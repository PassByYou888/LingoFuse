import { getBinding } from "./binding";
import type { NativeFunctions } from "./binding";
import { DataHandle } from "./data-handle";
import {
    LingoFuseCallError,
    LingoFuseError,
    LingoFuseTimeoutError,
} from "./errors";
import {
    CallPromise,
    runAsyncWithPromise,
    runLegacyOp,
} from "./async-support";
import { writeJson, readJsonTolerant } from "./lf-io";

export function normalizeUid(
    uid: Uint8Array | string,
): Uint8Array {
    if (uid instanceof Uint8Array) {
        if (uid.length !== 32) {
            throw new RangeError(
                `UID must be exactly 32 bytes, got ${uid.length}.`,
            );
        }
        return new Uint8Array(uid);
    }
    if (typeof uid === "string") {
        const hex = uid.trim();
        if (hex.length !== 64) {
            throw new RangeError(
                `UID hex string must be exactly 64 characters, ` +
                `got ${hex.length}.`,
            );
        }
        if (!/^[0-9a-fA-F]+$/.test(hex)) {
            throw new RangeError(
                "UID hex string contains non-hex characters.",
            );
        }
        const out = new Uint8Array(32);
        for (let i = 0; i < 32; i++) {
            out[i] = parseInt(hex.substr(i * 2, 2), 16);
        }
        return out;
    }
    throw new TypeError(
        `UID must be a Uint8Array(32) or a 64-character hex string, ` +
        `got ${uid === null ? "null" : typeof uid}.`,
    );
}

