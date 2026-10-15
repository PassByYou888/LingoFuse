# runtests.jl - Standard Julia test entry point for the LingoFuse
# binding.
#
# This file is a thin dispatcher. It runs two groups of acceptance
# tests, each in its own subprocess:
#
#     runtests_mock.jl    mock-shim group (no network required)
#     runtests_real.jl    real-shim group (uses the real library)
#
# Each group subprocess is started with --threads=2, and it in turn
# spawns one subprocess per acceptance script. Failure output from a
# grandchild goes to the parent's stdout and stderr, so a failure can
# be diagnosed directly from the run log.
#
# Why two groups
# --------------
# The Julia binding ships two shim variants:
#
#   lf_shim_mock.dll   The mock. Registration goes into a private
#                      table; the tests drive callbacks through the
#                      mock_lf_trigger_* drivers.
#
#   lf_shim_real.dll   The real shim. Registration and dispatch
#                      share one in-process table with the real
#                      LingoFuse library, so register_call! and
#                      LF_Call see the same APIs.
#
# A single Julia process cannot load both. src/shim.jl resolves the
# shim once at package-load time (see its file header for the search
# order), and every subsequent shim_* call goes to that one variant.
# The two groups therefore must run in separate processes.
#
# --threads=2 is REQUIRED: the callback consumer must not run on the
# main Julia thread. See src/callback.jl, start_callback_consumer,
# for the full reason.
#
# Run:
#
#     cd julia
#     julia --threads=2 test/runtests.jl

using Test

const _HERE = @__DIR__

"""
    run_group(script::String) -> Bool

Run one group script as a subprocess with `--threads=2` and return
`true` when it exits with status 0.
"""
function run_group(script::String)::Bool
    isfile(script) || error("Group script not found: $(script)")
    jl  = Base.julia_cmd()
    cmd = `$jl --threads=2 $script`
    proc = run(pipeline(cmd; stdout = stdout, stderr = stderr); wait = false)
    wait(proc)
    return proc.exitcode == 0
end

@testset "LingoFuse Julia binding" begin
    @testset "mock shim group" begin
        @test run_group(joinpath(_HERE, "runtests_mock.jl"))
    end

    @testset "real shim group" begin
        @test run_group(joinpath(_HERE, "runtests_real.jl"))
    end
end