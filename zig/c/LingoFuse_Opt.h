/**
 * @file LingoFuse_Opt.h
 * @brief Typed set_opt_* / get_opt_* helpers for the LingoFuse runtime.
 *
 * ============================================================================
 * WHAT THIS FILE PROVIDES
 * ============================================================================
 *
 * The LingoFuse C ABI exposes exactly two option functions:
 *
 *     void        LF_SetOption(const char* option, const char* value);
 *     const char* LF_GetOption(const char* option);
 *
 * Both take and return strings. That is the minimal, universal
 * interface, but it is also easy to misuse:
 *
 *     - A misspelled option name is silently ignored by the native layer.
 *     - Boolean values must be spelled "True" / "False" (case-insensitive);
 *       "true" / "1" / "yes" are not guaranteed to work on every build.
 *     - Integer values must be formatted as decimal strings.
 *
 * This header provides STATIC INLINE typed wrappers around the two
 * exported functions, so that C and C++ callers can write:
 *
 *     LF_Set_Opt_Quiet(1);
 *     LF_Set_Opt_Wait_Connection_Timeout(10000);
 *     int quiet = LF_Get_Opt_Quiet();
 *     uint64_t t = LF_Get_Opt_Wait_Connection_Timeout();
 *
 * and get the canonical wire form for free.
 *
 * ============================================================================
 * SCOPE
 * ============================================================================
 *
 * This header is HEADER-ONLY. It introduces no new exported symbols
 * and does not require any change to the native library. Every
 * function below is `static inline` and expands into calls to the
 * already-exported `LF_SetOption` / `LF_GetOption`.
 *
 * ============================================================================
 * CAN I USE THIS FROM C#?
 * ============================================================================
 *
 * NOT DIRECTLY. C# P/Invoke can only call symbols that are EXPORTED
 * from a native library. `static inline` functions have no exported
 * symbol and therefore cannot be P/Invoke'd.
 *
 * Two viable options for a C# binding:
 *
 *   OPTION 1 - Reimplement the wrappers in C# (RECOMMENDED, no native
 *              change required).
 *
 *     Use `LF_SetOption` / `LF_GetOption` directly and add a small
 *     C#-side typed layer. For example:
 *
 *         using System;
 *         using System.Runtime.InteropServices;
 *
 *         internal static class Lf {
 *             [DllImport("LingoFuse64", CallingConvention = CallingConvention.Cdecl)]
 *             internal static extern void LF_SetOption(
 *                 [MarshalAs(UnmanagedType.LPUTF8Str)] string option,
 *                 [MarshalAs(UnmanagedType.LPUTF8Str)] string value);
 *
 *             [DllImport("LingoFuse64", CallingConvention = CallingConvention.Cdecl)]
 *             internal static extern IntPtr LF_GetOption(
 *                 [MarshalAs(UnmanagedType.LPUTF8Str)] string option);
 *         }
 *
 *         public static class Options {
 *             public static void SetQuiet(bool v) =>
 *                 Lf.LF_SetOption("Quiet", v ? "True" : "False");
 *
 *             public static bool GetQuiet() =>
 *                 Marshal.PtrToStringUTF8(Lf.LF_GetOption("Quiet"))
 *                     ?.Equals("True", StringComparison.OrdinalIgnoreCase)
 *                 ?? false;
 *
 *             public static void SetWaitConnectionTimeout(ulong ms) =>
 *                 Lf.LF_SetOption("Wait_Connection_Timeout",
 *                                 ms.ToString(System.Globalization.CultureInfo.InvariantCulture));
 *
 *             public static ulong GetWaitConnectionTimeout() {
 *                 var s = Marshal.PtrToStringUTF8(Lf.LF_GetOption("Wait_Connection_Timeout"));
 *                 return ulong.TryParse(s, out var v) ? v : 0UL;
 *             }
 *
 *             // ... one pair per option, mirroring the C functions below.
 *         }
 *
 *     The C# layer is roughly 40 lines of mechanical translation from
 *     this header. The advantage is that no native-side change is
 *     required.
 *
 *   OPTION 2 - Extend the native library to export typed wrappers.
 *
 *     Define `LF_OPT_DECLARE_EXPORTED` before including this header in
 *     the native library's build. Every function below is then
 *     declared `extern` (instead of `static inline`) with the
 *     `LF_OPT_EXPORT` linkage macro. Implement them in a new .c file
 *     and add them to the export list. The C# P/Invoke layer can then
 *     call them by name.
 *
 *     This requires rebuilding the native library, which is why
 *     OPTION 1 is the recommended path when the runtime library is
 *     distributed as a binary.
 *
 * ============================================================================
 * BOOLEAN WIRE FORMAT
 * ============================================================================
 *
 * The setter functions always write "True" or "False". The getter
 * functions accept either case and treat anything other than "True"
 * (case-insensitive) as false.
 *
 * ============================================================================
 * INTEGER PARSING
 * ============================================================================
 *
 * The getters use strtoull / strtoll semantics: leading whitespace is
 * skipped, an optional sign is honoured for signed values, and
 * trailing garbage is ignored. An empty or non-numeric string yields
 * zero. This matches the C++ and Zig bindings' behaviour.
 *
 * ============================================================================
 * NULL SAFETY
 * ============================================================================
 *
 * `LF_GetOption` may return NULL for an unknown option on some
 * builds. All getters below check for NULL and treat it as "empty
 * string", so the caller never sees a NULL pointer.
 *
 * ============================================================================
 * THREADING
 * ============================================================================
 *
 * The underlying `LF_SetOption` / `LF_GetOption` are thread-safe. A
 * setter takes effect immediately, so a concurrent reader may observe
 * the old value, the new value, or (for string options) a torn read.
 * An application that needs a consistent multi-option configuration
 * must serialise its own updates behind its own lock.
 *
 * ============================================================================
 * PERSISTENCE
 * ============================================================================
 *
 * Every option resets to its built-in default when `LF_Shutdown` is
 * called. An application that restarts the framework must reapply its
 * options on every startup.
 */

