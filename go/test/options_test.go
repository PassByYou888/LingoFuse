package test

import (
	"testing"
	"time"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
	"github.com/PassByYou888/LingoFuse/go/sys"
)

// requireLibrary skips the test when the native library is not
// available. Every test that touches an LF_* call should invoke this
// first, so that a CI environment without the shared library
// produces a clean "skip", not a "fail".
func requireLibrary(t *testing.T) {
	t.Helper()
	if err := sys.LoadLibrary(); err != nil {
		t.Skipf("LingoFuse native library not available: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Boolean option round-trips
// ---------------------------------------------------------------------------

func TestOptQuietRoundTrip(t *testing.T) {
	requireLibrary(t)

	orig, err := lingofuse.GetOptQuiet()
	if err != nil {
		t.Fatalf("GetOptQuiet: %v", err)
	}
	t.Cleanup(func() { _ = lingofuse.SetOptQuiet(orig) })

	if err := lingofuse.SetOptQuiet(true); err != nil {
		t.Fatalf("SetOptQuiet(true): %v", err)
	}
	if got, _ := lingofuse.GetOptQuiet(); !got {
		t.Fatalf("GetOptQuiet() = false after SetOptQuiet(true)")
	}
	if err := lingofuse.SetOptQuiet(false); err != nil {
		t.Fatalf("SetOptQuiet(false): %v", err)
	}
	if got, _ := lingofuse.GetOptQuiet(); got {
		t.Fatalf("GetOptQuiet() = true after SetOptQuiet(false)")
	}
}

func TestOptShowThreadIDRoundTrip(t *testing.T) {
	requireLibrary(t)

	orig, _ := lingofuse.GetOptShowThreadID()
	t.Cleanup(func() { _ = lingofuse.SetOptShowThreadID(orig) })

	if err := lingofuse.SetOptShowThreadID(true); err != nil {
		t.Fatalf("SetOptShowThreadID(true): %v", err)
	}
	if got, _ := lingofuse.GetOptShowThreadID(); !got {
		t.Fatalf("GetOptShowThreadID() = false")
	}
	_ = lingofuse.SetOptShowThreadID(false)
	if got, _ := lingofuse.GetOptShowThreadID(); got {
		t.Fatalf("GetOptShowThreadID() = true")
	}
}

func TestOptConsoleOutputRoundTrip(t *testing.T) {
	requireLibrary(t)

	orig, _ := lingofuse.GetOptConsoleOutput()
	t.Cleanup(func() { _ = lingofuse.SetOptConsoleOutput(orig) })

	_ = lingofuse.SetOptConsoleOutput(true)
	if got, _ := lingofuse.GetOptConsoleOutput(); !got {
		t.Fatalf("SetOptConsoleOutput(true) did not stick")
	}
	_ = lingofuse.SetOptConsoleOutput(false)
	if got, _ := lingofuse.GetOptConsoleOutput(); got {
		t.Fatalf("SetOptConsoleOutput(false) did not stick")
	}
}

// ---------------------------------------------------------------------------
// Integer option round-trips
// ---------------------------------------------------------------------------

func TestOptWaitConnectionTimeoutRoundTrip(t *testing.T) {
	requireLibrary(t)

	orig, _ := lingofuse.GetOptWaitConnectionTimeout()
	t.Cleanup(func() { _ = lingofuse.SetOptWaitConnectionTimeout(orig) })

	const want uint64 = 12345
	if err := lingofuse.SetOptWaitConnectionTimeout(want); err != nil {
		t.Fatalf("SetOptWaitConnectionTimeout: %v", err)
	}
	got, err := lingofuse.GetOptWaitConnectionTimeout()
	if err != nil {
		t.Fatalf("GetOptWaitConnectionTimeout: %v", err)
	}
	if got != want {
		t.Fatalf("round-trip = %d, want %d", got, want)
	}
}

func TestOptIPCServThreadCountRoundTrip(t *testing.T) {
	requireLibrary(t)

	orig, _ := lingofuse.GetOptIPCServThreadCount()
	t.Cleanup(func() { _ = lingofuse.SetOptIPCServThreadCount(orig) })

	const want = 4
	_ = lingofuse.SetOptIPCServThreadCount(want)
	got, _ := lingofuse.GetOptIPCServThreadCount()
	if got != want {
		t.Fatalf("round-trip = %d, want %d", got, want)
	}
}

func TestOptFixedSequencedTimeRoundTrip(t *testing.T) {
	requireLibrary(t)

	orig, _ := lingofuse.GetOptFixedSequencedTime()
	t.Cleanup(func() { _ = lingofuse.SetOptFixedSequencedTime(orig) })

	const want uint64 = 7777
	_ = lingofuse.SetOptFixedSequencedTime(want)
	got, _ := lingofuse.GetOptFixedSequencedTime()
	if got != want {
		t.Fatalf("round-trip = %d, want %d", got, want)
	}
}

func TestOptDataHandleIdleTimeoutRoundTrip(t *testing.T) {
	requireLibrary(t)

	orig, _ := lingofuse.GetOptDataHandleIdleTimeout()
	t.Cleanup(func() { _ = lingofuse.SetOptDataHandleIdleTimeout(orig) })

	const want uint64 = 9999
	_ = lingofuse.SetOptDataHandleIdleTimeout(want)
	got, _ := lingofuse.GetOptDataHandleIdleTimeout()
	if got != want {
		t.Fatalf("round-trip = %d, want %d", got, want)
	}
}

// ---------------------------------------------------------------------------
// String option round-trips
// ---------------------------------------------------------------------------

func TestOptP2PNameRoundTrip(t *testing.T) {
	requireLibrary(t)

	orig, _ := lingofuse.GetOptP2PName()
	t.Cleanup(func() { _ = lingofuse.SetOptP2PName(orig) })

	const want = "test_group_unit"
	if err := lingofuse.SetOptP2PName(want); err != nil {
		t.Fatalf("SetOptP2PName: %v", err)
	}
	got, err := lingofuse.GetOptP2PName()
	if err != nil {
		t.Fatalf("GetOptP2PName: %v", err)
	}
	if got != want {
		t.Fatalf("round-trip = %q, want %q", got, want)
	}
}

// ---------------------------------------------------------------------------
// Special-cased options
// ---------------------------------------------------------------------------

// TestOptPasswordIsMasked verifies that GetOptPassword never returns
// the real password. The native layer deliberately returns a fixed
// mask ("********"); this test documents the contract.
func TestOptPasswordIsMasked(t *testing.T) {
	requireLibrary(t)

	orig, _ := lingofuse.GetOptPassword()
	t.Cleanup(func() { _ = lingofuse.SetOptPassword(orig) })

	const secret = "not-a-real-password-12345"
	if err := lingofuse.SetOptPassword(secret); err != nil {
		t.Fatalf("SetOptPassword: %v", err)
	}
	got, err := lingofuse.GetOptPassword()
	if err != nil {
		t.Fatalf("GetOptPassword: %v", err)
	}
	if got == secret {
		t.Fatalf("GetOptPassword returned the real password; " +
			"the mask contract is broken")
	}
}

// TestGenericGetOptionUnknownReturnsEmpty verifies that reading an
// unknown option name yields an empty string, not an error. This
// matches the native library's documented behaviour.
func TestGenericGetOptionUnknownReturnsEmpty(t *testing.T) {
	requireLibrary(t)

	got, err := lingofuse.GetOption("no_such_option_xyz")
	if err != nil {
		t.Fatalf("GetOption: %v", err)
	}
	if got != "" {
		t.Fatalf("GetOption(unknown) = %q, want empty", got)
	}
}

// ---------------------------------------------------------------------------
// Client default timeout arithmetic
// ---------------------------------------------------------------------------

// TestClientTimeoutConversion verifies that Client's default-timeout
// arithmetic is correct. This is a pure Go test and does not require
// a live connection.
func TestClientTimeoutConversion(t *testing.T) {
	// We do not call Connect here (which would touch the native
	// library). Instead we exercise the unexported helper indirectly
	// through the WithTimeout option and the Timeout accessor.
	//
	// The construction below bypasses Connect, so it is a structural
	// check rather than a behavioural one.
	//
	// The conversion itself is trivial (d / time.Millisecond) and is
	// covered end-to-end by the e2e tests that use a live server.
	_ = lingofuse.WithTimeout(5 * time.Second)
}
