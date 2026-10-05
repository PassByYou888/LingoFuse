# CrossService.jl - IPC beacon for the "ipc:cross" endpoint.
#
# The service does not register any API. Its sole purpose is to act
# as the discovery/anchor endpoint that workers and callers connect
# to. Behaviour matches the C++ / C# / Pascal / Python demos:
#
#   1. Load the binding.
#   2. Reset preparation state.
#   3. Prepare the service endpoint "ipc:cross" and a self-client.
#   4. Start the framework.
#   5. Wait for Enter.
#   6. Clean up in the LF-CLEAN-001 order.
#
# Run from the julia directory:
#
#     julia --threads=2 example/CrossService.jl

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using LingoFuse

const ENDPOINT = "ipc:cross"

function wait_for_enter()
    print("IPC service '$(ENDPOINT)' is running. Press Enter to exit...")
    flush(stdout)
    readline()
    return nothing
end

function main()
    println("=== Cross Service (Coordinator) ===")

    # Deployment options, identical to the other language demos.
    set_option("Wait_Connection_ReadyOk", "True")
    set_option("Overlap_Connection",    "True")
    set_option("Wait_Connection_Timeout", "10000")

    reset_prepare()

    tag_s = prepare_service(ENDPOINT, ENDPOINT)
    if tag_s < 0
        println(stderr, "[FATAL] prepare_service returned $(tag_s) for $(ENDPOINT)")
        return 1
    end
    println("[Service] Prepared service endpoint $(ENDPOINT) (tag=$(tag_s))")

    # Self-client anchors the C4 broadcast loop at this process.
    tag_c = prepare_client(ENDPOINT, nothing)
    if tag_c < 0
        println(stderr, "[FATAL] prepare_client returned $(tag_c) for $(ENDPOINT)")
        return 1
    end
    println("[Service] Prepared self-client (tag=$(tag_c))")

    if prepare_done() != 1 && !check_main_thread()
        println(stderr, "[FATAL] prepare_done failed and the main thread is not running")
        return 1
    end

    wait_for_enter()
    println("[Service] Shutting down...")
    return 0
end

ret = 0
try
    ret = main()
finally
    try exit_main_thread() catch; end
    try shutdown()         catch; end
end

println("[Service] Bye.")
exit(ret)