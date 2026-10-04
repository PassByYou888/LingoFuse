/*
 * lingofuse_nif.c
 *
 * Erlang NIF bridge for the LingoFuse C ABI.
 *
 * This file exposes all 37 C ABI exports as NIF functions, wraps
 * both handle kinds in Erlang resource objects, and provides a
 * callback dispatch bridge that forwards Call / Notify / Network
 * events to registered Erlang processes.
 *
 * Call callback modes
 * -------------------
 * Two Call dispatch modes are supported:
 *
 *   ASYNC (register_call/4)
 *     The C callback sends {lf_call, Api, Payload} to the registered
 *     Erlang process and returns immediately. The LingoFuse output
 *     handle is left empty. This matches the original binding
 *     behaviour and is retained for backward compatibility.
 *
 *   SYNC  (register_call_sync/4)
 *     The C callback sends {lf_call, Ref, Api, Payload} to the
 *     registered Erlang process and then BLOCKS until either:
 *       * the Erlang side calls lingofuse_nif:reply(Ref, ResultBin),
 *         which wakes the blocked callback and writes ResultBin into
 *         the LingoFuse output handle, or
 *       * the sync timeout expires (default 30 seconds), in which
 *         case the output handle is left empty and a late reply from
 *         the Erlang side is silently discarded with
 *         {error, unknown_ref}.
 *
 * Sync wait primitive
 * -------------------
 * The NIF public API does NOT provide enif_cond_timedwait. Only the
 * untimed enif_cond_wait is available. The sync bridge therefore
 * uses a short polling loop with a portable 5 ms sleep between
 * checks. A reply is observed on the next poll tick, so the
 * effective reply latency is bounded by the poll interval; for the
 * workloads this binding targets, that is acceptable.
 *
 * Binary construction rule
 * ------------------------
 * Every binary handed to the BEAM is built with the same three-step
 * sequence:
 *
 *     enif_alloc_binary(size, &bin);        // 1. allocate
 *     memcpy(bin.data, src, size);          // 2. fill
 *     term = enif_make_binary(env, &bin);   // 3. hand to BEAM
 *
 * After step 3, `bin` must not be touched again.
 *
 * Threading rules
 * ---------------
 *   - A NIF entry point runs on a BEAM scheduler thread.
 *   - A LingoFuse callback runs on a native worker thread owned by
 *     the LingoFuse library. The only thread-safe Erlang call
 *     available there is enif_send, called with a NULL first
 *     argument.
 *   - A resource destructor may run on any thread. It must not
 *     create terms.
 *
 * Portability
 * -----------
 * The file is compiled on Windows (MinGW, Clang, or MSVC), Linux,
 * macOS, and BSD. All platform-specific code is confined to the two
 * small sections below: the sleep primitive and the thread-local
 * storage keyword. Everything else is standard C11 plus the Erlang
 * NIF API.
 *
 * Binary construction uses enif_alloc_binary + enif_make_binary
 * rather than enif_make_new_binary, because the WinDynNifCallbacks
 * dispatch table on Windows declares the third argument of
 * enif_make_new_binary as ERL_NIF_TERM* rather than char**.
 */

#if defined(_WIN32) && !defined(_CRT_SECURE_NO_WARNINGS)
#  define _CRT_SECURE_NO_WARNINGS
#endif

#include <erl_nif.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ============================================================================
 * Platform-specific primitives
 * ----------------------------------------------------------------------------
 * Two primitives differ across the toolchains this project targets:
 *
 *   1. Sleep. Windows provides Sleep (milliseconds). POSIX provides
 *      nanosleep (struct timespec). The classic usleep is used
 *      elsewhere in the codebase but is deliberately avoided here:
 *      POSIX.1-2001 marked it obsolete and POSIX.1-2008 removed it
 *      from the standard. It happens to still be available on glibc
 *      (behind _DEFAULT_SOURCE) and on macOS/BSD, but nanosleep is
 *      portable without any feature-test macro. EINTR is retried so
 *      that a signal delivered to the NIF thread cannot make the
 *      sleep return early.
 *
 *   2. Thread-local storage. GCC and Clang support the __thread
 *      extension. MSVC supports __declspec(thread). C11 standardises
 *      _Thread_local, but MSVC only supports it from VS 2019 16.8
 *      onward with /std:c11. The three-way selection below keeps the
 *      file compilable on every toolchain the build script accepts.
 *
 * The rest of the file is free of platform conditionals.
 * ============================================================================ */

#if defined(_WIN32)
#  include <windows.h>
#  define LF_SLEEP_MS(ms) Sleep((DWORD)(ms))
#else
#  include <errno.h>
#  include <time.h>
static void lf_sleep_ms(unsigned int ms)
{
    struct timespec ts;
    ts.tv_sec  = (time_t)(ms / 1000U);
    ts.tv_nsec = (long)(ms % 1000U) * 1000000L;
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {
        /* resume after interruption */
    }
}
#  define LF_SLEEP_MS(ms) lf_sleep_ms((unsigned int)(ms))
#endif

#if defined(_MSC_VER)
#  define LF_THREAD_LOCAL __declspec(thread)
#elif defined(__GNUC__) || defined(__clang__)
#  define LF_THREAD_LOCAL __thread
#else
#  define LF_THREAD_LOCAL _Thread_local
#endif

#include "lf_loader.h"
#include "lf_bindings.h"

/* ============================================================================
 * Pre-cached atom table
 * ============================================================================ */

static ERL_NIF_TERM ATOM_OK;
static ERL_NIF_TERM ATOM_ERROR;
static ERL_NIF_TERM ATOM_TRUE;
static ERL_NIF_TERM ATOM_FALSE;
static ERL_NIF_TERM ATOM_UNDEFINED;
static ERL_NIF_TERM ATOM_NOT_LOADED;
static ERL_NIF_TERM ATOM_BADARG;
static ERL_NIF_TERM ATOM_CREATE_FAILED;
static ERL_NIF_TERM ATOM_CALL_FAILED;
static ERL_NIF_TERM ATOM_REGISTRATION_FAILED;
static ERL_NIF_TERM ATOM_NO_APP;
static ERL_NIF_TERM ATOM_NO_HANDLE;
static ERL_NIF_TERM ATOM_ENOMEM;
static ERL_NIF_TERM ATOM_LF_CALL;
static ERL_NIF_TERM ATOM_LF_NOTIFY;
static ERL_NIF_TERM ATOM_LF_CONNECT;
static ERL_NIF_TERM ATOM_LF_DISCONNECT;
static ERL_NIF_TERM ATOM_REPLY_UNKNOWN;

