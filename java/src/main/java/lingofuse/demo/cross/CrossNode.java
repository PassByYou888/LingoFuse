package lingofuse.demo.cross;

import lingofuse.AppHandle;
import lingofuse.Framework;
import lingofuse.LingoFuseStatus;
import lingofuse.NetworkEvents;

import java.util.Scanner;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Worker node that registers the {@code add} and {@code inv_seri} Call
 * APIs and connects to the IPC endpoint {@code ipc:cross} as a client.
 *
 * <p>Installs a JVM shutdown hook so cleanup runs exactly once on
 * every exit path.
 */
public final class CrossNode {

    private static final String ENDPOINT = CrossService.ENDPOINT;
    private static final String APP_NAME = "demo";

    private static final AtomicLong ADD_COUNT = new AtomicLong(0);
    private static final AtomicLong INV_SERI_COUNT = new AtomicLong(0);

    private static final AtomicBoolean CLEANED_UP = new AtomicBoolean(false);
    private static volatile AppHandle application = null;
    private static volatile boolean frameworkStarted = false;

    private static final BlockingQueue<String> LOG_QUEUE =
            new LinkedBlockingQueue<>();

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
        }, "CrossNode-log");
        t.setDaemon(true);
        t.start();

        Runtime.getRuntime().addShutdownHook(
                new Thread(CrossNode::cleanupOnce,
                        "CrossNode-shutdown-hook"));
    }

    private static void log(String line) {
        LOG_QUEUE.offer(line);
    }

    private CrossNode() {
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
        AppHandle app = application;
        if (app != null) {
            try {
                app.close();
            } catch (Throwable ignored) {
            }
        }
        try {
            if (frameworkStarted) {
                Framework.shutdown();
            }
        } catch (Throwable ignored) {
        }
    }

    public static void main(String[] args) {
        System.out.println("=== Cross Node (Worker) ===");
        System.out.println("[Node] Every invocation will be logged.");
        System.out.println();

        int exitCode = 0;

        try {
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
            Framework.setOption("Wait_Connection_Timeout", "10000");

            Framework.resetPrepare();

            AppHandle app = new AppHandle(
                    APP_NAME, "Java worker node (ABI wire format)");
            application = app;

            registerAdd(app);
            registerInvSeri(app);

            if (Framework.prepareClient(ENDPOINT, app) == -1) {
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

            log("[Node] Registered APIs 'add' and 'inv_seri' "
                    + "under application '" + APP_NAME + "'.");
            log("[Node] Online. Press Enter to exit...");

            try (Scanner scanner = new Scanner(System.in)) {
                if (scanner.hasNextLine()) {
                    scanner.nextLine();
                }
            }

            log("[Node] Shutting down...");
            log("[Node] Handled " + ADD_COUNT.get() + " add calls, "
                    + INV_SERI_COUNT.get() + " inv_seri calls.");

        } catch (Throwable t) {
            System.err.println("[FATAL] "
                    + t.getClass().getSimpleName() + ": " + t.getMessage());
            t.printStackTrace(System.err);
            exitCode = 1;
        } finally {
            cleanupOnce();
        }

        try {
            Thread.sleep(200);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }

        System.out.println("[Node] Bye.");
        if (exitCode != 0) {
            System.exit(exitCode);
        }
    }

    private static void registerAdd(AppHandle app) {
        if (!app.registerCall(
                "add",
                "add(int a, int b) -> int",
                (input, output) -> {
                    int a = input.readInt32();
                    int b = input.readInt32();
                    int c = a + b;

                    long n = ADD_COUNT.incrementAndGet();
                    log("[Node] add #" + n + "(" + a + ", " + b + ") = " + c);

                    output.writeInt32(c);
                })) {
            throw new IllegalStateException(
                    "Failed to register API 'add'");
        }
    }

    private static void registerInvSeri(AppHandle app) {
        if (!app.registerCall(
                "inv_seri",
                "inv_seri() -> reversed typed sequence",
                (input, output) -> {
                    int b = input.readUInt8();
                    int w = input.readUInt16();
                    long c = input.readUInt32();
                    long u64 = input.readUInt64();
                    String s = input.readString();
                    float f = input.readSingle();

                    long n = INV_SERI_COUNT.incrementAndGet();
                    log("[Node] inv_seri #" + n + " received: ["
                            + b + ", " + w + ", " + c + ", " + u64
                            + ", \"" + s + "\", " + f + "]");

                    output.writeSingle(f);
                    output.writeString(s);
                    output.writeUInt64(u64);
                    output.writeUInt32(c);
                    output.writeUInt16(w);
                    output.writeUInt8(b);

                    log("[Node] inv_seri #" + n + " replied: ["
                            + f + ", \"" + s + "\", " + u64 + ", "
                            + c + ", " + w + ", " + b + "]");
                })) {
            throw new IllegalStateException(
                    "Failed to register API 'inv_seri'");
        }
    }
}