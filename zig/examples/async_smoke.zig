// =============================================================================
//  async_smoke.zig - Smoke test for the asynchronous call family.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  Same reason as the other smoke tests.
//
//  Coverage
//  --------
//  This file exercises every public entry point of the
//  `async_call.zig` module and the three behavioural contracts that
//  make the asynchronous family safe to use from Zig:
//
//      1. Callback style   - callAsync / callAsyncSequenced deliver
//                            the result to a user handler on a native
//                            worker thread.
//      2. Blocking style   - callAsyncWait and its siblings return
//                            the response bytes after the callback
//                            fires, honouring an optional Zig-side
//                            timeout.
//      3. Single error path - when the native layer rejects the
//                            request, the handler fires synchronously
//                            with `.err`, and the entry point itself
//                            returns `Error.CallFailed`.
//
//  Zig-idiomatic handler
//  ---------------------
//  Zig has no closures, so the handler is written as a named struct's
//  function and the caller passes a user-context pointer that is
//  handed back unchanged. The pattern is exactly the same as
//  `std.Thread.spawn(.{}, fn, args)`.
//
//  Why the handler uses `readAllBytes`, not `io.readString`
//  -------------------------------------------------------
//  The result handle carries the raw response BYTES; it does not add a
//  framing NUL. `io.readString` stops at the first NUL, which would
//  truncate the little-endian `sum = 12` sequence to its leading byte
//  (0x0c) because the second byte of the i32 encoding is 0x00.
//  `readAllBytes` returns every byte the framework produced.
//
//  Error-union unpacking style
//  ---------------------------
//  Every `Error!T` returned by the binding is unpacked with `try` or
//  with `catch |err| { ... }`. The `if (x) |payload| { } else |err| { }`
//  form is deliberately NOT used, because Zig's type inference for
//  that form is sensitive to the payload type and produces confusing
//  diagnostics when the payload is itself an aggregate (a slice, a
//  struct). `catch` is unambiguous.
//
//  Loader
//  ------
//  This test starts the process-global simulated main thread. Do not
//  run it concurrently with another smoke test that does the same.
//
//  Exit codes
//  ----------
//      0  all steps passed
//      1  a step failed
//      2  the log file could not be created
// =============================================================================
const std = @import("std");
const lf = @import("lingofuse");

// -----------------------------------------------------------------------------
// C stdio / Windows
// -----------------------------------------------------------------------------

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fflush(stream: *anyopaque) c_int;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn exit(code: c_int) noreturn;
extern "c" fn Sleep(ms: u32) void;

// -----------------------------------------------------------------------------
// Log
// -----------------------------------------------------------------------------

const Log = struct {
    file: ?*anyopaque,

    fn open(path: [*:0]const u8) Log {
        return .{ .file = fopen(path, "wb") };
    }

    fn close(self: *Log) void {
        if (self.file) |f| {
            _ = fclose(f);
            self.file = null;
        }
    }

    fn write(self: *Log, msg: []const u8) void {
        if (self.file) |f| {
            _ = fwrite(msg.ptr, 1, msg.len, f);
            _ = fflush(f);
        }
        std.debug.print("{s}", .{msg});
    }

    fn line(self: *Log, msg: []const u8) void {
        self.write(msg);
        self.write("\n");
    }

    fn fmt(self: *Log, comptime format: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, format, args) catch {
            self.line("[log-fmt-error: buffer too small]");
            return;
        };
        self.write(s);
        self.write("\n");
    }
};

fn check(log: *Log, cond: bool, what: []const u8) !void {
    if (!cond) {
        log.fmt("[FAIL] {s}", .{what});
        return error.AssertFailed;
    }
}

// =============================================================================
// Test handlers / shared state
// =============================================================================

fn addHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;

    // Read exactly two little-endian i32 values. `readBytes` returns
    // the number actually read; for a well-formed request that is 4
    // for each field. A short read leaves the buffer partially
    // initialised, which the sum computation would then treat as
    // garbage; the caller's assertion on the response size catches
    // that case at the test level.
    var a_buf: [4]u8 = undefined;
    var b_buf: [4]u8 = undefined;
    _ = try input.readBytes(&a_buf);
    _ = try input.readBytes(&b_buf);

    const a = std.mem.readInt(i32, &a_buf, .little);
    const b = std.mem.readInt(i32, &b_buf, .little);

    const sum = a +% b;
    var out_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &out_buf, sum, .little);
    try output.writeBytes(&out_buf);
}

/// Shared state between the test thread and the async handler.
const Sync = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    payload: ?[]u8 = null,
    err: ?lf.Error = null,
};

