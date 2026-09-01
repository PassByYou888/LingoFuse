{ *
  *  Z.LingoFuse_Core – Core RPC Framework for LingoFuse
  *  ====================================================
  *
  *  This unit provides the foundational, language‑neutral RPC (Remote
  *  Procedure Call) engine for the LingoFuse distributed service framework.
  *  It defines the core data types, registration mechanisms, and execution
  *  logic for exposing and invoking APIs (both request‑response calls and
  *  one‑way notifications) within a single process.
  *
  *  The design is built around three primary concepts:
  *
  *    1. Application (TLF_App) – A named container that groups a set of
  *       related APIs. Each app has a unique name used for routing and
  *       discovery in a networked environment.
  *
  *    2. Engine (TLF_Engine) – The registry and executor. It maintains a
  *       thread‑safe hash pool of registered APIs (TLF_MethodInfo) and
  *       provides methods to invoke them locally (Execute_Call and
  *       Execute_Notify). It also triggers update events when the API list
  *       changes.
  *
  *    3. Data Handle (TLF_Data) – An opaque handle that encapsulates either
  *       an input parameter or an output result. Handles are automatically
  *       recycled by a global pool (TLF_DataPool) after an idle timeout,
  *       reducing manual memory management burden. The handle can be
  *       manipulated via buffer read/write operations.
  *
  *  The unit also provides a sequenced notification mechanism
  *  (TLF_Notify_Sequence_Thread_Pool and TLF_Notify_Sequence_Thread) that
  *  guarantees FIFO order delivery of notifications for each unique
  *  (application, API) pair. This is essential for scenarios where message
  *  ordering must be preserved.
  *
  *  All registration and execution methods are thread‑safe, making the
  *  framework suitable for multi‑threaded server applications. However,
  *  individual data handles (TLF_Data) are not thread‑safe; they must be
  *  used exclusively from one thread or protected by external
  *  synchronisation.
  *
  *  The unit is designed to be used both directly in native Pascal code and
  *  via the C ABI export layer (Z.LingoFuse_Export), allowing integration
  *  with other programming languages (C, C++, Python, etc.). It is also the
  *  foundation for the network‑aware LingoFuse service and client components
  *  (Z.Net.C4.LingoFuse) that extend these capabilities over a distributed
  *  C4 service mesh.
  *
  *  Typical usage scenarios include:
  *    - Building modular applications with plug‑in architectures.
  *    - Implementing microservices that expose RPC endpoints.
  *    - Creating distributed systems with ordered event processing.
  *    - Integrating with other languages via the C ABI layer.
  *
  *  Dependencies:
  *    - Z.Core          : Threading, containers, memory management, timers.
  *    - Z.PascalStrings : Pascal‑style string handling.
  *    - Z.UPascalStrings: Unicode string utilities.
  *    - Z.Status        : Global logging and status reporting.
  *    - Z.UnicodeMixedLib: Miscellaneous helper functions.
  *    - Z.HashList.Templet: Thread‑safe generic hash maps.
  *    - Z.MemoryStream  : TMem64 stream for binary data.
  *    - Z.LingoFuse_Export: C ABI types for external language binding.
  *
  *  Key global objects:
  *    - LF_DataPool         : Automatically recycles idle data handles.
  *    - LF_RunningCount     : Atomic counter of executing API calls.
  *    - LF_Notify_Sequence_Thread_Pool : Manages ordered notification threads.
  *
  *  For network‑enabled operation, refer to the companion unit
  *  Z.Net.C4.LingoFuse, which integrates this core with the C4 service mesh.
  *
  *  @Version   Part of the LingoFuse framework (based on LingoFuse, but heavily
  *             extended and renamed). For details, see the project repository
  *             or documentation.
  *  @Author    (Original LingoFuse by PassByYou888; LingoFuse is a derivative
  *             work with significant enhancements.)
  *
  *  @Example (local app registration and call):
  *    var
  *      App: TLF_App;
  *      Tool: TMemory_Param_Tool;
  *      Param, Result: TMem64;
  *    begin
  *      App := TLF_App.Create;
  *      App.Name := 'MyApp';
  *      App.Engine.Reg_Call('echo', 'Echo service', nil,
  *        procedure(Trigger: Pointer; Input, Output: PLF_Data)
  *        begin
  *          // Copy input to output.
  *          Output^.Data_Result.CopyFrom(Input^.Data_Param.Param, -1);
  *        end
  *      );
  *      Tool := TMemory_Param_Tool.Create;
  *      Tool.MethodName := 'echo';
  *      Tool.Param.WriteString('Hello');
  *      Param := TMem64.Create;
  *      Tool.EncryptToMem(Param);
  *      Tool.Free;
  *      Result := App.Engine.Execute_Call(Param); // Result contains 'Hello'
  *      App.Free;
  *      Param.Free;
  *      Result.Free;
  *    end;
  *
  *  For remote calls and notifications, see Z.Net.C4.LingoFuse.
  * }
unit Z.LingoFuse_Core;

{$DEFINE FPC_DELPHI_MODE}
{$I .\pascal\zNetV2\source\Z.Define.inc}

interface

