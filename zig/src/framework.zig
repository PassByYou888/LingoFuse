// =============================================================================
//  framework.zig - Process-wide facade over the LingoFuse C ABI.
// -----------------------------------------------------------------------------
//  Every process-wide operation that the native library provides but
//  that does not fit the DataHandle or AppHandle abstraction:
//
//      * Loader lifecycle    - init / deinit
//      * Network preparation - resetPrepare / prepareService /
//                              prepareClient / prepareDone /
//                              exitMainThread
//      * Remote invocation   - call / callOptional / notify /
//                              sequencedNotify
//                              callByUid / callOptionalByUid /
//                              notifyByUid / sequencedNotifyByUid
//                              callByP2PName / callOptionalByP2PName /
//                              notifyByP2PName / sequencedNotifyByP2PName
//      * Options             - setOption / getOption
//      * App-name helpers    - generateAppName / getAppName
//      * Health checks       - checkMainThread / checkApp / checkApi /
//                              checkUid / checkUidApi /
//                              checkP2PName / checkP2PNameApi
//      * Status queue        - getStatusCount / getStatus / postStatus
//      * Full shutdown       - shutdown
//
//  Three addressing schemes
//  ------------------------
//  LingoFuse routes a request by one of three keys. The three families
//  are parallel and independent; each one is exposed here under a
//  consistent naming convention:
//
//      Scheme    Key                            Local-first?  LB?
//      --------  -----------------------------  ------------  ----
//      App name  UTF-8 string                   yes           no
//      UID       32-byte session identifier     yes           no
//      P2PName   UTF-8 group name               no            yes
//
//  App name matches a registered application. A call goes to the
//  process-local instance first if one exists; otherwise the mesh
//  forwards it to one of the remote clients that hosts that app.
//
//  UID matches a specific client session. UID routing is session-level:
//  the UID is regenerated on every reconnect. It can reach ANY API
//  registered on the target -- whether app-bound or process-wide P2P --
//  without the caller knowing the target's App name. UID routing is
//  also local-first.
//
//  P2PName matches a user-defined group of clients. Routing is NOT
//  local-first: the call is always forwarded to the server, which owns
//  the load-balancing state.
//
//  The naming convention in this module is:
//
//      App-name family : bare name, e.g. `call`, `notify`
//      UID family      : `*ByUid`, e.g. `callByUid`, `notifyByUid`
//      P2PName family  : `*ByP2PName`, e.g. `callByP2PName`
//
//  Loader contract
//  ---------------
//  The C ABI is dynamically loaded. Before `init()` succeeds, every
//  LF_* function pointer is null. A well-behaved program calls `init()`
//  first and `deinit()` last.
//
//  PrepareDone contract
//  --------------------
//  `LF_PrepareDone` returns 1 only once per process. A second call
//  without an intervening `shutdown` returns 0, which is NOT a
//  failure. This module returns a `bool` from `prepareDone()`.
//
//  Call contract
//  -------------
//  `LF_Call` never returns a null handle. On timeout or unreachable
//  target it returns a size-0 handle. Two wrappers are offered:
//  `call` returns the handle unchanged; `callOptional` returns `null`
//  for a size-0 response. The same applies to the UID and P2PName
//  variants.
//
//  Array-fill style
//  ----------------
//  This module uses no `**` operator anywhere.
// =============================================================================
const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const DataHandle = @import("data_handle.zig").DataHandle;
const AppHandle = @import("app_handle.zig").AppHandle;
const Uid = @import("uid.zig").Uid;
const util = @import("util.zig");

// =============================================================================
// Loader lifecycle
// =============================================================================

/// Load the native runtime.
///
/// Must be called exactly once, from a single thread, before any other
/// `LF_*` function. Returns `Error.LibraryLoadFailed` when the runtime
/// library cannot be located or a required symbol is missing.
pub fn init() Error!void {
    if (sys.loadLibrary() != 1) return Error.LibraryLoadFailed;
}

/// Unload the native runtime.
///
/// Safe to call multiple times. Does NOT call `shutdown`; if the
/// framework was started, call `shutdown` first.
pub fn deinit() void {
    sys.freeLibrary();
}

// =============================================================================
// Network preparation
// =============================================================================

/// Clear the preparation queue.
///
/// Running services and clients are not affected. Only the pending list
/// of services and clients to be created by the next `prepareDone` is
/// cleared.
pub fn resetPrepare() void {
    sys.resetPrepare();
}

