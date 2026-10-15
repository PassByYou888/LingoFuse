/*
 * mock_lf.h - Minimal in-memory mock of the LingoFuse C ABI.
 *
 * Purpose
 * -------
 * The real LingoFuse library cannot be exercised from a unit test
 * without a full mesh, a service endpoint, and a running node. This
 * mock provides JUST the ABI surface that lf_shim.c needs, plus a
 * set of test drivers that simulate the C4 worker thread by
 * spawning a real native thread and invoking the registered
 * callback on it.
 *
 * What is mocked
 * --------------
 *   Data handles    - a heap buffer with a read/write cursor.
 *   App handles     - a heap struct carrying a name and description.
 *   Registration    - one linked list keyed by (name, namespace,
 *                     mode); namespace is App-bound or P2P, mode is
 *                     Call or Notify. Duplicate detection is per
 *                     (name, namespace, mode) triple.
 *   Network events  - two function pointers.
 *   Async dispatch  - a linked list of pending async operations,
 *                     keyed by user_token. Each entry stores the
 *                     result callback and the opaque data pointer
 *                     the caller supplied.
 *   Runtime options - a fixed-size key/value store. LF_SetOption
 *                     updates or inserts an entry; LF_GetOption
 *                     returns the stored value or "" when absent.
 *
 * What is NOT mocked
 * ------------------
 *   Any LingoFuse semantics beyond the raw ABI. No discovery, no
 *   broadcasting, no timeouts, no load balancing. This mock exists
 *   only to prove the shim's cross-thread mechanism works, and to
 *   let the Julia binding exercise every shim entry point without a
 *   live mesh.
 *
 * ABI compatibility with the real library
 * ---------------------------------------
 * Every function declared here has the exact same signature as the
 * corresponding LF_* export in the real LingoFuse library, EXCEPT
 * for the following deliberate relaxations:
 *
 *   - lf_shim_uid_t (defined in lf_shim.h) is used for the UID
 *     argument of LF_UID_Async_Call and LF_UID_Async_Sequenced_Call.
 *     The real library declares that argument as TP2P_UID___, which
 *     is array[0..31] of Byte. Both are 32-byte aggregates passed by
 *     value in the same psABI class (MEMORY), so the two are
 *     ABI-compatible for these argument-role positions.
 *
 *   - The trigger / data pointer of every registration and async
 *     dispatch call is passed through verbatim; the mock never
 *     inspects it. The real library behaves identically.
 *
 * Test drivers
 * ------------
 * Four drivers simulate the C4 worker thread by spawning a fresh
 * native thread, invoking the registered callback on it, and joining
 * before returning. This exactly matches the C4 worker-thread
 * behaviour that the shim is designed to survive.
 *
 *   mock_lf_trigger_call              App-bound Call dispatch
 *   mock_lf_trigger_p2p_call          Process-wide P2P Call dispatch
 *   mock_lf_trigger_notify            App-bound Notify dispatch
 *   mock_lf_trigger_p2p_notify        Process-wide P2P Notify dispatch
 *   mock_lf_trigger_network_event     Network connect / disconnect
 *   mock_lf_trigger_async_result      Async result delivery
 *
 * The async driver looks up the pending operation by user_token,
 * constructs a fresh result data handle carrying the supplied bytes,
 * invokes the trampoline on a native thread, and frees the handle.
 * A second call with the same token re-invokes the trampoline; this
 * is used by tests that exercise a late / duplicate result.
 *
 * Option storage
 * --------------
 * The mock keeps a fixed-size (name, value) table. Unknown names
 * return "". The table is process-global and is never reset; tests
 * that need a clean slate should restart the process.
 */

#ifndef MOCK_LF_H
#define MOCK_LF_H

#include <stddef.h>
#include <stdint.h>

/* lf_shim_uid_t is defined in lf_shim.h. Including that header here
 * keeps the UID type byte-for-byte identical between the shim and
 * the mock, so the async UID primitives have a single shared ABI. */
#include "lf_shim.h"

#if defined(_WIN32)
  #define MOCK_LF_API __declspec(dllexport)
#else
  #define MOCK_LF_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ====================================================================== */
/* Data handle                                                             */
/* ====================================================================== */

MOCK_LF_API void*   LF_CreateData(const char* method_name);
MOCK_LF_API void*   LF_CreateData_Permanent(const char* method_name);
MOCK_LF_API void    LF_FreeData(void* hnd);
MOCK_LF_API void*   LF_GetBuffer(void* hnd);
MOCK_LF_API int64_t LF_WriteBuffer(void* hnd, const void* buff, int64_t size);
MOCK_LF_API int64_t LF_ReadBuffer(void* hnd, void* buff, int64_t size);
MOCK_LF_API int64_t LF_GetPos(void* hnd);
MOCK_LF_API void    LF_SetPos(void* hnd, int64_t pos);
MOCK_LF_API int64_t LF_GetSize(void* hnd);
MOCK_LF_API void    LF_SetSize(void* hnd, int64_t size);

/* ====================================================================== */
/* App handle                                                              */
/* ====================================================================== */

MOCK_LF_API void* LF_CreateApp(const char* app_name, const char* desc);
MOCK_LF_API void  LF_FreeApp(void* app_hnd);

