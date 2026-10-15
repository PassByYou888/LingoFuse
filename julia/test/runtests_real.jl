# runtests_real.jl - Acceptance tests that require the real shim.
#
# Run through runtests.jl, or directly:
#
#     julia --threads=2 test/runtests_real.jl
#
# Each script in this group exercises the real LingoFuse library
# through the real shim (lf_shim_real.dll). src/shim.jl resolves the
# real shim by default when both variants are present; see its file
# header for the search order.
#
# Scripts that specifically need the real shim (test_restart.jl,
# test_e2e_local.jl) additionally pin it via ENV["LINGOFUSE_SHIM"] in
# their own file header, so the group still works if src/shim.jl's
# search order changes.
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

@testset "real shim group" begin
    @testset "io" begin
        @test run_script(joinpath(_HERE, "test_io.jl"))
    end

    @testset "RAII" begin
        @test run_script(joinpath(_HERE, "test_raii.jl"))
    end

    @testset "network" begin
        @test run_script(joinpath(_HERE, "test_network.jl"))
    end

    @testset "smoke" begin
        @test run_script(joinpath(_HERE, "smoke.jl"))
    end

    @testset "status" begin
        @test run_script(joinpath(_HERE, "test_status.jl"))
    end

    @testset "e2e local" begin
        @test run_script(joinpath(_HERE, "test_e2e_local.jl"))
    end

    @testset "restart" begin
        @test run_script(joinpath(_HERE, "test_restart.jl"))
    end
end