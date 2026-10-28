"use strict";

const { getBinding } = require("./binding");
const { DataHandle } = require("./data-handle");
const { AppHandle, setCallbackErrorReporter } = require("./app-handle");
const {
    LingoFuseCallError,
    LingoFuseObjectDisposedError,
} = require("./errors");

const {
    runAsyncWithPromise,
    runLegacyOp,
} = require("./async-support");
const { readJson, writeJson } = require("./lf-io");

let _funcs = null;

function funcs() {
    if (_funcs === null) {
        _funcs = getBinding().funcs;
    }
    return _funcs;
}

let callbackErrorHandler = null;

function setCallbackErrorHandler(fn) {
    if (fn !== null && typeof fn !== "function") {
        throw new TypeError(
            "setCallbackErrorHandler: fn must be a function or null."
        );
    }
    callbackErrorHandler = fn;
}

function reportCallbackError(source, err) {
    if (callbackErrorHandler) {
        try {
            callbackErrorHandler(source, err);
        } catch (_) {
        }
    }

    try {
        const detail =
            err instanceof Error
                ? err.stack ?? err.message
                : String(err);
        process.stderr.write(
            "[LingoFuse] Callback error in " + source + ": " + detail + "\n"
        );
    } catch (_) {
    }
}

setCallbackErrorReporter(reportCallbackError);

function normaliseTimeout(value) {
    let v;
    if (typeof value === "bigint") {
        v = value;
    } else if (typeof value === "number" && Number.isFinite(value)) {
        if (!Number.isInteger(value)) {
            throw new RangeError(
                "Timeout must be an integer number of milliseconds."
            );
        }
        v = BigInt(value);
    } else {
        throw new TypeError(
            "Timeout must be a number or a BigInt."
        );
    }

    if (v < 0n) {
        throw new RangeError("Timeout must be non-negative.");
    }
    const UINT64_MAX = (1n << 64n) - 1n;
    if (v > UINT64_MAX) {
        throw new RangeError("Timeout exceeds the 64-bit unsigned range.");
    }
    return v;
}

function resetPrepare() {
    funcs().LF_ResetPrepare();
}

function prepareService(listeningAddr, physicsAddr) {
    if (typeof listeningAddr !== "string") {
        throw new TypeError(
            "prepareService: listeningAddr must be a string."
        );
    }
    if (typeof physicsAddr !== "string") {
        throw new TypeError(
            "prepareService: physicsAddr must be a string."
        );
    }
    return funcs().LF_PrepareService(listeningAddr, physicsAddr);
}

function prepareClient(physicsAddr, app = null) {
    if (typeof physicsAddr !== "string") {
        throw new TypeError(
            "prepareClient: physicsAddr must be a string."
        );
    }
    if (app !== null && !(app instanceof AppHandle)) {
        throw new TypeError(
            "prepareClient: app must be an AppHandle or null."
        );
    }

    const rawApp = app === null ? null : app.raw;
    return funcs().LF_PrepareClient(physicsAddr, rawApp);
}

function prepareDone() {
    return funcs().LF_PrepareDone();
}

function exitMainThread() {
    funcs().LF_ExitMainThread();
}

function setOption(option, value) {
    if (typeof option !== "string") {
        throw new TypeError("setOption: option must be a string.");
    }
    if (typeof value !== "string") {
        throw new TypeError("setOption: value must be a string.");
    }
    funcs().LF_SetOption(option, value);
}

function getOption(option) {
    if (typeof option !== "string") {
        throw new TypeError("getOption: option must be a string.");
    }
    const v = funcs().LF_GetOption(option);
    return typeof v === "string" ? v : "";
}

function generateAppName() {
    const name = funcs().LF_Generate_AppName();
    return typeof name === "string" ? name : "";
}

function getAppName(app) {
    if (!(app instanceof AppHandle)) {
        throw new TypeError("getAppName: app must be an AppHandle.");
    }
    if (!app.isValid) {
        throw new LingoFuseObjectDisposedError("AppHandle");
    }
    const name = funcs().LF_Get_AppName(app.raw);
    return typeof name === "string" ? name : "";
}

