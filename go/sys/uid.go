package sys

import (
	"encoding/hex"
	"fmt"
)

// ---------------------------------------------------------------------------
// UID type and helpers
// ---------------------------------------------------------------------------
//
// The Pascal-side type `TP2P_UID___` is `array[0..31] of Byte`. On the
// FFI boundary, that maps to a 32-byte aggregate.
//
// {!!!!!  WHY A STRUCT, NOT A [32]byte ARRAY  !!!!!}
// The naive Go translation would be `type TP2P_UID = [32]byte`. That
// works at the language level, but the FFI library this binding uses
// (purego) does NOT support array-typed parameters or return values:
// it rejects them at registration time with an "unsupported type"
// panic, which then cascades into a LoadError for the entire library.
//
// Wrapping the array in a struct sidesteps the limitation without
// changing the ABI. On x86-64 SysV and Microsoft x64, a 32-byte
// aggregate -- whether it is an array or a struct containing that
// array -- is classified MEMORY by the psABI and is passed on the
// stack as an argument. The C side declares exactly this shape:
//
//	typedef struct TP2P_UID_s {
//	    uint8_t bytes[32];
//	} TP2P_UID;
//
// so the struct-wrapped form is ABI-compatible at the argument
// position by construction.
//
// {!!!!!  TWO ROLES, TWO REPRESENTATIONS  !!!!!}
// The same logical UID plays two roles on the C ABI:
//
//	ROLE 1 -- ARGUMENT (input position).
//	    Functions such as LF_UID_Call, LF_UID_Notify, LF_Check_UID
//	    take a 32-byte UID BY VALUE. The Go type is `TP2P_UID` (the
//	    struct defined below).
//
//	ROLE 2 -- RETURN VALUE (only LF_Get_P2P_UID).
//	    LF_Get_P2P_UID returns a POINTER to a 32-byte UID. The Go
//	    type is `*TP2P_UID`. The pointer is allocated by the C side
//	    and released automatically about 5 seconds after the call;
//	    callers MUST copy the 32 bytes immediately and MUST NOT free
//	    the pointer.
//
// {!!!!!  FIELD ACCESS  !!!!!}
// The 32 bytes are exposed as the `Bytes` field:
//
//	uid.Bytes[0]       // one byte
//	uid.Bytes[:]       // the whole array as a slice
//	copy(dst, uid.Bytes[:])
//
// The struct is comparable with `==`, so equality checks between two
// UIDs remain one-liners.
type TP2P_UID struct {
	Bytes [32]byte
}

// NullUID is the all-zero UID, the canonical "no identity" value.
//
// The framework returns this from LF_Get_P2P_UID when the handle is
// not an INPUT handle, or when the sender did not provide a UID.
var NullUID = TP2P_UID{}

// IsNullUID reports whether uid is the all-zero UID.
func IsNullUID(uid TP2P_UID) bool {
	for _, b := range uid.Bytes {
		if b != 0 {
			return false
		}
	}
	return true
}

// ParseUIDHex converts a 64-character hexadecimal string into a
// 32-byte UID.
//
// Accepts both lowercase and uppercase hex digits. Rejects strings
// that are not exactly 64 characters long, and strings that contain
// non-hex characters.
func ParseUIDHex(s string) (TP2P_UID, error) {
	var uid TP2P_UID
	if len(s) != 64 {
		return uid, fmt.Errorf(
			"uid: hex string must be exactly 64 characters, got %d",
			len(s),
		)
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return uid, fmt.Errorf("uid: invalid hex string: %w", err)
	}
	copy(uid.Bytes[:], b)
	return uid, nil
}

// FormatUIDHex returns the lowercase hex representation of uid.
// The output is exactly 64 characters long.
func FormatUIDHex(uid TP2P_UID) string {
	return hex.EncodeToString(uid.Bytes[:])
}
