# LingoFuse Go binding

> Chinese version: [README.md](README.md)

[LingoFuse](https://github.com/PassByYou888/LingoFuse) is a cross-language, cross-process, cross-machine distributed RPC framework
built on the C4 service mesh. This directory is the **official Go binding** of LingoFuse, providing a wire format
**byte-for-byte compatible** with the C++ / C# / Pascal / Python / JavaScript
implementations, so processes written in those languages can be mixed freely in the same mesh.

- **Pure Go FFI**: built on [purego](https://github.com/ebitengine/purego) — no cgo, no C compiler
- **Cross-compilation friendly**: just `GOOS=windows go build`; no toolchain switching
- **RAII-style API**: `DataHandle` / `AppHandle` with explicit `Close()`, no dependency on `runtime.SetFinalizer`
- **Type safety**: `sys` is the only layer that touches native calls; everything above goes through the `lingofuse` package
- **Three addressing modes**: App name / UID / P2PName, through a unified `Target` interface, freely switchable
- **A modern async model**: `AsyncResult` + `CallAsync` / `CallAsyncWithTimeout` / `SequencedCallAsync`
- **Complete tests**: 60+ tests covering the ABI smoke, scalar/string/JSON I/O, the error hierarchy, addressing targets, async dispatch, and the full in-process E2E flow

---

## Contents

- [1. Requirements](#1-requirements)
- [2. Directory structure](#2-directory-structure)
- [3. Installing and deploying](#3-installing-and-deploying)
- [4. Building](#4-building)
- [5. Testing](#5-testing)
- [6. Quick start](#6-quick-start)
- [7. The cross-language Cross Demo](#7-the-cross-language-cross-demo)
- [8. API quick reference](#8-api-quick-reference)
- [9. Core concepts](#9-core-concepts)
- [10. Iron rules](#10-iron-rules)
- [11. Troubleshooting](#11-troubleshooting)
- [12. Differences from the other language bindings](#12-differences-from-the-other-language-bindings)

---

## 1. Requirements

### 1.1 Go version

| Component | Minimum version | Notes |
|------|:--------:|------|
| Go language | **1.21** | `any` / `unsafe.Add` / the `Int64`/`Bool`/`Uintptr` types of `sync/atomic` became available from this version |

Go 1.22 or later is recommended.

### 1.2 Operating system and architecture

| Platform | Architecture | Status |
|------|:----:|:----:|
| Windows | amd64 / arm64 | ✅ fully supported |
| Linux | amd64 / arm64 | ✅ fully supported |
| macOS | amd64 / arm64 | ✅ fully supported |
| other | any | ⚠️ limited by what `purego` supports |

### 1.3 The native library

At runtime the Go binding loads the native dynamic library through `purego` and **does not participate in compile-time linking**. The files required:

| Platform | File name |
|------|--------|
| Windows 64-bit | `LingoFuse64.dll` |
| Windows 32-bit | `LingoFuse32.dll` |
| Linux / BSD | `liblingofuse.so` |
| macOS | `liblingofuse.dylib` |

The main repository's `Binary/` directory already ships the Windows native library. Linux / macOS builds must be built from source (see the main repository's README).

### 1.4 What you do not need

- ❌ no C compiler (gcc / clang / MSVC)
- ❌ no `CGO_ENABLED=1`
- ❌ no Python / Node.js / .NET runtime

---

## 2. Directory structure

```
go/
├── go.mod                      # module definition
├── go.sum                      # dependency checksums
├── README.md                   # this file
├── LingoFuse64.dll             # native library (placed manually, see §3)
│
├── sys/                        # ① the low-level FFI layer
│   ├── bindings.go             #   the 59 C export function pointers
│   ├── uid.go                  #   the TP2P_UID type + Parse/Format/IsNull helpers
│   ├── loader.go               #   purego dynamic loading + per-symbol resolution + per-path error collection
│   ├── loader_windows.go       #   Windows platform bindings
│   ├── loader_unix.go          #   Unix platform bindings
│   ├── callbacks.go            #   callback bridging (trigger ID ↔ Go function) + deadlock watchdog
│   └── strings.go              #   C string helpers (CStringScope / GoString)
│
├── lingofuse/                  # ② the high-level RAII layer
│   ├── errors.go               #   the Error / ErrorCode hierarchy
│   ├── data_handle.go          #   the RAII DataHandle (with side-data accessors)
│   ├── app_handle.go           #   the RAII AppHandle
│   ├── io.go                   #   unified JSON / string / byte I/O
│   ├── framework.go            #   the process-level facade + watchdog control
│   ├── options.go              #   typed option shortcuts (SetOpt* / GetOpt*)
│   ├── status.go               #   the status queue + health checks (including UID / P2PName)
│   ├── network_events.go       #   process-level network event callbacks
│   ├── p2p_registration.go     #   process-level P2P API registration
│   ├── address.go              #   the Target interface + the three addressing modes
│   ├── async.go                #   AsyncResult + the async dispatch primitives
│   └── client.go               #   the high-level Client facade + the process-level connection
│
├── cross/                      # ③ the cross-language demos
│   ├── cross-service/main.go   #   the coordinator
│   ├── cross-node/main.go      #   the worker node (registers add / inv_seri)
│   ├── cross-call/main.go      #   the concurrent load client
│   └── README.md
│
├── test/                       # ④ tests
│   ├── abi_smoke_test.go       #   library load + handle create/read/write/free
│   ├── abi_probe_test.go       #   the UID-argument ABI probe
│   ├── data_handle_test.go     #   scalar I/O, the three NUL states, JSON, JsonOrBytes
│   ├── errors_test.go          #   ErrorCode classification, errors.Is/As/Unwrap
│   ├── options_test.go         #   option round trips
│   ├── address_test.go         #   Target / UID helpers / the three addressing classes
│   ├── async_test.go           #   async argument validation + context + dispatch failure paths
│   └── e2e_test.go             #   the full in-process service+client flow
│
├── build.ps1                   # build script
├── test.ps1                    # test script
├── dev_test.ps1                # fast development feedback loop
└── clean.ps1                   # clean script
```

**The layering principle**: `sys` is the only layer that calls native code directly. `lingofuse` depends only on `sys` and never touches `purego` itself.

---

## 3. Installing and deploying

### 3.1 Getting the source

```bash
git clone https://github.com/PassByYou888/LingoFuse.git
cd LingoFuse/go
```

### 3.2 Configuring a Go module proxy (required in mainland China)

`proxy.golang.org` is unreachable in mainland China, so switch to a domestic mirror:

```powershell
go env -w GOPROXY=https://goproxy.cn,https://goproxy.io,direct
go env -w GOSUMDB=off
```

Or use the Aliyun / Tencent Cloud mirrors:

```powershell
go env -w GOPROXY=https://mirrors.aliyun.com/goproxy/,direct
# or
go env -w GOPROXY=https://mirrors.tencent.com/go/,direct
```

### 3.3 Downloading the dependencies

```powershell
cd D:\CoreLibrary\LingoFuse\go
go mod tidy
```

It pulls `github.com/ebitengine/purego v0.8.1`.

### 3.4 Placing the native library

At runtime the Go binding looks for the native library in the following order:

1. **the directory containing the executable**
2. **the `native/` subdirectory under the executable's directory**
3. **the current working directory**
4. **the system loader search path** (`PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`)

The simplest approach is to put it in the module root:

```powershell
Copy-Item ..\Binary\LingoFuse64.dll .
```

If you reference this binding from another project, put the DLL in **that project's executable directory**.

### 3.5 Referencing it from another project

```bash
# in your project directory
go get github.com/PassByYou888/LingoFuse/go
```

Then in `main.go`:

```go
import (
    "github.com/PassByYou888/LingoFuse/go/lingofuse"
)
```

At that point you must ensure `LingoFuse64.dll` is in the same directory as your executable (or on the system `PATH`).

---

## 4. Building

### 4.1 The one-key script

In the `go/` directory:

```powershell
# build all packages + vet + the three cross executables (output to go\bin\)
.\build.ps1

# skip vet (faster)
.\build.ps1 -SkipVet
```

`build.ps1` does the following:

1. runs `go build ./...` to compile every package
2. runs `go vet ./...` for static checks
3. compiles the three cross executables into `go\bin\`
4. copies the native library from `..\Binary\LingoFuse64.dll` into `go\bin\`

### 4.2 Building manually

```powershell
cd D:\CoreLibrary\LingoFuse\go

# compile check only (no artifacts)
go build ./...

# static checks
go vet ./...

# compile the cross executables
go build -o .\bin\cross-service.exe .\cross\cross-service
go build -o .\bin\cross-node.exe    .\cross\cross-node
go build -o .\bin\cross-call.exe    .\cross\cross-call
```

### 4.3 Cross-compiling

Because cgo is not used, cross-compiling only requires switching `GOOS` / `GOARCH`:

```powershell
$env:GOOS = "linux"; $env:GOARCH = "amd64"
go build ./...

$env:GOOS = "darwin"; $env:GOARCH = "arm64"
go build ./...

# restore
Remove-Item Env:\GOOS, Env:\GOARCH
```

**Note**: cross-compiling only compiles the Go code; at runtime you still need the target platform's native library (`liblingofuse.so` / `liblingofuse.dylib`).

### 4.4 Fast development feedback

```powershell
.\dev_test.ps1
```

It runs `go build ./... && go vet ./... && go test ./... -count=1` in one go and gives a red/green signal within seconds, without the verbose `-v` output.

### 4.5 Cleaning

```powershell
.\clean.ps1
```

It removes the `go\bin\` directory, the Go build cache and the Go test cache. It **does not delete** `LingoFuse64.dll` or any source code.

---

## 5. Testing

### 5.1 The one-key script

```powershell
# the full test run (unit + E2E integration)
.\test.ps1

# unit tests only, skipping E2E and the ABI probe (about 1 second)
.\test.ps1 -Short

# the ABI probe only (verify the UID-argument ABI after upgrading the shared library)
.\test.ps1 -Probe

# enable the race detector (requires gcc on PATH)
.\test.ps1 -Race

# one line of output per package (no verbose -v logs)
.\test.ps1 -Quiet
```

### 5.2 Testing manually

```powershell
cd D:\CoreLibrary\LingoFuse\go

# all tests
go test ./... -v

# the ABI smoke only
go test ./test/ -run 'TestLibrary|TestDataHandle|TestPermanent' -v

# the ABI probe only
go test ./test/ -run 'TestProbe' -v

# E2E only (about 25 seconds)
go test ./test/ -run 'TestE2E_' -v

# the error hierarchy tests only
go test ./test/ -run 'TestError|TestNullHandle|TestInvalid' -v

# the addressing target tests only
go test ./test/ -run 'TestAppTarget|TestUIDTarget|TestP2PNameTarget|TestTarget' -v

# the async tests only
go test ./test/ -run 'TestCallAsync|TestSequencedCallAsync|TestAsyncResult|TestCallCtx' -v
```

### 5.3 The test matrix

| Test file | Coverage | Duration |
|---------|---------|:----:|
| `abi_smoke_test.go` | library load, handle create/read/write/free, permanent handles | < 1 s |
| `abi_probe_test.go` | the UID-argument ABI probe, UID hex round trip | < 1 s |
| `data_handle_test.go` | scalar I/O, the three NUL states, exact-read, JSON, JsonOrBytes, Unicode fidelity | < 1 s |
| `errors_test.go` | ErrorCode classification, errors.Is/As/Unwrap, null-handle, invalid-argument | < 1 s |
| `options_test.go` | boolean/integer/string option round trips, the password mask, unknown options | < 1 s |
| `address_test.go` | the properties of the three addressing classes, the UID helpers, Target interface consistency | < 1 s |
| `async_test.go` | argument validation, Context cancellation, the synchronous callback path of an async dispatch failure | < 1 s |
| `e2e_test.go` | in-process service+client, LocalCall, Notify, callback panic isolation, TryCall on an empty response, Shutdown idempotence | ~25 s |

**Skip logic**: if the native library is unavailable, every test prints `[SKIP]` and **counts as passing** without erroring. That keeps CI environments without the native library green.

### 5.4 Process-level side effects of the E2E tests

`TestE2E_*` starts the process-level simulated main thread (`LF_PrepareDone`), therefore:

- each E2E test set up and tears down independently; after `Shutdown` the next test can call `PrepareDone` again.
- **do not** run several E2E tests concurrently in the same test process (Go's `go test` runs tests within a package serially by default, so no extra configuration is needed).
- the E2E tests print native-layer logs to stdout (`Main Thread Begin, LingoFuse-v3.10 ...`); that is **normal output**, not a test failure.

---

## 6. Quick start

### 6.1 The minimal runnable example

Save as `main.go`:

```go
package main

import (
    "fmt"
    "log"

    "github.com/PassByYou888/LingoFuse/go/lingofuse"
)

type AddArgs struct {
    A int `json:"a"`
    B int `json:"b"`
}

type AddResult struct {
    Sum int `json:"sum"`
}

func main() {
    // 1. create an app and register one Call API
    app, err := lingofuse.NewAppHandle("Calc", "Go calculator")
    if err != nil {
        log.Fatal(err)
    }
    defer app.Close()

    err = app.RegisterCall("add", "add two ints",
        func(input, output *lingofuse.DataHandle) {
            var args AddArgs
            if err := lingofuse.ReadJSON(input, &args); err != nil {
                return
            }
            _ = lingofuse.WriteJSON(output, AddResult{Sum: args.A + args.B})
        })
    if err != nil {
        log.Fatal(err)
    }

    // 2. prepare the network (self-connect: act as both service and client)
    _ = lingofuse.SetOption("Overlap_Connection", "True")
    _ = lingofuse.SetOption("Wait_Connection_ReadyOk", "False")
    _ = lingofuse.ResetPrepare()

    endpoint := "ipc:go_calc"
    if _, err := lingofuse.PrepareService(endpoint, endpoint); err != nil {
        log.Fatal(err)
    }
    if _, err := lingofuse.PrepareClient(endpoint, app); err != nil {
        log.Fatal(err)
    }
    started, err := lingofuse.PrepareDone()
    if err != nil || !started {
        log.Fatalf("PrepareDone: %v, %v", started, err)
    }

    // 3. call locally
    req, _ := lingofuse.NewDataHandle("add")
    defer req.Close()
    _ = lingofuse.WriteJSON(req, AddArgs{A: 5, B: 7})
    _ = req.SetPosition(0)

    res, err := app.LocalCall(req)
    if err != nil {
        log.Fatal(err)
    }
    defer res.Close()

    var out AddResult
    _ = lingofuse.ReadJSON(res, &out)
    fmt.Printf("5 + 7 = %d\n", out.Sum)

    // 4. clean up (strictly in the LF-CLEAN-001 order)
    _ = lingofuse.ExitMainThread()
    app.Close()
    _ = lingofuse.Shutdown()
}
```

Run it:

```powershell
go run main.go
```

Output:

```
5 + 7 = 12
```

### 6.2 Remote calls (the Client facade)

The `Client` facade is recommended for simplifying process-level connection management. It performs `PrepareClient` + `PrepareDone` automatically, and later calls reuse the same process-level connection:

```go
package main

import (
    "fmt"
    "log"
    "time"

    "github.com/PassByYou888/LingoFuse/go/lingofuse"
)

type AddArgs struct {
    A int `json:"a"`
    B int `json:"b"`
}

type AddResult struct {
    Sum int `json:"sum"`
}

func main() {
    // the first Connect does the real network setup; the second and later ones return the same connection.
    c := lingofuse.MustConnect("Calc", "ipc:go_calc",
        lingofuse.WithTimeout(3*time.Second))

    // synchronous call: 5 + 7
    res, err := c.Call("add", AddArgs{A: 5, B: 7}, 0)
    if err != nil {
        log.Fatal(err)
    }
    defer res.Close()

    var out AddResult
    _ = lingofuse.ReadJSON(res, &out)
    fmt.Printf("5 + 7 = %d\n", out.Sum)

    // asynchronous call: fire-and-forget, the result is handled in the callback
    done := make(chan struct{})
    err = c.CallAsync("add", AddArgs{A: 40, B: 2},
        func(r lingofuse.AsyncResult) {
            defer close(done)
            if r.Err != nil {
                log.Printf("async failed: %v", r.Err)
                return
            }
            var v AddResult
            _ = lingofuse.ReadJSON(r.Value, &v)
            fmt.Printf("40 + 2 = %d (async)\n", v.Sum)
        })
    if err != nil {
        log.Fatal(err)
    }
    <-done

    _ = lingofuse.ExitMainThread()
    _ = lingofuse.Shutdown()
}
```

`TryCall` returns `(*DataHandle, bool, error)`:

- `(handle, true, nil)` — success
- `(nil, false, nil)` — timed out or the target is unreachable
- `(nil, false, err)` — a null handle or a load failure

### 6.3 The three addressing modes

Besides App-name addressing, LingoFuse also supports UID and P2PName addressing. All three share the same `Target` interface:

```go
// App-name addressing: local first
app := lingofuse.App("Calc")
res, _ := app.Call("add", AddArgs{A: 1, B: 2}, 3000)

// UID addressing: targeted at a specific session (local first)
var uid sys.TP2P_UID = ...  // obtained through a whoami probe
uidTgt := lingofuse.UID(uid)
res, _ = uidTgt.Call("add", AddArgs{A: 1, B: 2}, 3000)

// P2PName addressing: load-balancing within the group (always over the network)
p2p := lingofuse.P2P("workers")
res, _ = p2p.Call("add", AddArgs{A: 1, B: 2}, 3000)
```

All three are also available through the `Client` facade:

```go
c := lingofuse.MustConnect("Calc", "ipc:go_calc")
app := c.App("Calc")
uidTgt := c.UID(uid)
p2p := c.P2P("workers")
```

### 6.4 The whoami pattern (discovering your own UID)

To obtain its own UID, a client needs a server-side API that reads the side data:

```go
// server: read the caller's UID and send it back
app.RegisterCall("whoami", "echo caller identity",
    func(inp, out *lingofuse.DataHandle) {
        uid, _ := inp.GetP2PUID()   // 32-byte side data
        name, _ := inp.GetP2PName() // the sender's P2P name
        _ = lingofuse.WriteJSON(out, map[string]string{
            "uid_hex":  sys.FormatUIDHex(uid),
            "p2p_name": name,
        })
    })

// client: call whoami and cache the returned UID
res, _ := lingofuse.App("WhoamiSvc").Call("whoami", nil, 3000)
```

**Note**: a UID is regenerated on every `TunnelLink`. After a link drops and reconnects, you must probe again.

---

## 7. The cross-language Cross Demo

The three programs under `cross/` can run **mixed** with the same-named programs of C++ / C# / Pascal / Python / JavaScript. The wire format is byte-for-byte identical:

### 7.1 The API wire formats

**`add`**

```
input  : int32 LE + int32 LE
output : int32 LE
```

**`inv_seri`**

```
input  : uint8 + uint16 LE + uint32 LE + uint64 LE + string(NUL) + float32 LE
output : float32 LE + string(NUL) + uint64 LE + uint32 LE + uint16 LE + uint8
```

Strings are UTF-8 encoded and terminated by `0x00`. All integers and floats are little-endian.

### 7.2 Running a single language (all Go)

Run `.\build.ps1` first, then open three terminals:

**Terminal 1 — the coordinator**

```powershell
cd D:\CoreLibrary\LingoFuse\go\bin
.\cross-service.exe
```

Wait for `[Service] IPC service 'ipc:cross' is running.`

**Terminal 2 — the worker node**

```powershell
cd D:\CoreLibrary\LingoFuse\go\bin
.\cross-node.exe
```

Wait for `[Node] Online.`

**Terminal 3 — the load-test client**

```powershell
cd D:\CoreLibrary\LingoFuse\go\bin
.\cross-call.exe
```

It prints a summary after 10 seconds.

### 7.3 Running across languages

Replace any one of the three terminals with the implementation from another language, for example:

- **terminal 2** replaced by `Binary\CrossNode.exe` (the C++ node)
- **terminal 3** replaced by `node ..\js\cross\cross-call.js` (the JS client)

Whatever the combination, `add` and `inv_seri` always round-trip successfully.

### 7.4 The shutdown order

Strictly the reverse of startup:

1. close the **client** (cross-call)
2. close the **node** (cross-node)
3. close the **coordinator** (cross-service)

Each program cleans up automatically on exit in the order `ExitMainThread → app.Close → Shutdown`.

---

## 8. API quick reference

### 8.1 The `lingofuse` package

#### Construction / lifetime

| Function | Notes |
|------|------|
| `NewDataHandle(apiName) (*DataHandle, error)` | create an auto-reclaimed handle (reclaimed after 10 minutes of idleness) |
| `CreatePermanent(apiName) (*DataHandle, error)` | create a permanent handle that is never auto-reclaimed |
| `(*DataHandle).Close()` | free the handle, idempotent |
| `NewAppHandle(name, desc) (*AppHandle, error)` | create an app |
| `(*AppHandle).Close()` | detach the app, idempotent |

#### `DataHandle` I/O

| Method | Notes |
|------|------|
| `WriteBytes([]byte) / ReadBytes(n)` | raw bytes |
| `ReadBytesExact(n) / TryReadBytes(n)` | exact read; on failure returns an error / false |
| `ReadAllBytes()` | read to the end of the buffer |
| `WriteString(s) / ReadString()` | NUL-framed UTF-8 |
| `ReadStringBytes()` | NUL-framed raw bytes |
| `WriteInt8/16/32/64 / WriteUint8/16/32/64` | little-endian scalars |
| `WriteSingle/WriteDouble` | little-endian floats |
| `Position() / SetPosition(pos)` | the read/write cursor |
| `Size() / SetSize(n)` | the buffer size |
| `GetP2PUID() (sys.TP2P_UID, error)` | read the sender's UID (**callback input handles only**) |
| `GetP2PName() (string, error)` | read the sender's P2P name (**callback input handles only**) |

#### JSON I/O

| Function | Notes |
|------|------|
| `WriteJSON(h, v) error` | serialise + write + NUL terminator (**HTML escaping off**) |
| `ReadJSON(h, &v) error` | read to the NUL + deserialise |
| `TryReadJSON(h, &v) (bool, error)` | the non-panicking version |
| `ReadJSONOrBytes(h) (JsonOrBytes, error)` | lenient reading (the three states Empty / JSON / Bytes) |
| `MarshalJSON(v) (string, error)` | serialise to a compact UTF-8 string |
| `UnmarshalJSON(text, &v) error` | deserialise |

#### `AppHandle`

| Method | Notes |
|------|------|
| `RegisterCall(name, desc, handler) error` | register a Call API |
| `RegisterNotify(name, desc, handler) error` | register a Notify API |
| `Unregister(name) (bool, error)` | unregister an API |
| `LocalCall(param) (*DataHandle, error)` | in-process call |
| `LocalNotify(param) error` | in-process notification |
| `Bind() (int, error)` | bind to an idle client |
| `Name() / Raw() / IsValid()` | state queries |

#### The process-level facade

| Function | Notes |
|------|------|
| `ResetPrepare() error` | clear the preparation queue |
| `PrepareService(listen, physics) (int, error)` | prepare a service endpoint |
| `PrepareClient(addr, app) (int, error)` | prepare a client; `app` may be nil |
| `PrepareDone() (bool, error)` | start the framework; returns true only once per process |
| `ExitMainThread() error` | stop the main thread; clears the handle pool |
| `Call(appName, param, timeoutMs) (*DataHandle, error)` | remote synchronous call |
| `TryCall(appName, param, timeoutMs) (*DataHandle, bool, error)` | remote call; returns `(nil, false, nil)` on timeout |
| `Notify(appName, param) error` | one-way notification |
| `SequencedNotify(appName, param) error` | FIFO one-way notification |
| `SetOption(name, value) error` | set a runtime option |
| `GetOption(name) (string, error)` | read a runtime option |
| `GenerateAppName() (string, error)` | generate a globally unique app name |
| `GetAppName(app) (string, error)` | query an app name |
| `Shutdown() error` | fully shut down; **also clears the local P2P registry**; idempotent |

#### Watchdog control

| Function | Notes |
|------|------|
| `DisableDeadlockWatchdog()` | disable the LingoFuse deadlock watchdog (**use with care**, see §9.7) |
| `IsDeadlockWatchdogEnabled() bool` | query the watchdog state |

#### Typed options (`options.go`)

| Function | Option key | Type |
|------|--------|------|
| `SetOptQuiet(bool) / GetOptQuiet()` | `Quiet` | bool |
| `SetOptShowThreadID(bool) / GetOptShowThreadID()` | `ShowThreadID` | bool |
| `SetOptConsoleOutput(bool) / GetOptConsoleOutput()` | `ConsoleOutput` | bool |
| `SetOptOverlapConnection(bool) / GetOptOverlapConnection()` | `Overlap_Connection` | bool |
| `SetOptWaitConnectionReadyOk(bool) / GetOptWaitConnectionReadyOk()` | `Wait_Connection_ReadyOk` | bool |
| `SetOptWaitConnectionTimeout(ms) / GetOptWaitConnectionTimeout()` | `Wait_Connection_Timeout` | uint64 |
| `SetOptP2PName(str) / GetOptP2PName()` | `LF_P2P_name` | string |
| `SetOptPassword(str) / GetOptPassword()` | `password` | string (masked) |
| `SetOptDebug(str) / GetOptDebug()` | `debug` | string (write-only) |
| `SetOptIPCServThreadCount(int) / GetOptIPCServThreadCount()` | `IPC_Serv_ThreadCount` | int |
| `SetOptIPCServMaxQueueLength(int) / GetOptIPCServMaxQueueLength()` | `IPC_Serv_MaxQueueLength` | int |
| `SetOptIPCServMaxMsgSize(int) / GetOptIPCServMaxMsgSize()` | `IPC_Serv_MaxMsgSize` | int |
| `SetOptFixedSequencedTime(ms) / GetOptFixedSequencedTime()` | `Fixed_Sequenced_Time` | uint64 |
| `SetOptDataHandleIdleTimeout(ms) / GetOptDataHandleIdleTimeout()` | `DataHandle_Idle_Timeout` | uint64 |
| `SetOptDataHandlePoolScanInterval(ms) / GetOptDataHandlePoolScanInterval()` | `DataHandle_Pool_Scan_Interval` | uint64 |
| `SetOptNoReponseCmdNullFlushThreshold(int) / GetOptNoReponseCmdNullFlushThreshold()` | `No_Reponse_Cmd_NULL_Flush_Threshold` | int |

#### Process-level P2P registration (`p2p_registration.go`)

| Function | Notes |
|------|------|
| `RegisterP2PCall(name, desc, handler) error` | register a process-level P2P Call API |
| `RegisterP2PNotify(name, desc, handler) error` | register a process-level P2P Notify API |
| `UnregisterP2P(name) (bool, error)` | unregister a single P2P API |
| `ResetP2PRegistrations()` | **release all** local P2P registrations in bulk (`Shutdown` calls it automatically) |
| `IsP2PRegistered(name) bool` | diagnostic: whether an API is already registered |

#### Status and health checks

| Function | Notes |
|------|------|
| `GetStatusCount() (int, error)` | the number of pending log entries |
| `GetStatus() (string, error)` | take one log entry |
| `DrainStatus(n) ([]string, error)` | take log entries in bulk |
| `PostStatus(msg) error` | inject a log entry |
| `CheckMainThread() (bool, error)` | whether the main thread is running |
| `CheckApp(name) (bool, error)` | whether an app is visible (with a ~3 second cache delay) |
| `CheckApi(app, api) (bool, error)` | whether an API is visible (same as above) |
| `CheckUID(uid) (bool, error)` | whether a UID is online (same as above) |
| `CheckUIDApi(uid, api) (bool, error)` | whether a UID exposes an API (same as above) |
| `CheckP2PName(name) (bool, error)` | whether a P2P group exists (same as above) |
| `CheckP2PNameApi(name, api) (bool, error)` | whether a P2P group exposes an API (same as above) |

#### Network events

| Function | Notes |
|------|------|
| `SetNetworkEvent(onConnect, onDisconnect) error` | install the global callbacks; pass nil to disable |
| `ClearNetworkEvent() error` | remove both callbacks |
| `IsNetworkEventInstalled() bool` | whether callbacks are installed |

#### Addressing targets (`address.go`)

| Type / function | Notes |
|-------------|------|
| `Target` | the interface shared by the three addressing modes |
| `AppTarget` / `NewAppTarget(name)` / `App(name)` | App-name addressing (local first) |
| `UIDTarget` / `NewUIDTarget(uid)` / `UID(uid)` | UID addressing (local first) |
| `P2PNameTarget` / `NewP2PNameTarget(group)` / `P2P(group)` | P2PName addressing (not local first) |
| `(*AppTarget).Name() / (*UIDTarget).UID() / (*P2PNameTarget).Group()` | access the addressing key |

**The `Target` interface methods**:

| Method | Blocking? | Callable inside a callback? | Notes |
|------|:------:|:--------------:|------|
| `Call(api, payload, timeoutMs) (*DataHandle, error)` | yes | ❌ | synchronous request-response |
| `CallCtx(ctx, api, payload) (*DataHandle, error)` | yes | ❌ | synchronous request with a context |
| `CallAsync(api, payload, cb func(AsyncResult)) error` | no | ✅ | asynchronous request (callback style) |
| `CallAsyncWithTimeout(api, payload, timeout, cb) error` | no | ✅ | asynchronous + a Go-side timeout |
| `SequencedCall(api, payload, timeoutMs) (*DataHandle, error)` | yes | ❌ | FIFO synchronous request |
| `SequencedCallCtx(ctx, api, payload) (*DataHandle, error)` | yes | ❌ | FIFO + context |
| `SequencedCallAsync(api, payload, cb func(AsyncResult)) error` | no | ✅ | FIFO asynchronous request |
| `Notify(api, payload) error` | no | ✅ | one-way notification |
| `SequencedNotify(api, payload) error` | no | ✅ | FIFO one-way notification |
| `Describe() string` | no | ✅ | return a description of the addressing |

#### `AsyncResult`

```go
type AsyncResult struct {
    Value *DataHandle // the response handle (**borrowed**, invalid once the callback returns)
    Err   error       // when non-nil, Value is necessarily nil
}
```

**Ownership contract**:
- `Value` is a **borrowed** handle, valid only inside the callback body; **it becomes invalid the moment the callback returns**.
- **Do not** `Close()` that handle.
- **Do not** pass `Value` or its raw pointer out of the callback body.

#### The high-level `Client` facade (`client.go`)

| Function / method | Notes |
|------------|------|
| `Connect(app, endpoint, opts...) (*Client, error)` | the first call does the real network setup; later calls reuse the connection |
| `MustConnect(...) *Client` | the panicking version of Connect, suited to `main()` or package-level initialisation |
| `IsConnected() bool` | whether the process-level connection has been established |
| `LastConnectError() error` | the error of the most recent failed Connect |
| `WithTimeout(d) ClientOption` | set the default call timeout |
| `(*Client).App(name) *AppTarget` | build an App-name addressing target |
| `(*Client).UID(uid) *UIDTarget` | build a UID addressing target |
| `(*Client).P2P(group) *P2PNameTarget` | build a P2PName addressing target |
| `(*Client).DefaultTarget() *AppTarget` | shortcut for the default target |
| `(*Client).Call / TryCall / Notify / ...` | forwarded to `DefaultTarget()` |
| `(*Client).DefaultAppName() / Endpoint() / Timeout()` | access the read-only properties |

**Constraints**:
- **One process has exactly one connection**. The first `Connect` decides the endpoint; later `Connect` calls ignore the endpoint argument.
- `Client` has **no `Close()`**: the connection's lifetime is process-level and is not owned by the `Client` instance.

#### Errors

```go
type Error struct {
    Code    ErrorCode
    Message string
    Cause   error
}
```

`ErrorCode` constants: `ErrGeneric` / `ErrLibraryLoadFailed` / `ErrNullHandle` / `ErrInvalidArgument`
/ `ErrWriteFailed` / `ErrReadFailed` / `ErrCallFailed` / `ErrRegistrationFailed`
/ `ErrNotConnected` / `ErrTimeout` / `ErrAsyncDispatchFailed`

Classify with `errors.Is(err, &lingofuse.Error{Code: lingofuse.ErrTimeout})`, or
recover the `*lingofuse.Error` struct with `errors.As(err, &le)`.

### 8.2 The `sys` package

`sys` is the low-level FFI layer and ordinary users **should not** use it directly. It exposes:

- `sys.LoadLibrary() error` — load the native library explicitly
- 59 function variables (`LF_CreateData` / `LF_Call` / ...), all mirroring the C ABI
- `sys.CStringScope` / `sys.CString` / `sys.GoString` — C string helpers
- `sys.TP2P_UID` / `sys.NullUID` / `sys.IsNullUID` / `sys.ParseUIDHex` / `sys.FormatUIDHex` — UID helpers
- `sys.RegisterCallCallback` / `sys.RegisterNotifyCallback` / `sys.RegisterAsyncCallback` — callback registration
- `sys.DisableDeadlockWatchdog` / `sys.IsDeadlockWatchdogEnabled` — watchdog control (re-exported through `lingofuse`)

---

## 9. Core concepts

### 9.1 The three call modes

| Mode | Semantics | Ordering guarantee | Return value |
|------|------|:--------:|:------:|
| **Call** | request-response, synchronous or asynchronous | — | ✅ |
| **Notify** | one-way notification | ❌ | ❌ |
| **Sequenced Notify** | one-way notification | ✅ (FIFO within the same `(app, api)` pair) | ❌ |

### 9.2 The three addressing modes

| Mode | Routing key | Local first? | Load balancing? | Typical use |
|------|--------|:----------:|:----------:|---------|
| **AppTarget** | the App name string | ✅ | ❌ | fixed service discovery |
| **UIDTarget** | a 32-byte UID | ✅ | ❌ | targeted at a specific session |
| **P2PNameTarget** | the group name string | ❌ | ✅ (server side) | clusters of homogeneous services |

- **App name / UID**: local first. If this process has already registered an app of the same name or a client with the same UID, it executes locally.
- **P2PName**: **no local lookup**. Even if this process contains a client of the same group, the call is forwarded to the server for load balancing.
- **A UID is regenerated on every TunnelLink**: caching a UID across reconnects is unsafe; you must probe again.

### 9.3 The lifetime of a data handle

```
NewDataHandle(api)        →  the auto-reclaim pool, reclaimed after 10 minutes of idleness (scan interval 5 seconds)
CreatePermanent(api)      →  not pooled, never auto-reclaimed
Close()                   →  auto-reclaim: only marks deleted; permanent: frees synchronously
```

**Do not rely on auto-reclaim.** Auto-reclaim is a safety net, not a substitute. In production you must call `Close()` explicitly.

### 9.4 The callback contract

Callbacks run on the native library's background worker threads. Inside a callback the following is **forbidden**:

- ❌ blocking (`time.Sleep`, waiting on a channel, long I/O)
- ❌ calling any **synchronous** LingoFuse function:
  - `lingofuse.Call` / `TryCall`
  - `Target.Call` / `CallCtx` / `SequencedCall` / `SequencedCallCtx`
  - `AppHandle.LocalCall` / `LocalNotify`
  - `lingofuse.PrepareDone` / `Shutdown` / `ExitMainThread`
  - **this self-deadlocks** — the callback holds an internal lock, and the synchronous call needs the same lock to deliver the response
- ❌ touching the UI (if bound to a GUI)
- ❌ `Close()` on a borrowed handle (input / output are managed by the native layer)

Inside a callback the following is **allowed**:

- ✅ reading `input`, writing `output`
- ✅ reading the sender's side data through `input.GetP2PUID()` / `input.GetP2PName()`
- ✅ accessing shared state protected by `sync.Mutex`
- ✅ **calling async APIs**: `Target.CallAsync` / `SequencedCallAsync`
- ✅ **sending one-way notifications**: `Target.Notify` / `SequencedNotify` / `lingofuse.Notify`
- ✅ panicking — the Go wrapper recovers inside the trampoline, so the native layer sees "the callback returned normally" with empty output

### 9.5 Side data: UID / P2PName

On the **sender** side the LingoFuse framework automatically writes two identity fields into the header of every request payload:

- `FromUID` (32 bytes) — the sender's session UID
- `FromP2PName` (UTF-8 string) — the sender's P2P group name

The receiver can only read them on the **`input` argument of the callback that fired the event**:

| Location | Valid? |
|------|:------:|
| the `input` of an `On_Call` / `On_Notify` callback | ✅ |
| the `input` of a `LocalCall` / `LocalNotify` callback | ✅ |
| the callback's `output` | ❌ (zero-filled / empty) |
| a handle you created with `NewDataHandle()` | ❌ (same as above) |

When you call an invalid location the native layer **does not throw**; it only prints a warning and returns a zero UID / an empty string.

**C ABI layer**: `LF_Get_P2P_UID` returns `const TP2P_UID*` (**a pointer**, not a value). The framework frees the pointer about 5 seconds after the call. The Go wrapper's `DataHandle.GetP2PUID()` copies the 32 bytes into a Go value immediately, so the caller never touches the raw pointer.

### 9.6 The JSON serialisation strategy (byte-level cross-language consistency)

The Go binding's JSON output is **byte-for-byte identical** to C++ / Python / JavaScript:

| Property | Go implementation | Comparison with the other languages |
|------|---------|---------------|
| **compact output** | `strings.TrimRight(buf, "\n")` | ✅ matches C++ `dump(-1)` / JS `JSON.stringify` |
| **literal UTF-8 for non-ASCII** | default (`encoding/json` does not escape CJK / emoji) | ✅ matches C++ `ensure_ascii=false` / Python `ensure_ascii=False` |
| **HTML escaping off** | `enc.SetEscapeHTML(false)` | ✅ matches the other languages (**Go escapes `<` `>` `&` U+2028 U+2029 by default and that must be turned off explicitly**) |

**The key point**: Go's `encoding/json.Marshal` escapes `<`, `>`, `&`, `U+2028` and `U+2029` as HTML by default. That is a Go security feature (to prevent XSS), but it is inconsistent with the other languages in the LingoFuse toolchain. The Go binding turns it off explicitly with `json.Encoder.SetEscapeHTML(false)`, guaranteeing byte-level cross-language consistency.

### 9.7 The deadlock watchdog

**The problem**: `purego` does not use cgo, so the Go runtime **cannot see** LingoFuse's native worker threads. When a user goroutine blocks waiting for an async callback (on a `sync.WaitGroup`, say), the runtime wrongly concludes "all goroutines are asleep" and hard-crashes the whole process with `throw("all goroutines are asleep - deadlock!")` — even though the C side is actually working fine and would have called back microseconds later.

**The solution**: the Go binding starts a **recursive timer** in `init()` (it fires once per hour and reschedules itself immediately). That keeps a pending event in the runtime's timer heap at all times, so the runtime concludes "the program still has work to do" and does not misjudge the situation as a deadlock.

**Controllability**:

```go
// enabled by default. Turn it off if you have no blocking async-callback scenarios.
lingofuse.DisableDeadlockWatchdog()

// query the current state
lingofuse.IsDeadlockWatchdogEnabled()
```

**The cost of turning it off**: Go's built-in deadlock detection comes back. **If your application has a scenario where one goroutine blocks waiting for a native async callback while no other goroutine can run, the runtime hard-crashes.**

**Recommendation**:
- **keep the default (enabled)**: safer, and the cost is negligible (one timer event per hour).
- **turn it off only when you definitely do not use async callbacks, or the application already has another always-pending timer.**

### 9.8 Ownership of `AsyncResult`

`AsyncResult` is received by the async callback:

```go
tgt.CallAsync("api", payload, func(r AsyncResult) {
    if r.Err != nil {
        // the error branch: r.Value is necessarily nil
        return
    }
    // the success branch: r.Value is a **borrowed** handle
    // ✅ allowed: read the data inside the callback body
    data, _ := lingofuse.ReadStringBytes(r.Value)
    // ...
    // ❌ forbidden: Close(r.Value) — a double free
    // ❌ forbidden: storing r.Value in a global variable or passing it to another goroutine
})
```

**Four hard rules**:
1. read or copy the data **inside the callback body**.
2. **do not** `Close(r.Value)`.
3. **do not** pass `r.Value` (or its raw pointer) out of the callback body.
4. **do not** access `r.Value` at any point outside the callback body.

### 9.9 The Client facade (singleton semantics)

The LingoFuse framework is a **process-level singleton**: one simulated main thread, one client pool, one service pool. `Client` is therefore not an independent connection:

```go
c1 := lingofuse.MustConnect("AppA", "ipc:endpoint1")
c2 := lingofuse.MustConnect("AppB", "ipc:endpoint2")
// c2 reuses the process-level connection established by c1; the endpoint2 argument is ignored
```

**Constraints**:
- the first `Connect` decides the endpoint; later `Connect` calls only record diagnostics.
- `Client` has **no `Close()`**: the connection is not released with the `Client`.
- release the connection with the package-level `ExitMainThread` or `Shutdown`.

### 9.10 The three states of a NUL-framed string

`ReadString()` / `ReadStringBytes()` / `ReadJSON()` follow the same three-state rule:

| Case | Behaviour |
|------|------|
| a NUL was found | return the bytes before the NUL; advance the cursor past the NUL |
| no NUL was found | return all remaining bytes; advance the cursor to "end of buffer + 1" |
| the cursor is already at the end | return an empty string; the cursor is unchanged |

This is **exactly the same** as the bindings of the other five languages, so HTTP bridges, browsers and hand-written clients all interoperate correctly.

### 9.11 The single-shot semantics of `PrepareDone`

`PrepareDone` **returns `true` only once** in the same process. The second call returns `(false, nil)` — **that is not a failure**; the framework is simply already running.

If you need to reinitialise (for a test, say):

```go
_ = lingofuse.Shutdown()
_ = lingofuse.ResetPrepare()
// PrepareService / PrepareClient again
started, _ := lingofuse.PrepareDone()  // returns true again
```

**`Shutdown` clears the local P2P registry** — a fix specific to the Go binding: without that cleanup, you cannot re-register a P2P API of the same name after a restart.

---

## 10. Iron rules

Violating any one of them causes a crash, a deadlock or data corruption.

1. **Callbacks must use the native signature**: `LfCallFunc` / `LfNotifyFunc` / `LfAsyncCallOnResult` in the `sys` layer use the `cdecl` calling convention, which the Go wrapper already handles inside `purego.NewCallback`. Users only need the Go signatures of `lingofuse.CallHandler` / `NotifyHandler`.

2. **Do not call synchronous LingoFuse functions inside a callback**: `lingofuse.Call` / `Target.Call` / `Target.CallCtx` / `Target.SequencedCall` / `AppHandle.LocalCall` / `PrepareDone` / `Shutdown` all self-deadlock. **To make a follow-up call from inside a callback you must use `CallAsync` / `SequencedCallAsync`**.

3. **Data handles must be `Close()`d explicitly**: auto-reclaim means 10 minutes of idleness plus a 5-second scan delay; it is not a substitute.

4. **The cleanup order is fixed**: `ExitMainThread → app.Close → Shutdown`.

5. **`PrepareDone` succeeds only once per process**: `false` on the second call does not mean failure. To restart you must `Shutdown` first.

6. **`LingoFuse64.dll` must be discoverable at runtime**: the executable directory / the `native/` subdirectory / the current working directory / the system loader path — any one of the four.

7. **`AsyncResult.Value` of an async call is a borrowed handle**: valid only inside the callback body. It becomes invalid the moment the callback returns. Do not `Close` it and do not pass it out.

8. **Side data is only valid on `input`**: `GetP2PUID` / `GetP2PName` may only be called on the callback's `input` argument. Calling them on `output` or on a self-created handle returns a zero value plus a warning.

9. **`Client` is a process-level singleton without `Close()`**: the connection is not released with the `Client`. Release it with the package-level `ExitMainThread` / `Shutdown`.

10. **The local P2P registry is cleared after `Shutdown`**: that is deliberate (it guarantees the framework can restart). To reset the registry while running, use `ResetP2PRegistrations`.

---

## 11. Troubleshooting

### 11.1 Load failure

```
lingofuse: failed to load the native library; tried:
  - D:\myproj\myapp.exe (as dir) \ LingoFuse64.dll
      error: The specified module could not be found.
  - D:\myproj\native\LingoFuse64.dll
      error: The specified module could not be found.
  - D:\myproj\LingoFuse64.dll
      error: %1 is not a valid Win32 application.
system-loader fallback error: The specified module could not be found.
```

**Cause**: the DLL is not on any search path, or a **mismatched-architecture** DLL sits on the path.

**Handling**:
- read the error line by line: `%1 is not a valid Win32 application` means a DLL was found at that path but its architecture is wrong (a 64-bit program found a 32-bit DLL, for example).
- copy the correct DLL into the executable's directory.

### 11.2 A missing symbol

```
lingofuse: failed to register symbol "LF_CreateData_Permanent"
    (panic: purego: symbol LF_CreateData_Permanent not found)
```

**Cause**: the local `LingoFuse64.dll` is too old (older than 3.09). `LF_CreateData_Permanent` was introduced in 3.09.

**Handling**: take the newest version from the main repository's `Binary/` directory, or rebuild from source.

### 11.3 Call timeout

```go
res, ok, err := lingofuse.TryCall("MyApp", req, 3000)
// ok == false, err == nil  →  timeout or unreachable target
```

**Cause**:

1. the target app is not registered: `CheckApp("MyApp")` returns false
2. the network is unreachable
3. the target service starts too slowly

**Handling**:

```go
for i := 0; i < 15; i++ {
    if ok, _ := lingofuse.CheckApp("MyApp"); ok {
        break
    }
    time.Sleep(200 * time.Millisecond)
}
```

Alternatively set `Wait_Connection_ReadyOk` to `"True"` so `PrepareDone` blocks and waits.

### 11.4 A callback produces no output

**Cause**: the callback may not be registered, its registration may have failed, or a panic inside it may have been silently swallowed.

**Handling**:

- check the error returned by `RegisterCall` immediately (usually a duplicate API name)
- **do not use a bare `panic`** inside the callback; print diagnostics with `fmt.Fprintf(os.Stderr, ...)`

### 11.5 Deadlock (a synchronous function called inside a callback)

**Symptoms**: the process hangs, no log output, and Ctrl+C cannot exit it (except by force-killing).

**Cause**: a **synchronous** function such as `lingofuse.Call` / `Target.Call` / `AppHandle.LocalCall` was called inside a callback. The callback holds an internal lock, and the synchronous call needs the same lock to deliver the response → self-deadlock.

**Handling**:
- replace the synchronous call with **`CallAsync` / `SequencedCallAsync`**.
- or return from the callback and let the caller (a thread outside the callback) make the synchronous call.

**Verification**: `$env:GOTRACEBACK = "all"; go run main.go`, then press `Ctrl+\` (Unix) or `Ctrl+Break` (Windows) once it hangs to dump the stacks of all goroutines and find the one blocked in `lingofuse.Call`.

### 11.6 JSON output inconsistent with the other languages

**Symptoms**: a Go service returns `{"msg":"\u003chello\u003e"}`, while a C++ / Python service returns `{"msg":"<hello>"}`.

**Cause**: a custom serialiser was used with **HTML escaping left on** (calling `json.Marshal` directly, say).

**Handling**:
- use `lingofuse.WriteJSON` / `lingofuse.MarshalJSON` (HTML escaping is already off).
- if you serialise yourself, make sure you use `json.Encoder` + `SetEscapeHTML(false)`.

### 11.7 The IPC queue is already occupied

```
[IPC] Queue "ipc:cross0" is already occupied...
```

**Cause**: the previous program did not exit cleanly and the IPC queue was left behind.

**Handling**:

- close every leftover process
- or use a different endpoint name (`ipc:cross_v2`, say)

### 11.8 P2P registration fails after the framework restarts

**Symptoms**: after `Shutdown` → `PrepareDone`, `RegisterP2PCall` returns `ErrRegistrationFailed`, reporting "already registered".

**Cause (**fixed**)**: an older version's `Shutdown` did not clean up the Go-side `p2pRegistry`.

**Current state**: the Go binding's `Shutdown` calls `ResetP2PRegistrations` automatically. If you see this symptom, make sure you are on the newest version.

**Manual handling (if needed)**: call `lingofuse.ResetP2PRegistrations()` explicitly before `Shutdown`.

### 11.9 Using `AsyncResult.Value` outside the async callback

**Symptoms**: accessing `r.Value` after the callback returns gives garbage data, crashes, or occasionally works.

**Cause**: `AsyncResult.Value` is a **borrowed** handle; the framework frees the underlying buffer **immediately** when the callback returns. Using it afterwards is a use-after-free; `Close()`ing it is a double free.

**What you see depends on the payload size**: a small payload looks "normal" (the allocator has not reused that memory yet), while a large payload returns garbage (it has been reused).

**Handling**: **copy the data immediately** inside the callback body and use the copied bytes outside it.

### 11.10 `go mod tidy` times out

**Cause**: `proxy.golang.org` is blocked.

**Handling**: see §3.2, configure `GOPROXY` to a domestic mirror.

### 11.11 Cross-compilation succeeds but the runtime crashes

**Symptoms**: `GOOS=windows GOARCH=amd64 go build` succeeds, but at runtime it panics with `invalid memory address`.

**Cause**: cross-compiling only compiles the Go code. If you build a Windows binary on a non-Windows platform but copy a Linux `liblingofuse.so` next to the executable, it fails at runtime because of an architecture or format mismatch.

**Handling**: running on a target platform requires **that platform's native library**:
- Windows → `LingoFuse64.dll`
- Linux → `liblingofuse.so`
- macOS → `liblingofuse.dylib`

### 11.12 False positives from the deadlock watchdog

**Symptoms**: while the program blocks waiting for an async callback, the runtime prints `fatal error: all goroutines are asleep - deadlock!` and hard-crashes.

**Cause**: the deadlock watchdog was explicitly disabled (`lingofuse.DisableDeadlockWatchdog()`), or user code overrode the watchdog timer.

**Handling**: make sure the watchdog is enabled:

```go
if !lingofuse.IsDeadlockWatchdogEnabled() {
    log.Println("warning: deadlock watchdog is disabled")
}
```

If it has been disabled, re-enabling it requires restarting the process (once off, the watchdog cannot be turned back on).

---

## 12. Differences from the other language bindings

| Dimension | Pascal | C++ | C# | Rust | **Go** |
|------|:------:|:---:|:--:|:----:|:------:|
| FFI method | static linking | dynamic loading (hand-written) | P/Invoke | libloading | **purego** |
| Needs a C compiler | ❌ | ✅ | ❌ | ❌ | ❌ |
| Error handling | exceptions / return values | `std::exception` | `Exception` | `Result<T, E>` | **`(T, error)`** |
| Resource release | `Free_Data` | RAII | `IDisposable` | `Drop` | **explicit `Close()` + `defer`** |
| Callback mechanism | function pointer | `std::function` | `Delegate` | `Box<dyn Fn>` | **`sync.Map` + trigger ID** |
| Callback panic isolation | in-library `try/except` | user `try/catch` | automatic | user `catch_unwind` | **automatic recover in the wrapper** |
| Data handle type | `PLF_Data` record | `lingofuse::DataHandle` class | `DataHandle` class | `DataHandle` struct | **`*DataHandle` pointer** |
| Scalar I/O | `LF_WriteInt32` etc. | `write<int32_t>` | `WriteInt32` | `write(42i32)` | **`WriteInt32(42)`** |
| Three addressing modes | built in | built in | built in | built in | **the `Target` interface** |
| JSON HTML escaping | N/A (no such concept) | **off** | **off** | **off** | **off** (must be configured explicitly) |
| Deadlock watchdog | N/A (no runtime) | N/A (no runtime) | N/A (no runtime) | N/A (no runtime) | **configurable** (Go-specific) |

**Designs unique to Go**:

- **Errors instead of exceptions**: Go has no exception mechanism; everything is returned as `(value, error)`. `TryCall` / `TryReadBytes` / `TryReadString` offer "no error" versions returning the three-state `(value, bool, error)`.
- **Callbacks mapped through a `trigger` ID**: the `trigger` pointer `LF_RegisterCall` receives is reused as an auto-incrementing ID, and when the callback fires the Go function is looked up through the `sync` package's `sync.Map`. That avoids the complexity and security risk of exposing Go closure pointers to the C layer.
- **`Close()` on a borrowed handle is a no-op**: `app.LocalCall`, the `input`/`output` inside callbacks and `AsyncResult.Value` of async callbacks are all borrowed handles; `Close()` detects `owned == false` and returns immediately, preventing a double free.
- **No dependency on `runtime.SetFinalizer`**: every resource must be released explicitly. That is standard practice in the Go community, avoiding the unpredictable timing of finalizers.
- **The deadlock watchdog**: the Go runtime cannot see purego's C-layer worker threads and misjudges the situation as a deadlock. The watchdog avoids that false positive by always keeping one pending timer event. It is a compensation mechanism specific to the Go binding.
- **HTML escaping turned off explicitly**: Go's `encoding/json` escapes `<` `>` `&` U+2028 U+2029 by default, inconsistent with the other languages in the toolchain. The Go binding turns it off explicitly with `json.Encoder.SetEscapeHTML(false)`, guaranteeing byte-level cross-language consistency.
- **The P2P registry is cleared during `Shutdown`**: the Go binding cleans up its local `p2pRegistry` synchronously in `Shutdown`, guaranteeing that a P2P API of the same name can be registered again after the framework restarts. The other language bindings may not keep that local state, so their behaviour may differ slightly.

---

## References

- **Main repository**: https://github.com/PassByYou888/LingoFuse
- **C++ knowledge base**: `cpp/LingoFuse_Cpp_Knowledge_Base.md`
- **Rust user guide**: `rust/RUST_USER_GUIDE.md`
- **Pascal complete guide**: `pascal/LingoFuse_Pascal_Complete_Guide.md`
- **C# complete guide**: `csharp/LingoFuse_CSharp_Complete_Guide.md`
- **Cross-language demo notes**: `go/cross/README.md`

---

## License

The same as the main repository; see `LICENSE`.

