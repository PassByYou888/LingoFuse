{$Region 'lingofuse_import_head'}
(*
 * =============================================================================
 * lingofuse_import - Pascal Import Unit for the LingoFuse RPC Library
 * =============================================================================
 *
 * This unit is the official Pascal binding for the LingoFuse dynamic library
 * (LingoFuse64.dll / liblingofuse.so / liblingofuse.dylib). It imports all
 * C-ABI exported functions and provides a type-safe, object-oriented wrapper
 * that makes LingoFuse accessible from Delphi and Free Pascal.
 *
 * LingoFuse is a language-neutral, multi-threaded RPC framework that allows
 * applications to expose APIs (Call and Notify modes) and invoke them locally
 * or remotely over a network (using the C4 service mesh). This import unit is
 * the entry point for Pascal developers to use LingoFuse, and it also serves
 * as a comprehensive documentation resource that explains the entire system.
 *
 * =============================================================================
 * 1. CORE CONCEPTS
 * =============================================================================
 *
 *   - Data Handle (TDataHnd)
 *       An opaque pointer to a binary buffer that holds serialised parameters
 *       for an API call or notification. The buffer can be read/written using
 *       LF_Read*/LF_Write* functions. Handles are reference-counted by the
 *       library and automatically recycled when idle for more than 10 minutes.
 *       However, you should still free them explicitly with LF_FreeData to
 *       release resources promptly.
 *
 *   - Application Handle (TAppHnd)
 *       A logical container for a set of related APIs. Each application has a
 *       unique name (case-insensitive for matching) used for network routing.
 *       APIs are registered inside an application. The handle is created with
 *       LF_CreateApp and destroyed with LF_FreeApp.
 *
 *   - API Modes
 *       * Call   : Request-response. The caller provides input parameters and
 *                  expects a result (synchronous). The callback receives both
 *                  Input and Output handles.
 *       * Notify : One-way. The caller sends a notification and does not wait
 *                  for a response (asynchronous). The callback receives only
 *                  an Input handle.
 *
 *   - Local vs Remote Execution
 *       * Local calls (LF_LocalCall/LF_LocalNotify) execute immediately within
 *         the same process, bypassing the network entirely. They are useful for
 *         testing and for inter-module communication within the same process.
 *       * Remote calls (LF_Call/LF_Notify/LF_Sequenced_Notify) send requests
 *         over the network. They first attempt to find a local instance of the
 *         target application (same process) to avoid network overhead; if none
 *         is found, they forward the request to the service mesh.
 *
 *   - Sequenced Notify
 *       A special type of notification that guarantees FIFO ordering for the
 *       same (application, API) pair. This is implemented using dedicated
 *       threads inside the library, one per (app, api) key. It is essential
 *       for scenarios where message order must be preserved. The underlying
 *       transport is optimised for large payloads by streaming data in chunks,
 *       so you can safely send big messages without worrying about memory
 *       exhaustion or fragmentation.
 *
 * =============================================================================
 * 2. THREAD SAFETY MODEL
 * =============================================================================
 *
 *   {!!!!!  IMPORTANT  !!!!!}
 *   All functions exported by this unit are **fully thread-safe**. You may call
 *   them from any thread concurrently without external locking. The library
 *   internally protects its global state with critical sections.
 *
 *   However, for a given data handle (TDataHnd), concurrent writes must be
 *   serialised by the caller; concurrent reads are safe because the buffer
 *   operations are atomic with respect to position updates (they use internal
 *   locks). If you need to write from multiple threads to the same handle, you
 *   must use your own synchronisation.
 *
 *   Callbacks (TLF_Call_M and TLF_Notify_M) are invoked on the thread that the
 *   library uses to process network events (the "simulated main thread") unless
 *   you use the Sync variants (RegisterSyncCall_M / RegisterSyncNotify_M),
 *   which execute on the main thread (the thread that called LF_PrepareDone).
 *   If you register a normal (non-sync) callback, it will be executed on a
 *   background thread - ensure your method is thread-safe.
 *
 *   {!!!!!  CRITICAL - CALLBACK BLOCKING  !!!!!}
 *   Inside a callback (Call or Notify), you MUST NOT call any blocking
 *   LingoFuse function such as LF_Call, LF_LocalCall, or LF_PrepareDone.
 *   Doing so will cause a deadlock because the callback is executed on a
 *   library thread that may be holding internal locks. If you need to perform
 *   heavy work or make remote calls, offload the task to a separate thread
 *   using TThread.CreateAnonymousThread or TTask.Run.
 *
 * =============================================================================
 * 3. TYPICAL USAGE WORKFLOW
 * =============================================================================
 *
 *   a) Create an application handle:
 *        App := LF_CreateApp('MyApp', 'My description');
 *
 *   b) Register APIs (use object methods):
 *        LF_RegisterCall_M(App, 'echo', 'Echo', MyEchoMethod);
 *        LF_RegisterNotify_M(App, 'log', 'Logging', MyLogMethod);
 *
 *   c) Prepare network services/clients (if remote access is needed):
 *        LF_ResetPrepare; // clear any previous preparations
 *        LF_PrepareService('0.0.0.0', '127.0.0.1:9898'); // listen
 *        LF_PrepareClient('127.0.0.1:9898', App); // connect & expose App
 *
 *   d) Start the network (blocks until ready):
 *        if LF_PrepareDone = 1 then
 *          WriteLn('Ready');
 *
 *   e) Make local or remote calls:
 *        Data := LF_CreateData('echo');
 *        LF_WriteString(Data, 'Hello');
 *        Result := LF_LocalCall(App, Data);       // local
 *        // or remote:
 *        Result := LF_Call('RemoteApp', Data, 5000); // timeout 5s
 *
 *   f) Clean up:
 *        LF_FreeData(Data);
 *        LF_FreeData(Result);
 *        LF_FreeApp(App);
 *        LF_Shutdown;
 *
 * =============================================================================
 * 4. IMPORTANT NOTES AND COMMON PITFALLS
 * =============================================================================
 *
 *   {!!!!!  DATA HANDLE LIFETIME  !!!!!}
 *   - Always free data handles with LF_FreeData when you are done with them.
 *     Although the library has an automatic idle-timeout reclaimer
 *     (10 minutes), relying on it can lead to resource leaks under heavy
 *     load or in long-running applications. The reclaimer runs on the
 *     simulated main thread, so it is safe but not immediate.
 *   - Do not free a handle while it is being used in a callback or while a
 *     remote call is pending. Ensure that the handle is no longer referenced
 *     before freeing.
 *
 *   {!!!!!  CALLBACK REGISTRATION  !!!!!}
 *   - API names are case-insensitive when matching, but they are stored exactly
 *     as provided. Use consistent naming to avoid confusion.
 *   - If you register an API with the same name twice, the second registration
 *     will fail (returns 0). Always check the return value.
 *   - The Trigger pointer passed to LF_RegisterCall/Notify is stored and passed
 *     back to your callback. It can be used to pass context, but be careful with
 *     object lifetimes if the callback is invoked after the object is destroyed.
 *
 *   {!!!!!  SYNC VS NON-SYNC  !!!!!}
 *   - Use RegisterSync* variants only if your callback accesses UI components
 *     or non-thread-safe objects (e.g., VCL components). Otherwise, use the
 *     non-sync variants for better performance and lower latency.
 *   - The sync variants introduce a queue and a context switch, so they are
 *     slower. They are safe but not suitable for high-throughput APIs.
 *
 *   {!!!!!  REMOTE CALL TIMEOUT  !!!!!}
 *   - LF_Call accepts a timeout in milliseconds. A timeout of 0 means infinite
 *     wait. If the call times out, an empty result handle is returned (size 0).
 *     Always check the result size with LF_GetSize to detect timeouts.
 *   - A timeout may also occur if the network is slow or the remote application
 *     is not responding. The library does not automatically retry.
 *
 *   {!!!!!  SEQUENCED NOTIFY  !!!!!}
 *   - Use LF_Sequenced_Notify when order matters. It guarantees FIFO delivery
 *     per (app, api). It is slightly slower than ordinary notifications because
 *     it serialises processing through a dedicated thread.
 *   - The underlying thread pool has a 5-minute idle timeout; if no sequenced
 *     notifications are sent for a while, the thread terminates and is re-created
 *     when needed.
 *   - Large payloads are handled efficiently: the library streams data in
 *     chunks using the same memory-efficient I/O pipeline as normal calls,
 *     so you can transmit big binary blobs without copying or excessive
 *     allocations.
 *
 *   {!!!!!  STATUS QUEUE  !!!!!}
 *   - LF_GetStatus returns a pointer to a static buffer. The data is valid only
 *     until the next call to LF_GetStatus (or any other function that may modify
 *     the buffer). You must copy the string immediately if you need to keep it.
 *   - The status queue holds up to 1000 messages; older messages are discarded
 *     when the limit is reached.
 *   - IMPORTANT: LF_GetStatus and LF_PostStatus rely on the simulated main
 *     thread to process the status queue. If the main thread has not been
 *     started (i.e., LF_PrepareDone has not been called), these functions
 *     will have limited or no effect. You should only rely on them after
 *     the framework is fully initialised.
 *
 *   {!!!!!  PREPARATION AND STARTUP - REPEATED USAGE  !!!!!}
 *   - LF_PrepareService and LF_PrepareClient can be called at any time,
 *     even after the main thread has started (i.e., after LF_PrepareDone).
 *     In that case, they will immediately create and activate the service
 *     or client, rather than just queuing them for later. This allows
 *     dynamic addition of endpoints at runtime.
 *   - LF_PrepareDone, LF_ExitMainThread, and LF_Shutdown are not one-shot.
 *     You can call LF_PrepareDone again after a shutdown to restart the
 *     framework. This is useful for re-initialisation or for testing.
 *     However, you must ensure all resources are properly freed before
 *     restarting.
 *
 *   {!!!!!  OVERLAP_CONNECTION BEHAVIOR  !!!!!}
 *   - The `Overlap_Connection` option (set via LF_SetOption) controls whether
 *     multiple client tunnels to the same remote address are allowed.
 *   - When `Overlap_Connection = False` (default), only one client tunnel is
 *     created per address. Subsequent calls to LF_PrepareClient with a
 *     **different** `appHnd` will **silently ignore** the new application
 *     handle - the existing tunnel is reused, and the new `appHnd` is never
 *     bound. This can lead to confusing behaviour if you expect multiple
 *     applications to be hosted on the same remote service.
 *   - When `Overlap_Connection = True`, each call to LF_PrepareClient creates
 *     a **new independent tunnel**, and the provided `appHnd` is bound to the
 *     newly created client. This allows multiple applications to be exposed
 *     on the same remote service.
 *   - **Recommendation**: If you intend to host multiple applications on the
 *     same remote service, set `Overlap_Connection = True` **before** calling
 *     LF_PrepareClient. If you need to change the application on an existing
 *     client, use LF_BindApp.
 *
 *   {!!!!!  GENERATE_APP_NAME AND BINDAPP PATTERNS  !!!!!}
 *   - LF_Generate_AppName() returns a name that includes the current process
 *     name, PID, timestamp, and **active C4 tunnel addresses and remote IDs**.
 *     Therefore, it **must be called after LF_PrepareDone()** has successfully
 *     completed and the simulated main thread is running. If called before,
 *     the returned name will lack tunnel information and may not be globally
 *     unique.
 *   - The returned PAnsiChar pointer is valid for only **5 seconds**; you must
 *     copy its content immediately (e.g., using StrCopy/StrNew or by assigning
 *     to a Pascal string) - otherwise the library will free the memory and
 *     your pointer will become invalid.
 *   - LF_BindApp attaches an application to any client that currently has no
 *     application attached (i.e., where `Cli.app = nil`). The number of such
 *     clients depends on how many distinct addresses were used in
 *     LF_PrepareClient calls. If all clients are already occupied, BindApp
 *     returns 0.
 *   - To dynamically create a new client that will host a newly generated
 *     application name (for point-to-point communication), you can either:
 *       a) Set `Overlap_Connection = True` and call LF_PrepareClient with the
 *          same physical address and the new App handle - this creates a
 *          separate tunnel and binds the app immediately.
 *       b) If `Overlap_Connection = False` and the address already has a
 *          client, you must prepare a **different** physical address (e.g.,
 *          a different IPC name or TCP port) to create a new client.
 *     The typical pattern for a dynamic client (as used in LLM streaming) is:
 *       1. LF_ResetPrepare
 *       2. LF_PrepareClient(endpoint, nil)   // consumer only, no app
 *       3. LF_PrepareDone                    // wait for connection
 *       4. appName := LF_Generate_AppName    // generate unique name AFTER connection
 *       5. App := LF_CreateApp(appName)      // create App with that name
 *       6. Register Notify callbacks on App
 *       7. LF_BindApp(App)                   // bind to the existing client
 *     This ensures the App is attached to the already-established tunnel.
 *
 *   {!!!!!  CHECK FUNCTIONS CACHE BEHAVIOR  !!!!!}
 *   - LF_CheckApp and LF_CheckApi perform lookups based on a **local cache**
 *     that is updated via network broadcasts. These broadcasts propagate with
 *     a typical delay of about **3 seconds**. Consequently, these functions
 *     may return false negatives immediately after an application/API is
 *     registered, or false positives shortly after it is unregistered.
 *   - They are intended for **probing** availability and should not be used
 *     as authoritative existence tests for critical decisions. In deployment
 *     scenarios where immediate availability is required, consider retrying
 *     the call with a short delay, or implementing client-side caching.
 *   - For applications that require strict synchronisation, use the actual
 *     `LF_Call` and handle timeout/empty result gracefully.
 *
 *   {!!!!!  DEPLOYMENT MODE (Wait_Connection_ReadyOk)  !!!!!}
 *   - Setting `Wait_Connection_ReadyOk = False` (via LF_SetOption) tells the
 *     library that LF_PrepareDone should **not** block waiting for all clients
 *     to be fully connected and registered. This enables "deployment mode",
 *     where services and clients can start in any order, and the framework
 *     becomes ready as soon as the internal event loop is running.
 *   - This is useful for elastic clusters where startup order is unpredictable.
 *     However, if you make a remote call before the target application is
 *     registered, you will receive an empty result (size 0) or a timeout.
 *     It is recommended to combine this with retry logic or use LF_CheckApp
 *     with a backoff strategy.
 *   - The default is `True` (wait for readiness), which guarantees that after
 *     LF_PrepareDone returns 1, all prepared clients are online. This is safer
 *     but slower for dynamic deployments.
 *
 *   {!!!!!  RESOURCE CLEANUP ORDER  !!!!!}
 *   - The correct shutdown sequence to avoid resource leaks and crashes is:
 *       1. LF_ExitMainThread   // stop the network event loop
 *       2. LF_FreeApp(app)     // detach and stop sequenced threads (app stays in pool)
 *       3. LF_Shutdown         // destroy all remaining objects, free the pool
 *     Alternatively, calling LF_Shutdown alone will perform steps 1 and 3
 *     internally, but apps are not individually freed (they are all destroyed
 *     in the final cleanup). For explicit control, free apps before shutdown.
 *   - In a dynamic library (DLL), you **must** call LF_Shutdown explicitly
 *     before unloading the library, otherwise resources will leak and the
 *     process may crash. In a standalone executable, the finalization section
 *     of this unit automatically calls LF_Shutdown.
 *
 *   {!!!!!  INITIALIZATION / FINALIZATION  !!!!!}
 *   - The unit automatically initialises its internal structures when the unit
 *     is loaded. In an executable (not a library), the finalization section
 *     calls LF_Shutdown automatically to clean up resources.
 *   - In a dynamic library (DLL), the shutdown is NOT automatic because the
 *     library may be unloaded by the host process before finalization. You MUST
 *     call LF_Shutdown explicitly before unloading your library to avoid
 *     resource leaks and crashes.
 *
 * =============================================================================
 * 5. INTERNAL IMPLEMENTATION HIGHLIGHTS
 * =============================================================================
 *
 *   This unit implements a callback adapter that allows Pascal object methods
 *   (of object) to be used as cdecl callbacks required by the underlying
 *   library. It stores the method pointers (TMethod) in a pool (LF_EventPool)
 *   and uses a small trampoline procedure (Do_Internal_Call__ etc.) that
 *   retrieves the method and calls it.
 *
 *   For sync variants, it wraps the call in a procedure that is queued via
 *   TSoft_Synchronize_Tool. This tool is a user-space synchronisation
 *   mechanism that uses a FIFO queue and a busy-wait loop to marshal procedures
 *   to the main thread. It is similar to TThread.Synchronize but implemented
 *   entirely in Pascal without OS kernel calls, making it faster for
 *   high-frequency synchronisation.
 *
 *   The key internal data structures are:
 *     - LF_EventPool: a TOrderStruct<TMethod> that stores the TMethod of each
 *       registered method. The index (pointer to the TMethod) is used as the
 *       'Trigger' pointer when registering with the library.
 *     - LF_SyncTool: an instance of TSoft_Synchronize_Tool that handles the
 *       queuing and execution of sync callbacks on the main thread.
 *     - The trampolines (Do_Internal_Call__, Do_Internal_Sync_Call__, etc.)
 *       are simple cdecl procedures that retrieve the TMethod from the Trigger
 *       pointer and invoke the method. For sync variants, they queue the call.
 *
 *   TSoft_Synchronize_Tool works as follows:
 *     - The main thread (the one that calls LF_PrepareDone) is recorded as
 *       Soft_Synchronize_Main_Thread.
 *     - When Synchronize is called from a different thread, it creates a
 *       TPair2 containing the procedure and a boolean flag, pushes it onto
 *       a FIFO queue, and then busy-waits until the flag becomes False.
 *     - The main thread periodically calls Check_Synchronize (via the library's
 *       progress loop), which dequeues all pending procedures and executes them,
 *       then sets the flag to False, releasing the waiting threads.
 *
 *   This design avoids the overhead of kernel events and provides a fast,
 *   user-space synchronisation mechanism.
 *
 * =============================================================================
 * 6. COMMON PITFALLS FOR JSON DATA EXCHANGE (especially when using HTTP bridges)
 * =============================================================================
 *
 *   When your Pascal service communicates with other languages (e.g., Python,
 *   JavaScript, or via HTTP bridges like bridge.py), JSON is the most common
 *   data format. However, several subtle issues can arise due to differences
 *   in string handling and null terminators. Below are the most frequent traps
 *   and how to avoid them.
 *
 *   6.1 The Null Terminator (`#0`) Problem
 *   ---------------------------------------
 *   The LingoFuse core API uses C-style strings internally. Functions like
 *   `LF_ReadString` and `LF_WriteString` treat a byte `#0` (null) as the
 *   string terminator. This is fine when both ends are Pascal, but when you
 *   receive data from a foreign language (e.g., Python `requests` library or
 *   a web browser), the JSON string **does not** include a trailing null.
 *
 *   - **Reading**: `LF_ReadString` scans for a null byte; if none is found
 *     before the end of the buffer, it will read up to the buffer size
 *     (the implementation is fault-tolerant and returns the entire buffer
 *     content). However, older versions of this unit may not have this
 *     fallback - always ensure your code handles both cases.
 *
 *   - **Writing**: `LF_WriteString` **always** appends a null terminator.
 *     If you send this string to a non-Pascal client, that extra null may
 *     be misinterpreted (e.g., in JSON parsing). Many HTTP bridges, such as
 *     `bridge.py`, automatically strip the trailing null before forwarding
 *     the response to HTTP clients, so this is usually harmless. However,
 *     if you are writing custom binary protocols, be aware of the extra byte.
 *
 *   **Recommendation**:
 *   - When reading from an **Input** handle that comes from a foreign caller,
 *     use `LF_ReadString` - it will handle both terminated and non-terminated
 *     data gracefully (fault-tolerant mode).
 *   - When writing **Output** for a foreign caller, you can either:
 *       a) Use `LF_WriteString` (which adds `#0`) - but make sure your bridge
 *          or client can handle it (e.g., bridge.py strips it).
 *       b) Use `LF_WriteBuffer` with an explicit length to avoid the terminator
 *          entirely - this gives you full control.
 *   - For maximum compatibility, **always send valid JSON** (no extra bytes)
 *     and let the bridge strip the trailing null if present.
 *
 *   6.2 JSON Encoding and Decoding
 *   ------------------------------
 *   - JSON strings must be UTF-8 encoded. `LF_WriteString` expects a Pascal
 *     `string` and will convert it to UTF-8 automatically. On the receiving
 *     side, `LF_ReadString` returns a Pascal `string` decoded from UTF-8.
 *   - When constructing JSON manually, ensure all special characters (like
 *     quotes, backslashes, and control characters) are properly escaped.
 *   - Use a robust JSON library like `Z.Json` (included in the Z-framework)
 *     to avoid manual string concatenation errors.
 *
 *   6.3 Handling Errors and Timeouts
 *   --------------------------------
 *   - When a remote call fails (timeout, application not found, etc.),
 *     `LF_Call` returns an empty data handle (`TDataHnd` with `GetSize = 0`).
 *     Do not assume the handle is nil - always check `LF_GetSize(Result) = 0`.
 *   - In your callback, **always** write a valid JSON response, even in error
 *     cases. For example:
 *       `LF_WriteString(Output, '{"code":-1,"error":"Division by zero"}')`
 *   - This ensures the HTTP client or bridge receives a well-formed JSON
 *     object and can parse it without crashing.
 *
 *   6.4 Path and API Naming
 *   -----------------------
 *   - The HTTP bridge (bridge.py) routes requests based on the URL path:
 *         `/app_name/api_name`
 *   - Ensure your application name (`LF_CreateAppEx`) and API name
 *     (`LF_RegisterCallEx`) match the path used by your clients. Case-
 *     insensitive matching is supported, but it's good practice to use
 *     lowercase names consistently.
 *   - Do not use special characters in app/api names that are not URL-safe.
 *
 *   6.5 Example: Safe JSON Handling in a Callback
 *   ---------------------------------------------
 *   ```pascal
 *   procedure MyApiCallback(Trigger: Pointer; Input, Output: TDataHnd); cdecl;
 *   var
 *     jsonStr: string;
 *     jo: TZ_JsonObject;
 *     argsArr: TZ_JsonArray;
 *     expr: string;
 *     resultVal: string;
 *     resObj: TZ_JsonObject;
 *   begin
 *     // Read input (fault-tolerant, handles both terminated and non-terminated)
 *     jsonStr := LF_ReadString(Input);
 *     if jsonStr = '' then
 *     begin
 *       LF_WriteString(Output, '{"code":-1,"error":"Empty request"}');
 *       Exit;
 *     end;
 *
 *     jo := TZ_JsonObject.Create;
 *     try
 *       if not jo.ParseText(jsonStr) then
 *       begin
 *         LF_WriteString(Output, '{"code":-1,"error":"Invalid JSON"}');
 *         Exit;
 *       end;
 *       // ... extract arguments ...
 *       // ... compute result ...
 *       resObj := TZ_JsonObject.Create;
 *       try
 *         resObj.I['code'] := 0;
 *         resObj.S['result'] := resultVal;
 *         // Write JSON with trailing null (bridge.py will strip it)
 *         LF_WriteString(Output, resObj.ToJSONString(False));
 *       finally
 *         resObj.Free;
 *       end;
 *     finally
 *       jo.Free;
 *     end;
 *   end;
 *   ```
 *
 *   6.6 Debugging Tips
 *   ------------------
 *   - Enable debug mode on your HTTP bridge (`--debug`) to see the raw request
 *     and response bodies.
 *   - In your Pascal callback, you can use `LF_GetSize(Input)` and
 *     `LF_GetBuffer(Input)` to inspect the raw bytes if needed.
 *   - Use `LF_GetStatus` to retrieve internal LingoFuse log messages that may
 *     indicate network or registration issues.
 *
 *   6.7 Overlap_Connection and PrepareClient Behavior
 *   ------------------------------------------------
 *   The `Overlap_Connection` option (set via `LF_SetOption('Overlap_Connection', 'True/False')`)
 *   controls how `LF_PrepareClient` handles multiple calls to the same remote address.
 *
 *   - When `Overlap_Connection = False` (the default), only one client tunnel is
 *     created per address. Subsequent calls to `LF_PrepareClient` with a
 *     **different** `appHnd` will **silently ignore** the new application handle.
 *     The existing tunnel is reused, and the new `appHnd` is never bound.
 *     This can lead to confusing behaviour if you expect multiple applications
 *     to be hosted on the same remote service.
 *
 *   - When `Overlap_Connection = True`, each call to `LF_PrepareClient` creates
 *     a **new independent tunnel**, and the provided `appHnd` is bound to the
 *     newly created client. This allows multiple applications to be exposed
 *     on the same remote service, each with its own dedicated connection.
 *
 *   **Recommendation**: If you intend to host multiple applications on the same
 *   remote service, set `Overlap_Connection = True` **before** calling
 *   `LF_PrepareClient`. If you need to change the application on an existing
 *   client, use `LF_BindApp`.
 *
 * By following these guidelines, you can avoid the most common pitfalls when
 * integrating Pascal LingoFuse services with JSON-based HTTP clients and bridges.
 *
 * =============================================================================
 * 7. EXAMPLES (PASCAL)
 * =============================================================================
 *
 *   // Example 1: Registering a call API with an object method
 *   type
 *     TMyService = class
 *       procedure Echo(Input, Output: TDataHnd);
 *     end;
 *
 *   procedure TMyService.Echo(Input, Output: TDataHnd);
 *   var
 *     S: string;
 *   begin
 *     S := LF_ReadString(Input);  // read input
 *     LF_WriteString(Output, S);  // write back output
 *   end;
 *
 *   var
 *     App: TAppHnd;
 *     Service: TMyService;
 *   begin
 *     App := LF_CreateApp('MyApp', 'Echo Service');
 *     Service := TMyService.Create;
 *     if LF_RegisterCall_M(App, 'echo', 'Echo', Service.Echo) = 1 then
 *       WriteLn('Registered OK');
 *   end;
 *
 *   // Example 2: Remote call with timeout handling
 *   var
 *     Data, Result: TDataHnd;
 *   begin
 *     Data := LF_CreateData('add');
 *     LF_WriteInt32(Data, 5);
 *     LF_WriteInt32(Data, 7);
 *     Result := LF_Call('Calculator', Data, 3000); // 3s timeout
 *     if LF_GetSize(Result) > 0 then
 *       WriteLn('Result: ', LF_ReadInt32(Result))
 *     else
 *       WriteLn('Timeout or error');
 *     LF_FreeData(Data);
 *     LF_FreeData(Result);
 *   end;
 *
 *   // Example 3: Sending a sequenced notification with large data
 *   var
 *     Data: TDataHnd;
 *     BigData: array[0..1023] of Byte;
 *   begin
 *     Data := LF_CreateData('event');
 *     LF_WriteBuffer(Data, @BigData, SizeOf(BigData)); // large payload
 *     LF_Sequenced_Notify('Logger', Data);  // order is guaranteed
 *     LF_FreeData(Data);
 *   end;
 *
 * =============================================================================
 * 8. DEPENDENCIES
 * =============================================================================
 *
 *   The library itself (LingoFuse64.dll / liblingofuse.so) must be available
 *   in the system library path or in the same directory as the executable.
 *   This unit uses dynamic linking (external 'name') and does not require
 *   static linking.
 *
 *   The unit uses SysUtils, Classes, and SyncObjs (for TCriticalSection).
 *
 * =============================================================================
 * 9. VERSION & COMPATIBILITY
 * =============================================================================
 *
 *   This interface is compatible with LingoFuse version 1.0 and later.
 *   It supports Delphi (2009+) and Free Pascal (3.0+) on Windows, Linux,
 *   and macOS, both 32-bit and 64-bit.
 *
 * =============================================================================
 * 10. EXTENDED NOTES FOR AI AND ADVANCED USERS
 * =============================================================================
 *
 *   - The library is designed as a microservices foundation: each application
 *     (TAppHnd) can be registered on multiple clients, and remote calls are
 *     load-balanced across them. The local-first optimisation ensures that
 *     calls within the same process are extremely fast.
 *   - The sequenced notification system uses a hash map keyed by "appName.apiName"
 *     to a dedicated thread. This allows fine-grained ordering without blocking
 *     unrelated APIs.
 *   - The status buffer (LF_GetStatus) is useful for logging and debugging. It
 *     captures all internal log messages. You can inject your own messages with
 *     LF_PostStatus to unify logs.
 *   - The library does not persist configuration; all options set via LF_SetOption
 *     are lost after LF_Shutdown. If you need persistence, store the options
 *     externally.
 *   - For maximum performance, avoid using sync callbacks in high-volume APIs;
 *     instead, use the non-sync variants and handle thread safety in your
 *     callbacks.
 *   - When using remote calls, the library automatically tries local execution
 *     first. This means that even if you call LF_Call with a remote name, if a
 *     local application with that name exists, the call will be executed locally
 *     without network overhead. This is important to understand for debugging
 *     and performance tuning.
 *   - The library's simulated main thread is a user-space thread that runs the
 *     C4 progress loop. It is started by LF_PrepareDone and runs until
 *     LF_ExitMainThread or LF_Shutdown. It is responsible for network I/O,
 *     timer processing, and automatic handle reclamation.
 *
 * =============================================================================
 * 11. ADDITIONAL CRITICAL NOTES FOR PRODUCTION USAGE
 * =============================================================================
 *
 *   {!!!!!  GENERATE_APP_NAME - TIMING IS CRITICAL  !!!!!}
 *   - LF_Generate_AppName builds its unique string from active C4 tunnel
 *     addresses, remote IDs, process name (with PID), and a timestamp.
 *     Therefore, the network must be fully operational before calling it.
 *     Always call LF_Generate_AppName **after** LF_PrepareDone has returned 1.
 *     If called before, the generated name will lack tunnel info and may not
 *     be unique, causing routing failures.
 *   - The returned pointer is automatically freed by the library after 5 seconds.
 *     You must copy the content immediately (e.g., assign to a Pascal string,
 *     or use StrCopy/StrNew) - otherwise later accesses will read freed memory.
 *   - In dynamic client scenarios (e.g., LLM streaming clients), the correct
 *     order is:
 *       1. Prepare network with LF_PrepareClient(endpoint, nil)
 *       2. Call LF_PrepareDone and wait for success
 *       3. Call LF_Generate_AppName to obtain a unique name
 *       4. Create the App with that name, register callbacks
 *       5. Bind the App with LF_BindApp (or prepare a new client with that App)
 *     This guarantees the name includes all network identities.
 *
 *   {!!!!!  BINDAPP AND CLIENT CAPACITY  !!!!!}
 *   - LF_BindApp attaches an App to all currently **unbound** clients.
 *     Unbound means the client has no App attached (Cli.app = nil).
 *     Each client can host only one App at a time.
 *   - The number of unbound clients depends on how many LF_PrepareClient calls
 *     were made with distinct addresses (or with Overlap_Connection=True).
 *     If you prepared only one client, BindApp will bind to that client (if free),
 *     or return 0 if it is already occupied.
 *   - To support multiple Apps on the same physical address, you must set
 *     Overlap_Connection=True before calling LF_PrepareClient. Each call to
 *     LF_PrepareClient with a different App will create a new tunnel and bind
 *     that App immediately (without needing LF_BindApp). Alternatively, you can
 *     prepare clients with different addresses (e.g., different IPC names) and
 *     then use BindApp to attach Apps later.
 *   - If BindApp returns 0 because all clients are occupied, you have two
 *     options:
 *       a) Set Overlap_Connection=True and call LF_PrepareClient again with the
 *          new App - this creates a new client tunnel.
 *       b) Prepare additional clients with different addresses before calling
 *          BindApp.
 *
 *   {!!!!!  WAIT_CONNECTION_READYOK AND STARTUP ORDER  !!!!!}
 *   - When Wait_Connection_ReadyOk = True (default), LF_PrepareDone blocks
 *     until all prepared clients are connected and their Apps are online.
 *     This guarantees that after PrepareDone, all clients are ready.
 *   - When Wait_Connection_ReadyOk = False (deployment mode), PrepareDone
 *     returns as soon as the event loop starts, even if some clients are not
 *     yet connected. This allows services and nodes to start in any order.
 *     However, you must implement retry logic when calling remote APIs, as the
 *     target may not be registered yet. Use LF_CheckApp or LF_CheckApi with a
 *     backoff strategy to avoid immediate failures.
 *   - The timeout for waiting is controlled by Wait_Connection_Timeout (default
 *     30 seconds). If the timeout expires, PrepareDone still returns success (1)
 *     but some clients may remain offline. Check LF_GetStatus for warnings.
 *
 *   {!!!!!  CHECKAPP / CHECKAPI CACHE DELAY  !!!!!}
 *   - These functions query a local cache that is updated via network broadcasts.
 *     Broadcast propagation typically takes up to 3 seconds. As a result, they
 *     may not reflect the latest state immediately after registration or
 *     unregistration.
 *   - Do not use them as the sole condition for critical operations. Instead,
 *     call the API directly and handle timeouts or empty results gracefully.
 *     For better reliability, combine CheckApp/CheckApi with retry loops and
 *     short delays.
 *
 *   {!!!!!  CALLBACK DEADLOCK PREVENTION  !!!!!}
 *   - The rule "never call LF_Call or LF_Notify from within a callback" is
 *     absolute. Doing so will deadlock because the callback thread may already
 *     hold internal locks that are needed by the new call.
 *   - If your callback must perform a remote call, offload the work to a
 *     separate thread (e.g., using TThread.CreateAnonymousThread) and return
 *     immediately. The callback should only read the input, enqueue the request,
 *     and possibly write a temporary response (like a job ID) to the output.
 *   - For notify callbacks (which have no output), you can simply enqueue the
 *     data and return; the actual processing happens later.
 *
 *   {!!!!!  AUTOMATIC DATA HANDLE RECLAMATION  !!!!!}
 *   - The library maintains a global pool of data handles and automatically
 *     frees any handle that has been idle for more than 10 minutes. This is a
 *     safety net to prevent leaks when developers forget to call LF_FreeData.
 *   - However, the reclaimer runs on the simulated main thread; if the main
 *     thread is not running (e.g., before LF_PrepareDone or after LF_ExitMainThread),
 *     the reclaimer does not operate. In high-throughput applications, relying
 *     on automatic reclamation can cause memory bloat because handles may
 *     accumulate faster than they are reclaimed.
 *   - **Best practice**: always call LF_FreeData explicitly as soon as a handle
 *     is no longer needed. Do not depend on the automatic reclaimer for
 *     production performance.
 *
 *   {!!!!!  LF_FREEAPP AND LF_SHUTDOWN LIFETIME  !!!!!}
 *   - LF_FreeApp detaches the application from all clients and stops its
 *     sequenced notification threads, but the underlying TLF_App object is
 *     **not destroyed immediately**. It remains in the global LF_App_Pool
 *     until LF_Shutdown is called. This ensures that any pending network
 *     broadcasts that reference the app data can complete safely.
 *   - If you need to reclaim the app's memory before shutdown, you must call
 *     LF_Shutdown (which clears the entire pool). In practice, for long-running
 *     servers that dynamically create and destroy many Apps, you may need to
 *     carefully design your application to call LF_Shutdown periodically, or
 *     reuse app names, because the pool will keep objects alive until shutdown.
 *   - In a normal workflow, you can simply call LF_Shutdown at the end of your
 *     program, and it will free all remaining Apps, regardless of whether
 *     LF_FreeApp was called for each.
 *
 * =============================================================================
 * END OF DOCUMENTATION HEADER
 * =============================================================================
 *)
{$EndRegion 'lingofuse_import_head'}

