package lingofuse.address;

import lingofuse.DataHandle;
import lingofuse.LfIo;
import lingofuse.async.AsyncOp;
import lingofuse.async.AsyncResultHandler;
import lingofuse.async.AsyncSupport;
import lingofuse.async.CallFuture;
import lingofuse.async.TypedAsyncResultHandler;
import lingofuse.errors.LingoFuseTimeoutException;

import java.lang.foreign.MemorySegment;
import java.util.Objects;

/**
 * Abstract base for the three addressing modes.
 *
 * <p>A {@code Target} represents a logical routing key. Concrete
 * subclasses implement the five {@code raw*} hooks (one per underlying
 * C ABI family). The public API - both the synchronous style and the
 * modern asynchronous style - is defined once here and shared by all
 * three addressing modes.
 *
 * <h2>Three addressing modes</h2>
 *
 * <ul>
 *   <li>{@link AppTarget} - routes to a logical App by name.
 *       LOCAL-FIRST: if the caller process itself hosts an App with
 *       the matching name and API, the call is serviced locally
 *       without touching the network.</li>
 *   <li>{@link UIDTarget} - routes to a specific session by its
 *       32-byte UID. LOCAL-FIRST, matching App-name routing. The UID
 *       can address ANY API registered on the target, without
 *       requiring the caller to know the target App name.</li>
 *   <li>{@link P2PNameTarget} - routes to any client in a user-defined
 *       group. NOT local-first: the server-side dispatcher owns the
 *       load-balancing state and picks the actual target.</li>
 * </ul>
 *
 * <h2>API styles</h2>
 *
 * <p>Both styles are fully supported and can be freely mixed:
 *
 * <h3>Synchronous</h3>
 *
 * <pre>{@code
 * try (DataHandle req = new DataHandle("add")) {
 *     req.writeInt32(5);
 *     req.writeInt32(7);
 *     try (DataHandle resp = target.call(req, 3000)) {
 *         System.out.println("5 + 7 = " + resp.readInt32());
 *     }
 * }
 * }</pre>
 *
 * <h3>Asynchronous, callback-based ("direct business code")</h3>
 *
 * <pre>{@code
 * try (DataHandle req = new DataHandle("add")) {
 *     req.writeInt32(5);
 *     req.writeInt32(7);
 *     target.asyncCallJson(req, Integer.class, (sum, error) -> {
 *         if (error != null) {
 *             log.warn("add failed", error);
 *             return;
 *         }
 *         System.out.println("5 + 7 = " + sum);
 *     });
 * }
 * }</pre>
 *
 * <h3>Asynchronous, Future-based (chaining)</h3>
 *
 * <pre>{@code
 * CallFuture<Integer> future = target.callFuture(req, Integer.class);
 * future.thenAccept(sum -> System.out.println("5 + 7 = " + sum));
 * }</pre>
 *
 * <h2>Subclass hook contract</h2>
 *
 * <p>Every {@code raw*} hook receives the request {@link DataHandle}
 * and is responsible for forwarding it to a native function. The hook
 * MUST access the native pointer through
 * {@link DataHandle#withHandle(java.util.function.Function)} rather
 * than reading {@link DataHandle#raw()} directly:
 *
 * <pre>{@code
 * // Correct: the handle cannot be closed during the native call.
 * MemorySegment raw = param.withHandle(h -> NativeCall.callSeg(
 *         NativeMethods.LF_UID_Call, uidSeg, h, timeoutMs));
 *
 * // Incorrect: a concurrent param.close() frees the handle between
 * // param.raw() and the native call.
 * MemorySegment raw = NativeCall.callSeg(
 *         NativeMethods.LF_UID_Call, uidSeg, param.raw(), timeoutMs);
 * }</pre>
 *
 * <p>{@code withHandle} holds the handle's internal write lock for
 * the entire duration of the native call. This closes the
 * use-after-free window that would otherwise exist between reading
 * the raw pointer and passing it to the native function, and it is
 * the reason {@code raw()} is documented as a diagnostic-only
 * accessor.
 *
 * <h2>Callback lifetime</h2>
 *
 * <p>Callbacks registered through the async callback methods
 * ({@code asyncCall} / {@code asyncCallJson} / ...) run on native
 * worker threads. They must not block, and they must not call any
 * blocking LingoFuse function. Every exception they raise is caught
 * and reported through {@code Framework.reportCallbackError}; nothing
 * escapes into the C stack.
 *
 * <p>The typed variants ({@code *Json}) handle the result handle's
 * lifetime internally: the framework deserializes the payload before
 * invoking the handler, so the handler never sees a
 * {@link DataHandle}.
 *
 * <h2>Thread safety</h2>
 *
 * <p>Target instances are immutable after construction and safe to
 * share across threads. They do not cache any per-call state.
 */
