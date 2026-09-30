/**
 * @file framework.js
 * @brief Process-wide ABI facade for the LingoFuse native library.
 *
 * This module is the public entry point for every process-wide operation
 * that the native library exposes but that does not fit the DataHandle
 * or AppHandle abstractions:
 *
 *   - Network preparation (reset / prepare service / prepare client /
 *     prepare done / exit main thread).
 *   - Remote invocation (call / notify / sequenced notify).
 *   - Runtime options (set option).
 *   - Application name generation.
 *   - Process-wide shutdown.
 *
 * The module exists because binding.js returns only the raw function
 * table: the public layer must present each native export through a
 * signature that handles UTF-8 marshalling, argument validation, and
 * the ownership transfer of any DataHnd returned by the native side.
 *
 * This module performs no caching, no state management, and no
 * lifecycle coordination. Every function forwards to exactly one native
 * export. Callers who need to know the precise native semantics should
 * read the corresponding XML documentation in LingoFuse.h or the C#
 * Framework.cs file, which this module mirrors one-to-one.
 *
 * ============================================================================
 * CALLBACK ERROR REPORTING
 * ============================================================================
 * Callback bodies registered through AppHandle and NetworkEvents run on
 * native worker threads. An exception escaping such a body would cross
 * into the C stack and could destabilise the process, so every callback
 * is wrapped to swallow exceptions.
 *
 * The wrapper reports every swallowed exception through two channels:
 *
 *   1. The `callbackErrorHandler` property, if the application set one.
 *      This is the intended integration point for a real logging
 *      pipeline (pino, winston, a structured event sink, ...).
 *
 *   2. stderr, unconditionally. This gives every swallowed exception a
 *      default visible sink without requiring the application to
 *      install a handler.
 *
 * The handler is optional. A failure inside the handler itself is
 * swallowed, so a broken logger cannot crash the process.
 *
 * Note that the error reporter is installed on app-handle.js at module
 * load time. Until this module is require()d, app-handle.js falls back
 * to the stderr path directly. Requiring framework.js therefore
 * enables the pluggable handler.
 *
 * ============================================================================
 * NUMERIC ARGUMENTS
 * ============================================================================
 * `timeoutMs` is a 64-bit unsigned integer in the C ABI. JavaScript has
 * no native 64-bit unsigned integer type, so callers may pass either a
 * Number (safe up to 2^53 - 1, which covers every realistic timeout) or
 * a BigInt (for exact values up to 2^64 - 1). The boundary
 * normalises the value to BigInt before calling Koffi.
 *
 * A timeout of 0 means "wait indefinitely". The default is 5000 ms,
 * matching the C# binding.
 *
 * ============================================================================
 * DEPENDENCY DIRECTION
 * ============================================================================
 *
 *     binding.js         (raw Koffi declarations)
 *         ^
 *     data-handle.js     (RAII wrapper for TDataHnd)
 *     app-handle.js      (RAII wrapper for TAppHnd)
 *         ^
 *     framework.js       (this file - process-wide facade)
 *
 * ============================================================================
 */

"use strict";

const { getBinding } = require("./binding");
const { DataHandle } = require("./data-handle");
const { AppHandle, setCallbackErrorReporter } = require("./app-handle");
const { LingoFuseCallError } = require("./errors");

// ============================================================================
// Callback error reporting
// ============================================================================

/**
 * The native function table, resolved lazily on first use.
 * @type {object|null}
 */
let _funcs = null;

/**
 * Returns the native function table, resolving it on first call.
 *
 * @returns {object}
 */
function funcs() {
    if (_funcs === null) {
        _funcs = getBinding().funcs;
    }
    return _funcs;
}

/**
 * Optional handler invoked when a user callback raises an unhandled
 * exception. The first argument is a short identifier for the callback
 * site (for example "AppHandle.registerCall[add]" or
 * "NetworkEvents.connect"); the second is the value the callback threw,
 * which may be an Error or any other JavaScript value.
 *
 * Setting this property is optional. When it is null, swallowed
 * exceptions are still reported through stderr, but no application
 * level sink receives them.
 *
 * An exception raised by the handler itself is swallowed by the
 * framework, so a broken logging pipeline cannot destabilise a native
 * worker thread.
 *
 * @type {((source: string, err: *) => void) | null}
 */
let callbackErrorHandler = null;

/**
 * Installs a callback error handler. Passing null removes the handler.
 *
 * @param {((source: string, err: *) => void) | null} fn
 */
function setCallbackErrorHandler(fn) {
    if (fn !== null && typeof fn !== "function") {
        throw new TypeError(
            "setCallbackErrorHandler: fn must be a function or null."
        );
    }
    callbackErrorHandler = fn;
}

