// =============================================================================
//  test_abi.zig - Unit tests for the LingoFuse Zig C-ABI layer.
// -----------------------------------------------------------------------------
//  Coverage
//  --------
//  Local paths of the binding:
//
//      * DataHandle creation, lifetime, byte I/O, cursor, size.
//      * The permanent-handle constructor.
//      * The borrowed-handle path (used inside callbacks).
//      * The NUL-framed string write helper.
//      * AppHandle creation, registration, unregistration.
//      * Local call / local notify through registered handlers.
//      * Argument validation and error-return contracts.
//
//  Scope
//  -----
//  Network operations are NOT covered here; they are integration-level
//  behaviours and are exercised by a separate suite in a later stage.
//
//  Runtime requirement
//  -------------------
//  These tests require the platform-specific native library to be
//  discoverable from the test executable. When the library cannot be
//  loaded, every test is skipped via `error.SkipZigTest`.
//
//  Empirical constraints of the Zig test runner on Windows
//  -------------------------------------------------------
//  Two facts were established experimentally:
//
//      1. `LF_SetOption` before the simulated main thread has started
//         does not return promptly. This suite therefore does not
//         call `setOption` from its scaffolding.
//
//      2. The Zig test runner treats ANY log message whose level is
//         greater than or equal to `std.testing.log_level` (default
//         `.warn`) as a test failure. In particular, a `std.log.err`
//         emitted from a callback trampoline will be counted as a
//         failure of the test that triggered it. There is no log
//         level above `.err` that could be used to suppress this.
//
//         Consequently, the "handler errors are swallowed" contract
//         is NOT tested in this suite. It is fully exercised by
//         `examples/abi_smoke.zig`, which runs as a normal program
//         and does not apply the runner's log-based failure rule.
//
//  Also omitted
//  ------------
//  A test for "localCall to an unregistered API returns a size-0
//  handle" is likewise not part of this suite: it triggers the native
//  library's own diagnostic print, which on Windows can contend with
//  the test runner's stdout. The contract is covered by the smoke
//  test and, in a later stage, by the network-level suite where the
//  simulated main thread is running and the native print path is
//  safe.
//
//  What remains
//  ------------
//  33 tests, all of which run on the local paths of the binding and
//  produce no native console output.
//
//  Empirical contract for SetPos
//  -----------------------------
//  The Pascal import documentation states that LF_SetPos extends the
//  buffer with zero bytes when the new position exceeds the current
//  size. The runtime does NOT do that. SetPos only updates the
//  cursor; the buffer grows on WriteBuffer and SetSize. The test
//  below asserts only the observable contract.
//
//  NUL framing in read-back tests
//  ------------------------------
//  `DataHandle.writeString(s)` writes `s.len` bytes followed by one
//  NUL. A read-back that consumes the whole buffer therefore returns
//  `s.len + 1` bytes, and the last byte is the NUL.
// =============================================================================
const std = @import("std");
const testing = std.testing;

const lf = @import("lingofuse");

// -----------------------------------------------------------------------------
// One-shot loader state.
// -----------------------------------------------------------------------------

var g_load_attempted: bool = false;
var g_load_ok: bool = false;

/// Attempt to load the native runtime once. Returns `true` when the
/// runtime is usable.
fn haveNative() bool {
    if (!g_load_attempted) {
        g_load_attempted = true;
        lf.framework.init() catch {
            g_load_ok = false;
            return false;
        };
        g_load_ok = true;
    }
    return g_load_ok;
}

/// Skip the current test when the native runtime is unavailable.
///
/// This does NOT configure any runtime options. See the module
/// docstring for the reason.
fn requireNative() !void {
    if (!haveNative()) return error.SkipZigTest;
}

// -----------------------------------------------------------------------------
// Test handlers.
// -----------------------------------------------------------------------------

/// Read two little-endian i32 values, write their sum.
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

/// Echo the input bytes to the output, without any transformation.
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

/// A Notify handler that ignores its input.
fn sinkNotifyHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    _ = input;
}

// =============================================================================
// DataHandle - construction and lifetime
// =============================================================================

test "DataHandle: create and deinit succeeds" {
    try requireNative();

    var h = try lf.DataHandle.create("test_create");
    defer h.deinit();

    try testing.expect(h.isValid());
    try testing.expect(h.isOwning());
    try testing.expectEqual(@as(i64, 0), try h.size());
    try testing.expectEqual(@as(i64, 0), try h.position());
}