public abstract class Target {

    /**
     * The default timeout used by overloads that do not take an
     * explicit {@code timeoutMs} argument.
     */
    protected final long defaultTimeoutMs;

    /**
     * Creates a new Target.
     *
     * @param defaultTimeoutMs the default timeout in milliseconds;
     *                         must be non-negative
     * @throws IllegalArgumentException if {@code defaultTimeoutMs} is
     *                                  negative
     */
    protected Target(long defaultTimeoutMs) {
        if (defaultTimeoutMs < 0) {
            throw new IllegalArgumentException(
                    "defaultTimeoutMs must be non-negative: "
                            + defaultTimeoutMs);
        }
        this.defaultTimeoutMs = defaultTimeoutMs;
    }

    // ==================================================================
    // Subclass hooks
    // ==================================================================
    //
    // Each hook wraps exactly one C ABI family. Subclasses implement
    // them by delegating to Framework (for the sync primitives) or to
    // NativeCall + NativeMethods (for the async primitives, which
    // need direct access to the op's upcall stub).
    //
    // The API name is NOT passed to the hooks: it is already carried
    // by the DataHandle. The hooks only need the addressing key
    // (which the subclass knows) and the payload.
    //
    // EVERY hook MUST access the request handle through
    // param.withHandle(...), never through param.raw(). See the
    // "Subclass hook contract" section in the class header.

    /**
     * Issues a synchronous call for this addressing mode.
     *
     * @param param     the request handle
     * @param timeoutMs the timeout in milliseconds
     * @return the response handle; caller owns it
     */
    protected abstract DataHandle rawCall(DataHandle param, long timeoutMs);

    /**
     * Issues an asynchronous call for this addressing mode.
     *
     * @param param the request handle
     * @param stub  the upcall stub created by the async subsystem
     * @return 1 on successful dispatch, 0 on failure
     */
    protected abstract int rawAsyncCall(DataHandle param, MemorySegment stub);

    /**
     * Issues an asynchronous sequenced call for this addressing mode.
     *
     * @param param the request handle
     * @param stub  the upcall stub created by the async subsystem
     * @return 1 on successful dispatch, 0 on failure
     */
    protected abstract int rawAsyncSequencedCall(DataHandle param, MemorySegment stub);

    /**
     * Issues a one-way notification for this addressing mode.
     *
     * @param param the payload
     */
    protected abstract void rawNotify(DataHandle param);

    /**
     * Issues a one-way sequenced notification for this addressing
     * mode.
     *
     * @param param the payload
     */
    protected abstract void rawSequencedNotify(DataHandle param);

    /**
     * Returns a short human-readable description of this target,
     * used in exception messages and log lines.
     *
     * @return a description such as {@code "app(MyApp)"}
     */
    public abstract String describe();

    // ==================================================================
    // Synchronous API
    // ==================================================================

    /**
     * Sends a blocking request and returns the raw response handle.
     *
     * <p>The returned handle is owned by the caller and must be closed
     * (for example via try-with-resources).
     *
     * <p>On timeout or unreachable target, a
     * {@link LingoFuseTimeoutException} is thrown. This is different
     * from {@code Framework.call}, which returns a size-0 handle on
     * timeout. The Target layer standardises the failure mode across
     * the three addressing modes.
     *
     * @param param     the request handle; must not be null
     * @param timeoutMs the timeout in milliseconds; 0 means "wait
     *                  indefinitely"
     * @return the response handle; caller owns it
     * @throws NullPointerException     if {@code param} is null
     * @throws LingoFuseTimeoutException if the response is empty
     *                                  (timeout or unreachable target)
     */
    public DataHandle call(DataHandle param, long timeoutMs) {
        Objects.requireNonNull(param, "param must not be null");
        DataHandle response = rawCall(param, timeoutMs);
        if (response.size() == 0) {
            response.close();
            throw new LingoFuseTimeoutException(
                    "call on " + describe() + " timed out after "
                            + timeoutMs + "ms",
                    timeoutMs);
        }
        return response;
    }

