// =============================================================================
//  async-support.ts
// -----------------------------------------------------------------------------
//  Safe lifetime management and modern async bridging for LingoFuse's
//  asynchronous call primitives.
//
//  This module is the TypeScript counterpart of lingofuse.async_support
//  (Python) and AsyncSupport.cs (C#). It sits between the ctypes-level
//  async callback mechanism (LF_Async_Call and its UID_* / P2PNAME_*
//  variants) and modern TypeScript async programming.
//
//  WHY THIS SUBSYSTEM EXISTS
//  -------------------------
//  The native library holds a RAW FUNCTION POINTER to the callback you
//  register. It does NOT hold a JavaScript reference to the Koffi
//  callback object. Three distinct hazards arise from this:
//
//    1. PREMATURE RELEASE ON TIMEOUT
//       A timed-out request is NOT cancelled by the native library. The
//       framework will still invoke the callback when (or if) the
//       response eventually arrives. If we drop the Koffi callback
//       object when our TypeScript-side timeout fires, the native side
//       is left holding a dangling pointer, and the next invocation
//       crashes.
//
//    2. LEAK ON DISPATCH FAILURE
//       If the native library rejects the request before dispatching it
//       (returns a value other than 1), the callback will NEVER fire. A
//       naive "wait for the callback to release the object" policy leaks
//       the Koffi callback forever.
//
//    3. DOUBLE-RELEASE RACES
//       The JS thread (on timeout) and the native worker thread (on
//       callback) can race to release the same object. Without a state
//       machine, this leads to a use-after-free.
//
//  AsyncBridge addresses all three hazards through an explicit op state
//  machine (PENDING -> FIRED | ABANDONED | NOT_QUEUED).
//
//  ARCHITECTURE
//  ------------
//    CallPromise  -- a Promise wrapper with an `abandoned` flag.
//    AsyncOp      -- per-operation state holder. Owns the Koffi callback.
//    AsyncBridge  -- process-wide singleton. Holds every live op; runs
//                    a periodic reclamation loop via setInterval.
//
//    makeFutureOp        -- build an op + CallPromise pair.
//    makeLegacyOp        -- build an op for the callback style.
//    runAsyncWithPromise -- one-stop helper: build op+promise, issue the
//                           native request, arm the timeout, return the
//                           CallPromise.
//    runLegacyOp         -- one-stop helper for the callback style.
//
//  KOFFI CALLBACK LIFETIME
//  -----------------------
//  Every koffi.register(fn, proto) call creates a native N-API thread-
//  safe function backed by a libuv handle. By default that handle is
//  ref'ed, so it keeps the Node event loop alive and prevents the
//  process from exiting.
//
//  The ONLY way to release the handle is koffi.unregister(ptr). This
//  module therefore releases every op's callback as soon as the op's
//  state machine permits:
//
//    - FIRED      : the callback already returned; release immediately.
//    - NOT_QUEUED : dispatch never happened; release immediately.
//    - ABANDONED  : JS-side timeout fired. Release after a grace
//                   period, so a late native callback that is still in
//                   flight reaches a valid (no-op) trampoline rather
//                   than freed memory.
//
//  On shutdown(), every still-tracked op has its callback released
//  unconditionally, AND every pending grace-period timer is flushed
//  immediately. Without that, a caller who never awaits an async call
//  would keep the process alive, and a caller who shuts the bridge down
//  while a grace timer is armed would leave an orphan setTimeout
//  running against a torn-down Koffi registration table.
//
//  THREADING MODEL
//  ---------------
//  TypeScript (running on Node / Deno / Bun) is single-threaded per
//  event loop. Koffi callbacks are serialised onto the JS thread by the
//  Koffi runtime, so no locking is needed. The reclamation loop is a
//  setInterval timer that runs on the same event loop.
//
//  CONFIGURATION
//  -------------
//  Two environment variables are read ONCE at module load:
//
//    LINGOFUSE_ASYNC_RECLAIM_GRACE  -- seconds to keep an abandoned op
//                                      alive after its timeout fires,
//                                      giving any in-flight native
//                                      callback a chance to arrive on a
//                                      still-valid JS object.
//                                      Default: 60. Must be >= 0.
//
//    LINGOFUSE_ASYNC_RECLAIM_PERIOD -- seconds between reclamation
//                                      sweeps. Default: 1.0.
//                                      Must be > 0.05.
//
//  All code and status output are in English.
// =============================================================================

