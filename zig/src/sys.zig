// =============================================================================
//  sys.zig - Raw C ABI declarations for the LingoFuse native library.
// -----------------------------------------------------------------------------
//  This file is the ONLY place in the binding that declares the C ABI
//  surface. Every other module accesses the native functions through
//  the re-exports defined here.
//
//  Why hand-written extern declarations
//  ------------------------------------
//  Zig 0.15 removed the `@cImport` builtin. The recommended
//  replacement is either a build-time `translate-c` pass or
//  hand-written `extern fn` declarations. This binding chooses the
//  hand-written form because:
//
//      * The C ABI is small (37 functions, 3 callback types, 2 handle
//        types) and stable.
//      * Hand-written declarations give an exact Zig-side type for
//        every parameter, which catches mismatch at compile time.
//      * No build-time code generation step is required.
//
//  The declarations below are a one-to-one mirror of `LingoFuse.h`.
//  Keep them in sync when the C header changes.
//
//  Link-time contract
//  ------------------
//  These declarations resolve to symbols provided by `LingoFuse.c`
//  (the dynamic loader), NOT by the runtime library directly. That
//  file is compiled into every artifact that uses this module.
//
//  Runtime contract
//  ----------------
//  Before any function other than `LF_LoadLibrary` is called, the
//  process must have called `LF_LoadLibrary` and obtained a 1 return.
//  The `framework.init` helper calls it and returns an error on
//  failure.
// =============================================================================

// =============================================================================
// Handle types
// =============================================================================
//
// In the C ABI both handles are `typedef void*`. In Zig the canonical
// representation of a C `void*` is `?*anyopaque`: nullable, unaligned,
// pointer-sized.

/// Opaque data-handle pointer. C: `typedef void* TDataHnd;`.
pub const DataHnd = ?*anyopaque;

/// Opaque application-handle pointer. C: `typedef void* TAppHnd;`.
pub const AppHnd = ?*anyopaque;

// =============================================================================
// Callback prototypes
// =============================================================================
//
// All three are `cdecl`. A null function pointer means "not installed".

/// Call-mode (request-response) callback.
pub const CallFunc = *const fn (
    trigger: ?*anyopaque,
    input: DataHnd,
    output: DataHnd,
) callconv(.c) void;

/// Notify-mode (one-way) callback.
pub const NotifyFunc = *const fn (
    trigger: ?*anyopaque,
    input: DataHnd,
) callconv(.c) void;

/// Network connect/disconnect callback.
pub const NetworkEventFunc = *const fn (
    addr: ?[*:0]const u8,
) callconv(.c) void;

// =============================================================================
// Dynamic loader (provided by LingoFuse.c, not by the runtime)
// =============================================================================

/// `LF_LoadLibrary` - load the runtime. Returns 1 on success, 0 on failure.
pub extern fn LF_LoadLibrary() c_int;
pub const loadLibrary = LF_LoadLibrary;

/// `LF_FreeLibrary` - unload the runtime. Safe to call multiple times.
pub extern fn LF_FreeLibrary() void;
pub const freeLibrary = LF_FreeLibrary;

// =============================================================================
// Data-handle operations
// =============================================================================

/// `LF_CreateData` - auto-recycled data handle.
pub extern fn LF_CreateData(method_name: ?[*:0]const u8) DataHnd;
pub const createData = LF_CreateData;

/// `LF_CreateData_Permanent` - permanent data handle.
pub extern fn LF_CreateData_Permanent(method_name: ?[*:0]const u8) DataHnd;
pub const createDataPermanent = LF_CreateData_Permanent;

/// `LF_FreeData` - release a data handle. Null handles are ignored.
pub extern fn LF_FreeData(hnd: DataHnd) void;
pub const freeData = LF_FreeData;

/// `LF_GetBuffer` - raw pointer to the internal buffer.
pub extern fn LF_GetBuffer(hnd: DataHnd) ?*anyopaque;
pub const getBuffer = LF_GetBuffer;

