unit Z.Net.C4.LingoFuse;

{$DEFINE FPC_DELPHI_MODE}
{$I ..\pascal\zNetV2\source\Z.Define.inc}

interface

uses
{$IFDEF FPC}
  SysUtils,
  Z.FPC.GenericList,
{$ELSE FPC}
  SysUtils,
{$IFDEF MSWINDOWS}
  Windows,
{$ELSE}
  Posix.Unistd,
{$ENDIF}
{$ENDIF FPC}
  Variants,
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status, Z.UnicodeMixedLib,
  Z.ListEngine, Z.Geometry2D, Z.DFE, Z.Json, Z.Expression, Z.OpCode, Z.Notify,
  Z.Cipher, Z.MemoryStream, Z.Int128, Z.HashList.Templet,
  Z.Net, Z.Net.PhysicsIO, Z.Net.DoubleTunnelIO.NoAuth, Z.Net.C4,
  Z.LingoFuse_Core, Z.LingoFuse_Export;

type
  TC40_LF_Service = class;
  TC40_LF_SendTunnel = class;
  TC40_LF_RecvTunnel = class;

  TFixed_Sequenced_Pool = class(TString_Big_Hash_Pair_Pool<TTimeTick>);

  TC40_LF_Cycle_Anchor_64 = Int64;

  TUID_Data = record
    recv_io: TC40_LF_RecvTunnel;
    send_io: TC40_LF_SendTunnel;
    class function Get(recv_io_: TC40_LF_RecvTunnel; send_io_: TC40_LF_SendTunnel): TUID_Data; static;
  end;

  TUID_Hash_Pool = class(TBig_Hash_Pair_Pool<TUID___, TUID_Data>)
  public
    constructor Create;
  end;

  TP2PName_UID = TPair5<TUID___, TC40_LF_Cycle_Anchor_64, TString_Num64_Analysis_Tool, TTimeTick, TFixed_Sequenced_Pool>;
  PP2PName_UID = ^TP2PName_UID;

  TP2PName_UID_Ptr_List = class;

  TP2PName_UID_List = class(TBigList<TP2PName_UID>)
  public
    constructor Create;
    procedure DoFree(var Data: TP2PName_UID); override;
    function CompareData(const Data_1, Data_2: TP2PName_UID): Boolean; override;
    function Get_Ptr_Pool: TP2PName_UID_Ptr_List;
    procedure Add_UID(UID_: TUID___);
    procedure Remove_UID(UID_: TUID___);
  end;

  TP2PName_UID_Ptr_List = class(TBigList<PP2PName_UID>)
  public
    function Do_Sort_By_Cycle_Anchor(var L, R: PP2PName_UID): Integer;
    procedure Sort_By_Cycle_Anchor(taskName: TLF_String);
    function Do_Sort_By_Sequenced_Time(var L, R: PP2PName_UID): Integer;
    procedure Sort_By_Sequenced_Time(taskName: TLF_String);
  end;

  TP2PName_Hash_Pool = class(TBig_Hash_Pair_Pool<TLF_String, TP2PName_UID_List>)
  public
    constructor Create;
    function Get_Key_Hash(const Key_: TLF_String): THash; override;
    function Compare_Key(const Key_1, Key_2: TLF_String): Boolean; override;
    procedure DoFree(var Key: TLF_String; var Value: TP2PName_UID_List); override;
    procedure Update_UID(p2p_name__: TLF_String; UID_: TUID___);
    procedure Remove_UID(p2p_name__: TLF_String; UID_: TUID___);
  end;

  TUID_Info_Data = TPair2<TLF_String, TPascalStringList>;

  TUID_Info_Tool = class(TBig_Hash_Pair_Pool<TUID___, TUID_Info_Data>)
  public
    constructor Create;
    procedure DoFree(var Key: TUID___; var Value: TUID_Info_Data); override;
    function Compare_Value(const Value_1, Value_2: TUID_Info_Data): Boolean; override;
    procedure Import_From(inst: TC40_LF_RecvTunnel);
    procedure SaveToStream(d: TDFE);
    procedure LoadFromStream(d: TDFE);
    function Found_P2PName(p2p_name_: TLF_String): Boolean;
    function Found_P2PName_Api(p2p_name_, api_name_: TLF_String): Boolean;
  end;

  TC40_LF_RecvTunnel = class(TService_RecvTunnel_UserDefine_NoAuth)
  private
    P2PName: TLF_String;
    UID: TUID___;
    Cycle_Int64_Anchor_Tool: TString_Num64_Analysis_Tool;
    Cycle_Int64_Anchor: TC40_LF_Cycle_Anchor_64;
    Fixed_Sequenced_Pool: TFixed_Sequenced_Pool;
    Fixed_Sequenced_Temp_Time: TTimeTick;
  public
    LF_Service: TC40_LF_Service;
    APP_Name: TLF_String;
    APP_Desc: TLF_String;
    APP_Process_Info: TLF_String;
    api_info_data: THashList;
    p2p_api_info_data: THashList;
    Is_Local: Boolean;
    constructor Create(Owner_: TPeerIO); override;
    destructor Destroy; override;
  end;

  TC40_LF_RecvTunnelList = class(TBigList<TC40_LF_RecvTunnel>);

  TLF_ServiceInfo = class
  public
    APP_Name: TLF_String;
    APP_Desc: TLF_String;
    APP_Process_Info: TLF_String;
    api_info_data: THashList;
    Is_Local: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Assign(source: TC40_LF_RecvTunnel);
    procedure SaveToStream(stream: TCore_Stream);
    procedure LoadFromStream(stream: TCore_Stream);
  end;

  TLF_ServiceInfoPool = class(TBig_Object_List<TLF_ServiceInfo>)
  public
    constructor Create;
    destructor Destroy; override;
    procedure Build_Info_Form(inst: TC40_LF_RecvTunnel);
    procedure SaveToStream(d: TDFE);
    procedure LoadFromStream(d: TDFE);
    function Find_API(app_Name__, api_Name__: TLF_String): Boolean;
    function Find_APP(app_Name__: TLF_String): Boolean;
  end;

  TC40_LF_SendTunnel = class(TService_SendTunnel_UserDefine_NoAuth)
  private
    P2PName: TLF_String;
    UID: TUID___;
  public
    LF_Service: TC40_LF_Service;
    constructor Create(Owner_: TPeerIO); override;
    destructor Destroy; override;
  end;

  TSequence_Call_Bridge = class(TCustom_CompleteBuffer_Stream_Bridge)
  public
    constructor Create(Bridge_: TCommandCompleteBuffer_NoWait_Bridge); override;
    procedure Do_Sequence_Call_Done(Result_: TMem64);
  end;

  TAPI_Lookup_Cache = class(TString_Big_Hash_Pair_Pool<TC40_LF_RecvTunnelList>);

  TC40_LF_Service = class(TC40_Base_NoAuth_Service)
  private
    FNext_Broadcast_Tick: TTimeTick;
    FBroadcast_Scheduled: Boolean;
    procedure Schedule_API_Info_Broadcast;
  private
    FUID_Pool: TUID_Hash_Pool;
    FP2PName_Pool: TP2PName_Hash_Pool;
    FAPI_Lookup_Cache: TAPI_Lookup_Cache;
    procedure Init_UID_And_P2PName;
    procedure Free_UID_And_P2PName;
    procedure Update_P2PName_And_UID(p2p_name__: TLF_String; UID_: TUID___; p2p_api_: TPascalStringList; recv_io: TC40_LF_RecvTunnel; send_io: TC40_LF_SendTunnel);
  protected
    procedure DoLinkSuccess_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth); override;
    procedure DoUserOut_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth); override;

    procedure cmd_Update_UID(Sender: TPeerIO; InData: TDFE);
    procedure cmd_Init_APP_Info(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
    procedure cmd_No_App_Info(Sender: TPeerIO; InData: SystemString);

    procedure Run_Notify_Worker(thSender: THPC_StreamNotify; ThInData: TDFE);
    procedure cmd_Notify(Sender: TPeerIO; InData: TDFE);
    procedure cmd_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
    procedure Run_Call_Worker(thSender: THPC_CompleteBuffer_Stream; ThInData, ThOutData: TDFE);
    procedure cmd_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
    procedure cmd_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);

    procedure Run_UID_Notify_Worker(thSender: THPC_StreamNotify; ThInData: TDFE);
    procedure cmd_UID_Notify(Sender: TPeerIO; InData: TDFE);
    procedure cmd_UID_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
    procedure Run_UID_Call_Worker(thSender: THPC_CompleteBuffer_Stream; ThInData, ThOutData: TDFE);
    procedure cmd_UID_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
    procedure cmd_UID_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);

    procedure cmd_P2PName_Notify(Sender: TPeerIO; InData: TDFE);
    procedure cmd_P2PName_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
    procedure cmd_P2PName_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
    procedure cmd_P2PName_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
  public
    constructor Create(PhysicsService_: TC40_PhysicsService; ServiceTyp, Param_: U_String); override;
    destructor Destroy; override;
    procedure SafeCheck; override;
    procedure Progress; override;

    procedure Broadcast_API_Info();

    function Compare_Client_Cycle_Anchor(var L, R: TC40_LF_RecvTunnel): Integer;
    function Find_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
    function Find_UID(UID_: TUID___; api_Name__: TLF_String): TC40_LF_RecvTunnel;

    function Compare_Client_Fixed_Sequence(var L, R: TC40_LF_RecvTunnel): Integer;
    function Find_Fixed_Sequenced_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;

    function Find_P2PName_LoadBalance(p2p_name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
    function Find_P2PName_FixedSequenced(p2p_name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
  end;

  TC40_LF_Client = class(TC40_Base_NoAuth_Client)
  private
    Cycle_Int64_Anchor_Tool: TString_Num64_Analysis_Tool;
    Cycle_Int64_Anchor: TC40_LF_Cycle_Anchor_64;
    Fixed_Sequenced_Pool: TFixed_Sequenced_Pool;
    Fixed_Sequenced_Temp_Time: TTimeTick;
  private
    FLast_UID: TUID___;
    FLast_P2PName: TLF_String;
    FService_Info: TLF_ServiceInfoPool;
    FUID_Info_Tool: TUID_Info_Tool;
    FHost_Running_Thread_Num: TAtomInt32;
    FWait_Reponse_Thread_Num: TAtomInt32;
    FSent_No_Response_Cmd_Num: TAtomInt32;
    FLast_Check_UID_TimeTick: TTimeTick;
    FAPP: TLF_App;
    FAPI_APP_Is_Online: Boolean;
    FService_Info_Is_Online: Boolean;

    procedure Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender: TDT_P2PVM_NoAuth_Custom_Client); override;
    procedure cmd_update_service_api_info(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);

    procedure Run_Notify_Worker(thSender: THPC_CompleteBuffer; ThInData: PByte; ThDataSize: NativeInt);
    procedure cmd_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure cmd_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure cmd_Call(Sender: TPeerIO; InData, OutData: TDFE);
    procedure cmd_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);

    procedure Run_UID_Notify_Worker(thSender: THPC_CompleteBuffer; ThInData: PByte; ThDataSize: NativeInt);
    procedure cmd_UID_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure cmd_UID_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure cmd_UID_Call(Sender: TPeerIO; InData, OutData: TDFE);
    procedure cmd_UID_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);

    procedure cmd_P2PName_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure cmd_P2PName_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure cmd_P2PName_Call(Sender: TPeerIO; InData, OutData: TDFE);
    procedure cmd_P2PName_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);

    procedure Do_APP_Update(Sender: TLF_App);
    procedure Do_LF_P2P_APP_Update(Sender: TLF_App);
  private
    procedure Do_Update_UID_Info;
    procedure Do_Init_App_Info;
    procedure Do_Null_OnResult(Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
    procedure Send_Execute_Notify_Impl(app_Name__: TLF_String; Param: TMem64);
    procedure Send_Sequenced_Notify_Impl(app_Name__: TLF_String; Param: TMem64);
    function Wait_Execute_Call_Impl(app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
    procedure Async_Execute_Call_Impl(app_Name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
    procedure Async_Sequenced_Execute_Call_Impl(app_Name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
    procedure Send_UID_Execute_Notify_Impl(UID_: TUID___; Param: TMem64);
    procedure Send_UID_Execute_Sequenced_Notify_Impl(UID_: TUID___; Param: TMem64);
    function Wait_UID_Execute_Call_Impl(UID_: TUID___; Param: TMem64; TimeOut__: TTimeTick): TMem64;
    procedure Async_UID_Execute_Call_Impl(UID_: TUID___; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
    procedure Async_UID_Sequenced_Execute_Call_Impl(UID_: TUID___; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
    procedure Send_P2PName_Execute_Notify_Impl(p2p_name__: TLF_String; Param: TMem64);
    procedure Send_P2PName_Execute_Sequenced_Notify_Impl(p2p_name__: TLF_String; Param: TMem64);
    function Wait_P2PName_Execute_Call_Impl(p2p_name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
    procedure Async_P2PName_Execute_Call_Impl(p2p_name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
    procedure Async_P2PName_Sequenced_Execute_Call_Impl(p2p_name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
  public
    constructor Create(PhysicsTunnel_: TC40_PhysicsTunnel; source_: TC40_Info; Param_: U_String); override;
    destructor Destroy; override;
    procedure SafeCheck; override;
    procedure Progress; override;
    procedure DoNetworkOnline; override;
    procedure DoNetworkOffline; override;

    property Service_Info: TLF_ServiceInfoPool read FService_Info;
    procedure Update_UID_Info;
    procedure Init_App_Info;
    procedure Do_Init_App_Info_Result(Sender: TPeerIO; Result_: TDFE);
    property LF_AppIsOnline: Boolean read FAPI_APP_Is_Online;
    property LF_Service_Info_Is_Online: Boolean read FService_Info_Is_Online;

    procedure Set_API_APP(const Value: TLF_App);
    property APP: TLF_App read FAPP write Set_API_APP;

    function Get_App_From_Pool(app_Name__: TLF_String): TLF_App;

    procedure Check_Param_And_Send_Queue(Param: TMem64);

    procedure Send_Execute_Notify(app_Name__: TLF_String; Param: TMem64);
    procedure Send_Sequenced_Notify(app_Name__: TLF_String; Param: TMem64);
    function Wait_Execute_Call(app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
    function Async_Execute_Call(app_Name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
    function Async_Sequenced_Execute_Call(app_Name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;

    procedure Send_UID_Execute_Notify(UID_: TUID___; Param: TMem64);
    procedure Send_UID_Execute_Sequenced_Notify(UID_: TUID___; Param: TMem64);
    function Wait_UID_Execute_Call(UID_: TUID___; Param: TMem64; TimeOut__: TTimeTick): TMem64;
    function Async_UID_Execute_Call(UID_: TUID___; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
    function Async_UID_Sequenced_Execute_Call(UID_: TUID___; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;

    procedure Send_P2PName_Execute_Notify(p2p_name__: TLF_String; Param: TMem64);
    procedure Send_P2PName_Execute_Sequenced_Notify(p2p_name__: TLF_String; Param: TMem64);
    function Wait_P2PName_Execute_Call(p2p_name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
    function Async_P2PName_Execute_Call(p2p_name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
    function Async_P2PName_Sequenced_Execute_Call(p2p_name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
  end;

  TC40_LF_ClientList = TBigList<TC40_LF_Client>;

  TLF_Call_Bridge = class
  private
    Cli: TC40_LF_Client;
    Output: TMem64;
    IsRunning: Boolean;
    Error_: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Do_Result(Sender: TPeerIO; Result_: TDFE);
  end;

  TLF_Async_Call_Bridge = class
  private
    Cli: TC40_LF_Client;
    app_Name__, api_Name__: TLF_String;
    Data_: Pointer;
    OnResult: TLF_Async_Call_OnResult;
    Result_M64: TMem64;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Do_Th();
    procedure Do_Result(Sender: TPeerIO; Result_: TDFE);
  end;

  TLF_Async_Sequenced_Call_Bridge = class
  private
    Cli: TC40_LF_Client;
    app_Name__, api_Name__: TLF_String;
    Data_: Pointer;
    OnResult: TLF_Async_Call_OnResult;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Do_Local_Thread_Call_Result(Result_: TMem64);
    procedure Do_Result(Sender: TPeerIO; Result_: TDFE);
  end;

function Make_LingoFuse_Process_Name: TLF_String;
function Get_Cycle_Anchor: TC40_LF_Cycle_Anchor_64; inline;

function Find_Local_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
function Find_Remote_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;

function Find_Local_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
function Find_Remote_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;

function Find_Local_UID(UID_: TUID___): Boolean;
function Find_Local_UID_App(UID_: TUID___; api_Name__: TLF_String): TLF_App;
function Find_Remote_UID(UID_: TUID___): Boolean;
function Find_Remote_UID_API(UID_: TUID___; api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;

function Find_P2PNAME(p2p_name__: TLF_String): Boolean;
function Find_P2PNAME_API(p2p_name__, api_Name__: TLF_String): Boolean;

function Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
function Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;

procedure Do_LF_Network_Connect(addr_: TLF_String);
procedure Do_LF_Network_Disconnect(addr_: TLF_String);

procedure LF_Invalidate_Local_API_Cache;
procedure LF_Invalidate_Remote_API_Cache;
procedure LF_Invalidate_All_API_Cache;

var
  LF_P2P_name: TLF_AtomString;
  Fixed_Sequenced_Time: TTimeTick;
  LingoFuse_Process_Name: TLF_String;
  Find_Safe_Critical, Sort_Safe_Critical: TCritical;
  Cycle_Anchor_Seed: Int64;
  No_Reponse_Cmd_NULL_Flush_Threshold: Integer;

const
  C_Generate_Prefix = '@__generate__@';

implementation

{$I Z.LingoFuse_System_ProcessID.inc}


type
  TC40_LF_ClientListCache = class(TString_Big_Hash_Pair_Pool<TC40_LF_ClientList>)
  public
    procedure DoFree(var Key: SystemString; var Value: TC40_LF_ClientList); override;
  end;

procedure TC40_LF_ClientListCache.DoFree(var Key: SystemString; var Value: TC40_LF_ClientList);
begin
  Key := '';
  DisposeObjectAndNil(Value);
end;

var
  LF_Local_API_Cache: TC40_LF_ClientListCache = nil;
  LF_Remote_API_Cache: TC40_LF_ClientListCache = nil;

procedure LF_Invalidate_Local_API_Cache;
begin
  if LF_Local_API_Cache = nil then exit;
  Find_Safe_Critical.Lock;
  try
      LF_Local_API_Cache.Clear;
  finally
      Find_Safe_Critical.UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Invalidate Local API cache');
    end;
end;

procedure LF_Invalidate_Remote_API_Cache;
begin
  if LF_Remote_API_Cache = nil then exit;
  Find_Safe_Critical.Lock;
  try
      LF_Remote_API_Cache.Clear;
  finally
      Find_Safe_Critical.UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Invalidate Remote API cache');
    end;
end;

procedure LF_Invalidate_All_API_Cache;
begin
  if (LF_Local_API_Cache = nil) and (LF_Remote_API_Cache = nil) then exit;
  Find_Safe_Critical.Lock;
  try
    if LF_Local_API_Cache <> nil then LF_Local_API_Cache.Clear;
    if LF_Remote_API_Cache <> nil then LF_Remote_API_Cache.Clear;
  finally
      Find_Safe_Critical.UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Invalidate All API cache');
    end;
end;

function Get_Cycle_Anchor: TC40_LF_Cycle_Anchor_64;
begin
  Result := AtomInc(Cycle_Anchor_Seed);
end;

function Compare_Client_Cycle_Anchor_Local(var L, R: TC40_LF_Client): Integer;
begin
  Result := CompareInt64(L.Cycle_Int64_Anchor, R.Cycle_Int64_Anchor);
end;

function Find_Local_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
begin
  Result := nil;
  L := TC40_LF_ClientList.Create;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if Cli.APP <> nil then
          begin
            if app_Name__.Same(Cli.APP.Name) then
                L.Add(Cli);
          end;
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  Sort_Safe_Critical.Lock;

  if L.Num > 0 then
    with L.Repeat_ do
      repeat
          queue^.Data.Cycle_Int64_Anchor := queue^.Data.Cycle_Int64_Anchor_Tool[app_Name__.Text];
      until not Next;

  try
    L.Sort_C(Compare_Client_Cycle_Anchor_Local);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor_Tool[app_Name__.Text] := Get_Cycle_Anchor();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;
  DisposeObject(L);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Local_APP: name="%s" result=%p', [app_Name__.Text, Pointer(Result)]);
    end;
end;

function Find_Remote_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
begin
  Result := nil;
  L := TC40_LF_ClientList.Create;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client, True);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if Cli.Service_Info.Find_APP(app_Name__) then
            L.Add(Cli);
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  Sort_Safe_Critical.Lock;
  if L.Num > 0 then
    with L.Repeat_ do
      repeat
          queue^.Data.Cycle_Int64_Anchor := queue^.Data.Cycle_Int64_Anchor_Tool[app_Name__.Text];
      until not Next;
  try
    L.Sort_C(Compare_Client_Cycle_Anchor_Local);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor_Tool[app_Name__.Text] := Get_Cycle_Anchor();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;
  DisposeObject(L);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Remote_APP: name="%s" result=%p', [app_Name__.Text, Pointer(Result)]);
    end;
end;

function Find_Local_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
  n: SystemString;
  cache_hit: Boolean;
begin
  Result := nil;
  n := PFormat('%s.%s', [app_Name__.Text, api_Name__.Text]);

  Find_Safe_Critical.Lock;
  try
    cache_hit := True;
    L := LF_Local_API_Cache.Get_Key_Value(n);
    if L = nil then
      begin
        cache_hit := False;
        L := TC40_LF_ClientList.Create;
        arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
        for i := 0 to length(arry) - 1 do
          begin
            Cli := arry[i] as TC40_LF_Client;
            if Cli.APP <> nil then
              begin
                if app_Name__.Same(Cli.APP.Name) and Cli.APP.Engine.LF_MethodPool.Exists_Key(api_Name__) then
                    L.Add(Cli);
              end;
          end;
        LF_Local_API_Cache.Add(n, L, False);
      end;

    if L.Num > 0 then
      with L.Repeat_ do
        repeat
            queue^.Data.Cycle_Int64_Anchor := queue^.Data.Cycle_Int64_Anchor_Tool[n];
        until not Next;
    L.Sort_C(Compare_Client_Cycle_Anchor_Local);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor_Tool[n] := Get_Cycle_Anchor();
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Local_API: key="%s" hit=%s result=%p', [n, if_(cache_hit, 'yes', 'no'), Pointer(Result)]);
    end;
end;

function Find_Remote_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
  n: SystemString;
  cache_hit: Boolean;
begin
  Result := nil;
  n := PFormat('%s.%s', [app_Name__.Text, api_Name__.Text]);

  Find_Safe_Critical.Lock;
  try
    cache_hit := True;
    L := LF_Remote_API_Cache.Get_Key_Value(n);
    if L = nil then
      begin
        cache_hit := False;
        L := TC40_LF_ClientList.Create;
        arry := C40_ClientPool.FastSearchClass(TC40_LF_Client, True);
        for i := 0 to length(arry) - 1 do
          begin
            Cli := arry[i] as TC40_LF_Client;
            if Cli.Service_Info.Find_API(app_Name__, api_Name__) then
                L.Add(Cli);
          end;
        LF_Remote_API_Cache.Add(n, L, False);
      end;

    if L.Num > 0 then
      with L.Repeat_ do
        repeat
            queue^.Data.Cycle_Int64_Anchor := queue^.Data.Cycle_Int64_Anchor_Tool[n];
        until not Next;
    L.Sort_C(Compare_Client_Cycle_Anchor_Local);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor_Tool[n] := Get_Cycle_Anchor();
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Remote_API: key="%s" hit=%s result=%p', [n, if_(cache_hit, 'yes', 'no'), Pointer(Result)]);
    end;
end;

function Find_Local_UID(UID_: TUID___): Boolean;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
begin
  Result := False;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if TCipher.CompareHash(UID_, Cli.FLast_UID) then
          begin
            Result := True;
            Break;
          end;
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Local_UID: result=%s', [BoolToStr(Result, True)]);
    end;
end;

function Find_Local_UID_App(UID_: TUID___; api_Name__: TLF_String): TLF_App;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  matched: Boolean;
begin
  Result := nil;
  matched := False;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if TCipher.CompareHash(UID_, Cli.FLast_UID) then
          begin
            matched := True;
            Break;
          end;
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;
  if matched then
      Result := Find_API_From_P2P_APP(api_Name__);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Local_UID_App: api="%s" matched=%s app=%p',
        [api_Name__.Text, BoolToStr(matched, True), Pointer(Result)]);
    end;
end;

function Find_Remote_UID(UID_: TUID___): Boolean;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
begin
  Result := False;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if Cli.FUID_Info_Tool.Exists_Key(UID_) then
          begin
            Result := True;
            Break;
          end;
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Remote_UID: result=%s', [BoolToStr(Result, True)]);
    end;
end;

function Find_Remote_UID_API(UID_: TUID___; api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
  P: TUID_Info_Tool.PValue_;
  n: SystemString;
begin
  Result := nil;
  L := TC40_LF_ClientList.Create;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client, True);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        P := Cli.FUID_Info_Tool.Get_Value_Ptr___(UID_);
        if P <> nil then
          if P^.Second.ExistsValue(api_Name__.Text) >= 0 then
              L.Add(Cli);
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  n := TCipher.HashToString(UID_);
  Sort_Safe_Critical.Lock;
  if L.Num > 0 then
    with L.Repeat_ do
      repeat
          queue^.Data.Cycle_Int64_Anchor := queue^.Data.Cycle_Int64_Anchor_Tool[n];
      until not Next;
  try
    L.Sort_C(Compare_Client_Cycle_Anchor_Local);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor_Tool[n] := Get_Cycle_Anchor();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;
  DisposeObject(L);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Remote_UID_API: api="%s" result=%p', [api_Name__.Text, Pointer(Result)]);
    end;
end;

function Find_P2PNAME(p2p_name__: TLF_String): Boolean;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
begin
  Result := False;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client, True);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if Cli.FUID_Info_Tool.Found_P2PName(p2p_name__) then
          begin
            Result := True;
            Break;
          end;
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_P2PNAME: p2p="%s" result=%s', [p2p_name__.Text, BoolToStr(Result, True)]);
    end;
end;

function Find_P2PNAME_API(p2p_name__, api_Name__: TLF_String): Boolean;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
begin
  Result := False;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client, True);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if Cli.FUID_Info_Tool.Found_P2PName_Api(p2p_name__, api_Name__) then
          begin
            Result := True;
            Break;
          end;
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_P2PNAME_API: p2p="%s" api="%s" result=%s',
        [p2p_name__.Text, api_Name__.Text, BoolToStr(Result, True)]);
    end;
end;

function Compare_Client_Fixed_Sequenced_Local(var L, R: TC40_LF_Client): Integer;
begin
  Result := CompareUInt64(R.Fixed_Sequenced_Temp_Time, L.Fixed_Sequenced_Temp_Time);
end;

function Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
  n: SystemString;
begin
  Result := nil;
  L := TC40_LF_ClientList.Create;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if Cli.APP <> nil then
          begin
            if app_Name__.Same(Cli.APP.Name) and Cli.APP.Engine.LF_MethodPool.Exists_Key(api_Name__) then
                L.Add(Cli);
          end;
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  n := PFormat('%s.%s', [app_Name__.Text, api_Name__.Text]);
  Sort_Safe_Critical.Lock;
  if L.Num > 0 then
    with L.Repeat_ do
      repeat
        Cli := queue^.Data;
        Cli.Fixed_Sequenced_Temp_Time := Cli.Fixed_Sequenced_Pool.Get_Default_Value(n, 0);
      until not Next;

  try
    L.Sort_C(Compare_Client_Fixed_Sequenced_Local);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if GetTimeTick() - Result.Fixed_Sequenced_Temp_Time > Fixed_Sequenced_Time then
            Result := L.Last^.Data;
        Result.Fixed_Sequenced_Pool.Set_Key_Value(n, GetTimeTick());
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;
  DisposeObject(L);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Fixed_Sequenced_Local_API: key="%s" result=%p', [n, Pointer(Result)]);
    end;
end;

function Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
  n: SystemString;
begin
  Result := nil;
  L := TC40_LF_ClientList.Create;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.FastSearchClass(TC40_LF_Client, True);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if Cli.Service_Info.Find_API(app_Name__, api_Name__) then
            L.Add(Cli);
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  n := PFormat('%s.%s', [app_Name__.Text, api_Name__.Text]);
  Sort_Safe_Critical.Lock;
  if L.Num > 0 then
    with L.Repeat_ do
      repeat
        Cli := queue^.Data;
        Cli.Fixed_Sequenced_Temp_Time := Cli.Fixed_Sequenced_Pool.Get_Default_Value(n, 0);
      until not Next;

  try
    L.Sort_C(Compare_Client_Fixed_Sequenced_Local);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if GetTimeTick() - Result.Fixed_Sequenced_Temp_Time > Fixed_Sequenced_Time then
            Result := L.Last^.Data;
        Result.Fixed_Sequenced_Pool.Set_Key_Value(n, GetTimeTick());
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;
  DisposeObject(L);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Find_Fixed_Sequenced_Remote_API: key="%s" result=%p', [n, Pointer(Result)]);
    end;
end;

procedure Do_LF_Network_Connect_Worker(thSender: TCompute);
begin
  try
      Z.LingoFuse_Export.On_Network_Connect_Event(thSender.UserData);
  except
  end;
  TLF_String.FreeUTF8AnsiChar(thSender.UserData);
end;

procedure Do_LF_Network_Connect(addr_: TLF_String);
begin
  if Assigned(Z.LingoFuse_Export.On_Network_Connect_Event) then
      TCompute.RunC(addr_.BuildUTF8AnsiChar(), nil, Do_LF_Network_Connect_Worker);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Do_LF_Network_Connect: addr="%s"', [addr_.Text]);
    end;
end;

procedure Do_LF_Network_Disconnect_Worker(thSender: TCompute);
begin
  try
      Z.LingoFuse_Export.On_Network_Disconnect_Event(thSender.UserData);
  except
  end;
  TLF_String.FreeUTF8AnsiChar(thSender.UserData);
end;

procedure Do_LF_Network_Disconnect(addr_: TLF_String);
begin
  if Assigned(Z.LingoFuse_Export.On_Network_Disconnect_Event) then
      TCompute.RunC(addr_.BuildUTF8AnsiChar(), nil, Do_LF_Network_Disconnect_Worker);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Do_LF_Network_Disconnect: addr="%s"', [addr_.Text]);
    end;
end;

constructor TC40_LF_RecvTunnel.Create(Owner_: TPeerIO);
begin
  inherited Create(Owner_);
  P2PName := '';
  UID := Null_UID();
  Cycle_Int64_Anchor_Tool := TString_Num64_Analysis_Tool.Create($FF, 0);
  Cycle_Int64_Anchor := 0;
  Fixed_Sequenced_Pool := TFixed_Sequenced_Pool.Create($FF, 0);
  Fixed_Sequenced_Temp_Time := 0;
  LF_Service := nil;
  APP_Name := '';
  APP_Desc := '';
  APP_Process_Info := '';
  api_info_data := THashList.Create;
  p2p_api_info_data := THashList.Create;
  Is_Local := False;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('RecvTunnel.Create: peer=%s', [Owner_.GetPeerIP]);
    end;
end;

destructor TC40_LF_RecvTunnel.Destroy;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('RecvTunnel.Destroy: app="%s" p2p="%s"',
        [APP_Name.Text, P2PName.Text]);
    end;
  DisposeObject(Cycle_Int64_Anchor_Tool);
  DisposeObject(api_info_data);
  DisposeObject(p2p_api_info_data);
  DisposeObject(Fixed_Sequenced_Pool);
  inherited Destroy;
end;

constructor TLF_ServiceInfo.Create;
begin
  inherited Create;
  APP_Name := '';
  APP_Desc := '';
  APP_Process_Info := '';
  api_info_data := THashList.Create;
  Is_Local := False;
end;

destructor TLF_ServiceInfo.Destroy;
begin
  DisposeObject(api_info_data);
  inherited Destroy;
end;

procedure TLF_ServiceInfo.Assign(source: TC40_LF_RecvTunnel);
begin
  APP_Name := source.APP_Name;
  APP_Desc := source.APP_Desc;
  APP_Process_Info := source.APP_Process_Info;
  api_info_data.Assign(source.api_info_data);
  Is_Local := source.Is_Local;
end;

procedure TLF_ServiceInfo.SaveToStream(stream: TCore_Stream);
var
  d: TDFE;
  pl: TPascalStringList;
begin
  d := TDFE.Create;
  d.WriteString(APP_Name);
  d.WriteString(APP_Desc);
  d.WriteString(APP_Process_Info);
  pl := TPascalStringList.Create;
  api_info_data.GetNameList(pl);
  d.WritePascalStrings(pl);
  DisposeObject(pl);
  d.WriteBool(Is_Local);
  d.FastEncodeTo(stream);
  DisposeObject(d);
end;

procedure TLF_ServiceInfo.LoadFromStream(stream: TCore_Stream);
var
  d: TDFE;
  pl: TPascalStringList;
  i: Integer;
begin
  d := TDFE.Create;
  d.DecodeFrom(stream, True);
  APP_Name := d.R.ReadString;
  APP_Desc := d.R.ReadString;
  APP_Process_Info := d.R.ReadString;
  pl := TPascalStringList.Create;
  d.R.ReadPascalStrings(pl);
  api_info_data.Clear;
  for i := 0 to pl.Count - 1 do
      api_info_data.Add(pl[i], nil, False);
  DisposeObject(pl);
  Is_Local := d.R.ReadBool;
  DisposeObject(d);
end;

constructor TLF_ServiceInfoPool.Create;
begin
  inherited Create(True);
end;

destructor TLF_ServiceInfoPool.Destroy;
begin
  inherited Destroy;
end;

procedure TLF_ServiceInfoPool.Build_Info_Form(inst: TC40_LF_RecvTunnel);
var
  tmp: TLF_ServiceInfo;
begin
  if inst.api_info_data.Count > 0 then
    begin
      tmp := TLF_ServiceInfo.Create;
      tmp.Assign(inst);
      Add(tmp);
    end;
end;

procedure TLF_ServiceInfoPool.SaveToStream(d: TDFE);
var
  m64: TMS64;
begin
  if Num <= 0 then exit;
  m64 := TMS64.CustomCreate($FFFF);
  with Repeat_ do
    repeat
      queue^.Data.SaveToStream(m64);
      d.WriteStream(m64);
      m64.Clear;
    until not Next;
  DisposeObject(m64);
end;

procedure TLF_ServiceInfoPool.LoadFromStream(d: TDFE);
var
  m64: TMS64;
  inst: TLF_ServiceInfo;
begin
  Clear;
  m64 := TMS64.CustomCreate($FFFF);
  while d.R.NotEnd do
    begin
      d.R.ReadMS64_As_Mapping(m64);
      m64.Position := 0;
      inst := TLF_ServiceInfo.Create;
      inst.LoadFromStream(m64);
      Add(inst);
      m64.Clear;
    end;
  DisposeObject(m64);
end;

function TLF_ServiceInfoPool.Find_API(app_Name__, api_Name__: TLF_String): Boolean;
begin
  Result := False;
  if Num <= 0 then exit;
  with Repeat_ do
    repeat
      if app_Name__.Same(queue^.Data.APP_Name) and queue^.Data.api_info_data.Exists(api_Name__) then
        begin
          Result := True;
          exit;
        end;
    until not Next;
end;

function TLF_ServiceInfoPool.Find_APP(app_Name__: TLF_String): Boolean;
begin
  Result := False;
  if Num <= 0 then exit;
  with Repeat_ do
    repeat
      if app_Name__.Same(queue^.Data.APP_Name) then
        begin
          Result := True;
          exit;
        end;
    until not Next;
end;

class function TUID_Data.Get(recv_io_: TC40_LF_RecvTunnel; send_io_: TC40_LF_SendTunnel): TUID_Data;
begin
  Result.recv_io := recv_io_;
  Result.send_io := send_io_;
end;

constructor TUID_Hash_Pool.Create;
begin
  inherited Create(1024, TUID_Data.Get(nil, nil));
end;

constructor TP2PName_UID_List.Create;
begin
  inherited Create;
  Get_Critical__;
end;

procedure TP2PName_UID_List.DoFree(var Data: TP2PName_UID);
begin
  DisposeObjectAndNil(Data.Third);
  DisposeObjectAndNil(Data.Five);
  inherited;
end;

function TP2PName_UID_List.CompareData(const Data_1, Data_2: TP2PName_UID): Boolean;
begin
  Result := TCipher.CompareHash(Data_1.Primary, Data_2.Primary);
end;

function TP2PName_UID_List.Get_Ptr_Pool: TP2PName_UID_Ptr_List;
begin
  Result := TP2PName_UID_Ptr_List.Create;
  if Num > 0 then
    with Repeat_ do
      repeat
          Result.Add(@queue^.Data);
      until not Next;
end;

procedure TP2PName_UID_List.Add_UID(UID_: TUID___);
begin
  if Num > 0 then
    begin
      with Repeat_ do
        repeat
          if TCipher.CompareHash(UID_, queue^.Data.Primary) then
              exit;
        until not Next;
    end;
  Add(TP2PName_UID.Init(UID_, 0, nil, 0, nil));
end;

procedure TP2PName_UID_List.Remove_UID(UID_: TUID___);
begin
  if Num > 0 then
    begin
      with Repeat_ do
        repeat
          if TCipher.CompareHash(UID_, queue^.Data.Primary) then
              Push_To_Recycle_Pool(queue);
        until not Next;
      Free_Recycle_Pool;
    end;
end;

function TP2PName_UID_Ptr_List.Do_Sort_By_Cycle_Anchor(var L, R: PP2PName_UID): Integer;
begin
  Result := CompareInt64(L^.Second, R^.Second);
end;

procedure TP2PName_UID_Ptr_List.Sort_By_Cycle_Anchor(taskName: TLF_String);
begin
  if Num > 0 then
    begin
      with Repeat_ do
        repeat
          if queue^.Data^.Third = nil then queue^.Data^.Third := TString_Num64_Analysis_Tool.Create($FF, 0);
          queue^.Data^.Second := queue^.Data^.Third[taskName.Text];
        until not Next;
      Sort_M(Do_Sort_By_Cycle_Anchor);
    end;
end;

function TP2PName_UID_Ptr_List.Do_Sort_By_Sequenced_Time(var L, R: PP2PName_UID): Integer;
begin
  Result := CompareUInt64(R^.Fourth, L^.Fourth);
end;

procedure TP2PName_UID_Ptr_List.Sort_By_Sequenced_Time(taskName: TLF_String);
begin
  if Num > 0 then
    begin
      with Repeat_ do
        repeat
          if queue^.Data^.Five = nil then queue^.Data^.Five := TFixed_Sequenced_Pool.Create($FF, 0);
          queue^.Data^.Fourth := queue^.Data^.Five[taskName.Text];
        until not Next;
      Sort_M(Do_Sort_By_Sequenced_Time);
    end;
end;

constructor TP2PName_Hash_Pool.Create;
begin
  inherited Create(1024, nil);
end;

function TP2PName_Hash_Pool.Get_Key_Hash(const Key_: TLF_String): THash;
begin
  Result := UFastHashPPascalString(@Key_);
  Result := Get_CRC32(@Result, SizeOf(THash));
end;

function TP2PName_Hash_Pool.Compare_Key(const Key_1, Key_2: TLF_String): Boolean;
begin
  Result := Key_1.Same(@Key_2);
end;

procedure TP2PName_Hash_Pool.DoFree(var Key: TLF_String; var Value: TP2PName_UID_List);
begin
  Key := '';
  DisposeObjectAndNil(Value);
end;

procedure TP2PName_Hash_Pool.Update_UID(p2p_name__: TLF_String; UID_: TUID___);
var
  L: TP2PName_UID_List;
begin
  if not Exists_Key(p2p_name__) then
    begin
      L := TP2PName_UID_List.Create;
      Add(p2p_name__, L, False);
    end
  else L := Get_Key_Value(p2p_name__);
  L.Add_UID(UID_);
end;

procedure TP2PName_Hash_Pool.Remove_UID(p2p_name__: TLF_String; UID_: TUID___);
var
  L: TP2PName_UID_List;
begin
  L := Get_Key_Value(p2p_name__);
  if L = nil then exit;
  L.Remove_UID(UID_);
  if L.Num <= 0 then
      Delete(p2p_name__);
end;

constructor TUID_Info_Tool.Create;
begin
  inherited Create(1024, TUID_Info_Data.Init('', nil));
end;

procedure TUID_Info_Tool.DoFree(var Key: TUID___; var Value: TUID_Info_Data);
begin
  Value.Primary := '';
  DisposeObjectAndNil(Value.Second);
  inherited;
end;

function TUID_Info_Tool.Compare_Value(const Value_1, Value_2: TUID_Info_Data): Boolean;
begin
  Result := Value_1.Primary.Same(@Value_2.Primary);
end;

procedure TUID_Info_Tool.Import_From(inst: TC40_LF_RecvTunnel);
var
  tmp: TUID_Info_Data;
begin
  tmp := TUID_Info_Data.Init(inst.P2PName, TPascalStringList.Create);
  inst.p2p_api_info_data.GetNameList(tmp.Second);
  Add(inst.UID, tmp, True);
end;

procedure TUID_Info_Tool.SaveToStream(d: TDFE);
var
  arry: TDF_ArrayByte;
  buff: TBytes;
begin
  if Num <= 0 then exit;
  with Repeat_ do
    repeat
      arry := d.WriteArrayByte();
      arry.Buffer__.WritePtr(@queue^.Data^.Data.Primary[0], SizeOf(TUID___));
      buff := queue^.Data^.Data.Second.Primary.UTF8;
      if length(buff) > 0 then
          arry.Buffer__.WriteBytes(buff);
      d.WritePascalStrings(queue^.Data^.Data.Second.Second);
    until not Next;
end;

procedure TUID_Info_Tool.LoadFromStream(d: TDFE);
var
  arry: TDF_ArrayByte;
  UID_: TUID___;
  buff: TBytes;
  tmp: TUID_Info_Data;
begin
  Clear;
  while d.R.NotEnd do
    begin
      arry := d.R.ReadArrayByte();
      arry.Buffer__.ReadPtr(@UID_[0], SizeOf(TUID___));
      SetLength(buff, arry.Buffer__.Size - arry.Buffer__.Position);
      if length(buff) > 0 then
          arry.Buffer__.ReadPtr(@buff[0], length(buff));
      tmp := TUID_Info_Data.Init('', TPascalStringList.Create);
      tmp.Primary.UTF8 := buff;
      d.R.ReadPascalStrings(tmp.Second);
      Add(UID_, tmp, True);
    end;
end;

function TUID_Info_Tool.Found_P2PName(p2p_name_: TLF_String): Boolean;
begin
  Result := False;
  if Num > 0 then
    with Repeat_ do
      repeat
        if p2p_name_.Same(@queue^.Data^.Data.Second.Primary) then
          begin
            Result := True;
            exit;
          end;
      until not Next;
end;

function TUID_Info_Tool.Found_P2PName_Api(p2p_name_, api_name_: TLF_String): Boolean;
begin
  Result := False;
  if Num > 0 then
    with Repeat_ do
      repeat
        if p2p_name_.Same(@queue^.Data^.Data.Second.Primary) and (queue^.Data^.Data.Second.Second.ExistsValue(api_name_.Text) >= 0) then
          begin
            Result := True;
            exit;
          end;
      until not Next;
end;

constructor TC40_LF_SendTunnel.Create(Owner_: TPeerIO);
begin
  inherited Create(Owner_);
  P2PName := '';
  UID := Null_UID();
  LF_Service := nil;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SendTunnel.Create: peer=%s', [Owner_.GetPeerIP]);
    end;
end;

destructor TC40_LF_SendTunnel.Destroy;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SendTunnel.Destroy: p2p="%s"', [P2PName.Text]);
    end;
  inherited Destroy;
end;

constructor TSequence_Call_Bridge.Create(Bridge_: TCommandCompleteBuffer_NoWait_Bridge);
begin
  inherited Create(Bridge_);
  Bridge.Pause;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TSequence_Call_Bridge.Create: bridge=%p', [Pointer(Bridge_)]);
    end;
end;

procedure TSequence_Call_Bridge.Do_Sequence_Call_Done(Result_: TMem64);
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TSequence_Call_Bridge.Do_Sequence_Call_Done: size=%d self=%p',
        [Result_.Size, Pointer(Self)]);
    end;
  Bridge.OutData.WriteMem64(Result_);
  Bridge.Resume;
  DelayFreeObj(1.0, Self);
end;

procedure TC40_LF_Service.Schedule_API_Info_Broadcast;
begin
  if FBroadcast_Scheduled then exit;
  if DTNoAuth.TotalLinkCount < 10 then FNext_Broadcast_Tick := GetTimeTick() + 500
  else if DTNoAuth.TotalLinkCount < 100 then FNext_Broadcast_Tick := GetTimeTick() + 1000
  else FNext_Broadcast_Tick := GetTimeTick() + 3000;
  FBroadcast_Scheduled := True;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service.Schedule_API_Info_Broadcast: links=%d next_tick=%d',
        [DTNoAuth.TotalLinkCount, FNext_Broadcast_Tick]);
    end;
end;

procedure TC40_LF_Service.Init_UID_And_P2PName;
begin
  FUID_Pool := TUID_Hash_Pool.Create;
  FP2PName_Pool := TP2PName_Hash_Pool.Create;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service.Init_UID_And_P2PName done');
    end;
end;

procedure TC40_LF_Service.Free_UID_And_P2PName;
begin
  DisposeObjectAndNil(FUID_Pool);
  DisposeObjectAndNil(FP2PName_Pool);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service.Free_UID_And_P2PName done');
    end;
end;

procedure TC40_LF_Service.Update_P2PName_And_UID(p2p_name__: TLF_String; UID_: TUID___; p2p_api_: TPascalStringList; recv_io: TC40_LF_RecvTunnel; send_io: TC40_LF_SendTunnel);
var
  i: Integer;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service.Update_P2PName_And_UID: p2p="%s" api_count=%d',
        [p2p_name__.Text, p2p_api_.Count]);
    end;

  if (recv_io.P2PName <> '') then FP2PName_Pool.Remove_UID(recv_io.P2PName, recv_io.UID);
  if not Is_Null_UID(recv_io.UID) then
      FUID_Pool.Delete(recv_io.UID);

  recv_io.P2PName := p2p_name__;
  recv_io.UID := UID_;
  send_io.P2PName := p2p_name__;
  send_io.UID := UID_;

  FUID_Pool.Add(UID_, TUID_Data.Get(recv_io, send_io), True);

  if p2p_name__ <> '' then
      FP2PName_Pool.Update_UID(p2p_name__, UID_);

  recv_io.p2p_api_info_data.Clear;
  for i := 0 to p2p_api_.Count - 1 do recv_io.p2p_api_info_data.Add(p2p_api_[i].Text, nil, False);

  Schedule_API_Info_Broadcast();
end;

procedure TC40_LF_Service.DoLinkSuccess_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth);
var
  user_io: TC40_LF_RecvTunnel;
begin
  inherited DoLinkSuccess_Event(Sender, UserDefineIO);
  user_io := UserDefineIO as TC40_LF_RecvTunnel;
  user_io.LF_Service := Self;
  (user_io.SendTunnel as TC40_LF_SendTunnel).LF_Service := Self;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service.DoLinkSuccess_Event: peer=%s', [user_io.Owner.GetPeerIP]);
    end;
end;

procedure TC40_LF_Service.DoUserOut_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth);
var
  user_io: TC40_LF_RecvTunnel;
begin
  user_io := UserDefineIO as TC40_LF_RecvTunnel;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service.DoUserOut_Event: app="%s" p2p="%s" peer=%s',
        [user_io.APP_Name.Text, user_io.P2PName.Text, user_io.Owner.GetPeerIP]);
    end;

  if FUID_Pool <> nil then
      FUID_Pool.Delete(user_io.UID);

  if FP2PName_Pool <> nil then
      FP2PName_Pool.Remove_UID(user_io.P2PName, user_io.UID);

  if FAPI_Lookup_Cache <> nil then
    begin
      FAPI_Lookup_Cache.Clear;
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('Service: API cache invalidated by DoUserOut_Event');
        end;
    end;

  Schedule_API_Info_Broadcast();
  inherited DoUserOut_Event(Sender, UserDefineIO);
end;

procedure TC40_LF_Service.cmd_Update_UID(Sender: TPeerIO; InData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
  send_io: TC40_LF_SendTunnel;
  tmp_p2p_name: TLF_String;
  tmp_uid: TUID___;
  p2p_api_info_data: TPascalStringList;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_Update_UID: ENTER peer=%s', [Sender.GetPeerIP]);
    end;

  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  if user_io = nil then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('SVC.cmd_Update_UID: user_io=nil, exit');
        end;
      exit;
    end;
  send_io := user_io.SendTunnel as TC40_LF_SendTunnel;

  tmp_p2p_name.Text := InData.R.ReadString;
  tmp_uid := PUID___(InData.R.ReadArrayByte.Buffer__.Memory)^;
  p2p_api_info_data := TPascalStringList.Create;
  InData.R.ReadPascalStrings(p2p_api_info_data);

  Update_P2PName_And_UID(tmp_p2p_name, tmp_uid, p2p_api_info_data, user_io, send_io);

  DisposeObject(p2p_api_info_data);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_Update_UID: EXIT p2p="%s"', [tmp_p2p_name.Text]);
    end;
end;

procedure TC40_LF_Service.cmd_Init_APP_Info(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
  L: TPascalStringList;
  i: Integer;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_Init_APP_Info: ENTER');
    end;

  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender.R_IO) as TC40_LF_RecvTunnel;
  if user_io = nil then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('SVC.cmd_Init_APP_Info: user_io=nil, exit');
        end;
      exit;
    end;
  user_io.APP_Name := InData.R.ReadString;
  user_io.APP_Desc := InData.R.ReadString;
  user_io.APP_Process_Info := InData.R.ReadString;
  user_io.api_info_data.Clear;
  L := TPascalStringList.Create;
  InData.R.ReadPascalStrings(L);
  for i := 0 to L.Count - 1 do
      user_io.api_info_data.Add(L[i], nil, False);
  DisposeObject(L);
  user_io.Is_Local := InData.R.ReadBool;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_Init_APP_Info: app="%s" api_count=%d is_local=%s',
        [user_io.APP_Name.Text, user_io.api_info_data.Count, BoolToStr(user_io.Is_Local, True)]);
    end;

  if FAPI_Lookup_Cache <> nil then
    begin
      FAPI_Lookup_Cache.Clear;
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('Service: API cache invalidated by cmd_Init_APP_Info (app="%s")', [user_io.APP_Name.Text]);
        end;
    end;

  if user_io.APP_Name.StrExists(C_Generate_Prefix) then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('SVC.cmd_Init_APP_Info: auto-generated app, immediate broadcast');
        end;
      Broadcast_API_Info;
      FBroadcast_Scheduled := False;
    end
  else Schedule_API_Info_Broadcast();
end;

procedure TC40_LF_Service.cmd_No_App_Info(Sender: TPeerIO; InData: SystemString);
var
  user_io: TC40_LF_RecvTunnel;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_No_App_Info: ENTER msg="%s"', [InData]);
    end;

  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  if user_io = nil then exit;
  user_io.APP_Name := '';
  user_io.APP_Desc := '';
  user_io.APP_Process_Info := InData;
  user_io.api_info_data.Clear;
  user_io.Is_Local := False;

  if FAPI_Lookup_Cache <> nil then
    begin
      FAPI_Lookup_Cache.Clear;
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('Service: API cache invalidated by cmd_No_App_Info');
        end;
    end;

  Schedule_API_Info_Broadcast();
end;

procedure TC40_LF_Service.Run_Notify_Worker(thSender: THPC_StreamNotify; ThInData: TDFE);
var
  tmp_cli__: TC40_LF_Client;
  app_Name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
begin
  tmp_cli__ := thSender.UserObject as TC40_LF_Client;
  app_Name__ := ThInData.R.ReadString;
  Param := TMem64.Create;
  ThInData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.Run_Notify_Worker: app="%s" api="%s"',
        [app_Name__.Text, api_Name__.Text]);
    end;

  tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ + 1);
  try
      tmp_cli__.APP.Engine.Execute_Notify(Param);
  finally
      tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ - 1);
  end;
  DisposeObject(Param);
end;

procedure TC40_LF_Service.cmd_Notify(Sender: TPeerIO; InData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
  app_Name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  tmp_cli__: TC40_LF_Client;
  function Search_API_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    IO__: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) > 0 then
      begin
        for i := 0 to length(arry) - 1 do
          begin
            serv := arry[i] as TC40_LF_Service;
            IO__ := serv.Find_API(app_Name__, api_Name__);
            if IO__ <> nil then
              begin
                IO__.SendTunnel.Owner.SendCompleteBuffer('Notify', Param.NewClone, True);
                Result := True;
                exit;
              end;
          end;
      end;
  end;

begin
  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  app_Name__ := InData.R.ReadString;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_Notify: ENTER app="%s" api="%s" peer=%s',
        [app_Name__.Text, api_Name__.Text, Sender.GetPeerIP]);
    end;

  tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('SVC.cmd_Notify: LOCAL path, HPC dispatch');
        end;
      InData.R.Index := 0;
      DisposeObject(Param);
      RunHPC_StreamNotifyM(Sender, nil, tmp_cli__, InData, Run_Notify_Worker);
      exit;
    end;
  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_API_And_Send then
        exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_API_And_Send then
        exit;
    DoStatus('no found app("%s") api("%s")', [app_Name__.Text, api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.cmd_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
  app_Name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  tmp_cli__: TC40_LF_Client;
  function Search_API_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    IO__: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) > 0 then
      begin
        for i := 0 to length(arry) - 1 do
          begin
            serv := arry[i] as TC40_LF_Service;
            IO__ := serv.Find_Fixed_Sequenced_API(app_Name__, api_Name__);
            if IO__ <> nil then
              begin
                IO__.SendTunnel.Owner.SendCompleteBuffer('Sequenced_Notify', Param.NewClone, True);
                Result := True;
                exit;
              end;
          end;
      end;
  end;

begin
  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  app_Name__ := InData.R.ReadString;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_Sequenced_Notify: ENTER app="%s" api="%s"',
        [app_Name__.Text, api_Name__.Text]);
    end;

  tmp_cli__ := Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__);
  if tmp_cli__ <> nil then
    begin
      LF_Notify_Sequence_Thread_Pool.Post_Notify2(tmp_cli__.APP, Param.NewClone());
      DisposeObject(Param);
      exit;
    end;
  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_API_And_Send then
        exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_API_And_Send then
        exit;
    DoStatus('no found app("%s") api("%s")', [app_Name__.Text, api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.Run_Call_Worker(thSender: THPC_CompleteBuffer_Stream; ThInData, ThOutData: TDFE);
var
  tmp_cli__: TC40_LF_Client;
  app_Name__: TLF_String;
  Param, Output: TMem64;
  api_Name__: TLF_String;
begin
  tmp_cli__ := thSender.UserObject as TC40_LF_Client;
  app_Name__ := ThInData.R.ReadString;
  Param := TMem64.Create;
  ThInData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.Run_Call_Worker: app="%s" api="%s"',
        [app_Name__.Text, api_Name__.Text]);
    end;

  tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ + 1);
  try
      Output := tmp_cli__.APP.Engine.Execute_Call(Param);
  finally
      tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ - 1);
  end;
  DisposeObject(Param);
  ThOutData.WriteMem64(Output);
  DisposeObject(Output);
end;

procedure TC40_LF_Service.cmd_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  app_Name__: TLF_String;
  Param, Output: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  tmp_cli__: TC40_LF_Client;
  function Search_API_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    IO__: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) > 0 then
      begin
        for i := 0 to length(arry) - 1 do
          begin
            serv := arry[i] as TC40_LF_Service;
            IO__ := serv.Find_API(app_Name__, api_Name__);
            if IO__ <> nil then
              begin
                IO__.SendTunnel.Owner.SendCompleteBuffer_NoWait_StreamM('Call', InData,
                  TCompleteBuffer_Stream_Event_Bridge.Create(Sender, True).DoStreamEvent);
                Result := True;
                exit;
              end;
          end;
      end;
  end;

