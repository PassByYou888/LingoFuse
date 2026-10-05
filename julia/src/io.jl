# io.jl - Unified JSON and string I/O for LingoFuse data handles.
#
# This module is the Julia counterpart of Python's lingofuse.lf_io and
# C++'s lf_io.hpp. It is the single place in the toolchain where Julia
# values are converted to and from the bytes carried by a DataHandle.
#
# Wire format
# -----------
# A JSON payload on a data handle is:
#
#     [UTF-8 encoded JSON text][NUL byte]
#
# A plain-text payload uses the same framing:
#
#     [UTF-8 text][NUL byte]
#
# A raw binary payload uses:
#
#     [arbitrary bytes][NUL byte]
#
# The receiving side is fault-tolerant: if no NUL is found before the
# end of the buffer, the entire remaining buffer is consumed. This
# makes the reader tolerant of payloads that arrive from an HTTP
# bridge or any other producer that does not append a NUL.
#
# JSON serialization policy
# -------------------------
# Every JSON string produced by this module goes through dumps_json.
# That function is the single source of truth for the serialization
# policy. Its properties are:
#
#   - Compact output, no indentation, no trailing newline.
#   - Literal UTF-8: non-ASCII characters (Chinese, emoji, accented
#     Latin letters) are emitted as literal characters, not as
#     \uXXXX escapes. This matches the Python policy of
#     json.dumps(obj, ensure_ascii=False) and the C++/C# policy of
#     the nlohmann and System.Text.Json equivalents.
#
# The returned string does NOT include a trailing NUL byte. Callers
# that want to write it to a data handle with the required NUL
# terminator should use write_json! or write_string! instead.
#
# JSON deserialization policy
# ---------------------------
# loads_json uses JSON3.read with strict semantics. A payload that is
# not valid JSON throws. Callers that need a non-throwing path use
# try_read_json.
#
# read_json returns the JSON3 native structure (JSON3.Object,
# JSON3.Array, or a Julia scalar). This preserves JSON3's zero-copy
# semantics and is fast. Callers that need a plain Dict / Vector
# representation should use json_to_dict.
#
# Dependencies
# ------------
# JSON3 is required. Install it once with:
#
#     using Pkg; Pkg.add("JSON3")
#
# The binding does not pull in any other external package.

import JSON3

# ------------------------------------------------------------------ #
# JSON serialization and deserialization                             #
# ------------------------------------------------------------------ #

"""
    dumps_json(obj) -> String

Serialize `obj` to a compact UTF-8 JSON string.

Policy (single source of truth for the whole Julia toolchain):

  - Compact output: no indentation, no trailing newline.
  - Literal UTF-8: non-ASCII characters are emitted as literal
    characters, matching the Python (ensure_ascii=False), C++
    (nlohmann with literal UTF-8) and C# (UnsafeRelaxedJsonEscaping)
    producers byte-for-byte.

The returned string does NOT include a trailing NUL byte. Use
[`write_json!`](@ref) or [`write_string!`](@ref) to write it to a
data handle with the required terminator.
"""
function dumps_json(obj)::String
    return JSON3.write(obj)
end

"""
    loads_json(text::AbstractString) -> Any

Parse a UTF-8 JSON string into a Julia value.

The result is the JSON3 native structure: `JSON3.Object` for a JSON
object, `JSON3.Array` for a JSON array, and a Julia scalar
(`String`, `Int64`, `Float64`, `Bool`, or `nothing`) for the
primitives.

Strict: any syntax error or invalid UTF-8 sequence throws. Use
[`try_read_json`](@ref) for a non-throwing path.
"""
function loads_json(text::AbstractString)
    return JSON3.read(text)
end

"""
    json_to_dict(x) -> Any

Recursively convert a JSON3 value into a plain Julia container:
`Dict{String,Any}`, `Vector{Any}`, or a scalar.

Use this when the caller needs to pass the result to a function that
expects a `Dict` or `Vector`, or when the caller wants to mutate the
result. The returned structure shares no storage with the input; it
is a deep copy.
"""
function json_to_dict(x)
    if x isa JSON3.Object
        out = Dict{String,Any}()
        for (k, v) in pairs(x)
            out[String(k)] = json_to_dict(v)
        end
        return out
    elseif x isa JSON3.Array
        return Any[json_to_dict(v) for v in x]
    else
        return x
    end
