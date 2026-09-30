"use strict";
// =============================================================================
//  binding.ts
// -----------------------------------------------------------------------------
//  Low-level native binding for the LingoFuse C ABI using Koffi.
//
//  Callback types:
//      Koffi distinguishes between "an opaque pointer" (koffi.pointer("void"))
//      and "a pointer to a callback with a specific signature". The latter
//      must be built with koffi.proto() first, then wrapped with
//      koffi.pointer(). Passing a plain void pointer where a callback
//      pointer is expected raises:
//          TypeError: Unexpected void * type, expected <callback> * type
//
//      The three callback prototypes below (LfCallFunc, LfNotifyFunc,
//      LfNetworkEventFunc) mirror the definitions in LingoFuse.h and
//      lingofuse_import.pas.
//
//  Type strategy:
//      The NativeFunctions interface declares every FFI-boundary
//      parameter as `any` so that call sites do not need casts. Real
//      type checking is enforced by the higher-level wrappers
//      (DataHandle / AppHandle / framework).
// =============================================================================
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null) for (var k in mod) if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.koffi = exports.isLoaded = exports.getBinding = exports.LfNetworkEventFuncPtr = exports.LfNotifyFuncPtr = exports.LfCallFuncPtr = exports.LfNetworkEventFuncProto = exports.LfNotifyFuncProto = exports.LfCallFuncProto = exports.buildSearchPaths = exports.selectPlatformFileName = void 0;
const koffi = require("koffi");
exports.koffi = koffi;
const path = __importStar(require("node:path"));
const fs = __importStar(require("node:fs"));
const runtime_1 = require("./runtime");
// -----------------------------------------------------------------------------
//  Platform name and search-path helpers
// -----------------------------------------------------------------------------
/** Platform-specific shared library file name. */
function selectPlatformFileName() {
    const info = (0, runtime_1.getRuntimeInfo)();
    if (info.platform === "win32") {
        return info.arch === "x64" ? "LingoFuse64.dll" : "LingoFuse32.dll";
    }
    if (info.platform === "darwin") {
        return "liblingofuse.dylib";
    }
    return "liblingofuse.so";
}
exports.selectPlatformFileName = selectPlatformFileName;
/** Ordered list of candidate absolute paths for the native library. */
function buildSearchPaths() {
    const fileName = selectPlatformFileName();
    const candidates = [];
    const proc = globalThis.process;
    if (typeof proc?.execPath === "string" && proc.execPath.length > 0) {
        candidates.push(path.join(path.dirname(proc.execPath), fileName));
    }
    if (typeof proc?.cwd === "function") {
        try {
            candidates.push(path.join(proc.cwd(), fileName));
        }
        catch {
            // cwd() may throw in restricted sandboxes; skip.
        }
    }
    if (typeof __dirname === "string" && __dirname.length > 0) {
        candidates.push(path.join(__dirname, "..", "native", fileName));
    }
    return candidates;
}
exports.buildSearchPaths = buildSearchPaths;
// -----------------------------------------------------------------------------
//  Opaque handle types
// -----------------------------------------------------------------------------
const DataHnd = koffi.pointer("DataHnd", koffi.opaque());
const AppHnd = koffi.pointer("AppHnd", koffi.opaque());
// -----------------------------------------------------------------------------
//  Callback prototypes
// -----------------------------------------------------------------------------
//
//  These must be declared before they are used in lib.func() signatures
//  or passed to koffi.register(). The exported pointer types are what
//  call sites actually need.
// -----------------------------------------------------------------------------
/** Callback prototype for Call-mode (request-response) APIs. */
exports.LfCallFuncProto = koffi.proto("LfCallFunc", "void", [koffi.pointer("void"), DataHnd, DataHnd]);
/** Callback prototype for Notify-mode (one-way) APIs. */
exports.LfNotifyFuncProto = koffi.proto("LfNotifyFunc", "void", [koffi.pointer("void"), DataHnd]);
/** Callback prototype for network connect / disconnect events. */
exports.LfNetworkEventFuncProto = koffi.proto("LfNetworkEventFunc", "void", ["str"]);
/** Pointer types derived from the callback prototypes. */
exports.LfCallFuncPtr = koffi.pointer(exports.LfCallFuncProto);
exports.LfNotifyFuncPtr = koffi.pointer(exports.LfNotifyFuncProto);
exports.LfNetworkEventFuncPtr = koffi.pointer(exports.LfNetworkEventFuncProto);
// -----------------------------------------------------------------------------
//  Library loading
// -----------------------------------------------------------------------------
let _lib = null;
function loadLibrary() {
    if (_lib !== null) {
        return _lib;
    }
    const errors = [];
    for (const candidate of buildSearchPaths()) {
        try {
            if (fs.existsSync(candidate)) {
                _lib = koffi.load(candidate);
                return _lib;
            }
        }
        catch (err) {
            errors.push(`${candidate}: ${err instanceof Error ? err.message : String(err)}`);
        }
    }
    const bareName = selectPlatformFileName();
    try {
        _lib = koffi.load(bareName);
        return _lib;
    }
    catch (err) {
        errors.push(`${bareName}: ${err instanceof Error ? err.message : String(err)}`);
    }
    throw new Error(`Failed to load the LingoFuse native library.\nTried:\n` +
        errors.map((e) => `  - ${e}`).join("\n") +
        `\nPlace the library next to the executable, in the current ` +
        `working directory, in a ./native/ subdirectory, or on the ` +
        `system loader search path (PATH on Windows, LD_LIBRARY_PATH ` +
        `on Linux, DYLD_LIBRARY_PATH on macOS).`);
}
// -----------------------------------------------------------------------------
//  Function declaration
// -----------------------------------------------------------------------------
function declareFunctions(lib) {
    const f = {};
    // ---- Data handles (9) ----
    f.LF_CreateData = lib.func("LF_CreateData", DataHnd, ["str"]);
    f.LF_FreeData = lib.func("LF_FreeData", "void", [DataHnd]);
    f.LF_GetBuffer = lib.func("LF_GetBuffer", koffi.pointer("void"), [DataHnd]);
    f.LF_WriteBuffer = lib.func("LF_WriteBuffer", "int64", [
        DataHnd, koffi.pointer("uint8_t"), "int64",
    ]);
    f.LF_ReadBuffer = lib.func("LF_ReadBuffer", "int64", [
        DataHnd, koffi.pointer("uint8_t"), "int64",
    ]);
    f.LF_GetPos = lib.func("LF_GetPos", "int64", [DataHnd]);
    f.LF_SetPos = lib.func("LF_SetPos", "void", [DataHnd, "int64"]);
    f.LF_GetSize = lib.func("LF_GetSize", "int64", [DataHnd]);
    f.LF_SetSize = lib.func("LF_SetSize", "void", [DataHnd, "int64"]);
    // ---- Application handles (5) ----
    f.LF_CreateApp = lib.func("LF_CreateApp", AppHnd, ["str", "str"]);
    f.LF_FreeApp = lib.func("LF_FreeApp", "void", [AppHnd]);
    f.LF_Generate_AppName = lib.func("LF_Generate_AppName", "str", []);
    f.LF_Get_AppName = lib.func("LF_Get_AppName", "str", [AppHnd]);
    f.LF_BindApp = lib.func("LF_BindApp", "int", [AppHnd]);
    // ---- API registration (3) ----
    f.LF_RegisterCall = lib.func("LF_RegisterCall", "int", [
        AppHnd, "str", "str", koffi.pointer("void"), exports.LfCallFuncPtr,
    ]);
    f.LF_RegisterNotify = lib.func("LF_RegisterNotify", "int", [
        AppHnd, "str", "str", koffi.pointer("void"), exports.LfNotifyFuncPtr,
    ]);
    f.LF_Unregister = lib.func("LF_Unregister", "int", [AppHnd, "str"]);
    // ---- Local execution (2) ----
    f.LF_LocalCall = lib.func("LF_LocalCall", DataHnd, [AppHnd, DataHnd]);
    f.LF_LocalNotify = lib.func("LF_LocalNotify", "void", [AppHnd, DataHnd]);
    // ---- Network preparation (5) ----
    f.LF_ResetPrepare = lib.func("LF_ResetPrepare", "void", []);
    f.LF_PrepareService = lib.func("LF_PrepareService", "int", ["str", "str"]);
    f.LF_PrepareClient = lib.func("LF_PrepareClient", "int", ["str", AppHnd]);
    f.LF_PrepareDone = lib.func("LF_PrepareDone", "int", []);
    f.LF_ExitMainThread = lib.func("LF_ExitMainThread", "void", []);
    // ---- Remote invocation (3) ----
    f.LF_Call = lib.func("LF_Call", DataHnd, ["str", DataHnd, "uint64"]);
    f.LF_Notify = lib.func("LF_Notify", "void", ["str", DataHnd]);
    f.LF_Sequenced_Notify = lib.func("LF_Sequenced_Notify", "void", ["str", DataHnd]);
    // ---- Options and diagnostics (7) ----
    f.LF_SetOption = lib.func("LF_SetOption", "void", ["str", "str"]);
    f.LF_GetStatusCount = lib.func("LF_GetStatusCount", "int", []);
    f.LF_GetStatus = lib.func("LF_GetStatus", "str", []);
    f.LF_PostStatus = lib.func("LF_PostStatus", "void", ["str"]);
    f.LF_CheckMainThread = lib.func("LF_CheckMainThread", "int", []);
    f.LF_CheckApp = lib.func("LF_CheckApp", "int", ["str"]);
    f.LF_CheckApi = lib.func("LF_CheckApi", "int", ["str", "str"]);
    // ---- Shutdown (1) ----
    f.LF_Shutdown = lib.func("LF_Shutdown", "void", []);
    // ---- Network events (1) ----
    f.LF_Set_Network_Event = lib.func("LF_Set_Network_Event", "void", [
        exports.LfNetworkEventFuncPtr, exports.LfNetworkEventFuncPtr,
    ]);
    return f;
}
// -----------------------------------------------------------------------------
//  Singleton
// -----------------------------------------------------------------------------
let _instance = null;
/** Return the binding singleton, loading the library on first call. */
function getBinding() {
    if (_instance !== null) {
        return _instance;
    }
    const lib = loadLibrary();
    const funcs = declareFunctions(lib);
    _instance = Object.freeze({
        koffi,
        libraryName: selectPlatformFileName(),
        platform: (0, runtime_1.getRuntimeInfo)().platform,
        funcs: Object.freeze(funcs),
    });
    return _instance;
}
exports.getBinding = getBinding;
/** Returns true when the native binding has been successfully loaded. */
function isLoaded() {
    return _instance !== null;
}
exports.isLoaded = isLoaded;
//# sourceMappingURL=binding.js.map