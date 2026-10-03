// =============================================================================
//  abi_smoke.zig - ABI smoke test as a NORMAL program.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  The Zig test runner on Windows uses its own stdout transport, and
//  the native LingoFuse library writes diagnostics to the process
//  console. The two have been observed to contend, which makes the
//  test runner hang with no indication of where.
//
//  A normal executable sidesteps the transport entirely. Every step
//  of the smoke test is written to a log file (and mirrored to
//  stderr) BEFORE and AFTER each native call. If the program hangs,
//  the last line in the log file is the exact operation that blocked.
//
//  File I/O
//  --------
//  The log is written through C stdio (`fopen` / `fwrite` /
//  `fflush` / `fclose`), declared with `extern "c"` below. The Zig
//  `std.fs` file API has changed shape between releases; C stdio is
//  stable across every release and every supported platform.
//
//  Every write is followed by an `fflush`, so that a crash or a hang
//  leaves the log file in the state it was at the moment of the
//  failure.
//
//  Error assertions
//  ----------------
//  Zig represents a fallible call as an error union (`Error!T`). An
//  error-union value cannot be compared directly against an error-set
//  member; it must be destructured first. The `expectError` helper
//  below expresses "this call failed with exactly this error" in one
//  line, and works for `Error!void` and `Error!T` alike.
//
//  Empirical contract for SetPos
//  -----------------------------
//  The Pascal import documentation states that LF_SetPos extends the
//  buffer with zero bytes when the new position exceeds the current
//  size. The runtime does NOT do this. SetPos only updates the
//  cursor; the buffer grows on WriteBuffer and SetSize. The smoke
//  test asserts only the observable contract.
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
// C stdio, used instead of std.fs.
// -----------------------------------------------------------------------------

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fflush(stream: *anyopaque) c_int;
extern "c" fn fclose(stream: *anyopaque) c_int;
extern "c" fn exit(code: c_int) noreturn;

// -----------------------------------------------------------------------------
// Log helper.
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

    /// Write to both the log file and stderr. Never fails: a write
    /// error on either channel is swallowed so that the smoke test
    /// itself never dies because of logging.
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

// -----------------------------------------------------------------------------
// Assertion helpers.
// -----------------------------------------------------------------------------

fn check(log: *Log, cond: bool, what: []const u8) !void {
    if (!cond) {
        log.fmt("[FAIL] {s}", .{what});
        return error.AssertFailed;
    }
}

/// Return `true` when `result` is an error equal to `expected`.
///
/// `result` is the error-union value returned by a fallible call. In
/// Zig, an error-union value cannot be compared directly against an
/// error-set member; it must first be destructured. This helper
/// performs the destructuring and returns a plain boolean, so the
/// call site can stay on one line.
///
/// The `expected` parameter is `comptime` because the comparison is
/// against a fixed member of the `Error` set. The helper works for
/// both `Error!void` and `Error!T`.
fn expectError(result: anytype, comptime expected: lf.Error) bool {
    if (result) |_| {
        return false;
    } else |err| {
        return err == expected;
    }
}

// -----------------------------------------------------------------------------
// Global loader state.
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

fn echoHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    var buf: [256]u8 = undefined;
    const n = try input.readBytes(&buf);
    try output.writeBytes(buf[0..n]);
}

fn failingHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    _ = input;
    _ = output;
    return lf.Error.CallFailed;
}

fn sinkNotifyHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    _ = input;
}

// =============================================================================
// Steps - DataHandle construction and lifetime
// =============================================================================

fn stepDataHandleCreateAndDeinit(log: *Log) !void {
    log.line("[step] DataHandle: create and deinit");
    var h = try lf.DataHandle.create("smoke_create");
    defer h.deinit();

    try check(log, h.isValid(), "isValid");
    try check(log, h.isOwning(), "isOwning");
    try check(log, (try h.size()) == 0, "initial size == 0");
    try check(log, (try h.position()) == 0, "initial position == 0");
    log.line("[ok]   DataHandle: create and deinit");
}

