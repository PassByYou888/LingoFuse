package lingofuse;

import lingofuse.errors.LingoFuseException;
import lingofuse.errors.LingoFuseIoException;
import lingofuse.errors.LingoFuseObjectDisposedException;
import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Objects;

/**
 * RAII wrapper around a native LingoFuse data handle ({@code TDataHnd}).
 *
 * <p>Owns a native data handle and releases it deterministically on
 * {@link #close()}. Provides byte-level, atomic-type, and NUL-framed
 * string I/O on top of the underlying buffer.
 *
 * <p>This is the LOW-LEVEL primitive layer. JSON serialization and
 * NUL-framed byte sequences are provided by the higher-level
 * {@code LfIo} class, which is built on top of {@code DataHandle}.
 *
 * <h2>Two kinds of handles</h2>
 *
 * <p>The native library provides two flavours of data handle:
 *
 * <dl>
 *   <dt>Auto-recycled (created by the public constructor)</dt>
 *   <dd>
 *     Backed by {@code LF_CreateData}. Added to the library's idle
 *     pool. The pool scans every 5 seconds and frees any handle idle
 *     (no accessor call) for more than 10 minutes. {@code close()}
 *     only marks the handle as deleted; the actual release happens on
 *     the next pool scan (at most 5 seconds later). Recommended for
 *     the vast majority of use cases.
 *   </dd>
 *   <dt>Permanent (created by {@link #createPermanent(String)})</dt>
 *   <dd>
 *     Backed by {@code LF_CreateData_Permanent}. NOT added to the idle
 *     pool. The automatic idle-timeout reclaimer will NEVER free it,
 *     no matter how long it has been idle. {@code close()} releases
 *     it synchronously. Recommended for handles that must survive for
 *     the entire process lifetime (cached request templates,
 *     long-lived scratch buffers, global registries).
 *   </dd>
 * </dl>
 *
 * <p>Both kinds are released by {@code Framework.shutdown()} when the
 * process terminates, and both kinds must be explicitly closed to
 * avoid leaks.
 *
 * <h2>Ownership</h2>
 *
 * <p>A {@code DataHandle} is either "owning" or "borrowing":
 *
 * <ul>
 *   <li>Owning: created by the public constructor, by
 *       {@link #createPermanent(String)}, or by
 *       {@link #fromRaw(MemorySegment, boolean)} with
 *       {@code owned=true}. {@code close()} calls {@code LF_FreeData}
 *       on the native handle.</li>
 *   <li>Borrowing: created by
 *       {@link #fromRaw(MemorySegment, boolean)} with
 *       {@code owned=false}. {@code close()} is a no-op; the native
 *       layer owns the underlying resource and releases it when the
 *       callback returns.</li>
 * </ul>
 *
 * <p>Borrowing is used for the input/output handles passed into a
 * callback. Freeing them from Java would be a double-free.
 *
 * <h2>Borrowed handle close is a no-op</h2>
 *
 * <p>For a borrowed handle, {@link #close()} deliberately does NOT
 * change the wrapper state. A callback body that accidentally calls
 * {@code close()} on its input or output handle must not corrupt the
 * wrapper state for the rest of the callback body. The wrapper's
 * {@code closed} flag stays {@code false}, so {@link #isValid()} and
 * all read methods remain usable until the callback returns.
 *
 * <h2>String contract</h2>
 *
 * <p>LingoFuse frames strings with a single trailing NUL
 * ({@code 0x00}) byte on the wire. {@link #writeString(String)}
 * always appends the terminator. {@link #readString()} is
 * fault-tolerant: it reads until the first NUL, or all remaining
 * bytes if no NUL is present. This matches the behaviour of every
 * other LingoFuse binding and keeps interop with non-Pascal producers
 * (HTTP bridges, browsers) working.
 *
 * <p>Invalid UTF-8 byte sequences encountered during a read are
 * decoded with the encoder's default fallback: each invalid byte
 * becomes U+FFFD. This keeps the reader binary-safe. Callers that
 * need to detect invalid UTF-8 must read the raw bytes via
 * {@link #readBytesExact(int)} or {@link #readAllBytes()} and inspect
 * them directly.
 *
 * <h2>I/O failure semantics</h2>
 *
 * <p>Two symmetric families of read operations are offered so that
 * callers can choose their failure semantics explicitly:
 *
 * <ul>
 *   <li>Partial: {@link #readBytes(int)} returns up to {@code n}
 *       bytes. Never throws for a short read.</li>
 *   <li>Exact: {@link #readBytesExact(int)} and the atomic-type
 *       readers require exactly {@code n} bytes and throw
 *       {@link LingoFuseIoException} on a short read.</li>
 * </ul>
 *
 * <p>The atomic-type readers are exact by default, because a
 * partially read integer is never useful.
 *
 * <h2>Thread safety</h2>
 *
 * <p>The native library is thread-safe, but a single data handle
 * cannot be written concurrently. Read access is safe while another
 * thread reads. Callers that share a handle across threads must
 * serialise writes themselves.
 *
 * <p>The {@code handle} and {@code closed} fields are declared
 * {@code volatile} so that a {@code close()} on one thread is
 * observed by an {@code ensureOpen()} on another thread without
 * requiring an external lock. This is sufficient for the "do not use
 * after close" contract; it does not make concurrent writes safe.
 */