import { koffi, LfAsyncCallOnResultPtr } from "./binding";
import { LingoFuseError, LingoFuseTimeoutError } from "./errors";

// =============================================================================
//  Configuration
// =============================================================================

/**
 * Return the value of a float-typed environment variable, or `def` when
 * the variable is missing or not a finite number. When `minimum` is
 * supplied and the parsed value is below it, the minimum is returned
 * instead.
 *
 * The accessor is defensive because `process` may be absent in some
 * embeddings; it is read through `globalThis` so that Deno and Bun's
 * Node compatibility shims are picked up uniformly.
 */
function envFloat(name: string, def: number, minimum?: number): number {
    const proc = (globalThis as {
        process?: { env?: Record<string, string | undefined> };
    }).process;
    const raw = proc?.env?.[name];
    if (raw === undefined) return def;
    const v = Number.parseFloat(raw);
    if (!Number.isFinite(v)) return def;
    if (minimum !== undefined && v < minimum) return minimum;
    return v;
}

const DEFAULT_GRACE_SECONDS = envFloat(
    "LINGOFUSE_ASYNC_RECLAIM_GRACE",
    60.0,
    0.0,
);

const DEFAULT_PERIOD_SECONDS = envFloat(
    "LINGOFUSE_ASYNC_RECLAIM_PERIOD",
    1.0,
    0.05,
);

/**
 * Delay between abandoning an op and releasing its Koffi callback, in
 * milliseconds. This gives any straggling native callback that was
 * already in flight when the JS-side timeout fired a chance to reach a
 * still-valid trampoline. The trampoline itself is a no-op because the
 * op state is ABANDONED.
 *
 * The pending timer is tracked on the AsyncBridge instance (see
 * _pendingUnregisters) so that shutdown() can flush it immediately if
 * the bridge is torn down before the grace period elapses.
 */
const ABANDONED_RELEASE_DELAY_MS = 5000;

/** Portable timer handle type (Node returns an object; Deno/Bun return a number). */
type TimerHandle = ReturnType<typeof setTimeout>;
type IntervalHandle = ReturnType<typeof setInterval>;

// =============================================================================
//  CallPromise
// =============================================================================

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
export class CallPromise<T> implements PromiseLike<T> {
    private readonly _promise: Promise<T>;
    private _resolve!: (value: T | PromiseLike<T>) => void;
    private _reject!: (reason?: unknown) => void;
    private _abandoned = false;
    private _settled = false;

    public constructor() {
        this._promise = new Promise<T>((resolve, reject) => {
            this._resolve = resolve;
            this._reject = reject;
        });
    }

    /** True if the timeout fired before the result arrived. */
    public get abandoned(): boolean {
        return this._abandoned;
    }

    /** True once the underlying promise has been resolved or rejected. */
    public get settled(): boolean {
        return this._settled;
    }

    // -- Thenable interface (enables `await callPromise`) --

    public then<TResult1 = T, TResult2 = never>(
        onFulfilled?:
            | ((value: T) => TResult1 | PromiseLike<TResult1>)
            | null,
        onRejected?:
            | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
            | null,
    ): Promise<TResult1 | TResult2> {
        return this._promise.then(onFulfilled, onRejected);
    }

    public catch<TResult = never>(
        onRejected?:
            | ((reason: unknown) => TResult | PromiseLike<TResult>)
            | null,
    ): Promise<T | TResult> {
        return this._promise.catch(onRejected);
    }

    public finally(onFinally?: (() => void) | null): Promise<T> {
        return this._promise.finally(onFinally);
    }

    // -- Internal transitions (not part of the public API) --

    /** @internal */
    public _settleResolve(value: T): void {
        if (this._settled) return;
        this._settled = true;
        this._resolve(value);
    }

    /** @internal */
    public _settleReject(err: unknown): void {
        if (this._settled) return;
        this._settled = true;
        this._reject(err);
    }

