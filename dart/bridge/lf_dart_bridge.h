/*
 * lf_dart_bridge.h
 *
 * Dart FFI C bridge for LingoFuse.
 *
 * This bridge is a COMPLETE facade over the LingoFuse C ABI. It exists
 * because Dart's FFI layer has three limitations that make direct use
 * of the LingoFuse C ABI impossible or impractical, plus three
 * conveniences that are awkward to implement in Dart.
 *
 * ---------------------------------------------------------------------------
 * WHY THE BRIDGE EXISTS
 * ---------------------------------------------------------------------------
 *
 *   1. STRUCT-BY-VALUE.
 *      Dart FFI cannot reliably pass a 32-byte aggregate (the
 *      ARGUMENT-role TP2P_UID) by value across the ABI. The bridge
 *      accepts a `const uint8_t*` instead and repacks it on the C side
 *      into the exact struct layout that the Pascal side expects.
 *
 *   2. CALLBACKS FROM NATIVE WORKER THREADS.
 *      Call-mode and Notify-mode LingoFuse callbacks run on native
 *      worker threads and MUST complete synchronously before the worker
 *      returns (the framework releases the input/output buffers the
 *      instant the callback returns). Dart's NativeCallable is
 *      ASYNCHRONOUS for cross-thread invocations. The bridge resolves
 *      this by:
 *         a. copying the input bytes,
 *         b. posting them to the Dart isolate,
 *         c. BLOCKING on a semaphore until Dart calls back
 *            lf_bridge_complete() with the output bytes.
 *
 *   3. TRANSIENT POINTERS.
 *      LF_Get_P2P_UID / LF_Get_P2P_Name return pointers to
 *      library-owned buffers with a ~5-second lifetime. The bridge
 *      copies the value immediately into a caller-supplied buffer and
 *      never exposes the transient pointer to Dart.
 *
 * ---------------------------------------------------------------------------
 * CONVENIENCES THE BRIDGE PROVIDES
 * ---------------------------------------------------------------------------
 *
 *   A. TYPED OPTION HELPERS.
 *      LF_SetOption / LF_GetOption are stringly typed. The bridge
 *      exposes a typed set/get pair for every documented option, so
 *      Dart callers never see a string where an int or a bool was
 *      intended. See Section 11.
 *
 *   B. FIRE-AND-FORGET CALLBACK CHANNEL.
 *      The asynchronous call family (LF_Async_Call and its UID /
 *      P2PName variants) and the network event handler run on native
 *      worker threads that MUST NOT block. The bridge posts the result
 *      to the Dart isolate and returns IMMEDIATELY. See Section 7.5.
 *
 *   C. STATIC ERROR STRING.
 *      Every int-returning bridge function uses 0 for success and a
 *      non-zero LFB_* code for failure. See Section 15.
 *
 * ---------------------------------------------------------------------------
 * SECTIONS
 * ---------------------------------------------------------------------------
 *
 *   Section  0  Lifecycle         lf_bridge_init / lf_bridge_shutdown
 *   Section  1  Data handle       create / free / read / write / identity
 *   Section  2  Application       create / free / bind / get name
 *   Section  3  Registration      app-bound Call / Notify
 *   Section  4  Registration      process-wide P2P Call / Notify
 *   Section  5  Local execution   local Call / Notify
 *   Section  6  Network           reset / prepare service / prepare client
 *   Section  7  Invocation        App-name addressing (sync + async)
 *   Section  8  Invocation        UID addressing (sync + async)
 *   Section  9  Invocation        P2PName addressing (sync + async)
 *   Section 10  Queries           check main thread / app / api / uid / p2p
 *   Section 11  Options           typed set/get pairs for every option
 *   Section 12  Status            status queue
 *   Section 13  Network events    connect / disconnect
 *   Section 15  Diagnostics       error string / bridge version / stats
 *
 * ---------------------------------------------------------------------------
 * CALLBACK PROTOCOLS
 * ---------------------------------------------------------------------------
 *
 *   PROTOCOL A -- SYNCHRONOUS HANDSHAKE (Sections 3, 4, 5)
 *   ------------------------------------------------------
 *   Used by:  registered Call and Notify handlers, local call handlers.
 *   Thread:   a LingoFuse native worker thread.
 *   Lifetime: the Call worker BLOCKS until Dart replies; the Notify
 *             worker returns immediately after posting.
 *
 *   Message shape (5 elements):
 *
 *     [ request_id : int64,
 *       callback_id : int64,
 *       input : Uint8List,
 *       sender_uid : Uint8List(32),
 *       sender_p2p_name : Uint8List(N) ]
 *
 *   - `request_id` is zero for Notify (no reply expected) and a
 *     non-zero opaque integer for Call.
 *   - `callback_id` is the identifier the caller supplied at
 *     registration time.
 *   - `input` is the raw bytes of the request handle.
 *   - `sender_uid` is the 32-byte sender UID. It is all-zero when the
 *     request was not accompanied by side data (e.g. LF_LocalCall).
 *   - `sender_p2p_name` is the UTF-8 group name of the sender. It is
 *     empty when no P2P group was declared.
 *
 *   For Call, the native worker blocks on a semaphore until Dart
 *   calls lf_bridge_complete(request_id, output_bytes, output_size).
 *   For Notify, the worker returns after posting; Dart must not call
 *   lf_bridge_complete.
 *
 *       native worker                        Dart isolate
 *       -------------                        ------------
 *        1. copy input bytes
 *        2. extract sender identity
 *        3. allocate request_id (Call only)
 *        4. post [req_id, cb_id, input, uid, p2p]
 *           to Dart_PostCObject  ------------>  5. event loop receives
 *                                               6. dispatch to user handler
 *                                               7. call lf_bridge_complete(
 *                                                      request_id,
 *                                                      output_bytes,
 *                                                      output_size)
 *        8. semaphore released   <------------
 *        9. copy output bytes into the
 *           native output handle
 *       10. return
 *
 *   PROTOCOL B -- FIRE-AND-FORGET (Sections 7.4, 8.4, 9.4, 13)
 *   ----------------------------------------------------------
 *   Used by:  the asynchronous invocation family and network events.
 *   Thread:   a LingoFuse native worker thread.
 *   Lifetime: the native worker returns IMMEDIATELY after posting.
 *
 *   Message shape (2 elements):
 *
 *     [ op_id : int64, payload : Uint8List ]
 *
 *   For async calls, `op_id` is the caller-supplied operation ID.
 *   For network events, `op_id` is the connect/disconnect callback ID.
 *
 * ---------------------------------------------------------------------------
 * ERROR HANDLING
 * ---------------------------------------------------------------------------
 * Every int-returning function returns one of the LFB_ErrorCode values.
 * A non-zero value is a failure. Call lf_bridge_last_error() to obtain
 * a human-readable description. The string is stored in thread-local
 * storage and remains valid until the same thread performs another
 * bridge call.
 */

