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
import { readJsonTolerant } from "./lf-io";

let _funcs: NativeFunctions | null = null;

function funcs(): NativeFunctions {
    if (_funcs === null) _funcs = getBinding().funcs;
    return _funcs;
}

export type CallbackErrorHandler = (
    source: string,
    err: unknown,
) => void;

let _callbackErrorHandler: CallbackErrorHandler | null = null;

export function setCallbackErrorHandler(
    fn: CallbackErrorHandler | null,
): void {
    if (fn !== null && typeof fn !== "function") {
        throw new TypeError(
            "setCallbackErrorHandler: fn must be a function or null.");
    }
    _callbackErrorHandler = fn;
}

export function getCallbackErrorHandler(): CallbackErrorHandler | null {
    return _callbackErrorHandler;
}

function reportCallbackError(source: string, err: unknown): void {
    if (_callbackErrorHandler !== null) {
        try {
            _callbackErrorHandler(source, err);
        } catch {
            /* broken handler must not escape */
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
        /* stderr unavailable */
    }
}

setCallbackErrorReporter(reportCallbackError);

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
        throw new TypeError(
            "Timeout must be a number or a BigInt.");
    }
    if (v < 0n) {
        throw new RangeError("Timeout must be non-negative.");
    }
    const UINT64_MAX = (1n << 64n) - 1n;
    if (v > UINT64_MAX) {
        throw new RangeError(
            "Timeout exceeds the 64-bit unsigned range.");
    }
    return v;
}

function timeoutToNumber(
    value: number | bigint | undefined,
): number {
    if (value === undefined) return 5000;
    if (typeof value === "bigint") return Number(value);
    return value;
}

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

function toTp2pUid(bytes: Uint8Array): { bytes: Uint8Array } {
    const arr = new Uint8Array(32);
    arr.set(bytes);
    return { bytes: arr };
}

function makeJsonDeserializer<T>(): (rawResult: unknown) => T {
    return function (rawResult: unknown): T {
        if (!rawResult) return null as unknown as T;
        const h = DataHandle.fromRaw(rawResult, false);
        return readJsonTolerant<T>(h) as T;
    };
}

export function resetPrepare(): void {
    funcs().LF_ResetPrepare();
}

export function prepareService(
    listeningAddr: string,
    physicsAddr: string,
): number {
    if (typeof listeningAddr !== "string") {
        throw new TypeError(
            "prepareService: listeningAddr must be a string.");
    }
    if (typeof physicsAddr !== "string") {
        throw new TypeError(
            "prepareService: physicsAddr must be a string.");
    }
    return funcs().LF_PrepareService(listeningAddr, physicsAddr);
}

export function prepareClient(
    physicsAddr: string,
    app: AppHandle | null = null,
): number {
    if (typeof physicsAddr !== "string") {
        throw new TypeError(
            "prepareClient: physicsAddr must be a string.");
    }
    if (app !== null && !(app instanceof AppHandle)) {
        throw new TypeError(
            "prepareClient: app must be an AppHandle or null.");
    }
    const rawApp = app === null ? null : app.raw;
    return funcs().LF_PrepareClient(physicsAddr, rawApp);
}

export function prepareDone(): number {
    return funcs().LF_PrepareDone();
}

export function exitMainThread(): void {
    funcs().LF_ExitMainThread();
}

export function setOption(option: string, value: string): void {
    if (typeof option !== "string") {
        throw new TypeError("setOption: option must be a string.");
    }
    if (typeof value !== "string") {
        throw new TypeError("setOption: value must be a string.");
    }
    funcs().LF_SetOption(option, value);
}

export function getOption(option: string): string {
    if (typeof option !== "string") {
        throw new TypeError("getOption: option must be a string.");
    }
    const v = funcs().LF_GetOption(option);
    return typeof v === "string" ? v : "";
}

export function generateAppName(): string {
    const name = funcs().LF_Generate_AppName();
    return typeof name === "string" ? name : "";
}

export function getAppName(app: AppHandle): string {
    if (!(app instanceof AppHandle)) {
        throw new TypeError("getAppName: app must be an AppHandle.");
    }
    if (!app.isValid) {
        throw new LingoFuseObjectDisposedError("AppHandle");
    }
    const name = funcs().LF_Get_AppName(app.raw);
    return typeof name === "string" ? name : "";
}

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
        (cb, op) => funcs().LF_Async_Call(
            appName, param.raw, op.dataPtr, cb),
        onResult,
        userData,
        makeJsonDeserializer<TRes>(),
    );
}

