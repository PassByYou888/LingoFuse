// =============================================================================
//  cross_service.zig - Coordinator process for the IPC endpoint "ipc:cross".
// -----------------------------------------------------------------------------
//  This program:
//    1. Loads the LingoFuse runtime (RAII, reference-counted by the loader).
//    2. Creates the IPC service endpoint "ipc:cross".
//    3. Prepares a self-connected client tunnel so the mesh has at least
//       one physical tunnel at the coordinator.
//    4. Starts the framework.
//    5. Waits for Enter.
//    6. Shuts down in the LF-CLEAN-001 order.
//
//  The program registers no APIs. Its only role is to be the discovery
//  anchor that worker nodes and callers connect to.
//
//  Running (three terminals, in this order):
//      1. cross_service
//      2. cross_node
//      3. cross_call
//
//      zig build cross-service
//      zig-out\bin\cross_service.exe
// =============================================================================
const std = @import("std");
const lf = @import("lingofuse");

extern "c" fn getchar() c_int;
extern "c" fn exit(code: c_int) noreturn;

const ENDPOINT = "ipc:cross";

pub fn main() void {
    std.debug.print("=== Cross Service (Coordinator) ===\n", .{});

    lf.framework.init() catch |err| {
        std.debug.print("[FATAL] framework.init: {}\n", .{err});
        exit(1);
    };
    defer lf.framework.deinit();

    // Deployment options: identical to the other-language demos.
    lf.framework.setOption("Wait_Connection_ReadyOk", "True");
    lf.framework.setOption("Overlap_Connection", "True");
    lf.framework.setOption("Wait_Connection_Timeout", "10000");

    lf.framework.resetPrepare();

    const serv_tag = lf.framework.prepareService(ENDPOINT, ENDPOINT) catch |err| {
        std.debug.print("[FATAL] prepareService: {}\n", .{err});
        exit(1);
    };
    std.debug.print("[Service] Prepared service endpoint {s} (tag={}).\n", .{
        ENDPOINT, serv_tag,
    });

    const cli_tag = lf.framework.prepareClient(ENDPOINT, null) catch |err| {
        std.debug.print("[FATAL] prepareClient: {}\n", .{err});
        exit(1);
    };
    std.debug.print("[Service] Prepared client tunnel (tag={}).\n", .{cli_tag});

    const done = lf.framework.prepareDone();
    if (!done and !lf.framework.checkMainThread()) {
        std.debug.print(
            "[FATAL] prepareDone returned false and the main thread is not running\n",
            .{},
        );
        exit(1);
    }

    std.debug.print(
        "[Service] IPC service '{s}' is running. Press Enter to exit...\n",
        .{ENDPOINT},
    );
    _ = getchar();

    std.debug.print("[Service] Shutting down...\n", .{});
    lf.framework.exitMainThread();
    lf.framework.shutdown();
}