unit lingofuse_import;

{$ifdef FPC}
  {$mode delphi}{$H+}
  {$MODESWITCH AdvancedRecords}
  {$MODESWITCH NestedProcVars}
  {$MODESWITCH NESTEDCOMMENTS}
  {$CODEPAGE UTF8}
{$endif}

{$R-}
{$I-}
{$H+}

interface

uses SysUtils, Classes;

type
  (*
   * TDataHnd___: Opaque handle to a LingoFuse data buffer.
   *
   * Never dereference this pointer; always use the provided functions.
   * This handle is created by LF_CreateData (auto-recycled after 10 minutes
   * of idle) or LF_CreateData_Permanent (never auto-recycled), and must be
   * freed with LF_FreeData.
   *
   * [PITFALL] LF_FreeData is a no-op while the simulated main thread is not
   *   active (before LF_PrepareDone or after LF_ExitMainThread). This is by
   *   design - it avoids double-free during library initialisation/finalisation.
   *)
  TDataHnd___ = Pointer;

  (*
   * TDataHnd: Alias for TDataHnd___ for convenience.
   *)
  TDataHnd = TDataHnd___;

  (*
   * TAppHnd___: Opaque handle to a LingoFuse application instance.
   *
   * Created by LF_CreateApp and detached with LF_FreeApp. The underlying
   * TLF_App object is NOT immediately destroyed by LF_FreeApp; it remains
   * alive in the global LF_App_Pool until LF_Shutdown.
   *)
  TAppHnd___ = Pointer;

  (*
   * TAppHnd: Alias for TAppHnd___.
   *)
  TAppHnd = TAppHnd___;

  (*
   * TLF_Call_Event: Raw cdecl callback for Call-mode APIs.
   *
   * This is used only when you register a plain procedure (not a method)
   * with LF_RegisterCall. For object methods, use TLF_Call_M.
   *
   * [PITFALL] MUST be declared cdecl. The default Pascal convention
   *   (register / fastcall) will corrupt the stack when invoked from the
   *   C ABI layer.
   *
   * [PITFALL] Runs on a worker thread. See the unit header for the full
   *   contract of what is forbidden inside a callback.
   *
   * @param Trigger : The user-supplied pointer passed during registration.
   * @param Input   : TDataHnd containing the input parameters (read).
   * @param Output  : TDataHnd to be filled with the result (write).
   *)
  TLF_Call_Event = procedure(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;

  (*
   * TLF_Call_M: Object method callback for Call-mode APIs.
   *
   * This is the preferred way to register APIs from Pascal code. The method
   * will be called on a background thread (unless the Sync variant is used).
   *
   * [PITFALL] Runs on a worker thread; do not touch UI controls directly.
   * [PITFALL] Never call blocking LingoFuse functions (LF_Call, LF_LocalCall,
   *   LF_PrepareDone, LF_Shutdown) inside this method - it will deadlock.
   *
   * @param Input   : Input parameters (read).
   * @param Output  : Result data (write).
   *)
  TLF_Call_M = procedure(Input: TDataHnd___; Output: TDataHnd___) of object;

  (*
   * TLF_Notify_Event: Raw cdecl callback for Notify-mode APIs.
   *
   * [PITFALL] MUST be cdecl (see TLF_Call_Event for the rationale).
   * [PITFALL] Runs on a worker thread. Do not touch UI, do not call
   *   blocking LF_* functions, do not assume the caller thread.
   *
   * @param Trigger : The user-supplied pointer passed during registration.
   * @param Input   : TDataHnd containing the notification payload (read).
   *                  No output is produced.
   *)
  TLF_Notify_Event = procedure(Trigger: Pointer; Input: TDataHnd___); cdecl;

  (*
   * TLF_Notify_M: Object method callback for Notify-mode APIs.
   *
   * This is the preferred way to register Notify APIs from Pascal code.
   *
   * [PITFALL] Runs on a worker thread; do not touch UI controls directly.
   * [PITFALL] Never call blocking LingoFuse functions inside this method.
   *
   * @param Input   : Notification payload (read).
   *)
  TLF_Notify_M = procedure(Input: TDataHnd___) of object;

  (* ---- Dynamic Library Name Resolution ---- *)

{$IFDEF MSWINDOWS}
const
  (*
   * liblingofuse: Name of the LingoFuse dynamic library on Windows.
   * - 64-bit: LingoFuse64.dll
   * - 32-bit: LingoFuse32.dll
   *)
  {$IF Defined(CPU64) or Defined(CPUX64)}
  liblingofuse = 'LingoFuse64.dll';
  {$ELSE}
  liblingofuse = 'LingoFuse32.dll';
  {$ENDIF}
{$ELSE}
{$IFDEF DARWIN}
const
  (*
   * liblingofuse: Name of the LingoFuse dynamic library on macOS.
   *)
  liblingofuse = 'liblingofuse.dylib';
{$ELSE}
const
  (*
   * liblingofuse: Name of the LingoFuse dynamic library on Linux/Unix.
   *)
  liblingofuse = 'liblingofuse.so';
{$ENDIF}
{$ENDIF}

  (* ---- Core Data Operations ---- *)

  (*
   * LF_CreateData: Creates a new data handle for the given API name.
   * The handle must be freed with LF_FreeData.
   *
   * [PITFALL] The returned handle is tracked by an idle pool that reclaims
   *   untouched handles after 10 minutes. Refresh it periodically (any
   *   accessor call resets the idle timer) if you need it to survive longer,
   *   or use LF_CreateData_Permanent to opt out of automatic recycling.
   *
   * @param MethodName  Null-terminated UTF-8 string naming the target API.
   * @return A new TDataHnd (never nil).
   *)
  function LF_CreateData(MethodName: pansichar): TDataHnd___; cdecl; external liblingofuse name 'LF_CreateData';

  (*
   * LF_CreateDataEx: Convenience wrapper for LF_CreateData that accepts a
   * Pascal string (automatically UTF-8 encoded).
   *
   * @param MethodName  Pascal string API name.
   * @return A new TDataHnd (never nil).
   *)
  function LF_CreateDataEx(MethodName: string): TDataHnd___;

  (*
   * LF_CreateData_Permanent: Creates a new data handle initialised with
   * the given API name, but NOT registered in the internal data pool.
   * The internal buffer is empty (size = 0).
   *
   * Semantics:
   *   - The handle is created with auto_recycle___ = False.
   *   - It is NOT added to LF_DataPool, so TLF_DataPool.Progress (the
   *     idle scanner that runs every 5 seconds on the main thread) will
   *     NEVER reclaim it, regardless of how long it stays untouched.
   *   - LF_FreeData releases the record IMMEDIATELY (synchronously),
   *     rather than merely marking it as deleted for a later pool scan.
   *
   * When to use:
   *   - Handles that must survive for the entire lifetime of the process
   *     or for an unbounded period (cached request templates, long-lived
   *     scratch buffers, entries in a global registry, etc.).
   *
   * When NOT to use:
   *   - Short-lived or one-shot handles. For those, use LF_CreateData so
   *     the pool can reclaim any handle you forget to free.
   *
   * @param MethodName  Null-terminated UTF-8 string naming the target API.
   * @return A new TDataHnd___ (never nil). Must be freed with LF_FreeData.
   *
   * [PITFALL - LIFETIME] "Permanent" means "not automatically reclaimed",
   *   NOT "never released". You are fully responsible for calling
   *   LF_FreeData. There is no pool safety net: losing the pointer
   *   leaks the handle for the lifetime of the process.
   *
   * [PITFALL - SYNCHRONOUS FREE] When LF_FreeData is called on a permanent
   *   handle, the release happens inside that call. Do not touch the
   *   handle after LF_FreeData returns.
   *
   * [PITFALL - NO-OP WINDOW] LF_FreeData is still a no-op while the
   *   simulated main thread is not active (before LF_PrepareDone or
   *   after LF_ExitMainThread). Permanent handles created in that
   *   window stay allocated until the process terminates.
   *
   * [PITFALL - TIMESTAMPS IRRELEVANT] Every accessor (LF_GetSize,
   *   LF_GetPos, LF_ReadBuffer, LF_WriteBuffer, ...) still updates the
   *   handle's internal updated___ flag, but the pool scanner never
   *   reads it for permanent handles.
   *
   * @Example (C):
   *   static TDataHnd___ g_template = NULL;
   *
   *   void init_template(void) {
   *       g_template = LF_CreateData_Permanent("myapi");
   *       int hdr = 0x12345678;
   *       LF_WriteBuffer(g_template, &hdr, sizeof(hdr));
   *   }
   *
   *   void shutdown_template(void) {
   *       LF_FreeData(g_template);   // released immediately
   *       g_template = NULL;
   *   }
   *
   * @Example (Pascal):
   *   var
   *     Template: TDataHnd___;
   *   begin
   *     Template := LF_CreateData_Permanent('myapi');
   *     try
   *       // use Template across many calls / long lifetimes
   *     finally
   *       LF_FreeData(Template);
   *     end;
   *   end;
   *)
  function LF_CreateData_Permanent(MethodName: pansichar): TDataHnd___; cdecl; external liblingofuse name 'LF_CreateData_Permanent';

  (*
   * LF_CreateData_PermanentEx: Convenience wrapper for LF_CreateData_Permanent
   * that accepts a Pascal string (automatically UTF-8 encoded).
   *
   * @param MethodName  Pascal string API name.
   * @return A new TDataHnd___ (never nil). Must be freed with LF_FreeData.
   *)
  function LF_CreateData_PermanentEx(MethodName: string): TDataHnd___;

  (*
   * LF_FreeData: Destroys a data handle and releases associated memory.
   *
   * @param Hnd  The handle to free (can be nil).
   *
   * [PITFALL] Only actually frees the handle when the simulated main
   *   thread is active. Before LF_PrepareDone or after LF_ExitMainThread,
   *   the call is a no-op.
   *
   * [PITFALL] For auto-recycled handles (created with LF_CreateData),
   *   this only marks the handle as deleted; the actual release happens
   *   on the next TLF_DataPool.Progress scan (at most 5 seconds later).
   *   For permanent handles, the release is synchronous.
   *)
  procedure LF_FreeData(Hnd: TDataHnd___); cdecl; external liblingofuse name 'LF_FreeData';

  (*
   * LF_GetBuffer: Returns a pointer to the raw data buffer.
   * The pointer is valid until the handle is freed or resized.
   *
   * @param Hnd  The data handle.
   * @return Pointer to internal memory, or nil if handle is empty.
   *
   * [PITFALL] The pointer becomes invalid as soon as the buffer is resized
   *   (e.g. by LF_WriteBuffer or LF_SetSize).
   * [PITFALL] This call refreshes the handle's idle timestamp, protecting
   *   it from the 10-minute auto-recycle.
   *)
  function LF_GetBuffer(Hnd: TDataHnd___): Pointer; cdecl; external liblingofuse name 'LF_GetBuffer';

  (*
   * LF_GetBufferOffset: Returns a pointer to a position inside the buffer.
   *
   * @param Hnd     The data handle.
   * @param Offset  Byte offset from the start.
   * @return Pointer at Hnd + Offset, or nil if handle is nil.
   *)
  function LF_GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer;

  (*
   * LF_WriteBuffer: Writes data to the handle's buffer at the current
   * position. The position advances by the number of bytes written. The
   * buffer is automatically enlarged if needed.
   *
   * @param Hnd   The data handle.
   * @param Buff  Source data pointer.
   * @param Size  Number of bytes to write.
   * @return Number of bytes written (normally equals Size).
   *
   * [PITFALL] Refreshes the handle's idle timestamp.
   *)
  function LF_WriteBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl; external liblingofuse name 'LF_WriteBuffer';

  (*
   * LF_ReadBuffer: Reads data from the handle's buffer at the current
   * position. The position advances by the number of bytes actually read.
   *
   * @param Hnd   The data handle.
   * @param Buff  Destination buffer pointer.
   * @param Size  Maximum number of bytes to read.
   * @return Number of bytes actually read (may be less than Size at EOF).
   *
   * [PITFALL] Refreshes the handle's idle timestamp.
   *)
  function LF_ReadBuffer(Hnd: TDataHnd___; Buff: Pointer; Size: int64): int64; cdecl; external liblingofuse name 'LF_ReadBuffer';

{ ---- Convenience Write Helpers ---- }

(*
 * LF_WriteInt8: Writes an 8-bit signed integer at the current position.
 * @return True if exactly SizeOf(int8) bytes were written.
 *)
function LF_WriteInt8(Hnd: TDataHnd___; Value: int8): boolean;

(*
 * LF_WriteUInt8: Writes an 8-bit unsigned integer at the current position.
 * @return True if exactly SizeOf(uint8) bytes were written.
 *)
function LF_WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean;

(*
 * LF_WriteInt16: Writes a 16-bit signed integer (little-endian).
 * @return True if exactly SizeOf(int16) bytes were written.
 *)
function LF_WriteInt16(Hnd: TDataHnd___; Value: int16): boolean;

(*
 * LF_WriteUInt16: Writes a 16-bit unsigned integer (little-endian).
 * @return True if exactly SizeOf(uint16) bytes were written.
 *)
function LF_WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean;

(*
 * LF_WriteInt32: Writes a 32-bit signed integer (little-endian).
 * @return True if exactly SizeOf(int32) bytes were written.
 *)
function LF_WriteInt32(Hnd: TDataHnd___; Value: int32): boolean;

(*
 * LF_WriteUInt32: Writes a 32-bit unsigned integer (little-endian).
 * @return True if exactly SizeOf(uint32) bytes were written.
 *)
function LF_WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean;

(*
 * LF_WriteInt64: Writes a 64-bit signed integer (little-endian).
 * @return True if exactly SizeOf(int64) bytes were written.
 *)
function LF_WriteInt64(Hnd: TDataHnd___; Value: int64): boolean;

(*
 * LF_WriteUInt64: Writes a 64-bit unsigned integer (little-endian).
 * @return True if exactly SizeOf(uint64) bytes were written.
 *)
function LF_WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean;

(*
 * LF_WriteSingle: Writes a 32-bit IEEE 754 single-precision float.
 * @return True if exactly SizeOf(single) bytes were written.
 *)
function LF_WriteSingle(Hnd: TDataHnd___; Value: single): boolean;

(*
 * LF_WriteDouble: Writes a 64-bit IEEE 754 double-precision float.
 * @return True if exactly SizeOf(double) bytes were written.
 *)
function LF_WriteDouble(Hnd: TDataHnd___; Value: double): boolean;

(*
 * LF_WriteString: Writes a null-terminated UTF-8 string to the buffer.
 * The string is written as raw UTF-8 bytes followed by a zero terminator.
 *
 * @param Hnd    The data handle.
 * @param Value  Pascal string (will be UTF-8 encoded).
 * @return True if all bytes plus the null terminator were written.
 *
 * [PITFALL] An empty string still writes a single #0 byte.
 * [PITFALL] The trailing #0 may need to be stripped by non-Pascal receivers
 *   (e.g. HTTP bridges / JSON parsers).
 *)
function LF_WriteString(Hnd: TDataHnd___; const Value: string): boolean;

(*
 * LF_WriteStringBytes: Writes a raw UTF-8 byte array followed by a null
 * terminator. Useful when the caller already has UTF-8 bytes.
 *
 * @param Hnd    The data handle.
 * @param Value  Raw UTF-8 bytes (without terminator).
 * @return True if all bytes plus the null terminator were written.
 *)
function LF_WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean;

{ ---- Convenience Read Helpers (with out parameters) ---- }

(*
 * LF_ReadInt8: Reads an 8-bit signed integer into Value.
 * @return True if exactly SizeOf(int8) bytes were read.
 *)
function LF_ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean; overload;

(*
 * LF_ReadUInt8: Reads an 8-bit unsigned integer into Value.
 * @return True if exactly SizeOf(uint8) bytes were read.
 *)
function LF_ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean; overload;

(*
 * LF_ReadInt16: Reads a 16-bit signed integer (little-endian) into Value.
 * @return True if exactly SizeOf(int16) bytes were read.
 *)
function LF_ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean; overload;

(*
 * LF_ReadUInt16: Reads a 16-bit unsigned integer (little-endian) into Value.
 * @return True if exactly SizeOf(uint16) bytes were read.
 *)
function LF_ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean; overload;

(*
 * LF_ReadInt32: Reads a 32-bit signed integer (little-endian) into Value.
 * @return True if exactly SizeOf(int32) bytes were read.
 *)
function LF_ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean; overload;

(*
 * LF_ReadUInt32: Reads a 32-bit unsigned integer (little-endian) into Value.
 * @return True if exactly SizeOf(uint32) bytes were read.
 *)
function LF_ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean; overload;

(*
 * LF_ReadInt64: Reads a 64-bit signed integer (little-endian) into Value.
 * @return True if exactly SizeOf(int64) bytes were read.
 *)
function LF_ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean; overload;

(*
 * LF_ReadUInt64: Reads a 64-bit unsigned integer (little-endian) into Value.
 * @return True if exactly SizeOf(uint64) bytes were read.
 *)
function LF_ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean; overload;

(*
 * LF_ReadSingle: Reads a 32-bit IEEE 754 single-precision float into Value.
 * @return True if exactly SizeOf(single) bytes were read.
 *)
function LF_ReadSingle(Hnd: TDataHnd___; out Value: single): boolean; overload;

(*
 * LF_ReadDouble: Reads a 64-bit IEEE 754 double-precision float into Value.
 * @return True if exactly SizeOf(double) bytes were read.
 *)
function LF_ReadDouble(Hnd: TDataHnd___; out Value: double): boolean; overload;

{ ---- Convenience Read Helpers (return value) ---- }

(*
 * LF_ReadInt8: Reads an 8-bit signed integer and returns it.
 * Returns 0 on failure (buffer too short / handle invalid).
 *)
function LF_ReadInt8(Hnd: TDataHnd___): int8; overload;

(*
 * LF_ReadUInt8: Reads an 8-bit unsigned integer and returns it.
 * Returns 0 on failure.
 *)
function LF_ReadUInt8(Hnd: TDataHnd___): uint8; overload;

(*
 * LF_ReadInt16: Reads a 16-bit signed integer and returns it.
 * Returns 0 on failure.
 *)
function LF_ReadInt16(Hnd: TDataHnd___): int16; overload;

(*
 * LF_ReadUInt16: Reads a 16-bit unsigned integer and returns it.
 * Returns 0 on failure.
 *)
function LF_ReadUInt16(Hnd: TDataHnd___): uint16; overload;

(*
 * LF_ReadInt32: Reads a 32-bit signed integer and returns it.
 * Returns 0 on failure.
 *)
function LF_ReadInt32(Hnd: TDataHnd___): int32; overload;

(*
 * LF_ReadUInt32: Reads a 32-bit unsigned integer and returns it.
 * Returns 0 on failure.
 *)
function LF_ReadUInt32(Hnd: TDataHnd___): uint32; overload;

(*
 * LF_ReadInt64: Reads a 64-bit signed integer and returns it.
 * Returns 0 on failure.
 *)
function LF_ReadInt64(Hnd: TDataHnd___): int64; overload;

(*
 * LF_ReadUInt64: Reads a 64-bit unsigned integer and returns it.
 * Returns 0 on failure.
 *)
function LF_ReadUInt64(Hnd: TDataHnd___): uint64; overload;

(*
 * LF_ReadSingle: Reads a 32-bit IEEE 754 single-precision float.
 * Returns 0.0 on failure.
 *)
function LF_ReadSingle(Hnd: TDataHnd___): single; overload;

(*
 * LF_ReadDouble: Reads a 64-bit IEEE 754 double-precision float.
 * Returns 0.0 on failure.
 *)
function LF_ReadDouble(Hnd: TDataHnd___): double; overload;

{ ---- String Reading ---- }

(*
 * LF_ReadStringBytes: Reads raw UTF-8 bytes up to the next null terminator.
 *
 * The current position is advanced past the null terminator. If no null
 * terminator is found before the end of the buffer, the remaining bytes
 * are read (fault-tolerant mode). In that case, the position is set to
 * the end of the buffer.
 *
 * @param Hnd   The data handle.
 * @param Buff  Output byte array (raw UTF-8, without terminator).
 * @return True if at least one byte was read or the string was empty but
 *         a terminator was found.
 *)
function LF_ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean; overload;

(*
 * LF_ReadStringBytes: Reads raw UTF-8 bytes and returns them directly.
 * Returns an empty array on failure.
 *)
function LF_ReadStringBytes(Hnd: TDataHnd___): TBytes; overload;

(*
 * LF_ReadString: Reads a null-terminated UTF-8 string from the current
 * position and decodes it to a Pascal string.
 *
 * The current position is advanced past the null terminator. If no null
 * terminator is found before the end of the buffer, the remaining bytes
 * are decoded (fault-tolerant mode). This means the caller should ensure
 * the producer writes a null terminator (as LF_WriteString does) if the
 * buffer may contain additional data after the string.
 *
 * @param Hnd    The data handle.
 * @param Value  Output string (UTF-8 decoded).
 * @return True if a string was read.
 *)
function LF_ReadString(Hnd: TDataHnd___; out Value: string): boolean; overload;

(*
 * LF_ReadString: Reads a null-terminated UTF-8 string and returns it.
 * Returns an empty string on failure.
 *)
function LF_ReadString(Hnd: TDataHnd___): string; overload;

{ ---- Position/Size Operations ---- }

(*
 * LF_GetPos: Returns the current read/write position (zero-based).
 *
 * [PITFALL] Refreshes the handle's idle timestamp.
 *)
function LF_GetPos(Hnd: TDataHnd___): int64; cdecl; external liblingofuse name 'LF_GetPos';

(*
 * LF_SetPos: Sets the current read/write position. If the new position
 * is beyond the current size, the buffer is extended with zero bytes.
 *
 * [PITFALL] Setting a huge position may allocate a large buffer.
 * [PITFALL] Refreshes the handle's idle timestamp.
 *)
procedure LF_SetPos(Hnd: TDataHnd___; Pos_: int64); cdecl; external liblingofuse name 'LF_SetPos';

(*
 * LF_GetSize: Returns the total size (in bytes) of the data stored in
 * the handle.
 *
 * [PITFALL] Refreshes the handle's idle timestamp.
 *)
function LF_GetSize(Hnd: TDataHnd___): int64; cdecl; external liblingofuse name 'LF_GetSize';

(*
 * LF_SetSize: Resizes the internal buffer to the specified size.
 * If larger, the added space is uninitialised; if smaller, data beyond
 * the new size is discarded.
 *
 * [PITFALL] Newly added space is UNINITIALISED. Do not read from it
 *   without first writing to it.
 * [PITFALL] Refreshes the handle's idle timestamp.
 *)
procedure LF_SetSize(Hnd: TDataHnd___; Size_: int64); cdecl; external liblingofuse name 'LF_SetSize';

{ ---- Application Management ---- }

(*
 * LF_CreateApp: Creates a new application context with the given name
 * and description.
 *
 * [PITFALL] An empty Desc is replaced by "No Description".
 *
 * @param appName  Unique application identifier (UTF-8, case-insensitive
 *                 on the wire).
 * @param Desc     Human-readable description (UTF-8, may be empty).
 * @return A new TAppHnd (never nil).
 *)
function LF_CreateApp(appName, Desc: pansichar): TAppHnd___; cdecl; external liblingofuse name 'LF_CreateApp';

(*
 * LF_CreateAppEx: Convenience wrapper for LF_CreateApp accepting Pascal
 * strings (automatically UTF-8 encoded).
 *)
function LF_CreateAppEx(appName, Desc: string): TAppHnd___;

(*
 * LF_FreeApp: Detaches an application from all clients and stops its
 * sequenced notification threads, but does NOT immediately destroy the
 * underlying TLF_App object. The object remains alive in the global
 * LF_App_Pool until LF_Shutdown is called, which then frees it forcibly.
 *
 * This two-phase destruction prevents dangling pointers while allowing
 * other components (e.g. network broadcasts) to continue referencing the
 * application data safely. After calling LF_FreeApp, the handle should be
 * considered invalid and not used for further registrations or calls.
 *
 * @param appHnd  The application handle to detach (can be nil).
 * @see LF_Shutdown  for final cleanup.
 *)
procedure LF_FreeApp(appHnd: TAppHnd___); cdecl; external liblingofuse name 'LF_FreeApp';

(*
 * LF_Generate_AppName: Generates a globally unique application name string.
 * The name is built by concatenating:
 *   - All active C4 physics tunnel addresses and remote IDs,
 *   - The current process name (with PID),
 *   - A high-resolution timestamp.
 * This ensures that each call produces a distinct identifier, suitable for
 * point-to-point communication where each node must have a unique identity.
 *
 * [PITFALL - CRITICAL] The returned pointer is valid for only ~5 seconds;
 *   the library automatically frees the underlying memory after that time.
 *   The caller MUST copy the content immediately (e.g. via StrCopy / StrNew
 *   or by assigning to a Pascal string) before the pointer becomes invalid.
 *   Failure to do so will result in accessing freed memory.
 *
 * @return PAnsiChar pointing to a null-terminated UTF-8 string.
 *
 * @Example:
 *   var uniqueName: string;
 *   var p: PAnsiChar;
 *   p := LF_Generate_AppName;
 *   uniqueName := string(p);  // immediately copy to Pascal string
 *   // use uniqueName safely...
 *)
function LF_Generate_AppName(): pansichar; cdecl; external liblingofuse name 'LF_Generate_AppName';

(*
 * LF_Generate_AppNameEx: Convenience wrapper for LF_Generate_AppName that
 * copies the returned string into a Pascal string before the underlying
 * buffer is freed. This is the recommended variant for Pascal callers.
 *
 * @return A unique Pascal string. Empty if the underlying call returned nil.
 *)
function LF_Generate_AppNameEx(): string;

(*
 * LF_Get_AppName: Retrieves the application name associated with the given
 * application handle.
 *
 * [PITFALL - CRITICAL] The returned pointer is valid for only ~5 seconds;
 *   the library automatically frees the underlying memory after that time.
 *   The caller MUST copy the content immediately.
 *
 * @param appHnd The application handle (TLF_App) whose name is queried.
 * @return PAnsiChar pointing to the UTF-8 encoded name, or nil if appHnd
 *         is nil.
 *)
function LF_Get_AppName(appHnd: TAppHnd___): pansichar; cdecl; external liblingofuse name 'LF_Get_AppName';

(*
 * LF_Get_AppNameEx: Convenience wrapper for LF_Get_AppName that copies the
 * returned string into a Pascal string before the underlying buffer is
 * freed. This is the recommended variant for Pascal callers.
 *
 * @return A Pascal string. Empty if appHnd is nil or the underlying call
 *         returned nil.
 *)
function LF_Get_AppNameEx(appHnd: TAppHnd___): string;

(*
 * LF_BindApp: Binds an application to all currently unbound LingoFuse
 * clients. This function must be called after LF_PrepareDone has been
 * invoked and the simulated main thread is active; otherwise, it logs an
 * error and returns 0 without any binding.
 *
 * Upon successful binding, each client will register the application and
 * its APIs with the service, making them available for remote discovery
 * and invocation. The binding process logs the application name,
 * description, connection details, and a list of all registered APIs with
 * their modes (call / notify).
 *
 * @param appHnd The application handle to bind.
 * @return The number of clients to which the application was successfully
 *         bound. A return value of 0 indicates that either the main thread
 *         is not active, or all existing clients are already occupied
 *         (each client can only host one application). In the latter case,
 *         a log message is emitted: "All clients are already occupied".
 *         If at least one client is bound, the application becomes
 *         available on the network.
 *
 * [PITFALL] The function only binds to clients that currently have a nil
 *   app reference (i.e. Cli.app = nil). Clients already hosting an app
 *   are skipped. If no such clients exist, the result is 0.
 *)
function LF_BindApp(appHnd: TAppHnd___): integer; cdecl; external liblingofuse name 'LF_BindApp';

{ ---- API Registration ---- }

(*
 * LF_RegisterCall: Registers a Call-mode API with a raw cdecl callback.
 *
 * [PITFALL] OnCall MUST be cdecl.
 * [PITFALL] Duplicate API names cause the function to return 0 without
 *   changing anything.
 * [PITFALL] This triggers a network broadcast (coalesced with ~2s window).
 *
 * @param appHnd      The application handle.
 * @param MethodName  Unique API name (UTF-8, case-insensitive).
 * @param Desc        Optional description (UTF-8).
 * @param Trigger     User pointer passed to the callback unchanged.
 * @param OnCall      cdecl function pointer implementing the API.
 * @return 1 on success, 0 if the name already exists.
 *)
function LF_RegisterCall(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnCall: TLF_Call_Event): integer; cdecl; external liblingofuse name 'LF_RegisterCall';

(*
 * LF_RegisterCallEx: Convenience wrapper for LF_RegisterCall accepting
 * Pascal strings (automatically UTF-8 encoded).
 *)
function LF_RegisterCallEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;

(*
 * LF_RegisterCall_M: Registers a Call API with an object method.
 * The method will be invoked on a background thread (unless the Sync
 * variant is used). This is the preferred way to register APIs from
 * Pascal code.
 *
 * @param appHnd      The application handle.
 * @param MethodName  Unique API name (UTF-8, case-insensitive).
 * @param Desc        Optional description.
 * @param OnCall      Object method to call.
 * @return 1 on success, 0 if the name already exists.
 * @see LF_RegisterSyncCall_M for main-thread variant.
 *)
function LF_RegisterCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;

(*
 * LF_RegisterSyncCall_M: Same as LF_RegisterCall_M, but the callback will
 * be synchronised to the main thread (the thread that runs the LingoFuse
 * progress loop). Use this for UI updates or accessing non-thread-safe
 * resources.
 *
 * [PITFALL] The main thread MUST periodically call LF_Sync (the library's
 *   progress loop does this automatically after LF_PrepareDone). Otherwise
 *   the sync callback will never execute and the calling thread will block
 *   forever.
 *)
function LF_RegisterSyncCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;

(*
 * LF_RegisterNotify: Registers a Notify-mode API with a raw cdecl callback.
 *
 * [PITFALL] OnNotify MUST be cdecl.
 * [PITFALL] Duplicate API names cause the function to return 0.
 *
 * @return 1 on success, 0 if the name already exists.
 *)
function LF_RegisterNotify(appHnd: TAppHnd___; MethodName, Desc: pansichar; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
  cdecl; external liblingofuse name 'LF_RegisterNotify';

(*
 * LF_RegisterNotifyEx: Convenience wrapper for LF_RegisterNotify accepting
 * Pascal strings (automatically UTF-8 encoded).
 *)
function LF_RegisterNotifyEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;

(*
 * LF_RegisterNotify_M: Registers a Notify API with an object method.
 * The method will be invoked on a background thread (unless the Sync
 * variant is used).
 *
 * @return 1 on success, 0 if the name already exists.
 *)
function LF_RegisterNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;

(*
 * LF_RegisterSyncNotify_M: Same as LF_RegisterNotify_M, but the callback
 * will be synchronised to the main thread.
 *
 * [PITFALL] The main thread MUST periodically call LF_Sync.
 *)
function LF_RegisterSyncNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;

(*
 * LF_Sync: Processes any pending synchronised callbacks.
 *
 * This is automatically called by the library's progress loop, but you may
 * call it manually to force processing in your own main loop (for example
 * if you are not using LF_PrepareDone).
 *
 * @return Number of callbacks processed.
 *)
function LF_Sync(): integer;

{ ---- Unregister ---- }

(*
 * LF_Unregister: Unregisters a previously registered API by name.
 * The API is immediately removed from the local registry and a network
 * broadcast is triggered. Remote peers may still see the API for up to
 * ~3 seconds until the broadcast propagates.
 *
 * @param appHnd      The application handle.
 * @param MethodName  Name of the API to unregister (UTF-8).
 * @return 1 if the API was found and removed, 0 otherwise.
 *)
function LF_Unregister(appHnd: TAppHnd___; MethodName: pansichar): integer; cdecl; external liblingofuse name 'LF_Unregister';

(*
 * LF_UnregisterEx: Convenience wrapper for LF_Unregister accepting a
 * Pascal string (automatically UTF-8 encoded).
 *)
function LF_UnregisterEx(appHnd: TAppHnd___; MethodName: string): integer;

{ ---- Local Calls ---- }

(*
 * LF_LocalCall: Executes a Call-mode API locally within the application,
 * bypassing the network. Synchronous.
 *
 * [PITFALL] The INPUT handle is NOT freed by this function. Caller must
 *   call LF_FreeData on it separately.
 * [PITFALL] The RETURN handle is NEW - caller owns it and must free it.
 * [PITFALL] During execution, the input handle's calling counter is
 *   incremented (Begin_Call / End_Call) to prevent the 10-minute
 *   auto-recycle from firing while the call is in flight.
 *
 * @param appHnd  The application handle.
 * @param Param   Input data handle.
 * @return A new TDataHnd with the result (size 0 if not found / error).
 *)
function LF_LocalCall(appHnd: TAppHnd___; Param: TDataHnd___): TDataHnd___; cdecl; external liblingofuse name 'LF_LocalCall';

(*
 * LF_LocalNotify: Sends a notification locally within the application.
 * Synchronous, no result.
 *
 * [PITFALL] The input handle is NOT freed by this function.
 * [PITFALL] Begin_Call / End_Call are used to protect the input handle
 *   from auto-recycle during execution.
 *)
procedure LF_LocalNotify(appHnd: TAppHnd___; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_LocalNotify';

{ ---- Preparation / Startup / Shutdown ---- }

(*
 * LF_ResetPrepare: Clears any previously prepared services and clients.
 * Call this before preparing a new set to avoid conflicts.
 *
 * [PITFALL] This function does not affect already running services or
 *   clients - it only clears the preparation queue.
 *)
procedure LF_ResetPrepare(); cdecl; external liblingofuse name 'LF_ResetPrepare';

(*
 * LF_PrepareService: Prepares or immediately creates a C4 service.
 *
 * If the main thread is already running (after LF_PrepareDone), this
 * function will create and start the service instantly, rather than just
 * queueing it. Otherwise, it queues the service for creation when
 * LF_PrepareDone is called.
 *
 * @param ListeningAddr_  Address to bind (e.g. "0.0.0.0",
 *                        "127.0.0.1:9898", "ipc:my_service").
 * @param PhysicsAddr_    Public address advertised to clients (same format).
 * @return A tag ID for the service, or -1 if a duplicate address exists.
 *
 * @Example:
 *   LF_ResetPrepare;
 *   LF_PrepareService('0.0.0.0', '127.0.0.1:9898');
 *   LF_PrepareDone;
 *)
function LF_PrepareService(ListeningAddr_, PhysicsAddr_: pansichar): integer; cdecl; external liblingofuse name 'LF_PrepareService';

(*
 * LF_PrepareServiceEx: Convenience wrapper for LF_PrepareService accepting
 * Pascal strings (automatically UTF-8 encoded).
 *)
function LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_: string): integer;

(*
 * LF_PrepareClient: Prepares or immediately creates a C4 client.
 *
 * If the main thread is already running, the client connection is attempted
 * immediately; otherwise, it is queued until LF_PrepareDone.
 *
 * IMPORTANT: The behaviour of this function regarding duplicate addresses
 * is controlled by the `Overlap_Connection` option (see LF_SetOption):
 *
 *   - When Overlap_Connection = False (default): only one client tunnel is
 *     created per address. If a tunnel already exists, it is reused and the
 *     provided `appHnd` is **ignored** (silently discarded). This means you
 *     cannot bind multiple different applications to the same remote
 *     service using this function alone - use LF_BindApp to change the
 *     application on an existing client.
 *
 *   - When Overlap_Connection = True: each call creates a new independent
 *     tunnel, and the provided `appHnd` is bound to the newly created
 *     client. This allows multiple applications to be exposed on the same
 *     remote service, each with its own dedicated connection.
 *
 * @param PhysicsAddr_  Address of the remote service to connect to.
 * @param appHnd        Optional application handle to expose; nil for
 *                      consumer-only.
 * @return A tag ID for the client, or -1 if a duplicate address exists
 *         (only when Overlap_Connection is False and a tunnel already
 *         exists).
 *
 * [PITFALL] The client automatically reconnects if the connection is lost.
 *   Upon reconnection, the application (if provided) is re-registered.
 *)
function LF_PrepareClient(PhysicsAddr_: pansichar; appHnd: TAppHnd___): integer; cdecl; external liblingofuse name 'LF_PrepareClient';

(*
 * LF_PrepareClientEx: Convenience wrapper for LF_PrepareClient accepting a
 * Pascal string address (automatically UTF-8 encoded).
 *)
function LF_PrepareClientEx(PhysicsAddr_: string; appHnd: TAppHnd___): integer; overload;

(*
 * LF_PrepareClientEx: Convenience wrapper that prepares a consumer-only
 * client (no application).
 *)
function LF_PrepareClientEx(PhysicsAddr_: string): integer; overload;

(*
 * LF_PrepareDone: Starts the LingoFuse framework with all prepared services
 * and clients. Blocks until the framework is initialised.
 *
 * @return 1 on success, 0 on failure.
 *
 * [PITFALL] This function can be called multiple times after a shutdown,
 *   but in the same process, only the first successful invocation starts
 *   the simulated main thread; subsequent calls (without an intervening
 *   LF_Shutdown + LF_ResetPrepare) will return 0.
 * [PITFALL] If Wait_Connection_ReadyOk is True (default), this call blocks
 *   up to Wait_Connection_Timeout (default 30 seconds) waiting for all
 *   prepared clients to become online.
 *)
function LF_PrepareDone: integer; cdecl; external liblingofuse name 'LF_PrepareDone';

(*
 * LF_ExitMainThread: Signals the simulated main thread to exit gracefully.
 * The framework stops processing network events but does not free all
 * resources. You should still call LF_Shutdown for a full cleanup.
 *
 * [PITFALL] Safe to call repeatedly.
 *)
procedure LF_ExitMainThread; cdecl; external liblingofuse name 'LF_ExitMainThread';

{ ---- Remote Calls / Notifications ---- }

(*
 * LF_Call: Performs a synchronous remote (or local) call.
 * Blocks until the response is received or the timeout expires.
 *
 * @param appName   Target application name (UTF-8, case-insensitive).
 * @param Param     Input data handle. The function reads the buffer
 *                  synchronously and serialises it for transmission; it
 *                  does NOT take ownership of the handle.
 * @param Timeout_  Maximum wait in milliseconds. 0 means infinite.
 * @return A new TDataHnd with the result. If the call times out or fails,
 *         the handle has size 0 (but is still valid).
 *
 * [PITFALL] The INPUT handle is NOT freed by this function. Caller must
 *   free it separately with LF_FreeData.
 * [PITFALL] The RESULT handle is NEW - caller owns it and must free it.
 * [PITFALL] This call is synchronous and blocks the calling thread. Do
 *   NOT call it from inside a callback (deadlock).
 * [PITFALL] Begin_Call / End_Call are used to protect the input handle
 *   from auto-recycle during the network round-trip.
 *
 * [NOTE] The function first tries to find a local instance of the target
 *   application to avoid a network round-trip.
 *)
function LF_Call(appName: pansichar; Param: TDataHnd___; Timeout_: uint64): TDataHnd___; cdecl; external liblingofuse name 'LF_Call';

(*
 * LF_CallEx: Convenience wrapper for LF_Call accepting a Pascal string
 * app name (automatically UTF-8 encoded).
 *)
function LF_CallEx(appName: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;

(*
 * LF_Notify: Sends a one-way notification.
 * Returns immediately after the notification has been queued.
 *
 * [PITFALL] Notifications are NOT ordered. If ordering matters, use
 *   LF_Sequenced_Notify instead.
 * [PITFALL] Input handle is NOT freed by this function - caller must free
 *   it after the call returns.
 * [PITFALL] Begin_Call / End_Call protect the input handle.
 *)
procedure LF_Notify(appName: pansichar; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_Notify';

(*
 * LF_NotifyEx: Convenience wrapper for LF_Notify accepting a Pascal string
 * app name (automatically UTF-8 encoded).
 *)
procedure LF_NotifyEx(appName: string; Param: TDataHnd___);

(*
 * LF_Sequenced_Notify: Sends a one-way notification with FIFO ordering
 * guarantee for the same (application, API) pair. The notification is
 * queued in a dedicated thread per (app, api) to preserve order.
 *
 * @param appName  Target application name (UTF-8, case-insensitive).
 * @param Param    Input data handle (payload). The library streams large
 *                 payloads efficiently using chunked transfer, so you can
 *                 safely send big data without excessive memory usage.
 *
 * [PITFALL] The call returns immediately after the data is queued.
 * [PITFALL] The underlying per-(app,api) thread has a 5-minute idle
 *   timeout; it terminates when idle and is re-created on demand.
 * [PITFALL] Ordering is guaranteed PER (app, api) pair only - no cross-key
 *   ordering.
 * [PITFALL] Begin_Call / End_Call protect the input handle.
 *)
procedure LF_Sequenced_Notify(appName: pansichar; Param: TDataHnd___); cdecl; external liblingofuse name 'LF_Sequenced_Notify';

(*
 * LF_Sequenced_NotifyEx: Convenience wrapper for LF_Sequenced_Notify
 * accepting a Pascal string app name (automatically UTF-8 encoded).
 *)
procedure LF_Sequenced_NotifyEx(appName: string; Param: TDataHnd___);

{ ---- Options & Status ---- }

(*
 * LF_SetOption: Dynamically adjusts global runtime options of the
 * LingoFuse framework. All changes take effect immediately for subsequent
 * operations.
 *
 * @param Option  Configuration key (UTF-8, case-insensitive). The
 *                following keys (and their aliases) are recognised:
 *
 *                === Authentication ===
 *                - "password" / "passwd"
 *                    Sets the C4 P2PVM authentication token (string).
 *
 *                === Logging & Debugging ===
 *                - "Quiet"
 *                    Enable/disable quiet mode (boolean). When enabled,
 *                    most internal log messages are suppressed.
 *                - "ShowThreadID" / "ShowThread" / "Show_Thread"
 *                    Show thread IDs in log output (boolean).
 *                - "ConsoleOutput" / "Console_Output"
 *                    Enable or disable console logging (boolean).
 *
 *                === Connection Readiness ===
 *                - "Overlap_Connection" / "Overlap_Client" /
 *                  "OverlapConnection" / "OverlapClient" / "OverlapConnect"
 *                    Controls whether multiple client tunnels to the same
 *                    remote address are allowed.
 *                    - False (default): only one tunnel per address.
 *                      Subsequent LF_PrepareClient calls with a different
 *                      appHnd will ignore the new appHnd.
 *                    - True: each LF_PrepareClient call creates a new
 *                      independent tunnel, binding the provided appHnd.
 *                - "Wait_Connection_ReadyOk" / "Wait_API_Prepare_Done" /
 *                  "API_Prepare_Done_Wait" / "WaitConnect" / "Wait_Ready" /
 *                  "WaitReady"
 *                    If True, LF_PrepareDone blocks until all prepared
 *                    clients are connected and their applications are
 *                    online (boolean). Default is True.
 *                - "Wait_Connection_Timeout" / "Wait_TimeOut" /
 *                  "API_Prepare_Done_TimeOut" / "WaitTimeOut"
 *                    Timeout in milliseconds for the above wait (integer).
 *                    Default is 30,000 ms (30 seconds).
 *
 *                === IPC (Inter-Process Communication) ===
 *                - "IPC_Serv_ThreadCount" / "IPC_ThreadCount" /
 *                  "IPC_Server_ThreadCount"
 *                    Number of threads in the IPC server thread pool
 *                    (integer).
 *                - "IPC_Serv_MaxQueueLength" / "IPC_MaxQueueLength" /
 *                  "IPC_Server_MaxQueueLength"
 *                    Maximum length of the IPC message queue (integer).
 *                - "IPC_Serv_MaxMsgSize" / "IPC_MaxMsgSize" /
 *                  "IPC_Server_MaxMsgSize"
 *                    Maximum size (in bytes) of a single IPC message
 *                    (integer).
 *
 *                === Sequenced Notifications ===
 *                - "Fixed_Sequenced_Time" / "Fixed_Sequenced_Life"
 *                    Idle timeout (in milliseconds) for sequenced
 *                    notification fallback. When selecting a client for a
 *                    sequenced notification, if the candidate with the
 *                    oldest timestamp is older than this value, the system
 *                    falls back to the newest client to avoid starvation
 *                    (integer).
 *
 *                === Data Handle Pool ===
 *                - "DataHandle_Idle_Timeout" / "Data_Idle_Timeout" /
 *                  "Idle_Timeout"
 *                    Idle-timeout (in milliseconds) for automatic
 *                    reclamation of non-permanent data handles by
 *                    TLF_DataPool.Progress.
 *                      >  0 : ENABLED. A tracked handle that has not been
 *                             accessed for this long becomes a candidate
 *                             for release on the next pool scan.
 *                             Default: 600000 ms (10 minutes).
 *                      <= 0 : DISABLED. Only an explicit LF_FreeData
 *                             call releases a handle; the idle-reclaim
 *                             branch in Progress is skipped entirely.
 *
 *                    Notes:
 *                      * Any accessor call on the handle (LF_GetSize /
 *                        LF_GetPos / LF_ReadBuffer / LF_WriteBuffer / ...)
 *                        refreshes its idle timer and postpones the
 *                        timeout.
 *                      * A remote call in flight (calling counter > 0)
 *                        also postpones the timeout, regardless of idle
 *                        time.
 *                      * This option does NOT affect handles created with
 *                        LF_CreateData_Permanent. Those are released
 *                        synchronously by LF_FreeData and never enter the
 *                        idle-reclaim path.
 *
 *                - "DataHandle_Pool_Scan_Interval" / "Data_Scan_Interval" /
 *                  "DataHandle_Scan_Interval"
 *                    Minimum interval (in milliseconds) between two
 *                    consecutive scans of the data-handle pool by
 *                    TLF_DataPool.Progress.
 *                      >  0 : ENABLED. Progress() returns immediately if
 *                             fewer than this many milliseconds have
 *                             elapsed since the last scan. Default:
 *                             5000 ms (5 seconds).
 *                      <= 0 : DISABLED. Progress() scans on every call,
 *                             without rate-limiting.
 *
 *                    Relationship with DataHandle_Idle_Timeout:
 *                      * DataHandle_Pool_Scan_Interval controls HOW OFTEN
 *                        the pool is scanned.
 *                      * DataHandle_Idle_Timeout controls WHEN a scanned
 *                        handle is actually released.
 *                      * A handle that becomes eligible at time T is
 *                        typically released at T plus up to one scan
 *                        interval of latency.
 *
 *                    Notes:
 *                      * Progress() is driven by the simulated main
 *                        thread. Its effective call frequency is bounded
 *                        below by the main thread's tick granularity, not
 *                        by this value alone.
 *                      * Setting this very low (< 1 second) is almost
 *                        never useful: the pool lock and the O(N) walk
 *                        dominate the cost, while the reclamation-latency
 *                        improvement is negligible.
 *                      * Setting this to 0 disables the rate limiter, but
 *                        does NOT disable reclamation itself.
 *
 * @param Value   New value for the given option (UTF-8). Boolean values
 *                accept "True"/"False", "1"/"0", "Yes"/"No"
 *                (case-insensitive). Integer values are parsed as decimal
 *                numbers. String values are used as-is.
 *
 * [PITFALL] Unknown options are silently ignored.
 * [PITFALL] Changes are not persisted across restarts.
 *)
procedure LF_SetOption(Option, Value: pansichar); cdecl; external liblingofuse name 'LF_SetOption';

(*
 * LF_SetOptionEx: Convenience wrapper for LF_SetOption accepting Pascal
 * strings (automatically UTF-8 encoded).
 *)
procedure LF_SetOptionEx(Option, Value: string);

(*
 * LF_GetStatusCount: Returns the number of pending log messages in the
 * internal status buffer.
 *
 * [PITFALL] This counts messages that are already queued, not messages
 *   still in flight through the DoStatus pipeline.
 *)
function LF_GetStatusCount(): integer; cdecl; external liblingofuse name 'LF_GetStatusCount';

(*
 * LF_GetStatus: Retrieves the next log message from the internal status
 * buffer. The returned pointer is valid only until the next call to this
 * function. You must copy the string if you need to keep it.
 *
 * [PITFALL - BUFFER REUSE] The pointer is INVALIDATED by the next call to
 *   LF_GetStatus. Copy the string immediately if you need to retain it.
 *   Messages longer than 65,534 bytes are truncated.
 *
 * [PITFALL] This function relies on the simulated main thread to process
 *   the status queue. If the main thread has not been started (i.e.
 *   before LF_PrepareDone), the buffer may be empty or contain stale data.
 *
 * @return PAnsiChar pointing to a null-terminated UTF-8 string, or an
 *         empty string if no message is available.
 *)
function LF_GetStatus(): pansichar; cdecl; external liblingofuse name 'LF_GetStatus';

(*
 * LF_GetStatusEx: Convenience wrapper for LF_GetStatus that copies the
 * returned string into a Pascal string immediately, before the underlying
 * static buffer is overwritten.
 *)
function LF_GetStatusEx(): string;

(*
 * LF_PostStatus: Injects a user-supplied log message into the status
 * system, as if it had been emitted by the library itself.
 *
 * [PITFALL] Before LF_PrepareDone, the message is still enqueued (with a
 *   diagnostic log line), but may not appear in the returned buffer until
 *   the simulated main thread starts polling.
 *)
procedure LF_PostStatus(status: pansichar); cdecl; external liblingofuse name 'LF_PostStatus';

(*
 * LF_PostStatusEx: Convenience wrapper for LF_PostStatus accepting a
 * Pascal string (automatically UTF-8 encoded).
 *)
procedure LF_PostStatusEx(status: string);

{ ---- Queries ---- }

(*
 * LF_CheckMainThread: Returns 1 if the simulated main thread (which runs
 * the C4 progress loop) is currently active.
 *
 * [PITFALL] Before LF_PrepareDone and after LF_ExitMainThread this returns
 *   0. Remote communication is unavailable in that state.
 *)
function LF_CheckMainThread(): integer; cdecl; external liblingofuse name 'LF_CheckMainThread';

(*
 * LF_CheckMainThreadEx: Convenience wrapper returning a Boolean.
 *)
function LF_CheckMainThreadEx(): boolean;

(*
 * LF_CheckApp: Checks whether an application with the given name is
 * currently registered on the network (locally or remotely).
 *
 * @return 1 if at least one instance is available, 0 otherwise.
 *
 * [PITFALL] This is a point-in-time probe and does not guarantee that the
 *   application will still be online at the moment of a subsequent call.
 *)
function LF_CheckApp(appName: pansichar): integer; cdecl; external liblingofuse name 'LF_CheckApp';

(*
 * LF_CheckAppEx: Convenience wrapper returning a Boolean.
 *)
function LF_CheckAppEx(appName: string): boolean;

(*
 * LF_CheckApi: Checks whether a specific API is available on the network
 * for the given application. It searches both local and remote instances
 * of the application to determine if the API is exported.
 *
 * @param appName   Application name (UTF-8, case-insensitive).
 * @param apiName   API name (UTF-8, case-insensitive).
 * @return 1 if the API is available on at least one instance of the
 *         application, 0 otherwise.
 *
 * [PITFALL] This function performs a quick lookup based on cached
 *   information and may not reflect recent changes. It is useful for
 *   probing availability before making a call, but does not guarantee
 *   that the API will still be available at the moment of the actual
 *   call.
 *)
function LF_CheckApi(appName, apiName: pansichar): integer; cdecl; external liblingofuse name 'LF_CheckApi';

(*
 * LF_CheckApiEx: Convenience wrapper returning a Boolean.
 *)
function LF_CheckApiEx(appName, apiName: string): boolean;

{ ---- Shutdown ---- }

(*
 * LF_Shutdown: Gracefully terminates the entire LingoFuse framework.
 *
 * This procedure:
 *   1. Clears the network event callbacks (On_Network_Connect_Event /
 *      On_Network_Disconnect_Event). This prevents any in-flight worker
 *      thread from jumping into a callback after we start tearing down.
 *   2. Stops all sequenced notification threads.
 *   3. Frees all remaining data handles.
 *   4. Exits the simulated main thread.
 *   5. Clears the global LF_App_Pool, which destroys every TLF_App object
 *      that has not been physically freed by LF_FreeApp.
 *   6. Unloads the IPC library and closes the core dispatch thread.
 *
 * After LF_Shutdown, the library is fully reset and can be re-initialised
 * by calling preparation functions again. It is safe to call multiple
 * times.
 *
 * [PITFALL] Even if you forget to call LF_FreeApp for some applications,
 *   LF_Shutdown ensures they are properly destroyed, preventing leaks.
 *)
procedure LF_Shutdown; cdecl; external liblingofuse name 'LF_Shutdown';

{ ---- Network Events ---- }

(*
 * TLF_Network_Event: Callback prototype for network connect/disconnect
 * notifications at the transport layer.
 *
 * ===========================================================================
 * TRIGGER MECHANICS (confirmed by source inspection)
 * ===========================================================================
 *
 *   Connect    <- TC40_LF_Client.cmd_update_service_api_info
 *                 (fires once, on the first service-API-info broadcast
 *                  received from the server; gated by the
 *                  FService_Info_Is_Onlne False -> True transition)
 *
 *   Disconnect <- TC40_LF_Client.DoNetworkOffline
 *                 (fires once per physical link loss; NOT fired on the
 *                  auto-reconnect attempt itself)
 *
 * ===========================================================================
 * SEMANTIC CONTRACT
 * ===========================================================================
 *
 *   - "Connect" is NOT the TCP handshake completed. It is the earliest
 *     point at which the client can actually route remote calls.
 *   - Both events fire exactly once per connection lifecycle.
 *   - Global scope: no per-client registration API. If you need to
 *     distinguish clients, filter by the addr_ string in the callback.
 *
 * ===========================================================================
 * {!!!!!  CRITICAL PITFALLS  !!!!!}
 * ===========================================================================
 *
 *   [THREADING] The callback runs on a BACKGROUND TCompute WORKER THREAD.
 *     It is neither the caller thread nor the main thread. Do NOT touch
 *     UI controls directly; marshal to the main thread with TThread.Queue
 *     (VCL / LCL) or an equivalent mechanism.
 *
 *   [LIFETIME] The addr_ parameter is a raw UTF-8 PAnsiChar buffer owned
 *     by the library and freed IMMEDIATELY AFTER the callback returns
 *     (via TLF_String.FreeUTF8AnsiChar). Do NOT store the pointer; copy
 *     the string inside the callback if you need to retain it.
 *
 *   [EXCEPTIONS] Any exception raised inside the callback is SILENTLY
 *     SWALLOWED by the library. Do not use exceptions for control flow.
 *
 *   [ABI] The callback MUST be declared cdecl to be compatible with the
 *     C export layer. The default Pascal convention (register / fastcall)
 *     will corrupt the stack.
 *
 *   [BLOCKING] Never call blocking LingoFuse functions (LF_Call,
 *     LF_LocalCall, LF_PrepareDone, LF_Shutdown) inside the callback.
 *     It will deadlock.
 *
 *   [MANAGED LANGUAGES] In C# / Java / Python-ctypes the delegate /
 *     callback object MUST be kept alive with a strong reference;
 *     otherwise the GC may collect it while the library still holds the
 *     function pointer, causing a crash on the next invocation.
 *
 * @param addr_  Null-terminated UTF-8 string identifying the remote
 *               endpoint (e.g. "127.0.0.1:9898" or "ipc:service_name").
 *               Valid ONLY during the callback invocation.
 *
 * @Example (Pascal):
 *   procedure OnConnect(addr: PAnsiChar); cdecl;
 *   var s: string;
 *   begin
 *     s := UTF8ToString(addr);   // copy NOW, addr_ dies after return
 *     TThread.Queue(nil,
 *       procedure
 *       begin
 *         Memo1.Lines.Add('Connected to ' + s);
 *       end);
 *   end;
 *
 * @Example (C):
 *   static void __cdecl OnConnect(const char* addr) {
 *       char* copy = strdup(addr);   // copy NOW
 *       post_to_ui_thread(copy);
 *   }
 *)
type
  TLF_Network_Event = procedure(addr_: pansichar); cdecl;

(*
 * LF_Set_Network_Event: Installs or clears the global network event
 * handlers.
 *
 * @param On_Connect_     Callback invoked when a client becomes online.
 *                        Pass nil to disable the connect notification.
 * @param On_Disconnect_  Callback invoked when a client goes offline.
 *                        Pass nil to disable the disconnect notification.
 *
 * ===========================================================================
 * {!!!!!  CRITICAL PITFALLS  !!!!!}
 * ===========================================================================
 *
 *   [GLOBAL SCOPE] Both handlers are process-global. Installing a handler
 *     affects every LingoFuse client in the current process. There is no
 *     per-client registration API.
 *
 *   [RAW FUNCTION POINTER] The handlers are stored as raw pointers.
 *     The library does NOT own them. If the caller unloads its own module
 *     while a handler is still installed, subsequent invocations will
 *     jump into freed memory. Clear the handlers (pass nil) before
 *     unloading your module.
 *
 *   [MANAGED LANGUAGES] The delegate / callback object MUST be kept alive
 *     with a strong reference for as long as the handler is installed.
 *     Otherwise the GC may collect it while the library still invokes it.
 *
 *   [SHUTDOWN] LF_Shutdown automatically clears both handlers before
 *     tearing down the framework. It is safe (but not required) to call
 *     LF_Set_Network_Event(nil, nil) explicitly before LF_Shutdown.
 *
 *   [THREADING] The callbacks run on background TCompute worker threads.
 *     See TLF_Network_Event for the full contract.
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
 *   // ... later, before unloading your module:
 *   LF_Set_Network_Event(nil, nil);
 *
 * @Example (C):
 *   static void __cdecl OnConnect(const char* addr) {
 *       char* copy = strdup(addr);
 *       post_to_ui_thread(copy);
 *   }
 *   LF_Set_Network_Event(OnConnect, NULL);
 *)
procedure LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event); cdecl; external liblingofuse name 'LF_Set_Network_Event';

implementation

uses SyncObjs;

{ ----------------------------------------------------------------------------
  Helper Functions Implementation
  ---------------------------------------------------------------------------- }

(*
 * LF_CreateDataEx: Converts a Pascal string to UTF-8 and calls LF_CreateData.
 *)
function LF_CreateDataEx(MethodName: string): TDataHnd___;
begin
  Result := LF_CreateData(pansichar(UTF8Encode(MethodName)));
end;

(*
 * LF_CreateData_PermanentEx: Converts a Pascal string to UTF-8 and calls
 * LF_CreateData_Permanent.
 *)
function LF_CreateData_PermanentEx(MethodName: string): TDataHnd___;
begin
  Result := LF_CreateData_Permanent(pansichar(UTF8Encode(MethodName)));
end;

(*
 * LF_GetBufferOffset: Returns a pointer to Hnd's buffer + Offset.
 * Returns nil if the underlying buffer is nil.
 *)
function LF_GetBufferOffset(Hnd: TDataHnd___; Offset: nativeint): Pointer;
var
  base: Pointer;
begin
  base := LF_GetBuffer(Hnd);
  if base = nil then
    Result := nil
  else
    Result := Pointer(nativeuint(base) + Offset);
end;

(*
 * LF_WriteInt8: Writes an 8-bit signed integer.
 * Returns True if exactly SizeOf(int8) bytes were written.
 *)
function LF_WriteInt8(Hnd: TDataHnd___; Value: int8): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteUInt8: Writes an 8-bit unsigned integer.
 *)
function LF_WriteUInt8(Hnd: TDataHnd___; Value: uint8): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteInt16: Writes a 16-bit signed integer.
 *)
function LF_WriteInt16(Hnd: TDataHnd___; Value: int16): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteUInt16: Writes a 16-bit unsigned integer.
 *)
