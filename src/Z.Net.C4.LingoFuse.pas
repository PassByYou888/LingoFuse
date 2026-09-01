{ *
  * Z.Net.C4.LingoFuse – Distributed LingoFuse RPC over the C4 Service Mesh
  * ======================================================================
  *
  * This unit bridges the LingoFuse core RPC framework (Z.LingoFuse_Core) with
  * the C4 distributed service mesh (Z.Net.C4). It provides service-side
  * (TC40_LF_Service) and client-side (TC40_LF_Client) components that enable
  * applications to expose and call APIs (both Call and Notify modes) across
  * a network. Communication uses C4's P2PVM double‑tunnel infrastructure with
  * no authentication (NoAuth model), making it easy to deploy in trusted
  * environments.
  *
  * Key Concepts:
  *   – Application (TLF_App): A named container of APIs, defined in
  *     Z.LingoFuse_Core. Each app has a unique name and a set of registered
  *     Call/Notify APIs.
  *   – LingoFuse Service (TC40_LF_Service): Runs on a C4 PhysicsService.
  *     It accepts client connections, maintains a registry of all connected
  *     applications (APP_Name, description, process info, and list of exported
  *     API names), and routes incoming calls/notifications to the appropriate
  *     client instance. It also broadcasts a global service-info snapshot to
  *     all clients periodically.
  *   – LingoFuse Client (TC40_LF_Client): Connects to a LingoFuse Service.
  *     It can host a local TLF_App (set via the APP property) and automatically
  *     registers it with the service upon connection. It can also call remote
  *     applications (Wait_Execute_Call) and send notifications
  *     (Send_Execute_Notify), with an optimisation that executes locally if a
  *     matching application is found in the same process.
  *   – Sequenced Notifications: For notifications that must be delivered in
  *     order, the system uses a global thread pool
  *     (LF_Notify_Sequence_Thread_Pool) that ensures FIFO delivery per
  *     (application, API) pair. The service and client provide methods for
  *     sequenced notifications (Send_Sequenced_Notify, cmd_Sequenced_Notify)
  *     that route to the appropriate sequenced thread.
  *   – Load Balancing: The service uses a 'last selected time' heuristic to
  *     choose among multiple clients that host the same application, ensuring
  *     fair distribution. For sequenced notifications, it picks the client
  *     with the oldest timestamp for the specific (app, api) pair, thus
  *     distributing load.
  *
  * Architecture:
  *   Service side:
  *     - TC40_LF_Service inherits from TC40_Base_NoAuth_Service (C4 no‑auth).
  *     - Each connected client is represented by a TC40_LF_RecvTunnel object,
  *       which stores the application registration data.
  *     - The service periodically broadcasts a snapshot of all registered
  *       applications (via Broadcast_API_Info) to all clients.
  *     - Incoming 'Notify', 'Sequenced_Notify', and 'Call' commands are
  *       routed: first check for a local (same‑process) client via the global
  *       Find_Local_* functions; if not found, forward to another service
  *       instance or to a client on the same service.
  *   Client side:
  *     - TC40_LF_Client inherits from TC40_Base_NoAuth_Client.
  *     - It holds a TLF_App instance (APP property). When the client connects,
  *       it sends the app's registration (Init_App_Info) to the service.
  *     - It maintains a local cache of service info (TLF_ServiceInfoPool)
  *       received via broadcasts.
  *     - For calls/notifications, it first looks for a local app via the
  *       global Find_Local_* functions; if found, it executes directly
  *       (bypassing the network). Otherwise, it sends the request to the
  *       service.
  *
  * Thread Safety:
  *   - The service and client components are designed for use in a single
  *     thread (the C4 progress loop). Callbacks from the core engine
  *     (Execute_Call/Execute_Notify) may run in background threads
  *     (via HPC workers), so user callbacks must be thread‑safe and should
  *     not block.
  *   - Do not call Wait_Execute_Call inside a callback (risk of deadlock).
  *
  * Dependencies:
  *   - Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status, Z.UnicodeMixedLib,
  *     Z.ListEngine, Z.DFE, Z.MemoryStream, Z.HashList.Templet, etc.
  *   - Z.Net.C4 (C4 framework) and Z.Net.DoubleTunnelIO.NoAuth.
  *   - Z.LingoFuse_Core (the core RPC engine).
  *
  * Typical Usage:
  *
  * 1. On the service side (e.g., inside a C4 PhysicsService):
  *    PhysicsService.BuildDependNetwork('LingoFuse');
  *    // This creates an instance of TC40_LF_Service automatically.
  *
  * 2. On the client side (e.g., inside a C4 PhysicsTunnel):
  *    var
  *      App: TLF_App;
  *      Client: TC40_LF_Client;
  *    begin
  *      App := TLF_App.Create;
  *      App.Name := 'MyApp';
  *      App.Engine.Reg_Call('echo', 'Echo service', nil, MyEchoCallback);
  *      // After obtaining the client instance (e.g., from the tunnel's
  *      // DependNetworkClientPool), set the APP property:
  *      Client.APP := App;   // automatically registers with the service
  *    end;
  *
  * 3. To call a remote API:
  *    var
  *      Param, Result: TMem64;
  *    begin
  *      Param := TMem64.Create;
  *      // Pack the API name and parameters using TMemory_Param_Tool
  *      // ...
  *      Result := Client.Wait_Execute_Call('RemoteApp', Param, 5000);
  *      if Result <> nil then
  *        // process result
  *      DisposeObject(Result);
  *    end;
  *
  * 4. To send a sequenced notification:
  *    Client.Send_Sequenced_Notify('Logger', Param);  // Param consumed.
  *
  * For more details, see the unit-level documentation and the comments for
  * each class and method.
  * }
unit Z.Net.C4.LingoFuse;

{$DEFINE FPC_DELPHI_MODE}
{$I ..\pascal\zNetV2\source\Z.Define.inc}

interface

uses
{$IFDEF FPC}
  SysUtils,
  Z.FPC.GenericList,
{$ELSE FPC}
{$IFDEF MSWINDOWS}
  Windows,
{$ELSE}
  Posix.Unistd,
{$ENDIF}
{$ENDIF FPC}
  Variants, Math,
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status, Z.UnicodeMixedLib,
  Z.ListEngine, Z.Geometry2D, Z.DFE, Z.Json, Z.Expression, Z.OpCode, Z.Notify,
  Z.Cipher, Z.MemoryStream, Z.Int128, Z.HashList.Templet,
  Z.Net, Z.Net.PhysicsIO, Z.Net.DoubleTunnelIO.NoAuth, Z.Net.C4,
  Z.LingoFuse_Core;

