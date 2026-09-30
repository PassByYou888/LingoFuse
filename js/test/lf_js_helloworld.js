/**
 * @file lf_js_helloworld.js
 * @brief Standalone end-to-end demonstration of the LingoFuse
 *        JavaScript binding.
 *
 * This program is a self-contained example. It exercises the entire
 * stack in a single process:
 *
 *   1. Loads the native LingoFuse library.
 *   2. Creates an application and registers three APIs:
 *        - "add"    (Call mode,   JSON in / JSON out)
 *        - "echo"   (Call mode,   JSON in / JSON out)
 *        - "log"    (Notify mode, JSON in)
 *   3. Starts the framework with a single combined service+client.
 *   4. Waits for the application to become visible on the mesh.
 *   5. Invokes the registered APIs through four paths:
 *        - AppHandle.localCall    (in-process, no network hop)
 *        - AppHandle.localNotify  (in-process, one-way)
 *        - framework.call         (network-routed, resolves to the
 *                                  same in-process instance via the
 *                                  local-first optimisation)
 *   6. Prints the results.
 *   7. Cleans up in the documented order.
 *
 * The program is designed to be run with:
 *
 *     node lf_js_helloworld.js
 *
 * It does not require a second process. The single "ipc:demo"
 * endpoint is both the service and the client.
 *
 * ============================================================================
 * WHY A SINGLE PROCESS
 * ============================================================================
 * A two-process demo (a separate server and a separate client) is the
 * more realistic topology for production. It is also much harder to
 * demonstrate in one file, because it requires the reader to start two
 * terminals and to reason about timing. This example deliberately
 * chooses the single-process shape so that the full lifecycle is
 * visible in one run and every result is deterministic.
 *
 * The remote-invocation path is still exercised: framework.call() goes
 * through the same code path that a cross-process call would use. It
 * simply resolves to the local instance, thanks to LingoFuse's
 * documented local-first routing.
 *
 * ============================================================================
 * THE STARTUP WAIT
 * ============================================================================
 * Wait_Ready is disabled during preparation so that prepareDone()
 * returns immediately instead of blocking for up to 30 seconds. That
 * makes the demo start faster, but it means the framework is NOT
 * necessarily usable the moment prepareDone() returns.
 *
 * The native library connects a client to the service over IPC (or
 * TCP), and the first connection always goes through a brief
 * "connect - disconnect - reconnect" cycle while the service
 * finishes initialising. During that window, the client has not yet
 * received the service's API-info broadcast, so its local cache does
 * not know that "JsDemo" exists. A call issued during that window
 * times out.
 *
 * The correct way to handle this is to poll checkApp / checkApi until
 * the target becomes visible, with a bounded timeout. That is what
 * waitForApp() does below. Production code should always use this
 * pattern when Wait_Ready is disabled.
 *
 * ============================================================================
 * SHUTDOWN ORDER
 * ============================================================================
 * The native library requires a specific shutdown sequence:
 *
 *   1. exitMainThread()   stop the simulated main thread
 *   2. app.dispose()      detach the application (first stage)
 *   3. shutdown()         release everything (second stage)
 *
 * Calling shutdown() alone also performs steps 1 and 2 internally, but
 * the explicit sequence is what production code should use. This
 * example demonstrates the explicit sequence.
 *
 * ============================================================================
 * DIRECTORY LAYOUT
 * ============================================================================
 * This script assumes the following flat project layout:
 *
 *     js/
 *     ├── test/lf_js_helloworld.js   (this file)
 *     ├── index.js
 *     ├── index.mjs
 *     ├── binding.js
 *     ├── ... all other binding sources ...
 *     ├── package.json
 *     └── node_modules/         (koffi)
 *
 * Because every file lives in the same directory, the binding is
 * required as "./index.js".
 *
 * ============================================================================
 */

"use strict";

const lf = require("../index.js");

// ============================================================================
// Callback error reporting
// ============================================================================

/**
 * Install a callback error handler before any API is registered. Every
 * exception thrown by a user callback is routed through this handler
 * and also written to stderr. In a real application this is where you
 * would push the error into your logging pipeline.
 */
lf.framework.setCallbackErrorHandler((source, err) => {
    const message =
        err instanceof Error ? err.stack ?? err.message : String(err);
    console.error(`[app] callback failure at ${source}: ${message}`);
});

// ============================================================================
// Utilities
// ============================================================================

/**
 * Promise-based sleep helper.
 *
 * @param {number} ms
 * @returns {Promise<void>}
 */
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Poll the native mesh until the named application and (optionally)
 * API become visible, or until the timeout expires.
 *
 * The native lookup uses a local cache that is updated by network
 * broadcasts. On a self-connected (single-process) setup the cache
 * converges within a few hundred milliseconds. On a multi-process
 * setup it converges within a few seconds. In both cases, polling is
 * the reliable way to wait: the alternative, a fixed sleep, either
 * wastes time or races the broadcast.
 *
 * @param {string} appName
 *   Application name to wait for.
 * @param {string|null} apiName
 *   API name to wait for, or null to check only the application.
 * @param {number} timeoutMs
 *   Maximum time to wait, in milliseconds.
 * @param {number} [pollIntervalMs=100]
 *   Interval between checks.
 * @returns {Promise<boolean>}
 *   true when the target became visible, false on timeout.
 */
