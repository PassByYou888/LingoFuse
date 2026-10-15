// =============================================================================
//  p2p_smoke.zig - Smoke test for process-wide P2P registration.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  Same reason as the other smoke tests.
//
//  Coverage
//  --------
//  The lifecycle of a process-wide P2P API, without ever starting the
//  simulated main thread:
//
//      * Register a Call API, unregister it, verify the boolean result
//      * Unregister an unknown name
//      * Duplicate registration is rejected
//      * Re-register after unregister succeeds
//      * Register a Notify API and unregister it
//
//  The process-wide P2P namespace is INDEPENDENT of any App and is
//  available as soon as the DLL is loaded. It does not require
//  `prepareService` / `prepareClient` / `prepareDone`, so this smoke
//  test runs quickly and does not acquire any network resources.
//
//  What this test does NOT cover
//  -----------------------------
//  Actually CALLING a P2P API. That requires a running framework and a
//  real session UID / P2P group name; it is covered by
//  `addressing_smoke.zig`.
//
//  Context leak
//  ------------
//  Each successful registration leaks a small context block (see the
//  module docstring of `src/p2p.zig`). This is by design: the native
//  scheduler may invoke a callback at any time after registration,
//  including concurrently with an unregister call. The cost is
//  bounded by the number of registered APIs.
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
// Loader
// -----------------------------------------------------------------------------

var g_loaded: bool = false;

fn ensureLoaded(log: *Log) !void {
    if (g_loaded) return;
    log.line("[step] framework.init");
    try lf.framework.init();
    g_loaded = true;
    log.line("[ok]   framework.init");
}

// =============================================================================
// Handlers
// =============================================================================
//
// These handlers are never invoked by this smoke test (no framework is
// running and no request is issued), but they must have the correct
// signature so that the registration path can be exercised.

fn dummyCallHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    _ = input;
    _ = output;
}

fn dummyNotifyHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    _ = input;
}

// =============================================================================
// Steps
// =============================================================================

fn stepUnregisterUnknown(log: *Log) !void {
    log.line("[step] unregister an unknown name returns false");

    const present = try lf.p2p.unregisterP2P("__definitely_absent_zig_p2p__");
    try check(log, !present, "unknown name -> false");

    log.line("[ok]   unregister unknown");
}

fn stepCallRoundtrip(log: *Log) !void {
    log.line("[step] register P2P Call, then unregister");

    const name = "__zig_p2p_smoke_call__";

    // Defensive: ensure a clean slate.
    _ = lf.p2p.unregisterP2P(name) catch {};

    try lf.p2p.registerP2PCall(name, "smoke test", null, dummyCallHandler);
    const present = try lf.p2p.unregisterP2P(name);
    try check(log, present, "first unregister -> true");

    // Second unregister must be a no-op.
    const second = try lf.p2p.unregisterP2P(name);
    try check(log, !second, "second unregister -> false");

    log.line("[ok]   Call roundtrip");
}

fn stepDuplicateRejected(log: *Log) !void {
    log.line("[step] duplicate P2P Call registration is rejected");

    const name = "__zig_p2p_smoke_dup__";
    _ = lf.p2p.unregisterP2P(name) catch {};

    try lf.p2p.registerP2PCall(name, "first", null, dummyCallHandler);

    const second = lf.p2p.registerP2PCall(name, "second", null, dummyCallHandler);
    try check(
        log,
        std.meta.isError(second) and second == error.RegistrationFailed,
        "duplicate -> RegistrationFailed",
    );

    // Clean up so a re-run starts from a known state.
    _ = try lf.p2p.unregisterP2P(name);

    log.line("[ok]   duplicate rejected");
}

fn stepReRegister(log: *Log) !void {
    log.line("[step] re-register after unregister succeeds");

    const name = "__zig_p2p_smoke_rereg__";
    _ = lf.p2p.unregisterP2P(name) catch {};

    try lf.p2p.registerP2PCall(name, "v1", null, dummyCallHandler);
    _ = try lf.p2p.unregisterP2P(name);

    // Re-registering with the same name must succeed because the
    // previous registration has been removed.
    try lf.p2p.registerP2PCall(name, "v2", null, dummyCallHandler);

    _ = try lf.p2p.unregisterP2P(name);

    log.line("[ok]   re-register");
}

fn stepNotifyRoundtrip(log: *Log) !void {
    log.line("[step] register P2P Notify, then unregister");

    const name = "__zig_p2p_smoke_notify__";
    _ = lf.p2p.unregisterP2P(name) catch {};

    try lf.p2p.registerP2PNotify(name, "smoke test", null, dummyNotifyHandler);
    try check(log, try lf.p2p.unregisterP2P(name), "unregister notify");

    log.line("[ok]   Notify roundtrip");
}

fn stepCoexistsWithAppNamespace(log: *Log) !void {
    log.line("[step] P2P namespace is independent of the App namespace");

    const api_name = "__zig_p2p_smoke_coexist__";
    _ = lf.p2p.unregisterP2P(api_name) catch {};

    // Register an App-bound API and a P2P API with the SAME name.
    // Both registrations must succeed, because they live in different
    // namespaces.
    var app = try lf.AppHandle.create("ZigP2PCoexistApp", "smoke");
    defer app.deinit();

    try app.registerCall(api_name, "app-bound", null, dummyCallHandler);
    try lf.p2p.registerP2PCall(api_name, "p2p", null, dummyCallHandler);

    // Unregister the P2P copy. The App-bound copy must remain.
    try check(log, try lf.p2p.unregisterP2P(api_name), "unregister p2p");
    try check(log, try app.unregister(api_name), "app copy still present");

    log.line("[ok]   namespaces are independent");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "unregister unknown", .fn_ = stepUnregisterUnknown },
    .{ .name = "Call roundtrip", .fn_ = stepCallRoundtrip },
    .{ .name = "duplicate rejected", .fn_ = stepDuplicateRejected },
    .{ .name = "re-register", .fn_ = stepReRegister },
    .{ .name = "Notify roundtrip", .fn_ = stepNotifyRoundtrip },
    .{ .name = "namespace coexistence", .fn_ = stepCoexistsWithAppNamespace },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("p2p_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open p2p_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig P2P registration smoke test");
    log.line("================================================================");

    ensureLoaded(&log) catch |err| {
        log.fmt("[FATAL] framework.init failed: {}", .{err});
        exit(1);
    };

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
    log.fmt("  Results: {d} passed, {d} failed, {d} total", .{
        passed, failed, passed + failed,
    });
    log.line("================================================================");

    lf.framework.deinit();

    if (failed != 0) exit(1);
}