uses
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status, Z.UnicodeMixedLib,
  Z.HashList.Templet, Z.MemoryStream, Z.Parsing,
  Z.LingoFuse_Export, Z.Int128;

type
  { * Forward declaration of the application class, defined later. }
  TLF_App = class;

  { * TLF_String: Unicode string type used for all textual identifiers.
    * Alias for TUPascalString, providing high-performance Unicode handling. }
  TLF_String = TUPascalString;

  { * TLF_Mode: Classification of an API operation.
    * - LF_Unknow__ : Unspecified or error state.
    * - LF_Call__   : Request-response style, expects a result.
    * - LF_Notify__ : One-way message, no response. }
  TLF_Mode = (
    LF_Unknow__ = 0,
    LF_Call__ = 1,
    LF_Notify__ = 2
    );

  { * TMemory_Param_Tool: Packs/unpacks an API name and binary payload into a TMem64.
    * Wire format: [API name as Pascal string] + [4-byte payload size] + [payload bytes].
    * Not thread-safe; create per thread or synchronise.
    *
    * @Field MethodName : Name of the target API.
    * @Field Param      : Binary payload.
    * @Constructor Create : Initialises empty fields and internal temp buffer.
    * @Destructor Destroy : Frees Param and tmp.
    * @Method EncryptToMem : Encodes MethodName and Param into a TMem64.
    * @Method DecryptFromMem : Decodes a TMem64 back into MethodName and Param.
    * @ClassMethod Get_apiName : Extracts only the API name from a packed block.
    *
    * @Example:
    *   var Tool := TMemory_Param_Tool.Create;
    *   Tool.MethodName := 'echo';
    *   Tool.Param.WriteString('Hello');
    *   var Packed := TMem64.Create;
    *   Tool.EncryptToMem(Packed); // Packed now contains the encoded data
    *   // ... send Packed ...
    *   Tool.Free; }
  TMemory_Param_Tool = class
  private
    tmp: TMem64; // internal buffer for decoding without modifying source
  public
    MethodName: TLF_String;
    Param: TMem64;
    constructor Create;
    destructor Destroy; override;
    procedure EncryptToMem(m64: TMem64);
    procedure DecryptFromMem(m64: TMem64);
    class function Get_apiName(m64: TMem64): TLF_String;
  end;

  { * TLF_MethodInfo: Metadata for a single registered API.
    * Stores name, description, mode, user trigger, and cdecl callback.
    * Used as value in TLF_MethodPool. }
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

  { * TLF_MethodPool: Thread-safe hash map storing TLF_MethodInfo by API name.
    * Inherits from TCritical_String_Big_Hash_Pair_Pool.
    * @Field APP : Back-reference to owning TLF_App.
    * @Method DoFree : Frees the TLF_MethodInfo on removal. }
  TLF_MethodPool = class(TCritical_String_Big_Hash_Pair_Pool<TLF_MethodInfo>)
  public
    APP: TLF_App;
    procedure DoFree(var Key: SystemString; var Value: TLF_MethodInfo); override;
  end;

  { * PLF_Data: Pointer to a TLF_Data record. Used as opaque handle (TDataHnd___) in C exports. }
  PLF_Data = ^TLF_Data;

  { * TLF_DataOrder: FIFO queue that stores PLF_Data pointers. Used internally for collection. }
  TLF_DataOrder = class(TOrderStruct<PLF_Data>)
  end;

  { * TLF_DataPool: Global pool that tracks all active TLF_Data handles.
    * Automatically frees idle handles (idle > 5 minutes) every 5 seconds.
    * @Field Update_Time__ : Last time Progress() ran.
    * @Constructor Create : Initialises Update_Time__.
    * @Method Progress : Scans and frees idle handles.
    * @Method Free_All_Hnd : Frees all handles (used at finalisation). }
  TLF_DataPool = class(TBigList<PLF_Data>)
  private
    Update_Time__: TTimeTick;
  public
    constructor Create;
    procedure Progress;
    procedure Free_All_Hnd;
  end;

  { * TLF_Data: Discriminated union representing an input parameter or output result.
    * @Field Data_Param : Non-nil for input (TMemory_Param_Tool).
    * @Field Data_Result : Non-nil for output (TMem64).
    * @Field Data_Info : Debug string.
    * @Method Init : Sets fields to nil/empty.
    * @ClassMethod New_Param : Creates input handle with given API name.
    * @ClassMethod New_Param_From : Creates input by unpacking a packed TMem64.
    * @ClassMethod New_Result : Creates empty output handle.
    * @ClassMethod New_Result_From : Creates output taking ownership of a TMem64.
    * @ClassMethod Free_Data : Frees the record and owned objects.
    * @Method GetBuffer : Returns raw data pointer (read-only).
    * @Method WriteBuff : Writes data at current position.
    * @Method ReadBuff : Reads data at current position.
    * @Method Get_Pos : Returns current position.
    * @Method Set_Pos : Sets current position.
    * @Method Get_Size : Returns total buffer size.
    * @Method Set_Size : Resizes buffer. }
  TLF_Data = record
  private
    P___: TLF_DataPool.PQueueStruct; // pool entry pointer
    Last_Update__: TTimeTick; // last access timestamp
  public
    Data_Param: TMemory_Param_Tool;
    Data_Result: TMem64;
    Data_Info: TLF_String;
    procedure Init;
    class function New_Param(MethodName: TLF_String): PLF_Data; static;
    class function New_Param_From(Data_: TMem64): PLF_Data; static;
    class function New_Result: PLF_Data; static;
    class function New_Result_From(Data_: TMem64): PLF_Data; static;
    class procedure Free_Data(hnd: PLF_Data); static;
    function GetBuffer: Pointer;
    function WriteBuff(Buff: Pointer; Size: Int64): Int64;
    function ReadBuff(Buff: Pointer; Size: Int64): Int64;
    function Get_Pos: Int64;
    procedure Set_Pos(Pos_: Int64);
    function Get_Size: Int64;
    procedure Set_Size(Size_: Int64);
  end;

  { * TLF_Engine: Core API registry and execution engine.
    * Maintains a thread-safe pool of registered APIs and executes them locally.
    * @Field LF_MethodPool : Hash pool of registered APIs.
    * @Field APP : Back-reference to owning TLF_App.
    * @Constructor Create : Initialises the method pool.
    * @Destructor Destroy : Frees the method pool.
    * @Method Reg_Call : Registers a Call API.
    * @Method Reg_Notify : Registers a Notify API.
    * @Method UnReg : Unregisters an API by name.
    * @Method Execute_Call : Executes a Call synchronously, returns result.
    * @Method Execute_Notify : Executes a Notify synchronously (no result).
    *
    * @Example:
    *   var Eng := TLF_Engine.Create;
    *   Eng.Reg_Call('add', 'Adds two ints', nil,
    *     procedure(Trigger: Pointer; Input, Output: PLF_Data)
    *     var a,b,sum: Integer;
    *     begin
    *       Input^.Data_Param.Param.ReadBuffer(@a, SizeOf(a));
    *       Input^.Data_Param.Param.ReadBuffer(@b, SizeOf(b));
    *       sum := a + b;
    *       Output^.Data_Result.WriteBuffer(@sum, SizeOf(sum));
    *     end
    *   );
    *   // Prepare packed param...
    *   var Res := Eng.Execute_Call(Packed); // Res is a TMem64 with sum.
    *   Eng.Free; }
  TLF_Engine = class
  public
    LF_MethodPool: TLF_MethodPool;
    APP: TLF_App;
    constructor Create;
    destructor Destroy; override;
    function Reg_Call(MethodName, Desc: TLF_String; Trigger: Pointer; On_Call: TLF_Call_Event): Boolean;
    function Reg_Notify(MethodName, Desc: TLF_String; Trigger: Pointer; On_Notify: TLF_Notify_Event): Boolean;
    function UnReg(MethodName: TLF_String): Boolean;
    function Execute_Call(Memory_Param: TMem64): TMem64;
    procedure Execute_Notify(Memory_Param: TMem64);
  end;

  { * TOn_LFUpdate: Callback for application update events (API list changed).
    * @Param Sender : The TLF_App instance that changed. }
  TOn_LFUpdate = procedure(Sender: TLF_App) of object;

  { * TLF_UpdateEventPool: Thread-safe map storing TOn_LFUpdate callbacks keyed by binding object. }
  TLF_UpdateEventPool = class(TCritical_Big_Hash_Pair_Pool<TCore_Object, TOn_LFUpdate>)
  end;

  { * TLF_App: Logical application that exposes a set of APIs.
    * Notifies subscribers when its API list changes.
    * @Field Name : Unique identifier (case-sensitive).
    * @Field Desc : Description.
    * @Field Engine : The API registry and execution engine.
    * @Constructor Create : Initialises engine, event pool, and a 1-second timer for coalescing updates.
    * @Destructor Destroy : Frees engine and event pool.
    * @Method DoChange : Marks as changed and schedules notification.
    * @Method Subscribe_Update : Registers a listener.
    * @Method Remove_Update : Unregisters a listener.
    *
    * @Example:
    *   var App := TLF_App.Create;
    *   App.Name := 'MyApp';
    *   App.Engine.Reg_Call('ping', 'Ping', nil, MyPingCallback);
    *   App.Subscribe_Update(MyObj, MyUpdateHandler); }
  TLF_App = class
  private
    FUpdateEventPool: TLF_UpdateEventPool;
    FUpdated: Boolean;
    procedure Do_LFRegEvent;
    procedure DoTimer();
  public
    Name: TLF_String;
    Desc: TLF_String;
    Engine: TLF_Engine;
    constructor Create;
    destructor Destroy; override;
    procedure DoChange();
    procedure Subscribe_Update(Bind: TCore_Object; OnUpdate: TOn_LFUpdate);
    procedure Remove_Update(Bind: TCore_Object);
  end;

  { * Forward declaration of the sequenced notification thread. }
  TLF_Notify_Sequence_Thread = class;

  { * TLF_Notify_Sequence_Thread_Pool: Manages per-(app,api) threads for ordered notifications.
    * @InheritsFrom TBig_Hash_Pair_Pool<TLF_String, TLF_Notify_Sequence_Thread>
    * @Method Get_Key_Hash : Computes hash for the key.
    * @Method Compare_Key : Compares two keys.
    * @Method DoFree : Cleans up thread on removal.
    * @Method Post_Notify : Posts a notification to a specific (app,api) pair.
    * @Method Post_Notify2 : Convenience wrapper extracting API name from payload.
    * @Method Kill_App : Terminates all threads belonging to an app.
    * @Method Stop : Terminates all threads and clears pool. }
  TLF_Notify_Sequence_Thread_Pool = class(TBig_Hash_Pair_Pool<TLF_String, TLF_Notify_Sequence_Thread>)
  public
    constructor Create;
    function Get_Key_Hash(const Key_: TLF_String): THash; override;
    function Compare_Key(const Key_1, Key_2: TLF_String): Boolean; override;
    procedure DoFree(var Key: TLF_String; var Value: TLF_Notify_Sequence_Thread); override;
    procedure Post_Notify(Name_: TLF_String; const APP: TLF_App; Memory_Param: TMem64);
    procedure Post_Notify2(const APP: TLF_App; Memory_Param: TMem64);
    procedure Kill_App(const APP: TLF_App);
    procedure Stop;
  end;

  { * TNotify_Queue_Data: Pair of (TLF_App, TMem64) used in the notification queue. }
  TNotify_Queue_Data = TPair2<TLF_App, TMem64>;

  { * TNotify_Queue_Tool: FIFO queue for TNotify_Queue_Data. Overrides DoFree to free the TMem64. }
  TNotify_Queue_Tool = class(TOrderStruct<TNotify_Queue_Data>)
  public
    procedure DoFree(var Data: TNotify_Queue_Data); override;
  end;

  { * TLF_Notify_Sequence_Thread: Dedicated thread that processes notifications for one API in FIFO order.
    * Created on demand, terminates after 5 minutes of inactivity.
    * @Field Queue_Tool : FIFO queue of notifications.
    * @Field APP : The owning application.
    * @Field Critical : Lock protecting Queue_Tool.
    * @Constructor Create : Initialises queue and critical section.
    * @Destructor Destroy : Frees queue and critical section.
    * @Method Run : Starts the thread.
    * @Method Stop : Signals termination. }
  TLF_Notify_Sequence_Thread = class
  private
    Critical: TCritical;
    Internal_Queue_Pool___: TLF_Notify_Sequence_Thread_Pool;
    Internal_Queue_Data___: TLF_Notify_Sequence_Thread_Pool.PPair_Pool_Value__;
    Activted: Boolean;
    IsRunning, IsExit: Boolean;
    procedure Do_Run_Th();
  public
    Queue_Tool: TNotify_Queue_Tool;
    APP: TLF_App;
    constructor Create;
    destructor Destroy; override;
    procedure Run;
    procedure Stop;
  end;

