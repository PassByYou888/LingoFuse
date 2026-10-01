// =============================================================================
//  data-handle.ts
// -----------------------------------------------------------------------------
//  RAII wrapper around a native TDataHnd.
//
//  Owns a native data handle and releases it deterministically on
//  dispose(). Provides byte-level, atomic-type, and NUL-framed string
//  I/O on top of the underlying buffer.
//
//  Two kinds of handles:
//
//      AUTO-RECYCLED  created by the public constructor
//          - Backed by LF_CreateData.
//          - Added to the library's idle pool.
//          - The pool scans every 5 seconds and frees any handle idle
//            (no accessor call) for more than 10 minutes.
//          - dispose() only marks the handle as deleted; the actual
//            release happens on the next pool scan (at most 5 seconds
//            later).
//          - Recommended for the vast majority of use cases.
//
//      PERMANENT      created by DataHandle.createPermanent()
//          - Backed by LF_CreateData_Permanent.
//          - NOT added to the library's idle pool.
//          - The automatic idle-timeout reclaimer will NEVER free it,
//            no matter how long it has been idle.
//          - dispose() releases it IMMEDIATELY (synchronously).
//          - Recommended for handles that must survive for the entire
//            process lifetime (cached request templates, long-lived
//            scratch buffers, global registries).
//
//  Both kinds are released by framework.shutdown() when the process
//  terminates, and both kinds must be explicitly disposed to avoid
//  leaks.
//
//  Ownership:
//      owning     created by the public constructor or by
//                 createPermanent(); dispose() calls LF_FreeData on
//                 the native handle.
//      borrowing  created by fromRaw(raw, false); dispose() is a
//                 no-op; the native layer owns the underlying
//                 resource and releases it when the callback returns.
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

import type { TDataHnd } from "./types";
import type { Binding } from "./binding";
import { getBinding } from "./binding";
import {
    LingoFuseError,
    LingoFuseIoError,
    LingoFuseObjectDisposedError,
    ErrorCode,
} from "./errors";

