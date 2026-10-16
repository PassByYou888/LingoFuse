/**
 * @file lf_fortran.h
 * @brief C ABI bridge exposing LingoFuse to Fortran (and plain C).
 *
 * This header declares the complete C ABI that the Fortran binding
 * calls. Every function is `extern "C"`, every handle is `void*`,
 * every string is UTF-8 and NUL-terminated, and every failure is
 * reported through a return code (never through a C++ exception).
 *
 * ============================================================================
 * LAYERING
 * ============================================================================
 *
 *     L3  Fortran application / lf_fortran_mod.f90
 *     L2  C ABI bridge       / lf_fortran.h + lf_fortran.cpp   <- THIS FILE
 *     L1  LingoFuse C++ wrapper / LingoFuse.hpp + lf_io.hpp
 *     L0  LingoFuse64.dll runtime
 *
 * The bridge is deliberately thin: it forwards to the raw LingoFuse C ABI
 * (LingoFuse.h) and translates between:
 *
 *     - the C struct-by-value UID representation (TP2P_UID) and the
 *       Fortran-friendly `int8_t[32]` array,
 *     - C++ exceptions and C-style return codes,
 *     - the transient pointers returned by LF_Get_P2P_UID / LF_Get_P2P_Name
 *       (released ~5 s later) and caller-owned buffers.
 *
 * ============================================================================
 * DESIGN CONTRACTS
 * ============================================================================
 *
 *   - Handles are opaque. Fortran stores them as `type(c_ptr)`.
 *   - Ownership is explicit: every create has a matching destroy.
 *   - Callbacks are plain C function pointers with the exact signatures
 *     declared below. Fortran procedures declared with `bind(C)` and
 *     converted through `c_funloc()` are accepted.
 *   - All functions are thread-safe in the same sense as the underlying
 *     LingoFuse C API.
 *   - All functions catch every C++ exception internally and translate it
 *     into a failure return value. Exceptions never escape into the
 *     Fortran runtime.
 *
 * ============================================================================
 * MEMORY MODEL
 * ============================================================================
 *
 *   - `lf_app_create` returns a new application handle. Destroy it with
 *     `lf_app_destroy`.
 *   - `lf_data_create` returns a new data handle. Destroy it with
 *     `lf_data_destroy`.
 *   - `lf_call`, `lf_call_uid`, `lf_call_p2pname`, and `lf_local_call`
 *     return a new data handle that the caller owns and must destroy.
 *   - The input data handle passed to a call is *not* consumed.
 *
 * ============================================================================
 * UID REPRESENTATION
 * ============================================================================
 *
 * Pascal-side `TP2P_UID___` is `array[0..31] of Byte`. The C side wraps
 * it in a struct `TP2P_UID { uint8_t bytes[32]; }` because C has no
 * function-returnable arrays.
 *
 * For Fortran compatibility, this bridge exposes every UID as a plain
 * `int8_t[32]` array:
 *
 *     - The `int8_t` element type is the only portable 8-bit type
 *       available in Fortran (`c_int8_t`).
 *     - Array-in-struct on the C side is `memcpy`-compatible with
 *       array-on-the-stack on the Fortran side.
 *     - The bridge does the struct<->array conversion internally, so
 *       Fortran never sees `TP2P_UID`.
 *
 * Callers pass a pointer to a 32-byte array. The array contents are
 * compared and copied byte-for-byte; the bridge does NOT interpret the
 * UID as a number, so signedness is irrelevant.
 *
 * ============================================================================
 * P2P IDENTITY ("SIDE DATA") SEMANTICS
 * ============================================================================
 *
 * LF_Get_P2P_UID / LF_Get_P2P_Name read the sender's identity that was
 * written into the payload header on the SENDER side, by the framework,
 * BEFORE the request was transmitted. They are NOT properties of the
 * handle itself.
 *
 * Consequence:
 *
 *     VALID    -- the `input_handle` argument of a registered Call or
 *                 Notify callback, i.e. the handle the framework
 *                 delivered to the receiving side.
 *     INVALID  -- an OUTPUT handle, or a caller-created handle. The
 *                 library logs a warning and returns a zero-filled UID
 *                 or an empty string.
 *
 * Therefore `lf_data_get_p2p_uid` and `lf_data_get_p2p_name` are only
 * meaningful when called from inside a callback, and only on the input
 * handle. Both copy their result into a caller-owned buffer immediately;
 * they never expose the library's transient pointer.
 *
 * ============================================================================
 * ASYNC CALLBACK CONTRACT
 * ============================================================================
 *
 * `LfFortranAsyncCallback` is invoked on a TCompute worker thread, NOT on
 * the caller's thread and NOT on any "main" thread. Inside the callback:
 *
 *   - DO NOT block.
 *   - DO NOT call lf_call / lf_notify / lf_local_call / lf_prepare_done
 *     / lf_shutdown. Doing so deadlocks.
 *   - DO NOT retain the `result_handle` past the callback body. It is
 *     OWNED BY THE FRAMEWORK and released the instant the callback
 *     returns. Copy any data you need out of it inside the callback.
 *   - DO NOT call lf_data_destroy on `result_handle`.
 *
 * Dispatch failure:
 *   If the underlying LF_Async_* call rejects the request (return value
 *   0), the bridge invokes the callback SYNCHRONOUSLY, on the caller's
 *   thread, with `result_handle == NULL`. This gives the user a single
 *   unified failure path (`if (!result_handle) ...`). The user callback
 *   must therefore be safe to run on any thread.
 *
 * The `user_data` pointer is forwarded verbatim and is never touched by
 * the framework or the bridge. It is the caller's responsibility to
 * manage its lifetime.
 *
 * ============================================================================
 * OPTIONS
 * ============================================================================
 *
 * The bridge exposes two levels of option access:
 *
 *   1. Generic string-based accessors:
 *        lf_set_option(name, value)
 *        lf_get_option(name, buf, buf_size)
 *
 *   2. Typed shortcuts for the 16 options that are documented in
 *      LingoFuse.h. Each shortcut has a matching getter. Boolean options
 *      use `int` (0 = false, non-zero = true). String getters write into
 *      a caller-supplied buffer and return the number of bytes copied,
 *      or a negative error code.
 *
 * Unknown option names are silently ignored by the setter and return an
 * empty string from the getter, matching the underlying library.
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
 * UID size
 *
 * A LingoFuse session UID is always exactly 32 bytes. This constant is
 * provided so that Fortran declarations can use it for array bounds.
 * ========================================================================= */