fn stepDataHandleCreatePermanent(log: *Log) !void {
    log.line("[step] DataHandle: createPermanent");
    var h = try lf.DataHandle.createPermanent("smoke_permanent");
    defer h.deinit();

    try check(log, h.isValid(), "isValid");
    try check(log, h.isOwning(), "isOwning");
    try check(log, (try h.size()) == 0, "initial size == 0");
    log.line("[ok]   DataHandle: createPermanent");
}

fn stepDataHandleDeinitIdempotent(log: *Log) !void {
    log.line("[step] DataHandle: deinit is idempotent");
    var h = try lf.DataHandle.create("smoke_deinit_twice");
    h.deinit();
    try check(log, !h.isValid(), "invalid after first deinit");
    h.deinit();
    try check(log, !h.isValid(), "still invalid after second deinit");
    log.line("[ok]   DataHandle: deinit is idempotent");
}

fn stepDataHandleAfterDeinit(log: *Log) !void {
    log.line("[step] DataHandle: operations after deinit return NullHandle");
    var h = try lf.DataHandle.create("smoke_after_deinit");
    h.deinit();

    try check(log,
        expectError(h.size(), lf.Error.NullHandle),
        "size returns NullHandle");
    try check(log,
        expectError(h.position(), lf.Error.NullHandle),
        "position returns NullHandle");
    try check(log,
        expectError(h.setPosition(0), lf.Error.NullHandle),
        "setPosition returns NullHandle");
    try check(log,
        expectError(h.writeBytes("x"), lf.Error.NullHandle),
        "writeBytes returns NullHandle");
    log.line("[ok]   DataHandle: operations after deinit");
}

// =============================================================================
// Steps - DataHandle byte I/O
// =============================================================================

fn stepDataHandleByteRoundTrip(log: *Log) !void {
    log.line("[step] DataHandle: writeBytes / readBytes round-trip");
    var h = try lf.DataHandle.create("smoke_bytes");
    defer h.deinit();

    const payload = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    try h.writeBytes(&payload);
    try check(log, (try h.size()) == 5, "size after write");

    try h.setPosition(0);
    var out: [5]u8 = undefined;
    const got = try h.readBytes(&out);
    try check(log, got == 5, "bytes read");
    try check(log, std.mem.eql(u8, &payload, &out), "payload match");
    log.line("[ok]   DataHandle: byte round-trip");
}

fn stepDataHandleEmptyWrite(log: *Log) !void {
    log.line("[step] DataHandle: empty write is a no-op");
    var h = try lf.DataHandle.create("smoke_empty_write");
    defer h.deinit();

    try h.writeBytes("");
    try check(log, (try h.size()) == 0, "size stays 0");
    try check(log, (try h.position()) == 0, "position stays 0");
    log.line("[ok]   DataHandle: empty write");
}

fn stepDataHandleReadAtEnd(log: *Log) !void {
    log.line("[step] DataHandle: readBytes at end returns 0");
    var h = try lf.DataHandle.create("smoke_read_at_end");
    defer h.deinit();

    try h.writeBytes("hello");
    var buf: [8]u8 = undefined;
    const got = try h.readBytes(&buf);
    try check(log, got == 0, "zero bytes read");
    log.line("[ok]   DataHandle: read at end");
}

fn stepDataHandleShortRead(log: *Log) !void {
    log.line("[step] DataHandle: short read returns fewer bytes");
    var h = try lf.DataHandle.create("smoke_short_read");
    defer h.deinit();

    try h.writeBytes("abc");
    try h.setPosition(0);

    var buf: [8]u8 = undefined;
    const got = try h.readBytes(&buf);
    try check(log, got == 3, "three bytes read");
    try check(log, std.mem.eql(u8, "abc", buf[0..got]), "content match");
    log.line("[ok]   DataHandle: short read");
}