#ifndef LF_DART_BRIDGE_H_INCLUDED
#define LF_DART_BRIDGE_H_INCLUDED

#include <stdint.h>

#if defined(_WIN32)
#  if defined(LF_DART_BRIDGE_EXPORTS)
#    define LF_DART_API __declspec(dllexport)
#  else
#    define LF_DART_API __declspec(dllimport)
#  endif
#  define LF_DART_CALL __cdecl
#else
#  if defined(__GNUC__) && __GNUC__ >= 4
#    define LF_DART_API __attribute__((visibility("default")))
#  else
#    define LF_DART_API
#  endif
#  define LF_DART_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef enum LFB_ErrorCode {
    LFB_OK                    = 0,
    LFB_ERR_NOT_INITIALIZED   = 1,
    LFB_ERR_LIBRARY_NOT_LOADED= 2,
    LFB_ERR_NULL_HANDLE       = 3,
    LFB_ERR_BUFFER_TOO_SMALL  = 4,
    LFB_ERR_INVALID_ARGUMENT  = 5,
    LFB_ERR_LINGOFUSE_FAILED  = 6,
    LFB_ERR_BRIDGE_INTERNAL   = 7,
    LFB_ERR_DART_POST_FAILED  = 8,
    LFB_ERR_TIMEOUT           = 9,
} LFB_ErrorCode;

/* ===========================================================================
 * Section 0 -- Lifecycle
 * ========================================================================= */

LF_DART_API int LF_DART_CALL lf_bridge_init(int64_t dart_port_id, void* api_dl_data);
LF_DART_API void LF_DART_CALL lf_bridge_shutdown(void);
LF_DART_API int LF_DART_CALL lf_bridge_is_initialized(void);

/* ===========================================================================
 * Section 1 -- Data handle
 * ========================================================================= */

LF_DART_API void* LF_DART_CALL lf_bridge_create_data(const char* api_name);
LF_DART_API void* LF_DART_CALL lf_bridge_create_data_permanent(const char* api_name);
LF_DART_API void LF_DART_CALL lf_bridge_free_data(void* hnd);

LF_DART_API int64_t LF_DART_CALL lf_bridge_write_buffer(void* hnd, const void* buff, int64_t size);
LF_DART_API int64_t LF_DART_CALL lf_bridge_read_buffer(void* hnd, void* buff, int64_t size);
LF_DART_API int64_t LF_DART_CALL lf_bridge_get_pos(void* hnd);
LF_DART_API void LF_DART_CALL lf_bridge_set_pos(void* hnd, int64_t pos);
LF_DART_API int64_t LF_DART_CALL lf_bridge_get_size(void* hnd);
LF_DART_API void LF_DART_CALL lf_bridge_set_size(void* hnd, int64_t size);

