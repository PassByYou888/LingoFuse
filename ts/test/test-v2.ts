// =============================================================================
//  test/test-v2.ts
// -----------------------------------------------------------------------------
//  v2.0 test suite for the LingoFuse TypeScript binding.
//
//  This file covers ONLY the v2.0 additions. The v1.0 baseline suite
//  remains in test.ts and is expected to keep passing unchanged.
//
//  Coverage:
//     1. errors-v2               the 2 new exception types
//     2. CallPromise             Promise wrapper with abandoned flag
//     3. AsyncBridge             singleton lifecycle and stats
//     4. Targets                 AppTarget / UIDTarget / P2PNameTarget
//     5. options                 the 16 typed setter/getter pairs
//     6. framework.getOption     the raw option reader
//     7. DataHandle UID methods  writeUid / readUid / getP2PUid / getP2PName
//     8. p2p-registration        process-wide P2P registration helpers
//     9. status UID checks       checkUid / checkUidApi / checkP2PName*
//    10. Integration: call shapes       call / callAsync / callSync / tryCallSync
//    11. Integration: UIDTarget         real UID-routed invocation
//    12. Integration: side-data         getP2PUid / getP2PName inside callbacks
//
//  Runs on:
//      Node.js 18+ : npx tsx test/test-v2.ts
//      Bun 1.x+    : bun run test/test-v2.ts
//      Deno 2.x    : deno run --allow-ffi --allow-read --allow-env \
//                              --allow-net --allow-sys --allow-run \
//                              test/test-v2.ts
//
//  ============================================================================
//  THREE HARD CONSTRAINTS ENFORCED BY THIS SUITE
//  ============================================================================
//
//  [C1] NO DYNAMIC REGISTRATION AT TEST TIME
//       Every API is registered in the before() hook, before
//       prepareClient(). See the section "DYNAMIC REGISTRATION IS
//       INTENTIONALLY AVOIDED" below.
//
//  [C2] NO SIDE-EFFECTING debug COMMANDS
//       The setOptDebug test uses a no-op command name. The "service"
//       command creates a transient TC40_Console_Help object on the
//       native side that performs a live query of the C4 service pool;
//       that query can leave an asynchronous task pending when
//       LF_ExitMainThread runs, which causes the native cleanup phase
//       (C40Clean) to block forever, which in turn blocks the JS event
//       loop and prevents ANY JavaScript timer from firing.
//
//  [C3] DETACHED WATCHDOG PROCESS
//       Because a blocking native call freezes the entire JS event
//       loop, no in-process timer can rescue the run. The only
//       mechanism that survives a frozen event loop is an external
//       process that sends SIGKILL after a deadline. This suite
//       spawns such a watchdog when the runtime supports it.
//
//  ============================================================================
//  DYNAMIC REGISTRATION IS INTENTIONALLY AVOIDED
//  ============================================================================
//  Every API used by the test suite is registered in the before() hook,
//  which runs before LF_PrepareDone and before LF_PrepareClient. No test
//  registers an API at test time.
//
//  Why this matters:
//
//      app.registerCall(...) fires APP.DoChange, which schedules a
//      1-second timer. When the timer fires, Do_LFRegEvent is posted to
//      the native simulated main thread, which dispatches an
//      Init_App_Info broadcast to the service. If that broadcast is still
//      in flight when the after() hook calls LF_ExitMainThread, the
//      native main thread blocks inside C40Clean() waiting for the
//      broadcast to complete.
//
//  All code and status output are in English.
// =============================================================================

import { spawn, type ChildProcess } from "node:child_process";

import * as lf from "../src/index";
import { DataHandle } from "../src/index";

// =============================================================================
//  Section 0 -- External watchdog
// -----------------------------------------------------------------------------
//  A detached child process that SIGKILLs this process if it has not
//  exited within WATCHDOG_TIMEOUT_MS.
//
//  Why a child process, not a setTimeout:
//      If LF_ExitMainThread blocks the JS event loop, no timer inside
//      this process will ever fire. A child process has its own event
//      loop and can send a signal to this process at any time, even
//      while this process's event loop is completely frozen.
//
//  Set the environment variable LINGOFUSE_TEST_NO_WATCHDOG=1 to disable
//  the watchdog (useful when debugging the native shutdown path).
// =============================================================================

const WATCHDOG_TIMEOUT_MS = 90000;
const WATCHDOG_DISABLED =
    readEnv("LINGOFUSE_TEST_NO_WATCHDOG") === "1";

let _watchdog: ChildProcess | null = null;

function readEnv(name: string): string | undefined {
    const proc = (globalThis as {
        process?: { env?: Record<string, string | undefined> };
    }).process;
    return proc?.env?.[name];
}

function startWatchdog(): void {
    if (WATCHDOG_DISABLED) {
        console.error(
            "[watchdog] disabled by LINGOFUSE_TEST_NO_WATCHDOG=1");
        return;
    }

    const proc = (globalThis as {
        process?: { pid?: number; execPath?: string };
    }).process;
    if (proc?.pid === undefined || typeof proc.execPath !== "string") {
        // Deno and some embeddings do not expose a Node-shaped process.
        // The watchdog is a diagnostic, not a correctness requirement,
        // so skip it rather than fail the run.
        console.error("[watchdog] skipped: no compatible process object");
        return;
    }

    try {
        const script =
            `const ppid = ${proc.pid};` +
            `setTimeout(() => {` +
            `  try { process.kill(ppid, 'SIGKILL'); } catch (e) {}` +
            `}, ${WATCHDOG_TIMEOUT_MS});`;
        _watchdog = spawn(
            proc.execPath,
            ["-e", script],
            { detached: true, stdio: "ignore" },
        );
        _watchdog.unref();
        console.error(
            `[watchdog] armed: will SIGKILL this process after ` +
            `${WATCHDOG_TIMEOUT_MS}ms if it has not exited by then`);
    } catch (e) {
        console.error("[watchdog] failed to start:", e);
        _watchdog = null;
    }
}

function stopWatchdog(): void {
    if (_watchdog === null) return;
    try {
        _watchdog.kill();
    } catch {
        // ignore
    }
    _watchdog = null;
    console.error("[watchdog] disarmed");
}

// =============================================================================
//  Section 1 -- Minimal test harness (mirrors test.ts)
// =============================================================================

interface TestCase {
    readonly name: string;
    readonly fn: () => void | Promise<void>;
}

interface Suite {
    readonly name: string;
    readonly tests: TestCase[];
}

const SUITES: Suite[] = [];
let currentSuite: Suite | null = null;
let beforeAllFn: (() => void | Promise<void>) | null = null;
let afterAllFn: (() => void | Promise<void>) | null = null;

function describe(name: string, fn: () => void): void {
    const suite: Suite = { name, tests: [] };
    SUITES.push(suite);
    const previous = currentSuite;
    currentSuite = suite;
    try {
        fn();
    } finally {
        currentSuite = previous;
    }
}

function it(name: string, fn: () => void | Promise<void>): void {
    if (currentSuite === null) {
        throw new Error(`it() called outside describe(): ${name}`);
    }
    currentSuite.tests.push({ name, fn });
}

function before(fn: () => void | Promise<void>): void {
    if (beforeAllFn !== null) {
        throw new Error("before() may only be registered once.");
    }
    beforeAllFn = fn;
}

function after(fn: () => void | Promise<void>): void {
    if (afterAllFn !== null) {
        throw new Error("after() may only be registered once.");
    }
    afterAllFn = fn;
}