/// The Zig-idiomatic "handler body": a named struct with a `handle`
/// function. The pattern mirrors `std.Thread.spawn(.{}, fn, args)`.
const AsyncProbe = struct {
    fn handle(ctx: ?*anyopaque, result: lf.async_call.AsyncResult) void {
        const raw = ctx orelse return;
        const s: *Sync = @ptrCast(@alignCast(raw));

        switch (result) {
            .ok => |h| {
                var hh = h;
                // The framework-owned result handle carries the raw
                // response bytes and does NOT add a framing NUL.
                // `readAllBytes` copies every byte the framework
                // produced; `io.readString` would truncate at the
                // first zero byte.
                const bytes = hh.readAllBytes(std.heap.page_allocator) catch {
                    s.err = lf.Error.ReadFailed;
                    s.done.store(true, .release);
                    return;
                };
                s.payload = bytes;
                s.done.store(true, .release);
            },
            .err => |e| {
                s.err = e;
                s.done.store(true, .release);
            },
        }
    }
};

/// Wait for the shared state to become ready, or time out.
/// On success, the caller owns `s.payload` and must free it with
/// `std.heap.page_allocator.free`.
fn awaitSync(s: *Sync, timeout_ms: u64) lf.Error![]u8 {
    var i: u64 = 0;
    while (i < timeout_ms) : (i += 1) {
        if (s.done.load(.acquire)) {
            if (s.err) |e| return e;
            return s.payload orelse lf.Error.ReadFailed;
        }
        Sleep(1);
    }
    return lf.Error.Timeout;
}

// =============================================================================
// Configuration
// =============================================================================

const APP_NAME = "ZigAsyncSmokeApp";
const ENDPOINT = "ipc:zig_async_smoke";

// =============================================================================
// Steps
// =============================================================================

fn stepDispatchFailure(log: *Log) !void {
    log.line("[step] dispatch failure: single error path");

    // Defensive: the framework may have been left in an unknown state
    // by a previous run. shutdown() is idempotent.
    lf.framework.shutdown();

    var req = try lf.DataHandle.create("add");
    defer req.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, 1, .little);
    try req.writeBytes(&buf);
    std.mem.writeInt(i32, &buf, 2, .little);
    try req.writeBytes(&buf);

    var sync = Sync{};

    // Unpack the error union with `catch` for clarity.
    const void_result = lf.async_call.callAsync(
        "__no_such_app_in_dispatch_failure_step__",
        &req,
        &sync,
        AsyncProbe.handle,
    );

    const dispatched: bool = if (void_result) |_| true else |_| false;
    try check(log, !dispatched, "callAsync returned an error");

    if (void_result) |_| {
        // Unreachable after the check above; the compiler needs the
        // branch to be exhaustive.
    } else |err| {
        try check(log, err == lf.Error.CallFailed, "returns CallFailed");
    }

    try check(log, sync.done.load(.acquire), "handler fired synchronously");
    try check(log, sync.err != null, "handler received .err");
    if (sync.err) |e| {
        try check(log, e == lf.Error.CallFailed, ".err is CallFailed");
    }

    if (sync.payload) |p| std.heap.page_allocator.free(p);

    log.line("[ok]   dispatch failure");
}

fn setupFramework(log: *Log) !lf.AppHandle {
    log.line("[step] framework setup");

    try lf.options.setWaitConnectionReadyOk(false);
    try lf.options.setOverlapConnection(true);
    try lf.options.setQuiet(true);

    lf.framework.resetPrepare();

    var app = try lf.AppHandle.create(APP_NAME, "Zig async smoke");
    errdefer app.deinit();

    try app.registerCall("add", "add two i32 values", null, addHandler);

    const service_tag = try lf.framework.prepareService(ENDPOINT, ENDPOINT);
    log.fmt("      service tag = {d}", .{service_tag});

    const client_tag = try lf.framework.prepareClient(ENDPOINT, &app);
    log.fmt("      client tag  = {d}", .{client_tag});

    const started = lf.framework.prepareDone();
    try check(log, started, "prepareDone returned true");

    var i: usize = 0;
    var ok = false;
    while (i < 30) : (i += 1) {
        if (lf.framework.checkApi(APP_NAME, "add")) {
            ok = true;
            break;
        }
        Sleep(200);
    }
    try check(log, ok, "App/add became visible within 6 s");

    log.line("[ok]   framework setup");
    return app;
}

fn stepCallbackStyle(log: *Log) !void {
    log.line("[step] callback style: callAsync");

    var req = try lf.DataHandle.create("add");
    defer req.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, 5, .little);
    try req.writeBytes(&buf);
    std.mem.writeInt(i32, &buf, 7, .little);
    try req.writeBytes(&buf);

    var sync = Sync{};

    try lf.async_call.callAsync(APP_NAME, &req, &sync, AsyncProbe.handle);

    const bytes = try awaitSync(&sync, 10_000);
    defer std.heap.page_allocator.free(bytes);

    try check(log, bytes.len == 4, "response is 4 bytes");
    const sum = std.mem.readInt(i32, bytes[0..4], .little);
    try check(log, sum == 12, "5 + 7 == 12");

    log.fmt("      sum = {d}", .{sum});
    log.line("[ok]   callback style");
}

