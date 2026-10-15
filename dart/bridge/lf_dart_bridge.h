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
 *      to the Dart isolate and returns IMMEDIATELY. The Dart side
 *      receives it on the event loop and dispatches it to the user
 *      callback. This is the mechanism that makes the idiomatic Dart
 *      form "callAsync(app, param, (result) { ...business code... })"
 *      possible without any await/async seam. See Section 7.5.
 *
 *   C. STATIC ERROR STRING.
 *      Every int-returning bridge function uses 0 for success and a
 *      non-zero LFB_* code for failure. The bridge keeps a static,
 *      thread-local error message so callers can retrieve a
 *      human-readable description after a failure. See Section 15.
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
 *   Section 14  Callback plumbing internal - used by the bridge itself
 *   Section 15  Diagnostics       error string / bridge version / stats
 *
 * ---------------------------------------------------------------------------
 * CALLBACK PROTOCOLS
 * ---------------------------------------------------------------------------
 *
 * The bridge uses two distinct callback protocols. Getting them mixed
 * up is the single most common source of bugs, so read this section
 * carefully before touching any callback code.
 *
 *   PROTOCOL A -- SYNCHRONOUS HANDSHAKE (Sections 3, 4, 5)
 *   ------------------------------------------------------
 *   Used by:  registered Call and Notify handlers, local call handlers.
 *   Thread:   a LingoFuse native worker thread.
 *   Lifetime: the native worker BLOCKS until Dart replies.
 *
 *       native worker                        Dart isolate
 *       -------------                        ------------
 *        1. copy input bytes
 *        2. allocate request_id
 *        3. post [request_id, callback_id, input]
 *           to Dart_PostCObject  ------------>  4. event loop receives
 *                                               5. dispatch to user handler
 *                                               6. call lf_bridge_complete(
 *                                                      request_id,
 *                                                      output_bytes,
 *                                                      output_size)
 *        7. semaphore released   <------------
 *        8. copy output bytes into the
 *           native output handle
 *        9. return
 *
 *   PROTOCOL B -- FIRE-AND-FORGET (Sections 7.5, 8.5, 9.5, 13)
 *   ----------------------------------------------------------
 *   Used by:  the asynchronous invocation family and network events.
 *   Thread:   a LingoFuse native worker thread.
 *   Lifetime: the native worker returns IMMEDIATELY after posting.
 *
 *       native worker                        Dart isolate
 *       -------------                        ------------
 *        1. copy result bytes into a
 *           freshly malloc'd buffer
 *        2. post [op_id, result_bytes]
 *           to Dart_PostCObject  ------------>  3. event loop receives
 *                                               4. dispatch to user callback
 *        5. free the malloc'd buffer
 *        6. return
 *
 *   The distinction is critical:
 *     - Protocol A blocks; the native side waits for Dart.
 *     - Protocol B never blocks; the Dart side owns the payload once it
 *       has been posted.
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

/* ---------------------------------------------------------------------------
 * Export / calling convention
 * ------------------------------------------------------------------------- */

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

/* ===========================================================================
 * Error codes
 * ===========================================================================
 *
 * Every int-returning bridge function returns one of these. A return
 * value of LFB_OK (0) means success. Any other value is a failure and
 * should be reported via lf_bridge_last_error().
 *
 * The enum is not exhaustive: future versions may add codes. Callers
 * that only care about success vs failure can test for zero.
 * ========================================================================= */

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
 * ===========================================================================
 *
 * The bridge must be initialized ONCE per process, from the Dart main
 * isolate, before any other bridge function is called. Initialization
 * does three things:
 *
 *   1. Resolves every LingoFuse symbol into a static function pointer.
 *      After this call, the bridge never touches the dynamic loader
 *      again.
 *   2. Stores the Dart native port ID. Every callback message the
 *      bridge posts goes to this port.
 *   3. Registers the Dart API DL table so that Dart_PostCObject_DL
 *      works from non-Dart threads. This is the step that makes
 *      Protocol A and Protocol B possible.
 *
 * The `api_dl_data` argument must be exactly what Dart exposes as
 * NativeApi.initializeApiDLData. Passing NULL here is a hard error:
 * the bridge will refuse to initialize, and any attempt to invoke a
 * callback will crash inside the Dart runtime.
 * ========================================================================= */

/**
 * Initialize the bridge.
 *
 * @param dart_port_id  The native port ID of the Dart isolate that
 *                      will receive callback messages. Obtain this
 *                      from a ReceivePort's .sendPort.nativePort.
 * @param api_dl_data   NativeApi.initializeApiDLData from Dart.
 *                      MUST NOT be NULL.
 *
 * @return LFB_OK on success, an LFB_ErrorCode otherwise.
 *
 * Thread safety: call this exactly once, from a single thread, before
 * any other bridge function. Calling it more than once is a no-op that
 * returns LFB_OK; calling it with a different port ID is an error.
 */
LF_DART_API int LF_DART_CALL lf_bridge_init(
    int64_t dart_port_id,
    void*   api_dl_data);

