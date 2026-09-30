/**
 * @file index.js
 * @brief Public entry point for the LingoFuse JavaScript binding.
 *
 * This module is the single import surface for applications. It
 * re-exports every public symbol from the lower layers and provides
 * two small lifecycle helpers that mirror the C++ binding's
 * `LF_LoadLibrary` / `LF_FreeLibrary` names for cross-language
 * familiarity.
 *
 * ============================================================================
 * QUICK START
 * ============================================================================
 * @code
 * const lf = require("lingofuse-js");
 *
 * // 1. Load the runtime (idempotent, can be skipped - the binding
 * //    loads on first use anyway).
 * lf.loadLibrary();
 *
 * // 2. Create an application and register a Call API.
 * const app = new lf.AppHandle("Calculator", "Demo");
 * app.registerCall("add", "Add two integers", (input, output) => {
 *     const req = lf.io.readJson(input);
 *     lf.io.writeJson(output, { result: (req.a ?? 0) + (req.b ?? 0) });
 * });
 *
 * // 3. Prepare the framework.
 * lf.framework.resetPrepare();
 * lf.framework.prepareService("ipc:calc", "ipc:calc");
 * lf.framework.prepareClient("ipc:calc", app);
 * if (lf.framework.prepareDone() !== 1) {
 *     throw new Error("framework startup failed");
 * }
 *
 * // 4. Invoke the API locally.
 * const param = new lf.DataHandle("add");
 * lf.io.writeJson(param, { a: 5, b: 7 });
 * const result = app.localCall(param);
 * console.log(lf.io.readJson(result));   // { result: 12 }
 *
 * // 5. Clean up.
 * param.dispose();
 * result.dispose();
 * app.dispose();
 * lf.framework.exitMainThread();
 * lf.framework.shutdown();
 * @endcode
 *
 * ============================================================================
 * NAMESPACE LAYOUT
 * ============================================================================
 * The public surface is grouped into four namespaces plus a small set
 * of top-level types and functions:
 *
 *   lf.DataHandle          - RAII wrapper for a data buffer
 *   lf.AppHandle           - RAII wrapper for an application
 *   lf.io.*                - JSON / string / byte I/O
 *   lf.framework.*         - process-wide ABI facade
 *   lf.network.*           - network event handlers
 *   lf.status.*            - status queue and health checks
 *
 *   lf.LingoFuseError      - base exception
 *   lf.LingoFuseLibraryLoadError
 *   lf.LingoFuseCallError
 *   lf.LingoFuseIoError
 *   lf.LingoFuseObjectDisposedError
 *   lf.LingoFuseCallbackError
 *
 *   lf.loadLibrary()       - eager load (idempotent)
 *   lf.isLoaded()          - has the runtime been loaded?
 *   lf.libraryName()       - platform-specific library file name
 *   lf.platform()          - process.platform / process.arch summary
 *
 * ============================================================================
 * LIBRARY LOADING - A NOTE ON THE C++ VS. JS DIFFERENCE
 * ============================================================================
 * The C++ binding requires an explicit `LF_LoadLibrary()` call before
 * any other `LF_*` function. This is because the C wrapper implements
 * the ABI as a table of function pointers that is populated only when
 * the user asks for it.
 *
 * The JavaScript binding does NOT have this requirement. Koffi loads
 * the shared library the first time a native function is invoked, and
 * the CLR / Deno / Bun equivalent of a "load library" step is handled
 * lazily by Koffi's own resolver. There is no user-visible "before
 * load" state where a call would silently do nothing.
 *
 * For cross-language familiarity, this module still exports
 * `loadLibrary()`. It is idempotent and eagerly triggers the lazy
 * load, so any missing-library error is raised at the call site of
 * `loadLibrary()` rather than at the first unrelated native call.
 *
 * There is no `freeLibrary()`. Koffi does not support unloading a
 * shared library while it may still be in use, and forcing an unload
 * would leave dangling function pointers. Process exit is the only
 * safe release point, which is exactly when the OS unloads the
 * library anyway. Applications that need to shut down the framework
 * should call `framework.shutdown()`; that resets LingoFuse's internal
 * state without unloading the shared object.
 *
 * ============================================================================
 * DEPENDENCY DIRECTION
 * ============================================================================
 *
 *     index.js           (this file - public surface)
 *         ^
 *     framework.js  app-handle.js  network-events.js  status.js  lf-io.js
 *         ^
 *     data-handle.js
 *         ^
 *     binding.js         (raw Koffi declarations)
 *         ^
 *     errors.js          (standalone exception hierarchy)
 *
 * ============================================================================
 */

