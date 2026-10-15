// =============================================================================
//  test_abi.zig - Pure-logic unit tests for the LingoFuse Zig binding.
// -----------------------------------------------------------------------------
//  Why this file contains ONLY pure-logic tests
//  --------------------------------------------
//  The Zig test runner on Windows can hang when the native LingoFuse
//  library writes diagnostics to the console. A normal program
//  sidesteps this entirely; the test runner does not. The project
//  therefore uses two complementary mechanisms:
//
//      * `tests/test_abi.zig`          pure logic, no native calls.
//      * `examples/*_smoke.zig`        normal programs that touch the
//                                      native layer.
//
//  Everything in this file can run on any machine, with or without
//  the native runtime installed. Every test that would need the
//  native library has been moved to a smoke test:
//
//      DataHandle / AppHandle / framework tests
//          -> examples/abi_smoke.zig
//
//      Unified I/O tests
//          -> examples/io_smoke.zig
//
//      JSON engine tests
//          -> examples/json_smoke.zig
//
//      Network event tests
//          -> examples/network_events_smoke.zig
//
//      Status queue tests
//          -> examples/status_smoke.zig
//
//      UID value type tests
//          -> examples/uid_smoke.zig
//
//      P2P identity side-data tests
//          -> examples/identity_smoke.zig
//
//      Typed options tests
//          -> examples/options_smoke.zig
//
//      Async call family tests
//          -> examples/async_smoke.zig
//
//      Process-wide P2P registration tests
//          -> examples/p2p_smoke.zig
//
//      Three addressing schemes tests
//          -> examples/addressing_smoke.zig
//
//  Coverage
//  --------
//      * Uid value type: construction, hex parsing, ABI bridging,
//        comparison.
//      * AsyncResult tagged union shape.
//      * Top-level re-export surface, including every public symbol
//        added in v0.4 (Uid, options, p2p, async_call, and the new
//        framework functions).
//
//  Array-fill style
//  ----------------
//  This file uses no `**` operator anywhere. Fixed-size arrays are
//  initialised with `@splat` or explicit byte literals.
// =============================================================================
const std = @import("std");
const testing = std.testing;

const lf = @import("lingofuse");

// =============================================================================
// Uid value type
// =============================================================================

test "Uid: NULL is all zero" {
    const zeros: [32]u8 = @splat(0);
    try testing.expect(lf.Uid.NULL.isNull());
    try testing.expectEqual(zeros, lf.Uid.NULL.toBytes());
}

test "Uid: fromBytes / toBytes round-trip" {
    const source: [32]u8 = @splat(0x42);
    const uid = lf.Uid.fromBytes(source);
    try testing.expectEqual(source, uid.toBytes());
    try testing.expect(!uid.isNull());
}

test "Uid: fromSlice rejects wrong lengths" {
    const short: [31]u8 = @splat(0);
    const long: [33]u8 = @splat(0);
    try testing.expectError(lf.Error.InvalidArgument, lf.Uid.fromSlice(&short));
    try testing.expectError(lf.Error.InvalidArgument, lf.Uid.fromSlice(&long));
    try testing.expectError(lf.Error.InvalidArgument, lf.Uid.fromSlice(&[_]u8{}));
}

test "Uid: fromSlice accepts exact length" {
    const slice: [32]u8 = @splat(0xAB);
    const uid = try lf.Uid.fromSlice(&slice);
    try testing.expectEqual(slice, uid.toBytes());
}

test "Uid: fromHex / toHexBuf round-trip (lowercase)" {
    const hex = "0123456789abcdef0123456789abcdef" ++
        "0123456789abcdef0123456789abcdef";
    const uid = try lf.Uid.fromHex(hex);

    var buf: [64]u8 = undefined;
    uid.toHexBuf(&buf);
    try testing.expectEqualStrings(hex, &buf);
}

