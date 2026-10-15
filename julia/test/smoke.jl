# smoke.jl - Hardened Step-2 smoke test (final, dual-mode).
#
# Four scenarios, each on its own App, exercising a different
# handler-definition shape:
#
#   S1  named function, defined before start_callback_consumer
#   S2  anonymous closure, defined inside a try block
#   S3  anonymous closure capturing a Ref, defined inside a try block
#   S4  anonymous closure defined AFTER three scenarios have run,
#       simulating a handler registered at runtime.
#
# All four must PASS.
#
# DUAL MODE
# ---------
# See test_raii.jl for the full rationale. In REAL mode the scenario
# is driven by LF_LocalCall (the shim forwards registration to the
# real library, so the two registries coincide). In MOCK mode the
# scenario is driven by the mock's Call trigger, which spawns a
# native thread that invokes the registered trampoline exactly like
# a C4 worker would.
#
# The comparison uses String(copy(buf)) so that the second
# String(...) call still sees the original bytes: Julia's
# String(::Vector{UInt8}) takes ownership of its argument
# (zero-copy), which silently empties the vector.
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

function say(msg::AbstractString)
    println(stderr, "[smoke] ", msg)
    flush(stderr)
    return nothing
end

say("library : " * LINGOFUSE_LIBRARY_PATH)
say("shim    : " * LINGOFUSE_SHIM_PATH)
say("is_real : " * string(shim_is_real()))
say("main tid: " * string(Threads.threadid()))

# ------------------------------------------------------------------
# Mock driver (defined only for MOCK mode)
# ------------------------------------------------------------------
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

# ------------------------------------------------------------------
# S1 handler: top-level named function, defined before start.
# ------------------------------------------------------------------
function s1_named(in_bytes::Vector{UInt8})::Vector{UInt8}
    say("  [s1] ENTER  len=$(length(in_bytes))")
    out = copy(in_bytes)
    say("  [s1] EXIT   out_len=$(length(out))")
    return out
end

# ------------------------------------------------------------------
# Scenario runner
# ------------------------------------------------------------------

function run_scenario(label::String,
                      app_name::String,
                      handler::Function)
    say("")
    say("==========================================")
    say("scenario $label  (app=$app_name)")
    say("==========================================")

    say("LF_CreateApp")
    app = LF_CreateApp(app_name, "smoke")

    say("register (warmup on)")
    t0 = time()
    ok = register_call_with_handler(app, "echo", "", handler)
    t1 = time()
    say("register = $ok  (elapsed $(round(t1 - t0; digits=4)) s)")

    payload = Vector{UInt8}(codeunits("hello, world"))

    ok_bytes = false
    if shim_is_real()
        say("LF_CreateData")
        param = LF_CreateData("echo")

        GC.@preserve payload begin
            LF_WriteBuffer(param, pointer(payload), length(payload))
        end
        say("payload written, len = $(length(payload))")

        say("LF_LocalCall ENTER  (caller tid = $(Threads.threadid()))")
        t0 = time()
        result = LF_LocalCall(app, param)
        t1 = time()
        say("LF_LocalCall RETURNED  (elapsed $(round(t1 - t0; digits=4)) s)")

        sz = LF_GetSize(result)
        say("result size = $sz")

        if sz > 0
            buf = Vector{UInt8}(undef, sz)
            LF_SetPos(result, 0)
            GC.@preserve buf begin
                LF_ReadBuffer(result, pointer(buf), sz)
            end
            say("result bytes : " * join(string.(buf), " "))

            # String(v) TAKES OWNERSHIP of v (zero-copy). Copy first.
            text = String(copy(buf))
            say("result text  : " * text)
            ok_bytes = (text == "hello, world")
        end

        LF_FreeData(result)
        LF_FreeData(param)
    else
        say("mock_trigger_call ENTER  (caller tid = $(Threads.threadid()))")
        t0 = time()
        response = _mock_trigger_call("echo", payload)
        t1 = time()
        say("mock_trigger_call RETURNED  (elapsed $(round(t1 - t0; digits=4)) s)")
        say("response length = $(length(response))")

        if !isempty(response)
            say("response bytes: " * join(string.(response), " "))
            text = String(copy(response))
            say("response text : " * text)
            ok_bytes = (text == "hello, world")
        end
    end

    LF_FreeApp(app)
    say("scenario $label " * (ok_bytes ? "PASS" : "FAIL"))
    return ok_bytes
end

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

say("start_callback_consumer")
start_callback_consumer()

all_ok = Ref(true)

try
    all_ok[] &= run_scenario("S1-named", "SmokeS1", s1_named)

    closure_plain = (in_bytes::Vector{UInt8}) -> begin
        say("  [s2] ENTER  len=$(length(in_bytes))")
        out = copy(in_bytes)
        say("  [s2] EXIT   out_len=$(length(out))")
        return out
    end
    all_ok[] &= run_scenario("S2-closure-plain", "SmokeS2", closure_plain)

    counter = Ref(0)
    closure_capture = (in_bytes::Vector{UInt8}) -> begin
        counter[] += 1
        say("  [s3] ENTER  call #$(counter[])  len=$(length(in_bytes))")
        out = copy(in_bytes)
        say("  [s3] EXIT   out_len=$(length(out))")
        return out
    end
    all_ok[] &= run_scenario("S3-closure-capture", "SmokeS3", closure_capture)

    say("")
    say("---- defining S4 handler now (after three scenarios) ----")
    closure_late = (in_bytes::Vector{UInt8}) -> begin
        say("  [s4] ENTER  len=$(length(in_bytes))")
        out = copy(in_bytes)
        say("  [s4] EXIT   out_len=$(length(out))")
        return out
    end
    all_ok[] &= run_scenario("S4-closure-late", "SmokeS4", closure_late)

finally
    say("stop_callback_consumer")
    stop_callback_consumer()
end

say("")
if all_ok[]
    say("all scenarios passed")
    say("OK")
    exit(0)
else
    say("one or more scenarios failed")
    say("FAILED")
    exit(1)
end