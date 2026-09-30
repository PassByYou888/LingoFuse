// =============================================================================
//  framework.ts
// -----------------------------------------------------------------------------
//  Process-wide ABI facade for the LingoFuse native library.
//
//  Covers network preparation, remote invocation, runtime options,
//  application name generation, and process-wide shutdown.
// =============================================================================

import { getBinding } from "./binding";
import type { NativeFunctions } from "./binding";
import { DataHandle } from "./data-handle";
import { AppHandle, setCallbackErrorReporter } from "./app-handle";
import {
    LingoFuseCallbackError,
    LingoFuseCallError,
} from "./errors";

let _funcs: NativeFunctions | null = null;

function funcs(): NativeFunctions {
    if (_funcs === null) _funcs = getBinding().funcs;
    return _funcs;
}

// -----------------------------------------------------------------------------
//  Callback error reporting
// -----------------------------------------------------------------------------

/** Optional handler invoked when a user callback throws. */
export type CallbackErrorHandler = (source: string, err: unknown) => void;

let _callbackErrorHandler: CallbackErrorHandler | null = null;

/** Install a callback error handler. Pass null to remove it. */
export function setCallbackErrorHandler(fn: CallbackErrorHandler | null): void {
    if (fn !== null && typeof fn !== "function") {
        throw new TypeError("setCallbackErrorHandler: fn must be a function or null.");
    }
    _callbackErrorHandler = fn;
}

/** Read the currently installed callback error handler. */
export function getCallbackErrorHandler(): CallbackErrorHandler | null {
    return _callbackErrorHandler;
}

function reportCallbackError(source: string, err: unknown): void {
    if (_callbackErrorHandler !== null) {
        try {
            _callbackErrorHandler(source, err);
        } catch {
            // A broken handler must not escape into the native worker.
        }
    }
    try {
        const wrapped = err instanceof Error ? err : new LingoFuseCallbackError(source, err);
        const detail = wrapped.stack ?? wrapped.message;
        process.stderr.write(`[LingoFuse] Callback error in ${source}: ${detail}\n`);
    } catch {
        // stderr may be unavailable. Ignore.
    }
}

// Wire the handler into app-handle's module-level reporter.
setCallbackErrorReporter(reportCallbackError);

// -----------------------------------------------------------------------------
//  Timeout normalization
// -----------------------------------------------------------------------------

function normaliseTimeout(value: number | bigint): bigint {
    let v: bigint;
    if (typeof value === "bigint") {
        v = value;
    } else if (typeof value === "number" && Number.isFinite(value)) {
        if (!Number.isInteger(value)) {
            throw new RangeError("Timeout must be an integer number of milliseconds.");
        }
        v = BigInt(value);
    } else {
        throw new TypeError("Timeout must be a number or a BigInt.");
    }
    if (v < 0n) throw new RangeError("Timeout must be non-negative.");
    const UINT64_MAX = (1n << 64n) - 1n;
    if (v > UINT64_MAX) throw new RangeError("Timeout exceeds the 64-bit unsigned range.");
    return v;
}

// -----------------------------------------------------------------------------
//  Network preparation
// -----------------------------------------------------------------------------

/** Clear any previously prepared services and clients. */
export function resetPrepare(): void {
    funcs().LF_ResetPrepare();
}

/** Prepare a C4 service listening on listeningAddr and advertised as physicsAddr. */
export function prepareService(listeningAddr: string, physicsAddr: string): number {
    if (typeof listeningAddr !== "string") {
        throw new TypeError("prepareService: listeningAddr must be a string.");
    }
    if (typeof physicsAddr !== "string") {
        throw new TypeError("prepareService: physicsAddr must be a string.");
    }
    return funcs().LF_PrepareService(listeningAddr, physicsAddr);
}

/** Prepare a C4 client connecting to physicsAddr and optionally exposing app. */
export function prepareClient(physicsAddr: string, app: AppHandle | null = null): number {
    if (typeof physicsAddr !== "string") {
        throw new TypeError("prepareClient: physicsAddr must be a string.");
    }
    if (app !== null && !(app instanceof AppHandle)) {
        throw new TypeError("prepareClient: app must be an AppHandle or null.");
    }
    const rawApp = app === null ? null : app.raw;
    return funcs().LF_PrepareClient(physicsAddr, rawApp);
}

/** Start the framework. Returns 1 on success; 0 on a repeated call. */
export function prepareDone(): number {
    return funcs().LF_PrepareDone();
}

/** Request the simulated main thread to exit. */
export function exitMainThread(): void {
    funcs().LF_ExitMainThread();
}

// -----------------------------------------------------------------------------
//  Runtime options
// -----------------------------------------------------------------------------

/** Adjust a global runtime option. Unknown option names are silently ignored. */
export function setOption(option: string, value: string): void {
    if (typeof option !== "string") {
        throw new TypeError("setOption: option must be a string.");
    }
    if (typeof value !== "string") {
        throw new TypeError("setOption: value must be a string.");
    }
    funcs().LF_SetOption(option, value);
}

// -----------------------------------------------------------------------------
//  Application name
// -----------------------------------------------------------------------------

/**
 * Generate a globally unique application name.
 *
 * Must be called after prepareDone() has returned 1. The native function
 * returns a pointer valid for approximately 5 seconds; this wrapper
 * copies the string immediately.
 */
export function generateAppName(): string {
    const name = funcs().LF_Generate_AppName();
    return typeof name === "string" ? name : "";
}

// -----------------------------------------------------------------------------
//  Remote invocation
// -----------------------------------------------------------------------------

/**
 * Perform a synchronous remote call. On timeout or failure, the
 * returned handle has size 0 (it is never null).
 */
export function call(
    appName: string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): DataHandle {
    if (typeof appName !== "string") {
        throw new TypeError("call: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("call: param must be a DataHandle.");
    }
    const timeout = normaliseTimeout(timeoutMs);

    const result = funcs().LF_Call(appName, param.raw, timeout);
    if (result === null || result === undefined) {
        throw new LingoFuseCallError(
            "LF_Call returned a null handle.",
            { targetApp: appName });
    }
    return DataHandle.fromRaw(result, true);
}

/** Send a one-way Notify. Delivery order is not guaranteed. */
export function notify(appName: string, param: DataHandle): void {
    if (typeof appName !== "string") {
        throw new TypeError("notify: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("notify: param must be a DataHandle.");
    }
    funcs().LF_Notify(appName, param.raw);
}

/** Send a one-way notification with FIFO ordering per (app, api) pair. */
export function sequencedNotify(appName: string, param: DataHandle): void {
    if (typeof appName !== "string") {
        throw new TypeError("sequencedNotify: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("sequencedNotify: param must be a DataHandle.");
    }
    funcs().LF_Sequenced_Notify(appName, param.raw);
}

// -----------------------------------------------------------------------------
//  Shutdown
// -----------------------------------------------------------------------------

/** Gracefully terminate the framework, releasing all resources. */
export function shutdown(): void {
    funcs().LF_Shutdown();
}