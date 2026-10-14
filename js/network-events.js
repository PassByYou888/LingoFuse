/**
 * @file network-events.js
 * @brief Process-global connect / disconnect event handlers.
 *
 * This module wraps LF_Set_Network_Event, which installs a pair of
 * process-wide callbacks that fire when a LingoFuse client becomes
 * online or goes offline. It mirrors the role of NetworkEvents.cs in
 * the C# binding.
 *
 * ============================================================================
 * SEMANTICS
 * ============================================================================
 *
 * "Connect"    fires the FIRST time a client receives a service API-info
 *              broadcast. It is NOT the TCP handshake; it is the
 *              earliest point at which remote calls can be routed.
 *              Fires once per connection lifecycle, and again after an
 *              auto-reconnect.
 *
 * "Disconnect" fires once per physical link loss. An automatic
 *              reconnect does NOT emit a Disconnect for the reconnect
 *              attempt itself; it emits a new Connect once the client
 *              is back online.
 *
 * ============================================================================
 * THREADING CONTRACT
 * ============================================================================
 * Callbacks run on a background worker thread owned by the native
 * library. They must:
 *
 *   - copy the endpoint string immediately (this module does that for
 *     the user, so the handler receives a JavaScript string);
 *   - never touch UI controls directly;
 *   - never call any blocking LingoFuse function (call, localCall,
 *     prepareDone, shutdown) - this would deadlock;
 *   - never let an exception escape into the native stack.
 *
 * The module enforces the last rule: any exception raised by a user
 * handler is caught and reported through the shared callback error
 * reporter. The native layer sees a callback that returned normally.
 *
 * ============================================================================
 * ENDPOINT STRING LIFETIME
 * ============================================================================
 * The native side passes a UTF-8 pointer that is freed as soon as the
 * callback returns. Koffi's `str` type decodes the pointer into a
 * JavaScript string before the user handler is invoked, so user code
 * never sees a dangling pointer.
 *
 * ============================================================================
 * GLOBAL SCOPE
 * ============================================================================
 * LF_Set_Network_Event is a process-wide slot. There is no per-client
 * registration. Installing new handlers replaces the previous ones
 * entirely; passing null for a handler disables that event.
 *
 * shutdown() automatically clears both handlers during teardown. It is
 * nevertheless recommended to call clearNetworkEvent explicitly before
 * unloading the binding to release the Koffi callback registrations.
 *
 * ============================================================================
 * DELEGATE LIFETIME AND REPLACEMENT ORDER
 * ============================================================================
 * Koffi callbacks must be registered with `koffi.register` to remain
 * valid for the lifetime of the native registration. This module keeps
 * the registered pointers in module-level variables, and releases them
 * with `koffi.unregister` when the handlers are replaced or cleared.
 *
 * REPLACEMENT ORDER (important):
 * The native library holds a raw function pointer to each installed
 * trampoline. When setNetworkEvent() replaces the handlers, the new
 * trampolines must be installed on the native side BEFORE the old ones
 * are released. The sequence implemented here is:
 *
 *   1. Build the new trampolines (Koffi registration only; the native
 *      slot is not yet touched).
 *   2. Call LF_Set_Network_Event with the new pointers. The native
 *      slot now points at the new trampolines.
 *   3. Publish the new trampolines to module state.
 *   4. Release the old trampolines via koffi.unregister.
 *
 * Reversing steps 2 and 4 (releasing before the native swap) would
 * leave the native side holding a pointer to a freed trampoline for
 * the duration of the swap window. A connect/disconnect event arriving
 * in that window would jump to freed memory and crash the process.
 *
 * Failing to release at all would leak the Koffi trampoline object and
 * its backing libuv handle, which keeps the Node event loop alive.
 *
 * ============================================================================
 * USAGE
 * ============================================================================
 * @code
 * const { setNetworkEvent, clearNetworkEvent } = require("./network-events");
 *
 * setNetworkEvent(
 *     (addr) => console.log("Connected:", addr),
 *     (addr) => console.log("Disconnected:", addr)
 * );
 *
 * // ... later, before shutdown ...
 * clearNetworkEvent();
 * @endcode
 */

