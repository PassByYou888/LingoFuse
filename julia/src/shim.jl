# shim.jl - Julia bindings for the C callback shim.
#
# This revision adds two event accessors:
#   shim_read_from_uid       -- snapshot of the sender's 32-byte UID
#   shim_read_from_p2p_name  -- snapshot of the sender's P2P group name
#
# Both are read from the shim's event snapshot. They are safe to call on
# any event; when the shim is an older build without the corresponding
# C symbol, the functions return a zero UID / empty string instead of
# throwing.

const LF_SHIM_EVENT_CALL               = Cint(0)
const LF_SHIM_EVENT_NOTIFY             = Cint(1)
const LF_SHIM_EVENT_NETWORK_CONNECT    = Cint(2)
const LF_SHIM_EVENT_NETWORK_DISCONNECT = Cint(3)
const LF_SHIM_EVENT_ASYNC_RESULT       = Cint(4)

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

function _candidate_shim_paths()::Vector{String}
    candidates = String[]

    override = get(ENV, "LINGOFUSE_SHIM", "")
    if !isempty(override)
        push!(candidates, override)
    end

    here      = @__DIR__
    julia_dir = normpath(joinpath(here, ".."))
    c_ext_dir = joinpath(julia_dir, "c_ext")

    push!(candidates, joinpath(c_ext_dir, "real", _SHIM_REAL_NAME))
    push!(candidates, joinpath(c_ext_dir, _SHIM_REAL_NAME))
    push!(candidates, joinpath(c_ext_dir, _SHIM_MOCK_NAME))

    for dir in _library_search_directories()
        push!(candidates, joinpath(dir, _SHIM_REAL_NAME))
        push!(candidates, joinpath(dir, _SHIM_MOCK_NAME))
    end

    if !isempty(Base.PROGRAM_FILE)
        push!(candidates,
              joinpath(dirname(Base.PROGRAM_FILE), _SHIM_REAL_NAME))
        push!(candidates,
              joinpath(dirname(Base.PROGRAM_FILE), _SHIM_MOCK_NAME))
    end

    return candidates
end

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

function shim_register_p2p_call(name::AbstractString,
                                desc::AbstractString,
                                user_id::Int64)::Bool
    _require_shim()
    trace("shim: register_p2p_call name=$(name) uid=$(user_id)")
    ret = ccall((:lf_shim_register_p2p_call, LINGOFUSE_SHIM_PATH),
                Cint,
                (Cstring, Cstring, Int64),
                name, desc, user_id)
    trace("shim: register_p2p_call name=$(name) ret=$(ret)")
    return ret == 1
end

function shim_register_p2p_notify(name::AbstractString,
                                  desc::AbstractString,
                                  user_id::Int64)::Bool
    _require_shim()
    trace("shim: register_p2p_notify name=$(name) uid=$(user_id)")
    ret = ccall((:lf_shim_register_p2p_notify, LINGOFUSE_SHIM_PATH),
                Cint,
                (Cstring, Cstring, Int64),
                name, desc, user_id)
    trace("shim: register_p2p_notify name=$(name) ret=$(ret)")
    return ret == 1
end

function shim_unregister_p2p(name::AbstractString)::Bool
    _require_shim()
    trace("shim: unregister_p2p name=$(name)")
    ret = ccall((:lf_shim_unregister_p2p, LINGOFUSE_SHIM_PATH),
                Cint, (Cstring,), name)
    trace("shim: unregister_p2p name=$(name) ret=$(ret)")
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

function shim_async_call(app_name::AbstractString,
                         param_hnd::Ptr{Cvoid},
                         user_token::Int64)::Cint
    _require_shim()
    return ccall((:lf_shim_async_call, LINGOFUSE_SHIM_PATH),
                 Cint,
                 (Cstring, Ptr{Cvoid}, Int64),
                 app_name, param_hnd, user_token)
end

function shim_async_sequenced_call(app_name::AbstractString,
                                   param_hnd::Ptr{Cvoid},
                                   user_token::Int64)::Cint
    _require_shim()
    return ccall((:lf_shim_async_sequenced_call, LINGOFUSE_SHIM_PATH),
                 Cint,
                 (Cstring, Ptr{Cvoid}, Int64),
                 app_name, param_hnd, user_token)
end

function shim_uid_async_call(uid::LFShimUID,
                             param_hnd::Ptr{Cvoid},
                             user_token::Int64)::Cint
    _require_shim()
    uid_ref = Ref(uid)
    return GC.@preserve uid_ref begin
        ccall((:lf_shim_uid_async_call, LINGOFUSE_SHIM_PATH),
              Cint,
              (Ptr{LFShimUID}, Ptr{Cvoid}, Int64),
              uid_ref, param_hnd, user_token)
    end
end