/* ============================================================================
 * Sync callback bridge
 * ----------------------------------------------------------------------------
 * A pending sync Call is represented by a PendingSync struct that is
 * allocated on the C callback thread's stack. The struct is linked
 * into a global list protected by g_sync_mutex. The C callback polls
 * the struct with a short sleep between checks until either a reply
 * arrives or the timeout expires.
 * ============================================================================ */

typedef struct PendingSync {
    uint64_t                 ref;
    int                      has_result;
    int                      cancelled;
    void*                    result_data;
    int64_t                  result_size;
    struct PendingSync*      next;
} PendingSync;

static PendingSync*   g_sync_head     = NULL;
static ErlNifMutex*   g_sync_mutex    = NULL;
static uint64_t       g_sync_next_ref = 1;

/* Sync callback timeout, in milliseconds. Configurable via the
 * set_sync_timeout/1 NIF. Default 30 seconds. */
static ErlNifTime     g_sync_timeout_ms = 30000;

/* Poll interval used by sync_wait. Small enough to keep reply
 * latency low, large enough that concurrent waiters do not create
 * mutex contention. */
#define LF_SYNC_POLL_INTERVAL_MS 5

/* Register a stack-allocated PendingSync on the global list and
 * return its ref id. */
static uint64_t sync_register(PendingSync* p)
{
    enif_mutex_lock(g_sync_mutex);
    p->ref = g_sync_next_ref++;
    p->has_result = 0;
    p->cancelled = 0;
    p->result_data = NULL;
    p->result_size = 0;
    p->next = g_sync_head;
    g_sync_head = p;
    enif_mutex_unlock(g_sync_mutex);
    return p->ref;
}

/* Remove a PendingSync from the global list. Safe to call more than
 * once for the same entry (the second call is a no-op). */
static void sync_unregister(PendingSync* p)
{
    if (p == NULL) return;
    enif_mutex_lock(g_sync_mutex);
    PendingSync** pp = &g_sync_head;
    while (*pp != NULL) {
        if (*pp == p) {
            *pp = p->next;
            p->next = NULL;
            break;
        }
        pp = &(*pp)->next;
    }
    enif_mutex_unlock(g_sync_mutex);
}

/* Poll for the reply to arrive or the timeout to expire. Returns 1
 * if a reply is available (p->has_result is set), 0 on timeout or
 * when the bridge is shutting down.
 *
 * The loop releases the mutex between checks so that sync_deliver is
 * not blocked by the waiters. */
static int sync_wait(PendingSync* p)
{
    ErlNifTime deadline =
        enif_monotonic_time(ERL_NIF_MSEC) + g_sync_timeout_ms;
    int got = 0;

    while (1) {
        enif_mutex_lock(g_sync_mutex);
        if (p->has_result) {
            got = 1;
            enif_mutex_unlock(g_sync_mutex);
            break;
        }
        if (p->cancelled) {
            enif_mutex_unlock(g_sync_mutex);
            break;
        }
        enif_mutex_unlock(g_sync_mutex);

        ErlNifTime now = enif_monotonic_time(ERL_NIF_MSEC);
        if (now >= deadline) {
            break;
        }

        LF_SLEEP_MS(LF_SYNC_POLL_INTERVAL_MS);
    }
    return got;
}

/* Deliver a reply. Called from nif_reply. Copies the payload into
 * heap storage owned by the PendingSync; the caller of nif_reply
 * retains ownership of its own binary. Returns 1 if the ref was
 * found and the reply accepted, 0 if no such pending request exists. */
static int sync_deliver(uint64_t ref, const void* data, int64_t size)
{
    int found = 0;
    enif_mutex_lock(g_sync_mutex);
    for (PendingSync* p = g_sync_head; p != NULL; p = p->next) {
        if (p->ref == ref && !p->has_result) {
            if (size > 0) {
                p->result_data = malloc((size_t)size);
                if (p->result_data != NULL) {
                    memcpy(p->result_data, data, (size_t)size);
                    p->result_size = size;
                    p->has_result = 1;
                }
            } else {
                p->result_data = NULL;
                p->result_size = 0;
                p->has_result = 1;
            }
            found = 1;
            break;
        }
    }
    enif_mutex_unlock(g_sync_mutex);
    return found;
}

/* Mark the bridge as shutting down. Every active waiter will observe
 * this on its next poll tick and return. */
static void sync_wake_all(void)
{
    enif_mutex_lock(g_sync_mutex);
    for (PendingSync* p = g_sync_head; p != NULL; p = p->next) {
        p->cancelled = 1;
    }
    enif_mutex_unlock(g_sync_mutex);
}

/* ============================================================================
 * Resource types
 * ============================================================================ */

typedef struct {
    TDataHnd handle;
} DataHandleRes;

typedef struct {
    TAppHnd handle;
} AppHandleRes;

static ErlNifResourceType* g_data_handle_type = NULL;
static ErlNifResourceType* g_app_handle_type  = NULL;

static void data_handle_dtor(ErlNifEnv* env, void* obj) {
    (void)env;
    DataHandleRes* r = (DataHandleRes*)obj;
    if (r->handle != NULL) {
        const LF_Bindings* b = lf_loader_get();
        if (b != NULL && b->LF_FreeData != NULL) {
            b->LF_FreeData(r->handle);
        }
        r->handle = NULL;
    }
}

static void app_handle_dtor(ErlNifEnv* env, void* obj) {
    (void)env;
    AppHandleRes* r = (AppHandleRes*)obj;
    if (r->handle != NULL) {
        const LF_Bindings* b = lf_loader_get();
        if (b != NULL && b->LF_FreeApp != NULL) {
            b->LF_FreeApp(r->handle);
        }
        r->handle = NULL;
    }
}

/* ============================================================================
 * Callback registry
 * ============================================================================ */

typedef struct CallbackEntry {
    void* trigger;
    char*  api_name;
    ErlNifPid caller_pid;
    int    is_notify;
    int    is_sync;    /* 0 = async (legacy), 1 = sync bridge */
    volatile int dead;
    struct CallbackEntry* next;
} CallbackEntry;

static CallbackEntry* g_callbacks       = NULL;
static ErlNifMutex*   g_callbacks_mutex = NULL;

static CallbackEntry* callback_lookup(void* trigger) {
    if (trigger == NULL) return NULL;
    return (CallbackEntry*)trigger;
}

