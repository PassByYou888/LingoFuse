unit Z.LingoFuse_Export;

{$DEFINE FPC_DELPHI_MODE}
{$I ..\pascal\zNetV2\source\Z.Define.inc}

interface

uses SysUtils,
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.status, Z.UnicodeMixedLib,
  Z.Parsing, Z.MemoryStream, Z.ListEngine, Z.TextDataEngine, Z.Int128, Z.Notify,
  Z.Expression,
  Z.Net, Z.Net.C4, Z.Net.C4_Console_APP,
  Z.FP.Net.CrossSocket, Z.IPC.API, Z.Net.Server.IPC;

const
  C_LingoFuse_Edition = '5.01';

type
  TDataHnd___ = Pointer;
  TAppHnd___ = Pointer;
  TP2P_UID___ = TUID___;
  PP2P_UID___ = PUID___;
  TLF_Call_Event = procedure(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
  TLF_Notify_Event = procedure(Trigger: Pointer; Input: TDataHnd___); cdecl;
  TLF_Async_Call_OnResult = procedure(Data: Pointer; Result_: TDataHnd___); cdecl;
  TLF_Network_Event = procedure(addr_: pansichar); cdecl;

function LF_CreateData(MethodName: pansichar): TDataHnd___; cdecl;
function LF_CreateData_Permanent(MethodName: pansichar): TDataHnd___; cdecl;
procedure LF_FreeData(Hnd: TDataHnd___); cdecl;
function LF_GetBuffer(Hnd: TDataHnd___): Pointer; cdecl;
function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl;
function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl;
function LF_GetPos(Hnd: TDataHnd___): int64; cdecl;
procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64); cdecl;
function LF_GetSize(Hnd: TDataHnd___): int64; cdecl;
procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64); cdecl;
function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___; cdecl;
function LF_Get_P2P_Name(Hnd: TDataHnd___): pansichar; cdecl;

function LF_CreateApp(appName, Desc: pansichar): TAppHnd___; cdecl;
procedure LF_FreeApp(appHnd: TAppHnd___); cdecl;
function LF_Generate_AppName(): pansichar; cdecl;
function LF_Get_AppName(appHnd: TAppHnd___): pansichar; cdecl;
function LF_BindApp(appHnd: TAppHnd___): Integer; cdecl;

function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer; cdecl;
function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer; cdecl;
function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): Integer; cdecl;
function LF_Register_P2P_Call(MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer; cdecl;
function LF_Register_P2P_Notify(MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer; cdecl;
function LF_Unregister_P2P(MethodName: pansichar): Integer; cdecl;

function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___; cdecl;
procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___); cdecl;

function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): Integer; cdecl;
function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): Integer; cdecl;
procedure LF_ResetPrepare(); cdecl;
function LF_PrepareDone: Integer; cdecl;
procedure LF_ExitMainThread; cdecl;

function LF_Call(appName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl;
function LF_Async_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer; cdecl;
function LF_Async_Sequenced_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer; cdecl;
procedure LF_Notify(appName: pansichar; Param: TDataHnd___); cdecl;
procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___); cdecl;

function LF_UID_Call(UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl;
function LF_UID_Async_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer; cdecl;
function LF_UID_Async_Sequenced_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer; cdecl;
procedure LF_UID_Notify(UID: TP2P_UID___; Param: TDataHnd___); cdecl;
procedure LF_UID_Sequenced_Notify(UID: TP2P_UID___; Param: TDataHnd___); cdecl;

function LF_P2PNAME_Call(p2p_name_: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl;
function LF_P2PNAME_Async_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer; cdecl;
function LF_P2PNAME_Async_Sequenced_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer; cdecl;
procedure LF_P2PNAME_Notify(p2p_name_: pansichar; Param: TDataHnd___); cdecl;
procedure LF_P2PNAME_Sequenced_Notify(p2p_name_: pansichar; Param: TDataHnd___); cdecl;

function LF_CheckMainThread(): Integer; cdecl;
function LF_CheckApp(appName: pansichar): Integer; cdecl;
function LF_CheckApi(appName, apiName: pansichar): Integer; cdecl;
function LF_Check_UID(UID: TP2P_UID___): Integer; cdecl;
function LF_Check_UID_Api(UID: TP2P_UID___; apiName: pansichar): Integer; cdecl;
function LF_Check_P2PNAME(p2p_name_: pansichar): Integer; cdecl;
function LF_Check_P2PNAME_Api(p2p_name_: pansichar; apiName: pansichar): Integer; cdecl;

procedure LF_SetOption(Option, Value: pansichar); cdecl;
function LF_GetOption(Option: pansichar): pansichar; cdecl;
function LF_GetStatusCount(): Integer; cdecl;
function LF_GetStatus(): pansichar; cdecl;
procedure LF_PostStatus(status: pansichar); cdecl;
procedure LF_Shutdown; cdecl;

var On_Network_Connect_Event, On_Network_Disconnect_Event: TLF_Network_Event;
procedure LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event); cdecl;

function LF_Debug_Log_Enabled: Boolean; inline;
procedure LF_Debug_Log(const Msg: SystemString); overload;
procedure LF_Debug_Log(const Fmt: SystemString; const Args: array of const); overload;

implementation

uses Z.LingoFuse_Core, Z.Net.C4.LingoFuse;

procedure LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event);
begin
  On_Network_Connect_Event := On_Connect_;
  On_Network_Disconnect_Event := On_Disconnect_;
end;

function LF_Debug_Log_Enabled: Boolean;
begin
  Result := not C40_QuietMode;
end;

procedure LF_Debug_Log(const Msg: SystemString);
begin
  DoStatus('[LF-DEBUG] ' + Msg);
end;

procedure LF_Debug_Log(const Fmt: SystemString; const Args: array of const);
begin
  DoStatus('[LF-DEBUG] ' + PFormat(Fmt, Args));
end;

function DS(p: Pointer): TLF_String; inline;
begin
  if p = nil then
      Result := ''
  else
      Result.ReadUTF8AnsiChar(p);
end;

function LF_CreateData(MethodName: pansichar): TDataHnd___; cdecl;
var
  s: TLF_String;
begin
  s := DS(MethodName);
  Result := TLF_Data.New_Param(s, True);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_CreateData: api="%s" hnd=%p', [s.Text, Result]);
    end;
  s := '';
end;

function LF_CreateData_Permanent(MethodName: pansichar): TDataHnd___; cdecl;
var
  s: TLF_String;
begin
  s := DS(MethodName);
  Result := TLF_Data.New_Param(s, False);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_CreateData_Permanent: api="%s" hnd=%p', [s.Text, Result]);
    end;
  s := '';
end;

procedure LF_FreeData(Hnd: TDataHnd___);
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_FreeData: hnd=%p', [Hnd]);
    end;
  if Hnd <> nil then
      TLF_Data.Free_Data(Hnd);
end;

function LF_GetBuffer(Hnd: TDataHnd___): Pointer;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.GetBuffer
  else
      Result := nil;
end;

function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.WriteBuff(Buff, Size)
  else
      Result := 0;
end;

function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.ReadBuff(Buff, Size)
  else
      Result := 0;
end;

function LF_GetPos(Hnd: TDataHnd___): int64;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.Get_Pos
  else
      Result := 0;
end;

procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64);
begin
  if Hnd <> nil then
      PLF_Data(Hnd)^.Set_Pos(Pos_);
end;

function LF_GetSize(Hnd: TDataHnd___): int64;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.Get_Size
  else
      Result := 0;
end;

procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64);
begin
  if Hnd <> nil then
      PLF_Data(Hnd)^.Set_Size(Size_);
end;

function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
begin
  New(Result);
  if (Hnd <> nil) and (PLF_Data(Hnd)^.Data_Param <> nil) then
      Result^ := PLF_Data(Hnd)^.Get_P2P_UID()
  else Result^ := Null_UID();
  DelayFreeMem(5.0, Result);
end;

function LF_Get_P2P_Name(Hnd: TDataHnd___): pansichar;
var
  tmp: TLF_String;
begin
  tmp := '';
  if (Hnd <> nil) and (PLF_Data(Hnd)^.Data_Param <> nil) then
      tmp := PLF_Data(Hnd)^.Get_P2P_Name();
  Result := tmp.BuildUTF8AnsiChar();
  Z.Notify.DelayFreeMem(5.0, Result);
  tmp := '';
end;

function LF_CreateApp(appName, Desc: pansichar): TAppHnd___;
var
  app: TLF_App;
