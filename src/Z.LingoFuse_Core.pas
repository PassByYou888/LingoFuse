{ *
  *  Z.LingoFuse_Core - Core RPC Framework for LingoFuse
  *  ====================================================
  *
  *  This unit provides the foundational, language-neutral RPC (Remote
  *  Procedure Call) engine for the LingoFuse distributed service framework.
  *  It defines the core data types, registration mechanisms, and execution
  *  logic for exposing and invoking APIs (both request-response calls and
  *  one-way notifications) within a single process.
  *
  *  The design is built around three primary concepts:
  *
  *    1. Application (TLF_App) - A named container that groups a set of
  *       related APIs. Each app has a unique name used for routing and
  *       discovery in a networked environment.
  *
  *    2. Engine (TLF_Engine) - The registry and executor. It maintains a
  *       thread-safe hash pool of registered APIs (TLF_MethodInfo) and
  *       provides methods to invoke them locally (Execute_Call and
  *       Execute_Notify). It also triggers update events when the API list
  *       changes.
  *
  *    3. Data Handle (TLF_Data) - An opaque handle that encapsulates either
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
  *  All registration and execution methods are thread-safe, making the
  *  framework suitable for multi-threaded server applications. However,
  *  individual data handles (TLF_Data) are not thread-safe; they must be
  *  used exclusively from one thread or protected by external
  *  synchronisation.
  *
  *  The unit is designed to be used both directly in native Pascal code and
  *  via the C ABI export layer (Z.LingoFuse_Export), allowing integration
  *  with other programming languages (C, C++, Python, etc.). It is also the
  *  foundation for the network-aware LingoFuse service and client components
  *  (Z.Net.C4.LingoFuse) that extend these capabilities over a distributed
  *  C4 service mesh.
  *
  *  Typical usage scenarios include:
  *    - Building modular applications with plug-in architectures.
  *    - Implementing microservices that expose RPC endpoints.
  *    - Creating distributed systems with ordered event processing.
  *    - Integrating with other languages via the C ABI layer.
  *
  *  Dependencies:
  *    - Z.Core          : Threading, containers, memory management, timers.
  *    - Z.PascalStrings : Pascal-style string handling.
  *    - Z.UPascalStrings: Unicode string utilities.
  *    - Z.Status        : Global logging and status reporting.
  *    - Z.UnicodeMixedLib: Miscellaneous helper functions.
  *    - Z.HashList.Templet: Thread-safe generic hash maps.
  *    - Z.MemoryStream  : TMem64 stream for binary data.
  *    - Z.Notify        : Timer subscription and delayed-free utilities.
  *    - Z.LingoFuse_Export: C ABI types for external language binding.
  *
  *  Key global objects:
  *    - LF_App_Pool                    : Tracks all TLF_App instances.
  *    - LF_DataPool                    : Automatically recycles idle data handles.
  *    - LF_DataMemory                  : Secondary memory pool for TLF_Data records.
  *    - LF_RunningCount                : Atomic counter of executing API calls.
  *    - LF_Notify_Sequence_Thread_Pool : Manages ordered notification threads.
  *
  *  For network-enabled operation, refer to the companion unit
  *  Z.Net.C4.LingoFuse, which integrates this core with the C4 service mesh.
  *
  *  @Version   Part of the LingoFuse framework (based on LingoFuse, but
  *             heavily extended and renamed). For details, see the project
  *             repository or documentation.
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
{$I ..\pascal\zNetV2\source\Z.Define.inc}

interface

uses
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status, Z.UnicodeMixedLib,
  Z.HashList.Templet, Z.MemoryStream, Z.Parsing, Z.Notify,
  Z.LingoFuse_Export, Z.Int128;

type
  { * Forward declaration of the application class, defined later. }
  TLF_App = class;

  { *
    * TLF_String: Unicode string type used for all textual identifiers.
    * Alias for TUPascalString, providing high-performance Unicode handling.
    * }
  TLF_String = TUPascalString;

  { *
    * TLF_Mode: Classification of an API operation.
    *   - LF_Unknow__ : Unspecified or error state.
    *   - LF_Call__   : Request-response style, expects a result.
    *   - LF_Notify__ : One-way message, no response.
    * }
  TLF_Mode = (
    LF_Unknow__ = 0,
    LF_Call__ = 1,
    LF_Notify__ = 2
    );

  { *
    * TMemory_Param_Tool: Packs/unpacks an API name and binary payload into
    * a TMem64.
    *
    * Wire format:
    *   [API name as Pascal string] + [4-byte payload size] + [payload bytes]
    *
    * Not thread-safe; create per thread or synchronise externally.
    *
    * @Field MethodName : Name of the target API.
    * @Field Param      : Binary payload.
    * @Constructor Create : Initialises empty fields and internal temp buffer.
    * @Destructor  Destroy: Frees Param and tmp.
    * @Method EncryptToMem   : Encodes MethodName and Param into a TMem64.
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
    *   Tool.Free;
    * }
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

  { *
    * TLF_MethodInfo: Metadata for a single registered API.
    * Stores name, description, mode, user trigger, and cdecl callback.
    * Used as value type in TLF_MethodPool.
    * }
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

  { *
    * TLF_MethodPool: Thread-safe hash map storing TLF_MethodInfo by API name.
    * Inherits from TCritical_String_Big_Hash_Pair_Pool.
    *
    * @Field APP : Back-reference to owning TLF_App.
    * @Method DoFree : Frees the TLF_MethodInfo on removal.
    * }
  TLF_MethodPool = class(TCritical_String_Big_Hash_Pair_Pool<TLF_MethodInfo>)
  public
    APP: TLF_App;
    procedure DoFree(var Key: SystemString; var Value: TLF_MethodInfo); override;
  end;

  { *
    * PLF_Data: Pointer to a TLF_Data record. Used as opaque handle
    * (TDataHnd___) in the C export layer.
    * }
  PLF_Data = ^TLF_Data;

  { *
    * TLF_DataOrder: FIFO queue that stores PLF_Data pointers.
    * Used internally for collection during pool cleanup.
    * }
  TLF_DataOrder = class(TOrderStruct<PLF_Data>);

  { *
    * TLF_DataMemory: Secondary memory pool for TLF_Data records.
    *
    * Reuses previously allocated TLF_Data records to reduce New/Dispose
    * frequency and avoid heap fragmentation. All operations are protected
    * by an internal critical section.
    * }
  TLF_DataMemory = class(TOrderStruct<PLF_Data>)
  public
    Critical__: TCritical;
    constructor Create;
    destructor Destroy; override;
    function Get_New_PLF_Data: PLF_Data;
    procedure Free_PLF_Data(p: PLF_Data);
    procedure Free_All_PLF_Data_Memory;
  end;

  { *
    * TLF_DataPool: Global pool that tracks all active TLF_Data handles.
    *
    * Progress() periodically scans the pool and performs three operations
    * on each tracked handle:
    *   - If updated___, refresh time___ and clear updated___.
    *   - If deleted___, collect for user-requested release.
    *   - If idle longer than LF_DataHandle_Idle_Timeout, collect for
    *     timeout release.
    *
    * The scan itself is rate-limited to at most one pass per
    * LF_DataHandle_Pool_Scan_Interval ticks. Both limits are per-instance
    * fields, so a host that instantiates its own TLF_DataPool can tune
    * them independently of the global LF_DataPool singleton.
    *
    * Collected handles are freed outside the pool lock to avoid holding it
    * during user callbacks.
    *
    * @Field LF_DataHandle_Pool_Scan_Interval
    *     Minimum interval between two consecutive scans, in ticks.
    *       >  0 : rate-limit enabled (default: 5 seconds).
    *       <= 0 : rate-limit disabled; every Progress() call scans.
    *
    * @Field LF_DataHandle_Idle_Timeout
    *     Idle-age threshold above which a tracked handle is collected for
    *     automatic release, in ticks.
    *       >  0 : timeout enabled (default: 10 minutes).
    *       <= 0 : timeout disabled; only deleted___ handles are released.
    *
    * @Method Progress    : Scans and frees idle or deleted handles.
    * @Method Free_All_Hnd: Frees all handles unconditionally (used at
    *                      shutdown / finalisation).
    * }
  TLF_DataPool = class(TBigList<PLF_Data>)
  private
    Last_Progress_Time__, Last_Check_Order_Time__: TTimeTick;
  public
    (*
      * LF_DataHandle_Pool_Scan_Interval
      * --------------------------------
      * Minimum interval (in ticks) between two consecutive scans of the
      * pool by Progress().
      *
      * Semantics:
      *   >  0 : ENABLED. Progress() returns immediately if less than this
      *          many ticks have elapsed since the last scan. The default
      *          (C_Tick_Second * 5) means "scan at most once every 5
      *          seconds".
      *
      *   <= 0 : DISABLED. Progress() scans on every call, without any
      *          rate-limiting. Use this only when Progress() is invoked
      *          at a known, low frequency; otherwise the pool lock is
      *          acquired far too often and throughput will suffer.
      *
      * Relationship with LF_DataHandle_Idle_Timeout:
      *   - This field controls HOW OFTEN the pool is scanned.
      *   - LF_DataHandle_Idle_Timeout controls WHEN a scanned handle is
      *     actually released.
      *   - A handle that becomes eligible at time T is typically released
      *     at T plus up to one scan interval of latency.
      *
      * Notes:
      *   - Progress() is driven by the simulated main thread (see
      *     Z.LingoFuse_Export.Simulated_Main_Thread). Its effective call
      *     frequency is therefore bounded below by the main thread's tick
      *     granularity, not by this value alone.
      *   - Setting this very low (< 1 second) is almost never useful: the
      *     pool lock and the O(N) walk dominate the cost, while the
      *     reclamation-latency improvement is negligible.
      *   - Value is expressed in TTimeTick units; use C_Tick_Second /
      *     C_Tick_Minute / C_Tick_Hour helpers to build it portably.
      *
      * Default: Z.Core.C_Tick_Second * 5 (5 seconds), set in Create.
    *)
    LF_DataHandle_Pool_Scan_Interval: TTimeTick;

    (*
      * LF_DataHandle_Idle_Timeout
      * --------------------------
      * Idle-age threshold (in ticks) used by Progress() to decide when an
      * unreferenced, un-deleted data handle should be automatically
      * reclaimed.
      *
      * Semantics:
      *   >  0 : ENABLED. A tracked handle whose last effective access is
      *          older than this many ticks is collected for automatic
      *          release. Any accessor call (Get_Size / Get_Pos /
      *          WriteBuff / ReadBuff / ...) refreshes the handle's
      *          last-access timestamp and postpones the timeout. A remote
      *          call in flight (calling___ > 0) also postpones it,
      *          regardless of idle time. The default
      *          (C_Tick_Second * 60 * 10) means "10 minutes".
      *
      *   <= 0 : DISABLED. The idle-timeout branch is skipped entirely;
      *          Progress() will only act on handles whose deleted___ flag
      *          was set by an explicit Free_Data call. Use this in hosts
      *          that manage handle lifetimes themselves and want
      *          deterministic release without a background sweep.
      *
      * Notes:
      *   - The scan itself still runs at
      *     LF_DataHandle_Pool_Scan_Interval. This field only controls the
      *     AGE at which a handle becomes a candidate.
      *   - Value is expressed in TTimeTick units (C_Tick_Second * 60 * 10,
      *     C_Tick_Minute * 10, C_Tick_Hour, etc.).
      *   - This threshold does NOT apply to handles created with
      *     auto_recycle___ = False; those are released synchronously by
      *     Free_Data and never enter the timeout path.
      *
      * Default: Z.Core.C_Tick_Second * 60 * 10 (10 minutes), set in Create.
    *)
    LF_DataHandle_Idle_Timeout: TTimeTick;
    constructor Create;
    destructor Destroy; override;
    procedure Progress;
    procedure Free_All_Hnd;
  end;

  { *
    * TLF_Data: Discriminated union representing an input parameter or output
    * result. Exactly one of Data_Param / Data_Result is non-nil at a time.
    *
    * Private bookkeeping fields:
    *   - auto_recycle___ : True  -> Free_Data only marks deleted___
    *                       False -> Free_Data releases the record immediately
    *   - deleted___      : Set by user-requested Free_Data; processed by
    *                       TLF_DataPool.Progress.
    *   - updated___      : Set by every accessor and by Update(); tells
    *                       Progress to refresh time___.
    *   - time___         : Timestamp of last effective access (used for the
    *                       10-minute idle timeout).
    *
    * Public accessors:
    *   @Method Init             : Resets all fields.
    *   @ClassMethod New_Param   : Creates input handle with given API name.
    *   @ClassMethod New_Param_From : Creates input by unpacking a packed
    *                                 TMem64.
    *   @ClassMethod New_Result  : Creates empty output handle.
    *   @ClassMethod New_Result_From: Creates output taking ownership of a
    *                                 TMem64.
    *   @ClassMethod Free_Data   : Requests release of the handle.
    *   @Method Update           : Marks the handle as recently used.
    *   @Method GetBuffer        : Returns raw data pointer (read-only).
    *   @Method WriteBuff        : Writes data at current position.
    *   @Method ReadBuff         : Reads data at current position.
    *   @Method Get_Pos          : Returns current position.
    *   @Method Set_Pos          : Sets current position.
    *   @Method Get_Size         : Returns total buffer size.
    *   @Method Set_Size         : Resizes buffer.
    * }
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
    class function New_Param(MethodName: TLF_String; auto_recycle____: boolean): PLF_Data; static;
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
  end;

  { *
    * TLF_Engine: Core API registry and execution engine.
    *
    * Maintains a thread-safe pool of registered APIs (TLF_MethodPool) and
    * executes them locally.
    *
    * @Field LF_MethodPool : Hash pool of registered APIs.
    * @Field APP           : Back-reference to owning TLF_App.
    * @Constructor Create  : Initialises the method pool.
    * @Destructor  Destroy : Frees the method pool.
    * @Method Reg_Call     : Registers a Call API.
    * @Method Reg_Notify   : Registers a Notify API.
    * @Method UnReg        : Unregisters an API by name.
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
    *   Eng.Free;
    * }
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

  { *
    * TOn_LFUpdate: Callback for application update events (API list changed).
    * @Param Sender : The TLF_App instance that changed.
    * }
  TOn_LFUpdate = procedure(Sender: TLF_App) of object;

  { *
    * TLF_UpdateEventPool: Thread-safe map storing TOn_LFUpdate callbacks
    * keyed by a binding object.
    * }
  TLF_UpdateEventPool = class(TCritical_Big_Hash_Pair_Pool<TCore_Object, TOn_LFUpdate>)
  end;

  { *
    * TLF_App: Logical application that exposes a set of APIs.
    *
    * Notifies subscribers when its API list changes. Update notifications
    * are coalesced by a 1-second timer to avoid flooding subscribers during
    * burst registrations.
    *
    * @Field Name   : Unique identifier (routing key).
    * @Field Desc   : Description.
    * @Field Engine : The API registry and execution engine.
    * @Constructor Create : Initialises engine, event pool, and 1-second
    *                       coalescing timer; registers itself in LF_App_Pool.
    * @Destructor  Destroy : Frees engine and event pool.
    * @Method FakeFree : Detaches the timer only (two-phase destruction step 1).
    * @Method DoChange : Marks as changed and resets the timer.
    * @Method Subscribe_Update : Registers a listener.
    * @Method Remove_Update    : Unregisters a listener.
    *
    * @Example:
    *   var App := TLF_App.Create;
    *   App.Name := 'MyApp';
    *   App.Engine.Reg_Call('ping', 'Ping', nil, MyPingCallback);
    *   App.Subscribe_Update(MyObj, MyUpdateHandler);
    * }
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
    constructor Create;
    destructor Destroy; override;
    procedure FakeFree;
    procedure DoChange();
    procedure Subscribe_Update(Bind: TCore_Object; OnUpdate: TOn_LFUpdate);
    procedure Remove_Update(Bind: TCore_Object);
  end;

  { *
    * TLF_App_Pool: Global list of all TLF_App instances.
    * DoFree releases the underlying TLF_App.
    * }
  TLF_App_Pool = class(TBigList<TLF_App>)
  public
    procedure DoFree(var Data: TLF_App); override;
  end;

  { * Forward declaration of the sequenced notification thread. }
  TLF_Notify_Sequence_Thread = class;

  { *
    * TLF_Notify_Sequence_Thread_Pool: Manages per-(app,api) threads for
    * ordered notifications.
    *
    * A thread is created on demand when the first notification for a given
    * key arrives, and it terminates itself after 5 minutes of inactivity.
    * All threads share this pool's critical section for lookup and insertion.
    *
    * @Method Get_Key_Hash : Computes the hash value for the given key.
    * @Method Compare_Key  : Compares two keys (case-insensitive).
    * @Method DoFree       : Cleans up the thread entry on removal.
    * @Method Post_Notify  : Posts a notification to the (app,api) thread.
    * @Method Post_Notify2 : Convenience wrapper that builds the key from
    *                       APP.Name + API name.
    * @Method Kill_App     : Terminates all threads belonging to an app.
    * @Method Stop         : Terminates all threads and clears the pool.
    * }
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

  { *
    * TNotify_Queue_Data: Pair of (TLF_App, TMem64) used in the
    * per-sequence notification queue.
    * }
  TNotify_Queue_Data = TPair2<TLF_App, TMem64>;

  { *
    * TNotify_Queue_Tool: FIFO queue for TNotify_Queue_Data.
    * Overrides DoFree to release the TMem64 payload while leaving the
    * TLF_App reference untouched (the app is owned by LF_App_Pool).
    * }
  TNotify_Queue_Tool = class(TOrderStruct<TNotify_Queue_Data>)
  public
    procedure DoFree(var Data: TNotify_Queue_Data); override;
  end;

  { *
    * TLF_Notify_Sequence_Thread: Dedicated thread that processes notifications
    * for one (app,api) pair in strict FIFO order.
    *
    * Lifecycle:
    *   - Created on demand by TLF_Notify_Sequence_Thread_Pool.Post_Notify.
    *   - Runs Do_Run_Th, which drains its private queue in a loop.
    *   - Terminates automatically after 5 minutes of inactivity.
    *   - On termination, removes itself from the pool and schedules itself
    *     for delayed release (DelayFreeObj with a 5-second grace period) so
    *     that the surrounding TCompute machinery can finish writing the
    *     IsRunning / IsExit flags before the object is destroyed.
    *
    * @Field Queue_Tool : FIFO queue of pending notifications.
    * @Field APP        : The owning application.
    * @Field Critical   : Lock protecting Queue_Tool.
    * @Constructor Create : Allocates the queue and critical section.
    * @Destructor  Destroy: Frees the queue and critical section.
    * @Method Run  : Starts the worker thread.
    * @Method Stop : Requests termination (asynchronous).
    * }
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

var
  LF_App_Pool: TLF_App_Pool;
  { * LF_DataPool: Global pool for automatic recycling of TLF_Data handles. }
  LF_DataPool: TLF_DataPool;
  { * LF_DataMemory: Secondary memory pool for TLF_Data records. }
  LF_DataMemory: TLF_DataMemory;
  { * LF_RunningCount: Atomic counter of active API calls. }
  LF_RunningCount: TAtomInt;
  { * LF_Notify_Sequence_Thread_Pool: Global pool for sequenced notification
    * threads. }
  LF_Notify_Sequence_Thread_Pool: TLF_Notify_Sequence_Thread_Pool;

implementation

{ ----------------------------------------------------------------------------
  TMemory_Param_Tool
  ---------------------------------------------------------------------------- }

{ *
  * Initialises the tool with an empty MethodName, an empty Param buffer,
  * and a private temporary buffer used during decoding.
  * }
constructor TMemory_Param_Tool.Create;
begin
  inherited Create;
  tmp := TMem64.Create;
  MethodName := '';
  Param := TMem64.Create;
end;

{ *
  * Frees the Param payload and the internal temporary buffer.
  * }
destructor TMemory_Param_Tool.Destroy;
begin
  DisposeObject(Param);
  DisposeObject(tmp);
  inherited Destroy;
end;

{ *
  * Encodes MethodName and Param into the destination TMem64.
  *
  * The wire format is:
  *   [Pascal-string MethodName] [Int32 payload size] [raw payload bytes]
  *
  * The destination buffer is cleared first.
  * }
procedure TMemory_Param_Tool.EncryptToMem(m64: TMem64);
begin
  m64.Clear;
  m64.WriteString(MethodName.Text);
  m64.WriteInt32(Param.Size);
  m64.WritePtr(Param.Memory, Param.Size);
end;

{ *
  * Decodes a packed TMem64 back into MethodName and Param.
  *
  * Two paths are used depending on m64.ProtectedMode:
  *   - Protected (read-only): reads in-place, only Position is modified.
  *   - Unprotected: swaps the source buffer into tmp (taking ownership),
  *     then creates Param as a zero-copy mapping over tmp. After this call,
  *     the original m64 is empty; tmp holds the actual storage.
  * }
procedure TMemory_Param_Tool.DecryptFromMem(m64: TMem64);
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

{ *
  * Extracts only the API name from a packed TMem64, leaving the position
  * unchanged. Does not modify the contents of m64.
  * }
class function TMemory_Param_Tool.Get_apiName(m64: TMem64): TLF_String;
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

{ *
  * Initialises all fields to default empty values.
  * Mode is set to LF_Unknow__ until Reg_Call / Reg_Notify sets it.
  * }
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

{ ----------------------------------------------------------------------------
  TLF_MethodPool
  ---------------------------------------------------------------------------- }

{ *
  * Overridden to free the TLF_MethodInfo object when an entry is removed.
  * The Key string itself is freed automatically by the parent class.
  * }
procedure TLF_MethodPool.DoFree(var Key: SystemString; var Value: TLF_MethodInfo);
begin
  DisposeObjectAndNil(Value);
  inherited;
end;

{ ----------------------------------------------------------------------------
  TLF_DataMemory
  ---------------------------------------------------------------------------- }

{ *
  * Creates the internal critical section.
  * }
constructor TLF_DataMemory.Create;
begin
  inherited Create;
  Critical__ := TCritical.Create('TLF_DataMemory.Critical__');
end;

{ *
  * Releases all pooled TLF_Data records and the critical section.
  * }
destructor TLF_DataMemory.Destroy;
begin
  Free_All_PLF_Data_Memory();
  DisposeObject(Critical__);
  inherited Destroy;
end;

{ *
  * Returns a TLF_Data record from the pool if available; otherwise
  * allocates a fresh one via New(). The record's fields are not
  * initialised here; the caller must invoke Init.
  * }
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

{ *
  * Pushes a TLF_Data record back into the pool for future reuse.
  * The record is not freed here.
  * }
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

{ *
  * Physically disposes every TLF_Data record currently in the pool and
  * empties the pool. Called at unit finalisation.
  * }
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

{ ----------------------------------------------------------------------------
  TLF_DataPool
  ---------------------------------------------------------------------------- }

{ *
  * Initialises the last-progress timestamp to the current tick.
  * }
constructor TLF_DataPool.Create;
begin
  inherited Create;
  Last_Progress_Time__ := GetTimeTick();
  LF_DataHandle_Pool_Scan_Interval := Z.Core.C_Tick_Second * 5;
  LF_DataHandle_Idle_Timeout := Z.Core.C_Tick_Second * 60 * 10;
end;

{ *
  * Performs a final cleanup of all tracked handles.
  * }
destructor TLF_DataPool.Destroy;
begin
  Free_All_Hnd();
  inherited Destroy;
end;

{ *
  * Scans the pool and releases handles under three conditions:
  *   1. updated___ is True  -> refresh time___ and clear the flag.
  *   2. deleted___ is True  -> collect for user-requested release.
  *   3. Idle > 10 minutes   -> collect for timeout release.
  *
  * Runs at most once every 5 seconds. Collected handles are freed outside
  * the pool lock so that user callbacks (if any) do not deadlock.
  *
  * Timeout releases are logged; the number of recycled handles is capped
  * in the log output to avoid flooding.
  * }
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
                L.Push(queue^.Data); // user-requested release
                Push_To_Recycle_Pool(queue);
              end
            else if (tk - queue^.Data^.time___ > LF_DataHandle_Idle_Timeout) then
              begin
                timeout_data.Push(queue^.Data); // idle timeout release
                Push_To_Recycle_Pool(queue);
              end;
          until not Next;
      end;
    Free_Recycle_Pool;
  finally
      UnLock;
  end;

  while L.Num > 0 do // user-requested release
    begin
      TLF_Data.Free_Data___(L.First^.Data);
      L.Next;
    end;
  DisposeObject(L);

  if timeout_data.Num > 0 then // idle timeout release
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
  DisposeObject(timeout_data);
end;

{ *
  * Unconditionally releases every tracked handle. Used at shutdown and
  * finalisation to guarantee no leaks regardless of the idle timer state.
  * }
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
end;

{ ----------------------------------------------------------------------------
  TLF_Data
  ---------------------------------------------------------------------------- }

{ *
  * Internal release routine. Detaches Data_Param / Data_Result and returns
  * the TLF_Data record to the LF_DataMemory pool for future reuse.
  * }
class procedure TLF_Data.Free_Data___(hnd: PLF_Data);
begin
  if hnd = nil then exit;
  hnd^.Data_Info := '';
  DisposeObjectAndNil(hnd^.Data_Param);
  DisposeObjectAndNil(hnd^.Data_Result);
  DisposeObjectAndNil(hnd^.calling___);
  LF_DataMemory.Free_PLF_Data(hnd);
end;

{ *
  * Resets the record to its initial state. Called by every constructor.
  * }
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

{ *
  * Creates a new input parameter handle bound to the given API name.
  * The handle is registered in the global pool for automatic recycling.
  * }
class function TLF_Data.New_Param(MethodName: TLF_String; auto_recycle____: boolean): PLF_Data;
var
  p: PLF_Data;
begin
  p := LF_DataMemory.Get_New_PLF_Data;
  p^.Init;
  p^.Data_Param := TMemory_Param_Tool.Create;
  p^.Data_Param.MethodName := MethodName;
  p^.Data_Info := PFormat('api "%s" parameter.', [MethodName.Text]);

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
end;

{ *
  * Creates an input handle by unpacking a packed TMem64.
  *
  * If auto_recycle____ is True, the handle is registered in the global pool
  * for automatic recycling. If False, the handle is not tracked and the
  * caller is expected to release it via Free_Data.
  * }
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
end;

{ *
  * Creates a new empty output handle with a fresh TMem64 buffer.
  *
  * If auto_recycle____ is True, the handle is registered in the global pool
  * for automatic recycling.
  * }
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
end;

{ *
  * Creates an output handle that takes ownership of the supplied TMem64.
  * The handle is always registered in the global pool for automatic
  * recycling. The TMem64 position is reset to zero.
  * }
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
end;

{ *
  * Requests the release of a data handle.
  *
  * If auto_recycle___ is True, only the deleted___ flag is set and the
  * actual release is deferred to TLF_DataPool.Progress (at most 5 seconds).
  * If auto_recycle___ is False, the handle is released immediately.
  * }
class procedure TLF_Data.Free_Data(hnd: PLF_Data);
begin
  if hnd = nil then exit;
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

{ *
  * Returns a pointer to the raw data buffer, or nil if the handle is empty.
  * The pointer is valid until the buffer is resized or the handle is freed.
  * Marks the handle as recently used.
  * }
function TLF_Data.GetBuffer: Pointer;
begin
  Result := nil;
  if Data_Param <> nil then
      Result := Data_Param.Param.Memory
  else if Data_Result <> nil then
      Result := Data_Result.Memory;
  updated___ := True;
end;

{ *
  * Writes data at the current position. The buffer grows automatically as
  * needed. Returns the number of bytes written. Marks the handle as
  * recently used.
  * }
function TLF_Data.WriteBuff(Buff: Pointer; Size: Int64): Int64;
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.WritePtr(Buff, Size)
  else if Data_Result <> nil then
      Result := Data_Result.WritePtr(Buff, Size);
  updated___ := True;
end;

{ *
  * Reads data at the current position. Returns the number of bytes actually
  * read (may be less than Size at EOF). Marks the handle as recently used.
  * }
function TLF_Data.ReadBuff(Buff: Pointer; Size: Int64): Int64;
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.ReadPtr(Buff, Size)
  else if Data_Result <> nil then
      Result := Data_Result.ReadPtr(Buff, Size);
  updated___ := True;
end;

{ *
  * Returns the current read/write position. Marks the handle as recently
  * used.
  * }
function TLF_Data.Get_Pos: Int64;
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.Position
  else if Data_Result <> nil then
      Result := Data_Result.Position;
  updated___ := True;
end;

{ *
  * Sets the current read/write position. If the new position exceeds the
  * current size, the buffer is extended. Marks the handle as recently used.
  * }
procedure TLF_Data.Set_Pos(Pos_: Int64);
begin
  if Data_Param <> nil then
      Data_Param.Param.Position := Pos_
  else if Data_Result <> nil then
      Data_Result.Position := Pos_;
  updated___ := True;
end;

{ *
  * Returns the total size of the buffer in bytes. Marks the handle as
  * recently used.
  * }
function TLF_Data.Get_Size: Int64;
begin
  Result := 0;
  if Data_Param <> nil then
      Result := Data_Param.Param.Size
  else if Data_Result <> nil then
      Result := Data_Result.Size;
  updated___ := True;
end;

{ *
  * Resizes the buffer. If enlarged, the newly added space is left
  * uninitialised. Marks the handle as recently used.
  * }
procedure TLF_Data.Set_Size(Size_: Int64);
begin
  if Data_Param <> nil then
      Data_Param.Param.Size := Size_
  else if Data_Result <> nil then
      Data_Result.Size := Size_;
  updated___ := True;
end;

{ ----------------------------------------------------------------------------
  TLF_Engine
  ---------------------------------------------------------------------------- }

{ *
  * Creates the method pool with 255 buckets. The APP back-reference is set
  * by TLF_App.Create.
  * }
constructor TLF_Engine.Create;
begin
  inherited Create;
  LF_MethodPool := TLF_MethodPool.Create($FF, nil);
  LF_MethodPool.APP := nil;
end;

{ *
  * Frees the method pool.
  * }
destructor TLF_Engine.Destroy;
begin
  DisposeObject(LF_MethodPool);
  inherited Destroy;
end;

{ *
  * Registers a Call-mode API.
  *
  * Returns True on success. If MethodName already exists, no change is made
  * and False is returned.
  * }
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
end;

{ *
  * Registers a Notify-mode API.
  *
  * Returns True on success. If MethodName already exists, no change is made
  * and False is returned.
  * }
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
end;

{ *
  * Unregisters an API by name. Returns True if the API existed and was
  * removed.
  * }
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
end;

{ *
  * Executes a Call API synchronously. Returns a new TMem64 with the result.
  *
  * The input and output TLF_Data handles are created with auto_recycle___
  * = False, meaning they are released immediately after this function
  * returns. The output TMem64 is transferred to Result via SwapInstance
  * before the output handle is freed, so the result survives.
  *
  * A backup of both handles is taken before the callback and restored
  * afterwards, protecting against callbacks that carelessly mutate the
  * record's pointer fields.
  *
  * LF_RunningCount is incremented on entry and decremented on exit so that
  * the simulated main thread can adjust its polling strategy.
  * }
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

{ *
  * Executes a Notify API synchronously. No result is produced.
  *
  * If the API was registered as Call, a warning is printed and the Call
  * handler is invoked with the output discarded. The input handle is freed
  * on exit.
  * }
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

{ *
  * Broadcasts an update notification to every subscriber.
  * Runs on the main thread (posted by DoTimer via MainThreadPost).
  * Individual subscriber exceptions are swallowed.
  * }
procedure TLF_App.Do_LFRegEvent;
begin
  FUpdateEventPool.Lock;
  if FUpdateEventPool.Num > 0 then
    with FUpdateEventPool.repeat_ do
      repeat
        try
          if Assigned(queue^.Data^.Data.Second) then
              queue^.Data^.Data.Second(self);
        except
        end;
      until not Next;
  FUpdateEventPool.UnLock;
end;

{ *
  * Timer callback for coalescing update notifications.
  * If FUpdated is True, schedules Do_LFRegEvent on the main thread and
  * clears the flag. Runs on the timer thread.
  * }
procedure TLF_App.DoTimer;
begin
  if FUpdated then
    begin
      MainThreadPost.PostM_NP(Do_LFRegEvent);
      FUpdated := False;
    end;
end;

{ *
  * Creates a new TLF_App.
  *
  * Installs a 1-second coalescing timer for update notifications and
  * registers the new instance in LF_App_Pool.
  * }
constructor TLF_App.Create;
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

  LF_App_Pool.Lock;
  try
      LF_App_Pool.Add(self);
  finally
      LF_App_Pool.UnLock;
  end;
end;

{ *
  * Full destruction: removes the timer, frees the engine and the update
  * event pool.
  * }
destructor TLF_App.Destroy;
begin
  Remove_Timer(self);
  DisposeObject(Engine);
  DisposeObject(FUpdateEventPool);
  inherited Destroy;
end;

{ *
  * First phase of two-phase destruction. Only removes the coalescing timer;
  * does NOT release the engine or the update event pool. The actual release
  * is deferred to LF_Shutdown, which clears LF_App_Pool.
  * }
procedure TLF_App.FakeFree;
begin
  Remove_Timer(self);
end;

{ *
  * Marks the app as changed and resets the coalescing timer.
  * The subscriber notification fires at most 1 second later.
  * }
procedure TLF_App.DoChange();
begin
  FUpdated := True;
  Reset_Timer(self);
end;

{ *
  * Registers or replaces a listener for update notifications.
  * If Bind already has a registered callback, it is overwritten.
  * }
procedure TLF_App.Subscribe_Update(Bind: TCore_Object; OnUpdate: TOn_LFUpdate);
begin
  FUpdateEventPool.Add(Bind, OnUpdate, True);
end;

{ *
  * Unregisters the listener identified by Bind.
  * }
procedure TLF_App.Remove_Update(Bind: TCore_Object);
begin
  FUpdateEventPool.Delete(Bind);
end;

{ *
  * Releases a TLF_App instance when it is removed from the pool.
  * }
procedure TLF_App_Pool.DoFree(var Data: TLF_App);
begin
  DisposeObjectAndNil(Data);
  inherited DoFree(Data);
end;

{ ----------------------------------------------------------------------------
  TLF_Notify_Sequence_Thread_Pool
  ---------------------------------------------------------------------------- }

{ *
  * Creates the pool with 255 buckets.
  * }
constructor TLF_Notify_Sequence_Thread_Pool.Create;
begin
  inherited Create($FF, nil);
end;

{ *
  * Computes a 32-bit hash for the given key.
  * Two-stage: FastHashPPascalString then CRC32 of the result, ensuring
  * uniform distribution across the 255 buckets.
  * }
function TLF_Notify_Sequence_Thread_Pool.Get_Key_Hash(const Key_: TLF_String): THash;
begin
  Result := FastHashPPascalString(@Key_);
  Result := Get_CRC32(@Result, SizeOf(THash));
end;

{ *
  * Compares two keys using TLF_String.Same, which is case-insensitive.
  * }
function TLF_Notify_Sequence_Thread_Pool.Compare_Key(const Key_1, Key_2: TLF_String): boolean;
begin
  Result := Key_1.Same(@Key_2);
end;

{ *
  * Clears the key and thread reference when an entry is removed.
  * The thread itself is released by its own Do_Run_Th upon termination.
  * }
procedure TLF_Notify_Sequence_Thread_Pool.DoFree(var Key: TLF_String; var Value: TLF_Notify_Sequence_Thread);
begin
  Key := '';
  Value := nil;
  inherited;
end;

{ *
  * Posts a notification to the per-key thread.
  *
  * If no thread exists for Name_, one is created and started. The payload
  * is then pushed to that thread's queue. If the existing thread belongs to
  * a different TLF_App, the notification is rejected with a log message
  * (the key is considered to be owned by exactly one app).
  * }
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
end;

{ *
  * Convenience wrapper around Post_Notify.
  * The key is constructed as 'AppName.ApiName' so that a distinct thread
  * is maintained per (application, API) pair.
  * }
procedure TLF_Notify_Sequence_Thread_Pool.Post_Notify2(const APP: TLF_App; Memory_Param: TMem64);
begin
  Post_Notify(PFormat('%s.%s', [APP.Name.Text, TMemory_Param_Tool.Get_apiName(Memory_Param).Text]), APP, Memory_Param);
end;

{ *
  * Terminates every thread currently owned by the given app and removes
  * the corresponding pool entries. The threads themselves are scheduled for
  * delayed release by their own Do_Run_Th.
  * }
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
end;

{ *
  * Terminates every thread in the pool and empties the pool. Called by
  * LF_Shutdown and by the simulated main thread during its exit sequence.
  * }
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
end;

{ ----------------------------------------------------------------------------
  TNotify_Queue_Tool
  ---------------------------------------------------------------------------- }

{ *
  * Releases the TMem64 payload when the queue item is removed.
  * The TLF_App reference is intentionally left untouched; the app is owned
  * by LF_App_Pool.
  * }
procedure TNotify_Queue_Tool.DoFree(var Data: TNotify_Queue_Data);
begin
  Data.Primary := nil;
  DisposeObjectAndNil(Data.Second);
  inherited;
end;

{ ----------------------------------------------------------------------------
  TLF_Notify_Sequence_Thread
  ---------------------------------------------------------------------------- }

{ *
  * Main thread body. Drains the queue in strict FIFO order, executing each
  * notification via its target app's engine.
  *
  * The queue is periodically exchanged with an empty local queue under the
  * critical section, so the lock is held only for the swap and not during
  * user callbacks.
  *
  * After 5 minutes without any queued item, the thread sets Activted to
  * False and exits. On exit it removes itself from the parent pool and
  * schedules itself for delayed release (5-second grace period) so that the
  * surrounding TCompute machinery can finish writing the IsRunning and
  * IsExit flags before the object is destroyed.
  * }
procedure TLF_Notify_Sequence_Thread.Do_Run_Th;
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
              DoStatus('Sequenced notify api "%s" thread idle timeout, auto-terminating', [app_and_api___.Text]);
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

  // Schedule self-release after a 5-second grace period so that TCompute
  // can safely write back the IsRunning / IsExit flags before the object
  // is destroyed.
  DelayFreeObj(5.0, self);
end;

{ *
  * Allocates the critical section and the queue, and resets all state.
  * The APP and pool back-references are set by Post_Notify.
  * }
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

{ *
  * Frees the queue and the critical section.
  * }
destructor TLF_Notify_Sequence_Thread.Destroy;
begin
  DisposeObjectAndNil(Queue_Tool);
  DisposeObjectAndNil(Critical);
  inherited Destroy;
end;

{ *
  * Starts the worker thread via TCompute.
  * Does nothing if the thread is already running.
  * }
procedure TLF_Notify_Sequence_Thread.Run;
begin
  if IsRunning then exit;
  Activted := True;
  TCompute.RunM_NP(Do_Run_Th, @IsRunning, @IsExit);
end;

{ *
  * Requests thread termination. The thread will exit at the next iteration
  * of its main loop. This method does not wait for the thread to finish.
  * }
procedure TLF_Notify_Sequence_Thread.Stop;
begin
  if IsRunning then
      Activted := False;
end;

initialization

LF_App_Pool := TLF_App_Pool.Create;
LF_DataPool := TLF_DataPool.Create;
LF_DataMemory := TLF_DataMemory.Create;
LF_RunningCount := TAtomInt.Create(0);
LF_Notify_Sequence_Thread_Pool := TLF_Notify_Sequence_Thread_Pool.Create;

finalization

DisposeObjectAndNil(LF_RunningCount);
DisposeObjectAndNil(LF_DataPool);
DisposeObjectAndNil(LF_DataMemory);
DisposeObjectAndNil(LF_Notify_Sequence_Thread_Pool);
DisposeObjectAndNil(LF_App_Pool);

end.
