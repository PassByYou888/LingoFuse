(*
  * ===========================================================================
  * Z.LingoFuse_Export – C ABI Export Layer for LingoFuse
  * ===========================================================================
  *
  * This unit provides a set of plain C-style (cdecl) functions that can be
  * called from any programming language that supports dynamic library imports
  * (C, C++, C#, Python, Java, Rust, Go, Pascal, etc.). It acts as a binary
  * bridge between external applications and the internal LingoFuse core
  * objects (TLF_App, TLF_Data, TLF_Engine) and the C4 distributed service
  * layer.
  *
  * The exported functions manage:
  *   – Opaque handles for API data (TDataHnd___) and application instances
  *     (TAppHnd___). These handles must be created and freed using the provided
  *     functions – never dereference them directly.
  *   – Registration of local Call and Notify APIs with user-supplied cdecl
  *     callbacks.
  *   – Preparation and startup of the underlying C4 distributed communication
  *     layer (TCP and IPC).
  *   – Remote API calls and notifications (including sequenced notifications)
  *     across a network.
  *
  * The unit also manages a simulated main thread that runs the C4 progress
  * loop, making the library self-contained for applications that do not have
  * their own main loop. All exported functions are thread-safe; they can be
  * called concurrently from multiple threads.
  *
  * Runtime parameters (timeouts, logging, IPC settings) can be adjusted
  * dynamically via the LF_SetOption function. They are not automatically
  * persisted to disk; if persistence is needed, applications should read/write
  * their own configuration files.
  *
  * All string parameters (API names, descriptions, addresses) must be UTF-8
  * encoded and null-terminated (PAnsiChar). The library internally decodes
  * them to Pascal strings. The internal binary data handles are encoding-
  * agnostic – they are just byte buffers.
  *
  * ===========================================================================
  * THREAD SAFETY & CALLBACK RESTRICTIONS
  * ===========================================================================
  *
  * – All exported functions are thread-safe. They may be called from any
  *   thread without external locking.
  *
  * – For a given TDataHnd___: write operations must be serialised. Read
  *   operations are safe as long as the handle is not being written
  *   concurrently.
  *
  * – [PITFALL] Callbacks registered via LF_RegisterCall / LF_RegisterNotify
  *   and the network event handlers installed via LF_Set_Network_Event all
  *   run on BACKGROUND WORKER THREADS. Inside a callback you MUST NOT:
  *       * touch UI controls directly (VCL / LCL / GDI / OpenGL context);
  *       * call any blocking LingoFuse function (LF_Call, LF_LocalCall,
  *         LF_PrepareDone, LF_Shutdown) – this will deadlock;
  *       * block for a long time – worker threads are a shared resource.
  *   Offload heavy work to a dedicated thread, and marshal UI updates back
  *   to the main thread.
  *
  * – [PITFALL] Callback exceptions are SILENTLY SWALLOWED by the library.
  *   Do not rely on exceptions for control flow; log explicitly if you
  *   need diagnostics.
  *
  * – [PITFALL] Callback parameter strings (such as the addr_ in
  *   TLF_Network_Event) are typically valid ONLY DURING THE CALLBACK
  *   INVOCATION. Copy them (e.g. strdup / string assignment) before
  *   returning, if you need to retain them.
  *
  * ===========================================================================
  * @Example (local app registration and call in C):
  *   #include "LingoFuse.h"
  *   static void __cdecl AddCallback(void* Trigger, void* Input, void* Output) {
  *       int a, b;
  *       LF_ReadBuffer(Input, &a, sizeof(a));
  *       LF_ReadBuffer(Input, &b, sizeof(b));
  *       int sum = a + b;
  *       LF_WriteBuffer(Output, &sum, sizeof(sum));
  *   }
  *   int main() {
  *       TAppHnd___ app = LF_CreateApp("Demo", "Example");
  *       LF_RegisterCall(app, "add", "Add two ints", NULL, AddCallback);
  *       TDataHnd___ data = LF_CreateData("add");
  *       int a=5, b=7;
  *       LF_WriteBuffer(data, &a, sizeof(a));
  *       LF_WriteBuffer(data, &b, sizeof(b));
  *       TDataHnd___ result = LF_LocalCall(app, data);
  *       LF_FreeData(data);
  *       if (result) { int sum; LF_ReadBuffer(result, &sum, sizeof(sum)); }
  *       LF_FreeData(result);
  *       LF_FreeApp(app);
  *       LF_Shutdown();
  *       return 0;
  *   }
  *
  * For remote calls, prepare a service and clients with LF_PrepareService /
  * LF_PrepareClient, then start with LF_PrepareDone, and use LF_Call /
  * LF_Notify / LF_Sequenced_Notify with application names.
  *
  * Dependencies: Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status,
  *   Z.UnicodeMixedLib, Z.Net.C4, Z.LingoFuse_Core, Z.Net.C4.LingoFuse, etc.
  *
  * ===========================================================================
  * WARNING: This file has been heavily commented for clarity. All comments
  * are for documentation purposes and do not affect runtime behaviour.
  * ===========================================================================
*)
unit Z.LingoFuse_Export;

{$DEFINE FPC_DELPHI_MODE}
{$I ..\pascal\zNetV2\source\Z.Define.inc}

interface

const
  C_LingoFuse_Edition = '3.05';

type
  (*
    * TDataHnd___: Opaque handle to a LingoFuse data buffer.
    *
    * Internally this is a pointer to a TLF_Data record, but external code
    * MUST NEVER dereference it. Use the provided LF_* functions to read,
    * write, and manage its contents.
    *
    * Lifecycle:
    *   – Created with LF_CreateData.
    *   – Freed with LF_FreeData.
    *
    * [PITFALL] A data handle that is never touched for 5 minutes is
    *   automatically reclaimed by the internal idle pool. The reclamation
    *   runs asynchronously on the main thread, and a log line like
    *   `hint: Data handle pool "N" handles were idle...` is emitted. If
    *   you need a handle to survive longer, refresh it periodically
    *   (e.g. by calling LF_GetSize / LF_GetPos / any accessor).
    *
    * [PITFALL] LF_FreeData is a no-op while the simulated main thread is
    *   not active (i.e. before LF_PrepareDone or after LF_ExitMainThread).
    *   This is by design – it avoids double-free during library
    *   initialisation/finalisation.
    *)
  TDataHnd___ = Pointer;

  (*
    * TAppHnd___: Opaque handle to a LingoFuse application context (TLF_App).
    *
    * Represents a logical application that can host multiple APIs.
    * Created with LF_CreateApp, detached with LF_FreeApp.
    *
    * [PITFALL] LF_FreeApp does NOT immediately destroy the underlying
    *   TLF_App. It only detaches the app from all clients and stops
    *   sequenced notification threads. The object stays alive in the
    *   global LF_App_Pool until LF_Shutdown, which frees it for real.
    *   After LF_FreeApp, treat the handle as invalid – do not register
    *   APIs or perform calls through it.
    *)
  TAppHnd___ = Pointer;

  (*
    * TLF_Call_Event: Callback prototype for request-response (Call) APIs.
    *
    * [PITFALL] MUST be declared with the cdecl calling convention. The
    *   default Pascal convention (register / fastcall) will corrupt the
    *   stack when invoked from the C ABI layer.
    *
    * [PITFALL] Runs on a worker thread. See the unit header for the full
    *   contract of what is forbidden inside a callback.
    *
    * @param Trigger  User-supplied pointer passed to the callback unchanged.
    * @param Input    TDataHnd___ containing the serialised request parameters.
    *                 Read with LF_ReadBuffer / LF_GetBuffer.
    * @param Output   TDataHnd___ to hold the result. Write with
    *                 LF_WriteBuffer / LF_SetSize.
    *
    * @Example (Pascal):
    *   procedure MyCall(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
    *   var a, b, sum: Integer;
    *   begin
    *     LF_ReadBuffer(Input, @a, SizeOf(a));
    *     LF_ReadBuffer(Input, @b, SizeOf(b));
    *     sum := a + b;
    *     LF_WriteBuffer(Output, @sum, SizeOf(sum));
    *   end;
    *)
  TLF_Call_Event = procedure(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;

  (*
    * TLF_Notify_Event: Callback prototype for one-way notification APIs.
    *
    * [PITFALL] MUST be cdecl (see TLF_Call_Event for the rationale).
    *
    * [PITFALL] Runs on a worker thread. Do not touch UI, do not call
    *   blocking LF_* functions, do not assume the caller thread.
    *
    * @param Trigger  User-supplied pointer.
    * @param Input    TDataHnd___ containing the notification payload.
    *                 Read with LF_ReadBuffer / LF_GetBuffer.
    *                 No output is produced.
    *)
  TLF_Notify_Event = procedure(Trigger: Pointer; Input: TDataHnd___); cdecl;

  (*
    * TLF_Network_Event: Callback prototype for network connect/disconnect
    * notifications at the transport layer.
    *
    * ===========================================================================
    * TRIGGER MECHANICS (confirmed by source inspection)
    * ===========================================================================
    *
    * Connect path:
    *   TC40_LF_Client.cmd_update_service_api_info
    *     → (on first service-info broadcast) Do_LF_Network_Connect
    *     → TCompute.RunC(...) → On_Network_Connect_Event(addr_)
    *
    * Disconnect path:
    *   TC40_LF_Client.DoNetworkOffline
    *     → Do_LF_Network_Disconnect
    *     → TCompute.RunC(...) → On_Network_Disconnect_Event(addr_)
    *
    * ===========================================================================
    * SEMANTIC CONTRACT
    * ===========================================================================
    *
    * – "Connect" is NOT the same as "TCP handshake completed". It fires only
    *   after the client has received its FIRST service-API-info broadcast
    *   from the server. That is the earliest point at which remote routing
    *   can actually be performed.
    *
    * – "Disconnect" fires when the physical link is lost.
    *
    * – Both events fire exactly ONCE per connection lifecycle:
    *       * Connect fires once per `FService_Info_Is_Onlne` False → True
    *         transition.
    *       * Disconnect fires once per DoNetworkOffline invocation (i.e.
    *         actual link loss).
    *
    * ===========================================================================
    * PITFALLS
    * ===========================================================================
    *
    * [PITFALL – THREADING] The callback runs on a BACKGROUND TCompute WORKER
    *   THREAD. It is neither the caller thread nor the main thread. Never
    *   touch UI controls directly. Use main-thread marshalling
    *   (e.g. TThread.Queue, Synchronize) if UI update is required.
    *
    * [PITFALL – LIFETIME] The addr_ parameter is a raw UTF-8 PAnsiChar
    *   buffer owned by the library. It is released IMMEDIATELY AFTER this
    *   callback returns (via TLF_String.FreeUTF8AnsiChar). DO NOT retain
    *   the pointer, and DO NOT free it. Copy the content (e.g. strdup in
    *   C, string assignment in Pascal) if you need it beyond the call.
    *
    * [PITFALL – EXCEPTIONS] Exceptions raised inside the callback are
    *   silently swallowed by the library. Do not use exceptions for
    *   control flow here; log explicitly if you need diagnostics.
    *
    * [PITFALL – ABI] The callback MUST be declared cdecl to be
    *   ABI-compatible with the C export layer.
    *
    * [PITFALL – BLOCKING] Never call blocking LingoFuse functions
    *   (LF_Call, LF_LocalCall, LF_PrepareDone, LF_Shutdown) inside this
    *   callback. It will deadlock.
    *
    * [PITFALL – GLOBAL SCOPE] These events are process-global. There is
    *   currently no per-client registration API. If you need per-client
    *   callbacks, do the filtering yourself by inspecting addr_.
    *
    * @param addr_  Null-terminated UTF-8 string identifying the remote
    *               endpoint (host URL or IPC address). Valid only during
    *               the callback.
    *
    * @Example (Pascal):
    *   procedure OnConnect(addr: PAnsiChar); cdecl;
    *   var s: string;
    *   begin
    *     s := UTF8ToString(addr);   // copy inside the callback
    *     TThread.Queue(nil,
    *       procedure
    *       begin
    *         Memo1.Lines.Add('Connected to ' + s);
    *       end);
    *   end;
    *
    * @Example (C):
    *   static void __cdecl OnConnect(const char* addr) {
    *       char* copy = strdup(addr);  // copy now, use later
    *       post_to_ui_thread(copy);
    *   }
    *)
  TLF_Network_Event = procedure(addr_: pansichar); cdecl;

  (*
    * LF_CreateData: Creates a new data handle initialised with the
    * given API name. The internal buffer is empty (size = 0).
    *
    * @param MethodName  Null-terminated UTF-8 string naming the target API.
    * @return A new TDataHnd___ (never nil). Must be freed with LF_FreeData.
    *
    * [PITFALL] The returned handle is tracked by an idle pool that
    *   reclaims untouched handles after 5 minutes. Refresh it if you
    *   need to keep it longer.
    *
    * @Example:
    *   TDataHnd___ d = LF_CreateData("echo");
    *   int value = 123;
    *   LF_WriteBuffer(d, &value, sizeof(value));
    *   // ... use d in a call ...
    *   LF_FreeData(d);
    *)
function LF_CreateData(MethodName: pansichar): TDataHnd___; cdecl;

(*
  * LF_FreeData: Destroys a data handle and releases all associated
  * memory. After this call, the handle is invalid.
  *
  * @param Hnd  The handle to free (can be nil, does nothing).
  *
  * [PITFALL] If the simulated main thread is not active (i.e. before
  *   LF_PrepareDone or after LF_ExitMainThread), the call is a NO-OP.
  *   This is intentional – it avoids double-free during library
  *   initialisation/finalisation.
  *)
procedure LF_FreeData(Hnd: TDataHnd___); cdecl;

(*
  * LF_GetBuffer: Returns a direct pointer to the raw binary data in the
  * handle. The pointer is valid until the handle is freed or the buffer
  * is resized.
  *
  * @param Hnd  The data handle.
  * @return Pointer to internal memory block, or nil if empty.
  *
  * [PITFALL] Do NOT free the returned pointer – it is owned by the handle.
  * [PITFALL] The pointer becomes invalid as soon as the buffer is resized
  *   (e.g. by LF_WriteBuffer or LF_SetSize).
  *)
function LF_GetBuffer(Hnd: TDataHnd___): Pointer; cdecl;

(*
  * LF_WriteBuffer: Appends or overwrites binary data into the handle's
  * buffer at the current position. The position advances by the number of
  * bytes written. The buffer is automatically enlarged if needed.
  *
  * @param Hnd   The data handle.
  * @param Buff  Source data pointer.
  * @param Size  Number of bytes to write.
  * @return Number of bytes written (normally equals Size).
  *)
function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl;

(*
  * LF_ReadBuffer: Reads binary data from the handle's buffer into the
  * caller's buffer, starting at the current position. The position
  * advances by the number of bytes actually read.
  *
  * @param Hnd   The data handle.
  * @param Buff  Destination buffer.
  * @param Size  Maximum number of bytes to read.
  * @return Number of bytes actually read (may be less than Size if EOF).
  *)
function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl;

(*
  * LF_GetPos: Returns the current read/write position (zero-based).
  * @param Hnd  The data handle.
  * @return Current offset in bytes.
  *)
function LF_GetPos(Hnd: TDataHnd___): int64; cdecl;

(*
  * LF_SetPos: Sets the current read/write position. If the new position
  * is beyond the current size, the buffer is extended with zero bytes.
  * @param Hnd   The data handle.
  * @param Pos_  New position (must be >= 0).
  *)
procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64); cdecl;

(*
  * LF_GetSize: Returns the total size (in bytes) of the data stored in
  * the handle.
  * @param Hnd  The data handle.
  * @return Current buffer size.
  *)
function LF_GetSize(Hnd: TDataHnd___): int64; cdecl;

(*
  * LF_SetSize: Resizes the internal buffer to the specified size.
  * If larger, the added space is uninitialised; if smaller, data beyond
  * the new size is discarded.
  * @param Hnd    The data handle.
  * @param Size_  New desired size in bytes.
  *)
procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64); cdecl;

(*
  * LF_CreateApp: Creates a new application context with the given name
  * and description. The handle encapsulates a TLF_App object that can host
  * a set of APIs. It must be detached with LF_FreeApp.
  *
  * @param appName  Unique application identifier (UTF-8). Matching on the
  *                 wire is case-insensitive.
  * @param Desc     Human-readable description (UTF-8, can be empty –
  *                 empty is replaced by "No Description").
  * @return A new TAppHnd___ (never nil).
  *
  * [PITFALL] The app name is the routing key on the network. Two apps with
  *   the same name on the same service may cause ambiguous routing. Use
  *   LF_Generate_AppName to produce a collision-free name when needed.
  *)
function LF_CreateApp(appName, Desc: pansichar): TAppHnd___; cdecl;

(*
  * LF_FreeApp: Detaches an application from all clients and stops its
  * sequenced notification threads, but does NOT immediately destroy the
  * underlying TLF_App object.
  *
  * The object remains alive in the global LF_App_Pool until LF_Shutdown
  * is called, which then frees it forcibly.
  *
  * Why two-phase destruction?
  *   – Network broadcasts and per-(app,api) sequenced threads may still
  *     hold references while they drain their queues. Destroying the
  *     app immediately would cause dangling pointers on those threads.
  *   – LF_Shutdown is the single synchronisation point where it is safe
  *     to release everything.
  *
  * After calling LF_FreeApp, treat the handle as INVALID:
  *   – Do not register new APIs through it.
  *   – Do not call LF_BindApp on it.
  *   – Do not pass it to LF_LocalCall / LF_LocalNotify.
  *
  * @param appHnd  The application handle to detach (can be nil).
  *
  * [PITFALL] LF_FreeApp does NOT free the handle. Forgetting LF_Shutdown
  *   will leave the underlying app alive for the lifetime of the process.
  *)
procedure LF_FreeApp(appHnd: TAppHnd___); cdecl;

(*
  * LF_Generate_AppName: Generates a globally unique application name string.
  *
  * The name is built by concatenating:
  *   – All active C4 physics tunnel addresses and remote IDs,
  *   – The current process name (with PID),
  *   – A monotonically increasing counter (per call).
  *
  * This ensures that each call produces a distinct identifier, suitable for
  * point-to-point communication where each node must have a unique identity.
  *
  * ===========================================================================
  * [PITFALL – CRITICAL] RETURNED POINTER IS VALID FOR ONLY ~5 SECONDS
  * ===========================================================================
  *
  * The library automatically frees the underlying memory after 5 seconds
  * (via Z.Notify.DelayFreeMem). The caller MUST copy the content
  * immediately:
  *
  *   Pascal:
  *     var s: string;
  *     s := UTF8ToString(LF_Generate_AppName());   // copy now
  *
  *   C:
  *     char* uniqueName = LF_Generate_AppName();
  *     char* copy = strdup(uniqueName);            // MUST copy immediately
  *     // use copy...
  *     free(copy);
  *
  * Failure to copy will result in accessing freed memory.
  *
  * @return PAnsiChar pointing to a null-terminated UTF-8 string.
  *)
function LF_Generate_AppName(): pansichar; cdecl;

(*
  * LF_Get_AppName: Retrieves the application name associated with the
  * given application handle.
  *
  * ===========================================================================
  * [PITFALL – CRITICAL] RETURNED POINTER IS VALID FOR ONLY ~5 SECONDS
  * ===========================================================================
  *
  * Same contract as LF_Generate_AppName – copy immediately.
  *
  * @param appHnd The application handle (TLF_App) whose name is queried.
  * @return PAnsiChar pointing to the UTF-8 encoded name stored in the app.
  *)
function LF_Get_AppName(appHnd: TAppHnd___): pansichar; cdecl;

(*
  * LF_BindApp: Binds an application to all currently UNBOUND LingoFuse
  * clients. Each client can host at most one app.
  *
  * @param appHnd The application handle to bind.
  * @return The number of clients to which the application was successfully
  *         bound. A return value of 0 indicates that either:
  *             (a) the simulated main thread is not active, or
  *             (b) all existing clients already host an app.
  *
  * ===========================================================================
  * [PITFALL – ORDERING] MUST be called AFTER LF_PrepareDone has been
  *   invoked AND the simulated main thread is active. Calling it earlier
  *   logs an error and returns 0 without binding anything.
  * ===========================================================================
  *
  * ===========================================================================
  * [PITFALL – ONE APP PER CLIENT] A client hosting an app is skipped by
  *   subsequent LF_BindApp calls. To host multiple apps, either use the
  *   Overlap_Connection = True option when preparing clients, or bind
  *   different appHnd values to different clients.
  * ===========================================================================
  *
  * On success, the function logs the app name, description, connection
  * details, and every registered API (with mode Call / Notify).
  *)
function LF_BindApp(appHnd: TAppHnd___): Integer; cdecl;

(*
  * LF_RegisterCall: Registers a Call-mode API within the application.
  *
  * @param appHnd      The application handle.
  * @param MethodName  Unique API name (UTF-8, matching is case-insensitive).
  * @param Desc        Optional description (UTF-8).
  * @param Trigger     User data passed to the callback.
  * @param OnCall      cdecl function pointer implementing the API.
  * @return 1 if registration succeeded, 0 if the API name already exists.
  *
  * [PITFALL] OnCall MUST be declared cdecl. Using the default Pascal
  *   convention will corrupt the stack on C ABI invocation.
  *
  * [PITFALL] Registering the same MethodName twice is a no-op (returns 0).
  *   Unregister with LF_Unregister first if you need to replace it.
  *
  * [PITFALL] This triggers a network broadcast of the API list. It is
  *   coalesced by the service side with a ~2 second delay window.
  *
  * @Example (C):
  *   static void __cdecl MyCall(void* trigger, void* input, void* output) {
  *     // read input, write output
  *   }
  *   LF_RegisterCall(app, "echo", "Echo", NULL, MyCall);
  *)
function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer; cdecl;

(*
  * LF_RegisterNotify: Registers a Notify-mode API.
  *
  * Similar to LF_RegisterCall but for one-way notifications. The callback
  * receives only an input handle and produces no response.
  *
  * @return 1 on success, 0 if the name already exists.
  *
  * [PITFALL] OnNotify MUST be cdecl.
  *)
function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer; cdecl;

(*
  * LF_Unregister: Removes a previously registered API from the application.
  *
  * This function also triggers a network update broadcast. After calling
  * LF_Unregister, the change is propagated to all connected C4 services and
  * clients within approximately 2–3 seconds (the service side uses a
  * coalescing window).
  *
  * @param appHnd      The application handle.
  * @param MethodName  The name of the API to unregister (UTF-8).
  * @return 1 on success, 0 if the API name does not exist.
  *)
function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): Integer; cdecl;

