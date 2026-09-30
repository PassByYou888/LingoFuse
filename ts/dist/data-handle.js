"use strict";
// =============================================================================
//  data-handle.ts
// -----------------------------------------------------------------------------
//  RAII wrapper around a native TDataHnd.
//
//  Owns a native data handle and releases it deterministically on
//  dispose(). Provides byte-level, atomic-type, and NUL-framed string
//  I/O on top of the underlying buffer.
//
//  Ownership:
//      owning     created by the public constructor; dispose() calls
//                 LF_FreeData on the native handle.
//      borrowing  created by fromRaw(raw, false); dispose() is a no-op;
//                 the native layer owns the underlying resource.
//
//  String contract:
//      writeString always appends a single trailing NUL byte.
//      readString is fault-tolerant: it reads until the first NUL, or
//      all remaining bytes when no NUL is present. The cursor advances
//      past the NUL, or to (size + 1) when none was found.
//
//  Numeric contract:
//      The 64-bit writers accept both `number` and `bigint`. A `number`
//      argument must be a finite integer; any other numeric value
//      raises a RangeError whose message names the failing setter or
//      writer, so that a stack trace with several nested calls still
//      pinpoints the actual source.
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.DataHandle = void 0;
const binding_1 = require("./binding");
const errors_1 = require("./errors");
/** Convert a Koffi int64 result to a plain Number. */
function toNumber(v) {
    return typeof v === "bigint" ? Number(v) : v;
}
/**
 * Convert a plain Number or BigInt to BigInt for a Koffi int64 argument.
 *
 * A BigInt is returned unchanged. A Number must be a finite integer;
 * any other numeric value raises a RangeError whose message includes
 * the caller-supplied context string. This makes it possible to
 * identify the failing operation even when multiple wrappers are on
 * the stack.
 *
 * @param v        The value to convert.
 * @param context  Short identifier of the calling operation, included
 *                 in the error message (e.g. "DataHandle.position").
 */
