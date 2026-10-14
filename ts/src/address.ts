// =============================================================================
//  address.ts
// -----------------------------------------------------------------------------
//  Three-addressing-mode abstraction for LingoFuse remote calls.
//
//  This module implements the three orthogonal addressing modes that the
//  LingoFuse C ABI supports, and gives each of them a uniform set of
//  call shapes:
//
//    AppTarget       -- address a logical App by its name.
//    UIDTarget       -- address a specific session by its 32-byte UID.
//    P2PNameTarget   -- address a group of clients by a user-supplied name.
//
//  CALL SHAPES
//  -----------
//  Each Target exposes three parallel styles for request/response:
//
//    1. Promise (default; recommended for new code):
//
//         const result = await target.call<Req, Res>(
//             "api", payload, { timeoutMs: 3000 });
//
//    2. Inline callback (for event-oriented code):
//
//         target.callAsync<Req, Res>("api", payload, (result, error) => {
//             // Business code goes directly in the callback body.
//         });
//
//    3. Synchronous (for code that must block):
//
//         const result = target.callSync<Req, Res>("api", payload, {
//             timeoutMs: 3000,
//         });
//
//  The three styles share the same payload serialization policy (JSON
//  via lf-io) and the same error envelope. They can be freely mixed.
//
//  One-way notifications are provided by `notify` and `sequencedNotify`.
//
//  ADDRESSING SEMANTICS
//  --------------------
//    +------------------+---------------+--------------+------------------+
//    | Mode             | Routing key   | Local-first? | Load-balanced?   |
//    +==================+===============+==============+==================+
//    | AppTarget        | App name      | YES          | N/A              |
//    | UIDTarget        | UID (32 B)    | YES          | N/A              |
//    | P2PNameTarget    | Group name    | NO           | YES (server)     |
//    +------------------+---------------+--------------+------------------+
//
//  Local-first means: if the caller process itself hosts a matching
//  App / client for the addressing key, the call is serviced locally
//  without touching the network. P2PName deliberately opts out of
//  local-first routing: the server-side dispatcher owns the load-
//  balancing state, and short-cutting locally would defeat it.
//
//  UID LIFECYCLE
//  -------------
//  A UID is a session identifier generated during TunnelLink. It is
//  regenerated on every reconnect: callers that cache a UID MUST
//  re-probe it after a link loss.
//
//  To learn a client's own UID, use the "whoami" pattern: register a
//  Call API on the target side whose callback reads the caller's UID
//  from its INPUT handle via DataHandle.getP2PUid(), and call it from
//  the client.
//
//  ZERO-HANDLE DESIGN
//  ------------------
//  The Target methods NEVER expose DataHandle to the caller. Each
//  public method:
//
//    1. Creates a fresh DataHandle internally.
//    2. Serializes the JS payload into it.
//    3. Dispatches the native request.
//    4. Disposes the handle in a finally block.
//
//  The result is delivered to the caller as a plain JavaScript value
//  (or a Promise of one). There is no manual dispose, no raw pointer,
//  and no risk of an accidental double-free.
//
//  Low-level callers who need direct access to DataHandle should use
//  framework.ts instead, which keeps the historical handle-based API.
//
//  PAYLOAD SERIALIZATION
//  ---------------------
//  Payloads are serialized with lf-io (JSON, compact, no \uXXXX escapes,
//  NUL-terminated). This is the same policy used by every other
//  LingoFuse binding.
//
//  All code and documentation are in English.
// =============================================================================

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
import { writeJson, readJson } from "./lf-io";

// -----------------------------------------------------------------------------
//  UID normalization helpers
// -----------------------------------------------------------------------------

/**
 * Normalize a UID value into a 32-byte Uint8Array.
 *
 * Accepts:
 *   - Uint8Array of length 32
 *   - 64-character hexadecimal string (case-insensitive)
 *
 * @throws {TypeError}  When uid is neither a Uint8Array nor a string.
 * @throws {RangeError} When the length is not 32 (bytes) or 64 (hex).
 * @throws {RangeError} When the hex string contains non-hex characters.
 *
 * This function is also re-exported (prefixed with `_`) for use by
 * status.ts. The two modules keep separate copies to avoid a load-time
 * circular dependency between them.
 */
