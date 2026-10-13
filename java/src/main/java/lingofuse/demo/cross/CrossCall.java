package lingofuse.demo.cross;

import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.LingoFuseStatus;
import lingofuse.NetworkEvents;
import lingofuse.errors.LingoFuseException;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.Scanner;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Concurrent client / load tester for the {@code ipc:cross} endpoint.
 *
 * <p>Installs a JVM shutdown hook so cleanup runs exactly once on
 * every exit path.
 */
public final class CrossCall {

    private static final String TARGET_APP = "demo";
    private static final String ENDPOINT = CrossService.ENDPOINT;

    private static final int WORKER_THREADS = 32;
    private static final int TEST_SECONDS = 10;
    private static final long CALL_TIMEOUT_MS = 1000L;

    private static final int PAUSE_MS =
            Integer.getInteger("lingofuse.crosscall.pause", 0);

    private static final long LOG_EVERY_NTH_CALL = 5000L;

    private static final int NUMBER_MIN = 1;
    private static final int NUMBER_MAX = 1000;

    private static final int INV_B = 200;
    private static final int INV_W = 0x10;
    private static final long INV_C = 0x2FL;
    private static final long INV_U64 = 0x3FL;
    private static final String INV_S = "hello world";
    private static final float INV_F = 3.14f;

    private static final BlockingQueue<String> LOG_QUEUE =
            new LinkedBlockingQueue<>();

    private static final AtomicBoolean CLEANED_UP = new AtomicBoolean(false);
    private static volatile boolean frameworkStarted = false;

