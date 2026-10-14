/*
 * lingofuse_ext.c — Ruby C extension for LingoFuse.
 *
 * ============================================================================
 * ARCHITECTURE — AFTER THE "REPLACE FIDDLE" REVISION
 * ============================================================================
 * This extension does two jobs:
 *
 *   1. LOADER + ABI SURFACE.
 *      It embeds LingoFuse.c (the upstream dynamic-library loader and
 *      function forwarder) and re-exports its 59 LF_* functions to Ruby
 *      as singleton methods on the LingoFuse::Native module. This
 *      replaces lib/lingofuse/binding.rb's previous Fiddle-based layer.
 *
 *   2. CALLBACK MARSHALING.
 *      The original extension's job: it interposes a native work queue
 *      between LingoFuse's TCompute worker threads (which cannot enter
 *      the Ruby VM) and a dedicated Ruby dispatcher thread (which can).
 *      All user callbacks — Call / Notify / Network events / Async Call
 *      results — are routed through this queue.
 *
 * The two jobs share the same shared object. LingoFuse.c is compiled
 * into lingofuse_ext.so alongside this file; the LF_LoadLibrary() call
 * in Init_lingofuse_ext() resolves the real LingoFuse64.dll at load
 * time and populates the static function-pointer table.
 *
 * ============================================================================
 * STRING HANDLING — UTF-8 ENCODING
 * ============================================================================
 * Every function that returns a const char* (LF_GetStatus, LF_GetOption,
 * LF_Generate_AppName, LF_Get_AppName, LF_Get_P2P_Name) points to a
 * transient buffer:
 *
 *   - LF_GetStatus        -> process-wide static buffer, valid until the
 *                            NEXT call to LF_GetStatus.
 *   - LF_GetOption        -> released ~5 seconds after the call.
 *   - LF_Generate_AppName -> released ~5 seconds after the call.
 *   - LF_Get_AppName      -> released ~5 seconds after the call.
 *   - LF_Get_P2P_Name     -> released ~5 seconds after the call.
 *
 * Every one of these is wrapped with rb_utf8_str_new_cstr(), which
 * copies the bytes into a fresh Ruby String on the spot AND tags the
 * string with the UTF-8 encoding. Using rb_utf8_str_new_cstr (rather
 * than the older rb_str_new_cstr) is deliberate: the latter produces a
 * binary (ASCII-8BIT) String, which would force every Ruby caller to
 * apply .force_encoding("UTF-8") before comparing or printing it.
 * The wire protocol is UTF-8 throughout, so tagging at the boundary is
 * the correct place.
 *
 * LF_Get_P2P_UID is the one exception: it returns a pointer to a
 * 32-byte UID, which is binary, not text. That path uses rb_str_new
 * (which preserves ASCII-8BIT), and is intentionally NOT routed
 * through cstr_to_rb.
 *
 * ============================================================================
 * GVL RELEASE
 * ============================================================================
 * Operations that may block for a non-trivial time (network calls,
 * LF_PrepareDone, LF_Shutdown, LF_ExitMainThread) are wrapped with
 * rb_thread_call_without_gvl so that other Ruby threads can run while
 * the native call is in flight. Pure in-memory operations (LF_GetSize,
 * LF_WriteBuffer, ...) hold the GVL for the full call, which is
 * correct: they are O(1) or O(buffer) and cannot block.
 *
 * ============================================================================
 * UID ARGUMENTS
 * ============================================================================
 * TP2P_UID is a 32-byte struct passed BY VALUE on the C ABI. The Ruby
 * side represents a UID as a 32-byte String. The wrapper checks the
 * length and copies the bytes into a stack-local TP2P_UID, then passes
 * it by value. Nothing is allocated.
 *
 * ============================================================================
 * ASYNC CALL RESULT HANDLING
 * ============================================================================
 * LF_Async_Call and its UID_* / P2PName_* variants take an
 * LF_AsyncCallOnResult callback:
 *
 *     void (*)(void* data, TDataHnd result)
 *
 * The `data` pointer is opaque to LingoFuse and is forwarded verbatim.
 * In this extension it carries a CallbackRef* so that the trampoline can
 * find the Ruby Proc and dispatch it on the Ruby thread.
 *
 * The `result` handle is OWNED BY THE FRAMEWORK and is released
 * IMMEDIATELY after the trampoline returns. The Ruby proc must copy
 * everything it needs out of the handle before returning.
 *
 * The Ruby dispatcher guarantees that the trampoline does not return
 * until the Ruby proc has finished, so the result handle is still valid
 * when the Ruby proc reads it.
 *
 * ============================================================================
 * THREAD SAFETY
 * ============================================================================
 * The callback-marshaling queue uses pthread primitives. The Ruby side
 * is responsible for running the dispatcher loop on a single thread
 * (NativeBridge.start). See lib/lingofuse/native_bridge.rb.
 */

#include <ruby.h>
#include <ruby/thread.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "LingoFuse.h"   /* loader + 59 forwarders + helper functions */

/* ============================================================================
 * SECTION 1 - Callback kinds
 * ============================================================================
 * These constants are shared between the callback-marshaling machinery
 * (this file) and the Ruby wrapper (lib/lingofuse/native_bridge.rb).
 * They MUST remain stable across releases.
 *
 * Kinds 0..3 are the ORIGINAL set (Call / Notify / Network connect /
 * Network disconnect). Kind 4 (ASYNC_CALL) was added by the async
 * support revision. The wire values are part of the Ruby<->C contract
 * and MUST NOT be renumbered.
 */

#define LF_KIND_CALL               0
#define LF_KIND_NOTIFY             1
#define LF_KIND_NETWORK_CONNECT    2
#define LF_KIND_NETWORK_DISCONNECT 3
#define LF_KIND_ASYNC_CALL         4

/* ============================================================================
 * SECTION 2 - Callback marshaling: data structures
 * ============================================================================
 * These reproduce the original extension's structures verbatim. Do not
 * change their layout: native_bridge.rb's create_ref / free_ref
 * round-trips the CallbackRef* value as an Integer, and changing the
 * layout would break that contract.
 */

typedef struct CallbackItem {
    VALUE proc;                 /* Ruby Proc to invoke                     */
    void* input;                /* input pointer / native buffer / NUL str */
    void* output;               /* output pointer, or NULL                 */
    int   kind;                 /* LF_KIND_*                               */
    int   done;                 /* set to 1 by the dispatcher              */
    struct CallbackItem* next;  /* singly-linked queue link                */
} CallbackItem;

typedef struct CallbackRef {
    VALUE proc;                 /* Ruby Proc, GC-registered                */
    int   kind;                 /* LF_KIND_*                               */
} CallbackRef;

typedef struct DispatchArgs {
    VALUE proc;
    VALUE input;                /* Ruby VALUE (Integer or String)          */
    VALUE output;               /* Ruby VALUE (Integer) or Qnil            */
    int   kind;
} DispatchArgs;

/* ============================================================================
 * SECTION 3 - Callback marshaling: global state
 * ============================================================================ */

static pthread_mutex_t g_queue_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_work_cond  = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  g_done_cond  = PTHREAD_COND_INITIALIZER;

static CallbackItem* g_queue_head = NULL;
static CallbackItem* g_queue_tail = NULL;

static pthread_mutex_t g_net_lock           = PTHREAD_MUTEX_INITIALIZER;
static CallbackRef*    g_net_connect_ref    = NULL;
static CallbackRef*    g_net_disconnect_ref = NULL;

/* ============================================================================
 * SECTION 4 - Callback marshaling: queue primitives
 * ============================================================================ */

static void enqueue_item(CallbackItem* item)
{
    pthread_mutex_lock(&g_queue_lock);
    item->next = NULL;
    if (g_queue_tail != NULL) {
        g_queue_tail->next = item;
    } else {
        g_queue_head = item;
    }
    g_queue_tail = item;
    pthread_cond_signal(&g_work_cond);
    pthread_mutex_unlock(&g_queue_lock);
}

