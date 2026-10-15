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
//      * The C ABI is small and stable.
//      * Hand-written declarations give an exact Zig-side type for
//        every parameter, which catches mismatch at compile time.
//      * No build-time code generation step is required.
//
//  The declarations below are a one-to-one mirror of `LingoFuse.h`.
//  Keep them in sync when the C header changes.
//
//  Coverage
//  --------
//  The runtime exports 59 symbols across 14 groups; this file declares
//  all 59, plus the two loader functions that are provided by
//  `LingoFuse.c` (the C wrapper), not by the runtime itself:
//
//      Data-handle operations (12)
//          LF_CreateData, LF_CreateData_Permanent, LF_FreeData,
//          LF_GetBuffer, LF_WriteBuffer, LF_ReadBuffer,
//          LF_GetPos, LF_SetPos, LF_GetSize, LF_SetSize,
//          LF_Get_P2P_UID, LF_Get_P2P_Name
//
//      Application-handle operations (5)
//          LF_CreateApp, LF_FreeApp,
//          LF_Generate_AppName, LF_Get_AppName, LF_BindApp
//
//      API registration, app-bound (3)
//          LF_RegisterCall, LF_RegisterNotify, LF_Unregister
//
//      API registration, process-wide P2P (3)
//          LF_Register_P2P_Call, LF_Register_P2P_Notify,
//          LF_Unregister_P2P
//
//      Local execution (2)
//          LF_LocalCall, LF_LocalNotify
//
//      Network preparation (5)
//          LF_ResetPrepare, LF_PrepareService, LF_PrepareClient,
//          LF_PrepareDone, LF_ExitMainThread
//
//      Remote invocation, App-name addressing (5)
//          LF_Call, LF_Async_Call, LF_Async_Sequenced_Call,
//          LF_Notify, LF_Sequenced_Notify
//
//      Remote invocation, UID addressing (5)
//          LF_UID_Call, LF_UID_Async_Call, LF_UID_Async_Sequenced_Call,
//          LF_UID_Notify, LF_UID_Sequenced_Notify
//
//      Remote invocation, P2PName addressing (5)
//          LF_P2PNAME_Call, LF_P2PNAME_Async_Call,
//          LF_P2PNAME_Async_Sequenced_Call,
//          LF_P2PNAME_Notify, LF_P2PNAME_Sequenced_Notify
//
//      Queries (7)
//          LF_CheckMainThread, LF_CheckApp, LF_CheckApi,
//          LF_Check_UID, LF_Check_UID_Api,
//          LF_Check_P2PNAME, LF_Check_P2PNAME_Api
//
//      Options (2)
//          LF_SetOption, LF_GetOption
//
//      Status (3)
//          LF_GetStatusCount, LF_GetStatus, LF_PostStatus
//
//      Network events (1)
//          LF_Set_Network_Event
//
//      Shutdown (1)
//          LF_Shutdown
//
//      Loader (2) - provided by `LingoFuse.c`, not by the runtime
//          LF_LoadLibrary, LF_FreeLibrary
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
//
//  ABI note - the two roles of `TP2P_UID`
//  --------------------------------------
//  The Pascal-side type `TP2P_UID___` is `array[0..31] of Byte`. In C
//  it is wrapped in a struct so that it can be passed by value across
//  the cdecl boundary:
//
//      typedef struct TP2P_UID_s { uint8_t bytes[32]; } TP2P_UID;
//
//  The same Pascal type plays two DIFFERENT roles at the C ABI, and
//  each role requires a DIFFERENT Zig-side representation:
//
//      ARGUMENT role   : P2PUid (the extern struct, passed by value)
//      RETURN   role   : ?*const P2PUid (a pointer, LF_Get_P2P_UID only)
//
//  DO NOT unify the two. The `uid.zig` module provides a single safe
//  `Uid` newtype that bridges both roles.
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
// P2P UID value type
// =============================================================================

