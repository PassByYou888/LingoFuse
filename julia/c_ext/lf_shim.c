/*
 * lf_shim.c - Implementation of the LingoFuse C callback bridge.
 *
 * See lf_shim.h for the design rationale. This file contains NO mock
 * logic. It calls the LF_* functions as extern symbols; the linker
 * resolves them from either mock_lf.c (test build) or the real
 * LingoFuse library (production build).
 *
 * Locking discipline
 * ------------------
 * The consumer NEVER touches the native data handles. The trampoline
 * snapshots the input payload into a heap buffer before pushing the
 * event, and writes the consumer's response to the output handle
 * after the consumer signals completion. This is required: a
 * consumer that accessed the handle directly would enter the real
 * LingoFuse library from a different thread than the one that owns
 * the handle, and would deadlock on the library's per-handle locks.
 *
 * Sender identity (v3)
 * --------------------
 * The Call and Notify trampolines additionally snapshot the sender's
 * UID and P2P name into the event, using the same rule: copy the
 * bytes on the trampoline thread, never let the consumer touch the
 * native handle.
 *
 * Shutdown contract
 * -----------------
 * lf_shim_shutdown() is asynchronous with respect to the
 * trampolines. It sets a process-wide g_shutdown flag and broadcasts
 * the queue condition variable. Any trampoline currently blocked in
 * wait_for_completion() will observe the flag within one timeout
 * period (100 ms) and unblock itself, then free its event.
 *
 * Because of this asynchrony, the caller MUST fully stop the
 * Julia-side consumer BEFORE calling lf_shim_shutdown().
 *
 * Re-initialisation contract
 * --------------------------
 * lf_shim_init() may be called more than once per process. The
 * second and subsequent calls reset the shutdown flag. The mutex and
 * condition variable are preserved across calls.
 *
 * Precondition: the previous consumer MUST have been fully stopped
 * before re-initialising.
 *
 * ============================================================================
 * WHY NO THREAD-LOCAL STORAGE (MIN-GW COMPATIBILITY)
 * ============================================================================
 * An earlier draft of this file used `__thread` / `__declspec(thread)`
 * to give each runtime-option getter its own thread-local buffer.
 *
 * MinGW-w64 ignores the attribute in a runtime-loaded DLL (which is
 * what every ccall-loaded shared library is). The compiler emits
 * only a `-Wattributes` warning and treats the variable as a plain
 * static, silently breaking the "thread-local" contract and, in the
 * worst case, misplacing the variable's storage.
 *
 * The current implementation therefore avoids TLS entirely:
 *
 *   - Each typed string getter owns a dedicated static buffer, so
 *     concurrent getters of DIFFERENT options never interfere.
 *
 *   - The generic lf_shim_get_option uses a mutex-protected static
 *     buffer. Concurrent callers of the SAME generic getter may
 *     observe each other's results; this is documented on the
 *     public declaration and on the getter's implementation below.
 *
 * The performance impact is negligible: the option getters are not
 * on any hot path, and the typed getters take no lock at all.
 */

#include "lf_shim.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ================================================================= */
/* Platform abstraction: mutex + condition variable                   */
/* ================================================================= */

#if defined(_WIN32)

  #include <windows.h>

  typedef CRITICAL_SECTION   lf_mutex_t;
  typedef CONDITION_VARIABLE lf_cond_t;

  static void lf_mutex_init(lf_mutex_t* m)    { InitializeCriticalSection(m); }
  static void lf_mutex_destroy(lf_mutex_t* m) { DeleteCriticalSection(m); }
  static void lf_mutex_lock(lf_mutex_t* m)    { EnterCriticalSection(m); }
  static void lf_mutex_unlock(lf_mutex_t* m)  { LeaveCriticalSection(m); }

  static void lf_cond_init(lf_cond_t* c)      { InitializeConditionVariable(c); }
  static void lf_cond_destroy(lf_cond_t* c)   { (void)c; }
  static void lf_cond_signal(lf_cond_t* c)    { WakeConditionVariable(c); }
  static void lf_cond_broadcast(lf_cond_t* c) { WakeAllConditionVariable(c); }

  static int lf_cond_wait(lf_cond_t* c, lf_mutex_t* m, int timeout_ms)
  {
      DWORD ms = (timeout_ms < 0) ? INFINITE : (DWORD)timeout_ms;
      return SleepConditionVariableCS(c, m, ms) ? 1 : 0;
  }

