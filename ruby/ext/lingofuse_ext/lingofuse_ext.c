/*
 * lingofuse_ext.c — Native-side callback marshaling for the Ruby binding.
 *
 * ============================================================================
 * WHY THIS EXTENSION EXISTS
 * ============================================================================
 * Fiddle cannot invoke a Ruby callback from a thread that the Ruby VM
 * does not know about. LingoFuse delivers every received Call / Notify /
 * Sequenced Notify / Network event on a worker thread created by its own
 * TCompute scheduler. When Fiddle's Closure::BlockCaller then tries to
 * re-enter the interpreter from such a thread, MRI raises
 *
 *     [BUG] rb_thread_call_with_gvl() is called by non-ruby thread
 *
 * and the process deadlocks permanently.
 *
 * This extension breaks the cycle by interposing a native queue between
 * the LingoFuse callback thread and a dedicated Ruby dispatcher thread.
 *
 * ============================================================================
 * TWO PATHS: GVL-HOLDING AND GVL-LESS
 * ============================================================================
 * LingoFuse invokes a callback from two contexts:
 *
 *   1. GVL held (LocalCall / LocalNotify on the Ruby main thread)
 *      The Proc runs DIRECTLY on the calling thread via rb_protect.
 *      No queue is involved.
 *
 *   2. GVL not held (a native worker thread)
 *      The callback enqueues a CallbackItem and blocks until the Ruby
 *      dispatcher thread signals completion. The native thread never
 *      touches a Ruby object.
 *
 * The two paths are selected by ruby_thread_has_gvl_p().
 *
 * ============================================================================
 * CALLBACK KINDS
 * ============================================================================
 * A single integer `kind` field distinguishes the four callback shapes:
 *
 *   0  Call            — Proc receives (input, output)
 *   1  Notify          — Proc receives (input)
 *   2  NetworkConnect  — Proc receives (addr_string)
 *   3  NetworkDisconn  — Proc receives (addr_string)
 *
 * The arity is decided by the trampoline that enqueued the item, never
 * by inspecting a pointer at dispatch time.
 *
 * ============================================================================
 * NETWORK EVENT GLOBALS
 * ============================================================================
 * LF_Set_Network_Event has no `trigger` argument: it takes two raw
 * function pointers. The extension therefore keeps a pair of process-
 * wide CallbackRef pointers, set by install_network_event() before the
 * Ruby side calls LF_Set_Network_Event. The trampolines read those
 * globals.
 *
 * This mirrors LF_Set_Network_Event's own process-wide semantics.
 *
 * ============================================================================
 * ABI NOTE
 * ============================================================================
 * This extension does NOT link against LingoFuse. It only provides:
 *
 *   - a place to store a Ruby Proc for each registered API, and
 *   - C function addresses that can be handed to LF_RegisterCall /
 *     LF_RegisterNotify / LF_Set_Network_Event through Fiddle.
 *
 * ============================================================================
 * PORTABILITY
 * ============================================================================
 * <sys/time.h> is deliberately NOT included: on MinGW-w64 it collides
 * with ruby/win32.h over gettimeofday. clock_gettime is available
 * through winpthreads, which the Ruby DevKit already links.
 *
 * ============================================================================
 */

#include <ruby.h>
#include <ruby/thread.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ============================================================================
 * Callback kinds
 * ============================================================================
 */

#define LF_KIND_CALL               0
#define LF_KIND_NOTIFY             1
#define LF_KIND_NETWORK_CONNECT    2
#define LF_KIND_NETWORK_DISCONNECT 3

/* ============================================================================
 * Data structures
 * ============================================================================
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
 * Global state
 * ============================================================================
 */

static pthread_mutex_t g_queue_lock  = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_work_cond   = PTHREAD_COND_INITIALIZER;
static pthread_cond_t  g_done_cond   = PTHREAD_COND_INITIALIZER;

static CallbackItem*   g_queue_head  = NULL;
static CallbackItem*   g_queue_tail  = NULL;

/* Process-wide network event refs. Set by install_network_event() and
 * cleared by the same function; the trampolines read them. */
static pthread_mutex_t g_net_lock          = PTHREAD_MUTEX_INITIALIZER;
static CallbackRef*    g_net_connect_ref   = NULL;
static CallbackRef*    g_net_disconnect_ref = NULL;

/* ============================================================================
 * Small utilities
 * ============================================================================
 */

/* A portable strdup; stdlib.h's strdup is not guaranteed by C89 and
 * older MinGW headers may hide it behind feature macros. */
static char* lf_strdup(const char* s)
{
    if (s == NULL) {
        return NULL;
    }
    size_t len = strlen(s) + 1;
    char* p = (char*)malloc(len);
    if (p != NULL) {
        memcpy(p, s, len);
    }
    return p;
}

/* ============================================================================
 * Queue primitives
 * ============================================================================
 */

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
 * Dispatch helpers
 * ============================================================================
 */

static VALUE dispatch_protected(VALUE arg)
{
    DispatchArgs* a = (DispatchArgs*)arg;

    switch (a->kind) {
    case LF_KIND_NOTIFY:
    case LF_KIND_NETWORK_CONNECT:
    case LF_KIND_NETWORK_DISCONNECT:
        return rb_funcall(a->proc, rb_intern("call"), 1, a->input);
    case LF_KIND_CALL:
    default:
        return rb_funcall(a->proc, rb_intern("call"), 2, a->input, a->output);
    }
}

