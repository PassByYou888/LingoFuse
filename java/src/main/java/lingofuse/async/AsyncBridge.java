package lingofuse.async;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Process-wide manager for every outstanding {@link AsyncOp}.
 *
 * <p>The bridge owns the only strong reference to each op's upcall
 * stub for as long as the C library might invoke it, and releases
 * that reference once the op's state machine permits. It also owns a
 * single-threaded scheduler that handles timeouts and delayed
 * releases.
 *
 * <h2>Why a bridge</h2>
 *
 * <p>A naive "create a stub, hand it to the C library, drop the
 * reference when the request returns" approach has three well-known
 * failure modes:
 *
 * <ol>
 *   <li><b>Premature release on timeout.</b> A timed-out request is
 *       NOT cancelled by the C library; it will still invoke the
 *       callback when the response eventually arrives. Dropping the
 *       stub on timeout leaves the C side holding a dangling pointer,
 *       which crashes the process on the next invocation.</li>
 *   <li><b>Leak on dispatch failure.</b> If the C library rejects
 *       the request before dispatching it (returns 0), the callback
 *       will never fire. A naive "wait for the callback to release"
 *       policy leaks the stub forever.</li>
 *   <li><b>Double-release races.</b> The caller thread (on timeout)
 *       and the C worker thread (on callback) can race to release
 *       the same op. Without a state machine, this leads to a
 *       use-after-free.</li>
 * </ol>
 *
 * <p>The bridge addresses all three by keeping every op alive until
 * one of the following holds:
 *
 * <ul>
 *   <li>the callback has fired (state FIRED), or</li>
 *   <li>a configurable grace period has elapsed since the timeout
 *       fired (state ABANDONED), giving any late callback a chance to
 *       arrive on a still-valid Java object, or</li>
 *   <li>the dispatch failed and the callback will never fire (state
 *       NOT_QUEUED).</li>
 * </ul>
 *
 * <h2>Singleton lifecycle</h2>
 *
 * <p>Use {@link #instance()} to obtain the process-wide singleton.
 * {@link #shutdownInstance()} releases it; the next call to
 * {@code instance()} creates a fresh bridge with an empty registry.
 *
 * <p>Tests should call {@code shutdownInstance()} in {@code tearDown}
 * so that no op from one test can leak into the next.
 *
 * <h2>Configuration</h2>
 *
 * <p>The grace period and the reclamation thread are exposed as
 * instance fields so that tests can shrink them without touching the
 * global configuration. Default values:
 *
 * <ul>
 *   <li>{@code graceSeconds = 60.0}: keep an abandoned op alive for
 *       60 seconds after its timeout fires. Chosen to comfortably
 *       exceed any plausible C-side request latency.</li>
 *   <li>The scheduler uses a single daemon thread named
 *       {@code LingoFuseAsyncBridge}.</li>
 * </ul>
 *
 * <h2>Diagnostics</h2>
 *
 * <p>{@link #stats()} returns a snapshot of the current counts. Use
 * it for tests and production dashboards.
 */
public final class AsyncBridge {

    // ------------------------------------------------------------------
    // Singleton
    // ------------------------------------------------------------------

    private static volatile AsyncBridge INSTANCE;

    /**
     * Returns the process-wide singleton, creating it on first use.
     *
     * <p>Double-checked locking with a volatile field; safe and fast
     * on every modern JVM.
     *
     * @return the process-wide bridge
     */
    public static AsyncBridge instance() {
        AsyncBridge local = INSTANCE;
        if (local == null) {
            synchronized (AsyncBridge.class) {
                local = INSTANCE;
                if (local == null) {
                    local = new AsyncBridge();
                    INSTANCE = local;
                }
            }
        }
        return local;
    }

    /**
     * Releases the singleton. Safe to call multiple times.
     *
     * <p>Intended for tests and process teardown. After this call,
     * the next {@link #instance()} invocation creates a fresh bridge
     * with an empty registry.
     */
    public static void shutdownInstance() {
        AsyncBridge local;
        synchronized (AsyncBridge.class) {
            local = INSTANCE;
            INSTANCE = null;
        }
        if (local != null) {
            local.shutdown();
        }
    }

    // ------------------------------------------------------------------
    // Fields
    // ------------------------------------------------------------------

    /** All live ops, keyed by an internal id. */
    private final Map<Long, AsyncOp> ops = new ConcurrentHashMap<>();

    /** Id generator. */
    private final AtomicLong nextId = new AtomicLong(0);

    /** Cumulative count of released ops. */
    private final AtomicLong releaseCount = new AtomicLong(0);

    /** The scheduler thread. */
    private final ScheduledExecutorService scheduler;

    /** Guards the shutdown flag and the scheduler lifecycle. */
    private final Object lock = new Object();

    /** True after {@link #shutdown()} has been called. */
    private volatile boolean shutdown = false;

    // ------------------------------------------------------------------
    // Configuration (public so tests can override)
    // ------------------------------------------------------------------

    /**
     * Seconds to keep an abandoned op alive after its timeout fires,
     * giving any in-flight C callback a chance to arrive on a
     * still-valid Java object.
     *
     * <p>Default 60.0. Must be {@code >= 0}.
     */
    public volatile double graceSeconds = 60.0;

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    private AsyncBridge() {
        ThreadFactory tf = r -> {
            Thread t = new Thread(r, "LingoFuseAsyncBridge");
            t.setDaemon(true);
            return t;
        };
        this.scheduler = Executors.newSingleThreadScheduledExecutor(tf);
    }

    // ------------------------------------------------------------------
    // Registration and scheduling
    // ------------------------------------------------------------------

    /**
     * Registers an op with the bridge.
     *
     * <p>Must be called before the op's upcall stub is handed to the
     * C library, so that the C side can never invoke a callback the
     * bridge does not know about.
     *
     * @param op the op to register; must not be null
     */
    public void register(AsyncOp op) {
        long id = nextId.incrementAndGet();
        ops.put(id, op);
    }

    /**
     * Arms a Python-side timeout on the given op.
     *
     * <p>When the timeout fires, the op is transitioned to ABANDONED,
     * the associated Future (if any) is resolved with a
     * {@link lingofuse.errors.LingoFuseTimeoutException}, and the op
     * is held alive for {@link #graceSeconds} before release.
     *
     * @param op        the op to arm
     * @param timeoutMs the timeout in milliseconds; values {@code <= 0}
     *                  are ignored
     */
    public void scheduleTimeout(AsyncOp op, long timeoutMs) {
        if (timeoutMs <= 0) {
            return;
        }
        if (shutdown) {
            return;
        }
        try {
            scheduler.schedule(
                    () -> handleTimeout(op),
                    timeoutMs,
                    TimeUnit.MILLISECONDS);
        } catch (java.util.concurrent.RejectedExecutionException e) {
            // The scheduler was shut down between the check above
            // and the schedule call. Drop the timeout.
        }
    }

    /**
     * Schedules immediate release of the given op.
     *
     * <p>Package-private: called by {@link AsyncOp} on state
     * transitions.
     */
    void scheduleReleaseNow(AsyncOp op) {
        if (shutdown) {
            releaseOp(op);
            return;
        }
        try {
            scheduler.execute(() -> releaseOp(op));
        } catch (java.util.concurrent.RejectedExecutionException e) {
            // Shutting down; release synchronously as a fallback.
            releaseOp(op);
        }
    }

    /**
     * Schedules release of the given op after the grace period.
     *
     * <p>Package-private: called by the reclamation path.
     */
    void scheduleReleaseAfterGrace(AsyncOp op) {
        long delayMs = (long) Math.max(0, graceSeconds * 1000.0);
        if (shutdown) {
            releaseOp(op);
            return;
        }
        try {
            scheduler.schedule(
                    () -> releaseOp(op),
                    delayMs,
                    TimeUnit.MILLISECONDS);
        } catch (java.util.concurrent.RejectedExecutionException e) {
            releaseOp(op);
        }
    }

    // ------------------------------------------------------------------
    // Timeout handling
    // ------------------------------------------------------------------

    private void handleTimeout(AsyncOp op) {
        // Attempt the PENDING -> ABANDONED transition. If the op is
        // no longer PENDING, some other path won the race and there
        // is nothing for us to do.
        if (!op.abandon()) {
            return;
        }

        // If the op has a Future, resolve it with a timeout exception
        // and mark it abandoned.
        java.util.concurrent.CompletableFuture<?> fut = op.future();
        if (fut instanceof CallFuture<?> cf) {
            cf.markAbandoned();
            if (!cf.isDone()) {
                try {
                    cf.completeExceptionally(
                            new lingofuse.errors.LingoFuseTimeoutException(
                                    "async call to '" + op.apiName()
                                            + "' abandoned after timeout; "
                                            + "the C-side request may "
                                            + "still be in flight, but "
                                            + "its result will be "
                                            + "discarded."));
                } catch (Throwable ignored) {
                    // Race: someone else resolved the future between
                    // our isDone() check and the completion attempt.
                    // The other party wins.
                }
            }
        }

        // Keep the op alive for the grace period so that a late
        // callback can still find a valid Java object.
        scheduleReleaseAfterGrace(op);
    }

    // ------------------------------------------------------------------
    // Release
    // ------------------------------------------------------------------

    private void releaseOp(AsyncOp op) {
        // Find and remove the op. We iterate because the id is stored
        // inside the bridge, not on the op itself.
        for (Map.Entry<Long, AsyncOp> entry : ops.entrySet()) {
            if (entry.getValue() == op) {
                if (ops.remove(entry.getKey(), op)) {
                    releaseCount.incrementAndGet();
                }
                return;
            }
        }
    }

    // ------------------------------------------------------------------
    // Diagnostics
    // ------------------------------------------------------------------

    /**
     * Returns a snapshot of the bridge's current state.
     *
     * <p>The returned map is a plain copy; mutating it does not affect
     * the bridge. Safe to call from any thread.
     *
     * @return a snapshot map with keys
     *         {@code total}, {@code pending}, {@code fired},
     *         {@code abandoned}, {@code not_queued},
     *         {@code released_total}, {@code grace_seconds}
     */
    public Map<String, Object> stats() {
        long total = 0;
        long pending = 0;
        long fired = 0;
        long abandoned = 0;
        long notQueued = 0;

        for (AsyncOp op : ops.values()) {
            total++;
            switch (op.state()) {
                case AsyncOp.STATE_PENDING:    pending++;    break;
                case AsyncOp.STATE_FIRED:      fired++;      break;
                case AsyncOp.STATE_ABANDONED:  abandoned++;  break;
                case AsyncOp.STATE_NOT_QUEUED: notQueued++;  break;
                default: break;
            }
        }

        Map<String, Object> m = new java.util.LinkedHashMap<>();
        m.put("total", total);
        m.put("pending", pending);
        m.put("fired", fired);
        m.put("abandoned", abandoned);
        m.put("not_queued", notQueued);
        m.put("released_total", releaseCount.get());
        m.put("grace_seconds", graceSeconds);
        return m;
    }

    /**
     * Returns the current number of live ops. Cheap convenience
     * accessor for tests.
     *
     * @return the number of registered ops
     */
    public int liveOpCount() {
        return ops.size();
    }

    // ------------------------------------------------------------------
    // Shutdown
    // ------------------------------------------------------------------

    /**
     * Releases every tracked op and stops the scheduler.
     *
     * <p>Safe to call multiple times. After shutdown, the bridge is
     * unusable; obtain a fresh instance via {@link #instance()}.
     */
    public void shutdown() {
        synchronized (lock) {
            if (shutdown) {
                return;
            }
            shutdown = true;
        }

        ops.clear();

        scheduler.shutdownNow();
        try {
            scheduler.awaitTermination(2, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}