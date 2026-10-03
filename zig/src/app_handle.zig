// =============================================================================
//  app_handle.zig - RAII wrapper around a native LingoFuse application handle.
// -----------------------------------------------------------------------------
//  An AppHandle owns a native TAppHnd and provides a safe Zig API for
//  registering Call / Notify endpoints, unregistering them, invoking
//  them locally, and binding the application to idle clients.
//
//  Callback model
//  --------------
//  Callbacks run on native worker threads. Handlers receive borrowed
//  DataHandle instances for input and output; they MUST NOT call
//  `deinit` on them. Handlers MUST NOT call any blocking LingoFuse
//  function. See the trampolines below for the exact contract.
//
//  Panic isolation
//  ---------------
//  Zig panics do not unwind cleanly across a `callconv(.c)` boundary.
//  Recommended build config for programs that register callbacks:
//  `-fno-unwind-tables` plus `panic = abort`.
//
//  Memory model
//  ------------
//  Each SUCCESSFUL registration owns TWO page-allocator blocks:
//
//      1. A small `CallContext` / `NotifyContext` struct.
//      2. A NUL-terminated copy of the API name.
//
//  Both blocks are handed to the native layer (the struct via the
//  `trigger` pointer) and are intentionally never reclaimed, because
//  the native scheduler may invoke the callback at any time after
//  registration, including concurrently with an unregister call. The
//  cost is bounded by the number of registered APIs, which is
//  normally small.
//
//  The name copy is REQUIRED: the trampoline reads `ctx.api_name`
//  when logging a handler error, potentially long after the caller's
//  original slice has gone out of scope. Storing a reference would be
//  a use-after-free.
//
//  A FAILED registration does not hand either block to the native
//  layer, so both are reclaimed immediately.
//
//  Threading
//  ---------
//  AppHandle is NOT thread-safe. Registration must be complete before
//  the App is exposed to the mesh.
// =============================================================================
const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const DataHandle = @import("data_handle.zig").DataHandle;

// -----------------------------------------------------------------------------
// Handler types
// -----------------------------------------------------------------------------

/// Call-mode handler.
pub const CallHandler = *const fn (
    ctx: ?*anyopaque,
    input: *DataHandle,
    output: *DataHandle,
) Error!void;

/// Notify-mode handler.
pub const NotifyHandler = *const fn (
    ctx: ?*anyopaque,
    input: *DataHandle,
) Error!void;

// -----------------------------------------------------------------------------
// Internal context objects
// -----------------------------------------------------------------------------
//
// `api_name` points into a page-allocator block owned by this context.
// The block is created in `registerCall` / `registerNotify` and is
// never freed on the success path (see the module docstring).

const CallContext = struct {
    user_ctx: ?*anyopaque,
    handler: CallHandler,
    api_name: [:0]const u8,
};

const NotifyContext = struct {
    user_ctx: ?*anyopaque,
    handler: NotifyHandler,
    api_name: [:0]const u8,
};

/// Duplicate `name` into a page-allocator block, NUL-terminated.
///
/// The caller owns the returned slice. On failure, returns
/// `Error.OutOfMemory` and allocates nothing.
fn dupApiName(name: [:0]const u8) Error![:0]u8 {
    const buf = std.heap.page_allocator.alloc(u8, name.len + 1) catch
        return Error.OutOfMemory;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0];
}

// -----------------------------------------------------------------------------
// Trampolines
// -----------------------------------------------------------------------------
//
// The actual C-ABI entry points invoked by the native library. They
// never panic: every operation that could fail is handled through a
// `catch`.

fn callTrampoline(
    trigger: ?*anyopaque,
    input: sys.DataHnd,
    output: sys.DataHnd,
) callconv(.c) void {
    const raw_trigger = trigger orelse return;
    const ctx: *CallContext = @ptrCast(@alignCast(raw_trigger));

    var in_h = DataHandle.fromRaw(input, false);
    var out_h = DataHandle.fromRaw(output, false);

    ctx.handler(ctx.user_ctx, &in_h, &out_h) catch |err| {
        std.log.err(
            "LingoFuse Call handler for API '{s}' returned error: {}",
            .{ ctx.api_name, err },
        );
    };
}

fn notifyTrampoline(
    trigger: ?*anyopaque,
    input: sys.DataHnd,
) callconv(.c) void {
    const raw_trigger = trigger orelse return;
    const ctx: *NotifyContext = @ptrCast(@alignCast(raw_trigger));

    var in_h = DataHandle.fromRaw(input, false);

    ctx.handler(ctx.user_ctx, &in_h) catch |err| {
        std.log.err(
            "LingoFuse Notify handler for API '{s}' returned error: {}",
            .{ ctx.api_name, err },
        );
    };
}

// -----------------------------------------------------------------------------
// AppHandle
// -----------------------------------------------------------------------------

