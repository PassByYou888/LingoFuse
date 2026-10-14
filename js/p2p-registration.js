/**
 * @file p2p-registration.js
 * @brief Process-wide P2P API registration.
 *
 * This module wraps LF_Register_P2P_Call / LF_Register_P2P_Notify /
 * LF_Unregister_P2P, which register APIs into the process-wide P2P
 * namespace.
 *
 * ============================================================================
 * NAMESPACE ISOLATION
 * ============================================================================
 * The process-wide P2P namespace is INDEPENDENT of any App:
 *
 *   - APIs registered here are reachable via UID addressing and
 *     P2PName addressing ONLY.
 *   - They are NOT reachable via App-name addressing, even if the
 *     registered API name happens to match an App name.
 *   - They live on the process-wide LF_P2P_APP and survive until the
 *     framework is shut down.
 *
 * Typical use: register a small set of globally-discoverable utility
 * APIs (health probes, capability discovery, identity echo, etc.) that
 * any client in the mesh can call by group name or by UID.
 *
 * ============================================================================
 * KEEPALIVE
 * ============================================================================
 * The native library holds a raw function pointer to each installed
 * callback. If the corresponding Koffi callback object is garbage
 * collected while the pointer is still live, the next invocation will
 * crash. This module keeps a strong reference to every registered
 * callback in a module-level array, mirroring the contract of
 * AppHandle.#registrations for app-bound registration.
 *
 * ============================================================================
 * THREADING
 * ============================================================================
 * Registration is safe to perform at any time, both before and after
 * LF_PrepareDone. The registered callbacks run on native worker threads.
 * They MUST NOT block, and MUST NOT call any synchronous LingoFuse
 * function.
 *
 * All comments are in English.
 */

"use strict";

const koffi = require("koffi");
const {
    getBinding,
    LfCallFunc,
    LfNotifyFunc,
} = require("./binding");
const { DataHandle } = require("./data-handle");
const { LingoFuseRegistrationError } = require("./errors");

// ============================================================================
// Module-level state
// ============================================================================

let _funcs = null;

function funcs() {
    if (_funcs === null) {
        _funcs = getBinding().funcs;
    }
    return _funcs;
}

/**
 * Strong references to every Koffi callback registered through the
 * process-wide P2P API. The list is intentionally never cleared: the
 * process-wide P2P namespace is by definition tied to the process
 * lifetime, and the underlying native library does not provide a way
 * to unregister the callback object itself (only its name).
 *
 * @type {Array<object>}
 */
const _p2pCallbacks = [];

// ============================================================================
// Callback error reporting (best-effort, no dependency on framework.js
// to avoid a circular require)
// ============================================================================

function _reportCallbackError(source, err) {
    try {
        const detail =
            err instanceof Error
                ? err.stack ?? err.message
                : String(err);
        process.stderr.write(
            `[LingoFuse] Callback error in ${source}: ${detail}`
        );
    } catch (_e) {
        // Even stderr may be unavailable in some embeddings. Ignore.
    }
}

// ============================================================================
// Public API
// ============================================================================

/**
 * Register a process-wide P2P Call API.
 *
 * The API becomes reachable via UID addressing or P2PName addressing
 * from any client in the mesh, without requiring the caller to know the
 * target App name.
 *
 * @param {string} apiName
 * @param {(input: DataHandle, output: DataHandle) => void} handler
 * @param {string} [description=""]
 * @throws {TypeError} On a malformed argument.
 * @throws {import('./errors').LingoFuseRegistrationError}
 *   When the underlying native call is rejected.
 */
function registerP2PCall(apiName, handler, description = "") {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "registerP2PCall: apiName must be a string."
        );
    }
    if (typeof handler !== "function") {
        throw new TypeError(
            "registerP2PCall: handler must be a function."
        );
    }
    const desc = description ?? "";

    const bridge = koffi.register(
        function (_trigger, input, output) {
            const inH = DataHandle.fromRaw(input, false);
            const outH = DataHandle.fromRaw(output, false);
            try {
                handler(inH, outH);
            } catch (err) {
                _reportCallbackError(
                    `registerP2PCall[${apiName}]`,
                    err
                );
            }
        },
        koffi.pointer(LfCallFunc)
    );

    // Keep a strong reference BEFORE the native call, so that if the
    // native call raises, the wrapper still survives for the process
    // lifetime.
    _p2pCallbacks.push(bridge);

    const ret = funcs().LF_Register_P2P_Call(
        apiName,
        desc,
        null,
        bridge
    );
    if (ret !== 1) {
        throw new LingoFuseRegistrationError(apiName);
    }
}

/**
 * Register a process-wide P2P Notify API.
 *
 * @param {string} apiName
 * @param {(input: DataHandle) => void} handler
 * @param {string} [description=""]
 * @throws {TypeError} On a malformed argument.
 * @throws {import('./errors').LingoFuseRegistrationError}
 */
function registerP2PNotify(apiName, handler, description = "") {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "registerP2PNotify: apiName must be a string."
        );
    }
    if (typeof handler !== "function") {
        throw new TypeError(
            "registerP2PNotify: handler must be a function."
        );
    }
    const desc = description ?? "";

    const bridge = koffi.register(
        function (_trigger, input) {
            const inH = DataHandle.fromRaw(input, false);
            try {
                handler(inH);
            } catch (err) {
                _reportCallbackError(
                    `registerP2PNotify[${apiName}]`,
                    err
                );
            }
        },
        koffi.pointer(LfNotifyFunc)
    );

    _p2pCallbacks.push(bridge);

    const ret = funcs().LF_Register_P2P_Notify(
        apiName,
        desc,
        null,
        bridge
    );
    if (ret !== 1) {
        throw new LingoFuseRegistrationError(apiName);
    }
}

/**
 * Remove a previously registered process-wide P2P API.
 *
 * The removal is immediate locally. Remote peers may still see the API
 * for up to ~3 seconds until the network broadcast propagates.
 *
 * The corresponding Koffi callback wrapper stays in the keepalive list
 * even after unregistration: the native library does not expose a way
 * to release the callback object itself, and keeping the reference is
 * harmless (a few dozen bytes) while removing it would risk a use-after-
 * free if the library still holds the pointer.
 *
 * @param {string} apiName
 * @returns {boolean}
 */
function unregisterP2P(apiName) {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "unregisterP2P: apiName must be a string."
        );
    }
    return funcs().LF_Unregister_P2P(apiName) === 1;
}

// ============================================================================
// Public exports
// ============================================================================

module.exports = {
    registerP2PCall,
    registerP2PNotify,
    unregisterP2P,
};
