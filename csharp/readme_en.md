# The LingoFuse C# binding

> Chinese version: [readme.md](readme.md)

> **The official C# binding of the cross-language communication foundation: full tests, three-way HTTP Bridge, cross-language ABI interop, UID / P2PName addressing, Task-based async calls, callback-style async, pluggable callback thread dispatch.**
>
> This directory is the only starting point for .NET developers using LingoFuse. Reading this README tells you:
> - what the C# binding actually covers;
> - what each module is for;
> - which scenarios the tests cover;
> - where the common pitfalls are.

---

## 1. The conclusion first: how complete C# support is

The LingoFuse C# binding forms a complete closed loop — **not merely "the examples run", but a production-grade binding**.

| Dimension | Status | Notes |
|------|:----:|------|
| P/Invoke low-level binding | ✅ complete | `NativeMethods.cs` imports all **59** exported C ABI functions, with full XML comments |
| RAII wrappers | ✅ complete | `DataHandle` / `AppHandle`, supporting `using` and `IDisposable` |
| UID value type | ✅ complete | `P2PUid` — a 32-byte blittable struct, no `unsafe` needed |
| Unified JSON I/O | ✅ complete | `LfIo` is the only serialization entry point, guaranteeing cross-language byte identity |
| Strongly typed runtime options | ✅ complete | `RuntimeOptions` — covering all 16 `set_opt_xxx` / `get_opt_xxx` |
| Callback thread dispatch | ✅ complete | `CallbackDispatcher` — Inline / MainThread / single-thread queue / custom |
| Process-level facade | ✅ complete | `Framework` provides network preparation, remote calls, options and shutdown |
| App-name addressing | ✅ complete | `Call` / `Notify` / `SequencedNotify` + async variants |
| UID addressing | ✅ complete | `CallByUid` / `NotifyByUid` / `SequencedNotifyByUid` + async variants |
| P2PName addressing | ✅ complete | `CallByP2PName` / `NotifyByP2PName` / `SequencedNotifyByP2PName` + async variants |
| Async calls | ✅ complete | `Task<DataHandle>` — compatible with C# `await` and `SynchronizationContext` |
| Callback-style async ★ | ✅ complete | `Async.Call(..., r => {...})` — the call and the callback in one expression, aligned with C++ / Pascal |
| Sender identity | ✅ complete | `DataHandle.GetSenderUid` / `GetSenderP2PName` |
| Global P2P registration | ✅ complete | `Framework.RegisterP2PCall` / `RegisterP2PNotify` / `UnregisterP2P` |
| Network events | ✅ complete | `NetworkEvents` global connect / disconnect callbacks |
| Status and health checks | ✅ complete | the `LingoFuseStatus` status queue + liveness + UID / P2PName liveness |
| Exception hierarchy | ✅ complete | 5 exception types, covering loading / calls / I/O / disposed |
| Permanent handles | ✅ complete | `DataHandle.CreatePermanent` |
| Multithreaded concurrency | ✅ tested | 10 threads × 100 local calls; 8 threads × 500 independent handles |
| Cross-language ABI | ✅ tested | byte-by-byte little-endian verification, byte-identical with C++ / Pascal / Python |
| Cross-language JSON | ✅ tested | Emoji / Chinese with no `\uXXXX` escapes |
| Performance load test | ✅ available | `CrossCall` 32-thread load test |
| Test coverage | ✅ complete | `csharp/test/` about 60 cases (v4.0 regression) + `csharp/test2/` about 58 cases (v5.0 / v5.1 API), around 118 in total; both suites use a **home-grown TestCase/TestRunner** (not xUnit); the numbers evolve with the code, so take the actual `dotnet run` output as authoritative |
| Cross-platform | ✅ complete | Windows / Linux / macOS, with automatic dynamic library resolution |
| Documentation | ✅ complete | `LingoFuse_CSharp_Complete_Guide.md` v5.1, 17 chapters + 4 appendices |
| CI | ⚠️ local only | no GitHub Actions workflow at the repository root; C# testing is done locally (`csharp/build.ps1` / `dotnet run`) |

**Overall judgement**: the C# binding covers the whole chain — from low-level P/Invoke through high-level RAII wrappers, unified JSON I/O, cross-language ABI interop, UID / P2PName addressing, Task-based async calls, callback-style async, pluggable callback thread dispatch, network events and status checks — and ships with **about 118 runnable tests**.

---

## 2. Directory structure

```text
csharp/
├── src/
│   └── LingoFuse_cs/                  # the main binding library
│       ├── LingoFuse_cs.csproj        # the library project
│       ├── Async.cs                   # ★ v5.1  the callback-style async facade
│       ├── AsyncResult.cs             # ★ v5.1  the read-only callback result value type
│       ├── P2PUid.cs                  # ★ v5.0  the 32-byte UID value type
│       ├── CallbackDispatcher.cs      # ★ v5.0  the callback thread dispatch abstraction
│       ├── RuntimeOptions.cs          # ★ v5.0  strongly typed runtime options
│       ├── DataHandle.cs              # the RAII data handle (including the v5.0 GetSenderUid / GetSenderP2PName)
│       ├── AppHandle.cs               # the RAII app handle (including the v5.0 dispatcher overloads)
│       ├── Framework.cs               # the process-level facade (including v5.0 UID / P2PName / Async / P2P registration)
│       ├── LfIo.cs                    # unified JSON / string I/O
│       ├── NetworkEvents.cs           # global network events
│       ├── LingoFuseStatus.cs         # the status queue + health checks
│       ├── LingoFuseException.cs      # the exception hierarchy
│       └── Native/
│           ├── NativeMethods.cs       # P/Invoke declarations (the only native call site)
│           ├── NativeTypes.cs         # opaque handles + TUIDNative + callback prototypes
│           ├── Utf8Marshal.cs         # UTF-8 NUL-terminated string marshalling
│           └── AsyncCallbackBridge.cs # ★ v5.0  Task ↔ C ABI holder/trampoline
│
├── test/                              # the v4.0 regression suite (about 60 cases, home-grown TestCase/TestRunner)
│   ├── Program.cs
│   └── test.csproj
│
├── test2/                             # ★ the v5.0 / v5.1 suite (about 58 cases, home-grown TestCase/TestRunner)
│   ├── Program.cs
│   └── test2.csproj
│
├── CrossCall/                         # the load-test client
│   ├── CrossCall.cs                   # 32 threads × 10 seconds
│   └── CrossCall.csproj
│
├── CrossNode/                         # the worker node
│   ├── CrossNode.cs                   # registers the add / inv_seri APIs
│   └── CrossNode.csproj
│
├── CrossService/                      # the coordinator / beacon
│   ├── CrossService.cs
│   └── crossService.csproj
│
├── build.ps1                          # one-key build (supports -Target Test / Pack)
├── clean.ps1                          # one-key clean (including publish/ and artifacts/)
├── publish.ps1                        # one-key publish (supports -SkipTests)
├── lf_csharp.sln                      # the Visual Studio solution
├── LingoFuse_CSharp_Complete_Guide.md # the complete guide (v5.1, 17 chapters + 4 appendices)
└── readme.md                          # this file
```

---

## 3. The core modules in detail

### 3.1 `NativeMethods.cs` — P/Invoke declarations

**Responsibilities:**

- declare all **59** C ABI exports (expanded from 37 to 59 in v5.0).
- use `NativeLibrary.SetDllImportResolver` to select the platform library automatically:
  - Windows 64 → `LingoFuse64.dll`
  - Windows 32 → `LingoFuse32.dll`
  - Linux / BSD → `liblingofuse.so`
  - macOS → `liblingofuse.dylib`
- all functions use `CallingConvention.Cdecl`.
- string parameters are declared as `IntPtr`, with marshalling handled by `Utf8Marshal`.
- UID parameters use `TUIDNative` (a 32-byte blittable struct), binary-compatible with Pascal's `array[0..31] of Byte`.

**Note:** this is the internal layer; user code never calls it directly.

### 3.2 `NativeTypes.cs` — opaque handles + UID + callback prototypes