export function normalizeUid(uid: Uint8Array | string): Uint8Array {
    if (uid instanceof Uint8Array) {
        if (uid.length !== 32) {
            throw new RangeError(
                `UID must be exactly 32 bytes, got ${uid.length}.`,
            );
        }
        // Defensive copy: callers may reuse or mutate their buffer.
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

/**
 * Convert a 32-byte Uint8Array into a value the Koffi binding can pass
 * to LF_UID_* functions.
 *
 * The argument-role TP2P_UID type declared in binding.ts is a Koffi
 * struct wrapping a 32-byte array (matching the C header's
 * `struct { uint8_t bytes[32]; }`). Koffi requires the value passed at
 * the call site to have that same shape, so we return an object with a
 * `bytes` field.
 *
 * A fresh Uint8Array is allocated so that Koffi cannot hold a reference
 * to the caller's buffer across the native call.
 */
export function toTp2pUid(bytes: Uint8Array): { bytes: Uint8Array } {
    const arr = new Uint8Array(32);
    arr.set(bytes);
    return { bytes: arr };
}

// -----------------------------------------------------------------------------
//  Internal result-deserialization helpers
// -----------------------------------------------------------------------------

/**
 * Build a deserializer that reads the JSON payload from an async result
 * handle. Called on the JS thread inside the native callback window, so
 * the handle is still valid.
 */
function makeJsonDeserializer<T>(): (rawResult: unknown) => T {
    return function (rawResult: unknown): T {
        if (!rawResult) return null as unknown as T;
        const h = DataHandle.fromRaw(rawResult, false);
        h.position = 0;
        return readJson<T>(h) as T;
    };
}

/**
 * Consume a synchronous Call result handle: check for a null handle or
 * a zero-size (timeout) handle, then read the JSON payload.
 *
 * The caller owns the returned handle, so we dispose it after reading.
 */
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
        const size = h.size;
        if (size === 0) {
            throw new LingoFuseTimeoutError(
                `Call to '${apiName}' on ${targetDesc} timed out after ` +
                `${timeoutMs}ms.`,
                { targetApi: apiName, timeoutMs },
            );
        }
        h.position = 0;
        return readJson<T>(h) as T;
    } finally {
        h.dispose();
    }
}

// -----------------------------------------------------------------------------
//  Target base class
// -----------------------------------------------------------------------------

/** Options accepted by every Target constructor and every call method. */
export interface TargetOptions {
    /** Default timeout in milliseconds. Defaults to 5000. */
    readonly timeoutMs?: number;
}

/** Per-call options accepted by the request/response methods. */
export interface CallOptions {
    /** Timeout in milliseconds. Falls back to the Target default. */
    readonly timeoutMs?: number;
}

/**
 * Abstract base class for the three addressing modes.
 *
 * Concrete subclasses implement the protected _rawIssue* hooks, one per
 * underlying C ABI function family. The public API is defined once here.
 */
export abstract class Target {
    protected readonly _funcs: NativeFunctions;
    protected readonly _defaultTimeoutMs: number;

    public constructor(opts: TargetOptions = {}) {
        this._funcs = getBinding().funcs;
        this._defaultTimeoutMs = opts.timeoutMs ?? 5000;
    }

    // ------------------------------------------------------------------
    // Protected hooks (subclasses must override)
    // ------------------------------------------------------------------

    protected abstract _rawIssueSyncCall(
        apiName: string,
        param: DataHandle,
        timeoutMs: number,
    ): unknown;

