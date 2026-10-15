#!/usr/bin/env julia
#
# test_shim.jl - Integration test for the C callback shim.
#
# ============================================================================
# v2.1 FIX: JIT COMPILATION THREAD RACE
# ============================================================================
# The previous revision crashed unpredictably inside the consumer
# thread, at different points across runs. Diagnosis:
#
#   * The first call to a fresh anonymous-closure handler (the `do`
#     block passed to alloc_uid) triggers Julia's JIT compiler on the
#     CONSUMER thread.
#
#   * At that moment the MAIN thread is blocked inside @threadcall,
#     waiting on a libuv worker that in turn waits on the shim's
#     native trampoline.
#
#   * The combination of "JIT compile on thread A" while "thread B is
#     parked inside @threadcall" hits an unreproducible edge case in
#     Julia 1.13's compiler state machine, producing a native crash.
#
# Two mitigations are applied here and BOTH are required:
#
#   1. WARMUP IN alloc_uid. Every handler is invoked three times on
#      the CALLING thread (with empty, tiny, and 8-byte payloads)
#      before it is ever handed to the shim. This forces the JIT to
#      compile the handler, its dependencies, and every top-level
#      helper it reaches (int32_from_le, int32_le, uppercase, ...)
#      on the main thread, where JIT is unambiguously safe.
#
#   2. INVOKELATEST IN THE CONSUMER. Every dispatch site calls the
#      handler through Base.invokelatest rather than a direct call.
#      This pins the call to the current world age and avoids any
#      remaining "method too new" boundary state.
#
# Do NOT remove either mitigation without reproducing the original
# crash on the target Julia version.
#
# ============================================================================
# OTHER DESIGN NOTES
# ============================================================================
#
# Logging
#   All output goes to stderr via println + flush.
#
# GC SAFETY FOR @threadcall ARGUMENTS
#   Every @threadcall that carries a raw pointer computes that pointer
#   INSIDE a GC.@preserve block. Computing it outside the block leaves
#   the source object unprotected; a young-generation GC can move the
#   object between the pointer computation and the call, and native
#   code then reads / writes freed memory.
#
# Consumer loop and GC interaction
#   The consumer thread polls lf_shim_wait_event with a ZERO timeout.
#   A long blocking ccall would pin the calling Julia thread outside a
#   GC safepoint; see SHIM_MECHANISM_GUIDE.md §4.5.
#
# Test framework
#   Manual check() function; no @testset.

# ---------------------------------------------------------------- #
# Logging                                                           #
# ---------------------------------------------------------------- #

function log(msg::AbstractString)
    println(stderr, "[test_shim] ", msg)
    flush(stderr)
end

# ---------------------------------------------------------------- #
# Locate the shim library                                           #
# ---------------------------------------------------------------- #

const HERE = @__DIR__

function find_shim_lib()::String
    candidates = Sys.iswindows() ? ["lf_shim_mock.dll"] :
                 Sys.isapple()   ? ["liblf_shim_mock.dylib"] :
                                   ["liblf_shim_mock.so"]
    for name in candidates
        p = joinpath(HERE, name)
        isfile(p) && return p
    end
    error("Cannot find the compiled shim in $HERE")
end

const SHIM = find_shim_lib()
log("shim library path: $SHIM")

# ---------------------------------------------------------------- #
# Event kind constants                                              #
# ---------------------------------------------------------------- #

const LF_SHIM_EVENT_CALL               = Cint(0)
const LF_SHIM_EVENT_NOTIFY             = Cint(1)
const LF_SHIM_EVENT_NETWORK_CONNECT    = Cint(2)
const LF_SHIM_EVENT_NETWORK_DISCONNECT = Cint(3)
const LF_SHIM_EVENT_ASYNC_RESULT       = Cint(4)

# ---------------------------------------------------------------- #
# UID type                                                          #
# ---------------------------------------------------------------- #

const UID_SIZE = 32
const LFShimUID = NTuple{UID_SIZE, UInt8}

zero_uid()::LFShimUID = ntuple(_ -> UInt8(0), UID_SIZE)

function uid_from_bytes(b::AbstractVector{UInt8})::LFShimUID
    length(b) == UID_SIZE || error("UID must be 32 bytes")
    return ntuple(i -> b[i], UID_SIZE)
end

# ---------------------------------------------------------------- #
# Shim lifecycle                                                    #
# ---------------------------------------------------------------- #

function shim_init()
    ret = ccall((:lf_shim_init, SHIM), Cint, ())
    ret == 1 || error("lf_shim_init failed")
end

shim_shutdown() = ccall((:lf_shim_shutdown, SHIM), Cvoid, ())

# ---------------------------------------------------------------- #
# App-bound registration                                            #
# ---------------------------------------------------------------- #

function shim_register_call(app::Ptr{Cvoid}, name::String, uid::Int64)::Bool
    ret = ccall((:lf_shim_register_call, SHIM), Cint,
                (Ptr{Cvoid}, Cstring, Cstring, Int64),
                app, name, "", uid)
    return ret == 1
end

function shim_register_notify(app::Ptr{Cvoid}, name::String, uid::Int64)::Bool
    ret = ccall((:lf_shim_register_notify, SHIM), Cint,
                (Ptr{Cvoid}, Cstring, Cstring, Int64),
                app, name, "", uid)
    return ret == 1
end

# ---------------------------------------------------------------- #
# Process-wide P2P registration                                     #
# ---------------------------------------------------------------- #

function shim_register_p2p_call(name::String, uid::Int64)::Bool
    ret = ccall((:lf_shim_register_p2p_call, SHIM), Cint,
                (Cstring, Cstring, Int64),
                name, "", uid)
    return ret == 1
end

function shim_register_p2p_notify(name::String, uid::Int64)::Bool
    ret = ccall((:lf_shim_register_p2p_notify, SHIM), Cint,
                (Cstring, Cstring, Int64),
                name, "", uid)
    return ret == 1
end

