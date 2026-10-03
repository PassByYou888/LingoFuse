// =============================================================================
//  cross_node.zig - Worker node that registers the "add" and "inv_seri" APIs.
// -----------------------------------------------------------------------------
//  Registers two Call APIs under the application name "demo":
//
//      add       (int32 a, int32 b)                    -> int32
//      inv_seri  (uint8, uint16, uint32, uint64,
//                 string(NUL), float)                   -> reversed types
//
//  The wire format is byte-for-byte identical to the C++ / C# / Rust /
//  Go / JavaScript / Pascal / Python counterparts, so a Zig node is
//  directly interoperable with a caller written in any of those
//  languages, and vice versa.
//
//  Running:
//      zig build cross-node
//      zig-out\bin\cross_node.exe
// =============================================================================
const std = @import("std");
const lf = @import("lingofuse");

extern "c" fn getchar() c_int;
extern "c" fn exit(code: c_int) noreturn;

const ENDPOINT = "ipc:cross";
const APP_NAME = "demo";

// -----------------------------------------------------------------------------
// Callbacks
// -----------------------------------------------------------------------------
//
// Callbacks run on background worker threads. Inside them:
//   - Do not block.
//   - Do not call framework.call / app.localCall (deadlock).
//   - Do not panic. Zig panics do not unwind cleanly across the
//     `callconv(.c)` boundary; the trampolines in `app_handle.zig`
//     catch Zig errors via the `Error!void` return type, but a panic
//     would still be a bug.

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
    std.debug.print("[Node] add({}, {}) = {}\n", .{ a, b, sum });

    std.mem.writeInt(i32, &buf, sum, .little);
    try output.writeBytes(&buf);
}

fn invSeriHandler(
    ctx: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    _ = ctx;
    const alloc = std.heap.page_allocator;

    // Read the request fields in order:
    //   uint8, uint16 LE, uint32 LE, uint64 LE, string(NUL), float32 LE
    var b1: [1]u8 = undefined;
    _ = try input.readBytes(&b1);
    const vb: u8 = b1[0];

    var b2: [2]u8 = undefined;
    _ = try input.readBytes(&b2);
    const vw = std.mem.readInt(u16, &b2, .little);

    var b4: [4]u8 = undefined;
    _ = try input.readBytes(&b4);
    const vc = std.mem.readInt(u32, &b4, .little);

    var b8: [8]u8 = undefined;
    _ = try input.readBytes(&b8);
    const vu64 = std.mem.readInt(u64, &b8, .little);

    const vs = try lf.io.readString(input, alloc);
    defer alloc.free(vs);

    var bf: [4]u8 = undefined;
    _ = try input.readBytes(&bf);
    const fbits = std.mem.readInt(u32, &bf, .little);
    const vf: f32 = @bitCast(fbits);

    std.debug.print(
        "[Node] inv_seri received: [{}, {}, {}, {}, \"{s}\", {d}]\n",
        .{ vb, vw, vc, vu64, vs, vf },
    );

    // Reply in the reverse order: float32, string, uint64, uint32,
    // uint16, uint8.
    var out_f: [4]u8 = undefined;
    std.mem.writeInt(u32, &out_f, @bitCast(vf), .little);
    try output.writeBytes(&out_f);

    try lf.io.writeString(output, vs);

    var out_u64: [8]u8 = undefined;
    std.mem.writeInt(u64, &out_u64, vu64, .little);
    try output.writeBytes(&out_u64);

    var out_c: [4]u8 = undefined;
    std.mem.writeInt(u32, &out_c, vc, .little);
    try output.writeBytes(&out_c);

    var out_w: [2]u8 = undefined;
    std.mem.writeInt(u16, &out_w, vw, .little);
    try output.writeBytes(&out_w);

    var out_b: [1]u8 = undefined;
    out_b[0] = vb;
    try output.writeBytes(&out_b);

    std.debug.print(
        "[Node] inv_seri replied:  [{d}, \"{s}\", {}, {}, {}, {}]\n",
        .{ vf, vs, vu64, vc, vw, vb },
    );
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

pub fn main() void {
    std.debug.print("=== Cross Node (Worker) ===\n", .{});

    lf.framework.init() catch |err| {
        std.debug.print("[FATAL] framework.init: {}\n", .{err});
        exit(1);
    };
    defer lf.framework.deinit();

    // The App lives in its own block so that `defer app.deinit()` runs
    // at exactly the right point in the LF-CLEAN-001 sequence:
    //
    //     exitMainThread  ->  app.deinit  ->  shutdown  ->  deinit
    //
    // The outer `defer framework.deinit()` runs after the block.
    {
        var app = lf.AppHandle.create(APP_NAME, "Zig worker node") catch |err| {
            std.debug.print("[FATAL] AppHandle.create: {}\n", .{err});
            exit(1);
        };
        defer app.deinit();

        app.registerCall("add", "add(int a, int b) -> int", null, addHandler) catch |err| {
            std.debug.print("[FATAL] registerCall(add): {}\n", .{err});
            exit(1);
        };
        app.registerCall(
            "inv_seri",
            "inv_seri() -> reversed typed sequence",
            null,
            invSeriHandler,
        ) catch |err| {
            std.debug.print("[FATAL] registerCall(inv_seri): {}\n", .{err});
            exit(1);
        };

        std.debug.print(
            "[Node] Registered APIs 'add' and 'inv_seri' under application '{s}'.\n",
            .{APP_NAME},
        );

        // Deployment mode: do not block prepareDone waiting for the
        // coordinator; the node connects automatically once the
        // endpoint becomes reachable.
        lf.framework.setOption("Wait_Ready", "False");
        lf.framework.setOption("Overlap_Connection", "True");

        lf.framework.resetPrepare();

        const cli_tag = lf.framework.prepareClient(ENDPOINT, &app) catch |err| {
            std.debug.print("[FATAL] prepareClient: {}\n", .{err});
            exit(1);
        };
        std.debug.print(
            "[Node] Prepared client tunnel to {s} (tag={}).\n",
            .{ ENDPOINT, cli_tag },
        );

        const done = lf.framework.prepareDone();
        if (!done and !lf.framework.checkMainThread()) {
            std.debug.print("[FATAL] prepareDone failed\n", .{});
            exit(1);
        }

        std.debug.print("[Node] Online. Press Enter to exit...\n", .{});
        _ = getchar();

        std.debug.print("[Node] Shutting down...\n", .{});
        lf.framework.exitMainThread();
        // defer: app.deinit() runs here, before the framework shutdown
        // below, exactly matching the LF-CLEAN-001 order.
    }

    lf.framework.shutdown();
}
