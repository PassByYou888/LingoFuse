# test_e2e_local.jl - Single-process end-to-end test.
#
# Runs the Cross demo (Service + Node + Call) entirely inside one
# Julia process. This isolates the binding's RPC path from the
# multi-process IPC plumbing, so that a failure here is always a
# binding problem, and a success here proves the binding is sound.
#
# What it exercises:
#
#   1. start_callback_consumer
#   2. prepare_service / prepare_client / prepare_done
#   3. App creation + register_call! for two APIs
#   4. app_target + call (synchronous Call)
#   5. app_target + notify (one-way Notify)
#   6. Binary payload round-trip (the same wire format as CrossNode.cpp)
#   7. Error path: call to a non-existent App returns a documented
#      exception rather than crashing
#
# Why single-process works
# ------------------------
# App-name routing is LOCAL-FIRST. When the caller process itself
# hosts an App with the matching name and API, the call is serviced
# locally without touching the network. This test therefore runs the
# full Call dispatch path (payload build -> routing -> callback ->
# response) without requiring any cross-process IPC endpoint.
#
# ---------------------------------------------------------------- #
# HANDLERS MUST NOT TOUCH THE LIBRARY                               #
# ---------------------------------------------------------------- #
# The handlers below run on the callback consumer thread while the
# caller thread is blocked inside LF_Call on a libuv worker. Any
# LF_* call from a handler (for example LF_CreateData to build a
# scratch DataHandle) would contend with the in-flight LF_Call for
# the library's internal locks and deadlock the process.
#
# The handlers therefore implement little-endian integer / float
# I/O directly on Julia Vector{UInt8}, using the private helpers
# below. No DataHandle, no LF_*, no binio.jl. The bytes produced are
# identical to what binio.jl would produce.
#
# ---------------------------------------------------------------- #
# WAIT_CONNECTION_READYOK MUST BE TRUE                              #
# ---------------------------------------------------------------- #
# prepare_done must block until the local client is online AND the
# App has been bound to that client. This is the ONLY way the local
# routing tables see the App. This matches the behavior of the
# Python Server class and the C++ Cross* demos.
#
# Run:
#
#     julia --threads=2 test/test_e2e_local.jl
#
# A minimum of 2 Julia threads is REQUIRED.

ENV["LINGOFUSE_TRACE"] = "0"

const _SRC = joinpath(@__DIR__, "..", "src")

include(joinpath(_SRC, "trace.jl"))
include(joinpath(_SRC, "error.jl"))
include(joinpath(_SRC, "uid.jl"))
include(joinpath(_SRC, "loader.jl"))
include(joinpath(_SRC, "abi.jl"))
include(joinpath(_SRC, "shim.jl"))
include(joinpath(_SRC, "callback.jl"))
include(joinpath(_SRC, "data_handle.jl"))
include(joinpath(_SRC, "binio.jl"))
include(joinpath(_SRC, "app.jl"))
include(joinpath(_SRC, "async.jl"))
include(joinpath(_SRC, "target.jl"))
include(joinpath(_SRC, "p2p.jl"))
include(joinpath(_SRC, "network.jl"))

# ------------------------------------------------------------------ #
# Report                                                             #
# ------------------------------------------------------------------ #

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[e2e_local] $tag  $msg")
    flush(stderr)
    if cond
        passed[] += 1
    else
        failed[] += 1
    end
    return cond
end

# ------------------------------------------------------------------ #
# Little-endian byte helpers (pure Julia, DO NOT touch the library)  #
# ------------------------------------------------------------------ #

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

# Read a NUL-terminated UTF-8 string starting at 0-based offset `off`.
# Returns (string, next_offset) where next_offset is the 0-based
# offset of the byte AFTER the NUL (or length(b)+1 if no NUL found).
function _read_nul_string(b::AbstractVector{UInt8}, off::Int)
    i = off + 1
    @inbounds while i <= length(b) && b[i] != 0x00
        i += 1
    end
    s = String(copy(@view b[off + 1:i - 1]))
    return s, i
end

# ------------------------------------------------------------------ #
# Handlers                                                           #
# ------------------------------------------------------------------ #
#
# Identical wire behavior to example/CrossNode.jl. The two length
# checks at the top of each handler reject the three synthetic
# payloads that register_call! uses to warm up the JIT (empty, two
# bytes, 256 zero bytes).

const CALLS_ADD      = Threads.Atomic{Int}(0)
const CALLS_INV_SERI = Threads.Atomic{Int}(0)

