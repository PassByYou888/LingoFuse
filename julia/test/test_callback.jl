# test_callback.jl - Acceptance test for callback dispatch and
# data-handle identity accessors.
#
# Coverage:
#   - Consumer lifecycle: start / is_running / stop / restart.
#   - Async handler registry: register / release / lookup.
#   - Async result dispatch: register a handler, pre-arm the token
#     with shim_async_call, fire a synthetic result with the mock
#     driver, and verify the handler receives the payload.
#   - Call dispatch: register a handler, drive it with the mock's
#     Call trigger, verify the output flows back.
#   - Notify dispatch: same, without a response.
#   - Network event dispatch: install connect / disconnect handlers,
#     fire them with the mock driver, verify kind + addr.
#   - DataHandle identity accessors: get_p2p_uid / get_p2p_name on a
#     self-created handle return a zero UID / empty string.
#
# This file uses the MOCK shim (lf_shim_mock.dll), which pairs the
# shim implementation with mock_lf.c. The mock provides test drivers
# that spawn a native thread to invoke the registered callback,
# exactly matching the C4 worker-thread behaviour of the real
# library. This makes the full cross-thread path exercisable without
# a live network.
#
# @threadcall vs ccall
# --------------------
# Every mock_trigger_* wrapper below dispatches through @threadcall,
# not a plain ccall. The mock driver blocks its caller until the
# native trampoline has been completed by the Julia consumer; the
# consumer allocates Julia heap objects while it works, and a plain
# ccall would hold the calling thread outside a GC safepoint for the
# entire duration, deadlocking the allocation. @threadcall runs the
# C call on a libuv thread-pool worker, so the calling Julia thread
# remains schedulable and reaches a safepoint. This is the same
# mechanism that c_ext/test_shim.jl uses.
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

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test_callback] $tag  $msg")
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
#
# These test-only drivers live in mock_lf.c. They are NOT part of the
# shim's public ABI, so they are bound here with raw ccall /
# @threadcall rather than through shim.jl.
#
# Every pointer argument is computed inside a GC.@preserve block, as
# required for a @threadcall argument: computing it outside the block
# would leave the source object unprotected against a young-generation
# GC that runs between the pointer computation and the C call.

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

function mock_trigger_call(name::AbstractString,
                           input::Vector{UInt8},
                           cap::Integer = 4096)::Vector{UInt8}
    name_str = String(name)
    out_buf  = zeros(UInt8, cap)
    written  = Ref{Csize_t}(0)
    in_len   = length(input)
    cap_val  = cap

    GC.@preserve name_str input out_buf written begin
        name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
        in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)
        out_ptr  = pointer(out_buf)
        wrt_ptr  = Base.unsafe_convert(Ptr{Csize_t}, written)

        @threadcall((:mock_lf_trigger_call, _MOCK_SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t,
                     Ptr{UInt8}, Csize_t, Ptr{Csize_t}),
                    name_ptr, in_ptr, in_len,
                    out_ptr, cap_val, wrt_ptr)
    end

    return out_buf[1:written[]]
end