#else /* POSIX */

  #include <pthread.h>
  #include <time.h>
  #include <errno.h>

  typedef pthread_mutex_t lf_mutex_t;
  typedef pthread_cond_t  lf_cond_t;

  static void lf_mutex_init(lf_mutex_t* m)    { pthread_mutex_init(m, NULL); }
  static void lf_mutex_destroy(lf_mutex_t* m) { pthread_mutex_destroy(m); }
  static void lf_mutex_lock(lf_mutex_t* m)    { pthread_mutex_lock(m); }
  static void lf_mutex_unlock(lf_mutex_t* m)  { pthread_mutex_unlock(m); }

  static void lf_cond_init(lf_cond_t* c)      { pthread_cond_init(c, NULL); }
  static void lf_cond_destroy(lf_cond_t* c)   { pthread_cond_destroy(c); }
  static void lf_cond_signal(lf_cond_t* c)    { pthread_cond_signal(c); }
  static void lf_cond_broadcast(lf_cond_t* c) { pthread_cond_broadcast(c); }

  static int lf_cond_wait(lf_cond_t* c, lf_mutex_t* m, int timeout_ms)
  {
      if (timeout_ms < 0) {
          return pthread_cond_wait(c, m) == 0 ? 1 : 0;
      }
      struct timespec ts;
      clock_gettime(CLOCK_REALTIME, &ts);
      ts.tv_sec  += timeout_ms / 1000;
      ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
      if (ts.tv_nsec >= 1000000000L) {
          ts.tv_sec += 1;
          ts.tv_nsec -= 1000000000L;
      }
      int rc = pthread_cond_timedwait(c, m, &ts);
      return rc == 0 ? 1 : 0;
  }

#endif /* _WIN32 */

/* ================================================================= */
/* External LingoFuse functions                                       */
/* ================================================================= */

typedef void (*lf_call_cb_t)(void*, void*, void*);
typedef void (*lf_notify_cb_t)(void*, void*);
typedef void (*lf_net_cb_t)(const char*);
typedef void (*lf_async_cb_t)(void*, void*);

/* ---- Registration ---- */

extern int LF_RegisterCall(
    void* app, const char* name, const char* desc,
    void* trigger, lf_call_cb_t cb);

extern int LF_RegisterNotify(
    void* app, const char* name, const char* desc,
    void* trigger, lf_notify_cb_t cb);

extern int LF_Register_P2P_Call(
    const char* name, const char* desc,
    void* trigger, lf_call_cb_t cb);

extern int LF_Register_P2P_Notify(
    const char* name, const char* desc,
    void* trigger, lf_notify_cb_t cb);

extern int LF_Unregister_P2P(const char* name);

extern void LF_Set_Network_Event(
    lf_net_cb_t on_connect, lf_net_cb_t on_disconnect);

/* ---- Data handle accessors ---- */

extern int64_t LF_GetSize(void* hnd);
extern void    LF_SetPos(void* hnd, int64_t pos);
extern int64_t LF_ReadBuffer(void* hnd, void* buff, int64_t size);
extern int64_t LF_WriteBuffer(void* hnd, const void* buff, int64_t size);

/* ---- Sender identity (v3) ----
 *
 * Both functions return pointers that the Pascal side schedules for
 * release ~5 seconds after the call. The shim MUST copy the bytes
 * immediately and MUST NOT free the pointers.
 */

extern lf_shim_uid_t* LF_Get_P2P_UID(void* hnd);
extern const char*    LF_Get_P2P_Name(void* hnd);

/* ---- Async dispatch ---- */

extern int LF_Async_Call(
    const char* app, void* param, void* data, lf_async_cb_t cb);

extern int LF_Async_Sequenced_Call(
    const char* app, void* param, void* data, lf_async_cb_t cb);

extern int LF_UID_Async_Call(
    lf_shim_uid_t uid, void* param, void* data, lf_async_cb_t cb);

extern int LF_UID_Async_Sequenced_Call(
    lf_shim_uid_t uid, void* param, void* data, lf_async_cb_t cb);

extern int LF_P2PNAME_Async_Call(
    const char* group, void* param, void* data, lf_async_cb_t cb);

extern int LF_P2PNAME_Async_Sequenced_Call(
    const char* group, void* param, void* data, lf_async_cb_t cb);

/* ---- Runtime options ---- */

extern void        LF_SetOption(const char* name, const char* value);
extern const char* LF_GetOption(const char* name);

/* ================================================================= */
/* Allocation-failure diagnostic                                      */
/* ================================================================= */