function handle_add(in_bytes::Vector{UInt8})::Vector{UInt8}
    length(in_bytes) == 8 || return UInt8[]

    Threads.atomic_add!(CALLS_ADD, 1)

    a = _le_i32(in_bytes, 0)
    b = _le_i32(in_bytes, 4)
    c = a + b

    println(stderr, "[node] add($(a), $(b)) = $(c)")

    out = UInt8[]
    sizehint!(out, 4)
    _push_i32!(out, c)
    return out
end

function handle_inv_seri(in_bytes::Vector{UInt8})::Vector{UInt8}
    # Minimum: 1 + 2 + 4 + 8 + 1 (NUL) + 4 = 20 bytes.
    length(in_bytes) >= 20 || return UInt8[]

    b_val   = in_bytes[1]                # uint8  @ 0
    w_val   = _le_u16(in_bytes, 1)       # uint16 @ 1
    c_val   = _le_u32(in_bytes, 3)       # uint32 @ 3
    u64_val = _le_u64(in_bytes, 7)       # uint64 @ 7

    # string @ 15, NUL-terminated
    s_val, next_off = _read_nul_string(in_bytes, 15)
    isempty(s_val) && return UInt8[]     # rejects the 256-byte warmup

    # float32 right after the string's NUL
    (length(in_bytes) - next_off) >= 4 || return UInt8[]
    f_val = _le_f32(in_bytes, next_off)

    Threads.atomic_add!(CALLS_INV_SERI, 1)

    println(stderr,
            "[node] inv_seri received: " *
            "[$(b_val), $(w_val), $(c_val), $(u64_val), " *
            "\"$(s_val)\", $(f_val)]")

    out = UInt8[]
    _push_f32!(out, f_val)
    append!(out, codeunits(s_val))
    push!(out, 0x00)
    _push_u64!(out, u64_val)
    _push_u32!(out, c_val)
    _push_u16!(out, w_val)
    _push_u8!(out, b_val)

    println(stderr,
            "[node] inv_seri replied:  " *
            "[$(f_val), \"$(s_val)\", $(u64_val), " *
            "$(c_val), $(w_val), $(b_val)]")

    return out
end

# ------------------------------------------------------------------ #
# Helpers                                                            #
# ------------------------------------------------------------------ #

function unique_endpoint(prefix::String)::String
    pid  = getpid()
    salt = rand(UInt32)
    return "ipc:jle2e_$(prefix)_$(pid)_$(salt)"
end

# ------------------------------------------------------------------ #
# Main                                                               #
# ------------------------------------------------------------------ #

const APP_NAME = "demo"
const ENDPOINT = unique_endpoint("local")

println(stderr, "[e2e_local] endpoint = ", ENDPOINT)

start_callback_consumer()

app = App(APP_NAME, "single-process e2e test")

