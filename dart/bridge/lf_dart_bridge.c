/*
 * lf_dart_bridge.c
 *
 * Implementation of the Dart FFI C bridge for LingoFuse.
 *
 * Design rationale, callback protocols, error-handling contract and
 * the full exported API surface are documented in lf_dart_bridge.h.
 * Read that file first; this file only explains IMPLEMENTATION
 * choices that are not obvious from the header.
 *
 * ---------------------------------------------------------------------------
 * HIGH-LEVEL STRUCTURE
 * ---------------------------------------------------------------------------
 *
 *   Section  0  Platform abstraction (mutex / semaphore / atomics / TLS)
 *   Section  1  Global state
 *   Section  2  Thread-local error string
 *   Section  3  LingoFuse dynamic loading and symbol resolution
 *   Section  4  Dart PostCObject helpers
 *   Section  5  Protocol A: pending-request table and trampolines
 *   Section  6  Protocol B: fire-and-forget trampolines
 *   Section  7  Option helpers (typed get / set)
 *   Section  8  Exported functions (Sections 0..15 of the header)
 *   Section  9  Attach / detach entry points for the bridge DLL
 *
 * ---------------------------------------------------------------------------
 * WHY THE BRIDGE LOADS LINGOFUSE ITSELF
 * ---------------------------------------------------------------------------
 * The bridge DLL is independent of the Dart side. It cannot assume that
 * Dart has already loaded LingoFuse64.dll into the same process, nor
 * that the OS loader will find LingoFuse by name. The bridge therefore
 * performs its own LoadLibraryA / dlopen on init.
 *
 * If LingoFuse is already loaded (because Dart loaded it first), the
 * OS returns the existing handle and the refcount is incremented. This
 * is harmless.
 *
 * ---------------------------------------------------------------------------
 * UID-AS-VALUE ABI
 * ---------------------------------------------------------------------------
 * LingoFuse's ARGUMENT-role UID type is `array[0..31] of Byte` on the
 * Pascal side. On x86-64 (both SysV AMD64 and Windows x64) an
 * aggregate larger than 16 bytes is classified MEMORY by the psABI,
 * so a C struct with a single 32-byte array member is ABI-compatible.
 *
 * The bridge constructs this struct on the stack and passes it BY
 * VALUE to LF_UID_Call and friends. Dart never sees the struct: it
 * only supplies a `const uint8_t*`.
 *
 * See the header for the fallback plan if this ABI assumption fails on
 * a future compiler or architecture.
 */

#define LF_DART_BRIDGE_EXPORTS
#include "lf_dart_bridge.h"
#include "dart_api_dl.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ===========================================================================
 * Section 0 -- Platform abstraction
 * ===========================================================================
 *
 * Windows uses Win32 primitives; everything else uses POSIX threads,
 * POSIX semaphores and GCC/Clang builtins for atomics.
 *
 * The abstraction is deliberately minimal: only the five primitives
 * the bridge actually needs (mutex, semaphore, atomic inc/dec, TLS,
 * dynamic loading).
 * ========================================================================= */

#if defined(_WIN32)

#  include <windows.h>

#  define LF_TLS __declspec(thread)

typedef HMODULE        lf_lib_handle_t;
typedef CRITICAL_SECTION lf_mutex_t;
typedef HANDLE         lf_sem_t;

static void lf_mutex_init(lf_mutex_t* m)      { InitializeCriticalSection(m); }
static void lf_mutex_lock(lf_mutex_t* m)      { EnterCriticalSection(m); }
static void lf_mutex_unlock(lf_mutex_t* m)    { LeaveCriticalSection(m); }
static void lf_mutex_destroy(lf_mutex_t* m)   { DeleteCriticalSection(m); }

static int  lf_sem_init(lf_sem_t* s)
{
    /* Max count is 0x7FFFFFFF: plenty for any realistic request count. */
    *s = CreateSemaphoreA(NULL, 0, 0x7FFFFFFF, NULL);
    return (*s == NULL) ? -1 : 0;
}

static void lf_sem_wait(lf_sem_t* s)
{
    /* No spurious wakeups on Win32; INFINITE means "wait forever". */
    WaitForSingleObject(*s, INFINITE);
}

static void lf_sem_post(lf_sem_t* s)
{
    ReleaseSemaphore(*s, 1, NULL);
}

static void lf_sem_destroy(lf_sem_t* s)
{
    if (*s != NULL) { CloseHandle(*s); *s = NULL; }
}

static lf_lib_handle_t lf_lib_load(const char* name)
{
    return LoadLibraryA(name);
}

static void* lf_lib_sym(lf_lib_handle_t h, const char* name)
{
    return (void*)GetProcAddress((HMODULE)h, name);
}

static void lf_lib_free(lf_lib_handle_t h)
{
    if (h != NULL) { FreeLibrary((HMODULE)h); }
}

/* InterlockedIncrement returns the new value, matching our contract. */
static long lf_atomic_inc(volatile long* p)
{
    return InterlockedIncrement((volatile LONG*)p);
}

#else /* POSIX */

#  include <dlfcn.h>
#  include <errno.h>
#  include <pthread.h>
#  include <semaphore.h>
#  include <unistd.h>

#  define LF_TLS __thread

typedef void*           lf_lib_handle_t;
typedef pthread_mutex_t lf_mutex_t;
typedef sem_t           lf_sem_t;

static void lf_mutex_init(lf_mutex_t* m)    { pthread_mutex_init(m, NULL); }
static void lf_mutex_lock(lf_mutex_t* m)    { pthread_mutex_lock(m); }
static void lf_mutex_unlock(lf_mutex_t* m)  { pthread_mutex_unlock(m); }
static void lf_mutex_destroy(lf_mutex_t* m) { pthread_mutex_destroy(m); }

static int lf_sem_init(lf_sem_t* s)
{
    /* process-private, initial value 0 */
    return sem_init(s, 0, 0);
}

static void lf_sem_wait(lf_sem_t* s)
{
    /* EINTR can occur if the worker thread receives a signal. Loop. */
    int rc;
    do {
        rc = sem_wait(s);
    } while (rc != 0 && errno == EINTR);
}

static void lf_sem_post(lf_sem_t* s)
{
    sem_post(s);
}

static void lf_sem_destroy(lf_sem_t* s)
{
    sem_destroy(s);
}

static lf_lib_handle_t lf_lib_load(const char* name)
{
    return dlopen(name, RTLD_LAZY | RTLD_LOCAL);
}

static void* lf_lib_sym(lf_lib_handle_t h, const char* name)
{
    return dlsym(h, name);
}

static void lf_lib_free(lf_lib_handle_t h)
{
    if (h != NULL) { dlclose(h); }
}

static long lf_atomic_inc(volatile long* p)
{
    return __sync_add_and_fetch(p, 1);
}

#endif /* _WIN32 */

/* ===========================================================================
 * Section 1 -- Global state
 * ===========================================================================
 *
 * Every field below is either write-once (at init) or protected by a
 * lock. The `initialized` flag is read without a lock in a few
 * fast-path checks; this is safe because it is only ever set to 1 by
 * lf_bridge_init (which runs single-threaded, before any other bridge
 * call can succeed) and never cleared except by lf_bridge_shutdown
 * (which is documented as "call from the main isolate only").
 * ========================================================================= */

/* ---------------------------------------------------------------------------
 * LingoFuse symbol table
 * ---------------------------------------------------------------------------
 * We resolve the ~59 exported LingoFuse functions into one array,
 * indexed by an enum. This avoids 59 typedefs and keeps the loader
 * table small and readable.
 *
 * Each entry is used with an explicit cast at the call site. The cast
 * is the type contract; the enum name documents the intent.
 * ------------------------------------------------------------------------- */

enum LF_Sym_Index {
    /* Data handle */
    SYM_CreateData = 0,
    SYM_CreateData_Permanent,
    SYM_FreeData,
    SYM_GetBuffer,
    SYM_WriteBuffer,
    SYM_ReadBuffer,
    SYM_GetPos,
    SYM_SetPos,
    SYM_GetSize,
    SYM_SetSize,
    SYM_Get_P2P_UID,
    SYM_Get_P2P_Name,

    /* Application */
    SYM_CreateApp,
    SYM_FreeApp,
    SYM_Generate_AppName,
    SYM_Get_AppName,
    SYM_BindApp,

    /* Registration (app-bound) */
    SYM_RegisterCall,
    SYM_RegisterNotify,
    SYM_Unregister,

    /* Registration (process-wide P2P) */
    SYM_Register_P2P_Call,
    SYM_Register_P2P_Notify,
    SYM_Unregister_P2P,

    /* Local execution */
    SYM_LocalCall,
    SYM_LocalNotify,

    /* Network preparation */
    SYM_ResetPrepare,
    SYM_PrepareService,
    SYM_PrepareClient,
    SYM_PrepareDone,
    SYM_ExitMainThread,

    /* Invocation (App name) */
    SYM_Call,
    SYM_Async_Call,
    SYM_Async_Sequenced_Call,
    SYM_Notify,
    SYM_Sequenced_Notify,