(*
  * LF_LocalCall: Executes a Call-mode API locally within the application,
  * bypassing the network. Synchronous.
  *
  * @param appHnd  The application handle.
  * @param Param   Input data handle (created with LF_CreateData).
  * @return A new TDataHnd___ with the result (size 0 if not found / error).
  *
  * [PITFALL] The INPUT handle is NOT freed by this function. Caller must
  *   call LF_FreeData on it separately.
  * [PITFALL] The RETURN handle is NEW – caller owns it and must free it.
  *
  * @Example:
  *   TDataHnd___ d = LF_CreateData("echo");
  *   LF_WriteBuffer(d, "hello", 5);
  *   TDataHnd___ res = LF_LocalCall(app, d);
  *   LF_FreeData(d);
  *   // process res...
  *   LF_FreeData(res);
  *)
function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___; cdecl;

(*
  * LF_LocalNotify: Sends a notification locally within the application.
  * Synchronous, no result.
  *
  * [PITFALL] The input handle is NOT freed by this function. Caller must
  *   free it separately.
  *)
procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___); cdecl;

(*
  * LF_PrepareService: Prepares or immediately creates a C4 service.
  *
  * This function can be called at any time – before or after LF_PrepareDone.
  *   – Before LF_PrepareDone: the command is queued and started later.
  *   – After  LF_PrepareDone: the service is created and started immediately
  *     (dynamic addition).
  *
  * @param ListeningAddr_  Address to bind (UTF-8). Supported formats:
  *          - IPv4:   "0.0.0.0" or "127.0.0.1:9898"
  *          - IPv6:   "[::1]:8080" or "::1|8080"
  *          - Domain: "myhost.com:9090"
  *          - IPC:    "ipc:my_service" (port ignored)
  *        Default port is 9898 if omitted.
  * @param PhysicsAddr_    Public address advertised to clients (same format).
  * @return A tag (integer ID) identifying this service, or -1 on failure.
  *
  * [PITFALL] Duplicate detection only runs when the simulated main thread
  *   is ALREADY ACTIVE (`Init_Successed and Simulated_Main_Thread_Running`).
  *   If you call LF_PrepareService twice before LF_PrepareDone with the
  *   same listen address, you will get a "-1" only via the prepared-list
  *   check. If you call it after LF_PrepareDone with a duplicate listen
  *   address, you will get a "-1" via the runtime service-pool check.
  *   In both cases, the function does not start a new service.
  *
  * @Example:
  *   LF_ResetPrepare();
  *   LF_PrepareService("0.0.0.0", "127.0.0.1:9898");   // TCP
  *   LF_PrepareService("ipc:test", "ipc:test");        // IPC
  *   LF_PrepareClient("127.0.0.1:9898", app);
  *   LF_PrepareDone();
  *)
