# status.jl - Network event listeners and status queue helpers.
#
# This module is the Julia counterpart of the Python binding's
# lingofuse.network_events and the C# binding's NetworkEvents.cs. It
# wraps the process-global network event callbacks with two
# higher-level APIs:
#
#   NetworkEventListener    Object-oriented listener base type.
#   NetworkEventQueue       Bounded, thread-safe event queue.
#
# Both are built on top of install_network_handlers /
# clear_network_handlers in callback.jl, which in turn drive the
# shim's network event trampolines.
#
# Callback contract
# -----------------
# Network callbacks run on the shim's consumer thread, not on the
# thread that installed them. Inside a callback:
#
#   - Do NOT touch UI or any thread-affine resource.
#   - Do NOT call any blocking LingoFuse function.
#   - Do NOT let an exception escape. The consumer swallows it and
#     logs it, but a slow or throwing handler delays every subsequent
#     event.
#
# NetworkEventQueue enforces the last point structurally: the
# installed handler does nothing but push a tuple onto a Channel.
#
# Semantics
# ---------
# "Connect" fires the first time a client receives a service API-info
# broadcast, not at the TCP handshake. It fires once per connection
# lifecycle and again after an automatic reconnect.
#
# "Disconnect" fires once per physical link loss. An automatic
# reconnect does not emit a Disconnect for the reconnect attempt
# itself.
#
# Replace semantics
# -----------------
# LF_Set_Network_Event installs a process-global pair of callbacks.
# Calling set_network_event a second time discards the previous pair
# entirely, even if the new call passes `nothing` for one side. To
# replace only one side, pass the current handler for the other side
# explicitly, or call clear_network_event first.

# ================================================================== #
# NetworkEventListener                                               #
# ================================================================== #

"""
    NetworkEventListener(on_connect, on_disconnect)

Object-oriented network event listener.

Both fields are `Function` values; each receives a single
`String` argument (the endpoint address). The default constructor
installs no-op handlers.

Set `on_connect` and `on_disconnect` to closures that capture the
listener's state, or assign after construction:

    listener = NetworkEventListener()
    listener.on_connect = addr -> println("online : ", addr)
    listener.on_disconnect = addr -> println("offline: ", addr)
    set_network_event(listener)

The listener instance is captured by the installed trampolines for
as long as it is installed, so it will not be garbage-collected.
"""
mutable struct NetworkEventListener
    on_connect::Function
    on_disconnect::Function
end

_noop_network_handler(_addr::String) = nothing

NetworkEventListener() =
    NetworkEventListener(_noop_network_handler, _noop_network_handler)

# ================================================================== #
# NetworkEventQueue                                                  #
# ================================================================== #

const _DEFAULT_QUEUE_SIZE = 10000

"""
    NetworkEventQueue(max_size = 10000)

Thread-safe queue that receives network events.

Events are pushed by a handler installed via `install!`, and consumed
by the application through `take_event` / `poll_event`. The queue is
bounded; when full, `install!`'s handler blocks on `put!`, applying
natural back-pressure.

The underlying LF_Set_Network_Event slot is process-global. There is
exactly one listener at a time, so use the process-wide singleton
returned by `global_queue()` rather than constructing independent
instances and calling `install!` on each.
"""
mutable struct NetworkEventQueue
    channel::Channel{Tuple{Symbol,String}}
    installed::Bool
    lock::ReentrantLock
end

NetworkEventQueue(max_size::Integer = _DEFAULT_QUEUE_SIZE) =
    NetworkEventQueue(
        Channel{Tuple{Symbol,String}}(Int(max_size)),
        false,
        ReentrantLock(),
    )

# ------------------------------------------------------------------ #
# Process-wide singleton                                             #
# ------------------------------------------------------------------ #

const _GLOBAL_QUEUE      = Ref{Union{NetworkEventQueue,Nothing}}(nothing)
const _GLOBAL_QUEUE_LOCK = ReentrantLock()

"""
    global_queue() -> NetworkEventQueue

Return the process-wide singleton `NetworkEventQueue`, creating it on
first call. Because the underlying native slot is process-global,
there is exactly one useful queue per process.
"""
function global_queue()::NetworkEventQueue
    lock(_GLOBAL_QUEUE_LOCK) do
        if _GLOBAL_QUEUE[] === nothing
            _GLOBAL_QUEUE[] = NetworkEventQueue()
        end
        return _GLOBAL_QUEUE[]::NetworkEventQueue
    end
end

# ------------------------------------------------------------------ #
# Producer side (runs on the consumer thread)                        #
# ------------------------------------------------------------------ #

function _enqueue(q::NetworkEventQueue, kind::Symbol, addr::String)
    try
        put!(q.channel, (kind, addr))
    catch
        # Channel was closed during shutdown; drop the event.
    end
    return nothing
end

# ------------------------------------------------------------------ #
# Install / uninstall                                                #
# ------------------------------------------------------------------ #

"""
    install!(q::NetworkEventQueue) -> Nothing

Install `q` as the receiver of network events. Idempotent.

If a different listener is already installed (whether through this
queue or through a direct `set_network_event` call), it is replaced
and its handlers are released.
"""
function install!(q::NetworkEventQueue)::Nothing
    already = lock(q.lock) do
        was = q.installed
        q.installed = true
        was
    end
    already && return nothing

    install_network_handlers(
        (kind, addr) -> kind == "connect"    ? _enqueue(q, :connect, addr)    : nothing,
        (kind, addr) -> kind == "disconnect" ? _enqueue(q, :disconnect, addr) : nothing,
    )
    return nothing
end

"""
    uninstall!(q::NetworkEventQueue) -> Nothing

Stop receiving network events. Idempotent. Does not drain the queue.
"""
function uninstall!(q::NetworkEventQueue)::Nothing
    was = lock(q.lock) do
        prev = q.installed
        q.installed = false
        prev
    end
    was || return nothing
    clear_network_handlers()
    return nothing
