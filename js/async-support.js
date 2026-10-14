/**
 * @file async-support.js
 * @brief Safe lifetime management and modern async bridging for
 *        LingoFuse's asynchronous call primitives.
 *
 * This module is the JavaScript counterpart of lingofuse.async_support
 * (Python) and AsyncSupport.cs (C#). It sits between the ctypes-level
 * async callback mechanism (LF_Async_Call and its UID_* / P2PName_*
 * variants) and modern JavaScript async programming.
 *
 * ============================================================================
 * WHY THIS SUBSYSTEM EXISTS
 * ============================================================================
 * The native library holds a RAW FUNCTION POINTER to the callback you
 * register. It does NOT hold a JavaScript reference to the Koffi
 * callback object. Three distinct hazards arise from this:
 *
 *   1. PREMATURE RELEASE ON TIMEOUT
 *      A timed-out request is NOT cancelled by the native library. The
 *      framework will still invoke the callback when (or if) the
 *      response eventually arrives. If we drop the Koffi callback
 *      object when our JS-side timeout fires, the native side is left
 *      holding a dangling pointer, and the next invocation crashes.
 *
 *   2. LEAK ON DISPATCH FAILURE
 *      If the native library rejects the request before dispatching it
 *      (returns a value other than 1), the callback will NEVER fire. A
 *      naive "wait for the callback to release the object" policy leaks
 *      the Koffi callback forever.
 *
 *   3. DOUBLE-RELEASE RACES
 *      The JS thread (on timeout) and the native worker thread (on
 *      callback) can race to release the same object. Without a state
 *      machine, this leads to a use-after-free.
 *
 * AsyncBridge addresses all three hazards through an explicit op state
 * machine (PENDING -> FIRED | ABANDONED | NOT_QUEUED).
 *
 * ============================================================================
 * ARCHITECTURE
 * ============================================================================
 *   CallPromise  -- a Promise wrapper with an `abandoned` flag.
 *   AsyncOp      -- per-operation state holder. Owns the Koffi callback.
 *   AsyncBridge  -- process-wide singleton. Holds every live op; runs
 *                   a periodic reclamation loop via setInterval.
 *
 *   makeFutureOp        -- build an op + CallPromise pair.
 *   makeLegacyOp        -- build an op for the callback style.
 *   runAsyncWithPromise -- one-stop helper: build op+promise, issue the
 *                          native request, arm the timeout, return the
 *                          CallPromise.
 *   runLegacyOp         -- one-stop helper for the callback style.
 *
 * ============================================================================
 * KOFFI CALLBACK LIFETIME
 * ============================================================================
 * Every koffi.register(fn, proto) call creates a native N-API thread-
 * safe function backed by a libuv handle. By default that handle is
 * ref'ed, so it keeps the Node event loop alive and prevents the
 * process from exiting.
 *
 * The ONLY way to release the handle is koffi.unregister(ptr). This
 * module therefore releases every op's callback as soon as the op's
 * state machine permits:
 *
 *   - FIRED      : the callback already returned; release immediately.
 *   - NOT_QUEUED : dispatch never happened; release immediately.
 *   - ABANDONED  : JS-side timeout fired. Release after a grace
 *                  period, so a late native callback that is still in
 *                  flight reaches a valid (no-op) trampoline rather
 *                  than freed memory.
 *
 * On shutdown(), every still-tracked op has its callback released
 * unconditionally. Without that, a caller who never awaits an async
 * call would keep the process alive.
 *
 * ============================================================================
 * THREADING MODEL
 * ============================================================================
 * JavaScript is single-threaded per event loop. Koffi callbacks are
 * serialised onto the JS thread by the Koffi runtime, so no locking is
 * needed. The reclamation loop is a setInterval timer that runs on the
 * same event loop.
 *
 * ============================================================================
 * CONFIGURATION
 * ============================================================================
 * Two environment variables are read ONCE at module load:
 *
 *   LINGOFUSE_ASYNC_RECLAIM_GRACE  -- seconds to keep an abandoned op
 *                                     alive after its timeout fires,
 *                                     giving any in-flight native
 *                                     callback a chance to arrive on a
 *                                     still-valid JS object.
 *                                     Default: 60. Must be >= 0.
 *
 *   LINGOFUSE_ASYNC_RECLAIM_PERIOD -- seconds between reclamation sweeps.
 *                                     Default: 1.0. Must be > 0.05.
 *
 * All comments and status output are in English.
 */

