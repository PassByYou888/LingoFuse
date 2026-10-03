// =============================================================================
//  json_smoke.zig - Complete API test for the lf_json C ABI library.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  Same reason as `abi_smoke.zig` and `io_smoke.zig`: the Zig test
//  runner on Windows can hang when the native LingoFuse library writes
//  diagnostics to the console. A normal executable sidesteps the
//  transport entirely, and every step is written to a log file before
//  and after each native call, so a hang leaves a usable trace.
//
//  Coverage
//  --------
//  Every public function of `c/lf_json.h` is exercised, including:
//
//    * Parsing and freeing
//    * Type query (all ten tags)
//    * Serialization (dump_size / dump_into) with every JSON type
//    * Value readers (bool / int64 / uint64 / double / string)
//    * Object access (size / key iteration / get)
//    * Array access (size / get)
//    * DOM construction (new_* / object_set / array_push)
//    * Streaming writer (all typed writers, raw, size, into)
//    * Byte-level wire format compatibility
//    * Error paths and NULL safety for every entry point
//
//  Exit codes
//  ----------
//      0  all steps passed
//      1  a step failed
//      2  the log file could not be created
// =============================================================================
const std = @import("std");
const lf = @import("lingofuse");

const jz = lf.json_c;

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
        var buf: [2048]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, format, args) catch {
            self.line("[log-fmt-error: buffer too small]");
            return;
        };
        self.write(s);
        self.write("\n");
    }
};

// -----------------------------------------------------------------------------
// Assertion helpers
// -----------------------------------------------------------------------------

fn check(log: *Log, cond: bool, what: []const u8) !void {
    if (!cond) {
        log.fmt("[FAIL] {s}", .{what});
        return error.AssertFailed;
    }
}

fn checkDump(
    log: *Log,
    hnd: jz.JsonHnd,
    expected: []const u8,
    what: []const u8,
) !void {
    if (hnd == null) {
        log.fmt("[FAIL] {s}: handle is null", .{what});
        return error.AssertFailed;
    }

    const n = jz.lf_json_dump_size(hnd);
    if (n < 0) {
        log.fmt("[FAIL] {s}: dump_size returned -1", .{what});
        return error.AssertFailed;
    }
    const expected_len: i64 = @intCast(expected.len);
    if (n != expected_len) {
        log.fmt("[FAIL] {s}: size {d}, expected {d}", .{ what, n, expected.len });
        return error.AssertFailed;
    }

    const buf = std.heap.page_allocator.alloc(u8, @intCast(n + 1)) catch
        return error.OutOfMemory;
    defer std.heap.page_allocator.free(buf);

    const got = jz.lf_json_dump_into(hnd, buf.ptr, @intCast(n + 1));
    if (got != n) {
        log.fmt("[FAIL] {s}: dump_into returned {d}, expected {d}", .{ what, got, n });
        return error.AssertFailed;
    }

    if (!std.mem.eql(u8, buf[0..@intCast(n)], expected)) {
        log.fmt("[FAIL] {s}: bytes differ", .{what});
        log.fmt("        got:      |{s}|", .{buf[0..@intCast(n)]});
        log.fmt("        expected: |{s}|", .{expected});
        return error.AssertFailed;
    }
}

fn checkWriter(
    log: *Log,
    w: jz.JsonWriter,
    expected: []const u8,
    what: []const u8,
) !void {
    if (w == null) {
        log.fmt("[FAIL] {s}: writer is null", .{what});
        return error.AssertFailed;
    }

    const n = jz.lf_json_writer_size(w);
    if (n < 0) {
        log.fmt("[FAIL] {s}: writer_size returned -1", .{what});
        return error.AssertFailed;
    }
    const expected_len: i64 = @intCast(expected.len);
    if (n != expected_len) {
        log.fmt("[FAIL] {s}: size {d}, expected {d}", .{ what, n, expected.len });
        return error.AssertFailed;
    }

    const buf = std.heap.page_allocator.alloc(u8, @intCast(n)) catch
        return error.OutOfMemory;
    defer std.heap.page_allocator.free(buf);

    const got = jz.lf_json_writer_into(w, buf.ptr, n);
    if (got != n) {
        log.fmt("[FAIL] {s}: writer_into returned {d}, expected {d}", .{ what, got, n });
        return error.AssertFailed;
    }

    if (!std.mem.eql(u8, buf, expected)) {
        log.fmt("[FAIL] {s}: bytes differ", .{what});
        log.fmt("        got:      |{s}|", .{buf});
        log.fmt("        expected: |{s}|", .{expected});
        return error.AssertFailed;
    }
}

fn parseSlice(s: []const u8) jz.JsonHnd {
    return jz.lf_json_parse(s.ptr, @intCast(s.len));
}

fn parseCStr(s: [*:0]const u8) jz.JsonHnd {
    return jz.lf_json_parse(s, -1);
}

// -----------------------------------------------------------------------------
// Shared UTF-8 literals
// -----------------------------------------------------------------------------

const UTF8_ZHANGSAN = "\xe5\xbc\xa0\xe4\xb8\x89";
const UTF8_EARTH = "\xf0\x9f\x8c\x8d";

// =============================================================================
// Section A - Parsing
// =============================================================================

fn stepA01_parseScalars(log: *Log) !void {
    log.line("[step] A01: parse null / bool / int / float");

    var h = parseCStr("null");
    try check(log, h != null, "parse null");
    try check(log, jz.lf_json_type(h) == jz.TAG_NULL, "type null");
    jz.lf_json_free(h);

    h = parseCStr("true");
    try check(log, h != null, "parse true");
    try check(log, jz.lf_json_type(h) == jz.TAG_BOOL, "type bool");
    jz.lf_json_free(h);

    h = parseCStr("false");
    try check(log, h != null, "parse false");
    try check(log, jz.lf_json_type(h) == jz.TAG_BOOL, "type bool");
    jz.lf_json_free(h);

    h = parseCStr("42");
    try check(log, h != null, "parse 42");
    try check(log, jz.lf_json_type(h) == jz.TAG_UINT or
        jz.lf_json_type(h) == jz.TAG_INT, "type number");
    jz.lf_json_free(h);

    h = parseCStr("-7");
    try check(log, h != null, "parse -7");
    try check(log, jz.lf_json_type(h) == jz.TAG_INT, "type int");
    jz.lf_json_free(h);

    h = parseCStr("3.14");
    try check(log, h != null, "parse 3.14");
    try check(log, jz.lf_json_type(h) == jz.TAG_FLOAT, "type float");
    jz.lf_json_free(h);

    log.line("[ok]   A01");
}

