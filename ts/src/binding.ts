// =============================================================================
//  binding.ts
// -----------------------------------------------------------------------------
//  Low-level native binding for the LingoFuse C ABI using Koffi.
//
//  This module is the ONLY place in the TypeScript binding where native
//  code is invoked. Every higher-level wrapper goes through the
//  functions declared here.
//
//  RESPONSIBILITY
//  --------------
//    1. Locate and load the platform-specific LingoFuse shared library.
//    2. Declare all 59 exported C functions with correct signatures.
//    3. Provide opaque handle types (DataHnd, AppHnd) and the 32-byte
//       TP2P_UID struct type.
//    4. Declare callback prototypes for Call, Notify, Network events,
//       and asynchronous Call (LfAsyncCallOnResult).
//    5. Expose a clean, synchronous API surface for the RAII layer.
//
//  UID TYPE - TWO DIFFERENT ROLES
//  ------------------------------
//  The Pascal-side type `TP2P_UID___` is `array[0..31] of Byte`. It
//  plays TWO different roles on the C ABI, and each role requires a
//  DIFFERENT Koffi-level representation:
//
//    ROLE 1 - ARGUMENT (input position):
//        The Koffi type is `TP2P_UID` (a `uint8[32]` array wrapped in
//        a struct). Used by all LF_UID_* and LF_Check_UID* functions,
//        and by LF_UID_*_Sequenced_*.
//
//    ROLE 2 - RETURN VALUE (only LF_Get_P2P_UID):
//        The Koffi type is `koffi.pointer("uint8")`. The pointer is
//        allocated by the native side and released ~5 seconds later.
//
//  DO NOT unify these two roles.
//
//  CALLBACK TYPES
//  --------------
//  Koffi distinguishes between "an opaque pointer" (koffi.pointer("void"))
//  and "a pointer to a callback with a specific signature". The latter
//  must be built with koffi.proto() first, then wrapped with
//  koffi.pointer(). Passing a plain void pointer where a callback
//  pointer is expected raises:
//      TypeError: Unexpected void * type, expected <callback> * type
//
//  The four callback prototypes below (LfCallFunc, LfNotifyFunc,
//  LfNetworkEventFunc, LfAsyncCallOnResult) mirror the definitions in
//  LingoFuse.h and lingofuse_import.pas.
//
//  TYPE STRATEGY
//  -------------
//  The NativeFunctions interface declares every FFI-boundary parameter
//  as `any` so that call sites do not need casts. Real type checking is
//  enforced by the higher-level wrappers (DataHandle / AppHandle /
//  framework / address).
//
//  EXPORT COUNT
//  ------------
//  59 functions, matching the C ABI export table:
//      - 12  data handle
//      - 5   application handle
//      - 3   app-bound API registration
//      - 3   process-wide P2P API registration
//      - 2   local execution
//      - 5   network preparation
//      - 5   App-name remote invocation
//      - 5   UID remote invocation
//      - 5   P2PName remote invocation
//      - 7   health checks
//      - 2   options
//      - 3   status
//      - 1   network events
//      - 1   shutdown
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

/**
 * Argument-role type: a 32-byte UID, passed by value in cdecl.
 *
 * WHY A STRUCT, NOT A BARE ARRAY
 * ------------------------------
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
export const TP2P_UID = koffi.struct("TP2P_UID", {
    bytes: koffi.array("uint8", 32, "Typed"),
});

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

/**
 * Callback prototype for the asynchronous remote invocation family
 * (LF_Async_Call and its UID_* / P2PNAME_* variants).
 *
 * Parameters:
 *   - data   : the opaque pointer the caller passed at the call site
 *              (the `Data` argument of LF_Async_Call etc.).
 *   - result : a DataHnd OWNED BY THE FRAMEWORK.
 *
 * {!!!!!  LIFETIME  !!!!!}
 * The `result` handle is released IMMEDIATELY after this callback
 * returns. Do NOT call LF_FreeData on it. Do NOT retain the pointer
 * past its own return. Any handle from an asynchronous callback must
 * be read fully (and its bytes copied out) BEFORE the callback
 * returns.
 *
 * This prototype is deliberately declared SEPARATELY from
 * LfNotifyFuncProto even though their parameter lists happen to be
 * identical. The two serve different roles: LfNotifyFuncProto is
 * registered on the native side as a persistent API handler, while
 * LfAsyncCallOnResultProto is a one-shot completion callback. Koffi
 * treats distinct proto() names as distinct types, which is what we
 * want here.
 */
