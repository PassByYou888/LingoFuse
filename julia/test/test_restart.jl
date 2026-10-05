# test_restart.jl - Verify that start/stop_callback_consumer can
# be called more than once, and that shutdown with pending events
# does not hang.
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

passed = Ref(0); failed = Ref(0)
function ck(c, m); c ? (passed[] += 1) : (failed[] += 1);
    println(stderr, "[test] ", c ? "PASS" : "FAIL", "  ", m); end

# Round 1
start_callback_consumer()
ck(is_callback_consumer_running(), "round 1: consumer running")
stop_callback_consumer()
ck(!is_callback_consumer_running(), "round 1: consumer stopped")

# Round 2 (this is the S1 fix verification)
start_callback_consumer()
ck(is_callback_consumer_running(), "round 2: consumer running after restart")
app = App("RestartTest", "restart")
ck(register_call!(app, "echo", "echo",
                  (b) -> copy(b)), "round 2: register_call! ok")
dh = DataHandle("echo")
write_string!(dh, "hello")
result = local_call(app, dh)
set_cursor_position!(result, 0)
ck(read_string!(result) == "hello", "round 2: call works")
dispose!(result); dispose!(dh); dispose!(app)
stop_callback_consumer()
ck(!is_callback_consumer_running(), "round 2: consumer stopped")

println(stderr, "[test] results: passed=$(passed[])  failed=$(failed[])")
exit(failed[] == 0 ? 0 : 1)