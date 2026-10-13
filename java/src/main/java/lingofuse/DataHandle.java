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

/**
 * RAII wrapper around a native LingoFuse data handle ({@code TDataHnd}).
 *
 * <p>Owns a native data handle and releases it deterministically on
 * {@link #close()}. Provides byte-level, atomic-type, and NUL-framed
 * string I/O on top of the underlying buffer.
 *
 * <p>Thread safety: a single instance is guarded by an internal
 * {@link ReentrantReadWriteLock}. Mutating operations (write, seek,
 * setSize, close) acquire the write lock; read-only accessors
 * (position, size, getBufferPointer) acquire the read lock. This
 * closes the historical race between {@code close()} and any
 * concurrent I/O, and prevents the buffer-reallocation use-after-free
 * that occurred when a reader held a raw pointer into the buffer
 * while another thread triggered a resize.
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

    public MemorySegment raw() {
        return handle;
    }

    public boolean isValid() {
        return !closed && !isNull(handle);
    }

    public boolean isOwning() {
        return owned;
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