static CallbackEntry* callback_alloc(const char* api_name,
                                     const ErlNifPid* pid,
                                     int is_notify,
                                     int is_sync) {
    CallbackEntry* e = (CallbackEntry*)calloc(1, sizeof(CallbackEntry));
    if (e == NULL) return NULL;

    size_t len = strlen(api_name);
    e->api_name = (char*)malloc(len + 1);
    if (e->api_name == NULL) {
        free(e);
        return NULL;
    }
    memcpy(e->api_name, api_name, len);
    e->api_name[len] = '\0';

    e->caller_pid = *pid;
    e->is_notify  = is_notify;
    e->is_sync    = is_sync;
    e->dead       = 0;
    e->trigger    = e;

    enif_mutex_lock(g_callbacks_mutex);
    e->next = g_callbacks;
    g_callbacks = e;
    enif_mutex_unlock(g_callbacks_mutex);

    return e;
}

static void callback_mark_dead_by_name(const char* api_name) {
    enif_mutex_lock(g_callbacks_mutex);
    for (CallbackEntry* e = g_callbacks; e != NULL; e = e->next) {
        if (e->api_name != NULL && strcmp(e->api_name, api_name) == 0) {
            e->dead = 1;
        }
    }
    enif_mutex_unlock(g_callbacks_mutex);
}

static void callback_free_all(void) {
    if (g_callbacks_mutex == NULL) return;
    enif_mutex_lock(g_callbacks_mutex);
    CallbackEntry* e = g_callbacks;
    g_callbacks = NULL;
    enif_mutex_unlock(g_callbacks_mutex);

    while (e != NULL) {
        CallbackEntry* next = e->next;
        if (e->api_name != NULL) free(e->api_name);
        free(e);
        e = next;
    }
}

/* ============================================================================
 * Callback trampolines
 * ============================================================================ */

static int copy_handle_to_binary(ErlNifEnv* env,
                                 TDataHnd hnd,
                                 ERL_NIF_TERM* out_term) {
    const LF_Bindings* b = lf_loader_get();
    if (b == NULL || hnd == NULL) {
        ErlNifBinary bin;
        if (!enif_alloc_binary(0, &bin)) {
            *out_term = ATOM_ENOMEM;
            return 0;
        }
        *out_term = enif_make_binary(env, &bin);
        return 0;
    }

    int64_t size = b->LF_GetSize(hnd);
    if (size <= 0) {
        ErlNifBinary bin;
        if (!enif_alloc_binary(0, &bin)) {
            *out_term = ATOM_ENOMEM;
            return 0;
        }
        *out_term = enif_make_binary(env, &bin);
        return 1;
    }

    int64_t saved = b->LF_GetPos(hnd);
    b->LF_SetPos(hnd, 0);

    ErlNifBinary bin;
    if (!enif_alloc_binary((size_t)size, &bin)) {
        b->LF_SetPos(hnd, saved);
        *out_term = ATOM_ENOMEM;
        return 0;
    }

    int64_t got = b->LF_ReadBuffer(hnd, bin.data, size);
    b->LF_SetPos(hnd, saved);

    if (got != size) {
        enif_release_binary(&bin);
        return 0;
    }
    *out_term = enif_make_binary(env, &bin);
    return 1;
}

/* Write a byte buffer into the LingoFuse output handle. Returns 1 on
 * a full write, 0 otherwise. */
static int write_to_output_handle(TDataHnd output,
                                  const void* data,
                                  int64_t size) {
    if (output == NULL) return 0;
    const LF_Bindings* b = lf_loader_get();
    if (b == NULL) return 0;

    b->LF_SetPos(output, 0);
    b->LF_SetSize(output, 0);

    if (size <= 0) {
        return 1;
    }
    int64_t written = b->LF_WriteBuffer(output, data, size);
    return (written == size) ? 1 : 0;
}

/* Build and enif_send the {lf_call, ...} message. When with_ref is
 * non-zero, the message is a 4-tuple that carries the ref; otherwise
 * it is the legacy 3-tuple. Returns 1 on success. */
static int send_lf_call_message(ErlNifEnv* msg_env,
                                const CallbackEntry* e,
                                const ERL_NIF_TERM api_term,
                                const ERL_NIF_TERM payload_term,
                                int with_ref,
                                uint64_t ref)
{
    ERL_NIF_TERM msg;
    if (with_ref) {
        msg = enif_make_tuple4(msg_env, ATOM_LF_CALL,
                               enif_make_uint64(msg_env, ref),
                               api_term,
                               payload_term);
    } else {
        msg = enif_make_tuple3(msg_env, ATOM_LF_CALL,
                               api_term,
                               payload_term);
    }
    if (!enif_send(NULL, &e->caller_pid, msg_env, msg)) {
        return 0;
    }
    return 1;
}

/* Result stash used to pass the reply payload from
 * dispatch_to_process back to lf_call_callback, which owns the
 * output handle.
 *
 * The stash is a thread-local slot because every LingoFuse worker
 * thread that enters lf_call_callback does so for exactly one call at
 * a time. The callback clears the slot before returning. */
typedef struct {
    void*   data;
    int64_t size;
} SyncStash;

static LF_THREAD_LOCAL SyncStash t_sync_stash = { NULL, 0 };

static void lf_sync_stash_result(void* data, int64_t size) {
    t_sync_stash.data = data;
    t_sync_stash.size = size;
}

static SyncStash lf_sync_take_result(void) {
    SyncStash s = t_sync_stash;
    t_sync_stash.data = NULL;
    t_sync_stash.size = 0;
    return s;
}

static void dispatch_to_process(CallbackEntry* e,
                                TDataHnd input,
                                int is_call) {
    if (e == NULL || e->dead) return;

    ErlNifEnv* msg_env = enif_alloc_env();
    if (msg_env == NULL) return;

    ERL_NIF_TERM payload;
    if (!copy_handle_to_binary(msg_env, input, &payload)) {
        enif_free_env(msg_env);
        return;
    }

    size_t api_len = strlen(e->api_name);
    ErlNifBinary api_bin;
    if (!enif_alloc_binary(api_len, &api_bin)) {
        enif_free_env(msg_env);
        return;
    }
    if (api_len > 0) memcpy(api_bin.data, e->api_name, api_len);
    ERL_NIF_TERM api_term = enif_make_binary(msg_env, &api_bin);

    if (is_call) {
        if (e->is_sync) {
            PendingSync pending;
            memset(&pending, 0, sizeof(pending));
            uint64_t ref = sync_register(&pending);

            if (!send_lf_call_message(msg_env, e, api_term, payload,
                                      1 /* with_ref */, ref)) {
                sync_unregister(&pending);
                enif_free_env(msg_env);
                return;
            }

            /* Block until the Erlang side calls reply/2 or the
             * sync timeout fires. */
            int got = sync_wait(&pending);
            sync_unregister(&pending);

            if (got && pending.result_data != NULL) {
                /* Hand the reply payload to the caller of this
                 * function (lf_call_callback) via the thread-local
                 * stash. Ownership of the heap buffer transfers to
                 * the stash. */
                lf_sync_stash_result(pending.result_data,
                                     pending.result_size);
                pending.result_data = NULL;
            } else if (pending.result_data != NULL) {
                /* Timed out but a late reply raced in. Discard. */
                free(pending.result_data);
                pending.result_data = NULL;
            }

            enif_free_env(msg_env);
            return;
        } else {
            /* Async mode: fire and forget. */
            (void)send_lf_call_message(msg_env, e, api_term, payload,
                                       0 /* with_ref */, 0);
            enif_free_env(msg_env);
            return;
        }
    } else {
        ERL_NIF_TERM msg = enif_make_tuple3(msg_env, ATOM_LF_NOTIFY,
                                            api_term, payload);
        enif_send(NULL, &e->caller_pid, msg_env, msg);
    }

    enif_free_env(msg_env);
}

