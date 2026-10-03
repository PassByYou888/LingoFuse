// =============================================================================
//  status_smoke.zig - Smoke test for the status queue API.
// -----------------------------------------------------------------------------
//  Same normal-program pattern as the other smoke tests.
//
//  Coverage
//  --------
//      * getStatusCount    - non-negative, snapshot
//      * postStatus        - accepts a message without crashing
//      * getStatus         - returns an allocator-owned slice
//      * drainStatus       - max_messages == 0 short-circuits
//      * drainStatus       - small batch returns a well-formed slice
//
//  What this test does NOT cover
//  -----------------------------
//  The native status queue is only processed while the simulated main
//  thread is running. Starting that thread requires `prepareDone`,
//  which is a process-global one-shot operation; the ABI / IO smoke
//  tests already exercise the prepare / shutdown cycle. This test
//  therefore runs entirely against the pre-start state, which is a
//  supported (if limited) usage mode documented in the module
//  docstring of `status.zig`.
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
// C stdio
// -----------------------------------------------------------------------------

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fflush(stream: *anyopaque) c_int;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn exit(code: c_int) noreturn;

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
// Steps
// =============================================================================

fn stepCountNonNegative(log: *Log) !void {
    log.line("[step] status: getStatusCount is non-negative");

    const n = lf.status.getStatusCount();
    try check(log, n >= 0, "count >= 0");

    log.line("[ok]   count non-negative");
}

fn stepPostStatus(log: *Log) !void {
    log.line("[step] status: postStatus accepts a message");

    // `postStatus` is documented as safe to call before the framework
    // has started. It queues the message; the native layer processes
    // it once the simulated main thread is running. This step only
    // verifies that the call itself does not crash.
    lf.status.postStatus("zig status smoke: hello");

    log.line("[ok]   postStatus");
}

fn stepGetStatusReturnsSlice(log: *Log) !void {
    log.line("[step] status: getStatus returns an allocator-owned slice");

    const alloc = std.heap.page_allocator;
    const msg = try lf.status.getStatus(alloc);
    defer alloc.free(msg);

    // The slice is always NUL-terminated at index `msg.len`.
    try check(log, msg[msg.len] == 0, "sentinel is NUL");

    log.line("[ok]   getStatus returns a slice");
}

fn stepDrainZeroIsNoop(log: *Log) !void {
    log.line("[step] status: drainStatus(0) returns an empty slice");

    const alloc = std.heap.page_allocator;
    const msgs = try lf.status.drainStatus(alloc, 0);
    defer alloc.free(msgs);

    try check(log, msgs.len == 0, "empty result");

    log.line("[ok]   drainStatus(0)");
}

fn stepDrainSmallBatch(log: *Log) !void {
    log.line("[step] status: drainStatus(16) returns a well-formed slice");

    const alloc = std.heap.page_allocator;
    const msgs = try lf.status.drainStatus(alloc, 16);
    defer {
        for (msgs) |m| alloc.free(m);
        alloc.free(msgs);
    }

    // The result may be empty (no messages pending) or contain
    // messages; either is fine. The only invariant we can assert in
    // this test is that every returned element is a valid
    // NUL-terminated slice.
    for (msgs) |m| {
        if (m[m.len] != 0) {
            log.line("[FAIL] drained message is not NUL-terminated");
            return error.AssertFailed;
        }
    }

    log.line("[ok]   drainStatus(16)");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "count non-negative", .fn_ = stepCountNonNegative },
    .{ .name = "postStatus", .fn_ = stepPostStatus },
    .{ .name = "getStatus returns slice", .fn_ = stepGetStatusReturnsSlice },
    .{ .name = "drainStatus(0)", .fn_ = stepDrainZeroIsNoop },
    .{ .name = "drainStatus(16)", .fn_ = stepDrainSmallBatch },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("status_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open status_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig status queue smoke test");
    log.line("================================================================");

    var passed: usize = 0;
    var failed: usize = 0;

    for (ALL_STEPS) |step| {
        log.line("");
        step.fn_(&log) catch |err| {
            failed += 1;
            log.fmt("[FAIL] step '{s}' failed: {}", .{ step.name, err });
            continue;
        };
        passed += 1;
    }

    log.line("");
    log.line("================================================================");
    log.fmt("  Results: {d} passed, {d} failed, {d} total", .{ passed, failed, passed + failed });
    log.line("================================================================");

    if (failed != 0) exit(1);
}
