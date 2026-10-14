/*
 * lingofuse_nif.c
 *
 * Erlang NIF bridge for the LingoFuse C ABI (59 exports).
 *
 * This file exposes all 59 C ABI exports as NIF functions, wraps
 * both handle kinds in Erlang resource objects, and provides a
 * callback dispatch bridge that forwards Call / Notify / Async /
 * Network events to registered Erlang processes.
 *
 * Callback modes
 * --------------
 *   ASYNC (register_call/4):
 *     The C callback sends {lf_call, Api, Payload} to the registered
 *     Erlang process and returns immediately. The LingoFuse output
 *     handle is left empty.
 *
 *   SYNC  (register_call_sync/4):
 *     The C callback sends {lf_call, Ref, Api, Payload} and then
 *     BLOCKS until either reply(Ref, Bin) is called or the sync
 *     timeout expires.
 *
 *   P2P   (register_p2p_call[_sync]/4, register_p2p_notify/4):
 *     Same shapes as the App-bound variants, but the message tag is
 *     {lf_p2p_call, ...} / {lf_p2p_notify, ...} and the API is
 *     registered into the process-wide P2P namespace.
 *
 *   IDENTITY (Options = #{with_identity => true}):
 *     The message gains one trailing element, an Erlang map
 *     #{uid => <<_:256>>, p2p_name => Binary}. The default (absent
 *     option) preserves the legacy message shapes exactly.
 *
 * Async invocation
 * ----------------
 *   Erlang: {ok, Ref} = async_call(App, Param, ReplyPid, Options)
 *   Result: {lf_async_result, Ref, {ok, Bin} | {error, Reason}}
 *
 *   The C side allocates an AsyncOp in a global registry, keyed by a
 *   monotonically increasing uint64_t ref. The ref is passed to the C
 *   ABI as (void*)(uintptr_t)ref. The single shared trampoline
 *   lf_async_result_cb looks up the op, builds the result message,
 *   enif_send's it to ReplyPid, and frees the op.
 *
 *   Dispatch failure (LF_Async_* returns non-1) aborts the op
 *   immediately, so the Erlang side never sees a stale op.
 *
 *   Stale ops whose callback never fires are lazily reclaimed on the
 *   next async_call, after a 10-minute idle window. The window is
 *   deliberately generous: the C4 mesh may hold a request for a long
 *   time on a slow link.
 *
 * Side data
 * ---------
 *   LF_Get_P2P_UID / LF_Get_P2P_Name are valid ONLY on the INPUT
 *   handle of a registered callback. The NIF extracts the identity
 *   once, copies it into a freshly allocated Erlang binary, and
 *   discards the transient C pointer immediately. The extraction is
 *   performed only when the callback was registered with
 *   with_identity = true.
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
 * storage keyword.
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
 * Constants
 * ============================================================================ */

/* Idle window after which an unreferenced AsyncOp is reclaimed on the
 * next async_call. Ten minutes matches the C4 data-handle idle window
 * and is deliberately generous for slow links. */
#define LF_ASYNC_OP_IDLE_MS (10 * 60 * 1000)

/* Poll interval used by sync_wait. Small enough to keep reply latency
 * low, large enough that concurrent waiters do not create mutex
 * contention. */
#define LF_SYNC_POLL_INTERVAL_MS 5

/* Default sync callback timeout, in milliseconds. Configurable via
 * set_sync_timeout/1. */
#define LF_SYNC_DEFAULT_TIMEOUT_MS 30000

/* Maximum length of a P2P name we copy from the C ABI. Names longer
 * than this are truncated. The framework does not impose a length
 * limit, but a name that long would be pathological. */
#define LF_P2P_NAME_MAX 256

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

/* New atoms for v2 ABI */
static ERL_NIF_TERM ATOM_LF_P2P_CALL;
static ERL_NIF_TERM ATOM_LF_P2P_NOTIFY;
static ERL_NIF_TERM ATOM_LF_ASYNC_RESULT;
static ERL_NIF_TERM ATOM_ASYNC_DISPATCH_FAILED;
static ERL_NIF_TERM ATOM_NO_RESULT;
static ERL_NIF_TERM ATOM_UID;
static ERL_NIF_TERM ATOM_P2P_NAME;

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
    uint64_t            ref;
    int                 has_result;
    int                 cancelled;
    void*               result_data;
    int64_t             result_size;
    struct PendingSync* next;
} PendingSync;

static PendingSync*   g_sync_head     = NULL;
static ErlNifMutex*   g_sync_mutex    = NULL;
static uint64_t       g_sync_next_ref = 1;
static ErlNifTime     g_sync_timeout_ms = LF_SYNC_DEFAULT_TIMEOUT_MS;

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
 * ----------------------------------------------------------------------------
 * A single table holds both App-bound and process-wide P2P callbacks.
 * The `is_p2p` flag distinguishes them at dispatch and unregister
 * time. The `with_identity` flag controls whether the callback
 * dispatch extracts the sender's side data and appends it to the
 * message.
 * ============================================================================ */

typedef struct CallbackEntry {
    void*  trigger;                 /* == this entry's address       */
    char*  api_name;
    ErlNifPid caller_pid;
    int    is_notify;
    int    is_sync;
    int    is_p2p;
    int    with_identity;
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
                                     int is_sync,
                                     int is_p2p,
                                     int with_identity) {
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

    e->caller_pid    = *pid;
    e->is_notify     = is_notify;
    e->is_sync       = is_sync;
    e->is_p2p        = is_p2p;
    e->with_identity = with_identity;
    e->dead          = 0;
    e->trigger       = e;

    enif_mutex_lock(g_callbacks_mutex);
    e->next = g_callbacks;
    g_callbacks = e;
    enif_mutex_unlock(g_callbacks_mutex);

    return e;
}

/* Mark every callback with the given API name as dead. Used by both
 * unregister/2 and unregister_p2p/1. The `is_p2p` filter allows the
 * two namespaces to be cleaned up independently even when they share
 * an API name. */
