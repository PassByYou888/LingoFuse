# data_handle.jl - RAII wrapper around a native LingoFuse data handle.
#
# Design
# ------
# DataHandle is a mutable struct owning a native TDataHnd. It provides:
#
#   - Deterministic release through dispose!(dh).
#   - A finalizer that releases the handle if dispose! was forgotten.
#   - Byte-level I/O, string helpers, and cursor management on top of
#     the raw LF_* primitives from abi.jl.
#
# Two ownership modes
# -------------------
#   owned = true   (default)  dispose! calls LF_FreeData.
#   owned = false             dispose! is a no-op; the native layer
#                             retains ownership (used inside callbacks).
#
# A borrowed handle stays valid for the entire callback body even if
# the user accidentally calls dispose! on it; the wrapper's state is
# intentionally not modified for borrowed handles, so subsequent reads
# within the same callback continue to work.
#
# Finalizer notes
# ---------------
# A finalizer runs on the GC thread while the object is being
# collected. It MUST NOT:
#   - write to any field of the object (write barriers are illegal
#     during finalization),
#   - allocate a new Julia object,
#   - call back into the Julia runtime in any complex way.
#
# The finalizer below therefore does exactly one thing: read the
# captured handle value and, if non-null, call LF_FreeData. All state
# transitions live in dispose!, which runs on a normal Julia thread.
#
# Method naming
# -------------
# Mutating operations are suffixed with `!` (write_buffer!,
# write_string!, ...). Accessors have no suffix (buffer_size,
# cursor_position, ...). This matches the Julia convention and makes
# the intent visible at the call site.
#
# String framing and UTF-8
# ------------------------
# write_string! appends a single NUL byte after the UTF-8 content.
#
# read_string! is fault-tolerant: it stops at the first NUL, and if
# no NUL is present it consumes the entire remaining buffer.
#
# IMPORTANT: read_string! does NOT validate or repair UTF-8. The
# returned String is constructed with `String(::Vector{UInt8})`,
# which takes ownership of the bytes without transcoding. If the
# payload contains invalid UTF-8 sequences, the resulting String may
# be malformed and any subsequent character-level operation on it
# (iteration, indexing, regex, printing) may raise an error or
# produce incorrect results. Callers that must handle arbitrary
# bytes should use read_buffer_exact! or read_string_bytes and
# perform their own decoding with an explicit error handler.

# ------------------------------------------------------------------ #
# Struct and constructors                                            #
# ------------------------------------------------------------------ #

"""
    DataHandle(method_name::AbstractString; permanent::Bool = false)

Create a new data handle bound to `method_name`.

When `permanent` is `false` (the default), the handle is added to the
library's idle pool: the pool scans every 5 seconds and frees any
handle idle for more than 10 minutes.

When `permanent` is `true`, the handle is not added to the idle pool
and is never reclaimed automatically. `dispose!` releases it
synchronously. Use this for handles that must survive for the entire
process lifetime.

A finalizer is installed on the returned object, so a forgotten
`dispose!` still results in a release, though at an unpredictable
moment. Explicit `dispose!` is strongly recommended.
"""
mutable struct DataHandle
    handle::Ptr{Cvoid}
    owned::Bool
    disposed::Bool
end

function DataHandle(method_name::AbstractString;
                    permanent::Bool = false)
    h = permanent ? LF_CreateData_Permanent(method_name) :
                    LF_CreateData(method_name)
    if h == C_NULL
        throw(LingoFuseIoError(
            "DataHandle.constructor",
            "native layer returned a null handle for '$(method_name)'"
        ))
    end
    return _wrap_data_handle(h, true)
end

"""
    DataHandle(hnd::Ptr{Cvoid}, owned::Bool) -> DataHandle

Wrap an already-allocated native data handle.

This low-level constructor is intended for code that receives a raw
handle from an LF_* function (for example `LF_Call`) and wants the
RAII guarantees of the wrapper. Ordinary application code should use
`DataHandle(name)` or `local_call` / `LF_Call` with the wrapper's
return value.

When `owned` is `true`, the returned wrapper calls `LF_FreeData` on
`dispose!` (or on finalization). When `owned` is `false`, the wrapper
is a borrowed view; `dispose!` is a no-op and the native layer
retains ownership.
"""
function DataHandle(hnd::Ptr{Cvoid}, owned::Bool)::DataHandle
    hnd == C_NULL &&
        throw(ArgumentError("cannot wrap a null native handle"))
    return _wrap_data_handle(hnd, owned)
end

