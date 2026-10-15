# target.jl - Addressing targets for the three LingoFuse routing modes.
#
# This file defines the user-facing calling surface: a single set of
# functions (call, notify, sequenced_notify, future, sequenced_future,
# async_call, async_sequenced_call) that work identically across the
# three addressing modes.
#
# The three modes differ ONLY in routing:
#
#   AppTarget      -- routes to a logical App by name. LOCAL-FIRST:
#                     if the caller process itself hosts an App with
#                     the matching name and API, the call is serviced
#                     locally without touching the network.
#
#   UIDTarget      -- routes to a specific session by its 32-byte UID.
#                     LOCAL-FIRST, matching App name routing. The UID
#                     is regenerated on every TunnelLink; callers
#                     that cache a UID MUST re-probe it after a link
#                     loss.
#
#   P2PNameTarget  -- routes to any client in a user-defined group.
#                     NOT local-first: the call is always forwarded
#                     to the server for dispatch, because the server
#                     owns the load-balancing state.
#
# Call shapes
# -----------
# Each target exposes seven functions, which fall into three groups:
#
#   Synchronous (blocking):
#     call(t, api, payload; timeout_ms)
#     notify(t, api, payload)
#     sequenced_notify(t, api, payload)
#
#   Asynchronous, Future-based:
#     future(t, api, payload; timeout_ms)           -> Future
#     sequenced_future(t, api, payload; timeout_ms) -> Future
#
#   Asynchronous, do-block callback:
#     async_call(t, api, payload) do result, err ... end
#     async_sequenced_call(t, api, payload) do result, err ... end
#
# The two do-block variants ALSO return a Future. This lets callers
# correlate a callback with its underlying request (for diagnostics
# or for waiting), and it is what makes the do-block form testable
# against the mock driver.
#
# Payload forms
# -------------
# The `payload` argument of the calling functions is polymorphic:
#
#   nothing                   -- empty payload
#   Vector{UInt8}             -- raw bytes, written to the handle
#                                verbatim
#   Function(dh::DataHandle)  -- the caller writes into the handle
#                                using the DataHandle API. This is
#                                the most flexible form and the one
#                                used by the CrossDemo examples.
#
# Any other type is rejected with an ArgumentError. A dedicated JSON
# calling layer is NOT provided in this file; callers that want to
# pass structured data should either build the bytes themselves, or
# use a JSON library (JSON3) inside their payload Function.
#
# Synchronous timeout
# -------------------
# The C ABI signals a synchronous timeout by returning a data handle
# of size 0 (rather than a NULL pointer). This file treats that as a
# timeout: `call` raises `LingoFuseTimeoutError`. There is no way to
# distinguish "the peer returned an empty response" from "the call
# timed out" at the C ABI level. Callers that need to distinguish the
# two should use `future` and check `is_abandoned`.
#
# Asynchronous timeout
# --------------------
# The async path is "soft timeout" (decision D4): the Future is
# resolved with `LingoFuseTimeoutError` and `is_abandoned(fut)` is
# true, but the C-side request may still be in flight. If its result
# ever arrives, the callback consumer finds no registered handler for
# the token and drops the event silently (see callback.jl,
# _dispatch_async_result).
#
# do-block callback thread
# ------------------------
# The user callback passed to `async_call` / `async_sequenced_call`
# runs on a dedicated watcher task, NOT on the callback consumer
# thread. This means the user callback MAY block, MAY wait on
# additional Futures, and MAY call any other LingoFuse API. It must
# not, however, call `shutdown` or `exit_main_thread`: those would
# tear down the framework while the request is still in flight.
#
# The watcher task is created with `Threads.@spawn` and is scheduled
# onto an arbitrary Julia thread. It is therefore safe to mix
# `async_call` with code that itself uses `Threads.@spawn` or `@async`.

# ------------------------------------------------------------------ #
# Target types                                                        #
# ------------------------------------------------------------------ #

"""
    AbstractTarget

Supertype of the three addressing modes. Concrete instances are
created by `app_target`, `uid_target`, and `p2pname_target`; the
abstract type itself is not intended to be instantiated directly.

All targets are immutable and safe to share across threads. Each one
carries a default timeout that is used when a calling function is
invoked without an explicit `timeout_ms`.
"""
abstract type AbstractTarget end

