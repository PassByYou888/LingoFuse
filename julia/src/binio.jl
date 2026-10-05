# binio.jl - Little-endian binary I/O for LingoFuse data handles.
#
# Provides symmetric write_*!/read_* helpers for the primitive types
# used by the LingoFuse wire protocol's raw binary channel:
#
#   UInt8   Int8    UInt16  Int16
#   UInt32  Int32   UInt64  Int64
#   Float32 Float64
#
# All integers are written and read little-endian, matching every
# other LingoFuse binding (Pascal, C, C++, C#, Python, JavaScript).
# The float encodings are IEEE 754 single- and double-precision.
#
# The write side always throws on a short write: a partial write on
# the wire would corrupt the framing for every subsequent field.
#
# The read side has two flavours:
#
#   read_int32(dh)         - throws LingoFuseIoError on a short read.
#   try_read_int32(dh)     - returns (ok, value); ok is a Bool.
#
# The throwing form is the default because a partially read integer
# is never useful; the try-form exists for probing code.
#
# This module is a consumer of data_handle.jl; it never touches the
# native LF_* functions directly.

# ------------------------------------------------------------------ #
# Internal helpers                                                   #
# ------------------------------------------------------------------ #

# Encode a little-endian byte sequence for the given value and write
# it to the handle at the cursor.
function _write_le!(dh::DataHandle, bytes::Vector{UInt8})::Int64
    return write_buffer!(dh, bytes)
end

# Read exactly `n` bytes and return them. Throws on a short read; the
# cursor is restored on failure.
function _read_exact(dh::DataHandle, n::Int)::Vector{UInt8}
    return read_buffer_exact!(dh, n)
end

# ================================================================== #
# Unsigned integers                                                  #
# ================================================================== #

"""
    write_uint8!(dh::DataHandle, v::Integer) -> Int64

Write an 8-bit unsigned integer. The cursor advances by 1 byte.
"""
function write_uint8!(dh::DataHandle, v::Integer)::Int64
    0 <= v <= 0xFF || throw(ArgumentError("value out of UInt8 range: $v"))
    return _write_le!(dh, UInt8[v])
end

"""
    read_uint8(dh::DataHandle) -> UInt8

Read an 8-bit unsigned integer. Throws `LingoFuseIoError` on a short
read.
"""
function read_uint8(dh::DataHandle)::UInt8
    return _read_exact(dh, 1)[1]
end

"""
    write_uint16!(dh::DataHandle, v::Integer) -> Int64

Write a 16-bit unsigned integer in little-endian order. The cursor
advances by 2 bytes.
"""
function write_uint16!(dh::DataHandle, v::Integer)::Int64
    0 <= v <= 0xFFFF || throw(ArgumentError("value out of UInt16 range: $v"))
    u = UInt16(v)
    return _write_le!(dh, UInt8[u & 0xFF, (u >> 8) & 0xFF])
end

"""
    read_uint16(dh::DataHandle) -> UInt16

Read a 16-bit unsigned integer in little-endian order.
"""
function read_uint16(dh::DataHandle)::UInt16
    b = _read_exact(dh, 2)
    return UInt16(b[1]) | (UInt16(b[2]) << 8)
end

"""
    write_uint32!(dh::DataHandle, v::Integer) -> Int64

Write a 32-bit unsigned integer in little-endian order. The cursor
advances by 4 bytes.
"""
function write_uint32!(dh::DataHandle, v::Integer)::Int64
    0 <= v <= 0xFFFFFFFF || throw(ArgumentError("value out of UInt32 range: $v"))
    u = UInt32(v)
    return _write_le!(dh, UInt8[
        u & 0xFF,
        (u >> 8)  & 0xFF,
        (u >> 16) & 0xFF,
        (u >> 24) & 0xFF,
    ])
end

"""
    read_uint32(dh::DataHandle) -> UInt32

Read a 32-bit unsigned integer in little-endian order.
"""
function read_uint32(dh::DataHandle)::UInt32
    b = _read_exact(dh, 4)
    return UInt32(b[1])           |
           (UInt32(b[2]) << 8)    |
           (UInt32(b[3]) << 16)   |
           (UInt32(b[4]) << 24)
end

"""
    write_uint64!(dh::DataHandle, v::Integer) -> Int64

Write a 64-bit unsigned integer in little-endian order. The cursor
advances by 8 bytes.
"""
function write_uint64!(dh::DataHandle, v::Integer)::Int64
    (0 <= v <= typemax(UInt64)) ||
        throw(ArgumentError("value out of UInt64 range: $v"))
    u = UInt64(v)
    return _write_le!(dh, UInt8[
        (u >>  0) & 0xFF,
        (u >>  8) & 0xFF,
        (u >> 16) & 0xFF,
        (u >> 24) & 0xFF,
        (u >> 32) & 0xFF,
        (u >> 40) & 0xFF,
        (u >> 48) & 0xFF,
        (u >> 56) & 0xFF,
    ])
end

"""
    read_uint64(dh::DataHandle) -> UInt64

Read a 64-bit unsigned integer in little-endian order.
"""
function read_uint64(dh::DataHandle)::UInt64
    b = _read_exact(dh, 8)
    result = UInt64(0)
    for i in 1:8
        result |= UInt64(b[i]) << (8 * (i - 1))
    end
    return result
end

# ================================================================== #
# Signed integers                                                    #
# ================================================================== #

"""
    write_int8!(dh::DataHandle, v::Integer) -> Int64

Write an 8-bit signed integer (two's complement). The cursor advances
by 1 byte.
"""
function write_int8!(dh::DataHandle, v::Integer)::Int64
    typemin(Int8) <= v <= typemax(Int8) ||
        throw(ArgumentError("value out of Int8 range: $v"))
    return _write_le!(dh, UInt8[reinterpret(UInt8, Int8(v))])
