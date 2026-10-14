/**
 * @file binding.js
 * @brief Low-level native binding layer for the LingoFuse C ABI using Koffi.
 *
 * This module is the ONLY place in the JavaScript binding where native
 * code is invoked. Every higher-level wrapper goes through the functions
 * declared here.
 *
 * ============================================================================
 * RESPONSIBILITY
 * ============================================================================
 *   1. Locate and load the platform-specific LingoFuse shared library.
 *   2. Declare all 59 exported C functions with correct signatures.
 *   3. Provide opaque handle types (DataHnd, AppHnd, TP2P_UID).
 *   4. Declare callback prototypes for Call, Notify, Network events,
 *      and asynchronous Call (LfAsyncCallOnResult).
 *   5. Expose a clean, synchronous API surface for the RAII layer.
 *
 * ============================================================================
 * UID TYPE - TWO DIFFERENT ROLES
 * ============================================================================
 * The Pascal-side type `TP2P_UID___` is `array[0..31] of Byte`. It
 * plays TWO different roles on the C ABI, and each role requires a
 * DIFFERENT Koffi-level representation:
 *
 *   ROLE 1 - ARGUMENT (input position):
 *       The Koffi type is `TP2P_UID` (a `uint8[32]` array).
 *
 *   ROLE 2 - RETURN VALUE (only LF_Get_P2P_UID):
 *       The Koffi type is `koffi.pointer("uint8")`. The pointer is
 *       allocated by the native side and released ~5 seconds later.
 *
 * DO NOT unify these two roles.
 *
 * All comments and docstrings are in English.
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
 * @returns {string}
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
  return "liblingofuse.so";
}

/**
 * Returns a list of candidate search paths for the shared library.
 *
 * @returns {string[]}
 */
