(*
  * ===========================================================================
  * Z.LingoFuse_Export – C ABI Export Layer for LingoFuse
  * ===========================================================================
  *
  * This unit provides a set of plain C‑style (cdecl) functions that can be
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
  *   – Registration of local Call and Notify APIs with user‑supplied cdecl
  *     callbacks.
  *   – Preparation and startup of the underlying C4 distributed communication
  *     layer (TCP and IPC).
  *   – Remote API calls and notifications (including sequenced notifications)
  *     across a network.
  *
  * The unit also manages a simulated main thread that runs the C4 progress
  * loop, making the library self‑contained for applications that do not have
  * their own main loop. All exported functions are thread‑safe; they can be
  * called concurrently from multiple threads.
  *
  * Runtime parameters (timeouts, logging, IPC settings) can be adjusted
  * dynamically via the LF_SetOption function. They are not automatically
  * persisted to disk; if persistence is needed, applications should read/write
  * their own configuration files.
  *
  * All string parameters (API names, descriptions, addresses) must be UTF‑8
  * encoded and null‑terminated (PAnsiChar). The library internally decodes
  * them to Pascal strings. The internal binary data handles are encoding‑
  * agnostic – they are just byte buffers.
  *
  * Thread safety: all exported functions are thread‑safe. For a given TDataHnd___,
  * write operations must be serialised; read operations are safe as long as
  * the handle is not being written concurrently.
  * Callbacks are executed in background threads – do not perform blocking
  * operations or call LF_Call/LF_Notify inside a callback (risk of deadlock).
  * Offload heavy work to separate threads.
  *
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
  * For remote calls, prepare a service and clients with LF_PrepareService/
  * LF_PrepareClient, then start with LF_PrepareDone, and use LF_Call/
  * LF_Notify / LF_Sequenced_Notify with application names.
  *
  * Dependencies: Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.Status,
  *   Z.UnicodeMixedLib, Z.Net.C4, Z.LingoFuse_Core, Z.Net.C4.LingoFuse, etc.
  * ===========================================================================
  *
  *  WARNING: This file has been heavily commented for clarity. All comments
  *  are for documentation purposes and do not affect runtime behaviour.
  * ===========================================================================
*)
unit Z.LingoFuse_Export;

{$DEFINE FPC_DELPHI_MODE}
{$I ..\pascal\zNetV2\source\Z.Define.inc}

interface

type
  { * TDataHnd___: Opaque handle to a LingoFuse data buffer.
    * Internally it is a pointer to a TLF_Data record, but external code
    * must never dereference it. Use the provided LF_* functions to read,
    * write, and manage its contents.
    * Created with LF_CreateData, freed with LF_FreeData. }
  TDataHnd___ = Pointer;

  { * TAppHnd___: Opaque handle to an application context (TLF_App).
    * Represents a logical application that can host multiple APIs.
    * Created with LF_CreateApp, freed with LF_FreeApp. }
  TAppHnd___ = Pointer;

  { * TLF_Call_Event: Callback prototype for request‑response (Call) APIs.
    * Must be declared with the cdecl calling convention.
    * @param Trigger  User‑supplied pointer passed to the callback unchanged.
    * @param Input    TDataHnd___ containing the serialised request parameters.
    *                 Read with LF_ReadBuffer / LF_GetBuffer.
    * @param Output   TDataHnd___ to hold the result. Write with
    *                 LF_WriteBuffer / LF_SetSize. }
  TLF_Call_Event = procedure(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;

  { * TLF_Notify_Event: Callback prototype for one‑way notification (Notify) APIs.
    * Must be cdecl.
    * @param Trigger  User‑supplied pointer.
    * @param Input    TDataHnd___ containing the notification payload.
    *                 Read with LF_ReadBuffer / LF_GetBuffer.
    *                 No output is produced. }
  TLF_Notify_Event = procedure(Trigger: Pointer; Input: TDataHnd___); cdecl;

  { ---- DataHnd Operations ---- }

  { * LF_CreateData: Creates a new data handle initialised with the
    * given API name. The internal buffer is empty (size = 0).
    * @param MethodName  Null‑terminated UTF‑8 string naming the target API.
    * @return A new TDataHnd___ (never nil). Must be freed with LF_FreeData.
    * @Example:
    *   TDataHnd___ d = LF_CreateData("echo");
    *   int value = 123;
    *   LF_WriteBuffer(d, &value, sizeof(value));
    *   // ... use d in a call ...
    *   LF_FreeData(d); }
function LF_CreateData(MethodName: pansichar): TDataHnd___; cdecl;

{ * LF_FreeData: Destroys a data handle and releases all associated
  * memory. After this call, the handle is invalid.
  * @param Hnd  The handle to free (can be nil, does nothing).
  * @Note If the main thread is not active (i.e., before LF_PrepareDone),
  *        the handle is not freed to avoid issues during library initialisation. }
procedure LF_FreeData(Hnd: TDataHnd___); cdecl;

{ * LF_GetBuffer: Returns a direct pointer to the raw binary data in the
  * handle. The pointer is valid until the handle is freed or the buffer
  * is resized. Do not free this pointer.
  * @param Hnd  The data handle.
  * @return Pointer to internal memory block, or nil if empty.
  * @Note Useful for zero‑copy read‑only access. }
function LF_GetBuffer(Hnd: TDataHnd___): Pointer; cdecl;

{ * LF_WriteBuffer: Appends or overwrites binary data into the handle's
  * buffer at the current position. The position advances by the number of
  * bytes written. The buffer is automatically enlarged if needed.
  * @param Hnd   The data handle.
  * @param Buff  Source data pointer.
  * @param Size  Number of bytes to write.
  * @return Number of bytes written (normally equals Size). }
function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl;

{ * LF_ReadBuffer: Reads binary data from the handle's buffer into the
  * caller's buffer, starting at the current position. The position
  * advances by the number of bytes actually read.
  * @param Hnd   The data handle.
  * @param Buff  Destination buffer.
  * @param Size  Maximum number of bytes to read.
  * @return Number of bytes actually read (may be less than Size if EOF). }
function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl;

{ * LF_GetPos: Returns the current read/write position (zero‑based).
  * @param Hnd  The data handle.
  * @return Current offset in bytes. }
function LF_GetPos(Hnd: TDataHnd___): int64; cdecl;

{ * LF_SetPos: Sets the current read/write position. If the new position
  * is beyond the current size, the buffer is extended with zero bytes.
  * @param Hnd   The data handle.
  * @param Pos_  New position (must be >= 0). }
procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64); cdecl;

{ * LF_GetSize: Returns the total size (in bytes) of the data stored in
  * the handle.
  * @param Hnd  The data handle.
  * @return Current buffer size. }
function LF_GetSize(Hnd: TDataHnd___): int64; cdecl;

{ * LF_SetSize: Resizes the internal buffer to the specified size.
  * If larger, the added space is uninitialised; if smaller, data beyond
  * the new size is discarded.
  * @param Hnd    The data handle.
  * @param Size_  New desired size in bytes. }
procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64); cdecl;

{ ---- AppHnd Operations ---- }

{ * LF_CreateApp: Creates a new application context with the given
  * name and description. The handle encapsulates a TLF_App object that
  * can host a set of APIs. It must be freed with LF_FreeApp.
  * @param appName  Unique application identifier (UTF‑8, case‑sensitive
  *                 for storage but matching is case‑insensitive).
  * @param Desc     Human‑readable description (UTF‑8, can be empty).
  * @return A new TAppHnd___ (never nil).
  * @Note The application name is used for remote routing. }
function LF_CreateApp(appName, Desc: pansichar): TAppHnd___; cdecl;

{ * LF_FreeApp: Detaches an application from all clients and stops its
  * sequenced notification threads, but does NOT immediately destroy the
  * underlying TLF_App object. The object remains alive in the global
  * LF_App_Pool until LF_Shutdown is called, which then frees it forcibly.
  *
  * This two‑phase destruction prevents dangling pointers while allowing
  * other components (e.g., network broadcasts) to continue referencing the
  * application data safely. After calling LF_FreeApp, the handle should be
  * considered invalid and not used for further registrations or calls.
  *
  * @param appHnd  The application handle to detach (can be nil).
  * @see LF_Shutdown  for final cleanup.
  * }
procedure LF_FreeApp(appHnd: TAppHnd___); cdecl;

{ * LF_Generate_appName: Generates a globally unique application name string.
  * The name is built by concatenating:
  *   - All active C4 physics tunnel addresses and remote IDs,
  *   - The current process name (with PID),
  *   - A high‑resolution timestamp.
  * This ensures that each call produces a distinct identifier, suitable for
  * point‑to‑point communication where each node must have a unique identity.
  *
  * WARNING: The returned pointer is valid for only 5 seconds; the library
  * automatically frees the underlying memory after that time. The caller
  * MUST copy the content immediately (e.g., via strdup/strcpy in C, or
  * by decoding to a Python string) before the pointer becomes invalid.
  * Failure to do so will result in accessing freed memory.
  *
  * @return PAnsiChar pointing to a null‑terminated UTF‑8 string.
  * @Example:
  *   char* uniqueName = LF_Generate_AppName();
  *   char* copy = strdup(uniqueName);  // MUST copy immediately
  *   // use copy...
  *   free(copy);
  * }
function LF_Generate_AppName(): pansichar; cdecl;

