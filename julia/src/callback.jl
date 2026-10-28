# callback.jl - Julia-side consumer and dispatcher for the C shim.
#
# This revision adds task-local storage of the sender's UID and P2P name
# for every dispatched Call / Notify event. Users read them via
# current_input_uid() / current_input_p2p_name() inside their handler.

const HANDLERS      = Dict{Int64, Function}()
const HANDLERS_LOCK = ReentrantLock()
const NEXT_UID      = Ref{Int64}(0)

function _alloc_uid(handler::Function)::Int64
    lock(HANDLERS_LOCK) do
        uid = (NEXT_UID[] += 1)
        HANDLERS[uid] = handler
        trace("callback: allocated uid=$(uid)")
        return uid
    end
end

function _release_uid(uid::Int64)
    lock(HANDLERS_LOCK) do
        delete!(HANDLERS, uid)
    end
    trace("callback: released uid=$(uid)")
    return
end

function _lookup_handler(uid::Int64)::Union{Function,Nothing}
    lock(HANDLERS_LOCK) do
        return get(HANDLERS, uid, nothing)
    end
end

const CONSUMER_RUNNING = Ref{Bool}(false)
const CONSUMER_TASK    = Ref{Union{Task,Nothing}}(nothing)
const CONSUMER_TID     = Ref{Int}(-1)

const _POLL_INTERVAL_SEC = 0.005

function _read_event_input(e::Ptr{Cvoid})::Vector{UInt8}
    return shim_read_input(e)
end

function _read_event_result(e::Ptr{Cvoid})::Vector{UInt8}
    return shim_read_result(e)
end

function _dispatch_call(e::Ptr{Cvoid}, uid::Int64)
    trace("callback: dispatch CALL uid=$(uid)")
    handler = _lookup_handler(uid)
    if handler === nothing
        trace("callback: no handler for uid=$(uid)")
        return nothing
    end

    in_bytes = _read_event_input(e)
    from_uid = shim_read_from_uid(e)
    from_p2p = shim_read_from_p2p_name(e)
    task_local_storage(:lf_current_uid, from_uid)
    task_local_storage(:lf_current_p2p_name, from_p2p)
    trace("callback: handler input length=$(length(in_bytes))")

    result = Base.invokelatest(handler, in_bytes)

    if result isa AbstractVector{UInt8} && !isempty(result)
        trace("callback: handler output length=$(length(result))")
        ok = shim_set_output(e, result)
        if !ok
            println(stderr,
                    "[LingoFuse] shim_set_output failed for uid=", uid,
                    " (response length=", length(result),
                    "); the caller will receive an empty response.")
            flush(stderr)
        end
    else
        trace("callback: handler returned no output")
    end
    return nothing
end

function _dispatch_notify(e::Ptr{Cvoid}, uid::Int64)
    trace("callback: dispatch NOTIFY uid=$(uid)")
    handler = _lookup_handler(uid)
    handler === nothing && return nothing
    in_bytes = _read_event_input(e)
    from_uid = shim_read_from_uid(e)
    from_p2p = shim_read_from_p2p_name(e)
    task_local_storage(:lf_current_uid, from_uid)
    task_local_storage(:lf_current_p2p_name, from_p2p)
    Base.invokelatest(handler, in_bytes)
    return nothing
end

function _dispatch_network(e::Ptr{Cvoid}, uid::Int64, which::String)
    trace("callback: dispatch NETWORK uid=$(uid) which=$(which)")
    handler = _lookup_handler(uid)
    handler === nothing && return nothing
    addr = shim_event_addr(e)
    addr === nothing && (addr = "")
    Base.invokelatest(handler, which, addr)
    return nothing
end

function _dispatch_async_result(e::Ptr{Cvoid}, uid::Int64)
    trace("callback: dispatch ASYNC_RESULT uid=$(uid)")
    handler = _lookup_handler(uid)
    if handler === nothing
        trace("callback: no handler for async token=$(uid) (dropped)")
        return nothing
    end

    result_bytes = _read_event_result(e)
    trace("callback: async result length=$(length(result_bytes))")

    Base.invokelatest(handler, result_bytes)
    return nothing
end

function _consumer_loop()
    CONSUMER_TID[] = Threads.threadid()
    trace("callback: consumer STARTED on tid=$(CONSUMER_TID[])")

    while CONSUMER_RUNNING[]
        e = shim_wait_event(0)
        if e == C_NULL
            sleep(_POLL_INTERVAL_SEC)
            continue
        end

        try
            kind = shim_event_kind(e)
            uid  = shim_event_user_id(e)
            trace("callback: consumer EVENT kind=$(kind) uid=$(uid)")

            if kind == LF_SHIM_EVENT_CALL
                _dispatch_call(e, uid)
            elseif kind == LF_SHIM_EVENT_NOTIFY
                _dispatch_notify(e, uid)
            elseif kind == LF_SHIM_EVENT_NETWORK_CONNECT
                _dispatch_network(e, uid, "connect")
            elseif kind == LF_SHIM_EVENT_NETWORK_DISCONNECT
                _dispatch_network(e, uid, "disconnect")
            elseif kind == LF_SHIM_EVENT_ASYNC_RESULT
                _dispatch_async_result(e, uid)
            end
        catch err
            println(stderr,
                    "[LingoFuse] callback handler raised: ",
                    sprint(showerror, err))
            flush(stderr)
        finally
            shim_complete_event(e)
        end

        sleep(0)
    end

    trace("callback: consumer EXITING")
    return nothing