// =============================================================================
//  Section 2 -- Minimal assertion library
// =============================================================================

class AssertionError extends Error {
    public constructor(message: string) {
        super(message);
        this.name = "AssertionError";
    }
}

function formatValue(v: unknown): string {
    if (typeof v === "string") return JSON.stringify(v);
    if (typeof v === "bigint") return `${v}n`;
    if (v === null) return "null";
    if (v === undefined) return "undefined";
    if (v instanceof Uint8Array) {
        return `Uint8Array(${v.length})[${Array.from(v)
            .slice(0, 8)
            .map((b) => b.toString(16).padStart(2, "0"))
            .join(" ")}${v.length > 8 ? " ..." : ""}]`;
    }
    if (typeof v === "object") {
        try { return JSON.stringify(v); }
        catch { return String(v); }
    }
    return String(v);
}

function deepEqual(a: unknown, b: unknown): boolean {
    if (Object.is(a, b)) return true;
    if (a instanceof Uint8Array && b instanceof Uint8Array) {
        if (a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) {
            if (a[i] !== b[i]) return false;
        }
        return true;
    }
    if (typeof a !== typeof b) return false;
    if (a === null || b === null) return false;
    if (typeof a !== "object") return false;
    if (Array.isArray(a) !== Array.isArray(b)) return false;

    if (Array.isArray(a) && Array.isArray(b)) {
        if (a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) {
            if (!deepEqual(a[i], b[i])) return false;
        }
        return true;
    }

    const ka = Object.keys(a as object);
    const kb = Object.keys(b as object);
    if (ka.length !== kb.length) return false;
    for (const k of ka) {
        if (!Object.prototype.hasOwnProperty.call(b, k)) return false;
        if (!deepEqual(
            (a as Record<string, unknown>)[k],
            (b as Record<string, unknown>)[k],
        )) return false;
    }
    return true;
}

type Ctor = new (...args: never[]) => Error;

const assert = {
    ok(value: unknown, message?: string): void {
        if (!value) {
            throw new AssertionError(
                message ??
                    `Expected a truthy value but received ${formatValue(value)}.`);
        }
    },

    equal(actual: unknown, expected: unknown, message?: string): void {
        if (!Object.is(actual, expected)) {
            throw new AssertionError(
                message ??
                    `Expected ${formatValue(expected)} but received ${formatValue(actual)}.`);
        }
    },

    notEqual(actual: unknown, expected: unknown, message?: string): void {
        if (Object.is(actual, expected)) {
            throw new AssertionError(
                message ??
                    `Expected a value different from ${formatValue(expected)}.`);
        }
    },

    deepEqual(actual: unknown, expected: unknown, message?: string): void {
        if (!deepEqual(actual, expected)) {
            throw new AssertionError(
                message ??
                    `Deep equality failed.\n` +
                    `        actual  : ${formatValue(actual)}\n` +
                    `        expected: ${formatValue(expected)}`);
        }
    },

    throws(fn: () => void, expectedType?: Ctor, message?: string): void {
        let thrown: unknown = null;
        let didThrow = false;
        try {
            fn();
        } catch (err) {
            didThrow = true;
            thrown = err;
        }
        if (!didThrow) {
            throw new AssertionError(
                message ??
                    `Expected function to throw${expectedType ? ` ${expectedType.name}` : ""}, but it returned normally.`);
        }
        if (expectedType && !(thrown instanceof expectedType)) {
            const actualName =
                thrown && (thrown as object).constructor
                    ? (thrown as object).constructor.name
                    : typeof thrown;
            throw new AssertionError(
                message ??
                    `Expected thrown error to be ${expectedType.name}, ` +
                    `but received ${actualName}: ` +
                    `${thrown && (thrown as Error).message}`);
        }
    },

    async rejects(
        promise: PromiseLike<unknown>,
        expectedType?: Ctor,
        message?: string,
    ): Promise<void> {
        let thrown: unknown = null;
        let didReject = false;
        try {
            await promise;
        } catch (err) {
            didReject = true;
            thrown = err;
        }
        if (!didReject) {
            throw new AssertionError(
                message ?? "Expected promise to reject, but it resolved.");
        }
        if (expectedType && !(thrown instanceof expectedType)) {
            const actualName =
                thrown && (thrown as object).constructor
                    ? (thrown as object).constructor.name
                    : typeof thrown;
            throw new AssertionError(
                message ??
                    `Expected rejection to be ${expectedType.name}, ` +
                    `but received ${actualName}: ` +
                    `${thrown && (thrown as Error).message}`);
        }
    },

    match(value: unknown, pattern: RegExp, message?: string): void {
        if (typeof value !== "string") {
            throw new AssertionError(
                message ?? `match: value must be a string, got ${typeof value}.`);
        }
        if (!(pattern instanceof RegExp)) {
            throw new AssertionError(message ?? "match: pattern must be a RegExp.");
        }
        if (!pattern.test(value)) {
            throw new AssertionError(
                message ?? `Expected ${formatValue(value)} to match ${pattern}.`);
        }
    },
};

// =============================================================================
//  Section 3 -- Shared state
// =============================================================================

const ENDPOINT = "ipc:jstest2";
const APP_NAME = "JsTest2";
const P2P_GROUP = "jstest2_group";

let app: lf.AppHandle | null = null;
let frameworkReady = false;

/** Set in before() via the whoami probe. */
let selfUid: Uint8Array | null = null;

const selfP2PName: string = P2P_GROUP;

// =============================================================================
//  Section 4 -- Helpers
// =============================================================================

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(
    predicate: () => boolean,
    timeoutMs: number,
    intervalMs: number = 100,
): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (predicate()) return true;
        await sleep(intervalMs);
    }
    return false;
}

function uidToHex(uid: Uint8Array): string {
    let out = "";
    for (const b of uid) {
        out += b.toString(16).padStart(2, "0");
    }
    return out;
}

function randomHex64(): string {
    let out = "";
    for (let i = 0; i < 64; i++) {
        out += Math.floor(Math.random() * 16).toString(16);
    }
    return out;
}

function randomSuffix(): string {
    return Math.random().toString(36).slice(2, 10);
}

// =============================================================================
//  Section 5 -- Global setup / teardown
// =============================================================================

