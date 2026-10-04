/**
 * @file lf_fortran.h
 * @brief C ABI bridge exposing LingoFuse to Fortran (and plain C).
 *
 * This header declares the complete C ABI that the Fortran binding
 * calls. Every function is `extern "C"`, every handle is `void*`,
 * every string is UTF-8 and NUL-terminated, and every failure is
 * reported through a return code (never through a C++ exception).
 *
 * Design contracts:
 *
 *   - Handles are opaque. Fortran stores them as `type(c_ptr)`.
 *   - Ownership is explicit: every create has a matching destroy.
 *   - Callbacks are plain C function pointers with the exact
 *     signatures declared below. Fortran procedures declared with
 *     `bind(C)` and converted through `c_funloc()` are accepted.
 *   - All functions are thread-safe in the same sense as the
 *     underlying LingoFuse C API.
 *   - All functions catch every C++ exception internally and
 *     translate it into a failure return value. Exceptions never
 *     escape into the Fortran runtime.
 *
 * Memory model:
 *
 *   - `lf_app_create` returns a new application handle. Destroy it
 *     with `lf_app_destroy`.
 *   - `lf_data_create` returns a new data handle. Destroy it with
 *     `lf_data_destroy`.
 *   - `lf_call` and `lf_local_call` return a new data handle that
 *     the caller owns and must destroy.
 *   - The input data handle passed to a call is *not* consumed.
 *
 * Callback lifetime:
 *
 *   - A callback registered with `lf_app_register_call` /
 *     `lf_app_register_notify` remains installed until the
 *     application is destroyed. There is no per-callback unregister
 *     in this ABI; use the underlying LingoFuse API if you need it.
 *   - A network event callback installed with `lf_set_network_event`
 *     remains installed until it is replaced or `lf_shutdown` runs.
 */

#ifndef LF_FORTRAN_H_INCLUDED
#define LF_FORTRAN_H_INCLUDED

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * Opaque handle types
 *
 * All handles are `void*` so that Fortran can store them as
 * `type(c_ptr)` without any conversion. Do not dereference them.
 * ========================================================================= */

typedef void* LfAppHandle;
typedef void* LfDataHandle;

/* =========================================================================
 * Callback types
 *
 * Fortran procedures must be declared with `bind(C)` and use the
 * `value` attribute for the `type(c_ptr)` arguments, matching the
 * signatures below.
 *
 * All callbacks run on a background worker thread owned by the
 * LingoFuse library. Inside a callback:
 *
 *   - Do not block.
 *   - Do not call `lf_call`, `lf_notify`, `lf_sequenced_notify`,
 *     `lf_local_call`, `lf_local_notify`, `lf_prepare_done`, or
 *     `lf_shutdown`. Doing so deadlocks.
 *   - Do not touch UI controls directly.
 * ========================================================================= */

/**
 * Callback for a Call-mode (request-response) API.
 *
 * @param input_handle   Read-only data handle carrying the request.
 * @param output_handle  Writable data handle for the response.
 */
typedef void (*LfFortranCallCallback)(void* input_handle,
                                      void* output_handle);

/**
 * Callback for a Notify-mode (one-way) API.
 *
 * @param input_handle  Read-only data handle carrying the payload.
 */
typedef void (*LfFortranNotifyCallback)(void* input_handle);

/**
 * Callback for a network connect / disconnect event.
 *
 * @param addr  NUL-terminated UTF-8 endpoint string. Valid ONLY
 *              during the callback. Copy it inside the callback
 *              if you need to retain it.
 */
typedef void (*LfFortranNetworkEventCallback)(const char* addr);

/* =========================================================================
 * Application handle operations
 * ========================================================================= */

/**
 * Create a new application.
 *
 * @param name  UTF-8, NUL-terminated application name.
 * @param desc  UTF-8, NUL-terminated description. May be NULL.
 * @return A non-NULL handle on success, NULL on failure.
 */
LfAppHandle lf_app_create(const char* name, const char* desc);

/**
 * Destroy an application previously created with `lf_app_create`.
 * A NULL handle is silently ignored.
 */
void lf_app_destroy(LfAppHandle app);

/**
 * Register a Call-mode API.
 *
 * @param app       Application handle.
 * @param api       UTF-8, NUL-terminated API name.
 * @param desc      UTF-8, NUL-terminated description. May be NULL.
 * @param callback  Fortran callback (converted with `c_funloc`).
 * @return 1 on success, 0 on failure (duplicate name, NULL args, ...).
 */
int lf_app_register_call(LfAppHandle app,
                         const char* api,
                         const char* desc,
                         LfFortranCallCallback callback);

/**
 * Register a Notify-mode API.
 *
 * @return 1 on success, 0 on failure.
 */