fn stepA02_parseString(log: *Log) !void {
    log.line("[step] A02: parse string (ascii / empty / UTF-8)");

    var h = parseCStr("\"hello\"");
    try check(log, h != null, "parse ascii string");
    try check(log, jz.lf_json_type(h) == jz.TAG_STRING, "type string");
    try check(log, jz.lf_json_string_size(h) == 5, "size 5");
    jz.lf_json_free(h);

    h = parseCStr("\"\"");
    try check(log, h != null, "parse empty string");
    try check(log, jz.lf_json_string_size(h) == 0, "size 0");
    jz.lf_json_free(h);

    h = parseCStr("\"hello, \xe4\xb8\x96\xe7\x95\x8c\"");
    try check(log, h != null, "parse utf8 string");
    try check(log, jz.lf_json_string_size(h) == 13, "size 13");
    jz.lf_json_free(h);

    log.line("[ok]   A02");
}

fn stepA03_parseEscapes(log: *Log) !void {
    log.line("[step] A03: parse string escapes (incl \\uXXXX and surrogate)");

    var h = parseCStr("\"\\u4e16\"");
    try check(log, h != null, "parse \\u4e16");
    try check(log, jz.lf_json_string_size(h) == 3, "3 bytes");
    jz.lf_json_free(h);

    h = parseCStr("\"\\ud83c\\udf0d\"");
    try check(log, h != null, "parse surrogate pair");
    try check(log, jz.lf_json_string_size(h) == 4, "4 bytes");
    jz.lf_json_free(h);

    h = parseCStr("\"a\\\\b\\\"c\"");
    try check(log, h != null, "parse backslash+quote");
    try check(log, jz.lf_json_string_size(h) == 5, "5 bytes");
    jz.lf_json_free(h);

    h = parseCStr("\"\\n\\t\\r\\b\\f\"");
    try check(log, h != null, "parse control escapes");
    try check(log, jz.lf_json_string_size(h) == 5, "5 control bytes");
    jz.lf_json_free(h);

    log.line("[ok]   A03");
}

fn stepA04_parseContainers(log: *Log) !void {
    log.line("[step] A04: parse array / object (empty and nested)");

    var h = parseCStr("[]");
    try check(log, h != null, "parse []");
    try check(log, jz.lf_json_type(h) == jz.TAG_ARRAY, "type array");
    try check(log, jz.lf_json_array_size(h) == 0, "empty array size 0");
    jz.lf_json_free(h);

    h = parseCStr("{}");
    try check(log, h != null, "parse {}");
    try check(log, jz.lf_json_type(h) == jz.TAG_OBJECT, "type object");
    try check(log, jz.lf_json_object_size(h) == 0, "empty object size 0");
    jz.lf_json_free(h);

    h = parseCStr("[1,2,[3,4]]");
    try check(log, h != null, "parse nested array");
    try check(log, jz.lf_json_array_size(h) == 3, "3 elements");
    jz.lf_json_free(h);

    h = parseCStr("{\"a\":1,\"b\":{\"c\":2}}");
    try check(log, h != null, "parse nested object");
    try check(log, jz.lf_json_object_size(h) == 2, "2 keys");
    jz.lf_json_free(h);

    log.line("[ok]   A04");
}

fn stepA05_parseErrors(log: *Log) !void {
    log.line("[step] A05: parse error paths");

    var h = jz.lf_json_parse(null, 5);
    try check(log, h == null, "null text -> null handle");

    const empty = "";
    h = jz.lf_json_parse(empty.ptr, 0);
    try check(log, h == null, "len 0 -> null handle");

    h = parseCStr("not json");
    try check(log, h == null, "invalid JSON -> null handle");

    const err = jz.lf_json_last_error();
    try check(log, err != null, "last_error non-null after failure");
    const err_slice = std.mem.span(err.?);
    try check(log, err_slice.len > 0, "last_error non-empty");

    h = parseCStr("{\"a\":1} trailing");
    try check(log, h == null, "trailing garbage rejected");

    h = parseCStr("1");
    try check(log, h != null, "valid parse");
    jz.lf_json_free(h);
    const err2 = jz.lf_json_last_error();
    try check(log, err2 != null, "last_error non-null");
    const err2_slice = std.mem.span(err2.?);
    try check(log, err2_slice.len == 0, "last_error cleared on success");

    log.line("[ok]   A05");
}

fn stepA06_parseWithExplicitLen(log: *Log) !void {
    log.line("[step] A06: parse with explicit length (len >= 0)");

    const text = "{\"a\":1}";
    const h = jz.lf_json_parse(text.ptr, 7);
    try check(log, h != null, "explicit len parse");
    try check(log, jz.lf_json_type(h) == jz.TAG_OBJECT, "type object");
    jz.lf_json_free(h);

    log.line("[ok]   A06");
}

fn stepA07_freeNullSafe(log: *Log) !void {
    log.line("[step] A07: lf_json_free(NULL) is a no-op");
    jz.lf_json_free(null);
    log.line("[ok]   A07");
}

// =============================================================================
// Section B - Type tags
// =============================================================================

fn stepB01_typeTags(log: *Log) !void {
    log.line("[step] B01: lf_json_type returns the correct tag");

    const cases = [_]struct { text: []const u8, tag: c_int }{
        .{ .text = "null", .tag = jz.TAG_NULL },
        .{ .text = "true", .tag = jz.TAG_BOOL },
        .{ .text = "-1", .tag = jz.TAG_INT },
        .{ .text = "3.5", .tag = jz.TAG_FLOAT },
        .{ .text = "\"x\"", .tag = jz.TAG_STRING },
        .{ .text = "[]", .tag = jz.TAG_ARRAY },
        .{ .text = "{}", .tag = jz.TAG_OBJECT },
    };

    for (cases) |c| {
        const h = parseSlice(c.text);
        try check(log, h != null, "parse for type test");
        defer jz.lf_json_free(h);
        const actual = jz.lf_json_type(h);
        if (actual != c.tag) {
            log.fmt("[FAIL] B01: type of '{s}' = {d}, expected {d}", .{ c.text, actual, c.tag });
            return error.AssertFailed;
        }
    }

    try check(log, jz.lf_json_type(null) == -1, "null handle -> -1");

    log.line("[ok]   B01");
}

