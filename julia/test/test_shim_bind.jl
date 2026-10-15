# test_shim_bind.jl - Binding-completeness test for src/shim.jl.
#
# Coverage:
#   - All shim-side symbols are bound as Julia functions.
#   - shim library resolution (available / is_real / path).
#   - Lifecycle: shim_init, shim_shutdown, re-init.
#   - All 16 typed option get/set pairs.
#   - Generic option set/get.
#   - Process-wide P2P registration.
#   - All 6 async dispatch primitives return the expected value.
#   - Event accessors tolerate NULL (empty queue) safely.
#
# This file loads the shim library (mock or real, whichever is found
# first) and the real LingoFuse runtime. It does NOT prepare a
# service, does NOT start the simulated main thread, and does NOT
# register any callback. All side effects are limited to shim-internal
# state and (for LF_CreateData / LF_FreeData) auto-recycled handle
# allocation.
#
# The test does NOT depend on the mock shim being the one that is
# loaded. It adapts to shim_is_real() for the one option whose
# behaviour differs between the two (the password getter returns the
# value on mock, and a fixed mask on the real library).
#
# Exit code: 0 on success, 1 on any failure.

ENV["LINGOFUSE_TRACE"] = "0"

# ------------------------------------------------------------------ #
# Mock shim pin                                                      #
# ------------------------------------------------------------------ #
# This test asserts the exact return values of every shim entry
# point under the mock shim. Two families of assertions depend on
# mock-specific behavior:
#
#   debug round-trip
#       The real library treats the "debug" option as write-only;
#       LF_GetOption("debug") returns the placeholder string
#       "(no value: debug is write-only)". The mock stores and
#       returns the value verbatim.
#
#   async dispatch return value
#       The mock's LF_Async_Call (and its five siblings) always
#       record the pending op and return 1. The real library
#       returns 0 when there is no live mesh connection to route
#       the request through.
#
# The test therefore loads lf_shim_mock.dll, not lf_shim_real.dll.
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

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test_shim_bind] $tag  $msg")
    flush(stderr)
    if cond
        passed[] += 1
    else
        failed[] += 1
    end
    return cond
end

# -------------------------------------------------------------------- #
# Event kind constants                                                 #
# -------------------------------------------------------------------- #

println(stderr, "[test_shim_bind] --- event kind constants ---")

ck(LF_SHIM_EVENT_CALL               == 0, "LF_SHIM_EVENT_CALL == 0")
ck(LF_SHIM_EVENT_NOTIFY             == 1, "LF_SHIM_EVENT_NOTIFY == 1")
ck(LF_SHIM_EVENT_NETWORK_CONNECT    == 2, "LF_SHIM_EVENT_NETWORK_CONNECT == 2")
ck(LF_SHIM_EVENT_NETWORK_DISCONNECT == 3, "LF_SHIM_EVENT_NETWORK_DISCONNECT == 3")
ck(LF_SHIM_EVENT_ASYNC_RESULT       == 4, "LF_SHIM_EVENT_ASYNC_RESULT == 4")

# -------------------------------------------------------------------- #
# Expected symbols                                                     #
# -------------------------------------------------------------------- #
#
# Every shim_* function that src/shim.jl exports. The check below
# scans Main for all shim_* Function bindings and compares the set
# against this list. A missing name is reported; so is an unexpected
# one (a binding whose name starts with shim_ but is not in this list).
#
# Count breakdown:
#   Lifecycle:           2
#   Resolution:          3
#   Registration App:    2
#   Registration P2P:    3
#   Network events:      2
#   Async dispatch:      6
#   Consumer:            1
#   Event accessors:     9
#   Julia payload copy:  2
#   Event completion:    2
#   Typed options:      32  (16 pairs)
#   Generic options:     2
#   -----------------------
#   Total:              66

