// =============================================================================
//  util.zig - Shared low-level helpers for the LingoFuse Zig binding.
// -----------------------------------------------------------------------------
//  This module collects small, dependency-free utilities that several
//  higher-level modules need. Keeping them here avoids duplicating the
//  same code in `status.zig`, `framework.zig`, `data_handle.zig`, and
//  the modules added in the v0.4 upgrade (`options.zig`, `p2p.zig`,
//  `async_call.zig`).
//
//  Why a local `dupeZ`
//  -------------------
//  `std.mem.Allocator.dupeZ` was removed in Zig 0.17. Several modules
//  need a NUL-terminated copy of a caller-supplied slice in order to
//  build the `[*:0]const u8` that the native C ABI expects. This module
//  provides the single implementation.
//
//  Design constraints
//  ------------------
//  This module MUST NOT import any other module of the binding except
//  `error.zig`. It is the lowest layer of the higher-level wrappers,
//  and a circular dependency would be a design bug.
// =============================================================================

const std = @import("std");
const Error = @import("error.zig").Error;

// =============================================================================
// NUL-terminated duplication
// =============================================================================

/// Duplicate `s` into an allocator-owned, NUL-terminated slice.
///
/// The returned slice is sentinel-terminated: `result[result.len] == 0`
/// is guaranteed, and `result.ptr` is a valid `[*:0]u8`.
///
/// The caller owns the returned slice and must free it with
/// `alloc.free`.
///
/// # Relationship to the removed `Allocator.dupeZ`
///
/// This helper reproduces the exact semantics that
/// `std.mem.Allocator.dupeZ` provided before Zig 0.17 removed it. The
/// implementation uses only `alloc.alloc` and `@memcpy`, both of which
/// are stable across Zig releases.
///
/// # Example
///
/// ```zig
/// const s = try util.dupeZ(alloc, "hello");
/// defer alloc.free(s);
/// // s.ptr is a valid [*:0]u8
/// ```
pub fn dupeZ(alloc: std.mem.Allocator, s: []const u8) Error![:0]u8 {
    const buf = alloc.alloc(u8, s.len + 1) catch return Error.OutOfMemory;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

// =============================================================================
// C-string copy
// =============================================================================

/// Copy a NUL-terminated C string into an allocator-owned slice.
///
/// `ptr` must be non-null. The function reads until the first NUL and
/// copies the bytes immediately, so the caller does not depend on the
/// lifetime of the source buffer.
///
/// # Motivation
///
/// The native LingoFuse string accessors (`LF_Get_P2P_Name`,
/// `LF_GetOption`, `LF_GetStatus`, `LF_Generate_AppName`,
/// `LF_Get_AppName`) return pointers into transient buffers that the
/// library releases about 5 seconds after the call. Any caller that
/// wants to retain the value MUST copy it immediately. This helper is
/// the single sanctioned way to do so.
///
/// The caller owns the returned slice and must free it with
/// `alloc.free`.
pub fn copyCstr(alloc: std.mem.Allocator, ptr: [*:0]const u8) Error![:0]u8 {
    return dupeZ(alloc, std.mem.span(ptr));
}

/// Copy an optional NUL-terminated C string.
///
/// A null pointer yields an empty string. This is the correct
/// behaviour for every native accessor that returns a pointer only on
/// success and a null pointer otherwise.
pub fn copyCstrOrEmpty(
    alloc: std.mem.Allocator,
    ptr: ?[*:0]const u8,
) Error![:0]u8 {
    if (ptr) |p| return dupeZ(alloc, std.mem.span(p));
    return dupeZ(alloc, "");
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "dupeZ produces a NUL-terminated copy" {
    const alloc = testing.allocator;

    const s = try dupeZ(alloc, "hello");
    defer alloc.free(s);

    try testing.expectEqual(@as(usize, 5), s.len);
    try testing.expectEqual(@as(u8, 'h'), s[0]);
    try testing.expectEqual(@as(u8, 'o'), s[4]);
    try testing.expectEqual(@as(u8, 0), s[s.len]);
}

test "dupeZ handles an empty input" {
    const alloc = testing.allocator;

    const s = try dupeZ(alloc, "");
    defer alloc.free(s);

    try testing.expectEqual(@as(usize, 0), s.len);
    try testing.expectEqual(@as(u8, 0), s[s.len]);
}

test "dupeZ preserves embedded NUL bytes" {
    const alloc = testing.allocator;

    // The input contains an embedded NUL. dupeZ must copy every byte
    // verbatim and append exactly one NUL.
    const input = [_]u8{ 'a', 0, 'b' };
    const s = try dupeZ(alloc, &input);
    defer alloc.free(s);

    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(u8, 'a'), s[0]);
    try testing.expectEqual(@as(u8, 0), s[1]);
    try testing.expectEqual(@as(u8, 'b'), s[2]);
    try testing.expectEqual(@as(u8, 0), s[s.len]);
}

test "copyCstr reads up to the first NUL" {
    const alloc = testing.allocator;

    const s = try copyCstr(alloc, "hello");
    defer alloc.free(s);

    try testing.expectEqualStrings("hello", s);
}

test "copyCstrOrEmpty with null yields an empty string" {
    const alloc = testing.allocator;

    const s = try copyCstrOrEmpty(alloc, null);
    defer alloc.free(s);

    try testing.expectEqual(@as(usize, 0), s.len);
    try testing.expectEqual(@as(u8, 0), s[s.len]);
}

test "copyCstrOrEmpty with a non-null pointer copies it" {
    const alloc = testing.allocator;

    const s = try copyCstrOrEmpty(alloc, "abc");
    defer alloc.free(s);

    try testing.expectEqualStrings("abc", s);
}