/**
 * Shut down the bridge.
 *
 * This does NOT call LF_Shutdown(). It releases the bridge's internal
 * resources (threads, semaphores, cached buffers) and clears the
 * stored Dart port ID. The LingoFuse library itself remains loaded and
 * functional; call LF_Shutdown through the normal prepare/shutdown
 * path to tear down the framework.
 *
 * Safe to call multiple times. After the final call, lf_bridge_init()
 * may be called again to reinitialize.
 */
LF_DART_API void LF_DART_CALL lf_bridge_shutdown(void);

/**
 * Returns non-zero if lf_bridge_init() has completed successfully.
 */
LF_DART_API int LF_DART_CALL lf_bridge_is_initialized(void);

/* ===========================================================================
 * Section 1 -- Data handle
 * ===========================================================================
 *
 * Direct forwarders to the LingoFuse data-handle API, with two
 * bridge-specific adjustments:
 *
 *   - The identity accessors (1.7, 1.8) copy the transient pointer's
 *     target into a caller-supplied buffer and never return the
 *     pointer.
 *
 *   - The UID I/O helpers (1.9, 1.10) accept a `const uint8_t*` rather
 *     than the ARGUMENT-role TP2P_UID, so Dart does not have to pass a
 *     32-byte aggregate by value.
 *
 * The handle returned by lf_bridge_create_data / create_permanent is a
 * raw LingoFuse TDataHnd. It can be freely passed to any other bridge
 * function that expects a data handle, and it can also be passed
 * directly to Dart's FFI layer if the caller wants to invoke LingoFuse
 * helpers that the bridge does not forward.
 * ========================================================================= */

/**
 * Creates a new auto-recycled data handle bound to the given API name.
 *
 * @param api_name  UTF-8, NUL-terminated API name.
 * @return  A new handle, or NULL on failure.
 */
LF_DART_API void* LF_DART_CALL lf_bridge_create_data(
    const char* api_name);

/**
 * Creates a new PERMANENT data handle. It is not added to the idle
 * pool and must be released by an explicit lf_bridge_free_data().
 *
 * @param api_name  UTF-8, NUL-terminated API name.
 * @return  A new handle, or NULL on failure.
 */
LF_DART_API void* LF_DART_CALL lf_bridge_create_data_permanent(
    const char* api_name);

/**
 * Releases a data handle. NULL is accepted and ignored.
 *
 * For auto-recycled handles this only marks the handle as deleted;
 * the actual release happens on the next pool scan (at most 5 seconds
 * later). For permanent handles the release is synchronous.
 *
 * Do NOT call this on the `result` argument of an async callback.
 * That handle is owned by the framework and is released
 * automatically when the callback returns.
 */
LF_DART_API void LF_DART_CALL lf_bridge_free_data(
    void* hnd);

/**
 * Appends `size` bytes at the current cursor. The cursor advances by
 * the number of bytes written. The buffer grows as needed.
 *
 * @return  Number of bytes actually written, or a negative value on
 *          failure.
 */
LF_DART_API int64_t LF_DART_CALL lf_bridge_write_buffer(
    void*       hnd,
    const void* buff,
    int64_t     size);

/**
 * Reads up to `size` bytes from the current cursor into `buff`. The
 * cursor advances by the number of bytes actually read.
 *
 * @return  Number of bytes actually read, or a negative value on
 *          failure.
 */
LF_DART_API int64_t LF_DART_CALL lf_bridge_read_buffer(
    void*   hnd,
    void*   buff,
    int64_t size);

/** Returns the current read/write cursor position, or -1 on failure. */
LF_DART_API int64_t LF_DART_CALL lf_bridge_get_pos(
    void* hnd);

/**
 * Sets the current read/write cursor. A position past the current
 * size implicitly grows the buffer; the new bytes are uninitialized.
 */
LF_DART_API void LF_DART_CALL lf_bridge_set_pos(
    void*   hnd,
    int64_t pos);

/** Returns the total buffer size in bytes, or -1 on failure. */
LF_DART_API int64_t LF_DART_CALL lf_bridge_get_size(
    void* hnd);

/** Adjusts the buffer size. Newly added space is uninitialized. */
LF_DART_API void LF_DART_CALL lf_bridge_set_size(
    void*   hnd,
    int64_t size);

/* ---------------------------------------------------------------------------
 * 1.7  LF_Get_P2P_UID  --  side-data identity accessor
 * ---------------------------------------------------------------------------
 *
 * Reads the auto-injected sender UID ("side data") from an INPUT
 * handle and copies the 32 bytes into `out_uid_32`.
 *
 * IMPORTANT: this reads SIDE DATA that the sender wrote into the
 * request payload, not a property of the handle itself. It is valid
 * ONLY on the `input` argument of a registered Call / Notify callback
 * (or the input of a local call). On an OUTPUT handle or on a
 * caller-created handle it returns 32 zero bytes.
 *
 * The bridge copies the 32 bytes immediately, so the caller never
 * sees the library's transient pointer and never has to worry about
 * the ~5-second validity window.
 *
 * @param hnd         Data handle.
 * @param out_uid_32  Caller-supplied buffer of at least 32 bytes.
 * @return  LFB_OK on success, LFB_ERR_NULL_HANDLE / LFB_ERR_INVALID_ARGUMENT
 *          on failure.
 */