function call(appName, param, timeoutMs = 5000) {
    if (typeof appName !== "string") {
        throw new TypeError("call: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("call: param must be a DataHandle.");
    }
    const timeout = normaliseTimeout(timeoutMs);

    const result = funcs().LF_Call(appName, param.raw, timeout);
    if (result === null || result === undefined) {
        throw new LingoFuseCallError(
            "LF_Call returned a null handle.",
            { targetApp: appName, targetApi: null }
        );
    }
    return DataHandle.fromRaw(result, true);
}

function tryCall(appName, param, timeoutMs = 5000) {
    const response = call(appName, param, timeoutMs);
    if (response.size === 0) {
        response.dispose();
        return null;
    }
    return response;
}

function notify(appName, param) {
    if (typeof appName !== "string") {
        throw new TypeError("notify: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("notify: param must be a DataHandle.");
    }
    funcs().LF_Notify(appName, param.raw);
}

function sequencedNotify(appName, param) {
    if (typeof appName !== "string") {
        throw new TypeError("sequencedNotify: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("sequencedNotify: param must be a DataHandle.");
    }
    funcs().LF_Sequenced_Notify(appName, param.raw);
}

function _makeJsonDeserializer() {
    return function (rawResult) {
        if (!rawResult) return null;
        const h = DataHandle.fromRaw(rawResult, false);
        h.position = 0;
        return readJson(h);
    };
}

function _wrapUid(uid) {
    if (
        uid !== null &&
        typeof uid === "object" &&
        uid.bytes instanceof Uint8Array
    ) {
        if (uid.bytes.length !== 32) {
            throw new RangeError(
                "UID must be exactly 32 bytes, got " + uid.bytes.length + "."
            );
        }
        return uid;
    }
    if (uid instanceof Uint8Array) {
        if (uid.length !== 32) {
            throw new RangeError(
                "UID must be exactly 32 bytes, got " + uid.length + "."
            );
        }
        return { bytes: new Uint8Array(uid) };
    }
    if (typeof uid === "string") {
        const hex = uid.trim();
        if (hex.length !== 64) {
            throw new RangeError(
                "UID hex string must be exactly 64 characters, got " +
                hex.length + "."
            );
        }
        if (!/^[0-9a-fA-F]+$/.test(hex)) {
            throw new RangeError(
                "UID hex string contains non-hex characters."
            );
        }
        const bytes = new Uint8Array(32);
        for (let i = 0; i < 32; i++) {
            bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
        }
        return { bytes };
    }
    throw new TypeError(
        "UID must be a Uint8Array(32), a 64-char hex string, " +
        "or a { bytes: Uint8Array(32) } object."
    );
}

function callAsync(appName, param, onResult, userData = undefined) {
    if (typeof appName !== "string") {
        throw new TypeError("callAsync: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("callAsync: param must be a DataHandle.");
    }
    if (typeof onResult !== "function") {
        throw new TypeError("callAsync: onResult must be a function.");
    }
    return runLegacyOp(
        (cb, op) => funcs().LF_Async_Call(
            appName, param.raw, op.dataPtr, cb
        ),
        onResult,
        userData,
        _makeJsonDeserializer()
    );
}

function callPromise(appName, param, timeoutMs = 5000) {
    if (typeof appName !== "string") {
        throw new TypeError("callPromise: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("callPromise: param must be a DataHandle.");
    }
    const timeout = Number(normaliseTimeout(timeoutMs));
    return runAsyncWithPromise(
        (cb, op) => funcs().LF_Async_Call(
            appName, param.raw, op.dataPtr, cb
        ),
        _makeJsonDeserializer(),
        timeout
    );
}

function callSequencedPromise(appName, param, timeoutMs = 5000) {
    if (typeof appName !== "string") {
        throw new TypeError("callSequencedPromise: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("callSequencedPromise: param must be a DataHandle.");
    }
    const timeout = Number(normaliseTimeout(timeoutMs));
    return runAsyncWithPromise(
        (cb, op) => funcs().LF_Async_Sequenced_Call(
            appName, param.raw, op.dataPtr, cb
        ),
        _makeJsonDeserializer(),
        timeout
    );
}

function uidCall(uid, param, timeoutMs = 5000) {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidCall: param must be a DataHandle.");
    }
    const timeout = Number(normaliseTimeout(timeoutMs));
    const uidArg = _wrapUid(uid);
    const result = funcs().LF_UID_Call(uidArg, param.raw, BigInt(timeout));
    if (result === null || result === undefined) {
        throw new LingoFuseCallError("LF_UID_Call returned a null handle.");
    }
    return DataHandle.fromRaw(result, true);
}

function uidCallAsync(uid, param, onResult, userData = undefined) {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidCallAsync: param must be a DataHandle.");
    }
    if (typeof onResult !== "function") {
        throw new TypeError("uidCallAsync: onResult must be a function.");
    }
    const uidArg = _wrapUid(uid);
    return runLegacyOp(
        (cb, op) => funcs().LF_UID_Async_Call(
            uidArg, param.raw, op.dataPtr, cb
        ),
        onResult,
        userData,
        _makeJsonDeserializer()
    );
}

function uidCallPromise(uid, param, timeoutMs = 5000) {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidCallPromise: param must be a DataHandle.");
    }
    const timeout = Number(normaliseTimeout(timeoutMs));
    const uidArg = _wrapUid(uid);
    return runAsyncWithPromise(
        (cb, op) => funcs().LF_UID_Async_Call(
            uidArg, param.raw, op.dataPtr, cb
        ),
        _makeJsonDeserializer(),
        timeout
    );
}

function uidCallSequencedPromise(uid, param, timeoutMs = 5000) {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidCallSequencedPromise: param must be a DataHandle.");
    }
    const timeout = Number(normaliseTimeout(timeoutMs));
    const uidArg = _wrapUid(uid);
    return runAsyncWithPromise(
        (cb, op) => funcs().LF_UID_Async_Sequenced_Call(
            uidArg, param.raw, op.dataPtr, cb
        ),
        _makeJsonDeserializer(),
        timeout
    );
}

function uidNotify(uid, param) {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidNotify: param must be a DataHandle.");
    }
    const uidArg = _wrapUid(uid);
    funcs().LF_UID_Notify(uidArg, param.raw);
}

function uidSequencedNotify(uid, param) {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidSequencedNotify: param must be a DataHandle.");
    }
    const uidArg = _wrapUid(uid);
    funcs().LF_UID_Sequenced_Notify(uidArg, param.raw);
}

