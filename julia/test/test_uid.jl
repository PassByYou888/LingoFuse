# test_uid.jl - Acceptance test for the UID type (src/uid.jl).
#
# Coverage:
#   - Type properties: UID_SIZE, sizeof, isbits, length
#   - zero_uid
#   - uid_from_bytes (valid inputs, length errors)
#   - uid_from_hex (lower / upper / mixed case, whitespace stripping,
#     length errors, invalid characters)
#   - Round-trips: uid_from_bytes ∘ uid_to_bytes, and
#     uid_from_hex ∘ uid_to_hex
#   - Equality, hashing, and Dict-key behaviour
#   - is_zero_uid
#   - Ref(u) construction and its size
#   - show formatting
#
# This file has no C dependency and no network dependency. It exercises
# only the pure-Julia UID type, so it runs on any Julia installation
# without the LingoFuse runtime.
#
# Exit code: 0 on success, 1 on any failure.

const _SRC = joinpath(@__DIR__, "..", "src")

include(joinpath(_SRC, "uid.jl"))

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test_uid] $tag  $msg")
    flush(stderr)
    if cond
        passed[] += 1
    else
        failed[] += 1
    end
    return cond
end

# -------------------------------------------------------------------- #
# Type properties                                                      #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- type properties ---")

ck(UID_SIZE == 32, "UID_SIZE == 32")
ck(sizeof(LFShimUID) == 32, "sizeof(LFShimUID) == 32")
ck(isbitstype(LFShimUID), "LFShimUID is an isbits type")
ck(length(zero_uid()) == 32, "zero_uid() has length 32")

# -------------------------------------------------------------------- #
# zero_uid                                                             #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- zero_uid ---")

let u = zero_uid()
    ck(all(==(0x00), u), "zero_uid is all zeros")
    ck(is_zero_uid(u), "is_zero_uid(zero_uid()) is true")
    ck(u == zero_uid(), "two calls to zero_uid are equal")
end

# -------------------------------------------------------------------- #
# uid_from_bytes                                                       #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- uid_from_bytes ---")

let bytes = UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                  0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
                  0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
                  0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20]
    u = uid_from_bytes(bytes)
    ck(length(u) == 32, "uid_from_bytes returns 32 elements")
    ck(u[1] == 0x01, "first byte preserved")
    ck(u[32] == 0x20, "last byte preserved")
end

let
    threw = false
    try
        uid_from_bytes(UInt8[0x00, 0x00])
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_from_bytes rejects a 2-byte input")
end

let
    threw = false
    try
        uid_from_bytes(zeros(UInt8, 33))
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_from_bytes rejects a 33-byte input")
end

let
    threw = false
    try
        uid_from_bytes(UInt8[])
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_from_bytes rejects an empty input")
end

# -------------------------------------------------------------------- #
# uid_from_hex                                                         #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- uid_from_hex ---")

const HEX_LOWER = "0102030405060708090a0b0c0d0e0f10" *
                  "1112131415161718191a1b1c1d1e1f20"

const HEX_UPPER = "0102030405060708090A0B0C0D0E0F10" *
                  "1112131415161718191A1B1C1D1E1F20"

let u = uid_from_hex(HEX_LOWER)
    ck(u[1] == 0x01, "lowercase hex: first byte")
    ck(u[16] == 0x10, "lowercase hex: byte 16")
    ck(u[17] == 0x11, "lowercase hex: byte 17")
    ck(u[32] == 0x20, "lowercase hex: last byte")
end

let u_lower = uid_from_hex(HEX_LOWER)
    u_upper = uid_from_hex(HEX_UPPER)
    ck(u_lower == u_upper,
       "uppercase and lowercase hex produce the same UID")
end

let u = uid_from_hex("   " * HEX_LOWER * "   ")
    ck(u == uid_from_hex(HEX_LOWER),
       "leading/trailing whitespace is stripped")
end

let
    threw = false
    try
        uid_from_hex("abcd")
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_from_hex rejects a 4-character input")
end

let
    threw = false
    try
        uid_from_hex(HEX_LOWER[1:63])   # 63 chars
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_from_hex rejects a 63-character input")
end

let
    threw = false
    try
        uid_from_hex(HEX_LOWER * "0")   # 65 chars
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_from_hex rejects a 65-character input")
end