    /* Invocation (UID) */
    SYM_UID_Call,
    SYM_UID_Async_Call,
    SYM_UID_Async_Sequenced_Call,
    SYM_UID_Notify,
    SYM_UID_Sequenced_Notify,

    /* Invocation (P2PName) */
    SYM_P2PNAME_Call,
    SYM_P2PNAME_Async_Call,
    SYM_P2PNAME_Async_Sequenced_Call,
    SYM_P2PNAME_Notify,
    SYM_P2PNAME_Sequenced_Notify,

    /* Queries */
    SYM_CheckMainThread,
    SYM_CheckApp,
    SYM_CheckApi,
    SYM_Check_UID,
    SYM_Check_UID_Api,
    SYM_Check_P2PNAME,
    SYM_Check_P2PNAME_Api,

    /* Options */
    SYM_SetOption,
    SYM_GetOption,

    /* Status */
    SYM_GetStatusCount,
    SYM_GetStatus,
    SYM_PostStatus,

    /* Network events */
    SYM_Set_Network_Event,

    /* Shutdown */
    SYM_Shutdown,

    LF_SYM_COUNT
};

/* ---------------------------------------------------------------------------
 * Pending request (Protocol A)
 * ------------------------------------------------------------------------- */

typedef struct PendingRequest {
    int64_t        request_id;
    lf_sem_t       sem;
    uint8_t*       out_buf;       /* owned by this struct */
    int64_t        out_size;      /* number of valid bytes in out_buf */
    int64_t        out_capacity;  /* allocated size of out_buf */
    volatile long  completed;     /* 0 -> waiting; 1 -> lf_bridge_complete ran */
    struct PendingRequest* next;  /* singly linked list */
} PendingRequest;

/* ---------------------------------------------------------------------------
 * Global state struct
 * ------------------------------------------------------------------------- */

typedef struct BridgeState {
    /* Lifecycle */
    volatile long initialized;
    int64_t       dart_port_id;

    /* LingoFuse library */
    lf_lib_handle_t lf_lib;
    void*           lf_syms[LF_SYM_COUNT];

    /* Protocol A table */
    lf_mutex_t       pending_lock;
    PendingRequest*  pending_head;
    volatile long    pending_count;

    /* Request ID source (32-bit is plenty) */
    volatile long    next_request_id;

    /* Network event callback IDs (-1 means disabled) */
    volatile long    connect_callback_id;
    volatile long    disconnect_callback_id;

    /* Statistics */
    volatile long    dart_post_ok;
    volatile long    dart_post_fail;
} BridgeState;

static BridgeState g_state;

/* Two distinct callback trampolines are needed for connect/disconnect
 * because LF_NetworkEventFunc has no user-data parameter. The global
 * callback IDs above hold the current values. */

static void LF_DART_CALL bridge_connect_trampoline(const char* addr);
static void LF_DART_CALL bridge_disconnect_trampoline(const char* addr);

static void LF_DART_CALL bridge_call_trampoline(void* trigger, void* input, void* output);
static void LF_DART_CALL bridge_notify_trampoline(void* trigger, void* input);
static void LF_DART_CALL bridge_async_on_result(void* data, void* result);

/* ===========================================================================
 * Section 2 -- Thread-local error string
 * ===========================================================================
 *
 * Every int-returning bridge function that can fail stores a
 * human-readable description here before returning a non-zero code.
 * lf_bridge_last_error() returns a pointer into this buffer.
 *
 * The buffer is thread-local so that two threads cannot overwrite each
 * other's messages. On MSVC, LF_TLS is __declspec(thread); on
 * GCC/Clang it is __thread.
 * ========================================================================= */

#define LF_ERROR_BUF_SIZE 512
static LF_TLS char g_error_buf[LF_ERROR_BUF_SIZE];

static void lf_set_error(const char* fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vsnprintf(g_error_buf, LF_ERROR_BUF_SIZE, fmt, args);
    va_end(args);
}

static void lf_clear_error(void)
{
    g_error_buf[0] = '\0';
}

/* ===========================================================================
 * Section 3 -- LingoFuse dynamic loading and symbol resolution
 * =========================================================================== */

static const char* lf_platform_library_name(void)
{
#if defined(_WIN32)
    /* 64-bit vs 32-bit chosen at runtime; the compiler cannot always
     * be trusted to define _WIN64 correctly under cross-compilation. */
    return (sizeof(void*) == 8) ? "LingoFuse64.dll" : "LingoFuse32.dll";
#elif defined(__APPLE__)
    return "liblingofuse.dylib";
#else
    return "liblingofuse.so";
#endif
}

/* Resolve one symbol; store NULL on failure and return 0. */
static int lf_resolve_symbol(const char* short_name, int slot)
{
    char full_name[128];
    if (snprintf(full_name, sizeof(full_name), "LF_%s", short_name) >=
        (int)sizeof(full_name)) {
        lf_set_error("symbol name too long: %s", short_name);
        return 0;
    }

    void* p = lf_lib_sym(g_state.lf_lib, full_name);
    if (p == NULL) {
        lf_set_error("failed to resolve symbol: %s", full_name);
        return 0;
    }
    g_state.lf_syms[slot] = p;
    return 1;
}

