/**
 * @file LingoFuse.c
 * @brief Implementation of the explicit-linking C wrapper for LingoFuse.
 *
 * This file provides:
 *   - Platform-specific dynamic library loading (LoadLibraryA / dlopen).
 *   - Resolution of all 59 exported LF_* symbols into static function
 *     pointers, with cleanup on partial failure.
 *   - Thin forwarding wrappers with defensive null checks.
 *   - Helper functions (LF_WriteInt8 / LF_ReadString / LF_WriteUid /
 *     LF_ReadUid / ...) implemented on top of LF_WriteBuffer /
 *     LF_ReadBuffer, matching Pascal semantics in lingofuse_import.pas.
 *
 * All error and diagnostic output is written to stderr in English.
 *
 * Platform support:
 *   - Windows (MSVC, MinGW, clang-cl)
 *   - Linux / BSD (glibc, musl)
 *   - macOS (via _NSGetExecutablePath, since /proc is not available)
 *
 * Thread safety note:
 *   LF_LoadLibrary() and LF_FreeLibrary() are NOT thread-safe with each
 *   other. Call LF_LoadLibrary() once at program startup, from a single
 *   thread, before any other LF_* function.
 *
 * ============================================================================
 * ABI NOTE ON TP2P_UID (32-byte struct by value)
 * ============================================================================
 * On x86-64 (System V AMD64 and Microsoft x64), a >16-byte aggregate is
 * classified MEMORY by the psABI and is therefore:
 *
 *   - passed on the stack when it is an argument, and
 *   - returned via the SRet hidden-pointer convention when it is a
 *     return value.
 *
 * FPC's `array[0..31] of Byte` falls into the same MEMORY class, so a
 * struct with a single 32-byte array member is intended to be
 * ABI-compatible with the Pascal side for the ARGUMENT-role positions.
 *
 * {!!!!!  LF_Get_P2P_UID IS THE EXCEPTION  !!!!!}
 * LF_Get_P2P_UID does NOT return the 32-byte UID by value. Its Pascal
 * signature is:
 *
 *     function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
 *
 * i.e. it returns a POINTER (^TUID___). The ctypes / C representation
 * for that one function is therefore `const TP2P_UID*`. The pointer is
 * allocated by the Pascal side via New and scheduled for automatic
 * release about 5 seconds later (DelayFreeMem(5.0, ...)). The C wrapper
 * simply forwards this pointer to the caller and does NOT copy, cache,
 * or free it.
 *
 * See LingoFuse.h "UID TYPE" for the full rationale.
 */

#define _CRT_SECURE_NO_WARNINGS
#include "LingoFuse.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

 /* ============================================================================
  * Platform-specific dynamic loading
  * ============================================================================ */

#if defined(_WIN32)
#  include <windows.h>
#  define LIB_HANDLE              HMODULE
#  define LOAD_LIBRARY(path)      LoadLibraryA(path)
#  define GET_PROC_ADDRESS(h, n)  GetProcAddress((HMODULE)(h), (n))
#  define FREE_LIBRARY(h)         FreeLibrary((HMODULE)(h))
#  define PATH_SEPARATOR          '\\'
#  ifndef PATH_MAX
#    ifdef MAX_PATH
#      define PATH_MAX MAX_PATH
#    else
#      define PATH_MAX 260
#    endif
#  endif
#elif defined(__APPLE__)
#  include <dlfcn.h>
#  include <unistd.h>
#  include <limits.h>
#  include <mach-o/dyld.h>
#  define LIB_HANDLE              void*
#  define LOAD_LIBRARY(path)      dlopen(path, RTLD_LAZY)
#  define GET_PROC_ADDRESS(h, n)  dlsym(h, n)
#  define FREE_LIBRARY(h)         dlclose(h)
#  define PATH_SEPARATOR          '/'
#  ifndef PATH_MAX
#    define PATH_MAX 1024
#  endif
#else
#  include <dlfcn.h>
#  include <unistd.h>
#  include <limits.h>
#  include <sys/types.h>
#  define LIB_HANDLE              void*
#  define LOAD_LIBRARY(path)      dlopen(path, RTLD_LAZY)
#  define GET_PROC_ADDRESS(h, n)  dlsym(h, n)
#  define FREE_LIBRARY(h)         dlclose(h)
#  define PATH_SEPARATOR          '/'
#  ifndef PATH_MAX
#    define PATH_MAX 4096
#  endif
#endif

  /* ============================================================================
   * Global state
   * ============================================================================ */

static LIB_HANDLE g_hDll = NULL;
static int        g_loaded = 0;

/* ============================================================================
 * Function-pointer typedefs for the 59 exported functions
 * ============================================================================
 *
 * Grouped by role, matching the header declaration order. The typedef names
 * use the `fnLF_` prefix to avoid colliding with the public `LF_` symbols.
 *
 * {!!!!!  UID ROLES USE DIFFERENT TYPES  !!!!!}
 * ARGUMENT-role UIDs (input parameters to LF_UID_*, LF_Check_UID, etc.)
 * use `TP2P_UID` (the struct, passed by value). RETURN-role UID has exactly
 * one instance -- LF_Get_P2P_UID -- and uses `const TP2P_UID*` (a pointer).
 *
 *   ARGUMENT role: `TP2P_UID`                (by value; array-in-struct)
 *   RETURN   role: `const TP2P_UID*`         (pointer; LF_Get_P2P_UID only)
 *
 * DO NOT change the return-role typedef to `TP2P_UID`, and DO NOT change
 * the argument-role typedefs to pointers. The two are different positions
 * in the ABI.
 */

 /* ---- Data handles ---- */

typedef TDataHnd(LF_CDECL* fnLF_CreateData)(const char*);
typedef TDataHnd(LF_CDECL* fnLF_CreateData_Permanent)(const char*);
typedef void        (LF_CDECL* fnLF_FreeData)(TDataHnd);
typedef void* (LF_CDECL* fnLF_GetBuffer)(TDataHnd);
typedef int64_t(LF_CDECL* fnLF_WriteBuffer)(TDataHnd, const void*, int64_t);
typedef int64_t(LF_CDECL* fnLF_ReadBuffer)(TDataHnd, void*, int64_t);
typedef int64_t(LF_CDECL* fnLF_GetPos)(TDataHnd);
typedef void        (LF_CDECL* fnLF_SetPos)(TDataHnd, int64_t);
typedef int64_t(LF_CDECL* fnLF_GetSize)(TDataHnd);
typedef void        (LF_CDECL* fnLF_SetSize)(TDataHnd, int64_t);

/* ---- Data handle identity accessors ----
 *
 * LF_Get_P2P_UID : RETURN-role pointer. The Pascal side returns
 *                  PP2P_UID___ (^TUID___), i.e. a pointer to a
 *                  transient 32-byte UID released by the library
 *                  after ~5 seconds.
 *
 * LF_Get_P2P_Name: c_char_p. The Pascal side returns a pointer to a
 *                  NUL-terminated UTF-8 string, also released after
 *                  ~5 seconds.
 */
typedef const TP2P_UID* (LF_CDECL* fnLF_Get_P2P_UID)(TDataHnd);
typedef const char* (LF_CDECL* fnLF_Get_P2P_Name)(TDataHnd);

/* ---- Application handles ---- */

typedef TAppHnd(LF_CDECL* fnLF_CreateApp)(const char*, const char*);
typedef void        (LF_CDECL* fnLF_FreeApp)(TAppHnd);
typedef const char* (LF_CDECL* fnLF_Generate_AppName)(void);
typedef const char* (LF_CDECL* fnLF_Get_AppName)(TAppHnd);
typedef int         (LF_CDECL* fnLF_BindApp)(TAppHnd);

