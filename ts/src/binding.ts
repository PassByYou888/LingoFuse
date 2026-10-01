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
//
//  Export count:
//      37 functions, matching the C ABI export table:
//        - 10 data handle
//        - 5  application handle
//        - 3  API registration
//        - 2  local execution
//        - 5  network preparation
//        - 3  remote invocation
//        - 7  options and diagnostics
//        - 1  shutdown
//        - 1  network events
// =============================================================================

import koffi = require("koffi");
import * as path from "node:path";
import * as fs from "node:fs";

import { getRuntimeInfo } from "./runtime";

/** The library handle returned by koffi.load(). */
type KoffiLib = ReturnType<typeof koffi.load>;

// -----------------------------------------------------------------------------
//  Platform name and search-path helpers
// -----------------------------------------------------------------------------

/**
 * Return the platform-specific shared library file name.
 *
 * Windows 64-bit : LingoFuse64.dll
 * Windows 32-bit : LingoFuse32.dll
 * Linux / BSD    : liblingofuse.so
 * macOS          : liblingofuse.dylib
 */
export function selectPlatformFileName(): string {
    const info = getRuntimeInfo();
    if (info.platform === "win32") {
        return info.arch === "x64" ? "LingoFuse64.dll" : "LingoFuse32.dll";
    }
    if (info.platform === "darwin") {
        return "liblingofuse.dylib";
    }
    return "liblingofuse.so";
}

/**
 * Return the ordered list of candidate absolute paths for the native
 * library.
 *
 * Resolution order:
 *   1. The directory containing the current executable.
 *   2. The current working directory.
 *   3. The package-local "native/" subdirectory.
 *
 * The final fallback in loadLibrary() is to ask the OS loader to
 * resolve the bare file name, which covers PATH on Windows,
 * LD_LIBRARY_PATH on Linux, and DYLD_LIBRARY_PATH on macOS.
 */
export function buildSearchPaths(): readonly string[] {
    const fileName = selectPlatformFileName();
    const candidates: string[] = [];
    const proc = (globalThis as {
        process?: { execPath?: string; cwd?: () => string };
    }).process;

    if (typeof proc?.execPath === "string" && proc.execPath.length > 0) {
        candidates.push(path.join(path.dirname(proc.execPath), fileName));
    }
    if (typeof proc?.cwd === "function") {
        try {
            candidates.push(path.join(proc.cwd(), fileName));
        } catch {
            // cwd() may throw in restricted sandboxes; skip.
        }
    }
    if (typeof __dirname === "string" && __dirname.length > 0) {
        candidates.push(path.join(__dirname, "..", "native", fileName));
    }
    return candidates;
}

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
export const LfCallFuncProto = koffi.proto(
    "LfCallFunc",
    "void",
    [koffi.pointer("void"), DataHnd, DataHnd],
);

/** Callback prototype for Notify-mode (one-way) APIs. */
export const LfNotifyFuncProto = koffi.proto(
    "LfNotifyFunc",
    "void",
    [koffi.pointer("void"), DataHnd],
);

/** Callback prototype for network connect / disconnect events. */
export const LfNetworkEventFuncProto = koffi.proto(
    "LfNetworkEventFunc",
    "void",
    ["str"],
);

/** Pointer types derived from the callback prototypes. */
export const LfCallFuncPtr = koffi.pointer(LfCallFuncProto);
export const LfNotifyFuncPtr = koffi.pointer(LfNotifyFuncProto);
export const LfNetworkEventFuncPtr = koffi.pointer(LfNetworkEventFuncProto);

// -----------------------------------------------------------------------------
//  Native function table
// -----------------------------------------------------------------------------

/**
 * Function table for the 37 exported LingoFuse functions.
 *
 * FFI-boundary parameters are typed as `any`; the interface exists to
 * name the functions and to pin their return types.
 */