static CallbackItem* dequeue_all(void)
{
    pthread_mutex_lock(&g_queue_lock);
    CallbackItem* head = g_queue_head;
    g_queue_head = NULL;
    g_queue_tail = NULL;
    pthread_mutex_unlock(&g_queue_lock);
    return head;
}

static void wait_for_item(CallbackItem* item)
{
    pthread_mutex_lock(&g_queue_lock);
    while (!item->done) {
        pthread_cond_wait(&g_done_cond, &g_queue_lock);
    }
    pthread_mutex_unlock(&g_queue_lock);
}

static void mark_done(CallbackItem* item)
{
    pthread_mutex_lock(&g_queue_lock);
    item->done = 1;
    pthread_cond_broadcast(&g_done_cond);
    pthread_mutex_unlock(&g_queue_lock);
}

/* ============================================================================
 * SECTION 5 - Callback marshaling: dispatch helpers
 * ============================================================================ */

static VALUE dispatch_protected(VALUE arg)
{
    DispatchArgs* a = (DispatchArgs*)arg;

    switch (a->kind) {
    case LF_KIND_NOTIFY:
    case LF_KIND_NETWORK_CONNECT:
    case LF_KIND_NETWORK_DISCONNECT:
    case LF_KIND_ASYNC_CALL:
        /* All four kinds invoke the user Proc with a single argument.
         * For NOTIFY / NETWORK_* that argument is the input pointer
         * or the address string; for ASYNC_CALL it is the result
         * handle (or nil). */
        return rb_funcall(a->proc, rb_intern("call"), 1, a->input);
    case LF_KIND_CALL:
    default:
        return rb_funcall(a->proc, rb_intern("call"), 2, a->input, a->output);
    }
}

static void dispatch_in_place(DispatchArgs* args)
{
    int state = 0;
    rb_protect(dispatch_protected, (VALUE)args, &state);

    if (state != 0) {
        VALUE err = rb_errinfo();
        VALUE msg = rb_obj_as_string(err);
        fprintf(stderr,
                "[LingoFuse::NativeBridge] callback raised: %s\n",
                StringValueCStr(msg));
        rb_set_errinfo(Qnil);
    }
}

/* ============================================================================
 * SECTION 6 - Callback marshaling: Call / Notify / Async trampolines
 * ============================================================================
 * trampoline_call       — Call mode:  (trigger, input, output) -> void
 * trampoline_notify     — Notify mode: (trigger, input) -> void
 * trampoline_async_call — Async result: (data, result) -> void
 *
 * The async variant mirrors the Call / Notify variants exactly, except
 * that its signature matches LF_AsyncCallOnResult and the `data`
 * argument carries the CallbackRef* (rather than `trigger`).
 */

static void trampoline_call(void* trigger, void* input, void* output)
{
    CallbackRef* ref = (CallbackRef*)trigger;
    if (ref == NULL) return;

    if (ruby_thread_has_gvl_p()) {
        DispatchArgs args;
        args.proc   = ref->proc;
        args.input  = ULL2NUM((unsigned long long)(uintptr_t)input);
        args.output = (output != NULL)
                        ? ULL2NUM((unsigned long long)(uintptr_t)output)
                        : Qnil;
        args.kind   = LF_KIND_CALL;
        dispatch_in_place(&args);
        return;
    }

    CallbackItem* item = (CallbackItem*)calloc(1, sizeof(CallbackItem));
    if (item == NULL) return;

    item->proc   = ref->proc;
    item->input  = input;
    item->output = output;
    item->kind   = LF_KIND_CALL;
    item->done   = 0;

    enqueue_item(item);
    wait_for_item(item);
    free(item);
}

static void trampoline_notify(void* trigger, void* input)
{
    CallbackRef* ref = (CallbackRef*)trigger;
    if (ref == NULL) return;

    if (ruby_thread_has_gvl_p()) {
        DispatchArgs args;
        args.proc   = ref->proc;
        args.input  = ULL2NUM((unsigned long long)(uintptr_t)input);
        args.output = Qnil;
        args.kind   = LF_KIND_NOTIFY;
        dispatch_in_place(&args);
        return;
    }

    CallbackItem* item = (CallbackItem*)calloc(1, sizeof(CallbackItem));
    if (item == NULL) return;

    item->proc   = ref->proc;
    item->input  = input;
    item->output = NULL;
    item->kind   = LF_KIND_NOTIFY;
    item->done   = 0;

    enqueue_item(item);
    wait_for_item(item);
    free(item);
}

/*
 * trampoline_async_call — result callback for LF_Async_Call and its
 * UID_* / P2PName_* variants.
 *
 * Signature matches LF_AsyncCallOnResult:
 *
 *     void (*)(void* data, TDataHnd result)
 *
 * `data` is the opaque pointer the caller supplied at the call site.
 * In this extension it is a CallbackRef* created by create_ref. It is
 * NOT freed here: the Ruby side (native_bridge.rb / async_support.rb)
 * owns the ref and releases it via free_ref.
 *
 * `result` is a TDataHnd owned by the framework. The framework releases
 * it IMMEDIATELY after this trampoline returns. The Ruby proc
 * dispatched on the caller side MUST therefore copy everything it needs
 * out of the result handle before returning, and MUST NOT retain the
 * pointer past its own return.
 *
 * The dispatcher / caller rendezvous guarantees the lifetime contract:
 *
 *   1. TCompute worker calls trampoline_async_call(data, result).
 *   2. trampoline enqueues the item, then blocks on wait_for_item.
 *   3. Ruby dispatcher dequeues the item and runs the Proc.
 *   4. The Proc reads the result handle and copies out what it needs.
 *   5. Dispatcher calls mark_done, waking the TCompute worker.
 *   6. trampoline returns.
 *   7. Framework releases result.
 *
 * Between steps 2 and 5 the result handle is alive. The Proc therefore
 * sees a valid pointer for the full duration of its own execution.
 *
 * On the "GVL already held" fast path (which happens for a synchronous
 * LocalCall that happens to trigger an async completion), the same
 * lifetime reasoning applies: the framework only releases result after
 * this function returns, and this function only returns after
 * dispatch_in_place has run the Proc to completion.
 */
static void trampoline_async_call(void* data, void* result)
{
    CallbackRef* ref = (CallbackRef*)data;
    if (ref == NULL) return;

    if (ruby_thread_has_gvl_p()) {
        DispatchArgs args;
        args.proc   = ref->proc;
        args.input  = (result != NULL)
                        ? ULL2NUM((unsigned long long)(uintptr_t)result)
                        : Qnil;
        args.output = Qnil;
        args.kind   = LF_KIND_ASYNC_CALL;
        dispatch_in_place(&args);
        return;
    }

    CallbackItem* item = (CallbackItem*)calloc(1, sizeof(CallbackItem));
    if (item == NULL) return;

    item->proc   = ref->proc;
    item->input  = result;   /* NULL is permitted (timeout / failure) */
    item->output = NULL;
    item->kind   = LF_KIND_ASYNC_CALL;
    item->done   = 0;

    enqueue_item(item);
    wait_for_item(item);
    free(item);
}

/* ============================================================================
 * SECTION 7 - Callback marshaling: network event trampolines
 * ============================================================================
 * The network callbacks receive a const char* that is owned by
 * LingoFuse and freed as soon as the callback returns. On the
 * native-thread path we must copy the string before enqueueing.
 */

static char* lf_strdup_(const char* s)
{
    if (s == NULL) return NULL;
    size_t len = strlen(s) + 1;
    char* p = (char*)malloc(len);
    if (p != NULL) memcpy(p, s, len);
    return p;
}

/* Forward declaration. */
static void dispatch_network(CallbackRef* ref, const char* addr);

static void trampoline_network_connect(const char* addr)
{
    CallbackRef* ref;
    pthread_mutex_lock(&g_net_lock);
    ref = g_net_connect_ref;
    pthread_mutex_unlock(&g_net_lock);
    dispatch_network(ref, addr);
}