type
  { Forward declarations }
  TC40_LF_Service = class;
  TFixed_Sequenced_Notify_Pool = class(TString_Big_Hash_Pair_Pool<TTimeTick>);

  { * TC40_LF_RecvTunnel: Per‑connection user‑defined object attached to the
    * receive tunnel on the service side. It stores the registration information
    * of the application hosted by the connected client, as well as runtime data
    * for load balancing and sequenced notification tracking.
    *
    * @Field Last_Selected_Time : Timestamp of the last time this tunnel was
    *        selected for routing a call/notification (used for load balancing).
    * @Field Fixed_Sequenced_Notify_Pool : Hash pool mapping "(app, api)" keys
    *        to the last time a sequenced notification was sent through this
    *        tunnel. Used to select the least recently used client for
    *        sequenced notifications.
    * @Field Temp_Fixed_Sequenced_Value : Temporary storage used during sorting
    *        to hold the last sequenced time for the current (app, api).
    * @Field LF_Service : Back‑reference to the owning service.
    * @Field APP_Name : Name of the application registered by this client.
    * @Field APP_Desc : Description of the application.
    * @Field APP_Process_Info : Process identifier string (e.g., "MyApp(1234)").
    * @Field api_info_data : Hash list where keys are the names of exported APIs.
    * @Field Host_Running_Thread_Num : Number of threads currently executing
    *        requests on behalf of this client (for load balancing).
    * @Field Wait_Reponse_Thread_Num : Number of threads waiting for remote
    *        responses (for load balancing).
    * @Field Is_Local : True if the client is connected via IPC or local network. }
  TC40_LF_RecvTunnel = class(TService_RecvTunnel_UserDefine_NoAuth)
  private
    Last_Selected_Time: TTimeTick;
    Fixed_Sequenced_Notify_Pool: TFixed_Sequenced_Notify_Pool;
    Temp_Fixed_Sequenced_Value: TTimeTick;
  public
    LF_Service: TC40_LF_Service;
    APP_Name: TLF_String;
    APP_Desc: TLF_String;
    APP_Process_Info: TLF_String;
    api_info_data: THashList;
    Host_Running_Thread_Num: Integer;
    Wait_Reponse_Thread_Num: Integer;
    Is_Local: Boolean;
    constructor Create(Owner_: TPeerIO); override;
    destructor Destroy; override;
  end;

  TC40_LF_RecvTunnelList = class(TBigList<TC40_LF_RecvTunnel>)
  end;

  { * TLF_ServiceInfo: A snapshot of a client's application registration,
    * used for broadcasting to other clients and for local caching.
    * It mirrors the fields of TC40_LF_RecvTunnel but is serialisable for
    * network transmission. }
  TLF_ServiceInfo = class
  public
    APP_Name: TLF_String;
    APP_Desc: TLF_String;
    APP_Process_Info: TLF_String;
    api_info_data: THashList;
    Host_Running_Thread_Num: Integer;
    Wait_Reponse_Thread_Num: Integer;
    Is_Local: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Assign(source: TC40_LF_RecvTunnel);
    procedure SaveToStream(stream: TCore_Stream);
    procedure LoadFromStream(stream: TCore_Stream);
  end;

  { * TLF_ServiceInfoPool: A list of TLF_ServiceInfo objects, used to build
    * and broadcast a complete registry of all applications connected to a
    * service. Inherits from TBig_Object_List for automatic memory management. }
  TLF_ServiceInfoPool = class(TBig_Object_List<TLF_ServiceInfo>)
  public
    constructor Create;
    destructor Destroy; override;
    procedure Build_Info_Form(Inst: TC40_LF_RecvTunnel);
    procedure SaveToStream(d: TDFE);
    procedure LoadFromStream(d: TDFE);
    function Find_API(app_Name__, api_Name__: TLF_String): Boolean;
    function Find_APP(app_Name__: TLF_String): Boolean;
  end;

  { * TC40_LF_SendTunnel: Per‑connection user‑defined object for the send
    * tunnel on the service side. Holds a back‑reference to the owning service. }
  TC40_LF_SendTunnel = class(TService_SendTunnel_UserDefine_NoAuth)
  public
    LF_Service: TC40_LF_Service;
    constructor Create(Owner_: TPeerIO); override;
    destructor Destroy; override;
  end;

  { * TC40_LF_Service: The LingoFuse service that runs on a C4 PhysicsService.
    * It accepts client connections, maintains a registry of all connected
    * applications, and routes incoming calls/notifications to the correct
    * destination. It also broadcasts a global service‑info snapshot to all
    * clients periodically.
    *
    * Routing logic:
    *   1. For a 'Call' or 'Notify', it first looks for a local (same‑process)
    *      client that hosts the target application and API via
    *      Find_Local_API. If found, it executes locally (bypassing the network)
    *      for optimal performance.
    *   2. Otherwise, it scans all connected clients on this service instance
    *      (using Find_API) and forwards to the first matching client. It also
    *      forwards to other service instances (via the C40_ServicePool) if
    *      needed.
    *   3. For sequenced notifications, it uses Find_Fixed_Sequenced_Local_API
    *      or Find_Fixed_Sequenced_Remote_API to choose a client based on the
    *      least‑recently‑used timestamp for the (app, api) pair, ensuring
    *      that notifications for the same pair are serialised.
    *
    * @Field FDelay_Broadcast_API_Info_Time : Earliest time when the next
    *        broadcast is allowed (used for coalescing).
    * @Field FNeed_Broadcast_API_Info : Flag indicating a broadcast is pending.
    * @Constructor Create : Sets up the service with custom user‑defined classes,
    *        configures buffer sizes, and registers command handlers.
    * @Destructor Destroy : Inherited, frees resources.
    * @Method Progress : Drives the network and triggers broadcast when ready.
    * @Method Broadcast_API_Info : Builds a snapshot of all registered
    *        applications and sends it to all connected clients.
    * @Method Find_API : Scans all connected clients and returns the first
    *        matching receive tunnel for the given app and API.
    * @Method Find_Fixed_Sequenced_API : Same as Find_API but uses the
    *        least‑recently‑used timestamp to choose among multiple clients. }
  TC40_LF_Service = class(TC40_Base_NoAuth_Service)
  private
    FDelay_Broadcast_API_Info_Time: TTimeTick;
    FNeed_Broadcast_API_Info: Boolean;
    procedure Do_Delay_Broadcast_API_Info;
  protected
    procedure DoLinkSuccess_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth); override;
    procedure DoUserOut_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth); override;
    procedure cmd_Init_APP_Info(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
    procedure cmd_No_App_Info(Sender: TPeerIO; InData: SystemString);
    procedure cmd_Thread_State(Sender: TPeerIO; InData: TDFE);
    procedure Do_Run_Notify_Th(thSender: THPC_StreamNotify; ThInData: TDFE);
    procedure cmd_Notify(Sender: TPeerIO; InData: TDFE);
    procedure cmd_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
    procedure Do_Run_Call_Th(thSender: THPC_CompleteBuffer_Stream; ThInData, ThOutData: TDFE);
    procedure cmd_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
  public
    constructor Create(PhysicsService_: TC40_PhysicsService; ServiceTyp, Param_: U_String); override;
    destructor Destroy; override;
    procedure SafeCheck; override;
    procedure Progress; override;
    procedure Broadcast_API_Info();

    function Do_Cmp_Last_Selected_Time__(var L, R: TC40_LF_RecvTunnel): Integer;
    function Find_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;

    function Do_Inv_Cmp_Temp_Sequence_Value__(var L, R: TC40_LF_RecvTunnel): Integer;
    function Find_Fixed_Sequenced_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
  end;

  { * TC40_LF_Client: The LingoFuse client that connects to a LingoFuse service.
    * It can host a local TLF_App (set via the APP property) and provides
    * methods to send notifications and calls to remote or local applications.
    * The client automatically registers its application with the service upon
    * connection.
    *
    * The client maintains a local cache of service info (FService_Info)
    * received via broadcasts, which enables it to find remote applications.
    * For calls/notifications, it first looks for a local (same‑process) client
    * via the global Find_Local_* functions; if found, execution is performed
    * locally without network overhead. Otherwise, it sends the request to the
    * service.
    *
    * Thread‑load statistics (FHost_Running_Thread_Num and
    * FWait_Reponse_Thread_Num) are sent to the service every second, allowing
    * the service to perform load‑aware routing.
    *
    * @Field Last_Selected_Time : Timestamp of the last time this client was
    *        selected (for load balancing).
    * @Field Fixed_Sequenced_Notify_Pool : Hash pool for tracking sequenced
    *        notification timestamps (used for local load balancing).
    * @Field Temp_Fixed_Sequenced_Value : Temporary value used during sorting.
    * @Field FService_Info : Cached service info received from the service.
    * @Field FHost_Running_Thread_Num : Atomic counter of threads handling
    *        incoming calls/notifications.
    * @Field FWait_Reponse_Thread_Num : Atomic counter of threads waiting for
    *        remote responses.
    * @Field FLast_Update_Thread_State_TimeTick : Last time thread states were
    *        sent to the service (for throttling).
    * @Field FAPP : The local application instance.
    * @Field FAPI_APP_Is_Online : True after successful registration.
    * @Constructor Create : Initialises the client and registers command handlers.
    * @Destructor Destroy : Waits for background threads to finish.
    * @Method Progress : Sends thread state updates every second.
    * @Method DoNetworkOnline/Offline : Called on connection/disconnection,
    *        updates online status.
    * @Method Update_LocalThread_State_To_Service : Sends thread counts to the
    *        service.
    * @Method Init_App_Info : Sends the application registration to the service.
    * @Method Set_API_APP : Binds a local application to the client.
    * @Method Send_Execute_Notify : Sends a one‑way notification (non‑sequenced).
    * @Method Send_Sequenced_Notify : Sends a sequenced notification.
    * @Method Wait_Execute_Call : Performs a synchronous call, waits for result.
    * @Property APP : The local application.
    * @Property LF_AppIsOnline : Indicates successful registration. }
  TC40_LF_Client = class(TC40_Base_NoAuth_Client)
  private
    Last_Selected_Time: TTimeTick;
    Fixed_Sequenced_Notify_Pool: TFixed_Sequenced_Notify_Pool;
    Temp_Fixed_Sequenced_Value: TTimeTick;
  protected
    FService_Info: TLF_ServiceInfoPool;
    FHost_Running_Thread_Num: TAtomInt32;
    FWait_Reponse_Thread_Num: TAtomInt32;
    FLast_Update_Thread_State_TimeTick: TTimeTick;
    FAPP: TLF_App;
    FAPI_APP_Is_Online: Boolean;
    procedure Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender: TDT_P2PVM_NoAuth_Custom_Client); override;
    procedure cmd_update_service_api_info(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure Do_Notify(thSender: THPC_CompleteBuffer; ThInData: PByte; ThDataSize: NativeInt);
    procedure cmd_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure cmd_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    procedure cmd_Call(Sender: TPeerIO; InData, OutData: TDFE);
    procedure Do_APP_Update(Sender: TLF_App);
  public
    constructor Create(PhysicsTunnel_: TC40_PhysicsTunnel; source_: TC40_Info; Param_: U_String); override;
    destructor Destroy; override;
    procedure SafeCheck; override;
    procedure Progress; override;
    procedure DoNetworkOnline; override;
    procedure DoNetworkOffline; override;
    property Service_Info: TLF_ServiceInfoPool read FService_Info;
    procedure Update_LocalThread_State_To_Service;
    procedure Init_App_Info;
    procedure Do_Init_App_Info_Result(Sender: TPeerIO; Result_: TDFE);
    property LF_AppIsOnline: Boolean read FAPI_APP_Is_Online;
    procedure Set_API_APP(const Value: TLF_App);
    property APP: TLF_App read FAPP write Set_API_APP;

    procedure Send_Execute_Notify___(const app_Name__: TLF_String; Param: TMem64);
    procedure Send_Execute_Notify(const app_Name__: TLF_String; Param: TMem64);

    procedure Send_Sequenced_Notify___(const app_Name__: TLF_String; Param: TMem64);
    procedure Send_Sequenced_Notify(const app_Name__: TLF_String; Param: TMem64);

    function Wait_Execute_Call___(const app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
    function Wait_Execute_Call(const app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
  end;

  TC40_LF_ClientList = TBigList<TC40_LF_Client>;

  { * TLF_CallBridge: Internal helper used by Wait_Execute_Call to capture the
    * asynchronous result of a call. It holds an output TMem64 and a flag
    * indicating whether the call is still pending. }
  TLF_CallBridge = class
  private
    Cli: TC40_LF_Client;
    Output: TMem64;
    IsRunning: Boolean;
    Error_: Boolean;
    procedure Do_Result(Sender: TPeerIO; Result_: TDFE);
  public
    constructor Create;
    destructor Destroy; override;
  end;

  { * Global utility functions for finding LingoFuse applications and APIs
    * locally (same process) or remotely (across the network). They support
    * wildcard matching on application names.
    *
    * @param app_Name__ : Application name (may contain wildcards like '*').
    * @param api_Name__ : API name (exact match).
    * @param Update_Selected_Time : If True, updates the Last_Selected_Time of
    *        the found client to the current tick, used for load balancing.
    * @return The matching client, or nil if none found. }
function Find_Local_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
function Find_Remote_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;

function Find_Local_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
function Find_Remote_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;

function Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
function Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;

var
  // Maximum age (in ticks) of a client's last sequenced-notify timestamp.
  // If the oldest candidate is older than this, fall back to the newest client
  // to prevent starvation and ensure fair distribution.
  Fixed_Sequenced_Time: TTimeTick;

implementation

{$I Z.LingoFuse_System_ProcessID.inc}


var
  Find_Safe_Critical, Sort_Safe_Critical: TCritical;

function Do_Cmp_Last_Selected_Time(var L, R: TC40_LF_Client): Integer;
{ * Comparison function for sorting TC40_LF_Client by Last_Selected_Time.
  * Used for load balancing: select the least recently used client. }
begin
  Result := CompareUInt64(L.Last_Selected_Time, R.Last_Selected_Time);
end;

function Find_Local_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
{ * Searches the local process for a client that hosts an application matching
  * the given name (wildcard supported). Returns the client with the oldest
  * Last_Selected_Time (least recently used) among matches.
  * @param app_Name__ : Application name pattern.
  * @param Update_Selected_Time : If True, updates the selected client's time.
  * @return The matching client, or nil. }
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
    arry := C40_ClientPool.SearchClass(TC40_LF_Client);
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
  try
    L.Sort_C(Do_Cmp_Last_Selected_Time);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Last_Selected_Time := GetTimeTick();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

function Find_Remote_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
{ * Searches remote clients (via the service info cache) for an application
  * matching the given name. Returns the client with the oldest
  * Last_Selected_Time among matches. }
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
    arry := C40_ClientPool.SearchClass(TC40_LF_Client, True);
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
  try
    L.Sort_C(Do_Cmp_Last_Selected_Time);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Last_Selected_Time := GetTimeTick();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

function Find_Local_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
{ * Searches the local process for a client that hosts an application matching
  * the given name AND exports the specified API. Returns the client with the
  * oldest Last_Selected_Time. }
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
    arry := C40_ClientPool.SearchClass(TC40_LF_Client);
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

  Sort_Safe_Critical.Lock;
  try
    L.Sort_C(Do_Cmp_Last_Selected_Time);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Last_Selected_Time := GetTimeTick();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

function Find_Remote_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
{ * Searches remote clients for an application matching the given name AND
  * exporting the specified API. Returns the client with the oldest
  * Last_Selected_Time. }
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
    arry := C40_ClientPool.SearchClass(TC40_LF_Client, True);
    for i := 0 to length(arry) - 1 do
      begin
        Cli := arry[i] as TC40_LF_Client;
        if Cli.Service_Info.Find_API(app_Name__, api_Name__) then
            L.Add(Cli);
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  Sort_Safe_Critical.Lock;
  try
    L.Sort_C(Do_Cmp_Last_Selected_Time);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Last_Selected_Time := GetTimeTick();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

function Do_Inv_Cmp_Temp_Sequence_Value(var L, R: TC40_LF_Client): Integer;
{ * Comparison function for sorting TC40_LF_Client by
  * Temp_Fixed_Sequenced_Value in descending order (so that the client with
  * the smallest value (oldest) comes first). }
begin
  Result := CompareUInt64(R.Temp_Fixed_Sequenced_Value, L.Temp_Fixed_Sequenced_Value);
end;

function Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
{ * Finds a local client for a sequenced notification. It computes a key
  * "appName.apiName", then for each matching local client, retrieves the
  * last timestamp from its Fixed_Sequenced_Notify_Pool. The client with the
  * smallest timestamp (oldest) is selected, and then its timestamp is updated
  * to the current time. This ensures that sequenced notifications for the same
  * (app, api) pair are distributed round‑robin or least‑recently‑used.
  * If a client's timestamp is older than 5 minutes, it falls back to the last
  * client (newest) to avoid starvation. }
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
  n: TLF_String;
begin
  Result := nil;
  L := TC40_LF_ClientList.Create;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.SearchClass(TC40_LF_Client);
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
  for i := 0 to L.Count - 1 do
    begin
      Cli := L[i] as TC40_LF_Client;
      Cli.Temp_Fixed_Sequenced_Value := Cli.Fixed_Sequenced_Notify_Pool.Get_Default_Value(n, 0);
    end;

  try
    L.Sort_C(Do_Inv_Cmp_Temp_Sequence_Value);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        // If the oldest timestamp is more than "Fixed_Sequenced_Time" ms old, fall back to the newest (last) to avoid always using the same client.
        if GetTimeTick() - Result.Temp_Fixed_Sequenced_Value > Fixed_Sequenced_Time then
            Result := L.Last^.Data;
        Result.Fixed_Sequenced_Notify_Pool.Set_Key_Value(n, GetTimeTick());
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

function Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
{ * Same as Find_Fixed_Sequenced_Local_API but searches remote clients
  * (using the service info cache). }
var
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  L: TC40_LF_ClientList;
  n: TLF_String;
begin
  Result := nil;
  L := TC40_LF_ClientList.Create;
  Find_Safe_Critical.Lock;
  try
    arry := C40_ClientPool.SearchClass(TC40_LF_Client, True);
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
  for i := 0 to L.Count - 1 do
    begin
      Cli := L[i] as TC40_LF_Client;
      Cli.Temp_Fixed_Sequenced_Value := Cli.Fixed_Sequenced_Notify_Pool.Get_Default_Value(n, 0);
    end;

  try
    L.Sort_C(Do_Inv_Cmp_Temp_Sequence_Value);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        // If the oldest timestamp is more than "Fixed_Sequenced_Time" ms old, fall back to the newest (last) to avoid always using the same client.
        if GetTimeTick() - Result.Temp_Fixed_Sequenced_Value > Fixed_Sequenced_Time then
            Result := L.Last^.Data;
        Result.Fixed_Sequenced_Notify_Pool.Set_Key_Value(n, GetTimeTick());
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

constructor TC40_LF_RecvTunnel.Create(Owner_: TPeerIO);
{ * Initialises the tunnel user object. Creates the fixed sequenced notify
  * pool and the API info hash list. }
begin
  inherited Create(Owner_);
  Last_Selected_Time := 0;
  Fixed_Sequenced_Notify_Pool := TFixed_Sequenced_Notify_Pool.Create($FF, 0);
  Temp_Fixed_Sequenced_Value := 0;

  LF_Service := nil;
  APP_Name := '';
  APP_Desc := '';
  APP_Process_Info := '';
  api_info_data := THashList.Create;
  Host_Running_Thread_Num := 0;
  Wait_Reponse_Thread_Num := 0;
  Is_Local := False;
end;

destructor TC40_LF_RecvTunnel.Destroy;
{ * Frees the API info hash list and the sequenced notify pool. }
begin
  DisposeObject(api_info_data);
  DisposeObject(Fixed_Sequenced_Notify_Pool);
  inherited Destroy;
end;

constructor TLF_ServiceInfo.Create;
{ * Creates an empty service info record. }
begin
  inherited Create;
  APP_Name := '';
  APP_Desc := '';
  APP_Process_Info := '';
  api_info_data := THashList.Create;
  Host_Running_Thread_Num := 0;
  Wait_Reponse_Thread_Num := 0;
  Is_Local := False;
end;

destructor TLF_ServiceInfo.Destroy;
{ * Frees the API info hash list. }
begin
  DisposeObject(api_info_data);
  inherited Destroy;
end;

procedure TLF_ServiceInfo.Assign(source: TC40_LF_RecvTunnel);
{ * Copies the registration data from a receive‑tunnel user object. }
begin
  APP_Name := source.APP_Name;
  APP_Desc := source.APP_Desc;
  APP_Process_Info := source.APP_Process_Info;
  api_info_data.Assign(source.api_info_data);
  Host_Running_Thread_Num := source.Host_Running_Thread_Num;
  Wait_Reponse_Thread_Num := source.Wait_Reponse_Thread_Num;
  Is_Local := source.Is_Local;
end;

procedure TLF_ServiceInfo.SaveToStream(stream: TCore_Stream);
{ * Serialises this service info to a stream using DFE encoding. }
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
  d.WriteInteger(Host_Running_Thread_Num);
  d.WriteInteger(Wait_Reponse_Thread_Num);
  d.WriteBool(Is_Local);
  d.FastEncodeTo(stream);
  DisposeObject(d);
end;

procedure TLF_ServiceInfo.LoadFromStream(stream: TCore_Stream);
{ * Deserialises service info from a stream. }
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
  Host_Running_Thread_Num := d.R.ReadInteger;
  Wait_Reponse_Thread_Num := d.R.ReadInteger;
  Is_Local := d.R.ReadBool;
  DisposeObject(d);
end;

constructor TLF_ServiceInfoPool.Create;
{ * Creates the pool with auto‑free enabled (True). }
begin
  inherited Create(True);
end;

destructor TLF_ServiceInfoPool.Destroy;
{ * Inherited, frees all objects. }
begin
  inherited Destroy;
end;

procedure TLF_ServiceInfoPool.Build_Info_Form(Inst: TC40_LF_RecvTunnel);
{ * Builds a snapshot entry from a client's registration data.
  * Only adds the entry if the client has at least one registered API. }
var
  tmp: TLF_ServiceInfo;
begin
  if Inst.api_info_data.Count > 0 then
    begin
      tmp := TLF_ServiceInfo.Create;
      tmp.Assign(Inst);
      Add(tmp);
    end;
end;

procedure TLF_ServiceInfoPool.SaveToStream(d: TDFE);
{ * Saves the entire pool to a DFE stream, serialising each item. }
var
  m64: TMS64;
begin
  if Num <= 0 then exit;
  m64 := TMS64.CustomCreate($FFFF);
  with repeat_ do
    repeat
      queue^.Data.SaveToStream(m64);
      d.WriteStream(m64);
      m64.Clear;
    until not Next;
  DisposeObject(m64);
end;

procedure TLF_ServiceInfoPool.LoadFromStream(d: TDFE);
{ * Loads the pool from a DFE stream, creating TLF_ServiceInfo objects. }
var
  m64: TMS64;
  Inst: TLF_ServiceInfo;
begin
  Clear;
  m64 := TMS64.CustomCreate($FFFF);
  while d.R.NotEnd do
    begin
      d.R.ReadMS64_As_Mapping(m64);
      m64.Position := 0;
      Inst := TLF_ServiceInfo.Create;
      Inst.LoadFromStream(m64);
      Add(Inst);
      m64.Clear;
    end;
  DisposeObject(m64);
end;

function TLF_ServiceInfoPool.Find_API(app_Name__, api_Name__: TLF_String): Boolean;
{ * Checks if any entry has the given appName and exports the given API. }
begin
  Result := False;
  if Num <= 0 then exit;
  with repeat_ do
    repeat
      if app_Name__.Same(queue^.Data.APP_Name) and queue^.Data.api_info_data.Exists(api_Name__) then
        begin
          Result := True;
          exit;
        end;
    until not Next;
end;

function TLF_ServiceInfoPool.Find_APP(app_Name__: TLF_String): Boolean;
{ * Checks if any entry has the given appName (regardless of APIs). }
begin
  Result := False;
  if Num <= 0 then exit;
  with repeat_ do
    repeat
      if app_Name__.Same(queue^.Data.APP_Name) then
        begin
          Result := True;
          exit;
        end;
    until not Next;
end;

constructor TC40_LF_SendTunnel.Create(Owner_: TPeerIO);
{ * Initialises the send tunnel user object with a nil service reference. }
begin
  inherited Create(Owner_);
  LF_Service := nil;
end;

destructor TC40_LF_SendTunnel.Destroy;
{ * Inherited. }
begin
  inherited Destroy;
end;

procedure TC40_LF_Service.Do_Delay_Broadcast_API_Info;
{ * Schedules a broadcast of API info after a 2‑second delay.
  * This coalesces multiple registration changes into a single broadcast. }
begin
  FDelay_Broadcast_API_Info_Time := GetTimeTick() + 2000;
  FNeed_Broadcast_API_Info := True;
end;

procedure TC40_LF_Service.DoLinkSuccess_Event(Sender: TDTService_NoAuth;
  UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth);
{ * Sets back‑references in the receive and send tunnel user objects. }
var
  user_io: TC40_LF_RecvTunnel;
begin
  inherited DoLinkSuccess_Event(Sender, UserDefineIO);
  user_io := UserDefineIO as TC40_LF_RecvTunnel;
  user_io.LF_Service := Self;
  (user_io.SendTunnel as TC40_LF_SendTunnel).LF_Service := Self;
end;

procedure TC40_LF_Service.DoUserOut_Event(Sender: TDTService_NoAuth;
  UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth);
{ * Overridden; no extra logic needed because the user object will be freed
  * automatically when the connection drops. }
begin
  inherited DoUserOut_Event(Sender, UserDefineIO);
end;

procedure TC40_LF_Service.cmd_Init_APP_Info(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
{ * Registers an application from a client. Reads the application name,
  * description, process info, and a list of API names, and stores them in
  * the receive‑tunnel user object. Also schedules a broadcast to all clients.
  *
  * @Param Sender : The bridge that contains the incoming data.
  * @Param InData : DFE containing: appName, appDesc, processInfo,
  *        a Pascal‑string list of API names, and a boolean Is_Local flag.
  * @Param OutData : Unused. }
var
  user_io: TC40_LF_RecvTunnel;
  L: TPascalStringList;
  i: Integer;
begin
  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender.R_IO) as TC40_LF_RecvTunnel;
  if user_io = nil then
      exit;
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
  Do_Delay_Broadcast_API_Info();
end;

procedure TC40_LF_Service.cmd_No_App_Info(Sender: TPeerIO; InData: SystemString);
{ * Handles a client that has no application to register (or an empty app).
  * Clears the registration data and schedules a broadcast. }
var
  user_io: TC40_LF_RecvTunnel;
begin
  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  if user_io = nil then
      exit;
  user_io.APP_Name := '';
  user_io.APP_Desc := '';
  user_io.APP_Process_Info := InData;
  user_io.api_info_data.Clear;
  user_io.Host_Running_Thread_Num := 0;
  user_io.Wait_Reponse_Thread_Num := 0;
  user_io.Is_Local := False;
  Do_Delay_Broadcast_API_Info();
end;

procedure TC40_LF_Service.cmd_Thread_State(Sender: TPeerIO; InData: TDFE);
{ * Receives runtime thread‑count updates from a client and stores them in
  * the user object for load‑aware routing. }
var
  user_io: TC40_LF_RecvTunnel;
begin
  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  if user_io = nil then
      exit;
  user_io.Host_Running_Thread_Num := InData.R.ReadInteger;
  user_io.Wait_Reponse_Thread_Num := InData.R.ReadInteger;
end;

procedure TC40_LF_Service.Do_Run_Notify_Th(thSender: THPC_StreamNotify; ThInData: TDFE);
{ * Background thread worker for executing a local notification.
  * Uses the TC40_LF_Client stored in thSender.UserObject.
  * Increments/decrements Host_Running_Thread_Num around the call. }
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
  tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ + 1);
  try
      tmp_cli__.APP.Engine.Execute_Notify(Param);
  finally
      tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ - 1);
  end;
  DisposeObject(Param);
end;

procedure TC40_LF_Service.cmd_Notify(Sender: TPeerIO; InData: TDFE);
{ * Routes an incoming notification to the appropriate destination.
  * 1) Tries local execution (same process) via Find_Local_API.
  * 2) If not found, forwards to other service instances (IPC first, then remote).
  * 3) Logs an error if no matching destination is found. }
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
  tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
    begin
      InData.R.Index := 0;
      DisposeObject(Param);
      RunHPC_StreamNotifyM(Sender, nil, tmp_cli__, InData, Do_Run_Notify_Th);
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
{ * Routes a sequenced notification. Uses Find_Fixed_Sequenced_Local_API or
  * Find_Fixed_Sequenced_Remote_API to choose a client based on the
  * least‑recently‑used timestamp for the (app, api) pair. If found locally,
  * it posts to the global sequenced thread pool; otherwise forwards to another
  * service instance. }
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
  tmp_cli__ := Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__);
  if tmp_cli__ <> nil then
    begin
      LF_Notify_Sequence_Thread_Pool.Post_Notify2(tmp_cli__.APP, Param.NewClone());
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