export interface NativeFunctions {
    // ---- Data handles (10) ----
    LF_CreateData(methodName: string): any;
    LF_CreateData_Permanent(methodName: string): any;
    LF_FreeData(hnd: any): void;
    LF_GetBuffer(hnd: any): any;
    LF_WriteBuffer(hnd: any, buff: Uint8Array, size: any): any;
    LF_ReadBuffer(hnd: any, buff: Uint8Array, size: any): any;
    LF_GetPos(hnd: any): any;
    LF_SetPos(hnd: any, pos: any): void;
    LF_GetSize(hnd: any): any;
    LF_SetSize(hnd: any, size: any): void;

    // ---- Application handles (5) ----
    LF_CreateApp(appName: string, desc: string): any;
    LF_FreeApp(appHnd: any): void;
    LF_Generate_AppName(): string;
    LF_Get_AppName(appHnd: any): string;
    LF_BindApp(appHnd: any): number;

    // ---- API registration (3) ----
    LF_RegisterCall(
        appHnd: any,
        methodName: string,
        desc: string,
        trigger: any,
        onCall: any,
    ): number;
    LF_RegisterNotify(
        appHnd: any,
        methodName: string,
        desc: string,
        trigger: any,
        onNotify: any,
    ): number;
    LF_Unregister(appHnd: any, methodName: string): number;

    // ---- Local execution (2) ----
    LF_LocalCall(appHnd: any, param: any): any;
    LF_LocalNotify(appHnd: any, param: any): void;

    // ---- Network preparation (5) ----
    LF_ResetPrepare(): void;
    LF_PrepareService(listeningAddr: string, physicsAddr: string): number;
    LF_PrepareClient(physicsAddr: string, appHnd: any): number;
    LF_PrepareDone(): number;
    LF_ExitMainThread(): void;

    // ---- Remote invocation (3) ----
    LF_Call(appName: string, param: any, timeoutMs: any): any;
    LF_Notify(appName: string, param: any): void;
    LF_Sequenced_Notify(appName: string, param: any): void;

    // ---- Options and diagnostics (7) ----
    LF_SetOption(option: string, value: string): void;
    LF_GetStatusCount(): number;
    LF_GetStatus(): string;
    LF_PostStatus(status: string): void;
    LF_CheckMainThread(): number;
    LF_CheckApp(appName: string): number;
    LF_CheckApi(appName: string, apiName: string): number;

    // ---- Shutdown (1) ----
    LF_Shutdown(): void;

    // ---- Network events (1) ----
    LF_Set_Network_Event(onConnect: any, onDisconnect: any): void;
}

/** Binding singleton contents. */
export interface Binding {
    readonly koffi: typeof koffi;
    readonly libraryName: string;
    readonly platform: string;
    readonly funcs: NativeFunctions;
}

// -----------------------------------------------------------------------------
//  Library loading
// -----------------------------------------------------------------------------

let _lib: KoffiLib | null = null;

function loadLibrary(): KoffiLib {
    if (_lib !== null) {
        return _lib;
    }

    const errors: string[] = [];
    for (const candidate of buildSearchPaths()) {
        try {
            if (fs.existsSync(candidate)) {
                _lib = koffi.load(candidate);
                return _lib;
            }
        } catch (err) {
            errors.push(`${candidate}: ${err instanceof Error ? err.message : String(err)}`);
        }
    }

    const bareName = selectPlatformFileName();
    try {
        _lib = koffi.load(bareName);
        return _lib;
    } catch (err) {
        errors.push(`${bareName}: ${err instanceof Error ? err.message : String(err)}`);
    }

    throw new Error(
        `Failed to load the LingoFuse native library.\nTried:\n` +
        errors.map((e) => `  - ${e}`).join("\n") +
        `\nPlace the library next to the executable, in the current ` +
        `working directory, in a ./native/ subdirectory, or on the ` +
        `system loader search path (PATH on Windows, LD_LIBRARY_PATH ` +
        `on Linux, DYLD_LIBRARY_PATH on macOS).`,
    );
}

