import { DataHandle } from "./data-handle";
import { AppHandle } from "./app-handle";
/** Optional handler invoked when a user callback throws. */
export type CallbackErrorHandler = (source: string, err: unknown) => void;
/** Install a callback error handler. Pass null to remove it. */
export declare function setCallbackErrorHandler(fn: CallbackErrorHandler | null): void;
/** Read the currently installed callback error handler. */
export declare function getCallbackErrorHandler(): CallbackErrorHandler | null;
/** Clear any previously prepared services and clients. */
export declare function resetPrepare(): void;
/** Prepare a C4 service listening on listeningAddr and advertised as physicsAddr. */
export declare function prepareService(listeningAddr: string, physicsAddr: string): number;
/** Prepare a C4 client connecting to physicsAddr and optionally exposing app. */
export declare function prepareClient(physicsAddr: string, app?: AppHandle | null): number;
/** Start the framework. Returns 1 on success; 0 on a repeated call. */
export declare function prepareDone(): number;
/** Request the simulated main thread to exit. */
export declare function exitMainThread(): void;
/** Adjust a global runtime option. Unknown option names are silently ignored. */
export declare function setOption(option: string, value: string): void;
/**
 * Generate a globally unique application name.
 *
 * Must be called after prepareDone() has returned 1. The native function
 * returns a pointer valid for approximately 5 seconds; this wrapper
 * copies the string immediately.
 */
export declare function generateAppName(): string;
/**
 * Perform a synchronous remote call. On timeout or failure, the
 * returned handle has size 0 (it is never null).
 */
export declare function call(appName: string, param: DataHandle, timeoutMs?: number | bigint): DataHandle;
/** Send a one-way Notify. Delivery order is not guaranteed. */
export declare function notify(appName: string, param: DataHandle): void;
/** Send a one-way notification with FIFO ordering per (app, api) pair. */
export declare function sequencedNotify(appName: string, param: DataHandle): void;
/** Gracefully terminate the framework, releasing all resources. */
export declare function shutdown(): void;
//# sourceMappingURL=framework.d.ts.map