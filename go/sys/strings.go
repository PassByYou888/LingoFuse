package sys

import (
	"runtime"
	"unsafe"
)

// CString allocates a NUL-terminated UTF-8 byte slice from a Go
// string. The returned byte slice MUST remain reachable for as long
// as the C function holds the pointer. Prefer CStringScope in call
// sites with multiple string parameters.
//
// The second return value points at the first byte of the backing
// buffer. If s is empty, the buffer still contains a single NUL byte.
func CString(s string) ([]byte, *byte) {
	b := make([]byte, len(s)+1)
	copy(b, s)
	return b, &b[0]
}

// CStringScope manages the lifetime of a set of C strings for the
// duration of a single call. Not thread-safe; create one per call
// site.
//
// Typical usage:
//
//	var scope sys.CStringScope
//	defer scope.Release()
//	sys.LF_SetOption(scope.Add("Quiet"), scope.Add("True"))
type CStringScope struct {
	keep [][]byte
}

// Add converts str to a NUL-terminated C string and tracks its
// backing storage until Release is called.
func (s *CStringScope) Add(str string) *byte {
	b, p := CString(str)
	s.keep = append(s.keep, b)
	return p
}

// Release drops every tracked backing buffer. After this call, any
// pointer previously returned by Add is invalid.
func (s *CStringScope) Release() {
	for i := range s.keep {
		s.keep[i] = nil
	}
	s.keep = nil
	runtime.KeepAlive(s)
}

// GoString copies a NUL-terminated C string into a Go string. The
// returned string owns its own memory and is safe to hold
// indefinitely.
//
// A nil pointer yields an empty string.
//
// The scan uses unsafe.Add, which keeps the pointer visible to the
// garbage collector and satisfies go vet's unsafeptr check.
func GoString(p *byte) string {
	if p == nil {
		return ""
	}
	n := uintptr(0)
	for {
		b := *(*byte)(unsafe.Add(unsafe.Pointer(p), n))
		if b == 0 {
			break
		}
		n++
	}
	if n == 0 {
		return ""
	}
	return string(unsafe.Slice(p, n))
}
