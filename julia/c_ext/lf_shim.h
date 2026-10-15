/*
 * lf_shim.h - Thread-safe C callback bridge for LingoFuse.
 *
 * See the original header comment in git history for the full design
 * rationale. This revision carries no interface change relative to
 * v2; the only difference is a documentation note explaining why
 * thread-local storage is NOT used inside the shim.
 *
 * ============================================================================
 * WHY NO THREAD-LOCAL STORAGE
 * ============================================================================
 * The runtime-option getters return `const char*` pointers. A naive
 * implementation would keep one thread-local buffer per getter. That
 * approach fails on MinGW-w64: the compiler silently ignores both
 * `__thread` and `__declspec(thread)` in a DLL that is loaded at
 * runtime (as any ccall-loaded shared library is), emitting only a
 * `-Wattributes` warning. The variable is then stored as an ordinary
 * static, and the "thread-local" contract is silently broken.
 *
 * The shim therefore gives each typed getter its own dedicated
 * static buffer, and the generic getter uses a mutex-protected
 * static buffer. See lf_shim.c for the full explanation.
 *
 * ============================================================================
 * REVISION NOTE (v2)
 * ============================================================================
 * This revision adds:
 *
 *   - Process-wide P2P API registration (lf_shim_register_p2p_*).
 *
 *   - Async call primitives for App / UID / P2PName addressing, each
 *     in plain and sequenced forms. Each primitive dispatches the
 *     request and returns immediately; the response is delivered
 *     later as an LF_SHIM_EVENT_ASYNC_RESULT event whose user_id
 *     field carries a caller-supplied token.
 *
 *   - Typed get/set helpers for every runtime option the Pascal side
 *     exposes through LF_Set_Opt_* / LF_Get_Opt_*. The generic
 *     lf_shim_set_option / lf_shim_get_option remain available for
 *     dynamic option names.
 *
 *   - A UID value type (lf_shim_uid_t) used by the UID-addressed
 *     async primitives.
 *
 *   - New event kind LF_SHIM_EVENT_ASYNC_RESULT, with matching
 *     payload accessors lf_shim_event_result_data / _len.
 *
 * Backward compatibility: every pre-existing declaration keeps its
 * exact signature. Existing callers need no change.
 *
 * ============================================================================
 * EVENT KINDS
 * ============================================================================
 *   0  LF_SHIM_EVENT_CALL               Call-mode callback (has output)
 *   1  LF_SHIM_EVENT_NOTIFY             Notify-mode callback
 *   2  LF_SHIM_EVENT_NETWORK_CONNECT    Client became online
 *   3  LF_SHIM_EVENT_NETWORK_DISCONNECT Client went offline
 *   4  LF_SHIM_EVENT_ASYNC_RESULT       Async call completed
 *
 * ============================================================================
 * user_id
 * ============================================================================
 * An opaque int64_t supplied at registration / async-dispatch time.
 * LingoFuse's `trigger` / `Data` pointer is used to carry this id
 * end-to-end: the shim casts it to void* on the way in, and casts it
 * back on the way out. This lets Julia dispatch to the correct
 * handler without exposing any Julia-managed state to native code.
 *
 * The async primitives reuse the same field: the caller supplies a
 * user_token, and the LF_SHIM_EVENT_ASYNC_RESULT event carries that
 * token back.
 *
 * ============================================================================
 * Export macro
 * ============================================================================
 * LF_SHIM_API marks a symbol as part of the public ABI of the
 * compiled shared library.
 */

#ifndef LF_SHIM_H
#define LF_SHIM_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
  #if defined(__GNUC__) || defined(__clang__)
    #define LF_SHIM_API __attribute__((dllexport))
  #elif defined(_MSC_VER)
    #define LF_SHIM_API __declspec(dllexport)
  #else
    #define LF_SHIM_API
  #endif
#elif defined(__GNUC__) || defined(__clang__)
  #define LF_SHIM_API __attribute__((visibility("default")))