// -----------------------------------------------------------------------------
//  Function declaration
// -----------------------------------------------------------------------------

function declareFunctions(lib: KoffiLib): NativeFunctions {
    const f = {} as NativeFunctions;

    // ---- Data handles (10) ----
    f.LF_CreateData = lib.func(
        "LF_CreateData", DataHnd, ["str"],
    ) as NativeFunctions["LF_CreateData"];

    // PERMANENT data handle. Not added to the idle pool; never
    // auto-reclaimed; LF_FreeData releases it synchronously.
    f.LF_CreateData_Permanent = lib.func(
        "LF_CreateData_Permanent", DataHnd, ["str"],
    ) as NativeFunctions["LF_CreateData_Permanent"];

    f.LF_FreeData = lib.func(
        "LF_FreeData", "void", [DataHnd],
    ) as NativeFunctions["LF_FreeData"];

    f.LF_GetBuffer = lib.func(
        "LF_GetBuffer", koffi.pointer("void"), [DataHnd],
    ) as NativeFunctions["LF_GetBuffer"];

    f.LF_WriteBuffer = lib.func("LF_WriteBuffer", "int64", [
        DataHnd, koffi.pointer("uint8_t"), "int64",
    ]) as NativeFunctions["LF_WriteBuffer"];

    f.LF_ReadBuffer = lib.func("LF_ReadBuffer", "int64", [
        DataHnd, koffi.pointer("uint8_t"), "int64",
    ]) as NativeFunctions["LF_ReadBuffer"];

    f.LF_GetPos = lib.func(
        "LF_GetPos", "int64", [DataHnd],
    ) as NativeFunctions["LF_GetPos"];

    f.LF_SetPos = lib.func(
        "LF_SetPos", "void", [DataHnd, "int64"],
    ) as NativeFunctions["LF_SetPos"];

    f.LF_GetSize = lib.func(
        "LF_GetSize", "int64", [DataHnd],
    ) as NativeFunctions["LF_GetSize"];

    f.LF_SetSize = lib.func(
        "LF_SetSize", "void", [DataHnd, "int64"],
    ) as NativeFunctions["LF_SetSize"];

    // ---- Application handles (5) ----
    f.LF_CreateApp = lib.func(
        "LF_CreateApp", AppHnd, ["str", "str"],
    ) as NativeFunctions["LF_CreateApp"];

    f.LF_FreeApp = lib.func(
        "LF_FreeApp", "void", [AppHnd],
    ) as NativeFunctions["LF_FreeApp"];

    f.LF_Generate_AppName = lib.func(
        "LF_Generate_AppName", "str", [],
    ) as NativeFunctions["LF_Generate_AppName"];

    f.LF_Get_AppName = lib.func(
        "LF_Get_AppName", "str", [AppHnd],
    ) as NativeFunctions["LF_Get_AppName"];

    f.LF_BindApp = lib.func(
        "LF_BindApp", "int", [AppHnd],
    ) as NativeFunctions["LF_BindApp"];

    // ---- API registration (3) ----
    f.LF_RegisterCall = lib.func("LF_RegisterCall", "int", [
        AppHnd, "str", "str", koffi.pointer("void"), LfCallFuncPtr,
    ]) as NativeFunctions["LF_RegisterCall"];

    f.LF_RegisterNotify = lib.func("LF_RegisterNotify", "int", [
        AppHnd, "str", "str", koffi.pointer("void"), LfNotifyFuncPtr,
    ]) as NativeFunctions["LF_RegisterNotify"];

    f.LF_Unregister = lib.func(
        "LF_Unregister", "int", [AppHnd, "str"],
    ) as NativeFunctions["LF_Unregister"];

    // ---- Local execution (2) ----
    f.LF_LocalCall = lib.func(
        "LF_LocalCall", DataHnd, [AppHnd, DataHnd],
    ) as NativeFunctions["LF_LocalCall"];

    f.LF_LocalNotify = lib.func(
        "LF_LocalNotify", "void", [AppHnd, DataHnd],
    ) as NativeFunctions["LF_LocalNotify"];

    // ---- Network preparation (5) ----
    f.LF_ResetPrepare = lib.func(
        "LF_ResetPrepare", "void", [],
    ) as NativeFunctions["LF_ResetPrepare"];

    f.LF_PrepareService = lib.func(
        "LF_PrepareService", "int", ["str", "str"],
    ) as NativeFunctions["LF_PrepareService"];

    f.LF_PrepareClient = lib.func(
        "LF_PrepareClient", "int", ["str", AppHnd],
    ) as NativeFunctions["LF_PrepareClient"];

    f.LF_PrepareDone = lib.func(
        "LF_PrepareDone", "int", [],
    ) as NativeFunctions["LF_PrepareDone"];

    f.LF_ExitMainThread = lib.func(
        "LF_ExitMainThread", "void", [],
    ) as NativeFunctions["LF_ExitMainThread"];

    // ---- Remote invocation (3) ----
    f.LF_Call = lib.func(
        "LF_Call", DataHnd, ["str", DataHnd, "uint64"],
    ) as NativeFunctions["LF_Call"];

    f.LF_Notify = lib.func(
        "LF_Notify", "void", ["str", DataHnd],
    ) as NativeFunctions["LF_Notify"];

    f.LF_Sequenced_Notify = lib.func(
        "LF_Sequenced_Notify", "void", ["str", DataHnd],
    ) as NativeFunctions["LF_Sequenced_Notify"];

    // ---- Options and diagnostics (7) ----
    f.LF_SetOption = lib.func(
        "LF_SetOption", "void", ["str", "str"],
    ) as NativeFunctions["LF_SetOption"];

    f.LF_GetStatusCount = lib.func(
        "LF_GetStatusCount", "int", [],
    ) as NativeFunctions["LF_GetStatusCount"];

    f.LF_GetStatus = lib.func(
        "LF_GetStatus", "str", [],
    ) as NativeFunctions["LF_GetStatus"];

    f.LF_PostStatus = lib.func(
        "LF_PostStatus", "void", ["str"],
    ) as NativeFunctions["LF_PostStatus"];

    f.LF_CheckMainThread = lib.func(
        "LF_CheckMainThread", "int", [],
    ) as NativeFunctions["LF_CheckMainThread"];

    f.LF_CheckApp = lib.func(
        "LF_CheckApp", "int", ["str"],
    ) as NativeFunctions["LF_CheckApp"];

    f.LF_CheckApi = lib.func(
        "LF_CheckApi", "int", ["str", "str"],
    ) as NativeFunctions["LF_CheckApi"];

    // ---- Shutdown (1) ----
    f.LF_Shutdown = lib.func(
        "LF_Shutdown", "void", [],
    ) as NativeFunctions["LF_Shutdown"];

    // ---- Network events (1) ----
    f.LF_Set_Network_Event = lib.func("LF_Set_Network_Event", "void", [
        LfNetworkEventFuncPtr, LfNetworkEventFuncPtr,
    ]) as NativeFunctions["LF_Set_Network_Event"];

    return f;
}

// -----------------------------------------------------------------------------
//  Singleton
// -----------------------------------------------------------------------------

let _instance: Binding | null = null;

/**
 * Return the binding singleton, loading the native library and
 * declaring all 37 functions on first call.
 */
export function getBinding(): Binding {
    if (_instance !== null) {
        return _instance;
    }

    const lib = loadLibrary();
    const funcs = declareFunctions(lib);

    _instance = Object.freeze({
        koffi,
        libraryName: selectPlatformFileName(),
        platform: getRuntimeInfo().platform,
        funcs: Object.freeze(funcs),
    });
    return _instance;
}

/** Returns true when the native binding has been successfully loaded. */
export function isLoaded(): boolean {
    return _instance !== null;
}

/**
 * Expose the Koffi module for advanced use (custom types, direct
 * declarations). Normal application code should not need this.
 */
export { koffi };