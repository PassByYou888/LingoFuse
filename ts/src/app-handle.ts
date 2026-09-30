// =============================================================================
//  app-handle.ts
// -----------------------------------------------------------------------------
//  RAII wrapper around a native TAppHnd.
//
//  Callback registration:
//      koffi.register() requires the callback pointer type built from the
//      matching koffi.proto(). Passing koffi.pointer("void") raises:
//          TypeError: Unexpected void * type, expected <callback> * type
//      The correct pointer types (LfCallFuncPtr / LfNotifyFuncPtr) are
//      declared and exported by binding.ts.
// =============================================================================

import { getBinding, koffi, LfCallFuncPtr, LfNotifyFuncPtr } from "./binding";
import type { Binding } from "./binding";
import type { TAppHnd } from "./types";
import { DataHandle } from "./data-handle";
import {
    LingoFuseCallError,
    LingoFuseError,
    LingoFuseObjectDisposedError,
    ErrorCode,
} from "./errors";

/** The handle type returned by koffi.register. */
type KoffiCallbackHandle = ReturnType<typeof koffi.register>;

/** Signature of a user-supplied Call-mode handler. */
export type CallHandler = (input: DataHandle, output: DataHandle) => void;

/** Signature of a user-supplied Notify-mode handler. */
export type NotifyHandler = (input: DataHandle) => void;

/** Internal slot shared with framework.ts for error reporting. */
let _callbackErrorReporter: ((source: string, err: unknown) => void) | null = null;

/** Install the process-wide callback error reporter. */
export function setCallbackErrorReporter(
    fn: ((source: string, err: unknown) => void) | null,
): void {
    _callbackErrorReporter = fn;
}

/** Report a swallowed callback error through the installed reporter. */
export function reportCallbackError(source: string, err: unknown): void {
    if (_callbackErrorReporter !== null) {
        try {
            _callbackErrorReporter(source, err);
        } catch {
            // A broken reporter must not escape into the native worker.
        }
        return;
    }
    try {
        const detail = err instanceof Error ? err.stack ?? err.message : String(err);
        process.stderr.write(`[LingoFuse] Callback error in ${source}: ${detail}\n`);
    } catch {
        // stderr may be unavailable in some embeddings. Ignore.
    }
}

export class AppHandle {
    #binding: Binding;
    #handle: TAppHnd | null;
    #name: string;
    #disposed: boolean;
    #registrations: Map<string, KoffiCallbackHandle>;

    /**
     * Create a new application with the given name and description.
     *
     * @throws {LingoFuseError} When the native side fails to allocate
     *         the application.
     */
    public constructor(name: string, description: string = "") {
        if (typeof name !== "string") {
            throw new TypeError("AppHandle: name must be a string.");
        }
        const desc = description ?? "";

        const binding = getBinding();
        this.#binding = binding;
        this.#name = name;
        this.#disposed = false;
        this.#registrations = new Map();

        const raw = binding.funcs.LF_CreateApp(name, desc);
        if (raw === null || raw === undefined) {
            throw new LingoFuseError(
                `Failed to create application '${name}'.`,
                ErrorCode.Generic);
        }
        this.#handle = raw;
    }

