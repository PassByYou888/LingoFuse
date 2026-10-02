package lingofuse

import (
	"encoding/binary"
	"math"
	"sync"
	"unsafe"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// DataHandle is a RAII wrapper around a native LingoFuse data handle
// (sys.DataHnd). It provides byte-level, scalar, and NUL-framed
// string I/O on top of the underlying buffer.
//
// Two kinds of handles exist, distinguished only by the constructor
// used:
//
//   - Auto-recycled (NewDataHandle): added to the library's idle
//     pool. The pool scans every 5 seconds and frees any handle idle
//     for more than 10 minutes. Close marks the handle deleted; the
//     actual release happens on the next pool scan.
//
//   - Permanent (CreatePermanent): not added to the pool. Never
//     auto-reclaimed. Close releases it synchronously.
//
// Both kinds must be explicitly closed to avoid leaks.
//
// Ownership:
//
//   - Owning handles (created by the public constructors or
//     CreatePermanent) call sys.LF_FreeData on Close.
//   - Borrowed handles (created by fromRaw with owned=false) are
//     no-ops on Close; the native layer owns the resource and
//     releases it when the surrounding callback returns.
//
// A DataHandle is not safe for concurrent writes. Concurrent reads
// are permitted by the native library but are unusual in Go; callers
// should serialise all access.
type DataHandle struct {
	mu     sync.Mutex
	handle sys.DataHnd
	owned  bool
	closed bool
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

// NewDataHandle creates a new auto-recycled data handle bound to the
// given API name. The underlying buffer starts empty.
//
// The handle is added to the library's idle pool; the pool scans
// every 5 seconds and frees any handle idle for more than 10
// minutes. Use CreatePermanent when the handle must survive for the
// entire process lifetime.
func NewDataHandle(apiName string) (*DataHandle, error) {
	if err := sys.LoadLibrary(); err != nil {
		return nil, wrapErr(ErrLibraryLoadFailed, err,
			"NewDataHandle: native library not available")
	}

	var scope sys.CStringScope
	name := scope.Add(apiName)
	raw := sys.LF_CreateData(name)
	scope.Release()

	if raw == 0 {
		return nil, newErr(ErrGeneric,
			"NewDataHandle: LF_CreateData returned a null handle for %q",
			apiName)
	}
	return &DataHandle{handle: raw, owned: true}, nil
}

// CreatePermanent creates a new permanent data handle bound to the
// given API name. The underlying buffer starts empty.
//
// Difference from NewDataHandle:
//
//   - Not added to the library's idle pool.
//   - Never auto-reclaimed.
//   - Close releases it synchronously.
//
// "Permanent" means "not auto-reclaimed", NOT "never released".
// You are responsible for calling Close.
func CreatePermanent(apiName string) (*DataHandle, error) {
	if err := sys.LoadLibrary(); err != nil {
		return nil, wrapErr(ErrLibraryLoadFailed, err,
			"CreatePermanent: native library not available")
	}

	var scope sys.CStringScope
	name := scope.Add(apiName)
	raw := sys.LF_CreateData_Permanent(name)
	scope.Release()

	if raw == 0 {
		return nil, newErr(ErrGeneric,
			"CreatePermanent: LF_CreateData_Permanent returned a null handle for %q",
			apiName)
	}
	return &DataHandle{handle: raw, owned: true}, nil
}

// fromRaw wraps an existing handle. Intended for internal use inside
// callbacks. When owned is false, Close is a no-op.
func fromRaw(raw sys.DataHnd, owned bool) *DataHandle {
	return &DataHandle{handle: raw, owned: owned}
}

// ---------------------------------------------------------------------------
// Identity and state
// ---------------------------------------------------------------------------

// Raw returns the raw native pointer. Returns 0 after an owning
// handle has been closed. The returned value is valid only as long
// as this DataHandle has not been closed.
func (d *DataHandle) Raw() sys.DataHnd {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.handle
}

// IsValid reports whether the handle is valid and usable.
func (d *DataHandle) IsValid() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return !d.closed && d.handle != 0
}

// IsOwning reports whether Close will call sys.LF_FreeData.
func (d *DataHandle) IsOwning() bool {
	return d.owned
}

// ---------------------------------------------------------------------------
// Lifetime
// ---------------------------------------------------------------------------

// Close releases the native handle when ownership applies.
// Idempotent.
//
// For an owning auto-recycled handle, this only marks the handle
// deleted; the actual release happens on the next pool scan (at most
// 5 seconds later). For an owning permanent handle, the release is
// synchronous. For a borrowed handle, this is a no-op.
func (d *DataHandle) Close() {
	if d == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()

	if d.closed {
		return
	}
	if !d.owned {
		// Borrowed handle: the native layer owns the resource.
		return
	}

	h := d.handle
	d.handle = 0
	d.closed = true

	if h != 0 {
		sys.LF_FreeData(h)
	}
}

// requireHandle returns the raw pointer or an error if the handle is
// closed. The caller must hold d.mu.
func (d *DataHandle) requireHandle(op string) (sys.DataHnd, error) {
	if d.closed || d.handle == 0 {
		return 0, newErr(ErrNullHandle,
			"%s: data handle is closed or null", op)
	}
	return d.handle, nil
}

// ---------------------------------------------------------------------------
// Position and size
// ---------------------------------------------------------------------------

// Position returns the current read/write cursor, in bytes.
func (d *DataHandle) Position() (int64, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.Position")
	if err != nil {
		return 0, err
	}
	return sys.LF_GetPos(h), nil
}

// SetPosition sets the read/write cursor. A position past the
// current size implicitly grows the buffer; the new bytes are
// uninitialised.
func (d *DataHandle) SetPosition(pos int64) error {
	if pos < 0 {
		return newErr(ErrInvalidArgument,
			"DataHandle.SetPosition: position must be non-negative, got %d",
			pos)
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.SetPosition")
	if err != nil {
		return err
	}
	sys.LF_SetPos(h, pos)
	return nil
}

// Size returns the total buffer size, in bytes.
func (d *DataHandle) Size() (int64, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.Size")
	if err != nil {
		return 0, err
	}
	return sys.LF_GetSize(h), nil
}

// SetSize resizes the buffer. Growing leaves the new bytes
// uninitialised; shrinking discards the trailing bytes.
func (d *DataHandle) SetSize(size int64) error {
	if size < 0 {
		return newErr(ErrInvalidArgument,
			"DataHandle.SetSize: size must be non-negative, got %d",
			size)
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.SetSize")
	if err != nil {
		return err
	}
	sys.LF_SetSize(h, size)
	return nil
}

// ---------------------------------------------------------------------------
// Byte I/O
// ---------------------------------------------------------------------------

// WriteBytes appends data at the current cursor. The buffer grows as
// needed; the cursor advances by the number of bytes written.
// An empty slice is a no-op.
func (d *DataHandle) WriteBytes(data []byte) error {
	if len(data) == 0 {
		return nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.WriteBytes")
	if err != nil {
		return err
	}
	written := sys.LF_WriteBuffer(h,
		uintptr(unsafe.Pointer(&data[0])), int64(len(data)))
	if written != int64(len(data)) {
		return newErr(ErrWriteFailed,
			"DataHandle.WriteBytes: requested %d bytes, wrote %d",
			len(data), written)
	}
	return nil
}

// ReadBytes reads up to n bytes. The cursor advances by the number
// of bytes actually read. Never fails for a short read; returns an
// empty slice at end-of-buffer.
func (d *DataHandle) ReadBytes(n int) ([]byte, error) {
	if n < 0 {
		return nil, newErr(ErrInvalidArgument,
			"DataHandle.ReadBytes: n must be non-negative, got %d", n)
	}
	if n == 0 {
		return []byte{}, nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.ReadBytes")
	if err != nil {
		return nil, err
	}
	buf := make([]byte, n)
	got := sys.LF_ReadBuffer(h,
		uintptr(unsafe.Pointer(&buf[0])), int64(n))
	if got <= 0 {
		return []byte{}, nil
	}
	if got < int64(n) {
		buf = buf[:got]
	}
	return buf, nil
}

// ReadBytesExact reads exactly n bytes. On a short read the cursor
// is left unchanged and ErrReadFailed is returned.
func (d *DataHandle) ReadBytesExact(n int) ([]byte, error) {
	if n < 0 {
		return nil, newErr(ErrInvalidArgument,
			"DataHandle.ReadBytesExact: n must be non-negative, got %d", n)
	}
	if n == 0 {
		return []byte{}, nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.ReadBytesExact")
	if err != nil {
		return nil, err
	}
	saved := sys.LF_GetPos(h)
	buf := make([]byte, n)
	got := sys.LF_ReadBuffer(h,
		uintptr(unsafe.Pointer(&buf[0])), int64(n))
	if got != int64(n) {
		sys.LF_SetPos(h, saved)
		return nil, newErr(ErrReadFailed,
			"DataHandle.ReadBytesExact: requested %d bytes, got %d",
			n, got)
	}
	return buf, nil
}

// TryReadBytes is the non-throwing counterpart of ReadBytesExact.
// Returns (nil, false, nil) on a short read (cursor restored).
func (d *DataHandle) TryReadBytes(n int) (data []byte, ok bool, err error) {
	if n < 0 {
		return nil, false, newErr(ErrInvalidArgument,
			"DataHandle.TryReadBytes: n must be non-negative, got %d", n)
	}
	if n == 0 {
		return []byte{}, true, nil
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	h, herr := d.requireHandle("DataHandle.TryReadBytes")
	if herr != nil {
		return nil, false, herr
	}
	saved := sys.LF_GetPos(h)
	buf := make([]byte, n)
	got := sys.LF_ReadBuffer(h,
		uintptr(unsafe.Pointer(&buf[0])), int64(n))
	if got != int64(n) {
		sys.LF_SetPos(h, saved)
		return nil, false, nil
	}
	return buf, true, nil
}

// ReadAllBytes reads every remaining byte from the current cursor to
// the end of the buffer and advances the cursor to the end.
func (d *DataHandle) ReadAllBytes() ([]byte, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.ReadAllBytes")
	if err != nil {
		return nil, err
	}
	pos := sys.LF_GetPos(h)
	total := sys.LF_GetSize(h)
	if pos >= total {
		return []byte{}, nil
	}
	n := total - pos
	buf := make([]byte, n)
	got := sys.LF_ReadBuffer(h,
		uintptr(unsafe.Pointer(&buf[0])), n)
	if got < 0 {
		return []byte{}, nil
	}
	if got < n {
		buf = buf[:got]
	}
	return buf, nil
}

// ---------------------------------------------------------------------------
// Scalar I/O (little-endian)
// ---------------------------------------------------------------------------

func (d *DataHandle) writeScalar(v uint64, size int) error {
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint64(buf, v)
	return d.WriteBytes(buf[:size])
}

func (d *DataHandle) readScalar(size int) (uint64, error) {
	b, err := d.ReadBytesExact(size)
	if err != nil {
		return 0, err
	}
	buf := make([]byte, 8)
	copy(buf, b)
	return binary.LittleEndian.Uint64(buf), nil
}

func (d *DataHandle) WriteUint8(v uint8) error   { return d.writeScalar(uint64(v), 1) }
func (d *DataHandle) WriteInt8(v int8) error     { return d.writeScalar(uint64(uint8(v)), 1) }
func (d *DataHandle) WriteUint16(v uint16) error { return d.writeScalar(uint64(v), 2) }
func (d *DataHandle) WriteInt16(v int16) error   { return d.writeScalar(uint64(uint16(v)), 2) }
func (d *DataHandle) WriteUint32(v uint32) error { return d.writeScalar(uint64(v), 4) }
func (d *DataHandle) WriteInt32(v int32) error   { return d.writeScalar(uint64(uint32(v)), 4) }
func (d *DataHandle) WriteUint64(v uint64) error { return d.writeScalar(v, 8) }
func (d *DataHandle) WriteInt64(v int64) error   { return d.writeScalar(uint64(v), 8) }

func (d *DataHandle) WriteSingle(v float32) error {
	return d.writeScalar(uint64(math.Float32bits(v)), 4)
}
func (d *DataHandle) WriteDouble(v float64) error {
	return d.writeScalar(math.Float64bits(v), 8)
}

func (d *DataHandle) ReadUint8() (uint8, error) {
	v, err := d.readScalar(1)
	return uint8(v), err
}
func (d *DataHandle) ReadInt8() (int8, error) {
	v, err := d.readScalar(1)
	return int8(v), err
}
func (d *DataHandle) ReadUint16() (uint16, error) {
	v, err := d.readScalar(2)
	return uint16(v), err
}
func (d *DataHandle) ReadInt16() (int16, error) {
	v, err := d.readScalar(2)
	return int16(v), err
}
func (d *DataHandle) ReadUint32() (uint32, error) {
	v, err := d.readScalar(4)
	return uint32(v), err
}
func (d *DataHandle) ReadInt32() (int32, error) {
	v, err := d.readScalar(4)
	return int32(v), err
}
func (d *DataHandle) ReadUint64() (uint64, error) {
	return d.readScalar(8)
}
func (d *DataHandle) ReadInt64() (int64, error) {
	v, err := d.readScalar(8)
	return int64(v), err
}

func (d *DataHandle) ReadSingle() (float32, error) {
	v, err := d.readScalar(4)
	return math.Float32frombits(uint32(v)), err
}
func (d *DataHandle) ReadDouble() (float64, error) {
	v, err := d.readScalar(8)
	return math.Float64frombits(v), err
}

// ---------------------------------------------------------------------------
// NUL-framed string I/O
// ---------------------------------------------------------------------------

// WriteString writes s as UTF-8 bytes followed by a single NUL byte.
// An empty string writes exactly one byte (the NUL).
func (d *DataHandle) WriteString(s string) error {
	if err := d.WriteBytes([]byte(s)); err != nil {
		return err
	}
	return d.WriteBytes([]byte{0})
}

// readUntilNUL reads from the current cursor up to the first NUL, or
// the entire remaining buffer if no NUL is found. The cursor is
// advanced past the NUL, or to (size + 1) when none was found.
//
// The caller must hold d.mu.
func (d *DataHandle) readUntilNUL(op string) ([]byte, error) {
	h, err := d.requireHandle(op)
	if err != nil {
		return nil, err
	}
	start := sys.LF_GetPos(h)
	total := sys.LF_GetSize(h)
	if start >= total {
		return []byte{}, nil
	}
	remaining := total - start
	raw := make([]byte, remaining)
	got := sys.LF_ReadBuffer(h,
		uintptr(unsafe.Pointer(&raw[0])), remaining)
	if got <= 0 {
		return []byte{}, nil
	}
	if got < remaining {
		raw = raw[:got]
	}
	for i, b := range raw {
		if b == 0 {
			sys.LF_SetPos(h, start+int64(i)+1)
			return raw[:i], nil
		}
	}
	// No NUL found: consume the whole tail, move one byte past the
	// end of the buffer (matches the native fault-tolerant rule).
	sys.LF_SetPos(h, start+int64(len(raw))+1)
	return raw, nil
}

// ReadString reads a UTF-8 string from the current cursor, stopping
// at the first NUL. If no NUL is present, the entire remaining buffer
// is consumed and returned. Invalid UTF-8 byte sequences are decoded
// with U+FFFD, matching the fault-tolerant policy of every other
// binding.
func (d *DataHandle) ReadString() (string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	b, err := d.readUntilNUL("DataHandle.ReadString")
	if err != nil {
		return "", err
	}
	if len(b) == 0 {
		return "", nil
	}
	return string(b), nil
}

// ReadStringBytes is the raw-byte counterpart of ReadString. The
// bytes are returned undecoded; embedded NULs act as terminators,
// matching every other LingoFuse binding.
func (d *DataHandle) ReadStringBytes() ([]byte, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.readUntilNUL("DataHandle.ReadStringBytes")
}

// TryReadString is the non-throwing counterpart of ReadString. The
// only recoverable failure mode is an exhausted buffer; a closed
// handle still returns an error.
func (d *DataHandle) TryReadString() (string, bool, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	h, err := d.requireHandle("DataHandle.TryReadString")
	if err != nil {
		return "", false, err
	}
	if sys.LF_GetPos(h) >= sys.LF_GetSize(h) {
		return "", false, nil
	}
	b, err := d.readUntilNUL("DataHandle.TryReadString")
	if err != nil {
		return "", false, err
	}
	return string(b), true, nil
}
