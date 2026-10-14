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
 * <p>Owns a single-threaded scheduler for timeouts and delayed
 * releases. Use {@link #instance()} to obtain the singleton, and
 * {@link #shutdownInstance()} to release it (intended for tests and
 * process teardown).
 *
 * <h2>Release path</h2>
 *
 * <p>An op leaves the active registry through one of three paths:
 *
 * <ol>
 *   <li>{@link AsyncOp#markNotQueued()} — the native dispatch was
 *       rejected before the request was queued. The release is
 *       scheduled immediately.</li>
 *   <li>{@link AsyncOp#invokeFromC(MemorySegment, Throwable)} — the
 *       C-side callback arrived. The release is scheduled
 *       immediately.</li>
 *   <li>{@link #handleTimeout} — the JS-side timeout fired before
 *       the callback arrived. The release is deferred by the
 *       configured grace period, so a straggling callback can still
 *       land on a valid trampoline.</li>
 * </ol>
 *
 * <p>In every case, the release path removes the op from the
 * registry by its assigned key (O(1)) and closes the stub arena. See
 * {@link AsyncOp#releaseResources()} for the arena-closing contract.
 *
 * <h2>Shutdown</h2>
 *
 * <p>{@link #shutdown()} releases every tracked op's resources
 * unconditionally, including any op currently in the ABANDONED
 * state. This is a deliberate departure from the grace-period logic:
 * once the bridge is being torn down, waiting for a callback that may
 * never arrive would just delay process exit.
 *
 * <h2>Notes on lifetime</h2>
 * <ul>
 *   <li>{@code scheduleTimeout(op, 0)} is a no-op (no timeout is
 *       armed).</li>
 *   <li>{@code scheduleTimeout(op, negative)} throws
 *       {@link IllegalArgumentException}.</li>
 * </ul>
 */
public final class AsyncBridge {

    private static volatile AsyncBridge INSTANCE;

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

    private final Map<Long, AsyncOp> ops = new ConcurrentHashMap<>();
    private final AtomicLong nextId = new AtomicLong(0);
    private final AtomicLong releaseCount = new AtomicLong(0);
    private final ScheduledExecutorService scheduler;
    private final Object lock = new Object();
    private volatile boolean shutdown = false;

    public volatile double graceSeconds = 60.0;

    private AsyncBridge() {
        ThreadFactory tf = r -> {
            Thread t = new Thread(r, "LingoFuseAsyncBridge");
            t.setDaemon(true);
            return t;
        };
        this.scheduler = Executors.newSingleThreadScheduledExecutor(tf);
    }

    /**
     * Registers an op and assigns it a stable registry key. Must be
     * called BEFORE the op's upcall stub is handed to the native
     * library.
     */
    public void register(AsyncOp op) {
        long id = nextId.incrementAndGet();
        op.setKey(id);
        ops.put(id, op);
    }

    /**
     * Arms a JS-side timeout on the given op.
     *
     * @param op        the op
     * @param timeoutMs the timeout in milliseconds; zero disables the
     *                  timeout
     * @throws IllegalArgumentException when {@code timeoutMs} is
     *         negative
     */
    public void scheduleTimeout(AsyncOp op, long timeoutMs) {
        if (timeoutMs < 0) {
            throw new IllegalArgumentException(
                    "timeoutMs must be non-negative: " + timeoutMs);
        }
        if (timeoutMs == 0) {
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
            // Scheduler is shutting down; drop the timeout.
        }
    }

    void scheduleReleaseNow(AsyncOp op) {
        if (shutdown) {
            releaseOp(op);
            return;
        }
        try {
            scheduler.execute(() -> releaseOp(op));
        } catch (java.util.concurrent.RejectedExecutionException e) {
            releaseOp(op);
        }
    }

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

    private void handleTimeout(AsyncOp op) {
        if (!op.abandon()) {
            return;
        }

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
                    // Race with another completion path.
                }
            }
        }

        scheduleReleaseAfterGrace(op);
    }

    /**
     * Removes an op from the registry and releases its resources.
     *
     * <p>O(1): the op carries the registry key assigned at
     * registration time, so the removal is a direct map lookup
     * rather than a linear scan.
     *
     * <p>Idempotent: a second call for the same op is a no-op
     * because the key is no longer present in the registry.
     */
    private void releaseOp(AsyncOp op) {
        long key = op.key();
        if (key == 0L) {
            // The op was never registered (for example, a
            // mis-constructed op that has not gone through
            // register()). Nothing to release.
            return;
        }
        if (ops.remove(key, op)) {
            op.releaseResources();
            releaseCount.incrementAndGet();
        }
    }

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

    public int liveOpCount() {
        return ops.size();
    }

    public void shutdown() {
        synchronized (lock) {
            if (shutdown) {
                return;
            }
            shutdown = true;
        }

        // Release every tracked op's resources before stopping the
        // scheduler.
        //
        // The release is UNCONDITIONAL, including for ops currently
        // in the ABANDONED state. During normal operation the
        // ABANDONED state defers the arena close by graceSeconds to
        // give a straggling callback a chance to land on a valid
        // trampoline; during shutdown there is nothing left to wait
        // for, and delaying process exit for a callback that may
        // never arrive is strictly worse than dropping it.
        java.util.List<AsyncOp> snapshot =
                new java.util.ArrayList<>(ops.values());
        for (AsyncOp op : snapshot) {
            op.releaseResources();
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