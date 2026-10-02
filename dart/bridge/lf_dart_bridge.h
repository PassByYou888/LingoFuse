// C bridge header: exposes a synchronous callback model for Dart.

#ifndef LF_DART_BRIDGE_H_INCLUDED
#define LF_DART_BRIDGE_H_INCLUDED

#include <stdint.h>

#if defined(_WIN32)
#  ifdef LF_DART_BRIDGE_EXPORTS
#    define LF_BRIDGE_API __declspec(dllexport)
#  else
#    define LF_BRIDGE_API __declspec(dllimport)
#  endif
#  define LF_BRIDGE_CDECL __cdecl
#else
#  define LF_BRIDGE_API __attribute__((visibility("default")))
#  define LF_BRIDGE_CDECL
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Initialize the bridge.
//
// `port_id`     : native port ID obtained from a Dart ReceivePort.
// `api_dl_data` : the pointer returned by `NativeApi.initializeApiDLData`
//                 in dart:ffi. MUST be non-null. Passing NULL crashes
//                 inside `Dart_InitializeApiDL`.
//
// Returns 0 on success, -1 on failure.
LF_BRIDGE_API int LF_BRIDGE_CDECL lf_bridge_init(
    int64_t port_id,
    void* api_dl_data);

LF_BRIDGE_API int LF_BRIDGE_CDECL lf_bridge_register_call(
    void* app_hnd,
    const char* api_name,
    const char* desc,
    int64_t callback_id);

LF_BRIDGE_API int LF_BRIDGE_CDECL lf_bridge_register_notify(
    void* app_hnd,
    const char* api_name,
    const char* desc,
    int64_t callback_id);

LF_BRIDGE_API void LF_BRIDGE_CDECL lf_bridge_complete(
    int64_t request_id,
    const uint8_t* output,
    int64_t output_len);

LF_BRIDGE_API void LF_BRIDGE_CDECL lf_bridge_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif  // LF_DART_BRIDGE_H_INCLUDED