{ * LF_Get_appName: Retrieves the application name associated with the given
  * application handle.
  *
  * WARNING: The returned pointer is valid for only 5 seconds; the library
  * automatically frees the underlying memory after that time. The caller
  * MUST copy the content immediately (e.g., via strdup/strcpy in C, or
  * by decoding to a Python string) before the pointer becomes invalid.
  *
  * @param appHnd The application handle (TLF_App) whose name is queried.
  * @return PAnsiChar pointing to the UTF‑8 encoded name stored in the app.
  * @Note This function simply returns the Name field of the TLF_App object.
  * }
function LF_Get_AppName(appHnd: TAppHnd___): pansichar; cdecl;

{ * LF_BindApp: Binds an application to all currently unbound LingoFuse
  * clients. This function must be called after LF_PrepareDone has been
  * invoked and the simulated main thread is active; otherwise, it logs an
  * error and returns 0 without any binding.
  *
  * Upon successful binding, each client will register the application and
  * its APIs with the service, making them available for remote discovery
  * and invocation. The binding process logs the application name, description,
  * connection details, and a list of all registered APIs with their modes
  * (call/notify).
  *
  * @param appHnd The application handle to bind.
  * @return The number of clients to which the application was successfully
  *         bound. A return value of 0 indicates that either the main thread
  *         is not active, or all existing clients are already occupied
  *         (each client can only host one application). In the latter case,
  *         a log message is emitted: "All clients are already occupied".
  *         If at least one client is bound, the application becomes available
  *         on the network.
  * @Note The function only binds to clients that currently have a nil app
  *       reference (i.e., Cli.app = nil). Clients already hosting an app
  *       are skipped. If no such clients exist, the result is 0.
  * }
function LF_BindApp(appHnd: TAppHnd___): Integer; cdecl;

(*
  * LF_RegisterCall: Registers a Call‑mode API within the application.
  * The API name must be unique inside the application. When a call is
  * made (locally or remotely), the provided OnCall callback is invoked.
  * @param appHnd   The application handle.
  * @param MethodName  Unique API name (UTF‑8, case‑insensitive).
  * @param Desc     Optional description (UTF‑8).
  * @param Trigger  User data passed to the callback.
  * @param OnCall   cdecl function pointer implementing the API.
  * @return 1 if registration succeeded, 0 if the API name already exists.
  * @Example (C):
  *   static void __cdecl MyCall(void* trigger, void* input, void* output) {
  *     // read input, write output
  *   }
  *   LF_RegisterCall(app, "echo", "Echo", NULL, MyCall); *)
function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer; cdecl;

{ * LF_RegisterNotify: Registers a Notify‑mode API.
  * Similar to LF_RegisterCall but for one‑way notifications. The callback
  * receives only an input handle and produces no response.
  * @param appHnd    The application handle.
  * @param MethodName Unique API name (UTF‑8, case‑insensitive).
  * @param Desc      Optional description.
  * @param Trigger   User data passed to callback.
  * @param OnNotify  cdecl function pointer.
  * @return 1 on success, 0 if the name already exists. }
function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer; cdecl;

{ * LF_Unregister: Removes a previously registered API from the application.
  * This function also triggers a network update broadcast. After calling
  * LF_Unregister, the change is propagated to all connected C4 services and
  * clients within approximately 3 seconds (depending on network latency).
  * @param appHnd   The application handle.
  * @param MethodName The name of the API to unregister (UTF‑8).
  * @return 1 on success, 0 if the API name does not exist. }
function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): Integer; cdecl;

{ * LF_LocalCall: Executes a Call‑mode API locally within the
  * application, bypassing the network. This is a synchronous call that
  * returns a new data handle containing the result. The caller must free
  * both the input and result handles.
  * @param appHnd  The application handle.
  * @param Param   Input data handle (created with LF_CreateData,
  *                containing the API name and parameters).
  * @return A new TDataHnd___ with the result (size 0 if the API was not
  *         found or an error occurred). Must be freed.
  * @Note The input handle is not freed by this function; call
  *       LF_FreeData on it separately.
  * @Example:
  *   TDataHnd___ d = LF_CreateData("echo");
  *   LF_WriteBuffer(d, "hello", 5);
  *   TDataHnd___ res = LF_LocalCall(app, d);
  *   LF_FreeData(d);
  *   // process res...
  *   LF_FreeData(res); }
function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___; cdecl;

{ * LF_LocalNotify: Sends a notification locally within the
  * application. This is synchronous but does not wait for any result.
  * @param appHnd  The application handle.
  * @param Param   Input data handle (created with LF_CreateData).
  * @Note The input handle is not freed by this function; the caller must
  *       free it separately. }
procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___); cdecl;

{ ---- Advanced Communication Service ---- }

{ * LF_PrepareService: Prepares or immediately creates a C4 service.
  * This function can be called at any time – before or after LF_PrepareDone.
  * If the simulated main thread is already running, the service is created
  * and started immediately (dynamic addition). Otherwise, it is queued and
  * will be started when LF_PrepareDone is called.
  * @param ListeningAddr_  Address to bind (UTF‑8). Supported formats:
  *          - IPv4: "0.0.0.0" or "127.0.0.1:9898"
  *          - IPv6: "[::1]:8080" or "::1|8080"
  *          - Domain: "myhost.com:9090"
  *          - IPC: "ipc:my_service" (port ignored)
  *        Default port is 9898 if omitted.
  * @param PhysicsAddr_    Public address advertised to clients (same format).
  * @return A tag (integer ID) identifying this service, or -1 if a duplicate
  *         listening address/port already exists.
  * @Note Services and clients can be prepared in any order; clients will wait
  *       for services to become available.
  * @Example:
  *   // Prepare a TCP service and an IPC service, then start.
  *   LF_ResetPrepare();
  *   LF_PrepareService("0.0.0.0", "127.0.0.1:9898");   // TCP
  *   LF_PrepareService("ipc:test", "ipc:test");        // IPC
  *   LF_PrepareClient("127.0.0.1:9898", app);
  *   LF_PrepareDone(); }
function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): Integer; cdecl;

{ * LF_PrepareClient: Prepares or immediately creates a C4 client.
  * ...
  * @param PhysicsAddr_  Address of the remote service to connect to (same
  *                      format as for LF_PrepareService).
  * @param appHnd        Optional TAppHnd___. If non‑nil, the client exposes
  *                      this application; if nil, it acts as a consumer.
  * @return A tag for this client, or -1 if a duplicate address already exists.
  * @Note The behaviour regarding duplicate addresses is controlled by the
  *       global Overlap_Connection option (see LF_SetOption).
  *       - If Overlap_Connection = False (default), only one client per
  *         address can exist; subsequent calls with different appHnd will
  *         be ignored (the appHnd is silently discarded).
  *       - If Overlap_Connection = True, each call creates a new independent
  *         client and binds the provided appHnd, allowing multiple
  *         applications on the same remote service.
  *       The client automatically reconnects if the connection is lost.
  *       Upon reconnection, the application (if provided) is re‑registered.
  * @Example:
  *   LF_PrepareClient("127.0.0.1:9898", nil);   // consume only
  *   LF_PrepareClient("ipc:test", app);        // provide APIs via app }
function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): Integer; cdecl;

{ * LF_ResetPrepare: Clears all previously prepared services and clients.
  * Call this before preparing a new set to avoid conflicts.
  * @Note This function does not affect already running services/clients;
  *       it only clears the preparation queue. }
procedure LF_ResetPrepare(); cdecl;

{ * LF_PrepareDone: Starts the C4 framework with all prepared services and
  * clients. This function blocks until the framework is initialised. It also
  * launches the simulated main thread that runs the C4 progress loop.
  * @return 1 if successful, 0 on failure.
  * @Note After this call, remote APIs can be invoked with LF_Call/Notify.
  *       The main thread continues until LF_ExitMainThread or LF_Shutdown is
  *       called. This function can be called multiple times after a shutdown
  *       (i.e., you can restart the framework). Do not call it again without
  *       resetting or shutting down first. Check logs via LF_GetStatus on
  *       failure. }
function LF_PrepareDone: Integer; cdecl;

{ * LF_ExitMainThread: Signals the simulated main thread to exit gracefully.
  * After this call, the network loop stops, but resources are not
  * automatically freed. You should still call LF_Shutdown for a full cleanup.
  * @Note This function can be called repeatedly; it is safe. After exiting,
  *       you may call LF_PrepareDone again to restart the framework. }
procedure LF_ExitMainThread; cdecl;

{ * LF_Call: Performs a remote (or local) call to the specified application.
  * This function blocks until the response is received or the timeout expires.
  * @param appName   Target application name (UTF‑8, case‑insensitive).
  * @param Param     Input data handle (API name + parameters). The function
  *                  reads the buffer content synchronously and serialises it
  *                  for transmission; it does not take ownership of the handle.
  *                  The caller remains responsible for freeing it with
  *                  LF_FreeData after this call returns.
  * @param Timeout_  Maximum wait in milliseconds. 0 means infinite.
  * @return A new TDataHnd___ containing the result. If the call times out or
  *         fails, the handle has size 0 (but is still valid). Must be freed
  *         with LF_FreeData.
  * @Note The function first tries to find a local instance of the target
  *       application to avoid network round‑trip. }