#define LF_UID_BYTE_COUNT 32

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
 *   - Do not call lf_call / lf_notify / lf_local_call / lf_prepare_done
 *     / lf_shutdown. Doing so deadlocks.
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

/**
 * Callback for an asynchronous call result.
 *
 * @param user_data      Opaque pointer that was supplied at the call
 *                       site. The framework and the bridge never touch
 *                       it. May be NULL.
 * @param result_handle  Result data handle OWNED BY THE FRAMEWORK. It
 *                       is released the instant this callback returns.
 *                       NULL if the request could not be dispatched.
 *
 * See the file-level docstring section "ASYNC CALLBACK CONTRACT" for the
 * full threading and ownership rules.
 */
typedef void (*LfFortranAsyncCallback)(void* user_data,
                                       void* result_handle);

/* =========================================================================
 * Library lifecycle
 * ========================================================================= */

/**
 * Explicitly load the LingoFuse runtime library.
 *
 * The bridge loads the library lazily on the first API call, so calling
 * this function is optional. It is provided so that an application can
 * fail fast at a well-defined point instead of discovering a missing
 * library in the middle of a call.
 *
 * Safe to call multiple times; the load runs at most once per process.
 *
 * @return 1 on success, 0 on failure (library not found).
 */
int lf_load_library(void);

