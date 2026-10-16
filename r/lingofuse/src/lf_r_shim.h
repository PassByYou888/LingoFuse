/* ============================================================================
 * lf_r_shim.h
 * ----------------------------------------------------------------------------
 * Interface between the C shim (lf_r_shim.c) and the C++ implementation
 * (lf_bridge.cpp) of the LingoFuse R bridge.
 *
 * RULES
 *   1. Pure C89. No R headers, no SEXP, no C++ types.
 *   2. Every declaration is extern "C".
 *   3. Returned const char* points to static or thread-local storage
 *      owned by the C++ layer. The caller must copy before the next
 *      call. Must NOT free.
 *   4. Opaque handles (void*) are caller-owned.
 *
 * VERSION HISTORY
 *   v1.0 (initial)
 *     - STEP 1 probes (ping / echo / info)
 *     - STEP 2 DataHandle + AppHandle
 *     - STEP 3a network preparation + app-name invocation
 *     - STEP 3b callee (job queue + trampolines)
 *
 *   v2.0 (this file)
 *     Complete coverage of the 59-symbol C ABI, plus a modern
 *     asynchronous layer.
 *
 *     New in v2.0:
 *       - Runtime options (set + get)
 *       - Status queue (get_count / get / post)
 *       - UID addressing (call / notify / sequenced_notify + checks)
 *       - P2PName addressing (call / notify / sequenced_notify + checks)
 *       - Process-wide P2P registration (call / notify / unregister)
 *       - Local execution (local_call / local_notify)
 *       - Asynchronous calls (six variants) with explicit lifetime
 *       - Network events (set / clear)
 *       - Side data extraction (sender UID / P2P name) from a job
 *       - Misc: generate_app_name / app_bind / app_unregister /
 *               data_set_size / data_get_buffer
 *
 * LIFETIME MODEL FOR ASYNCHRONOUS CALLS
 * -------------------------------------
 * The C4 request issued by LF_Async_Call* cannot be cancelled. Even
 * when the R side has given up on it, the framework will still
 * invoke the ctypes callback when (or if) the response arrives.
 *
 * If the bridge freed the ctypes callback on a Python-side timeout,
 * the C side would be left holding a dangling function pointer, and
 * the next invocation would crash the process. This is the exact
 * hazard that the Python bindings had to solve with their
 * AsyncBridge state machine; the R bridge uses the same discipline.
 *
 * The rules enforced by this interface are:
 *
 *   1. lf_impl_async_call*() returns a POSITIVE callback_id on
 *      dispatch success and 0 on dispatch failure.
 *        - Success  -> the callback is now live on the C side.
 *        - Failure  -> the callback was never handed to C; the slot
 *                      is released immediately and no callback will
 *                      ever fire.
 *
 *   2. The callback may fire at any time after success - before the
 *      R side calls lf_impl_async_release, or after, or never.
 *
 *   3. lf_impl_async_release(id) marks the slot as ORPHANED. A late
 *      callback then delivers its result to a slot that is still
 *      valid (so no use-after-free), but the result is dropped
 *      instead of being queued to the R side. The ctypes callback
 *      OBJECT IS NEVER FREED until lf_impl_unload_library or
 *      process exit.
 *
 *   4. On successful completion (R side received the result),
 *      the R side calls lf_impl_async_release(id) to release its
 *      slot, exactly as on timeout.
 *
 *   5. lf_impl_shutdown / lf_impl_unload_library drop every
 *      remaining slot at once. This is the only bulk release point.
 *
 * The cost of "never free the ctypes callback object early" is a
 * small per-slot allocation (a few hundred bytes) that is reclaimed
 * at process exit. The benefit is that the process cannot crash on
 * a late callback. The trade-off is deliberate and matches the
 * Python binding's design choice.
 * ========================================================================== */

#ifndef LF_R_SHIM_H
#define LF_R_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * SECTION 1 - Build chain probes (STEP 1)
 * ----------------------------------------------------------------------------
 * These are pure C++ functions; they do not touch the runtime. They
 * exist so that the R smoke test can verify that the bridge DLL was
 * correctly linked and loaded, before any runtime is involved.
 * ========================================================================== */

const char* lf_impl_ping(void);
const char* lf_impl_version(void);
const char* lf_impl_stage(void);
const char* lf_impl_compiled(void);

/* ============================================================================
 * SECTION 2 - Runtime loading (STEP 2)
 * ========================================================================== */