LF_DART_API int LF_DART_CALL lf_bridge_get_p2p_uid(
    void*    hnd,
    uint8_t* out_uid_32);

/* ---------------------------------------------------------------------------
 * 1.8  LF_Get_P2P_Name  --  side-data identity accessor
 * ---------------------------------------------------------------------------
 *
 * Reads the auto-injected sender P2P group name ("side data") from an
 * INPUT handle and copies it as a NUL-terminated UTF-8 string into
 * `out_buf`.
 *
 * Same validity rules as 1.7: only the `input` argument of a callback
 * carries side data. On any other handle the result is an empty
 * string.
 *
 * @param hnd       Data handle.
 * @param out_buf   Caller-supplied buffer.
 * @param buf_size  Size of `out_buf` in bytes.
 * @return  LFB_OK on success, LFB_ERR_BUFFER_TOO_SMALL if the name
 *          did not fit, or another LFB_ErrorCode on failure.
 */
LF_DART_API int LF_DART_CALL lf_bridge_get_p2p_name(
    void* hnd,
    char* out_buf,
    int   buf_size);

/* ---------------------------------------------------------------------------
 * 1.9  UID binary I/O
 * ---------------------------------------------------------------------------
 *
 * Fixed 32-byte read / write with no NUL framing. The bridge accepts
 * a `const uint8_t*` rather than the ARGUMENT-role TP2P_UID so that
 * Dart does not have to construct a 32-byte aggregate.
 * ------------------------------------------------------------------------- */

/**
 * Appends the 32-byte UID at the current cursor. No terminator is
 * appended.
 *
 * @param hnd     Data handle.
 * @param uid_32  Pointer to exactly 32 bytes.
 * @return  LFB_OK on success.
 */
LF_DART_API int LF_DART_CALL lf_bridge_write_uid(
    void*         hnd,
    const uint8_t* uid_32);

/**
 * Reads exactly 32 bytes from the current cursor into `out_uid_32`.
 * No terminator is consumed.
 *
 * @param hnd         Data handle.
 * @param out_uid_32  Caller-supplied buffer of at least 32 bytes.
 * @return  LFB_OK on success, LFB_ERR_LINGOFUSE_FAILED on a short read.
 */
LF_DART_API int LF_DART_CALL lf_bridge_read_uid(
    void*    hnd,
    uint8_t* out_uid_32);

/* ===========================================================================
 * Section 2 -- Application handle
 * =========================================================================== */

/**
 * Creates a new application with the given name and description.
 * The name must be unique on the wire; matching is case-insensitive.
 *
 * @param app_name  UTF-8, NUL-terminated application name.
 * @param desc      UTF-8, NUL-terminated description. May be NULL,
 *                  treated as an empty string.
 * @return  A new handle, or NULL on failure.
 */
LF_DART_API void* LF_DART_CALL lf_bridge_create_app(
    const char* app_name,
    const char* desc);

/**
 * First stage of the two-stage application destruction. The
 * application is detached from all clients and its sequenced
 * notification threads are stopped. The underlying object remains in
 * the global pool until LF_Shutdown is called.
 */
LF_DART_API void LF_DART_CALL lf_bridge_free_app(
    void* app_hnd);

/**
 * Copies the application's own name into `out_buf`. The bridge
 * copies immediately, so the caller never sees the library's
 * ~5-second transient pointer.
 */
LF_DART_API int LF_DART_CALL lf_bridge_get_app_name(
    void* app_hnd,
    char* out_buf,
    int   buf_size);

/**
 * Generates a globally unique application name.
 *
 * Must be called AFTER lf_bridge_prepare_done() has returned success.
 * The generated name includes C4 tunnel addresses, process name with
 * PID, and a high-resolution timestamp.
 *
 * The bridge copies immediately; no transient pointer is exposed.
 */
LF_DART_API int LF_DART_CALL lf_bridge_generate_app_name(
    char* out_buf,
    int   buf_size);

/**
 * Binds the application to all currently unbound LingoFuse clients.
 *
 * Must be called AFTER lf_bridge_prepare_done() has returned success
 * and while the simulated main thread is active.
 *
 * @return  Number of clients successfully bound (>= 0), or a negative
 *          LFB_ErrorCode on failure.
 */
LF_DART_API int LF_DART_CALL lf_bridge_bind_app(
    void* app_hnd);

/* ===========================================================================
 * Section 3 -- API registration (app-bound)
 * ===========================================================================
 *
 * Registered handlers run on native worker threads. They use
 * PROTOCOL A (synchronous handshake): the native worker blocks until
 * Dart calls lf_bridge_complete() with the output bytes.
 *
 * The `callback_id` argument is an opaque, caller-supplied identifier.
 * It is stored with the registration and returned verbatim in every
 * callback message, so the Dart side can dispatch to the right user
 * handler. Callers typically allocate these IDs from a monotonic
 * counter and keep a Map<int, Handler> on the Dart side.
 *
 * The registration functions themselves may only be called after
 * lf_bridge_init() has succeeded.
 * ========================================================================= */