| Type | Description |
|------|------|
| `DataHnd` | a data handle (an `IntPtr` wrapper with `IsValid` / `Null`) |
| `AppHnd` | an app handle (same as above) |
| `TUIDNative` | ★ a 32-byte blittable UID (4 × `ulong`), passed by value through P/Invoke |
| `LfCallFunc` | the Call callback prototype `(trigger, input, output) → void`, `cdecl` |
| `LfNotifyFunc` | the Notify callback prototype `(trigger, input) → void`, `cdecl` |
| `LfNetworkEventFunc` | the network event callback prototype `(addr) → void`, `cdecl` |
| `LfAsyncCallOnResult` | ★ the async completion callback prototype `(data, result) → void`, `cdecl` |

**Key point:** every callback uses `[UnmanagedFunctionPointer(CallingConvention.Cdecl)]`.

### 3.3 `Utf8Marshal.cs` — UTF-8 marshalling

**Responsibilities:**

- `Alloc(string) → IntPtr`: allocate NUL-terminated UTF-8 unmanaged memory.
- `Free(IntPtr)`: release it.
- `PtrToString(IntPtr) → string`: copy out of unmanaged memory and decode.

**Contract:**

- memory returned by `Alloc` must be released by the caller with `Free`.
- `PtrToString` copies immediately; the source pointer may be released after it returns.
- `Free(IntPtr.Zero)` is a no-op.

### 3.4 `P2PUid.cs` — the 32-byte UID value type (★ v5.0)

**A `readonly struct` with value semantics and zero GC pressure.**

**Why a dedicated type is needed:**

- the UID is a first-class citizen of LingoFuse's routing model: the primary key of UID addressing; the return type of `GetSenderUid()` inside callbacks; a 32-byte binary blob that must round-trip byte by byte across languages.
- using `byte[]` brings mutability, reference equality and no 32-byte constraint.
- using `unsafe fixed byte[32]` requires `AllowUnsafeBlocks` (which this binding avoids).
- using 4 × `ulong`: blittable, no `unsafe`, no allocation, value equality.

**API:**

| Member | Signature |
|------|------|
| `Empty` | `static readonly P2PUid` (all zeros) |
| `IsEmpty` | `bool` |
| `FromBytes(ReadOnlySpan<byte>)` | `static P2PUid` (requires 32 bytes) |
| `TryParse(string?, out P2PUid)` | `static bool` (64 hex characters) |
| `Parse(string)` | `static P2PUid` |
| `ToByteArray()` | `byte[]` |
| `CopyTo(Span<byte>)` | `void` |
| `ToHexString()` | `string` (64 lowercase hex) |
| `ToString()` / `Equals` / `GetHashCode` / `==` / `!=` | structural equality |

**Byte order**: the 4 `ulong` fields are laid out little-endian (`_lo` covers bytes 0..7, `_hi` covers 8..15, `_top` covers 16..23, `_last` covers 24..31), byte-compatible with Pascal's `array[0..31] of Byte`.

**Usage**:

```csharp
var uid = input.GetSenderUid();
if (!uid.IsEmpty) sessions[uid] = new Session();

using var param = new DataHandle("api");
using var resp = Framework.CallByUid(uid, param, 5000);
```

**⚠️ A key trap**: the UID **is regenerated on every reconnect**. Caching it across a link loss makes `CallByUid` return a size-0 handle. It must be rediscovered after a reconnect (see §6.4).

### 3.5 `CallbackDispatcher.cs` — callback thread dispatch (★ v5.0)

**The abstraction**:

```csharp
public interface ILingoCallbackDispatcher
{
    void Dispatch(Action callback);
}
```

**The synchronous contract (the crux)**:

> **`Dispatch` must not return until the callback has finished executing.**

The reason: the C ABI's `input` / `output` handles **are valid only inside the callback body**. The native layer releases them the instant the callback function returns. If `Dispatch` were post-and-forget, the worker thread would return early → the framework would release the handles → the UI thread would touch freed memory → **use-after-free**.

So `Dispatch` has synchronous semantics. The worker thread blocks until the callback has run to completion on the target thread.

**The built-in dispatchers**:

| Name | Behaviour |
|------|------|
| `CallbackDispatcher.Inline` | the default. Runs directly on the worker thread, zero overhead |
| `CallbackDispatcher.MainThread` | posts to the captured `SynchronizationContext`, blocking the worker until done |
| `CallbackDispatcher.CreateSingleThreadedQueue(name?)` | a dedicated background thread + FIFO queue |
| `CallbackDispatcher.CreateCustom(Action<Action>)` | a user-supplied dispatch delegate |

**Capturing the main thread**:

```csharp
// when the UI thread starts up (WPF App.OnStartup / WinForms Main / MAUI MauiProgram / Avalonia OnFrameworkInit)
CallbackDispatcher.CaptureMainThread();
```

**⚠️ Deadlock risk**: if the UI thread blocks synchronously on `Framework.Call` while a worker tries to dispatch back to the UI thread → deadlock. Use `CallAsync` + `await` to avoid it.

**Exception policy**: the dispatcher **does not catch** callback exceptions — the bridge catches them and routes them through `Framework.ReportCallbackError`. The dispatcher must propagate exceptions **unchanged** back to the worker thread.

### 3.6 `RuntimeOptions.cs` — strongly typed runtime options (★ v5.0)

**Covers all 16 `set_opt_xxx` / `get_opt_xxx` options, with spelling checked at compile time.**

**Why it is needed:**

- the C ABI's `LF_SetOption(name, value)` is stringly-typed: unknown options are **silently ignored**, and a typo, a stray space or a wrong case makes the setting ineffective with no warning at all.
- values must be parsed by hand.
- there is no discoverable list.

**The complete property list**:

| Category | Property | Type |
|------|------|------|
| authentication | `Password` | `string` (the getter returns a mask) |
| logging | `Quiet` / `ShowThreadId` / `ConsoleOutput` | `bool` |
| logging | `SetDebugCommand(string)` | write-only |
| connection | `OverlapConnection` | `bool` |
| connection | `WaitConnectionReadyOk` | `bool` |
| connection | `WaitConnectionTimeoutMs` | `ulong` |
| IPC | `IpcServerThreadCount` / `IpcServerMaxQueueLength` / `IpcServerMaxMsgSize` | `int` |
| sequencing | `FixedSequencedTimeMs` | `ulong` |
| P2P | `P2PName` | `string` |
| handle pool | `DataHandleIdleTimeoutMs` / `DataHandlePoolScanIntervalMs` | `ulong` |
| flush | `NoReponseCmdNullFlushThreshold` | `int` |

**The escape hatch**: `GetRaw(string)` / `SetRaw(string, string)`.

**Value formats**: bools are written as `"True"` / `"False"` (canonical); reads also accept `"1"` / `"0"` / `"Yes"` / `"No"`. int / ulong use `InvariantCulture`. **Unknown options return a type-safe default and do not throw**.

**Scope**: process-level; lost after `Framework.Shutdown`.

### 3.7 `DataHandle.cs` — the data handle

**An RAII wrapper supporting `using`.**

Three kinds:

| Kind | How to create | Auto-reclaim | When released |
|------|----------|:--------:|----------|
| auto-reclaim | `new DataHandle(api)` | after 10 minutes idle | `Dispose` marks it, the next scan releases it |
| permanent | `DataHandle.CreatePermanent(api)` | never | `Dispose` releases it synchronously |
| borrowed | `DataHandle.FromRaw(raw, owned: false)` | managed by the native layer | `Dispose` is a no-op |

**The I/O families:**

| Family | Method | Behaviour |
|------|------|------|
| partial read | `ReadBytes(n)` | returns at most n bytes, never throws |
| exact read | `ReadBytesExact(n)` | throws `LingoFuseIoException` on fewer than n |
| Try family | `TryReadBytes` / `TryReadInt32` etc. | returns a bool, never throws |
| read-all | `ReadAllBytes()` | reads the remaining bytes |

**Atomic types (little-endian):** 10 kinds of Write + 10 kinds of exact Read + 10 kinds of TryRead.

**The string contract:**

- `WriteString(s)`: UTF-8 + NUL. An empty string writes 1 byte (the NUL).
- `ReadString()`: reads up to the first NUL, or to the end when there is no NUL. Invalid UTF-8 is replaced byte by byte with U+FFFD.

**Sender identity (★ v5.0):**

```csharp
public P2PUid GetSenderUid()
public string GetSenderP2PName()
```

