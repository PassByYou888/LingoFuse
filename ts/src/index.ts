// =============================================================================
//  index.ts
// -----------------------------------------------------------------------------
//  Public entry point for the LingoFuse TypeScript binding.
//
//  Re-exports every public symbol from the lower layers and provides
//  small lifecycle helpers. The public surface is grouped into
//  namespaces, plus a set of top-level types and functions.
//
//  NAMESPACE LAYOUT
//  ----------------
//    lf.DataHandle          RAII wrapper for a data buffer
//    lf.AppHandle           RAII wrapper for an application
//    lf.io.*                JSON / string / byte I/O
//    lf.framework.*         process-wide ABI facade (low-level)
//    lf.network.*           network event handlers
//    lf.status.*            status queue and health checks
//    lf.options.*           typed runtime options
//    lf.address.*           three-addressing Target abstraction
//    lf.async.*             AsyncBridge / AsyncOp / CallPromise
//
//  TOP-LEVEL CONVENIENCE EXPORTS
//  -----------------------------
//    lf.AppTarget / lf.UIDTarget / lf.P2PNameTarget
//    lf.CallPromise / lf.AsyncBridge
//    lf.registerP2PCall / lf.registerP2PNotify / lf.unregisterP2P
//
//  LIFECYCLE HELPERS
//  -----------------
//    lf.loadLibrary()       eagerly load the native library
//    lf.isLoaded()          true once the library has been loaded
//    lf.libraryName()       platform-specific shared library name
//    lf.platform()          { platform, arch, runtime }
//
//  ESCAPE HATCH
//  ------------
//    lf._binding            the raw binding.ts module object
//
//  All code and documentation are in English.
// =============================================================================

// -----------------------------------------------------------------------------
//  Imports used by this module's own functions
// -----------------------------------------------------------------------------

import { detectRuntime, getRuntimeInfo } from "./runtime";
import { LingoFuseLibraryLoadError } from "./errors";
import * as bindingModule from "./binding";

// -----------------------------------------------------------------------------
//  Namespace imports (re-exported below)
// -----------------------------------------------------------------------------

import * as io from "./lf-io";
import * as framework from "./framework";
import * as network from "./network-events";
import * as status from "./status";
import * as options from "./options";
import * as address from "./address";
import * as asyncSupport from "./async-support";
import * as p2pReg from "./p2p-registration";

// -----------------------------------------------------------------------------
//  Version
// -----------------------------------------------------------------------------

/**
 * Version of the TypeScript binding itself. This is NOT the version of
 * the native LingoFuse runtime.
 *
 * 2.0.0 adds: the UID / P2PName families, the three-addressing Target
 * abstraction, the async-support subsystem, typed option shortcuts,
 * process-wide P2P registration, and full parity with the C ABI
 * export table (59 functions).
 */
export const VERSION = "2.0.0";

// -----------------------------------------------------------------------------
//  Errors
// -----------------------------------------------------------------------------

export {
    ErrorCode,
    LingoFuseError,
    LingoFuseLibraryLoadError,
    LingoFuseCallError,
    LingoFuseTimeoutError,
    LingoFuseIoError,
    LingoFuseObjectDisposedError,
    LingoFuseCallbackError,
    LingoFuseRegistrationError,
} from "./errors";

// -----------------------------------------------------------------------------
//  Types
// -----------------------------------------------------------------------------

export type {
    TDataHnd,
    TAppHnd,
    TP2P_UID,
    LfCallFunc,
    LfNotifyFunc,
    LfNetworkEventFunc,
    LfAsyncCallOnResult,
} from "./types";

export type {
    RuntimeFamily,
    RuntimeInfo,
} from "./runtime";

export type {
    OptionName,
    BooleanOptionValue,
} from "./options";

export type {
    AsyncBridgeStats,
    OpState,
} from "./async-support";

export type {
    TargetOptions,
    CallOptions,
} from "./address";

export type {
    CallbackErrorHandler,
} from "./framework";

export type {
    CallHandler,
    NotifyHandler,
} from "./app-handle";