procedure TC40_LF_Service.Do_Run_Call_Th(thSender: THPC_CompleteBuffer_Stream; ThInData, ThOutData: TDFE);
{ * Background thread worker for executing a local synchronous call.
  * Uses the TC40_LF_Client stored in thSender.UserObject.
  * Increments/decrements Host_Running_Thread_Num around the call. }
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
{ * Routes an incoming synchronous call. Tries local execution first, then
  * forwards to other service instances. }
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
  InData.R.Index := 0;
  tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
    begin
      DisposeObject(Param);
      RunHPC_CompleteBuffer_StreamM(Sender, nil, tmp_cli__, InData, OutData, Do_Run_Call_Th);
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

constructor TC40_LF_Service.Create(PhysicsService_: TC40_PhysicsService; ServiceTyp, Param_: U_String);
{ * Constructor: sets up the service with custom user‑defined classes,
  * configures buffer sizes, and registers the command handlers.
  * Temporarily disables per‑service directories to avoid clutter. }
var
  bak_: Boolean;
begin
  bak_ := C40_EnablePerServiceDirectory;
  C40_EnablePerServiceDirectory := False;
  inherited Create(PhysicsService_, ServiceTyp, Param_);
  C40_EnablePerServiceDirectory := bak_;

  FDelay_Broadcast_API_Info_Time := 0;
  FNeed_Broadcast_API_Info := False;
  ServiceInfo.OnlyInstance := False;

  DTNoAuth.RecvTunnel.UserDefineClass := TC40_LF_RecvTunnel;
  DTNoAuth.SendTunnel.UserDefineClass := TC40_LF_SendTunnel;

  DTNoAuth.RecvTunnel.MaxCompleteBufferSize := EStrToInt64(ParamList.GetDefaultValue('MaxBuffer', '500*1024*1024'), 500 * 1024 * 1024);
  DTNoAuth.SendTunnel.MaxCompleteBufferSize := EStrToInt64(ParamList.GetDefaultValue('MaxBuffer', '500*1024*1024'), 500 * 1024 * 1024);

  DTNoAuth.RecvTunnel.CompleteBufferCompressed := False;

  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('Init_APP_Info').OnExecute := cmd_Init_APP_Info;
  DTNoAuth.RecvTunnel.RegisterConsoleNotify('No_App_Info').OnExecute := cmd_No_App_Info;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('Thread_State').OnExecute := cmd_Thread_State;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('Notify').OnExecute := cmd_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_StreamNotify('Sequenced_Notify').OnExecute := cmd_Sequenced_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Bridge_Stream('Call').OnExecute := cmd_Call;

  DTNoAuth.RecvTunnel.PrintParams.Add('update_service_api_info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Init_APP_Info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('No_App_Info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Thread_State', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Sequenced_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Call', False, True);

  DTNoAuth.SendTunnel.PrintParams.Add('update_service_api_info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Init_APP_Info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('No_App_Info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Thread_State', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Sequenced_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Call', False, True);
