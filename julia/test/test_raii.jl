# test_raii.jl - Step-2 RAII acceptance test for DataHandle and App.
#
# Coverage:
#   1. DataHandle construction, write/read, dispose, is_disposed.
#   2. App creation, register_call!, local_call, unregister!, dispose!.
#   3. Warmup: a handler is invoked three times on the main thread at
#      registration (three payload shapes), so no path of its
#      invocation is left for the consumer thread to compile.
#   4. Closure parity: an anonymous closure works through the same
#      path as a named function, thanks to the warmup.
#   5. Lifetime: a disposed handle/app raises the appropriate error
#      on any subsequent use.
#
# DUAL MODE
# ---------
# The test runs in one of two modes, selected by shim_is_real():
#
#   REAL mode:  LINGOFUSE_SHIM points at lf_shim_real.dll. Both
#               registration (via the shim) and invocation (via
#               LF_LocalCall) reach the real LingoFuse library, so
#               the full register -> call -> unregister chain is
#               exercised end-to-end.
#
#   MOCK mode:  LINGOFUSE_SHIM points at lf_shim_mock.dll. The
#               registration reaches the mock's registry. The
#               invocation goes through the mock driver
#               (mock_lf_trigger_call), which spawns a real thread and
#               invokes the registered trampoline exactly like a C4
#               worker would. This exercises the cross-thread callback
#               path without requiring a live network.
#
# Because the mock library does not implement LF_LocalCall /
# LF_Unregister, the assertions that depend on those functions are
# reported as INFO (skipped) in MOCK mode. This is a documented
# limitation of the mock, not a defect in the test.
#
# NOTE: uid.jl MUST be included before abi.jl (see test_io.jl).

ENV["LINGOFUSE_TRACE"] = "0"

const _SRC = joinpath(@__DIR__, "..", "src")

include(joinpath(_SRC, "trace.jl"))
include(joinpath(_SRC, "error.jl"))
include(joinpath(_SRC, "uid.jl"))
include(joinpath(_SRC, "loader.jl"))
include(joinpath(_SRC, "abi.jl"))
include(joinpath(_SRC, "shim.jl"))
include(joinpath(_SRC, "callback.jl"))
include(joinpath(_SRC, "data_handle.jl"))
include(joinpath(_SRC, "app.jl"))

passed = Ref(0)
failed = Ref(0)
skipped = Ref(0)

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

function skip(msg::String)
    println(stderr, "[test] SKIP  $msg")
    flush(stderr)
    skipped[] += 1
    return nothing
end

# ------------------------------------------------------------------ #
# Mock driver                                                         #
# ------------------------------------------------------------------ #
#
# Present only in MOCK mode; not referenced in REAL mode.
# @threadcall is used (not plain ccall) because the mock's trigger
# blocks on the consumer while the consumer allocates Julia heap
# objects. A plain ccall would hold the calling thread outside a GC
# safepoint and deadlock the allocation.

function _mock_trigger_call(api_name::AbstractString,
                            payload::Vector{UInt8};
                            cap::Int = 4096)::Vector{UInt8}
    name_str = String(api_name)
    out_buf  = zeros(UInt8, cap)
    written  = Ref{Csize_t}(0)
    in_len   = length(payload)
    cap_val  = cap

    GC.@preserve name_str payload out_buf written begin
        name_ptr = Base.unsafe_convert(Ptr{UInt8}, name_str)
        in_ptr   = isempty(payload) ? Ptr{UInt8}(0) : pointer(payload)
        out_ptr  = pointer(out_buf)
        wrt_ptr  = Base.unsafe_convert(Ptr{Csize_t}, written)

        @threadcall((:mock_lf_trigger_call, LINGOFUSE_SHIM_PATH), Cvoid,
                    (Ptr{UInt8}, Ptr{UInt8}, Csize_t,
                     Ptr{UInt8}, Csize_t, Ptr{Csize_t}),
                    name_ptr, in_ptr, in_len,
                    out_ptr, cap_val, wrt_ptr)
    end

    return out_buf[1:written[]]
end

const _MODE = shim_is_real() ? "REAL" : "MOCK"
println(stderr, "[test] mode = $(_MODE)  shim = $(LINGOFUSE_SHIM_PATH)")

# ------------------------------------------------------------------
# DataHandle tests  (identical in both modes)
# ------------------------------------------------------------------
println(stderr, "[test] --- DataHandle ---")

let
    dh = DataHandle("test_api")
    ck(!is_disposed(dh), "fresh handle is not disposed")
    ck(buffer_size(dh) == 0, "fresh handle has size 0")
    ck(cursor_position(dh) == 0, "fresh handle cursor is at 0")

    write_buffer!(dh, UInt8[0x61, 0x62, 0x63])
    ck(buffer_size(dh) == 3, "after write 3 bytes, size = 3")
    ck(cursor_position(dh) == 3, "after write 3 bytes, cursor = 3")

    set_cursor_position!(dh, 0)
    got = read_buffer!(dh, 3)
    ck(got == UInt8[0x61, 0x62, 0x63], "read back the 3 bytes")

    set_cursor_position!(dh, 0)
    got_exact = read_buffer_exact!(dh, 3)
    ck(got_exact == UInt8[0x61, 0x62, 0x63],
       "read_buffer_exact! reads 3 bytes")

    set_cursor_position!(dh, 0)
    threw = false
    try
        read_buffer_exact!(dh, 5)
    catch e
        threw = e isa LingoFuseIoError
    end
    ck(threw, "read_buffer_exact! throws on short read")
    ck(cursor_position(dh) == 0, "cursor unchanged after failed exact read")

    dispose!(dh)
    ck(is_disposed(dh), "handle is disposed after dispose!")
    dispose!(dh)  # idempotent

    threw = false
    try
        buffer_size(dh)
    catch e
        threw = e isa LingoFuseObjectDisposedError
    end
    ck(threw, "using a disposed handle throws LingoFuseObjectDisposedError")
