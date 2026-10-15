# test_p2p.jl - Acceptance test for the process-wide P2P API
# registration layer (src/p2p.jl).
#
# Coverage:
#   - register_p2p_call! / register_p2p_notify! register with the
#     shim's process-wide namespace.
#   - Duplicate registration is rejected (returns false).
#   - unregister_p2p! returns true for an existing name, false for
#     an unknown one.
#   - A registered P2P Call handler is invoked when its API is
#     dispatched through the mock driver.
#   - A registered P2P Notify handler is invoked the same way.
#   - Warmup invokes the handler up to three times at registration.
#   - An empty API name is rejected with an ArgumentError.
#
# This test uses the MOCK shim. All mock_trigger_* wrappers go
# through @threadcall to preserve the GC safepoint contract (see
# test_callback.jl for the detailed explanation).
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
include(joinpath(_SRC, "app.jl"))
include(joinpath(_SRC, "async.jl"))
include(joinpath(_SRC, "target.jl"))
include(joinpath(_SRC, "p2p.jl"))

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test_p2p] $tag  $msg")
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

function mock_trigger_p2p_call(name::AbstractString,
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

        @threadcall((:mock_lf_trigger_p2p_call, _MOCK_SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t,
                     Ptr{UInt8}, Csize_t, Ptr{Csize_t}),
                    name_ptr, in_ptr, in_len,
                    out_ptr, cap_val, wrt_ptr)
    end

    return out_buf[1:written[]]
end

function mock_trigger_p2p_notify(name::AbstractString,
                                 input::Vector{UInt8})::Nothing
    name_str = String(name)
    in_len   = length(input)

    GC.@preserve name_str input begin
        name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
        in_ptr   = isempty(input) ? Ptr{UInt8}(0) : pointer(input)

        @threadcall((:mock_lf_trigger_p2p_notify, _MOCK_SHIM), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t),
                    name_ptr, in_ptr, in_len)
    end
    return nothing
end

# -------------------------------------------------------------------- #
# Consumer startup                                                    #
# -------------------------------------------------------------------- #

println(stderr, "[test_p2p] --- consumer startup ---")

start_callback_consumer()
ck(is_callback_consumer_running(), "callback consumer is running")

# -------------------------------------------------------------------- #
# Basic registration validation                                       #
# -------------------------------------------------------------------- #

println(stderr, "[test_p2p] --- basic registration ---")

let
    threw = false
    try
        register_p2p_call!("", "empty name", _ -> UInt8[])
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "register_p2p_call! rejects an empty name")
end

let
    threw = false
    try
        register_p2p_notify!("", "empty name", _ -> nothing)
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "register_p2p_notify! rejects an empty name")
end

# -------------------------------------------------------------------- #
# P2P Call registration + dispatch                                    #
# -------------------------------------------------------------------- #

println(stderr, "[test_p2p] --- P2P Call ---")

let
    name = "jltest_p2p_call_$(getpid())"
    calls_seen = Ref{Vector{Vector{UInt8}}}(Vector{Vector{UInt8}}())
    guard = ReentrantLock()

    # Register. warmup=true (default) means the handler is invoked up
    # to three times on the calling thread before register_p2p_call!
    # returns.
    ok = register_p2p_call!(name, "test call") do in_bytes
        # Warmup calls have no observable payload to echo; the mock
        # will not dispatch until we explicitly trigger below.
        lock(guard) do
            push!(calls_seen[], in_bytes)
        end
        return copy(in_bytes)
    end

    ck(ok, "register_p2p_call! returns true on first registration")

    # Warmup should have invoked the handler up to three times.
    warmup_count = lock(guard) do
        length(calls_seen[])
    end
    ck(warmup_count >= 1 && warmup_count <= 3,
       "warmup invoked the handler 1-3 times " *
       "(observed=$(warmup_count))")

    # Clear the warmup observations so we can isolate the real dispatch.
    lock(guard) do
        empty!(calls_seen[])
    end

    # Trigger a real P2P call through the mock.
    payload = Vector{UInt8}(codeunits("p2p payload"))
    response = mock_trigger_p2p_call(name, payload)

    ck(response == payload,
       "P2P Call dispatch round-trips the payload")

    # The handler should have recorded exactly one call now.
    real_count = lock(guard) do
        length(calls_seen[])
    end
    ck(real_count == 1, "handler invoked exactly once (got $(real_count))")

    # Duplicate registration must be rejected.
    dup_ok = register_p2p_call!(name, "dup"; warmup = false) do _
        UInt8[]
    end
    ck(!dup_ok, "duplicate P2P Call registration is rejected")

    # Unregister.
    ok_un = unregister_p2p!(name)
    ck(ok_un, "unregister_p2p! returns true for an existing name")
    ck(!unregister_p2p!(name),
       "unregister_p2p! returns false on a second call")