function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): Integer; cdecl;

(*
  * LF_PrepareClient: Prepares or immediately creates a C4 client.
  *
  * @param PhysicsAddr_  Address of the remote service to connect to (same
  *                      format as for LF_PrepareService).
  * @param appHnd        Optional TAppHnd___. If non-nil, the client exposes
  *                      this application; if nil, it acts as a consumer.
  * @return A tag for this client, or -1 if a duplicate address is detected
  *         (see below).
  *
  * ===========================================================================
  * [PITFALL – Overlap_Connection SEMANTICS]
  * ===========================================================================
  *
  * The behaviour regarding duplicate addresses is controlled by the global
  * Overlap_Connection option (see LF_SetOption):
  *
  *   – Overlap_Connection = False (default):
  *       * A single physical tunnel per remote address is reused.
  *       * Only the FIRST appHnd for a given address takes effect.
  *       * Subsequent calls with a different appHnd are SILENTLY IGNORED
  *         (the tag is stored but no new client is created, so the app
  *         never gets bound).
  *       * This mode is appropriate for single-app-per-address setups.
  *
  *   – Overlap_Connection = True:
  *       * A new physical tunnel is created for each call, even if the
  *         same address already has one.
  *       * Each call receives a unique tag and its appHnd is bound to a
  *         dedicated client.
  *       * This mode enables hosting multiple apps on the same service.
  *
  * ===========================================================================
  * [PITFALL – Wait_Connection_ReadyOk SEMANTICS]
  * ===========================================================================
  *
  * The Wait_Connection_ReadyOk / Wait_Connection_Timeout options only take
  * effect when LF_PrepareClient is called WHILE THE SIMULATED MAIN THREAD
  * IS ALREADY ACTIVE (i.e. after LF_PrepareDone has already returned 1).
  *
  * If you prepare clients BEFORE LF_PrepareDone, the wait is performed
  * inside the simulated main thread's startup sequence (see
  * Simulated_Main_Thread in Z.LingoFuse_Export.pas), which uses the same
  * Wait_Connection_Timeout value.
  *
  * ===========================================================================
  *
  * The client automatically reconnects if the connection is lost; on
  * reconnection, the application (if provided) is re-registered.
  *
  * @Example:
  *   LF_PrepareClient("127.0.0.1:9898", nil);   // consumer only
  *   LF_PrepareClient("ipc:test", app);        // provide APIs via app
  *)
function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): Integer; cdecl;

(*
  * LF_ResetPrepare: Clears all previously prepared services and clients.
  * Call this before preparing a new set to avoid conflicts.
  *
  * [PITFALL] This function does not affect already running services or
  *   clients – it only clears the preparation queue. Use LF_Shutdown to
  *   tear down running instances.
  *)
procedure LF_ResetPrepare(); cdecl;

(*
  * LF_PrepareDone: Starts the C4 framework with all prepared services and
  * clients. Blocks until the framework is initialised. Also launches the
  * simulated main thread that runs the C4 progress loop.
  *
  * @return 1 if successful, 0 on failure.
  *
  * [PITFALL] Do NOT call this twice without resetting first. If the
  *   simulated main thread is already running, this function returns 0
  *   immediately (no double-start).
  *
  * [PITFALL] If Wait_Connection_ReadyOk is True (default), this call
  *   blocks up to Wait_Connection_Timeout (default 30 seconds) waiting
  *   for all prepared clients to become online. Increase the timeout if
  *   your network is slow.
  *
  * [PITFALL] On failure, check the log via LF_GetStatus (but only after
  *   the simulated main thread is active).
  *)
function LF_PrepareDone: Integer; cdecl;

(*
  * LF_ExitMainThread: Signals the simulated main thread to exit gracefully.
  * After this call, the network loop stops, but resources are not freed.
  *
  * [PITFALL] You should still call LF_Shutdown for a full cleanup.
  * [PITFALL] Safe to call repeatedly.
  * [PITFALL] After exiting, you may call LF_PrepareDone again to restart
  *   the framework.
  *)
procedure LF_ExitMainThread; cdecl;

(*
  * LF_Call: Performs a synchronous remote (or local) call.
  * Blocks until the response is received or the timeout expires.
  *
  * @param appName   Target application name (UTF-8, case-insensitive).
  * @param Param     Input data handle. The function reads the buffer
  *                  synchronously and serialises it for transmission; it
  *                  does NOT take ownership of the handle.
  * @param Timeout_  Maximum wait in milliseconds. 0 means infinite.
  * @return A new TDataHnd___ with the result. If the call times out or
  *         fails, the handle has size 0 (but is still valid).
  *
  * [PITFALL] The INPUT handle is NOT freed by this function. Caller must
  *   free it separately with LF_FreeData.
  * [PITFALL] The RESULT handle is NEW – caller owns it and must free it.
  * [PITFALL] This call is synchronous and blocks the calling thread. Do
  *   NOT call it from inside a callback (deadlock).
  * [PITFALL] If no client is connected, the result is an empty handle.
  *   Use LF_CheckApp or LF_CheckMainThread to probe first.
  *
  * [NOTE] The function first tries to find a local instance of the target
  *   application to avoid a network round-trip.
  *)
function LF_Call(appName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl;

(*
  * LF_Notify: Sends a one-way notification.
  * Returns immediately after the notification has been queued.
  *
  * @param appName  Target application name (UTF-8, case-insensitive).
  * @param Param    Input data handle. Caller must free it separately with
  *                 LF_FreeData after this call returns.
  *
  * [PITFALL] Notifications are NOT ordered. If ordering matters, use
  *   LF_Sequenced_Notify instead.
  *)
procedure LF_Notify(appName: pansichar; Param: TDataHnd___); cdecl;

(*
  * LF_Sequenced_Notify: Sends a one-way notification with FIFO ordering
  * guarantee for the same (application, API) pair.
  *
  * The library maintains a dedicated thread per (app, api) key, which
  * processes notifications sequentially. Large payloads are chunked
  * internally. The call returns immediately after the data is queued.
  *
  * @param appName  Target application name (UTF-8, case-insensitive).
  * @param Param    Input data handle. Caller must free it separately with
  *                 LF_FreeData after this call returns.
  *
  * [PITFALL] The underlying per-key thread has a 5-minute idle timeout.
  *   Threads terminate when idle and are re-created on demand. This is
  *   transparent to callers.
  * [PITFALL] Notifications are ordered PER (app, api) pair. There is no
  *   cross-key ordering guarantee.
  *)
procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___); cdecl;