#define RESOLVE(short_name) \
    do { if (!lf_resolve_symbol(#short_name, SYM_##short_name)) return 0; } while (0)

static int lf_load_and_resolve(void)
{
    const char* name = lf_platform_library_name();
    g_state.lf_lib = lf_lib_load(name);
    if (g_state.lf_lib == NULL) {
        lf_set_error(
            "failed to load LingoFuse runtime library '%s'. "
            "Place it next to the executable, or add its directory "
            "to the OS loader search path (PATH on Windows, "
            "LD_LIBRARY_PATH on Linux, DYLD_LIBRARY_PATH on macOS).",
            name);
        return 0;
    }

    /* Data handle */
    RESOLVE(CreateData);
    RESOLVE(CreateData_Permanent);
    RESOLVE(FreeData);
    RESOLVE(GetBuffer);
    RESOLVE(WriteBuffer);
    RESOLVE(ReadBuffer);
    RESOLVE(GetPos);
    RESOLVE(SetPos);
    RESOLVE(GetSize);
    RESOLVE(SetSize);
    RESOLVE(Get_P2P_UID);
    RESOLVE(Get_P2P_Name);

    /* Application */
    RESOLVE(CreateApp);
    RESOLVE(FreeApp);
    RESOLVE(Generate_AppName);
    RESOLVE(Get_AppName);
    RESOLVE(BindApp);

    /* Registration (app-bound) */
    RESOLVE(RegisterCall);
    RESOLVE(RegisterNotify);
    RESOLVE(Unregister);

    /* Registration (process-wide P2P) */
    RESOLVE(Register_P2P_Call);
    RESOLVE(Register_P2P_Notify);
    RESOLVE(Unregister_P2P);

    /* Local execution */
    RESOLVE(LocalCall);
    RESOLVE(LocalNotify);

    /* Network preparation */
    RESOLVE(ResetPrepare);
    RESOLVE(PrepareService);
    RESOLVE(PrepareClient);
    RESOLVE(PrepareDone);
    RESOLVE(ExitMainThread);

    /* Invocation (App name) */
    RESOLVE(Call);
    RESOLVE(Async_Call);
    RESOLVE(Async_Sequenced_Call);
    RESOLVE(Notify);
    RESOLVE(Sequenced_Notify);

    /* Invocation (UID) */
    RESOLVE(UID_Call);
    RESOLVE(UID_Async_Call);
    RESOLVE(UID_Async_Sequenced_Call);
    RESOLVE(UID_Notify);
    RESOLVE(UID_Sequenced_Notify);

    /* Invocation (P2PName) */
    RESOLVE(P2PNAME_Call);
    RESOLVE(P2PNAME_Async_Call);
    RESOLVE(P2PNAME_Async_Sequenced_Call);
    RESOLVE(P2PNAME_Notify);
    RESOLVE(P2PNAME_Sequenced_Notify);

    /* Queries */
    RESOLVE(CheckMainThread);
    RESOLVE(CheckApp);
    RESOLVE(CheckApi);
    RESOLVE(Check_UID);
    RESOLVE(Check_UID_Api);
    RESOLVE(Check_P2PNAME);
    RESOLVE(Check_P2PNAME_Api);

    /* Options */
    RESOLVE(SetOption);
    RESOLVE(GetOption);

    /* Status */
    RESOLVE(GetStatusCount);
    RESOLVE(GetStatus);
    RESOLVE(PostStatus);

    /* Network events */
    RESOLVE(Set_Network_Event);

    /* Shutdown */
    RESOLVE(Shutdown);

    return 1;
}

/* Convenience macro used at call sites. The cast is the type contract. */
#define LF_GET(slot) (g_state.lf_syms[slot])

/* ===========================================================================
 * Section 4 -- Dart PostCObject helpers
 * ===========================================================================
 *
 * Two message shapes are posted:
 *
 *   Call / Notify (3-element):
 *     [ request_id : int64, callback_id : int64, input : Uint8List ]
 *
 *   Async / Network event (2-element):
 *     [ op_id : int64, payload : Uint8List ]
 *
 * The Dart side dispatches on array length. The bridge never sees the
 * reply; it is Dart's responsibility to look up the right handler.
 * ========================================================================= */

static int lf_post_two(int64_t a, const uint8_t* bytes, intptr_t size)
{
    Dart_CObject c_a;
    c_a.type = Dart_CObject_kInt64;
    c_a.value.as_int64 = a;

    Dart_CObject c_bytes;
    c_bytes.type = Dart_CObject_kTypedData;
    c_bytes.value.as_typed_data.type   = Dart_TypedData_kUint8;
    c_bytes.value.as_typed_data.length = size;
    /* If size is zero, Dart accepts a NULL values pointer; providing a
     * non-NULL dummy avoids a class of platform-specific edge cases. */
    static uint8_t dummy = 0;
    c_bytes.value.as_typed_data.values =
        (size > 0 && bytes != NULL) ? (uint8_t*)bytes : &dummy;

    Dart_CObject* elems[2] = { &c_a, &c_bytes };
    Dart_CObject arr;
    arr.type = Dart_CObject_kArray;
    arr.value.as_array.length = 2;
    arr.value.as_array.values = elems;

    if (!Dart_PostCObject_DL(g_state.dart_port_id, &arr)) {
        lf_atomic_inc(&g_state.dart_post_fail);
        return 0;
    }
    lf_atomic_inc(&g_state.dart_post_ok);
    return 1;
}

static int lf_post_three(int64_t a, int64_t b, const uint8_t* bytes, intptr_t size)
{
    Dart_CObject c_a;
    c_a.type = Dart_CObject_kInt64;
    c_a.value.as_int64 = a;

    Dart_CObject c_b;
    c_b.type = Dart_CObject_kInt64;
    c_b.value.as_int64 = b;

    Dart_CObject c_bytes;
    c_bytes.type = Dart_CObject_kTypedData;
    c_bytes.value.as_typed_data.type   = Dart_TypedData_kUint8;
    c_bytes.value.as_typed_data.length = size;
    static uint8_t dummy = 0;
    c_bytes.value.as_typed_data.values =
        (size > 0 && bytes != NULL) ? (uint8_t*)bytes : &dummy;

    Dart_CObject* elems[3] = { &c_a, &c_b, &c_bytes };
    Dart_CObject arr;
    arr.type = Dart_CObject_kArray;
    arr.value.as_array.length = 3;
    arr.value.as_array.values = elems;

    if (!Dart_PostCObject_DL(g_state.dart_port_id, &arr)) {
        lf_atomic_inc(&g_state.dart_post_fail);
        return 0;
    }
    lf_atomic_inc(&g_state.dart_post_ok);
    return 1;
}

/* Copy the entire contents of a LingoFuse data handle into a fresh
 * malloc'd buffer. Returns NULL on failure or for a zero-size handle;
 * sets *out_size accordingly. */
static uint8_t* lf_snapshot_handle(void* hnd, int64_t* out_size)
{
    *out_size = 0;
    if (hnd == NULL) { return NULL; }

    int64_t size =
        ((int64_t(*)(void*))LF_GET(SYM_GetSize))(hnd);
    if (size <= 0) { return NULL; }

    uint8_t* buf = (uint8_t*)malloc((size_t)size);
    if (buf == NULL) { return NULL; }

    ((void(*)(void*, int64_t))LF_GET(SYM_SetPos))(hnd, 0);
    int64_t got =
        ((int64_t(*)(void*, void*, int64_t))LF_GET(SYM_ReadBuffer))(hnd, buf, size);
    if (got != size) {
        free(buf);
        return NULL;
    }
    *out_size = size;
    return buf;
}

/* ===========================================================================
 * Section 5 -- Protocol A: pending-request table and trampolines
 * ===========================================================================
 *
 * Protocol A is used by registered Call / Notify handlers and by the
 * local-execution entry points. The native worker THREAD BLOCKS until
 * Dart replies via lf_bridge_complete (for Call) or returns without
 * waiting (for Notify, which produces no output).
 *
 * The table is a simple singly linked list guarded by a mutex. Real
 * workloads have at most a few dozen concurrent requests, so the
 * linear search is not a bottleneck.
 * ========================================================================= */

static PendingRequest* lf_pending_find_locked(int64_t request_id)
{
    PendingRequest* p = g_state.pending_head;
    while (p != NULL) {
        if (p->request_id == request_id) { return p; }
        p = p->next;
    }
    return NULL;
}

static void lf_pending_insert_locked(PendingRequest* req)
{
    req->next = g_state.pending_head;
    g_state.pending_head = req;
    lf_atomic_inc(&g_state.pending_count);
}

static void lf_pending_remove_locked(PendingRequest* req)
{
    PendingRequest** pp = &g_state.pending_head;
    while (*pp != NULL) {
        if (*pp == req) {
            *pp = req->next;
            lf_atomic_inc(&g_state.pending_count); /* decrement below */
            /* We use lf_atomic_inc as a generic "modify" op; a
             * dedicated atomic decrement would be cleaner but this
             * keeps the platform abstraction tiny. */
            return;
        }
        pp = &(*pp)->next;
    }
}

/* Real decrement; the "inc" above is a bookkeeping hack that we undo
 * here to avoid adding a new platform primitive. */
static void lf_pending_dec_count(void)
{
    /* We rely on the fact that pending_count is only read for stats. */
    /* Decrement by simulating: pending_count -= 2 (undo the false +1). */
#if defined(_WIN32)
    InterlockedExchangeAdd((volatile LONG*)&g_state.pending_count, -2);
#else
    __sync_add_and_fetch(&g_state.pending_count, -2);
#endif
}

/* Actually, on reflection, the above is fragile. Replace it with a
 * clean implementation: pending_count is only updated at insert and
 * remove, and always by exactly +1 or -1. */
#undef lf_pending_remove_locked

static void lf_pending_remove_locked_clean(PendingRequest* req)
{
    PendingRequest** pp = &g_state.pending_head;
    while (*pp != NULL) {
        if (*pp == req) {
            *pp = req->next;
#if defined(_WIN32)
            InterlockedDecrement((volatile LONG*)&g_state.pending_count);
#else
            __sync_sub_and_fetch(&g_state.pending_count, 1);
#endif
            return;
        }
        pp = &(*pp)->next;
    }
}

#define lf_pending_remove_locked lf_pending_remove_locked_clean

/* ---- Protocol A trampolines ---- */

static void LF_DART_CALL bridge_call_trampoline(
    void* trigger, void* input, void* output)
{
    int64_t callback_id = (int64_t)(intptr_t)trigger;

    /* Snapshot the input bytes. */
    int64_t in_size = 0;
    uint8_t* in_buf = lf_snapshot_handle(input, &in_size);

    /* Allocate a pending-request record. */
    PendingRequest* req = (PendingRequest*)calloc(1, sizeof(PendingRequest));
    if (req == NULL) {
        if (in_buf != NULL) { free(in_buf); }
        return;
    }

    if (lf_sem_init(&req->sem) != 0) {
        free(req);
        if (in_buf != NULL) { free(in_buf); }
        return;
    }

    req->request_id = (int64_t)lf_atomic_inc(&g_state.next_request_id);
    if (req->request_id == 0) {
        /* Wrap-around protection: request_id 0 is reserved for Notify. */
        req->request_id = (int64_t)lf_atomic_inc(&g_state.next_request_id);
    }

    lf_mutex_lock(&g_state.pending_lock);
    lf_pending_insert_locked(req);
    lf_mutex_unlock(&g_state.pending_lock);

    /* Post the message. Dart owns its copy of the bytes after the
     * PostCObject call returns, so we can free our snapshot now. */
    int ok = lf_post_three(req->request_id, callback_id, in_buf, (intptr_t)in_size);
    if (in_buf != NULL) { free(in_buf); }

    if (!ok) {
        /* Post failed: unwind and return without writing output. */
        lf_mutex_lock(&g_state.pending_lock);
        lf_pending_remove_locked(req);
        lf_mutex_unlock(&g_state.pending_lock);
        lf_sem_destroy(&req->sem);
        free(req);
        return;
    }

    /* Block until Dart calls lf_bridge_complete with our request_id. */
    lf_sem_wait(&req->sem);

    /* Copy the output bytes into the LingoFuse output handle. */
    if (req->out_size > 0 && req->out_buf != NULL && output != NULL) {
        ((int64_t(*)(void*, const void*, int64_t))LF_GET(SYM_WriteBuffer))
            (output, req->out_buf, req->out_size);
    }

    /* Cleanup. The record is no longer reachable by request_id once we
     * remove it under the lock. */
    lf_mutex_lock(&g_state.pending_lock);
    lf_pending_remove_locked(req);
    lf_mutex_unlock(&g_state.pending_lock);

    lf_sem_destroy(&req->sem);
    if (req->out_buf != NULL) { free(req->out_buf); }
    free(req);
}

static void LF_DART_CALL bridge_notify_trampoline(
    void* trigger, void* input)
{
    int64_t callback_id = (int64_t)(intptr_t)trigger;

    int64_t in_size = 0;
    uint8_t* in_buf = lf_snapshot_handle(input, &in_size);

    /* request_id 0 signals "no reply expected". Dart will not call
     * lf_bridge_complete for this message. */
    (void)lf_post_three(0, callback_id, in_buf, (intptr_t)in_size);

    if (in_buf != NULL) { free(in_buf); }
}

/* ===========================================================================
 * Section 6 -- Protocol B: fire-and-forget trampolines
 * ===========================================================================
 *
 * The asynchronous call family and the network event handlers use this
 * protocol. The native worker posts a message to the Dart isolate and
 * returns IMMEDIATELY. Nothing blocks.
 *
 * Memory safety: Dart_PostCObject_DL synchronously copies typed-data
 * payloads into the Dart heap. This means the source buffer can be
 * freed as soon as the call returns, and in particular BEFORE the user
 * callback runs.
 * ========================================================================= */

static void LF_DART_CALL bridge_async_on_result(void* data, void* result)
{
    int64_t op_id = (int64_t)(intptr_t)data;

    /* Snapshot the result handle. NOTE: the framework releases the
     * result handle the instant this function returns, so this copy is
     * mandatory and must complete before we return. */
    int64_t size = 0;
    uint8_t* buf = lf_snapshot_handle(result, &size);

    (void)lf_post_two(op_id, buf, (intptr_t)size);

    if (buf != NULL) { free(buf); }
    /* Return immediately. Do not touch `result` again. */
}

static void lf_post_network_event(int64_t callback_id, const char* addr)
{
    if (callback_id < 0) { return; }

    /* The addr string is UTF-8, NUL-terminated, and only valid during
     * the callback. We post a Uint8List rather than a Dart string so
     * that the bridge does not have to reason about UTF-8 vs UTF-16
     * at the C/Dart boundary. */
    const uint8_t* bytes = (const uint8_t*)(addr != NULL ? addr : "");
    intptr_t len = (intptr_t)(addr != NULL ? strlen(addr) : 0);

    (void)lf_post_two(callback_id, bytes, len);
}

static void LF_DART_CALL bridge_connect_trampoline(const char* addr)
{
    lf_post_network_event(g_state.connect_callback_id, addr);
}

static void LF_DART_CALL bridge_disconnect_trampoline(const char* addr)
{
    lf_post_network_event(g_state.disconnect_callback_id, addr);
}

/* ===========================================================================
 * Section 7 -- Option helpers
 * ===========================================================================
 *
 * Thin wrappers around LF_SetOption / LF_GetOption that handle the
 * stringly-typed marshalling once, so that every typed option entry
 * point below is a one-liner.
 * ========================================================================= */

static void lf_set_option_str(const char* key, const char* value)
{
    ((void(*)(const char*, const char*))LF_GET(SYM_SetOption))(key, value);
}

static void lf_set_option_bool(const char* key, int value)
{
    lf_set_option_str(key, value ? "True" : "False");
}

static void lf_set_option_int(const char* key, int value)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", value);
    lf_set_option_str(key, buf);
}

static void lf_set_option_u64(const char* key, uint64_t value)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)value);
    lf_set_option_str(key, buf);
}

