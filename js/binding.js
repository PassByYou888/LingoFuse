/**
 * @file binding.js
 * @brief Low-level native binding layer for the LingoFuse C ABI using Koffi.
 *
 * This module is the ONLY place in the JavaScript binding where native
 * code is invoked. Every higher-level wrapper goes through the functions
 * declared here. It mirrors the role of `NativeMethods.cs` in the C#
 * binding and the function-pointer table in `LingoFuse.c`.
 *
 * ============================================================================
 * RESPONSIBILITY
 * ============================================================================
 *   1. Locate and load the platform-specific LingoFuse shared library.
 *   2. Declare all 37 exported C functions with correct signatures.
 *   3. Provide opaque handle types (DataHnd, AppHnd).
 *   4. Declare callback prototypes for Call, Notify, and Network events.
 *   5. Expose a clean, synchronous API surface for the RAII layer.
 *
 * ============================================================================
 * CALLING CONVENTION
 * ============================================================================
 * All exported functions use the C calling convention (cdecl). Koffi uses
 * cdecl by default, so no explicit convention annotation is required.
 *
 * ============================================================================
 * STRING ENCODING
 * ============================================================================
 * Every string parameter is a UTF-8, NUL-terminated C string (const char*).
 * Koffi's `str` type handles the conversion automatically: JavaScript
 * strings are encoded to UTF-8 on the way in, and decoded from UTF-8 on
 * the way out.
 *
 * ============================================================================
 * PLATFORM LIBRARY NAMES
 * ============================================================================
 *   Windows 64-bit  ->  LingoFuse64.dll
 *   Windows 32-bit  ->  LingoFuse32.dll
 *   Linux / BSD     ->  liblingofuse.so
 *   macOS           ->  liblingofuse.dylib
 *
 * ============================================================================
 * PORTABILITY
 * ============================================================================
 * This module is designed to run on Node.js, Deno (2.x), and Bun.
 *
 *   - `process.platform` and `process.arch` are read defensively; both
 *     Deno 2.x and Bun provide a Node-compatible `process` shim.
 *
 *   - `process.execPath` and `process.cwd()` are guarded by type checks
 *     because they may be missing or behave differently in restricted
 *     embedded environments.
 *
 *   - `__dirname` is guarded by a type check because this file is
 *     currently shipped as CommonJS. If the file is ever converted to
 *     ESM, the `__dirname` branch is silently skipped and the caller
 *     must supply the native library via one of the other search paths
 *     or via the system loader.
 *
 *   - `require("koffi")` works on Node and Bun directly. On Deno it
 *     works only when the package is loaded through the npm: specifier
 *     (for example `import lf from "npm:lingofuse-js"`), which makes
 *     Deno's npm compatibility layer provide a CommonJS `require`.
 *
 * See PORTABILITY.md for the full set of usage recommendations.
 *
 * ============================================================================
 * CALLBACK LIFETIME
 * ============================================================================
 * Koffi distinguishes between transient and registered callbacks. LingoFuse
 * callbacks (Call, Notify, Network events) are invoked by native worker
 * threads at arbitrary times after registration. They MUST be registered
 * callbacks (`koffi.register`) to remain valid. The higher-level wrappers
 * in this package manage registration and unregistration.
 *
 * ============================================================================
 * BYTE BUFFER PARAMETERS
 * ============================================================================
 * The native LF_WriteBuffer / LF_ReadBuffer parameters are declared as
 * `const void*` / `void*` in C. In this Koffi binding they are declared
 * as `uint8_t*` so that Koffi accepts and returns `Uint8Array` values
 * directly. The native function is unaffected by this choice: it sees
 * the same pointer either way. Declaring the parameter as `void*` would
 * force the caller to pass raw addresses, which Koffi does not accept
 * for a `Uint8Array`.
 *
 * ============================================================================
 * THREAD SAFETY
 * ============================================================================
 * The native library is thread-safe. However, a single DataHnd must not be
 * written concurrently from multiple JavaScript threads. The RAII layer
 * documents the serialisation contract.
 *
 * ============================================================================
 */

"use strict";

const koffi = require("koffi");
const path = require("path");
const fs = require("fs");

// ============================================================================
// Platform detection
// ============================================================================

/**
 * Returns the platform-specific shared library file name.
 *
 * `process.platform` and `process.arch` are read defensively: on
 * Node.js, Deno 2.x, and Bun they are available; on a hypothetical
 * future runtime that lacks them, the function falls back to a
 * conservative default.
 *
 * @returns {string} The library file name (e.g. "LingoFuse64.dll").
 */
