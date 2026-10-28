import { getBinding, koffi, LfNetworkEventFuncPtr } from "./binding";
import type { NativeFunctions } from "./binding";
import { reportCallbackError } from "./app-handle";

type KoffiCallbackHandle = ReturnType<typeof koffi.register>;

let _funcs: NativeFunctions | null = null;
function funcs(): NativeFunctions {
    if (_funcs === null) _funcs = getBinding().funcs;
    return _funcs;
}

let _connectTrampoline: KoffiCallbackHandle | null = null;
let _disconnectTrampoline: KoffiCallbackHandle | null = null;

export type ConnectHandler = (addr: string) => void;
export type DisconnectHandler = (addr: string) => void;

function unregisterCallback(handle: KoffiCallbackHandle | null): void {
    if (handle === null) return;
    try {
        (koffi.unregister as (h: unknown) => void)(handle);
    } catch { /* ignore */ }
}

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

export function setNetworkEvent(
    onConnect: ConnectHandler | null,
    onDisconnect: DisconnectHandler | null,
): void {
    if (onConnect !== null && typeof onConnect !== "function") {
        throw new TypeError(
            "setNetworkEvent: onConnect must be a function or null.");
    }
    if (onDisconnect !== null && typeof onDisconnect !== "function") {
        throw new TypeError(
            "setNetworkEvent: onDisconnect must be a function or null.");
    }

    const oldConnect = _connectTrampoline;
    const oldDisconnect = _disconnectTrampoline;

    const newConnect = onConnect === null
        ? null
        : buildTrampoline("NetworkEvents.connect", onConnect);
    const newDisconnect = onDisconnect === null
        ? null
        : buildTrampoline("NetworkEvents.disconnect", onDisconnect);

    try {
        funcs().LF_Set_Network_Event(newConnect, newDisconnect);
    } catch (err) {
        unregisterCallback(newConnect);
        unregisterCallback(newDisconnect);
        throw err;
    }

    _connectTrampoline = newConnect;
    _disconnectTrampoline = newDisconnect;

    unregisterCallback(oldConnect);
    unregisterCallback(oldDisconnect);
}

export function clearNetworkEvent(): void {
    setNetworkEvent(null, null);
}

export function isNetworkEventInstalled(): boolean {
    return _connectTrampoline !== null || _disconnectTrampoline !== null;
}

export abstract class NetworkEventListener {
    public onConnect(_addr: string): void {
        /* default no-op */
    }
    public onDisconnect(_addr: string): void {
        /* default no-op */
    }
}

export function setNetworkEventListener(
    listener: NetworkEventListener | null,
): void {
    if (listener === null) {
        clearNetworkEvent();
        return;
    }
    if (!(listener instanceof NetworkEventListener)) {
        throw new TypeError(
            "setNetworkEventListener: listener must be a " +
            "NetworkEventListener or null.");
    }
    setNetworkEvent(
        (addr) => listener.onConnect(addr),
        (addr) => listener.onDisconnect(addr),
    );
}