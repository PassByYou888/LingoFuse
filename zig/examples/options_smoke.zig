// =============================================================================
//  options_smoke.zig - Smoke test for the typed options API.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  Same reason as the other smoke tests.
//
//  Coverage
//  --------
//  Every getter / setter pair that `options.zig` exposes, plus the
//  stringly-typed `framework.getOption` / `framework.setOption` for
//  cross-checking:
//
//      * Boolean round-trip       (Quiet, ShowThreadID)
//      * Integer round-trip       (Wait_Connection_Timeout, IPC_Serv_ThreadCount)
//      * String round-trip        (LF_P2P_name)
//      * Unknown option fallback  (empty string / 0 / false)
//      * Password masking         (never returns the plaintext)
//      * Typed getter == raw getter
//      * Write-only `debug` option
//
//  What this test does NOT cover
//  -----------------------------
//  Any option whose effect is only observable through a running
//  framework (Overlap_Connection after prepareClient, Wait_Ready
//  during prepareDone, etc.). Those are covered end-to-end by the
//  cross-process demos and by the addressing suite.
//
//  Loader
//  ------
//  The test calls `framework.init()` to load the native library and
//  `framework.deinit()` on exit. It does NOT start the simulated main
//  thread; the framework's network layer is never initialised.
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
// Steps
// =============================================================================

fn stepBoolRoundtrip(log: *Log) !void {
    log.line("[step] boolean round-trip: Quiet");

    const alloc = std.heap.page_allocator;

    try lf.options.setQuiet(true);
    try check(log, try lf.options.getQuiet(alloc), "Quiet == true");

    try lf.options.setQuiet(false);
    try check(log, !(try lf.options.getQuiet(alloc)), "Quiet == false");

    // Restore the default so the step is side-effect free for the
    // next smoke test that shares this process.
    try lf.options.setQuiet(false);

    log.line("[ok]   boolean round-trip");
}

fn stepBoolRoundtripSecond(log: *Log) !void {
    log.line("[step] boolean round-trip: ShowThreadID");

    const alloc = std.heap.page_allocator;

    try lf.options.setShowThreadId(true);
    try check(log, try lf.options.getShowThreadId(alloc), "on");

    try lf.options.setShowThreadId(false);
    try check(log, !(try lf.options.getShowThreadId(alloc)), "off");

    log.line("[ok]   ShowThreadID round-trip");
}

fn stepU64Roundtrip(log: *Log) !void {
    log.line("[step] u64 round-trip: Wait_Connection_Timeout");

    const alloc = std.heap.page_allocator;

    try lf.options.setWaitConnectionTimeout(12_345);
    try check(
        log,
        try lf.options.getWaitConnectionTimeout(alloc) == 12_345,
        "12_345",
    );

    // Restore the documented default.
    try lf.options.setWaitConnectionTimeout(30_000);

    log.line("[ok]   u64 round-trip");
}

fn stepI64Roundtrip(log: *Log) !void {
    log.line("[step] i64 round-trip: IPC_Serv_ThreadCount");

    const alloc = std.heap.page_allocator;

    try lf.options.setIpcServThreadCount(4);
    try check(
        log,
        try lf.options.getIpcServThreadCount(alloc) == 4,
        "4",
    );

    log.line("[ok]   i64 round-trip");
}

fn stepStringRoundtrip(log: *Log) !void {
    log.line("[step] string round-trip: LF_P2P_name");

    const alloc = std.heap.page_allocator;

    try lf.options.setP2PName("zig_options_smoke_group");

    const name = try lf.options.getP2PName(alloc);
    defer alloc.free(name);
    try check(
        log,
        std.mem.eql(u8, name, "zig_options_smoke_group"),
        "name round-trip",
    );

    // Restore empty for subsequent tests.
    try lf.options.setP2PName("");

    const empty = try lf.options.getP2PName(alloc);
    defer alloc.free(empty);
    try check(log, empty.len == 0, "empty after reset");

    log.line("[ok]   string round-trip");
}