var
  { * LF_DataPool: Global pool for automatic recycling of TLF_Data handles. }
  LF_DataPool: TLF_DataPool;
  { * LF_RunningCount: Atomic counter of active API calls. }
  LF_RunningCount: TAtomInt;
  { * LF_Notify_Sequence_Thread_Pool: Global pool for sequenced notification threads. }
  LF_Notify_Sequence_Thread_Pool: TLF_Notify_Sequence_Thread_Pool;

implementation

{ ----------------------------------------------------------------------------
  TMemory_Param_Tool
  ---------------------------------------------------------------------------- }

constructor TMemory_Param_Tool.Create;
{ * Initialises the tool with empty MethodName, empty Param, and a temporary buffer. }
begin
  inherited Create;
  tmp := TMem64.Create;
  MethodName := '';
  Param := TMem64.Create;
end;

destructor TMemory_Param_Tool.Destroy;
{ * Frees the Param payload and the temporary buffer. }
begin
  DisposeObject(Param);
  DisposeObject(tmp);
  inherited Destroy;
end;

procedure TMemory_Param_Tool.EncryptToMem(m64: TMem64);
{ * Encodes MethodName and Param into the destination TMem64.
  * The format: Pascal-string for name, then 32-bit size, then raw bytes.
  * Destination is cleared before writing. }
