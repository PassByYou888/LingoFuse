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
 * The implementation is deliberately thin. It uses the raw LingoFuse
 * C ABI (LingoFuse.h) directly, wrapped in minimal defensive code,
 * rather than layering the C++ RAII wrappers on top. This keeps the
 * bridge allocation-free (except where the underlying library
 * allocates), keeps the handle representation identical to the
 * native TDataHnd / TAppHnd, and avoids a second object lifetime
 * that Fortran cannot participate in.
 *
 * The only C++ features used are:
 *   - `extern "C"` linkage,
 *   - `try / catch (...)`,
 *   - `std::call_once` for the lazy load of the runtime library.
 *
 * All comments and diagnostic output are in English.
 */

#include "lf_fortran.h"
#include "LingoFuse.h"

#include <cstring>
#include <mutex>

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

/* ============================================================================
 * Internal helpers
 * ============================================================================ */

namespace {

/**
 * Callback context stored in the `trigger` slot of a registered API.
 * The native library hands the pointer back to our trampoline; we
 * then dispatch to the Fortran callback stored here.
 *
 * The context is intentionally leaked. The native library can invoke
 * a callback at any time after registration, including concurrently
 * with an unregister or destroy call. Reclaiming the context would
 * open a use-after-free window. The cost is bounded: a few dozen
 * bytes per registered API, and the number of registered APIs is
 * small in any realistic program.
 */
struct CallContext {
    LfFortranCallCallback callback;
};

struct NotifyContext {
    LfFortranNotifyCallback callback;
};

/* --- Trampolines ------------------------------------------------------ */

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

/* --- Safe string helpers ---------------------------------------------- */

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
                     char* dst,
                     int64_t buf_size,
                     int64_t* out_len) {
    if (!dst || buf_size <= 0) return -1;
    const char* s = src ? src : "";
    const int64_t needed =
        static_cast<int64_t>(std::strlen(s)) + 1;  /* include NUL */
    if (needed > buf_size) return -2;
    std::memcpy(dst, s, static_cast<size_t>(needed));
    if (out_len) *out_len = needed - 1;
    return 0;
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

extern "C" int lf_app_register_call(LfAppHandle app,
                                    const char* api,
                                    const char* desc,
                                    LfFortranCallCallback callback) {
    if (!app || !api || !callback) return 0;
    if (!ensure_loaded()) return 0;
    try {
        auto* ctx = new CallContext{callback};
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

extern "C" int lf_app_register_notify(LfAppHandle app,
                                      const char* api,
                                      const char* desc,
                                      LfFortranNotifyCallback callback) {
    if (!app || !api || !callback) return 0;
    if (!ensure_loaded()) return 0;
    try {
        auto* ctx = new NotifyContext{callback};
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
                                    const void* data,
                                    int64_t len) {
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
                                       void* data,
                                       int64_t len) {
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
                                           const void* data,
                                           int64_t len) {
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
                                        char* buf,
                                        int64_t buf_size) {
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
                                              void* buf,
                                              int64_t buf_size) {
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
                                           void* buf,
                                           int64_t buf_size) {
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

/* ============================================================================
 * JSON I/O
 * ============================================================================ */

extern "C" int lf_data_write_json(LfDataHandle h, const char* json_str) {
    if (!h || !json_str) return 0;
    if (!ensure_loaded()) return 0;
    try {
        /* JSON is passed through as a NUL-terminated UTF-8 string.
           The LingoFuse layer treats it as opaque bytes; no
           validation is performed here. */
        return LF_WriteString(static_cast<TDataHnd>(h), json_str);
    } catch (...) {
        return 0;
    }
}

extern "C" int64_t lf_data_read_json(LfDataHandle h,
                                      char* buf,
                                      int64_t buf_size) {
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
                                   const char* physics_addr) {
    if (!listening_addr || !physics_addr) return -1;
    if (!ensure_loaded()) return -1;
    try {
        return LF_PrepareService(listening_addr, physics_addr);
    } catch (...) {
        return -1;
    }
}

extern "C" int lf_prepare_client(const char* physics_addr, LfAppHandle app) {
    if (!physics_addr) return -1;
    if (!ensure_loaded()) return -1;
    try {
        return LF_PrepareClient(
            physics_addr,
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

extern "C" void lf_exit_main_thread(void) {
    if (!ensure_loaded()) return;
    try {
        LF_ExitMainThread();
    } catch (...) {
        /* Swallow. */
    }
}

extern "C" void lf_shutdown(void) {
    if (!ensure_loaded()) return;
    try {
        LF_Shutdown();
    } catch (...) {
        /* Swallow. */
    }
}

/* ============================================================================
 * Remote invocation
 * ============================================================================ */

extern "C" LfDataHandle lf_call(const char* app_name,
                                 LfDataHandle param,
                                 uint64_t timeout_ms) {
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
 * Options and diagnostics
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

extern "C" int lf_check_main_thread(void) {
    if (!ensure_loaded()) return 0;
    try {
        return LF_CheckMainThread();
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_check_app(const char* app_name) {
    if (!app_name) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_CheckApp(app_name);
    } catch (...) {
        return 0;
    }
}

extern "C" int lf_check_api(const char* app_name, const char* api_name) {
    if (!app_name || !api_name) return 0;
    if (!ensure_loaded()) return 0;
    try {
        return LF_CheckApi(app_name, api_name);
    } catch (...) {
        return 0;
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

extern "C" int64_t lf_get_app_name(LfAppHandle app,
                                    char* buf,
                                    int64_t buf_size) {
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

extern "C" int lf_get_status_count(void) {
    if (!ensure_loaded()) return 0;
    try {
        return LF_GetStatusCount();
    } catch (...) {
        return 0;
    }
}

extern "C" int64_t lf_get_status(char* buf, int64_t buf_size) {
    if (!buf || buf_size <= 0) return -1;
    if (!ensure_loaded()) return -1;
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
 * ============================================================================ */

/*
 * The native LF_Set_Network_Event stores a single pair of process-wide
 * function pointers. Because Fortran's `bind(C)` procedures already
 * use the C calling convention, the Fortran callback addresses can be
 * passed through directly, without a trampoline.
 *
 * The cast below is a simple reinterpretation from one function
 * pointer type to another, both with the same signature:
 *
 *     void (*)(const char*)
 *
 * It is safe on every platform that LingoFuse supports.
 */
extern "C" void lf_set_network_event(LfFortranNetworkEventCallback on_connect,
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