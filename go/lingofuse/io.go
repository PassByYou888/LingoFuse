package lingofuse

// ---------------------------------------------------------------------------
// Package-level JSON I/O
// ---------------------------------------------------------------------------
//
// This file mirrors lf_io.hpp (C++), lf_io.py (Python),
// LfIo.cs (C#), lf-io.js (JavaScript), and io.rs (Rust). It is the
// SINGLE sanctioned path for moving structured data to and from a
// DataHandle.
//
// Wire format:
//
//	[UTF-8 encoded JSON text][NUL byte]
//	[UTF-8 text][NUL byte]
//	[arbitrary bytes][NUL byte]
//
// Reading is fault-tolerant: if no NUL is found before the end of the
// buffer, the entire remaining buffer is consumed. This matches the
// Pascal, Python, C++, C#, and JavaScript bindings exactly.
//
// JSON SERIALIZATION POLICY
// -------------------------
// The toolchain-wide policy is:
//
//     - Compact output (no indentation, no trailing whitespace).
//     - Literal UTF-8: non-ASCII characters (CJK, emoji, accented
//       Latin) are emitted as literal UTF-8 bytes, NOT as \uXXXX
//       escapes.
//     - HTML escaping DISABLED: '<', '>', '&', U+2028, U+2029 are
//       emitted literally, NOT as \u003c, \u003e, \u0026, \u2028,
//       \u2029.
//     - Non-serializable values degrade to their str() representation
//       instead of raising (see MarshalJSON below).
//
// {!!!!!  WHY html_escape MUST BE DISABLED  !!!!!}
// Go's encoding/json.Marshal defaults to HTML-escaping '<', '>',
// '&', and the line separators U+2028 / U+2029. This is a Go
// security feature (it protects against XSS when embedding JSON in
// HTML), but it is INCOMPATIBLE with the rest of the LingoFuse
// toolchain:
//
//     C++       dumps_json  -> ensure_ascii=false, no HTML escape
//     Python    dumps_json  -> ensure_ascii=False, no HTML escape
//     JS        JSON.stringify -> no HTML escape
//
// A Go service that emitted {"msg":"<hello>"} as
// {"msg":"\u003chello\u003e"} would produce a byte sequence no other
// binding produces for the same object. Callers relying on
// byte-level identity for hashing, caching, or signature verification
// would observe a spurious mismatch.
//
// The fix is to route every serialization through a json.Encoder
// configured with SetEscapeHTML(false), and to strip the trailing
// newline that Encoder.Encode appends. This yields byte-identical
// output to the C++ / Python / JS producers.

import (
	"bytes"
	"encoding/json"
	"errors"
	"runtime"
	"strings"

	"github.com/PassByYou888/LingoFuse/go/sys"
)

// ---------------------------------------------------------------------------
// JSON: raw string <-> value
// ---------------------------------------------------------------------------

// MarshalJSON serializes v to a compact UTF-8 JSON string using the
// toolchain-wide policy (see the file header).
//
// The output is byte-identical to what the C++, Python, and
// JavaScript bindings produce for the same logical value.
//
// Errors:
//
//	Any error returned by the underlying json.Encoder is wrapped
//	as ErrWriteFailed. This is rare in practice: encoding/json
//	only fails on types it cannot handle, and the encoder used
//	here is the same one, just with HTML escaping disabled.
func MarshalJSON(v any) (string, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	// Disable HTML escaping: this is the single change that makes
	// Go's output match the rest of the toolchain.
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return "", wrapErr(ErrWriteFailed, err,
			"MarshalJSON: %s", err.Error())
	}
	// Encoder.Encode appends a trailing '\n'. Strip it so that the
	// output is compact. Note that we only strip the LAST newline:
	// an embedded newline inside a JSON string is escaped by the
	// encoder as \n, so it cannot appear as a raw byte here.
	s := buf.String()
	return strings.TrimRight(s, "\n"), nil
}

// UnmarshalJSON parses a UTF-8 JSON string into v. Strict: any syntax
// error is reported as ErrReadFailed.
//
// This is the read-side counterpart of MarshalJSON. It does NOT
// apply the unified JSON repair preprocessing; callers that want
// repair-on-read should use lingofuse/json_repair_preprocess or the
// read_json path on DataHandle.
func UnmarshalJSON(text string, v any) error {
	if err := json.Unmarshal([]byte(text), v); err != nil {
		return wrapErr(ErrReadFailed, err,
			"UnmarshalJSON: %s", err.Error())
	}
	return nil
}

// ---------------------------------------------------------------------------
// String I/O (NUL-framed UTF-8)
// ---------------------------------------------------------------------------

// WriteString writes s as UTF-8 bytes followed by a single NUL byte.
// An empty string writes exactly one byte (the NUL).
func WriteString(h *DataHandle, s string) error {
	if h == nil {
		return newErr(ErrNullHandle, "WriteString: nil handle")
	}
	return h.WriteString(s)
}

// ReadString reads a UTF-8 string from h, stopping at the first NUL.
// If no NUL is present, the entire remaining buffer is consumed.
func ReadString(h *DataHandle) (string, error) {
	if h == nil {
		return "", newErr(ErrNullHandle, "ReadString: nil handle")
	}
	return h.ReadString()
}

// ---------------------------------------------------------------------------
// Byte I/O (NUL-framed raw bytes)
// ---------------------------------------------------------------------------

