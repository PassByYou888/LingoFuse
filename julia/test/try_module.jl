# try_module.jl - Smoke test for `using LingoFuse`.
#
# Verifies that the package loads cleanly and reports its resolved
# library paths and the number of exported symbols.
#
# Run from the julia directory:
#
#     julia --threads=2 test/try_module.jl
#
# Or from the test directory:
#
#     julia --threads=2 try_module.jl

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))
using LingoFuse

println("VERSION    : ", LingoFuse.VERSION)
println("library    : ", LingoFuse.library_path())
println("shim       : ", LingoFuse.shim_path())
println("shim_real  : ", LingoFuse.shim_is_real())
println("exports    : ", length(names(LingoFuse)))