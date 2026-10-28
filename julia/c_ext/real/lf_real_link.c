/*
 * lf_real_link.c - Dynamic linker for the real LingoFuse library.
 *
 * Satisfies the extern declarations in lf_shim.c by loading the real
 * LingoFuse shared library on first use and resolving the symbols via
 * GetProcAddress (Windows) or dlsym (POSIX).
 *
 * Symbols provided
 * ----------------
 *   Registration (App-bound)
 *       LF_RegisterCall
 *       LF_RegisterNotify
 *
 *   Registration (process-wide P2P)
 *       LF_Register_P2P_Call
 *       LF_Register_P2P_Notify
 *       LF_Unregister_P2P
 *
 *   Network events
 *       LF_Set_Network_Event
 *
 *   Handle I/O
 *       LF_GetSize
 *       LF_SetPos
 *       LF_ReadBuffer
 *       LF_WriteBuffer
 *
 *   Sender identity (v3)
 *       LF_Get_P2P_UID
 *       LF_Get_P2P_Name
 *
 *   Async dispatch (six primitives)
 *       LF_Async_Call
 *       LF_Async_Sequenced_Call
 *       LF_UID_Async_Call
 *       LF_UID_Async_Sequenced_Call
 *       LF_P2PNAME_Async_Call
 *       LF_P2PNAME_Async_Sequenced_Call
 *
 *   Runtime options
 *       LF_SetOption
 *       LF_GetOption
 *
 * The handle I/O group is needed by the shim's trampolines, which
 * snapshot the input (or async result) payload and write the
 * consumer's response on the C4 worker thread.
 *
 * Sender identity
 * ---------------
 * LF_Get_P2P_UID returns a pointer to a 32-byte UID; LF_Get_P2P_Name
 * returns a NUL-terminated UTF-8 string. Both pointers are allocated
 * by the Pascal side and scheduled for release ~5 seconds after the
 * call. The shim memcpys the bytes on the trampoline thread and
 * never retains the pointers, so the release has no effect on the
 * caller.
 *
 * Why dynamic resolution instead of linking against an import library
 * ------------------------------------------------------------------
 *   - The LingoFuse distribution ships no .lib / .a import library.
 *   - MinGW-w64 cannot produce one from a Pascal-built DLL without
 *     dlltool / gendef, and MSVC uses an incompatible format.
 *   - Runtime resolution with LoadLibraryA / GetProcAddress is the
 *     only mechanism that works identically on MinGW, MSVC, and clang.
 *
 * Why lazy resolution instead of DllMain
 * --------------------------------------
 * MSDN explicitly warns against calling LoadLibrary from DllMain
 * because the loader lock can deadlock if the loaded module itself
 * loads further modules. Resolving on first use eliminates this
 * class of failure.
 *
 * Load policy
 * -----------
 * The resolver loads the library once, on the first forwarder call,
 * then resolves every required symbol in a single pass. If any
 * symbol is missing, the load is marked failed and every subsequent
 * forwarder call returns the safe default (0, NULL, or a no-op).
 * This makes a missing symbol a visible, one-time error rather than
 * a per-call silent failure.
 *
 * The library path is taken from LINGOFUSE_LIBRARY when set,
 * otherwise the platform-standard name is used.
 *
 * ABI note on the UID parameter
 * -----------------------------
 * The six async primitives include two that take a 32-byte UID by
 * value. The shim declares that parameter as `lf_shim_uid_t`, which
 * is defined in lf_shim.h with the same layout as the C ABI's
 * TP2P_UID___. The function-pointer typedefs below use
 * `lf_shim_uid_t` so that no cast is required at the forwarder
 * boundary; the argument's psABI class (MEMORY) is identical for the
 * two 32-byte aggregate types, so the call reaches the real library
 * intact.
 */

#include "../lf_shim.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#if defined(_WIN32)
  #include <windows.h>
  #define LF_PLATFORM_WINDOWS 1
#else
  #include <dlfcn.h>
  #define LF_PLATFORM_WINDOWS 0
#endif

/* ------------------------------------------------------------------ */
/* Callback type aliases                                              */
/* ------------------------------------------------------------------ */

typedef void (*lf_call_cb_t)(void* trigger, void* input, void* output);
typedef void (*lf_notify_cb_t)(void* trigger, void* input);
typedef void (*lf_net_cb_t)(const char* addr);
typedef void (*lf_async_cb_t)(void* data, void* result);

/* ------------------------------------------------------------------ */
/* Function pointer typedefs for resolved symbols                     */
/* ------------------------------------------------------------------ */