/**
 * Internal bridge used by AppHandle and NetworkEvents to report a
 * swallowed callback exception. Installed on app-handle.js at module
 * load time (see the install at the bottom of this file).
 *
 * @param {string} source
 * @param {*} err
 */
function reportCallbackError(source, err) {
    if (callbackErrorHandler) {
        try {
            callbackErrorHandler(source, err);
        } catch (_) {
            // A handler that throws must not be allowed to escape into
            // the native worker thread. Drop the secondary failure.
        }
    }

    // Always write to stderr as well. This gives every swallowed
    // exception a default visible sink without requiring the
    // application to install a handler.
    try {
        const detail =
            err instanceof Error
                ? err.stack ?? err.message
                : String(err);
        process.stderr.write(
            `[LingoFuse] Callback error in ${source}: ${detail}\n`
        );
    } catch (_) {
        // Even stderr may be unavailable in some embeddings. Ignore.
    }
}

// Install the reporter on app-handle.js. This must happen at module
// load time so that any callback registered through AppHandle after
// this point routes through the framework's handler.
setCallbackErrorReporter(reportCallbackError);

// ============================================================================
// Numeric helpers
// ============================================================================

/**
 * Normalise a timeout argument to BigInt for the uint64 native
 * parameter.
 *
 * @param {number|bigint} value
 * @returns {bigint}
 * @throws {RangeError} When the value is negative or exceeds 2^64 - 1.
 */
function normaliseTimeout(value) {
    let v;
    if (typeof value === "bigint") {
        v = value;
    } else if (typeof value === "number" && Number.isFinite(value)) {
        if (!Number.isInteger(value)) {
            throw new RangeError(
                "Timeout must be an integer number of milliseconds."
            );
        }
        v = BigInt(value);
    } else {
        throw new TypeError(
            "Timeout must be a number or a BigInt."
        );
    }

    if (v < 0n) {
        throw new RangeError("Timeout must be non-negative.");
    }
    const UINT64_MAX = (1n << 64n) - 1n;
    if (v > UINT64_MAX) {
        throw new RangeError("Timeout exceeds the 64-bit unsigned range.");
    }
    return v;
}

// ============================================================================
// Network preparation
// ============================================================================

/**
 * Clears any previously prepared services and clients. Running
 * services and clients are not affected.
 */
function resetPrepare() {
    funcs().LF_ResetPrepare();
}

/**
 * Prepares a C4 service listening on `listeningAddr` and advertised as
 * `physicsAddr`.
 *
 * @param {string} listeningAddr
 *   Local binding address, for example "0.0.0.0:9898" or
 *   "ipc:my_service".
 * @param {string} physicsAddr
 *   Address advertised to clients.
 * @returns {number}
 *   An internal tag on success, or -1 for a duplicate address.
 * @throws {TypeError} When either argument is not a string.
 */
function prepareService(listeningAddr, physicsAddr) {
    if (typeof listeningAddr !== "string") {
        throw new TypeError(
            "prepareService: listeningAddr must be a string."
        );
    }
    if (typeof physicsAddr !== "string") {
        throw new TypeError(
            "prepareService: physicsAddr must be a string."
        );
    }
    return funcs().LF_PrepareService(listeningAddr, physicsAddr);
}

/**
 * Prepares a C4 client connecting to `physicsAddr` and, optionally,
 * exposing `app` on the mesh.
 *
 * @param {string} physicsAddr
 *   Address of the target service.
 * @param {AppHandle|null} [app=null]
 *   Application to expose, or null for a pure consumer. When provided,
 *   the AppHandle must not be disposed.
 * @returns {number}
 *   An internal tag on success, or -1 for a duplicate address (unless
 *   Overlap_Connection is enabled via setOption()).
 * @throws {TypeError} When physicsAddr is not a string, or app is
 *   neither null nor an AppHandle.
 */
function prepareClient(physicsAddr, app = null) {
    if (typeof physicsAddr !== "string") {
        throw new TypeError(
            "prepareClient: physicsAddr must be a string."
        );
    }
    if (app !== null && !(app instanceof AppHandle)) {
        throw new TypeError(
            "prepareClient: app must be an AppHandle or null."
        );
    }

    const rawApp = app === null ? null : app.raw;
    return funcs().LF_PrepareClient(physicsAddr, rawApp);
}

/**
 * Starts the LingoFuse framework with all prepared services and
 * clients.
 *
 * @returns {number}
 *   1 on success. Returns 0 on a second call in the same process
 *   without an intervening shutdown(), which is not a failure.
 */
function prepareDone() {
    return funcs().LF_PrepareDone();
}

/**
 * Requests the simulated main thread to exit. Does not release all
 * resources; call shutdown() afterwards for a full cleanup.
 */