function buildSearchPaths() {
  const fileName = selectPlatformFileName();
  const candidates = [];

  try {
    if (
      typeof process !== "undefined" &&
      typeof process.execPath === "string" &&
      process.execPath.length > 0
    ) {
      candidates.push(path.join(path.dirname(process.execPath), fileName));
    }
  } catch (_) {
    // process.execPath may be unavailable.
  }

  try {
    if (
      typeof process !== "undefined" &&
      typeof process.cwd === "function"
    ) {
      candidates.push(path.join(process.cwd(), fileName));
    }
  } catch (_) {
    // process.cwd may be unavailable.
  }

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
 * @returns {object}
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
 * Argument-role type: a 32-byte UID, passed by value in cdecl.
 *
 * {!!!!!  WHY A STRUCT, NOT A BARE ARRAY  !!!!!}
 * Koffi rejects `koffi.array("uint8", 32)` when it appears as a
 * function parameter type ("Type uint8_t[32] cannot be used as a
 * parameter"). The ABI-correct representation is a struct wrapping
 * the 32-byte array, exactly matching the C header:
 *
 *     typedef struct TP2P_UID_s {
 *         uint8_t bytes[32];
 *     } TP2P_UID;
 *
 * On x86-64 (SysV and Windows x64), a >16-byte aggregate is classified
 * MEMORY by the psABI and is passed on the stack. A Koffi struct with
 * a single fixed-size array member reproduces that layout exactly.
 *
 * Used as an ARGTYPES entry ONLY. Do NOT use this as the return type of
 * LF_Get_P2P_UID; that function returns a POINTER.
 */
const TP2P_UID = koffi.struct("TP2P_UID", {
  bytes: koffi.array("uint8", 32, "Typed"),
});

/**
 * Opaque handle to a LingoFuse data buffer (TDataHnd).
 */
const DataHnd = koffi.pointer("DataHnd", koffi.opaque());

/**
 * Opaque handle to a LingoFuse application (TAppHnd).
 */
const AppHnd = koffi.pointer("AppHnd", koffi.opaque());

// ============================================================================
// Callback prototypes
// ============================================================================

/**
 * Callback prototype for Call-mode (request-response) APIs.
 */
const LfCallFunc = koffi.proto(
  "LfCallFunc",
  "void",
  [koffi.pointer("void"), DataHnd, DataHnd]
);

/**
 * Callback prototype for Notify-mode (one-way) APIs.
 */
const LfNotifyFunc = koffi.proto(
  "LfNotifyFunc",
  "void",
  [koffi.pointer("void"), DataHnd]
);

/**
 * Callback prototype for network connect/disconnect events.
 */
const LfNetworkEventFunc = koffi.proto(
  "LfNetworkEventFunc",
  "void",
  ["str"]
);

/**
 * Callback prototype for the asynchronous remote invocation family.
 *
 * Parameters:
 *   - data   : the opaque pointer the caller passed at the call site.
 *   - result : a DataHnd OWNED BY THE FRAMEWORK. Released IMMEDIATELY
 *              after this callback returns. Do NOT call LF_FreeData
 *              on it, and do NOT retain the pointer past its own
 *              return.
 */
const LfAsyncCallOnResult = koffi.proto(
  "LfAsyncCallOnResult",
  "void",
  [koffi.pointer("void"), DataHnd]
);

// ============================================================================
// Function declarations
// ============================================================================

/**
 * Declares all 59 exported LingoFuse functions and returns an object
 * holding them.
 *
 * @param {object} library  The Koffi library object.
 * @returns {object}
 */
function declareFunctions(library) {
  const f = {};

  // --------------------------------------------------------------------
  // Data handle operations (12)
  // --------------------------------------------------------------------

  f.LF_CreateData = library.func("LF_CreateData", DataHnd, ["str"]);

  f.LF_CreateData_Permanent = library.func(
    "LF_CreateData_Permanent",
    DataHnd,
    ["str"]
  );

  f.LF_FreeData = library.func("LF_FreeData", "void", [DataHnd]);

  f.LF_GetBuffer = library.func(
    "LF_GetBuffer",
    koffi.pointer("void"),
    [DataHnd]
  );

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

  /**
   * LF_Get_P2P_UID
   * Reads the auto-injected sender UID ("side data") from an INPUT
   * data handle. Returns a POINTER to a 32-byte UID.
   */
  f.LF_Get_P2P_UID = library.func(
    "LF_Get_P2P_UID",
    koffi.pointer("uint8"),
    [DataHnd]
  );

  /**
   * LF_Get_P2P_Name
   * Reads the auto-injected sender P2P group name ("side data") from
   * an INPUT data handle.
   */
  f.LF_Get_P2P_Name = library.func(
    "LF_Get_P2P_Name",
    "str",
    [DataHnd]
  );

  // --------------------------------------------------------------------
  // Application handle operations (5)
  // --------------------------------------------------------------------

  f.LF_CreateApp = library.func("LF_CreateApp", AppHnd, ["str", "str"]);
  f.LF_FreeApp = library.func("LF_FreeApp", "void", [AppHnd]);
  f.LF_Generate_AppName = library.func("LF_Generate_AppName", "str", []);
  f.LF_Get_AppName = library.func("LF_Get_AppName", "str", [AppHnd]);
  f.LF_BindApp = library.func("LF_BindApp", "int", [AppHnd]);

  // --------------------------------------------------------------------
  // API registration, app-bound (3)
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
  // API registration, process-wide P2P (3)
  // --------------------------------------------------------------------

  f.LF_Register_P2P_Call = library.func(
    "LF_Register_P2P_Call",
    "int",
    ["str", "str", koffi.pointer("void"), koffi.pointer(LfCallFunc)]
  );

  f.LF_Register_P2P_Notify = library.func(
    "LF_Register_P2P_Notify",
    "int",
    ["str", "str", koffi.pointer("void"), koffi.pointer(LfNotifyFunc)]
  );

  f.LF_Unregister_P2P = library.func(
    "LF_Unregister_P2P",
    "int",
    ["str"]
  );

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
  // Remote invocation by App name (5)
  // --------------------------------------------------------------------

  f.LF_Call = library.func("LF_Call", DataHnd, [
    "str",
    DataHnd,
    "uint64",
  ]);

  f.LF_Async_Call = library.func("LF_Async_Call", "int", [
    "str",
    DataHnd,
    koffi.pointer("void"),
    koffi.pointer(LfAsyncCallOnResult),
  ]);

  f.LF_Async_Sequenced_Call = library.func(
    "LF_Async_Sequenced_Call",
    "int",
    [
      "str",
      DataHnd,
      koffi.pointer("void"),
      koffi.pointer(LfAsyncCallOnResult),
    ]
  );

  f.LF_Notify = library.func("LF_Notify", "void", ["str", DataHnd]);
  f.LF_Sequenced_Notify = library.func("LF_Sequenced_Notify", "void", [
    "str",
    DataHnd,
  ]);

  // --------------------------------------------------------------------
  // Remote invocation by UID (5)
  // --------------------------------------------------------------------

  f.LF_UID_Call = library.func("LF_UID_Call", DataHnd, [
    TP2P_UID,
    DataHnd,
    "uint64",
  ]);

  f.LF_UID_Async_Call = library.func("LF_UID_Async_Call", "int", [
    TP2P_UID,
    DataHnd,
    koffi.pointer("void"),
    koffi.pointer(LfAsyncCallOnResult),
  ]);

  f.LF_UID_Async_Sequenced_Call = library.func(
    "LF_UID_Async_Sequenced_Call",
    "int",
    [
      TP2P_UID,
      DataHnd,
      koffi.pointer("void"),
      koffi.pointer(LfAsyncCallOnResult),
    ]
  );

  f.LF_UID_Notify = library.func("LF_UID_Notify", "void", [
    TP2P_UID,
    DataHnd,
  ]);

  f.LF_UID_Sequenced_Notify = library.func(
    "LF_UID_Sequenced_Notify",
    "void",
    [TP2P_UID, DataHnd]
  );

  // --------------------------------------------------------------------
  // Remote invocation by P2P name (5)
  // --------------------------------------------------------------------

  f.LF_P2PNAME_Call = library.func("LF_P2PNAME_Call", DataHnd, [
    "str",
    DataHnd,
    "uint64",
  ]);

  f.LF_P2PNAME_Async_Call = library.func(
    "LF_P2PNAME_Async_Call",
    "int",
    [
      "str",
      DataHnd,
      koffi.pointer("void"),
      koffi.pointer(LfAsyncCallOnResult),
    ]
  );

  f.LF_P2PNAME_Async_Sequenced_Call = library.func(
    "LF_P2PNAME_Async_Sequenced_Call",
    "int",
    [
      "str",
      DataHnd,
      koffi.pointer("void"),
      koffi.pointer(LfAsyncCallOnResult),
    ]
  );

  f.LF_P2PNAME_Notify = library.func("LF_P2PNAME_Notify", "void", [
    "str",
    DataHnd,
  ]);

  f.LF_P2PNAME_Sequenced_Notify = library.func(
    "LF_P2PNAME_Sequenced_Notify",
    "void",
    ["str", DataHnd]
  );

  // --------------------------------------------------------------------
  // Options and diagnostics (8)
  // --------------------------------------------------------------------

  f.LF_SetOption = library.func("LF_SetOption", "void", ["str", "str"]);

  f.LF_GetOption = library.func("LF_GetOption", "str", ["str"]);

  f.LF_GetStatusCount = library.func("LF_GetStatusCount", "int", []);
  f.LF_GetStatus = library.func("LF_GetStatus", "str", []);
  f.LF_PostStatus = library.func("LF_PostStatus", "void", ["str"]);
  f.LF_CheckMainThread = library.func("LF_CheckMainThread", "int", []);
  f.LF_CheckApp = library.func("LF_CheckApp", "int", ["str"]);
  f.LF_CheckApi = library.func("LF_CheckApi", "int", ["str", "str"]);

  f.LF_Check_UID = library.func("LF_Check_UID", "int", [TP2P_UID]);

  f.LF_Check_UID_Api = library.func("LF_Check_UID_Api", "int", [
    TP2P_UID,
    "str",
  ]);

  f.LF_Check_P2PNAME = library.func(
    "LF_Check_P2PNAME",
    "int",
    ["str"]
  );

  f.LF_Check_P2PNAME_Api = library.func(
    "LF_Check_P2PNAME_Api",
    "int",
    ["str", "str"]
  );

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
 * Returns the binding instance, loading the native library and
 * declaring all functions on first call.
 *
 * @returns {object}
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
      TP2P_UID,
    }),
    callbacks: Object.freeze({
      LfCallFunc,
      LfNotifyFunc,
      LfNetworkEventFunc,
      LfAsyncCallOnResult,
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
  koffi,
  DataHnd,
  AppHnd,
  TP2P_UID,
  LfCallFunc,
  LfNotifyFunc,
  LfNetworkEventFunc,
  LfAsyncCallOnResult,
};