(*
  * LF_CheckMainThread: Returns 1 if the simulated main thread (which runs
  * the C4 progress loop) is currently active.
  *
  * [PITFALL] Before LF_PrepareDone and after LF_ExitMainThread this
  *   returns 0. Remote communication is unavailable in that state.
  *)
function LF_CheckMainThread(): Integer; cdecl;

(*
  * LF_CheckApp: Checks whether an application with the given name is
  * currently registered on the network (locally or remotely).
  *
  * @return 1 if at least one instance is available, 0 otherwise.
  *
  * [PITFALL] This is a point-in-time probe and does not guarantee that
  *   the application will still be online at the moment of a subsequent
  *   call.
  *)
function LF_CheckApp(appName: pansichar): Integer; cdecl;

(*
  * LF_CheckApi: Checks whether a specific API is available on the network
  * for the given application.
  *
  * @return 1 if available on at least one instance, 0 otherwise.
  *
  * [PITFALL] Based on cached information; may not reflect recent changes.
  *)
function LF_CheckApi(appName, apiName: pansichar): Integer; cdecl;

(*
  * LF_SetOption: Dynamically adjusts global runtime options.
  * All changes take effect immediately for subsequent operations.
  *
  * @param Option  Configuration key (UTF-8, case-insensitive).
  * @param Value   New value (UTF-8).
  *
  * Supported keys and aliases:
  *
  *   === Authentication ===
  *   - "password" / "passwd"
  *       Sets the C4 P2PVM authentication token.
  *
  *   === Logging & Debugging ===
  *   - "Quiet"
  *       Enable/disable quiet mode. Suppresses most internal log messages.
  *   - "ShowThreadID" / "ShowThread" / "Show_Thread"
  *       Show thread IDs in log output.
  *   - "ConsoleOutput" / "Console_Output"
  *       Enable or disable console logging.
  *
  *   === Connection Readiness ===
  *   - "Overlap_Connection" / "Overlap_Client" / "OverlapConnection" /
  *     "OverlapClient" / "OverlapConnect"
  *       Controls whether multiple independent C4 physics tunnels can be
  *       created to the same remote address. See LF_PrepareClient for a
  *       detailed semantics description.
  *
  *   - "Wait_Connection_ReadyOk" / "Wait_API_Prepare_Done" /
  *     "API_Prepare_Done_Wait" / "WaitConnect" / "Wait_Ready" / "WaitReady"
  *       If True, LF_PrepareDone blocks until all prepared clients are
  *       connected and their apps are online.
  *
  *   - "Wait_Connection_Timeout" / "Wait_TimeOut" /
  *     "API_Prepare_Done_TimeOut" / "WaitTimeOut"
  *       Timeout in milliseconds for the above wait.
  *
  *   === IPC (Inter-Process Communication) ===
  *   - "IPC_Serv_ThreadCount" / "IPC_ThreadCount" /
  *     "IPC_Server_ThreadCount"
  *       Number of threads in the IPC server thread pool.
  *   - "IPC_Serv_MaxQueueLength" / "IPC_MaxQueueLength" /
  *     "IPC_Server_MaxQueueLength"
  *       Maximum length of the IPC message queue.
  *   - "IPC_Serv_MaxMsgSize" / "IPC_MaxMsgSize" / "IPC_Server_MaxMsgSize"
  *       Maximum size (in bytes) of a single IPC message.
  *
  *   === Sequenced Notifications ===
  *   - "Fixed_Sequenced_Time" / "Fixed_Sequenced_Life"
  *       Idle timeout (in milliseconds) for the sequenced-notification
  *       client-selection fallback. When the candidate with the oldest
  *       timestamp is older than this value, the system falls back to the
  *       newest client to avoid starvation. Default is 20 seconds.
  *
  * [PITFALL] Unknown options are SILENTLY IGNORED.
  * [PITFALL] Changes are not persisted across restarts.
  *)
procedure LF_SetOption(Option, Value: pansichar); cdecl;

(*
  * LF_GetStatusCount: Returns the number of pending log messages in the
  * internal status buffer.
  *
  * [PITFALL] This only reflects messages that have been queued through the
  *   DoStatus hook. It does not reflect messages still in flight.
  *)
function LF_GetStatusCount(): Integer; cdecl;

(*
  * LF_GetStatus: Retrieves the next log message from the internal status
  * buffer (FIFO order). The returned pointer points to a static 64-KB
  * buffer that is valid only until the next call to this function.
  *
  * [PITFALL – BUFFER REUSE] The pointer is INVALIDATED by the next call
  *   to LF_GetStatus. Copy the string immediately if you need to retain
  *   it. Messages longer than 65,534 bytes are truncated.
  *
  * [PITFALL] This function relies on the simulated main thread to
  *   process the status queue. Before LF_PrepareDone, the buffer may be
  *   empty or contain stale data.
  *
  * @return PAnsiChar pointing to a null-terminated UTF-8 string, or an
  *         empty string if no message is available.
  *)
function LF_GetStatus(): pansichar; cdecl;

(*
  * LF_PostStatus: Injects a user-supplied log message into the internal
  * status buffer, as if it were generated by the library itself.
  *
  * @param status  Null-terminated UTF-8 string containing the message.
  *
  * [PITFALL] Before LF_PrepareDone, the message may be discarded or may
  *   not appear in the buffer at all.
  *)
procedure LF_PostStatus(status: pansichar); cdecl;

(*
  * LF_Shutdown: Gracefully terminates the entire LingoFuse framework.
  *
  * Steps:
  *   1. Clears the network event callbacks (On_Network_).
  *   2. Stops all sequenced notification threads.
  *   3. Frees all remaining data handles.
  *   4. Exits the simulated main thread.
  *   5. Clears the global LF_App_Pool (this is where TLF_App objects are
  *      finally destroyed – LF_FreeApp only detached them).
  *   6. Unloads the IPC library and closes the core dispatch thread.
  *
  * [PITFALL] Safe to call multiple times.
  * [PITFALL] Even if LF_FreeApp was never called for some apps, LF_Shutdown
  *   ensures they are properly destroyed, preventing leaks.
  * [PITFALL] After LF_Shutdown, the library is fully reset and can be
  *   re-initialised by calling LF_PrepareService / LF_PrepareClient again
  *   followed by LF_PrepareDone.
  *)
procedure LF_Shutdown; cdecl;

(*
  * TLF_Network_Event is defined above (see the type declaration for the
  * full contract). This block documents the two global handler slots and
  * the installer function.
  *
  * [PITFALL] Both handler slots are PROCESS-GLOBAL. Installing a handler
  *   affects every LingoFuse client in the current process. There is no
  *   per-client registration API.
  *
  * [PITFALL] The callbacks are stored as raw function pointers. In managed
  *   languages (C#, Java, Python via ctypes) you MUST keep a strong
  *   reference to the delegate / callback object to prevent it from being
  *   garbage-collected while the library may still invoke it.
  *
  * [PITFALL] LF_Shutdown automatically clears both callbacks before
  *   tearing down the framework. It is safe (but not required) to call
  *   LF_Set_Network_Event(nil, nil) explicitly before LF_Shutdown.
  *)
var
  (*
    * On_Network_Connect_Event
    * Invoked when a client transitions to the "online" state.
    * "Online" means: the first service-API-info broadcast has been
    * received from the server. This is NOT the same as the TCP handshake
    * completing.
    *
    * [PITFALL] Runs on a background TCompute worker thread.
    * [PITFALL] addr_ is valid only during the callback.
    * [PITFALL] Fires exactly once per connection lifecycle.
    *)
  On_Network_Connect_Event: TLF_Network_Event;

  (*
    * On_Network_Disconnect_Event
    * Invoked when a client loses its connection to the service.
    *
    * [PITFALL] Runs on a background TCompute worker thread.
    * [PITFALL] addr_ is valid only during the callback.
    *)
  On_Network_Disconnect_Event: TLF_Network_Event;

(*
  * LF_Set_Network_Event: Installs or clears the global network event
  * handlers.
  *
  * @param On_Connect_     Callback invoked when a client becomes online.
  *                        Pass nil to disable the connect notification.
  * @param On_Disconnect_  Callback invoked when a client goes offline.
  *                        Pass nil to disable the disconnect notification.
  *
  * [PITFALL] Both callbacks are GLOBAL. See the var block above for the
  *   full contract and pitfalls.
  *
  * @Example (Pascal):
  *   procedure OnConnect(addr: PAnsiChar); cdecl;
  *   var s: string;
  *   begin
  *     s := UTF8ToString(addr);   // copy inside the callback
  *     TThread.Queue(nil,
  *       procedure
  *       begin
  *         Memo1.Lines.Add('Connected: ' + s);
  *       end);
  *   end;
  *
  *   LF_Set_Network_Event(@OnConnect, nil);
  *
  * @Example (C):
  *   static void __cdecl OnConnect(const char* addr) {
  *       char* copy = strdup(addr);
  *       post_to_ui_thread(copy);
  *   }
  *   LF_Set_Network_Event(OnConnect, NULL);
  *)
procedure LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event); cdecl;

implementation

uses
  SysUtils,
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.status, Z.UnicodeMixedLib,
  Z.Parsing, Z.MemoryStream, Z.ListEngine, Z.TextDataEngine, Z.Int128, Z.Notify,
  Z.Expression,
  Z.Net, Z.Net.C4, Z.Net.C4_Console_APP,
  Z.LingoFuse_Core, Z.Net.C4.LingoFuse,
  Z.FP.Net.CrossSocket,
  Z.IPC.API, Z.Net.Server.IPC;

(*
  * LF_Set_Network_Event: installs the global connect / disconnect handlers.
  *
  * [PITFALL] This is a plain pointer assignment. The library does NOT own
  *   the callbacks. If the caller unloads its own module while a callback
  *   is still installed, subsequent invocations will jump into freed
  *   memory. Clear the handlers (pass nil) before unloading your module.
  *
  * [PITFALL] Callbacks are stored in the interface section's var block,
  *   so they are visible to the entire library. The trigger sites live in
  *   Z.Net.C4.LingoFuse (Do_LF_Network_Connect / Do_LF_Network_Disconnect),
  *   which schedule the actual invocation on a background TCompute worker
  *   thread. See the TLF_Network_Event contract for the full picture.
  *)
