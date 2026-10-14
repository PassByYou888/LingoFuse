/**
 * @file address.js
 * @brief Three-addressing-mode abstraction for LingoFuse remote calls.
 *
 * This module implements the three orthogonal addressing modes that the
 * LingoFuse C ABI supports, and gives each of them a uniform set of call
 * shapes:
 *
 *   AppTarget       -- address a logical App by its name.
 *   UIDTarget       -- address a specific session by its 32-byte UID.
 *   P2PNameTarget   -- address a group of clients by a user-supplied name.
 *
 * ============================================================================
 * CALL SHAPES
 * ============================================================================
 * Each Target exposes three parallel styles for request/response:
 *
 *   1. Promise (default; recommended for new code):
 *
 *        const result = await target.call("api", payload, { timeoutMs });
 *
 *   2. Inline callback (for event-oriented code):
 *
 *        target.callAsync("api", payload, (result, error) => {
 *            // business code directly in the callback body
 *        });
 *
 *   3. Synchronous (for code that must block):
 *
 *        const result = target.callSync("api", payload, { timeoutMs });
 *
 * The three styles share the same payload serialization policy (JSON via
 * lingofuse.lf_io) and the same error envelope. They can be freely mixed.
 *
 * One-way notifications are provided by `notify` and `sequencedNotify`.
 *
 * ============================================================================
 * ADDRESSING SEMANTICS
 * ============================================================================
 *   +------------------+---------------+--------------+------------------+
 *   | Mode             | Routing key   | Local-first? | Load-balanced?   |
 *   +==================+===============+==============+==================+
 *   | AppTarget        | App name      | YES          | N/A              |
 *   | UIDTarget        | UID (32 B)    | YES          | N/A              |
 *   | P2PNameTarget    | Group name    | NO           | YES (server)     |
 *   +------------------+---------------+--------------+------------------+
 *
 * Local-first means: if the caller process itself hosts a matching
 * App / client for the addressing key, the call is serviced locally
 * without touching the network. P2PName deliberately opts out of
 * local-first routing: the server-side dispatcher owns the load-
 * balancing state, and short-cutting locally would defeat it.
 *
 * ============================================================================
 * UID LIFECYCLE
 * ============================================================================
 * A UID is a session identifier generated during TunnelLink. It is
 * regenerated on every reconnect: callers that cache a UID MUST re-probe
 * it after a link loss.
 *
 * To learn a client's own UID, use the "whoami" pattern: register a Call
 * API on the target side whose callback reads the caller's UID from its
 * INPUT handle via DataHandle.getP2PUid(), and call it from the client.
 *
 * ============================================================================
 * PAYLOAD SERIALIZATION
 * ============================================================================
 * Payloads are serialized with lingofuse.lf_io (JSON, compact, no \uXXXX
 * escapes, NUL-terminated). This is the same policy used by every other
 * LingoFuse binding.
 *
 * ============================================================================
 */

"use strict";

const { getBinding } = require("./binding");
const { DataHandle } = require("./data-handle");
const {
    LingoFuseError,
    LingoFuseTimeoutError,
} = require("./errors");
const {
    runAsyncWithPromise,
    runLegacyOp,
} = require("./async-support");
const { writeJson, readJson } = require("./lf-io");

// ============================================================================
// UID normalization helpers
// ============================================================================

/**
 * Normalize a UID value into a 32-byte Uint8Array.
 *
 * Accepts:
 *   - Uint8Array of length 32
 *   - Node Buffer of length 32
 *   - 64-character hexadecimal string (case-insensitive)
 *
 * @param {Uint8Array|Buffer|string} uid
 * @returns {Uint8Array}
 * @throws {TypeError|RangeError}
 */