static int g_alloc_warned = 0;

static void warn_alloc_failure(const char* what)
{
    if (g_alloc_warned) return;
    g_alloc_warned = 1;
    fprintf(stderr,
            "lf_shim: allocation failure in %s; "
            "one or more callbacks may return empty results\n",
            what);
}

/* ================================================================= */
/* Event structure                                                    */
/* ================================================================= */

struct lf_shim_event {
    int             kind;
    int64_t         user_id;

    /* Snapshot of the input payload. Owned by the event. Filled by
     * the trampoline before the event is queued; read by the
     * consumer without touching any native handle. */
    void*           input_data;
    size_t          input_len;

    /* Response bytes supplied by the consumer via lf_shim_set_output. */
    void*           output_data;
    size_t          output_len;

    /* Snapshot of the async result payload. */
    void*           result_data;
    size_t          result_len;

    /* Sender identity (v3). Filled only for CALL / NOTIFY events. */
    uint8_t         from_uid[32];
    char*           from_p2p_name;

    /* Borrowed from LingoFuse. Valid only on the trampoline thread
     * for the duration of the callback. The consumer never touches
     * these. */
    void*           trigger;
    void*           input;
    void*           output;

    /* Owned copy of the network event address (NULL for other kinds). */
    char*           addr;

    /* Synchronisation: the trampoline waits on this, the consumer
     * signals it via lf_shim_complete_event. */
    lf_mutex_t      mtx;
    lf_cond_t       cv;
    int             done;

    /* Queue linkage. */
    struct lf_shim_event* next;
};

static lf_shim_event_t* event_alloc(int kind, int64_t user_id)
{
    lf_shim_event_t* e = (lf_shim_event_t*)calloc(1, sizeof(*e));
    if (!e) {
        warn_alloc_failure("event_alloc");
        return NULL;
    }

    e->kind        = kind;
    e->user_id     = user_id;
    e->input_data  = NULL;
    e->input_len   = 0;
    e->output_data = NULL;
    e->output_len  = 0;
    e->result_data = NULL;
    e->result_len  = 0;
    e->from_p2p_name = NULL;
    e->done        = 0;
    e->next        = NULL;

    lf_mutex_init(&e->mtx);
    lf_cond_init(&e->cv);
    return e;
}

static void event_free(lf_shim_event_t* e)
{
    if (!e) return;
    lf_mutex_destroy(&e->mtx);
    lf_cond_destroy(&e->cv);
    if (e->input_data)    free(e->input_data);
    if (e->output_data)   free(e->output_data);
    if (e->result_data)   free(e->result_data);
    if (e->from_p2p_name) free(e->from_p2p_name);
    if (e->addr)          free(e->addr);
    free(e);
}

/* ================================================================= */
/* Queue                                                              */
/* ================================================================= */

static lf_mutex_t       g_queue_mtx;
static lf_cond_t        g_queue_cv;
static lf_shim_event_t* g_head         = NULL;
static lf_shim_event_t* g_tail         = NULL;
static volatile int     g_shutdown     = 0;
static int              g_initialised  = 0;

LF_SHIM_API int lf_shim_init(void)
{
    if (g_initialised) {
        lf_mutex_lock(&g_queue_mtx);
        g_shutdown = 0;
        lf_cond_broadcast(&g_queue_cv);
        lf_mutex_unlock(&g_queue_mtx);
        return 1;
    }

    lf_mutex_init(&g_queue_mtx);
    lf_cond_init(&g_queue_cv);
    g_head = g_tail = NULL;
    g_shutdown = 0;
    g_initialised = 1;
    return 1;
}

LF_SHIM_API void lf_shim_shutdown(void)
{
    if (!g_initialised) return;

    lf_mutex_lock(&g_queue_mtx);
    g_shutdown = 1;
    lf_cond_broadcast(&g_queue_cv);
    lf_mutex_unlock(&g_queue_mtx);
}

static void queue_push(lf_shim_event_t* e)
{
    lf_mutex_lock(&g_queue_mtx);
    e->next = NULL;
    if (g_tail) {
        g_tail->next = e;
        g_tail = e;
    } else {
        g_head = g_tail = e;
    }
    lf_cond_signal(&g_queue_cv);
    lf_mutex_unlock(&g_queue_mtx);
}