begin
  app_Name__ := InData.R.ReadString;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_Call: ENTER app="%s" api="%s"',
        [app_Name__.Text, api_Name__.Text]);
    end;

  InData.R.Index := 0;
  tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('SVC.cmd_Call: LOCAL path, HPC dispatch');
        end;
      DisposeObject(Param);
      RunHPC_CompleteBuffer_StreamM(Sender, nil, tmp_cli__, InData, OutData, Run_Call_Worker);
      exit;
    end;
  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_API_And_Send then
        exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_API_And_Send then
        exit;
    DoStatus('no found app("%s") api("%s")', [app_Name__.Text, api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.cmd_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  app_Name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  tmp_cli__: TC40_LF_Client;

  function Search_API_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    IO__: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) > 0 then
      begin
        for i := 0 to length(arry) - 1 do
          begin
            serv := arry[i] as TC40_LF_Service;
            IO__ := serv.Find_Fixed_Sequenced_API(app_Name__, api_Name__);
            if IO__ <> nil then
              begin
                IO__.SendTunnel.Owner.SendCompleteBuffer_NoWait_StreamM('Sequenced_Call', InData,
                  TCompleteBuffer_Stream_Event_Bridge.Create(Sender, True).DoStreamEvent);
                Result := True;
                exit;
              end;
          end;
      end;
  end;

begin
  app_Name__ := InData.R.ReadString;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_Sequenced_Call: ENTER app="%s" api="%s"',
        [app_Name__.Text, api_Name__.Text]);
    end;

  tmp_cli__ := Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__);
  if tmp_cli__ <> nil then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('SVC.cmd_Sequenced_Call: LOCAL path, Post_Call2 pool (app=%p)',
            [Pointer(tmp_cli__.APP)]);
        end;
      LF_Call_Sequence_Thread_Pool.Post_Call2(tmp_cli__.APP, Param.NewClone(),
        TSequence_Call_Bridge.Create(Sender).Do_Sequence_Call_Done);
      DisposeObject(Param);
      exit;
    end;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_API_And_Send then
        exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_API_And_Send then
        exit;
    DoStatus('no found app("%s") api("%s")', [app_Name__.Text, api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.Run_UID_Notify_Worker(thSender: THPC_StreamNotify; ThInData: TDFE);
var
  Param: TMem64;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  ThInData.R.Next;
  Param := TMem64.Create;
  ThInData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  target_app := Find_API_From_P2P_APP(api_Name__);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.Run_UID_Notify_Worker: api="%s" target=%p',
        [api_Name__.Text, Pointer(target_app)]);
    end;

  if target_app <> nil then
      target_app.Engine.Execute_Notify(Param);
  DisposeObject(Param);
end;

procedure TC40_LF_Service.cmd_UID_Notify(Sender: TPeerIO; InData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
  UID_: TUID___;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;

  function Search_API_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    IO__: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) > 0 then
      begin
        for i := 0 to length(arry) - 1 do
          begin
            serv := arry[i] as TC40_LF_Service;
            IO__ := serv.Find_UID(UID_, api_Name__);
            if IO__ <> nil then
              begin
                IO__.SendTunnel.Owner.SendCompleteBuffer('UID_Notify', Param.NewClone, True);
                Result := True;
                exit;
              end;
          end;
      end;
  end;

begin
  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  UID_ := PUID___(InData.R.ReadArrayByte.Buffer__.Memory)^;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_UID_Notify: ENTER api="%s"',
        [api_Name__.Text]);
    end;

  if Find_Local_UID_App(UID_, api_Name__) <> nil then
    begin
      InData.R.Index := 0;
      DisposeObject(Param);
      RunHPC_StreamNotifyM(Sender, nil, nil, InData, Run_UID_Notify_Worker);
      exit;
    end;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_API_And_Send then
        exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_API_And_Send then
        exit;
    DoStatus('no found uid:%s api("%s")', [TCipher.HashToString(UID_), api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.cmd_UID_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
  UID_: TUID___;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  target_app: TLF_App;

  function Search_API_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    IO__: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) > 0 then
      begin
        for i := 0 to length(arry) - 1 do
          begin
            serv := arry[i] as TC40_LF_Service;
            IO__ := serv.Find_UID(UID_, api_Name__);
            if IO__ <> nil then
              begin
                IO__.SendTunnel.Owner.SendCompleteBuffer('UID_Sequenced_Notify', Param.NewClone, True);
                Result := True;
                exit;
              end;
          end;
      end;
  end;

begin
  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  UID_ := PUID___(InData.R.ReadArrayByte.Buffer__.Memory)^;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_UID_Sequenced_Notify: ENTER api="%s"',
        [api_Name__.Text]);
    end;

  target_app := Find_Local_UID_App(UID_, api_Name__);
  if target_app <> nil then
    begin
      LF_Notify_Sequence_Thread_Pool.Post_Notify2(target_app, Param.NewClone());
      DisposeObject(Param);
      exit;
    end;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_API_And_Send then
        exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_API_And_Send then
        exit;
    DoStatus('no found uid:%s api("%s")', [TCipher.HashToString(UID_), api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.Run_UID_Call_Worker(thSender: THPC_CompleteBuffer_Stream; ThInData, ThOutData: TDFE);
var
  Param, Output: TMem64;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  ThInData.R.Next;
  Param := TMem64.Create;
  ThInData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  target_app := Find_API_From_P2P_APP(api_Name__);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.Run_UID_Call_Worker: api="%s" target=%p',
        [api_Name__.Text, Pointer(target_app)]);
    end;

  try
    if target_app <> nil then
        Output := target_app.Engine.Execute_Call(Param)
    else
        Output := TMem64.Create;
    ThOutData.WriteMem64(Output);
    DisposeObject(Output);
  finally
      DisposeObject(Param);
  end;
end;

procedure TC40_LF_Service.cmd_UID_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  UID_: TUID___;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  ab: TDF_ArrayByte;

  function Search_UID_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    IO__: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) <= 0 then exit;
    for i := 0 to length(arry) - 1 do
      begin
        serv := arry[i] as TC40_LF_Service;
        IO__ := serv.Find_UID(UID_, api_Name__);
        if IO__ <> nil then
          begin
            IO__.SendTunnel.Owner.SendCompleteBuffer_NoWait_StreamM('UID_Call', InData,
              TCompleteBuffer_Stream_Event_Bridge.Create(Sender, True).DoStreamEvent);
            Result := True;
            exit;
          end;
      end;
  end;