/**
 * Unload the LingoFuse runtime library.
 *
 * In practice there is no reason to call this: the library is normally
 * kept loaded for the entire process lifetime. It is provided for
 * completeness and for test harnesses that want to exercise the
 * load/unload path.
 *
 * After this call, any subsequent API call will re-attempt a lazy load.
 */
void lf_free_library(void);

/**
 * Gracefully shut down the LingoFuse framework.
 *
 * Order: lf_exit_main_thread -> lf_app_destroy(app) -> lf_shutdown.
 *
 * Safe to call multiple times.
 */
void lf_shutdown(void);

/**
 * Ask the simulated main thread to exit gracefully.
 *
 * WARNING: this also flushes the data handle pool, releasing EVERY
 * outstanding handle -- including those created with
 * lf_data_create_permanent. Do not use any data handle after this call.
 */
void lf_exit_main_thread(void);

/* =========================================================================
 * Application handle
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
 * Destroy an application previously created with lf_app_create.
 * A NULL handle is silently ignored.
 */
void lf_app_destroy(LfAppHandle app);

/**
 * Register a Call-mode API on an application.
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
 * Register a Notify-mode API on an application.
 *
 * @return 1 on success, 0 on failure.
 */
int lf_app_register_notify(LfAppHandle app,
                           const char* api,
                           const char* desc,
                           LfFortranNotifyCallback callback);

/**
 * Unregister an API previously registered with lf_app_register_call
 * or lf_app_register_notify.
 *
 * Removal is immediate locally; the network broadcast takes about
 * 3 seconds to propagate.
 *
 * @return 1 if the API was found and removed, 0 otherwise.
 */
int lf_app_unregister(LfAppHandle app, const char* api);

/**
 * Bind an application to every currently unbound LingoFuse client.
 *
 * Must be called after lf_prepare_done returned 1. Each client can host
 * at most one application.
 *
 * @return Number of clients bound. 0 means no free client was available.
 */
int lf_bind_app(LfAppHandle app);

/**
 * Copy the application name associated with the given handle into `buf`.
 *
 * The underlying pointer is only valid for ~5 seconds; this bridge
 * copies it immediately.
 *
 * @return Number of bytes copied (excluding the NUL) on success,
 *         -1 on failure, -2 if the buffer is too small.
 */
int64_t lf_get_app_name(LfAppHandle app, char* buf, int64_t buf_size);

/**
 * Copy a globally unique application name into `buf`.
 *
 * Must be called AFTER lf_prepare_done returned 1, otherwise the name
 * lacks the tunnel information.
 *
 * @return Number of bytes copied (excluding the NUL) on success,
 *         -1 on failure, -2 if the buffer is too small.
 */
int64_t lf_generate_app_name(char* buf, int64_t buf_size);

/* =========================================================================
 * Process-wide P2P API registration
 * =========================================================================
 *
 * The process-wide P2P namespace is INDEPENDENT of any App:
 *
 *   - APIs registered here are reachable via UID addressing and P2PName
 *     addressing ONLY.
 *   - They are NOT reachable via App-name addressing.
 *   - They live on the process-wide LF_P2P_APP and survive until
 *     lf_shutdown().
 *
 * Typical use: globally-discoverable utility APIs (health probes,
 * capability discovery, identity echo, etc.) that any client in the
 * mesh can call by UID or by P2PName without knowing the target's
 * App name.
 * ========================================================================= */

/**
 * Register a process-wide Call API.
 *
 * @return 1 on success, 0 on failure (duplicate name in the P2P
 *         namespace, NULL args, ...).
 */
int lf_register_p2p_call(const char* api,
                         const char* desc,
                         LfFortranCallCallback callback);

/**
 * Register a process-wide Notify API.
 *
 * @return 1 on success, 0 on failure.
 */
int lf_register_p2p_notify(const char* api,
                           const char* desc,
                           LfFortranNotifyCallback callback);