#else
  #define LF_SHIM_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lf_shim_event lf_shim_event_t;

/* ====================================================================== */
/* UID value type                                                          */
/* ====================================================================== */
/*
 * A 32-byte session identifier. Byte-for-byte identical to the C
 * ABI's TP2P_UID___ (Pascal: array[0..31] of Byte).
 *
 * Field layout:
 *     bytes[0] .. bytes[31]    the 32 UID octets, in the order
 *                              produced by Generate_Global_UID.
 *
 * A zero-filled lf_shim_uid_t is the "null UID".
 *
 * ABI NOTE
 * --------
 * On x86-64 (both System V AMD64 and Microsoft x64), a >16-byte
 * aggregate is classified MEMORY by the psABI and is therefore
 * passed on the stack when it is an argument. FPC's
 * `array[0..31] of Byte` falls into the same class, so a struct
 * with a single 32-byte array member is intended to be
 * ABI-compatible with the Pascal side for the ARGUMENT-role
 * positions. The Julia binding's test suite includes a UID
 * round-trip test that would catch a divergence.
 */
typedef struct lf_shim_uid_s {
    uint8_t bytes[32];
} lf_shim_uid_t;

/* ====================================================================== */
/* Event kinds                                                             */
/* ====================================================================== */

enum {
    LF_SHIM_EVENT_CALL               = 0,
    LF_SHIM_EVENT_NOTIFY             = 1,
    LF_SHIM_EVENT_NETWORK_CONNECT    = 2,
    LF_SHIM_EVENT_NETWORK_DISCONNECT = 3,
    LF_SHIM_EVENT_ASYNC_RESULT       = 4
};

/* ====================================================================== */
/* Lifecycle                                                               */
/* ====================================================================== */

/*
 * Initialise the shim's queue and synchronisation primitives.
 *
 * Must be called before any other shim function. May be called more
 * than once per process; the second and subsequent calls reset the
 * shutdown flag.
 *
 * Precondition for re-initialisation: the previous consumer MUST
 * have been fully stopped via lf_shim_shutdown() before this call.
 *
 * Returns 1 on success, 0 on failure.
 */
LF_SHIM_API int  lf_shim_init(void);

/*
 * Signal any blocked consumer to exit and release the queue.
 * Safe to call multiple times.
 */
LF_SHIM_API void lf_shim_shutdown(void);

/* ====================================================================== */
/* Registration: App-bound                                                 */
/* ====================================================================== */

LF_SHIM_API int  lf_shim_register_call(
    void*       app,
    const char* name,
    const char* desc,
    int64_t     user_id);

LF_SHIM_API int  lf_shim_register_notify(
    void*       app,
    const char* name,
    const char* desc,
    int64_t     user_id);

/* ====================================================================== */
/* Registration: process-wide P2P                                          */
/* ====================================================================== */
/*
 * The process-wide P2P namespace is INDEPENDENT of any App. APIs
 * registered here are reachable via UID addressing and P2PName
 * addressing ONLY. They are NOT reachable via App-name addressing.
 *
 * Lifetime: survives until LF_Shutdown. NOT torn down by LF_FreeApp.
 */

LF_SHIM_API int  lf_shim_register_p2p_call(
    const char* name,
    const char* desc,
    int64_t     user_id);

LF_SHIM_API int  lf_shim_register_p2p_notify(
    const char* name,
    const char* desc,
    int64_t     user_id);

LF_SHIM_API int  lf_shim_unregister_p2p(const char* name);

/* ====================================================================== */
/* Network events                                                          */
/* ====================================================================== */

LF_SHIM_API void lf_shim_install_network_events(
    int64_t connect_user_id,
    int64_t disconnect_user_id);

LF_SHIM_API void lf_shim_clear_network_events(void);

