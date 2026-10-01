/**
 * @file status.js
 * @brief Status queue and health checks for the LingoFuse runtime.
 *
 * This module wraps the diagnostic and probing surface of the native
 * library:
 *
 *   - The bounded status queue (LF_GetStatusCount / LF_GetStatus /
 *     LF_PostStatus).
 *   - The main-thread liveness check (LF_CheckMainThread).
 *   - The application and API availability probes (LF_CheckApp /
 *     LF_CheckApi).
 *
 * It mirrors the role of LingoFuseStatus.cs in the C# binding.
 *
 * ============================================================================
 * STATUS QUEUE
 * ============================================================================
 * The native library maintains a bounded FIFO of log messages, up to
 * 1000 entries. Older entries are dropped when the buffer is full.
 * Messages are surfaced through getStatusCount and getStatus, and can
 * be injected by the application through postStatus.
 *
 * ============================================================================
 * MAIN-THREAD DEPENDENCY
 * ============================================================================
 * The status queue is processed by the native simulated main thread.
 * Before prepareDone() has been called, the queue may be empty or
 * contain stale data; applications should not rely on status messages
 * during initialization.
 *
 * Injection is NOT subject to the same restriction: postStatus queues
 * the message even when the simulated main thread is not yet running.
 * The message becomes observable once the main thread starts
 * processing the queue (or immediately, if it is already running).
 *
 * ============================================================================
 * STATIC BUFFER HAZARD
 * ============================================================================
 * LF_GetStatus returns a pointer into a process-wide static buffer that
 * is overwritten by the next call. Koffi's `str` return type decodes
 * the pointer into a JavaScript string before this module's wrapper
 * returns, so callers never observe a dangling pointer.
 *
 * ============================================================================
 * HEALTH CHECKS
 * ============================================================================
 * checkMainThread reports whether the simulated main thread is running.
 * checkApp and checkApi perform cache-based lookups that are updated by
 * network broadcasts with an approximate 3-second delay. They are
 * suitable for probing and diagnostics, not for authoritative
 * availability decisions. For critical paths, issue the call and
 * handle timeouts explicitly.
 *
 * ============================================================================
 * DEPENDENCY DIRECTION
 * ============================================================================
 *
 *     binding.js         (raw Koffi declarations)
 *         ^
 *     status.js          (this file)
 *
 * This module depends only on binding.js. It does not touch any data
 * handle or application handle.
 *
 * ============================================================================
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
 * The native function returns a pointer into a static buffer that the
 * very next call would overwrite. Koffi's `str` type decodes the
 * pointer into a JavaScript string before this function returns, so
 * the caller never observes that hazard.
 *
 * [CAVEAT] The native ABI cannot distinguish "empty queue" from
 * "empty message": both produce an empty string. Callers that need to
 * distinguish the two must call getStatusCount first.
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
 * The function stops early when the native queue reports a message of
 * length zero, matching the historical behaviour of the C# binding.
 * An empty string can only be observed through the queue in a corner
 * case (a user explicitly posting an empty message, or a race with
 * another producer), so this early-exit rule is a pragmatic choice
 * that keeps the common path efficient.
 *
 * @param {number} [maxMessages=64]
 *   Upper bound on the number of messages to retrieve. Must be a
 *   non-negative integer. A value of zero returns an empty array
 *   without touching the queue.
 * @returns {string[]}
 *   The messages actually retrieved, in FIFO order. The array may be
 *   shorter than `maxMessages` when the queue held fewer messages or
 *   the early-exit rule triggered.
 * @throws {TypeError} When maxMessages is not a number.
 * @throws {RangeError} When maxMessages is negative or not an integer.
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
 * The native side queues the message even when the simulated main
 * thread is not yet running. The queue is bounded at 1000 entries;
 * older entries are dropped when the buffer is full.
 *
 * Messages posted during the initialisation window (before
 * prepareDone returns) are therefore not lost, but they may only
 * become observable once the main thread starts processing the queue.
 *
 * @param {string} message
 *   Message to inject. Must be a string. An empty string is allowed;
 *   the native side queues it as an empty entry.
 * @throws {TypeError} When message is not a string.
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
 * The lookup uses a local cache updated by network broadcasts with an
 * approximate 3-second delay. False negatives immediately after
 * registration and false positives shortly after unregistration are
 * both normal. Do not use this as an authoritative existence test for
 * critical paths.
 *
 * @param {string} appName
 *   Application name. Must be a string.
 * @returns {boolean}
 * @throws {TypeError} When appName is not a string.
 */
function checkApp(appName) {
    if (typeof appName !== "string") {
        throw new TypeError("checkApp: appName must be a string.");
    }
    return funcs().LF_CheckApp(appName) !== 0;
}

/**
 * Probes whether the named API is available for the given application.
 * Same cache-based caveat as checkApp.
 *
 * @param {string} appName
 * @param {string} apiName
 * @returns {boolean}
 * @throws {TypeError} When either argument is not a string.
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
};