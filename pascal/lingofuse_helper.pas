// See LingoFuse_Pascal_Complete_Guide.md for full usage.

unit lingofuse_helper;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$modeswitch advancedrecords}
  {$MODESWITCH NestedProcVars}
  {$CODEPAGE UTF8}
  {$packrecords c}
  {$PACKENUM 4}
{$endif}
{$R-}
{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  lingofuse_import;

type
  TCritical = TCriticalSection;

  LF = class
  public
    type
      TDataHandle = class
      private
        FHandle: TDataHnd___;
        FOwned: boolean;
        FDisposed: boolean;
        FLock: TCritical;
        function IsValid: boolean; inline;
      public
        constructor Create(const MethodName: string); overload;
        constructor Create_Permanent(const MethodName: string);
        constructor Create(AHandle: TDataHnd___; const Owned: boolean = False); overload;
        destructor Destroy; override;

        function WriteBuffer(const Buffer; Size: int64): int64;
        function ReadBuffer(var Buffer; Size: int64): int64;

        function WriteInt8(Value: int8): TDataHandle;
        function WriteUInt8(Value: uint8): TDataHandle;
        function WriteInt16(Value: int16): TDataHandle;
        function WriteUInt16(Value: uint16): TDataHandle;
        function WriteInt32(Value: int32): TDataHandle;
        function WriteUInt32(Value: uint32): TDataHandle;
        function WriteInt64(Value: int64): TDataHandle;
        function WriteUInt64(Value: uint64): TDataHandle;
        function WriteSingle(Value: single): TDataHandle;
        function WriteDouble(Value: double): TDataHandle;
        function WriteStringNullTerminated(const Value: string): TDataHandle;
        function WriteString(const Value: string): TDataHandle;
        function WriteStringBytes(const Value: TBytes): TDataHandle;

        function ReadInt8(var Value: int8): boolean; overload;
        function ReadUInt8(var Value: uint8): boolean; overload;
        function ReadInt16(var Value: int16): boolean; overload;
        function ReadUInt16(var Value: uint16): boolean; overload;
        function ReadInt32(var Value: int32): boolean; overload;
        function ReadUInt32(var Value: uint32): boolean; overload;
        function ReadInt64(var Value: int64): boolean; overload;
        function ReadUInt64(var Value: uint64): boolean; overload;
        function ReadSingle(var Value: single): boolean; overload;
        function ReadDouble(var Value: double): boolean; overload;

        function ReadInt8: int8; overload;
        function ReadUInt8: uint8; overload;
        function ReadInt16: int16; overload;
        function ReadUInt16: uint16; overload;
        function ReadInt32: int32; overload;
        function ReadUInt32: uint32; overload;
        function ReadInt64: int64; overload;
        function ReadUInt64: uint64; overload;
        function ReadSingle: single; overload;
        function ReadDouble: double; overload;

        function ReadStringBytes(out Buff: TBytes): boolean; overload;
        function ReadStringBytes(): TBytes; overload;
        function ReadStringNullTerminated: string;
        function ReadString(out Value: string): boolean; overload;
        function ReadString(): string; overload;

        function GetPos: int64;
        procedure SetPos(Pos_: int64);
        property Pos: int64 read GetPos write SetPos;

        function GetSize: int64;
        procedure SetSize(Size_: int64);
        property Size: int64 read GetSize write SetSize;

        function GetBufferEx(out Size: int64): Pointer;
        function GetBuffer(): Pointer;
        function GetBufferOffset(Offset: nativeint): Pointer;

        function Get_P2P_UID: PP2P_UID___;
        function Get_P2P_Name: string;

        property Handle: TDataHnd___ read FHandle;
      end;

      TAppHandle = class
      private
        FHandle: TAppHnd___;
        FName: string;
      public
        constructor Create(const AppName, Desc: string);
        destructor Destroy; override;

        function Bind: integer;

        function RegisterCall(const MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): boolean; overload;
        function RegisterCall(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean; overload;
        function RegisterCallSync(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
        function RegisterCall_P(const MethodName, Desc: string; OnCall: TLF_Call_P): boolean;
        function RegisterCallSync_P(const MethodName, Desc: string; OnCall: TLF_Call_P): boolean;

        function RegisterNotify(const MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): boolean; overload;
        function RegisterNotify(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean; overload;
        function RegisterNotifySync(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
        function RegisterNotify_P(const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean;
        function RegisterNotifySync_P(const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean;

        function Unregister(const MethodName: string): boolean;

        function LocalCall(Param: TDataHandle): TDataHandle;
        procedure LocalNotify(Param: TDataHandle);

        property Handle: TAppHnd___ read FHandle;
        property Name: string read FName;
      end;

  public
    // Data handle
    class function CreateData(const MethodName: string): TDataHandle; static;
    class function CreateData_Permanent(const MethodName: string): TDataHandle; static;
    class procedure FreeData(Hnd: TDataHnd___); static;
    class function GetBuffer(Hnd: TDataHnd___): Pointer; static;
    class function GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer; static;
    class function WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; static;
    class function ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; static;
    class function GetPos(Hnd: TDataHnd___): int64; static;
    class procedure SetPos(Hnd: TDataHnd___; Pos_: int64); static;
    class function GetSize(Hnd: TDataHnd___): int64; static;
    class procedure SetSize(Hnd: TDataHnd___; Size_: int64); static;
    class function Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___; static;
    class function Get_P2P_Name(Hnd: TDataHnd___): string; static;

    // Typed writes
    class function WriteInt8(Hnd: TDataHnd___; Value: int8): boolean; static;
    class function WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean; static;
    class function WriteInt16(Hnd: TDataHnd___; Value: int16): boolean; static;
    class function WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean; static;
    class function WriteInt32(Hnd: TDataHnd___; Value: int32): boolean; static;
    class function WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean; static;
    class function WriteInt64(Hnd: TDataHnd___; Value: int64): boolean; static;
    class function WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean; static;
    class function WriteSingle(Hnd: TDataHnd___; Value: single): boolean; static;
    class function WriteDouble(Hnd: TDataHnd___; Value: double): boolean; static;
    class function WriteString(Hnd: TDataHnd___; const Value: string): boolean; static;
    class function WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean; static;

    // Typed reads (out)
    class function ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean; overload; static;
    class function ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean; overload; static;
    class function ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean; overload; static;
    class function ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean; overload; static;
    class function ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean; overload; static;
    class function ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean; overload; static;
    class function ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean; overload; static;
    class function ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean; overload; static;
    class function ReadSingle(Hnd: TDataHnd___; out Value: single): boolean; overload; static;
    class function ReadDouble(Hnd: TDataHnd___; out Value: double): boolean; overload; static;
    class function ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean; overload; static;
    class function ReadString(Hnd: TDataHnd___; out Value: string): boolean; overload; static;

    // Typed reads (no out)
    class function ReadInt8(Hnd: TDataHnd___): int8; overload; static;
    class function ReadUInt8(Hnd: TDataHnd___): uint8; overload; static;
    class function ReadInt16(Hnd: TDataHnd___): int16; overload; static;
    class function ReadUInt16(Hnd: TDataHnd___): uint16; overload; static;
    class function ReadInt32(Hnd: TDataHnd___): int32; overload; static;
    class function ReadUInt32(Hnd: TDataHnd___): uint32; overload; static;
    class function ReadInt64(Hnd: TDataHnd___): int64; overload; static;
    class function ReadUInt64(Hnd: TDataHnd___): uint64; overload; static;
    class function ReadSingle(Hnd: TDataHnd___): single; overload; static;
    class function ReadDouble(Hnd: TDataHnd___): double; overload; static;
    class function ReadStringBytes(Hnd: TDataHnd___): TBytes; overload; static;
    class function ReadString(Hnd: TDataHnd___): string; overload; static;

    // App handle
    class function CreateApp(const AppName, Desc: string): TAppHandle; static;
    class procedure FreeApp(App: TAppHandle); static;
    class function Generate_AppName: string; static;
    class function Get_AppName(App: TAppHandle): string; static;
    class function BindApp(App: TAppHandle): integer; static;

    // API registration (app-bound)
    class function RegisterCall(App: TAppHandle; const MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): boolean; overload; static;
    class function RegisterCall(App: TAppHandle; const MethodName, Desc: string; OnCall: TLF_Call_M): boolean; overload; static;
    class function RegisterCallSync(App: TAppHandle; const MethodName, Desc: string; OnCall: TLF_Call_M): boolean; static;
    class function RegisterCall_P(App: TAppHandle; const MethodName, Desc: string; OnCall: TLF_Call_P): boolean; static;
    class function RegisterCallSync_P(App: TAppHandle; const MethodName, Desc: string; OnCall: TLF_Call_P): boolean; static;

    class function RegisterNotify(App: TAppHandle; const MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): boolean; overload; static;
    class function RegisterNotify(App: TAppHandle; const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean; overload; static;
    class function RegisterNotifySync(App: TAppHandle; const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean; static;
    class function RegisterNotify_P(App: TAppHandle; const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean; static;
    class function RegisterNotifySync_P(App: TAppHandle; const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean; static;

    class function Unregister(App: TAppHandle; const MethodName: string): boolean; static;
    class function LocalCall(App: TAppHandle; Param: TDataHandle): TDataHandle; static;
    class procedure LocalNotify(App: TAppHandle; Param: TDataHandle); static;

    // API registration (P2P)
    class function Register_P2P_Call(const MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): boolean; overload; static;
    class function Register_P2P_Call(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean; overload; static;
    class function Register_P2P_CallSync(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean; static;
    class function Register_P2P_Call_P(const MethodName, Desc: string; OnCall: TLF_Call_P): boolean; static;
    class function Register_P2P_CallSync_P(const MethodName, Desc: string; OnCall: TLF_Call_P): boolean; static;

    class function Register_P2P_Notify(const MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): boolean; overload; static;
    class function Register_P2P_Notify(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean; overload; static;
    class function Register_P2P_NotifySync(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean; static;
    class function Register_P2P_Notify_P(const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean; static;
    class function Register_P2P_NotifySync_P(const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean; static;

    class function Unregister_P2P(const MethodName: string): boolean; static;

    // Network preparation
    class procedure ResetPrepare; static;
    class function PrepareService(const ListeningAddr, PhysicsAddr: string): integer; overload; static;
    class function PrepareService(const ListeningAddr, PhysicsAddr: string; App: TAppHandle): integer; overload; static;
    class function PrepareClient(const PhysicsAddr: string; App: TAppHandle): integer; static;
    class function PrepareDone: boolean; static;
    class procedure ExitMainThread; static;

    // Remote invocation by App name
    class function CallApp(const AppName: string; Param: TDataHandle; TimeoutMs: uint64): TDataHandle; static;
    class function AsyncCallApp(const AppName: string; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function AsyncSequencedCallApp(const AppName: string; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function AsyncCallApp_P(const AppName: string; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer; static;
    class function AsyncSequencedCallApp_P(const AppName: string; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer; static;
    class procedure NotifyApp(const AppName: string; Param: TDataHandle); static;
    class procedure SequencedNotifyApp(const AppName: string; Param: TDataHandle); static;

    // Remote invocation by UID
    class function CallUID(const UID: TP2P_UID___; Param: TDataHandle; TimeoutMs: uint64): TDataHandle; static;
    class function AsyncCallUID(const UID: TP2P_UID___; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function AsyncSequencedCallUID(const UID: TP2P_UID___; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function AsyncCallUID_P(const UID: TP2P_UID___; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer; static;
    class function AsyncSequencedCallUID_P(const UID: TP2P_UID___; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer; static;
    class procedure NotifyUID(const UID: TP2P_UID___; Param: TDataHandle); static;
    class procedure SequencedNotifyUID(const UID: TP2P_UID___; Param: TDataHandle); static;

    // Remote invocation by P2P name
    class function CallP2PName(const p2p_name: string; Param: TDataHandle; TimeoutMs: uint64): TDataHandle; static;
    class function AsyncCallP2PName(const p2p_name: string; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function AsyncSequencedCallP2PName(const p2p_name: string; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function AsyncCallP2PName_P(const p2p_name: string; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer; static;
    class function AsyncSequencedCallP2PName_P(const p2p_name: string; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer; static;
    class procedure NotifyP2PName(const p2p_name: string; Param: TDataHandle); static;
    class procedure SequencedNotifyP2PName(const p2p_name: string; Param: TDataHandle); static;

    // Queries
    class function CheckMainThread: boolean; static;
    class function CheckApp(const AppName: string): boolean; static;
    class function CheckApi(AppName, ApiName: string): boolean; static;
    class function CheckUID(const UID: TP2P_UID___): boolean; static;
    class function CheckUIDApi(const UID: TP2P_UID___; ApiName: string): boolean; static;
    class function CheckP2PName(const p2p_name: string): boolean; static;
    class function CheckP2PNameApi(const p2p_name, ApiName: string): boolean; static;

    // Options
    class procedure SetOption(const Option, Value: string); static;
    class function GetOption(const Option: string): string; static;

    class procedure Set_Opt_Debug(const Value: string); static;
    class procedure Set_Opt_P2P_Name(const Value: string); static;
    class procedure Set_Opt_Password(const Value: string); static;
    class procedure Set_Opt_Quiet(const Value: Boolean); static;
    class procedure Set_Opt_Overlap_Connection(const Value: Boolean); static;
    class procedure Set_Opt_Wait_Connection_ReadyOk(const Value: Boolean); static;
    class procedure Set_Opt_Wait_Connection_Timeout(const Value: uint64); static;
    class procedure Set_Opt_ShowThreadID(const Value: Boolean); static;
    class procedure Set_Opt_ConsoleOutput(const Value: Boolean); static;
    class procedure Set_Opt_IPC_Serv_ThreadCount(const Value: Integer); static;
    class procedure Set_Opt_IPC_Serv_MaxQueueLength(const Value: Integer); static;
    class procedure Set_Opt_IPC_Serv_MaxMsgSize(const Value: Integer); static;
    class procedure Set_Opt_Fixed_Sequenced_Time(const Value: uint64); static;
    class procedure Set_Opt_DataHandle_Idle_Timeout(const Value: uint64); static;
    class procedure Set_Opt_DataHandle_Pool_Scan_Interval(const Value: uint64); static;
    class procedure Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(const Value: Integer); static;

    class function Get_Opt_Debug: string; static;
    class function Get_Opt_P2P_Name: string; static;
    class function Get_Opt_Password: string; static;
    class function Get_Opt_Quiet: Boolean; static;
    class function Get_Opt_Overlap_Connection: Boolean; static;
    class function Get_Opt_Wait_Connection_ReadyOk: Boolean; static;
    class function Get_Opt_Wait_Connection_Timeout: uint64; static;
    class function Get_Opt_ShowThreadID: Boolean; static;
    class function Get_Opt_ConsoleOutput: Boolean; static;
    class function Get_Opt_IPC_Serv_ThreadCount: Integer; static;
    class function Get_Opt_IPC_Serv_MaxQueueLength: Integer; static;
    class function Get_Opt_IPC_Serv_MaxMsgSize: Integer; static;
    class function Get_Opt_Fixed_Sequenced_Time: uint64; static;
    class function Get_Opt_DataHandle_Idle_Timeout: uint64; static;
    class function Get_Opt_DataHandle_Pool_Scan_Interval: uint64; static;
    class function Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold: Integer; static;

    // Status
    class function GetStatus: string; static;
    class function Get_Status_Num: integer; static;
    class procedure PostStatus(const Status: string); static;

    // Network events
    class procedure Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event); static;

    // Sync / Shutdown
    class function Sync: integer; static;
    class procedure Shutdown; static;
  end;

  LingoFuse = LF;

  // Raw forwarding class - mirrors lingofuse_import API exactly.
  LF___ = class
  public
    // Data handle
    class function LF_CreateData(MethodName: pansichar): TDataHnd___; static;
    class function LF_CreateDataEx(MethodName: string): TDataHnd___; static;
    class function LF_CreateData_Permanent(MethodName: pansichar): TDataHnd___; static;
    class function LF_CreateData_PermanentEx(MethodName: string): TDataHnd___; static;
    class procedure LF_FreeData(Hnd: TDataHnd___); static;
    class function LF_GetBuffer(Hnd: TDataHnd___): Pointer; static;
    class function LF_GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer; static;
    class function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; static;
    class function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; static;
    class function LF_GetPos(Hnd: TDataHnd___): int64; static;
    class procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64); static;
    class function LF_GetSize(Hnd: TDataHnd___): int64; static;
    class procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64); static;
    class function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___; static;
    class function LF_Get_P2P_Name(Hnd: TDataHnd___): pansichar; static;
    class function LF_Get_P2P_NameEx(Hnd: TDataHnd___): string; static;

    // Typed writes
    class function LF_WriteInt8(Hnd: TDataHnd___; Value: int8): boolean; static;
    class function LF_WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean; static;
    class function LF_WriteInt16(Hnd: TDataHnd___; Value: int16): boolean; static;
    class function LF_WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean; static;
    class function LF_WriteInt32(Hnd: TDataHnd___; Value: int32): boolean; static;
    class function LF_WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean; static;
    class function LF_WriteInt64(Hnd: TDataHnd___; Value: int64): boolean; static;
    class function LF_WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean; static;
    class function LF_WriteSingle(Hnd: TDataHnd___; Value: single): boolean; static;
    class function LF_WriteDouble(Hnd: TDataHnd___; Value: double): boolean; static;
    class function LF_WriteString(Hnd: TDataHnd___; const Value: string): boolean; static;
    class function LF_WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean; static;

    // Typed reads (out)
    class function LF_ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean; overload; static;
    class function LF_ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean; overload; static;
    class function LF_ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean; overload; static;
    class function LF_ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean; overload; static;
    class function LF_ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean; overload; static;
    class function LF_ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean; overload; static;
    class function LF_ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean; overload; static;
    class function LF_ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean; overload; static;
    class function LF_ReadSingle(Hnd: TDataHnd___; out Value: single): boolean; overload; static;
    class function LF_ReadDouble(Hnd: TDataHnd___; out Value: double): boolean; overload; static;
    class function LF_ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean; overload; static;
    class function LF_ReadString(Hnd: TDataHnd___; out Value: string): boolean; overload; static;

    // Typed reads (no out)
    class function LF_ReadInt8(Hnd: TDataHnd___): int8; overload; static;
    class function LF_ReadUInt8(Hnd: TDataHnd___): uint8; overload; static;
    class function LF_ReadInt16(Hnd: TDataHnd___): int16; overload; static;
    class function LF_ReadUInt16(Hnd: TDataHnd___): uint16; overload; static;
    class function LF_ReadInt32(Hnd: TDataHnd___): int32; overload; static;
    class function LF_ReadUInt32(Hnd: TDataHnd___): uint32; overload; static;
    class function LF_ReadInt64(Hnd: TDataHnd___): int64; overload; static;
    class function LF_ReadUInt64(Hnd: TDataHnd___): uint64; overload; static;
    class function LF_ReadSingle(Hnd: TDataHnd___): single; overload; static;
    class function LF_ReadDouble(Hnd: TDataHnd___): double; overload; static;
    class function LF_ReadStringBytes(Hnd: TDataHnd___): TBytes; overload; static;
    class function LF_ReadString(Hnd: TDataHnd___): string; overload; static;

    // App handle
    class function LF_CreateApp(AppName, Desc: pansichar): TAppHnd___; static;
    class function LF_CreateAppEx(AppName, Desc: string): TAppHnd___; static;
    class procedure LF_FreeApp(appHnd: TAppHnd___); static;
    class function LF_Generate_AppName(): pansichar; static;
    class function LF_Generate_AppNameEx(): string; static;
    class function LF_Get_AppName(appHnd: TAppHnd___): pansichar; static;
    class function LF_Get_AppNameEx(appHnd: TAppHnd___): string; static;
    class function LF_BindApp(appHnd: TAppHnd___): integer; static;

    // API registration (app-bound)
    class function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer; static;
    class function LF_RegisterCallEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer; static;
    class function LF_RegisterCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer; static;
    class function LF_RegisterSyncCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer; static;
    class function LF_RegisterCall_P(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_P): integer; static;
    class function LF_RegisterSyncCall_P(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_P): integer; static;

    class function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer; static;
    class function LF_RegisterNotifyEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer; static;
    class function LF_RegisterNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer; static;
    class function LF_RegisterSyncNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer; static;
    class function LF_RegisterNotify_P(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_P): integer; static;
    class function LF_RegisterSyncNotify_P(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_P): integer; static;

    class function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): integer; static;
    class function LF_UnregisterEx(appHnd: TAppHnd___; MethodName: string): integer; static;

    // API registration (P2P)
    class function LF_Register_P2P_Call(MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer; static;
    class function LF_Register_P2P_CallEx(MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer; static;
    class function LF_Register_P2P_Call_M(MethodName, Desc: string; OnCall: TLF_Call_M): integer; static;
    class function LF_Register_P2P_SyncCall_M(MethodName, Desc: string; OnCall: TLF_Call_M): integer; static;
    class function LF_Register_P2P_Call_P(MethodName, Desc: string; OnCall: TLF_Call_P): integer; static;
    class function LF_Register_P2P_SyncCall_P(MethodName, Desc: string; OnCall: TLF_Call_P): integer; static;

    class function LF_Register_P2P_Notify(MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer; static;
    class function LF_Register_P2P_NotifyEx(MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer; static;
    class function LF_Register_P2P_Notify_M(MethodName, Desc: string; OnNotify: TLF_Notify_M): integer; static;
    class function LF_Register_P2P_SyncNotify_M(MethodName, Desc: string; OnNotify: TLF_Notify_M): integer; static;
    class function LF_Register_P2P_Notify_P(MethodName, Desc: string; OnNotify: TLF_Notify_P): integer; static;
    class function LF_Register_P2P_SyncNotify_P(MethodName, Desc: string; OnNotify: TLF_Notify_P): integer; static;

    class function LF_Unregister_P2P(MethodName: pansichar): integer; static;
    class function LF_Unregister_P2PEx(MethodName: string): integer; static;

    // Local execution
    class function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___; static;
    class procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___); static;

    // Network preparation
    class procedure LF_ResetPrepare; static;
    class function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): integer; static;
    class function LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_: string): integer; static;
    class function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): integer; static;
    class function LF_PrepareClientEx(PhysicsAddr_: string; appHnd: TAppHnd___): integer; overload; static;
    class function LF_PrepareClientEx(PhysicsAddr_: string): integer; overload; static;
    class function LF_PrepareDone: integer; static;
    class procedure LF_ExitMainThread; static;

    // Remote invocation by App name
    class function LF_Call(AppName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; static;
    class function LF_CallEx(AppName: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; static;
    class function LF_Async_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_Async_CallEx(appName: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_Async_Call_P(appName: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer; static;
    class function LF_Async_Sequenced_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_Async_Sequenced_CallEx(appName: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_Async_Sequenced_Call_P(appName: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer; static;
    class procedure LF_Notify(appName: pansichar; Param: TDataHnd___); static;
    class procedure LF_NotifyEx(appName: string; Param: TDataHnd___); static;
    class procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___); static;
    class procedure LF_Sequenced_NotifyEx(appName: string; Param: TDataHnd___); static;

    // Remote invocation by UID
    class function LF_UID_Call(UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; static;
    class function LF_UID_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; static;
    class function LF_UID_Async_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_UID_Async_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_UID_Async_Call_P(const UID: TP2P_UID___; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer; static;
    class function LF_UID_Async_Sequenced_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_UID_Async_Sequenced_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_UID_Async_Sequenced_Call_P(const UID: TP2P_UID___; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer; static;
    class procedure LF_UID_Notify(UID: TP2P_UID___; Param: TDataHnd___); static;
    class procedure LF_UID_NotifyEx(const UID: TP2P_UID___; Param: TDataHnd___); static;
    class procedure LF_UID_Sequenced_Notify(UID: TP2P_UID___; Param: TDataHnd___); static;
    class procedure LF_UID_Sequenced_NotifyEx(const UID: TP2P_UID___; Param: TDataHnd___); static;

    // Remote invocation by P2P name
    class function LF_P2PNAME_Call(p2p_name_: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; static;
    class function LF_P2PNAME_CallEx(p2p_name_: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; static;
    class function LF_P2PNAME_Async_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_P2PNAME_Async_CallEx(p2p_name_: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_P2PNAME_Async_Call_P(p2p_name_: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer; static;
    class function LF_P2PNAME_Async_Sequenced_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_P2PNAME_Async_Sequenced_CallEx(p2p_name_: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer; static;
    class function LF_P2PNAME_Async_Sequenced_Call_P(p2p_name_: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer; static;
    class procedure LF_P2PNAME_Notify(p2p_name_: pansichar; Param: TDataHnd___); static;
    class procedure LF_P2PNAME_NotifyEx(p2p_name_: string; Param: TDataHnd___); static;
    class procedure LF_P2PNAME_Sequenced_Notify(p2p_name_: pansichar; Param: TDataHnd___); static;
    class procedure LF_P2PNAME_Sequenced_NotifyEx(p2p_name_: string; Param: TDataHnd___); static;

    // Queries
    class function LF_CheckMainThread(): integer; static;
    class function LF_CheckMainThreadEx(): boolean; static;
    class function LF_CheckApp(appName: pansichar): integer; static;
    class function LF_CheckAppEx(appName: string): boolean; static;
    class function LF_CheckApi(appName, apiName: pansichar): integer; static;
    class function LF_CheckApiEx(appName, apiName: string): boolean; static;
    class function LF_Check_UID(UID: TP2P_UID___): integer; static;
    class function LF_Check_UIDEx(const UID: TP2P_UID___): boolean; static;
    class function LF_Check_UID_Api(UID: TP2P_UID___; apiName: pansichar): integer; static;
    class function LF_Check_UID_ApiEx(const UID: TP2P_UID___; apiName: string): boolean; static;
    class function LF_Check_P2PNAME(p2p_name_: pansichar): integer; static;
    class function LF_Check_P2PNAMEEx(p2p_name_: string): boolean; static;
    class function LF_Check_P2PNAME_Api(p2p_name_, apiName: pansichar): integer; static;
    class function LF_Check_P2PNAME_ApiEx(p2p_name_, apiName: string): boolean; static;

    // Options / Status
    class procedure LF_SetOption(Option, Value: pansichar); static;
    class procedure LF_SetOptionEx(Option, Value: string); static;
    class function LF_GetOption(Option: pansichar): pansichar; static;
    class function LF_GetOptionEx(Option: string): string; static;
    class procedure LF_Set_Opt_Debug(const Value: string); static;
    class procedure LF_Set_Opt_P2P_Name(const Value: string); static;
    class procedure LF_Set_Opt_Password(const Value: string); static;
    class procedure LF_Set_Opt_Quiet(const Value: Boolean); static;
    class procedure LF_Set_Opt_Overlap_Connection(const Value: Boolean); static;
    class procedure LF_Set_Opt_Wait_Connection_ReadyOk(const Value: Boolean); static;
    class procedure LF_Set_Opt_Wait_Connection_Timeout(const Value: uint64); static;
    class procedure LF_Set_Opt_ShowThreadID(const Value: Boolean); static;
    class procedure LF_Set_Opt_ConsoleOutput(const Value: Boolean); static;
    class procedure LF_Set_Opt_IPC_Serv_ThreadCount(const Value: Integer); static;
    class procedure LF_Set_Opt_IPC_Serv_MaxQueueLength(const Value: Integer); static;
    class procedure LF_Set_Opt_IPC_Serv_MaxMsgSize(const Value: Integer); static;
    class procedure LF_Set_Opt_Fixed_Sequenced_Time(const Value: uint64); static;
    class procedure LF_Set_Opt_DataHandle_Idle_Timeout(const Value: uint64); static;
    class procedure LF_Set_Opt_DataHandle_Pool_Scan_Interval(const Value: uint64); static;
    class procedure LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(const Value: Integer); static;
    class function LF_Get_Opt_Debug: string; static;
    class function LF_Get_Opt_P2P_Name: string; static;
    class function LF_Get_Opt_Password: string; static;
    class function LF_Get_Opt_Quiet: Boolean; static;
    class function LF_Get_Opt_Overlap_Connection: Boolean; static;
    class function LF_Get_Opt_Wait_Connection_ReadyOk: Boolean; static;
    class function LF_Get_Opt_Wait_Connection_Timeout: uint64; static;
    class function LF_Get_Opt_ShowThreadID: Boolean; static;
    class function LF_Get_Opt_ConsoleOutput: Boolean; static;
    class function LF_Get_Opt_IPC_Serv_ThreadCount: Integer; static;
    class function LF_Get_Opt_IPC_Serv_MaxQueueLength: Integer; static;
    class function LF_Get_Opt_IPC_Serv_MaxMsgSize: Integer; static;
    class function LF_Get_Opt_Fixed_Sequenced_Time: uint64; static;
    class function LF_Get_Opt_DataHandle_Idle_Timeout: uint64; static;
    class function LF_Get_Opt_DataHandle_Pool_Scan_Interval: uint64; static;
    class function LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold: Integer; static;
    class function LF_GetStatusCount(): integer; static;
    class function LF_GetStatus(): pansichar; static;
    class function LF_GetStatusEx(): string; static;
    class procedure LF_PostStatus(status: pansichar); static;
    class procedure LF_PostStatusEx(status: string); static;

    // Network events
    class procedure LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event); static;

    // Sync / Shutdown
    class function LF_Sync(): integer; static;
    class procedure LF_Shutdown; static;
  end;

  LingoFuse___ = LF___;

implementation

// ----------------------------------------------------------------------------
// LF.TDataHandle
// ----------------------------------------------------------------------------

function LF.TDataHandle.IsValid: boolean;
begin
  Result := (FHandle <> nil) and not FDisposed;
end;

constructor LF.TDataHandle.Create(const MethodName: string);
begin
  inherited Create;
  FHandle := LF_CreateDataEx(MethodName);
  FOwned := True;
  FDisposed := False;
  FLock := TCritical.Create;
end;

constructor LF.TDataHandle.Create_Permanent(const MethodName: string);
begin
  inherited Create;
  FHandle := LF_CreateData_PermanentEx(MethodName);
  FOwned := True;
  FDisposed := False;
  FLock := TCritical.Create;
end;

constructor LF.TDataHandle.Create(AHandle: TDataHnd___; const Owned: boolean = False);
begin
  inherited Create;
  FHandle := AHandle;
  FOwned := Owned;
  FDisposed := False;
  FLock := TCritical.Create;
end;

destructor LF.TDataHandle.Destroy;
begin
  FLock.Enter;
  try
    if not FDisposed then
    begin
      if FOwned and (FHandle <> nil) then
        LF_FreeData(FHandle);
      FHandle := nil;
      FDisposed := True;
    end;
  finally
    FLock.Leave;
  end;
  FLock.Free;
  inherited;
end;

function LF.TDataHandle.WriteBuffer(const Buffer; Size: int64): int64;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_WriteBuffer(FHandle, @Buffer, Size);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadBuffer(var Buffer; Size: int64): int64;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadBuffer(FHandle, @Buffer, Size);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteInt8(Value: int8): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteInt8(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteUInt8(Value: uint8): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteUInt8(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteInt16(Value: int16): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteInt16(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteUInt16(Value: uint16): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteUInt16(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteInt32(Value: int32): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteInt32(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteUInt32(Value: uint32): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteUInt32(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteInt64(Value: int64): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteInt64(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteUInt64(Value: uint64): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteUInt64(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteSingle(Value: single): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteSingle(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteDouble(Value: double): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteDouble(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteStringNullTerminated(const Value: string): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteString(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.WriteString(const Value: string): TDataHandle;
begin
  Result := WriteStringNullTerminated(Value);
end;

function LF.TDataHandle.WriteStringBytes(const Value: TBytes): TDataHandle;
begin
  FLock.Enter;
  try
    if IsValid then LF_WriteStringBytes(FHandle, Value);
    Result := Self;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt8(var Value: int8): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadInt8(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt8(var Value: uint8): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadUInt8(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt16(var Value: int16): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadInt16(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt16(var Value: uint16): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadUInt16(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt32(var Value: int32): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadInt32(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt32(var Value: uint32): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadUInt32(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt64(var Value: int64): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadInt64(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt64(var Value: uint64): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadUInt64(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadSingle(var Value: single): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadSingle(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadDouble(var Value: double): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadDouble(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt8: int8;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadInt8(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt8: uint8;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadUInt8(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt16: int16;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadInt16(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt16: uint16;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadUInt16(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt32: int32;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadInt32(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt32: uint32;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadUInt32(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadInt64: int64;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadInt64(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadUInt64: uint64;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_ReadUInt64(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadSingle: single;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0.0 else Result := LF_ReadSingle(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadDouble: double;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0.0 else Result := LF_ReadDouble(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadStringBytes(out Buff: TBytes): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then Result := False else Result := LF_ReadStringBytes(FHandle, Buff);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadStringBytes(): TBytes;
begin
  FLock.Enter;
  try
    if not IsValid then SetLength(Result, 0) else Result := LF_ReadStringBytes(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadStringNullTerminated: string;
begin
  FLock.Enter;
  try
    if not IsValid then Result := '' else Result := LF_ReadString(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadString(out Value: string): boolean;
begin
  FLock.Enter;
  try
    if not IsValid then
    begin
      Value := '';
      Result := False;
    end
    else
      Result := LF_ReadString(FHandle, Value);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.ReadString(): string;
begin
  Result := ReadStringNullTerminated();
end;

function LF.TDataHandle.GetPos: int64;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_GetPos(FHandle);
  finally
    FLock.Leave;
  end;
end;

procedure LF.TDataHandle.SetPos(Pos_: int64);
begin
  FLock.Enter;
  try
    if IsValid then LF_SetPos(FHandle, Pos_);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.GetSize: int64;
begin
  FLock.Enter;
  try
    if not IsValid then Result := 0 else Result := LF_GetSize(FHandle);
  finally
    FLock.Leave;
  end;
end;

procedure LF.TDataHandle.SetSize(Size_: int64);
begin
  FLock.Enter;
  try
    if IsValid then LF_SetSize(FHandle, Size_);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.GetBufferEx(out Size: int64): Pointer;
begin
  FLock.Enter;
  try
    if not IsValid then
    begin
      Size := 0;
      Result := nil;
    end
    else
    begin
      Result := LF_GetBuffer(FHandle);
      Size := LF_GetSize(FHandle);
    end;
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.GetBuffer(): Pointer;
begin
  FLock.Enter;
  try
    if not IsValid then Result := nil else Result := LF_GetBuffer(FHandle);
  finally
    FLock.Leave;
  end;
end;

function LF.TDataHandle.GetBufferOffset(Offset: nativeint): Pointer;
begin
  Result := LF_GetBufferOffset(FHandle, Offset);
end;

function LF.TDataHandle.Get_P2P_UID: PP2P_UID___;
begin
  Result := LF_Get_P2P_UID(FHandle);
end;

function LF.TDataHandle.Get_P2P_Name: string;
begin
  Result := LF_Get_P2P_NameEx(FHandle);
end;

// ----------------------------------------------------------------------------
// LF.TAppHandle
// ----------------------------------------------------------------------------

constructor LF.TAppHandle.Create(const AppName, Desc: string);
begin
  inherited Create;
  FHandle := LF_CreateAppEx(AppName, Desc);
  FName := AppName;
end;

destructor LF.TAppHandle.Destroy;
begin
  if FHandle <> nil then LF_FreeApp(FHandle);
  inherited;
end;

function LF.TAppHandle.Bind: integer;
begin
  if FHandle = nil then Result := 0 else Result := LF_BindApp(FHandle);
end;

function LF.TAppHandle.RegisterCall(const MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterCallEx(FHandle, MethodName, Desc, Trigger, OnCall) = 1;
end;

function LF.TAppHandle.RegisterCall(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterCall_M(FHandle, MethodName, Desc, OnCall) = 1;
end;

function LF.TAppHandle.RegisterCallSync(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterSyncCall_M(FHandle, MethodName, Desc, OnCall) = 1;
end;

function LF.TAppHandle.RegisterCall_P(const MethodName, Desc: string; OnCall: TLF_Call_P): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterCall_P(FHandle, MethodName, Desc, OnCall) = 1;
end;

function LF.TAppHandle.RegisterCallSync_P(const MethodName, Desc: string; OnCall: TLF_Call_P): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterSyncCall_P(FHandle, MethodName, Desc, OnCall) = 1;
end;

function LF.TAppHandle.RegisterNotify(const MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterNotifyEx(FHandle, MethodName, Desc, Trigger, OnNotify) = 1;
end;

function LF.TAppHandle.RegisterNotify(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterNotify_M(FHandle, MethodName, Desc, OnNotify) = 1;
end;

function LF.TAppHandle.RegisterNotifySync(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterSyncNotify_M(FHandle, MethodName, Desc, OnNotify) = 1;
end;

function LF.TAppHandle.RegisterNotify_P(const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterNotify_P(FHandle, MethodName, Desc, OnNotify) = 1;
end;

function LF.TAppHandle.RegisterNotifySync_P(const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_RegisterSyncNotify_P(FHandle, MethodName, Desc, OnNotify) = 1;
end;

function LF.TAppHandle.Unregister(const MethodName: string): boolean;
begin
  if FHandle = nil then Result := False else Result := LF_UnregisterEx(FHandle, MethodName) = 1;
end;

function LF.TAppHandle.LocalCall(Param: TDataHandle): TDataHandle;
var
  Res: TDataHnd___;
begin
  if FHandle = nil then Result := TDataHandle.Create(nil, True)
  else
  begin
    Res := LF_LocalCall(FHandle, Param.Handle);
    Result := TDataHandle.Create(Res, True);
  end;
end;

procedure LF.TAppHandle.LocalNotify(Param: TDataHandle);
begin
  if FHandle <> nil then LF_LocalNotify(FHandle, Param.Handle);
end;

// ----------------------------------------------------------------------------
// LF class methods - data handle
// ----------------------------------------------------------------------------

class function LF.CreateData(const MethodName: string): TDataHandle;
begin Result := TDataHandle.Create(MethodName); end;

class function LF.CreateData_Permanent(const MethodName: string): TDataHandle;
begin Result := TDataHandle.Create_Permanent(MethodName); end;

class procedure LF.FreeData(Hnd: TDataHnd___);
begin LF_FreeData(Hnd); end;

class function LF.GetBuffer(Hnd: TDataHnd___): Pointer;
begin Result := LF_GetBuffer(Hnd); end;

class function LF.GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer;
begin Result := LF_GetBufferOffset(Hnd, Offset); end;

class function LF.WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin Result := LF_WriteBuffer(Hnd, Buff, Size); end;

class function LF.ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin Result := LF_ReadBuffer(Hnd, Buff, Size); end;

class function LF.GetPos(Hnd: TDataHnd___): int64;
begin Result := LF_GetPos(Hnd); end;

class procedure LF.SetPos(Hnd: TDataHnd___; Pos_: int64);
begin LF_SetPos(Hnd, Pos_); end;

class function LF.GetSize(Hnd: TDataHnd___): int64;
begin Result := LF_GetSize(Hnd); end;

class procedure LF.SetSize(Hnd: TDataHnd___; Size_: int64);
begin LF_SetSize(Hnd, Size_); end;

class function LF.Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
begin Result := LF_Get_P2P_UID(Hnd); end;

class function LF.Get_P2P_Name(Hnd: TDataHnd___): string;
begin Result := LF_Get_P2P_NameEx(Hnd); end;

// Typed writes
class function LF.WriteInt8(Hnd: TDataHnd___; Value: int8): boolean;
begin Result := LF_WriteInt8(Hnd, Value); end;

class function LF.WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean;
begin Result := LF_WriteUInt8(Hnd, Value); end;

class function LF.WriteInt16(Hnd: TDataHnd___; Value: int16): boolean;
begin Result := LF_WriteInt16(Hnd, Value); end;

class function LF.WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean;
begin Result := LF_WriteUInt16(Hnd, Value); end;

class function LF.WriteInt32(Hnd: TDataHnd___; Value: int32): boolean;
begin Result := LF_WriteInt32(Hnd, Value); end;

class function LF.WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean;
begin Result := LF_WriteUInt32(Hnd, Value); end;

class function LF.WriteInt64(Hnd: TDataHnd___; Value: int64): boolean;
begin Result := LF_WriteInt64(Hnd, Value); end;

class function LF.WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean;
begin Result := LF_WriteUInt64(Hnd, Value); end;

class function LF.WriteSingle(Hnd: TDataHnd___; Value: single): boolean;
begin Result := LF_WriteSingle(Hnd, Value); end;

class function LF.WriteDouble(Hnd: TDataHnd___; Value: double): boolean;
begin Result := LF_WriteDouble(Hnd, Value); end;

class function LF.WriteString(Hnd: TDataHnd___; const Value: string): boolean;
begin Result := LF_WriteString(Hnd, Value); end;

class function LF.WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean;
begin Result := LF_WriteStringBytes(Hnd, Value); end;

// Typed reads (out)
class function LF.ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean;
begin Result := LF_ReadInt8(Hnd, Value); end;

class function LF.ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean;
begin Result := LF_ReadUInt8(Hnd, Value); end;

class function LF.ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean;
begin Result := LF_ReadInt16(Hnd, Value); end;

class function LF.ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean;
begin Result := LF_ReadUInt16(Hnd, Value); end;

class function LF.ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean;
begin Result := LF_ReadInt32(Hnd, Value); end;

class function LF.ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean;
begin Result := LF_ReadUInt32(Hnd, Value); end;

class function LF.ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean;
begin Result := LF_ReadInt64(Hnd, Value); end;

class function LF.ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean;
begin Result := LF_ReadUInt64(Hnd, Value); end;

class function LF.ReadSingle(Hnd: TDataHnd___; out Value: single): boolean;
begin Result := LF_ReadSingle(Hnd, Value); end;

class function LF.ReadDouble(Hnd: TDataHnd___; out Value: double): boolean;
begin Result := LF_ReadDouble(Hnd, Value); end;

class function LF.ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean;
begin Result := LF_ReadStringBytes(Hnd, Buff); end;

class function LF.ReadString(Hnd: TDataHnd___; out Value: string): boolean;
begin Result := LF_ReadString(Hnd, Value); end;

// Typed reads (no out)
class function LF.ReadInt8(Hnd: TDataHnd___): int8;
begin Result := LF_ReadInt8(Hnd); end;

class function LF.ReadUInt8(Hnd: TDataHnd___): uint8;
begin Result := LF_ReadUInt8(Hnd); end;

class function LF.ReadInt16(Hnd: TDataHnd___): int16;
begin Result := LF_ReadInt16(Hnd); end;

class function LF.ReadUInt16(Hnd: TDataHnd___): uint16;
begin Result := LF_ReadUInt16(Hnd); end;

class function LF.ReadInt32(Hnd: TDataHnd___): int32;
begin Result := LF_ReadInt32(Hnd); end;

class function LF.ReadUInt32(Hnd: TDataHnd___): uint32;
begin Result := LF_ReadUInt32(Hnd); end;

class function LF.ReadInt64(Hnd: TDataHnd___): int64;
begin Result := LF_ReadInt64(Hnd); end;

class function LF.ReadUInt64(Hnd: TDataHnd___): uint64;
begin Result := LF_ReadUInt64(Hnd); end;

class function LF.ReadSingle(Hnd: TDataHnd___): single;
begin Result := LF_ReadSingle(Hnd); end;

class function LF.ReadDouble(Hnd: TDataHnd___): double;
begin Result := LF_ReadDouble(Hnd); end;

class function LF.ReadStringBytes(Hnd: TDataHnd___): TBytes;
begin Result := LF_ReadStringBytes(Hnd); end;

class function LF.ReadString(Hnd: TDataHnd___): string;
begin Result := LF_ReadString(Hnd); end;

// ----------------------------------------------------------------------------
// LF class methods - app handle
// ----------------------------------------------------------------------------

class function LF.CreateApp(const AppName, Desc: string): TAppHandle;
begin Result := TAppHandle.Create(AppName, Desc); end;

class procedure LF.FreeApp(App: TAppHandle);
begin if App <> nil then App.Free; end;

class function LF.Generate_AppName: string;
begin Result := LF_Generate_AppNameEx(); end;

class function LF.Get_AppName(App: TAppHandle): string;
begin if App = nil then Result := '' else Result := LF_Get_AppNameEx(App.Handle); end;

class function LF.BindApp(App: TAppHandle): integer;
begin if App = nil then Result := 0 else Result := LF_BindApp(App.Handle); end;

// API registration (app-bound)
class function LF.RegisterCall(App: TAppHandle; const MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): boolean;
begin if App = nil then Result := False else Result := App.RegisterCall(MethodName, Desc, Trigger, OnCall); end;

class function LF.RegisterCall(App: TAppHandle; const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
begin if App = nil then Result := False else Result := App.RegisterCall(MethodName, Desc, OnCall); end;

class function LF.RegisterCallSync(App: TAppHandle; const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
begin if App = nil then Result := False else Result := App.RegisterCallSync(MethodName, Desc, OnCall); end;

class function LF.RegisterCall_P(App: TAppHandle; const MethodName, Desc: string; OnCall: TLF_Call_P): boolean;
begin if App = nil then Result := False else Result := App.RegisterCall_P(MethodName, Desc, OnCall); end;

class function LF.RegisterCallSync_P(App: TAppHandle; const MethodName, Desc: string; OnCall: TLF_Call_P): boolean;
begin if App = nil then Result := False else Result := App.RegisterCallSync_P(MethodName, Desc, OnCall); end;

class function LF.RegisterNotify(App: TAppHandle; const MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): boolean;
begin if App = nil then Result := False else Result := App.RegisterNotify(MethodName, Desc, Trigger, OnNotify); end;

class function LF.RegisterNotify(App: TAppHandle; const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
begin if App = nil then Result := False else Result := App.RegisterNotify(MethodName, Desc, OnNotify); end;

class function LF.RegisterNotifySync(App: TAppHandle; const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
begin if App = nil then Result := False else Result := App.RegisterNotifySync(MethodName, Desc, OnNotify); end;

class function LF.RegisterNotify_P(App: TAppHandle; const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean;
begin if App = nil then Result := False else Result := App.RegisterNotify_P(MethodName, Desc, OnNotify); end;

class function LF.RegisterNotifySync_P(App: TAppHandle; const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean;
begin if App = nil then Result := False else Result := App.RegisterNotifySync_P(MethodName, Desc, OnNotify); end;

class function LF.Unregister(App: TAppHandle; const MethodName: string): boolean;
begin if App = nil then Result := False else Result := App.Unregister(MethodName); end;

class function LF.LocalCall(App: TAppHandle; Param: TDataHandle): TDataHandle;
begin if App = nil then Result := TDataHandle.Create(nil, True) else Result := App.LocalCall(Param); end;

class procedure LF.LocalNotify(App: TAppHandle; Param: TDataHandle);
begin if App <> nil then App.LocalNotify(Param); end;

// API registration (P2P)
class function LF.Register_P2P_Call(const MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): boolean;
begin Result := LF_Register_P2P_CallEx(MethodName, Desc, Trigger, OnCall) = 1; end;

class function LF.Register_P2P_Call(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
begin Result := LF_Register_P2P_Call_M(MethodName, Desc, OnCall) = 1; end;

class function LF.Register_P2P_CallSync(const MethodName, Desc: string; OnCall: TLF_Call_M): boolean;
begin Result := LF_Register_P2P_SyncCall_M(MethodName, Desc, OnCall) = 1; end;

class function LF.Register_P2P_Call_P(const MethodName, Desc: string; OnCall: TLF_Call_P): boolean;
begin Result := LF_Register_P2P_Call_P(MethodName, Desc, OnCall) = 1; end;

class function LF.Register_P2P_CallSync_P(const MethodName, Desc: string; OnCall: TLF_Call_P): boolean;
begin Result := LF_Register_P2P_SyncCall_P(MethodName, Desc, OnCall) = 1; end;

class function LF.Register_P2P_Notify(const MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): boolean;
begin Result := LF_Register_P2P_NotifyEx(MethodName, Desc, Trigger, OnNotify) = 1; end;

class function LF.Register_P2P_Notify(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
begin Result := LF_Register_P2P_Notify_M(MethodName, Desc, OnNotify) = 1; end;

class function LF.Register_P2P_NotifySync(const MethodName, Desc: string; OnNotify: TLF_Notify_M): boolean;
begin Result := LF_Register_P2P_SyncNotify_M(MethodName, Desc, OnNotify) = 1; end;

class function LF.Register_P2P_Notify_P(const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean;
begin Result := LF_Register_P2P_Notify_P(MethodName, Desc, OnNotify) = 1; end;

class function LF.Register_P2P_NotifySync_P(const MethodName, Desc: string; OnNotify: TLF_Notify_P): boolean;
begin Result := LF_Register_P2P_SyncNotify_P(MethodName, Desc, OnNotify) = 1; end;

class function LF.Unregister_P2P(const MethodName: string): boolean;
begin Result := LF_Unregister_P2PEx(MethodName) = 1; end;

// Network preparation
class procedure LF.ResetPrepare;
begin LF_ResetPrepare; end;

class function LF.PrepareService(const ListeningAddr, PhysicsAddr: string): integer;
begin Result := LF_PrepareServiceEx(ListeningAddr, PhysicsAddr); end;

class function LF.PrepareService(const ListeningAddr, PhysicsAddr: string; App: TAppHandle): integer;
begin
  Result := LF_PrepareServiceEx(ListeningAddr, PhysicsAddr);
  if Result <> 0 then PrepareClient(PhysicsAddr, App);
end;

class function LF.PrepareClient(const PhysicsAddr: string; App: TAppHandle): integer;
begin
  if Assigned(App) then Result := LF_PrepareClientEx(PhysicsAddr, App.Handle)
  else Result := LF_PrepareClientEx(PhysicsAddr);
end;

class function LF.PrepareDone: boolean;
begin Result := LF_PrepareDone = 1; end;

class procedure LF.ExitMainThread;
begin LF_ExitMainThread; end;

// Remote invocation by App name
class function LF.CallApp(const AppName: string; Param: TDataHandle; TimeoutMs: uint64): TDataHandle;
var Res: TDataHnd___;
begin Res := LF_CallEx(AppName, Param.Handle, TimeoutMs); Result := TDataHandle.Create(Res, True); end;

class function LF.AsyncCallApp(const AppName: string; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := LF_Async_CallEx(AppName, Param.Handle, Data, OnResult); end;

class function LF.AsyncSequencedCallApp(const AppName: string; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := LF_Async_Sequenced_CallEx(AppName, Param.Handle, Data, OnResult); end;

class function LF.AsyncCallApp_P(const AppName: string; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer;
begin Result := LF_Async_Call_P(AppName, Param.Handle, OnResult); end;

class function LF.AsyncSequencedCallApp_P(const AppName: string; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer;
begin Result := LF_Async_Sequenced_Call_P(AppName, Param.Handle, OnResult); end;

class procedure LF.NotifyApp(const AppName: string; Param: TDataHandle);
begin LF_NotifyEx(AppName, Param.Handle); end;

class procedure LF.SequencedNotifyApp(const AppName: string; Param: TDataHandle);
begin LF_Sequenced_NotifyEx(AppName, Param.Handle); end;

// Remote invocation by UID
class function LF.CallUID(const UID: TP2P_UID___; Param: TDataHandle; TimeoutMs: uint64): TDataHandle;
var Res: TDataHnd___;
begin Res := LF_UID_CallEx(UID, Param.Handle, TimeoutMs); Result := TDataHandle.Create(Res, True); end;

class function LF.AsyncCallUID(const UID: TP2P_UID___; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := LF_UID_Async_CallEx(UID, Param.Handle, Data, OnResult); end;

class function LF.AsyncSequencedCallUID(const UID: TP2P_UID___; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := LF_UID_Async_Sequenced_CallEx(UID, Param.Handle, Data, OnResult); end;

class function LF.AsyncCallUID_P(const UID: TP2P_UID___; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer;
begin Result := LF_UID_Async_Call_P(UID, Param.Handle, OnResult); end;

class function LF.AsyncSequencedCallUID_P(const UID: TP2P_UID___; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer;
begin Result := LF_UID_Async_Sequenced_Call_P(UID, Param.Handle, OnResult); end;

class procedure LF.NotifyUID(const UID: TP2P_UID___; Param: TDataHandle);
begin LF_UID_NotifyEx(UID, Param.Handle); end;

class procedure LF.SequencedNotifyUID(const UID: TP2P_UID___; Param: TDataHandle);
begin LF_UID_Sequenced_NotifyEx(UID, Param.Handle); end;

// Remote invocation by P2P name
class function LF.CallP2PName(const p2p_name: string; Param: TDataHandle; TimeoutMs: uint64): TDataHandle;
var Res: TDataHnd___;
begin Res := LF_P2PNAME_CallEx(p2p_name, Param.Handle, TimeoutMs); Result := TDataHandle.Create(Res, True); end;

class function LF.AsyncCallP2PName(const p2p_name: string; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := LF_P2PNAME_Async_CallEx(p2p_name, Param.Handle, Data, OnResult); end;

class function LF.AsyncSequencedCallP2PName(const p2p_name: string; Param: TDataHandle; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := LF_P2PNAME_Async_Sequenced_CallEx(p2p_name, Param.Handle, Data, OnResult); end;

class function LF.AsyncCallP2PName_P(const p2p_name: string; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer;
begin Result := LF_P2PNAME_Async_Call_P(p2p_name, Param.Handle, OnResult); end;

class function LF.AsyncSequencedCallP2PName_P(const p2p_name: string; Param: TDataHandle; OnResult: TLF_Async_Call_P): integer;
begin Result := LF_P2PNAME_Async_Sequenced_Call_P(p2p_name, Param.Handle, OnResult); end;

class procedure LF.NotifyP2PName(const p2p_name: string; Param: TDataHandle);
begin LF_P2PNAME_NotifyEx(p2p_name, Param.Handle); end;

class procedure LF.SequencedNotifyP2PName(const p2p_name: string; Param: TDataHandle);
begin LF_P2PNAME_Sequenced_NotifyEx(p2p_name, Param.Handle); end;

// Queries
class function LF.CheckMainThread: boolean;
begin Result := LF_CheckMainThreadEx(); end;

class function LF.CheckApp(const AppName: string): boolean;
begin Result := LF_CheckAppEx(AppName); end;

class function LF.CheckApi(AppName, ApiName: string): boolean;
begin Result := LF_CheckApiEx(AppName, ApiName); end;

class function LF.CheckUID(const UID: TP2P_UID___): boolean;
begin Result := LF_Check_UIDEx(UID); end;

class function LF.CheckUIDApi(const UID: TP2P_UID___; ApiName: string): boolean;
begin Result := LF_Check_UID_ApiEx(UID, ApiName); end;

class function LF.CheckP2PName(const p2p_name: string): boolean;
begin Result := LF_Check_P2PNAMEEx(p2p_name); end;

class function LF.CheckP2PNameApi(const p2p_name, ApiName: string): boolean;
begin Result := LF_Check_P2PNAME_ApiEx(p2p_name, ApiName); end;

// Options
class procedure LF.SetOption(const Option, Value: string);
begin LF_SetOptionEx(Option, Value); end;

class function LF.GetOption(const Option: string): string;
begin Result := LF_GetOptionEx(Option); end;

class procedure LF.Set_Opt_Debug(const Value: string);
begin LF_Set_Opt_Debug(Value); end;

class procedure LF.Set_Opt_P2P_Name(const Value: string);
begin LF_Set_Opt_P2P_Name(Value); end;

class procedure LF.Set_Opt_Password(const Value: string);
begin LF_Set_Opt_Password(Value); end;

class procedure LF.Set_Opt_Quiet(const Value: Boolean);
begin LF_Set_Opt_Quiet(Value); end;

class procedure LF.Set_Opt_Overlap_Connection(const Value: Boolean);
begin LF_Set_Opt_Overlap_Connection(Value); end;

class procedure LF.Set_Opt_Wait_Connection_ReadyOk(const Value: Boolean);
begin LF_Set_Opt_Wait_Connection_ReadyOk(Value); end;

class procedure LF.Set_Opt_Wait_Connection_Timeout(const Value: uint64);
begin LF_Set_Opt_Wait_Connection_Timeout(Value); end;

class procedure LF.Set_Opt_ShowThreadID(const Value: Boolean);
begin LF_Set_Opt_ShowThreadID(Value); end;

class procedure LF.Set_Opt_ConsoleOutput(const Value: Boolean);
begin LF_Set_Opt_ConsoleOutput(Value); end;

class procedure LF.Set_Opt_IPC_Serv_ThreadCount(const Value: Integer);
begin LF_Set_Opt_IPC_Serv_ThreadCount(Value); end;

class procedure LF.Set_Opt_IPC_Serv_MaxQueueLength(const Value: Integer);
begin LF_Set_Opt_IPC_Serv_MaxQueueLength(Value); end;

class procedure LF.Set_Opt_IPC_Serv_MaxMsgSize(const Value: Integer);
begin LF_Set_Opt_IPC_Serv_MaxMsgSize(Value); end;

class procedure LF.Set_Opt_Fixed_Sequenced_Time(const Value: uint64);
begin LF_Set_Opt_Fixed_Sequenced_Time(Value); end;

class procedure LF.Set_Opt_DataHandle_Idle_Timeout(const Value: uint64);
begin LF_Set_Opt_DataHandle_Idle_Timeout(Value); end;

class procedure LF.Set_Opt_DataHandle_Pool_Scan_Interval(const Value: uint64);
begin LF_Set_Opt_DataHandle_Pool_Scan_Interval(Value); end;

class procedure LF.Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(const Value: Integer);
begin LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(Value); end;

class function LF.Get_Opt_Debug: string;
begin Result := LF_Get_Opt_Debug; end;

class function LF.Get_Opt_P2P_Name: string;
begin Result := LF_Get_Opt_P2P_Name; end;

class function LF.Get_Opt_Password: string;
begin Result := LF_Get_Opt_Password; end;

class function LF.Get_Opt_Quiet: Boolean;
begin Result := LF_Get_Opt_Quiet; end;

class function LF.Get_Opt_Overlap_Connection: Boolean;
begin Result := LF_Get_Opt_Overlap_Connection; end;

class function LF.Get_Opt_Wait_Connection_ReadyOk: Boolean;
begin Result := LF_Get_Opt_Wait_Connection_ReadyOk; end;

class function LF.Get_Opt_Wait_Connection_Timeout: uint64;
begin Result := LF_Get_Opt_Wait_Connection_Timeout; end;

class function LF.Get_Opt_ShowThreadID: Boolean;
begin Result := LF_Get_Opt_ShowThreadID; end;

class function LF.Get_Opt_ConsoleOutput: Boolean;
begin Result := LF_Get_Opt_ConsoleOutput; end;

class function LF.Get_Opt_IPC_Serv_ThreadCount: Integer;
begin Result := LF_Get_Opt_IPC_Serv_ThreadCount; end;

class function LF.Get_Opt_IPC_Serv_MaxQueueLength: Integer;
begin Result := LF_Get_Opt_IPC_Serv_MaxQueueLength; end;

class function LF.Get_Opt_IPC_Serv_MaxMsgSize: Integer;
begin Result := LF_Get_Opt_IPC_Serv_MaxMsgSize; end;

class function LF.Get_Opt_Fixed_Sequenced_Time: uint64;
begin Result := LF_Get_Opt_Fixed_Sequenced_Time; end;

class function LF.Get_Opt_DataHandle_Idle_Timeout: uint64;
begin Result := LF_Get_Opt_DataHandle_Idle_Timeout; end;

class function LF.Get_Opt_DataHandle_Pool_Scan_Interval: uint64;
begin Result := LF_Get_Opt_DataHandle_Pool_Scan_Interval; end;

class function LF.Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold: Integer;
begin Result := LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold; end;

// Status
class function LF.GetStatus: string;
begin Result := LF_GetStatusEx(); end;

class function LF.Get_Status_Num: integer;
begin Result := LF_GetStatusCount(); end;

class procedure LF.PostStatus(const Status: string);
begin LF_PostStatusEx(Status); end;

// Network events
class procedure LF.Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event);
begin LF_Set_Network_Event(On_Connect_, On_Disconnect_); end;

// Sync / Shutdown
class function LF.Sync: integer;
begin Result := LF_Sync(); end;

class procedure LF.Shutdown;
begin LF_Shutdown; end;

// ----------------------------------------------------------------------------
// LF___ class methods - all raw forwards to lingofuse_import
// ----------------------------------------------------------------------------

class function LF___.LF_CreateData(MethodName: pansichar): TDataHnd___;
begin Result := lingofuse_import.LF_CreateData(MethodName); end;

class function LF___.LF_CreateDataEx(MethodName: string): TDataHnd___;
begin Result := lingofuse_import.LF_CreateDataEx(MethodName); end;

class function LF___.LF_CreateData_Permanent(MethodName: pansichar): TDataHnd___;
begin Result := lingofuse_import.LF_CreateData_Permanent(MethodName); end;

class function LF___.LF_CreateData_PermanentEx(MethodName: string): TDataHnd___;
begin Result := lingofuse_import.LF_CreateData_PermanentEx(MethodName); end;

class procedure LF___.LF_FreeData(Hnd: TDataHnd___);
begin lingofuse_import.LF_FreeData(Hnd); end;

class function LF___.LF_GetBuffer(Hnd: TDataHnd___): Pointer;
begin Result := lingofuse_import.LF_GetBuffer(Hnd); end;

class function LF___.LF_GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer;
begin Result := lingofuse_import.LF_GetBufferOffset(Hnd, Offset); end;

class function LF___.LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin Result := lingofuse_import.LF_WriteBuffer(Hnd, Buff, Size); end;

class function LF___.LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin Result := lingofuse_import.LF_ReadBuffer(Hnd, Buff, Size); end;

class function LF___.LF_GetPos(Hnd: TDataHnd___): int64;
begin Result := lingofuse_import.LF_GetPos(Hnd); end;

class procedure LF___.LF_SetPos(Hnd: TDataHnd___; Pos_: int64);
begin lingofuse_import.LF_SetPos(Hnd, Pos_); end;

class function LF___.LF_GetSize(Hnd: TDataHnd___): int64;
begin Result := lingofuse_import.LF_GetSize(Hnd); end;

class procedure LF___.LF_SetSize(Hnd: TDataHnd___; Size_: int64);
begin lingofuse_import.LF_SetSize(Hnd, Size_); end;

class function LF___.LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
begin Result := lingofuse_import.LF_Get_P2P_UID(Hnd); end;

class function LF___.LF_Get_P2P_Name(Hnd: TDataHnd___): pansichar;
begin Result := lingofuse_import.LF_Get_P2P_Name(Hnd); end;

class function LF___.LF_Get_P2P_NameEx(Hnd: TDataHnd___): string;
begin Result := lingofuse_import.LF_Get_P2P_NameEx(Hnd); end;

// Typed writes
class function LF___.LF_WriteInt8(Hnd: TDataHnd___; Value: int8): boolean;
begin Result := lingofuse_import.LF_WriteInt8(Hnd, Value); end;

class function LF___.LF_WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean;
begin Result := lingofuse_import.LF_WriteUInt8(Hnd, Value); end;

class function LF___.LF_WriteInt16(Hnd: TDataHnd___; Value: int16): boolean;
begin Result := lingofuse_import.LF_WriteInt16(Hnd, Value); end;

class function LF___.LF_WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean;
begin Result := lingofuse_import.LF_WriteUInt16(Hnd, Value); end;

class function LF___.LF_WriteInt32(Hnd: TDataHnd___; Value: int32): boolean;
begin Result := lingofuse_import.LF_WriteInt32(Hnd, Value); end;

class function LF___.LF_WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean;
begin Result := lingofuse_import.LF_WriteUInt32(Hnd, Value); end;

class function LF___.LF_WriteInt64(Hnd: TDataHnd___; Value: int64): boolean;
begin Result := lingofuse_import.LF_WriteInt64(Hnd, Value); end;

class function LF___.LF_WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean;
begin Result := lingofuse_import.LF_WriteUInt64(Hnd, Value); end;

class function LF___.LF_WriteSingle(Hnd: TDataHnd___; Value: single): boolean;
begin Result := lingofuse_import.LF_WriteSingle(Hnd, Value); end;

class function LF___.LF_WriteDouble(Hnd: TDataHnd___; Value: double): boolean;
begin Result := lingofuse_import.LF_WriteDouble(Hnd, Value); end;

class function LF___.LF_WriteString(Hnd: TDataHnd___; const Value: string): boolean;
begin Result := lingofuse_import.LF_WriteString(Hnd, Value); end;

class function LF___.LF_WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean;
begin Result := lingofuse_import.LF_WriteStringBytes(Hnd, Value); end;

// Typed reads (out)
class function LF___.LF_ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean;
begin Result := lingofuse_import.LF_ReadInt8(Hnd, Value); end;

class function LF___.LF_ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean;
begin Result := lingofuse_import.LF_ReadUInt8(Hnd, Value); end;

class function LF___.LF_ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean;
begin Result := lingofuse_import.LF_ReadInt16(Hnd, Value); end;

class function LF___.LF_ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean;
begin Result := lingofuse_import.LF_ReadUInt16(Hnd, Value); end;

class function LF___.LF_ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean;
begin Result := lingofuse_import.LF_ReadInt32(Hnd, Value); end;

class function LF___.LF_ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean;
begin Result := lingofuse_import.LF_ReadUInt32(Hnd, Value); end;

class function LF___.LF_ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean;
begin Result := lingofuse_import.LF_ReadInt64(Hnd, Value); end;

class function LF___.LF_ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean;
begin Result := lingofuse_import.LF_ReadUInt64(Hnd, Value); end;

class function LF___.LF_ReadSingle(Hnd: TDataHnd___; out Value: single): boolean;
begin Result := lingofuse_import.LF_ReadSingle(Hnd, Value); end;

class function LF___.LF_ReadDouble(Hnd: TDataHnd___; out Value: double): boolean;
begin Result := lingofuse_import.LF_ReadDouble(Hnd, Value); end;

class function LF___.LF_ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean;
begin Result := lingofuse_import.LF_ReadStringBytes(Hnd, Buff); end;

class function LF___.LF_ReadString(Hnd: TDataHnd___; out Value: string): boolean;
begin Result := lingofuse_import.LF_ReadString(Hnd, Value); end;

// Typed reads (no out)
class function LF___.LF_ReadInt8(Hnd: TDataHnd___): int8;
begin Result := lingofuse_import.LF_ReadInt8(Hnd); end;

class function LF___.LF_ReadUInt8(Hnd: TDataHnd___): uint8;
begin Result := lingofuse_import.LF_ReadUInt8(Hnd); end;

class function LF___.LF_ReadInt16(Hnd: TDataHnd___): int16;
begin Result := lingofuse_import.LF_ReadInt16(Hnd); end;

class function LF___.LF_ReadUInt16(Hnd: TDataHnd___): uint16;
begin Result := lingofuse_import.LF_ReadUInt16(Hnd); end;

class function LF___.LF_ReadInt32(Hnd: TDataHnd___): int32;
begin Result := lingofuse_import.LF_ReadInt32(Hnd); end;

class function LF___.LF_ReadUInt32(Hnd: TDataHnd___): uint32;
begin Result := lingofuse_import.LF_ReadUInt32(Hnd); end;

class function LF___.LF_ReadInt64(Hnd: TDataHnd___): int64;
begin Result := lingofuse_import.LF_ReadInt64(Hnd); end;

class function LF___.LF_ReadUInt64(Hnd: TDataHnd___): uint64;
begin Result := lingofuse_import.LF_ReadUInt64(Hnd); end;

class function LF___.LF_ReadSingle(Hnd: TDataHnd___): single;
begin Result := lingofuse_import.LF_ReadSingle(Hnd); end;

class function LF___.LF_ReadDouble(Hnd: TDataHnd___): double;
begin Result := lingofuse_import.LF_ReadDouble(Hnd); end;

class function LF___.LF_ReadStringBytes(Hnd: TDataHnd___): TBytes;
begin Result := lingofuse_import.LF_ReadStringBytes(Hnd); end;

class function LF___.LF_ReadString(Hnd: TDataHnd___): string;
begin Result := lingofuse_import.LF_ReadString(Hnd); end;

// App handle
class function LF___.LF_CreateApp(AppName, Desc: pansichar): TAppHnd___;
begin Result := lingofuse_import.LF_CreateApp(AppName, Desc); end;

class function LF___.LF_CreateAppEx(AppName, Desc: string): TAppHnd___;
begin Result := lingofuse_import.LF_CreateAppEx(AppName, Desc); end;

class procedure LF___.LF_FreeApp(appHnd: TAppHnd___);
begin lingofuse_import.LF_FreeApp(appHnd); end;

class function LF___.LF_Generate_AppName(): pansichar;
begin Result := lingofuse_import.LF_Generate_AppName(); end;

class function LF___.LF_Generate_AppNameEx(): string;
begin Result := lingofuse_import.LF_Generate_AppNameEx(); end;

class function LF___.LF_Get_AppName(appHnd: TAppHnd___): pansichar;
begin Result := lingofuse_import.LF_Get_AppName(appHnd); end;

class function LF___.LF_Get_AppNameEx(appHnd: TAppHnd___): string;
begin Result := lingofuse_import.LF_Get_AppNameEx(appHnd); end;

class function LF___.LF_BindApp(appHnd: TAppHnd___): integer;
begin Result := lingofuse_import.LF_BindApp(appHnd); end;

// API registration (app-bound)
class function LF___.LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin Result := lingofuse_import.LF_RegisterCall(appHnd, MethodName, Desc, Trigger, OnCall); end;

class function LF___.LF_RegisterCallEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin Result := lingofuse_import.LF_RegisterCallEx(appHnd, MethodName, Desc, Trigger, OnCall); end;

class function LF___.LF_RegisterCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
begin Result := lingofuse_import.LF_RegisterCall_M(appHnd, MethodName, Desc, OnCall); end;

class function LF___.LF_RegisterSyncCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
begin Result := lingofuse_import.LF_RegisterSyncCall_M(appHnd, MethodName, Desc, OnCall); end;

class function LF___.LF_RegisterCall_P(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_P): integer;
begin Result := lingofuse_import.LF_RegisterCall_P(appHnd, MethodName, Desc, OnCall); end;

class function LF___.LF_RegisterSyncCall_P(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_P): integer;
begin Result := lingofuse_import.LF_RegisterSyncCall_P(appHnd, MethodName, Desc, OnCall); end;

class function LF___.LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin Result := lingofuse_import.LF_RegisterNotify(appHnd, MethodName, Desc, Trigger, OnNotify); end;

class function LF___.LF_RegisterNotifyEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin Result := lingofuse_import.LF_RegisterNotifyEx(appHnd, MethodName, Desc, Trigger, OnNotify); end;

class function LF___.LF_RegisterNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
begin Result := lingofuse_import.LF_RegisterNotify_M(appHnd, MethodName, Desc, OnNotify); end;

class function LF___.LF_RegisterSyncNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
begin Result := lingofuse_import.LF_RegisterSyncNotify_M(appHnd, MethodName, Desc, OnNotify); end;

class function LF___.LF_RegisterNotify_P(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
begin Result := lingofuse_import.LF_RegisterNotify_P(appHnd, MethodName, Desc, OnNotify); end;

class function LF___.LF_RegisterSyncNotify_P(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
begin Result := lingofuse_import.LF_RegisterSyncNotify_P(appHnd, MethodName, Desc, OnNotify); end;

class function LF___.LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): integer;
begin Result := lingofuse_import.LF_Unregister(appHnd, MethodName); end;

class function LF___.LF_UnregisterEx(appHnd: TAppHnd___; MethodName: string): integer;
begin Result := lingofuse_import.LF_UnregisterEx(appHnd, MethodName); end;

// API registration (P2P)
class function LF___.LF_Register_P2P_Call(MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin Result := lingofuse_import.LF_Register_P2P_Call(MethodName, Desc, Trigger, OnCall); end;

class function LF___.LF_Register_P2P_CallEx(MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin Result := lingofuse_import.LF_Register_P2P_CallEx(MethodName, Desc, Trigger, OnCall); end;

class function LF___.LF_Register_P2P_Call_M(MethodName, Desc: string; OnCall: TLF_Call_M): integer;
begin Result := lingofuse_import.LF_Register_P2P_Call_M(MethodName, Desc, OnCall); end;

class function LF___.LF_Register_P2P_SyncCall_M(MethodName, Desc: string; OnCall: TLF_Call_M): integer;
begin Result := lingofuse_import.LF_Register_P2P_SyncCall_M(MethodName, Desc, OnCall); end;

class function LF___.LF_Register_P2P_Call_P(MethodName, Desc: string; OnCall: TLF_Call_P): integer;
begin Result := lingofuse_import.LF_Register_P2P_Call_P(MethodName, Desc, OnCall); end;

class function LF___.LF_Register_P2P_SyncCall_P(MethodName, Desc: string; OnCall: TLF_Call_P): integer;
begin Result := lingofuse_import.LF_Register_P2P_SyncCall_P(MethodName, Desc, OnCall); end;

class function LF___.LF_Register_P2P_Notify(MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin Result := lingofuse_import.LF_Register_P2P_Notify(MethodName, Desc, Trigger, OnNotify); end;

class function LF___.LF_Register_P2P_NotifyEx(MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin Result := lingofuse_import.LF_Register_P2P_NotifyEx(MethodName, Desc, Trigger, OnNotify); end;

class function LF___.LF_Register_P2P_Notify_M(MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
begin Result := lingofuse_import.LF_Register_P2P_Notify_M(MethodName, Desc, OnNotify); end;

class function LF___.LF_Register_P2P_SyncNotify_M(MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
begin Result := lingofuse_import.LF_Register_P2P_SyncNotify_M(MethodName, Desc, OnNotify); end;

class function LF___.LF_Register_P2P_Notify_P(MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
begin Result := lingofuse_import.LF_Register_P2P_Notify_P(MethodName, Desc, OnNotify); end;

class function LF___.LF_Register_P2P_SyncNotify_P(MethodName, Desc: string; OnNotify: TLF_Notify_P): integer;
begin Result := lingofuse_import.LF_Register_P2P_SyncNotify_P(MethodName, Desc, OnNotify); end;

class function LF___.LF_Unregister_P2P(MethodName: pansichar): integer;
begin Result := lingofuse_import.LF_Unregister_P2P(MethodName); end;

class function LF___.LF_Unregister_P2PEx(MethodName: string): integer;
begin Result := lingofuse_import.LF_Unregister_P2PEx(MethodName); end;

// Local execution
class function LF___.LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___;
begin Result := lingofuse_import.LF_LocalCall(appHnd, Param); end;

class procedure LF___.LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___);
begin lingofuse_import.LF_LocalNotify(appHnd, Param); end;

// Network preparation
class procedure LF___.LF_ResetPrepare;
begin lingofuse_import.LF_ResetPrepare; end;

class function LF___.LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): integer;
begin Result := lingofuse_import.LF_PrepareService(ListeningAddr_, PhysicsAddr_); end;

class function LF___.LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_: string): integer;
begin Result := lingofuse_import.LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_); end;

class function LF___.LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): integer;
begin Result := lingofuse_import.LF_PrepareClient(PhysicsAddr_, appHnd); end;

class function LF___.LF_PrepareClientEx(PhysicsAddr_: string; appHnd: TAppHnd___): integer;
begin Result := lingofuse_import.LF_PrepareClientEx(PhysicsAddr_, appHnd); end;

class function LF___.LF_PrepareClientEx(PhysicsAddr_: string): integer;
begin Result := lingofuse_import.LF_PrepareClientEx(PhysicsAddr_); end;

class function LF___.LF_PrepareDone: integer;
begin Result := lingofuse_import.LF_PrepareDone; end;

class procedure LF___.LF_ExitMainThread;
begin lingofuse_import.LF_ExitMainThread; end;

// Remote invocation by App name
class function LF___.LF_Call(AppName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin Result := lingofuse_import.LF_Call(AppName, Param, Timeout_); end;

class function LF___.LF_CallEx(AppName: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin Result := lingofuse_import.LF_CallEx(AppName, Param, Timeout_); end;

class function LF___.LF_Async_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_Async_Call(appName, Param, Data, OnResult); end;

class function LF___.LF_Async_CallEx(appName: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_Async_CallEx(appName, Param, Data, OnResult); end;

class function LF___.LF_Async_Call_P(appName: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
begin Result := lingofuse_import.LF_Async_Call_P(appName, Param, OnResult); end;

class function LF___.LF_Async_Sequenced_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_Async_Sequenced_Call(appName, Param, Data, OnResult); end;

class function LF___.LF_Async_Sequenced_CallEx(appName: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_Async_Sequenced_CallEx(appName, Param, Data, OnResult); end;

class function LF___.LF_Async_Sequenced_Call_P(appName: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
begin Result := lingofuse_import.LF_Async_Sequenced_Call_P(appName, Param, OnResult); end;

class procedure LF___.LF_Notify(appName: pansichar; Param: TDataHnd___);
begin lingofuse_import.LF_Notify(appName, Param); end;

class procedure LF___.LF_NotifyEx(appName: string; Param: TDataHnd___);
begin lingofuse_import.LF_NotifyEx(appName, Param); end;

class procedure LF___.LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___);
begin lingofuse_import.LF_Sequenced_Notify(appName, Param); end;

class procedure LF___.LF_Sequenced_NotifyEx(appName: string; Param: TDataHnd___);
begin lingofuse_import.LF_Sequenced_NotifyEx(appName, Param); end;

// Remote invocation by UID
class function LF___.LF_UID_Call(UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin Result := lingofuse_import.LF_UID_Call(UID, Param, Timeout_); end;

class function LF___.LF_UID_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin Result := lingofuse_import.LF_UID_CallEx(UID, Param, Timeout_); end;

class function LF___.LF_UID_Async_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_UID_Async_Call(UID, Param, Data, OnResult); end;

class function LF___.LF_UID_Async_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_UID_Async_CallEx(UID, Param, Data, OnResult); end;

class function LF___.LF_UID_Async_Call_P(const UID: TP2P_UID___; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
begin Result := lingofuse_import.LF_UID_Async_Call_P(UID, Param, OnResult); end;

class function LF___.LF_UID_Async_Sequenced_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_UID_Async_Sequenced_Call(UID, Param, Data, OnResult); end;

class function LF___.LF_UID_Async_Sequenced_CallEx(const UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_UID_Async_Sequenced_CallEx(UID, Param, Data, OnResult); end;

class function LF___.LF_UID_Async_Sequenced_Call_P(const UID: TP2P_UID___; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
begin Result := lingofuse_import.LF_UID_Async_Sequenced_Call_P(UID, Param, OnResult); end;

class procedure LF___.LF_UID_Notify(UID: TP2P_UID___; Param: TDataHnd___);
begin lingofuse_import.LF_UID_Notify(UID, Param); end;

class procedure LF___.LF_UID_NotifyEx(const UID: TP2P_UID___; Param: TDataHnd___);
begin lingofuse_import.LF_UID_NotifyEx(UID, Param); end;

class procedure LF___.LF_UID_Sequenced_Notify(UID: TP2P_UID___; Param: TDataHnd___);
begin lingofuse_import.LF_UID_Sequenced_Notify(UID, Param); end;

class procedure LF___.LF_UID_Sequenced_NotifyEx(const UID: TP2P_UID___; Param: TDataHnd___);
begin lingofuse_import.LF_UID_Sequenced_NotifyEx(UID, Param); end;

// Remote invocation by P2P name
class function LF___.LF_P2PNAME_Call(p2p_name_: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin Result := lingofuse_import.LF_P2PNAME_Call(p2p_name_, Param, Timeout_); end;

class function LF___.LF_P2PNAME_CallEx(p2p_name_: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin Result := lingofuse_import.LF_P2PNAME_CallEx(p2p_name_, Param, Timeout_); end;

class function LF___.LF_P2PNAME_Async_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_P2PNAME_Async_Call(p2p_name_, Param, Data, OnResult); end;

class function LF___.LF_P2PNAME_Async_CallEx(p2p_name_: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_P2PNAME_Async_CallEx(p2p_name_, Param, Data, OnResult); end;

class function LF___.LF_P2PNAME_Async_Call_P(p2p_name_: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
begin Result := lingofuse_import.LF_P2PNAME_Async_Call_P(p2p_name_, Param, OnResult); end;

class function LF___.LF_P2PNAME_Async_Sequenced_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_P2PNAME_Async_Sequenced_Call(p2p_name_, Param, Data, OnResult); end;

class function LF___.LF_P2PNAME_Async_Sequenced_CallEx(p2p_name_: string; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): integer;
begin Result := lingofuse_import.LF_P2PNAME_Async_Sequenced_CallEx(p2p_name_, Param, Data, OnResult); end;

class function LF___.LF_P2PNAME_Async_Sequenced_Call_P(p2p_name_: string; Param: TDataHnd___; OnResult: TLF_Async_Call_P): integer;
begin Result := lingofuse_import.LF_P2PNAME_Async_Sequenced_Call_P(p2p_name_, Param, OnResult); end;

class procedure LF___.LF_P2PNAME_Notify(p2p_name_: pansichar; Param: TDataHnd___);
begin lingofuse_import.LF_P2PNAME_Notify(p2p_name_, Param); end;

class procedure LF___.LF_P2PNAME_NotifyEx(p2p_name_: string; Param: TDataHnd___);
begin lingofuse_import.LF_P2PNAME_NotifyEx(p2p_name_, Param); end;

class procedure LF___.LF_P2PNAME_Sequenced_Notify(p2p_name_: pansichar; Param: TDataHnd___);
begin lingofuse_import.LF_P2PNAME_Sequenced_Notify(p2p_name_, Param); end;

class procedure LF___.LF_P2PNAME_Sequenced_NotifyEx(p2p_name_: string; Param: TDataHnd___);
begin lingofuse_import.LF_P2PNAME_Sequenced_NotifyEx(p2p_name_, Param); end;

// Queries
class function LF___.LF_CheckMainThread(): integer;
begin Result := lingofuse_import.LF_CheckMainThread(); end;

class function LF___.LF_CheckMainThreadEx(): boolean;
begin Result := lingofuse_import.LF_CheckMainThreadEx(); end;

class function LF___.LF_CheckApp(appName: pansichar): integer;
begin Result := lingofuse_import.LF_CheckApp(appName); end;

class function LF___.LF_CheckAppEx(appName: string): boolean;
begin Result := lingofuse_import.LF_CheckAppEx(appName); end;

class function LF___.LF_CheckApi(appName, apiName: pansichar): integer;
begin Result := lingofuse_import.LF_CheckApi(appName, apiName); end;

class function LF___.LF_CheckApiEx(appName, apiName: string): boolean;
begin Result := lingofuse_import.LF_CheckApiEx(appName, apiName); end;

class function LF___.LF_Check_UID(UID: TP2P_UID___): integer;
begin Result := lingofuse_import.LF_Check_UID(UID); end;

class function LF___.LF_Check_UIDEx(const UID: TP2P_UID___): boolean;
begin Result := lingofuse_import.LF_Check_UIDEx(UID); end;

class function LF___.LF_Check_UID_Api(UID: TP2P_UID___; apiName: pansichar): integer;
begin Result := lingofuse_import.LF_Check_UID_Api(UID, apiName); end;

class function LF___.LF_Check_UID_ApiEx(const UID: TP2P_UID___; apiName: string): boolean;
begin Result := lingofuse_import.LF_Check_UID_ApiEx(UID, apiName); end;

class function LF___.LF_Check_P2PNAME(p2p_name_: pansichar): integer;
begin Result := lingofuse_import.LF_Check_P2PNAME(p2p_name_); end;

class function LF___.LF_Check_P2PNAMEEx(p2p_name_: string): boolean;
begin Result := lingofuse_import.LF_Check_P2PNAMEEx(p2p_name_); end;

class function LF___.LF_Check_P2PNAME_Api(p2p_name_, apiName: pansichar): integer;
begin Result := lingofuse_import.LF_Check_P2PNAME_Api(p2p_name_, apiName); end;

class function LF___.LF_Check_P2PNAME_ApiEx(p2p_name_, apiName: string): boolean;
begin Result := lingofuse_import.LF_Check_P2PNAME_ApiEx(p2p_name_, apiName); end;

// Options
class procedure LF___.LF_SetOption(Option, Value: pansichar);
begin lingofuse_import.LF_SetOption(Option, Value); end;

class procedure LF___.LF_SetOptionEx(Option, Value: string);
begin lingofuse_import.LF_SetOptionEx(Option, Value); end;

class function LF___.LF_GetOption(Option: pansichar): pansichar;
begin Result := lingofuse_import.LF_GetOption(Option); end;

class function LF___.LF_GetOptionEx(Option: string): string;
begin Result := lingofuse_import.LF_GetOptionEx(Option); end;

class procedure LF___.LF_Set_Opt_Debug(const Value: string);
begin lingofuse_import.LF_Set_Opt_Debug(Value); end;

class procedure LF___.LF_Set_Opt_P2P_Name(const Value: string);
begin lingofuse_import.LF_Set_Opt_P2P_Name(Value); end;

class procedure LF___.LF_Set_Opt_Password(const Value: string);
begin lingofuse_import.LF_Set_Opt_Password(Value); end;

class procedure LF___.LF_Set_Opt_Quiet(const Value: Boolean);
begin lingofuse_import.LF_Set_Opt_Quiet(Value); end;

class procedure LF___.LF_Set_Opt_Overlap_Connection(const Value: Boolean);
begin lingofuse_import.LF_Set_Opt_Overlap_Connection(Value); end;

class procedure LF___.LF_Set_Opt_Wait_Connection_ReadyOk(const Value: Boolean);
begin lingofuse_import.LF_Set_Opt_Wait_Connection_ReadyOk(Value); end;

class procedure LF___.LF_Set_Opt_Wait_Connection_Timeout(const Value: uint64);
begin lingofuse_import.LF_Set_Opt_Wait_Connection_Timeout(Value); end;

class procedure LF___.LF_Set_Opt_ShowThreadID(const Value: Boolean);
begin lingofuse_import.LF_Set_Opt_ShowThreadID(Value); end;

class procedure LF___.LF_Set_Opt_ConsoleOutput(const Value: Boolean);
begin lingofuse_import.LF_Set_Opt_ConsoleOutput(Value); end;

class procedure LF___.LF_Set_Opt_IPC_Serv_ThreadCount(const Value: Integer);
begin lingofuse_import.LF_Set_Opt_IPC_Serv_ThreadCount(Value); end;

class procedure LF___.LF_Set_Opt_IPC_Serv_MaxQueueLength(const Value: Integer);
begin lingofuse_import.LF_Set_Opt_IPC_Serv_MaxQueueLength(Value); end;

class procedure LF___.LF_Set_Opt_IPC_Serv_MaxMsgSize(const Value: Integer);
begin lingofuse_import.LF_Set_Opt_IPC_Serv_MaxMsgSize(Value); end;

class procedure LF___.LF_Set_Opt_Fixed_Sequenced_Time(const Value: uint64);
begin lingofuse_import.LF_Set_Opt_Fixed_Sequenced_Time(Value); end;

class procedure LF___.LF_Set_Opt_DataHandle_Idle_Timeout(const Value: uint64);
begin lingofuse_import.LF_Set_Opt_DataHandle_Idle_Timeout(Value); end;

class procedure LF___.LF_Set_Opt_DataHandle_Pool_Scan_Interval(const Value: uint64);
begin lingofuse_import.LF_Set_Opt_DataHandle_Pool_Scan_Interval(Value); end;

class procedure LF___.LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(const Value: Integer);
begin lingofuse_import.LF_Set_Opt_No_Reponse_Cmd_NULL_Flush_Threshold(Value); end;

class function LF___.LF_Get_Opt_Debug: string;
begin Result := lingofuse_import.LF_Get_Opt_Debug; end;

class function LF___.LF_Get_Opt_P2P_Name: string;
begin Result := lingofuse_import.LF_Get_Opt_P2P_Name; end;

class function LF___.LF_Get_Opt_Password: string;
begin Result := lingofuse_import.LF_Get_Opt_Password; end;

class function LF___.LF_Get_Opt_Quiet: Boolean;
begin Result := lingofuse_import.LF_Get_Opt_Quiet; end;

class function LF___.LF_Get_Opt_Overlap_Connection: Boolean;
begin Result := lingofuse_import.LF_Get_Opt_Overlap_Connection; end;

class function LF___.LF_Get_Opt_Wait_Connection_ReadyOk: Boolean;
begin Result := lingofuse_import.LF_Get_Opt_Wait_Connection_ReadyOk; end;

class function LF___.LF_Get_Opt_Wait_Connection_Timeout: uint64;
begin Result := lingofuse_import.LF_Get_Opt_Wait_Connection_Timeout; end;

class function LF___.LF_Get_Opt_ShowThreadID: Boolean;
begin Result := lingofuse_import.LF_Get_Opt_ShowThreadID; end;

class function LF___.LF_Get_Opt_ConsoleOutput: Boolean;
begin Result := lingofuse_import.LF_Get_Opt_ConsoleOutput; end;

class function LF___.LF_Get_Opt_IPC_Serv_ThreadCount: Integer;
begin Result := lingofuse_import.LF_Get_Opt_IPC_Serv_ThreadCount; end;

class function LF___.LF_Get_Opt_IPC_Serv_MaxQueueLength: Integer;
begin Result := lingofuse_import.LF_Get_Opt_IPC_Serv_MaxQueueLength; end;

class function LF___.LF_Get_Opt_IPC_Serv_MaxMsgSize: Integer;
begin Result := lingofuse_import.LF_Get_Opt_IPC_Serv_MaxMsgSize; end;

class function LF___.LF_Get_Opt_Fixed_Sequenced_Time: uint64;
begin Result := lingofuse_import.LF_Get_Opt_Fixed_Sequenced_Time; end;

class function LF___.LF_Get_Opt_DataHandle_Idle_Timeout: uint64;
begin Result := lingofuse_import.LF_Get_Opt_DataHandle_Idle_Timeout; end;

class function LF___.LF_Get_Opt_DataHandle_Pool_Scan_Interval: uint64;
begin Result := lingofuse_import.LF_Get_Opt_DataHandle_Pool_Scan_Interval; end;

class function LF___.LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold: Integer;
begin Result := lingofuse_import.LF_Get_Opt_No_Reponse_Cmd_NULL_Flush_Threshold; end;

// Status
class function LF___.LF_GetStatusCount(): integer;
begin Result := lingofuse_import.LF_GetStatusCount(); end;

class function LF___.LF_GetStatus(): pansichar;
begin Result := lingofuse_import.LF_GetStatus(); end;

class function LF___.LF_GetStatusEx(): string;
begin Result := lingofuse_import.LF_GetStatusEx(); end;

class procedure LF___.LF_PostStatus(status: pansichar);
begin lingofuse_import.LF_PostStatus(status); end;

class procedure LF___.LF_PostStatusEx(status: string);
begin lingofuse_import.LF_PostStatusEx(status); end;

// Network events
class procedure LF___.LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event);
begin lingofuse_import.LF_Set_Network_Event(On_Connect_, On_Disconnect_); end;

// Sync / Shutdown
class function LF___.LF_Sync(): integer;
begin Result := lingofuse_import.LF_Sync(); end;

class procedure LF___.LF_Shutdown;
begin lingofuse_import.LF_Shutdown; end;

end.
