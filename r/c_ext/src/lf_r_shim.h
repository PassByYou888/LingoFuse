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
 * ========================================================================== */

#ifndef LF_R_SHIM_H
#define LF_R_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * STEP 1: build chain probes
 * ------------------------------------------------------------------------ */

const char* lf_impl_ping(void);
const char* lf_impl_version(void);
const char* lf_impl_stage(void);
const char* lf_impl_compiled(void);

/* ---------------------------------------------------------------------------
 * STEP 2: runtime loading
 * ------------------------------------------------------------------------ */

int         lf_impl_load_library(const char* runtime_dir);
void        lf_impl_unload_library(void);
int         lf_impl_is_loaded(void);
const char* lf_impl_loaded_path(void);
const char* lf_impl_last_error(void);

/* ---------------------------------------------------------------------------
 * STEP 2: DataHandle
 * ------------------------------------------------------------------------ */

void*   lf_impl_data_create(const char* api_name);
void*   lf_impl_data_create_permanent(const char* api_name);
void    lf_impl_data_free(void* hnd);
int64_t lf_impl_data_write_buffer(void* hnd, const void* buf, int64_t len);
int64_t lf_impl_data_read_buffer(void* hnd, void* buf, int64_t len);
int64_t lf_impl_data_get_pos(void* hnd);
int     lf_impl_data_set_pos(void* hnd, int64_t pos);
int64_t lf_impl_data_get_size(void* hnd);
void*   lf_impl_data_get_buffer(void* hnd);

/* ---------------------------------------------------------------------------
 * STEP 2: AppHandle
 * ------------------------------------------------------------------------ */

void*       lf_impl_app_create(const char* name, const char* description);
void        lf_impl_app_free(void* app);
const char* lf_impl_app_name(void* app);

/* ---------------------------------------------------------------------------
 * STEP 3a: network preparation (caller)
 * ------------------------------------------------------------------------ */

int  lf_impl_reset_prepare(void);
int  lf_impl_prepare_client(const char* endpoint);
/* Prepare a client connection that also exposes `app` on the mesh.
 *
 * `app` must be a pointer previously returned by lf_impl_app_create.
 * Passing NULL is equivalent to lf_impl_prepare_client(endpoint). */
int  lf_impl_prepare_client_with_app(const char* endpoint, void* app);
int  lf_impl_prepare_service(const char* listen_addr, const char* physics_addr);
int  lf_impl_prepare_done(void);
void lf_impl_exit_main_thread(void);
int  lf_impl_check_main_thread(void);
int  lf_impl_check_app(const char* app_name);
int  lf_impl_check_api(const char* app_name, const char* api_name);

/* ---------------------------------------------------------------------------
 * STEP 3a: remote invocation (caller)
 * ------------------------------------------------------------------------ */

const char* lf_impl_call(
    const char* app_name, const char* api_name, const char* payload,
    uint64_t timeout_ms, int64_t* out_len);

int lf_impl_notify(
    const char* app_name, const char* api_name, const char* payload);

int lf_impl_sequenced_notify(
    const char* app_name, const char* api_name, const char* payload);

/* Binary variants of call / notify. The request and response are raw
 * bytes; no NUL terminator is added or stripped.
 *
 * lf_impl_call_bin returns a pointer to thread-local storage owned by
 * the C++ layer, valid until the next lf_impl_call_bin on the same
 * thread. `out_len` receives the response byte count. Returns NULL on
 * failure. */
const char* lf_impl_call_bin(
    const char* app_name, const char* api_name,
    const void* req, int64_t req_len,
    uint64_t timeout_ms, int64_t* out_len);

int lf_impl_notify_bin(
    const char* app_name, const char* api_name,
    const void* req, int64_t req_len);

void lf_impl_shutdown(void);
void lf_impl_set_option(const char* name, const char* value);