export function toTp2pUid(
    bytes: Uint8Array,
): { bytes: Uint8Array } {
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

function consumeSyncResult<T>(
    rawResult: unknown,
    apiName: string,
    targetDesc: string,
    timeoutMs: number,
): T {
    if (!rawResult) {
        throw new LingoFuseCallError(
            `Call to '${apiName}' on ${targetDesc} returned a null handle.`,
            { targetApi: apiName },
        );
    }
    const h = DataHandle.fromRaw(rawResult, true);
    try {
        if (h.size === 0) {
            throw new LingoFuseTimeoutError(
                `Call to '${apiName}' on ${targetDesc} timed out after ` +
                `${timeoutMs}ms.`,
                { targetApi: apiName, timeoutMs },
            );
        }
        return readJsonTolerant<T>(h) as T;
    } finally {
        h.dispose();
    }
}

export interface TargetOptions {
    readonly timeoutMs?: number;
}

export interface CallOptions {
    readonly timeoutMs?: number;
}

interface AsyncOpView {
    readonly dataPtr: unknown;
}

export abstract class Target {
    protected readonly _funcs: NativeFunctions;
    protected readonly _defaultTimeoutMs: number;

    public constructor(opts: TargetOptions = {}) {
        this._funcs = getBinding().funcs;
        this._defaultTimeoutMs = opts.timeoutMs ?? 5000;
    }

    protected abstract _rawIssueSyncCall(
        apiName: string,
        param: DataHandle,
        timeoutMs: number,
    ): unknown;

    protected abstract _rawIssueAsyncCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
        op: AsyncOpView,
    ): number;

    protected abstract _rawIssueAsyncSequencedCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
        op: AsyncOpView,
    ): number;

    protected abstract _rawIssueNotify(
        apiName: string,
        param: DataHandle,
    ): void;

    protected abstract _rawIssueSequencedNotify(
        apiName: string,
        param: DataHandle,
    ): void;

    protected abstract _describe(): string;

    public abstract hashKey(): string;

    public call<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null = null,
        options: CallOptions = {},
    ): CallPromise<TRes> {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        let promise: CallPromise<TRes>;
        try {
            writeJson(param, payload);
            promise = runAsyncWithPromise<TRes>(
                (cb, op) => this._rawIssueAsyncCall(
                    apiName, param, cb, op),
                makeJsonDeserializer<TRes>(),
                timeoutMs,
            );
        } catch (err) {
            try { param.dispose(); } catch { /* ignore */ }
            throw err;
        }
        promise.then(
            () => { try { param.dispose(); } catch { /* ignore */ } },
            () => { try { param.dispose(); } catch { /* ignore */ } },
        );
        return promise;
    }

    public callAsync<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null,
        onResult: (
            result: TRes | null,
            error: Error | null,
            userData: unknown,
        ) => void,
        userData: unknown = undefined,
    ): number {
        if (typeof onResult !== "function") {
            throw new TypeError(
                "Target.callAsync: onResult must be a function.");
        }
        const param = new DataHandle(apiName);
        let ret: number;
        try {
            writeJson(param, payload);
            ret = runLegacyOp<TRes>(
                (cb, op) => this._rawIssueAsyncCall(
                    apiName, param, cb, op),
                (result, error, ud) => {
                    try { param.dispose(); } catch { /* ignore */ }
                    onResult(result, error, ud);
                },
                userData,
                makeJsonDeserializer<TRes>(),
            );
        } catch (err) {
            try { param.dispose(); } catch { /* ignore */ }
            throw err;
        }
        return ret;
    }

    public callSync<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null = null,
        options: CallOptions = {},
    ): TRes {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            const rawResult = this._rawIssueSyncCall(
                apiName, param, timeoutMs);
            return consumeSyncResult<TRes>(
                rawResult,
                apiName,
                this._describe(),
                timeoutMs,
            );
        } finally {
            try { param.dispose(); } catch { /* ignore */ }
        }
    }

    public tryCallSync<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null = null,
        options: CallOptions = {},
    ): TRes | null {
        try {
            return this.callSync<TReq, TRes>(
                apiName, payload, options);
        } catch {
            return null;
        }
    }

    public sequencedCall<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null = null,
        options: CallOptions = {},
    ): CallPromise<TRes> {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        let promise: CallPromise<TRes>;
        try {
            writeJson(param, payload);
            promise = runAsyncWithPromise<TRes>(
                (cb, op) => this._rawIssueAsyncSequencedCall(
                    apiName, param, cb, op),
                makeJsonDeserializer<TRes>(),
                timeoutMs,
            );
        } catch (err) {
            try { param.dispose(); } catch { /* ignore */ }
            throw err;
        }
        promise.then(
            () => { try { param.dispose(); } catch { /* ignore */ } },
            () => { try { param.dispose(); } catch { /* ignore */ } },
        );
        return promise;
    }

    public sequencedCallAsync<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null,
        onResult: (
            result: TRes | null,
            error: Error | null,
            userData: unknown,
        ) => void,
        userData: unknown = undefined,
    ): number {
        if (typeof onResult !== "function") {
            throw new TypeError(
                "Target.sequencedCallAsync: onResult must be a function.");
        }
        const param = new DataHandle(apiName);
        let ret: number;
        try {
            writeJson(param, payload);
            ret = runLegacyOp<TRes>(
                (cb, op) => this._rawIssueAsyncSequencedCall(
                    apiName, param, cb, op),
                (result, error, ud) => {
                    try { param.dispose(); } catch { /* ignore */ }
                    onResult(result, error, ud);
                },
                userData,
                makeJsonDeserializer<TRes>(),
            );
        } catch (err) {
            try { param.dispose(); } catch { /* ignore */ }
            throw err;
        }
        return ret;
    }

    public notify<TReq = unknown>(
        apiName: string,
        payload: TReq | null = null,
    ): void {
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            this._rawIssueNotify(apiName, param);
        } finally {
            try { param.dispose(); } catch { /* ignore */ }
        }
    }

    public sequencedNotify<TReq = unknown>(
        apiName: string,
        payload: TReq | null = null,
    ): void {
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            this._rawIssueSequencedNotify(apiName, param);
        } finally {
            try { param.dispose(); } catch { /* ignore */ }
        }
    }
}

export class AppTarget extends Target {
    private readonly _appName: string;

    public constructor(
        appName: string,
        opts: TargetOptions = {},
    ) {
        super(opts);
        if (typeof appName !== "string") {
            throw new TypeError(
                "AppTarget: appName must be a string.");
        }
        this._appName = appName;
    }

    public get appName(): string {
        return this._appName;
    }

    public hashKey(): string {
        return `app:${this._appName}`;
    }

    protected _describe(): string {
        return `app(${JSON.stringify(this._appName)})`;
    }

    protected _rawIssueSyncCall(
        apiName: string,
        param: DataHandle,
        timeoutMs: number,
    ): unknown {
        void apiName;
        return this._funcs.LF_Call(
            this._appName, param.raw, timeoutMs);
    }

