/*
 * mock_lf.c - Implementation of the LingoFuse mock ABI.
 * See mock_lf.h for the design rationale.
 */

#include "mock_lf.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ================================================================= */
/* Platform abstraction: threads                                      */
/* ================================================================= */

#if defined(_WIN32)

  #include <windows.h>

  typedef HANDLE mock_thread_t;

  static int thread_start(mock_thread_t* t,
                          DWORD (WINAPI *fn)(LPVOID),
                          void* arg)
  {
      *t = CreateThread(NULL, 0, fn, arg, 0, NULL);
      return *t != NULL;
  }

  static void thread_join(mock_thread_t t)
  {
      WaitForSingleObject(t, INFINITE);
      CloseHandle(t);
  }

#else

  #include <pthread.h>

  typedef pthread_t mock_thread_t;

  static int thread_start(mock_thread_t* t,
                          void* (*fn)(void*),
                          void* arg)
  {
      return pthread_create(t, NULL, fn, arg) == 0;
  }

  static void thread_join(mock_thread_t t)
  {
      pthread_join(t, NULL);
  }

#endif

/* ================================================================= */
/* Data handle                                                        */
/* ================================================================= */

typedef struct mock_data {
    char*   buf;
    int64_t cap;
    int64_t size;
    int64_t pos;
    char    name[128];
} mock_data_t;

static void ensure_capacity(mock_data_t* d, int64_t needed)
{
    if (needed <= d->cap) return;

    int64_t ncap = d->cap > 0 ? d->cap : 64;
    while (ncap < needed) ncap *= 2;

    d->buf = (char*)realloc(d->buf, (size_t)ncap);
    if (!d->buf) {
        /* In a real library this would be a fatal allocation failure.
         * In a mock, we simply lose the resize; callers will observe
         * a short write. */
        d->cap  = 0;
        d->size = 0;
        d->pos  = 0;
        return;
    }
    d->cap = ncap;
}

void* LF_CreateData(const char* method_name)
{
    mock_data_t* d = (mock_data_t*)calloc(1, sizeof(*d));
    if (!d) return NULL;

    d->cap = 64;
    d->buf = (char*)malloc((size_t)d->cap);
    if (!d->buf) { free(d); return NULL; }

    if (method_name) {
        strncpy(d->name, method_name, sizeof(d->name) - 1);
    }
    return d;
}

void* LF_CreateData_Permanent(const char* method_name)
{
    return LF_CreateData(method_name);
}

void LF_FreeData(void* hnd)
{
    mock_data_t* d = (mock_data_t*)hnd;
    if (!d) return;
    free(d->buf);
    free(d);
}

void* LF_GetBuffer(void* hnd)
{
    mock_data_t* d = (mock_data_t*)hnd;
    return d ? (void*)d->buf : NULL;
}

int64_t LF_WriteBuffer(void* hnd, const void* buff, int64_t size)
{
    mock_data_t* d = (mock_data_t*)hnd;
    if (!d || size < 0) return 0;

    ensure_capacity(d, d->pos + size);
    if (size > 0 && buff) {
        memcpy(d->buf + d->pos, buff, (size_t)size);
    }
    d->pos += size;
    if (d->pos > d->size) d->size = d->pos;
    return size;
}

int64_t LF_ReadBuffer(void* hnd, void* buff, int64_t size)
{
    mock_data_t* d = (mock_data_t*)hnd;
    if (!d || size < 0) return 0;

    int64_t avail = d->size - d->pos;
    if (avail <= 0) return 0;

    int64_t to_read = size < avail ? size : avail;
    if (to_read > 0 && buff) {
        memcpy(buff, d->buf + d->pos, (size_t)to_read);
    }
    d->pos += to_read;
    return to_read;
}

int64_t LF_GetPos(void* hnd)
{
    mock_data_t* d = (mock_data_t*)hnd;
    return d ? d->pos : 0;
}

void LF_SetPos(void* hnd, int64_t pos)
{
    mock_data_t* d = (mock_data_t*)hnd;
    if (!d || pos < 0) return;

    if (pos > d->cap) ensure_capacity(d, pos);
    if (pos > d->size) {
        memset(d->buf + d->size, 0, (size_t)(pos - d->size));
        d->size = pos;
    }
    d->pos = pos;
}

int64_t LF_GetSize(void* hnd)
{
    mock_data_t* d = (mock_data_t*)hnd;
    return d ? d->size : 0;
}

