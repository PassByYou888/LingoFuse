/*
 * lf_shim.c - Implementation of the LingoFuse C callback bridge.
 *
 * See lf_shim.h for the design rationale.
 *
 * This file contains NO mock logic. It calls the LF_* functions as
 * extern symbols; the linker resolves them from either mock_lf.c
 * (test build) or the real LingoFuse library (production build).
 *
 * Locking discipline
 * ------------------
 * The consumer NEVER touches the native data handles. The trampoline
 * snapshots the input payload into a heap buffer before pushing the
 * event, and writes the consumer's response to the output handle
 * after the consumer signals completion. This is required: a
 * consumer that accessed the handle directly would enter the real
 * LingoFuse library from a different thread than the one that owns
 * the handle, and would deadlock on the library's per-handle locks
 * (see SHIM_MECHANISM_GUIDE.md).
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
 * Julia-side consumer BEFORE calling lf_shim_shutdown(). Otherwise a
 * leftover event could be dequeued by the (still-running) consumer
 * after the trampoline has already freed it, producing a
 * use-after-free. The Julia layer (stop_callback_consumer) already
 * enforces this ordering.
 *
 * Re-initialisation contract
 * --------------------------
 * lf_shim_init() may be called more than once per process. The
 * second and subsequent calls reset the shutdown flag so that a
 * fresh consumer can start. The mutex and condition variable are
 * preserved across calls.
 *
 * Precondition: the previous consumer MUST have been fully stopped
 * before re-initialising, for the same reason as above.
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

  typedef CRITICAL_SECTION  lf_mutex_t;
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
/*
 * The shim needs two groups of LF_* functions:
 *
 *   1. Registration entry points. Used by lf_shim_register_call /
 *      lf_shim_register_notify / lf_shim_install_network_events.
 *
 *   2. Data handle accessors. Used by the trampolines to snapshot
 *      the input payload and to write the consumer's response to the
 *      output handle.
 *
 * In the mock build all seven symbols come from mock_lf.c. In the
 * real build, lf_real_link.c resolves them lazily against the real
 * LingoFuse library.
 */

extern int  LF_RegisterCall(
    void* app, const char* name, const char* desc,
    void* trigger,
    void (*cb)(void* trigger, void* input, void* output));

extern int  LF_RegisterNotify(
    void* app, const char* name, const char* desc,
    void* trigger,
    void (*cb)(void* trigger, void* input));

extern void LF_Set_Network_Event(
    void (*on_connect)(const char* addr),
    void (*on_disconnect)(const char* addr));

extern int64_t LF_GetSize(void* hnd);
extern void    LF_SetPos (void* hnd, int64_t pos);
extern int64_t LF_ReadBuffer (void* hnd, void* buff, int64_t size);
extern int64_t LF_WriteBuffer(void* hnd, const void* buff, int64_t size);

/* ================================================================= */
/* Allocation-failure diagnostic                                      */
/* ================================================================= */
/*
 * Every heap allocation in this file is checked for failure. To avoid
 * flooding stderr under sustained out-of-memory conditions, only the
 * first failure is reported. The message is intentionally coarse: an
 * allocation failure in the shim has no useful recovery path, and the
 * caller will observe an empty response.
 */

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

    /* Response bytes supplied by the consumer via lf_shim_set_output.
     * Owned by the event. Written to the native output handle by the
     * trampoline after the consumer signals completion. */
    void*           output_data;
    size_t          output_len;

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
    if (e->input_data)  free(e->input_data);
    if (e->output_data) free(e->output_data);
    if (e->addr)        free(e->addr);
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

