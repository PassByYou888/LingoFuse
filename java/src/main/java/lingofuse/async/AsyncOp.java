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
     * Releases the arena that owns the upcall stub, unless the op is
     * ABANDONED (in which case the C-side request may still be in
     * flight, and the arena must remain valid).
     */
    void releaseResources() {
        String current = state;
        if (STATE_ABANDONED.equals(current)) {
            // The C-side request may still be in flight. Leave the
            // stub arena open; the OS reclaims it at process exit.
            return;
        }
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