    static {
        Thread t = new Thread(() -> {
            try {
                while (true) {
                    String line = LOG_QUEUE.take();
                    System.out.print(line);
                    System.out.print('\n');
                    System.out.flush();
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }, "CrossCall-log");
        t.setDaemon(true);
        t.start();

        Runtime.getRuntime().addShutdownHook(
                new Thread(CrossCall::cleanupOnce,
                        "CrossCall-shutdown-hook"));
    }

    private static void log(String line) {
        LOG_QUEUE.offer(line);
    }

    private static volatile boolean STOP_REQUESTED = false;

    private static final class Stats {
        long totalCalls;
        long successCalls;
        long failedCalls;
        long addCalls;
        long invSeriCalls;
    }

    private static final Object STATS = new Object();
    private static final Stats STATS_DATA = new Stats();

    private CrossCall() {
    }

    private static void cleanupOnce() {
        if (!CLEANED_UP.compareAndSet(false, true)) {
            return;
        }
        try {
            NetworkEvents.clear();
        } catch (Throwable ignored) {
        }
        try {
            if (frameworkStarted) {
                Framework.exitMainThread();
            }
        } catch (Throwable ignored) {
        }
        try {
            if (frameworkStarted) {
                Framework.shutdown();
            }
        } catch (Throwable ignored) {
        }
    }

    public static void main(String[] args) {
        System.out.println("=== Cross Call (Client) ===");
        System.out.println("[Call] Per-call pause: " + PAUSE_MS + " ms");
        System.out.println();

        int exitCode = 0;

        try {
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
            Framework.setOption("Wait_Connection_Timeout", "10000");

            Framework.resetPrepare();

            if (Framework.prepareClient(ENDPOINT, null) == -1) {
                throw new IllegalStateException(
                        "prepareClient returned -1 for " + ENDPOINT);
            }

            int done = Framework.prepareDone();
            if (done != 1 && !LingoFuseStatus.checkMainThread()) {
                throw new IllegalStateException(
                        "prepareDone returned " + done
                                + " and the main thread is not running.");
            }

            frameworkStarted = true;

            System.out.println("[Call] Connected to " + ENDPOINT
                    + ". Starting " + TEST_SECONDS
                    + "-second load test with " + WORKER_THREADS
                    + " threads...");
            System.out.println();

            long startNanos = System.nanoTime();

            CountDownLatch doneLatch = new CountDownLatch(WORKER_THREADS);

            List<Thread> threads = new ArrayList<>(WORKER_THREADS);
            for (int i = 0; i < WORKER_THREADS; i++) {
                final int index = i;
                Thread t = new Thread(
                        () -> workerBody(index, doneLatch),
                        "cross-call-" + i);
                t.setDaemon(true);
                threads.add(t);
                t.start();
            }

            Thread.sleep(TEST_SECONDS * 1000L);
            STOP_REQUESTED = true;
            doneLatch.await();

            long elapsedNanos = System.nanoTime() - startNanos;
            double elapsedSec = elapsedNanos / 1_000_000_000.0;

            long total;
            long success;
            long failed;
            long add;
            long invSeri;
            synchronized (STATS) {
                total = STATS_DATA.totalCalls;
                success = STATS_DATA.successCalls;
                failed = STATS_DATA.failedCalls;
                add = STATS_DATA.addCalls;
                invSeri = STATS_DATA.invSeriCalls;
            }

            printSummary(elapsedSec, total, success, failed, add, invSeri);

            System.out.println("[Call] Press Enter to exit...");
            try (Scanner scanner = new Scanner(System.in)) {
                if (scanner.hasNextLine()) {
                    scanner.nextLine();
                }
            }

        } catch (Throwable t) {
            System.err.println("[FATAL] "
                    + t.getClass().getSimpleName() + ": " + t.getMessage());
            t.printStackTrace(System.err);
            exitCode = 1;
        } finally {
            cleanupOnce();
        }

        try {
            Thread.sleep(100);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }

        System.out.println("[Call] Bye.");
        if (exitCode != 0) {
            System.exit(exitCode);
        }
    }

    private static void printSummary(
            double elapsedSec,
            long total, long success, long failed,
            long add, long invSeri) {

        double successRate = (total > 0)
                ? 100.0 * success / total
                : 0.0;
        double throughput = (elapsedSec > 0)
                ? total / elapsedSec
                : 0.0;
        double successThroughput = (elapsedSec > 0)
                ? success / elapsedSec
                : 0.0;

        System.out.println();
        System.out.println("[Call] Load test summary");
        System.out.printf("         duration          : %.3f s%n", elapsedSec);
        System.out.printf("         total calls       : %d%n", total);
        System.out.printf("         success           : %d (%.2f %%)%n",
                success, successRate);
        System.out.printf("         failed            : %d%n", failed);
        System.out.printf("         add calls         : %d%n", add);
        System.out.printf("         inv_seri calls    : %d%n", invSeri);
        System.out.printf("         throughput        : %.2f calls/s%n",
                throughput);
        System.out.printf("         success throughput: %.2f calls/s%n",
                successThroughput);
        System.out.println();
    }

    private static void workerBody(int index, CountDownLatch doneLatch) {
        try {
            Random rng = new Random(
                    System.nanoTime() * 397L + index);

            long iter = 0L;
            while (!STOP_REQUESTED) {
                iter++;
                boolean doLog = (iter % LOG_EVERY_NTH_CALL == 0);

                if (rng.nextBoolean()) {
                    int a = NUMBER_MIN
                            + rng.nextInt(NUMBER_MAX - NUMBER_MIN + 1);
                    int b = NUMBER_MIN
                            + rng.nextInt(NUMBER_MAX - NUMBER_MIN + 1);

                    AddResult r = remoteAdd(a, b);

                    synchronized (STATS) {
                        STATS_DATA.totalCalls++;
                        STATS_DATA.addCalls++;
                        if (r.ok) {
                            STATS_DATA.successCalls++;
                        } else {
                            STATS_DATA.failedCalls++;
                        }
                    }

                    if (doLog) {
                        if (r.ok) {
                            log("[Call " + index + "] add(" + a + ", " + b
                                    + ") = " + r.sum);
                        } else {
                            log("[Call " + index + "] add(" + a + ", " + b
                                    + ") timed out or failed.");
                        }
                    }
                } else {
                    InvResult r = remoteInvSeri();

                    synchronized (STATS) {
                        STATS_DATA.totalCalls++;
                        STATS_DATA.invSeriCalls++;
                        if (r.ok) {
                            STATS_DATA.successCalls++;
                        } else {
                            STATS_DATA.failedCalls++;
                        }
                    }

                    if (doLog) {
                        if (r.ok) {
                            log("[Call " + index + "] " + r.text);
                        } else {
                            log("[Call " + index
                                    + "] inv_seri timed out or failed.");
                        }
                    }
                }

                if (PAUSE_MS > 0) {
                    try {
                        Thread.sleep(PAUSE_MS);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            }
        } finally {
            doneLatch.countDown();
        }
    }

    private static final class AddResult {
        final boolean ok;
        final int sum;

        AddResult(boolean ok, int sum) {
            this.ok = ok;
            this.sum = sum;
        }
    }

    private static final class InvResult {
        final boolean ok;
        final String text;

        InvResult(boolean ok, String text) {
            this.ok = ok;
            this.text = text;
        }
    }

    private static AddResult remoteAdd(int a, int b) {
        try (DataHandle request = new DataHandle("add")) {
            request.writeInt32(a);
            request.writeInt32(b);

            try (DataHandle response = Framework.call(
                    TARGET_APP, request, CALL_TIMEOUT_MS)) {

                if (response.size() < 4) {
                    return new AddResult(false, 0);
                }
                return new AddResult(true, response.readInt32());
            }
        } catch (LingoFuseException ex) {
            return new AddResult(false, 0);
        } catch (Throwable t) {
            return new AddResult(false, 0);
        }
    }

    private static InvResult remoteInvSeri() {
        try (DataHandle request = new DataHandle("inv_seri")) {
            request.writeUInt8(INV_B);
            request.writeUInt16(INV_W);
            request.writeUInt32(INV_C);
            request.writeUInt64(INV_U64);
            request.writeString(INV_S);
            request.writeSingle(INV_F);

            try (DataHandle response = Framework.call(
                    TARGET_APP, request, CALL_TIMEOUT_MS)) {

                if (response.size() == 0) {
                    return new InvResult(false, null);
                }

                float rf = response.readSingle();
                String rs = response.readString();
                long ru64 = response.readUInt64();
                long rc = response.readUInt32();
                int rw = response.readUInt16();
                int rb = response.readUInt8();

                String text = "reply: [" + rb + ", " + rw + ", " + rc
                        + ", " + ru64 + ", \"" + rs + "\", " + rf
                        + "]  original: [" + INV_B + ", " + INV_W + ", "
                        + INV_C + ", " + INV_U64 + ", \"" + INV_S + "\", "
                        + INV_F + "]";
                return new InvResult(true, text);
            }
        } catch (LingoFuseException ex) {
            return new InvResult(false, null);
        } catch (Throwable t) {
            return new InvResult(false, null);
        }
    }
}