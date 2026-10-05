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

# ------------------------------------------------------------------
# DataHandle tests
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
    ck(got_exact == UInt8[0x61, 0x62, 0x63], "read_buffer_exact! reads 3 bytes")

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
    ck(counter[] == 3, "warmup invoked the handler 3 times (counter = $(counter[]))")

    # Real call
    param = DataHandle("echo")
    write_string!(param, "hello")
    result = local_call(app, param)
    ck(counter[] == 4, "real call invoked the handler once more (counter = $(counter[]))")
    sz = buffer_size(result)
    ck(sz > 0, "result has non-zero size ($sz)")
    set_cursor_position!(result, 0)
    echoed = read_string!(result)
    ck(echoed == "hello", "local_call round-trips through the closure handler")
    dispose!(result)
    dispose!(param)

    # Duplicate registration
    ok = register_call!(app, "echo", "dup", handler; warmup = false)
    ck(!ok, "duplicate register_call! returns false")

    # Unregister
    ok = unregister!(app, "echo")
    ck(ok, "unregister! returns true for an existing API")
    ok = unregister!(app, "echo")
    ck(!ok, "unregister! returns false for an already-removed API")

    # A named function must work on the same code path.
    function named_handler(in_bytes::Vector{UInt8})
        return UInt8[0x4E]   # "N"
    end
    ok = register_call!(app, "named", "Named handler", named_handler)
    ck(ok, "register_call! with a named function returns true")
    param2 = DataHandle("named")
    result2 = local_call(app, param2)
    set_cursor_position!(result2, 0)
    ck(read_buffer!(result2, 1) == UInt8[0x4E],
       "named handler returned the expected single byte")
    dispose!(result2)
    dispose!(param2)

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
println(stderr, "[test] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test] OK")
    exit(0)
else
    println(stderr, "[test] FAILED")
    exit(1)
end