end

# ------------------------------------------------------------------ #
# String I/O (NUL-framed)                                            #
# ------------------------------------------------------------------ #
#
# write_string! and read_string! are defined in data_handle.jl. The
# functions below add the remaining entry points of the wire
# protocol: raw byte sequences, whole-buffer reads, and non-consuming
# peeks.

"""
    write_string_bytes!(dh::DataHandle, data::AbstractVector{UInt8}) -> Int64

Write `data` followed by a single NUL byte. The bytes are written
verbatim; embedded NUL bytes are preserved.

Unlike `write_string!`, which takes a Julia string, this accepts raw
bytes and does not validate or interpret them. Use it when the bytes
are already UTF-8 (for example, the output of `dumps_json`), or when
they are binary and the caller has chosen to frame them as a string.

Returns the number of bytes written, including the NUL terminator.
"""
function write_string_bytes!(dh::DataHandle,
                             data::AbstractVector{UInt8})::Int64
    _ensure_valid(dh)
    n1 = isempty(data) ? Int64(0) : write_buffer!(dh, Vector{UInt8}(data))
    n2 = write_buffer!(dh, UInt8[0x00])
    return n1 + n2
end

"""
    read_string_bytes(dh::DataHandle) -> Vector{UInt8}

Read raw bytes from the cursor, stopping at the first NUL byte.

When no NUL is found before the end of the buffer, all remaining
bytes are consumed and returned. This fault-tolerant behaviour
matches every other LingoFuse binding and is required for
interoperability with producers that do not append a NUL (HTTP
bridges, browsers, and any code that writes raw JSON).

Side effect (no-NUL case)
-------------------------
When no NUL is found, the cursor is advanced to (size + 1). The
native layer implicitly grows the buffer by one byte to accommodate
the new position, so the handle's total size increases by one after
such a read. This matches the contract of `read_string!` in
data_handle.jl and of every other LingoFuse binding.

Unlike `read_string!`, this returns a `Vector{UInt8}` and does not
attempt UTF-8 decoding. Use it when the caller wants to inspect,
forward, or decode the bytes with a specific error handler.
"""
function read_string_bytes(dh::DataHandle)::Vector{UInt8}
    _ensure_valid(dh)

    start = cursor_position(dh)
    total = buffer_size(dh)
    start >= total && return UInt8[]

    remaining = Int(total - start)
    raw = read_buffer!(dh, remaining)
    isempty(raw) && return UInt8[]

    nul_idx = findfirst(==(0x00), raw)
    if nul_idx === nothing
        # No NUL: the cursor already advanced to the end of the
        # buffer. Move it to total + 1 to match the fault-tolerant
        # read contract of every other binding. The native layer
        # grows the buffer by one byte.
        set_cursor_position!(dh, total + 1)
        return raw
    end

    # A NUL was found. Return the bytes before it and advance the
    # cursor past the NUL.
    set_cursor_position!(dh, start + nul_idx)
    return raw[1:nul_idx-1]
end

"""
    read_all_bytes(dh::DataHandle) -> Vector{UInt8}

Read every remaining byte from the cursor to the end of the buffer
and advance the cursor to the end. No NUL handling is performed.

Use this for raw binary payloads; use `read_string_bytes` for
NUL-framed text or JSON payloads.
"""
function read_all_bytes(dh::DataHandle)::Vector{UInt8}
    _ensure_valid(dh)
    pos   = cursor_position(dh)
    total = buffer_size(dh)
    pos >= total && return UInt8[]
    return read_buffer!(dh, Int(total - pos))
end

"""
    peek_string_bytes(dh::DataHandle) -> Vector{UInt8}

Return the bytes up to the first NUL without advancing the cursor
and without modifying the handle's size.

This is a pure read: no side effect on the handle, regardless of
whether a NUL is present. It differs from `read_string_bytes` in
that the no-NUL case does NOT advance the cursor to (size + 1) and
therefore does NOT trigger the native buffer-growth side effect.

Provided for diagnostic and logging code that needs to inspect the
current payload without consuming it.
"""
function peek_string_bytes(dh::DataHandle)::Vector{UInt8}
    _ensure_valid(dh)

    start = cursor_position(dh)
    total = buffer_size(dh)
    start >= total && return UInt8[]

    # read_buffer! never grows the buffer. It only advances the
    # cursor by the number of bytes actually read. We restore the
    # cursor afterwards so that the handle appears untouched.
    remaining = Int(total - start)
    raw = read_buffer!(dh, remaining)
    set_cursor_position!(dh, start)

    isempty(raw) && return UInt8[]
    nul_idx = findfirst(==(0x00), raw)
    return nul_idx === nothing ? raw : raw[1:nul_idx-1]