"""
    AppTarget <: AbstractTarget

Address a logical App by name. See the module docstring for the
routing semantics.
"""
struct AppTarget <: AbstractTarget
    app_name::String
    default_timeout_ms::Int
end

"""
    UIDTarget <: AbstractTarget

Address a specific session by its 32-byte UID. See the module
docstring for the routing semantics and the UID lifecycle.
"""
struct UIDTarget <: AbstractTarget
    uid::LFShimUID
    default_timeout_ms::Int
end

"""
    P2PNameTarget <: AbstractTarget

Address a group of clients by their shared P2P name. See the module
docstring for the routing semantics.
"""
struct P2PNameTarget <: AbstractTarget
    group_name::String
    default_timeout_ms::Int
end

# ------------------------------------------------------------------ #
# Target constructors                                                 #
# ------------------------------------------------------------------ #

const _DEFAULT_TARGET_TIMEOUT_MS = 5000

"""
    app_target(name::AbstractString; timeout_ms::Integer = 5000) -> AppTarget

Build an App-name addressing target.

The `name` is used verbatim as the routing key. Matching is
case-insensitive on the wire, but the string is stored as provided.
"""
function app_target(name::AbstractString;
                    timeout_ms::Integer = _DEFAULT_TARGET_TIMEOUT_MS)::AppTarget
    isempty(name) && throw(ArgumentError("App name must be non-empty"))
    tm = Int(timeout_ms)
    tm < 0 && throw(ArgumentError("timeout_ms must be non-negative"))
    return AppTarget(String(name), tm)
end

"""
    uid_target(uid; timeout_ms::Integer = 5000) -> UIDTarget

Build a UID addressing target.

The `uid` argument accepts any of the forms supported by
`uid_from_bytes` / `uid_from_hex`:
    * `LFShimUID`           -- already a 32-byte tuple
    * `Vector{UInt8}`       -- exactly 32 bytes
    * 64-character hex str  -- lowercase or uppercase

For the reverse direction (learning a remote peer's own UID), see the
"whoami" pattern in the LingoFuse documentation: the receiver reads
the sender's UID from the INPUT handle of a registered callback via
`DataHandle.get_p2p_uid`.
"""
function uid_target(uid;
                    timeout_ms::Integer = _DEFAULT_TARGET_TIMEOUT_MS)::UIDTarget
    normalized = _normalize_uid(uid)
    tm = Int(timeout_ms)
    tm < 0 && throw(ArgumentError("timeout_ms must be non-negative"))
    return UIDTarget(normalized, tm)
end

# Internal: accept the three documented forms of a UID and return an
# LFShimUID.
function _normalize_uid(uid)::LFShimUID
    if uid isa LFShimUID
        return uid
    elseif uid isa AbstractVector{UInt8}
        return uid_from_bytes(uid)
    elseif uid isa AbstractString
        return uid_from_hex(uid)
    else
        throw(ArgumentError(
            "uid must be LFShimUID, Vector{UInt8}, or a hex String; " *
            "got $(typeof(uid))"
        ))
    end
end

"""
    p2pname_target(name::AbstractString; timeout_ms::Integer = 5000) -> P2PNameTarget

Build a P2PName addressing target.

The `name` is the group name that one or more remote clients declared
for themselves via the `LF_P2P_name` runtime option. It is NOT the
name of any specific client; the server dispatches to a member of the
group.
"""
function p2pname_target(name::AbstractString;
                        timeout_ms::Integer = _DEFAULT_TARGET_TIMEOUT_MS)::P2PNameTarget
    isempty(name) && throw(ArgumentError("P2P group name must be non-empty"))
    tm = Int(timeout_ms)
    tm < 0 && throw(ArgumentError("timeout_ms must be non-negative"))
    return P2PNameTarget(String(name), tm)
end

# ------------------------------------------------------------------ #
# Target display                                                      #
# ------------------------------------------------------------------ #

function Base.show(io::IO, t::AppTarget)
    print(io, "AppTarget(", repr(t.app_name),
          ", timeout=", t.default_timeout_ms, "ms)")
end

