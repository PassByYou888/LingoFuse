# CrossService.jl - IPC beacon for the "ipc:cross" endpoint.
#
# This process is the coordination point. It does NOT register any
# API and does NOT create an App. Its sole purpose is to be the
# discovery / anchor endpoint that worker nodes and callers connect
# to.
#
# Behavior matches the C++ / C# / Pascal / Python CrossService demos:
#
#   1. Load the LingoFuse library (done implicitly at `using` time).
#   2. Reset preparation state.
#   3. Prepare the service endpoint "ipc:cross".
#   4. Prepare a self-client to anchor the C4 broadcast loop.
#   5. Start the framework (LF_PrepareDone).
#   6. Wait for the user to press Enter.
#   7. Clean up in the LF-CLEAN-001 order.
#
# Cleanup order (Pascal LF-CLEAN-001):
#
#     exit_main_thread  ->  shutdown
#
# There is no App to free, so the sequence is only two steps. The
# shutdown call is idempotent and safe even if prepare_done failed.
#
# ---------------------------------------------------------------- #
# STARTUP ORDER (IMPORTANT)                                         #
# ---------------------------------------------------------------- #
# The three example processes must be started in this order:
#
#     1. CrossService.jl    (keep running)
#     2. CrossNode.jl       (keep running)
#     3. CrossCall.jl       (runs for ~10s, then exits)
#
# If CrossService is stopped while CrossNode is still running,
# CrossNode loses its anchor and its App registration stops
# propagating. CrossCall will then report:
#
#     [FATAL] target app 'demo' did not become visible within 10 seconds
#
# This is expected behavior, not a binding defect: the mesh has no
# live coordination point.
#
# Run from the julia directory:
#
#     julia --threads=2 example/CrossService.jl
#
# A minimum of 2 Julia threads is REQUIRED because the callback
# consumer task must not run on the main Julia thread.

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using LingoFuse

const ENDPOINT = "ipc:cross"

# ------------------------------------------------------------------ #
# Helpers                                                            #
# ------------------------------------------------------------------ #

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

# ------------------------------------------------------------------ #
# Main                                                               #
# ------------------------------------------------------------------ #

function main()::Int
    banner("Cross Service (Coordinator)")

    # Deployment options. These match the C++ / C# / Python demos so
    # that all bindings behave identically on the same mesh:
    #
    #   Wait_Connection_ReadyOk = True
    #       prepare_done blocks until every prepared client is online.
    #       This is the correct choice for a coordinator: it must not
    #       advertise readiness before the IPC endpoint is actually
    #       accepting connections.
    #
    #   Overlap_Connection = True
    #       Allow multiple clients to connect to the same address.
    #       The coordinator itself creates a self-client, and worker
    #       nodes may also connect from other processes; the option
    #       has no effect across processes but is set for symmetry
    #       with the worker / caller demos.
    #
    #   Wait_Connection_Timeout = 10000
    #       Ten seconds is ample on localhost and on most LANs. The
    #       library imposes a 5,000 ms floor if a smaller value is
    #       supplied.
    set_option("Wait_Connection_ReadyOk", "True")
    set_option("Overlap_Connection",     "True")
    set_option("Wait_Connection_Timeout", "10000")

    reset_prepare()

    tag_s = prepare_service(ENDPOINT, ENDPOINT)
    if tag_s < 0
        println(stderr, "[FATAL] prepare_service returned $(tag_s) " *
                        "for $(ENDPOINT)")
        return 1
    end
    println("[Service] Prepared service endpoint $(ENDPOINT) (tag=$(tag_s))")

    tag_c = prepare_client(ENDPOINT, nothing)
    if tag_c < 0
        println(stderr, "[FATAL] prepare_client returned $(tag_c) " *
                        "for $(ENDPOINT)")
        return 1
    end
    println("[Service] Prepared self-client (tag=$(tag_c))")

    ret = prepare_done()
    if ret != 1 && !check_main_thread()
        println(stderr, "[FATAL] prepare_done returned $(ret) and the " *
                        "main thread is not running")
        return 1
    end

    wait_for_enter("IPC service '$(ENDPOINT)' is running. " *
                   "Press Enter to exit...")

    println("[Service] Shutting down...")
    return 0
end

# ------------------------------------------------------------------ #
# Entry point                                                        #
# ------------------------------------------------------------------ #
#
# The cleanup sequence runs in `finally` so that every exit path
# (normal return, early return, exception) performs the same
# teardown. Both calls are individually wrapped in `try` so that a
# failure in one does not prevent the other from running.
#
# The wrapper function exists so that the top-level scope contains no
# assignment to a global (which would trigger Julia's "soft scope"
# warning on 1.5+). The same pattern is used by CrossCall.jl.

function _entry()::Int
    ret = 0
    try
        ret = main()
    finally
        try exit_main_thread() catch; end
        try shutdown()         catch; end
    end
    return ret
end

exit(_entry())