void LF_SetSize(void* hnd, int64_t size)
{
    mock_data_t* d = (mock_data_t*)hnd;
    if (!d || size < 0) return;

    ensure_capacity(d, size);
    if (size > d->size) {
        memset(d->buf + d->size, 0, (size_t)(size - d->size));
    }
    d->size = size;
    if (d->pos > size) d->pos = size;
}

/* ================================================================= */
/* App handle                                                         */
/* ================================================================= */

typedef struct mock_app {
    char name[128];
    char desc[256];
} mock_app_t;

void* LF_CreateApp(const char* app_name, const char* desc)
{
    mock_app_t* a = (mock_app_t*)calloc(1, sizeof(*a));
    if (!a) return NULL;
    if (app_name) strncpy(a->name, app_name, sizeof(a->name) - 1);
    if (desc)     strncpy(a->desc, desc,     sizeof(a->desc) - 1);
    return a;
}

void LF_FreeApp(void* app_hnd)
{
    free(app_hnd);
}

/* ================================================================= */
/* Registration table                                                 */
/* ================================================================= */
/*
 * A single linked list stores every registration from both
 * namespaces. Each entry records the namespace (App-bound / P2P) and
 * the mode (Call / Notify) so that:
 *
 *   - duplicate detection is per (name, namespace, mode) triple;
 *   - lookup at dispatch time can select the correct entry.
 *
 * The callback pointer is stored type-erased and re-interpreted at
 * dispatch time based on the mode.
 */

typedef struct mock_reg {
    char             name[128];
    void*            trigger;
    int              is_p2p;      /* 0 = App-bound, 1 = P2P     */
    int              is_notify;   /* 0 = Call,      1 = Notify  */
    void*            cb;          /* void(*)(void*,void*,void*) or
                                     void(*)(void*,void*)       */
    struct mock_reg* next;
} mock_reg_t;

static mock_reg_t* g_reg_head = NULL;

static mock_reg_t* find_reg(const char* name, int is_p2p, int is_notify)
{
    if (!name) return NULL;
    for (mock_reg_t* p = g_reg_head; p; p = p->next) {
        if (p->is_p2p == is_p2p &&
            p->is_notify == is_notify &&
            strcmp(p->name, name) == 0) {
            return p;
        }
    }
    return NULL;
}

static mock_reg_t* append_reg(const char* name,
                              void* trigger,
                              int is_p2p,
                              int is_notify,
                              void* cb)
{
    if (!name || !cb) return NULL;
    if (find_reg(name, is_p2p, is_notify)) return NULL;

    mock_reg_t* r = (mock_reg_t*)calloc(1, sizeof(*r));
    if (!r) return NULL;

    strncpy(r->name, name, sizeof(r->name) - 1);
    r->trigger   = trigger;
    r->is_p2p    = is_p2p;
    r->is_notify = is_notify;
    r->cb        = cb;
    r->next      = g_reg_head;
    g_reg_head   = r;
    return r;
}

/* ---- App-bound ---- */

int LF_RegisterCall(void* app, const char* name, const char* desc,
                    void* trigger,
                    void (*cb)(void*, void*, void*))
{
    (void)app; (void)desc;
    return append_reg(name, trigger, 0, 0, (void*)cb) ? 1 : 0;
}

int LF_RegisterNotify(void* app, const char* name, const char* desc,
                      void* trigger,
                      void (*cb)(void*, void*))
{
    (void)app; (void)desc;
    return append_reg(name, trigger, 0, 1, (void*)cb) ? 1 : 0;
}

/* ---- Process-wide P2P ---- */

int LF_Register_P2P_Call(const char* name, const char* desc,
                         void* trigger,
                         void (*cb)(void*, void*, void*))
{
    (void)desc;
    return append_reg(name, trigger, 1, 0, (void*)cb) ? 1 : 0;
}

int LF_Register_P2P_Notify(const char* name, const char* desc,
                           void* trigger,
                           void (*cb)(void*, void*))
{
    (void)desc;
    return append_reg(name, trigger, 1, 1, (void*)cb) ? 1 : 0;
}

int LF_Unregister_P2P(const char* name)
{
    if (!name) return 0;

    mock_reg_t** pp = &g_reg_head;
    while (*pp) {
        if ((*pp)->is_p2p && strcmp((*pp)->name, name) == 0) {
            mock_reg_t* victim = *pp;
            *pp = victim->next;
            free(victim);
            return 1;
        }
        pp = &(*pp)->next;
    }
    return 0;
}