function exitMainThread() {
    funcs().LF_ExitMainThread();
}

// ============================================================================
// Runtime options
// ============================================================================

/**
 * Adjusts a global runtime option. Unknown option names are silently
 * ignored by the native layer.
 *
 * @param {string} option
 *   Option name, for example "Overlap_Connection".
 * @param {string} value
 *   New value, for example "True".
 * @throws {TypeError} When either argument is not a string.
 */
function setOption(option, value) {
    if (typeof option !== "string") {
        throw new TypeError("setOption: option must be a string.");
    }
    if (typeof value !== "string") {
        throw new TypeError("setOption: value must be a string.");
    }
    funcs().LF_SetOption(option, value);
}

// ============================================================================
// Application name generation
// ============================================================================

/**
 * Generates a globally unique application name.
 *
 * Must be called after prepareDone() returns 1. The native function
 * returns a pointer that is valid for approximately 5 seconds; Koffi
 * copies the string to a JavaScript string immediately.
 *
 * Returns an empty string when the underlying native function returns
 * a null pointer.
 *
 * @returns {string}
 */
function generateAppName() {
    const name = funcs().LF_Generate_AppName();
    return typeof name === "string" ? name : "";
}

// ============================================================================
// Remote invocation
// ============================================================================

/**
 * Performs a synchronous remote call and returns the response.
 *
 * @param {string} appName
 *   Target application name.
 * @param {DataHandle} param
 *   Request data handle. The handle is not consumed by this call; the
 *   caller retains ownership.
 * @param {number|bigint} [timeoutMs=5000]
 *   Timeout in milliseconds. Zero means "wait indefinitely".
 * @returns {DataHandle}
 *   A new DataHandle owning the response. On timeout or failure the
 *   native side returns an empty handle (size 0). The result is never
 *   null; the caller must dispose it.
 * @throws {TypeError} When appName is not a string, or param is not a
 *   DataHandle.
 * @throws {RangeError} When timeoutMs is negative or out of range.
 */
function call(appName, param, timeoutMs = 5000) {
    if (typeof appName !== "string") {
        throw new TypeError("call: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("call: param must be a DataHandle.");
    }
    const timeout = normaliseTimeout(timeoutMs);

    const result = funcs().LF_Call(appName, param.raw, timeout);
    if (result === null || result === undefined) {
        // The native ABI documents that LF_Call never returns NULL;
        // it returns an empty handle instead. A null pointer here
        // means a deeper transport failure.
        throw new LingoFuseCallError(
            "LF_Call returned a null handle.",
            { targetApp: appName, targetApi: null }
        );
    }
    return DataHandle.fromRaw(result, true);
}

/**
 * Sends a one-way Notify. Delivery order is not guaranteed; use
 * sequencedNotify() when FIFO ordering is required.
 *
 * @param {string} appName
 * @param {DataHandle} param
 * @throws {TypeError} When appName is not a string, or param is not a
 *   DataHandle.
 */
function notify(appName, param) {
    if (typeof appName !== "string") {
        throw new TypeError("notify: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("notify: param must be a DataHandle.");
    }
    funcs().LF_Notify(appName, param.raw);
}

/**
 * Sends a one-way notification with FIFO ordering guaranteed for the
 * same (application, API) pair.
 *
 * @param {string} appName
 * @param {DataHandle} param
 * @throws {TypeError} When appName is not a string, or param is not a
 *   DataHandle.
 */
function sequencedNotify(appName, param) {
    if (typeof appName !== "string") {
        throw new TypeError("sequencedNotify: appName must be a string.");
    }
    if (!(param instanceof DataHandle)) {
        throw new TypeError("sequencedNotify: param must be a DataHandle.");
    }
    funcs().LF_Sequenced_Notify(appName, param.raw);
}

// ============================================================================
// Shutdown
// ============================================================================

/**
 * Gracefully terminates the framework, releasing all resources.
 * Safe to call multiple times.
 *
 * Every AppHandle still alive in the process becomes invalid after this
 * call. The AppHandle wrappers do not detect this automatically;
 * callers must ensure that no AppHandle is used after shutdown() has
 * returned.
 */
function shutdown() {
    funcs().LF_Shutdown();
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
    // Callback error reporting
    setCallbackErrorHandler,
    get callbackErrorHandler() {
        return callbackErrorHandler;
    },

    // Network preparation
    resetPrepare,
    prepareService,
    prepareClient,
    prepareDone,
    exitMainThread,

    // Runtime options
    setOption,

    // Application name
    generateAppName,

    // Remote invocation
    call,
    notify,
    sequencedNotify,

    // Shutdown
    shutdown,
};