LF_SHIM_API lf_shim_event_t* lf_shim_wait_event(int timeout_ms)
{
    lf_mutex_lock(&g_queue_mtx);

    while (g_head == NULL && !g_shutdown) {
        if (!lf_cond_wait(&g_queue_cv, &g_queue_mtx, timeout_ms)) {
            lf_mutex_unlock(&g_queue_mtx);
            return NULL;
        }
    }

    if (g_head == NULL) {
        lf_mutex_unlock(&g_queue_mtx);
        return NULL;
    }

    lf_shim_event_t* e = g_head;
    g_head = e->next;
    if (g_head == NULL) g_tail = NULL;
    e->next = NULL;

    lf_mutex_unlock(&g_queue_mtx);
    return e;
}

/* ================================================================= */
/* Payload snapshot                                                   */
/* ================================================================= */

static void snapshot_handle(void* hnd, void** out_data, size_t* out_len)
{
    if (!hnd) return;

    LF_SetPos(hnd, 0);
    int64_t sz = LF_GetSize(hnd);
    if (sz <= 0) return;

    void* buf = malloc((size_t)sz);
    if (!buf) {
        warn_alloc_failure("snapshot_handle");
        return;
    }

    int64_t got = LF_ReadBuffer(hnd, buf, sz);
    if (got > 0) {
        *out_data = buf;
        *out_len  = (size_t)got;
    } else {
        free(buf);
    }
}

static void snapshot_input(lf_shim_event_t* e)
{
    snapshot_handle(e->input, &e->input_data, &e->input_len);
}

static void snapshot_result(lf_shim_event_t* e, void* result_hnd)
{
    snapshot_handle(result_hnd, &e->result_data, &e->result_len);
}

/* Snapshot the sender's UID and P2P name from a native input handle.
 * Called only from the Call and Notify trampolines. The underlying
 * Pascal-side functions return pointers with a ~5 second scheduled
 * lifetime; the shim copies the bytes now and never touches the
 * pointers again. */
static void snapshot_sender(lf_shim_event_t* e, void* input_hnd)
{
    if (!e || !input_hnd) return;

    lf_shim_uid_t* uid_ptr = LF_Get_P2P_UID(input_hnd);
    if (uid_ptr) {
        memcpy(e->from_uid, uid_ptr->bytes, 32);
    }

    const char* name_ptr = LF_Get_P2P_Name(input_hnd);
    if (name_ptr && name_ptr[0] != '\0') {
        size_t n = strlen(name_ptr);
        e->from_p2p_name = (char*)malloc(n + 1);
        if (e->from_p2p_name) {
            memcpy(e->from_p2p_name, name_ptr, n + 1);
        } else {
            warn_alloc_failure("snapshot_sender(from_p2p_name)");
        }
    }
}

/* ================================================================= */
/* Trampolines                                                        */
/* ================================================================= */

static void wait_for_completion(lf_shim_event_t* e)
{
    lf_mutex_lock(&e->mtx);
    while (!e->done) {
        if (g_shutdown) break;
        lf_cond_wait(&e->cv, &e->mtx, 100);
    }
    e->done = 1;
    lf_mutex_unlock(&e->mtx);
}

static void shim_call_trampoline(void* trigger, void* input, void* output)
{
    int64_t uid = (int64_t)(intptr_t)trigger;

    lf_shim_event_t* e = event_alloc(LF_SHIM_EVENT_CALL, uid);
    if (!e) return;

    e->trigger = trigger;
    e->input   = input;
    e->output  = output;

    snapshot_input(e);
    snapshot_sender(e, input);

    queue_push(e);
    wait_for_completion(e);

    if (e->output && e->output_data && e->output_len > 0) {
        LF_SetPos(e->output, 0);
        LF_WriteBuffer(e->output, e->output_data, (int64_t)e->output_len);
    }

    event_free(e);
}

static void shim_notify_trampoline(void* trigger, void* input)
{
    int64_t uid = (int64_t)(intptr_t)trigger;

    lf_shim_event_t* e = event_alloc(LF_SHIM_EVENT_NOTIFY, uid);
    if (!e) return;

    e->trigger = trigger;
    e->input   = input;
    e->output  = NULL;

    snapshot_input(e);
    snapshot_sender(e, input);

    queue_push(e);
    wait_for_completion(e);
    event_free(e);
}

static void shim_async_result_trampoline(void* data, void* result)
{
    int64_t uid = (int64_t)(intptr_t)data;

    lf_shim_event_t* e = event_alloc(LF_SHIM_EVENT_ASYNC_RESULT, uid);
    if (!e) return;

    e->trigger = data;
    e->input   = NULL;
    e->output  = NULL;

    snapshot_result(e, result);

    queue_push(e);
    wait_for_completion(e);
    event_free(e);
}

