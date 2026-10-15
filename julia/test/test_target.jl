# test_target.jl - Acceptance test for src/target.jl.
#
# Coverage:
#   A. Target construction and parameter validation
#   B. Payload form handling (_build_param)
#   C. Future + async result round-trip (mock driver)
#   D. sequenced_future round-trip (mock driver)
#   E. do-block async_call
#   F. do-block async_sequenced_call
#   G. Soft timeout (Future abandoned)
#   H. Cross-addressing checks: UIDTarget and P2PNameTarget exercise
#      the same code path
#
# This file uses the MOCK shim for async dispatch (shim_async_call
# and friends) and the REAL LingoFuse library for the raw abi.jl
# functions (LF_CreateData, LF_GetSize, ...). The synchronous call /
# notify paths go through the REAL library and require a live
# network, so they are only smoke-tested: the test verifies that the
# code path is reachable and that the payload is built correctly,
# not that a peer responds.
#
# Mock driver threading
# ---------------------
# Every mock_trigger_* wrapper below dispatches through @threadcall,
# as required by the GC-safepoint contract explained in
# test_callback.jl.
#
# Exit code: 0 on success, 1 on any failure.

ENV["LINGOFUSE_TRACE"] = "0"

# ------------------------------------------------------------------ #
# Mock shim pin                                                      #
# ------------------------------------------------------------------ #
# This test drives callbacks through the mock shim's trigger
# functions (mock_lf_trigger_call, mock_lf_trigger_async_result, ...).
# It must therefore load lf_shim_mock.dll, not lf_shim_real.dll.
#
# src/shim.jl prefers the real shim by design (see its file header);
# the choice is pinned here explicitly. A single Julia process cannot
# load both shims, so the mock and real test groups must run in
# separate processes; see test/runtests.jl for the full rationale.
#
# The mock shim is built by `julia/build.ps1` (or `julia/build.sh`).
# If it is missing, fail fast with an actionable message instead of
# silently falling back to the real shim.

const _MOCK_SHIM_PATH =
    joinpath(@__DIR__, "..", "c_ext", "lf_shim_mock.dll")

if !isfile(_MOCK_SHIM_PATH)
    println(stderr, "FATAL: this test requires the mock shim.")
    println(stderr, "  Expected: $_MOCK_SHIM_PATH")
    println(stderr, "  Build it with:")
    println(stderr, "      cd julia")
    println(stderr, "      .\\build.ps1")
    exit(1)
end

ENV["LINGOFUSE_SHIM"] = _MOCK_SHIM_PATH

const _SRC = joinpath(@__DIR__, "..", "src")

include(joinpath(_SRC, "trace.jl"))
include(joinpath(_SRC, "error.jl"))
include(joinpath(_SRC, "uid.jl"))
include(joinpath(_SRC, "loader.jl"))
include(joinpath(_SRC, "abi.jl"))
include(joinpath(_SRC, "shim.jl"))
include(joinpath(_SRC, "callback.jl"))
include(joinpath(_SRC, "data_handle.jl"))
include(joinpath(_SRC, "binio.jl"))
include(joinpath(_SRC, "async.jl"))
include(joinpath(_SRC, "target.jl"))

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test_target] $tag  $msg")
    flush(stderr)
    if cond
        passed[] += 1
    else
        failed[] += 1
    end
    return cond
end

# -------------------------------------------------------------------- #
# Mock driver bindings                                                 #
# -------------------------------------------------------------------- #

const _MOCK_SHIM = LINGOFUSE_SHIM_PATH

function mock_trigger_async_result(token::Int64,
                                   data::Vector{UInt8})::Nothing
    n = length(data)
    if n == 0
        @threadcall((:mock_lf_trigger_async_result, _MOCK_SHIM),
                    Cvoid,
                    (Int64, Ptr{UInt8}, Csize_t),
                    token, Ptr{UInt8}(0), Csize_t(0))
        return nothing
    end

    GC.@preserve data begin
        ptr = pointer(data)
        @threadcall((:mock_lf_trigger_async_result, _MOCK_SHIM),
                    Cvoid,
                    (Int64, Ptr{UInt8}, Csize_t),
                    token, ptr, Csize_t(n))
    end
    return nothing
end

# -------------------------------------------------------------------- #
# A. Target construction                                              #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- A. target construction ---")

let t = app_target("CalcApp")
    ck(t isa AppTarget, "app_target returns an AppTarget")
    ck(t.app_name == "CalcApp", "app_name preserved")
    ck(t.default_timeout_ms == 5000, "default timeout is 5000 ms")
end

let t = app_target("CalcApp"; timeout_ms = 1234)
    ck(t.default_timeout_ms == 1234, "custom timeout preserved")
end

let
    threw = false
    try
        app_target("")
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "app_target rejects an empty name")
end

let
    threw = false
    try
        app_target("x"; timeout_ms = -1)
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "app_target rejects a negative timeout")
end

