"use strict";
// =============================================================================
//  framework.ts
// -----------------------------------------------------------------------------
//  Process-wide ABI facade for the LingoFuse native library.
//
//  Covers network preparation, remote invocation, runtime options,
//  application name generation, and process-wide shutdown.
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.shutdown = exports.sequencedNotify = exports.notify = exports.call = exports.generateAppName = exports.setOption = exports.exitMainThread = exports.prepareDone = exports.prepareClient = exports.prepareService = exports.resetPrepare = exports.getCallbackErrorHandler = exports.setCallbackErrorHandler = void 0;
const binding_1 = require("./binding");
const data_handle_1 = require("./data-handle");
const app_handle_1 = require("./app-handle");
const errors_1 = require("./errors");
let _funcs = null;
function funcs() {
    if (_funcs === null)
        _funcs = (0, binding_1.getBinding)().funcs;
    return _funcs;
}
let _callbackErrorHandler = null;
/** Install a callback error handler. Pass null to remove it. */
function setCallbackErrorHandler(fn) {
    if (fn !== null && typeof fn !== "function") {
        throw new TypeError("setCallbackErrorHandler: fn must be a function or null.");
    }
    _callbackErrorHandler = fn;
}
exports.setCallbackErrorHandler = setCallbackErrorHandler;
/** Read the currently installed callback error handler. */
function getCallbackErrorHandler() {
    return _callbackErrorHandler;
}
exports.getCallbackErrorHandler = getCallbackErrorHandler;
function reportCallbackError(source, err) {
    if (_callbackErrorHandler !== null) {
        try {
            _callbackErrorHandler(source, err);
        }
        catch {
            // A broken handler must not escape into the native worker.
        }
    }
    try {
        const wrapped = err instanceof Error ? err : new errors_1.LingoFuseCallbackError(source, err);
        const detail = wrapped.stack ?? wrapped.message;
        process.stderr.write(`[LingoFuse] Callback error in ${source}: ${detail}\n`);
    }
    catch {
        // stderr may be unavailable. Ignore.
    }
}
// Wire the handler into app-handle's module-level reporter.
(0, app_handle_1.setCallbackErrorReporter)(reportCallbackError);
// -----------------------------------------------------------------------------
//  Timeout normalization
// -----------------------------------------------------------------------------
function normaliseTimeout(value) {
    let v;
    if (typeof value === "bigint") {
        v = value;
    }
    else if (typeof value === "number" && Number.isFinite(value)) {
        if (!Number.isInteger(value)) {
            throw new RangeError("Timeout must be an integer number of milliseconds.");
        }
        v = BigInt(value);
    }
    else {
        throw new TypeError("Timeout must be a number or a BigInt.");
    }
    if (v < 0n)
        throw new RangeError("Timeout must be non-negative.");
    const UINT64_MAX = (1n << 64n) - 1n;
    if (v > UINT64_MAX)
        throw new RangeError("Timeout exceeds the 64-bit unsigned range.");
    return v;
}
// -----------------------------------------------------------------------------
//  Network preparation
// -----------------------------------------------------------------------------
/** Clear any previously prepared services and clients. */
function resetPrepare() {
    funcs().LF_ResetPrepare();
}
exports.resetPrepare = resetPrepare;
/** Prepare a C4 service listening on listeningAddr and advertised as physicsAddr. */
function prepareService(listeningAddr, physicsAddr) {
    if (typeof listeningAddr !== "string") {
        throw new TypeError("prepareService: listeningAddr must be a string.");
    }
    if (typeof physicsAddr !== "string") {
        throw new TypeError("prepareService: physicsAddr must be a string.");
    }
    return funcs().LF_PrepareService(listeningAddr, physicsAddr);
}
exports.prepareService = prepareService;
/** Prepare a C4 client connecting to physicsAddr and optionally exposing app. */
function prepareClient(physicsAddr, app = null) {
    if (typeof physicsAddr !== "string") {
        throw new TypeError("prepareClient: physicsAddr must be a string.");
    }
    if (app !== null && !(app instanceof app_handle_1.AppHandle)) {
        throw new TypeError("prepareClient: app must be an AppHandle or null.");
    }
    const rawApp = app === null ? null : app.raw;
    return funcs().LF_PrepareClient(physicsAddr, rawApp);
}
exports.prepareClient = prepareClient;
/** Start the framework. Returns 1 on success; 0 on a repeated call. */
function prepareDone() {
    return funcs().LF_PrepareDone();
}
exports.prepareDone = prepareDone;
/** Request the simulated main thread to exit. */
function exitMainThread() {
    funcs().LF_ExitMainThread();
}
exports.exitMainThread = exitMainThread;
// -----------------------------------------------------------------------------
//  Runtime options
// -----------------------------------------------------------------------------
/** Adjust a global runtime option. Unknown option names are silently ignored. */
function setOption(option, value) {
    if (typeof option !== "string") {
        throw new TypeError("setOption: option must be a string.");
    }
    if (typeof value !== "string") {
        throw new TypeError("setOption: value must be a string.");
    }
    funcs().LF_SetOption(option, value);
}
exports.setOption = setOption;
// -----------------------------------------------------------------------------
//  Application name
// -----------------------------------------------------------------------------
/**
 * Generate a globally unique application name.
 *
 * Must be called after prepareDone() has returned 1. The native function
 * returns a pointer valid for approximately 5 seconds; this wrapper
 * copies the string immediately.
 */
function generateAppName() {
    const name = funcs().LF_Generate_AppName();
    return typeof name === "string" ? name : "";
}
exports.generateAppName = generateAppName;
// -----------------------------------------------------------------------------
//  Remote invocation
// -----------------------------------------------------------------------------
/**
 * Perform a synchronous remote call. On timeout or failure, the
 * returned handle has size 0 (it is never null).
 */
function call(appName, param, timeoutMs = 5000) {
    if (typeof appName !== "string") {
        throw new TypeError("call: appName must be a string.");
    }
    if (!(param instanceof data_handle_1.DataHandle)) {
        throw new TypeError("call: param must be a DataHandle.");
    }
    const timeout = normaliseTimeout(timeoutMs);
    const result = funcs().LF_Call(appName, param.raw, timeout);
    if (result === null || result === undefined) {
        throw new errors_1.LingoFuseCallError("LF_Call returned a null handle.", { targetApp: appName });
    }
    return data_handle_1.DataHandle.fromRaw(result, true);
}
exports.call = call;
/** Send a one-way Notify. Delivery order is not guaranteed. */
function notify(appName, param) {
    if (typeof appName !== "string") {
        throw new TypeError("notify: appName must be a string.");
    }
    if (!(param instanceof data_handle_1.DataHandle)) {
        throw new TypeError("notify: param must be a DataHandle.");
    }
    funcs().LF_Notify(appName, param.raw);
}
exports.notify = notify;
/** Send a one-way notification with FIFO ordering per (app, api) pair. */
function sequencedNotify(appName, param) {
    if (typeof appName !== "string") {
        throw new TypeError("sequencedNotify: appName must be a string.");
    }
    if (!(param instanceof data_handle_1.DataHandle)) {
        throw new TypeError("sequencedNotify: param must be a DataHandle.");
    }
    funcs().LF_Sequenced_Notify(appName, param.raw);
}
exports.sequencedNotify = sequencedNotify;
// -----------------------------------------------------------------------------
//  Shutdown
// -----------------------------------------------------------------------------
/** Gracefully terminate the framework, releasing all resources. */
function shutdown() {
    funcs().LF_Shutdown();
}
exports.shutdown = shutdown;
//# sourceMappingURL=framework.js.map