#ifndef LINGOFUSE_OPT_H_INCLUDED
#define LINGOFUSE_OPT_H_INCLUDED

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================================
 * Linkage control
 * ============================================================================
 *
 * Default mode: every helper is `static inline`, no new exports.
 *
 * If `LF_OPT_DECLARE_EXPORTED` is defined before including this
 * header, every helper becomes an `extern` declaration whose
 * definition must be provided by a separate .c file and added to the
 * native library's export list. This is OPTION 2 in the file docstring.
 */

#if defined(LF_OPT_DECLARE_EXPORTED)
#  if defined(_WIN32) && defined(LF_OPT_BUILDING_DLL)
#    define LF_OPT_EXPORT __declspec(dllexport)
#  elif defined(_WIN32)
#    define LF_OPT_EXPORT __declspec(dllimport)
#  elif defined(__GNUC__) && defined(LF_OPT_BUILDING_DLL)
#    define LF_OPT_EXPORT __attribute__((visibility("default")))
#  else
#    define LF_OPT_EXPORT
#  endif
#  define LF_OPT_LINKAGE extern LF_OPT_EXPORT
#  define LF_OPT_INLINE
#else
#  if defined(__GNUC__)
#    define LF_OPT_LINKAGE static __attribute__((unused))
#  else
#    define LF_OPT_LINKAGE static
#  endif
#  define LF_OPT_INLINE inline
#endif

/* ============================================================================
 * Raw C ABI declarations for the two exported functions
 * ============================================================================
 *
 * These are declared here so that the header is self-contained. Do NOT
 * add a definition; the symbols come from the LingoFuse runtime.
 *
 * If you already include `LingoFuse.h`, these declarations are
 * identical to the ones there; multiple declarations of the same
 * extern function are legal in C.
 */

#if defined(_WIN32)
#  define LF_OPT_CDECL __cdecl
#else
#  define LF_OPT_CDECL
#endif