fn stepSequencedCallback(log: *Log) !void {
    log.line("[step] callback style: callAsyncSequenced");

    var req = try lf.DataHandle.create("add");
    defer req.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, 100, .little);
    try req.writeBytes(&buf);
    std.mem.writeInt(i32, &buf, 200, .little);
    try req.writeBytes(&buf);

    var sync = Sync{};

    try lf.async_call.callAsyncSequenced(APP_NAME, &req, &sync, AsyncProbe.handle);

    const bytes = try awaitSync(&sync, 10_000);
    defer std.heap.page_allocator.free(bytes);

    try check(log, bytes.len == 4, "response is 4 bytes");
    const sum = std.mem.readInt(i32, bytes[0..4], .little);
    try check(log, sum == 300, "100 + 200 == 300");

    log.fmt("      sum = {d}", .{sum});
    log.line("[ok]   sequenced callback");
}

fn stepBlockingStyle(log: *Log) !void {
    log.line("[step] blocking style: callAsyncWait");

    var req = try lf.DataHandle.create("add");
    defer req.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, 40, .little);
    try req.writeBytes(&buf);
    std.mem.writeInt(i32, &buf, 2, .little);
    try req.writeBytes(&buf);

    const bytes = try lf.async_call.callAsyncWait(
        APP_NAME,
        &req,
        @as(?u64, 10_000),
    );
    defer std.heap.page_allocator.free(bytes);

    try check(log, bytes.len == 4, "response is 4 bytes");
    const sum = std.mem.readInt(i32, bytes[0..4], .little);
    try check(log, sum == 42, "40 + 2 == 42");

    log.fmt("      sum = {d}", .{sum});
    log.line("[ok]   blocking style");
}

fn stepBlockingStyleAbsentApp(log: *Log) !void {
    log.line("[step] blocking style: absent App returns an error");

    var req = try lf.DataHandle.create("add");
    defer req.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, 1, .little);
    try req.writeBytes(&buf);
    std.mem.writeInt(i32, &buf, 2, .little);
    try req.writeBytes(&buf);

    // Unpack the error union with `catch`. This is the unambiguous
    // form: the success path binds `bytes` to a `[]u8`, the error
    // path binds `err` to a `lf.Error`.
    const result = lf.async_call.callAsyncWait(
        "__definitely_absent_zig_async_smoke__",
        &req,
        @as(?u64, 2_000),
    );

    const bytes = result catch |err| {
        const ok = (err == lf.Error.CallFailed) or (err == lf.Error.Timeout);
        try check(log, ok, "returned CallFailed or Timeout");
        log.line("[ok]   absent App returns an error");
        return;
    };

    // Reaching this line means the call unexpectedly succeeded.
    std.heap.page_allocator.free(bytes);
    log.line("[FAIL] expected an error for an absent App");
    return error.AssertFailed;
}

fn teardownFramework(log: *Log, app: *lf.AppHandle) void {
    log.line("[step] framework teardown");
    app.deinit();
    lf.framework.exitMainThread();
    lf.framework.shutdown();
    log.line("[ok]   framework teardown");
}

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("async_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open async_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig async smoke test");
    log.line("================================================================");

    lf.framework.init() catch |err| {
        log.fmt("[FATAL] framework.init failed: {}", .{err});
        exit(1);
    };
    defer lf.framework.deinit();

    var passed: usize = 0;
    var failed: usize = 0;

    // Step 1: dispatch failure, before any framework is running.
    log.line("");
    stepDispatchFailure(&log) catch |err| {
        failed += 1;
        log.fmt("[FAIL] step 'dispatch failure' failed: {}", .{err});
    };
    if (failed == 0) passed += 1;

    // Step 2: framework setup. If this fails, the following steps
    // cannot run.
    log.line("");
    var app = setupFramework(&log) catch |err| {
        log.fmt("[FATAL] framework setup failed: {}", .{err});
        log.line("");
        log.line("================================================================");
        log.fmt("  Results: {d} passed, {d} failed", .{ passed, failed + 1 });
        log.line("================================================================");
        exit(1);
    };
    passed += 1;

    // Steps 3 - 6: the async call family against the live framework.
    const post_setup_steps = [_]struct {
        name: []const u8,
        fn_: *const fn (*Log) anyerror!void,
    }{
        .{ .name = "callback style", .fn_ = stepCallbackStyle },
        .{ .name = "sequenced callback", .fn_ = stepSequencedCallback },
        .{ .name = "blocking style", .fn_ = stepBlockingStyle },
        .{ .name = "absent App", .fn_ = stepBlockingStyleAbsentApp },
    };

    for (post_setup_steps) |step| {
        log.line("");
        step.fn_(&log) catch |err| {
            failed += 1;
            log.fmt("[FAIL] step '{s}' failed: {}", .{ step.name, err });
            continue;
        };
        passed += 1;
    }

    log.line("");
    teardownFramework(&log, &app);

    log.line("");
    log.line("================================================================");
    log.fmt("  Results: {d} passed, {d} failed, {d} total", .{
        passed, failed, passed + failed,
    });
    log.line("================================================================");

    if (failed != 0) exit(1);
}
