# async.jl - Future type for asynchronous LingoFuse operations.
#
# This file defines the ONE primitive that the entire Julia async
# layer is built on: a small, self-contained Future.
#
# Design
# ------
# A LingoFuse async call goes through four distinct threads of
# control:
#
#   1. The CALLER thread creates a Future, registers a handler with
#      the callback consumer, and dispatches the request. It then
#      returns to the user's code.
#
#   2. The C SHIM, on a C4 worker thread (via the real library) or
#      a spawned native thread (via the mock), snapshots the result
#      and pushes an event onto the consumer queue.
#
#   3. The CONSUMER thread (a Julia task owned by callback.jl) pops
#      the event, reads the payload, and invokes the handler that
#      was registered in step 1.
#
#   4. The TIMEOUT task (a Julia task owned by Base.Timer) may fire
#      BEFORE step 3 does, if the response is late.
#
# Both step 3 and step 4 race to resolve the same Future. The Future
# must therefore be resolved by EXACTLY ONE of them, and the other
# must observe that the resolution already happened and drop its
# attempt. This is the sole job of the `_try_resolve!` function
# below.
#
# Why not Base.Channel
# --------------------
# A `Channel{T}(1)` would also work as the transport, but it has
# two drawbacks:
#
#   * `isready(ch)` is not a stable predicate: it flips to false
#     after the first read, so `isready` cannot be called twice to
#     "peek" at the state without consuming the value.
#   * Once the channel is closed, `fetch` and `wait` behave
#     differently, which complicates the state machine.
#
# A `Threads.Condition` with an explicit `done::Bool` field makes
# the state query trivially idempotent and keeps the resolution
# logic explicit. That is what this file uses.
#
# Base. prefix discipline
# -----------------------
# This file extends four Base functions on Future: fetch, wait,
# isready, and show. Julia's name resolution is dynamic for global
# bindings, so a different module that also exports `notify`,
# `wait`, or `fetch` can SHADOW the Base version inside this file's
# function bodies. That is exactly what happened with `notify`: the
# target.jl module exports a `notify(target, api, payload)` function,
# which shadowed `Base.notify(cond)` inside _try_resolve! and caused
# a MethodError the first time an async result arrived.
#
# To make every Base call in this file immune to such shadowing, all
# invocations of Base functions are written with an explicit `Base.`
# prefix. This is the standard Julia discipline for extending Base
# functions: inside the method body, always call the Base binding
# through its qualified name.
#
# Threading
# ---------
# Every operation on a Future is safe to call from any thread or
# task. All state transitions and all state reads happen under the
# Future's own `Threads.Condition`, which serves as both the
# synchronisation primitive and the "state lock".
#
# This file does NOT depend on callback.jl, target.jl, or any other
# binding-layer file. It only depends on the error hierarchy
# (error.jl) for LingoFuseTimeoutError and LingoFuseStateError.

# ------------------------------------------------------------------ #
# Type definition                                                     #
# ------------------------------------------------------------------ #

"""
    Future

Represents the eventual result of an asynchronous LingoFuse call.

A Future is created by the `future` and `sequenced_future` functions
in target.jl. It is a one-shot container: once resolved (by a
result, an error, or a timeout), it never changes state again.

Use `fetch(f)` to block on the result, `wait(f)` to block without
throwing, and `isready(f)` to poll. `is_abandoned(f)` distinguishes
the timeout case from other failures.

Internally, a Future uses a `Threads.Condition` for synchronisation,
so all operations are safe to call from any thread or task. It is
NOT a `Base.Future`-like object from Distributed; it is a small,
self-contained primitive tailored to LingoFuse's async contract.

Fields:
    token       The handler token allocated by callback.jl for this
                request. Retained for diagnostics and for advanced
                users who need to correlate a Future with the
                registry.

    done        `true` once resolved. Set exactly once, under the
                Condition's lock.

    abandoned   `true` when the resolution was a timeout. Only
                meaningful when `done` is also true.

    result      The result value (typically a `Vector{UInt8}`) when
                `error === nothing` and the Future was not abandoned.

    error       The exception to throw on fetch, or `nothing`.
"""
mutable struct Future
    const token::Int64
    const cv::Threads.Condition
    done::Bool
    abandoned::Bool
    result::Any
    error::Any
end

# Internal constructor. Not exported; user code always obtains a
# Future from `future()` or `sequenced_future()`.
function _make_future(token::Int64)::Future
    return Future(token, Threads.Condition(),
                  false, false, nothing, nothing)
end

# ------------------------------------------------------------------ #
# Resolution                                                          #
# ------------------------------------------------------------------ #

