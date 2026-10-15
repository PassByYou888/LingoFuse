# CrossCall.jl - Load-tester for the "ipc:cross" endpoint.
#
# Connects as a pure consumer (no App attached) and spawns a
# configurable number of Julia tasks. Each task repeatedly invokes
# "demo.add" or "demo.inv_seri" at random for a fixed duration, then
# the process reports aggregate throughput.
#
# This revision uses the high-level `target.jl` calling surface
# (`app_target` + `call`) instead of calling LF_Call directly. The
# two forms are semantically equivalent; the high-level surface:
#
#   - centralizes payload construction through `_build_param`
#   - raises `LingoFuseCallError` / `LingoFuseTimeoutError` instead
#     of returning a size-0 handle
#   - keeps the example readable by hiding the raw ccall mechanics
#
# ---------------------------------------------------------------- #
# STARTUP ORDER (IMPORTANT)                                         #
# ---------------------------------------------------------------- #
# CrossService.jl and CrossNode.jl must BOTH be running before this
# script is started. This script polls the mesh for up to 10 seconds
# waiting for the "demo" App to appear; if it does not, it exits
# with a diagnostic listing the possible causes.
#
# ---------------------------------------------------------------- #
# CONCURRENCY AND LIBUV                                             #
# ---------------------------------------------------------------- #
# `call` dispatches through @threadcall in abi.jl, so every call
# consumes one libuv worker thread for the duration of the
# underlying C function. libuv's default thread pool has four
# workers; raising it requires the UV_THREADPOOL_SIZE environment
# variable at process start:
#
#     $env:UV_THREADPOOL_SIZE = "32"
#     julia --threads=2 example/CrossCall.jl
#
# With eight concurrent Julia tasks and the default four-worker
# pool, at most four calls are in flight at any moment and the
# remaining tasks queue inside libuv. This is a Julia runtime
# property, not a LingoFuse binding property; the C++ / C# demos use
# one native thread per call and reach higher concurrency on the
# same hardware.
#
# ---------------------------------------------------------------- #
# Run                                                               #
# ---------------------------------------------------------------- #
# After CrossService.jl and CrossNode.jl have started:
#
#     julia --threads=2 example/CrossCall.jl
#
# A minimum of 2 Julia threads is REQUIRED because the callback
# consumer task must not run on the main Julia thread.

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using LingoFuse

# ================================================================== #
# Configuration                                                      #
# ================================================================== #

const TARGET_APP          = "demo"
const ENDPOINT            = "ipc:cross"
const WORKER_TASKS        = 8
const TEST_SECONDS        = 10
const CALL_TIMEOUT_MS     = 1000
const PAUSE_SECONDS       = 0.001
const APP_VISIBLE_TIMEOUT = 10.0    # seconds

# ================================================================== #
# Aggregate counters                                                 #
# ================================================================== #
#
# Threads.Atomic{Int} provides a lock-free counter. All updates use
# the default sequential-consistency ordering, which is more than
# strong enough for counters that are only read after every worker
# has been joined.

const TOTAL_CALLS    = Threads.Atomic{Int}(0)
const SUCCESS_CALLS  = Threads.Atomic{Int}(0)
const FAILED_CALLS   = Threads.Atomic{Int}(0)
const ADD_CALLS      = Threads.Atomic{Int}(0)
const INV_SERI_CALLS = Threads.Atomic{Int}(0)

# ================================================================== #
# Remote call wrappers                                               #
# ================================================================== #

"""
    remote_add(target, a::Int32, b::Int32) -> Union{Int32,Nothing}

Invoke `demo.add` through the given target. Returns the sum on
success, or `nothing` on timeout / routing failure.
"""
function remote_add(target::AppTarget,
                    a::Int32,
                    b::Int32)::Union{Int32,Nothing}
    try
        payload = dh -> begin
            write_int32!(dh, a)
            write_int32!(dh, b)
        end
        response = call(target, "add", payload;
                        timeout_ms = CALL_TIMEOUT_MS)
        length(response) < 4 && return nothing

        scratch = DataHandle("add")
        try
            write_buffer!(scratch, response)
            set_cursor_position!(scratch, 0)
            return read_int32(scratch)
        finally
            dispose!(scratch)
        end
    catch
        return nothing
    end
