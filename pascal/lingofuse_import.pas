(* Reference: LingoFuse_Pascal_Complete_Guide.md *)

unit lingofuse_import;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$MODESWITCH AdvancedRecords}
  {$MODESWITCH NestedProcVars}
  {$MODESWITCH NESTEDCOMMENTS}
  {$CODEPAGE UTF8}
{$endif}

{$R-}{$I-}{$H+}

interface

uses SysUtils, Classes;

type
  TDataHnd___ = Pointer;
  TDataHnd = TDataHnd___;
  TAppHnd___ = Pointer;
  TAppHnd = TAppHnd___;
  TP2P_UID___ = array[0..31] of Byte;
  PP2P_UID___ = ^TP2P_UID___;
  TP2P_UID = TP2P_UID___;
  PP2P_UID = PP2P_UID___;


  TLF_Call_Event = procedure(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
  TLF_Call_M = procedure(Input: TDataHnd___; Output: TDataHnd___) of object;
  TLF_Notify_Event = procedure(Trigger: Pointer; Input: TDataHnd___); cdecl;
  TLF_Notify_M = procedure(Input: TDataHnd___) of object;
  TLF_Async_Call_OnResult = procedure(Data: Pointer; Result_: TDataHnd___); cdecl;
  TLF_Network_Event = procedure(addr_: pansichar); cdecl;

{$IFDEF FPC}
  TLF_Call_P = procedure(Input, Output: TDataHnd___) is nested;
  TLF_Notify_P = procedure(Input: TDataHnd___) is nested;
  TLF_Async_Call_P = procedure(Result_: TDataHnd___) is nested;
{$ELSE FPC}
  TLF_Call_P = reference to procedure(Input, Output: TDataHnd___);
  TLF_Notify_P = reference to procedure(Input: TDataHnd___);
  TLF_Async_Call_P = reference to procedure(Result_: TDataHnd___);
{$ENDIF FPC}

const
{$IFDEF MSWINDOWS}
  {$IF Defined(CPU64) or Defined(CPUX64)}
  liblingofuse = 'LingoFuse64.dll';
  {$ELSE}
  liblingofuse = 'LingoFuse32.dll';
  {$ENDIF}
{$ELSE}
  {$IFDEF DARWIN}
  liblingofuse = 'liblingofuse.dylib';
  {$ELSE}
  liblingofuse = 'liblingofuse.so';
  {$ENDIF}
{$ENDIF}

{ ============================================================================ }
{ Data handle                                                                  }
{ ============================================================================ }

function  LF_CreateData(MethodName: pansichar): TDataHnd___; cdecl; external liblingofuse name 'LF_CreateData';
function  LF_CreateDataEx(MethodName: string): TDataHnd___;
function  LF_CreateData_Permanent(MethodName: pansichar): TDataHnd___; cdecl; external liblingofuse name 'LF_CreateData_Permanent';
function  LF_CreateData_PermanentEx(MethodName: string): TDataHnd___;
procedure LF_FreeData(Hnd: TDataHnd___); cdecl; external liblingofuse name 'LF_FreeData';
function  LF_GetBuffer(Hnd: TDataHnd___): Pointer; cdecl; external liblingofuse name 'LF_GetBuffer';
function  LF_GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer;
function  LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl; external liblingofuse name 'LF_WriteBuffer';
function  LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl; external liblingofuse name 'LF_ReadBuffer';
function  LF_GetPos(Hnd: TDataHnd___): int64; cdecl; external liblingofuse name 'LF_GetPos';
procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64); cdecl; external liblingofuse name 'LF_SetPos';
function  LF_GetSize(Hnd: TDataHnd___): int64; cdecl; external liblingofuse name 'LF_GetSize';
procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64); cdecl; external liblingofuse name 'LF_SetSize';
function  LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___; cdecl; external liblingofuse name 'LF_Get_P2P_UID';
function  LF_Get_P2P_Name(Hnd: TDataHnd___): pansichar; cdecl; external liblingofuse name 'LF_Get_P2P_Name';
function  LF_Get_P2P_NameEx(Hnd: TDataHnd___): string;

function  LF_WriteInt8(Hnd: TDataHnd___; Value: int8): boolean;
function  LF_WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean;
function  LF_WriteInt16(Hnd: TDataHnd___; Value: int16): boolean;
function  LF_WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean;
function  LF_WriteInt32(Hnd: TDataHnd___; Value: int32): boolean;
function  LF_WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean;
function  LF_WriteInt64(Hnd: TDataHnd___; Value: int64): boolean;
function  LF_WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean;
function  LF_WriteSingle(Hnd: TDataHnd___; Value: single): boolean;
function  LF_WriteDouble(Hnd: TDataHnd___; Value: double): boolean;
function  LF_WriteString(Hnd: TDataHnd___; const Value: string): boolean;
function  LF_WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean;

function  LF_ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean; overload;
function  LF_ReadInt8(Hnd: TDataHnd___): int8; overload;
function  LF_ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean; overload;
function  LF_ReadUInt8(Hnd: TDataHnd___): uint8; overload;
function  LF_ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean; overload;
function  LF_ReadInt16(Hnd: TDataHnd___): int16; overload;
function  LF_ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean; overload;
function  LF_ReadUInt16(Hnd: TDataHnd___): uint16; overload;
function  LF_ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean; overload;
function  LF_ReadInt32(Hnd: TDataHnd___): int32; overload;
function  LF_ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean; overload;
function  LF_ReadUInt32(Hnd: TDataHnd___): uint32; overload;
function  LF_ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean; overload;
function  LF_ReadInt64(Hnd: TDataHnd___): int64; overload;
function  LF_ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean; overload;
function  LF_ReadUInt64(Hnd: TDataHnd___): uint64; overload;
function  LF_ReadSingle(Hnd: TDataHnd___; out Value: single): boolean; overload;
function  LF_ReadSingle(Hnd: TDataHnd___): single; overload;
function  LF_ReadDouble(Hnd: TDataHnd___; out Value: double): boolean; overload;
function  LF_ReadDouble(Hnd: TDataHnd___): double; overload;
function  LF_ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean; overload;
function  LF_ReadStringBytes(Hnd: TDataHnd___): TBytes; overload;
function  LF_ReadString(Hnd: TDataHnd___; out Value: string): boolean; overload;
function  LF_ReadString(Hnd: TDataHnd___): string; overload;

{ ============================================================================ }
{ App handle                                                                   }
{ ============================================================================ }

function  LF_CreateApp(appName, Desc: pansichar): TAppHnd___; cdecl; external liblingofuse name 'LF_CreateApp';
function  LF_CreateAppEx(appName, Desc: string): TAppHnd___;
procedure LF_FreeApp(appHnd: TAppHnd___); cdecl; external liblingofuse name 'LF_FreeApp';
function  LF_Generate_AppName(): pansichar; cdecl; external liblingofuse name 'LF_Generate_AppName';
function  LF_Generate_AppNameEx(): string;
function  LF_Get_AppName(appHnd: TAppHnd___): pansichar; cdecl; external liblingofuse name 'LF_Get_AppName';
function  LF_Get_AppNameEx(appHnd: TAppHnd___): string;
function  LF_BindApp(appHnd: TAppHnd___): integer; cdecl; external liblingofuse name 'LF_BindApp';

{ ============================================================================ }
{ API registration (app-bound)                                                 }
{ ============================================================================ }

function  LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer; cdecl; external liblingofuse name 'LF_RegisterCall';
function  LF_RegisterCallEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
function  LF_RegisterCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
function  LF_RegisterSyncCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
function  LF_RegisterCall_P(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_P): integer;
function  LF_RegisterSyncCall_P(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_P): integer;