int         lf_impl_load_library(const char* runtime_dir);
void        lf_impl_unload_library(void);
int         lf_impl_is_loaded(void);
const char* lf_impl_loaded_path(void);
const char* lf_impl_last_error(void);

/* ============================================================================
 * SECTION 3 - DataHandle (STEP 2)
 * ----------------------------------------------------------------------------
 * The DataHandle wraps LF_CreateData / LF_CreateData_Permanent and
 * exposes the full read / write / position / size surface. The
 * permanent variant is never auto-reclaimed by the runtime and must
 * be released explicitly with lf_impl_data_free.
 * ========================================================================== */

void*   lf_impl_data_create(const char* api_name);
void*   lf_impl_data_create_permanent(const char* api_name);
void    lf_impl_data_free(void* hnd);
int64_t lf_impl_data_write_buffer(void* hnd, const void* buf, int64_t len);
int64_t lf_impl_data_read_buffer(void* hnd, void* buf, int64_t len);
int64_t lf_impl_data_get_pos(void* hnd);
int     lf_impl_data_set_pos(void* hnd, int64_t pos);
int64_t lf_impl_data_get_size(void* hnd);
void*   lf_impl_data_get_buffer(void* hnd);          /* NEW v2.0 */
int     lf_impl_data_set_size(void* hnd, int64_t size); /* NEW v2.0 */

/* ============================================================================
 * SECTION 4 - AppHandle (STEP 2)
 * ========================================================================== */

void*       lf_impl_app_create(const char* name, const char* description);
void        lf_impl_app_free(void* app);
const char* lf_impl_app_name(void* app);
int         lf_impl_app_bind(void* app);             /* NEW v2.0 */
int         lf_impl_app_unregister(                  /* NEW v2.0 */
    void* app, const char* api_name);

/* Generate a globally unique application name.
 *
 * Backed by LF_Generate_AppName, which returns a pointer that is
 * valid for about 5 seconds and is then released by the runtime.
 * The C++ layer therefore copies the string immediately and stores
 * it in thread-local storage. The returned pointer is valid until
 * the next call to this function on the same thread. */
const char* lf_impl_generate_app_name(void);         /* NEW v2.0 */

/* ============================================================================
 * SECTION 5 - Network preparation (STEP 3a)
 * ========================================================================== */

int  lf_impl_reset_prepare(void);
int  lf_impl_prepare_client(const char* endpoint);
int  lf_impl_prepare_client_with_app(const char* endpoint, void* app);
int  lf_impl_prepare_service(const char* listen_addr, const char* physics_addr);
int  lf_impl_prepare_done(void);
void lf_impl_exit_main_thread(void);
int  lf_impl_check_main_thread(void);
int  lf_impl_check_app(const char* app_name);
int  lf_impl_check_api(const char* app_name, const char* api_name);

/* ============================================================================
 * SECTION 6 - Remote invocation by App name (STEP 3a)
 * ----------------------------------------------------------------------------
 * String and binary variants. The binary variant transmits the
 * payload verbatim; no NUL terminator is added or stripped.
 * ========================================================================== */

const char* lf_impl_call(
    const char* app_name, const char* api_name, const char* payload,
    uint64_t timeout_ms, int64_t* out_len);

int lf_impl_notify(
    const char* app_name, const char* api_name, const char* payload);

int lf_impl_sequenced_notify(
    const char* app_name, const char* api_name, const char* payload);

const char* lf_impl_call_bin(
    const char* app_name, const char* api_name,
    const void* req, int64_t req_len,
    uint64_t timeout_ms, int64_t* out_len);

int lf_impl_notify_bin(
    const char* app_name, const char* api_name,
    const void* req, int64_t req_len);

/* ============================================================================
 * SECTION 7 - Remote invocation by UID (NEW v2.0)
 * ----------------------------------------------------------------------------
 * The uid pointer MUST point to exactly 32 bytes. The C ABI
 * declares the UID as a 32-byte Pascal array (TP2P_UID___), which
 * on x64 is passed on the stack as a MEMORY-class aggregate. The
 * C++ implementation converts the byte pointer into the matching
 * by-value struct before calling the runtime.
 *
 * Both the string and the binary variants are provided.
 * ========================================================================== */

const char* lf_impl_uid_call(
    const uint8_t* uid, const char* api_name, const char* payload,
    uint64_t timeout_ms, int64_t* out_len);

int lf_impl_uid_notify(
    const uint8_t* uid, const char* api_name, const char* payload);

int lf_impl_uid_sequenced_notify(
    const uint8_t* uid, const char* api_name, const char* payload);

