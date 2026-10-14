/*
 * lf_bindings.h
 *
 * Type definitions for the 59 LingoFuse C ABI exports.
 *
 * This header is a pure declaration file. It defines:
 *   - Opaque handle types (TDataHnd, TAppHnd).
 *   - The UID value type (TP2P_UID, 32 bytes).
 *   - Callback prototypes (LF_CallFunc, LF_NotifyFunc,
 *     LF_NetworkEventFunc, LF_AsyncCallOnResult).
 *   - Function-pointer typedefs for every exported LF_* function.
 *   - An aggregated LF_Bindings struct that holds all 59 pointers.
 *
 * No function is actually called from this file. The pointers are
 * populated at runtime by lf_loader.c, which resolves each symbol
 * from the platform-specific LingoFuse shared library.
 *
 * The 59 exports are grouped exactly as in LingoFuse.h:
 *   - Data handle operations           (12)
 *   - Application handle operations    ( 5)
 *   - API registration, app-bound      ( 3)
 *   - API registration, process-wide   ( 3)
 *   - Local execution                  ( 2)
 *   - Network preparation              ( 5)
 *   - Remote invocation, app name      ( 5)
 *   - Remote invocation, UID           ( 5)
 *   - Remote invocation, P2P name      ( 5)
 *   - Queries                          ( 7)
 *   - Options                          ( 2)
 *   - Status and diagnostics           ( 3)
 *   - Network events                   ( 1)
 *   - Shutdown                         ( 1)
 *
 * ----------------------------------------------------------------------------
 * UID TYPE (TP2P_UID)
 * ----------------------------------------------------------------------------
 * The Pascal-side type is `array[0..31] of Byte`. In C there are no
 * function-returnable arrays, so the 32-byte value is wrapped in a
 * struct.
 *
 * The SAME Pascal type plays TWO different roles on the C ABI, and
 * each role uses a different representation:
 *
 *   ROLE 1 -- ARGUMENT (input position).
 *     Functions such as LF_UID_Call, LF_UID_Notify, LF_Check_UID, and
 *     LF_Check_UID_Api take a 32-byte UID BY VALUE. The C type used
 *     for these parameters is `TP2P_UID` (the struct).
 *
 *     ABI NOTE: On x86-64 (System V AMD64 and Microsoft x64), a
 *     >16-byte aggregate is classified MEMORY by the psABI and is
 *     therefore passed on the stack (as an argument). FPC's
 *     `array[0..31] of Byte` falls into the same MEMORY class, so a
 *     struct with a single 32-byte array member is ABI-compatible.
 *
 *   ROLE 2 -- RETURN VALUE (only LF_Get_P2P_UID).
 *     LF_Get_P2P_UID does NOT return a 32-byte UID by value. It
 *     returns a POINTER to a 32-byte UID. The C type used for this
 *     return is `const TP2P_UID*`.
 *
 *     The pointer is allocated by the C side and scheduled for
 *     automatic release about 5 seconds after the call. Callers MUST:
 *       1. Copy the 32 bytes IMMEDIATELY if they want to retain them.
 *       2. NOT call any deallocation function on the pointer.
 *       3. NOT retain the pointer beyond the ~5-second window.
 *
 * Do NOT unify these two roles. They are different positions in the
 * ABI and must be represented differently.
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
 * UID value type
 *
 * The 32 bytes are exposed as the `bytes` field. A zero-filled value
 * is the "null UID", which the framework returns when identity is
 * unavailable (for example, when reading from a non-input handle).
 * ============================================================================ */

typedef struct TP2P_UID_s {
    uint8_t bytes[32];
} TP2P_UID;

/* ============================================================================
 * Callback prototypes
 *
 * All callback types MUST use the cdecl calling convention. A
 * mismatch corrupts the stack when the native library invokes them.
 *
 * All callbacks run on a native worker thread owned by LingoFuse, NOT
 * on the BEAM scheduler thread. The only thread-safe BEAM call
 * available inside such a callback is enif_send with a NULL first
 * argument.
 * ============================================================================ */

typedef void (LF_CDECL *LF_CallFunc)(void* Trigger,
                                     TDataHnd Input,
                                     TDataHnd Output);

typedef void (LF_CDECL *LF_NotifyFunc)(void* Trigger,
                                       TDataHnd Input);

typedef void (LF_CDECL *LF_NetworkEventFunc)(const char* addr_);