/// The 32-byte P2P session identifier, in ABI form.
///
/// This is the Zig mirror of the C type `TP2P_UID`. The struct is
/// declared `extern` so that its layout is guaranteed to match the C
/// struct byte-for-byte, including alignment and padding.
///
/// # Role distinction
///
/// This type is used BY VALUE in argument position only. The
/// return-role instance (`LF_Get_P2P_UID`) returns `?*const P2PUid`,
/// not a value.
///
/// # ABI compatibility
///
/// On x86-64 (both System V AMD64 and Microsoft x64), a >16-byte
/// aggregate is classified MEMORY by the psABI and is therefore passed
/// on the stack. FPC's `array[0..31] of Byte` falls into the same
/// MEMORY class, so this struct is ABI-compatible for the
/// argument-role positions.
///
/// # Higher-level type
///
/// Most callers should use `uid.Uid`, which wraps this type and
/// provides hex conversion, formatting, and safe bridging for both
/// roles. Use `P2PUid` directly only if you are implementing a new
/// wrapper and need the raw ABI shape.
pub const P2PUid = extern struct {
    /// The 32 raw UID octets, in wire order.
    bytes: [32]u8,

    /// The all-zero UID ("null UID").
    ///
    /// `@splat(0)` is used instead of the `**` array-repeat operator
    /// on purpose. Zig requires `**` to have matching whitespace on
    /// both sides; any tool that normalises whitespace can silently
    /// break that rule. `@splat` has no such dependency.
    pub const NULL: P2PUid = .{ .bytes = @splat(0) };

    /// Returns `true` when all 32 bytes are zero.
    pub fn isNull(self: P2PUid) bool {
        for (self.bytes) |b| {
            if (b != 0) return false;
        }
        return true;
    }
};

// =============================================================================
// Callback prototypes
// =============================================================================
//
// All are `cdecl`. A null function pointer means "not installed".

/// Call-mode (request-response) callback.
///
/// # Contract
///
/// - Runs on a native worker thread.
/// - Must not block.
/// - Must not call any blocking LingoFuse function
///   (`LF_Call`, `LF_LocalCall`, `LF_PrepareDone`, `LF_Shutdown`).
/// - Must not unwind. Zig `callconv(.c)` functions do not unwind
///   cleanly, so panics must be avoided at the call site.
/// - Must not free `input` or `output`.
pub const CallFunc = *const fn (
    trigger: ?*anyopaque,
    input: DataHnd,
    output: DataHnd,
) callconv(.c) void;

/// Notify-mode (one-way) callback.
///
/// Same contract as `CallFunc`, minus the output handle.
pub const NotifyFunc = *const fn (
    trigger: ?*anyopaque,
    input: DataHnd,
) callconv(.c) void;

/// Network connect / disconnect callback.
///
/// # Parameter
///
/// `addr` is a UTF-8, NUL-terminated endpoint string. The buffer is
/// valid ONLY during the callback invocation; the native library
/// releases it as soon as the callback returns. Copy the string
/// immediately if you need to retain it.
pub const NetworkEventFunc = *const fn (
    addr: ?[*:0]const u8,
) callconv(.c) void;

