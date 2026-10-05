# test_status.jl - Step-3 status.jl acceptance test.
#
# Coverage:
#   - NetworkEventListener with mutable handlers
#   - NetworkEventQueue: install, take_event, poll_event, clear!
#   - global_queue() singleton behaviour
#   - set_network_event with a listener and with raw functions
#   - clear_network_event
#   - drain_status / log_status
#
# The test installs a queue, triggers no network events (there is no
# peer to connect to), and verifies the queue's surface directly by
# calling the producer helper `_enqueue` on it. This isolates the
# queue's own correctness from the mesh's timing.

ENV["LINGOFUSE_TRACE"] = "0"

const _SRC = joinpath(@__DIR__, "..", "src")

include(joinpath(_SRC, "trace.jl"))
include(joinpath(_SRC, "error.jl"))
include(joinpath(_SRC, "loader.jl"))
include(joinpath(_SRC, "abi.jl"))
include(joinpath(_SRC, "shim.jl"))
include(joinpath(_SRC, "callback.jl"))
include(joinpath(_SRC, "data_handle.jl"))
include(joinpath(_SRC, "app.jl"))
include(joinpath(_SRC, "network.jl"))
include(joinpath(_SRC, "io.jl"))
include(joinpath(_SRC, "status.jl"))

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test] $tag  $msg")
    flush(stderr)
    if cond
        passed[] += 1
    else
        failed[] += 1
    end
    return cond
end

# ------------------------------------------------------------------ #
# Consumer is required by the shim's install path                    #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- consumer lifecycle ---")

start_callback_consumer()
ck(is_callback_consumer_running(), "callback consumer is running")

# ------------------------------------------------------------------ #
# NetworkEventListener                                               #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- NetworkEventListener ---")

let
    listener = NetworkEventListener()
    ck(listener.on_connect    === _noop_network_handler, "default on_connect is the no-op")
    ck(listener.on_disconnect === _noop_network_handler, "default on_disconnect is the no-op")

    captured = String[]
    listener.on_connect = addr -> push!(captured, "C:" * addr)
    set_network_event(listener)
    # Directly invoke the listener's callback to verify the wiring.
    listener.on_connect("test-endpoint")
    ck(captured == ["C:test-endpoint"], "listener.on_connect wiring works")

    clear_network_event()
end

# ------------------------------------------------------------------ #
# set_network_event with raw functions                               #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- set_network_event (raw functions) ---")

let
    installed = Ref(false)
    set_network_event(
        (kind, addr) -> (installed[] = (kind == "connect")),
        (kind, addr) -> (installed[] = (kind == "disconnect")),
    )
    # We cannot easily trigger a real event, so this only verifies the
    # install path does not throw and that clearing succeeds.
    ck(true, "set_network_event with functions did not throw")
    clear_network_event()
    ck(true, "clear_network_event did not throw")
end

# ------------------------------------------------------------------ #
# NetworkEventQueue                                                  #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- NetworkEventQueue ---")

let
    q = NetworkEventQueue(64)
    ck(!is_installed(q), "fresh queue is not installed")
    ck(isempty_queue(q), "fresh queue is empty")
    ck(pending(q) == 0, "fresh queue has zero pending events")

    # Simulate producer-side traffic directly on the queue's channel.
    _enqueue(q, :connect,    "addr-1")
    _enqueue(q, :disconnect, "addr-2")
    _enqueue(q, :connect,    "addr-3")
    ck(pending(q) == 3, "pending() reports 3 buffered events")

    e1 = poll_event(q)
    ck(e1 == (:connect, "addr-1"), "poll_event returns the first event in FIFO order")
    e2 = take_event(q; timeout = 1.0)
    ck(e2 == (:disconnect, "addr-2"), "take_event returns the second event")

    e3 = poll_event(q)
    ck(e3 == (:connect, "addr-3"), "poll_event returns the third event")
    ck(isempty_queue(q), "queue is empty after consuming all events")
    ck(poll_event(q) === nothing, "poll_event returns nothing on an empty queue")

    # Refill and clear
    _enqueue(q, :connect, "a")
    _enqueue(q, :connect, "b")
    clear!(q)
    ck(isempty_queue(q), "clear! drains the queue")

    # close_queue! is idempotent, and after it the queue is unusable.
    close_queue!(q)
    close_queue!(q)
    ck(true, "close_queue! is idempotent")
end

# ------------------------------------------------------------------ #
# install! / uninstall!                                              #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- install! / uninstall! ---")

let
    q = NetworkEventQueue()
    ck(!is_installed(q), "queue is not installed initially")
    install!(q)
    ck(is_installed(q), "queue is installed after install!")
    install!(q)  # idempotent
    ck(is_installed(q), "install! is idempotent")

    uninstall!(q)
    ck(!is_installed(q), "queue is not installed after uninstall!")
    uninstall!(q)  # idempotent
    ck(true, "uninstall! is idempotent")

    close_queue!(q)
end

# ------------------------------------------------------------------ #
# global_queue singleton                                             #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- global_queue singleton ---")

let
    a = global_queue()
    b = global_queue()
    ck(a === b, "global_queue returns the same instance on every call")
    ck(a isa NetworkEventQueue, "global_queue returns a NetworkEventQueue")
end

# ------------------------------------------------------------------ #
# Status queue helpers                                               #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- status queue helpers ---")

let
    # Drain any pre-existing messages.
    empty!(drain_status(1024))

    # Post a handful and drain.
    post_status("jltest-marker-1")
    post_status("jltest-marker-2")
    post_status("jltest-marker-3")
    sleep(0.1)

    msgs = drain_status(16)
    ck(length(msgs) >= 3, "drain_status returned at least 3 messages")
    ck(any(m -> occursin("jltest-marker-1", m), msgs),
       "drain_status sees the first injected message")
    ck(any(m -> occursin("jltest-marker-3", m), msgs),
       "drain_status sees the third injected message")

    # drain_status(0) is a no-op.
    post_status("jltest-marker-4")
    sleep(0.1)
    ck(isempty(drain_status(0)), "drain_status(0) returns an empty vector")

    # log_status writes to the given IO; just make sure it works and
    # returns the number of messages.
    n = log_status(devnull; max_messages = 16)
    ck(n >= 0, "log_status returns a non-negative count ($n)")
end

# ------------------------------------------------------------------ #
# Shutdown                                                           #
# ------------------------------------------------------------------ #
println(stderr, "[test] --- shutdown ---")

stop_callback_consumer()
ck(true, "stop_callback_consumer completed")

# ------------------------------------------------------------------ #
# Summary                                                            #
# ------------------------------------------------------------------ #

println(stderr, "")
println(stderr, "[test] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test] OK")
    exit(0)
else
    println(stderr, "[test] FAILED")
    exit(1)
end