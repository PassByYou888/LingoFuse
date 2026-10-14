// =============================================================================
//  framework.ts
// -----------------------------------------------------------------------------
//  Process-wide ABI facade for the LingoFuse native library.
//
//  This is the LOW-LEVEL facade. It exposes one TypeScript function per
//  meaningful native operation, and it deliberately accepts and returns
//  DataHandle instances so that callers retain full control over
//  lifetime, buffer position, and byte-level I/O.
//
//  The high-level, handle-free surface lives in address.ts (Target
//  classes) and options.ts (typed runtime options). Application code
//  should generally prefer those. This module is for callers that need
//  either (a) a single function per native operation, or (b) direct
//  access to the DataHandle of a synchronous call result.
//
//  SCOPE
//  -----
//    - Network preparation (reset / prepare service / prepare client /
//      prepare done / exit main thread).
//    - Runtime options (setOption / getOption).
//    - Application name generation and query.
//    - Remote invocation:
//        * App name  : call / tryCall / callAsync / callPromise /
//                      notify / sequencedNotify
//        * UID       : uidCall / uidCallAsync / uidCallPromise /
//                      uidNotify / uidSequencedNotify
//        * P2PName   : p2pnameCall / p2pnameCallAsync /
//                      p2pnameCallPromise / p2pnameNotify /
//                      p2pnameSequencedNotify
//    - Callback error reporting (setCallbackErrorHandler).
//    - Process-wide shutdown.
//
//  WHAT THIS MODULE IS NOT
//  -----------------------
//    - It is NOT a wrapper for AppHandle (see app-handle.ts).
//    - It is NOT a wrapper for DataHandle (see data-handle.ts).
//    - It is NOT the typed option layer (see options.ts).
//    - It is NOT the three-addressing Target layer (see address.ts).
//
//  LAYERING
//  --------
//  This module sits at L4. It imports from L1 (binding), L2 (errors),
//  L3 (data-handle), and the L5 async-support module -- but only
//  through the specific symbols (CallPromise, runAsyncWithPromise,
//  runLegacyOp) that the async functions need. It does NOT import
//  address.ts, to preserve the strict downward dependency direction of
//  the binding. The few helpers that would otherwise be shared with
//  address.ts (UID normalization, JSON deserialization) are duplicated
//  here in a private, minimal form.
//
//  ASYNC RESULT SHAPE
//  ------------------
//  The async functions (callAsync / callPromise / uidCallPromise /
//  p2pnameCallPromise, and their legacy counterparts) always deliver a
//  DESERIALIZED JSON VALUE, never a DataHandle. This is deliberate:
//  the async result handle is released by the framework IMMEDIATELY
//  after the native callback returns, so passing the raw handle to
//  user code would expose a pointer whose lifetime has already ended.
//  The deserializer runs inside the callback window, copies the JSON
//  payload out, and hands a plain JavaScript value to the user.
//
//  Synchronous functions (call / tryCall / uidCall / p2pnameCall) DO
//  return a DataHandle, because the caller owns it and can safely
//  dispose it after reading.
//
//  THREADING
//  ---------
//  Async callbacks run on the JS event loop, serialised by the Koffi
//  bridge from the native worker thread. They MUST NOT block. See
//  async-support.ts for the full lifecycle model.
//
//  All code and documentation are in English.
// =============================================================================

import { getBinding } from "./binding";
import type { NativeFunctions } from "./binding";
import { DataHandle } from "./data-handle";
import { AppHandle, setCallbackErrorReporter } from "./app-handle";
import {
    LingoFuseCallbackError,
    LingoFuseCallError,
    LingoFuseObjectDisposedError,
} from "./errors";
import {
    CallPromise,
    runAsyncWithPromise,
    runLegacyOp,
} from "./async-support";
import { readJson } from "./lf-io";