/* Asynchronous result callback.
 *
 * Parameters:
 *   data   -- the opaque pointer the caller passed at the call site.
 *             The library neither owns nor frees it.
 *   result -- a TDataHnd OWNED BY THE FRAMEWORK. It is released
 *             IMMEDIATELY after this callback returns.
 *
 * The callback MUST:
 *   - read or copy everything it needs inside the body,
 *   - NOT call LF_FreeData on `result`,
 *   - NOT retain the pointer past its own return.
 *
 * Execution context: TCompute worker thread. The callback MUST NOT
 * block, and MUST NOT call any synchronous LingoFuse function.
 */
typedef void (LF_CDECL *LF_AsyncCallOnResult)(void* data, TDataHnd result);

/* ============================================================================
 * Data handle operations (12)
 * ============================================================================ */

typedef TDataHnd (LF_CDECL *LF_CreateData_fn)(const char* method_name);
typedef TDataHnd (LF_CDECL *LF_CreateData_Permanent_fn)(const char* method_name);
typedef void     (LF_CDECL *LF_FreeData_fn)(TDataHnd hnd);
typedef void*    (LF_CDECL *LF_GetBuffer_fn)(TDataHnd hnd);
typedef int64_t  (LF_CDECL *LF_WriteBuffer_fn)(TDataHnd hnd,
                                               const void* buff,
                                               int64_t size);
typedef int64_t  (LF_CDECL *LF_ReadBuffer_fn)(TDataHnd hnd,
                                              void* buff,
                                              int64_t size);
typedef int64_t  (LF_CDECL *LF_GetPos_fn)(TDataHnd hnd);
typedef void     (LF_CDECL *LF_SetPos_fn)(TDataHnd hnd, int64_t pos);
typedef int64_t  (LF_CDECL *LF_GetSize_fn)(TDataHnd hnd);
typedef void     (LF_CDECL *LF_SetSize_fn)(TDataHnd hnd, int64_t size);

/* RETURN-role UID: pointer to a library-owned 32-byte buffer, released
 * ~5 seconds after the call. Valid ONLY on the INPUT handle of a
 * registered callback. On any other handle it points to a zero-filled
 * UID. */
typedef const TP2P_UID* (LF_CDECL *LF_Get_P2P_UID_fn)(TDataHnd hnd);

/* RETURNS a transient NUL-terminated UTF-8 string, also released
 * ~5 seconds after the call. Same side-data contract as
 * LF_Get_P2P_UID. */
typedef const char* (LF_CDECL *LF_Get_P2P_Name_fn)(TDataHnd hnd);

/* ============================================================================
 * Application handle operations (5)
 * ============================================================================ */

typedef TAppHnd     (LF_CDECL *LF_CreateApp_fn)(const char* app_name,
                                                const char* desc);
typedef void        (LF_CDECL *LF_FreeApp_fn)(TAppHnd app_hnd);
typedef const char* (LF_CDECL *LF_Generate_AppName_fn)(void);
typedef const char* (LF_CDECL *LF_Get_AppName_fn)(TAppHnd app_hnd);
typedef int         (LF_CDECL *LF_BindApp_fn)(TAppHnd app_hnd);

/* ============================================================================
 * API registration, app-bound (3)
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
 * API registration, process-wide P2P (3)
 * ============================================================================ */

typedef int (LF_CDECL *LF_Register_P2P_Call_fn)(const char* method_name,
                                                const char* desc,
                                                void* trigger,
                                                LF_CallFunc on_call);

typedef int (LF_CDECL *LF_Register_P2P_Notify_fn)(const char* method_name,
                                                  const char* desc,
                                                  void* trigger,
                                                  LF_NotifyFunc on_notify);

typedef int (LF_CDECL *LF_Unregister_P2P_fn)(const char* method_name);

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
 * Remote invocation, app-name addressing (5)
 * ============================================================================ */

typedef TDataHnd (LF_CDECL *LF_Call_fn)(const char* app_name,
                                        TDataHnd param,
                                        uint64_t timeout_ms);

typedef int      (LF_CDECL *LF_Async_Call_fn)(const char* app_name,
                                              TDataHnd param,
                                              void* data,
                                              LF_AsyncCallOnResult on_result);

typedef int      (LF_CDECL *LF_Async_Sequenced_Call_fn)(
                     const char* app_name,
                     TDataHnd param,
                     void* data,
                     LF_AsyncCallOnResult on_result);

typedef void     (LF_CDECL *LF_Notify_fn)(const char* app_name,
                                          TDataHnd param);

typedef void     (LF_CDECL *LF_Sequenced_Notify_fn)(const char* app_name,
                                                    TDataHnd param);

/* ============================================================================
 * Remote invocation, UID addressing (5)
 *
 * The first parameter is an ARGUMENT-role UID, passed by value. See the
 * header banner for the ARGUMENT-vs-RETURN distinction.
 * ============================================================================ */

