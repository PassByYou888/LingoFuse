# test_async_unit.jl - Unit tests for src/async.jl.
#
# Coverage:
#   - Future construction (via the internal factory)
#   - Initial state: not done, not abandoned, no result, no error
#   - _try_resolve! with :result / :error / :timeout
#   - Idempotence of _try_resolve! (second call returns false)
#   - fetch: returns the result, throws the error, throws on timeout
#   - wait: blocks until resolved, does NOT throw
#   - isready: true after resolution, false before
#   - is_abandoned: true ONLY for the timeout tag
#   - show: all four states produce distinguishable output
#   - Concurrency: N tasks racing to resolve the same Future, exactly
#     one wins
#
# This file has no C dependency, no shim dependency, and no network
# dependency. It exercises only the pure-Julia Future type, so it
# runs on any Julia installation.
#
# LingoFuseError is an abstract type; the test constructs concrete
# subtypes (LingoFuseStateError, LingoFuseIoError, ...) wherever an
# arbitrary exception is needed.
#
# Exit code: 0 on success, 1 on any failure.

const _SRC = joinpath(@__DIR__, "..", "src")

include(joinpath(_SRC, "error.jl"))
include(joinpath(_SRC, "async.jl"))

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test_async_unit] $tag  $msg")
    flush(stderr)
    if cond
        passed[] += 1
    else
        failed[] += 1
    end
    return cond
end

# -------------------------------------------------------------------- #
# Construction and initial state                                       #
# -------------------------------------------------------------------- #

println(stderr, "[test_async_unit] --- construction ---")

let f = _make_future(42)
    ck(f isa Future, "_make_future returns a Future")
    ck(f.token == 42, "token is preserved")
    ck(!f.done, "fresh Future is not done")
    ck(!f.abandoned, "fresh Future is not abandoned")
    ck(f.result === nothing, "fresh Future has no result")
    ck(f.error === nothing, "fresh Future has no error")
    ck(!isready(f), "isready(fresh) is false")
    ck(!is_abandoned(f), "is_abandoned(fresh) is false")
end

# -------------------------------------------------------------------- #
# _try_resolve! with :result                                           #
# -------------------------------------------------------------------- #

println(stderr, "[test_async_unit] --- resolve :result ---")

let f = _make_future(1)
    payload = UInt8[0x61, 0x62, 0x63]
    won = _try_resolve!(f, :result, payload)
    ck(won, "_try_resolve! returns true on the first call")
    ck(f.done, "Future is done after resolution")
    ck(!f.abandoned, "not abandoned after :result resolution")
    ck(f.result == payload, "result payload is stored")
    ck(f.error === nothing, "no error after :result resolution")
    ck(isready(f), "isready is true after resolution")

    # Second attempt must fail and must NOT overwrite the state.
    lost = _try_resolve!(f, :result, UInt8[0x78])
    ck(!lost, "second _try_resolve! returns false")
    ck(f.result == payload,
       "second _try_resolve! does not overwrite the result")

    fetched = fetch(f)
    ck(fetched == payload, "fetch returns the original payload")

    waited = wait(f)
    ck(waited === nothing, "wait returns nothing on a resolved Future")
end

# -------------------------------------------------------------------- #
# _try_resolve! with :error                                            #
# -------------------------------------------------------------------- #

println(stderr, "[test_async_unit] --- resolve :error ---")

let f = _make_future(2)
    err = LingoFuseStateError("simulated failure")
    won = _try_resolve!(f, :error, err)
    ck(won, "_try_resolve! :error returns true")
    ck(f.done, "Future is done")
    ck(!f.abandoned, "not abandoned after :error resolution")
    ck(f.result === nothing, "no result after :error resolution")
    ck(f.error === err, "error object is stored by identity")

    threw = false
    caught = nothing
    try
        fetch(f)
    catch e
        threw = true
        caught = e
    end
    ck(threw, "fetch throws on an errored Future")
    ck(caught === err, "fetch throws the exact error object")

    # wait must NOT throw.
    threw2 = false
    try
        wait(f)
    catch
        threw2 = true
    end
    ck(!threw2, "wait does NOT throw on an errored Future")
end

# -------------------------------------------------------------------- #
# _try_resolve! with :timeout                                          #
# -------------------------------------------------------------------- #

println(stderr, "[test_async_unit] --- resolve :timeout ---")

let f = _make_future(3)
    won = _try_resolve!(f, :timeout, nothing)
    ck(won, "_try_resolve! :timeout returns true")
    ck(f.done, "Future is done")
    ck(f.abandoned, "Future is marked abandoned")
    ck(f.error isa LingoFuseTimeoutError,
       "timeout resolution stores a LingoFuseTimeoutError")
    ck(is_abandoned(f), "is_abandoned is true")

    threw = false
    caught = nothing
    try
        fetch(f)
    catch e
        threw = true
        caught = e
    end
    ck(threw, "fetch throws on an abandoned Future")
    ck(caught isa LingoFuseTimeoutError,
       "the thrown error is a LingoFuseTimeoutError")
end

# A Future resolved with :result must report abandoned == false.
let f = _make_future(4)
    _try_resolve!(f, :result, "ok")
    ck(!is_abandoned(f),
       "is_abandoned is false on a result-resolved Future")
end

# A Future resolved with :error must report abandoned == false.
let f = _make_future(5)
    _try_resolve!(f, :error, LingoFuseStateError("x"))
    ck(!is_abandoned(f),
       "is_abandoned is false on an error-resolved Future")
