// =============================================================================
//  addressing_smoke.zig - Smoke test for the three addressing schemes.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  Same reason as the other smoke tests.
//
//  Coverage
//  --------
//  This file brings up a same-process service + client pair and
//  exercises the complete SYNCHRONOUS addressing surface:
//
//      1. App-name addressing : framework.call
//      2. UID addressing      : callByUid, with the UID obtained
//                               through a `whoami` probe
//      3. P2PName addressing  : callByP2PName, with the group name set
//                               via `options.setP2PName`
//
//  Plus the four extra query APIs:
//
//      * checkUid        / checkUidApi
//      * checkP2PName    / checkP2PNameApi
//
//  including negative-path assertions (null UID, absent group).
//
//  Routing note
//  ------------
//  The service and the client share a process here, so:
//
//      * App-name routing takes the mesh's local-first path.
//      * UID routing also takes the local-first path (same reason).
//      * P2PName routing is NOT local-first: even in this configuration
//        the call is forwarded to the server-side dispatcher through
//        the IPC loopback, because the dispatcher owns the load-balancing
//        state.
//
//  All three assertions are therefore meaningful.
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
// Configuration
// =============================================================================

const APP_NAME = "ZigAddressingSmokeApp";
const ENDPOINT = "ipc:zig_addressing_smoke";
const P2P_GROUP = "zig_addressing_smoke_group";

// =============================================================================
// Handlers and payloads
// =============================================================================

const AddArgs = struct { a: i32, b: i32 };
const AddResult = struct { sum: i32 };

fn addHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;

    var buf: [4]u8 = undefined;
    _ = try input.readBytes(&buf);
    const a = std.mem.readInt(i32, &buf, .little);
    _ = try input.readBytes(&buf);
    const b = std.mem.readInt(i32, &buf, .little);

    const sum = a +% b;
    std.mem.writeInt(i32, &buf, sum, .little);
    try output.writeBytes(&buf);
}

const WhoamiRequest = struct {};
const WhoamiResult = struct {
    uid_hex: []const u8,
    p2p_name: []const u8,
};

fn whoamiHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    const alloc = std.heap.page_allocator;

    const uid = input.p2pUid() catch lf.Uid.NULL;
    const name: [:0]u8 = input.p2pName(alloc) catch |e| return e;
    defer alloc.free(name);

    var uid_hex: [64]u8 = undefined;
    uid.toHexBuf(&uid_hex);

    try lf.io.writeJson(output, WhoamiResult{
        .uid_hex = &uid_hex,
        .p2p_name = name,
    });
}

// =============================================================================
// Global framework state
// =============================================================================

var g_app: ?lf.AppHandle = null;
var g_my_uid: lf.Uid = lf.Uid.NULL;

// =============================================================================
// Helpers
// =============================================================================

/// Poll a predicate every 200 ms, up to 30 times (6 s total).
fn waitUntil(f: *const fn () bool) bool {
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        if (f()) return true;
        Sleep(200);
    }
    return false;
}

/// Call the `add` API via the given addressing scheme and return the
/// sum.
fn probeAdd(
    log: *Log,
    scheme: enum { app_name, uid, p2p_name },
) !i32 {
    var req = try lf.DataHandle.create("add");
    defer req.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, 40, .little);
    try req.writeBytes(&buf);
    std.mem.writeInt(i32, &buf, 2, .little);
    try req.writeBytes(&buf);

    var resp = switch (scheme) {
        .app_name => try lf.framework.call(APP_NAME, &req, 5000),
        .uid => try lf.framework.callByUid(g_my_uid, &req, 5000),
        .p2p_name => try lf.framework.callByP2PName(P2P_GROUP, &req, 5000),
    };
    defer resp.deinit();

    try check(log, (try resp.size()) == 4, "response size 4");
    try resp.setPosition(0);

    var out: [4]u8 = undefined;
    _ = try resp.readBytes(&out);
    return std.mem.readInt(i32, &out, .little);
}

// =============================================================================
// Steps
// =============================================================================

fn stepSetup(log: *Log) !void {
    log.line("[step] setup: register whoami + add, start framework");

    try lf.options.setP2PName(P2P_GROUP);
    try lf.options.setQuiet(true);
    try lf.options.setWaitConnectionReadyOk(false);
    try lf.options.setOverlapConnection(true);

    lf.framework.resetPrepare();

    var app = try lf.AppHandle.create(APP_NAME, "Zig addressing smoke");
    errdefer app.deinit();

    try app.registerCall("whoami", "identity probe", null, whoamiHandler);
    try app.registerCall("add", "add two i32 values", null, addHandler);

    const service_tag = try lf.framework.prepareService(ENDPOINT, ENDPOINT);
    log.fmt("      service tag = {d}", .{service_tag});

    const client_tag = try lf.framework.prepareClient(ENDPOINT, &app);
    log.fmt("      client tag  = {d}", .{client_tag});

    const started = lf.framework.prepareDone();
    try check(log, started, "prepareDone returned true");

    g_app = app;

    const ok = waitUntil(struct {
        fn f() bool {
            return lf.framework.checkApi(APP_NAME, "whoami");
        }
    }.f);
    try check(log, ok, "App/whoami visible within 6 s");

    log.line("[ok]   setup");
}