function LF_WriteUInt16(Hnd: TDataHnd___; Value: uint16): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteInt32: Writes a 32-bit signed integer.
 *)
function LF_WriteInt32(Hnd: TDataHnd___; Value: int32): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteUInt32: Writes a 32-bit unsigned integer.
 *)
function LF_WriteUInt32(Hnd: TDataHnd___; Value: uint32): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteInt64: Writes a 64-bit signed integer.
 *)
function LF_WriteInt64(Hnd: TDataHnd___; Value: int64): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteUInt64: Writes a 64-bit unsigned integer.
 *)
function LF_WriteUInt64(Hnd: TDataHnd___; Value: uint64): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteSingle: Writes a 32-bit IEEE 754 single-precision float.
 *)
function LF_WriteSingle(Hnd: TDataHnd___; Value: single): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteDouble: Writes a 64-bit IEEE 754 double-precision float.
 *)
function LF_WriteDouble(Hnd: TDataHnd___; Value: double): boolean;
begin
  Result := LF_WriteBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_WriteString: Writes a UTF-8 encoded string followed by a null
 * terminator. An empty string writes a single #0 byte.
 *)
function LF_WriteString(Hnd: TDataHnd___; const Value: string): boolean;
var
  utf8: TBytes;
  len: integer;
begin
  if Value = '' then
  begin
    Result := LF_WriteUInt8(Hnd, 0);
    Exit;
  end;
  utf8 := TEncoding.utf8.GetBytes(Value);
  len := Length(utf8);
  if LF_WriteBuffer(Hnd, @utf8[0], len) <> len then
  begin
    Result := False;
    Exit;
  end;
  Result := LF_WriteUInt8(Hnd, 0);
