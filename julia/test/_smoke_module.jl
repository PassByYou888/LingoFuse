# _smoke_module.jl - Verify that `using LingoFuse` loads cleanly.
#
# Run from the julia directory:
#
#     julia --threads=2 test/_smoke_module.jl
#
# Prints the resolved library paths, the shim path, whether the shim
# is the real or mock variant, and the number of exported symbols.
# Exits with status 0 on success and 1 on failure.
#
# This script exists because the equivalent one-liner is difficult to
# write correctly in PowerShell (the embedded double quotes for
# string literals must be escaped differently than in bash).

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using LingoFuse

println("VERSION        : ", LingoFuse.VERSION)
println("library        : ", LingoFuse.library_path())
println("library dir    : ", LingoFuse.library_dir())
println("shim           : ", LingoFuse.shim_path())
println("shim real      : ", LingoFuse.shim_is_real())

# Sanity assertions: if any of these fail, the module did not load
# correctly and the exit code will reflect it.
exit_code = 0
function check(cond::Bool, msg::String)
    if cond
        println("[PASS] ", msg)
    else
        println("[FAIL] ", msg)
        global exit_code = 1
    end
end

check(!isempty(LingoFuse.library_path()), "library_path is non-empty")
check(!isempty(LingoFuse.shim_path()),    "shim_path is non-empty")

# Spot-check that the public API is reachable.
check(isdefined(LingoFuse, :DataHandle), "DataHandle is defined")
check(isdefined(LingoFuse, :App),        "App is defined")
check(isdefined(LingoFuse, :Future),     "Future is defined")
check(isdefined(LingoFuse, :app_target), "app_target is defined")
check(isdefined(LingoFuse, :uid_target), "uid_target is defined")
check(isdefined(LingoFuse, :p2pname_target), "p2pname_target is defined")
check(isdefined(LingoFuse, :register_p2p_call!), "register_p2p_call! is defined")

# Count exported symbols (informational).
exported = names(LingoFuse)
println("export count   : ", length(exported))

exit(exit_code)