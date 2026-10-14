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
import java.util.concurrent.locks.ReentrantReadWriteLock;
import java.util.function.Function;

/**
 * RAII wrapper around a native LingoFuse data handle ({@code TDataHnd}).
 *
 * <p>Owns a native data handle and releases it deterministically on
 * {@link #close()}. Provides byte-level, atomic-type, and NUL-framed
 * string I/O on top of the underlying buffer.
 *
 * <h2>Thread safety</h2>
 *
 * <p>A single instance is guarded by an internal
 * {@link ReentrantReadWriteLock}. Mutating operations (write, seek,
 * setSize, close) acquire the write lock; read-only accessors
 * (position, size) acquire the read lock. This closes the race
 * between {@code close()} and any concurrent I/O, and prevents the
 * buffer-reallocation use-after-free that occurred when a reader
 * held a raw pointer into the buffer while another thread triggered
 * a resize.
 *
 * <h3>Passing the handle to a native call</h3>
 *
 * <p>Every native call that consumes the handle must go through
 * {@link #withHandle(Function)} rather than reading {@link #raw()}
 * directly. {@code withHandle} holds the write lock for the entire
 * duration of the native call, which prevents a concurrent
 * {@link #close()} from freeing the handle between the moment
 * {@code raw()} is read and the moment the native function receives
 * it.
 *
 * <pre>{@code
 * // Correct: the handle cannot be closed during the call.
 * param.withHandle(h ->
 *     NativeCall.callSeg(NativeMethods.LF_Call, nameSeg, h, timeout));
 *
 * // Incorrect: a concurrent close() can free the handle between
 * // param.raw() and the native call, causing use-after-free.
 * NativeCall.callSeg(NativeMethods.LF_Call, nameSeg, param.raw(), timeout);
 * }</pre>
 *
 * <p>{@link #getBufferPointer()} is a low-level escape hatch whose
 * result is valid only while the caller holds the handle exclusively.
 * Prefer {@link #readStringBytes()} or {@link #withHandle(Function)}
 * for any operation that reads through a raw buffer pointer.
 */
public final class DataHandle implements AutoCloseable {

    private static final java.nio.charset.Charset UTF8 = StandardCharsets.UTF_8;
    private static final ByteOrder LE = ByteOrder.LITTLE_ENDIAN;
    private static final long MAX_C_STRING_LENGTH = 1024L * 1024L;

    /*
     * ==================================================================
     * CROSS-LANGUAGE COMPATIBILITY NOTE
     * ------------------------------------------------------------------
     * This lock is a JAVA-PRIVATE thread-serialisation mechanism. It
     * guards concurrent access to a SINGLE DataHandle instance from
     * multiple Java threads.
     *
     * It does NOT cross the wire.
     * It does NOT change the byte sequence of any request or response.
     * It does NOT change the calling convention, argument order, or
     *   return semantics of any LF_* function.
     *
     * Other LingoFuse bindings (Pascal / Python / C++ / C# / JS) do
     * NOT need an equivalent lock; the LingoFuse ABI already specifies
     * that a single TDataHnd must not be written concurrently.
     *
     * DO NOT refactor this lock into the FFI layer or the wire layer.
     * ==================================================================
     */
    private final ReentrantReadWriteLock ioLock = new ReentrantReadWriteLock();

    private volatile MemorySegment handle;
    private final boolean owned;
    private volatile boolean closed;

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

    private DataHandle(MemorySegment raw, boolean owned) {
        this.handle = raw;
        this.owned = owned;
        this.closed = false;
    }

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

    public static DataHandle fromRaw(MemorySegment raw, boolean owned) {
        return new DataHandle(raw, owned);
    }

    /**
     * Returns the raw native pointer without any lifecycle protection.
     *
     * <p><b>Do not pass the result directly to a native call.</b>
     * Use {@link #withHandle(Function)} instead: the pointer returned
     * here is not protected against a concurrent {@link #close()}.
     *
     * <p>This accessor exists for diagnostics (comparing two handles
     * for identity) and for the rare case where a caller already
     * holds the write lock through some other means.
     *
     * @return the raw native pointer, or {@link MemorySegment#NULL}
     *         after {@link #close()}
     */
    public MemorySegment raw() {
        return handle;
    }

    public boolean isValid() {
        return !closed && !isNull(handle);
    }

    public boolean isOwning() {
        return owned;
    }

