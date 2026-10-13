package lingofuse.demo.cross;

import lingofuse.Framework;
import lingofuse.LingoFuseStatus;
import lingofuse.NetworkEvents;

import java.util.Scanner;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Coordinator process for the IPC endpoint {@code ipc:cross}.
 *
 * <p>Installs a JVM shutdown hook that guarantees cleanup exactly
 * once on every exit path, including {@code System.exit()}.
 */
public final class CrossService {

    public static final String ENDPOINT = "ipc:cross";

    private static final AtomicBoolean CLEANED_UP = new AtomicBoolean(false);
    private static volatile boolean frameworkStarted = false;

    static {
        Runtime.getRuntime().addShutdownHook(
                new Thread(CrossService::cleanupOnce,
                        "CrossService-shutdown-hook"));
    }

    private CrossService() {
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
        System.out.println("=== Cross Service (Coordinator) ===");
        System.out.println();

        int exitCode = 0;

        try {
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
            Framework.setOption("Wait_Connection_Timeout", "10000");

            Framework.resetPrepare();

            if (Framework.prepareService(ENDPOINT, ENDPOINT) == -1) {
                System.err.println(
                        "[FATAL] prepareService returned -1 for " + ENDPOINT);
                System.exit(1);
            }

            if (Framework.prepareClient(ENDPOINT, null) == -1) {
                System.err.println(
                        "[FATAL] prepareClient returned -1 for " + ENDPOINT);
                System.exit(1);
            }

            int done = Framework.prepareDone();
            if (done != 1 && !LingoFuseStatus.checkMainThread()) {
                System.err.println(
                        "[FATAL] prepareDone returned " + done
                                + " and the main thread is not running.");
                System.exit(1);
            }

            frameworkStarted = true;

            System.out.println("IPC service '" + ENDPOINT
                    + "' is running. Press Enter to exit...");
            try (Scanner scanner = new Scanner(System.in)) {
                if (scanner.hasNextLine()) {
                    scanner.nextLine();
                }
            }

            System.out.println("Shutting down...");

        } catch (Throwable t) {
            System.err.println("[FATAL] "
                    + t.getClass().getSimpleName() + ": " + t.getMessage());
            t.printStackTrace(System.err);
            exitCode = 1;
        } finally {
            cleanupOnce();
        }

        System.out.println("Bye.");
        if (exitCode != 0) {
            System.exit(exitCode);
        }
    }
}