function LF_Call(appName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl;

{ * LF_Notify: Sends a one‑way notification to the specified application.
  * Returns immediately after the notification has been sent (it does not
  * wait for any response). The input data is read synchronously and serialised
  * before return; the caller can safely free the handle afterwards.
  * @param appName  Target application name (UTF‑8, case‑insensitive).
  * @param Param    Input data handle (API name + payload). The caller must
  *                 free it with LF_FreeData after this call.
  * @Example:
  *   TDataHnd___ d = LF_CreateData("event");
  *   LF_WriteBuffer(d, "hello", 5);
  *   LF_Notify("my_app", d);
  *   LF_FreeData(d); }
procedure LF_Notify(appName: pansichar; Param: TDataHnd___); cdecl;

{ * LF_Sequenced_Notify: Sends a one‑way notification with FIFO ordering
  * guarantee for the same (application, API) pair. The library maintains a
  * dedicated thread per (app, api) key, which processes notifications
  * sequentially. Large payloads are handled efficiently through chunked
  * streaming, avoiding excessive memory copies. The call returns immediately
  * after the data is queued for transmission.
  * @param appName  Target application name (UTF‑8, case‑insensitive).
  * @param Param    Input data handle (payload). The caller is responsible
  *                 for freeing it with LF_FreeData after the call returns.
  * @Note The underlying thread pool has a 5‑minute idle timeout; threads
  *       terminate and are re‑created as needed. }
procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___); cdecl;

{ * LF_CheckMainThread: Checks whether the simulated main thread (which runs
  * the C4 progress loop) is currently active.
  * @return 1 if the simulated main thread is running, 0 otherwise.
  * @Note This function can be used to determine whether remote communication
  *       is available (LF_PrepareDone has been called and the loop is running).
  *       After LF_ExitMainThread is called, this returns 0. }
function LF_CheckMainThread(): Integer; cdecl;

{ * LF_CheckApp: Checks whether an application with the given name is
  * currently registered on the network (either locally or on any remote client
  * that has been discovered).
  * @param appName  Application name to look for (UTF‑8, case‑insensitive).
  * @return 1 if at least one instance of the application is available,
  *         0 otherwise.
  * @Note This function performs a quick lookup but does not guarantee that
  *       the application is still online at the moment of a subsequent call.
  *       It is useful for probing availability before making a call. }
function LF_CheckApp(appName: pansichar): Integer; cdecl;

{ * LF_CheckApi: Checks whether a specific API is available on the network
  * for the given application. It searches both local and remote instances
  * of the application to determine if the API is exported.
  * @param appName   Application name (UTF‑8, case‑insensitive).
  * @param apiName   API name (UTF‑8, case‑insensitive).
  * @return 1 if the API is available on at least one instance of the
  *         application, 0 otherwise.
  * @Note This function performs a quick lookup based on cached information
  *       and may not reflect recent changes. It is useful for probing
  *       availability before making a call, but does not guarantee that the
  *       API will still be available at the moment of the actual call. }
function LF_CheckApi(appName, apiName: pansichar): Integer; cdecl;

{ * LF_SetOption: Dynamically adjusts global runtime options of the LingoFuse
  * framework. All changes take effect immediately for subsequent operations.
  *
  * @param Option  Configuration key (UTF‑8, case‑insensitive). The following
  *                keys (and their aliases) are recognised:
  *
  *                === Authentication ===
  *                - "password" / "passwd"
  *                    Sets the C4 P2PVM authentication token (string).
  *
  *                === Logging & Debugging ===
  *                - "Quiet"
  *                    Enable/disable quiet mode (boolean). When enabled, most
  *                    internal log messages are suppressed.
  *                - "ShowThreadID" / "ShowThread" / "Show_Thread"
  *                    Show thread IDs in log output (boolean).
  *                - "ConsoleOutput" / "Console_Output"
  *                    Enable or disable console logging (boolean).
  *
  *                === Connection Readiness ===
  *                === Connection Readiness ===
  *                - "Overlap_Connection" / "Overlap_Client" / "OverlapConnection" / "OverlapClient" / "OverlapConnect"
  *                    Controls whether multiple independent C4 physics tunnels can be created
  *                    to the same remote address (IP:Port).  *
  *                When set to False (default):
  *                  - LF_PrepareClient will use the 'KeepAlive' command.
  *                  - If a tunnel to the given address already exists, it will be reused.
  *                  - The 'appHnd' parameter is effective ONLY the first time a client
  *                    for that address is prepared. Subsequent calls with a different
  *                    appHnd will be ignored (the tag is stored but no new client is
  *                    created, so the application never gets bound).
  *                  - This mode is suitable for scenarios where a single logical client
  *                    connection is shared across multiple components, but it is NOT
  *                    appropriate for hosting multiple independent applications on the
  *                    same remote service.
  *
  *                When set to True:
  *                  - LF_PrepareClient will use the 'NewKeepAlive' command.
  *                  - A new physical tunnel is created for each call, even if a tunnel
  *                    to the same address already exists.
  *                  - Each call receives a unique tag and the provided appHnd is bound
  *                    to the newly created client.
  *                  - This enables hosting multiple applications on the same remote
  *                    service, each with its own dedicated connection.
  *                  - Use this mode for multi‑tenant services, load testing, or when
  *                    each application requires its own isolated network channel.
  *
  *                Important notes:
  *                  - When Overlap_Connection is False and you attempt to prepare
  *                    multiple clients with different appHnds, no error is raised;
  *                    the second and subsequent appHnds are silently ignored. To avoid
  *                    confusion, always set Overlap_Connection to True if you intend
  *                    to bind multiple applications.
  *                  - Overlap_Connection is a global setting; changing it after some
  *                    clients have been prepared will affect only subsequent calls to
  *                    LF_PrepareClient.
  *                  - IPC connections (ipc:*) are not affected by this setting; they
  *                    are always treated as non‑overlapping (only one client per address).
  *                @Note: If you need to dynamically change the application on an
  *                       existing client, use the LF_BindApp function or obtain the
  *                       client handle and set its APP property directly.
  *
  *                - "Wait_Connection_ReadyOk" / "Wait_API_Prepare_Done" /
  *                  "API_Prepare_Done_Wait" / "WaitConnect" / "Wait_Ready" /
  *                  "WaitReady"
  *                    If True, LF_PrepareDone blocks until all prepared clients
  *                    are connected and their applications are online (boolean).
  *                - "Wait_Connection_Timeout" / "Wait_TimeOut" /
  *                  "API_Prepare_Done_TimeOut" / "WaitTimeOut"
  *                    Timeout in milliseconds for the above wait (integer).
  *
  *                === IPC (Inter‑Process Communication) ===
  *                - "IPC_Serv_ThreadCount" / "IPC_ThreadCount" /
  *                  "IPC_Server_ThreadCount"
  *                    Number of threads in the IPC server thread pool (integer).
  *                - "IPC_Serv_MaxQueueLength" / "IPC_MaxQueueLength" /
  *                  "IPC_Server_MaxQueueLength"
  *                    Maximum length of the IPC message queue (integer).
  *                - "IPC_Serv_MaxMsgSize" / "IPC_MaxMsgSize" /
  *                  "IPC_Server_MaxMsgSize"
  *                    Maximum size (in bytes) of a single IPC message (integer).
  *
  *                === Sequenced Notifications ===
  *                - "Fixed_Sequenced_Time" / "Fixed_Sequenced_Life"
  *                    Idle timeout (in milliseconds) for sequenced notification
  *                    fallback. When selecting a client for a sequenced
  *                    notification, if the candidate with the oldest timestamp
  *                    is older than this value, the system falls back to the
  *                    newest client to avoid starvation (integer).
  *
  * @param Value   New value for the given option (UTF‑8). Boolean values
  *                accept "True"/"False", "1"/"0", "Yes"/"No" (case‑insensitive).
  *                Integer values are parsed as decimal numbers. String values
  *                are used as‑is.
  *
  * @Note Unknown options are silently ignored. Changes are not persisted
  *       across restarts; applications must store their own configuration.
  * }
procedure LF_SetOption(Option, Value: pansichar); cdecl;

{ * LF_GetStatusCount: Returns the number of pending log messages in the
  * internal status buffer.
  * @return The number of messages currently queued.
  * @Note This function is thread‑safe and can be called concurrently with
  *       LF_GetStatus. }
function LF_GetStatusCount(): Integer; cdecl;

{ * LF_GetStatus: Retrieves the next log message from the internal status
  * buffer (FIFO order). The returned pointer points to a static 64‑KB buffer
  * that is valid only until the next call to this function (or any function
  * that may modify the buffer). The caller must copy the string immediately
  * if it needs to be retained.
  * Messages longer than 65,534 bytes are truncated.
  *
  * WARNING: This function relies on the simulated main thread to process the
  * status queue. If the main thread has not been started (i.e., before
  * LF_PrepareDone has been called), the buffer may be empty or contain stale
  * data. Do not rely on it until the framework is fully initialised.
  *
  * @return PAnsiChar pointing to a null‑terminated UTF‑8 string, or an empty
  *         string if no message is available.
  * @Note The returned pointer must not be freed by the caller.
  * @Important This function relies on the simulated main thread to process the
  *            status queue. If the main thread has not been started (i.e.,
  *            before LF_PrepareDone), the buffer may be empty or contain stale
  *            data. Do not rely on it until the framework is initialised. }
function LF_GetStatus(): pansichar; cdecl;

{ * LF_PostStatus: Injects a user‑supplied log message into the internal
  * status buffer, as if it were generated by the library itself. This is
  * useful for merging external logging with the LingoFuse status stream.
  * @param status  Null‑terminated UTF‑8 string containing the message to add.
  *
  * WARNING: This function also relies on the main thread to process the queue.
  * If the main thread has not been started (i.e., before LF_PrepareDone has
  * been called), messages may be discarded or may not appear in the buffer
  * at all. Use only after the framework is fully initialised.
  *
  * @Note The message is appended to the buffer and will be retrievable via
  *       LF_GetStatus in FIFO order.
  * @Important Similar to LF_GetStatus, this function relies on the main thread
  *            to process the queue. Before LF_PrepareDone, messages may be
  *            discarded or not appear in the buffer. }