end

# An unknown tag must resolve the Future with a state error, not
# crash.
let f = _make_future(6)
    won = _try_resolve!(f, :bogus_tag, nothing)
    ck(won, "_try_resolve! with an unknown tag returns true")
    ck(f.done, "Future is done after an unknown-tag resolution")
    ck(f.error isa LingoFuseStateError,
       "unknown tag produces a LingoFuseStateError")
end

# -------------------------------------------------------------------- #
# show                                                                 #
# -------------------------------------------------------------------- #

println(stderr, "[test_async_unit] --- show ---")

let f = _make_future(10)
    s = sprint(show, f)
    ck(occursin("pending", s), "show on a fresh Future says 'pending'")
end

let f = _make_future(11)
    _try_resolve!(f, :result, UInt8[])
    s = sprint(show, f)
    ck(occursin("resolved", s), "show on a resolved Future says 'resolved'")
end

let f = _make_future(12)
    _try_resolve!(f, :error, LingoFuseStateError("boom"))
    s = sprint(show, f)
    ck(occursin("error", s), "show on an errored Future mentions 'error'")
end

let f = _make_future(13)
    _try_resolve!(f, :timeout, nothing)
    s = sprint(show, f)
    ck(occursin("abandoned", s),
       "show on an abandoned Future says 'abandoned'")
end

# -------------------------------------------------------------------- #
# Concurrency: N tasks race to resolve the same Future                #
# -------------------------------------------------------------------- #
#
# This is the correctness property the whole design rests on: the
# Future is resolved by EXACTLY ONE winner, regardless of how many
# concurrent attempts there are, and the losing attempts observe
# false and do nothing.
#
# The test uses a small number of tasks (16) with a tight
# synchronisation barrier; on a multi-threaded Julia session the
# tasks will genuinely run concurrently. On a single-threaded session
# they will interleave; the property holds either way.

println(stderr, "[test_async_unit] --- concurrency ---")

let
    N = 16
    f = _make_future(100)
    wins = Threads.Atomic{Int}(0)
    losses = Threads.Atomic{Int}(0)

    # Each task tries to resolve the Future with a distinct payload.
    # Exactly one task must win; every other must observe false.
    tasks = Task[]
    for i in 1:N
        push!(tasks, Threads.@spawn begin
            ok = _try_resolve!(f, :result, i)
            if ok
                Threads.atomic_add!(wins, 1)
            else
                Threads.atomic_add!(losses, 1)
            end
        end)
    end
    foreach(wait, tasks)

    ck(wins[] == 1,
       "exactly one task resolved the Future (wins=$(wins[]))")
    ck(losses[] == N - 1,
       "all other tasks observed false (losses=$(losses[]))")

    # The result must be one of the N candidate values.
    r = fetch(f)
    ck(r isa Int && 1 <= r <= N,
       "the stored result is one of the N candidates (got $(r))")
end

# Same race, mixed tags. The winner is whichever task got there
# first; the test only asserts the "exactly one winner" property.
let
    N = 8
    f = _make_future(101)
    wins = Threads.Atomic{Int}(0)

    tasks = Task[]
    for i in 1:N
        tag = isodd(i) ? :result : :error
        payload = tag === :result ? "r$(i)" : LingoFuseStateError("e$(i)")
        push!(tasks, Threads.@spawn begin
            ok = _try_resolve!(f, tag, payload)
            ok && Threads.atomic_add!(wins, 1)
        end)
    end
    foreach(wait, tasks)

    ck(wins[] == 1,
       "mixed-tag race also has exactly one winner (wins=$(wins[]))")

    # Whether the winner stored a result or an error, the Future must
    # be in a self-consistent terminal state.
    ck(isready(f), "Future is done after the mixed-tag race")
    consistent = (f.result === nothing) != (f.error === nothing)
    ck(consistent,
       "exactly one of result / error is set (result=" *
       "$(f.result === nothing ? "nothing" : "set"), " *
       "error=$(f.error === nothing ? "nothing" : "set"))")
end

# -------------------------------------------------------------------- #
# Blocking behaviour                                                   #
# -------------------------------------------------------------------- #
#
# fetch / wait on a pending Future must block until it is resolved.
# This is verified with a producer task that resolves the Future
# after a short delay.

println(stderr, "[test_async_unit] --- blocking behaviour ---")

let
    f = _make_future(200)
    guard = ReentrantLock()
    resolved_at = Ref{Float64}(0.0)

    producer = Threads.@spawn begin
        sleep(0.05)
        _try_resolve!(f, :result, UInt8[0x01, 0x02])
        lock(guard) do
            resolved_at[] = time()
        end
    end

    t0 = time()
    r = fetch(f)
    t1 = time()

    wait(producer)

    ck(r == UInt8[0x01, 0x02],
       "fetch returns the value the producer stored")
    ck(t1 - t0 >= 0.04,
       "fetch blocked until the producer resolved " *
       "(elapsed=$(round(t1 - t0; digits=4))s)")
end

# -------------------------------------------------------------------- #
# Summary                                                              #
# -------------------------------------------------------------------- #

println(stderr, "")
println(stderr, "[test_async_unit] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test_async_unit] OK")
    exit(0)
else
    println(stderr, "[test_async_unit] FAILED")
    exit(1)
end