static void trampoline_network_disconnect(const char* addr)
{
    CallbackRef* ref;
    pthread_mutex_lock(&g_net_lock);
    ref = g_net_disconnect_ref;
    pthread_mutex_unlock(&g_net_lock);
    dispatch_network(ref, addr);
}

static void dispatch_network(CallbackRef* ref, const char* addr)
{
    if (ref == NULL) return;

    if (ruby_thread_has_gvl_p()) {
        VALUE addr_str = (addr != NULL) ? rb_utf8_str_new_cstr(addr) : Qnil;
        DispatchArgs args;
        args.proc   = ref->proc;
        args.input  = addr_str;
        args.output = Qnil;
        args.kind   = ref->kind;
        dispatch_in_place(&args);
        return;
    }

    char* addr_copy = (addr != NULL) ? lf_strdup_(addr) : NULL;

    CallbackItem* item = (CallbackItem*)calloc(1, sizeof(CallbackItem));
    if (item == NULL) {
        free(addr_copy);
        return;
    }

    item->proc   = ref->proc;
    item->input  = addr_copy;
    item->output = NULL;
    item->kind   = ref->kind;
    item->done   = 0;

    enqueue_item(item);
    wait_for_item(item);

    free(addr_copy);
    free(item);
}

/* ============================================================================
 * SECTION 8 - Callback marshaling: Ruby dispatcher
 * ============================================================================ */

static VALUE rb_process_all(VALUE self)
{
    (void)self;

    CallbackItem* item = dequeue_all();
    while (item != NULL) {
        CallbackItem* next = item->next;

        DispatchArgs args;
        args.proc = item->proc;

        switch (item->kind) {
        case LF_KIND_NETWORK_CONNECT:
        case LF_KIND_NETWORK_DISCONNECT:
            args.input = (item->input != NULL)
                            ? rb_utf8_str_new_cstr((const char*)item->input)
                            : Qnil;
            args.output = Qnil;
            break;
        case LF_KIND_NOTIFY:
            args.input  = ULL2NUM((unsigned long long)(uintptr_t)item->input);
            args.output = Qnil;
            break;
        case LF_KIND_ASYNC_CALL:
            /* The `input` slot carries the result handle pointer (or
             * NULL). Forward it as an Integer (or nil); the Ruby Proc
             * decides whether and how to read the handle. */
            args.input  = (item->input != NULL)
                            ? ULL2NUM((unsigned long long)(uintptr_t)item->input)
                            : Qnil;
            args.output = Qnil;
            break;
        case LF_KIND_CALL:
        default:
            args.input  = ULL2NUM((unsigned long long)(uintptr_t)item->input);
            args.output = (item->output != NULL)
                            ? ULL2NUM((unsigned long long)(uintptr_t)item->output)
                            : Qnil;
            break;
        }
        args.kind = item->kind;

        dispatch_in_place(&args);

        mark_done(item);
        item = next;
    }

    return Qnil;
}

/* ============================================================================
 * SECTION 9 - Callback marshaling: wait primitive
 * ============================================================================ */

struct wait_args {
    int has_work;
    int timeout_ms;
};

static void* wait_impl(void* arg)
{
    struct wait_args* wa = (struct wait_args*)arg;

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    ts.tv_sec  += wa->timeout_ms / 1000;
    ts.tv_nsec += (long)(wa->timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec  += 1;
        ts.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&g_queue_lock);
    if (g_queue_head == NULL) {
        pthread_cond_timedwait(&g_work_cond, &g_queue_lock, &ts);
    }
    wa->has_work = (g_queue_head != NULL);
    pthread_mutex_unlock(&g_queue_lock);

    return NULL;
}

static VALUE rb_wait_for_work(VALUE self, VALUE timeout_ms)
{
    (void)self;

    struct wait_args wa;
    wa.has_work   = 0;
    wa.timeout_ms = NUM2INT(timeout_ms);
    if (wa.timeout_ms < 0) wa.timeout_ms = 0;

    rb_thread_call_without_gvl(wait_impl, &wa, RUBY_UBF_IO, NULL);

    return wa.has_work ? Qtrue : Qfalse;
}

/* ============================================================================
 * SECTION 10 - Callback marshaling: registration bookkeeping
 * ============================================================================ */

static VALUE rb_create_ref(VALUE self, VALUE proc, VALUE kind)
{
    (void)self;

    if (!rb_obj_is_kind_of(proc, rb_cProc)) {
        rb_raise(rb_eTypeError, "callback must be a Proc");
    }

    int kind_int;
    if (kind == Qtrue) {
        kind_int = LF_KIND_NOTIFY;
    } else if (kind == Qfalse || kind == Qnil) {
        kind_int = LF_KIND_CALL;
    } else {
        kind_int = NUM2INT(kind);
    }

    CallbackRef* ref = (CallbackRef*)calloc(1, sizeof(CallbackRef));
    if (ref == NULL) {
        rb_raise(rb_eNoMemError, "calloc failed for CallbackRef");
    }

    ref->proc = proc;
    ref->kind = kind_int;

    rb_gc_register_address(&ref->proc);

    return ULL2NUM((unsigned long long)(uintptr_t)ref);
}

static VALUE rb_free_ref(VALUE self, VALUE address)
{
    (void)self;

    uintptr_t ptr = (uintptr_t)NUM2ULL(address);
    if (ptr == 0) return Qnil;

    CallbackRef* ref = (CallbackRef*)ptr;
    rb_gc_unregister_address(&ref->proc);
    free(ref);
    return Qnil;
}

static VALUE rb_call_trampoline_addr(VALUE self)
{
    (void)self;
    return ULL2NUM((unsigned long long)(uintptr_t)&trampoline_call);
}

static VALUE rb_notify_trampoline_addr(VALUE self)
{
    (void)self;
    return ULL2NUM((unsigned long long)(uintptr_t)&trampoline_notify);
}

static VALUE rb_async_call_trampoline_addr(VALUE self)
{
    (void)self;
    return ULL2NUM((unsigned long long)(uintptr_t)&trampoline_async_call);
}

static VALUE rb_network_connect_trampoline_addr(VALUE self)
{
    (void)self;
    return ULL2NUM((unsigned long long)(uintptr_t)&trampoline_network_connect);
}

static VALUE rb_network_disconnect_trampoline_addr(VALUE self)
{
    (void)self;
    return ULL2NUM((unsigned long long)(uintptr_t)&trampoline_network_disconnect);
}

static VALUE rb_set_network_refs(VALUE self, VALUE connect_addr, VALUE disconnect_addr)
{
    (void)self;

    pthread_mutex_lock(&g_net_lock);
    g_net_connect_ref =
        (connect_addr == Qnil) ? NULL
        : (CallbackRef*)(uintptr_t)NUM2ULL(connect_addr);
    g_net_disconnect_ref =
        (disconnect_addr == Qnil) ? NULL
        : (CallbackRef*)(uintptr_t)NUM2ULL(disconnect_addr);
    pthread_mutex_unlock(&g_net_lock);

    return Qnil;
}

/* ============================================================================
 * SECTION 11 - Loader wrappers
 * ============================================================================
 * LingoFuse.c owns the actual g_hDll handle and g_loaded flag. This
 * section adds a Ruby-visible mirror so that Native.loaded? can answer
 * without side effects.
 */

static int g_rb_loaded = 0;

static VALUE rb_native_load_library(VALUE self)
{
    (void)self;
    int ok = LF_LoadLibrary();
    if (ok) g_rb_loaded = 1;
    return INT2NUM(ok);
}

static VALUE rb_native_free_library(VALUE self)
{
    (void)self;
    LF_FreeLibrary();
    g_rb_loaded = 0;
    return Qnil;
}

static VALUE rb_native_loaded_p(VALUE self)
{
    (void)self;
    return g_rb_loaded ? Qtrue : Qfalse;
}

/* ============================================================================
 * SECTION 12 - Generic helpers for the 59 ABI wrappers
 * ============================================================================ */