procedure LF_PostStatus(status: pansichar); cdecl;

{ * LF_Shutdown: Gracefully terminates the entire LingoFuse framework.
  *
  * This procedure:
  *   1. Stops all sequenced notification threads.
  *   2. Frees all remaining data handles.
  *   3. Exits the simulated main thread.
  *   4. Clears the global LF_App_Pool, which destroys every TLF_App object
  *      that has not been physically freed by LF_FreeApp.
  *   5. Unloads the IPC library and closes the core dispatch thread.
  *
  * After LF_Shutdown, the library is fully reset and can be re‑initialised
  * by calling preparation functions again. It is safe to call multiple times.
  *
  * @Note  Even if you forget to call LF_FreeApp for some applications,
  *        LF_Shutdown ensures they are properly destroyed, preventing leaks.
  * }
procedure LF_Shutdown; cdecl;

implementation

uses
  SysUtils,
  Z.Core, Z.PascalStrings, Z.UPascalStrings, Z.status, Z.UnicodeMixedLib,
  Z.Parsing, Z.MemoryStream, Z.ListEngine, Z.TextDataEngine,
  Z.Net, Z.Net.C4, Z.Net.C4_Console_APP, Z.LingoFuse_Core, Z.Net.C4.LingoFuse,
  Z.IPC.API, Z.Net.Server.IPC, Z.Int128, Z.Notify, Z.Expression;

{ ------------------------------------------------------------------------------
  Internal helper: DS – Decode UTF‑8 string
  ------------------------------------------------------------------------------ }

function DS(P: Pointer): TLF_String; inline;
{ *
  * Decodes a null‑terminated UTF‑8 string (PAnsiChar) into a TLF_String.
  * This is used throughout the unit to convert external UTF‑8 inputs to
  * internal Unicode strings.
  * @Param P: Pointer to a null‑terminated UTF‑8 string.
  * @Returns: TLF_String (Unicode Pascal string).
  * @Note: The caller must ensure P is valid and null‑terminated.
  * @Example:
  *   var s: TLF_String;
  *   s := DS(myPAnsiChar);
  *   // now s is a Unicode string.
  * }
begin
  Result.ReadUTF8AnsiChar(P);
end;

{ ------------------------------------------------------------------------------
  Data Handle Operations
  ------------------------------------------------------------------------------ }

function LF_CreateData(MethodName: pansichar): TDataHnd___;
{ *
  * Creates a new data handle with the given API name.
  * Reads the UTF‑8 name, creates a TLF_Data record with a TMemory_Param_Tool,
  * and returns the handle.
  * @Param MethodName: Null‑terminated UTF‑8 string naming the API.
  * @Returns: A new TDataHnd___ (pointer to TLF_Data).
  * @Example:
  *   var d := LF_CreateData('echo');
  *   LF_WriteString(d, 'Hello');
  *   // use d...
  *   LF_FreeData(d);
  * }
var
  s: TLF_String;
begin
  s := DS(MethodName); // Decode UTF‑8 to internal string.
  Result := TLF_Data.New_Param(s); // Allocate a new input parameter handle.
end;

procedure LF_FreeData(Hnd: TDataHnd___);
{ *
  * Frees the TLF_Data record pointed to by Hnd.
  * @Param Hnd: The handle to free. If nil, does nothing.
  * @Note The handle is only freed if the simulated main thread is active.
  *       This is a safety measure to avoid double‑free during finalization.
  * @Example:
  *   LF_FreeData(myHandle);  // myHandle is now invalid.
  * }
begin
  if Simulator_Main_Thread_Activted and (Hnd <> nil) then
      TLF_Data.Free_Data(Hnd); // Delegate to the core's free routine.
end;

function LF_GetBuffer(Hnd: TDataHnd___): Pointer;
{ *
  * Returns the raw data pointer from the TLF_Data record.
  * @Param Hnd: The data handle.
  * @Returns: Pointer to the internal binary buffer, or nil if handle invalid.
  * @Note Updates the handle's usage timestamp to prevent automatic recycling.
  * @Warning The pointer is valid only until the handle is freed or resized.
  *          Do not free the returned pointer.
  * @Example:
  *   var p := LF_GetBuffer(data);
  *   if p <> nil then
  *     // read from p (read‑only)
  * }
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.GetBuffer // Get raw buffer from record.
  else
      Result := nil;
end;

function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
{ *
  * Delegates to TLF_Data.WriteBuff.
  * @Param Hnd: The data handle.
  * @Param Buff: Source data pointer.
  * @Param Size: Number of bytes to write.
  * @Returns: Number of bytes actually written.
  * @Note Updates the handle's usage timestamp.
  * @Warning The buffer is automatically enlarged if needed.
  * @Example:
  *   LF_WriteBuffer(d, @myInt, SizeOf(myInt));
  * }
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.WriteBuff(Buff, Size) // Write and advance position.
  else
      Result := 0;
end;

function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64;
{ *
  * Delegates to TLF_Data.ReadBuff.
  * @Param Hnd: The data handle.
  * @Param Buff: Destination buffer pointer.
  * @Param Size: Maximum number of bytes to read.
  * @Returns: Number of bytes actually read (may be less if EOF).
  * @Note Updates the handle's usage timestamp.
  * @Example:
  *   var val: Integer;
  *   LF_ReadBuffer(d, @val, SizeOf(val));
  * }
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.ReadBuff(Buff, Size) // Read and advance position.
  else
      Result := 0;
end;

function LF_GetPos(Hnd: TDataHnd___): int64;
{ *
  * Delegates to TLF_Data.Get_Pos.
  * @Param Hnd: The data handle.
  * @Returns: Current read/write position (0‑based).
  * @Note Updates the handle's usage timestamp.
  * }
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.Get_Pos
  else
      Result := 0;
end;

procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64);
{ *
  * Delegates to TLF_Data.Set_Pos.
  * @Param Hnd: The data handle.
  * @Param Pos_: New position (must be >= 0).
  * @Note If Pos_ exceeds the current size, the buffer is extended with zero bytes.
  * @Note Updates the handle's usage timestamp.
  * @Example:
  *   LF_SetPos(d, 0);  // rewind to beginning
  * }
begin
  if Hnd <> nil then
      PLF_Data(Hnd)^.Set_Pos(Pos_);
end;

function LF_GetSize(Hnd: TDataHnd___): int64;
{ *
  * Delegates to TLF_Data.Get_Size.
  * @Param Hnd: The data handle.
  * @Returns: Current buffer size in bytes.
  * @Note Updates the handle's usage timestamp.
  * }
begin
  if Hnd <> nil then
      Result := PLF_Data(Hnd)^.Get_Size
  else
      Result := 0;
end;

procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64);
{ *
  * Delegates to TLF_Data.Set_Size.
  * @Param Hnd: The data handle.
  * @Param Size_: New size in bytes. If larger, added space is uninitialised.
  * @Note Updates the handle's usage timestamp.
  * @Example:
  *   LF_SetSize(d, 1024);  // ensure at least 1024 bytes capacity
  * }
begin
  if Hnd <> nil then
      PLF_Data(Hnd)^.Set_Size(Size_);
end;

{ ------------------------------------------------------------------------------
  App Handle Operations
  ------------------------------------------------------------------------------ }

function LF_CreateApp(appName, Desc: pansichar): TAppHnd___;
{ *
  * Creates a TLF_App object, sets its name and description from UTF‑8 strings,
  * and returns the handle.
  * @Param appName: Null‑terminated UTF‑8 string naming the application.
  * @Param Desc: Null‑terminated UTF‑8 string describing the application.
  * @Returns: A new TAppHnd___ (pointer to TLF_App).
  * @Example:
  *   var app := LF_CreateApp('MyService', 'My service description');
  *   // register APIs, then free with LF_FreeApp(app);
  * }
var
  app: TLF_App;
begin
  app := TLF_App.Create; // Instantiate the app object.
  app.Name := DS(appName); // Set name.
  app.Desc := DS(Desc); // Set description.
  if app.Desc = '' then
      app.Desc := 'No Description'; // Provide a default if empty.
  Result := app;
end;

procedure LF_FreeApp(appHnd: TAppHnd___);
{ *
  * Frees the TLF_App object.
  * Also iterates over all C4 clients and clears any reference to this app
  * to avoid dangling pointers, and kills any sequenced notification threads
  * associated with this app.
  * @Param appHnd: The application handle to free.
  * @Example:
  *   LF_FreeApp(app);  // releases the app and its resources
  * }
var
  app: TLF_App;
  arry: TC40_Custom_Client_Array;
  i: Integer;
  Cli: TC40_LF_Client;