    /**
     * Executes {@code action} while holding the internal write lock
     * and with a guaranteed-valid handle. The action receives the raw
     * native pointer; it must not retain it beyond the call.
     *
     * <p>This is the correct way for callers to pass the handle to a
     * native function: it prevents a concurrent {@link #close()} from
     * freeing the handle while the native call is executing.
     *
     * <p>The write lock (not the read lock) is used deliberately. A
     * native call may read from AND write to the handle — for example,
     * {@code LF_Call} internally increments the handle's "calling"
     * counter and advances its cursor — so the more conservative
     * exclusive lock is required.
     *
     * @param action the action to run; receives the raw handle pointer
     * @param <T> the return type
     * @return whatever {@code action} returns
     * @throws NullPointerException if {@code action} is null
     * @throws LingoFuseObjectDisposedException if the handle has been
     *         closed
     */
    public <T> T withHandle(Function<MemorySegment, T> action) {
        Objects.requireNonNull(action, "action must not be null");
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            return action.apply(handle);
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    @Override
    public void close() {
        ioLock.writeLock().lock();
        try {
            if (closed) {
                return;
            }
            if (!owned) {
                return;
            }
            closed = true;
            MemorySegment snapshot = handle;
            handle = MemorySegment.NULL;
            if (!isNull(snapshot)) {
                NativeCall.callVoid(NativeMethods.LF_FreeData, snapshot);
            }
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    public long position() {
        ioLock.readLock().lock();
        try {
            ensureOpen();
            return NativeCall.callLong(NativeMethods.LF_GetPos, handle);
        } finally {
            ioLock.readLock().unlock();
        }
    }

    public void setPosition(long pos) {
        if (pos < 0) {
            throw new IllegalArgumentException(
                    "Position must be non-negative: " + pos);
        }
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            NativeCall.callVoid(NativeMethods.LF_SetPos, handle, pos);
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    public long size() {
        ioLock.readLock().lock();
        try {
            ensureOpen();
            return NativeCall.callLong(NativeMethods.LF_GetSize, handle);
        } finally {
            ioLock.readLock().unlock();
        }
    }

    public void setSize(long newSize) {
        if (newSize < 0) {
            throw new IllegalArgumentException(
                    "Size must be non-negative: " + newSize);
        }
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            NativeCall.callVoid(NativeMethods.LF_SetSize, handle, newSize);
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    /**
     * Returns the native pointer to the internal buffer.
     *
     * <p><b>The returned pointer is valid only while the caller holds
     * the handle exclusively.</b> Any subsequent {@code write},
     * {@code setSize}, or implicit buffer growth reallocates the
     * buffer and leaves the previous pointer dangling. In a
     * multi-threaded program, any concurrent operation on this handle
     * can invalidate the pointer.
     *
     * <p>Prefer {@link #readStringBytes()} or
     * {@link #withHandle(Function)} for anything that reads through a
     * raw buffer pointer; they hold the write lock for the entire
     * operation and therefore guarantee pointer validity.
     *
     * <p>The pointer must NOT be freed by the caller.
     *
     * @return the native buffer pointer, or {@code null} if the buffer
     *         is empty
     */
    public MemorySegment getBufferPointer() {
        ioLock.readLock().lock();
        try {
            ensureOpen();
            return NativeCall.callSeg(NativeMethods.LF_GetBuffer, handle);
        } finally {
            ioLock.readLock().unlock();
        }
    }

    public long writeBytes(byte[] data) {
        Objects.requireNonNull(data, "data must not be null");
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            if (data.length == 0) {
                return 0L;
            }
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment buf = arena.allocate(data.length);
                MemorySegment.copy(data, 0, buf, ValueLayout.JAVA_BYTE,
                        0, data.length);
                long written = NativeCall.callLong(
                        NativeMethods.LF_WriteBuffer, handle, buf,
                        (long) data.length);
                if (written != data.length) {
                    throw new LingoFuseIoException(
                            "writeBytes requested " + data.length
                                    + " bytes but only " + written
                                    + " were written.",
                            "writeBytes");
                }
                return written;
            }
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    public byte[] readBytes(int count) {
        if (count < 0) {
            throw new IllegalArgumentException(
                    "Count must be non-negative: " + count);
        }
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            return readBytesLocked(count);
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    public byte[] readBytesExact(int count) {
        if (count < 0) {
            throw new IllegalArgumentException(
                    "Count must be non-negative: " + count);
        }
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            if (count == 0) {
                return new byte[0];
            }
            long savedPos = NativeCall.callLong(NativeMethods.LF_GetPos, handle);
            byte[] buffer = readBytesLocked(count);
            if (buffer.length != count) {
                NativeCall.callVoid(NativeMethods.LF_SetPos, handle, savedPos);
                throw new LingoFuseIoException(
                        "readBytesExact requested " + count
                                + " bytes but only " + buffer.length
                                + " were available.",
                        "readBytesExact");
            }
            return buffer;
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    public ReadResult<byte[]> tryReadBytes(int count) {
        if (count < 0) {
            throw new IllegalArgumentException(
                    "Count must be non-negative: " + count);
        }
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            if (count == 0) {
                return ReadResult.success(new byte[0]);
            }
            long savedPos = NativeCall.callLong(NativeMethods.LF_GetPos, handle);
            byte[] buffer = readBytesLocked(count);
            if (buffer.length != count) {
                NativeCall.callVoid(NativeMethods.LF_SetPos, handle, savedPos);
                return ReadResult.failure();
            }
            return ReadResult.success(buffer);
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    public byte[] readAllBytes() {
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            long pos = NativeCall.callLong(NativeMethods.LF_GetPos, handle);
            long total = NativeCall.callLong(NativeMethods.LF_GetSize, handle);
            if (pos >= total) {
                return new byte[0];
            }
            return readBytesLocked((int) (total - pos));
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    // -------- Atomic writes (little-endian) --------

    public void writeInt8(byte value) {
        writeBytes(new byte[]{value});
    }

    public void writeUInt8(int value) {
        writeBytes(new byte[]{(byte) (value & 0xFF)});
    }

    public void writeInt16(short value) {
        writeBytes(ByteBuffer.allocate(2).order(LE).putShort(value).array());
    }

    public void writeUInt16(int value) {
        writeBytes(ByteBuffer.allocate(2).order(LE)
                .putShort((short) (value & 0xFFFF)).array());
    }

    public void writeInt32(int value) {
        writeBytes(ByteBuffer.allocate(4).order(LE).putInt(value).array());
    }

    public void writeUInt32(long value) {
        writeBytes(ByteBuffer.allocate(4).order(LE)
                .putInt((int) (value & 0xFFFFFFFFL)).array());
    }

    public void writeInt64(long value) {
        writeBytes(ByteBuffer.allocate(8).order(LE).putLong(value).array());
    }

    public void writeUInt64(long value) {
        writeBytes(ByteBuffer.allocate(8).order(LE).putLong(value).array());
    }

    public void writeSingle(float value) {
        writeBytes(ByteBuffer.allocate(4).order(LE).putFloat(value).array());
    }

    public void writeDouble(double value) {
        writeBytes(ByteBuffer.allocate(8).order(LE).putDouble(value).array());
    }

    // -------- Atomic reads (little-endian, exact) --------

    public byte readInt8() {
        return readBytesExact(1)[0];
    }

    public int readUInt8() {
        return readBytesExact(1)[0] & 0xFF;
    }

    public short readInt16() {
        return ByteBuffer.wrap(readBytesExact(2)).order(LE).getShort();
    }

    public int readUInt16() {
        return ByteBuffer.wrap(readBytesExact(2)).order(LE).getShort() & 0xFFFF;
    }

    public int readInt32() {
        return ByteBuffer.wrap(readBytesExact(4)).order(LE).getInt();
    }

    public long readUInt32() {
        return ByteBuffer.wrap(readBytesExact(4)).order(LE).getInt() & 0xFFFFFFFFL;
    }

    public long readInt64() {
        return ByteBuffer.wrap(readBytesExact(8)).order(LE).getLong();
    }

    public long readUInt64() {
        return ByteBuffer.wrap(readBytesExact(8)).order(LE).getLong();
    }

    public float readSingle() {
        return ByteBuffer.wrap(readBytesExact(4)).order(LE).getFloat();
    }

    public double readDouble() {
        return ByteBuffer.wrap(readBytesExact(8)).order(LE).getDouble();
    }

    // -------- NUL-framed strings --------

    public void writeString(String value) {
        Objects.requireNonNull(value, "value must not be null");
        ioLock.writeLock().lock();
        try {
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
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    public String readString() {
        ioLock.writeLock().lock();
        try {
            ensureOpen();
            long start = NativeCall.callLong(NativeMethods.LF_GetPos, handle);
            long total = NativeCall.callLong(NativeMethods.LF_GetSize, handle);

            if (start >= total) {
                return "";
            }

            MemorySegment buffer = NativeCall.callSeg(
                    NativeMethods.LF_GetBuffer, handle);
            if (isNull(buffer)) {
                return "";
            }

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

            NativeCall.callVoid(NativeMethods.LF_SetPos, handle,
                    scan < total ? scan + 1 : total + 1);
            return result;
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    /**
     * Reads raw bytes from the current cursor, stopping at the first
     * NUL.
     *
     * <p>Unlike {@link #readAllBytes()}, which consumes the entire
     * remaining buffer, this stops at the NUL that
     * {@link #writeString(String)} / {@code LfIo.writeJson} append.
     * The bytes are returned undecoded, so the caller can inspect or
     * forward them without a UTF-8 round-trip.
     *
     * <p>The whole read — cursor query, buffer-pointer acquisition,
     * NUL scan, byte copy, and cursor advance — is performed under
     * the internal write lock. This is the property that makes the
     * read safe against a concurrent writer: the buffer pointer
     * obtained from {@code LF_GetBuffer} is valid for the entire
     * scan-and-copy sequence, and no other thread can reallocate the
     * buffer under our feet.
     *
     * <p>This accessor is the one to use inside a bridge or proxy
     * that forwards a payload unchanged to a downstream consumer.
     *
     * @return the bytes before the NUL; empty when the cursor is at
     *         or past the end, or when the first byte is a NUL
     * @throws LingoFuseObjectDisposedException if the handle has been
     *         closed
     */
    public byte[] readStringBytes() {
        ioLock.writeLock().lock();
        try {
            ensureOpen();

            long start = NativeCall.callLong(NativeMethods.LF_GetPos, handle);
            long total = NativeCall.callLong(NativeMethods.LF_GetSize, handle);
            if (start >= total) {
                return new byte[0];
            }

            MemorySegment buffer = NativeCall.callSeg(
                    NativeMethods.LF_GetBuffer, handle);
            if (isNull(buffer)) {
                return new byte[0];
            }

            MemorySegment bounded = buffer.reinterpret(total);
            long scan = start;
            while (scan < total
                    && bounded.get(ValueLayout.JAVA_BYTE, scan) != 0) {
                scan++;
            }

            int length = (int) (scan - start);
            byte[] result = new byte[length];
            if (length > 0) {
                MemorySegment.copy(bounded, ValueLayout.JAVA_BYTE, start,
                        result, 0, length);
            }

            // Advance past the NUL when found; otherwise to one byte
            // past the end, matching the native fault-tolerant read
            // behaviour.
            NativeCall.callVoid(NativeMethods.LF_SetPos, handle,
                    scan < total ? scan + 1 : total + 1);
            return result;
        } finally {
            ioLock.writeLock().unlock();
        }
    }

    public ReadResult<String> tryReadString() {
        ioLock.readLock().lock();
        try {
            ensureOpen();
            long start = NativeCall.callLong(NativeMethods.LF_GetPos, handle);
            long total = NativeCall.callLong(NativeMethods.LF_GetSize, handle);
            if (start >= total) {
                return ReadResult.failure();
            }
        } finally {
            ioLock.readLock().unlock();
        }
        return ReadResult.success(readString());
    }

    // -------- Auto sender identity (side data) --------

    public byte[] getP2pUid() {
        ioLock.readLock().lock();
        try {
            ensureOpen();
            MemorySegment ptr = NativeCall.callSeg(
                    NativeMethods.LF_Get_P2P_UID, handle);
            if (isNull(ptr)) {
                return new byte[32];
            }
            return ptr.reinterpret(32).toArray(ValueLayout.JAVA_BYTE);
        } finally {
            ioLock.readLock().unlock();
        }
    }

    public String getP2pName() {
        ioLock.readLock().lock();
        try {
            ensureOpen();
            MemorySegment ptr = NativeCall.callSeg(
                    NativeMethods.LF_Get_P2P_Name, handle);
            if (isNull(ptr)) {
                return "";
            }
            return ptr.reinterpret(MAX_C_STRING_LENGTH).getString(0);
        } finally {
            ioLock.readLock().unlock();
        }
    }

    // -------- Internal helpers (already locked by caller) --------

    private byte[] readBytesLocked(int count) {
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

    private void ensureOpen() {
        if (closed || isNull(handle)) {
            throw new LingoFuseObjectDisposedException("DataHandle");
        }
    }

    private static boolean isNull(MemorySegment seg) {
        return seg == null || seg.address() == 0L;
    }

    public static final class ReadResult<T> {

        private final boolean ok;
        private final T value;

        private ReadResult(boolean ok, T value) {
            this.ok = ok;
            this.value = value;
        }

        public static <T> ReadResult<T> success(T value) {
            return new ReadResult<>(true, value);
        }

        public static <T> ReadResult<T> failure() {
            return new ReadResult<>(false, null);
        }

        public boolean isOk() {
            return ok;
        }

        public T getValue() {
            return value;
        }
    }
}