fn stepDataHandleEmbeddedNul(log: *Log) !void {
    log.line("[step] DataHandle: embedded NUL preserved");
    var h = try lf.DataHandle.create("smoke_embedded_nul");
    defer h.deinit();

    const payload = [_]u8{ 'a', 0, 'b', 0, 'c' };
    try h.writeBytes(&payload);
    try check(log, (try h.size()) == 5, "size 5");

    try h.setPosition(0);
    var out: [5]u8 = undefined;
    _ = try h.readBytes(&out);
    try check(log, std.mem.eql(u8, &payload, &out), "payload match");
    log.line("[ok]   DataHandle: embedded NUL");
}

fn stepDataHandleReadAll(log: *Log) !void {
    log.line("[step] DataHandle: readAllBytes from offset 7");
    var h = try lf.DataHandle.create("smoke_read_all");
    defer h.deinit();

    try h.writeBytes("hello, world");
    try h.setPosition(7);

    const rest = try h.readAllBytes(std.heap.page_allocator);
    defer std.heap.page_allocator.free(rest);
    try check(log, std.mem.eql(u8, "world", rest), "read 'world'");
    try check(log, (try h.size()) == (try h.position()), "cursor at end");
    log.line("[ok]   DataHandle: readAllBytes");
}

fn stepDataHandleReadAllEmpty(log: *Log) !void {
    log.line("[step] DataHandle: readAllBytes on empty");
    var h = try lf.DataHandle.create("smoke_read_all_empty");
    defer h.deinit();

    const rest = try h.readAllBytes(std.heap.page_allocator);
    defer std.heap.page_allocator.free(rest);
    try check(log, rest.len == 0, "empty slice");
    log.line("[ok]   DataHandle: readAllBytes on empty");
}

// =============================================================================
// Steps - DataHandle cursor and size
// =============================================================================

fn stepDataHandleSetSize(log: *Log) !void {
    log.line("[step] DataHandle: setSize grows and shrinks");
    var h = try lf.DataHandle.create("smoke_set_size");
    defer h.deinit();

    try h.setSize(16);
    try check(log, (try h.size()) == 16, "size 16");
    try h.setSize(4);
    try check(log, (try h.size()) == 4, "size 4");
    log.line("[ok]   DataHandle: setSize");
}

fn stepDataHandleSetPosGrow(log: *Log) !void {
    log.line("[step] DataHandle: setPosition changes the cursor");
    var h = try lf.DataHandle.create("smoke_set_pos_grow");
    defer h.deinit();

    // -------------------------------------------------------------------------
    // Empirical behaviour (verified on Windows 64-bit against the
    // current native build):
    //
    //     LF_SetPos(handle, 8) updates the cursor to 8 but does NOT
    //     grow the buffer. The buffer size remains 0 until a write
    //     or an explicit LF_SetSize is performed.
    //
    // The Pascal import documentation states that SetPos extends the
    // buffer with zero bytes when the position is beyond the current
    // size. The runtime does NOT do that. This binding therefore
    // relies only on the observable contract:
    //
    //     * SetPos updates the cursor.
    //     * WriteBuffer grows the buffer as needed.
    //     * SetSize grows or shrinks the buffer.
    //
    // The growth path is separately exercised by `setSize` (test 13)
    // and by `writeBytes` (test 5).
    // -------------------------------------------------------------------------
    try h.setPosition(8);
    try check(log, (try h.position()) == 8, "cursor == 8");

    log.line("[ok]   DataHandle: setPosition cursor");
}

fn stepDataHandleNegativeSize(log: *Log) !void {
    log.line("[step] DataHandle: negative size rejected");
    var h = try lf.DataHandle.create("smoke_neg_size");
    defer h.deinit();

    try check(log,
        expectError(h.setSize(-1), lf.Error.InvalidArgument),
        "InvalidArgument");
    log.line("[ok]   DataHandle: negative size");
}

