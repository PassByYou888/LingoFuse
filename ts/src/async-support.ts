import { koffi, LfAsyncCallOnResultPtr } from "./binding";
import { LingoFuseError, LingoFuseTimeoutError } from "./errors";

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
    "LINGOFUSE_ASYNC_RECLAIM_GRACE", 60.0, 0.0);
const DEFAULT_PERIOD_SECONDS = envFloat(
    "LINGOFUSE_ASYNC_RECLAIM_PERIOD", 1.0, 0.05);
const ABANDONED_RELEASE_DELAY_MS = 5000;

type TimerHandle = ReturnType<typeof setTimeout>;
type IntervalHandle = ReturnType<typeof setInterval>;

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

    public get abandoned(): boolean { return this._abandoned; }
    public get settled(): boolean { return this._settled; }

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

    public _settleResolve(value: T): void {
        if (this._settled) return;
        this._settled = true;
        this._resolve(value);
    }

    public _settleReject(err: unknown): void {
        if (this._settled) return;
        this._settled = true;
        this._reject(err);
    }

    public _markAbandoned(): void {
        this._abandoned = true;
    }
}

export type OpState =
    | "pending"
    | "fired"
    | "abandoned"
    | "not_queued";

const STATE_PENDING: OpState = "pending";
const STATE_FIRED: OpState = "fired";
const STATE_ABANDONED: OpState = "abandoned";
const STATE_NOT_QUEUED: OpState = "not_queued";

export type DeliverFn<T> = (
    result: T | null,
    error: Error | null,
) => void;

export class AsyncOp<T> {
    private readonly _deliver: DeliverFn<T>;
    private readonly _cCallback: unknown;
    private readonly _promise: CallPromise<T> | null;
    private _dataPtr: unknown;
    private _state: OpState = STATE_PENDING;
    private _key: number | null = null;

    public constructor(
        deliver: DeliverFn<T>,
        cCallback: unknown,
        promise: CallPromise<T> | null,
        dataPtr: unknown,
    ) {
        this._deliver = deliver;
        this._cCallback = cCallback;
        this._promise = promise;
        this._dataPtr = dataPtr;
    }

    public get cCallback(): unknown { return this._cCallback; }
    public get promise(): CallPromise<T> | null { return this._promise; }
    public get state(): OpState { return this._state; }
    public get key(): number | null { return this._key; }
    public set key(v: number | null) { this._key = v; }
    public get dataPtr(): unknown { return this._dataPtr; }

    public freeDataPtr(): void {
        if (this._dataPtr) {
            try {
                (koffi.free as (p: unknown) => void)(this._dataPtr);
            } catch { /* ignore */ }
            this._dataPtr = null;
        }
    }

    public markNotQueued(): void {
        if (this._state !== STATE_PENDING) return;
        this._state = STATE_NOT_QUEUED;
        AsyncBridge.instance().scheduleReleaseNow(this);
    }

    public invokeFromNative(
        result: T | null,
        error: Error | null,
    ): void {
        const current = this._state;
        if (current === STATE_FIRED) return;
        if (current === STATE_NOT_QUEUED) return;
        if (current === STATE_ABANDONED) {
            this._state = STATE_FIRED;
            AsyncBridge.instance().scheduleReleaseNow(this);
            return;
        }
        this._state = STATE_FIRED;
        try {
            this._deliver(result, error);
        } catch (err) {
            console.error(
                "[LingoFuse] AsyncOp delivery callback raised:", err);
        } finally {
            AsyncBridge.instance().scheduleReleaseNow(this);
        }
    }

    public abandon(): boolean {
        if (this._state !== STATE_PENDING) return false;
        this._state = STATE_ABANDONED;
        return true;
    }
}

interface ReleaseEntry<T = unknown> {
    deadline: number;
    op: AsyncOp<T>;
}

interface TimeoutEntry<T = unknown> {
    deadline: number;
    op: AsyncOp<T>;
}

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

export class AsyncBridge {
    private static _instance: AsyncBridge | null = null;

    private readonly _handles: Map<number, AsyncOp<unknown>> =
        new Map();
    private _counter = 0;
    private _releaseCount = 0;
    private readonly _timeoutQueue: TimeoutEntry<unknown>[] = [];
    private readonly _releaseQueue: ReleaseEntry<unknown>[] = [];
    private readonly _pendingUnregisters:
        Map<TimerHandle, AsyncOp<unknown>> = new Map();

    private _shutdown = false;
    private _timer: IntervalHandle | null = null;

    public graceSeconds: number = DEFAULT_GRACE_SECONDS;
    public periodSeconds: number = DEFAULT_PERIOD_SECONDS;

    private constructor() {
        this._timer = setInterval(
            () => this.reclaim(),
            Math.max(10, this.periodSeconds * 1000),
        );
        const t = this._timer as { unref?: () => void };
        if (typeof t.unref === "function") t.unref();
    }

    public static instance(): AsyncBridge {
        if (AsyncBridge._instance === null) {
            AsyncBridge._instance = new AsyncBridge();
        }
        return AsyncBridge._instance;
    }

    public static shutdownInstance(): void {
        if (AsyncBridge._instance !== null) {
            AsyncBridge._instance.shutdown();
            AsyncBridge._instance = null;
        }
    }

    public register<T>(op: AsyncOp<T>): void {
        this._counter += 1;
        op.key = this._counter;
        this._handles.set(
            op.key,
            op as unknown as AsyncOp<unknown>,
        );
    }

    public scheduleTimeout<T>(
        op: AsyncOp<T>,
        timeoutMs: number,
    ): void {
        if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return;
        const deadline = Date.now() + timeoutMs;
        this._timeoutQueue.push({
            deadline,
            op: op as unknown as AsyncOp<unknown>,
        });
    }