// -----------------------------------------------------------------------------
//  Native access
// -----------------------------------------------------------------------------

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
        throw new TypeError(
            "setCallbackErrorHandler: fn must be a function or null.");
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
        const wrapped = err instanceof Error
            ? err
            : new LingoFuseCallbackError(source, err);
        const detail = wrapped.stack ?? wrapped.message;
        process.stderr.write(
            `[LingoFuse] Callback error in ${source}: ${detail}\n`);
    } catch {
        // stderr may be unavailable. Ignore.
    }
}

// Wire the handler into app-handle's module-level reporter. This must
// happen at module load time so that any callback registered through
// AppHandle after this point routes through the framework's handler.
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
            throw new RangeError(
                "Timeout must be an integer number of milliseconds.");
        }
        v = BigInt(value);
    } else {
        throw new TypeError("Timeout must be a number or a BigInt.");
    }
    if (v < 0n) throw new RangeError("Timeout must be non-negative.");
    const UINT64_MAX = (1n << 64n) - 1n;
    if (v > UINT64_MAX) {
        throw new RangeError("Timeout exceeds the 64-bit unsigned range.");
    }
    return v;
}

/**
 * Convert a timeout argument to a plain Number suitable for the
 * JS-side deadline used by the async subsystem.
 */
function timeoutToNumber(value: number | bigint | undefined): number {
    if (value === undefined) return 5000;
    if (typeof value === "bigint") return Number(value);
    return value;
}

// -----------------------------------------------------------------------------
//  UID normalization (module-private)
// -----------------------------------------------------------------------------

/**
 * Normalize a UID value into a 32-byte Uint8Array.
 *
 * Accepts:
 *   - Uint8Array of length 32
 *   - 64-character hexadecimal string (case-insensitive)
 *
 * Kept private to framework.ts to preserve the downward layering rule:
 * framework.ts must not import address.ts, which would create a
 * cross-module dependency in the wrong direction. status.ts keeps its
 * own copy for the same reason.
 */
function normalizeUid(uid: Uint8Array | string): Uint8Array {
    if (uid instanceof Uint8Array) {
        if (uid.length !== 32) {
            throw new RangeError(
                `UID must be exactly 32 bytes, got ${uid.length}.`);
        }
        return new Uint8Array(uid);
    }
    if (typeof uid === "string") {
        const hex = uid.trim();
        if (hex.length !== 64) {
            throw new RangeError(
                `UID hex string must be exactly 64 characters, ` +
                `got ${hex.length}.`);
        }
        if (!/^[0-9a-fA-F]+$/.test(hex)) {
            throw new RangeError(
                "UID hex string contains non-hex characters.");
        }
        const out = new Uint8Array(32);
        for (let i = 0; i < 32; i++) {
            out[i] = parseInt(hex.substr(i * 2, 2), 16);
        }
        return out;
    }
    throw new TypeError(
        `UID must be a Uint8Array(32) or a 64-character hex string, ` +
        `got ${uid === null ? "null" : typeof uid}.`);
}

/**
 * Wrap a normalized 32-byte Uint8Array in the Koffi struct shape that
 * the LF_UID_* functions expect at the ABI boundary.
 */
function toTp2pUid(bytes: Uint8Array): { bytes: Uint8Array } {
    const arr = new Uint8Array(32);
    arr.set(bytes);
    return { bytes: arr };
}

// -----------------------------------------------------------------------------
//  JSON deserialization helper
// -----------------------------------------------------------------------------

/**
 * Build a deserializer that reads the JSON payload from an async result
 * handle. Called on the JS event loop inside the native callback window,
 * so the handle is still valid.
 *
 * The raw result handle is BORROWED (owned = false): the framework will
 * release it immediately after the callback returns. This function must
 * copy the payload out before returning.
 */
function makeJsonDeserializer<T>(): (rawResult: unknown) => T {
    return function (rawResult: unknown): T {
        if (!rawResult) return null as unknown as T;
        const h = DataHandle.fromRaw(rawResult, false);
        h.position = 0;
        return readJson<T>(h) as T;
    };
}