// =============================================================================
// Section C - Serialization
// =============================================================================

fn stepC01_dumpScalars(log: *Log) !void {
    log.line("[step] C01: dump null / bool / int / float");

    var h = parseCStr("null");
    try checkDump(log, h, "null", "dump null");
    jz.lf_json_free(h);

    h = parseCStr("true");
    try checkDump(log, h, "true", "dump true");
    jz.lf_json_free(h);

    h = parseCStr("false");
    try checkDump(log, h, "false", "dump false");
    jz.lf_json_free(h);

    h = parseCStr("-42");
    try checkDump(log, h, "-42", "dump -42");
    jz.lf_json_free(h);

    h = parseCStr("1.5");
    try checkDump(log, h, "1.5", "dump 1.5");
    jz.lf_json_free(h);

    h = parseCStr("0");
    try checkDump(log, h, "0", "dump 0");
    jz.lf_json_free(h);

    log.line("[ok]   C01");
}

fn stepC02_dumpStrings(log: *Log) !void {
    log.line("[step] C02: dump strings (ascii / utf8 / escapes)");

    var h = parseCStr("\"hello\"");
    try checkDump(log, h, "\"hello\"", "dump ascii");
    jz.lf_json_free(h);

    h = parseCStr("\"\\u5f20\\u4e09\"");
    try checkDump(log, h, "\"" ++ UTF8_ZHANGSAN ++ "\"", "dump utf8 literal");
    jz.lf_json_free(h);

    h = parseCStr("\"\\ud83c\\udf0d\"");
    try checkDump(log, h, "\"" ++ UTF8_EARTH ++ "\"", "dump surrogate literal");
    jz.lf_json_free(h);

    h = parseCStr("\"a\\\\b\"");
    try checkDump(log, h, "\"a\\\\b\"", "dump escaped backslash");
    jz.lf_json_free(h);

    h = parseCStr("\"a\\\"b\"");
    try checkDump(log, h, "\"a\\\"b\"", "dump escaped quote");
    jz.lf_json_free(h);

    h = parseCStr("\"\\n\\t\\r\\b\\f\"");
    try checkDump(log, h, "\"\\n\\t\\r\\b\\f\"", "dump short escapes");
    jz.lf_json_free(h);

    log.line("[ok]   C02");
}

fn stepC03_dumpContainers(log: *Log) !void {
    log.line("[step] C03: dump array / object (compact, no whitespace)");

    var h = parseCStr("[]");
    try checkDump(log, h, "[]", "empty array");
    jz.lf_json_free(h);

    h = parseCStr("{}");
    try checkDump(log, h, "{}", "empty object");
    jz.lf_json_free(h);

    h = parseCStr("[1,2,3]");
    try checkDump(log, h, "[1,2,3]", "array of ints");
    jz.lf_json_free(h);

    h = parseCStr("{\"b\":2,\"a\":1,\"c\":3}");
    try checkDump(log, h, "{\"a\":1,\"b\":2,\"c\":3}", "keys sorted");
    jz.lf_json_free(h);

    h = parseCStr("{\"x\":[1,{\"y\":2}]}");
    try checkDump(log, h, "{\"x\":[1,{\"y\":2}]}", "nested");
    jz.lf_json_free(h);

    log.line("[ok]   C03");
}

fn stepC04_dumpEdge(log: *Log) !void {
    log.line("[step] C04: dump edge cases");

    try check(log, jz.lf_json_dump_size(null) == -1, "dump_size(NULL)");

    const h = parseCStr("42");

    try check(log, jz.lf_json_dump_into(h, null, 10) == -1, "dump_into(null)");

    var tiny: [2]u8 = undefined;
    try check(log, jz.lf_json_dump_into(h, &tiny, 2) == -1, "too-small buffer");

    try check(log, jz.lf_json_dump_into(h, &tiny, 0) == -1, "buf_size 0");

    var exact: [3]u8 = undefined;
    const got = jz.lf_json_dump_into(h, &exact, 3);
    try check(log, got == 2, "exact buffer");
    try check(log, exact[0] == '4' and exact[1] == '2' and exact[2] == 0, "exact buffer content");

    jz.lf_json_free(h);
    log.line("[ok]   C04");
}

// =============================================================================
// Section D - Value readers
// =============================================================================

fn stepD01_getBool(log: *Log) !void {
    log.line("[step] D01: lf_json_get_bool");

    var h = parseCStr("true");
    var out: c_int = 0;
    try check(log, jz.lf_json_get_bool(h, &out) == 1, "get true");
    try check(log, out == 1, "value true");
    jz.lf_json_free(h);

    h = parseCStr("false");
    try check(log, jz.lf_json_get_bool(h, &out) == 1, "get false");
    try check(log, out == 0, "value false");
    jz.lf_json_free(h);

    h = parseCStr("1");
    try check(log, jz.lf_json_get_bool(h, &out) == 0, "wrong type -> 0");
    jz.lf_json_free(h);

    h = parseCStr("true");
    try check(log, jz.lf_json_get_bool(h, null) == 0, "null out -> 0");
    jz.lf_json_free(h);

    try check(log, jz.lf_json_get_bool(null, &out) == 0, "null hnd -> 0");

    log.line("[ok]   D01");
}

fn stepD02_getInt64(log: *Log) !void {
    log.line("[step] D02: lf_json_get_int64");

    var h = parseCStr("-9223372036854775808");
    var out: i64 = 0;
    try check(log, jz.lf_json_get_int64(h, &out) == 1, "get i64 min");
    try check(log, out == std.math.minInt(i64), "i64 min value");
    jz.lf_json_free(h);

    h = parseCStr("9223372036854775807");
    try check(log, jz.lf_json_get_int64(h, &out) == 1, "get i64 max");
    try check(log, out == std.math.maxInt(i64), "i64 max value");
    jz.lf_json_free(h);

    h = parseCStr("1.5");
    try check(log, jz.lf_json_get_int64(h, &out) == 0, "float -> 0");
    jz.lf_json_free(h);

    log.line("[ok]   D02");
}