fn stepDataHandleNegativePos(log: *Log) !void {
    log.line("[step] DataHandle: negative position rejected");
    var h = try lf.DataHandle.create("smoke_neg_pos");
    defer h.deinit();

    try check(log,
        expectError(h.setPosition(-1), lf.Error.InvalidArgument),
        "InvalidArgument");
    log.line("[ok]   DataHandle: negative position");
}

// =============================================================================
// Steps - DataHandle string write helper
// =============================================================================

fn stepDataHandleWriteStringNul(log: *Log) !void {
    log.line("[step] DataHandle: writeString appends one NUL");
    var h = try lf.DataHandle.create("smoke_write_string");
    defer h.deinit();

    try h.writeString("abc");
    try check(log, (try h.size()) == 4, "size 4 (3 + NUL)");

    try h.setPosition(0);
    var out: [4]u8 = undefined;
    _ = try h.readBytes(&out);
    try check(log, std.mem.eql(u8, &[_]u8{ 'a', 'b', 'c', 0 }, &out), "bytes");
    log.line("[ok]   DataHandle: writeString NUL");
}

fn stepDataHandleWriteStringEmpty(log: *Log) !void {
    log.line("[step] DataHandle: writeString empty writes one NUL");
    var h = try lf.DataHandle.create("smoke_write_string_empty");
    defer h.deinit();

    try h.writeString("");
    try check(log, (try h.size()) == 1, "size 1");

    try h.setPosition(0);
    var out: [1]u8 = undefined;
    _ = try h.readBytes(&out);
    try check(log, out[0] == 0, "byte is 0");
    log.line("[ok]   DataHandle: writeString empty");
}

fn stepDataHandleWriteStringUtf8(log: *Log) !void {
    log.line("[step] DataHandle: writeString multi-byte UTF-8");
    var h = try lf.DataHandle.create("smoke_write_utf8");
    defer h.deinit();

    const text = "hello \xe4\xb8\x96\xe7\x95\x8c";
    try check(log, text.len == 12, "text length 12");

    try h.writeString(text);
    try check(log, (try h.size()) == 13, "size 13");

    try h.setPosition(0);
    var out: [32]u8 = undefined;
    const got = try h.readBytes(&out);
    try check(log, got == 13, "read 13");
    try check(log, std.mem.eql(u8, text, out[0..text.len]), "payload");
    try check(log, out[text.len] == 0, "trailing NUL");
    log.line("[ok]   DataHandle: writeString UTF-8");
}

// =============================================================================
// Steps - DataHandle borrowed handle
// =============================================================================

fn stepDataHandleBorrow(log: *Log) !void {
    log.line("[step] DataHandle: borrowed handle deinit is no-op");
    var owner = try lf.DataHandle.create("smoke_borrow");
    defer owner.deinit();

    try owner.writeBytes("abc");

    const raw = owner.raw orelse return error.AssertFailed;
    var borrowed = lf.DataHandle.fromRaw(raw, false);
    try check(log, borrowed.isValid(), "borrowed valid");
    try check(log, !borrowed.isOwning(), "borrowed not owning");

    try borrowed.setPosition(0);
    var out: [3]u8 = undefined;
    _ = try borrowed.readBytes(&out);
    try check(log, std.mem.eql(u8, "abc", &out), "read content");

    borrowed.deinit();
    try check(log, owner.isValid(), "owner still valid");
    try check(log, (try owner.size()) == 3, "owner size 3");
    log.line("[ok]   DataHandle: borrowed handle");
}

// =============================================================================
// Steps - AppHandle construction and lifetime
// =============================================================================

fn stepAppHandleCreate(log: *Log) !void {
    log.line("[step] AppHandle: create and deinit");
    var app = try lf.AppHandle.create("SmokeAppBasic", "test app");
    defer app.deinit();

    try check(log, app.isValid(), "valid");
    try check(log, std.mem.eql(u8, "SmokeAppBasic", app.name()), "name");
    log.line("[ok]   AppHandle: create");
}

