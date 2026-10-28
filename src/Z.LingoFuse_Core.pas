unit Z.LingoFuse_Core;

{$DEFINE FPC_DELPHI_MODE}
{$I ..\pascal\zNetV2\source\Z.Define.inc}

interface

uses
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status, Z.UnicodeMixedLib,
  Z.HashList.Templet, Z.MemoryStream, Z.Parsing, Z.Notify, Z.ListEngine,
  Z.Cipher, Z.Int128, Z.Net,
  Z.LingoFuse_Export;

type
  TLF_App = class;

  TLF_String = TUPascalString;
  TLF_AtomString = TAtomVar<TLF_String>;

  TLF_Mode = (
    LF_Unknow__ = 0,
    LF_Call__ = 1,
    LF_Notify__ = 2
    );

  TMemory_Param_Tool = class
  private
    tmp: TMem64;
  public
    FromUID: TUID___;
    FromP2PName: TLF_String;
    apiName: TLF_String;
    Param: TMem64;
    constructor Create;
    destructor Destroy; override;
    procedure EncryptToMem(m64: TMem64);
    procedure DecryptFromMem(m64: TMem64);

    class function Get_apiName(m64: TMem64): TLF_String; static;
    class function Rebuild_UID_and_P2PName(m64: TMem64; UID_: TUID___; P2PName_: TLF_String): TMem64; static;
  end;

  TLF_MethodInfo = class
  public
    Name: TLF_String;
    Desc: TLF_String;
    Mode: TLF_Mode;
    Trigger: Pointer;
    On_Call: TLF_Call_Event;
    On_Notify: TLF_Notify_Event;
    constructor Create;
    destructor Destroy; override;
  end;

  TLF_MethodPool = class(TCritical_String_Big_Hash_Pair_Pool<TLF_MethodInfo>)
  public
    APP: TLF_App;
    procedure DoFree(var Key: SystemString; var Value: TLF_MethodInfo); override;
    procedure Export_API_List(dest: TPascalStringList);
  end;

  PLF_Data = ^TLF_Data;

  TLF_DataOrder = class(TOrderStruct<PLF_Data>);

  TLF_DataMemory = class(TOrderStruct<PLF_Data>)
  public
    Critical__: TCritical;
    constructor Create;
    destructor Destroy; override;
    function Get_New_PLF_Data: PLF_Data;
    procedure Free_PLF_Data(p: PLF_Data);
    procedure Free_All_PLF_Data_Memory;
  end;

  TLF_DataPool = class(TBigList<PLF_Data>)
  private
    Last_Progress_Time__, Last_Check_Order_Time__: TTimeTick;
  public
    LF_DataHandle_Pool_Scan_Interval: TTimeTick;
    LF_DataHandle_Idle_Timeout: TTimeTick;
    constructor Create;
    destructor Destroy; override;
    procedure Progress;
    procedure Free_All_Hnd;
  end;

  TLF_Data = record
  private
    auto_recycle___: boolean;
    deleted___: boolean;
    updated___: boolean;
    calling___: TAtomInt;
    time___: TTimeTick;
    class procedure Free_Data___(hnd: PLF_Data); static;
  public
    Data_Param: TMemory_Param_Tool;
    Data_Result: TMem64;
    Data_Info: TLF_String;
    procedure Init;
    class function New_Param(apiName: TLF_String; auto_recycle____: boolean): PLF_Data; static;
    class function New_Param_From(Data_: TMem64; auto_recycle____: boolean): PLF_Data; static;
    class function New_Result(auto_recycle____: boolean): PLF_Data; static;
    class function New_Result_From(Data_: TMem64; auto_recycle____: boolean): PLF_Data; static;
    class procedure Free_Data(hnd: PLF_Data); static;
    procedure Begin_Call;
    procedure End_Call;
    function GetBuffer: Pointer;
    function WriteBuff(Buff: Pointer; Size: Int64): Int64;
    function ReadBuff(Buff: Pointer; Size: Int64): Int64;
    function Get_Pos: Int64;
    procedure Set_Pos(Pos_: Int64);
    function Get_Size: Int64;
    procedure Set_Size(Size_: Int64);
    function Get_P2P_UID(): TUID___;
    function Get_P2P_Name(): TLF_String;
  end;

  TLF_Engine = class
  public
    LF_MethodPool: TLF_MethodPool;
    APP: TLF_App;
    constructor Create;
    destructor Destroy; override;
    function Reg_Call(MethodName, Desc: TLF_String; Trigger: Pointer; On_Call: TLF_Call_Event): boolean;
    function Reg_Notify(MethodName, Desc: TLF_String; Trigger: Pointer; On_Notify: TLF_Notify_Event): boolean;
    function UnReg(MethodName: TLF_String): boolean;
    function Execute_Call(Memory_Param: TMem64): TMem64;
    procedure Execute_Notify(Memory_Param: TMem64);
  end;

  TOn_LFUpdate = procedure(Sender: TLF_App) of object;

  TLF_UpdateEventPool = class(TCritical_Big_Hash_Pair_Pool<TCore_Object, TOn_LFUpdate>)
  end;

  TLF_App = class
  private
    FUpdateEventPool: TLF_UpdateEventPool;
    FUpdated: boolean;
    procedure Do_LFRegEvent;
    procedure DoTimer();
  public
    Name: TLF_String;
    Desc: TLF_String;
    Engine: TLF_Engine;
    constructor Create(Owner_Pool_: boolean);
    destructor Destroy; override;
    procedure FakeFree;
    procedure DoChange();
    procedure Subscribe_Update(Bind: TCore_Object; OnUpdate: TOn_LFUpdate);
    procedure Remove_Update(Bind: TCore_Object);
  end;

  TLF_App_Pool = class(TBigList<TLF_App>)
  public
    procedure DoFree(var Data: TLF_App); override;
  end;

  TLF_Call_Sequence_Thread = class;

  TOn_Sequence_Call_Event = procedure(Result_: TMem64) of object;

  TLF_Call_Sequence_Thread_Pool = class(TBig_Hash_Pair_Pool<TLF_String, TLF_Call_Sequence_Thread>)
  public
    constructor Create;
    function Get_Key_Hash(const Key_: TLF_String): THash; override;
    function Compare_Key(const Key_1, Key_2: TLF_String): boolean; override;
    procedure DoFree(var Key: TLF_String; var Value: TLF_Call_Sequence_Thread); override;
    procedure Post_Call(Name_: TLF_String; const APP: TLF_App; Memory_Param: TMem64; OnResult: TOn_Sequence_Call_Event);
    procedure Post_Call2(const APP: TLF_App; Memory_Param: TMem64; OnResult: TOn_Sequence_Call_Event);
    procedure Kill_App(const APP: TLF_App);
    procedure Stop;
  end;

  TCall_Queue_Data = record
    APP: TLF_App;
    Param_: TMem64;
    OnResult: TOn_Sequence_Call_Event;
    procedure Init;
  end;

  TCall_Queue_Tool = class(TOrderStruct<TCall_Queue_Data>)
  public
    procedure DoFree(var Data: TCall_Queue_Data); override;
  end;

  TLF_Call_Sequence_Thread = class
  private
    Critical: TCritical;
    Internal_Queue_Pool___: TLF_Call_Sequence_Thread_Pool;
    Internal_Queue_Data___: TLF_Call_Sequence_Thread_Pool.PPair_Pool_Value__;
    Activted: boolean;
    IsRunning, IsExit: boolean;
    procedure Do_Run_Th();
  public
    Queue_Tool: TCall_Queue_Tool;
    APP: TLF_App;
    constructor Create;
    destructor Destroy; override;
    procedure Run;
    procedure Stop;
  end;

  TLF_Notify_Sequence_Thread = class;

  TLF_Notify_Sequence_Thread_Pool = class(TBig_Hash_Pair_Pool<TLF_String, TLF_Notify_Sequence_Thread>)
  public
    constructor Create;
    function Get_Key_Hash(const Key_: TLF_String): THash; override;
    function Compare_Key(const Key_1, Key_2: TLF_String): boolean; override;
    procedure DoFree(var Key: TLF_String; var Value: TLF_Notify_Sequence_Thread); override;
    procedure Post_Notify(Name_: TLF_String; const APP: TLF_App; Memory_Param: TMem64);
    procedure Post_Notify2(const APP: TLF_App; Memory_Param: TMem64);
    procedure Kill_App(const APP: TLF_App);
    procedure Stop;
  end;

  TNotify_Queue_Data = TPair2<TLF_App, TMem64>;

  TNotify_Queue_Tool = class(TOrderStruct<TNotify_Queue_Data>)
  public
    procedure DoFree(var Data: TNotify_Queue_Data); override;
  end;

  TLF_Notify_Sequence_Thread = class
  private
    Critical: TCritical;
    Internal_Queue_Pool___: TLF_Notify_Sequence_Thread_Pool;
    Internal_Queue_Data___: TLF_Notify_Sequence_Thread_Pool.PPair_Pool_Value__;
    Activted: boolean;
    IsRunning, IsExit: boolean;
    procedure Do_Run_Th();
  public
    Queue_Tool: TNotify_Queue_Tool;
    APP: TLF_App;
    constructor Create;
    destructor Destroy; override;
    procedure Run;
    procedure Stop;
  end;

