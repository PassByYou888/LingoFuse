import { detectRuntime, getRuntimeInfo } from "./runtime";
/** Version of the TypeScript binding itself. */
export declare const VERSION = "1.0.0";
export { ErrorCode, LingoFuseError, LingoFuseLibraryLoadError, LingoFuseCallError, LingoFuseIoError, LingoFuseObjectDisposedError, LingoFuseCallbackError, } from "./errors";
export type { TDataHnd, TAppHnd, LfCallFunc, LfNotifyFunc, LfNetworkEventFunc, } from "./types";
export type { RuntimeFamily, RuntimeInfo, } from "./runtime";
export type { OptionName, BooleanOptionValue, } from "./options";
export { detectRuntime, getRuntimeInfo };
export { Option, bool } from "./options";
/** Alias kept for backward compatibility with earlier drafts. */
export { detectRuntime as runtime };
export { LibraryLoader } from "./library-loader";
export { getBinding, isLoaded as isNativeLoaded, selectPlatformFileName, buildSearchPaths, } from "./binding";
export { DataHandle } from "./data-handle";
export { AppHandle, setCallbackErrorReporter, reportCallbackError, } from "./app-handle";
export type { CallHandler, NotifyHandler, } from "./app-handle";
import * as io from "./lf-io";
export { io };
import * as framework from "./framework";
export { framework };
export type { CallbackErrorHandler } from "./framework";
import * as network from "./network-events";
export { network };
import * as status from "./status";
export { status };
/**
 * Eagerly trigger the lazy load of the native LingoFuse library.
 * Idempotent.
 *
 * @throws {LingoFuseLibraryLoadError} When the library cannot be loaded.
 */
export declare function loadLibrary(): boolean;
/**
 * Returns a short description of the current runtime, for diagnostics
 * and log headers.
 */
export declare function platform(): {
    readonly platform: string;
    readonly arch: string;
    readonly runtime: string;
};
//# sourceMappingURL=index.d.ts.map