function normalizeUid(uid) {
    if (uid instanceof Uint8Array) {
        if (uid.length !== 32) {
            throw new RangeError(
                `UID must be exactly 32 bytes, got ${uid.length}.`
            );
        }
        return new Uint8Array(uid);
    }
    if (typeof uid === "string") {
        const hex = uid.trim();
        if (hex.length !== 64) {
            throw new RangeError(
                `UID hex string must be exactly 64 characters, ` +
                `got ${hex.length}.`
            );
        }
        if (!/^[0-9a-fA-F]+$/.test(hex)) {
            throw new RangeError(
                `UID hex string contains non-hex characters.`
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
        `got ${uid === null ? "null" : typeof uid}.`
    );
}

/**
 * Convert a 32-byte Uint8Array into a value the Koffi binding can pass
 * to LF_UID_* functions.
 *
 * The argument-role TP2P_UID type declared in binding.js is a Koffi
 * struct wrapping a 32-byte array (matching the C header's
 * `struct { uint8_t bytes[32]; }`). Koffi requires the value passed at
 * the call site to have that same shape, so we return an object with a
 * `bytes` field.
 *
 * @param {Uint8Array} bytes
 * @returns {{ bytes: Uint8Array }}
 */
function toTp2pUid(bytes) {
    const arr = new Uint8Array(32);
    arr.set(bytes);
    return { bytes: arr };
}

// ============================================================================
// Internal result-deserialization helpers
// ============================================================================

/**
 * Build a deserializer that reads the JSON payload from an async result
 * handle. Called on the JS thread inside the native callback window, so
 * the handle is still valid.
 *
 * @returns {(rawResult: any) => *}
 */
function makeJsonDeserializer() {
    return function (rawResult) {
        if (!rawResult) return null;
        const h = DataHandle.fromRaw(rawResult, false);
        h.position = 0;
        return readJson(h);
    };
}

/**
 * Consume a synchronous Call result handle: check for a null handle or
 * a zero-size (timeout) handle, then read the JSON payload.
 *
 * The caller owns the returned handle, so we dispose it after reading.
 *
 * @param {any} rawResult
 * @param {string} apiName
 * @param {string} targetDesc
 * @param {number} timeoutMs
 * @returns {*}
 */
function consumeSyncResult(rawResult, apiName, targetDesc, timeoutMs) {
    if (!rawResult) {
        throw new LingoFuseError(
            `Call to '${apiName}' on ${targetDesc} returned a null handle.`
        );
    }
    const h = DataHandle.fromRaw(rawResult, true);
    try {
        const size = h.size;
        if (size === 0) {
            throw new LingoFuseTimeoutError(
                `Call to '${apiName}' on ${targetDesc} timed out after ` +
                `${timeoutMs}ms.`,
                { targetApi: apiName, timeoutMs }
            );
        }
        h.position = 0;
        return readJson(h);
    } finally {
        h.dispose();
    }
}

// ============================================================================
// Target base class
// ============================================================================

/**
 * Abstract base class for the three addressing modes.
 *
 * Concrete subclasses implement the private _rawIssue* hooks, one per
 * underlying C ABI function family. The public API is defined once here.
 */
class Target {
    constructor(opts = {}) {
        this._funcs = getBinding().funcs;
        this._defaultTimeoutMs = opts.timeoutMs ?? 5000;
    }

    // ------------------------------------------------------------------
    // Private hooks (subclasses override)
    // ------------------------------------------------------------------

    _rawIssueSyncCall(/* apiName, param, timeoutMs */) {
        throw new Error("Target._rawIssueSyncCall is abstract.");
    }
    _rawIssueAsyncCall(/* apiName, param, cCallback */) {
        throw new Error("Target._rawIssueAsyncCall is abstract.");
    }
    _rawIssueAsyncSequencedCall(/* apiName, param, cCallback */) {
        throw new Error("Target._rawIssueAsyncSequencedCall is abstract.");
    }
    _rawIssueNotify(/* apiName, param */) {
        throw new Error("Target._rawIssueNotify is abstract.");
    }
    _rawIssueSequencedNotify(/* apiName, param */) {
        throw new Error("Target._rawIssueSequencedNotify is abstract.");
    }

    _describe() {
        return "target";
    }

    /**
     * Stable string key for use as a Map / Set key.
     *
     * JavaScript's Map and Set compare keys by reference, not by value.
     * A caller who wants value-based lookup must use this method as the
     * map key:
     *
     *     const m = new Map();
     *     m.set(new AppTarget("X").hashKey(), 1);
     *     m.get(new AppTarget("X").hashKey());   // => 1
     *
     * Subclasses return a key that is unique to their addressing mode
     * (an `app:` / `uid:` / `p2p:` prefix), so two different modes with
     * the same string payload never produce the same key.
     */
    hashKey() {
        throw new Error("Target.hashKey is abstract.");
    }

    // ==================================================================
    // Public API: Call (Promise style, default)
    // ==================================================================

    /**
     * Send a non-blocking request. Returns a CallPromise that resolves
     * with the deserialized result.
     *
     * The CallPromise is a thenable, so `await target.call(...)` works.
     *
     * @param {string} apiName
     * @param {*} payload
     * @param {{ timeoutMs?: number }} [options]
     * @returns {import("./async-support").CallPromise}
     */
    call(apiName, payload = null, options = {}) {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            return runAsyncWithPromise(
                (cb) => this._rawIssueAsyncCall(apiName, param, cb),
                makeJsonDeserializer(),
                timeoutMs
            );
        } finally {
            // The native side has already copied the payload by the time
            // runAsyncWithPromise returns. Safe to dispose.
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
     * @param {string} apiName
     * @param {*} payload
     * @param {(result: *, error: Error|null, userData: *) => void} onResult
     * @param {*} [userData]
     * @returns {number} 1 if the request was queued, 0 otherwise.
     */
    callAsync(apiName, payload, onResult, userData = undefined) {
        if (typeof onResult !== "function") {
            throw new TypeError(
                "Target.callAsync: onResult must be a function."
            );
        }
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            return runLegacyOp(
                (cb) => this._rawIssueAsyncCall(apiName, param, cb),
                onResult,
                userData,
                makeJsonDeserializer()
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
     * @param {string} apiName
     * @param {*} payload
     * @param {{ timeoutMs?: number }} [options]
     * @returns {*}
     * @throws {LingoFuseError|LingoFuseTimeoutError}
     */
    callSync(apiName, payload = null, options = {}) {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            const rawResult = this._rawIssueSyncCall(
                apiName,
                param,
                timeoutMs
            );
            return consumeSyncResult(
                rawResult,
                apiName,
                this._describe(),
                timeoutMs
            );
        } finally {
            param.dispose();
        }
    }

    /**
     * Non-throwing counterpart of callSync. Returns null on timeout,
     * null-handle failure, or any deserialization error.
     *
     * @param {string} apiName
     * @param {*} payload
     * @param {{ timeoutMs?: number }} [options]
     * @returns {*|null}
     */
    tryCallSync(apiName, payload = null, options = {}) {
        try {
            return this.callSync(apiName, payload, options);
        } catch (_err) {
            return null;
        }
    }

    // ==================================================================
    // Public API: Sequenced Call (FIFO per target key + API)
    // ==================================================================

    /**
     * Send a non-blocking, FIFO-ordered request. Returns a CallPromise.
     */
    sequencedCall(apiName, payload = null, options = {}) {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            return runAsyncWithPromise(
                (cb) => this._rawIssueAsyncSequencedCall(apiName, param, cb),
                makeJsonDeserializer(),
                timeoutMs
            );
        } finally {
            param.dispose();
        }
    }

    /**
     * Send a non-blocking, FIFO-ordered request with an inline callback.
     */
    sequencedCallAsync(apiName, payload, onResult, userData = undefined) {
        if (typeof onResult !== "function") {
            throw new TypeError(
                "Target.sequencedCallAsync: onResult must be a function."
            );
        }
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            return runLegacyOp(
                (cb) => this._rawIssueAsyncSequencedCall(apiName, param, cb),
                onResult,
                userData,
                makeJsonDeserializer()
            );
        } finally {
            param.dispose();
        }
    }

    // ==================================================================
    // Public API: Notify (one-way)
    // ==================================================================

    /** Send a one-way notification. Returns immediately. */
    notify(apiName, payload = null) {
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            this._rawIssueNotify(apiName, param);
        } finally {
            param.dispose();
        }
    }

    /** Send a one-way, FIFO-ordered notification. Returns immediately. */
    sequencedNotify(apiName, payload = null) {
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            this._rawIssueSequencedNotify(apiName, param);
        } finally {
            param.dispose();
        }
    }
}