function shim_unregister_p2p(name::String)::Bool
    ret = ccall((:lf_shim_unregister_p2p, SHIM), Cint, (Cstring,), name)
    return ret == 1
end

# ---------------------------------------------------------------- #
# Network events                                                    #
# ---------------------------------------------------------------- #

function shim_install_network_events(conn_uid::Int64, disc_uid::Int64)
    ccall((:lf_shim_install_network_events, SHIM), Cvoid,
          (Int64, Int64), conn_uid, disc_uid)
end

shim_clear_network_events() =
    ccall((:lf_shim_clear_network_events, SHIM), Cvoid, ())

# ---------------------------------------------------------------- #
# Async primitives                                                  #
# ---------------------------------------------------------------- #

function shim_async_call(app_name::String,
                         param::Ptr{Cvoid},
                         token::Int64)::Cint
    return ccall((:lf_shim_async_call, SHIM), Cint,
                 (Cstring, Ptr{Cvoid}, Int64),
                 app_name, param, token)
end

function shim_async_sequenced_call(app_name::String,
                                   param::Ptr{Cvoid},
                                   token::Int64)::Cint
    return ccall((:lf_shim_async_sequenced_call, SHIM), Cint,
                 (Cstring, Ptr{Cvoid}, Int64),
                 app_name, param, token)
end

function shim_uid_async_call(uid::LFShimUID,
                             param::Ptr{Cvoid},
                             token::Int64)::Cint
    uid_ref = Ref(uid)
    return ccall((:lf_shim_uid_async_call, SHIM), Cint,
                 (Ref{LFShimUID}, Ptr{Cvoid}, Int64),
                 uid_ref, param, token)
end

function shim_uid_async_sequenced_call(uid::LFShimUID,
                                       param::Ptr{Cvoid},
                                       token::Int64)::Cint
    uid_ref = Ref(uid)
    return ccall((:lf_shim_uid_async_sequenced_call, SHIM), Cint,
                 (Ref{LFShimUID}, Ptr{Cvoid}, Int64),
                 uid_ref, param, token)
end

function shim_p2pname_async_call(group::String,
                                 param::Ptr{Cvoid},
                                 token::Int64)::Cint
    return ccall((:lf_shim_p2pname_async_call, SHIM), Cint,
                 (Cstring, Ptr{Cvoid}, Int64),
                 group, param, token)
end

function shim_p2pname_async_sequenced_call(group::String,
                                           param::Ptr{Cvoid},
                                           token::Int64)::Cint
    return ccall((:lf_shim_p2pname_async_sequenced_call, SHIM), Cint,
                 (Cstring, Ptr{Cvoid}, Int64),
                 group, param, token)
end

# ---------------------------------------------------------------- #
# Runtime options: typed getters/setters                            #
# ---------------------------------------------------------------- #

shim_set_opt_quiet(v::Bool) =
    ccall((:lf_shim_set_opt_quiet, SHIM), Cvoid, (Cint,), v ? 1 : 0)
shim_get_opt_quiet()::Bool =
    ccall((:lf_shim_get_opt_quiet, SHIM), Cint, ()) != 0

shim_set_opt_show_thread_id(v::Bool) =
    ccall((:lf_shim_set_opt_show_thread_id, SHIM), Cvoid, (Cint,), v ? 1 : 0)
shim_get_opt_show_thread_id()::Bool =
    ccall((:lf_shim_get_opt_show_thread_id, SHIM), Cint, ()) != 0

shim_set_opt_console_output(v::Bool) =
    ccall((:lf_shim_set_opt_console_output, SHIM), Cvoid, (Cint,), v ? 1 : 0)
shim_get_opt_console_output()::Bool =
    ccall((:lf_shim_get_opt_console_output, SHIM), Cint, ()) != 0

shim_set_opt_overlap_connection(v::Bool) =
    ccall((:lf_shim_set_opt_overlap_connection, SHIM), Cvoid, (Cint,), v ? 1 : 0)
shim_get_opt_overlap_connection()::Bool =
    ccall((:lf_shim_get_opt_overlap_connection, SHIM), Cint, ()) != 0

shim_set_opt_wait_connection_ready_ok(v::Bool) =
    ccall((:lf_shim_set_opt_wait_connection_ready_ok, SHIM), Cvoid, (Cint,), v ? 1 : 0)
shim_get_opt_wait_connection_ready_ok()::Bool =
    ccall((:lf_shim_get_opt_wait_connection_ready_ok, SHIM), Cint, ()) != 0

shim_set_opt_wait_connection_timeout(v::UInt64) =
    ccall((:lf_shim_set_opt_wait_connection_timeout, SHIM), Cvoid, (UInt64,), v)
shim_get_opt_wait_connection_timeout()::UInt64 =
    ccall((:lf_shim_get_opt_wait_connection_timeout, SHIM), UInt64, ())

shim_set_opt_fixed_sequenced_time(v::UInt64) =
    ccall((:lf_shim_set_opt_fixed_sequenced_time, SHIM), Cvoid, (UInt64,), v)
shim_get_opt_fixed_sequenced_time()::UInt64 =
    ccall((:lf_shim_get_opt_fixed_sequenced_time, SHIM), UInt64, ())

shim_set_opt_data_handle_idle_timeout(v::UInt64) =
    ccall((:lf_shim_set_opt_data_handle_idle_timeout, SHIM), Cvoid, (UInt64,), v)
shim_get_opt_data_handle_idle_timeout()::UInt64 =
    ccall((:lf_shim_get_opt_data_handle_idle_timeout, SHIM), UInt64, ())

shim_set_opt_data_handle_pool_scan_interval(v::UInt64) =
    ccall((:lf_shim_set_opt_data_handle_pool_scan_interval, SHIM), Cvoid, (UInt64,), v)
shim_get_opt_data_handle_pool_scan_interval()::UInt64 =
    ccall((:lf_shim_get_opt_data_handle_pool_scan_interval, SHIM), UInt64, ())

