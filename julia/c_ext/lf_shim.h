/*
 * lf_shim.h - Thread-safe C callback bridge for LingoFuse.
 *
 * Problem
 * -------
 * LingoFuse invokes registered Call / Notify callbacks on background C4
 * worker threads. Julia's GC, JIT, and Task scheduler all require that
 * any thread entering Julia be "adopted" by the runtime. A raw
 * @cfunction pointer handed to LingoFuse would therefore crash or
 * corrupt GC state.
 *
 * Solution
 * --------
 * This shim registers NATIVE C trampolines with LingoFuse. Each
 * trampoline packages the callback arguments into an event, pushes it
 * onto a process-wide queue, and then BLOCKS until a Julia-side
 * consumer signals completion. The LingoFuse-side worker thread is
 * blocked for the duration, exactly as it would be if the user
 * callback ran inline. There is no semantic change from LingoFuse's
 * perspective.
 *
 * Julia runs a single consumer task on a dedicated Julia thread. It
 * dequeues events, invokes the user handler, and signals the
 * trampoline to return. The consumer never touches the native data
 * handles; the shim snapshots the input payload and accepts the
 * consumer's response through lf_shim_set_output.
 *
 * Threading contract
 * ------------------
 *   C4 worker thread  -> trampoline (native C) -> queue -> BLOCKS
 *   Julia consumer    -> wait_event -> user handler -> complete_event
 *   main thread       -> free to do anything else
 *
 * The queue itself is a simple singly-linked list protected by a
 * mutex + condition variable. The critical sections are tiny (pointer
 * swaps); all real work happens outside the lock.
 *
 * Event kind constants
 * --------------------
 *   0  LF_SHIM_EVENT_CALL               Call-mode callback (has output)
 *   1  LF_SHIM_EVENT_NOTIFY             Notify-mode callback
 *   2  LF_SHIM_EVENT_NETWORK_CONNECT    Client became online
 *   3  LF_SHIM_EVENT_NETWORK_DISCONNECT Client went offline
 *
 * user_id
 * -------
 * An opaque int64_t supplied at registration time. LingoFuse's
 * `trigger` pointer is used to carry this id end-to-end: the shim
 * casts it to void* on the way in, and casts it back on the way out.
 * This lets Julia dispatch to the correct handler without exposing
 * any Julia-managed state to native code.
 *
 * Export macro
 * ------------
 * LF_SHIM_API marks a symbol as part of the public ABI of the
 * compiled shared library. The definition below chooses the correct
 * spelling for the compiler that is processing the header:
 *
 *   - MinGW / Clang on Windows: __attribute__((dllexport))
 *   - MSVC on Windows:          __declspec(dllexport)
 *   - GCC / Clang on POSIX:     __attribute__((visibility("default")))
 *   - Anything else:            (empty; the symbol is not exported)
 *
 * Every branch yields a syntactically valid declaration, so
 * IntelliSense parsers that do not recognise one family of
 * attributes still see a well-formed header.
 */

#ifndef LF_SHIM_H
#define LF_SHIM_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
  #if defined(__GNUC__) || defined(__clang__)
    #define LF_SHIM_API __attribute__((dllexport))
  #elif defined(_MSC_VER)
    #define LF_SHIM_API __declspec(dllexport)
  #else
    #define LF_SHIM_API
  #endif
#elif defined(__GNUC__) || defined(__clang__)
  #define LF_SHIM_API __attribute__((visibility("default")))
#else
  #define LF_SHIM_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lf_shim_event lf_shim_event_t;

/* Event kinds. */
enum {
    LF_SHIM_EVENT_CALL               = 0,
    LF_SHIM_EVENT_NOTIFY             = 1,
    LF_SHIM_EVENT_NETWORK_CONNECT    = 2,
    LF_SHIM_EVENT_NETWORK_DISCONNECT = 3
};

/* ------------------------------------------------------------------ */
/* Lifecycle                                                          */
/* ------------------------------------------------------------------ */

/* Initialise the shim's queue and synchronisation primitives.
 * Must be called exactly once, before any other shim function.
 * Returns 1 on success, 0 on failure. */
LF_SHIM_API int  lf_shim_init(void);

/* Signal any blocked consumer to exit and release the queue.
 * Safe to call multiple times. Does NOT free pending events; callers
 * that need to drain should do so before calling shutdown. */
LF_SHIM_API void lf_shim_shutdown(void);

/* ------------------------------------------------------------------ */
/* Registration (mirrors the underlying LF_* registration calls)      */
/* ------------------------------------------------------------------ */

/* Register a Call-mode API. Returns 1 on success, 0 on failure
 * (typically a duplicate API name). */
LF_SHIM_API int  lf_shim_register_call(
    void*       app,
    const char* name,
    const char* desc,
    int64_t     user_id);

