package lingofuse.demo;

import lingofuse.AppHandle;
import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.LfIo;
import lingofuse.LingoFuseStatus;

import java.util.Scanner;

/**
 * Minimal end-to-end demonstration of the LingoFuse Java binding.
 *
 * <p>This program runs a single process that acts as both a service
 * and a client, self-connected over a local IPC endpoint. It
 * exercises the complete lifecycle:
 *
 * <ol>
 *   <li>Create an {@link AppHandle} and register a Call API.</li>
 *   <li>Prepare a C4 service and a client on the same endpoint.</li>
 *   <li>Start the framework.</li>
 *   <li>Wait for the application to become visible on the mesh.</li>
 *   <li>Invoke the API through {@link Framework#call(String, DataHandle, long)}.</li>
 *   <li>Invoke the API locally through {@link AppHandle#localCall(DataHandle)}.</li>
 *   <li>Perform a clean shutdown in the documented order.</li>
 * </ol>
 *
 * <h2>Registered APIs</h2>
 *
 * <ul>
 *   <li>{@code echo}: receives a JSON string, returns the same JSON
 *       string.</li>
 *   <li>{@code add}: receives a JSON array of two integers, returns
 *       a JSON object {@code {"result": a + b}}.</li>
 * </ul>
 *
 * <h2>Running</h2>
 *
 * <pre>
 * # From the project root:
 * mvn -q exec:java -Dexec.mainClass=lingofuse.demo.EchoDemo
 *
 * # Or after `mvn package`:
 * java --enable-native-access=ALL-UNNAMED \
 *      -cp target/classes:target/dependency/* \
 *      lingofuse.demo.EchoDemo
 * </pre>
 *
 * <h2>Native library placement</h2>
 *
 * <p>The program requires {@code LingoFuse64.dll} (and its
 * dependencies {@code z_ipc_64.dll} and {@code mimalloc64.dll}) to be
 * discoverable. Place them next to the executable, in the current
 * working directory, on {@code java.library.path}, or on the system
 * {@code PATH}.
 */
public final class EchoDemo {

    private static final String ENDPOINT = "ipc:lingofuse_java_demo";
    private static final String APP_NAME = "EchoApp";
    private static final long CALL_TIMEOUT_MS = 3000L;

    private EchoDemo() {
        // Entry point; no instances.
    }

    public static void main(String[] args) {
        System.out.println("=== LingoFuse Java binding - Echo demo ===");
        System.out.println();

        AppHandle app = null;
        boolean started = false;

        try {
            // -----------------------------------------------------------------
            // 1. Deployment mode options.
            //
            // Wait_Connection_ReadyOk is left at its default (True) so
            // that prepareDone() blocks until the client is online.
            // Overlap_Connection is enabled so that the same endpoint
            // can host both the service and the client.
            // -----------------------------------------------------------------
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
            Framework.setOption("Wait_Connection_Timeout", "10000");

            Framework.resetPrepare();

            // -----------------------------------------------------------------
            // 2. Create the AppHandle and register the APIs.
            //
            // Registration MUST happen before prepareClient so that the
            // Init_App_Info broadcast carries the complete API list.
            // -----------------------------------------------------------------
            app = new AppHandle(APP_NAME, "Java demo echo service");

            boolean okEcho = app.registerCall("echo", "Echo a string",
                    (input, output) -> {
                        String s = LfIo.readString(input);
                        LfIo.writeString(output, s);
                    });
            if (!okEcho) {
                throw new IllegalStateException(
                        "Failed to register API 'echo'");
            }

            boolean okAdd = app.registerCall("add", "Add two integers",
                    (input, output) -> {
                        int a = input.readInt32();
                        int b = input.readInt32();
                        output.writeInt32(a + b);
                    });
            if (!okAdd) {
                throw new IllegalStateException(
                        "Failed to register API 'add'");
            }

            System.out.println("[Setup] Registered APIs 'echo' and 'add'.");

            // -----------------------------------------------------------------
            // 3. Prepare the service and the client.
            // -----------------------------------------------------------------
            int serviceTag = Framework.prepareService(ENDPOINT, ENDPOINT);
            if (serviceTag == -1) {
                throw new IllegalStateException(
                        "prepareService returned -1 for " + ENDPOINT);
            }

            int clientTag = Framework.prepareClient(ENDPOINT, app);
            if (clientTag == -1) {
                throw new IllegalStateException(
                        "prepareClient returned -1 for " + ENDPOINT);
            }

            System.out.println("[Setup] Service and client prepared on "
                    + ENDPOINT + ".");

            // -----------------------------------------------------------------
            // 4. Start the framework.
            // -----------------------------------------------------------------
            int done = Framework.prepareDone();
            if (done != 1 && !LingoFuseStatus.checkMainThread()) {
                throw new IllegalStateException(
                        "prepareDone returned " + done
                                + " and the main thread is not running.");
            }

            started = true;
            System.out.println("[Setup] Framework started.");

            // -----------------------------------------------------------------
            // 5. Wait for the app to become visible on the mesh.
            //
            // The mesh discovers applications via broadcast with a
            // typical propagation delay of about 3 seconds. Retry for
            // up to 10 seconds.
            // -----------------------------------------------------------------
            boolean visible = false;
            for (int i = 0; i < 50; i++) {
                if (LingoFuseStatus.checkApi(APP_NAME, "echo")) {
                    visible = true;
                    break;
                }
                try {
                    Thread.sleep(200);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
            if (!visible) {
                System.out.println(
                        "[Warn] App did not become visible within 10 seconds.");
            } else {
                System.out.println("[Setup] App '" + APP_NAME
                        + "' is visible on the mesh.");
            }

            // -----------------------------------------------------------------
            // 6. Exercise the registered APIs.
            // -----------------------------------------------------------------
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
            System.exit(1);
        } finally {
            // -----------------------------------------------------------------
            // 7. Clean shutdown.
            //
            // The order matches the documented LF-CLEAN-001 contract:
            //   NetworkEvents.clear() -> Framework.exitMainThread()
            //   -> app.close() -> Framework.shutdown()
            //
            // Every call is idempotent, so this block is safe to run
            // even on partial-init paths.
            // -----------------------------------------------------------------
            System.out.println();
            System.out.println("[Cleanup] Shutting down...");
            try {
                lingofuse.NetworkEvents.clear();
            } catch (Throwable ignored) {
                // Not fatal; continue with the rest of the sequence.
            }
            try {
                if (started) {
                    Framework.exitMainThread();
                }
            } catch (Throwable t) {
                System.err.println("[Cleanup] exitMainThread failed: " + t);
            }
            try {
                if (app != null) {
                    app.close();
                }
            } catch (Throwable t) {
                System.err.println("[Cleanup] app.close failed: " + t);
            }
            try {
                if (started) {
                    Framework.shutdown();
                }
            } catch (Throwable t) {
                System.err.println("[Cleanup] shutdown failed: " + t);
            }
            System.out.println("[Cleanup] Done.");
        }
    }

    // ------------------------------------------------------------------
    // Demonstration routines
    // ------------------------------------------------------------------

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