function shim_uid_async_sequenced_call(uid::LFShimUID,
                                       param_hnd::Ptr{Cvoid},
                                       user_token::Int64)::Cint
    _require_shim()
    uid_ref = Ref(uid)
    return GC.@preserve uid_ref begin
        ccall((:lf_shim_uid_async_sequenced_call, LINGOFUSE_SHIM_PATH),
              Cint,
              (Ptr{LFShimUID}, Ptr{Cvoid}, Int64),
              uid_ref, param_hnd, user_token)
    end
end

function shim_p2pname_async_call(group_name::AbstractString,
                                 param_hnd::Ptr{Cvoid},
                                 user_token::Int64)::Cint
    _require_shim()
    return ccall((:lf_shim_p2pname_async_call, LINGOFUSE_SHIM_PATH),
                 Cint,
                 (Cstring, Ptr{Cvoid}, Int64),
                 group_name, param_hnd, user_token)
end

function shim_p2pname_async_sequenced_call(group_name::AbstractString,
                                           param_hnd::Ptr{Cvoid},
                                           user_token::Int64)::Cint
    _require_shim()
    return ccall((:lf_shim_p2pname_async_sequenced_call,
                  LINGOFUSE_SHIM_PATH),
                 Cint,
                 (Cstring, Ptr{Cvoid}, Int64),
                 group_name, param_hnd, user_token)
end

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

function shim_event_input_data(e::Ptr{Cvoid})::Ptr{UInt8}
    return ccall((:lf_shim_event_input_data, LINGOFUSE_SHIM_PATH),
                 Ptr{UInt8}, (Ptr{Cvoid},), e)
end

function shim_event_input_len(e::Ptr{Cvoid})::Csize_t
    return ccall((:lf_shim_event_input_len, LINGOFUSE_SHIM_PATH),
                 Csize_t, (Ptr{Cvoid},), e)
end

function shim_event_result_data(e::Ptr{Cvoid})::Ptr{UInt8}
    return ccall((:lf_shim_event_result_data, LINGOFUSE_SHIM_PATH),
                 Ptr{UInt8}, (Ptr{Cvoid},), e)
end

function shim_event_result_len(e::Ptr{Cvoid})::Csize_t
    return ccall((:lf_shim_event_result_len, LINGOFUSE_SHIM_PATH),
                 Csize_t, (Ptr{Cvoid},), e)
end

function shim_read_input(e::Ptr{Cvoid})::Vector{UInt8}
    p = shim_event_input_data(e)
    n = shim_event_input_len(e)
    (p == C_NULL || n == 0) && return UInt8[]
    out = Vector{UInt8}(undef, Int(n))
    unsafe_copyto!(pointer(out), p, Int(n))
    return out
end

function shim_read_result(e::Ptr{Cvoid})::Vector{UInt8}
    p = shim_event_result_data(e)
    n = shim_event_result_len(e)
    (p == C_NULL || n == 0) && return UInt8[]
    out = Vector{UInt8}(undef, Int(n))
    unsafe_copyto!(pointer(out), p, Int(n))
    return out
end

function shim_read_from_uid(e::Ptr{Cvoid})::NTuple{32, UInt8}
    if !shim_available()
        return zero_uid()
    end
    local p::Ptr{UInt8}
    try
        p = ccall((:lf_shim_event_from_uid, LINGOFUSE_SHIM_PATH),
                  Ptr{UInt8}, (Ptr{Cvoid},), e)
    catch
        return zero_uid()
    end
    p == C_NULL && return zero_uid()
    return ntuple(i -> unsafe_load(p, i), 32)
end

function shim_read_from_p2p_name(e::Ptr{Cvoid})::String
    if !shim_available()
        return ""
    end
    local p::Ptr{UInt8}
    try
        p = ccall((:lf_shim_event_from_p2p_name, LINGOFUSE_SHIM_PATH),
                  Ptr{UInt8}, (Ptr{Cvoid},), e)
    catch
        return ""
    end
    p == C_NULL && return ""
    return unsafe_string(p)
end

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

function shim_complete_event(e::Ptr{Cvoid})::Nothing
    trace("shim: complete_event $(e)")
    ccall((:lf_shim_complete_event, LINGOFUSE_SHIM_PATH),
          Cvoid, (Ptr{Cvoid},), e)
    return nothing
end

function shim_set_opt_password(value::AbstractString)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_password, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cstring,), value)
    return nothing
end

function shim_get_opt_password()::String
    _require_shim()
    p = ccall((:lf_shim_get_opt_password, LINGOFUSE_SHIM_PATH),
              Ptr{UInt8}, ())
    p == C_NULL && return ""
    return unsafe_string(p)
end

function shim_set_opt_debug(value::AbstractString)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_debug, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cstring,), value)
    return nothing