fn stepD03_getUint64(log: *Log) !void {
    log.line("[step] D03: lf_json_get_uint64");

    var h = parseCStr("18446744073709551615");
    var out: u64 = 0;
    try check(log, jz.lf_json_get_uint64(h, &out) == 1, "get u64 max");
    try check(log, out == std.math.maxInt(u64), "u64 max value");
    jz.lf_json_free(h);

    h = parseCStr("42");
    try check(log, jz.lf_json_get_uint64(h, &out) == 1, "get 42 unsigned");
    try check(log, out == 42, "value 42");
    jz.lf_json_free(h);

    h = parseCStr("-1");
    try check(log, jz.lf_json_get_uint64(h, &out) == 0, "-1 -> 0");
    jz.lf_json_free(h);

    log.line("[ok]   D03");
}

fn stepD04_getDouble(log: *Log) !void {
    log.line("[step] D04: lf_json_get_double");

    var h = parseCStr("3.5");
    var out: f64 = 0;
    try check(log, jz.lf_json_get_double(h, &out) == 1, "float -> f64");
    try check(log, out == 3.5, "3.5");
    jz.lf_json_free(h);

    h = parseCStr("7");
    try check(log, jz.lf_json_get_double(h, &out) == 1, "int -> f64");
    try check(log, out == 7.0, "7.0");
    jz.lf_json_free(h);

    h = parseCStr("\"3.5\"");
    try check(log, jz.lf_json_get_double(h, &out) == 0, "string -> 0");
    jz.lf_json_free(h);

    log.line("[ok]   D04");
}

fn stepD05_stringReaders(log: *Log) !void {
    log.line("[step] D05: lf_json_string_size / lf_json_string_into");

    var h = parseCStr("\"hello\"");
    try check(log, jz.lf_json_string_size(h) == 5, "size");

    var buf: [5]u8 = undefined;
    try check(log, jz.lf_json_string_into(h, &buf, 5) == 5, "into");
    try check(log, std.mem.eql(u8, &buf, "hello"), "content");

    var tiny: [2]u8 = undefined;
    try check(log, jz.lf_json_string_into(h, &tiny, 2) == -1, "too small");

    jz.lf_json_free(h);
    h = parseCStr("42");
    try check(log, jz.lf_json_string_size(h) == -1, "size on non-string");
    try check(log, jz.lf_json_string_into(h, &buf, 5) == -1, "into on non-string");
    jz.lf_json_free(h);

    try check(log, jz.lf_json_string_size(null) == -1, "size(null)");
    try check(log, jz.lf_json_string_into(null, &buf, 5) == -1, "into(null)");

    log.line("[ok]   D05");
}

// =============================================================================
// Section E - Object access
// =============================================================================

fn stepE01_objectSize(log: *Log) !void {
    log.line("[step] E01: lf_json_object_size");

    var h = parseCStr("{\"a\":1,\"b\":2,\"c\":3}");
    try check(log, jz.lf_json_object_size(h) == 3, "3 keys");
    jz.lf_json_free(h);

    h = parseCStr("{}");
    try check(log, jz.lf_json_object_size(h) == 0, "empty -> 0");
    jz.lf_json_free(h);

    h = parseCStr("[]");
    try check(log, jz.lf_json_object_size(h) == -1, "array -> -1");
    jz.lf_json_free(h);

    try check(log, jz.lf_json_object_size(null) == -1, "null -> -1");

    log.line("[ok]   E01");
}

fn stepE02_objectKeyIteration(log: *Log) !void {
    log.line("[step] E02: lf_json_object_key_into order and bounds");

    var h = parseCStr("{\"banana\":1,\"apple\":2,\"cherry\":3}");

    var key_buf: [64]u8 = undefined;
    const expected = [_][]const u8{ "apple", "banana", "cherry" };
    for (expected, 0..) |want, i| {
        const n = jz.lf_json_object_key_into(h, @intCast(i), &key_buf, key_buf.len);
        if (n < 0) {
            log.fmt("[FAIL] E02: key {d} returned -1", .{i});
            jz.lf_json_free(h);
            return error.AssertFailed;
        }
        if (!std.mem.eql(u8, key_buf[0..@intCast(n)], want)) {
            log.fmt("[FAIL] E02: key {d} = |{s}|, expected |{s}|", .{ i, key_buf[0..@intCast(n)], want });
            jz.lf_json_free(h);
            return error.AssertFailed;
        }
    }

    try check(log, jz.lf_json_object_key_into(h, 3, &key_buf, key_buf.len) == -1, "oob");
    try check(log, jz.lf_json_object_key_into(h, -1, &key_buf, key_buf.len) == -1, "negative");
    try check(log, jz.lf_json_object_key_into(h, 0, &key_buf, 2) == -1, "small buf");

    jz.lf_json_free(h);
    h = parseCStr("[]");
    try check(log, jz.lf_json_object_key_into(h, 0, &key_buf, key_buf.len) == -1, "on array");
    jz.lf_json_free(h);

    log.line("[ok]   E02");
}

fn stepE03_objectGet(log: *Log) !void {
    log.line("[step] E03: lf_json_object_get");

    const h = parseCStr("{\"a\":1,\"b\":\"two\",\"c\":[3]}");

    var child = jz.lf_json_object_get(h, "a", 1);
    try check(log, child != null, "get a");
    try checkDump(log, child, "1", "child a dump");
    jz.lf_json_free(child);

    child = jz.lf_json_object_get(h, "b", 1);
    try check(log, child != null, "get b");
    try checkDump(log, child, "\"two\"", "child b dump");
    jz.lf_json_free(child);

    child = jz.lf_json_object_get(h, "c", 1);
    try check(log, child != null, "get c");
    try checkDump(log, child, "[3]", "child c dump");
    jz.lf_json_free(child);

    child = jz.lf_json_object_get(h, "z", 1);
    try check(log, child == null, "missing key -> null");

    child = jz.lf_json_object_get(null, "a", 1);
    try check(log, child == null, "null hnd -> null");

    jz.lf_json_free(h);

    const parent = parseCStr("{\"x\":{\"y\":1}}");
    const sub = jz.lf_json_object_get(parent, "x", 1);
    try check(log, sub != null, "get sub");

    try checkDump(log, parent, "{\"x\":{\"y\":1}}", "parent unchanged");

    jz.lf_json_free(sub);
    jz.lf_json_free(parent);

    log.line("[ok]   E03");
}

