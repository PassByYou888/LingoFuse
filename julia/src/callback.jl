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
# lf_shim_set_output. This module therefore uses only the payload
# accessors (shim_event_input_data, shim_event_input_len,
# shim_event_result_data, shim_event_result_len, shim_set_output) and
# never calls LF_ReadBuffer or LF_WriteBuffer from the consumer.
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
#
# Handler registry
# ----------------
# All four event kinds share ONE uid registry (HANDLERS). uids are
# allocated from a single monotonically increasing counter, so a uid
# cannot be reused and there is no ambiguity between event kinds.
#
# The four handlers have three distinct signatures:
#
#   Call / Async result  :: Function(Vector{UInt8})
#   Notify               :: Function(Vector{UInt8})
#   Network              :: Function(String, String)
#
# Call and Async result share a signature by design: an async result
# is delivered to the user exactly like a Call response, as a
# Julia-owned Vector{UInt8} carrying the raw payload.
#
# Async result dispatch
# ---------------------
# The ASYNC_RESULT branch was added in this revision. The dispatch
# function _dispatch_async_result reads the result payload through
# shim_read_result (a Julia-owned copy) and invokes the handler with
# Base.invokelatest, matching every other dispatch site.

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

"""
    _read_event_result(e) -> Vector{UInt8}

Return a Julia-owned copy of the event's async result snapshot. See
`shim_read_result` for the underlying contract.
"""
function _read_event_result(e::Ptr{Cvoid})::Vector{UInt8}
    return shim_read_result(e)
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

"""
    _dispatch_async_result(e, uid)

Dispatch one LF_SHIM_EVENT_ASYNC_RESULT event.

The event's user_id field carries the user_token supplied when the
async request was issued; the handler registered under that token is
invoked with a Julia-owned copy of the async result payload.

A token with no registered handler is not an error: an async request
may complete after its caller has already given up on it (a Python-
style "abandoned" timeout). In that case the event is silently
dropped. The C-side shim always signals completion of the event, so
no resource leaks.
"""
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

# ------------------------------------------------------------------ #
# Consumer loop                                                      #
# ------------------------------------------------------------------ #

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

# ------------------------------------------------------------------ #
# Consumer lifecycle                                                 #
# ------------------------------------------------------------------ #

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

# ------------------------------------------------------------------ #
# Registration wrappers                                              #
# ------------------------------------------------------------------ #

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

"""
    register_async_handler(handler::Function) -> Int64

Allocate a token for an asynchronous result handler.

The handler is invoked with a single `Vector{UInt8}` argument, the
async result payload, whenever an LF_SHIM_EVENT_ASYNC_RESULT event
carrying this token arrives. The caller is responsible for pairing
the returned token with an async dispatch call (shim_async_call and
friends) and for releasing it via release_async_handler once no
further result is expected.

There is no automatic release: an async request that never completes
leaves its token registered until the process exits. The caller
(the future / do-block layer in async.jl) is responsible for
releasing the token after the request resolves or times out.
"""
function register_async_handler(handler::Function)::Int64
    return _alloc_uid(handler)
end

"""
    release_async_handler(token::Int64) -> Nothing

Release an async handler token allocated by register_async_handler.

Idempotent: releasing an unknown or already-released token is a
no-op. The C shim may still deliver a late event for the token; such
an event finds no handler and is dropped (see
`_dispatch_async_result`).
"""
function release_async_handler(token::Int64)::Nothing
    _release_uid(token)
    return nothing
end

# ------------------------------------------------------------------ #
# Network event handlers                                             #
# ------------------------------------------------------------------ #

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

# ------------------------------------------------------------------ #
# Exports                                                            #
# ------------------------------------------------------------------ #

export start_callback_consumer,
       stop_callback_consumer,
       is_callback_consumer_running,
       register_call_with_handler,
       register_notify_with_handler,
       register_async_handler,
       release_async_handler,
       install_network_handlers,
       clear_network_handlers