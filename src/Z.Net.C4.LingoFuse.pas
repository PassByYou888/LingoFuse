(*
  * ===========================================================================
  * Z.Net.C4.LingoFuse - Distributed LingoFuse RPC over the C4 Service Mesh
  * ===========================================================================
  *
  * This unit bridges the LingoFuse core RPC framework (Z.LingoFuse_Core) with
  * the C4 distributed service mesh (Z.Net.C4). It provides service-side
  * (TC40_LF_Service) and client-side (TC40_LF_Client) components that enable
  * applications to expose and call APIs (both Call and Notify modes) across
  * a network. Communication uses C4's P2PVM double-tunnel infrastructure with
  * the NoAuth model, making it easy to deploy in trusted environments.
  *
  * Key Concepts:
  *   - Application (TLF_App): A named container of APIs, defined in
  *     Z.LingoFuse_Core. Each app has a unique name and a set of registered
  *     Call/Notify APIs.
  *   - LingoFuse Service (TC40_LF_Service): Runs on a C4 PhysicsService.
  *     It accepts client connections, maintains a registry of all connected
  *     applications (APP_Name, description, process info, and the list of
  *     exported API names), and routes incoming calls/notifications to the
  *     appropriate client instance. It also periodically broadcasts a global
  *     service-info snapshot to all clients.
  *   - LingoFuse Client (TC40_LF_Client): Connects to a LingoFuse service.
  *     It can host a local TLF_App (set via the APP property) and
  *     automatically registers it with the service upon connection. It can
  *     also call remote applications (Wait_Execute_Call) and send
  *     notifications (Send_Execute_Notify), with an optimization that
  *     executes locally if a matching application is found in the same
  *     process.
  *   - Sequenced Notifications: For notifications that must be delivered in
  *     order, the system uses a global thread pool
  *     (LF_Notify_Sequence_Thread_Pool) that ensures FIFO delivery per
  *     (application, API) pair. The service and client provide methods for
  *     sequenced notifications (Send_Sequenced_Notify, cmd_Sequenced_Notify)
  *     that route to the appropriate sequenced thread.
  *   - Load Balancing: The service uses a 'last selected time' heuristic to
  *     choose among multiple clients that host the same application, ensuring
  *     fair distribution. For sequenced notifications, it picks the client
  *     with the oldest timestamp for the specific (app, api) pair, thus
  *     distributing load.
  *
  * Architecture:
  *   Service side:
  *     - TC40_LF_Service inherits from TC40_Base_NoAuth_Service (C4 no-auth).
  *     - Each connected client is represented by a TC40_LF_RecvTunnel object,
  *       which stores the application registration data.
  *     - The service periodically broadcasts a snapshot of all registered
  *       applications (via Broadcast_API_Info) to all clients.
  *     - Incoming 'Notify', 'Sequenced_Notify', and 'Call' commands are
  *       routed: first check for a local (same-process) client via the global
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
  *     (via HPC workers), so user callbacks must be thread-safe and should
  *     not block.
  *   - Do not call Wait_Execute_Call inside a callback (risk of deadlock).
  *
  * Dependencies:
  *   - Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status,
  *     Z.UnicodeMixedLib, Z.ListEngine, Z.DFE, Z.MemoryStream,
  *     Z.HashList.Templet, etc.
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
  *)
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
  (*
    * Forward declaration: the TC40_LF_Service class is defined later.
    *)
  TC40_LF_Service = class;

  (*
    * TFixed_Sequenced_Notify_Pool
    * ----------------------------
    * Hash pool mapping a string key to a TTimeTick value.
    *
    * Purpose:
    *   - Service side: records the last time a given client was selected to
    *     receive a sequenced notification for a specific (app, api) pair.
    *     Used to pick the least-recently-selected client for load balancing.
    *   - Client side: used for local load balancing with the same logic.
    *
    * Key format: 'AppName.ApiName'.
    *)
  TFixed_Sequenced_Notify_Pool = class(TString_Big_Hash_Pair_Pool<TTimeTick>);

  (*
    * TC40_LF_Cycle_Anchor_64
    * -----------------------
    * Alias: an Int64 that represents a "cycle anchor", i.e., a selection
    * timestamp. Used to fairly rotate among multiple clients hosting the
    * same application.
    *)
  TC40_LF_Cycle_Anchor_64 = Int64;

  (*
    * TC40_LF_RecvTunnel
    * ------------------
    * Per-connection user-defined object attached to the receive tunnel on
    * the service side. It stores the registration information of the
    * application hosted by the connected client, as well as runtime data
    * for load balancing and sequenced notification tracking.
    *
    * Key Fields:
    *   - Cycle_Int64_Anchor: Timestamp of the last time this tunnel was
    *     selected for routing a call/notification (used for load balancing;
    *     the smallest value is chosen next).
    *   - Fixed_Sequenced_Notify_Pool: Hash pool mapping "(app, api)" keys
    *     to the last time a sequenced notification was sent through this
    *     tunnel. Used to select the least-recently-used client.
    *   - Fixed_Sequenced_Temp_Time: Temporary storage used during sorting
    *     to hold the last sequenced time for the current (app, api).
    *   - LF_Service: Back-reference to the owning service.
    *   - APP_Name: Name of the application registered by this client.
    *   - APP_Desc: Description of the application.
    *   - APP_Process_Info: Process identifier string (e.g., "MyApp(1234)").
    *   - api_info_data: Hash list where keys are the names of exported APIs.
    *   - Host_Running_Thread_Num: Number of threads currently executing
    *     requests on behalf of this client (for load balancing).
    *   - Wait_Reponse_Thread_Num: Number of threads waiting for remote
    *     responses (for load balancing).
    *   - Is_Local: True if the client is connected via IPC or local network.
    *)
  TC40_LF_RecvTunnel = class(TService_RecvTunnel_UserDefine_NoAuth)
  private
    (* Timestamp when this tunnel was last selected for routing. *)
    Cycle_Int64_Anchor: TC40_LF_Cycle_Anchor_64;
    (* Sequenced notification time pool, keyed by 'AppName.ApiName'. *)
    Fixed_Sequenced_Notify_Pool: TFixed_Sequenced_Notify_Pool;
    (* Temporary timestamp used during sorting. *)
    Fixed_Sequenced_Temp_Time: TTimeTick;
  public
    (* Back-reference: owning service. *)
    LF_Service: TC40_LF_Service;
    (* Application name registered by the client. *)
    APP_Name: TLF_String;
    (* Application description. *)
    APP_Desc: TLF_String;
    (* Process identifier string. *)
    APP_Process_Info: TLF_String;
    (* Set of exported API names. *)
    api_info_data: THashList;
    (* Number of threads currently executing requests for this client. *)
    Host_Running_Thread_Num: Integer;
    (* Number of threads waiting for remote responses. *)
    Wait_Reponse_Thread_Num: Integer;
    (* True if this is a local client (IPC or local network). *)
    Is_Local: Boolean;
    constructor Create(Owner_: TPeerIO); override;
    destructor Destroy; override;
  end;

  (*
    * TC40_LF_RecvTunnelList
    * ----------------------
    * List container of TC40_LF_RecvTunnel, used for temporary collection
    * and sorting.
    *)
  TC40_LF_RecvTunnelList = class(TBigList<TC40_LF_RecvTunnel>)
  end;

  (*
    * TLF_ServiceInfo
    * ---------------
    * A snapshot of a client's application registration, used for broadcasting
    * to other clients and for local caching. It mirrors the fields of
    * TC40_LF_RecvTunnel but is serializable for network transmission.
    *
    * Serialization order (strict):
    *   1. APP_Name
    *   2. APP_Desc
    *   3. APP_Process_Info
    *   4. Key list of api_info_data (Pascal string array)
    *   5. Host_Running_Thread_Num
    *   6. Wait_Reponse_Thread_Num
    *   7. Is_Local
    * Finally, the TDFE is encoded to the target stream via FastEncodeTo.
    *)
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

  (*
    * TLF_ServiceInfoPool
    * -------------------
    * A list of TLF_ServiceInfo objects, used to build and broadcast a
    * complete registry of all applications connected to a service. Inherits
    * from TBig_Object_List for automatic memory management (AutoFreeObject
    * is enabled).
    *
    * Key contracts:
    *   - Build_Info_Form only adds an entry when api_info_data.Count > 0,
    *     so applications with no API are excluded from the broadcast pool.
    *   - SaveToStream returns immediately on an empty pool.
    *   - Find_API / Find_APP use app_Name__.Same, which is case-insensitive.
    *)
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

  (*
    * TC40_LF_SendTunnel
    * ------------------
    * Per-connection user-defined object attached to the send tunnel on the
    * service side. Holds a back-reference to the owning service.
    *)
  TC40_LF_SendTunnel = class(TService_SendTunnel_UserDefine_NoAuth)
  public
    LF_Service: TC40_LF_Service;
    constructor Create(Owner_: TPeerIO); override;
    destructor Destroy; override;
  end;

  (*
    * TC40_LF_Service
    * ---------------
    * The LingoFuse service that runs on a C4 PhysicsService.
    * It accepts client connections, maintains a registry of all connected
    * applications, and routes incoming calls/notifications to the correct
    * destination. It also broadcasts a global service-info snapshot to all
    * clients periodically.
    *
    * Routing logic:
    *   1. For a 'Call' or 'Notify', it first looks for a local (same-process)
    *      client that hosts the target application and API via
    *      Find_Local_API. If found, it executes locally (bypassing the
    *      network) for optimal performance.
    *   2. Otherwise, it scans all connected clients on this service instance
    *      (using Find_API) and forwards to the first matching client. It also
    *      forwards to other service instances (via the C40_ServicePool) if
    *      needed.
    *   3. For sequenced notifications, it uses
    *      Find_Fixed_Sequenced_Local_API or Find_Fixed_Sequenced_Remote_API
    *      to choose a client based on the least-recently-used timestamp for
    *      the (app, api) pair, ensuring that notifications for the same pair
    *      are serialised.
    *
    * Key fields:
    *   - FDelay_Broadcast_API_Info_Time: Earliest time when the next
    *     broadcast is allowed (used for coalescing).
    *   - FNeed_Broadcast_API_Info: Flag indicating a broadcast is pending.
    *
    * Constructor: sets up the service with custom user-defined classes,
    *   configures buffer sizes, and registers command handlers.
    * Destructor: inherited, frees resources.
    * Progress: drives the network and triggers broadcast when ready.
    * Broadcast_API_Info: builds a snapshot of all registered applications
    *   and sends it to all connected clients.
    * Find_API: scans all connected clients and returns the first matching
    *   receive tunnel for the given app and API.
    * Find_Fixed_Sequenced_API: same as Find_API but uses the
    *   least-recently-used timestamp to choose among multiple clients.
    *)
  TC40_LF_Service = class(TC40_Base_NoAuth_Service)
  private
    (* Earliest allowed time for the next broadcast (coalescing window). *)
    FDelay_Broadcast_API_Info_Time: TTimeTick;
    (* Whether a broadcast is pending. *)
    FNeed_Broadcast_API_Info: Boolean;
    (* Internal: schedules a broadcast 2 seconds later. *)
    procedure Do_Delay_Broadcast_API_Info;
  protected
    procedure DoLinkSuccess_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth); override;
    procedure DoUserOut_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth); override;
    (* Client registers an application. *)
    procedure cmd_Init_APP_Info(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
    (* Client has no application info. *)
    procedure cmd_No_App_Info(Sender: TPeerIO; InData: SystemString);
    (* Client reports thread state. *)
    procedure cmd_Thread_State(Sender: TPeerIO; InData: TDFE);
    (* Background worker: execute a notification. *)
    procedure Do_Run_Notify_Th(thSender: THPC_StreamNotify; ThInData: TDFE);
    (* Route a one-way notification. *)
    procedure cmd_Notify(Sender: TPeerIO; InData: TDFE);
    (* Route a sequenced notification. *)
    procedure cmd_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
    (* Background worker: execute a Call. *)
    procedure Do_Run_Call_Th(thSender: THPC_CompleteBuffer_Stream; ThInData, ThOutData: TDFE);
    (* Route a request-response call. *)
    procedure cmd_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
  public
    constructor Create(PhysicsService_: TC40_PhysicsService; ServiceTyp, Param_: U_String); override;
    destructor Destroy; override;
    procedure SafeCheck; override;
    procedure Progress; override;
    (* Immediately broadcast service API information to all connected clients. *)
    procedure Broadcast_API_Info();

    (* Comparison function: ascending by Cycle_Int64_Anchor. *)
    function Do_Cmp_Last_Selected_Time__(var L, R: TC40_LF_RecvTunnel): Integer;
    (* Find a client tunnel matching the given app name and API name. *)
    function Find_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;

    (* Comparison function: descending by Fixed_Sequenced_Temp_Time. *)
    function Do_Inv_Cmp_Temp_Sequence_Value__(var L, R: TC40_LF_RecvTunnel): Integer;
    (* Find the target client tunnel for a sequenced notification (LRU selection). *)
    function Find_Fixed_Sequenced_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
  end;

  (*
    * TC40_LF_Client
    * --------------
    * The LingoFuse client that connects to a LingoFuse service. It can host
    * a local TLF_App (set via the APP property) and provides methods to
    * send notifications and calls to remote or local applications. The
    * client automatically registers its application with the service upon
    * connection.
    *
    * The client maintains a local cache of service info (FService_Info)
    * received via broadcasts, which enables it to find remote applications.
    * For calls/notifications, it first looks for a local (same-process)
    * client via the global Find_Local_* functions; if found, execution is
    * performed locally without network overhead. Otherwise, it sends the
    * request to the service.
    *
    * Thread-load statistics (FHost_Running_Thread_Num and
    * FWait_Reponse_Thread_Num) are sent to the service every second,
    * allowing the service to perform load-aware routing.
    *
    * Key fields:
    *   - Cycle_Int64_Anchor: Timestamp of the last time this client was
    *     selected (for load balancing).
    *   - Fixed_Sequenced_Notify_Pool: Hash pool for tracking sequenced
    *     notification timestamps (used for local load balancing).
    *   - Fixed_Sequenced_Temp_Time: Temporary value used during sorting.
    *   - FService_Info: Cached service info received from the service.
    *   - FHost_Running_Thread_Num: Atomic counter of threads handling
    *     incoming calls/notifications.
    *   - FWait_Reponse_Thread_Num: Atomic counter of threads waiting for
    *     remote responses.
    *   - FLast_Update_Thread_State_TimeTick: Last time thread states were
    *     sent to the service (for throttling).
    *   - FAPP: The local application instance.
    *   - FAPI_APP_Is_Online: True after successful registration.
    *
    * Constructor: initializes the client and registers command handlers.
    * Destructor: waits for background threads to finish.
    * Progress: sends thread state updates every second (throttled to a
    *   100-millisecond check interval).
    * DoNetworkOnline/Offline: called on connection/disconnection, updates
    *   online status.
    * Update_LocalThread_State_To_Service: sends thread counts to the
    *   service.
    * Init_App_Info: sends the application registration to the service.
    * Set_API_APP: binds a local application to the client.
    * Send_Execute_Notify: sends a one-way notification (non-sequenced).
    * Send_Sequenced_Notify: sends a sequenced notification.
    * Wait_Execute_Call: performs a synchronous call, waits for result.
    * APP: the local application.
    * LF_AppIsOnline: indicates successful registration.
    *)
  TC40_LF_Client = class(TC40_Base_NoAuth_Client)
  private
    (* Timestamp of the last selection. *)
    Cycle_Int64_Anchor: TC40_LF_Cycle_Anchor_64;
    (* Sequenced notification time pool. *)
    Fixed_Sequenced_Notify_Pool: TFixed_Sequenced_Notify_Pool;
    (* Temporary value used during sorting. *)
    Fixed_Sequenced_Temp_Time: TTimeTick;
  protected
    (* Cached service info received from the service. *)
    FService_Info: TLF_ServiceInfoPool;
    (* Number of threads handling incoming calls/notifications. *)
    FHost_Running_Thread_Num: TAtomInt32;
    (* Number of threads waiting for remote responses. *)
    FWait_Reponse_Thread_Num: TAtomInt32;
    (* Last time thread states were sent to the service. *)
    FLast_Update_Thread_State_TimeTick: TTimeTick;
    (* The local application instance. *)
    FAPP: TLF_App;
    (* True after successful registration. *)
    FAPI_APP_Is_Online: Boolean;
    (* True once the service info has been received. *)
    FService_Info_Is_Onlne: Boolean;
    (* Called when the double-tunnel link is established; auto-registers APP. *)
    procedure Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender: TDT_P2PVM_NoAuth_Custom_Client); override;
    (* Receive the service's broadcast of service info. *)
    procedure cmd_update_service_api_info(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    (* Background worker: execute a local notification. *)
    procedure Do_Notify(thSender: THPC_CompleteBuffer; ThInData: PByte; ThDataSize: NativeInt);
    (* Receive a 'Notify' command. *)
    procedure cmd_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    (* Receive a 'Sequenced_Notify' command. *)
    procedure cmd_Sequenced_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
    (* Receive a 'Call' command, execute it and return the result. *)
    procedure cmd_Call(Sender: TPeerIO; InData, OutData: TDFE);
    (* Re-register when the app's API list changes. *)
    procedure Do_APP_Update(Sender: TLF_App);
  public
    constructor Create(PhysicsTunnel_: TC40_PhysicsTunnel; source_: TC40_Info; Param_: U_String); override;
    destructor Destroy; override;
    procedure SafeCheck; override;
    procedure Progress; override;
    procedure DoNetworkOnline; override;
    procedure DoNetworkOffline; override;
    (* Service info cache (read-only). *)
    property Service_Info: TLF_ServiceInfoPool read FService_Info;
    (* Send local thread state to the service. *)
    procedure Update_LocalThread_State_To_Service;
    (* Send application registration info to the service. *)
    procedure Init_App_Info;
    (* Callback for the 'Init_APP_Info' command. *)
    procedure Do_Init_App_Info_Result(Sender: TPeerIO; Result_: TDFE);
    (* Whether the app is registered online. *)
    property LF_AppIsOnline: Boolean read FAPI_APP_Is_Online;
    (* Whether service info is online. *)
    property LF_Service_Info_Is_Onlne: Boolean read FService_Info_Is_Onlne;

    (* Bind a local app to this client. *)
    procedure Set_API_APP(const Value: TLF_App);
    property APP: TLF_App read FAPP write Set_API_APP;

    (* Internal: send a non-sequenced notification directly to the service. *)
    procedure Send_Execute_Notify___(const app_Name__: TLF_String; Param: TMem64);
    (* Send a non-sequenced notification (prefers local execution). *)
    procedure Send_Execute_Notify(const app_Name__: TLF_String; Param: TMem64);

    (* Internal: send a sequenced notification directly to the service. *)
    procedure Send_Sequenced_Notify___(const app_Name__: TLF_String; Param: TMem64);
    (* Send a sequenced notification (prefers local execution). *)
    procedure Send_Sequenced_Notify(const app_Name__: TLF_String; Param: TMem64);

    (* Internal: perform a synchronous call via the service. *)
    function Wait_Execute_Call___(const app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
    (* Perform a synchronous call (prefers local execution). *)
    function Wait_Execute_Call(const app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
  end;

  (*
    * TC40_LF_ClientList
    * ------------------
    * List container of TC40_LF_Client, used for temporary collection and
    * sorting.
    *)
  TC40_LF_ClientList = TBigList<TC40_LF_Client>;

  (*
    * TLF_CallBridge
    * --------------
    * Internal helper used by Wait_Execute_Call to capture the asynchronous
    * result of a call. It holds an output TMem64 and a flag indicating
    * whether the call is still pending.
    *)
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

(*
  * Get the cached LingoFuse process name (format 'ProcessName:PID').
  * Generated on first call; subsequent calls return the cached value.
  *)
function Make_LingoFuse_Process_Name: TLF_String;

(*
  * Get the global cycle anchor (atomic increment).
  * Used for load balancing: a monotonically increasing value is taken as
  * a timestamp each time a client is selected.
  *)
function Get_Cycle_Anchor: TC40_LF_Cycle_Anchor_64;

(*
  * Global utility functions for finding LingoFuse applications and APIs
  * locally (same process) or remotely (across the network). They support
  * wildcard matching on application names.
  *
  * Parameters:
  *   app_Name__: Application name (may contain wildcards like '*').
  *   api_Name__: API name (exact match).
  *   Update_Selected_Time: If True, updates the Cycle_Int64_Anchor of the
  *     found client to the current tick, used for load balancing.
  *
  * Returns: The matching client, or nil if none found.
  *)
function Find_Local_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
function Find_Remote_APP(app_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;

function Find_Local_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
function Find_Remote_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;

function Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
function Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;

(*
  * ---------------------------------------------------------------------------
  * Network event trigger entry points
  * ---------------------------------------------------------------------------
  *
  * These two procedures are the Pascal-side trigger sites for the global
  * network event callbacks exposed via LF_Set_Network_Event in
  * Z.LingoFuse_Export.pas.
  *
  * They are called internally by TC40_LF_Client (never by user code):
  *
  *   Do_LF_Network_Connect    <- cmd_update_service_api_info
  *                               (first service-API-info broadcast received)
  *   Do_LF_Network_Disconnect <- DoNetworkOffline
  *                               (physical link loss)
  *
  * PITFALLS:
  *   - The user callback is dispatched to a BACKGROUND TCompute worker
  *     thread, not the caller thread and not the main thread. Do not touch
  *     UI controls directly inside the callback.
  *   - The addr_ string is converted to a UTF-8 PAnsiChar and freed
  *     immediately after the callback returns. Copy it inside the callback
  *     if you need to retain it.
  *
  * @see Do_LF_Network_Connect    (implementation) for the full contract
  * @see Do_LF_Network_Disconnect (implementation) for the full contract
  * @see LF_Set_Network_Event     in Z.LingoFuse_Export.pas for the C ABI
  *                               installation API
  *)
procedure Do_LF_Network_Connect(addr_: TLF_String);
procedure Do_LF_Network_Disconnect(addr_: TLF_String);

var
  (*
    * Maximum age (in ticks) of a client's last sequenced-notify timestamp.
    * If the oldest candidate is older than this, fall back to the newest
    * client to prevent starvation and ensure fair distribution.
    * Defaults to 20 seconds, set in the initialization section.
    *)
  Fixed_Sequenced_Time: TTimeTick;

  (*
    * Cached LingoFuse process name. Generated on first call by
    * Make_LingoFuse_Process_Name.
    *)
  LingoFuse_Process_Name: TLF_String;

const
  (*
    * Prefix for auto-generated application names.
    * Applications with this prefix trigger an immediate broadcast on
    * registration (no coalescing window).
    *)
  C_Generate_Prefix = '@__generate__@';

implementation

uses Z.LingoFuse_Export;

{$I Z.LingoFuse_System_ProcessID.inc}

var
  (* Critical section for lookups (protects reads on C40_ClientPool). *)
  Find_Safe_Critical, Sort_Safe_Critical: TCritical;
  (* Global cycle anchor counter. *)
  Cycle_Anchor_Seed: TAtomInt64;

(*
  * Get_Cycle_Anchor
  * ----------------
  * Atomically increments the global counter and returns its previous value.
  * Used to generate monotonically increasing selection timestamps for
  * load balancing.
  *)
function Get_Cycle_Anchor: TC40_LF_Cycle_Anchor_64;
begin
  Cycle_Anchor_Seed.Lock;
  Result := Cycle_Anchor_Seed.P^;
  inc(Cycle_Anchor_Seed.P^);
  Cycle_Anchor_Seed.UnLock;
end;

(*
  * Do_Cmp_Cycle_Int64_Anchor
  * -------------------------
  * Comparison function: ascending by TC40_LF_Client.Cycle_Int64_Anchor.
  * Used for load balancing: selects the least-recently-used client.
  *)
function Do_Cmp_Cycle_Int64_Anchor(var L, R: TC40_LF_Client): Integer;
begin
  Result := CompareInt64(L.Cycle_Int64_Anchor, R.Cycle_Int64_Anchor);
end;

(*
  * Find_Local_APP
  * --------------
  * Searches the local process for a client that hosts an application matching
  * the given name (wildcard supported). Returns the client with the oldest
  * Cycle_Int64_Anchor (least recently used) among matches.
  *
  * Parameters:
  *   app_Name__: Application name pattern.
  *   Update_Selected_Time: If True, updates the selected client's
  *     Cycle_Int64_Anchor to the current timestamp.
  *
  * Returns: The matching client, or nil.
  *)
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
  try
    L.Sort_C(Do_Cmp_Cycle_Int64_Anchor);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor := Get_Cycle_Anchor();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

(*
  * Find_Remote_APP
  * ---------------
  * Searches remote clients (via the service info cache) for an application
  * matching the given name. Returns the client with the oldest
  * Cycle_Int64_Anchor among matches.
  *)
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
  try
    L.Sort_C(Do_Cmp_Cycle_Int64_Anchor);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor := Get_Cycle_Anchor();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

(*
  * Find_Local_API
  * --------------
  * Searches the local process for a client that hosts an application matching
  * the given name AND exports the specified API. Returns the client with the
  * oldest Cycle_Int64_Anchor.
  *)
function Find_Local_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
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
            if app_Name__.Same(Cli.APP.Name) and Cli.APP.Engine.LF_MethodPool.Exists_Key(api_Name__) then
                L.Add(Cli);
          end;
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  Sort_Safe_Critical.Lock;
  try
    L.Sort_C(Do_Cmp_Cycle_Int64_Anchor);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor := Get_Cycle_Anchor();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

(*
  * Find_Remote_API
  * ---------------
  * Searches remote clients for an application matching the given name AND
  * exporting the specified API. Returns the client with the oldest
  * Cycle_Int64_Anchor.
  *)
function Find_Remote_API(app_Name__, api_Name__: TLF_String; Update_Selected_Time: Boolean): TC40_LF_Client;
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
        if Cli.Service_Info.Find_API(app_Name__, api_Name__) then
            L.Add(Cli);
      end;
  finally
      Find_Safe_Critical.UnLock;
  end;

  Sort_Safe_Critical.Lock;
  try
    L.Sort_C(Do_Cmp_Cycle_Int64_Anchor);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        if Update_Selected_Time then
            Result.Cycle_Int64_Anchor := Get_Cycle_Anchor();
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

(*
  * Do_Cmp_Fixed_Sequenced_Temp_Time
  * --------------------------------
  * Comparison function: descending by TC40_LF_Client.Fixed_Sequenced_Temp_Time.
  * Used for sequenced notifications: the smallest value (oldest) comes first.
  *)
function Do_Cmp_Fixed_Sequenced_Temp_Time(var L, R: TC40_LF_Client): Integer;
begin
  Result := CompareUInt64(R.Fixed_Sequenced_Temp_Time, L.Fixed_Sequenced_Temp_Time);
end;

(*
  * Find_Fixed_Sequenced_Local_API
  * ------------------------------
  * Finds a local client for a sequenced notification.
  * Computes key 'AppName.ApiName', then for each matching local client,
  * retrieves the last timestamp from its Fixed_Sequenced_Notify_Pool. The
  * client with the smallest timestamp (oldest) is selected, and then its
  * timestamp is updated to the current time. This ensures that sequenced
  * notifications for the same (app, api) pair are distributed round-robin
  * or least-recently-used.
  * If a client's timestamp is older than Fixed_Sequenced_Time (default 20
  * seconds), the function falls back to the last client (newest) to avoid
  * starvation.
  *)
function Find_Fixed_Sequenced_Local_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
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
  for i := 0 to L.Count - 1 do
    begin
      Cli := L[i] as TC40_LF_Client;
      Cli.Fixed_Sequenced_Temp_Time := Cli.Fixed_Sequenced_Notify_Pool.Get_Default_Value(n, 0);
    end;

  try
    L.Sort_C(Do_Cmp_Fixed_Sequenced_Temp_Time);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        (* If the oldest timestamp is more than Fixed_Sequenced_Time old,
           fall back to the newest (last) to avoid always using the same
           client. *)
        if GetTimeTick() - Result.Fixed_Sequenced_Temp_Time > Fixed_Sequenced_Time then
            Result := L.Last^.Data;
        Result.Fixed_Sequenced_Notify_Pool.Set_Key_Value(n, GetTimeTick());
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

(*
  * Find_Fixed_Sequenced_Remote_API
  * -------------------------------
  * Same as Find_Fixed_Sequenced_Local_API but searches remote clients
  * (using the service info cache).
  *)
function Find_Fixed_Sequenced_Remote_API(app_Name__, api_Name__: TLF_String): TC40_LF_Client;
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
  for i := 0 to L.Count - 1 do
    begin
      Cli := L[i] as TC40_LF_Client;
      Cli.Fixed_Sequenced_Temp_Time := Cli.Fixed_Sequenced_Notify_Pool.Get_Default_Value(n, 0);
    end;

  try
    L.Sort_C(Do_Cmp_Fixed_Sequenced_Temp_Time);
    if L.Num > 0 then
      begin
        Result := L.First^.Data;
        (* If the oldest timestamp is more than Fixed_Sequenced_Time old,
           fall back to the newest (last) to avoid always using the same
           client. *)
        if GetTimeTick() - Result.Fixed_Sequenced_Temp_Time > Fixed_Sequenced_Time then
            Result := L.Last^.Data;
        Result.Fixed_Sequenced_Notify_Pool.Set_Key_Value(n, GetTimeTick());
      end;
  finally
      Sort_Safe_Critical.UnLock;
  end;

  DisposeObject(L);
end;

(*
  * ===========================================================================
  * Network event trigger chain (Pascal-side dispatch)
  * ===========================================================================
  *
  * These four procedures implement the Pascal side of the network event
  * bridge to the C ABI export layer (Z.LingoFuse_Export.pas). They are the
  * concrete trigger sites behind the TLF_Network_Event callbacks exposed to
  * external languages via LF_Set_Network_Event.
  *
  * Trigger origin:
  *   Connect    : TC40_LF_Client.cmd_update_service_api_info
  *                (fires once, when FService_Info_Is_Onlne goes False -> True)
  *   Disconnect : TC40_LF_Client.DoNetworkOffline
  *                (fires once per physical link loss)
  *
  * Dispatch flow:
  *   Do_LF_Network_Connect(addr_)           // runs on caller's thread
  *     -> check On_Network_Connect_Event    // may be nil
  *     -> TCompute.RunC(...)                // hop to background worker
  *     -> Do_LF_Network_Connect_Th___(th)   // worker thread
  *     -> On_Network_Connect_Event(addr)    // user callback
  *     -> FreeUTF8AnsiChar(addr)            // release UTF-8 buffer
  *
  * Same shape for Disconnect.
  *)

(*
  * Do_LF_Network_Connect_Th___
  * ---------------------------
  * Background-worker half of the connect notification.
  *
  * Runs on a TCompute worker thread, not on the caller thread and not on
  * the simulated main thread.
  *
  * PITFALLS:
  *   - The user callback is invoked through a raw function pointer. Any
  *     exception it raises is swallowed by try...except; do not rely on
  *     exceptions for control flow.
  *   - thSender.UserData is the UTF-8 PAnsiChar buffer allocated by
  *     BuildUTF8AnsiChar in Do_LF_Network_Connect. It is freed here, AFTER
  *     the callback returns. A callback that stores the pointer without
  *     copying will retain a dangling reference.
  *)
procedure Do_LF_Network_Connect_Th___(thSender: TCompute);
begin
  try
      Z.LingoFuse_Export.On_Network_Connect_Event(thSender.UserData);
  except
  end;
  TLF_String.FreeUTF8AnsiChar(thSender.UserData);
end;

(*
  * Do_LF_Network_Connect
  * ---------------------
  * Trigger entry point for the "client is online" notification.
  *
  * PITFALLS:
  *   - This is NOT a TCP handshake notification. It fires only after the
  *     client has received its first service-API-info broadcast from the
  *     server (see TC40_LF_Client.cmd_update_service_api_info). That is
  *     the earliest point at which remote routing can be performed.
  *   - Fires exactly once per connection lifecycle, gated by the
  *     FService_Info_Is_Onlne False -> True transition on the client.
  *   - The actual user callback is dispatched to a background TCompute
  *     worker thread via RunC. This function returns immediately after
  *     enqueuing; it does NOT wait for the callback to complete.
  *   - If no callback is installed (On_Network_Connect_Event = nil), this
  *     function returns silently without allocating any buffer. It is
  *     safe to call unconditionally.
  *
  * Parameters:
  *   addr_: Human-readable remote endpoint (e.g. "127.0.0.1:9898" or
  *     "ipc:service_name"). Converted to UTF-8 before being handed to the
  *     worker; the original TLF_String is not retained.
  *
  * @see LF_Set_Network_Event  in Z.LingoFuse_Export.pas for the C ABI
  *                            installation API and the full callback
  *                            contract.
  *)
procedure Do_LF_Network_Connect(addr_: TLF_String);
begin
  if Assigned(Z.LingoFuse_Export.On_Network_Connect_Event) then
      TCompute.RunC(addr_.BuildUTF8AnsiChar(), nil, Do_LF_Network_Connect_Th___);
end;

(*
  * Do_LF_Network_Disconnect_Th___
  * ------------------------------
  * Background-worker half of the disconnect notification.
  *
  * Runs on a TCompute worker thread. Contract is identical to
  * Do_LF_Network_Connect_Th___:
  *   - Callback exceptions are swallowed.
  *   - thSender.UserData is the UTF-8 PAnsiChar buffer; it is freed here
  *     after the callback returns. Callbacks must copy the string if they
  *     need it beyond the call.
  *)
procedure Do_LF_Network_Disconnect_Th___(thSender: TCompute);
begin
  try
      Z.LingoFuse_Export.On_Network_Disconnect_Event(thSender.UserData);
  except
  end;
  TLF_String.FreeUTF8AnsiChar(thSender.UserData);
end;

(*
  * Do_LF_Network_Disconnect
  * ------------------------
  * Trigger entry point for the "client went offline" notification.
  *
  * Fired by TC40_LF_Client.DoNetworkOffline when the physical link to the
  * service is lost. At this point remote calls will fail; local calls
  * (via Find_Local_) may still succeed if other clients remain online.
  *
  * PITFALLS:
  *   - Fires once per DoNetworkOffline invocation, i.e. once per physical
  *     link loss. Client auto-reconnect will trigger a fresh connect
  *     notification (via Do_LF_Network_Connect) after the next
  *     service-API-info broadcast, but NOT another disconnect.
  *   - The user callback is dispatched to a background TCompute worker
  *     thread. Do not touch UI controls from the callback; marshal to the
  *     main thread instead.
  *   - The addr_ parameter is validated and copied to UTF-8 before the
  *     worker dispatch, but the callback receives the UTF-8 buffer only
  *     during its own execution. Storing the pointer without copying is
  *     undefined behaviour.
  *
  * Parameters:
  *   addr_: Human-readable remote endpoint (same format as for
  *     Do_LF_Network_Connect).
  *
  * @see LF_Set_Network_Event  in Z.LingoFuse_Export.pas for the C ABI
  *                            installation API and the full callback
  *                            contract.
  *)
procedure Do_LF_Network_Disconnect(addr_: TLF_String);
begin
  if Assigned(Z.LingoFuse_Export.On_Network_Disconnect_Event) then
      TCompute.RunC(addr_.BuildUTF8AnsiChar(), nil, Do_LF_Network_Disconnect_Th___);
end;

(*
  * TC40_LF_RecvTunnel.Create
  * -------------------------
  * Initializes the tunnel user object. Creates the fixed sequenced notify
  * pool and the API info hash list.
  *)
constructor TC40_LF_RecvTunnel.Create(Owner_: TPeerIO);
begin
  inherited Create(Owner_);
  Cycle_Int64_Anchor := 0;
  Fixed_Sequenced_Notify_Pool := TFixed_Sequenced_Notify_Pool.Create($FF, 0);
  Fixed_Sequenced_Temp_Time := 0;

  LF_Service := nil;
  APP_Name := '';
  APP_Desc := '';
  APP_Process_Info := '';
  api_info_data := THashList.Create;
  Host_Running_Thread_Num := 0;
  Wait_Reponse_Thread_Num := 0;
  Is_Local := False;
end;

(*
  * TC40_LF_RecvTunnel.Destroy
  * --------------------------
  * Frees the API info hash list and the sequenced notify pool.
  *)
destructor TC40_LF_RecvTunnel.Destroy;
begin
  DisposeObject(api_info_data);
  DisposeObject(Fixed_Sequenced_Notify_Pool);
  inherited Destroy;
end;

(*
  * TLF_ServiceInfo.Create
  * ----------------------
  * Creates an empty service info record.
  *)
constructor TLF_ServiceInfo.Create;
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

(*
  * TLF_ServiceInfo.Destroy
  * -----------------------
  * Frees the API info hash list.
  *)
destructor TLF_ServiceInfo.Destroy;
begin
  DisposeObject(api_info_data);
  inherited Destroy;
end;

(*
  * TLF_ServiceInfo.Assign
  * ----------------------
  * Copies the registration data from a receive-tunnel user object.
  *)
procedure TLF_ServiceInfo.Assign(source: TC40_LF_RecvTunnel);
begin
  APP_Name := source.APP_Name;
  APP_Desc := source.APP_Desc;
  APP_Process_Info := source.APP_Process_Info;
  api_info_data.Assign(source.api_info_data);
  Host_Running_Thread_Num := source.Host_Running_Thread_Num;
  Wait_Reponse_Thread_Num := source.Wait_Reponse_Thread_Num;
  Is_Local := source.Is_Local;
end;

(*
  * TLF_ServiceInfo.SaveToStream
  * ----------------------------
  * Serializes this service info to a stream using DFE encoding.
  *
  * Serialization order (strict):
  *   1. APP_Name
  *   2. APP_Desc
  *   3. APP_Process_Info
  *   4. api_info_data key-name list (Pascal string array)
  *   5. Host_Running_Thread_Num
  *   6. Wait_Reponse_Thread_Num
  *   7. Is_Local
  *)
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
  d.WriteInteger(Host_Running_Thread_Num);
  d.WriteInteger(Wait_Reponse_Thread_Num);
  d.WriteBool(Is_Local);
  d.FastEncodeTo(stream);
  DisposeObject(d);
end;

(*
  * TLF_ServiceInfo.LoadFromStream
  * ------------------------------
  * Deserializes service info from a stream. The order must match
  * SaveToStream exactly.
  *)
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
  Host_Running_Thread_Num := d.R.ReadInteger;
  Wait_Reponse_Thread_Num := d.R.ReadInteger;
  Is_Local := d.R.ReadBool;
  DisposeObject(d);
end;

(*
  * TLF_ServiceInfoPool.Create
  * --------------------------
  * Creates the pool with auto-free enabled (True).
  *)
constructor TLF_ServiceInfoPool.Create;
begin
  inherited Create(True);
end;

(*
  * TLF_ServiceInfoPool.Destroy
  * ---------------------------
  * Inherited, frees all objects.
  *)
destructor TLF_ServiceInfoPool.Destroy;
begin
  inherited Destroy;
end;

(*
  * TLF_ServiceInfoPool.Build_Info_Form
  * -----------------------------------
  * Builds a snapshot entry from a client's registration data.
  * Only adds the entry if the client has at least one registered API.
  *)
procedure TLF_ServiceInfoPool.Build_Info_Form(Inst: TC40_LF_RecvTunnel);
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

(*
  * TLF_ServiceInfoPool.SaveToStream
  * --------------------------------
  * Saves the entire pool to a DFE stream, serializing each item.
  * Returns immediately on an empty pool.
  *)
procedure TLF_ServiceInfoPool.SaveToStream(d: TDFE);
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

(*
  * TLF_ServiceInfoPool.LoadFromStream
  * ----------------------------------
  * Loads the pool from a DFE stream, creating TLF_ServiceInfo objects.
  *)
procedure TLF_ServiceInfoPool.LoadFromStream(d: TDFE);
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

(*
  * TLF_ServiceInfoPool.Find_API
  * ----------------------------
  * Checks if any entry has the given appName and exports the given API.
  *)
function TLF_ServiceInfoPool.Find_API(app_Name__, api_Name__: TLF_String): Boolean;
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

(*
  * TLF_ServiceInfoPool.Find_APP
  * ----------------------------
  * Checks if any entry has the given appName (regardless of APIs).
  *)
function TLF_ServiceInfoPool.Find_APP(app_Name__: TLF_String): Boolean;
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

(*
  * TC40_LF_SendTunnel.Create
  * -------------------------
  * Initializes the send tunnel user object with a nil service reference.
  *)
constructor TC40_LF_SendTunnel.Create(Owner_: TPeerIO);
begin
  inherited Create(Owner_);
  LF_Service := nil;
end;

(*
  * TC40_LF_SendTunnel.Destroy
  * --------------------------
  * Inherited.
  *)
destructor TC40_LF_SendTunnel.Destroy;
begin
  inherited Destroy;
end;

(*
  * TC40_LF_Service.Do_Delay_Broadcast_API_Info
  * -------------------------------------------
  * Schedules a broadcast of API info after a 2-second delay.
  * This coalesces multiple registration changes into a single broadcast.
  *)
procedure TC40_LF_Service.Do_Delay_Broadcast_API_Info;
begin
  FDelay_Broadcast_API_Info_Time := GetTimeTick() + 2000;
  FNeed_Broadcast_API_Info := True;
end;

(*
  * TC40_LF_Service.DoLinkSuccess_Event
  * -----------------------------------
  * Sets back-references in the receive and send tunnel user objects.
  *)
procedure TC40_LF_Service.DoLinkSuccess_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth);
var
  user_io: TC40_LF_RecvTunnel;
begin
  inherited DoLinkSuccess_Event(Sender, UserDefineIO);
  user_io := UserDefineIO as TC40_LF_RecvTunnel;
  user_io.LF_Service := Self;
  (user_io.SendTunnel as TC40_LF_SendTunnel).LF_Service := Self;
end;

(*
  * TC40_LF_Service.DoUserOut_Event
  * -------------------------------
  * Overridden; no extra logic needed because the user object will be freed
  * automatically when the connection drops. But if the user had an app or
  * API info, schedule a broadcast update.
  *)
procedure TC40_LF_Service.DoUserOut_Event(Sender: TDTService_NoAuth; UserDefineIO: TService_RecvTunnel_UserDefine_NoAuth);
var
  user_io: TC40_LF_RecvTunnel;
begin
  user_io := UserDefineIO as TC40_LF_RecvTunnel;
  if (user_io.APP_Name <> '') or (user_io.api_info_data.Count > 0) then
      Do_Delay_Broadcast_API_Info();
  inherited DoUserOut_Event(Sender, UserDefineIO);
end;

(*
  * TC40_LF_Service.cmd_Init_APP_Info
  * ---------------------------------
  * Registers an application from a client. Reads the application name,
  * description, process info, and the list of API names, and stores them
  * in the receive-tunnel user object. Also schedules a broadcast to all
  * clients.
  *
  * Parameters:
  *   Sender: The bridge that contains the incoming data.
  *   InData: DFE containing: appName, appDesc, processInfo, a
  *     Pascal-string list of API names, and a boolean Is_Local flag.
  *   OutData: Unused.
  *)
procedure TC40_LF_Service.cmd_Init_APP_Info(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
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

  (* Auto-generated applications (with C_Generate_Prefix) trigger an
     immediate broadcast; others go through the coalescing window. *)
  if user_io.APP_Name.StrExists(C_Generate_Prefix) then
    begin
      Broadcast_API_Info;
      FNeed_Broadcast_API_Info := False;
    end
  else Do_Delay_Broadcast_API_Info();
end;

(*
  * TC40_LF_Service.cmd_No_App_Info
  * -------------------------------
  * Handles a client that has no application to register (or an empty app).
  * Clears the registration data and schedules a broadcast.
  *)
procedure TC40_LF_Service.cmd_No_App_Info(Sender: TPeerIO; InData: SystemString);
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

(*
  * TC40_LF_Service.cmd_Thread_State
  * --------------------------------
  * Receives runtime thread-count updates from a client and stores them in
  * the user object for load-aware routing.
  *)
procedure TC40_LF_Service.cmd_Thread_State(Sender: TPeerIO; InData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
begin
  user_io := DTNoAuthService.GetUserDefineRecvTunnel(Sender) as TC40_LF_RecvTunnel;
  if user_io = nil then
      exit;
  user_io.Host_Running_Thread_Num := InData.R.ReadInteger;
  user_io.Wait_Reponse_Thread_Num := InData.R.ReadInteger;
end;

(*
  * TC40_LF_Service.Do_Run_Notify_Th
  * --------------------------------
  * Background thread worker for executing a local notification.
  * Uses the TC40_LF_Client stored in thSender.UserObject.
  * Increments/decrements Host_Running_Thread_Num around the call.
  *)
procedure TC40_LF_Service.Do_Run_Notify_Th(thSender: THPC_StreamNotify; ThInData: TDFE);
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

(*
  * TC40_LF_Service.cmd_Notify
  * --------------------------
  * Routes an incoming notification to the appropriate destination.
  * 1) Tries local execution (same process) via Find_Local_API.
  * 2) If not found, forwards to other service instances (IPC first, then
  *    remote).
  * 3) Logs an error if no matching destination is found.
  *)
procedure TC40_LF_Service.cmd_Notify(Sender: TPeerIO; InData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
  app_Name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  tmp_cli__: TC40_LF_Client;

  (*
    * Iterate through the service instance array, find the first instance
    * that exports the target API and forward the notification to it.
    *)
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

(*
  * TC40_LF_Service.cmd_Sequenced_Notify
  * ------------------------------------
  * Routes a sequenced notification. Uses Find_Fixed_Sequenced_Local_API or
  * Find_Fixed_Sequenced_Remote_API to choose a client based on the
  * least-recently-used timestamp for the (app, api) pair. If found locally,
  * it posts to the global sequenced thread pool; otherwise forwards to
  * another service instance.
  *)
procedure TC40_LF_Service.cmd_Sequenced_Notify(Sender: TPeerIO; InData: TDFE);
var
  user_io: TC40_LF_RecvTunnel;
  app_Name__: TLF_String;
  Param: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  tmp_cli__: TC40_LF_Client;

  (*
    * Iterate through the service instance array, find the first instance
    * that can host the sequenced notification and forward to it.
    *)
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

(*
  * TC40_LF_Service.Do_Run_Call_Th
  * ------------------------------
  * Background thread worker for executing a local synchronous call.
  * Uses the TC40_LF_Client stored in thSender.UserObject.
  * Increments/decrements Host_Running_Thread_Num around the call.
  *)
procedure TC40_LF_Service.Do_Run_Call_Th(thSender: THPC_CompleteBuffer_Stream; ThInData, ThOutData: TDFE);
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

(*
  * TC40_LF_Service.cmd_Call
  * ------------------------
  * Routes an incoming synchronous call. Tries local execution first, then
  * forwards to other service instances.
  *)
procedure TC40_LF_Service.cmd_Call(Sender: TCommandCompleteBuffer_NoWait_Bridge; InData, OutData: TDFE);
var
  app_Name__: TLF_String;
  Param, Output: TMem64;
  api_Name__: TLF_String;
  arry: TC40_Custom_Service_Array;
  tmp_cli__: TC40_LF_Client;

  (*
    * Iterate through the service instance array, find the first instance
    * that can host the call and forward to it.
    *)
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

(*
  * TC40_LF_Service.Create
  * ----------------------
  * Constructor: sets up the service with custom user-defined classes,
  * configures buffer sizes, and registers the command handlers.
  * Temporarily disables per-service directories to avoid clutter.
  *)
constructor TC40_LF_Service.Create(PhysicsService_: TC40_PhysicsService; ServiceTyp, Param_: U_String);
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

(*
  * TC40_LF_Service.Destroy
  * -----------------------
  * Inherited.
  *)
destructor TC40_LF_Service.Destroy;
begin
  inherited Destroy;
end;

(*
  * TC40_LF_Service.SafeCheck
  * -------------------------
  * Inherited.
  *)
procedure TC40_LF_Service.SafeCheck;
begin
  inherited SafeCheck;
end;

(*
  * TC40_LF_Service.Progress
  * ------------------------
  * Main progress method. Drives the network and triggers a broadcast when
  * the scheduled broadcast time is reached.
  *)
procedure TC40_LF_Service.Progress;
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

(*
  * TC40_LF_Service.Broadcast_API_Info
  * ----------------------------------
  * Builds a snapshot of all registered applications and sends it to every
  * connected client using the 'update_service_api_info' command.
  *
  * Note: final_data is cloned for each receiver (NewClone) because
  * SendCompleteBuffer takes ownership and does not copy the data.
  *)
procedure TC40_LF_Service.Broadcast_API_Info();
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

(*
  * TC40_LF_Service.Do_Cmp_Last_Selected_Time__
  * -------------------------------------------
  * Comparison function: ascending by Cycle_Int64_Anchor, used to sort
  * connected clients for load balancing (pick the least recently used).
  *)
function TC40_LF_Service.Do_Cmp_Last_Selected_Time__(var L, R: TC40_LF_RecvTunnel): Integer;
begin
  Result := CompareInt64(L.Cycle_Int64_Anchor, R.Cycle_Int64_Anchor);
end;

(*
  * TC40_LF_Service.Find_API
  * ------------------------
  * Scans all connected clients and returns the receive-tunnel user object
  * of the first one that matches the given application name (wildcard)
  * and exposes the specified API. If multiple clients match, the one with
  * the lowest Cycle_Int64_Anchor is returned (load balancing).
  *)
function TC40_LF_Service.Find_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
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
      Result.Cycle_Int64_Anchor := Get_Cycle_Anchor();
    end;
  DisposeObject(L);
end;

(*
  * TC40_LF_Service.Do_Inv_Cmp_Temp_Sequence_Value__
  * -------------------------------------------------
  * Comparison function: descending by Fixed_Sequenced_Temp_Time.
  *)
function TC40_LF_Service.Do_Inv_Cmp_Temp_Sequence_Value__(var L, R: TC40_LF_RecvTunnel): Integer;
begin
  Result := CompareUInt64(R.Fixed_Sequenced_Temp_Time, L.Fixed_Sequenced_Temp_Time);
end;

(*
  * TC40_LF_Service.Find_Fixed_Sequenced_API
  * ----------------------------------------
  * Similar to Find_API but for sequenced notifications. Uses the
  * least-recently-used timestamp for the (app, api) key to select a client.
  * If multiple clients match, it computes each client's timestamp and
  * sorts in descending order (oldest first). The client with the oldest
  * timestamp (or the last if older than 5 minutes) is selected, and its
  * timestamp is updated.
  *)
function TC40_LF_Service.Find_Fixed_Sequenced_API(app_Name__, api_Name__: TLF_String): TC40_LF_RecvTunnel;
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
            queue^.Data.Fixed_Sequenced_Temp_Time := queue^.Data.Fixed_Sequenced_Notify_Pool.Get_Default_Value(n, 0);
        until not Next;
      L.Sort_M(Do_Inv_Cmp_Temp_Sequence_Value__);
    end;

  if L.Num > 0 then
    begin
      Result := L.First^.Data;
      if GetTimeTick() - Result.Fixed_Sequenced_Temp_Time > Fixed_Sequenced_Time then
          Result := L.Last^.Data;
      Result.Fixed_Sequenced_Notify_Pool.Set_Key_Value(n, GetTimeTick());
    end;

  DisposeObject(L);
end;

(*
  * TC40_LF_Client.Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink
  * ----------------------------------------------------------
  * Called when the double-tunnel link is established. If an APP is set,
  * automatically registers it with the service.
  *)
procedure TC40_LF_Client.Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender: TDT_P2PVM_NoAuth_Custom_Client);
begin
  inherited Do_DT_P2PVM_NoAuth_Custom_Client_TunnelLink(Sender);
  Init_App_Info;
end;

(*
  * TC40_LF_Client.cmd_update_service_api_info
  * ------------------------------------------
  * Receives the service's broadcast of available applications and updates
  * the local FService_Info cache. The data is DFE-encoded. The first time
  * this fires, it triggers the network connect event.
  *)
procedure TC40_LF_Client.cmd_update_service_api_info(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
var
  m64: TMS64;
  d: TDFE;
  addr_: TLF_String;
begin
  m64 := TMS64.Create;
  m64.Mapping(InData, DataSize);
  d := TDFE.Create;
  d.DecodeFrom(m64, True);
  DisposeObject(m64);
  Find_Safe_Critical.Lock;
  try
      FService_Info.LoadFromStream(d);
  finally
      Find_Safe_Critical.UnLock;
  end;
  DisposeObject(d);

  (* Trigger the network connect event on the first broadcast (not on the
     TCP handshake). *)
  if not FService_Info_Is_Onlne then
    begin
      if C40PhysicsTunnel.IPC_Mode then
          addr_ := C40PhysicsTunnel.PhysicsAddr
      else
          addr_ := Build_Host_URL(C40PhysicsTunnel.PhysicsAddr, C40PhysicsTunnel.PhysicsPort);
      Do_LF_Network_Connect(addr_);
    end;
  FService_Info_Is_Onlne := True;
end;

(*
  * TC40_LF_Client.Do_Notify
  * ------------------------
  * Background thread worker for executing a local notification.
  * Maps the raw input buffer to a TMem64 and invokes Execute_Notify on the
  * local APP. Increments/decrements Host_Running_Thread_Num.
  *)
procedure TC40_LF_Client.Do_Notify(thSender: THPC_CompleteBuffer; ThInData: PByte; ThDataSize: NativeInt);
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

(*
  * TC40_LF_Client.cmd_Notify
  * -------------------------
  * Handles incoming 'Notify' commands by offloading processing to a
  * background thread using RunHPC_CompleteBufferM.
  *)
procedure TC40_LF_Client.cmd_Notify(Sender: TPeerIO; InData: PByte; DataSize: NativeInt);
begin
  if FAPP = nil then
      exit;
  RunHPC_CompleteBufferM(Sender, nil, nil, InData, DataSize, Do_Notify);
end;

(*
  * TC40_LF_Client.cmd_Sequenced_Notify
  * -----------------------------------
  * Handles incoming 'Sequenced_Notify' commands. Extracts the API name,
  * creates a TMem64, and posts it to the global sequenced notification pool
  * for the current APP.
  *)
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
  LF_Notify_Sequence_Thread_Pool.Post_Notify2(APP, m64.NewClone);
  DisposeObject(m64);
end;

(*
  * TC40_LF_Client.cmd_Call
  * -----------------------
  * Handles incoming 'Call' commands synchronously. Decodes the request,
  * executes the API call locally, and writes the result back.
  * This runs in the main thread (not background).
  *)
procedure TC40_LF_Client.cmd_Call(Sender: TPeerIO; InData, OutData: TDFE);
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

(*
  * TC40_LF_Client.Do_APP_Update
  * ----------------------------
  * Called when the APP's API list changes. Re-registers the app with the
  * service.
  *)
procedure TC40_LF_Client.Do_APP_Update(Sender: TLF_App);
begin
  Init_App_Info;
end;

(*
  * TC40_LF_Client.Create
  * ---------------------
  * Constructor: initializes the client, creates the service info pool,
  * atomic counters, and fixed sequenced pool, and registers command
  * handlers.
  *)
constructor TC40_LF_Client.Create(PhysicsTunnel_: TC40_PhysicsTunnel; source_: TC40_Info; Param_: U_String);
begin
  inherited Create(PhysicsTunnel_, source_, Param_);
  FService_Info := TLF_ServiceInfoPool.Create;
  FHost_Running_Thread_Num := TAtomInt32.Create(0);
  FWait_Reponse_Thread_Num := TAtomInt32.Create(0);
  FLast_Update_Thread_State_TimeTick := 0;
  FAPP := nil;
  FAPI_APP_Is_Online := False;
  FService_Info_Is_Onlne := False;
  Cycle_Int64_Anchor := 0;
  Fixed_Sequenced_Notify_Pool := TFixed_Sequenced_Notify_Pool.Create($FF, 0);
  Fixed_Sequenced_Temp_Time := 0;

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

(*
  * TC40_LF_Client.Destroy
  * ----------------------
  * Destructor: removes the APP update subscription, waits for background
  * threads to finish (with a 2-second timeout), and frees resources.
  *)
destructor TC40_LF_Client.Destroy;
var
  tk: TTimeTick;
begin
  if FAPP <> nil then
      FAPP.Remove_Update(Self);
  tk := GetTimeTick() + 2000;
  while (FHost_Running_Thread_Num.V + FWait_Reponse_Thread_Num.V > 0) and (GetTimeTick() < tk) do
      TCompute.Sleep(10);
  DisposeObjectAndNil(FHost_Running_Thread_Num);
  DisposeObjectAndNil(FWait_Reponse_Thread_Num);
  DisposeObjectAndNil(FService_Info);
  DisposeObjectAndNil(Fixed_Sequenced_Notify_Pool);
  inherited Destroy;
end;

(*
  * TC40_LF_Client.SafeCheck
  * ------------------------
  * Inherited.
  *)
procedure TC40_LF_Client.SafeCheck;
begin
  inherited SafeCheck;
end;

(*
  * TC40_LF_Client.Progress
  * -----------------------
  * Main progress method. If the client is online, sends thread-state updates
  * to the service every second (throttled to a 100 ms check interval).
  *)
procedure TC40_LF_Client.Progress;
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

(*
  * TC40_LF_Client.DoNetworkOnline
  * ------------------------------
  * Inherited.
  *)
procedure TC40_LF_Client.DoNetworkOnline;
begin
  inherited DoNetworkOnline;
end;

(*
  * TC40_LF_Client.DoNetworkOffline
  * -------------------------------
  * Called when the client disconnects; resets the online flag and triggers
  * the network disconnect event.
  *)
procedure TC40_LF_Client.DoNetworkOffline;
var
  addr_: TLF_String;
begin
  inherited DoNetworkOffline;
  FAPI_APP_Is_Online := False;
  FService_Info_Is_Onlne := False;

  if C40PhysicsTunnel.IPC_Mode then
      addr_ := C40PhysicsTunnel.PhysicsAddr
  else
      addr_ := Build_Host_URL(C40PhysicsTunnel.PhysicsAddr, C40PhysicsTunnel.PhysicsPort);
  Do_LF_Network_Disconnect(addr_);
end;

(*
  * TC40_LF_Client.Update_LocalThread_State_To_Service
  * --------------------------------------------------
  * Sends the current thread-count statistics to the service using the
  * 'Thread_State' command. This allows the service to perform load-aware
  * routing.
  *)
procedure TC40_LF_Client.Update_LocalThread_State_To_Service;
begin
  if not LF_AppIsOnline then
      exit;
  DTNoAuth.SendTunnel.SendCompleteBuffer_StreamNotify('Thread_State',
    TDFE.Create.WriteInteger(FHost_Running_Thread_Num.V).WriteInteger(FWait_Reponse_Thread_Num.V).DelayFree);
end;

(*
  * TC40_LF_Client.Do_Init_App_Info_Result
  * --------------------------------------
  * Callback for the 'Init_APP_Info' command's response. Sets the online
  * flag to True, indicating registration was successful, and subscribes to
  * APP updates.
  *)
procedure TC40_LF_Client.Do_Init_App_Info_Result(Sender: TPeerIO; Result_: TDFE);
begin
  FAPI_APP_Is_Online := True;
  FAPP.Subscribe_Update(Self, Do_APP_Update);
end;

(*
  * TC40_LF_Client.Init_App_Info
  * ----------------------------
  * Builds a list of API names from the current TLF_App and sends the
  * registration to the service using the 'Init_APP_Info' command.
  * If APP is nil or has no name, sends a 'No_App_Info' notification
  * instead.
  *)
procedure TC40_LF_Client.Init_App_Info;
var
  api_info_data: TPascalStringList;
  R: TLF_MethodPool.TRepeat___;
begin
  if (APP = nil) or (APP.Name.TrimChar(#32#9) = '') then
    begin
      DTNoAuth.SendTunnel.SendConsoleNotifyCmd('No_App_Info', Make_LingoFuse_Process_Name());
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
      .WriteString(Make_LingoFuse_Process_Name())
      .WritePascalStrings(api_info_data)
      .WriteBool(IsLocal())
      .DelayFree,
    Do_Init_App_Info_Result);
  DisposeObject(api_info_data);
end;

(*
  * TC40_LF_Client.Set_API_APP
  * --------------------------
  * Binds a new TLF_App to the client. If the client is already connected,
  * immediately registers the new app with the service.
  *)
procedure TC40_LF_Client.Set_API_APP(const Value: TLF_App);
begin
  if FAPP <> nil then
      FAPP.Remove_Update(Self);
  FAPP := Value;
  if DTNoAuth.LinkOk then
      Init_App_Info;
end;

(*
  * TC40_LF_Client.Send_Execute_Notify___
  * -------------------------------------
  * Internal method that sends a non-sequenced notification by forwarding
  * to the service. The payload is wrapped in a DFE and sent via the send
  * tunnel. If the payload is large (> 100 KB), sends a NULL packet to
  * flush the buffer.
  *)
procedure TC40_LF_Client.Send_Execute_Notify___(const app_Name__: TLF_String; Param: TMem64);
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

(*
  * TC40_LF_Client.Send_Execute_Notify
  * ----------------------------------
  * Sends a non-sequenced notification to the target application. Performs
  * local execution if the target matches a local client; otherwise forwards
  * to the service.
  *)
procedure TC40_LF_Client.Send_Execute_Notify(const app_Name__: TLF_String; Param: TMem64);
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

(*
  * TC40_LF_Client.Send_Sequenced_Notify___
  * ---------------------------------------
  * Internal method that sends a sequenced notification by forwarding to the
  * service. Similar to Send_Execute_Notify___ but uses the
  * 'Sequenced_Notify' command.
  *)
procedure TC40_LF_Client.Send_Sequenced_Notify___(const app_Name__: TLF_String; Param: TMem64);
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

(*
  * TC40_LF_Client.Send_Sequenced_Notify
  * ------------------------------------
  * Sends a sequenced notification. Uses Find_Fixed_Sequenced_Local_API or
  * Find_Fixed_Sequenced_Remote_API to choose the correct client (locally
  * or remotely) and posts to the appropriate sequenced thread.
  *)
procedure TC40_LF_Client.Send_Sequenced_Notify(const app_Name__: TLF_String; Param: TMem64);
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

(*
  * TC40_LF_Client.Wait_Execute_Call___
  * -----------------------------------
  * Internal method that performs a synchronous call by forwarding to the
  * service. Blocks until the response arrives or the timeout expires.
  * Uses TLF_CallBridge to capture the asynchronous result.
  *)
function TC40_LF_Client.Wait_Execute_Call___(const app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
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
  DTNoAuth.SendTunnel.SendCompleteBuffer_NoWait_StreamM('Call', TDFE.Create.WriteString(app_Name__).WriteMem64(Param).DelayFree, tmp.Do_Result);
  if Param.Size > 100 * 1024 then DTNoAuth.SendTunnel.SendNULL;
  tk := GetTimeTick + TimeOut__;
  while tmp.IsRunning do
    begin
      TCompute.Sleep(10);
      if (LF_CheckMainThread <= 0) or ((TimeOut__ > 0) and (GetTimeTick > tk)) then
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

(*
  * TC40_LF_Client.Wait_Execute_Call
  * --------------------------------
  * Performs a synchronous call to the target application. First tries local
  * execution (same process), then remote execution via the service.
  *)
function TC40_LF_Client.Wait_Execute_Call(const app_Name__: TLF_String; Param: TMem64; TimeOut__: TTimeTick): TMem64;
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

(*
  * TLF_CallBridge.Create
  * ---------------------
  * Initializes the bridge with an empty output and sets IsRunning to False.
  *)
constructor TLF_CallBridge.Create;
begin
  inherited Create;
  Cli := nil;
  Output := TMem64.Create;
  IsRunning := False;
  Error_ := False;
end;

(*
  * TLF_CallBridge.Destroy
  * ----------------------
  * Frees the output memory.
  *)
destructor TLF_CallBridge.Destroy;
begin
  DisposeObjectAndNil(Output);
  inherited Destroy;
end;

(*
  * TLF_CallBridge.Do_Result
  * ------------------------
  * Called when the asynchronous response for a call arrives. Reads the
  * result TMem64 from the DFE and signals completion by setting IsRunning
  * to False.
  *)
procedure TLF_CallBridge.Do_Result(Sender: TPeerIO; Result_: TDFE);
begin
  Error_ := Result_.Count <= 0;
  if not Error_ then
      Result_.R.ReadMem64(Output);
  IsRunning := False;
end;

initialization

(*
  * Register the 'LingoFuse' service type in the global C4 registry.
  * Afterwards, calling BuildDependNetwork('LingoFuse') creates the
  * service.
  *)
RegisterC40('LingoFuse', TC40_LF_Service, TC40_LF_Client);

(* Sequenced notification fallback threshold: 20 seconds. *)
Fixed_Sequenced_Time := Z.Core.C_Tick_Second * 20;

(* Process name cache is cleared first; generated on first call to
   Make_LingoFuse_Process_Name. *)
LingoFuse_Process_Name := '';

(* Critical sections for lookups and sorting. *)
Find_Safe_Critical := TCritical.Create('Find_Hub_Safe_Critical');
Sort_Safe_Critical := TCritical.Create('Sort_Safe_Critical');

(* Global cycle anchor seed. *)
Cycle_Anchor_Seed := TAtomInt64.Create(0);

finalization

DisposeObjectAndNil(Find_Safe_Critical);
DisposeObjectAndNil(Sort_Safe_Critical);
DisposeObjectAndNil(Cycle_Anchor_Seed);

end.