"use strict";

const koffi = require("koffi");
const { getBinding, LfNetworkEventFunc } = require("./binding");
const { reportCallbackError } = require("./app-handle");

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

/**
 * The currently installed Koffi-registered connect trampoline, or null
 * when no connect handler is installed.
 *
 * Held at module scope so the Koffi runtime does not collect it while
 * the native library still holds the function pointer.
 *
 * @type {object|null}
 */
let _connectTrampoline = null;

/**
 * The currently installed Koffi-registered disconnect trampoline, or
 * null when no disconnect handler is installed.
 *
 * @type {object|null}
 */
let _disconnectTrampoline = null;

// ============================================================================
// Trampoline factories
// ============================================================================

/**
 * Builds a Koffi-registered trampoline for a connect or disconnect
 * handler.
 *
 * Each call to `setNetworkEvent` builds fresh trampolines. Caching them
 * would require a stable identity for the user callback, which an
 * anonymous function does not provide. Building fresh trampolines is
 * cheap (install is a once-per-process operation) and eliminates a
 * class of stale-callback bugs.
 *
 * @param {string} source
 *   Identifier used when reporting a swallowed exception.
 * @param {(addr: string) => void} userHandler
 * @returns {object}
 *   The Koffi-registered pointer to install in the native slot.
 */
function buildTrampoline(source, userHandler) {
    return koffi.register(
        function (addr) {
            // Koffi has already decoded the UTF-8 pointer into a
            // JavaScript string by the time this trampoline runs. The
            // native buffer may be freed immediately after we return,
            // but we are already holding a managed copy.
            const endpoint = typeof addr === "string" ? addr : "";
            try {
                userHandler(endpoint);
            } catch (err) {
                reportCallbackError(source, err);
            }
        },
        koffi.pointer(LfNetworkEventFunc)
    );
}

// ============================================================================
// Public API
// ============================================================================

/**
 * Installs the process-global connect and disconnect handlers.
 *
 * Passing null for either argument disables that event. This is a
 * REPLACE operation, not a patch: calling it a second time discards
 * any previously installed handlers, even those whose corresponding
 * argument is null in the new call.
 *
 * The replacement is performed in the order described in the file
 * header: build new, install on the native side, publish to module
 * state, then release the old trampolines. See the DELEGATE LIFETIME
 * AND REPLACEMENT ORDER section above.
 *
 * If the native install call throws, the newly built trampolines are
 * released immediately (they were never installed) and the module
 * state is left unchanged; the previous trampolines remain installed
 * and registered.
 *
 * @param {((addr: string) => void) | null} onConnect
 *   Handler invoked when a client becomes online. May be null.
 * @param {((addr: string) => void) | null} onDisconnect
 *   Handler invoked when a client goes offline. May be null.
 * @throws {TypeError}
 *   When either argument is neither a function nor null.
 * @throws {*}
 *   Any error raised by the native LF_Set_Network_Event call.
 */
