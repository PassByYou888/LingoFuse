# CrossCall.jl - Load-tester for the "ipc:cross" endpoint.
#
# Connects as a pure consumer (no App) and spawns a configurable
# number of Julia tasks. Each task repeatedly invokes "demo.add" or
# "demo.inv_seri" at random for a fixed duration, then reports
# aggregate throughput.
#
# Concurrency note
# ----------------
# LF_Call is dispatched through @threadcall in abi.jl, so every call
# consumes one libuv worker thread for the duration of the underlying
# C function. libuv's default thread pool has four workers; raising
# it requires the UV_THREADPOOL_SIZE environment variable at process
# start:
#
#     $env:UV_THREADPOOL_SIZE = "32"
#     julia --threads=2 example/CrossCall.jl
#
# With eight concurrent Julia tasks and the default four-worker pool,
# at most four calls are in flight at any moment and the remaining
# tasks queue inside libuv. This is a Julia runtime property, not a
# LingoFuse binding property; the C++ / C# demos use one native
# thread per call and therefore reach higher concurrency on the same
# hardware.
#
# The default task count (8) keeps the queue shallow and the
# throughput stable. Increase it after raising UV_THREADPOOL_SIZE.
#
# Run (after CrossService.jl and CrossNode.jl have started):
#
#     julia --threads=2 example/CrossCall.jl

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using LingoFuse

# ================================================================== #
# Configuration                                                      #
# ================================================================== #

const TARGET_APP      = "demo"
const ENDPOINT        = "ipc:cross"
const WORKER_TASKS    = 8
const TEST_SECONDS    = 10
const CALL_TIMEOUT_MS = 1000
const PAUSE_SECONDS   = 0.001

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
    remote_add(a::Int32, b::Int32) -> Union{Int32,Nothing}

Invoke demo.add via the raw ABI channel. Returns the sum on success
or `nothing` on timeout or failure.
"""
function remote_add(a::Int32, b::Int32)::Union{Int32,Nothing}
    param = DataHandle("add")
    try
        write_int32!(param, a)
        write_int32!(param, b)

        raw = LF_Call(TARGET_APP, param.handle, UInt64(CALL_TIMEOUT_MS))
        raw == C_NULL && return nothing

        result = DataHandle(raw, true)
        try
            buffer_size(result) < 4 && return nothing
            set_cursor_position!(result, 0)
            return read_int32(result)
        finally
            dispose!(result)
        end
    catch
        return nothing
    finally
        dispose!(param)
    end
end

"""
    remote_inv_seri() -> Union{String,Nothing}

Invoke demo.inv_seri and format the reply. Returns a human-readable
string on success or `nothing` on failure.
"""
function remote_inv_seri()::Union{String,Nothing}
    const_b = UInt8(200)
    const_w = UInt16(0x10)
    const_c = UInt32(0x2F)
    const_u = UInt64(0x3F)
    const_s = "hello world"
    const_f = Float32(3.14)

    param = DataHandle("inv_seri")
    try
        write_uint8!(param,  const_b)
        write_uint16!(param, const_w)
        write_uint32!(param, const_c)
        write_uint64!(param, const_u)
        write_string!(param, const_s)
        write_single!(param, const_f)

        raw = LF_Call(TARGET_APP, param.handle, UInt64(CALL_TIMEOUT_MS))
        raw == C_NULL && return nothing

        result = DataHandle(raw, true)
        try
            buffer_size(result) == 0 && return nothing
            set_cursor_position!(result, 0)

            rf   = read_single(result)
            rs   = read_string!(result)
            ru64 = read_uint64(result)
            rc   = read_uint32(result)
            rw   = read_uint16(result)
            rb   = read_uint8(result)

            return "reply: [$(rb), $(rw), $(rc), $(ru64), \"$(rs)\", $(rf)]" *
                   "  original: [$(const_b), $(const_w), $(const_c), " *
                   "$(const_u), \"$(const_s)\", $(const_f)]"
        finally
            dispose!(result)
        end
    catch
        return nothing
    finally
        dispose!(param)
    end
end

# ================================================================== #
# Worker task body                                                   #
# ================================================================== #

function worker_task(id::Int, deadline::Float64)
    while time() < deadline
        Threads.atomic_add!(TOTAL_CALLS, 1)

        if rand() < 0.5
            Threads.atomic_add!(ADD_CALLS, 1)
            a = Int32(rand(1:1000))
            b = Int32(rand(1:1000))
            r = remote_add(a, b)
            if r === nothing
                Threads.atomic_add!(FAILED_CALLS, 1)
            else
                Threads.atomic_add!(SUCCESS_CALLS, 1)
            end
        else
            Threads.atomic_add!(INV_SERI_CALLS, 1)
            r = remote_inv_seri()
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
# Main                                                               #
# ================================================================== #

function wait_for_enter()
    print("[Call] Press Enter to exit...")
    flush(stdout)
    readline()
    return nothing
end

function main()::Int
    println("=== Cross Call (Client) ===")

    set_option("Wait_Connection_ReadyOk", "True")
    set_option("Overlap_Connection",      "True")
    set_option("Wait_Connection_Timeout", "10000")

    reset_prepare()

    tag_c = prepare_client(ENDPOINT, nothing)
    if tag_c < 0
        println(stderr,
                "[FATAL] prepare_client returned $(tag_c) for $(ENDPOINT)")
        return 1
    end

    if prepare_done() != 1 && !check_main_thread()
        println(stderr, "[FATAL] prepare_done failed")
        return 1
    end

    # Wait for the "demo" App to become visible on the mesh.
    visible = false
    for _ in 1:100
        if check_app(TARGET_APP)
            visible = true
            break
        end
        sleep(0.1)
    end
    if !visible
        println(stderr, "[FATAL] target app '$(TARGET_APP)' did not become visible")
        return 1
    end

    println("[Call] Connected to $(ENDPOINT).")
    println("[Call] Starting $(TEST_SECONDS)-second load test " *
            "with $(WORKER_TASKS) tasks...")

    t_start  = time()
    deadline = t_start + TEST_SECONDS

    tasks = Task[]
    for i in 1:WORKER_TASKS
        push!(tasks, Threads.@spawn worker_task(i, deadline))
    end
    foreach(wait, tasks)

    t_end   = time()
    elapsed = t_end - t_start

    total     = TOTAL_CALLS[]
    success   = SUCCESS_CALLS[]
    failed    = FAILED_CALLS[]
    add_n     = ADD_CALLS[]
    inv_n     = INV_SERI_CALLS[]

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
    println("         throughput        : $(round(throughput; digits=2)) calls/s")
    println("         success throughput: $(round(succ_thr; digits=2)) calls/s")

    wait_for_enter()
    return 0
end

ret = 0
try
    ret = main()
finally
    try clear_network_event() catch; end
    try exit_main_thread()    catch; end
    try shutdown()            catch; end
end

println("[Call] Bye.")
exit(ret)