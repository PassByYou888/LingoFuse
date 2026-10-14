package lingofuse.async;

import lingofuse.DataHandle;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.util.concurrent.CompletableFuture;
import java.util.function.Function;

/**
 * A single outstanding asynchronous operation.
 *
 * <p>Owns the upcall stub, the arena that keeps the stub alive, the
 * deserializer, and (optionally) the {@link CallFuture}.
 *
 * <p>State machine: PENDING -&gt; FIRED | ABANDONED | NOT_QUEUED.
 * A late callback after a timeout transitions ABANDONED -&gt; FIRED
 * and drops the result.
 *
 * <p>The op holds a strong reference to the {@link AsyncBridge} that
 * created it. This ensures a late callback always notifies the
 * original bridge, even after {@code shutdownInstance()} has replaced
 * the process-wide singleton.
 *
 * <h2>Arena lifetime</h2>
 *
 * <p>The upcall stub lives in a shared {@link Arena} whose close is
 * deferred by the owning bridge. The release is triggered only after
 * the op is removed from the bridge's active-op registry, which in
 * turn happens through one of two paths:
 *
 * <ul>
 *   <li><b>FIRED / NOT_QUEUED</b>: the C side will never invoke the
 *       stub again; the arena is released immediately.</li>
 *   <li><b>ABANDONED</b>: the JS-side timeout fired. The C-side
 *       request may still be in flight. The bridge waits for the
 *       configured grace period (default 60 s) before releasing the
 *       arena, so that a straggling callback can still land on a
 *       valid trampoline and be safely discarded by
 *       {@link #invokeFromC(MemorySegment, Throwable)}.</li>
 * </ul>
 *
 * <p>If the grace period elapses and no callback has arrived, the op
 * is treated as permanently abandoned: the arena is closed, and any
 * callback that were to arrive after that point is outside the
 * contract (it will not be delivered). This bounds the memory used by
 * timed-out operations, which is important for workloads that
 * retry on timeout.
 */
public final class AsyncOp {

    public static final String STATE_PENDING    = "pending";
    public static final String STATE_FIRED      = "fired";
    public static final String STATE_ABANDONED  = "abandoned";
    public static final String STATE_NOT_QUEUED = "not_queued";

    private final String apiName;
    private final Function<DataHandle, Object> deserializer;
    private final DeliverFn deliver;
    private final CompletableFuture<?> future;
    private final MemorySegment stub;
    private final Arena stubArena;
    private final AsyncBridge ownerBridge;

    /**
     * The registry key assigned by {@link AsyncBridge#register}.
     *
     * <p>Zero means "not yet registered". The value is written once
     * by the bridge during registration and read afterwards by the
     * bridge's release path. Visibility is provided by the
     * {@link java.util.concurrent.ConcurrentHashMap} used inside the
     * bridge: the value is written before the op is inserted, and any
     * subsequent release path reads it after a successful lookup.
     */
    private long key = 0L;

    private final Object lock = new Object();
    private volatile String state = STATE_PENDING;

    AsyncOp(String apiName,
            Function<DataHandle, Object> deserializer,
            DeliverFn deliver,
            CompletableFuture<?> future,
            MemorySegment stub,
            Arena stubArena,
            AsyncBridge ownerBridge) {
        this.apiName = apiName;
        this.deserializer = deserializer;
        this.deliver = deliver;
        this.future = future;
        this.stub = stub;
        this.stubArena = stubArena;
        this.ownerBridge = ownerBridge;
    }

    public String apiName() {
        return apiName;
    }

    public MemorySegment stub() {
        return stub;
    }

    public CompletableFuture<?> future() {
        return future;
    }

    public String state() {
        return state;
    }

    public AsyncBridge ownerBridge() {
        return ownerBridge;
    }

    /**
     * Returns the registry key assigned by {@link AsyncBridge#register},
     * or 0 if the op has not been registered.
     *
     * <p>Package-private: callers outside the {@code lingofuse.async}
     * package have no reason to observe the key.
     */
    long key() {
        return key;
    }

    /**
     * Assigns the registry key. Called exactly once by
     * {@link AsyncBridge#register} before the op becomes reachable
     * through the registry.
     *
     * <p>Package-private: the key is an implementation detail of the
     * bridge's O(1) release path.
     */
    void setKey(long k) {
        this.key = k;
    }

    public void markNotQueued() {
        synchronized (lock) {
            if (!STATE_PENDING.equals(state)) {
                return;
            }
            state = STATE_NOT_QUEUED;
        }
        ownerBridge.scheduleReleaseNow(this);
    }

    boolean abandon() {
        synchronized (lock) {
            if (!STATE_PENDING.equals(state)) {
                return false;
            }
            state = STATE_ABANDONED;
            return true;
        }
    }

    void invokeFromC(MemorySegment rawResult, Throwable error) {
        synchronized (lock) {
            String current = state;
            if (STATE_FIRED.equals(current)) {
                return;
            }
            if (STATE_NOT_QUEUED.equals(current)) {
                return;
            }
            if (STATE_ABANDONED.equals(current)) {
                state = STATE_FIRED;
                ownerBridge.scheduleReleaseNow(this);
                return;
            }
            state = STATE_FIRED;
        }

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
            lingofuse.Framework.reportCallbackError(
                    "AsyncOp[" + apiName + "]", t);
        } finally {
            ownerBridge.scheduleReleaseNow(this);
        }
    }

    /**
     * Closes the arena that owns the upcall stub.
     *
     * <p>This method is called by {@link AsyncBridge} exactly once per
     * op, from the release path. The bridge guarantees that the
     * release path is only entered when it is safe to close the
     * arena:
     *
     * <ul>
     *   <li>For FIRED and NOT_QUEUED ops, the C side will never
     *       invoke the stub again.</li>
     *   <li>For ABANDONED ops, the bridge defers the call by the
     *       configured grace period; once the grace has elapsed, any
     *       callback that still has not arrived is outside the
     *       contract.</li>
     * </ul>
     *
     * <p>A previous design short-circuited on the ABANDONED state,
     * leaving the arena open forever to avoid a hypothetical late
     * callback. That produced an unbounded leak for any workload
     * that retries on timeout. The deferred-release path above
     * bounds it instead: the arena stays alive only for the duration
     * of the grace period.
     *
     * <p>If the arena is already closed (for example because
     * {@link AsyncBridge#shutdown()} already ran), the close is a
     * no-op.
     */
    void releaseResources() {
        if (stubArena == null) {
            return;
        }
        try {
            stubArena.close();
        } catch (Throwable ignored) {
            // Already closed.
        }
    }

    @FunctionalInterface
    interface DeliverFn {
        void accept(Object value, Throwable error);
    }
}