LF_OPT_LINKAGE void LF_OPT_CDECL LF_SetOption(
    const char* option, const char* value);

LF_OPT_LINKAGE const char* LF_OPT_CDECL LF_GetOption(
    const char* option);

/* ============================================================================
 * Internal helpers
 * ============================================================================
 *
 * These are prefixed with `lf_opt_` to avoid colliding with any symbol
 * a caller may already have. They are `static` (never exported).
 */

static LF_OPT_INLINE int lf_opt_str_eq_ci(const char* a, const char* b) {
    if (a == NULL || b == NULL) return 0;
    while (*a != '\0' && *b != '\0') {
        unsigned char ca = (unsigned char)*a;
        unsigned char cb = (unsigned char)*b;
        if (ca >= 'A' && ca <= 'Z') ca = (unsigned char)(ca + 32);
        if (cb >= 'A' && cb <= 'Z') cb = (unsigned char)(cb + 32);
        if (ca != cb) return 0;
        ++a; ++b;
    }
    return *a == '\0' && *b == '\0';
}

static LF_OPT_INLINE int lf_opt_get_bool(const char* name) {
    const char* v = LF_GetOption(name);
    if (v == NULL) return 0;
    return lf_opt_str_eq_ci(v, "True") ? 1 : 0;
}

static LF_OPT_INLINE uint64_t lf_opt_get_u64(const char* name) {
    const char* v = LF_GetOption(name);
    if (v == NULL || *v == '\0') return 0;
    return (uint64_t)strtoull(v, NULL, 10);
}

static LF_OPT_INLINE int64_t lf_opt_get_i64(const char* name) {
    const char* v = LF_GetOption(name);
    if (v == NULL || *v == '\0') return 0;
    return (int64_t)strtoll(v, NULL, 10);
}

/* Write a decimal value into a stack buffer and forward it. */
static LF_OPT_INLINE void lf_opt_set_u64(const char* name, uint64_t value) {
    char buf[32];
    /* 32 bytes is more than enough for 20 digits plus a NUL. */
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)value);
    LF_SetOption(name, buf);
}

static LF_OPT_INLINE void lf_opt_set_i64(const char* name, int64_t value) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)value);
    LF_SetOption(name, buf);
}

static LF_OPT_INLINE void lf_opt_set_bool(const char* name, int value) {
    LF_SetOption(name, value ? "True" : "False");
}

/* ============================================================================
 * Public typed API
 * ============================================================================
 *
 * One setter and one getter per option. The naming convention mirrors
 * the Pascal `LF_Set_Opt_*` / `LF_Get_Opt_*` families and the Zig
 * `options.setXxx` / `options.getXxx` pair.
 */

/* ---- Authentication ---------------------------------------------------- */

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_Password(const char* value) {
    LF_SetOption("password", value == NULL ? "" : value);
}

LF_OPT_LINKAGE const char* LF_OPT_INLINE
LF_Get_Opt_Password(void) {
    /* The native library masks this value; do not expect the plaintext. */
    return LF_GetOption("password");
}

