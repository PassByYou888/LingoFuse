package lingofuse.demo;

import lingofuse.AppHandle;
import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.LfIo;
import lingofuse.LingoFuseStatus;
import lingofuse.NetworkEvents;

import java.util.Scanner;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Minimal end-to-end demonstration of the LingoFuse Java binding.
 *
 * <p>Lifecycle: installs a JVM shutdown hook that runs a single-shot
 * {@code cleanupOnce()} action. The same action runs from the
 * {@code finally} block, so cleanup is guaranteed exactly once on
 * every exit path, including {@code System.exit()}.
 */
public final class EchoDemo {

    private static final String ENDPOINT = "ipc:lingofuse_java_demo";
    private static final String APP_NAME = "EchoApp";
    private static final long CALL_TIMEOUT_MS = 3000L;

    private static final AtomicBoolean CLEANED_UP = new AtomicBoolean(false);
    private static volatile boolean frameworkStarted = false;

    static {
        Runtime.getRuntime().addShutdownHook(
                new Thread(EchoDemo::cleanupOnce, "EchoDemo-shutdown-hook"));
    }

    private EchoDemo() {
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
        System.out.println("=== LingoFuse Java binding - Echo demo ===");
        System.out.println();

        AppHandle app = null;
        int exitCode = 0;

        try {
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
            Framework.setOption("Wait_Connection_Timeout", "10000");

            Framework.resetPrepare();

            app = new AppHandle(APP_NAME, "Java demo echo service");

            if (!app.registerCall("echo", "Echo a string",
                    (input, output) -> {
                        String s = LfIo.readString(input);
                        LfIo.writeString(output, s);
                    })) {
                throw new IllegalStateException(
                        "Failed to register API 'echo'");
            }

            if (!app.registerCall("add", "Add two integers",
                    (input, output) -> {
                        int a = input.readInt32();
                        int b = input.readInt32();
                        output.writeInt32(a + b);
                    })) {
                throw new IllegalStateException(
                        "Failed to register API 'add'");
            }

            System.out.println("[Setup] Registered APIs 'echo' and 'add'.");

            if (Framework.prepareService(ENDPOINT, ENDPOINT) == -1) {
                throw new IllegalStateException(
                        "prepareService returned -1 for " + ENDPOINT);
            }
            if (Framework.prepareClient(ENDPOINT, app) == -1) {
                throw new IllegalStateException(
                        "prepareClient returned -1 for " + ENDPOINT);
            }

            System.out.println("[Setup] Service and client prepared on "
                    + ENDPOINT + ".");

            int done = Framework.prepareDone();
            if (done != 1 && !LingoFuseStatus.checkMainThread()) {
                throw new IllegalStateException(
                        "prepareDone returned " + done
                                + " and the main thread is not running.");
            }
            frameworkStarted = true;
            System.out.println("[Setup] Framework started.");

            boolean visible = false;
            for (int i = 0; i < 50; i++) {
                if (LingoFuseStatus.checkApi(APP_NAME, "echo")) {
                    visible = true;
                    break;
                }
                Thread.sleep(200);
            }
            if (!visible) {
                System.out.println(
                        "[Warn] App did not become visible within 10 seconds.");
            } else {
                System.out.println("[Setup] App '" + APP_NAME
                        + "' is visible on the mesh.");
            }

            System.out.println();
            System.out.println("--- Remote call via Framework.call() ---");
            demonstrateEchoViaRemoteCall();
            demonstrateAddViaRemoteCall();

            System.out.println();
            System.out.println("--- Local call via AppHandle.localCall() ---");
            demonstrateEchoViaLocalCall(app);
            demonstrateAddViaLocalCall(app);

            System.out.println();
            System.out.println("[Demo] All demonstrations completed.");
            System.out.println("[Demo] Press Enter to shut down...");
            try (Scanner scanner = new Scanner(System.in)) {
                if (scanner.hasNextLine()) {
                    scanner.nextLine();
                }
            }

        } catch (Throwable t) {
            System.err.println("[Fatal] " + t);
            t.printStackTrace(System.err);
            exitCode = 1;
        } finally {
            if (app != null) {
                try {
                    app.close();
                } catch (Throwable ignored) {
                }
            }
            cleanupOnce();
            System.out.println("[Cleanup] Done.");
        }

        if (exitCode != 0) {
            System.exit(exitCode);
        }
    }

    private static void demonstrateEchoViaRemoteCall() {
        try (DataHandle request = new DataHandle("echo")) {
            LfIo.writeJson(request, "Hello, \u4e16\u754c!");

            try (DataHandle response = Framework.call(
                    APP_NAME, request, CALL_TIMEOUT_MS)) {

                if (response.size() == 0) {
                    System.out.println("  echo: no response (timeout)");
                    return;
                }
                String echoed = LfIo.readJson(response, String.class);
                System.out.println("  echo -> " + echoed);
            }
        }
    }

    private static void demonstrateAddViaRemoteCall() {
        try (DataHandle request = new DataHandle("add")) {
            request.writeInt32(5);
            request.writeInt32(7);

            try (DataHandle response = Framework.call(
                    APP_NAME, request, CALL_TIMEOUT_MS)) {

                if (response.size() == 0) {
                    System.out.println("  add: no response (timeout)");
                    return;
                }
                int result = response.readInt32();
                System.out.println("  add(5, 7) -> " + result);
            }
        }
    }

    private static void demonstrateEchoViaLocalCall(AppHandle app) {
        try (DataHandle request = new DataHandle("echo")) {
            LfIo.writeJson(request, "Local call, \u4f60\u597d!");

            try (DataHandle response = app.localCall(request)) {
                if (response.size() == 0) {
                    System.out.println("  echo: empty response");
                    return;
                }
                String echoed = LfIo.readJson(response, String.class);
                System.out.println("  echo -> " + echoed);
            }
        }
    }

    private static void demonstrateAddViaLocalCall(AppHandle app) {
        try (DataHandle request = new DataHandle("add")) {
            request.writeInt32(40);
            request.writeInt32(2);

            try (DataHandle response = app.localCall(request)) {
                if (response.size() == 0) {
                    System.out.println("  add: empty response");
                    return;
                }
                int result = response.readInt32();
                System.out.println("  add(40, 2) -> " + result);
            }
        }
    }
}