function Find_API_From_P2P_APP(api_name__: SystemString): TLF_App;

var
  LF_P2P_APP: TLF_App;
  LF_App_Pool: TLF_App_Pool;
  LF_DataPool: TLF_DataPool;
  LF_DataMemory: TLF_DataMemory;
  LF_RunningCount: TAtomInt;
  LF_Call_Sequence_Thread_Pool: TLF_Call_Sequence_Thread_Pool;
  LF_Notify_Sequence_Thread_Pool: TLF_Notify_Sequence_Thread_Pool;

implementation

function Find_API_From_P2P_APP(api_name__: SystemString): TLF_App;
begin
  Result := nil;
  if LF_P2P_APP.Engine.LF_MethodPool.Exists_Key(api_name__) then
    begin
      Result := LF_P2P_APP;
      exit;
    end;
  LF_App_Pool.Lock;
  try
    if LF_App_Pool.Num > 0 then
      with LF_App_Pool.Invert_Repeat_ do
        repeat
          if queue^.Data.Engine.LF_MethodPool.Exists_Key(api_name__) then
            begin
              Result := queue^.Data;
              exit;
            end;
        until not Prev;
  finally
      LF_App_Pool.UnLock;
  end;
end;

constructor TMemory_Param_Tool.Create;
begin
  inherited Create;
  tmp := TMem64.Create;
  FromUID := Null_UID();
  FromP2PName := '';
  apiName := '';
  Param := TMem64.Create;
end;

destructor TMemory_Param_Tool.Destroy;
begin
  FromP2PName := '';
  apiName := '';
  DisposeObject(Param);
  DisposeObject(tmp);
  inherited Destroy;
end;

procedure TMemory_Param_Tool.EncryptToMem(m64: TMem64);
begin
  m64.Clear;
  m64.WriteString(apiName.Text);
  m64.WritePtr(@FromUID[0], SizeOf(TUID___));
  m64.WriteString(FromP2PName.Text);
  m64.WriteInt32(Param.Size);
  m64.WritePtr(Param.Memory, Param.Size);
end;

procedure TMemory_Param_Tool.DecryptFromMem(m64: TMem64);
var
  i32: Integer;
begin
  if m64.ProtectedMode then
    begin
      m64.Position := 0;
      apiName.Text := m64.ReadString.Text;
      m64.ReadPtr(@FromUID[0], SizeOf(TUID___));
      FromP2PName.Text := m64.ReadString.Text;
      Param.Size := m64.ReadInt32;
      m64.ReadPtr(Param.Memory, Param.Size);
      Param.Position := 0;
    end
  else
    begin
      tmp.SwapInstance(m64);
      tmp.Position := 0;
      apiName.Text := tmp.ReadString.Text;
      tmp.ReadPtr(@FromUID[0], SizeOf(TUID___));
      FromP2PName.Text := tmp.ReadString.Text;
      i32 := tmp.ReadInt32;
      Param.Mapping(tmp.PosAsPtr, i32);
      Param.Position := 0;
    end;
end;

class function TMemory_Param_Tool.Get_apiName(m64: TMem64): TLF_String;
var
  bak_: Int64;
begin
  bak_ := m64.Position;
  m64.Position := 0;
  Result := m64.ReadString;
  m64.Position := bak_;
end;

class function TMemory_Param_Tool.Rebuild_UID_and_P2PName(m64: TMem64; UID_: TUID___; P2PName_: TLF_String): TMem64;
var
  tmp: TMemory_Param_Tool;
begin
  tmp := TMemory_Param_Tool.Create;
  tmp.DecryptFromMem(m64);
  tmp.FromUID := UID_;
  tmp.FromP2PName := P2PName_;
  Result := TMem64.Create;
  tmp.EncryptToMem(Result);
  DisposeObject(tmp);
