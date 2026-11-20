# LingoFuse C/C++ Interface README

> Chinese version: [README.md](README.md)

> The official C/C++ binding for the cross-language communication foundation. Built on the C ABI plus a C++17 RAII wrapper, it offers type safety, automatic resource management and cross-platform high-performance RPC, with a modern asynchronous call model built in.

---

## Contents

1. [Preparing the environment](#1-preparing-the-environment)
2. [Building](#2-building)
3. [Testing](#3-testing)
4. [Using the C++ interface](#4-using-the-c-interface)
5. [Using the asynchronous call model](#5-using-the-asynchronous-call-model)
6. [Reading the sender's identity (side data)](#6-reading-the-senders-identity-side-data)
7. [Test reports](#7-test-reports)
8. [Troubleshooting](#8-troubleshooting)
9. [License](#9-license)

---

## 1. Preparing the environment

### 1.1 Compiler and toolchain

| Item | Requirement |
|------|------|
| C++ standard | **C++17** or newer |
| Compiler | MSVC 2019+ / GCC 9+ / Clang 10+ / MinGW |
| CMake | 3.15 or newer |
| Thread library | `Threads::Threads` (located automatically by CMake) |
| Platforms | Windows 64/32-bit, Linux, macOS, BSD |

### 1.2 Runtime libraries

The C/C++ binding **does not ship** the LingoFuse native shared library; obtain it separately and place it where the system can find it.

| Platform | Core library | IPC dependency | Memory allocator |
|------|--------|----------|------------|
| Windows 64-bit | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32-bit | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` | `libmimalloc.so` (optional) |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` | `libmimalloc.dylib` (optional) |

**Search order** (determined by `LF_LoadLibrary`):
1. the directory containing the current executable
2. the system load path (`PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`)

**There is no environment-variable override mechanism**. The recommendation is to copy the runtime libraries next to the executable, or add their directory to the system `PATH`.

### 1.3 Obtaining the source

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
cd LingoFuse/cpp
```

The directory structure:

```
cpp/
├── LingoFuse.h                 # C ABI declarations
├── LingoFuse.c                 # C ABI dynamic loading and forwarding
├── LingoFuse.hpp               # C++17 RAII wrapper + asynchronous call model
├── lf_io.hpp                   # unified JSON / string I/O
├── lf_http_bridge_client.hpp   # HTTP bridge client
├── json.hpp                    # nlohmann/json single header
├── CMakeLists.txt              # top-level build script
├── LingoFuse_Cpp_Knowledge_Base.md   # the C++ knowledge base
├── json.hpp.md                 # the nlohmann/json reference
├── CrossDemo/                  # cross-process demo
├── Conc/                       # concurrent Notify demo and CI
├── Stress/                     # the stress test suite
└── test/                       # the functional test suite
    ├── test_lingofuse.cpp           # C++ RAII / network / async tests (50 items)
    ├── test_lingofuse_json.cpp      # JSON / wire-format tests (40 items)
    ├── test_lingofuse_capi.c        # pure C ABI offline tests
    ├── test_lingofuse_uid.c         # UID identity-injection end-to-end tests
    ├── test_uid_probe.c             # UID calling-convention probe (Windows only)
    ├── run_test_ci.ps1
    └── LingoFuse_Functional_Test_Guide.md
```

---

## 2. Building

### 2.1 The build steps

```bash
cd LingoFuse/cpp
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release
```

Build artifacts go to the `LingoFuse/Binary/` directory by default (the same directory as the runtime libraries).

### 2.2 The main targets

| Target | Type | Description |
|------|------|------|
| `lingofuse_headers` | INTERFACE | the public headers |
| `lingofuse_c_wrapper` | STATIC | the C ABI forwarding layer + dynamic loader |
| `test_lingofuse` | EXECUTABLE | C++ RAII / network / async tests (50 items) |
| `test_lingofuse_json` | EXECUTABLE | JSON / wire-format tests (40 items) |
| `test_lingofuse_capi` | EXECUTABLE | pure C ABI offline tests |
| `test_lingofuse_uid` | EXECUTABLE | UID identity-injection end-to-end tests |
| `test_uid_probe` | EXECUTABLE (Windows only) | the `LF_Get_P2P_UID` calling-convention probe |
| `ConcService` / `ConcClient` | EXECUTABLE | the concurrent Notify demo |
| `StressService` / `StressClient` / `StressMonitor` | EXECUTABLE | the stress-test trio |
| `CrossService` / `CrossNode` / `CrossCall` | EXECUTABLE | the cross-process demo |

### 2.3 Build options

CMake adds `/W4 /permissive-` for MSVC and `-Wall -Wextra` for GCC/Clang automatically. Customise them in `CMakeLists.txt` if needed.

---

## 3. Testing

### 3.1 Functional tests

```bash
cd LingoFuse/Binary

# C++ RAII / network / async tests (50 items)
./test_lingofuse
./test_lingofuse --ci

# JSON / wire-format tests (40 items)
./test_lingofuse_json --ci

# pure C ABI offline tests
./test_lingofuse_capi

# UID identity-injection end-to-end tests
./test_lingofuse_uid

# UID calling-convention probe (Windows only)
./test_uid_probe
```

One-command CI (cross-platform):

```powershell
# Windows
..\Test\run_test_ci.ps1

# Linux / macOS
../Test/run_test_ci.sh
```

**What the tests cover**:

| Suite | Items | Coverage |
|------|:----:|----------|
| `test_lingofuse` | 50 | DataHandle, App, network basics, network options, remote calls, network events, the status queue, concurrency, stress, **async calls (8 items)** |
| `test_lingofuse_json` | 40 | JSON serialization policy, NUL-framed strings, byte streams, tri-state reads, wire-format invariants |
| `test_lingofuse_capi` | ~30 | C ABI loading, handles, strings, the UID dual-role ABI, local calls |
| `test_lingofuse_uid` | 7 | end-to-end verification of sender UID injection, the pointer-return ABI |
| `test_uid_probe` | diagnostic | machine-code prologue analysis + safe-call verification |

### 3.2 The concurrent Notify test

```bash
# terminal 1: start the server
./ConcService

# terminal 2: start the client (default 8 threads × 10000 messages/batch × 20 batches)
./ConcClient --threads 8 --size 10000 --batches 20
```

One-command CI:

```powershell
.\run_conc_ci.ps1
```

### 3.3 The stress test

```bash
# terminal 1: start the server
./StressService

# terminal 2: start the monitor (optional)
./StressMonitor

# terminal 3: start the client
./StressClient --threads 64
```

One-command CI (runs 5 comparison scenarios automatically and produces a comparison report):

```powershell
.\run_stress_ci.ps1
```

### 3.4 The cross-process demo

```bash
# terminal 1: beacon
./CrossService

# terminal 2: worker node
./CrossNode

# terminal 3: load client
./CrossCall
```

### 3.5 CI mode and exit codes

Every test program supports the `--ci` flag, writes JSON Lines, and follows this exit-code convention:

| Exit code | Meaning |
|:------:|------|
| `0` | everything PASSed |
| `1` | some FAILs |
| `2` | bad command-line arguments or a startup failure |

---

## 4. Using the C++ interface

### 4.1 Including the headers

```cpp
#include "LingoFuse.hpp"              // RAII wrapper + asynchronous call model
#include "lf_io.hpp"                  // unified JSON / string I/O (optional, already included by LingoFuse.hpp)
#include "lf_http_bridge_client.hpp"  // HTTP bridge client (optional)
```

### 4.2 Loading the runtime library (the mandatory first step)

```cpp
int main() {
    lingofuse::LibraryLoader loader;   // the constructor calls LF_LoadLibrary
    // ... all other work ...
    return 0;                          // the destructor calls LF_FreeLibrary
}
```

`LibraryLoader` is a reference-counted RAII wrapper and is safe to use across several modules. **The library must be loaded successfully before any `LF_*` call**.

### 4.3 DataHandle — the data handle

```cpp
// create an auto-recycled handle (the default; the library frees it after 10 minutes idle)
lingofuse::DataHandle dh("my_api");

// create a permanent handle (never auto-recycled; free it manually)
auto perm = lingofuse::DataHandle::createPermanent("my_api");

// write scalars (little-endian)
dh.write(int32_t{42});
dh.write(std::string("Hello 世界"));

// write JSON
dh.writeJson({{"name", "Alice"}, {"age", 30}});

// read
dh.seek(0);
int32_t n;
dh.read(n);
std::string s = dh.readString();
auto j = dh.readJson();
```

### 4.4 App — the application container

```cpp
lingofuse::App app("MyApp", "My service");

// register a Call API (request-response)
app.registerCall("add", "Add two ints", nullptr,
    [](void*, void* in, void* out) {
        lingofuse::DataHandle in_h(static_cast<TDataHnd>(in), false);
        lingofuse::DataHandle out_h(static_cast<TDataHnd>(out), false);
        int32_t a, b;
        in_h.read(a); in_h.read(b);
        out_h.write(a + b);
    });

// register a Notify API (one-way)
app.registerNotify("log", "Log message", nullptr,
    [](void*, void* in) {
        lingofuse::DataHandle in_h(static_cast<TDataHnd>(in), false);
        // handle the message
    });

// local call
lingofuse::DataHandle param("add");
param.write(int32_t{5});
param.write(int32_t{7});
auto result = app.localCall(param);

// unregister
app.unregister("add");
```

### 4.5 Network preparation and startup

```cpp
lingofuse::setOption("Wait_Ready", "False");   // deployment mode, do not block waiting
lingofuse::resetPrepare();

// create the server (beacon)
lingofuse::prepareService("ipc:my_service", "ipc:my_service");

// create the client and bind the App
lingofuse::prepareClient("ipc:my_service", app.get());

// start the framework
if (lingofuse::prepareDone() != 1) {
    // startup failed
}

// wait for the target App to come online (optional)
for (int i = 0; i < 50; ++i) {
    if (lingofuse::checkApi("TargetApp", "target_api")) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
}
```

### 4.6 Synchronous remote calls

```cpp
// synchronous call
auto resp = lingofuse::tryCall("TargetApp", param, 3000);
if (resp) {
    int32_t result;
    resp->read(result);
}

// one-way notification (ordering not guaranteed)
lingofuse::notify("TargetApp", param);

// ordered notification (FIFO per (app, api) pair)
lingofuse::sequencedNotify("TargetApp", param);
```

### 4.7 Network event listeners

```cpp
lingofuse::setNetworkEvent(
    [](const std::string& addr) {
        std::cout << "Connected: " << addr << "\n";
    },
    [](const std::string& addr) {
        std::cout << "Disconnected: " << addr << "\n";
    });

// clear
lingofuse::clearNetworkEvent();
```

### 4.8 Runtime options

```cpp
lingofuse::setOption("Overlap_Connection", "True");       // allow several clients on one address
lingofuse::setOption("Wait_Connection_Timeout", "60000"); // 60-second wait timeout
lingofuse::setOption("Quiet", "True");                    // quiet mode
```

### 4.9 The status queue

```cpp
lingofuse::postStatus("custom log message");

while (lingofuse::statusCount() > 0) {
    std::string msg = lingofuse::popStatus();
    std::cout << "[LF] " << msg << "\n";
}
```

### 4.10 The HTTP bridge client

```cpp
#include "lf_http_bridge_client.hpp"

// wait for the bridge to come online
if (lingofuse::bridge::waitForBridge(nullptr, 5000)) {
    // send an HTTP POST
    auto envelope = lingofuse::bridge::httpPost(
        "https://api.example.com/v1/echo",
        {{"message", "Hello"}}
    );
    auto body = lingofuse::bridge::httpPostBody(
        "https://api.example.com/v1/echo",
        {{"message", "Hello"}}
    );

    // JSON repair
    std::string repaired = lingofuse::bridge::repairJson(
        "{'name': 'Alice', 'age': 30,}"
    );
}
```

### 4.11 The cleanup order

**Follow this order strictly** (Pascal LF-CLEAN-001):

```cpp
lingofuse::clearNetworkEvent();   // 1. clear network events
lingofuse::exitMainThread();      // 2. stop the main thread
app.close();                      // 3. free the App (~App does it automatically)
lingofuse::shutdown();            // 4. shut down the framework
// the LibraryLoader destructor calls LF_FreeLibrary automatically
```

In C++, RAII guarantees the order automatically:

```cpp
{
    lingofuse::LibraryLoader loader;   // constructed first, destroyed last
    ShutdownGuard shutdown_guard;      // constructed second, destroyed second -> LF_Shutdown
    lingofuse::App app("MyApp");       // constructed last, destroyed first -> LF_FreeApp
    // ...
}   // destruction order: ~App -> ~ShutdownGuard -> ~LibraryLoader
```

---

## 5. Using the asynchronous call model

> **This is the core feature of this update**. It hides the C ABI's `void* data` + function-pointer mechanism behind a lambda-friendly API, turning "issue a call → write the callback body" into one flowing piece of code.

### 5.1 The simplest form

```cpp
#include "LingoFuse.hpp"

lingofuse::callAsync("CalcSvc", "add",
    {{"a", 5}, {"b", 7}},                    // JSON payload
    [](lingofuse::AsyncResult r) {           // the callback
        if (!r.ok()) {
            std::cerr << "call failed: " << r.error() << "\n";
            return;
        }
        auto j = r.handle().readJson();      // copy the data out
        std::cout << j.dump() << "\n";
    });
```

**Three characteristics**:

1. **The call and the callback live in one expression** — no `std::function`, no hand-written trampoline.
2. **There is only one error path** — `if (!r.ok())`. Dispatch failures and remote failures both take it.
3. **The result is read from a "borrowed handle"** — `.readJson()` / `.readString()` / `.readBytes()` return fresh objects, and the user never touches a raw pointer.

### 5.2 The four entry points

| Function | Corresponding C ABI | Addressing |
|------|-----------|----------|
| `lingofuse::callAsync` | `LF_Async_Call` | App name |
| `lingofuse::callAsyncSequenced` | `LF_Async_Sequenced_Call` | App name, FIFO order |
| `lingofuse::callAsyncByUid` | `LF_UID_Async_Call` | UID |
| `lingofuse::callAsyncByP2PName` | `LF_P2PNAME_Async_Call` | P2PName |

Each has two overloads: **the DataHandle form** and **the convenience JSON form**.

### 5.3 Using an already-constructed DataHandle

```cpp
lingofuse::DataHandle param("add");
param.write(std::int32_t{5});
param.write(std::int32_t{7});

lingofuse::callAsync("CalcSvc", param,
    [](lingofuse::AsyncResult r) {
        if (!r.ok()) return;
        std::int32_t sum = 0;
        r.handle().read(sum);
        std::cout << "sum = " << sum << "\n";
    });

// the C ABI copies the payload synchronously at call time, so param can be destroyed immediately.
```

### 5.4 Fanning out several async calls

```cpp
struct Aggregator {
    std::mutex m;
    std::vector<nlohmann::json> results;
    std::atomic<int> pending{0};
    std::condition_variable cv;

    void submit(int n) { pending.store(n); }

    void on_result(nlohmann::json j) {
        { std::lock_guard<std::mutex> lk(m); results.push_back(std::move(j)); }
        if (--pending == 0) cv.notify_all();
    }

    bool wait(int timeout_ms) {
        std::unique_lock<std::mutex> lk(m);
        return cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                           [this] { return pending.load() == 0; });
    }
};

Aggregator agg;
agg.submit(16);

for (int i = 0; i < 16; ++i) {
    lingofuse::callAsync("compute_node", "exp",
        {{"base", 2.0}, {"exponent", static_cast<double>(i)}},
        [&agg](lingofuse::AsyncResult r) {
            if (r.ok()) {
                agg.on_result(r.handle().readJson());
            } else {
                agg.on_result(nlohmann::json{{"error", r.error()}});
            }
        });
}

agg.wait(10000);
```

**Key points**:
- the aggregator is **captured by reference**, and its lifetime must exceed all the callbacks — the stack-object + blocking-wait pattern is safe.
- each callback **copies the JSON out inside the callback body** and never keeps a handle across the callback boundary.

### 5.5 Chained calls (fire-and-forget)

```cpp
lingofuse::callAsync("AuthSvc", "login", {{"user", "alice"}},
    [](lingofuse::AsyncResult r) {
        if (!r.ok()) return;

        // copy the token out — we still need it after this callback returns.
        std::string token = r.handle().readJson()
                              .at("token").get<std::string>();

        // issue the next async call from inside the callback (fire-and-forget).
        lingofuse::callAsync("DataSvc", "fetch", {{"token", token}},
            [](lingofuse::AsyncResult r2) {
                if (!r2.ok()) return;
                auto j = r2.handle().readJson();
                my_main_thread_queue.post([j]() {
                    ui_label.setText(j.dump());
                });
            });
    });
```

Every step copies out what it needs before returning (`token`, `j`); nothing survives across a callback boundary.

### 5.6 The callback contract (required reading)

The `on_complete` callback runs on a **TCompute worker thread** — not the calling thread, and not the simulated main thread. Inside the callback:

| Allowed | Forbidden |
|------|------|
| reading/copying the result (`readJson` / `readString` / `readBytes` / `read<T>`) | blocking (sleep, network I/O, waiting on a lock) |
| posting to your own thread-safe queue | calling `LF_Call` / `LF_Notify` / `LF_LocalCall` / `LF_PrepareDone` / `LF_Shutdown` |
| issuing another `callAsync*` (a fire-and-forget chain) | touching UI components |
| logging / atomic operations | keeping `r.handle()` past the callback body |
|  | calling `LF_FreeData` on `r.handle()` |

### 5.7 Dispatch failures also go through the callback

If `LF_Async_Call` rejects the request before dispatching (returning 0), the C++ wrapper fires the callback **synchronously on the caller's thread** with an error `AsyncResult`.

**That means**:

- the caller need not check `callAsync`'s return value — "call failed" signals take the same `if (!r.ok())` path as remote failures.
- the callback body must **be safe on any thread** (including the caller's own). That is in fact a superset of the "no blocking / no `LF_*` calls / no UI" rule, and any callback obeying that rule satisfies it automatically.

### 5.8 No timeout / cancellation

The C ABI's async family has no timeout parameter and no cancellation handle. If a request is dispatched but its response never arrives, the holder object leaks and the callback never fires. In practice LingoFuse's transport layer guarantees that every dispatched async request eventually produces a callback (carrying either the result or an empty-payload "timeout" result), so this is a theoretical rather than a practical concern. Applications needing hard timeouts should implement them one layer up (tracking outstanding requests and abandoning them after a configured time, for instance).

### 5.9 Coexisting with the traditional synchronous style

The new async API **does not replace** the existing synchronous API:

```cpp
// synchronous (blocking, returns the result)
auto result = lingofuse::tryCall("App", param, 3000);

// asynchronous (non-blocking, callback)
lingofuse::callAsync("App", param, [](lingofuse::AsyncResult r) { ... });
```

**How to choose**:

- if you need the result immediately for the next step → synchronous
- if you need several calls concurrently → asynchronous
- if you are calling from a worker thread → **async only** (calling synchronous `LF_Call` on a worker thread deadlocks)

---

## 6. Reading the sender's identity (side data)

> **This is the other core feature of this update**. The LingoFuse framework writes two identity fields into the payload header of every request **on the sender**, and the receiver can read them from the callback's `input` argument.

### 6.1 The two identity fields

| Field | Content |
|------|------|
| `FromUID` | the sender's 32-byte session UID |
| `FromP2PName` | the sender's user-defined P2P group name (UTF-8) |

These two fields are **"side data"** — they are **not properties of the handle itself**, but metadata the sender writes into the payload.

### 6.2 Valid only on the callback's `input` argument

| Position | Valid |
|------|:--------:|
| the callback's `input` argument (Call / Notify) | ✅ |
| the local call's `input` | ✅ |
| the callback's `output` argument | ❌ (zero-filled / empty string) |
| a handle you created yourself with `LF_CreateData` | ❌ (as above) |

Called on an invalid position, the library **does not throw**; it logs a warning and returns a zero-filled UID / empty string.

### 6.3 How to read them from C++

The RAII wrapper hides the temporary library pointer and returns immediate copies only:

```cpp
static void LF_CDECL whoami_cb(void*, void* in, void* out) {
    lingofuse::DataHandle inp(static_cast<TDataHnd>(in), false);
    lingofuse::DataHandle out_h(static_cast<TDataHnd>(out), false);

    // read the sender identity from the input handle. Valid only inside the callback body.
    std::array<std::uint8_t, 32> uid = inp.getP2PUid();  // copied immediately
    std::string p2p_name = inp.getP2PName();             // copied immediately

    // uid and p2p_name are fresh objects and can safely be kept.
    std::string hex;
    hex.reserve(64);
    static const char* digits = "0123456789abcdef";
    for (auto b : uid) {
        hex.push_back(digits[(b >> 4) & 0x0F]);
        hex.push_back(digits[b & 0x0F]);
    }

    out_h.writeJson({
        {"uid_hex", hex},
        {"p2p_name", p2p_name}
    });
}
```

### 6.4 The contract of the two accessors

| Accessor | Returns | Valid position |
|--------|------|----------|
| `DataHandle::getP2PUid()` | `std::array<std::uint8_t, 32>` | `input` handles only |
| `DataHandle::getP2PName()` | `std::string` | `input` handles only |

Neither **throws**, neither **exposes a raw pointer**, and both **may be called from any thread**.

### 6.5 Typical uses

| Scenario | Usage |
|------|------|
| call authentication | compare `getP2PName()` against a whitelist |
| audit logging | record `getP2PUid()` (hex) and `getP2PName()` |
| session management | keep sessions keyed by UID |
| routing by group | fan out to different workers by P2PName |
| multi-tenancy | P2PName as the tenant identifier |
| a whoami probe | the server returns the caller's identity, the client discovers itself |

### 6.6 Details at the C ABI level (advanced users)

In the C ABI:

```c
const TP2P_UID* LF_Get_P2P_UID(TDataHnd hnd);  // returns a pointer
const char*     LF_Get_P2P_Name(TDataHnd hnd); // returns a pointer
```

- `LF_Get_P2P_UID` returns a `const TP2P_UID*` — a pointer to a 32-byte UID owned by the library, **freed by the library about 5 seconds after the call**. The caller must **dereference and copy immediately**, must not keep the pointer, and must not free it.
- the pointer returned by `LF_Get_P2P_Name` likewise expires after about 5 seconds; copy it with `strncpy` immediately.
- `LF_Get_P2P_UID` does **not** return a `TP2P_UID` value (that was the old ABI); it returns **a pointer** (the new ABI, since v3.2).

**Important**: the `TP2P_UID` type plays two different roles in the C ABI:

| Role | Type | Where it appears |
|------|------|----------|
| **parameter role** | `TP2P_UID` (struct, by value) | `LF_UID_Call` / `LF_Check_UID` / `LF_WriteUid` / `LF_ReadUid` |
| **return role** | `const TP2P_UID*` (pointer) | `LF_Get_P2P_UID` only |

**Do not unify these two roles** — they are different positions in the ABI.

---

## 7. Test reports

### 7.1 The functional test report

**Interactive mode**: a human-readable detailed report with each test's PASS/FAIL, elapsed time and failure reason.

**CI mode** (`--ci`): one JSON object per line.

A single test event:
```json
{"event":"test","suite":"test_lingofuse","index":1,"total":50,"category":"DataHandle","name":"DataHandle :: basic types","status":"PASS","elapsed_ms":12}
```

A suite summary:
```json
{"event":"summary","suite":"test_lingofuse","total":50,"passed":50,"failed":0,"elapsed_sec":52.234,"status":"PASS"}
```

The one-command script `run_test_ci.ps1` prints a comparison table:
```
======================================================================
  LingoFuse Functional Test -- CI Summary
======================================================================

  Suite                           Total   Passed   Failed    Time(s)   Status
  ---------------------------- -------- -------- -------- ---------- --------
  test_lingofuse                     50       50        0      52.23     PASS
  test_lingofuse_json                40       40        0       0.85     PASS
  ---------------------------- -------- -------- -------- ---------- --------
  TOTAL                              90       90        0      53.08     PASS

======================================================================
  RESULT: ALL TESTS PASSED
======================================================================
```

### 7.2 The concurrent Notify test report

`run_conc_ci.ps1` produces `conc_ci_report.jsonl`, containing every Service and Client event.

**The measured baseline** (Windows x64, LingoFuse v3.10):
- 8 threads × 10000 messages/batch × 20 batches → **4,454 notify/s**
- per-notify latency: P50 = 666 μs, P95 = 858 μs
- 200,000 notifies in total, **zero loss**
- the completion barrier costs 700–1100 ms each time

### 7.3 The stress test report

`run_stress_ci.ps1` produces `stress_ci_summary.txt`, containing the comparison table and automatically derived observations.

**The measured baseline** (Windows x64, LingoFuse v3.10):

| Scenario | Threads | Duration | Notify/s | Call/s | Success rate | Status |
|------|:----:|:----:|:--------:|:------:|:------:|:------:|
| Pure Notify | 32 | 15s | 5,446 | — | — | PASS |
| Pure Call @32 | 32 | 15s | — | 236 | 100% | PASS |
| Pure Call @128 | 128 | 15s | — | 817 | 100% | PASS |
| Pure Call @512 | 512 | 15s | — | 1,166 | 100% | PASS |
| Mixed 20:1 | 64 | 30s | 4,153 | 207 | 100% | PASS |

**Key conclusions**:
- a single process on a single endpoint tops out at **about 5,500 Notify/s**
- a single process on a single endpoint tops out at **about 1,200 Call/s**
- the Notify/Call throughput ratio is about **5×**
- Call starts saturating around 128 threads

### 7.4 A CI integration example

```yaml
- name: LingoFuse functional tests
  working-directory: LingoFuse/Binary
  shell: pwsh
  run: |
    ..\Test\run_test_ci.ps1 -Quiet

- name: LingoFuse concurrent notify test
  working-directory: LingoFuse/Binary
  shell: pwsh
  run: |
    .\run_conc_ci.ps1 -Batches 20 -Size 10000 -Threads 8 -Quiet

- name: LingoFuse stress self-evaluation
  working-directory: LingoFuse/Binary
  shell: pwsh
  run: |
    .\run_stress_ci.ps1 -Quiet
```

---

## 8. Troubleshooting

### 8.1 A load failure

**Symptom**: `LingoFuse: Failed to load LingoFuse64.dll`
**Fix**: copy the runtime library next to the executable, or add it to `PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`.

### 8.2 A callback crash

**Cause**: the callback did not use the `LF_CDECL` calling convention, corrupting the stack.
**Fix**: every synchronous callback must be declared `LF_CDECL` (that is, `__cdecl`). Async callbacks are handled by the wrapper automatically.

### 8.3 Deadlock

**Cause**: a blocking LingoFuse function (such as `LF_Call`) was called inside a callback.
**Fix**:
- synchronous scenarios: move the long-running work onto a dedicated thread.
- asynchronous scenarios: use `lingofuse::callAsync` to start a chained call (fire-and-forget) rather than the synchronous `LF_Call`.

### 8.4 A wrong cleanup order

**Symptom**: a crash on shutdown, or the address still occupied after a restart.
**Fix**: follow the order `clearNetworkEvent → exitMainThread → ~App → shutdown → ~LibraryLoader` strictly.

### 8.5 The Overlap_Connection trap

**Symptom**: when several Apps bind to the same address the second App is silently ignored.
**Fix**: call `setOption("Overlap_Connection", "True")` before `prepareClient`.

### 8.6 A remote call times out

**Symptom**: `tryCall` returns `nullopt`.
**Investigate**:
- use `checkApi` to confirm the target is online (mind the 3-second broadcast delay).
- check whether `Wait_Connection_Timeout` is too short.
- confirm the target App name and API name are correct.

### 8.7 Garbled Chinese in JSON

**Cause**: bypassing `lf_io` and calling the low-level API directly.
**Fix**: always handle JSON through `lingofuse::io::write_json` / `read_json`, which guarantees literal UTF-8 output with no `\uXXXX` escaping.

### 8.8 The async callback is never invoked

**Investigation order**:

1. **check whether `callAsync*` is actually executed** — log inside it.
2. **enable `ShowThreadID=True` + `Quiet=False`** — look for callback logs on the worker thread.
3. **confirm you are not calling a blocking function inside a callback** — it occupies the whole worker thread pool.
4. **if the request dispatches successfully but never calls back** — that is a transport-layer problem; look at the `[LF-DEBUG]` traces in the status queue.
5. **compare with `test_async_call_dispatch_failure`**: that test uses a "no client environment" to verify that the dispatch-failure path really does fire the callback synchronously.

### 8.9 The P2P identity is empty

**Symptom**: `getP2PUid()` returns all zeros and `getP2PName()` an empty string.
**Investigate**:
1. **confirm you are calling on the `input` handle** — not on the `output` handle or a self-built handle.
2. **confirm the sender set `LF_P2P_name`** — `setOption("LF_P2P_name", "my_group")`.
3. **confirm the UID has been generated** — keep `Wait_Connection_ReadyOk` at its default (`True`) so `prepareDone` blocks until the client is online.
4. **check the status queue** — the C side prints `[warning] Get_P2P_UID(): P2P Info only backcall "input" parameter.`.

### 8.10 Leaking `AsyncResult::handle()` out of an async callback

**Symptom**: passing a reference or raw pointer to `r.handle()` outward and hitting a use-after-free later.
**Root cause**: `AsyncResult::handle()` is **a borrow**; the framework frees the underlying buffer as soon as the callback returns.
**Fix**: **copy the data out** inside the callback body:

```cpp
// ❌ wrong: keeping a handle reference
lingofuse::DataHandle* saved = nullptr;
lingofuse::callAsync("App", param,
    [&saved](lingofuse::AsyncResult r) {
        saved = &r.handle();      // ❌ invalid once the callback returns
    });

// ✅ right: copy immediately
nlohmann::json saved;
lingofuse::callAsync("App", param,
    [&saved](lingofuse::AsyncResult r) {
        saved = r.handle().readJson();  // ✅ a fresh object
    });
```

---

## 9. License

MIT License. See the `LICENSE` file at the repository root.

---

## Further reading

| Document | Content |
|------|------|
| `LingoFuse_Cpp_Knowledge_Base.md` | the complete C++ interface reference (v8.0, 50 tests explained) |
| `LingoFuse_Pascal_Complete_Guide.md` | the Pascal interface and internal mechanisms |
| `test/LingoFuse_Functional_Test_Guide.md` | the functional tests in detail plus the CI baseline |
| `Conc/LingoFuse_Concurrent_Notify_Demo.md` | the concurrent Notify pattern and completion barriers |
| `Stress/LingoFuse_Stress_Test_Guide.md` | the Stress test suite and the measured baseline |
| `json.hpp.md` | the nlohmann/json reference |

---

*This document is based on the LingoFuse v3.10 C/C++ binding. All code examples use English comments, matching the source contract.*