procedure LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event);
begin
  On_Network_Connect_Event := On_Connect_;
  On_Network_Disconnect_Event := On_Disconnect_;
end;

(*
  * Internal helper: DS – Decode UTF-8 string.
  *
  * Decodes a null-terminated UTF-8 string (PAnsiChar) into a TLF_String.
  * Used throughout the unit to convert external UTF-8 inputs to internal
  * Unicode strings.
  *
  * @Param P: Pointer to a null-terminated UTF-8 string.
  * @Returns: TLF_String (Unicode Pascal string).
  * @Note: The caller must ensure P is valid and null-terminated.
  *)
function DS(p: Pointer): TLF_String; inline;
begin
  Result.ReadUTF8AnsiChar(p);
end;

(*
  * LF_CreateData
  *
  * Creates a new data handle with the given API name.
  * Reads the UTF-8 name, creates a TLF_Data record with a
  * TMemory_Param_Tool, and returns the handle.
  *
  * [PITFALL] The returned handle is tracked by an idle pool with a
  *   5-minute idle timeout. Refresh the handle periodically if you need
  *   it to survive longer.
  *)
function LF_CreateData(MethodName: pansichar): TDataHnd___;
var
  s: TLF_String;
begin
  s := DS(MethodName);
  Result := TLF_Data.New_Param(s);
end;

(*
  * LF_FreeData
  *
  * Frees the TLF_Data record pointed to by Hnd.
  *
  * [PITFALL] Only actually frees the handle when the simulated main
  *   thread is active. Before LF_PrepareDone or after LF_ExitMainThread,
  *   the call is a no-op (see the interface documentation for details).
  *)
procedure LF_FreeData(Hnd: TDataHnd___);
begin
  if Simulator_Main_Thread_Activted and (Hnd <> nil) then
      TLF_Data.Free_Data(Hnd);
end;

(*
  * LF_GetBuffer
  *
  * Returns the raw data pointer from the TLF_Data record.
  *
  * [PITFALL] Updates the handle's last-access timestamp. This refreshes
  *   the 5-minute idle countdown.
  * [PITFALL] The pointer is valid only until the handle is freed or
  *   resized. Do not free the returned pointer.
  *)
function LF_GetBuffer(Hnd: TDataHnd___): Pointer;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.GetBuffer
  else
      Result := nil;
end;

(*
  * LF_WriteBuffer
  *
  * Delegates to TLF_Data.WriteBuff.
  * Buffer is automatically enlarged if needed.
  * Updates the handle's last-access timestamp.
  *)
function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.WriteBuff(Buff, Size)
  else
      Result := 0;
end;

(*
  * LF_ReadBuffer
  *
  * Delegates to TLF_Data.ReadBuff.
  * Returns the number of bytes actually read (may be less than Size on EOF).
  * Updates the handle's last-access timestamp.
  *)
function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.ReadBuff(Buff, Size)
  else
      Result := 0;
end;

(*
  * LF_GetPos
  *
  * Delegates to TLF_Data.Get_Pos. Updates the handle's last-access timestamp.
  *)
function LF_GetPos(Hnd: TDataHnd___): int64;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.Get_Pos
  else
      Result := 0;
end;

(*
  * LF_SetPos
  *
  * Delegates to TLF_Data.Set_Pos.
  *
  * [PITFALL] If Pos_ exceeds the current size, the buffer is extended
  *   with zero bytes. This can silently allocate a large buffer if Pos_
  *   is set to a huge value.
  *)
procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64);
begin
  if Hnd <> nil then
      PLF_Data(Hnd)^.Set_Pos(Pos_);
end;

(*
  * LF_GetSize
  *
  * Delegates to TLF_Data.Get_Size. Updates the handle's last-access timestamp.
  *)
function LF_GetSize(Hnd: TDataHnd___): int64;
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.Get_Size
  else
      Result := 0;
end;

(*
  * LF_SetSize
  *
  * Delegates to TLF_Data.Set_Size.
  *
  * [PITFALL] If larger, the added space is UNINITIALISED. Do not read
  *   from a freshly enlarged buffer without first writing to it.
  *)
procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64);
begin
  if Hnd <> nil then
      PLF_Data(Hnd)^.Set_Size(Size_);
end;

(*
  * LF_CreateApp
  *
  * Creates a TLF_App object, sets its name and description, and returns
  * the handle.
  *
  * [PITFALL] An empty Desc is replaced by "No Description".
  *)
function LF_CreateApp(appName, Desc: pansichar): TAppHnd___;
var
  app: TLF_App;
begin
  app := TLF_App.Create;
  app.Name := DS(appName);
  app.Desc := DS(Desc);
  if app.Desc = '' then
      app.Desc := 'No Description';
  Result := app;
end;

(*
  * LF_FreeApp
  *
  * Detaches the app from all clients and stops sequenced notification
  * threads. The TLF_App object itself is NOT destroyed here – it stays
  * alive in LF_App_Pool until LF_Shutdown.
  *
  * [PITFALL] See the interface documentation for the full two-phase
  *   destruction rationale and post-call restrictions.
  *)
procedure LF_FreeApp(appHnd: TAppHnd___);
var
  app: TLF_App;
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
begin
  if not Core_Dispatch_Order_Activted then exit; // shutdown guard
  app := appHnd;
  arry := C40_ClientPool.FastSearchClass(TC40_LF_Client);
  for i := 0 to length(arry) - 1 do
    begin
      Cli := arry[i] as TC40_LF_Client;
      if Cli.app = app then
          Cli.app := nil; // detach client from app
    end;
  LF_Notify_Sequence_Thread_Pool.Kill_App(app); // stop per-(app,api) threads
  app.FakeFree;                                 // remove timer only
end;

(*
  * LF_Generate_AppName
  *
  * Builds a globally unique app name from active C4 tunnel info, the
  * process name + PID, and an atomic counter.
  *
  * [PITFALL – CRITICAL] The returned UTF-8 pointer is auto-freed after
  *   ~5 seconds (Z.Notify.DelayFreeMem(5.0, Result)). The caller MUST
  *   copy the content immediately.
  *)
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
  Z.Notify.DelayFreeMem(5.0, Result); // auto-free after 5 seconds
  tmp := '';
end;

(*
  * LF_Get_AppName
  *
  * Returns the app's Name field as UTF-8 PAnsiChar.
  *
  * [PITFALL – CRITICAL] Same 5-second auto-free contract as
  *   LF_Generate_AppName. Copy immediately.
  *)
function LF_Get_AppName(appHnd: TAppHnd___): pansichar;
var
  app: TLF_App;
begin
  app := appHnd;
  Result := app.Name.BuildUTF8AnsiChar();
  Z.Notify.DelayFreeMem(5.0, Result); // auto-free after 5 seconds
end;

(*
  * LF_BindApp
  *
  * Binds an app to all currently unbound LingoFuse clients.
  *
  * [PITFALL] Requires Simulator_Main_Thread_Activted. If the main
  *   thread is not active, logs an error and returns 0.
  * [PITFALL] Each client can host only one app. Clients already hosting
  *   an app are skipped.
  *)
function LF_BindApp(appHnd: TAppHnd___): Integer;
var
  app: TLF_App;
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
  tmp: TLF_String;
begin
  Result := 0;
  app := appHnd;
  if not Simulator_Main_Thread_Activted then
    begin
      DoStatus('LF_BindApp: Main thread is not active – cannot bind app.');
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
      DoStatus('LF_BindApp: All clients are already occupied – cannot bind app "%s".', [app.Name.Text]);
end;

(*
  * LF_RegisterCall
  *
  * Registers a Call-mode API.
  *
  * [PITFALL] OnCall MUST be cdecl.
  * [PITFALL] Duplicate API names cause the function to return 0 without
  *   changing anything.
  * [PITFALL] Triggers a network broadcast (coalesced with ~2s window).
  *)
function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer;
var
  app: TLF_App;
  MethodName__, Desc__: TLF_String;
begin
  app := appHnd;
  MethodName__ := DS(MethodName);
  Desc__ := DS(Desc);
  Result := if_(app.Engine.Reg_Call(MethodName__, Desc__, Trigger, OnCall), 1, 0);
end;

(*
  * LF_RegisterNotify
  *
  * Registers a Notify-mode API.
  *
  * [PITFALL] OnNotify MUST be cdecl.
  *)
function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer;
var
  app: TLF_App;
  MethodName__, Desc__: TLF_String;
begin
  app := appHnd;
  MethodName__ := DS(MethodName);
  Desc__ := DS(Desc);
  Result := if_(app.Engine.Reg_Notify(MethodName__, Desc__, Trigger, OnNotify), 1, 0);
end;

(*
  * LF_Unregister
  *
  * Removes a previously registered API and broadcasts the change.
  *
  * [PITFALL] The broadcast is coalesced by the service side (2-second
  *   window). There is no synchronous "removal confirmed" guarantee.
  *)
function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): Integer;
var
  app: TLF_App;
  MethodName__: TLF_String;
begin
  app := appHnd;
  MethodName__ := DS(MethodName);
  Result := if_(app.Engine.UnReg(MethodName__), 1, 0);
end;

(*
  * LF_LocalCall
  *
  * Executes a Call-mode API synchronously, bypassing the network.
  *
  * [PITFALL] Input handle is NOT freed here.
  * [PITFALL] The returned handle is NEW and must be freed by the caller.
  *)
function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___;
var
  app: TLF_App;
  tmp: TMem64;
begin
  app := appHnd;
  tmp := TMem64.Create;
  PLF_Data(Param).Data_Param.EncryptToMem(tmp);
  Result := TLF_Data.New_Result_From(app.Engine.Execute_Call(tmp));
  PLF_Data(Result)^.Data_Info := PFormat('result for app:%s api:%s', [app.Name.Text, PLF_Data(Param)^.Data_Param.MethodName.Text]);
  DisposeObject(tmp);
end;

(*
  * LF_LocalNotify
  *
  * Sends a notification locally. Synchronous, no result.
  *
  * [PITFALL] Input handle is NOT freed here.
  *)
procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___);
var
  app: TLF_App;
  tmp: TMem64;
begin
  app := appHnd;
  tmp := TMem64.Create;
  PLF_Data(Param).Data_Param.EncryptToMem(tmp);
  app.Engine.Execute_Notify(tmp);
  DisposeObject(tmp);
end;

(*
  * TAppHnd_Bind_Tag / TAppHnd_Bind_Tag_List
  *
  * Internal bookkeeping used to match prepared services and clients with
  * their application handles. Tags are generated by AtomInc(Tag_Seed).
  *
  * Not exported; not part of the public API.
  *)