/// RAII wrapper around a native LingoFuse application handle.
pub const AppHandle = struct {
    const Self = @This();

    /// The native handle. `null` once released.
    raw: sys.AppHnd,

    /// Application name. Kept for diagnostics and for the `name()` method.
    name_: [:0]const u8,

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// Create a new application with the given name and description.
    ///
    /// The parameter is named `app_name` (not `name`) because the
    /// struct also declares a `name()` method; Zig does not allow a
    /// function parameter to shadow a container-level declaration of
    /// the same name.
    pub fn create(
        app_name: [:0]const u8,
        description: [:0]const u8,
    ) Error!Self {
        const hnd = sys.createApp(app_name.ptr, description.ptr);
        if (hnd == null) return Error.LibraryLoadFailed;
        return .{ .raw = hnd, .name_ = app_name };
    }

    /// Application name passed to `create`.
    pub fn name(self: Self) []const u8 {
        return self.name_;
    }

    /// True while the handle is valid and not yet released.
    pub fn isValid(self: Self) bool {
        return self.raw != null;
    }

    // -------------------------------------------------------------------------
    // API registration
    // -------------------------------------------------------------------------

    /// Register a Call (request-response) API.
    ///
    /// On success, both the context object and the name copy are handed
    /// to the native layer through the `trigger` pointer and are never
    /// reclaimed.
    ///
    /// On failure, the native layer did NOT take ownership of either
    /// block, so both are reclaimed here.
    pub fn registerCall(
        self: *Self,
        api_name: [:0]const u8,
        description: [:0]const u8,
        ctx: ?*anyopaque,
        handler: CallHandler,
    ) Error!void {
        const hnd = self.raw orelse return Error.NullHandle;

        // Allocate the context.
        const ctx_obj = std.heap.page_allocator.create(CallContext) catch
            return Error.OutOfMemory;

        // Copy the API name. The context is intentionally leaked on
        // the success path, so this copy is also never freed. See the
        // module docstring for the rationale.
        const name_buf = dupApiName(api_name) catch {
            std.heap.page_allocator.destroy(ctx_obj);
            return Error.OutOfMemory;
        };

        ctx_obj.* = .{
            .user_ctx = ctx,
            .handler = handler,
            .api_name = name_buf,
        };

        const ret = sys.registerCall(
            hnd,
            api_name.ptr,
            description.ptr,
            @ptrCast(ctx_obj),
            callTrampoline,
        );
        if (ret != 1) {
            // The native layer refused the registration and therefore
            // did NOT store the context pointer. Reclaim both blocks
            // so that a rejected registration (typically a duplicate
            // API name) does not leak memory.
            std.heap.page_allocator.free(name_buf);
            std.heap.page_allocator.destroy(ctx_obj);
            return Error.RegistrationFailed;
        }
    }

    /// Register a Notify (one-way) API.
    ///
    /// Same ownership contract as `registerCall`.
    pub fn registerNotify(
        self: *Self,
        api_name: [:0]const u8,
        description: [:0]const u8,
        ctx: ?*anyopaque,
        handler: NotifyHandler,
    ) Error!void {
        const hnd = self.raw orelse return Error.NullHandle;

        const ctx_obj = std.heap.page_allocator.create(NotifyContext) catch
            return Error.OutOfMemory;

        const name_buf = dupApiName(api_name) catch {
            std.heap.page_allocator.destroy(ctx_obj);
            return Error.OutOfMemory;
        };

        ctx_obj.* = .{
            .user_ctx = ctx,
            .handler = handler,
            .api_name = name_buf,
        };

        const ret = sys.registerNotify(
            hnd,
            api_name.ptr,
            description.ptr,
            @ptrCast(ctx_obj),
            notifyTrampoline,
        );
        if (ret != 1) {
            std.heap.page_allocator.free(name_buf);
            std.heap.page_allocator.destroy(ctx_obj);
            return Error.RegistrationFailed;
        }
    }

    /// Unregister a previously registered API by name.
    pub fn unregister(self: *Self, api_name: [:0]const u8) Error!bool {
        const hnd = self.raw orelse return Error.NullHandle;
        return sys.unregister(hnd, api_name.ptr) == 1;
    }

    // -------------------------------------------------------------------------
    // Local execution
    // -------------------------------------------------------------------------

    /// Invoke a Call API within the same process.
    ///
    /// The input handle is NOT consumed. The returned DataHandle owns
    /// its underlying handle and must be deinitialised by the caller.
    pub fn localCall(
        self: *Self,
        param: *DataHandle,
    ) Error!DataHandle {
        const hnd = self.raw orelse return Error.NullHandle;
        const in_hnd = param.raw orelse return Error.NullHandle;

        const res = sys.localCall(hnd, in_hnd);
        if (res == null) return Error.CallFailed;

        return DataHandle.fromRaw(res, true);
    }

    /// Invoke a Notify API within the same process.
    pub fn localNotify(
        self: *Self,
        param: *DataHandle,
    ) Error!void {
        const hnd = self.raw orelse return Error.NullHandle;
        const in_hnd = param.raw orelse return Error.NullHandle;
        sys.localNotify(hnd, in_hnd);
    }

    // -------------------------------------------------------------------------
    // Client binding
    // -------------------------------------------------------------------------

    /// Bind this application to all currently-unbound clients.
    pub fn bind(self: *Self) Error!i32 {
        const hnd = self.raw orelse return Error.NullHandle;
        return sys.bindApp(hnd);
    }

    // -------------------------------------------------------------------------
    // Lifetime
    // -------------------------------------------------------------------------

    /// Perform the first stage of the two-stage native destruction.
    /// Idempotent.
    pub fn deinit(self: *Self) void {
        if (self.raw) |h| {
            sys.freeApp(h);
            self.raw = null;
        }
    }
};
