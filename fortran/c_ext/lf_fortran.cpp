/**
 * @file lf_fortran.cpp
 * @brief Implementation of the C ABI declared in lf_fortran.h.
 *
 * Every function below:
 *   - is declared `extern "C"` so the Fortran runtime sees a plain
 *     C symbol,
 *   - ensures the LingoFuse runtime library is loaded before it
 *     touches any LF_* function,
 *   - catches every C++ exception internally and translates it into
 *     a failure return value,
 *   - never lets a C++ exception cross the ABI boundary.
 *
 * ============================================================================
 * LAYERING
 * ============================================================================
 *
 * This file is the L2 bridge. It calls into the LingoFuse C ABI
 * declared in LingoFuse.h (via the dynamic loader implemented in
 * LingoFuse.c) and translates between:
 *
 *   - the C struct-by-value UID representation (TP2P_UID) and the
 *     Fortran-friendly `int8_t[32]` array,
 *   - C++ exceptions and C-style return codes,
 *   - the transient pointers returned by LF_Get_P2P_UID /
 *     LF_Get_P2P_Name (released ~5 seconds later) and caller-owned
 *     buffers.
 *
 * ============================================================================
 * THREAD SAFETY
 * ============================================================================
 *
 * The bridge itself is stateless. The only mutable state is the
 * `std::once_flag` used for lazy loading, which is thread-safe by
 * construction. All callback context objects are heap-allocated per
 * registration (or per async call) and are not shared across threads.
 *
 * ============================================================================
 * CALLBACK CONTEXT LIFETIME
 * ============================================================================
 *
 * For app-bound Call / Notify registrations, the context object is
 * deliberately leaked:
 *
 *   - The LingoFuse library can invoke a callback at any time after
 *     registration, including concurrently with an unregister or
 *     destroy call.
 *   - Reclaiming the context would open a use-after-free window.
 *   - The cost is a few dozen bytes per registered API, which is
 *     negligible in any realistic program.
 *
 * For async calls, the context object is heap-allocated per call and
 * is destroyed by the trampoline BEFORE the user callback is invoked,
 * so the user callback is free to issue further async calls without
 * accumulating contexts.
 *
 * All comments and diagnostic output are in English.
 */

#include "lf_fortran.h"
#include "LingoFuse.h"

#include <cstring>
#include <mutex>
#include <new>

/* ============================================================================
 * Library lifecycle - lazy loading
 * ============================================================================ */

namespace {

std::once_flag g_load_flag;
bool           g_load_result = false;

void do_load() {
    g_load_result = (LF_LoadLibrary() == 1);
}

/**
 * Ensure the LingoFuse runtime is loaded.
 *
 * Runs at most once per process. After a successful load, subsequent
 * calls are a cheap boolean check.
 *
 * If the first load fails, the failure is cached: installing the
 * library after a failed attempt is not supported, and the process
 * must be restarted. This mirrors the behaviour of the C++ RAII
 * loader in LingoFuse.hpp and of every other LingoFuse binding.
 */
bool ensure_loaded() {
    std::call_once(g_load_flag, do_load);
    return g_load_result;
}

} /* anonymous namespace */

/* ============================================================================
 * Public lifecycle functions
 * ============================================================================ */

extern "C" int lf_load_library(void) {
    return ensure_loaded() ? 1 : 0;
}

extern "C" void lf_free_library(void) {
    try {
        LF_FreeLibrary();
    } catch (...) {
        /* Swallow. */
    }
    /* std::once_flag is not resettable in a portable way, so a
       subsequent lf_load_library call will simply report the cached
       result. Unloading and reloading within a single process is not
       a supported scenario. */
    g_load_result = false;
}

