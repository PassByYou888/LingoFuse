//! Unified JSON, string, and byte I/O for LingoFuse data handles.
//!
//! This module is the Rust counterpart of `lf_io.hpp` (C++), `LfIo.cs`
//! (C#), and `lf-io.js` (JavaScript). It is the **single** sanctioned
//! path for moving structured data to and from a
//! [`DataHandle`](crate::data_handle::DataHandle).
//!
//! # Wire format
//!
//! A JSON payload on a data handle is:
//!
//! ```text
//! [UTF-8 encoded JSON text][NUL byte]
//! ```
//!
//! A plain-text payload uses the same framing. A raw binary payload is:
//!
//! ```text
//! [arbitrary bytes][NUL byte]
//! ```
//!
//! Reading is **fault-tolerant**: if no NUL is found before the end of
//! the buffer, the entire remaining buffer is consumed. This makes the
//! reader tolerant of payloads that arrive from an HTTP bridge or any
//! other producer that does not append a NUL.
//!
//! # Cross-language compatibility
//!
//! The framing matches `lingofuse_import.pas`, `lingofuse.lf_io`,
//! `lf_io.hpp`, `LfIo.cs`, and `lf-io.js` exactly. For the logical
//! payload `{"a":1}`, every binding emits the byte sequence
//! `7B 22 61 22 3A 31 7D 00`, and every reader follows the same
//! three-case rule:
//!
//! | Case | Condition | Result | New cursor |
//! |:----:|-----------|--------|------------|
//! | 1 | NUL found at offset `n` | Bytes `[start, start+n)` | `start + n + 1` |
//! | 2 | No NUL | Bytes `[start, size)` | `size + 1` |
//! | 3 | `start >= size` | Empty | unchanged |
//!
//! Case 2 advances the cursor to one byte past the end of the buffer.
//! The native library implicitly grows the buffer by one byte to
//! accommodate the new position, exactly like Pascal's
//! `LF_SetPos(Hnd, e + 1)`.
//!
//! # JSON serialization policy
//!
//! Every JSON string produced by this module goes through
//! [`dumps_json`]. That function is the single source of truth for the
//! serialization policy:
//!
//! - **Compact output**: no indentation, no trailing newline.
//! - **Literal UTF-8**: `serde_json` emits non-ASCII characters as
//!   literal UTF-8, not as `\uXXXX` escapes. This matches the Python
//!   `ensure_ascii=False` policy, the C++ `error_handler_t::replace`
//!   policy, and the C# `UnsafeRelaxedJsonEscaping` policy.
//! - **No panics**: a serialization failure returns
//!   [`ErrorCode::WriteFailed`](crate::error::ErrorCode::WriteFailed);
//!   a parse failure returns
//!   [`ErrorCode::ReadFailed`](crate::error::ErrorCode::ReadFailed).
//!
//! The module deliberately does **not** offer pretty-printing:
//! indentation would break the byte-for-byte cross-language contract.
//!
//! # Example
//!
//! ```no_run
//! use lingofuse::data_handle::DataHandle;
//! use lingofuse::io;
//! use serde::{Deserialize, Serialize};
//!
//! #[derive(Serialize, Deserialize)]
//! struct Point { x: f64, y: f64 }
//!
//! # fn main() -> Result<(), lingofuse::error::Error> {
//! let mut h = DataHandle::new("point")?;
//! io::write_json(&mut h, &Point { x: 1.5, y: 2.5 })?;
//! h.set_position(0)?;
//! let p: Point = io::read_json(&mut h)?;
//! # Ok(()) }
//! ```

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::data_handle::DataHandle;
use crate::error::{Error, ErrorCode};

// ============================================================================
// Constants
// ============================================================================

/// The NUL byte used as the string terminator on the wire.
pub const NUL_BYTE: u8 = 0x00;

// ============================================================================
// Internal helpers
// ============================================================================