let
    threw = false
    try
        # 'z' is not a hex digit
        uid_from_hex("zz02030405060708090a0b0c0d0e0f10" *
                     "1112131415161718191a1b1c1d1e1f20")
    catch e
        threw = e isa ArgumentError
    end
    ck(threw, "uid_from_hex rejects non-hex characters")
end

# -------------------------------------------------------------------- #
# Round-trips                                                          #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- round-trips ---")

let u1 = uid_from_hex(HEX_LOWER)
    b = uid_to_bytes(u1)
    ck(length(b) == 32, "uid_to_bytes returns 32 bytes")
    ck(b[1] == 0x01, "uid_to_bytes preserves the first byte")
    ck(b[32] == 0x20, "uid_to_bytes preserves the last byte")

    u2 = uid_from_bytes(b)
    ck(u1 == u2, "uid_from_bytes ∘ uid_to_bytes is identity")

    s = uid_to_hex(u1)
    ck(length(s) == 64, "uid_to_hex returns 64 characters")
    ck(s == HEX_LOWER, "uid_to_hex returns the expected lowercase string")

    u3 = uid_from_hex(s)
    ck(u1 == u3, "uid_from_hex ∘ uid_to_hex is identity")
end

# -------------------------------------------------------------------- #
# Equality and hashing                                                 #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- equality and hashing ---")

let a = uid_from_hex(HEX_LOWER)
    b = uid_from_hex(HEX_LOWER)
    c = uid_from_hex(HEX_UPPER)
    d = zero_uid()

    ck(a == b, "identical UIDs compare equal")
    ck(a == c, "case-insensitive hex parses to the same UID")
    ck(a != d, "non-zero UID differs from zero_uid")
    ck(hash(a) == hash(b), "equal UIDs hash the same")
    ck(hash(a) != hash(d),
       "distinct UIDs hash differently (best-effort check)")

    # Dict-key behaviour
    dict = Dict{LFShimUID, String}()
    dict[a] = "first"
    ck(dict[b] == "first", "UID works as a Dict key")
    ck(haskey(dict, c), "case-equivalent UID is a Dict key hit")
    ck(!haskey(dict, d), "zero_uid is not a key of a Dict keyed by a")
end

# -------------------------------------------------------------------- #
# is_zero_uid                                                          #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- is_zero_uid ---")

ck(is_zero_uid(zero_uid()), "zero_uid is zero")
ck(!is_zero_uid(uid_from_hex(HEX_LOWER)), "non-zero UID is not zero")

let mostly_zero = ntuple(i -> i == 32 ? UInt8(1) : UInt8(0), 32)
    ck(!is_zero_uid(mostly_zero),
       "UID with a single non-zero byte is not zero")
end

let all_but_first = ntuple(i -> i == 1 ? UInt8(0xFF) : UInt8(0), 32)
    ck(!is_zero_uid(all_but_first),
       "UID with a leading non-zero byte is not zero")
end

# -------------------------------------------------------------------- #
# Ref construction                                                     #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- Ref construction ---")

let u = uid_from_hex(HEX_LOWER)
    r = Ref(u)
    ck(r isa Base.RefValue{LFShimUID},
       "Ref(u) is Base.RefValue{LFShimUID}")
    ck(r isa LFShimUIDRef,
       "Ref(u) is LFShimUIDRef (the named alias)")
    ck(r[] == u, "Ref round-trip preserves the value")
    ck(sizeof(r) == 32, "sizeof(Ref(u)) == 32")
end

let r = Ref(zero_uid())
    ck(is_zero_uid(r[]), "Ref(zero_uid()) round-trips")
end

# -------------------------------------------------------------------- #
# Display                                                              #
# -------------------------------------------------------------------- #

println(stderr, "[test_uid] --- display ---")

let u = uid_from_hex(HEX_LOWER)
    s = sprint(show, u)
    ck(startswith(s, "UID("), "show output starts with 'UID('")
    ck(endswith(s, ")"), "show output ends with ')'")
    ck(occursin(HEX_LOWER, s), "show output contains the hex string")
end

# -------------------------------------------------------------------- #
# Summary                                                              #
# -------------------------------------------------------------------- #

println(stderr, "")
println(stderr, "[test_uid] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test_uid] OK")
    exit(0)
else
    println(stderr, "[test_uid] FAILED")
    exit(1)
end