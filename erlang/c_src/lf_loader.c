/*
 * lf_loader.c
 *
 * Platform-specific dynamic loading of the LingoFuse shared library.
 *
 * Loading strategy:
 *   1. Try the platform-specific file name directly via the OS loader
 *      search path (LoadLibraryA on Windows, dlopen on POSIX). This
 *      covers the common case where the native library has been placed
 *      on PATH / LD_LIBRARY_PATH / DYLD_LIBRARY_PATH.
 *   2. If that fails, the current working directory is tried
 *      explicitly. This helps during development, when the native
 *      library sits next to the BEAM executable or in the project
 *      root.
 *
 * On success, the loader resolves all 37 exported symbols into the
 * process-wide LF_Bindings table. If any symbol is missing, the load
 * is aborted and the partially-resolved table is discarded; a mixed
 * state is never exposed to callers.
 *
 * Thread safety:
 *   A single mutex protects the "load once" state. The fast path
 *   (already loaded / already failed) reads an int without locking,
 *   which is safe on every platform this binding supports: the value
 *   transitions monotonically from 0 (unknown) to +1 (loaded) or -1
 *   (failed), and it is only ever written by the thread that holds
 *   the mutex.
 */

#define _CRT_SECURE_NO_WARNINGS

#include "lf_loader.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================================
 * Platform-specific includes and primitives
 * ============================================================================ */

#if defined(_WIN32)
#  include <windows.h>
#  define LF_MUTEX_TYPE        CRITICAL_SECTION
#  define LF_MUTEX_INIT(m)     InitializeCriticalSection(m)
#  define LF_MUTEX_LOCK(m)     EnterCriticalSection(m)
#  define LF_MUTEX_UNLOCK(m)   LeaveCriticalSection(m)
#  define LF_MUTEX_DESTROY(m)  DeleteCriticalSection(m)
#  define LF_LIB_HANDLE        HMODULE
#  define LF_LIB_OPEN(name)    LoadLibraryA(name)
#  define LF_LIB_CLOSE(h)      FreeLibrary(h)
#  define LF_LIB_SYM(h, n)     ((void*)GetProcAddress((HMODULE)(h), (n)))
#  define LF_PATH_SEPARATOR    "\\"
#else
#  include <dlfcn.h>
#  include <pthread.h>
#  include <unistd.h>
#  include <errno.h>
#  define LF_MUTEX_TYPE        pthread_mutex_t
#  define LF_MUTEX_INIT(m)     pthread_mutex_init(m, NULL)
#  define LF_MUTEX_LOCK(m)     pthread_mutex_lock(m)
#  define LF_MUTEX_UNLOCK(m)   pthread_mutex_unlock(m)
#  define LF_MUTEX_DESTROY(m)  pthread_mutex_destroy(m)
#  define LF_LIB_HANDLE        void*
#  define LF_LIB_OPEN(name)    dlopen(name, RTLD_NOW | RTLD_GLOBAL)
#  define LF_LIB_CLOSE(h)      dlclose(h)
#  define LF_LIB_SYM(h, n)     dlsym((h), (n))
#  define LF_PATH_SEPARATOR    "/"
#endif

/* ============================================================================
 * Static state
 *
 * All access to g_bindings, g_lib_handle, g_status, and g_error must be
 * serialized through g_mutex (except for the fast-path check of
 * g_loaded, which is a plain int and safe to read without locking).
 * ============================================================================ */

static LF_Bindings    g_bindings;
static LF_LIB_HANDLE  g_lib_handle = NULL;
static int            g_loaded     = 0;   /* 0 = unknown, 1 = ok, -1 = failed */
static LF_LoadStatus  g_status     = LF_LOAD_NOT_LOADED;
static char           g_error[512];
static char           g_platform[64];
static LF_MUTEX_TYPE  g_mutex;
static int            g_mutex_ready = 0;

/* ============================================================================
 * Platform detection
 * ============================================================================ */

static const char* detect_platform(void) {
#if defined(_WIN32) && defined(_WIN64)
    return "Windows 64-bit";
#elif defined(_WIN32)
    return "Windows 32-bit";
#elif defined(__APPLE__)
    return "macOS";
#elif defined(__linux__) && defined(__x86_64__)
    return "Linux x86_64";
#elif defined(__linux__) && defined(__aarch64__)
    return "Linux aarch64";
#elif defined(__linux__)
    return "Linux";
#elif defined(__FreeBSD__)
    return "FreeBSD";
#else
    return "Unknown";
#endif
}

static const char* platform_library_name(void) {
#if defined(_WIN32) && defined(_WIN64)
    return "LingoFuse64.dll";
#elif defined(_WIN32)
    return "LingoFuse32.dll";
#elif defined(__APPLE__)
    return "liblingofuse.dylib";
#else
    return "liblingofuse.so";
#endif
}