begin
  if not Core_Dispatch_Order_Activted then exit; // is shutdown

  app := appHnd; // Cast to TLF_App.
  arry := C40_ClientPool.FastSearchClass(TC40_LF_Client); // Find all LingoFuse clients.
  for i := 0 to length(arry) - 1 do
    begin
      Cli := arry[i] as TC40_LF_Client;
      if Cli.app = app then // If this client references our app,
          Cli.app := nil; // detach it.
    end;
  LF_Notify_Sequence_Thread_Pool.Kill_App(app); // Stop any sequenced notify threads for this app.
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
    // Concatenate all C4 physics tunnel addresses, remote IDs, process name, and current timestamp
    for i := 0 to C40_PhysicsTunnelPool.Count - 1 do
      begin
        if tmp <> '' then
            tmp.Append('&');
        tmp.Append(Build_Host_URL(C40_PhysicsTunnelPool[i].PhysicsAddr, C40_PhysicsTunnelPool[i].PhysicsPort) + '&' +
            umlIntToStr(C40_PhysicsTunnelPool[i].PhysicsTunnel.RemoteID).Text);
      end;
    tmp.Append('&' + Make_LingoFuse_Process_Name.Text + '&' + umlIntToStr(GetTimeTick()).Text +
        '&' + umlIntToStr(AtomInc(Generate_AppName_Call_Num)).Text); // Add process name and timestamp for uniqueness
    tmp := C_Generate_Prefix + tmp;
  finally
      Generate_AppName_Critical.UnLock;
  end;
  Result := tmp.BuildUTF8AnsiChar(); // Convert to UTF‑8 PAnsiChar
  Z.Notify.DelayFreeMem(5.0, Result); // Auto‑free after 5 seconds (caller must copy immediately)
  tmp := '';
end;

function LF_Get_AppName(appHnd: TAppHnd___): pansichar;
var
  app: TLF_App;
begin
  app := appHnd;
  Result := app.Name.BuildUTF8AnsiChar(); // Return app's stored name as UTF‑8
  Z.Notify.DelayFreeMem(5.0, Result); // Auto‑free after 5 seconds
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
  app := appHnd;
  if not Simulator_Main_Thread_Activted then // Main thread not active – cannot proceed
    begin
      DoStatus('LF_BindApp: Main thread is not active – cannot bind app.');
      exit;
    end;
  arry := C40_ClientPool.FastSearchClass(TC40_LF_Client); // Get all LingoFuse clients
  for i := 0 to length(arry) - 1 do
    begin
      Cli := arry[i] as TC40_LF_Client;
      if Cli.app = nil then // Only bind if client does not already have an app
        begin
          Cli.app := app; // Attach the application to this client
          inc(Result); // Count successful bindings

          // Log the app and its registered APIs.
          if Cli.C40PhysicsTunnel.IPC_Mode then
              DoStatus('APP %s "%s" Bind OK for Connection "%s"', [Cli.app.Name.Text, Cli.app.Desc.Text, Cli.C40PhysicsTunnel.PhysicsAddr.Text])
          else
              DoStatus('APP %s "%s" Bind OK for Connection "%s"', [Cli.app.Name.Text, Cli.app.Desc.Text, Build_Host_URL(Cli.C40PhysicsTunnel.PhysicsAddr, Cli.C40PhysicsTunnel.PhysicsPort)]);

          // Log each registered API with its mode (call/notify/error)
          if Cli.app.Engine.LF_MethodPool.Num > 0 then
            with Cli.app.Engine.LF_MethodPool.Repeat_ do
              repeat
                if Assigned(Queue^.Data.Data.Second.On_Call) then
                    tmp := 'call'
                else if Assigned(Queue^.Data.Data.Second.On_Notify) then
                    tmp := 'notify'
                else
                    tmp := 'error';
                DoStatus('  (%s) (%s) "%s"', [tmp.Text, Queue^.Data.Data.Primary, Queue^.Data.Data.Second.Desc.Text]);
              until not Next;
        end;
    end;
  if Result = 0 then
      DoStatus('LF_BindApp: All clients are already occupied – cannot bind app "%s".', [app.Name.Text]);
end;

function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer;
{ *
  * Registers a Call API by decoding UTF‑8 names and calling app.Engine.Reg_Call.
  * @Param appHnd: The application handle.
  * @Param MethodName: Null‑terminated UTF‑8 API name.
  * @Param Desc: Null‑terminated UTF‑8 description.
  * @Param Trigger: User data passed to the callback.
  * @Param OnCall: The cdecl callback function.
  * @Returns: 1 if registration succeeded, 0 if the API name already exists.
  * @Example (Pascal):
  *   procedure MyCall(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
  *   begin ... end;
  *   if LF_RegisterCall(app, 'add', 'Adds two numbers', nil, @MyCall) = 1 then
  *     Writeln('Registered');
  * }
var
  app: TLF_App;
  MethodName__, Desc__: TLF_String;
begin
  app := appHnd; // Cast to TLF_App.
  MethodName__ := DS(MethodName); // Decode UTF‑8.
  Desc__ := DS(Desc);
  Result := if_(app.Engine.Reg_Call(MethodName__, Desc__, Trigger, OnCall), 1, 0);
  // Reg_Call returns Boolean; convert to 1/0.
end;

function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer;
{ *
  * Registers a Notify API similarly.
  * @Param appHnd: The application handle.
  * @Param MethodName: Null‑terminated UTF‑8 API name.
  * @Param Desc: Null‑terminated UTF‑8 description.
  * @Param Trigger: User data passed to the callback.
  * @Param OnNotify: The cdecl callback function.
  * @Returns: 1 on success, 0 if the name already exists.
  * }
var
  app: TLF_App;
  MethodName__, Desc__: TLF_String;
begin
  app := appHnd;
  MethodName__ := DS(MethodName);
  Desc__ := DS(Desc);
  Result := if_(app.Engine.Reg_Notify(MethodName__, Desc__, Trigger, OnNotify), 1, 0);
end;

function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): Integer;
{ *
  * Unregisters an API by name. Immediately removes the API from
  * the local registry and triggers a network broadcast to all peers.
  * @Param appHnd: The application handle.
  * @Param MethodName: Null‑terminated UTF‑8 API name.
  * @Returns: 1 if the API was found and removed, 0 otherwise.
  * }
var
  app: TLF_App;
  MethodName__: TLF_String;
begin
  app := appHnd;
  MethodName__ := DS(MethodName);
  Result := if_(app.Engine.UnReg(MethodName__), 1, 0);
end;

function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___;
{ *
  * Executes a Call locally.
  * 1) Creates a temporary TMem64 and packs the input handle.
  * 2) Invokes app.Engine.Execute_Call (which runs the callback synchronously).
  * 3) Wraps the result in a new TDataHnd___ and returns it.
  * The temporary TMem64 is freed after use.
  * @Param appHnd: The application handle.
  * @Param Param: Input data handle.
  * @Returns: New data handle containing the result. Must be freed by caller.
  * @Example:
  *   var res := LF_LocalCall(app, paramData);
  *   if LF_GetSize(res) > 0 then ... // process result
  *   LF_FreeData(res);
  * }
var
  app: TLF_App;
  tmp: TMem64;
begin
  app := appHnd;
  tmp := TMem64.Create; // Temporary memory stream.
  PLF_Data(Param).Data_Param.EncryptToMem(tmp); // Serialise the parameter handle.
  Result := TLF_Data.New_Result_From(app.Engine.Execute_Call(tmp)); // Execute and get result as a handle.
  PLF_Data(Result)^.Data_Info := PFormat('result for app:%s api:%s', [app.Name.Text, PLF_Data(Param)^.Data_Param.MethodName.Text]);
  DisposeObject(tmp); // Free temporary stream.
end;

procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___);
{ *
  * Sends a notification locally.
  * Packs the input handle and calls app.Engine.Execute_Notify.
  * @Param appHnd: The application handle.
  * @Param Param: Input data handle.
  * @Example:
  *   LF_LocalNotify(app, notifData);
  * }
var
  app: TLF_App;
  tmp: TMem64;
begin
  app := appHnd;
  tmp := TMem64.Create;
  PLF_Data(Param).Data_Param.EncryptToMem(tmp);
  app.Engine.Execute_Notify(tmp); // Execute the notification (no result).
  DisposeObject(tmp);
end;

{ ------------------------------------------------------------------------------
  Advanced Communication Service Implementation
  ------------------------------------------------------------------------------ }

type
  { * TAppHnd_Bind_Tag: Internal record that binds a tag (ID) to an application handle and
    * address information for a service or client. This is used to match
    * prepared clients with their applications when they connect. }
  TAppHnd_Bind_Tag = record
    appHnd: TAppHnd___; // The application handle to bind.
    Tag: Integer; // Unique tag assigned during preparation.
    IsService, IsClient: boolean; // Role flags.
    Listen, Addr, Port: TLF_String; // Address details.
    procedure Init;
  end;

  { * TAppHnd_Bind_Tag_List: List of TAppHnd_Bind_Tag, used to track prepared services/clients. }
  TAppHnd_Bind_Tag_List = class(TBigList<TAppHnd_Bind_Tag>)
  public
    procedure DoFree(var Data: TAppHnd_Bind_Tag); override;
    function CompareData(const Data_1, Data_2: TAppHnd_Bind_Tag): boolean; override;
  end;

procedure TAppHnd_Bind_Tag.Init;
{ * Initialises all fields to default empty values. }
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
{ * Frees the tag record by re‑initialising it. }
begin
  Data.Init();
  inherited DoFree(Data);
end;