function  LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer; cdecl; external liblingofuse name 'LF_RegisterNotify';
function  LF_RegisterNotifyEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
function  LF_RegisterNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
function  LF_RegisterSyncNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
function  LF_RegisterNotify_P(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
function  LF_RegisterSyncNotify_P(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;

function  LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): integer; cdecl; external liblingofuse name 'LF_Unregister';
function  LF_UnregisterEx(appHnd: TAppHnd___; MethodName: string): integer;

{ ============================================================================ }
{ API registration (process-wide P2P)                                          }
{ ============================================================================ }

function  LF_Register_P2P_Call(MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer; cdecl; external liblingofuse name 'LF_Register_P2P_Call';
function  LF_Register_P2P_CallEx(MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
function  LF_Register_P2P_Call_M(MethodName, Desc: string; OnCall: TLF_Call_M): integer;
function  LF_Register_P2P_SyncCall_M(MethodName, Desc: string; OnCall: TLF_Call_M): integer;
function  LF_Register_P2P_Call_P(MethodName, Desc: string; OnCall: TLF_Call_P): integer;
function  LF_Register_P2P_SyncCall_P(MethodName, Desc: string; OnCall: TLF_Call_P): integer;

function  LF_Register_P2P_Notify(MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer; cdecl; external liblingofuse name 'LF_Register_P2P_Notify';
function  LF_Register_P2P_NotifyEx(MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
function  LF_Register_P2P_Notify_M(MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
function  LF_Register_P2P_SyncNotify_M(MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
function  LF_Register_P2P_Notify_P(MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
function  LF_Register_P2P_SyncNotify_P(MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;

function  LF_Unregister_P2P(MethodName: pansichar): integer; cdecl; external liblingofuse name 'LF_Unregister_P2P';
function  LF_Unregister_P2PEx(MethodName: string): integer;

{ ============================================================================ }
{ Local execution                                                              }
{ ============================================================================ }

function  LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___; cdecl; external liblingofuse name 'LF_LocalCall';
procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_LocalNotify';

{ ============================================================================ }
{ Network preparation                                                          }
{ ============================================================================ }

function  LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): integer; cdecl; external liblingofuse name 'LF_PrepareService';
function  LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_: string): integer;
function  LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): integer; cdecl; external liblingofuse name 'LF_PrepareClient';
function  LF_PrepareClientEx(PhysicsAddr_: string; appHnd: TAppHnd___): integer; overload;
function  LF_PrepareClientEx(PhysicsAddr_: string): integer; overload;
procedure LF_ResetPrepare(); cdecl; external liblingofuse name 'LF_ResetPrepare';
function  LF_PrepareDone: integer; cdecl; external liblingofuse name 'LF_PrepareDone';
procedure LF_ExitMainThread; cdecl; external liblingofuse name 'LF_ExitMainThread';

{ ============================================================================ }
{ Remote invocation by app name                                                }
{ ============================================================================ }

function  LF_Call(appName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl; external liblingofuse name 'LF_Call';
function  LF_CallEx(appName: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
function  LF_Async_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; cdecl; external liblingofuse name 'LF_Async_Call';
function  LF_Async_CallEx(appName: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
function  LF_Async_Call_P(appName: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
function  LF_Async_Sequenced_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; cdecl; external liblingofuse name 'LF_Async_Sequenced_Call';
function  LF_Async_Sequenced_CallEx(appName: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
function  LF_Async_Sequenced_Call_P(appName: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
procedure LF_Notify(appName: pansichar; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_Notify';
procedure LF_NotifyEx(appName: string; Param: TDataHnd___);
procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_Sequenced_Notify';
procedure LF_Sequenced_NotifyEx(appName: string; Param: TDataHnd___);

{ ============================================================================ }
{ Remote invocation by UID                                                     }
{ ============================================================================ }

function  LF_UID_Call(UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl; external liblingofuse name 'LF_UID_Call';
function  LF_UID_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
function  LF_UID_Async_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; cdecl; external liblingofuse name 'LF_UID_Async_Call';
function  LF_UID_Async_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
function  LF_UID_Async_Call_P(const UID: TP2P_UID___; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
function  LF_UID_Async_Sequenced_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; cdecl; external liblingofuse name 'LF_UID_Async_Sequenced_Call';
function  LF_UID_Async_Sequenced_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
function  LF_UID_Async_Sequenced_Call_P(const UID: TP2P_UID___; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
procedure LF_UID_Notify(UID: TP2P_UID___; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_UID_Notify';
procedure LF_UID_NotifyEx(const UID: TP2P_UID___; Param: TDataHnd___);
procedure LF_UID_Sequenced_Notify(UID: TP2P_UID___; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_UID_Sequenced_Notify';
procedure LF_UID_Sequenced_NotifyEx(const UID: TP2P_UID___; Param: TDataHnd___);

{ ============================================================================ }
{ Remote invocation by P2P name                                                }
{ ============================================================================ }

function  LF_P2PNAME_Call(p2p_name_: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl; external liblingofuse name 'LF_P2PNAME_Call';
function  LF_P2PNAME_CallEx(p2p_name_: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
function  LF_P2PNAME_Async_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; cdecl; external liblingofuse name 'LF_P2PNAME_Async_Call';
function  LF_P2PNAME_Async_CallEx(p2p_name_: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
function  LF_P2PNAME_Async_Call_P(p2p_name_: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
function  LF_P2PNAME_Async_Sequenced_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; cdecl; external liblingofuse name 'LF_P2PNAME_Async_Sequenced_Call';
function  LF_P2PNAME_Async_Sequenced_CallEx(p2p_name_: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
function  LF_P2PNAME_Async_Sequenced_Call_P(p2p_name_: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
procedure LF_P2PNAME_Notify(p2p_name_: pansichar; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_P2PNAME_Notify';
procedure LF_P2PNAME_NotifyEx(p2p_name_: string; Param: TDataHnd___);
procedure LF_P2PNAME_Sequenced_Notify(p2p_name_: pansichar; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_P2PNAME_Sequenced_Notify';
procedure LF_P2PNAME_Sequenced_NotifyEx(p2p_name_: string; Param: TDataHnd___);

{ ============================================================================ }
{ Queries                                                                      }
{ ============================================================================ }

function  LF_CheckMainThread(): integer; cdecl; external liblingofuse name 'LF_CheckMainThread';
function  LF_CheckMainThreadEx(): boolean;
function  LF_CheckApp(appName: pansichar): integer; cdecl; external liblingofuse name 'LF_CheckApp';
function  LF_CheckAppEx(appName: string): boolean;
function  LF_CheckApi(appName, apiName: pansichar): integer; cdecl; external liblingofuse name 'LF_CheckApi';
function  LF_CheckApiEx(appName, apiName: string): boolean;
function  LF_Check_UID(UID: TP2P_UID___): integer; cdecl; external liblingofuse name 'LF_Check_UID';
function  LF_Check_UIDEx(const UID: TP2P_UID___): boolean;
function  LF_Check_UID_Api(UID: TP2P_UID___; apiName: pansichar): integer; cdecl; external liblingofuse name 'LF_Check_UID_Api';
function  LF_Check_UID_ApiEx(const UID: TP2P_UID___; apiName: string): boolean;
function  LF_Check_P2PNAME(p2p_name_: pansichar): integer; cdecl; external liblingofuse name 'LF_Check_P2PNAME';
function  LF_Check_P2PNAMEEx(p2p_name_: string): boolean;
function  LF_Check_P2PNAME_Api(p2p_name_, apiName: pansichar): integer; cdecl; external liblingofuse name 'LF_Check_P2PNAME_Api';
function  LF_Check_P2PNAME_ApiEx(p2p_name_, apiName: string): boolean;

{ ============================================================================ }
{ Options / Status                                                             }
{ ============================================================================ }

procedure LF_SetOption(Option, Value: pansichar); cdecl; external liblingofuse name 'LF_SetOption';
procedure LF_SetOptionEx(Option, Value: string);
function  LF_GetOption(Option: pansichar): pansichar; cdecl; external liblingofuse name 'LF_GetOption';
function  LF_GetOptionEx(Option: string): string;

{ ---- LF_SetOption shortcuts (v3: LF_Set_Opt_XXX) ------------------------- }
procedure LF_Set_Opt_Debug(const Value: string);
procedure LF_Set_Opt_P2P_Name(const Value: string);
procedure LF_Set_Opt_Password(const Value: string);
procedure LF_Set_Opt_Quiet(const Value: Boolean);
procedure LF_Set_Opt_Overlap_Connection(const Value: Boolean);
procedure LF_Set_Opt_Wait_Connection_ReadyOk(const Value: Boolean);
procedure LF_Set_Opt_Wait_Connection_Timeout(const Value: uint64);
procedure LF_Set_Opt_ShowThreadID(const Value: Boolean);
procedure LF_Set_Opt_ConsoleOutput(const Value: Boolean);
procedure LF_Set_Opt_IPC_Serv_ThreadCount(const Value: Integer);
procedure LF_Set_Opt_IPC_Serv_MaxQueueLength(const Value: Integer);
procedure LF_Set_Opt_IPC_Serv_MaxMsgSize(const Value: Integer);
procedure LF_Set_Opt_Fixed_Sequenced_Time(const Value: uint64);
procedure LF_Set_Opt_DataHandle_Idle_Timeout(const Value: uint64);
procedure LF_Set_Opt_DataHandle_Pool_Scan_Interval(const Value: uint64);
procedure LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(const Value: Integer);

{ ---- LF_GetOption shortcuts (v3: LF_Get_Opt_XXX) ------------------------- }
function LF_Get_Opt_Debug: string;
function LF_Get_Opt_P2P_Name: string;
function LF_Get_Opt_Password: string;
function LF_Get_Opt_Quiet: Boolean;
function LF_Get_Opt_Overlap_Connection: Boolean;
function LF_Get_Opt_Wait_Connection_ReadyOk: Boolean;
function LF_Get_Opt_Wait_Connection_Timeout: uint64;
function LF_Get_Opt_ShowThreadID: Boolean;
function LF_Get_Opt_ConsoleOutput: Boolean;
function LF_Get_Opt_IPC_Serv_ThreadCount: Integer;
function LF_Get_Opt_IPC_Serv_MaxQueueLength: Integer;
function LF_Get_Opt_IPC_Serv_MaxMsgSize: Integer;
function LF_Get_Opt_Fixed_Sequenced_Time: uint64;
function LF_Get_Opt_DataHandle_Idle_Timeout: uint64;
function LF_Get_Opt_DataHandle_Pool_Scan_Interval: uint64;
function LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold: Integer;

function  LF_GetStatusCount(): integer; cdecl; external liblingofuse name 'LF_GetStatusCount';
function  LF_GetStatus(): pansichar; cdecl; external liblingofuse name 'LF_GetStatus';
function  LF_GetStatusEx(): string;
procedure LF_PostStatus(status: pansichar); cdecl; external liblingofuse name 'LF_PostStatus';
procedure LF_PostStatusEx(status: string);

{ ============================================================================ }
{ Network events                                                               }
{ ============================================================================ }

procedure LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event); cdecl; external liblingofuse name 'LF_Set_Network_Event';

{ ============================================================================ }
{ Sync pump / Shutdown                                                         }
{ ============================================================================ }

function  LF_Sync(): integer;
procedure LF_Shutdown; cdecl; external liblingofuse name 'LF_Shutdown';

implementation

uses SyncObjs;

type
  PLF_ListNode = ^TLF_ListNode;
  TLF_ListNode = record
    Data: Pointer;
    Prev: PLF_ListNode;
    Next: PLF_ListNode;
  end;

  TLF_List = class
  private
    FFirst: PLF_ListNode;
    FLast: PLF_ListNode;
    FNum: Integer;
    FAutoFree: Boolean;
  public
    constructor Create(AutoFree_: Boolean);
    destructor Destroy; override;
    procedure Clear;
    function Add(Data: Pointer): PLF_ListNode;
    procedure Remove(p: PLF_ListNode);
    function GetItem(Index: Integer): Pointer;
    procedure MoveAllTo(Dest: TLF_List);
    property Num: Integer read FNum;
    property First: PLF_ListNode read FFirst;
    property Last: PLF_ListNode read FLast;
    property Items[Index: Integer]: Pointer read GetItem; default;
  end;

  TCritical = class(TCriticalSection)
  public
    procedure Lock; inline;
    procedure UnLock; inline;
  end;

  TPair2<T1, T2> = packed record
    Primary: T1;
    Second: T2;
    class function Init(Primary_: T1; Second_: T2): TPair2<T1, T2>; static;
  end;

  TCore_Thread = TThread;

{$IFDEF FPC}
  TOnSynchronize_P_NP = procedure() is nested;
{$ELSE FPC}
  TOnSynchronize_P_NP = reference to procedure();
{$ENDIF FPC}

  TSynchronize_Data___ = TPair2<TOnSynchronize_P_NP, Boolean>;
  PSynchronize_Data___ = ^TSynchronize_Data___;

  TSoft_Synchronize_Tool = class
  private
    SyncQueue__: TLF_List;
    Critical: TCritical;
  public
    Soft_Synchronize_Main_Thread: TCore_Thread;
    constructor Create;
    destructor Destroy; override;
    function Check_Synchronize(): NativeInt;
    procedure Synchronize(OnSync: TOnSynchronize_P_NP);
  end;

  TLF_Call_Holder = class
    FCB: TLF_Call_P;
  end;

  TLF_Notify_Holder = class
    FCB: TLF_Notify_P;
  end;

  TLF_Async_Call_Holder = class
    FCB: TLF_Async_Call_P;
  end;

  TLF_Async_Call_Pool = class
  private
    FFree: TLF_List;
    FCritical: TCritical;
  public
    constructor Create;
    destructor Destroy; override;
    function Acquire: TLF_Async_Call_Holder;
    procedure Release(h: TLF_Async_Call_Holder);
    function FreeCount: Integer;
  end;

constructor TLF_List.Create(AutoFree_: Boolean);
begin
  inherited Create;
  FFirst := nil;
  FLast := nil;
  FNum := 0;
  FAutoFree := AutoFree_;
end;

destructor TLF_List.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TLF_List.Clear;
var
  p, N: PLF_ListNode;
begin
  p := FFirst;
  while p <> nil do
  begin
    N := p^.Next;
    if FAutoFree and (p^.Data <> nil) then
    begin
      try
        TObject(p^.Data).Free;
      except
      end;
    end;
    Dispose(p);
    p := N;
  end;
  FFirst := nil;
  FLast := nil;
  FNum := 0;
end;

function TLF_List.Add(Data: Pointer): PLF_ListNode;
var
  p: PLF_ListNode;
begin
  New(p);
  p^.Data := Data;
  p^.Prev := FLast;
  p^.Next := nil;
  if FLast <> nil then
    FLast^.Next := p
  else
    FFirst := p;
  FLast := p;
  Inc(FNum);
  Result := p;
end;

procedure TLF_List.Remove(p: PLF_ListNode);
begin
  if p = nil then Exit;
  if p^.Prev <> nil then
    p^.Prev^.Next := p^.Next
  else
    FFirst := p^.Next;
  if p^.Next <> nil then
    p^.Next^.Prev := p^.Prev
  else
    FLast := p^.Prev;
  if FAutoFree and (p^.Data <> nil) then
  begin
    try
      TObject(p^.Data).Free;
    except
    end;
  end;
  Dispose(p);
  Dec(FNum);
end;

function TLF_List.GetItem(Index: Integer): Pointer;
var
  p: PLF_ListNode;
  i: Integer;
begin
  if (Index < 0) or (Index >= FNum) then
    raise Exception.Create('TLF_List index out of range');
  p := FFirst;
  for i := 0 to Index - 1 do
    p := p^.Next;
  Result := p^.Data;
end;

procedure TLF_List.MoveAllTo(Dest: TLF_List);
begin
  if Dest = nil then Exit;
  if FNum > 0 then
  begin
    if Dest.FLast <> nil then
      Dest.FLast^.Next := FFirst
    else
      Dest.FFirst := FFirst;
    FFirst^.Prev := Dest.FLast;
    Dest.FLast := FLast;
    Inc(Dest.FNum, FNum);
  end;
  FFirst := nil;
  FLast := nil;
  FNum := 0;
end;

procedure TCritical.Lock;
begin
  Acquire;
end;

procedure TCritical.UnLock;
begin
  Release;
end;

class function TPair2<T1, T2>.Init(Primary_: T1; Second_: T2): TPair2<T1, T2>;
begin
  Result.Primary := Primary_;
  Result.Second := Second_;
end;

constructor TSoft_Synchronize_Tool.Create;
begin
  inherited Create;
  SyncQueue__ := TLF_List.Create(False);
  Critical := TCritical.Create;
  Soft_Synchronize_Main_Thread := nil;
end;

destructor TSoft_Synchronize_Tool.Destroy;
var
  p, N: PLF_ListNode;
begin
  Critical.Lock;
  try
    p := SyncQueue__.First;
    while p <> nil do
    begin
      N := p^.Next;
      if p^.Data <> nil then
        Dispose(PSynchronize_Data___(p^.Data));
      p := N;
    end;
    SyncQueue__.Clear;
  finally
    Critical.UnLock;
  end;
  SyncQueue__.Free;
  Critical.Free;
  inherited Destroy;
end;

function TSoft_Synchronize_Tool.Check_Synchronize(): NativeInt;
var
  Temp_Queue: TLF_List;
  p, N: PLF_ListNode;
  sync_: PSynchronize_Data___;
begin
  Result := 0;
  if Soft_Synchronize_Main_Thread = nil then
    Soft_Synchronize_Main_Thread := TCore_Thread.CurrentThread;
  if Soft_Synchronize_Main_Thread <> TCore_Thread.CurrentThread then
    Exit;

  Temp_Queue := TLF_List.Create(False);
  Critical.Lock;
  try
    SyncQueue__.MoveAllTo(Temp_Queue);
  finally
    Critical.UnLock;
  end;

  p := Temp_Queue.First;
  while p <> nil do
  begin
    N := p^.Next;
    sync_ := PSynchronize_Data___(p^.Data);
    try
      if Assigned(sync_^.Primary) then
        sync_^.Primary();
    except
    end;
    sync_^.Second := False;
    Inc(Result);
    p := N;
  end;

  Temp_Queue.Free;
end;

procedure TSoft_Synchronize_Tool.Synchronize(OnSync: TOnSynchronize_P_NP);
var
  tmp: PSynchronize_Data___;
begin
  if (Soft_Synchronize_Main_Thread = nil) or
     (TCore_Thread.CurrentThread = Soft_Synchronize_Main_Thread) then
  begin
    try
      Check_Synchronize();
      OnSync();
    except
    end;
  end
  else
  begin
    New(tmp);
    tmp^ := TPair2<TOnSynchronize_P_NP, Boolean>.Init(OnSync, True);
    Critical.Lock;
    try
      SyncQueue__.Add(tmp);
    finally
      Critical.UnLock;
    end;
    while tmp^.Second do
      TCore_Thread.Sleep(1);
    Dispose(tmp);
  end;
end;

constructor TLF_Async_Call_Pool.Create;
begin
  inherited Create;
  FFree := TLF_List.Create(True);
  FCritical := TCritical.Create;
end;

destructor TLF_Async_Call_Pool.Destroy;
begin
  FCritical.Lock;
  try
    FFree.Clear;
  finally
    FCritical.UnLock;
  end;
  FFree.Free;
  FCritical.Free;
  inherited Destroy;
end;

function TLF_Async_Call_Pool.Acquire: TLF_Async_Call_Holder;
var
  p: PLF_ListNode;
begin
  FCritical.Lock;
  try
    if FFree.Num > 0 then
    begin
      p := FFree.First;
      Result := TLF_Async_Call_Holder(p^.Data);
      FFree.Remove(p);
    end
    else
      Result := TLF_Async_Call_Holder.Create;
  finally
    FCritical.UnLock;
  end;
end;

procedure TLF_Async_Call_Pool.Release(h: TLF_Async_Call_Holder);
begin
  if h = nil then Exit;
  h.FCB := nil;
  FCritical.Lock;
  try
    FFree.Add(h);
  finally
    FCritical.UnLock;
  end;
end;

function TLF_Async_Call_Pool.FreeCount: Integer;
begin
  FCritical.Lock;
  try
    Result := FFree.Num;
  finally
    FCritical.UnLock;
  end;
end;

var
  LF_MethodList: TLF_List;
  LF_Call_List: TLF_List;
  LF_Notify_List: TLF_List;
  LF_Async_Call_Pool: TLF_Async_Call_Pool;
  LF_SyncTool: TSoft_Synchronize_Tool;

type
  PM = ^TMethod;

procedure Do_Internal_Call__(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
var
  ev: TLF_Call_M;
begin
  ev := TLF_Call_M(PM(Trigger)^);
  ev(Input, Output);
end;

procedure Do_Internal_Sync_Call__(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
var
  ev: TLF_Call_M;

  procedure DoSync();
  begin
    ev(Input, Output);
  end;

begin
  ev := TLF_Call_M(PM(Trigger)^);
{$IFDEF FPC}
  LF_SyncTool.Synchronize(DoSync);
{$ELSE FPC}
  LF_SyncTool.Synchronize(
    procedure
    begin
      ev(Input, Output);
    end);
{$ENDIF FPC}
end;

procedure Do_Internal_Notify__(Trigger: Pointer; Input: TDataHnd___); cdecl;
var
  ev: TLF_Notify_M;
begin
  ev := TLF_Notify_M(PM(Trigger)^);
  ev(Input);
end;

procedure Do_Internal_Sync_Notify__(Trigger: Pointer; Input: TDataHnd___); cdecl;
var
  ev: TLF_Notify_M;

  procedure DoSync();
  begin
    ev(Input);
  end;

begin
  ev := TLF_Notify_M(PM(Trigger)^);
{$IFDEF FPC}
  LF_SyncTool.Synchronize(DoSync);
{$ELSE FPC}
  LF_SyncTool.Synchronize(
    procedure
    begin
      ev(Input);
    end);
{$ENDIF FPC}
end;

procedure Do_Internal_Call_P__(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
var
  h: TLF_Call_Holder;
begin
  h := TLF_Call_Holder(Trigger);
  if Assigned(h.FCB) then
    h.FCB(Input, Output);
end;

procedure Do_Internal_Sync_Call_P__(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
var
  h: TLF_Call_Holder;

  procedure DoSync();
  begin
    if Assigned(h.FCB) then
      h.FCB(Input, Output);
  end;

begin
  h := TLF_Call_Holder(Trigger);
{$IFDEF FPC}
  LF_SyncTool.Synchronize(DoSync);
{$ELSE FPC}
  LF_SyncTool.Synchronize(
    procedure
    begin
      if Assigned(h.FCB) then
        h.FCB(Input, Output);
    end);
{$ENDIF FPC}
end;

procedure Do_Internal_Notify_P__(Trigger: Pointer; Input: TDataHnd___); cdecl;
var
  h: TLF_Notify_Holder;
begin
  h := TLF_Notify_Holder(Trigger);
  if Assigned(h.FCB) then
    h.FCB(Input);
end;

procedure Do_Internal_Sync_Notify_P__(Trigger: Pointer; Input: TDataHnd___); cdecl;
var
  h: TLF_Notify_Holder;

  procedure DoSync();
  begin
    if Assigned(h.FCB) then
      h.FCB(Input);
  end;

begin
  h := TLF_Notify_Holder(Trigger);
{$IFDEF FPC}
  LF_SyncTool.Synchronize(DoSync);
{$ELSE FPC}
  LF_SyncTool.Synchronize(
    procedure
    begin
      if Assigned(h.FCB) then
        h.FCB(Input);
    end);
{$ENDIF FPC}
end;

procedure Do_Internal_Async_Call_P__(Data: Pointer; Result_: TDataHnd___); cdecl;
var
  h: TLF_Async_Call_Holder;
  cb: TLF_Async_Call_P;
begin
  h := TLF_Async_Call_Holder(Data);
  if h = nil then Exit;
  cb := h.FCB;
  LF_Async_Call_Pool.Release(h);
  if Assigned(cb) then
  begin
    try
      cb(Result_);
    except
    end;
  end;
end;

function LF_CreateDataEx(MethodName: string): TDataHnd___;
begin
  Result := LF_CreateData(pansichar(UTF8Encode(MethodName)));
end;

function LF_CreateData_PermanentEx(MethodName: string): TDataHnd___;
begin
  Result := LF_CreateData_Permanent(pansichar(UTF8Encode(MethodName)));
end;

function LF_CreateAppEx(appName, Desc: string): TAppHnd___;
begin
  Result := LF_CreateApp(pansichar(UTF8Encode(appName)), pansichar(UTF8Encode(Desc)));
end;

function LF_Generate_AppNameEx(): string;
var
  p: pansichar;
begin
  p := LF_Generate_AppName();
  if p = nil then
    Result := ''
  else
    Result := string(UTF8Decode(p));
end;

function LF_Get_AppNameEx(appHnd: TAppHnd___): string;
var
  p: pansichar;
begin
  p := LF_Get_AppName(appHnd);
  if p = nil then
    Result := ''
  else
    Result := string(UTF8Decode(p));
end;

function LF_Get_P2P_NameEx(Hnd: TDataHnd___): string;
var
  p: pansichar;
begin
  p := LF_Get_P2P_Name(Hnd);
  if p = nil then
    Result := ''
  else
    Result := string(UTF8Decode(p));
end;

function LF_RegisterCallEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin
  Result := LF_RegisterCall(appHnd, pansichar(UTF8Encode(MethodName)), pansichar(UTF8Encode(Desc)), Trigger, OnCall);
end;

function LF_RegisterNotifyEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin
  Result := LF_RegisterNotify(appHnd, pansichar(UTF8Encode(MethodName)), pansichar(UTF8Encode(Desc)), Trigger, OnNotify);
end;

function LF_UnregisterEx(appHnd: TAppHnd___; MethodName: string): integer;
begin
  Result := LF_Unregister(appHnd, pansichar(UTF8Encode(MethodName)));
end;

function LF_Register_P2P_CallEx(MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin
  Result := LF_Register_P2P_Call(pansichar(UTF8Encode(MethodName)), pansichar(UTF8Encode(Desc)), Trigger, OnCall);
end;

function LF_Register_P2P_NotifyEx(MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin
  Result := LF_Register_P2P_Notify(pansichar(UTF8Encode(MethodName)), pansichar(UTF8Encode(Desc)), Trigger, OnNotify);
end;

function LF_Unregister_P2PEx(MethodName: string): integer;
begin
  Result := LF_Unregister_P2P(pansichar(UTF8Encode(MethodName)));
end;

function LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_: string): integer;
begin
  Result := LF_PrepareService(pansichar(UTF8Encode(ListeningAddr_)), pansichar(UTF8Encode(PhysicsAddr_)));
end;

function LF_PrepareClientEx(PhysicsAddr_: string; appHnd: TAppHnd___): integer;
begin
  Result := LF_PrepareClient(pansichar(UTF8Encode(PhysicsAddr_)), appHnd);
end;

function LF_PrepareClientEx(PhysicsAddr_: string): integer;
begin
  Result := LF_PrepareClientEx(PhysicsAddr_, nil);
end;

function LF_CallEx(appName: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin
  Result := LF_Call(pansichar(UTF8Encode(appName)), Param, Timeout_);
end;

function LF_Async_CallEx(appName: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin
  Result := LF_Async_Call(pansichar(UTF8Encode(appName)), Param, Data, OnResult);
end;

function LF_Async_Sequenced_CallEx(appName: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin
  Result := LF_Async_Sequenced_Call(pansichar(UTF8Encode(appName)), Param, Data, OnResult);
end;

procedure LF_NotifyEx(appName: string; Param: TDataHnd___);
begin
  LF_Notify(pansichar(UTF8Encode(appName)), Param);
end;

procedure LF_Sequenced_NotifyEx(appName: string; Param: TDataHnd___);
begin
  LF_Sequenced_Notify(pansichar(UTF8Encode(appName)), Param);
end;

function LF_UID_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin
  Result := LF_UID_Call(UID, Param, Timeout_);
end;

function LF_UID_Async_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin
  Result := LF_UID_Async_Call(UID, Param, Data, OnResult);
end;

function LF_UID_Async_Sequenced_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin
  Result := LF_UID_Async_Sequenced_Call(UID, Param, Data, OnResult);
end;

procedure LF_UID_NotifyEx(const UID: TP2P_UID___; Param: TDataHnd___);
begin
  LF_UID_Notify(UID, Param);
end;

procedure LF_UID_Sequenced_NotifyEx(const UID: TP2P_UID___; Param: TDataHnd___);
begin
  LF_UID_Sequenced_Notify(UID, Param);
end;

function LF_P2PNAME_CallEx(p2p_name_: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin
  Result := LF_P2PNAME_Call(pansichar(UTF8Encode(p2p_name_)), Param, Timeout_);
end;

function LF_P2PNAME_Async_CallEx(p2p_name_: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin
  Result := LF_P2PNAME_Async_Call(pansichar(UTF8Encode(p2p_name_)), Param, Data, OnResult);
end;

function LF_P2PNAME_Async_Sequenced_CallEx(p2p_name_: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin
  Result := LF_P2PNAME_Async_Sequenced_Call(pansichar(UTF8Encode(p2p_name_)), Param, Data, OnResult);
end;

procedure LF_P2PNAME_NotifyEx(p2p_name_: string; Param: TDataHnd___);
begin
  LF_P2PNAME_Notify(pansichar(UTF8Encode(p2p_name_)), Param);
end;

procedure LF_P2PNAME_Sequenced_NotifyEx(p2p_name_: string; Param: TDataHnd___);
begin
  LF_P2PNAME_Sequenced_Notify(pansichar(UTF8Encode(p2p_name_)), Param);
end;

function LF_Check_UIDEx(const UID: TP2P_UID___): boolean;
begin
  Result := LF_Check_UID(UID) <> 0;
end;

function LF_Check_UID_ApiEx(const UID: TP2P_UID___; apiName: string): boolean;
begin
  Result := LF_Check_UID_Api(UID, pansichar(UTF8Encode(apiName))) <> 0;
end;

function LF_Check_P2PNAMEEx(p2p_name_: string): boolean;
begin
  Result := LF_Check_P2PNAME(pansichar(UTF8Encode(p2p_name_))) <> 0;
end;

function LF_Check_P2PNAME_ApiEx(p2p_name_, apiName: string): boolean;
begin
  Result := LF_Check_P2PNAME_Api(pansichar(UTF8Encode(p2p_name_)), pansichar(UTF8Encode(apiName))) <> 0;
end;

procedure LF_SetOptionEx(Option, Value: string);
begin
  LF_SetOption(pansichar(UTF8Encode(Option)), pansichar(UTF8Encode(Value)));
end;

function LF_GetOptionEx(Option: string): string;
var
  p: pansichar;
begin
  p := LF_GetOption(pansichar(UTF8Encode(Option)));
  if p = nil then
    Result := ''
  else
    Result := string(UTF8Decode(p));
end;

{ ---- LF_SetOption shortcuts (v3: LF_Set_Opt_XXX) ------------------------- }

procedure LF_Set_Opt_Debug(const Value: string);
begin
  LF_SetOptionEx('debug', Value);
end;

procedure LF_Set_Opt_P2P_Name(const Value: string);
begin
  LF_SetOptionEx('LF_P2P_name', Value);
end;

procedure LF_Set_Opt_Password(const Value: string);
begin
  LF_SetOptionEx('password', Value);
end;

procedure LF_Set_Opt_Quiet(const Value: Boolean);
begin
  if Value then
    LF_SetOptionEx('Quiet', 'True')
  else
    LF_SetOptionEx('Quiet', 'False');
end;

procedure LF_Set_Opt_Overlap_Connection(const Value: Boolean);
begin
  if Value then
    LF_SetOptionEx('Overlap_Connection', 'True')
  else
    LF_SetOptionEx('Overlap_Connection', 'False');
end;

procedure LF_Set_Opt_Wait_Connection_ReadyOk(const Value: Boolean);
begin
  if Value then
    LF_SetOptionEx('Wait_Connection_ReadyOk', 'True')
  else
    LF_SetOptionEx('Wait_Connection_ReadyOk', 'False');
end;

procedure LF_Set_Opt_Wait_Connection_Timeout(const Value: uint64);
begin
  LF_SetOptionEx('Wait_Connection_Timeout', IntToStr(Value));
end;

procedure LF_Set_Opt_ShowThreadID(const Value: Boolean);
begin
  if Value then
    LF_SetOptionEx('ShowThreadID', 'True')
  else
    LF_SetOptionEx('ShowThreadID', 'False');
end;

procedure LF_Set_Opt_ConsoleOutput(const Value: Boolean);
begin
  if Value then
    LF_SetOptionEx('ConsoleOutput', 'True')
  else
    LF_SetOptionEx('ConsoleOutput', 'False');
end;

procedure LF_Set_Opt_IPC_Serv_ThreadCount(const Value: Integer);
begin
  LF_SetOptionEx('IPC_Serv_ThreadCount', IntToStr(Value));
end;

procedure LF_Set_Opt_IPC_Serv_MaxQueueLength(const Value: Integer);
begin
  LF_SetOptionEx('IPC_Serv_MaxQueueLength', IntToStr(Value));
end;

procedure LF_Set_Opt_IPC_Serv_MaxMsgSize(const Value: Integer);
begin
  LF_SetOptionEx('IPC_Serv_MaxMsgSize', IntToStr(Value));
end;

procedure LF_Set_Opt_Fixed_Sequenced_Time(const Value: uint64);
begin
  LF_SetOptionEx('Fixed_Sequenced_Time', IntToStr(Value));
end;

procedure LF_Set_Opt_DataHandle_Idle_Timeout(const Value: uint64);
begin
  LF_SetOptionEx('DataHandle_Idle_Timeout', IntToStr(Value));
end;

procedure LF_Set_Opt_DataHandle_Pool_Scan_Interval(const Value: uint64);
begin
  LF_SetOptionEx('DataHandle_Pool_Scan_Interval', IntToStr(Value));
end;

procedure LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(const Value: Integer);
begin
  LF_SetOptionEx('No_Reponse_Cmd_NULL_Flush_Threshold', IntToStr(Value));
end;

{ ---- LF_GetOption shortcuts (v3: LF_Get_Opt_XXX) ------------------------- }

function LF_Get_Opt_Debug: string;
begin
  Result := LF_GetOptionEx('debug');
end;

function LF_Get_Opt_P2P_Name: string;
begin
  Result := LF_GetOptionEx('LF_P2P_name');
end;

function LF_Get_Opt_Password: string;
begin
  Result := LF_GetOptionEx('password');
end;

function LF_Get_Opt_Quiet: Boolean;
begin
  Result := SameText(LF_GetOptionEx('Quiet'), 'True');
end;

function LF_Get_Opt_Overlap_Connection: Boolean;
begin
  Result := SameText(LF_GetOptionEx('Overlap_Connection'), 'True');
end;

function LF_Get_Opt_Wait_Connection_ReadyOk: Boolean;
begin
  Result := SameText(LF_GetOptionEx('Wait_Connection_ReadyOk'), 'True');
end;

function LF_Get_Opt_Wait_Connection_Timeout: uint64;
var
  s: string;
  v: Int64;
begin
  s := LF_GetOptionEx('Wait_Connection_Timeout');
  if TryStrToInt64(s, v) then
    Result := uint64(v)
  else
    Result := 0;
end;

function LF_Get_Opt_ShowThreadID: Boolean;
begin
  Result := SameText(LF_GetOptionEx('ShowThreadID'), 'True');
end;

function LF_Get_Opt_ConsoleOutput: Boolean;
begin
  Result := SameText(LF_GetOptionEx('ConsoleOutput'), 'True');
end;

function LF_Get_Opt_IPC_Serv_ThreadCount: Integer;
var
  s: string;
  v: Integer;
begin
  s := LF_GetOptionEx('IPC_Serv_ThreadCount');
  if TryStrToInt(s, v) then
    Result := v
  else
    Result := 0;
end;

function LF_Get_Opt_IPC_Serv_MaxQueueLength: Integer;
var
  s: string;
  v: Integer;
begin
  s := LF_GetOptionEx('IPC_Serv_MaxQueueLength');
  if TryStrToInt(s, v) then
    Result := v
  else
    Result := 0;
end;

function LF_Get_Opt_IPC_Serv_MaxMsgSize: Integer;
var
  s: string;
  v: Integer;
begin
  s := LF_GetOptionEx('IPC_Serv_MaxMsgSize');
  if TryStrToInt(s, v) then
    Result := v
  else
    Result := 0;
end;

function LF_Get_Opt_Fixed_Sequenced_Time: uint64;
var
  s: string;
  v: Int64;
begin
  s := LF_GetOptionEx('Fixed_Sequenced_Time');
  if TryStrToInt64(s, v) then
    Result := uint64(v)
  else
    Result := 0;
end;

function LF_Get_Opt_DataHandle_Idle_Timeout: uint64;
var
  s: string;
  v: Int64;
begin
  s := LF_GetOptionEx('DataHandle_Idle_Timeout');
  if TryStrToInt64(s, v) then
    Result := uint64(v)
  else
    Result := 0;
end;

function LF_Get_Opt_DataHandle_Pool_Scan_Interval: uint64;
var
  s: string;
  v: Int64;
begin
  s := LF_GetOptionEx('DataHandle_Pool_Scan_Interval');
  if TryStrToInt64(s, v) then
    Result := uint64(v)
  else
    Result := 0;
end;

function LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold: Integer;
var
  s: string;
  v: Integer;
begin
  s := LF_GetOptionEx('No_Reponse_Cmd_NULL_Flush_Threshold');
  if TryStrToInt(s, v) then
    Result := v
  else
    Result := 0;
end;

function LF_GetStatusEx(): string;
var
  p: pansichar;
begin
  p := LF_GetStatus();
  if p = nil then
    Result := ''
  else
    Result := string(UTF8Decode(p));
end;

procedure LF_PostStatusEx(status: string);
begin
  LF_PostStatus(pansichar(UTF8Encode(status)));
end;

function LF_CheckMainThreadEx(): boolean;
begin
  Result := LF_CheckMainThread() <> 0;
end;

function LF_CheckAppEx(appName: string): boolean;
begin
  Result := LF_CheckApp(pansichar(UTF8Encode(appName))) <> 0;
end;

function LF_CheckApiEx(appName, apiName: string): boolean;
begin
  Result := LF_CheckApi(pansichar(UTF8Encode(appName)), pansichar(UTF8Encode(apiName))) <> 0;
end;

function LF_GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer;
var
  base: Pointer;
begin
  base := LF_GetBuffer(Hnd);
  if base = nil then
    Result := nil
  else
    Result := Pointer(NativeUInt(base) + NativeUInt(Offset));
end;

function LF_WriteInt8(Hnd: TDataHnd___; Value: int8): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteInt16(Hnd: TDataHnd___; Value: int16): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteInt32(Hnd: TDataHnd___; Value: int32): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteInt64(Hnd: TDataHnd___; Value: int64): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteSingle(Hnd: TDataHnd___; Value: single): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteDouble(Hnd: TDataHnd___; Value: double): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_WriteString(Hnd: TDataHnd___; const Value: string): boolean;
var
  utf8: TBytes;
  len: integer;
begin
  if Value = '' then
  begin
    Result := LF_WriteUInt8(Hnd, 0);
    Exit;
  end;
  utf8 := TEncoding.UTF8.GetBytes(Value);
  len := Length(utf8);
  if LF_WriteBuffer(Hnd, @utf8[0], len) <> len then
  begin
    Result := False;
    Exit;
  end;
  Result := LF_WriteUInt8(Hnd, 0);
end;

function LF_WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean;
begin
  if Length(Value) <= 0 then
  begin
    Result := LF_WriteUInt8(Hnd, 0);
    Exit;
  end;
  if LF_WriteBuffer(Hnd, @Value[0], Length(Value)) <> Length(Value) then
  begin
    Result := False;
    Exit;
  end;
  Result := LF_WriteUInt8(Hnd, 0);
end;

function LF_ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadSingle(Hnd: TDataHnd___; out Value: single): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadDouble(Hnd: TDataHnd___; out Value: double): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

function LF_ReadInt8(Hnd: TDataHnd___): int8;
var
  v: int8;
begin
  if LF_ReadInt8(Hnd, v) then Result := v else Result := 0;
end;

function LF_ReadUInt8(Hnd: TDataHnd___): uint8;
var
  v: uint8;
begin
  if LF_ReadUInt8(Hnd, v) then Result := v else Result := 0;
end;

function LF_ReadInt16(Hnd: TDataHnd___): int16;
var
  v: int16;
begin
  if LF_ReadInt16(Hnd, v) then Result := v else Result := 0;
end;

function LF_ReadUInt16(Hnd: TDataHnd___): uint16;
var
  v: uint16;
begin
  if LF_ReadUInt16(Hnd, v) then Result := v else Result := 0;
end;

function LF_ReadInt32(Hnd: TDataHnd___): int32;
var
  v: int32;
begin
  if LF_ReadInt32(Hnd, v) then Result := v else Result := 0;
end;

function LF_ReadUInt32(Hnd: TDataHnd___): uint32;
var
  v: uint32;
begin
  if LF_ReadUInt32(Hnd, v) then Result := v else Result := 0;
end;

function LF_ReadInt64(Hnd: TDataHnd___): int64;
var
  v: int64;
begin
  if LF_ReadInt64(Hnd, v) then Result := v else Result := 0;
end;

function LF_ReadUInt64(Hnd: TDataHnd___): uint64;
var
  v: uint64;
begin
  if LF_ReadUInt64(Hnd, v) then Result := v else Result := 0;
end;

function LF_ReadSingle(Hnd: TDataHnd___): single;
var
  v: single;
begin
  if LF_ReadSingle(Hnd, v) then Result := v else Result := 0.0;
end;

function LF_ReadDouble(Hnd: TDataHnd___): double;
var
  v: double;
begin
  if LF_ReadDouble(Hnd, v) then Result := v else Result := 0.0;
end;

function LF_ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean;
type
  TByteArray = array [0 .. 0] of byte;
  PByteArray = ^TByteArray;
var
  p: PByteArray;
  b, e, sz: int64;
begin
  p := LF_GetBuffer(Hnd);
  sz := LF_GetSize(Hnd);
  if (p = nil) or (sz = 0) then
  begin
    SetLength(Buff, 0);
    Result := False;
    Exit;
  end;
  b := LF_GetPos(Hnd);
  if b >= sz then
  begin
    SetLength(Buff, 0);
    Result := False;
    Exit;
  end;
  e := b;
  while (e < sz) and (p^[e] <> 0) do
    Inc(e);
  SetLength(Buff, e - b);
  if e > b then
    Move(p^[b], Buff[0], e - b);
  LF_SetPos(Hnd, e + 1);
  Result := True;
end;

function LF_ReadStringBytes(Hnd: TDataHnd___): TBytes;
begin
  LF_ReadStringBytes(Hnd, Result);
end;

function LF_ReadString(Hnd: TDataHnd___; out Value: string): boolean;
type
  TByteArray = array [0 .. 0] of byte;
  PByteArray = ^TByteArray;
var
  p: PByteArray;
  b, e, sz: int64;
  Buff: TBytes;
begin
  p := LF_GetBuffer(Hnd);
  sz := LF_GetSize(Hnd);
  if (p = nil) or (sz = 0) then
  begin
    Value := '';
    Result := False;
    Exit;
  end;
  b := LF_GetPos(Hnd);
  if b >= sz then
  begin
    Value := '';
    Result := False;
    Exit;
  end;
  e := b;
  while (e < sz) and (p^[e] <> 0) do
    Inc(e);
  SetLength(Buff, e - b);
  if e > b then
    Move(p^[b], Buff[0], e - b);
  LF_SetPos(Hnd, e + 1);
  Value := string(TEncoding.UTF8.GetString(Buff));
  Result := True;
end;

function LF_ReadString(Hnd: TDataHnd___): string;
begin
  LF_ReadString(Hnd, Result);
end;

function LF_RegisterCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
var
  pMethod: PM;
begin
  New(pMethod);
  pMethod^ := TMethod(OnCall);
  LF_MethodList.Add(pMethod);
  Result := LF_RegisterCallEx(appHnd, MethodName, Desc, pMethod, Do_Internal_Call__);
end;

function LF_RegisterSyncCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
var
  pMethod: PM;
begin
  New(pMethod);
  pMethod^ := TMethod(OnCall);
  LF_MethodList.Add(pMethod);
  Result := LF_RegisterCallEx(appHnd, MethodName, Desc, pMethod, Do_Internal_Sync_Call__);
end;

function LF_RegisterNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
var
  pMethod: PM;
begin
  New(pMethod);
  pMethod^ := TMethod(OnNotify);
  LF_MethodList.Add(pMethod);
  Result := LF_RegisterNotifyEx(appHnd, MethodName, Desc, pMethod, Do_Internal_Notify__);
end;

function LF_RegisterSyncNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
var
  pMethod: PM;
begin
  New(pMethod);
  pMethod^ := TMethod(OnNotify);
  LF_MethodList.Add(pMethod);
  Result := LF_RegisterNotifyEx(appHnd, MethodName, Desc, pMethod, Do_Internal_Sync_Notify__);
end;

function LF_RegisterCall_P(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_P): integer;
var
  h: TLF_Call_Holder;
begin
  h := TLF_Call_Holder.Create;
  h.FCB := OnCall;
  LF_Call_List.Add(h);
  Result := LF_RegisterCallEx(appHnd, MethodName, Desc, h, Do_Internal_Call_P__);
end;

function LF_RegisterSyncCall_P(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_P): integer;
var
  h: TLF_Call_Holder;
begin
  h := TLF_Call_Holder.Create;
  h.FCB := OnCall;
  LF_Call_List.Add(h);
  Result := LF_RegisterCallEx(appHnd, MethodName, Desc, h, Do_Internal_Sync_Call_P__);
end;

function LF_RegisterNotify_P(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
var
  h: TLF_Notify_Holder;
begin
  h := TLF_Notify_Holder.Create;
  h.FCB := OnNotify;
  LF_Notify_List.Add(h);
  Result := LF_RegisterNotifyEx(appHnd, MethodName, Desc, h, Do_Internal_Notify_P__);
end;

function LF_RegisterSyncNotify_P(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
var
  h: TLF_Notify_Holder;
begin
  h := TLF_Notify_Holder.Create;
  h.FCB := OnNotify;
  LF_Notify_List.Add(h);
  Result := LF_RegisterNotifyEx(appHnd, MethodName, Desc, h, Do_Internal_Sync_Notify_P__);
end;

function LF_Register_P2P_Call_M(MethodName, Desc: string; OnCall: TLF_Call_M): integer;
var
  pMethod: PM;
begin
  New(pMethod);
  pMethod^ := TMethod(OnCall);
  LF_MethodList.Add(pMethod);
  Result := LF_Register_P2P_CallEx(MethodName, Desc, pMethod, Do_Internal_Call__);
end;

function LF_Register_P2P_SyncCall_M(MethodName, Desc: string; OnCall: TLF_Call_M): integer;
var
  pMethod: PM;
begin
  New(pMethod);
  pMethod^ := TMethod(OnCall);
  LF_MethodList.Add(pMethod);
  Result := LF_Register_P2P_CallEx(MethodName, Desc, pMethod, Do_Internal_Sync_Call__);
end;

function LF_Register_P2P_Notify_M(MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
var
  pMethod: PM;
begin
  New(pMethod);
  pMethod^ := TMethod(OnNotify);
  LF_MethodList.Add(pMethod);
  Result := LF_Register_P2P_NotifyEx(MethodName, Desc, pMethod, Do_Internal_Notify__);
end;

function LF_Register_P2P_SyncNotify_M(MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
var
  pMethod: PM;
begin
  New(pMethod);
  pMethod^ := TMethod(OnNotify);
  LF_MethodList.Add(pMethod);
  Result := LF_Register_P2P_NotifyEx(MethodName, Desc, pMethod, Do_Internal_Sync_Notify__);
end;

function LF_Register_P2P_Call_P(MethodName, Desc: string; OnCall: TLF_Call_P): integer;
var
  h: TLF_Call_Holder;
begin
  h := TLF_Call_Holder.Create;
  h.FCB := OnCall;
  LF_Call_List.Add(h);
  Result := LF_Register_P2P_CallEx(MethodName, Desc, h, Do_Internal_Call_P__);
end;

function LF_Register_P2P_SyncCall_P(MethodName, Desc: string; OnCall: TLF_Call_P): integer;
var
  h: TLF_Call_Holder;
begin
  h := TLF_Call_Holder.Create;
  h.FCB := OnCall;
  LF_Call_List.Add(h);
  Result := LF_Register_P2P_CallEx(MethodName, Desc, h, Do_Internal_Sync_Call_P__);
end;

function LF_Register_P2P_Notify_P(MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
var
  h: TLF_Notify_Holder;
begin
  h := TLF_Notify_Holder.Create;
  h.FCB := OnNotify;
  LF_Notify_List.Add(h);
  Result := LF_Register_P2P_NotifyEx(MethodName, Desc, h, Do_Internal_Notify_P__);
end;

function LF_Register_P2P_SyncNotify_P(MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
var
  h: TLF_Notify_Holder;
begin
  h := TLF_Notify_Holder.Create;
  h.FCB := OnNotify;
  LF_Notify_List.Add(h);
  Result := LF_Register_P2P_NotifyEx(MethodName, Desc, h, Do_Internal_Sync_Notify_P__);
end;

function LF_Async_Call_P(appName: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
var
  h: TLF_Async_Call_Holder;
begin
  h := LF_Async_Call_Pool.Acquire;
  h.FCB := OnResult;
  Result := LF_Async_CallEx(appName, Param, h, Do_Internal_Async_Call_P__);
end;

function LF_Async_Sequenced_Call_P(appName: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
var
  h: TLF_Async_Call_Holder;
begin
  h := LF_Async_Call_Pool.Acquire;
  h.FCB := OnResult;
  Result := LF_Async_Sequenced_CallEx(appName, Param, h, Do_Internal_Async_Call_P__);
end;

function LF_UID_Async_Call_P(const UID: TP2P_UID___; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
var
  h: TLF_Async_Call_Holder;
begin
  h := LF_Async_Call_Pool.Acquire;
  h.FCB := OnResult;
  Result := LF_UID_Async_CallEx(UID, Param, h, Do_Internal_Async_Call_P__);
end;

function LF_UID_Async_Sequenced_Call_P(const UID: TP2P_UID___; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
var
  h: TLF_Async_Call_Holder;
begin
  h := LF_Async_Call_Pool.Acquire;
  h.FCB := OnResult;
  Result := LF_UID_Async_Sequenced_CallEx(UID, Param, h, Do_Internal_Async_Call_P__);
end;

function LF_P2PNAME_Async_Call_P(p2p_name_: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
var
  h: TLF_Async_Call_Holder;
begin
  h := LF_Async_Call_Pool.Acquire;
  h.FCB := OnResult;
  Result := LF_P2PNAME_Async_CallEx(p2p_name_, Param, h, Do_Internal_Async_Call_P__);
end;

function LF_P2PNAME_Async_Sequenced_Call_P(p2p_name_: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
var
  h: TLF_Async_Call_Holder;
begin
  h := LF_Async_Call_Pool.Acquire;
  h.FCB := OnResult;
  Result := LF_P2PNAME_Async_Sequenced_CallEx(p2p_name_, Param, h, Do_Internal_Async_Call_P__);
end;

function LF_Sync(): integer;
begin
  Result := LF_SyncTool.Check_Synchronize();
end;

procedure Do_Init();
begin
  LF_MethodList := TLF_List.Create(False);
  LF_Call_List := TLF_List.Create(True);
  LF_Notify_List := TLF_List.Create(True);
  LF_Async_Call_Pool := TLF_Async_Call_Pool.Create;
  LF_SyncTool := TSoft_Synchronize_Tool.Create;

  if not IsLibrary then
  begin
    if IsConsole then
      LF_SetOptionEx('ConsoleOutput', 'True')
    else
      LF_SetOptionEx('ConsoleOutput', 'False');
  end;
end;

procedure Do_Free;
var
  p: PLF_ListNode;
begin
  if LF_MethodList <> nil then
  begin
    p := LF_MethodList.First;
    while p <> nil do
    begin
      if p^.Data <> nil then
        Dispose(PM(p^.Data));
      p := p^.Next;
    end;
  end;

  LF_MethodList.Free;
  LF_Call_List.Free;
  LF_Notify_List.Free;
  LF_Async_Call_Pool.Free;
  LF_SyncTool.Free;
  LF_MethodList := nil;
  LF_Call_List := nil;
  LF_Notify_List := nil;
  LF_Async_Call_Pool := nil;
  LF_SyncTool := nil;
end;

initialization

  Do_Init();

finalization

  Do_Free();

end.