let
    hex_uid = "ab"^32
    t = uid_target(hex_uid)
    ck(t isa UIDTarget, "uid_target accepts a 64-char hex string")
    ck(uid_to_hex(t.uid) == hex_uid, "hex string round-trips")
end

let
    bytes_uid = collect(UInt8, 1:32)
    t = uid_target(bytes_uid)
    ck(t isa UIDTarget, "uid_target accepts a 32-byte vector")
    ck(uid_to_bytes(t.uid) == bytes_uid, "byte vector round-trips")
end

let
    tuple_uid = ntuple(i -> UInt8(i), 32)
    t = uid_target(tuple_uid)
    ck(t.uid == tuple_uid, "uid_target accepts an LFShimUID tuple")
end

let
    threw = false
    try
        uid_target("not a UID")
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_target rejects a malformed hex string")
end

let
    threw = false
    try
        uid_target(12345)
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_target rejects a non-bytes / non-string argument")
end

let t = p2pname_target("workers")
    ck(t isa P2PNameTarget, "p2pname_target returns a P2PNameTarget")
    ck(t.group_name == "workers", "group name preserved")
end

let
    threw = false
    try
        p2pname_target("")
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "p2pname_target rejects an empty name")
end

# show methods
let
    ck(occursin("CalcApp", sprint(show, app_target("CalcApp"))),
       "show(AppTarget) mentions the app name")
    ck(occursin("UIDTarget(", sprint(show, uid_target("ab"^32))),
       "show(UIDTarget) mentions the constructor name")
    ck(occursin("ab"^16, sprint(show, uid_target("ab"^32))),
       "show(UIDTarget) contains the hex UID prefix")
    ck(occursin("workers", sprint(show, p2pname_target("workers"))),
       "show(P2PNameTarget) mentions the group name")
end

# -------------------------------------------------------------------- #
# B. Payload forms                                                    #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- B. payload forms ---")

let dh = _build_param("echo", nothing)
    try
        ck(buffer_size(dh) == 0, "payload nothing -> empty buffer")
    finally
        dispose!(dh)
    end
end

let dh = _build_param("echo", UInt8[0x41, 0x42, 0x43])
    try
        ck(buffer_size(dh) == 3, "payload bytes -> 3-byte buffer")
        set_cursor_position!(dh, 0)
        ck(read_buffer!(dh, 3) == UInt8[0x41, 0x42, 0x43],
           "payload bytes round-trip")
    finally
        dispose!(dh)
    end
end

let dh = _build_param("echo", d -> write_int32!(d, Int32(42)))
    try
        ck(buffer_size(dh) == 4, "payload function -> 4-byte buffer")
        set_cursor_position!(dh, 0)
        ck(read_int32(dh) == Int32(42), "payload function value preserved")
    finally
        dispose!(dh)
    end
end

let
    threw = false
    try
        _build_param("echo", 42)
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "payload Int is rejected")
end

let
    threw = false
    try
        _build_param("echo", "raw string")
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "payload String is rejected (must be bytes or function)")
end

# -------------------------------------------------------------------- #
# Consumer + startup                                                  #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- consumer startup ---")

start_callback_consumer()
ck(is_callback_consumer_running(), "callback consumer is running")

# -------------------------------------------------------------------- #
# C. Future end-to-end (mock driver)                                  #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- C. future end-to-end ---")

let
    t = app_target("TargetFutureApp"; timeout_ms = 5000)
    fut = future(t, "echo", UInt8[0x01, 0x02, 0x03])
    ck(fut isa Future, "future returns a Future")
    ck(!isready(fut), "Future is initially pending")

    # Trigger the mock result through the token that was recorded
    # when `future` issued shim_async_call.
    payload = UInt8[0x41, 0x42, 0x43, 0x44]
    mock_trigger_async_result(fut.token, payload)

    deadline = time() + 2.0
    while time() < deadline
        isready(fut) && break
        sleep(0.005)
    end

    ck(isready(fut), "Future resolved after the mock trigger")
    ck(!is_abandoned(fut), "Future was not abandoned")
    r = fetch(fut)
    ck(r == payload, "fetch returns the exact payload")
end

# -------------------------------------------------------------------- #
# D. Sequenced future end-to-end                                      #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- D. sequenced_future end-to-end ---")

let
    t = app_target("TargetSeqApp"; timeout_ms = 5000)
    fut = sequenced_future(t, "echo", UInt8[0x10, 0x20])
    ck(fut isa Future, "sequenced_future returns a Future")

    payload = UInt8[0xAA, 0xBB]
    mock_trigger_async_result(fut.token, payload)

    deadline = time() + 2.0
    while time() < deadline
        isready(fut) && break
        sleep(0.005)
    end

    ck(isready(fut), "sequenced Future resolved after the mock trigger")
    ck(fetch(fut) == payload, "sequenced fetch returns the payload")
end

# -------------------------------------------------------------------- #
# E. do-block async_call                                              #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- E. do-block async_call ---")

