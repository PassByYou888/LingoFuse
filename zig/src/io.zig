// =============================================================================
//  io.zig - Unified JSON / string / byte I/O for LingoFuse data handles.
// -----------------------------------------------------------------------------
//  This module is the Zig counterpart of `lf_io.hpp` (C++), `LfIo.cs`
//  (C#), `lf-io.js` (JavaScript), `lf_io.py` (Python), and `io.rs`
//  (Rust). It is the SINGLE sanctioned path for moving structured data
//  to and from a `DataHandle`.
//
//  Wire format
//  -----------
//      JSON payload   : [UTF-8 encoded JSON text][NUL byte]
//      Text payload   : [UTF-8 text][NUL byte]
//      Binary payload : [arbitrary bytes][NUL byte]
//
//  Reading is fault-tolerant: if no NUL is found before the end of the
//  buffer, the entire remaining buffer is consumed. The cursor is
//  advanced to (buffer size + 1) in that case, matching the native
//  rule documented in every other binding.
//
//  JSON engine
//  -----------
//  Serialization goes through nlohmann/json — the exact same engine
//  the C++ binding uses — via the `lf_json_*` C ABI declared in
//  `json_c.zig`. This guarantees that every byte we emit is
//  byte-identical to what the C++ binding would emit for the same
//  logical value:
//
//      * Compact output (no whitespace).
//      * Literal UTF-8 for non-ASCII (never \uXXXX for characters
//        representable as UTF-8 bytes).
//      * Short escapes for \n, \r, \t, \b, \f.
//      * nlohmann's Grisu2 float formatting (round-trip safe).
//      * NaN / infinity emitted as JSON `null`.
//
//  The Zig-side serializer walks `@typeInfo(T)` and calls into the
//  lf_json streaming writer. It does NOT compute any JSON text
//  itself; the writer decides how bytes are produced.
//
//  Deserialization goes through `std.json.parseFromSlice`. Writing a
//  general Zig-typed JSON reader on top of the lf_json DOM would
//  require a full second reflection pass to construct every kind of
//  `T`, which is a large amount of code for little benefit. `std.json`
//  already implements that and its parsing decisions match nlohmann's
//  for all well-formed JSON input.
//
//  The `.allocate = .alloc_always` option is critical for the reader:
//  with the default `.alloc_if_needed`, `parseFromSlice` aliases the
//  caller's input buffer for any string that requires no escape
//  processing. In `readJson` and `tryReadJson` that buffer is a
//  temporary freed by a `defer` before the function returns, which
//  would leave the parsed value with dangling string slices.
// =============================================================================

const std = @import("std");
const DataHandle = @import("data_handle.zig").DataHandle;
const Error = @import("error.zig").Error;
const json_c = @import("json_c.zig");

/// The NUL byte used as the string terminator on the wire.
pub const NUL_BYTE: u8 = 0x00;

// =============================================================================
// String I/O
// =============================================================================

/// Write `value` as UTF-8 bytes, followed by a single NUL byte.
///
/// An empty string writes exactly one byte (the NUL), matching every
/// other LingoFuse binding.
pub fn writeString(handle: *DataHandle, value: []const u8) Error!void {
    try handle.writeBytes(value);
    try handle.writeBytes(&[_]u8{NUL_BYTE});
}

/// Write raw bytes followed by a single NUL byte.
///
/// Unlike `writeString`, embedded NUL bytes in `data` are preserved
/// in the buffer; only one extra NUL is appended at the end.
pub fn writeStringBytes(handle: *DataHandle, data: []const u8) Error!void {
    try handle.writeBytes(data);
    try handle.writeBytes(&[_]u8{NUL_BYTE});
}

/// Read a UTF-8 string from the handle, stopping at the first NUL.
///
/// If no NUL is present, the entire remaining buffer is consumed.
/// The returned slice is owned by the caller and must be freed with
/// `alloc.free`.
pub fn readString(handle: *DataHandle, alloc: std.mem.Allocator) Error![]u8 {
    return readUntilNul(handle, alloc);
}

/// Read raw bytes from the handle, stopping at the first NUL.
///
/// Functionally identical to `readString`.
pub fn readStringBytes(handle: *DataHandle, alloc: std.mem.Allocator) Error![]u8 {
    return readUntilNul(handle, alloc);
}

/// Read raw bytes up to the first NUL WITHOUT advancing the cursor.
///
/// The cursor is restored to its original value before returning,
/// even if the read itself failed.
pub fn peekStringBytes(handle: *DataHandle, alloc: std.mem.Allocator) Error![]u8 {
    const saved = try handle.position();
    const result = readUntilNul(handle, alloc);
    if (result) |bytes| {
        try handle.setPosition(saved);
        return bytes;
    } else |err| {
        handle.setPosition(saved) catch {};
        return err;
    }
}