/* ---- Network event trampolines ---- */

static int64_t g_connect_uid    = 0;
static int64_t g_disconnect_uid = 0;

static lf_shim_event_t* make_network_event(int kind, int64_t uid, const char* addr)
{
    lf_shim_event_t* e = event_alloc(kind, uid);
    if (!e) return NULL;

    if (addr) {
        size_t n = strlen(addr);
        e->addr = (char*)malloc(n + 1);
        if (e->addr) {
            memcpy(e->addr, addr, n + 1);
        } else {
            warn_alloc_failure("make_network_event(addr)");
        }
    }
    return e;
}

static void shim_network_connect_trampoline(const char* addr)
{
    lf_shim_event_t* e = make_network_event(
        LF_SHIM_EVENT_NETWORK_CONNECT, g_connect_uid, addr);
    if (!e) return;

    queue_push(e);
    wait_for_completion(e);
    event_free(e);
}

static void shim_network_disconnect_trampoline(const char* addr)
{
    lf_shim_event_t* e = make_network_event(
        LF_SHIM_EVENT_NETWORK_DISCONNECT, g_disconnect_uid, addr);
    if (!e) return;

    queue_push(e);
    wait_for_completion(e);
    event_free(e);
}

/* ================================================================= */
/* Public registration API: App-bound                                 */
/* ================================================================= */

LF_SHIM_API int lf_shim_register_call(void* app, const char* name,
                                      const char* desc, int64_t user_id)
{
    return LF_RegisterCall(
        app, name, desc,
        (void*)(intptr_t)user_id,
        shim_call_trampoline);
}

LF_SHIM_API int lf_shim_register_notify(void* app, const char* name,
                                        const char* desc, int64_t user_id)
{
    return LF_RegisterNotify(
        app, name, desc,
        (void*)(intptr_t)user_id,
        shim_notify_trampoline);
}

/* ================================================================= */
/* Public registration API: process-wide P2P                          */
/* ================================================================= */

LF_SHIM_API int lf_shim_register_p2p_call(const char* name,
                                          const char* desc,
                                          int64_t user_id)
{
    return LF_Register_P2P_Call(
        name, desc,
        (void*)(intptr_t)user_id,
        shim_call_trampoline);
}

LF_SHIM_API int lf_shim_register_p2p_notify(const char* name,
                                            const char* desc,
                                            int64_t user_id)
{
    return LF_Register_P2P_Notify(
        name, desc,
        (void*)(intptr_t)user_id,
        shim_notify_trampoline);
}

LF_SHIM_API int lf_shim_unregister_p2p(const char* name)
{
    return LF_Unregister_P2P(name);
}

/* ================================================================= */
/* Network events                                                     */
/* ================================================================= */

LF_SHIM_API void lf_shim_install_network_events(int64_t connect_uid,
                                                int64_t disconnect_uid)
{
    g_connect_uid    = connect_uid;
    g_disconnect_uid = disconnect_uid;
    LF_Set_Network_Event(shim_network_connect_trampoline,
                         shim_network_disconnect_trampoline);
}

LF_SHIM_API void lf_shim_clear_network_events(void)
{
    LF_Set_Network_Event(NULL, NULL);
    g_connect_uid    = 0;
    g_disconnect_uid = 0;
}

/* ================================================================= */
/* Async calls                                                        */
/* ================================================================= */

LF_SHIM_API int lf_shim_async_call(const char* app_name,
                                   void*       param_hnd,
                                   int64_t     user_token)
{
    if (!app_name || !param_hnd) return 0;
    return LF_Async_Call(
        app_name, param_hnd,
        (void*)(intptr_t)user_token,
        shim_async_result_trampoline);
}

LF_SHIM_API int lf_shim_async_sequenced_call(const char* app_name,
                                             void*       param_hnd,
                                             int64_t     user_token)
{
    if (!app_name || !param_hnd) return 0;
    return LF_Async_Sequenced_Call(
        app_name, param_hnd,
        (void*)(intptr_t)user_token,
        shim_async_result_trampoline);
}

LF_SHIM_API int lf_shim_uid_async_call(const lf_shim_uid_t* uid,
                                       void*                 param_hnd,
                                       int64_t               user_token)
{
    if (!uid || !param_hnd) return 0;
    return LF_UID_Async_Call(
        *uid, param_hnd,
        (void*)(intptr_t)user_token,
        shim_async_result_trampoline);
}