static void LF_CDECL lf_call_callback(void* trigger,
                                      TDataHnd input,
                                      TDataHnd output) {
    CallbackEntry* e = callback_lookup(trigger);
    dispatch_to_process(e, input, 1);

    if (e != NULL && e->is_sync) {
        SyncStash s = lf_sync_take_result();
        if (s.data != NULL && s.size > 0) {
            write_to_output_handle(output, s.data, s.size);
            free(s.data);
        }
        /* else: leave the output handle empty. */
    }
}

static void LF_CDECL lf_notify_callback(void* trigger, TDataHnd input) {
    CallbackEntry* e = callback_lookup(trigger);
    dispatch_to_process(e, input, 0);
}

/* --- Network events ------------------------------------------------------- */

static ErlNifPid  g_net_connect_pid;
static ErlNifPid  g_net_disconnect_pid;
static int        g_net_connect_set    = 0;
static int        g_net_disconnect_set = 0;

static void LF_CDECL lf_net_connect_cb(const char* addr) {
    if (!g_net_connect_set) return;
    ErlNifEnv* msg_env = enif_alloc_env();
    if (msg_env == NULL) return;

    size_t len = (addr != NULL) ? strlen(addr) : 0;
    ErlNifBinary bin;
    if (!enif_alloc_binary(len, &bin)) {
        enif_free_env(msg_env);
        return;
    }
    if (len > 0) memcpy(bin.data, addr, len);
    ERL_NIF_TERM bin_term = enif_make_binary(msg_env, &bin);

    ERL_NIF_TERM msg = enif_make_tuple2(msg_env, ATOM_LF_CONNECT, bin_term);
    enif_send(NULL, &g_net_connect_pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void LF_CDECL lf_net_disconnect_cb(const char* addr) {
    if (!g_net_disconnect_set) return;
    ErlNifEnv* msg_env = enif_alloc_env();
    if (msg_env == NULL) return;

    size_t len = (addr != NULL) ? strlen(addr) : 0;
    ErlNifBinary bin;
    if (!enif_alloc_binary(len, &bin)) {
        enif_free_env(msg_env);
        return;
    }
    if (len > 0) memcpy(bin.data, addr, len);
    ERL_NIF_TERM bin_term = enif_make_binary(msg_env, &bin);

    ERL_NIF_TERM msg = enif_make_tuple2(msg_env, ATOM_LF_DISCONNECT, bin_term);
    enif_send(NULL, &g_net_disconnect_pid, msg_env, msg);
    enif_free_env(msg_env);
}

/* ============================================================================
 * Helpers
 * ============================================================================ */

static int get_c_string(ErlNifEnv* env, ERL_NIF_TERM term, char** out) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin)) {
        return 0;
    }
    char* buf = (char*)malloc(bin.size + 1);
    if (buf == NULL) return 0;
    if (bin.size > 0) memcpy(buf, bin.data, bin.size);
    buf[bin.size] = '\0';
    *out = buf;
    return 1;
}

static ERL_NIF_TERM make_binary_from_cstr(ErlNifEnv* env, const char* s) {
    size_t len = (s != NULL) ? strlen(s) : 0;
    ErlNifBinary bin;
    if (!enif_alloc_binary(len, &bin)) {
        return ATOM_ENOMEM;
    }
    if (len > 0) memcpy(bin.data, s, len);
    return enif_make_binary(env, &bin);
}

static ERL_NIF_TERM make_error(ErlNifEnv* env, ERL_NIF_TERM reason) {
    return enif_make_tuple2(env, ATOM_ERROR, reason);
}

static ERL_NIF_TERM make_badarg(ErlNifEnv* env) {
    return enif_make_badarg(env);
}

static DataHandleRes* get_data_handle_res(ErlNifEnv* env, ERL_NIF_TERM term) {
    DataHandleRes* r = NULL;
    if (!enif_get_resource(env, term, g_data_handle_type, (void**)&r)) {
        return NULL;
    }
    if (r == NULL || r->handle == NULL) return NULL;
    return r;
}

static AppHandleRes* get_app_handle_res(ErlNifEnv* env, ERL_NIF_TERM term) {
    AppHandleRes* r = NULL;
    if (!enif_get_resource(env, term, g_app_handle_type, (void**)&r)) {
        return NULL;
    }
    if (r == NULL || r->handle == NULL) return NULL;
    return r;
}

static ERL_NIF_TERM make_data_handle_term(ErlNifEnv* env, TDataHnd hnd) {
    if (hnd == NULL) return ATOM_UNDEFINED;
    DataHandleRes* r = (DataHandleRes*)enif_alloc_resource(
        g_data_handle_type, sizeof(DataHandleRes));
    if (r == NULL) return ATOM_ENOMEM;
    r->handle = hnd;
    ERL_NIF_TERM term = enif_make_resource(env, r);
    enif_release_resource(r);
    return term;
}

static ERL_NIF_TERM make_app_handle_term(ErlNifEnv* env, TAppHnd hnd) {
    if (hnd == NULL) return ATOM_UNDEFINED;
    AppHandleRes* r = (AppHandleRes*)enif_alloc_resource(
        g_app_handle_type, sizeof(AppHandleRes));
    if (r == NULL) return ATOM_ENOMEM;
    r->handle = hnd;
    ERL_NIF_TERM term = enif_make_resource(env, r);
    enif_release_resource(r);
    return term;
}

#define LF_ENSURE_LOADED()                                                   \
    const LF_Bindings* b = lf_loader_get();                                  \
    if (b == NULL) {                                                         \
        return make_error(env, ATOM_NOT_LOADED);                             \
    }                                                                        \
    (void)b

/* ============================================================================
 * NIF load / upgrade / unload
 * ============================================================================ */