public final class DataHandle implements AutoCloseable {

    /**
     * UTF-8 encoding used for the NUL-framed string contract. No byte
     * order mark is emitted; invalid byte sequences are replaced with
     * U+FFFD by the encoder's default fallback.
     */
    private static final java.nio.charset.Charset UTF8 = StandardCharsets.UTF_8;

    /**
     * Little-endian byte order, as required by the LingoFuse wire
     * format for every integer and floating-point value.
     */
    private static final ByteOrder LE = ByteOrder.LITTLE_ENDIAN;

    /**
     * The native handle. {@link MemorySegment#NULL} after an owning
     * handle has been closed.
     */
    private volatile MemorySegment handle;

    /** True when {@link #close()} will call {@code LF_FreeData}. */
    private final boolean owned;

    /** True after an owning handle has been closed. */
    private volatile boolean closed;

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /**
     * Creates a new AUTO-RECYCLED data handle bound to the given API
     * name. The underlying buffer starts empty.
     *
     * <p>The handle is added to the library's idle pool. The pool
     * scans every 5 seconds and frees any handle that has been idle
     * for more than 10 minutes. Any accessor call ({@code position()},
     * {@code size()}, {@code getBufferPointer()}, read/write methods,
     * ...) refreshes the idle timestamp.
     *
     * <p>Use {@link #createPermanent(String)} when the handle must
     * survive for the entire process lifetime.
     *
     * @param apiName the UTF-8 API name; must not be null
     * @throws NullPointerException if {@code apiName} is null
     * @throws LingoFuseException   if the native side fails to
     *                              allocate the handle
     */
    public DataHandle(String apiName) {
        Objects.requireNonNull(apiName, "apiName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSegment = arena.allocateFrom(apiName);
            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_CreateData, nameSegment);
            if (isNull(raw)) {
                throw new LingoFuseException(
                        "Failed to create a data handle for API '"
                                + apiName + "'");
            }
            this.handle = raw;
            this.owned = true;
            this.closed = false;
        }
    }

    /**
     * Private constructor used by the static factories.
     *
     * @param raw   the raw native handle
     * @param owned whether {@code close()} will free the handle
     */
    private DataHandle(MemorySegment raw, boolean owned) {
        this.handle = raw;
        this.owned = owned;
        this.closed = false;
    }

    /**
     * Creates a new PERMANENT data handle bound to the given API name.
     * The underlying buffer starts empty.
     *
     * <p>Difference from {@link #DataHandle(String)}:
     * <ul>
     *   <li>NOT added to the library's idle pool.</li>
     *   <li>The automatic idle-timeout reclaimer will NEVER free it,
     *       no matter how long it has been idle.</li>
     *   <li>{@link #close()} releases it IMMEDIATELY (synchronously),
     *       rather than marking it for a later pool scan.</li>
     * </ul>
     *
     * <p>Use this for handles that must survive for the entire
     * lifetime of the process (cached request templates, long-lived
     * scratch buffers, global registries).
     *
     * <p>Do NOT use it for short-lived handles; the pool safety net
     * is lost.
     *
     * @param apiName the UTF-8 API name; must not be null
     * @return a new {@code DataHandle} wrapping a permanent handle
     * @throws NullPointerException if {@code apiName} is null
     * @throws LingoFuseException   if the native side fails to
     *                              allocate the handle
     */
    public static DataHandle createPermanent(String apiName) {
        Objects.requireNonNull(apiName, "apiName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment nameSegment = arena.allocateFrom(apiName);
            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_CreateData_Permanent, nameSegment);
            if (isNull(raw)) {
                throw new LingoFuseException(
                        "Failed to create a permanent data handle for API '"
                                + apiName + "'");
            }
            return new DataHandle(raw, true);
        }
    }

    /**
     * Wraps an existing raw handle.
     *
     * <p>Intended for internal use when the native layer already owns
     * the handle (for example, inside a callback).
     *
     * @param raw   the raw pointer as returned by the native callback
     * @param owned when true, {@link #close()} calls
     *              {@code LF_FreeData}; when false, {@link #close()}
     *              is a no-op and the native layer retains ownership
     * @return a new {@code DataHandle} wrapping {@code raw}
     */
    public static DataHandle fromRaw(MemorySegment raw, boolean owned) {
        return new DataHandle(raw, owned);
    }

    // ------------------------------------------------------------------
    // Identity and state
    // ------------------------------------------------------------------

    /**
     * Returns the raw native pointer.
     *
     * <p>Returns {@link MemorySegment#NULL} when an owning handle has
     * been closed. A borrowed handle keeps its pointer until the
     * native layer releases it (after the callback returns).
     *
     * @return the raw handle
     */
    public MemorySegment raw() {
        return handle;
    }

    /**
     * Returns whether the handle is valid and usable.
     *
     * <p>A borrowed handle is always valid until the native layer
     * releases it, even after an accidental {@link #close()} call.
     *
     * @return true while the handle is usable
     */
    public boolean isValid() {
        return !closed && !isNull(handle);
    }

    /**
     * Returns whether this instance owns the native handle, i.e.
     * whether {@link #close()} will call {@code LF_FreeData}.
     *
     * @return true for owning handles
     */
    public boolean isOwning() {
        return owned;
    }

    // ------------------------------------------------------------------
    // Lifetime
    // ------------------------------------------------------------------

    /**
     * Releases the native handle when ownership applies.
     *
     * <p>For an owning auto-recycled handle: calls
     * {@code LF_FreeData}, which only marks the handle as deleted.
     * The actual release happens on the next idle-pool scan (at most
     * 5 seconds later). The wrapper's state transitions to closed and
     * subsequent operations throw
     * {@link LingoFuseObjectDisposedException}. Idempotent.
     *
     * <p>For an owning permanent handle: calls {@code LF_FreeData},
     * which releases the handle IMMEDIATELY (synchronously). The
     * wrapper's state transitions to closed, and subsequent operations
     * throw {@link LingoFuseObjectDisposedException}. Idempotent.
     *
     * <p>For a borrowed handle: this method is a NO-OP. The native
     * layer owns the underlying resource and releases it when the
     * callback returns. The wrapper's state is unchanged so that a
     * callback body that accidentally calls {@code close()} can still
     * read from the input handle for the rest of its execution.
     */
    @Override
    public void close() {
        if (closed) {
            return;
        }
        if (!owned) {
            // Borrowed handle: the native layer owns the resource.
            // close() is deliberately a no-op.
            return;
        }

        closed = true;

        // Snapshot the handle into a local, then clear the field.
        // Publishing MemorySegment.NULL through the volatile field
        // makes the close visible to a concurrent ensureOpen() on
        // another thread.
        MemorySegment snapshot = handle;
        handle = MemorySegment.NULL;

        if (!isNull(snapshot)) {
            NativeCall.callVoid(NativeMethods.LF_FreeData, snapshot);
        }
    }

    // ------------------------------------------------------------------
    // Position and size
    // ------------------------------------------------------------------

    /**
     * Returns the current read/write cursor position, in bytes.
     *
     * @return the current position
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public long position() {
        ensureOpen();
        return NativeCall.callLong(NativeMethods.LF_GetPos, handle);
    }

    /**
     * Sets the read/write cursor position.
     *
     * <p>Setting a position past the current size implicitly grows
     * the buffer. The new bytes are uninitialised.
     *
     * @param pos the new position; must be non-negative
     * @throws IllegalArgumentException          if {@code pos} is negative
     * @throws LingoFuseObjectDisposedException  if the handle has been
     *                                           closed
     */
    public void setPosition(long pos) {
        if (pos < 0) {
            throw new IllegalArgumentException(
                    "Position must be non-negative: " + pos);
        }
        ensureOpen();
        NativeCall.callVoid(NativeMethods.LF_SetPos, handle, pos);
    }

    /**
     * Returns the total buffer size, in bytes.
     *
     * @return the buffer size
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public long size() {
        ensureOpen();
        return NativeCall.callLong(NativeMethods.LF_GetSize, handle);
    }

    /**
     * Sets the buffer size.
     *
     * <p>A larger size grows the buffer with uninitialised bytes; a
     * smaller size truncates.
     *
     * @param newSize the new size; must be non-negative
     * @throws IllegalArgumentException          if {@code newSize} is
     *                                           negative
     * @throws LingoFuseObjectDisposedException  if the handle has been
     *                                           closed
     */
    public void setSize(long newSize) {
        if (newSize < 0) {
            throw new IllegalArgumentException(
                    "Size must be non-negative: " + newSize);
        }
        ensureOpen();
        NativeCall.callVoid(NativeMethods.LF_SetSize, handle, newSize);
    }

    /**
     * Returns the native pointer to the internal buffer.
     *
     * <p>The pointer is invalidated by any subsequent resize
     * (including implicit growth caused by a write or by setting
     * {@link #setPosition(long)} past the current size). Do not free
     * the pointer.
     *
     * @return the internal buffer pointer, or {@link MemorySegment#NULL}
     *         if the buffer is empty
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public MemorySegment getBufferPointer() {
        ensureOpen();
        return NativeCall.callSeg(NativeMethods.LF_GetBuffer, handle);
    }

    // ==================================================================
    // Byte I/O - partial-read family
    // ==================================================================

    /**
     * Appends {@code data} at the current cursor.
     *
     * <p>The buffer grows as needed; the cursor advances by the number
     * of bytes written.
     *
     * @param data the bytes to append; must not be null
     * @return the number of bytes actually written (equal to
     *         {@code data.length})
     * @throws NullPointerException             if {@code data} is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     * @throws LingoFuseIoException             if the native layer
     *                                          accepts fewer bytes than
     *                                          requested
     */
    public long writeBytes(byte[] data) {
        Objects.requireNonNull(data, "data must not be null");
        ensureOpen();

        if (data.length == 0) {
            return 0L;
        }

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment buf = arena.allocate(data.length);
            MemorySegment.copy(data, 0, buf, ValueLayout.JAVA_BYTE,
                    0, data.length);

            long written = NativeCall.callLong(
                    NativeMethods.LF_WriteBuffer, handle, buf, (long) data.length);

            if (written != data.length) {
                throw new LingoFuseIoException(
                        "writeBytes requested " + data.length
                                + " bytes but only " + written
                                + " were written.",
                        "writeBytes");
            }
            return written;
        }
    }

    /**
     * Reads up to {@code count} bytes into a new array.
     *
     * <p>The cursor advances by the number of bytes actually read.
     *
     * @param count the maximum number of bytes to read; must be
     *              non-negative
     * @return the bytes actually read (never null; empty at
     *         end-of-buffer; may be shorter than {@code count})
     * @throws IllegalArgumentException          if {@code count} is
     *                                           negative
     * @throws LingoFuseObjectDisposedException  if the handle has been
     *                                           closed
     */
    public byte[] readBytes(int count) {
        if (count < 0) {
            throw new IllegalArgumentException(
                    "Count must be non-negative: " + count);
        }
        ensureOpen();

        if (count == 0) {
            return new byte[0];
        }

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment buf = arena.allocate(count);
            long read = NativeCall.callLong(
                    NativeMethods.LF_ReadBuffer, handle, buf, (long) count);

            if (read <= 0) {
                return new byte[0];
            }
            return buf.asSlice(0, read).toArray(ValueLayout.JAVA_BYTE);
        }
    }

    // ==================================================================
    // Byte I/O - exact-read family
    // ==================================================================

    /**
     * Reads exactly {@code count} bytes. Throws on a short read. The
     * cursor advances by exactly {@code count} bytes on success and is
     * left unchanged on failure.
     *
     * @param count the exact number of bytes to read; must be
     *              non-negative
     * @return the bytes read
     * @throws IllegalArgumentException          if {@code count} is
     *                                           negative
     * @throws LingoFuseObjectDisposedException  if the handle has been
     *                                           closed
     * @throws LingoFuseIoException              if fewer than
     *                                           {@code count} bytes
     *                                           are available
     */
    public byte[] readBytesExact(int count) {
        if (count < 0) {
            throw new IllegalArgumentException(
                    "Count must be non-negative: " + count);
        }
        ensureOpen();

        if (count == 0) {
            return new byte[0];
        }

        long savedPos = position();
        byte[] buffer = readBytes(count);
        if (buffer.length != count) {
            setPosition(savedPos);
            throw new LingoFuseIoException(
                    "readBytesExact requested " + count
                            + " bytes but only " + buffer.length
                            + " were available.",
                    "readBytesExact");
        }
        return buffer;
    }

    /**
     * Non-throwing counterpart of {@link #readBytesExact(int)}.
     *
     * <p>The cursor advances by {@code count} bytes on success and is
     * left unchanged on failure.
     *
     * @param count the exact number of bytes to read
     * @return a two-element result: {@code [0]} is a boolean flag,
     *         {@code [1]} is the byte array on success
     */
    public ReadResult<byte[]> tryReadBytes(int count) {
        if (count < 0) {
            throw new IllegalArgumentException(
                    "Count must be non-negative: " + count);
        }
        ensureOpen();

        if (count == 0) {
            return ReadResult.success(new byte[0]);
        }

        long savedPos = position();
        byte[] buffer = readBytes(count);
        if (buffer.length != count) {
            setPosition(savedPos);
            return ReadResult.failure();
        }
        return ReadResult.success(buffer);
    }

    /**
     * Reads every remaining byte from the current cursor to the end of
     * the buffer and advances the cursor to the end.
     *
     * @return the remaining bytes; empty when the cursor is already at
     *         or past the end
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public byte[] readAllBytes() {
        ensureOpen();
        long pos = position();
        long total = size();
        if (pos >= total) {
            return new byte[0];
        }
        return readBytes((int) (total - pos));
    }

    // ==================================================================
    // Atomic write helpers (little-endian)
    // ==================================================================

    /** Writes an 8-bit signed integer. The cursor advances by 1 byte. */
    public void writeInt8(byte value) {
        writeBytes(new byte[]{value});
    }

    /** Writes an 8-bit unsigned integer. The cursor advances by 1 byte. */
    public void writeUInt8(int value) {
        writeBytes(new byte[]{(byte) (value & 0xFF)});
    }

    /** Writes a 16-bit signed integer. The cursor advances by 2 bytes. */
    public void writeInt16(short value) {
        writeBytes(ByteBuffer.allocate(2).order(LE).putShort(value).array());
    }

    /** Writes a 16-bit unsigned integer. The cursor advances by 2 bytes. */
    public void writeUInt16(int value) {
        writeBytes(ByteBuffer.allocate(2).order(LE)
                .putShort((short) (value & 0xFFFF)).array());
    }

    /** Writes a 32-bit signed integer. The cursor advances by 4 bytes. */
    public void writeInt32(int value) {
        writeBytes(ByteBuffer.allocate(4).order(LE).putInt(value).array());
    }

    /** Writes a 32-bit unsigned integer. The cursor advances by 4 bytes. */
    public void writeUInt32(long value) {
        writeBytes(ByteBuffer.allocate(4).order(LE)
                .putInt((int) (value & 0xFFFFFFFFL)).array());
    }

    /** Writes a 64-bit signed integer. The cursor advances by 8 bytes. */
    public void writeInt64(long value) {
        writeBytes(ByteBuffer.allocate(8).order(LE).putLong(value).array());
    }

    /** Writes a 64-bit unsigned integer. The cursor advances by 8 bytes. */
    public void writeUInt64(long value) {
        // Java has no unsigned long; the bit pattern is preserved.
        writeBytes(ByteBuffer.allocate(8).order(LE).putLong(value).array());
    }

    /** Writes a 32-bit single-precision float. The cursor advances by 4 bytes. */
    public void writeSingle(float value) {
        writeBytes(ByteBuffer.allocate(4).order(LE).putFloat(value).array());
    }

    /** Writes a 64-bit double-precision float. The cursor advances by 8 bytes. */
    public void writeDouble(double value) {
        writeBytes(ByteBuffer.allocate(8).order(LE).putDouble(value).array());
    }

    // ==================================================================
    // Atomic read helpers (little-endian) - exact semantics
    // ==================================================================

    /** Reads an 8-bit signed integer. Requires 1 byte. */
    public byte readInt8() {
        return readBytesExact(1)[0];
    }

    /** Reads an 8-bit unsigned integer. Requires 1 byte. */
    public int readUInt8() {
        return readBytesExact(1)[0] & 0xFF;
    }

    /** Reads a 16-bit signed integer. Requires 2 bytes. */
    public short readInt16() {
        return ByteBuffer.wrap(readBytesExact(2)).order(LE).getShort();
    }

    /** Reads a 16-bit unsigned integer. Requires 2 bytes. */
    public int readUInt16() {
        return ByteBuffer.wrap(readBytesExact(2)).order(LE).getShort() & 0xFFFF;
    }

    /** Reads a 32-bit signed integer. Requires 4 bytes. */
    public int readInt32() {
        return ByteBuffer.wrap(readBytesExact(4)).order(LE).getInt();
    }

    /** Reads a 32-bit unsigned integer. Requires 4 bytes. */
    public long readUInt32() {
        return ByteBuffer.wrap(readBytesExact(4)).order(LE).getInt() & 0xFFFFFFFFL;
    }

    /** Reads a 64-bit signed integer. Requires 8 bytes. */
    public long readInt64() {
        return ByteBuffer.wrap(readBytesExact(8)).order(LE).getLong();
    }

    /** Reads a 64-bit unsigned integer. Requires 8 bytes. */
    public long readUInt64() {
        // Java has no unsigned long; the bit pattern is returned as-is.
        return ByteBuffer.wrap(readBytesExact(8)).order(LE).getLong();
    }

    /** Reads a 32-bit single-precision float. Requires 4 bytes. */
    public float readSingle() {
        return ByteBuffer.wrap(readBytesExact(4)).order(LE).getFloat();
    }

    /** Reads a 64-bit double-precision float. Requires 8 bytes. */
    public double readDouble() {
        return ByteBuffer.wrap(readBytesExact(8)).order(LE).getDouble();
    }

    // ==================================================================
    // NUL-framed string I/O
    // ==================================================================

    /**
     * Writes {@code value} as UTF-8, followed by a single NUL byte.
     * An empty string writes exactly one byte (the NUL).
     *
     * @param value the UTF-8 string; must not be null
     * @throws NullPointerException             if {@code value} is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     * @throws LingoFuseIoException             if the native layer
     *                                          accepts fewer bytes than
     *                                          requested
     */
    public void writeString(String value) {
        Objects.requireNonNull(value, "value must not be null");
        ensureOpen();

        byte[] utf8 = value.getBytes(UTF8);
        long total = utf8.length + 1L;

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment buf = arena.allocate(total);
            if (utf8.length > 0) {
                MemorySegment.copy(utf8, 0, buf, ValueLayout.JAVA_BYTE,
                        0, utf8.length);
            }
            buf.set(ValueLayout.JAVA_BYTE, utf8.length, (byte) 0);

            long written = NativeCall.callLong(
                    NativeMethods.LF_WriteBuffer, handle, buf, total);

            if (written != total) {
                throw new LingoFuseIoException(
                        "writeString wrote " + written + " of "
                                + total + " bytes.",
                        "writeString");
            }
        }
    }

    /**
     * Reads a UTF-8 string from the current cursor, stopping at the
     * first NUL byte.
     *
     * <p>When no NUL is found before the end of the buffer, all
     * remaining bytes are consumed and returned.
     *
     * <p>Invalid UTF-8 byte sequences are decoded with the encoder's
     * default fallback (each invalid byte becomes U+FFFD). Callers
     * that need to detect invalid UTF-8 must read the raw bytes and
     * inspect them directly.
     *
     * @return the decoded string; empty when the cursor is at or past
     *         the end of the buffer, or when the first byte is a NUL
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public String readString() {
        ensureOpen();

        long start = position();
        long total = size();

        if (start >= total) {
            return "";
        }

        MemorySegment buffer = getBufferPointer();
        if (isNull(buffer)) {
            return "";
        }

        // The pointer returned by LF_GetBuffer is a zero-size segment
        // (it comes from a void* return value). Reinterpret it to the
        // known buffer size so that we can safely walk it.
        MemorySegment bounded = buffer.reinterpret(total);

        long scan = start;
        while (scan < total
                && bounded.get(ValueLayout.JAVA_BYTE, scan) != 0) {
            scan++;
        }

        int length = (int) (scan - start);
        String result;
        if (length == 0) {
            result = "";
        } else {
            byte[] bytes = new byte[length];
            MemorySegment.copy(bounded, ValueLayout.JAVA_BYTE, start,
                    bytes, 0, length);
            result = new String(bytes, UTF8);
        }

        // Advance past the NUL when found; otherwise to one byte past
        // the end, matching the native fault-tolerant read behaviour.
        setPosition(scan < total ? scan + 1 : total + 1);

        return result;
    }

    /**
     * Non-throwing counterpart of {@link #readString()}.
     *
     * <p>The only recoverable failure mode is an exhausted buffer; a
     * closed handle still throws.
     *
     * @return a two-element result: {@code [0]} is a boolean flag,
     *         {@code [1]} is the string on success
     * @throws LingoFuseObjectDisposedException if the handle has been
     *                                          closed
     */
    public ReadResult<String> tryReadString() {
        ensureOpen();

        long start = position();
        long total = size();
        if (start >= total) {
            return ReadResult.failure();
        }
        return ReadResult.success(readString());
    }

    // ==================================================================
    // Internal helpers
    // ==================================================================

    private void ensureOpen() {
        // The volatile read of `handle` makes a concurrent close
        // visible to this thread.
        if (closed || isNull(handle)) {
            throw new LingoFuseObjectDisposedException("DataHandle");
        }
    }

    private static boolean isNull(MemorySegment seg) {
        return seg == null
                || seg.address() == 0L;
    }

    // ------------------------------------------------------------------
    // Read result
    // ------------------------------------------------------------------

    /**
     * A two-state result: success with a value, or failure with no
     * value. Used by the {@code tryRead*} family so that the caller
     * does not need to distinguish a legitimate empty value from a
     * failure.
     *
     * @param <T> the value type
     */
    public static final class ReadResult<T> {

        private final boolean ok;
        private final T value;

        private ReadResult(boolean ok, T value) {
            this.ok = ok;
            this.value = value;
        }

        /**
         * Creates a success result.
         *
         * @param value the value
         * @param <T>   the value type
         * @return a success result
         */
        public static <T> ReadResult<T> success(T value) {
            return new ReadResult<>(true, value);
        }

        /**
         * Creates a failure result.
         *
         * @param <T> the value type
         * @return a failure result
         */
        public static <T> ReadResult<T> failure() {
            return new ReadResult<>(false, null);
        }

        /**
         * Returns whether the operation succeeded.
         *
         * @return true on success
         */
        public boolean isOk() {
            return ok;
        }

        /**
         * Returns the value, or null on failure.
         *
         * @return the value, or null
         */
        public T getValue() {
            return value;
        }
    }
}