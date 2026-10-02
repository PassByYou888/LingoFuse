#define LF_DART_BRIDGE_EXPORTS
#include "lf_dart_bridge.h"
#include "dart_api_dl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ============================================================================
// Platform abstraction layer
// ============================================================================

#if defined(_WIN32)

#  include <windows.h>

typedef HMODULE     lf_lib_t;
typedef HANDLE      lf_sem_t;
typedef CRITICAL_SECTION lf_mutex_t;

static lf_lib_t lf_load_library(const char* path) {
    return LoadLibraryA(path);
}
static void* lf_get_symbol(lf_lib_t lib, const char* name) {
    return (void*)GetProcAddress(lib, name);
}
static void lf_free_library(lf_lib_t lib) {
    FreeLibrary(lib);
}
static void lf_mutex_init(lf_mutex_t* m) { InitializeCriticalSection(m); }
static void lf_mutex_lock(lf_mutex_t* m) { EnterCriticalSection(m); }
static void lf_mutex_unlock(lf_mutex_t* m) { LeaveCriticalSection(m); }
static lf_sem_t lf_sem_create(void) {
    return CreateSemaphoreA(NULL, 0, 1, NULL);
}
static void lf_sem_wait(lf_sem_t s) { WaitForSingleObject(s, INFINITE); }
static void lf_sem_post(lf_sem_t s) { ReleaseSemaphore(s, 1, NULL); }
static void lf_sem_destroy(lf_sem_t s) { CloseHandle(s); }
static long lf_atomic_inc(volatile long* v) {
    return InterlockedIncrement(v);
}
static const char* lf_default_lingofuse_name(void) {
    return "LingoFuse64.dll";
}

#else // POSIX (Linux / macOS / BSD)

#  include <dlfcn.h>
#  include <pthread.h>
#  include <semaphore.h>
#  include <stdatomic.h>

typedef void*          lf_lib_t;
typedef sem_t          lf_sem_t;
typedef pthread_mutex_t lf_mutex_t;

static lf_lib_t lf_load_library(const char* path) {
    return dlopen(path, RTLD_LAZY);
}
static void* lf_get_symbol(lf_lib_t lib, const char* name) {
    return dlsym(lib, name);
}
static void lf_free_library(lf_lib_t lib) {
    dlclose(lib);
}
static void lf_mutex_init(lf_mutex_t* m) {
    pthread_mutex_init(m, NULL);
}
static void lf_mutex_lock(lf_mutex_t* m) {
    pthread_mutex_lock(m);
}
static void lf_mutex_unlock(lf_mutex_t* m) {
    pthread_mutex_unlock(m);
}
static lf_sem_t lf_sem_create(void) {
    lf_sem_t s;
    sem_init(&s, 0, 0);
    return s;
}
static void lf_sem_wait(lf_sem_t s) { sem_wait(&s); }
static void lf_sem_post(lf_sem_t s) { sem_post(&s); }
static void lf_sem_destroy(lf_sem_t s) { sem_destroy(&s); }
static long lf_atomic_inc(volatile long* v) {
    return atomic_fetch_add((_Atomic long*)v, 1) + 1;
}
static const char* lf_default_lingofuse_name(void) {
#  if defined(__APPLE__)
    return "liblingofuse.dylib";
#  else
    return "liblingofuse.so";
#  endif
}

#endif

// ============================================================================
// LingoFuse function pointer table
// ============================================================================

typedef void* TDataHnd;
typedef void* TAppHnd;

typedef int64_t (*LF_GetSize_Fn)(TDataHnd);
typedef int64_t (*LF_GetPos_Fn)(TDataHnd);
typedef void    (*LF_SetPos_Fn)(TDataHnd, int64_t);
typedef int64_t (*LF_ReadBuffer_Fn)(TDataHnd, void*, int64_t);
typedef int64_t (*LF_WriteBuffer_Fn)(TDataHnd, const void*, int64_t);
typedef int     (*LF_RegisterCall_Fn)(TAppHnd, const char*, const char*,
                                      void*, void*);
typedef int     (*LF_RegisterNotify_Fn)(TAppHnd, const char*, const char*,
                                        void*, void*);

static lf_lib_t            g_lingofuse = NULL;
static LF_GetSize_Fn       pLF_GetSize = NULL;
static LF_GetPos_Fn        pLF_GetPos = NULL;
static LF_SetPos_Fn        pLF_SetPos = NULL;
static LF_ReadBuffer_Fn    pLF_ReadBuffer = NULL;
static LF_WriteBuffer_Fn   pLF_WriteBuffer = NULL;
static LF_RegisterCall_Fn  pLF_RegisterCall = NULL;
static LF_RegisterNotify_Fn pLF_RegisterNotify = NULL;