static int load_common(ErlNifEnv* env, void** priv, ERL_NIF_TERM load_info) {
    (void)priv;
    (void)load_info;

    ATOM_OK                  = enif_make_atom(env, "ok");
    ATOM_ERROR               = enif_make_atom(env, "error");
    ATOM_TRUE                = enif_make_atom(env, "true");
    ATOM_FALSE               = enif_make_atom(env, "false");
    ATOM_UNDEFINED           = enif_make_atom(env, "undefined");
    ATOM_NOT_LOADED          = enif_make_atom(env, "lf_not_loaded");
    ATOM_BADARG              = enif_make_atom(env, "badarg");
    ATOM_CREATE_FAILED       = enif_make_atom(env, "create_failed");
    ATOM_CALL_FAILED         = enif_make_atom(env, "call_failed");
    ATOM_REGISTRATION_FAILED = enif_make_atom(env, "registration_failed");
    ATOM_NO_APP              = enif_make_atom(env, "no_app");
    ATOM_NO_HANDLE           = enif_make_atom(env, "no_handle");
    ATOM_ENOMEM              = enif_make_atom(env, "enomem");
    ATOM_LF_CALL             = enif_make_atom(env, "lf_call");
    ATOM_LF_NOTIFY           = enif_make_atom(env, "lf_notify");
    ATOM_LF_CONNECT          = enif_make_atom(env, "lf_connect");
    ATOM_LF_DISCONNECT       = enif_make_atom(env, "lf_disconnect");
    ATOM_REPLY_UNKNOWN       = enif_make_atom(env, "unknown_ref");

    g_data_handle_type = enif_open_resource_type(
        env, NULL, "lf_data_handle",
        data_handle_dtor, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL);
    if (g_data_handle_type == NULL) {
        fprintf(stderr, "[lingofuse_nif] failed to open data handle resource type\n");
        return -1;
    }

    g_app_handle_type = enif_open_resource_type(
        env, NULL, "lf_app_handle",
        app_handle_dtor, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL);
    if (g_app_handle_type == NULL) {
        fprintf(stderr, "[lingofuse_nif] failed to open app handle resource type\n");
        return -1;
    }

    if (g_callbacks_mutex == NULL) {
        g_callbacks_mutex = enif_mutex_create("lf_callbacks_mutex");
        if (g_callbacks_mutex == NULL) {
            fprintf(stderr, "[lingofuse_nif] failed to create callbacks mutex\n");
            return -1;
        }
    }

    if (g_sync_mutex == NULL) {
        g_sync_mutex = enif_mutex_create("lf_sync_mutex");
        if (g_sync_mutex == NULL) {
            fprintf(stderr, "[lingofuse_nif] failed to create sync mutex\n");
            return -1;
        }
    }

    LF_LoadStatus status = lf_loader_ensure_loaded();
    if (status != LF_LOAD_OK) {
        fprintf(stderr,
                "[lingofuse_nif] LingoFuse library not available.\n"
                "  platform  : %s\n"
                "  expected  : %s\n"
                "  error     : %s\n",
                lf_loader_platform(),
                lf_loader_expected_file_name(),
                lf_loader_last_error());
    } else {
        fprintf(stderr,
                "[lingofuse_nif] LingoFuse library loaded "
                "(platform=%s, file=%s)\n",
                lf_loader_platform(),
                lf_loader_expected_file_name());
    }

    return 0;
}

static int nif_load(ErlNifEnv* env, void** priv, ERL_NIF_TERM load_info) {
    return load_common(env, priv, load_info);
}

static int nif_upgrade(ErlNifEnv* env, void** priv, void** old_priv,
                       ERL_NIF_TERM load_info) {
    (void)old_priv;
    return load_common(env, priv, load_info);
}

static void nif_unload(ErlNifEnv* env, void* priv) {
    (void)env;
    (void)priv;

    /* Wake every blocked sync callback so none is stuck when the
     * loader tears down the library. */
    if (g_sync_mutex != NULL) {
        sync_wake_all();
    }

    callback_free_all();

    if (g_callbacks_mutex != NULL) {
        enif_mutex_destroy(g_callbacks_mutex);
        g_callbacks_mutex = NULL;
    }
    if (g_sync_mutex != NULL) {
        enif_mutex_destroy(g_sync_mutex);
        g_sync_mutex = NULL;
    }
}

/* ============================================================================
 * Data handle thunks
 * ============================================================================ */

static ERL_NIF_TERM nif_create_data(ErlNifEnv* env, int argc,
                                    const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* name = NULL;
    if (!get_c_string(env, argv[0], &name)) {
        return make_badarg(env);
    }
    TDataHnd hnd = b->LF_CreateData(name);
    free(name);

    if (hnd == NULL) return make_error(env, ATOM_CREATE_FAILED);
    ERL_NIF_TERM term = make_data_handle_term(env, hnd);
    if (enif_is_identical(term, ATOM_ENOMEM)) {
        b->LF_FreeData(hnd);
        return make_error(env, ATOM_ENOMEM);
    }
    return term;
}

static ERL_NIF_TERM nif_create_data_permanent(ErlNifEnv* env, int argc,
                                              const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* name = NULL;
    if (!get_c_string(env, argv[0], &name)) {
        return make_badarg(env);
    }
    TDataHnd hnd = b->LF_CreateData_Permanent(name);
    free(name);

    if (hnd == NULL) return make_error(env, ATOM_CREATE_FAILED);
    ERL_NIF_TERM term = make_data_handle_term(env, hnd);
    if (enif_is_identical(term, ATOM_ENOMEM)) {
        b->LF_FreeData(hnd);
        return make_error(env, ATOM_ENOMEM);
    }
    return term;
}

static ERL_NIF_TERM nif_free_data(ErlNifEnv* env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    DataHandleRes* r = NULL;
    if (!enif_get_resource(env, argv[0], g_data_handle_type, (void**)&r)) {
        return make_badarg(env);
    }
    if (r == NULL || r->handle == NULL) {
        return ATOM_OK;
    }
    b->LF_FreeData(r->handle);
    r->handle = NULL;
    return ATOM_OK;
}

static ERL_NIF_TERM nif_get_buffer(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    DataHandleRes* r = get_data_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);

    void* p = b->LF_GetBuffer(r->handle);
    int64_t size = b->LF_GetSize(r->handle);

    if (p == NULL || size <= 0) {
        ErlNifBinary bin;
        if (!enif_alloc_binary(0, &bin)) {
            return make_error(env, ATOM_ENOMEM);
        }
        return enif_make_binary(env, &bin);
    }

    ErlNifBinary bin;
    if (!enif_alloc_binary((size_t)size, &bin)) {
        return make_error(env, ATOM_ENOMEM);
    }
    memcpy(bin.data, p, (size_t)size);
    return enif_make_binary(env, &bin);
}