static const char* lf_get_option_str(const char* key)
{
    const char* v =
        ((const char*(*)(const char*))LF_GET(SYM_GetOption))(key);
    return v != NULL ? v : "";
}

static int lf_get_option_bool(const char* key)
{
    const char* v = lf_get_option_str(key);
    /* The Pascal side writes "True" / "False". We accept a few
     * case-insensitive spellings for robustness. */
    if (v[0] == '\0') { return 0; }
    if ((v[0] == 'T' || v[0] == 't') && (v[1] == 'r' || v[1] == 'R')) { return 1; }
    if (v[0] == '1') { return 1; }
    if ((v[0] == 'Y' || v[0] == 'y') && (v[1] == 'e' || v[1] == 'E')) { return 1; }
    return 0;
}

static int lf_get_option_int(const char* key)
{
    const char* v = lf_get_option_str(key);
    if (v[0] == '\0') { return 0; }
    return (int)strtol(v, NULL, 10);
}

static uint64_t lf_get_option_u64(const char* key)
{
    const char* v = lf_get_option_str(key);
    if (v[0] == '\0') { return 0; }
    return (uint64_t)strtoull(v, NULL, 10);
}

static int lf_copy_string_into(
    const char* src, char* out_buf, int buf_size)
{
    if (out_buf == NULL || buf_size <= 0) {
        lf_set_error("output buffer is NULL or too small");
        return LFB_ERR_INVALID_ARGUMENT;
    }
    if (src == NULL) { src = ""; }

    size_t needed = strlen(src) + 1;
    if (needed > (size_t)buf_size) {
        memcpy(out_buf, src, (size_t)(buf_size - 1));
        out_buf[buf_size - 1] = '\0';
        lf_set_error(
            "output buffer too small: need %zu bytes, got %d",
            needed, buf_size);
        return LFB_ERR_BUFFER_TOO_SMALL;
    }
    memcpy(out_buf, src, needed);
    return LFB_OK;
}

/* Convenience macro for int-returning setters. */
#define DEFINE_OPT_SETTER(fn, key, setter)                                     \
    int LF_DART_CALL fn(const char* value) {                                   \
        lf_clear_error();                                                      \
        if (!g_state.initialized) {                                            \
            lf_set_error("bridge is not initialized");                         \
            return LFB_ERR_NOT_INITIALIZED;                                    \
        }                                                                      \
        if (value == NULL) { value = ""; }                                     \
        setter(key, value);                                                    \
        return LFB_OK;                                                         \
    }

#define DEFINE_OPT_GETTER_STR(fn, key)                                         \
    int LF_DART_CALL fn(char* out_buf, int buf_size) {                         \
        lf_clear_error();                                                      \
        if (!g_state.initialized) {                                            \
            lf_set_error("bridge is not initialized");                         \
            return LFB_ERR_NOT_INITIALIZED;                                    \
        }                                                                      \
        return lf_copy_string_into(lf_get_option_str(key), out_buf, buf_size); \
    }

#define DEFINE_OPT_BOOL(fn_base, key)                                          \
    int LF_DART_CALL fn_base##_set(int value) {                                \
        lf_clear_error();                                                      \
        if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }          \
        lf_set_option_bool(key, value);                                        \
        return LFB_OK;                                                         \
    }                                                                          \
    int LF_DART_CALL fn_base##_get(void) {                                     \
        if (!g_state.initialized) { return 0; }                                \
        return lf_get_option_bool(key);                                        \
    }

#define DEFINE_OPT_INT(fn_base, key)                                           \
    int LF_DART_CALL fn_base##_set(int value) {                                \
        lf_clear_error();                                                      \
        if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }          \
        lf_set_option_int(key, value);                                         \
        return LFB_OK;                                                         \
    }                                                                          \
    int LF_DART_CALL fn_base##_get(void) {                                     \
        if (!g_state.initialized) { return 0; }                                \
        return lf_get_option_int(key);                                         \
    }

#define DEFINE_OPT_U64(fn_base, key)                                           \
    int LF_DART_CALL fn_base##_set(uint64_t value) {                           \
        lf_clear_error();                                                      \
        if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }          \
        lf_set_option_u64(key, value);                                         \
        return LFB_OK;                                                         \
    }                                                                          \
    int LF_DART_CALL fn_base##_get(void) {                                     \
        if (!g_state.initialized) { return 0; }                                \
        uint64_t v = lf_get_option_u64(key);                                   \
        /* The header declares these getters as int; clamp to INT_MAX. */      \
        if (v > 0x7FFFFFFFULL) { v = 0x7FFFFFFFULL; }                          \
        return (int)v;                                                         \
    }

/* ===========================================================================
 * Section 8 -- Exported functions
 * ===========================================================================
 *
 * Order matches the header. Each function is a short, direct
 * implementation; the interesting logic (Protocol A / B, option
 * marshalling, string copying) lives in the helper sections above.
 * ========================================================================= */

/* ---- Section 0: Lifecycle ---- */

int LF_DART_CALL lf_bridge_init(int64_t dart_port_id, void* api_dl_data)
{
    lf_clear_error();

    if (g_state.initialized) {
        /* Re-initialization with the same port is a no-op. A different
         * port is a programming error. */
        if (g_state.dart_port_id != dart_port_id) {
            lf_set_error(
                "bridge is already initialized with a different port ID");
            return LFB_ERR_BRIDGE_INTERNAL;
        }
        return LFB_OK;
    }

    if (api_dl_data == NULL) {
        lf_set_error(
            "api_dl_data is NULL; pass NativeApi.initializeApiDLData");
        return LFB_ERR_INVALID_ARGUMENT;
    }

    /* Register the Dart API DL table first. This must happen before
     * Dart_PostCObject_DL can be used from a non-Dart thread. */
    int rc = (int)Dart_InitializeApiDL(api_dl_data);
    if (rc != 0) {
        lf_set_error("Dart_InitializeApiDL failed with code %d", rc);
        return LFB_ERR_BRIDGE_INTERNAL;
    }

    memset(&g_state, 0, sizeof(g_state));
    g_state.dart_port_id = dart_port_id;
    g_state.connect_callback_id = -1;
    g_state.disconnect_callback_id = -1;

    lf_mutex_init(&g_state.pending_lock);

    if (!lf_load_and_resolve()) {
        lf_mutex_destroy(&g_state.pending_lock);
        if (g_state.lf_lib != NULL) {
            lf_lib_free(g_state.lf_lib);
            g_state.lf_lib = NULL;
        }
        return LFB_ERR_LIBRARY_NOT_LOADED;
    }

    g_state.initialized = 1;
    return LFB_OK;
}