end;

constructor TLF_MethodInfo.Create;
begin
  inherited Create;
  Name := '';
  Desc := '';
  Mode := TLF_Mode.LF_Unknow__;
  Trigger := nil;
  On_Call := nil;
  On_Notify := nil;
end;

destructor TLF_MethodInfo.Destroy;
begin
  inherited Destroy;
end;

procedure TLF_MethodPool.DoFree(var Key: SystemString; var Value: TLF_MethodInfo);
begin
  DisposeObjectAndNil(Value);
  inherited;
end;

procedure TLF_MethodPool.Export_API_List(dest: TPascalStringList);
begin
  if Num > 0 then
    with repeat_ do
      repeat
          dest.Add(queue^.Data^.Data.Primary);
      until not Next;
end;

constructor TLF_DataMemory.Create;
begin
  inherited Create;
  Critical__ := TCritical.Create('TLF_DataMemory.Critical__');
end;

destructor TLF_DataMemory.Destroy;
begin
  Free_All_PLF_Data_Memory();
  DisposeObject(Critical__);
  inherited Destroy;
end;

function TLF_DataMemory.Get_New_PLF_Data: PLF_Data;
begin
  Critical__.Lock;
  try
    if Num > 0 then
      begin
        Result := First^.Data; Next;
      end
    else New(Result);
  finally
      Critical__.UnLock;
  end;
end;

procedure TLF_DataMemory.Free_PLF_Data(p: PLF_Data);
begin
  if p = nil then exit;
  Critical__.Lock;
  try
      Push(p);
  finally
      Critical__.UnLock;
  end;
end;

procedure TLF_DataMemory.Free_All_PLF_Data_Memory;
begin
  Critical__.Lock;
  try
    while Num > 0 do
      begin
        try
            Dispose(First^.Data);
        except
        end;
        Next;
      end;
  finally
      Critical__.UnLock;
  end;
end;

constructor TLF_DataPool.Create;
begin
  inherited Create;
  Last_Progress_Time__ := GetTimeTick();
  LF_DataHandle_Pool_Scan_Interval := Z.Core.C_Tick_Second * 5;
  LF_DataHandle_Idle_Timeout := Z.Core.C_Tick_Second * 60 * 10;
end;

destructor TLF_DataPool.Destroy;
begin
  Free_All_Hnd();
  inherited Destroy;
end;

procedure TLF_DataPool.Progress;
var
  tk: TTimeTick;
  timeout_data, L: TLF_DataOrder;
begin
  tk := GetTimeTick();
  if GetTimeTickDiff(tk, Last_Progress_Time__) < LF_DataHandle_Pool_Scan_Interval then exit;
  Last_Progress_Time__ := tk;
  timeout_data := TLF_DataOrder.Create;
  L := TLF_DataOrder.Create;
  Lock;
  try
    if Num > 0 then
      begin
        with repeat_ do
          repeat
            if queue^.Data^.updated___ or (queue^.Data^.calling___.V > 0) then
              begin
                queue^.Data^.time___ := tk;
                queue^.Data^.updated___ := False;
              end
            else if (queue^.Data^.deleted___) then
              begin
                L.Push(queue^.Data);
                Push_To_Recycle_Pool(queue);
              end
            else if (LF_DataHandle_Idle_Timeout > 0) and (tk - queue^.Data^.time___ > LF_DataHandle_Idle_Timeout) then
              begin
                timeout_data.Push(queue^.Data);
                Push_To_Recycle_Pool(queue);
              end;
          until not Next;
      end;
    Free_Recycle_Pool;
  finally
      UnLock;
  end;
  while L.Num > 0 do
    begin
      TLF_Data.Free_Data___(L.First^.Data);
      L.Next;
    end;
  DisposeObject(L);
  if timeout_data.Num > 0 then
    begin
      DoStatus('hint: Data handle pool "%d" handles were idle for more than 10 minutes and have been automatically freed.', [timeout_data.Num]);
      if timeout_data.Num > 5 then
          DoStatus('...');
      repeat
        if timeout_data.Num < 3 then
            DoStatus('hint: automatically free handles ' + timeout_data.First^.Data^.Data_Info.Text);
        TLF_Data.Free_Data___(timeout_data.First^.Data);
        timeout_data.Next;
      until timeout_data.Num <= 0;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('DataPool.Progress: live=%d timeout_freed=%d', [Num, timeout_data.Num]);
    end;
  DisposeObject(timeout_data);
end;

procedure TLF_DataPool.Free_All_Hnd;
begin
  Lock;
  try
    if Num > 0 then
      begin
        DoStatus('hint: Data handle pool "%d" handles automatically freed.', [Num]);
        if Num > 5 then
            DoStatus('...');
        with repeat_ do
          repeat
            if queue^.Data.calling___.V <= 0 then
              begin
                if Num - I__ < 3 then
                    DoStatus('hint: automatically free handles ' + queue^.Data^.Data_Info.Text);
                TLF_Data.Free_Data___(queue^.Data);
              end;
          until not Next;
      end;
    Clear;
  finally
      UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('DataPool.Free_All_Hnd done');
    end;
end;

class procedure TLF_Data.Free_Data___(hnd: PLF_Data);
begin
  if hnd = nil then exit;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Data.Free_Data___: hnd=%p info="%s"', [hnd, hnd^.Data_Info.Text]);
    end;
  hnd^.Data_Info := '';
  DisposeObjectAndNil(hnd^.Data_Param);
  DisposeObjectAndNil(hnd^.Data_Result);
  DisposeObjectAndNil(hnd^.calling___);
  LF_DataMemory.Free_PLF_Data(hnd);
end;

procedure TLF_Data.Init;
begin
  auto_recycle___ := True;
  deleted___ := False;
  updated___ := True;
  calling___ := TAtomInt.Create(0);
  time___ := 0;
  Data_Param := nil;
  Data_Result := nil;
  Data_Info := '';
end;

class function TLF_Data.New_Param(apiName: TLF_String; auto_recycle____: boolean): PLF_Data;
var
  p: PLF_Data;