/// Asynchronous Call result callback.
///
/// Used by every `LF_Async_*` function:
///
///     LF_Async_Call
///     LF_Async_Sequenced_Call
///     LF_UID_Async_Call
///     LF_UID_Async_Sequenced_Call
///     LF_P2PNAME_Async_Call
///     LF_P2PNAME_Async_Sequenced_Call
///
/// # Parameters
///
/// - `data`:   The opaque pointer supplied by the caller at the call
///             site. The library neither owns nor frees it. Ownership
///             transfer is the caller's responsibility.
/// - `result`: A `DataHnd` OWNED BY THE FRAMEWORK. It is released
///             IMMEDIATELY after this callback returns.
///
/// # Contract
///
/// The `result` handle is released IMMEDIATELY after this callback
/// returns. The callback MUST:
///
///   - Read or copy everything it needs inside the callback body.
///   - NOT call `LF_FreeData` on `result`.
///   - NOT retain the handle past the callback body.
///
/// This is the OPPOSITE of the synchronous family
/// (`LF_Call` / `LF_UID_Call` / `LF_P2PNAME_Call`), whose returned
/// handle is owned by the CALLER and MUST be released with
/// `LF_FreeData`.
///
/// # Threading
///
/// The callback runs on a `TCompute` worker thread. It is NOT the
/// caller's thread and NOT the simulated main thread.
pub const AsyncCallOnResult = *const fn (
    data: ?*anyopaque,
    result: DataHnd,
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
// Data-handle operations (12)
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

/// `LF_SetPos` - set the cursor position.
pub extern fn LF_SetPos(hnd: DataHnd, pos: i64) void;
pub const setPos = LF_SetPos;

/// `LF_GetSize` - total buffer size in bytes.
pub extern fn LF_GetSize(hnd: DataHnd) i64;
pub const getSize = LF_GetSize;

/// `LF_SetSize` - resize the buffer; new bytes are uninitialised.
pub extern fn LF_SetSize(hnd: DataHnd, size: i64) void;
pub const setSize = LF_SetSize;

/// `LF_Get_P2P_UID` - read the sender's injected UID from an INPUT handle.
///
/// # Side-data semantics
///
/// This function does NOT read a property of the handle itself. It
/// reads the "side data" that the sender's transport layer writes into
/// every request payload before transmission. The receiver therefore
/// sees the UID only inside the `Data_Param` of the INPUT handle that
/// the framework delivers to a registered callback.
///
/// **Valid only on input handles:**
///
///   - The `input` argument of a `CallFunc` callback.
///   - The `input` argument of a `NotifyFunc` callback.
///   - The input handle of a local call / notify.
///
/// **Invalid on:**
///
///   - Output handles (no `Data_Param`).
///   - Caller-created handles (`LF_CreateData` / `LF_CreateData_Permanent`).
///
/// In the invalid cases the native library logs a warning and returns
/// a pointer to a zero-filled UID.
///
/// # Return value
///
/// A pointer to a 32-byte `P2PUid`, allocated by the native library
/// and scheduled for automatic release approximately 5 seconds after
/// the call. The caller MUST:
///
///   1. Copy the 32 bytes immediately if the value is to be retained.
///   2. NOT call any deallocation function on the pointer.
///   3. NOT retain the pointer beyond the ~5-second window.
///
/// The `uid.zig` module's `Uid.fromPtr` helper encapsulates all three
/// rules. Prefer `DataHandle.p2pUid()` over calling this directly.
pub extern fn LF_Get_P2P_UID(hnd: DataHnd) ?*const P2PUid;
pub const getP2PUid = LF_Get_P2P_UID;

/// `LF_Get_P2P_Name` - read the sender's injected P2P name from an INPUT handle.
///
/// # Side-data semantics
///
/// Same identity-injection mechanism as `LF_Get_P2P_UID`. This
/// function reads the `FromP2PName` field that the sender's transport
/// layer wrote into the payload header; it does NOT read a property of
/// the handle itself.
///
/// **Valid only on input handles**: the `input` argument of a
/// `CallFunc` / `NotifyFunc` callback, or the input of a local call.
/// On output handles and on caller-created handles, the native library
/// logs a warning and returns an empty string.
///
/// # Return value
///
/// A pointer to a UTF-8, NUL-terminated string in a transient buffer
/// released approximately 5 seconds after the call. The caller MUST
/// copy the string immediately if it is to be retained, and MUST NOT
/// free the pointer.
///
/// The `util.copyCstr` helper copies the string into an allocator-owned
/// slice. Prefer `DataHandle.p2pName()` over calling this directly.
pub extern fn LF_Get_P2P_Name(hnd: DataHnd) ?[*:0]const u8;
pub const getP2PName = LF_Get_P2P_Name;

// =============================================================================
// Application-handle operations (5)
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
// API registration, app-bound (3)
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
// API registration, process-wide P2P (3)
// =============================================================================
//
// The process-wide P2P namespace is INDEPENDENT of any App. APIs
// registered here are reachable via UID addressing and P2PName
// addressing ONLY. They are NOT reachable via App-name addressing,
// even if the API name happens to match a registered App name.
//
// Typical use: globally-discoverable utility APIs (health probes,
// capability discovery, identity echo) that any client in the mesh
// can call by UID or by P2PName without knowing the target's App name.

/// `LF_Register_P2P_Call` - register a process-wide P2P Call API.
pub extern fn LF_Register_P2P_Call(
    method_name: ?[*:0]const u8,
    desc: ?[*:0]const u8,
    trigger: ?*anyopaque,
    on_call: CallFunc,
) c_int;
pub const registerP2PCall = LF_Register_P2P_Call;

/// `LF_Register_P2P_Notify` - register a process-wide P2P Notify API.
pub extern fn LF_Register_P2P_Notify(
    method_name: ?[*:0]const u8,
    desc: ?[*:0]const u8,
    trigger: ?*anyopaque,
    on_notify: NotifyFunc,
) c_int;
pub const registerP2PNotify = LF_Register_P2P_Notify;

/// `LF_Unregister_P2P` - remove a process-wide P2P API by name.
///
/// Does NOT affect app-bound APIs of the same name.
pub extern fn LF_Unregister_P2P(method_name: ?[*:0]const u8) c_int;
pub const unregisterP2P = LF_Unregister_P2P;

// =============================================================================
// Local execution (2)
// =============================================================================

/// `LF_LocalCall` - invoke a Call API within the same process.
pub extern fn LF_LocalCall(app_hnd: AppHnd, param: DataHnd) DataHnd;
pub const localCall = LF_LocalCall;

/// `LF_LocalNotify` - invoke a Notify API within the same process.
pub extern fn LF_LocalNotify(app_hnd: AppHnd, param: DataHnd) void;
pub const localNotify = LF_LocalNotify;

// =============================================================================
// Network preparation (5)
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
// Remote invocation, App-name addressing (5)
// =============================================================================

/// `LF_Call` - synchronous remote call. Never returns a null handle.
pub extern fn LF_Call(
    app_name: ?[*:0]const u8,
    param: DataHnd,
    timeout_ms: u64,
) DataHnd;
pub const call = LF_Call;

/// `LF_Async_Call` - asynchronous remote call by App name.
pub extern fn LF_Async_Call(
    app_name: ?[*:0]const u8,
    param: DataHnd,
    data: ?*anyopaque,
    on_result: AsyncCallOnResult,
) c_int;
pub const asyncCall = LF_Async_Call;

/// `LF_Async_Sequenced_Call` - asynchronous FIFO call by App name.
pub extern fn LF_Async_Sequenced_Call(
    app_name: ?[*:0]const u8,
    param: DataHnd,
    data: ?*anyopaque,
    on_result: AsyncCallOnResult,
) c_int;
pub const asyncSequencedCall = LF_Async_Sequenced_Call;

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
// Remote invocation, UID addressing (5)
// =============================================================================
//
// UID addressing routes to the exact client whose tunnel established
// the given 32-byte session identifier. It is session-level: the UID
// is regenerated on every reconnect, so a caller that caches a UID
// MUST re-probe it after a link loss.
//
// UID routing is LOCAL-FIRST, matching App-name routing. A UID can
// address any API registered on the target -- whether app-bound or
// process-wide P2P -- without the caller knowing the target's App name.
//
// The `uid` parameter is the ARGUMENT-role `P2PUid` (the struct, passed
// by value). Do NOT change it to a pointer; that would break the ABI.

/// `LF_UID_Call` - synchronous remote call addressed by session UID.
pub extern fn LF_UID_Call(
    uid: P2PUid,
    param: DataHnd,
    timeout_ms: u64,
) DataHnd;
pub const uidCall = LF_UID_Call;

/// `LF_UID_Async_Call` - asynchronous call addressed by session UID.
pub extern fn LF_UID_Async_Call(
    uid: P2PUid,
    param: DataHnd,
    data: ?*anyopaque,
    on_result: AsyncCallOnResult,
) c_int;
pub const uidAsyncCall = LF_UID_Async_Call;

/// `LF_UID_Async_Sequenced_Call` - asynchronous FIFO call by session UID.
pub extern fn LF_UID_Async_Sequenced_Call(
    uid: P2PUid,
    param: DataHnd,
    data: ?*anyopaque,
    on_result: AsyncCallOnResult,
) c_int;
pub const uidAsyncSequencedCall = LF_UID_Async_Sequenced_Call;

/// `LF_UID_Notify` - one-way notification addressed by session UID.
pub extern fn LF_UID_Notify(uid: P2PUid, param: DataHnd) void;
pub const uidNotify = LF_UID_Notify;

/// `LF_UID_Sequenced_Notify` - FIFO notification by session UID.
pub extern fn LF_UID_Sequenced_Notify(uid: P2PUid, param: DataHnd) void;
pub const uidSequencedNotify = LF_UID_Sequenced_Notify;

// =============================================================================
// Remote invocation, P2PName addressing (5)
// =============================================================================
//
// P2PName addressing routes to any client in a user-defined group. It
// is NOT local-first: the call is always forwarded to the server,
// which owns the load-balancing state.
//
// Target selection on the server uses one of two strategies:
//
//   - Load balancing (Cycle_Anchor): the target with the smallest
//     anchor value is chosen, then its anchor is advanced.
//   - Sticky affinity (FixedSequenced), governed by the
//     `Fixed_Sequenced_Time` runtime option (default 20 seconds).

/// `LF_P2PNAME_Call` - synchronous remote call by P2P group name.
pub extern fn LF_P2PNAME_Call(
    p2p_name: ?[*:0]const u8,
    param: DataHnd,
    timeout_ms: u64,
) DataHnd;
pub const p2pnameCall = LF_P2PNAME_Call;

/// `LF_P2PNAME_Async_Call` - asynchronous call by P2P group name.
pub extern fn LF_P2PNAME_Async_Call(
    p2p_name: ?[*:0]const u8,
    param: DataHnd,
    data: ?*anyopaque,
    on_result: AsyncCallOnResult,
) c_int;
pub const p2pnameAsyncCall = LF_P2PNAME_Async_Call;

/// `LF_P2PNAME_Async_Sequenced_Call` - asynchronous FIFO call by P2P group name.
pub extern fn LF_P2PNAME_Async_Sequenced_Call(
    p2p_name: ?[*:0]const u8,
    param: DataHnd,
    data: ?*anyopaque,
    on_result: AsyncCallOnResult,
) c_int;
pub const p2pnameAsyncSequencedCall = LF_P2PNAME_Async_Sequenced_Call;

/// `LF_P2PNAME_Notify` - one-way notification by P2P group name.
pub extern fn LF_P2PNAME_Notify(
    p2p_name: ?[*:0]const u8,
    param: DataHnd,
) void;
pub const p2pnameNotify = LF_P2PNAME_Notify;

/// `LF_P2PNAME_Sequenced_Notify` - FIFO notification by P2P group name.
pub extern fn LF_P2PNAME_Sequenced_Notify(
    p2p_name: ?[*:0]const u8,
    param: DataHnd,
) void;
pub const p2pnameSequencedNotify = LF_P2PNAME_Sequenced_Notify;

// =============================================================================
// Queries (7)
// =============================================================================
//
// All queries consult a LOCALLY CACHED view of the mesh, updated by
// periodic broadcasts with a typical propagation delay of about 3
// seconds. A query can return false negatives shortly after a
// registration and false positives shortly after an unregistration.
// Use them as probing tools, not as authoritative existence tests.
// For critical decisions, call the target API directly and handle
// timeouts gracefully.

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

/// `LF_Check_UID` - 1 when a client with the given UID is registered.
///
/// The UID is passed as the ARGUMENT-role `P2PUid` (the struct).
pub extern fn LF_Check_UID(uid: P2PUid) c_int;
pub const checkUid = LF_Check_UID;

/// `LF_Check_UID_Api` - 1 when a client with the given UID exposes the named API.
pub extern fn LF_Check_UID_Api(
    uid: P2PUid,
    api_name: ?[*:0]const u8,
) c_int;
pub const checkUidApi = LF_Check_UID_Api;

/// `LF_Check_P2PNAME` - 1 when a client with the given P2P group name is registered.
pub extern fn LF_Check_P2PNAME(p2p_name: ?[*:0]const u8) c_int;
pub const checkP2PName = LF_Check_P2PNAME;

/// `LF_Check_P2PNAME_Api` - 1 when a client in the given P2P group exposes the named API.
pub extern fn LF_Check_P2PNAME_Api(
    p2p_name: ?[*:0]const u8,
    api_name: ?[*:0]const u8,
) c_int;
pub const checkP2PNameApi = LF_Check_P2PNAME_Api;

// =============================================================================
// Options and diagnostics (2 + 3)
// =============================================================================

/// `LF_SetOption` - adjust a global runtime option.
///
/// Unknown option names are silently ignored by the native layer.
pub extern fn LF_SetOption(
    option: ?[*:0]const u8,
    value: ?[*:0]const u8,
) void;
pub const setOption = LF_SetOption;

/// `LF_GetOption` - read a global runtime option.
///
/// The returned pointer targets a transient buffer released about 5
/// seconds after the call. The caller MUST copy the string immediately
/// if it is to be retained, and MUST NOT free the pointer.
///
/// Unknown option names return an empty string. Some options are
/// write-only (for example `debug`); their getter returns a fixed
/// placeholder string.
pub extern fn LF_GetOption(option: ?[*:0]const u8) ?[*:0]const u8;
pub const getOption = LF_GetOption;

/// `LF_GetStatusCount` - number of pending log messages.
pub extern fn LF_GetStatusCount() c_int;
pub const getStatusCount = LF_GetStatusCount;

/// `LF_GetStatus` - retrieve the next log message (static buffer).
///
/// The returned pointer targets a process-wide static buffer that the
/// next call to this function overwrites. Copy the string immediately
/// if it is to be retained.
pub extern fn LF_GetStatus() ?[*:0]const u8;
pub const getStatus = LF_GetStatus;

/// `LF_PostStatus` - inject a log message.
pub extern fn LF_PostStatus(status: ?[*:0]const u8) void;
pub const postStatus = LF_PostStatus;

// =============================================================================
// Network events (1)
// =============================================================================

/// `LF_Set_Network_Event` - install/replace the process-global callbacks.
///
/// This is a REPLACE operation, not a patch. Passing a null pointer for
/// either argument disables that event.
pub extern fn LF_Set_Network_Event(
    on_connect: ?NetworkEventFunc,
    on_disconnect: ?NetworkEventFunc,
) void;
pub const setNetworkEvent = LF_Set_Network_Event;

// =============================================================================
// Shutdown (1)
// =============================================================================

/// `LF_Shutdown` - graceful full shutdown; releases all resources.
pub extern fn LF_Shutdown() void;
pub const shutdown = LF_Shutdown;