fn stepAppHandleAfterDeinit(log: *Log) !void {
    log.line("[step] AppHandle: operations after deinit");
    var app = try lf.AppHandle.create("SmokeAppDisposed", "");
    app.deinit();

    try check(log, !app.isValid(), "invalid");
    try check(log,
        expectError(app.registerCall("x", "y", null, addHandler),
            lf.Error.NullHandle),
        "registerCall returns NullHandle");
    try check(log,
        expectError(app.unregister("x"), lf.Error.NullHandle),
        "unregister returns NullHandle");
    log.line("[ok]   AppHandle: after deinit");
}

fn stepAppHandleDeinitTwice(log: *Log) !void {
    log.line("[step] AppHandle: deinit is idempotent");
    var app = try lf.AppHandle.create("SmokeAppDeinitTwice", "");
    app.deinit();
    app.deinit();
    try check(log, !app.isValid(), "invalid");
    log.line("[ok]   AppHandle: deinit idempotent");
}

// =============================================================================
// Steps - AppHandle registration
// =============================================================================

fn stepAppHandleRegister(log: *Log) !void {
    log.line("[step] AppHandle: registerCall and registerNotify succeed");
    var app = try lf.AppHandle.create("SmokeAppReg", "");
    defer app.deinit();

    try app.registerCall("add", "add two ints", null, addHandler);
    try app.registerNotify("sink", "sink notify", null, sinkNotifyHandler);
    log.line("[ok]   AppHandle: register");
}

fn stepAppHandleDuplicate(log: *Log) !void {
    log.line("[step] AppHandle: duplicate registration fails");
    var app = try lf.AppHandle.create("SmokeAppDup", "");
    defer app.deinit();

    try app.registerCall("dup", "first", null, addHandler);
    try check(log,
        expectError(app.registerCall("dup", "second", null, addHandler),
            lf.Error.RegistrationFailed),
        "second returns RegistrationFailed");
    log.line("[ok]   AppHandle: duplicate");
}

fn stepAppHandleUnregister(log: *Log) !void {
    log.line("[step] AppHandle: unregister returns true then false");
    var app = try lf.AppHandle.create("SmokeAppUnreg", "");
    defer app.deinit();

    try app.registerCall("gone", "gone", null, addHandler);
    try check(log, try app.unregister("gone"), "first unregister true");
    try check(log, !try app.unregister("gone"), "second unregister false");
    log.line("[ok]   AppHandle: unregister");
}

fn stepAppHandleReregister(log: *Log) !void {
    log.line("[step] AppHandle: re-register after unregister");
    var app = try lf.AppHandle.create("SmokeAppRereg", "");
    defer app.deinit();

    try app.registerCall("hot", "v1", null, addHandler);
    try check(log, try app.unregister("hot"), "unregister");
    try app.registerCall("hot", "v2", null, addHandler);
    log.line("[ok]   AppHandle: re-register");
}

// =============================================================================
// Steps - AppHandle local execution
// =============================================================================

fn stepAppHandleLocalCall(log: *Log) !void {
    log.line("[step] AppHandle: localCall round-trip");
    var app = try lf.AppHandle.create("SmokeAppLocalCall", "");
    defer app.deinit();

    try app.registerCall("add", "add two ints", null, addHandler);

    var req = try lf.DataHandle.create("add");
    defer req.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, 5, .little);
    try req.writeBytes(&buf);
    std.mem.writeInt(i32, &buf, 7, .little);
    try req.writeBytes(&buf);

    var res = try app.localCall(&req);
    defer res.deinit();

    try res.setPosition(0);
    var out: [4]u8 = undefined;
    _ = try res.readBytes(&out);
    const sum = std.mem.readInt(i32, &out, .little);
    try check(log, sum == 12, "sum == 12");
    log.line("[ok]   AppHandle: localCall");
}