begin
  p := LF_DataMemory.Get_New_PLF_Data;
  p^.Init;
  p^.Data_Param := TMemory_Param_Tool.Create;
  p^.Data_Param.apiName := apiName;
  p^.Data_Info := PFormat('api "%s" parameter.', [apiName.Text]);
  p^.auto_recycle___ := auto_recycle____;
  if auto_recycle____ then
    begin
      LF_DataPool.Lock;
      try
          LF_DataPool.Add(p);
      finally
          LF_DataPool.UnLock;
      end;
    end;
  Result := p;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Data.New_Param: api="%s" auto=%s hnd=%p', [apiName.Text, if_(auto_recycle____, 'yes', 'no'), Result]);
    end;
end;

class function TLF_Data.New_Param_From(Data_: TMem64; auto_recycle____: boolean): PLF_Data;
var
  p: PLF_Data;
begin
  p := LF_DataMemory.Get_New_PLF_Data;
  p^.Init;
  p^.Data_Param := TMemory_Param_Tool.Create;
  p^.Data_Param.DecryptFromMem(Data_);
  p^.auto_recycle___ := auto_recycle____;
  if auto_recycle____ then
    begin
      LF_DataPool.Lock;
      try
          LF_DataPool.Add(p);
      finally
          LF_DataPool.UnLock;
      end;
    end;
  Result := p;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Data.New_Param_From: api="%s" auto=%s hnd=%p', [p^.Data_Param.apiName.Text, if_(auto_recycle____, 'yes', 'no'), Result]);
    end;
end;

class function TLF_Data.New_Result(auto_recycle____: boolean): PLF_Data;
var
  p: PLF_Data;
begin
  p := LF_DataMemory.Get_New_PLF_Data;
  p^.Init;
  p^.Data_Result := TMem64.Create;
  p^.auto_recycle___ := auto_recycle____;
  if auto_recycle____ then
    begin
      LF_DataPool.Lock;
      try
          LF_DataPool.Add(p);
      finally
          LF_DataPool.UnLock;
      end;
    end;
  Result := p;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Data.New_Result: auto=%s hnd=%p', [if_(auto_recycle____, 'yes', 'no'), Result]);
    end;
end;

class function TLF_Data.New_Result_From(Data_: TMem64; auto_recycle____: boolean): PLF_Data;
var
  p: PLF_Data;
begin
  p := LF_DataMemory.Get_New_PLF_Data;
  p^.Init;
  p^.Data_Result := Data_;
  p^.Data_Result.Position := 0;
  p^.auto_recycle___ := auto_recycle____;
  if auto_recycle____ then
    begin
      LF_DataPool.Lock;
      try
          LF_DataPool.Add(p);
      finally
          LF_DataPool.UnLock;
      end;
    end;
  Result := p;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Data.New_Result_From: size=%d auto=%s hnd=%p', [Data_.Size, if_(auto_recycle____, 'yes', 'no'), Result]);
    end;
end;

class procedure TLF_Data.Free_Data(hnd: PLF_Data);
begin
  if hnd = nil then exit;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_Data.Free_Data: hnd=%p auto=%s', [hnd, if_(hnd^.auto_recycle___, 'yes', 'no')]);
    end;
  if hnd^.auto_recycle___ then
      hnd^.deleted___ := True
  else TLF_Data.Free_Data___(hnd);
end;

procedure TLF_Data.Begin_Call;
begin
  calling___.UnLock(calling___.LockP^ + 1);
  updated___ := True;
end;

procedure TLF_Data.End_Call;
begin
  calling___.UnLock(calling___.LockP^ - 1);
  updated___ := True;
end;

function TLF_Data.GetBuffer: Pointer;
begin
  Result := nil;
  if Data_Param <> nil then
      Result := Data_Param.Param.Memory
  else if Data_Result <> nil then
      Result := Data_Result.Memory;
  updated___ := True;
end;

function TLF_Data.WriteBuff(Buff: Pointer; Size: Int64): Int64;
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.WritePtr(Buff, Size)
  else if Data_Result <> nil then
      Result := Data_Result.WritePtr(Buff, Size);
  updated___ := True;
end;

function TLF_Data.ReadBuff(Buff: Pointer; Size: Int64): Int64;
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.ReadPtr(Buff, Size)
  else if Data_Result <> nil then
      Result := Data_Result.ReadPtr(Buff, Size);
  updated___ := True;
end;

function TLF_Data.Get_Pos: Int64;
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.Position
  else if Data_Result <> nil then
      Result := Data_Result.Position;
  updated___ := True;
end;

procedure TLF_Data.Set_Pos(Pos_: Int64);
begin
  if Data_Param <> nil then
      Data_Param.Param.Position := Pos_
  else if Data_Result <> nil then
      Data_Result.Position := Pos_;
  updated___ := True;
end;

function TLF_Data.Get_Size: Int64;
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.Size
  else if Data_Result <> nil then
      Result := Data_Result.Size;
  updated___ := True;
end;

procedure TLF_Data.Set_Size(Size_: Int64);
begin
  if Data_Param <> nil then
      Data_Param.Param.Size := Size_
  else if Data_Result <> nil then
      Data_Result.Size := Size_;
  updated___ := True;
end;

function TLF_Data.Get_P2P_UID(): TUID___;
begin
  if Data_Param <> nil then
      Result := Data_Param.FromUID
  else
    begin
      DoStatus('[warning] Get_P2P_UID(): P2P Info only backcall "input" parameter.');
      Result := Null_UID();
    end;
  updated___ := True;
end;

function TLF_Data.Get_P2P_Name(): TLF_String;
begin
  if Data_Param <> nil then
      Result := Data_Param.FromP2PName
  else
    begin
      DoStatus('[warning] Get_P2P_Name(): P2P Info only backcall "input" parameter.');
      Result := '';
    end;
  updated___ := True;
end;

constructor TLF_Engine.Create;
begin
  inherited Create;
  LF_MethodPool := TLF_MethodPool.Create($FF, nil);
  LF_MethodPool.APP := nil;
end;

destructor TLF_Engine.Destroy;
begin
  DisposeObject(LF_MethodPool);
  inherited Destroy;
end;

function TLF_Engine.Reg_Call(MethodName, Desc: TLF_String; Trigger: Pointer; On_Call: TLF_Call_Event): boolean;
var
  api_: TLF_MethodInfo;
begin
  Result := False;
  if LF_MethodPool.Exists_Key(MethodName) then
      exit;
  api_ := TLF_MethodInfo.Create;
  api_.Name := MethodName;
  api_.Desc := Desc;
  api_.Mode := TLF_Mode.LF_Call__;
  api_.Trigger := Trigger;
  api_.On_Call := On_Call;
  LF_MethodPool.Add(MethodName, api_, False);
  APP.DoChange();
  Result := True;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Engine.Reg_Call: app="%s" api="%s"', [APP.Name.Text, MethodName.Text]);
    end;
