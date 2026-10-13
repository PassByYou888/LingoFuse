package lingofuse.async;

import lingofuse.DataHandle;

import java.lang.foreign.MemorySegment;
import java.util.concurrent.CompletableFuture;
import java.util.function.Function;

/**
 * A single outstanding asynchronous operation.
 *
 * <p>Owns the upcall stub that the native library will invoke when the
 * response arrives, the deserializer that turns the raw result handle
 * into a Java value, and (optionally) the {@link CallFuture} that
 * receives the result.
 *
 * <h2>State machine</h2>
 *
 * <pre>
 *                    +-------------+
 *                    |   PENDING   |
 *                    +------+------+
 *                           |
 *         callback  +-------+-------+  dispatch failure
 *                   |               |
 *                   v               v
 *             +----------+   +--------------+
 *             |  FIRED   |   |  NOT_QUEUED  |
 *             +----------+   +--------------+
 *                   ^
 *                   |  timeout fires first
 *                   |
 *             +-----------+
 *             | ABANDONED |  --(late callback)--&gt; FIRED
 *             +-----------+
 * </pre>
 *
 * <p>FIRED means the C callback has completed its Java-side work
 * (whether it delivered a result or was dropped because the op had
 * already been abandoned). Once FIRED, the op is scheduled for
 * immediate release.
 *
 * <p>ABANDONED means the timeout fired while the op was still PENDING.
 * The op is held alive for a grace period before release, giving any
 * late callback a chance to arrive on a still-valid Java object.
 *
 * <p>NOT_QUEUED means the C dispatch failed before the callback was
 * installed. The op is released immediately.
 *
 * <h2>Threading</h2>
 *
 * <p>All state transitions are guarded by a single {@link Object}
 * monitor. The state field is also volatile so that {@link #state()}
 * can be read cheaply from any thread.
 *
 * <p>The delivery function is invoked exactly once, on the native
 * worker thread, outside the monitor so that a slow user callback
 * cannot block other state transitions.
 */
public final class AsyncOp {

    // ------------------------------------------------------------------
    // State constants
    // ------------------------------------------------------------------

    /** Awaiting the C callback. */
    public static final String STATE_PENDING    = "pending";

    /** Callback fired and delivery completed. */
    public static final String STATE_FIRED      = "fired";

    /** Timeout fired before the callback arrived. */
    public static final String STATE_ABANDONED  = "abandoned";

    /** Dispatch failed before the callback was installed. */
    public static final String STATE_NOT_QUEUED = "not_queued";

    // ------------------------------------------------------------------
    // Fields
    // ------------------------------------------------------------------

    private final String apiName;
    private final Function<DataHandle, Object> deserializer;
    private final DeliverFn deliver;
    private final CompletableFuture<?> future;
    private final MemorySegment stub;

    private final Object lock = new Object();
    private volatile String state = STATE_PENDING;

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    /**
     * Creates a new op.
     *
     * <p>Package-private: user code never instantiates an AsyncOp
     * directly. Use the factory methods in {@link AsyncSupport}.
     *
     * @param apiName      the remote API name; used for diagnostics
     * @param deserializer the deserializer applied to the raw result
     *                     handle; must not be null
     * @param deliver      the function that receives the deserialized
     *                     value (or an error); must not be null
     * @param future       the Future to resolve, or null for
     *                     legacy-style ops
     * @param stub         the upcall stub that the native library will
     *                     invoke; must not be null
     */
    AsyncOp(String apiName,
            Function<DataHandle, Object> deserializer,
            DeliverFn deliver,
            CompletableFuture<?> future,
            MemorySegment stub) {
        this.apiName = apiName;
        this.deserializer = deserializer;
        this.deliver = deliver;
        this.future = future;
        this.stub = stub;
    }

    // ------------------------------------------------------------------
    // Accessors
    // ------------------------------------------------------------------

    /** Returns the remote API name; used for diagnostics. */
    public String apiName() {
        return apiName;
    }

