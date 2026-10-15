# LingoFuse.jl - Main module entry point for the Julia binding.
#
# Usage from a script:
#
#     push!(LOAD_PATH, "path/to/LingoFuse/julia/src")
#     using LingoFuse
#
# Usage from the REPL after activating the project:
#
#     julia> using LingoFuse
#
# Usage inside a Julia module that already has the path configured:
#
#     import LingoFuse
#
# The module is organised into layers, each in its own file:
#
#   trace.jl        Runtime trace (LINGOFUSE_TRACE=1)
#   error.jl        Exception hierarchy
#   uid.jl          UID type (32-byte tuple) and helpers
#   loader.jl       Library discovery and PATH preparation
#   abi.jl          Raw ccall bindings for the 59 LF_* exports
#   shim.jl         Julia bindings for the C callback shim
#   callback.jl     Consumer task and event dispatch
#   data_handle.jl  RAII wrapper for TDataHnd + identity accessors
#   binio.jl        Little-endian binary I/O helpers
#   app.jl          RAII wrapper for TAppHnd
#   async.jl        Future type for asynchronous operations
#   target.jl       Three addressing modes + sync / async / do-block
#   p2p.jl          Process-wide P2P API registration
#   network.jl      Network preparation and lifecycle
#   io.jl           Unified JSON / string / byte I/O
#   status.jl       Network event listeners and status queue helpers
#
# The include order is significant:
#
#   - error.jl must precede loader.jl (which can throw
#     LingoFuseLoadError) and every other file that throws a
#     LingoFuse error subtype.
#
#   - abi.jl must precede every wrapper that calls LF_* functions
#     (data_handle.jl, app.jl, network.jl, target.jl, ...).
#
#   - shim.jl must precede callback.jl (which calls shim_* functions).
#
#   - callback.jl must precede p2p.jl and target.jl (which allocate
#     handler tokens from callback.jl's registry).
#
#   - app.jl must precede p2p.jl (which reuses _warmup_handler).
#
#   - async.jl must precede target.jl (which constructs Futures).
#
# Every file uses flat top-level definitions and export statements;
# there is no nested module structure. This mirrors the C, C++, C#,
# Python, and JavaScript bindings, all of which expose a single flat
# surface for the same ABI.

module LingoFuse

include("trace.jl")
include("error.jl")
include("uid.jl")
include("loader.jl")
include("abi.jl")
include("shim.jl")
include("callback.jl")
include("data_handle.jl")
include("binio.jl")
include("app.jl")
include("async.jl")
include("target.jl")
include("p2p.jl")
include("network.jl")
include("io.jl")
include("status.jl")

"""
    VERSION

Version of the Julia binding. This is independent of the native
LingoFuse runtime version, which is reported by the library itself
as `'3.x'` and is available in the startup banner.
"""
const VERSION = v"0.2.0"

function __init__()
    # Report the resolved library paths once at package load. This is
    # a diagnostic convenience; production code should not depend on
    # it. Use `library_path()` and `shim_path()` for programmatic
    # access.
    try
        @debug "LingoFuse Julia binding $(VERSION) initialised" library = library_path() shim = shim_path()
    catch
        # Loading diagnostics must never prevent the package from
        # loading.
    end
    return nothing
end

end # module LingoFuse