function Base.show(io::IO, t::UIDTarget)
    print(io, "UIDTarget(", uid_to_hex(t.uid),
          ", timeout=", t.default_timeout_ms, "ms)")
end

function Base.show(io::IO, t::P2PNameTarget)
    print(io, "P2PNameTarget(", repr(t.group_name),
          ", timeout=", t.default_timeout_ms, "ms)")
end

# ------------------------------------------------------------------ #
# Internal dispatch (one pair per addressing mode)                    #
# ------------------------------------------------------------------ #
#
# Five dispatch functions per target, one per underlying primitive.
# The body of each public API function calls one of them; this keeps
# the routing difference confined to a single line per primitive.
#
# Naming convention:
#
#   _dispatch_call           -- synchronous blocking call
#   _dispatch_async          -- async request, response via token
#   _dispatch_async_seq      -- async request with FIFO ordering
#   _dispatch_notify         -- one-way notify
#   _dispatch_seq_notify     -- one-way notify with FIFO ordering

# App-name addressing
_dispatch_call(t::AppTarget, hnd::Ptr{Cvoid}, timeout_ms::Int) =
    LF_Call(t.app_name, hnd, UInt64(timeout_ms))
_dispatch_async(t::AppTarget, hnd::Ptr{Cvoid}, token::Int64) =
    shim_async_call(t.app_name, hnd, token)
_dispatch_async_seq(t::AppTarget, hnd::Ptr{Cvoid}, token::Int64) =
    shim_async_sequenced_call(t.app_name, hnd, token)
_dispatch_notify(t::AppTarget, hnd::Ptr{Cvoid}) =
    LF_Notify(t.app_name, hnd)
_dispatch_seq_notify(t::AppTarget, hnd::Ptr{Cvoid}) =
    LF_Sequenced_Notify(t.app_name, hnd)

# UID addressing
_dispatch_call(t::UIDTarget, hnd::Ptr{Cvoid}, timeout_ms::Int) =
    LF_UID_Call(t.uid, hnd, UInt64(timeout_ms))
_dispatch_async(t::UIDTarget, hnd::Ptr{Cvoid}, token::Int64) =
    shim_uid_async_call(t.uid, hnd, token)
_dispatch_async_seq(t::UIDTarget, hnd::Ptr{Cvoid}, token::Int64) =
    shim_uid_async_sequenced_call(t.uid, hnd, token)
_dispatch_notify(t::UIDTarget, hnd::Ptr{Cvoid}) =
    LF_UID_Notify(t.uid, hnd)
_dispatch_seq_notify(t::UIDTarget, hnd::Ptr{Cvoid}) =
    LF_UID_Sequenced_Notify(t.uid, hnd)

# P2PName addressing
_dispatch_call(t::P2PNameTarget, hnd::Ptr{Cvoid}, timeout_ms::Int) =
    LF_P2PNAME_Call(t.group_name, hnd, UInt64(timeout_ms))
_dispatch_async(t::P2PNameTarget, hnd::Ptr{Cvoid}, token::Int64) =
    shim_p2pname_async_call(t.group_name, hnd, token)
_dispatch_async_seq(t::P2PNameTarget, hnd::Ptr{Cvoid}, token::Int64) =
    shim_p2pname_async_sequenced_call(t.group_name, hnd, token)
_dispatch_notify(t::P2PNameTarget, hnd::Ptr{Cvoid}) =
    LF_P2PNAME_Notify(t.group_name, hnd)
_dispatch_seq_notify(t::P2PNameTarget, hnd::Ptr{Cvoid}) =
    LF_P2PNAME_Sequenced_Notify(t.group_name, hnd)

# ------------------------------------------------------------------ #
# Payload construction                                                #
# ------------------------------------------------------------------ #