/**
 * Registers a Call API.
 *
 * @param app_hnd      Application handle.
 * @param method_name  UTF-8, NUL-terminated API name (case-insensitive).
 * @param desc         UTF-8, NUL-terminated description. May be NULL.
 * @param callback_id  Caller-supplied identifier.
 * @return  LFB_OK on success, LFB_ERR_LINGOFUSE_FAILED if the name is
 *          already taken, or another error code.
 */
LF_DART_API int LF_DART_CALL lf_bridge_register_call(
    void*       app_hnd,
    const char* method_name,
    const char* desc,
    int64_t     callback_id);

/**
 * Registers a Notify API.
 *
 * @param callback_id  Caller-supplied identifier. Notify callbacks do
 *                     not produce output, but the ID is still returned
 *                     in the callback message so the Dart side can
 *                     dispatch.
 */
LF_DART_API int LF_DART_CALL lf_bridge_register_notify(
    void*       app_hnd,
    const char* method_name,
    const char* desc,
    int64_t     callback_id);

/**
 * Unregisters a previously registered API by name.
 *
 * @return  LFB_OK if the API was found and removed,
 *          LFB_ERR_LINGOFUSE_FAILED otherwise.
 */
LF_DART_API int LF_DART_CALL lf_bridge_unregister(
    void*       app_hnd,
    const char* method_name);

/**
 * Reply entry point for PROTOCOL A.
 *
 * Called by the Dart isolate when a user handler has finished. The
 * `request_id` is the first element of the message the bridge posted.
 *
 * The bridge copies `output` into the LingoFuse output handle and
 * releases the blocked native worker.
 *
 * Passing NULL for `output` with `size == 0` is legal and means "empty
 * reply".
 *
 * Thread safety: safe to call from any Dart thread. The `request_id`
 * uniquely identifies the pending native worker.
 */
LF_DART_API int LF_DART_CALL lf_bridge_complete(
    int64_t      request_id,
    const uint8_t* output,
    int64_t      size);

/* ===========================================================================
 * Section 4 -- API registration (process-wide P2P)
 * ===========================================================================
 *
 * APIs registered here live on the process-wide LF_P2P_APP and are
 * reachable via UID addressing and P2PName addressing ONLY. They are
 * NOT reachable via App-name addressing.
 *
 * The callback protocol is identical to Section 3: PROTOCOL A with
 * lf_bridge_complete as the reply entry point. Registration IDs are
 * drawn from the same counter namespace.
 * ========================================================================= */

/**
 * Registers a process-wide Call API.
 */
LF_DART_API int LF_DART_CALL lf_bridge_register_p2p_call(
    const char* method_name,
    const char* desc,
    int64_t     callback_id);

/**
 * Registers a process-wide Notify API.
 */
LF_DART_API int LF_DART_CALL lf_bridge_register_p2p_notify(
    const char* method_name,
    const char* desc,
    int64_t     callback_id);

/**
 * Removes a process-wide P2P API by name.
 *
 * @return  LFB_OK if the API was found and removed,
 *          LFB_ERR_LINGOFUSE_FAILED otherwise.
 */
LF_DART_API int LF_DART_CALL lf_bridge_unregister_p2p(
    const char* method_name);

/* ===========================================================================
 * Section 5 -- Local execution
 * ===========================================================================
 *
 * Local calls run in-process and bypass the network. The callback
 * protocol is still PROTOCOL A: the calling thread blocks until Dart
 * returns the output bytes.
 * ========================================================================= */

/**
 * Executes a Call API locally.
 *
 * @param app_hnd  Application handle.
 * @param param    Input data handle. Not consumed.
 * @return  A new result handle (must be freed by the caller), or NULL
 *          on failure. On a missing API, an empty (size 0) handle is
 *          returned, matching LingoFuse semantics.
 */
LF_DART_API void* LF_DART_CALL lf_bridge_local_call(
    void* app_hnd,
    void* param);

/**
 * Executes a Notify API locally. No return value.
 */
LF_DART_API void LF_DART_CALL lf_bridge_local_notify(
    void* app_hnd,
    void* param);

/* ===========================================================================
 * Section 6 -- Network preparation
 * ========================================================================= */

/**
 * Clears any previously prepared services and clients. Running
 * services and clients are unaffected.
 */
LF_DART_API void LF_DART_CALL lf_bridge_reset_prepare(void);

/**
 * Prepares a C4 service.
 *
 * @return  A tag ID (>= 0), or a negative LFB_ErrorCode if the address
 *          is a duplicate / invalid.
 */
LF_DART_API int LF_DART_CALL lf_bridge_prepare_service(
    const char* listening_addr,
    const char* physics_addr);

/**
 * Prepares a client connecting to `physics_addr`, optionally exposing
 * `app_hnd` on the mesh.
 *
 * @param app_hnd  Application handle, or NULL for a pure consumer.
 * @return  A tag ID (>= 0), or a negative LFB_ErrorCode on failure.
 */
