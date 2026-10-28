"use strict";

const lf = require("lingofuse-js");
const { DataHandle } = lf;
const _binding = lf._binding;
const funcs = _binding.getBinding().funcs;
const asyncSupport = lf.async;

const ENDPOINT = "ipc:async_test";
const SERVICE_APP = "AsyncTestService";
const CLIENT_APP = "AsyncTestClient";
const P2P_GROUP = "async_test_p2p_group";
const CLIENT_P2P_GROUP = "async_test_client_p2p";

const STATUS_OK = 0x00;
const STATUS_ERROR = 0xFF;
const DEFAULT_TIMEOUT_MS = 5000;
const TEST_LEVEL_TIMEOUT_MS = 10000;
const WATCHDOG_MS = 180000;

let _pass = 0;
let _fail = 0;
let _skip = 0;
let _selfUid = null;
let _clientApp = null;
let _frameworkReady = false;
let _stopping = false;

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

function parseUidHex(hex) {
    const out = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
        out[i] = parseInt(hex.substr(i * 2, 2), 16);
    }
    return out;
}

function wrapUid(uid) {
    if (uid instanceof Uint8Array) {
        if (uid.length !== 32) throw new RangeError("uid must be 32 bytes, got " + uid.length);
        return { bytes: new Uint8Array(uid) };
    }
    if (typeof uid === "string") {
        if (uid.length !== 64) throw new RangeError("uid hex must be 64 chars, got " + uid.length);
        return { bytes: parseUidHex(uid) };
    }
    throw new TypeError("uid must be Uint8Array(32) or 64-char hex string");
}

function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
}

function reportPass(label, value) {
    _pass++;
    if (value !== undefined && value !== "") {
        console.log("[PASS] " + label + " = " + String(value));
    } else {
        console.log("[PASS] " + label);
    }
}

function reportFail(label, reason) {
    _fail++;
    console.log("[FAIL] " + label + " -- " + String(reason));
}

function reportSkip(label, reason) {
    _skip++;
    console.log("[SKIP] " + label + " -- " + String(reason));
}

function readStatusThen(apiName, h) {
    if (h.size === 0) {
        throw new Error("[" + apiName + "] empty response (timeout or not found)");
    }
    h.position = 0;
    const status = h.readUInt8();
    if (status === STATUS_OK) {
        return null;
    }
    let msg = "<unreadable>";
    try { msg = h.readString(); } catch (_) {}
    throw new Error("[" + apiName + "] remote error: " + msg);
}

function makeI32Deserializer(apiName) {
    return function (rawResult) {
        if (!rawResult) throw new Error("[" + apiName + "] null response");
        const h = DataHandle.fromRaw(rawResult, false);
        readStatusThen(apiName, h);
        return h.readInt32();
    };
}

function makeStringDeserializer(apiName) {
    return function (rawResult) {
        if (!rawResult) throw new Error("[" + apiName + "] null response");
        const h = DataHandle.fromRaw(rawResult, false);
        readStatusThen(apiName, h);
        return h.readString();
    };
}

function makeJsonDeserializer(apiName) {
    return function (rawResult) {
        if (!rawResult) throw new Error("[" + apiName + "] null response");
        const h = DataHandle.fromRaw(rawResult, false);
        readStatusThen(apiName, h);
        return lf.io.readJson(h);
    };
}

function buildParamI32(apiName, values) {
    const param = new DataHandle(apiName);
    for (const v of values) param.writeInt32(v);
    return param;
}

function buildParamString(apiName, values) {
    const param = new DataHandle(apiName);
    for (const v of values) param.writeString(v);
    return param;
}

function buildParamEmpty(apiName) {
    return new DataHandle(apiName);
}

function raceTest(promise, timeoutMs) {
    let timer = null;
    const timerPromise = new Promise((_, rej) => {
        timer = setTimeout(
            () => rej(new Error("test level timeout after " + timeoutMs + "ms")),
            timeoutMs
        );
    });
    return Promise.race([promise, timerPromise]).then(
        (v) => {
            if (timer) clearTimeout(timer);
            return v;
        },
        (e) => {
            if (timer) clearTimeout(timer);
            throw e;
        }
    );
}

