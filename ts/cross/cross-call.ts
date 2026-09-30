// =============================================================================
//  cross/cross-call.ts
// -----------------------------------------------------------------------------
//  Load tester for the "ipc:cross" endpoint.
//
//  TypeScript port of the C++ CrossCall.cpp / C# CrossCall.cs /
//  Pascal cross_call.lpr / JavaScript cross-call.js demo. It connects
//  as a pure consumer (no application is exposed) and repeatedly
//  invokes one of two remote APIs on the "demo" application at random:
//
//    add       (int32 a, int32 b)                       -> int32
//    inv_seri  (uint8, uint16, uint32, uint64,
//               string(NUL), float)                      -> reversed types
//
//  Both APIs use the raw ABI channel. No JSON is involved at any point.
//  Every byte written matches what the C++ / C# / Pascal / Python /
//  JavaScript clients write for the same logical call, so this script
//  can drive a node written in any of those languages.
//
//  Concurrency note:
//      Node.js is single-threaded at the JavaScript level, so this
//      script issues sequential calls rather than the C++ version's
//      32 concurrent worker threads. To drive higher load, launch
//      several instances in parallel from separate terminals.
//
//  Cleanup order (matching Pascal LF-CLEAN-001):
//      NetworkEvents.Clear -> ExitMainThread -> Shutdown
//
//  Run:
//      npx tsx cross/cross-call.ts
//      bun run cross/cross-call.ts
//      deno run --allow-ffi --allow-read --allow-env --allow-net --allow-sys \
//          cross/cross-call.ts
// =============================================================================

import * as readline from "node:readline";
import * as lf from "../src/index";
import { DataHandle } from "../src/index";

// -----------------------------------------------------------------------------
//  Configuration (must match the other language demos)
// -----------------------------------------------------------------------------

const TARGET_APP = "demo";
const ENDPOINT = "ipc:cross";

const TEST_SECONDS = 10;
const CALL_TIMEOUT_MS = 1000;
const PAUSE_MS = 1;

const LOG_EVERY_NTH_CALL = 5000;

const NUMBER_MIN = 1;
const NUMBER_MAX = 1000;

// -----------------------------------------------------------------------------
//  Statistics
// -----------------------------------------------------------------------------

interface Stats {
    totalCalls: number;
    successCalls: number;
    failedCalls: number;
    addCalls: number;
    invSeriCalls: number;
}

function newStats(): Stats {
    return {
        totalCalls: 0,
        successCalls: 0,
        failedCalls: 0,
        addCalls: 0,
        invSeriCalls: 0,
    };
}

// -----------------------------------------------------------------------------
//  Helpers
// -----------------------------------------------------------------------------

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function formatFloat(v: number): number {
    return Number.parseFloat(Number(v).toPrecision(6));
}

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
//  Remote call wrappers
// -----------------------------------------------------------------------------

/**
 * Invoke the remote "add" API via the raw ABI channel.
 *
 * Request : int32 (little-endian) + int32 (little-endian)
 * Reply   : int32 (little-endian)
 */
function remoteAdd(a: number, b: number): number | null {
    const param = new DataHandle("add");
    try {
        param.writeInt32(a);
        param.writeInt32(b);

        const response = lf.framework.call(TARGET_APP, param, CALL_TIMEOUT_MS);
        try {
            if (response.size < 4) return null;
            return response.readInt32();
        }
        finally {
            response.dispose();
        }
    }
    catch {
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
 */
function remoteInvSeri(): string | null {
    const b = 200;
    const w = 0x10;
    const c = 0x2F;
    const u64 = 0x3Fn;
    const s = "hello world";
    const f = 3.14;

    const param = new DataHandle("inv_seri");
    try {
        param.writeUInt8(b);
        param.writeUInt16(w);
        param.writeUInt32(c);
        param.writeUInt64(u64);
        param.writeString(s);
        param.writeSingle(f);

        const response = lf.framework.call(TARGET_APP, param, CALL_TIMEOUT_MS);
        try {
            if (response.size === 0) return null;

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
    catch {
        return null;
    }
    finally {
        param.dispose();
    }
}

// -----------------------------------------------------------------------------
//  Main
// -----------------------------------------------------------------------------

async function main(): Promise<number> {
    console.log("=== Cross Call (Client) ===");

    let started = false;

    try {
        lf.loadLibrary();

        lf.framework.setOption(lf.Option.WAIT_CONNECTION_READY_OK, lf.bool(true));
        lf.framework.setOption(lf.Option.OVERLAP_CONNECTION, lf.bool(true));
        lf.framework.setOption(lf.Option.WAIT_CONNECTION_TIMEOUT, "10000");

        lf.framework.resetPrepare();

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

        const stats = newStats();
        const startTime = Date.now();
        const deadline = startTime + TEST_SECONDS * 1000;
        let iter = 0;

        while (Date.now() < deadline) {
            iter += 1;
            const doLog = (iter % LOG_EVERY_NTH_CALL === 0);

            if (Math.random() < 0.5) {
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
        const throughput = elapsedS > 0 ? stats.totalCalls / elapsedS : 0.0;
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

main().then((code) => {
    process.exitCode = code;
});