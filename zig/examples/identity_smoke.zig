// =============================================================================
//  identity_smoke.zig - Smoke test for P2P identity side data.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  Same reason as the other smoke tests.
//
//  Coverage
//  --------
//  This file exercises the two side-data accessors on `DataHandle`:
//
//      * p2pUid()   -> Uid
//      * p2pName()  -> [:0]u8 (allocator-owned)
//
//  in two concrete scenarios:
//
//      1. A caller-created OWNING handle: both accessors must yield the
//         documented zero / empty values.
//      2. The `input` argument of a registered callback triggered by a
//         local call: the UID must be non-null and the name must match
//         the configured P2P group name. The `output` argument of the
//         same callback must yield the zero / empty values.
//
//  The test brings up a same-process service + client pair, sets a
//  known P2P group name, registers a `whoami` API, and calls it. The
//  callback inspects both handles and returns the observed values to
//  the caller, which verifies them independently.
//
//  What this test does NOT cover
//  -----------------------------
//  Cross-process identity propagation. The service and the client
//  share a process here, so the mesh takes its local-first routing
//  path. Local calls still inject identity (documented behaviour), so
//  the assertion is meaningful; but a cross-process hop would require
//  two OS processes.
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
// C stdio
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

const P2P_GROUP = "zig_identity_smoke_group";
const APP_NAME = "ZigIdentitySmokeApp";
const ENDPOINT = "ipc:zig_identity_smoke";

// =============================================================================
// Payloads
// =============================================================================

/// The whoami request payload (empty).
const WhoamiRequest = struct {};

/// The whoami response payload. Fields describe what the callback
/// observed on both the input and the output handles.
const WhoamiResponse = struct {
    input_uid_hex: []const u8,
    input_name: []const u8,
    input_uid_non_null: bool,
    input_name_matches_group: bool,
    output_uid_is_null: bool,
    output_name_is_empty: bool,
};

// =============================================================================
// Callback
// =============================================================================

fn whoamiCallback(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    const alloc = std.heap.page_allocator;

    // --- input handle side data -------------------------------------
    const in_uid = input.p2pUid() catch lf.Uid.NULL;
    const in_name: [:0]u8 = input.p2pName(alloc) catch |e| return e;
    defer alloc.free(in_name);

    // --- output handle side data ------------------------------------
    const out_uid = output.p2pUid() catch lf.Uid.NULL;
    const out_name: [:0]u8 = output.p2pName(alloc) catch |e| return e;
    defer alloc.free(out_name);

    // --- encode result ----------------------------------------------
    var uid_hex: [64]u8 = undefined;
    in_uid.toHexBuf(&uid_hex);

    const payload = WhoamiResponse{
        .input_uid_hex = &uid_hex,
        .input_name = in_name,
        .input_uid_non_null = !in_uid.isNull(),
        .input_name_matches_group = std.mem.eql(u8, in_name, P2P_GROUP),
        .output_uid_is_null = out_uid.isNull(),
        .output_name_is_empty = out_name.len == 0,
    };

    try lf.io.writeJson(output, payload);
}

// =============================================================================
// Steps
// =============================================================================

fn stepOwningHandleAccessors(log: *Log) !void {
    log.line("[step] owning handle: accessors return zero / empty");

    var h = try lf.DataHandle.create("identity_probe_owning");
    defer h.deinit();

    const uid = try h.p2pUid();
    try check(log, uid.isNull(), "owning handle UID is NULL");

    const alloc = std.heap.page_allocator;
    const name = try h.p2pName(alloc);
    defer alloc.free(name);
    try check(log, name.len == 0, "owning handle name is empty");

    log.line("[ok]   owning handle accessors");
}

fn waitForApi(app_name: [:0]const u8, api_name: [:0]const u8) bool {
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        if (lf.framework.checkApi(app_name, api_name)) return true;
        Sleep(200);
    }
    return false;
}

fn stepCallbackIdentity(log: *Log) !void {
    log.line("[step] callback: input carries identity, output does not");

    try lf.options.setP2PName(P2P_GROUP);
    try lf.options.setQuiet(true);
    try lf.options.setWaitConnectionReadyOk(false);
    try lf.options.setOverlapConnection(true);

    lf.framework.resetPrepare();

    var app = try lf.AppHandle.create(APP_NAME, "Zig identity smoke");
    defer app.deinit();

    try app.registerCall("whoami", "identity probe", null, whoamiCallback);

    const service_tag = try lf.framework.prepareService(ENDPOINT, ENDPOINT);
    log.fmt("      service tag = {d}", .{service_tag});

    const client_tag = try lf.framework.prepareClient(ENDPOINT, &app);
    log.fmt("      client tag  = {d}", .{client_tag});

    const started = lf.framework.prepareDone();
    try check(log, started, "prepareDone returned true");

    if (!waitForApi(APP_NAME, "whoami")) {
        log.line("[FAIL] App/whoami never became visible within 6 s");
        return error.AssertFailed;
    }

    var req = try lf.DataHandle.create("whoami");
    defer req.deinit();
    try lf.io.writeJson(&req, WhoamiRequest{});

    var resp = try lf.framework.call(APP_NAME, &req, 5000);
    defer resp.deinit();

    try resp.setPosition(0);

    // io.readJson(handle, alloc, T) -> Parsed(T)
    var parsed = try lf.io.readJson(
        &resp,
        std.heap.page_allocator,
        WhoamiResponse,
    );
    defer parsed.deinit();

    try check(log, parsed.value.input_uid_non_null, "input UID non-null");
    try check(
        log,
        parsed.value.input_name_matches_group,
        "input name matches configured group",
    );
    try check(log, parsed.value.output_uid_is_null, "output UID is NULL");
    try check(
        log,
        parsed.value.output_name_is_empty,
        "output name is empty",
    );

    log.fmt("      input UID  = {s}", .{parsed.value.input_uid_hex});
    log.fmt("      input name = {s}", .{parsed.value.input_name});

    lf.framework.exitMainThread();
    lf.framework.shutdown();

    log.line("[ok]   callback identity");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "owning handle accessors", .fn_ = stepOwningHandleAccessors },
    .{ .name = "callback identity", .fn_ = stepCallbackIdentity },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("identity_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open identity_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig P2P identity smoke test");
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