function selectPlatformFileName() {
  const platform =
    (typeof process !== "undefined" && process.platform) || "linux";
  const arch =
    (typeof process !== "undefined" && process.arch) || "x64";

  if (platform === "win32") {
    return arch === "x64" ? "LingoFuse64.dll" : "LingoFuse32.dll";
  }
  if (platform === "darwin") {
    return "liblingofuse.dylib";
  }
  // Linux, BSD, and any other ELF-based system.
  return "liblingofuse.so";
}

/**
 * Returns a list of candidate search paths for the shared library.
 *
 * Resolution order:
 *   1. The directory containing the current executable.
 *   2. The current working directory.
 *   3. The package's own native/ directory (for bundled deployments).
 *
 * Every branch is defensive: a runtime that lacks `process.execPath`,
 * `process.cwd`, or `__dirname` simply skips that candidate and moves
 * on. The final fallback in loadLibrary() is to ask the system loader
 * to resolve the bare library name, which covers PATH on Windows,
 * LD_LIBRARY_PATH on Linux, and DYLD_LIBRARY_PATH on macOS.
 *
 * @returns {string[]} An ordered list of absolute file paths to try.
 */
function buildSearchPaths() {
  const fileName = selectPlatformFileName();
  const candidates = [];

  // 1. Next to the executable.
  try {
    if (
      typeof process !== "undefined" &&
      typeof process.execPath === "string" &&
      process.execPath.length > 0
    ) {
      candidates.push(path.join(path.dirname(process.execPath), fileName));
    }
  } catch (_) {
    // process.execPath may be unavailable in exotic embeddings.
  }

  // 2. Current working directory.
  try {
    if (
      typeof process !== "undefined" &&
      typeof process.cwd === "function"
    ) {
      candidates.push(path.join(process.cwd(), fileName));
    }
  } catch (_) {
    // process.cwd may be unavailable or may throw in restricted sandboxes.
  }

  // 3. Package-local native/ directory.
  //
  // __dirname is available in CommonJS. The binding is currently
  // shipped as CommonJS, so this branch is reliable on Node and Bun.
  // It is guarded with a type check so that a future conversion to
  // ESM does not break this function: in ESM, __dirname is undefined
  // and this candidate is silently skipped.
  if (typeof __dirname === "string" && __dirname.length > 0) {
    candidates.push(path.join(__dirname, "..", "native", fileName));
  }

  return candidates;
}

// ============================================================================
// Library loading
// ============================================================================

/**
 * The loaded Koffi library object.
 * @type {object|null}
 */
let lib = null;

/**
 * Loads the LingoFuse shared library.
 *
 * @returns {object} The Koffi library object.
 * @throws {Error} If the library cannot be found or loaded.
 */
function loadLibrary() {
  if (lib) {
    return lib;
  }

  const candidates = buildSearchPaths();
  const errors = [];

  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) {
        lib = koffi.load(candidate);
        return lib;
      }
    } catch (err) {
      errors.push(`${candidate}: ${err.message}`);
    }
  }

  // Final attempt: let the system loader resolve the bare file name.
  const bareName = selectPlatformFileName();
  try {
    lib = koffi.load(bareName);
    return lib;
  } catch (err) {
    errors.push(`${bareName}: ${err.message}`);
  }

  throw new Error(
    `Failed to load the LingoFuse native library.\n` +
    `Tried:\n` +
    errors.map((e) => `  - ${e}`).join("\n") +
    `\nPlace the library next to the executable, in the current ` +
    `working directory, in a ./native/ subdirectory, or on the system ` +
    `loader search path (PATH on Windows, LD_LIBRARY_PATH on Linux, ` +
    `DYLD_LIBRARY_PATH on macOS).`
  );
}

// ============================================================================
// Opaque handle types
// ============================================================================

/**
 * Opaque handle to a LingoFuse data buffer (TDataHnd).
 *
 * Never dereference this pointer. All access goes through the exported
 * LF_* functions.
 */
const DataHnd = koffi.pointer("DataHnd", koffi.opaque());

/**
 * Opaque handle to a LingoFuse application (TAppHnd).
 *
 * Never dereference this pointer. All access goes through the exported
 * LF_* functions.
 */
const AppHnd = koffi.pointer("AppHnd", koffi.opaque());

// ============================================================================
// Callback prototypes
// ============================================================================

/**
 * Callback prototype for Call-mode (request-response) APIs.
 *
 * @param trigger  User-supplied pointer passed at registration time.
 * @param input    Read-only input data handle.
 * @param output   Writable output data handle.
 */
const LfCallFunc = koffi.proto(
  "LfCallFunc",
  "void",
  [koffi.pointer("void"), DataHnd, DataHnd]
);

/**
 * Callback prototype for Notify-mode (one-way) APIs.
 *
 * @param trigger  User-supplied pointer passed at registration time.
 * @param input    Read-only input data handle.
 */
const LfNotifyFunc = koffi.proto(
  "LfNotifyFunc",
  "void",
  [koffi.pointer("void"), DataHnd]
);