**Valid only on the callback's `input` parameter**. Other handles return `P2PUid.Empty` / `""` and **do not throw**. The return values are **copies**, safe to store and pass across threads.

### 3.8 `LfIo.cs` — unified JSON / string I/O

**This is the toolchain's only serialization entry point.**

**The JSON serialization policy (private, not configurable):**

```csharp
new JsonSerializerOptions
{
    WriteIndented = false,
    Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    PropertyNameCaseInsensitive = false,
    DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    NumberHandling = JsonNumberHandling.Strict,
}
```

**The key guarantees:**

- **no `\uXXXX` escapes**: BMP characters and supplementary-plane characters (emoji) are all emitted as literal UTF-8.
- **`UnescapeSurrogatePairs`**: restores `\uD8xx\uDCxx` surrogate pairs to the original characters, so emoji bytes match Pascal / Python / C++.

**The API:**

| Method | Purpose |
|------|------|
| `WriteString` / `ReadString` | NUL-terminated strings |
| `WriteStringBytes` / `ReadStringBytes` / `ReadAllBytes` | byte streams |
| `WriteJson` / `ReadJson<T>` | JSON read/write |
| `TryReadJson<T>` | non-throwing JSON read |

**Why no public `JsonSerializerOptions`:** exposing them would tempt callers into building a second serialization path and breaking the wire-protocol contract. To change the JSON shape, annotate your types with `[JsonPropertyName]` / `[JsonIgnore]` / `[JsonConverter]`.

### 3.9 `AppHandle.cs` — the app handle

**An RAII wrapper, `IDisposable`.**