    public scheduleReleaseNow<T>(op: AsyncOp<T>): void {
        this._releaseQueue.push({
            deadline: Date.now(),
            op: op as unknown as AsyncOp<unknown>,
        });
    }

    public scheduleReleaseAfterGrace<T>(op: AsyncOp<T>): void {
        const deadline = Date.now() + this.graceSeconds * 1000;
        this._releaseQueue.push({
            deadline,
            op: op as unknown as AsyncOp<unknown>,
        });
    }

    public reclaim(): void {
        if (this._shutdown) return;
        const now = Date.now();

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

    private releaseOp(op: AsyncOp<unknown>): void {
        if (op.key === null) return;
        if (!this._handles.has(op.key)) return;

        const wasAbandoned = op.state === STATE_ABANDONED;

        this._handles.delete(op.key);
        this._releaseCount += 1;

        if (wasAbandoned) {
            let timer: TimerHandle;
            timer = setTimeout(() => {
                this._pendingUnregisters.delete(timer);
                this.unregisterCallback(op.cCallback);
                op.freeDataPtr();
            }, ABANDONED_RELEASE_DELAY_MS);
            const t = timer as { unref?: () => void };
            if (typeof t.unref === "function") t.unref();
            this._pendingUnregisters.set(timer, op);
        } else {
            this.unregisterCallback(op.cCallback);
            op.freeDataPtr();
        }
    }

    private unregisterCallback(callback: unknown): void {
        try {
            (koffi.unregister as (h: unknown) => void)(callback);
        } catch { /* ignore */ }
    }

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

    public shutdown(): void {
        if (this._shutdown) return;
        this._shutdown = true;

        if (this._timer !== null) {
            clearInterval(this._timer);
            this._timer = null;
        }

        if (this._pendingUnregisters.size > 0) {
            const pending =
                Array.from(this._pendingUnregisters.entries());
            this._pendingUnregisters.clear();
            for (const [timer, op] of pending) {
                try { clearTimeout(timer); } catch { /* ignore */ }
                this.unregisterCallback(op.cCallback);
                op.freeDataPtr();
            }
        }

        for (const op of this._handles.values()) {
            this.unregisterCallback(op.cCallback);
            op.freeDataPtr();
        }

        this._handles.clear();
        this._timeoutQueue.length = 0;
        this._releaseQueue.length = 0;
    }
}

function createAsyncOp<T>(
    deliver: DeliverFn<T>,
    deserialize: (rawResult: unknown) => T,
    promise: CallPromise<T> | null,
): AsyncOp<T> {
    let dataPtr: unknown;
    try {
        dataPtr = (koffi.alloc as (t: string, n: number) => unknown)(
            "uint8", 1);
    } catch (err) {
        const detail =
            err instanceof Error ? err.message : String(err);
        throw new LingoFuseError(
            "AsyncOp: failed to allocate native data pointer: " + detail,
        );
    }
    if (!dataPtr) {
        throw new LingoFuseError(
            "AsyncOp: native data pointer allocation returned null.");
    }

    const cell: { op: AsyncOp<T> | null } = { op: null };

    let cCallback: unknown;
    try {
        cCallback = koffi.register(
            function (_rawData: unknown, rawResult: unknown): void {
                const op = cell.op;
                if (op === null) return;

                let result: T | null = null;
                let error: Error | null = null;

                if (rawResult) {
                    try {
                        result = deserialize(rawResult);
                    } catch (err) {
                        error = err instanceof Error
                            ? err
                            : new Error(String(err));
                    }
                }

                op.invokeFromNative(result, error);
            },
            LfAsyncCallOnResultPtr,
        );
    } catch (err) {
        try {
            (koffi.free as (p: unknown) => void)(dataPtr);
        } catch { /* ignore */ }
        throw err;
    }

    let op: AsyncOp<T>;
    try {
        op = new AsyncOp<T>(deliver, cCallback, promise, dataPtr);
        cell.op = op;
        AsyncBridge.instance().register(op);
    } catch (err) {
        try {
            (koffi.unregister as (h: unknown) => void)(cCallback);
        } catch { /* ignore */ }
        try {
            (koffi.free as (p: unknown) => void)(dataPtr);
        } catch { /* ignore */ }
        throw err;
    }

    return op;
}

export function makeLegacyOp<T>(
    onResult: (
        result: T | null,
        error: Error | null,
        userData: unknown,
    ) => void,
    userData: unknown,
    deserialize: (rawResult: unknown) => T,
): AsyncOp<T> {
    function deliver(
        result: T | null,
        error: Error | null,
    ): void {
        try {
            onResult(result, error, userData);
        } catch (err) {
            console.error(
                "[LingoFuse] User async on_result callback raised:",
                err);
        }
    }
    return createAsyncOp<T>(deliver, deserialize, null);
}

export function makeFutureOp<T>(
    deserialize: (rawResult: unknown) => T,
): {
    op: AsyncOp<T>;
    promise: CallPromise<T>;
} {
    const callPromise = new CallPromise<T>();

    function deliver(
        result: T | null,
        error: Error | null,
    ): void {
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

export function runAsyncWithPromise<T>(
    issueFn: (cb: unknown, op: AsyncOp<T>) => number,
    deserialize: (rawResult: unknown) => T,
    timeoutMs?: number,
): CallPromise<T> {
    const { op, promise } = makeFutureOp<T>(deserialize);

    let ret: number;
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

export function runLegacyOp<T>(
    issueFn: (cb: unknown, op: AsyncOp<T>) => number,
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
                    `async request was not queued ` +
                    `(dispatch returned ${ret})`,
                ),
                userData,
            );
        } catch { /* ignore */ }
    }
    return ret;
}