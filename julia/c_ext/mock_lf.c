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
        d->cap = 0;
        d->size = 0;
        d->pos = 0;
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
/* Registration tables                                                */
/* ================================================================= */

typedef struct mock_call {
    char        name[128];
    void*       trigger;
    void        (*cb)(void*, void*, void*);
    struct mock_call* next;
} mock_call_t;

typedef struct mock_notify {
    char        name[128];
    void*       trigger;
    void        (*cb)(void*, void*);
    struct mock_notify* next;
} mock_notify_t;

static mock_call_t*   g_call_head   = NULL;
static mock_notify_t* g_notify_head = NULL;

static void (*g_on_connect)(const char*)    = NULL;
static void (*g_on_disconnect)(const char*) = NULL;

int LF_RegisterCall(void* app, const char* name, const char* desc,
                    void* trigger,
                    void (*cb)(void*, void*, void*))
{
    (void)app; (void)desc;
    if (!name || !cb) return 0;

    for (mock_call_t* p = g_call_head; p; p = p->next) {
        if (strcmp(p->name, name) == 0) return 0;
    }

    mock_call_t* r = (mock_call_t*)calloc(1, sizeof(*r));
    if (!r) return 0;

    strncpy(r->name, name, sizeof(r->name) - 1);
    r->trigger = trigger;
    r->cb = cb;
    r->next = g_call_head;
    g_call_head = r;
    return 1;
}

int LF_RegisterNotify(void* app, const char* name, const char* desc,
                      void* trigger,
                      void (*cb)(void*, void*))
{
    (void)app; (void)desc;
    if (!name || !cb) return 0;

    for (mock_notify_t* p = g_notify_head; p; p = p->next) {
        if (strcmp(p->name, name) == 0) return 0;
    }

    mock_notify_t* r = (mock_notify_t*)calloc(1, sizeof(*r));
    if (!r) return 0;

    strncpy(r->name, name, sizeof(r->name) - 1);
    r->trigger = trigger;
    r->cb = cb;
    r->next = g_notify_head;
    g_notify_head = r;
    return 1;
}

void LF_Set_Network_Event(void (*on_connect)(const char*),
                          void (*on_disconnect)(const char*))
{
    g_on_connect    = on_connect;
    g_on_disconnect = on_disconnect;
}

/* ================================================================= */
/* Worker-thread simulators                                           */
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

#endif

void mock_lf_trigger_call(
    const char* api_name,
    const void* input_bytes, size_t input_len,
    void*       output_buf,  size_t output_cap,
    size_t*     out_written)
{
    if (out_written) *out_written = 0;
    if (!api_name) return;

    mock_call_t* r = NULL;
    for (mock_call_t* p = g_call_head; p; p = p->next) {
        if (strcmp(p->name, api_name) == 0) { r = p; break; }
    }
    if (!r) return;

    /* Build the same pair of handles that the real LingoFuse would
     * pass to a Call callback. */
    void* h_in  = LF_CreateData(api_name);
    void* h_out = LF_CreateData(api_name);
    if (input_len > 0 && input_bytes) {
        LF_WriteBuffer(h_in, input_bytes, (int64_t)input_len);
    }
    LF_SetPos(h_in, 0);

    call_thread_ctx_t ctx = { r->cb, r->trigger, h_in, h_out };

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

void mock_lf_trigger_notify(
    const char* api_name,
    const void* input_bytes, size_t input_len)
{
    if (!api_name) return;

    mock_notify_t* r = NULL;
    for (mock_notify_t* p = g_notify_head; p; p = p->next) {
        if (strcmp(p->name, api_name) == 0) { r = p; break; }
    }
    if (!r) return;

    void* h_in = LF_CreateData(api_name);
    if (input_len > 0 && input_bytes) {
        LF_WriteBuffer(h_in, input_bytes, (int64_t)input_len);
    }
    LF_SetPos(h_in, 0);

    notify_thread_ctx_t ctx = { r->cb, r->trigger, h_in };

    mock_thread_t t;
    if (thread_start(&t, notify_thread_proc, &ctx)) {
        thread_join(t);
    }

    LF_FreeData(h_in);
}

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