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
//      * Options             - setOption
//      * App-name helpers    - generateAppName / getAppName
//      * Health checks       - checkMainThread / checkApp / checkApi
//      * Status queue        - getStatusCount / getStatus / postStatus
//      * Full shutdown       - shutdown
//
//  Loader contract
//  ---------------
//  The C ABI is dynamically loaded. Before `init()` succeeds, every
//  LF_* function pointer is null. A well-behaved program calls
//  `init()` first and `deinit()` last.
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
//  for a size-0 response.
// =============================================================================
const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const DataHandle = @import("data_handle.zig").DataHandle;
const AppHandle = @import("app_handle.zig").AppHandle;

// -----------------------------------------------------------------------------
// Allocator helper
// -----------------------------------------------------------------------------
//
// `std.mem.Allocator.dupeZ` was removed in Zig 0.17. This local
// helper reproduces its semantics using only `alloc` and `free`,
// both of which are stable across Zig releases.
//
// The returned slice is sentinel-terminated: `result[result.len] == 0`
// is guaranteed, and `result.ptr` is a valid `[*:0]u8`.
fn dupeZ(alloc: std.mem.Allocator, s: []const u8) Error![:0]u8 {
    const buf = alloc.alloc(u8, s.len + 1) catch return Error.OutOfMemory;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

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
/// Running services and clients are not affected. Only the pending
/// list of services and clients to be created by the next
/// `prepareDone` is cleared.
pub fn resetPrepare() void {
    sys.resetPrepare();
}

/// Prepare a C4 service.
///
/// `listening_addr` is the local binding address. `physics_addr` is
/// the address advertised to clients; usually equal to `listening_addr`.
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
/// handle -- including permanent ones. Do not use any data handle
/// after this call has returned.
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
pub fn setOption(
    option: [:0]const u8,
    value: [:0]const u8,
) void {
    sys.setOption(option.ptr, value.ptr);
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
    const ptr = sys.generateAppName() orelse
        return dupeZ(alloc, "");
    const slice = std.mem.span(ptr);
    return dupeZ(alloc, slice);
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
    const ptr = sys.getAppName(hnd) orelse
        return dupeZ(alloc, "");
    const slice = std.mem.span(ptr);
    return dupeZ(alloc, slice);
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

// =============================================================================
// Remote invocation
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
    const ptr = sys.getStatus() orelse
        return dupeZ(alloc, "");
    const slice = std.mem.span(ptr);
    return dupeZ(alloc, slice);
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