function safeDispose(param) {
    try { param.dispose(); } catch (_) {}
}

function attachDispose(promise, param) {
    if (promise && typeof promise.then === "function") {
        promise.then(
            () => safeDispose(param),
            () => safeDispose(param)
        );
    }
}

function handleTestEchoStr(input, output) {
    let s;
    try {
        s = input.readString();
    } catch (e) {
        try {
            output.size = 0;
            output.position = 0;
            output.writeUInt8(STATUS_ERROR);
            output.writeString("input truncated: test_echo_str");
        } catch (_) {}
        return;
    }
    try {
        output.size = 0;
        output.position = 0;
        output.writeUInt8(STATUS_OK);
        output.writeString(s);
    } catch (_) {}
}

function handleTestEchoStrJson(input, output) {
    try {
        const req = lf.io.readJson(input);
        output.size = 0;
        output.position = 0;
        output.writeUInt8(STATUS_OK);
        lf.io.writeJson(output, { echo: req });
    } catch (e) {
        try {
            output.size = 0;
            output.position = 0;
            output.writeUInt8(STATUS_ERROR);
            output.writeString(errMsg(e));
        } catch (_) {}
    }
}

async function probeSelfIdentity() {
    const param = new DataHandle("whoami");
    try {
        const res = lf.framework.call(SERVICE_APP, param, 5000);
        try {
            if (res.size === 0) {
                console.log("[INFO] whoami returned empty");
                return false;
            }
            res.position = 0;
            const status = res.readUInt8();
            if (status !== STATUS_OK) {
                const msg = res.readString();
                console.log("[INFO] whoami remote error: " + msg);
                return false;
            }
            const payload = res.readString();
            const parts = payload.split("|");
            const uidHex = parts[0];
            const p2p = parts[1] || "";
            if (uidHex.length === 64) {
                _selfUid = parseUidHex(uidHex);
                console.log("[INFO] self uid = " + uidHex);
                console.log("[INFO] self p2p = " + p2p);
                return true;
            }
            console.log("[INFO] unexpected whoami payload: " + JSON.stringify(payload));
        } finally {
            try { res.dispose(); } catch (_) {}
        }
    } catch (e) {
        console.log("[INFO] whoami probe failed: " + errMsg(e));
    } finally {
        try { param.dispose(); } catch (_) {}
    }
    return false;
}

async function testAppAsyncI32(label, apiName, args, expected) {
    const param = buildParamI32(apiName, args);
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_Async_Call(SERVICE_APP, param.raw, op.dataPtr, cb),
            makeI32Deserializer(apiName),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v === expected) reportPass(label, v);
        else reportFail(label, "expected " + expected + " got " + v);
    } catch (e) {
        safeDispose(param);
        reportFail(label, errMsg(e));
    }
}

async function testAppAsyncSequencedI32(label, apiName, args, expected) {
    const param = buildParamI32(apiName, args);
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_Async_Sequenced_Call(SERVICE_APP, param.raw, op.dataPtr, cb),
            makeI32Deserializer(apiName),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v === expected) reportPass(label, v);
        else reportFail(label, "expected " + expected + " got " + v);
    } catch (e) {
        safeDispose(param);
        reportFail(label, errMsg(e));
    }
}

async function testAppAsyncString(label, apiName, args, expected) {
    const param = buildParamString(apiName, args);
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_Async_Call(SERVICE_APP, param.raw, op.dataPtr, cb),
            makeStringDeserializer(apiName),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v === expected) reportPass(label, JSON.stringify(v));
        else reportFail(label, "expected " + JSON.stringify(expected) + " got " + JSON.stringify(v));
    } catch (e) {
        safeDispose(param);
        reportFail(label, errMsg(e));
    }
}

async function testAppAsyncRemoteError() {
    const param = buildParamEmpty("fail_always");
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_Async_Call(SERVICE_APP, param.raw, op.dataPtr, cb),
            makeI32Deserializer("fail_always"),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        reportFail("fail_always(app async remote error)", "should have thrown");
    } catch (e) {
        safeDispose(param);
        const m = errMsg(e);
        if (m.indexOf("intentional failure") >= 0) {
            reportPass("fail_always(app async remote error)", m);
        } else {
            reportFail("fail_always(app async remote error)", "unexpected: " + m);
        }
    }
}