# Internal: wrap an already-allocated handle. Used by the constructor
# above and by callers that need a non-owning wrapper.
function _wrap_data_handle(h::Ptr{Cvoid}, owned::Bool)
    obj = DataHandle(h, owned, false)
    if owned
        finalizer(_finalize_data_handle!, obj)
    end
    return obj
end

# Finalizer: do NOT modify any field and do NOT allocate. Read the
# handle value and, if non-null, release it.
function _finalize_data_handle!(dh::DataHandle)
    h = dh.handle
    if h != C_NULL
        LF_FreeData(h)
    end
    return
end

# ------------------------------------------------------------------ #
# Lifetime                                                           #
# ------------------------------------------------------------------ #

"""
    dispose!(dh::DataHandle) -> Nothing

Release the native handle when ownership applies. Idempotent.

For an owning auto-recycled handle, this marks the handle as deleted;
the actual release happens on the next idle-pool scan (at most 5
seconds later). For an owning permanent handle, the release is
immediate.

For a borrowed handle, this is a no-op: the native layer owns the
resource and releases it when the callback returns.
"""
function dispose!(dh::DataHandle)
    if dh.disposed
        return nothing
    end
    if !dh.owned
        # Borrowed handle: leave the wrapper state untouched so that
        # a subsequent read within the same callback still works.
        return nothing
    end

    dh.disposed = true
    h = dh.handle
    dh.handle = C_NULL
    if h != C_NULL
        LF_FreeData(h)
    end
    return nothing
end

"""
    is_disposed(dh::DataHandle) -> Bool

Return `true` when the handle has been released.
"""
is_disposed(dh::DataHandle)::Bool = dh.disposed

function _ensure_valid(dh::DataHandle)
    if dh.disposed || dh.handle == C_NULL
        throw(LingoFuseObjectDisposedError("DataHandle"))
    end
    return
end

# ------------------------------------------------------------------ #
# Cursor and size                                                    #
# ------------------------------------------------------------------ #

"""
    cursor_position(dh::DataHandle) -> Int64

Return the current read/write cursor position.
"""
function cursor_position(dh::DataHandle)::Int64
    _ensure_valid(dh)
    return LF_GetPos(dh.handle)
end

"""
    set_cursor_position!(dh::DataHandle, pos::Integer) -> Nothing

Set the read/write cursor. A position past the current size implicitly
grows the buffer; the newly added region is zero-filled by the native
layer.
"""
function set_cursor_position!(dh::DataHandle, pos::Integer)
    _ensure_valid(dh)
    p = Int64(pos)
    p < 0 && throw(ArgumentError("position must be non-negative"))
    LF_SetPos(dh.handle, p)
    return nothing
end

"""
    buffer_size(dh::DataHandle) -> Int64

Return the total buffer size in bytes.
"""
function buffer_size(dh::DataHandle)::Int64
    _ensure_valid(dh)
    return LF_GetSize(dh.handle)
end

"""
    resize_buffer!(dh::DataHandle, n::Integer) -> Nothing

Resize the buffer. Enlarging zero-fills the new region in the current
native implementation; callers should not depend on this.
"""
function resize_buffer!(dh::DataHandle, n::Integer)
    _ensure_valid(dh)
    s = Int64(n)
    s < 0 && throw(ArgumentError("size must be non-negative"))
    LF_SetSize(dh.handle, s)
    return nothing
end

# ------------------------------------------------------------------ #
# Byte-level I/O                                                     #
# ------------------------------------------------------------------ #

"""
    write_buffer!(dh::DataHandle, data::Vector{UInt8}) -> Int64

Append `data` at the cursor. The buffer grows as needed; the cursor
advances by the number of bytes written.

Returns the number of bytes written, which equals `length(data)` for
a successful write.
"""
function write_buffer!(dh::DataHandle, data::Vector{UInt8})::Int64
    _ensure_valid(dh)
    isempty(data) && return Int64(0)
    n = Int64(length(data))
    written = GC.@preserve data begin
        LF_WriteBuffer(dh.handle, pointer(data), n)
    end
    if written != n
        throw(LingoFuseIoError(
            "DataHandle.write_buffer!",
            "short write: $(written) of $(n) bytes"
        ))
    end
    return written
end

"""
    read_buffer!(dh::DataHandle, n::Integer) -> Vector{UInt8}

Read up to `n` bytes at the cursor. The cursor advances by the number
of bytes actually read. Never throws for a short read; the returned
vector may be shorter than `n` at the end of the buffer.
"""
function read_buffer!(dh::DataHandle, n::Integer)::Vector{UInt8}
    _ensure_valid(dh)
    k = Int(n)
    k < 0 && throw(ArgumentError("n must be non-negative"))
    k == 0 && return UInt8[]
    out = Vector{UInt8}(undef, k)
    got = GC.@preserve out begin
        LF_ReadBuffer(dh.handle, pointer(out), Int64(k))
    end
    if got < 0
        return UInt8[]
    end
    if got < k
        # Short read: shrink in place. resize! does not copy, unlike
        # out[1:got].
        resize!(out, Int(got))
    end
    return out