fn stepUnknownOptionFallback(log: *Log) !void {
    log.line("[step] unknown option falls back to safe defaults");

    const alloc = std.heap.page_allocator;

    const b = try lf.options.getBool(alloc, "__no_such_option_zig__");
    try check(log, !b, "bool -> false");

    const u = try lf.options.getU64(alloc, "__no_such_option_zig__");
    try check(log, u == 0, "u64 -> 0");

    const i = try lf.options.getI64(alloc, "__no_such_option_zig__");
    try check(log, i == 0, "i64 -> 0");

    const s = try lf.options.getString(alloc, "__no_such_option_zig__");
    defer alloc.free(s);
    try check(log, s.len == 0, "string -> empty");

    log.line("[ok]   unknown option fallback");
}

fn stepPasswordMasked(log: *Log) !void {
    log.line("[step] password getter never returns the plaintext");

    const alloc = std.heap.page_allocator;

    try lf.options.setPassword("zig_options_smoke_secret");
    const masked = try lf.options.getPassword(alloc);
    defer alloc.free(masked);

    try check(log, masked.len > 0, "non-empty mask");
    try check(
        log,
        std.mem.indexOf(u8, masked, "zig_options_smoke_secret") == null,
        "plaintext not present in mask",
    );

    log.line("[ok]   password masked");
}

fn stepTypedMatchesRaw(log: *Log) !void {
    log.line("[step] typed getter == raw framework.getOption");

    const alloc = std.heap.page_allocator;

    // Boolean option.
    try lf.options.setQuiet(true);
    try check(log, try lf.options.getQuiet(alloc), "typed true");
    {
        const raw = try lf.framework.getOption(alloc, "Quiet");
        defer alloc.free(raw);
        try check(
            log,
            std.ascii.eqlIgnoreCase(raw, "True"),
            "raw reads as \"True\"",
        );
    }
    try lf.options.setQuiet(false);

    // Integer option.
    try lf.options.setWaitConnectionTimeout(15_000);
    {
        const raw = try lf.framework.getOption(alloc, "Wait_Connection_Timeout");
        defer alloc.free(raw);
        try check(
            log,
            std.mem.eql(u8, raw, "15000"),
            "raw integer form is \"15000\"",
        );
    }
    try lf.options.setWaitConnectionTimeout(30_000);

    log.line("[ok]   typed == raw");
}

fn stepDebugWriteOnly(log: *Log) !void {
    log.line("[step] debug option accepts a write, getter returns placeholder");

    const alloc = std.heap.page_allocator;

    // The debug option executes a console command; on a framework that
    // has not been fully prepared, most commands are no-ops or print a
    // diagnostic. We only require that the setter does not crash and
    // that the getter returns something (possibly a placeholder).
    try lf.options.setDebug("service");

    const v = try lf.options.getDebug(alloc);
    defer alloc.free(v);
    // No content assertion; the native library decides what to return.

    log.line("[ok]   debug write / read");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "bool round-trip: Quiet", .fn_ = stepBoolRoundtrip },
    .{ .name = "bool round-trip: ShowThreadID", .fn_ = stepBoolRoundtripSecond },
    .{ .name = "u64 round-trip", .fn_ = stepU64Roundtrip },
    .{ .name = "i64 round-trip", .fn_ = stepI64Roundtrip },
    .{ .name = "string round-trip", .fn_ = stepStringRoundtrip },
    .{ .name = "unknown option fallback", .fn_ = stepUnknownOptionFallback },
    .{ .name = "password masked", .fn_ = stepPasswordMasked },
    .{ .name = "typed == raw", .fn_ = stepTypedMatchesRaw },
    .{ .name = "debug write-only", .fn_ = stepDebugWriteOnly },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("options_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open options_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig options smoke test");
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
