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

import { getBinding, koffi, LfNetworkEventFuncPtr } from "./binding";
import type { NativeFunctions } from "./binding";
import { reportCallbackError } from "./app-handle";

/** The handle type returned by koffi.register. */
type KoffiCallbackHandle = ReturnType<typeof koffi.register>;

let _funcs: NativeFunctions | null = null;
function funcs(): NativeFunctions {
    if (_funcs === null) _funcs = getBinding().funcs;
    return _funcs;
}

let _connectTrampoline: KoffiCallbackHandle | null = null;
let _disconnectTrampoline: KoffiCallbackHandle | null = null;

/** User-supplied connect handler. */
export type ConnectHandler = (addr: string) => void;
/** User-supplied disconnect handler. */
export type DisconnectHandler = (addr: string) => void;

function buildTrampoline(
    source: string,
    handler: ConnectHandler | DisconnectHandler,
): KoffiCallbackHandle {
    return koffi.register(
        (addr: unknown): void => {
            const endpoint = typeof addr === "string" ? addr : "";
            try {
                handler(endpoint);
            } catch (err) {
                reportCallbackError(source, err);
            }
        },
        LfNetworkEventFuncPtr,
    );
}

/**
 * Install the process-global connect and disconnect handlers. Passing
 * null for either argument disables that event. This is a REPLACE
 * operation.
 */
export function setNetworkEvent(
    onConnect: ConnectHandler | null,
    onDisconnect: DisconnectHandler | null,
): void {
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
        try { koffi.unregister(oldConnect); } catch { /* ignore */ }
    }
    if (oldDisconnect !== null) {
        try { koffi.unregister(oldDisconnect); } catch { /* ignore */ }
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

/** Remove both handlers. Safe to call multiple times. */
export function clearNetworkEvent(): void {
    setNetworkEvent(null, null);
}

/** True when at least one handler is installed. */
export function isNetworkEventInstalled(): boolean {
    return _connectTrampoline !== null || _disconnectTrampoline !== null;
}

// -----------------------------------------------------------------------------
//  Object-oriented listener
// -----------------------------------------------------------------------------

/** Base class for object-oriented network event listeners. */
export abstract class NetworkEventListener {
    /** Called when a client becomes online. */
    public onConnect(_addr: string): void {
        // Default: do nothing.
    }
    /** Called when a client goes offline. */
    public onDisconnect(_addr: string): void {
        // Default: do nothing.
    }
}

/** Install a NetworkEventListener. */
export function setNetworkEventListener(
    listener: NetworkEventListener | null,
): void {
    if (listener === null) {
        clearNetworkEvent();
        return;
    }
    if (!(listener instanceof NetworkEventListener)) {
        throw new TypeError(
            "setNetworkEventListener: listener must be a NetworkEventListener or null.");
    }
    setNetworkEvent(
        (addr) => listener.onConnect(addr),
        (addr) => listener.onDisconnect(addr),
    );
}