before(async () => {
    console.error("[before] ENTER");

    lf.loadLibrary();

    // ---------------------------------------------------------------------
    // Enable the most verbose native logging available. This is done
    // BEFORE any native call that could produce diagnostics, so that the
    // before() and after() phases are fully traced.
    //
    // The three options map to the Pascal-side Z.Status flags:
    //
    //     Quiet=false          C40_QuietMode = False
    //     ShowThreadID=true    status messages get a [tid] prefix
    //     ConsoleOutput=true   status messages are written to the console
    //
    // LF_SetOption is asynchronous once the simulated main thread is
    // running; at this point it is not yet running, so the calls are
    // applied immediately.
    // ---------------------------------------------------------------------
    console.error("[before] enabling verbose native logging...");
    lf.options.setOptQuiet(false);
    lf.options.setOptShowThreadID(true);
    lf.options.setOptConsoleOutput(true);
    console.error("[before] verbose native logging enabled");

    // Per-request P2P name for this process.
    lf.options.setOptP2PName(P2P_GROUP);

    // Deployment-friendly setup: do NOT block in prepareDone.
    lf.options.setOptWaitConnectionReadyOk(false);
    lf.options.setOptOverlapConnection(true);

    // LF_SetOption is asynchronous once the main thread is running.
    // Yield here so the two options above land before prepareDone
    // starts the network.
    await sleep(150);

    console.error("[before] creating AppHandle...");
    const created = new lf.AppHandle(APP_NAME, "v2.0 test suite");

    // ---------------------------------------------------------------------
    // Register EVERY probe API up front, before prepareClient.
    // See the file-level docstring section [C1] for why.
    // ---------------------------------------------------------------------

    console.error("[before] registering API 'add'...");
    const ok1 = created.registerCall(
        "add",
        "Add two integers",
        (input: DataHandle, output: DataHandle) => {
            const req = (lf.io.readJson<{ a?: number; b?: number }>(input) ?? {}) as {
                a?: number;
                b?: number;
            };
            const a = Number(req.a) || 0;
            const b = Number(req.b) || 0;
            lf.io.writeJson(output, { result: a + b });
        },
    );
    if (!ok1) throw new Error("failed to register 'add'");

    console.error("[before] registering API 'whoami'...");
    const ok2 = created.registerCall(
        "whoami",
        "Echo caller identity",
        (input: DataHandle, output: DataHandle) => {
            const uid = input.getP2PUid();
            const name = input.getP2PName();
            lf.io.writeJson(output, {
                uid_hex: uidToHex(uid),
                p2p_name: name,
            });
        },
    );
    if (!ok2) throw new Error("failed to register 'whoami'");

    console.error("[before] registering API 'log'...");
    const ok3 = created.registerNotify(
        "log",
        "One-way log",
        (_input: DataHandle) => {
            // Intentionally ignore the payload.
        },
    );
    if (!ok3) throw new Error("failed to register 'log'");

    console.error("[before] registering API 'probe_output'...");
    const ok4 = created.registerCall(
        "probe_output",
        "Inspect own output handle",
        (_input: DataHandle, output: DataHandle) => {
            const outUid = output.getP2PUid();
            const outName = output.getP2PName();
            lf.io.writeJson(output, {
                out_uid_all_zero: Array.from(outUid).every((b) => b === 0),
                out_name_empty: outName === "",
            });
        },
    );
    if (!ok4) throw new Error("failed to register 'probe_output'");

    console.error("[before] bringing up self-connected mesh...");
    lf.framework.resetPrepare();
    lf.framework.prepareService(ENDPOINT, ENDPOINT);
    lf.framework.prepareClient(ENDPOINT, created);

    const started = lf.framework.prepareDone();
    if (started !== 1 && !lf.status.checkMainThread()) {
        throw new Error(
            `prepareDone() returned ${started} and the main thread is not running`);
    }

    console.error("[before] waiting for the mesh to converge...");
    const visible = await waitFor(
        () =>
            lf.status.checkApp(APP_NAME) &&
            lf.status.checkApi(APP_NAME, "add") &&
            lf.status.checkApi(APP_NAME, "probe_output"),
        10000,
    );
    if (!visible) {
        throw new Error(
            `${APP_NAME} did not become visible within 10 seconds`);
    }

    frameworkReady = true;
    console.error("[before] EXIT");

    // Learn our own UID via the whoami probe.
    console.error("[before] probing own UID via 'whoami'...");
    try {
        const param = new DataHandle("whoami");
        lf.io.writeJson(param, {});
        const resp = lf.framework.call(APP_NAME, param, 3000);
        try {
            if (resp.size > 0) {
                const body = lf.io.readJson<{
                    uid_hex: string;
                    p2p_name: string;
                }>(resp);
                if (
                    body &&
                    typeof body.uid_hex === "string" &&
                    body.uid_hex.length === 64
                ) {
                    const bytes = new Uint8Array(32);
                    for (let i = 0; i < 32; i++) {
                        bytes[i] = parseInt(
                            body.uid_hex.substr(i * 2, 2),
                            16,
                        );
                    }
                    selfUid = bytes;
                    console.error(`[before] own UID = ${body.uid_hex}`);
                }
            }
        } finally {
            param.dispose();
            resp.dispose();
        }
    } catch (e) {
        console.error(
            "[before] whoami probe failed; UID tests will be skipped");
        selfUid = null;
    }
});

after(async () => {
    console.error("[after] ENTER");

    if (!frameworkReady) {
        console.error("[after] framework was never ready; nothing to do");
        console.error("[after] EXIT");
        return;
    }

    console.error("[after] step 1: sleep(500) to let pending native work drain");
    await sleep(500);
    console.error("[after] step 1 done");

    console.error("[after] step 2: AsyncBridge.shutdownInstance()");
    try {
        lf.AsyncBridge.shutdownInstance();
        console.error("[after] step 2 done");
    } catch (e) {
        console.error("[after] step 2 threw:", e);
    }

    // ---------------------------------------------------------------------
    // step 3 is the critical step. If the native shutdown path blocks,
    // it blocks here, and no JS timer can fire afterwards.
    //
    // The console.error markers before and after this call are the
    // single most useful diagnostic for distinguishing:
    //
    //     "native shutdown is stuck"  -> we see "step 3 begin" but
    //                                    never "step 3 done"
    //     "JS is stuck somewhere else" -> we never see "step 3 begin"
    // ---------------------------------------------------------------------
    console.error("[after] step 3 begin: LF_ExitMainThread()");
    try {
        lf.framework.exitMainThread();
        console.error("[after] step 3 done: LF_ExitMainThread() returned");
    } catch (e) {
        console.error("[after] step 3 threw:", e);
    }

    console.error("[after] step 4: app.dispose()");
    try {
        if (app !== null) {
            app.dispose();
        }
        app = null;
        console.error("[after] step 4 done");
    } catch (e) {
        console.error("[after] step 4 threw:", e);
    }

    console.error("[after] step 5: LF_Shutdown()");
    try {
        lf.framework.shutdown();
        console.error("[after] step 5 done");
    } catch (e) {
        console.error("[after] step 5 threw:", e);
    }

    console.error("[after] EXIT");
});

// =============================================================================
//  Section 6 -- Test definitions
// =============================================================================

// -----------------------------------------------------------------------------
//  1. errors-v2
// -----------------------------------------------------------------------------

describe("errors-v2", () => {
    it("LingoFuseTimeoutError extends LingoFuseError", () => {
        const err = new lf.LingoFuseTimeoutError("timed out");
        assert.ok(err instanceof lf.LingoFuseError);
        assert.ok(err instanceof Error);
        assert.equal(err.name, "LingoFuseTimeoutError");
        assert.equal(err.message, "timed out");
    });

    it("LingoFuseTimeoutError carries targetApp / targetApi / timeoutMs", () => {
        const err = new lf.LingoFuseTimeoutError("t", {
            targetApp: "Calc",
            targetApi: "add",
            timeoutMs: 3000,
        });
        assert.equal(err.targetApp, "Calc");
        assert.equal(err.targetApi, "add");
        assert.equal(err.timeoutMs, 3000);
    });

    it("LingoFuseTimeoutError uses ErrorCode.Timeout", () => {
        const err = new lf.LingoFuseTimeoutError("t");
        assert.equal(err.code, lf.ErrorCode.Timeout);
    });

    it("LingoFuseRegistrationError extends LingoFuseError", () => {
        const err = new lf.LingoFuseRegistrationError("whoami");
        assert.ok(err instanceof lf.LingoFuseError);
        assert.equal(err.name, "LingoFuseRegistrationError");
        assert.equal(err.apiName, "whoami");
        assert.match(err.message, /whoami/);
    });

    it("all 8 exception classes are exported from the package", () => {
        for (const name of [
            "LingoFuseError",
            "LingoFuseLibraryLoadError",
            "LingoFuseCallError",
            "LingoFuseTimeoutError",
            "LingoFuseIoError",
            "LingoFuseObjectDisposedError",
            "LingoFuseCallbackError",
            "LingoFuseRegistrationError",
        ] as const) {
            assert.equal(
                typeof (lf as unknown as Record<string, unknown>)[name],
                "function",
                `missing class: ${name}`,
            );
        }
    });
});