static void callback_mark_dead_by_name(const char* api_name, int is_p2p)
{
    enif_mutex_lock(g_callbacks_mutex);
    for (CallbackEntry* e = g_callbacks; e != NULL; e = e->next) {
        if (e->api_name != NULL
            && e->is_p2p == is_p2p
            && strcmp(e->api_name, api_name) == 0) {
            e->dead = 1;
        }
    }
    enif_mutex_unlock(g_callbacks_mutex);
}

static void callback_free_all(void)
{
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
 * Async operation registry
 * ----------------------------------------------------------------------------
 * A global table maps a monotonically increasing uint64_t ref to an
 * AsyncOp. The ref is passed to the C ABI as (void*)(uintptr_t)ref;
 * the single shared trampoline lf_async_result_cb uses the ref to
 * look up the op when the callback fires.
 *
 * Lifetime:
 *   - async_op_register allocates and links a new op.
 *   - async_op_take removes and returns an op, or NULL.
 *   - async_op_abort is used by the dispatcher when the C ABI
 *     rejected the request; it aborts the op immediately.
 *   - async_op_gc_stale reclaims ops whose callback never fired.
 *     It is invoked lazily on every async_op_register.
 * ============================================================================ */

typedef struct AsyncOp {
    uint64_t          ref;
    ErlNifPid         reply_pid;
    int64_t           created_at_ms;
    struct AsyncOp*   next;
} AsyncOp;

static AsyncOp*      g_async_head     = NULL;
static ErlNifMutex*  g_async_mutex    = NULL;
static uint64_t      g_async_next_ref = 1;

static void async_op_gc_stale_locked(ErlNifTime now)
{
    AsyncOp** pp = &g_async_head;
    while (*pp != NULL) {
        AsyncOp* cur = *pp;
        if (now - cur->created_at_ms > LF_ASYNC_OP_IDLE_MS) {
            *pp = cur->next;
            free(cur);
        } else {
            pp = &cur->next;
        }
    }
}

static uint64_t async_op_register(const ErlNifPid* reply_pid)
{
    if (g_async_mutex == NULL) return 0;

    AsyncOp* op = (AsyncOp*)calloc(1, sizeof(AsyncOp));
    if (op == NULL) return 0;

    ErlNifTime now = enif_monotonic_time(ERL_NIF_MSEC);

    enif_mutex_lock(g_async_mutex);
    async_op_gc_stale_locked(now);

    op->ref           = g_async_next_ref++;
    if (g_async_next_ref == 0) g_async_next_ref = 1;   /* wrap guard */
    op->reply_pid     = *reply_pid;
    op->created_at_ms = now;
    op->next          = g_async_head;
    g_async_head      = op;

    uint64_t ref = op->ref;
    enif_mutex_unlock(g_async_mutex);
    return ref;
}

static AsyncOp* async_op_take(uint64_t ref)
{
    if (g_async_mutex == NULL) return NULL;
    AsyncOp* found = NULL;
    enif_mutex_lock(g_async_mutex);
    AsyncOp** pp = &g_async_head;
    while (*pp != NULL) {
        if ((*pp)->ref == ref) {
            found = *pp;
            *pp = found->next;
            break;
        }
        pp = &(*pp)->next;
    }
    enif_mutex_unlock(g_async_mutex);
    return found;
}

static void async_op_abort(uint64_t ref)
{
    AsyncOp* op = async_op_take(ref);
    if (op != NULL) free(op);
}

static void async_op_free_all(void)
{
    if (g_async_mutex == NULL) return;
    enif_mutex_lock(g_async_mutex);
    AsyncOp* op = g_async_head;
    g_async_head = NULL;
    enif_mutex_unlock(g_async_mutex);

    while (op != NULL) {
        AsyncOp* next = op->next;
        free(op);
        op = next;
    }
}

/* ============================================================================
 * Identity extraction
 * ----------------------------------------------------------------------------
 * Side-data snapshot extracted from an INPUT handle. The uid and
 * p2p_name buffers are copied immediately; the transient C pointers
 * are never retained.
 * ============================================================================ */

typedef struct {
    uint8_t uid[32];
    char    p2p_name[LF_P2P_NAME_MAX];
    int     has_uid;
    int     has_name;
} LfIdentity;

static void extract_identity(TDataHnd input, LfIdentity* out)
{
    memset(out, 0, sizeof(*out));
    if (input == NULL) return;

    const LF_Bindings* b = lf_loader_get();
    if (b == NULL) return;

    if (b->LF_Get_P2P_UID != NULL) {
        const TP2P_UID* uid_ptr = b->LF_Get_P2P_UID(input);
        if (uid_ptr != NULL) {
            memcpy(out->uid, uid_ptr->bytes, 32);
            out->has_uid = 1;
        }
    }

    if (b->LF_Get_P2P_Name != NULL) {
        const char* name_ptr = b->LF_Get_P2P_Name(input);
        if (name_ptr != NULL && name_ptr[0] != '\0') {
            strncpy(out->p2p_name, name_ptr, LF_P2P_NAME_MAX - 1);
            out->p2p_name[LF_P2P_NAME_MAX - 1] = '\0';
            out->has_name = 1;
        }
    }
}

static ERL_NIF_TERM make_identity_map(ErlNifEnv* env,
                                      const LfIdentity* id)
{
    ErlNifBinary uid_bin;
    if (!enif_alloc_binary(32, &uid_bin)) {
        return ATOM_ENOMEM;
    }
    if (id->has_uid) {
        memcpy(uid_bin.data, id->uid, 32);
    } else {
        memset(uid_bin.data, 0, 32);
    }
    ERL_NIF_TERM uid_term = enif_make_binary(env, &uid_bin);

    size_t name_len = id->has_name ? strlen(id->p2p_name) : 0;
    ErlNifBinary name_bin;
    if (!enif_alloc_binary(name_len, &name_bin)) {
        return ATOM_ENOMEM;
    }
    if (name_len > 0) {
        memcpy(name_bin.data, id->p2p_name, name_len);
    }
    ERL_NIF_TERM name_term = enif_make_binary(env, &name_bin);

    ERL_NIF_TERM keys[2]   = { ATOM_UID, ATOM_P2P_NAME };
    ERL_NIF_TERM values[2] = { uid_term, name_term };
    ERL_NIF_TERM map_term;
    if (!enif_make_map_from_arrays(env, keys, values, 2, &map_term)) {
        return ATOM_ENOMEM;
    }
    return map_term;
}

/* ============================================================================
 * Callback trampolines
 * ============================================================================ */
/* Read the full content of a data handle as an Erlang binary, with
 * ONE trailing NUL byte stripped if present.
 *
 * Why strip the NUL
 * -----------------
 * Every string producer in the LingoFuse toolchain appends a single
 * NUL byte as the wire framing (Pascal LF_WriteString, Python
 * lf_io.write_string, C++ io::write_string, JavaScript
 * lf-io.writeString). Every string reader strips that framing byte
 * before handing the payload to user code (Pascal LF_ReadString,
 * Python lf_io.read_string, C++ io::read_string, JavaScript
 * lf-io.readString).
 *
 * The Erlang callback messages are the ONE place in the toolchain
 * where a payload is delivered as a raw binary. If the framing NUL
 * were exposed here, a caller who passes the payload to a JSON
 * parser would trip on it, which is exactly the failure the
 * identity suite hit. Stripping one trailing NUL restores the
 * cross-language invariant: what the callback receives is the
 * payload, not the payload plus its framing byte.
 *
 * Stripping is one-shot: a payload that does not end in NUL is
 * returned unchanged, and a payload that is just the single NUL
 * byte becomes an empty binary.
 *
 * A NULL handle, or a handle with no bytes, yields an empty binary.
 *
 * Returns 1 on success, 0 on allocation failure. The result term is
 * stored in *out_term. */
static int read_and_strip_nul(ErlNifEnv* env,
                              TDataHnd hnd,
                              ERL_NIF_TERM* out_term)
{
    const LF_Bindings* b = lf_loader_get();
    int64_t size = 0;

    if (b != NULL && hnd != NULL) {
        size = b->LF_GetSize(hnd);
    }

    if (size <= 0) {
        ErlNifBinary empty;
        if (!enif_alloc_binary(0, &empty)) {
            *out_term = ATOM_ENOMEM;
            return 0;
        }
        *out_term = enif_make_binary(env, &empty);
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
        ErlNifBinary empty;
        if (!enif_alloc_binary(0, &empty)) {
            *out_term = ATOM_ENOMEM;
            return 0;
        }
        *out_term = enif_make_binary(env, &empty);
        return 1;
    }

    if (bin.data[size - 1] == 0) {
        size_t new_size = (size_t)(size - 1);
        ErlNifBinary trimmed;
        if (!enif_alloc_binary(new_size, &trimmed)) {
            enif_release_binary(&bin);
            *out_term = ATOM_ENOMEM;
            return 0;
        }
        if (new_size > 0) {
            memcpy(trimmed.data, bin.data, new_size);
        }
        enif_release_binary(&bin);
        *out_term = enif_make_binary(env, &trimmed);
        return 1;
    }

    *out_term = enif_make_binary(env, &bin);
    return 1;
}


static int write_to_output_handle(TDataHnd output,
                                  const void* data,
                                  int64_t size)
{
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

/* Build the callback message. The shape depends on the entry:
 *
 *   async Call (App)     {lf_call, Api, Payload}          [+ Identity]
 *   sync  Call (App)     {lf_call, Ref, Api, Payload}     [+ Identity]
 *   async Call (P2P)     {lf_p2p_call, Api, Payload}      [+ Identity]
 *   sync  Call (P2P)     {lf_p2p_call, Ref, Api, Payload} [+ Identity]
 *   Notify (App)         {lf_notify, Api, Payload}        [+ Identity]
 *   Notify (P2P)         {lf_p2p_notify, Api, Payload}    [+ Identity]
 */
static ERL_NIF_TERM build_callback_message(ErlNifEnv* env,
                                           const CallbackEntry* e,
                                           uint64_t ref,
                                           ERL_NIF_TERM api_term,
                                           ERL_NIF_TERM payload_term,
                                           const LfIdentity* id)
{
    ERL_NIF_TERM terms[5];
    unsigned int n = 0;

    if (e->is_notify) {
        terms[n++] = e->is_p2p ? ATOM_LF_P2P_NOTIFY : ATOM_LF_NOTIFY;
    } else {
        terms[n++] = e->is_p2p ? ATOM_LF_P2P_CALL : ATOM_LF_CALL;
        if (e->is_sync) {
            terms[n++] = enif_make_uint64(env, ref);
        }
    }
    terms[n++] = api_term;
    terms[n++] = payload_term;
    if (e->with_identity && id != NULL) {
        terms[n++] = make_identity_map(env, id);
    }
    return enif_make_tuple_from_array(env, terms, n);
}

/* Thread-local stash used to pass the sync reply payload from
 * dispatch_to_process back to lf_call_callback, which owns the output
 * handle. Every LingoFuse worker thread that enters lf_call_callback
 * does so for exactly one call at a time. */
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
                                int is_call)
{
    if (e == NULL || e->dead) return;

    ErlNifEnv* msg_env = enif_alloc_env();
    if (msg_env == NULL) return;

    /* Extract identity only if requested. */
    LfIdentity id_snapshot;
    int use_id = e->with_identity;
    if (use_id) {
        extract_identity(input, &id_snapshot);
    }

    ERL_NIF_TERM payload;
    if (!read_and_strip_nul(msg_env, input, &payload)) {
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

            ERL_NIF_TERM msg = build_callback_message(
                msg_env, e, ref, api_term, payload,
                use_id ? &id_snapshot : NULL);

            if (!enif_send(NULL, &e->caller_pid, msg_env, msg)) {
                sync_unregister(&pending);
                enif_free_env(msg_env);
                return;
            }

            int got = sync_wait(&pending);
            sync_unregister(&pending);

            if (got && pending.result_data != NULL) {
                lf_sync_stash_result(pending.result_data,
                                     pending.result_size);
                pending.result_data = NULL;
            } else if (pending.result_data != NULL) {
                free(pending.result_data);
                pending.result_data = NULL;
            }

            enif_free_env(msg_env);
            return;
        } else {
            ERL_NIF_TERM msg = build_callback_message(
                msg_env, e, 0, api_term, payload,
                use_id ? &id_snapshot : NULL);
            (void)enif_send(NULL, &e->caller_pid, msg_env, msg);
            enif_free_env(msg_env);
            return;
        }
    } else {
        ERL_NIF_TERM msg = build_callback_message(
            msg_env, e, 0, api_term, payload,
            use_id ? &id_snapshot : NULL);
        (void)enif_send(NULL, &e->caller_pid, msg_env, msg);
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

/* Single shared trampoline for every asynchronous result callback.
 * `data` is the uint64_t ref cast to a void*. */
static void LF_CDECL lf_async_result_cb(void* data, TDataHnd result) {
    uint64_t ref = (uint64_t)(uintptr_t)data;
    AsyncOp* op = async_op_take(ref);
    if (op == NULL) return;   /* already aborted or GC'd */

    const LF_Bindings* b = lf_loader_get();
    if (b == NULL) {
        free(op);
        return;
    }

    ErlNifEnv* msg_env = enif_alloc_env();
    if (msg_env == NULL) {
        free(op);
        return;
    }

    ERL_NIF_TERM result_term;

    if (result != NULL) {
        ERL_NIF_TERM payload;
        if (read_and_strip_nul(msg_env, result, &payload)) {
            result_term = enif_make_tuple2(msg_env, ATOM_OK, payload);
        } else {
            result_term = enif_make_tuple2(msg_env, ATOM_ERROR, ATOM_ENOMEM);
        }
    } else {
        result_term = enif_make_tuple2(msg_env, ATOM_ERROR, ATOM_NO_RESULT);
    }

    ERL_NIF_TERM msg = enif_make_tuple3(
        msg_env,
        ATOM_LF_ASYNC_RESULT,
        enif_make_uint64(msg_env, ref),
        result_term);

    (void)enif_send(NULL, &op->reply_pid, msg_env, msg);
    enif_free_env(msg_env);
    free(op);
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
    (void)enif_send(NULL, &g_net_connect_pid, msg_env, msg);
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
    (void)enif_send(NULL, &g_net_disconnect_pid, msg_env, msg);
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

static DataHandleRes* get_data_handle_res(ErlNifEnv* env,
                                          ERL_NIF_TERM term) {
    DataHandleRes* r = NULL;
    if (!enif_get_resource(env, term, g_data_handle_type, (void**)&r)) {
        return NULL;
    }
    if (r == NULL || r->handle == NULL) return NULL;
    return r;
}

static AppHandleRes* get_app_handle_res(ErlNifEnv* env,
                                        ERL_NIF_TERM term) {
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

/* Read a 32-byte UID binary into a TP2P_UID struct. Returns 1 on
 * success, 0 on any shape mismatch. */
static int get_uid_arg(ErlNifEnv* env,
                       ERL_NIF_TERM term,
                       TP2P_UID* out) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin)) return 0;
    if (bin.size != 32) return 0;
    memcpy(out->bytes, bin.data, 32);
    return 1;
}

/* Read the with_identity flag from an Options map. The map may be the
 * atom `undefined` (no options) or a map. Missing key or non-true
 * value means false. */
static int get_options_with_identity(ErlNifEnv* env, ERL_NIF_TERM opts) {
    if (enif_is_identical(opts, ATOM_UNDEFINED)) return 0;
    if (!enif_is_map(env, opts)) return 0;

    ERL_NIF_TERM key = enif_make_atom(env, "with_identity");
    ERL_NIF_TERM value;
    if (!enif_get_map_value(env, opts, key, &value)) return 0;
    return enif_is_identical(value, ATOM_TRUE) ? 1 : 0;
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

    ATOM_LF_P2P_CALL         = enif_make_atom(env, "lf_p2p_call");
    ATOM_LF_P2P_NOTIFY       = enif_make_atom(env, "lf_p2p_notify");
    ATOM_LF_ASYNC_RESULT     = enif_make_atom(env, "lf_async_result");
    ATOM_ASYNC_DISPATCH_FAILED =
        enif_make_atom(env, "async_dispatch_failed");
    ATOM_NO_RESULT           = enif_make_atom(env, "no_result");
    ATOM_UID                 = enif_make_atom(env, "uid");
    ATOM_P2P_NAME            = enif_make_atom(env, "p2p_name");

    g_data_handle_type = enif_open_resource_type(
        env, NULL, "lf_data_handle",
        data_handle_dtor, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL);
    if (g_data_handle_type == NULL) {
        fprintf(stderr,
                "[lingofuse_nif] failed to open data handle resource type\n");
        return -1;
    }

    g_app_handle_type = enif_open_resource_type(
        env, NULL, "lf_app_handle",
        app_handle_dtor, ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL);
    if (g_app_handle_type == NULL) {
        fprintf(stderr,
                "[lingofuse_nif] failed to open app handle resource type\n");
        return -1;
    }

    if (g_callbacks_mutex == NULL) {
        g_callbacks_mutex = enif_mutex_create("lf_callbacks_mutex");
        if (g_callbacks_mutex == NULL) {
            fprintf(stderr,
                    "[lingofuse_nif] failed to create callbacks mutex\n");
            return -1;
        }
    }

    if (g_sync_mutex == NULL) {
        g_sync_mutex = enif_mutex_create("lf_sync_mutex");
        if (g_sync_mutex == NULL) {
            fprintf(stderr,
                    "[lingofuse_nif] failed to create sync mutex\n");
            return -1;
        }
    }

    if (g_async_mutex == NULL) {
        g_async_mutex = enif_mutex_create("lf_async_mutex");
        if (g_async_mutex == NULL) {
            fprintf(stderr,
                    "[lingofuse_nif] failed to create async mutex\n");
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

    if (g_sync_mutex != NULL) {
        sync_wake_all();
    }

    async_op_free_all();
    callback_free_all();

    if (g_async_mutex != NULL) {
        enif_mutex_destroy(g_async_mutex);
        g_async_mutex = NULL;
    }
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
 * Data handle thunks (10, unchanged)
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
 * Application handle thunks (5, unchanged)
 * ============================================================================ */

static ERL_NIF_TERM nif_create_app(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* name = NULL;
    char* desc = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);
    if (!get_c_string(env, argv[1], &desc)) {
        free(name); return make_badarg(env);
    }

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
 * ----------------------------------------------------------------------------
 * Generic implementation shared by App-bound and process-wide P2P
 * registrations, in both ASYNC and SYNC variants.
 *
 * Argument layout:
 *   App-bound:  App, Name, Desc, Pid, Options
 *   P2P:        Name, Desc, Pid, Options
 *
 * Options is a map, or the atom `undefined` for "no options".
 * ============================================================================ */

static int register_common_ex(ErlNifEnv* env,
                              int argc,
                              const ERL_NIF_TERM argv[],
                              int is_notify,
                              int is_sync,
                              int is_p2p,
                              ERL_NIF_TERM* out)
{
    (void)argc;

    const LF_Bindings* b = lf_loader_get();
    if (b == NULL) {
        *out = make_error(env, ATOM_NOT_LOADED);
        return 0;
    }

    TAppHnd app_hnd = NULL;
    ERL_NIF_TERM name_term, desc_term, pid_term, opts_term;

    if (is_p2p) {
        name_term = argv[0];
        desc_term = argv[1];
        pid_term  = argv[2];
        opts_term = argv[3];
    } else {
        AppHandleRes* app = get_app_handle_res(env, argv[0]);
        if (app == NULL) { *out = make_badarg(env); return 0; }
        app_hnd   = app->handle;
        name_term = argv[1];
        desc_term = argv[2];
        pid_term  = argv[3];
        opts_term = argv[4];
    }

    char* name = NULL;
    char* desc = NULL;
    if (!get_c_string(env, name_term, &name)) {
        *out = make_badarg(env);
        return 0;
    }
    if (!get_c_string(env, desc_term, &desc)) {
        free(name);
        *out = make_badarg(env);
        return 0;
    }

    ErlNifPid pid;
    if (!enif_get_local_pid(env, pid_term, &pid)) {
        free(name); free(desc);
        *out = make_badarg(env);
        return 0;
    }

    int with_identity = get_options_with_identity(env, opts_term);

    CallbackEntry* e = callback_alloc(name, &pid,
                                      is_notify, is_sync, is_p2p,
                                      with_identity);
    if (e == NULL) {
        free(name); free(desc);
        *out = make_error(env, ATOM_ENOMEM);
        return 0;
    }

    int ret;
    if (is_p2p) {
        if (is_notify) {
            ret = b->LF_Register_P2P_Notify(
                name, desc, e->trigger, lf_notify_callback);
        } else {
            ret = b->LF_Register_P2P_Call(
                name, desc, e->trigger, lf_call_callback);
        }
    } else {
        if (is_notify) {
            ret = b->LF_RegisterNotify(
                app_hnd, name, desc, e->trigger, lf_notify_callback);
        } else {
            ret = b->LF_RegisterCall(
                app_hnd, name, desc, e->trigger, lf_call_callback);
        }
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
    register_common_ex(env, argc, argv,
                       0 /* is_notify */, 0 /* is_sync */, 0 /* is_p2p */,
                       &out);
    return out;
}

static ERL_NIF_TERM nif_register_call_sync(ErlNifEnv* env, int argc,
                                           const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM out;
    register_common_ex(env, argc, argv,
                       0, 1, 0, &out);
    return out;
}

static ERL_NIF_TERM nif_register_notify(ErlNifEnv* env, int argc,
                                        const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM out;
    register_common_ex(env, argc, argv,
                       1, 0, 0, &out);
    return out;
}

static ERL_NIF_TERM nif_register_p2p_call(ErlNifEnv* env, int argc,
                                          const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM out;
    register_common_ex(env, argc, argv,
                       0, 0, 1, &out);
    return out;
}

static ERL_NIF_TERM nif_register_p2p_call_sync(ErlNifEnv* env, int argc,
                                               const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM out;
    register_common_ex(env, argc, argv,
                       0, 1, 1, &out);
    return out;
}

static ERL_NIF_TERM nif_register_p2p_notify(ErlNifEnv* env, int argc,
                                            const ERL_NIF_TERM argv[]) {
    ERL_NIF_TERM out;
    register_common_ex(env, argc, argv,
                       1, 0, 1, &out);
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
        callback_mark_dead_by_name(name, 0 /* app-bound */);
    }
    free(name);

    return (ret == 1) ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM nif_unregister_p2p(ErlNifEnv* env, int argc,
                                       const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* name = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);

    int ret = b->LF_Unregister_P2P(name);
    if (ret == 1) {
        callback_mark_dead_by_name(name, 1 /* P2P */);
    }
    free(name);

    return (ret == 1) ? ATOM_TRUE : ATOM_FALSE;
}

/* ============================================================================
 * Sync reply thunk (2, unchanged)
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
 * Local execution thunks (2, unchanged)
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
 * Network preparation thunks (5, unchanged)
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
    if (!get_c_string(env, argv[1], &physics)) {
        free(listen); return make_badarg(env);
    }
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

    /* Wake every pending sync waiter BEFORE tearing the C4 loop down.
     *
     * Why this is required
     * --------------------
     * A sync callback that the C ABI delivered to a dirty scheduler
     * thread may still be blocked in sync_wait, waiting for reply/2
     * from the BEAM side. If LF_ExitMainThread starts releasing C4
     * internal state while such a callback is still live, the next
     * accessor call from the callback touches freed memory and the
     * process dies with an ACCESS_VIOLATION.
     *
     * Setting every PendingSync's `cancelled` flag makes sync_wait
     * return on its next poll tick (within LF_SYNC_POLL_INTERVAL_MS),
     * so the callback unwinds cleanly before LF_ExitMainThread
     * proceeds. The same wake is already performed by nif_shutdown;
     * doing it here as well closes the window between the two calls.
     *
     * A caller whose sync reply arrives after this wake sees
     * {error, unknown_ref}, which is the documented behaviour for a
     * late reply.
     */
    sync_wake_all();

    b->LF_ExitMainThread();
    return ATOM_OK;
}

/* ============================================================================
 * Remote invocation thunks
 * ============================================================================ */

/* --- Synchronous, App name (3, unchanged) --- */

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

/* --- Synchronous, UID (3, new) --- */

static ERL_NIF_TERM nif_uid_call(ErlNifEnv* env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    TP2P_UID uid;
    if (!get_uid_arg(env, argv[0], &uid)) return make_badarg(env);

    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) return make_badarg(env);

    ErlNifUInt64 timeout = 0;
    if (!enif_get_uint64(env, argv[2], &timeout)) {
        return make_badarg(env);
    }

    TDataHnd res = b->LF_UID_Call(uid, prm->handle, (uint64_t)timeout);
    if (res == NULL) return make_error(env, ATOM_CALL_FAILED);
    ERL_NIF_TERM term = make_data_handle_term(env, res);
    if (enif_is_identical(term, ATOM_ENOMEM)) {
        b->LF_FreeData(res);
        return make_error(env, ATOM_ENOMEM);
    }
    return term;
}

static ERL_NIF_TERM nif_uid_notify(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    TP2P_UID uid;
    if (!get_uid_arg(env, argv[0], &uid)) return make_badarg(env);
    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) return make_badarg(env);
    b->LF_UID_Notify(uid, prm->handle);
    return ATOM_OK;
}

static ERL_NIF_TERM nif_uid_sequenced_notify(ErlNifEnv* env, int argc,
                                             const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    TP2P_UID uid;
    if (!get_uid_arg(env, argv[0], &uid)) return make_badarg(env);
    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) return make_badarg(env);
    b->LF_UID_Sequenced_Notify(uid, prm->handle);
    return ATOM_OK;
}

