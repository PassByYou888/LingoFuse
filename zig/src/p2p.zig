// =============================================================================
//  p2p.zig - Process-wide P2P API registration.
// -----------------------------------------------------------------------------
//  This module is the Zig counterpart of the `LF_Register_P2P_*` /
//  `LF_Unregister_P2P` family in `LingoFuse.h`. It lets a process
//  publish Call / Notify handlers on a namespace that is INDEPENDENT of
//  any App.
//
//  What "process-wide P2P" means
//  -----------------------------
//  An API registered through `registerP2PCall` or `registerP2PNotify`
//  lives on the process-wide `LF_P2P_APP` and is reachable through UID
//  addressing and P2PName addressing ONLY. It is NOT reachable by
//  App-name addressing, even if the API name happens to match a
//  registered App name.
//
//  The intended use is for utility APIs that any client in the mesh
//  should be able to call without knowing the target's App name:
//  health probes, capability discovery, identity echo, and similar
//  "who am I talking to?" helpers.
//
//  Comparison with AppHandle.registerCall
//  --------------------------------------
//
//      Aspect           AppHandle.registerCall   registerP2PCall
//      ---------------- ------------------------ -------------------
//      Namespace        The App's own namespace  Process-wide P2P
//      Reachable by     App name, UID, P2PName   UID, P2PName
//      Bound to an App  Yes (the AppHandle)      No (process-global)
//      Registered on    LF_RegisterCall          LF_Register_P2P_Call
//      Unregistered by  AppHandle.unregister     unregisterP2P
//      Lifetime         Until AppHandle drops    Until LF_Shutdown
//
//  Callback contract
//  -----------------
//  The callback rules are IDENTICAL to those in `app_handle.zig`:
//
//      1. Do not block. A long-running callback occupies a worker
//         thread from the native pool.
//      2. Do not call any blocking LingoFuse function
//         (framework.call, AppHandle.localCall, framework.prepareDone,
//         framework.shutdown) from inside a callback. Doing so
//         deadlocks the native scheduler.
//      3. Do not panic. Zig panics do not unwind cleanly across a
//         `callconv(.c)` boundary; the trampoline catches Zig errors
//         via the `Error!void` return type, but a panic would still
//         be a bug.
//
//  Memory model
//  ------------
//  Each registered P2P API owns a small context object that is Boxed
//  and leaked to the native layer as the callback's `trigger` pointer.
//  The block is NEVER reclaimed, even when the API is unregistered.
//  This is the same trade-off documented in `app_handle.zig`: the
//  native layer may invoke a callback at any time, including
//  concurrently with an unregister call, so a reclaim would create a
//  use-after-free window.
//
//  The cost is bounded: a context is a few dozen bytes, and the number
//  of registered APIs per process is normally small (single digits to
//  low tens).
//
//  Threading
//  ---------
//  The functions in this module may be called from any thread. The
//  native library is thread-safe, and the module holds no shared state
//  of its own.
//
//  Array-fill style
//  ----------------
//  This module uses no `**` operator anywhere.
// =============================================================================

const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const DataHandle = @import("data_handle.zig").DataHandle;
const util = @import("util.zig");

// CallHandler / NotifyHandler are defined in app_handle.zig and shared
// by every registration path (app-bound and process-wide P2P). Importing
// them here avoids duplicating the two typedefs; the dependency is a
// pure type dependency with no runtime coupling.
const CallHandler = @import("app_handle.zig").CallHandler;
const NotifyHandler = @import("app_handle.zig").NotifyHandler;

// =============================================================================
// Context objects (leaked as the `trigger` pointer)
// =============================================================================

/// The context behind a registered P2P Call API.
///
/// The native layer stores a raw pointer to a heap-allocated
/// `CallContext` as the callback's `trigger` parameter. See the module
/// documentation for why the block is leaked rather than reclaimed.
const CallContext = struct {
    user_ctx: ?*anyopaque,
    handler: CallHandler,
    /// NUL-terminated copy of the API name. Used by the trampoline when
    /// logging a handler error. REQUIRED: the trampoline may run long
    /// after the caller's original slice has gone out of scope, so
    /// storing a reference would be a use-after-free.
    api_name_buf: [:0]u8,
};

/// The context behind a registered P2P Notify API.
const NotifyContext = struct {
    user_ctx: ?*anyopaque,
    handler: NotifyHandler,
    api_name_buf: [:0]u8,
};

// =============================================================================
// Trampolines
// =============================================================================

/// The `extern "C"` function the native layer invokes for a P2P Call API.
///
/// # Safety
///
/// - `trigger` must be a pointer produced by `std.heap.page_allocator
///   .create(CallContext)` and stored via `@ptrCast`. It is `'static`
///   from the native layer's point of view because the block is never
///   reclaimed.
/// - `input` and `output` are valid `TDataHnd` values for the duration
///   of the callback, as documented by the native library.
fn p2pCallTrampoline(
    trigger: ?*anyopaque,
    input: sys.DataHnd,
    output: sys.DataHnd,
) callconv(.c) void {
    const raw = trigger orelse return;
    const c: *CallContext = @ptrCast(@alignCast(raw));

    var in_h = DataHandle.fromRaw(input, false);
    var out_h = DataHandle.fromRaw(output, false);

    c.handler(c.user_ctx, &in_h, &out_h) catch |err| {
        std.log.err(
            "LingoFuse P2P Call handler for API '{s}' returned error: {}",
            .{ c.api_name_buf, err },
        );
    };
}

