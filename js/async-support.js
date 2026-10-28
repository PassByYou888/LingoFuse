"use strict";

const koffi = require("koffi");
const { getBinding, LfAsyncCallOnResult } = require("./binding");
const { LingoFuseError, LingoFuseTimeoutError } = require("./errors");

function _envFloat(name, def, minimum) {
    const raw = process.env[name];
    if (raw === undefined) return def;
    const v = Number.parseFloat(raw);
    if (!Number.isFinite(v)) return def;
    if (minimum !== undefined && v < minimum) return minimum;
    return v;
}

const _DEFAULT_GRACE_SECONDS = _envFloat(
    "LINGOFUSE_ASYNC_RECLAIM_GRACE",
    60.0,
    0.0
);

const _DEFAULT_PERIOD_SECONDS = _envFloat(
    "LINGOFUSE_ASYNC_RECLAIM_PERIOD",
    1.0,
    0.05
);

const _ABANDONED_RELEASE_DELAY_MS = 30000;

const _DEBUG = typeof process !== "undefined" && process.env.LF_DEBUG === "1";

function _dbg(...args) {
    if (!_DEBUG) return;
    try { console.log("[AsyncBridge]", ...args); } catch (_) {}
}

class CallPromise {
    constructor() {
        this._promise = new Promise((resolve, reject) => {
            this._resolve = resolve;
            this._reject = reject;
        });
        this._abandoned = false;
        this._settled = false;
    }

    get abandoned() {
        return this._abandoned;
    }

    get settled() {
        return this._settled;
    }

    then(onFulfilled, onRejected) {
        return this._promise.then(onFulfilled, onRejected);
    }

    catch(onRejected) {
        return this._promise.catch(onRejected);
    }

    finally(onFinally) {
        return this._promise.finally(onFinally);
    }

    _settleResolve(value) {
        if (this._settled) return;
        this._settled = true;
        this._resolve(value);
    }

    _settleReject(err) {
        if (this._settled) return;
        this._settled = true;
        this._reject(err);
    }

    _markAbandoned() {
        this._abandoned = true;
    }
}

const STATE_PENDING = "pending";
const STATE_FIRED = "fired";
const STATE_ABANDONED = "abandoned";
const STATE_NOT_QUEUED = "not_queued";

class AsyncOp {
    constructor(deliver, cCallback, promise, dataPtr) {
        this._deliver = deliver;
        this._cCallback = cCallback;
        this._promise = promise;
        this._dataPtr = dataPtr;
        this._state = STATE_PENDING;
        this._key = null;
        this._createdAt = Date.now();
    }

    get cCallback() {
        return this._cCallback;
    }

    get promise() {
        return this._promise;
    }

    get state() {
        return this._state;
    }

    get dataPtr() {
        return this._dataPtr;
    }

    _freeDataPtr() {
        if (this._dataPtr) {
            try { koffi.free(this._dataPtr); } catch (_) {}
            this._dataPtr = null;
        }
    }

    markNotQueued() {
        if (this._state !== STATE_PENDING) return;
        this._state = STATE_NOT_QUEUED;
        AsyncBridge.instance()._scheduleReleaseNow(this);
    }

    _invokeFromNative(result, error) {
        const current = this._state;
        _dbg("op#" + this._key + " invokeFromNative, prevState=" + current);
        if (current === STATE_FIRED) return;
        if (current === STATE_NOT_QUEUED) return;
        if (current === STATE_ABANDONED) {
            this._state = STATE_FIRED;
            AsyncBridge.instance()._scheduleReleaseNow(this);
            return;
        }
        this._state = STATE_FIRED;
        try {
            this._deliver(result, error);
        } catch (err) {
            try {
                console.error(
                    "[LingoFuse] AsyncOp delivery callback raised:",
                    err
                );
            } catch (_) {}
        } finally {
            AsyncBridge.instance()._scheduleReleaseNow(this);
        }
    }

    _abandon() {
        if (this._state !== STATE_PENDING) return false;
        this._state = STATE_ABANDONED;
        return true;
    }
}

class AsyncBridge {
    constructor() {
        this._handles = new Map();
        this._counter = 0;
        this._releaseCount = 0;
        this._timeoutQueue = [];
        this._releaseQueue = [];
        this._pendingUnregisters = new Map();
        this._shutdown = false;
        this.graceSeconds = _DEFAULT_GRACE_SECONDS;
        this.periodSeconds = _DEFAULT_PERIOD_SECONDS;

        this._timer = null;
    }

