const std = @import("std");
const sys = @import("sys.zig");
const Error = @import("error.zig").Error;
const Uid = @import("uid.zig").Uid;
const util = @import("util.zig");

pub const DataHandle = struct {
    const Self = @This();

    raw: sys.DataHnd,
    owned: bool,

    pub fn create(api_name: [:0]const u8) Error!Self {
        const hnd = sys.createData(api_name.ptr);
        if (hnd == null) return Error.LibraryLoadFailed;
        return .{ .raw = hnd, .owned = true };
    }

    pub fn createPermanent(api_name: [:0]const u8) Error!Self {
        const hnd = sys.createDataPermanent(api_name.ptr);
        if (hnd == null) return Error.LibraryLoadFailed;
        return .{ .raw = hnd, .owned = true };
    }

    pub fn fromRaw(hnd: sys.DataHnd, owned: bool) Self {
        return .{ .raw = hnd, .owned = owned };
    }

    pub fn deinit(self: *Self) void {
        if (!self.owned) return;
        if (self.raw) |h| sys.freeData(h);
        self.raw = null;
    }

    pub fn isValid(self: Self) bool {
        return self.raw != null;
    }

    pub fn isOwning(self: Self) bool {
        return self.owned;
    }

    pub fn position(self: Self) Error!i64 {
        const h = self.raw orelse return Error.NullHandle;
        return sys.getPos(h);
    }

    pub fn setPosition(self: *Self, pos: i64) Error!void {
        if (pos < 0) return Error.InvalidArgument;
        const h = self.raw orelse return Error.NullHandle;
        sys.setPos(h, pos);
    }

    pub fn size(self: Self) Error!i64 {
        const h = self.raw orelse return Error.NullHandle;
        return sys.getSize(h);
    }

    pub fn setSize(self: *Self, size_: i64) Error!void {
        if (size_ < 0) return Error.InvalidArgument;
        const h = self.raw orelse return Error.NullHandle;
        sys.setSize(h, size_);
    }

    pub fn writeBytes(self: *Self, data: []const u8) Error!void {
        if (data.len == 0) return;
        const h = self.raw orelse return Error.NullHandle;
        const written = sys.writeBuffer(h, data.ptr, @intCast(data.len));
        if (written != @as(i64, @intCast(data.len))) return Error.WriteFailed;
    }

    pub fn readBytes(self: *Self, buf: []u8) Error!usize {
        if (buf.len == 0) return 0;
        const h = self.raw orelse return Error.NullHandle;
        const got = sys.readBuffer(h, buf.ptr, @intCast(buf.len));
        if (got < 0) return Error.ReadFailed;
        return @intCast(got);
    }

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

    pub fn writeString(self: *Self, value: []const u8) Error!void {
        try self.writeBytes(value);
        try self.writeBytes(&[_]u8{0});
    }

    pub fn write(self: *Self, value: anytype) Error!void {
        const T = @TypeOf(value);
        const tag = @typeInfo(T);

        switch (tag) {
            .int, .float, .bool => {
                const h = self.raw orelse return Error.NullHandle;
                var v = value;
                const n = @sizeOf(T);
                const p: [*]const u8 = @ptrCast(&v);
                const written = sys.writeBuffer(h, p, @intCast(n));
                if (written != @as(i64, @intCast(n))) return Error.WriteFailed;
            },
            .comptime_int => {
                if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
                    return self.write(@as(i32, @intCast(value)));
                } else {
                    return self.write(@as(i64, value));
                }
            },
            .comptime_float => {
                return self.write(@as(f64, value));
            },
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    return self.writeString(value);
                }
                @compileError("DataHandle.write: unsupported pointer type " ++ @typeName(T));
            },
            else => @compileError("DataHandle.write: unsupported type " ++ @typeName(T)),
        }
    }

    pub fn read(self: *Self, out: anytype) Error!bool {
        const T = @TypeOf(out.*);
        const tag = @typeInfo(T);

        switch (tag) {
            .int, .float, .bool => {
                const h = self.raw orelse return Error.NullHandle;
                const n = @sizeOf(T);
                const p: [*]u8 = @ptrCast(out);
                const got = sys.readBuffer(h, p, @intCast(n));
                return got == @as(i64, @intCast(n));
            },
            else => @compileError("DataHandle.read: unsupported type " ++ @typeName(T)),
        }
    }

    pub fn p2pUid(self: Self) Error!Uid {
        const h = self.raw orelse return Error.NullHandle;
        const ptr = sys.getP2PUid(h) orelse return Uid.NULL;
        return Uid.fromPtr(ptr);
    }

    pub fn p2pName(self: Self, alloc: std.mem.Allocator) Error![:0]u8 {
        const h = self.raw orelse return Error.NullHandle;
        const ptr = sys.getP2PName(h);
        return util.copyCstrOrEmpty(alloc, ptr);
    }
};
