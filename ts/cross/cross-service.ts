// =============================================================================
//  cross/cross-service.ts
// -----------------------------------------------------------------------------
//  Coordinator process for the IPC endpoint "ipc:cross".
//
//  TypeScript port of the C++ CrossService.cpp / C# CrossService.cs /
//  Pascal cross_service.lpr / JavaScript cross-service.js demo.
//
//  Behaviour:
//      1. Load the native LingoFuse library (lazily, via Koffi).
//      2. Configure the same deployment options as the other languages.
//      3. Create the IPC service endpoint "ipc:cross".
//      4. Prepare a self-connected client so the C4 mesh has at least
//         one physical tunnel to anchor the broadcast loop.
//      5. Start the framework (LF_PrepareDone).
//      6. Wait for Enter.
//      7. Shut down in the LF-CLEAN-001 order.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      NetworkEvents.Clear -> ExitMainThread -> Shutdown
//
//  Run:
//      npx tsx cross/cross-service.ts
//      bun run cross/cross-service.ts
//      deno run --allow-ffi --allow-read --allow-env --allow-net --allow-sys \
//          cross/cross-service.ts
// =============================================================================

import * as readline from "node:readline";
import * as lf from "../src/index";

// -----------------------------------------------------------------------------
//  Configuration (must match the other language demos)
// -----------------------------------------------------------------------------

const ENDPOINT = "ipc:cross";

// -----------------------------------------------------------------------------
//  Helpers
// -----------------------------------------------------------------------------

function waitForEnter(): Promise<void> {
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

async function main(): Promise<number> {
    console.log("=== Cross Service (Coordinator) ===");

    let started = false;

    try {
        lf.loadLibrary();

        lf.framework.setOption(lf.Option.WAIT_CONNECTION_READY_OK, lf.bool(true));
        lf.framework.setOption(lf.Option.OVERLAP_CONNECTION, lf.bool(true));
        lf.framework.setOption(lf.Option.WAIT_CONNECTION_TIMEOUT, "10000");

        lf.framework.resetPrepare();

        const serviceTag = lf.framework.prepareService(ENDPOINT, ENDPOINT);
        if (serviceTag < 0) {
            console.error(
                `[FATAL] LF_PrepareService returned ${serviceTag} for ${ENDPOINT}.`);
            return 1;
        }
        console.log(
            `[Service] Prepared service endpoint ${ENDPOINT} (tag=${serviceTag}).`);

        const clientTag = lf.framework.prepareClient(ENDPOINT, null);
        if (clientTag < 0) {
            console.error(
                `[FATAL] LF_PrepareClient returned ${clientTag} for ${ENDPOINT}.`);
            return 1;
        }
        console.log(`[Service] Prepared client tunnel (tag=${clientTag}).`);

        const done = lf.framework.prepareDone();
        if (done !== 1 && !lf.status.checkMainThread()) {
            console.error(
                `[FATAL] LF_PrepareDone returned ${done} and the main thread is not running.`);
            return 1;
        }

        started = true;
        console.log(
            `[Service] IPC service '${ENDPOINT}' is running. Press Enter to exit...`);

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
            try { lf.network.clearNetworkEvent(); } catch { /* ignore */ }
            try { lf.framework.exitMainThread(); } catch { /* ignore */ }
            try { lf.framework.shutdown(); } catch { /* ignore */ }
        }
    }

    console.log("[Service] Bye.");
    return 0;
}

main().then((code) => {
    process.exitCode = code;
});