end

function start_callback_consumer()::Nothing
    CONSUMER_RUNNING[] && return nothing

    if Threads.nthreads() < 2
        throw(LingoFuseStateError(
            "start_callback_consumer requires at least 2 Julia threads. " *
            "Restart Julia with --threads=2 (or more)."
        ))
    end

    if !shim_init()
        throw(LingoFuseLoadError(
            LINGOFUSE_SHIM_PATH,
            "lf_shim_init returned failure"
        ))
    end

    CONSUMER_RUNNING[] = true
    CONSUMER_TASK[]    = Threads.@spawn _consumer_loop()

    for _ in 1:100
        CONSUMER_TID[] != -1 && break
        sleep(0.001)
    end

    if CONSUMER_TID[] == 1
        CONSUMER_RUNNING[] = false
        t = CONSUMER_TASK[]
        if t !== nothing; wait(t); end
        CONSUMER_TASK[] = nothing
        CONSUMER_TID[]  = -1
        throw(LingoFuseStateError(
            "start_callback_consumer: the consumer task was scheduled " *
            "onto the main Julia thread, which would deadlock. " *
            "Restart Julia with --threads=2 (or more)."
        ))
    end

    trace("callback: consumer running on tid=$(CONSUMER_TID[])")
    return nothing
end

function stop_callback_consumer()::Nothing
    trace("callback: stopping consumer")

    CONSUMER_RUNNING[] = false
    t = CONSUMER_TASK[]
    if t !== nothing
        wait(t)
    end
    CONSUMER_TASK[] = nothing
    CONSUMER_TID[]  = -1

    try
        shim_shutdown()
    catch err
        println(stderr,
                "[LingoFuse] shim_shutdown raised: ",
                sprint(showerror, err))
        flush(stderr)
    end

    trace("callback: consumer stopped")
    return nothing
end

is_callback_consumer_running()::Bool = CONSUMER_RUNNING[]

function current_input_uid()::Union{Nothing, NTuple{32, UInt8}}
    tls = task_local_storage()
    haskey(tls, :lf_current_uid) || return nothing
    return tls[:lf_current_uid]::NTuple{32, UInt8}
end

function current_input_p2p_name()::Union{Nothing, String}
    tls = task_local_storage()
    haskey(tls, :lf_current_p2p_name) || return nothing
    return tls[:lf_current_p2p_name]::String
end

function register_call_with_handler(app_hnd::Ptr{Cvoid},
                                    name::AbstractString,
                                    desc::AbstractString,
                                    handler::Function)::Bool
    uid = _alloc_uid(handler)
    ok  = shim_register_call(app_hnd, name, desc, uid)
    ok || _release_uid(uid)
    return ok
end

function register_notify_with_handler(app_hnd::Ptr{Cvoid},
                                      name::AbstractString,
                                      desc::AbstractString,
                                      handler::Function)::Bool
    uid = _alloc_uid(handler)
    ok  = shim_register_notify(app_hnd, name, desc, uid)
    ok || _release_uid(uid)
    return ok
end

function register_async_handler(handler::Function)::Int64
    return _alloc_uid(handler)
end

function release_async_handler(token::Int64)::Nothing
    _release_uid(token)
    return nothing
end

const _NETWORK_HANDLER_UIDS = Ref{NTuple{2,Int64}}((0, 0))

function install_network_handlers(
    on_connect::Union{Function,Nothing},
    on_disconnect::Union{Function,Nothing}
)::Nothing
    c_uid = on_connect    === nothing ? 0 : _alloc_uid(on_connect)
    d_uid = on_disconnect === nothing ? 0 : _alloc_uid(on_disconnect)

    try
        shim_install_network_events(c_uid, d_uid)
    catch
        c_uid != 0 && _release_uid(c_uid)
        d_uid != 0 && _release_uid(d_uid)
        rethrow()
    end

    prev = _NETWORK_HANDLER_UIDS[]
    prev[1] != 0 && _release_uid(prev[1])
    prev[2] != 0 && _release_uid(prev[2])
    _NETWORK_HANDLER_UIDS[] = (c_uid, d_uid)

    return nothing
end

function clear_network_handlers()::Nothing
    shim_clear_network_events()
    prev = _NETWORK_HANDLER_UIDS[]
    prev[1] != 0 && _release_uid(prev[1])
    prev[2] != 0 && _release_uid(prev[2])
    _NETWORK_HANDLER_UIDS[] = (0, 0)
    return nothing
end

export start_callback_consumer,
       stop_callback_consumer,
       is_callback_consumer_running,
       current_input_uid,
       current_input_p2p_name,
       register_call_with_handler,
       register_notify_with_handler,
       register_async_handler,
       release_async_handler,
       install_network_handlers,
       clear_network_handlers