typedef int     (*fn_RegisterCall)(void*, const char*, const char*, void*,
                                   lf_call_cb_t);
typedef int     (*fn_RegisterNotify)(void*, const char*, const char*, void*,
                                     lf_notify_cb_t);
typedef int     (*fn_Register_P2P_Call)(const char*, const char*, void*,
                                        lf_call_cb_t);
typedef int     (*fn_Register_P2P_Notify)(const char*, const char*, void*,
                                          lf_notify_cb_t);
typedef int     (*fn_Unregister_P2P)(const char*);
typedef void    (*fn_Set_Network_Event)(lf_net_cb_t, lf_net_cb_t);
typedef int64_t (*fn_GetSize)(void*);
typedef void    (*fn_SetPos)(void*, int64_t);
typedef int64_t (*fn_ReadBuffer)(void*, void*, int64_t);
typedef int64_t (*fn_WriteBuffer)(void*, const void*, int64_t);

/* Sender identity (v3). The Pascal side declares these as
 *     function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
 *     function LF_Get_P2P_Name(Hnd: TDataHnd___): pansichar;
 * and both are cdecl. lf_shim_uid_t is layout-compatible with
 * TP2P_UID___, so the pointer types match. */
typedef lf_shim_uid_t* (*fn_Get_P2P_UID)(void*);
typedef const char*    (*fn_Get_P2P_Name)(void*);

/*
 * The six async dispatch primitives. LF_UID_Async_Call and
 * LF_UID_Async_Sequenced_Call take the UID by value; the
 * lf_shim_uid_t struct is used here so no cast is required when the
 * shim's forwarder passes its argument through.
 */
typedef int     (*fn_Async_Call)(const char*, void*, void*, lf_async_cb_t);
typedef int     (*fn_Async_Sequenced_Call)(const char*, void*, void*,
                                           lf_async_cb_t);
typedef int     (*fn_UID_Async_Call)(lf_shim_uid_t, void*, void*,
                                     lf_async_cb_t);
typedef int     (*fn_UID_Async_Sequenced_Call)(lf_shim_uid_t, void*, void*,
                                               lf_async_cb_t);
typedef int     (*fn_P2PNAME_Async_Call)(const char*, void*, void*,
                                         lf_async_cb_t);
typedef int     (*fn_P2PNAME_Async_Sequenced_Call)(const char*, void*, void*,
                                                   lf_async_cb_t);

typedef void        (*fn_SetOption)(const char*, const char*);
typedef const char* (*fn_GetOption)(const char*);

/* ------------------------------------------------------------------ */
/* Loader state                                                       */
/* ------------------------------------------------------------------ */

static void* g_real_lib   = NULL;
static int   g_load_done  = 0;
static int   g_load_ok    = 0;

static const char* default_library_name(void)
{
#if LF_PLATFORM_WINDOWS
    return (sizeof(void*) == 8) ? "LingoFuse64.dll" : "LingoFuse32.dll";
#elif defined(__APPLE__)
    return "liblingofuse.dylib";
#else
    return "liblingofuse.so";
#endif
}

static void* open_real_library(void)
{
    const char* env  = getenv("LINGOFUSE_LIBRARY");
    const char* name = (env && env[0]) ? env : default_library_name();

#if LF_PLATFORM_WINDOWS
    HMODULE h = LoadLibraryA(name);
    if (h == NULL && env && env[0]) {
        h = LoadLibraryA(default_library_name());
    }
    return (void*)h;
#else
    void* h = dlopen(name, RTLD_LAZY | RTLD_GLOBAL);
    if (h == NULL && env && env[0]) {
        h = dlopen(default_library_name(), RTLD_LAZY | RTLD_GLOBAL);
    }
    return h;
#endif
}

static void* resolve_symbol(void* h, const char* name)
{
    if (!h) return NULL;
#if LF_PLATFORM_WINDOWS
    return (void*)GetProcAddress((HMODULE)h, name);
#else
    return dlsym(h, name);
#endif
}

/* ------------------------------------------------------------------ */
/* Resolved API table                                                 */
/* ------------------------------------------------------------------ */