/* ---- API registration (app-bound) ---- */

typedef int         (LF_CDECL* fnLF_RegisterCall)(TAppHnd, const char*,
    const char*, void*,
    LF_CallFunc);
typedef int         (LF_CDECL* fnLF_RegisterNotify)(TAppHnd, const char*,
    const char*, void*,
    LF_NotifyFunc);
typedef int         (LF_CDECL* fnLF_Unregister)(TAppHnd, const char*);

/* ---- API registration (process-wide P2P) ---- */

typedef int         (LF_CDECL* fnLF_Register_P2P_Call)(const char*,
    const char*, void*,
    LF_CallFunc);
typedef int         (LF_CDECL* fnLF_Register_P2P_Notify)(const char*,
    const char*, void*,
    LF_NotifyFunc);
typedef int         (LF_CDECL* fnLF_Unregister_P2P)(const char*);

/* ---- Local execution ---- */

typedef TDataHnd(LF_CDECL* fnLF_LocalCall)(TAppHnd, TDataHnd);
typedef void        (LF_CDECL* fnLF_LocalNotify)(TAppHnd, TDataHnd);

/* ---- Network preparation ---- */

typedef int         (LF_CDECL* fnLF_PrepareService)(const char*, const char*);
typedef int         (LF_CDECL* fnLF_PrepareClient)(const char*, TAppHnd);
typedef void        (LF_CDECL* fnLF_ResetPrepare)(void);
typedef int         (LF_CDECL* fnLF_PrepareDone)(void);
typedef void        (LF_CDECL* fnLF_ExitMainThread)(void);

/* ---- Remote invocation (app-name) ---- */

typedef TDataHnd(LF_CDECL* fnLF_Call)(const char*, TDataHnd, uint64_t);
typedef int         (LF_CDECL* fnLF_Async_Call)(const char*, TDataHnd, void*,
    LF_AsyncCallOnResult);
typedef int         (LF_CDECL* fnLF_Async_Sequenced_Call)(const char*, TDataHnd,
    void*,
    LF_AsyncCallOnResult);
typedef void        (LF_CDECL* fnLF_Notify)(const char*, TDataHnd);
typedef void        (LF_CDECL* fnLF_Sequenced_Notify)(const char*, TDataHnd);

/* ---- Remote invocation (UID) ----
 *
 * The first parameter is an ARGUMENT-role UID: it uses `TP2P_UID` (the
 * struct, by value), matching the Pascal-side `array[0..31] of Byte`.
 */
typedef TDataHnd(LF_CDECL* fnLF_UID_Call)(TP2P_UID, TDataHnd, uint64_t);
typedef int         (LF_CDECL* fnLF_UID_Async_Call)(TP2P_UID, TDataHnd, void*,
    LF_AsyncCallOnResult);
typedef int         (LF_CDECL* fnLF_UID_Async_Sequenced_Call)(TP2P_UID, TDataHnd,
    void*,
    LF_AsyncCallOnResult);
typedef void        (LF_CDECL* fnLF_UID_Notify)(TP2P_UID, TDataHnd);
typedef void        (LF_CDECL* fnLF_UID_Sequenced_Notify)(TP2P_UID, TDataHnd);

/* ---- Remote invocation (P2PName) ---- */

typedef TDataHnd(LF_CDECL* fnLF_P2PNAME_Call)(const char*, TDataHnd, uint64_t);
typedef int         (LF_CDECL* fnLF_P2PNAME_Async_Call)(const char*, TDataHnd,
    void*,
    LF_AsyncCallOnResult);
typedef int         (LF_CDECL* fnLF_P2PNAME_Async_Sequenced_Call)(
    const char*, TDataHnd, void*, LF_AsyncCallOnResult);
typedef void        (LF_CDECL* fnLF_P2PNAME_Notify)(const char*, TDataHnd);
typedef void        (LF_CDECL* fnLF_P2PNAME_Sequenced_Notify)(const char*, TDataHnd);

/* ---- Queries ---- */

typedef int         (LF_CDECL* fnLF_CheckMainThread)(void);
typedef int         (LF_CDECL* fnLF_CheckApp)(const char*);
typedef int         (LF_CDECL* fnLF_CheckApi)(const char*, const char*);

/* ---- Queries (UID / P2PName) ----
 *
 * The UID parameters are ARGUMENT-role (`TP2P_UID`, by value).
 */
typedef int         (LF_CDECL* fnLF_Check_UID)(TP2P_UID);
typedef int         (LF_CDECL* fnLF_Check_UID_Api)(TP2P_UID, const char*);
typedef int         (LF_CDECL* fnLF_Check_P2PNAME)(const char*);
typedef int         (LF_CDECL* fnLF_Check_P2PNAME_Api)(const char*, const char*);

/* ---- Options ---- */

typedef void        (LF_CDECL* fnLF_SetOption)(const char*, const char*);
typedef const char* (LF_CDECL* fnLF_GetOption)(const char*);

/* ---- Status ---- */

typedef int         (LF_CDECL* fnLF_GetStatusCount)(void);
typedef const char* (LF_CDECL* fnLF_GetStatus)(void);
typedef void        (LF_CDECL* fnLF_PostStatus)(const char*);

/* ---- Network events ---- */

typedef void        (LF_CDECL* fnLF_Set_Network_Event)(LF_NetworkEventFunc,
    LF_NetworkEventFunc);

/* ---- Shutdown ---- */

typedef void        (LF_CDECL* fnLF_Shutdown)(void);

/* ============================================================================
 * Static function pointers
 * ============================================================================
 *
 * One per exported symbol. Grouped and ordered to match LF_LoadLibrary's
 * RESOLVE sequence (see below), so that a visual diff between the two
 * stays trivial.
 */

 /* ---- Data handles ---- */
static fnLF_CreateData           pLF_CreateData = NULL;
static fnLF_CreateData_Permanent pLF_CreateData_Permanent = NULL;
static fnLF_FreeData             pLF_FreeData = NULL;
static fnLF_GetBuffer            pLF_GetBuffer = NULL;
static fnLF_WriteBuffer          pLF_WriteBuffer = NULL;
static fnLF_ReadBuffer           pLF_ReadBuffer = NULL;
static fnLF_GetPos               pLF_GetPos = NULL;
static fnLF_SetPos               pLF_SetPos = NULL;
static fnLF_GetSize              pLF_GetSize = NULL;
static fnLF_SetSize              pLF_SetSize = NULL;
static fnLF_Get_P2P_UID          pLF_Get_P2P_UID = NULL;
static fnLF_Get_P2P_Name         pLF_Get_P2P_Name = NULL;

/* ---- Application handles ---- */
static fnLF_CreateApp            pLF_CreateApp = NULL;
static fnLF_FreeApp              pLF_FreeApp = NULL;
static fnLF_Generate_AppName     pLF_Generate_AppName = NULL;
static fnLF_Get_AppName          pLF_Get_AppName = NULL;
static fnLF_BindApp              pLF_BindApp = NULL;

/* ---- API registration (app-bound) ---- */
static fnLF_RegisterCall         pLF_RegisterCall = NULL;
static fnLF_RegisterNotify       pLF_RegisterNotify = NULL;
static fnLF_Unregister           pLF_Unregister = NULL;