/* Convert a Ruby VALUE to a native data / app handle (void*). */
static inline void* rb_to_handle(VALUE v)
{
    return (void*)(uintptr_t)NUM2ULL(v);
}

/* Convert a native void* handle to a Ruby VALUE. */
static inline VALUE handle_to_rb(void* h)
{
    if (h == NULL) return Qnil;
    return ULL2NUM((unsigned long long)(uintptr_t)h);
}

/* Copy a 32-byte Ruby String into a stack-local TP2P_UID. */
static inline void rb_to_uid(VALUE uid_str, TP2P_UID* out)
{
    Check_Type(uid_str, T_STRING);
    if (RSTRING_LEN(uid_str) != 32) {
        rb_raise(rb_eArgError, "UID must be exactly 32 bytes");
    }
    memcpy(out->bytes, RSTRING_PTR(uid_str), 32);
}

/* Extract a NUL-terminated UTF-8 C string from a Ruby String. */
static inline const char* rb_to_cstr(VALUE v)
{
    Check_Type(v, T_STRING);
    return StringValueCStr(v);
}

/*
 * Wrap a native const char* into a Ruby String.
 *
 * The string is copied immediately (rb_utf8_str_new_cstr copies the
 * bytes into a fresh Ruby String) and tagged with the UTF-8 encoding.
 * This differs from the historical rb_str_new_cstr, which would produce
 * an ASCII-8BIT (binary) String; callers would then have to apply
 * .force_encoding("UTF-8") before comparing or printing.
 *
 * The wire protocol is UTF-8 throughout, so tagging at the C boundary
 * is the correct place. Every string-returning wrapper routes through
 * this helper: get_p2p_name, generate_app_name, get_app_name,
 * get_option, get_status, and the network-event path.
 *
 * LF_Get_P2P_UID is the one exception: it returns a pointer to a
 * 32-byte UID, which is binary, not text. That path uses rb_str_new
 * (which preserves ASCII-8BIT) directly, bypassing this helper.
 */
static inline VALUE cstr_to_rb(const char* s)
{
    if (s == NULL) return rb_utf8_str_new_cstr("");
    return rb_utf8_str_new_cstr(s);
}

/* ============================================================================
 * SECTION 13 - Data handle operations (12)
 * ============================================================================ */

static VALUE rb_lf_create_data(VALUE self, VALUE name)
{
    (void)self;
    return handle_to_rb(LF_CreateData(rb_to_cstr(name)));
}

static VALUE rb_lf_create_data_permanent(VALUE self, VALUE name)
{
    (void)self;
    return handle_to_rb(LF_CreateData_Permanent(rb_to_cstr(name)));
}

static VALUE rb_lf_free_data(VALUE self, VALUE hnd)
{
    (void)self;
    LF_FreeData(rb_to_handle(hnd));
    return Qnil;
}

static VALUE rb_lf_get_buffer(VALUE self, VALUE hnd)
{
    (void)self;
    return handle_to_rb(LF_GetBuffer(rb_to_handle(hnd)));
}

/*
 * LF_WriteBuffer(hnd, buff, size) -> Integer
 *
 * `buff` is a Ruby String whose bytes are written verbatim. `size` may
 * be shorter than the string (a prefix write), but must not exceed it.
 */
static VALUE rb_lf_write_buffer(VALUE self, VALUE hnd, VALUE buff, VALUE size)
{
    (void)self;
    Check_Type(buff, T_STRING);

    long long want = NUM2LL(size);
    if (want < 0) {
        rb_raise(rb_eArgError, "size must be non-negative");
    }
    if (want > RSTRING_LEN(buff)) {
        rb_raise(rb_eArgError, "size exceeds buffer length");
    }

    int64_t wrote = LF_WriteBuffer(
        rb_to_handle(hnd),
        (const void*)RSTRING_PTR(buff),
        (int64_t)want
    );
    return LL2NUM((long long)wrote);
}

/*
 * LF_ReadBuffer(hnd, count) -> String
 *
 * Allocates a temporary native buffer, reads into it, and returns a
 * fresh Ruby String containing exactly the bytes that were read.
 */
static VALUE rb_lf_read_buffer(VALUE self, VALUE hnd, VALUE count)
{
    (void)self;

    long long want = NUM2LL(count);
    if (want < 0) {
        rb_raise(rb_eArgError, "count must be non-negative");
    }
    if (want == 0) {
        return rb_str_new("", 0);
    }

    char* buf = (char*)malloc((size_t)want);
    if (buf == NULL) {
        rb_raise(rb_eNoMemError, "malloc failed for read buffer");
    }

    int64_t got = LF_ReadBuffer(rb_to_handle(hnd), buf, (int64_t)want);
    if (got < 0) got = 0;
    if (got > want) got = want;

    VALUE result = rb_str_new(buf, (long)got);
    free(buf);
    return result;
}

static VALUE rb_lf_get_pos(VALUE self, VALUE hnd)
{
    (void)self;
    return LL2NUM((long long)LF_GetPos(rb_to_handle(hnd)));
}

static VALUE rb_lf_set_pos(VALUE self, VALUE hnd, VALUE pos)
{
    (void)self;
    LF_SetPos(rb_to_handle(hnd), (int64_t)NUM2LL(pos));
    return Qnil;
}

static VALUE rb_lf_get_size(VALUE self, VALUE hnd)
{
    (void)self;
    return LL2NUM((long long)LF_GetSize(rb_to_handle(hnd)));
}

static VALUE rb_lf_set_size(VALUE self, VALUE hnd, VALUE size)
{
    (void)self;
    LF_SetSize(rb_to_handle(hnd), (int64_t)NUM2LL(size));
    return Qnil;
}

/*
 * LF_Get_P2P_UID(hnd) -> String (32 bytes) or nil
 *
 * The native function returns a pointer to a 32-byte UID owned by the
 * framework and released ~5 seconds after the call. We copy the 32
 * bytes immediately.
 *
 * NOTE: the result is BINARY (ASCII-8BIT), not text. The UID is an
 * opaque 32-byte value; the caller treats it as bytes throughout.
 * rb_str_new preserves the source's binary nature.
 */
static VALUE rb_lf_get_p2p_uid(VALUE self, VALUE hnd)
{
    (void)self;
    const TP2P_UID* ptr = LF_Get_P2P_UID(rb_to_handle(hnd));
    if (ptr == NULL) return Qnil;
    return rb_str_new((const char*)ptr->bytes, 32);
}

/*
 * LF_Get_P2P_Name(hnd) -> String (UTF-8)
 *
 * Transient pointer, released ~5 seconds after the call.
 * cstr_to_rb copies immediately and tags the string as UTF-8.
 */
static VALUE rb_lf_get_p2p_name(VALUE self, VALUE hnd)
{
    (void)self;
    return cstr_to_rb(LF_Get_P2P_Name(rb_to_handle(hnd)));
}

/* ============================================================================
 * SECTION 14 - Application handle operations (5)
 * ============================================================================ */

static VALUE rb_lf_create_app(VALUE self, VALUE name, VALUE desc)
{
    (void)self;
    return handle_to_rb(LF_CreateApp(rb_to_cstr(name), rb_to_cstr(desc)));
}

static VALUE rb_lf_free_app(VALUE self, VALUE hnd)
{
    (void)self;
    LF_FreeApp(rb_to_handle(hnd));
    return Qnil;
}

static VALUE rb_lf_generate_app_name(VALUE self)
{
    (void)self;
    return cstr_to_rb(LF_Generate_AppName());
}

static VALUE rb_lf_get_app_name(VALUE self, VALUE hnd)
{
    (void)self;
    return cstr_to_rb(LF_Get_AppName(rb_to_handle(hnd)));
}

static VALUE rb_lf_bind_app(VALUE self, VALUE hnd)
{
    (void)self;
    return INT2NUM(LF_BindApp(rb_to_handle(hnd)));
}