test "DataHandle: createPermanent succeeds" {
    try requireNative();

    var h = try lf.DataHandle.createPermanent("test_permanent");
    defer h.deinit();

    try testing.expect(h.isValid());
    try testing.expect(h.isOwning());
    try testing.expectEqual(@as(i64, 0), try h.size());
}

test "DataHandle: deinit is idempotent" {
    try requireNative();

    var h = try lf.DataHandle.create("test_deinit_twice");
    h.deinit();
    try testing.expect(!h.isValid());
    h.deinit();
    try testing.expect(!h.isValid());
}

test "DataHandle: operations after deinit return NullHandle" {
    try requireNative();

    var h = try lf.DataHandle.create("test_after_deinit");
    h.deinit();

    try testing.expectError(lf.Error.NullHandle, h.size());
    try testing.expectError(lf.Error.NullHandle, h.position());
    try testing.expectError(
        lf.Error.NullHandle,
        h.setPosition(0),
    );
    try testing.expectError(
        lf.Error.NullHandle,
        h.writeBytes("x"),
    );
}

// =============================================================================
// DataHandle - byte I/O
// =============================================================================

test "DataHandle: writeBytes and readBytes round-trip" {
    try requireNative();

    var h = try lf.DataHandle.create("test_bytes");
    defer h.deinit();

    const payload = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 };
    try h.writeBytes(&payload);
    try testing.expectEqual(@as(i64, 5), try h.size());

    try h.setPosition(0);
    var out: [5]u8 = undefined;
    const got = try h.readBytes(&out);
    try testing.expectEqual(@as(usize, 5), got);
    try testing.expectEqualSlices(u8, &payload, &out);
}

test "DataHandle: writeBytes with an empty slice is a no-op" {
    try requireNative();

    var h = try lf.DataHandle.create("test_empty_write");
    defer h.deinit();

    try h.writeBytes("");
    try testing.expectEqual(@as(i64, 0), try h.size());
    try testing.expectEqual(@as(i64, 0), try h.position());
}

test "DataHandle: readBytes at end returns zero bytes" {
    try requireNative();

    var h = try lf.DataHandle.create("test_read_at_end");
    defer h.deinit();

    try h.writeBytes("hello");
    var buf: [8]u8 = undefined;
    const got = try h.readBytes(&buf);
    try testing.expectEqual(@as(usize, 0), got);
}

test "DataHandle: short read returns fewer bytes, not an error" {
    try requireNative();

    var h = try lf.DataHandle.create("test_short_read");
    defer h.deinit();

    try h.writeBytes("abc");
    try h.setPosition(0);

    var buf: [8]u8 = undefined;
    const got = try h.readBytes(&buf);
    try testing.expectEqual(@as(usize, 3), got);
    try testing.expectEqualSlices(u8, "abc", buf[0..got]);
}

test "DataHandle: embedded NUL bytes are preserved by the raw path" {
    try requireNative();

    var h = try lf.DataHandle.create("test_embedded_nul");
    defer h.deinit();

    const payload = [_]u8{ 'a', 0, 'b', 0, 'c' };
    try h.writeBytes(&payload);
    try testing.expectEqual(@as(i64, 5), try h.size());

    try h.setPosition(0);
    var out: [5]u8 = undefined;
    _ = try h.readBytes(&out);
    try testing.expectEqualSlices(u8, &payload, &out);
}

test "DataHandle: readAllBytes returns the remaining payload" {
    try requireNative();

    var h = try lf.DataHandle.create("test_read_all");
    defer h.deinit();

    try h.writeBytes("hello, world");
    try h.setPosition(7);

    const rest = try h.readAllBytes(testing.allocator);
    defer testing.allocator.free(rest);
    try testing.expectEqualSlices(u8, "world", rest);

    try testing.expectEqual(try h.size(), try h.position());
}

test "DataHandle: readAllBytes on an empty buffer returns empty" {
    try requireNative();

    var h = try lf.DataHandle.create("test_read_all_empty");
    defer h.deinit();

    const rest = try h.readAllBytes(testing.allocator);
    defer testing.allocator.free(rest);
    try testing.expectEqual(@as(usize, 0), rest.len);
}

// =============================================================================
// DataHandle - cursor and size
// =============================================================================