end

"""
    is_installed(q::NetworkEventQueue) -> Bool

Return `true` while `q` is receiving events.
"""
is_installed(q::NetworkEventQueue)::Bool = q.installed

# ------------------------------------------------------------------ #
# Consumer side                                                      #
# ------------------------------------------------------------------ #

"""
    take_event(q::NetworkEventQueue; timeout::Real = Inf) -> (Symbol, String)

Block until an event is available, or until `timeout` seconds elapse.

Returns a tuple `(kind, addr)` where `kind` is `:connect` or
`:disconnect`. Throws `LingoFuseStateError` on timeout.
"""
function take_event(q::NetworkEventQueue;
                    timeout::Real = Inf)::Tuple{Symbol,String}
    if isinf(timeout)
        return take!(q.channel)
    end
    deadline = time() + Float64(timeout)
    while time() < deadline
        isready(q.channel) && return take!(q.channel)
        sleep(0.005)
    end
    throw(LingoFuseStateError(
        "NetworkEventQueue.take_event: timed out after $(timeout) s"
    ))
end

"""
    poll_event(q::NetworkEventQueue) -> Union{Tuple{Symbol,String},Nothing}

Non-blocking counterpart of `take_event`. Returns `nothing` when no
event is available.
"""
function poll_event(q::NetworkEventQueue)::Union{Tuple{Symbol,String},Nothing}
    isready(q.channel) || return nothing
    return take!(q.channel)
end

"""
    pending(q::NetworkEventQueue) -> Int

Return the approximate number of events currently buffered.
"""
pending(q::NetworkEventQueue)::Int = Base.n_avail(q.channel)

"""
    isempty_queue(q::NetworkEventQueue) -> Bool

Return `true` when no event is currently buffered.
"""
isempty_queue(q::NetworkEventQueue)::Bool = !isready(q.channel)

"""
    clear!(q::NetworkEventQueue) -> Nothing

Drain all buffered events without processing them.
"""
function clear!(q::NetworkEventQueue)::Nothing
    while isready(q.channel)
        try
            take!(q.channel)
        catch
            break
        end
    end
    return nothing
end

"""
    close_queue!(q::NetworkEventQueue) -> Nothing

Uninstall the queue and close its channel. After this, the queue
cannot be reused.
"""
function close_queue!(q::NetworkEventQueue)::Nothing
    uninstall!(q)
    try
        close(q.channel)
    catch
        # Already closed.
    end
    return nothing
end

# ================================================================== #
# Convenience wrappers                                               #
# ================================================================== #

"""
    set_network_event(listener::NetworkEventListener) -> Nothing

Install a `NetworkEventListener` as the process-global network event
receiver. Replaces any previously installed handlers.
"""
function set_network_event(listener::NetworkEventListener)::Nothing
    install_network_handlers(
        (kind, addr) -> kind == "connect"    ? listener.on_connect(addr)    : nothing,
        (kind, addr) -> kind == "disconnect" ? listener.on_disconnect(addr) : nothing,
    )
    return nothing
end

"""
    set_network_event(on_connect, on_disconnect) -> Nothing

Install two function-based handlers.

Each function receives `(kind::String, addr::String)` where `kind` is
`"connect"` or `"disconnect"`. Passing `nothing` for one side
disables that event.

This is a replace operation: calling it a second time discards any
previously installed handlers.
"""
function set_network_event(
    on_connect::Union{Function,Nothing},
    on_disconnect::Union{Function,Nothing},
)::Nothing
    install_network_handlers(on_connect, on_disconnect)
    return nothing
end

"""
    clear_network_event() -> Nothing

Remove both network event handlers. Idempotent.
"""
function clear_network_event()::Nothing
    clear_network_handlers()
    return nothing
end

# ================================================================== #
# Status queue helpers                                               #
# ================================================================== #
#
# status_count, get_status, post_status are defined in network.jl.
# The helpers below add a batch drain and a formatted log callback.

"""
    drain_status(max_messages::Integer = 64) -> Vector{String}

Retrieve up to `max_messages` pending status messages in FIFO order.

The function stops early when `get_status` returns an empty string.
This can only happen in a corner case (a user explicitly posting an
empty message, or a race with another producer), so the early-exit
rule is a pragmatic choice that keeps the common path efficient.

Returns an empty vector when the queue is empty.
"""
function drain_status(max_messages::Integer = 64)::Vector{String}
    max_messages < 0 && throw(ArgumentError("max_messages must be non-negative"))
    max_messages == 0 && return String[]

    n = status_count()
    n <= 0 && return String[]

    out = String[]
    for _ in 1:min(n, Int(max_messages))
        msg = get_status()
        isempty(msg) && break
        push!(out, msg)
    end
    return out
end

"""
    log_status(io::IO = stderr; max_messages::Integer = 64) -> Int

Drain the status queue and write each message to `io` with a
`[LF]` prefix. Returns the number of messages written.

Diagnostic helper; intended for scripts that want to surface the
native log stream without setting up a dedicated handler.
"""
function log_status(io::IO = stderr;
                    max_messages::Integer = 64)::Int
    messages = drain_status(max_messages)
    for m in messages
        println(io, "[LF] ", m)
    end
    flush(io)
    return length(messages)
end

# ================================================================== #
# Exports                                                            #
# ================================================================== #

export NetworkEventListener,
       NetworkEventQueue,
       global_queue,
       install!,
       uninstall!,
       is_installed,
       take_event,
       poll_event,
       pending,
       isempty_queue,
       clear!,
       close_queue!,
       set_network_event,
       clear_network_event,
       drain_status,
       log_status