/* --- Synchronous, P2P name (3, new) --- */

static ERL_NIF_TERM nif_p2pname_call(ErlNifEnv* env, int argc,
                                     const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* name = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);

    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) { free(name); return make_badarg(env); }

    ErlNifUInt64 timeout = 0;
    if (!enif_get_uint64(env, argv[2], &timeout)) {
        free(name); return make_badarg(env);
    }

    TDataHnd res = b->LF_P2PNAME_Call(name, prm->handle,
                                      (uint64_t)timeout);
    free(name);

    if (res == NULL) return make_error(env, ATOM_CALL_FAILED);
    ERL_NIF_TERM term = make_data_handle_term(env, res);
    if (enif_is_identical(term, ATOM_ENOMEM)) {
        b->LF_FreeData(res);
        return make_error(env, ATOM_ENOMEM);
    }
    return term;
}

static ERL_NIF_TERM nif_p2pname_notify(ErlNifEnv* env, int argc,
                                       const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* name = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);
    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) { free(name); return make_badarg(env); }
    b->LF_P2PNAME_Notify(name, prm->handle);
    free(name);
    return ATOM_OK;
}

static ERL_NIF_TERM nif_p2pname_sequenced_notify(
    ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* name = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);
    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) { free(name); return make_badarg(env); }
    b->LF_P2PNAME_Sequenced_Notify(name, prm->handle);
    free(name);
    return ATOM_OK;
}