// -----------------------------------------------------------------------------
//  Network preparation
// -----------------------------------------------------------------------------

/** Clear any previously prepared services and clients. */
export function resetPrepare(): void {
    funcs().LF_ResetPrepare();
}

/**
 * Prepare a C4 service listening on listeningAddr and advertised as
 * physicsAddr.
 *
 * @returns An internal tag on success, or -1 for a duplicate address.
 */
export function prepareService(
    listeningAddr: string,
    physicsAddr: string,
): number {
    if (typeof listeningAddr !== "string") {
        throw new TypeError(
            "prepareService: listeningAddr must be a string.");
    }
    if (typeof physicsAddr !== "string") {
        throw new TypeError("prepareService: physicsAddr must be a string.");
    }
    return funcs().LF_PrepareService(listeningAddr, physicsAddr);
}

/**
 * Prepare a C4 client connecting to physicsAddr and optionally exposing
 * app.
 *
 * @param app  Application handle, or null for a pure consumer.
 */
export function prepareClient(
    physicsAddr: string,
    app: AppHandle | null = null,
): number {
    if (typeof physicsAddr !== "string") {
        throw new TypeError("prepareClient: physicsAddr must be a string.");
    }
    if (app !== null && !(app instanceof AppHandle)) {
        throw new TypeError("prepareClient: app must be an AppHandle or null.");
    }
    const rawApp = app === null ? null : app.raw;
    return funcs().LF_PrepareClient(physicsAddr, rawApp);
}

/**
 * Start the framework. Returns 1 on success; 0 on a repeated call in
 * the same process without an intervening shutdown, which is not a
 * failure.
 */
export function prepareDone(): number {
    return funcs().LF_PrepareDone();
}

/**
 * Request the simulated main thread to exit.
 *
 * [PITFALL] LF_ExitMainThread also flushes the data handle pool,
 * releasing every outstanding handle -- including those created with
 * DataHandle.createPermanent(). Do not use any data handle after this
 * call has returned.
 */
export function exitMainThread(): void {
    funcs().LF_ExitMainThread();
}

// -----------------------------------------------------------------------------
//  Runtime options
// -----------------------------------------------------------------------------

/**
 * Adjust a global runtime option. Unknown option names are silently
 * ignored by the native layer.
 *
 * Prefer the typed helpers in options.ts for known option names; this
 * function is provided for dynamic names and for scripting.
 *
 * [PITFALL] Once the framework is running (prepareDone returned 1),
 * LF_SetOption is posted to the native main thread and applied on the
 * next tick. A subsequent getOption() may therefore observe the old
 * value. Yield for at least one main-thread tick (100-150 ms is a safe
 * budget) before reading back.
 */
export function setOption(option: string, value: string): void {
    if (typeof option !== "string") {
        throw new TypeError("setOption: option must be a string.");
    }
    if (typeof value !== "string") {
        throw new TypeError("setOption: value must be a string.");
    }
    funcs().LF_SetOption(option, value);
}

/**
 * Read the current value of a runtime option.
 *
 * Returns a UTF-8 string. Unknown option names yield an empty string.
 * The native function returns a pointer to a transient buffer released
 * ~5 seconds after the call; Koffi's `str` return type decodes it into
 * a JavaScript string on the return boundary, so the returned value is
 * already detached and safe to retain.
 *
 * For typed access with canonical option keys, use the helpers in
 * options.ts.
 */
export function getOption(option: string): string {
    if (typeof option !== "string") {
        throw new TypeError("getOption: option must be a string.");
    }
    const v = funcs().LF_GetOption(option);
    return typeof v === "string" ? v : "";
}

// -----------------------------------------------------------------------------
//  Application name generation and query
// -----------------------------------------------------------------------------