int lf_app_register_notify(LfAppHandle app,
                           const char* api,
                           const char* desc,
                           LfFortranNotifyCallback callback);

/* =========================================================================
 * Data handle operations
 * ========================================================================= */

/**
 * Create a new auto-recycled data handle bound to the given API name.
 * The caller must release it with `lf_data_destroy`.
 */
LfDataHandle lf_data_create(const char* api_name);

/**
 * Create a new permanent data handle. Never auto-reclaimed; must be
 * released synchronously with `lf_data_destroy`.
 */
LfDataHandle lf_data_create_permanent(const char* api_name);

/**
 * Destroy a data handle created by any of the creation functions, or
 * returned by `lf_call` / `lf_local_call`. NULL is ignored.
 */
void lf_data_destroy(LfDataHandle hnd);

/* ---- Scalar I/O (little-endian) ---- */

int lf_data_write_int8(LfDataHandle hnd, int8_t value);
int lf_data_write_int16(LfDataHandle hnd, int16_t value);
int lf_data_write_int32(LfDataHandle hnd, int32_t value);
int lf_data_write_int64(LfDataHandle hnd, int64_t value);

int lf_data_write_uint8(LfDataHandle hnd, uint8_t value);
int lf_data_write_uint16(LfDataHandle hnd, uint16_t value);
int lf_data_write_uint32(LfDataHandle hnd, uint32_t value);
int lf_data_write_uint64(LfDataHandle hnd, uint64_t value);

int lf_data_write_float32(LfDataHandle hnd, float value);
int lf_data_write_float64(LfDataHandle hnd, double value);

int lf_data_read_int8(LfDataHandle hnd, int8_t* out);
int lf_data_read_int16(LfDataHandle hnd, int16_t* out);
int lf_data_read_int32(LfDataHandle hnd, int32_t* out);
int lf_data_read_int64(LfDataHandle hnd, int64_t* out);

int lf_data_read_uint8(LfDataHandle hnd, uint8_t* out);
int lf_data_read_uint16(LfDataHandle hnd, uint16_t* out);
int lf_data_read_uint32(LfDataHandle hnd, uint32_t* out);
int lf_data_read_uint64(LfDataHandle hnd, uint64_t* out);

int lf_data_read_float32(LfDataHandle hnd, float* out);
int lf_data_read_float64(LfDataHandle hnd, double* out);

/* ---- Byte / string I/O ---- */

/**
 * Write raw bytes at the cursor. No NUL is appended.
 * @return 1 on success, 0 on failure.
 */
int lf_data_write_bytes(LfDataHandle hnd, const void* data, int64_t len);

/**
 * Read up to `len` raw bytes into `data`.
 * @return Number of bytes actually read, or -1 on failure.
 */
int64_t lf_data_read_bytes(LfDataHandle hnd, void* data, int64_t len);

/**
 * Write a UTF-8 string followed by a NUL terminator.
 * @return 1 on success, 0 on failure.
 */
int lf_data_write_string(LfDataHandle hnd, const char* str);

/**
 * Write raw bytes followed by a NUL terminator.
 * @return 1 on success, 0 on failure.
 */
int lf_data_write_string_bytes(LfDataHandle hnd, const void* data, int64_t len);

/**
 * Read a NUL-terminated UTF-8 string into `buf`.
 *
 * If the string does not fit in `buf_size - 1` bytes, the call fails
 * with return value -2 and the cursor is left unchanged. The caller
 * can retry with a larger buffer.
 *
 * @return Number of bytes copied (excluding the NUL) on success,
 *         -1 on general failure, -2 if the buffer is too small.
 */
int64_t lf_data_read_string(LfDataHandle hnd, char* buf, int64_t buf_size);

/**
 * Read raw bytes up to the first NUL into `buf`.
 * @return Number of bytes copied on success, -1 or -2 on failure.
 */
int64_t lf_data_read_string_bytes(LfDataHandle hnd,
                                  void* buf,
                                  int64_t buf_size);

/**
 * Read all remaining bytes from the cursor to the end of the buffer.
 * @return Number of bytes copied on success, -1 or -2 on failure.
 */
int64_t lf_data_read_all_bytes(LfDataHandle hnd,
                               void* buf,
                               int64_t buf_size);

/* ---- JSON I/O ---- */

/**
 * Serialize the JSON string `json_str` and write it with a NUL
 * terminator. `json_str` must already be valid UTF-8 JSON.
 * @return 1 on success, 0 on failure.
 */
int lf_data_write_json(LfDataHandle hnd, const char* json_str);

/**
 * Read a NUL-terminated JSON payload into `buf`.
 * @return Number of bytes copied on success, -1 or -2 on failure.
 */
