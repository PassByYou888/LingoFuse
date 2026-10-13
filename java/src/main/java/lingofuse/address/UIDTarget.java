package lingofuse.address;

import lingofuse.DataHandle;
import lingofuse.errors.LingoFuseException;
import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;
import lingofuse.ffi.NativeTypes;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.Arrays;
import java.util.Objects;

/**
 * Addresses a specific session by its 32-byte UID.
 *
 * <p>Routing is LOCAL-FIRST, matching App-name routing. The UID can
 * address ANY API registered on the target -- whether app-bound (via
 * {@code AppHandle.registerCall}) or process-wide (via
 * {@code P2PRegistry.registerCall}) -- without requiring the caller to
 * know the target App name.
 *
 * <h2>UID argument representation</h2>
 *
 * <p>The C ABI declares the UID parameter of every {@code LF_UID_*}
 * function as {@code TP2P_UID___} (a 32-byte array). In cdecl an array
 * parameter decays to a pointer, so this class accepts the UID as a
 * Java {@code byte[]} of length exactly 32, copies it into a confined
 * Arena on every call, and passes the resulting segment.
 *
 * <p>The constructor validates the length and makes a defensive copy.
 * Mutating the caller's array after construction has no effect on
 * this target.
 *
 * <h2>UID lifecycle</h2>
 *
 * <p>A UID is regenerated on every TunnelLink. Caching a UID across
 * a link loss is unsafe; callers that cache must re-probe after a
 * reconnect. The canonical way to learn a client's own UID is the
 * "whoami" pattern described in {@link lingofuse.DataHandle#getP2pUid()}.
 */
public final class UIDTarget extends Target {

    /** The default timeout used when the caller does not supply one. */
    public static final long DEFAULT_TIMEOUT_MS = 5000L;

    private final byte[] uid;

    /**
     * Creates a UIDTarget with the default timeout.
     *
     * @param uid the 32-byte UID; must not be null and must be exactly
     *            32 bytes long
     * @throws NullPointerException     if {@code uid} is null
     * @throws IllegalArgumentException if {@code uid.length != 32}
     */
    public UIDTarget(byte[] uid) {
        this(uid, DEFAULT_TIMEOUT_MS);
    }

    /**
     * Creates a UIDTarget with an explicit default timeout.
     *
     * @param uid              the 32-byte UID
     * @param defaultTimeoutMs the default timeout in milliseconds
     * @throws NullPointerException     if {@code uid} is null
     * @throws IllegalArgumentException if {@code uid.length != 32}
     */
    public UIDTarget(byte[] uid, long defaultTimeoutMs) {
        super(defaultTimeoutMs);
        Objects.requireNonNull(uid, "uid must not be null");
        if (uid.length != NativeTypes.UID_BYTES) {
            throw new IllegalArgumentException(
                    "uid must be exactly " + NativeTypes.UID_BYTES
                            + " bytes, got " + uid.length);
        }
        // Defensive copy: the caller's array must not be able to
        // mutate this target after construction.
        this.uid = uid.clone();
    }

    /**
     * Returns a defensive copy of the UID.
     *
     * @return a fresh 32-byte array
     */
    public byte[] uidBytes() {
        return uid.clone();
    }

    // ==================================================================
    // Subclass hook implementations
    // ==================================================================

    @Override
    protected DataHandle rawCall(DataHandle param, long timeoutMs) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena);
            MemorySegment raw = NativeCall.callSeg(
                    NativeMethods.LF_UID_Call,
                    uidSeg,
                    param.raw(),
                    timeoutMs);
            if (raw == null || raw.address() == 0L) {
                throw new LingoFuseException(
                        "LF_UID_Call returned a null handle for uid="
                                + hex(uid) + ".");
            }
            return DataHandle.fromRaw(raw, true);
        }
    }

    @Override
    protected int rawAsyncCall(DataHandle param, MemorySegment stub) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena);
            return NativeCall.callInt(
                    NativeMethods.LF_UID_Async_Call,
                    uidSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    stub);
        }
    }

    @Override
    protected int rawAsyncSequencedCall(DataHandle param, MemorySegment stub) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena);
            return NativeCall.callInt(
                    NativeMethods.LF_UID_Async_Sequenced_Call,
                    uidSeg,
                    param.raw(),
                    MemorySegment.NULL,
                    stub);
        }
    }

    @Override
    protected void rawNotify(DataHandle param) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena);
            NativeCall.callVoid(
                    NativeMethods.LF_UID_Notify,
                    uidSeg,
                    param.raw());
        }
    }

    @Override
    protected void rawSequencedNotify(DataHandle param) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena);
            NativeCall.callVoid(
                    NativeMethods.LF_UID_Sequenced_Notify,
                    uidSeg,
                    param.raw());
        }
    }

    @Override
    public String describe() {
        return "uid(" + hex(uid) + ")";
    }

    // ==================================================================
    // Internal helpers
    // ==================================================================

    private MemorySegment allocateUid(Arena arena) {
        MemorySegment seg = arena.allocate(NativeTypes.UID_BYTES);
        MemorySegment.copy(uid, 0, seg, ValueLayout.JAVA_BYTE, 0,
                (int) NativeTypes.UID_BYTES);
        return seg;
    }

    private static String hex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(Character.forDigit((b >> 4) & 0x0F, 16));
            sb.append(Character.forDigit(b & 0x0F, 16));
        }
        return sb.toString();
    }

    // ==================================================================
    // Value semantics
    // ==================================================================

    @Override
    public String toString() {
        return "UIDTarget(" + hex(uid) + ")";
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (!(o instanceof UIDTarget other)) {
            return false;
        }
        return Arrays.equals(uid, other.uid);
    }

    @Override
    public int hashCode() {
        return Arrays.hashCode(uid);
    }
}