    static instance() {
        if (!AsyncBridge._instance) {
            AsyncBridge._instance = new AsyncBridge();
        }
        return AsyncBridge._instance;
    }

    static shutdownInstance() {
        if (AsyncBridge._instance) {
            AsyncBridge._instance.shutdown();
            AsyncBridge._instance = null;
        }
    }

    _ensureTimer() {
        if (this._shutdown) return;
        if (this._timer !== null) return;
        this._timer = setInterval(
            () => this._reclaim(),
            Math.max(10, this.periodSeconds * 1000)
        );
    }

    _stopTimer() {
        if (this._timer !== null) {
            clearInterval(this._timer);
            this._timer = null;
        }
    }

    _hasActiveWork() {
        return this._handles.size > 0
            || this._timeoutQueue.length > 0
            || this._releaseQueue.length > 0;
    }

    register(op) {
        this._counter += 1;
        op._key = this._counter;
        this._handles.set(op._key, op);
        this._ensureTimer();
    }

    scheduleTimeout(op, timeoutMs) {
        if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return;
        const deadline = Date.now() + timeoutMs;
        this._timeoutQueue.push({ deadline, op });
        this._ensureTimer();
    }

    _scheduleReleaseNow(op) {
        this._releaseQueue.push({ deadline: Date.now(), op });
        this._ensureTimer();
    }

    _scheduleReleaseAfterGrace(op) {
        const deadline = Date.now() + this.graceSeconds * 1000;
        this._releaseQueue.push({ deadline, op });
        this._ensureTimer();
    }

    _reclaim() {
        if (this._shutdown) return;
        const now = Date.now();

        if (this._timeoutQueue.length > 0) {
            const remaining = [];
            for (const entry of this._timeoutQueue) {
                if (entry.deadline <= now) {
                    this._handleTimeout(entry.op);
                } else {
                    remaining.push(entry);
                }
            }
            this._timeoutQueue = remaining;
        }

        if (this._releaseQueue.length > 0) {
            const remaining = [];
            for (const entry of this._releaseQueue) {
                if (entry.deadline <= now) {
                    this._releaseOp(entry.op);
                } else {
                    remaining.push(entry);
                }
            }
            this._releaseQueue = remaining;
        }

        if (!this._hasActiveWork()) {
            this._stopTimer();
        }
    }

    _handleTimeout(op) {
        if (!op._abandon()) return;
        const p = op.promise;
        if (p instanceof CallPromise) {
            p._markAbandoned();
            if (!p.settled) {
                p._settleReject(
                    new LingoFuseTimeoutError(
                        "LingoFuse async call abandoned after timeout; " +
                        "the native-side request may still be in flight, " +
                        "but its result will be discarded."
                    )
                );
            }
        }
        this._scheduleReleaseAfterGrace(op);
    }

    _releaseOp(op) {
        if (op._key === null) return;
        if (!this._handles.has(op._key)) return;

        this._handles.delete(op._key);
        this._releaseCount += 1;

        const state = op.state;
        _dbg("release op#" + op._key + " state=" + state);

        if (state === STATE_FIRED || state === STATE_NOT_QUEUED) {
            this._unregisterCallback(op.cCallback);
            op._freeDataPtr();
            return;
        }

        let timer;
        timer = setTimeout(() => {
            this._pendingUnregisters.delete(timer);
            this._unregisterCallback(op.cCallback);
            op._freeDataPtr();
        }, _ABANDONED_RELEASE_DELAY_MS);

        if (timer && typeof timer.unref === "function") {
            timer.unref();
        }

        this._pendingUnregisters.set(timer, op);
    }

    _unregisterCallback(callback) {
        try {
            koffi.unregister(callback);
        } catch (_e) {
        }
    }

    stats() {
        let pending = 0;
        let fired = 0;
        let abandoned = 0;
        let notQueued = 0;
        for (const op of this._handles.values()) {
            const s = op.state;
            if (s === STATE_PENDING) pending += 1;
            else if (s === STATE_FIRED) fired += 1;
            else if (s === STATE_ABANDONED) abandoned += 1;
            else if (s === STATE_NOT_QUEUED) notQueued += 1;
        }
        return {
            total: this._handles.size,
            pending,
            fired,
            abandoned,
            not_queued: notQueued,
            released_total: this._releaseCount,
            grace_seconds: this.graceSeconds,
            period_seconds: this.periodSeconds,
        };
    }