/// Read every remaining byte from the current cursor to the end of
/// the buffer, and advance the cursor to the end.
pub fn readAllBytes(handle: *DataHandle, alloc: std.mem.Allocator) Error![]u8 {
    const pos = try handle.position();
    const total = try handle.size();

    if (pos >= total) {
        return alloc.alloc(u8, 0) catch Error.OutOfMemory;
    }

    const remaining: usize = @intCast(total - pos);
    const buf = alloc.alloc(u8, remaining) catch return Error.OutOfMemory;
    errdefer alloc.free(buf);

    const got = try handle.readBytes(buf);
    if (got != remaining) {
        return Error.ReadFailed;
    }
    return buf;
}

// -----------------------------------------------------------------------------
// Internal: fault-tolerant NUL-aware read
// -----------------------------------------------------------------------------
//
// Case 1 - NUL found at offset `n`:
//     return bytes [start, start + n);
//     cursor -> start + n + 1.
//
// Case 2 - no NUL before end of buffer:
//     return bytes [start, size);
//     cursor -> size + 1.
//
// Case 3 - cursor at or past end of buffer:
//     return empty slice;
//     cursor unchanged.
//
fn readUntilNul(handle: *DataHandle, alloc: std.mem.Allocator) Error![]u8 {
    const start = try handle.position();
    const total = try handle.size();

    // Case 3
    if (start >= total) {
        return alloc.alloc(u8, 0) catch Error.OutOfMemory;
    }

    const remaining: usize = @intCast(total - start);
    const raw = alloc.alloc(u8, remaining) catch return Error.OutOfMemory;
    defer alloc.free(raw);

    const got = try handle.readBytes(raw);

    const nul_index = std.mem.indexOfScalar(u8, raw[0..got], NUL_BYTE);

    var content_len: usize = undefined;
    var new_pos: i64 = undefined;

    if (nul_index) |idx| {
        // Case 1
        content_len = idx;
        new_pos = start + @as(i64, @intCast(idx)) + 1;
    } else {
        // Case 2
        content_len = got;
        new_pos = start + @as(i64, @intCast(got)) + 1;
    }

    try handle.setPosition(new_pos);

    const result = alloc.alloc(u8, content_len) catch return Error.OutOfMemory;
    if (content_len > 0) {
        @memcpy(result, raw[0..content_len]);
    }
    return result;
}

// =============================================================================
// JSON serialization
// =============================================================================

/// Streaming writer that forwards every serialization step to the
/// `lf_json` C ABI.
///
/// This type is the compile-time interface expected by
/// [`serializeJson`]. The method names form the contract; any other
/// type with these methods can be substituted in tests without
/// touching the serializer.
const LfJsonWriter = struct {
    handle: json_c.JsonWriter,

    /// Emit structural punctuation (`{`, `}`, `[`, `]`, `:`, `,`).
    ///
    /// The caller guarantees the bytes are valid JSON syntax. No
    /// quoting or escaping is applied.
    pub fn writeRaw(self: LfJsonWriter, bytes: []const u8) Error!void {
        json_c.lf_json_writer_raw(self.handle, bytes.ptr, @intCast(bytes.len));
    }

    /// Emit a JSON string literal from a UTF-8 byte slice.
    ///
    /// The quotes and the escaping are produced by nlohmann's exact
    /// policy: literal UTF-8 for non-ASCII, short escapes for the
    /// control characters, `\u00XX` for the rest of U+0000..U+001F.
    pub fn writeString(self: LfJsonWriter, bytes: []const u8) Error!void {
        json_c.lf_json_writer_string(self.handle, bytes.ptr, @intCast(bytes.len));
    }

    /// Emit a signed integer.
    pub fn writeInt(self: LfJsonWriter, v: i64) Error!void {
        json_c.lf_json_writer_int64(self.handle, v);
    }

    /// Emit an unsigned integer.
    pub fn writeUint(self: LfJsonWriter, v: u64) Error!void {
        json_c.lf_json_writer_uint64(self.handle, v);
    }

    /// Emit a floating-point value.
    ///
    /// nlohmann applies its Grisu2 formatting; NaN and infinity are
    /// emitted as the JSON literal `null`.
    pub fn writeFloat(self: LfJsonWriter, v: f64) Error!void {
        json_c.lf_json_writer_double(self.handle, v);
    }

    /// Emit `true` or `false`.
    pub fn writeBool(self: LfJsonWriter, v: bool) Error!void {
        json_c.lf_json_writer_bool(self.handle, if (v) 1 else 0);
    }

    /// Emit `null`.
    pub fn writeNull(self: LfJsonWriter) Error!void {
        json_c.lf_json_writer_null(self.handle);
    }
};