const EXPECTED_SHIM_FUNCTIONS = Symbol[
    # Lifecycle
    :shim_init,
    :shim_shutdown,

    # Resolution
    :shim_available,
    :shim_is_real,
    :shim_path,

    # Registration: App-bound
    :shim_register_call,
    :shim_register_notify,

    # Registration: process-wide P2P
    :shim_register_p2p_call,
    :shim_register_p2p_notify,
    :shim_unregister_p2p,

    # Network events
    :shim_install_network_events,
    :shim_clear_network_events,

    # Async dispatch (6 primitives)
    :shim_async_call,
    :shim_async_sequenced_call,
    :shim_uid_async_call,
    :shim_uid_async_sequenced_call,
    :shim_p2pname_async_call,
    :shim_p2pname_async_sequenced_call,

    # Consumer
    :shim_wait_event,

    # Event accessors
    :shim_event_kind,
    :shim_event_user_id,
    :shim_event_input,
    :shim_event_output,
    :shim_event_addr,
    :shim_event_input_data,
    :shim_event_input_len,
    :shim_event_result_data,
    :shim_event_result_len,

    # Julia-owned payload copies
    :shim_read_input,
    :shim_read_result,

    # Event completion
    :shim_set_output,
    :shim_complete_event,

    # Typed options (16 pairs)
    :shim_set_opt_password,                       :shim_get_opt_password,
    :shim_set_opt_debug,                          :shim_get_opt_debug,
    :shim_set_opt_quiet,                          :shim_get_opt_quiet,
    :shim_set_opt_show_thread_id,                 :shim_get_opt_show_thread_id,
    :shim_set_opt_console_output,                 :shim_get_opt_console_output,
    :shim_set_opt_overlap_connection,             :shim_get_opt_overlap_connection,
    :shim_set_opt_wait_connection_ready_ok,       :shim_get_opt_wait_connection_ready_ok,
    :shim_set_opt_wait_connection_timeout,        :shim_get_opt_wait_connection_timeout,
    :shim_set_opt_ipc_serv_thread_count,          :shim_get_opt_ipc_serv_thread_count,
    :shim_set_opt_ipc_serv_max_queue_length,      :shim_get_opt_ipc_serv_max_queue_length,
    :shim_set_opt_ipc_serv_max_msg_size,          :shim_get_opt_ipc_serv_max_msg_size,
    :shim_set_opt_fixed_sequenced_time,           :shim_get_opt_fixed_sequenced_time,
    :shim_set_opt_p2p_name,                       :shim_get_opt_p2p_name,
    :shim_set_opt_data_handle_idle_timeout,       :shim_get_opt_data_handle_idle_timeout,
    :shim_set_opt_data_handle_pool_scan_interval, :shim_get_opt_data_handle_pool_scan_interval,
    :shim_set_opt_no_reponse_cmd_null_flush_threshold,
    :shim_get_opt_no_reponse_cmd_null_flush_threshold,

    # Generic options
    :shim_set_option,
    :shim_get_option,
]

const EXPECTED_SHIM_FUNCTION_COUNT = 66

ck(length(EXPECTED_SHIM_FUNCTIONS) == EXPECTED_SHIM_FUNCTION_COUNT,
   "EXPECTED_SHIM_FUNCTIONS contains " *
   "$EXPECTED_SHIM_FUNCTION_COUNT entries " *
   "(got $(length(EXPECTED_SHIM_FUNCTIONS)))")

ck(length(unique(EXPECTED_SHIM_FUNCTIONS)) ==
   length(EXPECTED_SHIM_FUNCTIONS),
   "EXPECTED_SHIM_FUNCTIONS contains no duplicates")

println(stderr, "[test_shim_bind] --- symbol presence ---")

let missing = Symbol[]
    for name in EXPECTED_SHIM_FUNCTIONS
        if !isdefined(Main, name)
            push!(missing, name)
        end
    end
    if isempty(missing)
        ck(true,
           "all $EXPECTED_SHIM_FUNCTION_COUNT expected shim functions " *
           "are bound")
    else
        ck(false, "missing: $(join(string.(missing), ", "))")
    end
end

let nonfunc = Symbol[]
    for name in EXPECTED_SHIM_FUNCTIONS
        isdefined(Main, name) || continue
        v = getfield(Main, name)
        if !(v isa Function)
            push!(nonfunc, name)
        end
    end
    if isempty(nonfunc)
        ck(true, "all expected shim bindings are Function instances")
    else
        ck(false, "non-function: $(join(string.(nonfunc), ", "))")
    end
end

let expected_set = Set(EXPECTED_SHIM_FUNCTIONS)
    unexpected = Symbol[]
    for n in names(Main; all = true)
        s = string(n)
        if startswith(s, "shim_")
            v = try
                getfield(Main, n)
            catch
                continue
            end
            if v isa Function && !(n in expected_set)
                push!(unexpected, n)
            end
        end
    end
    if isempty(unexpected)
        ck(true, "no unexpected shim_* Function binding found")
    else
        ck(false, "unexpected: $(join(string.(unexpected), ", "))")
    end