/* --- Asynchronous dispatcher (shared by 6 entry points) --- */

typedef enum {
    ASYNC_KIND_APP,
    ASYNC_KIND_APP_SEQ,
    ASYNC_KIND_UID,
    ASYNC_KIND_UID_SEQ,
    ASYNC_KIND_P2PNAME,
    ASYNC_KIND_P2PNAME_SEQ
} AsyncKind;

static ERL_NIF_TERM do_async_call(ErlNifEnv* env,
                                  int argc,
                                  const ERL_NIF_TERM argv[],
                                  AsyncKind kind)
{
    (void)argc;
    LF_ENSURE_LOADED();

    /* argv[0] = target  (binary; 32-byte binary for UID kinds)
     * argv[1] = param   (data handle)
     * argv[2] = reply_pid (local pid)
     */

    TP2P_UID uid;
    char* target_cstr = NULL;

    switch (kind) {
    case ASYNC_KIND_APP:
    case ASYNC_KIND_APP_SEQ:
    case ASYNC_KIND_P2PNAME:
    case ASYNC_KIND_P2PNAME_SEQ:
        if (!get_c_string(env, argv[0], &target_cstr)) {
            return make_badarg(env);
        }
        break;
    case ASYNC_KIND_UID:
    case ASYNC_KIND_UID_SEQ:
        memset(&uid, 0, sizeof(uid));
        if (!get_uid_arg(env, argv[0], &uid)) {
            return make_badarg(env);
        }
        break;
    }

    DataHandleRes* prm = get_data_handle_res(env, argv[1]);
    if (prm == NULL) {
        free(target_cstr);
        return make_badarg(env);
    }

    ErlNifPid reply_pid;
    if (!enif_get_local_pid(env, argv[2], &reply_pid)) {
        free(target_cstr);
        return make_badarg(env);
    }

    uint64_t ref = async_op_register(&reply_pid);
    if (ref == 0) {
        free(target_cstr);
        return make_error(env, ATOM_ENOMEM);
    }

    int rc = 0;
    void* data = (void*)(uintptr_t)ref;

    switch (kind) {
    case ASYNC_KIND_APP:
        rc = b->LF_Async_Call(target_cstr, prm->handle,
                              data, lf_async_result_cb);
        break;
    case ASYNC_KIND_APP_SEQ:
        rc = b->LF_Async_Sequenced_Call(target_cstr, prm->handle,
                                        data, lf_async_result_cb);
        break;
    case ASYNC_KIND_UID:
        rc = b->LF_UID_Async_Call(uid, prm->handle,
                                  data, lf_async_result_cb);
        break;
    case ASYNC_KIND_UID_SEQ:
        rc = b->LF_UID_Async_Sequenced_Call(uid, prm->handle,
                                            data, lf_async_result_cb);
        break;
    case ASYNC_KIND_P2PNAME:
        rc = b->LF_P2PNAME_Async_Call(target_cstr, prm->handle,
                                      data, lf_async_result_cb);
        break;
    case ASYNC_KIND_P2PNAME_SEQ:
        rc = b->LF_P2PNAME_Async_Sequenced_Call(target_cstr, prm->handle,
                                                data, lf_async_result_cb);
        break;
    }

    free(target_cstr);

    if (rc != 1) {
        async_op_abort(ref);
        return make_error(env, ATOM_ASYNC_DISPATCH_FAILED);
    }
    return enif_make_uint64(env, ref);
}

