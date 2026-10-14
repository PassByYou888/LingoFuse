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
 * crash. This module keeps a strong reference to every SUCCESSFULLY
 * REGISTERED callback in a module-level array, mirroring the contract
 * of AppHandle.#registrations for app-bound registration.
 *
 * The keepalive list is intentionally never pruned:
 *
 *   - On a REJECTED registration (the native call returned a value
 *     other than 1), the Koffi bridge was never handed to the native
 *     library, so it is safe to release immediately. This module does
 *     exactly that and does NOT add the bridge to the keepalive list.
 *
 *   - On a successful registration followed by LF_Unregister_P2P, the
 *     native library may still be holding a pointer to the bridge
 *     while an in-flight request completes. The library does not
 *     expose a way to release the callback object itself; keeping the
 *     reference is harmless (a few dozen bytes) and removing it would
 *     risk a use-after-free on the native side.
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
 * Strong references to every Koffi callback successfully registered
 * through the process-wide P2P API.
 *
 * Only bridges accepted by the native layer are appended. A bridge
 * whose registration was rejected is released immediately and never
 * enters this list.
 *
 * The list is intentionally never cleared at runtime:
 *
 *   - The process-wide P2P namespace is tied to the process lifetime.
 *   - The native library does not expose a way to release the callback
 *     object itself on unregistration (only its name).
 *   - Keeping the reference is harmless; releasing it could leave the
 *     native side with a dangling pointer if an in-flight request is
 *     still being serviced when LF_Unregister_P2P returns.
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
            `[LingoFuse] Callback error in ${source}: ${detail}\n`
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

    const ret = funcs().LF_Register_P2P_Call(
        apiName,
        desc,
        null,
        bridge
    );

    if (ret !== 1) {
        // The native call did NOT accept the callback pointer. The
        // bridge has never been seen by the native library, so it is
        // safe (and required) to release it immediately. Pushing it
        // into the keepalive list before this check would leak one
        // Koffi thread-safe function per rejected registration.
        try {
            koffi.unregister(bridge);
        } catch (_e) {
            // Best-effort cleanup.
        }
        throw new LingoFuseRegistrationError(apiName);
    }

    // Registration succeeded: the native library now holds a raw
    // pointer to this bridge. Keep the strong reference for the
    // lifetime of the process.
    _p2pCallbacks.push(bridge);
}

/**
 * Register a process-wide P2P Notify API.
 *
 * @param {string} apiName
 * @param {(input: DataHandle) => void} handler
 * @param {string} [description=""]
 * @throws {TypeError} On a malformed argument.
 * @throws {import('./errors').LingoFuseRegistrationError}
 *   When the underlying native call is rejected.
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

    const ret = funcs().LF_Register_P2P_Notify(
        apiName,
        desc,
        null,
        bridge
    );

    if (ret !== 1) {
        // Same reasoning as registerP2PCall above: the bridge was
        // never handed to the native library and is safe to release.
        try {
            koffi.unregister(bridge);
        } catch (_e) {
            // Best-effort cleanup.
        }
        throw new LingoFuseRegistrationError(apiName);
    }

    _p2pCallbacks.push(bridge);
}

/**
 * Remove a previously registered process-wide P2P API.
 *
 * The removal is immediate locally. Remote peers may still see the API
 * for up to ~3 seconds until the network broadcast propagates.
 *
 * The corresponding Koffi callback wrapper stays in the keepalive list
 * even after unregistration. This is deliberate:
 *
 *   - The native library does not expose a way to release the callback
 *     object itself (only its name).
 *   - An in-flight request that was already dispatched when the
 *     unregistration command is processed may still invoke the bridge.
 *   - Keeping the reference is harmless (a few dozen bytes per
 *     registration) and removing it would risk a use-after-free.
 *
 * Callers who repeatedly register and unregister the same name should
 * be aware that each successful register/keep cycle leaves one bridge
 * in the keepalive list for the lifetime of the process. This is the
 * safest behaviour the native ABI permits; the alternative is a
 * potential crash on a late callback.
 *
 * @param {string} apiName
 * @returns {boolean}
 *   true when the native call reported a removal, false otherwise.
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