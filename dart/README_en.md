# The LingoFuse Dart binding

> Chinese version: [README.md](README.md)

> The official Dart binding for [LingoFuse](https://github.com/PassByYou888/LingoFuse).
> Built on Dart FFI plus a tiny C bridge DLL, it provides **full caller-side and server-side capability**, covering all 59 exported functions of the LingoFuse v5.x C ABI, the three addressing modes, the modern async API, and typed runtime options.
>
> **This binding lives in the `dart/` directory of the LingoFuse main repository**, alongside the first-party bindings for Pascal, Python, C++, C#, TypeScript, JavaScript, Rust, Go and others.

---

## Contents

- [What this is](#what-this-is)
- [Capability scope](#capability-scope)
- [The three addressing modes](#the-three-addressing-modes)
- [Directory layout](#directory-layout)
- [Environment preparation](#environment-preparation)
- [Environment verification](#environment-verification)
- [Project initialization](#project-initialization)
- [Building the C bridge DLL](#building-the-c-bridge-dll)
- [Multi-platform builds](#multi-platform-builds)
- [Running the tests](#running-the-tests)
- [Tests and POC validation](#tests-and-poc-validation)
- [Quick start: a minimal example](#quick-start-a-minimal-example)
- [Quick start: the modern async API](#quick-start-the-modern-async-api)
- [Cross-language interop](#cross-language-interop)
- [API reference](#api-reference)
- [Runtime options](#runtime-options)
- [Cleanup order](#cleanup-order)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Related projects](#related-projects)
- [License](#license)

---

## What this is

LingoFuse is a cross-language RPC framework whose core promise is: **a function written in any language can be called directly from any other language**.

This Dart binding achieves that through a **three-layer architecture**:

```
Dart application code
    │
    ├── user API layer
    │     DataHandle / AppHandle / Framework / LingoFuseStatus / LfIo
    │     Target / AppTarget / UIDTarget / P2PNameTarget
    │     CallPromise / AsyncBridge
    │
    ├── bridge host (BridgeHost)
    │     Protocol A: synchronous handshake (Call / Notify)
    │     Protocol B: fire-and-forget (async / network events)
    │
    └── FFI layer (two paths coexist)
          Legacy path: bindings_generated.dart ──→ LingoFuse64.dll
          Bridge path: bridge_ffi.dart ──→ lf_dart_bridge.dll ──→ LingoFuse64.dll
```

**The two paths run independently and do not interfere**:

- the **Legacy path** calls the C ABI exported by `LingoFuse64.dll` directly; it is the original v1.x channel, and all v1.x API semantics are unchanged.
- the **Bridge path** goes through a tiny C bridge DLL that solves three problems Dart FFI cannot handle: passing a UID struct by value, synchronously calling back from native worker threads, and the lifetime of temporary pointers.
- the **v2.0 APIs** (three addressing modes, modern async, typed options) go through the Bridge path; the **old APIs** (`Framework.call`, `DataHandle` scalar I/O, etc.) go through the Legacy path. Both share the same `LingoFuse64.dll` instance and the process-level network state.

The C bridge layer is necessary; the reason is explained in detail in [Building the C bridge DLL](#building-the-c-bridge-dll).

---

## Capability scope

| Capability | Status | Notes |
|---|:---:|---|
| Load the LingoFuse DLL | ✅ | automatic platform detection (Windows / Linux / macOS) |
| Create / read / write a DataHandle | ✅ | full support for both auto-recycled and permanent handles |
| JSON / string / byte I/O | ✅ | byte-level compatible with the other bindings |
| Call a remote API as a **caller** | ✅ | all three addressing modes (App name / UID / P2PName) |
| Register a Call API as a **server** | ✅ | synchronous semantics via the C bridge |
| Register a Notify API as a **server** | ✅ | as above |
| **process-level P2P registration** | ✅ | `registerP2PCall` / `registerP2PNotify` |
| **async calls (Promise style)** | ✅ | `target.call(...)` → `CallPromise<Uint8List>` |
| **async calls (Callback style)** | ✅ | `target.callAsync(api, payload, (result, error) { ... })` |
| **async calls (automatic JSON decoding)** | ✅ | `target.callJson<T>(...)` |
| **typed runtime options** | ✅ | 32 strongly-typed `setOpt*` / `getOpt*` accessors |
| **UID / P2PName health checks** | ✅ | `LingoFuseStatus.checkUid` / `checkP2PName` |
| **P2P identity reading** | ✅ | `DataHandle.getP2PUid` / `getP2PName` (input handles only) |
| **NetworkEvents (network event callbacks)** | ✅ | `BridgeHost.setNetworkEvent` implemented |
| status queue | ✅ | `LingoFuseStatus` |

**Not supported**:
- Flutter Web (Dart FFI is unavailable there)
- 32-bit Windows (theoretically possible, untested)

---

## The three addressing modes

LingoFuse supports **three orthogonal addressing modes**, exposed uniformly by the Dart binding through the `Target` abstraction:

| Addressing mode | Dart type | Index key | Local first | Server-side load balancing |
|---|---|:---:|:---:|
| **App name** | `AppTarget` | a UTF-8 string | ✅ | ❌ |
| **UID** | `UIDTarget` | 32 bytes of binary | ✅ | ❌ |
| **P2PName** | `P2PNameTarget` | a UTF-8 string | ❌ | ✅ |

**How the semantics differ**:

- **App-name addressing**: targets a fixed service. If the same App is also registered in this process, the call executes locally instead of going over the network.
- **UID addressing**: targets a particular session. The UID is generated when a `TunnelLink` succeeds and changes after a reconnect, so the caller has to rediscover it.
- **P2PName addressing**: targets a cluster of homogeneous services. **It does no local lookup** and always goes through server-side load balancing.

**The three modes share the same set of call shapes**:

```dart
// 1. Promise style (returns bytes)
final bytes = await target.call('api', payload: {...}).future;

// 2. Promise style (automatic JSON decoding)
final json = await target.callJson<Map<String, dynamic>>('api').future;

// 3. Callback style (business code lives in the callback)
target.callAsync('api', {...}, (result, error) {
  if (error != null) { handleError(error); return; }
  handleResult(result!);
});

// 4. Blocking style (must be called from a child isolate)
final handle = target.callSync('api', payload: {...});

// 5. One-way notification
target.notify('api', payload: {...});           // no ordering guarantee
target.sequencedNotify('api', payload: {...});  // FIFO within (app, api) guaranteed
```

---

## Directory layout

```
dart/
├── pubspec.yaml                  package definition + ffigen configuration
├── dart_test.yaml               forces serial test execution
├── check-env.ps1                 environment diagnostic script (Windows)
├── lf_dart_bridge.dll             build artifact (copied here)
│
├── bridge/                       ★ C bridge source
│   ├── lf_dart_bridge.h          full declarations (~103 exported functions)
│   ├── lf_dart_bridge.c          full implementation
│   ├── build.ps1                 Windows build script (MSVC + dumpbin self-check)
│   ├── build.sh                  Linux / macOS build script (nm self-check)
│   ├── dart_api_dl.h             ← copied from the Dart SDK
│   ├── dart_api_dl.c             ← downloaded from Dart SDK GitHub
│   ├── dart_api.h                ← copied from the Dart SDK
│   ├── dart_native_api.h         ← copied from the Dart SDK
│   ├── dart_tools_api.h          ← copied from the Dart SDK
│   ├── dart_version.h            ← copied from the Dart SDK
│   └── internal/
│       └── dart_api_dl_impl.h    ← copied from the Dart SDK
│
├── headers/
│   └── LingoFuse.h               ← copied from the LingoFuse repo (59 C ABI exports)
│
├── lib/
│   ├── lingofuse.dart            public entry point
│   └── src/
│       ├── bindings_generated.dart   ffigen-generated (Legacy FFI)
│       ├── runtime.dart              DLL loading (two paths: getBindings / getBridge)
│       ├── errors.dart               the 8-class exception hierarchy
│       ├── data_handle.dart          the RAII data handle (+ 4 P2P/UID bridge methods)
│       ├── io.dart                   LfIo: the single authority for JSON / string I/O
│       ├── framework.dart            the process-level facade (+ 32 typed options + 3 addressing shortcuts)
│       ├── app_handle.dart           the RAII application handle (+ 3 P2P registration methods)
│       ├── status.dart               the status queue (+ 4 UID/P2P checks)
│       ├── async_support.dart        CallPromise / AsyncBridge
│       ├── address.dart              Target / AppTarget / UIDTarget / P2PNameTarget
│       └── bridge/
│           ├── bridge_error.dart     BridgeErrorCode / BridgeException
│           ├── bridge_ffi.dart       FFI declarations for the C bridge (100+)
│           └── bridge_host.dart      the Dart-side dual-protocol host
│
├── bin/
│   ├── lf_probe.dart             minimal load test
│   ├── phase1_test.dart          DataHandle layer test
│   ├── phase2_test.dart          caller-side test
│   ├── phase3_test.dart          server end-to-end test
│   ├── phase4_bridge_probe.dart  bridge layer probe (21 items)
│   ├── phase5_framework_test.dart Framework probe (28 items)
│   ├── phase6_async_probe.dart   async API probe (24 items)
│   ├── phase7_addressing_probe.dart  three-addressing-mode probe (25 items)
│   └── hello_async.dart          async API teaching demo
│
├── test/
│   ├── data_handle_test.dart     DataHandle layer unit tests
│   ├── io_test.dart              LfIo layer unit tests
│   ├── status_test.dart          status queue unit tests
│   └── server_test.dart          end-to-end integration tests
│
├── example/                      full examples (to be completed)
├── native/                       backup native library directory
└── tool/                         helper tool directory
```

---

## Environment preparation

### 1. The Dart SDK

**Download links** (the zip version, no installer needed):

Official:
```
https://storage.googleapis.com/dart-archive/channels/stable/release/3.6.2/sdk/dartsdk-windows-x64-release.zip
```

Mainland-China mirror (recommended):
```
https://storage.flutter-io.cn/dart-archive/channels/stable/release/3.6.2/sdk/dartsdk-windows-x64-release.zip
```

**Installation steps**:

1. Unzip to `D:\dart-sdk` (avoid non-ASCII characters and spaces in the path).
2. Add `D:\dart-sdk\bin` to the system PATH:
   ```powershell
   # an administrator PowerShell
   $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
   if ($p -notlike '*D:\dart-sdk\bin*') {
       [Environment]::SetEnvironmentVariable('Path', "$p;D:\dart-sdk\bin", 'Machine')
   }
   ```
3. **Close and reopen PowerShell**, then run:
   ```powershell
   dart --version
   ```
   It should print `Dart SDK version: 3.6.2` or later.

### 2. VSCode + the Dart extension

1. Download and install VSCode from https://code.visualstudio.com/.
2. Open VSCode and press `Ctrl+Shift+X` to open the extension marketplace.
3. Search for **Dart** and install the official extension published by **Dart Code**.
4. Open this project's directory; VSCode will recognise `pubspec.yaml` automatically.

### 3. Visual Studio 2022

**The C++ workload must be installed**, otherwise the bridge DLL cannot be compiled.

1. Open **Visual Studio Installer**.
2. Find VS2022 and click **Modify**.
3. Tick **Desktop development with C++**.
4. On the right, confirm these are ticked:
   - MSVC v143 - VS 2022 C++ x64/x86 build tools
   - Windows 11 SDK (or Windows 10 SDK)
   - C++ CMake tools for Windows
5. Click **Modify** to finish the installation.

### 4. LLVM

`ffigen` depends on LLVM's `libclang`.

**Download links**:
```
https://github.com/llvm/llvm-project/releases
```

In the latest release's Assets, find `LLVM-*-win64.exe` (e.g. `LLVM-19.1.7-win64.exe`).

**Installation steps**:

1. Run the installer.
2. **Be sure to tick** `Add LLVM to the system PATH for all users`.
3. Installing to `C:\LLVM` is recommended.
4. Reopen PowerShell and run:
   ```powershell
   clang --version
   ```
   It should print a version number.

### 5. CMake

If you ticked **C++ CMake tools** for VS2022, CMake is already installed with VS and you can skip this step.

If you need a standalone install:
```
https://cmake.org/download/
```
Download `cmake-*-windows-x64.msi` and tick **Add CMake to the system PATH for all users** during installation.

---

## Environment verification

`check-env.ps1` checks every dependency item by item and also attempts one real DLL call.

**Run it**:

```powershell
cd D:\CoreLibrary\LingoFuse\dart
powershell -ExecutionPolicy Bypass -File .\check-env.ps1
```

**Expected output** (all [OK]):

```
==================================================================
  0. System Information
==================================================================
         OS:         Microsoft Windows Server 2022 Datacenter
         ...
==================================================================
  1. Dart SDK
==================================================================
  [OK]   dart command available: D:\dart-sdk\bin\dart.exe
         Dart SDK version: 3.6.2 (stable) ...
==================================================================
  2. VSCode
==================================================================
  [OK]   code command available: ...
  [OK]   Dart extension installed: dart-code.dart-code-3.144.0
==================================================================
  3. Visual Studio 2022
==================================================================
  [OK]   C++ desktop workload installed (MSVC v143)
  [OK]   VS built-in CMake component installed
  [OK]   found vcvars64.bat: ...
==================================================================
  4. LLVM / clang
==================================================================
  [OK]   clang command available: C:\LLVM\bin\clang.exe
  [OK]   found libclang.dll: C:\LLVM\bin\libclang.dll
==================================================================
  5. CMake
==================================================================
  [OK]   cmake command available: ...
==================================================================
  6. Git
==================================================================
  [OK]   git command available: ...
==================================================================
  7. LingoFuse native library (.dll)
==================================================================
  [OK]   found LingoFuse64.dll : D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll
  [OK]   found dependency z_ipc_64.dll : ...
  [OK]   found dependency mimalloc64.dll : ...
==================================================================
  8. PATH key entries
==================================================================
  [OK]   dart -> D:\dart-sdk\bin
  [OK]   llvm -> C:\LLVM\bin
  [OK]   cmake -> C:\Program Files\CMake\bin
  [OK]   LingoFuse -> D:\CoreLibrary\LingoFuse\Binary
==================================================================
Summary
==================================================================
  [OK]   All required components are ready. You can start Dart FFI development.
```

**If anything is [FAIL]**:

- **the Dart SDK is missing** → install it as in step 1 above
- **VSCode / the Dart extension is missing** → install as in step 2 above
- **the VS2022 C++ workload is missing** → add it through the Installer as in step 3 above
- **LLVM/libclang is missing** → install as in step 4 above
- **CMake is missing** → install as in step 5 above
- **LingoFuse64.dll is not found** → make sure `D:\CoreLibrary\LingoFuse\Binary\` exists and contains the three DLLs

**Also confirm `D:\CoreLibrary\LingoFuse\Binary` is on PATH**:

```powershell
$env:PATH -split ';' | Select-String 'LingoFuse'
```

It should print `D:\CoreLibrary\LingoFuse\Binary`. If it does not, run as administrator:

```powershell
$p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$p;D:\CoreLibrary\LingoFuse\Binary", 'Machine')
```

Then **close and reopen PowerShell**.

---

## Project initialization

### 1. Fetch the dependencies

```powershell
cd D:\CoreLibrary\LingoFuse\dart
dart pub get
```

This downloads `ffi`, `path`, `ffigen`, `test` and their transitive dependencies.

### 2. Generate the FFI bindings

`ffigen` parses `headers/LingoFuse.h` and generates `lib/src/bindings_generated.dart` automatically.

```powershell
dart run ffigen
```

**Expected output**:

```
[INFO]   : Running in Directory: 'D:\CoreLibrary\LingoFuse\dart'
[INFO]   : Input Headers: [file:///D:/CoreLibrary/LingoFuse/dart/headers/LingoFuse.h]
[INFO]   : Finished, Bindings generated in D:\CoreLibrary\LingoFuse\dart\lib\src\bindings_generated.dart
```

**If it reports `Couldn't find dynamic library in default locations`**:

that means `ffigen` cannot find `libclang.dll`. Confirm that the `ffigen` section of `pubspec.yaml` contains:

```yaml
ffigen:
  # ...
  llvm-path:
    - 'C:\LLVM'
    - 'C:\LLVM\bin'
```

---

## Building the C bridge DLL

### Why a C bridge is needed

Dart FFI's callback mechanism offers only two modes:

| Mode | Callable from any native thread? | Sync/async |
|---|:---:|:---:|
| `NativeCallable.isolateLocal` | ❌ only from the isolate that created it | sync |
| `NativeCallable.listener` | ✅ callable from any thread | **async** |

LingoFuse's Call callbacks run on native worker threads, so it can **only** use `listener`. But `listener` is **asynchronous**: once the native thread fires the callback it **returns immediately**, without waiting for Dart to finish. And LingoFuse **releases** the input / output buffers **immediately** after the callback returns. By the time the Dart callback actually runs, the native buffers may already have been reclaimed.

**The C bridge layer's solution**:

```
LingoFuse native thread                    Dart main isolate
     │                                    │
     │  1. snapshot the input bytes onto the heap
     │  2. post via Dart_PostCObject_DL ──→  3. receive the message, call the user handler
     │                                    │  4. send back via lf_bridge_complete
     │  5. block and wait (semaphore) ←──────│
     │  6. write the output into the LingoFuse handle
     │  7. return; LingoFuse releases the buffer
```

**The key**: the native thread **blocks and waits** at step 5, returning only once Dart has finished. That turns an asynchronous callback into synchronous semantics, matching LingoFuse's assumptions.

**The C bridge also solves two other problems Dart FFI cannot handle**:

1. **passing a UID struct by value**: LingoFuse's `TP2P_UID` is a 32-byte Pascal array, and Dart FFI cannot reliably pass it by value. The bridge accepts a `const uint8_t*` and repacks it on the C side.
2. **the lifetime of temporary pointers**: `LF_Get_P2P_UID` returns a framework-owned pointer (released automatically after about 5 seconds). The bridge copies the 32 bytes into the caller's buffer immediately and never exposes a raw pointer.

### Step 1: copy the Dart SDK headers

**This is the most important step before compiling.**

The Dart SDK headers live in `D:\dart-sdk\include\` and include:

```
D:\dart-sdk\include\
├── dart_api.h
├── dart_api_dl.h
├── dart_native_api.h
├── dart_tools_api.h
├── dart_version.h
└── internal\
    └── dart_api_dl_impl.h
```

**Note that `dart_api_dl.c` is not in the SDK include directory**; it has to be downloaded from the Dart SDK's GitHub source repository:

```
https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c
```

**The complete copy operation**:

```powershell
# 1. create the bridge directory (if it does not exist yet)
New-Item -ItemType Directory -Force -Path D:\CoreLibrary\LingoFuse\dart\bridge | Out-Null
New-Item -ItemType Directory -Force -Path D:\CoreLibrary\LingoFuse\dart\bridge\internal | Out-Null

# 2. copy all headers (including the internal/ subdirectory)
Copy-Item D:\dart-sdk\include\*.h    D:\CoreLibrary\LingoFuse\dart\bridge\ -Force
Copy-Item D:\dart-sdk\include\internal\*.h D:\CoreLibrary\LingoFuse\dart\bridge\internal\ -Force

# 3. download dart_api_dl.c into the bridge\ directory
#    （open the link below in a browser and use "Save as" to put it in bridge\）
#    https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c

# 4. verify the files are all present
Get-ChildItem D:\CoreLibrary\LingoFuse\dart\bridge\ -Recurse -File | Format-Table Name, Length
```

**The `bridge\` directory should finally contain** (alongside `lf_dart_bridge.*` and `build.ps1`):

| File | Source |
|---|---|
| `lf_dart_bridge.h` | this repository |
| `lf_dart_bridge.c` | this repository |
| `build.ps1` | this repository |
| `dart_api.h` | copied from `D:\dart-sdk\include\` |
| `dart_api_dl.h` | copied from `D:\dart-sdk\include\` |
| `dart_native_api.h` | copied from `D:\dart-sdk\include\` |
| `dart_tools_api.h` | copied from `D:\dart-sdk\include\` |
| `dart_version.h` | copied from `D:\dart-sdk\include\` |
| `internal\dart_api_dl_impl.h` | copied from `D:\dart-sdk\include\internal\` |
| `dart_api_dl.c` | downloaded from Dart SDK GitHub |

**Why copy all of them**:

- `dart_api_dl.h` internally `#include "dart_api.h"`
- `dart_api.h` internallly `#include "dart_native_api.h"` and `"dart_version.h"`
- `dart_api_dl.c` internally `#include "internal/dart_api_dl_impl.h"`

After copying the whole `include/` tree into `bridge/`, the compiler finds every dependency in **the current directory** without extra `-I` flags pointing at the SDK path. The bridge directory is thus **self-contained**, and compiling does not depend on where the Dart SDK lives.

### Step 2: confirm the source files are all present

Before running the build script, confirm the required source files are there:

```powershell
cd D:\CoreLibrary\LingoFuse\dart\bridge

foreach ($f in @(
    'lf_dart_bridge.h',
    'lf_dart_bridge.c',
    'build.ps1',
    'dart_api.h',
    'dart_api_dl.h',
    'dart_api_dl.c',
    'dart_native_api.h',
    'dart_tools_api.h',
    'dart_version.h',
    'internal\dart_api_dl_impl.h'
)) {
    if (Test-Path $f) {
        Write-Host "[OK]   $f"
    } else {
        Write-Host "[FAIL] $f MISSING" -ForegroundColor Red
    }
}
```

Continue only once everything is [OK].

### Step 3: run build.ps1

**This is the core build command**:

```powershell
cd D:\CoreLibrary\LingoFuse\dart\bridge
.\build.ps1
```

**If it complains about the execution policy**:

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

**What build.ps1 does internally** (six steps):

1. **validate the required source files** — continue only if all exist
2. **locate `vcvars64.bat`** — via `vswhere` or a search over known paths
3. **optional cleanup** — delete `obj/` and the output DLL when `-Clean` is passed
4. **invoke `cl.exe`** — compile `lf_dart_bridge.c` and `dart_api_dl.c`
5. **dumpbin self-check** — assert the exported symbol count ≥ 80 and that key symbols are present
6. **copy into the `dart/` root directory** — so the Dart runtime can load it from the CWD

**The full `cl.exe` arguments**:

```
/nologo                     suppress the copyright banner
/O2                         optimisation level 2 (speed)
/LD                         produce a DLL
/MD                         use the multi-threaded DLL runtime
/W3                         warning level 3
/wd4100                     disable the "unused parameter" warning
/I.                         include search path: the current directory
/I..\headers                include search path: the parent headers directory (LingoFuse.h)
lf_dart_bridge.c            source file
dart_api_dl.c               source file
/Fe:lf_dart_bridge.dll      output file name
/Fo:obj/                    object file output directory
```

**Expected output**:

```
==================================================================
  LingoFuse Dart Bridge Build (Windows / MSVC)
==================================================================

  Step 1: verifying required files
  [OK]   all 10 required files present

  Step 2: locating vcvars64.bat
  [OK]   found: C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat

  Step 3: cleaning previous build
         clean skipped (pass -Clean to force a full rebuild)

  Step 4: compiling lf_dart_bridge.dll
  [OK]   built: D:\CoreLibrary\LingoFuse\dart\bridge\lf_dart_bridge.dll (~19000 bytes)

  Step 5: verifying exported symbols (dumpbin)
  [OK]   exported 103 lf_bridge_* symbols (minimum: 80)
  [OK]   all 21 critical exports present

  Step 6: copying to dart/ parent directory
  [OK]   copied to: D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll

==================================================================
  Build complete
==================================================================

  [OK]   DLL  : D:\CoreLibrary\LingoFuse\dart\bridge\lf_dart_bridge.dll
  [OK]   copy : D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll
```

**Common build errors**:

| Error | Cause | Fix |
|---|---|---|
| `fatal error C1083: cannot open include file: "dart_api.h"` | `dart_api.h` was not copied into `bridge\` | redo step 1 |
| `fatal error C1083: cannot open include file: "internal/dart_api_dl_impl.h"` | the `internal\` subdirectory was not copied | check that `bridge\internal\dart_api_dl_impl.h` exists |
| `error LNK2019: unresolved external symbol Dart_InitializeApiDL` | `dart_api_dl.c` was not included in the build | confirm `bridge\dart_api_dl.c` exists |
| `[FAIL] vcvars64.bat not found` | VS2022 has no C++ workload | open VS Installer and add the workload |
| `[FAIL] only N lf_bridge_* symbols exported` | the header declares it but the `.c` does not implement it | check that `lf_dart_bridge.c` is complete |

### Step 4: copy the DLL into the project root

`build.ps1` does this automatically. If you compile manually, copy it with:

```powershell
Copy-Item D:\CoreLibrary\LingoFuse\dart\bridge\lf_dart_bridge.dll `
          D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll -Force
```

**Verify the DLL exists**:

```powershell
Get-ChildItem D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll |
    Format-Table Name, Length, LastWriteTime
```

---

## Multi-platform builds

`lf_dart_bridge.c` uses **conditional compilation** to support Windows, Linux and macOS at the same time. The upper layers are unaware of platform differences.

### The platform abstraction layer

Inside, the bridge code defines a set of abstract functions with an `lf_*` prefix, and each platform provides its own implementation:

| Function | Windows | Linux / macOS |
|---|---|---|
| dynamic library handle | `HMODULE` | `void*` |
| load a dynamic library | `LoadLibraryA` | `dlopen` |
| resolve a symbol | `GetProcAddress` | `dlsym` |
| unload a dynamic library | `FreeLibrary` | `dlclose` |
| mutex | `CRITICAL_SECTION` | `pthread_mutex_t` |
| semaphore | `CreateSemaphoreA` / `WaitForSingleObject` | `sem_init` / `sem_wait` / `sem_post` |
| atomic increment | `InterlockedIncrement` | `__sync_add_and_fetch` |
| TLS | `__declspec(thread)` | `__thread` |
| LingoFuse library name | `LingoFuse64.dll` | `liblingofuse.so` / `liblingofuse.dylib` |

### The per-platform checklist

#### Windows (verified)

| Step | Command |
|---|---|
| 1 | copy all `.h` from `D:\dart-sdk\include\` into `bridge\`, including the `internal\` subdirectory |
| 2 | download `dart_api_dl.c` from Dart SDK GitHub into `bridge\` |
| 3 | `cd bridge; .\build.ps1` |
| 4 | `build.ps1` copies it into `dart\` automatically |

#### Linux

| Step | Command |
|---|---|
| 1 | install the toolchain: `sudo apt install build-essential` (Debian/Ubuntu) or `sudo dnf groupinstall "Development Tools"` (Fedora) |
| 2 | copy all headers from the Dart SDK's `include/` directory into `bridge/` (including the `internal/` subdirectory) |
| 3 | download `dart_api_dl.c` from [Dart SDK GitHub](https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c) into `bridge/` |
| 4 | `cd bridge; chmod +x build.sh; ./build.sh` |
| 5 | `build.sh` copies it into `dart/` automatically |

**Extra Linux requirements**:
- LingoFuse's Linux build `liblingofuse.so` must be findable via PATH / `LD_LIBRARY_PATH`
- if LingoFuse ships an official prebuilt Linux library, just use it

#### macOS

| Step | Command |
|---|---|
| 1 | install the Xcode Command Line Tools: `xcode-select --install` |
| 2 | copy all headers from the Dart SDK's `include/` directory into `bridge/` |
| 3 | download `dart_api_dl.c` from [Dart SDK GitHub](https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c) into `bridge/` |
| 4 | `cd bridge; chmod +x build.sh; ./build.sh` |
| 5 | `build.sh` copies it into `dart/` automatically |

**Extra macOS considerations**:
- Apple Silicon (arm64) and Intel (x86_64) are different architectures, so the bridge must be compiled for the local architecture
- if LingoFuse ships an official prebuilt macOS library, just use it

### About the LingoFuse core library

**The LingoFuse core library is officially provided as prebuilt multi-platform builds.** Developers of the Dart binding do not need to compile the LingoFuse core library themselves.

The official repository's `Binary/` directory contains:

| Platform | Core library | IPC dependency | Memory allocator |
|---|---|---|---|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` | `libmimalloc.so` (optional) |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` | `libmimalloc.dylib` (optional) |

**How to deploy**: add the `Binary/` directory to the system PATH, or copy the dynamic libraries next to the executable.

On Windows you also need the **VC++ 2015-2022 redistributable package**:
- [Latest supported Visual C++ redistributable packages](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170)

### Dart-side cross-platform adjustments

The `load()` method in `lib/src/bridge/bridge_ffi.dart` picks the right file name per platform:

```dart
static String _selectFileName() {
  if (Platform.isWindows) return 'lf_dart_bridge.dll';
  if (Platform.isMacOS) return 'lf_dart_bridge.dylib';
  return 'lf_dart_bridge.so';
}
```

The search order of `BridgeFfi.load()` is:

1. the environment variable `LINGOFUSE_BRIDGE_DLL` (if set and non-empty)
2. `bridge/<bridgeName>` (relative to the CWD)
3. `<bridgeName>` (the bare file name, handled by the OS loader)

---

## Running the tests

### Test structure

| File | Needs the framework | Notes |
|---|:---:|---|
| `test/data_handle_test.dart` | ❌ | DataHandle layer: construction, bytes, scalars, strings, position, lifecycle |
| `test/io_test.dart` | ❌ | LfIo layer: JSON serialization, string/byte I/O |
| `test/status_test.dart` | ❌ | the status queue |
| `test/server_test.dart` | ✅ | end-to-end: Framework + AppHandle + C bridge + remote calls |

`dart_test.yaml` forces `concurrency: 1`, because the framework state is shared at process level.

### Running all tests

```powershell
cd D:\CoreLibrary\LingoFuse\dart
dart test
```

**Expected output**:

```
00:00 +0: loading test\data_handle_test.dart
00:00 +38: test\data_handle_test.dart: All tests passed!
00:00 +58: test\io_test.dart: All tests passed!
00:00 +63: test\status_test.dart: All tests passed!
00:01 +63: test\server_test.dart: (setUpAll)
... (LingoFuse native startup logs) ...
00:08 +75: All tests passed!
```

### Running the probes

Besides the unit tests, `bin/` holds five standalone probes, each a self-contained end-to-end validation:

```powershell
# bridge layer probe (no framework startup, pure C bridge ABI validation)
dart run bin\phase4_bridge_probe.dart
# → 21 passed, 0 failed

# Framework layer probe (typed options, argument validation, error paths)
dart run bin\phase5_framework_test.dart
# → 28 passed, 0 failed

# Async API probe (Promise / Callback / JSON / timeout / error)
dart run bin\phase6_async_probe.dart
# → 24 passed, 0 failed

# three-addressing-mode probe (AppTarget / UIDTarget / P2PNameTarget)
dart run bin\phase7_addressing_probe.dart
# → 25 passed, 0 failed

# teaching demo (runs all 5 async scenarios)
dart run bin\hello_async.dart
```

### Running a single test file

```powershell
dart test test\data_handle_test.dart
dart test test\server_test.dart
```

### Verbose output mode

```powershell
dart test --reporter expanded
```

### Running only tests whose name matches

```powershell
dart test --name "echo"
dart test --name "uint64"
```

### Diagnostics when a test fails

```powershell
dart test --chain-stack-traces
```

---

## Tests and POC validation

### What a test is, and what a POC is

In the LingoFuse ecosystem, **a test** and **a POC (proof of concept)** are two different things:

| Dimension | Test | POC (proof of concept) |
|---|---|---|
| **purpose** | validate the correctness of the binding layer itself | validate how LingoFuse behaves in **your own business scenario** |
| **scope** | API contracts, serialization, lifecycle, callbacks | your App-layer logic, your concurrency model, your data volume |
| **provided by** | provided by the LingoFuse repository | **built by the user** |
| **example** | can `DataHandle` read and write an int32 correctly | can your order system reliably call a Dart service under high concurrency |

### The Dart binding's test system

The Dart binding provides validation at **four levels**:

**Unit tests** (`test/data_handle_test.dart`, `io_test.dart`, `status_test.dart`):
- do not depend on the LingoFuse framework being started
- validate `DataHandle`'s byte, scalar and string I/O
- validate `LfIo`'s JSON serialization and byte-level cross-language consistency
- validate `LingoFuseStatus`'s queue operations

**End-to-end integration tests** (`test/server_test.dart`):
- start the full LingoFuse framework (service + client + C bridge)
- register Call/Notify APIs
- issue remote calls from a child isolate
- validate the whole "prepare → connect → App registration → broadcast → route → callback → return" chain

**The bridge probe** (`bin/phase4_bridge_probe.dart`):
- no framework startup, purely validating the C bridge's ABI correctness
- validates `create_data` / `write_buffer` / `read_buffer` / `get_p2p_uid` / `write_uid` / `read_uid` and the like
- validates that P2P identity returns zeros on a self-created handle

**The Addressing / Async probes** (`bin/phase6` / `phase7`):
- end-to-end validation of the three addressing modes plus the modern async API
- cover Promise / Callback / JSON / timeout / error paths
- **must go through `P2PNameTarget`** (see the deadlock trap in [Troubleshooting](#troubleshooting))

**Note**: in every end-to-end test the server and the caller run **inside the same process**, so `LF_Call` takes the mesh's local-first routing path. It traverses the full native call chain but makes no TCP or cross-process IPC hop.

### A POC: build it yourself

LingoFuse states explicitly: **the tests the Dart binding provides are mechanism-level tests, not your App-level tests.**

Before using the Dart binding in your business, you need to:

1. **build a PoC around your own business scenario**: simulate your App-layer logic and validate how LingoFuse behaves under your data volume, concurrency model and error handling
2. **validate across processes**: start two independent Dart processes (or a Dart process plus one in another language) and validate cross-process IPC/TCP calls
3. **long-running stability**: run the Dart server for more than 24 hours and watch memory and thread stability

### Suggested POC scenarios

| Scenario | What it validates |
|---|---|
| a Dart server + a Pascal client | cross-language interop (Dart as the server) |
| a Dart client + a Python server | cross-language interop (Dart as the caller) |
| high-concurrency Call requests | the performance impact of the C bridge's serialization |
| large data transfer (>100 MB) | memory usage and transfer stability |
| disconnect and reconnect | automatic recovery after a network interruption |
| P2PName load balancing | how requests are distributed across several clients with the same P2PName |
| async under high concurrency | memory and latency under concurrent `CallPromise` calls |

---

## Quick start: a minimal example

### The server

Create `bin/my_server.dart`:

```dart
// Minimal LingoFuse server in Dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

Future<void> main() async {
  // Step 1: start the C bridge host.
  // Required before any AppHandle.registerCall / registerNotify.
  await BridgeHost.start();

  // Step 2: create an application and register a Call API.
  final app = AppHandle('MyDartServer', 'Minimal example');

  app.registerCall('echo', 'Echo the input string', (Uint8List input) {
    final text = String.fromCharCodes(input);
    return Uint8List.fromList('Echo: $text'.codeUnits);
  });

  app.registerCall('add', 'Add two int32 (little-endian)', (Uint8List input) {
    final bd = ByteData.sublistView(input);
    final a = bd.getInt32(0, Endian.little);
    final b = bd.getInt32(4, Endian.little);
    return (ByteData(4)..setInt32(0, a + b, Endian.little))
        .buffer
        .asUint8List();
  });

  // Step 3: configure and start the framework.
  Framework.setOption('Quiet', 'False');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService('ipc:my_dart_server', 'ipc:my_dart_server');
  Framework.prepareClient('ipc:my_dart_server', app: app);

  if (!Framework.prepareDone()) {
    stderr.writeln('Framework failed to start');
    exit(1);
  }

  print('Server ready on "ipc:my_dart_server".');
  print('Press Enter to stop.');
  stdin.readLineSync();

  // Step 4: cleanup in the required order.
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
}
```

**Run it**:

```powershell
dart run bin/my_server.dart
```

### The client (Legacy style)

Create `bin/my_client.dart`:

```dart
// Minimal LingoFuse client in Dart (legacy synchronous style).

import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

void main() {
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.resetPrepare();
  Framework.prepareClient('ipc:my_dart_server');
  Framework.prepareDone();

  // Wait for the server to become visible.
  for (int i = 0; i < 30; i++) {
    if (Framework.checkApp('MyDartServer')) break;
    sleep(Duration(milliseconds: 100));
  }

  // Call "echo".
  final echoParam = DataHandle('echo');
  echoParam.writeBytes('hello from Dart client'.codeUnits);
  echoParam.position = 0;
  final echoResp = Framework.call('MyDartServer', echoParam, timeoutMs: 5000);
  print('echo: ${String.fromCharCodes(echoResp.readBytes(echoResp.size))}');
  echoResp.dispose();
  echoParam.dispose();

  // Call "add".
  final addParam = DataHandle('add');
  addParam.writeInt32(15);
  addParam.writeInt32(27);
  addParam.position = 0;
  final addResp = Framework.call('MyDartServer', addParam, timeoutMs: 5000);
  print('add: ${addResp.readInt32()}');
  addResp.dispose();
  addParam.dispose();

  Framework.exitMainThread();
  Framework.shutdown();
}

void sleep(Duration d) {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {}
}
```

**Run it**:

```powershell
dart run bin/my_client.dart
```

**Expected output**:

```
echo: Echo: hello from Dart client
add: 42
```

---

## Quick start: the modern async API

The modern async API is v2.0's core new capability: it lets business code be **written directly in callbacks**, without breaking into await/async. A complete example is in `bin/hello_async.dart`.

### Three addressing modes + four call shapes

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:lingofuse/lingofuse.dart';

Future<void> main() async {
  // 1. start the bridge host
  await BridgeHost.start();

  // 2. declare this process's P2P group name
  //    afterwards P2PNameTarget('worker_group') can route to this process
  Framework.setOptP2PName('worker_group');

  // 3. create an App and register APIs
  final app = AppHandle('MyService', 'async demo');
  app.registerCall('add', 'Add two integers', (Uint8List input) {
    final json = decodeJsonPayload(input) as Map<String, dynamic>;
    final a = (json['a'] as num).toInt();
    final b = (json['b'] as num).toInt();
    return encodeJsonPayload({'sum': a + b});
  });

  // 4. start the framework
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService('ipc:my_service', 'ipc:my_service');
  Framework.prepareClient('ipc:my_service', app: app);
  Framework.prepareDone();

  // wait for the P2P name to propagate to the server (client -> server -> broadcast, about 2 seconds)
  await Future.delayed(const Duration(milliseconds: 2000));

  // ★ key: issuing an async call from the Dart main isolate REQUIRES P2PNameTarget
  //   App-name / UID routing is local-first and triggers a synchronous callback that deadlocks.
  //   See the "Troubleshooting" section below.
  final target = P2PNameTarget('worker_group');

  // ---- shape 1: Promise style (returns raw bytes) ----
  final bytes = await target.call(
    'add',
    payload: {'a': 1, 'b': 2},
    timeoutMs: 5000,
  ).future;
  print('bytes: $bytes');

  // ---- shape 2: Promise style (automatic JSON decoding) ----
  final json = await target.callJson<Map<String, dynamic>>(
    'add',
    payload: {'a': 10, 'b': 20},
    timeoutMs: 5000,
  ).future;
  print('sum: ${json['sum']}');  // → 30

  // ---- shape 3: Callback style (Erlang style, business code in the callback) ----
  target.callAsync('add', {'a': 3, 'b': 4}, (result, error) {
    if (error != null) {
      print('error: $error');
      return;
    }
    final reply = decodeJsonPayload(result!) as Map<String, dynamic>;
    print('callback sum: ${reply['sum']}');  // → 7
  });

  // ---- shape 4: blocking style (must be called from a child isolate) ----
  // Calling it from the main isolate blocks the Dart event loop, so bridge callbacks cannot be delivered.
  // See the Isolate.run usage in bin/server_test.dart.

  // cleanup
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
}

// JSON helper: strip LingoFuse's trailing NUL, then decode
Object? decodeJsonPayload(Uint8List bytes) {
  final nulIndex = bytes.indexOf(0);
  final payload = nulIndex >= 0 ? bytes.sublist(0, nulIndex) : bytes;
  if (payload.isEmpty) return null;
  return jsonDecode(utf8.decode(payload));
}

// JSON helper: encode into UTF-8 bytes
Uint8List encodeJsonPayload(Object? value) {
  return Uint8List.fromList(utf8.encode(jsonEncode(value)));
}
```

### The five typical async scenarios

`bin/hello_async.dart` demonstrates all five, and can be referenced directly:

| Scenario | What it demonstrates |
|---|---|
| **[1] Erlang style** | business code written directly in the `callAsync` callback, with no await break |
| **[2] Promise style** | `await target.callJson<T>(...).future`, a clean chained form |
| **[3] nested calls** | a second call issued from inside the first callback, forming a business logic chain |
| **[4] giving up on timeout** | a 1.5s timeout against a 3s handler, giving `promise.abandoned=true` |
| **[5] server-side errors** | a handler returning `{"error": "..."}` is recognised correctly |

### Choosing among the three addressing modes

| Scenario | Recommended addressing |
|---|---|
| calling a fixed business service | `AppTarget` |
| pushing to a known client by UID | `UIDTarget` |
| issuing an async call from the main isolate | **`P2PNameTarget`** (avoids deadlock) |
| load balancing across a homogeneous worker cluster | `P2PNameTarget` |
| needing FIFO ordering | use the `sequencedCall` / `sequencedNotify` variants |

---

## Cross-language interop

A Dart server can be called by **a LingoFuse client in any other language**, because underneath they all use the same C4 service mesh. Likewise, a Dart client can call services implemented in any language.

### The wire protocol

| Element | Encoding |
|---|---|
| strings | UTF-8 bytes + `0x00` |
| integers | little-endian |
| floating point | IEEE 754, little-endian |
| JSON | compact, literal UTF-8, no `\uXXXX` escapes |
| raw bytes | arbitrary bytes + `0x00` |

These rules are fully consistent with the Pascal / Python / C++ / C# / Rust / Go / JavaScript bindings.

### Cross-language call examples

**A Dart server called by a Python client**:

On the Dart side, register:
```dart
app.registerCall('echo', 'Echo', (Uint8List input) => input);
```

On the Python side, call:
```python
from lingofuse import C4
client = C4("MyDartServer", "ipc:my_dart_server")
result = client.echo(b"hello from Python")
```

**A Python server called by a Dart client**:

```dart
final param = DataHandle('compute');
LfIo.writeJson(param, {'expression': '1+2*3'});
param.position = 0;
final resp = Framework.call('PythonApp', param, timeoutMs: 5000);
```

**P2PName cross-language load balancing**:

On the Dart side, declare the group name:
```dart
Framework.setOptP2PName('compute_workers');
```

On the Python side, call any worker in the group:
```python
from lingofuse import C4
client = C4("", "ipc:compute_grid")
result = client.p2pname("compute_workers").call("compute", {"expr": "..."})
```

---

## API reference

### `DataHandle`

```dart
// ---- construction ----
DataHandle(String apiName)                              // auto-recycled
DataHandle.createPermanent(String apiName)              // permanent
DataHandle.fromRaw(Pointer<Void> raw, {bool owned = false})

// ---- properties ----
int get position / set position(int)
int get size / set size(int)
bool get isValid
bool get isOwning
Pointer<Void> get raw

// ---- byte I/O ----
int writeBytes(List<int>)
Uint8List readBytes(int)
Uint8List readBytesExact(int)             // throws on short read
Uint8List readAllBytes()
Uint8List readBytesUntilNul()

// ---- scalar I/O (little-endian) ----
void writeInt8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Single/Double(...)
int/double readInt8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Single/Double()

// ---- string I/O (UTF-8, trailing NUL) ----
void writeString(String)
String readString()

// ---- P2P identity (input handles only, needs BridgeHost) ----
Uint8List getP2PUid()                     // 32 bytes; self-created / output handles return all zeros
String getP2PName()                       // self-created / output handles return an empty string

// ---- UID binary I/O (needs BridgeHost) ----
void writeUid(Uint8List uid)              // must be 32 bytes
Uint8List readUid()                       // reads 32 bytes

// ---- lifecycle ----
void dispose()
```

### `LfIo`

```dart
// ---- JSON string helpers (no handle) ----
static String dumpsJson(Object? value)    // compact + literal UTF-8
static T loadsJson<T>(String text)

// ---- string I/O ----
static void writeString(DataHandle, String)
static String readString(DataHandle)

// ---- byte I/O ----
static void writeStringBytes(DataHandle, Uint8List)
static Uint8List readStringBytes(DataHandle)
static Uint8List readAllBytes(DataHandle)

// ---- JSON I/O ----
static void writeJson(DataHandle, Object?)
static T readJson<T>(DataHandle)          // throws LingoFuseIoError when empty or invalid
static T? tryReadJson<T>(DataHandle)      // returns null when empty or invalid
```

### `Framework` — network preparation

```dart
static void resetPrepare()
static int prepareService(String listeningAddr, String physicsAddr)
static int prepareClient(String physicsAddr, {AppHandle? app})
static bool prepareDone()
static void exitMainThread()
static void shutdown()
```

### `Framework` — typed runtime options (v2.0)

Every `setOpt*` goes through the Legacy path (so it can be set before the framework starts); every `getOpt*` goes through the Bridge path (so `BridgeHost.start()` must already have completed).

```dart
// ---- authentication ----
static void setOptPassword(String value)
static String getOptPassword()            // returns the mask "********"

// ---- logging and debugging ----
static void setOptDebug(String value)     // writes a C4 console command
static String getOptDebug()
static void setOptQuiet(bool value)
static bool getOptQuiet()
static void setOptShowThreadID(bool value)
static bool getOptShowThreadID()
static void setOptConsoleOutput(bool value)
static bool getOptConsoleOutput()

// ---- connection readiness ----
static void setOptOverlapConnection(bool value)
static bool getOptOverlapConnection()
static void setOptWaitConnectionReadyOk(bool value)
static bool getOptWaitConnectionReadyOk()
static void setOptWaitConnectionTimeout(int ms)
static int getOptWaitConnectionTimeout()

// ---- IPC ----
static void setOptIpcServThreadCount(int value)
static int getOptIpcServThreadCount()
static void setOptIpcServMaxQueueLength(int value)
static int getOptIpcServMaxQueueLength()
static void setOptIpcServMaxMsgSize(int value)
static int getOptIpcServMaxMsgSize()

// ---- sequenced notification ----
static void setOptFixedSequencedTime(int ms)
static int getOptFixedSequencedTime()

// ---- P2P group name ----
static void setOptP2PName(String value)
static String getOptP2PName()

// ---- data handle pool ----
static void setOptDataHandleIdleTimeout(int ms)
static int getOptDataHandleIdleTimeout()
static void setOptDataHandlePoolScanInterval(int ms)
static int getOptDataHandlePoolScanInterval()

// ---- command flushing ----
static void setOptNoReponseCmdNullFlushThreshold(int value)
static int getOptNoReponseCmdNullFlushThreshold()
```

**The generic escape hatch**:

```dart
static void setOption(String option, String value)   // Legacy path
static String getOption(String option)               // Bridge path (needs startup)
```

### `Framework` — health checks and calls

```dart
static bool checkMainThread()
static bool checkApp(String appName)
static bool checkApi(String appName, String apiName)
static String generateAppName()

// ---- App-name addressing (Legacy) ----
static DataHandle call(String appName, DataHandle param, {int timeoutMs = 5000})
static DataHandle? tryCall(String appName, DataHandle param, {int timeoutMs = 5000})
static void notify(String appName, DataHandle param)
static void sequencedNotify(String appName, DataHandle param)

// ---- UID addressing (Bridge, needs BridgeHost) ----
static DataHandle uidCall(Uint8List uid, DataHandle param, {int timeoutMs = 5000})
static DataHandle? tryUidCall(Uint8List uid, DataHandle param, {int timeoutMs = 5000})
static void uidNotify(Uint8List uid, DataHandle param)
static void uidSequencedNotify(Uint8List uid, DataHandle param)

// ---- P2PName addressing (Bridge, needs BridgeHost) ----
static DataHandle p2pnameCall(String p2pName, DataHandle param, {int timeoutMs = 5000})
static DataHandle? tryP2pnameCall(String p2pName, DataHandle param, {int timeoutMs = 5000})
static void p2pnameNotify(String p2pName, DataHandle param)
static void p2pnameSequencedNotify(String p2pName, DataHandle param)

// ---- async calls (Bridge, needs BridgeHost) ----
static void callAsync(String appName, DataHandle param, AsyncResultHandler onResult)
static void callAsyncSequenced(String appName, DataHandle param, AsyncResultHandler onResult)
static void uidCallAsync(Uint8List uid, DataHandle param, AsyncResultHandler onResult)
static void uidCallAsyncSequenced(Uint8List uid, DataHandle param, AsyncResultHandler onResult)
static void p2pnameCallAsync(String p2pName, DataHandle param, AsyncResultHandler onResult)
static void p2pnameCallAsyncSequenced(String p2pName, DataHandle param, AsyncResultHandler onResult)
```

### `AppHandle`

```dart
AppHandle(String name, String description)

// ---- application-level registration (reachable by App-name addressing) ----
void registerCall(String apiName, String description, CallHandler handler)
void registerNotify(String apiName, String description, NotifyHandler handler)
bool unregister(String apiName)

// ---- process-level P2P registration (reachable only by UID / P2PName addressing) ----
void registerP2PCall(String apiName, String description, CallHandler handler)
void registerP2PNotify(String apiName, String description, NotifyHandler handler)
bool unregisterP2P(String apiName)

// ---- local execution ----
DataHandle localCall(DataHandle param)
void localNotify(DataHandle param)

// ---- client binding ----
int bind()

// ---- properties ----
String get name
bool get isValid
Pointer<Void> get raw

// ---- lifecycle ----
void dispose()
```

### `BridgeHost`

```dart
// ---- lifecycle ----
static Future<BridgeHost> start()         // must happen before any registerCall
static BridgeHost get instance            // throws StateError if not started
static BridgeHost? get instanceOrNull     // for capability detection
void stop()                               // idempotent

// ---- properties ----
bool get isStopped
String get version
String get lastError
String get statsJson

// ---- network events (global, installed by replacement) ----
void setNetworkEvent({NetworkEventHandler? onConnect, NetworkEventHandler? onDisconnect})
void clearNetworkEvent()
bool get isNetworkEventInstalled
```

### `Target` / `AppTarget` / `UIDTarget` / `P2PNameTarget`

```dart
// ---- the call shapes shared by the three addressing modes ----
abstract class Target {
  String get hashKey;                     // 'app:x' / 'uid:hex' / 'p2p:name'
  String describe();                      // a human-readable description

  // Promise style: returns CallPromise<Uint8List>
  CallPromise<Uint8List> call(String apiName, {Object? payload, int? timeoutMs});

  // Promise style (automatic JSON decoding): returns CallPromise<T>
  CallPromise<T> callJson<T>(String apiName, {Object? payload, int? timeoutMs});

  // Callback style: onResult(result, error) is guaranteed to be called exactly once
  void callAsync(String apiName, Object? payload, void Function(Uint8List?, String?) onResult);

  // Blocking style: returns a DataHandle, and the caller must dispose it
  DataHandle callSync(String apiName, {Object? payload, int timeoutMs = 5000});
  DataHandle? tryCallSync(String apiName, {Object? payload, int timeoutMs = 5000});

  // one-way
  void notify(String apiName, {Object? payload});
  void sequencedNotify(String apiName, {Object? payload});
}

// ---- concrete constructors ----
AppTarget(String appName)
UIDTarget(Uint8List uid)                  // must be 32 bytes, otherwise throws RangeError
UIDTarget.hex(String hex)                 // must be a 64-character hex string, otherwise throws RangeError
P2PNameTarget(String groupName)
```

### `CallPromise<T>` / `AsyncBridge`

```dart
// ---- CallPromise<T> ----
Future<T> get future                       // the underlying Future
bool get abandoned                         // whether it was given up on because of a timeout
bool get settled                           // whether it has already resolved/rejected

// thenable: awaitable directly
Future<R> then<R>(FutureOr<R> Function(T), {Function? onError});
Future<T> catchError(Function, {bool Function(Object)? test});
Future<T> whenComplete(FutureOr<void> Function());

// ---- AsyncBridge (a process-level singleton) ----
static AsyncBridge instance()
static void shutdownInstance()
Map<String, int> stats()                   // {pending, total_settled, total_abandoned, shutdown}
bool get isShutdown
void shutdown()
```

### `LingoFuseStatus`

```dart
// ---- the status queue (Legacy) ----
static int getStatusCount()
static String getStatus()
static List<String> drainStatus([int maxMessages = 64])
static void postStatus(String message)

// ---- UID / P2PName health checks (Bridge, needs BridgeHost) ----
static bool checkUid(Uint8List uid)              // must be 32 bytes
static bool checkUidApi(Uint8List uid, String apiName)
static bool checkP2PName(String p2pName)
static bool checkP2PNameApi(String p2pName, String apiName)
```

### `BridgeFfi` / `BridgeException` / `BridgeErrorCode`

```dart
// ---- BridgeFfi: the FFI bindings for the C bridge ----
static BridgeFfi load()                    // loads lf_dart_bridge.dll
static BridgeFfi get instance              // throws StateError if not loaded
static void resetForTest()                 // for tests

// ---- BridgeException ----
class BridgeException implements Exception {
  final int code;                          // an LFB_ErrorCode constant
  final String message;
  final String? operation;
}

// ---- the BridgeErrorCode constants ----
BridgeErrorCode.ok                = 0
BridgeErrorCode.notInitialized    = 1
BridgeErrorCode.libraryNotLoaded  = 2
BridgeErrorCode.nullHandle        = 3
BridgeErrorCode.bufferTooSmall    = 4
BridgeErrorCode.invalidArgument   = 5
BridgeErrorCode.lingofuseFailed   = 6
BridgeErrorCode.bridgeInternal    = 7
BridgeErrorCode.dartPostFailed    = 8
BridgeErrorCode.timeout           = 9  // reserved, currently unused
```

### The exception hierarchy

Every exception inherits from `LingoFuseError`:

```dart
class LingoFuseError implements Exception
class LingoFuseLibraryLoadError extends LingoFuseError   // DLL load failure
class LingoFuseCallError extends LingoFuseError          // remote call failure
class LingoFuseTimeoutError extends LingoFuseError       // timeout (reserved; async currently throws TimeoutException)
class LingoFuseIoError extends LingoFuseError            // handle I/O failure
class LingoFuseObjectDisposedError extends LingoFuseError // object already disposed
class LingoFuseCallbackError extends LingoFuseError      // exception inside a callback
class LingoFuseRegistrationError extends LingoFuseError  // P2P registration failure
```

**Note**: a timeout on `Target.call(...)` **currently throws Dart's built-in `TimeoutException`** (from `dart:async`), not `LingoFuseTimeoutError`. Catch it accordingly:

```dart
try {
  await target.call('api', payload: {...}).future;
} on TimeoutException catch (e) {
  // timeout
} catch (e) {
  // some other error
}
```

---

## Runtime options

Set them through `Framework.setOption(name, value)` (the Legacy string interface) or `Framework.setOpt*` (the v2.0 typed interface).

| Option | Type | Default | When it takes effect | Notes |
|---|---|---|---|---|
| `password` / `passwd` | string | `DTC40@ZSERVER` | immediately | the C4 network authentication password |
| `Quiet` | bool | `False` | immediately | suppress internal logging |
| `ShowThreadID` | bool | `True` | immediately | show thread IDs in the log |
| `ConsoleOutput` | bool | auto | immediately | the console output switch |
| `debug` | string | — | immediately | executes a C4 console command (write side) |
| `Overlap_Connection` | bool | `False` | before `prepareClient` | allow several clients on the same address |
| `Wait_Connection_ReadyOk` | bool | `True` | before `prepareDone` | whether to wait for all clients to be ready |
| `Wait_Connection_Timeout` | int ms | `30000` | before `prepareDone` | the wait timeout |
| `IPC_Serv_ThreadCount` | int | platform dependent | before the IPC server starts | the IPC server thread count |
| `IPC_Serv_MaxQueueLength` | int | platform dependent | before the IPC server starts | the IPC message queue length |
| `IPC_Serv_MaxMsgSize` | int | platform dependent | before the IPC server starts | the maximum bytes in one IPC message |
| `Fixed_Sequenced_Time` | int ms | `20000` | immediately | the stickiness window for sequenced notifications |
| `LF_P2P_name` | string | `''` | the next request | the P2P group name this process declares |
| `DataHandle_Idle_Timeout` | int ms | `600000` | after `prepareDone` | the data handle idle-reclaim threshold |
| `DataHandle_Pool_Scan_Interval` | int ms | `5000` | after `prepareDone` | the handle pool scan interval |
| `No_Reponse_Cmd_NULL_Flush_Threshold` | int | `5000` | immediately | the NULL flush threshold for one-way commands |

**Boolean format**: `"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` / `"No"` (case-insensitive).

**Unknown option names are silently ignored** — a typo gives no feedback at all, so check them carefully.

**Options do not persist across `LF_Shutdown`** — they must be set again when the framework is restarted.

---

## Cleanup order

You **must** clean up in the following order, otherwise you may get a crash or a resource leak:

```dart
// 1. release the App (unbind + stop the sequenced notification threads)
app.dispose();

// 2. stop the simulated main thread (drain the data handle pool, including permanent ones)
Framework.exitMainThread();

// 3. release native resources (drain the application pool, unload the IPC library)
Framework.shutdown();

// 4. close the Dart-side port listener
BridgeHost.instance.stop();
```

Use `try/finally` so every exit path runs it:

```dart
try {
  // ... business code ...
} finally {
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
}
```

**How `BridgeHost.stop()` relates to `Framework.shutdown()`**:

- `Framework.shutdown()` releases **the LingoFuse framework** (process-level network state, the App pool, the handle pool)
- `BridgeHost.stop()` releases **the C bridge layer** (`ReceivePort`, the pending op table, the native mutex)
- the two are **independent** and both must be called; usually the bridge goes last

---

## Troubleshooting

### `[FAIL] Couldn't find libclang.dll`

`ffigen` cannot find LLVM. Confirm `pubspec.yaml` has an `llvm-path` entry:

```yaml
ffigen:
  llvm-path:
    - 'C:\LLVM'
    - 'C:\LLVM\bin'
```

### `LF_CreateData returned null`

The DLL loaded but the allocation failed. Possible causes:
- the DLL version does not match the header
- out of memory

Use [Dependencies](https://github.com/lucasg/Dependencies) to check that every dependency of `LingoFuse64.dll` resolves.

### `Could not load lf_dart_bridge.dll`

- confirm `dart\lf_dart_bridge.dll` exists
- or set the environment variable `LINGOFUSE_BRIDGE_DLL` to the full path
- or use `dart\bridge\lf_dart_bridge.dll` (`BridgeFfi.load()` searches it automatically)

### `BridgeHost is not started`

Before `AppHandle.registerCall` you must call `await BridgeHost.start()`. Every bridge method such as `LingoFuseStatus.checkUid` / `Framework.uidCall` / `Target.call` also requires the bridge to be started.

### `BridgeHost has been stopped`

`BridgeHost.instance` is unusable after `stop()`. To use it again you must call `await BridgeHost.start()` once more.

### A remote call returns nothing

- use `checkApp` to confirm the target application is visible (the mesh broadcast has about a 3-second delay)
- confirm the API name is spelled correctly (case-insensitive, but it must match exactly)
- increase `timeoutMs`

### `execute call-mode api "xxx" (stdcall) execpet!`

An exception inside the callback. Common causes:
- `Dart_InitializeApiDL(NULL)` was skipped (the C bridge must be handed the real `NativeApi.initializeApiDLData` from Dart)
- the Dart process was not restarted after rebuilding `lf_dart_bridge.dll`

### ⚠️ Calling an async method on `AppTarget` / `UIDTarget` from the Dart main isolate deadlocks

**This is the most important pitfall.**

Under **local-first routing**, if this process has an App with the same name / the same UID, `LF_Async_Call` **runs the handler synchronously on the caller's thread**. The Dart main isolate issues an FFI call → Pascal hits the local target → the bridge's Protocol A callback fires synchronously → the native side blocks waiting for Dart → but the Dart main isolate is stuck inside the FFI call and cannot process messages → **deadlock in both directions**.

**The fix**: when issuing an async call from the Dart main isolate, **you must use `P2PNameTarget`**:

```dart
// ❌ deadlocks
final target = AppTarget('MyApp');
await target.call('api', payload: {...}).future;

// ✅ safe (P2PName does no local lookup and always goes through the server's own thread)
final target = P2PNameTarget('my_group');
await target.call('api', payload: {...}).future;
```

**Why P2PName is safe**: P2PName routing **does not check locally** and always forwards to the server dispatcher. The server runs the handler on **its own native thread**, so the Dart main isolate's OS thread is never occupied.

**An alternative**: call from a child isolate (see the `Isolate.run` usage in `test/server_test.dart`).

### Tests hang

- remote calls (`Framework.call` / `callSync`) **must run in a child isolate**, otherwise the main isolate's event loop is blocked and Dart-side callbacks cannot respond
- when issuing async calls from the main isolate, use `P2PNameTarget`
- confirm `concurrency: 1` in `dart_test.yaml` is in effect

### `dart test` shows `+N -M` with no failure details

```powershell
dart test --reporter expanded --chain-stack-traces
```

---

## Known limitations

### 1. `NativeCallable` is asynchronous

That is fundamental to Dart FFI's design; the C bridge solves it by blocking and waiting, but that introduces **one thread hop per callback**. In high-frequency scenarios the performance is below that of the native Rust / C++ bindings.

### 2. Single-threaded serialization

The C bridge's `g_state.pending_head` list and `pending_lock` keep it thread-safe, but every Call / Notify callback ultimately runs serially on the Dart main isolate's event loop. A Dart server cannot handle several Call requests in parallel.

**If you need a highly concurrent server on the Dart side**, consider:
- using several Dart processes
- or an `Isolate` pool to spread the load
- or switching to the Rust / C++ / Go binding

### 3. Isolate affinity of async calls

When issuing an async call from the Dart main isolate, **only `P2PNameTarget` can be used**. The async methods of `AppTarget` / `UIDTarget` deadlock on the main isolate (reason above). This is an **architectural limitation**, not a bug. If you must use App-name / UID addressing from the main isolate, you can only fall back to the synchronous `call` or use a child isolate.

### 4. `LingoFuseTimeoutError` is unused

`errors.dart` defines `LingoFuseTimeoutError`, but the async API actually throws Dart's built-in `TimeoutException`. Catch them separately:

```dart
try { ... } on TimeoutException catch (e) { ... }  // async timeout
try { ... } on LingoFuseError catch (e) { ... }    // other LF errors
```

A future version may unify them; for now, be aware of this.

### 5. NetworkEvents has no Dart-side wrapper

`BridgeHost.setNetworkEvent` is implemented (the underlying channel is ready), but there is no abstraction class such as `NetworkEventListener`. Users must call `BridgeHost.instance.setNetworkEvent(...)` directly, and the callback signature is `void Function(String addr)`.

### 6. Flutter Web is unsupported

Dart FFI is unavailable on Flutter Web (Web is a JS runtime).

### 7. 32-bit Windows is untested

In theory `LingoFuse32.dll` + a 32-bit `dart.exe` should work, but it has not been verified.

### 8. Big-endian platforms are untested

The protocol specifies little-endian, but no endianness adaptation has been done for big-endian platforms (such as certain MIPS / PowerPC servers).

---

## Related projects

- [the LingoFuse main repository](https://github.com/PassByYou888/LingoFuse)
- [LingoFuse-Tools (the code generator)](https://github.com/PassByYou888/LingoFuse-Tools)
- [zIPC (the on-machine IPC engine)](https://github.com/PassByYou888/zIPC)

---

## License

MIT.

---

*Binding version: 0.2.0 (the v2.0 feature upgrade)*
*Target LingoFuse version: v5.x or later (including the v3.2 ABI revision + the LF-ASYNC family)*
*Last updated: 2026-10-15*