int64_t lf_data_read_json(LfDataHandle hnd, char* buf, int64_t buf_size);

/* ---- Cursor / size ---- */

int64_t lf_data_get_position(LfDataHandle hnd);
void    lf_data_set_position(LfDataHandle hnd, int64_t pos);
int64_t lf_data_get_size(LfDataHandle hnd);
void    lf_data_set_size(LfDataHandle hnd, int64_t size);

/* =========================================================================
 * Network preparation
 * ========================================================================= */

void lf_reset_prepare(void);

/**
 * @return A tag ID on success, or -1 on duplicate/invalid address.
 */
int lf_prepare_service(const char* listening_addr, const char* physics_addr);

/**
 * @param app  Optional application handle, or NULL for a pure consumer.
 * @return A tag ID on success, or -1 on duplicate/invalid address.
 */
int lf_prepare_client(const char* physics_addr, LfAppHandle app);

/**
 * @return 1 on first successful start, 0 on a repeated call without an
 *         intervening `lf_shutdown`, -1 on failure.
 */
int lf_prepare_done(void);

void lf_exit_main_thread(void);
void lf_shutdown(void);

/* =========================================================================
 * Remote invocation
 * ========================================================================= */

/**
 * Synchronous remote call.
 *
 * The returned handle is NEW and owned by the caller. It is never
 * NULL. On timeout or unreachable target, its size is 0.
 *
 * @param app_name    Target application name (UTF-8, NUL-terminated).
 * @param param       Input data handle (not consumed).
 * @param timeout_ms  Timeout in milliseconds. 0 means "wait forever".
 */
LfDataHandle lf_call(const char* app_name,
                     LfDataHandle param,
                     uint64_t timeout_ms);

/**
 * In-process call, bypassing the network.
 * The returned handle is NEW and owned by the caller.
 */
LfDataHandle lf_local_call(LfAppHandle app, LfDataHandle param);

/**
 * One-way notification. Delivery order is not guaranteed.
 * The input handle is not consumed.
 */
void lf_notify(const char* app_name, LfDataHandle param);

/**
 * One-way notification with FIFO ordering per (app, api) pair.
 * The input handle is not consumed.
 */
void lf_sequenced_notify(const char* app_name, LfDataHandle param);

/* =========================================================================
 * Options and diagnostics
 * ========================================================================= */

void lf_set_option(const char* option, const char* value);

int lf_check_main_thread(void);
int lf_check_app(const char* app_name);
int lf_check_api(const char* app_name, const char* api_name);

/**
 * Copy the generated unique application name into `buf`.
 * @return Number of bytes copied (excluding the NUL) on success,
 *         -1 on failure, -2 if the buffer is too small.
 */
int64_t lf_generate_app_name(char* buf, int64_t buf_size);

/**
 * Copy the application name of an existing handle into `buf`.
 * @return Number of bytes copied (excluding the NUL) on success,
 *         -1 on failure, -2 if the buffer is too small.
 */
int64_t lf_get_app_name(LfAppHandle app, char* buf, int64_t buf_size);

int  lf_get_status_count(void);

/**
 * Copy the next status message into `buf`.
 * @return Number of bytes copied (excluding the NUL), or -1 / -2.
 */
int64_t lf_get_status(char* buf, int64_t buf_size);

void lf_post_status(const char* message);

/* =========================================================================
 * Library lifecycle
 * ========================================================================= */

/**
 * Explicitly load the LingoFuse runtime library.
 *
 * The bridge loads the library lazily on the first API call, so
 * calling this function is optional. It is provided so that an
 * application can fail fast at a well-defined point instead of
 * discovering a missing library in the middle of a call.
 *
 * Safe to call multiple times; the load runs at most once per
 * process.
 *
 * @return 1 on success, 0 on failure (library not found).
 */
int lf_load_library(void);

/**
 * Unload the LingoFuse runtime library.
 *
 * In practice there is no reason to call this: the library is
 * normally kept loaded for the entire process lifetime. It is
 * provided for completeness and for test harnesses that want to
 * exercise the load/unload path.
 *
 * After this call, any subsequent API call will re-attempt a lazy
 * load.
 */
void lf_free_library(void);

/* =========================================================================
 * Network events
 * ========================================================================= */

/**
 * Install or clear the process-global network event callbacks.
 *
 * Passing NULL for either argument disables that event. This is a
 * REPLACE operation: a second call discards any previously installed
 * callbacks, even those whose argument is NULL in the new call.
 */
void lf_set_network_event(LfFortranNetworkEventCallback on_connect,
                          LfFortranNetworkEventCallback on_disconnect);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LF_FORTRAN_H_INCLUDED */