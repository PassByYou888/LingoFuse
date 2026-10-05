#!/usr/bin/env julia
#
# test_shim.jl - Integration test for the C callback shim.
#
# Design notes
# ------------
#
# Logging
#   All output goes to stderr via println + flush. Julia's @info logger
#   is deliberately not used so no logger-side buffering or
#   thread-locality can interfere with diagnosis.
#
# Library loading
#   As of Julia 1.13, ccall only accepts String, Symbol, or LazyLibrary
#   as the library argument. This script passes the shim's path as a
#   plain String; Julia caches the dlopen internally.
#
# Consumer loop and GC interaction (critical)
#   The consumer thread polls lf_shim_wait_event with a ZERO timeout.
#   A long blocking ccall (say, 100 ms) would pin the calling Julia
#   thread inside native code, and Julia's stop-the-world GC would
#   wait on that thread for up to the full ccall duration. When the
#   main thread performs an allocation, that delay manifests as a
#   stall or, if the consumer immediately re-enters a long ccall, as
#   a livelock.
#
#   With a zero timeout, each ccall is only a few microseconds. The
#   loop body then calls sleep(0.005), which yields to the scheduler
#   and lets any pending GC request complete immediately.
#
# Mock drivers and @threadcall
#   The blocking mock drivers are dispatched via @threadcall so the C
#   call runs on libuv's thread pool. This keeps the main Julia thread
#   in a GC-safe, safepoint-responsive state throughout the mock
#   driver's (potentially blocking) execution.
#
#   @threadcall cannot perform Julia-side conversions on the libuv
#   worker thread, so every argument is an isbits value (raw pointer
#   or integer) prepared on the calling thread. Strings are converted
#   with Base.unsafe_convert to Ptr{UInt8}, and the source objects are
#   kept alive across the call with GC.@preserve.
#
# Test framework
#   This script does not use @testset. A manual check() function
#   counts passes and failures. This removes the last nontrivial
#   allocation site from the harness, so any remaining hang would be
#   unambiguously attributable to the shim itself rather than to the
#   test framework's summary builder.

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
# Shim lifecycle                                                    #
# ---------------------------------------------------------------- #

function shim_init()
    ret = ccall((:lf_shim_init, SHIM), Cint, ())
    ret == 1 || error("lf_shim_init failed")
end

shim_shutdown() = ccall((:lf_shim_shutdown, SHIM), Cvoid, ())

# ---------------------------------------------------------------- #
# Registration                                                      #
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

function shim_install_network_events(conn_uid::Int64, disc_uid::Int64)
    ccall((:lf_shim_install_network_events, SHIM), Cvoid,
          (Int64, Int64), conn_uid, disc_uid)
end

shim_clear_network_events() =
    ccall((:lf_shim_clear_network_events, SHIM), Cvoid, ())

# ---------------------------------------------------------------- #
# Event accessors                                                   #
# ---------------------------------------------------------------- #

shim_wait_event(timeout_ms::Int)::Ptr{Cvoid} =
    ccall((:lf_shim_wait_event, SHIM), Ptr{Cvoid}, (Cint,), timeout_ms)