end;

function TLF_Engine.Reg_Notify(MethodName, Desc: TLF_String; Trigger: Pointer; On_Notify: TLF_Notify_Event): boolean;
var
  api_: TLF_MethodInfo;
begin
  Result := False;
  if LF_MethodPool.Exists_Key(MethodName) then
      exit;
  api_ := TLF_MethodInfo.Create;
  api_.Name := MethodName;
  api_.Desc := Desc;
  api_.Mode := TLF_Mode.LF_Notify__;
  api_.Trigger := Trigger;
  api_.On_Notify := On_Notify;
  LF_MethodPool.Add(MethodName, api_, False);
  APP.DoChange();
  Result := True;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Engine.Reg_Notify: app="%s" api="%s"', [APP.Name.Text, MethodName.Text]);
    end;
end;

function TLF_Engine.UnReg(MethodName: TLF_String): boolean;
var
  api_: TLF_MethodInfo;
begin
  Result := False;
  if not LF_MethodPool.Exists_Key(MethodName) then
      exit;
  LF_MethodPool.Delete(MethodName);
  APP.DoChange();
  Result := True;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Engine.UnReg: app="%s" api="%s"', [APP.Name.Text, MethodName.Text]);
    end;
end;

function TLF_Engine.Execute_Call(Memory_Param: TMem64): TMem64;
var
  api_: TLF_MethodInfo;
  input_, output_: PLF_Data;
  bak_input_, bak_output_: TLF_Data;
begin
  LF_RunningCount.UnLock(LF_RunningCount.LockP^ + 1);
  input_ := TLF_Data.New_Param_From(Memory_Param, False);
  output_ := TLF_Data.New_Result(False);
  Result := TMem64.Create;
  try
    api_ := LF_MethodPool.Get_Default_Value(input_.Data_Param.apiName, nil);
    if LF_Debug_Log_Enabled then
      begin
        LF_Debug_Log('Engine.Execute_Call: app="%s" api="%s" found=%s', [APP.Name.Text, input_.Data_Param.apiName.Text, if_(api_ <> nil, 'yes', 'no')]);
      end;
    if api_ = nil then
      begin
        DoStatus('no found api "%s"', [input_.Data_Param.apiName.Text]);
        exit;
      end;
    bak_input_ := input_^;
    bak_output_ := output_^;
    case api_.Mode of
      LF_Call__:
        begin
          try
            if Assigned(api_.On_Call) then
              begin
                api_.On_Call(api_.Trigger, input_, output_);
                input_^ := bak_input_;
                output_^ := bak_output_;
              end;
          except
            DoStatus('execute call-mode api "%s" (stdcall) execpet!', [input_.Data_Param.apiName.Text]);
            input_^ := bak_input_;
            output_^ := bak_output_;
          end;
        end;
      LF_Notify__:
        begin
          DoStatus('Warning: API "%s" is registered as Notify but invoked as Call; no return value will be produced.', [input_.Data_Param.apiName.Text]);
          try
            if Assigned(api_.On_Notify) then
              begin
                api_.On_Notify(api_.Trigger, input_);
                input_^ := bak_input_;
              end;
          except
            DoStatus('execute notify-mode api "%s" (stdcall) execpet!', [input_.Data_Param.apiName.Text]);
            input_^ := bak_input_;
          end;
        end;
    end;
  finally
    Result.SwapInstance(output_.Data_Result);
    TLF_Data.Free_Data(input_);
    TLF_Data.Free_Data(output_);
    LF_RunningCount.UnLock(LF_RunningCount.LockP^ - 1);
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Engine.Execute_Call done: result_size=%d', [Result.Size]);
    end;
end;

procedure TLF_Engine.Execute_Notify(Memory_Param: TMem64);
var
  api_: TLF_MethodInfo;
  input_, output_: PLF_Data;
  bak_input_, bak_output_: TLF_Data;
begin
  LF_RunningCount.UnLock(LF_RunningCount.LockP^ + 1);
  input_ := TLF_Data.New_Param_From(Memory_Param, False);
  output_ := TLF_Data.New_Result(False);
  try
    api_ := LF_MethodPool.Get_Default_Value(input_.Data_Param.apiName, nil);
    if LF_Debug_Log_Enabled then
      begin
        LF_Debug_Log('Engine.Execute_Notify: app="%s" api="%s" found=%s', [APP.Name.Text, input_.Data_Param.apiName.Text, if_(api_ <> nil, 'yes', 'no')]);
      end;
    if api_ = nil then
      begin
        DoStatus('no found api "%s"', [input_.Data_Param.apiName.Text]);
        exit;
      end;
    bak_input_ := input_^;
    bak_output_ := output_^;
    case api_.Mode of
      LF_Call__:
        begin
          DoStatus('Warning: API "%s" is registered as Call but invoked via Notify; any returned value will be discarded.', [input_.Data_Param.apiName.Text]);
          try
            if Assigned(api_.On_Call) then
              begin
                api_.On_Call(api_.Trigger, input_, output_);
                input_^ := bak_input_;
                output_^ := bak_output_;
              end;
          except
            DoStatus('execute call-mode api "%s" (stdcall) execpet!', [input_.Data_Param.apiName.Text]);
            input_^ := bak_input_;
            output_^ := bak_output_;
          end;
        end;
      LF_Notify__:
        begin
          try
            if Assigned(api_.On_Notify) then
              begin
                api_.On_Notify(api_.Trigger, input_);
                input_^ := bak_input_;
              end;
          except
            DoStatus('execute notify-mode api "%s" (stdcall) execpet!', [input_.Data_Param.apiName.Text]);
            input_^ := bak_input_;
          end;
        end;
    end;
  finally
    TLF_Data.Free_Data(input_);
    TLF_Data.Free_Data(output_);
    LF_RunningCount.UnLock(LF_RunningCount.LockP^ - 1);
  end;
end;

procedure TLF_App.Do_LFRegEvent;
var
  snapshot: array of TOn_LFUpdate;
  i, n: Integer;
begin
  FUpdateEventPool.Lock;
  try
    n := FUpdateEventPool.Num;
    if n > 0 then
      begin
        SetLength(snapshot, n);
        with FUpdateEventPool.repeat_ do
          repeat
              snapshot[I__] := queue^.Data^.Data.Second;
          until not Next;
      end;
  finally
      FUpdateEventPool.UnLock;
  end;

  for i := 0 to Length(snapshot) - 1 do
    begin
      if Assigned(snapshot[i]) then
        try
            snapshot[i](self);
        except
        end;
    end;
  SetLength(snapshot, 0);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('App.Do_LFRegEvent: app="%s" notified=%d', [Name.Text, n]);
    end;