void LF_DART_CALL lf_bridge_shutdown(void)
{
    if (!g_state.initialized) { return; }

    /* Mark not-initialized first so that any in-flight callback sees
     * the change and bails out cleanly. */
    g_state.initialized = 0;

    /* Release pending-request resources. There is no way to wake a
     * blocked worker thread safely from here; the documented contract
     * is that lf_bridge_shutdown is called only after all requests
     * have completed. */
    lf_mutex_lock(&g_state.pending_lock);
    PendingRequest* p = g_state.pending_head;
    g_state.pending_head = NULL;
    g_state.pending_count = 0;
    lf_mutex_unlock(&g_state.pending_lock);

    while (p != NULL) {
        PendingRequest* next = p->next;
        lf_sem_destroy(&p->sem);
        if (p->out_buf != NULL) { free(p->out_buf); }
        free(p);
        p = next;
    }

    lf_mutex_destroy(&g_state.pending_lock);

    if (g_state.lf_lib != NULL) {
        lf_lib_free(g_state.lf_lib);
        g_state.lf_lib = NULL;
    }

    memset(g_state.lf_syms, 0, sizeof(g_state.lf_syms));
}

int LF_DART_CALL lf_bridge_is_initialized(void)
{
    return g_state.initialized ? 1 : 0;
}

/* ---- Section 1: Data handle ---- */

void* LF_DART_CALL lf_bridge_create_data(const char* api_name)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return NULL; }
    if (api_name == NULL) { lf_set_error("null api_name"); return NULL; }
    return ((void*(*)(const char*))LF_GET(SYM_CreateData))(api_name);
}

void* LF_DART_CALL lf_bridge_create_data_permanent(const char* api_name)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return NULL; }
    if (api_name == NULL) { lf_set_error("null api_name"); return NULL; }
    return ((void*(*)(const char*))LF_GET(SYM_CreateData_Permanent))(api_name);
}

void LF_DART_CALL lf_bridge_free_data(void* hnd)
{
    if (!g_state.initialized) { return; }
    ((void(*)(void*))LF_GET(SYM_FreeData))(hnd);
}

int64_t LF_DART_CALL lf_bridge_write_buffer(void* hnd, const void* buff, int64_t size)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return -1; }
    if (hnd == NULL) { lf_set_error("null handle"); return -1; }
    return ((int64_t(*)(void*, const void*, int64_t))LF_GET(SYM_WriteBuffer))
        (hnd, buff, size);
}

int64_t LF_DART_CALL lf_bridge_read_buffer(void* hnd, void* buff, int64_t size)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return -1; }
    if (hnd == NULL) { lf_set_error("null handle"); return -1; }
    return ((int64_t(*)(void*, void*, int64_t))LF_GET(SYM_ReadBuffer))
        (hnd, buff, size);
}

int64_t LF_DART_CALL lf_bridge_get_pos(void* hnd)
{
    if (!g_state.initialized || hnd == NULL) { return -1; }
    return ((int64_t(*)(void*))LF_GET(SYM_GetPos))(hnd);
}

void LF_DART_CALL lf_bridge_set_pos(void* hnd, int64_t pos)
{
    if (!g_state.initialized || hnd == NULL) { return; }
    ((void(*)(void*, int64_t))LF_GET(SYM_SetPos))(hnd, pos);
}

int64_t LF_DART_CALL lf_bridge_get_size(void* hnd)
{
    if (!g_state.initialized || hnd == NULL) { return -1; }
    return ((int64_t(*)(void*))LF_GET(SYM_GetSize))(hnd);
}

void LF_DART_CALL lf_bridge_set_size(void* hnd, int64_t size)
{
    if (!g_state.initialized || hnd == NULL) { return; }
    ((void(*)(void*, int64_t))LF_GET(SYM_SetSize))(hnd, size);
}

int LF_DART_CALL lf_bridge_get_p2p_uid(void* hnd, uint8_t* out_uid_32)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (hnd == NULL || out_uid_32 == NULL) {
        lf_set_error("null handle or null output buffer");
        return LFB_ERR_INVALID_ARGUMENT;
    }

    /* The Pascal side returns a pointer (PP2P_UID___). We dereference
     * and copy immediately; we never return the pointer to Dart and
     * never free it (the library does that on its own schedule). */
    const void* ptr =
        ((const void*(*)(void*))LF_GET(SYM_Get_P2P_UID))(hnd);
    if (ptr == NULL) {
        memset(out_uid_32, 0, 32);
    } else {
        memcpy(out_uid_32, ptr, 32);
    }
    return LFB_OK;
}

int LF_DART_CALL lf_bridge_get_p2p_name(void* hnd, char* out_buf, int buf_size)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (hnd == NULL) { lf_set_error("null handle"); return LFB_ERR_INVALID_ARGUMENT; }

    const char* p =
        ((const char*(*)(void*))LF_GET(SYM_Get_P2P_Name))(hnd);
    return lf_copy_string_into(p, out_buf, buf_size);
}

int LF_DART_CALL lf_bridge_write_uid(void* hnd, const uint8_t* uid_32)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (hnd == NULL || uid_32 == NULL) {
        lf_set_error("null handle or null uid");
        return LFB_ERR_INVALID_ARGUMENT;
    }

    int64_t written =
        ((int64_t(*)(void*, const void*, int64_t))LF_GET(SYM_WriteBuffer))
            (hnd, uid_32, 32);
    if (written != 32) {
        lf_set_error("short write: %lld of 32", (long long)written);
        return LFB_ERR_LINGOFUSE_FAILED;
    }
    return LFB_OK;
}

int LF_DART_CALL lf_bridge_read_uid(void* hnd, uint8_t* out_uid_32)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (hnd == NULL || out_uid_32 == NULL) {
        lf_set_error("null handle or null output buffer");
        return LFB_ERR_INVALID_ARGUMENT;
    }

    int64_t got =
        ((int64_t(*)(void*, void*, int64_t))LF_GET(SYM_ReadBuffer))
            (hnd, out_uid_32, 32);
    if (got != 32) {
        lf_set_error("short read: %lld of 32", (long long)got);
        return LFB_ERR_LINGOFUSE_FAILED;
    }
    return LFB_OK;
}

/* ---- Section 2: Application handle ---- */

void* LF_DART_CALL lf_bridge_create_app(const char* app_name, const char* desc)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return NULL; }
    if (app_name == NULL) { lf_set_error("null app_name"); return NULL; }
    if (desc == NULL) { desc = ""; }
    return ((void*(*)(const char*, const char*))LF_GET(SYM_CreateApp))
        (app_name, desc);
}

void LF_DART_CALL lf_bridge_free_app(void* app_hnd)
{
    if (!g_state.initialized) { return; }
    ((void(*)(void*))LF_GET(SYM_FreeApp))(app_hnd);
}

int LF_DART_CALL lf_bridge_get_app_name(void* app_hnd, char* out_buf, int buf_size)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (app_hnd == NULL) { lf_set_error("null app handle"); return LFB_ERR_INVALID_ARGUMENT; }

    const char* p =
        ((const char*(*)(void*))LF_GET(SYM_Get_AppName))(app_hnd);
    return lf_copy_string_into(p, out_buf, buf_size);
}

int LF_DART_CALL lf_bridge_generate_app_name(char* out_buf, int buf_size)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }

    const char* p =
        ((const char*(*)())LF_GET(SYM_Generate_AppName))();
    return lf_copy_string_into(p, out_buf, buf_size);
}

int LF_DART_CALL lf_bridge_bind_app(void* app_hnd)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return -LFB_ERR_NOT_INITIALIZED; }
    if (app_hnd == NULL) { lf_set_error("null app handle"); return -LFB_ERR_INVALID_ARGUMENT; }
    return ((int(*)(void*))LF_GET(SYM_BindApp))(app_hnd);
}

/* ---- Section 3: Registration (app-bound) ---- */

