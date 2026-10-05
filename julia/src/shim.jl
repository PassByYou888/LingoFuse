# shim.jl - Julia bindings for the C callback shim.
#
# See the original header comment in git history for the full design
# rationale. This revision:
#
#   1. Replaces the hard-coded relative search with a two-stage
#      resolver: (a) the platform library search path, then
#      (b) the in-tree build directories relative to this source
#      file. The shim is a build artefact of the Julia package, so
#      the in-tree locations ship with the package and the entire
#      julia/ directory can be relocated without any configuration
#      change.
#
#   2. Keeps the three payload accessors introduced by the
#      payload-snapshot revision of the C shim:
#          shim_event_input_data
#          shim_event_input_len
#          shim_set_output
#      These are the ONLY way the consumer may interact with the
#      event payload; they never touch a native data handle.
#
#   3. Keeps the convenience helper shim_read_input that returns a
#      Julia-owned Vector{UInt8} copy of the input snapshot in one
#      call.

const LF_SHIM_EVENT_CALL               = Cint(0)
const LF_SHIM_EVENT_NOTIFY             = Cint(1)
const LF_SHIM_EVENT_NETWORK_CONNECT    = Cint(2)
const LF_SHIM_EVENT_NETWORK_DISCONNECT = Cint(3)

const _SHIM_REAL_NAME = if Sys.iswindows()
    "lf_shim_real.dll"
elseif Sys.isapple()
    "liblf_shim_real.dylib"
else
    "liblf_shim_real.so"
end

const _SHIM_MOCK_NAME = if Sys.iswindows()
    "lf_shim_mock.dll"
elseif Sys.isapple()
    "liblf_shim_mock.dylib"
else
    "liblf_shim_mock.so"
end

# Resolve the C shim library path.
#
# Search order:
#
#   1. LINGOFUSE_SHIM override, when set. Must name an existing
#      file.
#   2. Every directory on the platform's library search path (see
#      loader.jl for the exact list per platform). This allows the
#      shim to be installed system-wide alongside the runtime.
#   3. The in-tree build directories, relative to this source file:
#      <julia>/c_ext/real/ and <julia>/c_ext/. These ship with the
#      package, so the entire julia/ directory can be relocated
#      without any configuration change.
#   4. Alongside the current program, if any.
#
# When no directory on the search path contains the shim, the empty
# string is returned and shim_available() reports false. The caller
# (start_callback_consumer) will then raise a diagnostic error that
# names the missing file and the ways to provide it.
function _candidate_shim_paths()::Vector{String}
    candidates = String[]

    override = get(ENV, "LINGOFUSE_SHIM", "")
    if !isempty(override)
        push!(candidates, override)
    end

    for dir in _library_search_directories()
        push!(candidates, joinpath(dir, _SHIM_REAL_NAME))
    end

    here      = @__DIR__
    julia_dir = normpath(joinpath(here, ".."))
    c_ext_dir = joinpath(julia_dir, "c_ext")

    push!(candidates, joinpath(c_ext_dir, "real", _SHIM_REAL_NAME))
    push!(candidates, joinpath(c_ext_dir, _SHIM_REAL_NAME))

    if !isempty(Base.PROGRAM_FILE)
        push!(candidates,
              joinpath(dirname(Base.PROGRAM_FILE), _SHIM_REAL_NAME))
    end

    return candidates
end

# Walk the candidate list and return the first entry that resolves to
# an existing file. The bare library name is not a candidate here:
# the shim is a build artefact of this package and its absence is a
# deployment error that should be surfaced rather than papered over.
function _find_shim_library()::String
    for p in _candidate_shim_paths()
        if isabspath(p)
            if isfile(p)
                trace("shim: found " * p)
                return p
            end
            trace("shim: not present " * p)
        end
    end
    return ""
end

const LINGOFUSE_SHIM_PATH = _find_shim_library()

shim_available()::Bool = !isempty(LINGOFUSE_SHIM_PATH)

function shim_is_real()::Bool
    shim_available() || return false
    return occursin("real", basename(LINGOFUSE_SHIM_PATH))
end

shim_path()::String = LINGOFUSE_SHIM_PATH

