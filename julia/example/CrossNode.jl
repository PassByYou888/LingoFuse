# CrossNode.jl - Worker node exposing the "demo" application.
#
# Registers two Call APIs on the "demo" App:
#
#   add       (int32 a, int32 b)                          -> int32
#   inv_seri  (uint8, uint16, uint32, uint64,
#              string(NUL), float)                         -> same types reversed
#
# The wire format is byte-for-byte identical to the C++ / C# /
# Pascal / Python / JavaScript CrossNode demos. A Julia CrossNode can
# be driven by a CrossCall written in any of those languages, and a
# Julia CrossCall can drive a CrossNode written in any of them.
#
# ---------------------------------------------------------------- #
# HANDLERS MUST NOT TOUCH THE LIBRARY                               #
# ---------------------------------------------------------------- #
# The handlers below run on the callback consumer thread while a
# peer's LF_Call (or the local LF_LocalCall path) is blocked on a
# libuv worker. Any LF_* call from a handler -- most commonly
# LF_CreateData to build a scratch DataHandle -- would contend with
# that in-flight call for the library's internal locks and deadlock
# the process.
#
# The handlers therefore implement little-endian integer / float
# I/O directly on Julia Vector{UInt8}, using the private helpers
# below. No DataHandle, no LF_*, no binio.jl. The bytes produced are
# identical to what binio.jl would produce.
#
# ---------------------------------------------------------------- #
# OBSERVABILITY CONTRACT                                            #
# ---------------------------------------------------------------- #
# This file deliberately mirrors the C++ CrossNode.cpp behavior:
# EVERY call prints a single line describing the request and the
# computed result. There is no heartbeat, no sampling, no aggregate
# statistics.
#
# Line format:
#
#   add        [Node] add(a, b) = c
#   inv_seri   [Node] inv_seri received: [b, w, c, u64, "s", f]
#   inv_seri   [Node] inv_seri replied:  [f, "s", u64, c, w, b]
#   error      [Node] inv_seri: failed to read data.
#
# Multi-threaded output
# ---------------------
# Handlers run on the callback consumer thread; concurrent Calls to
# the same App are possible. Each line is built in memory first and
# emitted under one process-wide lock, exactly like C++'s log_line.
#
# ---------------------------------------------------------------- #
# RUN AND STARTUP ORDER                                             #
# ---------------------------------------------------------------- #
# CrossService.jl must be running BEFORE this node is started. If it
# is not, the node still starts and connects to a local loopback
# queue, but its App registration never reaches any other process.
# In that state the terminal stays silent after "[Node] Online." -
# there will be no request lines because no requests can arrive.
#
#     Terminal 1:  julia --threads=2 example/CrossService.jl
#     Terminal 2:  julia --threads=2 example/CrossNode.jl     (this file)
#     Terminal 3:  julia --threads=2 example/CrossCall.jl
#
# A minimum of 2 Julia threads is REQUIRED because the callback
# consumer task must not run on the main Julia thread.
#
# Cleanup order (Pascal LF-CLEAN-001):
#
#     clear_network_event  ->  exit_main_thread  ->  dispose!(app)
#         ->  stop_callback_consumer  ->  shutdown

push!(LOAD_PATH, joinpath(@__DIR__, "..", "src"))

using LingoFuse

const ENDPOINT = "ipc:cross"
const APP_NAME = "demo"

const REGISTRATION_GRACE_SECONDS = 3.0

# ================================================================== #
# Thread-safe single-line logging                                    #
# ================================================================== #

const _LOG_LOCK = ReentrantLock()

function log_line(io::IO, parts...)
    buf = IOBuffer()
    for p in parts
        print(buf, p)
    end
    line = String(take!(buf))

    lock(_LOG_LOCK) do
        println(io, line)
        flush(io)
    end
    return nothing
end

# ================================================================== #
# Little-endian byte helpers (pure Julia, DO NOT touch the library)  #
# ================================================================== #

@inline function _le_u16(b::AbstractVector{UInt8}, off::Int)::UInt16
    return UInt16(b[off + 1]) | (UInt16(b[off + 2]) << 8)
end

@inline function _le_u32(b::AbstractVector{UInt8}, off::Int)::UInt32
    return UInt32(b[off + 1])           |
           (UInt32(b[off + 2]) << 8)    |
           (UInt32(b[off + 3]) << 16)   |
           (UInt32(b[off + 4]) << 24)
end

@inline function _le_u64(b::AbstractVector{UInt8}, off::Int)::UInt64
    u = UInt64(0)
    @inbounds for i in 0:7
        u |= UInt64(b[off + i + 1]) << (8 * i)
    end
    return u
end

@inline _le_i32(b::AbstractVector{UInt8}, off::Int)::Int32 =
    reinterpret(Int32, _le_u32(b, off))

@inline _le_f32(b::AbstractVector{UInt8}, off::Int)::Float32 =
    reinterpret(Float32, _le_u32(b, off))

@inline function _push_u8!(out::Vector{UInt8}, v::UInt8)
    push!(out, v)
    return nothing
end

@inline function _push_u16!(out::Vector{UInt8}, v::UInt16)
    push!(out, UInt8(v & 0xFF))
    push!(out, UInt8((v >> 8) & 0xFF))
    return nothing
end

@inline function _push_u32!(out::Vector{UInt8}, v::UInt32)
    push!(out, UInt8(v & 0xFF))
    push!(out, UInt8((v >> 8)  & 0xFF))
    push!(out, UInt8((v >> 16) & 0xFF))
    push!(out, UInt8((v >> 24) & 0xFF))
    return nothing
