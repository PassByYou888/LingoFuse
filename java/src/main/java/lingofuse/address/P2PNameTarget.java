package lingofuse.address;

import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.util.Objects;

/**
 * Addresses a group of clients by their shared P2P name.
 *
 * <p>Routing is NOT local-first. Even when the caller process itself
 * hosts a client in the target group, the call is forwarded to the
 * server for dispatch. This is a deliberate design choice: the
 * server-side dispatcher owns the load-balancing state, and
 * short-cutting locally would defeat it.
 *
 * <h2>Selection strategy</h2>
 *
 * <p>The server-side dispatcher picks a target using one of two
 * strategies:
 *
 * <ul>
 *   <li><b>Load balancing (Cycle_Anchor):</b> the target with the
 *       smallest anchor value is chosen, and its anchor is then
 *       advanced so that the next call lands elsewhere.</li>
 *   <li><b>Sticky affinity (FixedSequenced):</b> the same target is
 *       kept for a bounded period, governed by the runtime option
 *       {@code Fixed_Sequenced_Time} (default 20 seconds).</li>
 * </ul>
 *
 * <h2>Group name source</h2>
 *
 * <p>The group name is the value a client sets via the runtime option
 * {@code LF_P2P_name} (see {@code Options.setP2pName}). Multiple
 * clients can share a group name; the server dispatches calls among
 * them.
 *
 * <p>This is distinct from the P2P name that a RECEIVER reads from a
 * callback's INPUT handle via {@code DataHandle.getP2pName()}: the
 * latter is side data injected by the sender's transport layer,
 * identifying the sender. Both are strings of the same wire type, but
 * they come from two different sources and serve two different
 * purposes.
 *
 * <h2>Handle access</h2>
 *
 * <p>The synchronous and one-way hooks delegate to {@link Framework},
 * which already routes the request handle through
 * {@link DataHandle#withHandle(java.util.function.Function)}. The two
 * asynchronous hooks that call the native library directly do the
 * same: they obtain the native pointer through
 * {@code param.withHandle(h -> ...)} rather than {@code param.raw()},
 * so a concurrent {@link DataHandle#close()} cannot free the handle
 * while the native call is executing.
 */
public final class P2PNameTarget extends Target {

    /** The default timeout used when the caller does not supply one. */
    public static final long DEFAULT_TIMEOUT_MS = 5000L;

    private final String groupName;

    /**
     * Creates a P2PNameTarget with the default timeout.
     *
     * @param groupName the P2P group name; must not be null
     */
    public P2PNameTarget(String groupName) {
        this(groupName, DEFAULT_TIMEOUT_MS);
    }

    /**
     * Creates a P2PNameTarget with an explicit default timeout.
     *
     * @param groupName        the P2P group name; must not be null
     * @param defaultTimeoutMs the default timeout in milliseconds
     */
    public P2PNameTarget(String groupName, long defaultTimeoutMs) {
        super(defaultTimeoutMs);
        this.groupName = Objects.requireNonNull(groupName,
                "groupName must not be null");
    }

    /** Returns the P2P group name this target addresses. */
    public String groupName() {
        return groupName;
    }

    // ==================================================================
    // Subclass hook implementations
    // ==================================================================

    @Override
    protected DataHandle rawCall(DataHandle param, long timeoutMs) {
        return Framework.p2pCall(groupName, param, timeoutMs);
    }

    @Override
    protected int rawAsyncCall(DataHandle param, MemorySegment stub) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(groupName);
            return param.withHandle(h -> NativeCall.callInt(
                    NativeMethods.LF_P2PNAME_Async_Call,
                    groupSeg, h, MemorySegment.NULL, stub));
        }
    }

    @Override
    protected int rawAsyncSequencedCall(DataHandle param, MemorySegment stub) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(groupName);
            return param.withHandle(h -> NativeCall.callInt(
                    NativeMethods.LF_P2PNAME_Async_Sequenced_Call,
                    groupSeg, h, MemorySegment.NULL, stub));
        }
    }

    @Override
    protected void rawNotify(DataHandle param) {
        Framework.p2pNotify(groupName, param);
    }

    @Override
    protected void rawSequencedNotify(DataHandle param) {
        Framework.p2pSequencedNotify(groupName, param);
    }

    @Override
    public String describe() {
        return "p2pname(" + groupName + ")";
    }

    // ==================================================================
    // Value semantics
    // ==================================================================

    @Override
    public String toString() {
        return "P2PNameTarget(" + groupName + ")";
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (!(o instanceof P2PNameTarget other)) {
            return false;
        }
        return groupName.equals(other.groupName);
    }

    @Override
    public int hashCode() {
        return groupName.hashCode();
    }
}