"""
    _try_resolve!(f::Future, tag::Symbol, payload) -> Bool

Attempt to resolve `f` with the given tag and payload. Returns true
when the state transition actually happened; false when the Future
had already been resolved, in which case the call is a no-op.

Tags:
    :result  -- payload is the result value (typically
                `Vector{UInt8}`)
    :error   -- payload is the exception to throw on fetch
    :timeout -- no payload; marks the Future as abandoned and stores
                a `LingoFuseTimeoutError` as the error

This function is thread-safe and idempotent. It is the ONLY way to
transition a Future from unresolved to resolved. Both the async
result handler (running on the consumer thread) and the timeout
timer (running on its own task) call it; whichever wins the race
observes `true`, the loser observes `false` and drops its attempt.

The `Base.notify` call is made while holding the Condition's lock,
as required by `Threads.Condition`'s contract. The `Base.` prefix is
mandatory: see the "Base. prefix discipline" note in the module
header.
"""
function _try_resolve!(f::Future, tag::Symbol, payload)::Bool
    Base.lock(f.cv)
    try
        f.done && return false
        f.done = true
        if tag === :result
            f.result = payload
        elseif tag === :error
            f.error = payload
        elseif tag === :timeout
            f.abandoned = true
            f.error = LingoFuseTimeoutError("<async>", UInt64(0))
        else
            f.error = LingoFuseStateError(
                "unknown Future tag: $(tag)"
            )
        end
        Base.notify(f.cv)
        return true
    finally
        Base.unlock(f.cv)
    end
end

# ------------------------------------------------------------------ #
# Consumer-side operations                                            #
# ------------------------------------------------------------------ #

"""
    fetch(f::Future) -> Any

Block until `f` is resolved, then return its result.

If the Future was resolved with an error (including a timeout), the
error is thrown. The result of a successful LingoFuse async call is
typically a `Vector{UInt8}`; the target layer (target.jl) may
transform it further (for example into a JSON value).

A Future is a one-shot value: `fetch` may be called more than once,
and every call after the first returns the same value immediately.
"""
function Base.fetch(f::Future)
    Base.lock(f.cv)
    try
        while !f.done
            Base.wait(f.cv)
        end
    finally
        Base.unlock(f.cv)
    end
    f.error !== nothing && throw(f.error)
    return f.result
end

"""
    wait(f::Future) -> Nothing

Block until `f` is resolved. Unlike `fetch`, this function does NOT
throw when the Future was resolved with an error. It is useful when
the caller only cares that the underlying operation has completed
(for example, before releasing a resource or before a subsequent
dependent call).

Returns `nothing` in every case. Callers that need the outcome
should use `fetch` or inspect the state via `isready` /
`is_abandoned` after `wait` returns.
"""
function Base.wait(f::Future)::Nothing
    Base.lock(f.cv)
    try
        while !f.done
            Base.wait(f.cv)
        end
    finally
        Base.unlock(f.cv)
    end
    return nothing
end

"""
    isready(f::Future) -> Bool

Return `true` if the Future has been resolved, `false` otherwise.

Non-blocking. Safe to call from any thread or task. This is the
"peek" primitive that the timeout logic uses to shrink its race
window; because state reads happen under the Condition's lock, it
is well-defined at every moment.
"""
function Base.isready(f::Future)::Bool
    Base.lock(f.cv)
    try
        return f.done
    finally
        Base.unlock(f.cv)
    end
end

"""
    is_abandoned(f::Future) -> Bool

Return `true` if the Future was resolved by a timeout, `false`
otherwise.

This is the ONLY reliable way to distinguish a timeout from any
other error. An abandoned Future throws a `LingoFuseTimeoutError`
on `fetch`, but so does any other Future whose resolution happened
to be a timeout, so a caller that needs the "was this a timeout?"
answer should consult this predicate rather than pattern-match on
the exception type.

An abandoned Future means the Python-side equivalent of
"CallFuture.abandoned == True": the C-side request may still be in
flight, and if its callback ever arrives, the result is silently
discarded by the callback consumer (see callback.jl,
_dispatch_async_result, the "no handler for token" branch).
"""
function is_abandoned(f::Future)::Bool
    Base.lock(f.cv)
    try
        return f.abandoned
    finally
        Base.unlock(f.cv)
    end
end

# ------------------------------------------------------------------ #
# Display                                                             #
# ------------------------------------------------------------------ #

function Base.show(io::IO, f::Future)
    Base.lock(f.cv)
    try
        if !f.done
            print(io, "Future(token=", f.token, ", pending)")
        elseif f.abandoned
            print(io, "Future(token=", f.token, ", abandoned)")
        elseif f.error !== nothing
            print(io, "Future(token=", f.token, ", error=",
                  typeof(f.error), ")")
        else
            print(io, "Future(token=", f.token, ", resolved)")
        end
    finally
        Base.unlock(f.cv)
    end
    return nothing
end

# ------------------------------------------------------------------ #
# Exports                                                             #
# ------------------------------------------------------------------ #

export Future, is_abandoned