extern "C" void lf_shutdown(void) {
    if (!ensure_loaded()) return;
    try {
        LF_Shutdown();
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" void lf_exit_main_thread(void) {
    if (!ensure_loaded()) return;
    try {
        LF_ExitMainThread();
    } catch (...) {
        /* Swallow. */
    }
}

/* ============================================================================
 * Internal helpers
 * ============================================================================ */

namespace {

/* --- Callback contexts --------------------------------------------------
 *
 * The `trigger` slot of a registered API stores a pointer to one of
 * these structs. The native library hands the pointer back to our
 * trampoline, which then dispatches to the Fortran callback.
 *
 * See the file-level docstring for the lifetime policy.
 */

struct CallContext {
    LfFortranCallCallback callback;
};

struct NotifyContext {
    LfFortranNotifyCallback callback;
};

struct AsyncContext {
    LfFortranAsyncCallback callback;
    void*                  user_data;
};

/* --- Trampolines ------------------------------------------------------- */

void LF_CDECL call_trampoline(void* trigger, void* input, void* output) {
    if (!trigger) return;
    auto* ctx = static_cast<CallContext*>(trigger);
    if (!ctx->callback) return;
    try {
        ctx->callback(input, output);
    } catch (...) {
        /* Swallow; never let an exception reach the native stack. */
    }
}

void LF_CDECL notify_trampoline(void* trigger, void* input) {
    if (!trigger) return;
    auto* ctx = static_cast<NotifyContext*>(trigger);
    if (!ctx->callback) return;
    try {
        ctx->callback(input);
    } catch (...) {
        /* Swallow. */
    }
}

/**
 * Async trampoline.
 *
 * Reconstructs the AsyncContext from `data`, extracts the user callback
 * and the user data pointer, and DESTROYS the context BEFORE invoking
 * the user callback. This is critical: it means a user callback that
 * issues another async call does not accumulate contexts, and the
 * context is not leaked if the user callback throws.
 *
 * The `result` argument is an opaque handle that is OWNED BY THE
 * FRAMEWORK. It is released the instant this trampoline returns. The
 * user callback must NOT retain it and must NOT call lf_data_destroy
 * on it.
 */
void LF_CDECL async_trampoline(void* data, void* result) {
    auto* ctx = static_cast<AsyncContext*>(data);
    if (!ctx) return;

    LfFortranAsyncCallback cb        = ctx->callback;
    void*                  user_data = ctx->user_data;

    delete ctx;   /* release BEFORE calling the user callback */

    if (!cb) return;
    try {
        cb(user_data, result);
    } catch (...) {
        /* Swallow. */
    }
}

/* --- Safe string helpers ----------------------------------------------- */

/** Return a NUL-terminated string, using "" when the input is NULL. */
inline const char* safe_cstr(const char* s) {
    return s ? s : "";
}

/**
 * Copy a NUL-terminated source string into a fixed-size destination
 * buffer. On success, `out_len` receives the number of bytes copied
 * (excluding the terminator).
 *
 * Returns:
 *    0  success
 *   -1  null destination, null buffer, or non-positive size
 *   -2  destination too small (source length + 1 > buf_size)
 */
int copy_cstr_to_buf(const char* src,
                     char*       dst,
                     int64_t     buf_size,
                     int64_t*    out_len) {
    if (!dst || buf_size <= 0) return -1;
    const char* s = src ? src : "";
    const int64_t needed =
        static_cast<int64_t>(std::strlen(s)) + 1;  /* include NUL */
    if (needed > buf_size) return -2;
    std::memcpy(dst, s, static_cast<size_t>(needed));
    if (out_len) *out_len = needed - 1;
    return 0;
}

/* --- UID helpers ------------------------------------------------------- */

/**
 * Copy a Fortran `int8_t[32]` into a LingoFuse `TP2P_UID` struct.
 * The `int8_t` element type is the only 8-bit type Fortran can use
 * portably; the underlying bytes are the same regardless of signedness.
 */
inline void uid_array_to_struct(const int8_t* src, TP2P_UID& dst) {
    std::memcpy(dst.bytes, src, LF_UID_BYTE_COUNT);
}

/**
 * Copy a LingoFuse `TP2P_UID` struct into a Fortran `int8_t[32]`.
 */
inline void uid_struct_to_array(const TP2P_UID& src, int8_t* dst) {
    std::memcpy(dst, src.bytes, LF_UID_BYTE_COUNT);
}

/**
 * Parse one hex character into a 4-bit nibble. Accepts both cases.
 * Returns false for any non-hex character.
 */
inline bool hex_char_to_nibble(char c, uint8_t& out) {
    if (c >= '0' && c <= '9') { out = static_cast<uint8_t>(c - '0');      return true; }
    if (c >= 'a' && c <= 'f') { out = static_cast<uint8_t>(c - 'a' + 10); return true; }
    if (c >= 'A' && c <= 'F') { out = static_cast<uint8_t>(c - 'A' + 10); return true; }
    return false;
}

/**
 * Generic async submission helper.
 *
 * `issue` is a callable that takes the AsyncContext pointer as a
 * `void*` and returns the C ABI's int result code (1 = dispatched,
 * anything else = not dispatched). It must NOT throw; if it does, the
 * helper treats it as a dispatch failure.
 *
 * On success, ownership of the context passes to the framework (via
 * `async_trampoline`). On failure, the helper invokes the user
 * callback SYNCHRONOUSLY on the caller's thread with a NULL result,
 * then destroys the context.
 */
template <typename IssueFn>
int submit_async_call(IssueFn&&               issue,
                      LfFortranAsyncCallback  cb,
                      void*                   user_data) {
    if (!cb) return 0;

    auto* ctx = new (std::nothrow) AsyncContext{cb, user_data};
    if (!ctx) return 0;

    int rc = 0;
    try {
        rc = issue(static_cast<void*>(ctx));
    } catch (...) {
        rc = 0;
    }

    if (rc != 1) {
        /* Dispatch failed; the framework will never invoke the
           callback. Invoke it ourselves with a NULL result so that the
           user has a single, unified failure path. */
        delete ctx;
        try {
            cb(user_data, nullptr);
        } catch (...) {
            /* Swallow. */
        }
        return 0;
    }
    return 1;
}

} /* anonymous namespace */

/* ============================================================================
 * Application handle
 * ============================================================================ */

extern "C" LfAppHandle lf_app_create(const char* name, const char* desc) {
    if (!name) return nullptr;
    if (!ensure_loaded()) return nullptr;
    try {
        TAppHnd hnd = LF_CreateApp(name, safe_cstr(desc));
        return static_cast<LfAppHandle>(hnd);
    } catch (...) {
        return nullptr;
    }
}

extern "C" void lf_app_destroy(LfAppHandle app) {
    if (!app) return;
    if (!ensure_loaded()) return;
    try {
        LF_FreeApp(static_cast<TAppHnd>(app));
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" int lf_app_register_call(LfAppHandle            app,
                                    const char*            api,
                                    const char*            desc,
                                    LfFortranCallCallback  callback) {
    if (!app || !api || !callback) return 0;
    if (!ensure_loaded()) return 0;
    try {
        auto* ctx = new (std::nothrow) CallContext{callback};
        if (!ctx) return 0;
        const int rc = LF_RegisterCall(
            static_cast<TAppHnd>(app),
            api,
            safe_cstr(desc),
            ctx,
            &call_trampoline);
        if (rc != 1) {
            /* The native layer refused the registration; the trigger
               was not stored, so reclaiming the context here is safe. */
            delete ctx;
            return 0;
        }
        return 1;
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_app_register_notify(LfAppHandle              app,
                                      const char*              api,
                                      const char*              desc,
                                      LfFortranNotifyCallback  callback) {
    if (!app || !api || !callback) return 0;
    if (!ensure_loaded()) return 0;
    try {
        auto* ctx = new (std::nothrow) NotifyContext{callback};
        if (!ctx) return 0;
        const int rc = LF_RegisterNotify(
            static_cast<TAppHnd>(app),
            api,
            safe_cstr(desc),
            ctx,
            &notify_trampoline);
        if (rc != 1) {
            delete ctx;
            return 0;
        }
        return 1;
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_app_unregister(LfAppHandle app, const char* api) {
    if (!app || !api) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_Unregister(static_cast<TAppHnd>(app), api);
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_bind_app(LfAppHandle app) {
    if (!app) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_BindApp(static_cast<TAppHnd>(app));
    } catch (...) {
        return 0;
    }
}

extern "C" int64_t lf_get_app_name(LfAppHandle app,
                                   char*       buf,
                                   int64_t     buf_size) {
    if (!app || !buf || buf_size <= 0) return -1;
    if (!ensure_loaded()) return -1;
    try {
        const char* name = LF_Get_AppName(static_cast<TAppHnd>(app));
        int64_t out_len = 0;
        const int rc = copy_cstr_to_buf(name, buf, buf_size, &out_len);
        return (rc == 0) ? out_len : static_cast<int64_t>(rc);
    } catch (...) {
        return -1;
    }
}

extern "C" int64_t lf_generate_app_name(char* buf, int64_t buf_size) {
    if (!buf || buf_size <= 0) return -1;
    if (!ensure_loaded()) return -1;
    try {
        const char* name = LF_Generate_AppName();
        int64_t out_len = 0;
        const int rc = copy_cstr_to_buf(name, buf, buf_size, &out_len);
        return (rc == 0) ? out_len : static_cast<int64_t>(rc);
    } catch (...) {
        return -1;
    }
}

/* ============================================================================
 * Process-wide P2P API registration
 * ============================================================================ */

extern "C" int lf_register_p2p_call(const char*            api,
                                    const char*            desc,
                                    LfFortranCallCallback  callback) {
    if (!api || !callback) return 0;
    if (!ensure_loaded()) return 0;
    try {
        auto* ctx = new (std::nothrow) CallContext{callback};
        if (!ctx) return 0;
        const int rc = LF_Register_P2P_Call(
            api,
            safe_cstr(desc),
            ctx,
            &call_trampoline);
        if (rc != 1) {
            delete ctx;
            return 0;
        }
        return 1;
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_register_p2p_notify(const char*              api,
                                      const char*              desc,
                                      LfFortranNotifyCallback  callback) {
    if (!api || !callback) return 0;
    if (!ensure_loaded()) return 0;
    try {
        auto* ctx = new (std::nothrow) NotifyContext{callback};
        if (!ctx) return 0;
        const int rc = LF_Register_P2P_Notify(
            api,
            safe_cstr(desc),
            ctx,
            &notify_trampoline);
        if (rc != 1) {
            delete ctx;
            return 0;
        }
        return 1;
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_unregister_p2p(const char* api) {
    if (!api) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_Unregister_P2P(api);
    } catch (...) {
        return 0;
    }
}

/* ============================================================================
 * Data handle - creation / destruction
 * ============================================================================ */

extern "C" LfDataHandle lf_data_create(const char* api_name) {
    if (!api_name) return nullptr;
    if (!ensure_loaded()) return nullptr;
    try {
        return static_cast<LfDataHandle>(LF_CreateData(api_name));
    } catch (...) {
        return nullptr;
    }
}

extern "C" LfDataHandle lf_data_create_permanent(const char* api_name) {
    if (!api_name) return nullptr;
    if (!ensure_loaded()) return nullptr;
    try {
        return static_cast<LfDataHandle>(LF_CreateData_Permanent(api_name));
    } catch (...) {
        return nullptr;
    }
}

extern "C" void lf_data_destroy(LfDataHandle hnd) {
    if (!hnd) return;
    if (!ensure_loaded()) return;
    try {
        LF_FreeData(static_cast<TDataHnd>(hnd));
    } catch (...) {
        /* Swallow. */
    }
}

/* ============================================================================
 * Scalar I/O
 * ============================================================================ */

extern "C" int lf_data_write_int8(LfDataHandle h, int8_t v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteInt8(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_int16(LfDataHandle h, int16_t v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteInt16(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_int32(LfDataHandle h, int32_t v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteInt32(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_int64(LfDataHandle h, int64_t v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteInt64(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_uint8(LfDataHandle h, uint8_t v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteUInt8(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_uint16(LfDataHandle h, uint16_t v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteUInt16(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_uint32(LfDataHandle h, uint32_t v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteUInt32(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_uint64(LfDataHandle h, uint64_t v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteUInt64(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_float32(LfDataHandle h, float v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteSingle(static_cast<TDataHnd>(h), v);
}
extern "C" int lf_data_write_float64(LfDataHandle h, double v) {
    if (!ensure_loaded()) return 0;
    return LF_WriteDouble(static_cast<TDataHnd>(h), v);
}

extern "C" int lf_data_read_int8(LfDataHandle h, int8_t* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadInt8(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_int16(LfDataHandle h, int16_t* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadInt16(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_int32(LfDataHandle h, int32_t* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadInt32(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_int64(LfDataHandle h, int64_t* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadInt64(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_uint8(LfDataHandle h, uint8_t* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadUInt8(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_uint16(LfDataHandle h, uint16_t* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadUInt16(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_uint32(LfDataHandle h, uint32_t* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadUInt32(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_uint64(LfDataHandle h, uint64_t* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadUInt64(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_float32(LfDataHandle h, float* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadSingle(static_cast<TDataHnd>(h), o);
}
extern "C" int lf_data_read_float64(LfDataHandle h, double* o) {
    if (!ensure_loaded()) return 0;
    return LF_ReadDouble(static_cast<TDataHnd>(h), o);
}

/* ============================================================================
 * Byte / string I/O
 * ============================================================================ */

extern "C" int lf_data_write_bytes(LfDataHandle h,
                                   const void*  data,
                                   int64_t      len) {
    if (!h || len < 0) return 0;
    if (!data && len > 0) return 0;
    if (!ensure_loaded()) return 0;
    try {
        const int64_t written = LF_WriteBuffer(
            static_cast<TDataHnd>(h), data, len);
        return (written == len) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

extern "C" int64_t lf_data_read_bytes(LfDataHandle h,
                                      void*        data,
                                      int64_t      len) {
    if (!h || len < 0) return -1;
    if (!data && len > 0) return -1;
    if (!ensure_loaded()) return -1;
    try {
        return LF_ReadBuffer(static_cast<TDataHnd>(h), data, len);
    } catch (...) {
        return -1;
    }
}

extern "C" int lf_data_write_string(LfDataHandle h, const char* str) {
    if (!h || !str) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_WriteString(static_cast<TDataHnd>(h), str);
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_data_write_string_bytes(LfDataHandle h,
                                          const void*  data,
                                          int64_t      len) {
    if (!h || len < 0) return 0;
    if (!data && len > 0) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_WriteStringBytes(static_cast<TDataHnd>(h), data, len);
    } catch (...) {
        return 0;
    }
}

extern "C" int64_t lf_data_read_string(LfDataHandle h,
                                       char*        buf,
                                       int64_t      buf_size) {
    if (!h || !buf || buf_size <= 0) return -1;
    if (!ensure_loaded()) return -1;
    try {
        const int rc = LF_ReadString(
            static_cast<TDataHnd>(h), buf, static_cast<size_t>(buf_size));
        if (rc != 1) return -1;
        return static_cast<int64_t>(std::strlen(buf));
    } catch (...) {
        return -1;
    }
}

extern "C" int64_t lf_data_read_string_bytes(LfDataHandle h,
                                             void*        buf,
                                             int64_t      buf_size) {
    if (!h || !buf || buf_size < 0) return -1;
    if (!ensure_loaded()) return -1;
    try {
        const int64_t rc = LF_ReadStringBytes(
            static_cast<TDataHnd>(h), buf, buf_size);
        if (rc < 0) return -1;
        return rc;
    } catch (...) {
        return -1;
    }
}

extern "C" int64_t lf_data_read_all_bytes(LfDataHandle h,
                                          void*        buf,
                                          int64_t      buf_size) {
    if (!h || !buf || buf_size < 0) return -1;
    if (!ensure_loaded()) return -1;
    try {
        const int64_t pos = LF_GetPos(static_cast<TDataHnd>(h));
        const int64_t sz  = LF_GetSize(static_cast<TDataHnd>(h));
        if (pos < 0 || pos >= sz) return 0;
        const int64_t remaining = sz - pos;
        if (remaining > buf_size) return -2;
        const int64_t got = LF_ReadBuffer(
            static_cast<TDataHnd>(h), buf, remaining);
        if (got < 0) return -1;
        return got;
    } catch (...) {
        return -1;
    }
}

extern "C" int lf_data_write_json(LfDataHandle h, const char* json_str) {
    if (!h || !json_str) return 0;
    if (!ensure_loaded()) return 0;
    try {
        /* JSON is passed through as a NUL-terminated UTF-8 string.
           The LingoFuse layer treats it as opaque bytes; no validation
           is performed here. */
        return LF_WriteString(static_cast<TDataHnd>(h), json_str);
    } catch (...) {
        return 0;
    }
}

extern "C" int64_t lf_data_read_json(LfDataHandle h,
                                     char*        buf,
                                     int64_t      buf_size) {
    /* Identical to lf_data_read_string. Provided as a separate name
       for readability at the call site. */
    return lf_data_read_string(h, buf, buf_size);
}

/* ============================================================================
 * Cursor / size
 * ============================================================================ */

extern "C" int64_t lf_data_get_position(LfDataHandle h) {
    if (!h) return -1;
    if (!ensure_loaded()) return -1;
    try {
        return LF_GetPos(static_cast<TDataHnd>(h));
    } catch (...) {
        return -1;
    }
}

extern "C" void lf_data_set_position(LfDataHandle h, int64_t pos) {
    if (!h) return;
    if (!ensure_loaded()) return;
    try {
        LF_SetPos(static_cast<TDataHnd>(h), pos);
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" int64_t lf_data_get_size(LfDataHandle h) {
    if (!h) return -1;
    if (!ensure_loaded()) return -1;
    try {
        return LF_GetSize(static_cast<TDataHnd>(h));
    } catch (...) {
        return -1;
    }
}

extern "C" void lf_data_set_size(LfDataHandle h, int64_t size) {
    if (!h) return;
    if (!ensure_loaded()) return;
    try {
        LF_SetSize(static_cast<TDataHnd>(h), size);
    } catch (...) {
        /* Swallow. */
    }
}

/* ============================================================================
 * UID binary I/O (ARGUMENT-role)
 * ============================================================================
 *
 * The Fortran-facing representation is `int8_t[32]`. The C ABI uses a
 * `TP2P_UID` struct. This bridge performs the conversion internally;
 * Fortran never sees the struct.
 */

extern "C" int lf_data_write_uid(LfDataHandle h, const int8_t* uid_32) {
    if (!h || !uid_32) return 0;
    if (!ensure_loaded()) return 0;
    try {
        TP2P_UID uid;
        uid_array_to_struct(uid_32, uid);
        return LF_WriteUid(static_cast<TDataHnd>(h), uid);
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_data_read_uid(LfDataHandle h, int8_t* out_uid_32) {
    if (!h || !out_uid_32) return 0;
    if (!ensure_loaded()) return 0;
    try {
        TP2P_UID uid;
        std::memset(&uid, 0, sizeof(uid));
        const int rc = LF_ReadUid(static_cast<TDataHnd>(h), &uid);
        if (rc != 1) return 0;
        uid_struct_to_array(uid, out_uid_32);
        return 1;
    } catch (...) {
        return 0;
    }
}

/* ============================================================================
 * P2P identity accessors (INPUT handles only)
 * ============================================================================
 *
 * The underlying LF_Get_P2P_UID returns a POINTER to a 32-byte UID that
 * the library releases about 5 seconds after the call. We copy the
 * bytes into the caller's buffer IMMEDIATELY and never expose the
 * pointer.
 *
 * LF_Get_P2P_Name returns a NUL-terminated string with the same
 * lifetime rule. We copy it into the caller's buffer immediately.
 *
 * Both functions are only meaningful when called on the input handle
 * of a registered callback. On any other handle, the underlying library
 * returns a zero-filled UID / an empty string; we forward that value
 * faithfully.
 */

extern "C" int lf_data_get_p2p_uid(LfDataHandle h, int8_t* out_uid_32) {
    if (!out_uid_32) return 0;
    if (!ensure_loaded()) return 0;

    /* Clear the output first so that every return path yields a
       well-defined value. */
    std::memset(out_uid_32, 0, LF_UID_BYTE_COUNT);

    if (!h) return 0;

    try {
        const TP2P_UID* p = LF_Get_P2P_UID(static_cast<TDataHnd>(h));
        if (!p) {
            /* The wrapper returns NULL only if the library was not
               loaded, which we have already ruled out. Treat any
               other NULL as a failure. */
            return 0;
        }
        std::memcpy(out_uid_32, p->bytes, LF_UID_BYTE_COUNT);
        return 1;
    } catch (...) {
        return 0;
    }
}

extern "C" int64_t lf_data_get_p2p_name(LfDataHandle h,
                                        char*        buf,
                                        int64_t      buf_size) {
    if (!buf || buf_size <= 0) return -1;
    if (!ensure_loaded()) return -1;

    /* Establish a well-defined empty result on every failure path. */
    buf[0] = '\0';

    if (!h) return -1;

    try {
        const char* name = LF_Get_P2P_Name(static_cast<TDataHnd>(h));
        int64_t out_len = 0;
        const int rc = copy_cstr_to_buf(name, buf, buf_size, &out_len);
        return (rc == 0) ? out_len : static_cast<int64_t>(rc);
    } catch (...) {
        return -1;
    }
}

/* ============================================================================
 * UID <-> hex helpers
 * ============================================================================ */

extern "C" int lf_uid_to_hex(const int8_t* uid_32, char* out_hex) {
    if (!uid_32 || !out_hex) return 0;
    static const char kHex[] = "0123456789abcdef";
    for (int i = 0; i < LF_UID_BYTE_COUNT; ++i) {
        const uint8_t b = static_cast<uint8_t>(uid_32[i]);
        out_hex[i * 2]     = kHex[(b >> 4) & 0x0F];
        out_hex[i * 2 + 1] = kHex[b & 0x0F];
    }
    out_hex[LF_UID_BYTE_COUNT * 2] = '\0';
    return 1;
}

extern "C" int lf_uid_from_hex(const char* hex, int8_t* out_uid_32) {
    if (!hex || !out_uid_32) return 0;

    int8_t tmp[LF_UID_BYTE_COUNT];
    for (int i = 0; i < LF_UID_BYTE_COUNT; ++i) {
        uint8_t hi = 0, lo = 0;
        if (!hex_char_to_nibble(hex[i * 2],     hi)) return 0;
        if (!hex_char_to_nibble(hex[i * 2 + 1], lo)) return 0;
        tmp[i] = static_cast<int8_t>((hi << 4) | lo);
    }

    /* Only commit on full success, so a malformed input never leaves
       a partially-written output. */
    std::memcpy(out_uid_32, tmp, LF_UID_BYTE_COUNT);
    return 1;
}

/* ============================================================================
 * Network preparation
 * ============================================================================ */

extern "C" void lf_reset_prepare(void) {
    if (!ensure_loaded()) return;
    try {
        LF_ResetPrepare();
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" int lf_prepare_service(const char* listening_addr,
                                  const char* phys_addr) {
    if (!listening_addr || !phys_addr) return -1;
    if (!ensure_loaded()) return -1;
    try {
        return LF_PrepareService(listening_addr, phys_addr);
    } catch (...) {
        return -1;
    }
}

extern "C" int lf_prepare_client(const char* phys_addr, LfAppHandle app) {
    if (!phys_addr) return -1;
    if (!ensure_loaded()) return -1;
    try {
        return LF_PrepareClient(
            phys_addr,
            static_cast<TAppHnd>(app));
    } catch (...) {
        return -1;
    }
}

extern "C" int lf_prepare_done(void) {
    if (!ensure_loaded()) return -1;
    try {
        return LF_PrepareDone();
    } catch (...) {
        return -1;
    }
}

/* ============================================================================
 * Remote invocation - app-name addressing
 * ============================================================================ */

extern "C" LfDataHandle lf_call(const char* app_name,
                                LfDataHandle param,
                                uint64_t     timeout_ms) {
    if (!app_name || !param) return nullptr;
    if (!ensure_loaded()) return nullptr;
    try {
        return static_cast<LfDataHandle>(
            LF_Call(app_name, static_cast<TDataHnd>(param), timeout_ms));
    } catch (...) {
        return nullptr;
    }
}

extern "C" LfDataHandle lf_local_call(LfAppHandle app, LfDataHandle param) {
    if (!app || !param) return nullptr;
    if (!ensure_loaded()) return nullptr;
    try {
        return static_cast<LfDataHandle>(
            LF_LocalCall(static_cast<TAppHnd>(app),
                         static_cast<TDataHnd>(param)));
    } catch (...) {
        return nullptr;
    }
}

extern "C" void lf_notify(const char* app_name, LfDataHandle param) {
    if (!app_name || !param) return;
    if (!ensure_loaded()) return;
    try {
        LF_Notify(app_name, static_cast<TDataHnd>(param));
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" void lf_sequenced_notify(const char* app_name, LfDataHandle param) {
    if (!app_name || !param) return;
    if (!ensure_loaded()) return;
    try {
        LF_Sequenced_Notify(app_name, static_cast<TDataHnd>(param));
    } catch (...) {
        /* Swallow. */
    }
}

/* ============================================================================
 * Remote invocation - UID addressing
 * ============================================================================
 *
 * The Fortran-facing UID argument is `const int8_t*` pointing to 32
 * bytes. The C ABI expects a `TP2P_UID` struct BY VALUE. The bridge
 * performs the conversion internally.
 */

extern "C" LfDataHandle lf_call_uid(const int8_t* uid_32,
                                    LfDataHandle  param,
                                    uint64_t      timeout_ms) {
    if (!uid_32 || !param) return nullptr;
    if (!ensure_loaded()) return nullptr;
    try {
        TP2P_UID uid;
        uid_array_to_struct(uid_32, uid);
        return static_cast<LfDataHandle>(
            LF_UID_Call(uid, static_cast<TDataHnd>(param), timeout_ms));
    } catch (...) {
        return nullptr;
    }
}

extern "C" void lf_notify_uid(const int8_t* uid_32, LfDataHandle param) {
    if (!uid_32 || !param) return;
    if (!ensure_loaded()) return;
    try {
        TP2P_UID uid;
        uid_array_to_struct(uid_32, uid);
        LF_UID_Notify(uid, static_cast<TDataHnd>(param));
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" void lf_sequenced_notify_uid(const int8_t* uid_32,
                                        LfDataHandle  param) {
    if (!uid_32 || !param) return;
    if (!ensure_loaded()) return;
    try {
        TP2P_UID uid;
        uid_array_to_struct(uid_32, uid);
        LF_UID_Sequenced_Notify(uid, static_cast<TDataHnd>(param));
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" int lf_check_uid(const int8_t* uid_32) {
    if (!uid_32) return 0;
    if (!ensure_loaded()) return 0;
    try {
        TP2P_UID uid;
        uid_array_to_struct(uid_32, uid);
        return LF_Check_UID(uid);
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_check_uid_api(const int8_t* uid_32,
                                const char*   api_name) {
    if (!uid_32 || !api_name) return 0;
    if (!ensure_loaded()) return 0;
    try {
        TP2P_UID uid;
        uid_array_to_struct(uid_32, uid);
        return LF_Check_UID_Api(uid, api_name);
    } catch (...) {
        return 0;
    }
}

/* ============================================================================
 * Remote invocation - P2PName addressing
 * ============================================================================ */

extern "C" LfDataHandle lf_call_p2pname(const char*  p2p_name,
                                        LfDataHandle param,
                                        uint64_t     timeout_ms) {
    if (!p2p_name || !param) return nullptr;
    if (!ensure_loaded()) return nullptr;
    try {
        return static_cast<LfDataHandle>(
            LF_P2PNAME_Call(p2p_name,
                            static_cast<TDataHnd>(param),
                            timeout_ms));
    } catch (...) {
        return nullptr;
    }
}

extern "C" void lf_notify_p2pname(const char*  p2p_name,
                                  LfDataHandle param) {
    if (!p2p_name || !param) return;
    if (!ensure_loaded()) return;
    try {
        LF_P2PNAME_Notify(p2p_name, static_cast<TDataHnd>(param));
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" void lf_sequenced_notify_p2pname(const char*  p2p_name,
                                            LfDataHandle param) {
    if (!p2p_name || !param) return;
    if (!ensure_loaded()) return;
    try {
        LF_P2PNAME_Sequenced_Notify(p2p_name, static_cast<TDataHnd>(param));
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" int lf_check_p2pname(const char* p2p_name) {
    if (!p2p_name) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_Check_P2PNAME(p2p_name);
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_check_p2pname_api(const char* p2p_name,
                                    const char* api_name) {
    if (!p2p_name || !api_name) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_Check_P2PNAME_Api(p2p_name, api_name);
    } catch (...) {
        return 0;
    }
}

/* ============================================================================
 * Asynchronous invocation
 * ============================================================================
 *
 * Every async entry point has the same shape:
 *
 *   1. Validate the arguments.
 *   2. Allocate an AsyncContext.
 *   3. Hand the context to the C ABI's LF_Async_* function as the
 *      opaque `data` pointer, with `async_trampoline` as the callback.
 *   4. If the C ABI returns 1, ownership of the context has passed to
 *      the framework. Return 1.
 *   5. If the C ABI returns anything else, invoke the user callback
 *      SYNCHRONOUSLY with a NULL result, destroy the context, and
 *      return 0.
 *
 * The user therefore sees exactly one callback invocation per call,
 * and can treat a NULL result uniformly as a failure.
 */

extern "C" int lf_async_call(const char*             app_name,
                             LfDataHandle            param,
                             LfFortranAsyncCallback  callback,
                             void*                   user_data) {
    if (!app_name || !param) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    if (!ensure_loaded()) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    return submit_async_call(
        [&](void* ctx) -> int {
            return LF_Async_Call(
                app_name,
                static_cast<TDataHnd>(param),
                ctx,
                &async_trampoline);
        },
        callback,
        user_data);
}

extern "C" int lf_async_sequenced_call(const char*             app_name,
                                       LfDataHandle            param,
                                       LfFortranAsyncCallback  callback,
                                       void*                   user_data) {
    if (!app_name || !param) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    if (!ensure_loaded()) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    return submit_async_call(
        [&](void* ctx) -> int {
            return LF_Async_Sequenced_Call(
                app_name,
                static_cast<TDataHnd>(param),
                ctx,
                &async_trampoline);
        },
        callback,
        user_data);
}

extern "C" int lf_async_call_uid(const int8_t*           uid_32,
                                 LfDataHandle            param,
                                 LfFortranAsyncCallback  callback,
                                 void*                   user_data) {
    if (!uid_32 || !param) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    if (!ensure_loaded()) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    return submit_async_call(
        [&](void* ctx) -> int {
            TP2P_UID uid;
            uid_array_to_struct(uid_32, uid);
            return LF_UID_Async_Call(
                uid,
                static_cast<TDataHnd>(param),
                ctx,
                &async_trampoline);
        },
        callback,
        user_data);
}

extern "C" int lf_async_sequenced_call_uid(const int8_t*           uid_32,
                                           LfDataHandle            param,
                                           LfFortranAsyncCallback  callback,
                                           void*                   user_data) {
    if (!uid_32 || !param) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    if (!ensure_loaded()) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    return submit_async_call(
        [&](void* ctx) -> int {
            TP2P_UID uid;
            uid_array_to_struct(uid_32, uid);
            return LF_UID_Async_Sequenced_Call(
                uid,
                static_cast<TDataHnd>(param),
                ctx,
                &async_trampoline);
        },
        callback,
        user_data);
}

extern "C" int lf_async_call_p2pname(const char*             p2p_name,
                                     LfDataHandle            param,
                                     LfFortranAsyncCallback  callback,
                                     void*                   user_data) {
    if (!p2p_name || !param) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    if (!ensure_loaded()) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    return submit_async_call(
        [&](void* ctx) -> int {
            return LF_P2PNAME_Async_Call(
                p2p_name,
                static_cast<TDataHnd>(param),
                ctx,
                &async_trampoline);
        },
        callback,
        user_data);
}

extern "C" int lf_async_sequenced_call_p2pname(
        const char*             p2p_name,
        LfDataHandle            param,
        LfFortranAsyncCallback  callback,
        void*                   user_data) {
    if (!p2p_name || !param) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    if (!ensure_loaded()) {
        if (callback) {
            try { callback(user_data, nullptr); } catch (...) {}
        }
        return 0;
    }
    return submit_async_call(
        [&](void* ctx) -> int {
            return LF_P2PNAME_Async_Sequenced_Call(
                p2p_name,
                static_cast<TDataHnd>(param),
                ctx,
                &async_trampoline);
        },
        callback,
        user_data);
}

/* ============================================================================
 * Options - generic accessors
 * ============================================================================ */

extern "C" void lf_set_option(const char* option, const char* value) {
    if (!option || !value) return;
    if (!ensure_loaded()) return;
    try {
        LF_SetOption(option, value);
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" int64_t lf_get_option(const char* option,
                                 char*       buf,
                                 int64_t     buf_size) {
    if (!option || !buf || buf_size <= 0) return -1;
    if (!ensure_loaded()) return -1;
    buf[0] = '\0';
    try {
        const char* value = LF_GetOption(option);
        int64_t out_len = 0;
        const int rc = copy_cstr_to_buf(value, buf, buf_size, &out_len);
        return (rc == 0) ? out_len : static_cast<int64_t>(rc);
    } catch (...) {
        return -1;
    }
}

/* ============================================================================
 * Options - typed shortcuts
 * ============================================================================
 *
 * Direct forwarders to the C helper functions implemented in
 * LingoFuse.c (LF_Set_Opt_* / LF_Get_Opt_*). Those helpers wrap
 * LF_SetOption / LF_GetOption with the canonical wire form ("True" /
 * "False" for booleans, decimal strings for integers) and are already
 * cross-validated against the Pascal helpers.
 *
 * The password and debug getters return process-static string
 * constants; the underlying library always returns a fixed mask /
 * placeholder for these two options, so the pointer is safe to hold
 * indefinitely.
 */

/* ---- Authentication ---- */

extern "C" void lf_set_opt_password(const char* value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_Password(safe_cstr(value)); } catch (...) {}
}

extern "C" const char* lf_get_opt_password(void) {
    if (!ensure_loaded()) return "";
    try {
        const char* v = LF_Get_Opt_Password();
        /* LF_Get_Opt_Password returns the fixed mask "********".
           The library never exposes the real password. */
        return v ? v : "";
    } catch (...) {
        return "";
    }
}

/* ---- Logging and diagnostics ---- */

extern "C" void lf_set_opt_debug(const char* value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_Debug(safe_cstr(value)); } catch (...) {}
}

extern "C" const char* lf_get_opt_debug(void) {
    if (!ensure_loaded()) return "";
    try {
        const char* v = LF_Get_Opt_Debug();
        /* The debug option is write-only; the library returns a
           fixed placeholder string. */
        return v ? v : "";
    } catch (...) {
        return "";
    }
}

extern "C" void lf_set_opt_quiet(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_Quiet(value); } catch (...) {}
}

extern "C" int lf_get_opt_quiet(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_Quiet(); } catch (...) { return 0; }
}

extern "C" void lf_set_opt_show_thread_id(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_ShowThreadID(value); } catch (...) {}
}

extern "C" int lf_get_opt_show_thread_id(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_ShowThreadID(); } catch (...) { return 0; }
}

extern "C" void lf_set_opt_console_output(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_ConsoleOutput(value); } catch (...) {}
}

extern "C" int lf_get_opt_console_output(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_ConsoleOutput(); } catch (...) { return 0; }
}

/* ---- Connection readiness ---- */

extern "C" void lf_set_opt_overlap_connection(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_Overlap_Connection(value); } catch (...) {}
}

extern "C" int lf_get_opt_overlap_connection(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_Overlap_Connection(); } catch (...) { return 0; }
}

extern "C" void lf_set_opt_wait_ready_ok(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_Wait_Connection_ReadyOk(value); } catch (...) {}
}

extern "C" int lf_get_opt_wait_ready_ok(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_Wait_Connection_ReadyOk(); } catch (...) { return 0; }
}

extern "C" void lf_set_opt_wait_timeout(uint64_t value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_Wait_Connection_Timeout(value); } catch (...) {}
}

extern "C" uint64_t lf_get_opt_wait_timeout(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_Wait_Connection_Timeout(); } catch (...) { return 0; }
}

/* ---- IPC ---- */

extern "C" void lf_set_opt_ipc_thread_count(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_IPC_Serv_ThreadCount(value); } catch (...) {}
}

extern "C" int lf_get_opt_ipc_thread_count(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_IPC_Serv_ThreadCount(); } catch (...) { return 0; }
}

extern "C" void lf_set_opt_ipc_max_queue(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_IPC_Serv_MaxQueueLength(value); } catch (...) {}
}

extern "C" int lf_get_opt_ipc_max_queue(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_IPC_Serv_MaxQueueLength(); } catch (...) { return 0; }
}

extern "C" void lf_set_opt_ipc_max_msg_size(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_IPC_Serv_MaxMsgSize(value); } catch (...) {}
}

extern "C" int lf_get_opt_ipc_max_msg_size(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_IPC_Serv_MaxMsgSize(); } catch (...) { return 0; }
}

/* ---- Sequenced notifications ---- */

extern "C" void lf_set_opt_fixed_sequenced_time(uint64_t value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_Fixed_Sequenced_Time(value); } catch (...) {}
}

extern "C" uint64_t lf_get_opt_fixed_sequenced_time(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_Fixed_Sequenced_Time(); } catch (...) { return 0; }
}

/* ---- P2P group name ---- */

extern "C" void lf_set_opt_p2p_name(const char* value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_P2P_Name(safe_cstr(value)); } catch (...) {}
}

extern "C" int64_t lf_get_opt_p2p_name(char* buf, int64_t buf_size) {
    if (!buf || buf_size <= 0) return -1;
    if (!ensure_loaded()) return -1;
    buf[0] = '\0';
    try {
        /* LF_Get_Opt_P2P_Name returns a transient pointer that the
           library releases ~5 seconds after the call. Copy it
           immediately. */
        const char* v = LF_Get_Opt_P2P_Name();
        int64_t out_len = 0;
        const int rc = copy_cstr_to_buf(v, buf, buf_size, &out_len);
        return (rc == 0) ? out_len : static_cast<int64_t>(rc);
    } catch (...) {
        return -1;
    }
}

/* ---- Data handle pool ---- */

extern "C" void lf_set_opt_data_idle_timeout(uint64_t value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_DataHandle_Idle_Timeout(value); } catch (...) {}
}

extern "C" uint64_t lf_get_opt_data_idle_timeout(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_Get_Opt_DataHandle_Idle_Timeout(); } catch (...) { return 0; }
}

extern "C" void lf_set_opt_data_scan_interval(uint64_t value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_DataHandle_Pool_Scan_Interval(value); } catch (...) {}
}

extern "C" uint64_t lf_get_opt_data_scan_interval(void) {
    if (!ensure_loaded()) return 0;
    try {
        return LF_Get_Opt_DataHandle_Pool_Scan_Interval();
    } catch (...) {
        return 0;
    }
}

/* ---- Command flushing ---- */

extern "C" void lf_set_opt_null_flush_threshold(int value) {
    if (!ensure_loaded()) return;
    try { LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(value); } catch (...) {}
}

extern "C" int lf_get_opt_null_flush_threshold(void) {
    if (!ensure_loaded()) return 0;
    try {
        return LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold();
    } catch (...) {
        return 0;
    }
}

/* ============================================================================
 * Queries and diagnostics
 * ============================================================================ */

extern "C" int lf_check_main_thread(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_CheckMainThread(); } catch (...) { return 0; }
}

extern "C" int lf_check_app(const char* app_name) {
    if (!app_name) return 0;
    if (!ensure_loaded()) return 0;
    try { return LF_CheckApp(app_name); } catch (...) { return 0; }
}

extern "C" int lf_check_api(const char* app_name, const char* api_name) {
    if (!app_name || !api_name) return 0;
    if (!ensure_loaded()) return 0;
    try { return LF_CheckApi(app_name, api_name); } catch (...) { return 0; }
}

extern "C" int lf_get_status_count(void) {
    if (!ensure_loaded()) return 0;
    try { return LF_GetStatusCount(); } catch (...) { return 0; }
}

extern "C" int64_t lf_get_status(char* buf, int64_t buf_size) {
    if (!buf || buf_size <= 0) return -1;
    if (!ensure_loaded()) return -1;
    buf[0] = '\0';
    try {
        const char* msg = LF_GetStatus();
        int64_t out_len = 0;
        const int rc = copy_cstr_to_buf(msg, buf, buf_size, &out_len);
        return (rc == 0) ? out_len : static_cast<int64_t>(rc);
    } catch (...) {
        return -1;
    }
}

extern "C" void lf_post_status(const char* message) {
    if (!message) return;
    if (!ensure_loaded()) return;
    try {
        LF_PostStatus(message);
    } catch (...) {
        /* Swallow. */
    }
}

/* ============================================================================
 * Network events
 * ============================================================================
 *
 * The native LF_Set_Network_Event stores a single pair of process-wide
 * function pointers. Because Fortran's `bind(C)` procedures already
 * use the C calling convention, the Fortran callback addresses can be
 * passed through directly, without a trampoline.
 *
 * The cast below is a simple reinterpretation between two function
 * pointer types that have identical signatures:
 *
 *     void (*)(const char*)
 *
 * It is safe on every platform that LingoFuse supports.
 */
extern "C" void lf_set_network_event(
        LfFortranNetworkEventCallback on_connect,
        LfFortranNetworkEventCallback on_disconnect) {
    if (!ensure_loaded()) return;
    try {
        LF_Set_Network_Event(
            reinterpret_cast<LF_NetworkEventFunc>(on_connect),
            reinterpret_cast<LF_NetworkEventFunc>(on_disconnect));
    } catch (...) {
        /* Swallow. */
    }
}