end

# -------------------------------------------------------------------- #
# Library resolution                                                   #
# -------------------------------------------------------------------- #

println(stderr, "[test_shim_bind] --- library resolution ---")

ck(shim_available(),
   "shim_available() is true (found at $(LINGOFUSE_SHIM_PATH))")

ck(!isempty(LINGOFUSE_SHIM_PATH),
   "LINGOFUSE_SHIM_PATH is non-empty")

ck(shim_path() == LINGOFUSE_SHIM_PATH,
   "shim_path() matches LINGOFUSE_SHIM_PATH")

let r = shim_is_real()
    ck(r isa Bool, "shim_is_real() returns a Bool")
    # The following check is informational, not an assertion.
    if r
        println(stderr, "[test_shim_bind] INFO  shim is the REAL variant")
    else
        println(stderr, "[test_shim_bind] INFO  shim is the MOCK variant")
    end
end

# -------------------------------------------------------------------- #
# Lifecycle                                                            #
# -------------------------------------------------------------------- #

println(stderr, "[test_shim_bind] --- lifecycle ---")

let ok = shim_init()
    ck(ok, "shim_init() returned true")
end

# A second shim_init resets the shutdown flag; must not raise.
let ok = shim_init()
    ck(ok, "second shim_init() returned true")
end

# wait_event with a zero timeout on an empty queue must return NULL.
let e = shim_wait_event(0)
    ck(e == C_NULL,
       "shim_wait_event(0) returns C_NULL on an empty queue")
end

# -------------------------------------------------------------------- #
# Typed options                                                        #
# -------------------------------------------------------------------- #
#
# Each pair is exercised with a value that is distinct from the
# option's default, so a "getter returned default because the setter
# was a no-op" bug is caught. The password option is the one
# exception: on the real library the getter returns a fixed mask, so
# only the type and non-emptiness are asserted.

println(stderr, "[test_shim_bind] --- typed options ---")

# --- password ---
let v0 = "jltest_password_marker"
    shim_set_opt_password(v0)
    v1 = shim_get_opt_password()
    ck(v1 isa String, "password getter returns a String")
    ck(!isempty(v1), "password getter returns a non-empty String")
    if shim_is_real()
        ck(v1 == "********",
           "password is masked on the real library (got '$v1')")
    else
        ck(v1 == v0,
           "password round-trips on the mock (got '$v1')")
    end
end

# --- debug ---
let v0 = "service"
    shim_set_opt_debug(v0)
    ck(shim_get_opt_debug() == v0, "debug round-trips")
end

# --- boolean options ---
let
    for (setf, getf, name) in (
        (shim_set_opt_quiet,                shim_get_opt_quiet,                "quiet"),
        (shim_set_opt_show_thread_id,       shim_get_opt_show_thread_id,       "show_thread_id"),
        (shim_set_opt_console_output,       shim_get_opt_console_output,       "console_output"),
        (shim_set_opt_overlap_connection,   shim_get_opt_overlap_connection,   "overlap_connection"),
        (shim_set_opt_wait_connection_ready_ok,
         shim_get_opt_wait_connection_ready_ok,
         "wait_connection_ready_ok"),
    )
        setf(true)
        ck(getf() === true,  "$(name) true -> true")
        setf(false)
        ck(getf() === false, "$(name) false -> false")
    end
end

# --- unsigned 64-bit options ---
let
    for (setf, getf, name, val) in (
        (shim_set_opt_wait_connection_timeout,      shim_get_opt_wait_connection_timeout,      "wait_connection_timeout",          UInt64(12345)),
        (shim_set_opt_fixed_sequenced_time,         shim_get_opt_fixed_sequenced_time,         "fixed_sequenced_time",             UInt64(67890)),
        (shim_set_opt_data_handle_idle_timeout,     shim_get_opt_data_handle_idle_timeout,     "data_handle_idle_timeout",         UInt64(111111)),
        (shim_set_opt_data_handle_pool_scan_interval,
         shim_get_opt_data_handle_pool_scan_interval,
         "data_handle_pool_scan_interval",
         UInt64(22222)),
    )
        setf(val)
        ck(getf() == val, "$(name) round-trips ($val)")
    end
end

