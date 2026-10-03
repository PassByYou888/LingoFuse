// =============================================================================
//  cross_call.zig - Concurrent load-test client for "ipc:cross".
// -----------------------------------------------------------------------------
//  Connects as a pure consumer (no application exposed) and spawns a
//  pool of worker threads. Each thread repeatedly invokes one of two
//  remote APIs on the "demo" application at random:
//
//      add       (int32 a, int32 b)                    -> int32
//      inv_seri  (uint8, uint16, uint32, uint64,
//                 string(NUL), float)                   -> reversed types
//
//  The test runs for a fixed duration, then prints a summary and shuts
//  down cleanly.
//
//  Timing and sleeping
//  -------------------
//  The Zig 0.17 standard library removed several time-related APIs
//  that earlier versions exposed (`std.time.Timer`,
//  `std.time.nanoTimestamp`, `std.Thread.sleep`). To avoid depending
//  on any of them, this program uses the C standard library's `clock()`
//  for elapsed-time measurement and the Windows API's `Sleep(ms)` for
//  delays. Both are declared directly with `extern "c"`.
//
//  `Sleep` is a Windows-only symbol. This project currently targets
//  Windows x64; porting to POSIX would require replacing the two
//  `Sleep` call sites with `nanosleep` or equivalent.
//
//  Log sampling
//  ------------
//  With 32 threads at a 1 ms pause, the process issues many thousands
//  of calls per second. Printing every call would make the log I/O
//  itself the bottleneck. Each worker therefore logs one iteration out
//  of every LOG_EVERY_NTH; the aggregate counters remain exact.
//
//  Running (three terminals):
//      1. cross_service
//      2. cross_node
//      3. cross_call
//
//      zig build cross-call
//      zig-out\bin\cross_call.exe
// =============================================================================
const std = @import("std");
const lf = @import("lingofuse");

// -----------------------------------------------------------------------------
// C standard library and Windows API, for portable timing and input.
// -----------------------------------------------------------------------------

extern "c" fn getchar() c_int;
extern "c" fn exit(code: c_int) noreturn;
extern "c" fn clock() c_long;

/// Windows API: suspend the calling thread for `dwMilliseconds`.
///
/// This replaces `std.Thread.sleep`, which was removed in Zig 0.17.
/// The symbol is provided by `kernel32` and is linked by default.
extern "c" fn Sleep(dwMilliseconds: u32) void;

/// `CLOCKS_PER_SEC` for the target platform.
///
/// On Windows this is 1000 (millisecond resolution); on POSIX it is
/// 1000000. This project currently targets Windows, so 1000 is the
/// correct value. Update this constant if a POSIX target is added.
const CLOCKS_PER_SEC: c_long = 1000;

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------

const TARGET_APP = "demo";
const ENDPOINT = "ipc:cross";

const WORKER_THREADS: usize = 32;
const TEST_SECONDS: u64 = 10;
const CALL_TIMEOUT_MS: u64 = 1000;
const PAUSE_MS: u64 = 1;
const LOG_EVERY_NTH: u64 = 5000;

const NUMBER_MIN: i32 = 1;
const NUMBER_MAX: i32 = 1000;

// -----------------------------------------------------------------------------
// Statistics
// -----------------------------------------------------------------------------

const Stats = struct {
    total: std.atomic.Value(u64),
    success: std.atomic.Value(u64),
    failed: std.atomic.Value(u64),
    add_calls: std.atomic.Value(u64),
    inv_seri_calls: std.atomic.Value(u64),

    fn init() Stats {
        return .{
            .total = std.atomic.Value(u64).init(0),
            .success = std.atomic.Value(u64).init(0),
            .failed = std.atomic.Value(u64).init(0),
            .add_calls = std.atomic.Value(u64).init(0),
            .inv_seri_calls = std.atomic.Value(u64).init(0),
        };
    }
};

// -----------------------------------------------------------------------------
// Small xorshift64 PRNG.
//
// Inlined to avoid pulling in `std.Random` for what is essentially
// "pick 0 or 1, then pick a random small integer". Each worker owns a
// private state, so no synchronisation is needed.
// -----------------------------------------------------------------------------