async function testAppAsyncNoSuchApp() {
    const param = buildParamI32("add", [1, 2]);
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_Async_Call("DefinitelyNotAnApp_xyz", param.raw, op.dataPtr, cb),
            makeI32Deserializer("add"),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        reportFail("add(no such app async)", "should have failed");
    } catch (e) {
        safeDispose(param);
        const name = (e && e.name) || "";
        if (name === "LingoFuseTimeoutError" || name === "LingoFuseError" || name === "Error") {
            reportPass("add(no such app async)", "rejected as expected (" + name + ")");
        } else {
            reportFail("add(no such app async)", "wrong error: " + errMsg(e));
        }
    }
}

async function testAppAsyncJson() {
    const param = new DataHandle("add_json");
    try {
        lf.io.writeJson(param, { a: 5, b: 7 });
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_Async_Call(SERVICE_APP, param.raw, op.dataPtr, cb),
            makeJsonDeserializer("add_json"),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v && v.result === 12) reportPass("add_json(app async)", JSON.stringify(v));
        else reportFail("add_json(app async)", "unexpected: " + JSON.stringify(v));
    } catch (e) {
        safeDispose(param);
        reportFail("add_json(app async)", errMsg(e));
    }
}

async function testUidAsync() {
    if (!_selfUid) { reportSkip("test_echo_str(uid async)", "no self uid"); return; }
    const param = buildParamString("test_echo_str", ["hello via uid async"]);
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_UID_Async_Call(wrapUid(_selfUid), param.raw, op.dataPtr, cb),
            makeStringDeserializer("test_echo_str"),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v === "hello via uid async") reportPass("test_echo_str(uid async)", JSON.stringify(v));
        else reportFail("test_echo_str(uid async)", "unexpected: " + JSON.stringify(v));
    } catch (e) {
        safeDispose(param);
        reportFail("test_echo_str(uid async)", errMsg(e));
    }
}

async function testUidAsyncSequenced() {
    if (!_selfUid) { reportSkip("test_echo_str(uid async seq)", "no self uid"); return; }
    const param = buildParamString("test_echo_str", ["hello via uid async seq"]);
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_UID_Async_Sequenced_Call(wrapUid(_selfUid), param.raw, op.dataPtr, cb),
            makeStringDeserializer("test_echo_str"),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v === "hello via uid async seq") reportPass("test_echo_str(uid async seq)", JSON.stringify(v));
        else reportFail("test_echo_str(uid async seq)", "unexpected: " + JSON.stringify(v));
    } catch (e) {
        safeDispose(param);
        reportFail("test_echo_str(uid async seq)", errMsg(e));
    }
}

async function testP2PNameAsync() {
    const param = buildParamI32("add", [3, 4]);
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_P2PNAME_Async_Call(P2P_GROUP, param.raw, op.dataPtr, cb),
            makeI32Deserializer("add"),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v === 7) reportPass("add(p2pname async)", v);
        else reportFail("add(p2pname async)", "expected 7 got " + v);
    } catch (e) {
        safeDispose(param);
        reportFail("add(p2pname async)", errMsg(e));
    }
}

async function testP2PNameAsyncSequenced() {
    const param = buildParamString("echo_str", ["hello via p2pname seq"]);
    try {
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_P2PNAME_Async_Sequenced_Call(P2P_GROUP, param.raw, op.dataPtr, cb),
            makeStringDeserializer("echo_str"),
            DEFAULT_TIMEOUT_MS
        );
        attachDispose(promise, param);
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v === "hello via p2pname seq") reportPass("echo_str(p2pname async seq)", JSON.stringify(v));
        else reportFail("echo_str(p2pname async seq)", "unexpected: " + JSON.stringify(v));
    } catch (e) {
        safeDispose(param);
        reportFail("echo_str(p2pname async seq)", errMsg(e));
    }
}