/* ---- Logging and diagnostics ------------------------------------------- */

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_Quiet(int value) {
    lf_opt_set_bool("Quiet", value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_Quiet(void) {
    return lf_opt_get_bool("Quiet");
}

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_ShowThreadID(int value) {
    lf_opt_set_bool("ShowThreadID", value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_ShowThreadID(void) {
    return lf_opt_get_bool("ShowThreadID");
}

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_ConsoleOutput(int value) {
    lf_opt_set_bool("ConsoleOutput", value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_ConsoleOutput(void) {
    return lf_opt_get_bool("ConsoleOutput");
}

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_Debug(const char* value) {
    LF_SetOption("debug", value == NULL ? "" : value);
}

LF_OPT_LINKAGE const char* LF_OPT_INLINE
LF_Get_Opt_Debug(void) {
    /* Write-only option; the getter returns a placeholder. */
    return LF_GetOption("debug");
}

/* ---- Connection readiness ---------------------------------------------- */

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_Overlap_Connection(int value) {
    lf_opt_set_bool("Overlap_Connection", value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_Overlap_Connection(void) {
    return lf_opt_get_bool("Overlap_Connection");
}

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_Wait_Connection_ReadyOk(int value) {
    lf_opt_set_bool("Wait_Connection_ReadyOk", value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_Wait_Connection_ReadyOk(void) {
    return lf_opt_get_bool("Wait_Connection_ReadyOk");
}

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_Wait_Connection_Timeout(uint64_t value) {
    lf_opt_set_u64("Wait_Connection_Timeout", value);
}

LF_OPT_LINKAGE uint64_t LF_OPT_INLINE
LF_Get_Opt_Wait_Connection_Timeout(void) {
    return lf_opt_get_u64("Wait_Connection_Timeout");
}

/* ---- IPC -------------------------------------------------------------- */

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_IPC_Serv_ThreadCount(int value) {
    lf_opt_set_i64("IPC_Serv_ThreadCount", (int64_t)value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_IPC_Serv_ThreadCount(void) {
    return (int)lf_opt_get_i64("IPC_Serv_ThreadCount");
}

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_IPC_Serv_MaxQueueLength(int value) {
    lf_opt_set_i64("IPC_Serv_MaxQueueLength", (int64_t)value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_IPC_Serv_MaxQueueLength(void) {
    return (int)lf_opt_get_i64("IPC_Serv_MaxQueueLength");
}

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_IPC_Serv_MaxMsgSize(int value) {
    lf_opt_set_i64("IPC_Serv_MaxMsgSize", (int64_t)value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_IPC_Serv_MaxMsgSize(void) {
    return (int)lf_opt_get_i64("IPC_Serv_MaxMsgSize");
}

/* ---- Sequenced notifications ------------------------------------------ */

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_Fixed_Sequenced_Time(uint64_t value) {
    lf_opt_set_u64("Fixed_Sequenced_Time", value);
}

LF_OPT_LINKAGE uint64_t LF_OPT_INLINE
LF_Get_Opt_Fixed_Sequenced_Time(void) {
    return lf_opt_get_u64("Fixed_Sequenced_Time");
}

/* ---- P2P group name --------------------------------------------------- */

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_P2P_Name(const char* value) {
    LF_SetOption("LF_P2P_name", value == NULL ? "" : value);
}

LF_OPT_LINKAGE const char* LF_OPT_INLINE
LF_Get_Opt_P2P_Name(void) {
    return LF_GetOption("LF_P2P_name");
}

/* ---- Data handle pool ------------------------------------------------- */

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_DataHandle_Idle_Timeout(uint64_t value) {
    lf_opt_set_u64("DataHandle_Idle_Timeout", value);
}

LF_OPT_LINKAGE uint64_t LF_OPT_INLINE
LF_Get_Opt_DataHandle_Idle_Timeout(void) {
    return lf_opt_get_u64("DataHandle_Idle_Timeout");
}

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_DataHandle_Pool_Scan_Interval(uint64_t value) {
    lf_opt_set_u64("DataHandle_Pool_Scan_Interval", value);
}

LF_OPT_LINKAGE uint64_t LF_OPT_INLINE
LF_Get_Opt_DataHandle_Pool_Scan_Interval(void) {
    return lf_opt_get_u64("DataHandle_Pool_Scan_Interval");
}

/* ---- Command flushing ------------------------------------------------- */

LF_OPT_LINKAGE void LF_OPT_INLINE
LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(int value) {
    lf_opt_set_i64("No_Reponse_Cmd_NULL_Flush_Threshold", (int64_t)value);
}

LF_OPT_LINKAGE int LF_OPT_INLINE
LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(void) {
    return (int)lf_opt_get_i64("No_Reponse_Cmd_NULL_Flush_Threshold");
}

/* ============================================================================
 * Cleanup
 * ============================================================================
 *
 * Undefine the internal macros so that the header does not leak them
 * into the including translation unit.
 */

#undef LF_OPT_CDECL

#endif /* LINGOFUSE_OPT_H_INCLUDED */