    shutdown() {
        if (this._shutdown) return;
        this._shutdown = true;

        this._stopTimer();

        if (this._pendingUnregisters.size > 0) {
            const pending = Array.from(this._pendingUnregisters.entries());
            this._pendingUnregisters.clear();
            for (const [timer, op] of pending) {
                try { clearTimeout(timer); } catch (_e) {}
                this._unregisterCallback(op.cCallback);
                op._freeDataPtr();
            }
        }

        for (const op of this._handles.values()) {
            this._unregisterCallback(op.cCallback);
            op._freeDataPtr();
        }

        this._handles.clear();
        this._timeoutQueue = [];
        this._releaseQueue = [];
    }
}

AsyncBridge._instance = null;

function _createAsyncOp(deliver, deserialize, promise) {
    let dataPtr;
    try {
        dataPtr = koffi.alloc("uint8", 1);
    } catch (err) {
        throw new LingoFuseError(
            "AsyncOp: failed to allocate native data pointer: " +
            (err && err.message ? err.message : String(err))
        );
    }
    if (!dataPtr) {
        throw new LingoFuseError(
            "AsyncOp: native data pointer allocation returned null."
        );
    }

    const cell = { op: null };

    let cCallback;
    try {
        cCallback = koffi.register(
            function (_rawData, rawResult) {
                const op = cell.op;
                if (!op) return;

                let result = null;
                let error = null;

                if (rawResult) {
                    try {
                        result = deserialize(rawResult);
                    } catch (err) {
                        error = err;
                    }
                }

                op._invokeFromNative(result, error);
            },
            koffi.pointer(LfAsyncCallOnResult)
        );
    } catch (err) {
        try { koffi.free(dataPtr); } catch (_) {}
        throw err;
    }

    let op;
    try {
        op = new AsyncOp(deliver, cCallback, promise, dataPtr);
        cell.op = op;
        AsyncBridge.instance().register(op);
    } catch (err) {
        try { koffi.unregister(cCallback); } catch (_) {}
        try { koffi.free(dataPtr); } catch (_) {}
        throw err;
    }

    return op;
}

function makeLegacyOp(onResult, userData, deserialize) {
    function deliver(result, error) {
        try {
            onResult(result, error, userData);
        } catch (err) {
            try {
                console.error(
                    "[LingoFuse] User async on_result callback raised:",
                    err
                );
            } catch (_) {}
        }
    }
    return _createAsyncOp(deliver, deserialize, null);
}

function makeFutureOp(deserialize) {
    const callPromise = new CallPromise();

    function deliver(result, error) {
        if (callPromise.settled) return;
        if (error) {
            callPromise._settleReject(error);
        } else {
            callPromise._settleResolve(result);
        }
    }

    const op = _createAsyncOp(deliver, deserialize, callPromise);
    return { op, promise: callPromise };
}

function runAsyncWithPromise(issueFn, deserialize, timeoutMs) {
    const { op, promise } = makeFutureOp(deserialize);

    let ret;
    try {
        ret = issueFn(op.cCallback, op);
    } catch (err) {
        op.markNotQueued();
        throw err;
    }

    if (ret !== 1) {
        op.markNotQueued();
        if (!promise.settled) {
            promise._settleReject(
                new LingoFuseError(
                    "async request was not queued (dispatch returned " + ret + ")"
                )
            );
        }
        return promise;
    }

    if (
        timeoutMs !== undefined &&
        timeoutMs !== null &&
        Number.isFinite(timeoutMs) &&
        timeoutMs > 0
    ) {
        AsyncBridge.instance().scheduleTimeout(op, timeoutMs);
    }

    return promise;
}

function runLegacyOp(issueFn, onResult, userData, deserialize) {
    const op = makeLegacyOp(onResult, userData, deserialize);

    let ret;
    try {
        ret = issueFn(op.cCallback, op);
    } catch (err) {
        op.markNotQueued();
        throw err;
    }

    if (ret !== 1) {
        op.markNotQueued();
        try {
            onResult(
                null,
                new LingoFuseError(
                    "async request was not queued (dispatch returned " + ret + ")"
                ),
                userData
            );
        } catch (_err) {
        }
    }
    return ret;
}

module.exports = {
    AsyncBridge,
    AsyncOp,
    CallPromise,
    makeFutureOp,
    makeLegacyOp,
    runAsyncWithPromise,
    runLegacyOp,
};