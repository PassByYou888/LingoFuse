// =============================================================================
//  network_events_smoke.zig - Smoke test for the network event handler API.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  Same reason as the other smoke tests: the Zig test runner on
//  Windows can hang when the native LingoFuse library writes
//  diagnostics to the console. A normal executable sidesteps the
//  transport entirely, and every step is written to a log file before
//  and after each native call, so a hang leaves a usable trace.
//
//  Coverage
//  --------
//  Every public function of `src/network_events.zig`:
//
//      * setNetworkEvent      (install both / only connect / only disconnect)
//      * clearNetworkEvent
//      * isInstalled
//      * isConnectInstalled
//      * isDisconnectInstalled
//
//  What this test does NOT cover
//  -----------------------------
//  A real callback invocation requires a second process to join the
//  mesh and trigger the underlying native event. That path can only be
//  exercised by a two-process integration test, which is out of scope
//  for a single-process smoke test.
//
//  The test therefore verifies only the install / query / clear
//  lifecycle of the module itself, which is what a caller can
//  meaningfully assert from a single process.
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

// -----------------------------------------------------------------------------
// Handler bodies
// -----------------------------------------------------------------------------
//
// The handlers are never actually invoked by this smoke test (no
// network activity), but they must be real functions with the correct
// signature so that the install path can be exercised.

var g_connect_call_count: usize = 0;
var g_disconnect_call_count: usize = 0;

fn onConnect(ctx: ?*anyopaque, addr: []const u8) void {
    _ = ctx;
    _ = addr;
    g_connect_call_count += 1;
}

fn onDisconnect(ctx: ?*anyopaque, addr: []const u8) void {
    _ = ctx;
    _ = addr;
    g_disconnect_call_count += 1;
}

// =============================================================================
// Steps
// =============================================================================

fn stepInitialState(log: *Log) !void {
    log.line("[step] network_events: initial state is uninstalled");

    try check(log, !lf.network_events.isInstalled(), "not installed");
    try check(log, !lf.network_events.isConnectInstalled(), "connect clear");
    try check(log, !lf.network_events.isDisconnectInstalled(), "disconnect clear");

    log.line("[ok]   initial state");
}

fn stepInstallBoth(log: *Log) !void {
    log.line("[step] network_events: install both handlers");

    lf.network_events.setNetworkEvent(onConnect, null, onDisconnect, null);

    try check(log, lf.network_events.isInstalled(), "installed");
    try check(log, lf.network_events.isConnectInstalled(), "connect");
    try check(log, lf.network_events.isDisconnectInstalled(), "disconnect");

    log.line("[ok]   install both");
}

fn stepReplaceWithOnlyConnect(log: *Log) !void {
    log.line("[step] network_events: replace with only connect");

    // Second call discards the previous handlers (replace semantics).
    lf.network_events.setNetworkEvent(onConnect, null, null, null);

    try check(log, lf.network_events.isInstalled(), "still installed");
    try check(log, lf.network_events.isConnectInstalled(), "connect kept");
    try check(log, !lf.network_events.isDisconnectInstalled(), "disconnect dropped");

    log.line("[ok]   replace with only connect");
}

fn stepReplaceWithOnlyDisconnect(log: *Log) !void {
    log.line("[step] network_events: replace with only disconnect");

    lf.network_events.setNetworkEvent(null, null, onDisconnect, null);

    try check(log, lf.network_events.isInstalled(), "still installed");
    try check(log, !lf.network_events.isConnectInstalled(), "connect dropped");
    try check(log, lf.network_events.isDisconnectInstalled(), "disconnect kept");

    log.line("[ok]   replace with only disconnect");
}

fn stepClear(log: *Log) !void {
    log.line("[step] network_events: clear");

    lf.network_events.clearNetworkEvent();

    try check(log, !lf.network_events.isInstalled(), "not installed");
    try check(log, !lf.network_events.isConnectInstalled(), "connect clear");
    try check(log, !lf.network_events.isDisconnectInstalled(), "disconnect clear");

    log.line("[ok]   clear");
}

fn stepClearIdempotent(log: *Log) !void {
    log.line("[step] network_events: clear is idempotent");

    lf.network_events.clearNetworkEvent();
    lf.network_events.clearNetworkEvent();

    try check(log, !lf.network_events.isInstalled(), "still uninstalled");

    log.line("[ok]   clear idempotent");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "initial state", .fn_ = stepInitialState },
    .{ .name = "install both", .fn_ = stepInstallBoth },
    .{ .name = "replace with only connect", .fn_ = stepReplaceWithOnlyConnect },
    .{ .name = "replace with only disconnect", .fn_ = stepReplaceWithOnlyDisconnect },
    .{ .name = "clear", .fn_ = stepClear },
    .{ .name = "clear idempotent", .fn_ = stepClearIdempotent },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("network_events_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open network_events_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig network events smoke test");
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
