/*
 * mock_lf.h - Minimal in-memory mock of the LingoFuse C ABI.
 *
 * Purpose
 * -------
 * The real LingoFuse library cannot be exercised from a unit test
 * without a full mesh, a service endpoint, and a running node. This
 * mock provides JUST the ABI surface that lf_shim.c needs, plus
 * three test drivers that simulate the C4 worker thread by spawning
 * a real native thread and invoking the registered callback on it.
 *
 * What is mocked
 * --------------
 *   Data handles    - a heap buffer with a read/write cursor.
 *   App handles     - a heap struct carrying a name and description.
 *   Registration    - a linked list per (Call | Notify).
 *   Network events  - two function pointers.
 *   Triggers        - three driver functions (see the bottom of the file).
 *
 * What is NOT mocked
 * ------------------
 *   Any LingoFuse semantics beyond the raw ABI. No discovery, no
 *   broadcasting, no timeouts, no load balancing. This mock exists
 *   only to prove the shim's cross-thread mechanism works.
 */

#ifndef MOCK_LF_H
#define MOCK_LF_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
  #define MOCK_LF_API __declspec(dllexport)
#else
  #define MOCK_LF_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Data handle ---- */

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

/* ---- App handle ---- */

MOCK_LF_API void* LF_CreateApp(const char* app_name, const char* desc);
MOCK_LF_API void  LF_FreeApp(void* app_hnd);

/* ---- Registration ---- */

MOCK_LF_API int LF_RegisterCall(
    void* app, const char* name, const char* desc,
    void* trigger,
    void (*cb)(void* trigger, void* input, void* output));

MOCK_LF_API int LF_RegisterNotify(
    void* app, const char* name, const char* desc,
    void* trigger,
    void (*cb)(void* trigger, void* input));

MOCK_LF_API void LF_Set_Network_Event(
    void (*on_connect)(const char* addr),
    void (*on_disconnect)(const char* addr));

/* ---- Test drivers ---- */
/*
 * Each driver spawns a fresh native thread, invokes the registered
 * callback on that thread, and joins before returning. This exactly
 * matches the C4 worker-thread behaviour that the shim is designed
 * to survive.
 *
 * mock_lf_trigger_call:
 *   Looks up the Call API by name, constructs input / output data
 *   handles, spawns the worker thread, and after the join copies the
 *   output buffer into the caller's buffer.
 *
 * mock_lf_trigger_notify:
 *   Same, but no output.
 *
 * mock_lf_trigger_network_event:
 *   Invokes whichever of the two global network callbacks was
 *   requested. The address string is passed through to the callback
 *   unchanged.
 */

MOCK_LF_API void mock_lf_trigger_call(
    const char* api_name,
    const void* input_bytes, size_t input_len,
    void*       output_buf,  size_t output_cap,
    size_t*     out_written);

MOCK_LF_API void mock_lf_trigger_notify(
    const char* api_name,
    const void* input_bytes, size_t input_len);

MOCK_LF_API void mock_lf_trigger_network_event(
    int         is_connect,
    const char* addr);

#ifdef __cplusplus
}
#endif

#endif /* MOCK_LF_H */