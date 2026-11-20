# LingoFuse Zig binding

> Chinese version: [README.md](README.md)

> **The official Zig binding, with a wire format that is byte-for-byte compatible with the Pascal / C++ / C# / Rust / Go / Python / JavaScript implementations.**
>
> Version: v1.1 (stages 1–7 plus the v0.4 incremental upgrade: UID type, P2P identity, typed options, process-level P2P registration, the async call family)
> Native library: LingoFuse v3.10 / C4 v4.01
> Target Zig version: 0.17.0

---

## Contents

1. [Project structure](#1-project-structure)
2. [Setting up the environment](#2-setting-up-the-environment)
3. [Compiler version requirements](#3-compiler-version-requirements)
4. [The verified environment](#4-the-verified-environment)
5. [Confirming the code in the c directory](#5-confirming-the-code-in-the-c-directory)
6. [Confirming the compilers](#6-confirming-the-compilers)
7. [Testing](#7-testing)
8. [The Cross Demo trio](#8-the-cross-demo-trio)
9. [A tour of the new v0.4 capabilities](#9-a-tour-of-the-new-v04-capabilities)
10. [Using typed options from C#](#10-using-typed-options-from-c)
11. [Troubleshooting](#11-troubleshooting)
12. [Known limitations](#12-known-limitations)

---

## 1. Project structure

```
zig/
├── build.zig                    # build script
├── build.zig.zon                # package description
├── build.ps1                    # one-key build
├── test.ps1                     # one-key test
├── clean.ps1                    # one-key clean
├── README.md                    # this file
│
├── c/                           # C / C++ dependencies
│   ├── LingoFuse.h              # LingoFuse C ABI header
│   ├── LingoFuse.c              # LingoFuse dynamic loader
│   ├── LingoFuse_Opt.h          # (new in v0.4) the C wrapper layer for typed set_opt_* / get_opt_*
│   ├── lf_json.h                # the C ABI header for nlohmann/json
│   ├── lf_json.cpp              # the C ABI implementation of nlohmann/json
│   └── json.hpp                 # nlohmann/json single-file build (external dependency)
│
├── src/                         # the binding source
│   ├── lingofuse.zig            # module root: top-level re-exports
│   ├── sys.zig                  # hand-written extern declarations for 59 C ABI functions
│   ├── error.zig                # the error set
│   ├── util.zig                 # (new in v0.4) shared helpers (dupeZ / copyCstr)
│   ├── uid.zig                  # (new in v0.4) the 32-byte UID value type
│   ├── data_handle.zig          # RAII data handle (including P2P identity accessors)
│   ├── app_handle.zig           # RAII app handle + callback trampoline
│   ├── framework.zig            # the process-level facade (three addressing schemes)
│   ├── io.zig                   # unified JSON / string / byte I/O
│   ├── json_c.zig               # extern declarations for the lf_json C ABI
│   ├── network_events.zig       # process-level network events
│   ├── status.zig               # the status queue
│   ├── options.zig              # (new in v0.4) typed options
│   ├── p2p.zig                  # (new in v0.4) process-level P2P registration
│   └── async_call.zig           # (new in v0.4) modern async calls
│
├── examples/                    # executable examples / tests
│   ├── abi_smoke.zig            # ABI smoke test (35 steps)
│   ├── io_smoke.zig             # unified I/O smoke test (18 steps)
│   ├── json_smoke.zig           # lf_json C ABI smoke test (43 steps)
│   ├── network_events_smoke.zig # network-events smoke test (6 steps)
│   ├── status_smoke.zig         # status-queue smoke test (5 steps)
│   ├── uid_smoke.zig            # (v0.4) UID value-type smoke test (10 steps)
│   ├── identity_smoke.zig       # (v0.4) P2P identity side-data smoke test (2 steps)
│   ├── options_smoke.zig        # (v0.4) typed-options smoke test (9 steps)
│   ├── async_smoke.zig          # (v0.4) async call family smoke test (6 steps)
│   ├── p2p_smoke.zig            # (v0.4) process-level P2P registration smoke test (6 steps)
│   ├── addressing_smoke.zig     # (v0.4) three addressing schemes smoke test (7 steps)
│   ├── cross_service.zig        # Cross Demo coordinator
│   ├── cross_node.zig           # Cross Demo worker node
│   └── cross_call.zig           # Cross Demo load client
│
└── tests/
    └── test_abi.zig             # Zig-native unit tests (pure logic only, about 24 `test` blocks)
```

**The layering principle**:

```
application layer   user code
                    ↓ import "lingofuse"
high-level wrappers io / network_events / status / options / p2p / async_call
                    framework / app_handle / data_handle
                    ↓
type layer          Uid / Error / util
                    ↓
FFI layer           sys (the only module that calls the native library directly) / json_c
                    ↓
native library      LingoFuse64.dll (+ z_ipc_64.dll) / lf_json (statically linked into the exe)
```

---

## 2. Setting up the environment

### 2.1 Getting the source

```powershell
git clone https://github.com/PassByYou888/LingoFuse.git
cd LingoFuse\zig
```

### 2.2 Getting `json.hpp`

This project does not bundle the nlohmann/json single-file build; download it yourself:

1. open https://github.com/nlohmann/json/releases
2. download `json.hpp` from the latest release (about 900 KB)
3. put it at `zig/c/json.hpp`

**Version requirement**: 3.11 or newer (this project is verified on 3.12.0).

### 2.3 Getting the native library

You need the following files (matching the `Binary/` directory of the main LingoFuse repository):

| Platform | Main library | IPC dependency |
|------|------|----------|
| Windows 64-bit | `LingoFuse64.dll` | `z_ipc_64.dll` |
| Windows 32-bit | `LingoFuse32.dll` | `z_ipc_32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` |

**Where to put them** (following the loader's search order):

1. the directory of the executable (`zig-out\bin\`)
2. the system `PATH` (Windows) / `LD_LIBRARY_PATH` (Linux) / `DYLD_LIBRARY_PATH` (macOS)

**The least-effort approach**: add the `LingoFuse\Binary\` directory to the system `PATH`:

```powershell
# Windows PowerShell (valid for the current session only)
$env:PATH = "D:\CoreLibrary\LingoFuse\Binary;$env:PATH"
```

### 2.4 Installing Zig

See section 3.

### 2.5 One-key verification

```powershell
cd D:\CoreLibrary\LingoFuse\zig
.\build.ps1        # build every artifact
.\test.ps1         # run every test suite
```

If `build.ps1` prints `Build succeeded.` and `test.ps1` prints `RESULT: ALL SUITES PASSED`, the environment is ready.

---

## 3. Compiler version requirements

| Component | Minimum | Recommended | Notes |
|------|:--------:|:--------:|------|
| **Zig** | 0.17.0 | 0.17.0 | see the note below |
| C compiler | any | MinGW-w64 / MSVC 2019+ | Zig's built-in `zig cc` is sufficient |
| C++ compiler | C++17 support | any | same as above |
| nlohmann/json | 3.11.0 | 3.12.0 | the single-file build |
| PowerShell | 5.1 | 7.x | scripts only |
| Operating system | Windows 10 x64 | Windows 10/11 x64 | Linux/macOS not yet verified |

### 3.1 Why Zig is pinned to 0.17.0

During development this project found that **Zig 0.17 introduced several breaking API changes** that are incompatible with older versions:

| Change | Impact | How this binding copes |
|------|------|-----------|
| `@cImport` removed | `extern fn` must be written by hand | the 59 declarations in `src/sys.zig` |
| `std.meta.fields` removed | reflecting on struct fields must probe the actual layout via `@typeInfo(T).@"struct"` | `serializeJson` in `src/io.zig` |
| `std.mem.Allocator.dupeZ` removed | use a local `dupeZ` helper | `dupeZ` in `src/util.zig` |
| `std.time.Timer` / `milliTimestamp` removed | use the C / Windows API | `src/async_call.zig` uses `GetTickCount64` |
| `std.Thread.sleep` removed | use the Windows `Sleep(ms)` | `src/async_call.zig` + `cross_call.zig` |
| `std.json.parseFromSlice` aliases its input by default | must pass `.allocate = .alloc_always` explicitly | `readJson` / `loadsJson` in `src/io.zig` |
| `std.ArrayListUnmanaged` gained a new field | cannot be initialised with `.{ }` | the project does not use ArrayList |
| the signature of a custom `format` method changed | `std.fmt` no longer recognises the old signature | no custom `format`; explicit helpers such as `toHexBuf` |
| **the `**` operator's whitespace requirement** | the whitespace on both sides of `**` must be symmetric; editors / text round-trips can break it | **`**` is banned throughout the project**; fill with `@splat` / `@memset` |

**Before upgrading the Zig version**, every item above must be re-evaluated. The project records them in step in `build.zig` and the `README`.

### 3.2 Installing Zig

```powershell
# after downloading, unpack it anywhere, e.g. D:\zig-x86_64-windows-0.17.0\
# then add it to PATH
[Environment]::SetEnvironmentVariable(
    "PATH",
    "D:\zig-x86_64-windows-0.17.0;" + [Environment]::GetEnvironmentVariable("PATH", "User"),
    "User"
)

# verify
zig version
# expected output: 0.17.0
```

### 3.3 The C++ compiler

Zig bundles `zig cc` / `zig c++`, so no separate C++ compiler is needed. `build.zig` sets `m.link_libcpp = true` so Zig automatically uses its bundled C++ runtime.

---

## 4. The verified environment

### 4.1 The development verification environment

| Item | Value |
|----|-----|
| Operating system | Windows 10 x64 |
| Zig | 0.17.0 (`D:\zig-x86_64-windows-0.17.0\zig.exe`) |
| PowerShell | 5.1 |
| Native library | `LingoFuse64.dll` (v3.10) + `z_ipc_64.dll` |
| nlohmann/json | 3.12.0 |
| Editor | VS Code + the `ziglang.vscode-zig` extension |

### 4.2 The verification results

Every test passes 100% in this environment:

| Suite | Form | Scale | Status |
|------|------|------|:----:|
| `zig build test` | pure-logic unit tests (`test_abi.zig`) | about 24 `test` blocks | ✅ |
| `zig build smoke` | the ABI smoke program (`abi_smoke.zig`) | 35 assertion steps | ✅ |
| `zig build io-smoke` | the I/O smoke program | 18 assertion steps | ✅ |
| `zig build json-smoke` | the JSON engine smoke program | 43 assertion steps | ✅ |
| `zig build network-events-smoke` | the network-events smoke program | 6 assertion steps | ✅ |
| `zig build status-smoke` | the status-queue smoke program | 5 assertion steps | ✅ |
| `zig build uid-smoke` | the UID type smoke program | 10 assertion steps | ✅ |
| `zig build identity-smoke` | the P2P identity smoke program | 2 assertion steps | ✅ |
| `zig build options-smoke` | the typed-options smoke program | 9 assertion steps | ✅ |
| `zig build async-smoke` | the async call smoke program | 6 assertion steps | ✅ |
| `zig build p2p-smoke` | the process-level P2P registration smoke program | 6 assertion steps | ✅ |
| `zig build addressing-smoke` | the three addressing schemes smoke program | 7 assertion steps | ✅ |
| **Total** | — | **about 50 `test` blocks + about 170+ smoke assertion steps** | ✅ |

**On how these numbers are counted**:

- `zig build test` runs the `test` blocks in `tests/test_abi.zig` — Zig-native unit tests covering pure logic only, with no dependency on the native library. There are about 24.
- `zig build *-smoke` runs the **ordinary programs** in `examples/*_smoke.zig`; each program advances in "steps" and prints `[OK]` / `[FAIL]` per step. These are not `test` blocks; they are assertion steps.
- The two are not the same unit. The "total" in the table means "about 50 `test` blocks + about 170+ smoke assertion steps", not "170 tests".
- **The exact numbers are whatever `zig build test` / `zig build *-smoke` actually prints**; the counts may lag behind code evolution, so the source is authoritative.

### 4.3 Unverified environments (an honest statement)

| Environment | Status | Notes |
|------|:----:|------|
| Windows 32-bit | ⏳ not verified | needs the 32-bit native library |
| Linux x64 | ⏳ not verified | `cross_call.zig` / `async_call.zig` use the Windows `Sleep` / `GetTickCount64`, which must be replaced |
| macOS | ⏳ not verified | same as above |
| Zig 0.18+ | ⏳ not verified | the breaking-change list must be re-run |
| Big-endian architectures | ⏳ not verified | the protocol specifies little-endian, so big-endian platforms need explicit conversion |

**The conclusion matches readme.md**: Windows x64 is verified; Linux / macOS / 32-bit platforms must be verified by the user.

---

## 5. Confirming the code in the c directory

### 5.1 `c/LingoFuse.h` / `c/LingoFuse.c`

**Origin**: copied from the C/C++ binding directory of the main LingoFuse repository; **original files unrelated to the development of this binding**.

| Item | Value |
|----|-----|
| Purpose | the dynamic loader for the LingoFuse C ABI (`LF_LoadLibrary` and so on) |
| Exported functions | 59 `LF_*` |
| Modified? | ❌ not modified, kept byte for byte |
| How it is verified | the 59 `extern fn` declarations in `src/sys.zig` correspond one-to-one with `LingoFuse.h` |

**How to confirm**:

```powershell
# open c/LingoFuse.h and search for function declarations with the "LF_" prefix
# the count should be 59, plus the two loader functions (LF_LoadLibrary / LF_FreeLibrary) for 61 total
Select-String -Path c\LingoFuse.h -Pattern "^\s*(TDataHnd|TAppHnd|void|int|int64_t|const char\*)\s+LF_" | Measure-Object
```

### 5.2 `c/lf_json.h` / `c/lf_json.cpp`

**Origin**: **added by this project**, to give Zig a C ABI wrapper around nlohmann/json.

| Item | Value |
|----|-----|
| Purpose | let Zig call C++'s nlohmann/json directly, guaranteeing that JSON serialisation is byte-for-byte identical to the C++ binding |
| Design | **opaque handles** (`TJsonHnd` / `TJsonWriter`) stand in for C++ objects |
| Exception handling | every C++ exception is caught inside the ABI boundary, returning NULL / -1 / 0 |
| Thread safety | different handles are independent; writing through the same handle needs external synchronisation |
| Coverage | parsing, serialisation, type queries, value reads, object/array access, DOM building, a streaming writer |

### 5.3 `c/LingoFuse_Opt.h` (new in v0.4)

**Origin**: **added by this project**, providing C / C++ with a **header wrapper** for the typed `set_opt_*` / `get_opt_*`.

| Item | Value |
|----|-----|
| Purpose | wrap string calls such as `LF_SetOption("Quiet", "True")` as `LF_Set_Opt_Quiet(1)` |
| Design | **header-only**; every function is `static inline` and introduces no new exported symbols |
| Coverage | 16 typed pairs (Quiet / ShowThreadID / Wait_Connection_Timeout / IPC / P2P / DataHandle and so on) |
| C# users | **cannot P/Invoke an inline function directly**; see section 10 |

### 5.4 `c/json.hpp`

**Origin**: the single-file build downloaded from nlohmann/json's official releases.

| Item | Value |
|----|-----|
| Version | 3.12.0 |
| Size | about 920 KB |
| Modified? | ❌ not modified |

---

## 6. Confirming the compilers

### 6.1 The Zig compiler

```powershell
zig version
# must print 0.17.0 (this project is verified only on 0.17.0)
```

### 6.2 The C compiler (Zig's built-in)

Zig ships a C compiler; `build.zig` compiles `c/LingoFuse.c` through `addCSourceFile`.

### 6.3 The C++ compiler (Zig's built-in)

`build.zig` compiles `lf_json.cpp` through `addCSourceFile(.{ .file = b.path("c/lf_json.cpp"), .flags = &.{"-std=c++17"} })`, and links the C++ runtime through `m.link_libcpp = true`.

### 6.4 The compiler confirmation checklist

| Item | Command | Expectation |
|----|------|------|
| Zig version | `zig version` | `0.17.0` |
| C compiler | `.\build.ps1` | `Build succeeded.` |
| C++ compiler | `.\test.ps1` | `RESULT: ALL SUITES PASSED` |
| Native library | `Test-Path LingoFuse64.dll` or `where.exe LingoFuse64.dll` | a path |
| `z_ipc_64.dll` | `where.exe z_ipc_64.dll` | a path |
| `json.hpp` | `Test-Path c\json.hpp` | `True` |

---

## 7. Testing

### 7.1 How to run the tests

```powershell
# run every suite with one command
.\test.ps1

# or run a single suite
zig build test                     # Zig-native unit tests (pure logic)
zig build smoke                    # ABI smoke test
zig build io-smoke                 # unified I/O smoke test
zig build json-smoke               # lf_json C ABI smoke test
zig build network-events-smoke     # network-events smoke test
zig build status-smoke             # status-queue smoke test
zig build uid-smoke                # UID value-type smoke test
zig build identity-smoke           # P2P identity side-data smoke test
zig build options-smoke            # typed-options smoke test
zig build async-smoke              # async call family smoke test
zig build p2p-smoke                # process-level P2P registration smoke test
zig build addressing-smoke         # three addressing schemes smoke test
```

### 7.2 Why `test_abi.zig` may hold only pure-logic tests

**The iron rule**: `tests/test_abi.zig` **must not** contain any test that needs the native library.

**Root cause**: the Zig test runner has two known problems on Windows:

1. **stdout transport contention**: when the native LingoFuse library writes diagnostics to the console it can contend with the test runner's stdout transport and **hang** (no output, no return).
2. **log-level misjudgement**: the test runner defaults to `std.testing.log_level = .warn`, so any log at warn or above (including `std.log.err` inside the callback trampoline) is judged a test failure. **There is no level above `.err` that could suppress it.**

**The workaround**: every test that needs the native library must be rewritten as an **ordinary program** (`examples/*_smoke.zig`):

- write to a log file before and after each step (C stdio + `fflush`), so a hang leaves the scene preserved in the log
- the Zig test runner is not used, so the log-level rules do not apply
- exit-code convention: 0 = all passed, 1 = something failed, 2 = could not open the log file

**The only things `tests/test_abi.zig` may contain**:
- pure data-structure tests (the `Uid` value type, the `AsyncResult` tagged union)
- re-export existence checks (`@hasDecl`)
- tests that do not call `lf.framework.init()`

If an integration test is put there by mistake, `zig build test` **hangs** on the first step.

### 7.3 An overview of the test items

| Suite | Form | Scale | Area |
|------|------|:----:|---------|
| `test_abi` | unit tests (pure logic, `test` blocks) | about 24 `test` blocks | the Uid value type, AsyncResult, re-export existence |
| `smoke` | ABI integration (smoke program) | 35 assertion steps | the complete C ABI contract, callbacks, the binding |
| `io-smoke` | I/O layer (smoke program) | 18 assertion steps | string framing, the JSON wire format, tolerant reading |
| `json-smoke` | JSON engine (smoke program) | 43 assertion steps | the full nlohmann API surface, byte-level compatibility |
| `network-events-smoke` | network events (smoke program) | 6 assertion steps | the install / query / clear lifecycle |
| `status-smoke` | status queue (smoke program) | 5 assertion steps | counting, posting, reading, batch draining |
| `uid-smoke` | UID type (smoke program) | 10 assertion steps | construction / hex / ABI bridging / comparison |
| `identity-smoke` | identity side data (smoke program) | 2 assertion steps | owning handle / callback input+output |
| `options-smoke` | typed options (smoke program) | 9 assertion steps | representative coverage of the 16 typed pairs |
| `async-smoke` | async calls (smoke program) | 6 assertion steps | callback style / blocking style / the single error path |
| `p2p-smoke` | process-level P2P registration (smoke program) | 6 assertion steps | register / unregister / duplicate name / re-registration / namespace independence |
| `addressing-smoke` | the three addressing schemes (smoke program) | 7 assertion steps | App name / UID / P2PName + queries (including negative paths) |
| **Total** | — | **about 50 `test` blocks + about 170+ smoke assertion steps** | — |

**On how these numbers are counted**: the scale of `test_abi` is its number of `test` blocks; the scale of the other suites is the number of assertion steps inside the smoke program. These are different units and must not be added up into "170+ tests". The exact numbers are whatever a real run prints.

### 7.4 Telling whether the tests really ran

**The trap**: when the native library is missing, some integration tests print `[SKIP]` and return success. **A test showing `ok` does not mean it actually ran**.

**How to tell**:

```powershell
# run and capture the output
zig build smoke 2>&1 | Select-String "SKIP"

# no output → the native library loaded and the test really ran ✅
# [SKIP] printed → the native library was not found and the test was skipped ⚠️
```

**A more reliable way**: look at the log files the tests produce:

```powershell
Get-Content abi_smoke.log | Select-Object -First 20
Get-Content uid_smoke.log | Select-Object -First 20
```

The first line of the log should be `LingoFuse Zig ... smoke test`, and every step afterwards records `[step]` / `[ok]` before and after.

### 7.5 Serial vs parallel

- `zig build test` (pure logic) may run in parallel
- every smoke test **must run serially** (they all start the framework's simulated main thread)

**Recommendation**: `.\test.ps1` already calls every suite serially in order.

---

## 8. The Cross Demo trio

### 8.1 Purpose

The Cross Demo is **cross-process, cross-language** end-to-end verification. It mirrors the same-named demos of C++ / C# / Rust / Go / JavaScript / Pascal / Python, verifying **byte-level interoperability** between the Zig binding and the other language bindings.

### 8.2 The three programs

| Program | Role | Responsibility |
|------|------|------|
| `cross_service` | coordinator | creates the IPC endpoint `ipc:cross` as the discovery anchor |
| `cross_node` | worker node | registers the two APIs `add` / `inv_seri`, exposed as the app `demo` |
| `cross_call` | load client | 32 threads calling `demo` concurrently for 10 seconds, then printing throughput |

### 8.3 The registered APIs

#### `add(int32, int32) → int32`

```
request:  int32 LE + int32 LE
response: int32 LE
```

#### `inv_seri(...) → a reversed sequence`

```
request:  uint8 + uint16 LE + uint32 LE + uint64 LE + string(NUL) + float32 LE
response: float32 LE + string(NUL) + uint64 LE + uint32 LE + uint16 LE + uint8
```

**Strings are UTF-8 encoded and terminated by `0x00`. All integers and floats are little-endian.**

### 8.4 Running a single language (all Zig)

**Step one: build**

```powershell
cd D:\CoreLibrary\LingoFuse\zig
.\build.ps1
# or
zig build cross-service cross-node cross-call
```

The artifacts land in `zig-out\bin\`:

```
cross_service.exe
cross_node.exe
cross_call.exe
```

**Step two: three terminals, in order**

```powershell
cd D:\CoreLibrary\LingoFuse\zig\zig-out\bin
```

**Terminal 1 — the coordinator**:

```powershell
.\cross_service.exe
# wait for "[Service] IPC service 'ipc:cross' is running. Press Enter to exit..."
```

**Terminal 2 — the worker node**:

```powershell
.\cross_node.exe
# wait for "[Node] Online. Press Enter to exit..."
```

**Terminal 3 — the load client**:

```powershell
.\cross_call.exe
# prints a summary automatically after 10 seconds
```

**Step three: the shutdown order** (the reverse of startup)

1. close the **client** (cross_call) — press Enter
2. close the **node** (cross_node) — press Enter
3. close the **coordinator** (cross_service) — press Enter

Each program cleans up automatically on exit in the order `ExitMainThread → app.deinit → shutdown → deinit` (LF-CLEAN-001).

### 8.5 Running across languages

Replace any one of the three terminals with the implementation from another language. For example:

**Mix A**: Zig coordinator + C++ node + Zig client

**Mix B**: Zig coordinator + Zig node + Go client

**Any combination should succeed**, because the wire format is byte-for-byte identical.

### 8.6 The cross-language interoperability checklist

| Component | Zig | C++ | C# | Rust | Go | JS | Pascal | Python |
|------|:---:|:---:|:--:|:----:|:--:|:--:|:------:|:------:|
| Coordinator | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Node | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Client | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

---

## 9. A tour of the new v0.4 capabilities

### 9.1 The UID value type

```zig
const lf = @import("lingofuse");

// parse from hex
const uid = try lf.Uid.fromHex("0123...cdef");

// construct from bytes
const uid = lf.Uid.fromBytes([_]u8{0x42} ** 32);  // note: the project uses @splat

// check / compare
if (uid.isNull()) { ... }
if (a.eql(b)) { ... }

// output
var buf: [64]u8 = undefined;
uid.toHexBuf(&buf);
std.debug.print("uid = {s}\n", .{&buf});
```

### 9.2 P2P identity side data

```zig
fn whoamiCallback(
    _: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    // the sender identity can only be read from the callback's input handle
    const uid = input.p2pUid() catch lf.Uid.NULL;
    const name = input.p2pName(std.heap.page_allocator) catch return;

    // print (uid as hex)
    var buf: [64]u8 = undefined;
    uid.toHexBuf(&buf);
    std.debug.print("caller uid = {s}, name = {s}\n", .{ &buf, name });
}
```

### 9.3 Typed options

```zig
const lf = @import("lingofuse");

// booleans / integers / strings
try lf.options.setQuiet(true);
try lf.options.setWaitConnectionTimeout(10_000);
try lf.options.setP2PName("worker_group");

// getters (string types return an allocator-owned slice)
const quiet = try lf.options.getQuiet(std.heap.page_allocator);
const timeout = try lf.options.getWaitConnectionTimeout(std.heap.page_allocator);
const name = try lf.options.getP2PName(std.heap.page_allocator);
defer std.heap.page_allocator.free(name);
```

### 9.4 Process-level P2P registration

```zig
fn whoamiHandler(
    _: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    const uid = input.p2pUid() catch lf.Uid.NULL;
    const name = input.p2pName(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(name);

    var buf: [64]u8 = undefined;
    uid.toHexBuf(&buf);

    try lf.io.writeJson(output, .{
        .uid_hex = &buf,
        .p2p_name = name,
    });
}

// register (it belongs to no App and is reachable by UID or P2PName)
try lf.p2p.registerP2PCall("whoami", "echo caller identity", null, whoamiHandler);

// unregister
const removed = try lf.p2p.unregisterP2P("whoami");
```

### 9.5 The async call family (the highlight)

**This is the Zig form of the "`async_call(xxx, business code)`" you care about most.**

Zig has no closures, so the business code is written as the **fn of an anonymous struct**, carrying shared state through a `ctx` pointer. It is structurally identical to `std.Thread.spawn(.{}, fn, args)`:

```zig
const lf = @import("lingofuse");

// --- shared state ------------------------------------------------
const Sync = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sum: i32 = 0,
};

// --- "business code": the fn of an anonymous struct --------------
const Biz = struct {
    fn handle(ctx: ?*anyopaque, result: lf.async_call.AsyncResult) void {
        const s: *Sync = @ptrCast(@alignCast(ctx orelse return));
        switch (result) {
            .ok => |h| {
                var hh = h;
                var buf: [4]u8 = undefined;
                _ = hh.readBytes(&buf) catch { return; };
                s.sum = std.mem.readInt(i32, &buf, .little);
                s.done.store(true, .release);
            },
            .err => |e| {
                std.debug.print("async failed: {}\n", .{e});
                s.done.store(true, .release);
            },
        }
    }
};

// --- start the call ------------------------------------------------
var req = try lf.DataHandle.create("add");
defer req.deinit();
// ... fill in req ...
var sync = Sync{};
try lf.async_call.callAsync("Calculator", &req, &sync, Biz.handle);

// --- wait (or handle it directly inside Biz.handle) ----------------
while (!sync.done.load(.acquire)) Sleep(1);
```

**Blocking style** (closest to the feel of a synchronous call):

```zig
const bytes = try lf.async_call.callAsyncWait(
    "Calculator",
    &req,
    @as(?u64, 5_000),  // null = wait forever
);
defer std.heap.page_allocator.free(bytes);

// bytes is the response payload, with no trailing NUL
const out = try lf.io.loadsJson(MyResult, bytes);
```

**Why it returns `[]u8` rather than a `DataHandle`**: the async callback's `result` handle belongs to **the framework** and is freed the moment the callback returns. Wrapping it as an owning `DataHandle` and letting it escape the callback boundary causes a use-after-free. The only safe strategy is to **copy the bytes inside the callback**.

---

## 10. Using typed options from C#

### 10.1 The problem

The LingoFuse C ABI exports only two option functions:

```c
void        LF_SetOption(const char* option, const char* value);
const char* LF_GetOption(const char* option);
```

`c/LingoFuse_Opt.h` offers **`static inline` wrappers** such as `LF_Set_Opt_Quiet(1)`, but they **cannot be called from C# by P/Invoke** — P/Invoke can only call **exported** symbols, and a `static inline` function has no exported symbol.

### 10.2 The solution: write a small wrapper on the C# side

**The recommended way** (no native library change needed):

```csharp
using System;
using System.Globalization;
using System.Runtime.InteropServices;

internal static class Lf {
    private const string Lib = "LingoFuse64";  // or "LingoFuse32"

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void LF_SetOption(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string option,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string value);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr LF_GetOption(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string option);
}

/// <summary>
/// Typed wrappers around LF_SetOption / LF_GetOption.
/// Mirrors c/LingoFuse_Opt.h.
/// </summary>
public static class LfOptions {
    private static string GetString(string option) {
        var ptr = Lf.LF_GetOption(option);
        return ptr == IntPtr.Zero ? "" : (Marshal.PtrToStringUTF8(ptr) ?? "");
    }

    private static bool GetBool(string option) =>
        GetString(option).Equals("True", StringComparison.OrdinalIgnoreCase);

    private static void SetBool(string option, bool value) =>
        Lf.LF_SetOption(option, value ? "True" : "False");

    private static ulong GetU64(string option) =>
        ulong.TryParse(GetString(option), NumberStyles.Integer,
                       CultureInfo.InvariantCulture, out var v) ? v : 0UL;

    private static int GetI32(string option) =>
        int.TryParse(GetString(option), NumberStyles.Integer,
                     CultureInfo.InvariantCulture, out var v) ? v : 0;

    // --- Quiet ---------------------------------------------------
    public static void SetQuiet(bool v) => SetBool("Quiet", v);
    public static bool GetQuiet() => GetBool("Quiet");

    // --- ShowThreadID --------------------------------------------
    public static void SetShowThreadId(bool v) => SetBool("ShowThreadID", v);
    public static bool GetShowThreadId() => GetBool("ShowThreadID");

    // --- ConsoleOutput -------------------------------------------
    public static void SetConsoleOutput(bool v) => SetBool("ConsoleOutput", v);
    public static bool GetConsoleOutput() => GetBool("ConsoleOutput");

    // --- Overlap_Connection --------------------------------------
    public static void SetOverlapConnection(bool v) => SetBool("Overlap_Connection", v);
    public static bool GetOverlapConnection() => GetBool("Overlap_Connection");

    // --- Wait_Connection_ReadyOk ---------------------------------
    public static void SetWaitConnectionReadyOk(bool v) => SetBool("Wait_Connection_ReadyOk", v);
    public static bool GetWaitConnectionReadyOk() => GetBool("Wait_Connection_ReadyOk");

    // --- Wait_Connection_Timeout ---------------------------------
    public static void SetWaitConnectionTimeout(ulong ms) =>
        Lf.LF_SetOption("Wait_Connection_Timeout",
                        ms.ToString(CultureInfo.InvariantCulture));
    public static ulong GetWaitConnectionTimeout() =>
        GetU64("Wait_Connection_Timeout");

    // --- Fixed_Sequenced_Time ------------------------------------
    public static void SetFixedSequencedTime(ulong ms) =>
        Lf.LF_SetOption("Fixed_Sequenced_Time",
                        ms.ToString(CultureInfo.InvariantCulture));
    public static ulong GetFixedSequencedTime() =>
        GetU64("Fixed_Sequenced_Time");

    // --- IPC_Serv_ThreadCount ------------------------------------
    public static void SetIpcServThreadCount(int v) =>
        Lf.LF_SetOption("IPC_Serv_ThreadCount",
                        v.ToString(CultureInfo.InvariantCulture));
    public static int GetIpcServThreadCount() =>
        GetI32("IPC_Serv_ThreadCount");

    // --- DataHandle_Idle_Timeout ---------------------------------
    public static void SetDataHandleIdleTimeout(ulong ms) =>
        Lf.LF_SetOption("DataHandle_Idle_Timeout",
                        ms.ToString(CultureInfo.InvariantCulture));
    public static ulong GetDataHandleIdleTimeout() =>
        GetU64("DataHandle_Idle_Timeout");

    // --- LF_P2P_name ---------------------------------------------
    public static void SetP2PName(string name) => Lf.LF_SetOption("LF_P2P_name", name);
    public static string GetP2PName() => GetString("LF_P2P_name");
}
```

Usage is identical to the typed layers of Pascal / C++ / Zig:

```csharp
LfOptions.SetQuiet(true);
LfOptions.SetWaitConnectionTimeout(10_000);
LfOptions.SetP2PName("worker_group");

bool quiet = LfOptions.GetQuiet();
ulong timeout = LfOptions.GetWaitConnectionTimeout();
string group = LfOptions.GetP2PName();
```

### 10.3 About `c/LingoFuse_Opt.h`

`c/LingoFuse_Opt.h` is a convenience layer **for C / C++ users**. C# users can simply copy the `LfOptions` class from section 10.2.

**A future possibility**: if the Pascal side of LingoFuse decides to export typed functions (`LF_Set_Opt_Quiet` and so on), C# could then P/Invoke those symbols directly. **That requires changing Pascal code and is outside this Zig project.** The top of `c/LingoFuse_Opt.h` carries an explanation of the `LF_OPT_DECLARE_EXPORTED` macro describing that evolution path.

---

## 11. Troubleshooting

### 11.1 Compile errors

| Symptom | Cause | Fix |
|------|------|------|
| `LibraryNotFound` | the native library is not on the search path | put `LingoFuse64.dll` + `z_ipc_64.dll` in the exe directory or on PATH |
| `SymbolMissing { symbol: "LF_xxx" }` | the native library is too old | take the newest version from the main repository's `Binary/` |
| `error: expected expression, found 'const'` | a Zig syntax error (0.17 is stricter) | check the syntax |
| `local variable is never mutated` | Zig 0.17 turned the warning into an error | change the unmodified `var` to `const` |
| `binary operator '*' has whitespace on one side` | asymmetric whitespace around the `**` operator | **switch to `@splat`** (see 11.4) |
| `std.mem.Allocator has no member named 'dupeZ'` | removed in Zig 0.17 | use `dupeZ` from `src/util.zig` |
| `std.Thread has no member named 'sleep'` | removed in Zig 0.17 | use the Windows `Sleep(ms)` |
| `std.time has no member named 'milliTimestamp'` | removed in Zig 0.17 | use the Windows `GetTickCount64()` |
| `dependency on libc must be explicitly specified` | a single-file `zig test` does not include libc | add `-lc`: `zig test -lc src/async_call.zig` |

### 11.2 Runtime problems

| Symptom | Cause | Fix |
|------|------|------|
| `zig build test` hangs | an integration test slipped into `test_abi.zig` | remove it; move it to `examples/*_smoke.zig` (see 7.2) |
| `test ... failed: error.SkipZigTest` | the native library is not loaded | check PATH |
| a smoke test step shows `[FAIL]` | see the log file for details | open the `.log` and look at the failure point |
| the first Cross Demo call times out | mesh broadcast delay | normal; it succeeds on retry after 1–3 seconds |
| `IPC queue is already occupied` | an earlier run did not exit cleanly | close every leftover process, or change the endpoint name |
| `LF_BindApp: Main thread is not active` | `prepareDone` was not called or failed | check the `prepareDone` return value |

### 11.3 Log files

Each smoke run produces its own log:

| Log | Produced by |
|------|--------|
| `abi_smoke.log` | `zig build smoke` |
| `io_smoke.log` | `zig build io-smoke` |
| `json_smoke.log` | `zig build json-smoke` |
| `network_events_smoke.log` | `zig build network-events-smoke` |
| `status_smoke.log` | `zig build status-smoke` |
| `uid_smoke.log` | `zig build uid-smoke` |
| `identity_smoke.log` | `zig build identity-smoke` |
| `options_smoke.log` | `zig build options-smoke` |
| `async_smoke.log` | `zig build async-smoke` |
| `p2p_smoke.log` | `zig build p2p-smoke` |
| `addressing_smoke.log` | `zig build addressing-smoke` |

**When it hangs**: the **last line** of the log file is the operation that hung.

**Cleaning up**:

```powershell
.\clean.ps1                  # delete every .log
.\clean.ps1 -KeepLogs        # keep the logs, delete only .zig-cache and zig-out
```

### 11.4 The `**` operator trap (important)

Zig's `**` (array repetition operator) requires **symmetric whitespace on both sides**:

```zig
const a = [_]u8{0} ** 32;   // ✅ correct
const a = [_]u8{0} **32;    // ❌ error: whitespace on one side
const a = [_]u8{0}** 32;    // ❌ error: whitespace on one side
```

**Any tool (an editor, a Markdown round-trip, copy-and-paste) can break the symmetry**. This project's **iron rule**:

> **`**` is banned in all project code (src/ examples/ tests/).**

**Alternatives**:

| Scenario | Banned form | Recommended form |
|------|---------|---------|
| an all-zero array | `[_]u8{0} ** N` | `@splat(0)` or `std.mem.zeroes([N]u8)` |
| filling with one value | `[_]u8{v} ** N` | `@splat(v)` |
| runtime fill | `arr ** = v` | `@memset(&arr, v)` |
| string repetition | `"abc" ** N` | an explicit `@memset` or a `while` loop |

### 11.5 About the `-lc` flag

A module containing **`extern "c" fn` declarations** (currently only `src/async_call.zig`) needs `-lc` for a single-file `zig test`:

```powershell
zig test -lc src/async_call.zig
```

**`build.zig` already sets `link_libc = true`**, so `zig build` / `zig build test` / `zig build *-smoke` **need no manual handling**.

---

## 12. Known limitations

### 12.1 Platform

| Limitation | Impact | Status |
|------|------|:----:|
| verified only on Windows x64 | Linux / macOS untested | ⏳ |
| `cross_call.zig` / `async_call.zig` use the Windows `Sleep` / `GetTickCount64` | porting to POSIX needs `nanosleep` / `clock_gettime` | ⏳ |
| big-endian architectures untested | explicit byte-order conversion needed | ⏳ |

### 12.2 Zig version

| Limitation | Impact |
|------|------|
| pinned to 0.17.0 | 0.18+ requires re-running the breaking-change list |
| `std.json` behaviour may change | `io.readJson` / `loadsJson` / `tryReadJson` need focused regression |
| the signature of a custom `format` method changed | no custom `format`; explicit helpers such as `toHexBuf` |

### 12.3 Architecture

| Limitation | Notes |
|------|------|
| the global slots in `network_events.zig` are not atomic | the documentation requires single-threaded calls; violating that causes handler/ctx mismatches |
| a successful registration in `app_handle.zig` leaks its context | deliberate, and the cost is bounded (the number of APIs) |
| a successful registration in `p2p.zig` likewise leaks its context | same as above |
| the blocking timeout in `async_call.zig` does not cancel the native request | a callback may arrive late after the timeout; the handler discards it once it sees an abandoned waiter |
| `tests/test_abi.zig` cannot hold integration tests | the Zig test runner hangs (see §7.2) |
| `status.drainStatus` allocates twice | irrelevant for short queues; optimisable in high-frequency scenarios |

### 12.4 APIs not implemented

The Zig binding currently **does not expose** the following native capabilities:

| API | Status | Notes |
|-----|:----:|------|
| JSON Pointer | ❌ | requires extending `lf_json.h` |
| JSON Patch | ❌ | same as above |
| JSON Merge Patch | ❌ | same as above |
| JSON SAX streaming parse | ❌ | same as above |
| JSON binary formats (CBOR and so on) | ❌ | same as above |

To get these, `c/lf_json.h` / `c/lf_json.cpp` must be extended.

### 12.5 Stages not finished

| Stage | Status | Notes |
|:----:|:----:|------|
| 8. Multi-language interconnection testing | ⏳ | recommended to verify the combinations in §8.6 one by one |
| 9. CI integration | ⏳ | the repository root currently has **no** GitHub Actions workflow; the only workflow in the tree is `erlang/.github/workflows/ci.yml`. Zig tests rely on running `.\test.ps1` locally |
| — | ⏳ | a complete guide / a pitfall knowledge base |

---

## References

- **The main LingoFuse repository**: https://github.com/PassByYou888/LingoFuse
- **nlohmann/json**: https://github.com/nlohmann/json
- **The official Zig documentation**: https://ziglang.org/documentation/0.17.0/

## License

The same as the main repository; see `LICENSE` in the repository root.