end

@inline function _push_u64!(out::Vector{UInt8}, v::UInt64)
    @inbounds for i in 0:7
        push!(out, UInt8((v >> (8 * i)) & 0xFF))
    end
    return nothing
end

@inline _push_i32!(out::Vector{UInt8}, v::Int32) =
    _push_u32!(out, reinterpret(UInt32, v))

@inline _push_f32!(out::Vector{UInt8}, v::Float32) =
    _push_u32!(out, reinterpret(UInt32, v))

function _read_nul_string(b::AbstractVector{UInt8}, off::Int)
    i = off + 1
    @inbounds while i <= length(b) && b[i] != 0x00
        i += 1
    end
    s = String(copy(@view b[off + 1:i - 1]))
    return s, i
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

# ================================================================== #
# Handlers                                                           #
# ================================================================== #
#
# The two length checks at the top of each handler reject the three
# synthetic payloads that register_call! uses to warm up the JIT
# (empty, two bytes, 256 zero bytes), so the registration phase is
# silent.

# ------------------------------------------------------------------ #
# add(int32, int32) -> int32
# ------------------------------------------------------------------ #
function handle_add(in_bytes::Vector{UInt8})::Vector{UInt8}
    length(in_bytes) == 8 || return UInt8[]

    a = _le_i32(in_bytes, 0)
    b = _le_i32(in_bytes, 4)
    c = a + b

    # CrossNode.cpp:
    #     log_line(std::cout, "[Node] add(", a, ", ", b, ") = ", c);
    log_line(stdout, "[Node] add(", a, ", ", b, ") = ", c)

    out = UInt8[]
    sizehint!(out, 4)
    _push_i32!(out, c)
    return out
end

# ------------------------------------------------------------------ #
# inv_seri() -> reversed typed sequence
# ------------------------------------------------------------------ #
function handle_inv_seri(in_bytes::Vector{UInt8})::Vector{UInt8}
    # Minimum well-formed length: 1 + 2 + 4 + 8 + 1 + 4 = 20 bytes.
    length(in_bytes) >= 20 || return UInt8[]

    b_val   = in_bytes[1]
    w_val   = _le_u16(in_bytes, 1)
    c_val   = _le_u32(in_bytes, 3)
    u64_val = _le_u64(in_bytes, 7)

    s_val, next_off = _read_nul_string(in_bytes, 15)
    isempty(s_val) && return UInt8[]     # rejects the 256-byte warmup

    (length(in_bytes) - next_off) >= 4 || return UInt8[]
    f_val = _le_f32(in_bytes, next_off)

    # CrossNode.cpp:
    #     log_line(std::cout, "[Node] inv_seri received: [",
    #              static_cast<int>(b), ", ", w, ", ", c, ", ",
    #              u64, ", \"", s, "\", ", f, "]");
    log_line(stdout, "[Node] inv_seri received: [",
             b_val, ", ", w_val, ", ", c_val, ", ", u64_val,
             ", \"", s_val, "\", ", f_val, "]")

    out = UInt8[]
    _push_f32!(out, f_val)
    append!(out, codeunits(s_val))
    push!(out, 0x00)
    _push_u64!(out, u64_val)
    _push_u32!(out, c_val)
    _push_u16!(out, w_val)
    _push_u8!(out, b_val)

    #     log_line(std::cout, "[Node] inv_seri replied: [",
    #              f, ", \"", s, "\", ", u64, ", ", c, ", ",
    #              w, ", ", static_cast<int>(b), "]");
    log_line(stdout, "[Node] inv_seri replied:  [",
             f_val, ", \"", s_val, "\", ", u64_val, ", ", c_val,
             ", ", w_val, ", ", b_val, "]")

    return out
end

# ================================================================== #
# Main                                                               #
# ================================================================== #

function main()::Int
    banner("Cross Node (Worker)")

    # Wait_Connection_ReadyOk = False (deployment mode), matching
    # Pascal cross_node.lpr, Python cross_node.py, and C++
    # CrossNode.cpp. The node may start before the coordinator; the
    # C4 client reconnects automatically.
    set_option("Wait_Connection_ReadyOk", "False")
    set_option("Overlap_Connection",     "True")

    reset_prepare()
    start_callback_consumer()

    app = App(APP_NAME, "Julia worker node")
    try
        ok1 = register_call!(app, "add",
                             "add(int a, int b) -> int",
                             handle_add)
        if !ok1
            println(stderr, "[FATAL] Failed to register API 'add'")
            return 1
        end

        ok2 = register_call!(app, "inv_seri",
                             "inv_seri() -> reversed typed sequence",
                             handle_inv_seri)
        if !ok2
            println(stderr, "[FATAL] Failed to register API 'inv_seri'")
            return 1
        end

        println("[Node] Registered APIs 'add' and 'inv_seri' " *
                "under application '$(APP_NAME)'.")

        tag_c = prepare_client(ENDPOINT, app)
        if tag_c < 0
            println(stderr, "[FATAL] prepare_client returned $(tag_c) " *
                            "for $(ENDPOINT)")
            return 1
        end

        if prepare_done() != 1 && !check_main_thread()
            println(stderr, "[FATAL] prepare_done failed")
            return 1
        end

        # Give the registration broadcast time to reach the mesh.
        println("[Node] Framework online; waiting " *
                "$(REGISTRATION_GRACE_SECONDS)s for the registration " *
                "broadcast to propagate...")
        sleep(REGISTRATION_GRACE_SECONDS)

        println("[Node] Online.  Waiting for calls...")
        println()

        wait_for_enter("[Node] Press Enter to exit...")

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