/**
 * Callback prototype for network connect/disconnect events.
 *
 * @param addr  UTF-8 endpoint string. Valid ONLY during the callback
 *              invocation; copy the string immediately if you need it.
 */
const LfNetworkEventFunc = koffi.proto(
  "LfNetworkEventFunc",
  "void",
  ["str"]
);

// ============================================================================
// Function declarations
// ============================================================================

/**
 * Declares all 37 exported LingoFuse functions and returns an object
 * holding them.
 *
 * @param {object} library  The Koffi library object.
 * @returns {object} An object whose properties are the declared functions.
 */
function declareFunctions(library) {
  const f = {};

  // --------------------------------------------------------------------
  // Data handle operations (10)
  // --------------------------------------------------------------------

  /**
   * LF_CreateData
   * Creates a new AUTO-RECYCLED data handle bound to the given API
   * name. The handle is added to the library's idle pool; the pool
   * scans every 5 seconds and frees any handle that has been idle for
   * more than 10 minutes.
   */
  f.LF_CreateData = library.func("LF_CreateData", DataHnd, ["str"]);

  /**
   * LF_CreateData_Permanent
   * Creates a new PERMANENT data handle bound to the given API name.
   *
   * Difference from LF_CreateData:
   *   - NOT added to the library's idle pool.
   *   - The automatic idle-timeout reclaimer will NEVER free it.
   *   - LF_FreeData releases it synchronously.
   *
   * Use this for handles that must survive for the entire process
   * lifetime (cached templates, long-lived scratch buffers, global
   * registries). Do NOT use it for short-lived handles; the pool
   * safety net is lost.
   *
   * [PITFALL - NO-OP WINDOW]
   *   LF_FreeData is a no-op while the simulated main thread is not
   *   active (before LF_PrepareDone or after LF_ExitMainThread).
   *   Permanent handles created in that window stay allocated until
   *   the process terminates. LF_Shutdown releases any permanent
   *   handle still alive at teardown.
   */
  f.LF_CreateData_Permanent = library.func(
    "LF_CreateData_Permanent",
    DataHnd,
    ["str"]
  );

  /**
   * LF_FreeData
   * Releases a data handle. Passing a null handle is safe and ignored.
   *
   * For an auto-recycled handle this only marks the handle as deleted;
   * the actual release happens on the next pool scan (at most 5
   * seconds later). For a permanent handle the release is synchronous.
   *
   * [PITFALL] This call is a NO-OP while the simulated main thread is
   * not active. Permanent handles created in that window stay
   * allocated until the process terminates or LF_Shutdown runs.
   */
  f.LF_FreeData = library.func("LF_FreeData", "void", [DataHnd]);

  f.LF_GetBuffer = library.func("LF_GetBuffer", koffi.pointer("void"), [DataHnd]);
  f.LF_WriteBuffer = library.func("LF_WriteBuffer", "int64", [
    DataHnd,
    koffi.pointer("uint8_t"),
    "int64",
  ]);
  f.LF_ReadBuffer = library.func("LF_ReadBuffer", "int64", [
    DataHnd,
    koffi.pointer("uint8_t"),
    "int64",
  ]);
  f.LF_GetPos = library.func("LF_GetPos", "int64", [DataHnd]);
  f.LF_SetPos = library.func("LF_SetPos", "void", [DataHnd, "int64"]);
  f.LF_GetSize = library.func("LF_GetSize", "int64", [DataHnd]);
  f.LF_SetSize = library.func("LF_SetSize", "void", [DataHnd, "int64"]);

  // --------------------------------------------------------------------
  // Application handle operations (5)
  // --------------------------------------------------------------------

  f.LF_CreateApp = library.func("LF_CreateApp", AppHnd, ["str", "str"]);
  f.LF_FreeApp = library.func("LF_FreeApp", "void", [AppHnd]);

  /**
   * LF_Generate_AppName
   * Returns a pointer to a temporary buffer valid for ~5 seconds.
   * Koffi copies the string immediately into a JavaScript string.
   */
  f.LF_Generate_AppName = library.func("LF_Generate_AppName", "str", []);

  /**
   * LF_Get_AppName
   * Same 5-second validity rule as LF_Generate_AppName.
   */
  f.LF_Get_AppName = library.func("LF_Get_AppName", "str", [AppHnd]);

  f.LF_BindApp = library.func("LF_BindApp", "int", [AppHnd]);

  // --------------------------------------------------------------------
  // API registration (3)
  // --------------------------------------------------------------------

  f.LF_RegisterCall = library.func("LF_RegisterCall", "int", [
    AppHnd,
    "str",
    "str",
    koffi.pointer("void"),
    koffi.pointer(LfCallFunc),
  ]);
  f.LF_RegisterNotify = library.func("LF_RegisterNotify", "int", [
    AppHnd,
    "str",
    "str",
    koffi.pointer("void"),
    koffi.pointer(LfNotifyFunc),
  ]);
  f.LF_Unregister = library.func("LF_Unregister", "int", [AppHnd, "str"]);

  // --------------------------------------------------------------------
  // Local execution (2)
  // --------------------------------------------------------------------

  f.LF_LocalCall = library.func("LF_LocalCall", DataHnd, [AppHnd, DataHnd]);
  f.LF_LocalNotify = library.func("LF_LocalNotify", "void", [AppHnd, DataHnd]);

  // --------------------------------------------------------------------
  // Network preparation (5)
  // --------------------------------------------------------------------

  f.LF_ResetPrepare = library.func("LF_ResetPrepare", "void", []);
  f.LF_PrepareService = library.func("LF_PrepareService", "int", [
    "str",
    "str",
  ]);
  f.LF_PrepareClient = library.func("LF_PrepareClient", "int", [
    "str",
    AppHnd,
  ]);
  f.LF_PrepareDone = library.func("LF_PrepareDone", "int", []);
  f.LF_ExitMainThread = library.func("LF_ExitMainThread", "void", []);

  // --------------------------------------------------------------------
  // Remote invocation (3)
  // --------------------------------------------------------------------

  f.LF_Call = library.func("LF_Call", DataHnd, [
    "str",
    DataHnd,
    "uint64",
  ]);
  f.LF_Notify = library.func("LF_Notify", "void", ["str", DataHnd]);
  f.LF_Sequenced_Notify = library.func("LF_Sequenced_Notify", "void", [
    "str",
    DataHnd,
  ]);

  // --------------------------------------------------------------------
  // Options and diagnostics (7)
  // --------------------------------------------------------------------

  f.LF_SetOption = library.func("LF_SetOption", "void", ["str", "str"]);
  f.LF_GetStatusCount = library.func("LF_GetStatusCount", "int", []);
  f.LF_GetStatus = library.func("LF_GetStatus", "str", []);

  /**
   * LF_PostStatus
   * Injects a custom log message into the status queue.
   *
   * The message is queued even when the simulated main thread is not
   * running. The queue is bounded at 1000 entries; older entries are
   * dropped when the buffer is full.
   */
  f.LF_PostStatus = library.func("LF_PostStatus", "void", ["str"]);

  f.LF_CheckMainThread = library.func("LF_CheckMainThread", "int", []);
  f.LF_CheckApp = library.func("LF_CheckApp", "int", ["str"]);
  f.LF_CheckApi = library.func("LF_CheckApi", "int", ["str", "str"]);

  // --------------------------------------------------------------------
  // Shutdown (1)
  // --------------------------------------------------------------------

  f.LF_Shutdown = library.func("LF_Shutdown", "void", []);

  // --------------------------------------------------------------------
  // Network events (1)
  // --------------------------------------------------------------------

  f.LF_Set_Network_Event = library.func("LF_Set_Network_Event", "void", [
    koffi.pointer(LfNetworkEventFunc),
    koffi.pointer(LfNetworkEventFunc),
  ]);

  return f;
}