export const LfAsyncCallOnResultProto = koffi.proto(
    "LfAsyncCallOnResult",
    "void",
    [koffi.pointer("void"), DataHnd],
);

/** Pointer types derived from the callback prototypes. */
export const LfCallFuncPtr = koffi.pointer(LfCallFuncProto);
export const LfNotifyFuncPtr = koffi.pointer(LfNotifyFuncProto);
export const LfNetworkEventFuncPtr = koffi.pointer(LfNetworkEventFuncProto);
export const LfAsyncCallOnResultPtr = koffi.pointer(LfAsyncCallOnResultProto);

// -----------------------------------------------------------------------------
//  Native function table
// -----------------------------------------------------------------------------

/**
 * Function table for the 59 exported LingoFuse functions.
 *
 * FFI-boundary parameters are typed as `any`; the interface exists to
 * name the functions and to pin their return types.
 */
export interface NativeFunctions {
    // ---- Data handles (12) ----
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
    /**
     * Reads the auto-injected sender UID ("side data") from an INPUT
     * data handle. Returns a POINTER to a 32-byte UID. The pointer is
     * owned by the native side and released ~5 seconds after the call.
     * Callers must copy the 32 bytes immediately and never retain the
     * pointer.
     */
    LF_Get_P2P_UID(hnd: any): any;
    /**
     * Reads the auto-injected sender P2P group name ("side data") from
     * an INPUT data handle. Returns a NUL-terminated UTF-8 string. The
     * buffer is released ~5 seconds after the call; Koffi's `str`
     * return type copies it immediately.
     */
    LF_Get_P2P_Name(hnd: any): string;

    // ---- Application handles (5) ----
    LF_CreateApp(appName: string, desc: string): any;
    LF_FreeApp(appHnd: any): void;
    LF_Generate_AppName(): string;
    LF_Get_AppName(appHnd: any): string;
    LF_BindApp(appHnd: any): number;

    // ---- App-bound API registration (3) ----
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

    // ---- Process-wide P2P API registration (3) ----
    //
    // The process-wide P2P namespace is independent of any App. APIs
    // registered here are reachable via UID addressing and P2PName
    // addressing ONLY; they are NOT reachable via App-name addressing.
    LF_Register_P2P_Call(
        methodName: string,
        desc: string,
        trigger: any,
        onCall: any,
    ): number;
    LF_Register_P2P_Notify(
        methodName: string,
        desc: string,
        trigger: any,
        onNotify: any,
    ): number;
    LF_Unregister_P2P(methodName: string): number;

    // ---- Local execution (2) ----
    LF_LocalCall(appHnd: any, param: any): any;
    LF_LocalNotify(appHnd: any, param: any): void;

    // ---- Network preparation (5) ----
    LF_ResetPrepare(): void;
    LF_PrepareService(listeningAddr: string, physicsAddr: string): number;
    LF_PrepareClient(physicsAddr: string, appHnd: any): number;
    LF_PrepareDone(): number;
    LF_ExitMainThread(): void;

    // ---- App-name remote invocation (5) ----
    LF_Call(appName: string, param: any, timeoutMs: any): any;
    LF_Async_Call(
        appName: string,
        param: any,
        data: any,
        onResult: any,
    ): number;
    LF_Async_Sequenced_Call(
        appName: string,
        param: any,
        data: any,
        onResult: any,
    ): number;
    LF_Notify(appName: string, param: any): void;
    LF_Sequenced_Notify(appName: string, param: any): void;