// -----------------------------------------------------------------------------
//  2. CallPromise
// -----------------------------------------------------------------------------

describe("CallPromise", () => {
    it("is exported at the top level and from lf.async", () => {
        assert.equal(lf.CallPromise, lf.async.CallPromise);
        assert.equal(typeof lf.CallPromise, "function");
    });

    it("initial state: not settled, not abandoned", () => {
        const p = new lf.CallPromise<unknown>();
        assert.equal(p.settled, false);
        assert.equal(p.abandoned, false);
    });

    it("provides then / catch / finally (thenable interface)", () => {
        const p = new lf.CallPromise<unknown>();
        assert.equal(typeof p.then, "function");
        assert.equal(typeof p.catch, "function");
        assert.equal(typeof p.finally, "function");
    });

    it("_settleResolve resolves the underlying promise", async () => {
        const p = new lf.CallPromise<{ answer: number }>();
        p._settleResolve({ answer: 42 });
        const v = await p;
        assert.deepEqual(v, { answer: 42 });
        assert.equal(p.settled, true);
    });

    it("_settleReject rejects the underlying promise", async () => {
        const p = new lf.CallPromise<unknown>();
        const err = new Error("boom");
        p._settleReject(err);
        await assert.rejects(p, Error);
        assert.equal(p.settled, true);
    });

    it("_settleResolve is idempotent", async () => {
        const p = new lf.CallPromise<string>();
        p._settleResolve("first");
        p._settleResolve("second");
        const v = await p;
        assert.equal(v, "first");
    });

    it("_markAbandoned flips the abandoned flag", () => {
        const p = new lf.CallPromise<unknown>();
        assert.equal(p.abandoned, false);
        p._markAbandoned();
        assert.equal(p.abandoned, true);
    });

    it("a resolved CallPromise is awaitable like a regular Promise", async () => {
        const p = new lf.CallPromise<number>();
        p._settleResolve(7);
        const doubled = await p.then((v) => v * 2);
        assert.equal(doubled, 14);
    });
});

// -----------------------------------------------------------------------------
//  3. AsyncBridge
// -----------------------------------------------------------------------------

describe("AsyncBridge", () => {
    it("is exported at the top level and from lf.async", () => {
        assert.equal(lf.AsyncBridge, lf.async.AsyncBridge);
        assert.equal(typeof lf.AsyncBridge, "function");
    });

    it("instance() returns a singleton", () => {
        lf.AsyncBridge.shutdownInstance();
        const a = lf.AsyncBridge.instance();
        const b = lf.AsyncBridge.instance();
        assert.equal(a, b);
    });

    it("fresh instance has zero counters", () => {
        lf.AsyncBridge.shutdownInstance();
        const bridge = lf.AsyncBridge.instance();
        const stats = bridge.stats();
        assert.equal(stats.total, 0);
        assert.equal(stats.pending, 0);
        assert.equal(stats.fired, 0);
        assert.equal(stats.abandoned, 0);
        assert.equal(stats.not_queued, 0);
        assert.equal(stats.released_total, 0);
    });

    it("graceSeconds and periodSeconds have positive defaults", () => {
        lf.AsyncBridge.shutdownInstance();
        const bridge = lf.AsyncBridge.instance();
        assert.ok(bridge.graceSeconds > 0);
        assert.ok(bridge.periodSeconds > 0);
    });

    it("shutdownInstance() clears the singleton", () => {
        const first = lf.AsyncBridge.instance();
        lf.AsyncBridge.shutdownInstance();
        const second = lf.AsyncBridge.instance();
        assert.notEqual(first, second);
    });

    it("shutdown() is idempotent", () => {
        lf.AsyncBridge.shutdownInstance();
        const bridge = lf.AsyncBridge.instance();
        bridge.shutdown();
        bridge.shutdown();
        assert.ok(true);
    });
});

// -----------------------------------------------------------------------------
//  4. Targets
// -----------------------------------------------------------------------------

describe("Targets", () => {
    it("all four Target classes are exported at the top level", () => {
        assert.equal(typeof lf.AppTarget, "function");
        assert.equal(typeof lf.UIDTarget, "function");
        assert.equal(typeof lf.P2PNameTarget, "function");
        assert.equal(typeof lf.address.Target, "function");
        assert.equal(lf.AppTarget, lf.address.AppTarget);
    });

    it("AppTarget stores the app name", () => {
        const t = new lf.AppTarget("Calculator");
        assert.equal(t.appName, "Calculator");
    });

    it("AppTarget rejects a non-string name", () => {
        assert.throws(
            () => new lf.AppTarget(42 as unknown as string),
            TypeError,
        );
    });

    it("AppTarget equality works across instances", () => {
        assert.equal(
            new lf.AppTarget("A").appName,
            new lf.AppTarget("A").appName,
        );
    });

    it("AppTarget.hashKey() is value-based", () => {
        assert.equal(
            new lf.AppTarget("X").hashKey(),
            new lf.AppTarget("X").hashKey(),
        );
        assert.notEqual(
            new lf.AppTarget("X").hashKey(),
            new lf.AppTarget("Y").hashKey(),
        );
    });

    it("UIDTarget accepts Uint8Array(32)", () => {
        const uid = new Uint8Array(32);
        for (let i = 0; i < 32; i++) uid[i] = i;
        const t = new lf.UIDTarget(uid);
        assert.deepEqual(t.uidBytes, uid);
    });

    it("UIDTarget accepts 64-char hex string", () => {
        const hex =
            "00112233445566778899aabbccddeeff" +
            "00112233445566778899aabbccddeeff";
        const t = new lf.UIDTarget(hex);
        assert.equal(t.uidHex, hex);
        assert.equal(t.uidBytes.length, 32);
    });

    it("UIDTarget rejects a wrong-length Uint8Array", () => {
        assert.throws(
            () => new lf.UIDTarget(new Uint8Array(10)),
            RangeError,
        );
    });

    it("UIDTarget rejects a wrong-length hex string", () => {
        assert.throws(() => new lf.UIDTarget("abcd"), RangeError);
    });

    it("UIDTarget rejects a non-hex string", () => {
        assert.throws(
            () => new lf.UIDTarget("zz".repeat(32)),
            RangeError,
        );
    });

    it("UIDTarget rejects a wrong type", () => {
        assert.throws(
            () => new lf.UIDTarget(42 as unknown as string),
            TypeError,
        );
    });

    it("UIDTarget.uidBytes returns a defensive copy", () => {
        const uid = new Uint8Array(32).fill(1);
        const t = new lf.UIDTarget(uid);
        const a = t.uidBytes;
        const b = t.uidBytes;
        assert.notEqual(a, b);
        a[0] = 99;
        assert.equal(t.uidBytes[0], 1);
    });

    it("UIDTarget.hashKey() is value-based", () => {
        const uid = new Uint8Array(32).fill(7);
        assert.equal(
            new lf.UIDTarget(uid).hashKey(),
            new lf.UIDTarget(uid).hashKey(),
        );
        const other = new Uint8Array(32).fill(8);
        assert.notEqual(
            new lf.UIDTarget(uid).hashKey(),
            new lf.UIDTarget(other).hashKey(),
        );
    });

    it("P2PNameTarget stores the group name", () => {
        const t = new lf.P2PNameTarget("workers");
        assert.equal(t.groupName, "workers");
    });

    it("P2PNameTarget rejects a non-string group name", () => {
        assert.throws(
            () => new lf.P2PNameTarget(42 as unknown as string),
            TypeError,
        );
    });

    it("P2PNameTarget.hashKey() is value-based", () => {
        assert.equal(
            new lf.P2PNameTarget("G").hashKey(),
            new lf.P2PNameTarget("G").hashKey(),
        );
        assert.notEqual(
            new lf.P2PNameTarget("G").hashKey(),
            new lf.P2PNameTarget("H").hashKey(),
        );
    });

    it("every Target exposes the call-shape methods", () => {
        const targets: lf.address.Target[] = [
            new lf.AppTarget("X"),
            new lf.UIDTarget(new Uint8Array(32)),
            new lf.P2PNameTarget("G"),
        ];
        for (const t of targets) {
            for (const m of [
                "call",
                "callAsync",
                "callSync",
                "tryCallSync",
                "sequencedCall",
                "sequencedCallAsync",
                "notify",
                "sequencedNotify",
                "hashKey",
            ]) {
                assert.equal(
                    typeof (t as unknown as Record<string, unknown>)[m],
                    "function",
                    `${t.constructor.name} is missing ${m}`,
                );
            }
        }
    });

    it("cross-type hashKeys are not silently equal", () => {
        const a = new lf.AppTarget("X");
        const p = new lf.P2PNameTarget("X");
        assert.notEqual(a.hashKey(), p.hashKey());
        assert.match(a.hashKey(), /^app:/);
        assert.match(p.hashKey(), /^p2p:/);
    });
});