shim_set_opt_ipc_serv_thread_count(v::Int) =
    ccall((:lf_shim_set_opt_ipc_serv_thread_count, SHIM), Cvoid, (Cint,), v)
shim_get_opt_ipc_serv_thread_count()::Int =
    Int(ccall((:lf_shim_get_opt_ipc_serv_thread_count, SHIM), Cint, ()))

shim_set_opt_ipc_serv_max_queue_length(v::Int) =
    ccall((:lf_shim_set_opt_ipc_serv_max_queue_length, SHIM), Cvoid, (Cint,), v)
shim_get_opt_ipc_serv_max_queue_length()::Int =
    Int(ccall((:lf_shim_get_opt_ipc_serv_max_queue_length, SHIM), Cint, ()))

shim_set_opt_ipc_serv_max_msg_size(v::Int) =
    ccall((:lf_shim_set_opt_ipc_serv_max_msg_size, SHIM), Cvoid, (Cint,), v)
shim_get_opt_ipc_serv_max_msg_size()::Int =
    Int(ccall((:lf_shim_get_opt_ipc_serv_max_msg_size, SHIM), Cint, ()))

shim_set_opt_no_reponse_cmd_null_flush_threshold(v::Int) =
    ccall((:lf_shim_set_opt_no_reponse_cmd_null_flush_threshold, SHIM), Cvoid, (Cint,), v)
shim_get_opt_no_reponse_cmd_null_flush_threshold()::Int =
    Int(ccall((:lf_shim_get_opt_no_reponse_cmd_null_flush_threshold, SHIM), Cint, ()))

function shim_set_opt_password(v::String)
    ccall((:lf_shim_set_opt_password, SHIM), Cvoid, (Cstring,), v)
end

function shim_get_opt_password()::String
    p = ccall((:lf_shim_get_opt_password, SHIM), Ptr{UInt8}, ())
    p == C_NULL && return ""
    return unsafe_string(p)
end

function shim_set_opt_debug(v::String)
    ccall((:lf_shim_set_opt_debug, SHIM), Cvoid, (Cstring,), v)
end

function shim_get_opt_debug()::String
    p = ccall((:lf_shim_get_opt_debug, SHIM), Ptr{UInt8}, ())
    p == C_NULL && return ""
    return unsafe_string(p)
end

function shim_set_opt_p2p_name(v::String)
    ccall((:lf_shim_set_opt_p2p_name, SHIM), Cvoid, (Cstring,), v)
end

function shim_get_opt_p2p_name()::String
    p = ccall((:lf_shim_get_opt_p2p_name, SHIM), Ptr{UInt8}, ())
    p == C_NULL && return ""
    return unsafe_string(p)
end

function shim_set_option(name::String, value::String)
    ccall((:lf_shim_set_option, SHIM), Cvoid, (Cstring, Cstring), name, value)
end

function shim_get_option(name::String)::String
    p = ccall((:lf_shim_get_option, SHIM), Ptr{UInt8}, (Cstring,), name)
    p == C_NULL && return ""
    return unsafe_string(p)
end

# ---------------------------------------------------------------- #
# Event accessors                                                   #
# ---------------------------------------------------------------- #

shim_wait_event(timeout_ms::Int)::Ptr{Cvoid} =
    ccall((:lf_shim_wait_event, SHIM), Ptr{Cvoid}, (Cint,), timeout_ms)

shim_event_kind(e::Ptr{Cvoid})::Int =
    Int(ccall((:lf_shim_event_kind, SHIM), Cint, (Ptr{Cvoid},), e))

shim_event_uid(e::Ptr{Cvoid})::Int64 =
    ccall((:lf_shim_event_user_id, SHIM), Int64, (Ptr{Cvoid},), e)

shim_event_input(e::Ptr{Cvoid})::Ptr{Cvoid} =
    ccall((:lf_shim_event_input, SHIM), Ptr{Cvoid}, (Ptr{Cvoid},), e)

shim_event_output(e::Ptr{Cvoid})::Ptr{Cvoid} =
    ccall((:lf_shim_event_output, SHIM), Ptr{Cvoid}, (Ptr{Cvoid},), e)

function shim_event_addr(e::Ptr{Cvoid})::Union{String,Nothing}
    p = ccall((:lf_shim_event_addr, SHIM), Ptr{UInt8}, (Ptr{Cvoid},), e)
    p == C_NULL && return nothing
    return unsafe_string(p)
end

function shim_event_input_data(e::Ptr{Cvoid})::Ptr{UInt8}
    return ccall((:lf_shim_event_input_data, SHIM), Ptr{UInt8}, (Ptr{Cvoid},), e)
end

function shim_event_input_len(e::Ptr{Cvoid})::Csize_t
    return ccall((:lf_shim_event_input_len, SHIM), Csize_t, (Ptr{Cvoid},), e)
end

function shim_read_input(e::Ptr{Cvoid})::Vector{UInt8}
    p = shim_event_input_data(e)
    n = shim_event_input_len(e)
    (p == C_NULL || n == 0) && return UInt8[]
    out = Vector{UInt8}(undef, Int(n))
    GC.@preserve out begin
        unsafe_copyto!(pointer(out), p, Int(n))
    end
    return out
end

function shim_event_result_data(e::Ptr{Cvoid})::Ptr{UInt8}
    return ccall((:lf_shim_event_result_data, SHIM), Ptr{UInt8}, (Ptr{Cvoid},), e)
end

function shim_event_result_len(e::Ptr{Cvoid})::Csize_t
    return ccall((:lf_shim_event_result_len, SHIM), Csize_t, (Ptr{Cvoid},), e)
end

function shim_read_result(e::Ptr{Cvoid})::Vector{UInt8}
    p = shim_event_result_data(e)
    n = shim_event_result_len(e)
    (p == C_NULL || n == 0) && return UInt8[]
    out = Vector{UInt8}(undef, Int(n))
    GC.@preserve out begin
        unsafe_copyto!(pointer(out), p, Int(n))
    end
    return out
end