/* ====================================================================== */
/* Async calls                                                             */
/* ====================================================================== */
/*
 * All six primitives dispatch the request and return immediately.
 * The response is delivered later as an LF_SHIM_EVENT_ASYNC_RESULT
 * event whose user_id is the user_token supplied here.
 *
 * Return value:
 *   1  request queued; a result event will follow
 *   0  dispatch failed; no event will follow
 */

LF_SHIM_API int lf_shim_async_call(
    const char* app_name,
    void*       param_hnd,
    int64_t     user_token);

LF_SHIM_API int lf_shim_async_sequenced_call(
    const char* app_name,
    void*       param_hnd,
    int64_t     user_token);

LF_SHIM_API int lf_shim_uid_async_call(
    const lf_shim_uid_t* uid,
    void*                param_hnd,
    int64_t              user_token);

LF_SHIM_API int lf_shim_uid_async_sequenced_call(
    const lf_shim_uid_t* uid,
    void*                param_hnd,
    int64_t              user_token);

LF_SHIM_API int lf_shim_p2pname_async_call(
    const char* group_name,
    void*       param_hnd,
    int64_t     user_token);

LF_SHIM_API int lf_shim_p2pname_async_sequenced_call(
    const char* group_name,
    void*       param_hnd,
    int64_t     user_token);

/* ====================================================================== */
/* Consumer side                                                           */
/* ====================================================================== */

LF_SHIM_API lf_shim_event_t* lf_shim_wait_event(int timeout_ms);

/* ====================================================================== */
/* Event accessors (const; no ownership transfer)                          */
/* ====================================================================== */

LF_SHIM_API int         lf_shim_event_kind   (const lf_shim_event_t* e);
LF_SHIM_API int64_t     lf_shim_event_user_id(const lf_shim_event_t* e);
LF_SHIM_API void*       lf_shim_event_input  (const lf_shim_event_t* e);
LF_SHIM_API void*       lf_shim_event_output (const lf_shim_event_t* e);
LF_SHIM_API const char* lf_shim_event_addr   (const lf_shim_event_t* e);

/* ====================================================================== */
/* Input payload snapshot                                                  */
/* ====================================================================== */

LF_SHIM_API const void* lf_shim_event_input_data(const lf_shim_event_t* e);
LF_SHIM_API size_t      lf_shim_event_input_len (const lf_shim_event_t* e);

/* ====================================================================== */
/* Async result payload                                                    */
/* ====================================================================== */

LF_SHIM_API const void* lf_shim_event_result_data(const lf_shim_event_t* e);
LF_SHIM_API size_t      lf_shim_event_result_len (const lf_shim_event_t* e);

/* ====================================================================== */
/* Output payload (Call and Notify events)                                 */
/* ====================================================================== */

LF_SHIM_API int  lf_shim_set_output(lf_shim_event_t* e,
                                    const void*      data,
                                    size_t           len);

LF_SHIM_API void lf_shim_complete_event(lf_shim_event_t* e);

/* ====================================================================== */
/* Runtime options - typed get / set                                       */
/* ====================================================================== */
/*
 * String getters return a pointer into a shim-owned static buffer.
 *
 * Each typed getter (password, debug, p2p_name) owns a DEDICATED
 * buffer, so concurrent getters of DIFFERENT options never interfere.
 * The generic lf_shim_get_option uses a mutex-protected shared
 * buffer; concurrent callers of the generic getter may observe each
 * other's results, so callers in a multi-threaded context should
 * copy the returned string before the next generic call.
 *
 * No thread-local storage is used. See the file header for why.
 */

/* ---- Authentication ---------------------------------------------------- */

LF_SHIM_API void        lf_shim_set_opt_password(const char* value);
LF_SHIM_API const char* lf_shim_get_opt_password(void);

/* ---- Logging and diagnostics ------------------------------------------- */