// -----------------------------------------------------------------------------
//  5. options
// -----------------------------------------------------------------------------

describe("options", () => {
    // LF_SetOption is asynchronous once the simulated main thread is
    // running. Every set-then-read pair must yield long enough for the
    // main thread to apply the change.
    const flushOption = (): Promise<void> => sleep(150);

    it("exports all 16 typed setter/getter pairs", () => {
        const expected: ReadonlyArray<keyof typeof lf.options> = [
            "setOptPassword", "getOptPassword",
            "setOptDebug", "getOptDebug",
            "setOptQuiet", "getOptQuiet",
            "setOptShowThreadID", "getOptShowThreadID",
            "setOptConsoleOutput", "getOptConsoleOutput",
            "setOptOverlapConnection", "getOptOverlapConnection",
            "setOptWaitConnectionReadyOk", "getOptWaitConnectionReadyOk",
            "setOptWaitConnectionTimeout", "getOptWaitConnectionTimeout",
            "setOptIpcServThreadCount", "getOptIpcServThreadCount",
            "setOptIpcServMaxQueueLength", "getOptIpcServMaxQueueLength",
            "setOptIpcServMaxMsgSize", "getOptIpcServMaxMsgSize",
            "setOptFixedSequencedTime", "getOptFixedSequencedTime",
            "setOptP2PName", "getOptP2PName",
            "setOptDataHandleIdleTimeout", "getOptDataHandleIdleTimeout",
            "setOptDataHandlePoolScanInterval",
            "getOptDataHandlePoolScanInterval",
            "setOptNoReponseCmdNullFlushThreshold",
            "getOptNoReponseCmdNullFlushThreshold",
        ];
        for (const name of expected) {
            assert.equal(
                typeof lf.options[name],
                "function",
                `options.${String(name)} is missing`,
            );
        }
        assert.equal(expected.length, 32);
    });

    it("setOptQuiet / getOptQuiet round-trip", async () => {
        const original = lf.options.getOptQuiet();
        try {
            lf.options.setOptQuiet(true);
            await flushOption();
            assert.equal(lf.options.getOptQuiet(), true);

            lf.options.setOptQuiet(false);
            await flushOption();
            assert.equal(lf.options.getOptQuiet(), false);
        } finally {
            lf.options.setOptQuiet(original);
        }
    });

    it("setOptShowThreadID / getOptShowThreadID round-trip", async () => {
        const original = lf.options.getOptShowThreadID();
        try {
            lf.options.setOptShowThreadID(false);
            await flushOption();
            assert.equal(lf.options.getOptShowThreadID(), false);

            lf.options.setOptShowThreadID(true);
            await flushOption();
            assert.equal(lf.options.getOptShowThreadID(), true);
        } finally {
            lf.options.setOptShowThreadID(original);
        }
    });

    it("setOptConsoleOutput / getOptConsoleOutput round-trip", async () => {
        const original = lf.options.getOptConsoleOutput();
        try {
            lf.options.setOptConsoleOutput(false);
            await flushOption();
            assert.equal(lf.options.getOptConsoleOutput(), false);
        } finally {
            lf.options.setOptConsoleOutput(original);
        }
    });

    it("setOptOverlapConnection / getOptOverlapConnection round-trip", async () => {
        const original = lf.options.getOptOverlapConnection();
        try {
            lf.options.setOptOverlapConnection(false);
            await flushOption();
            assert.equal(lf.options.getOptOverlapConnection(), false);

            lf.options.setOptOverlapConnection(true);
            await flushOption();
            assert.equal(lf.options.getOptOverlapConnection(), true);
        } finally {
            lf.options.setOptOverlapConnection(original);
        }
    });

    it("setOptWaitConnectionReadyOk / getOptWaitConnectionReadyOk round-trip", async () => {
        const original = lf.options.getOptWaitConnectionReadyOk();
        try {
            lf.options.setOptWaitConnectionReadyOk(false);
            await flushOption();
            assert.equal(lf.options.getOptWaitConnectionReadyOk(), false);

            lf.options.setOptWaitConnectionReadyOk(true);
            await flushOption();
            assert.equal(lf.options.getOptWaitConnectionReadyOk(), true);
        } finally {
            lf.options.setOptWaitConnectionReadyOk(original);
        }
    });

    it("setOptWaitConnectionTimeout / getOptWaitConnectionTimeout round-trip", async () => {
        const original = lf.options.getOptWaitConnectionTimeout();
        try {
            lf.options.setOptWaitConnectionTimeout(12345);
            await flushOption();
            assert.equal(lf.options.getOptWaitConnectionTimeout(), 12345);
        } finally {
            lf.options.setOptWaitConnectionTimeout(original);
        }
    });

    it("setOptIpcServThreadCount / getter round-trip", async () => {
        const original = lf.options.getOptIpcServThreadCount();
        try {
            lf.options.setOptIpcServThreadCount(8);
            await flushOption();
            assert.equal(lf.options.getOptIpcServThreadCount(), 8);
        } finally {
            lf.options.setOptIpcServThreadCount(original);
        }
    });

    it("setOptIpcServMaxQueueLength / getter round-trip", async () => {
        const original = lf.options.getOptIpcServMaxQueueLength();
        try {
            lf.options.setOptIpcServMaxQueueLength(1024);
            await flushOption();
            assert.equal(lf.options.getOptIpcServMaxQueueLength(), 1024);
        } finally {
            lf.options.setOptIpcServMaxQueueLength(original);
        }
    });

    it("setOptIpcServMaxMsgSize / getter round-trip", async () => {
        const original = lf.options.getOptIpcServMaxMsgSize();
        try {
            lf.options.setOptIpcServMaxMsgSize(1048576);
            await flushOption();
            assert.equal(lf.options.getOptIpcServMaxMsgSize(), 1048576);
        } finally {
            lf.options.setOptIpcServMaxMsgSize(original);
        }
    });

    it("setOptFixedSequencedTime / getter round-trip", async () => {
        const original = lf.options.getOptFixedSequencedTime();
        try {
            lf.options.setOptFixedSequencedTime(30000);
            await flushOption();
            assert.equal(lf.options.getOptFixedSequencedTime(), 30000);
        } finally {
            lf.options.setOptFixedSequencedTime(original);
        }
    });

    it("setOptDataHandleIdleTimeout / getter round-trip", async () => {
        const original = lf.options.getOptDataHandleIdleTimeout();
        try {
            lf.options.setOptDataHandleIdleTimeout(300000);
            await flushOption();
            assert.equal(lf.options.getOptDataHandleIdleTimeout(), 300000);
        } finally {
            lf.options.setOptDataHandleIdleTimeout(original);
        }
    });

    it("setOptDataHandlePoolScanInterval / getter round-trip", async () => {
        const original = lf.options.getOptDataHandlePoolScanInterval();
        try {
            lf.options.setOptDataHandlePoolScanInterval(2000);
            await flushOption();
            assert.equal(
                lf.options.getOptDataHandlePoolScanInterval(),
                2000,
            );
        } finally {
            lf.options.setOptDataHandlePoolScanInterval(original);
        }
    });

    it("setOptNoReponseCmdNullFlushThreshold / getter round-trip", async () => {
        const original =
            lf.options.getOptNoReponseCmdNullFlushThreshold();
        try {
            lf.options.setOptNoReponseCmdNullFlushThreshold(1234);
            await flushOption();
            assert.equal(
                lf.options.getOptNoReponseCmdNullFlushThreshold(),
                1234,
            );
        } finally {
            lf.options.setOptNoReponseCmdNullFlushThreshold(original);
        }
    });

    it("setOptP2PName / getOptP2PName round-trip", async () => {
        const original = lf.options.getOptP2PName();
        try {
            lf.options.setOptP2PName("test_group");
            await flushOption();
            assert.equal(lf.options.getOptP2PName(), "test_group");
        } finally {
            lf.options.setOptP2PName(original);
        }
    });

    it("setOptPassword stores; getOptPassword returns the fixed mask", () => {
        const original = lf.options.getOptPassword();
        try {
            lf.options.setOptPassword("secret123");
            const read = lf.options.getOptPassword();
            assert.match(read, /^\*+$/);
        } finally {
            lf.options.setOptPassword(original);
        }
    });

    it("setOptDebug / getOptDebug do not throw", () => {
        // -----------------------------------------------------------------
        // [C2] NO SIDE-EFFECTING debug COMMANDS
        //
        // The debug option is write-only and executes a C4 console
        // command on the native side. Some commands have side effects:
        //
        //     "service"       queries the live service pool
        //     "tunnel"        queries the live tunnel pool
        //     "ZNet_Info"     walks the ZNet instance registry
        //     ...
        //
        // Running such a command during the test suite can leave an
        // asynchronous native task pending. If that task is still
        // pending when LF_ExitMainThread runs, the native cleanup
        // phase blocks forever, and the JS event loop (blocked on the
        // synchronous LF_ExitMainThread call) can never run any JS
        // timer again.
        //
        // The test below uses a deliberately non-existent command name
        // so that the debug option path is exercised without triggering
        // any live query. The native side logs "unknown command" and
        // returns immediately.
        // -----------------------------------------------------------------
        lf.options.setOptDebug("noop-for-test");
        const v = lf.options.getOptDebug();
        assert.equal(typeof v, "string");
    });

    it("setOptWaitConnectionTimeout rejects non-number", () => {
        assert.throws(
            () =>
                lf.options.setOptWaitConnectionTimeout(
                    "not-a-number" as unknown as number,
                ),
            TypeError,
        );
    });

    it("setOptP2PName rejects non-string", () => {
        assert.throws(
            () => lf.options.setOptP2PName(42 as unknown as string),
            TypeError,
        );
    });

    it("setOptPassword rejects non-string", () => {
        assert.throws(
            () => lf.options.setOptPassword(42 as unknown as string),
            TypeError,
        );
    });
});