    /** @internal */
    public _markAbandoned(): void {
        this._abandoned = true;
    }
}

// =============================================================================
//  AsyncOp
// =============================================================================

/** Lifecycle state of a single asynchronous operation. */
export type OpState =
    | "pending"
    | "fired"
    | "abandoned"
    | "not_queued";

const STATE_PENDING: OpState = "pending";
const STATE_FIRED: OpState = "fired";
const STATE_ABANDONED: OpState = "abandoned";
const STATE_NOT_QUEUED: OpState = "not_queued";

/**
 * The delivery callback used internally by AsyncOp. It is invoked
 * exactly once per op, on the JS event loop, inside the native
 * callback window (or, for dispatch failures, before returning).
 */
export type DeliverFn<T> = (result: T | null, error: Error | null) => void;

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
export class AsyncOp<T> {
    private readonly _deliver: DeliverFn<T>;
    private readonly _cCallback: unknown;
    private readonly _promise: CallPromise<T> | null;
    private _state: OpState = STATE_PENDING;
    private _key: number | null = null;
    private readonly _createdAt: number = Date.now();

    /** @internal */
    public constructor(
        deliver: DeliverFn<T>,
        cCallback: unknown,
        promise: CallPromise<T> | null,
    ) {
        this._deliver = deliver;
        this._cCallback = cCallback;
        this._promise = promise;
    }

    /** @internal */
    public get cCallback(): unknown {
        return this._cCallback;
    }

    /** @internal */
    public get promise(): CallPromise<T> | null {
        return this._promise;
    }

    /** @internal */
    public get state(): OpState {
        return this._state;
    }

    /** @internal */
    public get key(): number | null {
        return this._key;
    }

    /** @internal */
    public set key(v: number | null) {
        this._key = v;
    }

    /**
     * Transition to NOT_QUEUED and schedule immediate release.
     * Called when the native dispatch returns a value other than 1.
     * Idempotent.
     */
    public markNotQueued(): void {
        if (this._state !== STATE_PENDING) return;
        this._state = STATE_NOT_QUEUED;
        AsyncBridge.instance().scheduleReleaseNow(this);
    }

    /**
     * Called by the Koffi callback wrapper on the JS thread.
     * Transitions to FIRED (or, if already ABANDONED, still transitions
     * to FIRED but drops the result), then invokes the deliver function
     * exactly once.
     *
     * @internal
     */
    public invokeFromNative(result: T | null, error: Error | null): void {
        const current = this._state;
        if (current === STATE_FIRED) return;
        if (current === STATE_NOT_QUEUED) return;
        if (current === STATE_ABANDONED) {
            // The JS-side timeout already rejected the promise. The
            // late result is dropped silently. Transition to FIRED so
            // that the release path treats this as a normal, completed
            // op (release immediately, no grace timer).
            this._state = STATE_FIRED;
            AsyncBridge.instance().scheduleReleaseNow(this);
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
            console.error(
                "[LingoFuse] AsyncOp delivery callback raised:",
                err,
            );
        } finally {
            AsyncBridge.instance().scheduleReleaseNow(this);
        }
    }

    /**
     * Transition to ABANDONED. Returns true if the transition happened.
     *
     * @internal
     */
    public abandon(): boolean {
        if (this._state !== STATE_PENDING) return false;
        this._state = STATE_ABANDONED;
        return true;
    }
}

// =============================================================================
//  AsyncBridge
// =============================================================================

interface ReleaseEntry<T = unknown> {
    deadline: number;
    op: AsyncOp<T>;
}

interface TimeoutEntry<T = unknown> {
    deadline: number;
    op: AsyncOp<T>;
}

/**
 * Snapshot of AsyncBridge counters, useful for diagnostics.
 */
export interface AsyncBridgeStats {
    readonly total: number;
    readonly pending: number;
    readonly fired: number;
    readonly abandoned: number;
    readonly not_queued: number;
    readonly released_total: number;
    readonly grace_seconds: number;
    readonly period_seconds: number;
}

/**
 * Process-wide manager for every outstanding AsyncOp.
 *
 * The bridge is a singleton. It holds the only strong reference to each
 * op's Koffi callback object for as long as the native library might
 * invoke it, and releases that reference once the op's state machine
 * permits.
 */
