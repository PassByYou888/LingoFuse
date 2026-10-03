// =============================================================================
//  io_smoke.zig - Smoke test for the unified I/O layer, as a NORMAL program.
// -----------------------------------------------------------------------------
//  Why a normal program, not a Zig test
//  ------------------------------------
//  Same reason as `abi_smoke.zig`: the Zig test runner on Windows can
//  hang when the native LingoFuse library writes diagnostics to the
//  console (see the module docstring of `abi_smoke.zig` for the full
//  backstory). A normal executable sidesteps the transport entirely,
//  and every step is written to a log file before and after each
//  native call, so a hang leaves a usable trace.
//
//  File I/O
//  --------
//  The log is written through C stdio (`fopen` / `fwrite` / `fflush` /
//  `fclose`), declared with `extern "c"` below. The Zig `std.fs` file
//  API has changed shape between releases; C stdio is stable across
//  every release and every supported platform.
//
//  Every write is followed by an `fflush`, so that a crash or a hang
//  leaves the log file in the state it was at the moment of the
//  failure.
//
//  Coverage
//  --------
//  This file exercises every public function of `io.zig`:
//
//      * String I/O       - writeString, readString
//      * Byte I/O         - writeStringBytes, readStringBytes,
//                           peekStringBytes, readAllBytes
//      * JSON serialization - dumpsJson, writeJson
//      * JSON deserialization - loadsJson, readJson, tryReadJson
//
//  It also verifies the fault-tolerant NUL-aware read semantics
//  (Cases 1, 2, 3 of the module docstring of `io.zig`), including the
//  "cursor moves to size + 1" rule that every LingoFuse binding
//  shares.
//
//  Byte-level assertions
//  ---------------------
//  The wire format is verified byte-for-byte. The canonical example:
//
//      writeJson(&h, Payload{ .a = 1 })
//
//  must produce exactly:
//
//      7B 22 61 22 3A 31 7D 00
//
//  i.e. `{"a":1}` followed by a single NUL.
//
//  Error assertions
//  ----------------
//  Zig represents a fallible call as an error union (`Error!T`). An
//  error-union value cannot be compared directly against an error-set
//  member; it must be destructured first. The `expectError` helper
//  below expresses "this call failed with exactly this error" in one
//  line, and works for `Error!void` and `Error!T` alike.
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

// -----------------------------------------------------------------------------
// Shared test payloads.
//
// Field order inside a struct is the order the serializer emits. The
// JSON text produced for a given payload is verified byte-for-byte,
// so any change to this struct must be mirrored in the matching
// assertion.
// -----------------------------------------------------------------------------

const PairPayload = struct { a: i32, b: i32 };
const OnePayload = struct { a: i32 };
const MsgPayload = struct { msg: []const u8 };
const NamePayload = struct { name: []const u8, emoji: []const u8 };

// UTF-8 literals, written with explicit escapes so that this file is
// independent of the editor's source encoding.
//
//   "hello, " (7 bytes) + U+4E16 (3) + U+754C (3) + " " (1) + U+1F30D (4)
const UTF8_HELLO = "hello, \xe4\xb8\x96\xe7\x95\x8c \xf0\x9f\x8c\x8d";
//   U+5F20 U+4E09
const UTF8_ZHANGSAN = "\xe5\xbc\xa0\xe4\xb8\x89";
//   U+1F30D (earth globe europe-africa)
const UTF8_EARTH = "\xf0\x9f\x8c\x8d";

// =============================================================================
// Steps - String I/O
// =============================================================================

fn stepStringRoundtrip(log: *Log) !void {
    log.line("[step] io: writeString / readString round-trip");
    var h = try lf.DataHandle.create("io_string_rt");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    try lf.io.writeString(&h, UTF8_HELLO);
    // The payload is exactly text.len bytes; writeString appends one NUL.
    try check(log, (try h.size()) == UTF8_HELLO.len + 1, "size == text.len + 1");

    try h.setPosition(0);
    const rb = try lf.io.readString(&h, alloc);
    defer alloc.free(rb);
    try check(log, std.mem.eql(u8, rb, UTF8_HELLO), "content match");

    log.line("[ok]   io: string round-trip");
}