/* ---- API registration (process-wide P2P) ---- */
static fnLF_Register_P2P_Call    pLF_Register_P2P_Call = NULL;
static fnLF_Register_P2P_Notify  pLF_Register_P2P_Notify = NULL;
static fnLF_Unregister_P2P       pLF_Unregister_P2P = NULL;

/* ---- Local execution ---- */
static fnLF_LocalCall            pLF_LocalCall = NULL;
static fnLF_LocalNotify          pLF_LocalNotify = NULL;

/* ---- Network preparation ---- */
static fnLF_PrepareService       pLF_PrepareService = NULL;
static fnLF_PrepareClient        pLF_PrepareClient = NULL;
static fnLF_ResetPrepare         pLF_ResetPrepare = NULL;
static fnLF_PrepareDone          pLF_PrepareDone = NULL;
static fnLF_ExitMainThread       pLF_ExitMainThread = NULL;

/* ---- Remote invocation (app-name) ---- */
static fnLF_Call                 pLF_Call = NULL;
static fnLF_Async_Call           pLF_Async_Call = NULL;
static fnLF_Async_Sequenced_Call pLF_Async_Sequenced_Call = NULL;
static fnLF_Notify               pLF_Notify = NULL;
static fnLF_Sequenced_Notify     pLF_Sequenced_Notify = NULL;

/* ---- Remote invocation (UID) ---- */
static fnLF_UID_Call             pLF_UID_Call = NULL;
static fnLF_UID_Async_Call       pLF_UID_Async_Call = NULL;
static fnLF_UID_Async_Sequenced_Call pLF_UID_Async_Sequenced_Call = NULL;
static fnLF_UID_Notify           pLF_UID_Notify = NULL;
static fnLF_UID_Sequenced_Notify pLF_UID_Sequenced_Notify = NULL;

/* ---- Remote invocation (P2PName) ---- */
static fnLF_P2PNAME_Call         pLF_P2PNAME_Call = NULL;
static fnLF_P2PNAME_Async_Call   pLF_P2PNAME_Async_Call = NULL;
static fnLF_P2PNAME_Async_Sequenced_Call
pLF_P2PNAME_Async_Sequenced_Call = NULL;
static fnLF_P2PNAME_Notify       pLF_P2PNAME_Notify = NULL;
static fnLF_P2PNAME_Sequenced_Notify
pLF_P2PNAME_Sequenced_Notify = NULL;

/* ---- Queries ---- */
static fnLF_CheckMainThread      pLF_CheckMainThread = NULL;
static fnLF_CheckApp             pLF_CheckApp = NULL;
static fnLF_CheckApi             pLF_CheckApi = NULL;

/* ---- Queries (UID / P2PName) ---- */
static fnLF_Check_UID            pLF_Check_UID = NULL;
static fnLF_Check_UID_Api        pLF_Check_UID_Api = NULL;
static fnLF_Check_P2PNAME        pLF_Check_P2PNAME = NULL;
static fnLF_Check_P2PNAME_Api    pLF_Check_P2PNAME_Api = NULL;

/* ---- Options ---- */
static fnLF_SetOption            pLF_SetOption = NULL;
static fnLF_GetOption            pLF_GetOption = NULL;

/* ---- Status ---- */
static fnLF_GetStatusCount       pLF_GetStatusCount = NULL;
static fnLF_GetStatus            pLF_GetStatus = NULL;
static fnLF_PostStatus           pLF_PostStatus = NULL;

/* ---- Network events ---- */
static fnLF_Set_Network_Event    pLF_Set_Network_Event = NULL;

/* ---- Shutdown ---- */
static fnLF_Shutdown             pLF_Shutdown = NULL;

/* ============================================================================
 * Helper macros
 * ============================================================================ */

 /*
  * RESOLVE: resolve one exported symbol into its static pointer.
  * On failure, releases the library handle and returns 0 from the enclosing
  * function (LF_LoadLibrary).
  */