/* Register a Notify-mode API. */
LF_SHIM_API int  lf_shim_register_notify(
    void*       app,
    const char* name,
    const char* desc,
    int64_t     user_id);

/* Install process-global network event callbacks. */
LF_SHIM_API void lf_shim_install_network_events(
    int64_t connect_user_id,
    int64_t disconnect_user_id);

/* Clear both network event callbacks. */
LF_SHIM_API void lf_shim_clear_network_events(void);

/* ------------------------------------------------------------------ */
/* Consumer side (called from Julia)                                  */
/* ------------------------------------------------------------------ */

/* Block until an event is available or the timeout elapses.
 * `timeout_ms < 0` means wait forever.
 * Returns NULL on timeout or shutdown. The caller must call
 * lf_shim_complete_event on a non-NULL result. */
LF_SHIM_API lf_shim_event_t* lf_shim_wait_event(int timeout_ms);

/* --- Event accessors (const; no ownership transfer) --- */

/* Returns one of the LF_SHIM_EVENT_* constants. */
LF_SHIM_API int         lf_shim_event_kind   (const lf_shim_event_t* e);

/* Returns the user_id supplied at registration time. */
LF_SHIM_API int64_t     lf_shim_event_user_id(const lf_shim_event_t* e);

/* Borrowed DataHnd values, valid only on the trampoline thread for
 * the duration of the callback. Provided for completeness; the
 * consumer must NOT use them. */
LF_SHIM_API void*       lf_shim_event_input  (const lf_shim_event_t* e);
LF_SHIM_API void*       lf_shim_event_output (const lf_shim_event_t* e);

/* NUL-terminated UTF-8 endpoint string. NULL for non-network events. */
LF_SHIM_API const char* lf_shim_event_addr   (const lf_shim_event_t* e);

/* ------------------------------------------------------------------ */
/* Event payload accessors                                            */
/* ------------------------------------------------------------------ */
/*
 * The trampoline snapshots the input handle's payload into a heap
 * buffer BEFORE pushing the event, so the consumer never touches the
 * native data handle.
 *
 * A consumer that read from the native input handle, or wrote to the
 * native output handle, would enter the real LingoFuse library from
 * a thread other than the one that owns the handle, and would
 * deadlock on the library's per-handle locks. Snapshotting removes
 * that class of failure entirely.
 *
 * Lifetime
 * --------
 * The pointer and length returned by lf_shim_event_input_data and
 * lf_shim_event_input_len are valid until lf_shim_complete_event
 * returns. The consumer must copy the bytes into its own storage
 * before that point if it needs to retain them.
 */

/* Return the snapshot of the input payload, or NULL when the input
 * was empty or absent. */
LF_SHIM_API const void* lf_shim_event_input_data(const lf_shim_event_t* e);

/* Return the length, in bytes, of the input snapshot. Zero when the
 * input was empty or absent. */
LF_SHIM_API size_t      lf_shim_event_input_len (const lf_shim_event_t* e);

/* ------------------------------------------------------------------ */
/* Output payload                                                     */
/* ------------------------------------------------------------------ */
/*
 * The consumer hands the response bytes to the shim through this
 * function. The data is copied into a heap buffer owned by the event.
 * The trampoline writes the buffer to the native output handle after
 * the consumer signals completion.
 *
 * Calling this more than once replaces the previous payload: the old
 * buffer is freed first.
 *
 * Passing len == 0 clears any previously set output and marks the
 * response as empty. The trampoline then writes nothing to the
 * native output handle.
 *
 * Returns 1 on success and 0 on a null event or an allocation
 * failure.
 */
LF_SHIM_API int lf_shim_set_output(lf_shim_event_t* e,
                                   const void*      data,
                                   size_t           len);

/* Signal the blocked trampoline to return. The consumer MUST have
 * finished all output work (via lf_shim_set_output) before calling
 * this. The event object is freed by the trampoline after this
 * returns; the caller must not touch it afterwards. */
LF_SHIM_API void lf_shim_complete_event(lf_shim_event_t* e);

/* ------------------------------------------------------------------ */
/* Test-only drivers (implemented by mock_lf.c, not by the shim)      */
/* ------------------------------------------------------------------ */
/* These exist only to simulate the C4 worker thread that would
 * normally dispatch a callback. A production build links against the
 * real LingoFuse library and does not reference them. */

LF_SHIM_API void mock_lf_trigger_call(
    const char* api_name,
    const void* input_bytes, size_t input_len,
    void*       output_buf,  size_t output_cap,
    size_t*     out_written);

LF_SHIM_API void mock_lf_trigger_notify(
    const char* api_name,
    const void* input_bytes, size_t input_len);

LF_SHIM_API void mock_lf_trigger_network_event(
    int         is_connect,
    const char* addr);

#ifdef __cplusplus
}
#endif

#endif /* LF_SHIM_H */