    /**
     * Synchronous call with the target's default timeout.
     *
     * @param param the request handle
     * @return the response handle
     */
    public DataHandle call(DataHandle param) {
        return call(param, defaultTimeoutMs);
    }

    /**
     * Sends a blocking request and returns the deserialized JSON
     * result.
     *
     * <p>Equivalent to {@code call(param, timeoutMs)} followed by
     * {@link LfIo#readJson(DataHandle, Class)}.
     *
     * @param param     the request handle; must not be null
     * @param type      the target type; must not be null
     * @param timeoutMs the timeout in milliseconds
     * @param <T>       the target type parameter
     * @return the deserialized result
     * @throws NullPointerException      if any argument is null
     * @throws LingoFuseTimeoutException if the response is empty
     */
    public <T> T callJson(DataHandle param, Class<T> type, long timeoutMs) {
        Objects.requireNonNull(type, "type must not be null");
        try (DataHandle response = call(param, timeoutMs)) {
            return LfIo.readJson(response, type);
        }
    }

    /**
     * Synchronous JSON call with the target's default timeout.
     *
     * @param param the request handle
     * @param type  the target type
     * @param <T>   the target type parameter
     * @return the deserialized result
     */
    public <T> T callJson(DataHandle param, Class<T> type) {
        return callJson(param, type, defaultTimeoutMs);
    }

    /**
     * Sends a one-way notification. Returns immediately.
     *
     * <p>Delivery order is not guaranteed. Use
     * {@link #sequencedNotify(DataHandle)} when FIFO ordering per
     * {@code (target, api)} pair is required.
     *
     * @param param the payload; must not be null
     */
    public void notify(DataHandle param) {
        Objects.requireNonNull(param, "param must not be null");
        rawNotify(param);
    }

    /**
     * Sends a one-way sequenced notification. Returns immediately.
     *
     * @param param the payload; must not be null
     */
    public void sequencedNotify(DataHandle param) {
        Objects.requireNonNull(param, "param must not be null");
        rawSequencedNotify(param);
    }

    // ==================================================================
    // Asynchronous API - callback style
    // ==================================================================

    /**
     * Sends a non-blocking request with a raw-handle callback.
     *
     * <p>The callback receives the borrowed result handle. It must
     * copy any data it wants to keep before returning; see
     * {@link AsyncResultHandler} for the full lifetime contract.
     *
     * @param param   the request handle; must not be null
     * @param handler the user callback; must not be null
     * @return true if the request was queued successfully
     * @throws NullPointerException if any argument is null
     */
    public boolean asyncCall(DataHandle param, AsyncResultHandler handler) {
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncCall[" + describe() + "]",
                handler,
                h -> h);

