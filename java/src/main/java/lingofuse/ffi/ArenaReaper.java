package lingofuse.ffi;

import java.lang.foreign.Arena;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;

/**
 * Shared deferred-release scheduler for FFM arenas.
 *
 * <p>Components that install upcall stubs in an arena must not close
 * the arena eagerly when the registration is retired: the native
 * library may still be about to invoke the stub on a worker thread.
 * Closing the arena eagerly would leave a dangling function pointer,
 * which crashes the process on the next invocation.
 *
 * <p>This class provides a single process-wide scheduler that closes
 * arenas after a bounded grace period. The default grace period is
 * generous (30 s) because the failure mode being protected against
 * is a process-wide crash, whereas the resource being protected is a
 * few hundred bytes of native memory.
 *
 * <h2>Cross-language compatibility</h2>
 *
 * <p>This class is a JAVA-PRIVATE resource manager for FFM upcall
 * stub memory. It does NOT participate in any wire protocol, does
 * NOT affect the byte sequence of any LF_* call, and does NOT
 * change any observable semantics of the LingoFuse ABI. Other
 * bindings do not have and do not need an equivalent mechanism:
 * they manage their own callback objects according to the language's
 * own rules.
 *
 * <p>The arena that is retired here is the FFM-side storage for the
 * Java-to-native trampoline. The LingoFuse library itself never sees
 * this arena; it only sees the raw function pointer that was
 * extracted from it.
 *
 * <p>DO NOT move this logic into the wire layer.
 */
public final class ArenaReaper {

    private static final long DEFAULT_GRACE_MS = 30_000L;

    private static final ScheduledExecutorService SCHEDULER =
            Executors.newSingleThreadScheduledExecutor(new ThreadFactory() {
                @Override
                public Thread newThread(Runnable r) {
                    Thread t = new Thread(r, "LingoFuse-ArenaReaper");
                    t.setDaemon(true);
                    return t;
                }
            });

    private ArenaReaper() {
    }

    /**
     * Retires the given arena with the default grace period.
     *
     * @param arena the arena to close; may be null
     */
    public static void retire(Arena arena) {
        retire(arena, DEFAULT_GRACE_MS);
    }

    /**
     * Retires the given arena after the specified grace period.
     *
     * @param arena   the arena to close; may be null
     * @param graceMs the delay in milliseconds before closing
     */
    public static void retire(Arena arena, long graceMs) {
        if (arena == null) {
            return;
        }
        try {
            SCHEDULER.schedule(() -> {
                try {
                    arena.close();
                } catch (Throwable ignored) {
                    // Already closed or JVM exiting.
                }
            }, Math.max(0L, graceMs), TimeUnit.MILLISECONDS);
        } catch (Throwable ignored) {
            // Scheduler already shut down; the OS reclaims the memory
            // when the process terminates.
        }
    }
}