typedef TDataHnd (LF_CDECL *LF_UID_Call_fn)(TP2P_UID uid,
                                            TDataHnd param,
                                            uint64_t timeout_ms);

typedef int      (LF_CDECL *LF_UID_Async_Call_fn)(TP2P_UID uid,
                                                  TDataHnd param,
                                                  void* data,
                                                  LF_AsyncCallOnResult on_result);

typedef int      (LF_CDECL *LF_UID_Async_Sequenced_Call_fn)(
                     TP2P_UID uid,
                     TDataHnd param,
                     void* data,
                     LF_AsyncCallOnResult on_result);

typedef void     (LF_CDECL *LF_UID_Notify_fn)(TP2P_UID uid, TDataHnd param);

typedef void     (LF_CDECL *LF_UID_Sequenced_Notify_fn)(TP2P_UID uid,
                                                        TDataHnd param);

/* ============================================================================
 * Remote invocation, P2P-name addressing (5)
 * ============================================================================ */

typedef TDataHnd (LF_CDECL *LF_P2PNAME_Call_fn)(const char* p2p_name,
                                                TDataHnd param,
                                                uint64_t timeout_ms);

typedef int      (LF_CDECL *LF_P2PNAME_Async_Call_fn)(
                     const char* p2p_name,
                     TDataHnd param,
                     void* data,
                     LF_AsyncCallOnResult on_result);

typedef int      (LF_CDECL *LF_P2PNAME_Async_Sequenced_Call_fn)(
                     const char* p2p_name,
                     TDataHnd param,
                     void* data,
                     LF_AsyncCallOnResult on_result);

typedef void     (LF_CDECL *LF_P2PNAME_Notify_fn)(const char* p2p_name,
                                                  TDataHnd param);

typedef void     (LF_CDECL *LF_P2PNAME_Sequenced_Notify_fn)(
                     const char* p2p_name,
                     TDataHnd param);

/* ============================================================================
 * Queries (7)
 * ============================================================================ */

typedef int (LF_CDECL *LF_CheckMainThread_fn)(void);
typedef int (LF_CDECL *LF_CheckApp_fn)(const char* app_name);
typedef int (LF_CDECL *LF_CheckApi_fn)(const char* app_name,
                                       const char* api_name);

/* UID parameters here are ARGUMENT-role (by value). */
typedef int (LF_CDECL *LF_Check_UID_fn)(TP2P_UID uid);
typedef int (LF_CDECL *LF_Check_UID_Api_fn)(TP2P_UID uid,
                                            const char* api_name);

typedef int (LF_CDECL *LF_Check_P2PNAME_fn)(const char* p2p_name);
typedef int (LF_CDECL *LF_Check_P2PNAME_Api_fn)(const char* p2p_name,
                                                const char* api_name);

/* ============================================================================
 * Options (2)
 * ============================================================================ */

typedef void        (LF_CDECL *LF_SetOption_fn)(const char* option,
                                                const char* value);
typedef const char* (LF_CDECL *LF_GetOption_fn)(const char* option);

/* ============================================================================
 * Status and diagnostics (3)
 * ============================================================================ */

typedef int         (LF_CDECL *LF_GetStatusCount_fn)(void);
typedef const char* (LF_CDECL *LF_GetStatus_fn)(void);
typedef void        (LF_CDECL *LF_PostStatus_fn)(const char* status);

/* ============================================================================
 * Network events (1)
 * ============================================================================ */

typedef void (LF_CDECL *LF_Set_Network_Event_fn)(LF_NetworkEventFunc on_connect,
                                                 LF_NetworkEventFunc on_disconnect);

/* ============================================================================
 * Shutdown (1)
 * ============================================================================ */

typedef void (LF_CDECL *LF_Shutdown_fn)(void);

/* ============================================================================
 * Aggregated function pointer table
 *
 * This struct is populated exactly once, at the first successful load
 * of the LingoFuse shared library. After that it is read-only and may
 * be shared across any number of threads.
 *
 * Field order matches the grouping used in LingoFuse.h and in the
 * LF_RESOLVE sequence in lf_loader.c. Do not reorder without updating
 * all three in the same change.
 * ============================================================================ */