    protected abstract _rawIssueAsyncCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
    ): number;

    protected abstract _rawIssueAsyncSequencedCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
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

    /**
     * Stable string key for use as a Map / Set key.
     *
     * TypeScript's Map and Set compare keys by reference, not by value.
     * A caller who wants value-based lookup must use this method as the
     * map key:
     *
     *     const m = new Map<string, number>();
     *     m.set(new AppTarget("X").hashKey(), 1);
     *     m.get(new AppTarget("X").hashKey());   // => 1
     *
     * Subclasses return a key that is unique to their addressing mode
     * (an `app:` / `uid:` / `p2p:` prefix), so two different modes with
     * the same string payload never produce the same key.
     */
    public abstract hashKey(): string;

    // ==================================================================
    // Public API: Call (Promise style, default)
    // ==================================================================

    /**
     * Send a non-blocking request. Returns a CallPromise that resolves
     * with the deserialized result.
     *
     * The CallPromise is a thenable, so `await target.call(...)` works.
     *
     * All handles are created and disposed internally. The caller
     * passes and receives plain JavaScript values.
     */
    public call<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null = null,
        options: CallOptions = {},
    ): CallPromise<TRes> {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            return runAsyncWithPromise<TRes>(
                (cb) => this._rawIssueAsyncCall(apiName, param, cb),
                makeJsonDeserializer<TRes>(),
                timeoutMs,
            );
        } finally {
            // The native side has already copied the payload by the
            // time runAsyncWithPromise returns. Safe to dispose.
            param.dispose();
        }
    }

    // ==================================================================
    // Public API: Call (inline callback style)
    // ==================================================================

    /**
     * Send a non-blocking request with an inline callback.
     *
     * The callback fires on the JS event loop (delivered from the native
     * worker thread by the Koffi bridge) and receives:
     *
     *     onResult(result, error, userData)
     *
     *   - result   : the deserialized JSON value, or null on error.
     *   - error    : a LingoFuseError / LingoFuseTimeoutError, or null.
     *   - userData : the value passed at the call site, or undefined.
     *
     * The callback MUST NOT block. Exceptions raised inside it are
     * caught and logged to stderr; they never escape into the native
     * stack.
     *
     * @returns 1 if the request was queued, 0 otherwise.
     */
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
                "Target.callAsync: onResult must be a function.",
            );
        }
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            return runLegacyOp<TRes>(
                (cb) => this._rawIssueAsyncCall(apiName, param, cb),
                onResult,
                userData,
                makeJsonDeserializer<TRes>(),
            );
        } finally {
            param.dispose();
        }
    }

    // ==================================================================
    // Public API: Call (synchronous)
    // ==================================================================

    /**
     * Send a blocking request. Returns the deserialized result.
     *
     * @throws {LingoFuseTimeoutError} On a zero-size result handle.
     * @throws {LingoFuseCallError}    On a null result handle.
     * @throws {LingoFuseIoError}      On a JSON deserialization failure.
     */
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
                apiName,
                param,
                timeoutMs,
            );
            return consumeSyncResult<TRes>(
                rawResult,
                apiName,
                this._describe(),
                timeoutMs,
            );
        } finally {
            param.dispose();
        }
    }

    /**
     * Non-throwing counterpart of callSync. Returns null on timeout,
     * null-handle failure, or any deserialization error.
     */
    public tryCallSync<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null = null,
        options: CallOptions = {},
    ): TRes | null {
        try {
            return this.callSync<TReq, TRes>(apiName, payload, options);
        } catch {
            return null;
        }
    }

    // ==================================================================
    // Public API: Sequenced Call (FIFO per target key + API)
    // ==================================================================

    /**
     * Send a non-blocking, FIFO-ordered request. Returns a CallPromise.
     *
     * The FIFO guarantee applies per (target key, API) pair, matching
     * the native sequencing implementation.
     */
    public sequencedCall<TReq = unknown, TRes = unknown>(
        apiName: string,
        payload: TReq | null = null,
        options: CallOptions = {},
    ): CallPromise<TRes> {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            return runAsyncWithPromise<TRes>(
                (cb) => this._rawIssueAsyncSequencedCall(apiName, param, cb),
                makeJsonDeserializer<TRes>(),
                timeoutMs,
            );
        } finally {
            param.dispose();
        }
    }

    /** Send a non-blocking, FIFO-ordered request with an inline callback. */
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
                "Target.sequencedCallAsync: onResult must be a function.",
            );
        }
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            return runLegacyOp<TRes>(
                (cb) => this._rawIssueAsyncSequencedCall(apiName, param, cb),
                onResult,
                userData,
                makeJsonDeserializer<TRes>(),
            );
        } finally {
            param.dispose();
        }
    }

    // ==================================================================
    // Public API: Notify (one-way)
    // ==================================================================

    /** Send a one-way notification. Returns immediately. */
    public notify<TReq = unknown>(
        apiName: string,
        payload: TReq | null = null,
    ): void {
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            this._rawIssueNotify(apiName, param);
        } finally {
            param.dispose();
        }
    }

    /** Send a one-way, FIFO-ordered notification. Returns immediately. */
    public sequencedNotify<TReq = unknown>(
        apiName: string,
        payload: TReq | null = null,
    ): void {
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            this._rawIssueSequencedNotify(apiName, param);
        } finally {
            param.dispose();
        }
    }
}

// =============================================================================
//  AppTarget
// =============================================================================

/**
 * Address a logical App by its name.
 *
 * Routing: local-first (the caller's own process wins if it hosts a
 * matching App). Otherwise, the request travels the C4 mesh.
 */
export class AppTarget extends Target {
    private readonly _appName: string;

    public constructor(appName: string, opts: TargetOptions = {}) {
        super(opts);
        if (typeof appName !== "string") {
            throw new TypeError("AppTarget: appName must be a string.");
        }
        this._appName = appName;
    }

    public get appName(): string {
        return this._appName;
    }

    /**
     * Value-based string key. See Target.hashKey for the rationale.
     */
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
        return this._funcs.LF_Call(this._appName, param.raw, timeoutMs);
    }

    protected _rawIssueAsyncCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
    ): number {
        return this._funcs.LF_Async_Call(
            this._appName,
            param.raw,
            null,
            cb,
        );
    }

    protected _rawIssueAsyncSequencedCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
    ): number {
        return this._funcs.LF_Async_Sequenced_Call(
            this._appName,
            param.raw,
            null,
            cb,
        );
    }

    protected _rawIssueNotify(apiName: string, param: DataHandle): void {
        this._funcs.LF_Notify(this._appName, param.raw);
    }

    protected _rawIssueSequencedNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        this._funcs.LF_Sequenced_Notify(this._appName, param.raw);
    }
}