typedef struct {
    fn_RegisterCall                RegisterCall;
    fn_RegisterNotify              RegisterNotify;
    fn_Register_P2P_Call           Register_P2P_Call;
    fn_Register_P2P_Notify         Register_P2P_Notify;
    fn_Unregister_P2P              Unregister_P2P;
    fn_Set_Network_Event           Set_Network_Event;
    fn_GetSize                     GetSize;
    fn_SetPos                      SetPos;
    fn_ReadBuffer                  ReadBuffer;
    fn_WriteBuffer                 WriteBuffer;
    fn_Get_P2P_UID                 Get_P2P_UID;
    fn_Get_P2P_Name                Get_P2P_Name;
    fn_Async_Call                  Async_Call;
    fn_Async_Sequenced_Call        Async_Sequenced_Call;
    fn_UID_Async_Call              UID_Async_Call;
    fn_UID_Async_Sequenced_Call    UID_Async_Sequenced_Call;
    fn_P2PNAME_Async_Call          P2PNAME_Async_Call;
    fn_P2PNAME_Async_Sequenced_Call P2PNAME_Async_Sequenced_Call;
    fn_SetOption                   SetOption;
    fn_GetOption                   GetOption;
} lf_api_t;

static lf_api_t g_api;

static int ensure_api(void)
{
    if (g_load_done) return g_load_ok;
    g_load_done = 1;

    g_real_lib = open_real_library();
    if (!g_real_lib) {
        const char* env = getenv("LINGOFUSE_LIBRARY");
        fprintf(stderr,
                "lf_real_link: failed to load the real LingoFuse "
                "library '%s'\n",
                (env && env[0]) ? env : default_library_name());
        return 0;
    }

#define RESOLVE(field, symbol)                                              \
    do {                                                                    \
        g_api.field = (void*)resolve_symbol(g_real_lib, symbol);            \
        if (!g_api.field) {                                                 \
            fprintf(stderr,                                                 \
                    "lf_real_link: symbol '%s' not found\n", symbol);       \
            return 0;                                                       \
        }                                                                   \
    } while (0)

    /* Registration (App-bound) */
    RESOLVE(RegisterCall,                "LF_RegisterCall");
    RESOLVE(RegisterNotify,              "LF_RegisterNotify");

    /* Registration (process-wide P2P) */
    RESOLVE(Register_P2P_Call,           "LF_Register_P2P_Call");
    RESOLVE(Register_P2P_Notify,         "LF_Register_P2P_Notify");
    RESOLVE(Unregister_P2P,              "LF_Unregister_P2P");

    /* Network events */
    RESOLVE(Set_Network_Event,           "LF_Set_Network_Event");

    /* Handle I/O */
    RESOLVE(GetSize,                     "LF_GetSize");
    RESOLVE(SetPos,                      "LF_SetPos");
    RESOLVE(ReadBuffer,                  "LF_ReadBuffer");
    RESOLVE(WriteBuffer,                 "LF_WriteBuffer");

    /* Sender identity (v3) */
    RESOLVE(Get_P2P_UID,                 "LF_Get_P2P_UID");
    RESOLVE(Get_P2P_Name,                "LF_Get_P2P_Name");

    /* Async dispatch */
    RESOLVE(Async_Call,                  "LF_Async_Call");
    RESOLVE(Async_Sequenced_Call,        "LF_Async_Sequenced_Call");
    RESOLVE(UID_Async_Call,              "LF_UID_Async_Call");
    RESOLVE(UID_Async_Sequenced_Call,    "LF_UID_Async_Sequenced_Call");
    RESOLVE(P2PNAME_Async_Call,          "LF_P2PNAME_Async_Call");
    RESOLVE(P2PNAME_Async_Sequenced_Call,"LF_P2PNAME_Async_Sequenced_Call");

    /* Runtime options */
    RESOLVE(SetOption,                   "LF_SetOption");
    RESOLVE(GetOption,                   "LF_GetOption");

#undef RESOLVE

    g_load_ok = 1;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Exported forwarders                                                */
/* ------------------------------------------------------------------ */
/*
 * Every forwarder follows the same shape:
 *
 *   1. ensure_api(); if the load has failed, return the safe default
 *      without touching the real library.
 *   2. Reject obviously invalid arguments (NULL handle, NULL name)
 *      before the call. This mirrors the defensive style used in the
 *      C wrapper (LingoFuse.c) and avoids a crash inside the real
 *      library if a caller passes garbage.
 *   3. Call through the cached function pointer.
 *
 * No forwarder throws; no forwarder logs on a hot path. The one
 * exception is ensure_api() itself, which prints a single line the
 * first time the load fails.
 */

/* ---- Registration (App-bound) ---- */

int LF_RegisterCall(void*       app,
                    const char* name,
                    const char* desc,
                    void*       trigger,
                    void (*cb)(void*, void*, void*))
{
    if (!ensure_api() || cb == NULL) return 0;
    return g_api.RegisterCall(app, name, desc, trigger, cb);
}

int LF_RegisterNotify(void*       app,
                      const char* name,
                      const char* desc,
                      void*       trigger,
                      void (*cb)(void*, void*))
{
    if (!ensure_api() || cb == NULL) return 0;
    return g_api.RegisterNotify(app, name, desc, trigger, cb);
}

/* ---- Registration (process-wide P2P) ---- */

int LF_Register_P2P_Call(const char* name,
                         const char* desc,
                         void*       trigger,
                         void (*cb)(void*, void*, void*))
{
    if (!ensure_api() || cb == NULL) return 0;
    return g_api.Register_P2P_Call(name, desc, trigger, cb);
}

int LF_Register_P2P_Notify(const char* name,
                           const char* desc,
                           void*       trigger,
                           void (*cb)(void*, void*))
{
    if (!ensure_api() || cb == NULL) return 0;
    return g_api.Register_P2P_Notify(name, desc, trigger, cb);
}

int LF_Unregister_P2P(const char* name)
{
    if (!ensure_api()) return 0;
    return g_api.Unregister_P2P(name);
}

/* ---- Network events ---- */

void LF_Set_Network_Event(void (*on_connect)(const char*),
                          void (*on_disconnect)(const char*))
{
    if (!ensure_api()) return;
    g_api.Set_Network_Event(on_connect, on_disconnect);
}

/* ---- Handle I/O ---- */

int64_t LF_GetSize(void* hnd)
{
    if (!ensure_api() || hnd == NULL) return 0;
    return g_api.GetSize(hnd);
}

void LF_SetPos(void* hnd, int64_t pos)
{
    if (!ensure_api() || hnd == NULL) return;
    g_api.SetPos(hnd, pos);
}

int64_t LF_ReadBuffer(void* hnd, void* buff, int64_t size)
{
    if (!ensure_api() || hnd == NULL) return 0;
    return g_api.ReadBuffer(hnd, buff, size);
}

int64_t LF_WriteBuffer(void* hnd, const void* buff, int64_t size)
{
    if (!ensure_api() || hnd == NULL) return 0;
    return g_api.WriteBuffer(hnd, buff, size);
}

/* ---- Sender identity (v3) ---- */

lf_shim_uid_t* LF_Get_P2P_UID(void* hnd)
{
    if (!ensure_api() || hnd == NULL) return NULL;
    return g_api.Get_P2P_UID(hnd);
}

const char* LF_Get_P2P_Name(void* hnd)
{
    if (!ensure_api() || hnd == NULL) return NULL;
    return g_api.Get_P2P_Name(hnd);
}

/* ---- Async dispatch ---- */

int LF_Async_Call(const char* app_name,
                  void*       param,
                  void*       data,
                  void (*cb)(void*, void*))
{
    if (!ensure_api() || app_name == NULL || cb == NULL) return 0;
    return g_api.Async_Call(app_name, param, data, cb);
}

int LF_Async_Sequenced_Call(const char* app_name,
                            void*       param,
                            void*       data,
                            void (*cb)(void*, void*))
{
    if (!ensure_api() || app_name == NULL || cb == NULL) return 0;
    return g_api.Async_Sequenced_Call(app_name, param, data, cb);
}

int LF_UID_Async_Call(lf_shim_uid_t uid,
                      void*         param,
                      void*         data,
                      void (*cb)(void*, void*))
{
    if (!ensure_api() || cb == NULL) return 0;
    return g_api.UID_Async_Call(uid, param, data, cb);
}

int LF_UID_Async_Sequenced_Call(lf_shim_uid_t uid,
                                void*         param,
                                void*         data,
                                void (*cb)(void*, void*))
{
    if (!ensure_api() || cb == NULL) return 0;
    return g_api.UID_Async_Sequenced_Call(uid, param, data, cb);
}

int LF_P2PNAME_Async_Call(const char* group_name,
                          void*       param,
                          void*       data,
                          void (*cb)(void*, void*))
{
    if (!ensure_api() || group_name == NULL || cb == NULL) return 0;
    return g_api.P2PNAME_Async_Call(group_name, param, data, cb);
}

int LF_P2PNAME_Async_Sequenced_Call(const char* group_name,
                                    void*       param,
                                    void*       data,
                                    void (*cb)(void*, void*))
{
    if (!ensure_api() || group_name == NULL || cb == NULL) return 0;
    return g_api.P2PNAME_Async_Sequenced_Call(group_name, param, data, cb);
}

/* ---- Runtime options ---- */

void LF_SetOption(const char* name, const char* value)
{
    if (!ensure_api() || name == NULL) return;
    g_api.SetOption(name, value);
}

const char* LF_GetOption(const char* name)
{
    if (!ensure_api() || name == NULL) return "";
    const char* v = g_api.GetOption(name);
    return v ? v : "";
}