"""
    _build_param(api_name::String, payload) -> DataHandle

Build a `DataHandle` for the request payload.

Accepted payload forms:
    nothing                   -- empty buffer
    Vector{UInt8}             -- raw bytes written verbatim
    Function(dh::DataHandle)  -- caller writes into the handle

The returned handle has its cursor reset to 0, so the framework reads
the payload from the beginning.
"""
function _build_param(api_name::String, payload)::DataHandle
    dh = DataHandle(api_name)
    try
        if payload === nothing
            # empty payload; nothing to write
        elseif payload isa AbstractVector{UInt8}
            write_buffer!(dh, Vector{UInt8}(payload))
        elseif payload isa Function
            payload(dh)
        else
            throw(ArgumentError(
                "payload must be nothing, Vector{UInt8}, or " *
                "Function(DataHandle); got $(typeof(payload))"
            ))
        end
        set_cursor_position!(dh, 0)
        return dh
    catch
        dispose!(dh)
        rethrow()
    end
end

# Internal: read the bytes of a result handle and dispose it. Used by
# `call` to convert the raw C result into a Julia vector.
function _read_result_bytes(result_hnd::Ptr{Cvoid})::Vector{UInt8}
    dh = DataHandle(result_hnd, true)
    try
        sz = buffer_size(dh)
        sz <= 0 && return UInt8[]
        set_cursor_position!(dh, 0)
        return read_buffer!(dh, Int(sz))
    finally
        dispose!(dh)
    end
end

# ------------------------------------------------------------------ #
# Synchronous API                                                     #
# ------------------------------------------------------------------ #

"""
    call(target, api_name, payload = nothing; timeout_ms = -1) -> Vector{UInt8}

Send a blocking request and return the response bytes.

When `timeout_ms` is negative (the default), the target's own default
timeout is used. A value of 0 means "no timeout".

Throws:
    LingoFuseCallError     -- the framework could not deliver the
                              request, or the peer returned a NULL
                              result handle.
    LingoFuseTimeoutError  -- the call did not complete within the
                              timeout window. The C side signals
                              this by returning a size-0 handle.

Returns an empty `Vector{UInt8}` when the peer returned an empty
response. This is indistinguishable from a timeout at the C ABI
level; see the module docstring.
"""
function call(target::AbstractTarget,
              api_name::AbstractString,
              payload = nothing;
              timeout_ms::Integer = -1)::Vector{UInt8}
    tm = timeout_ms < 0 ? target.default_timeout_ms : Int(timeout_ms)
    tm < 0 && throw(ArgumentError("timeout_ms must be non-negative"))

    api_str = String(api_name)
    param = _build_param(api_str, payload)
    raw = Ptr{Cvoid}(0)
    try
        raw = _dispatch_call(target, param.handle, tm)
    finally
        dispose!(param)
    end

    if raw == C_NULL
        throw(LingoFuseCallError(api_str,
            "call on $(_describe(target)) returned a null handle"))
    end

    sz = LF_GetSize(raw)
    if sz == 0
        LF_FreeData(raw)
        throw(LingoFuseTimeoutError(api_str, UInt64(tm)))
    end

    return _read_result_bytes(raw)
end

"""
    notify(target, api_name, payload = nothing) -> Nothing

Send a one-way notification. No response is expected and no ordering
guarantee is provided. Use `sequenced_notify` when ordering matters.

The call blocks until the notification has been handed to the
transport (or, for a local-first match, until the local callback has
completed). It does not wait for any remote processing.
"""
function notify(target::AbstractTarget,
                api_name::AbstractString,
                payload = nothing)::Nothing
    api_str = String(api_name)
    param = _build_param(api_str, payload)
    try
        _dispatch_notify(target, param.handle)
    finally
        dispose!(param)
    end
    return nothing
end

"""
    sequenced_notify(target, api_name, payload = nothing) -> Nothing

Send a one-way notification with FIFO ordering per
(target_key, api_name) pair. The target_key is the app name, the UID,
or the P2P group name, depending on the addressing mode.

Blocks until the notification has been handed to the transport.
"""
function sequenced_notify(target::AbstractTarget,
                          api_name::AbstractString,
                          payload = nothing)::Nothing
    api_str = String(api_name)
    param = _build_param(api_str, payload)
    try
        _dispatch_seq_notify(target, param.handle)
    finally
        dispose!(param)
    end
    return nothing
end

# ------------------------------------------------------------------ #
# Asynchronous API (Future)                                           #
# ------------------------------------------------------------------ #