#define RESOLVE(func)                                                        \
    do {                                                                     \
        pLF_##func = (fnLF_##func)GET_PROC_ADDRESS(g_hDll, "LF_" #func);     \
        if (!pLF_##func) {                                                   \
            fprintf(stderr,                                                  \
                    "LingoFuse: Failed to resolve symbol LF_" #func "\n");   \
            FREE_LIBRARY(g_hDll);                                            \
            g_hDll = NULL;                                                   \
            return 0;                                                        \
        }                                                                    \
    } while (0)

  /* ZERO: reset one static pointer to NULL. */
#define ZERO(func) pLF_##func = NULL

/* CHECK_LOADED_RET: guard for functions that return a value. */
#define CHECK_LOADED_RET(func, ret)                                          \
    do {                                                                     \
        if (!g_loaded || !pLF_##func) {                                      \
            fprintf(stderr,                                                  \
                    "LingoFuse: " #func " called before LF_LoadLibrary\n");  \
            return ret;                                                      \
        }                                                                    \
    } while (0)

/* CHECK_LOADED_VOID: guard for functions that return void. */
#define CHECK_LOADED_VOID(func)                                              \
    do {                                                                     \
        if (!g_loaded || !pLF_##func) {                                      \
            fprintf(stderr,                                                  \
                    "LingoFuse: " #func " called before LF_LoadLibrary\n");  \
            return;                                                          \
        }                                                                    \
    } while (0)

/* ============================================================================
 * Helper: retrieve the directory containing the current executable
 * ----------------------------------------------------------------------------
 * Returns 1 on success, 0 on failure. On success, @p out_dir holds a
 * null-terminated path with no trailing separator.
 * ============================================================================ */

static int GetExeDirectory(char* out_dir, size_t out_size) {
    char full_path[PATH_MAX];

    if (out_dir == NULL || out_size == 0) return 0;
    memset(full_path, 0, sizeof(full_path));

#if defined(_WIN32)
    {
        DWORD n = GetModuleFileNameA(NULL, full_path,
            (DWORD)(sizeof(full_path) - 1));
        if (n == 0 || n >= (DWORD)sizeof(full_path)) return 0;
        full_path[n] = '\0';
    }
#elif defined(__APPLE__)
    {
        /*
         * macOS has no /proc filesystem. Use _NSGetExecutablePath instead.
         * The function may return a path with symlinks; that is acceptable
         * for locating a shared library next to the executable.
         */
        uint32_t sz = (uint32_t)sizeof(full_path);
        if (_NSGetExecutablePath(full_path, &sz) != 0) {
            return 0;   /* buffer too small */
        }
        full_path[sizeof(full_path) - 1] = '\0';
    }
#else
    {
        /*
         * Linux / BSD: resolve /proc/self/exe via readlink. Note that
         * readlink does not append a NUL byte, so we must do it manually.
         */
        ssize_t n = readlink("/proc/self/exe",
            full_path, sizeof(full_path) - 1);
        if (n <= 0) return 0;
        full_path[n] = '\0';
    }
#endif

    /* Locate the last path separator ('/' or '\\'). */
    {
        char* last_sep = strrchr(full_path, '/');
        if (last_sep == NULL) last_sep = strrchr(full_path, '\\');
        if (last_sep == NULL) return 0;

        {
            size_t dirlen = (size_t)(last_sep - full_path);
            if (dirlen + 1 > out_size) return 0;
            memcpy(out_dir, full_path, dirlen);
            out_dir[dirlen] = '\0';
        }
    }

    return 1;
}

/* ============================================================================
 * Library loading / unloading
 * ============================================================================ */

int LF_LoadLibrary(void) {
    if (g_loaded) return 1;

    {
        char exe_dir[PATH_MAX];
        char dll_path[PATH_MAX];
        const char* dll_name;

        memset(exe_dir, 0, sizeof(exe_dir));
        memset(dll_path, 0, sizeof(dll_path));

        /*
         * Select the library file name.
         *
         * On Windows we decide between 64-bit and 32-bit at RUNTIME using
         * sizeof(void*), because compile-time macros (_WIN64, __x86_64__)
         * can be wrong under cross-compilation. On Unix systems the name
         * is fixed.
         */
#if defined(_WIN32)
        dll_name = (sizeof(void*) == 8) ? "LingoFuse64.dll"
            : "LingoFuse32.dll";
#elif defined(__APPLE__)
        dll_name = "liblingofuse.dylib";
#else
        dll_name = "liblingofuse.so";
#endif

        /*
         * First attempt: load from the directory containing the executable.
         * This allows shipping the library alongside the application without
         * modifying the system search path.
         */
        if (GetExeDirectory(exe_dir, sizeof(exe_dir))) {
            size_t dirlen = strlen(exe_dir);
            size_t namelen = strlen(dll_name);

            if (dirlen + 1 + namelen + 1 <= sizeof(dll_path)) {
                /* Manually concatenate to avoid snprintf portability issues. */
                memcpy(dll_path, exe_dir, dirlen);
                dll_path[dirlen] = PATH_SEPARATOR;
                memcpy(dll_path + dirlen + 1, dll_name, namelen + 1);
                g_hDll = LOAD_LIBRARY(dll_path);
            }
        }

        /* Second attempt: rely on the system search path. */
        if (!g_hDll) {
            g_hDll = LOAD_LIBRARY(dll_name);
            if (!g_hDll) {
                fprintf(stderr, "LingoFuse: Failed to load %s\n", dll_name);
                return 0;
            }
        }
    }

    /* ---- Resolve all 59 exported functions ---- */

    /* Data handles (12) */
    RESOLVE(CreateData);
    RESOLVE(CreateData_Permanent);
    RESOLVE(FreeData);
    RESOLVE(GetBuffer);
    RESOLVE(WriteBuffer);
    RESOLVE(ReadBuffer);
    RESOLVE(GetPos);
    RESOLVE(SetPos);
    RESOLVE(GetSize);
    RESOLVE(SetSize);
    RESOLVE(Get_P2P_UID);
    RESOLVE(Get_P2P_Name);

    /* Application handles (5) */
    RESOLVE(CreateApp);
    RESOLVE(FreeApp);
    RESOLVE(Generate_AppName);
    RESOLVE(Get_AppName);
    RESOLVE(BindApp);

    /* API registration, app-bound (3) */
    RESOLVE(RegisterCall);
    RESOLVE(RegisterNotify);
    RESOLVE(Unregister);

    /* API registration, process-wide P2P (3) */
    RESOLVE(Register_P2P_Call);
    RESOLVE(Register_P2P_Notify);
    RESOLVE(Unregister_P2P);

    /* Local execution (2) */
    RESOLVE(LocalCall);
    RESOLVE(LocalNotify);

    /* Network preparation (5) */
    RESOLVE(PrepareService);
    RESOLVE(PrepareClient);
    RESOLVE(ResetPrepare);
    RESOLVE(PrepareDone);
    RESOLVE(ExitMainThread);

    /* Remote invocation, app-name (5) */
    RESOLVE(Call);
    RESOLVE(Async_Call);
    RESOLVE(Async_Sequenced_Call);
    RESOLVE(Notify);
    RESOLVE(Sequenced_Notify);

    /* Remote invocation, UID (5) */
    RESOLVE(UID_Call);
    RESOLVE(UID_Async_Call);
    RESOLVE(UID_Async_Sequenced_Call);
    RESOLVE(UID_Notify);
    RESOLVE(UID_Sequenced_Notify);

    /* Remote invocation, P2PName (5) */
    RESOLVE(P2PNAME_Call);
    RESOLVE(P2PNAME_Async_Call);
    RESOLVE(P2PNAME_Async_Sequenced_Call);
    RESOLVE(P2PNAME_Notify);
    RESOLVE(P2PNAME_Sequenced_Notify);

    /* Queries (7) */
    RESOLVE(CheckMainThread);
    RESOLVE(CheckApp);
    RESOLVE(CheckApi);
    RESOLVE(Check_UID);
    RESOLVE(Check_UID_Api);
    RESOLVE(Check_P2PNAME);
    RESOLVE(Check_P2PNAME_Api);

    /* Options (2) */
    RESOLVE(SetOption);
    RESOLVE(GetOption);

    /* Status (3) */
    RESOLVE(GetStatusCount);
    RESOLVE(GetStatus);
    RESOLVE(PostStatus);

    /* Network events (1) */
    RESOLVE(Set_Network_Event);

    /* Shutdown (1) */
    RESOLVE(Shutdown);

    g_loaded = 1;
    return 1;
}

void LF_FreeLibrary(void) {
    if (g_hDll) {
        FREE_LIBRARY(g_hDll);
        g_hDll = NULL;
    }

    /* Clear all function pointers to prevent use-after-unload. */

    /* Data handles */
    ZERO(CreateData);
    ZERO(CreateData_Permanent);
    ZERO(FreeData);
    ZERO(GetBuffer);
    ZERO(WriteBuffer);
    ZERO(ReadBuffer);
    ZERO(GetPos);
    ZERO(SetPos);
    ZERO(GetSize);
    ZERO(SetSize);
    ZERO(Get_P2P_UID);
    ZERO(Get_P2P_Name);

    /* Application handles */
    ZERO(CreateApp);
    ZERO(FreeApp);
    ZERO(Generate_AppName);
    ZERO(Get_AppName);
    ZERO(BindApp);

    /* API registration, app-bound */
    ZERO(RegisterCall);
    ZERO(RegisterNotify);
    ZERO(Unregister);

    /* API registration, process-wide P2P */
    ZERO(Register_P2P_Call);
    ZERO(Register_P2P_Notify);
    ZERO(Unregister_P2P);

    /* Local execution */
    ZERO(LocalCall);
    ZERO(LocalNotify);

    /* Network preparation */
    ZERO(PrepareService);
    ZERO(PrepareClient);
    ZERO(ResetPrepare);
    ZERO(PrepareDone);
    ZERO(ExitMainThread);

    /* Remote invocation, app-name */
    ZERO(Call);
    ZERO(Async_Call);
    ZERO(Async_Sequenced_Call);
    ZERO(Notify);
    ZERO(Sequenced_Notify);

    /* Remote invocation, UID */
    ZERO(UID_Call);
    ZERO(UID_Async_Call);
    ZERO(UID_Async_Sequenced_Call);
    ZERO(UID_Notify);
    ZERO(UID_Sequenced_Notify);

    /* Remote invocation, P2PName */
    ZERO(P2PNAME_Call);
    ZERO(P2PNAME_Async_Call);
    ZERO(P2PNAME_Async_Sequenced_Call);
    ZERO(P2PNAME_Notify);
    ZERO(P2PNAME_Sequenced_Notify);

    /* Queries */
    ZERO(CheckMainThread);
    ZERO(CheckApp);
    ZERO(CheckApi);
    ZERO(Check_UID);
    ZERO(Check_UID_Api);
    ZERO(Check_P2PNAME);
    ZERO(Check_P2PNAME_Api);

    /* Options */
    ZERO(SetOption);
    ZERO(GetOption);

    /* Status */
    ZERO(GetStatusCount);
    ZERO(GetStatus);
    ZERO(PostStatus);

    /* Network events */
    ZERO(Set_Network_Event);

    /* Shutdown */
    ZERO(Shutdown);

    g_loaded = 0;
}

/* ============================================================================
 * DATA HANDLE - forwarders
 * ============================================================================ */

TDataHnd LF_CreateData(const char* method_name) {
    if (method_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_CreateData: NULL method_name\n");
        return NULL;
    }
    CHECK_LOADED_RET(CreateData, NULL);
    return pLF_CreateData(method_name);
}

TDataHnd LF_CreateData_Permanent(const char* method_name) {
    if (method_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_CreateData_Permanent: NULL method_name\n");
        return NULL;
    }
    CHECK_LOADED_RET(CreateData_Permanent, NULL);
    return pLF_CreateData_Permanent(method_name);
}

void LF_FreeData(TDataHnd hnd) {
    CHECK_LOADED_VOID(FreeData);
    pLF_FreeData(hnd);
}

void* LF_GetBuffer(TDataHnd hnd) {
    CHECK_LOADED_RET(GetBuffer, NULL);
    return pLF_GetBuffer(hnd);
}

int64_t LF_WriteBuffer(TDataHnd hnd, const void* buff, int64_t size) {
    CHECK_LOADED_RET(WriteBuffer, 0);
    return pLF_WriteBuffer(hnd, buff, size);
}

int64_t LF_ReadBuffer(TDataHnd hnd, void* buff, int64_t size) {
    CHECK_LOADED_RET(ReadBuffer, 0);
    return pLF_ReadBuffer(hnd, buff, size);
}

int64_t LF_GetPos(TDataHnd hnd) {
    CHECK_LOADED_RET(GetPos, 0);
    return pLF_GetPos(hnd);
}

void LF_SetPos(TDataHnd hnd, int64_t pos) {
    CHECK_LOADED_VOID(SetPos);
    pLF_SetPos(hnd, pos);
}

int64_t LF_GetSize(TDataHnd hnd) {
    CHECK_LOADED_RET(GetSize, 0);
    return pLF_GetSize(hnd);
}

void LF_SetSize(TDataHnd hnd, int64_t size) {
    CHECK_LOADED_VOID(SetSize);
    pLF_SetSize(hnd, size);
}

/* ----------------------------------------------------------------------------
 * LF_Get_P2P_UID - RETURN-role pointer
 * ----------------------------------------------------------------------------
 *
 * The Pascal signature is:
 *
 *     function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
 *
 * i.e. it returns a pointer to a 32-byte UID, not the value itself. The
 * pointer is allocated by the Pascal side via New and is scheduled for
 * automatic release about 5 seconds later (DelayFreeMem(5.0, ...)).
 *
 * {!!!!!  SIDE DATA SEMANTICS  !!!!!}
 *
 * The value behind the pointer is the sender's UID as written into the
 * payload header by the SENDER'S transport layer (Pascal side:
 * TC40_LF_Client.Send_* -> TMemory_Param_Tool.Rebuild_UID_and_P2PName).
 * It is NOT a property of the handle itself.
 *
 * Therefore this function is only meaningful for INPUT handles:
 *
 *     VALID    -- the `input` (or `param`) argument of a registered Call
 *                 or Notify callback, or the input of a local call.
 *     INVALID  -- an OUTPUT handle, or a caller-created handle. The Pascal
 *                 side logs a warning and returns a zero-filled UID.
 *
 * The C wrapper simply forwards the pointer. It does NOT:
 *   - copy the UID into a caller buffer,
 *   - cache the pointer,
 *   - free the pointer.
 *
 * The caller MUST copy the 32 bytes immediately if it wants to retain
 * them, MUST NOT free the pointer, and MUST NOT retain the pointer past
 * the ~5-second validity window.
 *
 * On a load-order failure (library not loaded), the wrapper returns NULL
 * and prints a diagnostic. This is the only case in which the wrapper
 * itself returns NULL; a valid pointer is forwarded verbatim.
 * ------------------------------------------------------------------------- */
const TP2P_UID* LF_Get_P2P_UID(TDataHnd hnd) {
    if (!g_loaded || !pLF_Get_P2P_UID) {
        fprintf(stderr,
            "LingoFuse: Get_P2P_UID called before LF_LoadLibrary\n");
        return NULL;
    }
    return pLF_Get_P2P_UID(hnd);
}

const char* LF_Get_P2P_Name(TDataHnd hnd) {
    CHECK_LOADED_RET(Get_P2P_Name, "");
    return pLF_Get_P2P_Name(hnd);
}

/* ============================================================================
 * APPLICATION HANDLE - forwarders
 * ============================================================================ */

TAppHnd LF_CreateApp(const char* app_name, const char* desc) {
    if (app_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_CreateApp: NULL app_name\n");
        return NULL;
    }
    /* Treat NULL description as an empty string, matching Pascal semantics. */
    if (desc == NULL) desc = "";
    CHECK_LOADED_RET(CreateApp, NULL);
    return pLF_CreateApp(app_name, desc);
}

void LF_FreeApp(TAppHnd app_hnd) {
    CHECK_LOADED_VOID(FreeApp);
    pLF_FreeApp(app_hnd);
}

const char* LF_Generate_AppName(void) {
    CHECK_LOADED_RET(Generate_AppName, "");
    return pLF_Generate_AppName();
}

const char* LF_Get_AppName(TAppHnd app_hnd) {
    CHECK_LOADED_RET(Get_AppName, "");
    return pLF_Get_AppName(app_hnd);
}

int LF_BindApp(TAppHnd app_hnd) {
    CHECK_LOADED_RET(BindApp, 0);
    return pLF_BindApp(app_hnd);
}

/* ============================================================================
 * API REGISTRATION - forwarders
 * ============================================================================ */

int LF_RegisterCall(TAppHnd app_hnd,
    const char* method_name,
    const char* desc,
    void* trigger,
    LF_CallFunc on_call) {
    if (method_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_RegisterCall: NULL method_name\n");
        return 0;
    }
    if (desc == NULL) desc = "";
    CHECK_LOADED_RET(RegisterCall, 0);
    return pLF_RegisterCall(app_hnd, method_name, desc, trigger, on_call);
}

int LF_RegisterNotify(TAppHnd app_hnd,
    const char* method_name,
    const char* desc,
    void* trigger,
    LF_NotifyFunc on_notify) {
    if (method_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_RegisterNotify: NULL method_name\n");
        return 0;
    }
    if (desc == NULL) desc = "";
    CHECK_LOADED_RET(RegisterNotify, 0);
    return pLF_RegisterNotify(app_hnd, method_name, desc, trigger, on_notify);
}

int LF_Unregister(TAppHnd app_hnd, const char* method_name) {
    if (method_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_Unregister: NULL method_name\n");
        return 0;
    }
    CHECK_LOADED_RET(Unregister, 0);
    return pLF_Unregister(app_hnd, method_name);
}

/* ---- Process-wide P2P registration ---- */

int LF_Register_P2P_Call(const char* method_name,
    const char* desc,
    void* trigger,
    LF_CallFunc on_call) {
    if (method_name == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_Register_P2P_Call: NULL method_name\n");
        return 0;
    }
    if (desc == NULL) desc = "";
    CHECK_LOADED_RET(Register_P2P_Call, 0);
    return pLF_Register_P2P_Call(method_name, desc, trigger, on_call);
}

int LF_Register_P2P_Notify(const char* method_name,
    const char* desc,
    void* trigger,
    LF_NotifyFunc on_notify) {
    if (method_name == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_Register_P2P_Notify: NULL method_name\n");
        return 0;
    }
    if (desc == NULL) desc = "";
    CHECK_LOADED_RET(Register_P2P_Notify, 0);
    return pLF_Register_P2P_Notify(method_name, desc, trigger, on_notify);
}

int LF_Unregister_P2P(const char* method_name) {
    if (method_name == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_Unregister_P2P: NULL method_name\n");
        return 0;
    }
    CHECK_LOADED_RET(Unregister_P2P, 0);
    return pLF_Unregister_P2P(method_name);
}

/* ============================================================================
 * LOCAL EXECUTION - forwarders
 * ============================================================================ */

TDataHnd LF_LocalCall(TAppHnd app_hnd, TDataHnd param) {
    CHECK_LOADED_RET(LocalCall, NULL);
    return pLF_LocalCall(app_hnd, param);
}

void LF_LocalNotify(TAppHnd app_hnd, TDataHnd param) {
    CHECK_LOADED_VOID(LocalNotify);
    pLF_LocalNotify(app_hnd, param);
}

/* ============================================================================
 * NETWORK PREPARATION - forwarders
 * ============================================================================ */

void LF_ResetPrepare(void) {
    CHECK_LOADED_VOID(ResetPrepare);
    pLF_ResetPrepare();
}

int LF_PrepareService(const char* listening_addr, const char* physics_addr) {
    if (listening_addr == NULL || physics_addr == NULL) {
        fprintf(stderr, "LingoFuse: LF_PrepareService: NULL address\n");
        return 0;
    }
    CHECK_LOADED_RET(PrepareService, 0);
    return pLF_PrepareService(listening_addr, physics_addr);
}

int LF_PrepareClient(const char* physics_addr, TAppHnd app_hnd) {
    if (physics_addr == NULL) {
        fprintf(stderr, "LingoFuse: LF_PrepareClient: NULL physics_addr\n");
        return 0;
    }
    CHECK_LOADED_RET(PrepareClient, 0);
    return pLF_PrepareClient(physics_addr, app_hnd);
}

int LF_PrepareDone(void) {
    CHECK_LOADED_RET(PrepareDone, 0);
    return pLF_PrepareDone();
}

void LF_ExitMainThread(void) {
    CHECK_LOADED_VOID(ExitMainThread);
    pLF_ExitMainThread();
}

/* ============================================================================
 * REMOTE INVOCATION - app-name addressing
 * ============================================================================ */

TDataHnd LF_Call(const char* app_name, TDataHnd param, uint64_t timeout_ms) {
    if (app_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_Call: NULL app_name\n");
        return NULL;
    }
    CHECK_LOADED_RET(Call, NULL);
    return pLF_Call(app_name, param, timeout_ms);
}

/*
 * Async call forwarders.
 *
 * The `data` pointer and the `on_result` callback are forwarded verbatim;
 * the C wrapper neither allocates nor inspects them. See LingoFuse.h for
 * the ownership contract of the `result` handle delivered to the callback.
 */
int LF_Async_Call(const char* app_name,
    TDataHnd param,
    void* data,
    LF_AsyncCallOnResult on_result) {
    if (app_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_Async_Call: NULL app_name\n");
        return 0;
    }
    if (on_result == NULL) {
        fprintf(stderr, "LingoFuse: LF_Async_Call: NULL on_result\n");
        return 0;
    }
    CHECK_LOADED_RET(Async_Call, 0);
    return pLF_Async_Call(app_name, param, data, on_result);
}

int LF_Async_Sequenced_Call(const char* app_name,
    TDataHnd param,
    void* data,
    LF_AsyncCallOnResult on_result) {
    if (app_name == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_Async_Sequenced_Call: NULL app_name\n");
        return 0;
    }
    if (on_result == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_Async_Sequenced_Call: NULL on_result\n");
        return 0;
    }
    CHECK_LOADED_RET(Async_Sequenced_Call, 0);
    return pLF_Async_Sequenced_Call(app_name, param, data, on_result);
}

void LF_Notify(const char* app_name, TDataHnd param) {
    if (app_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_Notify: NULL app_name\n");
        return;
    }
    CHECK_LOADED_VOID(Notify);
    pLF_Notify(app_name, param);
}

void LF_Sequenced_Notify(const char* app_name, TDataHnd param) {
    if (app_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_Sequenced_Notify: NULL app_name\n");
        return;
    }
    CHECK_LOADED_VOID(Sequenced_Notify);
    pLF_Sequenced_Notify(app_name, param);
}

/* ============================================================================
 * REMOTE INVOCATION - UID addressing
 * ============================================================================
 *
 * The TP2P_UID argument is passed BY VALUE (ARGUMENT role). This is
 * required for ABI compatibility with the Pascal side. Do NOT convert
 * it to a pointer. See LingoFuse.h "UID TYPE" for the full rationale
 * on the two roles the same Pascal type plays on the C ABI.
 */

TDataHnd LF_UID_Call(TP2P_UID uid, TDataHnd param, uint64_t timeout_ms) {
    CHECK_LOADED_RET(UID_Call, NULL);
    return pLF_UID_Call(uid, param, timeout_ms);
}

int LF_UID_Async_Call(TP2P_UID uid,
    TDataHnd param,
    void* data,
    LF_AsyncCallOnResult on_result) {
    if (on_result == NULL) {
        fprintf(stderr, "LingoFuse: LF_UID_Async_Call: NULL on_result\n");
        return 0;
    }
    CHECK_LOADED_RET(UID_Async_Call, 0);
    return pLF_UID_Async_Call(uid, param, data, on_result);
}

int LF_UID_Async_Sequenced_Call(TP2P_UID uid,
    TDataHnd param,
    void* data,
    LF_AsyncCallOnResult on_result) {
    if (on_result == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_UID_Async_Sequenced_Call: NULL on_result\n");
        return 0;
    }
    CHECK_LOADED_RET(UID_Async_Sequenced_Call, 0);
    return pLF_UID_Async_Sequenced_Call(uid, param, data, on_result);
}

void LF_UID_Notify(TP2P_UID uid, TDataHnd param) {
    CHECK_LOADED_VOID(UID_Notify);
    pLF_UID_Notify(uid, param);
}

void LF_UID_Sequenced_Notify(TP2P_UID uid, TDataHnd param) {
    CHECK_LOADED_VOID(UID_Sequenced_Notify);
    pLF_UID_Sequenced_Notify(uid, param);
}

/* ============================================================================
 * REMOTE INVOCATION - P2PName addressing
 * ============================================================================ */

TDataHnd LF_P2PNAME_Call(const char* p2p_name,
    TDataHnd param,
    uint64_t timeout_ms) {
    if (p2p_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_P2PNAME_Call: NULL p2p_name\n");
        return NULL;
    }
    CHECK_LOADED_RET(P2PNAME_Call, NULL);
    return pLF_P2PNAME_Call(p2p_name, param, timeout_ms);
}

int LF_P2PNAME_Async_Call(const char* p2p_name,
    TDataHnd param,
    void* data,
    LF_AsyncCallOnResult on_result) {
    if (p2p_name == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_P2PNAME_Async_Call: NULL p2p_name\n");
        return 0;
    }
    if (on_result == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_P2PNAME_Async_Call: NULL on_result\n");
        return 0;
    }
    CHECK_LOADED_RET(P2PNAME_Async_Call, 0);
    return pLF_P2PNAME_Async_Call(p2p_name, param, data, on_result);
}

int LF_P2PNAME_Async_Sequenced_Call(const char* p2p_name,
    TDataHnd param,
    void* data,
    LF_AsyncCallOnResult on_result) {
    if (p2p_name == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_P2PNAME_Async_Sequenced_Call: NULL p2p_name\n");
        return 0;
    }
    if (on_result == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_P2PNAME_Async_Sequenced_Call: NULL on_result\n");
        return 0;
    }
    CHECK_LOADED_RET(P2PNAME_Async_Sequenced_Call, 0);
    return pLF_P2PNAME_Async_Sequenced_Call(p2p_name, param, data, on_result);
}

void LF_P2PNAME_Notify(const char* p2p_name, TDataHnd param) {
    if (p2p_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_P2PNAME_Notify: NULL p2p_name\n");
        return;
    }
    CHECK_LOADED_VOID(P2PNAME_Notify);
    pLF_P2PNAME_Notify(p2p_name, param);
}

void LF_P2PNAME_Sequenced_Notify(const char* p2p_name, TDataHnd param) {
    if (p2p_name == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_P2PNAME_Sequenced_Notify: NULL p2p_name\n");
        return;
    }
    CHECK_LOADED_VOID(P2PNAME_Sequenced_Notify);
    pLF_P2PNAME_Sequenced_Notify(p2p_name, param);
}

/* ============================================================================
 * QUERIES - forwarders
 * ============================================================================ */

int LF_CheckMainThread(void) {
    CHECK_LOADED_RET(CheckMainThread, 0);
    return pLF_CheckMainThread();
}

int LF_CheckApp(const char* app_name) {
    if (app_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_CheckApp: NULL app_name\n");
        return 0;
    }
    CHECK_LOADED_RET(CheckApp, 0);
    return pLF_CheckApp(app_name);
}

int LF_CheckApi(const char* app_name, const char* api_name) {
    if (app_name == NULL || api_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_CheckApi: NULL argument\n");
        return 0;
    }
    CHECK_LOADED_RET(CheckApi, 0);
    return pLF_CheckApi(app_name, api_name);
}

int LF_Check_UID(TP2P_UID uid) {
    CHECK_LOADED_RET(Check_UID, 0);
    return pLF_Check_UID(uid);
}

int LF_Check_UID_Api(TP2P_UID uid, const char* api_name) {
    if (api_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_Check_UID_Api: NULL api_name\n");
        return 0;
    }
    CHECK_LOADED_RET(Check_UID_Api, 0);
    return pLF_Check_UID_Api(uid, api_name);
}

int LF_Check_P2PNAME(const char* p2p_name) {
    if (p2p_name == NULL) {
        fprintf(stderr, "LingoFuse: LF_Check_P2PNAME: NULL p2p_name\n");
        return 0;
    }
    CHECK_LOADED_RET(Check_P2PNAME, 0);
    return pLF_Check_P2PNAME(p2p_name);
}

int LF_Check_P2PNAME_Api(const char* p2p_name, const char* api_name) {
    if (p2p_name == NULL || api_name == NULL) {
        fprintf(stderr,
            "LingoFuse: LF_Check_P2PNAME_Api: NULL argument\n");
        return 0;
    }
    CHECK_LOADED_RET(Check_P2PNAME_Api, 0);
    return pLF_Check_P2PNAME_Api(p2p_name, api_name);
}

/* ============================================================================
 * OPTIONS - forwarders
 * ============================================================================ */

void LF_SetOption(const char* option, const char* value) {
    if (option == NULL || value == NULL) {
        fprintf(stderr, "LingoFuse: LF_SetOption: NULL argument\n");
        return;
    }
    CHECK_LOADED_VOID(SetOption);
    pLF_SetOption(option, value);
}

const char* LF_GetOption(const char* option) {
    if (option == NULL) {
        fprintf(stderr, "LingoFuse: LF_GetOption: NULL option\n");
        return "";
    }
    CHECK_LOADED_RET(GetOption, "");
    return pLF_GetOption(option);
}

/* ============================================================================
 * STATUS AND DIAGNOSTICS - forwarders
 * ============================================================================ */

int LF_GetStatusCount(void) {
    CHECK_LOADED_RET(GetStatusCount, 0);
    return pLF_GetStatusCount();
}

const char* LF_GetStatus(void) {
    CHECK_LOADED_RET(GetStatus, "");
    return pLF_GetStatus();
}

void LF_PostStatus(const char* status) {
    if (status == NULL) {
        fprintf(stderr, "LingoFuse: LF_PostStatus: NULL status\n");
        return;
    }
    CHECK_LOADED_VOID(PostStatus);
    pLF_PostStatus(status);
}

/* ============================================================================
 * NETWORK EVENTS - forwarder
 * ============================================================================ */

void LF_Set_Network_Event(LF_NetworkEventFunc on_connect,
    LF_NetworkEventFunc on_disconnect) {
    CHECK_LOADED_VOID(Set_Network_Event);
    pLF_Set_Network_Event(on_connect, on_disconnect);
}

/* ============================================================================
 * SHUTDOWN - forwarder
 * ============================================================================ */

void LF_Shutdown(void) {
    CHECK_LOADED_VOID(Shutdown);
    pLF_Shutdown();
}

/* ============================================================================
 * HELPER FUNCTIONS
 * ----------------------------------------------------------------------------
 * Implemented on top of LF_WriteBuffer / LF_ReadBuffer / LF_GetBuffer /
 * LF_SetPos, matching Pascal semantics in lingofuse_import.pas.
 *
 * All integer helpers use little-endian byte order.
 * ============================================================================ */

 /* ---- Buffer offset ---- */

void* LF_GetBufferOffset(TDataHnd hnd, int64_t offset) {
    unsigned char* base;

    if (!g_loaded || !pLF_GetBuffer) return NULL;
    base = (unsigned char*)pLF_GetBuffer(hnd);
    if (base == NULL) return NULL;
    return base + offset;
}

/* ---- Atomic write helpers ---- */

int LF_WriteInt8(TDataHnd hnd, int8_t value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 1) == 1) ? 1 : 0;
}

int LF_WriteUInt8(TDataHnd hnd, uint8_t value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 1) == 1) ? 1 : 0;
}