end

# ------------------------------------------------------------------ #
# JSON I/O                                                           #
# ------------------------------------------------------------------ #

"""
    write_json!(dh::DataHandle, obj) -> Int64

Serialize `obj` as UTF-8 JSON and write it with a NUL terminator.

The serialization goes through [`dumps_json`](@ref), so the compact,
literal-UTF-8 policy is guaranteed. The output never contains a
\\uXXXX escape for non-ASCII text, and a trailing NUL byte is always
appended.

Returns the number of bytes written, including the NUL terminator.
"""
function write_json!(dh::DataHandle, obj)::Int64
    _ensure_valid(dh)
    text = dumps_json(obj)
    return write_string!(dh, text)
end

"""
    read_json(dh::DataHandle) -> Any

Read a UTF-8 JSON payload from the cursor and return the decoded
value.

The payload may or may not be NUL-terminated. When a NUL is present,
it marks the end of the payload; otherwise the entire remaining
buffer is consumed. In the latter case the buffer grows by one byte
(see `read_string_bytes` for the side-effect contract).

Returns `nothing` when the buffer contains no bytes at all. This
matches the historical convention of the toolchain: an empty payload
means "no result". Note that a JSON `null` (the four bytes `null`)
also decodes to `nothing`; callers that need to distinguish the two
must inspect the raw buffer themselves via `read_string_bytes`.

The returned value is the JSON3 native structure (`JSON3.Object` /
`JSON3.Array` / scalar). Call [`json_to_dict`](@ref) to obtain a
plain `Dict` / `Vector` representation.

Throws when the payload is not valid UTF-8 or not valid JSON. Use
[`try_read_json`](@ref) for a non-throwing path, or
[`read_json_or_bytes`](@ref) to forward non-JSON payloads
unchanged.
"""
function read_json(dh::DataHandle)
    _ensure_valid(dh)
    text = read_string!(dh)
    isempty(text) && return nothing
    return loads_json(text)
end

"""
    try_read_json(dh::DataHandle) -> Any

Non-throwing counterpart of [`read_json`](@ref). Returns `nothing`
when the payload is empty, invalid UTF-8, or invalid JSON.

The cursor is advanced regardless of the outcome; this matches the
historical behaviour of the C++ and C# wrappers and is the only
sensible choice for a probe.
"""
function try_read_json(dh::DataHandle)
    _ensure_valid(dh)
    text = read_string!(dh)
    isempty(text) && return nothing
    try
        return loads_json(text)
    catch
        return nothing
    end
end

"""
    read_json_or_bytes(dh::DataHandle)

Read a payload and return either the decoded JSON value or the raw
bytes.

Semantics:

  - Empty payload                -> `nothing`
  - Valid JSON                   -> the decoded value (JSON3 native)
  - Valid UTF-8 but invalid JSON -> the raw bytes (`Vector{UInt8}`)
  - Invalid UTF-8                -> the raw bytes

This is a deliberately lenient reader for callers that want to
forward or log a non-JSON response rather than treat it as a
protocol error. The canonical example is an MCP or HTTP bridge: a
backend API may return plain text or binary, and the bridge must not
reject it merely because it is not JSON.

Callers that want strict behaviour should use `read_json` instead.
"""
function read_json_or_bytes(dh::DataHandle)
    _ensure_valid(dh)
    raw = read_string_bytes(dh)
    isempty(raw) && return nothing

    # Copy first: String(v) takes ownership of v (zero-copy).
    text = String(copy(raw))
    try
        return loads_json(text)
    catch
        return raw
    end
end

# ------------------------------------------------------------------ #
# Exports                                                            #
# ------------------------------------------------------------------ #

export dumps_json,
       loads_json,
       json_to_dict,
       write_string_bytes!,
       read_string_bytes,
       read_all_bytes,
       peek_string_bytes,
       write_json!,
       read_json,
       try_read_json,
       read_json_or_bytes