LF_DART_API int LF_DART_CALL lf_bridge_prepare_client(
    const char* physics_addr,
    void*       app_hnd);

/**
 * Starts the framework with all prepared services and clients.
 *
 * Returns 1 exactly ONCE per process (without an intervening
 * lf_bridge_shutdown_lf()). A second call returns 0; do NOT interpret
 * that as a failure.
 *
 * @return  1 on success, 0 on failure or repeated call. A negative
 *          value is a bridge error.
 */
LF_DART_API int LF_DART_CALL lf_bridge_prepare_done(void);

/**
 * Requests the simulated main thread to exit gracefully.
 *
 * WARNING: this also flushes the data handle pool, releasing every
 * outstanding handle - including permanent ones. Do not use any data
 * handle after this call.
 */
LF_DART_API void LF_DART_CALL lf_bridge_exit_main_thread(void);

/**
 * Full LingoFuse shutdown. Distinct from lf_bridge_shutdown(), which
 * only tears down the bridge. Call this to release framework
 * resources; call lf_bridge_shutdown() afterwards to release bridge
 * resources, or just let the process exit.
 *
 * Safe to call multiple times.
 */
LF_DART_API void LF_DART_CALL lf_bridge_lf_shutdown(void);

/* ===========================================================================
 * Section 7 -- Remote invocation, App-name addressing
 * ===========================================================================
 *
 * Synchronous forms (7.1 - 7.3) block the calling thread until the
 * reply arrives or the timeout expires. They use no callbacks and are
 * safe to call from the Dart main isolate ONLY if the timeout is short
 * (because the Dart event loop is blocked while the call is in
 * flight). The idiomatic use from Dart is to run them in a worker
 * isolate, or to prefer the async forms (7.4 - 7.6).
 *
 * Asynchronous forms (7.4 - 7.6) return immediately. The result is
 * delivered to the Dart isolate via PROTOCOL B: the bridge posts
 * [op_id, result_bytes] to Dart_PostCObject and returns without
 * waiting. The Dart side dispatches on `op_id`.
 * ========================================================================= */

/* ---------------------------------------------------------------------------
 * 7.1  LF_Call  --  synchronous remote call
 * ---------------------------------------------------------------------------
 *
 * @param app_name     Target application name (UTF-8).
 * @param param        Input data handle. Not consumed.
 * @param timeout_ms   Timeout in milliseconds. 0 means infinite.
 * @return  A new result handle (must be freed by the caller). On
 *          timeout / failure this is an empty (size 0) handle, NOT
 *          NULL. Callers who want a nullable contract should use 7.2.
 */
LF_DART_API void* LF_DART_CALL lf_bridge_call(
    const char* app_name,
    void*       param,
    uint64_t    timeout_ms);

/* ---------------------------------------------------------------------------
 * 7.2  LF_Notify  --  one-way notification
 * ------------------------------------------------------------------------- */
LF_DART_API void LF_DART_CALL lf_bridge_notify(
    const char* app_name,
    void*       param);

/* ---------------------------------------------------------------------------
 * 7.3  LF_Sequenced_Notify  --  FIFO one-way notification
 * ------------------------------------------------------------------------- */
LF_DART_API void LF_DART_CALL lf_bridge_sequenced_notify(
    const char* app_name,
    void*       param);

/* ---------------------------------------------------------------------------
 * 7.4  LF_Async_Call  --  asynchronous remote call
 * ---------------------------------------------------------------------------
 *
 * Fires the request and returns immediately. When the reply arrives,
 * the bridge posts a message to the Dart isolate:
 *
 *     [op_id: int64, result_bytes: Uint8List]
 *
 * The `op_id` is whatever the caller supplied. It is echoed verbatim
 * and is the only thing the Dart side needs in order to route the
 * result to the right user callback.
 *
 * The `result_bytes` are the raw bytes of the reply handle. They have
 * already been copied out of the framework-owned buffer, so they are
 * safe to retain indefinitely. An empty result produces a zero-length
 * Uint8List; a timeout produces the same thing (matching LingoFuse
 * semantics: timeout => size 0).
 *
 * @param app_name     Target application name (UTF-8).
 * @param param        Input data handle. Not consumed. The bridge
 *                     copies the payload synchronously inside this
 *                     call, so `param` may be freed the moment this
 *                     function returns.
 * @param op_id        Caller-supplied operation ID.
 * @return  LFB_OK if the request was dispatched, an LFB_ErrorCode
 *          otherwise. NOTE: a successful dispatch does NOT guarantee
 *          that a reply will arrive; a reply may be delayed
 *          indefinitely if the target is unreachable. The Dart side
 *          is responsible for imposing its own timeout if it wants
 *          one.
 *
 * Threading contract for the Dart-side callback:
 *   The callback runs on the Dart event loop, NOT on a native worker
 *   thread. It MUST NOT block, MUST NOT call back into the bridge
 *   synchronously, and MUST NOT touch UI without proper marshalling.
 */
LF_DART_API int LF_DART_CALL lf_bridge_call_async(
    const char* app_name,
    void*       param,
    int64_t     op_id);