test "Uid: fromHex accepts mixed case and 0x / 0X prefixes" {
    const lower = try lf.Uid.fromHex(
        "0123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    );
    const upper = try lf.Uid.fromHex(
        "0123456789ABCDEF0123456789ABCDEF" ++
            "0123456789ABCDEF0123456789ABCDEF",
    );
    const with_0x = try lf.Uid.fromHex(
        "0x0123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    );
    const with_0X = try lf.Uid.fromHex(
        "0X0123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    );

    try testing.expect(lower.eql(upper));
    try testing.expect(lower.eql(with_0x));
    try testing.expect(lower.eql(with_0X));
}

test "Uid: fromHex rejects bad input" {
    try testing.expectError(lf.Error.InvalidArgument, lf.Uid.fromHex(""));
    try testing.expectError(lf.Error.InvalidArgument, lf.Uid.fromHex("abc"));

    const bad_hex: [64]u8 = @splat('z');
    try testing.expectError(lf.Error.InvalidArgument, lf.Uid.fromHex(&bad_hex));
}

test "Uid: toHexAlloc produces a NUL-terminated string" {
    const alloc = testing.allocator;

    const hex = "0123456789abcdef0123456789abcdef" ++
        "0123456789abcdef0123456789abcdef";
    const uid = try lf.Uid.fromHex(hex);
    const out = try uid.toHexAlloc(alloc);
    defer alloc.free(out);

    try testing.expectEqual(@as(usize, 64), out.len);
    try testing.expectEqual(@as(u8, 0), out[out.len]);
    try testing.expectEqualStrings(hex, out);
}

test "Uid: eql compares by content" {
    const a = try lf.Uid.fromHex(
        "0123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    );
    const b = try lf.Uid.fromHex(
        "0123456789abcdef0123456789abcdef" ++
            "0123456789abcdef0123456789abcdef",
    );
    const c = try lf.Uid.fromHex(
        "ffffffffffffffffffffffffffffffff" ++
            "ffffffffffffffffffffffffffffffff",
    );

    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(!a.eql(lf.Uid.NULL));
}

test "Uid: toLf preserves bytes" {
    const hex = "0123456789abcdef0123456789abcdef" ++
        "0123456789abcdef0123456789abcdef";
    const uid = try lf.Uid.fromHex(hex);
    const lf_struct = uid.toLf();
    try testing.expectEqual(uid.toBytes(), lf_struct.bytes);
}

test "Uid: fromPtr copies bytes immediately" {
    var backing: lf.sys.P2PUid = .{ .bytes = @splat(0x55) };
    const uid = lf.Uid.fromPtr(&backing);

    // Mutating the source after fromPtr must not affect the copy.
    backing.bytes[0] = 0x99;
    try testing.expectEqual(@as(u8, 0x55), uid.toBytes()[0]);
}

// =============================================================================
// AsyncResult tagged union
// =============================================================================

test "AsyncResult: .ok tag carries a DataHandle value" {
    // Construct a null borrowed handle; we only check the union shape.
    // `DataHandle.fromRaw` is a pure struct constructor and does NOT
    // touch the native library.
    const h = lf.DataHandle.fromRaw(null, false);
    const r: lf.async_call.AsyncResult = .{ .ok = h };

    const got = switch (r) {
        .ok => |x| x,
        .err => unreachable,
    };
    try testing.expect(!got.isValid());
}

test "AsyncResult: .err tag carries an Error value" {
    const r: lf.async_call.AsyncResult = .{ .err = lf.Error.CallFailed };

    const got = switch (r) {
        .ok => unreachable,
        .err => |x| x,
    };
    try testing.expectEqual(lf.Error.CallFailed, got);
}

// =============================================================================
// Top-level re-export surface
// =============================================================================
//
// `@hasDecl` is a comptime builtin; the checks below fold into
// constants at compile time and perform no runtime work. A missing
// declaration is a compilation error, not a runtime failure, so these
// tests fail fast if a public symbol is accidentally removed.

test "top-level re-exports exist" {
    try testing.expect(@hasDecl(lf, "sys"));
    try testing.expect(@hasDecl(lf, "Error"));
    try testing.expect(@hasDecl(lf, "Uid"));
    try testing.expect(@hasDecl(lf, "DataHandle"));
    try testing.expect(@hasDecl(lf, "AppHandle"));
    try testing.expect(@hasDecl(lf, "CallHandler"));
    try testing.expect(@hasDecl(lf, "NotifyHandler"));
    try testing.expect(@hasDecl(lf, "framework"));
    try testing.expect(@hasDecl(lf, "io"));
    try testing.expect(@hasDecl(lf, "json_c"));
    try testing.expect(@hasDecl(lf, "network_events"));
    try testing.expect(@hasDecl(lf, "status"));
    try testing.expect(@hasDecl(lf, "options"));
    try testing.expect(@hasDecl(lf, "p2p"));
    try testing.expect(@hasDecl(lf, "async_call"));
}

test "framework: public surface includes the v0.4 additions" {
    const f = lf.framework;
    try testing.expect(@hasDecl(f, "getOption"));
    try testing.expect(@hasDecl(f, "callByUid"));
    try testing.expect(@hasDecl(f, "callOptionalByUid"));
    try testing.expect(@hasDecl(f, "notifyByUid"));
    try testing.expect(@hasDecl(f, "sequencedNotifyByUid"));
    try testing.expect(@hasDecl(f, "callByP2PName"));
    try testing.expect(@hasDecl(f, "callOptionalByP2PName"));
    try testing.expect(@hasDecl(f, "notifyByP2PName"));
    try testing.expect(@hasDecl(f, "sequencedNotifyByP2PName"));
    try testing.expect(@hasDecl(f, "checkUid"));
    try testing.expect(@hasDecl(f, "checkUidApi"));
    try testing.expect(@hasDecl(f, "checkP2PName"));
    try testing.expect(@hasDecl(f, "checkP2PNameApi"));
}

test "options: public surface includes the typed pair set" {
    const o = lf.options;
    try testing.expect(@hasDecl(o, "setQuiet"));
    try testing.expect(@hasDecl(o, "getQuiet"));
    try testing.expect(@hasDecl(o, "setWaitConnectionTimeout"));
    try testing.expect(@hasDecl(o, "getWaitConnectionTimeout"));
    try testing.expect(@hasDecl(o, "setP2PName"));
    try testing.expect(@hasDecl(o, "getP2PName"));
    try testing.expect(@hasDecl(o, "setOverlapConnection"));
    try testing.expect(@hasDecl(o, "getOverlapConnection"));
    try testing.expect(@hasDecl(o, "setFixedSequencedTime"));
    try testing.expect(@hasDecl(o, "getFixedSequencedTime"));
    try testing.expect(@hasDecl(o, "setDataHandleIdleTimeout"));
    try testing.expect(@hasDecl(o, "getDataHandleIdleTimeout"));
}

test "p2p: public surface" {
    const p = lf.p2p;
    try testing.expect(@hasDecl(p, "registerP2PCall"));
    try testing.expect(@hasDecl(p, "registerP2PNotify"));
    try testing.expect(@hasDecl(p, "unregisterP2P"));
}

test "async_call: public surface" {
    const a = lf.async_call;
    try testing.expect(@hasDecl(a, "AsyncResult"));
    try testing.expect(@hasDecl(a, "AsyncResultHandler"));
    try testing.expect(@hasDecl(a, "callAsync"));
    try testing.expect(@hasDecl(a, "callAsyncSequenced"));
    try testing.expect(@hasDecl(a, "callAsyncByUid"));
    try testing.expect(@hasDecl(a, "callAsyncByP2PName"));
    try testing.expect(@hasDecl(a, "callAsyncWait"));
    try testing.expect(@hasDecl(a, "callAsyncWaitByUid"));
    try testing.expect(@hasDecl(a, "callAsyncWaitByP2PName"));
}

test "DataHandle: p2pUid / p2pName exist on the type" {
    try testing.expect(@hasDecl(lf.DataHandle, "p2pUid"));
    try testing.expect(@hasDecl(lf.DataHandle, "p2pName"));
}

test "Uid: public surface" {
    const u = lf.Uid;
    try testing.expect(@hasDecl(u, "NULL"));
    try testing.expect(@hasDecl(u, "fromBytes"));
    try testing.expect(@hasDecl(u, "fromSlice"));
    try testing.expect(@hasDecl(u, "fromHex"));
    try testing.expect(@hasDecl(u, "fromPtr"));
    try testing.expect(@hasDecl(u, "toBytes"));
    try testing.expect(@hasDecl(u, "asBytes"));
    try testing.expect(@hasDecl(u, "toLf"));
    try testing.expect(@hasDecl(u, "isNull"));
    try testing.expect(@hasDecl(u, "eql"));
    try testing.expect(@hasDecl(u, "toHexBuf"));
    try testing.expect(@hasDecl(u, "toHexAlloc"));
}

test "sys: v0.4 extern declarations exist" {
    const s = lf.sys;
    // P2P identity accessors
    try testing.expect(@hasDecl(s, "getP2PUid"));
    try testing.expect(@hasDecl(s, "getP2PName"));
    // Process-wide P2P registration
    try testing.expect(@hasDecl(s, "registerP2PCall"));
    try testing.expect(@hasDecl(s, "registerP2PNotify"));
    try testing.expect(@hasDecl(s, "unregisterP2P"));
    // App-name async
    try testing.expect(@hasDecl(s, "asyncCall"));
    try testing.expect(@hasDecl(s, "asyncSequencedCall"));
    // UID addressing
    try testing.expect(@hasDecl(s, "uidCall"));
    try testing.expect(@hasDecl(s, "uidAsyncCall"));
    try testing.expect(@hasDecl(s, "uidAsyncSequencedCall"));
    try testing.expect(@hasDecl(s, "uidNotify"));
    try testing.expect(@hasDecl(s, "uidSequencedNotify"));
    // P2PName addressing
    try testing.expect(@hasDecl(s, "p2pnameCall"));
    try testing.expect(@hasDecl(s, "p2pnameAsyncCall"));
    try testing.expect(@hasDecl(s, "p2pnameAsyncSequencedCall"));
    try testing.expect(@hasDecl(s, "p2pnameNotify"));
    try testing.expect(@hasDecl(s, "p2pnameSequencedNotify"));
    // Queries
    try testing.expect(@hasDecl(s, "checkUid"));
    try testing.expect(@hasDecl(s, "checkUidApi"));
    try testing.expect(@hasDecl(s, "checkP2PName"));
    try testing.expect(@hasDecl(s, "checkP2PNameApi"));
    // Options
    try testing.expect(@hasDecl(s, "getOption"));
    // ABI types
    try testing.expect(@hasDecl(s, "P2PUid"));
    try testing.expect(@hasDecl(s, "AsyncCallOnResult"));
}