fn xorshift64(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

fn randomInRange(state: *u64, min: i32, max: i32) i32 {
    const span: u64 = @intCast(max - min + 1);
    const r = xorshift64(state) % span;
    return min + @as(i32, @intCast(r));
}

// -----------------------------------------------------------------------------
// Remote call wrappers
// -----------------------------------------------------------------------------
//
// Both helpers take ownership of the response handle and release it
// before returning. The `|*r|` capture pattern is used so that the
// `defer` operates on the original `?DataHandle` payload instead of a
// copy; a plain `|r|` capture would produce a temporary whose `deinit`
// leaks the original slot.

/// Invoke the remote "add" API.
///
/// Returns the sum on success, `null` on timeout or failure.
fn remoteAdd(a: i32, b: i32) ?i32 {
    var param = lf.DataHandle.create("add") catch return null;
    defer param.deinit();

    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, a, .little);
    param.writeBytes(&buf) catch return null;
    std.mem.writeInt(i32, &buf, b, .little);
    param.writeBytes(&buf) catch return null;

    var maybe = lf.framework.callOptional(
        TARGET_APP,
        &param,
        CALL_TIMEOUT_MS,
    ) catch return null;

    defer {
        if (maybe) |*r| r.deinit();
    }

    if (maybe) |*r| {
        var out: [4]u8 = undefined;
        const got = r.readBytes(&out) catch return null;
        if (got != 4) return null;
        return std.mem.readInt(i32, &out, .little);
    }
    return null;
}

/// Invoke the remote "inv_seri" API.
///
/// Returns an allocator-owned human-readable description of the reply,
/// or `null` on failure. The caller owns the returned slice and must
/// free it with `alloc.free`.
fn remoteInvSeri(alloc: std.mem.Allocator) ?[]u8 {
    var param = lf.DataHandle.create("inv_seri") catch return null;
    defer param.deinit();

    // Write the request fields.
    param.writeBytes(&[_]u8{200}) catch return null;

    var w_b: [2]u8 = undefined;
    std.mem.writeInt(u16, &w_b, 0x10, .little);
    param.writeBytes(&w_b) catch return null;

    var c_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &c_b, 0x2F, .little);
    param.writeBytes(&c_b) catch return null;

    var u64_b: [8]u8 = undefined;
    std.mem.writeInt(u64, &u64_b, 0x3F, .little);
    param.writeBytes(&u64_b) catch return null;

    lf.io.writeString(&param, "hello world") catch return null;

    var f_b: [4]u8 = undefined;
    std.mem.writeInt(u32, &f_b, @as(u32, @bitCast(@as(f32, 3.14))), .little);
    param.writeBytes(&f_b) catch return null;

    var maybe = lf.framework.callOptional(
        TARGET_APP,
        &param,
        CALL_TIMEOUT_MS,
    ) catch return null;

    defer {
        if (maybe) |*r| r.deinit();
    }

    if (maybe) |*r| {
        // Read the reply fields in the reverse order the node wrote
        // them: float32, string, uint64, uint32, uint16, uint8.
        var rf_b: [4]u8 = undefined;
        var got = r.readBytes(&rf_b) catch return null;
        if (got != 4) return null;
        const rf: f32 = @bitCast(std.mem.readInt(u32, &rf_b, .little));

        const rs = lf.io.readString(r, alloc) catch return null;
        defer alloc.free(rs);

        var ru64_b: [8]u8 = undefined;
        got = r.readBytes(&ru64_b) catch return null;
        if (got != 8) return null;
        const ru64 = std.mem.readInt(u64, &ru64_b, .little);

        var rc_b: [4]u8 = undefined;
        got = r.readBytes(&rc_b) catch return null;
        if (got != 4) return null;
        const rc = std.mem.readInt(u32, &rc_b, .little);

        var rw_b: [2]u8 = undefined;
        got = r.readBytes(&rw_b) catch return null;
        if (got != 2) return null;
        const rw = std.mem.readInt(u16, &rw_b, .little);

        var rb_b: [1]u8 = undefined;
        got = r.readBytes(&rb_b) catch return null;
        if (got != 1) return null;
        const rb = rb_b[0];

        // Format the reply. `bufPrint` avoids depending on
        // `std.fmt.allocPrint`, whose signature has drifted across
        // Zig releases.
        var line_buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(
            &line_buf,
            "reply: [{}, {}, {}, {}, \"{s}\", {d}]  original: [200, 16, 47, 63, \"hello world\", 3.14]",
            .{ rb, rw, rc, ru64, rs, rf },
        ) catch return null;

        const result = alloc.alloc(u8, line.len) catch return null;
        @memcpy(result, line);
        return result;
    }
    return null;
}

