import type { TAppHnd } from "./types";
import { DataHandle } from "./data-handle";
/** Signature of a user-supplied Call-mode handler. */
export type CallHandler = (input: DataHandle, output: DataHandle) => void;
/** Signature of a user-supplied Notify-mode handler. */
export type NotifyHandler = (input: DataHandle) => void;
/** Install the process-wide callback error reporter. */
export declare function setCallbackErrorReporter(fn: ((source: string, err: unknown) => void) | null): void;
/** Report a swallowed callback error through the installed reporter. */
export declare function reportCallbackError(source: string, err: unknown): void;
export declare class AppHandle {
    #private;
    /**
     * Create a new application with the given name and description.
     *
     * @throws {LingoFuseError} When the native side fails to allocate
     *         the application.
     */
    constructor(name: string, description?: string);
    get name(): string;
    get raw(): TAppHnd | null;
    get isValid(): boolean;
    /** Register a Call (request-response) API. */
    registerCall(apiName: string, description: string, handler: CallHandler): boolean;
    /** Register a Notify (one-way) API. */
    registerNotify(apiName: string, description: string, handler: NotifyHandler): boolean;
    /** Unregister a previously registered API. */
    unregister(apiName: string): boolean;
    /**
     * Invoke a Call API locally. The result handle has size 0 when the
     * target API is not registered.
     */
    localCall(param: DataHandle): DataHandle;
    /** Invoke a Notify API locally. */
    localNotify(param: DataHandle): void;
    /**
     * Bind the application to all currently unbound clients. Must be
     * called after prepareDone() returned 1.
     */
    bind(): number;
    /**
     * Stage one of two-stage destruction: detaches the application
     * from all clients and stops its sequenced threads. The native
     * object remains in the global pool until shutdown() is called.
     */
    dispose(): void;
}
//# sourceMappingURL=app-handle.d.ts.map