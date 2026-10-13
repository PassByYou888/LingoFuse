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
 * <p>Notes on lifetime:
 * <ul>
 *   <li>{@code scheduleTimeout(op, 0)} is a no-op (no timeout is
 *       armed).</li>
 *   <li>{@code scheduleTimeout(op, negative)} throws
 *       {@link IllegalArgumentException}.</li>
 *   <li>{@link #shutdown()} releases all tracked op resources before
 *       stopping the scheduler. Any callback that arrives after
 *       shutdown notifies its owner bridge through
 *       {@link AsyncOp#ownerBridge()}; the release falls back to the
 *       synchronous path.</li>
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

    public void register(AsyncOp op) {
        long id = nextId.incrementAndGet();
        ops.put(id, op);
    }

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

    private void releaseOp(AsyncOp op) {
        for (Map.Entry<Long, AsyncOp> entry : ops.entrySet()) {
            if (entry.getValue() == op) {
                if (ops.remove(entry.getKey(), op)) {
                    op.releaseResources();
                    releaseCount.incrementAndGet();
                }
                return;
            }
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

        // Release resources for every tracked op before stopping the
        // scheduler. Ops in the ABANDONED state keep their arena open
        // (see AsyncOp.releaseResources).
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