function p2pnameCall(p2pName, param, timeoutMs = 5000) {
    if (typeof p2pName !== "string") {
        throw new TypeError("p2pnameCall: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("p2pnameCall: param must be a DataHandle.");
    }
    const timeout = Number(normaliseTimeout(timeoutMs));
    const result = funcs().LF_P2PNAME_Call(
        p2pName,
        param.raw,
        BigInt(timeout)
    );
    if (result === null || result === undefined) {
        throw new LingoFuseCallError(
            "LF_P2PNAME_Call returned a null handle."
        );
    }
    return DataHandle.fromRaw(result, true);
}

function p2pnameCallAsync(p2pName, param, onResult, userData = undefined) {
    if (typeof p2pName !== "string") {
        throw new TypeError("p2pnameCallAsync: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("p2pnameCallAsync: param must be a DataHandle.");
    }
    if (typeof onResult !== "function") {
        throw new TypeError("p2pnameCallAsync: onResult must be a function.");
    }
    return runLegacyOp(
        (cb, op) => funcs().LF_P2PNAME_Async_Call(
            p2pName, param.raw, op.dataPtr, cb
        ),
        onResult,
        userData,
        _makeJsonDeserializer()
    );
}

function p2pnameCallPromise(p2pName, param, timeoutMs = 5000) {
    if (typeof p2pName !== "string") {
        throw new TypeError(
            "p2pnameCallPromise: p2pName must be a string."
        );
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "p2pnameCallPromise: param must be a DataHandle."
        );
    }
    const timeout = Number(normaliseTimeout(timeoutMs));
    return runAsyncWithPromise(
        (cb, op) => funcs().LF_P2PNAME_Async_Call(
            p2pName, param.raw, op.dataPtr, cb
        ),
        _makeJsonDeserializer(),
        timeout
    );
}

function p2pnameCallSequencedPromise(p2pName, param, timeoutMs = 5000) {
    if (typeof p2pName !== "string") {
        throw new TypeError(
            "p2pnameCallSequencedPromise: p2pName must be a string."
        );
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "p2pnameCallSequencedPromise: param must be a DataHandle."
        );
    }
    const timeout = Number(normaliseTimeout(timeoutMs));
    return runAsyncWithPromise(
        (cb, op) => funcs().LF_P2PNAME_Async_Sequenced_Call(
            p2pName, param.raw, op.dataPtr, cb
        ),
        _makeJsonDeserializer(),
        timeout
    );
}

function p2pnameNotify(p2pName, param) {
    if (typeof p2pName !== "string") {
        throw new TypeError("p2pnameNotify: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("p2pnameNotify: param must be a DataHandle.");
    }
    funcs().LF_P2PNAME_Notify(p2pName, param.raw);
}

function p2pnameSequencedNotify(p2pName, param) {
    if (typeof p2pName !== "string") {
        throw new TypeError(
            "p2pnameSequencedNotify: p2pName must be a string."
        );
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "p2pnameSequencedNotify: param must be a DataHandle."
        );
    }
    funcs().LF_P2PNAME_Sequenced_Notify(p2pName, param.raw);
}

function shutdown() {
    funcs().LF_Shutdown();
}

module.exports = {
    setCallbackErrorHandler,
    get callbackErrorHandler() {
        return callbackErrorHandler;
    },

    resetPrepare,
    prepareService,
    prepareClient,
    prepareDone,
    exitMainThread,

    setOption,
    getOption,

    generateAppName,
    getAppName,

    call,
    tryCall,
    notify,
    sequencedNotify,

    callAsync,
    callPromise,
    callSequencedPromise,

    uidCall,
    uidCallAsync,
    uidCallPromise,
    uidCallSequencedPromise,
    uidNotify,
    uidSequencedNotify,

    p2pnameCall,
    p2pnameCallAsync,
    p2pnameCallPromise,
    p2pnameCallSequencedPromise,
    p2pnameNotify,
    p2pnameSequencedNotify,

    shutdown,
};