static int load_lingofuse(void) {
    if (g_lingofuse != NULL) return 1;

    const char* env = getenv("LINGOFUSE_DLL");
    if (env != NULL && env[0] != '\0') {
        g_lingofuse = lf_load_library(env);
    }
    if (g_lingofuse == NULL) {
        g_lingofuse = lf_load_library(lf_default_lingofuse_name());
    }
    if (g_lingofuse == NULL) {
        fprintf(stderr,
                "lf_dart_bridge: cannot load %s\n",
                lf_default_lingofuse_name());
        return 0;
    }

    pLF_GetSize         = (LF_GetSize_Fn)       lf_get_symbol(g_lingofuse, "LF_GetSize");
    pLF_GetPos          = (LF_GetPos_Fn)        lf_get_symbol(g_lingofuse, "LF_GetPos");
    pLF_SetPos          = (LF_SetPos_Fn)        lf_get_symbol(g_lingofuse, "LF_SetPos");
    pLF_ReadBuffer      = (LF_ReadBuffer_Fn)    lf_get_symbol(g_lingofuse, "LF_ReadBuffer");
    pLF_WriteBuffer     = (LF_WriteBuffer_Fn)   lf_get_symbol(g_lingofuse, "LF_WriteBuffer");
    pLF_RegisterCall    = (LF_RegisterCall_Fn)  lf_get_symbol(g_lingofuse, "LF_RegisterCall");
    pLF_RegisterNotify  = (LF_RegisterNotify_Fn)lf_get_symbol(g_lingofuse, "LF_RegisterNotify");

    if (!pLF_GetSize || !pLF_GetPos || !pLF_SetPos ||
        !pLF_ReadBuffer || !pLF_WriteBuffer ||
        !pLF_RegisterCall || !pLF_RegisterNotify) {
        fprintf(stderr, "lf_dart_bridge: LingoFuse is missing required symbols\n");
        lf_free_library(g_lingofuse);
        g_lingofuse = NULL;
        return 0;
    }
    return 1;
}

// ============================================================================
// Bridge state
// ============================================================================

static Dart_Port_DL g_port = 0;
static int           g_initialized = 0;

static lf_mutex_t g_lock;
static int        g_lock_initialized = 0;

static volatile long g_next_request_id = 1;

typedef struct Request {
    int64_t request_id;
    int64_t callback_id;

    char*   input_data;
    int64_t input_len;

    char*   output_data;
    int64_t output_len;

    lf_sem_t done_sem;

    struct Request* next;
} Request;

static Request* g_requests = NULL;

static void lock_init(void) {
    if (!g_lock_initialized) {
        lf_mutex_init(&g_lock);
        g_lock_initialized = 1;
    }
}
static void lock_acquire(void) { lf_mutex_lock(&g_lock); }
static void lock_release(void) { lf_mutex_unlock(&g_lock); }

static void register_request(Request* req) {
    lock_acquire();
    req->next = g_requests;
    g_requests = req;
    lock_release();
}

static Request* find_request(int64_t request_id) {
    Request* found = NULL;
    lock_acquire();
    for (Request* p = g_requests; p != NULL; p = p->next) {
        if (p->request_id == request_id) { found = p; break; }
    }
    lock_release();
    return found;
}

static void unregister_request(Request* req) {
    lock_acquire();
    Request** pp = &g_requests;
    while (*pp != NULL) {
        if (*pp == req) { *pp = req->next; break; }
        pp = &(*pp)->next;
    }
    lock_release();
}

// ============================================================================
// Callback trampolines
// ============================================================================

static void LF_BRIDGE_CDECL call_trampoline(
    void* trigger, TDataHnd input, TDataHnd output) {
    (void)output;

    if (!pLF_GetSize || !pLF_GetPos || !pLF_SetPos || !pLF_ReadBuffer) {
        return;
    }

    int64_t callback_id = (int64_t)(intptr_t)trigger;

    int64_t input_len = pLF_GetSize(input);
    char*   input_data = NULL;
    if (input_len > 0) {
        input_data = (char*)malloc((size_t)input_len);
        if (input_data == NULL) return;
        int64_t saved = pLF_GetPos(input);
        pLF_SetPos(input, 0);
        pLF_ReadBuffer(input, input_data, input_len);
        pLF_SetPos(input, saved);
    }

    Request* req = (Request*)calloc(1, sizeof(Request));
    if (req == NULL) { free(input_data); return; }

    req->request_id  = (int64_t)lf_atomic_inc(&g_next_request_id);
    req->callback_id = callback_id;
    req->input_data  = input_data;
    req->input_len   = input_len;
    req->done_sem    = lf_sem_create();

    register_request(req);

    Dart_CObject rid, cid, data;
    Dart_CObject* items[3];

    rid.type = Dart_CObject_kInt64;
    rid.value.as_int64 = req->request_id;

    cid.type = Dart_CObject_kInt64;
    cid.value.as_int64 = req->callback_id;

    data.type = Dart_CObject_kTypedData;
    data.value.as_typed_data.type   = Dart_TypedData_kUint8;
    data.value.as_typed_data.length = (intptr_t)input_len;
    data.value.as_typed_data.values = (uint8_t*)input_data;

    items[0] = &rid;
    items[1] = &cid;
    items[2] = &data;

    Dart_CObject msg;
    msg.type = Dart_CObject_kArray;
    msg.value.as_array.length = 3;
    msg.value.as_array.values = items;

    if (!Dart_PostCObject_DL(g_port, &msg)) {
        unregister_request(req);
        lf_sem_destroy(req->done_sem);
        free(input_data);
        free(req);
        return;
    }

    lf_sem_wait(req->done_sem);

    if (req->output_len > 0 && req->output_data != NULL && pLF_WriteBuffer) {
        pLF_WriteBuffer(output, req->output_data, req->output_len);
    }

    unregister_request(req);
    lf_sem_destroy(req->done_sem);
    free(req->input_data);
    free(req->output_data);
    free(req);
}