/// Prepare a C4 service.
///
/// `listening_addr` is the local binding address. `physics_addr` is the
/// address advertised to clients; usually equal to `listening_addr`.
pub fn prepareService(
    listening_addr: [:0]const u8,
    physics_addr: [:0]const u8,
) Error!i32 {
    const tag = sys.prepareService(listening_addr.ptr, physics_addr.ptr);
    if (tag < 0) return Error.RegistrationFailed;
    return tag;
}

/// Prepare a C4 client.
///
/// `physics_addr` is the address of the target service. `app` is the
/// application to expose, or `null` for a pure consumer.
pub fn prepareClient(
    physics_addr: [:0]const u8,
    app: ?*const AppHandle,
) Error!i32 {
    const app_hnd: sys.AppHnd = if (app) |a| blk: {
        break :blk a.raw orelse return Error.NullHandle;
    } else null;

    const tag = sys.prepareClient(physics_addr.ptr, app_hnd);
    if (tag < 0) return Error.RegistrationFailed;
    return tag;
}

/// Start the framework with the prepared services and clients.
///
/// Returns `true` on the first successful start, `false` on a second
/// call without an intervening `shutdown`. A `false` return is NOT a
/// failure: the framework is already running.
pub fn prepareDone() bool {
    return sys.prepareDone() == 1;
}

/// Request the simulated main thread to exit.
///
/// This also flushes the data-handle pool, releasing every outstanding
/// handle -- including permanent ones. Do not use any data handle after
/// this call has returned.
pub fn exitMainThread() void {
    sys.exitMainThread();
}

// =============================================================================
// Runtime options
// =============================================================================

/// Adjust a global runtime option.
///
/// Unknown option names are silently ignored by the native layer. Use
/// `"True"` / `"False"` for booleans; integer values are decimal
/// strings.
///
/// This is the raw stringly-typed interface. The `options.zig` module
/// provides typed wrappers (`options.setQuiet`, etc.).
pub fn setOption(
    option: [:0]const u8,
    value: [:0]const u8,
) void {
    sys.setOption(option.ptr, value.ptr);
}

/// Read a global runtime option.
///
/// Returns an allocator-owned, NUL-terminated slice. The native pointer
/// is valid for only about 5 seconds; this wrapper copies the string
/// immediately, so the returned slice is safe to retain.
///
/// Unknown option names return an empty string. Some options are
/// write-only (for example `debug`); their getter returns a fixed
/// placeholder string.
///
/// # Ownership
///
/// The caller owns the returned slice and must free it with
/// `alloc.free`.
pub fn getOption(
    alloc: std.mem.Allocator,
    option: [:0]const u8,
) Error![:0]u8 {
    const ptr = sys.getOption(option.ptr);
    return util.copyCstrOrEmpty(alloc, ptr);
}

// =============================================================================
// Application name helpers
// =============================================================================

/// Generate a globally unique application name.
///
/// Must be called after `prepareDone` has returned `true`. The native
/// pointer is valid for only ~5 seconds; this wrapper copies the
/// string into an allocator-owned slice. The caller owns the slice
/// and must free it with `alloc.free`.
pub fn generateAppName(
    alloc: std.mem.Allocator,
) Error![:0]u8 {
    const ptr = sys.generateAppName();
    return util.copyCstrOrEmpty(alloc, ptr);
}

/// Return the name of an existing application handle.
///
/// Same ~5-second pointer-lifetime rule as `generateAppName`; this
/// wrapper copies the string immediately.
pub fn getAppName(
    alloc: std.mem.Allocator,
    app: *const AppHandle,
) Error![:0]u8 {
    const hnd = app.raw orelse return Error.NullHandle;
    const ptr = sys.getAppName(hnd);
    return util.copyCstrOrEmpty(alloc, ptr);
}

// =============================================================================
// Health checks
// =============================================================================

/// True when the simulated main thread is running.
pub fn checkMainThread() bool {
    return sys.checkMainThread() != 0;
}

/// True when the named application is visible on the mesh.
///
/// The lookup uses a local cache updated by network broadcasts with an
/// approximate 3-second propagation delay.
pub fn checkApp(app_name: [:0]const u8) bool {
    return sys.checkApp(app_name.ptr) != 0;
}