// ============================================================================
// Public API
// ============================================================================

/**
 * The singleton binding instance. Lazily initialised on first access.
 */
let _instance = null;

/**
 * Returns the binding instance, loading the native library and declaring
 * all functions on first call.
 *
 * @returns {{
 *   koffi: object,
 *   types: { DataHnd: object, AppHnd: object },
 *   callbacks: {
 *     LfCallFunc: object,
 *     LfNotifyFunc: object,
 *     LfNetworkEventFunc: object
 *   },
 *   funcs: object,
 *   platform: string,
 *   libraryName: string
 * }}
 */
function getBinding() {
  if (_instance) {
    return _instance;
  }

  const library = loadLibrary();
  const funcs = declareFunctions(library);

  _instance = Object.freeze({
    koffi,
    types: Object.freeze({
      DataHnd,
      AppHnd,
    }),
    callbacks: Object.freeze({
      LfCallFunc,
      LfNotifyFunc,
      LfNetworkEventFunc,
    }),
    funcs: Object.freeze(funcs),
    platform:
      (typeof process !== "undefined" && process.platform) || "unknown",
    libraryName: selectPlatformFileName(),
  });

  return _instance;
}

/**
 * Returns true when the native binding has been successfully loaded.
 *
 * @returns {boolean}
 */
function isLoaded() {
  return _instance !== null;
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
  getBinding,
  isLoaded,
  selectPlatformFileName,
  buildSearchPaths,
  // Expose the raw Koffi module for advanced use cases (e.g. custom types).
  koffi,
  // Expose type constructors for the higher-level layers.
  DataHnd,
  AppHnd,
  LfCallFunc,
  LfNotifyFunc,
  LfNetworkEventFunc,
};