type
  TAppHnd_Bind_Tag = record
    appHnd: TAppHnd___;
    Tag: Integer;
    IsService, IsClient: boolean;
    Listen, Addr, Port: TLF_String;
    procedure Init;
  end;

  TAppHnd_Bind_Tag_List = class(TBigList<TAppHnd_Bind_Tag>)
  public
    procedure DoFree(var Data: TAppHnd_Bind_Tag); override;
    function CompareData(const Data_1, Data_2: TAppHnd_Bind_Tag): boolean; override;
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

function TAppHnd_Bind_Tag_List.CompareData(const Data_1, Data_2: TAppHnd_Bind_Tag): boolean;
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

(*
  * LF_ResetPrepare
  *
  * Clears the preparation queue and tag mapping.
  *
  * [PITFALL] Does NOT affect already running services/clients. Use
  *   LF_Shutdown to tear down running instances.
  *)
procedure LF_ResetPrepare();
begin
  Prepare_Commands.Clear;
  AppHnd_Bind_Tag_List.Clear;
end;

(*
  * TTemp_C40_PhysicsService_Bridge__
  *
  * Logging bridge for C4 service lifecycle events. Prints human-readable
  * messages on service start/stop and link success/failure. No behaviour
  * beyond logging.
  *)
type
  TTemp_C40_PhysicsService_Bridge__ = class(TCore_InterfacedObject_Intermediate, IC40_PhysicsService_Event)
  public
    procedure C40_PhysicsService_Build_Network(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service);
    procedure C40_PhysicsService_Start(Sender: TC40_PhysicsService);
    procedure C40_PhysicsService_Stop(Sender: TC40_PhysicsService);
    procedure C40_PhysicsService_LinkSuccess(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
    procedure C40_PhysicsService_UserOut(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
  end;

procedure TTemp_C40_PhysicsService_Bridge__.C40_PhysicsService_Build_Network(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service);
begin
  { Nothing to do – the network is already built. }
end;

procedure TTemp_C40_PhysicsService_Bridge__.C40_PhysicsService_Start(Sender: TC40_PhysicsService);
begin
  if Sender.IPC_Mode then
      DoStatus('LingoFuse Service Listening: "%s" OK, Host: "%s"', [Sender.ListeningAddr.Text, Sender.PhysicsAddr.Text])
  else
      DoStatus('LingoFuse Service Listening: "%s" OK, Host: "%s"', [Build_Host_URL(Sender.ListeningAddr, Sender.PhysicsPort), Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
end;

procedure TTemp_C40_PhysicsService_Bridge__.C40_PhysicsService_Stop(Sender: TC40_PhysicsService);
begin
  DoStatus('LingoFuse Service Listening: "%s" Stop', [Build_Host_URL(Sender.ListeningAddr, Sender.PhysicsPort)]);
end;

procedure TTemp_C40_PhysicsService_Bridge__.C40_PhysicsService_LinkSuccess(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
var
  serv: TC40_LF_Service;
  user_io: TC40_LF_RecvTunnel;
begin
  serv := Custom_Service_ as TC40_LF_Service;
  user_io := Trigger_ as TC40_LF_RecvTunnel;
  DoStatus('LingoFuse Service Link Successed IO "%s"', [user_io.Owner.GetPeerIP]);
end;

procedure TTemp_C40_PhysicsService_Bridge__.C40_PhysicsService_UserOut(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
var
  serv: TC40_LF_Service;
  user_io: TC40_LF_RecvTunnel;
begin
  serv := Custom_Service_ as TC40_LF_Service;
  user_io := Trigger_ as TC40_LF_RecvTunnel;
  DoStatus('LingoFuse Service User-out IO "%s"', [user_io.Owner.GetPeerIP]);
end;

(*
  * TTemp_C40_PhysicsTunnel_Bridge__
  *
  * Logging bridge and app-binding bridge for C4 client tunnel lifecycle.
  *
  * [PITFALL] C40_PhysicsTunnel_Client_Connected performs the tag → app
  *   binding. If the tag is not found in AppHnd_Bind_Tag_List, the client
  *   will not host an app. This is a common source of "app not visible on
  *   the network" reports. Check that LF_PrepareClient was called with a
  *   non-nil appHnd and that the tag matches.
  *)
type
  TTemp_C40_PhysicsTunnel_Bridge__ = class(TCore_InterfacedObject_Intermediate, IC40_PhysicsTunnel_Event)
  public
    constructor Create;
    procedure C40_PhysicsTunnel_Connected(Sender: TC40_PhysicsTunnel);
    procedure C40_PhysicsTunnel_Disconnect(Sender: TC40_PhysicsTunnel);
    procedure C40_PhysicsTunnel_Build_Network(Sender: TC40_PhysicsTunnel; Custom_Client_: TC40_Custom_Client);
    procedure C40_PhysicsTunnel_Client_Connected(Sender: TC40_PhysicsTunnel; Custom_Client_: TC40_Custom_Client);
  end;

constructor TTemp_C40_PhysicsTunnel_Bridge__.Create;
begin
  inherited Create;
end;

procedure TTemp_C40_PhysicsTunnel_Bridge__.C40_PhysicsTunnel_Connected(Sender: TC40_PhysicsTunnel);
begin
  DoStatus('Connection %s Successed', [Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
end;

procedure TTemp_C40_PhysicsTunnel_Bridge__.C40_PhysicsTunnel_Disconnect(Sender: TC40_PhysicsTunnel);
begin
  DoStatus('%s Disconnected', [Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
end;

procedure TTemp_C40_PhysicsTunnel_Bridge__.C40_PhysicsTunnel_Build_Network(Sender: TC40_PhysicsTunnel; Custom_Client_: TC40_Custom_Client);
begin
  if Sender.IPC_Mode then
      DoStatus('Ready Network: "%s"', [Sender.PhysicsAddr.Text])
  else
      DoStatus('Ready Network: "%s"', [Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
end;

procedure TTemp_C40_PhysicsTunnel_Bridge__.C40_PhysicsTunnel_Client_Connected(Sender: TC40_PhysicsTunnel; Custom_Client_: TC40_Custom_Client);
var
  Cli: TC40_LF_Client;
  tmp: TLF_String;
begin
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

(*
  * Global state for the simulated main thread.
  *
  * Overlap_Connection defaults to False – see LF_PrepareClient for the
  * full semantics. Wait_Connection_ReadyOk defaults to True with a
  * 30-second timeout.
  *)
var
  Init_Running, Init_Successed, Simulated_Main_Thread_Running: boolean;
  Temp_C40_PhysicsTunnel_Bridge__: TTemp_C40_PhysicsTunnel_Bridge__;
  Temp_C40_PhysicsService_Bridge__: TTemp_C40_PhysicsService_Bridge__;
  Overlap_Connection: boolean;
  Wait_Connection_ReadyOk: boolean;
  Wait_Connection_Timeout: TTimeTick;

(*
  * Do_Post_RUn_C40_Extract_CmdLine
  *
  * Helper that executes C40_Extract_CmdLine on the main thread.
  * Used when a service/client is prepared after the main thread is
  * already running.
  *)
procedure Do_Post_RUn_C40_Extract_CmdLine;
begin
  C40_Extract_CmdLine();
end;

(*
  * LF_PrepareService
  *
  * Builds a C4 'Service' command, tags it, and either queues it or
  * executes it immediately (see interface documentation).
  *
  * [PITFALL] Duplicate detection has two paths:
  *   (a) runtime service-pool check (main thread already running);
  *   (b) prepared-list check (before main thread starts).
  * Both return -1 on duplicate. See the interface documentation for the
  * exact timing.
  *)
function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): Integer;
var
  Listen, Host, Port: U_String;
  Cmd_: U_String;
  running: boolean;
begin
  Listen := DS(ListeningAddr_).Text;
  Host := DS(PhysicsAddr_).Text;
  if Is_IPC_Addr(Host.Text) or Is_IPC_Addr(Listen.Text) then
      Port := '0'
  else
    begin
      Port := '9898';
      ExtractHostAddress(Host, Port);
      ExtractHostAddress(Listen, Port);
    end;

  if Init_Successed and Simulated_Main_Thread_Running then
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

  if Init_Successed and Simulated_Main_Thread_Running then
    begin
      SetLength(C40AppParam, 1);
      C40AppParam[0] := Cmd_;
      C40AppParsingTextStyle := TTextStyle.tsC;
      DoStatus('Run %s', [Cmd_.Text]);
      if TCompute.CurrentThread = Z.Core.Main_Thread then
        begin
          Do_Post_RUn_C40_Extract_CmdLine();
        end
      else
        begin
          Z.Core.MainThreadProgress.PostC1(Do_Post_RUn_C40_Extract_CmdLine, @running, nil);
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

(*
  * LF_PrepareClient
  *
  * Builds a C4 'KeepAlive' (or 'NewKeepAlive' when Overlap_Connection is
  * True) command, tags it, and either queues it or executes it immediately.
  *
  * [PITFALL] When Overlap_Connection = False, the second and later calls
  *   with a different appHnd on the same remote address are SILENTLY
  *   IGNORED. See the interface documentation for the full table.
  *
  * [PITFALL] Wait_Connection_ReadyOk / Wait_Connection_Timeout only have
  *   an effect on the "immediate execution" path (main thread already
  *   running). See the interface documentation.
  *)
function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): Integer;
var
  Host, Port: U_String;
  Cmd_: TLF_String;
  full_url: TLF_String;
  running: boolean;
  Cli: TC40_LF_Client;
  tk: TTimeTick;
begin
  Host := DS(PhysicsAddr_).Text;
  if Is_IPC_Addr(Host.Text) then
      Port := '0'
  else
    begin
      Port := '9898';
      ExtractHostAddress(Host, Port);
    end;

  if (not Overlap_Connection) and Init_Successed and Simulated_Main_Thread_Running then
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

  if Init_Successed and Simulated_Main_Thread_Running then
    begin
      SetLength(C40AppParam, 1);
      C40AppParam[0] := Cmd_;
      C40AppParsingTextStyle := TTextStyle.tsC;
      DoStatus('Run %s', [Cmd_.Text]);
      if TCompute.CurrentThread = Z.Core.Main_Thread then
        begin
          Do_Post_RUn_C40_Extract_CmdLine();
        end
      else
        begin
          Z.Core.MainThreadProgress.PostC1(Do_Post_RUn_C40_Extract_CmdLine, @running, nil);
          while running do
              TCompute.Sleep(10);

          Cli := C40_ClientPool.FindTag(Result) as TC40_LF_Client;
          if Cli <> nil then
            if Wait_Connection_ReadyOk then
              begin
                tk := GetTimeTick + Wait_Connection_Timeout;
                while (GetTimeTick() < tk) and Simulated_Main_Thread_Running do
                  begin
                    if (Cli.Connected) and ((Cli.app = nil) or Cli.LF_AppIsOnline) and (Cli.LF_Service_Info_Is_Onlne) then
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

(*
  * Simulated_Main_Thread
  *
  * Entry point for the simulated main thread that drives the C4 progress
  * loop.
  *
  * [PITFALL] This is the thread that ultimately invokes the network event
  *   callbacks via TCompute.RunC. Do not call blocking LingoFuse
  *   functions from inside Simulated_Main_Thread – it would freeze the
  *   whole framework.
  *)
procedure Simulated_Main_Thread();
var
  i: Integer;
  tk: TTimeTick;
  Cli: TC40_LF_Client;
  Prepare_Cli_Num, Online_Num: Integer;
begin
  DoStatus('LingoFuse-v%s Main Thread Begin, C4-v%s,Net-v%s,%s,IPC-v%s',
    [C_LingoFuse_Edition, C_C4_Edition, C_ZNet_Edition, C_Cross_Edition, C_Z_IPC_Edition]);

  SetLength(C40AppParam, Prepare_Commands.Count);
  for i := 0 to Prepare_Commands.Count - 1 do
      C40AppParam[i] := Prepare_Commands[i];

  if Prepare_Commands.Count > 0 then
    begin
      C40AppParsingTextStyle := TTextStyle.tsC;
      On_C40_PhysicsTunnel_Event_Console := Temp_C40_PhysicsTunnel_Bridge__;

      Init_Successed := C40_Extract_CmdLine();

      if Init_Successed and Wait_Connection_ReadyOk then
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
              tk := GetTimeTick + Wait_Connection_Timeout;
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
                            if (Cli <> nil) and (Cli.Connected) and ((Cli.app = nil) or Cli.LF_AppIsOnline) and (Cli.LF_Service_Info_Is_Onlne) then
                                inc(Online_Num);
                          end;
                      until not Next;
                  end;
                Init_Successed := Online_Num >= Prepare_Cli_Num;
              until Init_Successed or (not Simulated_Main_Thread_Running) or ((Wait_Connection_Timeout > 0) and (GetTimeTick() > tk));
            end;
        end;
    end
  else
    begin
      Init_Successed := True;
    end;

  Init_Running := False;

  if Init_Successed then
    while Simulated_Main_Thread_Running do
      begin
        C40Progress(if_(LF_RunningCount.V > 0, 0, 10));
        try
            LF_DataPool.Progress();
        except
        end;
      end;

  try
    DoStatus('Clean Framework.');
    C40Clean();
    LF_Notify_Sequence_Thread_Pool.Stop;
  except
  end;

  try
      LF_DataPool.Free_All_Hnd();
  except
  end;
  DoStatus('LingoFuse Main Thread Exit');
end;

(*
  * LF_PrepareDone
  *
  * Starts the simulated main thread and waits for initialisation to
  * complete. Returns 1 on success, 0 on failure.
  *
  * [PITFALL] If the simulated main thread is already running, returns 0
  *   immediately (no double-start). Call LF_Shutdown before re-preparing.
  *)
function LF_PrepareDone: Integer;
var
  tk: TTimeTick;
begin
  Result := 0;
  if Simulated_Main_Thread_Running then
      exit;

  Open_Core_Dispatch_Thread();
  Init_Running := True;
  Init_Successed := False;
  Simulated_Main_Thread_Running := True;

  Begin_Simulator_Main_Thread(Simulated_Main_Thread);
  tk := GetTimeTick() + C_Tick_Second * 30;
  while Init_Running do
    begin
      Boot_Thread_Sync_Tool.Check_Synchronize(10);
      if GetTimeTick() > tk then break;
    end;
  Result := if_(Init_Successed, 1, 0);
end;

(*
  * LF_ExitMainThread
  *
  * Signals the main loop to stop and waits for the simulator thread to
  * finish.
  *)
procedure LF_ExitMainThread;
begin
  Simulated_Main_Thread_Running := False;
  while Simulator_Main_Thread_Activted do
      Boot_Thread_Sync_Tool.Check_Synchronize(10);
end;

var
  Find_Class_Critical: TCritical = nil;

(*
  * LF_Call
  *
  * Synchronous remote call. Finds a connected LingoFuse client, packs the
  * input, and calls Wait_Execute_Call.
  *
  * [PITFALL] Input handle is NOT freed here – caller must free it.
  * [PITFALL] Result is a NEW handle – caller owns it.
  * [PITFALL] Blocking call. Do not call from a callback (deadlock).
  *)
function LF_Call(appName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
var
  Cli: TC40_LF_Client;
  tmp, Output: TMem64;
begin
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
      PLF_Data(Param).Data_Param.EncryptToMem(tmp);
      try
          Output := Cli.Wait_Execute_Call(DS(appName), tmp, Timeout_);
      except
          DoStatus('LF_Call(%s, ...) except', [DS(appName).Text]);
      end;
      DisposeObject(tmp);
    end
  else
    begin
      DoStatus('"%s" no connection', [DS(appName).Text]);
    end;
  if Output = nil then
      Output := TMem64.Create;
  Result := TLF_Data.New_Result_From(Output);
  PLF_Data(Result)^.Data_Info := PFormat('result for app:%s api:%s', [DS(appName).Text, PLF_Data(Param)^.Data_Param.MethodName.Text]);
end;

(*
  * LF_Notify
  *
  * Non-sequenced notification. Returns immediately.
  *
  * [PITFALL] Not ordered. Use LF_Sequenced_Notify for FIFO per (app, api).
  * [PITFALL] Input handle is NOT freed here – caller must free it.
  *)
procedure LF_Notify(appName: pansichar; Param: TDataHnd___);
var
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
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
  PLF_Data(Param).Data_Param.EncryptToMem(tmp);
  try
      Cli.Send_Execute_Notify(DS(appName), tmp);
  except
      DoStatus('LF_Notify(%s, ...) except', [DS(appName).Text]);
  end;
  DisposeObject(tmp);
end;

(*
  * LF_Sequenced_Notify
  *
  * Sequenced notification. FIFO per (app, api) pair.
  *
  * [PITFALL] Input handle is NOT freed here – caller must free it.
  * [PITFALL] Per-(app, api) threads idle out after 5 minutes.
  *)
procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___);
var
  Cli: TC40_LF_Client;
  tmp: TMem64;
begin
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
  PLF_Data(Param).Data_Param.EncryptToMem(tmp);
  try
      Cli.Send_Sequenced_Notify(DS(appName), tmp);
  except
      DoStatus('LF_Sequenced_Notify(%s, ...) except', [DS(appName).Text]);
  end;
  DisposeObject(tmp);
end;

(*
  * LF_CheckMainThread
  *
  * Returns 1 if the simulated main thread is active.
  *)
function LF_CheckMainThread(): Integer;
begin
  Result := if_(Simulator_Main_Thread_Activted, 1, 0);
end;

(*
  * LF_CheckApp
  *
  * Probes whether an app is registered locally or remotely.
  *
  * [PITFALL] Point-in-time probe; not a guarantee.
  *)
function LF_CheckApp(appName: pansichar): Integer;
begin
  Result := if_((Find_Local_APP(DS(appName), False) <> nil) or (Find_Remote_APP(DS(appName), False) <> nil), 1, 0);
end;

(*
  * LF_CheckApi
  *
  * Probes whether an API is exported by any instance of the app.
  *)
function LF_CheckApi(appName, apiName: pansichar): Integer;
begin
  Result := if_((Find_Local_Api(DS(appName), DS(apiName), False) <> nil) or
      (Find_Remote_Api(DS(appName), DS(apiName), False) <> nil), 1, 0);
end;

(*
  * LF_SetOption
  *
  * Applies a runtime option. See the interface documentation for the full
  * list of keys and their semantics.
  *
  * [PITFALL] Unknown keys are silently ignored. There is no error return.
  *)
procedure LF_SetOption(Option, Value: pansichar);
var
  opt, V, tmp: TLF_String;
  L: Integer;
  i: Integer;
begin
  opt := DS(Option);
  V := DS(Value);

  if opt.Same('password', 'passwd') then
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
    end;
end;

(*
  * TStatus_Buffer / backcall_DoStatus / LF_GetStatusCount / LF_GetStatus /
  * LF_PostStatus
  *
  * Internal status queue used to expose library logs to host applications.
  *
  * ===========================================================================
  * DESIGN
  * ===========================================================================
  *
  * – Library logs are forwarded here via a DoStatus hook installed in the
  *   initialization section (backcall_DoStatus).
  * – Messages are stored as UTF-8 byte arrays in a FIFO queue
  *   (TStatus_Buffer, a TOrderStruct<TBytes>).
  * – Host applications poll LF_GetStatus() to pop messages one at a time.
  *
  * ===========================================================================
  * [PITFALL] MAIN-THREAD DEPENDENCY
  * ===========================================================================
  *
  * The queue itself is populated from any thread (via DoStatus), but
  * LF_GetStatus / LF_PostStatus are only meaningful once the simulated
  * main thread is running (after LF_PrepareDone). Before that, the buffer
  * may be empty or contain stale data. See the interface documentation.
  *
  * ===========================================================================
  * [PITFALL] QUEUE LENGTH CAPPED AT 1000
  * ===========================================================================
  *
  * backcall_DoStatus discards the OLDEST message when the queue exceeds
  * 1000 entries. If your host application does not poll often enough, you
  * will silently lose messages. Poll frequently or accept the loss.
  *
  * ===========================================================================
  * [PITFALL] LF_GetStatus RETURNS A STATIC BUFFER
  * ===========================================================================
  *
  * The returned PAnsiChar points into a static 64-KB buffer that is
  * OVERWRITTEN on the next call. Copy the string immediately if you need
  * to retain it. Messages longer than 65,534 bytes are truncated.
  *)
type
  (*
    * TStatus_Buffer: FIFO queue of UTF-8 log message bytes.
    * DoFree clears the byte array to release memory when an entry is
    * popped from the queue.
    *)
  TStatus_Buffer = class(TOrderStruct<TBytes>)
  public
    procedure DoFree(var Data: TBytes); override;
  end;

var
  Status_Pool: TStatus_Buffer = nil;          // FIFO queue of pending log messages
  Status_Critical__: TCritical = nil;          // Mutex protecting the queue
  Status_Buff: array [0 .. $FFFF] of byte;     // Static 64-KB return buffer

(*
  * TStatus_Buffer.DoFree
  *
  * Clears the byte array when a queue item is popped. There is no
  * explicit FreeMemory here – the TB dynamic array is managed by the
  * RTL. SetLength(..., 0) is enough.
  *)
procedure TStatus_Buffer.DoFree(var Data: TBytes);
begin
  SetLength(Data, 0);
  inherited DoFree(Data);
end;

(*
  * backcall_DoStatus
  *
  * Hook installed into the global DoStatus system. Captures every
  * library log line and stores it as UTF-8 bytes in the status queue.
  *
  * [PITFALL] The queue is capped at 1000 entries. Beyond that, the
  *   OLDEST message is dropped, not the newest.
  *
  * [PITFALL] This is called from arbitrary threads (including internal
  *   worker threads). All access to Status_Pool is serialised through
  *   Status_Critical__.
  *
  * @Param Text_: The log message as a SystemString.
  * @Param ID:    Unused here, but required by the hook signature.
  *)
procedure backcall_DoStatus(Text_: SystemString; const ID: Integer);
begin
  Status_Critical__.Lock;
  try
    while Status_Pool.Num > 1000 do
        Status_Pool.Next;
    Status_Pool.Push(TPascalString(Text_).UTF8);
  finally
      Status_Critical__.UnLock;
  end;
end;

(*
  * LF_GetStatusCount
  *
  * Returns the number of pending log messages in the queue.
  *
  * [PITFALL] This counts messages that are already queued, not messages
  *   still in flight through the DoStatus pipeline.
  *)
function LF_GetStatusCount(): Integer;
begin
  Status_Critical__.Lock;
  try
      Result := Status_Pool.Num;
  finally
      Status_Critical__.UnLock;
  end;
end;

(*
  * LF_GetStatus
  *
  * Pops the oldest message from the queue and copies it into the static
  * 64-KB Status_Buff, null-terminated.
  *
  * [PITFALL] RETURNED BUFFER IS REUSED. The PAnsiChar is invalidated by
  *   the next call to LF_GetStatus. Copy the string immediately.
  * [PITFALL] MESSAGES ARE TRUNCATED at 65,534 bytes.
  * [PITFALL] Requires the simulated main thread for meaningful output.
  *
  * @Returns PAnsiChar pointing to a null-terminated UTF-8 string, or an
  *          empty string if no message is available.
  *)
function LF_GetStatus(): pansichar;
var
  L: Integer;
begin
  Result := @Status_Buff;
  Status_Critical__.Lock;
  Status_Buff[0] := 0;
  Status_Buff[1] := 0;
  try
    if Status_Pool.Num > 0 then
      begin
        L := length(Status_Pool.First^.Data);
        if L > 0 then
          begin
            CopyPtr(@Status_Pool.First^.Data[0], @Status_Buff, Min(L, SizeOf(Status_Buff) - 1));
            Status_Buff[Min(L, SizeOf(Status_Buff) - 1)] := 0;
          end;
        Status_Pool.Next;
      end;
  finally
      Status_Critical__.UnLock;
  end;
end;

(*
  * LF_PostStatus
  *
  * Injects a user-supplied message into the status system, as if it had
  * been emitted by the library itself.
  *
  * [PITFALL] Before LF_PrepareDone, the message may be discarded. See
  *   the interface documentation.
  *)
procedure LF_PostStatus(status: pansichar);
begin
  if not Simulator_Main_Thread_Activted then
    begin
      DoStatus('LF_PostStatus: Main thread not running; message queued directly. message: %s', [DS(status).Text]);
      exit;
    end;
  Status_Critical__.Lock;
  try
      Post_To_DoStatus_Queue(TCompute.CurrentThread, DS(status), 0);
  finally
      Status_Critical__.UnLock;
  end;
end;

(*
  * LF_Shutdown
  *
  * Gracefully terminates the entire LingoFuse framework.
  *
  * ===========================================================================
  * STEPS (in order)
  * ===========================================================================
  *
  *   1. Clears the network event callbacks (On_Network_Connect_Event /
  *      On_Network_Disconnect_Event). This prevents any in-flight worker
  *      thread from jumping into a callback after we start tearing down.
  *
  *   2. Stops all sequenced notification threads.
  *
  *   3. Frees all remaining data handles.
  *
  *   4. Exits the simulated main thread (LF_ExitMainThread).
  *
  *   5. Clears the global LF_App_Pool. This is where TLF_App objects that
  *      were detached with LF_FreeApp are finally destroyed.
  *
  *   6. Unloads the IPC library and closes the core dispatch thread.
  *
  * ===========================================================================
  * [PITFALL] Safe to call multiple times.
  * ===========================================================================
  *
  * [PITFALL] After LF_Shutdown, the library is fully reset and can be
  *   re-initialised by calling LF_PrepareService / LF_PrepareClient again
  *   followed by LF_PrepareDone.
  *
  * [PITFALL] Even if LF_FreeApp was never called for some apps,
  *   LF_Shutdown ensures they are properly destroyed, preventing leaks.
  *
  * [PITFALL] The network event callbacks are cleared FIRST. If you rely
  *   on a final disconnect notification, install a separate hook that
  *   is not cleared here, or handle the event before calling LF_Shutdown.
  *)
procedure LF_Shutdown;
begin
  // reset network event – protects against in-flight worker threads
  On_Network_Connect_Event := nil;
  On_Network_Disconnect_Event := nil;

  try
    LF_Notify_Sequence_Thread_Pool.Stop;
    LF_DataPool.Free_All_Hnd();
  except
  end;
  LF_ExitMainThread();
  LF_App_Pool.Clear;
  UnloadIPCLibrary();
  Close_Core_Dispatch_Thread();
end;

initialization

// reset network event
On_Network_Connect_Event := nil;
On_Network_Disconnect_Event := nil;

(*
  * ===========================================================================
  * INITIALIZATION
  * ===========================================================================
  *
  * Sets up all global state required by the LingoFuse export layer.
  *
  * [PITFALL] This block runs as part of unit initialisation, BEFORE any
  *   exported function is called. Do not remove or reorder the statements
  *   below – LF_PrepareService / LF_PrepareClient / LF_PrepareDone all
  *   depend on these globals being initialised.
  *)

(* Per-call counter used by LF_Generate_AppName to guarantee unique names. *)
Generate_AppName_Call_Num := 0;

(* Critical section that protects the counter above. *)
Generate_AppName_Critical := TCritical.Create;

(* List of C4 command strings queued by LF_PrepareService /
   LF_PrepareClient before the main thread starts. *)
Prepare_Commands := TPascalStringList.Create;

(* Tag seed starts at 1 so that the first prepared service/client gets a
   non-zero tag. Tag 0 is treated as "unset" in some lookup paths. *)
Tag_Seed := 1;

(* Maps tags to app handles and address info. Used by the tunnel bridge
   to bind apps to clients when they connect. *)
AppHnd_Bind_Tag_List := TAppHnd_Bind_Tag_List.Create;

(* Simulated main thread state flags. *)
Init_Running := True;
Init_Successed := False;
Simulated_Main_Thread_Running := False;

(* C4 event bridges for logging and app binding. *)
Temp_C40_PhysicsTunnel_Bridge__ := TTemp_C40_PhysicsTunnel_Bridge__.Create;
On_C40_PhysicsTunnel_Event_Console := Temp_C40_PhysicsTunnel_Bridge__;
Temp_C40_PhysicsService_Bridge__ := TTemp_C40_PhysicsService_Bridge__.Create;
On_C40_PhysicsService_Event_Console := Temp_C40_PhysicsService_Bridge__;

(* Default runtime options. See LF_SetOption for the full list. *)
Overlap_Connection := False;
Wait_Connection_ReadyOk := True;
Wait_Connection_Timeout := 30 * 1000;   (* 30 seconds *)

(* When loaded as a shared library (IsLibrary = True), force safe defaults:
   thread IDs hidden, console output on, quiet mode enabled. This reduces
   noise and avoids surprises for host applications that do not expect
   chatty logs. *)
if IsLibrary then
  begin
    Z.status.StatusThreadID := False;
    Z.status.ConsoleOutput := True;
    Z.Net.C4.C40SetQuietMode(True);
  end;

(* LingoFuse does not use per-service directories; disable the C4 default
   to avoid creating spurious folders on disk. *)
C40_EnablePerServiceDirectory := False;

(* Protects the client lookup in LF_Call / LF_Notify / LF_Sequenced_Notify. *)
Find_Class_Critical := TCritical.Create('Find_Class_Critical');

(* Status queue + its mutex. The DoStatus hook is installed below. *)
Status_Pool := TStatus_Buffer.Create;
Status_Critical__ := TCritical.Create('Status_Critical__');
AddDoStatusHookC(Status_Pool, backcall_DoStatus);

finalization

(*
  * ===========================================================================
  * FINALIZATION
  * ===========================================================================
  *
  * Tears down all global state. Runs AFTER LF_Shutdown has been called (or
  * after the host application has finished using the library).
  *
  * [PITFALL] All global variables set in initialization MUST be released
  *   here. Failure to do so leaks memory and may leave dangling callbacks
  *   installed in Z.Status.
  *
  * [PITFALL] The order of releases matters:
  *   – C4 event bridges are unhooked FIRST to prevent any late callbacks.
  *   – The DoStatus hook is removed BEFORE Status_Pool is freed;
  *     otherwise a late DoStatus could touch a freed object.
  *)

(* Unhook C4 event bridges. This must run before freeing them, otherwise
   the C4 layer could call into a half-destroyed object. *)
On_C40_PhysicsTunnel_Event_Console := nil;
On_C40_PhysicsService_Event_Console := nil;

(* Free prepared command list and tag list. *)
DisposeObjectAndNil(Prepare_Commands);
DisposeObjectAndNil(AppHnd_Bind_Tag_List);

(* Free C4 event bridge instances. *)
DisposeObjectAndNil(Temp_C40_PhysicsTunnel_Bridge__);
DisposeObjectAndNil(Temp_C40_PhysicsService_Bridge__);

(* Free the client-lookup critical section. *)
DisposeObjectAndNil(Find_Class_Critical);

(* Remove the DoStatus hook BEFORE freeing the status queue. *)
RemoveDoStatusHook(Status_Pool);
DisposeObjectAndNil(Status_Pool);
DisposeObjectAndNil(Status_Critical__);

(* Free the app-name generator critical section. *)
DisposeObjectAndNil(Generate_AppName_Critical);

end.
