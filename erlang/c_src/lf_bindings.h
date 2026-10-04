/*
 * lf_bindings.h
 *
 * Type definitions for the 37 LingoFuse C ABI exports.
 *
 * This header is a pure declaration file. It defines:
 *   - Opaque handle types (TDataHnd, TAppHnd).
 *   - Callback prototypes (LF_CallFunc, LF_NotifyFunc, LF_NetworkEventFunc).
 *   - Function-pointer typedefs for every exported LF_* function.
 *   - An aggregated LF_Bindings struct that holds all 37 pointers.
 *
 * No function is actually called from this file. The pointers are
 * populated at runtime by lf_loader.c, which resolves each symbol from
 * the platform-specific LingoFuse shared library.
 *
 * The 37 exports are grouped exactly as in LingoFuse.h:
 *   - Data handle operations         (10)
 *   - Application handle operations  (5)
 *   - API registration               (3)
 *   - Local execution                (2)
 *   - Network preparation            (5)
 *   - Remote invocation              (3)
 *   - Options and diagnostics        (7)
 *   - Shutdown                       (1)
 *   - Network events                 (1)
 */

#ifndef LF_BINDINGS_H
#define LF_BINDINGS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Calling convention
 *
 * LingoFuse uses the C calling convention (cdecl) on every platform.
 * On Windows, __cdecl must be spelled explicitly; on other platforms,
 * the macro expands to nothing.
 * ============================================================================ */

#if defined(_WIN32)
#  define LF_CDECL __cdecl
#else
#  define LF_CDECL
#endif

/* ============================================================================
 * Opaque handle types
 *
 * Both handles are raw pointers. They must NEVER be dereferenced by
 * user code; all access goes through the LF_* functions.
 * ============================================================================ */

typedef void* TDataHnd;
typedef void* TAppHnd;

/* ============================================================================
 * Callback prototypes
 *
 * All three callback types MUST use the cdecl calling convention. A
 * mismatch corrupts the stack when the native library invokes them.
 * ============================================================================ */

typedef void (LF_CDECL *LF_CallFunc)(void* Trigger, TDataHnd Input, TDataHnd Output);
typedef void (LF_CDECL *LF_NotifyFunc)(void* Trigger, TDataHnd Input);
typedef void (LF_CDECL *LF_NetworkEventFunc)(const char* addr_);

/* ============================================================================
 * Data handle operations (10)
 * ============================================================================ */

typedef TDataHnd (LF_CDECL *LF_CreateData_fn)(const char* method_name);
typedef TDataHnd (LF_CDECL *LF_CreateData_Permanent_fn)(const char* method_name);
typedef void     (LF_CDECL *LF_FreeData_fn)(TDataHnd hnd);
typedef void*    (LF_CDECL *LF_GetBuffer_fn)(TDataHnd hnd);
typedef int64_t  (LF_CDECL *LF_WriteBuffer_fn)(TDataHnd hnd, const void* buff, int64_t size);
typedef int64_t  (LF_CDECL *LF_ReadBuffer_fn)(TDataHnd hnd, void* buff, int64_t size);
typedef int64_t  (LF_CDECL *LF_GetPos_fn)(TDataHnd hnd);
typedef void     (LF_CDECL *LF_SetPos_fn)(TDataHnd hnd, int64_t pos);
typedef int64_t  (LF_CDECL *LF_GetSize_fn)(TDataHnd hnd);
typedef void     (LF_CDECL *LF_SetSize_fn)(TDataHnd hnd, int64_t size);

/* ============================================================================
 * Application handle operations (5)
 * ============================================================================ */

typedef TAppHnd     (LF_CDECL *LF_CreateApp_fn)(const char* app_name, const char* desc);
typedef void        (LF_CDECL *LF_FreeApp_fn)(TAppHnd app_hnd);
typedef const char* (LF_CDECL *LF_Generate_AppName_fn)(void);
typedef const char* (LF_CDECL *LF_Get_AppName_fn)(TAppHnd app_hnd);
typedef int         (LF_CDECL *LF_BindApp_fn)(TAppHnd app_hnd);

/* ============================================================================
 * API registration (3)
 * ============================================================================ */

typedef int (LF_CDECL *LF_RegisterCall_fn)(TAppHnd app_hnd,
                                           const char* method_name,
                                           const char* desc,
                                           void* trigger,
                                           LF_CallFunc on_call);

typedef int (LF_CDECL *LF_RegisterNotify_fn)(TAppHnd app_hnd,
                                             const char* method_name,
                                             const char* desc,
                                             void* trigger,
                                             LF_NotifyFunc on_notify);

typedef int (LF_CDECL *LF_Unregister_fn)(TAppHnd app_hnd,
                                         const char* method_name);

/* ============================================================================
 * Local execution (2)
 * ============================================================================ */

typedef TDataHnd (LF_CDECL *LF_LocalCall_fn)(TAppHnd app_hnd, TDataHnd param);
typedef void     (LF_CDECL *LF_LocalNotify_fn)(TAppHnd app_hnd, TDataHnd param);

/* ============================================================================
 * Network preparation (5)
 * ============================================================================ */