function TAppHnd_Bind_Tag_List.CompareData(const Data_1, Data_2: TAppHnd_Bind_Tag): boolean;
{ * Compares two tags for equality (used by the list's search functions). }
begin
  Result :=
    (Data_1.appHnd = Data_2.appHnd) and (Data_1.Tag = Data_2.Tag) and
    (Data_1.IsService = Data_2.IsService) and (Data_1.IsClient = Data_2.IsClient) and
    Data_1.Listen.Same(@Data_2.Listen) and Data_1.Addr.Same(@Data_2.Addr);
end;

{ Global variables used for preparation and startup. }
var
  Prepare_Commands: TPascalStringList = nil; // List of C4 command strings to be executed at startup.
  Tag_Seed: Integer = 0; // Incrementing seed for generating unique tags.
  AppHnd_Bind_Tag_List: TAppHnd_Bind_Tag_List = nil; // Maps tags to application handles and addresses.

procedure LF_ResetPrepare();
{ *
  * Clears prepared commands and tag mappings.
  * @Note This does not affect already running services/clients; only the queue.
  * @Example:
  *   LF_ResetPrepare;  // clear old preparations before setting new ones.
  * }
begin
  Prepare_Commands.Clear;
  AppHnd_Bind_Tag_List.Clear;
end;

{ * Temporary event bridge for C4 PhysicsService.
  * It logs service start/stop and link success events. }
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
{ * Logs service start. }
begin
  if Sender.IPC_Mode then
      DoStatus('LingoFuse Service Listening: "%s" OK, Host: "%s"', [Sender.ListeningAddr.Text, Sender.PhysicsAddr.Text])
  else
      DoStatus('LingoFuse Service Listening: "%s" OK, Host: "%s"', [Build_Host_URL(Sender.ListeningAddr, Sender.PhysicsPort), Build_Host_URL(Sender.PhysicsAddr, Sender.PhysicsPort)]);
end;

procedure TTemp_C40_PhysicsService_Bridge__.C40_PhysicsService_Stop(Sender: TC40_PhysicsService);
{ * Logs service stop. }
begin
  DoStatus('LingoFuse Service Listening: "%s" Stop', [Build_Host_URL(Sender.ListeningAddr, Sender.PhysicsPort)]);
end;

procedure TTemp_C40_PhysicsService_Bridge__.C40_PhysicsService_LinkSuccess(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
{ * Logs link success. }
var
  serv: TC40_LF_Service;
  user_io: TC40_LF_RecvTunnel;
begin
  serv := Custom_Service_ as TC40_LF_Service;
  user_io := Trigger_ as TC40_LF_RecvTunnel;
  DoStatus('LingoFuse Service Link Successed IO "%s"', [user_io.Owner.GetPeerIP]);
end;

procedure TTemp_C40_PhysicsService_Bridge__.C40_PhysicsService_UserOut(Sender: TC40_PhysicsService; Custom_Service_: TC40_Custom_Service; Trigger_: TCore_Object);
{ * Logs user disconnect. }
var
  serv: TC40_LF_Service;
  user_io: TC40_LF_RecvTunnel;
begin
  serv := Custom_Service_ as TC40_LF_Service;
  user_io := Trigger_ as TC40_LF_RecvTunnel;
  DoStatus('LingoFuse Service User-out IO "%s"', [user_io.Owner.GetPeerIP]);
end;

{ * Temporary event bridge for C4 PhysicsTunnel.
  * When a dependent client is built, it matches the client's tag to an
  * application handle and sets the client's app property, triggering
  * registration of the app's APIs. }
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
{ * When a LingoFuse client connects, this callback matches its Tag to a prepared
  * application handle and sets the client's app reference. It also logs the
  * registered APIs. }
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
            Cli.app := Queue^.Data.appHnd; // Attach the application to the client.
            if Cli.app <> nil then
              begin
                // Log the app and its registered APIs.
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
                      DoStatus('  (%s) (%s) "%s"', [tmp.Text, Queue^.Data.Data.Primary, Queue^.Data.Data.Second.Desc.Text]);
                    until not Next;
              end;
          end;
      until not Next;
end;

var
  Init_Running, Init_Successed, Simulated_Main_Thread_Running: boolean; // State flags for the simulated main thread.
  Temp_C40_PhysicsTunnel_Bridge__: TTemp_C40_PhysicsTunnel_Bridge__; // Bridge instance for tunnel events.
  Temp_C40_PhysicsService_Bridge__: TTemp_C40_PhysicsService_Bridge__; // Bridge instance for service events.
  Overlap_Connection: boolean;
  Wait_Connection_ReadyOk: boolean; // Whether LF_PrepareDone should wait for clients.
  Wait_Connection_Timeout: TTimeTick; // Timeout in milliseconds for the above wait.

procedure Do_Post_RUn_C40_Extract_CmdLine;
{ * Helper that executes C40_Extract_CmdLine on the main thread.
  * This is used when a service/client is prepared after the main thread is already running. }
begin
  C40_Extract_CmdLine(); // Parse and execute all prepared C4 commands.
end;

function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): Integer;
{ *
  * Prepares a C4 service. Builds a C4 'Service' command string and stores
  * the tag and addresses. It decodes UTF‑8 addresses, handles IPC detection,
  * and defaults port to 9898. The command is added to Prepare_Commands.
  * If the main thread is already running (Init_Successed = True), the service
  * is started immediately by injecting the command into the C4 parser.
  * @Param ListeningAddr_: Null‑terminated UTF‑8 listening address.
  * @Param PhysicsAddr_: Null‑terminated UTF‑8 advertised address.
  * @Returns: A unique tag for this service, or -1 if duplicate.
  * @Example:
  *   var tag := LF_PrepareService('0.0.0.0', '127.0.0.1:9898');
  * }
var
  Listen, Host, Port: U_String;
  Cmd_: U_String;
  running: boolean;
begin
  Listen := DS(ListeningAddr_).Text; // Decode address.
  Host := DS(PhysicsAddr_).Text;
  if Is_IPC_Addr(Host.Text) or Is_IPC_Addr(Listen.Text) then
      Port := '0' // IPC uses port 0.
  else
    begin
      Port := '9898'; // Default port.
      ExtractHostAddress(Host, Port); // Extract host and port from string.
      ExtractHostAddress(Listen, Port);
    end;
  // Duplicate detection – check if a service with this address already exists
  // either in the running system or in the preparation queue.
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
  Prepare_Commands.Add(Cmd_); // Queue the command for later execution.
  with AppHnd_Bind_Tag_List.Add_Null^ do // Store tag binding.
    begin
      Data.Init();
      Data.appHnd := nil;
      Data.Tag := Tag_Seed;
      Data.IsService := True;
      Data.Listen := Listen;
      Data.Addr := Build_Host_URL(Host, Port);
      Data.Port := Port;
    end;
  AtomInc(Tag_Seed); // Increment tag for next use.

  // If the main thread is already running, execute the command immediately.
  if Init_Successed and Simulated_Main_Thread_Running then
    begin
      SetLength(C40AppParam, 1);
      C40AppParam[0] := Cmd_;
      C40AppParsingTextStyle := TTextStyle.tsC;
      DoStatus('Run %s', [Cmd_.Text]);
      if TCompute.CurrentThread = Z.Core.Main_Thread then
        begin
          Do_Post_RUn_C40_Extract_CmdLine(); // Execute directly if already on main thread.
        end
      else
        begin
          // Post to main thread via progress tool.
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

function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): Integer;
{ *
  * Prepares a C4 client. Similar to LF_PrepareService but for clients.
  * Builds a 'KeepAlive' command and optionally binds an app handle.
  * If the main thread is already running, the client connection is initiated
  * immediately.
  * @Param PhysicsAddr_: Null‑terminated UTF‑8 address of the service to connect to.
  * @Param appHnd: Optional application handle to expose; if nil, consumer only.
  * @Returns: A unique tag for this client, or -1 if duplicate.
  * @Example:
  *   var tag := LF_PrepareClient('127.0.0.1:9898', myApp);
  * }
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

  // When Overlap_Connection is False, prevent multiple clients to the same address.
  if (not Overlap_Connection) and Init_Successed and Simulated_Main_Thread_Running then
    begin
      if Z.Net.C4.C40_PhysicsTunnelPool.ExistsPhysicsAddr(Host, EStrToInt(Port)) then
        begin
          DoStatus('error: repeat connection addr:%s port:%s', [Host.Text, Port.Text]);
          Result := -1;
          exit;
        end;
    end;

  // Also check the prepared list to avoid duplicates before startup.
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

  // Choose command based on Overlap_Connection flag.
  // When Overlap_Connection=True, use 'NewKeepAlive' to force a new tunnel.
  // When False, use 'KeepAlive' which may reuse an existing tunnel.
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

  // If the main thread is already running, execute the command immediately.
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
          // If Wait_Connection_ReadyOk is True, we wait for the client to be fully ready.
          Cli := C40_ClientPool.FindTag(Result) as TC40_LF_Client;
          if Cli <> nil then
            if Wait_Connection_ReadyOk then
              begin
                tk := GetTimeTick + Wait_Connection_Timeout;
                while GetTimeTick() < tk do
                  begin
                    // Check conditions:
                    // - Connected
                    // - If app is not nil, app must be online (LF_AppIsOnline)
                    // - Service info must be received (LF_Service_Info_Is_Onlne)
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

procedure Simulated_Main_Thread();
{ *
  * Entry point for the simulated main thread.
  * 1) Copies all prepared commands into the global C40AppParam array.
  * 2) Sets up event bridges and parses the commands via C40_Extract_CmdLine.
  * 3) If Wait_Connection_ReadyOk is True, polls until all prepared clients
  *    are connected and registered (or timeout).
  * 4) Runs the C4 progress loop until Simulated_Main_Thread_Running becomes False.
  * 5) Cleans up C4 resources on exit.
  * This is the heart of the network event loop.
  * }
var
  i: Integer;
  tk: TTimeTick;
  Cli: TC40_LF_Client;
  Prepare_Cli_Num, Online_Num: Integer;