// =============================================================================
// Section F - Array access
// =============================================================================

fn stepF01_arraySize(log: *Log) !void {
    log.line("[step] F01: lf_json_array_size");

    var h = parseCStr("[1,2,3]");
    try check(log, jz.lf_json_array_size(h) == 3, "3 elements");
    jz.lf_json_free(h);

    h = parseCStr("[]");
    try check(log, jz.lf_json_array_size(h) == 0, "empty -> 0");
    jz.lf_json_free(h);

    h = parseCStr("{}");
    try check(log, jz.lf_json_array_size(h) == -1, "object -> -1");
    jz.lf_json_free(h);

    try check(log, jz.lf_json_array_size(null) == -1, "null -> -1");

    log.line("[ok]   F01");
}

fn stepF02_arrayGet(log: *Log) !void {
    log.line("[step] F02: lf_json_array_get");

    const h = parseCStr("[\"one\",\"two\",[3]]");

    var child = jz.lf_json_array_get(h, 0);
    try check(log, child != null, "get 0");
    try checkDump(log, child, "\"one\"", "elem 0");
    jz.lf_json_free(child);

    child = jz.lf_json_array_get(h, 1);
    try check(log, child != null, "get 1");
    try checkDump(log, child, "\"two\"", "elem 1");
    jz.lf_json_free(child);

    child = jz.lf_json_array_get(h, 2);
    try check(log, child != null, "get 2");
    try checkDump(log, child, "[3]", "elem 2");
    jz.lf_json_free(child);

    child = jz.lf_json_array_get(h, 3);
    try check(log, child == null, "oob -> null");

    child = jz.lf_json_array_get(h, -1);
    try check(log, child == null, "negative -> null");

    child = jz.lf_json_array_get(null, 0);
    try check(log, child == null, "null hnd -> null");

    jz.lf_json_free(h);
    log.line("[ok]   F02");
}

// =============================================================================
// Section G - DOM builder
// =============================================================================

fn stepG01_newScalars(log: *Log) !void {
    log.line("[step] G01: new_null / bool / int64 / uint64 / double");

    var h = jz.lf_json_new_null();
    try check(log, h != null, "new null");
    try checkDump(log, h, "null", "dump null");
    jz.lf_json_free(h);

    h = jz.lf_json_new_bool(1);
    try checkDump(log, h, "true", "dump true");
    jz.lf_json_free(h);

    h = jz.lf_json_new_bool(0);
    try checkDump(log, h, "false", "dump false");
    jz.lf_json_free(h);

    h = jz.lf_json_new_int64(-42);
    try checkDump(log, h, "-42", "dump -42");
    jz.lf_json_free(h);

    h = jz.lf_json_new_uint64(42);
    try checkDump(log, h, "42", "dump 42u");
    jz.lf_json_free(h);

    h = jz.lf_json_new_double(3.5);
    try checkDump(log, h, "3.5", "dump 3.5");
    jz.lf_json_free(h);

    log.line("[ok]   G01");
}

fn stepG02_newString(log: *Log) !void {
    log.line("[step] G02: new_string (empty / ascii / utf8)");

    var h = jz.lf_json_new_string("", 0);
    try check(log, h != null, "new empty string");
    try checkDump(log, h, "\"\"", "dump empty");
    jz.lf_json_free(h);

    h = jz.lf_json_new_string("hello", 5);
    try checkDump(log, h, "\"hello\"", "dump ascii");
    jz.lf_json_free(h);

    h = jz.lf_json_new_string(UTF8_ZHANGSAN.ptr, UTF8_ZHANGSAN.len);
    try check(log, h != null, "new utf8 string");
    try checkDump(log, h, "\"" ++ UTF8_ZHANGSAN ++ "\"", "dump utf8");
    jz.lf_json_free(h);

    log.line("[ok]   G02");
}

fn stepG03_domArray(log: *Log) !void {
    log.line("[step] G03: new_array + array_push");

    const arr = jz.lf_json_new_array();
    try check(log, arr != null, "new array");

    const v1 = jz.lf_json_new_int64(1);
    const v2 = jz.lf_json_new_int64(2);
    const v3 = jz.lf_json_new_string("three", 5);

    try check(log, jz.lf_json_array_push(arr, v1) == 1, "push 1");
    try check(log, jz.lf_json_array_push(arr, v2) == 1, "push 2");
    try check(log, jz.lf_json_array_push(arr, v3) == 1, "push 3");

    try checkDump(log, arr, "[1,2,\"three\"]", "dump array");

    jz.lf_json_free(v1);
    jz.lf_json_free(v2);
    jz.lf_json_free(v3);
    jz.lf_json_free(arr);

    const obj = jz.lf_json_new_object();
    const v = jz.lf_json_new_int64(1);
    try check(log, jz.lf_json_array_push(obj, v) == 0, "push on object -> 0");
    try check(log, jz.lf_json_array_push(null, v) == 0, "push on null -> 0");
    jz.lf_json_free(v);
    jz.lf_json_free(obj);

    log.line("[ok]   G03");
}

fn stepG04_domObject(log: *Log) !void {
    log.line("[step] G04: new_object + object_set");

    const obj = jz.lf_json_new_object();
    try check(log, obj != null, "new object");

    const v1 = jz.lf_json_new_int64(1);
    const v2 = jz.lf_json_new_string("two", 3);

    try check(log, jz.lf_json_object_set(obj, "a", 1, v1) == 1, "set a");
    try check(log, jz.lf_json_object_set(obj, "b", 1, v2) == 1, "set b");

    try checkDump(log, obj, "{\"a\":1,\"b\":\"two\"}", "dump object");

    const v3 = jz.lf_json_new_int64(99);
    try check(log, jz.lf_json_object_set(obj, "a", 1, v3) == 1, "replace a");
    try checkDump(log, obj, "{\"a\":99,\"b\":\"two\"}", "dump replaced");

    const arr = jz.lf_json_new_array();
    try check(log, jz.lf_json_object_set(arr, "x", 1, v1) == 0, "set on array -> 0");
    try check(log, jz.lf_json_object_set(null, "x", 1, v1) == 0, "set on null -> 0");
    try check(log, jz.lf_json_object_set(obj, "x", 1, null) == 0, "null child -> 0");

    jz.lf_json_free(v1);
    jz.lf_json_free(v2);
    jz.lf_json_free(v3);
    jz.lf_json_free(arr);
    jz.lf_json_free(obj);

    log.line("[ok]   G04");
}

