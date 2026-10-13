package test

import (
	"testing"

	"github.com/PassByYou888/LingoFuse/go/lingofuse"
	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// AppTarget
// ---------------------------------------------------------------------------

func TestAppTargetProperties(t *testing.T) {
	tgt := lingofuse.App("Calc")

	if got := tgt.Name(); got != "Calc" {
		t.Fatalf("Name() = %q, want %q", got, "Calc")
	}
	if got := tgt.Describe(); got != "app(Calc)" {
		t.Fatalf("Describe() = %q, want %q", got, "app(Calc)")
	}
	if got := tgt.String(); got != "app(Calc)" {
		t.Fatalf("String() = %q, want %q", got, "app(Calc)")
	}
}

func TestAppTargetImplementsTarget(t *testing.T) {
	var _ lingofuse.Target = lingofuse.App("X")
}

// ---------------------------------------------------------------------------
// UIDTarget
// ---------------------------------------------------------------------------

func TestUIDTargetProperties(t *testing.T) {
	var uid sys.TP2P_UID
	for i := range uid.Bytes {
		uid.Bytes[i] = byte(i)
	}
	tgt := lingofuse.UID(uid)

	if got := tgt.UID(); got != uid {
		t.Fatalf("UID() = %v, want %v", got, uid)
	}
	if got := tgt.Describe(); got != "uid("+sys.FormatUIDHex(uid)+")" {
		t.Fatalf("Describe() = %q", got)
	}
}

func TestUIDTargetImplementsTarget(t *testing.T) {
	var _ lingofuse.Target = lingofuse.UID(sys.TP2P_UID{})
}

func TestUIDTargetZeroUIDAllowedAtConstruction(t *testing.T) {
	// A zero UID is a well-defined value: it represents "no identity".
	// Constructing a target for it must succeed; whether the call
	// routes anywhere is a runtime question.
	tgt := lingofuse.UID(sys.NullUID)
	if !sys.IsNullUID(tgt.UID()) {
		t.Fatalf("constructed UIDTarget does not carry the null UID")
	}
}

// ---------------------------------------------------------------------------
// P2PNameTarget
// ---------------------------------------------------------------------------

func TestP2PNameTargetProperties(t *testing.T) {
	tgt := lingofuse.P2P("workers")

	if got := tgt.Group(); got != "workers" {
		t.Fatalf("Group() = %q, want %q", got, "workers")
	}
	if got := tgt.Describe(); got != "p2pname(workers)" {
		t.Fatalf("Describe() = %q", got)
	}
	if got := tgt.String(); got != "p2pname(workers)" {
		t.Fatalf("String() = %q", got)
	}
}

func TestP2PNameTargetImplementsTarget(t *testing.T) {
	var _ lingofuse.Target = lingofuse.P2P("g")
}

// ---------------------------------------------------------------------------
// sys-level UID helpers
// ---------------------------------------------------------------------------

func TestParseUIDHexValid(t *testing.T) {
	const hex = "00112233445566778899aabbccddeeff" +
		"00112233445566778899aabbccddeeff"
	uid, err := sys.ParseUIDHex(hex)
	if err != nil {
		t.Fatalf("ParseUIDHex: %v", err)
	}
	got := sys.FormatUIDHex(uid)
	if got != hex {
		t.Fatalf("FormatUIDHex round-trip = %q, want %q", got, hex)
	}
}

func TestParseUIDHexUppercaseAccepted(t *testing.T) {
	const hex = "AABBCCDDEEFF00112233445566778899" +
		"AABBCCDDEEFF00112233445566778899"
	uid, err := sys.ParseUIDHex(hex)
	if err != nil {
		t.Fatalf("ParseUIDHex(uppercase): %v", err)
	}
	// FormatUIDHex always emits lowercase.
	if sys.FormatUIDHex(uid) != "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899" {
		t.Fatalf("uppercase round-trip lost content")
	}
}

func TestParseUIDHexWrongLength(t *testing.T) {
	cases := []string{"", "00", "abc"}
	for _, c := range cases {
		if _, err := sys.ParseUIDHex(c); err == nil {
			t.Fatalf("ParseUIDHex(%q) = nil error; want failure", c)
		}
	}
}

func TestParseUIDHexInvalidCharacter(t *testing.T) {
	const bad = "zz" + "00" + "000000000000000000000000000000" +
		"00000000000000000000000000000000"
	if _, err := sys.ParseUIDHex(bad); err == nil {
		t.Fatalf("ParseUIDHex with non-hex char returned nil error")
	}
}

func TestIsNullUID(t *testing.T) {
	if !sys.IsNullUID(sys.NullUID) {
		t.Fatalf("IsNullUID(NullUID) = false")
	}
	var nonZero sys.TP2P_UID
	nonZero.Bytes[31] = 1
	if sys.IsNullUID(nonZero) {
		t.Fatalf("IsNullUID(non-zero) = true")
	}
}

// ---------------------------------------------------------------------------
// Target interface uniformity
// ---------------------------------------------------------------------------

// TestTargetInterfaceUniformity asserts that all three addressing
// modes expose exactly the same method surface, so that call sites
// can switch modes without rewriting the call shape.
//
// This test is compile-time: if any of the three concrete types were
// to lose a method, the assignment below would fail to compile.
func TestTargetInterfaceUniformity(t *testing.T) {
	targets := []lingofuse.Target{
		lingofuse.App("Calc"),
		lingofuse.UID(sys.NullUID),
		lingofuse.P2P("workers"),
	}
	for _, tgt := range targets {
		if tgt.Describe() == "" {
			t.Fatalf("Describe() returned empty for %T", tgt)
		}
	}
}