begin
  m64.Clear;
  m64.WriteString(MethodName.Text);
  m64.WriteInt32(Param.Size);
  m64.WritePtr(Param.Memory, Param.Size);
end;

procedure TMemory_Param_Tool.DecryptFromMem(m64: TMem64);
{ * Decodes a packed TMem64 back into MethodName and Param.
  * If m64 is protected (read-only), reads directly; otherwise swaps into tmp buffer. }
var
  i32: Integer;
begin
  if m64.ProtectedMode then
    begin
      m64.Position := 0;
      MethodName := m64.ReadString;
      Param.Size := m64.ReadInt32;
      m64.ReadPtr(Param.Memory, Param.Size);
      Param.Position := 0;
    end
  else
    begin
      tmp.SwapInstance(m64);
      tmp.Position := 0;
      MethodName := tmp.ReadString;
      i32 := tmp.ReadInt32;
      Param.Mapping(tmp.PosAsPtr, i32);
      Param.Position := 0;
    end;
end;

class function TMemory_Param_Tool.Get_apiName(m64: TMem64): TLF_String;
{ * Extracts only the API name from a packed TMem64, leaving position unchanged. }
var
  bak_: Int64;
begin
  bak_ := m64.Position;
  m64.Position := 0;
  Result := m64.ReadString;
  m64.Position := bak_;