fn stepG05_domNested(log: *Log) !void {
    log.line("[step] G05: nested DOM (object containing array containing object)");

    const root = jz.lf_json_new_object();
    const arr = jz.lf_json_new_array();

    const e1 = jz.lf_json_new_object();
    const v1 = jz.lf_json_new_int64(1);
    _ = jz.lf_json_object_set(e1, "v", 1, v1);

    const e2 = jz.lf_json_new_object();
    const v2 = jz.lf_json_new_int64(2);
    _ = jz.lf_json_object_set(e2, "v", 1, v2);

    _ = jz.lf_json_array_push(arr, e1);
    _ = jz.lf_json_array_push(arr, e2);
    _ = jz.lf_json_object_set(root, "list", 4, arr);

    try checkDump(log, root, "{\"list\":[{\"v\":1},{\"v\":2}]}", "nested dump");

    jz.lf_json_free(v1);
    jz.lf_json_free(v2);
    jz.lf_json_free(e1);
    jz.lf_json_free(e2);
    jz.lf_json_free(arr);
    jz.lf_json_free(root);

    log.line("[ok]   G05");
}

fn stepG06_domEqualsParse(log: *Log) !void {
    log.line("[step] G06: DOM-built equals parse-built (byte-for-byte)");

    const obj = jz.lf_json_new_object();
    const v1 = jz.lf_json_new_int64(1);
    const v2 = jz.lf_json_new_string("two", 3);
    _ = jz.lf_json_object_set(obj, "a", 1, v1);
    _ = jz.lf_json_object_set(obj, "b", 1, v2);

    const parsed = parseCStr("{\"a\":1,\"b\":\"two\"}");

    const n1 = jz.lf_json_dump_size(obj);
    const n2 = jz.lf_json_dump_size(parsed);
    try check(log, n1 == n2, "same dump size");

    const b1 = std.heap.page_allocator.alloc(u8, @intCast(n1 + 1)) catch
        return error.OutOfMemory;
    defer std.heap.page_allocator.free(b1);
    const b2 = std.heap.page_allocator.alloc(u8, @intCast(n2 + 1)) catch
        return error.OutOfMemory;
    defer std.heap.page_allocator.free(b2);

    _ = jz.lf_json_dump_into(obj, b1.ptr, @intCast(n1 + 1));
    _ = jz.lf_json_dump_into(parsed, b2.ptr, @intCast(n2 + 1));

    try check(log, std.mem.eql(u8, b1[0..@intCast(n1)], b2[0..@intCast(n2)]), "byte-for-byte equal");

    jz.lf_json_free(v1);
    jz.lf_json_free(v2);
    jz.lf_json_free(obj);
    jz.lf_json_free(parsed);

    log.line("[ok]   G06");
}

// =============================================================================
// Section H - Streaming writer
// =============================================================================

fn stepH01_writerScalars(log: *Log) !void {
    log.line("[step] H01: writer typed scalars");

    var w = jz.lf_json_writer_new();
    try check(log, w != null, "writer_new");
    jz.lf_json_writer_int64(w, -42);
    try checkWriter(log, w, "-42", "int64");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_uint64(w, 42);
    try checkWriter(log, w, "42", "uint64");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_double(w, 3.5);
    try checkWriter(log, w, "3.5", "double");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_bool(w, 1);
    try checkWriter(log, w, "true", "bool true");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_bool(w, 0);
    try checkWriter(log, w, "false", "bool false");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_null(w);
    try checkWriter(log, w, "null", "null");
    jz.lf_json_writer_free(w);

    log.line("[ok]   H01");
}

fn stepH02_writerStrings(log: *Log) !void {
    log.line("[step] H02: writer_string (ascii / utf8 / escapes)");

    var w = jz.lf_json_writer_new();
    jz.lf_json_writer_string(w, "hello", 5);
    try checkWriter(log, w, "\"hello\"", "ascii");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_string(w, "", 0);
    try checkWriter(log, w, "\"\"", "empty");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_string(w, UTF8_ZHANGSAN.ptr, UTF8_ZHANGSAN.len);
    try checkWriter(log, w, "\"" ++ UTF8_ZHANGSAN ++ "\"", "utf8 literal");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_string(w, "a\\b", 3);
    try checkWriter(log, w, "\"a\\\\b\"", "backslash");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_string(w, "a\"b", 3);
    try checkWriter(log, w, "\"a\\\"b\"", "quote");
    jz.lf_json_writer_free(w);

    w = jz.lf_json_writer_new();
    jz.lf_json_writer_string(w, "\n\t\r", 3);
    try checkWriter(log, w, "\"\\n\\t\\r\"", "controls");
    jz.lf_json_writer_free(w);

    log.line("[ok]   H02");
}

fn stepH03_writerRaw(log: *Log) !void {
    log.line("[step] H03: writer_raw builds composite JSON");

    const w = jz.lf_json_writer_new();
    try check(log, w != null, "new");

    jz.lf_json_writer_raw(w, "{", 1);
    jz.lf_json_writer_string(w, "a", 1);
    jz.lf_json_writer_raw(w, ":", 1);
    jz.lf_json_writer_int64(w, 1);
    jz.lf_json_writer_raw(w, ",", 1);
    jz.lf_json_writer_string(w, "b", 1);
    jz.lf_json_writer_raw(w, ":[", 2);
    jz.lf_json_writer_int64(w, 2);
    jz.lf_json_writer_raw(w, ",", 1);
    jz.lf_json_writer_int64(w, 3);
    jz.lf_json_writer_raw(w, "]}", 2);

    try checkWriter(log, w, "{\"a\":1,\"b\":[2,3]}", "composite");
    jz.lf_json_writer_free(w);

    log.line("[ok]   H03");
}