shim_event_kind(e::Ptr{Cvoid})::Int =
    ccall((:lf_shim_event_kind, SHIM), Cint, (Ptr{Cvoid},), e)

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

    name_ptr = Base.unsafe_convert(Ptr{UInt8}, name)
    in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)
    out_ptr  = pointer(out_buf)
    wrt_ptr  = Base.unsafe_convert(Ptr{Csize_t}, written)
    in_len   = length(input)
    cap_val  = cap

    GC.@preserve name input out_buf written begin
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

    name_ptr = Base.unsafe_convert(Ptr{UInt8}, name)
    in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)
    in_len   = length(input)

    GC.@preserve name input begin
        @threadcall((:mock_lf_trigger_notify, SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
                    name_ptr, in_ptr, in_len)
    end

    log("mock_trigger_notify: RETURNED")
end

function mock_trigger_network(is_connect::Bool, addr::String)
    log("mock_trigger_network: ENTER  is_connect=$is_connect  addr=$addr")

    flag     = is_connect ? Cint(1) : Cint(0)
    addr_ptr = Base.unsafe_convert(Ptr{UInt8}, addr)

    GC.@preserve addr begin
        @threadcall((:mock_lf_trigger_network_event, SHIM), Cvoid,
                    (Cint, Ptr{UInt8}),
                    flag, addr_ptr)
    end

    log("mock_trigger_network: RETURNED")
end

# ---------------------------------------------------------------- #
# Data-handle operations                                            #
# ---------------------------------------------------------------- #

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
    got = ccall((:LF_ReadBuffer, SHIM), Int64,
                (Ptr{Cvoid}, Ptr{UInt8}, Int64),
                h, pointer(buf), n)
    return buf[1:got]
end

function lf_write_buffer(h::Ptr{Cvoid}, data::Vector{UInt8})::Int64
    return ccall((:LF_WriteBuffer, SHIM), Int64,
                 (Ptr{Cvoid}, Ptr{UInt8}, Int64),
                 h, pointer(data), length(data))
end

make_app(name::String)::Ptr{Cvoid} =
    ccall((:LF_CreateApp, SHIM), Ptr{Cvoid},
          (Cstring, Cstring), name, "test")

free_app(app::Ptr{Cvoid}) =
    ccall((:LF_FreeApp, SHIM), Cvoid, (Ptr{Cvoid},), app)

# ---------------------------------------------------------------- #
# Dispatch table                                                    #
# ---------------------------------------------------------------- #

const HANDLERS = Dict{Int64, Function}()
const NEXT_UID = Ref{Int64}(0)

function alloc_uid(handler::Function)::Int64
    uid = (NEXT_UID[] += 1)
    HANDLERS[uid] = handler
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
        # Non-blocking poll. Using a long timeout (e.g. 100 ms) would
        # pin this Julia thread inside native code for the entire
        # wait, during which a stop-the-world GC cannot complete.
        # The zero-timeout call returns in microseconds; the
        # subsequent sleep then yields to the scheduler.
        e = shim_wait_event(0)
        if e == C_NULL
            sleep(POLL_INTERVAL_S)
            continue
        end

        kind = shim_event_kind(e)
        uid  = shim_event_uid(e)
        log("consumer_loop: EVENT RECEIVED  kind=$kind  uid=$uid")

        try
            if kind == 0
                handle_call_event(e, uid)
            elseif kind == 1
                handle_notify_event(e, uid)
            elseif kind == 2
                handle_network_event(e, uid, "connect")
            elseif kind == 3
                handle_network_event(e, uid, "disconnect")
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

        # Give the scheduler a chance to run pending GC work between
        # events. sleep(0) yields without actually sleeping.
        sleep(0)
    end

    log("consumer_loop: EXITING")
end

function handle_call_event(e::Ptr{Cvoid}, uid::Int64)
    log("handle_call: ENTER  uid=$uid")

    handler = get(HANDLERS, uid, nothing)
    log("handle_call: handler lookup  found=$(handler !== nothing)")
    handler === nothing && return

    input  = shim_event_input(e)
    output = shim_event_output(e)
    log("handle_call: got handles  input=$input  output=$output")

    in_bytes = lf_read_all(input)
    log("handle_call: input read  len=$(length(in_bytes))")

    result = handler(in_bytes)
    log("handle_call: handler returned  type=$(typeof(result))")

    if result isa Vector{UInt8} && !isempty(result)
        lf_write_buffer(output, result)
        log("handle_call: output written  len=$(length(result))")
    end

    log("handle_call: EXIT  uid=$uid")
end

function handle_notify_event(e::Ptr{Cvoid}, uid::Int64)
    log("handle_notify: ENTER  uid=$uid")
    handler = get(HANDLERS, uid, nothing)
    handler === nothing && return

    input = shim_event_input(e)
    in_bytes = lf_read_all(input)
    handler(in_bytes)
    log("handle_notify: EXIT  uid=$uid")
end

function handle_network_event(e::Ptr{Cvoid}, uid::Int64, which::String)
    log("handle_network: ENTER  uid=$uid  which=$which")
    handler = get(HANDLERS, uid, nothing)
    handler === nothing && return

    addr = shim_event_addr(e)
    handler(which, addr)
    log("handle_network: EXIT  uid=$uid")
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
# Tests                                                             #
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

    check(length(resp) == 4,             "add response length is 4")
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

    sleep(0.3)
    check(received[] == payload, "notify payload matches")

    free_app(app)
    log("test_notify: EXIT")
end

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

    sleep(0.3)

    check(length(events) == 2,                          "two network events received")
    if length(events) == 2
        check(events[1][1] == "connect",                "first event is connect")
        check(events[2][1] == "disconnect",             "second event is disconnect")
        check(events[1][2] == "ipc:test_endpoint",      "connect addr matches")
    end

    shim_clear_network_events()
    log("test_network_events: EXIT")
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

        log("main: >>> test_network_events")
        test_network_events()
        log("main: <<< test_network_events")

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