static void LF_BRIDGE_CDECL notify_trampoline(void* trigger, TDataHnd input) {
    if (!pLF_GetSize || !pLF_GetPos || !pLF_SetPos || !pLF_ReadBuffer) {
        return;
    }

    int64_t callback_id = (int64_t)(intptr_t)trigger;

    int64_t input_len = pLF_GetSize(input);
    char*   input_data = NULL;
    if (input_len > 0) {
        input_data = (char*)malloc((size_t)input_len);
        if (input_data == NULL) return;
        int64_t saved = pLF_GetPos(input);
        pLF_SetPos(input, 0);
        pLF_ReadBuffer(input, input_data, input_len);
        pLF_SetPos(input, saved);
    }

    Dart_CObject rid, cid, data;
    Dart_CObject* items[3];

    rid.type = Dart_CObject_kInt64;
    rid.value.as_int64 = 0;

    cid.type = Dart_CObject_kInt64;
    cid.value.as_int64 = callback_id;

    data.type = Dart_CObject_kTypedData;
    data.value.as_typed_data.type   = Dart_TypedData_kUint8;
    data.value.as_typed_data.length = (intptr_t)input_len;
    data.value.as_typed_data.values = (uint8_t*)input_data;

    items[0] = &rid;
    items[1] = &cid;
    items[2] = &data;

    Dart_CObject msg;
    msg.type = Dart_CObject_kArray;
    msg.value.as_array.length = 3;
    msg.value.as_array.values = items;

    Dart_PostCObject_DL(g_port, &msg);

    free(input_data);
}

// ============================================================================
// Public API
// ============================================================================

int LF_BRIDGE_CDECL lf_bridge_init(int64_t port_id, void* api_dl_data) {
    if (g_initialized) return 0;

    if (api_dl_data == NULL) {
        fprintf(stderr, "lf_dart_bridge: api_dl_data is NULL; pass "
                        "NativeApi.initializeApiDLData from Dart\n");
        return -1;
    }

    if (Dart_InitializeApiDL(api_dl_data) != 0) {
        fprintf(stderr, "lf_dart_bridge: Dart_InitializeApiDL failed\n");
        return -1;
    }

    lock_init();
    g_port = (Dart_Port_DL)port_id;
    g_initialized = 1;
    return 0;
}

int LF_BRIDGE_CDECL lf_bridge_register_call(
    void* app_hnd, const char* api_name, const char* desc, int64_t callback_id) {
    if (!load_lingofuse()) return 0;
    void* trigger = (void*)(intptr_t)callback_id;
    return pLF_RegisterCall((TAppHnd)app_hnd, api_name, desc,
                            trigger, (void*)call_trampoline);
}

int LF_BRIDGE_CDECL lf_bridge_register_notify(
    void* app_hnd, const char* api_name, const char* desc, int64_t callback_id) {
    if (!load_lingofuse()) return 0;
    void* trigger = (void*)(intptr_t)callback_id;
    return pLF_RegisterNotify((TAppHnd)app_hnd, api_name, desc,
                              trigger, (void*)notify_trampoline);
}

void LF_BRIDGE_CDECL lf_bridge_complete(
    int64_t request_id, const uint8_t* output, int64_t output_len) {
    Request* req = find_request(request_id);
    if (req == NULL) return;

    if (output_len > 0 && output != NULL) {
        char* copy = (char*)malloc((size_t)output_len);
        if (copy != NULL) {
            memcpy(copy, output, (size_t)output_len);
            req->output_data = copy;
            req->output_len  = output_len;
        }
    }
    lf_sem_post(req->done_sem);
}

void LF_BRIDGE_CDECL lf_bridge_shutdown(void) {
    g_initialized = 0;
    g_port = 0;
}