function _require_shim()
    if !shim_available()
        throw(LingoFuseLoadError(
            _SHIM_REAL_NAME,
            "C callback shim not found. It must be built once with " *
            "c_ext/real/build.ps1 (Windows) or c_ext/real/build.sh " *
            "(POSIX). Alternatively, place the shared library on " *
            "the system library search path, or set LINGOFUSE_SHIM " *
            "to its full path."
        ))
    end
    return
end

# ================================================================== #
# Lifecycle                                                           #
# ================================================================== #

function shim_init()::Bool
    _require_shim()
    trace("shim: shim_init")
    ok = ccall((:lf_shim_init, LINGOFUSE_SHIM_PATH), Cint, ()) == 1
    trace("shim: shim_init $(ok ? "OK" : "FAILED")")
    return ok
end

function shim_shutdown()::Nothing
    shim_available() || return nothing
    trace("shim: shim_shutdown")
    ccall((:lf_shim_shutdown, LINGOFUSE_SHIM_PATH), Cvoid, ())
    return nothing
end

# ================================================================== #
# Registration                                                        #
# ================================================================== #

function shim_register_call(app_hnd::Ptr{Cvoid},
                            name::AbstractString,
                            desc::AbstractString,
                            user_id::Int64)::Bool
    _require_shim()
    trace("shim: register_call name=$(name) uid=$(user_id)")
    ret = ccall((:lf_shim_register_call, LINGOFUSE_SHIM_PATH),
                Cint,
                (Ptr{Cvoid}, Cstring, Cstring, Int64),
                app_hnd, name, desc, user_id)
    trace("shim: register_call name=$(name) ret=$(ret)")
    return ret == 1
end

function shim_register_notify(app_hnd::Ptr{Cvoid},
                              name::AbstractString,
                              desc::AbstractString,
                              user_id::Int64)::Bool
    _require_shim()
    trace("shim: register_notify name=$(name) uid=$(user_id)")
    ret = ccall((:lf_shim_register_notify, LINGOFUSE_SHIM_PATH),
                Cint,
                (Ptr{Cvoid}, Cstring, Cstring, Int64),
                app_hnd, name, desc, user_id)
    trace("shim: register_notify name=$(name) ret=$(ret)")
    return ret == 1
end

function shim_install_network_events(connect_uid::Int64,
                                     disconnect_uid::Int64)::Nothing
    _require_shim()
    trace("shim: install_network_events c=$(connect_uid) d=$(disconnect_uid)")
    ccall((:lf_shim_install_network_events, LINGOFUSE_SHIM_PATH),
          Cvoid, (Int64, Int64), connect_uid, disconnect_uid)
    return nothing
end

function shim_clear_network_events()::Nothing
    shim_available() || return nothing
    trace("shim: clear_network_events")
    ccall((:lf_shim_clear_network_events, LINGOFUSE_SHIM_PATH),
          Cvoid, ())
    return nothing
end

# ================================================================== #
# Consumer side                                                       #
# ================================================================== #

function shim_wait_event(timeout_ms::Integer)::Ptr{Cvoid}
    _require_shim()
    e = ccall((:lf_shim_wait_event, LINGOFUSE_SHIM_PATH),
              Ptr{Cvoid}, (Cint,), Cint(timeout_ms))
    e != C_NULL && trace("shim: wait_event returned an event pointer")
    return e
end

function shim_event_kind(e::Ptr{Cvoid})::Cint
    return ccall((:lf_shim_event_kind, LINGOFUSE_SHIM_PATH),
                 Cint, (Ptr{Cvoid},), e)
end

function shim_event_user_id(e::Ptr{Cvoid})::Int64
    return ccall((:lf_shim_event_user_id, LINGOFUSE_SHIM_PATH),
                 Int64, (Ptr{Cvoid},), e)
end

function shim_event_input(e::Ptr{Cvoid})::Ptr{Cvoid}
    return ccall((:lf_shim_event_input, LINGOFUSE_SHIM_PATH),
                 Ptr{Cvoid}, (Ptr{Cvoid},), e)
end

function shim_event_output(e::Ptr{Cvoid})::Ptr{Cvoid}
    return ccall((:lf_shim_event_output, LINGOFUSE_SHIM_PATH),
                 Ptr{Cvoid}, (Ptr{Cvoid},), e)
end

function shim_event_addr(e::Ptr{Cvoid})::Union{String,Nothing}
    p = ccall((:lf_shim_event_addr, LINGOFUSE_SHIM_PATH),
              Ptr{UInt8}, (Ptr{Cvoid},), e)
    p == C_NULL && return nothing
    return unsafe_string(p)
