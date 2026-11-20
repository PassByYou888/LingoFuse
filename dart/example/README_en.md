# LingoFuse Dart Binding — Examples

> Chinese version: [README.md](README.md)

> This directory is the **example index and getting-started document** for the LingoFuse Dart binding.
>
> Unlike the main `README.md` (which covers "how to build, how to integrate, what the API is"), this file focuses on
> **"how to run it, how to verify it, how to write your own"**.
>
> **Suggested reading order**: read the [Quick start](../README_en.md#quick-start-minimal-example) section of the main `README.md` first,
> confirm the framework can start; then come back here and pick the example that matches your scenario.

---

## Contents

- [Where these examples come from](#where-these-examples-come-from)
- [Example inventory](#example-inventory)
- [Prerequisites](#prerequisites)
- [Common run flow](#common-run-flow)
- [Example details](#example-details)
  - [phase4 — C bridge layer probe](#phase4--c-bridge-layer-probe)
  - [phase5 — Framework layer probe](#phase5--framework-layer-probe)
  - [phase6 — Modern async API probe](#phase6--modern-async-api-probe)
  - [phase7 — Three addressing schemes probe](#phase7--three-addressing-schemes-probe)
  - [hello_async — teaching demo](#hello_async--teaching-demo)
- [How to write your own example (PoC)](#how-to-write-your-own-example-poc)
- [Project structure conventions](#project-structure-conventions)
- [Frequently asked questions](#frequently-asked-questions)

---

## Where these examples come from

The **official examples of the LingoFuse Dart binding all live in the `bin/` directory**, side by side with the unit and
integration tests under `test/`. The reasons for this design:

1. **Examples are tests**: every probe under `bin/` is a **self-contained end-to-end verification** that works both as
   a regression during development and as a starting template for users.
2. **No maintaining two copies of code**: when examples and tests are separate, they drift — "tests pass but the example
   is out of date" happens easily.
3. **Every example runs standalone**: `dart run bin/xxx.dart` just works, with no hidden dependencies.

This directory (`example/`) exists as an **index and reading entry point**; it holds no extra source code itself.
If a complex scenario that does not belong in `bin/` appears later (for example a demo needing several cooperating
processes), it will be added here as a subdirectory.

---

## Example inventory

| File | Type | Prerequisite | Coverage | Pass criterion |
|---|---|---|---|---|
| `bin/lf_probe.dart` | probe | DLL only | minimal FFI load check | all `[OK]` |
| `bin/phase1_test.dart` | probe | DLL only | DataHandle basic I/O | `failed: 0` |
| `bin/phase2_test.dart` | probe | DLL only | network preparation + caller side | `failed: 0` |
| `bin/phase3_test.dart` | probe | full framework | Server + remote call | all `[OK]` |
| `bin/phase4_bridge_probe.dart` | probe | bridge DLL | C bridge layer ABI | `passed: 21` |
| `bin/phase5_framework_test.dart` | probe | bridge DLL | typed options + argument validation | `passed: 28` |
| `bin/phase6_async_probe.dart` | probe | full framework | modern async API | `passed: 31` |
| `bin/phase7_addressing_probe.dart` | probe | full framework | three addressing schemes | `passed: 25` |
| `bin/hello_async.dart` | teaching demo | full framework | five async scenarios | full text output |

**Terminology**:

- **DLL only**: `LingoFuse64.dll` merely has to be findable by the OS loader; the framework need not start.
- **Bridge DLL**: additionally needs `lf_dart_bridge.dll`; the framework need not start.
- **Full framework**: the LingoFuse framework must be started (`Framework.prepareDone()`).

---

## Prerequisites

Complete the [Environment setup](../README_en.md#environment-setup) section of the main `README.md`, confirming three things in particular:

```powershell
# 1. the Dart SDK is available
dart --version
# should print: Dart SDK version: 3.6.x (stable) ...

# 2. the LingoFuse core library can be found
$env:PATH -split ';' | Select-String 'LingoFuse'
# should print something containing: D:\CoreLibrary\LingoFuse\Binary

# 3. the bridge DLL is built
Test-Path D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll
# should print: True
```

If item 3 is `False`, rebuild following the [Building the C bridge DLL](../README_en.md#building-the-c-bridge-dll)
section of the main `README.md`.

---

## Common run flow

Every example runs the same way:

```powershell
cd D:\CoreLibrary\LingoFuse\dart
dart run bin\<example-name>.dart
```

**Examples**:

```powershell
dart run bin\phase4_bridge_probe.dart
dart run bin\hello_async.dart
```

**Exit code conventions**:

- probes (`phase4` / `phase5` / `phase6` / `phase7`):
  - everything passes → exit code `0`
  - any failure → exit code `1`, printing `=== Summary ===` and the failure count at the end
- `hello_async`: always exit code `0` (it is a demo, not a verification).

**Output conventions**:

Probe output has three parts:

```
=== Phase N <description> ===

[Setup] ...            ← prerequisites: start the bridge / declare the group name / start the framework
[1] ...                ← item-by-item verification, each printing [OK] / [FAIL]
[2] ...
[Cleanup] ...          ← release resources

=== Summary ===
  passed: N
  failed: 0
```

Any `[FAIL]` line carries diagnostic information (actual value, exception type and so on).

---

## Example details

### phase4 — C bridge layer probe

**File**: `bin/phase4_bridge_probe.dart`

**Target**: whether the C ABI of `lf_dart_bridge.dll` is correct.

**Run**:

```powershell
dart run bin\phase4_bridge_probe.dart
```

**Coverage**:

| Section | Content |
|---|---|
| `[1]` | `BridgeHost.start()` |
| `[2]` | `lfBridgeVersion` / `lfBridgeIsInitialized` |
| `[3]` | `lfBridgeCreateData` / `WriteBuffer` / `ReadBuffer` / `GetSize` / `FreeData` |
| `[4]` | how `lfBridgeGetP2PUid` / `GetP2PName` behave on a **self-created handle** (should return 32 zero bytes + an empty string) |
| `[5]` | byte-exact round-trip of `lfBridgeWriteUid` / `ReadUid` |
| `[6]` | `lfBridgeFreeData` |
| `[7]` | `lfBridgeStatsJson` |
| `[8]` | `BridgeHost.stop()` |

**What it verifies**:

- **Dart FFI to C bridge type mapping** is correct (Pointer, Int32, Int64, Uint8*).
- **UID binary I/O** is lossless at the bridge layer (Dart FFI cannot pass a 32-byte struct directly, so the bridge
  must repack it).
- **P2P identity returns zeros on non-input handles**, as the LF contract specifies.

**Typical failures**:

- `[FAIL] create_data returns non-null` → the bridge DLL was not built correctly or is not loaded.
- `[FAIL] self-created handle yields 32 zero bytes` → the bridge's `lf_bridge_get_p2p_uid` implementation is wrong
  (it must not get the P2P-identity read restrictions wrong).

---

### phase5 — Framework layer probe

**File**: `bin/phase5_framework_test.dart`

**Target**: the typed option interface and argument validation of `Framework`.

**Run**:

```powershell
dart run bin\phase5_framework_test.dart
```

**Coverage**:

| Section | Content |
|---|---|
| `[1]` | full invocation of all 16 `setOpt*` calls (no exceptions) |
| `[2]` | typed getters return safe fallbacks (`false` / `0` / `""`) while **the bridge is not started** |
| `[3]` | UID length validation is **independent** of bridge state (31/33 bytes → `RangeError`) |
| `[4]` | while the bridge is not started, bridge methods throw `StateError` (with clear guidance) |
| `[5]` | `LingoFuseStatus.checkUid` length validation is **independent** of bridge state |
| `[6]` | `LfIo.tryReadJson` behaviour on three kinds of input (valid / invalid / empty) |
| `[7]` | `Framework.call` to a nonexistent target returns a size=0 handle; `tryCall` returns null |

**What it verifies**:

- **Argument validation is decoupled from runtime state** — even with the bridge down, a wrong UID length is rejected
  before any FFI call; that lets users validate their own arguments **without starting the framework**.
- **Typed getters are a "never throws" safe interface** — `getOptQuiet()` returns `false` when the bridge is down
  instead of throwing `StateError`.
- **The null contract of `tryCall`** — `tryCall` returns `null` on timeout / no target rather than a size=0 handle.

**Typical failures**:

- `[FAIL] all 16 typed setters completed` → one option name is misspelled (LF option names are
  case-insensitive but **spelling-sensitive**; unknown options are silently ignored, no error).
- `[FAIL] Framework.getOption returns "" when bridge is down` → the bridge-state probe has a bug.

---

### phase6 — Modern async API probe

**File**: `bin/phase6_async_probe.dart`

**Target**: the full async semantics of `Target` / `CallPromise` / `AsyncBridge`.

**Run**:

```powershell
dart run bin\phase6_async_probe.dart
```

**Coverage**:

| Section | Content | Why `P2PNameTarget` is used |
|---|---|---|
| `[1]` | Promise style (`.call(...).future`) | P2PName does no local lookup, avoiding a main-isolate deadlock |
| `[2]` | JSON style (`.callJson<T>(...).future`) | same as above |
| `[3]` | Callback style (`.callAsync(api, payload, cb)`) | same as above |
| `[4]` | short timeout (1 ms) → promise.abandoned=true | verifies the timeout state machine |
| `[5]` | missing API → empty bytes or timeout | verifies the error path |
| `[6]` | **sequenced async** (`Framework.p2pnameCallAsyncSequenced`) | verifies FIFO ordering |
| `[7]` | **UID length validation at the BridgeHost layer** (should throw `RangeError`) | verifies cross-layer exception-type consistency |

**What it verifies**:

- **The Promise / Callback / JSON shapes have consistent semantics** (the same request through different wrappers).
- **The timeout state machine is correct** — after a timeout the promise both settles and is marked `abandoned`, and
  the native request **is not cancelled** (a late callback is silently dropped).
- **Sequenced async really is sequenced** — section [6] fires 3 sequenced asyncs in a row and verifies that
  `seq=0/1/2` come back in the right order. **This is the key test against regression.**
- **Exception types are consistent across layers** — both `Framework._checkUidLength` and `BridgeHost._checkUidLength`
  throw `RangeError` (an early version of BridgeHost threw `ArgumentError`, so users catching
  `RangeError` missed one layer).

**Why `P2PNameTarget` is mandatory**:

The async routing of `AppTarget` / `UIDTarget` is **local-first**. When the Dart main isolate
issues an async call and the local process matches a local App, Pascal executes the handler
**synchronously on the caller's thread**. The handler is the bridge's Protocol A trampoline, which calls
`Dart_PostCObject` and then blocks waiting for Dart to answer — but the Dart main isolate is still stuck in the FFI call → **a two-way deadlock**.

`P2PNameTarget` always goes through server-side forwarding, and the server executes the handler on **an independent native thread**, never
occupying the Dart main isolate. **See the [Troubleshooting](../README_en.md#troubleshooting) section of the main `README.md` for details.**

**Typical failures**:

- The probe hangs at `[1] Promise style` without printing anything → most likely `AppTarget`
  or `UIDTarget` was used by mistake. **Check whether the target declaration was changed to something other than P2PName**.
- `[FAIL] sequenced async preserves FIFO order` → `Framework.p2pnameCallAsyncSequenced`
  has degraded into a non-sequenced call (a regression).

---

### phase7 — Three addressing schemes probe

**File**: `bin/phase7_addressing_probe.dart`

**Target**: the three addressing modes `AppTarget` / `UIDTarget` / `P2PNameTarget`.

**Run**:

```powershell
dart run bin\phase7_addressing_probe.dart
```

**Coverage**:

| Section | Content | Notes |
|---|---|---|
| `[1]` | `AppTarget` static properties | only `hashKey` / `describe` are verified; **no call is made** (to avoid a deadlock) |
| `[2]` | `UIDTarget` argument validation | 31 / 33 bytes → `RangeError`; non-hex → `RangeError` |
| `[3]` | `UIDTarget` dead route | call with a nonexistent UID and verify the promise settles rather than hanging forever |
| `[4]` | `P2PNameTarget` end-to-end call | the only addressing mode that actually makes a network call |
| `[5]` | cross-type `hashKey` non-collision | the `app:` / `uid:` / `p2p:` prefixes guarantee keys from different modes never collide |

**What it verifies**:

- **The three addressing schemes expose the same API surface** — `hashKey`, `describe` and the call shape are identical.
- **UID argument validation is strict** — no silent truncation or zero padding; a wrong length raises `RangeError` immediately.
- **A dead route does not hang forever** — calling a nonexistent UID settles the promise after the timeout,
  so the user is never stuck.
- **`hashKey` works as a Map / Set key** — different addressing modes are not mistaken for the same target.

**Why `[1]` makes no call**:

An async call through `AppTarget` deadlocks on the main isolate (as described above). The probe deliberately verifies only static properties,
leaving the real call to `[4] P2PNameTarget`. This is **deliberate design**, not an omission.

**Typical failures**:

- `[FAIL] dead-route settled` → the UID routing layer has a bug: it does not return an empty response for a nonexistent target.

---

### hello_async — teaching demo

**File**: `bin/hello_async.dart`

**Role**: **not a verification but a tutorial**. It demonstrates **five typical uses** of the modern async API.

**Run**:

```powershell
dart run bin\hello_async.dart
```

**Coverage**:

| Section | Scenario | Teaching point |
|---|---|---|
| `[1]` | **Erlang style** | business code goes straight into the `callAsync` callback, with no await break |
| `[2]` | **Promise style** | `await target.callJson<T>(...).future`, a clear chain |
| `[3]` | **Nested calls** | the first callback issues a second call; business logic chains naturally |
| `[4]` | **Timeout abandon** | a 1.5 s budget against a 3 s handler, `promise.abandoned=true` |
| `[5]` | **Server error** | a handler returning `{"error": "..."}` is correctly recognised |

**APIs registered on the server**:

```dart
app.registerCall('add', 'Add two integers', serverAdd);
app.registerCall('greet', 'Greet a name', serverGreet);
app.registerCall('getUser', 'Look up a user by id', serverGetUser);
app.registerCall('slow', 'Sleep for a given number of milliseconds', serverSlow);
```

**Client calls**:

```dart
final client = P2PNameTarget('hello_async_group');

// Erlang style
client.callAsync('greet', {'name': 'World'}, (result, error) {
  if (error != null) { print('[error] $error'); return; }
  final reply = decodeJsonResult(result);
  print('[reply] greeting = ${reply['greeting']}');
});

// Promise style
final sum = await client.callJson<Map<String, dynamic>>(
  'add',
  payload: {'a': 17, 'b': 25},
  timeoutMs: 5000,
).future;
print('[reply] ${sum['sum']}');
```

**What it demonstrates**:

- **Callback and business code in one place** — no jumping out to another function body.
- **`CallPromise` is thenable** — `await promise` and `await promise.future` are equivalent.
- **`callJson<T>` handles NUL framing automatically** — LingoFuse's string convention never leaks into user code.
- **Timeout is recoverable** — the `abandoned` flag lets the business layer tell "timeout" from "error".
- **Server business errors are separate from transport errors** — `{"error": "..."}` is recognised by the business layer,
  while the transport layer only delivers it.

**Sample output**:

```
=== Hello, Async ===

[boot] starting BridgeHost...
[boot] declaring P2P group "hello_async_group"...
[boot] creating AppHandle and registering APIs...
[boot] starting framework on "ipc:hello_async"...
[boot] waiting for the mesh to converge...
[boot] ready; client = p2pname("hello_async_group")

[1] Erlang feel: client.callAsync(api, payload, (result, error) { ... })
    [reply] greeting = Hello, World!

[2] Promise style: await client.callJson<Map>(...).future
    [reply] 42

[3] Nested call: inside the getUser callback, call greet(user.name)
    [getUser] id=2 name=Bob
    [greet]    Hello, Bob!

[4] Timeout: a 1.5s budget against a 3s handler
    [timeout] Async call to p2pname("hello_async_group") was abandoned...

[5] Error path: getUser(999) returns a JSON error
    [server-error] user 999 not found

[cleanup] stopping the framework...

=== done ===
```

---

## How to write your own example (PoC)

**The official probes verify "the mechanism"; your PoC verifies "the business".** They cannot replace each other.

### Minimal PoC template

Create `bin/my_poc.dart`:

```dart
// My LingoFuse PoC: <describe your scenario here>.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const String kAppName = 'MyPocService';
const String kGroupName = 'my_poc_group';
const String kEndpoint = 'ipc:my_poc';

// ---------------------------------------------------------------------------
// Server-side business logic
// ---------------------------------------------------------------------------

/// <describe what this handler does>
Uint8List onMyApi(Uint8List input) {
  final req = decodeJsonPayload(input) as Map<String, dynamic>;
  // ... your business logic ...
  return encodeJsonPayload({'result': 'ok'});
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  // --- 1. Boot ---
  await BridgeHost.start();
  Framework.setOptP2PName(kGroupName);

  final app = AppHandle(kAppName, 'My PoC');
  app.registerCall('myApi', 'My API', onMyApi);

  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService(kEndpoint, kEndpoint);
  Framework.prepareClient(kEndpoint, app: app);
  Framework.prepareDone();

  // Wait for the P2P name to propagate.
  await Future.delayed(const Duration(milliseconds: 2000));

  // --- 2. Exercise your scenario ---
  final target = P2PNameTarget(kGroupName);
  final reply = await target
      .callJson<Map<String, dynamic>>(
        'myApi',
        payload: {'input': 'hello'},
        timeoutMs: 5000,
      )
      .future;

  print('result: ${reply['result']}');

  // --- 3. Cleanup ---
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Object? decodeJsonPayload(Uint8List bytes) {
  final nulIndex = bytes.indexOf(0);
  final payload = nulIndex >= 0 ? bytes.sublist(0, nulIndex) : bytes;
  if (payload.isEmpty) return null;
  return jsonDecode(utf8.decode(payload));
}

Uint8List encodeJsonPayload(Object? value) {
  return Uint8List.fromList(utf8.encode(jsonEncode(value)));
}
```

Run:

```powershell
dart run bin\my_poc.dart
```

### PoC coverage checklist (advance in this order)

| Stage | Goal | Reference example |
|---|---|---|
| **1. Single process locally** | server and client in one process, P2PName routing | `bin/hello_async.dart` |
| **2. Two processes locally** | two separate Dart processes communicating over IPC | copy `my_poc.dart` into `my_server.dart` / `my_client.dart` and run them separately |
| **3. Cross-language** | Dart server + Python/C++ client (or the reverse) | the [Cross-language interop](../README_en.md#cross-language-interop) section of the main `README.md` |
| **4. Load balancing** | several Dart processes with the same P2PName, watching task distribution | start N `my_server.dart` instances and have the client fire 100 calls |
| **5. Long running** | let the server run 24 h, watching memory / threads | add memory snapshots to the `my_server.dart` main loop |

### Key gotchas (hit repeatedly when writing a PoC)

1. **`await BridgeHost.start()` must precede server registration** — otherwise `registerCall` throws `StateError`.
2. **Set the P2P group name before `prepareClient`** — `Framework.setOptP2PName` must come before
   the client connects, otherwise the first broadcast does not carry that group name.
3. **P2P name propagation takes ~2 seconds** — `client -> server -> broadcast` is two hops, so do not call too early.
4. **Async calls from the main isolate must use `P2PNameTarget`** — `AppTarget` /
   `UIDTarget` async calls deadlock.
5. **Synchronous calls (`Framework.call`) must run in a child isolate** — otherwise they block the Dart event
   loop and bridge callbacks cannot be delivered.
6. **Cleanup order must not be scrambled** — `app.dispose()` → `exitMainThread()` → `shutdown()` →
   `BridgeHost.stop()`.

---

## Project structure conventions

```
dart/
├── bin/          official probes + teaching demos + your PoCs
├── test/         unit tests + integration tests (mechanism-layer verification)
├── example/      this file (index and getting-started document)
├── native/       optional native library directory (see below)
└── tool/         auxiliary tool directory (see below)
```

### How `bin/` and `test/` divide the work

| Directory | Purpose | Typical content |
|---|---|---|
| `bin/` | **runnable examples/probes** | end-to-end verification, teaching demos, your PoCs |
| `test/` | **automated tests** | unit tests, integration tests, driven by `dart test` |

**The two do not overlap**: probes under `bin/` can be run by hand to read the output, while tests under `test/` are
executed in bulk by CI. The same logic may exist in both, but usually one form is chosen.

### What `native/` and `tool/` are for

These two directories are currently empty and serve the following **optional** scenarios:

- **`native/`**: when you need to ship a release that does not depend on the system `PATH`, copy
  `LingoFuse64.dll` / `z_ipc_64.dll` / `mimalloc64.dll` here and add `native/` as a candidate
  in the library search path of the loading code.
- **`tool/`**: for auxiliary scripts, for example:
  - packaging scripts (bundling one PoC from `bin/` with its dependencies into a standalone zip)
  - performance benchmark scripts
  - scripts that auto-generate PoC templates

**If you do not use these two directories**, they can safely be deleted. They never affect the main flow.

---

## Frequently asked questions

### `dart run bin/xxx.dart` reports `Could not load lf_dart_bridge.dll`

Handle it following the [Troubleshooting](../README_en.md#troubleshooting) section of the main `README.md`. The three most common causes:

1. `lf_dart_bridge.dll` was never built → see [Building the C bridge DLL](../README_en.md#building-the-c-bridge-dll)
2. the DLL is not on the search path → put it in the `dart/` root, `dart/bridge/`, or set an environment variable
3. a dependency DLL is missing → `z_ipc_64.dll` / `mimalloc64.dll` must be on PATH

### A probe hangs with no output

**99% of the time it is a deadlock**. Check:

- was `P2PNameTarget` changed to `AppTarget` / `UIDTarget`?
- was a synchronous call issued on the Dart main isolate?

See the header comment of `bin/phase6_async_probe.dart` about "why P2PName is mandatory".

### phase6 passes fewer checks than expected

The expectation in this file is **31 passes** (all of groups [1]–[7] plus `[Cleanup]`). If you get fewer than 31:

- check whether you are running an old version (the `phase6` before v2.0 final had only 24 checks).
- run `dart run bin\phase6_async_probe.dart` again after pulling the latest code.

### The `[4] Timeout` section of `hello_async` prints no timeout

- check whether the target machine is much slower than expected (a CI environment, say); 1.5 s may not cover a 3 s handler
  **plus** propagation delay. Temporarily raise `timeoutMs`, or shorten the sleep in `serverSlow`.
- if it never times out at all (it prints `[unexpected] the call resolved`), the handler finished faster than 1.5 s —
  most likely the busy-wait in `serverSlow` was optimised away; rebuild.

### The process does not exit after the probe finishes

- check whether the `[Cleanup]` section printed completely. If it hangs inside `BridgeHost.instance.stop()`,
  some native thread was not joined properly — that is a bug, please report it.
- if the exit code is `0` but the shell still says "running", it may be delayed DLL unloading on Windows; wait 1–2 seconds.

### I want to modify a probe to test my own scenario

Recommended approach:

1. **Copy** `bin/hello_async.dart` to `bin/my_poc.dart`.
2. Change `kAppName` / `kGroupName` / `kEndpoint` to your own names.
3. Replace the `serverXxx` functions with your own business logic.
4. Replace the `[1]`–`[5]` call sections with your own scenario.

**Do not modify the official probe files directly** — they get overwritten when the binding is upgraded. Use a separate filename.

---

*Document version: 1.0*
*Target LingoFuse Dart binding: v0.2.0 (v2.0 feature upgrade)*
*Last updated: 2026-10-15*