int LF_WriteInt16(TDataHnd hnd, int16_t value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 2) == 2) ? 1 : 0;
}

int LF_WriteUInt16(TDataHnd hnd, uint16_t value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 2) == 2) ? 1 : 0;
}

int LF_WriteInt32(TDataHnd hnd, int32_t value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 4) == 4) ? 1 : 0;
}

int LF_WriteUInt32(TDataHnd hnd, uint32_t value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 4) == 4) ? 1 : 0;
}

int LF_WriteInt64(TDataHnd hnd, int64_t value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 8) == 8) ? 1 : 0;
}

int LF_WriteUInt64(TDataHnd hnd, uint64_t value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 8) == 8) ? 1 : 0;
}

int LF_WriteSingle(TDataHnd hnd, float value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 4) == 4) ? 1 : 0;
}

int LF_WriteDouble(TDataHnd hnd, double value) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    return (pLF_WriteBuffer(hnd, &value, 8) == 8) ? 1 : 0;
}

int LF_WriteString(TDataHnd hnd, const char* value) {
    size_t len;
    char nul = 0;

    if (value == NULL) return 0;
    if (!g_loaded || !pLF_WriteBuffer) return 0;

    len = strlen(value);

    /* 1. Write the UTF-8 content (may be empty). */
    if (len > 0) {
        if (pLF_WriteBuffer(hnd, value, (int64_t)len) != (int64_t)len) {
            return 0;
        }
    }

    /* 2. Append the null terminator (#0). */
    return (pLF_WriteBuffer(hnd, &nul, 1) == 1) ? 1 : 0;
}