async function testConcurrent() {
    const count = 10;
    const params = [];
    const promises = [];
    try {
        for (let i = 0; i < count; i++) {
            const p = buildParamI32("add", [i, i * 2]);
            params.push(p);
            const promise = asyncSupport.runAsyncWithPromise(
                (cb, op) => funcs.LF_Async_Call(SERVICE_APP, p.raw, op.dataPtr, cb),
                makeI32Deserializer("add"),
                DEFAULT_TIMEOUT_MS
            );
            promises.push(promise);
        }
        for (let i = 0; i < count; i++) {
            attachDispose(promises[i], params[i]);
        }
        const results = await raceTest(Promise.all(promises), TEST_LEVEL_TIMEOUT_MS);
        const mismatches = [];
        for (let i = 0; i < count; i++) {
            const expected = i + i * 2;
            if (results[i] !== expected) {
                mismatches.push("[" + i + "] expected " + expected + " got " + results[i]);
            }
        }
        if (mismatches.length === 0) reportPass("concurrent 10x add(app async)", "all matched");
        else reportFail("concurrent 10x add(app async)", mismatches.join("; "));
    } catch (e) {
        for (const p of params) { safeDispose(p); }
        reportFail("concurrent 10x add(app async)", errMsg(e));
    }
}

async function testAppTargetCall() {
    try {
        const t = new lf.AppTarget(SERVICE_APP);
        const result = await raceTest(
            t.call("add_json", { a: 10, b: 20 }, { timeoutMs: DEFAULT_TIMEOUT_MS }),
            TEST_LEVEL_TIMEOUT_MS
        );
        if (result && result.result === 30) reportPass("AppTarget.call(add_json)", JSON.stringify(result));
        else reportFail("AppTarget.call(add_json)", "unexpected: " + JSON.stringify(result));
    } catch (e) {
        reportFail("AppTarget.call(add_json)", errMsg(e));
    }
}

async function testAppTargetSequencedCall() {
    try {
        const t = new lf.AppTarget(SERVICE_APP);
        const result = await raceTest(
            t.sequencedCall("add_json", { a: 40, b: 2 }, { timeoutMs: DEFAULT_TIMEOUT_MS }),
            TEST_LEVEL_TIMEOUT_MS
        );
        if (result && result.result === 42) reportPass("AppTarget.sequencedCall(add_json)", JSON.stringify(result));
        else reportFail("AppTarget.sequencedCall(add_json)", "unexpected: " + JSON.stringify(result));
    } catch (e) {
        reportFail("AppTarget.sequencedCall(add_json)", errMsg(e));
    }
}

async function testAppTargetCallSync() {
    try {
        const t = new lf.AppTarget(SERVICE_APP);
        const result = t.callSync("add_json", { a: 1, b: 2 }, { timeoutMs: DEFAULT_TIMEOUT_MS });
        if (result && result.result === 3) reportPass("AppTarget.callSync(add_json)", JSON.stringify(result));
        else reportFail("AppTarget.callSync(add_json)", "unexpected: " + JSON.stringify(result));
    } catch (e) {
        reportFail("AppTarget.callSync(add_json)", errMsg(e));
    }
}

async function testUIDTargetCall() {
    if (!_selfUid) { reportSkip("UIDTarget.call(test_echo_str_json)", "no self uid"); return; }
    try {
        const t = new lf.UIDTarget(_selfUid);
        const result = await raceTest(
            t.call("test_echo_str_json", { echo: "hi from uid target" }, { timeoutMs: DEFAULT_TIMEOUT_MS }),
            TEST_LEVEL_TIMEOUT_MS
        );
        if (result && result.echo && result.echo.echo === "hi from uid target") {
            reportPass("UIDTarget.call(test_echo_str_json)", JSON.stringify(result));
        } else {
            reportFail("UIDTarget.call(test_echo_str_json)", "unexpected: " + JSON.stringify(result));
        }
    } catch (e) {
        reportFail("UIDTarget.call(test_echo_str_json)", errMsg(e));
    }
}

async function testP2PNameTargetCall() {
    try {
        const t = new lf.P2PNameTarget(P2P_GROUP);
        const result = await raceTest(
            t.call("echo_str_json", { hello: "world" }, { timeoutMs: DEFAULT_TIMEOUT_MS }),
            TEST_LEVEL_TIMEOUT_MS
        );
        if (result && result.echo && result.echo.hello === "world") {
            reportPass("P2PNameTarget.call(echo_str_json)", JSON.stringify(result));
        } else {
            reportFail("P2PNameTarget.call(echo_str_json)", "unexpected: " + JSON.stringify(result));
        }
    } catch (e) {
        reportFail("P2PNameTarget.call(echo_str_json)", errMsg(e));
    }
}