end

# ------------------------------------------------------------------
# String I/O tests
# ------------------------------------------------------------------
println(stderr, "[test] --- String I/O ---")

let
    dh = DataHandle("str_api")
    n = write_string!(dh, "hello, 世界 🌍")
    ck(n > 0, "write_string! reports bytes written ($n)")
    set_cursor_position!(dh, 0)
    s = read_string!(dh)
    ck(s == "hello, 世界 🌍", "round-trip UTF-8 string matches")
    dispose!(dh)
end

let
    dh = DataHandle("str_api")
    write_string!(dh, "abc")
    write_string!(dh, "def")
    set_cursor_position!(dh, 0)
    ck(read_string!(dh) == "abc", "first string is 'abc'")
    ck(read_string!(dh) == "def", "second string is 'def'")
    dispose!(dh)
end

# ------------------------------------------------------------------
# App tests (with consumer)
# ------------------------------------------------------------------
println(stderr, "[test] --- App (with consumer) ---")

start_callback_consumer()

try
    app = App("RaiiTestApp", "RAII acceptance test")
    ck(!is_disposed(app), "fresh App is not disposed")
    ck(app_name(app) == "RaiiTestApp", "app_name returns the configured name")

    counter = Ref(0)

    # Anonymous closure that captures `counter`. This is the exact
    # shape that historically triggered the consumer-thread hang.
    handler = (in_bytes::Vector{UInt8}) -> begin
        counter[] += 1
        return copy(in_bytes)
    end

    ok = register_call!(app, "echo", "Echo the payload", handler)
    ck(ok, "register_call! returned true")
    ck(counter[] == 3,
       "warmup invoked the handler 3 times (counter = $(counter[]))")

    # ---- Real invocation: mode-dependent ----
    if shim_is_real()
        # Registration and invocation both reach the real library.
        param = DataHandle("echo")
        write_string!(param, "hello")
        result = local_call(app, param)
        ck(counter[] == 4,
           "real call invoked the handler once more " *
           "(counter = $(counter[]))")
        sz = buffer_size(result)
        ck(sz > 0, "result has non-zero size ($sz)")
        set_cursor_position!(result, 0)
        echoed = read_string!(result)
        ck(echoed == "hello",
           "local_call round-trips through the closure handler")
        dispose!(result)
        dispose!(param)
    else
        # Mock mode: the mock has no LF_LocalCall. Drive the handler
        # through the mock's Call trigger, which spawns a native
        # thread and invokes the registered trampoline exactly like a
        # C4 worker would.
        payload = Vector{UInt8}(codeunits("hello"))
        response = _mock_trigger_call("echo", payload)
        ck(counter[] == 4,
           "mock call invoked the handler once more " *
           "(counter = $(counter[]))")
        ck(response == payload,
           "mock driver round-trips through the closure handler")
    end

    # ---- Duplicate registration (mode-independent) ----
    ok = register_call!(app, "echo", "dup", handler; warmup = false)
    ck(!ok, "duplicate register_call! returns false")

    # ---- Unregister: only testable in REAL mode ----
    if shim_is_real()
        ok = unregister!(app, "echo")
        ck(ok, "unregister! returns true for an existing API")
        ok = unregister!(app, "echo")
        ck(!ok, "unregister! returns false for an already-removed API")
    else
        skip("unregister! (mock library does not implement LF_Unregister)")
    end

    # ---- Named function handler: mode-dependent invocation ----
    function named_handler(in_bytes::Vector{UInt8})
        return UInt8[0x4E]   # "N"
    end
    ok = register_call!(app, "named", "Named handler", named_handler)
    ck(ok, "register_call! with a named function returns true")

    if shim_is_real()
        param2 = DataHandle("named")
        result2 = local_call(app, param2)
        set_cursor_position!(result2, 0)
        ck(read_buffer!(result2, 1) == UInt8[0x4E],
           "named handler returned the expected single byte")
        dispose!(result2)
        dispose!(param2)
    else
        response2 = _mock_trigger_call("named", UInt8[])
        ck(response2 == UInt8[0x4E],
           "named handler returned the expected single byte (mock)")
    end

    # ---- Lifetime ----
    dispose!(app)
    ck(is_disposed(app), "App is disposed after dispose!")

    threw = false
    try
        register_call!(app, "x", "y", handler; warmup = false)
    catch e
        threw = e isa LingoFuseObjectDisposedError
    end
    ck(threw, "register_call! on a disposed App throws")
finally
    stop_callback_consumer()
end

println(stderr, "")
println(stderr, "[test] results: passed=$(passed[])  " *
                "failed=$(failed[])  skipped=$(skipped[])")
if failed[] == 0
    println(stderr, "[test] OK")
    exit(0)
else
    println(stderr, "[test] FAILED")
    exit(1)
end