int LF_WriteStringBytes(TDataHnd hnd, const void* data, int64_t length) {
    char nul = 0;

    if (length < 0) return 0;
    if (data == NULL && length > 0) return 0;
    if (!g_loaded || !pLF_WriteBuffer) return 0;

    if (length > 0) {
        if (pLF_WriteBuffer(hnd, data, length) != length) {
            return 0;
        }
    }

    /* Append the null terminator (#0), matching Pascal LF_WriteStringBytes. */
    return (pLF_WriteBuffer(hnd, &nul, 1) == 1) ? 1 : 0;
}

int LF_WriteUid(TDataHnd hnd, TP2P_UID uid) {
    if (!g_loaded || !pLF_WriteBuffer) return 0;
    /*
     * Fixed 32-byte write, no terminator. Matches Pascal's
     * `m64.WritePtr(@UID, SizeOf(TP2P_UID___))`.
     *
     * NOTE: `uid` is the ARGUMENT-role struct (by value). This is
     * unrelated to the LF_Get_P2P_UID return value, which is a pointer.
     */
    return (pLF_WriteBuffer(hnd, uid.bytes, 32) == 32) ? 1 : 0;
}

/* ---- Atomic read helpers ---- */

int LF_ReadInt8(TDataHnd hnd, int8_t* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 1) == 1) ? 1 : 0;
}