end;

procedure TLF_App.DoTimer;
begin
  if FUpdated then
    begin
      if Simulator_Main_Thread_Activted then
          MainThreadPost.PostM_NP(Do_LFRegEvent);
      FUpdated := False;
    end;
end;

constructor TLF_App.Create(Owner_Pool_: boolean);
begin
  inherited Create;
  Name := '';
  Desc := '';
  Engine := TLF_Engine.Create;
  Engine.APP := self;
  Engine.LF_MethodPool.APP := self;
  FUpdateEventPool := TLF_UpdateEventPool.Create($FF, nil);
  FUpdated := False;
  Subscribe_Timer_M(self, 1000, DoTimer);
  if Owner_Pool_ then
    begin
      LF_App_Pool.Lock;
      try
          LF_App_Pool.Add(self);
      finally
          LF_App_Pool.UnLock;
      end;
    end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_App.Create: name="%s" owner_pool=%s', [Name.Text, if_(Owner_Pool_, 'yes', 'no')]);
    end;
end;

destructor TLF_App.Destroy;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_App.Destroy: name="%s"', [Name.Text]);
    end;
  Remove_Timer(self);
  DisposeObject(Engine);
  DisposeObject(FUpdateEventPool);
  inherited Destroy;
end;

procedure TLF_App.FakeFree;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_App.FakeFree: name="%s"', [Name.Text]);
    end;
  Remove_Timer(self);
end;

procedure TLF_App.DoChange();
begin
  FUpdated := True;
  Reset_Timer(self);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('TLF_App.DoChange: name="%s"', [Name.Text]);
    end;
end;

procedure TLF_App.Subscribe_Update(Bind: TCore_Object; OnUpdate: TOn_LFUpdate);
begin
  FUpdateEventPool.Add(Bind, OnUpdate, True);
end;

procedure TLF_App.Remove_Update(Bind: TCore_Object);
begin
  FUpdateEventPool.Delete(Bind);
end;

procedure TLF_App_Pool.DoFree(var Data: TLF_App);
begin
  DisposeObjectAndNil(Data);
  inherited DoFree(Data);
end;

constructor TLF_Call_Sequence_Thread_Pool.Create;
begin
  inherited Create($FF, nil);
end;

function TLF_Call_Sequence_Thread_Pool.Get_Key_Hash(const Key_: TLF_String): THash;
begin
  Result := FastHashPPascalString(@Key_);
  Result := Get_CRC32(@Result, SizeOf(THash));
end;

function TLF_Call_Sequence_Thread_Pool.Compare_Key(const Key_1, Key_2: TLF_String): boolean;
begin
  Result := Key_1.Same(@Key_2);
end;

procedure TLF_Call_Sequence_Thread_Pool.DoFree(var Key: TLF_String; var Value: TLF_Call_Sequence_Thread);
begin
  Key := '';
  Value := nil;
  inherited;
end;

procedure TLF_Call_Sequence_Thread_Pool.Post_Call(Name_: TLF_String; const APP: TLF_App; Memory_Param: TMem64; OnResult: TOn_Sequence_Call_Event);
var
  th: TLF_Call_Sequence_Thread;
begin
  Lock;
  try
    th := Get_Default_Value(Name_, nil);
    if th = nil then
      begin
        th := TLF_Call_Sequence_Thread.Create;
        th.APP := APP;
        th.Internal_Queue_Pool___ := self;
        th.Internal_Queue_Data___ := Add(Name_, th, False);
        th.Run;
      end;
    th.Critical.Lock;
    try
      if th.APP = APP then
        begin
          with th.Queue_Tool.Push_Null^ do
            begin
              Data.Init;
              Data.APP := APP;
              Data.Param_ := Memory_Param;
              Data.OnResult := OnResult;
            end;
        end
      else DoStatus('TLF_Call_Sequence_Thread_Pool.Post_Call: application mismatch - thread for "%s" belongs to a different app instance', [Name_.Text]);
    finally
        th.Critical.UnLock;
    end;
  finally
      UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SeqCallPool.Post_Call: key="%s"', [Name_.Text]);
    end;
end;

procedure TLF_Call_Sequence_Thread_Pool.Post_Call2(const APP: TLF_App; Memory_Param: TMem64; OnResult: TOn_Sequence_Call_Event);
begin
  Post_Call(PFormat('%s.%s', [APP.Name.Text, TMemory_Param_Tool.Get_apiName(Memory_Param).Text]), APP, Memory_Param, OnResult);
end;

procedure TLF_Call_Sequence_Thread_Pool.Kill_App(const APP: TLF_App);
var
  th: TLF_Call_Sequence_Thread;
begin
  Lock;
  try
    if Num > 0 then
      begin
        with repeat_ do
          repeat
            if APP = queue^.Data^.Data.Second.APP then
              begin
                queue^.Data^.Data.Second.Critical.Lock;
                try
                  queue^.Data^.Data.Second.Internal_Queue_Pool___ := nil;
                  queue^.Data^.Data.Second.Internal_Queue_Data___ := nil;
                finally
                    queue^.Data^.Data.Second.Critical.UnLock;
                end;
                queue^.Data^.Data.Second.Stop;
                queue^.Data^.Data.Second := nil;
                Push_To_Recycle_Pool2(queue);
              end;
          until not Next;
        Free_Recycle_Pool;
      end;
  finally
      UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SeqCallPool.Kill_App: app="%s"', [APP.Name.Text]);
    end;
end;

procedure TLF_Call_Sequence_Thread_Pool.Stop;
var
  th: TLF_Call_Sequence_Thread;
begin
  Lock;
  try
    if Num > 0 then
      begin
        with repeat_ do
          repeat
            queue^.Data^.Data.Second.Critical.Lock;
            try
              queue^.Data^.Data.Second.Internal_Queue_Pool___ := nil;
              queue^.Data^.Data.Second.Internal_Queue_Data___ := nil;
            finally
                queue^.Data^.Data.Second.Critical.UnLock;
            end;
            queue^.Data^.Data.Second.Stop;
            queue^.Data^.Data.Second := nil;
          until not Next;
        Clear;
      end;
  finally
      UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SeqCallPool.Stop done');
    end;
end;

