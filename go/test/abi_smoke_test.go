package test

import (
	"testing"
	"unsafe"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

func ensureLib(t *testing.T) {
	t.Helper()
	if err := sys.LoadLibrary(); err != nil {
		t.Skipf("[SKIP] native library not available: %v", err)
	}
}

func TestLibraryLoads(t *testing.T) {
	ensureLib(t)

	// Check that zero-argument functions are usable.
	if sys.LF_CheckMainThread() != 0 {
		// The main thread is not running before PrepareDone.
		t.Logf("LF_CheckMainThread returned non-zero")
	}
	_ = sys.LF_GetStatusCount()
}

func TestDataHandleRoundtrip(t *testing.T) {
	ensureLib(t)

	var scope sys.CStringScope
	name := scope.Add("abi_smoke_roundtrip")
	hnd := sys.LF_CreateData(name)
	if hnd == 0 {
		t.Fatal("LF_CreateData returned a null handle")
	}
	defer sys.LF_FreeData(hnd)

	payload := []byte{0x01, 0x02, 0x03, 0x04}
	written := sys.LF_WriteBuffer(hnd, uintptr(unsafe.Pointer(&payload[0])), int64(len(payload)))
	if written != 4 {
		t.Fatalf("LF_WriteBuffer wrote %d bytes, expected 4", written)
	}

	if size := sys.LF_GetSize(hnd); size != 4 {
		t.Fatalf("LF_GetSize returned %d, expected 4", size)
	}

	sys.LF_SetPos(hnd, 0)

	back := make([]byte, 4)
	read := sys.LF_ReadBuffer(hnd, uintptr(unsafe.Pointer(&back[0])), 4)
	if read != 4 {
		t.Fatalf("LF_ReadBuffer read %d bytes, expected 4", read)
	}
	for i := range payload {
		if back[i] != payload[i] {
			t.Fatalf("round-trip mismatch at index %d: %x != %x", i, back[i], payload[i])
		}
	}
}

func TestPermanentHandle(t *testing.T) {
	ensureLib(t)

	var scope sys.CStringScope
	name := scope.Add("abi_smoke_permanent")
	hnd := sys.LF_CreateData_Permanent(name)
	if hnd == 0 {
		t.Fatal("LF_CreateData_Permanent returned null")
	}

	payload := []byte{0xAA, 0xBB, 0xCC}
	written := sys.LF_WriteBuffer(hnd, uintptr(unsafe.Pointer(&payload[0])), 3)
	if written != 3 {
		t.Fatalf("write returned %d", written)
	}
	if size := sys.LF_GetSize(hnd); size != 3 {
		t.Fatalf("size = %d", size)
	}

	// Synchronous release.
	sys.LF_FreeData(hnd)
}