/* ---------------------------------------------------------------------------
 * STEP 3b: callee (server side)
 * ---------------------------------------------------------------------------
 * R registers a raw cdecl callback through lf_impl_register_call_raw /
 * lf_impl_register_notify_raw. The trampoline runs on a C4 worker
 * thread. It must NEVER touch the R interpreter. Its only job is to
 * copy the input bytes and enqueue a Job.
 *
 * The R main thread retrieves Jobs through lf_impl_poll_job, invokes
 * the user R function, and returns the result via lf_impl_job_complete.
 *
 * Job lifetime:
 *   - Allocated by lf_impl_poll_job.
 *   - Freed by lf_impl_job_complete (the same call that wakes the
 *     worker thread). After completion the Job handle is invalid.
 *   - If a Job times out on the worker side (see
 *     lf_impl_set_job_timeout_ms), the worker unblocks itself and the
 *     Job is marked "already done". A later lf_impl_job_complete on
 *     that Job is a silent no-op.
 * ------------------------------------------------------------------------ */

/* Install a Call API on the app.
 *
 * The callback trampoline is a C++-layer internal detail; the caller
 * does not pass a function pointer. `user_trigger` is accepted for
 * interface symmetry and is currently ignored.
 *
 * Returns 1 on success, 0 on failure. */
int lf_impl_register_call_raw(
    void* app, const char* api_name, const char* description,
    void* user_trigger);

/* Install a Notify API on the app.
 *
 * Same contract as lf_impl_register_call_raw. */
int lf_impl_register_notify_raw(
    void* app, const char* api_name, const char* description,
    void* user_trigger);

/* Non-blocking dequeue of the next Job.
 *
 *   timeout_ms <= 0 : return immediately (non-blocking).
 *   timeout_ms  > 0 : block up to timeout_ms waiting for a Job.
 *
 * Returns an opaque Job pointer, or NULL on timeout.
 * The returned pointer must be passed to lf_impl_job_complete. */
void* lf_impl_poll_job(int64_t timeout_ms);

/* Copy the input payload of a Job into `buf` (capacity `cap`).
 * Returns the number of bytes copied, or -1 on failure.
 * A short return means the caller provided an undersized buffer. */
int64_t lf_impl_job_get_input(void* job, void* buf, int64_t cap);

/* Copy the input payload length of a Job without copying the bytes.
 * Returns the length in bytes, or -1 on failure. */
int64_t lf_impl_job_input_size(void* job);

/* Retrieve the API name of the Job. Returns a pointer to static
 * storage valid until the next call to this function on the same
 * thread, or NULL on failure. */
const char* lf_impl_job_api_name(void* job);

/* Return 1 for a Call job, 0 for a Notify job. */
int lf_impl_job_is_call(void* job);

/* Complete a Call job by writing `len` bytes from `buf` as the
 * response, or complete a Notify job by ignoring the buffer.
 * This is the call that wakes the blocked worker thread.
 * After completion the Job handle is invalid. Idempotent: completing
 * an already-timed-out Job is a silent no-op. */
void lf_impl_job_complete(void* job, const void* buf, int64_t len);

/* Drop ownership of a Job without writing a response.
 *
 * Use this when the R side will never call lf_impl_job_complete for
 * the Job -- for example, when the externalptr is finalised by the
 * R garbage collector, or when the R handler raised an exception
 * that was not caught. The worker is woken up so that it does not
 * block until its timeout, and both references are released.
 *
 * Idempotent with lf_impl_job_complete: whichever of the two is
 * called second observes the `done` flag and simply releases its
 * own reference. */
void lf_impl_job_abandon(void* job);

/* Install or replace the process-wide network event handlers.
 * Both callbacks follow the same rule as the API callbacks: they run
 * on a worker thread and must not touch R. The R layer will normally
 * not use these; they exist so that a future revision can pump them
 * through the same job queue. Passing NULL for either argument
 * disables that event. */
void lf_impl_set_network_event(
    void (*on_connect)(const char*),
    void (*on_disconnect)(const char*));

/* Set the maximum time a worker thread will wait for the R main thread
 * to complete a Job, in milliseconds. 0 means wait forever. The
 * default is 5000 ms. */
void lf_impl_set_job_timeout_ms(int64_t ms);

/* Return the number of Jobs currently pending in the queue.
 * Diagnostic only; not used by the R layer's hot path. */
int64_t lf_impl_pending_job_count(void);

#ifdef __cplusplus
}
#endif

#endif /* LF_R_SHIM_H */