function toBigInt(v, context) {
    if (typeof v === "bigint")
        return v;
    if (typeof v !== "number") {
        throw new TypeError(`${context}: value must be a number or a bigint.`);
    }
    if (!Number.isFinite(v)) {
        throw new RangeError(`${context}: value must be a finite number, got ${v}.`);
    }
    if (!Number.isInteger(v)) {
        throw new RangeError(`${context}: value must be an integer, got ${v}.`);
    }
    return BigInt(v);
}
/** Shared NUL byte buffer for empty string writes. */
const NULL_BYTE = Uint8Array.of(0);
const UTF8_ENCODER = new TextEncoder();
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: false });
class DataHandle {
    #binding;
    #handle;
    #owned;
    #disposed;
    /**
     * Create a new data handle bound to the given API name. The
     * underlying buffer starts empty.
     *
     * @throws {LingoFuseError} When the native library fails to
     *         allocate the handle.
     */
    constructor(apiName, internal) {
        const binding = (0, binding_1.getBinding)();
        this.#binding = binding;
        this.#disposed = false;
        if (internal !== undefined) {
            this.#handle = internal.handle;
            this.#owned = internal.owned;
            return;
        }
        if (typeof apiName !== "string") {
            throw new TypeError("DataHandle: apiName must be a string.");
        }
        this.#owned = true;
        const raw = binding.funcs.LF_CreateData(apiName);
        if (raw === null || raw === undefined) {
            throw new errors_1.LingoFuseError(`Failed to create a data handle for API '${apiName}'.`, errors_1.ErrorCode.Generic);
        }
        this.#handle = raw;
    }
    /** Wrap an existing raw handle. For internal use. */
    static fromRaw(raw, owned) {
        return new DataHandle("", { handle: raw, owned: Boolean(owned) });
    }
    /** Raw native pointer. Null after an owning handle has been disposed. */
    get raw() {
        return this.#handle;
    }
    /** True while the handle is valid and usable. */
    get isValid() {
        return !this.#disposed && this.#handle !== null && this.#handle !== undefined;
    }
    /** True when this instance owns the native handle. */
    get isOwning() {
        return this.#owned;
    }
    /**
     * Release the native handle when ownership applies.
     *
     * Owning handles: calls LF_FreeData, sets the disposed flag
     * (subsequent operations throw), and is idempotent. Borrowing
     * handles: no-op.
     */
    dispose() {
        if (this.#disposed)
            return;
        if (!this.#owned)
            return;
        this.#disposed = true;
        const handle = this.#handle;
        this.#handle = null;
        if (handle !== null && handle !== undefined) {
            this.#binding.funcs.LF_FreeData(handle);
        }
    }
    // ---- Position and size ----
    get position() {
        this.#ensureNotDisposed();
        return toNumber(this.#binding.funcs.LF_GetPos(this.#handle));
    }
    set position(value) {
        if (typeof value === "bigint" ? value < 0n : value < 0) {
            throw new RangeError("DataHandle.position: value must be non-negative.");
        }
        this.#ensureNotDisposed();
        this.#binding.funcs.LF_SetPos(this.#handle, toBigInt(value, "DataHandle.position"));
    }
    get size() {
        this.#ensureNotDisposed();
        return toNumber(this.#binding.funcs.LF_GetSize(this.#handle));
    }
    set size(value) {
        if (typeof value === "bigint" ? value < 0n : value < 0) {
            throw new RangeError("DataHandle.size: value must be non-negative.");
        }
        this.#ensureNotDisposed();
        this.#binding.funcs.LF_SetSize(this.#handle, toBigInt(value, "DataHandle.size"));
    }
    /** Native pointer to the internal buffer. Do not free. */
    getBufferPointer() {
        this.#ensureNotDisposed();
        return this.#binding.funcs.LF_GetBuffer(this.#handle);
    }
    // ---- Byte I/O ----
    /**
     * Append bytes at the current cursor. Throws on a short write,
     * symmetrically with readBytesExact.
     */
    writeBytes(data) {
        if (!(data instanceof Uint8Array)) {
            throw new TypeError("DataHandle.writeBytes: data must be a Uint8Array.");
        }
        this.#ensureNotDisposed();
        if (data.length === 0)
            return 0;
        const written = toNumber(this.#binding.funcs.LF_WriteBuffer(this.#handle, data, data.length));
        if (written !== data.length) {
            throw new errors_1.LingoFuseIoError(`writeBytes requested ${data.length} bytes but only ${written} were written.`, { operation: "writeBytes" });
        }
        return written;
    }
    /** Read up to count bytes. Returns fewer bytes at end-of-buffer. */
    readBytes(count) {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();
        if (count === 0)
            return new Uint8Array(0);
        const buffer = new Uint8Array(count);
        const got = toNumber(this.#binding.funcs.LF_ReadBuffer(this.#handle, buffer, count));
        if (got === count)
            return buffer;
        if (got <= 0)
            return new Uint8Array(0);
        return buffer.slice(0, got);
    }
    /** Read exactly count bytes. Throws on a short read. */
    readBytesExact(count) {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();
        if (count === 0)
            return new Uint8Array(0);
        const savedPos = this.position;
        const buffer = this.readBytes(count);
        if (buffer.length !== count) {
            this.position = savedPos;
            throw new errors_1.LingoFuseIoError(`readBytesExact requested ${count} bytes but only ${buffer.length} were available.`, { operation: "readBytesExact" });
        }
        return buffer;
    }
    /** Non-throwing counterpart of readBytesExact. */
    tryReadBytes(count) {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();
        if (count === 0)
            return { ok: true, value: new Uint8Array(0) };
        const savedPos = this.position;
        const buffer = this.readBytes(count);
        if (buffer.length !== count) {
            this.position = savedPos;
            return { ok: false };
        }
        return { ok: true, value: buffer };
    }
    /** Read every remaining byte. Cursor advances to the end. */
    readAllBytes() {
        this.#ensureNotDisposed();
        const pos = this.position;
        const total = this.size;
        if (pos >= total)
            return new Uint8Array(0);
        return this.readBytes(total - pos);
    }
    // ---- Atomic write helpers (little-endian) ----
    writeInt8(value) {
        this.writeBytes(Uint8Array.of(value & 0xff));
    }
    writeUInt8(value) {
        this.writeBytes(Uint8Array.of(value & 0xff));
    }
    writeInt16(value) {
        const b = new Uint8Array(2);
        new DataView(b.buffer).setInt16(0, value, true);
        this.writeBytes(b);
    }
    writeUInt16(value) {
        const b = new Uint8Array(2);
        new DataView(b.buffer).setUint16(0, value, true);
        this.writeBytes(b);
    }
    writeInt32(value) {
        const b = new Uint8Array(4);
        new DataView(b.buffer).setInt32(0, value, true);
        this.writeBytes(b);
    }
    writeUInt32(value) {
        const b = new Uint8Array(4);
        new DataView(b.buffer).setUint32(0, value, true);
        this.writeBytes(b);
    }
    writeInt64(value) {
        const b = new Uint8Array(8);
        new DataView(b.buffer).setBigInt64(0, toBigInt(value, "DataHandle.writeInt64"), true);
        this.writeBytes(b);
    }
    writeUInt64(value) {
        const b = new Uint8Array(8);
        new DataView(b.buffer).setBigUint64(0, toBigInt(value, "DataHandle.writeUInt64"), true);
        this.writeBytes(b);
    }
    writeSingle(value) {
        const b = new Uint8Array(4);
        new DataView(b.buffer).setFloat32(0, value, true);
        this.writeBytes(b);
    }
    writeDouble(value) {
        const b = new Uint8Array(8);
        new DataView(b.buffer).setFloat64(0, value, true);
        this.writeBytes(b);
    }
    // ---- Atomic read helpers (little-endian, exact) ----
    readInt8() {
        const b = this.readBytesExact(1);
        return (b[0] << 24) >> 24;
    }
    readUInt8() {
        return this.readBytesExact(1)[0];
    }
    readInt16() {
        const b = this.readBytesExact(2);
        return new DataView(b.buffer, b.byteOffset, 2).getInt16(0, true);
    }
    readUInt16() {
        const b = this.readBytesExact(2);
        return new DataView(b.buffer, b.byteOffset, 2).getUint16(0, true);
    }
    readInt32() {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getInt32(0, true);
    }
    readUInt32() {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getUint32(0, true);
    }
    readInt64() {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getBigInt64(0, true);
    }
    readUInt64() {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getBigUint64(0, true);
    }
    readSingle() {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getFloat32(0, true);
    }
    readDouble() {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getFloat64(0, true);
    }
    // ---- NUL-framed string I/O ----
    /**
     * Write a string as UTF-8, followed by a single NUL byte. An empty
     * string writes exactly one byte (the NUL).
     */
    writeString(value) {
        if (typeof value !== "string") {
            throw new TypeError("DataHandle.writeString: value must be a string.");
        }
        this.#ensureNotDisposed();
        const utf8 = UTF8_ENCODER.encode(value);
        if (utf8.length > 0)
            this.writeBytes(utf8);
        this.writeBytes(NULL_BYTE);
    }
    /**
     * Read a UTF-8 string, stopping at the first NUL. If no NUL is
     * found, all remaining bytes are consumed and returned. Invalid
     * UTF-8 sequences are decoded with U+FFFD.
     */
    readString() {
        this.#ensureNotDisposed();
        const start = this.position;
        const total = this.size;
        if (start >= total)
            return "";
        const remaining = total - start;
        const raw = new Uint8Array(remaining);
        const got = toNumber(this.#binding.funcs.LF_ReadBuffer(this.#handle, raw, remaining));
        if (got <= 0)
            return "";
        let nulIndex = -1;
        for (let i = 0; i < got; i++) {
            if (raw[i] === 0) {
                nulIndex = i;
                break;
            }
        }
        let payload;
        let newPos;
        if (nulIndex >= 0) {
            payload = raw.subarray(0, nulIndex);
            newPos = start + nulIndex + 1;
        }
        else {
            payload = raw.subarray(0, got);
            newPos = start + got + 1;
        }
        this.position = newPos;
        return UTF8_DECODER.decode(payload);
    }
    /** Non-throwing counterpart of readString. */
    tryReadString() {
        this.#ensureNotDisposed();
        const start = this.position;
        const total = this.size;
        if (start >= total)
            return { ok: false };
        return { ok: true, value: this.readString() };
    }
    // ---- Internal ----
    #ensureNotDisposed() {
        if (this.#disposed || this.#handle === null || this.#handle === undefined) {
            throw new errors_1.LingoFuseObjectDisposedError("DataHandle");
        }
    }
}
exports.DataHandle = DataHandle;
//# sourceMappingURL=data-handle.js.map