/* ============================================================================
 * Symbol resolution
 * ============================================================================ */

/*
 * Resolve one symbol into a typed function pointer. The macro uses
 * memcpy rather than a direct cast because ISO C does not guarantee
 * that a function pointer and a data pointer have the same
 * representation; memcpy sidesteps the diagnostic and is well-defined
 * on every platform LingoFuse supports.
 */
#define LF_RESOLVE(field, c_name)                                            \
    do {                                                                     \
        void* p_ = LF_LIB_SYM(g_lib_handle, c_name);                         \
        if (p_ == NULL) {                                                    \
            snprintf(g_error, sizeof(g_error),                               \
                     "required symbol not found: %s", c_name);               \
            g_status = LF_LOAD_SYM_MISSING;                                  \
            return 0;                                                        \
        }                                                                    \
        memcpy(&g_bindings.field, &p_, sizeof(p_));                          \
    } while (0)

static int resolve_all_symbols(void) {
    memset(&g_bindings, 0, sizeof(g_bindings));

    /* --- Data handle operations (10) --- */
    LF_RESOLVE(LF_CreateData,           "LF_CreateData");
    LF_RESOLVE(LF_CreateData_Permanent, "LF_CreateData_Permanent");
    LF_RESOLVE(LF_FreeData,             "LF_FreeData");
    LF_RESOLVE(LF_GetBuffer,            "LF_GetBuffer");
    LF_RESOLVE(LF_WriteBuffer,          "LF_WriteBuffer");
    LF_RESOLVE(LF_ReadBuffer,           "LF_ReadBuffer");
    LF_RESOLVE(LF_GetPos,               "LF_GetPos");
    LF_RESOLVE(LF_SetPos,               "LF_SetPos");
    LF_RESOLVE(LF_GetSize,              "LF_GetSize");
    LF_RESOLVE(LF_SetSize,              "LF_SetSize");

    /* --- Application handle operations (5) --- */
    LF_RESOLVE(LF_CreateApp,            "LF_CreateApp");
    LF_RESOLVE(LF_FreeApp,              "LF_FreeApp");
    LF_RESOLVE(LF_Generate_AppName,     "LF_Generate_AppName");
    LF_RESOLVE(LF_Get_AppName,          "LF_Get_AppName");
    LF_RESOLVE(LF_BindApp,              "LF_BindApp");

    /* --- API registration (3) --- */
    LF_RESOLVE(LF_RegisterCall,         "LF_RegisterCall");
    LF_RESOLVE(LF_RegisterNotify,       "LF_RegisterNotify");
    LF_RESOLVE(LF_Unregister,           "LF_Unregister");

    /* --- Local execution (2) --- */
    LF_RESOLVE(LF_LocalCall,            "LF_LocalCall");
    LF_RESOLVE(LF_LocalNotify,          "LF_LocalNotify");

    /* --- Network preparation (5) --- */
    LF_RESOLVE(LF_ResetPrepare,         "LF_ResetPrepare");
    LF_RESOLVE(LF_PrepareService,       "LF_PrepareService");
    LF_RESOLVE(LF_PrepareClient,        "LF_PrepareClient");
    LF_RESOLVE(LF_PrepareDone,          "LF_PrepareDone");
    LF_RESOLVE(LF_ExitMainThread,       "LF_ExitMainThread");

    /* --- Remote invocation (3) --- */
    LF_RESOLVE(LF_Call,                 "LF_Call");
    LF_RESOLVE(LF_Notify,               "LF_Notify");
    LF_RESOLVE(LF_Sequenced_Notify,     "LF_Sequenced_Notify");

    /* --- Options and diagnostics (7) --- */
    LF_RESOLVE(LF_SetOption,            "LF_SetOption");
    LF_RESOLVE(LF_GetStatusCount,       "LF_GetStatusCount");
    LF_RESOLVE(LF_GetStatus,            "LF_GetStatus");
    LF_RESOLVE(LF_PostStatus,           "LF_PostStatus");
    LF_RESOLVE(LF_CheckMainThread,      "LF_CheckMainThread");
    LF_RESOLVE(LF_CheckApp,             "LF_CheckApp");
    LF_RESOLVE(LF_CheckApi,             "LF_CheckApi");

    /* --- Shutdown (1) --- */
    LF_RESOLVE(LF_Shutdown,             "LF_Shutdown");

    /* --- Network events (1) --- */
    LF_RESOLVE(LF_Set_Network_Event,    "LF_Set_Network_Event");

    return 1;
}

#undef LF_RESOLVE