end;

destructor TC40_LF_Service.Destroy;
begin
  inherited Destroy;
end;

procedure TC40_LF_Service.SafeCheck;
begin
  inherited SafeCheck;
end;

procedure TC40_LF_Service.Progress;
{ * Main progress method. Drives the network and triggers broadcast
  * when the scheduled broadcast time is reached. }
begin
  inherited Progress;
  if FNeed_Broadcast_API_Info then
    begin
      if GetTimeTick() > FDelay_Broadcast_API_Info_Time then
        begin
          Broadcast_API_Info;
          FNeed_Broadcast_API_Info := False;
        end;
    end;
end;

procedure TC40_LF_Service.Broadcast_API_Info();
{ * Builds a snapshot of all registered applications and sends it to every
  * connected client using the 'update_service_api_info' command. }
var
  info_pool: TLF_ServiceInfoPool;
  arry: TIO_Array;
  ID_: Cardinal;
  IO_: TPeerIO;
  tmp: TC40_LF_RecvTunnel;
  d: TDFE;
  final_data: TMS64;
begin
  info_pool := TLF_ServiceInfoPool.Create;
  DTNoAuth.RecvTunnel.GetIO_Array(arry);
  for ID_ in arry do
    begin
      IO_ := DTNoAuth.RecvTunnel.PeerIO[ID_];
      if IO_ <> nil then
        begin
          tmp := IO_.Define as TC40_LF_RecvTunnel;
          if tmp.LinkOk then
              info_pool.Build_Info_Form(tmp);
        end;
    end;
  d := TDFE.Create;
  info_pool.SaveToStream(d);
  DisposeObject(info_pool);
  final_data := TMS64.CustomCreate(1024 * 1024);
  d.FastEncodeTo(final_data);
  DisposeObject(d);
  final_data.Position := 0;
  for ID_ in arry do
    begin
      IO_ := DTNoAuth.RecvTunnel.PeerIO[ID_];
      if IO_ <> nil then
        begin
          tmp := IO_.Define as TC40_LF_RecvTunnel;
          if tmp.LinkOk then
            begin
              tmp.SendTunnel.Owner.SendCompleteBuffer('update_service_api_info', final_data.NewClone, True);
            end;
        end;
    end;
  DisposeObject(final_data);
