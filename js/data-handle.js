/**
 * @file data-handle.js
 * @brief RAII wrapper around a native LingoFuse data handle (TDataHnd).
 *
 * RESPONSIBILITY
 * --------------
 * Owns a native data handle and releases it deterministically on
 * dispose(). Provides byte-level, atomic-type, and NUL-framed string
 * I/O on top of the underlying buffer.
 *
 * This is the LOW-LEVEL primitive layer. JSON serialization and
 * NUL-framed byte sequences are provided by the higher-level `LfIo`
 * module, which is built on top of DataHandle.
 *
 * TWO KINDS OF HANDLES
 * --------------------
 * The native library provides two flavours of data handle:
 *
 *   Auto-recycled  (created by the public constructor)
 *       - Backed by LF_CreateData.
 *       - Added to the library's idle pool.
 *       - The pool scans every 5 seconds and frees any handle idle
 *         (no accessor call) for more than 10 minutes.
 *       - dispose() only marks the handle as deleted; the actual
 *         release happens on the next pool scan (at most 5 seconds
 *         later).
 *       - Recommended for the vast majority of use cases.
 *
 *   Permanent      (created by the CreatePermanent factory)
 *       - Backed by LF_CreateData_Permanent.
 *       - NOT added to the library's idle pool.
 *       - The automatic idle-timeout reclaimer will NEVER free it,
 *         no matter how long it has been idle.
 *       - dispose() releases it IMMEDIATELY (synchronously).
 *       - Recommended for handles that must survive for the entire
 *         process lifetime (cached request templates, long-lived
 *         scratch buffers, global registries, etc.).
 *
 *   Both kinds are released by framework.shutdown() when the process
 *   terminates, and both kinds must be explicitly disposed to avoid
 *   leaks.
 *
 * OWNERSHIP
 * ---------
 * A DataHandle is either "owning" or "borrowing":
 *
 *   Owning    — created by the public constructor or by
 *               createPermanent(). dispose() calls LF_FreeData on the
 *               native handle.
 *   Borrowing — created by fromRaw(raw, false). dispose() is a no-op;
 *               the native layer owns the underlying resource and
 *               releases it when the callback returns.
 *
 * Borrowing is used for the input/output handles passed into a
 * callback. Freeing them from JavaScript would be a double-free.
 *
 * BORROWED HANDLE DISPOSE IS A NO-OP
 * ----------------------------------
 * For a borrowed handle, dispose() deliberately does NOT change the
 * wrapper state. A callback body that accidentally calls dispose() on
 * its input or output handle must not corrupt the wrapper state for the
 * rest of the callback body. The wrapper's `#disposed` flag stays
 * false, so isValid, raw, and all read methods remain usable until the
 * callback returns.
 *
 * STRING CONTRACT
 * ---------------
 * LingoFuse frames strings with a single trailing NUL (0x00) byte on
 * the wire. writeString always appends the terminator. readString is
 * fault-tolerant: it reads until the first NUL, or all remaining bytes
 * if no NUL is present. This matches the behaviour of every other
 * LingoFuse binding and keeps interop with non-Pascal producers (HTTP
 * bridges, browsers) working.
 *
 * Invalid UTF-8 byte sequences encountered during a read are decoded
 * with the default replacement character U+FFFD. This keeps the reader
 * binary-safe. Callers that need to detect invalid UTF-8 must read the
 * raw bytes via readBytesExact / readAllBytes and inspect them
 * directly.
 *
 * I/O FAILURE SEMANTICS
 * ---------------------
 * Two symmetric families of read operations are offered so that
 * callers can choose their failure semantics explicitly:
 *
 *   Partial   readBytes(n)
 *             Returns up to n bytes. Never throws for a short read.
 *
 *   Exact     readBytesExact(n)  /  readInt8() .. readDouble()
 *             Requires exactly n bytes. Throws LingoFuseIoError on a
 *             short read.
 *
 * The atomic-type readers are exact by default, because a partially
 * read integer is never useful. Each exact reader has a try* counter-
 * part that returns { ok: false } instead of throwing.
 *
 * WRITE FAILURE SEMANTICS
 * -----------------------
 * writeBytes requires the native layer to accept every byte. A short
 * write means the handle is corrupt or the process is out of memory;
 * there is no useful recovery path, and silently continuing would
 * produce a truncated payload on the wire. writeBytes therefore throws
 * LingoFuseIoError on a short write, symmetrically with
 * readBytesExact.
 *
 * INTERNAL CONSTRUCTION PATH
 * --------------------------
 * The public constructor takes only an API name. The static factories
 * fromRaw(raw, owned) and createPermanent(apiName) need to build an
 * instance without going through the "public" allocation branch.
 *
 * Because JavaScript private fields (#field) are only initialised by a
 * real construction path (Object.create(proto) produces an object that
 * has no private-field slots, and assigning to them throws TypeError),
 * the constructor accepts an undocumented second argument that carries
 * the pre-existing handle and ownership flag. That argument is an
 * implementation detail of this file and MUST NOT be passed by user
 * code.
 *
 * THREAD SAFETY
 * -------------
 * The native library is thread-safe, but a single data handle cannot
 * be written concurrently. Read access is safe while another thread
 * reads. Callers that share a handle across threads must serialise
 * writes themselves.
 *
 * ============================================================================
 */