/// The `extern "C"` function the native layer invokes for a P2P Notify API.
///
/// # Safety
///
/// Same contract as `p2pCallTrampoline`, minus the output handle.
fn p2pNotifyTrampoline(
    trigger: ?*anyopaque,
    input: sys.DataHnd,
) callconv(.c) void {
    const raw = trigger orelse return;
    const c: *NotifyContext = @ptrCast(@alignCast(raw));

    var in_h = DataHandle.fromRaw(input, false);

    c.handler(c.user_ctx, &in_h) catch |err| {
        std.log.err(
            "LingoFuse P2P Notify handler for API '{s}' returned error: {}",
            .{ c.api_name_buf, err },
        );
    };
}

// =============================================================================
// Public API
// =============================================================================

/// Register a process-wide P2P Call (request-response) API.
///
/// The `handler` runs on a native worker thread. See the module
/// documentation for the callback contract.
///
/// # Parameters
///
/// - `api_name`: UTF-8, NUL-terminated API name. Case-insensitive
///   matching applies at lookup time. Must be unique within the
///   process-wide P2P namespace; a duplicate registration returns
///   `Error.RegistrationFailed`.
/// - `description`: UTF-8, NUL-terminated description.
/// - `user_ctx`: Opaque pointer passed back to the handler unchanged.
///   May be null.
/// - `handler`: The callback. See the module documentation.
///
/// # Ownership
///
/// On success, this function leaks two allocator blocks (the
/// `CallContext` and a NUL-terminated copy of the API name). This is
/// intentional; see the module documentation.
///
/// # Errors
///
/// - `Error.OutOfMemory` if the context allocation fails.
/// - `Error.RegistrationFailed` if the native layer rejects the
///   registration (usually a duplicate name in the P2P namespace).
pub fn registerP2PCall(
    api_name: [:0]const u8,
    description: [:0]const u8,
    user_ctx: ?*anyopaque,
    handler: CallHandler,
) Error!void {
    const alloc = std.heap.page_allocator;

    // Copy the API name. The context is intentionally leaked on the
    // success path, so this copy is also never freed.
    const name_buf = util.dupeZ(alloc, api_name) catch
        return Error.OutOfMemory;

    const c = alloc.create(CallContext) catch {
        alloc.free(name_buf);
        return Error.OutOfMemory;
    };

    c.* = .{
        .user_ctx = user_ctx,
        .handler = handler,
        .api_name_buf = name_buf,
    };

    const ret = sys.registerP2PCall(
        api_name.ptr,
        description.ptr,
        @ptrCast(c),
        p2pCallTrampoline,
    );

    if (ret != 1) {
        // The native layer refused the registration and therefore did
        // NOT store the context pointer. Reclaim both blocks so that a
        // rejected registration (typically a duplicate API name) does
        // not leak memory.
        alloc.free(name_buf);
        alloc.destroy(c);
        return Error.RegistrationFailed;
    }
    // Success: both blocks are intentionally leaked. The native layer
    // may invoke the callback at any time, including concurrently with
    // an unregister call.
}

/// Register a process-wide P2P Notify (one-way) API.
///
/// Same contract as `registerP2PCall`, minus the output handle.
///
/// # Errors
///
/// Same as `registerP2PCall`.
pub fn registerP2PNotify(
    api_name: [:0]const u8,
    description: [:0]const u8,
    user_ctx: ?*anyopaque,
    handler: NotifyHandler,
) Error!void {
    const alloc = std.heap.page_allocator;

    const name_buf = util.dupeZ(alloc, api_name) catch
        return Error.OutOfMemory;

    const c = alloc.create(NotifyContext) catch {
        alloc.free(name_buf);
        return Error.OutOfMemory;
    };

    c.* = .{
        .user_ctx = user_ctx,
        .handler = handler,
        .api_name_buf = name_buf,
    };

    const ret = sys.registerP2PNotify(
        api_name.ptr,
        description.ptr,
        @ptrCast(c),
        p2pNotifyTrampoline,
    );

    if (ret != 1) {
        alloc.free(name_buf);
        alloc.destroy(c);
        return Error.RegistrationFailed;
    }
}

/// Remove a process-wide P2P API by name.
///
/// Does NOT affect app-bound APIs of the same name.
///
/// # Return value
///
/// `true` if the API was found and removed, `false` otherwise.
///
/// # Propagation delay
///
/// The local effect is immediate. A network broadcast propagates the
/// removal to remote peers within approximately 3 seconds. During that
/// window a remote caller may still route to this API and receive an
/// empty response.
///
/// # Note
///
/// The callback context behind the unregistered API is NOT reclaimed
/// (see the module documentation). A subsequent registration with the
/// same name creates a fresh context.
pub fn unregisterP2P(api_name: [:0]const u8) Error!bool {
    return sys.unregisterP2P(api_name.ptr) == 1;
}