/**
 * Remove a process-wide P2P API by name.
 *
 * Does NOT affect app-bound APIs of the same name.
 *
 * @return 1 if the API was found and removed, 0 otherwise.
 */
int lf_unregister_p2p(const char* api);

/* =========================================================================
 * Data handle - creation / destruction
 * ========================================================================= */

/**
 * Create a new auto-recycled data handle bound to the given API name.
 * The caller must release it with lf_data_destroy.
 */
LfDataHandle lf_data_create(const char* api_name);

/**
 * Create a new permanent data handle. Never auto-reclaimed; must be
 * released synchronously with lf_data_destroy.
 */
LfDataHandle lf_data_create_permanent(const char* api_name);

/**
 * Destroy a data handle created by any of the creation functions, or
 * returned by lf_call / lf_local_call / lf_call_uid / lf_call_p2pname.
 * NULL is ignored.
 *
 * Do NOT call this on the `result_handle` argument of an async callback.
 */
void lf_data_destroy(LfDataHandle hnd);

/* =========================================================================
 * Scalar I/O (little-endian)
 * ========================================================================= */

int lf_data_write_int8   (LfDataHandle hnd, int8_t   value);
int lf_data_write_int16  (LfDataHandle hnd, int16_t  value);
int lf_data_write_int32  (LfDataHandle hnd, int32_t  value);
int lf_data_write_int64  (LfDataHandle hnd, int64_t  value);

int lf_data_write_uint8  (LfDataHandle hnd, uint8_t  value);
int lf_data_write_uint16 (LfDataHandle hnd, uint16_t value);
int lf_data_write_uint32 (LfDataHandle hnd, uint32_t value);
int lf_data_write_uint64 (LfDataHandle hnd, uint64_t value);

int lf_data_write_float32(LfDataHandle hnd, float    value);
int lf_data_write_float64(LfDataHandle hnd, double   value);

int lf_data_read_int8    (LfDataHandle hnd, int8_t*   out);
int lf_data_read_int16   (LfDataHandle hnd, int16_t*  out);
int lf_data_read_int32   (LfDataHandle hnd, int32_t*  out);
int lf_data_read_int64   (LfDataHandle hnd, int64_t*  out);

int lf_data_read_uint8   (LfDataHandle hnd, uint8_t*  out);
int lf_data_read_uint16  (LfDataHandle hnd, uint16_t* out);
int lf_data_read_uint32  (LfDataHandle hnd, uint32_t* out);
int lf_data_read_uint64  (LfDataHandle hnd, uint64_t* out);

int lf_data_read_float32 (LfDataHandle hnd, float*    out);
int lf_data_read_float64 (LfDataHandle hnd, double*   out);

/* =========================================================================
 * Byte / string I/O
 * ========================================================================= */

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

/* =========================================================================
 * Cursor / size
 * ========================================================================= */

int64_t lf_data_get_position(LfDataHandle hnd);
void    lf_data_set_position(LfDataHandle hnd, int64_t pos);
int64_t lf_data_get_size    (LfDataHandle hnd);
void    lf_data_set_size    (LfDataHandle hnd, int64_t size);

/* =========================================================================
 * UID binary I/O (ARGUMENT-role, value semantics)
 * =========================================================================
 *
 * lf_data_write_uid writes exactly 32 bytes at the cursor; no
 * terminator is appended. lf_data_read_uid reads exactly 32 bytes.
 *
 * Both treat the UID as an opaque 32-byte sequence. The signedness of
 * the int8_t elements is irrelevant.
 * ========================================================================= */

/**
 * Write a 32-byte UID at the cursor. No terminator.
 * @return 1 on success, 0 on failure.
 */
int lf_data_write_uid(LfDataHandle hnd, const int8_t* uid_32);

/**
 * Read a 32-byte UID from the cursor into `out_uid_32`.
 * @return 1 on success, 0 on failure (fewer than 32 bytes available).
 */