int LF_ReadUInt8(TDataHnd hnd, uint8_t* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 1) == 1) ? 1 : 0;
}

int LF_ReadInt16(TDataHnd hnd, int16_t* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 2) == 2) ? 1 : 0;
}

int LF_ReadUInt16(TDataHnd hnd, uint16_t* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 2) == 2) ? 1 : 0;
}

int LF_ReadInt32(TDataHnd hnd, int32_t* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 4) == 4) ? 1 : 0;
}

int LF_ReadUInt32(TDataHnd hnd, uint32_t* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 4) == 4) ? 1 : 0;
}

int LF_ReadInt64(TDataHnd hnd, int64_t* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 8) == 8) ? 1 : 0;
}

int LF_ReadUInt64(TDataHnd hnd, uint64_t* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 8) == 8) ? 1 : 0;
}

int LF_ReadSingle(TDataHnd hnd, float* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 4) == 4) ? 1 : 0;
}

int LF_ReadDouble(TDataHnd hnd, double* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out, 8) == 8) ? 1 : 0;
}

/*
 * Read a null-terminated UTF-8 string.
 *
 * Matches Pascal's fault-tolerant LF_ReadString exactly:
 *
 *   - If a #0 is found, copy the bytes before it; advance the cursor
 *     past the #0.
 *   - If no #0 is found before the end of the buffer, copy the entire
 *     remaining buffer; advance the cursor to (end + 1), i.e. one byte
 *     past the end of the buffer. The underlying library implicitly
 *     grows the buffer by one byte to accommodate this (identical to
 *     Pascal's LF_SetPos behavior).
 *   - If the cursor is already at or past the end of the buffer, or if
 *     @p buf is too small to hold the string plus a terminator, return 0
 *     and leave the cursor unchanged.
 *
 * This function does NOT validate UTF-8; the copied bytes are raw.
 */
