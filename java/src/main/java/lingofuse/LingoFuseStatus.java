package lingofuse;

import lingofuse.ffi.NativeCall;
import lingofuse.ffi.NativeMethods;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
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
 *   <li>the application and API availability probes
 *       ({@link #checkApp(String)}, {@link #checkApi(String, String)}).</li>
 * </ul>
 *
 * <p>It mirrors the role of {@code LingoFuseStatus} in the C# binding.
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
 * thread is running. {@link #checkApp(String)} and
 * {@link #checkApi(String, String)} perform cache-based lookups that
 * are updated by network broadcasts with an approximate 3-second
 * delay. They are suitable for probing and diagnostics, not for
 * authoritative availability decisions. For critical paths, issue
 * the call and handle timeouts explicitly.
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
}