end;

(*
 * LF_WriteStringBytes: Writes raw bytes followed by a null terminator.
 * An empty array writes a single #0 byte.
 *)
function LF_WriteStringBytes(Hnd: TDataHnd___; const Value: TBytes): boolean;
begin
  if Length(Value) <= 0 then
  begin
    Result := LF_WriteUInt8(Hnd, 0);
    Exit;
  end;
  if LF_WriteBuffer(Hnd, @Value[0], Length(Value)) <> Length(Value) then
  begin
    Result := False;
    Exit;
  end;
  Result := LF_WriteUInt8(Hnd, 0);
end;

(*
 * LF_ReadInt8: Reads an 8-bit signed integer.
 *)
function LF_ReadInt8(Hnd: TDataHnd___; out Value: int8): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadUInt8: Reads an 8-bit unsigned integer.
 *)
function LF_ReadUInt8(Hnd: TDataHnd___; out Value: uint8): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadInt16: Reads a 16-bit signed integer.
 *)
function LF_ReadInt16(Hnd: TDataHnd___; out Value: int16): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadUInt16: Reads a 16-bit unsigned integer.
 *)
function LF_ReadUInt16(Hnd: TDataHnd___; out Value: uint16): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadInt32: Reads a 32-bit signed integer.
 *)
