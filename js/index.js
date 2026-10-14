/**
 * @file index.js
 * @brief Public entry point for the LingoFuse JavaScript binding.
 *
 * This module is the single import surface for applications. It
 * re-exports every public symbol from the lower layers.
 *
 * ============================================================================
 * NAMESPACE LAYOUT
 * ============================================================================
 *   lf.DataHandle          - RAII wrapper for a data buffer
 *   lf.AppHandle           - RAII wrapper for an application
 *   lf.io.*                - JSON / string / byte I/O
 *   lf.framework.*         - process-wide ABI facade
 *   lf.network.*           - network event handlers
 *   lf.status.*            - status queue and health checks
 *   lf.options.*           - typed runtime options
 *   lf.address.*           - three-addressing Target abstraction
 *   lf.async.*             - AsyncBridge, AsyncOp, CallPromise
 *
 * Top-level convenience exports:
 *   lf.AppTarget / lf.UIDTarget / lf.P2PNameTarget
 *   lf.CallPromise / lf.AsyncBridge
 *   lf.registerP2PCall / lf.registerP2PNotify / lf.unregisterP2P
 *
 * All comments and docstrings are in English.
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
const options = require("./options");
const address = require("./address");
const asyncSupport = require("./async-support");

// Process-wide P2P registration helpers live at this level (not on
// AppHandle) because they are process-scoped, not App-scoped.
const {
    registerP2PCall,
    registerP2PNotify,
    unregisterP2P,
} = require("./p2p-registration");

// ---------------------------------------------------------------------------
// Version
// ---------------------------------------------------------------------------

/**
 * Version of the JavaScript binding itself. This is NOT the version of
 * the native LingoFuse runtime.
 *
 * @type {string}
 */
const VERSION = "2.0.0";

// ---------------------------------------------------------------------------
// Lifecycle helpers
// ---------------------------------------------------------------------------

/**
 * Eagerly triggers the lazy load of the native LingoFuse library.
 *
 * @returns {boolean}
 * @throws {import('./errors').LingoFuseLibraryLoadError}
 */
function loadLibrary() {
    try {
        binding.getBinding();
        return true;
    } catch (err) {
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
 * Returns the platform-specific library file name.
 *
 * @returns {string}
 */
function libraryName() {
    return binding.selectPlatformFileName();
}

/**
 * Returns a short description of the current runtime.
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
    options,
    address,
    async: asyncSupport,

    // ------------------------------------------------------------------
    // Addressing shortcuts (top-level convenience)
    // ------------------------------------------------------------------
    AppTarget: address.AppTarget,
    UIDTarget: address.UIDTarget,
    P2PNameTarget: address.P2PNameTarget,
    CallPromise: asyncSupport.CallPromise,
    AsyncBridge: asyncSupport.AsyncBridge,

    // ------------------------------------------------------------------
    // Process-wide P2P registration
    // ------------------------------------------------------------------
    registerP2PCall,
    registerP2PNotify,
    unregisterP2P,

    // ------------------------------------------------------------------
    // Exceptions (re-exported for convenience)
    // ------------------------------------------------------------------
    LingoFuseError: errors.LingoFuseError,
    LingoFuseLibraryLoadError: errors.LingoFuseLibraryLoadError,
    LingoFuseCallError: errors.LingoFuseCallError,
    LingoFuseTimeoutError: errors.LingoFuseTimeoutError,
    LingoFuseIoError: errors.LingoFuseIoError,
    LingoFuseObjectDisposedError: errors.LingoFuseObjectDisposedError,
    LingoFuseCallbackError: errors.LingoFuseCallbackError,
    LingoFuseRegistrationError: errors.LingoFuseRegistrationError,

    // ------------------------------------------------------------------
    // Advanced / low-level escape hatches
    // ------------------------------------------------------------------
    _binding: binding,
};