# loader.jl - Locate the LingoFuse shared library and prepare the
# process environment for it. See the original header comment in
# git history for the full design rationale.
#
# This revision adds trace output at each resolution step.

const _LINGOFUSE_LIBRARY_NAME = begin
    if Sys.iswindows()
        Sys.WORD_SIZE == 64 ? "LingoFuse64.dll" : "LingoFuse32.dll"
    elseif Sys.isapple()
        "liblingofuse.dylib"
    else
        "liblingofuse.so"
    end
end

const _PATH_SEPARATOR = Sys.iswindows() ? ';' : ':'

function _candidate_library_paths()::Vector{String}
    candidates = String[]

    override = get(ENV, "LINGOFUSE_LIBRARY", "")
    if !isempty(override)
        push!(candidates, override)
    end

    home = get(ENV, "LINGOFUSE_HOME", "")
    if !isempty(home)
        push!(candidates, joinpath(home, "Binary", _LINGOFUSE_LIBRARY_NAME))
        push!(candidates, joinpath(home, _LINGOFUSE_LIBRARY_NAME))
    end

    here      = @__DIR__
    pkg_root  = normpath(joinpath(here, ".."))
    repo_root = normpath(joinpath(pkg_root, ".."))
    push!(candidates,
          joinpath(repo_root, "Binary", _LINGOFUSE_LIBRARY_NAME))

    if !isempty(Base.PROGRAM_FILE)
        push!(candidates,
              joinpath(dirname(Base.PROGRAM_FILE),
                       _LINGOFUSE_LIBRARY_NAME))
    end

    push!(candidates, _LINGOFUSE_LIBRARY_NAME)

    return candidates
end

function _find_library()::Union{String,Nothing}
    for path in _candidate_library_paths()
        if isabspath(path)
            if isfile(path)
                trace("loader: found candidate " * path)
                return path
            else
                trace("loader: candidate does not exist " * path)
            end
        else
            trace("loader: falling back to bare name " * path)
            return path
        end
    end
    return nothing
end

function _prepend_path(dir::String)
    if isempty(dir); return; end
    current = get(ENV, "PATH", "")
    entries = split(current, _PATH_SEPARATOR)
    if dir in entries; return; end
    ENV["PATH"] = isempty(current) ? dir :
                                    string(dir, _PATH_SEPARATOR, current)
    trace("loader: PATH prepended with " * dir)
    return
end

function _prepare_environment(lib_path::String)
    if isabspath(lib_path)
        _prepend_path(dirname(lib_path))
    end
    ENV["LINGOFUSE_LIBRARY"] = lib_path
    trace("loader: ENV[LINGOFUSE_LIBRARY] = " * lib_path)
    return
end

const LINGOFUSE_LIBRARY_PATH = begin
    p = _find_library()
    if p === nothing
        candidates = _candidate_library_paths()
        listed     = join(candidates, "\n  ")
        throw(LingoFuseLoadError(
            _LINGOFUSE_LIBRARY_NAME,
            "LingoFuse shared library not found. Searched:\n  " *
            listed *
            "\nSet LINGOFUSE_LIBRARY to the full path of " *
            _LINGOFUSE_LIBRARY_NAME *
            ", or place it under <repo>/Binary/."
        ))
    end
    _prepare_environment(p)
    p
end

const LINGOFUSE_LIBRARY_DIR = isabspath(LINGOFUSE_LIBRARY_PATH) ?
    dirname(LINGOFUSE_LIBRARY_PATH) : ""

library_path()::String = LINGOFUSE_LIBRARY_PATH
library_dir()::String  = LINGOFUSE_LIBRARY_DIR