int LF_DART_CALL lf_bridge_register_call(
    void* app_hnd, const char* method_name, const char* desc, int64_t callback_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (app_hnd == NULL || method_name == NULL) {
        lf_set_error("null argument");
        return LFB_ERR_INVALID_ARGUMENT;
    }
    if (desc == NULL) { desc = ""; }

    int rc = ((int(*)(void*, const char*, const char*, void*, void*))LF_GET(SYM_RegisterCall))
        (app_hnd, method_name, desc,
         (void*)(intptr_t)callback_id,
         (void*)bridge_call_trampoline);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

int LF_DART_CALL lf_bridge_register_notify(
    void* app_hnd, const char* method_name, const char* desc, int64_t callback_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (app_hnd == NULL || method_name == NULL) {
        lf_set_error("null argument");
        return LFB_ERR_INVALID_ARGUMENT;
    }
    if (desc == NULL) { desc = ""; }

    int rc = ((int(*)(void*, const char*, const char*, void*, void*))LF_GET(SYM_RegisterNotify))
        (app_hnd, method_name, desc,
         (void*)(intptr_t)callback_id,
         (void*)bridge_notify_trampoline);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

int LF_DART_CALL lf_bridge_unregister(void* app_hnd, const char* method_name)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (app_hnd == NULL || method_name == NULL) {
        lf_set_error("null argument");
        return LFB_ERR_INVALID_ARGUMENT;
    }
    int rc = ((int(*)(void*, const char*))LF_GET(SYM_Unregister))(app_hnd, method_name);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

int LF_DART_CALL lf_bridge_complete(
    int64_t request_id, const uint8_t* output, int64_t size)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (size < 0) { lf_set_error("negative size"); return LFB_ERR_INVALID_ARGUMENT; }
    if (size > 0 && output == NULL) {
        lf_set_error("null output with size > 0");
        return LFB_ERR_INVALID_ARGUMENT;
    }

    lf_mutex_lock(&g_state.pending_lock);

    PendingRequest* req = lf_pending_find_locked(request_id);
    if (req == NULL) {
        lf_mutex_unlock(&g_state.pending_lock);
        lf_set_error("unknown request_id: %lld", (long long)request_id);
        return LFB_ERR_INVALID_ARGUMENT;
    }
    if (req->completed) {
        lf_mutex_unlock(&g_state.pending_lock);
        lf_set_error("request_id %lld already completed", (long long)request_id);
        return LFB_ERR_INVALID_ARGUMENT;
    }

    /* Grow the output buffer if needed. */
    if (size > req->out_capacity) {
        uint8_t* new_buf = (uint8_t*)realloc(req->out_buf, (size_t)size);
        if (new_buf == NULL) {
            lf_mutex_unlock(&g_state.pending_lock);
            lf_set_error("out of memory growing output buffer");
            return LFB_ERR_BRIDGE_INTERNAL;
        }
        req->out_buf = new_buf;
        req->out_capacity = size;
    }

    if (size > 0) {
        memcpy(req->out_buf, output, (size_t)size);
    }
    req->out_size = size;
    req->completed = 1;

    lf_mutex_unlock(&g_state.pending_lock);

    /* Wake the blocked native worker. */
    lf_sem_post(&req->sem);
    return LFB_OK;
}

/* ---- Section 4: Registration (process-wide P2P) ---- */

int LF_DART_CALL lf_bridge_register_p2p_call(
    const char* method_name, const char* desc, int64_t callback_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (method_name == NULL) {
        lf_set_error("null method_name");
        return LFB_ERR_INVALID_ARGUMENT;
    }
    if (desc == NULL) { desc = ""; }

    int rc = ((int(*)(const char*, const char*, void*, void*))LF_GET(SYM_Register_P2P_Call))
        (method_name, desc,
         (void*)(intptr_t)callback_id,
         (void*)bridge_call_trampoline);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

int LF_DART_CALL lf_bridge_register_p2p_notify(
    const char* method_name, const char* desc, int64_t callback_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (method_name == NULL) {
        lf_set_error("null method_name");
        return LFB_ERR_INVALID_ARGUMENT;
    }
    if (desc == NULL) { desc = ""; }

    int rc = ((int(*)(const char*, const char*, void*, void*))LF_GET(SYM_Register_P2P_Notify))
        (method_name, desc,
         (void*)(intptr_t)callback_id,
         (void*)bridge_notify_trampoline);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

int LF_DART_CALL lf_bridge_unregister_p2p(const char* method_name)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (method_name == NULL) {
        lf_set_error("null method_name");
        return LFB_ERR_INVALID_ARGUMENT;
    }
    int rc = ((int(*)(const char*))LF_GET(SYM_Unregister_P2P))(method_name);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

/* ---- Section 5: Local execution ---- */

void* LF_DART_CALL lf_bridge_local_call(void* app_hnd, void* param)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return NULL; }
    if (app_hnd == NULL || param == NULL) {
        lf_set_error("null argument");
        return NULL;
    }
    return ((void*(*)(void*, void*))LF_GET(SYM_LocalCall))(app_hnd, param);
}

void LF_DART_CALL lf_bridge_local_notify(void* app_hnd, void* param)
{
    if (!g_state.initialized) { return; }
    if (app_hnd == NULL || param == NULL) { return; }
    ((void(*)(void*, void*))LF_GET(SYM_LocalNotify))(app_hnd, param);
}

/* ---- Section 6: Network preparation ---- */

void LF_DART_CALL lf_bridge_reset_prepare(void)
{
    if (!g_state.initialized) { return; }
    ((void(*)())LF_GET(SYM_ResetPrepare))();
}

int LF_DART_CALL lf_bridge_prepare_service(
    const char* listening_addr, const char* physics_addr)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return -LFB_ERR_NOT_INITIALIZED; }
    if (listening_addr == NULL || physics_addr == NULL) {
        lf_set_error("null address");
        return -LFB_ERR_INVALID_ARGUMENT;
    }
    return ((int(*)(const char*, const char*))LF_GET(SYM_PrepareService))
        (listening_addr, physics_addr);
}

int LF_DART_CALL lf_bridge_prepare_client(
    const char* physics_addr, void* app_hnd)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return -LFB_ERR_NOT_INITIALIZED; }
    if (physics_addr == NULL) {
        lf_set_error("null address");
        return -LFB_ERR_INVALID_ARGUMENT;
    }
    return ((int(*)(const char*, void*))LF_GET(SYM_PrepareClient))
        (physics_addr, app_hnd);
}

int LF_DART_CALL lf_bridge_prepare_done(void)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return -LFB_ERR_NOT_INITIALIZED; }
    return ((int(*)())LF_GET(SYM_PrepareDone))();
}

void LF_DART_CALL lf_bridge_exit_main_thread(void)
{
    if (!g_state.initialized) { return; }
    ((void(*)())LF_GET(SYM_ExitMainThread))();
}

void LF_DART_CALL lf_bridge_lf_shutdown(void)
{
    if (!g_state.initialized) { return; }
    ((void(*)())LF_GET(SYM_Shutdown))();
}

/* ---- Section 7: Invocation (App name) ---- */

void* LF_DART_CALL lf_bridge_call(
    const char* app_name, void* param, uint64_t timeout_ms)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return NULL; }
    if (app_name == NULL) { lf_set_error("null app_name"); return NULL; }
    return ((void*(*)(const char*, void*, uint64_t))LF_GET(SYM_Call))
        (app_name, param, timeout_ms);
}

void LF_DART_CALL lf_bridge_notify(const char* app_name, void* param)
{
    if (!g_state.initialized) { return; }
    if (app_name == NULL) { return; }
    ((void(*)(const char*, void*))LF_GET(SYM_Notify))(app_name, param);
}

void LF_DART_CALL lf_bridge_sequenced_notify(const char* app_name, void* param)
{
    if (!g_state.initialized) { return; }
    if (app_name == NULL) { return; }
    ((void(*)(const char*, void*))LF_GET(SYM_Sequenced_Notify))(app_name, param);
}

int LF_DART_CALL lf_bridge_call_async(
    const char* app_name, void* param, int64_t op_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (app_name == NULL) { lf_set_error("null app_name"); return LFB_ERR_INVALID_ARGUMENT; }
    int rc = ((int(*)(const char*, void*, void*, void*))LF_GET(SYM_Async_Call))
        (app_name, param,
         (void*)(intptr_t)op_id,
         (void*)bridge_async_on_result);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

int LF_DART_CALL lf_bridge_call_async_sequenced(
    const char* app_name, void* param, int64_t op_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (app_name == NULL) { lf_set_error("null app_name"); return LFB_ERR_INVALID_ARGUMENT; }
    int rc = ((int(*)(const char*, void*, void*, void*))LF_GET(SYM_Async_Sequenced_Call))
        (app_name, param,
         (void*)(intptr_t)op_id,
         (void*)bridge_async_on_result);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

/* ---- Section 8: Invocation (UID) ---- */

/* The ARGUMENT-role UID: a 32-byte aggregate passed BY VALUE.
 * On x86-64 this matches Pascal's `array[0..31] of Byte` because both
 * are classified MEMORY by the psABI. */
typedef struct {
    uint8_t bytes[32];
} TP2P_UID_VAL;

static void lf_uid_pack(const uint8_t* src, TP2P_UID_VAL* dst)
{
    memcpy(dst->bytes, src, 32);
}

void* LF_DART_CALL lf_bridge_uid_call(
    const uint8_t* uid_32, void* param, uint64_t timeout_ms)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return NULL; }
    if (uid_32 == NULL) { lf_set_error("null uid"); return NULL; }

    TP2P_UID_VAL uid;
    lf_uid_pack(uid_32, &uid);
    return ((void*(*)(TP2P_UID_VAL, void*, uint64_t))LF_GET(SYM_UID_Call))
        (uid, param, timeout_ms);
}

