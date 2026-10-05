# runtests.jl - Standard Julia test entry point for the LingoFuse
# binding.
#
# Run with:
#
#     cd julia
#     julia --threads=2 test/runtests.jl
#
# Every acceptance test is a standalone script that manages its own
# consumer lifecycle and shutdown. Running all of them in a single
# Julia process would require resetting the C shim, the consumer
# task, and the LingoFuse framework between each test; a subprocess
# gives every test a fresh process state, which is the environment
# the tests are written for.
#
# The top-level testset reports one entry per acceptance script.
# Failure output from a subprocess goes to the parent's stdout and
# stderr, so a failure can be diagnosed directly from the run log.
#
# As of Step 5, every test script lives in this same directory. The
# path passed to run_script() is therefore relative to @__DIR__.

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

@testset "LingoFuse Julia binding" begin
    @testset "io (Step 3)" begin
        @test run_script(joinpath(_HERE, "test_io.jl"))
    end

    @testset "RAII (Step 2)" begin
        @test run_script(joinpath(_HERE, "test_raii.jl"))
    end

    @testset "network (Step 2)" begin
        @test run_script(joinpath(_HERE, "test_network.jl"))
    end

    @testset "smoke (Step 2/3)" begin
        @test run_script(joinpath(_HERE, "smoke.jl"))
    end

    @testset "status (Step 3)" begin
        @test run_script(joinpath(_HERE, "test_status.jl"))
    end
end