/* ---------------------------------------------------------------------------
 * 7.5  LF_Async_Sequenced_Call  --  FIFO asynchronous call
 * ---------------------------------------------------------------------------
 * Same wire protocol as 7.4.
 * ------------------------------------------------------------------------- */
LF_DART_API int LF_DART_CALL lf_bridge_call_async_sequenced(
    const char* app_name,
    void*       param,
    int64_t     op_id);

/* ===========================================================================
 * Section 8 -- Remote invocation, UID addressing
 * ===========================================================================
 *
 * The UID is passed as a `const uint8_t*` to exactly 32 bytes. The
 * bridge repacks it into the ARGUMENT-role TP2P_UID struct on the C
 * side, which is why Dart never has to deal with a 32-byte aggregate.
 *
 * Routing is local-first: if the caller process itself hosts a
 * matching client, the call is serviced without touching the network.
 * ========================================================================= */

/* ---------------------------------------------------------------------------
 * 8.1  LF_UID_Call  --  synchronous call by UID
 * ------------------------------------------------------------------------- */
LF_DART_API void* LF_DART_CALL lf_bridge_uid_call(
    const uint8_t* uid_32,
    void*          param,
    uint64_t       timeout_ms);

/* ---------------------------------------------------------------------------
 * 8.2  LF_UID_Notify  --  one-way notification by UID
 * ------------------------------------------------------------------------- */
LF_DART_API void LF_DART_CALL lf_bridge_uid_notify(
    const uint8_t* uid_32,
    void*          param);

/* ---------------------------------------------------------------------------
 * 8.3  LF_UID_Sequenced_Notify  --  FIFO one-way notification by UID
 * ------------------------------------------------------------------------- */
LF_DART_API void LF_DART_CALL lf_bridge_uid_sequenced_notify(
    const uint8_t* uid_32,
    void*          param);

/* ---------------------------------------------------------------------------
 * 8.4  LF_UID_Async_Call  --  asynchronous call by UID
 * ---------------------------------------------------------------------------
 * Same PROTOCOL B contract as 7.4.
 * ------------------------------------------------------------------------- */
LF_DART_API int LF_DART_CALL lf_bridge_uid_call_async(
    const uint8_t* uid_32,
    void*          param,
    int64_t        op_id);

/* ---------------------------------------------------------------------------
 * 8.5  LF_UID_Async_Sequenced_Call
 * ------------------------------------------------------------------------- */
LF_DART_API int LF_DART_CALL lf_bridge_uid_call_async_sequenced(
    const uint8_t* uid_32,
    void*          param,
    int64_t        op_id);

/* ===========================================================================
 * Section 9 -- Remote invocation, P2PName addressing
 * ===========================================================================
 *
 * P2PName routing is NOT local-first. Even when the caller process
 * hosts a client in the target group, the call is forwarded to the
 * server for dispatch. The server-side dispatcher owns the load
 * balancing state, and short-cutting locally would defeat it.
 * ========================================================================= */

/* ---------------------------------------------------------------------------
 * 9.1  LF_P2PNAME_Call  --  synchronous call by group name
 * ------------------------------------------------------------------------- */
LF_DART_API void* LF_DART_CALL lf_bridge_p2pname_call(
    const char* p2p_name,
    void*       param,
    uint64_t    timeout_ms);

/* ---------------------------------------------------------------------------
 * 9.2  LF_P2PNAME_Notify
 * ------------------------------------------------------------------------- */
LF_DART_API void LF_DART_CALL lf_bridge_p2pname_notify(
    const char* p2p_name,
    void*       param);

/* ---------------------------------------------------------------------------
 * 9.3  LF_P2PNAME_Sequenced_Notify
 * ------------------------------------------------------------------------- */
LF_DART_API void LF_DART_CALL lf_bridge_p2pname_sequenced_notify(
    const char* p2p_name,
    void*       param);

/* ---------------------------------------------------------------------------
 * 9.4  LF_P2PNAME_Async_Call
 * ---------------------------------------------------------------------------
 * Same PROTOCOL B contract as 7.4.
 * ------------------------------------------------------------------------- */
LF_DART_API int LF_DART_CALL lf_bridge_p2pname_call_async(
    const char* p2p_name,
    void*       param,
    int64_t     op_id);

/* ---------------------------------------------------------------------------
 * 9.5  LF_P2PNAME_Async_Sequenced_Call
 * ------------------------------------------------------------------------- */
LF_DART_API int LF_DART_CALL lf_bridge_p2pname_call_async_sequenced(
    const char* p2p_name,
    void*       param,
    int64_t     op_id);

/* ===========================================================================
 * Section 10 -- Queries
 * ===========================================================================
 *
 * All queries consult a locally cached broadcast view with a typical
 * propagation delay of about 3 seconds. They are probing tools, not
 * authoritative existence tests. Return value is 1 for true, 0 for
 * false, and a negative LFB_ErrorCode on a bridge failure.
 * ========================================================================= */

LF_DART_API int LF_DART_CALL lf_bridge_check_main_thread(void);