let
    t = app_target("TargetDoBlockApp"; timeout_ms = 5000)
    guard = ReentrantLock()
    captured = Ref{Any}(nothing)

    fut = async_call(t, "echo", UInt8[0x55]) do result, err
        lock(guard) do
            captured[] = (result, err)
        end
    end

    ck(fut isa Future, "async_call returns a Future")

    payload = UInt8[0xDE, 0xAD, 0xBE, 0xEF]
    mock_trigger_async_result(fut.token, payload)

    deadline = time() + 2.0
    got = false
    while time() < deadline
        got = lock(guard) do
            captured[] !== nothing
        end
        got && break
        sleep(0.005)
    end

    ck(got, "do-block callback fired within the timeout window")
    lock(guard) do
        if captured[] !== nothing
            (res, err) = captured[]
            ck(err === nothing, "do-block err is nothing")
            ck(res == payload, "do-block result matches the payload")
        else
            ck(false, "do-block captured state is unset")
        end
    end
end

# -------------------------------------------------------------------- #
# F. do-block async_sequenced_call                                    #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- F. do-block async_sequenced_call ---")

let
    t = app_target("TargetDoBlockSeqApp"; timeout_ms = 5000)
    guard = ReentrantLock()
    captured = Ref{Any}(nothing)

    fut = async_sequenced_call(t, "echo", UInt8[0x01]) do result, err
        lock(guard) do
            captured[] = (result, err)
        end
    end

    ck(fut isa Future, "async_sequenced_call returns a Future")

    payload = UInt8[0x77, 0x88]
    mock_trigger_async_result(fut.token, payload)

    deadline = time() + 2.0
    got = false
    while time() < deadline
        got = lock(guard) do
            captured[] !== nothing
        end
        got && break
        sleep(0.005)
    end

    ck(got, "sequenced do-block callback fired")
    lock(guard) do
        if captured[] !== nothing
            (res, err) = captured[]
            ck(err === nothing, "sequenced do-block err is nothing")
            ck(res == payload, "sequenced do-block result matches")
        end
    end
end

# -------------------------------------------------------------------- #
# G. Soft timeout                                                     #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- G. soft timeout ---")

let
    # Short timeout; we will NOT trigger the mock result.
    t = app_target("TargetTimeoutApp"; timeout_ms = 100)
    fut = future(t, "echo", UInt8[])

    ck(!isready(fut), "Future pending immediately after dispatch")

    deadline = time() + 2.0
    while time() < deadline
        isready(fut) && break
        sleep(0.01)
    end

    ck(isready(fut), "Future resolved by timeout")
    ck(is_abandoned(fut), "Future is marked abandoned")

    threw = false
    caught = nothing
    try
        fetch(fut)
    catch e
        threw = true
        caught = e
    end
    ck(threw, "fetch throws on an abandoned Future")
    ck(caught isa LingoFuseTimeoutError,
       "the thrown error is a LingoFuseTimeoutError")
end

# -------------------------------------------------------------------- #
# H. Cross-addressing checks                                          #
# -------------------------------------------------------------------- #
#
# UIDTarget and P2PNameTarget share the same Future pipeline. This
# section exercises both to make sure the routing dispatch does not
# break the async machinery.

println(stderr, "[test_target] --- H. cross-addressing ---")

let
    uid = collect(UInt8, 1:32)
    t = uid_target(uid; timeout_ms = 5000)
    fut = future(t, "whoami", UInt8[])
    ck(fut isa Future, "UIDTarget future returns a Future")

    payload = UInt8[0x01, 0x02]
    mock_trigger_async_result(fut.token, payload)

    deadline = time() + 2.0
    while time() < deadline
        isready(fut) && break
        sleep(0.005)
    end
    ck(isready(fut), "UIDTarget Future resolved")
    ck(fetch(fut) == payload, "UIDTarget fetch returns the payload")
end

let
    t = p2pname_target("worker_group"; timeout_ms = 5000)
    fut = future(t, "whoami", UInt8[])
    ck(fut isa Future, "P2PNameTarget future returns a Future")

    payload = UInt8[0xAA]
    mock_trigger_async_result(fut.token, payload)

    deadline = time() + 2.0
    while time() < deadline
        isready(fut) && break
        sleep(0.005)
    end
    ck(isready(fut), "P2PNameTarget Future resolved")
    ck(fetch(fut) == payload, "P2PNameTarget fetch returns the payload")
end

# -------------------------------------------------------------------- #
# Shutdown                                                            #
# -------------------------------------------------------------------- #

println(stderr, "[test_target] --- shutdown ---")

stop_callback_consumer()
ck(!is_callback_consumer_running(), "consumer stopped")

# -------------------------------------------------------------------- #
# Summary                                                              #
# -------------------------------------------------------------------- #

println(stderr, "")
println(stderr, "[test_target] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test_target] OK")
    exit(0)
else
    println(stderr, "[test_target] FAILED")
    exit(1)
end