fn stepEmptyString(log: *Log) !void {
    log.line("[step] io: writeString with an empty string writes one NUL");
    var h = try lf.DataHandle.create("io_empty_string");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    try lf.io.writeString(&h, "");
    try check(log, (try h.size()) == 1, "size == 1");

    try h.setPosition(0);
    const rb = try lf.io.readString(&h, alloc);
    defer alloc.free(rb);
    try check(log, rb.len == 0, "empty result");

    log.line("[ok]   io: empty string");
}

fn stepWriteStringBytesEmbeddedNul(log: *Log) !void {
    log.line("[step] io: writeStringBytes preserves embedded NUL");
    var h = try lf.DataHandle.create("io_bytes_embedded");
    defer h.deinit();

    const payload = [_]u8{ 'a', 0, 'b', 0, 'c' };
    try lf.io.writeStringBytes(&h, &payload);

    // 5 payload bytes + 1 framing NUL = 6.
    try check(log, (try h.size()) == 6, "size == payload.len + 1");

    log.line("[ok]   io: writeStringBytes embedded NUL");
}

fn stepReadStringBytesStopsAtNul(log: *Log) !void {
    log.line("[step] io: readStringBytes stops at the first embedded NUL");
    var h = try lf.DataHandle.create("io_bytes_read");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    try lf.io.writeStringBytes(&h, &[_]u8{ 'a', 0, 'b' });
    try h.setPosition(0);

    const rb = try lf.io.readStringBytes(&h, alloc);
    defer alloc.free(rb);

    // Only "a" is returned. The embedded NUL acts as a terminator.
    try check(log, std.mem.eql(u8, rb, "a"), "stops at first embedded NUL");

    log.line("[ok]   io: readStringBytes stops at NUL");
}

fn stepPeekDoesNotAdvance(log: *Log) !void {
    log.line("[step] io: peekStringBytes does not advance the cursor");
    var h = try lf.DataHandle.create("io_peek");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    try lf.io.writeString(&h, "peek-me");
    try h.setPosition(0);

    const first = try lf.io.peekStringBytes(&h, alloc);
    defer alloc.free(first);
    try check(log, std.mem.eql(u8, first, "peek-me"), "first peek content");

    try check(log, (try h.position()) == 0, "cursor unchanged after peek");

    // A second peek must return the same bytes.
    const second = try lf.io.peekStringBytes(&h, alloc);
    defer alloc.free(second);
    try check(log, std.mem.eql(u8, first, second), "second peek matches first");

    // A real read now consumes the payload.
    const read_back = try lf.io.readString(&h, alloc);
    defer alloc.free(read_back);
    try check(log, std.mem.eql(u8, read_back, "peek-me"), "read after peek");

    log.line("[ok]   io: peek does not advance");
}

fn stepReadAllBytesRaw(log: *Log) !void {
    log.line("[step] io: readAllBytes returns raw bytes");
    var h = try lf.DataHandle.create("io_read_all");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    // An embedded NUL and a high byte: readAllBytes must not treat
    // either of them specially.
    const payload = [_]u8{ 0x00, 0x01, 0x02, 0xFF };
    try h.writeBytes(&payload);
    try h.setPosition(0);

    const all = try lf.io.readAllBytes(&h, alloc);
    defer alloc.free(all);
    try check(log, std.mem.eql(u8, all, &payload), "raw bytes match");

    log.line("[ok]   io: readAllBytes raw");
}

fn stepReadWithoutNul(log: *Log) !void {
    log.line("[step] io: readString without a NUL consumes the remaining buffer");
    var h = try lf.DataHandle.create("io_no_nul");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    // Write raw JSON with NO trailing NUL. This simulates a payload
    // arriving from an HTTP bridge or any other producer that does
    // not append a NUL.
    try h.writeBytes("{\"a\":1}");
    try h.setPosition(0);

    const rb = try lf.io.readString(&h, alloc);
    defer alloc.free(rb);
    try check(log, std.mem.eql(u8, rb, "{\"a\":1}"), "consumes all remaining bytes");

    log.line("[ok]   io: readString without NUL");
}