/// Serialize `value` as compact JSON and append a trailing NUL byte
/// to the handle.
///
/// The wire bytes are produced by lf_json / nlohmann, so they are
/// byte-identical to what the C++ binding writes for the same value.
///
/// A small stack buffer handles the common case (payloads under 1 KB)
/// without a heap allocation.
pub fn writeJson(handle: *DataHandle, value: anytype) Error!void {
    const w = json_c.lf_json_writer_new();
    if (w == null) return Error.OutOfMemory;
    defer json_c.lf_json_writer_free(w);

    const sink = LfJsonWriter{ .handle = w };
    try serializeJson(sink, value);

    const n = json_c.lf_json_writer_size(w);
    if (n < 0) return Error.WriteFailed;
    const n_usize: usize = @intCast(n);

    // Fast path: the whole payload fits in the stack buffer.
    var stack_buf: [1024]u8 = undefined;
    if (n_usize <= stack_buf.len) {
        if (json_c.lf_json_writer_into(w, &stack_buf, n) != n) {
            return Error.WriteFailed;
        }
        try handle.writeBytes(stack_buf[0..n_usize]);
        try handle.writeBytes(&[_]u8{NUL_BYTE});
        return;
    }

    // Slow path: heap-allocated staging buffer.
    const alloc = std.heap.page_allocator;
    const heap_buf = alloc.alloc(u8, n_usize) catch return Error.OutOfMemory;
    defer alloc.free(heap_buf);

    if (json_c.lf_json_writer_into(w, heap_buf.ptr, n) != n) {
        return Error.WriteFailed;
    }
    try handle.writeBytes(heap_buf);
    try handle.writeBytes(&[_]u8{NUL_BYTE});
}

/// Serialize `value` as a compact JSON string, without a trailing NUL.
///
/// The caller owns the returned slice and must free it with
/// `alloc.free`.
pub fn dumpsJson(alloc: std.mem.Allocator, value: anytype) Error![]u8 {
    const w = json_c.lf_json_writer_new();
    if (w == null) return Error.OutOfMemory;
    defer json_c.lf_json_writer_free(w);

    const sink = LfJsonWriter{ .handle = w };
    try serializeJson(sink, value);

    const n = json_c.lf_json_writer_size(w);
    if (n < 0) return Error.WriteFailed;
    const n_usize: usize = @intCast(n);

    const result = alloc.alloc(u8, n_usize) catch return Error.OutOfMemory;
    errdefer alloc.free(result);

    if (json_c.lf_json_writer_into(w, result.ptr, n) != n) {
        return Error.WriteFailed;
    }
    return result;
}