/// True when the named API is visible on the mesh.
///
/// Same cache semantics as `checkApp`.
pub fn checkApi(
    app_name: [:0]const u8,
    api_name: [:0]const u8,
) bool {
    return sys.checkApi(app_name.ptr, api_name.ptr) != 0;
}

/// True when a client with the given UID is registered.
///
/// Same cache semantics as `checkApp`: the answer is backed by a
/// broadcast-updated cache with approximately 3 seconds of propagation
/// delay.
pub fn checkUid(uid: Uid) bool {
    return sys.checkUid(uid.toLf()) != 0;
}

/// True when a client with the given UID exposes the named API.
pub fn checkUidApi(
    uid: Uid,
    api_name: [:0]const u8,
) bool {
    return sys.checkUidApi(uid.toLf(), api_name.ptr) != 0;
}

/// True when a client with the given P2P group name is registered.
pub fn checkP2PName(p2p_name: [:0]const u8) bool {
    return sys.checkP2PName(p2p_name.ptr) != 0;
}

/// True when a client in the given P2P group exposes the named API.
pub fn checkP2PNameApi(
    p2p_name: [:0]const u8,
    api_name: [:0]const u8,
) bool {
    return sys.checkP2PNameApi(p2p_name.ptr, api_name.ptr) != 0;
}

// =============================================================================
// Remote invocation - App-name addressing
// =============================================================================

/// Perform a synchronous remote call and return the response handle.
///
/// Never fails with a null handle: on timeout or unreachable target,
/// the native layer returns a size-0 handle. Check the returned
/// handle's size to distinguish a failure from an empty response, or
/// use `callOptional` for a Zig-idiomatic `?DataHandle`.
///
/// The caller owns the returned handle and must call `deinit` on it.
/// `param` is NOT consumed.
pub fn call(
    app_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: u64,
) Error!DataHandle {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const res = sys.call(app_name.ptr, param_hnd, timeout_ms);
    if (res == null) return Error.CallFailed;
    return DataHandle.fromRaw(res, true);
}

/// Like `call`, but returns `null` when the native layer produced an
/// empty (size-0) response.
///
/// When the function returns a non-null handle, the caller owns it.
/// When it returns `null`, the underlying empty handle has already
/// been released by this function.
pub fn callOptional(
    app_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: u64,
) Error!?DataHandle {
    var response = try call(app_name, param, timeout_ms);
    const sz = try response.size();
    if (sz == 0) {
        response.deinit();
        return null;
    }
    return response;
}

/// Send a one-way notification.
///
/// Delivery order is not guaranteed. `param` is NOT consumed.
pub fn notify(
    app_name: [:0]const u8,
    param: *const DataHandle,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    sys.notify(app_name.ptr, param_hnd);
}

/// Send a one-way notification with FIFO ordering guaranteed for the
/// same (app_name, api_name) pair. `param` is NOT consumed.
pub fn sequencedNotify(
    app_name: [:0]const u8,
    param: *const DataHandle,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    sys.sequencedNotify(app_name.ptr, param_hnd);
}

// =============================================================================
// Remote invocation - UID addressing
// =============================================================================
//
// UID addressing routes to the exact client whose tunnel established the
// given 32-byte session identifier. It is session-level: the UID is
// regenerated on every reconnect, so a caller that caches a UID MUST
// re-probe it after a link loss.
//
// UID routing is LOCAL-FIRST, matching App-name routing. A UID can
// address any API registered on the target -- whether app-bound or
// process-wide P2P -- without the caller knowing the target's App name.
//
// A null UID is a valid argument: it simply matches no client, and the
// synchronous `call` family returns a size-0 handle.

/// Perform a synchronous remote call addressed by session UID.
///
/// Same timeout and ownership contract as `call`. See
/// `callOptionalByUid` for the `?DataHandle` variant.
pub fn callByUid(
    uid: Uid,
    param: *const DataHandle,
    timeout_ms: u64,
) Error!DataHandle {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const res = sys.uidCall(uid.toLf(), param_hnd, timeout_ms);
    if (res == null) return Error.CallFailed;
    return DataHandle.fromRaw(res, true);
}

/// Like `callByUid`, but returns `null` for a size-0 response.
pub fn callOptionalByUid(
    uid: Uid,
    param: *const DataHandle,
    timeout_ms: u64,
) Error!?DataHandle {
    var response = try callByUid(uid, param, timeout_ms);
    const sz = try response.size();
    if (sz == 0) {
        response.deinit();
        return null;
    }
    return response;
}

