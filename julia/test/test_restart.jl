# test_restart.jl - Verify that start/stop_callback_consumer can
# be called more than once, and that shutdown with pending events
# does not hang.
#
# This test exercises the restart contract of the callback layer
# (see c_ext/lf_shim.c, "Re-initialisation contract") together with
# a real round-trip through LF_LocalCall. It therefore loads the
# REAL shim (lf_shim_real.dll), which shares its registration table
# with the real LingoFuse library that LF_LocalCall dispatches into.
#
# The mock shim cannot be used here: register_call! would register
# into the mock's private table, and LF_LocalCall (which goes to the
# real library) would find no matching API, so round 2 would fail
# with a misleading "no found api" error.
#
# NOTE: uid.jl MUST be included before abi.jl. abi.jl's signatures
# reference LFShimUID (the 32-byte tuple type), which is defined in
# uid.jl. Omitting the include produces an UndefVarError at the
# LF_Get_P2P_UID binding.

ENV["LINGOFUSE_TRACE"] = "0"

# ------------------------------------------------------------------ #
# Real shim pin                                                      #
# ------------------------------------------------------------------ #
# See the file header above. Fail fast if the real shim has not been
# built, instead of silently falling back to whatever shim src/shim.jl
# happens to resolve.

const _REAL_SHIM_PATH =
    joinpath(@__DIR__, "..", "c_ext", "real", "lf_shim_real.dll")

if !isfile(_REAL_SHIM_PATH)
    println(stderr, "FATAL: this test requires the real shim.")
    println(stderr, "  Expected: $_REAL_SHIM_PATH")
    println(stderr, "  Build it with:")
    println(stderr, "      cd julia")
    println(stderr, "      .\\build.ps1")
    exit(1)
end

ENV["LINGOFUSE_SHIM"] = _REAL_SHIM_PATH

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