void LF_DART_CALL lf_bridge_uid_notify(const uint8_t* uid_32, void* param)
{
    if (!g_state.initialized || uid_32 == NULL) { return; }
    TP2P_UID_VAL uid;
    lf_uid_pack(uid_32, &uid);
    ((void(*)(TP2P_UID_VAL, void*))LF_GET(SYM_UID_Notify))(uid, param);
}

void LF_DART_CALL lf_bridge_uid_sequenced_notify(
    const uint8_t* uid_32, void* param)
{
    if (!g_state.initialized || uid_32 == NULL) { return; }
    TP2P_UID_VAL uid;
    lf_uid_pack(uid_32, &uid);
    ((void(*)(TP2P_UID_VAL, void*))LF_GET(SYM_UID_Sequenced_Notify))(uid, param);
}

int LF_DART_CALL lf_bridge_uid_call_async(
    const uint8_t* uid_32, void* param, int64_t op_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (uid_32 == NULL) { lf_set_error("null uid"); return LFB_ERR_INVALID_ARGUMENT; }

    TP2P_UID_VAL uid;
    lf_uid_pack(uid_32, &uid);
    int rc = ((int(*)(TP2P_UID_VAL, void*, void*, void*))LF_GET(SYM_UID_Async_Call))
        (uid, param,
         (void*)(intptr_t)op_id,
         (void*)bridge_async_on_result);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

int LF_DART_CALL lf_bridge_uid_call_async_sequenced(
    const uint8_t* uid_32, void* param, int64_t op_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (uid_32 == NULL) { lf_set_error("null uid"); return LFB_ERR_INVALID_ARGUMENT; }

    TP2P_UID_VAL uid;
    lf_uid_pack(uid_32, &uid);
    int rc = ((int(*)(TP2P_UID_VAL, void*, void*, void*))LF_GET(SYM_UID_Async_Sequenced_Call))
        (uid, param,
         (void*)(intptr_t)op_id,
         (void*)bridge_async_on_result);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

/* ---- Section 9: Invocation (P2PName) ---- */

void* LF_DART_CALL lf_bridge_p2pname_call(
    const char* p2p_name, void* param, uint64_t timeout_ms)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return NULL; }
    if (p2p_name == NULL) { lf_set_error("null p2p_name"); return NULL; }
    return ((void*(*)(const char*, void*, uint64_t))LF_GET(SYM_P2PNAME_Call))
        (p2p_name, param, timeout_ms);
}

void LF_DART_CALL lf_bridge_p2pname_notify(const char* p2p_name, void* param)
{
    if (!g_state.initialized || p2p_name == NULL) { return; }
    ((void(*)(const char*, void*))LF_GET(SYM_P2PNAME_Notify))(p2p_name, param);
}

void LF_DART_CALL lf_bridge_p2pname_sequenced_notify(
    const char* p2p_name, void* param)
{
    if (!g_state.initialized || p2p_name == NULL) { return; }
    ((void(*)(const char*, void*))LF_GET(SYM_P2PNAME_Sequenced_Notify))(p2p_name, param);
}

