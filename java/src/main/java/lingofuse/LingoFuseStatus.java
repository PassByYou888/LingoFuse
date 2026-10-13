package lingofuse;

import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;
import lingofuse.ffi.NativeTypes;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * Status queue and health-check helpers for the LingoFuse runtime.
 *
 * <p>This class wraps the diagnostic and probing surface of the native
 * library:
 *
 * <ul>
 *   <li>the bounded status queue
 *       ({@link #getStatusCount()}, {@link #getStatus()},
 *       {@link #drainStatus(int)}, {@link #postStatus(String)});</li>
 *   <li>the main-thread liveness check
 *       ({@link #checkMainThread()});</li>
 *   <li>the App-name availability probes
 *       ({@link #checkApp(String)}, {@link #checkApi(String, String)});</li>
 *   <li>the UID availability probes
 *       ({@link #checkUid(byte[])},
 *       {@link #checkUidApi(byte[], String)});</li>
 *   <li>the P2PName availability probes
 *       ({@link #checkP2pName(String)},
 *       {@link #checkP2pNameApi(String, String)}).</li>
 * </ul>
 *
 * <h2>Status queue</h2>
 *
 * <p>The native library maintains a bounded FIFO of log messages, up
 * to 1000 entries. Older entries are dropped when the buffer is full.
 * Messages are surfaced through {@link #getStatus()} and can be
 * injected by the application through {@link #postStatus(String)}.
 *
 * <h2>Main-thread dependency</h2>
 *
 * <p>The status queue is processed by the native simulated main
 * thread. Before {@link Framework#prepareDone()} has been called, the
 * queue may be empty or contain stale data; applications should not
 * rely on status messages during initialization.
 *
 * <p>Injection is NOT subject to the same restriction:
 * {@link #postStatus(String)} queues the message even when the
 * simulated main thread is not yet running.
 *
 * <h2>Static buffer hazard</h2>
 *
 * <p>{@code LF_GetStatus} returns a pointer into a process-wide
 * static buffer that is overwritten by the next call. This wrapper
 * copies the string to a managed instance immediately, so callers
 * never observe a dangling pointer.
 *
 * <h2>Health checks</h2>
 *
 * <p>{@link #checkMainThread()} reports whether the simulated main
 * thread is running. All other probes are cache-based lookups that
 * are updated by network broadcasts with an approximate 3-second
 * delay. They are suitable for probing and diagnostics, not for
 * authoritative availability decisions. For critical paths, issue
 * the call and handle timeouts explicitly.
 *
 * <h2>UID argument representation</h2>
 *
 * <p>The C ABI declares the UID parameter of {@code LF_Check_UID} and
 * {@code LF_Check_UID_Api} as {@code TP2P_UID___} (a 32-byte array).
 * In cdecl an array parameter decays to a pointer, so this class
 * accepts the UID as a Java {@code byte[]} of length exactly 32,
 * copies it into a confined Arena on every call, and passes the
 * resulting segment. Length mismatches are rejected with
 * {@link IllegalArgumentException} before any native call is made.
 */
public final class LingoFuseStatus {

    private LingoFuseStatus() {
        // Utility class; no instances.
    }

    // ==================================================================
    // Status queue
    // ==================================================================

    /**
     * Returns the number of pending log messages in the status queue.
     *
     * @return the number of pending messages
     */
    public static int getStatusCount() {
        return NativeCall.callInt(NativeMethods.LF_GetStatusCount);
    }

    /**
     * Retrieves the next log message from the status queue, or an
     * empty string when the queue is empty.
     *
     * <p>The native function returns a pointer into a static buffer
     * that the very next call would overwrite. This method copies the
     * string immediately, so the caller never observes that hazard.
     *
     * <p>Caveat: the native ABI cannot distinguish "empty queue" from
     * "empty message"; both produce an empty string. Callers that
     * need to distinguish the two must call {@link #getStatusCount()}
     * first.
     *
     * @return the next message, or an empty string when the queue is
     *         empty
     */
    public static String getStatus() {
        MemorySegment ptr = NativeCall.callSeg(NativeMethods.LF_GetStatus);
        if (ptr == null || ptr.address() == 0L) {
            return "";
        }
        return ptr.reinterpret(Long.MAX_VALUE).getString(0);
    }

    /**
     * Drains up to {@code maxMessages} pending status messages and
     * returns them in FIFO order.
     *
     * <p>The method stops early when the native queue reports a
     * message of length zero, matching the historical behaviour of
     * the C# binding. An empty string can only be observed through
     * the queue in a corner case (a user explicitly posting an empty
     * message, or a race with another producer), so this early-exit
     * rule is a pragmatic choice that keeps the common path efficient.
     *
     * @param maxMessages the upper bound on the number of messages to
     *                    retrieve; must be non-negative
     * @return the messages actually retrieved, in FIFO order; empty
     *         when the queue was empty
     * @throws IllegalArgumentException if {@code maxMessages} is
     *                                  negative
     */
    public static List<String> drainStatus(int maxMessages) {
        if (maxMessages < 0) {
            throw new IllegalArgumentException(
                    "maxMessages must be non-negative: " + maxMessages);
        }
        if (maxMessages == 0) {
            return List.of();
        }

        int pending = getStatusCount();
        if (pending <= 0) {
            return List.of();
        }

        int count = Math.min(pending, maxMessages);
        List<String> messages = new ArrayList<>(count);

        for (int i = 0; i < count; i++) {
            String msg = getStatus();
            if (msg.isEmpty()) {
                break;
            }
            messages.add(msg);
        }
        return messages;
    }

    /**
     * Convenience overload of {@link #drainStatus(int)} with a
     * default cap of 64 messages.
     *
     * @return the messages actually retrieved
     */
    public static List<String> drainStatus() {
        return drainStatus(64);
    }

    /**
     * Injects a custom log message into the status queue.
     *
     * <p>The native side queues the message even when the simulated
     * main thread is not yet running. The queue is bounded at 1000
     * entries; older entries are dropped when the buffer is full.
     *
     * @param message the message to inject; must not be null. An
     *                empty string is allowed.
     * @throws NullPointerException if {@code message} is null
     */
    public static void postStatus(String message) {
        Objects.requireNonNull(message, "message must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment seg = arena.allocateFrom(message);
            NativeCall.callVoid(NativeMethods.LF_PostStatus, seg);
        }
    }

    // ==================================================================
    // Health checks
    // ==================================================================

    /**
     * Returns whether the simulated main thread is currently running.
     *
     * @return true when the main thread is active
     */
    public static boolean checkMainThread() {
        return NativeCall.callInt(NativeMethods.LF_CheckMainThread) != 0;
    }

    /**
     * Probes whether an application with the given name is available.
     *
     * <p>The lookup uses a local cache updated by network broadcasts
     * with an approximate 3-second delay. False negatives immediately
     * after registration and false positives shortly after
     * unregistration are both normal. Do not use this as an
     * authoritative existence test for critical paths.
     *
     * @param appName the application name; must not be null
     * @return true when at least one instance exists
     * @throws NullPointerException if {@code appName} is null
     */
    public static boolean checkApp(String appName) {
        Objects.requireNonNull(appName, "appName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment seg = arena.allocateFrom(appName);
            return NativeCall.callInt(NativeMethods.LF_CheckApp, seg) != 0;
        }
    }

    /**
     * Probes whether the named API is available for the given
     * application. Same cache-based caveat as
     * {@link #checkApp(String)}.
     *
     * @param appName the application name; must not be null
     * @param apiName the API name; must not be null
     * @return true when the API is available on at least one instance
     * @throws NullPointerException if either argument is null
     */
    public static boolean checkApi(String appName, String apiName) {
        Objects.requireNonNull(appName, "appName must not be null");
        Objects.requireNonNull(apiName, "apiName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment appSeg = arena.allocateFrom(appName);
            MemorySegment apiSeg = arena.allocateFrom(apiName);
            return NativeCall.callInt(
                    NativeMethods.LF_CheckApi, appSeg, apiSeg) != 0;
        }
    }

    /**
     * Probes whether a client with the given UID is currently known to
     * the mesh (locally or via the cached remote view).
     *
     * <p>Same cache-based caveat as {@link #checkApp(String)}: fresh
     * registrations may produce a false negative for a short window,
     * and fresh unregistrations may produce a false positive.
     *
     * @param uid the 32-byte UID; must not be null and must be exactly
     *            32 bytes long
     * @return true when the UID is present in the local or cached
     *         remote view
     * @throws NullPointerException     if {@code uid} is null
     * @throws IllegalArgumentException if {@code uid.length != 32}
     */
    public static boolean checkUid(byte[] uid) {
        checkUidLength(uid, "uid");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            return NativeCall.callInt(
                    NativeMethods.LF_Check_UID, uidSeg) != 0;
        }
    }

    /**
     * Probes whether a client with the given UID exposes the named
     * API.
     *
     * <p>Same cache-based caveat as {@link #checkApp(String)}.
     *
     * @param uid     the 32-byte UID; must not be null and must be
     *                exactly 32 bytes long
     * @param apiName the API name; must not be null
     * @return true when the API is available on at least one client
     *         with the matching UID
     * @throws NullPointerException     if any argument is null
     * @throws IllegalArgumentException if {@code uid.length != 32}
     */
    public static boolean checkUidApi(byte[] uid, String apiName) {
        checkUidLength(uid, "uid");
        Objects.requireNonNull(apiName, "apiName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment uidSeg = allocateUid(arena, uid);
            MemorySegment apiSeg = arena.allocateFrom(apiName);
            return NativeCall.callInt(
                    NativeMethods.LF_Check_UID_Api,
                    uidSeg,
                    apiSeg) != 0;
        }
    }

    /**
     * Probes whether at least one client has the given P2P group name.
     *
     * <p>Same cache-based caveat as {@link #checkApp(String)}.
     *
     * @param p2pName the P2P group name; must not be null
     * @return true when the group is present in the local or cached
     *         remote view
     * @throws NullPointerException if {@code p2pName} is null
     */
    public static boolean checkP2pName(String p2pName) {
        Objects.requireNonNull(p2pName, "p2pName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment seg = arena.allocateFrom(p2pName);
            return NativeCall.callInt(
                    NativeMethods.LF_Check_P2PNAME, seg) != 0;
        }
    }

    /**
     * Probes whether at least one client in the given P2P group
     * exposes the named API.
     *
     * <p>Same cache-based caveat as {@link #checkApp(String)}.
     *
     * @param p2pName the P2P group name; must not be null
     * @param apiName the API name; must not be null
     * @return true when the API is available on at least one client in
     *         the group
     * @throws NullPointerException if either argument is null
     */
    public static boolean checkP2pNameApi(String p2pName, String apiName) {
        Objects.requireNonNull(p2pName, "p2pName must not be null");
        Objects.requireNonNull(apiName, "apiName must not be null");

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment groupSeg = arena.allocateFrom(p2pName);
            MemorySegment apiSeg = arena.allocateFrom(apiName);
            return NativeCall.callInt(
                    NativeMethods.LF_Check_P2PNAME_Api,
                    groupSeg,
                    apiSeg) != 0;
        }
    }

    // ==================================================================
    // Internal helpers
    // ==================================================================

    /**
     * Validates that a UID argument has exactly the expected length.
     *
     * @param uid     the UID argument
     * @param argName the parameter name to use in the error message
     * @throws NullPointerException     if {@code uid} is null
     * @throws IllegalArgumentException if {@code uid.length} does not
     *                                  match {@link NativeTypes#UID_BYTES}
     */
    private static void checkUidLength(byte[] uid, String argName) {
        Objects.requireNonNull(uid, argName + " must not be null");
        if (uid.length != NativeTypes.UID_BYTES) {
            throw new IllegalArgumentException(
                    argName + " must be exactly " + NativeTypes.UID_BYTES
                            + " bytes, got " + uid.length);
        }
    }

    /**
     * Allocates a 32-byte segment in the given arena and copies the
     * UID into it.
     *
     * @param arena the arena to allocate from
     * @param uid   the 32-byte UID; must have been validated already
     * @return a segment that holds the 32 UID bytes
     */
    private static MemorySegment allocateUid(Arena arena, byte[] uid) {
        MemorySegment seg = arena.allocate(NativeTypes.UID_BYTES);
        MemorySegment.copy(uid, 0, seg, ValueLayout.JAVA_BYTE, 0,
                (int) NativeTypes.UID_BYTES);
        return seg;
    }
}