/**
 * @file lf-io.js
 * @brief Unified JSON and string I/O for LingoFuse data handles.
 *
 * This module is the JavaScript counterpart of `lf_io.hpp` (C++) and
 * `LfIo.cs` (C#). It is the SINGLE place in the JavaScript toolchain
 * where JavaScript values are converted to, and from, the bytes carried
 * by a LingoFuse DataHandle. Every service that touches a DataHandle
 * should use the helpers defined here instead of calling writeBytes /
 * readBytes / JSON.stringify / JSON.parse directly.
 *
 * ============================================================================
 * WIRE FORMAT
 * ============================================================================
 *
 * A JSON payload on a data handle is:
 *
 *     [UTF-8 encoded JSON text][NUL byte]
 *
 * A plain-text payload uses the same framing:
 *
 *     [UTF-8 text][NUL byte]
 *
 * A raw binary payload uses:
 *
 *     [arbitrary bytes][NUL byte]
 *
 * The receiving side (readString / readStringBytes / readJson) is
 * fault-tolerant: if no NUL is found before the end of the buffer, the
 * entire remaining buffer is consumed. This makes the reader tolerant
 * of payloads that arrive from an HTTP bridge or any other producer
 * that does not append a NUL.
 *
 * ============================================================================
 * COMPATIBILITY WITH THE PASCAL / PYTHON / C++ / C# SIDES
 * ============================================================================
 *
 * The framing matches lingofuse_import.pas, lingofuse.lf_io, lf_io.hpp
 * and LfIo.cs exactly. For the logical payload {"a":1}, every binding
 * emits the byte sequence 7B 22 61 22 3A 31 7D 00, and every reader
 * follows the same three-case rule:
 *
 *     Case 1 - a NUL is found:
 *         Return the bytes before it, advance the cursor past the NUL.
 *
 *     Case 2 - no NUL is found:
 *         Return the entire remaining buffer, advance the cursor to
 *         (buffer size + 1). The underlying library implicitly grows
 *         the buffer by one byte to accommodate the new position.
 *
 *     Case 3 - the cursor is at or past the end:
 *         Return an empty result, cursor unchanged.
 *
 * ============================================================================
 * JSON SERIALIZATION POLICY
 * ============================================================================
 *
 * Every JSON string produced by this module goes through `dumps()`.
 * That function is the single source of truth for the serialization
 * policy. Its three properties are:
 *
 *   - Compact output, no indentation, no trailing newline.
 *     JSON.stringify(obj) already produces this by default.
 *
 *   - Non-ASCII characters emitted as literal UTF-8, not as \\uXXXX
 *     escapes. JSON.stringify escapes only control characters, quotes
 *     and backslashes; every other code point stays intact, and the
 *     subsequent TextEncoder emits real UTF-8 bytes. This makes the
 *     output byte-identical to what the Pascal, Python, C++ and C#
 *     producers emit.
 *
 *   - BigInt values are serialized as JSON numbers when they fit into
 *     a double without loss; otherwise they are serialized as JSON
 *     strings to avoid silent truncation. JSON.stringify would throw
 *     on a BigInt without the replacer below.
 *
 * `dumps()` accepts no options. Pretty-printing is deliberately not
 * offered: it would break the byte-for-byte cross-language contract.
 *
 * ============================================================================
 * JSON DESERIALIZATION POLICY
 * ============================================================================
 *
 * `loads()` uses `JSON.parse` with strict semantics. A payload that is
 * not valid JSON throws `LingoFuseIoError`. Callers that need a
 * non-throwing path use `tryReadJson`.
 *
 * Note on large integers: `JSON.parse` produces `Number` for every
 * JSON number. A value that exceeds 2^53 loses precision. Callers that
 * must preserve int64 precision should either negotiate the payload
 * shape with the peer (e.g. send the integer as a string) or read the
 * raw bytes and parse them with a BigInt-aware parser.
 *
 * ============================================================================
 * ERROR HANDLING
 * ============================================================================
 *
 * All failures throw `LingoFuseIoError`. Argument validation errors use
 * the standard JavaScript exceptions (`TypeError`, `RangeError`). The
 * `try*` family returns a tagged result object instead of throwing.
 *
 * ============================================================================
 * DEPENDENCY DIRECTION
 * ============================================================================
 *
 *     binding.js         (raw Koffi declarations)
 *         ^
 *     data-handle.js     (RAII wrapper for TDataHnd)
 *         ^
 *     lf-io.js           (this file - JSON and string contract)
 *         ^
 *     app-handle.js / framework.js / network-events.js
 *
 * This module depends only on data-handle.js. It never touches the
 * native functions directly.
 *
 * ============================================================================
 * USAGE EXAMPLE
 * ============================================================================
 * @code
 * const { DataHandle } = require("./data-handle");
 * const { writeJson, readJson, writeString, readString } = require("./lf-io");
 *
 * // Inside a Call callback:
 * function add(input, output) {
 *     const req = readJson(input);
 *     const a = req.a ?? 0;
 *     const b = req.b ?? 0;
 *     writeJson(output, { result: a + b });
 * }
 * @endcode
 */