/// Send a one-way notification addressed by session UID.
///
/// Delivery order is not guaranteed. Use `sequencedNotifyByUid` when
/// FIFO ordering is required.
pub fn notifyByUid(
    uid: Uid,
    param: *const DataHandle,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    sys.uidNotify(uid.toLf(), param_hnd);
}

/// Send a FIFO-ordered one-way notification addressed by session UID.
///
/// FIFO ordering is guaranteed only for the same (uid, api_name) pair.
pub fn sequencedNotifyByUid(
    uid: Uid,
    param: *const DataHandle,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    sys.uidSequencedNotify(uid.toLf(), param_hnd);
}

// =============================================================================
// Remote invocation - P2PName addressing
// =============================================================================
//
// P2PName addressing routes to any client in a user-defined group. It is
// NOT local-first: the call is always forwarded to the server, which
// owns the load-balancing state.
//
// Target selection on the server uses one of two strategies:
//
//     - Load balancing (Cycle_Anchor): the target with the smallest
//       anchor value is chosen, then its anchor is advanced.
//     - Sticky affinity (FixedSequenced), governed by the
//       `Fixed_Sequenced_Time` runtime option (default 20 seconds).

/// Perform a synchronous remote call addressed by P2P group name.
///
/// Same timeout and ownership contract as `call`.
pub fn callByP2PName(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: u64,
) Error!DataHandle {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const res = sys.p2pnameCall(p2p_name.ptr, param_hnd, timeout_ms);
    if (res == null) return Error.CallFailed;
    return DataHandle.fromRaw(res, true);
}

/// Like `callByP2PName`, but returns `null` for a size-0 response.
pub fn callOptionalByP2PName(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: u64,
) Error!?DataHandle {
    var response = try callByP2PName(p2p_name, param, timeout_ms);
    const sz = try response.size();
    if (sz == 0) {
        response.deinit();
        return null;
    }
    return response;
}

/// Send a one-way notification addressed by P2P group name.
///
/// Delivery order is not guaranteed. Use `sequencedNotifyByP2PName`
/// when FIFO ordering is required.
pub fn notifyByP2PName(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    sys.p2pnameNotify(p2p_name.ptr, param_hnd);
}

/// Send a FIFO-ordered one-way notification addressed by P2P group name.
///
/// FIFO ordering is guaranteed only for the same (p2p_name, api_name)
/// pair.
pub fn sequencedNotifyByP2PName(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    sys.p2pnameSequencedNotify(p2p_name.ptr, param_hnd);
}

// =============================================================================
// Status queue
// =============================================================================

/// Number of pending log messages in the status queue.
pub fn getStatusCount() i32 {
    return sys.getStatusCount();
}

/// Retrieve the next log message from the status queue.
///
/// The native function returns a pointer into a static buffer that the
/// next call overwrites; this wrapper copies the string immediately.
/// The caller owns the slice and must free it with `alloc.free`.
pub fn getStatus(
    alloc: std.mem.Allocator,
) Error![:0]u8 {
    const ptr = sys.getStatus();
    return util.copyCstrOrEmpty(alloc, ptr);
}

/// Inject a user-supplied log message into the status queue.
pub fn postStatus(message: [:0]const u8) void {
    sys.postStatus(message.ptr);
}

// =============================================================================
// Shutdown
// =============================================================================

/// Gracefully terminate the framework, releasing all resources.
///
/// After `shutdown`:
///
///     * Every `AppHandle` still alive becomes invalid.
///     * The framework may be re-initialised by calling the preparation
///       functions again.
///     * The process-wide "started" flag is reset, so the next
///       `prepareDone` returns `true` again.
///
/// Safe to call multiple times.
pub fn shutdown() void {
    sys.shutdown();
}

// =============================================================================
// Tests
// =============================================================================
//
// This module's public API requires the native runtime. The unit tests
// below therefore cannot exercise the process-wide operations; those
// are covered end-to-end by `examples/abi_smoke.zig` and by the
// cross-process demos. This file has no pure helper functions that can
// be tested in isolation, so it declares no `test` block. `zig test
// src/framework.zig` compiles the file and reports zero tests, which
// is the intended outcome.