end;

{ ----------------------------------------------------------------------------
  TLF_MethodInfo
  ---------------------------------------------------------------------------- }

constructor TLF_MethodInfo.Create;
{ * Initialises all fields to default empty values, Mode = LF_Unknow__. }
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

{ ----------------------------------------------------------------------------
  TLF_MethodPool
  ---------------------------------------------------------------------------- }

procedure TLF_MethodPool.DoFree(var Key: SystemString; var Value: TLF_MethodInfo);
{ * Overridden to free the TLF_MethodInfo object when an entry is removed. }
begin
  DisposeObjectAndNil(Value);
  inherited;
end;

{ ----------------------------------------------------------------------------
  TLF_DataPool
  ---------------------------------------------------------------------------- }

constructor TLF_DataPool.Create;
{ * Initialises Update_Time__ to current tick. }
begin
  inherited Create;
  Update_Time__ := GetTimeTick();
end;

procedure TLF_DataPool.Progress;
{ * Scans the pool and frees handles that have been idle for >5 minutes.
  * Runs at most every 5 seconds. Collects handles in a temporary list to free outside lock. }
var
  tk: TTimeTick;
  L: TLF_DataOrder;
begin
  tk := GetTimeTick();
  if tk - Update_Time__ < 5000 then exit;
  Update_Time__ := tk;
  L := TLF_DataOrder.Create;
  Lock;
  try
    if Num > 0 then
      with repeat_ do
        repeat
          if tk - queue^.Data^.Last_Update__ > Z.Core.C_Tick_Second * 60 * 5 then
            begin
              queue^.Data^.P___ := nil;
              L.Push(queue^.Data);
              Push_To_Recycle_Pool(queue);
            end;
        until not Next;
    Free_Recycle_Pool;
  finally
      UnLock;
  end;
  if L.Num > 0 then
    begin
      DoStatus('hint: Data handle pool "%d" handles were idle for more than 5 minutes and have been automatically freed.', [L.Num]);
      if L.Num > 5 then
          DoStatus('...');
      repeat
        if L.Num < 5 then
            DoStatus('hint: automatically free handles ' + L.First^.Data^.Data_Info.Text);
        TLF_Data.Free_Data(L.First^.Data);
        L.Next;
      until L.Num <= 0;
    end;
  DisposeObject(L);
end;

procedure TLF_DataPool.Free_All_Hnd;
{ * Frees all handles currently in the pool. Used during finalisation. }
var
  L: TLF_DataOrder;
begin
  L := TLF_DataOrder.Create;
  Lock;
  try
    if Num > 0 then
      with repeat_ do
        repeat
          queue^.Data^.P___ := nil;
          L.Push(queue^.Data);
        until not Next;
    Clear;
  finally
      UnLock;
  end;
  if L.Num > 0 then
    begin
      if L.Num > 5 then
        begin
          DoStatus('hint: Data handle pool "%d" do automatically freed.', [L.Num]);
          DoStatus('...');
        end;
      repeat
        if L.Num < 5 then
            DoStatus('hint: automatically free handles ' + L.First^.Data^.Data_Info.Text);
        TLF_Data.Free_Data(L.First^.Data);
        L.Next;
      until L.Num <= 0;
    end;
  DisposeObject(L);
end;

{ ----------------------------------------------------------------------------
  TLF_Data
  ---------------------------------------------------------------------------- }

procedure TLF_Data.Init;
{ * Initialises the record with nil pointers and empty info. }
begin
  P___ := nil;
  Last_Update__ := GetTimeTick();
  Data_Param := nil;
  Data_Result := nil;
  Data_Info := '';
end;

class function TLF_Data.New_Param(MethodName: TLF_String): PLF_Data;
{ * Creates a new input parameter handle with the given API name.
  * The handle is added to the global pool for recycling. }
var
  p: PLF_Data;
begin
  New(p);
  p^.Init;
  p^.Data_Param := TMemory_Param_Tool.Create;
  p^.Data_Param.MethodName := MethodName;
  p^.Data_Info := PFormat('api "%s" parameter.', [MethodName.Text]);
  LF_DataPool.Lock;
  try
      p^.P___ := LF_DataPool.Add(p);
  finally
      LF_DataPool.UnLock;
  end;
  Result := p;
end;

class function TLF_Data.New_Param_From(Data_: TMem64): PLF_Data;
{ * Creates an input handle by unpacking a packed TMem64. }
var
  p: PLF_Data;
begin
  New(p);
  p^.Init;
  p^.Data_Param := TMemory_Param_Tool.Create;
  p^.Data_Param.DecryptFromMem(Data_);
  LF_DataPool.Lock;
  try
      p^.P___ := LF_DataPool.Add(p);
  finally
      LF_DataPool.UnLock;
  end;
  Result := p;
end;

class function TLF_Data.New_Result: PLF_Data;
{ * Creates a new empty output handle with a fresh TMem64. }
var
  p: PLF_Data;