export class AsyncBridge {
    private static _instance: AsyncBridge | null = null;

    private readonly _handles: Map<number, AsyncOp<unknown>> = new Map();
    private _counter = 0;
    private _releaseCount = 0;
    private readonly _timeoutQueue: TimeoutEntry<unknown>[] = [];
    private readonly _releaseQueue: ReleaseEntry<unknown>[] = [];

    /**
     * Grace-period timers that defer the release of an ABANDONED op's
     * Koffi callback. Keyed by the timer handle; the value is the Koffi
     * callback object.
     *
     * Tracking these on the instance lets shutdown() flush them
     * immediately, instead of leaving an orphan setTimeout running
     * against a torn-down Koffi registration table. Without this
     * tracking, calling shutdownInstance() and then creating a new
     * AsyncBridge would leave the old bridge's timers racing the new
     * bridge's unregister calls on Koffi's global registry.
     */
    private readonly _pendingUnregisters: Map<TimerHandle, unknown> =
        new Map();

    private _shutdown = false;
    private _timer: IntervalHandle | null = null;

    /** Grace period, in seconds, applied to abandoned ops. */
    public graceSeconds: number = DEFAULT_GRACE_SECONDS;

    /** Reclamation period, in seconds. */
    public periodSeconds: number = DEFAULT_PERIOD_SECONDS;

    private constructor() {
        this._timer = setInterval(
            () => this.reclaim(),
            Math.max(10, this.periodSeconds * 1000),
        );
        // Do not block process exit on this timer.
        const t = this._timer as { unref?: () => void };
        if (typeof t.unref === "function") t.unref();
    }

    /** Return the process-wide singleton, creating it on first call. */
    public static instance(): AsyncBridge {
        if (AsyncBridge._instance === null) {
            AsyncBridge._instance = new AsyncBridge();
        }
        return AsyncBridge._instance;
    }

    /**
     * Shut down the singleton and clear it, so that the next call to
     * instance() builds a fresh one.
     */
    public static shutdownInstance(): void {
        if (AsyncBridge._instance !== null) {
            AsyncBridge._instance.shutdown();
            AsyncBridge._instance = null;
        }
    }

    /**
     * Register an op with the bridge. Must be called BEFORE the op's
     * Koffi callback is handed to the native library.
     *
     * @internal
     */
    public register<T>(op: AsyncOp<T>): void {
        this._counter += 1;
        op.key = this._counter;
        this._handles.set(
            op.key,
            op as unknown as AsyncOp<unknown>,
        );
    }

    /**
     * Arm a JS-side timeout on the given op. When the timeout fires, the
     * op is transitioned to ABANDONED, the CallPromise is rejected with
     * LingoFuseTimeoutError, and the op is held alive for graceSeconds.
     *
     * @internal
     */
    public scheduleTimeout<T>(op: AsyncOp<T>, timeoutMs: number): void {
        if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return;
        const deadline = Date.now() + timeoutMs;
        this._timeoutQueue.push({
            deadline,
            op: op as unknown as AsyncOp<unknown>,
        });
    }

    /** @internal */
    public scheduleReleaseNow<T>(op: AsyncOp<T>): void {
        this._releaseQueue.push({
            deadline: Date.now(),
            op: op as unknown as AsyncOp<unknown>,
        });
    }

    /** @internal */
    public scheduleReleaseAfterGrace<T>(op: AsyncOp<T>): void {
        const deadline = Date.now() + this.graceSeconds * 1000;
        this._releaseQueue.push({
            deadline,
            op: op as unknown as AsyncOp<unknown>,
        });
    }