static ERL_NIF_TERM nif_write_buffer(ErlNifEnv* env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    DataHandleRes* r = get_data_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);

    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[1], &bin)) {
        return make_badarg(env);
    }

    int64_t written;
    if (bin.size == 0) {
        written = 0;
    } else {
        written = b->LF_WriteBuffer(r->handle, bin.data, (int64_t)bin.size);
    }
    return enif_make_int64(env, written);
}

static ERL_NIF_TERM nif_read_buffer(ErlNifEnv* env, int argc,
                                    const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    DataHandleRes* r = get_data_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);

    ErlNifSInt64 want = 0;
    if (!enif_get_int64(env, argv[1], &want) || want < 0) {
        return make_badarg(env);
    }
    if (want == 0) {
        ErlNifBinary bin;
        if (!enif_alloc_binary(0, &bin)) {
            return make_error(env, ATOM_ENOMEM);
        }
        return enif_make_binary(env, &bin);
    }

    ErlNifBinary bin;
    if (!enif_alloc_binary((size_t)want, &bin)) {
        return make_error(env, ATOM_ENOMEM);
    }

    int64_t got = b->LF_ReadBuffer(r->handle, bin.data, want);

    if (got <= 0) {
        enif_release_binary(&bin);
        ErlNifBinary empty;
        if (!enif_alloc_binary(0, &empty)) {
            return make_error(env, ATOM_ENOMEM);
        }
        return enif_make_binary(env, &empty);
    }
    if (got < want) {
        ErlNifBinary small;
        if (!enif_alloc_binary((size_t)got, &small)) {
            enif_release_binary(&bin);
            return make_error(env, ATOM_ENOMEM);
        }
        memcpy(small.data, bin.data, (size_t)got);
        enif_release_binary(&bin);
        return enif_make_binary(env, &small);
    }
    return enif_make_binary(env, &bin);
}

static ERL_NIF_TERM nif_get_pos(ErlNifEnv* env, int argc,
                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    DataHandleRes* r = get_data_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);
    return enif_make_int64(env, b->LF_GetPos(r->handle));
}

static ERL_NIF_TERM nif_set_pos(ErlNifEnv* env, int argc,
                                const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    DataHandleRes* r = get_data_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);

    ErlNifSInt64 pos = 0;
    if (!enif_get_int64(env, argv[1], &pos) || pos < 0) {
        return make_badarg(env);
    }
    b->LF_SetPos(r->handle, pos);
    return ATOM_OK;
}

static ERL_NIF_TERM nif_get_size(ErlNifEnv* env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    DataHandleRes* r = get_data_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);
    return enif_make_int64(env, b->LF_GetSize(r->handle));
}

static ERL_NIF_TERM nif_set_size(ErlNifEnv* env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    DataHandleRes* r = get_data_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);

    ErlNifSInt64 size = 0;
    if (!enif_get_int64(env, argv[1], &size) || size < 0) {
        return make_badarg(env);
    }
    b->LF_SetSize(r->handle, size);
    return ATOM_OK;
}

/* ============================================================================
 * Application handle thunks
 * ============================================================================ */

static ERL_NIF_TERM nif_create_app(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* name = NULL;
    char* desc = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);
    if (!get_c_string(env, argv[1], &desc)) { free(name); return make_badarg(env); }

    TAppHnd hnd = b->LF_CreateApp(name, desc);
    free(name);
    free(desc);

    if (hnd == NULL) return make_error(env, ATOM_CREATE_FAILED);
    ERL_NIF_TERM term = make_app_handle_term(env, hnd);
    if (enif_is_identical(term, ATOM_ENOMEM)) {
        b->LF_FreeApp(hnd);
        return make_error(env, ATOM_ENOMEM);
    }
    return term;
}

static ERL_NIF_TERM nif_free_app(ErlNifEnv* env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    AppHandleRes* r = NULL;
    if (!enif_get_resource(env, argv[0], g_app_handle_type, (void**)&r)) {
        return make_badarg(env);
    }
    if (r == NULL || r->handle == NULL) return ATOM_OK;
    b->LF_FreeApp(r->handle);
    r->handle = NULL;
    return ATOM_OK;
}

static ERL_NIF_TERM nif_generate_app_name(ErlNifEnv* env, int argc,
                                          const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();
    const char* s = b->LF_Generate_AppName();
    return make_binary_from_cstr(env, s);
}

static ERL_NIF_TERM nif_get_app_name(ErlNifEnv* env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    AppHandleRes* r = get_app_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);
    const char* s = b->LF_Get_AppName(r->handle);
    return make_binary_from_cstr(env, s);
}

static ERL_NIF_TERM nif_bind_app(ErlNifEnv* env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    AppHandleRes* r = get_app_handle_res(env, argv[0]);
    if (r == NULL) return make_badarg(env);
    int n = b->LF_BindApp(r->handle);
    return enif_make_int(env, n);
}

/* ============================================================================
 * API registration thunks
 * ============================================================================ */

static int register_common(ErlNifEnv* env, int argc,
                           const ERL_NIF_TERM argv[],
                           int is_notify,
                           int is_sync,
                           ERL_NIF_TERM* out) {
    (void)argc;

    const LF_Bindings* b = lf_loader_get();
    if (b == NULL) {
        *out = make_error(env, ATOM_NOT_LOADED);
        return 0;
    }

    AppHandleRes* app = get_app_handle_res(env, argv[0]);
    if (app == NULL) { *out = make_badarg(env); return 0; }

    char* name = NULL;
    char* desc = NULL;
    if (!get_c_string(env, argv[1], &name)) { *out = make_badarg(env); return 0; }
    if (!get_c_string(env, argv[2], &desc)) { free(name); *out = make_badarg(env); return 0; }

    ErlNifPid pid;
    if (!enif_get_local_pid(env, argv[3], &pid)) {
        free(name); free(desc);
        *out = make_badarg(env); return 0;
    }

    CallbackEntry* e = callback_alloc(name, &pid, is_notify, is_sync);
    if (e == NULL) {
        free(name); free(desc);
        *out = make_error(env, ATOM_ENOMEM); return 0;
    }

    int ret;
    if (is_notify) {
        ret = b->LF_RegisterNotify(
            app->handle, name, desc, e->trigger,
            (LF_NotifyFunc)lf_notify_callback);
    } else {
        ret = b->LF_RegisterCall(
            app->handle, name, desc, e->trigger,
            (LF_CallFunc)lf_call_callback);
    }

    free(name);
    free(desc);

    if (ret != 1) {
        e->dead = 1;
        *out = make_error(env, ATOM_REGISTRATION_FAILED);
        return 0;
    }
    *out = ATOM_OK;
    return 1;
}