end

"""
    remote_inv_seri(target) -> Union{String,Nothing}

Invoke `demo.inv_seri` through the given target and format the reply.
Returns a human-readable string on success, or `nothing` on failure.
"""
function remote_inv_seri(target::AppTarget)::Union{String,Nothing}
    const_b = UInt8(200)
    const_w = UInt16(0x10)
    const_c = UInt32(0x2F)
    const_u = UInt64(0x3F)
    const_s = "hello world"
    const_f = Float32(3.14)

    try
        payload = dh -> begin
            write_uint8!(dh,  const_b)
            write_uint16!(dh, const_w)
            write_uint32!(dh, const_c)
            write_uint64!(dh, const_u)
            write_string!(dh, const_s)
            write_single!(dh, const_f)
        end
        response = call(target, "inv_seri", payload;
                        timeout_ms = CALL_TIMEOUT_MS)
        isempty(response) && return nothing

        scratch = DataHandle("inv_seri")
        try
            write_buffer!(scratch, response)
            set_cursor_position!(scratch, 0)

            rf   = read_single(scratch)
            rs   = read_string!(scratch)
            ru64 = read_uint64(scratch)
            rc   = read_uint32(scratch)
            rw   = read_uint16(scratch)
            rb   = read_uint8(scratch)

            return "reply: [$(rb), $(rw), $(rc), $(ru64), " *
                   "\"$(rs)\", $(rf)]  original: " *
                   "[$(const_b), $(const_w), $(const_c), " *
                   "$(const_u), \"$(const_s)\", $(const_f)]"
        finally
            dispose!(scratch)
        end
    catch
        return nothing
    end
end

# ================================================================== #
# Worker task body                                                   #
# ================================================================== #

function worker_task(target::AppTarget, deadline::Float64)
    while time() < deadline
        Threads.atomic_add!(TOTAL_CALLS, 1)

        if rand() < 0.5
            Threads.atomic_add!(ADD_CALLS, 1)
            a = Int32(rand(1:1000))
            b = Int32(rand(1:1000))
            r = remote_add(target, a, b)
            if r === nothing
                Threads.atomic_add!(FAILED_CALLS, 1)
            else
                Threads.atomic_add!(SUCCESS_CALLS, 1)
            end
        else
            Threads.atomic_add!(INV_SERI_CALLS, 1)
            r = remote_inv_seri(target)
            if r === nothing
                Threads.atomic_add!(FAILED_CALLS, 1)
            else
                Threads.atomic_add!(SUCCESS_CALLS, 1)
            end
        end

        sleep(PAUSE_SECONDS)
    end
    return nothing
end

# ================================================================== #
# Helpers                                                            #
# ================================================================== #

function banner(title::AbstractString)
    println("=== ", title, " ===")
    return nothing
end

function wait_for_enter(prompt::AbstractString)
    print(prompt)
    flush(stdout)
    readline()
    return nothing
end

"""
    wait_for_app_visible(app_name, timeout_seconds) -> Bool

Poll `check_app` until the named App becomes visible on the mesh, or
until `timeout_seconds` elapse. Returns `true` on success, `false`
on timeout.

The lookup uses a local cache updated by network broadcasts with a
propagation delay of roughly 3 seconds (LF-CHK-001). Polling with a
small sleep interval is the documented pattern for readiness
detection after `prepare_done` has returned.
"""
function wait_for_app_visible(app_name::AbstractString,
                              timeout_seconds::Float64)::Bool
    deadline = time() + timeout_seconds
    while time() < deadline
        check_app(app_name) && return true
        sleep(0.1)
    end
    return false
end

# ================================================================== #
# Main                                                               #
# ================================================================== #