int LF_DART_CALL lf_bridge_p2pname_call_async(
    const char* p2p_name, void* param, int64_t op_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (p2p_name == NULL) { lf_set_error("null p2p_name"); return LFB_ERR_INVALID_ARGUMENT; }
    int rc = ((int(*)(const char*, void*, void*, void*))LF_GET(SYM_P2PNAME_Async_Call))
        (p2p_name, param,
         (void*)(intptr_t)op_id,
         (void*)bridge_async_on_result);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

int LF_DART_CALL lf_bridge_p2pname_call_async_sequenced(
    const char* p2p_name, void* param, int64_t op_id)
{
    lf_clear_error();
    if (!g_state.initialized) { lf_set_error("bridge not initialized"); return LFB_ERR_NOT_INITIALIZED; }
    if (p2p_name == NULL) { lf_set_error("null p2p_name"); return LFB_ERR_INVALID_ARGUMENT; }
    int rc = ((int(*)(const char*, void*, void*, void*))LF_GET(SYM_P2PNAME_Async_Sequenced_Call))
        (p2p_name, param,
         (void*)(intptr_t)op_id,
         (void*)bridge_async_on_result);
    return rc == 1 ? LFB_OK : LFB_ERR_LINGOFUSE_FAILED;
}

/* ---- Section 10: Queries ---- */

int LF_DART_CALL lf_bridge_check_main_thread(void)
{
    if (!g_state.initialized) { return 0; }
    return ((int(*)())LF_GET(SYM_CheckMainThread))();
}

int LF_DART_CALL lf_bridge_check_app(const char* app_name)
{
    if (!g_state.initialized || app_name == NULL) { return 0; }
    return ((int(*)(const char*))LF_GET(SYM_CheckApp))(app_name);
}

int LF_DART_CALL lf_bridge_check_api(const char* app_name, const char* api_name)
{
    if (!g_state.initialized || app_name == NULL || api_name == NULL) { return 0; }
    return ((int(*)(const char*, const char*))LF_GET(SYM_CheckApi))
        (app_name, api_name);
}

int LF_DART_CALL lf_bridge_check_uid(const uint8_t* uid_32)
{
    if (!g_state.initialized || uid_32 == NULL) { return 0; }
    TP2P_UID_VAL uid;
    lf_uid_pack(uid_32, &uid);
    return ((int(*)(TP2P_UID_VAL))LF_GET(SYM_Check_UID))(uid);
}

int LF_DART_CALL lf_bridge_check_uid_api(const uint8_t* uid_32, const char* api_name)
{
    if (!g_state.initialized || uid_32 == NULL || api_name == NULL) { return 0; }
    TP2P_UID_VAL uid;
    lf_uid_pack(uid_32, &uid);
    return ((int(*)(TP2P_UID_VAL, const char*))LF_GET(SYM_Check_UID_Api))
        (uid, api_name);
}

int LF_DART_CALL lf_bridge_check_p2pname(const char* p2p_name)
{
    if (!g_state.initialized || p2p_name == NULL) { return 0; }
    return ((int(*)(const char*))LF_GET(SYM_Check_P2PNAME))(p2p_name);
}

int LF_DART_CALL lf_bridge_check_p2pname_api(
    const char* p2p_name, const char* api_name)
{
    if (!g_state.initialized || p2p_name == NULL || api_name == NULL) { return 0; }
    return ((int(*)(const char*, const char*))LF_GET(SYM_Check_P2PNAME_Api))
        (p2p_name, api_name);
}

/* ---- Section 11: Options ---- */

/* 11.1 Authentication */
DEFINE_OPT_SETTER(lf_bridge_set_opt_password, "password", lf_set_option_str)
DEFINE_OPT_GETTER_STR(lf_bridge_get_opt_password, "password")

/* 11.2 Logging and diagnostics */
DEFINE_OPT_SETTER(lf_bridge_set_opt_debug, "debug", lf_set_option_str)
DEFINE_OPT_GETTER_STR(lf_bridge_get_opt_debug, "debug")

int LF_DART_CALL lf_bridge_set_opt_quiet(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_bool("Quiet", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_quiet(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_bool("Quiet");
}

int LF_DART_CALL lf_bridge_set_opt_show_thread_id(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_bool("ShowThreadID", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_show_thread_id(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_bool("ShowThreadID");
}

int LF_DART_CALL lf_bridge_set_opt_console_output(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_bool("ConsoleOutput", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_console_output(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_bool("ConsoleOutput");
}

/* 11.3 Connection readiness */
int LF_DART_CALL lf_bridge_set_opt_overlap_connection(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_bool("Overlap_Connection", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_overlap_connection(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_bool("Overlap_Connection");
}

int LF_DART_CALL lf_bridge_set_opt_wait_connection_ready_ok(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_bool("Wait_Connection_ReadyOk", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_wait_connection_ready_ok(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_bool("Wait_Connection_ReadyOk");
}

int LF_DART_CALL lf_bridge_set_opt_wait_connection_timeout(uint64_t value_ms)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_u64("Wait_Connection_Timeout", value_ms);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_wait_connection_timeout(void)
{
    if (!g_state.initialized) { return 0; }
    uint64_t v = lf_get_option_u64("Wait_Connection_Timeout");
    if (v > 0x7FFFFFFFULL) { v = 0x7FFFFFFFULL; }
    return (int)v;
}

/* 11.4 IPC */
int LF_DART_CALL lf_bridge_set_opt_ipc_serv_thread_count(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_int("IPC_Serv_ThreadCount", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_ipc_serv_thread_count(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_int("IPC_Serv_ThreadCount");
}

int LF_DART_CALL lf_bridge_set_opt_ipc_serv_max_queue_length(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_int("IPC_Serv_MaxQueueLength", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_ipc_serv_max_queue_length(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_int("IPC_Serv_MaxQueueLength");
}

int LF_DART_CALL lf_bridge_set_opt_ipc_serv_max_msg_size(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_int("IPC_Serv_MaxMsgSize", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_ipc_serv_max_msg_size(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_int("IPC_Serv_MaxMsgSize");
}

/* 11.5 Sequenced notifications */
int LF_DART_CALL lf_bridge_set_opt_fixed_sequenced_time(uint64_t value_ms)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_u64("Fixed_Sequenced_Time", value_ms);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_fixed_sequenced_time(void)
{
    if (!g_state.initialized) { return 0; }
    uint64_t v = lf_get_option_u64("Fixed_Sequenced_Time");
    if (v > 0x7FFFFFFFULL) { v = 0x7FFFFFFFULL; }
    return (int)v;
}

/* 11.6 P2P group name */
DEFINE_OPT_SETTER(lf_bridge_set_opt_p2p_name, "LF_P2P_name", lf_set_option_str)
DEFINE_OPT_GETTER_STR(lf_bridge_get_opt_p2p_name, "LF_P2P_name")

/* 11.7 Data handle pool */
int LF_DART_CALL lf_bridge_set_opt_data_handle_idle_timeout(uint64_t value_ms)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_u64("DataHandle_Idle_Timeout", value_ms);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_data_handle_idle_timeout(void)
{
    if (!g_state.initialized) { return 0; }
    uint64_t v = lf_get_option_u64("DataHandle_Idle_Timeout");
    if (v > 0x7FFFFFFFULL) { v = 0x7FFFFFFFULL; }
    return (int)v;
}

int LF_DART_CALL lf_bridge_set_opt_data_handle_pool_scan_interval(uint64_t value_ms)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_u64("DataHandle_Pool_Scan_Interval", value_ms);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_data_handle_pool_scan_interval(void)
{
    if (!g_state.initialized) { return 0; }
    uint64_t v = lf_get_option_u64("DataHandle_Pool_Scan_Interval");
    if (v > 0x7FFFFFFFULL) { v = 0x7FFFFFFFULL; }
    return (int)v;
}

/* 11.8 Command flushing */
int LF_DART_CALL lf_bridge_set_opt_no_reponse_cmd_null_flush_threshold(int value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    lf_set_option_int("No_Reponse_Cmd_NULL_Flush_Threshold", value);
    return LFB_OK;
}
int LF_DART_CALL lf_bridge_get_opt_no_reponse_cmd_null_flush_threshold(void)
{
    if (!g_state.initialized) { return 0; }
    return lf_get_option_int("No_Reponse_Cmd_NULL_Flush_Threshold");
}

/* 11.9 Generic escape hatch */
int LF_DART_CALL lf_bridge_set_option(const char* option, const char* value)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    if (option == NULL || value == NULL) {
        lf_set_error("null option or value");
        return LFB_ERR_INVALID_ARGUMENT;
    }
    lf_set_option_str(option, value);
    return LFB_OK;
}

int LF_DART_CALL lf_bridge_get_option(
    const char* option, char* out_buf, int buf_size)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    if (option == NULL) { lf_set_error("null option"); return LFB_ERR_INVALID_ARGUMENT; }
    return lf_copy_string_into(lf_get_option_str(option), out_buf, buf_size);
}

/* ---- Section 12: Status ---- */

int LF_DART_CALL lf_bridge_get_status_count(void)
{
    if (!g_state.initialized) { return -1; }
    return ((int(*)())LF_GET(SYM_GetStatusCount))();
}

int LF_DART_CALL lf_bridge_get_status(char* out_buf, int buf_size)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    const char* p = ((const char*(*)())LF_GET(SYM_GetStatus))();
    return lf_copy_string_into(p, out_buf, buf_size);
}

int LF_DART_CALL lf_bridge_post_status(const char* message)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    if (message == NULL) { lf_set_error("null message"); return LFB_ERR_INVALID_ARGUMENT; }
    ((void(*)(const char*))LF_GET(SYM_PostStatus))(message);
    return LFB_OK;
}

/* ---- Section 13: Network events ---- */

int LF_DART_CALL lf_bridge_set_network_event(
    int64_t connect_callback_id, int64_t disconnect_callback_id)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }

    g_state.connect_callback_id = connect_callback_id;
    g_state.disconnect_callback_id = disconnect_callback_id;

    void* on_connect = (connect_callback_id >= 0)
        ? (void*)&bridge_connect_trampoline : NULL;
    void* on_disconnect = (disconnect_callback_id >= 0)
        ? (void*)&bridge_disconnect_trampoline : NULL;

    ((void(*)(void*, void*))LF_GET(SYM_Set_Network_Event))
        (on_connect, on_disconnect);
    return LFB_OK;
}

int LF_DART_CALL lf_bridge_clear_network_event(void)
{
    lf_clear_error();
    if (!g_state.initialized) { return LFB_ERR_NOT_INITIALIZED; }
    g_state.connect_callback_id = -1;
    g_state.disconnect_callback_id = -1;
    ((void(*)(void*, void*))LF_GET(SYM_Set_Network_Event))(NULL, NULL);
    return LFB_OK;
}

/* ---- Section 15: Diagnostics ---- */

const char* LF_DART_CALL lf_bridge_last_error(void)
{
    return g_error_buf;
}

const char* LF_DART_CALL lf_bridge_version(void)
{
    return "lf_dart_bridge v1.0.0 (2026)";
}

int LF_DART_CALL lf_bridge_stats_json(char* out_buf, int buf_size)
{
    lf_clear_error();
    if (out_buf == NULL || buf_size <= 0) {
        lf_set_error("invalid output buffer");
        return LFB_ERR_INVALID_ARGUMENT;
    }

    char tmp[512];
    int n = snprintf(
        tmp, sizeof(tmp),
        "{"
        "\"initialized\":%s,"
        "\"library_loaded\":%s,"
        "\"pending_requests\":%ld,"
        "\"dart_post_ok\":%ld,"
        "\"dart_post_fail\":%ld,"
        "\"next_request_id\":%ld"
        "}",
        g_state.initialized ? "true" : "false",
        (g_state.lf_lib != NULL) ? "true" : "false",
        (long)g_state.pending_count,
        (long)g_state.dart_post_ok,
        (long)g_state.dart_post_fail,
        (long)g_state.next_request_id);

    if (n < 0 || n >= (int)sizeof(tmp)) {
        lf_set_error("stats buffer overflow");
        return LFB_ERR_BRIDGE_INTERNAL;
    }
    return lf_copy_string_into(tmp, out_buf, buf_size);
}

/* ===========================================================================
 * Section 9 -- Attach / detach entry points
 * ===========================================================================
 *
 * On Windows we do not need explicit DllMain; the default process
 * attach/detach is sufficient. On POSIX there is no equivalent, so we
 * leave it to the caller to invoke lf_bridge_init and
 * lf_bridge_shutdown.
 *
 * If the bridge is ever converted into a self-contained Windows DLL
 * that must be usable from any language without an explicit init call
 * (e.g. via GetProcAddress from a non-Dart host), a DllMain can be
 * added here to perform minimal setup. That is NOT the case today: the
 * bridge is designed to be driven from Dart, and lf_bridge_init is
 * mandatory.
 * ========================================================================= */

#if defined(_WIN32)
BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpReserved)
{
    (void)hinstDLL;
    (void)lpReserved;

    if (fdwReason == DLL_PROCESS_DETACH) {
        /* Best-effort cleanup. The Dart side is expected to have called
         * lf_bridge_shutdown already; this is only a safety net for
         * the case where the host process terminates without a clean
         * shutdown. */
        if (g_state.initialized) {
            /* We deliberately do NOT call LF_Shutdown here: the Dart
             * side owns the LingoFuse lifecycle. We only release the
             * bridge's own resources. */
            lf_bridge_shutdown();
        }
    }
    return TRUE;
}
#endif

/* ===========================================================================
 * End of lf_dart_bridge.c
 * ===========================================================================
 *
 * ABI COMPATIBILITY NOTE (UID as value)
 * -------------------------------------
 * The TP2P_UID_VAL struct (single uint8_t[32] member) is passed BY
 * VALUE to LF_UID_* and LF_Check_UID*. This is the bridge's central
 * ABI assumption:
 *
 *   - SysV AMD64  : struct > 16 bytes -> MEMORY class -> stack. FPC's
 *                   `array[0..31] of Byte` -> MEMORY class -> stack.
 *                   Compatible.
 *   - Windows x64 : struct > 8 bytes  -> hidden pointer. FPC's
 *                   `array[0..31] of Byte` -> same. Compatible.
 *
 * If a future compiler or architecture disagrees, the fallback is to
 * move the pack/forward step into a tiny FPC-compiled shim that takes
 * a `const uint8_t*` and constructs the array locally. That shim would
 * be linked into the bridge DLL and would eliminate the ABI assumption
 * entirely, at the cost of one extra DLL and one extra function call
 * per UID-addressed request.
 *
 * End of file.
 * ========================================================================= */