    // ---- UID remote invocation (5) ----
    LF_UID_Call(uid: any, param: any, timeoutMs: any): any;
    LF_UID_Async_Call(
        uid: any,
        param: any,
        data: any,
        onResult: any,
    ): number;
    LF_UID_Async_Sequenced_Call(
        uid: any,
        param: any,
        data: any,
        onResult: any,
    ): number;
    LF_UID_Notify(uid: any, param: any): void;
    LF_UID_Sequenced_Notify(uid: any, param: any): void;

    // ---- P2PName remote invocation (5) ----
    LF_P2PNAME_Call(
        p2pName: string,
        param: any,
        timeoutMs: any,
    ): any;
    LF_P2PNAME_Async_Call(
        p2pName: string,
        param: any,
        data: any,
        onResult: any,
    ): number;
    LF_P2PNAME_Async_Sequenced_Call(
        p2pName: string,
        param: any,
        data: any,
        onResult: any,
    ): number;
    LF_P2PNAME_Notify(p2pName: string, param: any): void;
    LF_P2PNAME_Sequenced_Notify(p2pName: string, param: any): void;

    // ---- Health checks (7) ----
    LF_CheckMainThread(): number;
    LF_CheckApp(appName: string): number;
    LF_CheckApi(appName: string, apiName: string): number;
    LF_Check_UID(uid: any): number;
    LF_Check_UID_Api(uid: any, apiName: string): number;
    LF_Check_P2PNAME(p2pName: string): number;
    LF_Check_P2PNAME_Api(p2pName: string, apiName: string): number;

    // ---- Options (2) ----
    LF_SetOption(option: string, value: string): void;
    /**
     * Reads a runtime option. Returns a UTF-8 string. Unknown option
     * names yield an empty string. The underlying buffer is released
     * ~5 seconds after the call; Koffi's `str` return type copies it
     * immediately, so the returned value is safe to retain.
     */
    LF_GetOption(option: string): string;

    // ---- Status (3) ----
    LF_GetStatusCount(): number;
    LF_GetStatus(): string;
    LF_PostStatus(status: string): void;

    // ---- Network events (1) ----
    LF_Set_Network_Event(onConnect: any, onDisconnect: any): void;