/** Convert a Koffi int64 result to a plain Number. */
function toNumber(v: number | bigint): number {
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
function toBigInt(v: number | bigint, context: string): bigint {
    if (typeof v === "bigint") return v;

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

export class DataHandle {
    #binding: Binding;
    #handle: TDataHnd | null;
    #owned: boolean;
    #disposed: boolean;

    /**
     * Create a new AUTO-RECYCLED data handle bound to the given API
     * name. The underlying buffer starts empty.
     *
     * The handle is added to the library's idle pool. The pool frees
     * it after 10 minutes of idle time (scanned every 5 seconds).
     *
     * The optional `internal` argument is an implementation detail
     * used by the static factories fromRaw() and createPermanent().
     * User code must never pass it.
     *
     * @throws {LingoFuseError} When the native library fails to
     *         allocate the handle.
     */
    public constructor(
        apiName: string,
        internal?: { handle: TDataHnd; owned: boolean },
    ) {
        const binding = getBinding();
        this.#binding = binding;
        this.#disposed = false;

        // Internal construction path: wrap an existing native handle.
        if (internal !== undefined) {
            this.#handle = internal.handle;
            this.#owned = internal.owned;
            return;
        }

        // Public construction path: allocate a new auto-recycled handle.
        if (typeof apiName !== "string") {
            throw new TypeError("DataHandle: apiName must be a string.");
        }
        this.#owned = true;

        const raw = binding.funcs.LF_CreateData(apiName);
        if (raw === null || raw === undefined) {
            throw new LingoFuseError(
                `Failed to create a data handle for API '${apiName}'.`,
                ErrorCode.Generic,
            );
        }
        this.#handle = raw;
    }

    /**
     * Wrap an existing raw handle. For internal use.
     *
     * @param raw    Raw pointer value as returned by the native layer.
     * @param owned  When true, dispose() will call LF_FreeData. When
     *               false, dispose() is a no-op and the native layer
     *               retains ownership.
     */
    public static fromRaw(raw: TDataHnd, owned: boolean): DataHandle {
        return new DataHandle("", { handle: raw, owned: Boolean(owned) });
    }

    /**
     * Create a new PERMANENT data handle bound to the given API name.
     *
     * The underlying handle is created with LF_CreateData_Permanent.
     *
     * Difference from the regular constructor:
     *   - NOT added to the library's idle pool.
     *   - The automatic idle-timeout reclaimer will NEVER free it,
     *     no matter how long it has been idle.
     *   - On dispose(), LF_FreeData releases it IMMEDIATELY
     *     (synchronously), rather than marking it for a later pool
     *     scan.
     *
     * When to use:
     *   - Handles that must survive for the entire lifetime of the
     *     process, or for an unbounded period (cached request
     *     templates, long-lived scratch buffers, global registries).
     *
     * When NOT to use:
     *   - Short-lived or one-shot handles. Use the regular constructor
     *     for those, so the pool can reclaim any handle you forget to
     *     dispose.
     *
     * [PITFALL - NO-OP WINDOW]
     *   The underlying LF_FreeData is a no-op while the simulated main
     *   thread is not active (before framework.prepareDone() or after
     *   framework.exitMainThread()). Permanent handles created in that
     *   window stay allocated until the process terminates, or until
     *   framework.shutdown() runs.
     *
     * [PITFALL - LIFETIME]
     *   "Permanent" means "not automatically reclaimed", NOT "never
     *   released". You are fully responsible for calling dispose().
     *   Losing the reference leaks the handle for the lifetime of the
     *   process.
     *
     * @throws {TypeError} When apiName is not a string.
     * @throws {LingoFuseError} When the native library fails to
     *         allocate the handle.
     */
    public static createPermanent(apiName: string): DataHandle {
        if (typeof apiName !== "string") {
            throw new TypeError(
                "DataHandle.createPermanent: apiName must be a string.");
        }
        const binding = getBinding();
        const raw = binding.funcs.LF_CreateData_Permanent(apiName);
        if (raw === null || raw === undefined) {
            throw new LingoFuseError(
                `Failed to create a permanent data handle for API '${apiName}'.`,
                ErrorCode.Generic,
            );
        }
        return new DataHandle("", { handle: raw, owned: true });
    }

    /** Raw native pointer. Null after an owning handle has been disposed. */
    public get raw(): TDataHnd | null {
        return this.#handle;
    }

    /** True while the handle is valid and usable. */
    public get isValid(): boolean {
        return !this.#disposed && this.#handle !== null && this.#handle !== undefined;
    }

    /** True when this instance owns the native handle. */
    public get isOwning(): boolean {
        return this.#owned;
    }

    /**
     * Release the native handle when ownership applies.
     *
     * Owning auto-recycled handles (created by the public constructor):
     * LF_FreeData marks the handle for release; the actual release
     * happens on the next idle-pool scan (at most 5 seconds later).
     *
     * Owning permanent handles (created by createPermanent): LF_FreeData
     * releases the record synchronously.
     *
     * Borrowing handles: dispose() is a no-op. The wrapper state is
     * unchanged, so a callback body that accidentally calls dispose()
     * can still read the input handle for the rest of its execution.
     *
     * Idempotent.
     */
    public dispose(): void {
        if (this.#disposed) return;
        if (!this.#owned) return;

        this.#disposed = true;
        const handle = this.#handle;
        this.#handle = null;

        if (handle !== null && handle !== undefined) {
            this.#binding.funcs.LF_FreeData(handle);
        }
    }

    // ---- Position and size ----

    public get position(): number {
        this.#ensureNotDisposed();
        return toNumber(this.#binding.funcs.LF_GetPos(this.#handle));
    }

    public set position(value: number | bigint) {
        if (typeof value === "bigint" ? value < 0n : value < 0) {
            throw new RangeError("DataHandle.position: value must be non-negative.");
        }
        this.#ensureNotDisposed();
        this.#binding.funcs.LF_SetPos(
            this.#handle, toBigInt(value, "DataHandle.position"));
    }

    public get size(): number {
        this.#ensureNotDisposed();
        return toNumber(this.#binding.funcs.LF_GetSize(this.#handle));
    }

    public set size(value: number | bigint) {
        if (typeof value === "bigint" ? value < 0n : value < 0) {
            throw new RangeError("DataHandle.size: value must be non-negative.");
        }
        this.#ensureNotDisposed();
        this.#binding.funcs.LF_SetSize(
            this.#handle, toBigInt(value, "DataHandle.size"));
    }

    /** Native pointer to the internal buffer. Do not free. */
    public getBufferPointer(): unknown {
        this.#ensureNotDisposed();
        return this.#binding.funcs.LF_GetBuffer(this.#handle);
    }

    // ---- Byte I/O ----

    /**
     * Append bytes at the current cursor. Throws on a short write,
     * symmetrically with readBytesExact.
     */
    public writeBytes(data: Uint8Array): number {
        if (!(data instanceof Uint8Array)) {
            throw new TypeError("DataHandle.writeBytes: data must be a Uint8Array.");
        }
        this.#ensureNotDisposed();
        if (data.length === 0) return 0;

        const written = toNumber(
            this.#binding.funcs.LF_WriteBuffer(this.#handle, data, data.length));
        if (written !== data.length) {
            throw new LingoFuseIoError(
                `writeBytes requested ${data.length} bytes but only ${written} were written.`,
                { operation: "writeBytes" });
        }
        return written;
    }

    /** Read up to count bytes. Returns fewer bytes at end-of-buffer. */
    public readBytes(count: number): Uint8Array {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();
        if (count === 0) return new Uint8Array(0);

        const buffer = new Uint8Array(count);
        const got = toNumber(
            this.#binding.funcs.LF_ReadBuffer(this.#handle, buffer, count));
        if (got === count) return buffer;
        if (got <= 0) return new Uint8Array(0);
        return buffer.slice(0, got);
    }

    /** Read exactly count bytes. Throws on a short read. */
    public readBytesExact(count: number): Uint8Array {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();
        if (count === 0) return new Uint8Array(0);

        const savedPos = this.position;
        const buffer = this.readBytes(count);
        if (buffer.length !== count) {
            this.position = savedPos;
            throw new LingoFuseIoError(
                `readBytesExact requested ${count} bytes but only ${buffer.length} were available.`,
                { operation: "readBytesExact" });
        }
        return buffer;
    }

    /** Non-throwing counterpart of readBytesExact. */
    public tryReadBytes(
        count: number,
    ): { ok: true; value: Uint8Array } | { ok: false } {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();
        if (count === 0) return { ok: true, value: new Uint8Array(0) };

        const savedPos = this.position;
        const buffer = this.readBytes(count);
        if (buffer.length !== count) {
            this.position = savedPos;
            return { ok: false };
        }
        return { ok: true, value: buffer };
    }

    /** Read every remaining byte. Cursor advances to the end. */
    public readAllBytes(): Uint8Array {
        this.#ensureNotDisposed();
        const pos = this.position;
        const total = this.size;
        if (pos >= total) return new Uint8Array(0);
        return this.readBytes(total - pos);
    }

    // ---- Atomic write helpers (little-endian) ----

    public writeInt8(value: number): void {
        this.writeBytes(Uint8Array.of(value & 0xff));
    }
    public writeUInt8(value: number): void {
        this.writeBytes(Uint8Array.of(value & 0xff));
    }
    public writeInt16(value: number): void {
        const b = new Uint8Array(2);
        new DataView(b.buffer).setInt16(0, value, true);
        this.writeBytes(b);
    }
    public writeUInt16(value: number): void {
        const b = new Uint8Array(2);
        new DataView(b.buffer).setUint16(0, value, true);
        this.writeBytes(b);
    }
    public writeInt32(value: number): void {
        const b = new Uint8Array(4);
        new DataView(b.buffer).setInt32(0, value, true);
        this.writeBytes(b);
    }
    public writeUInt32(value: number): void {
        const b = new Uint8Array(4);
        new DataView(b.buffer).setUint32(0, value, true);
        this.writeBytes(b);
    }
    public writeInt64(value: number | bigint): void {
        const b = new Uint8Array(8);
        new DataView(b.buffer).setBigInt64(
            0, toBigInt(value, "DataHandle.writeInt64"), true);
        this.writeBytes(b);
    }
    public writeUInt64(value: number | bigint): void {
        const b = new Uint8Array(8);
        new DataView(b.buffer).setBigUint64(
            0, toBigInt(value, "DataHandle.writeUInt64"), true);
        this.writeBytes(b);
    }
    public writeSingle(value: number): void {
        const b = new Uint8Array(4);
        new DataView(b.buffer).setFloat32(0, value, true);
        this.writeBytes(b);
    }
    public writeDouble(value: number): void {
        const b = new Uint8Array(8);
        new DataView(b.buffer).setFloat64(0, value, true);
        this.writeBytes(b);
    }

    // ---- Atomic read helpers (little-endian, exact) ----

    public readInt8(): number {
        const b = this.readBytesExact(1);
        return (b[0] << 24) >> 24;
    }
    public readUInt8(): number {
        return this.readBytesExact(1)[0];
    }
    public readInt16(): number {
        const b = this.readBytesExact(2);
        return new DataView(b.buffer, b.byteOffset, 2).getInt16(0, true);
    }
    public readUInt16(): number {
        const b = this.readBytesExact(2);
        return new DataView(b.buffer, b.byteOffset, 2).getUint16(0, true);
    }
    public readInt32(): number {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getInt32(0, true);
    }
    public readUInt32(): number {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getUint32(0, true);
    }
    public readInt64(): bigint {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getBigInt64(0, true);
    }
    public readUInt64(): bigint {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getBigUint64(0, true);
    }
    public readSingle(): number {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getFloat32(0, true);
    }
    public readDouble(): number {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getFloat64(0, true);
    }

    // ---- NUL-framed string I/O ----

    /**
     * Write a string as UTF-8, followed by a single NUL byte. An empty
     * string writes exactly one byte (the NUL).
     */
    public writeString(value: string): void {
        if (typeof value !== "string") {
            throw new TypeError("DataHandle.writeString: value must be a string.");
        }
        this.#ensureNotDisposed();
        const utf8 = UTF8_ENCODER.encode(value);
        if (utf8.length > 0) this.writeBytes(utf8);
        this.writeBytes(NULL_BYTE);
    }

    /**
     * Read a UTF-8 string, stopping at the first NUL. If no NUL is
     * found, all remaining bytes are consumed and returned. Invalid
     * UTF-8 sequences are decoded with U+FFFD.
     */
    public readString(): string {
        this.#ensureNotDisposed();

        const start = this.position;
        const total = this.size;
        if (start >= total) return "";

        const remaining = total - start;
        const raw = new Uint8Array(remaining);
        const got = toNumber(
            this.#binding.funcs.LF_ReadBuffer(this.#handle, raw, remaining));
        if (got <= 0) return "";

        let nulIndex = -1;
        for (let i = 0; i < got; i++) {
            if (raw[i] === 0) { nulIndex = i; break; }
        }

        let payload: Uint8Array;
        let newPos: number;
        if (nulIndex >= 0) {
            payload = raw.subarray(0, nulIndex);
            newPos = start + nulIndex + 1;
        } else {
            payload = raw.subarray(0, got);
            newPos = start + got + 1;
        }

        this.position = newPos;
        return UTF8_DECODER.decode(payload);
    }

    /** Non-throwing counterpart of readString. */
    public tryReadString(): { ok: true; value: string } | { ok: false } {
        this.#ensureNotDisposed();
        const start = this.position;
        const total = this.size;
        if (start >= total) return { ok: false };
        return { ok: true, value: this.readString() };
    }

    // ---- Internal ----

    #ensureNotDisposed(): void {
        if (this.#disposed || this.#handle === null || this.#handle === undefined) {
            throw new LingoFuseObjectDisposedError("DataHandle");
        }
    }
}