/* ---- Network events ---- */

static void (*g_on_connect)(const char*)    = NULL;
static void (*g_on_disconnect)(const char*) = NULL;

void LF_Set_Network_Event(void (*on_connect)(const char*),
                          void (*on_disconnect)(const char*))
{
    g_on_connect    = on_connect;
    g_on_disconnect = on_disconnect;
}

/* ================================================================= */
/* Async dispatch table                                               */
/* ================================================================= */
/*
 * Each pending async operation stores:
 *   - the token (extracted from the caller's data pointer);
 *   - the caller's data pointer (passed verbatim to the trampoline);
 *   - the result callback.
 *
 * The trampoline is invoked from a fresh native thread by
 * mock_lf_trigger_async_result. Multiple triggers for the same
 * token are allowed and each one re-invokes the trampoline with a
 * fresh result handle.
 */

typedef struct mock_async {
    int64_t            token;
    void*              data;
    void               (*cb)(void*, void*);
    struct mock_async* next;
} mock_async_t;

static mock_async_t* g_async_head = NULL;

static int64_t token_from_data(void* data)
{
    return (int64_t)(intptr_t)data;
}

static void record_async(void* data, void (*cb)(void*, void*))
{
    if (!cb) return;

    mock_async_t* a = (mock_async_t*)calloc(1, sizeof(*a));
    if (!a) return;

    a->token = token_from_data(data);
    a->data  = data;
    a->cb    = cb;
    a->next  = g_async_head;
    g_async_head = a;
}

static mock_async_t* find_async(int64_t token)
{
    for (mock_async_t* p = g_async_head; p; p = p->next) {
        if (p->token == token) return p;
    }
    return NULL;
}

/* ---- Public dispatch entry points ---- */

int LF_Async_Call(const char* app_name, void* param, void* data,
                  void (*cb)(void*, void*))
{
    (void)app_name; (void)param;
    record_async(data, cb);
    return 1;
}

int LF_Async_Sequenced_Call(const char* app_name, void* param, void* data,
                            void (*cb)(void*, void*))
{
    (void)app_name; (void)param;
    record_async(data, cb);
    return 1;
}

int LF_UID_Async_Call(lf_shim_uid_t uid, void* param, void* data,
                      void (*cb)(void*, void*))
{
    (void)uid; (void)param;
    record_async(data, cb);
    return 1;
}

int LF_UID_Async_Sequenced_Call(lf_shim_uid_t uid, void* param, void* data,
                                void (*cb)(void*, void*))
{
    (void)uid; (void)param;
    record_async(data, cb);
    return 1;
}

int LF_P2PNAME_Async_Call(const char* group_name, void* param, void* data,
                          void (*cb)(void*, void*))
{
    (void)group_name; (void)param;
    record_async(data, cb);
    return 1;
}

int LF_P2PNAME_Async_Sequenced_Call(const char* group_name, void* param, void* data,
                                    void (*cb)(void*, void*))
{
    (void)group_name; (void)param;
    record_async(data, cb);
    return 1;
}

/* ================================================================= */
/* Runtime options                                                    */
/* ================================================================= */
/*
 * A fixed-size key/value store. Every entry is a NUL-terminated
 * string. LF_GetOption returns a pointer into the store, or a
 * pointer to a static "" for unknown names.
 *
 * The capacity is generous enough for the test suite and the mock
 * never evicts entries. Tests that need a clean slate restart the
 * process.
 */

#define MOCK_MAX_OPTS     64
#define MOCK_OPT_NAME_MAX 64
#define MOCK_OPT_VAL_MAX  512

typedef struct {
    char name[MOCK_OPT_NAME_MAX];
    char value[MOCK_OPT_VAL_MAX];
} mock_opt_entry_t;

static mock_opt_entry_t g_opts[MOCK_MAX_OPTS];
static int              g_opts_used = 0;

static const char* mock_opt_get(const char* name)
{
    if (!name) return "";
    for (int i = 0; i < g_opts_used; i++) {
        if (strcmp(g_opts[i].name, name) == 0) {
            return g_opts[i].value;
        }
    }
    return "";
}