procedure TCall_Queue_Data.Init;
begin
  APP := nil;
  Param_ := nil;
  OnResult := nil;
end;

procedure TCall_Queue_Tool.DoFree(var Data: TCall_Queue_Data);
begin
  Data.APP := nil;
  DisposeObjectAndNil(Data.Param_);
  Data.OnResult := nil;
end;

procedure TLF_Call_Sequence_Thread.Do_Run_Th;
var
  app_and_api___: TLF_String;
  Result_M64: TMem64;
  tmp: TCall_Queue_Tool;
  tk: TTimeTick;
begin
  if LF_Debug_Log_Enabled then
    begin
      app_and_api___ := Internal_Queue_Data___^.Data.Primary.Text;
      LF_Debug_Log('SeqCallThread start: api="%s"', [app_and_api___.Text]);
    end;
  tmp := TCall_Queue_Tool.Create;
  tk := GetTimeTick();
  while Activted do
    begin
      Critical.Lock;
      if Queue_Tool.Num > 0 then
          tmp.SwapInstance(Queue_Tool);
      Critical.UnLock;
      if tmp.Num > 0 then
        begin
          try
            repeat
              try
                Result_M64 := tmp.First^.Data.APP.Engine.Execute_Call(tmp.First^.Data.Param_);
                if Assigned(tmp.First^.Data.OnResult) then
                    tmp.First^.Data.OnResult(Result_M64);
              except
                  Result_M64 := nil;
              end;
              DisposeObjectAndNil(Result_M64);
              DisposeObjectAndNil(tmp.First^.Data.Param_);
              tmp.Next;
            until (tmp.Num <= 0) or (not Activted);
          except
          end;
          tk := GetTimeTick();
        end
      else
        begin
          TCompute.Sleep(10);
          if GetTimeTick() - tk >= Z.Core.C_Tick_Minute * 5 then
            begin
              if LF_Debug_Log_Enabled then
                begin
                  LF_Debug_Log('SeqCallThread idle timeout: api="%s"', [app_and_api___.Text]);
                end;
              Activted := False;
            end;
        end;
    end;
  DisposeObject(tmp);
  if (Internal_Queue_Data___ <> nil) and (Internal_Queue_Pool___ <> nil) then
    begin
      Internal_Queue_Pool___.Lock;
      try
          Internal_Queue_Pool___.Remove(Internal_Queue_Data___);
      finally
          Internal_Queue_Pool___.UnLock;
      end;
    end;
  DelayFreeObj(1.0, self);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SeqCallThread exit: api="%s"', [app_and_api___.Text]);
    end;
end;

constructor TLF_Call_Sequence_Thread.Create;
begin
  inherited Create;
  Critical := TCritical.Create(ClassName + '.Critical');
  Internal_Queue_Pool___ := nil;
  Internal_Queue_Data___ := nil;
  Activted := False;
  IsRunning := False;
  IsExit := False;
  Queue_Tool := TCall_Queue_Tool.Create;
  APP := nil;
end;

destructor TLF_Call_Sequence_Thread.Destroy;
begin
  DisposeObjectAndNil(Queue_Tool);
  DisposeObjectAndNil(Critical);
  inherited Destroy;
end;

procedure TLF_Call_Sequence_Thread.Run;
begin
  if IsRunning then exit;
  Activted := True;
  TCompute.RunM_NP(Do_Run_Th, @IsRunning, @IsExit);
end;

procedure TLF_Call_Sequence_Thread.Stop;
begin
  if IsRunning then
      Activted := False;
end;

constructor TLF_Notify_Sequence_Thread_Pool.Create;
begin
  inherited Create($FF, nil);
end;

function TLF_Notify_Sequence_Thread_Pool.Get_Key_Hash(const Key_: TLF_String): THash;
begin
  Result := FastHashPPascalString(@Key_);
  Result := Get_CRC32(@Result, SizeOf(THash));
end;

function TLF_Notify_Sequence_Thread_Pool.Compare_Key(const Key_1, Key_2: TLF_String): boolean;
begin
  Result := Key_1.Same(@Key_2);
end;

procedure TLF_Notify_Sequence_Thread_Pool.DoFree(var Key: TLF_String; var Value: TLF_Notify_Sequence_Thread);
begin
  Key := '';
  Value := nil;
  inherited;
end;

procedure TLF_Notify_Sequence_Thread_Pool.Post_Notify(Name_: TLF_String; const APP: TLF_App; Memory_Param: TMem64);
var
  th: TLF_Notify_Sequence_Thread;
begin
  Lock;
  try
    th := Get_Default_Value(Name_, nil);
    if th = nil then
      begin
        th := TLF_Notify_Sequence_Thread.Create;
        th.APP := APP;
        th.Internal_Queue_Pool___ := self;
        th.Internal_Queue_Data___ := Add(Name_, th, False);
        th.Run;
      end;
    th.Critical.Lock;
    try
      if th.APP = APP then th.Queue_Tool.Push(TNotify_Queue_Data.Init(APP, Memory_Param))
      else DoStatus('TLF_Notify_Sequence_Thread_Pool.Post_Notify: application mismatch - thread for "%s" belongs to a different app instance', [Name_.Text]);
    finally
        th.Critical.UnLock;
    end;
  finally
      UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SeqNotifyPool.Post_Notify: key="%s"', [Name_.Text]);
    end;
end;

procedure TLF_Notify_Sequence_Thread_Pool.Post_Notify2(const APP: TLF_App; Memory_Param: TMem64);
begin
  Post_Notify(PFormat('%s.%s', [APP.Name.Text, TMemory_Param_Tool.Get_apiName(Memory_Param).Text]), APP, Memory_Param);
end;

procedure TLF_Notify_Sequence_Thread_Pool.Kill_App(const APP: TLF_App);
var
  th: TLF_Notify_Sequence_Thread;
begin
  Lock;
  try
    if Num > 0 then
      begin
        with repeat_ do
          repeat
            if APP = queue^.Data^.Data.Second.APP then
              begin
                queue^.Data^.Data.Second.Critical.Lock;
                try
                  queue^.Data^.Data.Second.Internal_Queue_Pool___ := nil;
                  queue^.Data^.Data.Second.Internal_Queue_Data___ := nil;
                finally
                    queue^.Data^.Data.Second.Critical.UnLock;
                end;
                queue^.Data^.Data.Second.Stop;
                queue^.Data^.Data.Second := nil;
                Push_To_Recycle_Pool2(queue);
              end;
          until not Next;
        Free_Recycle_Pool;
      end;
  finally
      UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SeqNotifyPool.Kill_App: app="%s"', [APP.Name.Text]);
    end;
