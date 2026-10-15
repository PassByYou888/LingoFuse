// =============================================================================
//  uid_smoke.zig - Smoke test for the UID value type and its ABI bridging.
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
//  The UID value type and its ABI bridging:
//
//      * Uid.NULL is the all-zero 32-byte value
//      * fromBytes / toBytes round-trip
//      * fromSlice length validation
//      * fromHex with optional 0x / 0X prefix and mixed case
//      * toHexBuf produces lowercase 64-character output
//      * toHexAlloc produces a NUL-terminated allocator-owned string
//      * toLf returns an extern struct with identical bytes
//      * fromPtr copies the bytes immediately (does not alias)
//      * eql compares by content
//
//  Plus the two null-UID-adjacent framework queries that do not
//  require a running framework:
//
//      * checkUid(Uid.NULL)          -> false
//      * checkUidApi(Uid.NULL, ...)  -> false
//
//  What this test does NOT cover
//  -----------------------------
//  UID-addressed invocation (callByUid / callAsyncByUid / ...). Those
//  require a running framework and a real session UID, which can only
//  be produced by an actual client tunnel. They are covered by the
//  cross-process addressing suite in a later batch.
//
//  Loader
//  ------
//  The test calls `framework.init()` to load the native library (so
//  that the framework queries below can be exercised) and
//  `framework.deinit()` on exit. It does NOT call `prepareService` /
//  `prepareClient` / `prepareDone`; the framework's simulated main
//  thread is never started, and no network resources are acquired.
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
// Shared literals
// =============================================================================

// A canonical 64-character UID string used by several steps.
const UID_HEX =
    "0123456789abcdef0123456789abcdef" ++
    "0123456789abcdef0123456789abcdef";

// =============================================================================
// Steps
// =============================================================================

fn stepNullUid(log: *Log) !void {
    log.line("[step] Uid: NULL is all-zero");

    try check(log, lf.Uid.NULL.isNull(), "isNull");

    const bytes = lf.Uid.NULL.toBytes();
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] != 0) {
            log.fmt("[FAIL] byte {d} is {d}, expected 0", .{ i, bytes[i] });
            return error.AssertFailed;
        }
    }
    log.line("[ok]   Uid.NULL");
}

fn stepFromBytesRoundtrip(log: *Log) !void {
    log.line("[step] Uid: fromBytes / toBytes round-trip");

    const source: [32]u8 = @splat(0x42);
    const uid = lf.Uid.fromBytes(source);

    const got = uid.toBytes();
    try check(log, std.mem.eql(u8, &source, &got), "byte round-trip");
    try check(log, !uid.isNull(), "non-null");

    log.line("[ok]   fromBytes / toBytes");
}

fn stepFromSliceLength(log: *Log) !void {
    log.line("[step] Uid: fromSlice validates length");

    const exact: [32]u8 = @splat(0xAA);
    const ok = lf.Uid.fromSlice(&exact);
    try check(log, ok != error.InvalidArgument, "exact-length accepted");

    const short: [31]u8 = @splat(0);
    const short_err = lf.Uid.fromSlice(&short);
    try check(
        log,
        std.meta.isError(short_err) and short_err == error.InvalidArgument,
        "short slice rejected",
    );

    const long: [33]u8 = @splat(0);
    const long_err = lf.Uid.fromSlice(&long);
    try check(
        log,
        std.meta.isError(long_err) and long_err == error.InvalidArgument,
        "long slice rejected",
    );

    log.line("[ok]   fromSlice");
}

fn stepFromHexParsing(log: *Log) !void {
    log.line("[step] Uid: fromHex accepts 0x / 0X prefix and mixed case");

    const lower = try lf.Uid.fromHex(UID_HEX);
    try check(log, !lower.isNull(), "lowercase accepted");

    const upper = try lf.Uid.fromHex(
        "0123456789ABCDEF0123456789ABCDEF" ++
            "0123456789ABCDEF0123456789ABCDEF",
    );
    try check(log, lower.eql(upper), "case-insensitive");

    const with_0x = try lf.Uid.fromHex(
        "0x" ++ UID_HEX,
    );
    try check(log, lower.eql(with_0x), "0x prefix stripped");

    const with_0X = try lf.Uid.fromHex(
        "0X" ++ UID_HEX,
    );
    try check(log, lower.eql(with_0X), "0X prefix stripped");

    const bad_len = lf.Uid.fromHex("abc");
    try check(
        log,
        std.meta.isError(bad_len) and bad_len == error.InvalidArgument,
        "short hex rejected",
    );

    log.line("[ok]   fromHex");
}