    /** Returns the upcall stub. */
    public MemorySegment stub() {
        return stub;
    }

    /** Returns the associated Future, or null for legacy-style ops. */
    public CompletableFuture<?> future() {
        return future;
    }

    /** Returns the current state; thread-safe. */
    public String state() {
        return state;
    }

    // ------------------------------------------------------------------
    // State transitions
    // ------------------------------------------------------------------

    /**
     * Transitions to NOT_QUEUED and schedules immediate release.
     *
     * <p>Called by the caller thread when the C dispatch returned a
     * value other than 1; the callback will never fire. Safe to call
     * multiple times.
     *
     * <p>This method is public because it is called from the
     * {@code lingofuse} and {@code lingofuse.address} packages, which
     * live outside {@code lingofuse.async}. It is not intended to be
     * called by application code.
     */
    public void markNotQueued() {
        synchronized (lock) {
            if (!STATE_PENDING.equals(state)) {
                return;
            }
            state = STATE_NOT_QUEUED;
        }
        AsyncBridge.instance().scheduleReleaseNow(this);
    }

    /**
     * Transitions to ABANDONED. Returns true if the transition
     * actually happened (i.e. the op was PENDING), false otherwise.
     *
     * <p>Called by the reclamation thread.
     */
    boolean abandon() {
        synchronized (lock) {
            if (!STATE_PENDING.equals(state)) {
                return false;
            }
            state = STATE_ABANDONED;
            return true;
        }
    }

    /**
     * Invoked from the native upcall stub when the C callback fires.
     *
     * <p>Runs on a native worker thread. The {@code rawResult} segment
     * is a borrowed DataHandle owned by the framework; it is valid
     * ONLY for the duration of this method. The deserializer is
     * applied inside the monitor-free region.
     *
     * @param rawResult the raw result handle; may be a null segment
     * @param error     a non-null error if the framework already knows
     *                  the operation failed
     */
    void invokeFromC(MemorySegment rawResult, Throwable error) {

        // ----------------------------------------------------------
        // Step 1: state transition.
        // ----------------------------------------------------------
        synchronized (lock) {
            String current = state;
            if (STATE_FIRED.equals(current)) {
                // Second invocation; by contract this cannot happen.
                return;
            }
            if (STATE_NOT_QUEUED.equals(current)) {
                // Dispatch already failed; ignore.
                return;
            }
            if (STATE_ABANDONED.equals(current)) {
                // Late callback after timeout. Drop the result, but
                // release immediately instead of waiting for the
                // grace period to expire.
                state = STATE_FIRED;
                AsyncBridge.instance().scheduleReleaseNow(this);
                return;
            }
            // current == STATE_PENDING: normal path.
            state = STATE_FIRED;
        }

        // ----------------------------------------------------------
        // Step 2: deserialize + deliver.
        //
        // This runs OUTSIDE the monitor so that a slow user callback
        // cannot block other state transitions.
        // ----------------------------------------------------------
        Object value = null;
        Throwable actualError = error;

        if (actualError == null
                && rawResult != null
                && rawResult.address() != 0L) {
            try {
                DataHandle borrowed = DataHandle.fromRaw(rawResult, false);
                value = deserializer.apply(borrowed);
            } catch (Throwable t) {
                actualError = t;
            }
        }

        try {
            deliver.accept(value, actualError);
        } catch (Throwable t) {
            // The delivery function itself raised. Report through the
            // framework's callback-error channel and continue.
            lingofuse.Framework.reportCallbackError(
                    "AsyncOp[" + apiName + "]", t);
        } finally {
            AsyncBridge.instance().scheduleReleaseNow(this);
        }
    }

    // ------------------------------------------------------------------
    // Delivery function
    // ------------------------------------------------------------------

    /**
     * The function that receives the deserialized result (or an
     * error). Created by the factory methods in {@link AsyncSupport}.
     */
    @FunctionalInterface
    interface DeliverFn {
        void accept(Object value, Throwable error);
    }
}