LF_SHIM_API int lf_shim_uid_async_sequenced_call(const lf_shim_uid_t* uid,
                                                 void*                 param_hnd,
                                                 int64_t               user_token)
{
    if (!uid || !param_hnd) return 0;
    return LF_UID_Async_Sequenced_Call(
        *uid, param_hnd,
        (void*)(intptr_t)user_token,
        shim_async_result_trampoline);
}

LF_SHIM_API int lf_shim_p2pname_async_call(const char* group_name,
                                           void*       param_hnd,
                                           int64_t     user_token)
{
    if (!group_name || !param_hnd) return 0;
    return LF_P2PNAME_Async_Call(
        group_name, param_hnd,
        (void*)(intptr_t)user_token,
        shim_async_result_trampoline);
}

LF_SHIM_API int lf_shim_p2pname_async_sequenced_call(const char* group_name,
                                                     void*       param_hnd,
                                                     int64_t     user_token)
{
    if (!group_name || !param_hnd) return 0;
    return LF_P2PNAME_Async_Sequenced_Call(
        group_name, param_hnd,
        (void*)(intptr_t)user_token,
        shim_async_result_trampoline);
}

/* ================================================================= */
/* Consumer API                                                       */
/* ================================================================= */

LF_SHIM_API int lf_shim_event_kind(const lf_shim_event_t* e)
{
    return e ? e->kind : -1;
}

LF_SHIM_API int64_t lf_shim_event_user_id(const lf_shim_event_t* e)
{
    return e ? e->user_id : 0;
}

LF_SHIM_API void* lf_shim_event_input(const lf_shim_event_t* e)
{
    return e ? e->input : NULL;
}

LF_SHIM_API void* lf_shim_event_output(const lf_shim_event_t* e)
{
    return e ? e->output : NULL;
}

LF_SHIM_API const char* lf_shim_event_addr(const lf_shim_event_t* e)
{
    return e ? e->addr : NULL;
}

LF_SHIM_API const uint8_t* lf_shim_event_from_uid(const lf_shim_event_t* e)
{
    return e ? e->from_uid : NULL;
}

LF_SHIM_API const char* lf_shim_event_from_p2p_name(const lf_shim_event_t* e)
{
    return e ? e->from_p2p_name : NULL;
}

LF_SHIM_API const void* lf_shim_event_input_data(const lf_shim_event_t* e)
{
    return e ? e->input_data : NULL;
}

LF_SHIM_API size_t lf_shim_event_input_len(const lf_shim_event_t* e)
{
    return e ? e->input_len : 0;
}

LF_SHIM_API const void* lf_shim_event_result_data(const lf_shim_event_t* e)
{
    return e ? e->result_data : NULL;
}

LF_SHIM_API size_t lf_shim_event_result_len(const lf_shim_event_t* e)
{
    return e ? e->result_len : 0;
}

LF_SHIM_API int lf_shim_set_output(lf_shim_event_t* e,
                                   const void*      data,
                                   size_t           len)
{
    if (!e) return 0;

    if (e->output_data) {
        free(e->output_data);
        e->output_data = NULL;
        e->output_len  = 0;
    }

    if (len == 0) return 1;
    if (!data)    return 0;

    e->output_data = malloc(len);
    if (!e->output_data) {
        warn_alloc_failure("lf_shim_set_output");
        return 0;
    }

    memcpy(e->output_data, data, len);
    e->output_len = len;
    return 1;
}

LF_SHIM_API void lf_shim_complete_event(lf_shim_event_t* e)
{
    if (!e) return;
    lf_mutex_lock(&e->mtx);
    e->done = 1;
    lf_cond_signal(&e->cv);
    lf_mutex_unlock(&e->mtx);
    /* The trampoline owns the event and will free it after waking up. */
}

/* ================================================================= */
/* Runtime options                                                    */
/* ================================================================= */
/*
 * Each typed string getter owns a dedicated static buffer, so
 * concurrent getters of DIFFERENT options never interfere.
 *
 * The generic lf_shim_get_option uses a mutex-protected static
 * buffer. Two concurrent callers of the generic getter may overwrite
 * each other's results; the returned pointer is only valid until the
 * next call to the generic getter on ANY thread. This limitation is
 * documented on the public declaration and is acceptable because the
 * generic getter is a fallback for dynamic option names, not the
 * primary access path.
 *
 * No thread-local storage is used; see the file header.
 */