function shim_set_output(e::Ptr{Cvoid}, data::Vector{UInt8})::Bool
    isempty(data) && return true
    ret = GC.@preserve data begin
        ccall((:lf_shim_set_output, SHIM), Cint,
              (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
              e, pointer(data), Csize_t(length(data)))
    end
    return ret == 1
end

shim_complete(e::Ptr{Cvoid}) =
    ccall((:lf_shim_complete_event, SHIM), Cvoid, (Ptr{Cvoid},), e)

# ---------------------------------------------------------------- #
# Mock drivers via @threadcall                                      #
# ---------------------------------------------------------------- #

function mock_trigger_call(name::String, input::Vector{UInt8};
                           cap::Int = 4096)::Vector{UInt8}
    log("mock_trigger_call: ENTER  name=$name  len=$(length(input))")

    out_buf = zeros(UInt8, cap)
    written = Ref{Csize_t}(0)
    in_len  = length(input)
    cap_val = cap

    GC.@preserve name input out_buf written begin
        name_ptr = Base.unsafe_convert(Ptr{UInt8}, name)
        in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)
        out_ptr  = pointer(out_buf)
        wrt_ptr  = Base.unsafe_convert(Ptr{Csize_t}, written)

        @threadcall((:mock_lf_trigger_call, SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t,
                     Ptr{UInt8}, Csize_t, Ptr{Csize_t}),
                    name_ptr, in_ptr, in_len,
                    out_ptr, cap_val, wrt_ptr)
    end

    log("mock_trigger_call: RETURNED  written=$(written[])")
    return out_buf[1:written[]]
end

function mock_trigger_notify(name::String, input::Vector{UInt8})
    log("mock_trigger_notify: ENTER  name=$name  len=$(length(input))")

    in_len = length(input)

    GC.@preserve name input begin
        name_ptr = Base.unsafe_convert(Ptr{UInt8}, name)
        in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)

        @threadcall((:mock_lf_trigger_notify, SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
                    name_ptr, in_ptr, in_len)
    end

    log("mock_trigger_notify: RETURNED")
end

function mock_trigger_p2p_call(name::String, input::Vector{UInt8};
                               cap::Int = 4096)::Vector{UInt8}
    log("mock_trigger_p2p_call: ENTER  name=$name  len=$(length(input))")

    out_buf = zeros(UInt8, cap)
    written = Ref{Csize_t}(0)
    in_len  = length(input)
    cap_val = cap

    GC.@preserve name input out_buf written begin
        name_ptr = Base.unsafe_convert(Ptr{UInt8}, name)
        in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)
        out_ptr  = pointer(out_buf)
        wrt_ptr  = Base.unsafe_convert(Ptr{Csize_t}, written)

        @threadcall((:mock_lf_trigger_p2p_call, SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t,
                     Ptr{UInt8}, Csize_t, Ptr{Csize_t}),
                    name_ptr, in_ptr, in_len,
                    out_ptr, cap_val, wrt_ptr)
    end

    log("mock_trigger_p2p_call: RETURNED  written=$(written[])")
    return out_buf[1:written[]]
end

