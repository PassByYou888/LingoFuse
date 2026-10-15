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
//
//  P2P identity side data
//  ----------------------
//  The framework injects two identity fields into every inbound
//  request payload on the SENDER side, before transmission:
//
//      FromUID       - the sender's 32-byte session UID
//      FromP2PName   - the sender's P2P group name (UTF-8)
//
//  These are "side data": they are metadata the sender wrote into the
//  payload header, not properties of the handle itself. A receiver can
//  therefore read them only on the INPUT handle that the framework
//  delivered to a registered callback.
//
//  `p2pUid` and `p2pName` expose these fields:
//
//      Handle                                         Valid?
//      --------------------------------------------   ------
//      input argument of a Call / Notify callback     yes
//      input handle of a local call / notify          yes
//      output argument of a Call callback             no
//      caller-created handle (create / permanent)     no
//
//  The two accessors never fail for the invalid cases: the native
//  library logs a warning and returns a pointer to a zero-filled UID /
//  an empty string, which these wrappers translate to `Uid.NULL` and
//  the empty string respectively.
//
//  Pointer lifetime
//  ----------------
//  `LF_Get_P2P_UID` returns a pointer allocated by the native library
//  and scheduled for automatic release about 5 seconds after the call.
//  `LF_Get_P2P_Name` returns a C string pointer with the same release
//  rule. Both accessors in this module COPY IMMEDIATELY and never
//  expose the raw pointer to the caller, so the returned values are
//  safe to retain indefinitely.
// =============================================================================
const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const Uid = @import("uid.zig").Uid;
const util = @import("util.zig");

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
    ///
    /// This is a LOW-LEVEL helper used to build payloads that will be
    /// read back with a NUL-aware reader. It is the equivalent of the
    /// C++ `DataHandle::write(const std::string&)`.
    ///
    /// For reading the value back with the fault-tolerant rules, use
    /// `io.readString` instead of `readBytes`.
    pub fn writeString(self: *Self, value: []const u8) Error!void {
        try self.writeBytes(value);
        try self.writeBytes(&[_]u8{0});
    }

    // -------------------------------------------------------------------------
    // P2P identity side data
    // -------------------------------------------------------------------------

    /// Return the sender's 32-byte session UID.
    ///
    /// # Contract
    ///
    /// This reads SIDE DATA injected by the sender's transport layer
    /// into the payload header; it is not a property of the handle
    /// itself. It is therefore meaningful only on the INPUT handle of
    /// a registered callback (or the input of a local call).
    ///
    /// On any other handle -- an output handle, or a caller-created
    /// handle -- the native library logs a warning and returns a
    /// pointer to a zero-filled UID. This wrapper translates that to
    /// `Uid.NULL`.
    ///
    /// # Pointer lifetime
    ///
    /// The native pointer is valid for about 5 seconds; this method
    /// COPIES THE 32 BYTES IMMEDIATELY, so the returned value is safe
    /// to retain indefinitely.
    ///
    /// # Errors
    ///
    /// - `Error.NullHandle` if this handle is not valid.
    pub fn p2pUid(self: Self) Error!Uid {
        const h = self.raw orelse return Error.NullHandle;
        const ptr = sys.getP2PUid(h) orelse return Uid.NULL;
        return Uid.fromPtr(ptr);
    }

    /// Return the sender's P2P group name.
    ///
    /// # Contract
    ///
    /// Same side-data rule as `p2pUid`: this is meaningful only on the
    /// INPUT handle of a registered callback. On any other handle the
    /// native library logs a warning and returns an empty string.
    ///
    /// # Pointer lifetime
    ///
    /// The native pointer is valid for about 5 seconds; this method
    /// COPIES THE STRING IMMEDIATELY into an allocator-owned slice,
    /// so the returned value is safe to retain indefinitely.
    ///
    /// # Ownership
    ///
    /// The caller owns the returned slice and must free it with
    /// `alloc.free`.
    ///
    /// # Errors
    ///
    /// - `Error.NullHandle` if this handle is not valid.
    /// - `Error.OutOfMemory` if the copy allocation fails.
    pub fn p2pName(
        self: Self,
        alloc: std.mem.Allocator,
    ) Error![:0]u8 {
        const h = self.raw orelse return Error.NullHandle;
        const ptr = sys.getP2PName(h);
        return util.copyCstrOrEmpty(alloc, ptr);
    }
};