end

# -------------------------------------------------------------------- #
# P2P Notify registration + dispatch                                  #
# -------------------------------------------------------------------- #

println(stderr, "[test_p2p] --- P2P Notify ---")

let
    name = "jltest_p2p_notify_$(getpid())"
    calls_seen = Ref{Vector{Vector{UInt8}}}(Vector{Vector{UInt8}}())
    guard = ReentrantLock()

    ok = register_p2p_notify!(name, "test notify") do in_bytes
        lock(guard) do
            push!(calls_seen[], in_bytes)
        end
        return nothing
    end

    ck(ok, "register_p2p_notify! returns true on first registration")

    lock(guard) do
        empty!(calls_seen[])
    end

    payload = Vector{UInt8}(codeunits("p2p notify"))
    mock_trigger_p2p_notify(name, payload)

    # Notify dispatch is asynchronous; poll for the call.
    deadline = time() + 2.0
    got = false
    while time() < deadline
        got = lock(guard) do
            !isempty(calls_seen[])
        end
        got && break
        sleep(0.005)
    end

    ck(got, "P2P Notify handler invoked")
    lock(guard) do
        if !isempty(calls_seen[])
            ck(calls_seen[][1] == payload,
               "Notify handler received the payload")
        end
    end

    # Duplicate registration must be rejected.
    dup_ok = register_p2p_notify!(name, "dup"; warmup = false) do _
        nothing
    end
    ck(!dup_ok, "duplicate P2P Notify registration is rejected")

    unregister_p2p!(name)
end

# -------------------------------------------------------------------- #
# Warmup control                                                      #
# -------------------------------------------------------------------- #

println(stderr, "[test_p2p] --- warmup control ---")

let
    name = "jltest_p2p_nowarmup_$(getpid())"
    count = Ref(0)
    guard = ReentrantLock()

    ok = register_p2p_call!(name, "no warmup"; warmup = false) do _
        lock(guard) do
            count[] += 1
        end
        UInt8[]
    end

    ck(ok, "register_p2p_call! with warmup=false succeeds")
    c = lock(guard) do
        count[]
    end
    ck(c == 0, "warmup=false does not invoke the handler (got $(c))")

    unregister_p2p!(name)
end

# -------------------------------------------------------------------- #
# unregister_p2p! on an unknown name                                  #
# -------------------------------------------------------------------- #

println(stderr, "[test_p2p] --- unknown unregister ---")

ck(!unregister_p2p!("jltest_never_registered_$(getpid())"),
   "unregister_p2p! returns false for an unknown name")

# -------------------------------------------------------------------- #
# Shutdown                                                            #
# -------------------------------------------------------------------- #

println(stderr, "[test_p2p] --- shutdown ---")

stop_callback_consumer()
ck(!is_callback_consumer_running(), "consumer stopped")

# -------------------------------------------------------------------- #
# Summary                                                              #
# -------------------------------------------------------------------- #

println(stderr, "")
println(stderr, "[test_p2p] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test_p2p] OK")
    exit(0)
else
    println(stderr, "[test_p2p] FAILED")
    exit(1)
end