function setNetworkEvent(onConnect, onDisconnect) {
    if (onConnect !== null && typeof onConnect !== "function") {
        throw new TypeError(
            "setNetworkEvent: onConnect must be a function or null."
        );
    }
    if (onDisconnect !== null && typeof onDisconnect !== "function") {
        throw new TypeError(
            "setNetworkEvent: onDisconnect must be a function or null."
        );
    }

    // Capture the currently installed trampolines. They stay alive
    // (and remain registered with Koffi) until the native side has
    // been told to use the new ones, so that a connect/disconnect
    // event arriving during this window never reaches a freed
    // trampoline.
    const oldConnect = _connectTrampoline;
    const oldDisconnect = _disconnectTrampoline;

    // -----------------------------------------------------------------
    // Step 1: build the new trampolines.
    //
    // Building does not touch the native slot; it only creates new
    // Koffi callback registrations.
    // -----------------------------------------------------------------
    const newConnect =
        onConnect === null
            ? null
            : buildTrampoline("NetworkEvents.connect", onConnect);
    const newDisconnect =
        onDisconnect === null
            ? null
            : buildTrampoline("NetworkEvents.disconnect", onDisconnect);

    // -----------------------------------------------------------------
    // Step 2: install the new trampolines on the native side.
    //
    // If this throws, the old trampolines are still installed and
    // still registered, and the module state is unchanged. We only
    // need to release the newly built ones, which the native side
    // never saw.
    // -----------------------------------------------------------------
    try {
        funcs().LF_Set_Network_Event(newConnect, newDisconnect);
    } catch (err) {
        if (newConnect !== null) {
            try {
                koffi.unregister(newConnect);
            } catch (_) {
                // Best-effort cleanup.
            }
        }
        if (newDisconnect !== null) {
            try {
                koffi.unregister(newDisconnect);
            } catch (_) {
                // Best-effort cleanup.
            }
        }
        throw err;
    }

    // -----------------------------------------------------------------
    // Step 3: publish the new trampolines to module state.
    //
    // From this point forward, the module owns the new trampolines
    // and no longer owns the old ones.
    // -----------------------------------------------------------------
    _connectTrampoline = newConnect;
    _disconnectTrampoline = newDisconnect;

    // -----------------------------------------------------------------
    // Step 4: release the old trampolines.
    //
    // The native side no longer holds any pointer to them, so the
    // Koffi registrations can be safely released.
    // -----------------------------------------------------------------
    if (oldConnect !== null) {
        try {
            koffi.unregister(oldConnect);
        } catch (_) {
            // Best-effort cleanup.
        }
    }
    if (oldDisconnect !== null) {
        try {
            koffi.unregister(oldDisconnect);
        } catch (_) {
            // Best-effort cleanup.
        }
    }
}

/**
 * Removes both handlers. Safe to call multiple times.
 *
 * This also releases the strong references held by the module,
 * allowing the Koffi runtime to collect the trampolines.
 */
function clearNetworkEvent() {
    setNetworkEvent(null, null);
}

/**
 * Returns true when at least one handler is currently installed.
 *
 * @returns {boolean}
 */
function isNetworkEventInstalled() {
    return _connectTrampoline !== null || _disconnectTrampoline !== null;
}

// ============================================================================
// Object-oriented listener (optional convenience)
// ============================================================================

/**
 * Base class for object-oriented network event listeners.
 *
 * Subclass and override onConnect / onDisconnect. Both methods run on a
 * native worker thread; see the file-level docstring for the full
 * threading contract.
 *
 * The listener instance is captured by the trampolines installed via
 * `setNetworkEventListener`. As long as the listener is installed, it
 * cannot be collected.
 */
class NetworkEventListener {
    /**
     * Called when a client becomes online.
     *
     * @param {string} _addr
     */
    onConnect(_addr) {
        // Default: do nothing.
    }

    /**
     * Called when a client goes offline.
     *
     * @param {string} _addr
     */
    onDisconnect(_addr) {
        // Default: do nothing.
    }
}

/**
 * Installs a NetworkEventListener.
 *
 * The listener is captured by the trampolines, keeping it alive for as
 * long as it is installed. Use clearNetworkEvent() to uninstall.
 *
 * @param {NetworkEventListener|null} listener
 * @throws {TypeError}
 *   When listener is neither null nor a NetworkEventListener.
 */
function setNetworkEventListener(listener) {
    if (listener === null) {
        clearNetworkEvent();
        return;
    }
    if (!(listener instanceof NetworkEventListener)) {
        throw new TypeError(
            "setNetworkEventListener: listener must be a " +
            "NetworkEventListener or null."
        );
    }

    setNetworkEvent(
        (addr) => listener.onConnect(addr),
        (addr) => listener.onDisconnect(addr)
    );
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
    setNetworkEvent,
    clearNetworkEvent,
    isNetworkEventInstalled,
    NetworkEventListener,
    setNetworkEventListener,
};