"use strict";

const lf = require("lingofuse-js");
const { DataHandle } = lf;

const ENDPOINT = "ipc:async_test";
const APP_NAME = "AsyncTestService";
const P2P_GROUP = "async_test_p2p_group";

const STATUS_OK = 0x00;
const STATUS_ERROR = 0xFF;

const DEBUG = typeof process !== "undefined" && process.env.LF_DEBUG === "1";

function dbg(...args) {
    if (!DEBUG) return;
    try { console.log("[SERVICE-DBG]", ...args); } catch (_) {}
}

function errMsg(e) {
    if (e === null || e === undefined) return "null";
    if (typeof e === "string") return e;
    if (e.message) return e.message;
    return String(e);
}

function hexFromUid(uid) {
    let s = "";
    for (let i = 0; i < uid.length; i++) {
        s += uid[i].toString(16).padStart(2, "0").toUpperCase();
    }
    return s;
}

function safeWriteError(outH, msg) {
    try {
        outH.size = 0;
        outH.position = 0;
        outH.writeUInt8(STATUS_ERROR);
        outH.writeString(msg);
    } catch (_) {}
}

function safeWriteOkInt32(outH, value) {
    try {
        outH.size = 0;
        outH.position = 0;
        outH.writeUInt8(STATUS_OK);
        outH.writeInt32(value);
    } catch (_) {}
}

function safeWriteOkString(outH, value) {
    try {
        outH.size = 0;
        outH.position = 0;
        outH.writeUInt8(STATUS_OK);
        outH.writeString(value);
    } catch (_) {}
}

function safeWriteOkJson(outH, value) {
    try {
        outH.size = 0;
        outH.position = 0;
        outH.writeUInt8(STATUS_OK);
        lf.io.writeJson(outH, value);
    } catch (_) {}
}

function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
}

function handleAdd(input, output) {
    let a, b;
    try {
        a = input.readInt32();
        b = input.readInt32();
    } catch (e) {
        console.log("[SERVICE] add: input truncated: " + errMsg(e));
        safeWriteError(output, "input truncated: add: " + errMsg(e));
        return;
    }
    console.log("[SERVICE] add(" + a + ", " + b + ") = " + (a + b));
    try {
        safeWriteOkInt32(output, a + b);
    } catch (e) {
        safeWriteError(output, errMsg(e));
    }
}

function handleEchoStr(input, output) {
    let s;
    try {
        s = input.readString();
    } catch (e) {
        console.log("[SERVICE] echo_str: input truncated: " + errMsg(e));
        safeWriteError(output, "input truncated: echo_str: " + errMsg(e));
        return;
    }
    console.log("[SERVICE] echo_str(" + JSON.stringify(s) + ")");
    try {
        safeWriteOkString(output, s);
    } catch (e) {
        safeWriteError(output, errMsg(e));
    }
}

function handleWhoAmI(input, output) {
    try {
        const uid = input.getP2PUid();
        const p2p = input.getP2PName();
        const payload = hexFromUid(uid) + "|" + p2p;
        console.log("[SERVICE] whoami -> " + payload);
        safeWriteOkString(output, payload);
    } catch (e) {
        safeWriteError(output, errMsg(e));
    }
}

function handleFailAlways(input, output) {
    console.log("[SERVICE] fail_always: returning error");
    safeWriteError(output, "intentional failure from fail_always");
}

function handleLogNotify(input) {
    try {
        const level = input.readString();
        const msg = input.readString();
        console.log("[SERVICE] log_notify(level=" + JSON.stringify(level) + ", msg=" + JSON.stringify(msg) + ")");
    } catch (e) {
        console.error("[SERVICE] log_notify error: " + errMsg(e));
    }
}

function handleAddJson(input, output) {
    try {
        const req = lf.io.readJson(input);
        const a = (req && typeof req.a === "number") ? req.a : 0;
        const b = (req && typeof req.b === "number") ? req.b : 0;
        console.log("[SERVICE] add_json(" + a + ", " + b + ") = " + (a + b));
        safeWriteOkJson(output, { result: a + b });
    } catch (e) {
        safeWriteError(output, errMsg(e));
    }
}

function handleEchoStrJson(input, output) {
    try {
        const req = lf.io.readJson(input);
        console.log("[SERVICE] echo_str_json(" + JSON.stringify(req) + ")");
        safeWriteOkJson(output, { echo: req });
    } catch (e) {
        safeWriteError(output, errMsg(e));
    }
}