LF_DART_API int LF_DART_CALL lf_bridge_check_app(
    const char* app_name);

LF_DART_API int LF_DART_CALL lf_bridge_check_api(
    const char* app_name,
    const char* api_name);

LF_DART_API int LF_DART_CALL lf_bridge_check_uid(
    const uint8_t* uid_32);

LF_DART_API int LF_DART_CALL lf_bridge_check_uid_api(
    const uint8_t* uid_32,
    const char*    api_name);

LF_DART_API int LF_DART_CALL lf_bridge_check_p2pname(
    const char* p2p_name);

LF_DART_API int LF_DART_CALL lf_bridge_check_p2pname_api(
    const char* p2p_name,
    const char* api_name);

/* ===========================================================================
 * Section 11 -- Options
 * ===========================================================================
 *
 * LingoFuse's LF_SetOption / LF_GetOption pair is stringly typed. This
 * section provides a typed set/get pair for every documented option,
 * so Dart callers never see a string where an int or a bool was
 * intended.
 *
 * All setters return LFB_OK on success. Unknown option names are
 * silently ignored by the underlying LF_SetOption, so the setters here
 * cannot report "unknown option" - they can only report bridge-level
 * failures such as a NULL argument.
 *
 * All getters return the value directly. When the underlying option is
 * unknown or unset, the getters return a documented safe fallback:
 *     int / uint64 getters  -> 0
 *     string getters        -> "" (empty string)
 *     bool getters          -> 0 (false)
 *
 * Options are NOT persisted across LF_Shutdown. An application that
 * restarts the framework must reapply its options on every startup.
 * ========================================================================= */

/* ---------------------------------------------------------------------------
 * 11.1  Authentication
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_password(
    const char* value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_password(
    char* out_buf,
    int   buf_size);

/* ---------------------------------------------------------------------------
 * 11.2  Logging and diagnostics
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_debug(
    const char* value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_debug(
    char* out_buf,
    int   buf_size);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_quiet(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_quiet(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_show_thread_id(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_show_thread_id(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_console_output(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_console_output(void);

/* ---------------------------------------------------------------------------
 * 11.3  Connection readiness
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_overlap_connection(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_overlap_connection(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_wait_connection_ready_ok(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_wait_connection_ready_ok(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_wait_connection_timeout(
    uint64_t value_ms);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_wait_connection_timeout(void);

/* ---------------------------------------------------------------------------
 * 11.4  IPC
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_ipc_serv_thread_count(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_ipc_serv_thread_count(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_ipc_serv_max_queue_length(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_ipc_serv_max_queue_length(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_ipc_serv_max_msg_size(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_ipc_serv_max_msg_size(void);

/* ---------------------------------------------------------------------------
 * 11.5  Sequenced notifications
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_fixed_sequenced_time(
    uint64_t value_ms);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_fixed_sequenced_time(void);

/* ---------------------------------------------------------------------------
 * 11.6  P2P group name
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_p2p_name(
    const char* value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_p2p_name(
    char* out_buf,
    int   buf_size);

/* ---------------------------------------------------------------------------
 * 11.7  Data handle pool
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_data_handle_idle_timeout(
    uint64_t value_ms);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_data_handle_idle_timeout(void);

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_data_handle_pool_scan_interval(
    uint64_t value_ms);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_data_handle_pool_scan_interval(void);

/* ---------------------------------------------------------------------------
 * 11.8  Command flushing
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_opt_no_reponse_cmd_null_flush_threshold(
    int value);

LF_DART_API int LF_DART_CALL lf_bridge_get_opt_no_reponse_cmd_null_flush_threshold(void);

/* ---------------------------------------------------------------------------
 * 11.9  Generic escape hatch
 * ---------------------------------------------------------------------------
 *
 * For options not covered above, or for scripting-style access with
 * dynamic option names. The string getter copies into a
 * caller-supplied buffer and never exposes the library's transient
 * pointer.
 * ------------------------------------------------------------------------- */

LF_DART_API int LF_DART_CALL lf_bridge_set_option(
    const char* option,
    const char* value);

LF_DART_API int LF_DART_CALL lf_bridge_get_option(
    const char* option,
    char*       out_buf,
    int         buf_size);

/* ===========================================================================
 * Section 12 -- Status queue
 * ===========================================================================
 *
 * The status queue depends on the simulated main thread. Before
 * lf_bridge_prepare_done() succeeds, the queue may be empty or stale.
 * ========================================================================= */

/**
 * Number of pending status messages (0 .. 1000), or -1 on failure.
 */
LF_DART_API int LF_DART_CALL lf_bridge_get_status_count(void);

/**
 * Copies the next status message (FIFO) into `out_buf` and removes it
 * from the queue.
 *
 * @return  LFB_OK on success, LFB_ERR_BUFFER_TOO_SMALL if the message
 *          did not fit (the message is consumed anyway), or
 *          LFB_ERR_LINGOFUSE_FAILED if the queue is empty.
 */
LF_DART_API int LF_DART_CALL lf_bridge_get_status(
    char* out_buf,
    int   buf_size);