// -----------------------------------------------------------------------------
//  6. framework.getOption
// -----------------------------------------------------------------------------

describe("framework.getOption", () => {
    it("getOption('Quiet') agrees with options.getOptQuiet()", () => {
        const raw = lf.framework.getOption("Quiet");
        const typed = lf.options.getOptQuiet();
        if (raw.length === 0) {
            assert.equal(typed, false);
        } else {
            assert.equal(typed, raw.trim().toLowerCase() === "true");
        }
    });

    it("getOption('UnknownOption_xyz') returns an empty string", () => {
        assert.equal(lf.framework.getOption("UnknownOption_xyz"), "");
    });

    it("getOption rejects a non-string argument", () => {
        assert.throws(
            () => lf.framework.getOption(42 as unknown as string),
            TypeError,
        );
    });
});

// -----------------------------------------------------------------------------
//  7. DataHandle UID methods
// -----------------------------------------------------------------------------

describe("DataHandle UID methods", () => {
    it("writeUid writes exactly 32 bytes", () => {
        const h = new DataHandle("test");
        try {
            const uid = new Uint8Array(32).fill(0xaa);
            h.writeUid(uid);
            assert.equal(h.size, 32);
        } finally {
            h.dispose();
        }
    });

    it("writeUid rejects a non-Uint8Array", () => {
        const h = new DataHandle("test");
        try {
            assert.throws(
                () => h.writeUid("not bytes" as unknown as Uint8Array),
                TypeError,
            );
        } finally {
            h.dispose();
        }
    });

    it("writeUid rejects a wrong-length Uint8Array", () => {
        const h = new DataHandle("test");
        try {
            assert.throws(
                () => h.writeUid(new Uint8Array(10)),
                RangeError,
            );
        } finally {
            h.dispose();
        }
    });

    it("writeUid / readUid round-trip", () => {
        const h = new DataHandle("test");
        try {
            const uid = new Uint8Array(32);
            for (let i = 0; i < 32; i++) uid[i] = (i * 7) & 0xff;
            h.writeUid(uid);

            h.position = 0;
            const back = h.readUid();
            assert.deepEqual(back, uid);
        } finally {
            h.dispose();
        }
    });

    it("readUid throws LingoFuseIoError on a short buffer", () => {
        const h = new DataHandle("test");
        try {
            h.writeBytes(Uint8Array.of(1, 2, 3));
            h.position = 0;
            assert.throws(() => h.readUid(), lf.LingoFuseIoError);
        } finally {
            h.dispose();
        }
    });

    it("getP2PUid on a self-created handle returns 32 zero bytes", () => {
        const h = new DataHandle("test");
        try {
            const uid = h.getP2PUid();
            assert.equal(uid instanceof Uint8Array, true);
            assert.equal(uid.length, 32);
            for (let i = 0; i < 32; i++) {
                assert.equal(uid[i], 0);
            }
        } finally {
            h.dispose();
        }
    });

    it("getP2PName on a self-created handle returns an empty string", () => {
        const h = new DataHandle("test");
        try {
            assert.equal(h.getP2PName(), "");
        } finally {
            h.dispose();
        }
    });
});

