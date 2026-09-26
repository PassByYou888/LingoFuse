# LingoFuse C# Binding — Complete Guide

> **Purpose.** This is the single self-contained reference for the
> `LingoFuse` .NET binding. An AI or human engineer who reads this file
> alone must be able to write correct, production-grade LingoFuse C#
> programs without consulting the source.
>
> **Coverage.** This document describes every public type, method,
> contract, wire format, exception, and lifecycle rule exposed by the
> binding. It is written for C# and assumes prior knowledge of .NET and
> of the LingoFuse wire protocol at the level described in Chapter 12.
>
> **Version.** Matches the binding after the interface-reform pass
> (nullable-aware, dual JSON / ABI paths, explicit framework lifecycle).

---

## Table of Contents

1. [Overview and Design](#1-overview-and-design)
2. [Installation and Namespaces](#2-installation-and-namespaces)
3. [The Load / Unload Contract](#3-the-load--unload-contract)
4. [The Framework Lifecycle](#4-the-framework-lifecycle)
5. [DataHandle](#5-datahandle)
6. [AppHandle](#6-apphandle)
7. [LingoFuseApp](#7-lingofuseapp)
8. [Host Classes — Client, Server, Node](#8-host-classes--client-server-node)
9. [Sync Callbacks](#9-sync-callbacks)
10. [Network Events](#10-network-events)
11. [Status and Diagnostics](#11-status-and-diagnostics)
12. [Cross-Language Wire Contracts](#12-cross-language-wire-contracts)
13. [JSON Policy](#13-json-policy)
14. [Exception Hierarchy](#14-exception-hierarchy)
15. [Complete Examples](#15-complete-examples)
16. [Anti-Patterns and Pitfalls](#16-anti-patterns-and-pitfalls)
17. [Quick Reference](#17-quick-reference)

---

## 1. Overview and Design

### 1.1 What LingoFuse is

LingoFuse is a cross-language, cross-process, cross-machine RPC
framework. A **service** endpoint (the C4 mesh beacon) registers
applications; **clients** connect to that endpoint and expose their own
applications or call remote ones.

The wire protocol is **language-neutral**:

- every string is **UTF-8, NUL-terminated**;
- every integer and float is **little-endian**;
- two payload channels are supported: **JSON** and **raw ABI**.

The .NET binding exposes both channels as first-class, so a C# peer can
interoperate with C++, Pascal, and Python peers regardless of which
channel those peers use.

### 1.2 The three host types

The binding exposes three host classes. They differ only in what they
own; their outbound API is **identical**.

| Host              | Owns a service? | Owns an App? | Purpose                                     |
|-------------------|:---------------:|:------------:|---------------------------------------------|
| `LingoFuseServer` | ✅               | ✅            | Coordinator: listens and exposes APIs.      |
| `LingoFuseNode`   | ❌               | ✅            | Worker: attaches to an existing coordinator.|
| `LingoFuseClient` | ❌               | ❌            | Pure consumer: calls remote APIs only.      |

Use `LingoFuseClient` when the process only needs to make calls. Use
`LingoFuseNode` when a coordinator already exists and this process only
registers APIs. Use `LingoFuseServer` when this process is the
coordinator itself.

### 1.3 The two payload channels

Both channels use the same `DataHandle` primitive. They differ in what
bytes are placed on the wire and who interprets them.

| Channel | Writer API                                            | Reader API                                            |
|---------|-------------------------------------------------------|-------------------------------------------------------|
| JSON    | `LfIo.WriteJson` / `DataHandle.WriteJson`             | `LfIo.ReadJson<T>` / `DataHandle.ReadJson`            |
| ABI     | `DataHandle.WriteInt32`, `WriteString`, `WriteBytes`, … | `DataHandle.ReadInt32`, `ReadString`, `ReadBytes`, … |

**Choose one channel per (app, api) pair and use it consistently across
every language on the mesh.** JSON is convenient for structured data;
ABI is the right choice for byte-precise interop with C++ / Pascal /
Python peers.

### 1.4 Layer map

```
  Your application
        │
        ▼
  LingoFuse.Host          LingoFuseServer / LingoFuseClient / LingoFuseNode
  LingoFuse.Core          DataHandle / AppHandle / LingoFuseApp / LingoFuseSync
  LingoFuse.Io            LfIo / JsonPolicy
  LingoFuse.Diagnostics   LingoFuseStatus
  LingoFuse.Events        NetworkEvents
  LingoFuse.Host (runtime)LingoFuseFramework
  LingoFuse.Native        NativeMethods (P/Invoke, internal)
        │
        ▼
  LingoFuse64.dll / liblingofuse.so / liblingofuse.dylib
```

---

## 2. Installation and Namespaces

### 2.1 Required files

The binding is a single class library. Its public types live in these
namespaces:

| Namespace              | Contains                                              |
|------------------------|-------------------------------------------------------|
| `LingoFuse`            | Exceptions (base and derived).                        |
| `LingoFuse.Core`       | `DataHandle`, `AppHandle`, `LingoFuseSync`.           |
| `LingoFuse.Host`       | `LingoFuseServer`, `LingoFuseClient`, `LingoFuseNode`, `LingoFuseApp`, `LingoFuseFramework`. |
| `LingoFuse.Io`         | `LfIo`, `JsonPolicy`.                                 |
| `LingoFuse.Diagnostics`| `LingoFuseStatus`.                                    |
| `LingoFuse.Events`     | `NetworkEvents`.                                      |
| `LingoFuse.Native`     | `DataHnd`, `AppHnd`, delegate types (public but only used by the binding itself). |

A typical application starts with:

```csharp
using LingoFuse;
using LingoFuse.Core;
using LingoFuse.Diagnostics;
using LingoFuse.Events;
using LingoFuse.Host;
using LingoFuse.Io;
```

### 2.2 Target frameworks

The binding targets `net8.0` / `net9.0` and requires `x64`. Do **not**
target `Any CPU`: the native library is a 64-bit binary on 64-bit
platforms.

### 2.3 The nullable context

The binding is compiled with `<Nullable>enable</Nullable>`. Public
methods use `T?` annotations where the return can be null. Note that
**`T?` on an unconstrained generic parameter is not `Nullable<T>`** — see
§7.6 for the consequences.

---

## 3. The Load / Unload Contract

### 3.1 Lazy loading

The native library is loaded **lazily**, on the first P/Invoke into any
`LF_*` function. There is **no** `LF_LoadLibrary` step at the .NET level
(unlike the C wrapper shipped with the Pascal distribution). The static
constructor of the internal `NativeMethods` class installs a
`DllImportResolver` that maps the logical name `"LingoFuse"` to the
platform file:

| Platform      | File                    |
|---------------|-------------------------|
| Windows x64   | `LingoFuse64.dll`       |
| Windows x86   | `LingoFuse32.dll`       |
| Linux / BSD   | `liblingofuse.so`       |
| macOS         | `liblingofuse.dylib`    |

The resolver is registered the first time any `NativeMethods` member is
touched, which happens on the first host operation.

### 3.2 Load failure

If the resolver cannot find the file, the first `LF_*` call throws a
`DllNotFoundException` (or `BadImageFormatException` on an architecture
mismatch). Wrap the first host operation in a try/catch:

```csharp
try
{
    using var client = new LingoFuseClient("ipc:svc");
    client.Connect();
}
catch (DllNotFoundException ex)
{
    Console.Error.WriteLine(
        "Cannot load LingoFuse native library: " + ex.Message);
    return 1;
}
```

### 3.3 Where to place the file

Put the native library **next to the executable** (in the same folder as
`YourApp.dll` / `YourApp.exe`), or somewhere on the OS loader path:

- Windows: `PATH`
- Linux: `LD_LIBRARY_PATH`
- macOS: `DYLD_LIBRARY_PATH`

There is no environment variable override at the .NET level.

### 3.4 Unload

There is **no explicit unload** at the .NET level. The native library is
released by the OS when the process exits. Use
`LingoFuseFramework.Shutdown()` (§4.2) to stop the framework's threads
and release its resources **before** process exit; the file handle is
released afterwards by the OS.

---

## 4. The Framework Lifecycle

The native framework is **process-wide**. It is either running (the
simulated main thread is alive) or stopped. Every host class in the
binding cooperates through a single internal state machine.

### 4.1 `LingoFuseFramework` — the public lifecycle entry point

```csharp
public static class LingoFuseFramework
{
    public static bool IsStarted { get; }

    public static void Shutdown();
    public static void ExitMainThread();
    public static void ResetPrepare();
}
```

| Member              | Effect                                                                                                 |
|---------------------|--------------------------------------------------------------------------------------------------------|
| `IsStarted`         | True when `LF_PrepareDone` has been called and the simulated main thread is alive.                     |
| `Shutdown()`        | Full teardown: clears network events, `LF_ExitMainThread`, `LF_Shutdown`, resets the internal cache.    |
| `ExitMainThread()`  | Stops the simulated main thread but keeps the native library loaded.                                    |
| `ResetPrepare()`    | Equivalent to `LF_ResetPrepare`: discards any pending service/client preparations.                      |

### 4.2 When to call `Shutdown()`

**Before process exit**, so that the simulated main thread and every
background worker thread are stopped deterministically. If you do not
call it:

- the OS will still reclaim the process's threads and memory when the
  process exits;
- but if the process hosts LingoFuse as a plugin inside a larger host
  application, the host cannot unload the plugin cleanly, because the
  framework's threads are still alive.

### 4.3 `Shutdown()` is idempotent

Call it as many times as you want; the second call is a no-op. All
failures are swallowed: a shutdown path that itself throws is worse than
a silent no-op.

### 4.4 The recommended exit pattern

Every application that uses LingoFuse should end with:

```csharp
LingoFuseFramework.Shutdown();
```

The three host classes provide a `FullCleanup()` convenience method
that does exactly this (see §8.6).

---

## 5. DataHandle

`DataHandle` is the **only** primitive the binding exposes for reading
and writing payload bytes. Every API in the binding ultimately reads
from or writes into a `DataHandle`.

### 5.1 Class shape

```csharp
namespace LingoFuse.Core;

public sealed class DataHandle : IDisposable
{
    // Construction
    public DataHandle(string apiName);
    public static DataHandle FromRaw(IntPtr raw, bool owned);

    // Identity and state
    public IntPtr Raw { get; }
    public bool IsValid { get; }
    public bool IsOwning { get; }

    // Position and size
    public long Position { get; set; }
    public long Size { get; set; }
    public IntPtr GetBufferPointer();

    // Byte I/O (partial-read family)
    public long WriteBytes(byte[] data);
    public byte[] ReadBytes(int count);
    public byte[] ReadAllBytes();

    // Byte I/O (exact-read family)
    public byte[] ReadBytesExact(int count);
    public bool   TryReadBytes(int count, out byte[]? value);

    // Atomic write family (little-endian)
    public void WriteInt8(sbyte value);
    public void WriteUInt8(byte value);
    public void WriteInt16(short value);
    public void WriteUInt16(ushort value);
    public void WriteInt32(int value);
    public void WriteUInt32(uint value);
    public void WriteInt64(long value);
    public void WriteUInt64(ulong value);
    public void WriteSingle(float value);
    public void WriteDouble(double value);

    // Atomic read family (exact semantics, throws on short read)
    public sbyte   ReadInt8();
    public byte    ReadUInt8();
    public short   ReadInt16();
    public ushort  ReadUInt16();
    public int     ReadInt32();
    public uint    ReadUInt32();
    public long    ReadInt64();
    public ulong   ReadUInt64();
    public float   ReadSingle();
    public double  ReadDouble();

    // Atomic read family (non-throwing)
    public bool TryReadInt8(out sbyte value);
    public bool TryReadUInt8(out byte value);
    public bool TryReadInt16(out short value);
    public bool TryReadUInt16(out ushort value);
    public bool TryReadInt32(out int value);
    public bool TryReadUInt32(out uint value);
    public bool TryReadInt64(out long value);
    public bool TryReadUInt64(out ulong value);
    public bool TryReadSingle(out float value);
    public bool TryReadDouble(out double value);

    // NUL-framed string I/O
    public void   WriteString(string value);
    public string ReadString();
    public bool   TryReadString(out string? value);

    // Lifetime
    public void Dispose();
}
```

### 5.2 Construction

#### 5.2.1 Owning handle

```csharp
var dh = new DataHandle("add");
```

Creates a native data handle bound to the API name `"add"`. The handle
**owns** the underlying native resource; `Dispose()` will call
`LF_FreeData`. The buffer starts empty.

Throws `ArgumentNullException` if `apiName` is null.
Throws `LingoFuseException` if the native allocation fails (rare).

#### 5.2.2 Borrowing handle

```csharp
var borrowed = DataHandle.FromRaw(rawPtr, owned: false);
```

Wraps an existing native pointer **without** taking ownership.
`Dispose()` is a **no-op**; the native layer retains the resource. This
is the form used internally when the binding passes `input` and
`output` handles into a callback.

**Critical**: an owning handle that is disposed releases the native
resource. A borrowing handle that is disposed does nothing — the caller
must let the native layer release the resource at the end of the
callback.

### 5.3 Position and size

| Member                       | Behaviour                                                                                             |
|------------------------------|-------------------------------------------------------------------------------------------------------|
| `Position` (get/set)         | Current read/write cursor in bytes. Setting past `Size` **grows** the buffer; the new bytes are zero or uninitialised (implementation-defined). |
| `Size` (get/set)             | Total buffer size. Setting smaller truncates; setting larger grows.                                    |
| `GetBufferPointer()`         | Returns the native pointer. **Invalidated** by any resize, including a write.                          |

Setting a negative value throws `ArgumentOutOfRangeException`.

### 5.4 Byte I/O

#### 5.4.1 Partial reads

```csharp
long WriteBytes(byte[] data);   // appends at cursor, returns bytes written
byte[] ReadBytes(int count);    // reads up to `count`, returns actual bytes
byte[] ReadAllBytes();          // reads from cursor to end, advances to end
```

`ReadBytes` returns **fewer** bytes than requested when the buffer ends
early. The returned array can be empty. **Never throws for a short
read.**

`WriteBytes` accepts an empty array (no-op, returns 0). Throws
`ArgumentNullException` for a null array.

#### 5.4.2 Exact reads

```csharp
byte[] ReadBytesExact(int count);
bool   TryReadBytes(int count, out byte[]? value);
```

`ReadBytesExact` requires exactly `count` bytes. On a short read:

- the cursor is **left unchanged** (rolled back to its pre-call value);
- a `LingoFuseIoException` is thrown with `Operation == "ReadBytesExact"`.

`TryReadBytes` performs the same check but returns `false` on a short
read (cursor unchanged). The `out` value is `null` on failure.

### 5.5 Atomic I/O — write family

All writers append at the cursor and advance it by the size of the
type. All integers and floats use **little-endian** encoding.

| Method           | Size | Notes                            |
|------------------|:----:|----------------------------------|
| `WriteInt8`      | 1    | signed                           |
| `WriteUInt8`     | 1    | unsigned                         |
| `WriteInt16`     | 2    | little-endian                    |
| `WriteUInt16`    | 2    | little-endian                    |
| `WriteInt32`     | 4    | little-endian                    |
| `WriteUInt32`    | 4    | little-endian                    |
| `WriteInt64`     | 8    | little-endian                    |
| `WriteUInt64`    | 8    | little-endian                    |
| `WriteSingle`    | 4    | IEEE 754 single-precision, LE    |
| `WriteDouble`    | 8    | IEEE 754 double-precision, LE    |

### 5.6 Atomic I/O — exact-read family

The exact-read family requires exactly the type's size in bytes. On a
short read, the cursor is rolled back and `LingoFuseIoException` is
thrown.

| Method           | Requires | Notes                              |
|------------------|:--------:|------------------------------------|
| `ReadInt8`       | 1 byte   | signed                             |
| `ReadUInt8`      | 1 byte   | unsigned                           |
| `ReadInt16`      | 2 bytes  | little-endian                      |
| `ReadUInt16`     | 2 bytes  | little-endian                      |
| `ReadInt32`      | 4 bytes  | little-endian                      |
| `ReadUInt32`     | 4 bytes  | little-endian                      |
| `ReadInt64`      | 8 bytes  | little-endian                      |
| `ReadUInt64`     | 8 bytes  | little-endian                      |
| `ReadSingle`     | 4 bytes  | IEEE 754 single-precision, LE      |
| `ReadDouble`     | 8 bytes  | IEEE 754 double-precision, LE      |

### 5.7 Atomic I/O — Try-read family

Each `TryReadXxx(out T value)` mirrors its throwing counterpart but
returns `false` instead of throwing. **The cursor is left unchanged on
failure.** On success, the value is returned via the `out` parameter.

### 5.8 NUL-framed string I/O

#### 5.8.1 `WriteString(string value)`

Writes `value` as UTF-8 bytes, followed by **one NUL byte (`0x00`)**.

- Empty string → exactly one byte: `0x00`.
- Invalid .NET strings (unpaired surrogates) are replaced with U+FFFD
  by the encoder's default fallback; the writer does not throw.
- Throws `ArgumentNullException` for a null argument.

#### 5.8.2 `ReadString()`

Reads a UTF-8 string from the current cursor, stopping at the first NUL
byte. The cursor advances to just **past** the NUL.

**Fault-tolerant behaviour** (critical for cross-language interop):

- If a NUL **is** found at offset `end`, the cursor is set to `end + 1`.
- If **no** NUL is found before the end of the buffer, **all remaining
  bytes are consumed**, and the cursor is set to `size + 1` — one byte
  past the end. The underlying library implicitly grows the buffer by
  one byte to accommodate this position.

This matches the C++ `read_string` and the Pascal `LF_ReadString`
helpers exactly. It is what makes the reader tolerant of payloads that
arrive from an HTTP bridge or any other non-NUL-terminating producer.

**Invalid UTF-8**: byte sequences that are not valid UTF-8 are decoded
with the encoder's default fallback (each invalid byte becomes U+FFFD).
This **matches Pascal's behaviour but differs from Python (which
raises) and C++ (which returns raw bytes)**. See §12.6.

**Cursor at or past end**: returns an empty string; cursor unchanged.

#### 5.8.3 `TryReadString(out string? value)`

Returns `false` if the cursor is at or past the end of the buffer (with
`value = null`). Otherwise reads the string and returns `true`.
Never throws for a malformed payload.

### 5.9 Disposal

```csharp
using var dh = new DataHandle("add");
// ... use dh ...
// Dispose at scope exit.
```

`Dispose()` is idempotent. The **only** case in which it does something
is when `IsOwning == true`. For a borrowed handle, `Dispose()` is a
no-op; the wrapper state remains valid so that an accidental call inside
a callback cannot corrupt the wrapper.

### 5.10 Thread safety

The native library is thread-safe, but a single `DataHandle` **cannot
be written from multiple threads concurrently**. Reading is safe while
another thread reads. If multiple threads must share a handle for
writes, the caller must serialise them with their own lock.

### 5.11 Lifetime cap

The native library reclaims a data handle that has not been touched for
**5 minutes**. Do not rely on this; always dispose handles explicitly.

---

## 6. AppHandle

`AppHandle` is a thin RAII wrapper around the native application handle
(an `AppHnd`). Most applications do not use it directly — they use
`LingoFuseApp` (§7) or the host classes (§8), both of which build on
`AppHandle`.

### 6.1 Class shape

```csharp
namespace LingoFuse.Core;

public sealed class AppHandle : IDisposable
{
    public AppHandle(string name, string description = "");

    public string  Name    { get; }
    public IntPtr  Raw     { get; }
    public bool    IsValid { get; }

    // Registration — asynchronous (native worker thread)
    public bool RegisterCall(string apiName, string description,
                             Action<DataHandle, DataHandle> handler);
    public bool RegisterNotify(string apiName, string description,
                               Action<DataHandle> handler);

    // Registration — synchronous (main thread)
    public bool RegisterCallSync(string apiName, string description,
                                 Action<DataHandle, DataHandle> handler);
    public bool RegisterNotifySync(string apiName, string description,
                                   Action<DataHandle> handler);

    // Unregister
    public bool Unregister(string apiName);

    // Local execution
    public DataHandle LocalCall(DataHandle param);
    public void       LocalNotify(DataHandle param);

    // Client binding
    public int Bind();

    public void Dispose();
}
```

### 6.2 Registration

#### 6.2.1 `RegisterCall(apiName, description, handler)`

Registers a request-response API. The `handler` is invoked on a
**native worker thread** with two borrowed `DataHandle` instances:

```csharp
handle.RegisterCall("add", "Add two ints", (input, output) =>
{
    int a = input.ReadInt32();
    int b = input.ReadInt32();
    output.WriteInt32(a + b);
});
```

Returns `true` on success, `false` if the API name is already taken.

**Handler rules:**

1. Do **not** dispose `input` or `output`. `DataHandle.Dispose()` is a
   no-op on borrowed handles, but the correct behaviour is to leave
   them alone.
2. Do **not** call any blocking LingoFuse function (`CallBinary`,
   `Call`, `Notify`, `LocalCall`, `PrepareDone`, `Shutdown`) from
   inside the handler. This will deadlock.
3. Do **not** let an exception escape. The wrapper catches it and logs
   via `Debug.WriteLine`; the caller sees an empty response.
4. Do **not** touch UI controls directly. Marshal to the UI thread via
   `LingoFuseSync` (see §9) or your framework's dispatcher.

#### 6.2.2 `RegisterNotify(apiName, description, handler)`

Registers a one-way API. The handler receives a single borrowed
`DataHandle` (the input). It does not produce output.

#### 6.2.3 Sync variants

`RegisterCallSync` / `RegisterNotifySync` marshal the handler to the
**main thread**. The application must drive the queue by calling
`LingoFuseSync.ProcessSyncQueue()` periodically (§9).

### 6.3 `LocalCall` and `LocalNotify`

```csharp
using var param = new DataHandle("add");
param.WriteInt32(5);
param.WriteInt32(7);

using var result = handle.LocalCall(param);
int sum = result.ReadInt32();   // 12
```

`LocalCall` bypasses the network entirely and invokes the registered
handler synchronously in the calling thread. The input handle is not
consumed. The returned `DataHandle` owns the response and must be
disposed.

When the target API is not registered, the returned handle has
`Size == 0`. Callers must check `Size` before reading.

`LocalNotify` sends a one-way notification locally.

### 6.4 `Bind()`

Binds the application to all currently unbound clients in the current
process. Returns the number of clients bound. Zero means:

- the simulated main thread is not active, or
- every client already has an application attached.

---

## 7. LingoFuseApp

`LingoFuseApp` is a convenience wrapper around `AppHandle` that
provides typed JSON and ABI registration and local execution.

### 7.1 Class shape

```csharp
namespace LingoFuse.Host;

public sealed class LingoFuseApp : IDisposable
{
    public LingoFuseApp(string? name = null, string description = "");

    public AppHandle  Handle        { get; }
    public IntPtr     Raw           { get; }
    public string     Name          { get; }
    public bool       IsValid       { get; }
    public IReadOnlyCollection<string> ExposedApis { get; }

    // ABI registration
    public bool Expose(string apiName, string description,
                       Action<DataHandle, DataHandle> handler,
                       bool synchronous = false);
    public bool ExposeNotify(string apiName, string description,
                             Action<DataHandle> handler,
                             bool synchronous = false);

    // JSON registration
    public bool Expose<TResult>(string apiName,
                                Func<TResult> handler,
                                string description = "",
                                bool synchronous = false);
    public bool Expose<TArg, TResult>(string apiName,
                                      Func<TArg, TResult> handler,
                                      string description = "",
                                      bool synchronous = false);
    public bool Expose<T1, T2, TResult>(string apiName,
                                        Func<T1, T2, TResult> handler,
                                        string description = "",
                                        bool synchronous = false);
    public bool ExposeNotify<TArg>(string apiName,
                                   Action<TArg> handler,
                                   string description = "",
                                   bool synchronous = false);

    // Unregister
    public bool Unregister(string apiName);

    // Local execution — JSON
    public T? LocalCall<T>(string apiName, object? payload = null);
    public bool TryLocalCall<T>(string apiName, object? payload,
                                out T? result);
    public bool TryLocalCall<T>(string apiName, out T? result);
    public void LocalNotify(string apiName, object? payload = null);

    // Local execution — ABI
    public DataHandle LocalCallBinary(DataHandle request);
    public void       LocalNotifyBinary(DataHandle request);

    // Client binding
    public int Bind();

    public void Dispose();
}
```

### 7.2 Construction

```csharp
var app = new LingoFuseApp("MyApp", "My description");
```

Pass a name explicitly **or** leave it null / empty to auto-generate a
globally unique name via `LF_Generate_AppName`. Auto-generation requires
the simulated main thread to be running; it is only safe after
`LingoFuseFramework.IsStarted` returns `true`.

### 7.3 ABI registration

```csharp
app.Expose("add", "Add two int32s", (input, output) =>
{
    int a = input.ReadInt32();
    int b = input.ReadInt32();
    output.WriteInt32(a + b);
});
```

The handler receives **borrowed** `DataHandle` instances. See §6.2.1 for
the handler rules (they are identical).

### 7.4 JSON registration

```csharp
// Zero arguments
app.Expose<int>("answer", () => 42);

// One argument
app.Expose<string, string>("echo", s => s);

// Two arguments
app.Expose<int, int, int>("add", (a, b) => a + b);

// Notify (typed, one argument)
app.ExposeNotify<int>("bump", n => Console.WriteLine(n));
```

**JSON envelope convention** (typed overloads only):

| Handler arity | Expected request payload              | Response payload          |
|---------------|---------------------------------------|---------------------------|
| 0 arguments   | JSON `null` or no payload             | JSON serialisation of `TResult` |
| 1 argument    | a bare JSON value, or `[value]`       | JSON serialisation of `TResult` |
| 2 arguments   | a JSON array `[v1, v2]`               | JSON serialisation of `TResult` |

A JSON `null` request payload is passed to the handler as
`default(TArg)`. This makes it possible for a Python / C++ / Pascal peer
to transmit a null reference argument that the C# handler receives as
`null` (for reference types) or as `default(TArg)` (for value types).

If the handler throws, the wrapper writes a JSON error envelope:

```json
{ "__error__": "...message...", "__type__": "...full.type.name..." }
```

The caller sees this as the response body. It matches the convention
used by the Python binding.

### 7.5 Local execution — JSON

```csharp
// Registered typed handler
app.Expose<int, int, int>("add", (a, b) => a + b);

// Typed local call
int sum = app.LocalCall<int>("add", new object[] { 5, 7 });   // 12

// Non-throwing variant
if (app.TryLocalCall<int>("add", new object[] { 5, 7 }, out int sum2))
{
    Console.WriteLine(sum2);   // 12
}
```

**Return value on unregistered API**: `LocalCall<T>` returns
`default(T)`. For a value type `T` this is a value (e.g. `0`); for a
reference type it is `null`.

**`TryLocalCall<T>`** is the idiomatic way to distinguish "empty
response" (unregistered API) from a legitimate `default(T)` return
value:

```csharp
if (app.TryLocalCall<int>("add", payload, out int result))
{
    // API exists, result is the handler's return value.
}
else
{
    // API is not registered on this App.
}
```

### 7.6 The `T?` gotcha on unconstrained generics

**Critical**: `T?` on an unconstrained generic parameter does not mean
`Nullable<T>`. The compiler only produces `Nullable<T>` when `T` is
constrained with `where T : struct`.

The consequence:

```csharp
app.Expose<int, int, int>("add", (a, b) => a + b);

int  v = app.LocalCall<int>("add", ...);       // v is int, not int?
string s = app.LocalCall<string>("echo", ...); // s is string?, not string
```

For **value types**, the return type is `T`; for **reference types**, the
return type is `T?`.

**Do not write**:

```csharp
var v = app.LocalCall<int>("add", ...);
if (v.HasValue) { ... }   // compile error: int has no HasValue
```

**Do write**:

```csharp
int v = app.LocalCall<int>("add", ...);
if (v != 0) { ... }        // or use TryLocalCall<T>

// Or, to distinguish "not registered" from "returned 0":
if (app.TryLocalCall<int>("add", payload, out int v2)) { ... }
```

### 7.7 Local execution — ABI

```csharp
using var req = new DataHandle("add");
req.WriteInt32(5);
req.WriteInt32(7);

using var resp = app.LocalCallBinary(req);
int sum = resp.ReadInt32();   // 12
```

No JSON is involved. The caller owns both handles and must dispose
them. The response handle has `Size == 0` when the API is not
registered.

### 7.8 Disposal

`Dispose()` releases the underlying `AppHandle`. On the native side,
`LF_FreeApp` is called, which detaches the application from all clients
and stops its sequenced-notification threads. The native application
object itself remains alive in the global pool until
`LingoFuseFramework.Shutdown()` is called.

---

## 8. Host Classes — Client, Server, Node

### 8.1 Side-by-side shape

All three host classes share the same outbound API. They differ only in
what they own and how they are started.

| Member                        | Client | Server | Node |
|-------------------------------|:------:|:------:|:----:|
| `App` property                | ❌     | ✅     | ✅   |
| `Endpoint` property           | ✅     | ✅     | ✅   |
| `PublicEndpoint` property     | ❌     | ✅     | ❌   |
| `DefaultTimeoutMs` property   | ✅     | ✅     | ✅   |
| `IsConnected` property        | ✅     | ❌     | ✅   |
| `IsRunning` property          | ❌     | ✅     | ❌   |
| `IsValid` property            | ✅     | ✅     | ✅   |
| `Connect(overlapConnection)`  | ✅     | ❌     | ✅   |
| `Start(overlapConnection)`    | ❌     | ✅     | ❌   |
| `Stop(fullCleanup)`           | ❌     | ✅     | ❌   |
| `Dispose()`                   | ✅     | ✅     | ✅   |
| `FullCleanup()`               | ✅     | ✅     | ✅   |
| `Call<T>` / `CallRaw`         | ✅     | ✅     | ✅   |
| `TryCall<T>` / `TryCallRaw`   | ✅     | ✅     | ✅   |
| `Notify` / `SequencedNotify`  | ✅     | ✅     | ✅   |
| `CallBinary` / `TryCallBinary`| ✅     | ✅     | ✅   |
| `NotifyBinary` / `SequencedNotifyBinary` | ✅ | ✅ | ✅ |

### 8.2 Construction

```csharp
var client = new LingoFuseClient("ipc:svc", defaultTimeoutMs: 5000);
var server = new LingoFuseServer("MyApp", "ipc:my_app",
                                 description: "demo");
var node   = new LingoFuseNode("MyApp", "ipc:beacon",
                               description: "worker");
```

`appName` and `endpoint` must not be null or empty
(`ArgumentException`). `description` may be null (treated as empty).
`publicEndpoint` (Server only) defaults to `endpoint`.
`defaultTimeoutMs` is applied to outbound calls whose caller does not
specify one.

### 8.3 Starting a host

#### 8.3.1 `Client.Connect(overlapConnection = false)`

Prepares the framework if necessary and connects the client to the
endpoint. Safe to call once per instance.

- If the framework is already running in this process (started by a
  `LingoFuseServer` or another `LingoFuseNode`), the client attaches to
  it without re-preparing.
- Otherwise, the client performs the full preparation sequence:
  `LF_ResetPrepare → LF_PrepareClient → LF_PrepareDone`.

#### 8.3.2 `Node.Connect(overlapConnection = false)`

Same structure as `Client.Connect`, but it registers the node's own App
with the endpoint.

#### 8.3.3 `Server.Start(overlapConnection = false)`

Performs the full sequence in one call:

```
LF_ResetPrepare → LF_PrepareService → LF_PrepareClient → LF_PrepareDone
```

The service endpoint is created, the server's App is attached to an
internal client, and the simulated main thread starts.

#### 8.3.4 The `overlapConnection` flag

Set it to `true` when two or more hosts in the **same process** need to
share the same endpoint. The flag enables the native
`Overlap_Connection` option, which allows multiple client tunnels to the
same address.

Without it, the second `Connect` / `Start` on the same address fails
with `LingoFuseStateException` (`LF_PrepareClient returned -1`).

Cross-process clients are unaffected: each process has its own C4
client pool.

### 8.4 Outbound invocation

Both the JSON path and the ABI path are available on all three hosts.

#### 8.4.1 JSON path (throwing)

```csharp
// Typed call — returns the deserialised response
int sum = client.Call<int>("Calc", "add", new object[] { 5, 7 }, 3000);

// Raw call — returns the JSON text
string json = client.CallRaw("Calc", "add", new object[] { 5, 7 }, 3000);
```

On failure, throws `LingoFuseCallException` (timeout, unreachable
target, empty reply) or `LingoFuseException` (JSON deserialisation
failure).

#### 8.4.2 JSON path (non-throwing)

```csharp
if (client.TryCall<int>("Calc", "add", new object[] { 5, 7 }, 3000,
                        out int sum))
{
    // sum holds the deserialised response
}

if (client.TryCallRaw("Calc", "add", payload, 3000, out string? json))
{
    // json holds the raw response text
}
```

`TryCall` / `TryCallRaw` return `false` on timeout, unreachable target,
empty reply, or (for `TryCall`) JSON deserialisation failure. They
still throw `ArgumentNullException` and `LingoFuseObjectDisposedException`
for caller misuse.

#### 8.4.3 ABI path

```csharp
using var req = new DataHandle("add");
req.WriteInt32(5);
req.WriteInt32(7);

using var resp = client.CallBinary("Calc", req, 3000);
int sum = resp.ReadInt32();
```

Non-throwing variant:

```csharp
if (client.TryCallBinary("Calc", req, 3000, out var resp))
{
    using (resp)
    {
        int sum = resp!.ReadInt32();
    }
}
```

**Ownership**: the caller owns the request handle and is responsible for
disposing it. The caller owns the returned response handle and must
dispose it. On failure (`TryCallBinary` returning `false`), `resp` is
`null`.

#### 8.4.4 Notify and SequencedNotify

```csharp
client.Notify("Logger", "log", "message");
client.SequencedNotify("Logger", "log", "message");
```

- `Notify` — one-way, best-effort. Delivery order is **not** guaranteed.
- `SequencedNotify` — one-way, **FIFO** per `(app, api)` pair.

The ABI variants are:

```csharp
using var req = new DataHandle("log");
req.WriteString("message");
client.NotifyBinary("Logger", req);
client.SequencedNotifyBinary("Logger", req);
```

### 8.5 Stopping a host

| Host     | Stop API                            | Effect                                                              |
|----------|-------------------------------------|---------------------------------------------------------------------|
| Client   | `Dispose()`                         | Detaches the client. Framework stays running.                       |
| Client   | `FullCleanup()`                     | Detaches and shuts down the framework process-wide.                 |
| Server   | `Stop(fullCleanup: false)`          | Stops the network loop. App handle remains valid.                   |
| Server   | `Stop(fullCleanup: true)`           | Stops the network loop and shuts down the framework process-wide.   |
| Server   | `FullCleanup()`                     | Equivalent to `Stop(fullCleanup: true)`.                            |
| Node     | `Dispose()`                         | Detaches the node's App. Framework stays running.                   |
| Node     | `FullCleanup()`                     | Detaches and shuts down the framework process-wide.                 |

### 8.6 Choosing between `Dispose` and `FullCleanup`

**`Dispose()`** is the right choice when the process hosts other
LingoFuse instances that must continue to operate after this host is
gone. It does **not** call `LF_Shutdown`; the simulated main thread
stays alive.

**`FullCleanup()`** is the right choice when this host is the last
LingoFuse instance in the process, or when the process is about to
exit. It performs:

```
LF_ExitMainThread  ->  (App detach)  ->  LF_Shutdown
```

which matches the Pascal `LF-CLEAN-001` cleanup order.

**In every application that owns only a client or only a node**, call
`FullCleanup()` in a `finally` block so that the framework is released
on every exit path, including exceptions:

```csharp
LingoFuseClient? client = null;
try
{
    client = new LingoFuseClient("ipc:svc");
    client.Connect();
    // ... use the client ...
}
finally
{
    client?.FullCleanup();
}
```

Do **not** rely on `using` alone for a lone host: the `using` statement
calls `Dispose()`, which does not stop the framework.

### 8.7 Coexisting hosts in one process

```csharp
var server = new LingoFuseServer("Beacon", "ipc:beacon");
server.Start();

var node = new LingoFuseNode("Worker", "ipc:beacon");
node.Connect(overlapConnection: true);

var client = new LingoFuseClient("ipc:beacon");
client.Connect(overlapConnection: true);

// ... use all three ...

// Detach each host without tearing down the framework.
client.Dispose();
node.Dispose();
server.Stop(fullCleanup: false);

// Release the framework process-wide once every host is done.
LingoFuseFramework.Shutdown();
```

`overlapConnection: true` is required for the second and third hosts on
the same endpoint within the same process.

---

## 9. Sync Callbacks

### 9.1 Why sync callbacks exist

Registered callbacks normally run on native worker threads. Some use
cases — notably UI updates — require the callback body to run on the
application's **main thread**. The sync variants of the registration
methods provide that.

### 9.2 The contract

When you register a callback with `synchronous: true`
(`LingoFuseApp.Expose(..., synchronous: true)` or
`AppHandle.RegisterCallSync` / `RegisterNotifySync`):

1. The native worker thread enqueues the callback into a process-wide
   queue and then **blocks** until the main thread executes it.
2. The application must call `LingoFuseSync.ProcessSyncQueue()`
   periodically from the main thread to drain the queue.

**Why the worker blocks**: the input/output `DataHandle` instances
passed to the callback are borrowed from the native layer, which
releases them as soon as the callback returns. If the callback were
enqueued and the worker returned immediately, the handles would be
freed while the main thread was still waiting to run the body. Blocking
the worker until the main thread has finished guarantees the handles
stay valid.

### 9.3 The public API

```csharp
public static class LingoFuseSync
{
    public static void SetMainThread();
    public static bool IsMainThreadCurrent { get; }
    public static int  PendingSyncCount    { get; }
    public static long TotalSyncProcessed  { get; }

    public static int ProcessSyncQueue();
}
```

| Member                   | Effect                                                                                    |
|--------------------------|-------------------------------------------------------------------------------------------|
| `SetMainThread()`        | Designates the calling thread as the main thread. Call once at startup.                    |
| `IsMainThreadCurrent`    | True when the caller is the registered main thread.                                        |
| `PendingSyncCount`       | Number of callbacks waiting to be drained.                                                 |
| `TotalSyncProcessed`     | Cumulative count of callbacks executed since process start.                                |
| `ProcessSyncQueue()`     | Drains every pending callback. Returns the number executed.                                |

The first call to `ProcessSyncQueue` automatically registers the caller
as the main thread. If the very first call may come from a non-UI
thread, call `SetMainThread()` explicitly during application startup.

### 9.4 Main-loop integration

**Windows Forms / WPF**:

```csharp
System.Windows.Forms.Application.Idle +=
    (_, __) => LingoFuseSync.ProcessSyncQueue();
```

Or a timer:

```csharp
var timer = new System.Windows.Forms.Timer { Interval = 10 };
timer.Tick += (_, __) => LingoFuseSync.ProcessSyncQueue();
timer.Start();
```

**Console / service**:

```csharp
while (running)
{
    LingoFuseSync.ProcessSyncQueue();
    Thread.Sleep(10);
}
```

**ASP.NET Core**: run a dedicated hosted service on the main pipeline
thread, or designate a background thread as the main thread via
`SetMainThread()` and drain from there.

### 9.5 Failure to drain

If `ProcessSyncQueue` is never called:

- the queued callbacks never execute;
- the native worker threads that dispatched them block forever inside
  the internal completion wait;
- the framework eventually stalls.

`LingoFuseSync.PendingSyncCount` is a useful diagnostic: a persistently
non-zero value means the main loop is not draining often enough.

---

## 10. Network Events

### 10.1 Semantics

The binding exposes two **process-global** event handlers:

| Event        | Trigger                                                              | Frequency                                |
|--------------|----------------------------------------------------------------------|------------------------------------------|
| **Connect**  | First service API-info broadcast received by any client in the process. | Once per connection lifecycle, again after a successful auto-reconnect. |
| **Disconnect**| Physical link loss.                                                 | Once per physical loss.                   |

**Connect is NOT the TCP handshake.** It is the earliest point at which
the client can route remote calls. A TCP connection that has not yet
received the service's broadcast does not produce a Connect.

### 10.2 Threading

Both handlers run on a **background worker thread** owned by the native
library. They must:

- copy the endpoint string if they need to keep it (the wrapper already
  copies it into a managed `string` before invoking the user delegate,
  so user code never sees a dangling pointer);
- never touch UI controls directly;
- never call any blocking LingoFuse function;
- never let an exception escape.

The wrapper enforces the last rule: exceptions are caught and logged via
`Debug.WriteLine`. The native layer sees a callback that returned
normally.

### 10.3 The public API

```csharp
public static class NetworkEvents
{
    public static bool IsInstalled { get; }

    public static void Set(Action<string>? onConnect,
                           Action<string>? onDisconnect);

    public static void Clear();
}
```

### 10.4 Usage

```csharp
NetworkEvents.Set(
    onConnect: addr => Console.WriteLine($"[+] {addr}"),
    onDisconnect: addr => Console.WriteLine($"[-] {addr}"));
```

Passing `null` for either argument disables that particular event.

### 10.5 Install / clear timing

Install the handlers **before** the framework starts, or at any point
while it is running. Clear them **before** calling
`LingoFuseFramework.Shutdown()` so that no user callback can fire during
teardown.

`LingoFuseFramework.Shutdown()` clears both handlers automatically as
its first step, so an explicit `Clear()` is optional.

### 10.6 Replace semantics

`Set` is a **replace**, not a patch. Calling it twice discards the
previous handlers, even for the side whose argument is `null` in the new
call:

```csharp
NetworkEvents.Set(onConnect: cb1, onDisconnect: null);
NetworkEvents.Set(onConnect: null, onDisconnect: cb2);
// cb1 is now uninstalled; only cb2 is active.
```

To install both, pass them in a single call.

---

## 11. Status and Diagnostics

### 11.1 Status queue

The native library maintains a bounded FIFO of log messages, up to
1000 entries. Older entries are dropped when the buffer is full.

**Main-thread dependency**: the status queue is processed by the
simulated main thread. Before `LF_PrepareDone`, the queue may be empty
or stale. Applications should not rely on status messages during
initialization.

**Static buffer hazard**: `LF_GetStatus` returns a pointer into a
process-wide static buffer that is overwritten by the next call. The
C# wrapper copies the string to a managed instance immediately, so
callers never observe a dangling pointer.

### 11.2 The public API

```csharp
public static class LingoFuseStatus
{
    public static int    GetStatusCount();
    public static string GetStatus();
    public static string[] DrainStatus(int maxMessages = 64);
    public static void   PostStatus(string message);

    public static bool CheckMainThread();
    public static bool CheckApp(string appName);
    public static bool CheckApi(string appName, string apiName);
}
```

| Method              | Effect                                                                                    |
|---------------------|-------------------------------------------------------------------------------------------|
| `GetStatusCount()`  | Number of pending log messages.                                                            |
| `GetStatus()`       | Retrieves and removes the next message. Empty string when the queue is empty.              |
| `DrainStatus(n)`    | Retrieves up to `n` messages in FIFO order. Returns an empty array when the queue is empty.|
| `PostStatus(msg)`   | Injects a custom message into the queue.                                                   |
| `CheckMainThread()` | True when the simulated main thread is running.                                            |
| `CheckApp(name)`    | True when the named application is available (locally or remotely).                        |
| `CheckApi(app, api)`| True when the named API is available on the given application.                             |

### 11.3 The cache-delay caveat

`CheckApp` and `CheckApi` use a **local cache** updated by network
broadcasts with an approximate 3-second delay. They are suitable for
probing and diagnostics, **not** for authoritative availability
decisions.

False negatives immediately after registration and false positives
shortly after unregistration are both normal. For critical paths,
issue the call and handle timeouts explicitly. A common pattern is a
short retry loop:

```csharp
bool available = false;
for (int i = 0; i < 15; i++)
{
    if (LingoFuseStatus.CheckApi("MyApp", "my_api"))
    {
        available = true;
        break;
    }
    Thread.Sleep(200);
}
```

---

## 12. Cross-Language Wire Contracts

### 12.1 UTF-8, NUL, little-endian

Every string in every payload is UTF-8 and NUL-terminated. Every integer
and float is little-endian. These rules hold for both channels (JSON
and ABI) and for every binding (C#, C++, Pascal, Python).

### 12.2 ABI wire format

The ABI channel exposes the raw native types through `DataHandle`. The
byte layout for each type is fixed and platform-independent:

| Type                       | Bytes | Encoding                              |
|----------------------------|:-----:|---------------------------------------|
| `int8` / `uint8`           | 1     | two's complement / unsigned           |
| `int16` / `uint16`         | 2     | little-endian                         |
| `int32` / `uint32`         | 4     | little-endian                         |
| `int64` / `uint64`         | 8     | little-endian                         |
| `single` (float)           | 4     | IEEE 754 single-precision, LE         |
| `double`                   | 8     | IEEE 754 double-precision, LE         |
| `string`                   | var   | UTF-8 bytes + one `0x00` byte         |

**NUL-framed read (fault-tolerant)**: reading a string stops at the
first NUL byte. If no NUL is present, the entire remaining buffer is
consumed and the cursor is advanced to `size + 1`.

### 12.3 The `add` example — byte layout

Request (a = 5, b = 7):

```
05 00 00 00  07 00 00 00
```

Response (sum = 12):

```
0C 00 00 00
```

### 12.4 The `inv_seri` example — byte layout

Request (b = 200, w = 0x10, c = 0x2F, u64 = 0x3F,
s = "hello world", f = 3.14f):

```
C8                              uint8
10 00                           uint16 LE
2F 00 00 00                     uint32 LE
3F 00 00 00 00 00 00 00         uint64 LE
68 65 6C 6C 6F 20 77 6F 72 6C 64 00   "hello world" + NUL
C3 F5 48 40                     float LE
```

Response (reverse field order):

```
C3 F5 48 40                     float LE
68 65 6C 6C 6F 20 77 6F 72 6C 64 00
3F 00 00 00 00 00 00 00         uint64 LE
2F 00 00 00                     uint32 LE
10 00                           uint16 LE
C8                              uint8
```

### 12.5 The JSON wire format

A JSON payload is the UTF-8 encoding of the JSON text, followed by one
NUL byte. Reading is fault-tolerant as described in §5.8.2.

The canonical serialisation policy is documented in §13.

### 12.6 String reading across languages

| Language | Invalid UTF-8 handling on read                     |
|----------|----------------------------------------------------|
| C#       | Each invalid byte becomes U+FFFD                   |
| Pascal   | Each invalid byte becomes U+FFFD                   |
| Python   | Raises `UnicodeDecodeError`                        |
| C++      | Returns the raw bytes unchanged                    |

**C# matches Pascal**, not Python or C++. The C# reader is binary-safe:
it never fails on a malformed payload.

If a C# receiver needs to detect invalid UTF-8, it must read the raw
bytes via `ReadBytesExact` / `ReadAllBytes` and inspect them itself.

### 12.7 Cross-language call patterns

**C# server + C++ / Pascal / Python client (ABI channel)**:

```csharp
// C# server
using var server = new LingoFuseServer("Calc", "ipc:calc");
server.App.Expose("add", "add", (input, output) =>
{
    int a = input.ReadInt32();
    int b = input.ReadInt32();
    output.WriteInt32(a + b);
});
server.Start();
```

```cpp
// C++ client
lingofuse::DataHandle param("add");
param.write<int32_t>(5);
param.write<int32_t>(7);
auto resp = lingofuse::tryCall("Calc", param, 3000);
int32_t sum = 0; resp->read(sum);   // 12
```

**C# client + C++ / Pascal / Python server (ABI channel)**:

```csharp
using var client = new LingoFuseClient("ipc:calc");
client.Connect();

using var req = new DataHandle("add");
req.WriteInt32(5);
req.WriteInt32(7);

using var resp = client.CallBinary("Calc", req, 3000);
int sum = resp.ReadInt32();   // 12
```

**JSON channel** — identical to the above, except the payload is
serialised and deserialised through `LfIo.WriteJson` / `LfIo.ReadJson`
or through the typed `Call<T>` / `Expose<T...>` overloads.

### 12.8 Choosing a channel

| Criterion              | JSON channel                                            | ABI channel                                             |
|------------------------|---------------------------------------------------------|---------------------------------------------------------|
| Structured data        | Convenient — typed overloads serialise automatically    | Manual field-by-field writes                            |
| Interop with C++ / Pascal / Python | Works, but the peer must use the same JSON policy       | Works, byte-precise by construction                     |
| Payload size           | Larger (JSON overhead)                                  | Smaller (raw binary)                                    |
| Debuggability          | Human-readable on the wire                              | Requires a hex dump                                     |
| Schema evolution       | Easier — new fields can be added without breaking peers | Requires coordinated field-by-field changes             |

**Rule of thumb**: JSON for structured, evolving data; ABI for byte-
precise cross-language interop or for performance-critical paths.

---

## 13. JSON Policy

### 13.1 The single source of truth

`JsonPolicy` is the canonical serializer for the whole C# binding.
Every JSON payload written by the binding passes through its options.

```csharp
public static class JsonPolicy
{
    public static readonly JsonSerializerOptions Options;
    public static readonly JsonSerializerOptions OptionsSnakeCase;

    public static string Dumps(object? value);
    public static T      Loads<T>(string json);
    public static bool   TryLoads<T>(string? json, out T? value);
}
```

### 13.2 The policy

| Property                | Value                                    |
|-------------------------|------------------------------------------|
| `WriteIndented`         | `false` (compact output)                 |
| `Encoder`               | `JavaScriptEncoder.UnsafeRelaxedJsonEscaping` (literal UTF-8, no `\uXXXX` escapes for characters that can be emitted literally) |
| `PropertyNameCaseInsensitive` | `false`                            |
| `DefaultIgnoreCondition`| `JsonIgnoreCondition.Never`              |
| `NumberHandling`        | `JsonNumberHandling.Strict`              |
| `PropertyNamingPolicy`  | `null` (C# property names used verbatim) |

### 13.3 Literal UTF-8, not `\uXXXX` escapes

The encoder preserves non-ASCII characters as literal UTF-8. For
example, `{"msg": "你好"}` is written as:

```
7B 22 6D 73 67 22 3A 20 22 E4 BD A0 E5 A5 BD 22 7D 00
```

not as `{"msg": "\u4f60\u597d"}`. This matches every other binding in
the toolchain.

### 13.4 Null handling

A null value is written as the four-byte JSON literal `null`. A null
reference argument sent by a peer is passed to a typed handler as
`default(TArg)`.

### 13.5 Cross-language naming

`System.Text.Json` uses the C# property name verbatim. For a C# `record`
named `Person(Name, Age)`, the JSON keys will be `"Name"` and `"Age"`,
not `"name"` and `"age"`.

**If a peer (Python / C++ / Pascal) expects snake_case keys**, mark each
property with `[JsonPropertyName]`:

```csharp
public sealed record Person(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("age")]  int    Age);
```

Alternatively, use `OptionsSnakeCase`, which applies the snake_case
naming policy globally. This is not the default because a global policy
would silently rename every C# payload.

### 13.6 Number formatting caveat

`System.Text.Json` emits the shortest round-trippable representation of
a floating-point number:

| Value | C# output | Python output | C++ output |
|-------|-----------|---------------|------------|
| 1.0   | `1`       | `1.0`         | `1.0`      |
| 1e-7  | `1E-07`   | `1e-07`       | `1e-7`     |

Every parser reads these as the same numeric value. The only case where
the byte difference matters is a golden-file comparison of raw JSON
text; cross-language tests should compare numeric values after parsing,
not bytes before parsing.

### 13.7 Public helpers

```csharp
string json    = JsonPolicy.Dumps(new { a = 1, b = "x" });
// json == "{\"a\":1,\"b\":\"x\"}"

var obj        = JsonPolicy.Loads<MyType>(json);
bool ok        = JsonPolicy.TryLoads<MyType>(json, out var parsed);
```

`Loads<T>` throws `LingoFuseException` on malformed input.
`TryLoads<T>` returns `false` on malformed input (and for a null or
empty string).

---

## 14. Exception Hierarchy

### 14.1 The tree

```
LingoFuseException                      (base)
├── LingoFuseLibraryLoadException       native library cannot be loaded
├── LingoFuseCallException              remote call failed
├── LingoFuseRegistrationException      API registration failed
├── LingoFuseObjectDisposedException    use after Dispose
├── LingoFuseStateException             invalid object state
└── LingoFuseIoException                I/O on a DataHandle failed
```

Plus the standard .NET exceptions that the binding also throws:
`ArgumentNullException`, `ArgumentOutOfRangeException`,
`ArgumentException`.

### 14.2 When each is thrown

| Exception                          | Trigger                                                         |
|------------------------------------|-----------------------------------------------------------------|
| `LingoFuseLibraryLoadException`    | Reserved; the binding currently surfaces load failures as `DllNotFoundException`. |
| `LingoFuseCallException`           | A throwing remote-call method (`Call<T>`, `CallRaw`, `CallBinary`) failed. Carries `TargetApp` / `TargetApi` when known. |
| `LingoFuseRegistrationException`   | Reserved for future use; the current registration methods return `false` on failure instead of throwing. |
| `LingoFuseObjectDisposedException` | A method was called on a disposed object.                       |
| `LingoFuseStateException`          | The object is in the wrong state (not connected, already running, etc.). |
| `LingoFuseIoException`             | An exact read or write on a `DataHandle` failed. Carries `Operation` (e.g. `"ReadBytesExact"`). |

### 14.3 Non-throwing counterparts

Every throwing remote-call method has a `Try*` counterpart that
returns a boolean instead:

| Throwing                    | Non-throwing                  |
|-----------------------------|-------------------------------|
| `Call<T>`                   | `TryCall<T>`                  |
| `CallRaw`                   | `TryCallRaw`                  |
| `CallBinary`                | `TryCallBinary`               |
| `LocalCall<T>`              | `TryLocalCall<T>`             |

The `Try*` methods still throw `ArgumentNullException` and
`LingoFuseObjectDisposedException` for caller misuse. They only catch
"the peer did not respond" conditions (timeout, unreachable target,
empty reply, JSON deserialisation failure).

### 14.4 Recommended catch pattern

```csharp
try
{
    using var client = new LingoFuseClient("ipc:svc");
    client.Connect();
    // ...
}
catch (LingoFuseCallException ex)
{
    // Remote call failed; ex.TargetApp / ex.TargetApi are populated.
}
catch (LingoFuseStateException ex)
{
    // Object not in the right state.
}
catch (LingoFuseObjectDisposedException ex)
{
    // Use-after-dispose bug in the caller.
}
catch (LingoFuseIoException ex)
{
    // Byte-level I/O failure on a DataHandle.
}
catch (LingoFuseException ex)
{
    // Any other LingoFuse-specific failure.
}
catch (DllNotFoundException ex)
{
    // Native library not found.
}
```

---

## 15. Complete Examples

### 15.1 Minimal calculator server

```csharp
using System;
using LingoFuse.Core;
using LingoFuse.Host;

class CalculatorServer
{
    static int Main()
    {
        LingoFuseServer? server = null;
        try
        {
            server = new LingoFuseServer("Calc", "ipc:calc");

            server.App.Expose("add", "Add two int32s", (input, output) =>
            {
                int a = input.ReadInt32();
                int b = input.ReadInt32();
                output.WriteInt32(a + b);
            });

            server.App.Expose<string, string>("echo", s => s);

            server.Start();

            Console.WriteLine("Calculator running. Press Enter to stop.");
            Console.ReadLine();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[FATAL] {ex.Message}");
            return 1;
        }
        finally
        {
            server?.FullCleanup();
        }
        return 0;
    }
}
```

### 15.2 Calculator client

```csharp
using System;
using LingoFuse;
using LingoFuse.Core;
using LingoFuse.Host;

class CalculatorClient
{
    static int Main()
    {
        LingoFuseClient? client = null;
        try
        {
            client = new LingoFuseClient("ipc:calc");
            client.Connect();

            using var req = new DataHandle("add");
            req.WriteInt32(5);
            req.WriteInt32(7);

            using var resp = client.CallBinary("Calc", req, 3000);
            Console.WriteLine($"5 + 7 = {resp.ReadInt32()}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[FATAL] {ex.Message}");
            return 1;
        }
        finally
        {
            client?.FullCleanup();
        }
        return 0;
    }
}
```

### 15.3 Worker node (attaches to an existing coordinator)

```csharp
using System;
using LingoFuse.Core;
using LingoFuse.Host;

class Worker
{
    static int Main()
    {
        LingoFuseNode? node = null;
        try
        {
            node = new LingoFuseNode("Compute", "ipc:beacon");

            node.App.Expose<int, int, int>("double", n => n * 2);

            node.Connect(overlapConnection: true);

            Console.WriteLine("Worker online. Press Enter to stop.");
            Console.ReadLine();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[FATAL] {ex.Message}");
            return 1;
        }
        finally
        {
            node?.FullCleanup();
        }
        return 0;
    }
}
```

### 15.4 Coordinator + worker + caller in one process

```csharp
using System;
using LingoFuse.Core;
using LingoFuse.Host;

class AllInOne
{
    static int Main()
    {
        var server = new LingoFuseServer("Beacon", "ipc:beacon");
        server.Start();

        using var node = new LingoFuseNode("Worker", "ipc:beacon");
        node.App.Expose<int, int, int>("add", (a, b) => a + b);
        node.Connect(overlapConnection: true);

        using var client = new LingoFuseClient("ipc:beacon");
        client.Connect(overlapConnection: true);

        int sum = client.Call<int>("Worker", "add",
                                   new object[] { 20, 22 }, 3000);
        Console.WriteLine($"20 + 22 = {sum}");

        client.Dispose();
        node.Dispose();
        server.Stop(fullCleanup: false);

        LingoFuseFramework.Shutdown();
        return 0;
    }
}
```

### 15.5 Concurrency

```csharp
using System;
using System.Collections.Generic;
using System.Threading;
using LingoFuse.Core;
using LingoFuse.Host;

class ConcurrentClient
{
    static int Main()
    {
        LingoFuseClient? client = null;
        try
        {
            client = new LingoFuseClient("ipc:calc");
            client.Connect();

            int total = 0;
            var threads = new List<Thread>();
            for (int t = 0; t < 10; t++)
            {
                var thread = new Thread(() =>
                {
                    for (int i = 0; i < 100; i++)
                    {
                        using var req = new DataHandle("add");
                        req.WriteInt32(i);
                        req.WriteInt32(i);

                        using var resp = client.CallBinary(
                            "Calc", req, 3000);
                        Interlocked.Add(ref total, resp.ReadInt32());
                    }
                });
                threads.Add(thread);
            }

            foreach (var t in threads) t.Start();
            foreach (var t in threads) t.Join();

            Console.WriteLine($"Total: {total}");
        }
        finally
        {
            client?.FullCleanup();
        }
        return 0;
    }
}
```

### 15.6 Sync callback with a UI main loop

```csharp
using System;
using System.Windows.Forms;
using LingoFuse;
using LingoFuse.Core;
using LingoFuse.Host;

class UiServer : Form
{
    [STAThread]
    static void Main()
    {
        LingoFuseSync.SetMainThread();

        var server = new LingoFuseServer("UiApp", "ipc:ui");

        server.App.Expose<int, int, int>(
            "add",
            (a, b) =>
            {
                // Runs on the UI thread because synchronous: true.
                MessageBox.Show($"{a} + {b}");
                return a + b;
            },
            synchronous: true);

        server.Start();

        var timer = new Timer { Interval = 10 };
        timer.Tick += (_, __) => LingoFuseSync.ProcessSyncQueue();
        timer.Start();

        Application.Run(new UiServer());
        server.FullCleanup();
    }
}
```

### 15.7 Network event listener

```csharp
using System;
using LingoFuse.Core;
using LingoFuse.Events;
using LingoFuse.Host;

class EventListener
{
    static int Main()
    {
        NetworkEvents.Set(
            onConnect:    addr => Console.WriteLine($"[+] {addr}"),
            onDisconnect: addr => Console.WriteLine($"[-] {addr}"));

        LingoFuseClient? client = null;
        try
        {
            client = new LingoFuseClient("ipc:svc");
            client.Connect();

            Console.WriteLine("Press Enter to exit.");
            Console.ReadLine();
        }
        finally
        {
            client?.FullCleanup();
        }
        return 0;
    }
}
```

---

## 16. Anti-Patterns and Pitfalls

### 16.1 Using `using` alone for a lone host

```csharp
// ❌ WRONG: Dispose() only detaches. The framework stays running.
using var client = new LingoFuseClient("ipc:svc");
client.Connect();
// Process exits with the simulated main thread still alive.
```

```csharp
// ✅ CORRECT: FullCleanup() in a finally block.
LingoFuseClient? client = null;
try
{
    client = new LingoFuseClient("ipc:svc");
    client.Connect();
    // ...
}
finally
{
    client?.FullCleanup();
}
```

### 16.2 Calling `LF_Call` from inside a callback

```csharp
// ❌ WRONG: deadlocks the worker thread.
app.Expose("outer", "outer", (input, output) =>
{
    using var req = new DataHandle("inner");
    using var resp = client.CallBinary("OtherApp", req, 3000);   // deadlock
});
```

```csharp
// ✅ CORRECT: offload to a separate thread and return immediately.
app.Expose("outer", "outer", (input, output) =>
{
    var captured = input.ReadAllBytes();
    Task.Run(() =>
    {
        using var req = new DataHandle("inner");
        req.WriteBytes(captured);
        using var resp = client.CallBinary("OtherApp", req, 3000);
        // process resp ...
    });
});
```

### 16.3 Disposing a borrowed handle inside a callback

```csharp
// ❌ WRONG (but harmless in this binding):
app.Expose("api", "desc", (input, output) =>
{
    input.Dispose();                 // no-op for a borrowed handle
    var s = input.ReadString();      // still works
});
```

The binding treats `Dispose()` on a borrowed handle as a no-op, so the
code above is not a bug — but it is misleading. Do not dispose borrowed
handles.

### 16.4 Using `HasValue` on an unconstrained generic return

```csharp
// ❌ WRONG: int has no HasValue.
var v = app.LocalCall<int>("answer");
if (v.HasValue) { ... }
```

```csharp
// ✅ CORRECT: int is the return type.
int v = app.LocalCall<int>("answer");
if (app.TryLocalCall<int>("answer", null, out int v2)) { ... }
```

### 16.5 Expecting `LocalCall<T>` to signal an unregistered API

```csharp
// ❌ MISLEADING: this returns default(int) == 0; it does not throw.
int v = app.LocalCall<int>("not_registered");
```

```csharp
// ✅ CORRECT: use TryLocalCall<T>.
if (app.TryLocalCall<int>("not_registered", null, out int v))
{
    // API is registered; v is the handler's return value.
}
else
{
    // API is not registered.
}
```

### 16.6 Sharing a `DataHandle` across threads for writes

```csharp
// ❌ WRONG: concurrent writes corrupt the cursor.
Parallel.For(0, 100, i => { dh.WriteInt32(i); });
```

```csharp
// ✅ CORRECT: one handle per thread, or a lock around the handle.
Parallel.For(0, 100, i =>
{
    using var dh = new DataHandle("api");
    dh.WriteInt32(i);
    // ...
});
```

### 16.7 Reading past the end of a buffer

```csharp
// ❌ WRONG: throws LingoFuseIoException when the buffer is too short.
using var dh = new DataHandle("api");
dh.WriteInt32(42);
dh.Position = 0;
long a = dh.ReadInt64();   // throws
```

```csharp
// ✅ CORRECT: check the size first, or use TryReadInt64.
using var dh = new DataHandle("api");
dh.WriteInt32(42);
dh.Position = 0;
if (dh.TryReadInt64(out long a)) { ... }
```

### 16.8 Forgetting that `TryCall` can fail for multiple reasons

```csharp
// A false return can mean any of:
//   - timeout
//   - unreachable target
//   - empty reply
//   - JSON deserialisation failure (for TryCall<T>)
if (!client.TryCall<int>("Calc", "add", payload, 3000, out var sum))
{
    // You cannot tell which. Use TryCallRaw + your own JSON parse
    // if you need to distinguish.
}
```

### 16.9 Installing overlapping network events

```csharp
// ❌ WRONG: the second call replaces the first.
NetworkEvents.Set(onConnect: cb1, onDisconnect: null);
NetworkEvents.Set(onConnect: null, onDisconnect: cb2);
// cb1 is no longer installed.
```

```csharp
// ✅ CORRECT: install both in one call.
NetworkEvents.Set(onConnect: cb1, onDisconnect: cb2);
```

### 16.10 Forgetting `overlapConnection: true` for multiple hosts

```csharp
// ❌ WRONG: the second Connect throws LingoFuseStateException.
var n1 = new LingoFuseNode("Worker1", "ipc:beacon");
n1.Connect();
var n2 = new LingoFuseNode("Worker2", "ipc:beacon");
n2.Connect();       // throws
```

```csharp
// ✅ CORRECT:
n1.Connect(overlapConnection: true);
n2.Connect(overlapConnection: true);
```

### 16.11 Calling `CheckApi` as an authoritative gate

```csharp
// ❌ FRAGILE: the cache can lag by ~3 s.
if (!LingoFuseStatus.CheckApi("Calc", "add")) return;

using var req = new DataHandle("add");
// ... call may still fail if the cache is stale ...
```

```csharp
// ✅ ROBUST: retry loop.
bool ready = false;
for (int i = 0; i < 15; i++)
{
    if (LingoFuseStatus.CheckApi("Calc", "add"))
    {
        ready = true;
        break;
    }
    Thread.Sleep(200);
}

// Or just call and handle the failure.
```

### 16.12 Mixing JSON and ABI on the same (app, api)

```csharp
// ❌ WRONG: the server writes ABI bytes; the client reads JSON.
server.App.Expose("api", "desc", (input, output) =>
    output.WriteInt32(42));

// Client side:
int v = client.Call<int>("App", "api");   // ❌ JSON decoder sees raw bytes
```

```csharp
// ✅ CORRECT: pick one channel and use it consistently.
// ABI server:
server.App.Expose("api", "desc", (input, output) =>
    output.WriteInt32(42));

// ABI client:
using var req = new DataHandle("api");
using var resp = client.CallBinary("App", req, 3000);
int v = resp.ReadInt32();
```

### 16.13 Disposing the response handle before reading

```csharp
// ❌ WRONG:
var resp = client.CallBinary("App", req, 3000);
resp.Dispose();
int v = resp.ReadInt32();   // throws LingoFuseObjectDisposedException
```

```csharp
// ✅ CORRECT:
using var resp = client.CallBinary("App", req, 3000);
int v = resp.ReadInt32();
```

### 16.14 Ignoring `PendingSyncCount`

```csharp
// ❌ Potential silent stall if ProcessSyncQueue is too slow.
while (running) { Thread.Sleep(1000); }
```

```csharp
// ✅ Monitor and drain promptly.
while (running)
{
    LingoFuseSync.ProcessSyncQueue();
    if (LingoFuseSync.PendingSyncCount > 100)
        Console.Error.WriteLine("Sync queue backing up");
    Thread.Sleep(10);
}
```

---

## 17. Quick Reference

### 17.1 Public classes

| Type                  | Namespace              | Purpose                              |
|-----------------------|------------------------|--------------------------------------|
| `LingoFuseFramework`  | `LingoFuse.Host`       | Process-wide lifecycle control.      |
| `LingoFuseServer`     | `LingoFuse.Host`       | Coordinator host.                    |
| `LingoFuseNode`       | `LingoFuse.Host`       | Worker host.                         |
| `LingoFuseClient`     | `LingoFuse.Host`       | Pure consumer host.                  |
| `LingoFuseApp`        | `LingoFuse.Host`       | Application container (used by hosts).|
| `AppHandle`           | `LingoFuse.Core`       | Low-level native app wrapper.        |
| `DataHandle`          | `LingoFuse.Core`       | Payload buffer.                      |
| `LingoFuseSync`       | `LingoFuse.Core`       | Sync-callback main-thread queue.     |
| `LfIo`                | `LingoFuse.Io`         | NUL-framed string / JSON I/O.        |
| `JsonPolicy`          | `LingoFuse.Io`         | Canonical JSON serialisation policy. |
| `LingoFuseStatus`     | `LingoFuse.Diagnostics`| Status queue and health checks.      |
| `NetworkEvents`       | `LingoFuse.Events`     | Process-global connect/disconnect.   |

### 17.2 `DataHandle` atomic types

| Write                | Exact read            | Try read                                 |
|----------------------|-----------------------|------------------------------------------|
| `WriteInt8`          | `ReadInt8`            | `TryReadInt8(out sbyte value)`           |
| `WriteUInt8`         | `ReadUInt8`           | `TryReadUInt8(out byte value)`           |
| `WriteInt16`         | `ReadInt16`           | `TryReadInt16(out short value)`          |
| `WriteUInt16`        | `ReadUInt16`          | `TryReadUInt16(out ushort value)`        |
| `WriteInt32`         | `ReadInt32`           | `TryReadInt32(out int value)`            |
| `WriteUInt32`        | `ReadUInt32`          | `TryReadUInt32(out uint value)`          |
| `WriteInt64`         | `ReadInt64`           | `TryReadInt64(out long value)`           |
| `WriteUInt64`        | `ReadUInt64`          | `TryReadUInt64(out ulong value)`         |
| `WriteSingle`        | `ReadSingle`          | `TryReadSingle(out float value)`         |
| `WriteDouble`        | `ReadDouble`          | `TryReadDouble(out double value)`        |
| `WriteString`        | `ReadString`          | `TryReadString(out string? value)`       |
| `WriteBytes`         | `ReadBytes` / `ReadBytesExact` | `TryReadBytes(n, out byte[]? value)` |

### 17.3 Host API

| Method                          | Client | Server | Node |
|---------------------------------|:------:|:------:|:----:|
| `Connect(overlapConnection)`    | ✅     | ❌     | ✅   |
| `Start(overlapConnection)`      | ❌     | ✅     | ❌   |
| `Stop(fullCleanup)`             | ❌     | ✅     | ❌   |
| `Dispose()`                     | ✅     | ✅     | ✅   |
| `FullCleanup()`                 | ✅     | ✅     | ✅   |
| `Call<T>` / `CallRaw`           | ✅     | ✅     | ✅   |
| `TryCall<T>` / `TryCallRaw`     | ✅     | ✅     | ✅   |
| `Notify` / `SequencedNotify`    | ✅     | ✅     | ✅   |
| `CallBinary` / `TryCallBinary`  | ✅     | ✅     | ✅   |
| `NotifyBinary` / `SequencedNotifyBinary` | ✅ | ✅ | ✅ |
| `App` property                  | ❌     | ✅     | ✅   |

### 17.4 `LingoFuseFramework` lifecycle

| Member              | Effect                                                         |
|---------------------|----------------------------------------------------------------|
| `IsStarted`         | True when the simulated main thread is alive.                  |
| `Shutdown()`        | Full teardown: clear events, exit, `LF_Shutdown`, reset.       |
| `ExitMainThread()`  | Stop the simulated main thread; library stays loaded.          |
| `ResetPrepare()`    | `LF_ResetPrepare`.                                             |

### 17.5 `LingoFuseSync`

| Member                    | Effect                                                       |
|---------------------------|--------------------------------------------------------------|
| `SetMainThread()`         | Designate the calling thread as the main thread.             |
| `IsMainThreadCurrent`     | True when the caller is the main thread.                     |
| `PendingSyncCount`        | Pending sync callbacks.                                      |
| `TotalSyncProcessed`      | Cumulative count of sync callbacks executed.                 |
| `ProcessSyncQueue()`      | Drain the queue; returns the number executed.                |

### 17.6 `NetworkEvents`

| Member                        | Effect                                                     |
|-------------------------------|------------------------------------------------------------|
| `IsInstalled`                 | True when at least one handler is installed.               |
| `Set(onConnect, onDisconnect)`| Replace both handlers; `null` disables one side.           |
| `Clear()`                     | Remove both handlers.                                      |

### 17.7 `LingoFuseStatus`

| Member                        | Effect                                                     |
|-------------------------------|------------------------------------------------------------|
| `GetStatusCount()`            | Number of pending log messages.                            |
| `GetStatus()`                 | Dequeue the next log message.                              |
| `DrainStatus(maxMessages)`    | Dequeue up to N messages.                                  |
| `PostStatus(message)`         | Inject a message.                                          |
| `CheckMainThread()`           | True when the simulated main thread is running.            |
| `CheckApp(name)`              | True when the named app is available (cache-based).        |
| `CheckApi(app, api)`          | True when the named API is available (cache-based).        |

### 17.8 Types

| Name                       | Size on wire (ABI) | Encoding                    |
|----------------------------|:------------------:|-----------------------------|
| `int8` / `uint8`           | 1                  | two's complement / unsigned |
| `int16` / `uint16`         | 2                  | little-endian               |
| `int32` / `uint32`         | 4                  | little-endian               |
| `int64` / `uint64`         | 8                  | little-endian               |
| `single`                   | 4                  | IEEE 754 LE                 |
| `double`                   | 8                  | IEEE 754 LE                 |
| `string`                   | variable           | UTF-8 + NUL                 |

### 17.9 The seven iron rules

1. **Call `FullCleanup()` on the last host in the process** — otherwise
   the simulated main thread never stops.
2. **Never call a blocking LingoFuse function inside a callback** — it
   deadlocks.
3. **Never dispose a borrowed `DataHandle`** — `Dispose()` is a no-op,
   but the correct behaviour is to leave it alone.
4. **Drive `LingoFuseSync.ProcessSyncQueue()` from the main thread** if
   you registered any sync callback.
5. **Use `TryLocalCall<T>` / `TryCall<T>` to detect unregistered APIs**;
   `LocalCall<T>` / `Call<T>` return `default(T)`, which is
   indistinguishable from a legitimate default value.
6. **Choose one payload channel (JSON or ABI) per (app, api) and stick
   with it across every language.**
7. **Set `overlapConnection: true` when two or more hosts share the same
   endpoint within one process.**

---

## 18. Self-Audit

This section verifies that the document is self-sufficient. The
checklist below enumerates every question a reader might ask and points
to the section that answers it.

| Question                                                     | Section  |
|--------------------------------------------------------------|----------|
| How do I load the native library?                            | §3.1     |
| How do I unload it?                                          | §3.4, §4 |
| What does `LingoFuseFramework.Shutdown()` do?                | §4.1–§4.3|
| When should I call it?                                       | §4.2, §8.6 |
| How do I create a `DataHandle`?                              | §5.2     |
| What does `ReadString` do when there is no NUL?              | §5.8.2   |
| What does `ReadBytesExact` throw?                            | §5.4.2   |
| How do I write two int32s?                                   | §5.5     |
| What happens when a callback is called after Dispose?        | §5.9     |
| How do I register a Call API?                                | §6.2, §7.3, §7.4 |
| How do I register a Notify API?                              | §6.2.2, §7.4 |
| What runs on the native worker thread?                       | §6.2.1, §6.2.2, §9.1 |
| How do I run a callback on the UI thread?                    | §9       |
| How do I invoke an API locally?                              | §6.3, §7.5, §7.7 |
| How do I bind an App to an existing client?                  | §6.4, §7.7, §8.1 |
| What is the difference between `Client`, `Server`, `Node`?   | §1.2, §8.1 |
| How do I start a server?                                     | §8.3.3   |
| How do I connect a client?                                   | §8.3.1   |
| How do I stop a host?                                        | §8.5     |
| What does `overlapConnection` do?                            | §8.3.4   |
| How do I make a JSON call?                                   | §8.4.1   |
| How do I make an ABI call?                                   | §8.4.3   |
| How do I make a non-throwing call?                           | §8.4.2   |
| How do I know if a call timed out?                           | §8.4.2, §14.2 |
| How do I get the remote response bytes?                      | §8.4.3   |
| How do I know when a peer connects?                          | §10      |
| How do I access the status log?                              | §11      |
| How do I know if an App is available?                        | §11.2, §11.3 |
| What is the byte layout of an int32?                         | §12.2    |
| What is the byte layout of a string?                         | §12.2    |
| How do I write a payload that a C++ peer can read?           | §12.7    |
| How do I read invalid UTF-8?                                 | §5.8.2, §12.6 |
| How is JSON serialised?                                      | §13.2    |
| How do I make a JSON key snake_case?                         | §13.5    |
| Why are floating-point numbers formatted differently?        | §13.6    |
| What exceptions can be thrown?                               | §14      |
| What are the most common mistakes?                           | §16      |
| What are the essential rules?                                | §17.9    |

**Self-audit result**: every question above can be answered from this
document alone. A reader who has studied §1–§17 is expected to write
correct C# LingoFuse programs without consulting the source. If any
question arises that this table does not cover, please consult the
source; the document is intended to be exhaustive, and any gap is a
defect worth reporting.

---

*End of document.*