// -----------------------------------------------------------------------------
//  Runtime helpers
// -----------------------------------------------------------------------------

export { detectRuntime, getRuntimeInfo };

/**
 * The canonical option name constants, plus the boolean-to-string
 * helper that emits the native "True" / "False" spellings.
 */
export { Option, bool } from "./options";

/**
 * Alias kept for backward compatibility with earlier drafts, mirroring
 * the historical name used by the JavaScript binding.
 */
export { detectRuntime as runtime };

// -----------------------------------------------------------------------------
//  Library loader
// -----------------------------------------------------------------------------

export { LibraryLoader } from "./library-loader";

// -----------------------------------------------------------------------------
//  RAII handles
// -----------------------------------------------------------------------------

export { DataHandle } from "./data-handle";

export {
    AppHandle,
    setCallbackErrorReporter,
    reportCallbackError,
} from "./app-handle";

// -----------------------------------------------------------------------------
//  Namespaces
// -----------------------------------------------------------------------------

export { io, framework, network, status, options, address };

/**
 * The async-support subsystem, exported under both the short name
 * `async` (matching the JavaScript binding) and the longer name
 * `asyncSupport` (for callers who prefer a name that is not a reserved
 * word in downstream tooling).
 */
export { asyncSupport as async };
export { asyncSupport };

// -----------------------------------------------------------------------------
//  Top-level shortcuts (addressing targets)
// -----------------------------------------------------------------------------

export const AppTarget = address.AppTarget;
export const UIDTarget = address.UIDTarget;
export const P2PNameTarget = address.P2PNameTarget;

// -----------------------------------------------------------------------------
//  Top-level shortcuts (async subsystem)
// -----------------------------------------------------------------------------

export const CallPromise = asyncSupport.CallPromise;
export const AsyncBridge = asyncSupport.AsyncBridge;

// -----------------------------------------------------------------------------
//  Top-level shortcuts (process-wide P2P registration)
// -----------------------------------------------------------------------------

export const registerP2PCall = p2pReg.registerP2PCall;
export const registerP2PNotify = p2pReg.registerP2PNotify;
export const unregisterP2P = p2pReg.unregisterP2P;

// -----------------------------------------------------------------------------
//  Binding singleton access
// -----------------------------------------------------------------------------

export const getBinding = bindingModule.getBinding;
export const isLoaded = bindingModule.isLoaded;
export const selectPlatformFileName = bindingModule.selectPlatformFileName;
export const buildSearchPaths = bindingModule.buildSearchPaths;

/**
 * Historical alias for isLoaded(), preserved for backward compatibility
 * with the pre-2.0 TypeScript binding.
 */
export const isNativeLoaded = bindingModule.isLoaded;

// -----------------------------------------------------------------------------
//  Escape hatch
// -----------------------------------------------------------------------------

/**
 * The raw binding.ts module object. Intended for advanced users who
 * need direct access to the Koffi declarations (custom types, direct
 * function invocation, version probing).
 *
 * Normal application code should use the higher-level wrappers.
 */
export const _binding = bindingModule;

// -----------------------------------------------------------------------------
//  Lifecycle helpers
// -----------------------------------------------------------------------------

/**
 * Eagerly triggers the lazy load of the native LingoFuse library.
 *
 * Idempotent: the second and subsequent calls return true without
 * reloading. Throws LingoFuseLibraryLoadError when the library cannot
 * be located or loaded.
 *
 * @throws {LingoFuseLibraryLoadError}
 */
export function loadLibrary(): boolean {
    try {
        bindingModule.getBinding();
        return true;
    } catch (err) {
        const libName = bindingModule.selectPlatformFileName();
        const message = err instanceof Error ? err.message : String(err);
        throw new LingoFuseLibraryLoadError(
            libName,
            message,
            { cause: err },
        );
    }
}

/**
 * Returns the platform-specific shared library file name.
 *
 * On Windows : LingoFuse64.dll / LingoFuse32.dll
 * On Linux   : liblingofuse.so
 * On macOS   : liblingofuse.dylib
 */
export function libraryName(): string {
    return bindingModule.selectPlatformFileName();
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