"""
    future(target, api_name, payload = nothing; timeout_ms = -1) -> Future

Issue an asynchronous request and return a `Future` immediately.

The Future resolves with a `Vector{UInt8}` (the response payload)
when the response arrives, or with an exception when the request
fails or times out. See `src/async.jl` for the Future contract.

Timeout is "soft": when `timeout_ms` elapses before the response
arrives, the Future is resolved with `LingoFuseTimeoutError` and
`is_abandoned(fut)` becomes true, but the C-side request may still be
in flight. Any late result is silently discarded.

A `timeout_ms` of 0 disables the Julia-side timeout; the Future will
wait indefinitely for a result. This is rarely appropriate for
remote calls; it is provided for callers that implement their own
timeout at a higher layer.
"""
function future(target::AbstractTarget,
                api_name::AbstractString,
                payload = nothing;
                timeout_ms::Integer = -1)::Future
    tm = timeout_ms < 0 ? target.default_timeout_ms : Int(timeout_ms)
    tm < 0 && throw(ArgumentError("timeout_ms must be non-negative"))

    api_str = String(api_name)

    # The Future's token field is `const`, so the token must be
    # allocated before the Future is constructed. But the handler
    # registered for that token needs to reference the Future, which
    # does not exist yet. Break the cycle with two Refs, populated in
    # the order: handler -> token -> future.
    #
    # The event that would invoke the handler cannot arrive before
    # the dispatch below, and the dispatch happens after both Refs
    # are populated, so no race is possible.
    fut_ref   = Ref{Union{Future, Nothing}}(nothing)
    token_ref = Ref{Int64}(0)

    handler = function (result_bytes::Vector{UInt8})
        f = fut_ref[]
        f === nothing && return nothing
        if _try_resolve!(f, :result, result_bytes)
            release_async_handler(token_ref[])
        end
        return nothing
    end

    tok = register_async_handler(handler)
    token_ref[] = tok

    fut = _make_future(tok)
    fut_ref[] = fut

    param = _build_param(api_str, payload)
    ret = try
        _dispatch_async(target, param.handle, tok)
    finally
        dispose!(param)
    end

    if ret != 1
        release_async_handler(tok)
        _try_resolve!(fut, :error,
            LingoFuseCallError(api_str,
                "async dispatch returned $ret (request not queued) " *
                "on $(_describe(target))"))
        return fut
    end

    if tm > 0
        Threads.@spawn begin
            sleep(tm / 1000.0)
            if _try_resolve!(fut, :timeout, nothing)
                release_async_handler(tok)
            end
        end
    end

    return fut
end

"""
    sequenced_future(target, api_name, payload = nothing; timeout_ms = -1) -> Future

Asynchronous variant of `sequenced_notify`'s counterpart for calls:
same as `future`, but the framework maintains FIFO ordering per
(target_key, api_name) pair.
"""
function sequenced_future(target::AbstractTarget,
                          api_name::AbstractString,
                          payload = nothing;
                          timeout_ms::Integer = -1)::Future
    tm = timeout_ms < 0 ? target.default_timeout_ms : Int(timeout_ms)
    tm < 0 && throw(ArgumentError("timeout_ms must be non-negative"))

    api_str = String(api_name)

    fut_ref   = Ref{Union{Future, Nothing}}(nothing)
    token_ref = Ref{Int64}(0)

    handler = function (result_bytes::Vector{UInt8})
        f = fut_ref[]
        f === nothing && return nothing
        if _try_resolve!(f, :result, result_bytes)
            release_async_handler(token_ref[])
        end
        return nothing
    end

    tok = register_async_handler(handler)
    token_ref[] = tok

    fut = _make_future(tok)
    fut_ref[] = fut

    param = _build_param(api_str, payload)
    ret = try
        _dispatch_async_seq(target, param.handle, tok)
    finally
        dispose!(param)
    end

    if ret != 1
        release_async_handler(tok)
        _try_resolve!(fut, :error,
            LingoFuseCallError(api_str,
                "async sequenced dispatch returned $ret " *
                "(request not queued) on $(_describe(target))"))
        return fut
    end

    if tm > 0
        Threads.@spawn begin
            sleep(tm / 1000.0)
            if _try_resolve!(fut, :timeout, nothing)
                release_async_handler(tok)
            end
        end
    end

    return fut
end