fn stepReadWithoutNulCursor(log: *Log) !void {
    log.line("[step] io: readString without a NUL advances the cursor to size + 1");
    var h = try lf.DataHandle.create("io_cursor_edge");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    try h.writeBytes("abcd");
    try h.setPosition(0);

    const rb = try lf.io.readString(&h, alloc);
    defer alloc.free(rb);
    try check(log, std.mem.eql(u8, rb, "abcd"), "content match");

    // Case 2 of the fault-tolerant read rule: the cursor moves to
    // (buffer size + 1), i.e. one byte past the end. This matches
    // Pascal's LF_SetPos(Hnd, e + 1) with e == size.
    const pos = try h.position();
    try check(log, pos == 5, "cursor == size + 1");

    log.line("[ok]   io: cursor at size + 1");
}

// =============================================================================
// Steps - JSON serialization (no handle)
// =============================================================================

fn stepDumpsJsonCompact(log: *Log) !void {
    log.line("[step] io: dumpsJson produces compact output");
    const alloc = std.heap.page_allocator;

    const text = try lf.io.dumpsJson(alloc, PairPayload{ .a = 1, .b = 2 });
    defer alloc.free(text);

    try check(log, std.mem.eql(u8, text, "{\"a\":1,\"b\":2}"), "compact text");
    try check(
        log,
        std.mem.indexOfScalar(u8, text, '\n') == null,
        "no newline",
    );
    try check(
        log,
        std.mem.indexOfScalar(u8, text, ' ') == null,
        "no space",
    );

    log.line("[ok]   io: dumpsJson compact");
}

fn stepDumpsJsonNonAscii(log: *Log) !void {
    log.line("[step] io: dumpsJson preserves non-ASCII as literal UTF-8");
    const alloc = std.heap.page_allocator;

    const text = try lf.io.dumpsJson(alloc, MsgPayload{ .msg = UTF8_ZHANGSAN });
    defer alloc.free(text);

    // The literal CJK bytes must appear verbatim in the output.
    try check(
        log,
        std.mem.indexOf(u8, text, UTF8_ZHANGSAN) != null,
        "CJK bytes are literal",
    );
    // No \uXXXX escape may appear anywhere.
    try check(
        log,
        std.mem.indexOf(u8, text, "\\u") == null,
        "no \\uXXXX escape",
    );

    log.line("[ok]   io: dumpsJson non-ASCII");
}

fn stepDumpsJsonControlEscapes(log: *Log) !void {
    log.line("[step] io: dumpsJson escapes control characters only");
    const alloc = std.heap.page_allocator;

    // Newline, tab, carriage return, backspace, form feed.
    const text = try lf.io.dumpsJson(
        alloc,
        MsgPayload{ .msg = "a\nb\tc\rd\x08e\x0C" },
    );
    defer alloc.free(text);

    // Every one of those characters must appear as a two-character
    // escape sequence.
    try check(log, std.mem.indexOf(u8, text, "\\n") != null, "newline escaped");
    try check(log, std.mem.indexOf(u8, text, "\\t") != null, "tab escaped");
    try check(log, std.mem.indexOf(u8, text, "\\r") != null, "CR escaped");
    try check(log, std.mem.indexOf(u8, text, "\\b") != null, "backspace escaped");
    try check(log, std.mem.indexOf(u8, text, "\\f") != null, "form feed escaped");

    log.line("[ok]   io: dumpsJson control escapes");
}