| Method | Purpose |
|------|------|
| `RegisterCall(api, desc, Action<DataHandle, DataHandle>)` | register a Call API (inline thread) |
| `RegisterCall(api, desc, handler, ILingoCallbackDispatcher)` | ★ v5.0 register a Call API (chosen thread) |
| `RegisterNotify(api, desc, Action<DataHandle>)` | register a Notify API (inline thread) |
| `RegisterNotify(api, desc, handler, ILingoCallbackDispatcher)` | ★ v5.0 register a Notify API (chosen thread) |
| `Unregister(api)` | unregister an API |
| `LocalCall(param)` | a local Call (runs the handler on the caller's thread) |
| `LocalNotify(param)` | a local Notify |
| `Bind()` | bind to idle clients |

**The callback model:**

- the user callback receives **borrowed** `DataHandle`s (owned = false).
- **do not `Dispose` the input/output handles inside a callback** (a no-op, but pointless).
- **callback exceptions are caught** and reported through `Framework.ReportCallbackError`.

**Thread safety:**

- all public methods are serialized under `_registrationsLock`, preventing races between registration and Dispose.
- `_handle` is declared `volatile`.

**Two-phase destruction:**

1. `Dispose` → `LF_FreeApp`: unbind the client + stop the sequenced-notify thread; the object is still in the global pool.
2. `Framework.Shutdown` → clears the pool, actually destroying all the objects.

### 3.10 `Framework.cs` — the process-level facade

**Responsibilities:**

| Category | Methods |
|------|------|
| network preparation | `ResetPrepare` / `PrepareService` / `PrepareClient` / `PrepareDone` / `ExitMainThread` |
| App-name sync | `Call` / `TryCall` / `Notify` / `SequencedNotify` |
| App-name async ★ | `CallAsync` / `CallSequencedAsync` |
| UID sync ★ | `CallByUid` / `NotifyByUid` / `SequencedNotifyByUid` |
| UID async ★ | `CallByUidAsync` / `CallByUidSequencedAsync` |
| P2PName sync ★ | `CallByP2PName` / `NotifyByP2PName` / `SequencedNotifyByP2PName` |
| P2PName async ★ | `CallByP2PNameAsync` / `CallByP2PNameSequencedAsync` |
| liveness ★ | `CheckUid` / `CheckUidApi` / `CheckP2PName` / `CheckP2PNameApi` |
| P2P registration ★ | `RegisterP2PCall` (×2) / `RegisterP2PNotify` (×2) / `UnregisterP2P` |
| options | `SetOption` (the raw string interface) |
| app names | `GenerateAppName` / `GetAppName` |
| shutdown | `Shutdown` |
| callback errors | the `CallbackErrorHandler` property |

**The key contracts:**

- `PrepareDone` **returns 1 only once per process**; a second call returns 0 (not a failure).
- `Call` returns a **size = 0 handle** on timeout, not null.
- `TryCall` returns `null` (an already disposed empty handle), or a non-empty `DataHandle`.
- `Shutdown` is idempotent.
- **the bridges for P2P registration are held in an internal static dictionary**, cleared on `Shutdown`.

### 3.11 `AsyncCallbackBridge.cs` — the Task bridge (★ v5.0, internal)

**Responsibilities:**

- wrap the 6 async call primitives of the C ABI as `Task<DataHandle>`.
- **a single trampoline**: every entry point shares one `LfAsyncCallOnResult` function-pointer constant.
- **GCHandle lifetime**: dispatch succeeded → the callback releases it; dispatch failed → the caller releases it; P/Invoke threw → `catch` releases it.
- **result materialization**: inside the callback body, **immediately copy** the payload of the framework-owned handle (in 1 MiB chunks) into a newly created owned handle — **never expose the framework-owned raw pointer**.
- **dispatch failure → a faulted `Task`**: throws `LingoFuseCallException`, unified with the synchronous path.

**The key design decision: no `RunContinuationsAsynchronously`**

`TaskCompletionSource` **does not set** `RunContinuationsAsynchronously`. The reason:

- keep semantics **consistent with the BCL's built-in async APIs** (`HttpClient.GetAsync` / `Stream.ReadAsync` / …).
- `await` **returns to that context** when a `SynchronizationContext` is present (the UI case).
- with no SyncContext (console / background services) the continuation runs inline on the completing thread.
- a user's explicit `ConfigureAwait(false)` forces inlining.

**⚠️ A local App-name async call completes synchronously (an important semantic)**:

When the target App is **this process**, the C ABI's `LF_Async_Call` fires the completion callback **synchronously before returning**. Consequences:

- the `Task<DataHandle>` is **already completed** when `CallAsync` returns.
- a subsequent `await` **does not suspend** — the continuation runs inline on the current thread, **posted to no SyncContext at all**.

Awaiting `CallAsync("LocalApp", ...)` on the UI thread leaves the continuation **still on the UI thread** — behaviourally correct (the UI thread never yielded), but different from the remote case's `SyncContext.Post`.

**Do not rely on `await` yielding**. If code must run on a specific thread, marshal explicitly.

### 3.12 `NetworkEvents.cs` — global network events

| Method | Purpose |
|------|------|
| `Set(onConnect, onDisconnect)` | install callbacks (**REPLACE semantics**) |
| `Clear()` | remove all callbacks |
| `IsInstalled` | whether any is installed |

**Semantics:**

- **Connect**: the first receipt of a server API broadcast. **Not a TCP connect.**
- **Disconnect**: the physical link is lost once. Automatic reconnection does not fire Disconnect.

**The thread contract:**

- callbacks run on a native worker thread.
- do not touch the UI.
- do not call blocking LF functions.
- the endpoint string is copied immediately into a managed string by the wrapper.

**GC keep-alive:** the wrapper keeps the `LfNetworkEventFunc` delegate alive through a static field.

### 3.13 `LingoFuseStatus.cs` — status and health checks

| Method | Purpose |
|------|------|
| `GetStatusCount()` | the number of pending messages (capped at 1000) |
| `GetStatus()` | fetch one message (static buffer, copied immediately) |
| `DrainStatus(max)` | batch fetch |
| `PostStatus(msg)` | inject a message |
| `CheckMainThread()` | whether the main thread is running |
| `CheckApp(name)` | probe an App (with **about 3 seconds of cache delay**) |
| `CheckApi(app, api)` | probe an API (same as above) |

**Note**: UID / P2PName liveness is `Framework.CheckUid` / `CheckP2PName`; see §3.10.

### 3.14 `LingoFuseException.cs` — the exception hierarchy

```text
LingoFuseException
├── LingoFuseLibraryLoadException    (loading failed — not currently thrown)
├── LingoFuseCallException           (remote call failed — TargetApp/TargetApi)
├── LingoFuseIoException             (short read / short write — Operation)
└── LingoFuseObjectDisposedException (use after dispose — ObjectName)
```

### 3.15 `Async.cs` / `AsyncResult.cs` — callback-style async (★ v5.1)

**A callback-style async facade that merges "the call + the callback" into a single expression.**

**Why it is needed:**

- the C++ binding uses `lingofuse::callAsync("App", req, [](AsyncResult r){...})`; the Pascal binding uses `LF.AsyncCallApp_P('App', Data, procedure(Result_) ...)`.
- the await style (`Framework.CallAsync`) **copies** the result into a new handle and hands it to a `Task`. Suited to UI applications.
- the callback style (`Async`) **lends** the result to the callback body and releases it when the callback returns. Suited to server-side logic, embedded scenarios and integrations consistent with C++/Pascal.

**The API:**

| Method | Purpose |
|------|------|
| `Async.Call(appName, request, onResult)` | App-name addressing |
| `Async.Call<T>(appName, apiName, payload, onResult)` | App-name + a JSON convenience overload |
| `Async.CallSequenced(...)` | App-name, FIFO |
| `Async.CallByUid(uid, request, onResult)` | UID addressing |
| `Async.CallByUidSequenced(...)` | UID, FIFO |
| `Async.CallByP2PName(group, request, onResult)` | P2PName addressing |
| `Async.CallByP2PNameSequenced(...)` | P2PName, FIFO |

All methods return `void`; the completion signal comes out through `Action<AsyncResult>`.

**The AsyncResult contract:**

| Member | Description |
|------|------|
| `Ok` | `true` = a result handle was obtained; `false` = dispatch failed |
| `Error` | the reason when `Ok == false` |
| `Size` | the payload byte count |
| `Handle` | a borrowed `DataHandle`, valid only inside the callback body |
| `ReadString()` / `ReadAllBytes()` / `ReadJson<T>()` | convenience methods that copy the data |

**Lifetime**: an `AsyncResult` is valid only while the callback lambda is executing. The framework releases the underlying handle immediately once the lambda returns. This is exactly consistent with C++'s `AsyncResult` and Pascal's `Result_` parameter.

**Dispatch failure**: when `LF_Async_*` returns 0, `Async` calls the callback **synchronously on the caller's thread** with `Ok == false`. A single error path.

**A shared trampoline** (`s_trampoline`), kept strongly referenced by a static field. Callback exceptions are caught and reported through `Framework.ReportCallbackError`.

**The simplest example:**

```csharp
Async.Call("Calculator", "add",
    new { a = 10, b = 20 },
    r =>
    {
        if (!r.Ok) { Console.Error.WriteLine(r.Error); return; }
        var v = r.ReadJson<JsonElement>();
        Console.WriteLine($"10 + 20 = {v.GetProperty("result").GetInt32()}");
    });
```

---

## 4. Testing and verification

### 4.1 The two test suites

| Suite | Cases | Coverage |
|------|:----:|------|
| `test` (v4.0) | about 60 | DataHandle, AppHandle, LfIo, Framework, network integration, cross-language ABI, concurrency, stress |
| `test2` (v5.0 / v5.1) | about 58 | P2PUid, RuntimeOptions, side data, CallbackDispatcher, UID addressing, P2PName addressing, async (App / UID / P2PName), P2P registration, dispatcher integration, callback-style async (10 cases) |

**About 118 tests in total.** The numbers evolve with the code; for the exact pass/total figures take the actual `dotnet run` output as authoritative.

**Both suites use a home-grown TestCase/TestRunner** — not xUnit, and no `[Fact]` / `[TestMethod]` attributes. The runners live in `test/Program.cs` and `test2/Program.cs` respectively, tallying passes / failures per category and printing a summary.

### 4.2 `test/Program.cs` — the v4.0 regression tests (about 60 cases)

**The test categories:**

| Category | Count | Coverage |
|------|:----:|----------|
| `DataHandle` | 19 | basic types, Unicode, tolerant reads, position and size, Dispose safety, NUL termination, empty strings, large buffers, embedded NULs, mixed fields, zero length, exact reads, the Try family, read-all, permanent handle creation / survival / synchronous release |
| `AppHandle` | 10 | register / local call, duplicate registration, re-registration, case insensitivity, a callback with no output, exception isolation, LocalNotify, LocalCallBinary, LocalNotifyBinary, Dispose safety |
| `LfIo` | 7 | JSON POCO round trips, null values, Unicode (no `\uXXXX`), arrays, numbers, TryReadJson, ReadJson throwing |
| `Framework` | 5 | SetOption does not throw, ResetPrepare does not throw, GenerateAppName, PrepareDone only once, Shutdown idempotence |
| network integration | 8 | a single-address JSON call, a missing target returning an empty handle, a long-string round trip, Notify, SequencedNotify FIFO, CheckApp / CheckApi, NetworkEvents, the status queue |
| cross-language ABI | 5 | CallBinary int32, multi-type round trips, byte-by-byte little-endian verification, NotifyBinary, SequencedNotifyBinary |
| concurrency | 2 | 10 threads × 100 local calls, 8 threads × 500 independent handles |
| stress | 2 | 1000 sequential local calls, 100 App create/destroy cycles |

### 4.3 `test2/Program.cs` — tests for the new v5.0 / v5.1 APIs (about 58 cases)

**The test categories:**

| Category | Count | Coverage |
|------|:----:|----------|
| `P2PUid` | 6 | `Empty` / `FromBytes` / length validation / `TryParse` / `ToHexString` / `CopyTo` / equality / dictionary keys |
| `RuntimeOptions` | 8 | bool / logging / ulong / int / string round trips; the password mask; `GetRaw`/`SetRaw`; defaults for unset options |
| `DataHandle` side data | 4 | input handles carry identity / output handles are empty / self-created handles are empty / a disposed handle throws |
| `CallbackDispatcher` | 6 | Inline on the same thread / SingleThreadedQueue on a different thread / blocks the caller / Custom wrapping / null rejected / fallback when nothing is installed |
| UID addressing | 5 | self-discovery / `CallByUid` / `NotifyByUid` / `SequencedNotifyByUid` FIFO / `CheckUid` + `CheckUidApi` |
| P2PName addressing | 5 | `CallByP2PName` / `NotifyByP2PName` / `SequencedNotifyByP2PName` FIFO / `CheckP2PName` + `CheckP2PNameApi` / an unknown group returning an empty result |
| Async App name | 4 | `CallAsync` / `CallSequencedAsync` FIFO / **await returning to the SyncContext** / 8-way concurrency |
| Async UID/P2PName | 4 | `CallByUidAsync` / `CallByUidSequencedAsync` / `CallByP2PNameAsync` / `CallByP2PNameSequencedAsync` |
| P2P registration | 3 | `RegisterP2PCall` / `RegisterP2PNotify` / `UnregisterP2P` (including duplicate / missing / null edge cases) |
| Dispatcher integration | 1 | register an API with a dispatcher and verify the handler runs on the dispatcher thread, not the caller's |
| **Async callback style** ★ | **10** | Call JSON / Call DataHandle / synchronous dispatch failure / CallSequenced FIFO / CallByUid / CallByUidSequenced FIFO / CallByP2PName / CallByP2PNameSequenced FIFO / callback exception isolation / chained calls |

**How to run them:**

```bash
cd test2
dotnet run
```

**Output:** the pass count / failure count / elapsed time per category, plus failure details. **All PASS is expected**; the exact pass count evolves with the code, so take the actual `dotnet run` output as authoritative.

### 4.4 The cross demo — three-way joint debugging

| Program | Role |
|------|------|
| `CrossService` | coordinator / beacon, listening on `ipc:cross` |
| `CrossNode` | worker node, registering the `add` / `inv_seri` APIs of the `demo` app |
| `CrossCall` | load-test client, 32 threads × 10 seconds |

**Running in three terminals:**

```bash
# terminal 1
dotnet run --project CrossService

# terminal 2 (after terminal 1 prints running)
dotnet run --project CrossNode

# terminal 3 (after terminal 2 prints Online)
dotnet run --project CrossCall
```

**Cross-language verification:** the C# `CrossCall` can call the C++ / Pascal / Python `CrossNode`, and vice versa — the wire protocol is byte-identical.

### 4.5 One-key build / test

```powershell
# clean
.\clean.ps1 -IncludePackages

# build + run all tests (both test and test2 are console harnesses, executed with dotnet run)
.\build.ps1 -Configuration Release -Target Test

# run only the v5.0 / v5.1 tests
.\build.ps1 -Project .\test2\test2.csproj -Configuration Release -Target Test

# pack (packs only LingoFuse_cs.csproj)
.\build.ps1 -Configuration Release -Target Pack

# publish (skipping the test projects)
.\publish.ps1 -SkipTests
```

---

## 5. Getting started

### 5.1 Adding the reference

```xml
<ItemGroup>
  <ProjectReference Include="..\src\LingoFuse\LingoFuse.csproj" />
</ItemGroup>
```

### 5.2 A minimal server

```csharp
using System;
using LingoFuse;

using var app = new AppHandle("Calculator", "Demo calculator");

app.RegisterCall("add", "Add two ints", (input, output) =>
{
    var args = LfIo.ReadJson<int[]>(input);
    LfIo.WriteJson(output, new { result = args[0] + args[1] });
});

RuntimeOptions.OverlapConnection = true;
Framework.ResetPrepare();
Framework.PrepareService("ipc:calc", "ipc:calc");
Framework.PrepareClient("ipc:calc", app);

if (Framework.PrepareDone() != 1)
{
    Console.Error.WriteLine("Startup failed");
    return;
}

Console.WriteLine("Ready. Press Enter to stop.");
Console.ReadLine();

NetworkEvents.Clear();
Framework.ExitMainThread();
app.Dispose();
Framework.Shutdown();
```

### 5.3 A minimal client (synchronous)

```csharp
using System;
using System.Text.Json;
using LingoFuse;

RuntimeOptions.WaitConnectionReadyOk = true;
RuntimeOptions.OverlapConnection = true;
Framework.ResetPrepare();
Framework.PrepareClient("ipc:calc", null);

if (Framework.PrepareDone() != 1)
{
    Console.Error.WriteLine("Startup failed");
    return;
}

using var request = new DataHandle("add");
LfIo.WriteJson(request, new[] { 5, 7 });

using var response = Framework.Call("Calculator", request, timeoutMs: 3000);
if (response.Size == 0)
{
    Console.WriteLine("Call failed (timeout or unreachable)");
    return;
}

var result = LfIo.ReadJson<JsonElement>(response);
Console.WriteLine($"5 + 7 = {result.GetProperty("result").GetInt32()}");

NetworkEvents.Clear();
Framework.ExitMainThread();
Framework.Shutdown();
```

### 5.4 A minimal client (asynchronous, ★ v5.0)

```csharp
static async Task Main()
{
    RuntimeOptions.WaitConnectionReadyOk = true;
    RuntimeOptions.OverlapConnection = true;
    Framework.ResetPrepare();
    Framework.PrepareClient("ipc:calc", null);
    Framework.PrepareDone();

    using var request = new DataHandle("add");
    LfIo.WriteJson(request, new[] { 5, 7 });

    // the await continuation follows native C# await semantics:
    //   - with a SyncContext → posted back to it
    //   - with no SyncContext → inlined on the completing thread
    using var response = await Framework.CallAsync("Calculator", request);

    var result = LfIo.ReadJson<JsonElement>(response);
    Console.WriteLine($"5 + 7 = {result.GetProperty("result").GetInt32()}");

    NetworkEvents.Clear();
    Framework.ExitMainThread();
    Framework.Shutdown();
}
```

### 5.5 A minimal client (callback style, ★ v5.1)

Compared with the await style of §5.4, this version merges "the call + the callback" into a single expression, fully isomorphic with C++'s `lingofuse::callAsync` and Pascal's `LF.AsyncCallApp_P`.

```csharp
using System;
using System.Text.Json;
using LingoFuse;

RuntimeOptions.WaitConnectionReadyOk = true;
RuntimeOptions.OverlapConnection = true;
Framework.ResetPrepare();
Framework.PrepareClient("ipc:calc", null);
Framework.PrepareDone();

// Build the request once, dispatch it, and handle the result in a
// single expression. The callback runs on a native worker thread;
// AsyncResult is valid only inside the callback body.
Async.Call("Calculator", "add",
    new { a = 5, b = 7 },
    r =>
    {
        if (!r.Ok) { Console.Error.WriteLine(r.Error); return; }
        var v = r.ReadJson<JsonElement>();
        Console.WriteLine($"5 + 7 = {v.GetProperty("result").GetInt32()}");
    });

Console.ReadLine();   // keep the process alive

NetworkEvents.Clear();
Framework.ExitMainThread();
Framework.Shutdown();
```

**Note**: this example has no `await`, so the host method need not be `async`. The callback style has zero contagion on the call stack.

---

## 6. Advanced usage

### 6.1 The ABI cross-language channel

No JSON; binary scalars are read and written directly, byte-identical with C++ / Pascal / Python.

```csharp
// server
app.RegisterCall("add", "Add two ints", (input, output) =>
{
    int a = input.ReadInt32();
    int b = input.ReadInt32();
    output.WriteInt32(a + b);
});

// client
using var request = new DataHandle("add");
request.WriteInt32(15);
request.WriteInt32(27);
using var response = Framework.Call("demo", request, 3000);
int sum = response.ReadInt32();   // 42
```

**The wire format:**

```text
request:  [a: int32 little-endian][b: int32 little-endian]
response: [sum: int32 little-endian]
```

### 6.2 Permanent handles

```csharp
using var template = DataHandle.CreatePermanent("my_api");
template.WriteString("template-payload");
// reused repeatedly across the whole process lifetime
// Dispose before exit (synchronous release)
```

### 6.3 UID addressing (★ v5.0)

```csharp
// a synchronous call
using var param = new DataHandle("compute");
using var resp = Framework.CallByUid(targetUid, param, 5000);

// an asynchronous call
using var resp2 = await Framework.CallByUidAsync(targetUid, param);

// liveness probe
if (Framework.CheckUid(targetUid))
{
    // the target is online
}
```

**Compared with App-name addressing:**

- **App name**: knowing the App name → route to any client hosting that App (local first).
- **UID**: knowing a specific session UID → route to any API that client registered (**without knowing the App name**, local first).

### 6.4 Sender identity (the whoami pattern, ★ v5.0)

**The server registers a whoami API**:

```csharp
app.RegisterCall("whoami", "Return caller identity", (input, output) =>
{
    var uid = input.GetSenderUid();
    var p2p = input.GetSenderP2PName();
    output.WriteString(uid.ToHexString());
    output.WriteString(p2p);
});
```

**A client calling itself**:

```csharp
var uidHolder = new StrongBox<P2PUid>(P2PUid.Empty);

app.RegisterCall("__probe__", "capture identity",
    (input, output) =>
    {
        uidHolder.Value = input.GetSenderUid();
        output.WriteString(uidHolder.Value.ToHexString());
    });

using var p = new DataHandle("__probe__");
using var resp = Framework.Call(appName, p, 5000);
var selfUid = uidHolder.Value;   // this process's UID
```

**⚠️ The UID changes on reconnection**. You must run whoami again after every Connect event.

### 6.5 P2PName addressing (★ v5.0)

**The server (worker nodes, start N copies)**:

```csharp
RuntimeOptions.P2PName = "compute_group";       // join the group
RuntimeOptions.WaitConnectionReadyOk = true;

using var app = new AppHandle("Worker", "compute worker");
app.RegisterCall("compute", "do work", (input, output) =>
{
    // ...
});

Framework.ResetPrepare();
Framework.PrepareClient("ipc:beacon", app);
Framework.PrepareDone();
```

**The client (any process)**:

```csharp
using var param = new DataHandle("compute");
using var resp = Framework.CallByP2PName("compute_group", param, 5000);
// the server load-balances across the group members by Cycle_Anchor
```

**⚠️ P2PName routing is not local first** — even when this process has a group member, the call still goes over the network.

### 6.6 Asynchronous calls (★ v5.0)

**A concurrent fan-out**:

```csharp
var tasks = new List<Task<DataHandle>>();
for (int i = 0; i < 16; i++)
{
    var p = new DataHandle("echo_n");
    p.WriteInt32(i);
    tasks.Add(Framework.CallAsync("compute_node", p));
}

var results = await Task.WhenAll(tasks);
foreach (var r in results)
{
    using (r) { Console.WriteLine(r.ReadInt32()); }
}
```

**Chained calls**:

```csharp
using var login = new DataHandle("login");
LfIo.WriteJson(login, new { user = "alice" });
using var loginResp = await Framework.CallAsync("AuthSvc", login);
var token = LfIo.ReadJson<JsonElement>(loginResp)
    .GetProperty("token").GetString()!;

using var fetch = new DataHandle("fetch");
LfIo.WriteJson(fetch, new { token });
using var fetchResp = await Framework.CallAsync("DataSvc", fetch);
// process fetchResp
```

**A soft-timeout composition**:

```csharp
var pending = Framework.CallAsync("App", param);
var delay = Task.Delay(TimeSpan.FromSeconds(5));
var completed = await Task.WhenAny(pending, delay);

if (completed == delay)
{
    // soft timeout: the underlying holder is still occupied until the framework finally fires the completion callback
}
else
{
    using var response = await pending;
    // ...
}
```

### 6.7 Callback-style async (★ v5.1)

**The simplest form**:

```csharp
using System.Text.Json;
using LingoFuse;

Async.Call("Calculator", "add",
    new { a = 10, b = 20 },
    r =>
    {
        if (!r.Ok) { Console.Error.WriteLine(r.Error); return; }
        var v = r.ReadJson<JsonElement>();
        Console.WriteLine($"10 + 20 = {v.GetProperty("result").GetInt32()}");
    });
```

**The DataHandle form**:

```csharp
using var request = new DataHandle("inv_seri");
request.WriteUInt8(200);
request.WriteUInt16(0x10);
request.WriteUInt32(0x2F);
request.WriteString("hello");

Async.Call("CrossNode", request,
    r =>
    {
        if (!r.Ok || r.Size == 0) return;
        var b   = r.Handle.ReadUInt8();
        var w   = r.Handle.ReadUInt16();
        var c   = r.Handle.ReadUInt32();
        var msg = r.Handle.ReadString();
        // ...
    });
```

**Starting another async call inside the callback (chaining)**:

```csharp
Async.Call("AuthSvc", "login", new { user = "alice" },
    r1 =>
    {
        if (!r1.Ok) return;
        string token = r1.ReadJson<JsonElement>()
            .GetProperty("token").GetString()!;

        Async.Call("DataSvc", "fetch", new { token },
            r2 =>
            {
                if (!r2.Ok) return;
                var data = r2.ReadJson<JsonElement>();
                myMainThreadQueue.Enqueue(data);
            });
    });
```

**Dispatch failure**: when `LF_Async_*` returns 0, the callback fires **synchronously on the caller's thread** with `Ok == false`. A single error path.

**Choosing between the two styles**:

| Scenario | Recommended |
|------|------|
| UI applications (WPF / WinForms / MAUI / Avalonia) | `await Framework.CallAsync(...)` |
| needing automatic `SynchronizationContext` marshalling | `await Framework.CallAsync(...)` |
| needing `Task.WhenAll` / `Task.WhenAny` composition | `await Framework.CallAsync(...)` |
| server-side callback logic, embedded, scripted | `Async.Call(..., r => { ... })` |
| teams wanting consistency with C++ / Pascal integration | `Async.Call(..., r => { ... })` |
| wanting to avoid `async`/`await` contagion through the whole call stack | `Async.Call(..., r => { ... })` |

The two can be mixed freely; they share the underlying C ABI.

### 6.8 Global P2P registration (★ v5.0)

```csharp
// register a process-level Call API
Framework.RegisterP2PCall("capabilities",
    "Return capabilities",
    (input, output) =>
    {
        LfIo.WriteJson(output, new { version = "5.1" });
    });

// register a process-level Notify API
Framework.RegisterP2PNotify("health_ping",
    "Ping handler",
    input => Console.WriteLine($"[ping] {input.ReadString()}"));

// peers can call it by UID or P2PName addressing:
//     Framework.CallByUid(someUid, new DataHandle("capabilities"));
//     Framework.CallByP2PName("some_group", new DataHandle("capabilities"));

// unregister
Framework.UnregisterP2P("capabilities");
```

**P2P APIs are reachable only via UID / P2PName addressing, never via App name**.

### 6.9 Callback thread dispatch (★ v5.0)

**A UI-thread handler**:

```csharp
// when the UI starts
CallbackDispatcher.CaptureMainThread();

using var app = new AppHandle("UIApp", "UI service");

app.RegisterCall("update_label", "Update label",
    (input, output) =>
    {
        // runs on the UI thread
        MyLabel.Text = input.ReadString();
        output.WriteString("ok");
    },
    CallbackDispatcher.MainThread);
```

**A single-thread queue handler**:

```csharp
using var dispatcher =
    CallbackDispatcher.CreateSingleThreadedQueue("db-writer");

app.RegisterCall("write_db", "Write to DB",
    (input, output) =>
    {
        // runs on the dedicated thread, in FIFO order
        // ...
    },
    dispatcher);
```

**A custom dispatcher**:

```csharp
var dispatcher = CallbackDispatcher.CreateCustom(callback =>
{
    // your own scheduling logic
    // it must be synchronous: the callback has finished before this returns
    myCustomScheduler.Post(callback);
    myCustomScheduler.WaitUntilDone();
});
```

### 6.10 Network events

```csharp
NetworkEvents.Set(
    onConnect: addr => Console.WriteLine($"[+] {addr}"),
    onDisconnect: addr => Console.WriteLine($"[-] {addr}"));

// ... run ...

NetworkEvents.Clear();
```

### 6.11 Callback error handling

```csharp
Framework.CallbackErrorHandler = (source, ex) =>
{
    logger.Error($"[LingoFuse] {source}: {ex}");
};
```

### 6.12 JSON property naming

```csharp
public sealed class Request
{
    [System.Text.Json.Serialization.JsonPropertyName("user_name")]
    public string UserName { get; set; } = "";

    [System.Text.Json.Serialization.JsonPropertyName("request_id")]
    public int RequestId { get; set; }
}
```

Serializes as `{"user_name":"...","request_id":...}`.

### 6.13 Strongly typed runtime options (★ v5.0)

```csharp
RuntimeOptions.OverlapConnection = true;
RuntimeOptions.WaitConnectionReadyOk = true;
RuntimeOptions.WaitConnectionTimeoutMs = 10000;
RuntimeOptions.P2PName = "worker_group";
RuntimeOptions.Quiet = false;
RuntimeOptions.ShowThreadId = true;
RuntimeOptions.ConsoleOutput = true;

// reading (an unset option returns a type-safe default and does not throw)
bool quiet = RuntimeOptions.Quiet;
string p2p = RuntimeOptions.P2PName;

// the escape hatch: unknown / future options
RuntimeOptions.SetRaw("Some_Future_Option", "value");
string raw = RuntimeOptions.GetRaw("Some_Future_Option");
```

---

## 7. Configuration options

`RuntimeOptions` typed properties vs the raw string interface of `Framework.SetOption`:

| Option | RuntimeOptions property | Alias | Default | Notes |
|------|---------------------|------|------|------|
| authentication | `Password` | `passwd` | — | C4 P2PVM authentication (the getter returns a mask) |
| logging | `Quiet` | — | False | quiet mode |
| logging | `ShowThreadId` | `ShowThread` | True | log lines show the thread ID |
| logging | `ConsoleOutput` | `Console_Output` | auto | console logging |
| logging | `SetDebugCommand(string)` | `debug_cmd` etc. | — | execute a C4 debug command (write-only) |
| connection | `OverlapConnection` | `Overlap_Client` etc. | False | allow multiple clients on the same address |
| connection | `WaitConnectionReadyOk` | `Wait_Ready` etc. | True | whether to wait for clients to be ready |
| connection | `WaitConnectionTimeoutMs` | `Wait_TimeOut` etc. | 30000 | wait timeout in ms |
| IPC | `IpcServerThreadCount` | `IPC_ThreadCount` etc. | platform-dependent | IPC server thread count |
| IPC | `IpcServerMaxQueueLength` | `IPC_MaxQueueLength` etc. | platform-dependent | IPC queue length |
| IPC | `IpcServerMaxMsgSize` | `IPC_MaxMsgSize` etc. | platform-dependent | maximum IPC message size |
| sequencing | `FixedSequencedTimeMs` | `Fixed_Sequenced_Life` | 20000 | the sequenced-notify fallback threshold |
| P2P | `P2PName` | `P2P_name` etc. | empty | this process's P2P group name |
| handle pool | `DataHandleIdleTimeoutMs` | `Data_Idle_Timeout` etc. | 600000 | the idle reclaim threshold |
| handle pool | `DataHandlePoolScanIntervalMs` | `Data_Scan_Interval` etc. | 5000 | the pool scan interval |
| flush | `NoReponseCmdNullFlushThreshold` | — | 5000 | the Notify NULL flush threshold |

**Boolean value format:** `"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` / `"No"` (case-insensitive).

**Scope**: process-level; lost after `Framework.Shutdown`.

**Recommendation**: new code should prefer the `RuntimeOptions` properties — compile-time checking, type safety, and non-throwing reads. The raw `Framework.SetOption` is kept for future extension options.

---

## 8. The cleanup order

Strictly in this order:

```text
1. NetworkEvents.Clear()
2. Framework.ExitMainThread()
3. app.Dispose()
4. Framework.Shutdown()
```

| Step | Reason |
|------|------|
| 1 | prevent callbacks firing during the shutdown transition |
| 2 | stop the main thread, so no callback can fire |
| 3 | unbind the App, stop the sequenced-notify thread |
| 4 | release all native resources, including the App pool and the P2P bridge registry |

Use `finally` to guarantee it on every exit path:

```csharp
finally
{
    if (started)
    {
        try { NetworkEvents.Clear(); } catch { }
        try { Framework.ExitMainThread(); } catch { }
        try { app?.Dispose(); } catch { }
        try { Framework.Shutdown(); } catch { }
    }
}
```

---

## 9. Common pitfalls and FAQ

### 9.1 Never block inside a callback

**Symptom:** the whole process deadlocks.

**Cause:** callbacks run on a native worker thread, and `Framework.Call` needs the main thread to dispatch the response.

**Fix:** inside a callback never call `Framework.Call` / `Notify` / `SequencedNotify` / `LocalCall` / `LocalNotify` / `PrepareDone` / `Shutdown`. Push long-running work onto `Task.Run`.

### 9.2 `Call` returns size=0 on timeout, not null

**Fix:** test `response.Size == 0`, not `null`.

### 9.3 `PrepareDone` returns 1 only once per process

**Fix:** to restart the framework you must do `Shutdown` → `ResetPrepare` → `PrepareDone`.

### 9.4 API registration must come before `PrepareClient`

**Symptom:** the first call times out.

**Cause:** the `Init_App_Info` broadcast is sent at `PrepareClient` time. APIs registered afterwards are not in the broadcast.

**Fix:**

```csharp
using var app = new AppHandle("MyApp", "");
app.RegisterCall("api1", "...", ...);   // ← register first
app.RegisterCall("api2", "...", ...);
Framework.PrepareClient(endpoint, app); // ← bind afterwards
```

### 9.5 Multiple clients on the same address are silently ignored

**Fix:** set `RuntimeOptions.OverlapConnection = true` (before `PrepareClient`).

### 9.6 `CheckApp` / `CheckApi` / `CheckUid` / `CheckP2PName` have about 3 seconds of cache delay

**Fix:** retry in a loop, for up to 6 seconds.

### 9.7 `AppHandle.Dispose` does not release memory immediately

**Cause:** two-phase destruction; the object is only destroyed at `Framework.Shutdown`.

**Fix:** for long-running services, `Shutdown` and restart periodically, or do a single `Shutdown` at process exit.

### 9.8 `NetworkEvents.Set` has REPLACE semantics

**Fix:** pass both callbacks in one call, or `Clear` and then `Set`.

### 9.9 The difference between `LfIo.WriteJson` and `DataHandle.WriteBytes`

| Method | NUL terminated | Purpose |
|------|:--------:|------|
| `LfIo.WriteString` | ✅ | UTF-8 text |
| `LfIo.WriteJson` | ✅ | JSON text |
| `LfIo.WriteStringBytes` | ✅ | pre-encoded bytes |
| `DataHandle.WriteBytes` | ❌ | raw bytes, no terminator |

### 9.10 `TryReadJson` returns `true` but the value is `null`

**Cause:** the JSON payload is the literal `null` and `T` is a reference type.

**Fix:** check `v is not null` as well.

### 9.11 Using `DataHandle.FromRaw` outside a callback leaks

**Fix:** outside callbacks always use `new DataHandle("api")`.

### 9.12 `DataHandle.Raw` becomes invalid after a resize

**Fix:** never cache `Raw`. If you need to keep the data long-term, copy the bytes.

### 9.13 The side-data accessors return empty values on the wrong handle

**Symptom:** `GetSenderUid()` returns `P2PUid.Empty` and `GetSenderP2PName()` returns `""`.

**Cause:** calling them on an output handle or a self-created handle.

**Fix:** **call them only on the callback's `input` parameter**.

### 9.14 UIDs become invalid across a link loss

**Symptom:** `CallByUid` returns a size-0 handle.

**Cause:** the UID is regenerated on every reconnect.

**Fix:** run whoami again after every Connect event to rediscover the UID.

### 9.15 P2PName routing does not go local

**Symptom:** this process has a group member, yet `CallByP2PName` still goes over the network.

**Cause:** P2PName routing is by design not local-first.

**Fix:** for local-first behaviour use `Call` (App name) or `CallByUid`.

### 9.16 A dispatcher that breaks the synchronous contract → use-after-free

**Symptom:** sporadic crashes, with the UI thread touching a released handle.

**Cause:** a custom dispatcher that is post-and-forget.

**Fix:** `Dispatch` must not return until the callback has finished executing.

### 9.17 A UI handler plus a synchronous Call deadlocks

**Symptom:** the process deadlocks.

**Cause:** the UI thread is blocked in `Framework.Call` while a worker tries to dispatch back to the UI thread.

**Fix:** use `CallAsync` + `await` rather than `Call`. Or do not make synchronous calls from inside a UI handler.

### 9.18 `await` does not return to the SyncContext

**Symptom:** with a SyncContext set inside `Task.Run`, after awaiting the continuation is not on the ctx thread.

**Cause:**
- a local App-name call **completes synchronously** → the Task is already done → await does not suspend → no Post.
- a thread-pool thread with no SyncContext → the continuation runs inline on the completing thread.

**Fix:**
- await on the real UI thread (do not wrap it in `Task.Run`).
- or post the whole async lambda to the ctx.

### 9.19 An AsyncResult escaping the callback body

**Symptom:** accessing `AsyncResult.Handle` / `Read*` after the callback returns occasionally reads garbage or crashes.

**Cause:** `AsyncResult` internally holds a **borrowed** `DataHandle` (`owned: false`). The framework releases the underlying handle the instant the callback returns.

**Fix:** **immediately copy** the data you need inside the callback body (`ReadJson<T>` / `ReadString` / `ReadAllBytes`), and hand the **copied managed object** out into the world. Never store an `AsyncResult` or `r.Handle` in a field, enqueue it, or pass it to another thread.

### 9.20 Treating callback-style async as a synchronous function

**Symptom:** assuming the result is ready once `Async.Call(...)` returns.

**Cause:** `Async.Call` returns `void`. On a successful dispatch the callback fires on **a worker thread later**, long after `Async.Call` has returned.

**Fix:** synchronize between the caller and the callback with `ManualResetEventSlim` / `CountdownEvent` / `TaskCompletionSource`. Or switch to the await style `Framework.CallAsync`.

### 9.21 The complete FAQ

**Q: Is C# support complete?**
A: Yes. The P/Invoke layer (59 exports), RAII wrappers, unified JSON I/O, UID / P2PName addressing, Task-based async, callback-style async, pluggable callback thread dispatch, network events, the exception hierarchy, about 118 tests and cross-language ABI interop are all covered.

**Q: What should I run first?**
A: Run the `test` and `test2` projects first, to confirm the dynamic library and the environment are fine.

**Q: How do I verify cross-language operation?**
A: Start a C++ or Pascal `CrossNode` and call it with the C# `CrossCall`; or the other way round. The wire protocol is byte-identical.

**Q: How do I load-test?**
A: Run `CrossCall` — 32 threads × 10 seconds, printing the throughput.

**Q: The dynamic library cannot be found?**
A: Put `LingoFuse64.dll` / `liblingofuse.so` in the same directory as the executable, or on the system PATH.

**Q: `PrepareDone` returns 0 the second time?**
A: It succeeds only once per process. To restart, do `Shutdown` + `ResetPrepare` first.

**Q: Will `LingoFuseLibraryLoadException` be thrown?**
A: The current implementation does not throw it; on a load failure `NativeLibrary.Load` throws `DllNotFoundException`. Catch both.

**Q: Does `AppHandle` support registering APIs across threads?**
A: Yes. An internal lock serializes it.

**Q: Can Pascal / Python / C++ peers call a C# service?**
A: Yes. All languages use the same wire protocol; the App name and API name just have to match.

**Q: JSON key casing?**
A: C# property names verbatim. To switch to snake_case, annotate with `[JsonPropertyName]`.

**Q: Are emoji escaped?**
A: No. `UnescapeSurrogatePairs` inside `LfIo` guarantees emoji are emitted as literal UTF-8.

**Q: How do I get the sender's identity?**
A: In a callback use `input.GetSenderUid()` and `input.GetSenderP2PName()`. **Valid only on `input`**.

**Q: How do I get a handler onto the UI thread?**
A: `CallbackDispatcher.CaptureMainThread()` (once, when the UI starts), then pass `CallbackDispatcher.MainThread` at registration time.

**Q: Why does an async call sometimes complete synchronously?**
A: When the target App is local (this process), the C ABI fires the completion callback **synchronously before `CallAsync` returns**, so the Task is already complete. Then `await` does not suspend and the continuation runs inline on the current thread. See `LingoFuse_CSharp_Complete_Guide.md` §12.4 for details.

**Q: How do I add a timeout to an async call?**
A: `Task.WhenAny(pending, Task.Delay(...))`. The C ABI layer has no timeout / cancellation.

**Q: Does the UID change?**
A: It is regenerated on every reconnect. Caching a UID across a link loss makes `CallByUid` fail.

**Q: Is P2PName routing local first?**
A: No. P2PName routing always goes to the server, and the server load-balances.

**Q: Which should I choose, callback-style or await-style async?**
A: UI apps / needing `SynchronizationContext` / needing `Task.WhenAll` → await style. Server-side callback logic / embedded / consistency with C++/Pascal / not wanting `async` to infect the call stack → callback style. The two can be mixed.

---

## 10. Cross-language interoperability

### 10.1 The wire-protocol contract

| Element | Encoding |
|------|------|
| string frame | UTF-8 bytes + NUL (`0x00`) |
| integers | little-endian |
| floating point | IEEE 754, little-endian |
| JSON text | compact, literal UTF-8, no `\uXXXX` escapes |
| UID | 32 bytes, little-endian 4 × 64-bit |
| raw bytes | arbitrary bytes + NUL (when using `WriteStringBytes`) |

### 10.2 The interop matrix

| Server | Client | Transport | Addressing / envelope | Supported |
|--------|--------|------|-------------|:----:|
| C# | C# | IPC / TCP | JSON / ABI / UID / P2PName | ✅ |
| C# | Pascal | IPC | JSON / ABI / UID / P2PName | ✅ |
| C# | Python | IPC | JSON / ABI / UID / P2PName | ✅ |
| C# | C++ | IPC | JSON / ABI / UID / P2PName | ✅ |
| C# | Rust / Go / Node / Java | IPC | JSON / ABI / UID / P2PName | ✅ |
| C# | HTTP | HTTP→bridge→LF | JSON | ✅ |

**All combinations use the same wire protocol.** The only differences are whether the application layer picks a JSON envelope or raw scalars, and which addressing (App name / UID / P2PName) it uses.

### 10.3 The side-data matrix

| Command | Is the sender identity injected? |
|------|:------------------:|
| `Framework.Notify` / `SequencedNotify` | ✅ |
| `Framework.Call` / `CallAsync` | ✅ |
| `Framework.CallByUid` / `CallByUidAsync` | ✅ |
| `Framework.CallByP2PName` / `CallByP2PNameAsync` | ✅ |
| `AppHandle.LocalCall` / `LocalNotify` | ✅ |
| the `Result_` handle of an async callback | ❌ (an output handle) |
| a handle the caller created itself | ❌ (no sender) |

### 10.4 A cross-language example

**The C# server:**

```csharp
app.RegisterCall("add", "Add two ints", (input, output) =>
{
    int a = input.ReadInt32();
    int b = input.ReadInt32();
    output.WriteInt32(a + b);
});
```

**The C++ client:**

```cpp
DataHandle param("add");
param.write<int32_t>(a);
param.write<int32_t>(b);
auto response = lingofuse::call("demo", param, 1000);
int32_t sum = response.read<int32_t>();
```

**The Pascal client:**

```pascal
send_ := LF_CreateDataEx('add');
LF_WriteInt32(send_, a);
LF_WriteInt32(send_, b);
return_ := LF_CallEx('demo', send_, 1000);
Result := LF_ReadInt32(return_);
```

**The Python client:**

```python
c = C4("demo", "ipc:cross")
result = c.add(a, b)
```

**The wire bytes are exactly identical.**

---

## 11. Comparison with the other language bindings

| Feature | C# | Pascal | Python | C++ |
|------|:--:|:------:|:------:|:---:|
| underlying binding | `NativeMethods.cs` | `lingofuse_import.pas` | `_lf_native.py` | `LingoFuse.h` |
| RAII wrappers | `DataHandle` / `AppHandle` | `TDataHandle` / `TAppHandle` | `DataHandle` / `App` | `DataHandle` / `AppHandle` |
| UID value type | `P2PUid` | `TP2P_UID___` | `bytes` | `TP2P_UID` |
| unified JSON I/O | `LfIo` | `lf_io` (via the Bridge) | `lf_io` | `lf_io.hpp` |
| strongly typed options | `RuntimeOptions` | — | — | — |
| callback thread dispatch | `CallbackDispatcher` | `LF_RegisterSyncCall_M` | — | — |
| async calls | `Task<DataHandle>` | an anonymous method + `LF_Async_Call` | `call_future` + `asyncio` | `callAsync` + `AsyncResult` |
| callback-style async ★ | `Async.Call(..., r => {...})` | `LF.AsyncCallApp_P` | — | `lingofuse::callAsync` |
| HTTP Bridge client | — | ✅ | ✅ | ✅ |
| network events | `NetworkEvents` | `LF_Set_Network_Event` | `network_events` | `NetworkEvents` |
| status checks | `LingoFuseStatus` | direct calls | `lingofuse.check_*` | `LingoFuseStatus` |
| permanent handles | `CreatePermanent` | `LF_CreateData_Permanent` | `create_permanent` | ✅ |
| test framework | **home-grown TestCase/TestRunner** | a combined suite | a combined suite | functional + stress + concurrency |
| test count | about 118 (about 60 + about 58) | a combined suite | a combined suite | functional + stress + concurrency |
| CI | ❌ local only | ❌ local only | ❌ local only | ❌ local only (no GitHub Actions at the root) |

---

## 12. Licence

MIT. Use it as you like, change it as you like, sell it if you want.

---

## Further reading

| Document | Content |
|------|------|
| `LingoFuse_CSharp_Complete_Guide.md` | the complete C# interface reference (v5.1, 17 chapters + 4 appendices) |
| `../LingoFuse_Pascal_Complete_Guide.md` | the Pascal interface and internal mechanisms |
| `../Z.LingoFuse.md` | the LingoFuse internal-mechanism knowledge base |
| `../cpp/LingoFuse_Cpp_Knowledge_Base.md` | the C++ interface reference (v8.0) |

---

*This document is maintained alongside the LingoFuse C# binding v5.1 and covers about 118 tests (about 60 regression + about 58 v5.0/v5.1 API, home-grown TestCase/TestRunner). For exact figures take the actual `dotnet run` output as authoritative.*
*For the complete API reference see `LingoFuse_CSharp_Complete_Guide.md`.*
*Last updated: 2026-11-14*