/// `LF_WriteBuffer` - write bytes at the cursor; auto-grows.
pub extern fn LF_WriteBuffer(hnd: DataHnd, buff: [*]const u8, size: i64) i64;
pub const writeBuffer = LF_WriteBuffer;

/// `LF_ReadBuffer` - read bytes at the cursor; advances the cursor.
pub extern fn LF_ReadBuffer(hnd: DataHnd, buff: [*]u8, size: i64) i64;
pub const readBuffer = LF_ReadBuffer;

/// `LF_GetPos` - current cursor position.
pub extern fn LF_GetPos(hnd: DataHnd) i64;
pub const getPos = LF_GetPos;

/// `LF_SetPos` - set the cursor position; may grow the buffer.
pub extern fn LF_SetPos(hnd: DataHnd, pos: i64) void;
pub const setPos = LF_SetPos;

/// `LF_GetSize` - total buffer size in bytes.
pub extern fn LF_GetSize(hnd: DataHnd) i64;
pub const getSize = LF_GetSize;

/// `LF_SetSize` - resize the buffer; new bytes are uninitialised.
pub extern fn LF_SetSize(hnd: DataHnd, size: i64) void;
pub const setSize = LF_SetSize;

// =============================================================================
// Application-handle operations
// =============================================================================

/// `LF_CreateApp` - create a named application container.
pub extern fn LF_CreateApp(
    app_name: ?[*:0]const u8,
    desc: ?[*:0]const u8,
) AppHnd;
pub const createApp = LF_CreateApp;

/// `LF_FreeApp` - detach an application.
pub extern fn LF_FreeApp(app_hnd: AppHnd) void;
pub const freeApp = LF_FreeApp;

/// `LF_Generate_AppName` - unique name; pointer valid for ~5 seconds.
pub extern fn LF_Generate_AppName() ?[*:0]const u8;
pub const generateAppName = LF_Generate_AppName;

/// `LF_Get_AppName` - name of an existing handle; ~5-second pointer lifetime.
pub extern fn LF_Get_AppName(app_hnd: AppHnd) ?[*:0]const u8;
pub const getAppName = LF_Get_AppName;

/// `LF_BindApp` - bind an application to all currently-unbound clients.
pub extern fn LF_BindApp(app_hnd: AppHnd) c_int;
pub const bindApp = LF_BindApp;

// =============================================================================
// API registration
// =============================================================================

/// `LF_RegisterCall` - register a Call (request-response) API.
pub extern fn LF_RegisterCall(
    app_hnd: AppHnd,
    method_name: ?[*:0]const u8,
    desc: ?[*:0]const u8,
    trigger: ?*anyopaque,
    on_call: CallFunc,
) c_int;
pub const registerCall = LF_RegisterCall;

/// `LF_RegisterNotify` - register a Notify (one-way) API.
pub extern fn LF_RegisterNotify(
    app_hnd: AppHnd,
    method_name: ?[*:0]const u8,
    desc: ?[*:0]const u8,
    trigger: ?*anyopaque,
    on_notify: NotifyFunc,
) c_int;
pub const registerNotify = LF_RegisterNotify;

/// `LF_Unregister` - remove a registered API by name.
pub extern fn LF_Unregister(
    app_hnd: AppHnd,
    method_name: ?[*:0]const u8,
) c_int;
pub const unregister = LF_Unregister;

// =============================================================================
// Local execution
// =============================================================================

/// `LF_LocalCall` - invoke a Call API within the same process.
pub extern fn LF_LocalCall(app_hnd: AppHnd, param: DataHnd) DataHnd;
pub const localCall = LF_LocalCall;

/// `LF_LocalNotify` - invoke a Notify API within the same process.
pub extern fn LF_LocalNotify(app_hnd: AppHnd, param: DataHnd) void;
pub const localNotify = LF_LocalNotify;