const char* lf_impl_uid_call_bin(
    const uint8_t* uid, const char* api_name,
    const void* req, int64_t req_len,
    uint64_t timeout_ms, int64_t* out_len);

int lf_impl_uid_notify_bin(
    const uint8_t* uid, const char* api_name,
    const void* req, int64_t req_len);

/* ============================================================================
 * SECTION 8 - Remote invocation by P2P name (NEW v2.0)
 * ========================================================================== */

const char* lf_impl_p2pname_call(
    const char* group_name, const char* api_name, const char* payload,
    uint64_t timeout_ms, int64_t* out_len);

int lf_impl_p2pname_notify(
    const char* group_name, const char* api_name, const char* payload);

int lf_impl_p2pname_sequenced_notify(
    const char* group_name, const char* api_name, const char* payload);

const char* lf_impl_p2pname_call_bin(
    const char* group_name, const char* api_name,
    const void* req, int64_t req_len,
    uint64_t timeout_ms, int64_t* out_len);

int lf_impl_p2pname_notify_bin(
    const char* group_name, const char* api_name,
    const void* req, int64_t req_len);

/* ============================================================================
 * SECTION 9 - Local execution (NEW v2.0)
 * ----------------------------------------------------------------------------
 * These go through the C4 engine (LF_LocalCall / LF_LocalNotify) and
 * therefore dispatch to the C-side registered handlers, NOT to the
 * R-side handler table.
 *
 * WARNING: Calling lf_impl_local_call from the R main thread will
 * deadlock if the target handler is registered in R. The handler
 * would be enqueued as a Job that can only be serviced by a
 * subsequent lf_poll, but lf_impl_local_call is blocking on the
 * SAME thread. R users should normally use the R-level local
 * dispatch helpers instead; these C-level entry points exist only
 * for mixed-language scenarios where the target is a C handler.
 * ========================================================================== */

const char* lf_impl_local_call(
    void* app, const char* api_name, const char* payload,
    int64_t* out_len);

int lf_impl_local_notify(
    void* app, const char* api_name, const char* payload);

/* ============================================================================
 * SECTION 10 - Runtime options (NEW v2.0)
 * ----------------------------------------------------------------------------
 * Every option key recognised by LF_SetOption is also readable
 * through LF_GetOption. The C++ layer copies the returned string
 * immediately; the runtime's transient buffer is never exposed.
 *
 * The lf_impl_get_option result is stored in thread-local storage
 * and remains valid until the next call on the same thread.
 * ========================================================================== */

void        lf_impl_set_option(const char* name, const char* value);
const char* lf_impl_get_option(const char* name);    /* NEW v2.0 */

/* ============================================================================
 * SECTION 11 - Status queue (NEW v2.0)
 * ----------------------------------------------------------------------------
 * Backed by LF_GetStatusCount / LF_GetStatus / LF_PostStatus.
 *
 * LF_GetStatus returns a pointer to a 64KB static buffer that is
 * reused by the next call. The C++ layer copies the string
 * immediately into thread-local storage.
 *
 * LF_GetStatus and LF_PostStatus require the simulated main thread
 * to be running. They are no-ops (returning empty / 0) otherwise.
 * ========================================================================== */

int         lf_impl_get_status_count(void);          /* NEW v2.0 */
const char* lf_impl_get_status(void);                /* NEW v2.0 */
void        lf_impl_post_status(const char* text);   /* NEW v2.0 */

/* ============================================================================
 * SECTION 12 - Health checks for UID / P2PName (NEW v2.0)
 * ----------------------------------------------------------------------------
 * Each of these consults a locally cached view of the mesh that is
 * updated by periodic broadcasts. Registration and unregistration
 * propagate to this cache with a typical delay of about 3 seconds.
 * A fresh registration may therefore return 0 (false negative) for
 * a short window, and a fresh unregistration may return 1 (false
 * positive). These are probing tools, not authoritative existence
 * tests.
 * ========================================================================== */

int lf_impl_check_uid(const uint8_t* uid);           /* NEW v2.0 */
int lf_impl_check_uid_api(                           /* NEW v2.0 */
    const uint8_t* uid, const char* api_name);
int lf_impl_check_p2pname(const char* group_name);   /* NEW v2.0 */
int lf_impl_check_p2pname_api(                       /* NEW v2.0 */
    const char* group_name, const char* api_name);