/**
 * Generate a globally unique application name.
 *
 * Must be called after prepareDone() returns 1. The native function
 * returns a pointer valid for approximately 5 seconds; this wrapper
 * copies the string immediately.
 */
export function generateAppName(): string {
    const name = funcs().LF_Generate_AppName();
    return typeof name === "string" ? name : "";
}

/**
 * Return the authoritative name of an application handle, as stored in
 * the C4 mesh registry.
 *
 * The managed AppHandle.name property returns the name passed to the
 * constructor. This function queries the native side. The two are
 * usually identical but can differ if the native layer normalised the
 * name.
 *
 * @throws {TypeError}                    When app is not an AppHandle.
 * @throws {LingoFuseObjectDisposedError} When the handle is disposed.
 */
export function getAppName(app: AppHandle): string {
    if (!(app instanceof AppHandle)) {
        throw new TypeError("getAppName: app must be an AppHandle.");
    }
    if (!app.isValid) {
        // AppHandle.raw returns null after dispose without throwing;
        // detect the disposed state explicitly, otherwise the native
        // call below would receive a null handle and silently return
        // an empty string.
        throw new LingoFuseObjectDisposedError("AppHandle");
    }
    const name = funcs().LF_Get_AppName(app.raw);
    return typeof name === "string" ? name : "";
}

// =============================================================================
//  Remote invocation -- App-name addressing
// =============================================================================

/**
 * Perform a synchronous remote call by App name.
 *
 * On timeout or failure, the returned handle has size 0 (it is never
 * null). Callers who need to distinguish "timeout / unreachable target"
 * from "empty response" should inspect `size` directly, or use
 * tryCall() for a null-on-failure contract.
 *
 * Ownership: the caller is responsible for disposing the returned
 * handle.
 *
 * @throws {TypeError}  When appName is not a string, or param is not a
 *                      DataHandle.
 * @throws {RangeError} When timeoutMs is negative or out of range.
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

/**
 * Perform a synchronous remote call by App name and return the response
 * only when the native layer produced a non-empty payload.
 *
 * Returns null on timeout or unreachable target, instead of a size-0
 * DataHandle. Callers who need to distinguish "timeout" from "empty
 * response" must use call() and inspect `size` themselves.
 *
 * Ownership: when the function returns a non-null handle, the caller is
 * responsible for disposing it. When the function returns null, the
 * underlying empty handle has already been disposed by this function;
 * the caller must not free anything.
 */
export function tryCall(
    appName: string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): DataHandle | null {
    const response = call(appName, param, timeoutMs);
    if (response.size === 0) {
        response.dispose();
        return null;
    }
    return response;
}

/**
 * Non-blocking Call by App name with an inline callback. The callback
 * fires on the JS event loop and receives:
 *
 *     onResult(result, error, userData)
 *
 *   - result   : the deserialized JSON value, or null on error.
 *   - error    : a LingoFuseError / LingoFuseTimeoutError, or null.
 *   - userData : the value passed at call time, or undefined.
 *
 * The callback MUST NOT block. Exceptions raised inside it are caught
 * and logged to stderr; they never escape into the native stack.
 *
 * @returns 1 on successful dispatch, 0 otherwise.
 */