begin
  app := TLF_App.Create(True);
  app.Name := DS(appName);
  app.Desc := DS(Desc);
  if app.Desc = '' then
      app.Desc := 'No Description';
  Result := app;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_CreateApp: name="%s" desc="%s" hnd=%p', [app.Name.Text, app.Desc.Text, Result]);
    end;
end;

procedure LF_FreeApp(appHnd: TAppHnd___);
var
  app: TLF_App;
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
begin
  if not Core_Dispatch_Order_Activted then exit;
  if appHnd = nil then exit;
  app := appHnd;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_FreeApp: hnd=%p name="%s"', [appHnd, app.Name.Text]);
    end;
  arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
  for i := 0 to length(arry) - 1 do
    begin
      Cli := arry[i] as TC40_LF_Client;
      if Cli.app = app then
          Cli.app := nil;
    end;
  LF_Notify_Sequence_Thread_Pool.Kill_App(app);
  LF_Call_Sequence_Thread_Pool.Kill_App(app);
  app.FakeFree;
end;

var
  Generate_AppName_Call_Num: int64 = 0;
  Generate_AppName_Critical: TCritical = nil;

function LF_Generate_AppName(): pansichar;
var
  i: Integer;
  tmp: TLF_String;
begin
  tmp := '';
  Generate_AppName_Critical.Lock;
  try
    for i := 0 to C40_PhysicsTunnelPool.Count - 1 do
      begin
        if tmp <> '' then
            tmp.Append('&');
        tmp.Append(Build_Host_URL(C40_PhysicsTunnelPool[i].PhysicsAddr, C40_PhysicsTunnelPool[i].PhysicsPort) + '&' +
            umlIntToStr(C40_PhysicsTunnelPool[i].PhysicsTunnel.RemoteID).Text);
      end;
    tmp.Append('&' + Make_LingoFuse_Process_Name.Text + '&' +
        umlIntToStr(AtomInc(Generate_AppName_Call_Num)).Text);
    tmp := C_Generate_Prefix + tmp;
  finally
      Generate_AppName_Critical.UnLock;
  end;
  Result := tmp.BuildUTF8AnsiChar();
  Z.Notify.DelayFreeMem(5.0, Result);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Generate_AppName: "%s"', [tmp.Text]);
    end;
  tmp := '';
end;

function LF_Get_AppName(appHnd: TAppHnd___): pansichar;
var
  app: TLF_App;
begin
  if appHnd = nil then
    begin
      Result := nil;
      exit;
    end;
  app := appHnd;
  Result := app.Name.BuildUTF8AnsiChar();
  Z.Notify.DelayFreeMem(5.0, Result);
end;

function LF_BindApp(appHnd: TAppHnd___): Integer;
var
  app: TLF_App;
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  tmp: TLF_String;
begin
  Result := 0;
  if appHnd = nil then exit;
  app := appHnd;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_BindApp: hnd=%p name="%s"', [appHnd, app.Name.Text]);
    end;
  if not Simulator_Main_Thread_Activted then
    begin
      DoStatus('LF_BindApp: Main thread is not active - cannot bind app.');
      exit;
    end;
  arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
  for i := 0 to length(arry) - 1 do
    begin
      Cli := arry[i] as TC40_LF_Client;
      if Cli.app = nil then
        begin
          Cli.app := app;
          inc(Result);

          if Cli.C40PhysicsTunnel.IPC_Mode then
              DoStatus('APP %s "%s" Bind OK for Connection "%s"', [Cli.app.Name.Text, Cli.app.Desc.Text, Cli.C40PhysicsTunnel.PhysicsAddr.Text])
          else
              DoStatus('APP %s "%s" Bind OK for Connection "%s"', [Cli.app.Name.Text, Cli.app.Desc.Text, Build_Host_URL(Cli.C40PhysicsTunnel.PhysicsAddr, Cli.C40PhysicsTunnel.PhysicsPort)]);

          if Cli.app.Engine.LF_MethodPool.Num > 0 then
            with Cli.app.Engine.LF_MethodPool.Repeat_ do
              repeat
                if Assigned(Queue^.Data.Data.Second.On_Call) then
                    tmp := 'call'
                else if Assigned(Queue^.Data.Data.Second.On_Notify) then
                    tmp := 'notify'
                else
                    tmp := 'error';
                DoStatus('  (%s) (%s) "%s"', [tmp.Text, Queue^.Data.Data.Primary, Queue^.Data.Data.Second.Desc.ShortText(50, 10, 10).Text]);
              until not Next;
        end;
    end;
  if Result = 0 then
      DoStatus('LF_BindApp: All clients are already occupied - cannot bind app "%s".', [app.Name.Text]);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_BindApp done: bound=%d', [Result]);
    end;
end;

function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer;
var
  app: TLF_App;
  MethodName__, Desc__: TLF_String;
begin
  Result := 0;
  if appHnd = nil then exit;
  if MethodName = nil then exit;
  app := appHnd;
  MethodName__ := DS(MethodName);
  Desc__ := DS(Desc);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_RegisterCall: hnd=%p name="%s"', [appHnd, MethodName__.Text]);
    end;
  Result := if_(app.Engine.Reg_Call(MethodName__, Desc__, Trigger, OnCall), 1, 0);
end;

function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer;
var
  app: TLF_App;
  MethodName__, Desc__: TLF_String;
begin
  Result := 0;
  if appHnd = nil then exit;
  if MethodName = nil then exit;
  app := appHnd;
  MethodName__ := DS(MethodName);
  Desc__ := DS(Desc);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_RegisterNotify: hnd=%p name="%s"', [appHnd, MethodName__.Text]);
    end;
  Result := if_(app.Engine.Reg_Notify(MethodName__, Desc__, Trigger, OnNotify), 1, 0);
end;

function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): Integer;
var
  app: TLF_App;
  MethodName__: TLF_String;
begin
  Result := 0;
  if appHnd = nil then exit;
  app := appHnd;
  MethodName__ := DS(MethodName);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Unregister: hnd=%p name="%s"', [appHnd, MethodName__.Text]);
    end;
  Result := if_(app.Engine.UnReg(MethodName__), 1, 0);
end;

