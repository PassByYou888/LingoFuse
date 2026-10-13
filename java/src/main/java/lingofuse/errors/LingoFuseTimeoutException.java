package lingofuse.errors;

/**
 * Raised when a synchronous remote call times out.
 *
 * <p>This is a specialised subclass of {@link LingoFuseException}, so
 * existing {@code catch (LingoFuseException)} handlers continue to
 * work unchanged. The separate type exists so that callers who want
 * to distinguish "no response in time" from other failures (a null
 * handle, a transport error, a deserialization failure) can do so
 * with a precise {@code catch (LingoFuseTimeoutException)}.
 *
 * <h2>Timeout versus empty response</h2>
 *
 * <p>The native synchronous primitives ({@code LF_Call} /
 * {@code LF_UID_Call} / {@code LF_P2PNAME_Call}) signal a timeout by
 * returning an empty handle (size 0), which is indistinguishable from
 * a peer that legitimately replied with an empty payload. The
 * higher-level {@code Target.call} method wraps this into a
 * {@code LingoFuseTimeoutException} whenever the returned handle has
 * size 0. Callers that need to distinguish the two cases must use
 * {@code Target.callFuture} with a timeout, which resolves with this
 * exception on timeout and with an empty result on a legitimate empty
 * reply.
 *
 * <h2>Late C-side completion</h2>
 *
 * <p>When this exception is thrown by an asynchronous path, the
 * underlying C-side request is NOT cancelled. It may still complete,
 * and its result will be silently discarded by the framework. The
 * {@code CallFuture.abandoned()} flag reports this state.
 */
public class LingoFuseTimeoutException extends LingoFuseException {

    /**
     * The timeout that was exceeded, in milliseconds. Zero means the
     * timeout value was not recorded (for example, when the exception
     * was raised from an asynchronous path that did not preserve it).
     */
    private final long timeoutMs;

    /**
     * Creates a new timeout exception without a recorded timeout
     * value.
     *
     * @param message a human-readable description of the failure
     */
    public LingoFuseTimeoutException(String message) {
        super(message);
        this.timeoutMs = 0L;
    }

    /**
     * Creates a new timeout exception with the timeout value that was
     * exceeded.
     *
     * @param message   a human-readable description of the failure
     * @param timeoutMs the timeout in milliseconds
     */
    public LingoFuseTimeoutException(String message, long timeoutMs) {
        super(message);
        this.timeoutMs = timeoutMs;
    }

    /**
     * Returns the timeout that was exceeded, in milliseconds, or 0
     * when the value was not recorded.
     *
     * @return the timeout value in milliseconds
     */
    public long getTimeoutMs() {
        return timeoutMs;
    }
}