function LF_ReadInt32(Hnd: TDataHnd___; out Value: int32): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadUInt32: Reads a 32-bit unsigned integer.
 *)
function LF_ReadUInt32(Hnd: TDataHnd___; out Value: uint32): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadInt64: Reads a 64-bit signed integer.
 *)
function LF_ReadInt64(Hnd: TDataHnd___; out Value: int64): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadUInt64: Reads a 64-bit unsigned integer.
 *)
function LF_ReadUInt64(Hnd: TDataHnd___; out Value: uint64): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadSingle: Reads a 32-bit IEEE 754 single-precision float.
 *)
function LF_ReadSingle(Hnd: TDataHnd___; out Value: single): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadDouble: Reads a 64-bit IEEE 754 double-precision float.
 *)
function LF_ReadDouble(Hnd: TDataHnd___; out Value: double): boolean;
begin
  Result := LF_ReadBuffer(Hnd, @Value, SizeOf(Value)) = SizeOf(Value);
end;

(*
 * LF_ReadInt8: Returns the read value directly. 0 on failure.
 *)
function LF_ReadInt8(Hnd: TDataHnd___): int8;
var
  v: int8;
begin
  if LF_ReadInt8(Hnd, v) then Result := v
  else
    Result := 0;
end;

(*
 * LF_ReadUInt8: Returns the read value directly. 0 on failure.
 *)
