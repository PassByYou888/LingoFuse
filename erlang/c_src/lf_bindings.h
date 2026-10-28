#ifndef LF_BINDINGS_H
#define LF_BINDINGS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  define LF_CDECL __cdecl
#else
#  define LF_CDECL
#endif

typedef void* TDataHnd;
typedef void* TAppHnd;

typedef struct TP2P_UID_s {
    uint8_t bytes[32];
} TP2P_UID;

typedef void (LF_CDECL *LF_CallFunc)(void* Trigger, TDataHnd Input, TDataHnd Output);
typedef void (LF_CDECL *LF_NotifyFunc)(void* Trigger, TDataHnd Input);
typedef void (LF_CDECL *LF_NetworkEventFunc)(const char* addr_);
typedef void (LF_CDECL *LF_AsyncCallOnResult)(void* data, TDataHnd result);

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
typedef const TP2P_UID* (LF_CDECL *LF_Get_P2P_UID_fn)(TDataHnd hnd);
typedef const char* (LF_CDECL *LF_Get_P2P_Name_fn)(TDataHnd hnd);

typedef TAppHnd     (LF_CDECL *LF_CreateApp_fn)(const char* app_name, const char* desc);
typedef void        (LF_CDECL *LF_FreeApp_fn)(TAppHnd app_hnd);
typedef const char* (LF_CDECL *LF_Generate_AppName_fn)(void);
typedef const char* (LF_CDECL *LF_Get_AppName_fn)(TAppHnd app_hnd);
typedef int         (LF_CDECL *LF_BindApp_fn)(TAppHnd app_hnd);

typedef int (LF_CDECL *LF_RegisterCall_fn)(TAppHnd app_hnd, const char* method_name, const char* desc, void* trigger, LF_CallFunc on_call);
typedef int (LF_CDECL *LF_RegisterNotify_fn)(TAppHnd app_hnd, const char* method_name, const char* desc, void* trigger, LF_NotifyFunc on_notify);
typedef int (LF_CDECL *LF_Unregister_fn)(TAppHnd app_hnd, const char* method_name);

typedef int (LF_CDECL *LF_Register_P2P_Call_fn)(const char* method_name, const char* desc, void* trigger, LF_CallFunc on_call);
typedef int (LF_CDECL *LF_Register_P2P_Notify_fn)(const char* method_name, const char* desc, void* trigger, LF_NotifyFunc on_notify);
typedef int (LF_CDECL *LF_Unregister_P2P_fn)(const char* method_name);

typedef TDataHnd (LF_CDECL *LF_LocalCall_fn)(TAppHnd app_hnd, TDataHnd param);
typedef void     (LF_CDECL *LF_LocalNotify_fn)(TAppHnd app_hnd, TDataHnd param);

typedef void (LF_CDECL *LF_ResetPrepare_fn)(void);
typedef int  (LF_CDECL *LF_PrepareService_fn)(const char* listening_addr, const char* physics_addr);
typedef int  (LF_CDECL *LF_PrepareClient_fn)(const char* physics_addr, TAppHnd app_hnd);
typedef int  (LF_CDECL *LF_PrepareDone_fn)(void);
typedef void (LF_CDECL *LF_ExitMainThread_fn)(void);

typedef TDataHnd (LF_CDECL *LF_Call_fn)(const char* app_name, TDataHnd param, uint64_t timeout_ms);
typedef int      (LF_CDECL *LF_Async_Call_fn)(const char* app_name, TDataHnd param, void* data, LF_AsyncCallOnResult on_result);
typedef int      (LF_CDECL *LF_Async_Sequenced_Call_fn)(const char* app_name, TDataHnd param, void* data, LF_AsyncCallOnResult on_result);
typedef void     (LF_CDECL *LF_Notify_fn)(const char* app_name, TDataHnd param);
typedef void     (LF_CDECL *LF_Sequenced_Notify_fn)(const char* app_name, TDataHnd param);

typedef TDataHnd (LF_CDECL *LF_UID_Call_fn)(TP2P_UID uid, TDataHnd param, uint64_t timeout_ms);
typedef int      (LF_CDECL *LF_UID_Async_Call_fn)(TP2P_UID uid, TDataHnd param, void* data, LF_AsyncCallOnResult on_result);
typedef int      (LF_CDECL *LF_UID_Async_Sequenced_Call_fn)(TP2P_UID uid, TDataHnd param, void* data, LF_AsyncCallOnResult on_result);
typedef void     (LF_CDECL *LF_UID_Notify_fn)(TP2P_UID uid, TDataHnd param);
typedef void     (LF_CDECL *LF_UID_Sequenced_Notify_fn)(TP2P_UID uid, TDataHnd param);

typedef TDataHnd (LF_CDECL *LF_P2PNAME_Call_fn)(const char* p2p_name, TDataHnd param, uint64_t timeout_ms);
typedef int      (LF_CDECL *LF_P2PNAME_Async_Call_fn)(const char* p2p_name, TDataHnd param, void* data, LF_AsyncCallOnResult on_result);
typedef int      (LF_CDECL *LF_P2PNAME_Async_Sequenced_Call_fn)(const char* p2p_name, TDataHnd param, void* data, LF_AsyncCallOnResult on_result);
typedef void     (LF_CDECL *LF_P2PNAME_Notify_fn)(const char* p2p_name, TDataHnd param);
typedef void     (LF_CDECL *LF_P2PNAME_Sequenced_Notify_fn)(const char* p2p_name, TDataHnd param);