fn stepToHexBuf(log: *Log) !void {
    log.line("[step] Uid: toHexBuf produces lowercase 64-char output");

    const uid = try lf.Uid.fromHex(UID_HEX);
    var buf: [64]u8 = undefined;
    uid.toHexBuf(&buf);

    try check(log, std.mem.eql(u8, &buf, UID_HEX), "hex matches input");

    log.line("[ok]   toHexBuf");
}

fn stepToHexAlloc(log: *Log) !void {
    log.line("[step] Uid: toHexAlloc produces NUL-terminated string");

    const alloc = std.heap.page_allocator;
    const uid = try lf.Uid.fromHex(UID_HEX);
    const out = try uid.toHexAlloc(alloc);
    defer alloc.free(out);

    try check(log, out.len == 64, "length 64");
    try check(log, out[out.len] == 0, "sentinel NUL");
    try check(log, std.mem.eql(u8, out, UID_HEX), "content");

    log.line("[ok]   toHexAlloc");
}

fn stepToLf(log: *Log) !void {
    log.line("[step] Uid: toLf preserves bytes");

    const uid = try lf.Uid.fromHex(UID_HEX);
    const lf_struct = uid.toLf();
    try check(
        log,
        std.mem.eql(u8, &uid.toBytes(), &lf_struct.bytes),
        "toLf bytes",
    );

    log.line("[ok]   toLf");
}

fn stepFromPtrCopy(log: *Log) !void {
    log.line("[step] Uid: fromPtr copies bytes immediately");

    var backing: lf.sys.P2PUid = .{ .bytes = @splat(0x55) };
    const uid = lf.Uid.fromPtr(&backing);

    backing.bytes[0] = 0x99;
    try check(log, uid.toBytes()[0] == 0x55, "copy not aliased");

    log.line("[ok]   fromPtr");
}

fn stepEql(log: *Log) !void {
    log.line("[step] Uid: eql compares by content");

    const a = try lf.Uid.fromHex(UID_HEX);
    const b = try lf.Uid.fromHex(UID_HEX);
    const c = try lf.Uid.fromHex(
        "ffffffffffffffffffffffffffffffff" ++
            "ffffffffffffffffffffffffffffffff",
    );

    try check(log, a.eql(b), "equal");
    try check(log, !a.eql(c), "not equal");
    try check(log, !a.eql(lf.Uid.NULL), "not equal to NULL");

    log.line("[ok]   eql");
}

fn stepCheckUidNull(log: *Log) !void {
    log.line("[step] framework: checkUid(NULL) is false");

    try check(log, !lf.framework.checkUid(lf.Uid.NULL), "null UID never present");
    try check(
        log,
        !lf.framework.checkUidApi(lf.Uid.NULL, "any_api"),
        "null UID exposes no API",
    );

    log.line("[ok]   checkUid(NULL)");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "Uid.NULL", .fn_ = stepNullUid },
    .{ .name = "fromBytes / toBytes", .fn_ = stepFromBytesRoundtrip },
    .{ .name = "fromSlice length", .fn_ = stepFromSliceLength },
    .{ .name = "fromHex", .fn_ = stepFromHexParsing },
    .{ .name = "toHexBuf", .fn_ = stepToHexBuf },
    .{ .name = "toHexAlloc", .fn_ = stepToHexAlloc },
    .{ .name = "toLf", .fn_ = stepToLf },
    .{ .name = "fromPtr", .fn_ = stepFromPtrCopy },
    .{ .name = "eql", .fn_ = stepEql },
    .{ .name = "checkUid(NULL)", .fn_ = stepCheckUidNull },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("uid_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open uid_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig UID smoke test");
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
