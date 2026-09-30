// =============================================================================
//  examples/hello-world.ts
// -----------------------------------------------------------------------------
//  End-to-end demonstration of the LingoFuse TypeScript binding.
//
//  Registers two APIs ("add" and "echo"), connects as a self-talking
//  client, waits for the application to become visible on the mesh,
//  then invokes the APIs through three paths:
//
//      app.localCall    in-process, no network hop
//      app.localNotify  in-process, one-way
//      framework.call   network-routed, resolves to the same local instance
//
//  Run:
//      npx tsx examples/hello-world.ts
//      bun run examples/hello-world.ts
//      deno run --allow-ffi --allow-read --allow-env --allow-net --allow-sys \
//          examples/hello-world.ts
// =============================================================================

import * as lf from "../src/index";
import { DataHandle } from "../src/index";

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForApp(
    appName: string,
    apiName: string | null,
    timeoutMs: number,
): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        const appOk = lf.status.checkApp(appName);
        const apiOk = apiName === null || lf.status.checkApi(appName, apiName);
        if (appOk && apiOk) return true;
        await sleep(100);
    }
    return false;
}

function handleAdd(input: DataHandle, output: DataHandle): void {
    const req = lf.io.readJson<{ a?: number; b?: number }>(input) ?? {};
    const a = typeof req.a === "number" ? req.a : 0;
    const b = typeof req.b === "number" ? req.b : 0;
    lf.io.writeJson(output, { result: a + b });
}

function handleEcho(input: DataHandle, output: DataHandle): void {
    const req = lf.io.readJson<unknown>(input);
    lf.io.writeJson(output, { echo: req, server: "ts-demo" });
}

function handleLog(input: DataHandle): void {
    const payload = lf.io.readJson<unknown>(input);
    console.log(`[App] notify payload: ${JSON.stringify(payload)}`);
}

async function main(): Promise<void> {
    console.log("=== LingoFuse TypeScript demo ===");
    console.log("");

    lf.loadLibrary();
    const env = lf.platform();
    console.log(`[Phase 1] runtime: ${env.runtime} / ${env.platform} / ${env.arch}`);
    console.log("");

    const app = new lf.AppHandle("TsDemo", "LingoFuse TypeScript demo");
    if (!app.registerCall("add", "Add two integers", handleAdd)) {
        throw new Error("failed to register 'add'");
    }
    if (!app.registerCall("echo", "Echo the request payload", handleEcho)) {
        throw new Error("failed to register 'echo'");
    }
    if (!app.registerNotify("log", "Log a one-way payload", handleLog)) {
        throw new Error("failed to register 'log'");
    }
    console.log("[Phase 2] registered: add, echo (Call), log (Notify)");
    console.log("");

    lf.framework.setOption(lf.Option.WAIT_CONNECTION_READY_OK, lf.bool(false));
    lf.framework.resetPrepare();
    const serviceTag = lf.framework.prepareService("ipc:tsdemo", "ipc:tsdemo");
    const clientTag = lf.framework.prepareClient("ipc:tsdemo", app);
    console.log(`[Phase 3] service tag=${serviceTag}, client tag=${clientTag}`);

    const started = lf.framework.prepareDone();
    if (started !== 1) {
        throw new Error(`prepareDone() returned ${started}; expected 1.`);
    }
    console.log("");

    const visible = await waitForApp("TsDemo", "add", 10000);
    if (!visible) {
        throw new Error("the application did not become visible within 10 seconds");
    }
    console.log("[Phase 3b] application is visible on the mesh");
    console.log("");

    // 4a. localCall: add
    {
        const param = new lf.DataHandle("add");
        lf.io.writeJson(param, { a: 5, b: 7 });
        const result = app.localCall(param);
        const response = lf.io.readJson(result);
        console.log(`[Phase 4a] localCall('add', {a:5, b:7}) -> ${JSON.stringify(response)}`);
        param.dispose();
        result.dispose();
    }

    // 4b. localCall: echo (non-ASCII payload round-trip)
    {
        const param = new lf.DataHandle("echo");
        lf.io.writeJson(param, { greeting: "你好", list: [1, 2, 3] });
        const result = app.localCall(param);
        const response = lf.io.readJson(result);
        console.log(`[Phase 4b] localCall('echo', ...) -> ${JSON.stringify(response)}`);
        param.dispose();
        result.dispose();
    }

    // 4c. localNotify: log
    {
        const param = new lf.DataHandle("log");
        lf.io.writeJson(param, { level: "info", message: "hello" });
        app.localNotify(param);
        param.dispose();
        await sleep(200);
    }

    // 4d. framework.call: network path, resolves to local instance
    {
        const param = new lf.DataHandle("add");
        lf.io.writeJson(param, { a: 100, b: 200 });
        const result = lf.framework.call("TsDemo", param, 3000);
        if (result.size === 0) {
            console.log("[Phase 4d] call timed out or target not found");
        } else {
            const response = lf.io.readJson(result);
            console.log(`[Phase 4d] framework.call('TsDemo', 'add', ...) -> ${JSON.stringify(response)}`);
        }
        param.dispose();
        result.dispose();
    }
    console.log("");

    const messages = lf.status.drainStatus(64);
    if (messages.length > 0) {
        console.log("[Phase 5] status messages");
        for (const m of messages) console.log(`          ${m}`);
        console.log("");
    }

    console.log("[Phase 6] shutting down");
    lf.network.clearNetworkEvent();
    lf.framework.exitMainThread();
    app.dispose();
    lf.framework.shutdown();
    console.log("          done");
    console.log("");
    console.log("=== demo completed successfully ===");
}

main().catch((err) => {
    console.error("");
    console.error("=== demo failed ===");
    console.error(err instanceof Error ? err.stack ?? err.message : String(err));
    process.exitCode = 1;
});