"use strict";

const koffi = require("koffi");
const { getBinding, LfAsyncCallOnResult } = require("./binding");
const { LingoFuseError, LingoFuseTimeoutError } = require("./errors");

// ============================================================================
// Configuration
// ============================================================================

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

/**
 * Delay between abandoning an op and releasing its Koffi callback, in
 * milliseconds. This gives any straggling native callback that was
 * already in flight when the JS-side timeout fired a chance to reach a
 * still-valid trampoline. The trampoline itself is a no-op because the
 * op state is ABANDONED.
 */
const _ABANDONED_RELEASE_DELAY_MS = 5000;

// ============================================================================
// CallPromise
// ============================================================================

/**
 * A Promise wrapper with an `abandoned` flag.
 *
 * The `abandoned` flag distinguishes two ways the promise can end up
 * without a result:
 *
 *   - The caller explicitly cancelled it (not supported by this
 *     wrapper; future extension).
 *   - The JS-side timeout expired before the native callback arrived.
 *     `abandoned` becomes true.
 *
 * The native request is NOT cancelled when the timeout fires. The
 * framework keeps the callback alive for a grace period, and any late
 * result is silently discarded.
 *
 * CallPromise is a thenable: `await callPromise` works.
 */
class CallPromise {
    constructor() {
        /** @type {Promise<*>} */
        this._promise = new Promise((resolve, reject) => {
            this._resolve = resolve;
            this._reject = reject;
        });
        this._abandoned = false;
        this._settled = false;
    }

    /** True if the timeout fired before the result arrived. */
    get abandoned() {
        return this._abandoned;
    }

    /** True once the underlying promise has been resolved or rejected. */
    get settled() {
        return this._settled;
    }

    // -- Thenable interface (enables `await callPromise`) --
    then(onFulfilled, onRejected) {
        return this._promise.then(onFulfilled, onRejected);
    }
    catch(onRejected) {
        return this._promise.catch(onRejected);
    }
    finally(onFinally) {
        return this._promise.finally(onFinally);
    }

    // -- Internal transitions (not part of the public API) --
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

// ============================================================================
// AsyncOp
// ============================================================================

const STATE_PENDING = "pending";
const STATE_FIRED = "fired";
const STATE_ABANDONED = "abandoned";
const STATE_NOT_QUEUED = "not_queued";

/**
 * A single outstanding asynchronous operation.
 *
 * Owns the Koffi callback object and, optionally, the CallPromise that
 * receives the result.
 *
 * State machine:
 *
 *   PENDING  --(callback fires)-->   FIRED
 *   PENDING  --(timeout fires)-->    ABANDONED --(callback fires)--> FIRED
 *   PENDING  --(dispatch fails)-->   NOT_QUEUED
 */
class AsyncOp {
    constructor(deliver, cCallback, promise) {
        this._deliver = deliver;
        this._cCallback = cCallback;
        this._promise = promise;
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

    /**
     * Transition to NOT_QUEUED and schedule immediate release.
     * Called when the native dispatch returns a value other than 1.
     * Idempotent.
     */
    markNotQueued() {
        if (this._state !== STATE_PENDING) return;
        this._state = STATE_NOT_QUEUED;
        AsyncBridge.instance()._scheduleReleaseNow(this);
    }

    /**
     * Called by the Koffi callback wrapper on the JS thread.
     * Transitions to FIRED (or, if already ABANDONED, still transitions
     * to FIRED but drops the result), then invokes the deliver function
     * exactly once.
     */
    _invokeFromNative(result, error) {
        const current = this._state;
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
            // A failure here means the caller's callback or our
            // internal promise-resolution helper raised. We must never
            // let that escape into the native stack.
            // eslint-disable-next-line no-console
            console.error("[LingoFuse] AsyncOp delivery callback raised:", err);
        } finally {
            AsyncBridge.instance()._scheduleReleaseNow(this);
        }
    }