/// Reads bytes from the handle up to the first NUL (or the end of the
/// buffer), and advances the cursor past the NUL (or to `size + 1` when
/// no NUL was found).
///
/// This is the single implementation of the three-case rule described in
/// the module documentation. Every byte-oriented reader in this module
/// delegates to it.
///
/// The function uses only the public [`DataHandle`] API, so it does not
/// depend on any private implementation detail of `data_handle.rs`.
fn read_until_nul(handle: &mut DataHandle) -> Result<Vec<u8>, Error> {
    let start = handle.position()?;
    let total = handle.size()?;

    // Case 3: cursor at or past the end of the buffer.
    if start >= total {
        return Ok(Vec::new());
    }

    // Read every remaining byte. The native `LF_ReadBuffer` advances the
    // cursor to the end of the buffer; we overwrite it below to match
    // the exact NUL-aware semantics.
    let remaining = (total - start) as usize;
    let mut raw = handle.read_bytes(remaining)?;

    if raw.is_empty() {
        return Ok(Vec::new());
    }

    // Scan for the first NUL.
    match raw.iter().position(|&b| b == NUL_BYTE) {
        Some(nul_index) => {
            // Case 1: a NUL was found. Truncate, then move the cursor
            // to just past the NUL.
            raw.truncate(nul_index);
            handle.set_position(start + nul_index as i64 + 1)?;
            Ok(raw)
        }
        None => {
            // Case 2: no NUL found. Move the cursor to one byte past
            // the end of the buffer.
            let new_pos = start + raw.len() as i64 + 1;
            handle.set_position(new_pos)?;
            Ok(raw)
        }
    }
}

// ============================================================================
// JSON: raw string <-> value
// ============================================================================

/// Serializes a value to a compact UTF-8 JSON string.
///
/// The single source of truth for the JSON serialization policy. See
/// the module documentation for the exact guarantees.
///
/// # Errors
///
/// Returns [`ErrorCode::WriteFailed`](crate::error::ErrorCode::WriteFailed)
/// when the value cannot be serialized (for example, a map with a
/// non-string key, or a `serde` `Serialize` implementation that
/// deliberately fails).
///
/// # Example
///
/// ```
/// # use lingofuse::io;
/// let s = io::dumps_json(&serde_json::json!({"a": 1})).unwrap();
/// assert_eq!(s, r#"{"a":1}"#);
/// ```
pub fn dumps_json<T: Serialize>(value: &T) -> Result<String, Error> {
    serde_json::to_string(value).map_err(|e| {
        Error::new(
            ErrorCode::WriteFailed,
            format!("io::dumps_json: {}", e),
        )
    })
}

/// Parses a UTF-8 JSON string into a value.
///
/// Strict: any syntax error produces
/// [`ErrorCode::ReadFailed`](crate::error::ErrorCode::ReadFailed).
/// Leading and trailing whitespace is ignored. A UTF-8 BOM is **not**
/// skipped; strip it yourself if you need to accept BOM-prefixed input.
///
/// # Errors
///
/// Returns [`ErrorCode::ReadFailed`](crate::error::ErrorCode::ReadFailed)
/// when the text is not valid JSON, or when the target type does not
/// match the payload's shape.
///
/// # Example
///
/// ```
/// # use lingofuse::io;
/// let v: serde_json::Value = io::loads_json(r#"{"a":1}"#).unwrap();
/// assert_eq!(v["a"], 1);
/// ```
pub fn loads_json<T: DeserializeOwned>(text: &str) -> Result<T, Error> {
    serde_json::from_str(text).map_err(|e| {
        Error::new(
            ErrorCode::ReadFailed,
            format!("io::loads_json: {}", e),
        )
    })
}

// ============================================================================
// String I/O (NUL-framed UTF-8)
// ============================================================================

/// Writes a string as UTF-8 bytes, followed by a single NUL byte.
///
/// An empty string writes exactly one byte (the NUL), matching the
/// Pascal, Python, C++, C#, and JavaScript bindings.
///
/// # Errors
///
/// Any failure from the underlying [`DataHandle::write_bytes`].
///
/// # Example
///
/// ```no_run
/// # use lingofuse::{data_handle::DataHandle, io};
/// # fn f() -> Result<(), lingofuse::error::Error> {
/// let mut h = DataHandle::new("greet")?;
/// io::write_string(&mut h, "hello, 世界")?;
/// # Ok(()) }
/// ```
pub fn write_string(handle: &mut DataHandle, value: &str) -> Result<(), Error> {
    handle.write_bytes(value.as_bytes())?;
    handle.write_bytes(&[NUL_BYTE])?;
    Ok(())
}

