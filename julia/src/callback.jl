# callback.jl - Julia-side consumer and dispatcher for the C shim.
#
# Consumer / native handle isolation
# ----------------------------------
# The consumer NEVER touches the native input or output data handles.
# A native handle is owned by the C4 worker thread that runs the
# callback; reading or writing it from a different thread would enter
# the real LingoFuse library on the wrong thread and deadlock on the
# library's per-handle locks.
#
# The shim solves this by snapshotting the input payload on the
# trampoline thread and accepting the consumer's response through
# lf_shim_set_output. This module therefore uses only the three
# payload accessors (shim_event_input_data, shim_event_input_len,
# shim_set_output) and never calls LF_ReadBuffer or LF_WriteBuffer
# from the consumer.
#
# World age
# ---------
# The consumer task is spawned by start_callback_consumer, which
# captures the task's world age at that moment. Any handler defined
# AFTER the spawn (an anonymous closure created inside a function
# body, an @eval-ed definition, a method added to an existing
# function) belongs to a later world age and is invisible to the
# consumer through a direct call. Julia reports this as
#
#     MethodError: no method matching ...
#     (method too new to be called from this world context.)
#
# Every user-handler invocation in this module therefore goes through
# Base.invokelatest, which forces the call to use the latest world
# age regardless of the caller's. This is the documented remedy for
# the error above and matches the practice recommended for
# long-running tasks that dispatch dynamically-registered callbacks.
#
# Restart contract
# ----------------
# start_callback_consumer / stop_callback_consumer may be called more
# than once in the same process. Each stop_callback_consumer fully
# quiesces the consumer task before calling into the shim, so the
# shim's re-initialisation path (which resets g_shutdown) is safe.
# See c_ext/lf_shim.c for the underlying contract.

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

# ------------------------------------------------------------------ #
# Event payload helpers                                              #
# ------------------------------------------------------------------ #

"""
    _read_event_input(e) -> Vector{UInt8}

Return a Julia-owned copy of the event's input snapshot. See
`shim_read_input` for the underlying contract.
"""
function _read_event_input(e::Ptr{Cvoid})::Vector{UInt8}
    return shim_read_input(e)
end

# ------------------------------------------------------------------ #
# Event dispatch                                                     #
# ------------------------------------------------------------------ #
#
# The user handler is always invoked through Base.invokelatest. This
# is required because the consumer task was spawned at a specific
# world age, and a handler defined after that point belongs to a
# later world age. A direct call would fail with
# "method too new to be called from this world context".

function _dispatch_call(e::Ptr{Cvoid}, uid::Int64)
    trace("callback: dispatch CALL uid=$(uid)")
    handler = _lookup_handler(uid)
    if handler === nothing
        trace("callback: no handler for uid=$(uid)")
        return nothing
    end

    in_bytes = _read_event_input(e)
    trace("callback: handler input length=$(length(in_bytes))")

    result = Base.invokelatest(handler, in_bytes)

    if result isa AbstractVector{UInt8} && !isempty(result)
        trace("callback: handler output length=$(length(result))")
        ok = shim_set_output(e, result)
        if !ok
            # The shim's allocation of the output buffer failed (or the
            # event pointer was invalid). The caller will receive an
            # empty response. This is the only signal we can produce
            # from the consumer thread; report it and continue.
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

    # Check the shim's initialisation result. A false return means the
    # shim could not set up its queue; without this check the consumer
    # would start and silently poll an uninitialised queue forever.
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

    # Order matters (see c_ext/lf_shim.c, "Shutdown contract"):
    #   1. Ask the consumer loop to stop.
    #   2. Wait for the consumer task to finish (it must no longer be
    #      polling the shim queue).
    #   3. THEN call shim_shutdown. After this point the shim's
    #      trampolines will observe g_shutdown within one timeout
    #      period and free their events. Because the consumer has
    #      already exited, no event can be dequeued after being freed.
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

const _NETWORK_HANDLER_UIDS = Ref{NTuple{2,Int64}}((0, 0))

function install_network_handlers(
    on_connect::Union{Function,Nothing},
    on_disconnect::Union{Function,Nothing}
)::Nothing
    c_uid = on_connect    === nothing ? 0 : _alloc_uid(on_connect)
    d_uid = on_disconnect === nothing ? 0 : _alloc_uid(on_disconnect)

    # Install on the native side first. If this fails, release the
    # freshly allocated uids so they do not leak, and rethrow. The
    # previously installed handlers remain active.
    try
        shim_install_network_events(c_uid, d_uid)
    catch
        c_uid != 0 && _release_uid(c_uid)
        d_uid != 0 && _release_uid(d_uid)
        rethrow()
    end

    # Native install succeeded. Now release the previous handlers and
    # publish the new uids.
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
       register_call_with_handler,
       register_notify_with_handler,
       install_network_handlers,
       clear_network_handlers