# ------------------------------------------------------------------ #
# Asynchronous API (do-block callback)                                #
# ------------------------------------------------------------------ #
#
# The user callback receives (result, err) as positional arguments,
# per decision D2. `result` is a Vector{UInt8} on success and
# `nothing` on failure; `err` is `nothing` on success and an
# exception on failure.
#
# The callback runs on a dedicated watcher task, NOT on the callback
# consumer thread. It MAY block, MAY wait on additional Futures, and
# MAY call any other LingoFuse API except shutdown / exit_main_thread.
#
# The do-block syntax relies on Julia's convention that the callback
# is passed as the FIRST positional argument, so these functions are
# declared as `async_call(on_result, target, api, payload)`. The
# user-facing call site looks natural:
#
#     async_call(t_app, "add", payload) do result, err
#         ...
#     end
#
# The do-block form is equivalent to:
#
#     async_call((result, err) -> begin ... end, t_app, "add", payload)

"""
    async_call(on_result::Function, target, api_name, payload = nothing;
               timeout_ms = -1) -> Future

Issue an asynchronous request and deliver the result to a callback.

The callback is invoked with two positional arguments:

    on_result(result::Union{Vector{UInt8}, Nothing},
              err::Union{Exception, Nothing})

On success, `result` is the response payload and `err` is `nothing`.
On failure (dispatch error, peer error, or timeout), `result` is
`nothing` and `err` is the corresponding exception.

The callback runs on a dedicated watcher task. It may block and may
call other LingoFuse APIs, except `shutdown` and `exit_main_thread`.

Use the do-block form for the idiomatic Julia syntax:

    async_call(t_app, "add", payload) do result, err
        if err !== nothing
            @error "call failed" exception = err
        else
            @info "got result" length(result)
        end
    end

Returns the underlying `Future` immediately after the request has
been queued. Most callers ignore it; callers that need to correlate
the callback with the request (for diagnostics or for waiting) can
use it. See `src/async.jl` for the Future contract.
"""
function async_call(on_result::Function,
                    target::AbstractTarget,
                    api_name::AbstractString,
                    payload = nothing;
                    timeout_ms::Integer = -1)::Future
    on_result isa Function ||
        throw(ArgumentError("on_result must be a Function"))

    fut = future(target, api_name, payload; timeout_ms = timeout_ms)

    Threads.@spawn begin
        wait(fut)
        if fut.error !== nothing
            on_result(nothing, fut.error)
        else
            on_result(fut.result, nothing)
        end
    end

    return fut
end

"""
    async_sequenced_call(on_result::Function, target, api_name,
                         payload = nothing; timeout_ms = -1) -> Future

Sequenced variant of `async_call`. FIFO ordering is preserved per
(target_key, api_name) pair. See `async_call` for the full contract
of the callback and its execution context.

Returns the underlying `Future` immediately after the request has
been queued.
"""
function async_sequenced_call(on_result::Function,
                              target::AbstractTarget,
                              api_name::AbstractString,
                              payload = nothing;
                              timeout_ms::Integer = -1)::Future
    on_result isa Function ||
        throw(ArgumentError("on_result must be a Function"))

    fut = sequenced_future(target, api_name, payload;
                           timeout_ms = timeout_ms)

    Threads.@spawn begin
        wait(fut)
        if fut.error !== nothing
            on_result(nothing, fut.error)
        else
            on_result(fut.result, nothing)
        end
    end

    return fut
end

# ------------------------------------------------------------------ #
# Internal: describe a target for error messages                      #
# ------------------------------------------------------------------ #

_describe(t::AppTarget)::String     = "app($(repr(t.app_name)))"
_describe(t::UIDTarget)::String     = "uid($(uid_to_hex(t.uid)))"
_describe(t::P2PNameTarget)::String = "p2pname($(repr(t.group_name)))"

# ------------------------------------------------------------------ #
# Exports                                                             #
# ------------------------------------------------------------------ #

export AbstractTarget,
       AppTarget,
       UIDTarget,
       P2PNameTarget,
       app_target,
       uid_target,
       p2pname_target,
       call,
       notify,
       sequenced_notify,
       future,
       sequenced_future,
       async_call,
       async_sequenced_call