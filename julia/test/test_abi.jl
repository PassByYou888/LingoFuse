# test_abi.jl - Binding-completeness test for src/abi.jl.
#
# Coverage:
#   - All 59 exported LF_* symbols are bound as Julia functions.
#   - Every exported symbol listed in LingoFuse.lpr is present.
#   - No unexpected LF_* symbol is bound (no stale binding).
#   - A few safe, side-effect-free calls return sensible defaults.
#
# This file loads the real LingoFuse runtime through loader.jl. It
# does NOT prepare any service or client, does NOT start the simulated
# main thread, and does NOT register any callback. The calls it makes
# are limited to functions that are safe to call before prepare_done:
#
#   LF_CheckMainThread   -> returns 0 before prepare_done
#   LF_GetStatusCount    -> returns a non-negative integer
#   LF_SetOption         -> accepts and stores an option
#   LF_GetOption         -> returns the stored value
#
# Exit code: 0 on success, 1 on any failure.

ENV["LINGOFUSE_TRACE"] = "0"

const _SRC = joinpath(@__DIR__, "..", "src")

include(joinpath(_SRC, "trace.jl"))
include(joinpath(_SRC, "error.jl"))
include(joinpath(_SRC, "uid.jl"))
include(joinpath(_SRC, "loader.jl"))
include(joinpath(_SRC, "abi.jl"))

passed = Ref(0)
failed = Ref(0)

function ck(cond::Bool, msg::String)
    tag = cond ? "PASS" : "FAIL"
    println(stderr, "[test_abi] $tag  $msg")
    flush(stderr)
    if cond
        passed[] += 1
    else
        failed[] += 1
    end
    return cond
end

# -------------------------------------------------------------------- #
# Expected symbol list                                                 #
# -------------------------------------------------------------------- #
#
# Verbatim transcription of the exports clause in LingoFuse.lpr.
# Order is preserved for readability; the checks below treat it as a
# set.

const EXPECTED_SYMBOLS = [
    # Data handles (12)
    :LF_CreateData,
    :LF_CreateData_Permanent,
    :LF_FreeData,
    :LF_GetBuffer,
    :LF_WriteBuffer,
    :LF_ReadBuffer,
    :LF_GetPos,
    :LF_SetPos,
    :LF_GetSize,
    :LF_SetSize,
    :LF_Get_P2P_UID,
    :LF_Get_P2P_Name,

    # Application handles (5)
    :LF_CreateApp,
    :LF_FreeApp,
    :LF_Generate_AppName,
    :LF_Get_AppName,
    :LF_BindApp,

    # API registration (app-bound) (3)
    :LF_RegisterCall,
    :LF_RegisterNotify,
    :LF_Unregister,

    # API registration (process-wide P2P) (3)
    :LF_Register_P2P_Call,
    :LF_Register_P2P_Notify,
    :LF_Unregister_P2P,

    # Local execution (2)
    :LF_LocalCall,
    :LF_LocalNotify,

    # Network preparation (5)
    :LF_ResetPrepare,
    :LF_PrepareService,
    :LF_PrepareClient,
    :LF_PrepareDone,
    :LF_ExitMainThread,

    # Remote invocation by app name (5)
    :LF_Call,
    :LF_Async_Call,
    :LF_Async_Sequenced_Call,
    :LF_Notify,
    :LF_Sequenced_Notify,

    # Remote invocation by UID (5)
    :LF_UID_Call,
    :LF_UID_Async_Call,
    :LF_UID_Async_Sequenced_Call,
    :LF_UID_Notify,
    :LF_UID_Sequenced_Notify,

    # Remote invocation by P2P name (5)
    :LF_P2PNAME_Call,
    :LF_P2PNAME_Async_Call,
    :LF_P2PNAME_Async_Sequenced_Call,
    :LF_P2PNAME_Notify,
    :LF_P2PNAME_Sequenced_Notify,

    # Health checks (7)
    :LF_CheckMainThread,
    :LF_CheckApp,
    :LF_CheckApi,
    :LF_Check_UID,
    :LF_Check_UID_Api,
    :LF_Check_P2PNAME,
    :LF_Check_P2PNAME_Api,

    # Runtime options (2)
    :LF_SetOption,
    :LF_GetOption,

    # Status / diagnostics (3)
    :LF_GetStatusCount,
    :LF_GetStatus,
    :LF_PostStatus,

    # Network events (1)
    :LF_Set_Network_Event,

    # Shutdown (1)
    :LF_Shutdown,
]