async function testAsyncBridgeStats() {
    try {
        const bridge = lf.AsyncBridge.instance();
        const before = bridge.stats();
        const param = buildParamI32("add", [1, 1]);
        try {
            const promise = asyncSupport.runAsyncWithPromise(
                (cb, op) => funcs.LF_Async_Call(SERVICE_APP, param.raw, op.dataPtr, cb),
                makeI32Deserializer("add"),
                DEFAULT_TIMEOUT_MS
            );
            attachDispose(promise, param);
            const during = bridge.stats();
            const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
            await sleep(300);
            const after = bridge.stats();
            const dispatched = during.total > before.total;
            const completed = after.released_total >= before.released_total;
            if (v === 2 && dispatched && completed) {
                reportPass("AsyncBridge stats", "before=" + JSON.stringify(before) + " during=" + JSON.stringify(during) + " after=" + JSON.stringify(after));
            } else {
                reportFail("AsyncBridge stats",
                    "v=" + v + " dispatched=" + dispatched + " completed=" + completed
                    + " before=" + JSON.stringify(before)
                    + " during=" + JSON.stringify(during)
                    + " after=" + JSON.stringify(after));
            }
        } catch (e) {
            safeDispose(param);
            reportFail("AsyncBridge stats", errMsg(e));
        }
    } catch (e) {
        reportFail("AsyncBridge stats", errMsg(e));
    }
}

async function testShortLivedParam() {
    try {
        const p1 = buildParamI32("add", [100, 200]);
        const promise = asyncSupport.runAsyncWithPromise(
            (cb, op) => funcs.LF_Async_Call(SERVICE_APP, p1.raw, op.dataPtr, cb),
            makeI32Deserializer("add"),
            DEFAULT_TIMEOUT_MS
        );
        p1.dispose();
        const v = await raceTest(promise, TEST_LEVEL_TIMEOUT_MS);
        if (v === 300) reportPass("short-lived param", v);
        else reportFail("short-lived param", "expected 300 got " + v);
    } catch (e) {
        reportFail("short-lived param", errMsg(e));
    }
}

async function testNotifyP2PDispatched() {
    const param = new DataHandle("log_notify");
    try {
        param.writeString("INFO");
        param.writeString("hello from notify p2p");
        try {
            lf.framework.p2pnameNotify(P2P_GROUP, param);
            reportPass("log_notify(p2pname notify)", "dispatched");
        } catch (e) {
            reportFail("log_notify(p2pname notify)", errMsg(e));
        }
    } finally {
        try { param.dispose(); } catch (_) {}
    }
}

async function testSequencedNotifyDispatched() {
    const param = new DataHandle("log_notify");
    try {
        param.writeString("INFO");
        param.writeString("hello from sequenced notify");
        try {
            lf.framework.sequencedNotify(SERVICE_APP, param);
            reportPass("log_notify(sequenced notify)", "dispatched");
        } catch (e) {
            reportFail("log_notify(sequenced notify)", errMsg(e));
        }
    } finally {
        try { param.dispose(); } catch (_) {}
    }
}

async function cleanup() {
    if (_stopping) return;
    _stopping = true;
    console.log("");
    console.log("[CALL] cleanup...");

    try { lf.AsyncBridge.shutdownInstance(); } catch (_) {}

    await sleep(3000);

    try { lf.network.clearNetworkEvent(); } catch (_) {}
    try { lf.framework.exitMainThread(); } catch (_) {}
    try { if (_clientApp) _clientApp.dispose(); } catch (_) {}
    try { lf.framework.shutdown(); } catch (_) {}

    console.log("[CALL] cleanup done");
}