// ============================================================================
// AppTarget
// ============================================================================

class AppTarget extends Target {
    constructor(appName, opts = {}) {
        super(opts);
        if (typeof appName !== "string") {
            throw new TypeError("AppTarget: appName must be a string.");
        }
        this._appName = appName;
    }

    get appName() {
        return this._appName;
    }

    /**
     * Value-based string key. See Target.hashKey for the rationale.
     */
    hashKey() {
        return `app:${this._appName}`;
    }

    _describe() {
        return `app(${JSON.stringify(this._appName)})`;
    }

    _rawIssueSyncCall(apiName, param, timeoutMs) {
        return this._funcs.LF_Call(this._appName, param.raw, timeoutMs);
    }
    _rawIssueAsyncCall(apiName, param, cb) {
        return this._funcs.LF_Async_Call(
            this._appName,
            param.raw,
            null,
            cb
        );
    }
    _rawIssueAsyncSequencedCall(apiName, param, cb) {
        return this._funcs.LF_Async_Sequenced_Call(
            this._appName,
            param.raw,
            null,
            cb
        );
    }
    _rawIssueNotify(apiName, param) {
        this._funcs.LF_Notify(this._appName, param.raw);
    }
    _rawIssueSequencedNotify(apiName, param) {
        this._funcs.LF_Sequenced_Notify(this._appName, param.raw);
    }
}