int lf_data_read_uid(LfDataHandle hnd, int8_t* out_uid_32);

/* =========================================================================
 * P2P identity accessors (INPUT handles only)
 * =========================================================================
 *
 * These read the sender's identity that the framework injects into the
 * payload header on the SENDER side. They are ONLY meaningful when
 * called on the `input_handle` argument of a registered Call / Notify
 * callback.
 *
 * Calling them on an OUTPUT handle or on a caller-created handle is a
 * well-defined no-op: the library returns a zero-filled UID / an empty
 * string, and this bridge faithfully forwards that.
 *
 * The underlying library returns transient pointers that it releases
 * about 5 seconds after the call. This bridge copies the value into the
 * caller-supplied buffer IMMEDIATELY, so the caller never sees the
 * transient pointer and never needs to think about its lifetime.
 * ========================================================================= */

/**
 * Copy the sender's 32-byte UID into `out_uid_32`.
 *
 * @return 1 on success (the buffer is filled, possibly all-zero),
 *         0 on failure (NULL handle, or the library is not loaded).
 */
int lf_data_get_p2p_uid(LfDataHandle hnd, int8_t* out_uid_32);

/**
 * Copy the sender's P2P group name into `buf`.
 *
 * @return Number of bytes copied (excluding the NUL) on success,
 *         -1 on failure, -2 if the buffer is too small.
 */
int64_t lf_data_get_p2p_name(LfDataHandle hnd, char* buf, int64_t buf_size);

/* =========================================================================
 * UID <-> hex helpers
 * =========================================================================
 *
 * Provided for logging, tracing, and cross-process identity exchange.
 * The hex representation is lowercase, 64 characters, plus a NUL.
 * ========================================================================= */

/**
 * Format a 32-byte UID as 64 lowercase hex characters plus a NUL.
 *
 * @param uid_32   Input UID.
 * @param out_hex  Destination buffer. Must be at least 65 bytes.
 * @return 1 on success, 0 on failure.
 */
int lf_uid_to_hex(const int8_t* uid_32, char* out_hex);

/**
 * Parse a 64-character lowercase hex string into a 32-byte UID.
 *
 * Upper-case hex is also accepted. Any non-hex character causes the
 * call to fail without modifying `out_uid_32`.
 *
 * @param hex           NUL-terminated hex string (at least 64 chars).
 * @param out_uid_32    Destination UID.
 * @return 1 on success, 0 on failure.
 */
int lf_uid_from_hex(const char* hex, int8_t* out_uid_32);

/* =========================================================================
 * Network preparation
 * ========================================================================= */

void lf_reset_prepare(void);

/**
 * @return A tag ID on success, or -1 on duplicate/invalid address.
 */
int lf_prepare_service(const char* listening_addr, const char* phys_addr);

/**
 * @param app  Optional application handle, or NULL for a pure consumer.
 * @return A tag ID on success, or -1 on duplicate/invalid address.
 */
int lf_prepare_client(const char* phys_addr, LfAppHandle app);

/**
 * @return 1 on first successful start, 0 on a repeated call without an
 *         intervening lf_shutdown, -1 on failure.
 */
int lf_prepare_done(void);

/* =========================================================================
 * Remote invocation - app-name addressing
 * ========================================================================= */

/**
 * Synchronous remote call by application name.
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
 * One-way notification by application name.
 * Delivery order is not guaranteed.
 */
void lf_notify(const char* app_name, LfDataHandle param);

/**
 * One-way notification by application name with FIFO ordering per
 * (app, api) pair.
 */
void lf_sequenced_notify(const char* app_name, LfDataHandle param);