async function waitForApp(
    appName,
    apiName,
    timeoutMs,
    pollIntervalMs = 100
) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const appOk = lf.status.checkApp(appName);
        const apiOk = apiName === null || lf.status.checkApi(appName, apiName);
        if (appOk && apiOk) {
            return true;
        }
        await sleep(pollIntervalMs);
    }
    return false;
}

// ============================================================================
// API implementations
// ============================================================================

/**
 * Call-mode handler: add two integers from a JSON request.
 *
 * Request:   { "a": number, "b": number }
 * Response:  { "result": number }
 *
 * The handler reads the input handle with lf.io.readJson and writes
 * the output with lf.io.writeJson. Both functions handle the NUL
 * framing that the native wire format requires, so the callback body
 * only deals with plain JavaScript objects.
 *
 * @param {lf.DataHandle} input   Borrowed input handle.
 * @param {lf.DataHandle} output  Borrowed output handle.
 */
function handleAdd(input, output) {
    const req = lf.io.readJson(input) ?? {};
    const a = Number.isFinite(req.a) ? req.a : 0;
    const b = Number.isFinite(req.b) ? req.b : 0;
    lf.io.writeJson(output, { result: a + b });
}

/**
 * Call-mode handler: echo the request payload back to the caller,
 * wrapping it in a small envelope.
 *
 * Request:   any JSON value
 * Response:  { "echo": <request>, "server": "js-demo" }
 *
 * @param {lf.DataHandle} input
 * @param {lf.DataHandle} output
 */
function handleEcho(input, output) {
    const req = lf.io.readJson(input);
    lf.io.writeJson(output, {
        echo: req,
        server: "js-demo",
    });
}

/**
 * Notify-mode handler: log the payload to stdout.
 *
 * Request:   any JSON value
 * Response:  (none; Notify is one-way)
 *
 * @param {lf.DataHandle} input
 */
function handleLog(input) {
    const payload = lf.io.readJson(input);
    console.log(`[app] notify payload: ${JSON.stringify(payload)}`);
}

// ============================================================================
// Main
// ============================================================================

/**
 * Run the demo. The function is structured as a sequence of clearly
 * labelled phases so that a reader can follow the lifecycle in the
 * same order that the native library requires.
 *
 * @returns {Promise<void>}
 */