"use strict";

const { DataHandle } = require("./data-handle");
const { LingoFuseIoError } = require("./errors");

// ============================================================================
// Constants
// ============================================================================

/**
 * The NUL byte used as the string terminator on the wire.
 */
const NUL_BYTE = 0x00;

/**
 * The UTF-8 codec instances. TextEncoder is stateless; TextDecoder is
 * created with `{ fatal: false }` so that invalid byte sequences become
 * U+FFFD rather than throwing. This matches the "replace" policy used
 * by the C++ (error_handler_t::replace) and C# (UnsafeRelaxedJsonEscaping
 * with the default encoder fallback) bindings.
 */
const UTF8_ENCODER = new TextEncoder();
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: false });

// ============================================================================
// JSON serialization
// ============================================================================

/**
 * A replacer for JSON.stringify that handles BigInt.
 *
 * JSON.stringify has no native support for BigInt and would throw a
 * TypeError. The replacer below serializes a BigInt as:
 *
 *   - a JSON number, when its absolute value is <= Number.MAX_SAFE_INTEGER;
 *   - a JSON string, otherwise.
 *
 * The number branch keeps small integers readable on the wire. The
 * string branch keeps 64-bit values lossless when the peer is expected
 * to parse them explicitly.
 *
 * @param {string} _key
 * @param {*} value
 * @returns {*}
 */
function bigIntReplacer(_key, value) {
    if (typeof value === "bigint") {
        const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);
        const MIN_SAFE = -MAX_SAFE;
        if (value <= MAX_SAFE && value >= MIN_SAFE) {
            return Number(value);
        }
        return value.toString();
    }
    return value;
}

/**
 * Serialize a JavaScript value to a compact UTF-8 JSON string.
 *
 * Policy (single source of truth for the whole JavaScript toolchain):
 *
 *   - Compact output: no indentation, no trailing newline. This is the
 *     default behaviour of JSON.stringify.
 *   - Non-ASCII characters stay literal. JSON.stringify escapes only
 *     control characters, quotes and backslashes; the subsequent
 *     TextEncoder produces real UTF-8 bytes. This makes the output
 *     byte-identical to the Python (ensure_ascii=False) and C#
 *     (UnsafeRelaxedJsonEscaping) producers.
 *   - BigInt values are handled via the replacer described above.
 *
 * The returned string does NOT include a trailing NUL byte. Callers
 * that want to write it to a data handle with the required NUL
 * terminator should use `writeJson` or `writeString` instead.
 *
 * @param {*} value
 *   Any JSON-serializable value, including BigInt. `undefined`,
 *   functions and symbols are dropped when they appear as object
 *   properties and become `null` when they appear as array elements,
 *   exactly as JSON.stringify specifies. A top-level `undefined` is
 *   treated as the JSON literal `null`.
 * @returns {string}
 *   The compact UTF-8 JSON text (as a JavaScript string).
 * @throws {LingoFuseIoError}
 *   When the value cannot be serialized (for example because it
 *   contains a circular reference, or because a top-level function or
 *   symbol was passed).
 */
function dumps(value) {
    try {
        if (value === undefined) {
            return "null";
        }
        const text = JSON.stringify(value, bigIntReplacer);
        if (typeof text !== "string") {
            // JSON.stringify returns undefined for a top-level
            // function or symbol. Treat that as a serialization
            // failure; the C# and C++ bindings reject it at compile
            // time, so this is the closest runtime analogue.
            throw new LingoFuseIoError(
                "lf-io.dumps: value is not JSON-serializable."
            );
        }
        return text;
    } catch (err) {
        if (err instanceof LingoFuseIoError) {
            throw err;
        }
        throw new LingoFuseIoError(
            `lf-io.dumps: JSON serialization failed: ${err.message}`,
            { cause: err }
        );
    }
}

/**
 * Parse a UTF-8 JSON string into a JavaScript value.
 *
 * Strict: any syntax error raises `LingoFuseIoError`. Leading and
 * trailing whitespace is ignored. A UTF-8 BOM is NOT skipped;
 * JSON.parse rejects it. Strip it yourself if you need to accept
 * BOM-prefixed input.
 *
 * @param {string} text  A UTF-8 JSON document.
 * @returns {*}
 * @throws {TypeError} When text is not a string.
 * @throws {LingoFuseIoError} When the text is not valid JSON.
 */