end

function shim_get_opt_debug()::String
    _require_shim()
    p = ccall((:lf_shim_get_opt_debug, LINGOFUSE_SHIM_PATH),
              Ptr{UInt8}, ())
    p == C_NULL && return ""
    return unsafe_string(p)
end

function shim_set_opt_quiet(value::Bool)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_quiet, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), value ? 1 : 0)
    return nothing
end

function shim_get_opt_quiet()::Bool
    _require_shim()
    return ccall((:lf_shim_get_opt_quiet, LINGOFUSE_SHIM_PATH),
                 Cint, ()) != 0
end

function shim_set_opt_show_thread_id(value::Bool)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_show_thread_id, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), value ? 1 : 0)
    return nothing
end

function shim_get_opt_show_thread_id()::Bool
    _require_shim()
    return ccall((:lf_shim_get_opt_show_thread_id, LINGOFUSE_SHIM_PATH),
                 Cint, ()) != 0
end

function shim_set_opt_console_output(value::Bool)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_console_output, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), value ? 1 : 0)
    return nothing
end

function shim_get_opt_console_output()::Bool
    _require_shim()
    return ccall((:lf_shim_get_opt_console_output, LINGOFUSE_SHIM_PATH),
                 Cint, ()) != 0
end

function shim_set_opt_overlap_connection(value::Bool)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_overlap_connection, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), value ? 1 : 0)
    return nothing
end

function shim_get_opt_overlap_connection()::Bool
    _require_shim()
    return ccall((:lf_shim_get_opt_overlap_connection,
                  LINGOFUSE_SHIM_PATH), Cint, ()) != 0
end

function shim_set_opt_wait_connection_ready_ok(value::Bool)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_wait_connection_ready_ok,
           LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), value ? 1 : 0)
    return nothing
end

function shim_get_opt_wait_connection_ready_ok()::Bool
    _require_shim()
    return ccall((:lf_shim_get_opt_wait_connection_ready_ok,
                  LINGOFUSE_SHIM_PATH), Cint, ()) != 0
end

function shim_set_opt_wait_connection_timeout(value_ms::UInt64)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_wait_connection_timeout, LINGOFUSE_SHIM_PATH),
          Cvoid, (UInt64,), value_ms)
    return nothing
end

function shim_get_opt_wait_connection_timeout()::UInt64
    _require_shim()
    return ccall((:lf_shim_get_opt_wait_connection_timeout,
                  LINGOFUSE_SHIM_PATH), UInt64, ())
end

function shim_set_opt_ipc_serv_thread_count(value::Integer)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_ipc_serv_thread_count, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), Cint(value))
    return nothing
end

function shim_get_opt_ipc_serv_thread_count()::Int
    _require_shim()
    return Int(ccall((:lf_shim_get_opt_ipc_serv_thread_count,
                      LINGOFUSE_SHIM_PATH), Cint, ()))
end

function shim_set_opt_ipc_serv_max_queue_length(value::Integer)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_ipc_serv_max_queue_length,
           LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), Cint(value))
    return nothing
end

function shim_get_opt_ipc_serv_max_queue_length()::Int
    _require_shim()
    return Int(ccall((:lf_shim_get_opt_ipc_serv_max_queue_length,
                      LINGOFUSE_SHIM_PATH), Cint, ()))
end

function shim_set_opt_ipc_serv_max_msg_size(value::Integer)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_ipc_serv_max_msg_size, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), Cint(value))
    return nothing
end

function shim_get_opt_ipc_serv_max_msg_size()::Int
    _require_shim()
    return Int(ccall((:lf_shim_get_opt_ipc_serv_max_msg_size,
                      LINGOFUSE_SHIM_PATH), Cint, ()))
end

function shim_set_opt_fixed_sequenced_time(value_ms::UInt64)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_fixed_sequenced_time, LINGOFUSE_SHIM_PATH),
          Cvoid, (UInt64,), value_ms)
    return nothing
end

function shim_get_opt_fixed_sequenced_time()::UInt64
    _require_shim()
    return ccall((:lf_shim_get_opt_fixed_sequenced_time,
                  LINGOFUSE_SHIM_PATH), UInt64, ())
end

function shim_set_opt_p2p_name(value::AbstractString)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_p2p_name, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cstring,), value)
    return nothing
end

function shim_get_opt_p2p_name()::String
    _require_shim()
    p = ccall((:lf_shim_get_opt_p2p_name, LINGOFUSE_SHIM_PATH),
              Ptr{UInt8}, ())
    p == C_NULL && return ""
    return unsafe_string(p)
end

function shim_set_opt_data_handle_idle_timeout(value_ms::UInt64)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_data_handle_idle_timeout,
           LINGOFUSE_SHIM_PATH),
          Cvoid, (UInt64,), value_ms)
    return nothing
