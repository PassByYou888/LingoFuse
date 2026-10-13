package lingofuse.async;

import lingofuse.DataHandle;

/**
 * Callback for a legacy-style asynchronous call.
 *
 * <p>Invoked exactly once on a native worker thread, when the response
 * arrives or the framework reports a failure.
 *
 * <h2>Lifetime of the result handle</h2>
 *
 * <p>The {@code result} argument is a BORROWED handle
 * ({@code owned = false}). It is valid ONLY for the duration of this
 * method call. The framework releases the underlying native handle as
 * soon as this method returns.
 *
 * <p>Concretely, the following rules apply inside the callback body:
 *
 * <ul>
 *   <li>READ from the handle as much as you need.</li>
 *   <li>COPY out any data you want to keep (for example via
 *       {@link lingofuse.LfIo#readJson(DataHandle)}) before
 *       returning.</li>
 *   <li>Do NOT retain the handle itself beyond this method.</li>
 *   <li>Do NOT call {@link DataHandle#close()} on it. Calling
 *       {@code close()} on a borrowed handle is a no-op (it is safe
 *       but pointless); the important rule is that the handle will be
 *       invalid the moment this method returns.</li>
 *   <li>Do NOT call any blocking LingoFuse function
 *       ({@code LF_Call}, {@code LF_LocalCall}, ...). Doing so will
 *       deadlock.</li>
 * </ul>
 *
 * <h2>Error argument</h2>
 *
 * <p>{@code error} is {@code null} on success. On failure it is a
 * {@link Throwable} describing what went wrong: a transport-level
 * failure, a deserialization failure, or a native exception.
 *
 * <p>The callback is invoked exactly once. If the Python-side timeout
 * fires before the C-side callback arrives, the AsyncBridge suppresses
 * the late delivery and this handler is never invoked at all.
 *
 * <h2>Threading</h2>
 *
 * <p>Every callback runs on a native worker thread. It must not block
 * and must not touch thread-affine resources (UI, thread-locals).
 * Use {@code CompletableFuture} / {@code ExecutorService} to hand off
 * heavy work to another thread.
 */
@FunctionalInterface
public interface AsyncResultHandler {

    /**
     * Called when the response arrives or the operation fails.
     *
     * @param result the borrowed result handle; valid only for the
     *               duration of this call. May be {@code null} on
     *               failure.
     * @param error  {@code null} on success; a {@link Throwable}
     *               otherwise
     */
    void onResult(DataHandle result, Throwable error);
}