        int ret = rawAsyncCall(param, op.stub());
        if (ret != 1) {
            op.markNotQueued();
            return false;
        }
        return true;
    }

    /**
     * Sends a non-blocking sequenced request with a raw-handle
     * callback. FIFO ordering is guaranteed per
     * {@code (target, api)} pair.
     *
     * @param param   the request handle; must not be null
     * @param handler the user callback; must not be null
     * @return true if the request was queued successfully
     */
    public boolean asyncSequencedCall(
            DataHandle param, AsyncResultHandler handler) {
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeLegacyOp(
                "asyncSequencedCall[" + describe() + "]",
                handler,
                h -> h);

        int ret = rawAsyncSequencedCall(param, op.stub());
        if (ret != 1) {
            op.markNotQueued();
            return false;
        }
        return true;
    }

    /**
     * Sends a non-blocking request with a typed callback.
     *
     * <p>The framework deserializes the result before invoking the
     * handler, so the handler never sees a {@link DataHandle}. This
     * is the "direct business code" style:
     *
     * <pre>{@code
     * try (DataHandle req = new DataHandle("add")) {
     *     req.writeInt32(5);
     *     req.writeInt32(7);
     *     target.asyncCallJson(req, Integer.class, (sum, error) -> {
     *         if (error != null) {
     *             log.warn("add failed", error);
     *             return;
     *         }
     *         System.out.println("5 + 7 = " + sum);
     *     });
     * }
     * }</pre>
     *
     * @param param   the request handle; must not be null
     * @param type    the target type; must not be null
     * @param handler the user callback; must not be null
     * @param <T>     the deserialized value type
     * @return true if the request was queued successfully
     */
    public <T> boolean asyncCallJson(
            DataHandle param,
            Class<T> type,
            TypedAsyncResultHandler<T> handler) {
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "asyncCallJson[" + describe() + "]",
                handler,
                AsyncSupport.jsonDeserializer(type));

        int ret = rawAsyncCall(param, op.stub());
        if (ret != 1) {
            op.markNotQueued();
            return false;
        }
        return true;
    }

    /**
     * Sends a non-blocking sequenced request with a typed callback.
     *
     * <p>Same as {@link #asyncCallJson(DataHandle, Class,
     * TypedAsyncResultHandler)} but FIFO-ordered per
     * {@code (target, api)} pair.
     *
     * @param param   the request handle; must not be null
     * @param type    the target type; must not be null
     * @param handler the user callback; must not be null
     * @param <T>     the deserialized value type
     * @return true if the request was queued successfully
     */
    public <T> boolean asyncSequencedCallJson(
            DataHandle param,
            Class<T> type,
            TypedAsyncResultHandler<T> handler) {
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");
        Objects.requireNonNull(handler, "handler must not be null");

        AsyncOp op = AsyncSupport.makeTypedLegacyOp(
                "asyncSequencedCallJson[" + describe() + "]",
                handler,
                AsyncSupport.jsonDeserializer(type));

        int ret = rawAsyncSequencedCall(param, op.stub());
        if (ret != 1) {
            op.markNotQueued();
            return false;
        }
        return true;
    }

    // ==================================================================
    // Asynchronous API - Future style
    // ==================================================================

    /**
     * Sends a non-blocking request and returns a
     * {@link CallFuture} that resolves with the deserialized result.
     *
     * <p>The returned Future can be chained, blocked on, or awaited
     * via {@code CompletableFuture} APIs. Its {@code abandoned()}
     * flag reports whether the timeout fired before the response
     * arrived.
     *
     * @param param     the request handle; must not be null
     * @param type      the target type; must not be null
     * @param timeoutMs the Python-side timeout in milliseconds
     * @param <T>       the deserialized value type
     * @return a Future that resolves with the result
     */
    public <T> CallFuture<T> callFuture(
            DataHandle param, Class<T> type, long timeoutMs) {
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");

        return AsyncSupport.runAsyncWithFuture(
                "callFuture[" + describe() + "]",
                stub -> rawAsyncCall(param, stub),
                AsyncSupport.jsonDeserializer(type),
                timeoutMs);
    }

    /**
     * Future-based call with the target's default timeout.
     *
     * @param param the request handle
     * @param type  the target type
     * @param <T>   the deserialized value type
     * @return a Future that resolves with the result
     */
    public <T> CallFuture<T> callFuture(DataHandle param, Class<T> type) {
        return callFuture(param, type, defaultTimeoutMs);
    }

    /**
     * Sends a non-blocking sequenced request and returns a
     * {@link CallFuture}.
     *
     * @param param     the request handle
     * @param type      the target type
     * @param timeoutMs the Python-side timeout in milliseconds
     * @param <T>       the deserialized value type
     * @return a Future that resolves with the result
     */
    public <T> CallFuture<T> sequencedCallFuture(
            DataHandle param, Class<T> type, long timeoutMs) {
        Objects.requireNonNull(param, "param must not be null");
        Objects.requireNonNull(type, "type must not be null");

        return AsyncSupport.runAsyncWithFuture(
                "sequencedCallFuture[" + describe() + "]",
                stub -> rawAsyncSequencedCall(param, stub),
                AsyncSupport.jsonDeserializer(type),
                timeoutMs);
    }

    /**
     * Sequenced Future-based call with the target's default timeout.
     *
     * @param param the request handle
     * @param type  the target type
     * @param <T>   the deserialized value type
     * @return a Future that resolves with the result
     */
    public <T> CallFuture<T> sequencedCallFuture(
            DataHandle param, Class<T> type) {
        return sequencedCallFuture(param, type, defaultTimeoutMs);
    }
}