// ============================================================================
// UIDTarget
// ============================================================================

class UIDTarget extends Target {
    constructor(uid, opts = {}) {
        super(opts);
        this._uidBytes = normalizeUid(uid);
        this._uidArray = toTp2pUid(this._uidBytes);
    }

    get uidBytes() {
        return new Uint8Array(this._uidBytes);
    }

    get uidHex() {
        let out = "";
        for (const b of this._uidBytes) {
            out += b.toString(16).padStart(2, "0");
        }
        return out;
    }

    /**
     * Value-based string key. See Target.hashKey for the rationale.
     */
    hashKey() {
        return `uid:${this.uidHex}`;
    }

    _describe() {
        return `uid(${this.uidHex})`;
    }

    _rawIssueSyncCall(apiName, param, timeoutMs) {
        return this._funcs.LF_UID_Call(
            this._uidArray,
            param.raw,
            timeoutMs
        );
    }
    _rawIssueAsyncCall(apiName, param, cb) {
        return this._funcs.LF_UID_Async_Call(
            this._uidArray,
            param.raw,
            null,
            cb
        );
    }
    _rawIssueAsyncSequencedCall(apiName, param, cb) {
        return this._funcs.LF_UID_Async_Sequenced_Call(
            this._uidArray,
            param.raw,
            null,
            cb
        );
    }
    _rawIssueNotify(apiName, param) {
        this._funcs.LF_UID_Notify(this._uidArray, param.raw);
    }
    _rawIssueSequencedNotify(apiName, param) {
        this._funcs.LF_UID_Sequenced_Notify(this._uidArray, param.raw);
    }
}

// ============================================================================
// P2PNameTarget
// ============================================================================

class P2PNameTarget extends Target {
    constructor(groupName, opts = {}) {
        super(opts);
        if (typeof groupName !== "string") {
            throw new TypeError(
                "P2PNameTarget: groupName must be a string."
            );
        }
        this._groupName = groupName;
    }

    get groupName() {
        return this._groupName;
    }

    /**
     * Value-based string key. See Target.hashKey for the rationale.
     */
    hashKey() {
        return `p2p:${this._groupName}`;
    }

    _describe() {
        return `p2pname(${JSON.stringify(this._groupName)})`;
    }

    _rawIssueSyncCall(apiName, param, timeoutMs) {
        return this._funcs.LF_P2PNAME_Call(
            this._groupName,
            param.raw,
            timeoutMs
        );
    }
    _rawIssueAsyncCall(apiName, param, cb) {
        return this._funcs.LF_P2PNAME_Async_Call(
            this._groupName,
            param.raw,
            null,
            cb
        );
    }
    _rawIssueAsyncSequencedCall(apiName, param, cb) {
        return this._funcs.LF_P2PNAME_Async_Sequenced_Call(
            this._groupName,
            param.raw,
            null,
            cb
        );
    }
    _rawIssueNotify(apiName, param) {
        this._funcs.LF_P2PNAME_Notify(this._groupName, param.raw);
    }
    _rawIssueSequencedNotify(apiName, param) {
        this._funcs.LF_P2PNAME_Sequenced_Notify(
            this._groupName,
            param.raw
        );
    }
}

// ============================================================================
// Public exports
// ============================================================================

module.exports = {
    Target,
    AppTarget,
    UIDTarget,
    P2PNameTarget,
    // Internal helper re-exported for status.js and P2P registration helpers
    _normalizeUid: normalizeUid,
    _toTp2pUid: toTp2pUid,
};