    // ---- Shutdown (1) ----
    LF_Shutdown(): void;
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
            errors.push(
                `${candidate}: ${
                    err instanceof Error ? err.message : String(err)
                }`,
            );
        }
    }

    const bareName = selectPlatformFileName();
    try {
        _lib = koffi.load(bareName);
        return _lib;
    } catch (err) {
        errors.push(
            `${bareName}: ${
                err instanceof Error ? err.message : String(err)
            }`,
        );
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

    // ---- Data handles (12) ----
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

    // LF_Get_P2P_UID returns a POINTER to a 32-byte UID. The pointer
    // is owned by the native side and released ~5 seconds after the
    // call. Callers must copy the 32 bytes immediately and never
    // retain the pointer. See DataHandle.getP2PUid in data-handle.ts
    // for the sanctioned wrapper.
    f.LF_Get_P2P_UID = lib.func(
        "LF_Get_P2P_UID",
        koffi.pointer("uint8"),
        [DataHnd],
    ) as NativeFunctions["LF_Get_P2P_UID"];

    // LF_Get_P2P_Name returns a NUL-terminated UTF-8 string. Koffi's
    // `str` return type copies it immediately.
    f.LF_Get_P2P_Name = lib.func(
        "LF_Get_P2P_Name", "str", [DataHnd],
    ) as NativeFunctions["LF_Get_P2P_Name"];

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

    // ---- App-bound API registration (3) ----
    f.LF_RegisterCall = lib.func("LF_RegisterCall", "int", [
        AppHnd, "str", "str", koffi.pointer("void"), LfCallFuncPtr,
    ]) as NativeFunctions["LF_RegisterCall"];

    f.LF_RegisterNotify = lib.func("LF_RegisterNotify", "int", [
        AppHnd, "str", "str", koffi.pointer("void"), LfNotifyFuncPtr,
    ]) as NativeFunctions["LF_RegisterNotify"];

    f.LF_Unregister = lib.func(
        "LF_Unregister", "int", [AppHnd, "str"],
    ) as NativeFunctions["LF_Unregister"];

    // ---- Process-wide P2P API registration (3) ----
    //
    // These register into the process-wide LF_P2P_APP namespace.
    // Reachable via UID and P2PName addressing only; NOT via App-name
    // addressing. They take no AppHnd.
    f.LF_Register_P2P_Call = lib.func("LF_Register_P2P_Call", "int", [
        "str", "str", koffi.pointer("void"), LfCallFuncPtr,
    ]) as NativeFunctions["LF_Register_P2P_Call"];

    f.LF_Register_P2P_Notify = lib.func(
        "LF_Register_P2P_Notify", "int",
        ["str", "str", koffi.pointer("void"), LfNotifyFuncPtr],
    ) as NativeFunctions["LF_Register_P2P_Notify"];

    f.LF_Unregister_P2P = lib.func(
        "LF_Unregister_P2P", "int", ["str"],
    ) as NativeFunctions["LF_Unregister_P2P"];

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

    // ---- App-name remote invocation (5) ----
    f.LF_Call = lib.func(
        "LF_Call", DataHnd, ["str", DataHnd, "uint64"],
    ) as NativeFunctions["LF_Call"];

    f.LF_Async_Call = lib.func("LF_Async_Call", "int", [
        "str", DataHnd, koffi.pointer("void"), LfAsyncCallOnResultPtr,
    ]) as NativeFunctions["LF_Async_Call"];

    f.LF_Async_Sequenced_Call = lib.func(
        "LF_Async_Sequenced_Call", "int",
        ["str", DataHnd, koffi.pointer("void"), LfAsyncCallOnResultPtr],
    ) as NativeFunctions["LF_Async_Sequenced_Call"];

    f.LF_Notify = lib.func(
        "LF_Notify", "void", ["str", DataHnd],
    ) as NativeFunctions["LF_Notify"];

    f.LF_Sequenced_Notify = lib.func(
        "LF_Sequenced_Notify", "void", ["str", DataHnd],
    ) as NativeFunctions["LF_Sequenced_Notify"];

    // ---- UID remote invocation (5) ----
    //
    // The UID argument is passed by value in cdecl, wrapped in the
    // TP2P_UID struct (see the note at the top of this file). Callers
    // must pass { bytes: Uint8Array(32) } at the call site; the
    // _toTp2pUid helper in address.ts does this.
    f.LF_UID_Call = lib.func(
        "LF_UID_Call", DataHnd, [TP2P_UID, DataHnd, "uint64"],
    ) as NativeFunctions["LF_UID_Call"];

    f.LF_UID_Async_Call = lib.func("LF_UID_Async_Call", "int", [
        TP2P_UID, DataHnd, koffi.pointer("void"), LfAsyncCallOnResultPtr,
    ]) as NativeFunctions["LF_UID_Async_Call"];

    f.LF_UID_Async_Sequenced_Call = lib.func(
        "LF_UID_Async_Sequenced_Call", "int",
        [TP2P_UID, DataHnd, koffi.pointer("void"), LfAsyncCallOnResultPtr],
    ) as NativeFunctions["LF_UID_Async_Sequenced_Call"];

    f.LF_UID_Notify = lib.func(
        "LF_UID_Notify", "void", [TP2P_UID, DataHnd],
    ) as NativeFunctions["LF_UID_Notify"];

    f.LF_UID_Sequenced_Notify = lib.func(
        "LF_UID_Sequenced_Notify", "void", [TP2P_UID, DataHnd],
    ) as NativeFunctions["LF_UID_Sequenced_Notify"];

    // ---- P2PName remote invocation (5) ----
    f.LF_P2PNAME_Call = lib.func(
        "LF_P2PNAME_Call", DataHnd, ["str", DataHnd, "uint64"],
    ) as NativeFunctions["LF_P2PNAME_Call"];

    f.LF_P2PNAME_Async_Call = lib.func(
        "LF_P2PNAME_Async_Call", "int",
        ["str", DataHnd, koffi.pointer("void"), LfAsyncCallOnResultPtr],
    ) as NativeFunctions["LF_P2PNAME_Async_Call"];

    f.LF_P2PNAME_Async_Sequenced_Call = lib.func(
        "LF_P2PNAME_Async_Sequenced_Call", "int",
        ["str", DataHnd, koffi.pointer("void"), LfAsyncCallOnResultPtr],
    ) as NativeFunctions["LF_P2PNAME_Async_Sequenced_Call"];

    f.LF_P2PNAME_Notify = lib.func(
        "LF_P2PNAME_Notify", "void", ["str", DataHnd],
    ) as NativeFunctions["LF_P2PNAME_Notify"];

    f.LF_P2PNAME_Sequenced_Notify = lib.func(
        "LF_P2PNAME_Sequenced_Notify", "void", ["str", DataHnd],
    ) as NativeFunctions["LF_P2PNAME_Sequenced_Notify"];

    // ---- Health checks (7) ----
    f.LF_CheckMainThread = lib.func(
        "LF_CheckMainThread", "int", [],
    ) as NativeFunctions["LF_CheckMainThread"];

    f.LF_CheckApp = lib.func(
        "LF_CheckApp", "int", ["str"],
    ) as NativeFunctions["LF_CheckApp"];

    f.LF_CheckApi = lib.func(
        "LF_CheckApi", "int", ["str", "str"],
    ) as NativeFunctions["LF_CheckApi"];

    f.LF_Check_UID = lib.func(
        "LF_Check_UID", "int", [TP2P_UID],
    ) as NativeFunctions["LF_Check_UID"];

    f.LF_Check_UID_Api = lib.func(
        "LF_Check_UID_Api", "int", [TP2P_UID, "str"],
    ) as NativeFunctions["LF_Check_UID_Api"];

    f.LF_Check_P2PNAME = lib.func(
        "LF_Check_P2PNAME", "int", ["str"],
    ) as NativeFunctions["LF_Check_P2PNAME"];

    f.LF_Check_P2PNAME_Api = lib.func(
        "LF_Check_P2PNAME_Api", "int", ["str", "str"],
    ) as NativeFunctions["LF_Check_P2PNAME_Api"];

    // ---- Options (2) ----
    f.LF_SetOption = lib.func(
        "LF_SetOption", "void", ["str", "str"],
    ) as NativeFunctions["LF_SetOption"];

    // LF_GetOption returns a transient UTF-8 buffer, released ~5
    // seconds after the call. Koffi's `str` return type copies it on
    // the call boundary, so the returned string is fully detached.
    f.LF_GetOption = lib.func(
        "LF_GetOption", "str", ["str"],
    ) as NativeFunctions["LF_GetOption"];

    // ---- Status (3) ----
    f.LF_GetStatusCount = lib.func(
        "LF_GetStatusCount", "int", [],
    ) as NativeFunctions["LF_GetStatusCount"];

    f.LF_GetStatus = lib.func(
        "LF_GetStatus", "str", [],
    ) as NativeFunctions["LF_GetStatus"];

    f.LF_PostStatus = lib.func(
        "LF_PostStatus", "void", ["str"],
    ) as NativeFunctions["LF_PostStatus"];

    // ---- Network events (1) ----
    f.LF_Set_Network_Event = lib.func("LF_Set_Network_Event", "void", [
        LfNetworkEventFuncPtr, LfNetworkEventFuncPtr,
    ]) as NativeFunctions["LF_Set_Network_Event"];

    // ---- Shutdown (1) ----
    f.LF_Shutdown = lib.func(
        "LF_Shutdown", "void", [],
    ) as NativeFunctions["LF_Shutdown"];

    return f;
}

// -----------------------------------------------------------------------------
//  Singleton
// -----------------------------------------------------------------------------

let _instance: Binding | null = null;

/**
 * Return the binding singleton, loading the native library and
 * declaring all 59 functions on first call.
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