# Sanity check on the expected list itself.
ck(length(EXPECTED_SYMBOLS) == 59,
   "EXPECTED_SYMBOLS contains 59 entries (got $(length(EXPECTED_SYMBOLS)))")
ck(length(unique(EXPECTED_SYMBOLS)) == length(EXPECTED_SYMBOLS),
   "EXPECTED_SYMBOLS contains no duplicates")

# -------------------------------------------------------------------- #
# Every expected symbol is bound                                       #
# -------------------------------------------------------------------- #

println(stderr, "[test_abi] --- symbol presence ---")

let missing = Symbol[]
    for name in EXPECTED_SYMBOLS
        if !isdefined(Main, name)
            push!(missing, name)
        end
    end
    if isempty(missing)
        ck(true, "all 59 expected symbols are bound")
    else
        ck(false, "missing symbols: $(join(string.(missing), ", "))")
    end
end

# Every bound symbol is a Function.
let nonfuncs = Symbol[]
    for name in EXPECTED_SYMBOLS
        if !isdefined(Main, name)
            continue
        end
        v = getfield(Main, name)
        if !(v isa Function)
            push!(nonfuncs, name)
        end
    end
    if isempty(nonfuncs)
        ck(true, "all bound symbols are Function instances")
    else
        ck(false, "non-function bindings: $(join(string.(nonfuncs), ", "))")
    end
end

# No unexpected LF_* function is bound.
#
# The check scans Main for every binding whose name starts with "LF_"
# and is a Function. It reports those not in EXPECTED_SYMBOLS. This
# catches a stale binding whose name does not appear in
# LingoFuse.lpr's exports clause.
let expected_set = Set(EXPECTED_SYMBOLS)
    unexpected = Symbol[]
    for n in names(Main; all = true)
        s = string(n)
        if startswith(s, "LF_")
            v = try
                getfield(Main, n)
            catch
                continue
            end
            if v isa Function && !(n in expected_set)
                push!(unexpected, n)
            end
        end
    end
    if isempty(unexpected)
        ck(true, "no unexpected LF_* Function binding found")
    else
        ck(false, "unexpected LF_* bindings: " *
                  "$(join(string.(unexpected), ", "))")
    end
end

# -------------------------------------------------------------------- #
# Safe calls                                                           #
# -------------------------------------------------------------------- #
#
# These functions are safe to call before prepare_done and do not
# mutate any network or callback state.

println(stderr, "[test_abi] --- safe calls ---")

# LF_CheckMainThread returns 0 before prepare_done.
let r = LF_CheckMainThread()
    ck(r == 0, "LF_CheckMainThread == 0 before prepare_done (got $r)")
end

# LF_GetStatusCount returns a non-negative integer.
let n = LF_GetStatusCount()
    ck(n >= 0, "LF_GetStatusCount >= 0 (got $n)")
end

# LF_GetStatus returns a String (possibly empty).
let s = LF_GetStatus()
    ck(s isa String, "LF_GetStatus returns a String")
end

# Round-trip a runtime option.
let marker = "jltest_abi_marker_$(getpid())"
    LF_SetOption("Quiet", "True")
    v1 = LF_GetOption("Quiet")
    ck(v1 == "True", "LF_SetOption/GetOption round-trips a boolean (got '$v1')")

    LF_SetOption("Quiet", "False")
    v2 = LF_GetOption("Quiet")
    ck(v2 == "False", "second round-trip (got '$v2')")

    # Unknown option -> empty string.
    v3 = LF_GetOption(marker)
    ck(v3 == "", "unknown option yields an empty string (got '$v3')")
end

# LF_Get_P2P_UID / LF_Get_P2P_Name on a self-created handle: the C
# side logs a warning and returns a zero UID / empty string. The
# call itself must not crash.
let h = LF_CreateData("abi_identity_probe")
    try
        p = LF_Get_P2P_UID(h)
        ck(p != C_NULL,
           "LF_Get_P2P_UID returns a non-null pointer on a non-input handle")
        u = unsafe_load(p)
        ck(is_zero_uid(u),
           "LF_Get_P2P_UID yields a zero UID on a non-input handle")

        s = LF_Get_P2P_Name(h)
        ck(s == "",
           "LF_Get_P2P_Name yields an empty string on a non-input handle")
    finally
        LF_FreeData(h)
    end
end

# -------------------------------------------------------------------- #
# Summary                                                              #
# -------------------------------------------------------------------- #

println(stderr, "")
println(stderr, "[test_abi] results: passed=$(passed[])  failed=$(failed[])")
if failed[] == 0
    println(stderr, "[test_abi] OK")
    exit(0)
else
    println(stderr, "[test_abi] FAILED")
    exit(1)
end