export function callAsync<TRes = unknown>(
    appName: string,
    param: DataHandle,
    onResult: (
        result: TRes | null,
        error: Error | null,
        userData: unknown,
    ) => void,
    userData: unknown = undefined,
): number {
    if (typeof appName !== "string") {
        throw new TypeError("callAsync: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("callAsync: param must be a DataHandle.");
    }
    if (typeof onResult !== "function") {
        throw new TypeError("callAsync: onResult must be a function.");
    }
    return runLegacyOp<TRes>(
        (cb) => funcs().LF_Async_Call(appName, param.raw, null, cb),
        onResult,
        userData,
        makeJsonDeserializer<TRes>(),
    );
}

/**
 * Non-blocking Call by App name returning a CallPromise.
 *
 * @returns A thenable that resolves with the deserialized JSON value.
 */
export function callPromise<TRes = unknown>(
    appName: string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): CallPromise<TRes> {
    if (typeof appName !== "string") {
        throw new TypeError("callPromise: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("callPromise: param must be a DataHandle.");
    }
    const timeout = timeoutToNumber(timeoutMs);
    return runAsyncWithPromise<TRes>(
        (cb) => funcs().LF_Async_Call(appName, param.raw, null, cb),
        makeJsonDeserializer<TRes>(),
        timeout,
    );
}

/** Send a one-way Notify by App name. Delivery order is not guaranteed. */
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

// =============================================================================
//  Remote invocation -- UID addressing
// =============================================================================

/**
 * Perform a synchronous remote call by UID.
 *
 * On timeout or failure, the returned handle has size 0 (it is never
 * null). Ownership: the caller is responsible for disposing the
 * returned handle.
 *
 * @param uid  A 32-byte Uint8Array, or a 64-character hex string.
 */
export function uidCall(
    uid: Uint8Array | string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): DataHandle {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidCall: param must be a DataHandle.");
    }
    const bytes = normalizeUid(uid);
    const timeout = normaliseTimeout(timeoutMs);
    const result = funcs().LF_UID_Call(
        toTp2pUid(bytes),
        param.raw,
        timeout,
    );
    if (result === null || result === undefined) {
        throw new LingoFuseCallError("LF_UID_Call returned a null handle.");
    }
    return DataHandle.fromRaw(result, true);
}

/**
 * Non-blocking Call by UID with an inline callback.
 *
 * @returns 1 on successful dispatch, 0 otherwise.
 */
export function uidCallAsync<TRes = unknown>(
    uid: Uint8Array | string,
    param: DataHandle,
    onResult: (
        result: TRes | null,
        error: Error | null,
        userData: unknown,
    ) => void,
    userData: unknown = undefined,
): number {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidCallAsync: param must be a DataHandle.");
    }
    if (typeof onResult !== "function") {
        throw new TypeError("uidCallAsync: onResult must be a function.");
    }
    const bytes = normalizeUid(uid);
    const uidArg = toTp2pUid(bytes);
    return runLegacyOp<TRes>(
        (cb) => funcs().LF_UID_Async_Call(uidArg, param.raw, null, cb),
        onResult,
        userData,
        makeJsonDeserializer<TRes>(),
    );
}

/**
 * Non-blocking Call by UID returning a CallPromise.
 */
export function uidCallPromise<TRes = unknown>(
    uid: Uint8Array | string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): CallPromise<TRes> {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidCallPromise: param must be a DataHandle.");
    }
    const bytes = normalizeUid(uid);
    const uidArg = toTp2pUid(bytes);
    const timeout = timeoutToNumber(timeoutMs);
    return runAsyncWithPromise<TRes>(
        (cb) => funcs().LF_UID_Async_Call(uidArg, param.raw, null, cb),
        makeJsonDeserializer<TRes>(),
        timeout,
    );
}

/** One-way Notify by UID. */
export function uidNotify(
    uid: Uint8Array | string,
    param: DataHandle,
): void {
    if (!(param instanceof DataHandle)) {
        throw new TypeError("uidNotify: param must be a DataHandle.");
    }
    const bytes = normalizeUid(uid);
    funcs().LF_UID_Notify(toTp2pUid(bytes), param.raw);
}

/** FIFO-ordered one-way Notify by UID. */
export function uidSequencedNotify(
    uid: Uint8Array | string,
    param: DataHandle,
): void {
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "uidSequencedNotify: param must be a DataHandle.");
    }
    const bytes = normalizeUid(uid);
    funcs().LF_UID_Sequenced_Notify(toTp2pUid(bytes), param.raw);
}