fn stepAppHandleLocalCallInputLifetime(log: *Log) !void {
    log.line("[step] AppHandle: localCall input handle not consumed");
    var app = try lf.AppHandle.create("SmokeAppInputLifetime", "");
    defer app.deinit();

    try app.registerCall("add", "", null, addHandler);

    var req = try lf.DataHandle.create("add");
    defer req.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, 1, .little);
    try req.writeBytes(&buf);
    std.mem.writeInt(i32, &buf, 2, .little);
    try req.writeBytes(&buf);

    var res = try app.localCall(&req);
    defer res.deinit();

    try check(log, req.isValid(), "req still valid");
    try check(log, (try req.size()) == 8, "req size 8");
    log.line("[ok]   AppHandle: localCall input lifetime");
}

fn stepAppHandleLocalNotify(log: *Log) !void {
    log.line("[step] AppHandle: localNotify");
    var app = try lf.AppHandle.create("SmokeAppLocalNotify", "");
    defer app.deinit();

    try app.registerNotify("sink", "", null, sinkNotifyHandler);

    var req = try lf.DataHandle.create("sink");
    defer req.deinit();
    try req.writeString("payload");

    try app.localNotify(&req);
    log.line("[ok]   AppHandle: localNotify");
}

fn stepAppHandleHandlerErr(log: *Log) !void {
    log.line("[step] AppHandle: handler errors are swallowed");
    var app = try lf.AppHandle.create("SmokeAppHandlerErr", "");
    defer app.deinit();

    try app.registerCall("boom", "", null, failingHandler);

    var req = try lf.DataHandle.create("boom");
    defer req.deinit();

    var res = try app.localCall(&req);
    defer res.deinit();

    try check(log, (try res.size()) == 0, "empty output");
    log.line("[ok]   AppHandle: handler error swallowed");
}

fn stepAppHandleEcho200(log: *Log) !void {
    log.line("[step] AppHandle: echo 200-byte payload");
    var app = try lf.AppHandle.create("SmokeAppEcho", "");
    defer app.deinit();

    try app.registerCall("echo", "", null, echoHandler);

    var payload: [200]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var req = try lf.DataHandle.create("echo");
    defer req.deinit();
    try req.writeBytes(&payload);

    var res = try app.localCall(&req);
    defer res.deinit();

    const out = try res.readAllBytes(std.heap.page_allocator);
    defer std.heap.page_allocator.free(out);
    try check(log, std.mem.eql(u8, &payload, out), "payload match");
    log.line("[ok]   AppHandle: echo 200");
}

// =============================================================================
// Steps - Framework (no network)
// =============================================================================

fn stepFrameworkStatusCount(log: *Log) !void {
    log.line("[step] framework: getStatusCount >= 0");
    const n = lf.framework.getStatusCount();
    try check(log, n >= 0, "non-negative");
    log.line("[ok]   framework: getStatusCount");
}

fn stepFrameworkUnknownOption(log: *Log) !void {
    log.line("[step] framework: setOption with unknown key does not crash");
    lf.framework.setOption("ThisOptionDoesNotExist_xyz", "value");
    log.line("[ok]   framework: unknown option");
}

fn stepFrameworkCheckMainThread(log: *Log) !void {
    log.line("[step] framework: checkMainThread returns a bool");
    _ = lf.framework.checkMainThread();
    log.line("[ok]   framework: checkMainThread");
}