static ERL_NIF_TERM nif_register_call(ErlNifEnv* env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM out;
    register_common(env, argc, argv, 0 /* is_notify */, 0 /* is_sync */, &out);
    return out;
}

static ERL_NIF_TERM nif_register_call_sync(ErlNifEnv* env, int argc,
                                           const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM out;
    register_common(env, argc, argv, 0 /* is_notify */, 1 /* is_sync */, &out);
    return out;
}

static ERL_NIF_TERM nif_register_notify(ErlNifEnv* env, int argc,
                                        const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM out;
    register_common(env, argc, argv, 1 /* is_notify */, 0 /* is_sync */, &out);
    return out;
}

static ERL_NIF_TERM nif_unregister(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    AppHandleRes* app = get_app_handle_res(env, argv[0]);
    if (app == NULL) return make_badarg(env);

    char* name = NULL;
    if (!get_c_string(env, argv[1], &name)) return make_badarg(env);

    int ret = b->LF_Unregister(app->handle, name);
    if (ret == 1) {
        callback_mark_dead_by_name(name);
    }
    free(name);

    return (ret == 1) ? ATOM_TRUE : ATOM_FALSE;
}

/* ============================================================================
 * Sync reply thunk
 * ============================================================================ */

static ERL_NIF_TERM nif_reply(ErlNifEnv* env, int argc,
                              const ERL_NIF_TERM argv[]) {
    (void)argc;

    ErlNifUInt64 ref = 0;
    if (!enif_get_uint64(env, argv[0], &ref)) {
        return make_badarg(env);
    }

    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[1], &bin)) {
        return make_badarg(env);
    }

    int ok = sync_deliver((uint64_t)ref, bin.data, (int64_t)bin.size);
    if (ok) {
        return ATOM_OK;
    }
    return make_error(env, ATOM_REPLY_UNKNOWN);
}

/* ============================================================================
 * Sync timeout configuration
 * ============================================================================ */

static ERL_NIF_TERM nif_set_sync_timeout(ErlNifEnv* env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    (void)argc;
    ErlNifUInt64 ms = 0;
    if (!enif_get_uint64(env, argv[0], &ms)) {
        return make_badarg(env);
    }
    if (ms < 100) ms = 100;
    g_sync_timeout_ms = (ErlNifTime)ms;
    return ATOM_OK;
}

static ERL_NIF_TERM nif_get_sync_timeout(ErlNifEnv* env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    return enif_make_uint64(env, (ErlNifUInt64)g_sync_timeout_ms);
}

/* ============================================================================
 * Local execution thunks
 * ============================================================================ */

static ERL_NIF_TERM nif_local_call(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    AppHandleRes* app = get_app_handle_res(env, argv[0]);
    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (app == NULL || prm == NULL) return make_badarg(env);

    TDataHnd res = b->LF_LocalCall(app->handle, prm->handle);
    if (res == NULL) return make_error(env, ATOM_CALL_FAILED);
    ERL_NIF_TERM term = make_data_handle_term(env, res);
    if (enif_is_identical(term, ATOM_ENOMEM)) {
        b->LF_FreeData(res);
        return make_error(env, ATOM_ENOMEM);
    }
    return term;
}

static ERL_NIF_TERM nif_local_notify(ErlNifEnv* env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    AppHandleRes* app = get_app_handle_res(env, argv[0]);
    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (app == NULL || prm == NULL) return make_badarg(env);
    b->LF_LocalNotify(app->handle, prm->handle);
    return ATOM_OK;
}

/* ============================================================================
 * Network preparation thunks
 * ============================================================================ */

static ERL_NIF_TERM nif_reset_prepare(ErlNifEnv* env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();
    b->LF_ResetPrepare();
    return ATOM_OK;
}

static ERL_NIF_TERM nif_prepare_service(ErlNifEnv* env, int argc,
                                        const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* listen = NULL;
    char* physics = NULL;
    if (!get_c_string(env, argv[0], &listen)) return make_badarg(env);
    if (!get_c_string(env, argv[1], &physics)) { free(listen); return make_badarg(env); }
    int tag = b->LF_PrepareService(listen, physics);
    free(listen); free(physics);
    return enif_make_int(env, tag);
}

static ERL_NIF_TERM nif_prepare_client(ErlNifEnv* env, int argc,
                                       const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* addr = NULL;
    if (!get_c_string(env, argv[0], &addr)) return make_badarg(env);

    TAppHnd app_hnd = NULL;
    if (!enif_is_identical(argv[1], ATOM_UNDEFINED)) {
        AppHandleRes* app = get_app_handle_res(env, argv[1]);
        if (app == NULL) { free(addr); return make_badarg(env); }
        app_hnd = app->handle;
    }

    int tag = b->LF_PrepareClient(addr, app_hnd);
    free(addr);
    return enif_make_int(env, tag);
}

static ERL_NIF_TERM nif_prepare_done(ErlNifEnv* env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();
    int ret = b->LF_PrepareDone();
    return enif_make_int(env, ret);
}

static ERL_NIF_TERM nif_exit_main_thread(ErlNifEnv* env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();
    b->LF_ExitMainThread();
    return ATOM_OK;
}

/* ============================================================================
 * Remote invocation thunks
 * ============================================================================ */

static ERL_NIF_TERM nif_call(ErlNifEnv* env, int argc,
                             const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* app = NULL;
    if (!get_c_string(env, argv[0], &app)) return make_badarg(env);

    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) { free(app); return make_badarg(env); }

    ErlNifUInt64 timeout = 0;
    if (!enif_get_uint64(env, argv[2], &timeout)) {
        free(app); return make_badarg(env);
    }

    TDataHnd res = b->LF_Call(app, prm->handle, (uint64_t)timeout);
    free(app);

    if (res == NULL) return make_error(env, ATOM_CALL_FAILED);
    ERL_NIF_TERM term = make_data_handle_term(env, res);
    if (enif_is_identical(term, ATOM_ENOMEM)) {
        b->LF_FreeData(res);
        return make_error(env, ATOM_ENOMEM);
    }
    return term;
}

static ERL_NIF_TERM nif_notify(ErlNifEnv* env, int argc,
                               const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* app = NULL;
    if (!get_c_string(env, argv[0], &app)) return make_badarg(env);
    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) { free(app); return make_badarg(env); }
    b->LF_Notify(app, prm->handle);
    free(app);
    return ATOM_OK;
}