/// The single generic serializer.
///
/// Dispatches on `@typeInfo(T)` and calls the corresponding method on
/// `writer`. The `writer` parameter is a compile-time duck-typed
/// value with the following methods:
///
///     fn writeRaw(self, bytes: []const u8) Error!void
///     fn writeString(self, bytes: []const u8) Error!void
///     fn writeInt(self, v: i64) Error!void
///     fn writeUint(self, v: u64) Error!void
///     fn writeFloat(self, v: f64) Error!void
///     fn writeBool(self, v: bool) Error!void
///     fn writeNull(self) Error!void
///
/// The serializer never computes JSON text itself; the writer decides
/// how bytes are produced. This makes it trivial to swap the JSON
/// engine in the future without touching this function.
pub fn serializeJson(writer: anytype, value: anytype) Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .null => try writer.writeNull(),

        .bool => try writer.writeBool(value),

        .int => |i| {
            // Signedness is a property of the integer type, so the
            // dispatch happens at comptime.
            if (i.signedness == .signed) {
                try writer.writeInt(@intCast(value));
            } else {
                try writer.writeUint(@intCast(value));
            }
        },

        .comptime_int => {
            // `comptime_int` has no fixed width. Route by sign at
            // runtime; the JSON writer narrows to i64 / u64 anyway.
            if (value < 0) {
                try writer.writeInt(@intCast(value));
            } else {
                try writer.writeUint(@intCast(value));
            }
        },

        .float, .comptime_float => try writer.writeFloat(@floatCast(value)),

        .optional => {
            if (value) |v| {
                try serializeJson(writer, v);
            } else {
                try writer.writeNull();
            }
        },

        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    // `[]u8` and `[]const u8` are strings; all other
                    // slices are arrays.
                    if (p.child == u8) {
                        try writer.writeString(value);
                    } else {
                        try writer.writeRaw("[");
                        for (value, 0..) |item, idx| {
                            if (idx > 0) try writer.writeRaw(",");
                            try serializeJson(writer, item);
                        }
                        try writer.writeRaw("]");
                    }
                },
                .one => {
                    // Single-item pointer: dereference.
                    try serializeJson(writer, value.*);
                },
                else => @compileError(
                    "io.serializeJson: only slice and single-item " ++
                        "pointers are supported; convert many/C pointers " ++
                        "to slices before serializing",
                ),
            }
        },

        .array => |a| {
            // `[N]u8` is a string; other arrays are JSON arrays.
            if (a.child == u8) {
                try writer.writeString(value[0..]);
            } else {
                try writer.writeRaw("[");
                for (value, 0..) |item, idx| {
                    if (idx > 0) try writer.writeRaw(",");
                    try serializeJson(writer, item);
                }
                try writer.writeRaw("]");
            }
        },

        .@"struct" => {
            try writer.writeRaw("{");

            // Zig 0.17 renamed the members of `lang.Type.Struct`:
            // `std.meta.fields` is now a hard compile error, and the
            // old `@typeInfo(T).@"struct".fields` access no longer
            // exists either. Probe at comptime for whichever layout
            // this compiler uses.
            const S = @typeInfo(T).@"struct";
            const ST = @TypeOf(S);

            if (comptime @hasField(ST, "fields")) {
                inline for (S.fields, 0..) |field, idx| {
                    if (idx > 0) try writer.writeRaw(",");
                    try writer.writeString(field.name);
                    try writer.writeRaw(":");
                    try serializeJson(writer, @field(value, field.name));
                }
            } else if (comptime @hasField(ST, "field_names")) {
                inline for (S.field_names, 0..) |name, idx| {
                    if (idx > 0) try writer.writeRaw(",");
                    try writer.writeString(name);
                    try writer.writeRaw(":");
                    try serializeJson(writer, @field(value, name));
                }
            } else {
                @compileError(
                    "io.serializeJson: unrecognized struct type-info " ++
                        "layout. Open zig/lib/std/lang.zig near the " ++
                        "`pub const Struct` declaration and report the " ++
                        "field names so the compat branches can be updated.",
                );
            }

            try writer.writeRaw("}");
        },

        .@"enum" => {
            try writer.writeString(@tagName(value));
        },

        .@"union" => {
            @compileError(
                "io.serializeJson: union serialization is not yet " ++
                    "implemented. See the module docstring for the planned " ++
                    "extension point.",
            );
        },

        else => @compileError(
            "io.serializeJson: unsupported type: " ++ @typeName(T),
        ),
    }
}

// =============================================================================
// JSON deserialization
// =============================================================================
//
// Delegates to `std.json.parseFromSlice`.
//
// The `.allocate = .alloc_always` option is critical. With the default
// `.alloc_if_needed`, `parseFromSlice` aliases the caller's input buffer
// for any string that requires no escape processing. In `readJson` and
// `tryReadJson` the input buffer is a temporary that is freed by a
// `defer` before the function returns, so the parsed value would end up
// with dangling string slices. `.alloc_always` makes the parser copy
// every string into its own arena, so the returned `Parsed(T)` is
// self-contained and can outlive the input.

/// Parse a NUL-framed JSON payload from `handle` into `T`.
///
/// The caller owns the returned `Parsed(T)` and must call `deinit()`
/// on it. An empty payload, a malformed payload, or a payload that
/// does not match the shape of `T` produces `Error.ReadFailed`.
pub fn readJson(
    handle: *DataHandle,
    alloc: std.mem.Allocator,
    comptime T: type,
) Error!std.json.Parsed(T) {
    const text = try readUntilNul(handle, alloc);
    defer alloc.free(text);

    return std.json.parseFromSlice(T, alloc, text, .{
        .allocate = .alloc_always,
    }) catch {
        return Error.ReadFailed;
    };
}

/// Non-throwing counterpart of `readJson`.
///
/// Returns `null` when the payload is empty, malformed, or does not
/// match `T`. A closed or invalid handle still returns an error.
pub fn tryReadJson(
    handle: *DataHandle,
    alloc: std.mem.Allocator,
    comptime T: type,
) Error!?std.json.Parsed(T) {
    const text = try readUntilNul(handle, alloc);
    defer alloc.free(text);

    const parsed = std.json.parseFromSlice(T, alloc, text, .{
        .allocate = .alloc_always,
    }) catch {
        return null;
    };
    return parsed;
}

/// Parse a JSON text string (no NUL framing) into `T`.
///
/// The caller owns the returned `Parsed(T)` and must call `deinit()`
/// on it.
pub fn loadsJson(
    alloc: std.mem.Allocator,
    text: []const u8,
    comptime T: type,
) Error!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, text, .{
        .allocate = .alloc_always,
    }) catch {
        return Error.ReadFailed;
    };
}