fn stepH04_writerEdge(log: *Log) !void {
    log.line("[step] H04: writer edge cases");

    try check(log, jz.lf_json_writer_size(null) == -1, "size(null)");
    try check(log, jz.lf_json_writer_into(null, null, 0) == -1, "into(null)");

    const w = jz.lf_json_writer_new();
    jz.lf_json_writer_int64(w, 42);

    var tiny: [1]u8 = undefined;
    try check(log, jz.lf_json_writer_into(w, &tiny, 1) == -1, "too small");

    try check(log, jz.lf_json_writer_into(w, null, 10) == -1, "null buf");

    var exact: [2]u8 = undefined;
    const got = jz.lf_json_writer_into(w, &exact, 2);
    try check(log, got == 2, "exact buf");
    try check(log, exact[0] == '4' and exact[1] == '2', "exact content");

    jz.lf_json_writer_free(w);
    jz.lf_json_writer_free(null);

    log.line("[ok]   H04");
}

fn stepH05_writerNoTrailingNul(log: *Log) !void {
    log.line("[step] H05: writer output has no trailing NUL");

    const w = jz.lf_json_writer_new();
    jz.lf_json_writer_int64(w, 42);

    try check(log, jz.lf_json_writer_size(w) == 2, "size 2");

    var buf: [2]u8 = undefined;
    try check(log, jz.lf_json_writer_into(w, &buf, 2) == 2, "2-byte buf");

    jz.lf_json_writer_free(w);
    log.line("[ok]   H05");
}

// =============================================================================
// Section I - Wire format compat
// =============================================================================

fn stepI01_canonicalBytes(log: *Log) !void {
    log.line("[step] I01: canonical {\"a\":1} byte sequence");

    const h = parseCStr("{\"a\":1}");
    const n = jz.lf_json_dump_size(h);
    try check(log, n == 7, "size 7");

    var buf: [8]u8 = undefined;
    _ = jz.lf_json_dump_into(h, &buf, 8);

    const expected = [_]u8{ '{', '"', 'a', '"', ':', '1', '}', 0 };
    try check(log, std.mem.eql(u8, &buf, &expected), "byte sequence");

    jz.lf_json_free(h);
    log.line("[ok]   I01");
}

fn stepI02_utf8Literal(log: *Log) !void {
    log.line("[step] I02: UTF-8 emitted literally, no \\uXXXX");

    const h = jz.lf_json_new_string("你好 🌍", "你好 🌍".len);
    const n = jz.lf_json_dump_size(h);
    const buf = std.heap.page_allocator.alloc(u8, @intCast(n + 1)) catch
        return error.OutOfMemory;
    defer std.heap.page_allocator.free(buf);
    _ = jz.lf_json_dump_into(h, buf.ptr, @intCast(n + 1));

    const out = buf[0..@intCast(n)];
    try check(log, std.mem.indexOf(u8, out, "\\u") == null, "no \\uXXXX");
    try check(log, std.mem.indexOf(u8, out, "你") != null, "literal 你");
    try check(log, std.mem.indexOf(u8, out, "🌍") != null, "literal emoji");

    jz.lf_json_free(h);
    log.line("[ok]   I02");
}

fn stepI03_controlEscapes(log: *Log) !void {
    log.line("[step] I03: control chars use short escapes when possible");

    const bytes = [_]u8{ 0x08, 0x0C, 0x01, 0x1F };
    const h = jz.lf_json_new_string(&bytes, 4);

    try checkDump(log, h, "\"\\b\\f\\u0001\\u001f\"", "control escapes");

    jz.lf_json_free(h);
    log.line("[ok]   I03");
}

fn stepI04_floatFormatting(log: *Log) !void {
    log.line("[step] I04: float formatting is round-trip safe");

    var h = jz.lf_json_new_double(1.5);
    try checkDump(log, h, "1.5", "1.5");
    jz.lf_json_free(h);

    h = jz.lf_json_new_double(0.0);
    try checkDump(log, h, "0.0", "0.0");
    jz.lf_json_free(h);

    h = jz.lf_json_new_double(std.math.nan(f64));
    try checkDump(log, h, "null", "NaN -> null");
    jz.lf_json_free(h);

    h = jz.lf_json_new_double(std.math.inf(f64));
    try checkDump(log, h, "null", "Inf -> null");
    jz.lf_json_free(h);

    log.line("[ok]   I04");
}

fn stepI05_deepCopyEquals(log: *Log) !void {
    log.line("[step] I05: object_get returns a deep copy");

    const root = parseCStr("{\"a\":{\"b\":[1,2,3]}}");

    const a = jz.lf_json_object_get(root, "a", 1);
    try check(log, a != null, "get a");

    const n = jz.lf_json_dump_size(a);
    const buf = std.heap.page_allocator.alloc(u8, @intCast(n + 1)) catch
        return error.OutOfMemory;
    defer std.heap.page_allocator.free(buf);
    _ = jz.lf_json_dump_into(a, buf.ptr, @intCast(n + 1));

    try check(log, std.mem.eql(u8, buf[0..@intCast(n)], "{\"b\":[1,2,3]}"), "deep copy content");

    try checkDump(log, root, "{\"a\":{\"b\":[1,2,3]}}", "root unchanged");

    jz.lf_json_free(a);
    jz.lf_json_free(root);
    log.line("[ok]   I05");
}

// =============================================================================
// Section J - Edge cases
// =============================================================================

fn stepJ01_deepNesting(log: *Log) !void {
    log.line("[step] J01: deeply nested array");

    const text = std.heap.page_allocator.alloc(u8, 128) catch
        return error.OutOfMemory;
    defer std.heap.page_allocator.free(text);

    var pos: usize = 0;
    for (0..64) |_| {
        text[pos] = '[';
        pos += 1;
    }
    for (0..64) |_| {
        text[pos] = ']';
        pos += 1;
    }

    const h = jz.lf_json_parse(text.ptr, @intCast(pos));
    try check(log, h != null, "parse nested");
    jz.lf_json_free(h);

    log.line("[ok]   J01");
}

fn stepJ02_longString(log: *Log) !void {
    log.line("[step] J02: long string (8 KB)");

    const alloc = std.heap.page_allocator;
    const len: usize = 8192;
    const buf = alloc.alloc(u8, len) catch return error.OutOfMemory;
    defer alloc.free(buf);
    @memset(buf, 'x');

    const h = jz.lf_json_new_string(buf.ptr, @intCast(len));
    try check(log, h != null, "new long string");
    try check(log, jz.lf_json_string_size(h) == @as(i64, @intCast(len)), "size");
    jz.lf_json_free(h);

    log.line("[ok]   J02");
}

