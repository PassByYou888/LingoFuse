import { getBinding, koffi, LfCallFuncPtr, LfNotifyFuncPtr } from "./binding";
import type { NativeFunctions } from "./binding";
import { DataHandle } from "./data-handle";
import { LingoFuseRegistrationError } from "./errors";

let _funcs: NativeFunctions | null = null;
function funcs(): NativeFunctions {
    if (_funcs === null) _funcs = getBinding().funcs;
    return _funcs;
}

const _p2pCallbacks: unknown[] = [];

function reportCallbackError(source: string, err: unknown): void {
    try {
        const detail =
            err instanceof Error
                ? err.stack ?? err.message
                : String(err);
        process.stderr.write(
            `[LingoFuse] Callback error in ${source}: ${detail}\n`,
        );
    } catch {
        /* stderr unavailable */
    }
}

function unregisterCallback(handle: unknown): void {
    try {
        (koffi.unregister as (h: unknown) => void)(handle);
    } catch { /* ignore */ }
}

export function registerP2PCall(
    apiName: string,
    handler: (input: DataHandle, output: DataHandle) => void,
    description: string = "",
): void {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "registerP2PCall: apiName must be a string.");
    }
    if (typeof handler !== "function") {
        throw new TypeError(
            "registerP2PCall: handler must be a function.");
    }
    const desc = description ?? "";

    const bridge = koffi.register(
        function (_trigger: unknown, input: unknown, output: unknown): void {
            const inH = DataHandle.fromRaw(input, false);
            const outH = DataHandle.fromRaw(output, false);
            try {
                handler(inH, outH);
            } catch (err) {
                reportCallbackError(
                    `registerP2PCall[${apiName}]`, err);
            }
        },
        LfCallFuncPtr,
    );

    let ret: number;
    try {
        ret = funcs().LF_Register_P2P_Call(
            apiName, desc, null, bridge);
    } catch (err) {
        unregisterCallback(bridge);
        throw err;
    }

    if (ret !== 1) {
        unregisterCallback(bridge);
        throw new LingoFuseRegistrationError(apiName);
    }

    _p2pCallbacks.push(bridge);
}

export function registerP2PNotify(
    apiName: string,
    handler: (input: DataHandle) => void,
    description: string = "",
): void {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "registerP2PNotify: apiName must be a string.");
    }
    if (typeof handler !== "function") {
        throw new TypeError(
            "registerP2PNotify: handler must be a function.");
    }
    const desc = description ?? "";

    const bridge = koffi.register(
        function (_trigger: unknown, input: unknown): void {
            const inH = DataHandle.fromRaw(input, false);
            try {
                handler(inH);
            } catch (err) {
                reportCallbackError(
                    `registerP2PNotify[${apiName}]`, err);
            }
        },
        LfNotifyFuncPtr,
    );

    let ret: number;
    try {
        ret = funcs().LF_Register_P2P_Notify(
            apiName, desc, null, bridge);
    } catch (err) {
        unregisterCallback(bridge);
        throw err;
    }

    if (ret !== 1) {
        unregisterCallback(bridge);
        throw new LingoFuseRegistrationError(apiName);
    }

    _p2pCallbacks.push(bridge);
}

export function unregisterP2P(apiName: string): boolean {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "unregisterP2P: apiName must be a string.");
    }
    return funcs().LF_Unregister_P2P(apiName) === 1;
}