/* ============================================================================
 * SECTION 13 - Process-wide P2P registration (NEW v2.0)
 * ----------------------------------------------------------------------------
 * The process-wide P2P namespace is a second registration space,
 * independent of any App. APIs registered here are reachable via
 * UID addressing and P2PName addressing without requiring the
 * caller to know the target App name. They are NOT reachable via
 * App-name addressing.
 *
 * The lifetime of a P2P registration is the process lifetime. It
 * is NOT affected by LF_FreeApp; only LF_Shutdown clears it.
 * ========================================================================== */

int lf_impl_register_p2p_call(                       /* NEW v2.0 */
    const char* api_name, const char* description,
    void* user_trigger);
int lf_impl_register_p2p_notify(                     /* NEW v2.0 */
    const char* api_name, const char* description,
    void* user_trigger);
int lf_impl_unregister_p2p(const char* api_name);    /* NEW v2.0 */

/* ============================================================================
 * SECTION 14 - Callee: job queue and trampolines (STEP 3b)
 * ----------------------------------------------------------------------------
 * Two variants of each trampoline exist:
 *
 *   call_trampoline / notify_trampoline
 *       Used for App-bound registration. The resulting Job is
 *       tagged RegistrySpace_AppBound.
 *
 *   p2p_call_trampoline / p2p_notify_trampoline
 *       Used for process-wide P2P registration. The Job is tagged
 *       RegistrySpace_P2P.
 *
 * The R side uses this tag to decide which handler table to
 * consult. Both trampolines obey the same rule: they run on a C4
 * worker thread and MUST NOT touch the R interpreter.
 * ========================================================================== */

int lf_impl_register_call_raw(
    void* app, const char* api_name, const char* description,
    void* user_trigger);

int lf_impl_register_notify_raw(
    void* app, const char* api_name, const char* description,
    void* user_trigger);

/* Dequeue the next Job.
 *
 *   timeout_ms <= 0 : return immediately (non-blocking).
 *   timeout_ms  > 0 : block up to timeout_ms waiting for a Job.
 *
 * Returns an opaque Job pointer, or NULL on timeout. The returned
 * pointer must be released with one of the *_complete or *_abandon
 * functions below, or it will leak.
 *
 * The Job is reference-counted internally. lf_impl_job_abandon and
 * lf_impl_job_complete are idempotent with each other: whichever
 * runs second observes the done flag and simply releases its own
 * reference. */
void* lf_impl_poll_job(int64_t timeout_ms);

/* Inspect the Job kind:
 *   0 = Call, 1 = Notify, 2 = AsyncResult, 3 = NetEvent
 *
 * Only kinds 0 and 1 are produced by the trampolines in this
 * section. Kinds 2 and 3 come from the async layer (Section 15)
 * and the network event layer (Section 16). */
int lf_impl_job_kind(void* job);

/* Inspect the registration space of a Call / Notify job:
 *   0 = AppBound, 1 = P2P
 *
 * For kinds 2 and 3, this returns 0. */
int lf_impl_job_registry_space(void* job);

/* Copy the input payload of a Job into buf (capacity cap).
 * Returns the number of bytes copied, or -1 on failure.
 * A short return means the caller provided an undersized buffer. */
int64_t lf_impl_job_get_input(void* job, void* buf, int64_t cap);

/* Same, but the input payload is returned without any NUL
 * stripping. Binary-mode dispatch uses this. */
int64_t lf_impl_job_get_input_size(void* job);

/* Retrieve the API name of the Job. The pointer refers to storage
 * owned by the Job and remains valid until the Job is released. */
const char* lf_impl_job_api_name(void* job);

/* Return 1 for a Call job, 0 for a Notify job. */
int lf_impl_job_is_call(void* job);

/* Side data extraction: the sender's identity as injected by the
 * framework on the sending side.
 *
 * VALID ONLY FOR Call / Notify jobs, and ONLY when the request
 * arrived over the network (or through the Send_* path of a local
 * call). Direct LF_LocalCall / LF_LocalNotify requests do not
 * populate side data.
 *
 * sender_uid is written as exactly 32 bytes; the caller must pass
 * a buffer of at least 32 bytes. Returns 1 on success, 0 if the
 * side data is unavailable for this job. */
int lf_impl_job_sender_uid_valid(void* job);
int lf_impl_job_sender_uid(void* job, void* buf, int64_t cap);

/* The sender's user-supplied P2P group name, or "" if unset.
 * The pointer is owned by the Job. */
const char* lf_impl_job_sender_p2p_name(void* job);

/* Complete a Call job by writing len bytes from buf as the
 * response, or complete a Notify job by ignoring the buffer.
 * This wakes the blocked worker thread. Idempotent with abandon. */