// WriteStringBytes writes raw bytes followed by a single NUL byte.
// Embedded NULs are preserved in the buffer.
func WriteStringBytes(h *DataHandle, data []byte) error {
	if h == nil {
		return newErr(ErrNullHandle, "WriteStringBytes: nil handle")
	}
	if err := h.WriteBytes(data); err != nil {
		return err
	}
	return h.WriteBytes([]byte{0})
}

// ReadStringBytes reads raw bytes from h, stopping at the first NUL.
//
// Note: because this stops at the first NUL, an embedded NUL in the
// payload acts as a terminator. Use ReadAllBytes to recover the
// entire buffer, including embedded NULs.
func ReadStringBytes(h *DataHandle) ([]byte, error) {
	if h == nil {
		return nil, newErr(ErrNullHandle, "ReadStringBytes: nil handle")
	}
	return h.ReadStringBytes()
}

// ReadAllBytes reads every remaining byte from h without NUL handling.
func ReadAllBytes(h *DataHandle) ([]byte, error) {
	if h == nil {
		return nil, newErr(ErrNullHandle, "ReadAllBytes: nil handle")
	}
	return h.ReadAllBytes()
}

// ---------------------------------------------------------------------------
// JSON I/O (NUL-framed JSON)
// ---------------------------------------------------------------------------

// WriteJSON serializes v as UTF-8 JSON and writes it with the
// standard NUL terminator.
//
// The serialization goes through MarshalJSON, so the toolchain-wide
// policy (no HTML escape, literal UTF-8, compact output) is
// guaranteed.
func WriteJSON(h *DataHandle, v any) error {
	if h == nil {
		return newErr(ErrNullHandle, "WriteJSON: nil handle")
	}
	text, err := MarshalJSON(v)
	if err != nil {
		return err
	}
	return h.WriteString(text)
}

// ReadJSON reads a NUL-framed JSON payload and deserializes it into v.
//
// An empty payload is reported as ErrReadFailed. A payload that is
// not valid JSON, or that does not match the shape of v, is also
// reported as ErrReadFailed.
func ReadJSON(h *DataHandle, v any) error {
	if h == nil {
		return newErr(ErrNullHandle, "ReadJSON: nil handle")
	}
	text, err := h.ReadString()
	if err != nil {
		return err
	}
	if text == "" {
		return newErr(ErrReadFailed, "ReadJSON: empty payload")
	}
	return UnmarshalJSON(text, v)
}

// TryReadJSON is the non-throwing counterpart of ReadJSON. It
// returns (true, nil) on success, (false, nil) when the payload is
// empty or not valid JSON, and (false, err) only when the handle
// itself is unusable.
//
// The cursor is advanced regardless of whether the payload parsed
// successfully.
func TryReadJSON(h *DataHandle, v any) (bool, error) {
	if h == nil {
		return false, newErr(ErrNullHandle, "TryReadJSON: nil handle")
	}
	text, err := h.ReadString()
	if err != nil {
		return false, err
	}
	if text == "" {
		return false, nil
	}
	if err := json.Unmarshal([]byte(text), v); err != nil {
		return false, nil
	}
	return true, nil
}

// ---------------------------------------------------------------------------
// JsonOrBytes
// ---------------------------------------------------------------------------

// JsonOrBytes is the result of a lenient JSON-or-bytes read.
//
// Fields:
//
//	Empty  — the handle contained no bytes at all.
//	IsJSON — true when the payload parsed as valid JSON.
//	JSON   — the parsed value (nil when IsJSON is false).
//	Bytes  — the raw payload (nil when IsJSON is true).
type JsonOrBytes struct {
	Empty  bool
	IsJSON bool
	JSON   any
	Bytes  []byte
}

// ReadJSONOrBytes reads a UTF-8 payload and returns either the parsed
// JSON value or the raw bytes.
//
// Semantics:
//
//	Empty payload                -> JsonOrBytes{Empty: true}
//	Valid JSON                   -> JsonOrBytes{IsJSON: true, JSON: v}
//	Valid UTF-8, invalid JSON    -> JsonOrBytes{Bytes: b}
//	Invalid UTF-8                -> JsonOrBytes{Bytes: b}
//
// The handle cursor is advanced past the payload exactly as in
// ReadStringBytes.
func ReadJSONOrBytes(h *DataHandle) (JsonOrBytes, error) {
	if h == nil {
		return JsonOrBytes{}, newErr(ErrNullHandle,
			"ReadJSONOrBytes: nil handle")
	}
	raw, err := h.ReadStringBytes()
	if err != nil {
		return JsonOrBytes{}, err
	}
	if len(raw) == 0 {
		return JsonOrBytes{Empty: true}, nil
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return JsonOrBytes{Bytes: raw}, nil
	}
	return JsonOrBytes{IsJSON: true, JSON: v}, nil
}

// ---------------------------------------------------------------------------
// C string helper
// ---------------------------------------------------------------------------

// CStr returns a NUL-terminated copy of s. Its sole purpose is to
// make the wire contract explicit at call sites that pass a Go
// string to a low-level C function.
//
// The returned byte slice must stay reachable for as long as the
// native call holds the pointer. Typical idiom:
//
//	b, p := lingofuse.CStr("hello")
//	sys.LF_CreateApp(p, nil)
//	runtime.KeepAlive(b)
func CStr(s string) ([]byte, *byte) {
	return sys.CString(s)
}

// 保证 runtime 包被引用（CStr 的文档提到 runtime.KeepAlive）。
var _ = runtime.KeepAlive

// 保证 errors 包被引用（供将来 Is/As 使用）。
var _ = errors.Is