LF_DART_API int LF_DART_CALL lf_bridge_get_p2p_uid(void* hnd, uint8_t* out_uid_32);
LF_DART_API int LF_DART_CALL lf_bridge_get_p2p_name(void* hnd, char* out_buf, int buf_size);

LF_DART_API int LF_DART_CALL lf_bridge_write_uid(void* hnd, const uint8_t* uid_32);
LF_DART_API int LF_DART_CALL lf_bridge_read_uid(void* hnd, uint8_t* out_uid_32);

/* ===========================================================================
 * Section 2 -- Application handle
 * ========================================================================= */

LF_DART_API void* LF_DART_CALL lf_bridge_create_app(const char* app_name, const char* desc);
LF_DART_API void LF_DART_CALL lf_bridge_free_app(void* app_hnd);
LF_DART_API int LF_DART_CALL lf_bridge_get_app_name(void* app_hnd, char* out_buf, int buf_size);
LF_DART_API int LF_DART_CALL lf_bridge_generate_app_name(char* out_buf, int buf_size);
LF_DART_API int LF_DART_CALL lf_bridge_bind_app(void* app_hnd);

/* ===========================================================================
 * Section 3 -- API registration (app-bound)
 * ========================================================================= */

LF_DART_API int LF_DART_CALL lf_bridge_register_call(
    void* app_hnd, const char* method_name, const char* desc, int64_t callback_id);

LF_DART_API int LF_DART_CALL lf_bridge_register_notify(
    void* app_hnd, const char* method_name, const char* desc, int64_t callback_id);

LF_DART_API int LF_DART_CALL lf_bridge_unregister(
    void* app_hnd, const char* method_name);

LF_DART_API int LF_DART_CALL lf_bridge_complete(
    int64_t request_id, const uint8_t* output, int64_t size);

/* ===========================================================================
 * Section 4 -- API registration (process-wide P2P)
 * ========================================================================= */

LF_DART_API int LF_DART_CALL lf_bridge_register_p2p_call(
    const char* method_name, const char* desc, int64_t callback_id);

LF_DART_API int LF_DART_CALL lf_bridge_register_p2p_notify(
    const char* method_name, const char* desc, int64_t callback_id);

LF_DART_API int LF_DART_CALL lf_bridge_unregister_p2p(
    const char* method_name);

/* ===========================================================================
 * Section 5 -- Local execution
 * ========================================================================= */

LF_DART_API void* LF_DART_CALL lf_bridge_local_call(void* app_hnd, void* param);
LF_DART_API void LF_DART_CALL lf_bridge_local_notify(void* app_hnd, void* param);

/* ===========================================================================
 * Section 6 -- Network preparation
 * ========================================================================= */

LF_DART_API void LF_DART_CALL lf_bridge_reset_prepare(void);
LF_DART_API int LF_DART_CALL lf_bridge_prepare_service(
    const char* listening_addr, const char* physics_addr);
LF_DART_API int LF_DART_CALL lf_bridge_prepare_client(
    const char* physics_addr, void* app_hnd);
LF_DART_API int LF_DART_CALL lf_bridge_prepare_done(void);
LF_DART_API void LF_DART_CALL lf_bridge_exit_main_thread(void);
LF_DART_API void LF_DART_CALL lf_bridge_lf_shutdown(void);

/* ===========================================================================
 * Section 7 -- Remote invocation, App-name addressing
 * ========================================================================= */

LF_DART_API void* LF_DART_CALL lf_bridge_call(
    const char* app_name, void* param, uint64_t timeout_ms);

LF_DART_API void LF_DART_CALL lf_bridge_notify(
    const char* app_name, void* param);

LF_DART_API void LF_DART_CALL lf_bridge_sequenced_notify(
    const char* app_name, void* param);

LF_DART_API int LF_DART_CALL lf_bridge_call_async(
    const char* app_name, void* param, int64_t op_id);

LF_DART_API int LF_DART_CALL lf_bridge_call_async_sequenced(
    const char* app_name, void* param, int64_t op_id);

/* ===========================================================================
 * Section 8 -- Remote invocation, UID addressing
 * ========================================================================= */

LF_DART_API void* LF_DART_CALL lf_bridge_uid_call(
    const uint8_t* uid_32, void* param, uint64_t timeout_ms);

LF_DART_API void LF_DART_CALL lf_bridge_uid_notify(
    const uint8_t* uid_32, void* param);

