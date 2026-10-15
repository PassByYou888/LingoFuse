# runtests_mock.jl - Acceptance tests that require the mock shim.
#
# Run through runtests.jl, or directly:
#
#     julia --threads=2 test/runtests_mock.jl
#
# Each script in this group exercises the C shim through the mock's
# trigger drivers (mock_lf_trigger_*). It does NOT touch the real
# network. The pin to lf_shim_mock.dll is set by the test file itself
# (see the file header of test_callback.jl), so this runner does not
# need to set LINGOFUSE_SHIM.
#
# See runtests.jl for why the mock and real groups run in separate
# processes.

using Test

const _HERE = @__DIR__

"""
    run_script(script::String; threads::Int = 2) -> Bool

Run one acceptance script as a subprocess with `--threads=N` and
return `true` when it exits with status 0.
"""
function run_script(script::String; threads::Int = 2)::Bool
    isfile(script) || error("Test script not found: $(script)")
    jl  = Base.julia_cmd()
    cmd = `$jl --threads=$threads $script`
    proc = run(pipeline(cmd; stdout = stdout, stderr = stderr); wait = false)
    wait(proc)
    return proc.exitcode == 0
end

@testset "mock shim group" begin
    @testset "UID type" begin
        @test run_script(joinpath(_HERE, "test_uid.jl"))
    end

    @testset "ABI bindings" begin
        @test run_script(joinpath(_HERE, "test_abi.jl"))
    end

    @testset "Shim bindings" begin
        @test run_script(joinpath(_HERE, "test_shim_bind.jl"))
    end

    @testset "Callback dispatch" begin
        @test run_script(joinpath(_HERE, "test_callback.jl"))
    end

    @testset "Future type" begin
        @test run_script(joinpath(_HERE, "test_async_unit.jl"))
    end

    @testset "Targets + async API" begin
        @test run_script(joinpath(_HERE, "test_target.jl"))
    end

    @testset "P2P registration" begin
        @test run_script(joinpath(_HERE, "test_p2p.jl"))
    end
end