begin
  New(p);
  p^.Init;
  p^.Data_Result := TMem64.Create;
  LF_DataPool.Lock;
  try
      p^.P___ := LF_DataPool.Add(p);
  finally
      LF_DataPool.UnLock;
  end;
  Result := p;
end;

class function TLF_Data.New_Result_From(Data_: TMem64): PLF_Data;
{ * Creates an output handle, taking ownership of the provided TMem64. }
var
  p: PLF_Data;
begin
  New(p);
  p^.Init;
  p^.Data_Result := Data_;
  p^.Data_Result.Position := 0;
  LF_DataPool.Lock;
  try
      p^.P___ := LF_DataPool.Add(p);
  finally
      LF_DataPool.UnLock;
  end;
  Result := p;
end;

class procedure TLF_Data.Free_Data(hnd: PLF_Data);
{ * Frees the handle and all owned objects. Removes from global pool. }
begin
  if hnd = nil then exit;
  if hnd^.P___ <> nil then
    begin
      LF_DataPool.Lock;
      try
          LF_DataPool.Remove_P(hnd^.P___);
      finally
          LF_DataPool.UnLock;
      end;
      hnd^.P___ := nil;
    end;
  hnd^.Data_Info := '';
  DisposeObjectAndNil(hnd^.Data_Param);
  DisposeObjectAndNil(hnd^.Data_Result);
  Dispose(hnd);
end;

function TLF_Data.GetBuffer: Pointer;
{ * Returns raw data pointer (read-only). Updates last-access timestamp. }
begin
  Result := nil;
  if Data_Param <> nil then
      Result := Data_Param.Param.Memory
  else if Data_Result <> nil then
      Result := Data_Result.Memory;
  LF_DataPool.Lock;
  try
      Last_Update__ := GetTimeTick();
  finally
      LF_DataPool.UnLock;
  end;
end;

function TLF_Data.WriteBuff(Buff: Pointer; Size: Int64): Int64;
{ * Writes data at current position. Updates timestamp. }
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.WritePtr(Buff, Size)
  else if Data_Result <> nil then
      Result := Data_Result.WritePtr(Buff, Size);
  LF_DataPool.Lock;
  try
      Last_Update__ := GetTimeTick();
  finally
      LF_DataPool.UnLock;
  end;
end;

function TLF_Data.ReadBuff(Buff: Pointer; Size: Int64): Int64;
{ * Reads data at current position. Updates timestamp. }
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.ReadPtr(Buff, Size)
  else if Data_Result <> nil then
      Result := Data_Result.ReadPtr(Buff, Size);
  LF_DataPool.Lock;
  try
      Last_Update__ := GetTimeTick();
  finally
      LF_DataPool.UnLock;
  end;
end;

function TLF_Data.Get_Pos: Int64;
{ * Returns current read/write position. Updates timestamp. }
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.Position
  else if Data_Result <> nil then
      Result := Data_Result.Position;
  LF_DataPool.Lock;
  try
      Last_Update__ := GetTimeTick();
  finally
      LF_DataPool.UnLock;
  end;
end;

procedure TLF_Data.Set_Pos(Pos_: Int64);
{ * Sets current read/write position. Updates timestamp. }
begin
  if Data_Param <> nil then
      Data_Param.Param.Position := Pos_
  else if Data_Result <> nil then
      Data_Result.Position := Pos_;
  LF_DataPool.Lock;
  try
      Last_Update__ := GetTimeTick();
  finally
      LF_DataPool.UnLock;
  end;
end;

function TLF_Data.Get_Size: Int64;
{ * Returns total buffer size. Updates timestamp. }
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.Size
  else if Data_Result <> nil then
      Result := Data_Result.Size;
  LF_DataPool.Lock;
  try
      Last_Update__ := GetTimeTick();
  finally
      LF_DataPool.UnLock;
  end;
end;

procedure TLF_Data.Set_Size(Size_: Int64);
{ * Resizes buffer. Updates timestamp. }
begin
  if Data_Param <> nil then
      Data_Param.Param.Size := Size_
  else if Data_Result <> nil then
      Data_Result.Size := Size_;
  LF_DataPool.Lock;
  try
      Last_Update__ := GetTimeTick();
  finally
      LF_DataPool.UnLock;
  end;
end;

{ ----------------------------------------------------------------------------
  TLF_Engine
  ---------------------------------------------------------------------------- }

constructor TLF_Engine.Create;
{ * Creates the method pool with 255 buckets and sets APP to nil. }
begin
  inherited Create;
  LF_MethodPool := TLF_MethodPool.Create($FF, nil);
  LF_MethodPool.APP := nil;
end;

destructor TLF_Engine.Destroy;
{ * Frees the method pool. }
begin
  DisposeObject(LF_MethodPool);
  inherited Destroy;
end;

function TLF_Engine.Reg_Call(MethodName, Desc: TLF_String; Trigger: Pointer; On_Call: TLF_Call_Event): Boolean;
{ * Registers a Call API. Returns True on success, False if name already exists. }
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
end;

function TLF_Engine.Reg_Notify(MethodName, Desc: TLF_String; Trigger: Pointer; On_Notify: TLF_Notify_Event): Boolean;
{ * Registers a Notify API. Returns True on success, False if name already exists. }
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
end;