void lf_impl_job_complete(void* job, const void* buf, int64_t len);

/* Drop ownership of a Job without writing a response. Wakes the
 * worker and releases both references. Idempotent with complete. */
void lf_impl_job_abandon(void* job);

/* Configuration for the job queue. The default timeout is 5000 ms;
 * a value of 0 disables the timeout and makes worker threads wait
 * indefinitely. */
void    lf_impl_set_job_timeout_ms(int64_t ms);
int64_t lf_impl_pending_job_count(void);

/* ============================================================================
 * SECTION 15 - Asynchronous calls (NEW v2.0)
 * ----------------------------------------------------------------------------
 * See the file header for the full lifetime contract.
 *
 * Each function returns a positive callback_id on dispatch success
 * and 0 on dispatch failure. On success, the callback fires on a
 * C4 worker thread and its result is delivered as a Job of kind
 * AsyncResult (see lf_impl_poll_job). On failure, no callback is
 * ever installed on the C side and no AsyncResult job is produced.
 *
 * The R side must eventually call lf_impl_async_release(id) for
 * every successful dispatch, whether the result arrived, the
 * request timed out, or the R side simply lost interest.
 * ========================================================================== */

int64_t lf_impl_async_call(
    const char* app_name, const char* api_name,
    const char* payload, uint64_t timeout_ms);

int64_t lf_impl_async_sequenced_call(
    const char* app_name, const char* api_name,
    const char* payload, uint64_t timeout_ms);

int64_t lf_impl_uid_async_call(
    const uint8_t* uid, const char* api_name,
    const char* payload, uint64_t timeout_ms);

int64_t lf_impl_uid_async_sequenced_call(
    const uint8_t* uid, const char* api_name,
    const char* payload, uint64_t timeout_ms);

int64_t lf_impl_p2pname_async_call(
    const char* group_name, const char* api_name,
    const char* payload, uint64_t timeout_ms);

int64_t lf_impl_p2pname_async_sequenced_call(
    const char* group_name, const char* api_name,
    const char* payload, uint64_t timeout_ms);

/* Inspect an AsyncResult job. The callback_id matches the value
 * returned by the corresponding lf_impl_async_call*. */
int64_t lf_impl_job_callback_id(void* job);

/* The result / error strings of an AsyncResult job. Exactly one of
 * them is non-empty:
 *   - result is non-empty and error is empty  -> success
 *   - result is empty and error is non-empty  -> failure
 * The pointers are owned by the Job.
 *
 * error_kind is one of:
 *   0 = no error
 *   1 = timeout on the C side (the underlying async bridge gave up
 *       before the response arrived; this is NOT produced by the
 *       R-side timeout, which is handled entirely in R)
 *   2 = response was received but could not be delivered
 *   3 = other / unknown
 */
const char* lf_impl_job_result(void* job);
const char* lf_impl_job_error(void* job);
int         lf_impl_job_error_kind(void* job);

/* Release the R-side slot associated with an async call. Safe to
 * call multiple times; safe to call with an unknown id.
 *
 * This does NOT free the ctypes callback object. See the file
 * header for the rationale. */
void lf_impl_async_release(int64_t callback_id);

/* Diagnostic. Returns the number of slots currently tracked. */
int64_t lf_impl_async_slot_count(void);

/* ============================================================================
 * SECTION 16 - Network events (NEW v2.0)
 * ----------------------------------------------------------------------------
 * Backed by LF_Set_Network_Event. Passing NULL for either callback
 * disables that event.
 *
 * The two callbacks run on a C4 worker thread and MUST NOT touch
 * the R interpreter. Their only job is to enqueue a NetEvent Job;
 * the R side dispatches from the pump loop.
 *
 * Network event semantics (from the runtime docs):
 *   "Connect"    is NOT the TCP handshake completion. It fires the
 *                first time the client receives a service API-info
 *                broadcast, i.e. the earliest point at which
 *                remote calls can be routed.
 *   "Disconnect" fires once per physical link loss.
 * ========================================================================== */

void lf_impl_set_network_event(                      /* NEW v2.0 */
    void (*on_connect)(const char*),
    void (*on_disconnect)(const char*));

/* Inspect a NetEvent job. event_kind is "connect" or "disconnect".
 * addr is the endpoint string. Both pointers are owned by the Job. */
const char* lf_impl_job_event_kind(void* job);
const char* lf_impl_job_event_addr(void* job);

/* ============================================================================
 * SECTION 17 - Shutdown
 * ========================================================================== */

void lf_impl_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* LF_R_SHIM_H */