function LF_ReadUInt8(Hnd: TDataHnd___): uint8;
var
  v: uint8;
begin
  if LF_ReadUInt8(Hnd, v) then Result := v
  else
    Result := 0;
end;

(*
 * LF_ReadInt16: Returns the read value directly. 0 on failure.
 *)
function LF_ReadInt16(Hnd: TDataHnd___): int16;
var
  v: int16;
begin
  if LF_ReadInt16(Hnd, v) then Result := v
  else
    Result := 0;
end;

(*
 * LF_ReadUInt16: Returns the read value directly. 0 on failure.
 *)
function LF_ReadUInt16(Hnd: TDataHnd___): uint16;
var
  v: uint16;
begin
  if LF_ReadUInt16(Hnd, v) then Result := v
  else
    Result := 0;
end;

(*
 * LF_ReadInt32: Returns the read value directly. 0 on failure.
 *)
function LF_ReadInt32(Hnd: TDataHnd___): int32;
var
  v: int32;
begin
  if LF_ReadInt32(Hnd, v) then Result := v
  else
    Result := 0;
end;

(*
 * LF_ReadUInt32: Returns the read value directly. 0 on failure.
 *)
function LF_ReadUInt32(Hnd: TDataHnd___): uint32;
var
  v: uint32;
begin
  if LF_ReadUInt32(Hnd, v) then Result := v
  else
    Result := 0;