fn stepLoadsJsonStrict(log: *Log) !void {
    log.line("[step] io: loadsJson is strict");
    const alloc = std.heap.page_allocator;

    // Valid input parses.
    {
        const parsed = lf.io.loadsJson(alloc, "{\"a\":1}", OnePayload) catch {
            try check(log, false, "valid JSON must parse");
            return error.AssertFailed;
        };
        defer parsed.deinit();
        try check(log, parsed.value.a == 1, "parsed value");
    }

    // Empty string is rejected.
    {
        const result = lf.io.loadsJson(alloc, "", OnePayload);
        try check(
            log,
            expectError(result, lf.Error.ReadFailed),
            "empty rejected",
        );
    }

    // Trailing comma is rejected (it is not valid JSON).
    {
        const result = lf.io.loadsJson(alloc, "{\"a\":1,}", OnePayload);
        try check(
            log,
            expectError(result, lf.Error.ReadFailed),
            "trailing comma rejected",
        );
    }

    log.line("[ok]   io: loadsJson strict");
}

// =============================================================================
// Steps - JSON I/O through a handle
// =============================================================================

fn stepJsonRoundtrip(log: *Log) !void {
    log.line("[step] io: writeJson / readJson round-trip");
    var h = try lf.DataHandle.create("io_json_rt");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    try lf.io.writeJson(&h, PairPayload{ .a = 5, .b = 7 });
    try h.setPosition(0);

    var parsed = try lf.io.readJson(&h, alloc, PairPayload);
    defer parsed.deinit();

    try check(log, parsed.value.a == 5, "a == 5");
    try check(log, parsed.value.b == 7, "b == 7");

    log.line("[ok]   io: writeJson / readJson round-trip");
}

fn stepJsonByteLevel(log: *Log) !void {
    log.line("[step] io: writeJson produces exactly {\"a\":1}\\0");
    var h = try lf.DataHandle.create("io_json_bytes");
    defer h.deinit();

    try lf.io.writeJson(&h, OnePayload{ .a = 1 });

    // `{"a":1}` is 7 bytes; the framing NUL adds one more.
    try check(log, (try h.size()) == 8, "size == 8");

    try h.setPosition(0);
    var buf: [8]u8 = undefined;
    const got = try h.readBytes(&buf);
    try check(log, got == 8, "read 8 bytes");

    const expected = [_]u8{ '{', '"', 'a', '"', ':', '1', '}', 0 };
    try check(log, std.mem.eql(u8, &buf, &expected), "wire bytes match");

    log.line("[ok]   io: writeJson byte-level");
}

fn stepJsonUnicode(log: *Log) !void {
    log.line("[step] io: writeJson / readJson Unicode round-trip");
    var h = try lf.DataHandle.create("io_json_unicode");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    try lf.io.writeJson(
        &h,
        NamePayload{ .name = UTF8_ZHANGSAN, .emoji = UTF8_EARTH },
    );

    // Inspect the raw wire bytes first.
    try h.setPosition(0);
    const raw = try lf.io.readStringBytes(&h, alloc);
    defer alloc.free(raw);

    try check(
        log,
        std.mem.indexOf(u8, raw, UTF8_ZHANGSAN) != null,
        "CJK literal on the wire",
    );
    try check(
        log,
        std.mem.indexOf(u8, raw, UTF8_EARTH) != null,
        "emoji literal on the wire",
    );
    try check(
        log,
        std.mem.indexOf(u8, raw, "\\u") == null,
        "no \\uXXXX escape on the wire",
    );

    // Now round-trip through the parser.
    try h.setPosition(0);
    var parsed = try lf.io.readJson(&h, alloc, NamePayload);
    defer parsed.deinit();

    try check(
        log,
        std.mem.eql(u8, parsed.value.name, UTF8_ZHANGSAN),
        "name round-trip",
    );
    try check(
        log,
        std.mem.eql(u8, parsed.value.emoji, UTF8_EARTH),
        "emoji round-trip",
    );

    log.line("[ok]   io: writeJson Unicode round-trip");
}

// =============================================================================
// Steps - JSON error paths
// =============================================================================

fn stepReadJsonEmpty(log: *Log) !void {
    log.line("[step] io: readJson rejects an empty payload");
    var h = try lf.DataHandle.create("io_json_empty");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    // An empty payload is exactly one NUL byte on the wire.
    try lf.io.writeString(&h, "");
    try h.setPosition(0);

    const result = lf.io.readJson(&h, alloc, OnePayload);
    try check(
        log,
        expectError(result, lf.Error.ReadFailed),
        "empty payload rejected",
    );

    log.line("[ok]   io: readJson empty");
}