try
    ok1 = register_call!(app, "add",
                         "add(int a, int b) -> int",
                         handle_add)
    ck(ok1, "register_call! 'add' returned true")

    ok2 = register_call!(app, "inv_seri",
                         "inv_seri() -> reversed typed sequence",
                         handle_inv_seri)
    ck(ok2, "register_call! 'inv_seri' returned true")

    ck(CALLS_ADD[]      == 0,
       "warmup did not reach add (counter = $(CALLS_ADD[]))")
    ck(CALLS_INV_SERI[] == 0,
       "warmup did not reach inv_seri (counter = $(CALLS_INV_SERI[]))")

    reset_prepare()
    set_option("Wait_Connection_ReadyOk", "True")
    set_option("Wait_Connection_Timeout", "10000")
    set_option("Quiet",                  "True")

    tag_s = prepare_service(ENDPOINT, ENDPOINT)
    ck(tag_s >= 0, "prepare_service returned a tag ($(tag_s))")

    tag_c = prepare_client(ENDPOINT, app)
    ck(tag_c >= 0, "prepare_client returned a tag ($(tag_c))")

    ret = prepare_done()
    ck(ret == 1 || check_main_thread(),
       "prepare_done returned 1 (or the main thread is running)")

    ck(check_main_thread(), "check_main_thread returns true")

    ck(check_app(APP_NAME),
       "App '$(APP_NAME)' is visible after prepare_done")
    ck(check_api(APP_NAME, "add"),
       "API 'add' is visible after prepare_done")
    ck(check_api(APP_NAME, "inv_seri"),
       "API 'inv_seri' is visible after prepare_done")

    target = app_target(APP_NAME; timeout_ms = 3000)

    # ------------------------------------------------------------------
    # Call 1: add(10, 32) -> 42.
    # ------------------------------------------------------------------
    println(stderr, "")
    println(stderr, "[e2e_local] --- call add(10, 32) ---")

    r1 = call(target, "add", dh -> begin
        write_int32!(dh, Int32(10))
        write_int32!(dh, Int32(32))
    end)

    ck(length(r1) == 4,
       "add response length is 4 (got $(length(r1)))")

    if length(r1) == 4
        scratch = DataHandle("add")
        try
            write_buffer!(scratch, r1)
            set_cursor_position!(scratch, 0)
            v = read_int32(scratch)
            ck(v == Int32(42),
               "add(10, 32) == 42 (got $(v))")
        finally
            dispose!(scratch)
        end
    end

    ck(CALLS_ADD[] == 1,
       "add handler invoked exactly once (got $(CALLS_ADD[]))")

    # ------------------------------------------------------------------
    # Call 2: inv_seri with the same payload CrossCall uses.
    # ------------------------------------------------------------------
    println(stderr, "")
    println(stderr, "[e2e_local] --- call inv_seri ---")

    r2 = call(target, "inv_seri", dh -> begin
        write_uint8!(dh,  UInt8(200))
        write_uint16!(dh, UInt16(0x10))
        write_uint32!(dh, UInt32(0x2F))
        write_uint64!(dh, UInt64(0x3F))
        write_string!(dh, "hello world")
        write_single!(dh, Float32(3.14))
    end)

    ck(!isempty(r2),
       "inv_seri response is not empty (got $(length(r2)) bytes)")

    if !isempty(r2)
        scratch = DataHandle("inv_seri")
        try
            write_buffer!(scratch, r2)
            set_cursor_position!(scratch, 0)

            rf   = read_single(scratch)
            rs   = read_string!(scratch)
            ru64 = read_uint64(scratch)
            rc   = read_uint32(scratch)
            rw   = read_uint16(scratch)
            rb   = read_uint8(scratch)

            ck(rb   == UInt8(200),        "inv_seri reply b == 200")
            ck(rw   == UInt16(0x10),      "inv_seri reply w == 0x10")
            ck(rc   == UInt32(0x2F),      "inv_seri reply c == 0x2F")
            ck(ru64 == UInt64(0x3F),      "inv_seri reply u64 == 0x3F")
            ck(rs   == "hello world",     "inv_seri reply s == 'hello world'")
            ck(abs(rf - Float32(3.14)) < 1f-6,
                                          "inv_seri reply f ≈ 3.14")
        finally
            dispose!(scratch)
        end
    end

    ck(CALLS_INV_SERI[] == 1,
       "inv_seri handler invoked exactly once (got $(CALLS_INV_SERI[]))")

    # ------------------------------------------------------------------
    # Notify path: one-way, no response.
    #
    # The target API is registered as Call, so the framework emits a
    # warning ("registered as Call but invoked via Notify") and
    # discards the response. That is the documented cross-mode
    # behavior (see LF-MECH-* in the Pascal knowledge base); this
    # block exercises the path deliberately. The handler still runs
    # and its side effect (CALLS_ADD++) is what we assert.
    # ------------------------------------------------------------------
    println(stderr, "")
    println(stderr, "[e2e_local] --- notify add (one-way) ---")

    before = CALLS_ADD[]
    notify(target, "add", dh -> begin
        write_int32!(dh, Int32(1))
        write_int32!(dh, Int32(2))
    end)
    sleep(0.2)

    ck(CALLS_ADD[] == before + 1,
       "notify reached the add handler " *
       "(before=$(before), after=$(CALLS_ADD[]))")

    # ------------------------------------------------------------------
    # Error path: call a non-existent App.
    # ------------------------------------------------------------------
    println(stderr, "")
    println(stderr, "[e2e_local] --- call to a non-existent App ---")

    ghost = app_target("NoSuchApp_$(rand(UInt32))"; timeout_ms = 500)

    threw = false
    caught = nothing
    try
        call(ghost, "anything", UInt8[0x01])
    catch e
        threw = true
        caught = e
    end

    ck(threw, "call to a non-existent App raises")
    ck(caught isa LingoFuseTimeoutError ||
       caught isa LingoFuseCallError,
       "the raised error is LingoFuseTimeoutError or " *
       "LingoFuseCallError (got $(typeof(caught)))")

    println(stderr, "")
    println(stderr, "[e2e_local] counters: " *
                    "add=$(CALLS_ADD[])  inv_seri=$(CALLS_INV_SERI[])")

finally
    try exit_main_thread()       catch; end
    try dispose!(app)            catch; end
    try stop_callback_consumer() catch; end
    try shutdown()               catch; end
end

println(stderr, "")
println(stderr, "[e2e_local] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[e2e_local] OK")
    exit(0)
else
    println(stderr, "[e2e_local] FAILED")
    exit(1)
end