end;

(*
 * LF_ReadInt64: Returns the read value directly. 0 on failure.
 *)
function LF_ReadInt64(Hnd: TDataHnd___): int64;
var
  v: int64;
begin
  if LF_ReadInt64(Hnd, v) then Result := v
  else
    Result := 0;
end;

(*
 * LF_ReadUInt64: Returns the read value directly. 0 on failure.
 *)
function LF_ReadUInt64(Hnd: TDataHnd___): uint64;
var
  v: uint64;
begin
  if LF_ReadUInt64(Hnd, v) then Result := v
  else
    Result := 0;
end;

(*
 * LF_ReadSingle: Returns the read value directly. 0.0 on failure.
 *)
function LF_ReadSingle(Hnd: TDataHnd___): single;
var
  v: single;
begin
  if LF_ReadSingle(Hnd, v) then Result := v
  else
    Result := 0.0;
end;

(*
 * LF_ReadDouble: Returns the read value directly. 0.0 on failure.
 *)
function LF_ReadDouble(Hnd: TDataHnd___): double;
var
  v: double;
begin
  if LF_ReadDouble(Hnd, v) then Result := v
  else
    Result := 0.0;
end;

(*
 * LF_ReadStringBytes: Reads a null-terminated UTF-8 byte sequence starting
 * at the current position. The position is advanced past the null
 * terminator. If no terminator is found before the end of the buffer, the
 * remaining bytes are returned (fault-tolerant mode).
 *)
function LF_ReadStringBytes(Hnd: TDataHnd___; out Buff: TBytes): boolean;
type
  TByteArray = array [0 .. 0] of byte;
  PByteArray = ^TByteArray;
var
  p: PByteArray;
  b, e, sz: int64;
begin
  p := LF_GetBuffer(Hnd);
  sz := LF_GetSize(Hnd);
  if (p = nil) or (sz = 0) then
  begin
    SetLength(Buff, 0);
    Result := False;
    Exit;
  end;
  b := LF_GetPos(Hnd);
  if b >= sz then
  begin
    SetLength(Buff, 0);
    Result := False;
    Exit;
  end;
  e := b;
  while (e < sz) and (p^[e] <> 0) do
    Inc(e);
  SetLength(Buff, e - b);
  if e > b then
    Move(p^[b], Buff[0], e - b);
  LF_SetPos(Hnd, e + 1);
  Result := True;
end;

(*
 * LF_ReadStringBytes: Returns the read bytes directly.
 *)
function LF_ReadStringBytes(Hnd: TDataHnd___): TBytes;
begin
  LF_ReadStringBytes(Hnd, Result);
end;

(*
 * LF_ReadString: Reads a null-terminated UTF-8 byte sequence and decodes
 * it into a Pascal string. The position is advanced past the null
 * terminator.
 *)
function LF_ReadString(Hnd: TDataHnd___; out Value: string): boolean;
type
  TByteArray = array [0 .. 0] of byte;
  PByteArray = ^TByteArray;
var
  p: PByteArray;
  b, e, sz: int64;
  Buff: TBytes;
begin
  p := LF_GetBuffer(Hnd);
  sz := LF_GetSize(Hnd);
  if (p = nil) or (sz = 0) then
  begin
    Value := '';
    Result := False;
    Exit;
  end;
  b := LF_GetPos(Hnd);
  if b >= sz then
  begin
    Value := '';
    Result := False;
    Exit;
  end;
  e := b;
  while (e < sz) and (p^[e] <> 0) do
    Inc(e);
  SetLength(Buff, e - b);
  if e > b then
    Move(p^[b], Buff[0], e - b);
  LF_SetPos(Hnd, e + 1);
  Value := TEncoding.utf8.GetString(Buff);
  Result := True;
end;

(*
 * LF_ReadString: Returns the read string directly.
 *)
function LF_ReadString(Hnd: TDataHnd___): string;
begin
  LF_ReadString(Hnd, Result);
end;

(*
 * LF_CreateAppEx: Converts Pascal strings to UTF-8 and calls LF_CreateApp.
 *)
function LF_CreateAppEx(appName, Desc: string): TAppHnd___;
begin
  Result := LF_CreateApp(pansichar(UTF8Encode(appName)), pansichar(UTF8Encode(Desc)));
end;

(*
 * LF_Generate_AppNameEx: Copies the returned PAnsiChar into a Pascal
 * string immediately, before the library frees the buffer.
 *)
function LF_Generate_AppNameEx(): string;
var
  p: pansichar;
begin
  p := LF_Generate_AppName();
  if p = nil then
    Result := ''
  else
    Result := UTF8Decode(p);
end;

(*
 * LF_Get_AppNameEx: Copies the returned PAnsiChar into a Pascal string
 * immediately, before the library frees the buffer. Returns an empty
 * string if appHnd is nil or the library returns nil.
 *)
function LF_Get_AppNameEx(appHnd: TAppHnd___): string;
var
  p: pansichar;
begin
  p := LF_Get_AppName(appHnd);
  if p = nil then
    Result := ''
  else
    Result := UTF8Decode(p);
end;

(*
 * LF_RegisterCallEx: Converts Pascal strings to UTF-8 and calls
 * LF_RegisterCall.
 *)
function LF_RegisterCallEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnCall: TLF_Call_Event): integer;
begin
  Result := LF_RegisterCall(appHnd, pansichar(UTF8Encode(MethodName)), pansichar(UTF8Encode(Desc)), Trigger, OnCall);
end;

(*
 * LF_RegisterNotifyEx: Converts Pascal strings to UTF-8 and calls
 * LF_RegisterNotify.
 *)
function LF_RegisterNotifyEx(appHnd: TAppHnd___; MethodName, Desc: string; Trigger: Pointer; OnNotify: TLF_Notify_Event): integer;
begin
  Result := LF_RegisterNotify(appHnd, pansichar(UTF8Encode(MethodName)), pansichar(UTF8Encode(Desc)), Trigger, OnNotify);
end;

(*
 * LF_UnregisterEx: Converts a Pascal string to UTF-8 and calls
 * LF_Unregister.
 *)
function LF_UnregisterEx(appHnd: TAppHnd___; MethodName: string): integer;
begin
  Result := LF_Unregister(appHnd, pansichar(UTF8Encode(MethodName)));
end;

(*
 * LF_PrepareServiceEx: Converts Pascal strings to UTF-8 and calls
 * LF_PrepareService.
 *)
function LF_PrepareServiceEx(ListeningAddr_, PhysicsAddr_: string): integer;
begin
  Result := LF_PrepareService(pansichar(UTF8Encode(ListeningAddr_)), pansichar(UTF8Encode(PhysicsAddr_)));
end;

(*
 * LF_PrepareClientEx: Converts a Pascal string to UTF-8 and calls
 * LF_PrepareClient with an app handle.
 *)
function LF_PrepareClientEx(PhysicsAddr_: string; appHnd: TAppHnd___): integer;
begin
  Result := LF_PrepareClient(pansichar(UTF8Encode(PhysicsAddr_)), appHnd);
end;

(*
 * LF_PrepareClientEx: Convenience overload that prepares a consumer-only
 * client (nil app handle).
 *)
function LF_PrepareClientEx(PhysicsAddr_: string): integer;
begin
  Result := LF_PrepareClientEx(PhysicsAddr_, nil);
end;

(*
 * LF_CallEx: Converts a Pascal string to UTF-8 and calls LF_Call.
 *)
function LF_CallEx(appName: string; Param: TDataHnd___; Timeout_: uint64): TDataHnd___;
begin
  Result := LF_Call(pansichar(UTF8Encode(appName)), Param, Timeout_);
end;

(*
 * LF_NotifyEx: Converts a Pascal string to UTF-8 and calls LF_Notify.
 *)
procedure LF_NotifyEx(appName: string; Param: TDataHnd___);
begin
  LF_Notify(pansichar(UTF8Encode(appName)), Param);
end;

(*
 * LF_Sequenced_NotifyEx: Converts a Pascal string to UTF-8 and calls
 * LF_Sequenced_Notify.
 *)
procedure LF_Sequenced_NotifyEx(appName: string; Param: TDataHnd___);
begin
  LF_Sequenced_Notify(pansichar(UTF8Encode(appName)), Param);
end;

(*
 * LF_SetOptionEx: Converts Pascal strings to UTF-8 and calls LF_SetOption.
 *)
procedure LF_SetOptionEx(Option, Value: string);
begin
  LF_SetOption(pansichar(UTF8Encode(Option)), pansichar(UTF8Encode(Value)));
end;

(*
 * LF_GetStatusEx: Copies the returned PAnsiChar into a Pascal string
 * immediately, before the underlying static buffer is overwritten.
 *)
function LF_GetStatusEx(): string;
var
  p: pansichar;
begin
  p := LF_GetStatus();
  if p = nil then
    Result := ''
  else
    Result := UTF8Decode(p);
end;

(*
 * LF_PostStatusEx: Converts a Pascal string to UTF-8 and calls
 * LF_PostStatus.
 *)
procedure LF_PostStatusEx(status: string);
begin
  LF_PostStatus(pansichar(UTF8Encode(status)));
end;

(*
 * LF_CheckMainThreadEx: Returns True if the simulated main thread is
 * active.
 *)
function LF_CheckMainThreadEx(): boolean;
begin
  Result := LF_CheckMainThread() <> 0;
end;

(*
 * LF_CheckAppEx: Converts a Pascal string to UTF-8 and calls LF_CheckApp.
 * Returns True if the app is registered locally or remotely.
 *)
function LF_CheckAppEx(appName: string): boolean;
begin
  Result := LF_CheckApp(pansichar(UTF8Encode(appName))) <> 0;
end;

(*
 * LF_CheckApiEx: Converts Pascal strings to UTF-8 and calls LF_CheckApi.
 * Returns True if the API is available on at least one instance of the
 * application.
 *)
function LF_CheckApiEx(appName, apiName: string): boolean;
begin
  Result := LF_CheckApi(pansichar(UTF8Encode(appName)), pansichar(UTF8Encode(apiName))) <> 0;
end;

(* ----------------------------------------------------------------------------
  Internal Synchronisation & Callback Adapter
  ----------------------------------------------------------------------------

  {!!!!!  HOW METHOD CALLBACKS WORK  !!!!!}

  The LingoFuse library expects cdecl callbacks (TLF_Call_Event or
  TLF_Notify_Event). However, Pascal object methods (of object) have a
  different calling convention and cannot be passed directly.

  This unit solves that by storing the TMethod (code + data pointer) of
  each registered method in an internal pool (LF_EventPool) and providing
  small cdecl trampoline procedures (Do_Internal_Call__ etc.) that
  retrieve the TMethod and call it.

  The registration functions (LF_RegisterCall_M, etc.) do the following:
    1. Allocate a slot in LF_EventPool and store the TMethod.
    2. Pass the address of the TMethod as the 'Trigger' pointer to the
       underlying LF_RegisterCall function.
    3. Provide the trampoline as the callback.

  When the library invokes the trampoline, it passes the Trigger pointer
  (which is the address of the TMethod), allowing the trampoline to
  reconstruct the TMethod and invoke the Pascal method.

  For sync variants, the trampoline wraps the call in a procedure that
  is queued via TSoft_Synchronize_Tool. This tool ensures that the
  procedure is executed on the main thread (the thread that called
  LF_PrepareDone). It does this using a FIFO queue and a busy-wait loop,
  similar to TThread.Synchronize but implemented entirely in user space.

  {!!!!!  THREAD SAFETY OF THIS ADAPTER  !!!!!}
  - LF_EventPool uses TOrderStruct which is not thread-safe, but it is
    only accessed during registration (which is typically single-threaded).
    The pool is not accessed concurrently after registration.
  - The sync queue (TSoft_Synchronize_Tool.SyncQueue__) is protected by
    a critical section, making it thread-safe for posting callbacks.
  - The trampolines themselves are executed on the library's threads,
    but they only read the TMethod from the pool and call it. The pool
    is never modified after registration, so it is safe.

  {!!!!!  IMPORTANT - DO NOT BLOCK  !!!!!}
  - The trampolines are called on the library's internal threads. If you
    block inside a callback (e.g. by calling LF_Call or Sleep), you will
    block the network event loop, causing performance degradation or
    deadlocks. Use the sync variants for UI updates and offload heavy
    work to separate threads.

  ---------------------------------------------------------------------------- *)

type
  (*
   * TCritical: Wrapper around TCriticalSection with Lock/UnLock methods.
   *)
  TCritical = class(TCriticalSection)
  public
    procedure Lock; inline;
    procedure UnLock; inline;
  end;

  (*
   * TOrderStruct<T>: A simple singly-linked FIFO queue.
   * Used for storing deferred callbacks and event data.
   * This is a generic implementation of a queue with Push (tail) and
   * Next (head remove). It is not thread-safe; external locking is
   * required.
   *)
  TOrderStruct<T_> = class
  public
    type
      POrderStruct = ^TOrderStruct_;

      TOrderStruct_ = record
        Data: T_;
        Next: POrderStruct;
      end;

      TOnFreeOrderStruct = procedure(var p: T_) of object;
  private
    FFirst: POrderStruct;
    FLast: POrderStruct;
    FNum: nativeint;
    FOnFreeOrderStruct: TOnFreeOrderStruct;
    procedure DoInternalFree(const p: POrderStruct);
  public
    constructor Create; virtual;
    destructor Destroy; override;
    procedure DoFree(var Data: T_); virtual;
    procedure SwapInstance(Source: TOrderStruct<T_>);
    procedure Clear;
    property Current: POrderStruct read FFirst;
    property First: POrderStruct read FFirst;
    property Last: POrderStruct read FLast;
    procedure Next;
    function Push(const Data: T_): POrderStruct;
    function Push_Null: POrderStruct;
    property Num: nativeint read FNum;
    property OnFree: TOnFreeOrderStruct read FOnFreeOrderStruct write FOnFreeOrderStruct;
  end;

  (*
   * TPair2<T1, T2>: Simple record for two values.
   *)
  TPair2<T1, T2> = packed record
    Primary: T1;
    Second: T2;
    class function Init(Primary_: T1; Second_: T2): TPair2<T1, T2>; static;
  end;

  (*
   * TCore_Thread: Alias for TThread (the RTL thread class).
   *)
  TCore_Thread = TThread;

  {$IFDEF FPC}
  (*
   * TOnSynchronize_P_NP: Nested procedure type used for sync callbacks
   * under Free Pascal. It captures the enclosing scope's variables.
   *)
  TOnSynchronize_P_NP = procedure() is nested;
  {$ELSE FPC}
  (*
   * TOnSynchronize_P_NP: Anonymous method reference type used for sync
   * callbacks under Delphi.
   *)
  TOnSynchronize_P_NP = reference to procedure();
  {$ENDIF FPC}

  (*
   * TSoft_Synchronize_Tool: A user-space synchronisation tool that queues
   * procedures and executes them on a designated thread (the main thread).
   * It is used to implement the Sync callback variants.
   *
   * Mechanism:
   *   - The main thread (the one that calls LF_PrepareDone) is recorded
   *     as Soft_Synchronize_Main_Thread.
   *   - When Synchronize is called from a different thread, it creates a
   *     TPair2 containing the procedure and a boolean flag, pushes it onto
   *     a FIFO queue, and then busy-waits until the flag becomes False.
   *   - The main thread periodically calls Check_Synchronize, which
   *     dequeues all pending procedures and executes them, then sets the
   *     flag to False, releasing the waiting threads.
   *
   * This is a lightweight alternative to TThread.Synchronize because it
   * avoids kernel objects (events) and uses only user-mode spin-waiting.
   * It is suitable for high-frequency synchronisation.
   *
   * {!!!!!  CRITICAL - MAIN THREAD MUST CALL Check_Synchronize  !!!!!}
   * The library's progress loop automatically calls Check_Synchronize
   * periodically. If you are using the sync variants in a custom main
   * loop (without LF_PrepareDone), you must call LF_Sync() regularly.
   *)
  TSoft_Synchronize_Tool = class
  private
    type
      TSynchronize_Data___ = TPair2<TOnSynchronize_P_NP, boolean>;
      PSynchronize_Data___ = ^TSynchronize_Data___;
      TSynchronize_Queue___ = TOrderStruct<PSynchronize_Data___>;
  private
    SyncQueue__: TSynchronize_Queue___;
    Critical: TCritical;
  public
    Soft_Synchronize_Main_Thread: TCore_Thread;
    constructor Create;
    destructor Destroy; override;
    function Check_Synchronize(): nativeint;
    procedure Synchronize(OnSync: TOnSynchronize_P_NP);
  end;

(*
 * FillPtr: Fills memory with a byte value using efficient 8/4/2/1-byte
 * block writes.
 *)
procedure FillPtr(const dest: Pointer; Size: nativeuint; const Value: byte); forward;

(*
 * TCritical.Lock: Acquires the underlying critical section.
 *)
procedure TCritical.Lock;
begin
  Acquire;
end;

(*
 * TCritical.UnLock: Releases the underlying critical section.
 *)