"use strict";

const {
    LingoFuseError,
    LingoFuseIoError,
    LingoFuseObjectDisposedError,
} = require("./errors");

const { getBinding } = require("./binding");

// ============================================================================
// Small helpers for int64 / BigInt normalisation
// ============================================================================
//
// Koffi returns int64 values as BigInt. For byte operations on buffers
// we need plain numbers. The helpers below normalise both directions
// without losing precision for the sizes LingoFuse actually uses (a
// data buffer larger than 2^53 bytes is not physically possible).

/**
 * Convert a Koffi int64 result to a plain Number. The input may be a
 * BigInt or a Number, depending on the Koffi version.
 *
 * @param {bigint|number} v
 * @returns {number}
 */
function toNumber(v) {
    return typeof v === "bigint" ? Number(v) : v;
}

/**
 * Convert a plain Number or BigInt to BigInt for a Koffi int64
 * argument.
 *
 * @param {bigint|number} v
 * @returns {bigint}
 */
function toBigInt(v) {
    return typeof v === "bigint" ? v : BigInt(v);
}

// ============================================================================
// Module-level shared resources
// ============================================================================

/**
 * The single NUL byte used as the string terminator. Held as a shared
 * frozen buffer to avoid a heap allocation per empty-string write.
 */
const NULL_BYTE = Uint8Array.of(0);

/**
 * Shared UTF-8 encoder. TextEncoder is stateless, so a single instance
 * is safe to reuse across every DataHandle and every call.
 */
const UTF8_ENCODER = new TextEncoder();

/**
 * Shared UTF-8 decoder. Constructed with `{ fatal: false }` so that
 * invalid byte sequences become U+FFFD instead of throwing. This
 * matches the "replace" policy used by the C++ and C# bindings.
 */
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: false });

// ============================================================================
// DataHandle
// ============================================================================

/**
 * RAII wrapper around a native LingoFuse data handle.
 *
 * Instances are not thread-safe for concurrent writes. Different
 * instances are fully independent.
 */
class DataHandle {
    // --------------------------------------------------------------------
    // Private state
    // --------------------------------------------------------------------

    /** @type {object} Native binding singleton (funcs + types). */
    #binding;

    /** @type {object} The declared native functions. */
    #funcs;

    /** @type {object|null} Raw native handle pointer, or null. */
    #handle;

    /** @type {boolean} True when dispose() will call LF_FreeData. */
    #owned;

    /** @type {boolean} True after an owning handle has been disposed. */
    #disposed;

    // --------------------------------------------------------------------
    // Construction
    // --------------------------------------------------------------------