// -----------------------------------------------------------------------------
// Worker
// -----------------------------------------------------------------------------

const WorkerCtx = struct {
    index: usize,
    stop: *std.atomic.Value(bool),
    stats: *Stats,
};

fn worker(ctx: WorkerCtx) void {
    const alloc = std.heap.page_allocator;

    // Seed the PRNG with the thread index and the current clock tick
    // so that different workers diverge immediately.
    //
    // `clock()` returns `c_long`, which is 32-bit signed on Windows.
    // The value is always non-negative, but the type system does not
    // know that, so we widen to `u64` before masking. This also
    // documents the intent: only the low 32 bits are used as entropy.
    const clock_value: u64 = @as(u64, @intCast(clock()));
    const seed_ts: u64 = clock_value & 0xFFFFFFFF;
    var seed: u64 = (@as(u64, ctx.index) *% 0x9E3779B97F4A7C15) ^ seed_ts;

    var iter: u64 = 0;
    while (!ctx.stop.load(.acquire)) {
        iter += 1;
        const do_log = (iter % LOG_EVERY_NTH) == 0;

        if ((xorshift64(&seed) & 1) == 0) {
            // ---- add ----
            const a = randomInRange(&seed, NUMBER_MIN, NUMBER_MAX);
            const b = randomInRange(&seed, NUMBER_MIN, NUMBER_MAX);
            const result = remoteAdd(a, b);

            _ = ctx.stats.total.fetchAdd(1, .monotonic);
            _ = ctx.stats.add_calls.fetchAdd(1, .monotonic);

            if (result) |c| {
                _ = ctx.stats.success.fetchAdd(1, .monotonic);
                if (do_log) {
                    std.debug.print(
                        "[Call {}] add({}, {}) = {}\n",
                        .{ ctx.index, a, b, c },
                    );
                }
            } else {
                _ = ctx.stats.failed.fetchAdd(1, .monotonic);
                if (do_log) {
                    std.debug.print(
                        "[Call {}] add({}, {}) timed out or failed\n",
                        .{ ctx.index, a, b },
                    );
                }
            }
        } else {
            // ---- inv_seri ----
            const result = remoteInvSeri(alloc);

            _ = ctx.stats.total.fetchAdd(1, .monotonic);
            _ = ctx.stats.inv_seri_calls.fetchAdd(1, .monotonic);

            if (result) |text| {
                defer alloc.free(text);
                _ = ctx.stats.success.fetchAdd(1, .monotonic);
                if (do_log) {
                    std.debug.print(
                        "[Call {}] {s}\n",
                        .{ ctx.index, text },
                    );
                }
            } else {
                _ = ctx.stats.failed.fetchAdd(1, .monotonic);
                if (do_log) {
                    std.debug.print(
                        "[Call {}] inv_seri timed out or failed\n",
                        .{ctx.index},
                    );
                }
            }
        }

        if (PAUSE_MS > 0) {
            Sleep(@intCast(PAUSE_MS));
        }
    }
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------

pub fn main() void {
    std.debug.print("=== Cross Call (Client) ===\n", .{});

    lf.framework.init() catch |err| {
        std.debug.print("[FATAL] framework.init: {}\n", .{err});
        exit(1);
    };
    defer lf.framework.deinit();

    lf.framework.setOption("Wait_Connection_ReadyOk", "True");
    lf.framework.setOption("Overlap_Connection", "True");
    lf.framework.setOption("Wait_Connection_Timeout", "10000");

    lf.framework.resetPrepare();

    const cli_tag = lf.framework.prepareClient(ENDPOINT, null) catch |err| {
        std.debug.print("[FATAL] prepareClient: {}\n", .{err});
        exit(1);
    };
    std.debug.print(
        "[Call] Prepared client tunnel to {s} (tag={}).\n",
        .{ ENDPOINT, cli_tag },
    );

    const done = lf.framework.prepareDone();
    if (!done and !lf.framework.checkMainThread()) {
        std.debug.print("[FATAL] prepareDone failed\n", .{});
        exit(1);
    }

    std.debug.print(
        "[Call] Connected to {s}. Starting {}-second load test with {} threads...\n",
        .{ ENDPOINT, TEST_SECONDS, WORKER_THREADS },
    );

    var stats = Stats.init();
    var stop = std.atomic.Value(bool).init(false);

    // Launch workers.
    const threads = std.heap.page_allocator.alloc(std.Thread, WORKER_THREADS) catch {
        std.debug.print("[FATAL] alloc threads failed\n", .{});
        exit(1);
    };
    defer std.heap.page_allocator.free(threads);

    const start_clock: c_long = clock();

    var launched: usize = 0;
    while (launched < WORKER_THREADS) : (launched += 1) {
        threads[launched] = std.Thread.spawn(.{}, worker, .{
            WorkerCtx{
                .index = launched,
                .stop = &stop,
                .stats = &stats,
            },
        }) catch {
            std.debug.print(
                "[FATAL] Thread.spawn failed at index {}\n",
                .{launched},
            );
            exit(1);
        };
    }

    // Run for the configured duration.
    Sleep(@intCast(TEST_SECONDS * 1000));
    stop.store(true, .release);

    // Join all workers.
    for (threads) |t| t.join();

    const end_clock: c_long = clock();
    const elapsed_clocks: c_long = end_clock - start_clock;
    const elapsed_s: f64 =
        @as(f64, @floatFromInt(elapsed_clocks)) /
        @as(f64, @floatFromInt(CLOCKS_PER_SEC));

    const total = stats.total.load(.monotonic);
    const success = stats.success.load(.monotonic);
    const failed = stats.failed.load(.monotonic);
    const add_calls = stats.add_calls.load(.monotonic);
    const inv_seri_calls = stats.inv_seri_calls.load(.monotonic);

    const success_rate: f64 = if (total > 0)
        (100.0 * @as(f64, @floatFromInt(success)) /
            @as(f64, @floatFromInt(total)))
    else
        0.0;
    const throughput: f64 = if (elapsed_s > 0.0)
        (@as(f64, @floatFromInt(total)) / elapsed_s)
    else
        0.0;
    const success_throughput: f64 = if (elapsed_s > 0.0)
        (@as(f64, @floatFromInt(success)) / elapsed_s)
    else
        0.0;

    std.debug.print("\n", .{});
    std.debug.print("[Call] Load test summary\n", .{});
    std.debug.print("         duration          : {d:.3} s\n", .{elapsed_s});
    std.debug.print("         total calls       : {}\n", .{total});
    std.debug.print(
        "         success           : {} ({d:.2} %)\n",
        .{ success, success_rate },
    );
    std.debug.print("         failed            : {}\n", .{failed});
    std.debug.print("         add calls         : {}\n", .{add_calls});
    std.debug.print("         inv_seri calls    : {}\n", .{inv_seri_calls});
    std.debug.print(
        "         throughput        : {d:.2} calls/s\n",
        .{throughput},
    );
    std.debug.print(
        "         success throughput: {d:.2} calls/s\n",
        .{success_throughput},
    );

    std.debug.print("[Call] Press Enter to exit...\n", .{});
    _ = getchar();

    lf.framework.exitMainThread();
    lf.framework.shutdown();
}