    /** Transition to ABANDONED. Returns true if the transition happened. */
    _abandon() {
        if (this._state !== STATE_PENDING) return false;
        this._state = STATE_ABANDONED;
        return true;
    }
}

// ============================================================================
// AsyncBridge
// ============================================================================

/**
 * Process-wide manager for every outstanding AsyncOp.
 *
 * The bridge is a singleton. It holds the only strong reference to each
 * op's Koffi callback object for as long as the native library might
 * invoke it, and releases that reference once the op's state machine
 * permits.
 */
class AsyncBridge {
    constructor() {
        this._handles = new Map();
        this._counter = 0;
        this._releaseCount = 0;
        this._timeoutQueue = [];   // [{ deadline: number, op: AsyncOp }]
        this._releaseQueue = [];   // [{ deadline: number, op: AsyncOp }]
        this._shutdown = false;

        // Exposed as attributes so tests can override them per-instance.
        this.graceSeconds = _DEFAULT_GRACE_SECONDS;
        this.periodSeconds = _DEFAULT_PERIOD_SECONDS;

        this._timer = setInterval(
            () => this._reclaim(),
            Math.max(10, this.periodSeconds * 1000)
        );
        // Do not block process exit on this timer.
        if (this._timer && typeof this._timer.unref === "function") {
            this._timer.unref();
        }
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

    /**
     * Register an op with the bridge. Must be called BEFORE the op's
     * Koffi callback is handed to the native library.
     */
    register(op) {
        this._counter += 1;
        op._key = this._counter;
        this._handles.set(op._key, op);
    }

    /**
     * Arm a JS-side timeout on the given op. When the timeout fires, the
     * op is transitioned to ABANDONED, the CallPromise is resolved with
     * LingoFuseTimeoutError, and the op is held alive for graceSeconds.
     */
    scheduleTimeout(op, timeoutMs) {
        if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return;
        const deadline = Date.now() + timeoutMs;
        this._timeoutQueue.push({ deadline, op });
    }

    _scheduleReleaseNow(op) {
        this._releaseQueue.push({ deadline: Date.now(), op });
    }

    _scheduleReleaseAfterGrace(op) {
        const deadline = Date.now() + this.graceSeconds * 1000;
        this._releaseQueue.push({ deadline, op });
    }

    _reclaim() {
        if (this._shutdown) return;
        const now = Date.now();

        // Timeouts
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

        // Releases
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

        const wasAbandoned = (op._state === STATE_ABANDONED);

        this._handles.delete(op._key);
        this._releaseCount += 1;

        // Release the Koffi callback object. Every koffi.register call
        // creates a native N-API thread-safe function backed by a
        // libuv handle that is, by default, ref'ed. Without an
        // explicit koffi.unregister, each async call leaks one such
        // handle, and the Node event loop never becomes idle — the
        // process refuses to exit.
        //
        // Safety by state:
        //   FIRED      -- the callback already returned; releasing now
        //                 is safe.
        //   NOT_QUEUED -- the native dispatch never accepted the
        //                 request; no callback was ever installed.
        //   ABANDONED  -- the JS-side timeout fired and grace has
        //                 elapsed. A straggling native call is very
        //                 unlikely this late, but we still delay the
        //                 release by an extra window to be safe.
        const callback = op.cCallback;
        if (wasAbandoned) {
            setTimeout(() => {
                try {
                    koffi.unregister(callback);
                } catch (_e) {
                    // Best-effort: a failed unregister must never
                    // abort the release path.
                }
            }, _ABANDONED_RELEASE_DELAY_MS).unref();
        } else {
            try {
                koffi.unregister(callback);
            } catch (_e) {
                // Best-effort.
            }
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
        if (this._timer) {
            clearInterval(this._timer);
            this._timer = null;
        }

        // Release every outstanding Koffi callback. Without this,
        // each still-pending op leaves behind a native thread-safe
        // function handle that keeps the Node event loop alive and
        // prevents a clean process exit.
        for (const op of this._handles.values()) {
            try {
                koffi.unregister(op.cCallback);
            } catch (_e) {
                // Best-effort.
            }
        }

        this._handles.clear();
        this._timeoutQueue = [];
        this._releaseQueue = [];
    }
}

AsyncBridge._instance = null;

// ============================================================================
// Factory helpers
// ============================================================================

function _createAsyncOp(deliver, deserialize, promise) {
    const cell = { op: null };

    const cCallback = koffi.register(
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

    const op = new AsyncOp(deliver, cCallback, promise);
    cell.op = op;
    AsyncBridge.instance().register(op);
    return op;
}

/**
 * Build an AsyncOp for the traditional "user provides a callback" style.
 *
 * The user callback is invoked as onResult(result, error, userData) on
 * the JS thread (delivered from the native worker thread by the Koffi
 * bridge). It MUST NOT block.
 */
function makeLegacyOp(onResult, userData, deserialize) {
    function deliver(result, error) {
        try {
            onResult(result, error, userData);
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error(
                "[LingoFuse] User async on_result callback raised:",
                err
            );
        }
    }
    return _createAsyncOp(deliver, deserialize, null);
}

/**
 * Build an AsyncOp + CallPromise pair.
 *
 * No timeout is armed here; call AsyncBridge.instance().scheduleTimeout()
 * after successful dispatch. The runAsyncWithPromise helper does this.
 */
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

/**
 * One-stop helper: build op+promise, issue the native request, arm the
 * timeout on success, and return the CallPromise.
 *
 * @param {(cb: any) => number} issueFn
 *   A callable that takes the Koffi callback object and issues the
 *   native request. Returns 1 on successful dispatch, anything else on
 *   failure.
 * @param {(rawResult: any) => *} deserialize
 *   Converts the raw result handle into a JavaScript value. Called on
 *   the JS thread, inside the native callback window.
 * @param {number} [timeoutMs]
 *   Optional JS-side timeout in milliseconds.
 * @returns {CallPromise}
 */
function runAsyncWithPromise(issueFn, deserialize, timeoutMs) {
    const { op, promise } = makeFutureOp(deserialize);

    let ret;
    try {
        ret = issueFn(op.cCallback);
    } catch (err) {
        op.markNotQueued();
        throw err;
    }

    if (ret !== 1) {
        op.markNotQueued();
        if (!promise.settled) {
            promise._settleReject(
                new LingoFuseError(
                    `async request was not queued ` +
                    `(dispatch returned ${ret})`
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

/**
 * One-stop helper for the callback style. Issues the native request,
 * delivers the result to onResult, and returns the dispatch code.
 *
 * @returns {number}  The dispatch return code (1 = queued).
 */
function runLegacyOp(issueFn, onResult, userData, deserialize) {
    const op = makeLegacyOp(onResult, userData, deserialize);

    let ret;
    try {
        ret = issueFn(op.cCallback);
    } catch (err) {
        op.markNotQueued();
        throw err;
    }

    if (ret !== 1) {
        op.markNotQueued();
        // Deliver dispatch failure to the callback so the caller is not
        // left waiting forever.
        try {
            onResult(
                null,
                new LingoFuseError(
                    `async request was not queued ` +
                    `(dispatch returned ${ret})`
                ),
                userData
            );
        } catch (_err) {
            // swallow
        }
    }
    return ret;
}

// ============================================================================
// Public exports
// ============================================================================

module.exports = {
    AsyncBridge,
    AsyncOp,
    CallPromise,
    makeFutureOp,
    makeLegacyOp,
    runAsyncWithPromise,
    runLegacyOp,
};