function TLF_Engine.UnReg(MethodName: TLF_String): Boolean;
{ * Unregisters an API by name. Returns True if found and removed. }
var
  api_: TLF_MethodInfo;
begin
  Result := False;
  if not LF_MethodPool.Exists_Key(MethodName) then
      exit;
  LF_MethodPool.Delete(MethodName);
  APP.DoChange();
  Result := True;
end;

function TLF_Engine.Execute_Call(Memory_Param: TMem64): TMem64;
{ * Executes a Call API synchronously. Returns a new TMem64 with the result.
  * Increments/decrements LF_RunningCount. Frees input/output handles internally. }
var
  api_: TLF_MethodInfo;
  input_, output_: PLF_Data;
  bak_input_, bak_output_: TLF_Data;
begin
  LF_RunningCount.UnLock(LF_RunningCount.LockP^ + 1);
  input_ := TLF_Data.New_Param_From(Memory_Param);
  output_ := TLF_Data.New_Result;
  Result := TMem64.Create;
  try
    api_ := LF_MethodPool.Get_Default_Value(input_.Data_Param.MethodName, nil);
    if api_ = nil then
      begin
        DoStatus('no found api "%s"', [input_.Data_Param.MethodName.Text]);
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
            DoStatus('execute call-mode api "%s" (stdcall) execpet!', [input_.Data_Param.MethodName.Text]);
            input_^ := bak_input_;
            output_^ := bak_output_;
          end;
        end;
      LF_Notify__:
        begin
          DoStatus('Warning: API "%s" is registered as Notify but invoked as Call; no return value will be produced.', [input_.Data_Param.MethodName.Text]);
          try
            if Assigned(api_.On_Notify) then
              begin
                api_.On_Notify(api_.Trigger, input_);
                input_^ := bak_input_;
              end;
          except
            DoStatus('execute notify-mode api "%s" (stdcall) execpet!', [input_.Data_Param.MethodName.Text]);
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
end;

procedure TLF_Engine.Execute_Notify(Memory_Param: TMem64);
{ * Executes a Notify API synchronously. No result. Increments/decrements LF_RunningCount. }
var
  api_: TLF_MethodInfo;
  input_, output_: PLF_Data;
  bak_input_, bak_output_: TLF_Data;
begin
  LF_RunningCount.UnLock(LF_RunningCount.LockP^ + 1);
  input_ := TLF_Data.New_Param_From(Memory_Param);
  output_ := TLF_Data.New_Result;
  try
    api_ := LF_MethodPool.Get_Default_Value(input_.Data_Param.MethodName, nil);
    if api_ = nil then
      begin
        DoStatus('no found api "%s"', [input_.Data_Param.MethodName.Text]);
        exit;
      end;
    bak_input_ := input_^;
    bak_output_ := output_^;
    case api_.Mode of
      LF_Call__:
        begin
          DoStatus('Warning: API "%s" is registered as Call but invoked via Notify; any returned value will be discarded.', [input_.Data_Param.MethodName.Text]);
          try
            if Assigned(api_.On_Call) then
              begin
                api_.On_Call(api_.Trigger, input_, output_);
                input_^ := bak_input_;
                output_^ := bak_output_;
              end;
          except
            DoStatus('execute call-mode api "%s" (stdcall) execpet!', [input_.Data_Param.MethodName.Text]);
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
            DoStatus('execute notify-mode api "%s" (stdcall) execpet!', [input_.Data_Param.MethodName.Text]);
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

{ ----------------------------------------------------------------------------
  TLF_App
  ---------------------------------------------------------------------------- }

procedure TLF_App.Do_LFRegEvent;
{ * Broadcasts update events to all subscribers. Called on main thread via timer. }
begin
  FUpdateEventPool.Lock;
  if FUpdateEventPool.Num > 0 then
    with FUpdateEventPool.repeat_ do
      repeat
        try
          if Assigned(queue^.Data^.Data.Second) then
              queue^.Data^.Data.Second(Self);
        except
        end;
      until not Next;
  FUpdateEventPool.UnLock;
end;

procedure TLF_App.DoTimer;
{ * Timer callback: if FUpdated, posts Do_LFRegEvent to main thread and resets flag. }
begin
  if FUpdated then
    begin
      MainThreadPost.PostM_NP(Do_LFRegEvent);
      FUpdated := False;
    end;
end;

constructor TLF_App.Create;
{ * Creates the app, initialises engine, event pool, and a 1-second timer for coalescing updates. }
begin
  inherited Create;
  Name := '';
  Desc := '';
  Engine := TLF_Engine.Create;
  Engine.APP := Self;
  Engine.LF_MethodPool.APP := Self;
  FUpdateEventPool := TLF_UpdateEventPool.Create($FF, nil);
  FUpdated := False;
  Subscribe_Timer_M(Self, 1000, DoTimer);
end;

destructor TLF_App.Destroy;
{ * Stops timer, frees engine and event pool. }
begin
  Remove_Timer(Self);
  DisposeObject(Engine);
  DisposeObject(FUpdateEventPool);
  inherited Destroy;
end;