    /**
     * Creates a new AUTO-RECYCLED data handle bound to the given API
     * name. The underlying buffer starts empty.
     *
     * The second argument is an internal implementation detail used by
     * the static factories fromRaw() and createPermanent(). User code
     * must never pass it.
     *
     * @param {string|null} apiName
     *   UTF-8 API name. Must be a string when `internal` is null.
     *   An empty string is allowed but unusual; the native side stores
     *   the name as the "MethodName" component of the wire format.
     * @param {{ handle: object, owned: boolean }|null} [internal=null]
     *   Internal-only. When non-null, the constructor wraps an already
     *   allocated native handle instead of calling LF_CreateData.
     * @throws {TypeError} When apiName is not a string (public path).
     * @throws {import('./errors').LingoFuseError}
     *   When the native library fails to allocate the handle.
     */
    constructor(apiName, internal = null) {
        const binding = getBinding();
        this.#binding = binding;
        this.#funcs = binding.funcs;
        this.#disposed = false;

        // -----------------------------------------------------------------
        // Internal construction path: wrap an existing native handle.
        // -----------------------------------------------------------------
        if (internal !== null) {
            this.#handle = internal.handle;
            this.#owned = internal.owned;
            return;
        }

        // -----------------------------------------------------------------
        // Public construction path: allocate a new native handle.
        // -----------------------------------------------------------------
        if (typeof apiName !== "string") {
            throw new TypeError("DataHandle: apiName must be a string.");
        }

        this.#owned = true;

        const raw = this.#funcs.LF_CreateData(apiName);
        if (raw === null || raw === undefined) {
            throw new LingoFuseError(
                `Failed to create a data handle for API '${apiName}'.`
            );
        }
        this.#handle = raw;
    }

    /**
     * Wraps an existing raw handle. Intended for internal use when the
     * native layer already owns the handle (for example, inside a
     * callback).
     *
     * @param {object} raw
     *   Raw pointer value as returned by the native callback.
     * @param {boolean} owned
     *   When true, dispose() will call LF_FreeData. When false,
     *   dispose() is a no-op and the native layer retains ownership.
     * @returns {DataHandle}
     */
    static fromRaw(raw, owned) {
        return new DataHandle(null, { handle: raw, owned: Boolean(owned) });
    }

    /**
     * Creates a new PERMANENT data handle bound to the given API name.
     * The underlying buffer starts empty.
     *
     * Difference from `new DataHandle(apiName)`:
     *   - NOT added to the library's idle pool.
     *   - The automatic idle-timeout reclaimer will NEVER free it,
     *     no matter how long it has been idle.
     *   - dispose() releases it IMMEDIATELY (synchronously), rather
     *     than marking it for a later pool scan.
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
     *   thread is not active (before framework.prepareDone or after
     *   framework.exitMainThread). Permanent handles created in that
     *   window stay allocated until the process terminates, or until
     *   framework.shutdown runs.
     *
     * [PITFALL - LIFETIME]
     *   "Permanent" means "not automatically reclaimed", NOT "never
     *   released". You are fully responsible for disposing it. Losing
     *   the reference leaks the handle for the lifetime of the
     *   process.
     *
     * @param {string} apiName
     *   UTF-8 API name. Must be a string.
     * @returns {DataHandle}
     * @throws {TypeError} When apiName is not a string.
     * @throws {import('./errors').LingoFuseError}
     *   When the native library fails to allocate the handle.
     */
    static createPermanent(apiName) {
        if (typeof apiName !== "string") {
            throw new TypeError(
                "DataHandle.createPermanent: apiName must be a string."
            );
        }

        const binding = getBinding();
        const raw = binding.funcs.LF_CreateData_Permanent(apiName);
        if (raw === null || raw === undefined) {
            throw new LingoFuseError(
                `Failed to create a permanent data handle for API '${apiName}'.`
            );
        }
        return new DataHandle(null, { handle: raw, owned: true });
    }

    // --------------------------------------------------------------------
    // Identity and state
    // --------------------------------------------------------------------

    /**
     * Raw native pointer. Null after an owning handle has been
     * disposed. A borrowed handle keeps its pointer until the native
     * layer releases it (after the callback returns).
     *
     * @returns {object|null}
     */
    get raw() {
        return this.#handle;
    }

    /**
     * True while the handle is valid and usable. A borrowed handle is
     * always valid until the native layer releases it, even after an
     * accidental dispose() call.
     *
     * @returns {boolean}
     */
    get isValid() {
        return !this.#disposed && this.#handle !== null && this.#handle !== undefined;
    }

    /**
     * True when this instance owns the native handle (that is,
     * dispose() will call LF_FreeData).
     *
     * @returns {boolean}
     */
    get isOwning() {
        return this.#owned;
    }

    // --------------------------------------------------------------------
    // Lifetime
    // --------------------------------------------------------------------

