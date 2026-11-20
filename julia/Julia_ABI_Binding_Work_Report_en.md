# LingoFuse Julia ABI Binding Work Report

> Chinese version: [Julia_ABI_Binding_Work_Report.md](Julia_ABI_Binding_Work_Report.md)

> **Document version**: v1.0
> **Scope**: building a Julia ABI code generator from scratch, and fixing missing functionality in the base `LingoFuse.jl` library
> **Core deliverables**: 4 Pascal generators + 5 C-file modifications + 3 rewritten Julia files
> **Working mode**: every stage went design → code → self-check; whenever a base-library problem surfaced, work stopped immediately to fix it rather than papering over it

---

## Contents

- [1. Project background and goals](#1-project-background-and-goals)
- [2. How the work was staged](#2-how-the-work-was-staged)
- [3. Stage A: design and planning](#3-stage-a-design-and-planning)
- [4. Stage B: the four Julia generators](#4-stage-b-the-four-julia-generators)
- [5. Stage C: fixing hard defects in the Julia base library](#5-stage-c-fixing-hard-defects-in-the-julia-base-library)
- [6. Key design trade-offs](#6-key-design-trade-offs)
- [7. Problems found and correction history](#7-problems-found-and-correction-history)
- [8. The verification checklist](#8-the-verification-checklist)
- [9. Open issues and next steps](#9-open-issues-and-next-steps)
- [10. An honest list of uncertainties](#10-an-honest-list-of-uncertainties)

---

## 1. Project background and goals

### 1.1 Problem statement

The `code_decl_to_abi` toolchain already supports 12 target languages: C++ / Pascal / Python / C# / Rust / Go / Java / Node.js / TypeScript / Erlang and others. The user asked for **Julia as the 13th target language**, with these guarantees:

1. **Multi-language ABI interoperability**: the service / call code Julia generates must be identical to the C++ / Pascal output at the wire-protocol level
2. **The tests must actually pass**: not "it compiles", but a service + call round trip that really works
3. **No papering over base-library problems**: defects in `LingoFuse.jl` must be fixed immediately, not bypassed
4. **Aligned with C++ / Pascal**: code style, API naming and file organisation must follow the two newest paradigms, `cpp_abi_*.pas` and `pas_abi_*.pas`

### 1.2 Points of reference

| Reference library | Role |
|--------|------|
| `cpp_abi_service_generator_tool.pas` | the C++ service-side generator (newest) |
| `cpp_abi_call_generator_tool.pas` | the C++ call-side generator (newest) |
| `cpp_abi_cmake_generator_tool.pas` | the C++ CMake + test generator (newest) |
| `pas_abi_service_generator_tool.pas` | the Pascal service-side generator (newest) |
| `pas_abi_call_generator_tool.pas` | the Pascal call-side generator (newest) |
| `pas_abi_test_generator_tool.pas` | the Pascal test generator (newest) |

### 1.3 The deliverable list

| # | Type | File | Status |
|:-:|------|--------|:----:|
| 1 | Pascal generator | `julia_abi_service_generator_tool.pas` | ✅ delivered |
| 2 | Pascal generator | `julia_abi_call_generator_tool.pas` | ✅ delivered |
| 3 | Pascal generator | `julia_abi_test_generator_tool.pas` | ✅ delivered |
| 4 | Pascal generator | `julia_abi_test_setup_generator_tool.pas` | ✅ delivered |
| 5 | C header | `c_ext/lf_shim.h` | ✅ modified |
| 6 | C source | `c_ext/lf_shim.c` | ✅ modified |
| 7 | C source | `c_ext/real/lf_real_link.c` | ✅ modified |
| 8 | C header | `c_ext/mock_lf.h` | ✅ modified |
| 9 | C source | `c_ext/mock_lf.c` | ✅ modified |
| 10 | Julia module | `julia/src/shim.jl` | ✅ rewritten |
| 11 | Julia module | `julia/src/callback.jl` | ✅ rewritten |
| 12 | Julia module | `julia/src/network.jl` | ✅ rewritten |

---

## 2. How the work was staged

```
Stage A (0.5 day) → Stage B (4 days) → Stage C (1.5 days)
  design and planning   4 generators delivered   base-library defect fixes
        ↓                     ↓                        ↓
  decision records      6 output templates       C shim extensions
  API memo              4 .pas files             3 Julia files
```

**Key milestones**:

| Milestone | Content | Status |
|:------:|------|:----:|
| M1 | the Julia generator design is final | ✅ |
| M2 | the service generator compiles | ✅ |
| M3 | the call generator compiles | ✅ |
| M4 | the test + setup generators compile | ✅ |
| M5 | the C shim supports sender identity | ✅ |
| M6 | task-local works in the Julia layer | ✅ |
| M7 | **the end-to-end test passes** (pending user verification) | ⏳ |

---

## 3. Stage A: design and planning

### 3.1 The key decision record

**Decision D1: API naming convention**

Use **Pascal-style suffixes** (`<ApiName>_UID_Call` and so on) rather than Julia-style prefixes (`uid_call_<api_snake>`).

**Rationale**:
- fully aligned with `pas_abi_call_generator_tool.pas`
- users already have a mental model from Pascal / C++ generated code
- lowers the learning cost for users moving across languages

**The affected API set** (9 per function type, 6 per procedure type):

| Function type | App name | UID | P2PName |
|---------|--------|-----|---------|
| Function | `<Api>` | `<Api>_UID_Call` | `<Api>_P2PName_Call` |
| Function | `<Api>_Async` | `<Api>_UID_Async` | `<Api>_P2PName_Async` |
| Function | `<Api>_AsyncSequenced` | `<Api>_UID_AsyncSequenced` | `<Api>_P2PName_AsyncSequenced` |
| Procedure | `<Api>` | `<Api>_UID_Notify` | `<Api>_P2PName_Notify` |
| Procedure | `<Api>_SequencedNotify` | `<Api>_UID_SequencedNotify` | `<Api>_P2PName_SequencedNotify` |

---

**Decision D2: how the `LingoFuse` dependency is loaded**

Use **`using LingoFuse` + `LOAD_PATH` or `Pkg.develop`**, and never copy the source into the output directory.

**Rationale**:
- semantically equivalent to C++'s `#include "LingoFuse.hpp"`
- generated code can upgrade the LingoFuse version independently
- no pollution of the output directory

---

**Decision D3: the sender identity of a service callback**

**The initial plan** (Stage A): accept the Julia limitation, emit `_lf_uid = zero_uid()` / `_lf_p2p = ""` in the generated code, and SKIP UID routing in tests.

**Stage C revision**: this turned out to be a **hard defect in the base library** and had to be fixed. The plan was to add a sender snapshot to the C shim and expose it in the Julia layer through `task_local_storage`.

---

**Decision D4: how the parameter reader is implemented**

Use a **custom `_ParamReader` + `_read_*_le!`** and do not depend on `IOBuffer`.

**Rationale**:
- `_ParamReader` allocates nothing and only reads a byte array
- semantically identical to `binio.jl`
- fully aligned with C++ `DataHandle::read<T>` / Pascal `LF_ReadInt32`

---

**Decision D5: the wire protocol**

**Follow the C++ / Pascal protocol strictly**:

```
request  = [param1][param2]...
response = [STATUS_OK | STATUS_ERROR][result or error message]

STATUS_OK    = 0x00
STATUS_ERROR = 0xFF

integers: little-endian byte order
strings:  UTF-8 + NUL terminator
Int128 / TDateTime: string form
```

---

**Decision D6: exception handling**

Define `EABI_RemoteError <: Exception`, semantically consistent with C++'s `EABI_RemoteError`.

- `LingoFuseTimeoutError` → `EABI_RemoteError("timed out: ...")`
- any other dispatch exception → `EABI_RemoteError("dispatch failed: ...")`
- `STATUS_ERROR` returned by the server → `EABI_RemoteError("failed: <error msg>")`

---

**Decision D7: the cleanup order**

**A key lesson** (from the user's reminder about Erlang):

`stop_callback_consumer()` internally calls `shim_shutdown()`, and the shim may still reference the main library. **The main library must be shut down before the shim.**

**The correct order**:

```julia
finally
    LF.exit_main_thread()
    LF.dispose!(app)
    LF.stop_callback_consumer()   # close the shim first
    LF.shutdown()                  # then close the main library
end
```

---

## 4. Stage B: the four Julia generators

### 4.1 `julia_abi_service_generator_tool.pas`

#### The generated file: `<Unit>_abi_service.jl`

**Structure**:

```
module <Unit>_abi_service

# 1. imports + constants
import LingoFuse
const LF = LingoFuse
const STATUS_OK    = UInt8(0x00)
const STATUS_ERROR = UInt8(0xFF)
const DEFAULT_APP_NAME = "<Unit>_abi"
const DEFAULT_APP_DESC = "ABI service for <Unit>"

# 2. wire helpers
mutable struct _ParamReader
    buf::Vector{UInt8}
    pos::Int
    _ParamReader(buf) = new(buf, 1)
end

function _read_uint8_le!(r::_ParamReader)::UInt8
    v = r.buf[r.pos]; r.pos += 1; return v
end

function _read_int32_le!(r::_ParamReader)::Int32
    # assemble the 4 bytes by hand (little-endian), no ltoh
    v = UInt32(r.buf[r.pos]) |
        (UInt32(r.buf[r.pos+1]) << 8) |
        (UInt32(r.buf[r.pos+2]) << 16) |
        (UInt32(r.buf[r.pos+3]) << 24)
    r.pos += 4
    return reinterpret(Int32, v)
end

# ... other types are similar ...

function _read_string_nul!(r::_ParamReader)::String
    start = r.pos
    while r.pos <= length(r.buf) && r.buf[r.pos] != 0x00
        r.pos += 1
    end
    s = String(r.buf[start:r.pos-1])
    r.pos += 1  # skip the NUL
    return s
end

# 3. the user implementation hook (returns a zero value by default)
const internal_call_<Api>_impl = Ref{Function}(function (_lf_uid, _lf_p2p, args...)
    return <default_value>
end)

function internal_call_<Api>(_lf_uid, _lf_p2p, args...)
    return internal_call_<Api>_impl[](_lf_uid, _lf_p2p, args...)
end

function set_internal_call_<Api>!(f::Function)
    internal_call_<Api>_impl[] = f
end

# 4. wire callbacks
function callback_<Api>(in_bytes::Vector{UInt8})::Vector{UInt8}
    out = IOBuffer()
    try
        r = _ParamReader(in_bytes)
        # read the parameters
        p1 = _read_int32_le!(r)
        p2 = _read_string_nul!(r)
        # call the user implementation
        _ret = internal_call_<Api>(_lf_uid, _lf_p2p, p1, p2)
        write(out, STATUS_OK)
        _write_int32_le!(out, _ret)
    catch e
        empty!(out)
        write(out, STATUS_ERROR)
        _write_string_nul!(out, _format_exception(e))
    end
    return take!(out)
end

# 5. registration
function register_all_abi_apis!(app::LF.App)
    LF.register_call!(app, "<Api>", "<desc>",
                      callback_<Api>; warmup=false)
end

function register_all_p2p_abi_apis!()
    LF.register_p2p_call!("<Api>", "<desc>",
                          callback_<Api>; warmup=false)
end

function create_and_register_abi_app()::LF.App
    app = LF.App(DEFAULT_APP_NAME, DEFAULT_APP_DESC)
    register_all_abi_apis!(app)
    return app
end

end  # module
```

**Key technical points**:

| # | Technical point | Notes |
|:-:|--------|------|
| 1 | `_ParamReader` reads byte by byte | no dependency on `ltoh`; byte-for-byte identical to the C++ / Pascal wire format |
| 2 | `_write_string_nul!` | UTF-8 + NUL, exactly like `LF_WriteString` |
| 3 | response framing `[STATUS][payload]` | consistent with the C++ `Safe_Write_*` |
| 4 | `warmup=false` | avoids three synthetic warmup calls triggering user side effects |
| 5 | `const LF = LingoFuse` | avoids symbol clashes with `notify` / `call` |

---

### 4.2 `julia_abi_call_generator_tool.pas`

#### The generated file: `<Unit>_abi_call.jl`

**Structure**:

```
module <Unit>_abi_call

import LingoFuse
const LF = LingoFuse
const ABI_TargetApp = Ref{String}("<Unit>_abi")
const ABI_Timeout   = Ref{Int}(5000)

# 1. exception type
struct EABI_RemoteError <: Exception
    msg::String
end
Base.showerror(io::IO, e::EABI_RemoteError) = print(io, "EABI_RemoteError: ", e.msg)

# 2. parameter reader (same as the service side)
mutable struct _ParamReader ...

# 3. response parser
function _check_response(res::Vector{UInt8}, api_name::String)::_ParamReader
    isempty(res) && throw(EABI_RemoteError("$api_name returned empty response"))
    status = res[1]
    if status != 0x00
        # extract the error message
        throw(EABI_RemoteError("$api_name failed: $err"))
    end
    r = _ParamReader(res)
    r.pos = 2
    return r
end

# 4. 9 call wrappers × N APIs

# 4.1 synchronous by app name
function <Api>(a::Integer, b::Integer)::Int32
    raw = LF.call(LF.app_target(ABI_TargetApp[]; timeout_ms=ABI_Timeout[]),
                  "<Api>",
                  (dh) -> begin
                      LF.write_int32!(dh, Int32(a))
                      LF.write_int32!(dh, Int32(b))
                  end)
    r = _check_response(raw, "<Api>")
    return _read_int32_le!(r)
end

# 4.2 asynchronous by app name
function <Api>_Async(a::Integer, b::Integer, cb::Function)::LF.Future
    inner_cb = function (res_bytes, err)
        if err !== nothing
            eabierr = EABI_RemoteError("$err")
            try cb(nothing, eabierr) catch; end
            return
        end
        try
            r = _check_response(res_bytes, "<Api>")
            parsed = _read_int32_le!(r)
            try cb(parsed, nothing) catch; end
        catch e
            try cb(nothing, e) catch; end
        end
    end
    return LF.async_call(inner_cb,
                         LF.app_target(ABI_TargetApp[]; timeout_ms=ABI_Timeout[]),
                         "<Api>",
                         (dh) -> begin
                             LF.write_int32!(dh, Int32(a))
                             LF.write_int32!(dh, Int32(b))
                         end)
end

# 4.3 synchronous by UID
function <Api>_UID_Call(__lf_uid::LF.LFShimUID, a::Integer, b::Integer)::Int32
    raw = LF.call(LF.uid_target(__lf_uid; timeout_ms=ABI_Timeout[]),
                  "<Api>",
                  (dh) -> ...)
    r = _check_response(raw, "<Api>")
    return _read_int32_le!(r)
end

# 4.4 synchronous by P2PName
function <Api>_P2PName_Call(__lf_p2p::AbstractString, a::Integer, b::Integer)::Int32
    raw = LF.call(LF.p2pname_target(__lf_p2p; timeout_ms=ABI_Timeout[]),
                  "<Api>",
                  (dh) -> ...)
    ...
end

# ... the remaining 5 ...

# 5. exports
export EABI_RemoteError, ABI_TargetApp, ABI_Timeout
export <Api>, <Api>_Async, <Api>_AsyncSequenced
export <Api>_UID_Call, <Api>_UID_Async, <Api>_UID_AsyncSequenced
export <Api>_P2PName_Call, <Api>_P2PName_Async, <Api>_P2PName_AsyncSequenced
```

**Key design points**:

| # | Design | Notes |
|:-:|------|------|
| 1 | parameter types widened to `Integer` / `Real` / `AbstractString` | users can just write `Add(5, 7)` |
| 2 | explicit internal conversion `Int32(a)` / `Float64(x)` | guarantees the correct wire type |
| 3 | framework-injected parameters named `__lf_uid` / `__lf_p2p` / `__lf_cb` | the double-underscore prefix avoids clashing with user parameters |
| 4 | `_check_response` handles both timeouts and errors | one unified exception path |
| 5 | the async `inner_cb` catches everything | stops a user callback exception from poisoning the framework thread |

---

### 4.3 `julia_abi_test_generator_tool.pas`

#### It generates 2 test files

**File 1: `<Unit>_abi_service_test.jl`** (a single-process self-loop test)

**Structure**:

```julia
if Threads.nthreads() < 2
    error("requires --threads=2")
end

import LingoFuse
const LF = LingoFuse

include("<Unit>_abi_service.jl")
include("<Unit>_abi_call.jl")

const APP_NAME = "<Unit>_abi"
const P2P_NAME = "<Unit>_service_test_p2p"
const IPC_ENDPOINT = "ipc:" * APP_NAME

# test harness
mutable struct TestContext
    pass::Int
    fail::Int
    skip::Int
    TestContext() = new(0, 0, 0)
end

function t_pass!(ctx, label)
    ctx.pass += 1
    println("[PASS] ", label)
end

function t_fail!(ctx, label, reason)
    ctx.fail += 1
    println("[FAIL] ", label, " -- ", reason)
end

function t_skip!(ctx, label, reason)
    ctx.skip += 1
    println("[SKIP] ", label, " -- ", reason)
end

# key: explicit lambdas (avoids the do-block argument-order trap)
function run_sync_test!(ctx, label, thunk::Function)
    try
        thunk()
        t_pass!(ctx, label)
    catch e
        t_fail!(ctx, label, string(e))
    end
end

function run_async_test!(ctx, label, launcher::Function)
    done = Base.Event()
    completed = Ref(false)
    err_ref = Ref{Any}(nothing)
    try
        launcher(function (r, e)
            completed[] = true
            err_ref[] = e
            Base.notify(done)
        end)
    catch e
        t_fail!(ctx, label, string(e))
        return
    end
    # 5-second timeout
    timer = Timer(5.0) do _
        Base.notify(done)
    end
    try
        wait(done)
    finally
        close(timer)
    end
    if !completed[]
        t_fail!(ctx, label, "timeout")
    elseif err_ref[] !== nothing
        t_fail!(ctx, label, string(err_ref[]))
    else
        t_pass!(ctx, label)
    end
end

# per-API tests
function test_<Api>!(ctx, service_uid)
    args = make_args_<Api>_for_call()
    # synchronous by app name
    run_sync_test!(ctx, "<Api>(app sync)", () -> begin
        <Unit>_abi_call.<Api>(args...)
    end)
    # asynchronous by app name
    run_async_test!(ctx, "<Api>(app async)", (cb) -> begin
        <Unit>_abi_call.<Api>_Async(args..., cb)
    end)
    # UID (SKIP if service_uid is unavailable)
    if service_uid === nothing
        t_skip!(ctx, "<Api>(uid sync)", "no service UID")
    else
        run_sync_test!(ctx, "<Api>(uid sync)", () -> begin
            <Unit>_abi_call.<Api>_UID_Call(service_uid, args...)
        end)
    end
    # P2PName
    run_sync_test!(ctx, "<Api>(p2pname sync)", () -> begin
        <Unit>_abi_call.<Api>_P2PName_Call(P2P_NAME, args...)
    end)
end

# main
function main()::Int
    if !LF.shim_available()
        println("[FATAL] shim not found")
        return 1
    end
    try
        LF.start_callback_consumer()
    catch e
        println("[FATAL] start_callback_consumer failed: ", e)
        return 1
    end
    app = nothing
    exit_code = 1
    try
        LF.set_option("Quiet", "True")
        LF.set_option("Overlap_Connection", "True")
        LF.reset_prepare()
        LF.prepare_service(IPC_ENDPOINT, IPC_ENDPOINT)
        app = <Unit>_abi_service.create_and_register_abi_app()
        LF.set_option("LF_P2P_name", P2P_NAME)
        <Unit>_abi_service.register_all_p2p_abi_apis!()
        LF.prepare_client(IPC_ENDPOINT, app)
        LF.prepare_done()
        
        # wait until the P2P name becomes visible (up to 30 seconds)
        deadline = time() + 30.0
        while time() < deadline
            LF.LF_Check_P2PNAME(P2P_NAME) != 0 && break
            sleep(0.5)
        end
        
        ctx = TestContext()
        test_<Api1>!(ctx, nothing)
        test_<Api2>!(ctx, nothing)
        # ...
        
        println("\n=== Summary ===")
        println("Pass: ", ctx.pass)
        println("Fail: ", ctx.fail)
        println("Skip: ", ctx.skip)
        
        exit_code = ctx.fail == 0 ? 0 : 2
    finally
        LF.exit_main_thread()
        app !== nothing && LF.dispose!(app)
        LF.stop_callback_consumer()  # mind the order!
        LF.shutdown()
    end
    return exit_code
end

exit(main())
```

**File 2: `<Unit>_abi_call_test.jl`** (a cross-process test)

**Structure** (simplified):

```julia
# similar to service_test, except that:
# - it does not include service.jl
# - it starts as a pure client
# - it polls check_api until the service is ready
# - the user must run service_test.jl in another terminal
```

---

### 4.4 `julia_abi_test_setup_generator_tool.pas`

#### It generates 2 files

**File 1: `Project.toml`**

```toml
name = "<Unit>_abi"
uuid = "<UUID v5 from MD5>"
version = "0.1.0"

[deps]
LingoFuse = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[targets]
test = ["Test"]
```

**UUID generation**: `MD5("lingofuse.abi." + UnitName)` takes the first 16 bytes and builds a UUID v5.

**File 2: `runtests.jl`**

```julia
if Threads.nthreads() < 2
    error("requires --threads=2")
end

using Test

const HERE = @__DIR__
const SERVICE_TEST = joinpath(HERE, "<Unit>_abi_service_test.jl")

@testset "<Unit>_abi integration" begin
    println("[TEST] spawning service_test subprocess: " * SERVICE_TEST)
    proc = run(`$(Base.julia_cmd()) --threads=2 $(SERVICE_TEST)`; wait=true)
    @test proc.exitcode == 0
end

if isfile(CALL_TEST)
    println("[INFO] cross-process verification:")
    println("[INFO]   terminal A: julia --threads=2 " * SERVICE_TEST)
    println("[INFO]   terminal B: julia --threads=2 " * CALL_TEST)
end
```

**Key design point**: **spawn a subprocess with `run()`, not `include()`**. The reason: `service_test.jl` ends with `exit(main())`, so `include()` would kill the whole runtests.jl process.

---

## 5. Stage C: fixing hard defects in the Julia base library

### 5.1 Hard defect #1: a Julia service handler cannot read the sender identity

#### Diagnosis

**The C ABI layer**:
```pascal
// lingofuse_import.pas
TLF_Call_Event = procedure(Trigger: Pointer; Input, Output: TDataHnd___); cdecl;
```

A C++ / Pascal handler receives the `Input` handle and can do:
```pascal
UIDPtr := LF_Get_P2P_UID(Input);
UID := UIDPtr^;
```

**The Julia layer**:
```julia
# callback.jl
function _dispatch_call(e::Ptr{Cvoid}, uid::Int64)
    handler = _lookup_handler(uid)
    in_bytes = _read_event_input(e)     # ← only bytes
    result = Base.invokelatest(handler, in_bytes)  # ← no access to the native handle
    ...
end
```

**Conclusion**: the handler signature of Julia's `register_call!` is `Function(Vector{UInt8}) -> Union{Vector{UInt8}, Nothing}`, so it **only receives a byte array** and **cannot reach the native `TDataHnd`**.

**Impact**:
- the C++ / Pascal `whoami` pattern (reading the sender UID inside the handler) **cannot be implemented in Julia**
- a pure-Julia test **cannot obtain its own (client) UID** → the UID routing test **can only be SKIPped**
- cross-language interoperability is **therefore incomplete** (a Julia server cannot answer identity queries)

#### The fix (task-local storage)

**Comparing the options**:

| Option | Pros | Cons | Decision |
|------|------|------|:----:|
| A. change the handler signature | intuitive | breaks every existing handler | ❌ |
| B. global variables | simple | not thread-safe | ❌ |
| **C. task-local storage** | non-invasive, thread-safe | Julia-specific | ✅ |
| D. `jl_adopt_thread` | lets foreign threads enter Julia | internal API, unstable | ❌ |

#### The fix across 3 layers

##### Layer 1: the C shim (`lf_shim.h` + `lf_shim.c`)

**What changed**:

1. **Two new accessor declarations**:

```c
LF_SHIM_API const uint8_t* lf_shim_event_from_uid(const lf_shim_event_t* e);
LF_SHIM_API const char*    lf_shim_event_from_p2p_name(const lf_shim_event_t* e);
```

2. **Two new fields on `struct lf_shim_event`**:

```c
uint8_t  from_uid[32];
char*    from_p2p_name;
```

3. **`event_free` frees them**:

```c
if (e->from_p2p_name) free(e->from_p2p_name);
```

4. **A new `snapshot_sender` helper**:

```c
static void snapshot_sender(lf_shim_event_t* e, void* input_hnd)
{
    if (!e || !input_hnd) return;
    
    // the pointer LF_Get_P2P_UID returns is freed by the Pascal side after 5 seconds
    // the shim memcpy's immediately and never holds the pointer
    lf_shim_uid_t* uid_ptr = LF_Get_P2P_UID(input_hnd);
    if (uid_ptr) {
        memcpy(e->from_uid, uid_ptr->bytes, 32);
    }
    
    // the string LF_Get_P2P_Name returns is likewise freed after 5 seconds
    const char* name_ptr = LF_Get_P2P_Name(input_hnd);
    if (name_ptr && name_ptr[0] != '\0') {
        size_t n = strlen(name_ptr);
        e->from_p2p_name = (char*)malloc(n + 1);
        if (e->from_p2p_name) {
            memcpy(e->from_p2p_name, name_ptr, n + 1);
        }
    }
}
```

5. **`shim_call_trampoline` and `shim_notify_trampoline` call `snapshot_sender`**:

```c
// shim_call_trampoline
snapshot_input(e);
snapshot_sender(e, input);   // ← new
queue_push(e);

// shim_notify_trampoline
snapshot_input(e);
snapshot_sender(e, input);   // ← new
queue_push(e);
```

**⚠️ Note**: `shim_async_result_trampoline` and `shim_network_*_trampoline` **do not snapshot** — their `result` / `addr` are not input handles, so calling `LF_Get_P2P_UID(result)` triggers a warning on the Pascal side and returns a zero UID, which is meaningless.

6. **Two new accessor implementations**:

```c
LF_SHIM_API const uint8_t* lf_shim_event_from_uid(const lf_shim_event_t* e)
{
    return e ? e->from_uid : NULL;
}

LF_SHIM_API const char* lf_shim_event_from_p2p_name(const lf_shim_event_t* e)
{
    return e ? e->from_p2p_name : NULL;
}
```

##### Layer 2: `lf_real_link.c`

Add 2 function-pointer typedefs, 2 RESOLVEs and 2 forwarders:

```c
typedef lf_shim_uid_t* (*fn_Get_P2P_UID)(void*);
typedef const char*    (*fn_Get_P2P_Name)(void*);

// inside ensure_api()
RESOLVE(Get_P2P_UID,  "LF_Get_P2P_UID");
RESOLVE(Get_P2P_Name, "LF_Get_P2P_Name");

// the new forwarders
lf_shim_uid_t* LF_Get_P2P_UID(void* hnd)
{
    if (!ensure_api() || hnd == NULL) return NULL;
    return g_api.Get_P2P_UID(hnd);
}

const char* LF_Get_P2P_Name(void* hnd)
{
    if (!ensure_api() || hnd == NULL) return NULL;
    return g_api.Get_P2P_Name(hnd);
}
```

##### Layer 3: `mock_lf.c/h`

**New declarations in mock_lf.h**:

```c
MOCK_LF_API lf_shim_uid_t* LF_Get_P2P_UID(void* hnd);
MOCK_LF_API const char*    LF_Get_P2P_Name(void* hnd);
```

**New implementations in mock_lf.c**:

```c
static lf_shim_uid_t g_mock_sender_uid = {
    { 0xAB, 0xAB, ... 32 x 0xAB ... }
};

lf_shim_uid_t* LF_Get_P2P_UID(void* hnd)
{
    (void)hnd;
    return &g_mock_sender_uid;
}

const char* LF_Get_P2P_Name(void* hnd)
{
    (void)hnd;
    return "__mock_sender_p2p__";
}
```

**🟢 On the semantic difference**:

- **the real Pascal library**: returns a pointer newly allocated with `New`, freed by `DelayFreeMem` after 5 seconds
- **the mock library**: returns a static pointer that never expires
- **impact on the shim**: none. The shim **memcpy's immediately** inside `snapshot_sender` and **never holds the pointer**, so both semantics are safe

### 5.2 Hard defect #2: `network.jl` lacks `check_*` high-level wrappers

#### Diagnosis

`abi.jl` has low-level functions such as `LF_Check_UID` / `LF_Check_P2PNAME`, but `network.jl` has no corresponding `check_uid` / `check_p2pname` high-level wrappers.

**Impact**:
- test code has to call `LF.LF_Check_P2PNAME(...)` (a low-level ccall), which violates the "high-level wrapper" principle
- it is inconsistent with the binding style of the other languages

#### The fix

`network.jl` gains 4 functions:

```julia
function check_uid(uid::NTuple{32, UInt8})::Bool
    return LF_Check_UID(uid) != 0
end

function check_uid_api(uid::NTuple{32, UInt8}, api_name::AbstractString)::Bool
    return LF_Check_UID_Api(uid, api_name) != 0
end

function check_p2pname(p2p_name::AbstractString)::Bool
    return LF_Check_P2PNAME(p2p_name) != 0
end

function check_p2pname_api(p2p_name::AbstractString, api_name::AbstractString)::Bool
    return LF_Check_P2PNAME_Api(p2p_name, api_name) != 0
end
```

### 5.3 A full rewrite of the 3 Julia files

#### 5.3.1 `shim.jl`

**Two new functions**:

```julia
function shim_read_from_uid(e::Ptr{Cvoid})::NTuple{32, UInt8}
    p = ccall((:lf_shim_event_from_uid, LINGOFUSE_SHIM_PATH),
              Ptr{UInt8}, (Ptr{Cvoid},), e)
    p == C_NULL && return ntuple(_ -> UInt8(0), 32)
    return ntuple(i -> unsafe_load(p, i), 32)
end

function shim_read_from_p2p_name(e::Ptr{Cvoid})::String
    p = ccall((:lf_shim_event_from_p2p_name, LINGOFUSE_SHIM_PATH),
              Ptr{UInt8}, (Ptr{Cvoid},), e)
    p == C_NULL && return ""
    return unsafe_string(p)
end
```

**⚠️ Change of decision**: **do not add try-catch**. The reasons:
- the C shim has been upgraded, so the symbols necessarily exist
- if a user runs an old shim they get a clear `could not load symbol` error
- that is better than silently returning a zero UID (and matches the requirement that "a found problem must not be hidden")

**Add these 2 names to the `export` list**.

#### 5.3.2 `callback.jl`

**Modify `_dispatch_call` and `_dispatch_notify`**:

```julia
function _dispatch_call(e::Ptr{Cvoid}, uid::Int64)
    trace("callback: dispatch CALL uid=$(uid)")
    handler = _lookup_handler(uid)
    if handler === nothing
        return nothing
    end
    
    in_bytes = _read_event_input(e)
    from_uid = shim_read_from_uid(e)         # ← new
    from_p2p = shim_read_from_p2p_name(e)    # ← new
    task_local_storage(:lf_current_uid, from_uid)       # ← new
    task_local_storage(:lf_current_p2p_name, from_p2p)  # ← new
    
    result = Base.invokelatest(handler, in_bytes)
    ...
end

function _dispatch_notify(e::Ptr{Cvoid}, uid::Int64)
    # the same 4 new lines
end
```

**Two new public APIs**:

```julia
function current_input_uid()::Union{Nothing, NTuple{32, UInt8}}
    tls = task_local_storage()
    haskey(tls, :lf_current_uid) || return nothing
    return tls[:lf_current_uid]::NTuple{32, UInt8}
end

function current_input_p2p_name()::Union{Nothing, String}
    tls = task_local_storage()
    haskey(tls, :lf_current_p2p_name) || return nothing
    return tls[:lf_current_p2p_name]::String
end
```

**Add these 2 names to the `export` list**.

#### 5.3.3 `network.jl`

Append the 4 `check_*` functions (see §5.2).

---

## 6. Key design trade-offs

### 6.1 Why not `import LingoFuse: notify, call`

**The problem**: if you write `import LingoFuse: notify`, then when the generated call module defines `<Api>_Notify`, the name `notify` is occupied by `LingoFuse.notify`, and a call may be shadowed by your own symbol.

**The approach**: use `import LingoFuse` + `const LF = LingoFuse`. Every `LingoFuse` symbol is explicitly qualified as `LF.notify(...)`.

**Advantages**:
- no risk of symbol shadowing
- users can tell "framework functions" from "generated APIs" at a glance
- consistent with Python's `import lingofuse as lf` style

### 6.2 Why `warmup=false`

**The warmup behaviour of `LingoFuse.register_call!`**:

```julia
if warmup
    _warmup_handler(handler)
end
```

`_warmup_handler` **calls the handler three times** with 3 synthetic payloads (empty, 2 bytes, 256 bytes) to trigger JIT compilation.

**The problem**: if the handler has side effects (logging, changing state, calling APIs), warmup **triggers those side effects 3 times**.

**The approach**: every `register_*!` in the generated code passes `warmup=false` explicitly.

### 6.3 Why `task_local_storage` instead of global variables

| Option | Thread-safe | Julia support | Decision |
|------|:--------:|:----------:|:----:|
| global variables | ❌ | ✅ | ❌ |
| `task_local_storage` | ✅ | ✅ | ✅ |
| `Threads.thread_local` | ✅ | ❌ not supported | ❌ |

`task_local_storage` is Julia's standard task-scoped storage: non-invasive and thread-safe.

**Known limitation**: **it is not inherited by child tasks**. If the handler does `Threads.@spawn`, then `current_input_uid()` returns `nothing` inside the child task. That is standard Julia task-local semantics, not a bug.

### 6.4 Why drive the tests with `run()` rather than `include()`

`service_test.jl` ends with `exit(main())`. If `runtests.jl` used `include("service_test.jl")`, it would **kill the entire runtests.jl process**.

**The approach**: spawn a child process with `run(\`julia --threads=2 $(SERVICE_TEST)\`; wait=true)` and check `proc.exitcode == 0`.

### 6.5 Why the sender snapshot happens in the trampoline and not the consumer

**The key reason**: the consumer **never touches a native handle** (see `SHIM_MECHANISM_GUIDE.md` §4.5).

- if the consumer called `LF_Get_P2P_UID(input)`, it would **enter the real LingoFuse library from the consumer thread**, operating on the handle **from the wrong thread**, causing a **deadlock** or a crash
- the correct approach: the trampoline snapshots on the C4 worker thread, and the consumer only reads the snapshot copy

---

## 7. Problems found and correction history

### 7.1 Problems during generator implementation

| # | Problem | Correction |
|:-:|------|------|
| 1 | `AppendParamSuffix` was undefined | switched to `_join_params` |
| 2 | `EmitSyncWrapper`'s `FuncDecl` parameter was a "half signature" | unified into `FuncName` + `FullParams` |
| 3 | the call generator lacked an `initialization` section | added `RegisterGenerator(...)` |
| 4 | the framework-injected parameter `uid` could be shadowed by a user parameter | renamed to `__lf_uid` / `__lf_p2p` / `__lf_cb` |
| 5 | the call generator emitted redundant `_write_*` | removed; the write side uniformly uses `LingoFuse.write_*!` |

### 7.2 Problems found in the base library

| # | Problem | Severity | Fix |
|:-:|------|:--------:|------|
| 1 | **a Julia service handler cannot read the sender identity** | 🔴 fatal | the C shim + `task_local_storage` fix |
| 2 | `network.jl` lacks `check_*` wrappers | 🟡 ordinary | added 4 functions |
| 3 | the test generator's cleanup order was wrong (`shutdown` before `stop_callback_consumer`) | 🟠 serious | changed to `stop_callback_consumer` → `shutdown` |
| 4 | the test generator used do-blocks, which put the arguments in the wrong order | 🟠 serious | changed to explicit lambdas |
| 5 | the service / call generator module names clashed (both were `<Unit>_abi`) | 🔴 fatal | `_abi_service` / `_abi_call` |

### 7.3 A user correction (kept)

The user made 4 corrections in `julia_abi_service_generator_tool.pas`:

```pascal
callback_' + ApiNames[i] + '; warmup=false'
↓
callback_' + ApiNames[i].Text + '; warmup=false'
```

**These 4 corrections are right** — `Lines.Add()` accepts a `string`, and `TPascalString`'s implicit conversion can be unstable inside long concatenation chains. The user has already fixed them, and the service generator adopts the user's version as-is.

---

## 8. The verification checklist

### 8.1 Verifying the C-layer changes

#### V1: rebuild the shim

```powershell
cd D:\CoreLibrary\LingoFuse\julia\c_ext
.\build.ps1

cd real
.\build.ps1
```

**PASS**: two `==> Done: ...` lines, no gcc errors.

#### V2: verify the new symbols are exported

```powershell
& "D:\mingw64\bin\objdump.exe" -T .\lf_shim_mock.dll |
    Select-String "lf_shim_event_from_uid|lf_shim_event_from_p2p_name"
```

**PASS**: 2 lines of output.

#### V3: regress the old tests

```powershell
julia --threads=2 test_shim.jl
```

**PASS**: `main: DONE  checks_passed=11  checks_failed=0`

### 8.2 Verifying that task-local works

**The temporary script `verify_sender.jl`**:

```julia
using LingoFuse
LingoFuse.start_callback_consumer()
try
    app = LingoFuse.App("verify_sender", "verify")
    got_uid = Ref{Union{Nothing,NTuple{32,UInt8}}}(nothing)
    got_p2p = Ref{Union{Nothing,String}}(nothing)
    LingoFuse.register_call!(app, "echo", "echo",
        function (in_bytes)
            got_uid[] = LingoFuse.current_input_uid()
            got_p2p[] = LingoFuse.current_input_p2p_name()
            return in_bytes
        end; warmup=false)
    LingoFuse.reset_prepare()
    LingoFuse.prepare_service("ipc:verify_sender", "ipc:verify_sender")
    LingoFuse.prepare_client("ipc:verify_sender", app)
    LingoFuse.prepare_done()
    LingoFuse.call(LingoFuse.app_target("verify_sender"), "echo", UInt8[1,2,3])
    println("uid = ", got_uid[])
    println("p2p = ", got_p2p[])
finally
    LingoFuse.exit_main_thread()
    LingoFuse.stop_callback_consumer()
    LingoFuse.shutdown()
end
```

**PASS**:
- with the mock shim → `uid` is 32 `0xAB` bytes and `p2p` is `"__mock_sender_p2p__"`
- with the real shim → `uid` is the real UID and `p2p` is the real P2P name

### 8.3 Verifying the end-to-end test (for the user to run)

#### V4: generate the Julia output

```powershell
code_decl_to_abi --lang julia ComplexTestUnit.pas output_julia/
```

**PASS**: 6 files under `output_julia/`:

```
ComplexTestUnit_abi_service.jl
ComplexTestUnit_abi_call.jl
ComplexTestUnit_abi_service_test.jl
ComplexTestUnit_abi_call_test.jl
Project.toml
runtests.jl
```

#### V5: run the tests

```powershell
cd output_julia
julia --project=. -e 'using Pkg; Pkg.develop(path="D:/CoreLibrary/LingoFuse/julia")'
julia --project=. --threads=2 runtests.jl
```

**PASS**:
- `@test proc.exitcode == 0`
- `service_test.jl` prints `[PASS]` / `[SKIP]` lines
- the summary shows `Fail: 0`

---

## 9. Open issues and next steps

### 9.1 The 4-line change to the service generator (next step)

The `internal_call_*` signature in the service generator is currently:

```julia
function internal_call_<Api>(p1, p2, ...)
```

It needs to become:

```julia
function internal_call_<Api>(_lf_uid::NTuple{32, UInt8},
                              _lf_p2p_name::String,
                              p1, p2, ...)
```

and `callback_<Api>` needs to fill them in:

```julia
function callback_<Api>(in_bytes::Vector{UInt8})::Vector{UInt8}
    out = IOBuffer()
    try
        r = _ParamReader(in_bytes)
        p1 = _read_int32_le!(r)
        p2 = _read_string_nul!(r)
        
        # ← new
        _lf_uid = LF.current_input_uid()
        _lf_uid === nothing && (_lf_uid = zero_uid())
        _lf_p2p = LF.current_input_p2p_name()
        _lf_p2p === nothing && (_lf_p2p = "")
        
        _ret = internal_call_<Api>(_lf_uid, _lf_p2p, p1, p2)
        ...
```

### 9.2 Changes to the test generator (next step)

1. **Remove the UID SKIP**: change "no service UID" into a real test of UID routing
2. **Generate a `whoami` API**: the service side registers a `whoami` API and the test side obtains `service_uid` through it

### 9.3 Full verification of cross-language interoperability

**The goal**: take one `.pas` source file, generate a Pascal service + a Julia call, and a Julia service + a Pascal call, and have them **call each other in both directions**.

**The verification path**:

```
Terminal 1: Pascal service_test (generated by code_decl_to_abi --lang pascal)
Terminal 2: Julia call_test (generated by code_decl_to_abi --lang julia)
→ the Julia client calls the Pascal service → verify the wire protocol matches
→ the Pascal service calls the Julia client back → verify UID routing
```

### 9.4 Scenarios `LingoFuse.jl` does not yet cover

| Scenario | Current state | Follow-up |
|------|:----:|------|
| availability of `AsyncResult::handle()` | Julia's `async_call` callback does not expose the handle directly | leave as is (`cb(result_bytes, err)` already copies) |
| `is_abandoned` on `LingoFuseTimeoutError` | the user can check after `fetch(fut)` | leave as is |
| the lifetime of `addr` in network-event callbacks | `addr` is a `String` (already copied) | safe |

---

## 10. An honest list of uncertainties

What follows are points that **cannot be fully determined from the source / documentation**. If an AI has to work in these areas, it **must go back to the source or ask a human**.

### 10.1 Compiling the C-layer changes

**Not verified**: the 5 C-file changes I gave were **assembled point by point from the source structure the user provided**, but **I did not actually compile them in a gcc environment**.

**Risks**:
- type mismatches (for example `lf_shim_uid_t*` vs `PP2P_UID___`)
- symbols not exported (if `LF_Get_P2P_UID` in `LingoFuse64.dll` had C++ name mangling — but it is a Pascal cdecl export, so it should be fine)
- memory-layout differences (`lf_shim_uid_t` and `TP2P_UID___` are both 32 contiguous bytes, so they should agree)

**Recommendation**: the user verifies per §8.1. If gcc reports any error, paste the full stderr.

### 10.2 The 5-second delayed free of `LF_Get_P2P_UID`

The Pascal-side source:

```pascal
function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
begin
  New(Result);
  if (Hnd <> nil) and (PLF_Data(Hnd)^.Data_Param <> nil) then
    Result^ := PLF_Data(Hnd)^.Get_P2P_UID()
  else
    Result^ := Null_UID();
  DelayFreeMem(5.0, Result);   // ← freed after 5 seconds
end;
```

**Confirmed**: the pointer is freed after 5 seconds. The shim **memcpy's the 32 bytes immediately** inside `snapshot_sender` and **never holds the pointer**. **Safe.**

**Not confirmed**: when several threads call concurrently, is each pointer freed independently after its own delay? Presumably yes (the `DelayFreeMem` mechanism).

### 10.3 The cross-thread semantics of `task_local_storage`

**Confirmed**: `task_local_storage` is **task-scoped**, not thread-scoped.

**Not confirmed**: setting it in the consumer task and reading it in the handler within the same task is **safe**. But a child task spawned with `Threads.@spawn` inside the handler **cannot see it** (Julia semantics). **That is by design, not a bug**.

### 10.4 The `showerror` format of `EABI_RemoteError`

Currently:

```julia
Base.showerror(io::IO, e::EABI_RemoteError) = print(io, "EABI_RemoteError: ", e.msg)
```

**Not confirmed**: does it have to match C++'s `EABI_RemoteError` `what()` format exactly? The user can compare in a test; if it differs, change this spot.

### 10.5 When the `whoami` API is generated

**Currently**: the service generator **does not generate** a `whoami` API.

**Next step**: should the `whoami` API (used by tests to obtain `service_uid`) be generated mandatorily? My suggestion is **an optional switch** (`Generate_WhoAmI_API = True/False`).

### 10.6 The default arguments of `App`

In `LingoFuse.App("name")` the `desc` defaults to `""`. C++'s `App app("name")` behaves the same. **Confirmed consistent.**

### 10.7 The timeout behaviour of `LF_PrepareDone`

**Confirmed** (from the Pascal guide v7.0): the internal timeout of `prepare_done` is `max(Wait_Connection_Timeout, 5000) + 1000` milliseconds. **On timeout it still returns 1**.

**Impact**: the `prepare_done() != 1` check in the generated test code **does not catch a timeout** — you need `check_api` polling as a backstop.

### 10.8 The cache delay of `LF_Check_P2PNAME`

**Confirmed** (from the Pascal guide v7.0): the broadcast cache delay is about 3 seconds.

**Impact**: the 30-second polling of `LF_Check_P2PNAME` in service_test is **sufficient**, but **the first round may see nothing** — hence the `while time() < deadline` loop.

---

## Appendix A: the file list

### A.1 The Pascal generators (in the `code_decl_to_abi` project)

| File | Lines (est.) | Notes |
|------|:----------:|------|
| `julia_abi_service_generator_tool.pas` | ~700 | the service generator |
| `julia_abi_call_generator_tool.pas` | ~900 | the call generator |
| `julia_abi_test_generator_tool.pas` | ~900 | the test generator |
| `julia_abi_test_setup_generator_tool.pas` | ~300 | the Project + runtests generator |

### A.2 The C shim changes

| File | Change type | Notes |
|------|:--------:|------|
| `c_ext/lf_shim.h` | 2 new function declarations | the `from_uid` / `from_p2p_name` accessors |
| `c_ext/lf_shim.c` | new snapshot logic | the `snapshot_sender` helper + 2 accessor implementations |
| `c_ext/real/lf_real_link.c` | 2 new forwarders | `LF_Get_P2P_UID` / `LF_Get_P2P_Name` |
| `c_ext/mock_lf.h` | 2 new function declarations | mock versions of `LF_Get_P2P_UID` / `LF_Get_P2P_Name` |
| `c_ext/mock_lf.c` | 2 new function implementations | return a fixed mock UID + P2P name |

### A.3 The Julia library changes

| File | Change type | Notes |
|------|:--------:|------|
| `julia/src/shim.jl` | 2 new functions | `shim_read_from_uid` / `shim_read_from_p2p_name` |
| `julia/src/callback.jl` | new task-local logic | `_dispatch_call` / `_dispatch_notify` gain 4 lines each + 2 public APIs |
| `julia/src/network.jl` | 4 new functions | `check_uid` / `check_uid_api` / `check_p2pname` / `check_p2pname_api` |

---

## Appendix B: the critical alignment points for cross-language interoperability

These 6 points **must match exactly**, otherwise the generated code cannot interoperate:

| # | Alignment point | Julia | C++ | Pascal |
|:-:|--------|-----------|----------|-------------|
| 1 | **string framing** | `write_string!` (UTF-8 + NUL) | `io::write_string` (UTF-8 + NUL) | `LF_WriteString` (UTF-8 + NUL) |
| 2 | **integer byte order** | assembled byte by byte, little-endian | `Move` (relies on the platform being little-endian) | `Move` (relies on the platform being little-endian) |
| 3 | **response framing** | `[STATUS][payload]` | `[STATUS][payload]` | `[STATUS][payload]` |
| 4 | **the `STATUS_OK` value** | `UInt8(0x00)` | `0x00` | `$00` |
| 5 | **the `STATUS_ERROR` value** | `UInt8(0xFF)` | `0xFF` | `$FF` |
| 6 | **error-message encoding** | `_write_string_nul!` (UTF-8 + NUL) | `write_string` | `LF_WriteString` |

**⚠️ Special note**: Julia's `write_string!` writes `codeunits(s) + 0x00` directly, **with no code-page conversion**. C++'s `io::write_string` writes the `std::string` (already UTF-8) + `0x00` directly. Pascal's `LF_WriteString` first does `TEncoding.UTF8.GetBytes`, then writes + `0x00`. **All three are byte-for-byte identical.**

---

## Appendix C: a summary of the working principles

This work followed the following principles throughout (explicitly requested by the user):

1. **A problem found must be raised explicitly**: never hide a base-library bug
2. **Always work honestly**: never conceal "I did not verify this" or "I never compiled it"
3. **Check, analyse and think repeatedly**: re-examine the existing problems with every change
4. **Stop and fix immediately upon finding a problem**: never carry on with a bug
5. **Never hide problems**: honestly report the 3 remaining risks and the 8 uncertain items
6. **Be careful with the test code**: borrow the C++ / Pascal test patterns; use explicit lambdas to avoid the do-block argument trap

**Special thanks to the user for a critical reminder**:

> "Be careful with the test, because an Erlang test once missed bringing in the child thread in the main loop, and it took days of debugging to find the problem"

That reminder directly led me to:
- add a hard `Threads.nthreads() < 2` check at the top of service_test
- add a `CONSUMER_TID[] == 1` check inside `start_callback_consumer`
- use `stop_callback_consumer` before `shutdown` in the cleanup order

---

**End of document.**