fn stepProbeOwnUid(log: *Log) !void {
    log.line("[step] probe own UID via whoami");

    var req = try lf.DataHandle.create("whoami");
    defer req.deinit();
    try lf.io.writeJson(&req, WhoamiRequest{});

    var resp = try lf.framework.call(APP_NAME, &req, 5000);
    defer resp.deinit();

    try resp.setPosition(0);
    var parsed = try lf.io.readJson(
        &resp,
        std.heap.page_allocator,
        WhoamiResult,
    );
    defer parsed.deinit();

    try check(log, parsed.value.uid_hex.len == 64, "UID hex is 64 chars");

    const uid = try lf.Uid.fromHex(parsed.value.uid_hex);
    try check(log, !uid.isNull(), "own UID non-null");

    // Second probe must return the same UID.
    var req2 = try lf.DataHandle.create("whoami");
    defer req2.deinit();
    try lf.io.writeJson(&req2, WhoamiRequest{});

    var resp2 = try lf.framework.call(APP_NAME, &req2, 5000);
    defer resp2.deinit();

    try resp2.setPosition(0);
    var parsed2 = try lf.io.readJson(
        &resp2,
        std.heap.page_allocator,
        WhoamiResult,
    );
    defer parsed2.deinit();

    try check(
        log,
        std.mem.eql(u8, parsed.value.uid_hex, parsed2.value.uid_hex),
        "UID stable across two probes",
    );

    // Store the UID BEFORE waiting, so that the predicate sees it.
    g_my_uid = uid;

    const ok = waitUntil(struct {
        fn f() bool {
            return lf.framework.checkUid(g_my_uid);
        }
    }.f);
    try check(log, ok, "own UID became routable within 6 s");

    log.fmt("      own UID = {s}", .{parsed.value.uid_hex});
    log.line("[ok]   probe own UID");
}

fn stepAppNameAddressing(log: *Log) !void {
    log.line("[step] App-name addressing: call");

    const sum = try probeAdd(log, .app_name);
    try check(log, sum == 42, "40 + 2 == 42");

    log.fmt("      sum = {d}", .{sum});
    log.line("[ok]   App-name addressing");
}

fn stepUidAddressing(log: *Log) !void {
    log.line("[step] UID addressing: callByUid");

    try check(log, !g_my_uid.isNull(), "UID captured by previous step");

    const sum = try probeAdd(log, .uid);
    try check(log, sum == 42, "40 + 2 == 42");

    log.fmt("      sum = {d}", .{sum});
    log.line("[ok]   UID addressing");
}

fn stepP2PNameAddressing(log: *Log) !void {
    log.line("[step] P2PName addressing: callByP2PName");

    const ok = waitUntil(struct {
        fn f() bool {
            return lf.framework.checkP2PName(P2P_GROUP);
        }
    }.f);
    try check(log, ok, "P2P group visible within 6 s");

    const sum = try probeAdd(log, .p2p_name);
    try check(log, sum == 42, "40 + 2 == 42");

    log.fmt("      sum = {d}", .{sum});
    log.line("[ok]   P2PName addressing");
}

fn stepQueries(log: *Log) !void {
    log.line("[step] queries: positive and negative paths");

    // --- Positive ---------------------------------------------------
    try check(log, lf.framework.checkUid(g_my_uid), "checkUid positive");
    try check(
        log,
        lf.framework.checkUidApi(g_my_uid, "add"),
        "checkUidApi positive",
    );
    try check(
        log,
        lf.framework.checkP2PName(P2P_GROUP),
        "checkP2PName positive",
    );
    try check(
        log,
        lf.framework.checkP2PNameApi(P2P_GROUP, "add"),
        "checkP2PNameApi positive",
    );

    // --- Negative ---------------------------------------------------
    try check(log, !lf.framework.checkUid(lf.Uid.NULL), "null UID negative");
    try check(
        log,
        !lf.framework.checkUidApi(lf.Uid.NULL, "add"),
        "null UID api negative",
    );
    try check(
        log,
        !lf.framework.checkP2PName("__absent_group_in_smoke__"),
        "absent group negative",
    );
    try check(
        log,
        !lf.framework.checkP2PNameApi("__absent_group_in_smoke__", "add"),
        "absent group api negative",
    );
    try check(
        log,
        !lf.framework.checkApp("__absent_app_in_smoke__"),
        "absent App negative",
    );

    log.line("[ok]   queries");
}

fn stepTeardown(log: *Log) !void {
    log.line("[step] teardown");

    if (g_app) |*app| {
        app.deinit();
        g_app = null;
    }
    lf.framework.exitMainThread();
    lf.framework.shutdown();

    log.line("[ok]   teardown");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "setup", .fn_ = stepSetup },
    .{ .name = "probe own UID", .fn_ = stepProbeOwnUid },
    .{ .name = "App-name addressing", .fn_ = stepAppNameAddressing },
    .{ .name = "UID addressing", .fn_ = stepUidAddressing },
    .{ .name = "P2PName addressing", .fn_ = stepP2PNameAddressing },
    .{ .name = "queries", .fn_ = stepQueries },
    .{ .name = "teardown", .fn_ = stepTeardown },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("addressing_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open addressing_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig addressing smoke test");
    log.line("================================================================");

    lf.framework.init() catch |err| {
        log.fmt("[FATAL] framework.init failed: {}", .{err});
        exit(1);
    };
    defer lf.framework.deinit();

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

    if (failed != 0) exit(1);
}