    public get name(): string { return this.#name; }
    public get raw(): TAppHnd | null { return this.#handle; }
    public get isValid(): boolean {
        return !this.#disposed && this.#handle !== null && this.#handle !== undefined;
    }

    // ---- API registration ----

    /** Register a Call (request-response) API. */
    public registerCall(
        apiName: string,
        description: string,
        handler: CallHandler,
    ): boolean {
        if (typeof apiName !== "string") {
            throw new TypeError("AppHandle.registerCall: apiName must be a string.");
        }
        if (typeof handler !== "function") {
            throw new TypeError("AppHandle.registerCall: handler must be a function.");
        }
        const desc = description ?? "";
        this.#ensureNotDisposed();

        const key = apiName.toLowerCase();

        const bridge = koffi.register(
            (trigger: unknown, input: unknown, output: unknown): void => {
                const inH = DataHandle.fromRaw(input, false);
                const outH = DataHandle.fromRaw(output, false);
                try {
                    handler(inH, outH);
                } catch (err) {
                    reportCallbackError(`AppHandle.registerCall[${apiName}]`, err);
                }
            },
            LfCallFuncPtr,
        );

        const result = this.#binding.funcs.LF_RegisterCall(
            this.#handle, apiName, desc, null, bridge);

        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }

        try { koffi.unregister(bridge); } catch { /* ignore */ }
        return false;
    }

    /** Register a Notify (one-way) API. */
    public registerNotify(
        apiName: string,
        description: string,
        handler: NotifyHandler,
    ): boolean {
        if (typeof apiName !== "string") {
            throw new TypeError("AppHandle.registerNotify: apiName must be a string.");
        }
        if (typeof handler !== "function") {
            throw new TypeError("AppHandle.registerNotify: handler must be a function.");
        }
        const desc = description ?? "";
        this.#ensureNotDisposed();

        const key = apiName.toLowerCase();

        const bridge = koffi.register(
            (trigger: unknown, input: unknown): void => {
                const inH = DataHandle.fromRaw(input, false);
                try {
                    handler(inH);
                } catch (err) {
                    reportCallbackError(`AppHandle.registerNotify[${apiName}]`, err);
                }
            },
            LfNotifyFuncPtr,
        );

        const result = this.#binding.funcs.LF_RegisterNotify(
            this.#handle, apiName, desc, null, bridge);

        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }

        try { koffi.unregister(bridge); } catch { /* ignore */ }
        return false;
    }

    /** Unregister a previously registered API. */
    public unregister(apiName: string): boolean {
        if (typeof apiName !== "string") {
            throw new TypeError("AppHandle.unregister: apiName must be a string.");
        }
        this.#ensureNotDisposed();

        const key = apiName.toLowerCase();
        const result = this.#binding.funcs.LF_Unregister(this.#handle, apiName);

        if (result === 1) {
            const bridge = this.#registrations.get(key);
            this.#registrations.delete(key);
            if (bridge !== undefined) {
                try { koffi.unregister(bridge); } catch { /* ignore */ }
            }
            return true;
        }
        return false;
    }

    // ---- Local execution ----

    /**
     * Invoke a Call API locally. The result handle has size 0 when the
     * target API is not registered.
     */
    public localCall(param: DataHandle): DataHandle {
        if (!(param instanceof DataHandle)) {
            throw new TypeError("AppHandle.localCall: param must be a DataHandle.");
        }
        this.#ensureNotDisposed();

        const result = this.#binding.funcs.LF_LocalCall(this.#handle, param.raw);
        if (result === null || result === undefined) {
            throw new LingoFuseCallError(
                "LF_LocalCall returned a null handle.",
                { targetApp: this.#name });
        }
        return DataHandle.fromRaw(result, true);
    }

    /** Invoke a Notify API locally. */
    public localNotify(param: DataHandle): void {
        if (!(param instanceof DataHandle)) {
            throw new TypeError("AppHandle.localNotify: param must be a DataHandle.");
        }
        this.#ensureNotDisposed();
        this.#binding.funcs.LF_LocalNotify(this.#handle, param.raw);
    }

    // ---- Client binding ----

    /**
     * Bind the application to all currently unbound clients. Must be
     * called after prepareDone() returned 1.
     */
    public bind(): number {
        this.#ensureNotDisposed();
        return this.#binding.funcs.LF_BindApp(this.#handle);
    }

    // ---- Lifetime ----

    /**
     * Stage one of two-stage destruction: detaches the application
     * from all clients and stops its sequenced threads. The native
     * object remains in the global pool until shutdown() is called.
     */
    public dispose(): void {
        if (this.#disposed) return;
        this.#disposed = true;

        for (const bridge of this.#registrations.values()) {
            try { koffi.unregister(bridge); } catch { /* ignore */ }
        }
        this.#registrations.clear();

        const handle = this.#handle;
        this.#handle = null;
        if (handle !== null && handle !== undefined) {
            this.#binding.funcs.LF_FreeApp(handle);
        }
    }

    // ---- Internal ----

    #ensureNotDisposed(): void {
        if (this.#disposed || this.#handle === null || this.#handle === undefined) {
            throw new LingoFuseObjectDisposedError("AppHandle");
        }
    }
}