int LF_ReadString(TDataHnd hnd, char* buf, size_t buf_size) {
    int64_t start;
    int64_t size;
    int64_t end;
    int64_t len;
    const unsigned char* base;

    if (buf == NULL || buf_size == 0) return 0;
    if (!g_loaded) return 0;
    if (!pLF_GetPos || !pLF_GetSize || !pLF_GetBuffer || !pLF_SetPos) {
        return 0;
    }

    start = pLF_GetPos(hnd);
    size = pLF_GetSize(hnd);
    if (start < 0 || start >= size) {
        buf[0] = '\0';
        return 0;
    }

    base = (const unsigned char*)pLF_GetBuffer(hnd);
    if (base == NULL) {
        buf[0] = '\0';
        return 0;
    }

    /* Scan forward until a #0 is found or the buffer ends. */
    end = start;
    while (end < size && base[end] != 0) {
        ++end;
    }
    len = end - start;

    /* Require room for @p len bytes plus a terminating #0. */
    if ((int64_t)buf_size <= len) {
        buf[0] = '\0';
        return 0;
    }

    if (len > 0) {
        memcpy(buf, base + start, (size_t)len);
    }
    buf[len] = '\0';

    /*
     * Advance the cursor. Matches Pascal LF_SetPos(Hnd, e + 1):
     * if the buffer had no #0, `end == size` and the cursor becomes
     * size + 1, causing the library to grow the buffer by one byte.
     */
    pLF_SetPos(hnd, end + 1);

    return 1;
}

/*
 * Read a byte sequence terminated by either a #0 or the end of the buffer.
 *
 * Matches Pascal's LF_ReadStringBytes exactly. Returns:
 *   >= 0 : number of bytes copied (0 for an empty string).
 *   -1   : failure (cursor at or past end of buffer, or destination too
 *          small). The cursor is left unchanged.
 */
int64_t LF_ReadStringBytes(TDataHnd hnd, void* buf, int64_t buf_size) {
    int64_t start;
    int64_t size;
    int64_t end;
    int64_t len;
    const unsigned char* base;

    if (buf_size < 0) return -1;
    if (buf == NULL && buf_size > 0) return -1;
    if (!g_loaded) return -1;
    if (!pLF_GetPos || !pLF_GetSize || !pLF_GetBuffer || !pLF_SetPos) {
        return -1;
    }

    start = pLF_GetPos(hnd);
    size = pLF_GetSize(hnd);
    if (start < 0 || start >= size) {
        return -1;
    }

    base = (const unsigned char*)pLF_GetBuffer(hnd);
    if (base == NULL) return -1;

    end = start;
    while (end < size && base[end] != 0) {
        ++end;
    }
    len = end - start;

    if (len > buf_size) {
        return -1;  /* destination too small; cursor unchanged */
    }

    if (len > 0) {
        memcpy(buf, base + start, (size_t)len);
    }

    /* Advance the cursor past the #0, or to (size + 1) if none was found. */
    pLF_SetPos(hnd, end + 1);

    return len;
}

/*
 * Read a 32-byte UID from the current position.
 *
 * Symmetric with LF_WriteUid. No terminator is consumed or appended.
 * On failure (fewer than 32 bytes available, or the library is not
 * loaded), @p out is left unmodified and 0 is returned. The cursor
 * position after a failed read is unspecified; callers that need a
 * defined position on failure should save/restore it themselves.
 *
 * NOTE: @p out uses the ARGUMENT-role `TP2P_UID*` (pointer to the
 * struct). This is unrelated to the LF_Get_P2P_UID return value, which
 * is a `const TP2P_UID*` pointing to the library-owned transient UID.
 */
int LF_ReadUid(TDataHnd hnd, TP2P_UID* out) {
    if (out == NULL) return 0;
    if (!g_loaded || !pLF_ReadBuffer) return 0;
    return (pLF_ReadBuffer(hnd, out->bytes, 32) == 32) ? 1 : 0;
}