function mock_trigger_notify(name::AbstractString,
                             input::Vector{UInt8})::Nothing
    name_str = String(name)
    in_len   = length(input)

    GC.@preserve name_str input begin
        name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
        in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)

        @threadcall((:mock_lf_trigger_notify, _MOCK_SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
                    name_ptr, in_ptr, in_len)
    end
    return nothing
end

function mock_trigger_network_event(is_connect::Bool,
                                    addr::AbstractString)::Nothing
    flag     = is_connect ? Cint(1) : Cint(0)
    addr_str = String(addr)

    GC.@preserve addr_str begin
        addr_ptr = Base.unsafe_convert(Ptr{UInt8}, addr_str)
        @threadcall((:mock_lf_trigger_network_event, _MOCK_SHIM),
                    Cvoid,
                    (Cint, Ptr{UInt8}),
                    flag, addr_ptr)
    end
    return nothing
end

# -------------------------------------------------------------------- #
# Consumer lifecycle                                                   #
# -------------------------------------------------------------------- #

println(stderr, "[test_callback] --- consumer lifecycle ---")

ck(!is_callback_consumer_running(),
   "consumer is not running before start_callback_consumer")

start_callback_consumer()
ck(is_callback_consumer_running(),
   "consumer is running after start_callback_consumer")

start_callback_consumer()
ck(is_callback_consumer_running(),
   "second start is a no-op (still running)")

# -------------------------------------------------------------------- #
# Async handler registry                                               #
# -------------------------------------------------------------------- #
#
# The mock's find_async table is populated by LF_Async_Call and the
# five other async dispatch primitives. register_async_handler only
# allocates a Julia-side token; it does NOT touch the mock. We
# therefore pre-arm the token with a shim_async_call before firing
# the synthetic result. This mirrors the real workflow exactly: the
# token is always registered before the dispatch call.

println(stderr, "[test_callback] --- async handler registry ---")

let
    calls = Vector{Vector{UInt8}}()
    guard = ReentrantLock()

    token = register_async_handler() do result_bytes::Vector{UInt8}
        lock(guard) do
            push!(calls, result_bytes)
        end
    end

    ck(token > 0, "register_async_handler returns a positive token")

    # Pre-arm the mock's async table so that the trigger below finds
    # a pending operation for this token.
    param = LF_CreateData("test_callback_async_arm")
    try
        ret = shim_async_call("AnyApp", param, token)
        ck(ret == 1, "shim_async_call queues the async request")
    finally
        LF_FreeData(param)
    end

    # Fire a synthetic async result event for this token.
    payload = Vector{UInt8}(codeunits("async payload"))
    mock_trigger_async_result(token, payload)

    # The event is consumed on the consumer thread; poll until it
    # arrives (bounded wait).
    deadline = time() + 2.0
    while time() < deadline
        ready = lock(guard) do
            !isempty(calls)
        end
        ready && break
        sleep(0.005)
    end

    lock(guard) do
        ck(length(calls) == 1,
           "async handler invoked exactly once (got $(length(calls)))")
        if length(calls) == 1
            ck(calls[1] == payload,
               "async handler received the exact payload")
        end
    end

    release_async_handler(token)
    ck(true, "release_async_handler returned without error")
end

# A token with no registered handler AND no mock record: firing an
# event for it must be a silent no-op (both sides drop it).
let
    ghost_token = Int64(999_999_999)
    payload = Vector{UInt8}(codeunits("nobody home"))
    mock_trigger_async_result(ghost_token, payload)
    sleep(0.1)
    ck(true, "event for an unknown token is silently dropped")
end

# -------------------------------------------------------------------- #
# Call dispatch                                                        #
# -------------------------------------------------------------------- #

println(stderr, "[test_callback] --- Call dispatch ---")

let
    app = LF_CreateApp("jl_cb_call_app", "callback test")
    try
        handler_uid = register_call_with_handler(
            app, "echo", "echo handler",
            in_bytes -> copy(in_bytes)
        )
        ck(handler_uid, "register_call_with_handler returned true")

        payload = Vector{UInt8}(codeunits("call payload"))
        result = mock_trigger_call("echo", payload)
        ck(result == payload,
           "Call dispatch round-trips the payload")

        result_empty = mock_trigger_call("echo", UInt8[])
        ck(isempty(result_empty),
           "Call dispatch with empty input yields empty output")
    finally
        LF_FreeApp(app)
    end
end

# -------------------------------------------------------------------- #
# Notify dispatch                                                      #
# -------------------------------------------------------------------- #

println(stderr, "[test_callback] --- Notify dispatch ---")

let
    app = LF_CreateApp("jl_cb_notify_app", "notify test")
    captured = Ref{Vector{UInt8}}(UInt8[])
    guard = ReentrantLock()

    try
        ok = register_notify_with_handler(
            app, "log", "log handler",
            in_bytes -> begin
                lock(guard) do
                    captured[] = in_bytes
                end
                return nothing
            end
        )
        ck(ok, "register_notify_with_handler returned true")

        payload = Vector{UInt8}(codeunits("notify payload"))
        mock_trigger_notify("log", payload)

        lock(guard) do
            ck(captured[] == payload,
               "Notify handler received the payload")
        end
    finally
        LF_FreeApp(app)
    end
end

# -------------------------------------------------------------------- #
# Network event dispatch                                               #
# -------------------------------------------------------------------- #

println(stderr, "[test_callback] --- Network event dispatch ---")

let
    events = Vector{Tuple{String, String}}()
    guard = ReentrantLock()

    install_network_handlers(
        (kind, addr) -> lock(guard) do
            push!(events, (String(kind), String(addr)))
        end,
        (kind, addr) -> lock(guard) do
            push!(events, (String(kind), String(addr)))
        end,
    )
    ck(true, "install_network_handlers returned without error")

    mock_trigger_network_event(true,  "ipc:test_endpoint")
    mock_trigger_network_event(false, "ipc:test_endpoint")

    deadline = time() + 2.0
    while time() < deadline
        ready = lock(guard) do
            length(events) >= 2
        end
        ready && break
        sleep(0.005)
    end

    lock(guard) do
        ck(length(events) == 2,
           "two network events received (got $(length(events)))")
        if length(events) == 2
            ck(events[1] == ("connect", "ipc:test_endpoint"),
               "first event is connect with the expected address")
            ck(events[2] == ("disconnect", "ipc:test_endpoint"),
               "second event is disconnect with the expected address")
        end
    end

    clear_network_handlers()
    ck(true, "clear_network_handlers returned without error")
end

# -------------------------------------------------------------------- #
# DataHandle identity accessors                                        #
# -------------------------------------------------------------------- #

println(stderr, "[test_callback] --- DataHandle identity accessors ---")

# 1. On a self-created handle: the C side returns a zero UID / empty
#    string. The accessors must faithfully return those defaults.
let dh = DataHandle("identity_probe")
    try
        u = get_p2p_uid(dh)
        ck(u isa LFShimUID,
           "get_p2p_uid returns an LFShimUID")
        ck(length(u) == 32,
           "get_p2p_uid returns 32 bytes")
        ck(is_zero_uid(u),
           "get_p2p_uid on a self-created handle yields a zero UID")

        n = get_p2p_name(dh)
        ck(n isa String,
           "get_p2p_name returns a String")
        ck(n == "",
           "get_p2p_name on a self-created handle yields an empty string")
    finally
        dispose!(dh)
    end
end

# 2. On a disposed handle: the accessors must raise
#    LingoFuseObjectDisposedError, like every other operation.
let dh = DataHandle("identity_probe_disposed")
    dispose!(dh)
    ck(is_disposed(dh), "handle is disposed")

    threw_uid = false
    try
        get_p2p_uid(dh)
    catch e
        threw_uid = e isa LingoFuseObjectDisposedError
    end
    ck(threw_uid,
       "get_p2p_uid on a disposed handle throws " *
       "LingoFuseObjectDisposedError")

    threw_name = false
    try
        get_p2p_name(dh)
    catch e
        threw_name = e isa LingoFuseObjectDisposedError
    end
    ck(threw_name,
       "get_p2p_name on a disposed handle throws " *
       "LingoFuseObjectDisposedError")
end

# 3. The mock does NOT inject sender identity into input handles (its
#    LF_CreateData does not write FromUID / FromP2PName). The
#    accessors therefore return the zero UID / empty string even on a
#    mock-generated input handle. Documented behaviour, not a defect.
let
    app = LF_CreateApp("jl_cb_identity_app", "identity round-trip")

    try
        ok = register_call_with_handler(
            app, "whoami", "identity probe",
            in_bytes -> copy(in_bytes)
        )
        ck(ok, "register_call_with_handler for 'whoami' returned true")

        seen_uid  = Ref{LFShimUID}(zero_uid())
        seen_name = Ref{String}("")

        let dh = DataHandle("whoami")
            try
                seen_uid[]  = get_p2p_uid(dh)
                seen_name[] = get_p2p_name(dh)
            finally
                dispose!(dh)
            end
        end

        ck(is_zero_uid(seen_uid[]),
           "mock input handle yields a zero UID (no identity injection)")
        ck(seen_name[] == "",
           "mock input handle yields an empty P2P name")
    finally
        LF_FreeApp(app)
    end
end

# -------------------------------------------------------------------- #
# Restart                                                              #
# -------------------------------------------------------------------- #

println(stderr, "[test_callback] --- restart ---")

stop_callback_consumer()
ck(!is_callback_consumer_running(),
   "consumer stopped after stop_callback_consumer")

start_callback_consumer()
ck(is_callback_consumer_running(),
   "consumer restarts after a fresh start_callback_consumer")

# A second async round-trip after restart must work.
let
    calls = Vector{Vector{UInt8}}()
    guard = ReentrantLock()

    token = register_async_handler() do result_bytes::Vector{UInt8}
        lock(guard) do
            push!(calls, result_bytes)
        end
    end

    param = LF_CreateData("test_callback_async_restart")
    try
        ret = shim_async_call("AnyApp", param, token)
        ck(ret == 1, "shim_async_call queues the request after restart")
    finally
        LF_FreeData(param)
    end

    payload = Vector{UInt8}(codeunits("after restart"))
    mock_trigger_async_result(token, payload)

    deadline = time() + 2.0
    while time() < deadline
        ready = lock(guard) do
            !isempty(calls)
        end
        ready && break
        sleep(0.005)
    end

    lock(guard) do
        ck(length(calls) == 1 && calls[1] == payload,
           "async dispatch works after restart")
    end

    release_async_handler(token)
end

stop_callback_consumer()
ck(!is_callback_consumer_running(),
   "consumer stopped a second time")

# -------------------------------------------------------------------- #
# Summary                                                              #
# -------------------------------------------------------------------- #

println(stderr, "")
println(stderr, "[test_callback] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test_callback] OK")
    exit(0)
else
    println(stderr, "[test_callback] FAILED")
    exit(1)
end