/* =========================================================================
 * Remote invocation - UID addressing
 * =========================================================================
 *
 * UID addressing routes to the exact client whose TunnelLink produced
 * the given 32-byte UID. The UID is regenerated on every reconnect: a
 * caller that caches a UID MUST re-probe it after a link loss.
 *
 * UID routing is LOCAL-FIRST, matching app-name routing.
 *
 * A UID can address ANY API registered on the target -- whether
 * app-bound (lf_app_register_call) or process-wide
 * (lf_register_p2p_call) -- without requiring the caller to know the
 * target App name.
 * ========================================================================= */

/**
 * Synchronous remote call by UID. Same ownership rule as lf_call.
 */
LfDataHandle lf_call_uid(const int8_t* uid_32,
                         LfDataHandle param,
                         uint64_t timeout_ms);

/**
 * One-way notification by UID.
 */
void lf_notify_uid(const int8_t* uid_32, LfDataHandle param);

/**
 * One-way notification by UID with FIFO ordering per (uid, api) pair.
 */
void lf_sequenced_notify_uid(const int8_t* uid_32, LfDataHandle param);

/**
 * Return non-zero if a client with the given UID is currently registered.
 */
int lf_check_uid(const int8_t* uid_32);

/**
 * Return non-zero if a client with the given UID exposes the named API.
 */
int lf_check_uid_api(const int8_t* uid_32, const char* api_name);

/* =========================================================================
 * Remote invocation - P2PName addressing
 * =========================================================================
 *
 * P2PName addressing routes to any client in a user-defined group. The
 * server-side dispatcher picks a target using one of two strategies:
 * load balancing (Cycle_Anchor) or sticky affinity (FixedSequenced).
 *
 * P2PName routing is NOT local-first. Even when the caller process
 * itself hosts a client in the target group, the call is forwarded to
 * the server for dispatch.
 * ========================================================================= */

/**
 * Synchronous remote call by P2P group name. Same ownership rule as
 * lf_call.
 */
LfDataHandle lf_call_p2pname(const char* p2p_name,
                             LfDataHandle param,
                             uint64_t timeout_ms);

/**
 * One-way notification by P2P group name.
 */
void lf_notify_p2pname(const char* p2p_name, LfDataHandle param);

/**
 * One-way notification by P2P group name with FIFO ordering per
 * (p2p_name, api) pair.
 */
void lf_sequenced_notify_p2pname(const char* p2p_name, LfDataHandle param);

/**
 * Return non-zero if a client in the given P2P group is registered.
 */
int lf_check_p2pname(const char* p2p_name);

/**
 * Return non-zero if a client in the given P2P group exposes the named
 * API.
 */
int lf_check_p2pname_api(const char* p2p_name, const char* api_name);

/* =========================================================================
 * Asynchronous invocation
 * =========================================================================
 *
 * Each async function returns IMMEDIATELY:
 *   1   the request was queued; the callback will fire later on a
 *       TCompute worker thread,
 *   0   the request was NOT queued; the bridge has already invoked
 *       the callback SYNCHRONOUSLY on the caller's thread with
 *       `result_handle == NULL`.
 *
 * The user callback must therefore be safe to run on any thread and
 * must treat NULL `result_handle` as a dispatch failure.
 *
 * `user_data` is forwarded verbatim and never touched by the framework
 * or the bridge.
 * ========================================================================= */

int lf_async_call(const char* app_name,
                  LfDataHandle param,
                  LfFortranAsyncCallback callback,
                  void* user_data);

int lf_async_sequenced_call(const char* app_name,
                            LfDataHandle param,
                            LfFortranAsyncCallback callback,
                            void* user_data);

int lf_async_call_uid(const int8_t* uid_32,
                      LfDataHandle param,
                      LfFortranAsyncCallback callback,
                      void* user_data);

int lf_async_sequenced_call_uid(const int8_t* uid_32,
                                LfDataHandle param,
                                LfFortranAsyncCallback callback,
                                void* user_data);

int lf_async_call_p2pname(const char* p2p_name,
                          LfDataHandle param,
                          LfFortranAsyncCallback callback,
                          void* user_data);