async function main() {
    console.log("=== Async Test Service ===");
    console.log("[SERVICE] pid=" + process.pid);
    if (DEBUG) console.log("[SERVICE] DEBUG enabled");

    lf.framework.setCallbackErrorHandler((source, err) => {
        console.error("[SERVICE] callback error in " + source + ": " + errMsg(err));
    });

    try {
        lf.loadLibrary();
    } catch (e) {
        console.error("[SERVICE] failed to load library: " + errMsg(e));
        process.exit(1);
    }

    lf.options.setOptQuiet(false);
    lf.options.setOptShowThreadID(true);
    lf.options.setOptConsoleOutput(true);
    lf.options.setOptWaitConnectionReadyOk(false);
    lf.options.setOptOverlapConnection(true);
    lf.options.setOptP2PName(P2P_GROUP);

    await sleep(150);

    const app = new lf.AppHandle(APP_NAME, "Async test service");
    const ok =
        app.registerCall("add", "Add two ints", handleAdd) &&
        app.registerCall("echo_str", "Echo a string", handleEchoStr) &&
        app.registerCall("whoami", "Return caller uid|p2p", handleWhoAmI) &&
        app.registerCall("fail_always", "Always error", handleFailAlways) &&
        app.registerCall("add_json", "JSON add", handleAddJson) &&
        app.registerCall("echo_str_json", "JSON echo", handleEchoStrJson) &&
        app.registerNotify("log_notify", "Log notify", handleLogNotify);

    if (!ok) {
        console.error("[SERVICE] failed to register some app APIs");
        process.exit(1);
    }
    console.log("[SERVICE] registered 6 call APIs + 1 notify API on " + APP_NAME);

    lf.registerP2PCall("add", handleAdd, "P2P add");
    lf.registerP2PCall("echo_str", handleEchoStr, "P2P echo_str");
    lf.registerP2PCall("whoami", handleWhoAmI, "P2P whoami");
    lf.registerP2PCall("fail_always", handleFailAlways, "P2P fail_always");
    lf.registerP2PNotify("log_notify", handleLogNotify, "P2P log_notify");
    console.log("[SERVICE] registered 4 P2P call APIs + 1 P2P notify API");

    lf.framework.resetPrepare();
    lf.framework.prepareService(ENDPOINT, ENDPOINT);
    lf.framework.prepareClient(ENDPOINT, app);

    const started = lf.framework.prepareDone();
    if (started !== 1 && !lf.status.checkMainThread()) {
        console.error("[SERVICE] prepareDone failed: " + started);
        process.exit(1);
    }

    const deadline = Date.now() + 10000;
    let ready = false;
    while (Date.now() < deadline) {
        if (lf.status.checkApp(APP_NAME) && lf.status.checkApi(APP_NAME, "add")) {
            ready = true;
            break;
        }
        await sleep(100);
    }
    if (!ready) {
        console.error("[SERVICE] " + APP_NAME + " not visible after 10s");
        process.exit(1);
    }

    console.log("[SERVICE] ready");
    console.log("[SERVICE] endpoint  = " + ENDPOINT);
    console.log("[SERVICE] app_name  = " + APP_NAME);
    console.log("[SERVICE] p2p_group = " + P2P_GROUP);
    console.log("[SERVICE] Press Ctrl+C to stop");

    let stopping = false;
    const shutdown = () => {
        if (stopping) return;
        stopping = true;
        console.log("[SERVICE] shutting down...");
        try { lf.network.clearNetworkEvent(); } catch (_) {}
        try { lf.AsyncBridge.shutdownInstance(); } catch (_) {}
        try { lf.framework.exitMainThread(); } catch (_) {}
        try { app.dispose(); } catch (_) {}
        try { lf.framework.shutdown(); } catch (_) {}
        process.exit(0);
    };
    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);

    const statusTimer = setInterval(() => {
        if (stopping) return;
        try {
            const messages = lf.status.drainStatus(16);
            for (const m of messages) {
                console.log("[status] " + m);
            }
        } catch (_) {}
    }, 1000);
    if (statusTimer && typeof statusTimer.unref === "function") statusTimer.unref();

    setInterval(() => {}, 1 << 30);
}

main().catch((e) => {
    console.error("[SERVICE] fatal: " + ((e && e.stack) || e));
    process.exit(1);
});