/// Reads a UTF-8 string from the handle, stopping at the first NUL.
///
/// If no NUL is present, the entire remaining buffer is consumed.
/// Returns an empty string when the cursor is at or past the end of the
/// buffer, or when the first byte is a NUL.
///
/// Invalid UTF-8 byte sequences are decoded with replacement characters
/// (`U+FFFD`). Callers that need to detect invalid UTF-8 should use
/// [`read_string_bytes`] and inspect the raw bytes.
///
/// # Errors
///
/// Any failure from the underlying [`DataHandle`] methods.
pub fn read_string(handle: &mut DataHandle) -> Result<String, Error> {
    let bytes = read_until_nul(handle)?;
    if bytes.is_empty() {
        return Ok(String::new());
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

// ============================================================================
// Byte-oriented I/O (NUL-framed raw bytes)
// ============================================================================

/// Writes raw bytes followed by a single NUL byte.
///
/// The bytes are written verbatim; embedded NUL bytes are preserved
/// **in the buffer**. Unlike [`write_string`], this does **not** stop
/// at an embedded NUL; it writes exactly `data.len()` bytes and
/// appends one additional NUL.
///
/// # Asymmetry with the read side
///
/// [`read_string_bytes`] is defined as "stop at the first NUL",
/// matching Pascal's `LF_ReadStringBytes`. An embedded NUL therefore
/// acts as a terminator on read, and the bytes after it are **not**
/// returned. This asymmetry is intentional and matches every other
/// LingoFuse binding (C++, C#, JavaScript). If you need to recover
/// every byte including the embedded NULs, use [`read_all_bytes`], or
/// encode the length explicitly in the payload.
///
/// # Errors
///
/// Any failure from the underlying [`DataHandle::write_bytes`].
pub fn write_string_bytes(
    handle: &mut DataHandle,
    data: &[u8],
) -> Result<(), Error> {
    handle.write_bytes(data)?;
    handle.write_bytes(&[NUL_BYTE])?;
    Ok(())
}

/// Reads raw bytes from the handle, stopping at the first NUL.
///
/// Unlike [`read_all_bytes`], which consumes the entire remaining
/// buffer, this stops at the NUL that [`write_string`] / [`write_json`]
/// append. The bytes are returned undecoded, so the caller can inspect
/// or forward them without a UTF-8 round-trip.
///
/// This is the accessor to use inside a bridge or proxy that forwards
/// a payload unchanged to a downstream consumer.
///
/// # Note
///
/// Because this stops at the first NUL, an **embedded** NUL in the
/// payload acts as a terminator: bytes after it are not returned. This
/// is the same behaviour as every other LingoFuse binding. Use
/// [`read_all_bytes`] to recover the entire buffer, including embedded
/// NULs.
///
/// # Errors
///
/// Any failure from the underlying [`DataHandle`] methods.
pub fn read_string_bytes(handle: &mut DataHandle) -> Result<Vec<u8>, Error> {
    read_until_nul(handle)
}

/// Reads raw bytes up to the first NUL **without advancing the cursor**.
///
/// Provided for diagnostic and logging code that needs to inspect the
/// current payload without consuming it. The cursor is restored to its
/// original value before returning, so a subsequent [`read_string`] /
/// [`read_json`] sees the same bytes.
///
/// If the underlying read fails, the cursor is still restored before
/// the error is returned.
///
/// # Errors
///
/// Any failure from the underlying [`DataHandle`] methods.
pub fn peek_string_bytes(handle: &mut DataHandle) -> Result<Vec<u8>, Error> {
    let saved = handle.position()?;
    let result = read_until_nul(handle);
    // Always restore the cursor, even on failure.
    let restore = handle.set_position(saved);
    match result {
        Ok(bytes) => {
            restore?;
            Ok(bytes)
        }
        Err(e) => {
            // Ignore a failure of the restore here: the read error is
            // the more informative one.
            let _ = restore;
            Err(e)
        }
    }
}

/// Reads all remaining bytes from the handle, without NUL handling.
///
/// The cursor is advanced to the end of the buffer. Use this for raw
/// binary payloads; use [`read_string_bytes`] for NUL-terminated text
/// or JSON payloads.
///
/// # Errors
///
/// Any failure from the underlying [`DataHandle`] methods.
pub fn read_all_bytes(handle: &mut DataHandle) -> Result<Vec<u8>, Error> {
    handle.read_all_bytes()
}

// ============================================================================
// JSON I/O
// ============================================================================

/// Serializes a value as UTF-8 JSON and writes it with the standard NUL
/// terminator.
///
/// The serialization goes through [`dumps_json`], so the compact,
/// non-ASCII-literal policy is guaranteed. The output never contains a
/// `\uXXXX` escape for non-ASCII text, and a trailing NUL byte is
/// always appended.
///
/// # Errors
///
/// - [`ErrorCode::WriteFailed`](crate::error::ErrorCode::WriteFailed)
///   if the value cannot be serialized.
/// - Any write failure from the underlying [`DataHandle`].
pub fn write_json<T: Serialize>(
    handle: &mut DataHandle,
    value: &T,
) -> Result<(), Error> {
    let text = dumps_json(value)?;
    write_string(handle, &text)
}

/// Reads a UTF-8 JSON payload from the handle and deserializes it.
///
/// The payload may or may not be NUL-terminated. If a NUL is present,
/// it is treated as the end of the payload; otherwise the entire
/// remaining buffer is consumed.
///
/// # Errors
///
/// - [`ErrorCode::ReadFailed`](crate::error::ErrorCode::ReadFailed)
///   when the payload is empty, or when it is not valid JSON, or when
///   it does not match the shape of `T`.
/// - Any read failure from the underlying [`DataHandle`].
pub fn read_json<T: DeserializeOwned>(
    handle: &mut DataHandle,
) -> Result<T, Error> {
    let bytes = read_until_nul(handle)?;
    if bytes.is_empty() {
        return Err(Error::new(
            ErrorCode::ReadFailed,
            "io::read_json: empty payload",
        ));
    }
    let text = String::from_utf8_lossy(&bytes);
    loads_json(&text)
}

/// Non-throwing counterpart of [`read_json`].
///
/// The cursor is advanced regardless of whether the payload parses
/// successfully; this matches the historical behaviour of the C# and
/// C++ wrappers, and it is the only sensible choice for a probe.
///
/// # Return value
///
/// - `Ok(None)` when the payload is empty.
/// - `Ok(None)` when the payload is not valid JSON.
/// - `Ok(None)` when the payload does not match the shape of `T`.
/// - `Ok(Some(value))` on success.
///
/// A null/disposed handle still produces `Err`.
///
/// # Errors
///
/// Any read failure from the underlying [`DataHandle`] methods.
pub fn try_read_json<T: DeserializeOwned>(
    handle: &mut DataHandle,
) -> Result<Option<T>, Error> {
    let bytes = read_until_nul(handle)?;
    if bytes.is_empty() {
        return Ok(None);
    }
    let text = String::from_utf8_lossy(&bytes);
    match serde_json::from_str::<T>(&text) {
        Ok(v) => Ok(Some(v)),
        Err(_) => Ok(None),
    }
}

// ============================================================================
// JsonOrBytes
// ============================================================================

/// The result of a lenient JSON-or-bytes read.
///
/// A three-state result, mirroring the C++ `JsonOrBytes` variant and
/// the C# `TryReadJson` / `ReadJson` design:
///
/// | Variant | Meaning |
/// |---------|---------|
/// | [`JsonOrBytes::Empty`] | The handle contained no bytes at all. |
/// | [`JsonOrBytes::Json`] | The payload parsed as valid JSON. |
/// | [`JsonOrBytes::Bytes`] | The payload was not JSON (or was not UTF-8); raw bytes are returned. |
///
/// Used by callers that historically treated a non-JSON response as a
/// payload they should forward or log verbatim, rather than as a
/// protocol error. The canonical example is an MCP bridge: a backend
/// API may return plain text or binary, and the bridge must not reject
/// it merely because it is not JSON.
///
/// Callers that want strict behaviour must use [`read_json`] instead.
#[derive(Debug, Clone, PartialEq)]
pub enum JsonOrBytes {
    /// The handle was empty (no bytes at all).
    Empty,
    /// The payload was valid JSON. The value is stored untyped; cast it
    /// with `serde_json::from_value` if you need a concrete type.
    Json(serde_json::Value),
    /// The payload was not JSON (or was not valid UTF-8). The raw bytes
    /// are returned as-is.
    Bytes(Vec<u8>),
}

/// Reads a UTF-8 payload and returns either the JSON value or the raw
/// bytes.
///
/// # Semantics
///
/// | Payload | Result |
/// |---------|--------|
/// | Empty | [`JsonOrBytes::Empty`] |
/// | Valid JSON | [`JsonOrBytes::Json`] |
/// | Valid UTF-8, invalid JSON | [`JsonOrBytes::Bytes`] |
/// | Invalid UTF-8 | [`JsonOrBytes::Bytes`] |
///
/// The handle cursor is advanced past the payload exactly as in
/// [`read_string_bytes`].
///
/// # Errors
///
/// Any read failure from the underlying [`DataHandle`] methods.
pub fn read_json_or_bytes(
    handle: &mut DataHandle,
) -> Result<JsonOrBytes, Error> {
    let bytes = read_until_nul(handle)?;
    if bytes.is_empty() {
        return Ok(JsonOrBytes::Empty);
    }
    match std::str::from_utf8(&bytes) {
        Ok(text) => match serde_json::from_str::<serde_json::Value>(text) {
            Ok(value) => Ok(JsonOrBytes::Json(value)),
            Err(_) => Ok(JsonOrBytes::Bytes(bytes)),
        },
        Err(_) => Ok(JsonOrBytes::Bytes(bytes)),
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use serde::{Deserialize, Serialize};

    // ----------------------------------------------------------------
    // Helper: skip tests when the native library is absent.
    // ----------------------------------------------------------------

    fn try_handle(api: &str) -> Option<DataHandle> {
        match DataHandle::new(api) {
            Ok(h) => Some(h),
            Err(e) if e.code() == ErrorCode::LibraryLoadFailed => {
                eprintln!("[SKIP] native library not available: {}", e);
                None
            }
            Err(e) => panic!("unexpected construction failure: {}", e),
        }
    }

    // ----------------------------------------------------------------
    // JSON string helpers (no handle required).
    // ----------------------------------------------------------------

    #[test]
    fn dumps_json_is_compact() {
        #[derive(Serialize)]
        struct P {
            x: i32,
            y: i32,
        }
        let s = dumps_json(&P { x: 1, y: 2 }).unwrap();
        assert_eq!(s, r#"{"x":1,"y":2}"#);
        assert!(!s.contains('\n'));
    }

    #[test]
    fn dumps_json_preserves_non_ascii_literally() {
        let s = dumps_json(&serde_json::json!({ "msg": "你好 🌍" })).unwrap();
        assert!(s.contains("你好"), "CJK characters must stay literal");
        assert!(s.contains('🌍'), "emoji must stay literal");
        assert!(
            !s.contains("\\u"),
            "no \\uXXXX escape must appear: {}",
            s
        );
    }

    #[test]
    fn loads_json_is_strict() {
        assert!(loads_json::<serde_json::Value>(r#"{"a":1}"#).is_ok());
        assert!(loads_json::<serde_json::Value>("").is_err());
        assert!(loads_json::<serde_json::Value>("not json").is_err());
        // Trailing comma is invalid JSON.
        assert!(loads_json::<serde_json::Value>(r#"{"a":1,}"#).is_err());
    }

    #[test]
    fn json_string_roundtrip_no_handle() {
        let original = serde_json::json!({
            "name": "张三",
            "age": 30,
            "emoji": "🌍"
        });
        let text = dumps_json(&original).unwrap();
        let back: serde_json::Value = loads_json(&text).unwrap();
        assert_eq!(back, original);
    }

    // ----------------------------------------------------------------
    // String / bytes I/O (require a handle).
    // ----------------------------------------------------------------

    #[test]
    fn write_read_string_roundtrip() {
        let Some(mut h) = try_handle("test_io_string") else {
            return;
        };
        write_string(&mut h, "hello, 世界 🌍").unwrap();
        h.set_position(0).unwrap();
        assert_eq!(read_string(&mut h).unwrap(), "hello, 世界 🌍");
    }

    #[test]
    fn empty_string_roundtrip_writes_single_nul() {
        let Some(mut h) = try_handle("test_io_empty") else {
            return;
        };
        write_string(&mut h, "").unwrap();
        assert_eq!(h.size().unwrap(), 1);
        h.set_position(0).unwrap();
        assert_eq!(read_string(&mut h).unwrap(), "");
    }

    #[test]
    fn write_string_bytes_writes_all_bytes_then_framing_nul() {
        let Some(mut h) = try_handle("test_io_bytes_write") else {
            return;
        };
        // A payload with an embedded NUL. The writer preserves every
        // byte verbatim and appends exactly one framing NUL.
        let payload: &[u8] = b"a\0b\0c";
        write_string_bytes(&mut h, payload).unwrap();
        // 5 payload bytes + 1 framing NUL = 6.
        assert_eq!(h.size().unwrap(), 6);

        // Read back with read_all_bytes (raw): the entire buffer is
        // visible, including the embedded NULs and the framing NUL.
        h.set_position(0).unwrap();
        assert_eq!(read_all_bytes(&mut h).unwrap(), b"a\0b\0c\0");
    }

    #[test]
    fn read_string_bytes_stops_at_first_embedded_nul() {
        let Some(mut h) = try_handle("test_io_bytes_read") else {
            return;
        };
        // A payload with an embedded NUL.
        write_string_bytes(&mut h, b"a\0b").unwrap();
        h.set_position(0).unwrap();
        // read_string_bytes is defined as "stop at the first NUL", so
        // the embedded NUL acts as a terminator. Only "a" is returned.
        // This matches Pascal's LF_ReadStringBytes, the C++
        // io::read_string_bytes, the C# LfIo.ReadStringBytes, and the
        // JavaScript lf-io.readStringBytes.
        assert_eq!(read_string_bytes(&mut h).unwrap(), b"a");
    }

    #[test]
    fn peek_does_not_advance() {
        let Some(mut h) = try_handle("test_io_peek") else {
            return;
        };
        write_string(&mut h, "peek-me").unwrap();
        h.set_position(0).unwrap();
        let first = peek_string_bytes(&mut h).unwrap();
        let second = peek_string_bytes(&mut h).unwrap();
        assert_eq!(first, b"peek-me");
        assert_eq!(first, second);
        // The cursor must still be at 0.
        assert_eq!(h.position().unwrap(), 0);
        // A real read now consumes the payload.
        assert_eq!(read_string_bytes(&mut h).unwrap(), b"peek-me");
    }

    #[test]
    fn read_without_nul_consumes_remaining() {
        let Some(mut h) = try_handle("test_io_no_nul") else {
            return;
        };
        // Raw JSON with no trailing NUL.
        h.write_bytes(br#"{"a":1}"#).unwrap();
        h.set_position(0).unwrap();
        assert_eq!(read_string(&mut h).unwrap(), r#"{"a":1}"#);
    }

    #[test]
    fn read_all_bytes_is_raw() {
        let Some(mut h) = try_handle("test_io_all") else {
            return;
        };
        h.write_bytes(&[0x00, 0x01, 0x02, 0xFF]).unwrap();
        h.set_position(0).unwrap();
        assert_eq!(
            read_all_bytes(&mut h).unwrap(),
            vec![0x00, 0x01, 0x02, 0xFF]
        );
    }

    // ----------------------------------------------------------------
    // JSON I/O (require a handle).
    // ----------------------------------------------------------------

    #[derive(Serialize, Deserialize, Debug, PartialEq)]
    struct Pair {
        a: i32,
        b: i32,
    }

    #[test]
    fn json_roundtrip() {
        let Some(mut h) = try_handle("test_io_json") else {
            return;
        };
        let original = Pair { a: 5, b: 7 };
        write_json(&mut h, &original).unwrap();
        h.set_position(0).unwrap();
        let back: Pair = read_json(&mut h).unwrap();
        assert_eq!(back, original);
    }

    #[test]
    fn json_with_unicode_roundtrip() {
        #[derive(Serialize, Deserialize, Debug, PartialEq)]
        struct Msg {
            text: String,
        }
        let Some(mut h) = try_handle("test_io_json_unicode") else {
            return;
        };
        let original = Msg {
            text: "你好, 🌍".to_string(),
        };
        write_json(&mut h, &original).unwrap();

        // Verify the wire bytes contain literal UTF-8 and no \uXXXX.
        h.set_position(0).unwrap();
        let raw = read_string_bytes(&mut h).unwrap();
        let text = std::str::from_utf8(&raw).unwrap();
        assert!(text.contains("你好"));
        assert!(text.contains('🌍'));
        assert!(!text.contains("\\u"));

        h.set_position(0).unwrap();
        let back: Msg = read_json(&mut h).unwrap();
        assert_eq!(back, original);
    }

    #[test]
    fn read_json_rejects_empty() {
        let Some(mut h) = try_handle("test_io_json_empty") else {
            return;
        };
        // An empty payload is a single NUL byte on the wire.
        write_string(&mut h, "").unwrap();
        h.set_position(0).unwrap();
        let err = read_json::<Pair>(&mut h).unwrap_err();
        assert_eq!(err.code(), ErrorCode::ReadFailed);
    }

    #[test]
    fn try_read_json_returns_none_on_garbage() {
        let Some(mut h) = try_handle("test_io_json_bad") else {
            return;
        };
        write_string(&mut h, "not json").unwrap();
        h.set_position(0).unwrap();
        assert!(try_read_json::<Pair>(&mut h).unwrap().is_none());
    }

    #[test]
    fn try_read_json_returns_none_on_type_mismatch() {
        let Some(mut h) = try_handle("test_io_json_mismatch") else {
            return;
        };
        // Valid JSON, wrong shape for Pair.
        write_json(&mut h, &serde_json::json!(["not", "an", "object"])).unwrap();
        h.set_position(0).unwrap();
        assert!(try_read_json::<Pair>(&mut h).unwrap().is_none());
    }

    // ----------------------------------------------------------------
    // read_json_or_bytes (requires a handle).
    // ----------------------------------------------------------------

    #[test]
    fn read_json_or_bytes_empty() {
        let Some(mut h) = try_handle("test_io_variant_empty") else {
            return;
        };
        write_string(&mut h, "").unwrap();
        h.set_position(0).unwrap();
        assert_eq!(read_json_or_bytes(&mut h).unwrap(), JsonOrBytes::Empty);
    }

    #[test]
    fn read_json_or_bytes_json() {
        let Some(mut h) = try_handle("test_io_variant_json") else {
            return;
        };
        write_string(&mut h, r#"{"a":1}"#).unwrap();
        h.set_position(0).unwrap();
        match read_json_or_bytes(&mut h).unwrap() {
            JsonOrBytes::Json(v) => assert_eq!(v["a"], 1),
            other => panic!("expected Json, got {:?}", other),
        }
    }

    #[test]
    fn read_json_or_bytes_raw_on_non_json() {
        let Some(mut h) = try_handle("test_io_variant_raw") else {
            return;
        };
        write_string(&mut h, "hello, world").unwrap();
        h.set_position(0).unwrap();
        match read_json_or_bytes(&mut h).unwrap() {
            JsonOrBytes::Bytes(b) => {
                assert_eq!(b, b"hello, world");
            }
            other => panic!("expected Bytes, got {:?}", other),
        }
    }

    #[test]
    fn read_json_or_bytes_raw_on_invalid_utf8() {
        let Some(mut h) = try_handle("test_io_variant_invalid_utf8") else {
            return;
        };
        // 0xFF is never a valid UTF-8 lead byte.
        write_string_bytes(&mut h, &[0xFF, 0xFE, 0xFD]).unwrap();
        h.set_position(0).unwrap();
        match read_json_or_bytes(&mut h).unwrap() {
            JsonOrBytes::Bytes(b) => assert_eq!(b, vec![0xFF, 0xFE, 0xFD]),
            other => panic!("expected Bytes, got {:?}", other),
        }
    }
}