fn stepFrameworkCheckAppAbsent(log: *Log) !void {
    log.line("[step] framework: checkApp for an absent name is false");
    const visible = lf.framework.checkApp("__definitely_absent_zig_app__");
    try check(log, !visible, "not visible");
    log.line("[ok]   framework: checkApp absent");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "DataHandle: create and deinit", .fn_ = stepDataHandleCreateAndDeinit },
    .{ .name = "DataHandle: createPermanent", .fn_ = stepDataHandleCreatePermanent },
    .{ .name = "DataHandle: deinit idempotent", .fn_ = stepDataHandleDeinitIdempotent },
    .{ .name = "DataHandle: after deinit", .fn_ = stepDataHandleAfterDeinit },

    .{ .name = "DataHandle: byte round-trip", .fn_ = stepDataHandleByteRoundTrip },
    .{ .name = "DataHandle: empty write", .fn_ = stepDataHandleEmptyWrite },
    .{ .name = "DataHandle: read at end", .fn_ = stepDataHandleReadAtEnd },
    .{ .name = "DataHandle: short read", .fn_ = stepDataHandleShortRead },
    .{ .name = "DataHandle: embedded NUL", .fn_ = stepDataHandleEmbeddedNul },
    .{ .name = "DataHandle: readAllBytes", .fn_ = stepDataHandleReadAll },
    .{ .name = "DataHandle: readAllBytes empty", .fn_ = stepDataHandleReadAllEmpty },

    .{ .name = "DataHandle: setSize", .fn_ = stepDataHandleSetSize },
    .{ .name = "DataHandle: setPosition cursor", .fn_ = stepDataHandleSetPosGrow },
    .{ .name = "DataHandle: negative size", .fn_ = stepDataHandleNegativeSize },
    .{ .name = "DataHandle: negative position", .fn_ = stepDataHandleNegativePos },

    .{ .name = "DataHandle: writeString NUL", .fn_ = stepDataHandleWriteStringNul },
    .{ .name = "DataHandle: writeString empty", .fn_ = stepDataHandleWriteStringEmpty },
    .{ .name = "DataHandle: writeString UTF-8", .fn_ = stepDataHandleWriteStringUtf8 },

    .{ .name = "DataHandle: borrowed handle", .fn_ = stepDataHandleBorrow },

    .{ .name = "AppHandle: create", .fn_ = stepAppHandleCreate },
    .{ .name = "AppHandle: after deinit", .fn_ = stepAppHandleAfterDeinit },
    .{ .name = "AppHandle: deinit idempotent", .fn_ = stepAppHandleDeinitTwice },

    .{ .name = "AppHandle: register", .fn_ = stepAppHandleRegister },
    .{ .name = "AppHandle: duplicate", .fn_ = stepAppHandleDuplicate },
    .{ .name = "AppHandle: unregister", .fn_ = stepAppHandleUnregister },
    .{ .name = "AppHandle: re-register", .fn_ = stepAppHandleReregister },

    .{ .name = "AppHandle: localCall", .fn_ = stepAppHandleLocalCall },
    .{ .name = "AppHandle: localCall input lifetime", .fn_ = stepAppHandleLocalCallInputLifetime },
    .{ .name = "AppHandle: localNotify", .fn_ = stepAppHandleLocalNotify },
    .{ .name = "AppHandle: handler error", .fn_ = stepAppHandleHandlerErr },
    .{ .name = "AppHandle: echo 200", .fn_ = stepAppHandleEcho200 },

    .{ .name = "framework: getStatusCount", .fn_ = stepFrameworkStatusCount },
    .{ .name = "framework: unknown option", .fn_ = stepFrameworkUnknownOption },
    .{ .name = "framework: checkMainThread", .fn_ = stepFrameworkCheckMainThread },
    .{ .name = "framework: checkApp absent", .fn_ = stepFrameworkCheckAppAbsent },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("abi_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open abi_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig ABI smoke test");
    log.line("================================================================");

    // Loader. Every subsequent step depends on this.
    ensureLoaded(&log) catch |err| {
        log.fmt("[FATAL] framework.init failed: {}", .{err});
        exit(1);
    };

    // Run every step. A failure is logged and the run continues, so
    // that a single failure does not hide the state of the rest of
    // the suite.
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
    log.fmt("  Results: {d} passed, {d} failed, {d} total",
        .{ passed, failed, passed + failed });
    log.line("================================================================");

    if (failed != 0) exit(1);
}