typedef void (LF_CDECL *LF_ResetPrepare_fn)(void);
typedef int  (LF_CDECL *LF_PrepareService_fn)(const char* listening_addr,
                                              const char* physics_addr);
typedef int  (LF_CDECL *LF_PrepareClient_fn)(const char* physics_addr,
                                             TAppHnd app_hnd);
typedef int  (LF_CDECL *LF_PrepareDone_fn)(void);
typedef void (LF_CDECL *LF_ExitMainThread_fn)(void);

/* ============================================================================
 * Remote invocation (3)
 * ============================================================================ */

typedef TDataHnd (LF_CDECL *LF_Call_fn)(const char* app_name,
                                        TDataHnd param,
                                        uint64_t timeout_ms);
typedef void     (LF_CDECL *LF_Notify_fn)(const char* app_name, TDataHnd param);
typedef void     (LF_CDECL *LF_Sequenced_Notify_fn)(const char* app_name,
                                                    TDataHnd param);

/* ============================================================================
 * Options and diagnostics (7)
 * ============================================================================ */

typedef void        (LF_CDECL *LF_SetOption_fn)(const char* option, const char* value);
typedef int         (LF_CDECL *LF_GetStatusCount_fn)(void);
typedef const char* (LF_CDECL *LF_GetStatus_fn)(void);
typedef void        (LF_CDECL *LF_PostStatus_fn)(const char* status);
typedef int         (LF_CDECL *LF_CheckMainThread_fn)(void);
typedef int         (LF_CDECL *LF_CheckApp_fn)(const char* app_name);
typedef int         (LF_CDECL *LF_CheckApi_fn)(const char* app_name,
                                               const char* api_name);

/* ============================================================================
 * Shutdown (1)
 * ============================================================================ */

typedef void (LF_CDECL *LF_Shutdown_fn)(void);

/* ============================================================================
 * Network events (1)
 * ============================================================================ */

typedef void (LF_CDECL *LF_Set_Network_Event_fn)(LF_NetworkEventFunc on_connect,
                                                 LF_NetworkEventFunc on_disconnect);

/* ============================================================================
 * Aggregated function pointer table
 *
 * This struct is populated exactly once, at the first successful load
 * of the LingoFuse shared library. After that it is read-only and may
 * be shared across any number of threads.
 * ============================================================================ */

typedef struct LF_Bindings {
    /* Data handle (10) */
    LF_CreateData_fn            LF_CreateData;
    LF_CreateData_Permanent_fn  LF_CreateData_Permanent;
    LF_FreeData_fn              LF_FreeData;
    LF_GetBuffer_fn             LF_GetBuffer;
    LF_WriteBuffer_fn           LF_WriteBuffer;
    LF_ReadBuffer_fn            LF_ReadBuffer;
    LF_GetPos_fn                LF_GetPos;
    LF_SetPos_fn                LF_SetPos;
    LF_GetSize_fn               LF_GetSize;
    LF_SetSize_fn               LF_SetSize;

    /* Application handle (5) */
    LF_CreateApp_fn             LF_CreateApp;
    LF_FreeApp_fn               LF_FreeApp;
    LF_Generate_AppName_fn      LF_Generate_AppName;
    LF_Get_AppName_fn           LF_Get_AppName;
    LF_BindApp_fn               LF_BindApp;

    /* API registration (3) */
    LF_RegisterCall_fn          LF_RegisterCall;
    LF_RegisterNotify_fn        LF_RegisterNotify;
    LF_Unregister_fn            LF_Unregister;

    /* Local execution (2) */
    LF_LocalCall_fn             LF_LocalCall;
    LF_LocalNotify_fn           LF_LocalNotify;

    /* Network preparation (5) */
    LF_ResetPrepare_fn          LF_ResetPrepare;
    LF_PrepareService_fn        LF_PrepareService;
    LF_PrepareClient_fn         LF_PrepareClient;
    LF_PrepareDone_fn           LF_PrepareDone;
    LF_ExitMainThread_fn        LF_ExitMainThread;

    /* Remote invocation (3) */
    LF_Call_fn                  LF_Call;
    LF_Notify_fn                LF_Notify;
    LF_Sequenced_Notify_fn      LF_Sequenced_Notify;

    /* Options and diagnostics (7) */
    LF_SetOption_fn             LF_SetOption;
    LF_GetStatusCount_fn        LF_GetStatusCount;
    LF_GetStatus_fn             LF_GetStatus;
    LF_PostStatus_fn            LF_PostStatus;
    LF_CheckMainThread_fn       LF_CheckMainThread;
    LF_CheckApp_fn              LF_CheckApp;
    LF_CheckApi_fn              LF_CheckApi;

    /* Shutdown (1) */
    LF_Shutdown_fn              LF_Shutdown;

    /* Network events (1) */
    LF_Set_Network_Event_fn     LF_Set_Network_Event;
} LF_Bindings;

/* Number of exports expected to be resolved. Used as a defensive check
 * during load: if a future version of the header adds a field, this
 * constant is updated in the same change. */
#define LF_BINDINGS_COUNT 37

#ifdef __cplusplus
}
#endif

#endif /* LF_BINDINGS_H */