#define LF_OPT_BUF_SIZE 512

static char g_opt_buf_password[LF_OPT_BUF_SIZE];
static char g_opt_buf_debug[LF_OPT_BUF_SIZE];
static char g_opt_buf_p2p_name[LF_OPT_BUF_SIZE];

static lf_mutex_t g_opt_generic_mtx;
static char       g_opt_buf_generic[LF_OPT_BUF_SIZE];
static int        g_opt_generic_mtx_init = 0;

static void lf_opt_generic_mtx_ensure(void)
{
    if (g_opt_generic_mtx_init) return;
    lf_mutex_init(&g_opt_generic_mtx);
    g_opt_generic_mtx_init = 1;
}

/* ---- Internal helpers ---- */

static const char* copy_opt_into(const char* name,
                                 char*       buf,
                                 size_t      buf_size)
{
    if (!buf || buf_size == 0) return "";
    const char* v = LF_GetOption(name);
    if (!v) v = "";
    size_t n = strlen(v);
    if (n >= buf_size) n = buf_size - 1;
    memcpy(buf, v, n);
    buf[n] = '\0';
    return buf;
}

static void lf_set_opt_str(const char* name, const char* value)
{
    if (!name) return;
    if (!value) value = "";
    LF_SetOption(name, value);
}

static void lf_set_opt_bool(const char* name, int value)
{
    lf_set_opt_str(name, value ? "True" : "False");
}

static void lf_set_opt_int(const char* name, int value)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", value);
    lf_set_opt_str(name, buf);
}

static void lf_set_opt_u64(const char* name, uint64_t value)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)value);
    lf_set_opt_str(name, buf);
}

static int lf_get_opt_bool(const char* name)
{
    const char* v = LF_GetOption(name);
    if (!v || !*v) return 0;
    if (v[0] == 'T' || v[0] == 't') {
        if ((v[1] == 'r' || v[1] == 'R') &&
            (v[2] == 'u' || v[2] == 'U') &&
            (v[3] == 'e' || v[3] == 'E'))
            return 1;
    }
    return 0;
}

static int64_t lf_get_opt_i64(const char* name)
{
    const char* v = LF_GetOption(name);
    if (!v || !*v) return 0;
    return (int64_t)strtoll(v, NULL, 10);
}

static uint64_t lf_get_opt_u64(const char* name)
{
    const char* v = LF_GetOption(name);
    if (!v || !*v) return 0;
    return (uint64_t)strtoull(v, NULL, 10);
}

/* ---- Authentication ---- */

LF_SHIM_API void lf_shim_set_opt_password(const char* value)
{
    lf_set_opt_str("password", value);
}

LF_SHIM_API const char* lf_shim_get_opt_password(void)
{
    return copy_opt_into("password", g_opt_buf_password, LF_OPT_BUF_SIZE);
}

/* ---- Logging and diagnostics ---- */

LF_SHIM_API void lf_shim_set_opt_debug(const char* value)
{
    lf_set_opt_str("debug", value);
}

LF_SHIM_API const char* lf_shim_get_opt_debug(void)
{
    return copy_opt_into("debug", g_opt_buf_debug, LF_OPT_BUF_SIZE);
}

LF_SHIM_API void lf_shim_set_opt_quiet(int value)
{
    lf_set_opt_bool("Quiet", value);
}

LF_SHIM_API int lf_shim_get_opt_quiet(void)
{
    return lf_get_opt_bool("Quiet");
}

LF_SHIM_API void lf_shim_set_opt_show_thread_id(int value)
{
    lf_set_opt_bool("ShowThreadID", value);
}

LF_SHIM_API int lf_shim_get_opt_show_thread_id(void)
{
    return lf_get_opt_bool("ShowThreadID");
}

LF_SHIM_API void lf_shim_set_opt_console_output(int value)
{
    lf_set_opt_bool("ConsoleOutput", value);
}

LF_SHIM_API int lf_shim_get_opt_console_output(void)
{
    return lf_get_opt_bool("ConsoleOutput");
}

/* ---- Connection readiness ---- */

LF_SHIM_API void lf_shim_set_opt_overlap_connection(int value)
{
    lf_set_opt_bool("Overlap_Connection", value);
}

LF_SHIM_API int lf_shim_get_opt_overlap_connection(void)
{
    return lf_get_opt_bool("Overlap_Connection");
}

LF_SHIM_API void lf_shim_set_opt_wait_connection_ready_ok(int value)
{
    lf_set_opt_bool("Wait_Connection_ReadyOk", value);
}

