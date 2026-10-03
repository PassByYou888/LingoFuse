// =============================================================================
//  data_handle.zig - RAII wrapper around a native LingoFuse data handle.
// -----------------------------------------------------------------------------
//  A DataHandle owns a native TDataHnd and provides safe byte-oriented
//  and cursor-oriented access on top of the underlying buffer.
//
//  Two kinds of handle
//  -------------------
//      DataHandle.create(api_name)              auto-recycled
//      DataHandle.createPermanent(api_name)     permanent
//
//  Auto-recycled handles are added to the library's idle pool, scanned
//  every 5 seconds, and freed after 10 minutes of idle time. Permanent
//  handles are never auto-reclaimed and are released synchronously by
//  `deinit`.
//
//  Ownership
//  ---------
//      owning    - created by `create` / `createPermanent`.
//                  `deinit` calls `LF_FreeData`.
//      borrowing - created by `fromRaw(raw, false)`. `deinit` is a
//                  no-op; the native layer owns the resource and
//                  releases it when the enclosing callback returns.
//
//  Type of the `raw` field
//  -----------------------
//  `sys.DataHnd` is already `?*anyopaque`, i.e. an optional pointer.
//  The field is therefore declared as `sys.DataHnd`, NOT as
//  `?sys.DataHnd`.
// =============================================================================
const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;

/// RAII wrapper around a native LingoFuse data handle.
pub const DataHandle = struct {
    const Self = @This();

    /// The native handle. `null` once an owning handle has been released.
    raw: sys.DataHnd,

    /// True when `deinit` should call `LF_FreeData`.
    owned: bool,

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// Create an AUTO-RECYCLED data handle bound to `api_name`.
    pub fn create(api_name: [:0]const u8) Error!Self {
        const hnd = sys.createData(api_name.ptr);
        if (hnd == null) return Error.LibraryLoadFailed;
        return .{ .raw = hnd, .owned = true };
    }

    /// Create a PERMANENT data handle bound to `api_name`.
    ///
    /// "Permanent" means "not automatically reclaimed", NOT "never
    /// released". The caller is responsible for calling `deinit`.
    pub fn createPermanent(api_name: [:0]const u8) Error!Self {
        const hnd = sys.createDataPermanent(api_name.ptr);
        if (hnd == null) return Error.LibraryLoadFailed;
        return .{ .raw = hnd, .owned = true };
    }

    /// Wrap an existing raw handle.
    ///
    /// `owned = true`  - `deinit` calls `LF_FreeData`.
    /// `owned = false` - `deinit` is a no-op.
    pub fn fromRaw(hnd: sys.DataHnd, owned: bool) Self {
        return .{ .raw = hnd, .owned = owned };
    }

    // -------------------------------------------------------------------------
    // Lifetime
    // -------------------------------------------------------------------------

    /// Release the handle when ownership applies. Idempotent.
    pub fn deinit(self: *Self) void {
        if (!self.owned) return;
        if (self.raw) |h| sys.freeData(h);
        self.raw = null;
    }

    /// True while the handle is non-null.
    pub fn isValid(self: Self) bool {
        return self.raw != null;
    }

    /// True when this instance owns the native handle.
    pub fn isOwning(self: Self) bool {
        return self.owned;
    }

    // -------------------------------------------------------------------------
    // Cursor and size
    // -------------------------------------------------------------------------

    /// Current read/write cursor, in bytes.
    pub fn position(self: Self) Error!i64 {
        const h = self.raw orelse return Error.NullHandle;
        return sys.getPos(h);
    }

    /// Set the read/write cursor.
    pub fn setPosition(self: *Self, pos: i64) Error!void {
        if (pos < 0) return Error.InvalidArgument;
        const h = self.raw orelse return Error.NullHandle;
        sys.setPos(h, pos);
    }

    /// Total buffer size in bytes.
    pub fn size(self: Self) Error!i64 {
        const h = self.raw orelse return Error.NullHandle;
        return sys.getSize(h);
    }

    /// Resize the buffer.
    pub fn setSize(self: *Self, size_: i64) Error!void {
        if (size_ < 0) return Error.InvalidArgument;
        const h = self.raw orelse return Error.NullHandle;
        sys.setSize(h, size_);
    }

    // -------------------------------------------------------------------------
    // Byte I/O
    // -------------------------------------------------------------------------

    /// Append `data` at the current cursor. The buffer grows as needed.
    pub fn writeBytes(self: *Self, data: []const u8) Error!void {
        if (data.len == 0) return;
        const h = self.raw orelse return Error.NullHandle;
        const written = sys.writeBuffer(h, data.ptr, @intCast(data.len));
        if (written != @as(i64, @intCast(data.len))) return Error.WriteFailed;
    }

    /// Read up to `buf.len` bytes. Returns the number actually read.
    pub fn readBytes(self: *Self, buf: []u8) Error!usize {
        if (buf.len == 0) return 0;
        const h = self.raw orelse return Error.NullHandle;
        const got = sys.readBuffer(h, buf.ptr, @intCast(buf.len));
        if (got < 0) return Error.ReadFailed;
        return @intCast(got);
    }

    /// Read every remaining byte into a freshly-allocated slice. The
    /// caller owns the slice and must free it with `alloc.free`.
    pub fn readAllBytes(self: *Self, alloc: std.mem.Allocator) Error![]u8 {
        const pos = try self.position();
        const total = try self.size();
        if (pos >= total) return alloc.alloc(u8, 0) catch Error.OutOfMemory;
        const remaining: usize = @intCast(total - pos);
        const buf = alloc.alloc(u8, remaining) catch return Error.OutOfMemory;
        errdefer alloc.free(buf);
        const got = try self.readBytes(buf);
        if (got != remaining) return Error.ReadFailed;
        return buf;
    }

    // -------------------------------------------------------------------------
    // Low-level string write helper
    // -------------------------------------------------------------------------

    /// Write `value` as UTF-8 bytes followed by a single NUL byte.
    /// An empty `value` writes exactly one byte (the NUL).
    pub fn writeString(self: *Self, value: []const u8) Error!void {
        try self.writeBytes(value);
        try self.writeBytes(&[_]u8{0});
    }
};
