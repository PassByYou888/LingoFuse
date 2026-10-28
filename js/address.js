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

function normalizeUid(uid) {
    if (uid instanceof Uint8Array) {
        if (uid.length !== 32) {
            throw new RangeError(
                "UID must be exactly 32 bytes, got " + uid.length + "."
            );
        }
        return new Uint8Array(uid);
    }
    if (typeof uid === "string") {
        const hex = uid.trim();
        if (hex.length !== 64) {
            throw new RangeError(
                "UID hex string must be exactly 64 characters, got " +
                hex.length + "."
            );
        }
        if (!/^[0-9a-fA-F]+$/.test(hex)) {
            throw new RangeError(
                "UID hex string contains non-hex characters."
            );
        }
        const out = new Uint8Array(32);
        for (let i = 0; i < 32; i++) {
            out[i] = parseInt(hex.substr(i * 2, 2), 16);
        }
        return out;
    }
    throw new TypeError(
        "UID must be a Uint8Array(32) or a 64-character hex string, got " +
        (uid === null ? "null" : typeof uid) + "."
    );
}

function toTp2pUid(bytes) {
    const arr = new Uint8Array(32);
    arr.set(bytes);
    return { bytes: arr };
}

function readJsonTolerant(h) {
    if (!h || h.size === 0) {
        return null;
    }
    h.position = 0;
    const firstByte = h.readUInt8();
    if (firstByte === 0x00) {
        return readJson(h);
    }
    if (firstByte === 0xFF) {
        let message = "";
        try { message = h.readString(); } catch (_) {}
        throw new LingoFuseError(
            "remote error: " + (message || "<empty>")
        );
    }
    h.position = 0;
    return readJson(h);
}

function makeJsonDeserializer() {
    return function (rawResult) {
        if (!rawResult) {
            return null;
        }
        const h = DataHandle.fromRaw(rawResult, false);
        return readJsonTolerant(h);
    };
}

function consumeSyncResult(rawResult, apiName, targetDesc, timeoutMs) {
    if (!rawResult) {
        throw new LingoFuseError(
            "Call to '" + apiName + "' on " + targetDesc +
            " returned a null handle."
        );
    }
    const h = DataHandle.fromRaw(rawResult, true);
    try {
        const size = h.size;
        if (size === 0) {
            throw new LingoFuseTimeoutError(
                "Call to '" + apiName + "' on " + targetDesc +
                " timed out after " + timeoutMs + "ms.",
                { targetApi: apiName, timeoutMs }
            );
        }
        return readJsonTolerant(h);
    } finally {
        h.dispose();
    }
}

class Target {
    constructor(opts = {}) {
        this._funcs = getBinding().funcs;
        this._defaultTimeoutMs = opts.timeoutMs ?? 5000;
    }

    _rawIssueSyncCall() {
        throw new Error("Target._rawIssueSyncCall is abstract.");
    }
    _rawIssueAsyncCall() {
        throw new Error("Target._rawIssueAsyncCall is abstract.");
    }
    _rawIssueAsyncSequencedCall() {
        throw new Error("Target._rawIssueAsyncSequencedCall is abstract.");
    }
    _rawIssueNotify() {
        throw new Error("Target._rawIssueNotify is abstract.");
    }
    _rawIssueSequencedNotify() {
        throw new Error("Target._rawIssueSequencedNotify is abstract.");
    }

    _describe() {
        return "target";
    }

    hashKey() {
        throw new Error("Target.hashKey is abstract.");
    }