/* ============================================================================
 * Library load attempt
 * ============================================================================ */

static int try_open_library(void) {
    const char* name = platform_library_name();

    /* First attempt: rely on the OS loader search path. */
    g_lib_handle = LF_LIB_OPEN(name);
    if (g_lib_handle != NULL) {
        return 1;
    }

    /*
     * Second attempt: prepend the current working directory. This is
     * useful during development when the native library sits next to
     * the project instead of on PATH.
     *
     * We deliberately do NOT try to walk the whole PATH ourselves:
     * the OS loader already handles that case correctly, including
     * platform-specific quirks such as @rpath on macOS and the
     * per-user DLL directories on Windows 10+.
     */
    char cwd_buf[1024];
#if defined(_WIN32)
    DWORD n = GetCurrentDirectoryA((DWORD)sizeof(cwd_buf), cwd_buf);
    if (n == 0 || n >= (DWORD)sizeof(cwd_buf)) {
        return 0;
    }
#else
    if (getcwd(cwd_buf, sizeof(cwd_buf)) == NULL) {
        return 0;
    }
#endif

    size_t cwd_len = strlen(cwd_buf);
    size_t name_len = strlen(name);
    size_t sep_len = strlen(LF_PATH_SEPARATOR);

    if (cwd_len + sep_len + name_len + 1 > sizeof(cwd_buf)) {
        return 0;
    }

    char full_path[1024];
    memcpy(full_path, cwd_buf, cwd_len);
    memcpy(full_path + cwd_len, LF_PATH_SEPARATOR, sep_len);
    memcpy(full_path + cwd_len + sep_len, name, name_len + 1);

    g_lib_handle = LF_LIB_OPEN(full_path);
    if (g_lib_handle != NULL) {
        return 1;
    }

    /* Both attempts failed. Record a diagnostic that names both the
     * bare file name and the CWD-qualified path, so the operator knows
     * exactly which files were tried. */
#if defined(_WIN32)
    snprintf(g_error, sizeof(g_error),
             "could not load '%s' from the search path or from the "
             "current directory (error %lu)",
             name, (unsigned long)GetLastError());
#else
    snprintf(g_error, sizeof(g_error),
             "could not load '%s' from the search path or from the "
             "current directory: %s",
             name, dlerror());
#endif
    g_status = LF_LOAD_LIB_MISSING;
    return 0;
}

/* ============================================================================
 * Public API
 * ============================================================================ */

LF_LoadStatus lf_loader_ensure_loaded(void) {
    /* Fast path: a previous call already decided the outcome. */
    if (g_loaded == 1) {
        return LF_LOAD_OK;
    }
    if (g_loaded == -1) {
        return g_status;
    }

    if (!g_mutex_ready) {
        LF_MUTEX_INIT(&g_mutex);
        g_mutex_ready = 1;
    }

    LF_MUTEX_LOCK(&g_mutex);

    /* Double-checked locking: another thread may have completed the
     * load while we were waiting for the mutex. */
    if (g_loaded == 1) {
        LF_MUTEX_UNLOCK(&g_mutex);
        return LF_LOAD_OK;
    }
    if (g_loaded == -1) {
        LF_MUTEX_UNLOCK(&g_mutex);
        return g_status;
    }

    /* Initialize the platform string (once). */
    if (g_platform[0] == '\0') {
        snprintf(g_platform, sizeof(g_platform), "%s", detect_platform());
    }

    /* Attempt to open the shared library. */
    if (!try_open_library()) {
        g_loaded = -1;
        LF_MUTEX_UNLOCK(&g_mutex);
        return g_status;
    }

    /* Resolve every exported symbol. */
    if (!resolve_all_symbols()) {
        /* g_error and g_status have already been set by the macro.
         * Close the library so that a retry (which is not supported,
         * but a fresh process would do) starts clean. */
        LF_LIB_CLOSE(g_lib_handle);
        g_lib_handle = NULL;
        g_loaded = -1;
        LF_MUTEX_UNLOCK(&g_mutex);
        return g_status;
    }

    /* Success. Commit the state. */
    g_loaded = 1;
    g_status = LF_LOAD_OK;
    g_error[0] = '\0';
    LF_MUTEX_UNLOCK(&g_mutex);
    return LF_LOAD_OK;
}

const LF_Bindings* lf_loader_get(void) {
    if (g_loaded != 1) {
        return NULL;
    }
    return &g_bindings;
}

const char* lf_loader_last_error(void) {
    return g_error;
}

const char* lf_loader_platform(void) {
    if (g_platform[0] == '\0') {
        return detect_platform();
    }
    return g_platform;
}

const char* lf_loader_expected_file_name(void) {
    return platform_library_name();
}