/**
 * Injects a custom status message into the queue.
 */
LF_DART_API int LF_DART_CALL lf_bridge_post_status(
    const char* message);

/* ===========================================================================
 * Section 13 -- Network events
 * ===========================================================================
 *
 * Network events fire when a client becomes online (the first time it
 * receives a service API-info broadcast; this is NOT the TCP
 * handshake) or when a physical link is lost.
 *
 * The callback protocol is PROTOCOL B: the native worker posts a
 * message to the Dart isolate and returns immediately. The message
 * is:
 *
 *     [callback_id: int64, addr: Uint8List (UTF-8 bytes)]
 *
 * where `callback_id` is the connect_callback_id or
 * disconnect_callback_id supplied to lf_bridge_set_network_event.
 *
 * Both handlers are process-global. There is no per-client
 * registration. Installing new handlers replaces the previous ones
 * entirely; passing -1 for a handler disables that event.
 * ========================================================================= */

/**
 * Installs or replaces the process-global network event handlers.
 *
 * @param connect_callback_id     Caller-supplied ID for the connect
 *                                event, or -1 to disable.
 * @param disconnect_callback_id  Caller-supplied ID for the disconnect
 *                                event, or -1 to disable.
 * @return  LFB_OK on success.
 */
LF_DART_API int LF_DART_CALL lf_bridge_set_network_event(
    int64_t connect_callback_id,
    int64_t disconnect_callback_id);

/**
 * Removes both network event handlers.
 */
LF_DART_API int LF_DART_CALL lf_bridge_clear_network_event(void);

/* ===========================================================================
 * Section 14 -- Callback plumbing
 * ===========================================================================
 *
 * Functions in this section are used by the bridge itself and should
 * not be called from user code. They are declared here so that the
 * bridge's own translation unit can reference them without a forward
 * declaration, and so that a future Dart-side reimplementation of the
 * callback dispatcher can reuse them.
 *
 * In the current implementation, all of Section 14 is INTERNAL to
 * lf_dart_bridge.c and is not exported. The declarations below are
 * kept in the header for documentation purposes only; they are
 * commented out to avoid accidental linkage.
 *
 * ---------------------------------------------------------------------------
 *
 * static void LF_CDECL bridge_call_trampoline(
 *     void* trigger, void* input, void* output);
 *
 *     Protocol-A trampoline. Called by LingoFuse on a native worker
 *     thread. Copies the input bytes, posts the callback message, and
 *     blocks on a semaphore until lf_bridge_complete() is called.
 *
 * static void LF_CDECL bridge_notify_trampoline(
 *     void* trigger, void* input);
 *
 *     Protocol-A trampoline for Notify. Same as above but with no
 *     output and no handshake: the worker returns as soon as the
 *     message has been posted.
 *
 * static void LF_CDECL bridge_async_on_result(
 *     void* data, void* result);
 *
 *     Protocol-B trampoline for the asynchronous call family. Copies
 *     the result bytes into a freshly malloc'd buffer, posts
 *     [op_id, bytes], frees the buffer, and returns. The native
 *     framework releases the `result` handle the instant this
 *     function returns, so the copy MUST happen before the return.
 *
 * static void LF_CDECL bridge_network_event_trampoline(
 *     const char* addr);
 *
 *     Protocol-B trampoline for network events. The exact same
 *     trampoline is installed for both connect and disconnect; the
 *     dispatch to the right Dart handler is done by the Dart side
 *     based on which message arrives. (In the current version the
 *     bridge installs two DIFFERENT trampolines, one per event, so
 *     that the Dart side can distinguish them by callback_id.)
 *
 * ========================================================================= */

/* ===========================================================================
 * Section 15 -- Diagnostics
 * =========================================================================== */

/**
 * Returns a human-readable description of the most recent failure on
 * the CALLING THREAD.
 *
 * The returned pointer points into thread-local storage and remains
 * valid until the same thread performs another bridge call. Copy the
 * string immediately if you need to retain it.
 *
 * If no failure has occurred on this thread, an empty string is
 * returned.
 */
LF_DART_API const char* LF_DART_CALL lf_bridge_last_error(void);

/**
 * Returns the bridge's own version string, for diagnostics.
 * The returned pointer is a static constant and is valid forever.
 */
LF_DART_API const char* LF_DART_CALL lf_bridge_version(void);

/**
 * Returns bridge statistics as a NUL-terminated UTF-8 JSON string
 * copied into `out_buf`.
 *
 * The JSON object contains at least:
 *     {
 *         "initialized":      bool,
 *         "pending_requests": int,   // Protocol A in flight
 *         "pending_callbacks":int,   // Protocol B IDs allocated
 *         "dart_post_ok":     int,
 *         "dart_post_fail":   int,
 *         "library_loaded":   bool
 *     }
 *
 * @return  LFB_OK on success, LFB_ERR_BUFFER_TOO_SMALL if it did not
 *          fit.
 */
LF_DART_API int LF_DART_CALL lf_bridge_stats_json(
    char* out_buf,
    int   buf_size);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LF_DART_BRIDGE_H_INCLUDED */