end;

function TC40_LF_Service.Do_Cmp_Last_Selected_Time__(var L, R: TC40_LF_RecvTunnel): Integer;
{ * Comparison function for sorting connected clients by Last_Selected_Time.
  * Used to implement load balancing by selecting the least recently used client. }
begin
  Result := CompareUInt64(L.Last_Selected_Time, R.Last_Selected_Time);
end;

function TC40_LF_Service.Find_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
{ * Scans all connected clients and returns the receive‑tunnel user object of
  * the first one that matches the given application name (wildcard) and
  * exposes the specified API. If multiple clients match, the one with the
  * lowest Last_Selected_Time is returned (load balancing). }
var
  arry: TIO_Array;
  ID_: Cardinal;
  IO_: TPeerIO;
  tmp: TC40_LF_RecvTunnel;
  L: TC40_LF_RecvTunnelList;
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
  if L.Num > 1 then
      L.Sort_M(Do_Cmp_Last_Selected_Time__);
  if L.Num > 0 then
    begin
      Result := L.First^.Data;
      Result.Last_Selected_Time := GetTimeTick();
    end;
  DisposeObject(L);
end;

function TC40_LF_Service.Do_Inv_Cmp_Temp_Sequence_Value__(var L, R: TC40_LF_RecvTunnel): Integer;
{ * Comparison function for sorting by Temp_Fixed_Sequenced_Value (descending). }
begin
  Result := CompareUInt64(R.Temp_Fixed_Sequenced_Value, L.Temp_Fixed_Sequenced_Value);