// =============================================================================
//  Remote invocation -- P2PName addressing
// =============================================================================

/**
 * Perform a synchronous remote call by P2P group name.
 *
 * On timeout or failure, the returned handle has size 0 (it is never
 * null). Ownership: the caller is responsible for disposing the
 * returned handle.
 */
export function p2pnameCall(
    p2pName: string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): DataHandle {
    if (typeof p2pName !== "string") {
        throw new TypeError("p2pnameCall: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("p2pnameCall: param must be a DataHandle.");
    }
    const timeout = normaliseTimeout(timeoutMs);
    const result = funcs().LF_P2PNAME_Call(
        p2pName,
        param.raw,
        timeout,
    );
    if (result === null || result === undefined) {
        throw new LingoFuseCallError(
            "LF_P2PNAME_Call returned a null handle.");
    }
    return DataHandle.fromRaw(result, true);
}

/**
 * Non-blocking Call by P2P group name with an inline callback.
 *
 * @returns 1 on successful dispatch, 0 otherwise.
 */
export function p2pnameCallAsync<TRes = unknown>(
    p2pName: string,
    param: DataHandle,
    onResult: (
        result: TRes | null,
        error: Error | null,
        userData: unknown,
    ) => void,
    userData: unknown = undefined,
): number {
    if (typeof p2pName !== "string") {
        throw new TypeError("p2pnameCallAsync: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("p2pnameCallAsync: param must be a DataHandle.");
    }
    if (typeof onResult !== "function") {
        throw new TypeError("p2pnameCallAsync: onResult must be a function.");
    }
    return runLegacyOp<TRes>(
        (cb) => funcs().LF_P2PNAME_Async_Call(p2pName, param.raw, null, cb),
        onResult,
        userData,
        makeJsonDeserializer<TRes>(),
    );
}

/**
 * Non-blocking Call by P2P group name returning a CallPromise.
 */
export function p2pnameCallPromise<TRes = unknown>(
    p2pName: string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): CallPromise<TRes> {
    if (typeof p2pName !== "string") {
        throw new TypeError(
            "p2pnameCallPromise: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "p2pnameCallPromise: param must be a DataHandle.");
    }
    const timeout = timeoutToNumber(timeoutMs);
    return runAsyncWithPromise<TRes>(
        (cb) => funcs().LF_P2PNAME_Async_Call(p2pName, param.raw, null, cb),
        makeJsonDeserializer<TRes>(),
        timeout,
    );
}

/** One-way Notify by P2P group name. */
export function p2pnameNotify(
    p2pName: string,
    param: DataHandle,
): void {
    if (typeof p2pName !== "string") {
        throw new TypeError("p2pnameNotify: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("p2pnameNotify: param must be a DataHandle.");
    }
    funcs().LF_P2PNAME_Notify(p2pName, param.raw);
}

/** FIFO-ordered one-way Notify by P2P group name. */
export function p2pnameSequencedNotify(
    p2pName: string,
    param: DataHandle,
): void {
    if (typeof p2pName !== "string") {
        throw new TypeError(
            "p2pnameSequencedNotify: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "p2pnameSequencedNotify: param must be a DataHandle.");
    }
    funcs().LF_P2PNAME_Sequenced_Notify(p2pName, param.raw);
}

// =============================================================================
//  Shutdown
// =============================================================================

/**
 * Gracefully terminate the framework, releasing all resources.
 * Safe to call multiple times.
 *
 * Every AppHandle still alive in the process becomes invalid after this
 * call. The AppHandle wrappers do not detect this automatically;
 * callers must ensure that no AppHandle is used after shutdown() has
 * returned.
 *
 * The native side also clears both network event callbacks during
 * teardown. The managed references held by network-events.ts are NOT
 * released automatically; call network.clearNetworkEvent() explicitly
 * before shutdown if you want to release them.
 */
export function shutdown(): void {
    funcs().LF_Shutdown();
}