# --- signed int options ---
let
    for (setf, getf, name, val) in (
        (shim_set_opt_ipc_serv_thread_count,          shim_get_opt_ipc_serv_thread_count,          "ipc_serv_thread_count",          7),
        (shim_set_opt_ipc_serv_max_queue_length,      shim_get_opt_ipc_serv_max_queue_length,      "ipc_serv_max_queue_length",      1234),
        (shim_set_opt_ipc_serv_max_msg_size,          shim_get_opt_ipc_serv_max_msg_size,          "ipc_serv_max_msg_size",          65536),
        (shim_set_opt_no_reponse_cmd_null_flush_threshold,
         shim_get_opt_no_reponse_cmd_null_flush_threshold,
         "no_reponse_cmd_null_flush_threshold",
         512),
    )
        setf(val)
        ck(getf() == val, "$(name) round-trips ($val)")
    end
end

# --- p2p_name (string) ---
let v0 = "jltest_worker_group"
    shim_set_opt_p2p_name(v0)
    ck(shim_get_opt_p2p_name() == v0, "p2p_name round-trips")
end

# -------------------------------------------------------------------- #
# Generic option get / set                                             #
# -------------------------------------------------------------------- #

println(stderr, "[test_shim_bind] --- generic options ---")

let
    shim_set_option("Quiet", "True")
    ck(shim_get_option("Quiet") == "True",
       "generic set/get: Quiet=True")

    shim_set_option("Quiet", "False")
    ck(shim_get_option("Quiet") == "False",
       "generic set/get: Quiet=False")

    marker = "jltest_unknown_$(getpid())"
    ck(shim_get_option(marker) == "",
       "generic get of an unknown option returns an empty string")
end

# -------------------------------------------------------------------- #
# Process-wide P2P registration                                        #
# -------------------------------------------------------------------- #

println(stderr, "[test_shim_bind] --- P2P registration ---")

let
    name = "jltest_p2p_bind_$(getpid())"
    ok = shim_register_p2p_call(name, "test call", Int64(101))
    ck(ok, "shim_register_p2p_call returns true on first registration")

    ok2 = shim_register_p2p_call(name, "test call", Int64(102))
    ck(!ok2, "shim_register_p2p_call returns false on duplicate")

    ok_un = shim_unregister_p2p(name)
    ck(ok_un, "shim_unregister_p2p returns true for an existing name")

    ok_un2 = shim_unregister_p2p(name)
    ck(!ok_un2, "shim_unregister_p2p returns false for an unknown name")
end

let
    name = "jltest_p2p_notify_bind_$(getpid())"
    ok = shim_register_p2p_notify(name, "test notify", Int64(201))
    ck(ok, "shim_register_p2p_notify returns true on first registration")
    ck(shim_unregister_p2p(name),
       "shim_unregister_p2p removes a notify registration")
end

# -------------------------------------------------------------------- #
# Async dispatch primitives                                            #
# -------------------------------------------------------------------- #
#
# Each primitive is invoked with a valid param handle and a fresh
# user_token. Both the mock and the real shim return 1 when the
# request is successfully queued. The response is NOT awaited here;
# the consumer-loop integration is exercised by test_shim.jl, which
# uses the mock's trigger drivers.
#
# Empty group name
# ----------------
# The shim rejects a NULL group_name pointer, but NOT an empty
# string. An empty Julia String is converted to a pointer to a "\0"
# byte, which is a valid non-NULL pointer. The shim therefore queues
# the request and returns 1.
#
# Whether an empty group name is ultimately serviced is a
# SERVER-SIDE concern, not a shim concern: the server's
# cmd_P2PName_Call finds no match for "" and sends no reply, so the
# async callback never fires. Detecting that case requires a timeout
# on the caller side (see the target.jl / async.jl layers).
#
# The test below asserts the shim's actual contract: an empty group
# name is accepted at dispatch time.

println(stderr, "[test_shim_bind] --- async dispatch ---")

let param = LF_CreateData("async_dispatch_test")
    try
        # App-name async
        ck(shim_async_call("AnyApp", param, Int64(1001)) == 1,
           "shim_async_call returns 1")
        ck(shim_async_sequenced_call("AnyApp", param, Int64(1002)) == 1,
           "shim_async_sequenced_call returns 1")

        # UID async
        uid = uid_from_hex("ab"^32)
        ck(shim_uid_async_call(uid, param, Int64(2001)) == 1,
           "shim_uid_async_call returns 1")
        ck(shim_uid_async_sequenced_call(uid, param, Int64(2002)) == 1,
           "shim_uid_async_sequenced_call returns 1")

        # P2PName async
        ck(shim_p2pname_async_call("jltest_group", param, Int64(3001)) == 1,
           "shim_p2pname_async_call returns 1")
        ck(shim_p2pname_async_sequenced_call("jltest_group", param, Int64(3002)) == 1,
           "shim_p2pname_async_sequenced_call returns 1")
    finally
        LF_FreeData(param)
    end
