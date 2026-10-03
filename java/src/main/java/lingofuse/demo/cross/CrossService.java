package lingofuse.demo.cross;

import lingofuse.Framework;
import lingofuse.LingoFuseStatus;
import lingofuse.NetworkEvents;

/**
 * Coordinator process for the IPC endpoint {@code ipc:cross}.
 *
 * <p>This program:
 * <ol>
 *   <li>Creates the IPC service endpoint {@code ipc:cross}.</li>
 *   <li>Prepares a client on the same endpoint (pure consumer, no
 *       application).</li>
 *   <li>Starts the framework.</li>
 *   <li>Waits for the user to press Enter.</li>
 *   <li>Performs a clean shutdown in the LF-CLEAN-001 order:
 *       {@code NetworkEvents.clear -> Framework.exitMainThread
 *       -> Framework.shutdown}.</li>
 * </ol>
 *
 * <p>It does NOT register any API and does NOT act as a caller. Its
 * sole purpose is to act as the discovery/anchor endpoint that worker
 * nodes and callers connect to.
 *
 * <h2>Running</h2>
 *
 * <pre>
 * mvn -q exec:java -Dexec.mainClass=lingofuse.demo.cross.CrossService
 * </pre>
 *
 * <p>Or after {@code mvn package}:
 *
 * <pre>
 * java --enable-native-access=ALL-UNNAMED \
 *      -cp target/classes:target/dependency/* \
 *      lingofuse.demo.cross.CrossService
 * </pre>
 *
 * <p>Start this process first. Then start one or more
 * {@code CrossNode} processes, then start one or more
 * {@code CrossCall} processes.
 */
public final class CrossService {

    /** The shared IPC endpoint used by all three programs. */
    public static final String ENDPOINT = "ipc:cross";

    private CrossService() {
        // Entry point; no instances.
    }

    public static void main(String[] args) {
        System.out.println("=== Cross Service (Coordinator) ===");
        System.out.println();

        boolean started = false;

        try {
            // -----------------------------------------------------------------
            // Deployment options.
            //
            // Wait_Connection_ReadyOk is True so that prepareDone() blocks
            // until the internal client is actually online. The default
            // 30-second timeout is reduced to 10 seconds so the demo
            // stays responsive if something is genuinely wrong.
            // -----------------------------------------------------------------
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
            Framework.setOption("Wait_Connection_Timeout", "10000");

            Framework.resetPrepare();

            // -----------------------------------------------------------------
            // Service side.
            // -----------------------------------------------------------------
            int serviceTag = Framework.prepareService(ENDPOINT, ENDPOINT);
            if (serviceTag == -1) {
                System.err.println(
                        "[FATAL] prepareService returned -1 for " + ENDPOINT);
                return;
            }

            // -----------------------------------------------------------------
            // Client side: a pure consumer, no application attached.
            // This gives the mesh at least one physical tunnel at the
            // coordinator itself.
            // -----------------------------------------------------------------
            int clientTag = Framework.prepareClient(ENDPOINT, null);
            if (clientTag == -1) {
                System.err.println(
                        "[FATAL] prepareClient returned -1 for " + ENDPOINT);
                return;
            }

            // -----------------------------------------------------------------
            // Start the framework.
            // -----------------------------------------------------------------
            int done = Framework.prepareDone();
            if (done != 1 && !LingoFuseStatus.checkMainThread()) {
                System.err.println(
                        "[FATAL] prepareDone returned " + done
                                + " and the main thread is not running.");
                return;
            }

            started = true;

            System.out.println("IPC service '" + ENDPOINT
                    + "' is running. Press Enter to exit...");
            // Wait for user input.
            System.in.read();

            System.out.println("Shutting down...");

        } catch (Throwable t) {
            System.err.println("[FATAL] "
                    + t.getClass().getSimpleName() + ": " + t.getMessage());
            t.printStackTrace(System.err);
            System.exit(1);
        } finally {
            // -----------------------------------------------------------------
            // Clean shutdown on every exit path.
            //
            // The order matches the documented LF-CLEAN-001 contract:
            //   NetworkEvents.clear() -> Framework.exitMainThread()
            //   -> Framework.shutdown()
            //
            // Every call is idempotent, so this block is safe even when
            // the startup sequence failed partway through.
            // -----------------------------------------------------------------
            if (started) {
                try {
                    NetworkEvents.clear();
                } catch (Throwable ignored) {
                }
                try {
                    Framework.exitMainThread();
                } catch (Throwable ignored) {
                }
                try {
                    Framework.shutdown();
                } catch (Throwable ignored) {
                }
            }
        }

        System.out.println("Bye.");
    }
}