LF_DART_API void LF_DART_CALL lf_bridge_uid_sequenced_notify(
    const uint8_t* uid_32, void* param);

LF_DART_API int LF_DART_CALL lf_bridge_uid_call_async(
    const uint8_t* uid_32, void* param, int64_t op_id);

LF_DART_API int LF_DART_CALL lf_bridge_uid_call_async_sequenced(
    const uint8_t* uid_32, void* param, int64_t op_id);

/* ===========================================================================
 * Section 9 -- Remote invocation, P2PName addressing
 * ========================================================================= */

LF_DART_API void* LF_DART_CALL lf_bridge_p2pname_call(
    const char* p2p_name, void* param, uint64_t timeout_ms);

LF_DART_API void LF_DART_CALL lf_bridge_p2pname_notify(
    const char* p2p_name, void* param);

LF_DART_API void LF_DART_CALL lf_bridge_p2pname_sequenced_notify(
    const char* p2p_name, void* param);

LF_DART_API int LF_DART_CALL lf_bridge_p2pname_call_async(
    const char* p2p_name, void* param, int64_t op_id);

LF_DART_API int LF_DART_CALL lf_bridge_p2pname_call_async_sequenced(
    const char* p2p_name, void* param, int64_t op_id);

/* ===========================================================================
 * Section 10 -- Queries
 * ========================================================================= */

LF_DART_API int LF_DART_CALL lf_bridge_check_main_thread(void);
LF_DART_API int LF_DART_CALL lf_bridge_check_app(const char* app_name);
LF_DART_API int LF_DART_CALL lf_bridge_check_api(const char* app_name, const char* api_name);
LF_DART_API int LF_DART_CALL lf_bridge_check_uid(const uint8_t* uid_32);
LF_DART_API int LF_DART_CALL lf_bridge_check_uid_api(const uint8_t* uid_32, const char* api_name);
LF_DART_API int LF_DART_CALL lf_bridge_check_p2pname(const char* p2p_name);
LF_DART_API int LF_DART_CALL lf_bridge_check_p2pname_api(
    const char* p2p_name, const char* api_name);

/* ===========================================================================
 * Section 11 -- Options
 * ========================================================================= */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_password(const char* value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_password(char* out_buf, int buf_size);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_debug(const char* value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_debug(char* out_buf, int buf_size);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_quiet(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_quiet(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_show_thread_id(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_show_thread_id(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_console_output(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_console_output(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_overlap_connection(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_overlap_connection(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_wait_connection_ready_ok(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_wait_connection_ready_ok(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_wait_connection_timeout(uint64_t value_ms);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_wait_connection_timeout(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_ipc_serv_thread_count(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_ipc_serv_thread_count(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_ipc_serv_max_queue_length(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_ipc_serv_max_queue_length(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_ipc_serv_max_msg_size(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_ipc_serv_max_msg_size(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_fixed_sequenced_time(uint64_t value_ms);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_fixed_sequenced_time(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_p2p_name(const char* value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_p2p_name(char* out_buf, int buf_size);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_data_handle_idle_timeout(uint64_t value_ms);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_data_handle_idle_timeout(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_data_handle_pool_scan_interval(uint64_t value_ms);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_data_handle_pool_scan_interval(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_no_reponse_cmd_null_flush_threshold(int value);
LF_DART_API int LF_DART_CALL lf_bridge_get_opt_no_reponse_cmd_null_flush_threshold(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_option(const char* option, const char* value);
LF_DART_API int LF_DART_CALL lf_bridge_get_option(
    const char* option, char* out_buf, int buf_size);

/* ===========================================================================
 * Section 12 -- Status queue
 * ========================================================================= */

LF_DART_API int LF_DART_CALL lf_bridge_get_status_count(void);
LF_DART_API int LF_DART_CALL lf_bridge_get_status(char* out_buf, int buf_size);
LF_DART_API int LF_DART_CALL lf_bridge_post_status(const char* message);

/* ===========================================================================
 * Section 13 -- Network events
 * ========================================================================= */

LF_DART_API int LF_DART_CALL lf_bridge_set_network_event(
    int64_t connect_callback_id, int64_t disconnect_callback_id);

LF_DART_API int LF_DART_CALL lf_bridge_clear_network_event(void);

/* ===========================================================================
 * Section 15 -- Diagnostics
 * ========================================================================= */

LF_DART_API const char* LF_DART_CALL lf_bridge_last_error(void);
LF_DART_API const char* LF_DART_CALL lf_bridge_version(void);
LF_DART_API int LF_DART_CALL lf_bridge_stats_json(char* out_buf, int buf_size);

#ifdef __cplusplus
}
#endif

#endif /* LF_DART_BRIDGE_H_INCLUDED */