export function callPromise<TRes = unknown>(
    appName: string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): CallPromise<TRes> {
    if (typeof appName !== "string") {
        throw new TypeError("callPromise: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "callPromise: param must be a DataHandle.");
    }
    const timeout = timeoutToNumber(timeoutMs);
    return runAsyncWithPromise<TRes>(
        (cb, op) => funcs().LF_Async_Call(
            appName, param.raw, op.dataPtr, cb),
        makeJsonDeserializer<TRes>(),
        timeout,
    );
}

export function notify(appName: string, param: DataHandle): void {
    if (typeof appName !== "string") {
        throw new TypeError("notify: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("notify: param must be a DataHandle.");
    }
    funcs().LF_Notify(appName, param.raw);
}

export function sequencedNotify(
    appName: string,
    param: DataHandle,
): void {
    if (typeof appName !== "string") {
        throw new TypeError(
            "sequencedNotify: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "sequencedNotify: param must be a DataHandle.");
    }
    funcs().LF_Sequenced_Notify(appName, param.raw);
}

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
        toTp2pUid(bytes), param.raw, timeout);
    if (result === null || result === undefined) {
        throw new LingoFuseCallError(
            "LF_UID_Call returned a null handle.");
    }
    return DataHandle.fromRaw(result, true);
}

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
        throw new TypeError(
            "uidCallAsync: param must be a DataHandle.");
    }
    if (typeof onResult !== "function") {
        throw new TypeError(
            "uidCallAsync: onResult must be a function.");
    }
    const bytes = normalizeUid(uid);
    const uidArg = toTp2pUid(bytes);
    return runLegacyOp<TRes>(
        (cb, op) => funcs().LF_UID_Async_Call(
            uidArg, param.raw, op.dataPtr, cb),
        onResult,
        userData,
        makeJsonDeserializer<TRes>(),
    );
}

export function uidCallPromise<TRes = unknown>(
    uid: Uint8Array | string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): CallPromise<TRes> {
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "uidCallPromise: param must be a DataHandle.");
    }
    const bytes = normalizeUid(uid);
    const uidArg = toTp2pUid(bytes);
    const timeout = timeoutToNumber(timeoutMs);
    return runAsyncWithPromise<TRes>(
        (cb, op) => funcs().LF_UID_Async_Call(
            uidArg, param.raw, op.dataPtr, cb),
        makeJsonDeserializer<TRes>(),
        timeout,
    );
}

export function uidNotify(
    uid: Uint8Array | string,
    param: DataHandle,
): void {
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "uidNotify: param must be a DataHandle.");
    }
    const bytes = normalizeUid(uid);
    funcs().LF_UID_Notify(toTp2pUid(bytes), param.raw);
}

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

export function p2pnameCall(
    p2pName: string,
    param: DataHandle,
    timeoutMs: number | bigint = 5000,
): DataHandle {
    if (typeof p2pName !== "string") {
        throw new TypeError(
            "p2pnameCall: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "p2pnameCall: param must be a DataHandle.");
    }
    const timeout = normaliseTimeout(timeoutMs);
    const result = funcs().LF_P2PNAME_Call(
        p2pName, param.raw, timeout);
    if (result === null || result === undefined) {
        throw new LingoFuseCallError(
            "LF_P2PNAME_Call returned a null handle.");
    }
    return DataHandle.fromRaw(result, true);
}

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
        throw new TypeError(
            "p2pnameCallAsync: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "p2pnameCallAsync: param must be a DataHandle.");
    }
    if (typeof onResult !== "function") {
        throw new TypeError(
            "p2pnameCallAsync: onResult must be a function.");
    }
    return runLegacyOp<TRes>(
        (cb, op) => funcs().LF_P2PNAME_Async_Call(
            p2pName, param.raw, op.dataPtr, cb),
        onResult,
        userData,
        makeJsonDeserializer<TRes>(),
    );
}

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
        (cb, op) => funcs().LF_P2PNAME_Async_Call(
            p2pName, param.raw, op.dataPtr, cb),
        makeJsonDeserializer<TRes>(),
        timeout,
    );
}

export function p2pnameNotify(
    p2pName: string,
    param: DataHandle,
): void {
    if (typeof p2pName !== "string") {
        throw new TypeError(
            "p2pnameNotify: p2pName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError(
            "p2pnameNotify: param must be a DataHandle.");
    }
    funcs().LF_P2PNAME_Notify(p2pName, param.raw);
}

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

export function shutdown(): void {
    funcs().LF_Shutdown();
}