async function main() {
    console.log("=== LingoFuse JavaScript demo ===");
    console.log("");

    // -----------------------------------------------------------------
    // Phase 1 - Load the native library.
    //
    // This call is idempotent. Its only purpose is to surface a
    // missing-library error here, at a well-defined point, instead of
    // at the first unrelated native call.
    // -----------------------------------------------------------------
    console.log("[phase 1] loading the native library...");
    lf.loadLibrary();
    const env = lf.platform();
    console.log(`          runtime : ${env.runtime}`);
    console.log(`          platform: ${env.platform} / ${env.arch}`);
    console.log(`          library : ${lf.libraryName()}`);
    console.log("");

    // -----------------------------------------------------------------
    // Phase 2 - Create the application and register the APIs.
    //
    // Registrations must happen before prepareClient(). The native
    // library snapshots the API list when the application is attached
    // to a client, so an API registered afterwards would not be
    // visible on the mesh until the next broadcast.
    // -----------------------------------------------------------------
    console.log("[phase 2] creating the application and registering APIs...");
    const app = new lf.AppHandle("JsDemo", "LingoFuse JavaScript demo");

    if (!app.registerCall("add", "Add two integers", handleAdd)) {
        throw new Error("failed to register 'add'");
    }
    if (!app.registerCall("echo", "Echo the request payload", handleEcho)) {
        throw new Error("failed to register 'echo'");
    }
    if (!app.registerNotify("log", "Log a one-way payload", handleLog)) {
        throw new Error("failed to register 'log'");
    }
    console.log("          registered: add, echo (Call), log (Notify)");
    console.log("");

    // -----------------------------------------------------------------
    // Phase 3 - Prepare the framework.
    //
    // resetPrepare() clears any previous preparation queue. A single
    // "ipc:demo" endpoint is prepared as both a service and a client,
    // which makes this process self-contained.
    //
    // Wait_Ready is disabled because there is no remote peer to wait
    // for. The default (True) would block until every prepared client
    // reports ready, which is unnecessary here and would just add
    // startup latency. The trade-off is that prepareDone() now returns
    // before the mesh is necessarily usable - phase 3b below handles
    // that explicitly.
    // -----------------------------------------------------------------
    console.log("[phase 3] preparing the framework...");
    lf.framework.setOption("Wait_Ready", "False");

    lf.framework.resetPrepare();
    const serviceTag = lf.framework.prepareService("ipc:demo", "ipc:demo");
    const clientTag = lf.framework.prepareClient("ipc:demo", app);
    console.log(`          service tag: ${serviceTag}`);
    console.log(`          client tag : ${clientTag}`);

    const started = lf.framework.prepareDone();
    if (started !== 1) {
        throw new Error(
            `prepareDone() returned ${started}; expected 1.`
        );
    }
    console.log("          framework started");
    console.log("");

    // -----------------------------------------------------------------
    // Phase 3b - Wait for the application to become visible on the
    // mesh.
    //
    // Because Wait_Ready was disabled, prepareDone() returned as soon
    // as the framework's own event loop started. The client's
    // connection to the service, and the service's API-info broadcast
    // that follows, are both asynchronous. waitForApp() polls the
    // native cache until both the application and the "add" API are
    // visible, or until the timeout expires.
    //
    // This is the pattern that production code must use whenever
    // Wait_Ready is disabled: fixed sleeps either waste time or race
    // the broadcast, and a call issued too early silently times out.
    // -----------------------------------------------------------------
    console.log("[phase 3b] waiting for the application to appear on the mesh...");
    const visible = await waitForApp("JsDemo", "add", 10000);
    if (!visible) {
        throw new Error(
            "the application did not become visible within 10 seconds"
        );
    }
    console.log("          application is visible");
    console.log("");

    // -----------------------------------------------------------------
    // Phase 4 - Invoke the APIs.
    //
    // Three invocation paths are demonstrated:
    //
    //   localCall    - pure in-process, no network hop.
    //   localNotify  - pure in-process, one-way.
    //   call         - the remote path; in this single-process setup
    //                  it resolves to the same local instance.
    // -----------------------------------------------------------------

    console.log("[phase 4] invoking the APIs");
    console.log("");

    // 4a. localCall: add
    {
        console.log("  [4a] app.localCall('add', { a: 5, b: 7 })");
        const param = new lf.DataHandle("add");
        lf.io.writeJson(param, { a: 5, b: 7 });

        const result = app.localCall(param);
        const response = lf.io.readJson(result);
        console.log(`       response: ${JSON.stringify(response)}`);

        param.dispose();
        result.dispose();
        console.log("");
    }

    // 4b. localCall: echo (round-trips a structured payload)
    {
        console.log("  [4b] app.localCall('echo', { greeting: '你好', list: [1, 2, 3] })");
        const param = new lf.DataHandle("echo");
        lf.io.writeJson(param, { greeting: "你好", list: [1, 2, 3] });

        const result = app.localCall(param);
        const response = lf.io.readJson(result);
        console.log(`       response: ${JSON.stringify(response)}`);

        param.dispose();
        result.dispose();
        console.log("");
    }

    // 4c. localNotify: log
    {
        console.log("  [4c] app.localNotify('log', { level: 'info', message: 'hello' })");
        const param = new lf.DataHandle("log");
        lf.io.writeJson(param, { level: "info", message: "hello" });

        app.localNotify(param);
        param.dispose();

        // The notify callback runs on a native worker thread. A short
        // wait gives it time to complete before the next log line
        // makes the output interleaved and confusing.
        await sleep(200);
        console.log("");
    }

    // 4d. framework.call: the remote path, resolving to the local
    //     instance via the local-first optimisation.
    //
    // Because phase 3b already confirmed that the application and the
    // "add" API are visible on the mesh, this call can be issued
    // immediately without further waiting.
    {
        console.log("  [4d] framework.call('JsDemo', add, 3000)");
        const param = new lf.DataHandle("add");
        lf.io.writeJson(param, { a: 100, b: 200 });

        const result = lf.framework.call("JsDemo", param, 3000);
        if (result.size === 0) {
            console.log("       call timed out or target not found");
        } else {
            const response = lf.io.readJson(result);
            console.log(`       response: ${JSON.stringify(response)}`);
        }

        param.dispose();
        result.dispose();
        console.log("");
    }

    // -----------------------------------------------------------------
    // Phase 5 - Drain any status messages produced by the framework.
    //
    // The status queue depends on the simulated main thread, which is
    // running at this point. Draining it is optional but useful for
    // diagnostics.
    // -----------------------------------------------------------------
    console.log("[phase 5] draining the status queue");
    const messages = lf.status.drainStatus(64);
    if (messages.length === 0) {
        console.log("          (empty)");
    } else {
        for (const m of messages) {
            console.log(`          [status] ${m}`);
        }
    }
    console.log("");

    // -----------------------------------------------------------------
    // Phase 6 - Clean up.
    //
    // The documented order:
    //   1. exitMainThread   stop the simulated main thread
    //   2. app.dispose      detach the application
    //   3. shutdown         release all remaining resources
    //
    // Every handle created above has already been disposed in place,
    // so no explicit handle cleanup is needed here.
    // -----------------------------------------------------------------
    console.log("[phase 6] shutting down");
    lf.framework.exitMainThread();
    app.dispose();
    lf.framework.shutdown();
    console.log("          done");
    console.log("");
    console.log("=== demo completed successfully ===");
}

// ============================================================================
// Entry point
// ============================================================================

main().catch((err) => {
    console.error("");
    console.error("=== demo failed ===");
    console.error(err instanceof Error ? err.stack ?? err.message : String(err));
    process.exitCode = 1;
});