// =============================================================================
// Network preparation
// =============================================================================

/// `LF_ResetPrepare` - clear the preparation queue.
pub extern fn LF_ResetPrepare() void;
pub const resetPrepare = LF_ResetPrepare;

/// `LF_PrepareService` - prepare a C4 service; returns a tag, or -1.
pub extern fn LF_PrepareService(
    listening_addr: ?[*:0]const u8,
    physics_addr: ?[*:0]const u8,
) c_int;
pub const prepareService = LF_PrepareService;

/// `LF_PrepareClient` - prepare a C4 client; returns a tag, or -1.
pub extern fn LF_PrepareClient(
    physics_addr: ?[*:0]const u8,
    app_hnd: AppHnd,
) c_int;
pub const prepareClient = LF_PrepareClient;

/// `LF_PrepareDone` - start the framework. Returns 1 only once per process.
pub extern fn LF_PrepareDone() c_int;
pub const prepareDone = LF_PrepareDone;

/// `LF_ExitMainThread` - stop the simulated main thread.
pub extern fn LF_ExitMainThread() void;
pub const exitMainThread = LF_ExitMainThread;

// =============================================================================
// Remote invocation
// =============================================================================

/// `LF_Call` - synchronous remote call. Never returns a null handle.
pub extern fn LF_Call(
    app_name: ?[*:0]const u8,
    param: DataHnd,
    timeout_ms: u64,
) DataHnd;
pub const call = LF_Call;

/// `LF_Notify` - best-effort one-way notification.
pub extern fn LF_Notify(app_name: ?[*:0]const u8, param: DataHnd) void;
pub const notify = LF_Notify;

/// `LF_Sequenced_Notify` - FIFO-ordered one-way notification.
pub extern fn LF_Sequenced_Notify(
    app_name: ?[*:0]const u8,
    param: DataHnd,
) void;
pub const sequencedNotify = LF_Sequenced_Notify;

// =============================================================================
// Options and diagnostics
// =============================================================================

/// `LF_SetOption` - adjust a global runtime option.
pub extern fn LF_SetOption(
    option: ?[*:0]const u8,
    value: ?[*:0]const u8,
) void;
pub const setOption = LF_SetOption;

/// `LF_GetStatusCount` - number of pending log messages.
pub extern fn LF_GetStatusCount() c_int;
pub const getStatusCount = LF_GetStatusCount;

/// `LF_GetStatus` - retrieve the next log message (static buffer).
pub extern fn LF_GetStatus() ?[*:0]const u8;
pub const getStatus = LF_GetStatus;

/// `LF_PostStatus` - inject a log message.
pub extern fn LF_PostStatus(status: ?[*:0]const u8) void;
pub const postStatus = LF_PostStatus;

/// `LF_CheckMainThread` - 1 when the simulated main thread is running.
pub extern fn LF_CheckMainThread() c_int;
pub const checkMainThread = LF_CheckMainThread;

/// `LF_CheckApp` - 1 when the named app is visible on the mesh.
pub extern fn LF_CheckApp(app_name: ?[*:0]const u8) c_int;
pub const checkApp = LF_CheckApp;

/// `LF_CheckApi` - 1 when the named API is visible on the mesh.
pub extern fn LF_CheckApi(
    app_name: ?[*:0]const u8,
    api_name: ?[*:0]const u8,
) c_int;
pub const checkApi = LF_CheckApi;

// =============================================================================
// Shutdown and network events
// =============================================================================

/// `LF_Shutdown` - graceful full shutdown; releases all resources.
pub extern fn LF_Shutdown() void;
pub const shutdown = LF_Shutdown;

/// `LF_Set_Network_Event` - install/replace the process-global callbacks.
pub extern fn LF_Set_Network_Event(
    on_connect: ?NetworkEventFunc,
    on_disconnect: ?NetworkEventFunc,
) void;
pub const setNetworkEvent = LF_Set_Network_Event;
