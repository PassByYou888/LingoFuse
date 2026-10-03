// =============================================================================
//  build.zig - Build script for the LingoFuse Zig binding.
// -----------------------------------------------------------------------------
//  Targets
//  -------
//      zig build                       - default; builds all smoke executables
//                                        and all cross-process demos.
//      zig build smoke                 - runs the ABI smoke test.
//      zig build io-smoke              - runs the unified I/O smoke test.
//      zig build json-smoke            - runs the lf_json C ABI smoke test.
//      zig build network-events-smoke  - runs the network events smoke test.
//      zig build status-smoke          - runs the status queue smoke test.
//      zig build test                  - runs the Zig-native unit test suite.
//      zig build cross-service         - builds the cross demo coordinator.
//      zig build cross-node            - builds the cross demo worker node.
//      zig build cross-call            - builds the cross demo load client.
//
//  Cross-process demos are build-only steps: the user launches the three
//  executables manually in separate terminals, in the order
//  cross-service -> cross-node -> cross-call.
//
//  Filesystem requirements
//  -----------------------
//      zig/c/LingoFuse.h   - the LingoFuse C ABI header.
//      zig/c/LingoFuse.c   - the LingoFuse C ABI dynamic loader.
//      zig/c/lf_json.h     - the lf_json C ABI header.
//      zig/c/lf_json.cpp   - the lf_json C ABI implementation.
//      zig/c/json.hpp      - nlohmann/json single-file distribution.
//
//  Runtime requirement
//  -------------------
//      The platform-specific LingoFuse shared library must be
//      discoverable from the produced executable.
//
//  Zig version
//  -----------
//  Written against Zig 0.17.0.
// =============================================================================
const std = @import("std");

/// Build a module that depends on the binding and has the C and C++
/// sources compiled in.
///
/// Top-level function rather than a nested one because Zig nested
/// functions do NOT capture variables from the enclosing scope.
fn makeConsumer(
    b: *std.Build,
    lingofuse_mod: *std.Build.Module,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("lingofuse", lingofuse_mod);
    m.addIncludePath(b.path("c"));
    m.addCSourceFile(.{
        .file = b.path("c/LingoFuse.c"),
        .flags = &.{},
    });
    m.addCSourceFile(.{
        .file = b.path("c/lf_json.cpp"),
        .flags = &.{"-std=c++17"},
    });
    m.link_libc = true;
    m.link_libcpp = true;
    return m;
}

/// Register one smoke executable together with its run step.
fn addSmokeStep(
    b: *std.Build,
    lingofuse_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
    root_path: []const u8,
    step_name: []const u8,
    step_description: []const u8,
) *std.Build.Step.Compile {
    const mod = makeConsumer(b, lingofuse_mod, root_path, target, optimize);
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    const step = b.step(step_name, step_description);
    step.dependOn(&run.step);

    return exe;
}

/// Register one demo executable whose step only BUILDS it, without
/// running it. Used for the cross-process demos, which require the user
/// to launch several processes by hand in separate terminals.
fn addBuildOnlyStep(
    b: *std.Build,
    lingofuse_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
    root_path: []const u8,
    step_name: []const u8,
    step_description: []const u8,
) *std.Build.Step.Compile {
    const mod = makeConsumer(b, lingofuse_mod, root_path, target, optimize);
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = mod,
    });
    b.installArtifact(exe);

    const step = b.step(step_name, step_description);
    step.dependOn(&exe.step);

    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // The binding module.
    // -------------------------------------------------------------------------
    const lingofuse_mod = b.createModule(.{
        .root_source_file = b.path("src/lingofuse.zig"),
        .target = target,
        .optimize = optimize,
    });
    lingofuse_mod.addIncludePath(b.path("c"));
    lingofuse_mod.addCSourceFile(.{
        .file = b.path("c/LingoFuse.c"),
        .flags = &.{},
    });
    lingofuse_mod.addCSourceFile(.{
        .file = b.path("c/lf_json.cpp"),
        .flags = &.{"-std=c++17"},
    });
    lingofuse_mod.link_libc = true;
    lingofuse_mod.link_libcpp = true;

    // -------------------------------------------------------------------------
    // Smoke executables (run steps).
    // -------------------------------------------------------------------------
    const smoke_exe = addSmokeStep(
        b,
        lingofuse_mod,
        target,
        optimize,
        "abi_smoke",
        "examples/abi_smoke.zig",
        "smoke",
        "Run the ABI smoke test as a program",
    );

    const io_smoke_exe = addSmokeStep(
        b,
        lingofuse_mod,
        target,
        optimize,
        "io_smoke",
        "examples/io_smoke.zig",
        "io-smoke",
        "Run the unified I/O smoke test as a program",
    );

    const json_smoke_exe = addSmokeStep(
        b,
        lingofuse_mod,
        target,
        optimize,
        "json_smoke",
        "examples/json_smoke.zig",
        "json-smoke",
        "Run the lf_json C ABI smoke test as a program",
    );

    const events_smoke_exe = addSmokeStep(
        b,
        lingofuse_mod,
        target,
        optimize,
        "network_events_smoke",
        "examples/network_events_smoke.zig",
        "network-events-smoke",
        "Run the network events smoke test as a program",
    );

    const status_smoke_exe = addSmokeStep(
        b,
        lingofuse_mod,
        target,
        optimize,
        "status_smoke",
        "examples/status_smoke.zig",
        "status-smoke",
        "Run the status queue smoke test as a program",
    );

    // -------------------------------------------------------------------------
    // Cross-process demos (build-only steps).
    // -------------------------------------------------------------------------
    const cross_service_exe = addBuildOnlyStep(
        b,
        lingofuse_mod,
        target,
        optimize,
        "cross_service",
        "examples/cross_service.zig",
        "cross-service",
        "Build the cross demo coordinator (run it manually)",
    );

    const cross_node_exe = addBuildOnlyStep(
        b,
        lingofuse_mod,
        target,
        optimize,
        "cross_node",
        "examples/cross_node.zig",
        "cross-node",
        "Build the cross demo worker node (run it manually)",
    );

    const cross_call_exe = addBuildOnlyStep(
        b,
        lingofuse_mod,
        target,
        optimize,
        "cross_call",
        "examples/cross_call.zig",
        "cross-call",
        "Build the cross demo load client (run it manually)",
    );

    // -------------------------------------------------------------------------
    // Unit tests.
    // -------------------------------------------------------------------------
    const test_mod = makeConsumer(
        b,
        lingofuse_mod,
        "tests/test_abi.zig",
        target,
        optimize,
    );
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the Zig unit test suite");
    test_step.dependOn(&run_tests.step);

    // -------------------------------------------------------------------------
    // Default step: build every smoke executable and every demo.
    // -------------------------------------------------------------------------
    b.default_step.dependOn(&smoke_exe.step);
    b.default_step.dependOn(&io_smoke_exe.step);
    b.default_step.dependOn(&json_smoke_exe.step);
    b.default_step.dependOn(&events_smoke_exe.step);
    b.default_step.dependOn(&status_smoke_exe.step);
    b.default_step.dependOn(&cross_service_exe.step);
    b.default_step.dependOn(&cross_node_exe.step);
    b.default_step.dependOn(&cross_call_exe.step);
}