fn stepJ03_emptyObjectKey(log: *Log) !void {
    log.line("[step] J03: empty object key is legal");

    const h = parseCStr("{\"\":1}");
    try check(log, h != null, "parse");
    try check(log, jz.lf_json_object_size(h) == 1, "size 1");

    var key_buf: [4]u8 = undefined;
    const n = jz.lf_json_object_key_into(h, 0, &key_buf, key_buf.len);
    try check(log, n == 0, "empty key len");

    jz.lf_json_free(h);
    log.line("[ok]   J03");
}

fn stepJ04_utf8KeyOrdering(log: *Log) !void {
    log.line("[step] J04: keys sorted by UTF-8 byte order");

    const h = parseCStr("{\"\\u5f20\\u4e09\":3,\"b\":2,\"a\":1}");
    try check(log, h != null, "parse");

    var key_buf: [32]u8 = undefined;

    var n = jz.lf_json_object_key_into(h, 0, &key_buf, key_buf.len);
    try check(log, std.mem.eql(u8, key_buf[0..@intCast(n)], "a"), "key 0");

    n = jz.lf_json_object_key_into(h, 1, &key_buf, key_buf.len);
    try check(log, std.mem.eql(u8, key_buf[0..@intCast(n)], "b"), "key 1");

    n = jz.lf_json_object_key_into(h, 2, &key_buf, key_buf.len);
    try check(log, std.mem.eql(u8, key_buf[0..@intCast(n)], UTF8_ZHANGSAN), "key 2 (chinese)");

    jz.lf_json_free(h);
    log.line("[ok]   J04");
}

fn stepJ05_numericExtremes(log: *Log) !void {
    log.line("[step] J05: numeric extremes round-trip");

    var h = jz.lf_json_new_int64(std.math.minInt(i64));
    var out_i: i64 = 0;
    try check(log, jz.lf_json_get_int64(h, &out_i) == 1, "i64 min");
    try check(log, out_i == std.math.minInt(i64), "i64 min value");
    jz.lf_json_free(h);

    h = jz.lf_json_new_int64(std.math.maxInt(i64));
    try check(log, jz.lf_json_get_int64(h, &out_i) == 1, "i64 max");
    try check(log, out_i == std.math.maxInt(i64), "i64 max value");
    jz.lf_json_free(h);

    h = jz.lf_json_new_uint64(std.math.maxInt(u64));
    var out_u: u64 = 0;
    try check(log, jz.lf_json_get_uint64(h, &out_u) == 1, "u64 max");
    try check(log, out_u == std.math.maxInt(u64), "u64 max value");
    jz.lf_json_free(h);

    log.line("[ok]   J05");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    .{ .name = "A01 parse scalars", .fn_ = stepA01_parseScalars },
    .{ .name = "A02 parse string", .fn_ = stepA02_parseString },
    .{ .name = "A03 parse escapes", .fn_ = stepA03_parseEscapes },
    .{ .name = "A04 parse containers", .fn_ = stepA04_parseContainers },
    .{ .name = "A05 parse errors", .fn_ = stepA05_parseErrors },
    .{ .name = "A06 parse explicit len", .fn_ = stepA06_parseWithExplicitLen },
    .{ .name = "A07 free null", .fn_ = stepA07_freeNullSafe },

    .{ .name = "B01 type tags", .fn_ = stepB01_typeTags },

    .{ .name = "C01 dump scalars", .fn_ = stepC01_dumpScalars },
    .{ .name = "C02 dump strings", .fn_ = stepC02_dumpStrings },
    .{ .name = "C03 dump containers", .fn_ = stepC03_dumpContainers },
    .{ .name = "C04 dump edge", .fn_ = stepC04_dumpEdge },

    .{ .name = "D01 get_bool", .fn_ = stepD01_getBool },
    .{ .name = "D02 get_int64", .fn_ = stepD02_getInt64 },
    .{ .name = "D03 get_uint64", .fn_ = stepD03_getUint64 },
    .{ .name = "D04 get_double", .fn_ = stepD04_getDouble },
    .{ .name = "D05 string readers", .fn_ = stepD05_stringReaders },

    .{ .name = "E01 object_size", .fn_ = stepE01_objectSize },
    .{ .name = "E02 object_key_into", .fn_ = stepE02_objectKeyIteration },
    .{ .name = "E03 object_get", .fn_ = stepE03_objectGet },

    .{ .name = "F01 array_size", .fn_ = stepF01_arraySize },
    .{ .name = "F02 array_get", .fn_ = stepF02_arrayGet },

    .{ .name = "G01 new scalars", .fn_ = stepG01_newScalars },
    .{ .name = "G02 new string", .fn_ = stepG02_newString },
    .{ .name = "G03 dom array", .fn_ = stepG03_domArray },
    .{ .name = "G04 dom object", .fn_ = stepG04_domObject },
    .{ .name = "G05 dom nested", .fn_ = stepG05_domNested },
    .{ .name = "G06 dom == parse", .fn_ = stepG06_domEqualsParse },

    .{ .name = "H01 writer scalars", .fn_ = stepH01_writerScalars },
    .{ .name = "H02 writer strings", .fn_ = stepH02_writerStrings },
    .{ .name = "H03 writer raw", .fn_ = stepH03_writerRaw },
    .{ .name = "H04 writer edge", .fn_ = stepH04_writerEdge },
    .{ .name = "H05 writer no NUL", .fn_ = stepH05_writerNoTrailingNul },

    .{ .name = "I01 canonical bytes", .fn_ = stepI01_canonicalBytes },
    .{ .name = "I02 utf8 literal", .fn_ = stepI02_utf8Literal },
    .{ .name = "I03 control escapes", .fn_ = stepI03_controlEscapes },
    .{ .name = "I04 float formatting", .fn_ = stepI04_floatFormatting },
    .{ .name = "I05 deep copy", .fn_ = stepI05_deepCopyEquals },

    .{ .name = "J01 deep nesting", .fn_ = stepJ01_deepNesting },
    .{ .name = "J02 long string", .fn_ = stepJ02_longString },
    .{ .name = "J03 empty object key", .fn_ = stepJ03_emptyObjectKey },
    .{ .name = "J04 utf8 key order", .fn_ = stepJ04_utf8KeyOrdering },
    .{ .name = "J05 numeric extremes", .fn_ = stepJ05_numericExtremes },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("json_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open json_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig lf_json C ABI smoke test");
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
