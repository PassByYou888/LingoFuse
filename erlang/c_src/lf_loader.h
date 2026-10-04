/*
 * lf_loader.h
 *
 * Runtime loader for the LingoFuse shared library.
 *
 * This module is the ONLY place in the NIF that opens the LingoFuse
 * shared library. It resolves every exported symbol into a typed
 * function pointer stored in a process-wide LF_Bindings struct.
 *
 * Loading is lazy and idempotent:
 *   - The first successful call caches the function table.
 *   - Later calls return the same cached pointer with no additional
 *     work.
 *   - A failed load is cached as well. The process must be restarted
 *     to retry; installing the native library after a failed attempt
 *     is not supported, matching the C++ and JavaScript bindings.
 *
 * Thread safety:
 *   - All public functions are thread-safe.
 *   - The internal state is protected by a platform-specific mutex.
 */

#ifndef LF_LOADER_H
#define LF_LOADER_H

#include "lf_bindings.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Load status codes
 * ============================================================================ */

typedef enum {
    /* The library is loaded and every symbol has been resolved. */
    LF_LOAD_OK          = 0,

    /* No load has been attempted yet, and none will be triggered by
     * calling the read-only accessors. */
    LF_LOAD_NOT_LOADED  = 1,

    /* The platform-specific shared library file could not be found or
     * loaded. See lf_loader_last_error() for details. */
    LF_LOAD_LIB_MISSING = 2,

    /* The library loaded, but a required export is missing. Almost
     * always a version mismatch between this binding and the installed
     * native library. */
    LF_LOAD_SYM_MISSING = 3,

    /* The current platform is not supported by LingoFuse. */
    LF_LOAD_PLATFORM    = 4
} LF_LoadStatus;

/* ============================================================================
 * Public API
 * ============================================================================ */

/*
 * Load the LingoFuse dynamic library and resolve every export.
 *
 * Returns LF_LOAD_OK on success (which includes "already loaded") or
 * one of the failure codes on error. On failure, lf_loader_last_error()
 * returns a human-readable diagnostic.
 *
 * Thread-safe. Idempotent. A failure is cached for the process
 * lifetime; do not retry.
 */
LF_LoadStatus lf_loader_ensure_loaded(void);

/*
 * Return the resolved function-pointer table.
 *
 * Returns NULL if the library has not been successfully loaded. Every
 * caller MUST check for NULL before using any function pointer.
 */
const LF_Bindings* lf_loader_get(void);

/*
 * Return the last error message from the load attempt, or an empty
 * string when the load succeeded.
 *
 * The returned pointer is a process-wide buffer owned by the loader.
 * Do not free it. It remains valid until the next load attempt (which
 * for a cached failure never happens).
 */
const char* lf_loader_last_error(void);

/*
 * Return a short platform description, e.g. "Windows 64-bit",
 * "Linux x86_64", or "macOS". Used for diagnostics and log headers.
 *
 * The returned pointer is a process-wide static string; do not free it.
 */
const char* lf_loader_platform(void);

/*
 * Return the expected platform-specific file name of the shared
 * library, e.g. "LingoFuse64.dll" or "liblingofuse.so". Used for
 * diagnostics when the load fails.
 */
const char* lf_loader_expected_file_name(void);

#ifdef __cplusplus
}
#endif

#endif /* LF_LOADER_H */