static ERL_NIF_TERM nif_sequenced_notify(ErlNifEnv* env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* app = NULL;
    if (!get_c_string(env, argv[0], &app)) return make_badarg(env);
    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) { free(app); return make_badarg(env); }
    b->LF_Sequenced_Notify(app, prm->handle);
    free(app);
    return ATOM_OK;
}

/* ============================================================================
 * Options and diagnostics thunks
 * ============================================================================ */

static ERL_NIF_TERM nif_set_option(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* opt = NULL;
    char* val = NULL;
    if (!get_c_string(env, argv[0], &opt)) return make_badarg(env);
    if (!get_c_string(env, argv[1], &val)) { free(opt); return make_badarg(env); }
    b->LF_SetOption(opt, val);
    free(opt); free(val);
    return ATOM_OK;
}

static ERL_NIF_TERM nif_get_status_count(ErlNifEnv* env, int argc,
                                         const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();
    return enif_make_int(env, b->LF_GetStatusCount());
}

static ERL_NIF_TERM nif_get_status(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();
    const char* s = b->LF_GetStatus();
    return make_binary_from_cstr(env, s);
}

static ERL_NIF_TERM nif_post_status(ErlNifEnv* env, int argc,
                                    const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* s = NULL;
    if (!get_c_string(env, argv[0], &s)) return make_badarg(env);
    b->LF_PostStatus(s);
    free(s);
    return ATOM_OK;
}

static ERL_NIF_TERM nif_check_main_thread(ErlNifEnv* env, int argc,
                                          const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();
    return (b->LF_CheckMainThread() != 0) ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM nif_check_app(ErlNifEnv* env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* name = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);
    int r = b->LF_CheckApp(name);
    free(name);
    return (r != 0) ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM nif_check_api(ErlNifEnv* env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* app = NULL;
    char* api = NULL;
    if (!get_c_string(env, argv[0], &app)) return make_badarg(env);
    if (!get_c_string(env, argv[1], &api)) { free(app); return make_badarg(env); }
    int r = b->LF_CheckApi(app, api);
    free(app); free(api);
    return (r != 0) ? ATOM_TRUE : ATOM_FALSE;
}

/* ============================================================================
 * Shutdown thunk
 * ============================================================================ */

static ERL_NIF_TERM nif_shutdown(ErlNifEnv* env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();

    /* Mark the sync bridge as shutting down so any thread blocked
     * in sync_wait returns on its next poll tick. */
    sync_wake_all();

    b->LF_Shutdown();
    return ATOM_OK;
}

/* ============================================================================
 * Network event thunk
 * ============================================================================ */

static ERL_NIF_TERM nif_set_network_event(ErlNifEnv* env, int argc,
                                          const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    LF_NetworkEventFunc on_connect = NULL;
    LF_NetworkEventFunc on_disconnect = NULL;

    if (!enif_is_identical(argv[0], ATOM_UNDEFINED)) {
        ErlNifPid pid;
        if (!enif_get_local_pid(env, argv[0], &pid)) return make_badarg(env);
        g_net_connect_pid = pid;
        g_net_connect_set = 1;
        on_connect = lf_net_connect_cb;
    } else {
        g_net_connect_set = 0;
    }

    if (!enif_is_identical(argv[1], ATOM_UNDEFINED)) {
        ErlNifPid pid;
        if (!enif_get_local_pid(env, argv[1], &pid)) return make_badarg(env);
        g_net_disconnect_pid = pid;
        g_net_disconnect_set = 1;
        on_disconnect = lf_net_disconnect_cb;
    } else {
        g_net_disconnect_set = 0;
    }

    b->LF_Set_Network_Event(on_connect, on_disconnect);
    return ATOM_OK;
}

/* ============================================================================
 * NIF function table
 * ============================================================================ */

static ErlNifFunc nif_funcs[] = {
    /* Data handle */
    {"create_data",           1, nif_create_data,           0},
    {"create_data_permanent", 1, nif_create_data_permanent, 0},
    {"free_data",             1, nif_free_data,             0},
    {"get_buffer",            1, nif_get_buffer,            0},
    {"write_buffer",          2, nif_write_buffer,          0},
    {"read_buffer",           2, nif_read_buffer,           0},
    {"get_pos",               1, nif_get_pos,               0},
    {"set_pos",               2, nif_set_pos,               0},
    {"get_size",              1, nif_get_size,              0},
    {"set_size",              2, nif_set_size,              0},

    /* App handle */
    {"create_app",            2, nif_create_app,            0},
    {"free_app",              1, nif_free_app,              0},
    {"generate_app_name",     0, nif_generate_app_name,     0},
    {"get_app_name",          1, nif_get_app_name,          0},
    {"bind_app",              1, nif_bind_app,              0},

    /* API registration */
    {"register_call",         4, nif_register_call,         0},
    {"register_call_sync",    4, nif_register_call_sync,    0},
    {"register_notify",       4, nif_register_notify,       0},
    {"unregister",            2, nif_unregister,            0},

    /* Sync bridge */
    {"reply",                 2, nif_reply,                 0},
    {"set_sync_timeout",      1, nif_set_sync_timeout,      0},
    {"get_sync_timeout",      0, nif_get_sync_timeout,      0},

    /* Local execution */
    {"local_call",            2, nif_local_call,            ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"local_notify",          2, nif_local_notify,          ERL_NIF_DIRTY_JOB_IO_BOUND},

    /* Network preparation */
    {"reset_prepare",         0, nif_reset_prepare,         0},
    {"prepare_service",       2, nif_prepare_service,       0},
    {"prepare_client",        2, nif_prepare_client,        0},
    {"prepare_done",          0, nif_prepare_done,          ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"exit_main_thread",      0, nif_exit_main_thread,      ERL_NIF_DIRTY_JOB_IO_BOUND},

    /* Remote invocation */
    {"call",                  3, nif_call,                  ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"notify",                2, nif_notify,                0},
    {"sequenced_notify",      2, nif_sequenced_notify,      0},

    /* Options and diagnostics */
    {"set_option",            2, nif_set_option,            0},
    {"get_status_count",      0, nif_get_status_count,      0},
    {"get_status",            0, nif_get_status,            0},
    {"post_status",           1, nif_post_status,           0},
    {"check_main_thread",     0, nif_check_main_thread,     0},
    {"check_app",             1, nif_check_app,             0},
    {"check_api",             2, nif_check_api,             0},

    /* Shutdown */
    {"shutdown",              0, nif_shutdown,              ERL_NIF_DIRTY_JOB_IO_BOUND},

    /* Network events */
    {"set_network_event",     2, nif_set_network_event,     0}
};

ERL_NIF_INIT(lingofuse_nif, nif_funcs,
             nif_load, NULL, nif_upgrade, nif_unload)