function main()::Int
    banner("Cross Call (Client)")

    # Deployment options. Wait_Connection_ReadyOk = True so that the
    # process only proceeds after the local client is fully online,
    # and the C4 loop has populated its cache with the current mesh
    # state.
    set_option("Wait_Connection_ReadyOk", "True")
    set_option("Overlap_Connection",     "True")
    set_option("Wait_Connection_Timeout", "10000")

    reset_prepare()

    tag_c = prepare_client(ENDPOINT, nothing)
    if tag_c < 0
        println(stderr, "[FATAL] prepare_client returned $(tag_c) " *
                        "for $(ENDPOINT)")
        return 1
    end

    if prepare_done() != 1 && !check_main_thread()
        println(stderr, "[FATAL] prepare_done failed")
        return 1
    end

    # Wait for the "demo" App to become visible on the mesh. The
    # broadcast is asynchronous and lags a fresh registration by up
    # to ~3 seconds; polling is the documented pattern.
    println("[Call] Waiting for app '$(TARGET_APP)' to become " *
            "visible (timeout $(APP_VISIBLE_TIMEOUT)s)...")

    if !wait_for_app_visible(TARGET_APP, APP_VISIBLE_TIMEOUT)
        println(stderr, "")
        println(stderr, "[FATAL] target app '$(TARGET_APP)' did not " *
                        "become visible within " *
                        "$(APP_VISIBLE_TIMEOUT) seconds.")
        println(stderr, "        Possible causes:")
        println(stderr, "          1. CrossService.jl is not running.")
        println(stderr, "          2. CrossNode.jl is not running, or " *
                        "is still in its own startup phase.")
        println(stderr, "          3. CrossService.jl was shut down " *
                        "before CrossNode.jl connected to it.")
        println(stderr, "          4. CrossNode.jl and CrossCall.jl " *
                        "are connected to different IPC endpoints.")
        println(stderr, "")
        println(stderr, "        Correct startup order (each in its " *
                        "own terminal):")
        println(stderr, "          1. julia --threads=2 " *
                        "example/CrossService.jl")
        println(stderr, "          2. julia --threads=2 " *
                        "example/CrossNode.jl")
        println(stderr, "          3. julia --threads=2 " *
                        "example/CrossCall.jl")
        return 1
    end

    println("[Call] Connected to $(ENDPOINT).")
    println("[Call] Starting $(TEST_SECONDS)-second load test " *
            "with $(WORKER_TASKS) tasks...")

    # Build the addressing target ONCE and share it across tasks. An
    # AppTarget is immutable and safe to share.
    target = app_target(TARGET_APP; timeout_ms = CALL_TIMEOUT_MS)

    t_start  = time()
    deadline = t_start + TEST_SECONDS

    tasks = Task[]
    for _ in 1:WORKER_TASKS
        push!(tasks, Threads.@spawn worker_task(target, deadline))
    end
    foreach(wait, tasks)

    t_end   = time()
    elapsed = t_end - t_start

    total   = TOTAL_CALLS[]
    success = SUCCESS_CALLS[]
    failed  = FAILED_CALLS[]
    add_n   = ADD_CALLS[]
    inv_n   = INV_SERI_CALLS[]

    success_rate = total > 0 ? 100.0 * success / total : 0.0
    throughput   = elapsed > 0 ? total / elapsed : 0.0
    succ_thr     = elapsed > 0 ? success / elapsed : 0.0

    println()
    println("[Call] Load test summary")
    println("         duration          : $(round(elapsed; digits=3)) s")
    println("         total calls       : $(total)")
    println("         success           : $(success) " *
            "($(round(success_rate; digits=2)) %)")
    println("         failed            : $(failed)")
    println("         add calls         : $(add_n)")
    println("         inv_seri calls    : $(inv_n)")
    println("         throughput        : " *
            "$(round(throughput; digits=2)) calls/s")
    println("         success throughput: " *
            "$(round(succ_thr; digits=2)) calls/s")

    wait_for_enter("[Call] Press Enter to exit...")

    return 0
end

# ================================================================== #
# Entry point                                                        #
# ================================================================== #
#
# The wrapper function keeps the top-level scope free of global
# assignments, avoiding Julia's "soft scope" warning on 1.5+.

function _entry()::Int
    ret = 0
    try
        ret = main()
    finally
        try clear_network_event() catch; end
        try exit_main_thread()    catch; end
        try shutdown()            catch; end
    end
    return ret
end

exit(_entry())