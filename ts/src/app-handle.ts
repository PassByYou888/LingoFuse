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

type KoffiCallbackHandle = ReturnType<typeof koffi.register>;

export type CallHandler = (
    input: DataHandle,
    output: DataHandle,
) => void;

export type NotifyHandler = (input: DataHandle) => void;

let _callbackErrorReporter:
    | ((source: string, err: unknown) => void)
    | null = null;

export function setCallbackErrorReporter(
    fn: ((source: string, err: unknown) => void) | null,
): void {
    _callbackErrorReporter = fn;
}

export function reportCallbackError(
    source: string,
    err: unknown,
): void {
    if (_callbackErrorReporter !== null) {
        try {
            _callbackErrorReporter(source, err);
        } catch {
            /* broken reporter must not escape */
        }
        return;
    }
    try {
        const detail = err instanceof Error
            ? err.stack ?? err.message
            : String(err);
        process.stderr.write(
            `[LingoFuse] Callback error in ${source}: ${detail}\n`,
        );
    } catch {
        /* stderr unavailable */
    }
}

function unregisterCallback(handle: KoffiCallbackHandle | null): void {
    if (handle === null) return;
    try {
        (koffi.unregister as (h: unknown) => void)(handle);
    } catch {
        /* ignore */
    }
}

function writeErrorEnvelope(output: DataHandle, err: unknown): void {
    try {
        output.size = 0;
        output.position = 0;
        output.writeUInt8(0xFF);
        output.writeString(
            err instanceof Error ? err.message : String(err),
        );
    } catch {
        /* if envelope write itself fails, nothing more we can do */
    }
}

export class AppHandle {
    #binding: Binding;
    #handle: TAppHnd | null;
    #name: string;
    #disposed: boolean;
    #registrations: Map<string, KoffiCallbackHandle>;

    public constructor(name: string, description: string = "") {
        if (typeof name !== "string") {
            throw new TypeError(
                "AppHandle: name must be a string.");
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
                ErrorCode.Generic,
            );
        }
        this.#handle = raw;
    }

    public get name(): string {
        return this.#name;
    }

    public get raw(): TAppHnd | null {
        return this.#handle;
    }

    public get isValid(): boolean {
        return (
            !this.#disposed &&
            this.#handle !== null &&
            this.#handle !== undefined
        );
    }

    public registerCall(
        apiName: string,
        description: string,
        handler: CallHandler,
    ): boolean {
        if (typeof apiName !== "string") {
            throw new TypeError(
                "AppHandle.registerCall: apiName must be a string.");
        }
        if (typeof handler !== "function") {
            throw new TypeError(
                "AppHandle.registerCall: handler must be a function.");
        }
        const desc = description ?? "";
        this.#ensureNotDisposed();

        const key = apiName.toLowerCase();

        const bridge = koffi.register(
            (trigger: unknown, input: unknown, output: unknown): void => {
                void trigger;
                const inH = DataHandle.fromRaw(input, false);
                const outH = DataHandle.fromRaw(output, false);
                try {
                    handler(inH, outH);
                } catch (err) {
                    reportCallbackError(
                        `AppHandle.registerCall[${apiName}]`, err);
                    writeErrorEnvelope(outH, err);
                }
            },
            LfCallFuncPtr,
        );

        let result: number;
        try {
            result = this.#binding.funcs.LF_RegisterCall(
                this.#handle, apiName, desc, null, bridge);
        } catch (err) {
            unregisterCallback(bridge);
            throw err;
        }

        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }

        unregisterCallback(bridge);
        return false;
    }

    public registerNotify(
        apiName: string,
        description: string,
        handler: NotifyHandler,
    ): boolean {
        if (typeof apiName !== "string") {
            throw new TypeError(
                "AppHandle.registerNotify: apiName must be a string.");
        }
        if (typeof handler !== "function") {
            throw new TypeError(
                "AppHandle.registerNotify: handler must be a function.");
        }
        const desc = description ?? "";
        this.#ensureNotDisposed();

        const key = apiName.toLowerCase();

        const bridge = koffi.register(
            (trigger: unknown, input: unknown): void => {
                void trigger;
                const inH = DataHandle.fromRaw(input, false);
                try {
                    handler(inH);
                } catch (err) {
                    reportCallbackError(
                        `AppHandle.registerNotify[${apiName}]`, err);
                }
            },
            LfNotifyFuncPtr,
        );

        let result: number;
        try {
            result = this.#binding.funcs.LF_RegisterNotify(
                this.#handle, apiName, desc, null, bridge);
        } catch (err) {
            unregisterCallback(bridge);
            throw err;
        }

        if (result === 1) {
            this.#registrations.set(key, bridge);
            return true;
        }

        unregisterCallback(bridge);
        return false;
    }

    public unregister(apiName: string): boolean {
        if (typeof apiName !== "string") {
            throw new TypeError(
                "AppHandle.unregister: apiName must be a string.");
        }
        this.#ensureNotDisposed();

        const key = apiName.toLowerCase();
        const result = this.#binding.funcs.LF_Unregister(
            this.#handle, apiName);

        if (result === 1) {
            const bridge = this.#registrations.get(key);
            this.#registrations.delete(key);
            if (bridge !== undefined) {
                unregisterCallback(bridge);
            }
            return true;
        }
        return false;
    }

    public localCall(param: DataHandle): DataHandle {
        if (!(param instanceof DataHandle)) {
            throw new TypeError(
                "AppHandle.localCall: param must be a DataHandle.");
        }
        this.#ensureNotDisposed();

        const result = this.#binding.funcs.LF_LocalCall(
            this.#handle, param.raw);
        if (result === null || result === undefined) {
            throw new LingoFuseCallError(
                "LF_LocalCall returned a null handle.",
                { targetApp: this.#name },
            );
        }
        return DataHandle.fromRaw(result, true);
    }

    public localNotify(param: DataHandle): void {
        if (!(param instanceof DataHandle)) {
            throw new TypeError(
                "AppHandle.localNotify: param must be a DataHandle.");
        }
        this.#ensureNotDisposed();
        this.#binding.funcs.LF_LocalNotify(
            this.#handle, param.raw);
    }

    public bind(): number {
        this.#ensureNotDisposed();
        return this.#binding.funcs.LF_BindApp(this.#handle);
    }

    public dispose(): void {
        if (this.#disposed) return;
        this.#disposed = true;

        const handle = this.#handle;
        this.#handle = null;

        const bridges = Array.from(this.#registrations.values());
        this.#registrations.clear();

        if (handle !== null && handle !== undefined) {
            try {
                this.#binding.funcs.LF_FreeApp(handle);
            } catch {
                /* ensure trampolines still released below */
            }
        }

        for (const bridge of bridges) {
            unregisterCallback(bridge);
        }
    }

    #ensureNotDisposed(): void {
        if (
            this.#disposed ||
            this.#handle === null ||
            this.#handle === undefined
        ) {
            throw new LingoFuseObjectDisposedError("AppHandle");
        }
    }
}