    call(apiName, payload = null, options = {}) {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        let promise;
        try {
            writeJson(param, payload);
            promise = runAsyncWithPromise(
                (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
                makeJsonDeserializer(),
                timeoutMs
            );
        } catch (err) {
            try { param.dispose(); } catch (_) {}
            throw err;
        }
        promise.then(
            () => { try { param.dispose(); } catch (_) {} },
            () => { try { param.dispose(); } catch (_) {} }
        );
        return promise;
    }

    callAsync(apiName, payload, onResult, userData = undefined) {
        if (typeof onResult !== "function") {
            throw new TypeError(
                "Target.callAsync: onResult must be a function."
            );
        }
        const param = new DataHandle(apiName);
        let ret;
        try {
            writeJson(param, payload);
            ret = runLegacyOp(
                (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
                (result, error, ud) => {
                    try { param.dispose(); } catch (_) {}
                    onResult(result, error, ud);
                },
                userData,
                makeJsonDeserializer()
            );
        } catch (err) {
            try { param.dispose(); } catch (_) {}
            throw err;
        }
        return ret;
    }

    callSync(apiName, payload = null, options = {}) {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            const rawResult = this._rawIssueSyncCall(apiName, param, timeoutMs);
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

    tryCallSync(apiName, payload = null, options = {}) {
        try {
            return this.callSync(apiName, payload, options);
        } catch (_err) {
            return null;
        }
    }

    sequencedCall(apiName, payload = null, options = {}) {
        const timeoutMs = options.timeoutMs ?? this._defaultTimeoutMs;
        const param = new DataHandle(apiName);
        let promise;
        try {
            writeJson(param, payload);
            promise = runAsyncWithPromise(
                (cb, op) => this._rawIssueAsyncSequencedCall(apiName, param, cb, op),
                makeJsonDeserializer(),
                timeoutMs
            );
        } catch (err) {
            try { param.dispose(); } catch (_) {}
            throw err;
        }
        promise.then(
            () => { try { param.dispose(); } catch (_) {} },
            () => { try { param.dispose(); } catch (_) {} }
        );
        return promise;
    }

    sequencedCallAsync(apiName, payload, onResult, userData = undefined) {
        if (typeof onResult !== "function") {
            throw new TypeError(
                "Target.sequencedCallAsync: onResult must be a function."
            );
        }
        const param = new DataHandle(apiName);
        let ret;
        try {
            writeJson(param, payload);
            ret = runLegacyOp(
                (cb, op) => this._rawIssueAsyncSequencedCall(apiName, param, cb, op),
                (result, error, ud) => {
                    try { param.dispose(); } catch (_) {}
                    onResult(result, error, ud);
                },
                userData,
                makeJsonDeserializer()
            );
        } catch (err) {
            try { param.dispose(); } catch (_) {}
            throw err;
        }
        return ret;
    }

    notify(apiName, payload = null) {
        const param = new DataHandle(apiName);
        try {
            writeJson(param, payload);
            this._rawIssueNotify(apiName, param);
        } finally {
            param.dispose();
        }
    }

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

    hashKey() {
        return "app:" + this._appName;
    }

    _describe() {
        return "app(" + JSON.stringify(this._appName) + ")";
    }

    _rawIssueSyncCall(apiName, param, timeoutMs) {
        return this._funcs.LF_Call(this._appName, param.raw, timeoutMs);
    }

    _rawIssueAsyncCall(apiName, param, cb, op) {
        return this._funcs.LF_Async_Call(
            this._appName,
            param.raw,
            op.dataPtr,
            cb
        );
    }

    _rawIssueAsyncSequencedCall(apiName, param, cb, op) {
        return this._funcs.LF_Async_Sequenced_Call(
            this._appName,
            param.raw,
            op.dataPtr,
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

    hashKey() {
        return "uid:" + this.uidHex;
    }

    _describe() {
        return "uid(" + this.uidHex + ")";
    }

    _rawIssueSyncCall(apiName, param, timeoutMs) {
        return this._funcs.LF_UID_Call(
            this._uidArray,
            param.raw,
            timeoutMs
        );
    }

    _rawIssueAsyncCall(apiName, param, cb, op) {
        return this._funcs.LF_UID_Async_Call(
            this._uidArray,
            param.raw,
            op.dataPtr,
            cb
        );
    }

    _rawIssueAsyncSequencedCall(apiName, param, cb, op) {
        return this._funcs.LF_UID_Async_Sequenced_Call(
            this._uidArray,
            param.raw,
            op.dataPtr,
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

    hashKey() {
        return "p2p:" + this._groupName;
    }

    _describe() {
        return "p2pname(" + JSON.stringify(this._groupName) + ")";
    }

    _rawIssueSyncCall(apiName, param, timeoutMs) {
        return this._funcs.LF_P2PNAME_Call(
            this._groupName,
            param.raw,
            timeoutMs
        );
    }

    _rawIssueAsyncCall(apiName, param, cb, op) {
        return this._funcs.LF_P2PNAME_Async_Call(
            this._groupName,
            param.raw,
            op.dataPtr,
            cb
        );
    }

    _rawIssueAsyncSequencedCall(apiName, param, cb, op) {
        return this._funcs.LF_P2PNAME_Async_Sequenced_Call(
            this._groupName,
            param.raw,
            op.dataPtr,
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

module.exports = {
    Target,
    AppTarget,
    UIDTarget,
    P2PNameTarget,
    _normalizeUid: normalizeUid,
    _toTp2pUid: toTp2pUid,
};