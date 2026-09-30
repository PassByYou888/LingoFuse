"use strict";
// =============================================================================
//  status.ts
// -----------------------------------------------------------------------------
//  Status queue and health checks for the LingoFuse runtime.
//
//  The native library maintains a bounded FIFO of log messages (up to
//  1000 entries). Older entries are dropped when the buffer is full.
//
//  The status queue is processed by the native simulated main thread.
//  Before prepareDone() has been called, the queue may be empty or
//  contain stale data.
//
//  checkApp and checkApi perform cache-based lookups updated by network
//  broadcasts with an approximate 3-second delay. They are suitable for
//  probing, not for authoritative availability decisions.
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.checkApi = exports.checkApp = exports.checkMainThread = exports.postStatus = exports.drainStatus = exports.getStatus = exports.getStatusCount = void 0;
const binding_1 = require("./binding");
let _funcs = null;
function funcs() {
    if (_funcs === null)
        _funcs = (0, binding_1.getBinding)().funcs;
    return _funcs;
}
// -----------------------------------------------------------------------------
//  Status queue
// -----------------------------------------------------------------------------
/** Number of pending log messages in the status queue. */
function getStatusCount() {
    return funcs().LF_GetStatusCount();
}
exports.getStatusCount = getStatusCount;
/** Retrieve the next log message. Returns "" when the queue is empty. */
function getStatus() {
    const msg = funcs().LF_GetStatus();
    return typeof msg === "string" ? msg : "";
}
exports.getStatus = getStatus;
/**
 * Drain up to maxMessages pending status messages in FIFO order.
 * Stops early when the queue reports an empty message.
 */
function drainStatus(maxMessages = 64) {
    if (typeof maxMessages !== "number") {
        throw new TypeError("drainStatus: maxMessages must be a number.");
    }
    if (!Number.isInteger(maxMessages) || maxMessages < 0) {
        throw new RangeError("drainStatus: maxMessages must be a non-negative integer.");
    }
    if (maxMessages === 0)
        return [];
    const pending = getStatusCount();
    if (pending <= 0)
        return [];
    const count = Math.min(pending, maxMessages);
    const messages = [];
    for (let i = 0; i < count; i++) {
        const msg = getStatus();
        if (msg.length === 0)
            break;
        messages.push(msg);
    }
    return messages;
}
exports.drainStatus = drainStatus;
/** Inject a custom log message into the status queue. */
function postStatus(message) {
    if (typeof message !== "string") {
        throw new TypeError("postStatus: message must be a string.");
    }
    funcs().LF_PostStatus(message);
}
exports.postStatus = postStatus;
// -----------------------------------------------------------------------------
//  Health checks
// -----------------------------------------------------------------------------
/** True when the simulated main thread is currently running. */
function checkMainThread() {
    return funcs().LF_CheckMainThread() !== 0;
}
exports.checkMainThread = checkMainThread;
/**
 * Probe whether an application with the given name is available.
 *
 * Uses a local cache updated by network broadcasts (~3 s delay).
 * False negatives immediately after registration and false positives
 * shortly after unregistration are both normal.
 */
function checkApp(appName) {
    if (typeof appName !== "string") {
        throw new TypeError("checkApp: appName must be a string.");
    }
    return funcs().LF_CheckApp(appName) !== 0;
}
exports.checkApp = checkApp;
/** Probe whether the named API is available for the given application. */
function checkApi(appName, apiName) {
    if (typeof appName !== "string") {
        throw new TypeError("checkApi: appName must be a string.");
    }
    if (typeof apiName !== "string") {
        throw new TypeError("checkApi: apiName must be a string.");
    }
    return funcs().LF_CheckApi(appName, apiName) !== 0;
}
exports.checkApi = checkApi;
//# sourceMappingURL=status.js.map