end

function shim_get_opt_data_handle_idle_timeout()::UInt64
    _require_shim()
    return ccall((:lf_shim_get_opt_data_handle_idle_timeout,
                  LINGOFUSE_SHIM_PATH), UInt64, ())
end

function shim_set_opt_data_handle_pool_scan_interval(
    value_ms::UInt64)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_data_handle_pool_scan_interval,
           LINGOFUSE_SHIM_PATH),
          Cvoid, (UInt64,), value_ms)
    return nothing
end

function shim_get_opt_data_handle_pool_scan_interval()::UInt64
    _require_shim()
    return ccall((:lf_shim_get_opt_data_handle_pool_scan_interval,
                  LINGOFUSE_SHIM_PATH), UInt64, ())
end

function shim_set_opt_no_reponse_cmd_null_flush_threshold(
    value::Integer)::Nothing
    _require_shim()
    ccall((:lf_shim_set_opt_no_reponse_cmd_null_flush_threshold,
           LINGOFUSE_SHIM_PATH),
          Cvoid, (Cint,), Cint(value))
    return nothing
end

function shim_get_opt_no_reponse_cmd_null_flush_threshold()::Int
    _require_shim()
    return Int(ccall((:lf_shim_get_opt_no_reponse_cmd_null_flush_threshold,
                      LINGOFUSE_SHIM_PATH), Cint, ()))
end

function shim_set_option(name::AbstractString,
                         value::AbstractString)::Nothing
    _require_shim()
    ccall((:lf_shim_set_option, LINGOFUSE_SHIM_PATH),
          Cvoid, (Cstring, Cstring), name, value)
    return nothing
end

function shim_get_option(name::AbstractString)::String
    _require_shim()
    p = ccall((:lf_shim_get_option, LINGOFUSE_SHIM_PATH),
              Ptr{UInt8}, (Cstring,), name)
    p == C_NULL && return ""
    return unsafe_string(p)
end

export LF_SHIM_EVENT_CALL,
       LF_SHIM_EVENT_NOTIFY,
       LF_SHIM_EVENT_NETWORK_CONNECT,
       LF_SHIM_EVENT_NETWORK_DISCONNECT,
       LF_SHIM_EVENT_ASYNC_RESULT,
       LINGOFUSE_SHIM_PATH,
       shim_available, shim_is_real, shim_path,
       shim_init, shim_shutdown,
       shim_register_call, shim_register_notify,
       shim_register_p2p_call, shim_register_p2p_notify,
       shim_unregister_p2p,
       shim_install_network_events, shim_clear_network_events,
       shim_async_call, shim_async_sequenced_call,
       shim_uid_async_call, shim_uid_async_sequenced_call,
       shim_p2pname_async_call, shim_p2pname_async_sequenced_call,
       shim_wait_event,
       shim_event_kind, shim_event_user_id,
       shim_event_input, shim_event_output, shim_event_addr,
       shim_event_input_data, shim_event_input_len,
       shim_event_result_data, shim_event_result_len,
       shim_read_input, shim_read_result,
       shim_read_from_uid, shim_read_from_p2p_name,
       shim_set_output, shim_complete_event,
       shim_set_opt_password, shim_get_opt_password,
       shim_set_opt_debug, shim_get_opt_debug,
       shim_set_opt_quiet, shim_get_opt_quiet,
       shim_set_opt_show_thread_id, shim_get_opt_show_thread_id,
       shim_set_opt_console_output, shim_get_opt_console_output,
       shim_set_opt_overlap_connection, shim_get_opt_overlap_connection,
       shim_set_opt_wait_connection_ready_ok,
       shim_get_opt_wait_connection_ready_ok,
       shim_set_opt_wait_connection_timeout,
       shim_get_opt_wait_connection_timeout,
       shim_set_opt_ipc_serv_thread_count,
       shim_get_opt_ipc_serv_thread_count,
       shim_set_opt_ipc_serv_max_queue_length,
       shim_get_opt_ipc_serv_max_queue_length,
       shim_set_opt_ipc_serv_max_msg_size,
       shim_get_opt_ipc_serv_max_msg_size,
       shim_set_opt_fixed_sequenced_time,
       shim_get_opt_fixed_sequenced_time,
       shim_set_opt_p2p_name, shim_get_opt_p2p_name,
       shim_set_opt_data_handle_idle_timeout,
       shim_get_opt_data_handle_idle_timeout,
       shim_set_opt_data_handle_pool_scan_interval,
       shim_get_opt_data_handle_pool_scan_interval,
       shim_set_opt_no_reponse_cmd_null_flush_threshold,
       shim_get_opt_no_reponse_cmd_null_flush_threshold,
       shim_set_option, shim_get_option