static ERL_NIF_TERM nif_async_call(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    return do_async_call(env, argc, argv, ASYNC_KIND_APP);
}

static ERL_NIF_TERM nif_async_sequenced_call(ErlNifEnv* env, int argc,
                                             const ERL_NIF_TERM argv[]) {
    return do_async_call(env, argc, argv, ASYNC_KIND_APP_SEQ);
}

static ERL_NIF_TERM nif_uid_async_call(ErlNifEnv* env, int argc,
                                       const ERL_NIF_TERM argv[]) {
    return do_async_call(env, argc, argv, ASYNC_KIND_UID);
}

static ERL_NIF_TERM nif_uid_async_sequenced_call(
    ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return do_async_call(env, argc, argv, ASYNC_KIND_UID_SEQ);
}

static ERL_NIF_TERM nif_p2pname_async_call(ErlNifEnv* env, int argc,
                                           const ERL_NIF_TERM argv[]) {
    return do_async_call(env, argc, argv, ASYNC_KIND_P2PNAME);
}

static ERL_NIF_TERM nif_p2pname_async_sequenced_call(
    ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return do_async_call(env, argc, argv, ASYNC_KIND_P2PNAME_SEQ);
}

/* ============================================================================
 * Query thunks
 * ============================================================================ */

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
    if (!get_c_string(env, argv[1], &api)) {
        free(app); return make_badarg(env);
    }
    int r = b->LF_CheckApi(app, api);
    free(app); free(api);
    return (r != 0) ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM nif_check_uid(ErlNifEnv* env, int argc,
                                  const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    TP2P_UID uid;
    if (!get_uid_arg(env, argv[0], &uid)) return make_badarg(env);
    int r = b->LF_Check_UID(uid);
    return (r != 0) ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM nif_check_uid_api(ErlNifEnv* env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    TP2P_UID uid;
    if (!get_uid_arg(env, argv[0], &uid)) return make_badarg(env);
    char* api = NULL;
    if (!get_c_string(env, argv[1], &api)) return make_badarg(env);
    int r = b->LF_Check_UID_Api(uid, api);
    free(api);
    return (r != 0) ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM nif_check_p2pname(ErlNifEnv* env, int argc,
                                      const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* name = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);
    int r = b->LF_Check_P2PNAME(name);
    free(name);
    return (r != 0) ? ATOM_TRUE : ATOM_FALSE;
}

static ERL_NIF_TERM nif_check_p2pname_api(ErlNifEnv* env, int argc,
                                          const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* name = NULL;
    char* api = NULL;
    if (!get_c_string(env, argv[0], &name)) return make_badarg(env);
    if (!get_c_string(env, argv[1], &api)) {
        free(name); return make_badarg(env);
    }
    int r = b->LF_Check_P2PNAME_Api(name, api);
    free(name); free(api);
    return (r != 0) ? ATOM_TRUE : ATOM_FALSE;
}

/* ============================================================================
 * Option and diagnostic thunks
 * ============================================================================ */

static ERL_NIF_TERM nif_set_option(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();
    char* opt = NULL;
    char* val = NULL;
    if (!get_c_string(env, argv[0], &opt)) return make_badarg(env);
    if (!get_c_string(env, argv[1], &val)) {
        free(opt); return make_badarg(env);
    }
    b->LF_SetOption(opt, val);
    free(opt); free(val);
    return ATOM_OK;
}

static ERL_NIF_TERM nif_get_option(ErlNifEnv* env, int argc,
                                   const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    char* opt = NULL;
    if (!get_c_string(env, argv[0], &opt)) return make_badarg(env);

    const char* val = b->LF_GetOption(opt);
    free(opt);

    /* The C pointer is transient (~5s). Copy immediately into an
     * Erlang binary. An unknown option yields an empty string. */
    if (val == NULL) {
        ErlNifBinary bin;
        if (!enif_alloc_binary(0, &bin)) {
            return make_error(env, ATOM_ENOMEM);
        }
        return enif_make_binary(env, &bin);
    }
    return make_binary_from_cstr(env, val);
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

/* ============================================================================
 * Shutdown thunk (1, unchanged)
 * ============================================================================ */

static ERL_NIF_TERM nif_shutdown(ErlNifEnv* env, int argc,
                                 const ERL_NIF_TERM argv[]) {
    (void)argc; (void)argv;
    LF_ENSURE_LOADED();

    /* Unblock every sync waiter and abort every pending async op so
     * that no Erlang process is left hanging when the library is torn
     * down. */
    sync_wake_all();

    b->LF_Shutdown();
    return ATOM_OK;
}

/* ============================================================================
 * Network event thunk (1, unchanged)
 * ============================================================================ */

static ERL_NIF_TERM nif_set_network_event(ErlNifEnv* env, int argc,
                                          const ERL_NIF_TERM argv[]) {
    (void)argc;
    LF_ENSURE_LOADED();

    LF_NetworkEventFunc on_connect = NULL;
    LF_NetworkEventFunc on_disconnect = NULL;

    if (!enif_is_identical(argv[0], ATOM_UNDEFINED)) {
        ErlNifPid pid;
        if (!enif_get_local_pid(env, argv[0], &pid)) {
            return make_badarg(env);
        }
        g_net_connect_pid = pid;
        g_net_connect_set = 1;
        on_connect = lf_net_connect_cb;
    } else {
        g_net_connect_set = 0;
    }

    if (!enif_is_identical(argv[1], ATOM_UNDEFINED)) {
        ErlNifPid pid;
        if (!enif_get_local_pid(env, argv[1], &pid)) {
            return make_badarg(env);
        }
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
 *
 * Entries are grouped and ordered to match lingofuse_nif.erl's export
 * list. Adding or renaming an entry here requires an identical change
 * in the Erlang module, or the NIF load will fail with a symbol
 * mismatch.
 *
 * The three registration entry points (register_call,
 * register_call_sync, register_notify) now take a trailing Options
 * argument. Their arity is therefore 5, not 4. The Erlang wrapper
 * supplies `undefined` for callers of the legacy 4-argument form.
 * ============================================================================ */

static ErlNifFunc nif_funcs[] = {
    /* Data handle (10) */
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

    /* App handle (5) */
    {"create_app",            2, nif_create_app,            0},
    {"free_app",              1, nif_free_app,              0},
    {"generate_app_name",     0, nif_generate_app_name,     0},
    {"get_app_name",          1, nif_get_app_name,          0},
    {"bind_app",              1, nif_bind_app,              0},

    /* API registration, app-bound (4) */
    {"register_call",         5, nif_register_call,         0},
    {"register_call_sync",    5, nif_register_call_sync,    0},
    {"register_notify",       5, nif_register_notify,       0},
    {"unregister",            2, nif_unregister,            0},

    /* API registration, process-wide P2P (4) */
    {"register_p2p_call",       4, nif_register_p2p_call,       0},
    {"register_p2p_call_sync",  4, nif_register_p2p_call_sync,  0},
    {"register_p2p_notify",     4, nif_register_p2p_notify,     0},
    {"unregister_p2p",          1, nif_unregister_p2p,          0},

    /* Sync bridge (3) */
    {"reply",                 2, nif_reply,                 0},
    {"set_sync_timeout",      1, nif_set_sync_timeout,      0},
    {"get_sync_timeout",      0, nif_get_sync_timeout,      0},

    /* Local execution (2) */
    {"local_call",            2, nif_local_call,            ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"local_notify",          2, nif_local_notify,          ERL_NIF_DIRTY_JOB_IO_BOUND},

    /* Network preparation (5) */
    {"reset_prepare",         0, nif_reset_prepare,         0},
    {"prepare_service",       2, nif_prepare_service,       0},
    {"prepare_client",        2, nif_prepare_client,        0},
    {"prepare_done",          0, nif_prepare_done,          ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"exit_main_thread",      0, nif_exit_main_thread,      ERL_NIF_DIRTY_JOB_IO_BOUND},

    /* Remote invocation, app name (3) */
    {"call",                  3, nif_call,                  ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"notify",                2, nif_notify,                0},
    {"sequenced_notify",      2, nif_sequenced_notify,      0},

    /* Remote invocation, UID (3) */
    {"uid_call",              3, nif_uid_call,              ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"uid_notify",            2, nif_uid_notify,            0},
    {"uid_sequenced_notify",  2, nif_uid_sequenced_notify,  0},

    /* Remote invocation, P2P name (3) */
    {"p2pname_call",             3, nif_p2pname_call,             ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"p2pname_notify",           2, nif_p2pname_notify,           0},
    {"p2pname_sequenced_notify", 2, nif_p2pname_sequenced_notify, 0},

    /* Remote invocation, asynchronous (6)
     *
     * Every entry is marked DIRTY_JOB_IO_BOUND. LF_Async_Call may
     * execute its callback synchronously on the calling thread when
     * the target resolves locally (local-first routing). Without this
     * flag, a sync-mode callback would block a normal BEAM scheduler
     * thread and deadlock the caller.
     */
    {"async_call",               3, nif_async_call,
     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"async_sequenced_call",     3, nif_async_sequenced_call,
     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"uid_async_call",           3, nif_uid_async_call,
     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"uid_async_sequenced_call", 3, nif_uid_async_sequenced_call,
     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"p2pname_async_call",       3, nif_p2pname_async_call,
     ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"p2pname_async_sequenced_call",
                                 3, nif_p2pname_async_sequenced_call,
     ERL_NIF_DIRTY_JOB_IO_BOUND},

    /* Options and diagnostics (8) */
    {"set_option",            2, nif_set_option,            0},
    {"get_option",            1, nif_get_option,            0},
    {"get_status_count",      0, nif_get_status_count,      0},
    {"get_status",            0, nif_get_status,            0},
    {"post_status",           1, nif_post_status,           0},
    {"check_main_thread",     0, nif_check_main_thread,     0},
    {"check_app",             1, nif_check_app,             0},
    {"check_api",             2, nif_check_api,             0},

    /* Query, UID / P2P name (4) */
    {"check_uid",             1, nif_check_uid,             0},
    {"check_uid_api",         2, nif_check_uid_api,         0},
    {"check_p2pname",         1, nif_check_p2pname,         0},
    {"check_p2pname_api",     2, nif_check_p2pname_api,     0},

    /* Shutdown (1) */
    {"shutdown",              0, nif_shutdown,              ERL_NIF_DIRTY_JOB_IO_BOUND},

    /* Network events (1) */
    {"set_network_event",     2, nif_set_network_event,     0}
};

ERL_NIF_INIT(lingofuse_nif, nif_funcs,
             nif_load, NULL, nif_upgrade, nif_unload)