function loads(text) {
    if (typeof text !== "string") {
        throw new TypeError("lf-io.loads: text must be a string.");
    }
    try {
        return JSON.parse(text);
    } catch (err) {
        throw new LingoFuseIoError(
            `lf-io.loads: invalid JSON: ${err.message}`,
            { cause: err }
        );
    }
}

// ============================================================================
// Internal helpers
// ============================================================================

/**
 * Append a NUL byte to a DataHandle.
 *
 * @param {DataHandle} handle
 */
function appendNul(handle) {
    handle.writeUInt8(NUL_BYTE);
}

/**
 * Read bytes from a handle up to the first NUL (or the end of the
 * buffer), and advance the cursor past the NUL (or to size + 1 when no
 * NUL was found).
 *
 * This is the exact behaviour of Pascal's LF_ReadString, the Python
 * lf_io._read_until_nul helper, the C++ io::detail::read_until_nul,
 * and the C# LfIo.ReadStringBytes.
 *
 * The implementation uses only the public DataHandle API. It reads all
 * remaining bytes in a single call, then adjusts the cursor to the
 * exact position mandated by the three-case rule.
 *
 * @param {DataHandle} handle
 * @returns {Uint8Array}
 */
function readUntilNul(handle) {
    const start = handle.position;
    const total = handle.size;

    // Case 3: cursor at or past the end of the buffer.
    if (start >= total) {
        return new Uint8Array(0);
    }

    const remaining = total - start;
    const raw = handle.readBytes(remaining);

    // A defensive guard. handle.readBytes never returns null, but a
    // zero-length read here means the buffer changed under us; treat
    // it as Case 3.
    if (raw.length === 0) {
        return new Uint8Array(0);
    }

    // Scan for the first NUL.
    let nulIndex = -1;
    for (let i = 0; i < raw.length; i++) {
        if (raw[i] === NUL_BYTE) {
            nulIndex = i;
            break;
        }
    }

    if (nulIndex >= 0) {
        // Case 1: a NUL was found. Return the bytes before it, and
        // move the cursor past the NUL.
        const payload = raw.slice(0, nulIndex);
        handle.position = start + nulIndex + 1;
        return payload;
    }

    // Case 2: no NUL was found. Return all consumed bytes, and move
    // the cursor to one byte past the end of the buffer. The native
    // library implicitly grows the buffer by one byte to accommodate
    // the new position, matching Pascal's LF_SetPos(Hnd, e + 1).
    handle.position = start + raw.length + 1;
    return raw;
}

// ============================================================================
// String I/O (NUL-framed UTF-8)
// ============================================================================

/**
 * Write a string as UTF-8 bytes, followed by a NUL terminator.
 *
 * An empty string is written as a single NUL byte, matching Pascal's
 * LF_WriteString('').
 *
 * @param {DataHandle} handle  Target data handle.
 * @param {string} value       UTF-8 text. May be empty.
 * @throws {TypeError} When handle is not a DataHandle or value is not
 *   a string.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 * @throws {LingoFuseIoError} When the native layer writes fewer bytes
 *   than requested.
 */
function writeString(handle, value) {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.writeString: handle must be a DataHandle.");
    }
    if (typeof value !== "string") {
        throw new TypeError("lf-io.writeString: value must be a string.");
    }

    if (value.length > 0) {
        handle.writeBytes(UTF8_ENCODER.encode(value));
    }
    appendNul(handle);
}

/**
 * Read a UTF-8 string from the handle, stopping at the first NUL.
 *
 * If no NUL is present, the entire remaining buffer is consumed.
 * Returns an empty string when the cursor is at or past the end of the
 * buffer, or when the first byte is a NUL.
 *
 * The bytes are decoded with TextDecoder using the default UTF-8
 * replacement policy: invalid sequences become U+FFFD. Callers that
 * need to detect invalid UTF-8 should use `readStringBytes` and
 * inspect the raw bytes.
 *
 * @param {DataHandle} handle  Source data handle.
 * @returns {string}
 * @throws {TypeError} When handle is not a DataHandle.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 */
function readString(handle) {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.readString: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0) {
        return "";
    }
    return UTF8_DECODER.decode(bytes);
}

// ============================================================================
// Byte I/O (NUL-framed raw bytes)
// ============================================================================

/**
 * Write raw bytes followed by a NUL terminator. The bytes are written
 * verbatim; embedded NUL bytes are preserved.
 *
 * Unlike `writeString`, this does NOT stop at embedded NUL bytes; it
 * writes exactly `data.length` bytes and appends one additional NUL.
 *
 * @param {DataHandle} handle  Target data handle.
 * @param {Uint8Array|Buffer} data  Source bytes. May be empty.
 * @throws {TypeError} When handle or data is not the expected type.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 * @throws {LingoFuseIoError} When the native layer writes fewer bytes
 *   than requested.
 */
