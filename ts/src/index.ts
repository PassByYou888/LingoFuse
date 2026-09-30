// =============================================================================
//  index.ts
// -----------------------------------------------------------------------------
//  Public entry point for the LingoFuse TypeScript binding.
//
//  Re-exports every public symbol from the lower layers and provides
//  small lifecycle helpers. The public surface is grouped into
//  namespaces, plus a set of top-level types and functions.
// =============================================================================

// -----------------------------------------------------------------------------
//  Imports used by this module's own functions
// -----------------------------------------------------------------------------

import { detectRuntime, getRuntimeInfo } from "./runtime";
import { getBinding } from "./binding";
import { LingoFuseLibraryLoadError } from "./errors";

// -----------------------------------------------------------------------------
//  Version
// -----------------------------------------------------------------------------

/** Version of the TypeScript binding itself. */
export const VERSION = "1.0.0";

// -----------------------------------------------------------------------------
//  Errors
// -----------------------------------------------------------------------------

export {
    ErrorCode,
    LingoFuseError,
    LingoFuseLibraryLoadError,
    LingoFuseCallError,
    LingoFuseIoError,
    LingoFuseObjectDisposedError,
    LingoFuseCallbackError,
} from "./errors";

// -----------------------------------------------------------------------------
//  Types
// -----------------------------------------------------------------------------

export type {
    TDataHnd,
    TAppHnd,
    LfCallFunc,
    LfNotifyFunc,
    LfNetworkEventFunc,
} from "./types";

export type {
    RuntimeFamily,
    RuntimeInfo,
} from "./runtime";

export type {
    OptionName,
    BooleanOptionValue,
} from "./options";

// -----------------------------------------------------------------------------
//  Runtime helpers
// -----------------------------------------------------------------------------

export { detectRuntime, getRuntimeInfo };
export { Option, bool } from "./options";

/** Alias kept for backward compatibility with earlier drafts. */
export { detectRuntime as runtime };

// -----------------------------------------------------------------------------
//  Library loader
// -----------------------------------------------------------------------------

export { LibraryLoader } from "./library-loader";
export {
    getBinding,
    isLoaded as isNativeLoaded,
    selectPlatformFileName,
    buildSearchPaths,
} from "./binding";

// -----------------------------------------------------------------------------
//  RAII handles
// -----------------------------------------------------------------------------

export { DataHandle } from "./data-handle";
export {
    AppHandle,
    setCallbackErrorReporter,
    reportCallbackError,
} from "./app-handle";
export type {
    CallHandler,
    NotifyHandler,
} from "./app-handle";

// -----------------------------------------------------------------------------
//  Namespaces
// -----------------------------------------------------------------------------

import * as io from "./lf-io";
export { io };

import * as framework from "./framework";
export { framework };
export type { CallbackErrorHandler } from "./framework";

import * as network from "./network-events";
export { network };

import * as status from "./status";
export { status };

// -----------------------------------------------------------------------------
//  Lifecycle helpers
// -----------------------------------------------------------------------------

/**
 * Eagerly trigger the lazy load of the native LingoFuse library.
 * Idempotent.
 *
 * @throws {LingoFuseLibraryLoadError} When the library cannot be loaded.
 */
export function loadLibrary(): boolean {
    try {
        getBinding();
        return true;
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        throw new LingoFuseLibraryLoadError(
            "LingoFuse native library",
            message,
            { cause: err });
    }
}

/**
 * Returns a short description of the current runtime, for diagnostics
 * and log headers.
 */
export function platform(): {
    readonly platform: string;
    readonly arch: string;
    readonly runtime: string;
} {
    const info = getRuntimeInfo();
    return {
        platform: info.platform,
        arch: info.arch,
        runtime: info.family,
    };
}