begin
  ab := InData.R.ReadArrayByte;
  if ab.Buffer__.Size < SizeOf(TUID___) then exit;
  ab.Buffer__.ReadPtr(@UID_, SizeOf(TUID___));
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_UID_Call: ENTER api="%s"',
        [api_Name__.Text]);
    end;

  InData.R.Index := 0;

  if Find_Local_UID_App(UID_, api_Name__) <> nil then
    begin
      DisposeObject(Param);
      RunHPC_CompleteBuffer_StreamM(Sender, nil, nil, InData, OutData, Run_UID_Call_Worker);
      exit;
    end;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_UID_And_Send then exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_UID_And_Send then exit;
    DoStatus('no found uid:%s api("%s")', [TCipher.HashToString(UID_), api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.cmd_UID_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  UID_: TUID___;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  ab: TDF_ArrayByte;
  target_app: TLF_App;

  function Search_UID_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    IO__: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) <= 0 then exit;
    for i := 0 to length(arry) - 1 do
      begin
        serv := arry[i] as TC40_LF_Service;
        IO__ := serv.Find_UID(UID_, api_Name__);
        if IO__ <> nil then
          begin
            IO__.SendTunnel.Owner.SendCompleteBuffer_NoWait_StreamM('UID_Sequenced_Call', InData,
              TCompleteBuffer_Stream_Event_Bridge.Create(Sender, True).DoStreamEvent);
            Result := True;
            exit;
          end;
      end;
  end;

begin
  ab := InData.R.ReadArrayByte;
  if ab.Buffer__.Size < SizeOf(TUID___) then exit;
  ab.Buffer__.ReadPtr(@UID_, SizeOf(TUID___));
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_UID_Sequenced_Call: ENTER api="%s"',
        [api_Name__.Text]);
    end;

  InData.R.Index := 0;

  target_app := Find_Local_UID_App(UID_, api_Name__);
  if target_app <> nil then
    begin
      LF_Call_Sequence_Thread_Pool.Post_Call2(target_app, Param.NewClone,
        TSequence_Call_Bridge.Create(Sender).Do_Sequence_Call_Done);
      DisposeObject(Param);
      exit;
    end;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_UID_And_Send then exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_UID_And_Send then exit;
    DoStatus('no found uid:%s api("%s")', [TCipher.HashToString(UID_), api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.cmd_P2PName_Notify(Sender: TPeerIO; InData: TDFE);
var
  p2p_name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;

  function Search_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    target: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) <= 0 then exit;
    for i := 0 to length(arry) - 1 do
      begin
        serv := arry[i] as TC40_LF_Service;
        target := serv.Find_P2PName_LoadBalance(p2p_name__, api_Name__);
        if target <> nil then
          begin
            target.SendTunnel.Owner.SendCompleteBuffer('P2PName_Notify', Param.NewClone, True);
            Result := True;
            exit;
          end;
      end;
  end;

begin
  p2p_name__ := InData.R.ReadString;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_P2PName_Notify: ENTER p2p="%s" api="%s"',
        [p2p_name__.Text, api_Name__.Text]);
    end;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_And_Send then exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_And_Send then exit;
    DoStatus('no found p2pname:"%s" api:"%s"', [p2p_name__.Text, api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.cmd_P2PName_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
var
  p2p_name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;

  function Search_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    target: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) <= 0 then exit;
    for i := 0 to length(arry) - 1 do
      begin
        serv := arry[i] as TC40_LF_Service;
        target := serv.Find_P2PName_FixedSequenced(p2p_name__, api_Name__);
        if target <> nil then
          begin
            target.SendTunnel.Owner.SendCompleteBuffer('P2PName_Sequenced_Notify', Param.NewClone, True);
            Result := True;
            exit;
          end;
      end;
  end;

begin
  p2p_name__ := InData.R.ReadString;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_P2PName_Sequenced_Notify: ENTER p2p="%s" api="%s"',
        [p2p_name__.Text, api_Name__.Text]);
    end;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_And_Send then exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_And_Send then exit;
    DoStatus('no found p2pname:"%s" api:"%s"', [p2p_name__.Text, api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.cmd_P2PName_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  p2p_name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;

  function Search_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    target: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) <= 0 then exit;
    for i := 0 to length(arry) - 1 do
      begin
        serv := arry[i] as TC40_LF_Service;
        target := serv.Find_P2PName_LoadBalance(p2p_name__, api_Name__);
        if target <> nil then
          begin
            target.SendTunnel.Owner.SendCompleteBuffer_NoWait_StreamM('P2PName_Call', InData,
              TCompleteBuffer_Stream_Event_Bridge.Create(Sender, True).DoStreamEvent);
            Result := True;
            exit;
          end;
      end;
  end;

begin
  p2p_name__ := InData.R.ReadString;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_P2PName_Call: ENTER p2p="%s" api="%s"',
        [p2p_name__.Text, api_Name__.Text]);
    end;

  InData.R.Index := 0;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_And_Send then exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_And_Send then exit;
    DoStatus('no found p2pname:"%s" api:"%s"', [p2p_name__.Text, api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

procedure TC40_LF_Service.cmd_P2PName_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  p2p_name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;

  function Search_And_Send(): Boolean;
  var
    i: Integer;
    serv: TC40_LF_Service;
    target: TC40_LF_RecvTunnel;
  begin
    Result := False;
    if length(arry) <= 0 then exit;
    for i := 0 to length(arry) - 1 do
      begin
        serv := arry[i] as TC40_LF_Service;
        target := serv.Find_P2PName_FixedSequenced(p2p_name__, api_Name__);
        if target <> nil then
          begin
            target.SendTunnel.Owner.SendCompleteBuffer_NoWait_StreamM('P2PName_Sequenced_Call', InData,
              TCompleteBuffer_Stream_Event_Bridge.Create(Sender, True).DoStreamEvent);
            Result := True;
            exit;
          end;
      end;
  end;

begin
  p2p_name__ := InData.R.ReadString;
  Param := TMem64.Create;
  InData.R.ReadMem64_As_Mapping(Param);
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SVC.cmd_P2PName_Sequenced_Call: ENTER p2p="%s" api="%s"',
        [p2p_name__.Text, api_Name__.Text]);
    end;

  InData.R.Index := 0;

  try
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, True);
    if Search_And_Send then exit;
    arry := Z.Net.C4.C40_ServicePool.GetFromClass(TC40_LF_Service, False);
    if Search_And_Send then exit;
    DoStatus('no found p2pname:"%s" api:"%s"', [p2p_name__.Text, api_Name__.Text]);
  finally
    DisposeObject(Param);
    SetLength(arry, 0);
  end;