typedef struct LF_Bindings {
    /* Data handle (12) */
    LF_CreateData_fn             LF_CreateData;
    LF_CreateData_Permanent_fn   LF_CreateData_Permanent;
    LF_FreeData_fn               LF_FreeData;
    LF_GetBuffer_fn              LF_GetBuffer;
    LF_WriteBuffer_fn            LF_WriteBuffer;
    LF_ReadBuffer_fn             LF_ReadBuffer;
    LF_GetPos_fn                 LF_GetPos;
    LF_SetPos_fn                 LF_SetPos;
    LF_GetSize_fn                LF_GetSize;
    LF_SetSize_fn                LF_SetSize;
    LF_Get_P2P_UID_fn            LF_Get_P2P_UID;
    LF_Get_P2P_Name_fn           LF_Get_P2P_Name;

    /* Application handle (5) */
    LF_CreateApp_fn              LF_CreateApp;
    LF_FreeApp_fn                LF_FreeApp;
    LF_Generate_AppName_fn       LF_Generate_AppName;
    LF_Get_AppName_fn            LF_Get_AppName;
    LF_BindApp_fn                LF_BindApp;

    /* API registration, app-bound (3) */
    LF_RegisterCall_fn           LF_RegisterCall;
    LF_RegisterNotify_fn         LF_RegisterNotify;
    LF_Unregister_fn             LF_Unregister;

    /* API registration, process-wide P2P (3) */
    LF_Register_P2P_Call_fn      LF_Register_P2P_Call;
    LF_Register_P2P_Notify_fn    LF_Register_P2P_Notify;
    LF_Unregister_P2P_fn         LF_Unregister_P2P;

    /* Local execution (2) */
    LF_LocalCall_fn              LF_LocalCall;
    LF_LocalNotify_fn            LF_LocalNotify;

    /* Network preparation (5) */
    LF_ResetPrepare_fn           LF_ResetPrepare;
    LF_PrepareService_fn         LF_PrepareService;
    LF_PrepareClient_fn          LF_PrepareClient;
    LF_PrepareDone_fn            LF_PrepareDone;
    LF_ExitMainThread_fn         LF_ExitMainThread;

    /* Remote invocation, app name (5) */
    LF_Call_fn                   LF_Call;
    LF_Async_Call_fn             LF_Async_Call;
    LF_Async_Sequenced_Call_fn   LF_Async_Sequenced_Call;
    LF_Notify_fn                 LF_Notify;
    LF_Sequenced_Notify_fn       LF_Sequenced_Notify;

    /* Remote invocation, UID (5) */
    LF_UID_Call_fn               LF_UID_Call;
    LF_UID_Async_Call_fn         LF_UID_Async_Call;
    LF_UID_Async_Sequenced_Call_fn
                                 LF_UID_Async_Sequenced_Call;
    LF_UID_Notify_fn             LF_UID_Notify;
    LF_UID_Sequenced_Notify_fn   LF_UID_Sequenced_Notify;

    /* Remote invocation, P2P name (5) */
    LF_P2PNAME_Call_fn           LF_P2PNAME_Call;
    LF_P2PNAME_Async_Call_fn     LF_P2PNAME_Async_Call;
    LF_P2PNAME_Async_Sequenced_Call_fn
                                 LF_P2PNAME_Async_Sequenced_Call;
    LF_P2PNAME_Notify_fn         LF_P2PNAME_Notify;
    LF_P2PNAME_Sequenced_Notify_fn
                                 LF_P2PNAME_Sequenced_Notify;

    /* Queries (7) */
    LF_CheckMainThread_fn        LF_CheckMainThread;
    LF_CheckApp_fn               LF_CheckApp;
    LF_CheckApi_fn               LF_CheckApi;
    LF_Check_UID_fn              LF_Check_UID;
    LF_Check_UID_Api_fn          LF_Check_UID_Api;
    LF_Check_P2PNAME_fn          LF_Check_P2PNAME;
    LF_Check_P2PNAME_Api_fn      LF_Check_P2PNAME_Api;

    /* Options (2) */
    LF_SetOption_fn              LF_SetOption;
    LF_GetOption_fn              LF_GetOption;

    /* Status and diagnostics (3) */
    LF_GetStatusCount_fn         LF_GetStatusCount;
    LF_GetStatus_fn              LF_GetStatus;
    LF_PostStatus_fn             LF_PostStatus;

    /* Network events (1) */
    LF_Set_Network_Event_fn      LF_Set_Network_Event;

    /* Shutdown (1) */
    LF_Shutdown_fn               LF_Shutdown;
} LF_Bindings;

/* Number of exports expected to be resolved. Used as a defensive check
 * during load: if a future version of the header adds a field, this
 * constant is updated in the same change, and the compiler will warn
 * if the struct size no longer matches the expected field count. */
#define LF_BINDINGS_COUNT 59

#ifdef __cplusplus
}
#endif

#endif /* LF_BINDINGS_H */