int lf_shim_init(void)
{
    if (g_initialised) {
        /*
         * Re-initialisation after a previous shutdown: reset the
         * shutdown flag so a fresh consumer can start. The mutex and
         * condition variable are preserved.
         *
         * Precondition: the previous consumer MUST have been fully
         * stopped before this call. Otherwise a leftover event in
         * the queue could be dequeued by the old consumer after the
         * trampoline has freed it, producing a use-after-free.
         */
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

void lf_shim_shutdown(void)
{
    if (!g_initialised) return;

    /*
     * Signal every trampoline (and the consumer) to stop.
     *
     * We deliberately do NOT walk the queue here. Any trampoline
     * that is currently blocked in wait_for_completion() will notice
     * g_shutdown within one timeout period and unblock itself, then
     * free its own event. Walking the queue from this thread would
     * race with those trampolines, which free their events as soon
     * as they wake.
     *
     * The caller MUST have fully stopped the Julia-side consumer
     * before invoking this function; see the file header.
     */
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

lf_shim_event_t* lf_shim_wait_event(int timeout_ms)
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
/*
 * Read the entire content of the native input handle into a freshly
 * allocated heap buffer. Called on the trampoline thread, which is
 * the same thread that owns the handle, so no locking is required on
 * the native side.
 */

static void snapshot_input(lf_shim_event_t* e)
{
    if (!e->input) return;

    LF_SetPos(e->input, 0);
    int64_t sz = LF_GetSize(e->input);
    if (sz <= 0) return;

    e->input_data = malloc((size_t)sz);
    if (!e->input_data) {
        warn_alloc_failure("snapshot_input");
        return;
    }

    int64_t got = LF_ReadBuffer(e->input, e->input_data, sz);
    e->input_len = (got > 0) ? (size_t)got : 0;
    if (e->input_len == 0) {
        free(e->input_data);
        e->input_data = NULL;
    }
}

/* ================================================================= */
/* Trampolines                                                        */
/* ================================================================= */
/*
 * Each trampoline:
 *   1. Snapshots the input payload into a heap buffer.
 *   2. Allocates an event and pushes it onto the queue.
 *   3. Blocks on the event's own condition variable until either the
 *      consumer signals completion or the process-wide shutdown flag
 *      is observed.
 *   4. Writes the consumer's response to the native output handle
 *      (when applicable).
 *   5. Frees the event.
 *
 * Steps 1, 4, and 5 run on the C4 worker thread, so all native
 * handle accesses happen on the thread that owns the handles.
 */

static void wait_for_completion(lf_shim_event_t* e)
{
    lf_mutex_lock(&e->mtx);
    while (!e->done) {
        /*
         * Read g_shutdown without the queue mutex. g_shutdown is a
         * volatile int; on all platforms this binding targets, a
         * naturally aligned int read is atomic, and the volatile
         * qualifier prevents the compiler from caching the value
         * across loop iterations.
         *
         * A 100 ms timeout on the wait ensures that a g_shutdown
         * change is observed even when no signal arrives on this
         * event's condition variable. The normal fast path
         * (consumer signals completion) wakes this trampoline
         * immediately and does not pay the timeout.
         */
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
/* Public registration API                                            */
/* ================================================================= */

int lf_shim_register_call(void* app, const char* name,
                          const char* desc, int64_t user_id)
{
    return LF_RegisterCall(
        app, name, desc,
        (void*)(intptr_t)user_id,
        shim_call_trampoline);
}

int lf_shim_register_notify(void* app, const char* name,
                            const char* desc, int64_t user_id)
{
    return LF_RegisterNotify(
        app, name, desc,
        (void*)(intptr_t)user_id,
        shim_notify_trampoline);
}

void lf_shim_install_network_events(int64_t connect_uid, int64_t disconnect_uid)
{
    g_connect_uid    = connect_uid;
    g_disconnect_uid = disconnect_uid;
    LF_Set_Network_Event(shim_network_connect_trampoline,
                         shim_network_disconnect_trampoline);
}

void lf_shim_clear_network_events(void)
{
    LF_Set_Network_Event(NULL, NULL);
    g_connect_uid    = 0;
    g_disconnect_uid = 0;
}

/* ================================================================= */
/* Consumer API                                                       */
/* ================================================================= */

int lf_shim_event_kind(const lf_shim_event_t* e)
{
    return e ? e->kind : -1;
}

int64_t lf_shim_event_user_id(const lf_shim_event_t* e)
{
    return e ? e->user_id : 0;
}

void* lf_shim_event_input(const lf_shim_event_t* e)
{
    return e ? e->input : NULL;
}

void* lf_shim_event_output(const lf_shim_event_t* e)
{
    return e ? e->output : NULL;
}

const char* lf_shim_event_addr(const lf_shim_event_t* e)
{
    return e ? e->addr : NULL;
}

const void* lf_shim_event_input_data(const lf_shim_event_t* e)
{
    return e ? e->input_data : NULL;
}

size_t lf_shim_event_input_len(const lf_shim_event_t* e)
{
    return e ? e->input_len : 0;
}

int lf_shim_set_output(lf_shim_event_t* e, const void* data, size_t len)
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

void lf_shim_complete_event(lf_shim_event_t* e)
{
    if (!e) return;
    lf_mutex_lock(&e->mtx);
    e->done = 1;
    lf_cond_signal(&e->cv);
    lf_mutex_unlock(&e->mtx);
    /* The trampoline owns the event and will free it after waking up. */
}