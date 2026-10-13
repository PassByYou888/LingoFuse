package test

import (
	"testing"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// ABI probe — argument-role UID passing
// ---------------------------------------------------------------------------
//
// The Go binding represents the Pascal-side `TP2P_UID___` type as a
// Go struct containing a 32-byte array (sys.TP2P_UID). On x86-64
// System V and Microsoft x64, a 32-byte aggregate is classified
// MEMORY by the psABI and is therefore passed by reference when it
// appears in an argument position: the caller allocates space for
// the value and passes a POINTER to that space in the argument
// register.
//
// {!!!!!  WHY THE BINDING DECLARES *TP2P_UID  !!!!!}
// purego, the FFI library used by this binding, does not support
// struct or array arguments on Windows amd64. The binding therefore
// declares the FFI-side parameter as `*TP2P_UID` and passes the
// address of a local copy. This matches the ABI on every supported
// platform.
//
// {!!!!!  WHY THIS TEST EXISTS  !!!!!}
// This is the single most fragile part of the Go binding: if the
// pointer-passing assumption were wrong, the failure mode would be
// silent stack corruption in the caller, not a Go panic at the call
// site. Every UID-addressed call would then produce garbage identity
// fields without any diagnostic.
//
// This test exercises the assumption directly by invoking the four
// query functions that take a UID pointer. Each of them is a pure
// read (no side effects, no mesh interaction) and returns an int32
// in {0, 1}. The test asserts:
//
//   1. The call does not panic.
//   2. The return value is exactly 0 or 1.
//   3. An all-zero UID (sys.NullUID) is never registered, so the
//      query returns 0.

// TestProbeCheckUID_ZeroArgument verifies that LF_Check_UID can be
// invoked with a UID pointer and returns a well-formed bool.
func TestProbeCheckUID_ZeroArgument(t *testing.T) {
	requireLibrary(t)

	uid := sys.NullUID
	got := sys.LF_Check_UID(&uid)

	if got != 0 && got != 1 {
		t.Fatalf("LF_Check_UID(NullUID) = %d, want 0 or 1; "+
			"the pointer-passing assumption may be broken", got)
	}
	if got != 0 {
		t.Fatalf("LF_Check_UID(NullUID) = %d, want 0", got)
	}
}

// TestProbeCheckUID_NonZeroArgument verifies the same for a
// non-trivial UID.
func TestProbeCheckUID_NonZeroArgument(t *testing.T) {
	requireLibrary(t)

	var uid sys.TP2P_UID
	for i := range uid.Bytes {
		uid.Bytes[i] = byte(0xA0 + i)
	}
	got := sys.LF_Check_UID(&uid)

	if got != 0 && got != 1 {
		t.Fatalf("LF_Check_UID(non-zero) = %d, want 0 or 1", got)
	}
}

// TestProbeCheckUIDApi verifies the two-argument form
// (UID + API name).
func TestProbeCheckUIDApi(t *testing.T) {
	requireLibrary(t)

	var scope sys.CStringScope
	api := scope.Add("probe_never_registered_api")
	uid := sys.NullUID
	got := sys.LF_Check_UID_Api(&uid, api)
	scope.Release()

	if got != 0 && got != 1 {
		t.Fatalf("LF_Check_UID_Api(NullUID, ...) = %d, want 0 or 1; "+
			"the pointer-passing assumption may be broken", got)
	}
	if got != 0 {
		t.Fatalf("LF_Check_UID_Api(NullUID, ...) = %d, want 0", got)
	}
}

// TestProbeCheckP2PName provides a baseline: this function does NOT
// take a UID argument, so it should trivially succeed.
func TestProbeCheckP2PName(t *testing.T) {
	requireLibrary(t)

	var scope sys.CStringScope
	group := scope.Add("probe_never_registered_group")
	got := sys.LF_Check_P2PNAME(group)
	scope.Release()

	if got != 0 && got != 1 {
		t.Fatalf("LF_Check_P2PNAME = %d, want 0 or 1", got)
	}
	if got != 0 {
		t.Fatalf("LF_Check_P2PNAME(unknown) = %d, want 0", got)
	}
}

// TestProbeCheckP2PNameApi provides the same baseline for the
// two-argument P2P form.
func TestProbeCheckP2PNameApi(t *testing.T) {
	requireLibrary(t)

	var scope sys.CStringScope
	group := scope.Add("probe_never_registered_group")
	api := scope.Add("probe_never_registered_api")
	got := sys.LF_Check_P2PNAME_Api(group, api)
	scope.Release()

	if got != 0 && got != 1 {
		t.Fatalf("LF_Check_P2PNAME_Api = %d, want 0 or 1", got)
	}
	if got != 0 {
		t.Fatalf("LF_Check_P2PNAME_Api(unknown) = %d, want 0", got)
	}
}

// TestProbeUIDRoundtripThroughHex is a pure Go sanity check: it
// confirms that ParseUIDHex / FormatUIDHex form a faithful
// round-trip, so that a UID read from the wire (as hex) and passed
// to a query function above is not corrupted in between.
func TestProbeUIDRoundtripThroughHex(t *testing.T) {
	var original sys.TP2P_UID
	for i := range original.Bytes {
		original.Bytes[i] = byte(i * 7)
	}
	hex := sys.FormatUIDHex(original)
	parsed, err := sys.ParseUIDHex(hex)
	if err != nil {
		t.Fatalf("ParseUIDHex: %v", err)
	}
	if parsed != original {
		t.Fatalf("round-trip mismatch: %v != %v", parsed, original)
	}
}
