# CrossNode.jl - Worker node exposing the "demo" application.
#
# Registers two Call APIs on the "demo" App:
#
#   add       (int32 a, int32 b)                          -> int32
#   inv_seri  (uint8, uint16, uint32, uint64,
#              string(NUL), float)                         -> same types reversed
#
# Wire format is byte-for-byte identical to the C++ / C# / Pascal /
# Python / JavaScript CrossNode demos. A Julia CrossNode can be
# driven by a CrossCall written in any of those languages, and a
# Julia CrossCall can drive a CrossNode written in any of them.
#
# The two APIs use the raw ABI channel, not JSON. Every byte written
# matches what CrossNode.cpp writes for the same logical call.
#
# Run (after CrossService.jl has started):
#
#     julia --threads=2 example/CrossNode.jl
#
# Cleanup order (Pascal LF-CLEAN-001):
#     clear_network_event -> exit_main_thread -> dispose!(app)
#         -> stop_callback_consumer -> shutdown

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using LingoFuse

const ENDPOINT = "ipc:cross"
const APP_NAME = "demo"

# ================================================================== #
# Handlers                                                           #
# ================================================================== #
#
# Each handler receives a Vector{UInt8} with the raw request payload
# and returns a Vector{UInt8} with the raw response payload. No JSON
# is involved; the framing is entirely the caller's contract.
#
# The handlers run on the callback consumer thread. They must not
# block and must not call any blocking LingoFuse function. Every
# operation below is a pure byte transformation.

# ------------------------------------------------------------------ #
# add(int32, int32) -> int32
# ------------------------------------------------------------------ #
function handle_add(in_bytes::Vector{UInt8})::Vector{UInt8}
    if length(in_bytes) != 8
        throw(ArgumentError(
            "add: expected 8 bytes (int32 + int32), got $(length(in_bytes))"
        ))
    end

    in_dh  = DataHandle("add")
    out_dh = DataHandle("add")
    try
        write_buffer!(in_dh, in_bytes)
        set_cursor_position!(in_dh, 0)

        a = read_int32(in_dh)
        b = read_int32(in_dh)
        c = a + b

        println("[Node] add($(a), $(b)) = $(c)")

        write_int32!(out_dh, c)
        set_cursor_position!(out_dh, 0)
        return read_all_bytes(out_dh)
    finally
        dispose!(in_dh)
        dispose!(out_dh)
    end
end

# ------------------------------------------------------------------ #
# inv_seri() -> reversed typed sequence
# ------------------------------------------------------------------ #
function handle_inv_seri(in_bytes::Vector{UInt8})::Vector{UInt8}
    in_dh  = DataHandle("inv_seri")
    out_dh = DataHandle("inv_seri")
    try
        write_buffer!(in_dh, in_bytes)
        set_cursor_position!(in_dh, 0)

        b   = read_uint8(in_dh)
        w   = read_uint16(in_dh)
        c   = read_uint32(in_dh)
        u64 = read_uint64(in_dh)
        s   = read_string!(in_dh)      # stops at the NUL terminator
        f   = read_single(in_dh)

        println("[Node] inv_seri received: " *
                "[$(b), $(w), $(c), $(u64), \"$(s)\", $(f)]")

        # Reply in reverse field order, matching CrossNode.cpp.
        write_single!(out_dh, f)
        write_string!(out_dh, s)
        write_uint64!(out_dh, u64)
        write_uint32!(out_dh, c)
        write_uint16!(out_dh, w)
        write_uint8!(out_dh, b)

        println("[Node] inv_seri replied:  " *
                "[$(f), \"$(s)\", $(u64), $(c), $(w), $(b)]")

        set_cursor_position!(out_dh, 0)
        return read_all_bytes(out_dh)
    finally
        dispose!(in_dh)
        dispose!(out_dh)
    end
end

# ================================================================== #
# Main                                                               #
# ================================================================== #

function wait_for_enter()
    print("[Node] Online. Press Enter to exit...")
    flush(stdout)
    readline()
    return nothing
end

function main()::Int
    println("=== Cross Node (Worker) ===")

    # The worker may start before the coordinator; it reconnects
    # automatically once the endpoint becomes reachable.
    set_option("Wait_Ready",         "False")
    set_option("Overlap_Connection", "True")

    reset_prepare()
    start_callback_consumer()

    app = App(APP_NAME, "Julia worker node")
    try
        ok1 = register_call!(app, "add",
                             "add(int a, int b) -> int",
                             handle_add)
        ok1 || (println(stderr, "[FATAL] Failed to register API 'add'"); return 1)

        ok2 = register_call!(app, "inv_seri",
                             "inv_seri() -> reversed typed sequence",
                             handle_inv_seri)
        ok2 || (println(stderr, "[FATAL] Failed to register API 'inv_seri'"); return 1)

        tag_c = prepare_client(ENDPOINT, app)
        if tag_c < 0
            println(stderr,
                    "[FATAL] prepare_client returned $(tag_c) for $(ENDPOINT)")
            return 1
        end

        if prepare_done() != 1 && !check_main_thread()
            println(stderr, "[FATAL] prepare_done failed")
            return 1
        end

        println("[Node] Registered APIs 'add' and 'inv_seri' " *
                "under application '$(APP_NAME)'.")

        wait_for_enter()
        println("[Node] Shutting down...")
        return 0
    finally
        try clear_network_event()    catch; end
        try exit_main_thread()       catch; end
        try dispose!(app)            catch; end
        try stop_callback_consumer() catch; end
        try shutdown()               catch; end
    end
end

exit(main())