function writeStringBytes(handle, data) {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.writeStringBytes: handle must be a DataHandle."
        );
    }
    if (!(data instanceof Uint8Array)) {
        throw new TypeError(
            "lf-io.writeStringBytes: data must be a Uint8Array or Buffer."
        );
    }

    if (data.length > 0) {
        handle.writeBytes(data);
    }
    appendNul(handle);
}

/**
 * Read raw bytes from the handle, stopping at the first NUL.
 *
 * Unlike `readAllBytes`, which consumes the entire remaining buffer,
 * this stops at the NUL that `writeString` / `writeJson` append. The
 * bytes are returned undecoded, so the caller can inspect or forward
 * them without a UTF-8 round-trip.
 *
 * This is the accessor to use inside a bridge or proxy that forwards
 * a payload unchanged to a downstream consumer.
 *
 * @param {DataHandle} handle  Source data handle.
 * @returns {Uint8Array}
 * @throws {TypeError} When handle is not a DataHandle.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 */
function readStringBytes(handle) {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.readStringBytes: handle must be a DataHandle."
        );
    }
    return readUntilNul(handle);
}

/**
 * Read all remaining bytes from the handle, without NUL handling. The
 * cursor advances to the end of the buffer.
 *
 * Use this for raw binary payloads; use `readStringBytes` for NUL-
 * terminated text or JSON payloads.
 *
 * @param {DataHandle} handle  Source data handle.
 * @returns {Uint8Array}
 * @throws {TypeError} When handle is not a DataHandle.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 */
function readAllBytes(handle) {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.readAllBytes: handle must be a DataHandle.");
    }
    return handle.readAllBytes();
}

// ============================================================================
// JSON I/O
// ============================================================================

/**
 * Serialize `value` as UTF-8 JSON and write it with a NUL terminator.
 *
 * The serialization goes through `dumps()`, so the compact, non-ASCII-
 * literal policy is guaranteed. The output never contains a \\uXXXX
 * escape for non-ASCII text, and a trailing NUL byte is always
 * appended.
 *
 * @param {DataHandle} handle  Target data handle.
 * @param {*} value            The value to write. `undefined` is
 *   treated as JSON `null`.
 * @throws {TypeError} When handle is not a DataHandle.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 * @throws {LingoFuseIoError} When the value cannot be serialized.
 */
function writeJson(handle, value) {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.writeJson: handle must be a DataHandle.");
    }
    const text = dumps(value);
    writeString(handle, text);
}

/**
 * Read a UTF-8 JSON payload from the handle and return it.
 *
 * The payload may or may not be NUL-terminated. If a NUL is present,
 * it is treated as the end of the payload; otherwise the entire
 * remaining buffer is consumed.
 *
 * Returns `null` when the buffer contains no bytes at all. This
 * matches the historical convention of the toolchain: an empty payload
 * means "no result". Note that a JSON `null` (the four bytes `null`)
 * also decodes to `null`; callers that need to distinguish the two
 * must inspect the raw buffer themselves via `readStringBytes`.
 *
 * @param {DataHandle} handle  Source data handle.
 * @returns {*}
 * @throws {TypeError} When handle is not a DataHandle.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 * @throws {LingoFuseIoError} When the bytes are not valid JSON.
 */
function readJson(handle) {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.readJson: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0) {
        return null;
    }
    const text = UTF8_DECODER.decode(bytes);
    return loads(text);
}

/**
 * Non-throwing counterpart of `readJson`.
 *
 * The cursor is advanced regardless of whether the payload parses
 * successfully; this matches the historical behaviour of the C# and
 * C++ wrappers, and it is the only sensible choice for a probe.
 *
 * @param {DataHandle} handle  Source data handle.
 * @returns {{ ok: true, value: * } | { ok: false }}
 * @throws {TypeError} When handle is not a DataHandle.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 */
function tryReadJson(handle) {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.tryReadJson: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0) {
        return { ok: false };
    }
    const text = UTF8_DECODER.decode(bytes);
    try {
        return { ok: true, value: JSON.parse(text) };
    } catch (_) {
        return { ok: false };
    }
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
    // Constants
    NUL_BYTE,

    // JSON helpers (raw string <-> value)
    dumps,
    loads,

    // String I/O (NUL-framed UTF-8)
    writeString,
    readString,

    // Byte I/O (NUL-framed raw bytes)
    writeStringBytes,
    readStringBytes,
    readAllBytes,

    // JSON I/O (NUL-framed JSON)
    writeJson,
    readJson,
    tryReadJson,
};