end

# ================================================================== #
# Event payload accessors                                             #
# ================================================================== #

"""
    shim_event_input_data(e) -> Ptr{UInt8}

Return the snapshot of the input payload, or a null pointer when the
input was empty or absent.

The buffer is owned by the event and is freed by the trampoline after
the consumer signals completion. The consumer must copy the bytes
into Julia-owned storage before that point; the helper
[`shim_read_input`](@ref) does exactly that.

This accessor exists because the consumer MUST NOT read the native
input handle directly: doing so would enter the real LingoFuse
library from a thread other than the one that owns the handle, and
would deadlock on the library's per-handle locks.
"""
function shim_event_input_data(e::Ptr{Cvoid})::Ptr{UInt8}
    return ccall((:lf_shim_event_input_data, LINGOFUSE_SHIM_PATH),
                 Ptr{UInt8}, (Ptr{Cvoid},), e)
end

"""
    shim_event_input_len(e) -> Csize_t

Return the length in bytes of the input snapshot, or zero when the
input was empty or absent.
"""
function shim_event_input_len(e::Ptr{Cvoid})::Csize_t
    return ccall((:lf_shim_event_input_len, LINGOFUSE_SHIM_PATH),
                 Csize_t, (Ptr{Cvoid},), e)
end

"""
    shim_read_input(e) -> Vector{UInt8}

Return a Julia-owned copy of the event's input snapshot. The
underlying native buffer is owned by the shim and is freed by the
trampoline after the consumer signals completion; the returned
vector is independent and safe to retain past that point.

An empty input, a null snapshot, or a zero length all map to an
empty Vector{UInt8}.

The copy is performed with a single unsafe_copyto! into a freshly
allocated Julia array, which avoids the version-dependent signatures
of Base.unsafe_wrap.
"""
function shim_read_input(e::Ptr{Cvoid})::Vector{UInt8}
    p = shim_event_input_data(e)
    n = shim_event_input_len(e)
    (p == C_NULL || n == 0) && return UInt8[]
    out = Vector{UInt8}(undef, Int(n))
    unsafe_copyto!(pointer(out), p, Int(n))
    return out
end

"""
    shim_set_output(e, data) -> Bool

Hand the response bytes to the shim. The data is copied into a heap
buffer owned by the event; the trampoline writes it to the native
output handle after the consumer signals completion.

Calling this more than once replaces the previous payload. An empty
`data` clears any previously set output and marks the response as
empty.

Returns `true` on success.
"""
function shim_set_output(e::Ptr{Cvoid},
                         data::AbstractVector{UInt8})::Bool
    isempty(data) && return true
    ret = GC.@preserve data begin
        ccall((:lf_shim_set_output, LINGOFUSE_SHIM_PATH),
              Cint,
              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
              e, pointer(data), Csize_t(length(data)))
    end
    return ret == 1
end

"""
    shim_complete_event(e) -> Nothing

Signal the blocked trampoline to return. The caller must have
finished all output work (via [`shim_set_output`](@ref)) before
invoking this. The event object is freed by the trampoline after
this call returns; the caller must not touch `e` afterwards.
"""
function shim_complete_event(e::Ptr{Cvoid})::Nothing
    trace("shim: complete_event $(e)")
    ccall((:lf_shim_complete_event, LINGOFUSE_SHIM_PATH),
          Cvoid, (Ptr{Cvoid},), e)
    return nothing
end

# ================================================================== #
# Exports                                                             #
# ================================================================== #

export LF_SHIM_EVENT_CALL,
       LF_SHIM_EVENT_NOTIFY,
       LF_SHIM_EVENT_NETWORK_CONNECT,
       LF_SHIM_EVENT_NETWORK_DISCONNECT,
       LINGOFUSE_SHIM_PATH,
       shim_available, shim_is_real, shim_path,
       shim_init, shim_shutdown,
       shim_register_call, shim_register_notify,
       shim_install_network_events, shim_clear_network_events,
       shim_wait_event,
       shim_event_kind, shim_event_user_id,
       shim_event_input, shim_event_output, shim_event_addr,
       shim_event_input_data, shim_event_input_len,
       shim_read_input, shim_set_output,
       shim_complete_event