function mock_trigger_p2p_notify(name::String, input::Vector{UInt8})
    log("mock_trigger_p2p_notify: ENTER  name=$name  len=$(length(input))")

    in_len = length(input)

    GC.@preserve name input begin
        name_ptr = Base.unsafe_convert(Ptr{UInt8}, name)
        in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)

        @threadcall((:mock_lf_trigger_p2p_notify, SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
                    name_ptr, in_ptr, in_len)
    end

    log("mock_trigger_p2p_notify: RETURNED")
end

function mock_trigger_network(is_connect::Bool, addr::String)
    log("mock_trigger_network: ENTER  is_connect=$is_connect  addr=$addr")

    flag = is_connect ? Cint(1) : Cint(0)

    GC.@preserve addr begin
        addr_ptr = Base.unsafe_convert(Ptr{UInt8}, addr)

        @threadcall((:mock_lf_trigger_network_event, SHIM), Cvoid,
                    (Cint, Ptr{UInt8}),
                    flag, addr_ptr)
    end

    log("mock_trigger_network: RETURNED")
end

function mock_trigger_async_result(token::Int64, result::Vector{UInt8})
    log("mock_trigger_async_result: ENTER  token=$token  len=$(length(result))")

    res_len = length(result)

    GC.@preserve result begin
        res_ptr = isempty(result) ? Ptr{UInt8}(0) : pointer(result)

        @threadcall((:mock_lf_trigger_async_result, SHIM), Cvoid,
                    (Int64, Ptr{UInt8}, Csize_t),
                    token, res_ptr, res_len)
    end

    log("mock_trigger_async_result: RETURNED")
end

# ---------------------------------------------------------------- #
# Data-handle operations (mock)                                     #
# ---------------------------------------------------------------- #

lf_create_data(name::String)::Ptr{Cvoid} =
    ccall((:LF_CreateData, SHIM), Ptr{Cvoid}, (Cstring,), name)

lf_free_data(h::Ptr{Cvoid}) =
    ccall((:LF_FreeData, SHIM), Cvoid, (Ptr{Cvoid},), h)

lf_get_size(h::Ptr{Cvoid})::Int64 =
    ccall((:LF_GetSize, SHIM), Int64, (Ptr{Cvoid},), h)

lf_get_pos(h::Ptr{Cvoid})::Int64 =
    ccall((:LF_GetPos, SHIM), Int64, (Ptr{Cvoid},), h)

function lf_read_all(h::Ptr{Cvoid})::Vector{UInt8}
    sz  = lf_get_size(h)
    pos = lf_get_pos(h)
    n   = sz - pos
    n <= 0 && return UInt8[]
    buf = zeros(UInt8, n)
    got = GC.@preserve buf begin
        ccall((:LF_ReadBuffer, SHIM), Int64,
              (Ptr{Cvoid}, Ptr{UInt8}, Int64),
              h, pointer(buf), n)
    end
    return buf[1:got]
end

function lf_write_buffer(h::Ptr{Cvoid}, data::Vector{UInt8})::Int64
    return GC.@preserve data begin
        ccall((:LF_WriteBuffer, SHIM), Int64,
              (Ptr{Cvoid}, Ptr{UInt8}, Int64),
              h, pointer(data), length(data))
    end
end

make_app(name::String)::Ptr{Cvoid} =
    ccall((:LF_CreateApp, SHIM), Ptr{Cvoid},
          (Cstring, Cstring), name, "test")

free_app(app::Ptr{Cvoid}) =
    ccall((:LF_FreeApp, SHIM), Cvoid, (Ptr{Cvoid},), app)

# ---------------------------------------------------------------- #
# Dispatch table + JIT warmup                                       #
# ---------------------------------------------------------------- #
#
# WARMUP IS MANDATORY. See the file header. Three probe payloads
# cover the empty, tiny, and 8-byte dispatch paths; together they
# force JIT compilation of the handler closure AND every top-level
# helper it reaches (int32_from_le, int32_le, uppercase, String, ...)
# on the calling thread.

const HANDLERS = Dict{Int64, Function}()
const NEXT_UID = Ref{Int64}(0)

function alloc_uid(handler::Function)::Int64
    uid = (NEXT_UID[] += 1)
    HANDLERS[uid] = handler

    for probe in (UInt8[], UInt8[0x00], zeros(UInt8, 8))
        try
            Base.invokelatest(handler, probe)
        catch
            # A handler that rejects an unexpected payload shape must
            # still be registrable. Only the compilation side effect
            # of the invocation matters here.
        end
    end

    return uid
end

# ---------------------------------------------------------------- #
# Consumer loop (critical: non-blocking poll + sleep)               #
# ---------------------------------------------------------------- #

const RUNNING          = Ref{Bool}(true)
const EVENTS_PROCESSED = Ref{Int}(0)
const CONSUMER_TID     = Ref{Int}(-1)

const POLL_INTERVAL_S  = 0.005   # 5 ms

function consumer_loop()
    CONSUMER_TID[] = Threads.threadid()
    log("consumer_loop: STARTED  tid=$(CONSUMER_TID[])")

    while RUNNING[]
        e = shim_wait_event(0)
        if e == C_NULL
            sleep(POLL_INTERVAL_S)
            continue
        end

        kind = shim_event_kind(e)
        uid  = shim_event_uid(e)
        log("consumer_loop: EVENT RECEIVED  kind=$kind  uid=$uid")

        try
            if kind == Int(LF_SHIM_EVENT_CALL)
                handle_call_event(e, uid)
            elseif kind == Int(LF_SHIM_EVENT_NOTIFY)
                handle_notify_event(e, uid)
            elseif kind == Int(LF_SHIM_EVENT_NETWORK_CONNECT)
                handle_network_event(e, uid, "connect")
            elseif kind == Int(LF_SHIM_EVENT_NETWORK_DISCONNECT)
                handle_network_event(e, uid, "disconnect")
            elseif kind == Int(LF_SHIM_EVENT_ASYNC_RESULT)
                handle_async_result_event(e, uid)
            end
            log("consumer_loop: handler returned  kind=$kind  uid=$uid")
        catch err
            log("consumer_loop: HANDLER RAISED  kind=$kind  uid=$uid")
            showerror(stderr, err, catch_backtrace())
            println(stderr)
            flush(stderr)
        finally
            log("consumer_loop: completing event  kind=$kind  uid=$uid")
            shim_complete(e)
            EVENTS_PROCESSED[] += 1
            log("consumer_loop: EVENT COMPLETED  kind=$kind  uid=$uid")
        end

        sleep(0)
    end

    log("consumer_loop: EXITING")
end

function handle_call_event(e::Ptr{Cvoid}, uid::Int64)
    log("handle_call: ENTER  uid=$uid")

    handler = get(HANDLERS, uid, nothing)
    log("handle_call: handler lookup  found=$(handler !== nothing)")
    handler === nothing && return

    in_bytes = shim_read_input(e)
    log("handle_call: input read  len=$(length(in_bytes))")

    result = Base.invokelatest(handler, in_bytes)
    log("handle_call: handler returned  type=$(typeof(result))")

    if result isa Vector{UInt8} && !isempty(result)
        shim_set_output(e, result)
        log("handle_call: output written  len=$(length(result))")
    end

    log("handle_call: EXIT  uid=$uid")
end

function handle_notify_event(e::Ptr{Cvoid}, uid::Int64)
    log("handle_notify: ENTER  uid=$uid")
    handler = get(HANDLERS, uid, nothing)
    handler === nothing && return

    in_bytes = shim_read_input(e)
    Base.invokelatest(handler, in_bytes)
    log("handle_notify: EXIT  uid=$uid")
end

function handle_network_event(e::Ptr{Cvoid}, uid::Int64, which::String)
    log("handle_network: ENTER  uid=$uid  which=$which")
    handler = get(HANDLERS, uid, nothing)
    handler === nothing && return

    addr = shim_event_addr(e)
    Base.invokelatest(handler, which, addr)
    log("handle_network: EXIT  uid=$uid")
end

function handle_async_result_event(e::Ptr{Cvoid}, token::Int64)
    log("handle_async_result: ENTER  token=$token")
    handler = get(HANDLERS, token, nothing)
    if handler === nothing
        log("handle_async_result: no handler for token=$token")
        return
    end

    result_bytes = shim_read_result(e)
    log("handle_async_result: result len=$(length(result_bytes))")

    Base.invokelatest(handler, result_bytes)
    log("handle_async_result: EXIT  token=$token")
end

# ---------------------------------------------------------------- #
# Manual check framework (no @testset)                              #
# ---------------------------------------------------------------- #

const CHECKS_PASSED = Ref{Int}(0)
const CHECKS_FAILED = Ref{Int}(0)

function check(cond::Bool, msg::AbstractString)
    if cond
        CHECKS_PASSED[] += 1
        log("  PASS  $msg")
    else
        CHECKS_FAILED[] += 1
        log("  FAIL  $msg")
    end
end

# ---------------------------------------------------------------- #
# Small helpers                                                     #
# ---------------------------------------------------------------- #

int32_le(v::Int32)::Vector{UInt8} = collect(reinterpret(UInt8, [v]))
int32_from_le(b::Vector{UInt8})::Int32 = reinterpret(Int32, b[1:4])[1]

# ---------------------------------------------------------------- #
# Section 1 / 2: App-bound Call and Notify                          #
# ---------------------------------------------------------------- #

function test_echo_call()
    log("test_echo_call: ENTER")

    app = make_app("TestEcho")
    uid = alloc_uid() do in_bytes::Vector{UInt8}
        return in_bytes
    end
    check(shim_register_call(app, "echo", uid), "register_call 'echo'")

    payload = Vector{UInt8}(codeunits("hello, world"))
    log("test_echo_call: calling mock_trigger_call")
    response = mock_trigger_call("echo", payload)
    log("test_echo_call: mock returned  len=$(length(response))")

    check(response == payload, "echo response equals payload")

    free_app(app)
    log("test_echo_call: EXIT")
end

function test_add_call()
    log("test_add_call: ENTER")

    app = make_app("TestCalc")
    uid = alloc_uid() do in_bytes::Vector{UInt8}
        @assert length(in_bytes) == 8 "expected two int32"
        a = int32_from_le(in_bytes[1:4])
        b = int32_from_le(in_bytes[5:8])
        return int32_le(a + b)
    end
    check(shim_register_call(app, "add", uid), "register_call 'add'")

    req  = vcat(int32_le(Int32(5)), int32_le(Int32(7)))
    log("test_add_call: calling mock_trigger_call")
    resp = mock_trigger_call("add", req)
    log("test_add_call: mock returned  len=$(length(resp))")

    check(length(resp) == 4,                "add response length is 4")
    check(int32_from_le(resp) == Int32(12), "add response value is 12")

    free_app(app)
    log("test_add_call: EXIT")
end

function test_notify()
    log("test_notify: ENTER")

    app = make_app("TestNotify")
    received = Ref{Vector{UInt8}}(UInt8[])

    uid = alloc_uid() do in_bytes::Vector{UInt8}
        received[] = in_bytes
        return nothing
    end
    check(shim_register_notify(app, "log", uid), "register_notify 'log'")

    payload = Vector{UInt8}(codeunits("notify-payload"))
    log("test_notify: calling mock_trigger_notify")
    mock_trigger_notify("log", payload)
    log("test_notify: mock returned")

    check(received[] == payload, "notify payload matches")

    free_app(app)
    log("test_notify: EXIT")
end

# ---------------------------------------------------------------- #
# Section 3: Process-wide P2P registration and dispatch             #
# ---------------------------------------------------------------- #

function test_p2p_call()
    log("test_p2p_call: ENTER")

    uid = alloc_uid() do in_bytes::Vector{UInt8}
        return Vector{UInt8}(uppercase(String(copy(in_bytes))))
    end

    check(shim_register_p2p_call("p2p_echo", uid), "register_p2p_call ok")

    payload = Vector{UInt8}(codeunits("p2p hello"))
    resp = mock_trigger_p2p_call("p2p_echo", payload)

    check(String(copy(resp)) == "P2P HELLO",
          "p2p_call response was uppercased by handler")

    log("test_p2p_call: EXIT")
end

function test_p2p_notify()
    log("test_p2p_notify: ENTER")

    received = Ref{Vector{UInt8}}(UInt8[])
    uid = alloc_uid() do in_bytes::Vector{UInt8}
        received[] = in_bytes
        return nothing
    end

    check(shim_register_p2p_notify("p2p_log", uid), "register_p2p_notify ok")

    payload = Vector{UInt8}(codeunits("p2p notification"))
    mock_trigger_p2p_notify("p2p_log", payload)

    check(received[] == payload, "p2p notify payload matches")

    log("test_p2p_notify: EXIT")
end

function test_p2p_unregister()
    log("test_p2p_unregister: ENTER")

    uid = alloc_uid() do in_bytes::Vector{UInt8}
        return in_bytes
    end
    shim_register_p2p_notify("p2p_transient", uid)

    check(shim_unregister_p2p("p2p_transient"),
          "unregister_p2p returns true for an existing API")

    check(!shim_unregister_p2p("p2p_transient"),
          "unregister_p2p returns false for an already-removed API")

    log("test_p2p_unregister: EXIT")
end

# ---------------------------------------------------------------- #
# Section 4: Network events                                         #
# ---------------------------------------------------------------- #

function test_network_events()
    log("test_network_events: ENTER")

    events = Vector{Tuple{String,Union{String,Nothing}}}()

    uid_conn = alloc_uid() do which, addr
        push!(events, (String(which), addr))
    end
    uid_disc = alloc_uid() do which, addr
        push!(events, (String(which), addr))
    end

    shim_install_network_events(uid_conn, uid_disc)

    log("test_network_events: triggering connect")
    mock_trigger_network(true, "ipc:test_endpoint")
    log("test_network_events: connect returned")

    log("test_network_events: triggering disconnect")
    mock_trigger_network(false, "ipc:test_endpoint")
    log("test_network_events: disconnect returned")

    check(length(events) == 2,                     "two network events received")
    if length(events) == 2
        check(events[1][1] == "connect",           "first event is connect")
        check(events[2][1] == "disconnect",        "second event is disconnect")
        check(events[1][2] == "ipc:test_endpoint", "connect addr matches")
    end

    shim_clear_network_events()
    log("test_network_events: EXIT")
end

# ---------------------------------------------------------------- #
# Section 5: Async primitives                                       #
# ---------------------------------------------------------------- #

function test_async_call()
    log("test_async_call: ENTER")

    expected = Vector{UInt8}(codeunits("async result A"))
    param = lf_create_data("__async_param_A__")

    received = Ref{Vector{UInt8}}(UInt8[])
    token = alloc_uid() do result_bytes::Vector{UInt8}
        received[] = result_bytes
    end

    try
        ret = shim_async_call("AnyApp", param, token)
        check(ret == Cint(1), "shim_async_call returned 1")

        mock_trigger_async_result(token, expected)
        check(received[] == expected, "async result delivered intact")
    finally
        lf_free_data(param)
    end

    log("test_async_call: EXIT")
end

function test_async_sequenced_call()
    log("test_async_sequenced_call: ENTER")

    expected = Vector{UInt8}(codeunits("async sequenced result"))
    param = lf_create_data("__async_param_B__")

    received = Ref{Vector{UInt8}}(UInt8[])
    token = alloc_uid() do result_bytes::Vector{UInt8}
        received[] = result_bytes
    end

    try
        ret = shim_async_sequenced_call("AnyApp", param, token)
        check(ret == Cint(1), "shim_async_sequenced_call returned 1")

        mock_trigger_async_result(token, expected)
        check(received[] == expected, "async sequenced result delivered intact")
    finally
        lf_free_data(param)
    end

    log("test_async_sequenced_call: EXIT")
end

function test_uid_async_call()
    log("test_uid_async_call: ENTER")

    expected = Vector{UInt8}(codeunits("uid async result"))
    param = lf_create_data("__async_param_C__")

    received = Ref{Vector{UInt8}}(UInt8[])
    token = alloc_uid() do result_bytes::Vector{UInt8}
        received[] = result_bytes
    end

    uid = uid_from_bytes(collect(UInt8, 1:32))

    try
        ret = shim_uid_async_call(uid, param, token)
        check(ret == Cint(1), "shim_uid_async_call returned 1")

        mock_trigger_async_result(token, expected)
        check(received[] == expected, "uid async result delivered intact")
    finally
        lf_free_data(param)
    end

    log("test_uid_async_call: EXIT")
end

function test_uid_async_sequenced_call()
    log("test_uid_async_sequenced_call: ENTER")

    expected = Vector{UInt8}(codeunits("uid async sequenced result"))
    param = lf_create_data("__async_param_D__")

    received = Ref{Vector{UInt8}}(UInt8[])
    token = alloc_uid() do result_bytes::Vector{UInt8}
        received[] = result_bytes
    end

    uid = uid_from_bytes(collect(UInt8, 1:32))

    try
        ret = shim_uid_async_sequenced_call(uid, param, token)
        check(ret == Cint(1), "shim_uid_async_sequenced_call returned 1")

        mock_trigger_async_result(token, expected)
        check(received[] == expected, "uid async sequenced result delivered intact")
    finally
        lf_free_data(param)
    end

    log("test_uid_async_sequenced_call: EXIT")
end

function test_p2pname_async_call()
    log("test_p2pname_async_call: ENTER")

    expected = Vector{UInt8}(codeunits("p2p async result"))
    param = lf_create_data("__async_param_E__")

    received = Ref{Vector{UInt8}}(UInt8[])
    token = alloc_uid() do result_bytes::Vector{UInt8}
        received[] = result_bytes
    end

    try
        ret = shim_p2pname_async_call("worker_group", param, token)
        check(ret == Cint(1), "shim_p2pname_async_call returned 1")

        mock_trigger_async_result(token, expected)
        check(received[] == expected, "p2pname async result delivered intact")
    finally
        lf_free_data(param)
    end

    log("test_p2pname_async_call: EXIT")
end

function test_p2pname_async_sequenced_call()
    log("test_p2pname_async_sequenced_call: ENTER")

    expected = Vector{UInt8}(codeunits("p2p async sequenced result"))
    param = lf_create_data("__async_param_F__")

    received = Ref{Vector{UInt8}}(UInt8[])
    token = alloc_uid() do result_bytes::Vector{UInt8}
        received[] = result_bytes
    end

    try
        ret = shim_p2pname_async_sequenced_call("worker_group", param, token)
        check(ret == Cint(1), "shim_p2pname_async_sequenced_call returned 1")

        mock_trigger_async_result(token, expected)
        check(received[] == expected, "p2pname async sequenced result delivered intact")
    finally
        lf_free_data(param)
    end

    log("test_p2pname_async_sequenced_call: EXIT")
end

# ---------------------------------------------------------------- #
# Section 6: Runtime options                                        #
# ---------------------------------------------------------------- #

function test_opt_bool_roundtrip()
    log("test_opt_bool_roundtrip: ENTER")

    shim_set_opt_quiet(true);  check(shim_get_opt_quiet(),  "quiet true -> true")
    shim_set_opt_quiet(false); check(!shim_get_opt_quiet(), "quiet false -> false")

    shim_set_opt_show_thread_id(true);  check(shim_get_opt_show_thread_id(),  "show_thread_id true -> true")
    shim_set_opt_show_thread_id(false); check(!shim_get_opt_show_thread_id(), "show_thread_id false -> false")

    shim_set_opt_console_output(true);  check(shim_get_opt_console_output(),  "console_output true -> true")
    shim_set_opt_console_output(false); check(!shim_get_opt_console_output(), "console_output false -> false")

    shim_set_opt_overlap_connection(true);  check(shim_get_opt_overlap_connection(),  "overlap_connection true -> true")
    shim_set_opt_overlap_connection(false); check(!shim_get_opt_overlap_connection(), "overlap_connection false -> false")

    shim_set_opt_wait_connection_ready_ok(true);  check(shim_get_opt_wait_connection_ready_ok(),  "wait_connection_ready_ok true -> true")
    shim_set_opt_wait_connection_ready_ok(false); check(!shim_get_opt_wait_connection_ready_ok(), "wait_connection_ready_ok false -> false")

    log("test_opt_bool_roundtrip: EXIT")
end

function test_opt_numeric_roundtrip()
    log("test_opt_numeric_roundtrip: ENTER")

    shim_set_opt_wait_connection_timeout(UInt64(12345))
    check(shim_get_opt_wait_connection_timeout() == UInt64(12345),
          "wait_connection_timeout round-trip")

    shim_set_opt_fixed_sequenced_time(UInt64(67890))
    check(shim_get_opt_fixed_sequenced_time() == UInt64(67890),
          "fixed_sequenced_time round-trip")

    shim_set_opt_data_handle_idle_timeout(UInt64(111111))
    check(shim_get_opt_data_handle_idle_timeout() == UInt64(111111),
          "data_handle_idle_timeout round-trip")

    shim_set_opt_data_handle_pool_scan_interval(UInt64(22222))
    check(shim_get_opt_data_handle_pool_scan_interval() == UInt64(22222),
          "data_handle_pool_scan_interval round-trip")

    shim_set_opt_ipc_serv_thread_count(7)
    check(shim_get_opt_ipc_serv_thread_count() == 7,
          "ipc_serv_thread_count round-trip")

    shim_set_opt_ipc_serv_max_queue_length(1234)
    check(shim_get_opt_ipc_serv_max_queue_length() == 1234,
          "ipc_serv_max_queue_length round-trip")

    shim_set_opt_ipc_serv_max_msg_size(65536)
    check(shim_get_opt_ipc_serv_max_msg_size() == 65536,
          "ipc_serv_max_msg_size round-trip")

    shim_set_opt_no_reponse_cmd_null_flush_threshold(512)
    check(shim_get_opt_no_reponse_cmd_null_flush_threshold() == 512,
          "no_reponse_cmd_null_flush_threshold round-trip")

    log("test_opt_numeric_roundtrip: EXIT")
end

function test_opt_string_roundtrip()
    log("test_opt_string_roundtrip: ENTER")

    shim_set_opt_p2p_name("worker_group_42")
    check(shim_get_opt_p2p_name() == "worker_group_42",
          "p2p_name round-trip")

    shim_set_opt_debug("service")
    check(shim_get_opt_debug() == "service",
          "debug round-trip")

    shim_set_opt_password("secret_token")
    check(shim_get_opt_password() == "secret_token",
          "password round-trip (mock echoes back; real library masks)")

    log("test_opt_string_roundtrip: EXIT")
end

function test_opt_generic()
    log("test_opt_generic: ENTER")

    shim_set_option("Quiet", "True")
    check(shim_get_option("Quiet") == "True",
          "generic set/get: Quiet=True")

    shim_set_option("Quiet", "False")
    check(shim_get_option("Quiet") == "False",
          "generic set/get: Quiet=False")

    check(shim_get_option("no_such_option_xyz") == "",
          "generic get of unknown option returns \"\"")

    log("test_opt_generic: EXIT")
end

# ---------------------------------------------------------------- #
# Entry point                                                       #
# ---------------------------------------------------------------- #

function main()
    log("main: ENTER  nthreads=$(Threads.nthreads())  tid=$(Threads.threadid())")

    if Threads.nthreads() < 2
        log("FATAL: need at least 2 Julia threads")
        exit(1)
    end

    shim_init()
    log("main: shim_init OK")

    consumer = Threads.@spawn consumer_loop()
    sleep(0.2)
    log("main: consumer scheduled  tid=$(CONSUMER_TID[])")

    local passed = false
    try
        log("main: >>> test_echo_call")
        test_echo_call()
        log("main: <<< test_echo_call")

        log("main: >>> test_add_call")
        test_add_call()
        log("main: <<< test_add_call")

        log("main: >>> test_notify")
        test_notify()
        log("main: <<< test_notify")

        log("main: >>> test_p2p_call")
        test_p2p_call()
        log("main: <<< test_p2p_call")

        log("main: >>> test_p2p_notify")
        test_p2p_notify()
        log("main: <<< test_p2p_notify")

        log("main: >>> test_p2p_unregister")
        test_p2p_unregister()
        log("main: <<< test_p2p_unregister")

        log("main: >>> test_network_events")
        test_network_events()
        log("main: <<< test_network_events")

        log("main: >>> test_async_call")
        test_async_call()
        log("main: <<< test_async_call")

        log("main: >>> test_async_sequenced_call")
        test_async_sequenced_call()
        log("main: <<< test_async_sequenced_call")

        log("main: >>> test_uid_async_call")
        test_uid_async_call()
        log("main: <<< test_uid_async_call")

        log("main: >>> test_uid_async_sequenced_call")
        test_uid_async_sequenced_call()
        log("main: <<< test_uid_async_sequenced_call")

        log("main: >>> test_p2pname_async_call")
        test_p2pname_async_call()
        log("main: <<< test_p2pname_async_call")

        log("main: >>> test_p2pname_async_sequenced_call")
        test_p2pname_async_sequenced_call()
        log("main: <<< test_p2pname_async_sequenced_call")

        log("main: >>> test_opt_bool_roundtrip")
        test_opt_bool_roundtrip()
        log("main: <<< test_opt_bool_roundtrip")

        log("main: >>> test_opt_numeric_roundtrip")
        test_opt_numeric_roundtrip()
        log("main: <<< test_opt_numeric_roundtrip")

        log("main: >>> test_opt_string_roundtrip")
        test_opt_string_roundtrip()
        log("main: <<< test_opt_string_roundtrip")

        log("main: >>> test_opt_generic")
        test_opt_generic()
        log("main: <<< test_opt_generic")

        passed = (CHECKS_FAILED[] == 0)
    catch err
        log("main: TEST RAISED")
        showerror(stderr, err, catch_backtrace())
        println(stderr)
        flush(stderr)
    finally
        log("main: stopping consumer")
        RUNNING[] = false
        wait(consumer)
        log("main: consumer joined")
        shim_shutdown()
        log("main: shim shutdown")
    end

    log("main: DONE  checks_passed=$(CHECKS_PASSED[])  checks_failed=$(CHECKS_FAILED[])")
    passed ? exit(0) : exit(1)
end

main()