// -----------------------------------------------------------------------------
//  8. p2p-registration
// -----------------------------------------------------------------------------

describe("p2p-registration", () => {
    it("exports three module-level functions", () => {
        assert.equal(typeof lf.registerP2PCall, "function");
        assert.equal(typeof lf.registerP2PNotify, "function");
        assert.equal(typeof lf.unregisterP2P, "function");
    });

    it("registerP2PCall succeeds; unregisterP2P removes it", () => {
        const api = "p2p_test_call_" + randomSuffix();
        try {
            lf.registerP2PCall(
                api,
                (_input: DataHandle, output: DataHandle) => {
                    lf.io.writeJson(output, { ok: true });
                },
                "test call",
            );
            assert.equal(lf.unregisterP2P(api), true);
        } finally {
            try { lf.unregisterP2P(api); } catch { /* ignore */ }
        }
    });

    it("registerP2PNotify succeeds; unregisterP2P removes it", () => {
        const api = "p2p_test_notify_" + randomSuffix();
        try {
            lf.registerP2PNotify(
                api,
                (_input: DataHandle) => {
                    // no-op
                },
                "test notify",
            );
            assert.equal(lf.unregisterP2P(api), true);
        } finally {
            try { lf.unregisterP2P(api); } catch { /* ignore */ }
        }
    });

    it("duplicate registerP2PCall throws LingoFuseRegistrationError", () => {
        const api = "p2p_dup_call_" + randomSuffix();
        try {
            lf.registerP2PCall(api, () => { /* no-op */ }, "first");
            assert.throws(
                () => lf.registerP2PCall(api, () => { /* no-op */ }, "second"),
                lf.LingoFuseRegistrationError,
            );
        } finally {
            try { lf.unregisterP2P(api); } catch { /* ignore */ }
        }
    });

    it("unregisterP2P returns false for an unknown name", () => {
        const api = "p2p_unknown_" + randomSuffix();
        assert.equal(lf.unregisterP2P(api), false);
    });

    it("registerP2PCall rejects a non-string apiName", () => {
        assert.throws(
            () =>
                lf.registerP2PCall(
                    42 as unknown as string,
                    () => { /* no-op */ },
                ),
            TypeError,
        );
    });

    it("registerP2PCall rejects a non-function handler", () => {
        assert.throws(
            () =>
                lf.registerP2PCall(
                    "p2p_bad_handler",
                    "not-a-function" as unknown as (
                        input: DataHandle,
                        output: DataHandle,
                    ) => void,
                ),
            TypeError,
        );
    });

    it("unregisterP2P rejects a non-string apiName", () => {
        assert.throws(
            () => lf.unregisterP2P(42 as unknown as string),
            TypeError,
        );
    });
});

// -----------------------------------------------------------------------------
//  9. status UID checks
// -----------------------------------------------------------------------------

describe("status UID checks", () => {
    it("status exports checkUid / checkUidApi / checkP2PName / checkP2PNameApi", () => {
        assert.equal(typeof lf.status.checkUid, "function");
        assert.equal(typeof lf.status.checkUidApi, "function");
        assert.equal(typeof lf.status.checkP2PName, "function");
        assert.equal(typeof lf.status.checkP2PNameApi, "function");
    });

    it("checkUid returns false for a random unregistered UID", () => {
        const uid = new Uint8Array(32);
        for (let i = 0; i < 32; i++) {
            uid[i] = (Math.random() * 256) & 0xff;
        }
        assert.equal(lf.status.checkUid(uid), false);
    });

    it("checkUid accepts a 64-char hex string", () => {
        const hex = "00".repeat(32);
        assert.equal(lf.status.checkUid(hex), false);
    });

    it("checkUid rejects a wrong-length UID", () => {
        assert.throws(
            () => lf.status.checkUid(new Uint8Array(10)),
            RangeError,
        );
    });

    it("checkUid rejects a wrong type", () => {
        assert.throws(
            () => lf.status.checkUid(42 as unknown as Uint8Array),
            TypeError,
        );
    });

    it("checkUidApi returns false for a random unregistered pair", () => {
        const uid = new Uint8Array(32);
        for (let i = 0; i < 32; i++) {
            uid[i] = (Math.random() * 256) & 0xff;
        }
        assert.equal(lf.status.checkUidApi(uid, "no_such_api"), false);
    });

    it("checkP2PName returns false for an unregistered group", () => {
        assert.equal(
            lf.status.checkP2PName("no_such_group_" + randomHex64()),
            false,
        );
    });

    it("checkP2PName rejects a non-string argument", () => {
        assert.throws(
            () => lf.status.checkP2PName(42 as unknown as string),
            TypeError,
        );
    });

    it("checkP2PNameApi rejects a non-string apiName", () => {
        assert.throws(
            () => lf.status.checkP2PNameApi("G", 42 as unknown as string),
            TypeError,
        );
    });
});

// -----------------------------------------------------------------------------
//  10. Integration: call shapes
// -----------------------------------------------------------------------------

describe("Integration: call shapes", () => {
    it("AppTarget.callSync returns a deserialized result", () => {
        const target = new lf.AppTarget(APP_NAME);
        const result = target.callSync<
            { a: number; b: number },
            { result: number }
        >("add", { a: 20, b: 22 }, { timeoutMs: 3000 });
        assert.deepEqual(result, { result: 42 });
    });

    it("AppTarget.tryCallSync returns null on timeout / unreachable", () => {
        const ghost = new lf.AppTarget(
            "DefinitelyNotAnApp_" + randomHex64(),
        );
        const result = ghost.tryCallSync<
            { a: number; b: number },
            { result: number }
        >("add", { a: 1, b: 2 }, { timeoutMs: 500 });
        assert.equal(result, null);
    });

    it("AppTarget.call returns a CallPromise that resolves via await", async () => {
        const target = new lf.AppTarget(APP_NAME);
        const cp = target.call<
            { a: number; b: number },
            { result: number }
        >("add", { a: 3, b: 4 }, { timeoutMs: 3000 });
        assert.equal(cp instanceof lf.CallPromise, true);
        const result = await cp;
        assert.deepEqual(result, { result: 7 });
    });

    it("AppTarget.callAsync delivers to an inline callback with no await", async () => {
        const target = new lf.AppTarget(APP_NAME);

        const result = await new Promise<{ result: number }>(
            (resolve, reject) => {
                target.callAsync<
                    { a: number; b: number },
                    { result: number }
                >(
                    "add",
                    { a: 5, b: 6 },
                    (res, err) => {
                        if (err) return reject(err);
                        resolve(res!);
                    },
                );
            },
        );

        assert.deepEqual(result, { result: 11 });
    });

    it("AppTarget.callAsync passes userData through to the callback", async () => {
        const target = new lf.AppTarget(APP_NAME);
        const tag = { origin: "test" };

        const received = await new Promise<unknown>(
            (resolve, reject) => {
                target.callAsync<{ a: number; b: number }, { result: number }>(
                    "add",
                    { a: 1, b: 1 },
                    (_res, err, userData) => {
                        if (err) return reject(err);
                        resolve(userData);
                    },
                    tag,
                );
            },
        );

        assert.equal(received, tag);
    });

    it("AppTarget.notify returns immediately and does not throw", () => {
        const target = new lf.AppTarget(APP_NAME);
        target.notify("log", { level: "info" });
        assert.ok(true);
    });

    it("AppTarget.sequencedNotify returns immediately and does not throw", () => {
        const target = new lf.AppTarget(APP_NAME);
        target.sequencedNotify("log", { level: "info" });
        assert.ok(true);
    });
});