/* Run the Proc on the current thread, absorbing any exception.
 * Requires the current thread to hold the GVL. */
static void dispatch_in_place(DispatchArgs* args)
{
    int state = 0;
    rb_protect(dispatch_protected, (VALUE)args, &state);

    if (state != 0) {
        VALUE err = rb_errinfo();
        VALUE msg = rb_obj_as_string(err);
        /* Direct fd-2 write. This is the LAST-RESORT reporter; the
         * Ruby wrapper normally catches exceptions before they reach
         * this point. */
        fprintf(stderr,
                "[LingoFuse::NativeBridge] callback raised: %s\n",
                StringValueCStr(msg));
        rb_set_errinfo(Qnil);
    }
}

/* ============================================================================
 * Native callback trampolines for Call / Notify
 * ============================================================================
 */

static void trampoline_call(void* trigger, void* input, void* output)
{
    CallbackRef* ref = (CallbackRef*)trigger;
    if (ref == NULL) {
        return;
    }

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
    if (item == NULL) {
        return;
    }

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
    if (ref == NULL) {
        return;
    }

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
    if (item == NULL) {
        return;
    }

    item->proc   = ref->proc;
    item->input  = input;
    item->output = NULL;
    item->kind   = LF_KIND_NOTIFY;
    item->done   = 0;

    enqueue_item(item);
    wait_for_item(item);
    free(item);
}

/* ============================================================================
 * Network event dispatch
 * ============================================================================
 */

/* Common entry for both network trampolines. The `addr` pointer is
 * owned by LingoFuse and is freed immediately after this function
 * returns, so on the native-thread path we MUST copy it before
 * enqueuing. */
static void dispatch_network(CallbackRef* ref, const char* addr)
{
    if (ref == NULL) {
        return;
    }

    if (ruby_thread_has_gvl_p()) {
        VALUE addr_str = (addr != NULL) ? rb_str_new_cstr(addr) : Qnil;
        DispatchArgs args;
        args.proc   = ref->proc;
        args.input  = addr_str;
        args.output = Qnil;
        args.kind   = ref->kind;
        dispatch_in_place(&args);
        return;
    }

    /* Native thread: copy `addr` so the item survives the return. */
    char* addr_copy = (addr != NULL) ? lf_strdup(addr) : NULL;

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

/* ============================================================================
 * Ruby dispatcher
 * ============================================================================
 */

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
            /* item->input is a native char* buffer, not a handle. */
            args.input = (item->input != NULL)
                            ? rb_str_new_cstr((const char*)item->input)
                            : Qnil;
            args.output = Qnil;
            break;
        case LF_KIND_NOTIFY:
            args.input  = ULL2NUM((unsigned long long)(uintptr_t)item->input);
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
 * Wait primitives
 * ============================================================================
 */

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
    if (wa.timeout_ms < 0) {
        wa.timeout_ms = 0;
    }

    rb_thread_call_without_gvl(wait_impl, &wa, RUBY_UBF_IO, NULL);

    return wa.has_work ? Qtrue : Qfalse;
}

/* ============================================================================
 * Registration bookkeeping
 * ============================================================================
 */

/* kind is an Integer:
 *   0 = Call, 1 = Notify, 2 = Network connect, 3 = Network disconnect
 * Boolean true/false are accepted for backward compatibility and are
 * coerced to 1 and 0 respectively. */
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
    if (ptr == 0) {
        return Qnil;
    }

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

/* Store the process-wide network refs. Passing Qnil clears the slot. */
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
 * Test helpers
 * ============================================================================
 */

/* Simulate a network event from a native thread (GVL released). */
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

/* Invoke a network trampoline from a real native thread. */
static VALUE rb_test_invoke_network_event(
    VALUE self, VALUE ref_addr, VALUE addr_str, VALUE kind)
{
    (void)self;

    struct trigger_net_args ta;
    ta.ref       = (CallbackRef*)(uintptr_t)NUM2ULL(ref_addr);
    ta.kind      = NUM2INT(kind);
    ta.addr_copy = (addr_str == Qnil)
                     ? NULL
                     : lf_strdup(StringValueCStr(addr_str));

    rb_thread_call_without_gvl(trigger_net_without_gvl, &ta, RUBY_UBF_IO, NULL);

    free(ta.addr_copy);
    return Qtrue;
}

/* Invoke a network trampoline from the calling (Ruby) thread. */
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

/* Existing Call / Notify native-thread trigger, kept for compatibility. */
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

/* ============================================================================
 * Module initialisation
 * ============================================================================
 */

void Init_lingofuse_ext(void)
{
    VALUE m  = rb_define_module("LingoFuse");
    VALUE nb = rb_define_module_under(m, "NativeBridge");

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
    rb_define_singleton_method(nb, "network_connect_trampoline_addr",
                               rb_network_connect_trampoline_addr, 0);
    rb_define_singleton_method(nb, "network_disconnect_trampoline_addr",
                               rb_network_disconnect_trampoline_addr, 0);
    rb_define_singleton_method(nb, "set_network_refs",
                               rb_set_network_refs, 2);

    /* Test-only surface. */
    rb_define_singleton_method(nb, "test_invoke_from_native_thread",
                               rb_test_invoke_from_native_thread, 4);
    rb_define_singleton_method(nb, "test_invoke_network_event",
                               rb_test_invoke_network_event, 3);
    rb_define_singleton_method(nb, "test_invoke_network_event_inplace",
                               rb_test_invoke_network_event_inplace, 3);
}