end

# Empty group name: the shim accepts it (dispatch queued, ret=1).
# See the "Empty group name" note above for why this is the correct
# contract.
let param = LF_CreateData("async_dispatch_test_empty")
    try
        ret = shim_p2pname_async_call("", param, Int64(4001))
        ck(ret == 1,
           "shim_p2pname_async_call accepts an empty group name " *
           "(returns 1; empty-string routing is a server-side concern)")
    finally
        LF_FreeData(param)
    end
end

# NULL group name is rejected. The Julia binding converts
# C_NULL to a Ptr{UInt8}(0), which the shim sees as a NULL pointer.
# Because the Julia wrapper's signature is AbstractString, we cannot
# pass NULL through it directly; the check is done at the C level by
# inspecting the source. The Julia-side guarantee is that the wrapper
# never passes NULL: a Julia String always yields a valid pointer.
#
# To exercise the C-side NULL guard we call the shim directly with a
# raw ccall, bypassing the Julia wrapper.
let param = LF_CreateData("async_dispatch_test_null")
    try
        ret = ccall((:lf_shim_p2pname_async_call, LINGOFUSE_SHIM_PATH),
                    Cint,
                    (Ptr{UInt8}, Ptr{Cvoid}, Int64),
                    C_NULL, param, Int64(5001))
        ck(ret == 0,
           "lf_shim_p2pname_async_call rejects a NULL group name " *
           "(returns 0)")
    finally
        LF_FreeData(param)
    end
end

# -------------------------------------------------------------------- #
# Event accessors on NULL                                              #
# -------------------------------------------------------------------- #
#
# Every accessor documents a defensive NULL check. Calling them on a
# NULL pointer must not crash; it must return the documented default.
# This verifies the C-side NULL guards and the Julia-side signatures.

println(stderr, "[test_shim_bind] --- event accessors on NULL ---")

let null = Ptr{Cvoid}(0)
    ck(shim_event_kind(null)    == Cint(-1),
       "shim_event_kind(NULL) returns -1")
    ck(shim_event_user_id(null) == Int64(0),
       "shim_event_user_id(NULL) returns 0")
    ck(shim_event_input(null)   == C_NULL,
       "shim_event_input(NULL) returns C_NULL")
    ck(shim_event_output(null)  == C_NULL,
       "shim_event_output(NULL) returns C_NULL")
    ck(shim_event_addr(null)    === nothing,
       "shim_event_addr(NULL) returns nothing")
    ck(shim_event_input_data(null) == C_NULL,
       "shim_event_input_data(NULL) returns C_NULL")
    ck(shim_event_input_len(null)  == 0,
       "shim_event_input_len(NULL) returns 0")
    ck(shim_event_result_data(null) == C_NULL,
       "shim_event_result_data(NULL) returns C_NULL")
    ck(shim_event_result_len(null)  == 0,
       "shim_event_result_len(NULL) returns 0")

    # shim_read_input / shim_read_result on NULL must return an empty
    # vector, not crash.
    ck(shim_read_input(null)  == UInt8[],
       "shim_read_input(NULL) returns an empty Vector{UInt8}")
    ck(shim_read_result(null) == UInt8[],
       "shim_read_result(NULL) returns an empty Vector{UInt8}")

    # shim_set_output with an empty payload returns true without
    # touching the event.
    ck(shim_set_output(null, UInt8[]) == true,
       "shim_set_output(NULL, empty) returns true")
end

# -------------------------------------------------------------------- #
# Shutdown                                                             #
# -------------------------------------------------------------------- #

println(stderr, "[test_shim_bind] --- shutdown ---")

shim_shutdown()
ck(true, "shim_shutdown() completed without error")

shim_shutdown()
ck(true, "second shim_shutdown() is a no-op")

# -------------------------------------------------------------------- #
# Summary                                                              #
# -------------------------------------------------------------------- #

println(stderr, "")
println(stderr, "[test_shim_bind] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test_shim_bind] OK")
    exit(0)
else
    println(stderr, "[test_shim_bind] FAILED")
    exit(1)
end