procedure TLF_App.DoChange();
{ * Marks as changed and resets timer to trigger notification. }
begin
  FUpdated := True;
  Reset_Timer(Self);
end;

procedure TLF_App.Subscribe_Update(Bind: TCore_Object; OnUpdate: TOn_LFUpdate);
{ * Subscribes a listener; if Bind already exists, callback is overwritten. }
begin
  FUpdateEventPool.Add(Bind, OnUpdate, True);
end;

procedure TLF_App.Remove_Update(Bind: TCore_Object);
{ * Unsubscribes a listener. }
begin
  FUpdateEventPool.Delete(Bind);
end;

{ ----------------------------------------------------------------------------
  TLF_Notify_Sequence_Thread_Pool
  ---------------------------------------------------------------------------- }

constructor TLF_Notify_Sequence_Thread_Pool.Create;
{ * Creates the pool with 255 buckets. }
begin
  inherited Create($FF, nil);
end;

function TLF_Notify_Sequence_Thread_Pool.Get_Key_Hash(const Key_: TLF_String): THash;
{ * Computes hash for the key using FastHashPPascalString then CRC32. }
begin
  Result := FastHashPPascalString(@Key_);
  Result := Get_CRC32(@Result, SizeOf(THash));
end;

function TLF_Notify_Sequence_Thread_Pool.Compare_Key(const Key_1, Key_2: TLF_String): Boolean;
{ * Compares two keys using TLF_String.Same. }
begin
  Result := Key_1.Same(@Key_2);
end;

procedure TLF_Notify_Sequence_Thread_Pool.DoFree(var Key: TLF_String; var Value: TLF_Notify_Sequence_Thread);
{ * Overridden to clear key and thread reference. }
begin
  Key := '';
  Value := nil;
  inherited;
end;

procedure TLF_Notify_Sequence_Thread_Pool.Post_Notify(Name_: TLF_String; const APP: TLF_App; Memory_Param: TMem64);
{ * Posts a notification to the specified (app,api) pair.
  * Creates a thread if one does not exist, then enqueues the payload. }
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
        th.Internal_Queue_Pool___ := Self;
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
end;

procedure TLF_Notify_Sequence_Thread_Pool.Post_Notify2(const APP: TLF_App; Memory_Param: TMem64);
{ * Convenience wrapper: builds key as "APP.Name.APIName" and posts. }
begin
  Post_Notify(PFormat('%s.%s', [APP.Name.Text, TMemory_Param_Tool.Get_apiName(Memory_Param).Text]), APP, Memory_Param);
end;

procedure TLF_Notify_Sequence_Thread_Pool.Kill_App(const APP: TLF_App);
{ * Terminates and removes all threads belonging to the given app. }
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
end;

procedure TLF_Notify_Sequence_Thread_Pool.Stop;
{ * Stops all threads and clears the pool. }
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
end;

{ ----------------------------------------------------------------------------
  TNotify_Queue_Tool
  ---------------------------------------------------------------------------- }

procedure TNotify_Queue_Tool.DoFree(var Data: TNotify_Queue_Data);
{ * Frees the TMem64 payload when the queue item is removed. }
begin
  Data.Primary := nil;
  DisposeObjectAndNil(Data.Second);
  inherited;
end;

{ ----------------------------------------------------------------------------
  TLF_Notify_Sequence_Thread
  ---------------------------------------------------------------------------- }

procedure TLF_Notify_Sequence_Thread.Do_Run_Th;
{ * Main thread loop: processes queued notifications in order.
  * Terminates after 5 minutes of inactivity. }
var
  app_and_api___: TLF_String;
  tmp: TNotify_Queue_Tool;
  tk: TTimeTick;
begin
  app_and_api___ := Internal_Queue_Data___^.Data.Primary.Text;
  DoStatus('started Sequenced notify thread for api "%s"', [app_and_api___.Text]);

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
              DoStatus('Sequenced notify api "%s" thread idle timeout, auto‑terminating', [app_and_api___.Text]);
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

  DisposeObject(Self);
end;

constructor TLF_Notify_Sequence_Thread.Create;
{ * Initialises the thread: creates critical section and queue, clears pool references. }
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
{ * Frees the queue and critical section. }
begin
  DisposeObjectAndNil(Queue_Tool);
  DisposeObjectAndNil(Critical);
  inherited Destroy;
end;

procedure TLF_Notify_Sequence_Thread.Run;
{ * Starts the thread via TCompute. }
begin
  if IsRunning then exit;
  Activted := True;
  TCompute.RunM_NP(Do_Run_Th, @IsRunning, @IsExit);
end;

procedure TLF_Notify_Sequence_Thread.Stop;
{ * Signals the thread to stop by setting Activted := False. }
begin
  if IsRunning then
      Activted := False;
end;

initialization

LF_DataPool := TLF_DataPool.Create;
LF_RunningCount := TAtomInt.Create(0);
LF_Notify_Sequence_Thread_Pool := TLF_Notify_Sequence_Thread_Pool.Create;

finalization

DisposeObjectAndNil(LF_RunningCount);
DisposeObjectAndNil(LF_DataPool);
DisposeObjectAndNil(LF_Notify_Sequence_Thread_Pool);

end.
