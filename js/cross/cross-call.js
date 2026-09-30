"use strict";

// =============================================================================
//  cross-call.js
// -----------------------------------------------------------------------------
//  Load tester for the "ipc:cross" endpoint.
//
//  JavaScript port of the C++ CrossCall.cpp / C# CrossCall.cs /
//  Pascal cross_call.lpr demo. It connects as a pure consumer (no
//  application is exposed) and repeatedly invokes one of two remote
//  APIs on the "demo" application at random:
//
//    add       (int32 a, int32 b)                       -> int32
//    inv_seri  (uint8, uint16, uint32, uint64,
//               string(NUL), float)                      -> reversed types
//
//  Both APIs use the raw ABI channel. No JSON is involved at any
//  point. Every byte written matches what the C++ / C# / Pascal /
//  Python clients write for the same logical call, so this script can
//  drive a node written in any of those languages.
//
//  Concurrency note:
//      Node.js is single-threaded at the JavaScript level, so this
//      script issues sequential calls rather than the C++ version's
//      32 concurrent worker threads. To drive higher load, launch
//      several instances of this script in parallel from separate
//      terminals. The raw ABI channel is still exercised end to end.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      NetworkEvents.Clear -> ExitMainThread -> Shutdown
//
//  Run (one or more instances in parallel):
//      node cross-call.js
// =============================================================================

const readline = require("node:readline");

const lf = require("../index.js");

// -----------------------------------------------------------------------------
//  Configuration (must match the other language demos)
// -----------------------------------------------------------------------------

const TARGET_APP = "demo";
const ENDPOINT = "ipc:cross";

const TEST_SECONDS = 10;          // total load-test duration
const CALL_TIMEOUT_MS = 1000;     // per-call timeout
const PAUSE_MS = 1;               // pause between iterations

// Log one iteration out of every N. With thousands of calls per second,
// printing every call would make the log I/O itself the bottleneck.
// The Stats counters remain exact regardless of N.
const LOG_EVERY_NTH_CALL = 5000;

const NUMBER_MIN = 1;
const NUMBER_MAX = 1000;

// -----------------------------------------------------------------------------
//  Statistics
// -----------------------------------------------------------------------------

class Stats {
    constructor() {
        this.totalCalls = 0;
        this.successCalls = 0;
        this.failedCalls = 0;
        this.addCalls = 0;
        this.invSeriCalls = 0;
    }
}

// -----------------------------------------------------------------------------
//  Helpers
// -----------------------------------------------------------------------------

/**
 * Promise-based sleep.
 *
 * @param {number} ms
 * @returns {Promise<void>}
 */
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Format a float the way C++ std::ostream does by default.
 *
 * @param {number} v
 * @returns {number}
 */
function formatFloat(v) {
    return Number.parseFloat(Number(v).toPrecision(6));
}

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

// -----------------------------------------------------------------------------
//  Remote call wrappers
// -----------------------------------------------------------------------------

/**
 * Invoke the remote "add" API via the raw ABI channel.
 *
 * Request : int32 (little-endian) + int32 (little-endian)
 * Reply   : int32 (little-endian)
 *
 * @param {number} a
 * @param {number} b
 * @returns {number|null}  The sum, or null on timeout / failure.
 */
function remoteAdd(a, b) {
    const param = new lf.DataHandle("add");
    try {
        param.writeInt32(a);
        param.writeInt32(b);

        const response = lf.framework.call(
            TARGET_APP, param, CALL_TIMEOUT_MS);
        try {
            if (response.size < 4) {
                return null;
            }
            return response.readInt32();
        }
        finally {
            response.dispose();
        }
    }
    catch (err) {
        return null;
    }
    finally {
        param.dispose();
    }
}

/**
 * Invoke the remote "inv_seri" API via the raw ABI channel.
 *
 * Request : uint8, uint16, uint32, uint64, string(NUL), float
 * Reply   : float, string(NUL), uint64, uint32, uint16, uint8
 *
 * All integer types are little-endian. The string is UTF-8, NUL-
 * terminated. This matches CrossCall.cpp and CrossCall.cs exactly.
 *
 * @returns {string|null}  A formatted reply, or null on failure.
 */
function remoteInvSeri() {
    // Same constants as the C++ / C# / Pascal counterparts.
    const b = 200;
    const w = 0x10;
    const c = 0x2F;
    const u64 = 0x3Fn;              // BigInt literal for the uint64 field
    const s = "hello world";
    const f = 3.14;

    const param = new lf.DataHandle("inv_seri");
    try {
        param.writeUInt8(b);
        param.writeUInt16(w);
        param.writeUInt32(c);
        param.writeUInt64(u64);
        param.writeString(s);
        param.writeSingle(f);

        const response = lf.framework.call(
            TARGET_APP, param, CALL_TIMEOUT_MS);
        try {
            if (response.size === 0) {
                return null;
            }

            // Read the reply fields in the reverse order the node
            // wrote them.
            const rf = response.readSingle();
            const rs = response.readString();
            const ru64 = response.readUInt64();
            const rc = response.readUInt32();
            const rw = response.readUInt16();
            const rb = response.readUInt8();

            return `reply: [${rb}, ${rw}, ${rc}, ${ru64}, "${rs}", ${formatFloat(rf)}]`
                + `  original: [${b}, ${w}, ${c}, ${u64}, "${s}", ${formatFloat(f)}]`;
        }
        finally {
            response.dispose();
        }
    }
    catch (err) {
        return null;
    }
    finally {
        param.dispose();
    }
}