/* ============================================================================
 * SECTION 15 - API registration, app-bound (3)
 * ============================================================================
 * `trigger_addr` and `on_call_addr` are opaque Integer addresses
 * obtained from NativeBridge.create_ref and
 * NativeBridge.call_trampoline_addr respectively.
 */

static VALUE rb_lf_register_call(
    VALUE self, VALUE app, VALUE name, VALUE desc,
    VALUE trigger_addr, VALUE on_call_addr)
{
    (void)self;
    return INT2NUM(LF_RegisterCall(
        (TAppHnd)rb_to_handle(app),
        rb_to_cstr(name),
        rb_to_cstr(desc),
        (void*)(uintptr_t)NUM2ULL(trigger_addr),
        (LF_CallFunc)(uintptr_t)NUM2ULL(on_call_addr)
    ));
}

static VALUE rb_lf_register_notify(
    VALUE self, VALUE app, VALUE name, VALUE desc,
    VALUE trigger_addr, VALUE on_notify_addr)
{
    (void)self;
    return INT2NUM(LF_RegisterNotify(
        (TAppHnd)rb_to_handle(app),
        rb_to_cstr(name),
        rb_to_cstr(desc),
        (void*)(uintptr_t)NUM2ULL(trigger_addr),
        (LF_NotifyFunc)(uintptr_t)NUM2ULL(on_notify_addr)
    ));
}

static VALUE rb_lf_unregister(VALUE self, VALUE app, VALUE name)
{
    (void)self;
    return INT2NUM(LF_Unregister((TAppHnd)rb_to_handle(app), rb_to_cstr(name)));
}

/* ============================================================================
 * SECTION 16 - API registration, process-wide P2P (3)
 * ============================================================================ */

static VALUE rb_lf_register_p2p_call(
    VALUE self, VALUE name, VALUE desc,
    VALUE trigger_addr, VALUE on_call_addr)
{
    (void)self;
    return INT2NUM(LF_Register_P2P_Call(
        rb_to_cstr(name),
        rb_to_cstr(desc),
        (void*)(uintptr_t)NUM2ULL(trigger_addr),
        (LF_CallFunc)(uintptr_t)NUM2ULL(on_call_addr)
    ));
}

static VALUE rb_lf_register_p2p_notify(
    VALUE self, VALUE name, VALUE desc,
    VALUE trigger_addr, VALUE on_notify_addr)
{
    (void)self;
    return INT2NUM(LF_Register_P2P_Notify(
        rb_to_cstr(name),
        rb_to_cstr(desc),
        (void*)(uintptr_t)NUM2ULL(trigger_addr),
        (LF_NotifyFunc)(uintptr_t)NUM2ULL(on_notify_addr)
    ));
}

static VALUE rb_lf_unregister_p2p(VALUE self, VALUE name)
{
    (void)self;
    return INT2NUM(LF_Unregister_P2P(rb_to_cstr(name)));
}

/* ============================================================================
 * SECTION 17 - Local execution (2)
 * ============================================================================ */

static VALUE rb_lf_local_call(VALUE self, VALUE app, VALUE param)
{
    (void)self;
    return handle_to_rb(LF_LocalCall(
        (TAppHnd)rb_to_handle(app),
        (TDataHnd)rb_to_handle(param)
    ));
}

static VALUE rb_lf_local_notify(VALUE self, VALUE app, VALUE param)
{
    (void)self;
    LF_LocalNotify(
        (TAppHnd)rb_to_handle(app),
        (TDataHnd)rb_to_handle(param)
    );
    return Qnil;
}

/* ============================================================================
 * SECTION 18 - Network preparation (5)
 * ============================================================================ */

static VALUE rb_lf_prepare_service(VALUE self, VALUE listen, VALUE physics)
{
    (void)self;
    return INT2NUM(LF_PrepareService(rb_to_cstr(listen), rb_to_cstr(physics)));
}

static VALUE rb_lf_prepare_client(VALUE self, VALUE physics, VALUE app)
{
    (void)self;
    TAppHnd h = (app == Qnil) ? NULL : (TAppHnd)rb_to_handle(app);
    return INT2NUM(LF_PrepareClient(rb_to_cstr(physics), h));
}

static VALUE rb_lf_reset_prepare(VALUE self)
{
    (void)self;
    LF_ResetPrepare();
    return Qnil;
}

struct prepare_done_args { int result; };

static void* prepare_done_no_gvl(void* arg)
{
    struct prepare_done_args* a = (struct prepare_done_args*)arg;
    a->result = LF_PrepareDone();
    return NULL;
}

static VALUE rb_lf_prepare_done(VALUE self)
{
    (void)self;
    struct prepare_done_args a;
    a.result = 0;
    rb_thread_call_without_gvl(prepare_done_no_gvl, &a, RUBY_UBF_IO, NULL);
    return INT2NUM(a.result);
}

static void* exit_main_thread_no_gvl(void* arg)
{
    (void)arg;
    LF_ExitMainThread();
    return NULL;
}

static VALUE rb_lf_exit_main_thread(VALUE self)
{
    (void)self;
    rb_thread_call_without_gvl(exit_main_thread_no_gvl, NULL, RUBY_UBF_IO, NULL);
    return Qnil;
}

/* ============================================================================
 * SECTION 19 - Remote invocation, app-name addressing (5)
 * ============================================================================ */

struct call_args {
    const char* app_name;
    void*       param;
    uint64_t    timeout_ms;
    void*       result;
};

static void* call_no_gvl(void* arg)
{
    struct call_args* a = (struct call_args*)arg;
    a->result = LF_Call(a->app_name, (TDataHnd)a->param, a->timeout_ms);
    return NULL;
}

static VALUE rb_lf_call(VALUE self, VALUE app_name, VALUE param, VALUE timeout)
{
    (void)self;
    struct call_args a;
    a.app_name   = rb_to_cstr(app_name);
    a.param      = rb_to_handle(param);
    a.timeout_ms = (uint64_t)NUM2ULL(timeout);
    a.result     = NULL;

    rb_thread_call_without_gvl(call_no_gvl, &a, RUBY_UBF_IO, NULL);

    return handle_to_rb(a.result);
}

static VALUE rb_lf_async_call(
    VALUE self, VALUE app_name, VALUE param,
    VALUE data_addr, VALUE on_result_addr)
{
    (void)self;
    return INT2NUM(LF_Async_Call(
        rb_to_cstr(app_name),
        (TDataHnd)rb_to_handle(param),
        (void*)(uintptr_t)NUM2ULL(data_addr),
        (LF_AsyncCallOnResult)(uintptr_t)NUM2ULL(on_result_addr)
    ));
}

static VALUE rb_lf_async_sequenced_call(
    VALUE self, VALUE app_name, VALUE param,
    VALUE data_addr, VALUE on_result_addr)
{
    (void)self;
    return INT2NUM(LF_Async_Sequenced_Call(
        rb_to_cstr(app_name),
        (TDataHnd)rb_to_handle(param),
        (void*)(uintptr_t)NUM2ULL(data_addr),
        (LF_AsyncCallOnResult)(uintptr_t)NUM2ULL(on_result_addr)
    ));
}

static VALUE rb_lf_notify(VALUE self, VALUE app_name, VALUE param)
{
    (void)self;
    LF_Notify(rb_to_cstr(app_name), (TDataHnd)rb_to_handle(param));
    return Qnil;
}

static VALUE rb_lf_sequenced_notify(VALUE self, VALUE app_name, VALUE param)
{
    (void)self;
    LF_Sequenced_Notify(rb_to_cstr(app_name), (TDataHnd)rb_to_handle(param));
    return Qnil;
}

/* ============================================================================
 * SECTION 20 - Remote invocation, UID addressing (5)
 * ============================================================================ */

struct uid_call_args {
    TP2P_UID  uid;
    void*     param;
    uint64_t  timeout_ms;
    void*     result;
};