end

"""
    read_buffer_exact!(dh::DataHandle, n::Integer) -> Vector{UInt8}

Read exactly `n` bytes. Throws `LingoFuseIoError` when fewer than `n`
bytes are available. The cursor is unchanged on failure.
"""
function read_buffer_exact!(dh::DataHandle, n::Integer)::Vector{UInt8}
    _ensure_valid(dh)
    k = Int(n)
    k < 0 && throw(ArgumentError("n must be non-negative"))
    k == 0 && return UInt8[]

    saved = cursor_position(dh)
    out = read_buffer!(dh, k)
    if length(out) != k
        set_cursor_position!(dh, saved)
        throw(LingoFuseIoError(
            "DataHandle.read_buffer_exact!",
            "requested $(k) bytes, only $(length(out)) available"
        ))
    end
    return out
end

"""
    read_all!(dh::DataHandle) -> Vector{UInt8}

Read every remaining byte from the cursor to the end of the buffer
and advance the cursor to the end.
"""
function read_all!(dh::DataHandle)::Vector{UInt8}
    _ensure_valid(dh)
    sz = buffer_size(dh)
    pos = cursor_position(dh)
    pos >= sz && return UInt8[]
    return read_buffer!(dh, Int(sz - pos))
end

# ------------------------------------------------------------------ #
# NUL-framed string I/O                                              #
# ------------------------------------------------------------------ #

"""
    write_string!(dh::DataHandle, s::AbstractString) -> Int64

Write `s` as UTF-8 bytes followed by a single NUL byte. An empty
string writes exactly one byte (the NUL). Returns the number of bytes
written including the NUL.

The NUL terminator matches the LingoFuse wire-protocol convention;
every other binding produces the same bytes for the same logical
string.
"""
function write_string!(dh::DataHandle, s::AbstractString)::Int64
    _ensure_valid(dh)
    bytes = Vector{UInt8}(codeunits(s))
    n1 = write_buffer!(dh, bytes)
    n2 = write_buffer!(dh, UInt8[0x00])
    return n1 + n2
end

"""
    read_string!(dh::DataHandle) -> String

Read a UTF-8 string from the cursor, stopping at the first NUL byte.

When no NUL is found before the end of the buffer, all remaining
bytes are consumed. This fault-tolerant behaviour matches every
other LingoFuse binding.

Side effect (no-NUL case)
-------------------------
When no NUL is found, the cursor is advanced to (size + 1). The
native layer implicitly grows the buffer by one byte to accommodate
the new position, so the handle's total size increases by one after
such a read. This is a contract inherited from the Pascal / Python /
C++ bindings and is preserved here byte-for-byte.

UTF-8 (NOT validated)
---------------------
This function does NOT validate or repair UTF-8. It constructs the
result with `String(::Vector{UInt8})`, which takes ownership of the
bytes without transcoding. If the payload contains invalid UTF-8
sequences, the returned String may be malformed, and subsequent
character-level operations on it (iteration, indexing, regex) may
raise an error or produce incorrect results.

Callers that need to handle arbitrary bytes should use
`read_buffer_exact!` or `read_string_bytes` and decode explicitly
with the error handler of their choice.
"""
function read_string!(dh::DataHandle)::String
    _ensure_valid(dh)

    start = cursor_position(dh)
    total = buffer_size(dh)
    start >= total && return ""

    remaining = Int(total - start)
    raw = read_buffer!(dh, remaining)
    isempty(raw) && return ""

    nul_idx = findfirst(==(0x00), raw)
    if nul_idx === nothing
        # No NUL: the cursor already advanced to the end of the
        # buffer; move it to size + 1 to match the fault-tolerant
        # read contract of every other binding. The native layer
        # grows the buffer by one byte.
        set_cursor_position!(dh, total + 1)
        return String(raw)
    end

    # Advance the cursor past the NUL.
    set_cursor_position!(dh, start + nul_idx)
    payload = raw[1:nul_idx-1]
    return String(payload)
end

# ------------------------------------------------------------------ #
# Exports                                                            #
# ------------------------------------------------------------------ #

export DataHandle,
       dispose!,
       is_disposed,
       cursor_position,
       set_cursor_position!,
       buffer_size,
       resize_buffer!,
       write_buffer!,
       read_buffer!,
       read_buffer_exact!,
       read_all!,
       write_string!,
       read_string!