// -----------------------------------------------------------------------------
//  Main
// -----------------------------------------------------------------------------

async function main() {
    console.log("=== Cross Call (Client) ===");

    let started = false;

    try {
        lf.loadLibrary();

        lf.framework.setOption("Wait_Connection_ReadyOk", "True");
        lf.framework.setOption("Overlap_Connection", "True");
        lf.framework.setOption("Wait_Connection_Timeout", "10000");

        lf.framework.resetPrepare();

        // Pure consumer: no application is exposed.
        const clientTag = lf.framework.prepareClient(ENDPOINT, null);
        if (clientTag < 0) {
            console.error(
                `[FATAL] LF_PrepareClient returned ${clientTag} for ${ENDPOINT}.`);
            return 1;
        }

        const done = lf.framework.prepareDone();
        if (done !== 1 && !lf.status.checkMainThread()) {
            console.error(
                `[FATAL] LF_PrepareDone returned ${done} and the main thread is not running.`);
            return 1;
        }

        started = true;
        console.log(
            `[Call] Connected to ${ENDPOINT}. Starting ${TEST_SECONDS}-second load test...`);

        const stats = new Stats();
        const startTime = Date.now();
        const deadline = startTime + TEST_SECONDS * 1000;
        let iter = 0;

        while (Date.now() < deadline) {
            iter += 1;
            const doLog = (iter % LOG_EVERY_NTH_CALL === 0);

            if (Math.random() < 0.5) {
                // ---- add ----
                const a = NUMBER_MIN + Math.floor(
                    Math.random() * (NUMBER_MAX - NUMBER_MIN + 1));
                const b = NUMBER_MIN + Math.floor(
                    Math.random() * (NUMBER_MAX - NUMBER_MIN + 1));
                const result = remoteAdd(a, b);

                stats.totalCalls += 1;
                stats.addCalls += 1;

                if (result !== null) {
                    stats.successCalls += 1;
                    if (doLog) {
                        console.log(`[Call 0] add(${a}, ${b}) = ${result}`);
                    }
                }
                else {
                    stats.failedCalls += 1;
                    if (doLog) {
                        console.log(
                            `[Call 0] add(${a}, ${b}) timed out or failed.`);
                    }
                }
            }
            else {
                // ---- inv_seri ----
                const result = remoteInvSeri();

                stats.totalCalls += 1;
                stats.invSeriCalls += 1;

                if (result !== null) {
                    stats.successCalls += 1;
                    if (doLog) {
                        console.log(`[Call 0] ${result}`);
                    }
                }
                else {
                    stats.failedCalls += 1;
                    if (doLog) {
                        console.log(`[Call 0] inv_seri timed out or failed.`);
                    }
                }
            }

            if (PAUSE_MS > 0) {
                await sleep(PAUSE_MS);
            }
        }

        const elapsedS = (Date.now() - startTime) / 1000;
        const successRate = stats.totalCalls > 0
            ? 100.0 * stats.successCalls / stats.totalCalls
            : 0.0;
        const throughput = elapsedS > 0
            ? stats.totalCalls / elapsedS
            : 0.0;
        const successThroughput = elapsedS > 0
            ? stats.successCalls / elapsedS
            : 0.0;

        console.log();
        console.log("[Call] Load test summary");
        console.log(`         duration          : ${elapsedS.toFixed(3)} s`);
        console.log(`         total calls       : ${stats.totalCalls}`);
        console.log(
            `         success           : ${stats.successCalls} (${successRate.toFixed(2)} %)`);
        console.log(`         failed            : ${stats.failedCalls}`);
        console.log(`         add calls         : ${stats.addCalls}`);
        console.log(`         inv_seri calls    : ${stats.invSeriCalls}`);
        console.log(
            `         throughput        : ${throughput.toFixed(2)} calls/s`);
        console.log(
            `         success throughput: ${successThroughput.toFixed(2)} calls/s`);

        console.log("[Call] Press Enter to exit...");
        await waitForEnter();
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

    console.log("[Call] Bye.");
    return 0;
}

// -----------------------------------------------------------------------------
//  Entry point
// -----------------------------------------------------------------------------

main().then((code) => {
    process.exitCode = code;
});