    /**
     * Periodic reclamation sweep. Processes both the timeout queue and
     * the release queue.
     *
     * @internal
     */
    public reclaim(): void {
        if (this._shutdown) return;
        const now = Date.now();

        // Timeouts
        if (this._timeoutQueue.length > 0) {
            const remaining: TimeoutEntry<unknown>[] = [];
            for (const entry of this._timeoutQueue) {
                if (entry.deadline <= now) {
                    this.handleTimeout(entry.op);
                } else {
                    remaining.push(entry);
                }
            }
            this._timeoutQueue.length = 0;
            this._timeoutQueue.push(...remaining);
        }

        // Releases
        if (this._releaseQueue.length > 0) {
            const remaining: ReleaseEntry<unknown>[] = [];
            for (const entry of this._releaseQueue) {
                if (entry.deadline <= now) {
                    this.releaseOp(entry.op);
                } else {
                    remaining.push(entry);
                }
            }
            this._releaseQueue.length = 0;
            this._releaseQueue.push(...remaining);
        }
    }

    private handleTimeout(op: AsyncOp<unknown>): void {
        if (!op.abandon()) return;
        const p = op.promise;
        if (p instanceof CallPromise) {
            p._markAbandoned();
            if (!p.settled) {
                p._settleReject(
                    new LingoFuseTimeoutError(
                        "LingoFuse async call abandoned after timeout; " +
                        "the native-side request may still be in flight, " +
                        "but its result will be discarded.",
                    ),
                );
            }
        }
        this.scheduleReleaseAfterGrace(op);
    }

    /**
     * Release the Koffi callback for an op whose state machine permits
     * it. Called from reclaim() once the release deadline has passed.
     *
     * For FIRED / NOT_QUEUED ops the release is immediate.
     *
     * For ABANDONED ops the release is deferred by
     * ABANDONED_RELEASE_DELAY_MS so that a straggling native callback
     * reaches a still-valid trampoline. The deferring timer is
     * recorded on the instance so shutdown() can flush it.
     */
    private releaseOp(op: AsyncOp<unknown>): void {
        if (op.key === null) return;
        if (!this._handles.has(op.key)) return;

        const wasAbandoned = op.state === STATE_ABANDONED;

        this._handles.delete(op.key);
        this._releaseCount += 1;

        const callback = op.cCallback;

        if (wasAbandoned) {
            // Defer the release by the grace window. The timer handle
            // is kept in _pendingUnregisters so that shutdown() can
            // flush it if the bridge is torn down before the timer
            // fires.
            let timer: TimerHandle;
            timer = setTimeout(() => {
                this._pendingUnregisters.delete(timer);
                this.unregisterCallback(callback);
            }, ABANDONED_RELEASE_DELAY_MS);

            // Do not block process exit on this timer.
            const t = timer as { unref?: () => void };
            if (typeof t.unref === "function") t.unref();

            this._pendingUnregisters.set(timer, callback);
        } else {
            this.unregisterCallback(callback);
        }
    }

    /**
     * Best-effort release of a single Koffi callback object.
     *
     * Never throws: a failure here must not abort the release path.
     *
     * Koffi's TypeScript declaration restricts the parameter of
     * unregister() to `bigint`, but at runtime the function accepts
     * whatever register() returned. Cast the argument through a loose
     * function type to silence the type mismatch; the cast has no
     * runtime effect.
     */
    private unregisterCallback(callback: unknown): void {
        try {
            (koffi.unregister as (h: unknown) => void)(callback);
        } catch {
            // Best-effort.
        }
    }