static void* uid_call_no_gvl(void* arg)
{
    struct uid_call_args* a = (struct uid_call_args*)arg;
    a->result = LF_UID_Call(a->uid, (TDataHnd)a->param, a->timeout_ms);
    return NULL;
}

static VALUE rb_lf_uid_call(VALUE self, VALUE uid_str, VALUE param, VALUE timeout)
{
    (void)self;
    struct uid_call_args a;
    rb_to_uid(uid_str, &a.uid);
    a.param      = rb_to_handle(param);
    a.timeout_ms = (uint64_t)NUM2ULL(timeout);
    a.result     = NULL;

    rb_thread_call_without_gvl(uid_call_no_gvl, &a, RUBY_UBF_IO, NULL);

    return handle_to_rb(a.result);
}

static VALUE rb_lf_uid_async_call(
    VALUE self, VALUE uid_str, VALUE param,
    VALUE data_addr, VALUE on_result_addr)
{
    (void)self;
    TP2P_UID uid;
    rb_to_uid(uid_str, &uid);
    return INT2NUM(LF_UID_Async_Call(
        uid,
        (TDataHnd)rb_to_handle(param),
        (void*)(uintptr_t)NUM2ULL(data_addr),
        (LF_AsyncCallOnResult)(uintptr_t)NUM2ULL(on_result_addr)
    ));
}

static VALUE rb_lf_uid_async_sequenced_call(
    VALUE self, VALUE uid_str, VALUE param,
    VALUE data_addr, VALUE on_result_addr)
{
    (void)self;
    TP2P_UID uid;
    rb_to_uid(uid_str, &uid);
    return INT2NUM(LF_UID_Async_Sequenced_Call(
        uid,
        (TDataHnd)rb_to_handle(param),
        (void*)(uintptr_t)NUM2ULL(data_addr),
        (LF_AsyncCallOnResult)(uintptr_t)NUM2ULL(on_result_addr)
    ));
}

static VALUE rb_lf_uid_notify(VALUE self, VALUE uid_str, VALUE param)
{
    (void)self;
    TP2P_UID uid;
    rb_to_uid(uid_str, &uid);
    LF_UID_Notify(uid, (TDataHnd)rb_to_handle(param));
    return Qnil;
}

static VALUE rb_lf_uid_sequenced_notify(VALUE self, VALUE uid_str, VALUE param)
{
    (void)self;
    TP2P_UID uid;
    rb_to_uid(uid_str, &uid);
    LF_UID_Sequenced_Notify(uid, (TDataHnd)rb_to_handle(param));
    return Qnil;
}

/* ============================================================================
 * SECTION 21 - Remote invocation, P2PName addressing (5)
 * ============================================================================ */

struct p2p_call_args {
    const char* p2p_name;
    void*       param;
    uint64_t    timeout_ms;
    void*       result;
};

static void* p2p_call_no_gvl(void* arg)
{
    struct p2p_call_args* a = (struct p2p_call_args*)arg;
    a->result = LF_P2PNAME_Call(a->p2p_name, (TDataHnd)a->param, a->timeout_ms);
    return NULL;
}

static VALUE rb_lf_p2pname_call(
    VALUE self, VALUE p2p_name, VALUE param, VALUE timeout)
{
    (void)self;
    struct p2p_call_args a;
    a.p2p_name   = rb_to_cstr(p2p_name);
    a.param      = rb_to_handle(param);
    a.timeout_ms = (uint64_t)NUM2ULL(timeout);
    a.result     = NULL;

    rb_thread_call_without_gvl(p2p_call_no_gvl, &a, RUBY_UBF_IO, NULL);

    return handle_to_rb(a.result);
}

static VALUE rb_lf_p2pname_async_call(
    VALUE self, VALUE p2p_name, VALUE param,
    VALUE data_addr, VALUE on_result_addr)
{
    (void)self;
    return INT2NUM(LF_P2PNAME_Async_Call(
        rb_to_cstr(p2p_name),
        (TDataHnd)rb_to_handle(param),
        (void*)(uintptr_t)NUM2ULL(data_addr),
        (LF_AsyncCallOnResult)(uintptr_t)NUM2ULL(on_result_addr)
    ));
}

static VALUE rb_lf_p2pname_async_sequenced_call(
    VALUE self, VALUE p2p_name, VALUE param,
    VALUE data_addr, VALUE on_result_addr)
{
    (void)self;
    return INT2NUM(LF_P2PNAME_Async_Sequenced_Call(
        rb_to_cstr(p2p_name),
        (TDataHnd)rb_to_handle(param),
        (void*)(uintptr_t)NUM2ULL(data_addr),
        (LF_AsyncCallOnResult)(uintptr_t)NUM2ULL(on_result_addr)
    ));
}

static VALUE rb_lf_p2pname_notify(VALUE self, VALUE p2p_name, VALUE param)
{
    (void)self;
    LF_P2PNAME_Notify(rb_to_cstr(p2p_name), (TDataHnd)rb_to_handle(param));
    return Qnil;
}

static VALUE rb_lf_p2pname_sequenced_notify(VALUE self, VALUE p2p_name, VALUE param)
{
    (void)self;
    LF_P2PNAME_Sequenced_Notify(rb_to_cstr(p2p_name), (TDataHnd)rb_to_handle(param));
    return Qnil;
}

/* ============================================================================
 * SECTION 22 - Queries (7)
 * ============================================================================ */

static VALUE rb_lf_check_main_thread(VALUE self)
{
    (void)self;
    return INT2NUM(LF_CheckMainThread());
}

static VALUE rb_lf_check_app(VALUE self, VALUE name)
{
    (void)self;
    return INT2NUM(LF_CheckApp(rb_to_cstr(name)));
}

static VALUE rb_lf_check_api(VALUE self, VALUE app, VALUE api)
{
    (void)self;
    return INT2NUM(LF_CheckApi(rb_to_cstr(app), rb_to_cstr(api)));
}

static VALUE rb_lf_check_uid(VALUE self, VALUE uid_str)
{
    (void)self;
    TP2P_UID uid;
    rb_to_uid(uid_str, &uid);
    return INT2NUM(LF_Check_UID(uid));
}

static VALUE rb_lf_check_uid_api(VALUE self, VALUE uid_str, VALUE api)
{
    (void)self;
    TP2P_UID uid;
    rb_to_uid(uid_str, &uid);
    return INT2NUM(LF_Check_UID_Api(uid, rb_to_cstr(api)));
}

static VALUE rb_lf_check_p2pname(VALUE self, VALUE name)
{
    (void)self;
    return INT2NUM(LF_Check_P2PNAME(rb_to_cstr(name)));
}

static VALUE rb_lf_check_p2pname_api(VALUE self, VALUE name, VALUE api)
{
    (void)self;
    return INT2NUM(LF_Check_P2PNAME_Api(rb_to_cstr(name), rb_to_cstr(api)));
}

/* ============================================================================
 * SECTION 23 - Options (2)
 * ============================================================================ */

static VALUE rb_lf_set_option(VALUE self, VALUE option, VALUE value)
{
    (void)self;
    LF_SetOption(rb_to_cstr(option), rb_to_cstr(value));
    return Qnil;
}

static VALUE rb_lf_get_option(VALUE self, VALUE option)
{
    (void)self;
    return cstr_to_rb(LF_GetOption(rb_to_cstr(option)));
}

/* ============================================================================
 * SECTION 24 - Status (3)
 * ============================================================================ */

static VALUE rb_lf_get_status_count(VALUE self)
{
    (void)self;
    return INT2NUM(LF_GetStatusCount());
}

static VALUE rb_lf_get_status(VALUE self)
{
    (void)self;
    return cstr_to_rb(LF_GetStatus());
}

static VALUE rb_lf_post_status(VALUE self, VALUE status)
{
    (void)self;
    LF_PostStatus(rb_to_cstr(status));
    return Qnil;
}

/* ============================================================================
 * SECTION 25 - Network events (1)
 * ============================================================================
 * The two callback addresses are trampoline addresses obtained from
 * NativeBridge.network_connect_trampoline_addr /
 * NativeBridge.network_disconnect_trampoline_addr. Passing 0 disables
 * the slot.
 */

