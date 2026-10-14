/**
 * @file status.js
 * @brief Status queue and health checks for the LingoFuse runtime.
 *
 * All comments and docstrings are in English.
 */

"use strict";

const { getBinding } = require("./binding");

// ============================================================================
// Module-level state
// ============================================================================

/**
 * The native function table, resolved lazily on first use.
 * @type {object|null}
 */
let _funcs = null;

/**
 * Returns the native function table, resolving it on first call.
 *
 * @returns {object}
 */
function funcs() {
    if (_funcs === null) {
        _funcs = getBinding().funcs;
    }
    return _funcs;
}

// ============================================================================
// UID normalization helper (lazy, avoids circular require at load time)
// ============================================================================

/**
 * Normalize a UID value into a 32-byte Uint8Array.
 *
 * The implementation lives in address.js, but we require it lazily
 * to avoid a load-time circular dependency between status.js and
 * address.js.
 *
 * @param {Uint8Array|Buffer|string} uid
 * @returns {Uint8Array}
 */
function normalizeUid(uid) {
    const { _normalizeUid } = require("./address");
    return _normalizeUid(uid);
}

// ============================================================================
// Status queue
// ============================================================================

/**
 * Returns the number of pending log messages in the status queue.
 *
 * @returns {number}
 */
function getStatusCount() {
    return funcs().LF_GetStatusCount();
}

/**
 * Retrieves the next log message from the status queue, or an empty
 * string when the queue is empty.
 *
 * @returns {string}
 */
function getStatus() {
    const msg = funcs().LF_GetStatus();
    return typeof msg === "string" ? msg : "";
}

/**
 * Drains up to `maxMessages` pending status messages and returns them
 * in FIFO order.
 *
 * @param {number} [maxMessages=64]
 * @returns {string[]}
 */
function drainStatus(maxMessages = 64) {
    if (typeof maxMessages !== "number") {
        throw new TypeError("drainStatus: maxMessages must be a number.");
    }
    if (!Number.isInteger(maxMessages) || maxMessages < 0) {
        throw new RangeError(
            "drainStatus: maxMessages must be a non-negative integer."
        );
    }
    if (maxMessages === 0) {
        return [];
    }

    const pending = getStatusCount();
    if (pending <= 0) {
        return [];
    }

    const count = Math.min(pending, maxMessages);
    const messages = [];

    for (let i = 0; i < count; i++) {
        const msg = getStatus();
        if (msg.length === 0) {
            break;
        }
        messages.push(msg);
    }

    return messages;
}

/**
 * Injects a custom log message into the status queue.
 *
 * @param {string} message
 */
function postStatus(message) {
    if (typeof message !== "string") {
        throw new TypeError("postStatus: message must be a string.");
    }
    funcs().LF_PostStatus(message);
}

// ============================================================================
// Health checks
// ============================================================================

/**
 * Returns true when the simulated main thread is currently running.
 *
 * @returns {boolean}
 */
function checkMainThread() {
    return funcs().LF_CheckMainThread() !== 0;
}

/**
 * Probes whether an application with the given name is available.
 *
 * @param {string} appName
 * @returns {boolean}
 */
function checkApp(appName) {
    if (typeof appName !== "string") {
        throw new TypeError("checkApp: appName must be a string.");
    }
    return funcs().LF_CheckApp(appName) !== 0;
}

/**
 * Probes whether the named API is available for the given application.
 *
 * @param {string} appName
 * @param {string} apiName
 * @returns {boolean}
 */
function checkApi(appName, apiName) {
    if (typeof appName !== "string") {
        throw new TypeError("checkApi: appName must be a string.");
    }
    if (typeof apiName !== "string") {
        throw new TypeError("checkApi: apiName must be a string.");
    }
    return funcs().LF_CheckApi(appName, apiName) !== 0;
}

// ============================================================================
// UID / P2PName health checks
// ============================================================================

/**
 * Check whether a client with the given UID is currently known to the
 * mesh (locally or via the cached remote view).
 *
 * @param {Uint8Array|Buffer|string} uid
 * @returns {boolean}
 */
function checkUid(uid) {
    const uidBytes = normalizeUid(uid);
    return funcs().LF_Check_UID({ bytes: uidBytes }) !== 0;
}

/**
 * Check whether a client with the given UID exposes the named API.
 *
 * @param {Uint8Array|Buffer|string} uid
 * @param {string} apiName
 * @returns {boolean}
 */
function checkUidApi(uid, apiName) {
    if (typeof apiName !== "string") {
        throw new TypeError("checkUidApi: apiName must be a string.");
    }
    const uidBytes = normalizeUid(uid);
    return funcs().LF_Check_UID_Api({ bytes: uidBytes }, apiName) !== 0;
}

/**
 * Check whether at least one client has the given P2P group name.
 *
 * @param {string} p2pName
 * @returns {boolean}
 */
function checkP2PName(p2pName) {
    if (typeof p2pName !== "string") {
        throw new TypeError("checkP2PName: p2pName must be a string.");
    }
    return funcs().LF_Check_P2PNAME(p2pName) !== 0;
}

/**
 * Check whether at least one client in the given P2P group exposes the
 * named API.
 *
 * @param {string} p2pName
 * @param {string} apiName
 * @returns {boolean}
 */
function checkP2PNameApi(p2pName, apiName) {
    if (typeof p2pName !== "string") {
        throw new TypeError("checkP2PNameApi: p2pName must be a string.");
    }
    if (typeof apiName !== "string") {
        throw new TypeError("checkP2PNameApi: apiName must be a string.");
    }
    return funcs().LF_Check_P2PNAME_Api(p2pName, apiName) !== 0;
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
    // Status queue
    getStatusCount,
    getStatus,
    drainStatus,
    postStatus,

    // Health checks
    checkMainThread,
    checkApp,
    checkApi,

    // UID / P2PName health checks
    checkUid,
    checkUidApi,
    checkP2PName,
    checkP2PNameApi,
};