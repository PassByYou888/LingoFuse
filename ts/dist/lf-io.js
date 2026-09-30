"use strict";
// =============================================================================
//  lf-io.ts
// -----------------------------------------------------------------------------
//  Unified JSON and string I/O for LingoFuse data handles.
//
//  This module is the single place in the TypeScript toolchain where
//  JavaScript values are converted to and from the bytes carried by a
//  DataHandle. Every service should use these helpers instead of
//  calling writeBytes / readBytes / JSON.stringify / JSON.parse
//  directly.
//
//  Wire format:
//      JSON payload       : UTF-8 JSON text + NUL byte
//      Plain-text payload : UTF-8 text + NUL byte
//      Raw binary payload : arbitrary bytes + NUL byte
//
//  Serialization policy (mirrors lf_io.hpp):
//      compact output, no indentation
//      literal UTF-8 for non-ASCII characters
//      BigInt handled via a replacer (small values as JSON numbers,
//      large values as JSON strings)
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.tryReadJson = exports.readJson = exports.writeJson = exports.readAllBytes = exports.readStringBytes = exports.writeStringBytes = exports.readString = exports.writeString = exports.loads = exports.dumps = void 0;
const data_handle_1 = require("./data-handle");
const errors_1 = require("./errors");
const NUL_BYTE = 0x00;
const UTF8_ENCODER = new TextEncoder();
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: false });
// -----------------------------------------------------------------------------
//  JSON serialization
// -----------------------------------------------------------------------------
/**
 * A replacer for JSON.stringify that handles BigInt. Small BigInt
 * values become JSON numbers; values exceeding the safe integer range
 * become JSON strings to avoid silent truncation.
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
/** Serialize a value to a compact UTF-8 JSON string. */
function dumps(value) {
    try {
        if (value === undefined)
            return "null";
        const text = JSON.stringify(value, bigIntReplacer);
        if (typeof text !== "string") {
            throw new errors_1.LingoFuseIoError("lf-io.dumps: value is not JSON-serializable.");
        }
        return text;
    }
    catch (err) {
        if (err instanceof errors_1.LingoFuseIoError)
            throw err;
        const detail = err instanceof Error ? err.message : String(err);
        throw new errors_1.LingoFuseIoError(`lf-io.dumps: JSON serialization failed: ${detail}`, { cause: err });
    }
}
exports.dumps = dumps;
/** Parse a UTF-8 JSON string. Throws LingoFuseIoError on failure. */
function loads(text) {
    if (typeof text !== "string") {
        throw new TypeError("lf-io.loads: text must be a string.");
    }
    try {
        return JSON.parse(text);
    }
    catch (err) {
        const detail = err instanceof Error ? err.message : String(err);
        throw new errors_1.LingoFuseIoError(`lf-io.loads: invalid JSON: ${detail}`, { cause: err });
    }
}
exports.loads = loads;
// -----------------------------------------------------------------------------
//  String I/O
// -----------------------------------------------------------------------------
/** Write a UTF-8 string followed by a NUL terminator. */
function writeString(handle, value) {
    if (!(handle instanceof data_handle_1.DataHandle)) {
        throw new TypeError("lf-io.writeString: handle must be a DataHandle.");
    }
    if (typeof value !== "string") {
        throw new TypeError("lf-io.writeString: value must be a string.");
    }
    if (value.length > 0) {
        handle.writeBytes(UTF8_ENCODER.encode(value));
    }
    handle.writeBytes(Uint8Array.of(NUL_BYTE));
}
exports.writeString = writeString;
/** Read a UTF-8 string, stopping at the first NUL. */
function readString(handle) {
    if (!(handle instanceof data_handle_1.DataHandle)) {
        throw new TypeError("lf-io.readString: handle must be a DataHandle.");
    }
    return handle.readString();
}
exports.readString = readString;
// -----------------------------------------------------------------------------
//  Byte I/O
// -----------------------------------------------------------------------------
/** Write raw bytes followed by a NUL terminator. Embedded NULs preserved. */
function writeStringBytes(handle, data) {
    if (!(handle instanceof data_handle_1.DataHandle)) {
        throw new TypeError("lf-io.writeStringBytes: handle must be a DataHandle.");
    }
    if (!(data instanceof Uint8Array)) {
        throw new TypeError("lf-io.writeStringBytes: data must be a Uint8Array.");
    }
    if (data.length > 0)
        handle.writeBytes(data);
    handle.writeBytes(Uint8Array.of(NUL_BYTE));
}
exports.writeStringBytes = writeStringBytes;
/** Read raw bytes up to the first NUL. */
function readStringBytes(handle) {
    if (!(handle instanceof data_handle_1.DataHandle)) {
        throw new TypeError("lf-io.readStringBytes: handle must be a DataHandle.");
    }
    return readUntilNul(handle);
}
exports.readStringBytes = readStringBytes;
/** Read all remaining bytes without NUL handling. */
function readAllBytes(handle) {
    if (!(handle instanceof data_handle_1.DataHandle)) {
        throw new TypeError("lf-io.readAllBytes: handle must be a DataHandle.");
    }
    return handle.readAllBytes();
}
exports.readAllBytes = readAllBytes;
// -----------------------------------------------------------------------------
//  JSON I/O
// -----------------------------------------------------------------------------
/** Serialize a value as UTF-8 JSON and write it with a NUL terminator. */
function writeJson(handle, value) {
    if (!(handle instanceof data_handle_1.DataHandle)) {
        throw new TypeError("lf-io.writeJson: handle must be a DataHandle.");
    }
    const text = dumps(value);
    writeString(handle, text);
}
exports.writeJson = writeJson;
/**
 * Read a NUL-framed JSON payload and deserialize it.
 *
 * Returns `null` when the payload is empty. A JSON literal `null`
 * (the four bytes "null") also decodes to `null`; use readStringBytes
 * if the two must be distinguished.
 */
function readJson(handle) {
    if (!(handle instanceof data_handle_1.DataHandle)) {
        throw new TypeError("lf-io.readJson: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0)
        return null;
    const text = UTF8_DECODER.decode(bytes);
    return loads(text);
}
exports.readJson = readJson;
/** Non-throwing counterpart of readJson. */
function tryReadJson(handle) {
    if (!(handle instanceof data_handle_1.DataHandle)) {
        throw new TypeError("lf-io.tryReadJson: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0)
        return { ok: false };
    const text = UTF8_DECODER.decode(bytes);
    try {
        return { ok: true, value: JSON.parse(text) };
    }
    catch {
        return { ok: false };
    }
}
exports.tryReadJson = tryReadJson;
// -----------------------------------------------------------------------------
//  Internal helpers
// -----------------------------------------------------------------------------
/**
 * Read bytes up to the first NUL (or the end of the buffer). The
 * cursor advances past the NUL, or to (size + 1) when none was found.
 */
function readUntilNul(handle) {
    const start = handle.position;
    const total = handle.size;
    if (start >= total)
        return new Uint8Array(0);
    const remaining = total - start;
    const raw = handle.readBytes(remaining);
    if (raw.length === 0)
        return new Uint8Array(0);
    let nulIndex = -1;
    for (let i = 0; i < raw.length; i++) {
        if (raw[i] === NUL_BYTE) {
            nulIndex = i;
            break;
        }
    }
    if (nulIndex >= 0) {
        const payload = raw.slice(0, nulIndex);
        handle.position = start + nulIndex + 1;
        return payload;
    }
    // No NUL found: consume everything, move cursor to size + 1.
    handle.position = start + raw.length + 1;
    return raw;
}
//# sourceMappingURL=lf-io.js.map