    /**
     * Releases the native handle when ownership applies.
     *
     * For an OWNING AUTO-RECYCLED handle (created by the public
     * constructor): calls LF_FreeData, which only marks the handle as
     * deleted. The actual release happens on the next idle-pool scan
     * (at most 5 seconds later). The wrapper's state transitions to
     * disposed and subsequent operations throw
     * LingoFuseObjectDisposedError. Idempotent.
     *
     * For an OWNING PERMANENT handle (created by createPermanent):
     * calls LF_FreeData, which releases the handle IMMEDIATELY
     * (synchronously). The wrapper's state transitions to disposed,
     * and subsequent operations throw LingoFuseObjectDisposedError.
     * Idempotent.
     *
     * For a BORROWED handle: this method is a NO-OP. The native layer
     * owns the underlying resource and releases it when the callback
     * returns. The wrapper's state is unchanged so that a callback body
     * that accidentally calls dispose() can still read from the input
     * handle for the rest of its execution.
     */
    dispose() {
        if (this.#disposed) {
            return;
        }

        if (!this.#owned) {
            // Borrowed handle: the native layer owns the resource.
            // dispose() is deliberately a no-op.
            return;
        }

        this.#disposed = true;
        const handle = this.#handle;
        this.#handle = null;

        if (handle !== null && handle !== undefined) {
            this.#funcs.LF_FreeData(handle);
        }
    }

    // --------------------------------------------------------------------
    // Position and size
    // --------------------------------------------------------------------

