# diag.jl - Minimal test: does a Julia closure called from another
# task hang when the main task is inside @threadcall?
#
# This is the Step 1 diagnostic that isolated the safepoint/GC
# interaction described in SHIM_MECHANISM_GUIDE.md §4.5. It is kept
# here as a diagnostic tool; it is NOT part of the acceptance test
# suite.
#
# Run with:
#
#     julia --threads=2 test/diag.jl

using Base.Threads

function log(msg)
    println(stderr, "[diag][tid=", threadid(), "] ", msg)
    flush(stderr)
end

function worker()
    log("worker START")
    f = x -> copy(x)
    for i in 1:200
        v = Vector{UInt8}(undef, 8192)
        fill!(v, 0x42)
        w = f(v)
        if i % 40 == 0
            log("worker tick $i, copied $(length(w)) bytes")
        end
        sleep(0.01)
    end
    log("worker DONE")
end

log("main START tid=$(threadid())")
t = Threads.@spawn worker()
sleep(0.2)
log("main entering @threadcall(Sleep, 2000 ms)")
@threadcall((:Sleep, "kernel32.dll"), Cvoid, (Cuint,), 2000)
log("main @threadcall returned")
wait(t)
log("main DONE")