    /** Snapshot of the bridge counters. */
    public stats(): AsyncBridgeStats {
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

    /**
     * Release every outstanding op's callback and flush every pending
     * grace timer. Idempotent.
     */
    public shutdown(): void {
        if (this._shutdown) return;
        this._shutdown = true;

        if (this._timer !== null) {
            clearInterval(this._timer);
            this._timer = null;
        }

        // Flush every pending grace-period release immediately.
        //
        // Clearing the timers alone would be wrong: the Koffi callback
        // objects those timers were supposed to release would then
        // leak, and their libuv handles would keep the event loop
        // alive. Release the callbacks first, then drop the timers.
        if (this._pendingUnregisters.size > 0) {
            const pending = Array.from(this._pendingUnregisters.entries());
            this._pendingUnregisters.clear();
            for (const [timer, callback] of pending) {
                try {
                    clearTimeout(timer);
                } catch {
                    // Best-effort.
                }
                this.unregisterCallback(callback);
            }
        }

        // Release every outstanding op's Koffi callback. Without this,
        // each still-pending op leaves behind a native thread-safe
        // function handle that keeps the event loop alive.
        for (const op of this._handles.values()) {
            this.unregisterCallback(op.cCallback);
        }

        this._handles.clear();
        this._timeoutQueue.length = 0;
        this._releaseQueue.length = 0;
    }
}

// =============================================================================
//  Factory helpers
// =============================================================================

/**
 * Create an AsyncOp with a Koffi callback registered on the given
 * deserializer. The deserializer runs INSIDE the native callback
 * window; it must fully consume the result handle and return a
 * detached value.
 */
function createAsyncOp<T>(
    deliver: DeliverFn<T>,
    deserialize: (rawResult: unknown) => T,
    promise: CallPromise<T> | null,
): AsyncOp<T> {
    // The Koffi callback needs a reference to the op before the op is
    // constructed. A single-slot cell breaks the circular reference.
    const cell: { op: AsyncOp<T> | null } = { op: null };

    const cCallback = koffi.register(
        function (_rawData: unknown, rawResult: unknown): void {
            const op = cell.op;
            if (op === null) return;

            let result: T | null = null;
            let error: Error | null = null;

            if (rawResult) {
                try {
                    result = deserialize(rawResult);
                } catch (err) {
                    error =
                        err instanceof Error
                            ? err
                            : new Error(String(err));
                }
            }

            op.invokeFromNative(result, error);
        },
        LfAsyncCallOnResultPtr,
    );

    const op = new AsyncOp<T>(deliver, cCallback, promise);
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
export function makeLegacyOp<T>(
    onResult: (
        result: T | null,
        error: Error | null,
        userData: unknown,
    ) => void,
    userData: unknown,
    deserialize: (rawResult: unknown) => T,
): AsyncOp<T> {
    function deliver(result: T | null, error: Error | null): void {
        try {
            onResult(result, error, userData);
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error(
                "[LingoFuse] User async on_result callback raised:",
                err,
            );
        }
    }
    return createAsyncOp<T>(deliver, deserialize, null);
}

/**
 * Build an AsyncOp + CallPromise pair.
 *
 * No timeout is armed here; call
 * AsyncBridge.instance().scheduleTimeout() after successful dispatch.
 * The runAsyncWithPromise helper does this.
 */
export function makeFutureOp<T>(deserialize: (rawResult: unknown) => T): {
    op: AsyncOp<T>;
    promise: CallPromise<T>;
} {
    const callPromise = new CallPromise<T>();

    function deliver(result: T | null, error: Error | null): void {
        if (callPromise.settled) return;
        if (error) {
            callPromise._settleReject(error);
        } else {
            callPromise._settleResolve(result as T);
        }
    }

    const op = createAsyncOp<T>(deliver, deserialize, callPromise);
    return { op, promise: callPromise };
}

/**
 * One-stop helper: build op+promise, issue the native request, arm the
 * timeout on success, and return the CallPromise.
 *
 * @param issueFn     A callable that takes the Koffi callback object
 *                    and issues the native request. Returns 1 on
 *                    successful dispatch, anything else on failure.
 * @param deserialize Converts the raw result handle into a detached
 *                    value. Called on the JS thread, inside the native
 *                    callback window.
 * @param timeoutMs   Optional JS-side timeout in milliseconds.
 */
export function runAsyncWithPromise<T>(
    issueFn: (cb: unknown) => number,
    deserialize: (rawResult: unknown) => T,
    timeoutMs?: number,
): CallPromise<T> {
    const { op, promise } = makeFutureOp<T>(deserialize);

    let ret: number;
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
                    `(dispatch returned ${ret})`,
                ),
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
 * @returns The dispatch return code (1 = queued).
 */
export function runLegacyOp<T>(
    issueFn: (cb: unknown) => number,
    onResult: (
        result: T | null,
        error: Error | null,
        userData: unknown,
    ) => void,
    userData: unknown,
    deserialize: (rawResult: unknown) => T,
): number {
    const op = makeLegacyOp<T>(onResult, userData, deserialize);

    let ret: number;
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
                    `(dispatch returned ${ret})`,
                ),
                userData,
            );
        } catch {
            // swallow
        }
    }
    return ret;
}