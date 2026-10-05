/*
 * lf_real_link.c - Dynamic linker for the real LingoFuse library.
 *
 * Satisfies the extern declarations in lf_shim.c by loading the real
 * LingoFuse shared library on first use and resolving the symbols via
 * GetProcAddress (Windows) or dlsym (POSIX).
 *
 * Symbols provided
 * ----------------
 *   Registration    LF_RegisterCall
 *                   LF_RegisterNotify
 *                   LF_Set_Network_Event
 *
 *   Handle I/O      LF_GetSize
 *                   LF_SetPos
 *                   LF_ReadBuffer
 *                   LF_WriteBuffer
 *
 * The second group is needed by the shim's trampolines, which
 * snapshot the input payload and write the consumer's response on
 * the C4 worker thread.
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
 * The library path is taken from LINGOFUSE_LIBRARY when set,
 * otherwise the platform-standard name is used.
 */

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
/* Loader state                                                       */
/* ------------------------------------------------------------------ */

static void* g_real_lib          = NULL;
static int   g_loader_attempted  = 0;

#if LF_PLATFORM_WINDOWS
static const char* default_library_name(void)
{
    return (sizeof(void*) == 8) ? "LingoFuse64.dll" : "LingoFuse32.dll";
}
#else
static const char* default_library_name(void)
{
    return "liblingofuse.so";
}
#endif

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
    if (h == NULL) return NULL;
#if LF_PLATFORM_WINDOWS
    return (void*)GetProcAddress((HMODULE)h, name);
#else
    return dlsym(h, name);
#endif
}

static void ensure_loader(void)
{
    if (g_loader_attempted) return;
    g_loader_attempted = 1;
    g_real_lib = open_real_library();

    if (g_real_lib == NULL) {
        const char* env = getenv("LINGOFUSE_LIBRARY");
        fprintf(stderr,
                "lf_real_link: failed to load the real LingoFuse "
                "library '%s'\n",
                (env && env[0]) ? env : default_library_name());
    }
}

/* ------------------------------------------------------------------ */
/* Callback type aliases                                              */
/* ------------------------------------------------------------------ */
/*
 * The three LingoFuse callback signatures are declared as standalone
 * typedefs first, then referenced by name in the function-pointer
 * typedefs below. This makes each typedef a single level of
 * indirection, which the C parser in the editor handles cleanly;
 * nesting a function-pointer type inside another one triggers a
 * "function returning function" mis-diagnosis in some configurations.
 */

typedef void  (*LF_CallCallback)(void* trigger, void* input, void* output);
typedef void  (*LF_NotifyCallback)(void* trigger, void* input);
typedef void  (*LF_NetworkEventCallback)(const char* addr);

/* ------------------------------------------------------------------ */
/* Function pointer typedefs for resolved symbols                     */
/* ------------------------------------------------------------------ */

typedef int     (*fn_LF_RegisterCall)(void*, const char*, const char*, void*,
                                      LF_CallCallback);
typedef int     (*fn_LF_RegisterNotify)(void*, const char*, const char*, void*,
                                        LF_NotifyCallback);
typedef void    (*fn_LF_Set_Network_Event)(LF_NetworkEventCallback,
                                           LF_NetworkEventCallback);
typedef int64_t (*fn_LF_GetSize)(void*);
typedef void    (*fn_LF_SetPos)(void*, int64_t);
typedef int64_t (*fn_LF_ReadBuffer)(void*, void*, int64_t);
typedef int64_t (*fn_LF_WriteBuffer)(void*, const void*, int64_t);

/* ------------------------------------------------------------------ */
/* Exported forwarders                                                */
/* ------------------------------------------------------------------ */

int LF_RegisterCall(void*       app,
                    const char* name,
                    const char* desc,
                    void*       trigger,
                    void (*cb)(void*, void*, void*))
{
    ensure_loader();
    if (g_real_lib == NULL || cb == NULL) return 0;
    fn_LF_RegisterCall fn =
        (fn_LF_RegisterCall)resolve_symbol(g_real_lib, "LF_RegisterCall");
    if (fn == NULL) return 0;
    return fn(app, name, desc, trigger, cb);
}

int LF_RegisterNotify(void*       app,
                      const char* name,
                      const char* desc,
                      void*       trigger,
                      void (*cb)(void*, void*))
{
    ensure_loader();
    if (g_real_lib == NULL || cb == NULL) return 0;
    fn_LF_RegisterNotify fn =
        (fn_LF_RegisterNotify)resolve_symbol(g_real_lib, "LF_RegisterNotify");
    if (fn == NULL) return 0;
    return fn(app, name, desc, trigger, cb);
}

void LF_Set_Network_Event(void (*on_connect)(const char*),
                          void (*on_disconnect)(const char*))
{
    ensure_loader();
    if (g_real_lib == NULL) return;
    fn_LF_Set_Network_Event fn =
        (fn_LF_Set_Network_Event)resolve_symbol(g_real_lib,
                                                "LF_Set_Network_Event");
    if (fn != NULL) fn(on_connect, on_disconnect);
}

int64_t LF_GetSize(void* hnd)
{
    ensure_loader();
    if (g_real_lib == NULL || hnd == NULL) return 0;
    fn_LF_GetSize fn =
        (fn_LF_GetSize)resolve_symbol(g_real_lib, "LF_GetSize");
    if (fn == NULL) return 0;
    return fn(hnd);
}

void LF_SetPos(void* hnd, int64_t pos)
{
    ensure_loader();
    if (g_real_lib == NULL || hnd == NULL) return;
    fn_LF_SetPos fn =
        (fn_LF_SetPos)resolve_symbol(g_real_lib, "LF_SetPos");
    if (fn != NULL) fn(hnd, pos);
}

int64_t LF_ReadBuffer(void* hnd, void* buff, int64_t size)
{
    ensure_loader();
    if (g_real_lib == NULL || hnd == NULL) return 0;
    fn_LF_ReadBuffer fn =
        (fn_LF_ReadBuffer)resolve_symbol(g_real_lib, "LF_ReadBuffer");
    if (fn == NULL) return 0;
    return fn(hnd, buff, size);
}

int64_t LF_WriteBuffer(void* hnd, const void* buff, int64_t size)
{
    ensure_loader();
    if (g_real_lib == NULL || hnd == NULL) return 0;
    fn_LF_WriteBuffer fn =
        (fn_LF_WriteBuffer)resolve_symbol(g_real_lib, "LF_WriteBuffer");
    if (fn == NULL) return 0;
    return fn(hnd, buff, size);
}