static VALUE rb_lf_set_network_event(
    VALUE self, VALUE on_connect_addr, VALUE on_disconnect_addr)
{
    (void)self;
    LF_NetworkEventFunc c = (LF_NetworkEventFunc)(uintptr_t)NUM2ULL(on_connect_addr);
    LF_NetworkEventFunc d = (LF_NetworkEventFunc)(uintptr_t)NUM2ULL(on_disconnect_addr);
    LF_Set_Network_Event(c, d);
    return Qnil;
}

/* ============================================================================
 * SECTION 26 - Shutdown (1)
 * ============================================================================ */

static void* shutdown_no_gvl(void* arg)
{
    (void)arg;
    LF_Shutdown();
    return NULL;
}

static VALUE rb_lf_shutdown(VALUE self)
{
    (void)self;
    rb_thread_call_without_gvl(shutdown_no_gvl, NULL, RUBY_UBF_IO, NULL);
    return Qnil;
}

/* ============================================================================
 * SECTION 27 - Test helpers
 * ============================================================================
 * These are used by test/test_native_bridge_self_test.rb. They invoke
 * the trampolines from a native thread or in-place, so that the queue
 * and dispatcher can be exercised without a real LingoFuse network.
 */

struct trigger_net_args {
    CallbackRef* ref;
    char*        addr_copy;
    int          kind;
};

static void* trigger_net_body(void* arg)
{
    struct trigger_net_args* ta = (struct trigger_net_args*)arg;

    if (ta->kind == LF_KIND_NETWORK_CONNECT) {
        trampoline_network_connect(ta->addr_copy);
    } else {
        trampoline_network_disconnect(ta->addr_copy);
    }

    return NULL;
}

static void* trigger_net_without_gvl(void* arg)
{
    struct trigger_net_args* ta = (struct trigger_net_args*)arg;
    pthread_t t;
    if (pthread_create(&t, NULL, trigger_net_body, ta) != 0) {
        return NULL;
    }
    pthread_join(t, NULL);
    return NULL;
}

static VALUE rb_test_invoke_network_event(
    VALUE self, VALUE ref_addr, VALUE addr_str, VALUE kind)
{
    (void)self;

    struct trigger_net_args ta;
    ta.ref       = (CallbackRef*)(uintptr_t)NUM2ULL(ref_addr);
    ta.kind      = NUM2INT(kind);
    ta.addr_copy = (addr_str == Qnil)
                     ? NULL
                     : lf_strdup_(StringValueCStr(addr_str));

    rb_thread_call_without_gvl(trigger_net_without_gvl, &ta, RUBY_UBF_IO, NULL);

    free(ta.addr_copy);
    return Qtrue;
}

static VALUE rb_test_invoke_network_event_inplace(
    VALUE self, VALUE ref_addr, VALUE addr_str, VALUE kind)
{
    (void)self;

    CallbackRef* ref = (CallbackRef*)(uintptr_t)NUM2ULL(ref_addr);
    int kind_int = NUM2INT(kind);
    const char* addr = (addr_str == Qnil)
                         ? NULL
                         : StringValueCStr(addr_str);

    dispatch_network(ref, addr);
    (void)kind_int;
    return Qtrue;
}

struct trigger_args {
    CallbackRef* ref;
    void*        input;
    void*        output;
    int          kind;
};

static void* trigger_thread_body(void* arg)
{
    struct trigger_args* ta = (struct trigger_args*)arg;

    if (ta->kind == LF_KIND_NOTIFY) {
        trampoline_notify(ta->ref, ta->input);
    } else if (ta->kind == LF_KIND_ASYNC_CALL) {
        trampoline_async_call(ta->ref, ta->input);
    } else {
        trampoline_call(ta->ref, ta->input, ta->output);
    }

    return NULL;
}

static void* trigger_without_gvl(void* arg)
{
    struct trigger_args* ta = (struct trigger_args*)arg;
    pthread_t t;
    if (pthread_create(&t, NULL, trigger_thread_body, ta) != 0) {
        return NULL;
    }
    pthread_join(t, NULL);
    return NULL;
}

static VALUE rb_test_invoke_from_native_thread(
    VALUE self, VALUE ref_addr, VALUE input, VALUE output, VALUE is_notify)
{
    (void)self;

    struct trigger_args ta;
    ta.ref    = (CallbackRef*)(uintptr_t)NUM2ULL(ref_addr);
    ta.input  = (input  == Qnil) ? NULL : (void*)(uintptr_t)NUM2ULL(input);
    ta.output = (output == Qnil) ? NULL : (void*)(uintptr_t)NUM2ULL(output);
    ta.kind   = RTEST(is_notify) ? LF_KIND_NOTIFY : LF_KIND_CALL;

    rb_thread_call_without_gvl(trigger_without_gvl, &ta, RUBY_UBF_IO, NULL);

    return Qtrue;
}

/*
 * rb_test_invoke_async_from_native_thread — invoke trampoline_async_call
 * from a native pthread, so that the queue + dispatcher path is
 * exercised end-to-end without a real async network round trip.
 *
 * The `result` argument is an Integer address that the caller may pass
 * arbitrarily. The Ruby proc will receive it verbatim. Passing Qnil
 * simulates a timeout / failure result (the native contract permits a
 * NULL result pointer on those paths).
 */
static VALUE rb_test_invoke_async_from_native_thread(
    VALUE self, VALUE ref_addr, VALUE result_addr)
{
    (void)self;

    struct trigger_args ta;
    ta.ref    = (CallbackRef*)(uintptr_t)NUM2ULL(ref_addr);
    ta.input  = (result_addr == Qnil)
                  ? NULL
                  : (void*)(uintptr_t)NUM2ULL(result_addr);
    ta.output = NULL;
    ta.kind   = LF_KIND_ASYNC_CALL;

    rb_thread_call_without_gvl(trigger_without_gvl, &ta, RUBY_UBF_IO, NULL);

    return Qtrue;
}

/* ============================================================================
 * SECTION 28 - Module initialization
 * ============================================================================ */