begin
  DoStatus('LingoFuse Main Thread Begin');

  SetLength(C40AppParam, Prepare_Commands.Count);
  for i := 0 to Prepare_Commands.Count - 1 do
      C40AppParam[i] := Prepare_Commands[i]; // Copy commands.

  if Prepare_Commands.Count > 0 then
    begin
      C40AppParsingTextStyle := TTextStyle.tsC;
      On_C40_PhysicsTunnel_Event_Console := Temp_C40_PhysicsTunnel_Bridge__; // Install event bridges.

      Init_Successed := C40_Extract_CmdLine(); // Parse and execute commands.

      if Init_Successed and Wait_Connection_ReadyOk then
        begin
          // Count how many clients we expect.
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
                C40Progress(10); // Run network progress.
                Online_Num := 0;
                if AppHnd_Bind_Tag_List.Num > 0 then
                  begin
                    with AppHnd_Bind_Tag_List.Repeat_ do
                      repeat
                        if Queue^.Data.IsClient then
                          begin
                            Cli := C40_ClientPool.FindTag(Queue^.Data.Tag) as TC40_LF_Client;
                            // Check if client is connected and (if it has an app) the app is online.
                            if (Cli <> nil) and (Cli.Connected) and ((Cli.app = nil) or Cli.LF_AppIsOnline) and (Cli.LF_Service_Info_Is_Onlne) then
                                inc(Online_Num);
                          end;
                      until not Next;
                  end;
                Init_Successed := Online_Num >= Prepare_Cli_Num;
              until Init_Successed or ((Wait_Connection_Timeout > 0) and (GetTimeTick() > tk));
            end;
        end;
    end
  else
    begin
      Init_Successed := True; // No commands, framework is ready.
    end;

  Init_Running := False; // Signal that we are done initialising.

  if Init_Successed then
    while Simulated_Main_Thread_Running do
      begin
        C40Progress(if_(LF_RunningCount.V > 0, 0, 10)); // Run network progress with adaptive delay.
        try
            LF_DataPool.Progress(); // Reclaim idle data handles.
        except
        end;
      end;

  // Cleanup when main thread exits.
  try
    DoStatus('Clean Framework.');
    C40Clean(); // Shut down C4 services/clients.
    LF_Notify_Sequence_Thread_Pool.Stop; // Stop sequenced notification threads.
  except
  end;

  try
      LF_DataPool.Free_All_Hnd(); // Free all remaining data handles.
  except
  end;
  DoStatus('LingoFuse Main Thread Exit');
end;

function LF_PrepareDone: Integer;
{ *
  * Starts the simulated main thread and waits for initialisation to complete.
  * Returns 1 on success, 0 on failure.
  * @Returns: 1 if the framework started successfully, else 0.
  * @Example:
  *   if LF_PrepareDone = 1 then
  *     WriteLn('LingoFuse is ready');
  *   else
  *     WriteLn('Failed to start');
  * }
var
  tk: TTimeTick;
begin
  Result := 0;
  if Simulated_Main_Thread_Running then
      exit; // Already running.

  Open_Core_Dispatch_Thread(); // Ensure core dispatch thread is running.
  Init_Running := True;
  Init_Successed := False;
  Simulated_Main_Thread_Running := True;

  Begin_Simulator_Main_Thread(Simulated_Main_Thread); // Spawn the main thread.
  tk := GetTimeTick() + C_Tick_Second * 30;
  while Init_Running do
    begin
      Boot_Thread_Sync_Tool.Check_Synchronize(10); // Wait until initialisation completes.
      if GetTimeTick() > tk then break;
    end;
  Result := if_(Init_Successed, 1, 0);
end;

procedure LF_ExitMainThread;
{ *
  * Signals the main loop to stop and waits for the simulator thread to finish.
  * @Example:
  *   LF_ExitMainThread;  // stop the main loop
  * }
begin
  Simulated_Main_Thread_Running := False;
  while Simulator_Main_Thread_Activted do
      Boot_Thread_Sync_Tool.Check_Synchronize(10); // Wait for thread exit.
end;

var
  Find_Class_Critical: TCritical = nil; // Critical section used to protect C40 client lookups.

function LF_Call(appName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
{ *
  * Performs a synchronous remote call. It finds a connected LingoFuse client,
  * packs the input parameter into a TMem64, and calls Wait_Execute_Call on the
  * client with the given timeout. Returns a new data handle with the result,
  * or an empty handle on failure.
  * @Param appName: Null‑terminated UTF‑8 target application name.
  * @Param Param: Input data handle.
  * @Param Timeout_: Timeout in milliseconds; 0 = infinite.
  * @Returns: New data handle containing the result (must be freed).
  * @Example:
  *   var res := LF_Call('Calculator', data, 5000);
  *   if LF_GetSize(res) > 0 then ... // success
  *   LF_FreeData(res);
  * }
var
  Cli: TC40_LF_Client;
  tmp, Output: TMem64;
begin
  try
    Find_Class_Critical.Lock; // Protect search.
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
      PLF_Data(Param).Data_Param.EncryptToMem(tmp); // Serialise input.
      try
          Output := Cli.Wait_Execute_Call(DS(appName), tmp, Timeout_); // Perform remote call.
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
      Output := TMem64.Create; // Empty result on failure.
  Result := TLF_Data.New_Result_From(Output); // Wrap result in a data handle.
  PLF_Data(Result)^.Data_Info := PFormat('result for app:%s api:%s', [DS(appName).Text, PLF_Data(Param)^.Data_Param.MethodName.Text]);
end;

procedure LF_Notify(appName: pansichar; Param: TDataHnd___);
{ *
  * Sends a non‑sequenced notification. Finds a connected client, packs the
  * input, and calls Send_Execute_Notify. Returns immediately.
  * @Param appName: Null‑terminated UTF‑8 target application name.
  * @Param Param: Input data handle (not freed by this function).
  * @Example:
  *   LF_Notify('Logger', notifData);
  * }
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
      Cli.Send_Execute_Notify(DS(appName), tmp); // Send asynchronously.
  except
      DoStatus('LF_Notify(%s, ...) except', [DS(appName).Text]);
  end;
  DisposeObject(tmp);
end;

procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___);
{ *
  * Sends a sequenced notification. Similar to LF_Notify but uses
  * Send_Sequenced_Notify to guarantee FIFO order for the same (app, api) pair.
  * @Param appName: Null‑terminated UTF‑8 target application name.
  * @Param Param: Input data handle.
  * @Example:
  *   LF_Sequenced_Notify('Logger', eventData); // ordered delivery
  * }
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
      Cli.Send_Sequenced_Notify(DS(appName), tmp); // Queue for ordered delivery.
  except
      DoStatus('LF_Sequenced_Notify(%s, ...) except', [DS(appName).Text]);
  end;
  DisposeObject(tmp);
end;

function LF_CheckMainThread(): Integer;
{ *
  * Returns 1 if the simulated main thread is active.
  * @Returns: 1 if active, 0 otherwise.
  * @Example:
  *   if LF_CheckMainThread = 1 then
  *     // main thread is running
  * }
begin
  Result := if_(Simulator_Main_Thread_Activted, 1, 0);
end;

function LF_CheckApp(appName: pansichar): Integer;
{ *
  * Checks if the given application name is available locally or remotely.
  * @Param appName: Null‑terminated UTF‑8 application name.
  * @Returns: 1 if at least one instance is found, 0 otherwise.
  * @Example:
  *   if LF_CheckApp('MyService') = 1 then
  *     // MyService is available
  * }
begin
  Result := if_((Find_Local_APP(DS(appName), False) <> nil) or (Find_Remote_APP(DS(appName), False) <> nil), 1, 0);
end;

function LF_CheckApi(appName, apiName: pansichar): Integer;
begin
  Result := if_((Find_Local_Api(DS(appName), DS(apiName), False) <> nil) or
      (Find_Remote_Api(DS(appName), DS(apiName), False) <> nil), 1, 0);
end;

procedure LF_SetOption(Option, Value: pansichar);
{ *
  * Sets runtime options. See interface documentation for supported keys.
  * @Param Option: Configuration key.
  * @Param Value: New value.
  * @Note Unknown options are silently ignored.
  * @Example:
  *   LF_SetOption('Quiet', 'True');
  *   LF_SetOption('Fixed_Sequenced_Time', '300000'); // 5 minutes
  * }
var
  opt, V, tmp: TLF_String;
  L: Integer;
  i: Integer;