end;

function TC40_LF_Service.Find_Fixed_Sequenced_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
{ * Similar to Find_API but for sequenced notifications. Uses the
  * least‑recently‑used timestamp for the (app, api) key to select a client.
  * If multiple clients match, it computes each client's timestamp and sorts
  * in descending order (oldest first). The client with the oldest timestamp
  * (or the last if older than 5 minutes) is selected, and its timestamp is
  * updated. }
var
  arry: TIO_Array;
  ID_: Cardinal;
  IO_: TPeerIO;
  tmp: TC40_LF_RecvTunnel;
  L: TC40_LF_RecvTunnelList;
  n: TLF_String;
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
  if L.Num > 1 then
    begin
      with L.repeat_ do
        repeat
            queue^.Data.Temp_Fixed_Sequenced_Value := queue^.Data.Fixed_Sequenced_Notify_Pool.Get_Default_Value(n, 0);
        until not Next;
      L.Sort_M(Do_Inv_Cmp_Temp_Sequence_Value__);
    end;

  if L.Num > 0 then
    begin
      Result := L.First^.Data;
      if GetTimeTick() - Result.Temp_Fixed_Sequenced_Value > Fixed_Sequenced_Time then
          Result := L.Last^.Data;
      Result.Fixed_Sequenced_Notify_Pool.Set_Key_Value(n, GetTimeTick());
    end;

  DisposeObject(L);
end;

procedure TC40_LF_Client.Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender: TDT_P2PVM_NoAuth_Custom_Client);
{ * Called when the double‑tunnel link is established. If an APP is set,
  * automatically registers it with the service. }
begin
  inherited Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender);
  if APP <> nil then
      Init_App_Info;
end;

