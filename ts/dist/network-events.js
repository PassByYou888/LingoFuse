"use strict";
// =============================================================================
//  network-events.ts
// -----------------------------------------------------------------------------
//  Process-global connect / disconnect event handlers.
//
//  Callback registration:
//      koffi.register() requires the callback pointer type built from
//      the matching koffi.proto(). The correct pointer type
//      (LfNetworkEventFuncPtr) is declared and exported by binding.ts.
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.setNetworkEventListener = exports.NetworkEventListener = exports.isNetworkEventInstalled = exports.clearNetworkEvent = exports.setNetworkEvent = void 0;
const binding_1 = require("./binding");
const app_handle_1 = require("./app-handle");
let _funcs = null;
function funcs() {
    if (_funcs === null)
        _funcs = (0, binding_1.getBinding)().funcs;
    return _funcs;
}
let _connectTrampoline = null;
let _disconnectTrampoline = null;
function buildTrampoline(source, handler) {
    return binding_1.koffi.register((addr) => {
        const endpoint = typeof addr === "string" ? addr : "";
        try {
            handler(endpoint);
        }
        catch (err) {
            (0, app_handle_1.reportCallbackError)(source, err);
        }
    }, binding_1.LfNetworkEventFuncPtr);
}
/**
 * Install the process-global connect and disconnect handlers. Passing
 * null for either argument disables that event. This is a REPLACE
 * operation.
 */
function setNetworkEvent(onConnect, onDisconnect) {
    if (onConnect !== null && typeof onConnect !== "function") {
        throw new TypeError("setNetworkEvent: onConnect must be a function or null.");
    }
    if (onDisconnect !== null && typeof onDisconnect !== "function") {
        throw new TypeError("setNetworkEvent: onDisconnect must be a function or null.");
    }
    const oldConnect = _connectTrampoline;
    const oldDisconnect = _disconnectTrampoline;
    _connectTrampoline = null;
    _disconnectTrampoline = null;
    if (oldConnect !== null) {
        try {
            binding_1.koffi.unregister(oldConnect);
        }
        catch { /* ignore */ }
    }
    if (oldDisconnect !== null) {
        try {
            binding_1.koffi.unregister(oldDisconnect);
        }
        catch { /* ignore */ }
    }
    const newConnect = onConnect === null
        ? null
        : buildTrampoline("NetworkEvents.connect", onConnect);
    const newDisconnect = onDisconnect === null
        ? null
        : buildTrampoline("NetworkEvents.disconnect", onDisconnect);
    funcs().LF_Set_Network_Event(newConnect, newDisconnect);
    _connectTrampoline = newConnect;
    _disconnectTrampoline = newDisconnect;
}
exports.setNetworkEvent = setNetworkEvent;
/** Remove both handlers. Safe to call multiple times. */
function clearNetworkEvent() {
    setNetworkEvent(null, null);
}
exports.clearNetworkEvent = clearNetworkEvent;
/** True when at least one handler is installed. */
function isNetworkEventInstalled() {
    return _connectTrampoline !== null || _disconnectTrampoline !== null;
}
exports.isNetworkEventInstalled = isNetworkEventInstalled;
// -----------------------------------------------------------------------------
//  Object-oriented listener
// -----------------------------------------------------------------------------
/** Base class for object-oriented network event listeners. */
class NetworkEventListener {
    /** Called when a client becomes online. */
    onConnect(_addr) {
        // Default: do nothing.
    }
    /** Called when a client goes offline. */
    onDisconnect(_addr) {
        // Default: do nothing.
    }
}
exports.NetworkEventListener = NetworkEventListener;
/** Install a NetworkEventListener. */
function setNetworkEventListener(listener) {
    if (listener === null) {
        clearNetworkEvent();
        return;
    }
    if (!(listener instanceof NetworkEventListener)) {
        throw new TypeError("setNetworkEventListener: listener must be a NetworkEventListener or null.");
    }
    setNetworkEvent((addr) => listener.onConnect(addr), (addr) => listener.onDisconnect(addr));
}
exports.setNetworkEventListener = setNetworkEventListener;
//# sourceMappingURL=network-events.js.map