LF_SHIM_API void        lf_shim_set_opt_debug(const char* value);
LF_SHIM_API const char* lf_shim_get_opt_debug(void);
LF_SHIM_API void        lf_shim_set_opt_quiet(int value);
LF_SHIM_API int         lf_shim_get_opt_quiet(void);
LF_SHIM_API void        lf_shim_set_opt_show_thread_id(int value);
LF_SHIM_API int         lf_shim_get_opt_show_thread_id(void);
LF_SHIM_API void        lf_shim_set_opt_console_output(int value);
LF_SHIM_API int         lf_shim_get_opt_console_output(void);

/* ---- Connection readiness --------------------------------------------- */

LF_SHIM_API void        lf_shim_set_opt_overlap_connection(int value);
LF_SHIM_API int         lf_shim_get_opt_overlap_connection(void);
LF_SHIM_API void        lf_shim_set_opt_wait_connection_ready_ok(int value);
LF_SHIM_API int         lf_shim_get_opt_wait_connection_ready_ok(void);
LF_SHIM_API void        lf_shim_set_opt_wait_connection_timeout(uint64_t value_ms);
LF_SHIM_API uint64_t    lf_shim_get_opt_wait_connection_timeout(void);

/* ---- IPC -------------------------------------------------------------- */

LF_SHIM_API void        lf_shim_set_opt_ipc_serv_thread_count(int value);
LF_SHIM_API int         lf_shim_get_opt_ipc_serv_thread_count(void);
LF_SHIM_API void        lf_shim_set_opt_ipc_serv_max_queue_length(int value);
LF_SHIM_API int         lf_shim_get_opt_ipc_serv_max_queue_length(void);
LF_SHIM_API void        lf_shim_set_opt_ipc_serv_max_msg_size(int value);
LF_SHIM_API int         lf_shim_get_opt_ipc_serv_max_msg_size(void);

/* ---- Sequenced notifications ------------------------------------------ */

LF_SHIM_API void        lf_shim_set_opt_fixed_sequenced_time(uint64_t value_ms);
LF_SHIM_API uint64_t    lf_shim_get_opt_fixed_sequenced_time(void);

/* ---- P2P group name --------------------------------------------------- */

LF_SHIM_API void        lf_shim_set_opt_p2p_name(const char* value);
LF_SHIM_API const char* lf_shim_get_opt_p2p_name(void);

/* ---- Data handle pool ------------------------------------------------- */

LF_SHIM_API void        lf_shim_set_opt_data_handle_idle_timeout(uint64_t value_ms);
LF_SHIM_API uint64_t    lf_shim_get_opt_data_handle_idle_timeout(void);
LF_SHIM_API void        lf_shim_set_opt_data_handle_pool_scan_interval(uint64_t value_ms);
LF_SHIM_API uint64_t    lf_shim_get_opt_data_handle_pool_scan_interval(void);

/* ---- Command flushing ------------------------------------------------- */

LF_SHIM_API void        lf_shim_set_opt_no_reponse_cmd_null_flush_threshold(int value);
LF_SHIM_API int         lf_shim_get_opt_no_reponse_cmd_null_flush_threshold(void);

/* ---- Generic (for dynamic option names) ------------------------------- */

LF_SHIM_API void        lf_shim_set_option(const char* name, const char* value);
LF_SHIM_API const char* lf_shim_get_option(const char* name);

/* ====================================================================== */
/* Test-only drivers (implemented by mock_lf.c)                            */
/* ====================================================================== */

LF_SHIM_API void mock_lf_trigger_call(
    const char* api_name,
    const void* input_bytes, size_t input_len,
    void*       output_buf,  size_t output_cap,
    size_t*     out_written);

LF_SHIM_API void mock_lf_trigger_notify(
    const char* api_name,
    const void* input_bytes, size_t input_len);

LF_SHIM_API void mock_lf_trigger_network_event(
    int         is_connect,
    const char* addr);

LF_SHIM_API void mock_lf_trigger_async_result(
    int64_t     user_token,
    const void* result_bytes, size_t result_len);

#ifdef __cplusplus
}
#endif

#endif /* LF_SHIM_H */