LF_SHIM_API int lf_shim_get_opt_wait_connection_ready_ok(void)
{
    return lf_get_opt_bool("Wait_Connection_ReadyOk");
}

LF_SHIM_API void lf_shim_set_opt_wait_connection_timeout(uint64_t value_ms)
{
    lf_set_opt_u64("Wait_Connection_Timeout", value_ms);
}

LF_SHIM_API uint64_t lf_shim_get_opt_wait_connection_timeout(void)
{
    return lf_get_opt_u64("Wait_Connection_Timeout");
}

/* ---- IPC ---- */

LF_SHIM_API void lf_shim_set_opt_ipc_serv_thread_count(int value)
{
    lf_set_opt_int("IPC_Serv_ThreadCount", value);
}

LF_SHIM_API int lf_shim_get_opt_ipc_serv_thread_count(void)
{
    return (int)lf_get_opt_i64("IPC_Serv_ThreadCount");
}

LF_SHIM_API void lf_shim_set_opt_ipc_serv_max_queue_length(int value)
{
    lf_set_opt_int("IPC_Serv_MaxQueueLength", value);
}

LF_SHIM_API int lf_shim_get_opt_ipc_serv_max_queue_length(void)
{
    return (int)lf_get_opt_i64("IPC_Serv_MaxQueueLength");
}

LF_SHIM_API void lf_shim_set_opt_ipc_serv_max_msg_size(int value)
{
    lf_set_opt_int("IPC_Serv_MaxMsgSize", value);
}

LF_SHIM_API int lf_shim_get_opt_ipc_serv_max_msg_size(void)
{
    return (int)lf_get_opt_i64("IPC_Serv_MaxMsgSize");
}

/* ---- Sequenced notifications ---- */

LF_SHIM_API void lf_shim_set_opt_fixed_sequenced_time(uint64_t value_ms)
{
    lf_set_opt_u64("Fixed_Sequenced_Time", value_ms);
}

LF_SHIM_API uint64_t lf_shim_get_opt_fixed_sequenced_time(void)
{
    return lf_get_opt_u64("Fixed_Sequenced_Time");
}

/* ---- P2P group name ---- */

LF_SHIM_API void lf_shim_set_opt_p2p_name(const char* value)
{
    lf_set_opt_str("LF_P2P_name", value);
}

LF_SHIM_API const char* lf_shim_get_opt_p2p_name(void)
{
    return copy_opt_into("LF_P2P_name", g_opt_buf_p2p_name, LF_OPT_BUF_SIZE);
}

/* ---- Data handle pool ---- */

LF_SHIM_API void lf_shim_set_opt_data_handle_idle_timeout(uint64_t value_ms)
{
    lf_set_opt_u64("DataHandle_Idle_Timeout", value_ms);
}

LF_SHIM_API uint64_t lf_shim_get_opt_data_handle_idle_timeout(void)
{
    return lf_get_opt_u64("DataHandle_Idle_Timeout");
}

LF_SHIM_API void lf_shim_set_opt_data_handle_pool_scan_interval(uint64_t value_ms)
{
    lf_set_opt_u64("DataHandle_Pool_Scan_Interval", value_ms);
}

LF_SHIM_API uint64_t lf_shim_get_opt_data_handle_pool_scan_interval(void)
{
    return lf_get_opt_u64("DataHandle_Pool_Scan_Interval");
}

/* ---- Command flushing ---- */

LF_SHIM_API void lf_shim_set_opt_no_reponse_cmd_null_flush_threshold(int value)
{
    lf_set_opt_int("No_Reponse_Cmd_NULL_Flush_Threshold", value);
}

LF_SHIM_API int lf_shim_get_opt_no_reponse_cmd_null_flush_threshold(void)
{
    return (int)lf_get_opt_i64("No_Reponse_Cmd_NULL_Flush_Threshold");
}

/* ---- Generic (dynamic option names) ---- */

LF_SHIM_API void lf_shim_set_option(const char* name, const char* value)
{
    lf_set_opt_str(name, value);
}

LF_SHIM_API const char* lf_shim_get_option(const char* name)
{
    lf_opt_generic_mtx_ensure();
    lf_mutex_lock(&g_opt_generic_mtx);
    const char* result = copy_opt_into(name, g_opt_buf_generic, LF_OPT_BUF_SIZE);
    lf_mutex_unlock(&g_opt_generic_mtx);
    return result;
}