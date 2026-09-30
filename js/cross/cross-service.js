"use strict";

// =============================================================================
//  cross-service.js
// -----------------------------------------------------------------------------
//  Coordinator process for the IPC endpoint "ipc:cross".
//
//  JavaScript port of the C++ CrossService.cpp / C# CrossService.cs /
//  Pascal cross_service.lpr demo. Behaviour is identical:
//
//    1. Load the native LingoFuse library (lazily, via Koffi).
//    2. Configure the same deployment options as the other languages.
//    3. Create the IPC service endpoint "ipc:cross".
//    4. Prepare a self-connected client so the C4 mesh has at least
//       one physical tunnel to anchor the broadcast loop.
//    5. Start the framework (LF_PrepareDone).
//    6. Wait for Enter.
//    7. Shut down in the LF-CLEAN-001 order.
//
//  Any mix of language runtimes (C++ / C# / Pascal / Python / JS) can
//  participate in the same mesh because the endpoint name, the options,
//  and the shutdown sequence all match.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      NetworkEvents.Clear -> ExitMainThread -> Shutdown
//
//  All operations are idempotent, so the cleanup runs on every exit
//  path (normal return, early return, or exception).
//
//  Run:
//      node cross-service.js
// =============================================================================

const readline = require("node:readline");

const lf = require("../index.js");

// -----------------------------------------------------------------------------
//  Configuration (must match the other language demos)
// -----------------------------------------------------------------------------

const ENDPOINT = "ipc:cross";

// -----------------------------------------------------------------------------
//  Helpers
// -----------------------------------------------------------------------------

/**
 * Block until the user presses Enter.
 *
 * readline is used rather than a raw process.stdin 'data' listener so
 * that the TTY line discipline, echo, and process exit behaviour are
 * handled consistently across Node.js, Deno, and Bun.
 *
 * @returns {Promise<void>}
 */
function waitForEnter() {
    return new Promise((resolve) => {
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout,
        });
        rl.question("", () => {
            rl.close();
            process.stdin.pause();
            resolve();
        });
    });
}

// -----------------------------------------------------------------------------
//  Main
// -----------------------------------------------------------------------------

async function main() {
    console.log("=== Cross Service (Coordinator) ===");

    let started = false;

    try {
        // Eagerly load the native library so that a missing-library
        // error surfaces here, at a well-defined point, instead of at
        // the first unrelated native call.
        lf.loadLibrary();

        // Deployment options, identical to the C++ / C# / Pascal demos.
        lf.framework.setOption("Wait_Connection_ReadyOk", "True");
        lf.framework.setOption("Overlap_Connection", "True");
        lf.framework.setOption("Wait_Connection_Timeout", "10000");

        lf.framework.resetPrepare();

        // 1. Create the IPC service endpoint.
        const serviceTag = lf.framework.prepareService(ENDPOINT, ENDPOINT);
        if (serviceTag < 0) {
            console.error(
                `[FATAL] LF_PrepareService returned ${serviceTag} for ${ENDPOINT}.`);
            return 1;
        }
        console.log(
            `[Service] Prepared service endpoint ${ENDPOINT} (tag=${serviceTag}).`);

        // 2. Prepare a client with no application. This gives the mesh
        //    at least one physical tunnel at the coordinator itself,
        //    which the C4 broadcast loop needs in order to make the
        //    endpoint reachable by other processes.
        const clientTag = lf.framework.prepareClient(ENDPOINT, null);
        if (clientTag < 0) {
            console.error(
                `[FATAL] LF_PrepareClient returned ${clientTag} for ${ENDPOINT}.`);
            return 1;
        }
        console.log(
            `[Service] Prepared client tunnel (tag=${clientTag}).`);

        // 3. Start the framework. LF_PrepareDone returns 1 on the first
        //    successful call. A subsequent call in the same process
        //    without an intervening shutdown returns 0 (not a failure).
        const done = lf.framework.prepareDone();
        if (done !== 1 && !lf.status.checkMainThread()) {
            console.error(
                `[FATAL] LF_PrepareDone returned ${done} and the main thread is not running.`);
            return 1;
        }

        started = true;
        console.log(
            `[Service] IPC service '${ENDPOINT}' is running. Press Enter to exit...`);

        // 4. Idle until the user presses Enter.
        await waitForEnter();

        console.log("[Service] Shutting down...");
    }
    catch (err) {
        const detail = err instanceof Error
            ? err.stack ?? err.message
            : String(err);
        console.error(`[FATAL] ${detail}`);
        return 1;
    }
    finally {
        if (started) {
            // LF-CLEAN-001 sequence. Every operation is idempotent.
            try { lf.network.clearNetworkEvent(); } catch { /* ignore */ }
            try { lf.framework.exitMainThread(); } catch { /* ignore */ }
            try { lf.framework.shutdown(); } catch { /* ignore */ }
        }
    }

    console.log("[Service] Bye.");
    return 0;
}

// -----------------------------------------------------------------------------
//  Entry point
// -----------------------------------------------------------------------------

main().then((code) => {
    process.exitCode = code;
});