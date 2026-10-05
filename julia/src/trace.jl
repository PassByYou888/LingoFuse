# trace.jl - Lightweight runtime trace for diagnosing hangs and
# unexpected behavior in the LingoFuse Julia binding.
#
# Design
# ------
# The trace facility is intentionally minimal:
#
#   - It writes to stderr, one line per event, with a thread id and a
#     wall-clock timestamp.
#   - It never allocates a Julia object beyond the formatted string.
#   - It is disabled by default and enabled through the environment
#     variable LINGOFUSE_TRACE=1, or by calling set_trace!(true) at
#     runtime.
#
# Why stderr and not the @info logger
# -----------------------------------
# The Julia logging system routes through a task-local, potentially
# buffered pipeline. When the process is suspected of hanging, the
# value of a diagnostic is proportional to how quickly it reaches the
# terminal. Direct println + flush is the only mechanism with that
# guarantee, and it matches the approach used by the Step 1 test
# harness (see SHIM_MECHANISM_GUIDE.md).
#
# Thread safety
# -------------
# println to stderr takes Julia's standard stderr lock, so concurrent
# trace calls from multiple threads do not interleave mid-line.

const _TRACE_ENABLED = Ref{Bool}(false)

function _trace_env_default()::Bool
    v = lowercase(strip(get(ENV, "LINGOFUSE_TRACE", "0")))
    return v == "1" || v == "true" || v == "yes" || v == "on"
end

function _trace_init()
    _TRACE_ENABLED[] = _trace_env_default()
    return
end

_trace_init()

"""
    trace_enabled() -> Bool

Return `true` when runtime tracing is active.
"""
trace_enabled()::Bool = _TRACE_ENABLED[]

"""
    set_trace!(on::Bool) -> Nothing

Enable or disable runtime tracing at any point during the process
lifetime.
"""
function set_trace!(on::Bool)
    _TRACE_ENABLED[] = on
    return
end

"""
    trace(msg) -> Nothing

Emit one trace line to stderr when tracing is enabled. The line
includes the thread id and a wall-clock timestamp so that concurrent
events can be ordered.
"""
function trace(msg::AbstractString)
    _TRACE_ENABLED[] || return nothing
    tid = Threads.threadid()
    t   = round(time(); digits=3)
    println(stderr, "[LF][tid=", tid, "][t=", t, "] ", msg)
    flush(stderr)
    return nothing
end

export trace,
       trace_enabled,
       set_trace!