int lf_async_sequenced_call_p2pname(const char* p2p_name,
                                    LfDataHandle param,
                                    LfFortranAsyncCallback callback,
                                    void* user_data);

/* =========================================================================
 * Options - generic accessors
 * ========================================================================= */

/**
 * Set a global runtime option.
 *
 * Supported option names are documented in LingoFuse.h. Unknown names
 * are silently ignored. Changes are not persisted across restarts.
 */
void lf_set_option(const char* option, const char* value);

/**
 * Read a global runtime option into `buf`.
 *
 * @return Number of bytes copied (excluding the NUL) on success,
 *         -1 on failure, -2 if the buffer is too small.
 */
int64_t lf_get_option(const char* option, char* buf, int64_t buf_size);

/* =========================================================================
 * Options - typed shortcuts
 * =========================================================================
 *
 * These wrap the 16 options that are documented in LingoFuse.h. Boolean
 * options use `int` (0 = false, non-zero = true). String getters write
 * into a caller-supplied buffer.
 *
 * Naming mirrors the Pascal helper names in lingofuse_import.pas and
 * the C helper names in LingoFuse.h exactly, so cross-referencing is
 * trivial.
 * ========================================================================= */

/* ---- Authentication ---- */
void        lf_set_opt_password            (const char* value);
const char* lf_get_opt_password            (void);   /* always masked */

/* ---- Logging and diagnostics ---- */
void        lf_set_opt_debug               (const char* value);
const char* lf_get_opt_debug               (void);   /* placeholder */
void        lf_set_opt_quiet               (int value);
int         lf_get_opt_quiet               (void);
void        lf_set_opt_show_thread_id      (int value);
int         lf_get_opt_show_thread_id      (void);
void        lf_set_opt_console_output      (int value);
int         lf_get_opt_console_output      (void);

/* ---- Connection readiness ---- */
void        lf_set_opt_overlap_connection  (int value);
int         lf_get_opt_overlap_connection  (void);
void        lf_set_opt_wait_ready_ok       (int value);
int         lf_get_opt_wait_ready_ok       (void);
void        lf_set_opt_wait_timeout        (uint64_t value);
uint64_t    lf_get_opt_wait_timeout        (void);

/* ---- IPC ---- */
void        lf_set_opt_ipc_thread_count    (int value);
int         lf_get_opt_ipc_thread_count    (void);
void        lf_set_opt_ipc_max_queue       (int value);
int         lf_get_opt_ipc_max_queue       (void);
void        lf_set_opt_ipc_max_msg_size    (int value);
int         lf_get_opt_ipc_max_msg_size    (void);

/* ---- Sequenced notifications ---- */
void        lf_set_opt_fixed_sequenced_time(uint64_t value);
uint64_t    lf_get_opt_fixed_sequenced_time(void);

/* ---- P2P group name ---- */
void        lf_set_opt_p2p_name            (const char* value);
int64_t     lf_get_opt_p2p_name            (char* buf, int64_t buf_size);

/* ---- Data handle pool ---- */
void        lf_set_opt_data_idle_timeout   (uint64_t value);
uint64_t    lf_get_opt_data_idle_timeout   (void);
void        lf_set_opt_data_scan_interval  (uint64_t value);
uint64_t    lf_get_opt_data_scan_interval  (void);

/* ---- Command flushing ---- */
void        lf_set_opt_null_flush_threshold(int value);
int         lf_get_opt_null_flush_threshold(void);

/* =========================================================================
 * Queries and diagnostics
 * ========================================================================= */

int         lf_check_main_thread(void);
int         lf_check_app        (const char* app_name);
int         lf_check_api        (const char* app_name, const char* api_name);

int         lf_get_status_count (void);

/**
 * Copy the next status message into `buf`.
 * @return Number of bytes copied (excluding the NUL), or -1 / -2.
 */
int64_t     lf_get_status       (char* buf, int64_t buf_size);

void        lf_post_status      (const char* message);

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