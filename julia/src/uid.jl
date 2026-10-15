# uid.jl - UID type and helpers for the LingoFuse Julia binding.
#
# The LingoFuse C ABI represents a UID as a 32-byte Pascal array
# (TP2P_UID___ = array[0..31] of Byte). The Julia binding mirrors that
# representation as an NTuple{32, UInt8}, which:
#
#   - has the same memory layout (32 contiguous bytes),
#   - is a primitive isbits type, so it is passed by value in ccall,
#   - is accepted by Ref{...} for the C shim's Ref{LFShimUID} parameters,
#   - has built-in ==, hash, and Dict-key support from the tuple type.
#
# All UID helpers live in this file. Nothing else in the binding
# defines a UID type or a UID-level helper. See c_ext/lf_shim.h for
# the C-side layout that this type mirrors byte-for-byte.

# -------------------------------------------------------------------- #
# Type definition                                                      #
# -------------------------------------------------------------------- #

"""
    UID_SIZE

Number of bytes in a LingoFuse UID. Fixed by the C ABI at 32.
"""
const UID_SIZE = 32

"""
    LFShimUID

A 32-byte LingoFuse session UID.

Layout-compatible with the C shim's `lf_shim_uid_t` and with the
Pascal-side `TP2P_UID___`. Use `uid_from_hex`, `uid_from_bytes`, and
`zero_uid` to build one; use `uid_to_hex` and `uid_to_bytes` to
convert it back.
"""
const LFShimUID = NTuple{UID_SIZE, UInt8}

"""
    LFShimUIDRef

Alias for the Ref type the ccall bindings use when a UID must be
passed by reference to the C shim (for example,
`lf_shim_uid_async_call`).

This is simply `Base.RefValue{LFShimUID}`. Provided as a named alias
so that the ccall signatures read naturally.
"""
const LFShimUIDRef = Base.RefValue{LFShimUID}

# -------------------------------------------------------------------- #
# Hex-digit helpers                                                    #
# -------------------------------------------------------------------- #

# Lowercase ASCII hex digits, indexed 1..16 for nibble values 0..15.
# A lookup table is used rather than `string(nibble; base=16)` so that
# `uid_to_hex` allocates exactly one object (the result string) and
# does not go through the generic integer formatting path.
const _HEX_CHARS = UInt8[
    0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66,
]

@inline function _hex_digit(c::Char)::UInt8
    if '0' <= c <= '9'
        return UInt8(c - '0')
    elseif 'a' <= c <= 'f'
        return UInt8(c - 'a' + 10)
    elseif 'A' <= c <= 'F'
        return UInt8(c - 'A' + 10)
    else
        throw(ArgumentError("invalid hex digit: '$c'"))
    end
end

# -------------------------------------------------------------------- #
# Construction                                                         #
# -------------------------------------------------------------------- #

"""
    zero_uid() -> LFShimUID

Return a fresh all-zero UID.

This is the "null UID" that the C ABI uses to signal "no sender
identity": `LF_Get_P2P_UID` returns it when called on an output handle
or on a handle the caller created itself, and the framework writes it
into a payload header when the sender has not yet established a
session.
"""
zero_uid()::LFShimUID = ntuple(_ -> UInt8(0), UID_SIZE)

"""
    uid_from_bytes(b::AbstractVector{UInt8}) -> LFShimUID

Build a UID from exactly 32 raw bytes.

Throws `ArgumentError` when the input length is not 32. The input is
copied; the returned UID does not share storage with `b`.
"""
function uid_from_bytes(b::AbstractVector{UInt8})::LFShimUID
    length(b) == UID_SIZE ||
        throw(ArgumentError(
            "UID must be exactly $UID_SIZE bytes, got $(length(b))"
        ))
    return ntuple(i -> @inbounds(b[i]), UID_SIZE)
end

"""
    uid_from_hex(s::AbstractString) -> LFShimUID

Build a UID from a 64-character hexadecimal string.

Leading and trailing whitespace is stripped. The hex digits themselves
may be in either case. Throws `ArgumentError` when the string is not
exactly 64 characters long or contains a non-hex character.
"""
function uid_from_hex(s::AbstractString)::LFShimUID
    chars = collect(strip(s))
    if length(chars) != 64
        throw(ArgumentError(
            "UID hex string must be 64 characters, got $(length(chars))"
        ))
    end
    return ntuple(UID_SIZE) do i
        hi = _hex_digit(chars[2i - 1])
        lo = _hex_digit(chars[2i])
        (hi << 4) | lo
    end
end

# -------------------------------------------------------------------- #
# Conversion                                                           #
# -------------------------------------------------------------------- #

"""
    uid_to_bytes(u::LFShimUID) -> Vector{UInt8}

Return a fresh 32-element `Vector{UInt8}` holding the same bytes.

The returned vector is an independent copy; mutating it does not
affect the UID, and vice versa.
"""
uid_to_bytes(u::LFShimUID)::Vector{UInt8} = collect(u)

"""
    uid_to_hex(u::LFShimUID) -> String

Return the lowercase 64-character hexadecimal representation.

The output is always 64 ASCII characters, matching the input expected
by `uid_from_hex`.
"""
function uid_to_hex(u::LFShimUID)::String
    buf = Vector{UInt8}(undef, 64)
    @inbounds for i in 1:UID_SIZE
        b = u[i]
        buf[2i - 1] = _HEX_CHARS[Int((b >> 4) & 0x0F) + 1]
        buf[2i]     = _HEX_CHARS[Int(b & 0x0F) + 1]
    end
    return String(buf)
end

# -------------------------------------------------------------------- #
# Predicates                                                           #
# -------------------------------------------------------------------- #

"""
    is_zero_uid(u::LFShimUID) -> Bool

Return `true` when every byte of `u` is zero.

Mirrors the C ABI's `Null_UID()` concept. Use this to detect the
"no sender identity" case that `LF_Get_P2P_UID` returns on a non-input
handle.
"""
function is_zero_uid(u::LFShimUID)::Bool
    @inbounds for b in u
        b == 0x00 || return false
    end
    return true
end

# -------------------------------------------------------------------- #
# Display                                                              #
# -------------------------------------------------------------------- #

function Base.show(io::IO, u::LFShimUID)
    print(io, "UID(", uid_to_hex(u), ")")
    return nothing
end

# -------------------------------------------------------------------- #
# Exports                                                              #
# -------------------------------------------------------------------- #

export UID_SIZE,
       LFShimUID,
       LFShimUIDRef,
       zero_uid,
       uid_from_bytes,
       uid_from_hex,
       uid_to_bytes,
       uid_to_hex,
       is_zero_uid