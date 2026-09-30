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

import { DataHandle } from "./data-handle";
import { LingoFuseIoError } from "./errors";

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
function bigIntReplacer(_key: string, value: unknown): unknown {
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
export function dumps(value: unknown): string {
    try {
        if (value === undefined) return "null";
        const text = JSON.stringify(value, bigIntReplacer);
        if (typeof text !== "string") {
            throw new LingoFuseIoError(
                "lf-io.dumps: value is not JSON-serializable.");
        }
        return text;
    } catch (err) {
        if (err instanceof LingoFuseIoError) throw err;
        const detail = err instanceof Error ? err.message : String(err);
        throw new LingoFuseIoError(
            `lf-io.dumps: JSON serialization failed: ${detail}`,
            { cause: err });
    }
}

/** Parse a UTF-8 JSON string. Throws LingoFuseIoError on failure. */
export function loads<T = unknown>(text: string): T {
    if (typeof text !== "string") {
        throw new TypeError("lf-io.loads: text must be a string.");
    }
    try {
        return JSON.parse(text) as T;
    } catch (err) {
        const detail = err instanceof Error ? err.message : String(err);
        throw new LingoFuseIoError(
            `lf-io.loads: invalid JSON: ${detail}`,
            { cause: err });
    }
}

// -----------------------------------------------------------------------------
//  String I/O
// -----------------------------------------------------------------------------

/** Write a UTF-8 string followed by a NUL terminator. */
export function writeString(handle: DataHandle, value: string): void {
    if (!(handle instanceof DataHandle)) {
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

/** Read a UTF-8 string, stopping at the first NUL. */
export function readString(handle: DataHandle): string {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.readString: handle must be a DataHandle.");
    }
    return handle.readString();
}

// -----------------------------------------------------------------------------
//  Byte I/O
// -----------------------------------------------------------------------------

/** Write raw bytes followed by a NUL terminator. Embedded NULs preserved. */
export function writeStringBytes(handle: DataHandle, data: Uint8Array): void {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.writeStringBytes: handle must be a DataHandle.");
    }
    if (!(data instanceof Uint8Array)) {
        throw new TypeError("lf-io.writeStringBytes: data must be a Uint8Array.");
    }
    if (data.length > 0) handle.writeBytes(data);
    handle.writeBytes(Uint8Array.of(NUL_BYTE));
}

/** Read raw bytes up to the first NUL. */
export function readStringBytes(handle: DataHandle): Uint8Array {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.readStringBytes: handle must be a DataHandle.");
    }
    return readUntilNul(handle);
}

/** Read all remaining bytes without NUL handling. */
export function readAllBytes(handle: DataHandle): Uint8Array {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.readAllBytes: handle must be a DataHandle.");
    }
    return handle.readAllBytes();
}

// -----------------------------------------------------------------------------
//  JSON I/O
// -----------------------------------------------------------------------------

/** Serialize a value as UTF-8 JSON and write it with a NUL terminator. */
export function writeJson(handle: DataHandle, value: unknown): void {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.writeJson: handle must be a DataHandle.");
    }
    const text = dumps(value);
    writeString(handle, text);
}

/**
 * Read a NUL-framed JSON payload and deserialize it.
 *
 * Returns `null` when the payload is empty. A JSON literal `null`
 * (the four bytes "null") also decodes to `null`; use readStringBytes
 * if the two must be distinguished.
 */
export function readJson<T = unknown>(handle: DataHandle): T | null {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.readJson: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0) return null;
    const text = UTF8_DECODER.decode(bytes);
    return loads<T>(text);
}

/** Non-throwing counterpart of readJson. */
export function tryReadJson<T = unknown>(
    handle: DataHandle,
): { ok: true; value: T | null } | { ok: false } {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError("lf-io.tryReadJson: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0) return { ok: false };
    const text = UTF8_DECODER.decode(bytes);
    try {
        return { ok: true, value: JSON.parse(text) as T };
    } catch {
        return { ok: false };
    }
}

// -----------------------------------------------------------------------------
//  Internal helpers
// -----------------------------------------------------------------------------

/**
 * Read bytes up to the first NUL (or the end of the buffer). The
 * cursor advances past the NUL, or to (size + 1) when none was found.
 */
function readUntilNul(handle: DataHandle): Uint8Array {
    const start = handle.position;
    const total = handle.size;
    if (start >= total) return new Uint8Array(0);

    const remaining = total - start;
    const raw = handle.readBytes(remaining);
    if (raw.length === 0) return new Uint8Array(0);

    let nulIndex = -1;
    for (let i = 0; i < raw.length; i++) {
        if (raw[i] === NUL_BYTE) { nulIndex = i; break; }
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