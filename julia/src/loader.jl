# loader.jl - Locate the LingoFuse shared library through the
# system's dynamic-loading search path.
#
# Design
# ------
# The Julia binding deliberately does NOT bake in any fixed absolute
# path to the LingoFuse runtime. Instead, the runtime is resolved
# through the same mechanism the operating system's dynamic loader
# uses, so that a system-wide installation is discovered without any
# additional configuration:
#
#     Windows        PATH
#     Linux / BSD    LD_LIBRARY_PATH, then PATH as a fallback
#     macOS          DYLD_LIBRARY_PATH, DYLD_FALLBACK_LIBRARY_PATH,
#                    then PATH as a fallback
#
# A single environment-variable override (LINGOFUSE_LIBRARY) takes
# precedence over the search path. It is intended for diagnostic and
# CI scenarios, and for deployments where the runtime lives outside
# the normal search locations.
#
# If no directory on the search path contains the runtime, the bare
# library name is returned and the platform loader performs its own
# default search. This preserves compatibility with a system-wide
# installation whose directory is registered with the OS (for
# example, installed via ldconfig on Linux, or placed in
# C:\Windows\System32 on Windows) but is not present on the search
# path.
#
# All diagnostics are written to stderr in English.

# Platform-specific file name of the runtime library.
const _LINGOFUSE_LIBRARY_NAME = begin
    if Sys.iswindows()
        Sys.WORD_SIZE == 64 ? "LingoFuse64.dll" : "LingoFuse32.dll"
    elseif Sys.isapple()
        "liblingofuse.dylib"
    else
        "liblingofuse.so"
    end
end

# Character used to separate entries in a PATH-like environment
# variable.
const _PATH_SEPARATOR = Sys.iswindows() ? ';' : ':'

"""
    _library_search_env_vars() -> Vector{String}

Return the names of the environment variables that conventionally
hold runtime-library search directories on the current platform,
in the order they should be consulted.
"""
function _library_search_env_vars()::Vector{String}
    if Sys.iswindows()
        return ["PATH"]
    elseif Sys.isapple()
        return [
            "DYLD_LIBRARY_PATH",
            "DYLD_FALLBACK_LIBRARY_PATH",
            "PATH",
        ]
    else
        return ["LD_LIBRARY_PATH", "PATH"]
    end
end

"""
    _split_search_path(value::AbstractString) -> Vector{String}

Split a PATH-like value into individual directory entries, dropping
empty entries.
"""
function _split_search_path(value::AbstractString)::Vector{String}
    isempty(value) && return String[]
    entries = split(value, _PATH_SEPARATOR)
    return [String(e) for e in entries if !isempty(e)]
end

"""
    _library_search_directories() -> Vector{String}

Return every directory that should be searched, in priority order,
by consulting each of the platform's search-path environment
variables in turn. Duplicate directories are preserved; each one
costs a single stat call.
"""
function _library_search_directories()::Vector{String}
    dirs = String[]
    for var in _library_search_env_vars()
        value = get(ENV, var, "")
        isempty(value) && continue
        append!(dirs, _split_search_path(value))
    end
    return dirs
end

"""
    _find_library_on_search_path(libname::AbstractString)
        -> Union{String,Nothing}

Walk the platform's library search directories and return the full
path of the first entry that contains `libname`. Returns `nothing`
when no entry matches.
"""
function _find_library_on_search_path(
    libname::AbstractString,
)::Union{String,Nothing}
    for dir in _library_search_directories()
        candidate = joinpath(dir, libname)
        if isfile(candidate)
            return candidate
        end
    end
    return nothing
end

"""
    _resolve_library_path() -> String

Resolve the runtime library path using the following priority:

  1. The `LINGOFUSE_LIBRARY` environment variable, when set. This
     must name an existing file; a stale path is treated as a
     configuration error rather than silently ignored.
  2. The platform's library search path (PATH on Windows;
     LD_LIBRARY_PATH / DYLD_LIBRARY_PATH on POSIX; PATH as a
     fallback on all platforms).
  3. The bare library name, in which case the OS loader performs its
     own default search.

This function is called exactly once, at package load.
"""
function _resolve_library_path()::String
    override = get(ENV, "LINGOFUSE_LIBRARY", "")
    if !isempty(override)
        if isfile(override)
            return override
        end
        throw(LingoFuseLoadError(
            override,
            "LINGOFUSE_LIBRARY is set but does not name an existing " *
            "file. Unset the variable to fall back to the system " *
            "library search path, or correct the path."
        ))
    end

    found = _find_library_on_search_path(_LINGOFUSE_LIBRARY_NAME)
    if found !== nothing
        return found
    end

    # Nothing on the search path. Return the bare name so the OS
    # loader can try its own default locations. On POSIX this is the
    # only way to reach a library that is registered with ldconfig
    # but not present in LD_LIBRARY_PATH.
    return _LINGOFUSE_LIBRARY_NAME
end

const LINGOFUSE_LIBRARY_PATH = _resolve_library_path()

# If the runtime was resolved to a concrete file, make its directory
# available to the OS loader for the benefit of the C shim.
#
# The C shim calls LoadLibraryA / dlopen with the bare library name
# (or with the value of LINGOFUSE_LIBRARY). On Windows that call only
# succeeds if the directory is on the DLL search path, so an override
# that names a file outside the search path must be complemented by a
# PATH addition. On POSIX the loader already consults the
# directories listed in LD_LIBRARY_PATH, so a path that was found on
# that variable needs no adjustment; adding it is still harmless.
function _prepare_environment(lib_path::String)
    if isabspath(lib_path)
        dir = dirname(lib_path)
        current = get(ENV, "PATH", "")
        entries = split(current, _PATH_SEPARATOR)
        if !(dir in entries)
            ENV["PATH"] = isempty(current) ? dir :
                          string(dir, _PATH_SEPARATOR, current)
            trace("loader: PATH prepended with " * dir)
        end
    end
    ENV["LINGOFUSE_LIBRARY"] = lib_path
    trace("loader: ENV[LINGOFUSE_LIBRARY] = " * lib_path)
    return
end

_prepare_environment(LINGOFUSE_LIBRARY_PATH)

const LINGOFUSE_LIBRARY_DIR = isabspath(LINGOFUSE_LIBRARY_PATH) ?
    dirname(LINGOFUSE_LIBRARY_PATH) : ""

"""
    library_path() -> String

Return the resolved path of the LingoFuse runtime library.

When a matching file was found on the search path (or via
`LINGOFUSE_LIBRARY`), the returned value is a full path. When no
search directory matched, the value is the bare library name and
the OS loader will perform its own default search.
"""
library_path()::String = LINGOFUSE_LIBRARY_PATH

"""
    library_dir() -> String

Return the directory containing the runtime library, or the empty
string when the library was not resolved to a full path.
"""
library_dir()::String = LINGOFUSE_LIBRARY_DIR