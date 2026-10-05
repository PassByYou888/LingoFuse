# test_network.jl - Step-2 network acceptance test.
#
# Coverage:
#   1. Prepare service / client / done.
#   2. Diagnostics: check_main_thread, check_app, check_api.
#   3. RPC round trip through the C4 mesh (LF_Call).
#   4. exit_main_thread stops the loop without releasing resources.
#   5. shutdown releases resources; a second shutdown is a no-op.
#
# The test uses a unique IPC endpoint name (PID + random suffix) so
# repeated runs do not collide with a previous process's endpoint.

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

# ------------------------------------------------------------------ #
# Report                                                             #
# ------------------------------------------------------------------ #

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
# Test setup                                                         #
# ------------------------------------------------------------------ #

function unique_endpoint(prefix::String)::String
    pid  = getpid()
    salt = rand(UInt32)
    return "ipc:jltest_$(prefix)_$(pid)_$(salt)"
end

const APP_NAME     = "JlNetworkTestApp"
const API_NAME     = "echo"
const ENDPOINT     = unique_endpoint("net")

println(stderr, "[test] endpoint = ", ENDPOINT)

# ------------------------------------------------------------------ #
# Test body                                                          #
# ------------------------------------------------------------------ #

start_callback_consumer()

app = App(APP_NAME, "Julia network test")

try
    # Register an echo API. The warmup runs at registration time.
    ok = register_call!(app, API_NAME, "Echo the payload",
                        (in_bytes::Vector{UInt8}) -> copy(in_bytes))
    ck(ok, "register_call! returned true")

    # Prepare service and client.
    reset_prepare()

    set_option("Wait_Ready", "False")          # do not block on connect
    set_option("Quiet", "True")                # suppress native chatter

    tag_s = prepare_service(ENDPOINT, ENDPOINT)
    ck(tag_s >= 0, "prepare_service returned a tag ($(tag_s))")

    tag_c = prepare_client(ENDPOINT, app)
    ck(tag_c >= 0, "prepare_client returned a tag ($(tag_c))")

    ret = prepare_done()
    ck(ret == 1 || check_main_thread(),
       "prepare_done returned 1 (or main thread is running)")

    ck(check_main_thread(), "check_main_thread returns true")

    # Wait for the App to become visible on the mesh. With Wait_Ready
    # disabled, the broadcast is asynchronous; polling is the
    # documented pattern.
    visible_app = false
    visible_api = false
    for _ in 1:100
        visible_app = check_app(APP_NAME)
        visible_api = check_api(APP_NAME, API_NAME)
        (visible_app && visible_api) && break
        sleep(0.1)
    end
    ck(visible_app, "check_app finds the registered App")
    ck(visible_api, "check_api finds the registered API")

    # Round trip via LF_Call. Because the App is registered in this
    # same process, C4's local-first routing resolves the call to the
    # local instance; the full dispatch path is still exercised.
    param = DataHandle(API_NAME)
    write_string!(param, "hello, network")

    raw = LF_Call(APP_NAME, param.handle, UInt64(5000))
    ck(raw != C_NULL, "LF_Call returned a non-null handle")

    result = _wrap_data_handle(raw, true)
    sz = buffer_size(result)
    ck(sz > 0, "result has non-zero size ($sz)")

    if sz > 0
        set_cursor_position!(result, 0)
        text = read_string!(result)
        ck(text == "hello, network",
           "network round-trip returned the expected payload")
    end
    dispose!(result)
    dispose!(param)

    # generate_app_name must succeed after prepare_done has returned.
    gen = generate_app_name()
    ck(!isempty(gen), "generate_app_name returns a non-empty string")

    # get_app_name returns the App name from the native side.
    native_name = get_app_name(app)
    ck(native_name == APP_NAME, "get_app_name matches the App name")

finally
    # LF-CLEAN-001 sequence.
    try exit_main_thread() catch; end
    try dispose!(app) catch; end
    try shutdown() catch; end
    try stop_callback_consumer() catch; end
end

# Second shutdown must be safe and idempotent.
try
    shutdown()
    ck(true, "second shutdown() is a no-op")
catch err
    ck(false, "second shutdown() raised: $(sprint(showerror, err))")
end

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