end

"""
    read_int8(dh::DataHandle) -> Int8

Read an 8-bit signed integer.
"""
function read_int8(dh::DataHandle)::Int8
    return reinterpret(Int8, read_uint8(dh))
end

"""
    write_int16!(dh::DataHandle, v::Integer) -> Int64

Write a 16-bit signed integer in little-endian order. The cursor
advances by 2 bytes.
"""
function write_int16!(dh::DataHandle, v::Integer)::Int64
    typemin(Int16) <= v <= typemax(Int16) ||
        throw(ArgumentError("value out of Int16 range: $v"))
    return write_uint16!(dh, reinterpret(UInt16, Int16(v)))
end

"""
    read_int16(dh::DataHandle) -> Int16

Read a 16-bit signed integer in little-endian order.
"""
function read_int16(dh::DataHandle)::Int16
    return reinterpret(Int16, read_uint16(dh))
end

"""
    write_int32!(dh::DataHandle, v::Integer) -> Int64

Write a 32-bit signed integer in little-endian order. The cursor
advances by 4 bytes.
"""
function write_int32!(dh::DataHandle, v::Integer)::Int64
    typemin(Int32) <= v <= typemax(Int32) ||
        throw(ArgumentError("value out of Int32 range: $v"))
    return write_uint32!(dh, reinterpret(UInt32, Int32(v)))
end

"""
    read_int32(dh::DataHandle) -> Int32

Read a 32-bit signed integer in little-endian order.
"""
function read_int32(dh::DataHandle)::Int32
    return reinterpret(Int32, read_uint32(dh))
end

"""
    write_int64!(dh::DataHandle, v::Integer) -> Int64

Write a 64-bit signed integer in little-endian order. The cursor
advances by 8 bytes.
"""
function write_int64!(dh::DataHandle, v::Integer)::Int64
    typemin(Int64) <= v <= typemax(Int64) ||
        throw(ArgumentError("value out of Int64 range: $v"))
    return write_uint64!(dh, reinterpret(UInt64, Int64(v)))
end

"""
    read_int64(dh::DataHandle) -> Int64

Read a 64-bit signed integer in little-endian order.
"""
function read_int64(dh::DataHandle)::Int64
    return reinterpret(Int64, read_uint64(dh))
end

# ================================================================== #
# Floating point                                                     #
# ================================================================== #

"""
    write_single!(dh::DataHandle, v::Real) -> Int64

Write an IEEE 754 single-precision float in little-endian order. The
cursor advances by 4 bytes.
"""
function write_single!(dh::DataHandle, v::Real)::Int64
    return write_uint32!(dh, reinterpret(UInt32, Float32(v)))
end

"""
    read_single(dh::DataHandle) -> Float32

Read an IEEE 754 single-precision float in little-endian order.
"""
function read_single(dh::DataHandle)::Float32
    return reinterpret(Float32, read_uint32(dh))
end

"""
    write_double!(dh::DataHandle, v::Real) -> Int64

Write an IEEE 754 double-precision float in little-endian order. The
cursor advances by 8 bytes.
"""
function write_double!(dh::DataHandle, v::Real)::Int64
    return write_uint64!(dh, reinterpret(UInt64, Float64(v)))
end

"""
    read_double(dh::DataHandle) -> Float64

Read an IEEE 754 double-precision float in little-endian order.
"""
function read_double(dh::DataHandle)::Float64
    return reinterpret(Float64, read_uint64(dh))
end

# ================================================================== #
# Non-throwing variants                                              #
# ================================================================== #
#
# Each returns (ok::Bool, value). On failure, value is zero of the
# corresponding type and the cursor is unchanged.

function try_read_uint8(dh::DataHandle)
    try
        return (true, read_uint8(dh))
    catch
        return (false, UInt8(0))
    end
end

function try_read_uint16(dh::DataHandle)
    try
        return (true, read_uint16(dh))
    catch
        return (false, UInt16(0))
    end
end

function try_read_uint32(dh::DataHandle)
    try
        return (true, read_uint32(dh))
    catch
        return (false, UInt32(0))
    end
end

function try_read_uint64(dh::DataHandle)
    try
        return (true, read_uint64(dh))
    catch
        return (false, UInt64(0))
    end
end

function try_read_int8(dh::DataHandle)
    try
        return (true, read_int8(dh))
    catch
        return (false, Int8(0))
    end
end

function try_read_int16(dh::DataHandle)
    try
        return (true, read_int16(dh))
    catch
        return (false, Int16(0))
    end
end

function try_read_int32(dh::DataHandle)
    try
        return (true, read_int32(dh))
    catch
        return (false, Int32(0))
    end
end

function try_read_int64(dh::DataHandle)
    try
        return (true, read_int64(dh))
    catch
        return (false, Int64(0))
    end
end

function try_read_single(dh::DataHandle)
    try
        return (true, read_single(dh))
    catch
        return (false, Float32(0))
    end
end

function try_read_double(dh::DataHandle)
    try
        return (true, read_double(dh))
    catch
        return (false, Float64(0))
    end
end

# ================================================================== #
# Exports                                                            #
# ================================================================== #

export write_uint8!,  read_uint8,
       write_uint16!, read_uint16,
       write_uint32!, read_uint32,
       write_uint64!, read_uint64,
       write_int8!,   read_int8,
       write_int16!,  read_int16,
       write_int32!,  read_int32,
       write_int64!,  read_int64,
       write_single!, read_single,
       write_double!, read_double,
       try_read_uint8,  try_read_uint16,  try_read_uint32,  try_read_uint64,
       try_read_int8,   try_read_int16,   try_read_int32,   try_read_int64,
       try_read_single, try_read_double