begin
  opt := DS(Option);
  V := DS(Value);

  if opt.Same('password', 'passwd') then
    begin
      Z.Net.C4.C40_Password := V; // Set C4 password.
      // Mask password for logging.
      tmp := ''; // Initialize temp string for building the mask.
      for i := 0 to V.L - 1 do
          tmp.Append(if_(TMT19937.Rand32 mod 2 = 0, '*', '**'));
      DoStatus('Update Password = %s', [tmp.Text]);
    end
  else if opt.Same('Quiet') then
    begin
      C40SetQuietMode(EStrToBool(V.Text)); // Enable/disable quiet mode.
      DoStatus('Quiet = %s', [umlBoolToStr(EStrToBool(V.Text)).Text]);
    end

  else if opt.Same('Overlap_Connection', 'Overlap_Client', 'OverlapConnection', 'OverlapClient', 'OverlapConnect') then
    begin
      Overlap_Connection := EStrToBool(V.Text);
      DoStatus('Overlap Connection = %s', [umlBoolToStr(Overlap_Connection).Text]);
    end

  else if opt.Same('Wait_Connection_ReadyOk', 'Wait_API_Prepare_Done', 'API_Prepare_Done_Wait', 'WaitConnect', 'Wait_Ready', 'WaitReady') then
    begin
      Wait_Connection_ReadyOk := EStrToBool(V.Text); // Set whether to wait for clients.
      DoStatus('Wait Connection ReadyOk = %s', [umlBoolToStr(Wait_Connection_ReadyOk).Text]);
    end
  else if opt.Same('Wait_Connection_Timeout', 'Wait_TimeOut', 'API_Prepare_Done_TimeOut', 'WaitTimeOut') then
    begin
      Wait_Connection_Timeout := EStrToUInt64(V.Text); // Set timeout in ms.
      DoStatus('Wait Connection TimeOut = %s', [umlTimeTickToStr(Wait_Connection_Timeout).Text]);
    end
  else if opt.Same('ShowThreadID', 'ShowThread', 'Show_Thread') then
    begin
      Z.status.StatusThreadID := EStrToBool(V.Text); // Show thread IDs in logs.
      DoStatus('Status Thread ID = %s', [umlBoolToStr(Z.status.StatusThreadID).Text]);
    end
  else if opt.Same('ConsoleOutput', 'Console_Output') then
    begin
      Z.status.ConsoleOutput := EStrToBool(V.Text); // Enable/disable console logging.
      DoStatus('Console Output = %s', [umlBoolToStr(Z.status.ConsoleOutput).Text]);
    end
  else if opt.Same('IPC_Serv_ThreadCount', 'IPC_ThreadCount', 'IPC_Server_ThreadCount') then
    begin
      TZNet_Server_IPC.IPC_Serv_ThreadCount := EStrToInt(V.Text); // IPC server thread pool size.
      DoStatus('Interprocess Communication Server Thread Count = %s', [umlIntToStr(TZNet_Server_IPC.IPC_Serv_ThreadCount).Text]);
    end
  else if opt.Same('IPC_Serv_MaxQueueLength', 'IPC_MaxQueueLength', 'IPC_Server_MaxQueueLength') then
    begin
      TZNet_Server_IPC.IPC_Serv_MaxQueueLength := EStrToInt(V.Text); // IPC queue length.
      DoStatus('Interprocess Communication Server Max Queue Length = %s', [umlIntToStr(TZNet_Server_IPC.IPC_Serv_MaxQueueLength).Text]);
    end
  else if opt.Same('IPC_Serv_MaxMsgSize', 'IPC_MaxMsgSize', 'IPC_Server_MaxMsgSize') then
    begin
      TZNet_Server_IPC.IPC_Serv_MaxMsgSize := EStrToInt(V.Text); // Max IPC message size.
      DoStatus('Interprocess Communication Server Max Msg Size = %s', [umlIntToStr(TZNet_Server_IPC.IPC_Serv_MaxMsgSize).Text]);
    end
  else if opt.Same('Fixed_Sequenced_Time', 'Fixed_Sequenced_Life') then
    begin
      Fixed_Sequenced_Time := EStrToUInt64(V.Text); // Set sequenced notification fallback threshold.
      DoStatus('Fixed_Sequenced_Time = %s', [V.Text]);
    end;
end;

{ ------------------------------------------------------------------------------
  Status Buffer Implementation
  ------------------------------------------------------------------------------ }

type
  { * Internal FIFO queue for storing log messages as UTF‑8 byte arrays. }
  TStatus_Buffer = class(TOrderStruct<TBytes>)
  public
    procedure DoFree(var Data: TBytes); override;
  end;

var
  Status_Pool: TStatus_Buffer = nil; // Queue of status messages.
  Status_Critical__: TCritical = nil; // Lock protecting the queue.
  Status_Buff: array [0 .. $FFFF] of byte; // Static 64‑KB buffer for returning a message.

procedure TStatus_Buffer.DoFree(var Data: TBytes);
{ * Frees the byte array when a queue item is removed. }
begin
  SetLength(Data, 0);
  inherited DoFree(Data);
end;

procedure backcall_DoStatus(Text_: SystemString; const ID: Integer);
{ *
  * Hook called by the global DoStatus system.
  * It locks the status pool, discards old messages if the queue exceeds 1000,
  * and pushes the new message as UTF‑8 bytes.
  * @Param Text_: The message as a SystemString.
  * @Param ID: Unused, but required by the hook signature.
  * }
begin
  Status_Critical__.Lock;
  try
    while Status_Pool.Num > 1000 do
        Status_Pool.Next; // Discard oldest to maintain limit.
    Status_Pool.Push(TPascalString(Text_).UTF8); // Store as UTF‑8 bytes.
  finally
      Status_Critical__.UnLock;
  end;
end;

function LF_GetStatusCount(): Integer;
{ *
  * Returns the number of queued messages.
  * Thread‑safe via Status_Critical__ lock.
  * @Returns: Number of messages currently in the queue.
  * }
begin
  Status_Critical__.Lock;
  try
      Result := Status_Pool.Num;
  finally
      Status_Critical__.UnLock;
  end;
end;

function LF_GetStatus(): pansichar;
{ *
  * Retrieves the oldest message from the queue.
  * The message is copied into a static 64‑KB buffer (Status_Buff) and null‑terminated.
  * If the message is longer than 64KB-1, it is truncated.
  * The pointer is valid until the next call to LF_GetStatus.
  * After copying, the message is removed from the queue.
  * @Returns: PAnsiChar pointing to the static buffer (do not free).
  * @Example:
  *   var msg := LF_GetStatus;
  *   if msg^ <> #0 then
  *     WriteLn(UTF8Decode(msg)); // copy before next call.
  * }
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
            Status_Buff[Min(L, SizeOf(Status_Buff) - 1)] := 0; // Null‑terminate.
          end;
        Status_Pool.Next; // Remove from queue.
      end;
  finally
      Status_Critical__.UnLock;
  end;
end;

procedure LF_PostStatus(status: pansichar);
{ *
  * Injects a user‑supplied message into the status system.
  * @Param status: Null‑terminated UTF‑8 message.
  * @Example:
  *   LF_PostStatus('My custom log message');
  * }
begin
  if not Simulator_Main_Thread_Activted then
    begin
      // If main thread not running, directly queue via DoStatus.
      DoStatus('LF_PostStatus: Main thread not running; message queued directly. message: %s', [DS(status).Text]);
      exit;
    end;
  Status_Critical__.Lock;
  try
      Post_To_DoStatus_Queue(TCompute.CurrentThread, DS(status), 0); // Queue to status system.
  finally
      Status_Critical__.UnLock;
  end;
end;

procedure LF_Shutdown;
{ *
  * Gracefully shuts down the entire LingoFuse framework.
  * Stops the sequenced notification threads, frees all data handles,
  * exits the main thread, unloads the IPC library, and closes the C4 dispatch.
  * @Example:
  *   LF_Shutdown;  // cleanup before program exit.
  * }
begin
  try
    LF_Notify_Sequence_Thread_Pool.Stop; // Stop all sequenced notify threads.
    LF_DataPool.Free_All_Hnd(); // Free all remaining data handles.
  except
  end;
  LF_ExitMainThread(); // Stop the main loop.
  LF_App_Pool.Clear; // free all app
  UnloadIPCLibrary(); // Unload IPC support.
  Close_Core_Dispatch_Thread(); // Close dispatch thread.
end;

initialization

{ * Initialize global data structures. }
Generate_AppName_Call_Num := 0;
Generate_AppName_Critical := TCritical.Create;
Prepare_Commands := TPascalStringList.Create;
Tag_Seed := 1;
AppHnd_Bind_Tag_List := TAppHnd_Bind_Tag_List.Create;
Init_Running := True;
Init_Successed := False;
Simulated_Main_Thread_Running := False;
Temp_C40_PhysicsTunnel_Bridge__ := TTemp_C40_PhysicsTunnel_Bridge__.Create;
On_C40_PhysicsTunnel_Event_Console := Temp_C40_PhysicsTunnel_Bridge__;
Temp_C40_PhysicsService_Bridge__ := TTemp_C40_PhysicsService_Bridge__.Create;
On_C40_PhysicsService_Event_Console := Temp_C40_PhysicsService_Bridge__;
Overlap_Connection := False;
Wait_Connection_ReadyOk := True;
Wait_Connection_Timeout := 30 * 1000; // 30 seconds default.
if IsLibrary then
  begin
    // In a library, quiet mode and console output are set for safety.
    Z.status.StatusThreadID := False;
    Z.status.ConsoleOutput := True;
    Z.Net.C4.C40SetQuietMode(True);
  end;
C40_EnablePerServiceDirectory := False; // Disable per‑service directory.

Find_Class_Critical := TCritical.Create('Find_Class_Critical');

Status_Pool := TStatus_Buffer.Create;
Status_Critical__ := TCritical.Create('Status_Critical__');
AddDoStatusHookC(Status_Pool, backcall_DoStatus); // Install status hook.

finalization

On_C40_PhysicsTunnel_Event_Console := nil;
On_C40_PhysicsService_Event_Console := nil;
DisposeObjectAndNil(Prepare_Commands);
DisposeObjectAndNil(AppHnd_Bind_Tag_List);
DisposeObjectAndNil(Temp_C40_PhysicsTunnel_Bridge__);
DisposeObjectAndNil(Temp_C40_PhysicsService_Bridge__);
DisposeObjectAndNil(Find_Class_Critical);
RemoveDoStatusHook(Status_Pool);
DisposeObjectAndNil(Status_Pool);
DisposeObjectAndNil(Status_Critical__);
DisposeObjectAndNil(Generate_AppName_Critical);

end.