procedure TC40_LF_Client.cmd_update_service_api_info(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
{ * Receives the service's broadcast of available applications and updates
  * the local FService_Info cache. The data is DFE‑encoded. }
var
  m64: TMS64;
  d: TDFE;
begin
  m64 := TMS64.Create;
  m64.Mapping(InData, DataSize);
  d := TDFE.Create;
  d.DecodeFrom(m64, True);
  DisposeObject(m64);
  FService_Info.LoadFromStream(d);
  DisposeObject(d);
end;

procedure TC40_LF_Client.Do_Notify(thSender: THPC_CompleteBuffer; ThInData: PByte; ThDataSize: NativeInt);
{ * Background thread worker for executing a local notification.
  * Maps the raw input buffer to a TMem64 and invokes Execute_Notify on the
  * local APP. Increments/decrements Host_Running_Thread_Num. }
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
{ * Handles incoming 'Notify' commands by offloading processing to a background
  * thread using RunHPC_CompleteBufferM. }
begin
  if FAPP = nil then
      exit;
  RunHPC_CompleteBufferM(Sender, nil, nil, InData, DataSize, Do_Notify);
end;

procedure TC40_LF_Client.cmd_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
{ * Handles incoming 'Sequenced_Notify' commands. Extracts the API name,
  * creates a TMem64, and posts it to the global sequenced notification pool
  * for the current APP. }
var
  m64: TMem64;
  api_Name__: TLF_String;
begin
  if FAPP = nil then
      exit;
  m64 := TMem64.Create;
  m64.Mapping(InData, DataSize);
  api_Name__ := TMemory_Param_Tool.Get_apiName(m64);
  LF_Notify_Sequence_Thread_Pool.Post_Notify2(APP, m64.NewClone);
  DisposeObject(m64);
end;

procedure TC40_LF_Client.cmd_Call(Sender: TPeerIO; InData, OutData: TDFE);
{ * Handles incoming 'Call' commands synchronously. Decodes the request,
  * executes the API call locally, and writes the result back.
  * This runs in the main thread (not background). }
var
  app_Name__: TLF_String;
  m64, Output: TMem64;
begin
  if FAPP = nil then
      exit;
  FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ + 1);
  try
    app_Name__ := InData.R.ReadString;
    m64 := TMem64.Create;
    InData.R.ReadMem64_As_Mapping(m64);
    Output := FAPP.Engine.Execute_Call(m64);
    DisposeObject(m64);
    OutData.WriteMem64(Output);
    DisposeObject(Output);
  finally
      FHost_Running_Thread_Num.UnLock(FHost_Running_Thread_Num.LockP^ - 1);
  end;
end;