fn stepTryReadJsonGarbage(log: *Log) !void {
    log.line("[step] io: tryReadJson returns null on garbage");
    var h = try lf.DataHandle.create("io_json_garbage");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    try lf.io.writeString(&h, "not json");
    try h.setPosition(0);

    const result = try lf.io.tryReadJson(&h, alloc, OnePayload);
    try check(log, result == null, "garbage -> null");

    log.line("[ok]   io: tryReadJson garbage");
}

fn stepTryReadJsonTypeMismatch(log: *Log) !void {
    log.line("[step] io: tryReadJson returns null on a type mismatch");
    var h = try lf.DataHandle.create("io_json_mismatch");
    defer h.deinit();

    const alloc = std.heap.page_allocator;

    // Valid JSON, but the shape does not match OnePayload.
    try lf.io.writeString(&h, "[1,2,3]");
    try h.setPosition(0);

    const result = try lf.io.tryReadJson(&h, alloc, OnePayload);
    try check(log, result == null, "type mismatch -> null");

    log.line("[ok]   io: tryReadJson type mismatch");
}

// =============================================================================
// Step table
// =============================================================================

const Step = struct {
    name: []const u8,
    fn_: *const fn (*Log) anyerror!void,
};

const ALL_STEPS = [_]Step{
    // String I/O
    .{ .name = "io: string round-trip", .fn_ = stepStringRoundtrip },
    .{ .name = "io: empty string", .fn_ = stepEmptyString },
    .{ .name = "io: writeStringBytes embedded NUL", .fn_ = stepWriteStringBytesEmbeddedNul },
    .{ .name = "io: readStringBytes stops at NUL", .fn_ = stepReadStringBytesStopsAtNul },
    .{ .name = "io: peek does not advance", .fn_ = stepPeekDoesNotAdvance },
    .{ .name = "io: readAllBytes raw", .fn_ = stepReadAllBytesRaw },
    .{ .name = "io: readString without NUL", .fn_ = stepReadWithoutNul },
    .{ .name = "io: cursor at size + 1", .fn_ = stepReadWithoutNulCursor },

    // JSON serialization (no handle)
    .{ .name = "io: dumpsJson compact", .fn_ = stepDumpsJsonCompact },
    .{ .name = "io: dumpsJson non-ASCII", .fn_ = stepDumpsJsonNonAscii },
    .{ .name = "io: dumpsJson control escapes", .fn_ = stepDumpsJsonControlEscapes },
    .{ .name = "io: loadsJson strict", .fn_ = stepLoadsJsonStrict },

    // JSON I/O through a handle
    .{ .name = "io: writeJson / readJson round-trip", .fn_ = stepJsonRoundtrip },
    .{ .name = "io: writeJson byte-level", .fn_ = stepJsonByteLevel },
    .{ .name = "io: writeJson Unicode round-trip", .fn_ = stepJsonUnicode },

    // JSON error paths
    .{ .name = "io: readJson empty", .fn_ = stepReadJsonEmpty },
    .{ .name = "io: tryReadJson garbage", .fn_ = stepTryReadJsonGarbage },
    .{ .name = "io: tryReadJson type mismatch", .fn_ = stepTryReadJsonTypeMismatch },
};

// =============================================================================
// Main
// =============================================================================

pub fn main() void {
    var log = Log.open("io_smoke.log");
    if (log.file == null) {
        std.debug.print("[FATAL] cannot open io_smoke.log\n", .{});
        exit(2);
    }
    defer log.close();

    log.line("================================================================");
    log.line("  LingoFuse Zig unified I/O smoke test");
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
    log.fmt("  Results: {d} passed, {d} failed, {d} total", .{ passed, failed, passed + failed });
    log.line("================================================================");

    if (failed != 0) exit(1);
}