async function runAll() {
    console.log("=== Async Test Call ===");
    console.log("");

    lf.framework.setCallbackErrorHandler((source, err) => {
        console.error("[CALL] callback error in " + source + ": " + errMsg(err));
    });

    try { lf.loadLibrary(); }
    catch (e) { console.error("[CALL] failed to load library: " + errMsg(e)); process.exit(1); }

    lf.options.setOptQuiet(false);
    lf.options.setOptShowThreadID(true);
    lf.options.setOptConsoleOutput(true);
    lf.options.setOptWaitConnectionReadyOk(false);
    lf.options.setOptOverlapConnection(true);
    lf.options.setOptP2PName(CLIENT_P2P_GROUP);

    await sleep(150);

    _clientApp = new lf.AppHandle(CLIENT_APP, "Async test client");
    if (!_clientApp.registerCall("test_echo_str", "Echo string", handleTestEchoStr)) {
        console.error("[CALL] failed to register test_echo_str");
        process.exit(1);
    }
    if (!_clientApp.registerCall("test_echo_str_json", "Echo JSON", handleTestEchoStrJson)) {
        console.error("[CALL] failed to register test_echo_str_json");
        process.exit(1);
    }
    console.log("[CALL] registered 2 client test APIs on " + CLIENT_APP);

    lf.framework.resetPrepare();
    lf.framework.prepareClient(ENDPOINT, _clientApp);

    const started = lf.framework.prepareDone();
    if (started !== 1 && !lf.status.checkMainThread()) {
        console.error("[CALL] prepareDone failed: " + started);
        process.exit(1);
    }

    const deadline = Date.now() + 10000;
    let ready = false;
    while (Date.now() < deadline) {
        if (lf.status.checkApp(SERVICE_APP) && lf.status.checkApi(SERVICE_APP, "add")) {
            ready = true;
            break;
        }
        await sleep(100);
    }
    if (!ready) {
        console.error("[CALL] " + SERVICE_APP + " not visible after 10s");
        await cleanup();
        process.exit(1);
    }
    _frameworkReady = true;

    console.log("[CALL] ready");
    console.log("[CALL] endpoint  = " + ENDPOINT);
    console.log("[CALL] service   = " + SERVICE_APP);
    console.log("[CALL] client    = " + CLIENT_APP);
    console.log("[CALL] p2p_group = " + P2P_GROUP);
    console.log("");

    await probeSelfIdentity();
    console.log("");

    console.log("--- App addressing (async) ---");
    await testAppAsyncI32("add(app async)", "add", [5, 7], 12);
    await testAppAsyncSequencedI32("add(app async seq)", "add", [8, 9], 17);
    await testAppAsyncString("echo_str(app async)", "echo_str", ["hello"], "hello");
    await testAppAsyncJson();
    await testAppAsyncRemoteError();
    await testAppAsyncNoSuchApp();
    console.log("");

    console.log("--- UID addressing (async) ---");
    await testUidAsync();
    await testUidAsyncSequenced();
    console.log("");

    console.log("--- P2PName addressing (async) ---");
    await testP2PNameAsync();
    await testP2PNameAsyncSequenced();
    console.log("");

    console.log("--- Concurrency ---");
    await testConcurrent();
    console.log("");

    console.log("--- Target classes ---");
    await testAppTargetCallSync();
    await testAppTargetCall();
    await testAppTargetSequencedCall();
    await testUIDTargetCall();
    await testP2PNameTargetCall();
    console.log("");

    console.log("--- Notify (control group, no async family) ---");
    await testSequencedNotifyDispatched();
    await testNotifyP2PDispatched();
    console.log("");

    console.log("--- Internals ---");
    await testAsyncBridgeStats();
    await testShortLivedParam();
    console.log("");

    console.log("=== Summary ===");
    console.log("Pass : " + _pass);
    console.log("Fail : " + _fail);
    console.log("Skip : " + _skip);
    console.log("Total: " + (_pass + _fail + _skip));

    await cleanup();
    process.exit(_fail === 0 ? 0 : 2);
}

let _watchdog = setTimeout(() => {
    console.error("[CALL] WATCHDOG fired after " + WATCHDOG_MS + "ms; forcing exit");
    process.exit(3);
}, WATCHDOG_MS);

process.on("SIGINT", async () => {
    console.log("");
    console.log("[CALL] SIGINT, cleanup...");
    await cleanup();
    process.exit(130);
});

runAll().catch(async (e) => {
    console.error("[CALL] fatal: " + ((e && e.stack) || e));
    try { await cleanup(); } catch (_) {}
    process.exit(1);
});