end;

constructor TC40_LF_Service.Create(PhysicsService_: TC40_PhysicsService; ServiceTyp, Param_: U_String);
var
  bak_: Boolean;
begin
  bak_ := C40_EnablePerServiceDirectory;
  C40_EnablePerServiceDirectory := False;
  inherited Create(PhysicsService_, ServiceTyp, Param_);
  C40_EnablePerServiceDirectory := bak_;
  DTNoAuth.FileSystem := False;

  FNext_Broadcast_Tick := 0;
  FBroadcast_Scheduled := False;
  FAPI_Lookup_Cache := TAPI_Lookup_Cache.Create(1024, nil);
  Init_UID_And_P2PName();

  ServiceInfo.OnlyInstance := False;

  DTNoAuth.RecvTunnel.UserDefineClass := TC40_LF_RecvTunnel;
  DTNoAuth.SendTunnel.UserDefineClass := TC40_LF_SendTunnel;

  DTNoAuth.RecvTunnel.MaxCompleteBufferSize := EStrToInt64(ParamList.GetDefaultValue('MaxBuffer', '500*1024*1024'), 500 * 1024 * 1024);
  DTNoAuth.SendTunnel.MaxCompleteBufferSize := EStrToInt64(ParamList.GetDefaultValue('MaxBuffer', '500*1024*1024'), 500 * 1024 * 1024);
  DTNoAuth.RecvTunnel.CompleteBufferCompressed := False;

  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('Update_UID').OnExecute := cmd_Update_UID;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('Init_APP_Info').OnExecute := cmd_Init_APP_Info;
  DTNoAuth.RecvTunnel.RegisterConsoleNotify('No_App_Info').OnExecute := cmd_No_App_Info;

  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('Notify').OnExecute := cmd_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('Sequenced_Notify').OnExecute := cmd_Sequenced_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('Call').OnExecute := cmd_Call;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('Sequenced_Call').OnExecute := cmd_Sequenced_Call;

  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('UID_Notify').OnExecute := cmd_UID_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('UID_Sequenced_Notify').OnExecute := cmd_UID_Sequenced_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('UID_Call').OnExecute := cmd_UID_Call;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('UID_Sequenced_Call').OnExecute := cmd_UID_Sequenced_Call;

  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('P2PName_Notify').OnExecute := cmd_P2PName_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('P2PName_Sequenced_Notify').OnExecute := cmd_P2PName_Sequenced_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('P2PName_Call').OnExecute := cmd_P2PName_Call;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('P2PName_Sequenced_Call').OnExecute := cmd_P2PName_Sequenced_Call;

  DTNoAuth.RecvTunnel.PrintParams.Add('Update_UID', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('update_service_api_info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Init_APP_Info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('No_App_Info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Sequenced_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Sequenced_Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('UID_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('UID_Sequenced_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('UID_Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('UID_Sequenced_Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('P2PName_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('P2PName_Sequenced_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('P2PName_Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('P2PName_Sequenced_Call', False, True);

  DTNoAuth.SendTunnel.PrintParams.Add('Update_UID', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('update_service_api_info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Init_APP_Info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('No_App_Info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Sequenced_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Sequenced_Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('UID_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('UID_Sequenced_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('UID_Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('UID_Sequenced_Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('P2PName_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('P2PName_Sequenced_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('P2PName_Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('P2PName_Sequenced_Call', False, True);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TC40_LF_Service.Create: param="%s"', [Param_.Text]);
    end;
end;

destructor TC40_LF_Service.Destroy;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TC40_LF_Service.Destroy: begin');
    end;
  StopService;
  DisposeObjectAndNil(FAPI_Lookup_Cache);
  Free_UID_And_P2PName();
  inherited Destroy;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TC40_LF_Service.Destroy: done');
    end;
end;

procedure TC40_LF_Service.SafeCheck;
begin
  inherited SafeCheck;
end;

procedure TC40_LF_Service.Progress;
begin
  inherited Progress;
  if FBroadcast_Scheduled then
    begin
      if GetTimeTick() > FNext_Broadcast_Tick then
        begin
          if LF_Debug_Log_Enabled then
            begin
              LF_Debug_Log('Service.Progress: scheduled broadcast fires');
            end;
          Broadcast_API_Info;
          FBroadcast_Scheduled := False;
        end;
    end;
end;

procedure TC40_LF_Service.Broadcast_API_Info();
var
  alive: TC40_LF_RecvTunnelList;
  arry: TIO_Array;
  ID_: Cardinal;
  IO_: TPeerIO;
  tun: TC40_LF_RecvTunnel;
  payload: TMS64;
  sub, envelope: TDFE;
  pool: TLF_ServiceInfoPool;
  uid_tool: TUID_Info_Tool;
begin
  alive := TC40_LF_RecvTunnelList.Create;
  try
    DTNoAuth.RecvTunnel.GetIO_Array(arry);
    for ID_ in arry do
      begin
        IO_ := DTNoAuth.RecvTunnel.PeerIO[ID_];
        if IO_ = nil then Continue;
        tun := IO_.Define as TC40_LF_RecvTunnel;
        if tun.LinkOk then alive.Add(tun);
      end;

    if LF_Debug_Log_Enabled then
      begin
        LF_Debug_Log('Service.Broadcast_API_Info: alive=%d', [alive.Num]);
      end;

    if alive.Num <= 0 then exit;

    pool := TLF_ServiceInfoPool.Create;
    uid_tool := TUID_Info_Tool.Create;
    envelope := TDFE.Create;
    payload := TMS64.CustomCreate($FFFF);
    try
      with alive.Repeat_ do
        repeat
          pool.Build_Info_Form(queue^.Data);
          uid_tool.Import_From(queue^.Data);
        until not Next;

      sub := TDFE.Create;
      try
        pool.SaveToStream(sub);
        envelope.WriteDFE(sub);
      finally
          DisposeObject(sub);
      end;

      sub := TDFE.Create;
      try
        uid_tool.SaveToStream(sub);
        envelope.WriteDFE(sub);
      finally
          DisposeObject(sub);
      end;

      envelope.FastEncodeTo(payload);
      payload.Position := 0;

      with alive.Repeat_ do
        repeat
            queue^.Data.SendTunnel.Owner.SendCompleteBuffer('update_service_api_info', payload.NewClone, True);
        until not Next;
    finally
      DisposeObject(pool);
      DisposeObject(uid_tool);
      DisposeObject(envelope);
      DisposeObject(payload);
    end;
  finally
      DisposeObject(alive);
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service.Broadcast_API_Info done');
    end;
end;

function TC40_LF_Service.Compare_Client_Cycle_Anchor(var L, R: TC40_LF_RecvTunnel): Integer;
begin
  Result := CompareInt64(L.Cycle_Int64_Anchor, R.Cycle_Int64_Anchor);
end;

function TC40_LF_Service.Find_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
var
  arry: TIO_Array;
  ID_: Cardinal;
  IO_: TPeerIO;
  tmp: TC40_LF_RecvTunnel;
  L: TC40_LF_RecvTunnelList;
  n: SystemString;
  cache_hit: Boolean;
begin
  Result := nil;
  n := PFormat('%s.%s', [app_Name__.Text, api_Name__.Text]);

  cache_hit := True;
  L := FAPI_Lookup_Cache.Get_Key_Value(n);
  if L = nil then
    begin
      cache_hit := False;
      L := TC40_LF_RecvTunnelList.Create;
      FAPI_Lookup_Cache.Add(n, L, False);
      DTNoAuth.RecvTunnel.GetIO_Array(arry);
      for ID_ in arry do
        begin
          IO_ := DTNoAuth.RecvTunnel.PeerIO[ID_];
          if IO_ <> nil then
            begin
              tmp := IO_.Define as TC40_LF_RecvTunnel;
              if app_Name__.Same(tmp.APP_Name) and tmp.api_info_data.Exists(api_Name__) then
                  L.Add(tmp);
            end;
        end;
    end;

  if L.Num > 0 then
    with L.Repeat_ do
      repeat
          queue^.Data.Cycle_Int64_Anchor := queue^.Data.Cycle_Int64_Anchor_Tool[n];
      until not Next;

  L.Sort_M(Compare_Client_Cycle_Anchor);

  if L.Num > 0 then
    begin
      Result := L.First^.Data;
      Result.Cycle_Int64_Anchor_Tool[n] := Get_Cycle_Anchor();
    end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Svc.Find_API: key="%s" hit=%s result=%p', [n, if_(cache_hit, 'yes', 'no'), Pointer(Result)]);
    end;
end;

function TC40_LF_Service.Find_UID(UID_: TUID___; api_Name__: TLF_String): TC40_LF_RecvTunnel;
var
  P: TUID_Hash_Pool.PValue_;
begin
  Result := nil;
  P := FUID_Pool.Get_Value_Ptr___(UID_);
  if P = nil then exit;
  if P^.recv_io = nil then exit;
  if P^.send_io = nil then exit;
  if P^.recv_io.api_info_data.Exists(api_Name__.Text) or P^.recv_io.p2p_api_info_data.Exists(api_Name__.Text) then
      Result := P^.recv_io;
end;

function TC40_LF_Service.Compare_Client_Fixed_Sequence(var L, R: TC40_LF_RecvTunnel): Integer;
begin
  Result := CompareUInt64(R.Fixed_Sequenced_Temp_Time, L.Fixed_Sequenced_Temp_Time);
end;

function TC40_LF_Service.Find_Fixed_Sequenced_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
var
  arry: TIO_Array;
  ID_: Cardinal;
  IO_: TPeerIO;
  tmp: TC40_LF_RecvTunnel;
  L: TC40_LF_RecvTunnelList;
  n: SystemString;
  i: Integer;
begin
  Result := nil;
  DTNoAuth.RecvTunnel.GetIO_Array(arry);
  L := TC40_LF_RecvTunnelList.Create;
  for ID_ in arry do
    begin
      IO_ := DTNoAuth.RecvTunnel.PeerIO[ID_];
      if IO_ <> nil then
        begin
          tmp := IO_.Define as TC40_LF_RecvTunnel;
          if app_Name__.Same(tmp.APP_Name) and tmp.api_info_data.Exists(api_Name__) then
              L.Add(tmp);
        end;
    end;
  n := PFormat('%s.%s', [app_Name__.Text, api_Name__.Text]);
  if L.Num > 0 then
    begin
      with L.Repeat_ do
        repeat
            queue^.Data.Fixed_Sequenced_Temp_Time := queue^.Data.Fixed_Sequenced_Pool.Get_Default_Value(n, 0);
        until not Next;
      L.Sort_M(Compare_Client_Fixed_Sequence);
    end;
  if L.Num > 0 then
    begin
      Result := L.First^.Data;
      if GetTimeTick() - Result.Fixed_Sequenced_Temp_Time > Fixed_Sequenced_Time then
          Result := L.Last^.Data;
      Result.Fixed_Sequenced_Pool.Set_Key_Value(n, GetTimeTick());
    end;
  DisposeObject(L);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Svc.Find_Fixed_Sequenced_API: key="%s" result=%p', [n, Pointer(Result)]);
    end;
end;

function TC40_LF_Service.Find_P2PName_LoadBalance(p2p_name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
var
  UIDList: TP2PName_UID_List;
  PtrList: TP2PName_UID_Ptr_List;
  i: Integer;
  P: TUID_Hash_Pool.PValue_;
  taskKey: SystemString;
  selected: PP2PName_UID;
begin
  Result := nil;
  UIDList := FP2PName_Pool.Get_Key_Value(p2p_name__);
  if (UIDList = nil) or (UIDList.Num <= 0) then exit;

  taskKey := PFormat('%s.%s', [p2p_name__.Text, api_Name__.Text]);
  PtrList := TP2PName_UID_Ptr_List.Create;
  try
    with UIDList.Repeat_ do
      repeat
        P := FUID_Pool.Get_Value_Ptr___(queue^.Data.Primary);
        if (P <> nil) and (P^.recv_io <> nil) and (P^.send_io <> nil)
          and P^.recv_io.p2p_api_info_data.Exists(api_Name__.Text) then
            PtrList.Add(@queue^.Data);
      until not Next;

    if PtrList.Num <= 0 then exit;

    PtrList.Sort_By_Cycle_Anchor(taskKey);
    selected := PtrList.First^.Data;
    P := FUID_Pool.Get_Value_Ptr___(selected^.Primary);
    if (P = nil) or (P^.recv_io = nil) then exit;
    Result := P^.recv_io;
    selected^.Third[taskKey] := Get_Cycle_Anchor();
  finally
      DisposeObject(PtrList);
  end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Svc.Find_P2PName_LoadBalance: p2p="%s" api="%s" result=%p',
        [p2p_name__.Text, api_Name__.Text, Pointer(Result)]);
    end;
end;

function TC40_LF_Service.Find_P2PName_FixedSequenced(p2p_name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
var
  UIDList: TP2PName_UID_List;
  PtrList: TP2PName_UID_Ptr_List;
  P: TUID_Hash_Pool.PValue_;
  taskKey: SystemString;
  selected: PP2PName_UID;
begin
  Result := nil;
  UIDList := FP2PName_Pool.Get_Key_Value(p2p_name__);
  if (UIDList = nil) or (UIDList.Num <= 0) then exit;

  taskKey := PFormat('%s.%s', [p2p_name__.Text, api_Name__.Text]);
  PtrList := TP2PName_UID_Ptr_List.Create;
  try
    with UIDList.Repeat_ do
      repeat
        P := FUID_Pool.Get_Value_Ptr___(queue^.Data.Primary);
        if (P <> nil) and (P^.recv_io <> nil) and (P^.send_io <> nil)
          and P^.recv_io.p2p_api_info_data.Exists(api_Name__.Text) then
            PtrList.Add(@queue^.Data);
      until not Next;

    if PtrList.Num <= 0 then exit;

    PtrList.Sort_By_Sequenced_Time(taskKey);
    selected := PtrList.First^.Data;
    if (GetTimeTick() - selected^.Fourth) > Fixed_Sequenced_Time then
        selected := PtrList.Last^.Data;

    P := FUID_Pool.Get_Value_Ptr___(selected^.Primary);
    if (P = nil) or (P^.recv_io = nil) then exit;
    Result := P^.recv_io;
    selected^.Fourth := GetTimeTick();
  finally
      DisposeObject(PtrList);
  end;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Svc.Find_P2PName_FixedSequenced: p2p="%s" api="%s" result=%p',
        [p2p_name__.Text, api_Name__.Text, Pointer(Result)]);
    end;
end;

procedure TC40_LF_Client.Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender: TDT_P2PVM_NoAuth_Custom_Client);
begin
  inherited Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender);
  if Is_Null_UID(FLast_UID) then
      FLast_UID := Generate_Global_UID(PhysicsTunnel.UID, DTNoAuth.RecvTunnel.ServerState^.UID, DTNoAuth.SendTunnel.ServerState^.UID)
  else
      FLast_UID := Generate_Global_UID(FLast_UID, PhysicsTunnel.UID, DTNoAuth.RecvTunnel.ServerState^.UID, DTNoAuth.SendTunnel.ServerState^.UID);

  FSent_No_Response_Cmd_Num.V := 0;
  FHost_Running_Thread_Num.V := 0;
  FWait_Reponse_Thread_Num.V := 0;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.TunnelLink: tag=%d uid regenerated', [Tag]);
    end;

  Init_App_Info;
end;

procedure TC40_LF_Client.cmd_update_service_api_info(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
var
  input_stream: TMS64;
  envelope_dfe: TDFE;
  service_info_dfe: TDFE;
  uid_info_dfe: TDFE;
  remote_addr: TLF_String;
begin
  input_stream := TMS64.Create;
  input_stream.Mapping(InData, DataSize);
  envelope_dfe := TDFE.Create;
  envelope_dfe.DecodeFrom(input_stream, True);
  DisposeObject(input_stream);

  service_info_dfe := TDFE.Create;
  uid_info_dfe := TDFE.Create;
  envelope_dfe.R.ReadDFE(service_info_dfe);
  envelope_dfe.R.ReadDFE(uid_info_dfe);
  DisposeObject(envelope_dfe);

  Find_Safe_Critical.Lock;
  try
    FService_Info.LoadFromStream(service_info_dfe);
    FUID_Info_Tool.LoadFromStream(uid_info_dfe);
  finally
      Find_Safe_Critical.UnLock;
  end;
  DisposeObject(service_info_dfe);
  DisposeObject(uid_info_dfe);

  LF_Invalidate_All_API_Cache;

  if not FService_Info_Is_Online then
    begin
      if C40PhysicsTunnel.IPC_Mode then
          remote_addr := C40PhysicsTunnel.PhysicsAddr
      else
          remote_addr := Build_Host_URL(C40PhysicsTunnel.PhysicsAddr, C40PhysicsTunnel.PhysicsPort);
      Do_LF_Network_Connect(remote_addr);
    end;
  FService_Info_Is_Online := True;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_update_service_api_info: service_info=%d uid_info=%d',
        [FService_Info.Num, FUID_Info_Tool.Num]);
    end;
end;

procedure TC40_LF_Client.Run_Notify_Worker(thSender: THPC_CompleteBuffer; ThInData: PByte; ThDataSize: NativeInt);
var
  m64: TMem64;
begin
  if FAPP = nil then
      exit;
  FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
  try
    m64 := TMem64.Create;
    m64.Mapping(ThInData, ThDataSize);
    FAPP.Engine.Execute_Notify(m64);
    DisposeObject(m64);
  finally
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
  end;
end;

procedure TC40_LF_Client.cmd_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
begin
  if FAPP = nil then
      exit;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_Notify: ENTER size=%d', [DataSize]);
    end;
  RunHPC_CompleteBufferM(Sender, nil, nil, InData, DataSize, Run_Notify_Worker);
end;

procedure TC40_LF_Client.cmd_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
var
  m64: TMem64;
  api_Name__: TLF_String;
begin
  if FAPP = nil then
      exit;
  m64 := TMem64.Create;
  m64.Mapping(InData, DataSize);
  api_Name__ := TMemory_Param_Tool.Get_apiName(m64);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_Sequenced_Notify: ENTER api="%s"', [api_Name__.Text]);
    end;

  LF_Notify_Sequence_Thread_Pool.Post_Notify2(APP, m64.NewClone);
  DisposeObject(m64);
end;

procedure TC40_LF_Client.cmd_Call(Sender: TPeerIO; InData, OutData: TDFE);
var
  tmp_app: TLF_App;
  app_Name__: TLF_String;
  m64, Output: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_Call: ENTER');
    end;
  FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
  try
    app_Name__ := InData.R.ReadString;
    m64 := TMem64.Create;
    InData.R.ReadMem64_As_Mapping(m64);
    tmp_app := Get_App_From_Pool(app_Name__);
    if tmp_app <> nil then Output := tmp_app.Engine.Execute_Call(m64)
    else Output := TMem64.Create;
    DisposeObject(m64);
    OutData.WriteMem64(Output);
    DisposeObject(Output);
  finally
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
  end;
end;

procedure TC40_LF_Client.cmd_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  tmp_app: TLF_App;
  app_Name__: TLF_String;
  m64, Output: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_Sequenced_Call: ENTER');
    end;
  FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
  try
    app_Name__ := InData.R.ReadString;
    m64 := TMem64.Create;
    InData.R.ReadMem64_As_Mapping(m64);
    tmp_app := Get_App_From_Pool(app_Name__);

    if tmp_app <> nil then
      begin
        LF_Call_Sequence_Thread_Pool.Post_Call2(tmp_app, m64.NewClone(),
          TSequence_Call_Bridge.Create(Sender).Do_Sequence_Call_Done);
      end
    else
      begin
        Output := TMem64.Create;
        OutData.WriteMem64(Output);
        DisposeObject(Output);
      end;

    DisposeObject(m64);
  finally
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
  end;
end;

procedure TC40_LF_Client.Run_UID_Notify_Worker(thSender: THPC_CompleteBuffer; ThInData: PByte; ThDataSize: NativeInt);
var
  m64: TMem64;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  m64 := TMem64.Create;
  m64.Mapping(ThInData, ThDataSize);
  api_Name__ := TMemory_Param_Tool.Get_apiName(m64);
  target_app := Find_API_From_P2P_APP(api_Name__);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Run_UID_Notify_Worker: api="%s" target=%p',
        [api_Name__.Text, Pointer(target_app)]);
    end;

  if target_app <> nil then
    begin
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
      try
          target_app.Engine.Execute_Notify(m64);
      finally
          FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
      end;
    end;
  DisposeObject(m64);
end;

procedure TC40_LF_Client.cmd_UID_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_UID_Notify: ENTER size=%d', [DataSize]);
    end;
  RunHPC_CompleteBufferM(Sender, nil, nil, InData, DataSize, Run_UID_Notify_Worker);
end;

procedure TC40_LF_Client.cmd_UID_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
var
  m64: TMem64;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  m64 := TMem64.Create;
  m64.Mapping(InData, DataSize);
  api_Name__ := TMemory_Param_Tool.Get_apiName(m64);
  target_app := Find_API_From_P2P_APP(api_Name__);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_UID_Sequenced_Notify: api="%s" target=%p',
        [api_Name__.Text, Pointer(target_app)]);
    end;

  if target_app <> nil then
      LF_Notify_Sequence_Thread_Pool.Post_Notify2(target_app, m64.NewClone);
  DisposeObject(m64);
end;

procedure TC40_LF_Client.cmd_UID_Call(Sender: TPeerIO; InData, OutData: TDFE);
var
  UID_: TUID___;
  m64, Output: TMem64;
  ab: TDF_ArrayByte;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_UID_Call: ENTER');
    end;
  FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
  try
    ab := InData.R.ReadArrayByte;
    if ab.Buffer__.Size < SizeOf(TUID___) then exit;
    ab.Buffer__.ReadPtr(@UID_, SizeOf(TUID___));
    m64 := TMem64.Create;
    InData.R.ReadMem64_As_Mapping(m64);
    try
      api_Name__ := TMemory_Param_Tool.Get_apiName(m64);
      target_app := Find_API_From_P2P_APP(api_Name__);
      if target_app <> nil then
          Output := target_app.Engine.Execute_Call(m64)
      else
          Output := TMem64.Create;
      OutData.WriteMem64(Output);
      DisposeObject(Output);
    finally
        DisposeObject(m64);
    end;
  finally
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
  end;
end;

procedure TC40_LF_Client.cmd_UID_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  UID_: TUID___;
  m64: TMem64;
  ab: TDF_ArrayByte;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_UID_Sequenced_Call: ENTER');
    end;
  FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
  try
    ab := InData.R.ReadArrayByte;
    if ab.Buffer__.Size < SizeOf(TUID___) then exit;
    ab.Buffer__.ReadPtr(@UID_, SizeOf(TUID___));
    m64 := TMem64.Create;
    InData.R.ReadMem64_As_Mapping(m64);
    try
      api_Name__ := TMemory_Param_Tool.Get_apiName(m64);
      target_app := Find_API_From_P2P_APP(api_Name__);
      if target_app <> nil then
          LF_Call_Sequence_Thread_Pool.Post_Call2(target_app, m64.NewClone(),
          TSequence_Call_Bridge.Create(Sender).Do_Sequence_Call_Done);
    finally
        DisposeObject(m64);
    end;
  finally
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
  end;
end;

procedure TC40_LF_Client.cmd_P2PName_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_P2PName_Notify: ENTER size=%d', [DataSize]);
    end;
  RunHPC_CompleteBufferM(Sender, nil, nil, InData, DataSize, Run_UID_Notify_Worker);
end;

procedure TC40_LF_Client.cmd_P2PName_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
var
  m64: TMem64;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  m64 := TMem64.Create;
  m64.Mapping(InData, DataSize);
  api_Name__ := TMemory_Param_Tool.Get_apiName(m64);
  target_app := Find_API_From_P2P_APP(api_Name__);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_P2PName_Sequenced_Notify: api="%s" target=%p',
        [api_Name__.Text, Pointer(target_app)]);
    end;

  if target_app <> nil then
      LF_Notify_Sequence_Thread_Pool.Post_Notify2(target_app, m64.NewClone);
  DisposeObject(m64);
end;

procedure TC40_LF_Client.cmd_P2PName_Call(Sender: TPeerIO; InData, OutData: TDFE);
var
  p2p_name__: TLF_String;
  m64, Output: TMem64;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_P2PName_Call: ENTER');
    end;
  FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
  try
    p2p_name__ := InData.R.ReadString;
    m64 := TMem64.Create;
    InData.R.ReadMem64_As_Mapping(m64);
    try
      api_Name__ := TMemory_Param_Tool.Get_apiName(m64);
      target_app := Find_API_From_P2P_APP(api_Name__);
      if target_app <> nil then
          Output := target_app.Engine.Execute_Call(m64)
      else
          Output := TMem64.Create;
      OutData.WriteMem64(Output);
      DisposeObject(Output);
    finally
        DisposeObject(m64);
    end;
  finally
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
  end;
end;

procedure TC40_LF_Client.cmd_P2PName_Sequenced_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  p2p_name__: TLF_String;
  m64: TMem64;
  api_Name__: TLF_String;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.cmd_P2PName_Sequenced_Call: ENTER');
    end;
  FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
  try
    p2p_name__ := InData.R.ReadString;
    m64 := TMem64.Create;
    InData.R.ReadMem64_As_Mapping(m64);
    try
      api_Name__ := TMemory_Param_Tool.Get_apiName(m64);
      target_app := Find_API_From_P2P_APP(api_Name__);
      if target_app <> nil then
          LF_Call_Sequence_Thread_Pool.Post_Call2(target_app, m64.NewClone(),
          TSequence_Call_Bridge.Create(Sender).Do_Sequence_Call_Done);
    finally
        DisposeObject(m64);
    end;
  finally
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
  end;
end;

procedure TC40_LF_Client.Do_APP_Update(Sender: TLF_App);
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Do_APP_Update: tag=%d', [Tag]);
    end;
  DTNoAuth.ProgressPost.PostExecuteM_NP(0, Init_App_Info);
end;

procedure TC40_LF_Client.Do_LF_P2P_APP_Update(Sender: TLF_App);
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Do_LF_P2P_APP_Update: tag=%d', [Tag]);
    end;
  DTNoAuth.ProgressPost.PostExecuteM_NP(0, Update_UID_Info);
end;

procedure TC40_LF_Client.Do_Update_UID_Info;
var
  api_info_data: TPascalStringList;
  d: TDFE;
begin
  if not Connected then exit;
  FLast_P2PName := LF_P2P_name.V;
  api_info_data := TPascalStringList.Create;
  LF_P2P_APP.Engine.LF_MethodPool.Export_API_List(api_info_data);
  if LF_App_Pool.Num > 0 then
    with LF_App_Pool.Invert_Repeat_ do
      repeat
          queue^.Data.Engine.LF_MethodPool.Export_API_List(api_info_data);
      until not Prev;

  d := TDFE.Create;
  d.WriteString(FLast_P2PName);
  d.WriteArrayByte.Buffer__.WritePtr(@FLast_UID[0], SizeOf(TUID___));
  d.WritePascalStrings(api_info_data);
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('Update_UID', d);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Update_UID_Info: p2p_name="%s" api_count=%d',
        [FLast_P2PName.Text, api_info_data.Count]);
    end;
  DisposeObject(d);
  DisposeObject(api_info_data);
end;

procedure TC40_LF_Client.Do_Init_App_Info;
var
  api_info_data: TPascalStringList;
  R: TLF_MethodPool.TRepeat___;
begin
  if not Connected then exit;
  if (APP = nil) or (APP.Name.TrimChar(#32#9) = '') then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('Client.Init_App_Info: no app, sending No_App_Info');
        end;
      DTNoAuth.SendTunnel.SendConsoleNotifyCmd('No_App_Info', Make_LingoFuse_Process_Name());
      exit;
    end;
  api_info_data := TPascalStringList.Create;
  APP.Engine.LF_MethodPool.Export_API_List(api_info_data);
  DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('Init_APP_Info',
    TDFE.Create
      .WriteString(APP.Name.Text)
      .WriteString(APP.Desc.Text)
      .WriteString(Make_LingoFuse_Process_Name())
      .WritePascalStrings(api_info_data)
      .WriteBool(IsLocal())
      .DelayFree,
    Do_Init_App_Info_Result);
  DisposeObject(api_info_data);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Init_App_Info: app="%s"', [APP.Name.Text]);
    end;
end;

procedure TC40_LF_Client.Do_Null_OnResult(Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
var
  result_param_: PLF_Data;
begin
  result_param_ := TLF_Data.New_Result_From(TMem64.Create, False);
  if Assigned(OnResult_) then
      OnResult_(Data_, result_param_);
  TLF_Data.Free_Data(result_param_);
end;

procedure TC40_LF_Client.Send_Execute_Notify_Impl(app_Name__: TLF_String; Param: TMem64);
begin
  if not Connected then
    begin
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_Execute_Notify_Impl: app="%s"', [app_Name__.Text]);
    end;
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('Notify',
    TDFE.Create
      .WriteString(app_Name__)
      .WriteMem64(Param)
      .DelayFree
    );
  Check_Param_And_Send_Queue(Param);
end;

procedure TC40_LF_Client.Send_Sequenced_Notify_Impl(app_Name__: TLF_String; Param: TMem64);
begin
  if not Connected then
    begin
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_Sequenced_Notify_Impl: app="%s"', [app_Name__.Text]);
    end;
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('Sequenced_Notify',
    TDFE.Create
      .WriteString(app_Name__)
      .WriteMem64(Param)
      .DelayFree
    );
  Check_Param_And_Send_Queue(Param);
end;

function TC40_LF_Client.Wait_Execute_Call_Impl(app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
var
  api_Name__: TLF_String;
  tmp: TLF_Call_Bridge;
  tk: TTimeTick;
begin
  if not Connected then
    begin
      exit(TMem64.Create);
    end;
  Result := nil;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Wait_Execute_Call_Impl: ENTER app="%s" api="%s" timeout=%d',
        [app_Name__.Text, api_Name__.Text, TimeOut__]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  tmp := TLF_Call_Bridge.Create;
  tmp.Cli := Self;
  tmp.IsRunning := True;
  DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('Call', TDFE.Create.WriteString(app_Name__).WriteMem64(Param).DelayFree, tmp.Do_Result);
  Check_Param_And_Send_Queue(Param);

  tk := GetTimeTick + TimeOut__;
  while tmp.IsRunning do
    begin
      TCompute.Sleep(100);
      if (LF_CheckMainThread <= 0) or ((TimeOut__ > 0) and (GetTimeTick > tk)) then
        begin
          FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
          DoStatus('%s -> %s call timeout', [app_Name__.Text, api_Name__.Text]);
          if LF_Debug_Log_Enabled then
            begin
              LF_Debug_Log('Client.Wait_Execute_Call_Impl: TIMEOUT app="%s" api="%s"',
                [app_Name__.Text, api_Name__.Text]);
            end;
          exit;
        end;
    end;
  Result := tmp.Output.Swap_To_New_Instance;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  DisposeObject(tmp);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Wait_Execute_Call_Impl: EXIT size=%d', [Result.Size]);
    end;
end;

procedure TC40_LF_Client.Async_Execute_Call_Impl(app_Name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
var
  api_Name__: TLF_String;
  tmp: TLF_Async_Call_Bridge;
begin
  if not Connected then
    begin
      Do_Null_OnResult(Data_, OnResult_);
      exit;
    end;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_Execute_Call_Impl: ENTER app="%s" api="%s"',
        [app_Name__.Text, api_Name__.Text]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  try
    tmp := TLF_Async_Call_Bridge.Create;
    tmp.Cli := Self;
    tmp.app_Name__ := app_Name__;
    tmp.api_Name__ := api_Name__;
    tmp.Data_ := Data_;
    tmp.OnResult := OnResult_;
    DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('Call', TDFE.Create.WriteString(app_Name__).WriteMem64(Param).DelayFree, tmp.Do_Result);
    if LF_Debug_Log_Enabled then
      begin
        LF_Debug_Log('Client.Async_Execute_Call_Impl: SENT (bridge=%p)', [Pointer(tmp)]);
      end;
  finally
      FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  end;

  Check_Param_And_Send_Queue(Param);
end;

procedure TC40_LF_Client.Async_Sequenced_Execute_Call_Impl(app_Name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
var
  api_Name__: TLF_String;
  tmp: TLF_Async_Sequenced_Call_Bridge;
begin
  if not Connected then
    begin
      Do_Null_OnResult(Data_, OnResult_);
      exit;
    end;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_Sequenced_Execute_Call_Impl: ENTER app="%s" api="%s"',
        [app_Name__.Text, api_Name__.Text]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  try
    tmp := TLF_Async_Sequenced_Call_Bridge.Create;
    tmp.Cli := Self;
    tmp.app_Name__ := app_Name__;
    tmp.api_Name__ := api_Name__;
    tmp.Data_ := Data_;
    tmp.OnResult := OnResult_;
    DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('Sequenced_Call', TDFE.Create.WriteString(app_Name__).WriteMem64(Param).DelayFree, tmp.Do_Result);
    if LF_Debug_Log_Enabled then
      begin
        LF_Debug_Log('Client.Async_Sequenced_Execute_Call_Impl: SENT (bridge=%p)', [Pointer(tmp)]);
      end;
  finally
      FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  end;

  Check_Param_And_Send_Queue(Param);
end;

procedure TC40_LF_Client.Send_UID_Execute_Notify_Impl(UID_: TUID___; Param: TMem64);
var
  d: TDFE;
begin
  if not Connected then
    begin
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_UID_Execute_Notify_Impl: ENTER');
    end;
  d := TDFE.Create;
  d.WriteArrayByte.Buffer__.WritePtr(@UID_[0], SizeOf(TUID___));
  d.WriteMem64(Param);
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('UID_Notify', d);
  DisposeObject(d);

  Check_Param_And_Send_Queue(Param);
end;

procedure TC40_LF_Client.Send_UID_Execute_Sequenced_Notify_Impl(UID_: TUID___; Param: TMem64);
var
  d: TDFE;
begin
  if not Connected then
    begin
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_UID_Execute_Sequenced_Notify_Impl: ENTER');
    end;
  d := TDFE.Create;
  d.WriteArrayByte.Buffer__.WritePtr(@UID_[0], SizeOf(TUID___));
  d.WriteMem64(Param);
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('UID_Sequenced_Notify', d);
  DisposeObject(d);

  Check_Param_And_Send_Queue(Param);
end;

function TC40_LF_Client.Wait_UID_Execute_Call_Impl(UID_: TUID___; Param: TMem64; TimeOut__: TTimeTick): TMem64;
var
  tmp: TLF_Call_Bridge;
  d: TDFE;
  tk: TTimeTick;
begin
  if not Connected then
    begin
      exit(TMem64.Create);
    end;
  Result := nil;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Wait_UID_Execute_Call_Impl: ENTER timeout=%d', [TimeOut__]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  tmp := TLF_Call_Bridge.Create;
  tmp.Cli := Self;
  tmp.IsRunning := True;

  d := TDFE.Create;
  d.WriteArrayByte.Buffer__.WritePtr(@UID_[0], SizeOf(TUID___));
  d.WriteMem64(Param);
  d.DelayFree;
  DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('UID_Call', d, tmp.Do_Result);

  Check_Param_And_Send_Queue(Param);

  tk := GetTimeTick + TimeOut__;
  while tmp.IsRunning do
    begin
      TCompute.Sleep(100);
      if (LF_CheckMainThread <= 0) or ((TimeOut__ > 0) and (GetTimeTick > tk)) then
        begin
          FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
          DoStatus('uid -> %s call timeout', [TLF_String(TCipher.HashToString(UID_)).ShortText(20, 5, 5).Text]);
          if LF_Debug_Log_Enabled then
            begin
              LF_Debug_Log('Client.Wait_UID_Execute_Call_Impl: TIMEOUT');
            end;
          exit;
        end;
    end;
  Result := tmp.Output.Swap_To_New_Instance;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  DisposeObject(tmp);
end;

procedure TC40_LF_Client.Async_UID_Execute_Call_Impl(UID_: TUID___; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
var
  api_Name__: TLF_String;
  tmp: TLF_Async_Call_Bridge;
  d: TDFE;
begin
  if not Connected then
    begin
      Do_Null_OnResult(Data_, OnResult_);
      exit;
    end;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_UID_Execute_Call_Impl: ENTER api="%s"',
        [api_Name__.Text]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  try
    tmp := TLF_Async_Call_Bridge.Create;
    tmp.Cli := Self;
    tmp.app_Name__ := '';
    tmp.api_Name__ := api_Name__;
    tmp.Data_ := Data_;
    tmp.OnResult := OnResult_;
    d := TDFE.Create;
    d.WriteArrayByte.Buffer__.WritePtr(@UID_[0], SizeOf(TUID___));
    d.WriteMem64(Param);
    d.DelayFree;
    DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('UID_Call', d, tmp.Do_Result);
  finally
      FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  end;

  Check_Param_And_Send_Queue(Param);
end;

procedure TC40_LF_Client.Async_UID_Sequenced_Execute_Call_Impl(UID_: TUID___; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
var
  api_Name__: TLF_String;
  tmp: TLF_Async_Sequenced_Call_Bridge;
  d: TDFE;
begin
  if not Connected then
    begin
      Do_Null_OnResult(Data_, OnResult_);
      exit;
    end;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_UID_Sequenced_Execute_Call_Impl: ENTER api="%s"',
        [api_Name__.Text]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  try
    tmp := TLF_Async_Sequenced_Call_Bridge.Create;
    tmp.Cli := Self;
    tmp.app_Name__ := '';
    tmp.api_Name__ := api_Name__;
    tmp.Data_ := Data_;
    tmp.OnResult := OnResult_;
    d := TDFE.Create;
    d.WriteArrayByte.Buffer__.WritePtr(@UID_[0], SizeOf(TUID___));
    d.WriteMem64(Param);
    d.DelayFree;
    DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('UID_Sequenced_Call', d, tmp.Do_Result);
  finally
      FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  end;

  Check_Param_And_Send_Queue(Param);
end;

procedure TC40_LF_Client.Send_P2PName_Execute_Notify_Impl(p2p_name__: TLF_String; Param: TMem64);
begin
  if not Connected then
    begin
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_P2PName_Execute_Notify_Impl: p2p="%s"', [p2p_name__.Text]);
    end;
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('P2PName_Notify',
    TDFE.Create
      .WriteString(p2p_name__)
      .WriteMem64(Param)
      .DelayFree
    );

  Check_Param_And_Send_Queue(Param);
end;

procedure TC40_LF_Client.Send_P2PName_Execute_Sequenced_Notify_Impl(p2p_name__: TLF_String; Param: TMem64);
begin
  if not Connected then
    begin
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_P2PName_Execute_Sequenced_Notify_Impl: p2p="%s"', [p2p_name__.Text]);
    end;
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('P2PName_Sequenced_Notify',
    TDFE.Create
      .WriteString(p2p_name__)
      .WriteMem64(Param)
      .DelayFree
    );

  Check_Param_And_Send_Queue(Param);
end;

function TC40_LF_Client.Wait_P2PName_Execute_Call_Impl(p2p_name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
var
  tmp: TLF_Call_Bridge;
  d: TDFE;
  tk: TTimeTick;
begin
  if not Connected then
    begin
      exit(TMem64.Create);
    end;
  Result := nil;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Wait_P2PName_Execute_Call_Impl: p2p="%s" timeout=%d',
        [p2p_name__.Text, TimeOut__]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  tmp := TLF_Call_Bridge.Create;
  tmp.Cli := Self;
  tmp.IsRunning := True;

  d := TDFE.Create;
  d.WriteString(p2p_name__);
  d.WriteMem64(Param);
  d.DelayFree;
  DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('P2PName_Call', d, tmp.Do_Result);

  Check_Param_And_Send_Queue(Param);

  tk := GetTimeTick + TimeOut__;
  while tmp.IsRunning do
    begin
      TCompute.Sleep(100);
      if (LF_CheckMainThread <= 0) or ((TimeOut__ > 0) and (GetTimeTick > tk)) then
        begin
          FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
          DoStatus('p2pname:"%s" call timeout', [p2p_name__.Text]);
          exit;
        end;
    end;
  Result := tmp.Output.Swap_To_New_Instance;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  DisposeObject(tmp);
end;

procedure TC40_LF_Client.Async_P2PName_Execute_Call_Impl(p2p_name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
var
  api_Name__: TLF_String;
  tmp: TLF_Async_Call_Bridge;
  d: TDFE;
begin
  if not Connected then
    begin
      Do_Null_OnResult(Data_, OnResult_);
      exit;
    end;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_P2PName_Execute_Call_Impl: p2p="%s" api="%s"',
        [p2p_name__.Text, api_Name__.Text]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  try
    tmp := TLF_Async_Call_Bridge.Create;
    tmp.Cli := Self;
    tmp.app_Name__ := p2p_name__;
    tmp.api_Name__ := api_Name__;
    tmp.Data_ := Data_;
    tmp.OnResult := OnResult_;
    d := TDFE.Create;
    d.WriteString(p2p_name__);
    d.WriteMem64(Param);
    d.DelayFree;
    DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('P2PName_Call', d, tmp.Do_Result);
  finally
      FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  end;

  Check_Param_And_Send_Queue(Param);
end;

procedure TC40_LF_Client.Async_P2PName_Sequenced_Execute_Call_Impl(p2p_name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult);
var
  api_Name__: TLF_String;
  tmp: TLF_Async_Sequenced_Call_Bridge;
  d: TDFE;
begin
  if not Connected then
    begin
      Do_Null_OnResult(Data_, OnResult_);
      exit;
    end;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_P2PName_Sequenced_Execute_Call_Impl: p2p="%s" api="%s"',
        [p2p_name__.Text, api_Name__.Text]);
    end;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  try
    tmp := TLF_Async_Sequenced_Call_Bridge.Create;
    tmp.Cli := Self;
    tmp.app_Name__ := p2p_name__;
    tmp.api_Name__ := api_Name__;
    tmp.Data_ := Data_;
    tmp.OnResult := OnResult_;
    d := TDFE.Create;
    d.WriteString(p2p_name__);
    d.WriteMem64(Param);
    d.DelayFree;
    DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('P2PName_Sequenced_Call', d, tmp.Do_Result);
  finally
      FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  end;

  Check_Param_And_Send_Queue(Param);
end;

constructor TC40_LF_Client.Create(PhysicsTunnel_: TC40_PhysicsTunnel; source_: TC40_Info; Param_: U_String);
begin
  inherited Create(PhysicsTunnel_, source_, Param_);
  FLast_UID := Null_UID();
  FLast_P2PName := '';
  FService_Info := TLF_ServiceInfoPool.Create;
  FUID_Info_Tool := TUID_Info_Tool.Create;

  FHost_Running_Thread_Num := TAtomInt32.Create(0);
  FWait_Reponse_Thread_Num := TAtomInt32.Create(0);
  FSent_No_Response_Cmd_Num := TAtomInt32.Create(0);
  FLast_Check_UID_TimeTick := 0;

  FAPP := nil;
  FAPI_APP_Is_Online := False;
  FService_Info_Is_Online := False;
  LF_P2P_APP.Subscribe_Update(Self, Do_LF_P2P_APP_Update);

  Cycle_Int64_Anchor_Tool := TString_Num64_Analysis_Tool.Create($FF, 0);
  Cycle_Int64_Anchor := 0;
  Fixed_Sequenced_Pool := TFixed_Sequenced_Pool.Create($FF, 0);
  Fixed_Sequenced_Temp_Time := 0;

  DTNoAuth.RecvTunnel.MaxCompleteBufferSize := EStrToInt64(ParamList.GetDefaultValue('MaxBuffer', '500*1024*1024'), 500 * 1024 * 1024);
  DTNoAuth.SendTunnel.MaxCompleteBufferSize := EStrToInt64(ParamList.GetDefaultValue('MaxBuffer', '500*1024*1024'), 500 * 1024 * 1024);

  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('update_service_api_info').OnExecute := cmd_update_service_api_info;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('Notify').OnExecute := cmd_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('Sequenced_Notify').OnExecute := cmd_Sequenced_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Stream_Thread('Call').OnExecute := cmd_Call;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('Sequenced_Call').OnExecute := cmd_Sequenced_Call;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('UID_Notify').OnExecute := cmd_UID_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('UID_Sequenced_Notify').OnExecute := cmd_UID_Sequenced_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Stream_Thread('UID_Call').OnExecute := cmd_UID_Call;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('UID_Sequenced_Call').OnExecute := cmd_UID_Sequenced_Call;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('P2PName_Notify').OnExecute := cmd_P2PName_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('P2PName_Sequenced_Notify').OnExecute := cmd_P2PName_Sequenced_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Stream_Thread('P2PName_Call').OnExecute := cmd_P2PName_Call;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('P2PName_Sequenced_Call').OnExecute := cmd_P2PName_Sequenced_Call;

  DTNoAuth.RecvTunnel.PrintParams.Add('Update_UID', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('update_service_api_info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Init_APP_Info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('No_App_Info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Sequenced_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Sequenced_Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('UID_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('UID_Sequenced_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('UID_Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('UID_Sequenced_Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('P2PName_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('P2PName_Sequenced_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('P2PName_Call', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('P2PName_Sequenced_Call', False, True);

  DTNoAuth.SendTunnel.PrintParams.Add('Update_UID', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('update_service_api_info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Init_APP_Info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('No_App_Info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Sequenced_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Sequenced_Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('UID_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('UID_Sequenced_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('UID_Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('UID_Sequenced_Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('P2PName_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('P2PName_Sequenced_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('P2PName_Call', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('P2PName_Sequenced_Call', False, True);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TC40_LF_Client.Create: tag=%d param="%s"', [Tag, Param_.Text]);
    end;
end;

destructor TC40_LF_Client.Destroy;
var
  tk: TTimeTick;
  free_timeout_: Boolean;
begin
  if LF_Debug_Log_Enabled then
    LF_Debug_Log('TC40_LF_Client.Destroy: tag=%d begin', [Tag]);
  try
    try
      LF_P2P_APP.Remove_Update(Self);
    except
      on E: Exception do
        DoStatus('TC40_LF_Client.Destroy remove P2P update error: %s', [E.Message]);
    end;
    try
      if FAPP <> nil then
        FAPP.Remove_Update(Self);
    except
      on E: Exception do
        DoStatus('TC40_LF_Client.Destroy remove app update error: %s', [E.Message]);
    end;
    free_timeout_ := False;
    tk := GetTimeTick() + 2000;
    while (FHost_Running_Thread_Num.V + FWait_Reponse_Thread_Num.V > 0) do
      begin
        if GetTimeTick() > tk then
          begin
            free_timeout_ := True;
            Break;
          end
        else
          TCompute.Sleep(10);
      end;
    if not free_timeout_ then
      begin
        try DisposeObjectAndNil(FHost_Running_Thread_Num); except end;
        try DisposeObjectAndNil(FWait_Reponse_Thread_Num); except end;
        try DisposeObjectAndNil(FSent_No_Response_Cmd_Num); except end;
        try DisposeObjectAndNil(FUID_Info_Tool); except end;
        try DisposeObjectAndNil(FService_Info); except end;
        try DisposeObjectAndNil(Cycle_Int64_Anchor_Tool); except end;
        try DisposeObjectAndNil(Fixed_Sequenced_Pool); except end;
      end;
  finally
    try
      if C40_ClientPool <> nil then
        C40_ClientPool.Remove(Self);
    except
      on E: Exception do
        DoStatus('TC40_LF_Client.Destroy remove from pool error: %s', [E.Message]);
    end;
  end;
  try
    inherited Destroy;
  except
    on E: Exception do
      DoStatus('TC40_LF_Client.Destroy inherited error: %s', [E.Message]);
  end;
  if LF_Debug_Log_Enabled then
    LF_Debug_Log('TC40_LF_Client.Destroy: tag=%d done timeout=%s', [Tag, if_(free_timeout_, 'yes', 'no')]);
end;

procedure TC40_LF_Client.SafeCheck;
begin
  inherited SafeCheck;
end;

procedure TC40_LF_Client.Progress;
var
  tk: TTimeTick;
begin
  if LF_AppIsOnline then
    begin
      tk := GetTimeTick();
      if tk - FLast_Check_UID_TimeTick > 1000 then
        begin
          if not FLast_P2PName.Same(LF_P2P_name.V) then
            begin
              if LF_Debug_Log_Enabled then
                begin
                  LF_Debug_Log('Client.Progress: p2p name changed, updating UID info');
                end;
              Update_UID_Info;
            end;
          FLast_Check_UID_TimeTick := tk;
        end;
    end;
  inherited Progress;
end;

procedure TC40_LF_Client.DoNetworkOnline;
begin
  inherited DoNetworkOnline;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.DoNetworkOnline: tag=%d', [Tag]);
    end;
end;

procedure TC40_LF_Client.DoNetworkOffline;
var
  addr_: TLF_String;
begin
  inherited DoNetworkOffline;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.DoNetworkOffline: tag=%d', [Tag]);
    end;
  FAPI_APP_Is_Online := False;
  FService_Info_Is_Online := False;
  LF_Invalidate_All_API_Cache;
  if C40PhysicsTunnel.IPC_Mode then
      addr_ := C40PhysicsTunnel.PhysicsAddr
  else
      addr_ := Build_Host_URL(C40PhysicsTunnel.PhysicsAddr, C40PhysicsTunnel.PhysicsPort);
  Do_LF_Network_Disconnect(addr_);
end;

procedure TC40_LF_Client.Update_UID_Info;
begin
  Do_Update_UID_Info();
end;

procedure TC40_LF_Client.Init_App_Info;
begin
  Do_Update_UID_Info();
  Do_Init_App_Info();
end;

procedure TC40_LF_Client.Do_Init_App_Info_Result(Sender: TPeerIO; Result_: TDFE);
begin
  FAPI_APP_Is_Online := True;
  FAPP.Subscribe_Update(Self, Do_APP_Update);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Do_Init_App_Info_Result: app="%s" online', [FAPP.Name.Text]);
    end;
end;

procedure TC40_LF_Client.Set_API_APP(const Value: TLF_App);
begin
  if FAPP <> nil then
      FAPP.Remove_Update(Self);
  FAPP := Value;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Set_API_APP: tag=%d app=%p', [Tag, Pointer(Value)]);
    end;
  if DTNoAuth.LinkOk then
      Init_App_Info;
end;

function TC40_LF_Client.Get_App_From_Pool(app_Name__: TLF_String): TLF_App;
begin
  Result := nil;
  if FAPP <> nil then
    if app_Name__.Same(FAPP.Name) then
      begin
        Result := FAPP;
        exit;
      end;

  LF_App_Pool.Lock;
  try
    if LF_App_Pool.Num > 0 then
      with LF_App_Pool.Invert_Repeat_ do
        repeat
          if app_Name__.Same(queue^.Data.Name) then
            begin
              Result := queue^.Data;
              exit;
            end;
        until not Prev;
  finally
      LF_App_Pool.UnLock;
  end;
end;

procedure TC40_LF_Client.Check_Param_And_Send_Queue(Param: TMem64);
begin
  if Param.Size > 1024 * 1024 then
    begin
      DTNoAuth.SendTunnel.SendNULL;
      FSent_No_Response_Cmd_Num.V := 0;
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('Client.Check_Param_And_Send_Queue: large payload, SendNULL');
        end;
    end
  else if No_Reponse_Cmd_NULL_Flush_Threshold > 0 then
    begin
      FSent_No_Response_Cmd_Num.Lock;
      try
        inc(FSent_No_Response_Cmd_Num.P^);
        if FSent_No_Response_Cmd_Num.P^ > No_Reponse_Cmd_NULL_Flush_Threshold then
          begin
            DTNoAuth.SendTunnel.SendNULL;
            FSent_No_Response_Cmd_Num.P^ := 0;
            if LF_Debug_Log_Enabled then
              begin
                LF_Debug_Log('Client.Check_Param_And_Send_Queue: threshold reached, SendNULL');
              end;
          end;
      finally
          FSent_No_Response_Cmd_Num.UnLock;
      end;
    end;
end;

procedure TC40_LF_Client.Send_Execute_Notify(app_Name__: TLF_String; Param: TMem64);
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_Execute_Notify: ENTER app="%s"', [app_Name__.Text]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
    api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);
    tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
    if tmp_cli__ <> nil then
      begin
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Send_Execute_Notify: LOCAL app path');
          end;
        tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ + 1);
        try
            tmp_cli__.APP.Engine.Execute_Notify(tmp_param);
        finally
            tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ - 1);
        end;
        exit;
      end;
    tmp_cli__ := Find_Remote_API(app_Name__, api_Name__, True);
    if tmp_cli__ <> nil then
        tmp_cli__.Send_Execute_Notify_Impl(app_Name__, tmp_param)
    else
        Send_Execute_Notify_Impl(app_Name__, tmp_param);
  finally
      DisposeObject(tmp_param);
  end;
end;

procedure TC40_LF_Client.Send_Sequenced_Notify(app_Name__: TLF_String; Param: TMem64);
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_Sequenced_Notify: ENTER app="%s"', [app_Name__.Text]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
    api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);
    tmp_cli__ := Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__);
    if tmp_cli__ <> nil then
      begin
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Send_Sequenced_Notify: LOCAL fixed-sequenced path');
          end;
        LF_Notify_Sequence_Thread_Pool.Post_Notify2(tmp_cli__.APP, tmp_param.Swap_To_New_Instance);
        exit;
      end;

    tmp_cli__ := Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__);
    if tmp_cli__ <> nil then
        tmp_cli__.Send_Sequenced_Notify_Impl(app_Name__, tmp_param)
    else
        Send_Sequenced_Notify_Impl(app_Name__, tmp_param);
  finally
      DisposeObject(tmp_param);
  end;
end;

function TC40_LF_Client.Wait_Execute_Call(app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Wait_Execute_Call: ENTER app="%s" timeout=%d',
        [app_Name__.Text, TimeOut__]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
    Result := nil;
    api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);
    tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
    if tmp_cli__ <> nil then
      begin
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Wait_Execute_Call: LOCAL app path');
          end;
        tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ + 1);
        try
            Result := tmp_cli__.APP.Engine.Execute_Call(tmp_param);
        finally
            tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ - 1);
        end;
        exit;
      end;

    tmp_cli__ := Find_Remote_API(app_Name__, api_Name__, True);
    if tmp_cli__ <> nil then
        Result := tmp_cli__.Wait_Execute_Call_Impl(app_Name__, tmp_param, TimeOut__)
    else
        Result := Wait_Execute_Call_Impl(app_Name__, tmp_param, TimeOut__);
  finally
      DisposeObject(tmp_param);
  end;
end;

function TC40_LF_Client.Async_Execute_Call(app_Name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param, Result_M64: TMem64;
  result_param_: PLF_Data;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_Execute_Call: ENTER app="%s"', [app_Name__.Text]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  Result := False;
  api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);

  tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('Client.Async_Execute_Call: LOCAL app path');
        end;
      tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ + 1);
      try
          Result_M64 := tmp_cli__.APP.Engine.Execute_Call(tmp_param);
      finally
          tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ - 1);
      end;

      try
        result_param_ := TLF_Data.New_Result_From(Result_M64, False);
        result_param_^.Data_Info.Text := PFormat('result for app:%s api:%s', [app_Name__.Text, api_Name__.Text]);
        if Assigned(OnResult_) then
            OnResult_(Data_, result_param_);
        TLF_Data.Free_Data(result_param_);
        Result := True;
      except
        on E: Exception do
          begin
            Result := False;
            DoStatus('Client.Async_Execute_Call LOCAL path exception: %s: %s',
              [E.ClassName, E.Message]);
            if LF_Debug_Log_Enabled then
              begin
                LF_Debug_Log('Client.Async_Execute_Call LOCAL path EXCEPTION: %s: %s',
                  [E.ClassName, E.Message]);
              end;
          end;
      end;
      DisposeObject(tmp_param);
      exit;
    end;

  try
    tmp_cli__ := Find_Remote_API(app_Name__, api_Name__, True);
    if tmp_cli__ <> nil then
      begin
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Async_Execute_Call: REMOTE path (found client=%p)', [Pointer(tmp_cli__)]);
          end;
        tmp_cli__.Async_Execute_Call_Impl(app_Name__, tmp_param, Data_, OnResult_)
      end
    else
      begin
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Async_Execute_Call: SELF path (no client found)');
          end;
        Async_Execute_Call_Impl(app_Name__, tmp_param, Data_, OnResult_);
      end;
    Result := True;
  except
    on E: Exception do
      begin
        Result := False;
        DoStatus('Client.Async_Execute_Call exception: %s: %s', [E.ClassName, E.Message]);
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Async_Execute_Call EXCEPTION: %s: %s',
              [E.ClassName, E.Message]);
          end;
      end;
  end;

  DisposeObject(tmp_param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_Execute_Call: EXIT result=%s', [BoolToStr(Result, True)]);
    end;
end;

function TC40_LF_Client.Async_Sequenced_Execute_Call(app_Name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param: TMem64;
  call_bridge_: TLF_Async_Sequenced_Call_Bridge;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_Sequenced_Execute_Call: ENTER app="%s"', [app_Name__.Text]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);

  Result := False;

  api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);
  tmp_cli__ := Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__);
  if tmp_cli__ <> nil then
    begin
      if LF_Debug_Log_Enabled then
        begin
          LF_Debug_Log('Client.Async_Sequenced_Execute_Call: LOCAL fixed-sequenced path');
        end;
      try
        call_bridge_ := TLF_Async_Sequenced_Call_Bridge.Create;
        call_bridge_.Cli := Self;
        call_bridge_.app_Name__ := app_Name__;
        call_bridge_.api_Name__ := api_Name__;
        call_bridge_.Data_ := Data_;
        call_bridge_.OnResult := OnResult_;
        LF_Call_Sequence_Thread_Pool.Post_Call2(tmp_cli__.APP, tmp_param.Swap_To_New_Instance, call_bridge_.Do_Local_Thread_Call_Result);
        Result := True;
      except
        on E: Exception do
          begin
            DoStatus('Client.Async_Sequenced_Execute_Call LOCAL path exception: %s: %s',
              [E.ClassName, E.Message]);
            if LF_Debug_Log_Enabled then
              begin
                LF_Debug_Log('Client.Async_Sequenced_Execute_Call LOCAL path EXCEPTION: %s: %s',
                  [E.ClassName, E.Message]);
              end;
          end;
      end;
      DisposeObject(tmp_param);
      exit;
    end;

  try
    tmp_cli__ := Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__);
    if tmp_cli__ <> nil then
      begin
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Async_Sequenced_Execute_Call: REMOTE path');
          end;
        tmp_cli__.Async_Sequenced_Execute_Call_Impl(app_Name__, tmp_param, Data_, OnResult_)
      end
    else
      begin
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Async_Sequenced_Execute_Call: SELF path');
          end;
        Async_Sequenced_Execute_Call_Impl(app_Name__, tmp_param, Data_, OnResult_);
      end;
    Result := True;
  except
    on E: Exception do
      begin
        Result := False;
        DoStatus('Client.Async_Sequenced_Execute_Call exception: %s: %s',
          [E.ClassName, E.Message]);
        if LF_Debug_Log_Enabled then
          begin
            LF_Debug_Log('Client.Async_Sequenced_Execute_Call EXCEPTION: %s: %s',
              [E.ClassName, E.Message]);
          end;
      end;
  end;

  DisposeObject(tmp_param);

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_Sequenced_Execute_Call: EXIT result=%s',
        [BoolToStr(Result, True)]);
    end;
end;

procedure TC40_LF_Client.Send_UID_Execute_Notify(UID_: TUID___; Param: TMem64);
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param: TMem64;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_UID_Execute_Notify: ENTER');
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
    api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);

    target_app := Find_Local_UID_App(UID_, api_Name__);
    if target_app <> nil then
      begin
        target_app.Engine.Execute_Notify(tmp_param);
        exit;
      end;

    tmp_cli__ := Find_Remote_UID_API(UID_, api_Name__, True);
    if tmp_cli__ <> nil then
        tmp_cli__.Send_UID_Execute_Notify_Impl(UID_, tmp_param)
    else Send_UID_Execute_Notify_Impl(UID_, tmp_param);

  finally
      DisposeObject(tmp_param);
  end;
end;

procedure TC40_LF_Client.Send_UID_Execute_Sequenced_Notify(UID_: TUID___; Param: TMem64);
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param: TMem64;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_UID_Execute_Sequenced_Notify: ENTER');
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
    api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);

    target_app := Find_Local_UID_App(UID_, api_Name__);
    if target_app <> nil then
      begin
        LF_Notify_Sequence_Thread_Pool.Post_Notify2(target_app, tmp_param.Swap_To_New_Instance);
        exit;
      end;

    tmp_cli__ := Find_Remote_UID_API(UID_, api_Name__, True);
    if tmp_cli__ <> nil then
        tmp_cli__.Send_UID_Execute_Sequenced_Notify_Impl(UID_, tmp_param)
    else Send_UID_Execute_Sequenced_Notify_Impl(UID_, tmp_param);

  finally
      DisposeObject(tmp_param);
  end;
end;

function TC40_LF_Client.Wait_UID_Execute_Call(UID_: TUID___; Param: TMem64; TimeOut__: TTimeTick): TMem64;
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param: TMem64;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Wait_UID_Execute_Call: ENTER timeout=%d', [TimeOut__]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
    Result := nil;
    api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);

    target_app := Find_Local_UID_App(UID_, api_Name__);
    if target_app <> nil then
      begin
        Result := target_app.Engine.Execute_Call(tmp_param);
        exit;
      end;

    tmp_cli__ := Find_Remote_UID_API(UID_, api_Name__, True);
    if tmp_cli__ <> nil then
      begin
        Result := tmp_cli__.Wait_UID_Execute_Call_Impl(UID_, tmp_param, TimeOut__);
        exit;
      end;

    Result := Wait_UID_Execute_Call_Impl(UID_, tmp_param, TimeOut__);
  finally
      DisposeObject(tmp_param);
  end;
end;

function TC40_LF_Client.Async_UID_Execute_Call(UID_: TUID___; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param, Result_M64: TMem64;
  result_param_: PLF_Data;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_UID_Execute_Call: ENTER');
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  Result := False;
  api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);

  target_app := Find_Local_UID_App(UID_, api_Name__);
  if target_app <> nil then
    begin
      Result_M64 := target_app.Engine.Execute_Call(tmp_param);
      try
        result_param_ := TLF_Data.New_Result_From(Result_M64, False);
        result_param_^.Data_Info.Text := PFormat('result for uid api:%s', [api_Name__.Text]);
        if Assigned(OnResult_) then
            OnResult_(Data_, result_param_);
        TLF_Data.Free_Data(result_param_);
        Result := True;
      except
        on E: Exception do
          begin
            Result := False;
            DoStatus('Client.Async_UID_Execute_Call LOCAL path exception: %s: %s',
              [E.ClassName, E.Message]);
          end;
      end;
      DisposeObject(tmp_param);
      exit;
    end;

  try
    tmp_cli__ := Find_Remote_UID_API(UID_, api_Name__, True);
    if tmp_cli__ <> nil then
        tmp_cli__.Async_UID_Execute_Call_Impl(UID_, tmp_param, Data_, OnResult_)
    else
        Async_UID_Execute_Call_Impl(UID_, tmp_param, Data_, OnResult_);
    Result := True;
  except
    on E: Exception do
      begin
        Result := False;
        DoStatus('Client.Async_UID_Execute_Call exception: %s: %s',
          [E.ClassName, E.Message]);
      end;
  end;

  DisposeObject(tmp_param);
end;

function TC40_LF_Client.Async_UID_Sequenced_Execute_Call(UID_: TUID___; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
  tmp_param: TMem64;
  call_bridge_: TLF_Async_Sequenced_Call_Bridge;
  target_app: TLF_App;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_UID_Sequenced_Execute_Call: ENTER');
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  Result := False;
  api_Name__ := TMemory_Param_Tool.Get_apiName(tmp_param);

  target_app := Find_Local_UID_App(UID_, api_Name__);
  if target_app <> nil then
    begin
      try
        call_bridge_ := TLF_Async_Sequenced_Call_Bridge.Create;
        call_bridge_.Cli := Self;
        call_bridge_.app_Name__ := '';
        call_bridge_.api_Name__ := api_Name__;
        call_bridge_.Data_ := Data_;
        call_bridge_.OnResult := OnResult_;
        LF_Call_Sequence_Thread_Pool.Post_Call2(target_app, tmp_param.Swap_To_New_Instance, call_bridge_.Do_Local_Thread_Call_Result);
        Result := True;
      except
        on E: Exception do
          begin
            DoStatus('Client.Async_UID_Sequenced_Execute_Call LOCAL path exception: %s: %s',
              [E.ClassName, E.Message]);
          end;
      end;
      DisposeObject(tmp_param);
      exit;
    end;

  try
    tmp_cli__ := Find_Remote_UID_API(UID_, api_Name__, True);
    if tmp_cli__ <> nil then
        tmp_cli__.Async_UID_Sequenced_Execute_Call_Impl(UID_, tmp_param, Data_, OnResult_)
    else
        Async_UID_Sequenced_Execute_Call_Impl(UID_, tmp_param, Data_, OnResult_);
    Result := True;
  except
    on E: Exception do
      begin
        Result := False;
        DoStatus('Client.Async_UID_Sequenced_Execute_Call exception: %s: %s',
          [E.ClassName, E.Message]);
      end;
  end;

  DisposeObject(tmp_param);
end;

procedure TC40_LF_Client.Send_P2PName_Execute_Notify(p2p_name__: TLF_String; Param: TMem64);
var
  tmp_param: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_P2PName_Execute_Notify: p2p="%s"', [p2p_name__.Text]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
      Send_P2PName_Execute_Notify_Impl(p2p_name__, tmp_param);
  finally
      DisposeObject(tmp_param);
  end;
end;

procedure TC40_LF_Client.Send_P2PName_Execute_Sequenced_Notify(p2p_name__: TLF_String; Param: TMem64);
var
  tmp_param: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Send_P2PName_Execute_Sequenced_Notify: p2p="%s"', [p2p_name__.Text]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
      Send_P2PName_Execute_Sequenced_Notify_Impl(p2p_name__, tmp_param);
  finally
      DisposeObject(tmp_param);
  end;
end;

function TC40_LF_Client.Wait_P2PName_Execute_Call(p2p_name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
var
  tmp_param: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Wait_P2PName_Execute_Call: p2p="%s" timeout=%d',
        [p2p_name__.Text, TimeOut__]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
      Result := Wait_P2PName_Execute_Call_Impl(p2p_name__, tmp_param, TimeOut__);
  finally
      DisposeObject(tmp_param);
  end;
end;

function TC40_LF_Client.Async_P2PName_Execute_Call(p2p_name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
var
  tmp_param: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_P2PName_Execute_Call: p2p="%s"', [p2p_name__.Text]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
    Async_P2PName_Execute_Call_Impl(p2p_name__, tmp_param, Data_, OnResult_);
    Result := True;
  except
    on E: Exception do
      begin
        Result := False;
        DoStatus('Client.Async_P2PName_Execute_Call exception: %s: %s',
          [E.ClassName, E.Message]);
      end;
  end;
  DisposeObject(tmp_param);
end;

function TC40_LF_Client.Async_P2PName_Sequenced_Execute_Call(p2p_name__: TLF_String; Param: TMem64; Data_: Pointer; OnResult_: TLF_Async_Call_OnResult): Boolean;
var
  tmp_param: TMem64;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Client.Async_P2PName_Sequenced_Execute_Call: p2p="%s"', [p2p_name__.Text]);
    end;
  tmp_param := TMemory_Param_Tool.Rebuild_UID_and_P2PName(Param, FLast_UID, LF_P2P_name.V);
  try
    Async_P2PName_Sequenced_Execute_Call_Impl(p2p_name__, tmp_param, Data_, OnResult_);
    Result := True;
  except
    on E: Exception do
      begin
        Result := False;
        DoStatus('Client.Async_P2PName_Sequenced_Execute_Call exception: %s: %s',
          [E.ClassName, E.Message]);
      end;
  end;
  DisposeObject(tmp_param);
end;

constructor TLF_Call_Bridge.Create;
begin
  inherited Create;
  Cli := nil;
  Output := TMem64.Create;
  IsRunning := False;
  Error_ := False;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Call_Bridge.Create: self=%p', [Pointer(Self)]);
    end;
end;

destructor TLF_Call_Bridge.Destroy;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Call_Bridge.Destroy: self=%p', [Pointer(Self)]);
    end;
  DisposeObjectAndNil(Output);
  inherited Destroy;
end;

procedure TLF_Call_Bridge.Do_Result(Sender: TPeerIO; Result_: TDFE);
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Call_Bridge.Do_Result: self=%p count=%d', [Pointer(Self), Result_.Count]);
    end;
  Error_ := Result_.Count <= 0;
  if not Error_ then
      Result_.R.ReadMem64(Output);
  IsRunning := False;
end;

constructor TLF_Async_Call_Bridge.Create;
begin
  inherited Create;
  Cli := nil;
  app_Name__ := '';
  api_Name__ := '';
  Data_ := nil;
  OnResult := nil;
  Result_M64 := TMem64.Create;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Async_Call_Bridge.Create: self=%p', [Pointer(Self)]);
    end;
end;

destructor TLF_Async_Call_Bridge.Destroy;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Async_Call_Bridge.Destroy: self=%p', [Pointer(Self)]);
    end;
  DisposeObject(Result_M64);
  inherited Destroy;
end;

procedure TLF_Async_Call_Bridge.Do_Result(Sender: TPeerIO; Result_: TDFE);
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Async_Call_Bridge.Do_Result: self=%p count=%d',
        [Pointer(Self), Result_.Count]);
    end;
  if Result_.Count > 0 then
      Result_.R.ReadMem64(Result_M64);
  TCompute.RunM_NP(Do_Th);
end;

procedure TLF_Async_Call_Bridge.Do_Th;
var
  result_param_: PLF_Data;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Async_Call_Bridge.Do_Th: self=%p result_size=%d',
        [Pointer(Self), Result_M64.Size]);
    end;
  result_param_ := TLF_Data.New_Result_From(Result_M64.Swap_To_New_Instance, False);
  result_param_^.Data_Info.Text := PFormat('result for app:%s api:%s', [app_Name__.Text, api_Name__.Text]);
  try
    if Assigned(OnResult) then
        OnResult(Data_, result_param_);
  except
    on E: Exception do
      begin
        DoStatus('TLF_Async_Call_Bridge.Do_Th exception: %s: %s', [E.ClassName, E.Message]);
      end;
  end;
  TLF_Data.Free_Data(result_param_);
  DelayFreeObj(1.0, Self);
end;

constructor TLF_Async_Sequenced_Call_Bridge.Create;
begin
  inherited Create;
  Cli := nil;
  app_Name__ := '';
  api_Name__ := '';
  Data_ := nil;
  OnResult := nil;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Async_Sequenced_Call_Bridge.Create: self=%p', [Pointer(Self)]);
    end;
end;

destructor TLF_Async_Sequenced_Call_Bridge.Destroy;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Async_Sequenced_Call_Bridge.Destroy: self=%p', [Pointer(Self)]);
    end;
  inherited Destroy;
end;

procedure TLF_Async_Sequenced_Call_Bridge.Do_Local_Thread_Call_Result(Result_: TMem64);
var
  result_param_: PLF_Data;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Async_Sequenced_Call_Bridge.Do_Local_Thread_Call_Result: self=%p size=%d',
        [Pointer(Self), Result_.Size]);
    end;
  result_param_ := TLF_Data.New_Result_From(Result_.Swap_To_New_Instance, False);
  result_param_^.Data_Info.Text := PFormat('result for app:%s api:%s', [app_Name__.Text, api_Name__.Text]);
  try
    if Assigned(OnResult) then
        OnResult(Data_, result_param_);
  except
    on E: Exception do
      begin
        DoStatus('TLF_Async_Sequenced_Call_Bridge.Do_Local_Thread_Call_Result exception: %s: %s',
          [E.ClassName, E.Message]);
      end;
  end;
  TLF_Data.Free_Data(result_param_);
  DelayFreeObj(1.0, Self);
end;

procedure TLF_Async_Sequenced_Call_Bridge.Do_Result(Sender: TPeerIO; Result_: TDFE);
var
  Result_M64: TMem64;
  result_param_: PLF_Data;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Async_Sequenced_Call_Bridge.Do_Result: self=%p count=%d',
        [Pointer(Self), Result_.Count]);
    end;
  Result_M64 := TMem64.Create;
  if Result_.Count > 0 then
      Result_.R.ReadMem64(Result_M64);
  result_param_ := TLF_Data.New_Result_From(Result_M64, False);
  result_param_^.Data_Info.Text := PFormat('result for app:%s api:%s', [app_Name__.Text, api_Name__.Text]);
  try
    if Assigned(OnResult) then
        OnResult(Data_, result_param_);
  except
    on E: Exception do
      begin
        DoStatus('TLF_Async_Sequenced_Call_Bridge.Do_Result exception: %s: %s',
          [E.ClassName, E.Message]);
      end;
  end;
  TLF_Data.Free_Data(result_param_);
  DelayFreeObj(1.0, Self);
end;

initialization

RegisterC40('LingoFuse', TC40_LF_Service, TC40_LF_Client);
LF_P2P_name := TLF_AtomString.Create('');
Fixed_Sequenced_Time := Z.Core.C_Tick_Second * 20;
LingoFuse_Process_Name := '';
Find_Safe_Critical := TCritical.Create('Find_Hub_Safe_Critical');
Sort_Safe_Critical := TCritical.Create('Sort_Safe_Critical');
Cycle_Anchor_Seed := 0;
No_Reponse_Cmd_NULL_Flush_Threshold := 5000;
LF_Local_API_Cache := TC40_LF_ClientListCache.Create(1024, nil);
LF_Remote_API_Cache := TC40_LF_ClientListCache.Create(1024, nil);

finalization

DisposeObjectAndNil(LF_Local_API_Cache);
DisposeObjectAndNil(LF_Remote_API_Cache);
DisposeObjectAndNil(LF_P2P_name);
DisposeObjectAndNil(Find_Safe_Critical);
DisposeObjectAndNil(Sort_Safe_Critical);

end.