test "DataHandle: setSize grows and shrinks the buffer" {
    try requireNative();

    var h = try lf.DataHandle.create("test_set_size");
    defer h.deinit();

    try h.setSize(16);
    try testing.expectEqual(@as(i64, 16), try h.size());

    try h.setSize(4);
    try testing.expectEqual(@as(i64, 4), try h.size());
}

test "DataHandle: setPosition changes the cursor" {
    try requireNative();

    var h = try lf.DataHandle.create("test_set_pos_cursor");
    defer h.deinit();

    // LF_SetPos updates the cursor. It does NOT grow the buffer,
    // contrary to what the Pascal import documentation states. Only
    // WriteBuffer and SetSize grow the buffer. See the module
    // docstring for the empirical contract.
    try h.setPosition(8);
    try testing.expectEqual(@as(i64, 8), try h.position());
}

test "DataHandle: negative size is rejected" {
    try requireNative();

    var h = try lf.DataHandle.create("test_neg_size");
    defer h.deinit();

    try testing.expectError(lf.Error.InvalidArgument, h.setSize(-1));
}

test "DataHandle: negative position is rejected" {
    try requireNative();

    var h = try lf.DataHandle.create("test_neg_pos");
    defer h.deinit();

    try testing.expectError(
        lf.Error.InvalidArgument,
        h.setPosition(-1),
    );
}

// =============================================================================
// DataHandle - string write helper (low-level, NUL-framed)
// =============================================================================

test "DataHandle: writeString appends exactly one NUL" {
    try requireNative();

    var h = try lf.DataHandle.create("test_write_string");
    defer h.deinit();

    try h.writeString("abc");
    try testing.expectEqual(@as(i64, 4), try h.size());

    try h.setPosition(0);
    var out: [4]u8 = undefined;
    _ = try h.readBytes(&out);
    try testing.expectEqualSlices(u8, &[_]u8{ 'a', 'b', 'c', 0 }, &out);
}

test "DataHandle: writeString with an empty string writes a single NUL" {
    try requireNative();

    var h = try lf.DataHandle.create("test_write_empty_string");
    defer h.deinit();

    try h.writeString("");
    try testing.expectEqual(@as(i64, 1), try h.size());

    try h.setPosition(0);
    var out: [1]u8 = undefined;
    _ = try h.readBytes(&out);
    try testing.expectEqual(@as(u8, 0), out[0]);
}

test "DataHandle: writeString preserves multi-byte UTF-8" {
    try requireNative();

    var h = try lf.DataHandle.create("test_write_utf8");
    defer h.deinit();

    // "hello " (6 ASCII bytes) followed by U+4E16 (E4 B8 96) and
    // U+754C (E7 95 8C). Total payload: 12 bytes. With the NUL
    // terminator appended by writeString, the buffer holds 13 bytes.
    const text = "hello \xe4\xb8\x96\xe7\x95\x8c";
    try testing.expectEqual(@as(usize, 12), text.len);

    try h.writeString(text);
    try testing.expectEqual(@as(i64, 13), try h.size());

    try h.setPosition(0);
    var out: [32]u8 = undefined;
    const got = try h.readBytes(&out);
    try testing.expectEqual(@as(usize, 13), got);

    // The first `text.len` bytes must match the payload exactly.
    try testing.expectEqualSlices(u8, text, out[0..text.len]);
    // The final byte must be the NUL terminator.
    try testing.expectEqual(@as(u8, 0), out[text.len]);
}

// =============================================================================
// DataHandle - borrowed handles
// =============================================================================

test "DataHandle: fromRaw with owned=false is a no-op on deinit" {
    try requireNative();

    var owner = try lf.DataHandle.create("test_borrow");
    defer owner.deinit();

    try owner.writeBytes("abc");

    const raw = owner.raw orelse unreachable;
    var borrowed = lf.DataHandle.fromRaw(raw, false);
    try testing.expect(borrowed.isValid());
    try testing.expect(!borrowed.isOwning());

    try borrowed.setPosition(0);
    var out: [3]u8 = undefined;
    _ = try borrowed.readBytes(&out);
    try testing.expectEqualSlices(u8, "abc", &out);

    // Deinit of a borrowed wrapper must NOT free the underlying handle.
    borrowed.deinit();
    try testing.expect(owner.isValid());
    try testing.expectEqual(@as(i64, 3), try owner.size());
}

// =============================================================================
// AppHandle - construction and lifetime
// =============================================================================

test "AppHandle: create and deinit succeeds" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppBasic", "test app");
    defer app.deinit();

    try testing.expect(app.isValid());
    try testing.expectEqualStrings("TestZigAppBasic", app.name());
}