    /**
     * Current read/write cursor position, in bytes.
     *
     * @returns {number}
     */
    get position() {
        this.#ensureNotDisposed();
        return toNumber(this.#funcs.LF_GetPos(this.#handle));
    }

    /**
     * Sets the read/write cursor. A position past the current size
     * implicitly grows the buffer; the new bytes are uninitialised.
     *
     * @param {number|bigint} value  Non-negative byte offset.
     * @throws {RangeError} When value is negative.
     */
    set position(value) {
        if (typeof value === "bigint" ? value < 0n : value < 0) {
            throw new RangeError("Position must be non-negative.");
        }
        this.#ensureNotDisposed();
        this.#funcs.LF_SetPos(this.#handle, toBigInt(value));
    }

    /**
     * Total buffer size, in bytes.
     *
     * @returns {number}
     */
    get size() {
        this.#ensureNotDisposed();
        return toNumber(this.#funcs.LF_GetSize(this.#handle));
    }

    /**
     * Resizes the buffer. A larger size grows the buffer with
     * uninitialised bytes; a smaller size truncates.
     *
     * @param {number|bigint} value  Non-negative byte count.
     * @throws {RangeError} When value is negative.
     */
    set size(value) {
        if (typeof value === "bigint" ? value < 0n : value < 0) {
            throw new RangeError("Size must be non-negative.");
        }
        this.#ensureNotDisposed();
        this.#funcs.LF_SetSize(this.#handle, toBigInt(value));
    }

    /**
     * Returns the native pointer to the internal buffer.
     *
     * The pointer is invalidated by any subsequent resize (including
     * implicit growth caused by a write or by setting position past the
     * current size). Do not free the pointer.
     *
     * @returns {object|null}
     */
    getBufferPointer() {
        this.#ensureNotDisposed();
        return this.#funcs.LF_GetBuffer(this.#handle);
    }

    // ====================================================================
    // Byte I/O — partial-read family
    // ====================================================================

    /**
     * Appends the given bytes at the current cursor. The buffer grows
     * as needed; the cursor advances by the number of bytes written.
     *
     * @param {Uint8Array|Buffer} data
     *   Bytes to append. Must not be null. An empty array is a no-op.
     * @returns {number} Number of bytes actually written.
     * @throws {TypeError} When data is not a Uint8Array / Buffer.
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     * @throws {import('./errors').LingoFuseIoError}
     *   When the native layer writes fewer bytes than requested.
     */
    writeBytes(data) {
        if (!(data instanceof Uint8Array)) {
            throw new TypeError(
                "DataHandle.writeBytes: data must be a Uint8Array or Buffer."
            );
        }
        this.#ensureNotDisposed();

        if (data.length === 0) {
            return 0;
        }

        const written = toNumber(
            this.#funcs.LF_WriteBuffer(this.#handle, data, data.length)
        );
        if (written !== data.length) {
            throw new LingoFuseIoError(
                `writeBytes requested ${data.length} bytes but only ` +
                `${written} were written.`,
                { operation: "writeBytes" }
            );
        }
        return written;
    }

    /**
     * Reads up to `count` bytes into a new Uint8Array. The cursor
     * advances by the number of bytes actually read.
     *
     * @param {number} count  Maximum number of bytes to read.
     * @returns {Uint8Array}
     *   The bytes actually read. Empty at end-of-buffer and possibly
     *   shorter than `count`. Never null.
     * @throws {RangeError} When count is negative.
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     */
    readBytes(count) {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();

        if (count === 0) {
            return new Uint8Array(0);
        }

        const buffer = new Uint8Array(count);
        const got = toNumber(
            this.#funcs.LF_ReadBuffer(this.#handle, buffer, count)
        );
        if (got === count) {
            return buffer;
        }
        if (got <= 0) {
            return new Uint8Array(0);
        }
        return buffer.slice(0, got);
    }

    // ====================================================================
    // Byte I/O — exact-read family
    // ====================================================================

    /**
     * Reads exactly `count` bytes. Throws on a short read. The cursor
     * advances by exactly `count` bytes on success and is left
     * unchanged on failure.
     *
     * @param {number} count
     * @returns {Uint8Array}
     * @throws {RangeError} When count is negative.
     * @throws {import('./errors').LingoFuseIoError}
     *   When fewer than `count` bytes are available.
     */
    readBytesExact(count) {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();

        if (count === 0) {
            return new Uint8Array(0);
        }

        const savedPos = this.position;
        const buffer = this.readBytes(count);
        if (buffer.length !== count) {
            this.position = savedPos;
            throw new LingoFuseIoError(
                `readBytesExact requested ${count} bytes but only ` +
                `${buffer.length} were available.`,
                { operation: "readBytesExact" }
            );
        }
        return buffer;
    }

    /**
     * Non-throwing counterpart of readBytesExact. The cursor advances
     * by `count` bytes on success and is left unchanged on failure.
     *
     * @param {number} count
     * @returns {{ ok: true, value: Uint8Array } | { ok: false }}
     */
    tryReadBytes(count) {
        if (!Number.isInteger(count) || count < 0) {
            throw new RangeError("Count must be a non-negative integer.");
        }
        this.#ensureNotDisposed();

        if (count === 0) {
            return { ok: true, value: new Uint8Array(0) };
        }

        const savedPos = this.position;
        const buffer = this.readBytes(count);
        if (buffer.length !== count) {
            this.position = savedPos;
            return { ok: false };
        }
        return { ok: true, value: buffer };
    }

    /**
     * Reads every remaining byte from the current cursor to the end of
     * the buffer and advances the cursor to the end.
     *
     * @returns {Uint8Array}
     */
    readAllBytes() {
        this.#ensureNotDisposed();
        const pos = this.position;
        const total = this.size;
        if (pos >= total) {
            return new Uint8Array(0);
        }
        return this.readBytes(total - pos);
    }

    // ====================================================================
    // Atomic write helpers (little-endian)
    // ====================================================================

    /** Writes an 8-bit signed integer. Cursor advances by 1 byte. */
    writeInt8(value) {
        const buf = new Uint8Array(1);
        buf[0] = value & 0xff;
        this.writeBytes(buf);
    }

    /** Writes an 8-bit unsigned integer. Cursor advances by 1 byte. */
    writeUInt8(value) {
        this.writeBytes(Uint8Array.of(value & 0xff));
    }

    /** Writes a 16-bit signed integer. Cursor advances by 2 bytes. */
    writeInt16(value) {
        const buf = new Uint8Array(2);
        new DataView(buf.buffer).setInt16(0, value, true);
        this.writeBytes(buf);
    }

    /** Writes a 16-bit unsigned integer. Cursor advances by 2 bytes. */
    writeUInt16(value) {
        const buf = new Uint8Array(2);
        new DataView(buf.buffer).setUint16(0, value, true);
        this.writeBytes(buf);
    }

    /** Writes a 32-bit signed integer. Cursor advances by 4 bytes. */
    writeInt32(value) {
        const buf = new Uint8Array(4);
        new DataView(buf.buffer).setInt32(0, value, true);
        this.writeBytes(buf);
    }

    /** Writes a 32-bit unsigned integer. Cursor advances by 4 bytes. */
    writeUInt32(value) {
        const buf = new Uint8Array(4);
        new DataView(buf.buffer).setUint32(0, value, true);
        this.writeBytes(buf);
    }

    /** Writes a 64-bit signed integer. Cursor advances by 8 bytes. */
    writeInt64(value) {
        const buf = new Uint8Array(8);
        new DataView(buf.buffer).setBigInt64(0, toBigInt(value), true);
        this.writeBytes(buf);
    }

    /** Writes a 64-bit unsigned integer. Cursor advances by 8 bytes. */
    writeUInt64(value) {
        const buf = new Uint8Array(8);
        new DataView(buf.buffer).setBigUint64(0, toBigInt(value), true);
        this.writeBytes(buf);
    }

    /** Writes a 32-bit single-precision float. Cursor advances by 4 bytes. */
    writeSingle(value) {
        const buf = new Uint8Array(4);
        new DataView(buf.buffer).setFloat32(0, value, true);
        this.writeBytes(buf);
    }

    /** Writes a 64-bit double-precision float. Cursor advances by 8 bytes. */
    writeDouble(value) {
        const buf = new Uint8Array(8);
        new DataView(buf.buffer).setFloat64(0, value, true);
        this.writeBytes(buf);
    }

    // ====================================================================
    // Atomic read helpers (little-endian) — exact semantics
    // ====================================================================

    /** Reads an 8-bit signed integer. Requires 1 byte. */
    readInt8() {
        const b = this.readBytesExact(1);
        return (b[0] << 24) >> 24;
    }

    /** Reads an 8-bit unsigned integer. Requires 1 byte. */
    readUInt8() {
        return this.readBytesExact(1)[0];
    }

    /** Reads a 16-bit signed integer. Requires 2 bytes. */
    readInt16() {
        const b = this.readBytesExact(2);
        return new DataView(b.buffer, b.byteOffset, 2).getInt16(0, true);
    }

    /** Reads a 16-bit unsigned integer. Requires 2 bytes. */
    readUInt16() {
        const b = this.readBytesExact(2);
        return new DataView(b.buffer, b.byteOffset, 2).getUint16(0, true);
    }

    /** Reads a 32-bit signed integer. Requires 4 bytes. */
    readInt32() {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getInt32(0, true);
    }

    /** Reads a 32-bit unsigned integer. Requires 4 bytes. */
    readUInt32() {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getUint32(0, true);
    }

    /** Reads a 64-bit signed integer. Requires 8 bytes. Returns BigInt. */
    readInt64() {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getBigInt64(0, true);
    }

    /** Reads a 64-bit unsigned integer. Requires 8 bytes. Returns BigInt. */
    readUInt64() {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getBigUint64(0, true);
    }

    /** Reads a 32-bit single-precision float. Requires 4 bytes. */
    readSingle() {
        const b = this.readBytesExact(4);
        return new DataView(b.buffer, b.byteOffset, 4).getFloat32(0, true);
    }

    /** Reads a 64-bit double-precision float. Requires 8 bytes. */
    readDouble() {
        const b = this.readBytesExact(8);
        return new DataView(b.buffer, b.byteOffset, 8).getFloat64(0, true);
    }

    // ====================================================================
    // Atomic read helpers — try* variants
    // ====================================================================

    /** Non-throwing counterpart of readInt8. */
    tryReadInt8() {
        const r = this.tryReadBytes(1);
        return r.ok ? { ok: true, value: (r.value[0] << 24) >> 24 } : { ok: false };
    }

    /** Non-throwing counterpart of readUInt8. */
    tryReadUInt8() {
        const r = this.tryReadBytes(1);
        return r.ok ? { ok: true, value: r.value[0] } : { ok: false };
    }

    /** Non-throwing counterpart of readInt16. */
    tryReadInt16() {
        const r = this.tryReadBytes(2);
        if (!r.ok) return { ok: false };
        return {
            ok: true,
            value: new DataView(r.value.buffer, r.value.byteOffset, 2).getInt16(0, true),
        };
    }

    /** Non-throwing counterpart of readUInt16. */
    tryReadUInt16() {
        const r = this.tryReadBytes(2);
        if (!r.ok) return { ok: false };
        return {
            ok: true,
            value: new DataView(r.value.buffer, r.value.byteOffset, 2).getUint16(0, true),
        };
    }

    /** Non-throwing counterpart of readInt32. */
    tryReadInt32() {
        const r = this.tryReadBytes(4);
        if (!r.ok) return { ok: false };
        return {
            ok: true,
            value: new DataView(r.value.buffer, r.value.byteOffset, 4).getInt32(0, true),
        };
    }

    /** Non-throwing counterpart of readUInt32. */
    tryReadUInt32() {
        const r = this.tryReadBytes(4);
        if (!r.ok) return { ok: false };
        return {
            ok: true,
            value: new DataView(r.value.buffer, r.value.byteOffset, 4).getUint32(0, true),
        };
    }

    /** Non-throwing counterpart of readInt64. */
    tryReadInt64() {
        const r = this.tryReadBytes(8);
        if (!r.ok) return { ok: false };
        return {
            ok: true,
            value: new DataView(r.value.buffer, r.value.byteOffset, 8).getBigInt64(0, true),
        };
    }

    /** Non-throwing counterpart of readUInt64. */
    tryReadUInt64() {
        const r = this.tryReadBytes(8);
        if (!r.ok) return { ok: false };
        return {
            ok: true,
            value: new DataView(r.value.buffer, r.value.byteOffset, 8).getBigUint64(0, true),
        };
    }

    /** Non-throwing counterpart of readSingle. */
    tryReadSingle() {
        const r = this.tryReadBytes(4);
        if (!r.ok) return { ok: false };
        return {
            ok: true,
            value: new DataView(r.value.buffer, r.value.byteOffset, 4).getFloat32(0, true),
        };
    }

    /** Non-throwing counterpart of readDouble. */
    tryReadDouble() {
        const r = this.tryReadBytes(8);
        if (!r.ok) return { ok: false };
        return {
            ok: true,
            value: new DataView(r.value.buffer, r.value.byteOffset, 8).getFloat64(0, true),
        };
    }

    // ====================================================================
    // NUL-framed string I/O
    // ====================================================================

    /**
     * Writes a string as UTF-8, followed by a single NUL byte. An empty
     * string writes exactly one byte (the NUL).
     *
     * @param {string} value  UTF-8 string. Must be a string.
     * @throws {TypeError} When value is not a string.
     */
    writeString(value) {
        if (typeof value !== "string") {
            throw new TypeError("DataHandle.writeString: value must be a string.");
        }
        this.#ensureNotDisposed();

        const utf8 = UTF8_ENCODER.encode(value);
        if (utf8.length > 0) {
            this.writeBytes(utf8);
        }
        this.writeBytes(NULL_BYTE);
    }

    /**
     * Reads a UTF-8 string from the current cursor, stopping at the
     * first NUL byte. When no NUL is found before the end of the
     * buffer, all remaining bytes are consumed and returned.
     *
     * Invalid UTF-8 byte sequences are decoded with replacement
     * characters (U+FFFD). Callers that need to detect invalid UTF-8
     * must read the raw bytes and inspect them directly.
     *
     * @returns {string}
     */
    readString() {
        this.#ensureNotDisposed();

        const start = this.position;
        const total = this.size;
        if (start >= total) {
            return "";
        }

        // Read all remaining bytes. The native LF_ReadBuffer advances
        // the cursor to the end of the buffer; we will overwrite the
        // cursor below to match the exact NUL-aware semantics.
        const remaining = total - start;
        const raw = new Uint8Array(remaining);
        const got = toNumber(
            this.#funcs.LF_ReadBuffer(this.#handle, raw, remaining)
        );

        if (got <= 0) {
            return "";
        }

        // Scan for the first NUL.
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
        } else {
            // No NUL found: consume everything up to `got`, then move
            // the cursor to one byte past the end of the buffer,
            // matching the native fault-tolerant read behaviour.
            payload = raw.subarray(0, got);
            newPos = start + got + 1;
        }

        this.position = newPos;
        return UTF8_DECODER.decode(payload);
    }

    /**
     * Non-throwing counterpart of readString. The only recoverable
     * failure mode is an exhausted buffer; a disposed handle still
     * throws.
     *
     * @returns {{ ok: true, value: string } | { ok: false }}
     */
    tryReadString() {
        this.#ensureNotDisposed();

        const start = this.position;
        const total = this.size;
        if (start >= total) {
            return { ok: false };
        }
        return { ok: true, value: this.readString() };
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    /**
     * @private
     * @throws {import('./errors').LingoFuseObjectDisposedError}
     */
    #ensureNotDisposed() {
        if (
            this.#disposed ||
            this.#handle === null ||
            this.#handle === undefined
        ) {
            throw new LingoFuseObjectDisposedError("DataHandle");
        }
    }
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
    DataHandle,
};