procedure TC40_LF_Client.Do_APP_Update(Sender: TLF_App);
{ * Called when the APP's API list changes. Re‑registers the app with the service. }
begin
  Init_App_Info;
end;

constructor TC40_LF_Client.Create(PhysicsTunnel_: TC40_PhysicsTunnel; source_: TC40_Info; Param_: U_String);
{ * Constructor: initialises the client, creates the service info pool,
  * atomic counters, and fixed sequenced pool, and registers command handlers. }
begin
  inherited Create(PhysicsTunnel_, source_, Param_);
  FService_Info := TLF_ServiceInfoPool.Create;
  FHost_Running_Thread_Num := TAtomInt32.Create(0);
  FWait_Reponse_Thread_Num := TAtomInt32.Create(0);
  FLast_Update_Thread_State_TimeTick := 0;
  FAPP := nil;
  FAPI_APP_Is_Online := False;
  Last_Selected_Time := 0;
  Fixed_Sequenced_Notify_Pool := TFixed_Sequenced_Notify_Pool.Create($FF, 0);
  Temp_Fixed_Sequenced_Value := 0;

  DTNoAuth.RecvTunnel.MaxCompleteBufferSize := EStrToInt64(ParamList.GetDefaultValue('MaxBuffer', '500*1024*1024'), 500 * 1024 * 1024);
  DTNoAuth.SendTunnel.MaxCompleteBufferSize := EStrToInt64(ParamList.GetDefaultValue('MaxBuffer', '500*1024*1024'), 500 * 1024 * 1024);

  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('update_service_api_info').OnExecute := cmd_update_service_api_info;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('Notify').OnExecute := cmd_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer('Sequenced_Notify').OnExecute := cmd_Sequenced_Notify;
  DTNoAuth.RecvTunnel.RegisterCompleteBuffer_NoWait_Stream_Thread('Call').OnExecute := cmd_Call;

  DTNoAuth.RecvTunnel.PrintParams.Add('update_service_api_info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Init_APP_Info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('No_App_Info', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Thread_State', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Sequenced_Notify', False, True);
  DTNoAuth.RecvTunnel.PrintParams.Add('Call', False, True);

  DTNoAuth.SendTunnel.PrintParams.Add('update_service_api_info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Init_APP_Info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('No_App_Info', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Thread_State', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Sequenced_Notify', False, True);
  DTNoAuth.SendTunnel.PrintParams.Add('Call', False, True);
end;

destructor TC40_LF_Client.Destroy;
{ * Destructor: removes the APP update subscription, waits for background
  * threads to finish (with a 2‑second timeout), and frees resources. }
var
  tk: TTimeTick;
begin
  if FAPP <> nil then
      FAPP.Remove_Update(Self);
  tk := GetTimeTick() + 2000;
  while (FHost_Running_Thread_Num.V + FWait_Reponse_Thread_Num.V > 0) and (GetTimeTick() < tk) do
      TCompute.Sleep(100);
  DisposeObjectAndNil(FHost_Running_Thread_Num);
  DisposeObjectAndNil(FWait_Reponse_Thread_Num);
  DisposeObjectAndNil(FService_Info);
  DisposeObjectAndNil(Fixed_Sequenced_Notify_Pool);
  inherited Destroy;
end;

procedure TC40_LF_Client.SafeCheck;
begin
  inherited SafeCheck;
end;

procedure TC40_LF_Client.Progress;
{ * Main progress method. If the client is online, sends thread‑state updates
  * to the service every second (throttled to 100 ms check interval). }
var
  tk: TTimeTick;
begin
  if LF_AppIsOnline then
    begin
      tk := GetTimeTick();
      if tk - FLast_Update_Thread_State_TimeTick > 100 then
        begin
          if not DTNoAuth.SendTunnel.IOBusy then
              Update_LocalThread_State_To_Service;
          FLast_Update_Thread_State_TimeTick := tk;
        end;
    end;
  inherited Progress;
end;

procedure TC40_LF_Client.DoNetworkOnline;
begin
  inherited;
end;

procedure TC40_LF_Client.DoNetworkOffline;
{ * Called when the client disconnects; resets the online flag. }
begin
  inherited;
  FAPI_APP_Is_Online := False;
end;

procedure TC40_LF_Client.Update_LocalThread_State_To_Service;
{ * Sends the current thread‑count statistics to the service using the
  * 'Thread_State' command. This allows the service to perform load‑aware routing. }
begin
  if not LF_AppIsOnline then
      exit;
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('Thread_State',
    TDFE.Create.WriteInteger(FHost_Running_Thread_Num.V).WriteInteger(FWait_Reponse_Thread_Num.V).DelayFree);
end;

procedure TC40_LF_Client.Do_Init_App_Info_Result(Sender: TPeerIO; Result_: TDFE);
{ * Callback for the 'Init_APP_Info' command's response. Sets the online flag
  * to True, indicating registration was successful, and subscribes to APP updates. }
begin
  FAPI_APP_Is_Online := True;
  FAPP.Subscribe_Update(Self, Do_APP_Update);
end;

procedure TC40_LF_Client.Init_App_Info;
{ * Builds a list of API names from the current TLF_App and sends the
  * registration to the service using the 'Init_APP_Info' command.
  * If APP is nil or has no name, sends a 'No_App_Info' notification instead. }
var
  api_info_data: TPascalStringList;
  R: TLF_MethodPool.TRepeat___;
begin
  if (APP = nil) or (APP.Name.TrimChar(#32#9) = '') then
    begin
      DTNoAuth.SendTunnel.SendConsoleNotifyCmd('No_App_Info', MakeProcessName());
      exit;
    end;
  api_info_data := TPascalStringList.Create;
  if APP.Engine.LF_MethodPool.Num > 0 then
    begin
      R := APP.Engine.LF_MethodPool.Queue_Pool.repeat_;
      repeat
          api_info_data.Add(R.queue^.Data.Data.Primary);
      until not R.Next;
    end;
  DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('Init_APP_Info',
    TDFE.Create
      .WriteString(APP.Name.Text)
      .WriteString(APP.Desc.Text)
      .WriteString(MakeProcessName())
      .WritePascalStrings(api_info_data)
      .WriteBool(IsLocal())
      .DelayFree,
    Do_Init_App_Info_Result);
  DisposeObject(api_info_data);
end;

procedure TC40_LF_Client.Set_API_APP(const Value: TLF_App);
{ * Binds a new TLF_App to the client. If the client is already connected,
  * immediately registers the new app with the service. }
begin
  if FAPP <> nil then
      FAPP.Remove_Update(Self);
  FAPP := Value;
  if DTNoAuth.LinkOk then
      Init_App_Info;
end;

procedure TC40_LF_Client.Send_Execute_Notify___(const app_Name__: TLF_String; Param: TMem64);
{ * Internal method that sends a non‑sequenced notification by forwarding to
  * the service. The payload is wrapped in a DFE and sent via the send tunnel.
  * If the payload is large (>100 KB), sends a NULL packet to flush the buffer. }
begin
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('Notify',
    TDFE.Create
      .WriteString(app_Name__)
      .WriteMem64(Param)
      .DelayFree
    );
  if Param.Size > 100 * 1024 then
      DTNoAuth.SendTunnel.SendNULL;
end;

procedure TC40_LF_Client.Send_Execute_Notify(const app_Name__: TLF_String; Param: TMem64);
{ * Sends a non‑sequenced notification to the target application. Performs
  * local execution if the target matches a local client; otherwise forwards
  * to the service. }
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
begin
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
    begin
      tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ + 1);
      try
          tmp_cli__.APP.Engine.Execute_Notify(Param);
      finally
          tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ - 1);
      end;
      exit;
    end;

  tmp_cli__ := Find_Remote_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
      tmp_cli__.Send_Execute_Notify___(app_Name__, Param)
  else
      Send_Execute_Notify___(app_Name__, Param);
end;

procedure TC40_LF_Client.Send_Sequenced_Notify___(const app_Name__: TLF_String; Param: TMem64);
{ * Internal method that sends a sequenced notification by forwarding to the
  * service. Similar to Send_Execute_Notify___ but uses the 'Sequenced_Notify'
  * command. }
begin
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('Sequenced_Notify',
    TDFE.Create
      .WriteString(app_Name__)
      .WriteMem64(Param)
      .DelayFree
    );
  if Param.Size > 100 * 1024 then
      DTNoAuth.SendTunnel.SendNULL;
end;

procedure TC40_LF_Client.Send_Sequenced_Notify(const app_Name__: TLF_String; Param: TMem64);
{ * Sends a sequenced notification. Uses Find_Fixed_Sequenced_Local_API or
  * Find_Fixed_Sequenced_Remote_API to choose the correct client (locally or
  * remotely) and posts to the appropriate sequenced thread. }
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
begin
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  tmp_cli__ := Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__);
  if tmp_cli__ <> nil then
    begin
      LF_Notify_Sequence_Thread_Pool.Post_Notify2(tmp_cli__.APP, Param.NewClone);
      exit;
    end;

  tmp_cli__ := Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__);
  if tmp_cli__ <> nil then
      tmp_cli__.Send_Sequenced_Notify___(app_Name__, Param)
  else
      Send_Sequenced_Notify___(app_Name__, Param);
end;

function TC40_LF_Client.Wait_Execute_Call___(const app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
{ * Internal method that performs a synchronous call by forwarding to the service.
  * Blocks until the response arrives or the timeout expires.
  * Uses TLF_CallBridge to capture the asynchronous result. }
var
  api_Name__: TLF_String;
  tmp: TLF_CallBridge;
  tk: TTimeTick;
begin
  Result := nil;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ + 1);
  tmp := TLF_CallBridge.Create;
  tmp.Cli := Self;
  tmp.IsRunning := True;
  DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('Call',
    TDFE.Create
      .WriteString(app_Name__)
      .WriteMem64(Param)
      .DelayFree,
    tmp.Do_Result);
  if Param.Size > 100 * 1024 then
      DTNoAuth.SendTunnel.SendNULL;
  tk := GetTimeTick + TimeOut__;
  while tmp.IsRunning do
    begin
      TCompute.Sleep(10);
      if (TimeOut__ > 0) and (GetTimeTick > tk) then
        begin
          FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
          DoStatus('%s -> %s call timeout', [app_Name__.Text, api_Name__.Text]);
          exit;
        end;
    end;
  Result := tmp.Output.Swap_To_New_Instance;
  FWait_Reponse_Thread_Num.UnLock(FWait_Reponse_Thread_Num.LockP^ - 1);
  DisposeObject(tmp);
end;

function TC40_LF_Client.Wait_Execute_Call(const app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
{ * Performs a synchronous call to the target application. First tries local
  * execution (same process), then remote execution via the service. }
var
  api_Name__: TLF_String;
  tmp_cli__: TC40_LF_Client;
begin
  Result := nil;
  api_Name__ := TMemory_Param_Tool.Get_apiName(Param);
  tmp_cli__ := Find_Local_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
    begin
      tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ + 1);
      try
          Result := tmp_cli__.APP.Engine.Execute_Call(Param);
      finally
          tmp_cli__.FHost_Running_Thread_Num.UnLock(tmp_cli__.FHost_Running_Thread_Num.LockP^ - 1);
      end;
      exit;
    end;
  tmp_cli__ := Find_Remote_API(app_Name__, api_Name__, True);
  if tmp_cli__ <> nil then
      Result := tmp_cli__.Wait_Execute_Call___(app_Name__, Param, TimeOut__)
  else
      Result := Wait_Execute_Call___(app_Name__, Param, TimeOut__);
end;

constructor TLF_CallBridge.Create;
{ * Initialises the bridge with an empty output and sets IsRunning to False. }
begin
  inherited Create;
  Cli := nil;
  Output := TMem64.Create;
  IsRunning := False;
  Error_ := False;
end;

destructor TLF_CallBridge.Destroy;
{ * Frees the output memory. }
begin
  DisposeObjectAndNil(Output);
  inherited Destroy;
end;

procedure TLF_CallBridge.Do_Result(Sender: TPeerIO; Result_: TDFE);
{ * Called when the asynchronous response for a call arrives. Reads the result
  * TMem64 from the DFE and signals completion by setting IsRunning to False. }
begin
  Error_ := Result_.Count <= 0;
  if not Error_ then
      Result_.R.ReadMem64(Output);
  IsRunning := False;
end;

initialization

RegisterC40('LingoFuse', TC40_LF_Service, TC40_LF_Client);
Fixed_Sequenced_Time := Z.Core.C_Tick_Second * 20;
Find_Safe_Critical := TCritical.Create('Find_Hub_Safe_Critical');
Sort_Safe_Critical := TCritical.Create('Sort_Safe_Critical');

finalization

DisposeObjectAndNil(Find_Safe_Critical);
DisposeObjectAndNil(Sort_Safe_Critical);

end.