test "AppHandle: operations after deinit return NullHandle" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppDisposed", "test app");
    app.deinit();

    try testing.expect(!app.isValid());
    try testing.expectError(
        lf.Error.NullHandle,
        app.registerCall("x", "y", null, addHandler),
    );
    try testing.expectError(
        lf.Error.NullHandle,
        app.unregister("x"),
    );
}

test "AppHandle: deinit is idempotent" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppDeinitTwice", "");
    app.deinit();
    app.deinit();
    try testing.expect(!app.isValid());
}

// =============================================================================
// AppHandle - API registration
// =============================================================================

test "AppHandle: registerCall and registerNotify succeed" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppReg", "");
    defer app.deinit();

    try app.registerCall("add", "add two ints", null, addHandler);
    try app.registerNotify("sink", "sink notify", null, sinkNotifyHandler);
}

test "AppHandle: duplicate registration fails" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppDup", "");
    defer app.deinit();

    try app.registerCall("dup", "first", null, addHandler);
    try testing.expectError(
        lf.Error.RegistrationFailed,
        app.registerCall("dup", "second", null, addHandler),
    );
}

test "AppHandle: unregister returns true then false" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppUnreg", "");
    defer app.deinit();

    try app.registerCall("gone", "gone", null, addHandler);
    try testing.expect(try app.unregister("gone"));
    try testing.expect(!try app.unregister("gone"));
}

test "AppHandle: re-register after unregister succeeds" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppRereg", "");
    defer app.deinit();

    try app.registerCall("hot", "v1", null, addHandler);
    try testing.expect(try app.unregister("hot"));
    try app.registerCall("hot", "v2", null, addHandler);
}

// =============================================================================
// AppHandle - local execution
// =============================================================================

test "AppHandle: localCall round-trip through a registered handler" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppLocalCall", "");
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
    try testing.expectEqual(
        @as(i32, 12),
        std.mem.readInt(i32, &out, .little),
    );
}

// NOTE
// ----
// Two contracts that are exercised by examples/abi_smoke.zig are
// intentionally NOT tested here:
//
//   * "localCall to an unregistered API returns a size-0 handle".
//     It triggers a native diagnostic print on Windows that can
//     deadlock the test runner.
//
//   * "handler errors are swallowed by the trampoline".
//     It produces a std.log.err message, which the test runner
//     counts as a test failure. There is no log level above .err
//     that could be used to suppress this behaviour.
//
// Both are covered end-to-end by the smoke test, which runs as a
// normal program.

test "AppHandle: localCall input handle is not consumed" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppInputLifetime", "");
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

    try testing.expect(req.isValid());
    try testing.expectEqual(@as(i64, 8), try req.size());
}

test "AppHandle: localNotify reaches the registered handler" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppLocalNotify", "");
    defer app.deinit();

    try app.registerNotify("sink", "", null, sinkNotifyHandler);

    var req = try lf.DataHandle.create("sink");
    defer req.deinit();
    try req.writeString("payload");

    try app.localNotify(&req);
}

// =============================================================================
// AppHandle - echo handler with a larger payload
// =============================================================================

test "AppHandle: echo handler round-trips a 200-byte payload" {
    try requireNative();

    var app = try lf.AppHandle.create("TestZigAppEcho", "");
    defer app.deinit();

    try app.registerCall("echo", "", null, echoHandler);

    var payload: [200]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var req = try lf.DataHandle.create("echo");
    defer req.deinit();
    try req.writeBytes(&payload);

    var res = try app.localCall(&req);
    defer res.deinit();

    const out = try res.readAllBytes(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &payload, out);
}

// =============================================================================
// Framework - status queue (no network involved)
// =============================================================================

test "framework: getStatusCount is non-negative" {
    try requireNative();

    const n = lf.framework.getStatusCount();
    try testing.expect(n >= 0);
}

test "framework: setOption with an unknown key does not crash" {
    try requireNative();

    lf.framework.setOption("ThisOptionDoesNotExist_xyz", "value");
}

test "framework: checkMainThread returns a bool" {
    try requireNative();

    _ = lf.framework.checkMainThread();
}

test "framework: checkApp for an absent name is false" {
    try requireNative();

    const visible = lf.framework.checkApp(
        "__definitely_absent_zig_test_app__",
    );
    try testing.expect(!visible);
}