// -----------------------------------------------------------------------------
//  11. Integration: UIDTarget
// -----------------------------------------------------------------------------

describe("Integration: UIDTarget", () => {
    it("UIDTarget.callSync reaches the target by UID", () => {
        if (selfUid === null) return;
        const target = new lf.UIDTarget(selfUid);
        const result = target.callSync<
            { a: number; b: number },
            { result: number }
        >("add", { a: 10, b: 32 }, { timeoutMs: 3000 });
        assert.deepEqual(result, { result: 42 });
    });

    it("UIDTarget.call (Promise) reaches the target by UID", async () => {
        if (selfUid === null) return;
        const target = new lf.UIDTarget(selfUid);
        const result = await target.call<
            { a: number; b: number },
            { result: number }
        >("add", { a: 1, b: 2 }, { timeoutMs: 3000 });
        assert.deepEqual(result, { result: 3 });
    });

    it("UIDTarget accepts a hex string in place of a Uint8Array", () => {
        if (selfUid === null) return;
        const hex = uidToHex(selfUid);
        const target = new lf.UIDTarget(hex);
        const result = target.callSync<
            { a: number; b: number },
            { result: number }
        >("add", { a: 7, b: 8 }, { timeoutMs: 3000 });
        assert.deepEqual(result, { result: 15 });
    });
});

// -----------------------------------------------------------------------------
//  12. Integration: side data
// -----------------------------------------------------------------------------

describe("Integration: side data", () => {
    it("getP2PUid inside a callback returns the sender's 32-byte UID", async () => {
        const target = new lf.AppTarget(APP_NAME);
        const result = await target.call<unknown, { uid_hex: string }>(
            "whoami",
            {},
            { timeoutMs: 3000 },
        );
        assert.equal(typeof result.uid_hex, "string");
        assert.equal(result.uid_hex.length, 64);
        assert.match(result.uid_hex, /[1-9a-f]/);
    });

    it("getP2PName inside a callback returns the sender's declared group", async () => {
        const target = new lf.AppTarget(APP_NAME);
        const result = await target.call<unknown, { p2p_name: string }>(
            "whoami",
            {},
            { timeoutMs: 3000 },
        );
        assert.equal(result.p2p_name, P2P_GROUP);
    });

    it("getP2PUid / getP2PName on the OUTPUT handle return default values", () => {
        const target = new lf.AppTarget(APP_NAME);
        const result = target.callSync<
            unknown,
            { out_uid_all_zero: boolean; out_name_empty: boolean }
        >("probe_output", {}, { timeoutMs: 3000 });
        assert.equal(result.out_uid_all_zero, true);
        assert.equal(result.out_name_empty, true);
    });
});

// =============================================================================
//  Section 7 -- Runner
// =============================================================================

function detectRuntimeLabel(): string {
    if (typeof (globalThis as { Deno?: unknown }).Deno !== "undefined") {
        return "Deno";
    }
    if (typeof (globalThis as { Bun?: unknown }).Bun !== "undefined") {
        return "Bun";
    }
    const proc = (globalThis as {
        process?: { versions?: { node?: string } };
    }).process;
    if (proc?.versions?.node) {
        return `Node.js ${proc.versions.node}`;
    }
    return "Unknown";
}

async function runAll(): Promise<number> {
    console.error("LingoFuse TypeScript binding - v2.0 test suite");
    console.error(`Runtime: ${detectRuntimeLabel()}`);
    console.error("");

    let setupFailed = false;
    let setupError: unknown = null;

    if (beforeAllFn !== null) {
        try {
            await beforeAllFn();
        } catch (err) {
            setupFailed = true;
            setupError = err;
        }
    }

    let passed = 0;
    let failed = 0;

    if (setupFailed) {
        const detail =
            setupError instanceof Error
                ? setupError.stack ?? setupError.message
                : String(setupError);
        console.error("[SETUP FAILED]");
        console.error(detail);
        console.error("");
        console.error(
            "All tests are skipped because the shared setup did not complete.");
        console.error("");
    }

    for (const suite of SUITES) {
        console.error(`  ${suite.name}`);
        for (const testCase of suite.tests) {
            if (setupFailed) {
                console.error(`    - ${testCase.name} (skipped)`);
                continue;
            }
            try {
                await Promise.race([
                    Promise.resolve().then(() => testCase.fn()),
                    new Promise<never>((_, reject) => {
                        const t = setTimeout(
                            () =>
                                reject(
                                    new Error(
                                        "test timed out after 15000 ms",
                                    ),
                                ),
                            15000,
                        );
                        const th = t as { unref?: () => void };
                        if (typeof th.unref === "function") th.unref();
                    }),
                ]);
                passed += 1;
                console.error(`    \u2713 ${testCase.name}`);
            } catch (err) {
                failed += 1;
                const message =
                    err instanceof Error ? err.message : String(err);
                console.error(`    \u2717 ${testCase.name}`);
                console.error(`        ${message}`);
            }
        }
    }

    if (afterAllFn !== null) {
        try {
            await afterAllFn();
        } catch (err) {
            const detail =
                err instanceof Error
                    ? err.stack ?? err.message
                    : String(err);
            console.error("[TEARDOWN FAILED]");
            console.error(detail);
        }
    }

    console.error("");
    console.error("Summary");
    console.error(`  runtime : ${detectRuntimeLabel()}`);
    console.error(`  passed  : ${passed}`);
    console.error(`  failed  : ${failed}`);
    console.error(`  total   : ${passed + failed}`);

    if (setupFailed) return 1;
    return failed === 0 ? 0 : 1;
}

// =============================================================================
//  Section 8 -- Entry point
// =============================================================================

startWatchdog();

runAll()
    .then((code) => {
        stopWatchdog();
        const proc = (globalThis as {
            process?: { exitCode?: number; exit?: (code: number) => void };
        }).process;

        if (proc !== undefined) {
            proc.exitCode = code;

            // Give the process up to 3 seconds to wind down. If anything
            // is still holding the event loop alive (a stray Koffi
            // handle, an unclosed native socket, ...), force-exit with
            // the correct code.
            //
            // This short timer is safe even though the watchdog is
            // armed: the watchdog only fires at 90 seconds, and the
            // process will normally exit within milliseconds of this
            // call.
            setTimeout(() => {
                if (typeof proc.exit === "function") {
                    proc.exit(code);
                }
            }, 3000);
        }
    })
    .catch((err: unknown) => {
        stopWatchdog();
        console.error("");
        console.error("[FATAL] The test runner itself crashed:");
        console.error(
            err instanceof Error
                ? err.stack ?? err.message
                : String(err),
        );
        const proc = (globalThis as {
            process?: { exit?: (code: number) => void; exitCode?: number };
        }).process;
        if (proc !== undefined) {
            if (typeof proc.exit === "function") proc.exit(1);
            else proc.exitCode = 1;
        }
    });