// =============================================================================
//  UIDTarget
// =============================================================================

/**
 * Address a specific session by its 32-byte UID.
 *
 * Routing: local-first. UID is a session identifier regenerated on
 * every TunnelLink; a cached UID must be re-probed after a reconnect.
 */
export class UIDTarget extends Target {
    private readonly _uidBytes: Uint8Array;
    private readonly _uidArray: { bytes: Uint8Array };

    /**
     * @param uid  A 32-byte Uint8Array, or a 64-character hex string
     *             (case-insensitive).
     */
    public constructor(
        uid: Uint8Array | string,
        opts: TargetOptions = {},
    ) {
        super(opts);
        this._uidBytes = normalizeUid(uid);
        this._uidArray = toTp2pUid(this._uidBytes);
    }

    /** Defensive copy of the 32-byte UID. */
    public get uidBytes(): Uint8Array {
        return new Uint8Array(this._uidBytes);
    }

    /** 64-character lowercase hexadecimal representation. */
    public get uidHex(): string {
        let out = "";
        for (const b of this._uidBytes) {
            out += b.toString(16).padStart(2, "0");
        }
        return out;
    }

    /** Value-based string key. See Target.hashKey for the rationale. */
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
        return this._funcs.LF_UID_Call(
            this._uidArray,
            param.raw,
            timeoutMs,
        );
    }

    protected _rawIssueAsyncCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
    ): number {
        return this._funcs.LF_UID_Async_Call(
            this._uidArray,
            param.raw,
            null,
            cb,
        );
    }

    protected _rawIssueAsyncSequencedCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
    ): number {
        return this._funcs.LF_UID_Async_Sequenced_Call(
            this._uidArray,
            param.raw,
            null,
            cb,
        );
    }

    protected _rawIssueNotify(apiName: string, param: DataHandle): void {
        this._funcs.LF_UID_Notify(this._uidArray, param.raw);
    }

    protected _rawIssueSequencedNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        this._funcs.LF_UID_Sequenced_Notify(this._uidArray, param.raw);
    }
}

// =============================================================================
//  P2PNameTarget
// =============================================================================

/**
 * Address a group of clients by a user-supplied name.
 *
 * Routing: NOT local-first. The request is always forwarded to the
 * server-side dispatcher, which performs load balancing (Cycle_Anchor)
 * or sticky routing (FixedSequenced) across the group members.
 *
 * Use this when the caller does not care which specific worker handles
 * the request, only that some worker in the group does.
 */
export class P2PNameTarget extends Target {
    private readonly _groupName: string;

    public constructor(groupName: string, opts: TargetOptions = {}) {
        super(opts);
        if (typeof groupName !== "string") {
            throw new TypeError(
                "P2PNameTarget: groupName must be a string.",
            );
        }
        this._groupName = groupName;
    }

    public get groupName(): string {
        return this._groupName;
    }

    /** Value-based string key. See Target.hashKey for the rationale. */
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
        return this._funcs.LF_P2PNAME_Call(
            this._groupName,
            param.raw,
            timeoutMs,
        );
    }

    protected _rawIssueAsyncCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
    ): number {
        return this._funcs.LF_P2PNAME_Async_Call(
            this._groupName,
            param.raw,
            null,
            cb,
        );
    }

    protected _rawIssueAsyncSequencedCall(
        apiName: string,
        param: DataHandle,
        cb: unknown,
    ): number {
        return this._funcs.LF_P2PNAME_Async_Sequenced_Call(
            this._groupName,
            param.raw,
            null,
            cb,
        );
    }

    protected _rawIssueNotify(apiName: string, param: DataHandle): void {
        this._funcs.LF_P2PNAME_Notify(this._groupName, param.raw);
    }

    protected _rawIssueSequencedNotify(
        apiName: string,
        param: DataHandle,
    ): void {
        this._funcs.LF_P2PNAME_Sequenced_Notify(
            this._groupName,
            param.raw,
        );
    }
}

// =============================================================================
//  Internal re-exports (for status.ts and future modules)
// =============================================================================

/**
 * The UID normalisation helper, exported under an underscore-prefixed
 * alias for parity with the JavaScript binding. Not part of the public
 * API; callers should use the Target classes instead.
 *
 * @internal
 */
export const _normalizeUid = normalizeUid;

/**
 * The TP2P_UID wrapper helper, exported under an underscore-prefixed
 * alias for parity with the JavaScript binding. Not part of the public
 * API.
 *
 * @internal
 */
export const _toTp2pUid = toTp2pUid;