end;

procedure TLF_Notify_Sequence_Thread_Pool.Stop;
var
  th: TLF_Notify_Sequence_Thread;
begin
  Lock;
  try
    if Num > 0 then
      begin
        with repeat_ do
          repeat
            queue^.Data^.Data.Second.Critical.Lock;
            try
              queue^.Data^.Data.Second.Internal_Queue_Pool___ := nil;
              queue^.Data^.Data.Second.Internal_Queue_Data___ := nil;
            finally
                queue^.Data^.Data.Second.Critical.UnLock;
            end;
            queue^.Data^.Data.Second.Stop;
            queue^.Data^.Data.Second := nil;
          until not Next;
        Clear;
      end;
  finally
      UnLock;
  end;
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SeqNotifyPool.Stop done');
    end;
end;

procedure TNotify_Queue_Tool.DoFree(var Data: TNotify_Queue_Data);
begin
  Data.Primary := nil;
  DisposeObjectAndNil(Data.Second);
  inherited;
end;

procedure TLF_Notify_Sequence_Thread.Do_Run_Th;
var
  app_and_api___: TLF_String;
  tmp: TNotify_Queue_Tool;
  tk: TTimeTick;
begin
  if LF_Debug_Log_Enabled then
    begin
      app_and_api___ := Internal_Queue_Data___^.Data.Primary.Text;
      LF_Debug_Log('SeqNotifyThread start: api="%s"', [app_and_api___.Text]);
    end;
  tmp := TNotify_Queue_Tool.Create;
  tk := GetTimeTick();
  while Activted do
    begin
      Critical.Lock;
      if Queue_Tool.Num > 0 then
          tmp.SwapInstance(Queue_Tool);
      Critical.UnLock;
      if tmp.Num > 0 then
        begin
          try
            repeat
              tmp.First^.Data.Primary.Engine.Execute_Notify(tmp.First^.Data.Second);
              DisposeObjectAndNil(tmp.First^.Data.Second);
              tmp.Next;
            until (tmp.Num <= 0) or (not Activted);
          except
          end;
          tk := GetTimeTick();
        end
      else
        begin
          TCompute.Sleep(10);
          if GetTimeTick() - tk >= Z.Core.C_Tick_Minute * 5 then
            begin
              if LF_Debug_Log_Enabled then
                begin
                  LF_Debug_Log('SeqNotifyThread idle timeout: api="%s"', [app_and_api___.Text]);
                end;
              Activted := False;
            end;
        end;
    end;
  DisposeObject(tmp);
  if (Internal_Queue_Data___ <> nil) and (Internal_Queue_Pool___ <> nil) then
    begin
      Internal_Queue_Pool___.Lock;
      try
          Internal_Queue_Pool___.Remove(Internal_Queue_Data___);
      finally
          Internal_Queue_Pool___.UnLock;
      end;
    end;
  DelayFreeObj(1.0, self);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('SeqNotifyThread exit: api="%s"', [app_and_api___.Text]);
    end;
end;

constructor TLF_Notify_Sequence_Thread.Create;
begin
  inherited Create;
  Critical := TCritical.Create(ClassName + '.Critical');
  Internal_Queue_Pool___ := nil;
  Internal_Queue_Data___ := nil;
  Activted := False;
  IsRunning := False;
  IsExit := False;
  Queue_Tool := TNotify_Queue_Tool.Create;
  APP := nil;
end;

destructor TLF_Notify_Sequence_Thread.Destroy;
begin
  DisposeObjectAndNil(Queue_Tool);
  DisposeObjectAndNil(Critical);
  inherited Destroy;
end;

procedure TLF_Notify_Sequence_Thread.Run;
begin
  if IsRunning then exit;
  Activted := True;
  TCompute.RunM_NP(Do_Run_Th, @IsRunning, @IsExit);
end;

procedure TLF_Notify_Sequence_Thread.Stop;
begin
  if IsRunning then
      Activted := False;
end;

procedure Do_LF_Status___(Trigger: Pointer; Input: TDataHnd___); cdecl;
var
  UID_: TUID___;
  from_, uid_ascii_, status_: TLF_String;
begin
  status_.ReadUTF8AnsiChar(PLF_Data(Input)^.GetBuffer());
  if PLF_Data(Input)^.Data_Param <> nil then
    begin
      UID_ := PLF_Data(Input)^.Get_P2P_UID();
      from_ := PLF_Data(Input)^.Get_P2P_Name();
      uid_ascii_ := TCipher.HashToString(UID_);
      if from_ <> '' then
          DoStatus('[%s] %s: %s', [from_.Text, uid_ascii_.ShortText(20, 5, 5).Text, status_.Text])
      else
          DoStatus('[%s]: %s', [uid_ascii_.ShortText(20, 5, 5).Text, status_.Text]);
      from_ := '';
    end
  else DoStatus('%s', [status_.Text]);
  status_ := '';
end;

procedure Init_P2P_APP;
begin
  LF_P2P_APP := TLF_App.Create(False);
  LF_P2P_APP.Name := '___LF_P2P_APP___';
  LF_P2P_APP.Desc := '';
  LF_P2P_APP.Engine.Reg_Notify('Status', 'console status', nil, Do_LF_Status___);
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Init_P2P_APP done');
    end;
end;

procedure Free_P2P_APP;
begin
  if LF_Debug_Log_Enabled then
    begin
      LF_Debug_Log('Free_P2P_APP');
    end;
  DisposeObjectAndNil(LF_P2P_APP);
end;

initialization

LF_App_Pool := TLF_App_Pool.Create;
LF_DataPool := TLF_DataPool.Create;
LF_DataMemory := TLF_DataMemory.Create;
LF_RunningCount := TAtomInt.Create(0);
LF_Call_Sequence_Thread_Pool := TLF_Call_Sequence_Thread_Pool.Create;
LF_Notify_Sequence_Thread_Pool := TLF_Notify_Sequence_Thread_Pool.Create;
Init_P2P_APP();

finalization

Free_P2P_APP;
DisposeObjectAndNil(LF_RunningCount);
DisposeObjectAndNil(LF_DataPool);
DisposeObjectAndNil(LF_DataMemory);
DisposeObjectAndNil(LF_Call_Sequence_Thread_Pool);
DisposeObjectAndNil(LF_Notify_Sequence_Thread_Pool);
DisposeObjectAndNil(LF_App_Pool);

end.