    protected _rawIssueAsyncCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
        op: AsyncOpView,
    ): number {
        void apiName;
        return this._funcs.LF_Async_Call(
            this._appName, param.raw, op.dataPtr, cb);
    }

    protected _rawIssueAsyncSequencedCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
        op: AsyncOpView,
    ): number {
        void apiName;
        return this._funcs.LF_Async_Sequenced_Call(
            this._appName, param.raw, op.dataPtr, cb);
    }

    protected _rawIssueNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        void apiName;
        this._funcs.LF_Notify(this._appName, param.raw);
    }

    protected _rawIssueSequencedNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        void apiName;
        this._funcs.LF_Sequenced_Notify(this._appName, param.raw);
    }
}

export class UIDTarget extends Target {
    private readonly _uidBytes: Uint8Array;
    private readonly _uidArray: { bytes: Uint8Array };

    public constructor(
        uid: Uint8Array | string,
        opts: TargetOptions = {},
    ) {
        super(opts);
        this._uidBytes = normalizeUid(uid);
        this._uidArray = toTp2pUid(this._uidBytes);
    }

    public get uidBytes(): Uint8Array {
        return new Uint8Array(this._uidBytes);
    }

    public get uidHex(): string {
        let out = "";
        for (const b of this._uidBytes) {
            out += b.toString(16).padStart(2, "0");
        }
        return out;
    }

    public hashKey(): string {
        return `uid:${this.uidHex}`;
    }

    protected _describe(): string {
        return `uid(${this.uidHex})`;
    }

    protected _rawIssueSyncCall(
        apiName: string,
        param: DataHandle,
        timeoutMs: number,
    ): unknown {
        void apiName;
        return this._funcs.LF_UID_Call(
            this._uidArray, param.raw, timeoutMs);
    }

    protected _rawIssueAsyncCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
        op: AsyncOpView,
    ): number {
        void apiName;
        return this._funcs.LF_UID_Async_Call(
            this._uidArray, param.raw, op.dataPtr, cb);
    }

    protected _rawIssueAsyncSequencedCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
        op: AsyncOpView,
    ): number {
        void apiName;
        return this._funcs.LF_UID_Async_Sequenced_Call(
            this._uidArray, param.raw, op.dataPtr, cb);
    }

    protected _rawIssueNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        void apiName;
        this._funcs.LF_UID_Notify(this._uidArray, param.raw);
    }

    protected _rawIssueSequencedNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        void apiName;
        this._funcs.LF_UID_Sequenced_Notify(this._uidArray, param.raw);
    }
}

export class P2PNameTarget extends Target {
    private readonly _groupName: string;

    public constructor(
        groupName: string,
        opts: TargetOptions = {},
    ) {
        super(opts);
        if (typeof groupName !== "string") {
            throw new TypeError(
                "P2PNameTarget: groupName must be a string.");
        }
        this._groupName = groupName;
    }

    public get groupName(): string {
        return this._groupName;
    }

    public hashKey(): string {
        return `p2p:${this._groupName}`;
    }

    protected _describe(): string {
        return `p2pname(${JSON.stringify(this._groupName)})`;
    }

    protected _rawIssueSyncCall(
        apiName: string,
        param: DataHandle,
        timeoutMs: number,
    ): unknown {
        void apiName;
        return this._funcs.LF_P2PNAME_Call(
            this._groupName, param.raw, timeoutMs);
    }

    protected _rawIssueAsyncCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
        op: AsyncOpView,
    ): number {
        void apiName;
        return this._funcs.LF_P2PNAME_Async_Call(
            this._groupName, param.raw, op.dataPtr, cb);
    }

    protected _rawIssueAsyncSequencedCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
        op: AsyncOpView,
    ): number {
        void apiName;
        return this._funcs.LF_P2PNAME_Async_Sequenced_Call(
            this._groupName, param.raw, op.dataPtr, cb);
    }

    protected _rawIssueNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        void apiName;
        this._funcs.LF_P2PNAME_Notify(this._groupName, param.raw);
    }

    protected _rawIssueSequencedNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        void apiName;
        this._funcs.LF_P2PNAME_Sequenced_Notify(
            this._groupName, param.raw);
    }
}

export const _normalizeUid = normalizeUid;
export const _toTp2pUid = toTp2pUid;