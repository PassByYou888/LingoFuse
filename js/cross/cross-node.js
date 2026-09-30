"use strict";

// =============================================================================
//  cross-node.js
// -----------------------------------------------------------------------------
//  Worker node that registers the "add" and "inv_seri" Call APIs.
//
//  JavaScript port of the C++ CrossNode.cpp / C# CrossNode.cs /
//  Pascal cross_node.lpr demo. Wire format is byte-for-byte identical
//  to every other LingoFuse binding:
//
//    add       (int32 a, int32 b)                       -> int32
//        Reads two 32-bit signed integers (little-endian) and writes
//        their sum.
//
//    inv_seri  (uint8, uint16, uint32, uint64,
//               string(NUL), float)                      -> same types reversed
//        Reads a fixed sequence of typed values and echoes them back
//        in reverse order. Used to exercise the binary wire format.
//
//  A JavaScript CrossNode is directly interoperable with a C++ /
//  C# / Pascal / Python CrossCall client, and vice versa.
//
//  Startup:
//      1. Start the coordinator first (cross-service.js or the C++
//         / C# / Pascal equivalent).
//      2. Run this script. It connects as a client, exposes "demo",
//         and waits for Enter.
//      3. Run one or more callers (cross-call.js or the other
//         language equivalents).
//
//  The two APIs MUST be registered before prepareClient because the
//  Init_App_Info broadcast carries the API list as a snapshot.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      NetworkEvents.Clear -> ExitMainThread -> App.Dispose -> Shutdown
//
//  Run:
//      node cross-node.js
// =============================================================================

const readline = require("node:readline");

const lf = require("../index.js");

// -----------------------------------------------------------------------------
//  Configuration (must match the other language demos)
// -----------------------------------------------------------------------------

const ENDPOINT = "ipc:cross";
const APP_NAME = "demo";

// -----------------------------------------------------------------------------
//  Helpers
// -----------------------------------------------------------------------------

/**
 * Block until the user presses Enter.
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

/**
 * Format a float the way C++ std::ostream does by default: six
 * significant digits, no trailing zeros. Keeps the demo output
 * readable and close to what the C++ counterpart prints.
 *
 * @param {number} v
 * @returns {number}
 */
function formatFloat(v) {
    return Number.parseFloat(Number(v).toPrecision(6));
}

// -----------------------------------------------------------------------------
//  Callbacks
// -----------------------------------------------------------------------------
//  Callbacks run on a native worker thread (the Koffi bridge serialises
//  them onto the JS event loop, so they cannot interleave with each
//  other). Inside a callback:
//      - DO NOT block.
//      - DO NOT call LF_Call / LF_Notify / LF_LocalCall (deadlock).
//      - DO NOT dispose the borrowed input / output handles.
// =============================================================================

/**
 * add(int32, int32) -> int32
 *
 * @param {lf.DataHandle} input   Borrowed input handle.
 * @param {lf.DataHandle} output  Borrowed output handle.
 */
function handleAdd(input, output) {
    const a = input.readInt32();
    const b = input.readInt32();
    const c = a + b;

    console.log(`[Node] add(${a}, ${b}) = ${c}`);

    output.writeInt32(c);
}

/**
 * inv_seri(uint8, uint16, uint32, uint64, string, float)
 *   -> reversed typed sequence
 *
 * @param {lf.DataHandle} input   Borrowed input handle.
 * @param {lf.DataHandle} output  Borrowed output handle.
 */
function handleInvSeri(input, output) {
    const b = input.readUInt8();
    const w = input.readUInt16();
    const c = input.readUInt32();
    const u64 = input.readUInt64();     // BigInt
    const s = input.readString();
    const f = input.readSingle();

    console.log(
        `[Node] inv_seri received: [${b}, ${w}, ${c}, ${u64}, "${s}", ${formatFloat(f)}]`);

    // Reply in the reverse field order, matching CrossNode.cpp.
    output.writeSingle(f);
    output.writeString(s);
    output.writeUInt64(u64);
    output.writeUInt32(c);
    output.writeUInt16(w);
    output.writeUInt8(b);

    console.log(
        `[Node] inv_seri replied:  [${formatFloat(f)}, "${s}", ${u64}, ${c}, ${w}, ${b}]`);
}

// -----------------------------------------------------------------------------
//  Main
// -----------------------------------------------------------------------------

async function main() {
    console.log("=== Cross Node (Worker) ===");

    let started = false;
    let app = null;

    try {
        lf.loadLibrary();

        // Deployment mode: do not block PrepareDone waiting for the
        // service endpoint. The node can start before the coordinator;
        // it will connect automatically once the endpoint is reachable.
        lf.framework.setOption("Wait_Ready", "False");
        lf.framework.setOption("Overlap_Connection", "True");

        lf.framework.resetPrepare();

        // 1. Create the application and register the two Call APIs.
        //    Both registrations MUST complete before prepareClient,
        //    because the Init_App_Info broadcast carries the API list
        //    as a snapshot.
        app = new lf.AppHandle(APP_NAME, "JavaScript worker node");

        if (!app.registerCall(
            "add",
            "add(int a, int b) -> int",
            handleAdd)) {
            console.error("[FATAL] Failed to register API 'add'.");
            return 1;
        }

        if (!app.registerCall(
            "inv_seri",
            "inv_seri() -> reversed typed sequence",
            handleInvSeri)) {
            console.error("[FATAL] Failed to register API 'inv_seri'.");
            return 1;
        }

        // 2. Connect to the coordinator as a client and expose "demo".
        const clientTag = lf.framework.prepareClient(ENDPOINT, app);
        if (clientTag < 0) {
            console.error(
                `[FATAL] LF_PrepareClient returned ${clientTag} for ${ENDPOINT}.`);
            return 1;
        }

        // 3. Start the framework.
        const done = lf.framework.prepareDone();
        if (done !== 1 && !lf.status.checkMainThread()) {
            console.error(
                `[FATAL] LF_PrepareDone returned ${done} and the main thread is not running.`);
            return 1;
        }

        started = true;
        console.log(
            `[Node] Registered APIs 'add' and 'inv_seri' under application '${APP_NAME}'.`);
        console.log("[Node] Online. Press Enter to exit...");

        await waitForEnter();

        console.log("[Node] Shutting down...");
    }
    catch (err) {
        const detail = err instanceof Error
            ? err.stack ?? err.message
            : String(err);
        console.error(`[FATAL] ${detail}`);
        return 1;
    }
    finally {
        // LF-CLEAN-001 sequence. Every operation is idempotent, so
        // calling them unconditionally is safe even if startup failed
        // partway through.
        try { lf.network.clearNetworkEvent(); } catch { /* ignore */ }
        try { lf.framework.exitMainThread(); } catch { /* ignore */ }
        try { if (app !== null) app.dispose(); } catch { /* ignore */ }
        try { lf.framework.shutdown(); } catch { /* ignore */ }
    }

    console.log("[Node] Bye.");
    return 0;
}

// -----------------------------------------------------------------------------
//  Entry point
// -----------------------------------------------------------------------------

main().then((code) => {
    process.exitCode = code;
});