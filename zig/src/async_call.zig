const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const DataHandle = @import("data_handle.zig").DataHandle;
const Uid = @import("uid.zig").Uid;

extern "c" fn Sleep(dwMilliseconds: u32) void;
extern "c" fn GetTickCount64() u64;

inline fn sleepMillis(ms: u32) void {
    Sleep(ms);
}

inline fn nowMillis() u64 {
    return GetTickCount64();
}

pub const AsyncResult = union(enum) {
    ok: DataHandle,
    err: Error,
};

pub const AsyncResultHandler = *const fn (
    ctx: ?*anyopaque,
    result: AsyncResult,
) void;

const AsyncContext = struct {
    handler: AsyncResultHandler,
    user_ctx: ?*anyopaque,
};

fn allocContext(
    handler: AsyncResultHandler,
    user_ctx: ?*anyopaque,
) Error!*AsyncContext {
    const alloc = std.heap.page_allocator;
    const c = alloc.create(AsyncContext) catch return Error.OutOfMemory;
    c.* = .{ .handler = handler, .user_ctx = user_ctx };
    return c;
}

fn freeContext(c: *AsyncContext) void {
    std.heap.page_allocator.destroy(c);
}

fn asyncTrampoline(
    data: ?*anyopaque,
    result: sys.DataHnd,
) callconv(.c) void {
    const raw = data orelse return;
    const c: *AsyncContext = @ptrCast(@alignCast(raw));

    const h = DataHandle.fromRaw(result, false);
    c.handler(c.user_ctx, .{ .ok = h });
    freeContext(c);
}

pub fn callAsync(
    app_name: [:0]const u8,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.asyncCall(
        app_name.ptr,
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

pub fn callAsyncSequenced(
    app_name: [:0]const u8,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.asyncSequencedCall(
        app_name.ptr,
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

pub fn callAsyncByUid(
    uid: Uid,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.uidAsyncCall(
        uid.toLf(),
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

pub fn callAsyncByUidSequenced(
    uid: Uid,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.uidAsyncSequencedCall(
        uid.toLf(),
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

pub fn callAsyncByP2PName(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.p2pnameAsyncCall(
        p2p_name.ptr,
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

pub fn callAsyncByP2PNameSequenced(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
    user_ctx: ?*anyopaque,
    handler: AsyncResultHandler,
) Error!void {
    const param_hnd = param.raw orelse return Error.NullHandle;
    const c = try allocContext(handler, user_ctx);

    const ret = sys.p2pnameAsyncSequencedCall(
        p2p_name.ptr,
        param_hnd,
        @ptrCast(c),
        asyncTrampoline,
    );

    if (ret != 1) {
        c.handler(c.user_ctx, .{ .err = Error.CallFailed });
        freeContext(c);
        return Error.CallFailed;
    }
}

const Waiter = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    payload: ?[]u8 = null,
    err: ?Error = null,
    ref_count: std.atomic.Value(u32),

    fn alloc() Error!*Waiter {
        const w = std.heap.page_allocator.create(Waiter) catch
            return Error.OutOfMemory;
        w.* = .{
            .ref_count = std.atomic.Value(u32).init(2),
        };
        return w;
    }

    fn release(self: *Waiter) void {
        const old = self.ref_count.fetchSub(1, .acq_rel);
        if (old == 1) {
            if (self.payload) |p| std.heap.page_allocator.free(p);
            std.heap.page_allocator.destroy(self);
        }
    }
};

fn waitHandler(ctx: ?*anyopaque, result: AsyncResult) void {
    const raw = ctx orelse return;
    const w: *Waiter = @ptrCast(@alignCast(raw));

    switch (result) {
        .ok => |h| {
            var hh = h;
            const bytes = hh.readAllBytes(std.heap.page_allocator) catch {
                w.err = Error.ReadFailed;
                w.done.store(true, .release);
                w.release();
                return;
            };
            if (bytes.len == 0) {
                std.heap.page_allocator.free(bytes);
                w.err = Error.CallFailed;
                w.done.store(true, .release);
                w.release();
                return;
            }
            w.payload = bytes;
            w.done.store(true, .release);
            w.release();
        },
        .err => |e| {
            w.err = e;
            w.done.store(true, .release);
            w.release();
        },
    }
}

fn waitForResult(w: *Waiter, timeout_ms: ?u64) Error![]u8 {
    const start_ms: u64 = nowMillis();

    while (!w.done.load(.acquire)) {
        if (timeout_ms) |t| {
            const elapsed: u64 = nowMillis() - start_ms;
            if (elapsed >= t) {
                w.release();
                return Error.Timeout;
            }
        }
        sleepMillis(1);
    }

    if (w.err) |e| {
        w.release();
        return e;
    }

    const payload = w.payload orelse {
        w.release();
        return Error.ReadFailed;
    };

    w.payload = null;
    w.release();
    return payload;
}

pub fn callAsyncWait(
    app_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    const w = try Waiter.alloc();
    callAsync(app_name, param, w, waitHandler) catch |err| {
        w.release();
        return err;
    };
    return waitForResult(w, timeout_ms);
}

pub fn callAsyncWaitSequenced(
    app_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    const w = try Waiter.alloc();
    callAsyncSequenced(app_name, param, w, waitHandler) catch |err| {
        w.release();
        return err;
    };
    return waitForResult(w, timeout_ms);
}

pub fn callAsyncWaitByUid(
    uid: Uid,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    const w = try Waiter.alloc();
    callAsyncByUid(uid, param, w, waitHandler) catch |err| {
        w.release();
        return err;
    };
    return waitForResult(w, timeout_ms);
}

pub fn callAsyncWaitByUidSequenced(
    uid: Uid,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    const w = try Waiter.alloc();
    callAsyncByUidSequenced(uid, param, w, waitHandler) catch |err| {
        w.release();
        return err;
    };
    return waitForResult(w, timeout_ms);
}

pub fn callAsyncWaitByP2PName(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    const w = try Waiter.alloc();
    callAsyncByP2PName(p2p_name, param, w, waitHandler) catch |err| {
        w.release();
        return err;
    };
    return waitForResult(w, timeout_ms);
}

pub fn callAsyncWaitByP2PNameSequenced(
    p2p_name: [:0]const u8,
    param: *const DataHandle,
    timeout_ms: ?u64,
) Error![]u8 {
    const w = try Waiter.alloc();
    callAsyncByP2PNameSequenced(p2p_name, param, w, waitHandler) catch |err| {
        w.release();
        return err;
    };
    return waitForResult(w, timeout_ms);
}