procedure TCritical.UnLock;
begin
  Release;
end;

(*
 * TOrderStruct<T>.DoInternalFree: Calls DoFree and disposes the node.
 * Exceptions from DoFree are swallowed.
 *)
procedure TOrderStruct<T_>.DoInternalFree(const p: POrderStruct);
begin
  try
    DoFree(p^.Data);
    Dispose(p);
  except
  end;
end;

(*
 * TOrderStruct<T>.Create: Initialises an empty queue.
 *)
constructor TOrderStruct<T_>.Create;
begin
  inherited Create;
  FFirst := nil;
  FLast := nil;
  FNum := 0;
  FOnFreeOrderStruct := nil;
end;

(*
 * TOrderStruct<T>.Destroy: Clears the queue and releases resources.
 *)
destructor TOrderStruct<T_>.Destroy;
begin
  Clear;
  inherited Destroy;
end;

(*
 * TOrderStruct<T>.DoFree: Invokes the OnFree callback if assigned.
 *)
procedure TOrderStruct<T_>.DoFree(var Data: T_);
begin
  if Assigned(FOnFreeOrderStruct) then
    FOnFreeOrderStruct(Data);
end;

(*
 * TOrderStruct<T>.SwapInstance: Swaps the internal state (list head, tail,
 * count) with another TOrderStruct of the same type. The OnFree callback
 * is NOT swapped.
 *)
procedure TOrderStruct<T_>.SwapInstance(Source: TOrderStruct<T_>);
var
  FFirst_: POrderStruct;
  FLast_: POrderStruct;
  FNum_: nativeint;
begin
  FFirst_ := FFirst;
  FLast_ := FLast;
  FNum_ := FNum;
  FFirst := Source.FFirst;
  FLast := Source.FLast;
  FNum := Source.FNum;
  Source.FFirst := FFirst_;
  Source.FLast := FLast_;
  Source.FNum := FNum_;
end;

(*
 * TOrderStruct<T>.Clear: Removes and disposes all nodes in the queue.
 *)
procedure TOrderStruct<T_>.Clear;
var
  p, N_P: POrderStruct;
begin
  p := FFirst;
  while p <> nil do
  begin
    N_P := p^.Next;
    try
      DoInternalFree(p);
    except
    end;
    p := N_P;
  end;
  FFirst := nil;
  FLast := nil;
  FNum := 0;
end;

(*
 * TOrderStruct<T>.Next: Removes and disposes the head node.
 *)
procedure TOrderStruct<T_>.Next;
var
  N_P: POrderStruct;
begin
  if FFirst <> nil then
  begin
    N_P := FFirst^.Next;
    try
      DoInternalFree(FFirst);
    except
    end;
    FFirst := N_P;
    if FFirst = nil then
      FLast := nil;
    Dec(FNum);
  end;
end;

(*
 * TOrderStruct<T>.Push: Appends a new node with the given data to the
 * tail of the queue. Returns a pointer to the new node.
 *)
function TOrderStruct<T_>.Push(const Data: T_): POrderStruct;
var
  p: POrderStruct;
begin
  new(p);
  p^.Data := Data;
  p^.Next := nil;
  Inc(FNum);
  if (FFirst = nil) and (FLast = nil) then
  begin
    FFirst := p;
    FLast := p;
  end
  else if FLast <> nil then
  begin
    FLast^.Next := p;
    FLast := p;
  end;
  Result := p;
end;

(*
 * TOrderStruct<T>.Push_Null: Appends a new node with zero-initialised
 * data. Returns a pointer to the new node.
 *)
function TOrderStruct<T_>.Push_Null: POrderStruct;
var
  p: POrderStruct;
begin
  new(p);
  FillPtr(p, SizeOf(TOrderStruct_), 0);
  p^.Next := nil;
  Inc(FNum);
  if (FFirst = nil) and (FLast = nil) then
  begin
    FFirst := p;
    FLast := p;
  end
  else if FLast <> nil then
  begin
    FLast^.Next := p;
    FLast := p;
  end;
  Result := p;
end;

(*
 * TPair2<T1, T2>.Init: Static factory for creating a TPair2 record.
 *)
class function TPair2<T1, T2>.Init(Primary_: T1; Second_: T2): TPair2<T1, T2>;
begin
  Result.Primary := Primary_;
  Result.Second := Second_;
end;

(*
 * TSoft_Synchronize_Tool.Create: Initialises the sync queue and critical
 * section.
 *)
constructor TSoft_Synchronize_Tool.Create;
begin
  inherited Create;
  SyncQueue__ := TSynchronize_Queue___.Create;
  Critical := TCritical.Create;
  Soft_Synchronize_Main_Thread := nil;
end;

(*
 * TSoft_Synchronize_Tool.Destroy: Releases the sync queue and critical
 * section.
 *)
destructor TSoft_Synchronize_Tool.Destroy;
begin
  SyncQueue__.Free;
  Critical.Free;
  inherited Destroy;
end;

(*
 * TSoft_Synchronize_Tool.Check_Synchronize: Processes all pending
 * synchronisation procedures on the calling (main) thread.
 *
 * Returns the number of procedures executed.
 *
 * Called automatically by the library's progress loop. If you are running
 * a custom main loop (without LF_PrepareDone), you must call LF_Sync
 * regularly to drain the queue.
 *)
function TSoft_Synchronize_Tool.Check_Synchronize(): nativeint;
var
  Temp_SyncQueue__: TSynchronize_Queue___;
  sync_: PSynchronize_Data___;
begin
  Result := 0;
  Soft_Synchronize_Main_Thread := TCore_Thread.CurrentThread;
  Temp_SyncQueue__ := TSynchronize_Queue___.Create;
  Critical.Lock;
  Temp_SyncQueue__.SwapInstance(SyncQueue__);
  Critical.UnLock;
  while Temp_SyncQueue__.Num > 0 do
  begin
    sync_ := Temp_SyncQueue__.First^.Data;
    try
      if Assigned(sync_^.Primary) then
        sync_^.Primary();
    except
    end;
    sync_^.Second := False;
    Inc(Result);
    Temp_SyncQueue__.Next;
  end;
  Temp_SyncQueue__.Free;
end;

(*
 * TSoft_Synchronize_Tool.Synchronize: Queues a procedure to be executed
 * on the main thread.
 *
 * If the calling thread is already the main thread (or the main thread
 * has not yet been recorded), the procedure is executed immediately.
 * Otherwise, the procedure is pushed onto the sync queue and the calling
 * thread busy-waits until the main thread drains the queue.
 *)
procedure TSoft_Synchronize_Tool.Synchronize(OnSync: TOnSynchronize_P_NP);
var
  tmp: TSynchronize_Data___;
begin
  if (Soft_Synchronize_Main_Thread = nil) or (TCore_Thread.CurrentThread = Soft_Synchronize_Main_Thread) then
  begin
    try
      Check_Synchronize();
      OnSync();
    except
    end;
  end
  else
  begin
    tmp := TSynchronize_Data___.Init(OnSync, True);
    Critical.Lock;
    SyncQueue__.Push(@tmp);
    Critical.UnLock;
    while tmp.Second do TCore_Thread.Sleep(1);
  end;
end;

(* ----------------------------------------------------------------------------
  Callback Bridge Implementation
  ----------------------------------------------------------------------------

  {!!!!!  HOW THE ADAPTER WORKS - STEP BY STEP  !!!!!}

  1. When you call LF_RegisterCall_M, it stores the TMethod of your
     method in LF_EventPool (a FIFO queue) and obtains a pointer to that
     TMethod.

  2. It then calls the underlying LF_RegisterCall function, passing:
       - Trigger = address of the TMethod
       - OnCall = pointer to Do_Internal_Call__ (a cdecl procedure)

  3. When the library invokes Do_Internal_Call__, it receives the
     Trigger pointer (which is the address of the TMethod). It casts it
     back to a TMethod and uses it to call your method.

  4. For sync variants, instead of calling your method directly, the
     trampoline calls LF_SyncTool.Synchronize with an anonymous
     procedure that calls your method. This ensures your method executes
     on the main thread.

  {!!!!!  MEMORY MANAGEMENT  !!!!!}
  - The TMethod records stored in LF_EventPool are never freed until
    finalization. They remain valid for the entire lifetime of the
    application. This is safe because the number of registered APIs is
    fixed and small.
  - The Trigger pointer (address of the TMethod) is passed to the
    library, which stores it as a pointer. It is not used after the
    callback returns, so it is safe to keep the TMethod in the pool.

  {!!!!!  THREAD SAFETY  !!!!!}
  - LF_EventPool is only modified during registration (which is
    typically single-threaded). The trampolines only read from it, so
    no locking is needed.
  - The sync queue is protected by a critical section, so posting
    callbacks from multiple threads is safe.
  - The trampolines are executed on the library's internal threads,
    but they only call the Pascal method directly (or via the sync
    tool), so they are thread-safe as long as your method is.
  ---------------------------------------------------------------------------- *)

type
  (*
   * TAPI_Event_Pool: FIFO pool of registered method callbacks. Each
   * entry stores a TMethod (code + data pointer) captured at registration
   * time.
   *)
  TAPI_Event_Pool = TOrderStruct<TMethod>;

  (*
   * PM: Pointer to a TMethod record (used as the Trigger pointer).
   *)
  PM = ^TMethod;

var
  (* Pool of registered method callbacks. Populated during registration. *)
  LF_EventPool: TAPI_Event_Pool;

  (* Synchronisation tool for Sync variants. Queues callbacks to the main
    thread. *)
  LF_SyncTool: TSoft_Synchronize_Tool;

(*
 * Do_Internal_Call__: cdecl adapter for Call-mode methods.
 *
 * Retrieves the TMethod from the trigger pointer and invokes it on the
 * current (worker) thread.
 *)
procedure Do_Internal_Call__(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
var
  p: PM;
  ev: TLF_Call_M;
begin
  p := Trigger;
  ev := TLF_Call_M(p^);
  ev(Input, Output);
end;

(*
 * Do_Internal_Sync_Call__: Same as Do_Internal_Call__ but synchronises
 * the method invocation to the main thread using LF_SyncTool.
 *
 * [PITFALL] The main thread MUST periodically call LF_Sync (the library's
 *   progress loop does this automatically after LF_PrepareDone), otherwise
 *   the callback will never execute and the worker thread will block.
 *)
procedure Do_Internal_Sync_Call__(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
var
  p: PM;
  ev: TLF_Call_M;

  procedure DoSync();
  begin
    ev(Input, Output);
  end;

begin
  p := Trigger;
  ev := TLF_Call_M(p^);
  {$IFDEF FPC}
  LF_SyncTool.Synchronize(DoSync);
  {$ELSE FPC}
  LF_SyncTool.Synchronize(procedure
  begin
    ev(Input, Output);
  end);
  {$ENDIF FPC}
end;

(*
 * Do_Internal_Notify__: cdecl adapter for Notify-mode methods.
 *
 * Retrieves the TMethod from the trigger pointer and invokes it on the
 * current (worker) thread.
 *)
procedure Do_Internal_Notify__(Trigger: Pointer; Input: TDataHnd___); cdecl;
var
  p: PM;
  ev: TLF_Notify_M;
begin
  p := Trigger;
  ev := TLF_Notify_M(p^);
  ev(Input);
end;

(*
 * Do_Internal_Sync_Notify__: Synchronised version of Do_Internal_Notify__.
 *
 * [PITFALL] The main thread MUST periodically call LF_Sync.
 *)
procedure Do_Internal_Sync_Notify__(Trigger: Pointer; Input: TDataHnd___); cdecl;
var
  p: PM;
  ev: TLF_Notify_M;

  procedure DoSync();
  begin
    ev(Input);
  end;

begin
  p := Trigger;
  ev := TLF_Notify_M(p^);
  {$IFDEF FPC}
  LF_SyncTool.Synchronize(DoSync);
  {$ELSE FPC}
  LF_SyncTool.Synchronize(procedure
  begin
    ev(Input);
  end);
  {$ENDIF FPC}
end;

(*
 * LF_RegisterCall_M: Registers a non-sync Call method.
 *
 * Stores the TMethod in LF_EventPool, then registers the trampoline
 * Do_Internal_Call__ with the library. The Trigger pointer passed to the
 * library is the address of the stored TMethod.
 *)
function LF_RegisterCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
begin
  Result := LF_RegisterCallEx(appHnd, MethodName, Desc, @LF_EventPool.Push(TMethod(OnCall)).Data, Do_Internal_Call__);
end;

(*
 * LF_RegisterSyncCall_M: Registers a synchronised Call method.
 *
 * The callback is queued to the main thread via LF_SyncTool. Requires
 * the main thread to call LF_Sync periodically.
 *)
function LF_RegisterSyncCall_M(appHnd: TAppHnd___; MethodName, Desc: string; OnCall: TLF_Call_M): integer;
begin
  Result := LF_RegisterCallEx(appHnd, MethodName, Desc, @LF_EventPool.Push(TMethod(OnCall)).Data, Do_Internal_Sync_Call__);
end;

(*
 * LF_RegisterNotify_M: Registers a non-sync Notify method.
 *)
function LF_RegisterNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
begin
  Result := LF_RegisterNotifyEx(appHnd, MethodName, Desc, @LF_EventPool.Push(TMethod(OnNotify)).Data, Do_Internal_Notify__);
end;

(*
 * LF_RegisterSyncNotify_M: Registers a synchronised Notify method.
 *)
function LF_RegisterSyncNotify_M(appHnd: TAppHnd___; MethodName, Desc: string; OnNotify: TLF_Notify_M): integer;
begin
  Result := LF_RegisterNotifyEx(appHnd, MethodName, Desc, @LF_EventPool.Push(TMethod(OnNotify)).Data, Do_Internal_Sync_Notify__);
end;

(*
 * LF_Sync: Processes any pending sync callbacks.
 * Returns the number of callbacks executed.
 *)
function LF_Sync(): integer;
begin
  Result := LF_SyncTool.Check_Synchronize();
end;

(* ----------------------------------------------------------------------------
  FillPtr Implementation
  ---------------------------------------------------------------------------- *)

(*
 * FillPtr: Fills memory with a byte value using 8/4/2/1-byte block writes
 * for efficiency. The 8-byte pattern is replicated across the whole block.
 *)
procedure FillPtr(const dest: Pointer; Size: nativeuint; const Value: byte);
var
  d: pbyte;
  v: uint64;
begin
  if Size = 0 then Exit;
  v := Value or (Value shl 8) or (Value shl 16) or (Value shl 24);
  v := v or (v shl 32);
  d := dest;
  while Size >= 8 do
  begin
    PUInt64(d)^ := v;
    Dec(Size, 8);
    Inc(d, 8);
  end;
  if Size >= 4 then
  begin
    PCardinal(d)^ := PCardinal(@v)^;
    Dec(Size, 4);
    Inc(d, 4);
  end;
  if Size >= 2 then
  begin
    PWORD(d)^ := PWORD(@v)^;
    Dec(Size, 2);
    Inc(d, 2);
  end;
  if Size > 0 then
    d^ := Value;
end;

(* ----------------------------------------------------------------------------
  Initialization / Finalization
  ----------------------------------------------------------------------------

  {!!!!!  AUTOMATIC SHUTDOWN IN EXECUTABLE  !!!!!}
  - In an executable (not a library), the finalization section calls
    LF_Shutdown automatically to clean up resources.
  - In a library (DLL), the shutdown is NOT automatic because the
    library may be unloaded by the host process before finalization.
    You MUST call LF_Shutdown explicitly before unloading your library
    to avoid resource leaks.

  {!!!!!  INITIALIZATION ORDER  !!!!!}
  - The unit initializes the event pool and sync tool before any
    external calls can be made. This ensures that the callback adapter
    is ready when you register APIs.

  {!!!!!  CONSOLE OUTPUT SETTING  !!!!!}
  - If the application is a console application (IsConsole = True),
    the unit automatically sets ConsoleOutput to True to enable log
    messages. In GUI applications, it sets it to False. You can
    override this with LF_SetOption('ConsoleOutput', 'True/False').
  ---------------------------------------------------------------------------- *)

(*
 * Do_Init: Called during unit initialization. Creates the event pool
 * and sync tool, and sets the console output option based on the
 * application type (console vs GUI).
 *)
procedure Do_Init();
begin
  LF_EventPool := TAPI_Event_Pool.Create;
  LF_SyncTool := TSoft_Synchronize_Tool.Create;
  if not IsLibrary then
  begin
    if IsConsole then
      LF_SetOptionEx('ConsoleOutput', 'True')
    else
      LF_SetOptionEx('ConsoleOutput', 'False');
  end;
end;

(*
 * Do_Free: Called during unit finalization. Releases the event pool and
 * sync tool.
 *)
procedure Do_Free;
begin
  LF_EventPool.Free;
  LF_EventPool := nil;
  LF_SyncTool.Free;
  LF_SyncTool := nil;
end;

initialization

  Do_Init();

finalization

  Do_Free();

end.