static void mock_opt_set(const char* name, const char* value)
{
    if (!name) return;
    if (!value) value = "";

    for (int i = 0; i < g_opts_used; i++) {
        if (strcmp(g_opts[i].name, name) == 0) {
            strncpy(g_opts[i].value, value, MOCK_OPT_VAL_MAX - 1);
            g_opts[i].value[MOCK_OPT_VAL_MAX - 1] = '\0';
            return;
        }
    }

    if (g_opts_used >= MOCK_MAX_OPTS) return;  /* silently drop */

    strncpy(g_opts[g_opts_used].name, name, MOCK_OPT_NAME_MAX - 1);
    g_opts[g_opts_used].name[MOCK_OPT_NAME_MAX - 1] = '\0';

    strncpy(g_opts[g_opts_used].value, value, MOCK_OPT_VAL_MAX - 1);
    g_opts[g_opts_used].value[MOCK_OPT_VAL_MAX - 1] = '\0';

    g_opts_used++;
}

void LF_SetOption(const char* name, const char* value)
{
    mock_opt_set(name, value);
}

const char* LF_GetOption(const char* name)
{
    return mock_opt_get(name);
}

/* ================================================================= */
/* Worker-thread simulators: Call / Notify                            */
/* ================================================================= */

typedef struct call_thread_ctx {
    void  (*cb)(void*, void*, void*);
    void* trigger;
    void* input;
    void* output;
} call_thread_ctx_t;

typedef struct notify_thread_ctx {
    void  (*cb)(void*, void*);
    void* trigger;
    void* input;
} notify_thread_ctx_t;

typedef struct network_thread_ctx {
    void  (*cb)(const char*);
    char* addr;
} network_thread_ctx_t;

typedef struct async_thread_ctx {
    void  (*cb)(void*, void*);
    void* data;
    void* result;
} async_thread_ctx_t;

#if defined(_WIN32)

static DWORD WINAPI call_thread_proc(LPVOID arg)
{
    call_thread_ctx_t* c = (call_thread_ctx_t*)arg;
    c->cb(c->trigger, c->input, c->output);
    return 0;
}
static DWORD WINAPI notify_thread_proc(LPVOID arg)
{
    notify_thread_ctx_t* c = (notify_thread_ctx_t*)arg;
    c->cb(c->trigger, c->input);
    return 0;
}
static DWORD WINAPI network_thread_proc(LPVOID arg)
{
    network_thread_ctx_t* c = (network_thread_ctx_t*)arg;
    c->cb(c->addr);
    return 0;
}
static DWORD WINAPI async_thread_proc(LPVOID arg)
{
    async_thread_ctx_t* c = (async_thread_ctx_t*)arg;
    c->cb(c->data, c->result);
    return 0;
}

#else /* POSIX */

static void* call_thread_proc(void* arg)
{
    call_thread_ctx_t* c = (call_thread_ctx_t*)arg;
    c->cb(c->trigger, c->input, c->output);
    return NULL;
}
static void* notify_thread_proc(void* arg)
{
    notify_thread_ctx_t* c = (notify_thread_ctx_t*)arg;
    c->cb(c->trigger, c->input);
    return NULL;
}
static void* network_thread_proc(void* arg)
{
    network_thread_ctx_t* c = (network_thread_ctx_t*)arg;
    c->cb(c->addr);
    return NULL;
}
static void* async_thread_proc(void* arg)
{
    async_thread_ctx_t* c = (async_thread_ctx_t*)arg;
    c->cb(c->data, c->result);
    return NULL;
}

#endif

/* ---- Shared helpers ---- */

static void dispatch_call(mock_reg_t* r,
                          const void* input_bytes, size_t input_len,
                          void*       output_buf,  size_t output_cap,
                          size_t*     out_written)
{
    if (out_written) *out_written = 0;
    if (!r || r->is_notify) return;

    void* h_in  = LF_CreateData("__mock_call_in__");
    void* h_out = LF_CreateData("__mock_call_out__");
    if (!h_in || !h_out) {
        if (h_in)  LF_FreeData(h_in);
        if (h_out) LF_FreeData(h_out);
        return;
    }

    if (input_len > 0 && input_bytes) {
        LF_WriteBuffer(h_in, input_bytes, (int64_t)input_len);
    }
    LF_SetPos(h_in, 0);

    call_thread_ctx_t ctx = {
        (void (*)(void*, void*, void*))r->cb,
        r->trigger, h_in, h_out
    };

    mock_thread_t t;
    if (thread_start(&t, call_thread_proc, &ctx)) {
        thread_join(t);
    }

    if (output_buf && output_cap > 0) {
        LF_SetPos(h_out, 0);
        int64_t got = LF_ReadBuffer(h_out, output_buf, (int64_t)output_cap);
        if (out_written) *out_written = (size_t)got;
    }

    LF_FreeData(h_in);
    LF_FreeData(h_out);
}