typedef int (LF_CDECL *LF_CheckMainThread_fn)(void);
typedef int (LF_CDECL *LF_CheckApp_fn)(const char* app_name);
typedef int (LF_CDECL *LF_CheckApi_fn)(const char* app_name, const char* api_name);
typedef int (LF_CDECL *LF_Check_UID_fn)(TP2P_UID uid);
typedef int (LF_CDECL *LF_Check_UID_Api_fn)(TP2P_UID uid, const char* api_name);
typedef int (LF_CDECL *LF_Check_P2PNAME_fn)(const char* p2p_name);
typedef int (LF_CDECL *LF_Check_P2PNAME_Api_fn)(const char* p2p_name, const char* api_name);

typedef void        (LF_CDECL *LF_SetOption_fn)(const char* option, const char* value);
typedef const char* (LF_CDECL *LF_GetOption_fn)(const char* option);

typedef int         (LF_CDECL *LF_GetStatusCount_fn)(void);
typedef const char* (LF_CDECL *LF_GetStatus_fn)(void);
typedef void        (LF_CDECL *LF_PostStatus_fn)(const char* status);

typedef void (LF_CDECL *LF_Set_Network_Event_fn)(LF_NetworkEventFunc on_connect, LF_NetworkEventFunc on_disconnect);

typedef void (LF_CDECL *LF_Shutdown_fn)(void);

typedef const TP2P_UID* (LF_CDECL *LF_Get_Self_UID_fn)(void);

typedef struct LF_Bindings {
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

    LF_CreateApp_fn              LF_CreateApp;
    LF_FreeApp_fn                LF_FreeApp;
    LF_Generate_AppName_fn       LF_Generate_AppName;
    LF_Get_AppName_fn            LF_Get_AppName;
    LF_BindApp_fn                LF_BindApp;

    LF_RegisterCall_fn           LF_RegisterCall;
    LF_RegisterNotify_fn         LF_RegisterNotify;
    LF_Unregister_fn             LF_Unregister;

    LF_Register_P2P_Call_fn      LF_Register_P2P_Call;
    LF_Register_P2P_Notify_fn    LF_Register_P2P_Notify;
    LF_Unregister_P2P_fn         LF_Unregister_P2P;

    LF_LocalCall_fn              LF_LocalCall;
    LF_LocalNotify_fn            LF_LocalNotify;

    LF_ResetPrepare_fn           LF_ResetPrepare;
    LF_PrepareService_fn         LF_PrepareService;
    LF_PrepareClient_fn          LF_PrepareClient;
    LF_PrepareDone_fn            LF_PrepareDone;
    LF_ExitMainThread_fn         LF_ExitMainThread;

    LF_Call_fn                   LF_Call;
    LF_Async_Call_fn             LF_Async_Call;
    LF_Async_Sequenced_Call_fn   LF_Async_Sequenced_Call;
    LF_Notify_fn                 LF_Notify;
    LF_Sequenced_Notify_fn       LF_Sequenced_Notify;

    LF_UID_Call_fn               LF_UID_Call;
    LF_UID_Async_Call_fn         LF_UID_Async_Call;
    LF_UID_Async_Sequenced_Call_fn LF_UID_Async_Sequenced_Call;
    LF_UID_Notify_fn             LF_UID_Notify;
    LF_UID_Sequenced_Notify_fn   LF_UID_Sequenced_Notify;

    LF_P2PNAME_Call_fn           LF_P2PNAME_Call;
    LF_P2PNAME_Async_Call_fn     LF_P2PNAME_Async_Call;
    LF_P2PNAME_Async_Sequenced_Call_fn LF_P2PNAME_Async_Sequenced_Call;
    LF_P2PNAME_Notify_fn         LF_P2PNAME_Notify;
    LF_P2PNAME_Sequenced_Notify_fn LF_P2PNAME_Sequenced_Notify;

    LF_CheckMainThread_fn        LF_CheckMainThread;
    LF_CheckApp_fn               LF_CheckApp;
    LF_CheckApi_fn               LF_CheckApi;
    LF_Check_UID_fn              LF_Check_UID;
    LF_Check_UID_Api_fn          LF_Check_UID_Api;
    LF_Check_P2PNAME_fn          LF_Check_P2PNAME;
    LF_Check_P2PNAME_Api_fn      LF_Check_P2PNAME_Api;

    LF_SetOption_fn              LF_SetOption;
    LF_GetOption_fn              LF_GetOption;

    LF_GetStatusCount_fn         LF_GetStatusCount;
    LF_GetStatus_fn              LF_GetStatus;
    LF_PostStatus_fn             LF_PostStatus;

    LF_Set_Network_Event_fn      LF_Set_Network_Event;

    LF_Shutdown_fn               LF_Shutdown;

    LF_Get_Self_UID_fn           LF_Get_Self_UID;
} LF_Bindings;

#define LF_BINDINGS_REQUIRED_COUNT 59
#define LF_BINDINGS_TOTAL_COUNT    60

#ifdef __cplusplus
}
#endif

#endif