"use strict";

// ---------------------------------------------------------------------------
// Import every layer of the binding.
// ---------------------------------------------------------------------------

const binding = require("./binding");
const errors = require("./errors");
const { DataHandle } = require("./data-handle");
const { AppHandle } = require("./app-handle");
const io = require("./lf-io");
const framework = require("./framework");
const network = require("./network-events");
const status = require("./status");

// ---------------------------------------------------------------------------
// Version
// ---------------------------------------------------------------------------

/**
 * Version of the JavaScript binding itself. This is NOT the version of
 * the native LingoFuse runtime (which is reported by the native
 * library as `'3.06'` and is not surfaced through the C ABI).
 *
 * @type {string}
 */
const VERSION = "1.0.0";

// ---------------------------------------------------------------------------
// Lifecycle helpers
// ---------------------------------------------------------------------------

/**
 * Eagerly triggers the lazy load of the native LingoFuse library.
 *
 * This function is idempotent: calling it multiple times has no
 * additional effect after the first successful load. Its only purpose
 * is to make a missing-library error visible at a well-defined point
 * in the program rather than at the first unrelated native call.
 *
 * @returns {boolean}
 *   Always returns `true`. If the library cannot be loaded, this
 *   function throws instead of returning `false`, so that the caller
 *   sees the failure with a full stack trace.
 * @throws {import('./errors').LingoFuseLibraryLoadError}
 *   When the native library cannot be found or loaded. (Note: the
 *   underlying loader throws a plain `Error`, and this wrapper
 *   rethrows it with the library name attached so the caller can
 *   catch a structured type.)
 */
function loadLibrary() {
    try {
        binding.getBinding();
        return true;
    } catch (err) {
        // The binding layer throws a generic Error with a detailed
        // message. Rewrap it as a structured LingoFuse error so that
        // applications can dispatch on the type.
        const libName = binding.selectPlatformFileName();
        throw new errors.LingoFuseLibraryLoadError(
            libName,
            err.message,
            { cause: err }
        );
    }
}

/**
 * Returns true when the native library has been successfully loaded.
 *
 * @returns {boolean}
 */
function isLoaded() {
    return binding.isLoaded();
}

/**
 * Returns the platform-specific library file name that the binding
 * would try to load on this system.
 *
 * @returns {string}
 */
function libraryName() {
    return binding.selectPlatformFileName();
}

/**
 * Returns a short description of the current runtime, for diagnostics
 * and log headers.
 *
 * @returns {{ platform: string, arch: string, runtime: string }}
 */
function platform() {
    let runtime = "node";
    if (typeof Deno !== "undefined") {
        runtime = "deno";
    } else if (typeof Bun !== "undefined") {
        runtime = "bun";
    }
    return {
        platform: process.platform,
        arch: process.arch,
        runtime,
    };
}

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

module.exports = {
    // ------------------------------------------------------------------
    // Version
    // ------------------------------------------------------------------
    VERSION,

    // ------------------------------------------------------------------
    // Lifecycle helpers
    // ------------------------------------------------------------------
    loadLibrary,
    isLoaded,
    libraryName,
    platform,

    // ------------------------------------------------------------------
    // RAII handle types
    // ------------------------------------------------------------------
    DataHandle,
    AppHandle,

    // ------------------------------------------------------------------
    // Grouped namespaces
    // ------------------------------------------------------------------
    io,
    framework,
    network,
    status,

    // ------------------------------------------------------------------
    // Exceptions (re-exported for convenience)
    // ------------------------------------------------------------------
    LingoFuseError: errors.LingoFuseError,
    LingoFuseLibraryLoadError: errors.LingoFuseLibraryLoadError,
    LingoFuseCallError: errors.LingoFuseCallError,
    LingoFuseIoError: errors.LingoFuseIoError,
    LingoFuseObjectDisposedError: errors.LingoFuseObjectDisposedError,
    LingoFuseCallbackError: errors.LingoFuseCallbackError,

    // ------------------------------------------------------------------
    // Advanced / low-level escape hatches
    // ------------------------------------------------------------------
    // These are exposed for advanced use cases (custom types, direct
    // Koffi calls, integration tests that need the raw handle). Normal
    // application code should not use them.
    // ------------------------------------------------------------------
    _binding: binding,
};