static void dispatch_notify(mock_reg_t* r,
                            const void* input_bytes, size_t input_len)
{
    if (!r || !r->is_notify) return;

    void* h_in = LF_CreateData("__mock_notify_in__");
    if (!h_in) return;

    if (input_len > 0 && input_bytes) {
        LF_WriteBuffer(h_in, input_bytes, (int64_t)input_len);
    }
    LF_SetPos(h_in, 0);

    notify_thread_ctx_t ctx = {
        (void (*)(void*, void*))r->cb,
        r->trigger, h_in
    };

    mock_thread_t t;
    if (thread_start(&t, notify_thread_proc, &ctx)) {
        thread_join(t);
    }

    LF_FreeData(h_in);
}

/* ---- App-bound drivers ---- */

void mock_lf_trigger_call(
    const char* api_name,
    const void* input_bytes, size_t input_len,
    void*       output_buf,  size_t output_cap,
    size_t*     out_written)
{
    if (out_written) *out_written = 0;
    mock_reg_t* r = find_reg(api_name, 0, 0);
    dispatch_call(r, input_bytes, input_len, output_buf, output_cap, out_written);
}

void mock_lf_trigger_notify(
    const char* api_name,
    const void* input_bytes, size_t input_len)
{
    mock_reg_t* r = find_reg(api_name, 0, 1);
    dispatch_notify(r, input_bytes, input_len);
}

/* ---- P2P drivers ---- */

void mock_lf_trigger_p2p_call(
    const char* api_name,
    const void* input_bytes, size_t input_len,
    void*       output_buf,  size_t output_cap,
    size_t*     out_written)
{
    if (out_written) *out_written = 0;
    mock_reg_t* r = find_reg(api_name, 1, 0);
    dispatch_call(r, input_bytes, input_len, output_buf, output_cap, out_written);
}

void mock_lf_trigger_p2p_notify(
    const char* api_name,
    const void* input_bytes, size_t input_len)
{
    mock_reg_t* r = find_reg(api_name, 1, 1);
    dispatch_notify(r, input_bytes, input_len);
}

/* ---- Network events ---- */

void mock_lf_trigger_network_event(int is_connect, const char* addr)
{
    void (*cb)(const char*) = is_connect ? g_on_connect : g_on_disconnect;
    if (!cb) return;

    /* The callback contract says the address pointer is valid only
     * for the duration of the call. We copy it into a heap buffer so
     * the mock thread does not depend on the caller's storage. */
    char* copy = NULL;
    if (addr) {
        size_t n = strlen(addr);
        copy = (char*)malloc(n + 1);
        if (copy) memcpy(copy, addr, n + 1);
    }

    network_thread_ctx_t ctx = { cb, copy };

    mock_thread_t t;
    if (thread_start(&t, network_thread_proc, &ctx)) {
        thread_join(t);
    }

    if (copy) free(copy);
}

/* ---- Async result ---- */

void mock_lf_trigger_async_result(
    int64_t     user_token,
    const void* result_bytes, size_t result_len)
{
    mock_async_t* entry = find_async(user_token);
    if (!entry) {
        /* No pending operation. This is a legitimate scenario: tests
         * use it to simulate a result that never arrives. Silence. */
        return;
    }

    /* Build a result data handle carrying the payload. The trampoline
     * will snapshot it on its own thread; after this function
     * returns, the handle is freed. */
    void* result_hnd = LF_CreateData("__mock_async_result__");
    if (!result_hnd) return;

    if (result_len > 0 && result_bytes) {
        LF_WriteBuffer(result_hnd, result_bytes, (int64_t)result_len);
    }
    LF_SetPos(result_hnd, 0);

    async_thread_ctx_t ctx = {
        entry->cb,
        entry->data,
        result_hnd
    };

    mock_thread_t t;
    if (thread_start(&t, async_thread_proc, &ctx)) {
        thread_join(t);
    }

    LF_FreeData(result_hnd);
}