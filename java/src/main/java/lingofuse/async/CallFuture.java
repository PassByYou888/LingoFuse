package lingofuse.async;

import java.util.concurrent.CompletableFuture;

/**
 * A {@link CompletableFuture} that carries one extra diagnostic flag:
 * {@link #abandoned()}.
 *
 * <p>This class is the modern counterpart of the legacy
 * {@link AsyncResultHandler}. Both are produced by the same
 * {@link AsyncBridge} machinery; the only difference is the delivery
 * shape (callback vs. Future).
 *
 * <h2>Timeout semantics</h2>
 *
 * <p>{@link AsyncBridge} arms a Python-side timeout whenever the user
 * passes a positive {@code timeoutMs} to
 * {@link AsyncSupport#runAsyncWithFuture}. When that timeout fires
 * before the C-side callback arrives:
 *
 * <ol>
 *   <li>This Future is completed exceptionally with a
 *       {@link lingofuse.errors.LingoFuseTimeoutException}.</li>
 *   <li>{@link #abandoned()} becomes {@code true}.</li>
 *   <li>The underlying C request is NOT cancelled. It may still
 *       complete later; when it does, its result is silently
 *       discarded because the Future is already resolved.</li>
 * </ol>
 *
 * <p>Callers that need to distinguish "cancelled by the user" from
 * "timed out on our side" should inspect {@link #abandoned()} after
 * catching the exception.
 *
 * <h2>Thread safety</h2>
 *
 * <p>All methods inherited from {@link CompletableFuture} are
 * thread-safe. {@link #abandoned()} itself is volatile-read only and
 * is safe to call from any thread.
 *
 * @param <T> the deserialized result type
 */
public class CallFuture<T> extends CompletableFuture<T> {

    /**
     * True when the Python-side timeout fired before the C-side
     * callback arrived. Set by {@link AsyncBridge} on the reclamation
     * thread; read by the caller on any thread.
     */
    private volatile boolean abandoned = false;

    /**
     * Returns whether this Future was abandoned due to a
     * Python-side timeout.
     *
     * @return true when the timeout fired before the result arrived
     */
    public boolean abandoned() {
        return abandoned;
    }

    /**
     * Internal: marks this Future as abandoned. Idempotent.
     *
     * <p>Package-private so that only {@link AsyncBridge} can call it;
     * user code must never flip this flag.
     */
    void markAbandoned() {
        this.abandoned = true;
    }
}