library LingoFuse;

{$I ..\pascal\zNetV2\source\Z.Define.inc}

uses
  mimalloc4p,
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Z.LingoFuse_Export;

exports
  // ---- Data handles ---------------------------------------------------------
  LF_CreateData,
  LF_CreateData_Permanent,
  LF_FreeData,
  LF_GetBuffer,
  LF_WriteBuffer,
  LF_ReadBuffer,
  LF_GetPos,
  LF_SetPos,
  LF_GetSize,
  LF_SetSize,
  LF_Get_P2P_UID,
  LF_Get_P2P_Name,

  // ---- Application handles --------------------------------------------------
  LF_CreateApp,
  LF_FreeApp,
  LF_Generate_AppName,
  LF_Get_AppName,
  LF_BindApp,

  // ---- API registration (app-bound) -----------------------------------------
  LF_RegisterCall,
  LF_RegisterNotify,
  LF_Unregister,

  // ---- API registration (process-wide P2P) ----------------------------------
  LF_Register_P2P_Call,
  LF_Register_P2P_Notify,
  LF_Unregister_P2P,

  // ---- Local execution ------------------------------------------------------
  LF_LocalCall,
  LF_LocalNotify,

  // ---- Network preparation --------------------------------------------------
  LF_PrepareService,
  LF_PrepareClient,
  LF_ResetPrepare,
  LF_PrepareDone,
  LF_ExitMainThread,

  // ---- Remote invocation by app name ----------------------------------------
  LF_Call,
  LF_Async_Call,
  LF_Async_Sequenced_Call,
  LF_Notify,
  LF_Sequenced_Notify,

  // ---- Remote invocation by UID ---------------------------------------------
  LF_UID_Call,
  LF_UID_Async_Call,
  LF_UID_Async_Sequenced_Call,
  LF_UID_Notify,
  LF_UID_Sequenced_Notify,

  // ---- Remote invocation by P2P name ----------------------------------------
  LF_P2PNAME_Call,
  LF_P2PNAME_Async_Call,
  LF_P2PNAME_Async_Sequenced_Call,
  LF_P2PNAME_Notify,
  LF_P2PNAME_Sequenced_Notify,

  // ---- Health checks --------------------------------------------------------
  LF_CheckMainThread,
  LF_CheckApp,
  LF_CheckApi,
  LF_Check_UID,
  LF_Check_UID_Api,
  LF_Check_P2PNAME,
  LF_Check_P2PNAME_Api,

  // ---- Runtime options ------------------------------------------------------
  LF_SetOption,
  LF_GetOption,

  // ---- Status / diagnostics -------------------------------------------------
  LF_GetStatusCount,
  LF_GetStatus,
  LF_PostStatus,

  // ---- Network events -------------------------------------------------------
  LF_Set_Network_Event,

  // ---- Shutdown -------------------------------------------------------------
  LF_Shutdown;

begin
end.