void Init_lingofuse_ext(void)
{
    VALUE m   = rb_define_module("LingoFuse");
    VALUE nb  = rb_define_module_under(m, "NativeBridge");
    VALUE nat = rb_define_module_under(m, "Native");

    /* --------------------------------------------------------------------
     * Loader (LingoFuse::Native)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "load_library", rb_native_load_library, 0);
    rb_define_singleton_method(nat, "free_library", rb_native_free_library, 0);
    rb_define_singleton_method(nat, "loaded?",      rb_native_loaded_p,     0);

    /* --------------------------------------------------------------------
     * Data handle (12)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_create_data",
                               rb_lf_create_data, 1);
    rb_define_singleton_method(nat, "lf_create_data_permanent",
                               rb_lf_create_data_permanent, 1);
    rb_define_singleton_method(nat, "lf_free_data",
                               rb_lf_free_data, 1);
    rb_define_singleton_method(nat, "lf_get_buffer",
                               rb_lf_get_buffer, 1);
    rb_define_singleton_method(nat, "lf_write_buffer",
                               rb_lf_write_buffer, 3);
    rb_define_singleton_method(nat, "lf_read_buffer",
                               rb_lf_read_buffer, 2);
    rb_define_singleton_method(nat, "lf_get_pos",
                               rb_lf_get_pos, 1);
    rb_define_singleton_method(nat, "lf_set_pos",
                               rb_lf_set_pos, 2);
    rb_define_singleton_method(nat, "lf_get_size",
                               rb_lf_get_size, 1);
    rb_define_singleton_method(nat, "lf_set_size",
                               rb_lf_set_size, 2);
    rb_define_singleton_method(nat, "lf_get_p2p_uid",
                               rb_lf_get_p2p_uid, 1);
    rb_define_singleton_method(nat, "lf_get_p2p_name",
                               rb_lf_get_p2p_name, 1);

    /* --------------------------------------------------------------------
     * Application handle (5)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_create_app",
                               rb_lf_create_app, 2);
    rb_define_singleton_method(nat, "lf_free_app",
                               rb_lf_free_app, 1);
    rb_define_singleton_method(nat, "lf_generate_app_name",
                               rb_lf_generate_app_name, 0);
    rb_define_singleton_method(nat, "lf_get_app_name",
                               rb_lf_get_app_name, 1);
    rb_define_singleton_method(nat, "lf_bind_app",
                               rb_lf_bind_app, 1);

    /* --------------------------------------------------------------------
     * API registration, app-bound (3)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_register_call",
                               rb_lf_register_call, 5);
    rb_define_singleton_method(nat, "lf_register_notify",
                               rb_lf_register_notify, 5);
    rb_define_singleton_method(nat, "lf_unregister",
                               rb_lf_unregister, 2);

    /* --------------------------------------------------------------------
     * API registration, process-wide P2P (3)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_register_p2p_call",
                               rb_lf_register_p2p_call, 4);
    rb_define_singleton_method(nat, "lf_register_p2p_notify",
                               rb_lf_register_p2p_notify, 4);
    rb_define_singleton_method(nat, "lf_unregister_p2p",
                               rb_lf_unregister_p2p, 1);

    /* --------------------------------------------------------------------
     * Local execution (2)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_local_call",
                               rb_lf_local_call, 2);
    rb_define_singleton_method(nat, "lf_local_notify",
                               rb_lf_local_notify, 2);

    /* --------------------------------------------------------------------
     * Network preparation (5)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_prepare_service",
                               rb_lf_prepare_service, 2);
    rb_define_singleton_method(nat, "lf_prepare_client",
                               rb_lf_prepare_client, 2);
    rb_define_singleton_method(nat, "lf_reset_prepare",
                               rb_lf_reset_prepare, 0);
    rb_define_singleton_method(nat, "lf_prepare_done",
                               rb_lf_prepare_done, 0);
    rb_define_singleton_method(nat, "lf_exit_main_thread",
                               rb_lf_exit_main_thread, 0);

    /* --------------------------------------------------------------------
     * Remote invocation, app-name addressing (5)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_call",
                               rb_lf_call, 3);
    rb_define_singleton_method(nat, "lf_async_call",
                               rb_lf_async_call, 4);
    rb_define_singleton_method(nat, "lf_async_sequenced_call",
                               rb_lf_async_sequenced_call, 4);
    rb_define_singleton_method(nat, "lf_notify",
                               rb_lf_notify, 2);
    rb_define_singleton_method(nat, "lf_sequenced_notify",
                               rb_lf_sequenced_notify, 2);

    /* --------------------------------------------------------------------
     * Remote invocation, UID addressing (5)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_uid_call",
                               rb_lf_uid_call, 3);
    rb_define_singleton_method(nat, "lf_uid_async_call",
                               rb_lf_uid_async_call, 4);
    rb_define_singleton_method(nat, "lf_uid_async_sequenced_call",
                               rb_lf_uid_async_sequenced_call, 4);
    rb_define_singleton_method(nat, "lf_uid_notify",
                               rb_lf_uid_notify, 2);
    rb_define_singleton_method(nat, "lf_uid_sequenced_notify",
                               rb_lf_uid_sequenced_notify, 2);

    /* --------------------------------------------------------------------
     * Remote invocation, P2PName addressing (5)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_p2pname_call",
                               rb_lf_p2pname_call, 3);
    rb_define_singleton_method(nat, "lf_p2pname_async_call",
                               rb_lf_p2pname_async_call, 4);
    rb_define_singleton_method(nat, "lf_p2pname_async_sequenced_call",
                               rb_lf_p2pname_async_sequenced_call, 4);
    rb_define_singleton_method(nat, "lf_p2pname_notify",
                               rb_lf_p2pname_notify, 2);
    rb_define_singleton_method(nat, "lf_p2pname_sequenced_notify",
                               rb_lf_p2pname_sequenced_notify, 2);

    /* --------------------------------------------------------------------
     * Queries (7)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_check_main_thread",
                               rb_lf_check_main_thread, 0);
    rb_define_singleton_method(nat, "lf_check_app",
                               rb_lf_check_app, 1);
    rb_define_singleton_method(nat, "lf_check_api",
                               rb_lf_check_api, 2);
    rb_define_singleton_method(nat, "lf_check_uid",
                               rb_lf_check_uid, 1);
    rb_define_singleton_method(nat, "lf_check_uid_api",
                               rb_lf_check_uid_api, 2);
    rb_define_singleton_method(nat, "lf_check_p2pname",
                               rb_lf_check_p2pname, 1);
    rb_define_singleton_method(nat, "lf_check_p2pname_api",
                               rb_lf_check_p2pname_api, 2);

    /* --------------------------------------------------------------------
     * Options (2)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_set_option",
                               rb_lf_set_option, 2);
    rb_define_singleton_method(nat, "lf_get_option",
                               rb_lf_get_option, 1);

    /* --------------------------------------------------------------------
     * Status (3)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_get_status_count",
                               rb_lf_get_status_count, 0);
    rb_define_singleton_method(nat, "lf_get_status",
                               rb_lf_get_status, 0);
    rb_define_singleton_method(nat, "lf_post_status",
                               rb_lf_post_status, 1);

    /* --------------------------------------------------------------------
     * Network events (1)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_set_network_event",
                               rb_lf_set_network_event, 2);

    /* --------------------------------------------------------------------
     * Shutdown (1)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nat, "lf_shutdown",
                               rb_lf_shutdown, 0);

    /* --------------------------------------------------------------------
     * Callback marshaling (LingoFuse::NativeBridge)
     * ------------------------------------------------------------------ */

    rb_define_singleton_method(nb, "process_all",
                               rb_process_all, 0);
    rb_define_singleton_method(nb, "wait_for_work",
                               rb_wait_for_work, 1);
    rb_define_singleton_method(nb, "create_ref",
                               rb_create_ref, 2);
    rb_define_singleton_method(nb, "free_ref",
                               rb_free_ref, 1);
    rb_define_singleton_method(nb, "call_trampoline_addr",
                               rb_call_trampoline_addr, 0);
    rb_define_singleton_method(nb, "notify_trampoline_addr",
                               rb_notify_trampoline_addr, 0);
    rb_define_singleton_method(nb, "async_call_trampoline_addr",
                               rb_async_call_trampoline_addr, 0);
    rb_define_singleton_method(nb, "network_connect_trampoline_addr",
                               rb_network_connect_trampoline_addr, 0);
    rb_define_singleton_method(nb, "network_disconnect_trampoline_addr",
                               rb_network_disconnect_trampoline_addr, 0);
    rb_define_singleton_method(nb, "set_network_refs",
                               rb_set_network_refs, 2);

    /* Test-only surface */
    rb_define_singleton_method(nb, "test_invoke_from_native_thread",
                               rb_test_invoke_from_native_thread, 4);
    rb_define_singleton_method(nb, "test_invoke_network_event",
                               rb_test_invoke_network_event, 3);
    rb_define_singleton_method(nb, "test_invoke_network_event_inplace",
                               rb_test_invoke_network_event_inplace, 3);
    rb_define_singleton_method(nb, "test_invoke_async_from_native_thread",
                               rb_test_invoke_async_from_native_thread, 2);

    /* --------------------------------------------------------------------
     * Attempt to load the native library at extension-load time.
     *
     * A failure here is non-fatal: the Ruby side can call
     * LingoFuse::Native.load_library again later, which is useful when
     * the DLL is placed on PATH only after the Ruby process starts.
     * ------------------------------------------------------------------ */

    if (LF_LoadLibrary()) {
        g_rb_loaded = 1;
    } else {
        fprintf(stderr,
                "[LingoFuse::Native] native library not available at "
                "extension load; call LingoFuse::Native.load_library "
                "after adding the DLL directory to PATH.\n");
    }
}