function LF_Register_P2P_Call(MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer;
var
  MethodName__, Desc__: TLF_String;
begin
  Result := 0;
  MethodName__ := DS(MethodName);
  Desc__ := DS(Desc);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Register_P2P_Call: name="%s"', [MethodName__.Text]);
    end;
  Result := if_(LF_P2P_APP.Engine.Reg_Call(MethodName__, Desc__, Trigger, OnCall), 1, 0);
end;

function LF_Register_P2P_Notify(MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer;
var
  MethodName__, Desc__: TLF_String;
begin
  Result := 0;
  MethodName__ := DS(MethodName);
  Desc__ := DS(Desc);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Register_P2P_Notify: name="%s"', [MethodName__.Text]);
    end;
  Result := if_(LF_P2P_APP.Engine.Reg_Notify(MethodName__, Desc__, Trigger, OnNotify), 1, 0);
end;

function LF_Unregister_P2P(MethodName: pansichar): Integer;
var
  MethodName__: TLF_String;
begin
  Result := 0;
  MethodName__ := DS(MethodName);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Unregister_P2P: name="%s"', [MethodName__.Text]);
    end;
  Result := if_(LF_P2P_APP.Engine.UnReg(MethodName__), 1, 0);
end;

function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___;
var
  app: TLF_App;
  tmp: TMem64;
begin
  Result := nil;
  if appHnd = nil then exit;
  if Param = nil then exit;
  app := appHnd;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_LocalCall: hnd=%p param=%p', [appHnd, Param]);
    end;
  tmp := TMem64.Create;
  try
    PLF_Data(Param).Data_Param.EncryptToMem(tmp);
    PLF_Data(Param).Begin_Call;
    Result := TLF_Data.New_Result_From(app.Engine.Execute_Call(tmp), True);
  finally
    if Result <> nil then
        PLF_Data(Result)^.Data_Info := PFormat('result for app:%s api:%s', [app.Name.Text, PLF_Data(Param)^.Data_Param.apiName.Text]);
    PLF_Data(Param).End_Call;
    DisposeObject(tmp);
  end;
end;

procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___);
var
  app: TLF_App;
  tmp: TMem64;
begin
  if appHnd = nil then exit;
  if Param = nil then exit;
  app := appHnd;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_LocalNotify: hnd=%p param=%p', [appHnd, Param]);
    end;
  tmp := TMem64.Create;
  try
    PLF_Data(Param).Data_Param.EncryptToMem(tmp);
    PLF_Data(Param).Begin_Call;
    app.Engine.Execute_Notify(tmp);
  finally
    PLF_Data(Param).End_Call;
    DisposeObject(tmp);
  end;
end;

type
  TAppHnd_Bind_Tag = record
    appHnd: TAppHnd___;
    Tag: Integer;
    IsService, IsClient: Boolean;
    Listen, Addr, Port: TLF_String;
    procedure Init;
  end;

  TAppHnd_Bind_Tag_List = class(TBigList<TAppHnd_Bind_Tag>)
  public
    procedure DoFree(var Data: TAppHnd_Bind_Tag); override;
    function CompareData(const Data_1, Data_2: TAppHnd_Bind_Tag): Boolean; override;
  end;

procedure TAppHnd_Bind_Tag.Init;
begin
  appHnd := nil;
  Tag := 0;
  IsService := False;
  IsClient := False;
  Listen := '';
  Addr := '';
  Port := '';
end;

procedure TAppHnd_Bind_Tag_List.DoFree(var Data: TAppHnd_Bind_Tag);
begin
  Data.Init();
  inherited DoFree(Data);
end;

function TAppHnd_Bind_Tag_List.CompareData(const Data_1, Data_2: TAppHnd_Bind_Tag): Boolean;
begin
  Result :=
    (Data_1.appHnd = Data_2.appHnd) and (Data_1.Tag = Data_2.Tag) and
    (Data_1.IsService = Data_2.IsService) and (Data_1.IsClient = Data_2.IsClient) and
    Data_1.Listen.Same(@Data_2.Listen) and Data_1.Addr.Same(@Data_2.Addr);
end;

var
  Prepare_Commands: TPascalStringList = nil;
  Tag_Seed: Integer = 0;
  AppHnd_Bind_Tag_List: TAppHnd_Bind_Tag_List = nil;

procedure LF_ResetPrepare();
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_ResetPrepare: clearing %d prepare commands', [Prepare_Commands.Count]);
    end;
  Prepare_Commands.Clear;
  AppHnd_Bind_Tag_List.Clear;
end;

type
  TC40_Service_Bridge = class(TCore_InterfacedObject_Intermediate, IC40_PhysicsService_Event)
  public
    procedure C40_PhysicsService_Build_Network(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service);
    procedure C40_PhysicsService_Start(Sender: TC40_PhysicsService);
    procedure C40_PhysicsService_Stop(Sender: TC40_PhysicsService);
    procedure C40_PhysicsService_LinkSuccess(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
    procedure C40_PhysicsService_UserOut(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
  end;

procedure TC40_Service_Bridge.C40_PhysicsService_Build_Network(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service);
begin
end;

procedure TC40_Service_Bridge.C40_PhysicsService_Start(Sender: TC40_PhysicsService);
begin
  if Sender.IPC_Mode then
      DoStatus('LingoFuse Service Listening: "%s" OK, Host: "%s"', [Sender.ListeningAddr.Text, Sender.PhysicsAddr.Text])
  else
      DoStatus('LingoFuse Service Listening: "%s" OK, Host: "%s"', [Build_Host_URL(Sender.ListeningAddr, Sender.PhysicsPort), Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service Start: listen="%s" host="%s" port=%d', [Sender.ListeningAddr.Text, Sender.PhysicsAddr.Text, Sender.PhysicsPort]);
    end;
end;

procedure TC40_Service_Bridge.C40_PhysicsService_Stop(Sender: TC40_PhysicsService);
begin
  DoStatus('LingoFuse Service Listening: "%s" Stop', [Build_Host_URL(Sender.ListeningAddr, Sender.PhysicsPort)]);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service Stop: listen="%s"', [Sender.ListeningAddr.Text]);
    end;
end;

procedure TC40_Service_Bridge.C40_PhysicsService_LinkSuccess(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
var
  serv: TC40_LF_Service;
  user_io: TC40_LF_RecvTunnel;
begin
  serv := Custom_Service_ as TC40_LF_Service;
  user_io := Trigger_ as TC40_LF_RecvTunnel;
  DoStatus('LingoFuse Service Link Succeeded IO "%s"', [user_io.Owner.GetPeerIP]);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service LinkSuccess: peer="%s"', [user_io.Owner.GetPeerIP]);
    end;
end;

procedure TC40_Service_Bridge.C40_PhysicsService_UserOut(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
var
  serv: TC40_LF_Service;
  user_io: TC40_LF_RecvTunnel;
begin
  serv := Custom_Service_ as TC40_LF_Service;
  user_io := Trigger_ as TC40_LF_RecvTunnel;
  DoStatus('LingoFuse Service User-out IO "%s"', [user_io.Owner.GetPeerIP]);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Service UserOut: peer="%s"', [user_io.Owner.GetPeerIP]);
    end;
end;

type
  TC40_Tunnel_Bridge = class(TCore_InterfacedObject_Intermediate, IC40_PhysicsTunnel_Event)
  public
    constructor Create;
    procedure C40_PhysicsTunnel_Connected(Sender: TC40_PhysicsTunnel);
    procedure C40_PhysicsTunnel_Disconnect(Sender: TC40_PhysicsTunnel);
    procedure C40_PhysicsTunnel_Build_Network(Sender: TC40_PhysicsTunnel; Custom_Client_: TC40_Custom_Client);
    procedure C40_PhysicsTunnel_Client_Connected(Sender: TC40_PhysicsTunnel; Custom_Client_: TC40_Custom_Client);
  end;

constructor TC40_Tunnel_Bridge.Create;
begin
  inherited Create;
end;

procedure TC40_Tunnel_Bridge.C40_PhysicsTunnel_Connected(Sender: TC40_PhysicsTunnel);
begin
  DoStatus('Connection %s Succeeded', [Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Tunnel Connected: host="%s" port=%d', [Sender.PhysicsAddr.Text, Sender.PhysicsPort]);
    end;
end;

procedure TC40_Tunnel_Bridge.C40_PhysicsTunnel_Disconnect(Sender: TC40_PhysicsTunnel);
begin
  DoStatus('%s Disconnected', [Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Tunnel Disconnected: host="%s" port=%d', [Sender.PhysicsAddr.Text, Sender.PhysicsPort]);
    end;
end;

procedure TC40_Tunnel_Bridge.C40_PhysicsTunnel_Build_Network(Sender: TC40_PhysicsTunnel; Custom_Client_: TC40_Custom_Client);
begin
  if Sender.IPC_Mode then
      DoStatus('Ready Network: "%s"', [Sender.PhysicsAddr.Text])
  else
      DoStatus('Ready Network: "%s"', [Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
end;

procedure TC40_Tunnel_Bridge.C40_PhysicsTunnel_Client_Connected(Sender: TC40_PhysicsTunnel; Custom_Client_: TC40_Custom_Client);
var
  Cli: TC40_LF_Client;
  tmp: TLF_String;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Tunnel ClientConnected: tag=%d', [Custom_Client_.Tag]);
    end;
  if AppHnd_Bind_Tag_List.Num > 0 then
    with AppHnd_Bind_Tag_List.Repeat_ do
      repeat
        if Custom_Client_.Tag = Queue^.Data.Tag then
          begin
            Cli := (Custom_Client_ as TC40_LF_Client);
            Cli.app := Queue^.Data.appHnd;
            if Cli.app <> nil then
              begin
                if Cli.C40PhysicsTunnel.IPC_Mode then
                    DoStatus('APP %s "%s" Ready OK, Connection "%s"', [Cli.app.Name.Text, Cli.app.Desc.Text, Cli.C40PhysicsTunnel.PhysicsAddr.Text])
                else
                    DoStatus('APP %s "%s" Ready OK, Connection "%s"', [Cli.app.Name.Text, Cli.app.Desc.Text, Build_Host_URL(Cli.C40PhysicsTunnel.PhysicsAddr, Cli.C40PhysicsTunnel.PhysicsPort)]);
                if Cli.app.Engine.LF_MethodPool.Num > 0 then
                  with Cli.app.Engine.LF_MethodPool.Repeat_ do
                    repeat
                      if Assigned(Queue^.Data.Data.Second.On_Call) then
                          tmp := 'call'
                      else if Assigned(Queue^.Data.Data.Second.On_Notify) then
                          tmp := 'notify'
                      else
                          tmp := 'error';
                      DoStatus('  (%s) (%s) "%s"', [tmp.Text, Queue^.Data.Data.Primary, Queue^.Data.Data.Second.Desc.ShortText(50, 10, 10).Text]);
                    until not Next;
              end;
          end;
      until not Next;
end;

var
  Init_In_Progress, Init_Succeeded, Simulated_Main_Thread_Running: Boolean;
  C40_Tunnel_Bridge: TC40_Tunnel_Bridge;
  C40_Service_Bridge: TC40_Service_Bridge;
  Overlap_Connection: Boolean;
  Wait_Connection_ReadyOk: Boolean;
  Wait_Connection_Timeout: TTimeTick;

procedure Do_Post_Run_C40_Extract_CmdLine;
begin
  C40_Extract_CmdLine();
end;

function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): Integer;
var
  Listen, Host, Port: U_String;
  Cmd_: U_String;
  running: Boolean;
begin
  Listen := DS(ListeningAddr_).Text;
  Host := DS(PhysicsAddr_).Text;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_PrepareService: listen="%s" host="%s"', [Listen.Text, Host.Text]);
    end;
  if Is_IPC_Addr(Host.Text) or Is_IPC_Addr(Listen.Text) then
      Port := '0'
  else
    begin
      Port := '9898';
      ExtractHostAddress(Host, Port);
      ExtractHostAddress(Listen, Port);
    end;

  if Init_Succeeded and Simulated_Main_Thread_Running then
    begin
      if Z.Net.C4.C40_PhysicsServicePool.ExistsListenAddr(Listen, EStrToInt(Port)) then
        begin
          DoStatus('error: repeat listen addr:%s port:%s', [Listen.Text, Port.Text]);
          Result := -1;
          exit;
        end;
    end;

  if AppHnd_Bind_Tag_List.Num > 0 then
    begin
      with AppHnd_Bind_Tag_List.Repeat_ do
        repeat
          if Listen.Same(Queue^.Data.Listen.Text) and Port.Same(Queue^.Data.Port.Text) and (Queue^.Data.IsService) then
            begin
              DoStatus('prepare error: repeat listen addr:%s port:%s', [Listen.Text, Port.Text]);
              Result := -1;
              exit;
            end;
        until not Next;
    end;

  Cmd_ := PFormat('Service("%s","%s",%s,"LingoFuse@Tag=%d")', [Listen.Text, Host.Text, Port.Text, Tag_Seed]);
  Result := Tag_Seed;
  Prepare_Commands.Add(Cmd_);
  with AppHnd_Bind_Tag_List.Add_Null^ do
    begin
      Data.Init();
      Data.appHnd := nil;
      Data.Tag := Tag_Seed;
      Data.IsService := True;
      Data.Listen := Listen;
      Data.Addr := Build_Host_URL(Host, Port);
      Data.Port := Port;
    end;
  AtomInc(Tag_Seed);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_PrepareService: tag=%d cmd="%s"', [Result, Cmd_.Text]);
    end;

  if Init_Succeeded and Simulated_Main_Thread_Running then
    begin
      SetLength(C40AppParam, 1);
      C40AppParam[0] := Cmd_;
      C40AppParsingTextStyle := TTextStyle.tsC;
      DoStatus('Run %s', [Cmd_.Text]);
      if TCompute.CurrentThread = Z.Core.Main_Thread then
        begin
          Do_Post_Run_C40_Extract_CmdLine();
        end
      else
        begin
          Z.Core.MainThreadProgress.PostC1(Do_Post_Run_C40_Extract_CmdLine, @running, nil);
          while running do
              TCompute.Sleep(10);
        end;
      SetLength(C40AppParam, 0);
    end
  else
    begin
      DoStatus('LF_PrepareService: %s', [Cmd_.Text]);
    end;
end;

function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): Integer;
var
  Host, Port: U_String;
  Cmd_: TLF_String;
  full_url: TLF_String;
  running: Boolean;
  Cli: TC40_LF_Client;
  tk: TTimeTick;
begin
  Host := DS(PhysicsAddr_).Text;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_PrepareClient: host="%s" hnd=%p', [Host.Text, appHnd]);
    end;
  if Is_IPC_Addr(Host.Text) then
      Port := '0'
  else
    begin
      Port := '9898';
      ExtractHostAddress(Host, Port);
    end;

  if (not Overlap_Connection) and Init_Succeeded and Simulated_Main_Thread_Running then
    begin
      if Z.Net.C4.C40_PhysicsTunnelPool.ExistsPhysicsAddr(Host, EStrToInt(Port)) then
        begin
          DoStatus('error: repeat connection addr:%s port:%s', [Host.Text, Port.Text]);
          Result := -1;
          exit;
        end;
    end;

  if (not Overlap_Connection) and (AppHnd_Bind_Tag_List.Num > 0) then
    begin
      full_url := Build_Host_URL(Host, Port);
      with AppHnd_Bind_Tag_List.Repeat_ do
        repeat
          if full_url.Same(Queue^.Data.Addr) and (Queue^.Data.IsClient) then
            begin
              DoStatus('prepare error: repeat connection addr:%s port:%s', [Host.Text, Port.Text]);
              Result := -1;
              exit;
            end;
        until not Next;
    end;

  Cmd_ := PFormat(if_(Overlap_Connection, 'NewKeepAlive', 'KeepAlive') + '("%s",%s,"LingoFuse@Tag=%d")', [Host.Text, Port.Text, Tag_Seed]);
  Result := Tag_Seed;
  Prepare_Commands.Add(Cmd_);
  with AppHnd_Bind_Tag_List.Add_Null^ do
    begin
      Data.Init();
      Data.appHnd := appHnd;
      Data.Tag := Tag_Seed;
      Data.IsClient := True;
      Data.Listen := '';
      Data.Addr := Build_Host_URL(Host, Port);
      Data.Port := Port;
    end;
  AtomInc(Tag_Seed);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_PrepareClient: tag=%d cmd="%s"', [Result, Cmd_.Text]);
    end;

  if Init_Succeeded and Simulated_Main_Thread_Running then
    begin
      SetLength(C40AppParam, 1);
      C40AppParam[0] := Cmd_;
      C40AppParsingTextStyle := TTextStyle.tsC;
      DoStatus('Run %s', [Cmd_.Text]);
      if TCompute.CurrentThread = Z.Core.Main_Thread then
        begin
          Do_Post_Run_C40_Extract_CmdLine();
        end
      else
        begin
          Z.Core.MainThreadProgress.PostC1(Do_Post_Run_C40_Extract_CmdLine, @running, nil);
          while running do
              TCompute.Sleep(10);

          Cli := C40_ClientPool.FindTag(Result) as TC40_LF_Client;
          if Cli <> nil then
            if Wait_Connection_ReadyOk then
              begin
                tk := GetTimeTick + Wait_Connection_Timeout;
                while (GetTimeTick() < tk) and Simulated_Main_Thread_Running do
                  begin
                    if (Cli.Connected) and ((Cli.app = nil) or Cli.LF_AppIsOnline) and (Cli.LF_Service_Info_Is_Online) then
                        break
                    else
                        TCompute.Sleep(10);
                  end;
              end;
        end;
      SetLength(C40AppParam, 0);
    end
  else
    begin
      DoStatus('LF_PrepareClient: %s', [Cmd_.Text]);
    end;
end;

procedure Simulated_Main_Thread();
var
  i: Integer;
  tk: TTimeTick;
  Cli: TC40_LF_Client;
  Prepare_Cli_Num, Online_Num: Integer;
begin
  DoStatus('Main Thread Begin, LingoFuse-v%s C4-v%s,Net-v%s,%s,IPC-v%s,Core-v%s',
    [C_LingoFuse_Edition, C_C4_Edition, C_ZNet_Edition, C_Cross_Edition, C_Z_IPC_Edition, C_Z_Core_Edition]);

  SetLength(C40AppParam, Prepare_Commands.Count);
  for i := 0 to Prepare_Commands.Count - 1 do
      C40AppParam[i] := Prepare_Commands[i];

  if Prepare_Commands.Count > 0 then
    begin
      C40AppParsingTextStyle := TTextStyle.tsC;
      On_C40_PhysicsTunnel_Event_Console := C40_Tunnel_Bridge;

      Init_Succeeded := C40_Extract_CmdLine();

      if Init_Succeeded and Wait_Connection_ReadyOk then
        begin
          Prepare_Cli_Num := 0;
          if AppHnd_Bind_Tag_List.Num > 0 then
            with AppHnd_Bind_Tag_List.Repeat_ do
              repeat
                if Queue^.Data.IsClient then
                    inc(Prepare_Cli_Num);
              until not Next;

          if Prepare_Cli_Num > 0 then
            begin
              tk := GetTimeTick + if_(Wait_Connection_Timeout < 500, uint64(5000), Wait_Connection_Timeout);
              repeat
                C40Progress(10);
                Online_Num := 0;
                if AppHnd_Bind_Tag_List.Num > 0 then
                  begin
                    with AppHnd_Bind_Tag_List.Repeat_ do
                      repeat
                        if Queue^.Data.IsClient then
                          begin
                            Cli := C40_ClientPool.FindTag(Queue^.Data.Tag) as TC40_LF_Client;
                            if (Cli <> nil) and (Cli.Connected) and ((Cli.app = nil) or Cli.LF_AppIsOnline) and (Cli.LF_Service_Info_Is_Online) then
                                inc(Online_Num);
                          end;
                      until not Next;
                  end;
                Init_Succeeded := Online_Num >= Prepare_Cli_Num;
              until Init_Succeeded or (not Simulated_Main_Thread_Running) or ((Wait_Connection_Timeout > 0) and (GetTimeTick() > tk));
            end;
        end;
    end
  else
    begin
      Init_Succeeded := True;
    end;

  Init_In_Progress := False;

  if Init_Succeeded then
    while Simulated_Main_Thread_Running do
      begin
        C40Progress(if_(LF_RunningCount.V > 0, 1, 10));
        try
            LF_DataPool.Progress();
        except
        end;
      end;

  try
    C40Clean();
    LF_Call_Sequence_Thread_Pool.Stop;
    LF_Notify_Sequence_Thread_Pool.Stop;
    SysPost.Clean;
  except
  end;

  try
    LF_DataPool.Free_All_Hnd();
    LF_DataMemory.Free_All_PLF_Data_Memory();
  except
  end;
  DoStatus('LingoFuse Main Thread Exit');
  Check_Soft_Thread_Synchronize(0);
end;

function LF_PrepareDone: Integer;
var
  tk: TTimeTick;
begin
  Result := 0;
  if Simulated_Main_Thread_Running then
      exit;

  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_PrepareDone: starting simulator main thread');
    end;
  Open_Core_Dispatch_Thread();
  Init_In_Progress := True;
  Init_Succeeded := False;
  Simulated_Main_Thread_Running := True;
  LF_RunningCount.V := 0;

  Begin_Simulator_Main_Thread(Simulated_Main_Thread);
  tk := GetTimeTick() + if_(Wait_Connection_Timeout < 500, uint64(5000), Wait_Connection_Timeout) + 1000;
  while Init_In_Progress do
    begin
      Boot_Thread_Sync_Tool.Check_Synchronize(10);
      if GetTimeTick() > tk then break;
    end;
  Result := if_(Init_Succeeded, 1, 0);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_PrepareDone: result=%d', [Result]);
    end;
end;

procedure LF_ExitMainThread;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_ExitMainThread: signaling stop');
    end;
  Simulated_Main_Thread_Running := False;
  while Simulator_Main_Thread_Activted do
      Boot_Thread_Sync_Tool.Check_Synchronize(10);
end;

var
  Find_Class_Critical: TCritical = nil;

function LF_Call(appName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
var
  Cli: TC40_LF_Client;
  tmp, Output: TMem64;
begin
  if Param = nil then
    begin
      Result := TLF_Data.New_Result_From(TMem64.Create, True);
      PLF_Data(Result)^.Data_Info := PFormat('result for app:%s api:error!', [DS(appName).Text]);
      DoStatus('LF_Call(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Call: app="%s" timeout=%d', [DS(appName).Text, Timeout_]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  Output := nil;
  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
          Output := Cli.Wait_Execute_Call(DS(appName), tmp, Timeout_);
      except
          DoStatus('LF_Call(%s, ...) except', [DS(appName).Text]);
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('"%s" no connection', [DS(appName).Text]);
    end;
  if Output = nil then
      Output := TMem64.Create;
  Result := TLF_Data.New_Result_From(Output, True);
  PLF_Data(Result)^.Data_Info := PFormat('result for app:%s api:%s', [DS(appName).Text, PLF_Data(Param)^.Data_Param.apiName.Text]);
end;

function LF_Async_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer;
var
  tmp_data: TDataHnd___;
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
  Result := 0;
  if Param = nil then
    begin
      tmp_data := TLF_Data.New_Result_From(TMem64.Create, False);
      PLF_Data(tmp_data)^.Data_Info := PFormat('result for app:%s api:error!', [DS(appName).Text]);
      try
        if Assigned(OnResult) then
            OnResult(Data, tmp_data);
      except
      end;
      TLF_Data.Free_Data(tmp_data);
      DoStatus('LF_Async_Call(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Async_Call: app="%s"', [DS(appName).Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
        if Cli.Async_Execute_Call(DS(appName), tmp, Data, OnResult) then
            Result := 1;
      except
          DoStatus('LF_Async_Call(%s, ...) except', [DS(appName).Text]);
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('"%s" no connection', [DS(appName).Text]);
    end;
end;

function LF_Async_Sequenced_Call(appName: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer;
var
  tmp_data: TDataHnd___;
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
  Result := 0;
  if Param = nil then
    begin
      tmp_data := TLF_Data.New_Result_From(TMem64.Create, False);
      PLF_Data(tmp_data)^.Data_Info := PFormat('result for app:%s api:error!', [DS(appName).Text]);
      try
        if Assigned(OnResult) then
            OnResult(Data, tmp_data);
      except
      end;
      TLF_Data.Free_Data(tmp_data);
      DoStatus('LF_Async_Sequenced_Call(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Async_Sequenced_Call: app="%s"', [DS(appName).Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
        if Cli.Async_Sequenced_Execute_Call(DS(appName), tmp, Data, OnResult) then
            Result := 1;
      except
          DoStatus('LF_Async_Sequenced_Call(%s, ...) except', [DS(appName).Text]);
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('"%s" no connection', [DS(appName).Text]);
    end;
end;

procedure LF_Notify(appName: pansichar; Param: TDataHnd___);
var
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
  if Param = nil then
    begin
      DoStatus('LF_Notify(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Notify: app="%s"', [DS(appName).Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      exit;
  end;

  if Cli = nil then
      exit;
  tmp := TMem64.Create;
  PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
  PLF_Data(Param)^.Begin_Call;
  try
      Cli.Send_Execute_Notify(DS(appName), tmp);
  except
      DoStatus('LF_Notify(%s, ...) except', [DS(appName).Text]);
  end;
  PLF_Data(Param)^.End_Call;
  DisposeObject(tmp);
end;

procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___);
var
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
  if Param = nil then
    begin
      DoStatus('LF_Sequenced_Notify(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Sequenced_Notify: app="%s"', [DS(appName).Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      exit;
  end;

  if Cli = nil then
      exit;
  tmp := TMem64.Create;
  PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
  PLF_Data(Param)^.Begin_Call;
  try
      Cli.Send_Sequenced_Notify(DS(appName), tmp);
  except
      DoStatus('LF_Sequenced_Notify(%s, ...) except', [DS(appName).Text]);
  end;
  PLF_Data(Param)^.End_Call;
  DisposeObject(tmp);
end;

function LF_UID_Call(UID: TP2P_UID___; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
var
  Cli: TC40_LF_Client;
  tmp, Output: TMem64;
begin
  if Param = nil then
    begin
      Result := TLF_Data.New_Result_From(TMem64.Create, True);
      PLF_Data(Result)^.Data_Info := 'result for uid api:error!';
      DoStatus('LF_UID_Call(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_UID_Call: timeout=%d', [Timeout_]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  Output := nil;
  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
          Output := Cli.Wait_UID_Execute_Call(UID, tmp, Timeout_);
      except
          DoStatus('LF_UID_Call except');
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('LF_UID_Call: no connection');
    end;
  if Output = nil then
      Output := TMem64.Create;
  Result := TLF_Data.New_Result_From(Output, True);
  PLF_Data(Result)^.Data_Info := PFormat('result for uid api:%s', [PLF_Data(Param)^.Data_Param.apiName.Text]);
end;

function LF_UID_Async_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer;
var
  tmp_data: TDataHnd___;
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
  Result := 0;
  if Param = nil then
    begin
      tmp_data := TLF_Data.New_Result_From(TMem64.Create, False);
      PLF_Data(tmp_data)^.Data_Info := 'result for uid api:error!';
      try
        if Assigned(OnResult) then
            OnResult(Data, tmp_data);
      except
      end;
      TLF_Data.Free_Data(tmp_data);
      DoStatus('LF_UID_Async_Call(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_UID_Async_Call');
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
        if Cli.Async_UID_Execute_Call(UID, tmp, Data, OnResult) then
            Result := 1;
      except
          DoStatus('LF_UID_Async_Call except');
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('LF_UID_Async_Call: no connection');
    end;
end;

function LF_UID_Async_Sequenced_Call(UID: TP2P_UID___; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer;
var
  tmp_data: TDataHnd___;
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
  Result := 0;
  if Param = nil then
    begin
      tmp_data := TLF_Data.New_Result_From(TMem64.Create, False);
      PLF_Data(tmp_data)^.Data_Info := 'result for uid api:error!';
      try
        if Assigned(OnResult) then
            OnResult(Data, tmp_data);
      except
      end;
      TLF_Data.Free_Data(tmp_data);
      DoStatus('LF_UID_Async_Sequenced_Call(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_UID_Async_Sequenced_Call');
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
        if Cli.Async_UID_Sequenced_Execute_Call(UID, tmp, Data, OnResult) then
            Result := 1;
      except
          DoStatus('LF_UID_Async_Sequenced_Call except');
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('LF_UID_Async_Sequenced_Call: no connection');
    end;
end;

procedure LF_UID_Notify(UID: TP2P_UID___; Param: TDataHnd___);
var
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
  if Param = nil then
    begin
      DoStatus('LF_UID_Notify(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_UID_Notify');
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      exit;
  end;

  if Cli = nil then
      exit;
  tmp := TMem64.Create;
  PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
  PLF_Data(Param)^.Begin_Call;
  try
      Cli.Send_UID_Execute_Notify(UID, tmp);
  except
  end;
  PLF_Data(Param)^.End_Call;
  DisposeObject(tmp);
end;

procedure LF_UID_Sequenced_Notify(UID: TP2P_UID___; Param: TDataHnd___);
var
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
  if Param = nil then
    begin
      DoStatus('LF_UID_Sequenced_Notify(...) parameter = nil!');
      exit;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_UID_Sequenced_Notify');
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      exit;
  end;

  if Cli = nil then
      exit;
  tmp := TMem64.Create;
  PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
  PLF_Data(Param)^.Begin_Call;
  try
      Cli.Send_UID_Execute_Sequenced_Notify(UID, tmp);
  except
  end;
  PLF_Data(Param)^.End_Call;
  DisposeObject(tmp);
end;

function LF_P2PNAME_Call(p2p_name_: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
var
  Cli: TC40_LF_Client;
  tmp, Output: TMem64;
  p2p_name__: TLF_String;
begin
  if Param = nil then
    begin
      Result := TLF_Data.New_Result_From(TMem64.Create, True);
      PLF_Data(Result)^.Data_Info := 'result for p2pname api:error!';
      DoStatus('LF_P2PNAME_Call(...) parameter = nil!');
      exit;
    end;
  p2p_name__ := DS(p2p_name_);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_P2PNAME_Call: name="%s"', [p2p_name__.Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  Output := nil;
  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
          Output := Cli.Wait_P2PName_Execute_Call(p2p_name__, tmp, Timeout_);
      except
          DoStatus('LF_P2PNAME_Call(%s, ...) except', [p2p_name__.Text]);
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('LF_P2PNAME_Call: no connection');
    end;
  if Output = nil then
      Output := TMem64.Create;
  Result := TLF_Data.New_Result_From(Output, True);
  PLF_Data(Result)^.Data_Info := PFormat('result for p2pname:%s api:%s', [p2p_name__.Text, PLF_Data(Param)^.Data_Param.apiName.Text]);
end;

function LF_P2PNAME_Async_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer;
var
  tmp_data: TDataHnd___;
  Cli: TC40_LF_Client;
  tmp: TMem64;
  p2p_name__: TLF_String;
begin
  Result := 0;
  if Param = nil then
    begin
      tmp_data := TLF_Data.New_Result_From(TMem64.Create, False);
      PLF_Data(tmp_data)^.Data_Info := 'result for p2pname api:error!';
      try
        if Assigned(OnResult) then
            OnResult(Data, tmp_data);
      except
      end;
      TLF_Data.Free_Data(tmp_data);
      DoStatus('LF_P2PNAME_Async_Call(...) parameter = nil!');
      exit;
    end;
  p2p_name__ := DS(p2p_name_);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_P2PNAME_Async_Call: name="%s"', [p2p_name__.Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
        if Cli.Async_P2PName_Execute_Call(p2p_name__, tmp, Data, OnResult) then
            Result := 1;
      except
          DoStatus('LF_P2PNAME_Async_Call(%s, ...) except', [p2p_name__.Text]);
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('LF_P2PNAME_Async_Call: no connection');
    end;
end;

function LF_P2PNAME_Async_Sequenced_Call(p2p_name_: pansichar; Param: TDataHnd___; Data: Pointer; OnResult: TLF_Async_Call_OnResult): Integer;
var
  tmp_data: TDataHnd___;
  Cli: TC40_LF_Client;
  tmp: TMem64;
  p2p_name__: TLF_String;
begin
  Result := 0;
  if Param = nil then
    begin
      tmp_data := TLF_Data.New_Result_From(TMem64.Create, False);
      PLF_Data(tmp_data)^.Data_Info := 'result for p2pname api:error!';
      try
        if Assigned(OnResult) then
            OnResult(Data, tmp_data);
      except
      end;
      TLF_Data.Free_Data(tmp_data);
      DoStatus('LF_P2PNAME_Async_Sequenced_Call(...) parameter = nil!');
      exit;
    end;
  p2p_name__ := DS(p2p_name_);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_P2PNAME_Async_Sequenced_Call: name="%s"', [p2p_name__.Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      Cli := nil;
  end;

  if Cli <> nil then
    begin
      tmp := TMem64.Create;
      PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
      PLF_Data(Param)^.Begin_Call;
      try
        if Cli.Async_P2PName_Sequenced_Execute_Call(p2p_name__, tmp, Data, OnResult) then
            Result := 1;
      except
          DoStatus('LF_P2PNAME_Async_Sequenced_Call(%s, ...) except', [p2p_name__.Text]);
      end;
      DisposeObject(tmp);
      PLF_Data(Param)^.End_Call;
    end
  else
    begin
      DoStatus('LF_P2PNAME_Async_Sequenced_Call: no connection');
    end;
end;

procedure LF_P2PNAME_Notify(p2p_name_: pansichar; Param: TDataHnd___);
var
  Cli: TC40_LF_Client;
  tmp: TMem64;
  p2p_name__: TLF_String;
begin
  if Param = nil then
    begin
      DoStatus('LF_P2PNAME_Notify(...) parameter = nil!');
      exit;
    end;
  p2p_name__ := DS(p2p_name_);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_P2PNAME_Notify: name="%s"', [p2p_name__.Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      exit;
  end;

  if Cli = nil then
      exit;
  tmp := TMem64.Create;
  PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
  PLF_Data(Param)^.Begin_Call;
  try
      Cli.Send_P2PName_Execute_Notify(p2p_name__, tmp);
  except
      DoStatus('LF_P2PNAME_Notify(%s, ...) except', [p2p_name__.Text]);
  end;
  PLF_Data(Param)^.End_Call;
  DisposeObject(tmp);
end;

procedure LF_P2PNAME_Sequenced_Notify(p2p_name_: pansichar; Param: TDataHnd___);
var
  Cli: TC40_LF_Client;
  tmp: TMem64;
  p2p_name__: TLF_String;
begin
  if Param = nil then
    begin
      DoStatus('LF_P2PNAME_Sequenced_Notify(...) parameter = nil!');
      exit;
    end;
  p2p_name__ := DS(p2p_name_);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_P2PNAME_Sequenced_Notify: name="%s"', [p2p_name__.Text]);
    end;
  try
    Find_Class_Critical.Lock;
    try
        Cli := Z.Net.C4.C40_ClientPool.FastFindClass(TC40_LF_Client) as TC40_LF_Client;
    finally
        Find_Class_Critical.UnLock;
    end;
  except
      exit;
  end;

  if Cli = nil then
      exit;
  tmp := TMem64.Create;
  PLF_Data(Param)^.Data_Param.EncryptToMem(tmp);
  PLF_Data(Param)^.Begin_Call;
  try
      Cli.Send_P2PName_Execute_Sequenced_Notify(p2p_name__, tmp);
  except
      DoStatus('LF_P2PNAME_Sequenced_Notify(%s, ...) except', [p2p_name__.Text]);
  end;
  PLF_Data(Param)^.End_Call;
  DisposeObject(tmp);
end;

function LF_CheckMainThread(): Integer;
begin
  Result := if_(Simulator_Main_Thread_Activted, 1, 0);
end;

function LF_CheckApp(appName: pansichar): Integer;
begin
  Result := if_((Find_Local_APP(DS(appName), False) <> nil) or (Find_Remote_APP(DS(appName), False) <> nil), 1, 0);
end;

function LF_CheckApi(appName, apiName: pansichar): Integer;
begin
  Result := if_((Find_Local_Api(DS(appName), DS(apiName), False) <> nil) or
      (Find_Remote_Api(DS(appName), DS(apiName), False) <> nil), 1, 0);
end;

function LF_Check_UID(UID: TP2P_UID___): Integer;
begin
  Result := if_(Find_Local_UID(UID) or (Find_Remote_UID(UID)), 1, 0);
end;

function LF_Check_UID_Api(UID: TP2P_UID___; apiName: pansichar): Integer;
var
  apiName__: TLF_String;
begin
  apiName__ := DS(apiName);
  Result := if_(
    (Find_Local_UID_App(UID, apiName__) <> nil) or
      (Find_Remote_UID_API(UID, apiName__, False) <> nil),
    1, 0);
end;

function LF_Check_P2PNAME(p2p_name_: pansichar): Integer;
var
  p2p_name__: TLF_String;
begin
  p2p_name__ := DS(p2p_name_);
  Result := if_(Find_P2PNAME(p2p_name__), 1, 0);
end;

function LF_Check_P2PNAME_Api(p2p_name_: pansichar; apiName: pansichar): Integer;
var
  p2p_name__, apiName__: TLF_String;
begin
  p2p_name__ := DS(p2p_name_);
  apiName__ := DS(apiName);
  Result := if_(Find_P2PNAME_API(p2p_name__, apiName__), 1, 0);
end;

type
  TSetOpt_Inst = class
  public
    opt, V: TLF_String;
    procedure DoRun();
  end;

procedure TSetOpt_Inst.DoRun();
var
  tmp: TLF_String;
  L: Integer;
  i: Integer;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_SetOption: opt="%s" val="%s"', [opt.Text, V.Text]);
    end;

  if opt.Same('debug', 'debug_cmd', 'debug_command', 'debugcommand') then
    begin
      tmp := V;
      if Simulator_Main_Thread_Activted then
        begin
          DoStatus('execute %s', [tmp.Text]);
          try
            with TC40_Console_Help.Create do
              begin
                Run_HelpCmd(V.Text);
                Free;
              end;
          except
          end;
        end;
    end
  else if opt.Same('LF_P2P_name', 'P2P_name', 'LF_P2P', 'P2P') then
    begin
      LF_P2P_name.V := V;
      DoStatus('Update LF_P2P_name = %s', [V.Text]);
    end
  else if opt.Same('password', 'passwd') then
    begin
      Z.Net.C4.C40_Password := V;
      tmp := '';
      for i := 0 to V.L - 1 do
          tmp.Append(if_(TMT19937.Rand32 mod 2 = 0, '*', '**'));
      DoStatus('Update Password = %s', [tmp.Text]);
    end
  else if opt.Same('Quiet') then
    begin
      C40SetQuietMode(EStrToBool(V.Text));
      DoStatus('Quiet = %s', [umlBoolToStr(EStrToBool(V.Text)).Text]);
    end
  else if opt.Same('Overlap_Connection', 'Overlap_Client', 'OverlapConnection', 'OverlapClient', 'OverlapConnect') then
    begin
      Overlap_Connection := EStrToBool(V.Text);
      DoStatus('Overlap Connection = %s', [umlBoolToStr(Overlap_Connection).Text]);
    end
  else if opt.Same('Wait_Connection_ReadyOk', 'Wait_API_Prepare_Done', 'API_Prepare_Done_Wait', 'WaitConnect', 'Wait_Ready', 'WaitReady') then
    begin
      Wait_Connection_ReadyOk := EStrToBool(V.Text);
      DoStatus('Wait Connection ReadyOk = %s', [umlBoolToStr(Wait_Connection_ReadyOk).Text]);
    end
  else if opt.Same('Wait_Connection_Timeout', 'Wait_TimeOut', 'API_Prepare_Done_TimeOut', 'WaitTimeOut') then
    begin
      Wait_Connection_Timeout := EStrToUInt64(V.Text);
      DoStatus('Wait Connection TimeOut = %s', [umlTimeTickToStr(Wait_Connection_Timeout).Text]);
    end
  else if opt.Same('ShowThreadID', 'ShowThread', 'Show_Thread') then
    begin
      Z.status.StatusThreadID := EStrToBool(V.Text);
      DoStatus('Status Thread ID = %s', [umlBoolToStr(Z.status.StatusThreadID).Text]);
    end
  else if opt.Same('ConsoleOutput', 'Console_Output') then
    begin
      Z.status.ConsoleOutput := EStrToBool(V.Text);
      DoStatus('Console Output = %s', [umlBoolToStr(Z.status.ConsoleOutput).Text]);
    end
  else if opt.Same('IPC_Serv_ThreadCount', 'IPC_ThreadCount', 'IPC_Server_ThreadCount') then
    begin
      TZNet_Server_IPC.IPC_Serv_ThreadCount := EStrToInt(V.Text);
      DoStatus('Interprocess Communication Server Thread Count = %s', [umlIntToStr(TZNet_Server_IPC.IPC_Serv_ThreadCount).Text]);
    end
  else if opt.Same('IPC_Serv_MaxQueueLength', 'IPC_MaxQueueLength', 'IPC_Server_MaxQueueLength') then
    begin
      TZNet_Server_IPC.IPC_Serv_MaxQueueLength := EStrToInt(V.Text);
      DoStatus('Interprocess Communication Server Max Queue Length = %s', [umlIntToStr(TZNet_Server_IPC.IPC_Serv_MaxQueueLength).Text]);
    end
  else if opt.Same('IPC_Serv_MaxMsgSize', 'IPC_MaxMsgSize', 'IPC_Server_MaxMsgSize') then
    begin
      TZNet_Server_IPC.IPC_Serv_MaxMsgSize := EStrToInt(V.Text);
      DoStatus('Interprocess Communication Server Max Msg Size = %s', [umlIntToStr(TZNet_Server_IPC.IPC_Serv_MaxMsgSize).Text]);
    end
  else if opt.Same('Fixed_Sequenced_Time', 'Fixed_Sequenced_Life') then
    begin
      Fixed_Sequenced_Time := EStrToUInt64(V.Text);
      DoStatus('Fixed_Sequenced_Time = %s', [V.Text]);
    end
  else if opt.Same('DataHandle_Idle_Timeout', 'Data_Idle_Timeout', 'Idle_Timeout') then
    begin
      LF_DataPool.LF_DataHandle_Idle_Timeout := EStrToUInt64(V.Text);
      if LF_DataPool.LF_DataHandle_Idle_Timeout > 0 then
          DoStatus('Data handle idle timeout = %s ms', [umlIntToStr(LF_DataPool.LF_DataHandle_Idle_Timeout).Text])
      else
          DoStatus('Data handle idle timeout = disabled (idle reclamation off)');
    end
  else if opt.Same('DataHandle_Pool_Scan_Interval', 'Data_Scan_Interval', 'DataHandle_Scan_Interval') then
    begin
      LF_DataPool.LF_DataHandle_Pool_Scan_Interval := EStrToUInt64(V.Text);
      if LF_DataPool.LF_DataHandle_Pool_Scan_Interval > 0 then
          DoStatus('Data handle pool scan interval = %s ms', [umlIntToStr(LF_DataPool.LF_DataHandle_Pool_Scan_Interval).Text])
      else
          DoStatus('Data handle pool scan interval = disabled (scan on every Progress call)');
    end
  else if opt.Same('No_Reponse_Cmd_NULL_Flush_Threshold') then
    begin
      No_Reponse_Cmd_NULL_Flush_Threshold := EStrToInt(V.Text);
      DoStatus('No_Reponse_Cmd_NULL_Flush_Threshold = %d', [No_Reponse_Cmd_NULL_Flush_Threshold]);
    end;

  if Simulator_Main_Thread_Activted then DelayFreeObj(1.0, Self);
end;

procedure LF_SetOption(Option, Value: pansichar);
begin
  with TSetOpt_Inst.Create do
    begin
      opt := DS(Option);
      V := DS(Value);
      if Simulator_Main_Thread_Activted then
        begin
          MainThreadPost.PostM_NP(DoRun);
        end
      else
        begin
          DoRun();
          Free;
        end;
    end;
end;

function LF_GetOption(Option: pansichar): pansichar;
var
  opt, tmp: TLF_String;
begin
  opt := DS(Option);
  tmp := '';

  if opt.Same('debug', 'debug_cmd', 'debug_command', 'debugcommand') then
      tmp.Text := '(no value: debug is write-only)'
  else if opt.Same('LF_P2P_name', 'P2P_name', 'LF_P2P', 'P2P') then
      tmp.Text := LF_P2P_name.V
  else if opt.Same('password', 'passwd') then
      tmp.Text := '********'
  else if opt.Same('Quiet') then
      tmp.Text := umlBoolToStr(C40_QuietMode)
  else if opt.Same('Overlap_Connection', 'Overlap_Client', 'OverlapConnection', 'OverlapClient', 'OverlapConnect') then
      tmp.Text := umlBoolToStr(Overlap_Connection)
  else if opt.Same('Wait_Connection_ReadyOk', 'Wait_API_Prepare_Done', 'API_Prepare_Done_Wait', 'WaitConnect', 'Wait_Ready', 'WaitReady') then
      tmp.Text := umlBoolToStr(Wait_Connection_ReadyOk)
  else if opt.Same('Wait_Connection_Timeout', 'Wait_TimeOut', 'API_Prepare_Done_TimeOut', 'WaitTimeOut') then
      tmp.Text := umlIntToStr(Wait_Connection_Timeout)
  else if opt.Same('ShowThreadID', 'ShowThread', 'Show_Thread') then
      tmp.Text := umlBoolToStr(Z.status.StatusThreadID)
  else if opt.Same('ConsoleOutput', 'Console_Output') then
      tmp.Text := umlBoolToStr(Z.status.ConsoleOutput)
  else if opt.Same('IPC_Serv_ThreadCount', 'IPC_ThreadCount', 'IPC_Server_ThreadCount') then
      tmp.Text := umlIntToStr(TZNet_Server_IPC.IPC_Serv_ThreadCount)
  else if opt.Same('IPC_Serv_MaxQueueLength', 'IPC_MaxQueueLength', 'IPC_Server_MaxQueueLength') then
      tmp.Text := umlIntToStr(TZNet_Server_IPC.IPC_Serv_MaxQueueLength)
  else if opt.Same('IPC_Serv_MaxMsgSize', 'IPC_MaxMsgSize', 'IPC_Server_MaxMsgSize') then
      tmp.Text := umlIntToStr(TZNet_Server_IPC.IPC_Serv_MaxMsgSize)
  else if opt.Same('Fixed_Sequenced_Time', 'Fixed_Sequenced_Life') then
      tmp.Text := umlIntToStr(Fixed_Sequenced_Time)
  else if opt.Same('DataHandle_Idle_Timeout', 'Data_Idle_Timeout', 'Idle_Timeout') then
      tmp.Text := umlIntToStr(LF_DataPool.LF_DataHandle_Idle_Timeout)
  else if opt.Same('DataHandle_Pool_Scan_Interval', 'Data_Scan_Interval', 'DataHandle_Scan_Interval') then
      tmp.Text := umlIntToStr(LF_DataPool.LF_DataHandle_Pool_Scan_Interval)
  else if opt.Same('No_Reponse_Cmd_NULL_Flush_Threshold') then
      tmp.Text := umlIntToStr(No_Reponse_Cmd_NULL_Flush_Threshold);

  Result := tmp.BuildUTF8AnsiChar();
  if Result <> nil then
      Z.Notify.DelayFreeMem(5.0, Result);

  opt := '';
  tmp := '';
end;

type
  TStatus_Buffer = class(TOrderStruct<TBytes>)
  public
    procedure DoFree(var Data: TBytes); override;
  end;

var
  Status_Pool: TStatus_Buffer = nil;
  Status_Lock: TCritical = nil;
  Status_Return_Buffer: array [0 .. $FFFF] of Byte;

procedure TStatus_Buffer.DoFree(var Data: TBytes);
begin
  SetLength(Data, 0);
  inherited DoFree(Data);
end;

procedure Backcall_DoStatus(Text_: SystemString; const ID: Integer);
begin
  Status_Lock.Lock;
  try
    while Status_Pool.Num > 1000 do
        Status_Pool.Next;
    Status_Pool.Push(TPascalString(Text_).UTF8);
  finally
      Status_Lock.UnLock;
  end;
end;

function LF_GetStatusCount(): Integer;
begin
  Status_Lock.Lock;
  try
      Result := Status_Pool.Num;
  finally
      Status_Lock.UnLock;
  end;
end;

function LF_GetStatus(): pansichar;
var
  L: Integer;
begin
  Result := @Status_Return_Buffer;
  Status_Lock.Lock;
  Status_Return_Buffer[0] := 0;
  Status_Return_Buffer[1] := 0;
  try
    if Status_Pool.Num > 0 then
      begin
        L := length(Status_Pool.First^.Data);
        if L > 0 then
          begin
            CopyPtr(@Status_Pool.First^.Data[0], @Status_Return_Buffer, Min(L, SizeOf(Status_Return_Buffer) - 1));
            Status_Return_Buffer[Min(L, SizeOf(Status_Return_Buffer) - 1)] := 0;
          end;
        Status_Pool.Next;
      end;
  finally
      Status_Lock.UnLock;
  end;
end;

procedure LF_PostStatus(status: pansichar);
var
  s: TLF_String;
begin
  if not Simulator_Main_Thread_Activted then
    begin
      DoStatus('LF_PostStatus: Main thread not running; message queued directly. message: %s', [DS(status).Text]);
    end;
  s := DS(status);
  Status_Lock.Lock;
  try
      Post_To_DoStatus_Queue(TCompute.CurrentThread, s.Text, 0);
  finally
      Status_Lock.UnLock;
  end;
  s := '';
end;

procedure LF_Shutdown;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Shutdown: begin');
    end;
  On_Network_Connect_Event := nil;
  On_Network_Disconnect_Event := nil;

  LF_ExitMainThread();

  try
    LF_Call_Sequence_Thread_Pool.Stop;
    LF_Notify_Sequence_Thread_Pool.Stop;
    LF_App_Pool.Clear;
    LF_DataPool.Free_All_Hnd();
  except
  end;
  UnloadIPCLibrary();
  if IsLibrary then
      Close_Core_Dispatch_Thread();
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('LF_Shutdown: done');
    end;
end;

initialization

On_Network_Connect_Event := nil;
On_Network_Disconnect_Event := nil;

Generate_AppName_Call_Num := 0;
Generate_AppName_Critical := TCritical.Create;
Prepare_Commands := TPascalStringList.Create;
Tag_Seed := 1;
AppHnd_Bind_Tag_List := TAppHnd_Bind_Tag_List.Create;

Init_In_Progress := True;
Init_Succeeded := False;
Simulated_Main_Thread_Running := False;

C40_Tunnel_Bridge := TC40_Tunnel_Bridge.Create;
On_C40_PhysicsTunnel_Event_Console := C40_Tunnel_Bridge;
C40_Service_Bridge := TC40_Service_Bridge.Create;
On_C40_PhysicsService_Event_Console := C40_Service_Bridge;

Overlap_Connection := False;
Wait_Connection_ReadyOk := True;
Wait_Connection_Timeout := 30 * 1000;

if IsLibrary then
  begin
    Z.status.StatusThreadID := False;
    Z.status.ConsoleOutput := True;
    Z.Net.C4.C40SetQuietMode(True);
  end;

C40_EnablePerServiceDirectory := False;

Find_Class_Critical := TCritical.Create('Find_Class_Critical');

Status_Pool := TStatus_Buffer.Create;
Status_Lock := TCritical.Create('Status_Lock');
AddDoStatusHookC(Status_Pool, Backcall_DoStatus);

finalization

On_C40_PhysicsTunnel_Event_Console := nil;
On_C40_PhysicsService_Event_Console := nil;

DisposeObjectAndNil(Prepare_Commands);
DisposeObjectAndNil(AppHnd_Bind_Tag_List);
DisposeObjectAndNil(C40_Tunnel_Bridge);
DisposeObjectAndNil(C40_Service_Bridge);
DisposeObjectAndNil(Find_Class_Critical);

RemoveDoStatusHook(Status_Pool);
DisposeObjectAndNil(Status_Pool);
DisposeObjectAndNil(Status_Lock);

DisposeObjectAndNil(Generate_AppName_Critical);

end.