/* ====================================================================== */
/* Registration: App-bound                                                 */
/* ====================================================================== */

MOCK_LF_API int LF_RegisterCall(
    void* app, const char* name, const char* desc,
    void* trigger,
    void (*cb)(void* trigger, void* input, void* output));

MOCK_LF_API int LF_RegisterNotify(
    void* app, const char* name, const char* desc,
    void* trigger,
    void (*cb)(void* trigger, void* input));

/* ====================================================================== */
/* Registration: process-wide P2P                                          */
/* ====================================================================== */

MOCK_LF_API int LF_Register_P2P_Call(
    const char* name, const char* desc,
    void* trigger,
    void (*cb)(void* trigger, void* input, void* output));

MOCK_LF_API int LF_Register_P2P_Notify(
    const char* name, const char* desc,
    void* trigger,
    void (*cb)(void* trigger, void* input));

MOCK_LF_API int LF_Unregister_P2P(const char* name);

/* ====================================================================== */
/* Network events                                                          */
/* ====================================================================== */

MOCK_LF_API void LF_Set_Network_Event(
    void (*on_connect)(const char* addr),
    void (*on_disconnect)(const char* addr));

/* ====================================================================== */
/* Async dispatch                                                          */
/* ====================================================================== */
/*
 * Each primitive records a pending operation keyed by the caller's
 * `data` pointer (which the shim sets to the user_token as a void*).
 * The result callback is stored verbatim and is invoked later by
 * mock_lf_trigger_async_result.
 *
 * Return value: 1 on success (request recorded), 0 on failure.
 * The mock does not currently expose a way to force failure; tests
 * that need the failure path should arrange for the caller to ignore
 * the return value in a way that exercises the code under test.
 */

MOCK_LF_API int LF_Async_Call(
    const char* app_name, void* param, void* data,
    void (*cb)(void* data, void* result));

MOCK_LF_API int LF_Async_Sequenced_Call(
    const char* app_name, void* param, void* data,
    void (*cb)(void* data, void* result));

MOCK_LF_API int LF_UID_Async_Call(
    lf_shim_uid_t uid, void* param, void* data,
    void (*cb)(void* data, void* result));

MOCK_LF_API int LF_UID_Async_Sequenced_Call(
    lf_shim_uid_t uid, void* param, void* data,
    void (*cb)(void* data, void* result));

MOCK_LF_API int LF_P2PNAME_Async_Call(
    const char* group_name, void* param, void* data,
    void (*cb)(void* data, void* result));

MOCK_LF_API int LF_P2PNAME_Async_Sequenced_Call(
    const char* group_name, void* param, void* data,
    void (*cb)(void* data, void* result));

/* ====================================================================== */
/* Runtime options                                                         */
/* ====================================================================== */
/*
 * A fixed-size (name, value) store. LF_SetOption updates an existing
 * entry or appends a new one; entries beyond the capacity are
 * silently dropped. LF_GetOption returns the stored value, or a
 * pointer to a static "" for an unknown name.
 *
 * The returned pointer is valid until the next LF_SetOption call for
 * the same name. Callers that need to retain the value should copy
 * it immediately; lf_shim.c already does so via its thread-local
 * buffer.
 */

MOCK_LF_API void        LF_SetOption(const char* name, const char* value);
MOCK_LF_API const char* LF_GetOption(const char* name);

/* ====================================================================== */
/* Test drivers - App-bound                                                */
/* ====================================================================== */

MOCK_LF_API void mock_lf_trigger_call(
    const char* api_name,
    const void* input_bytes, size_t input_len,
    void*       output_buf,  size_t output_cap,
    size_t*     out_written);

MOCK_LF_API void mock_lf_trigger_notify(
    const char* api_name,
    const void* input_bytes, size_t input_len);

/* ====================================================================== */
/* Test drivers - process-wide P2P                                         */
/* ====================================================================== */

MOCK_LF_API void mock_lf_trigger_p2p_call(
    const char* api_name,
    const void* input_bytes, size_t input_len,
    void*       output_buf,  size_t output_cap,
    size_t*     out_written);

MOCK_LF_API void mock_lf_trigger_p2p_notify(
    const char* api_name,
    const void* input_bytes, size_t input_len);

/* ====================================================================== */
/* Test drivers - network events                                           */
/* ====================================================================== */

MOCK_LF_API void mock_lf_trigger_network_event(
    int         is_connect,
    const char* addr);

/* ====================================================================== */
/* Test drivers - async result                                             */
/* ====================================================================== */
/*
 * Look up the pending async operation by user_token, construct a
 * result data handle carrying the supplied bytes, invoke the stored
 * trampoline on a fresh native thread, and free the handle.
 *
 * When no entry matches the token, the call is a no-op. This lets
 * tests deliberately let a token time out.
 *
 * Multiple invocations with the same token are allowed: each one
 * re-invokes the trampoline with a fresh result handle. This is used
 * by tests that exercise late / duplicate results.
 */

MOCK_LF_API void mock_lf_trigger_async_result(
    int64_t     user_token,
    const void* result_bytes, size_t result_len);

#ifdef __cplusplus
}
#endif

#endif /* MOCK_LF_H */