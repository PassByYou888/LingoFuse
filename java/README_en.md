# The LingoFuse Java binding — knowledge base + README

> Chinese version: [README.md](README.md)

> **LingoFuse is the foundation for cross-language communication. This file is the complete
> knowledge base for the Java binding: both a getting-started README and the authoritative reference
> you consult day to day. After reading it you will be able to:**
>
> - wire the Java binding into any JDK 22+ project within 15 minutes;
> - make the right engineering choice among the three addressing modes (App name / UID / P2PName);
> - understand the byte-level contract of the wire protocol and guarantee byte-for-byte interop
>   with Pascal / Python / C++ / C# / JavaScript;
> - master the lifecycle model of the async subsystem and write production code with no leaks and
>   no deadlocks;
> - master real application patterns such as callbacks, side data, staggered retries and idempotency.

---

## Contents

**Part 1 — Getting started**
- [Chapter 1 — 30-second overview](#chapter-1--30-second-overview)
- [Chapter 2 — Environment setup](#chapter-2--environment-setup)
- [Chapter 3 — The first program](#chapter-3--the-first-program)

**Part 2 — Core concepts**
- [Chapter 4 — What LingoFuse is](#chapter-4--what-lingofuse-is)
- [Chapter 5 — The five abstractions](#chapter-5--the-five-abstractions)
- [Chapter 6 — The three addressing modes](#chapter-6--the-three-addressing-modes)

**Part 3 — Core mechanisms**
- [Chapter 7 — The wire protocol byte-level contract](#chapter-7--the-wire-protocol-byte-level-contract)
- [Chapter 8 — The side data injection mechanism](#chapter-8--the-side-data-injection-mechanism)
- [Chapter 9 — The callback execution model](#chapter-9--the-callback-execution-model)
- [Chapter 10 — The DataHandle lifecycle](#chapter-10--the-datashandle-lifecycle)
- [Chapter 11 — The async subsystem](#chapter-11--the-async-subsystem)

**Part 4 — API reference**
- [Chapter 12 — `DataHandle`](#chapter-12--datashandle)
- [Chapter 13 — `AppHandle`](#chapter-13--apphandle)
- [Chapter 14 — `Framework`](#chapter-14--framework)
- [Chapter 15 — `LfIo`](#chapter-15--lfio)
- [Chapter 16 — The `Target` family](#chapter-16--the-target-family)
- [Chapter 17 — `Options`](#chapter-17--options)
- [Chapter 18 — `P2PRegistry`](#chapter-18--p2pregistry)
- [Chapter 19 — `NetworkEvents`](#chapter-19--networkevents)
- [Chapter 20 — `LingoFuseStatus`](#chapter-20--lingofusestatus)
- [Chapter 21 — The exception hierarchy](#chapter-21--the-exception-hierarchy)

**Part 5 — Real application patterns**
- [Chapter 22 — The server pattern](#chapter-22--the-server-pattern)
- [Chapter 23 — The client pattern](#chapter-23--the-client-pattern)
- [Chapter 24 — The worker pool pattern](#chapter-24--the-worker-pool-pattern)
- [Chapter 25 — Identity awareness and authorization](#chapter-25--identity-awareness-and-authorization)
- [Chapter 26 — Cross-language integration](#chapter-26--cross-language-integration)
- [Chapter 27 — Lifecycle and graceful shutdown](#chapter-27--lifecycle-and-graceful-shutdown)

**Part 6 — Operations**
- [Chapter 28 — Troubleshooting](#chapter-28--troubleshooting)
- [Chapter 29 — Performance characteristics](#chapter-29--performance-characteristics)
- [Chapter 30 — Known limitations](#chapter-30--known-limitations)

**Appendices**
- [Appendix A — Complete API index](#appendix-a--complete-api-index)
- [Appendix B — Wire protocol byte-level examples](#appendix-b--wire-protocol-byte-level-examples)
- [Appendix C — Cross-language comparison](#appendix-c--cross-language-comparison)

---

# Chapter 1 — 30-second overview

**The LingoFuse Java binding** is a cross-language RPC client and server library built on the
**JDK 22+ FFM API (Project Panama)**. It **does not depend on JNI, JNA or JNR**, **writes no C glue
code**, and in pure Java loads `LingoFuse64.dll` (Windows) / `liblingofuse.so` (Linux) /
`liblingofuse.dylib` (macOS), exposing the same 59 C ABI symbols as Pascal / Python / C++ / C# /
JavaScript.

## 1.1 File layout

```
java/
├── pom.xml                          the Maven project configuration
├── build.ps1 / clean.ps1 / test.ps1  Windows helper scripts
├── run_test_ci.ps1 / .sh            CI reporting scripts
├── README.md                        this file
└── src/
    ├── main/java/lingofuse/         production code
    │   ├── DataHandle.java          the RAII data handle
    │   ├── AppHandle.java           the RAII application handle
    │   ├── Framework.java           the process-level facade
    │   ├── LfIo.java                uniform JSON / string I/O
    │   ├── Options.java             16 typed option pairs
    │   ├── P2PRegistry.java         process-level P2P namespace registration
    │   ├── NetworkEvents.java       global network events
    │   ├── LingoFuseStatus.java     the status queue + health checks
    │   ├── address/                 the three addressing modes (the Target family)
    │   ├── async/                   the async subsystem
    │   ├── errors/                  5 exception types
    │   ├── ffi/                     the FFM layer (users should not call it directly)
    │   └── demo/                    single-process / multi-process demos
    └── test/java/lingofuse/         145 unit tests
```

## 1.2 Dependency directions (strictly one-way)

```
LingoFuse.h (C ABI declarations, 59 symbols)
    │
    ├──> ffi/           FFM MethodHandle bindings
    │       │
    │       ├──> DataHandle / AppHandle / Framework  (the RAII layer)
    │       │       │
    │       │       ├──> address/     (the three addressing modes)
    │       │       ├──> async/       (the async subsystem)
    │       │       ├──> Options / P2PRegistry / NetworkEvents
    │       │       └──> LingoFuseStatus
    │       │
    │       └──> demo/    (the application layer)
    │
    └──> LingoFuse64.dll / liblingofuse.so / liblingofuse.dylib
```

**The only downward call chain.** User code should touch only `DataHandle`, `AppHandle`,
`Framework`, `LfIo`, `Options`, `P2PRegistry`, `NetworkEvents`, `LingoFuseStatus`, `address/` and
`async/`. `ffi/` is internal implementation; do not call it directly.

## 1.3 The seven iron rules

| # | Rule | Consequence of violating it |
|:-:|------|-----------|
| 1 | callbacks must use the `cdecl` convention (FFM guarantees it via `Linker.nativeLinker()`) | ABI mismatch |
| 2 | **never call `Framework.call` / `notify` / `prepareDone` / `shutdown` inside a callback** | deadlock |
| 3 | **all JSON / string I/O must go through `LfIo`** | frame misalignment, cross-language failure |
| 4 | cleanup order: `NetworkEvents.clear` → `exitMainThread` → `app.close` → `shutdown` | dangling pointers, crashes |
| 5 | one physical address may host only one client unless `Overlap_Connection` is enabled | silently dropped connections |
| 6 | **do not call any LF_* function before `LF_LoadLibrary`** (in Java `LibraryLoader` guarantees it) | null-pointer dereference |
| 7 | **`getP2pUid` / `getP2pName` are valid only on a callback's `input` handle** | you read 0 / an empty string |

## 1.4 Key defaults

| Item | Value |
|------|---:|
| number of exported C ABI symbols | 59 |
| default TCP port | 9898 |
| DataHandle idle reclamation threshold | 10 minutes |
| reclamation scan interval | 5 seconds |
| `prepareDone` initialization timeout | 30 seconds |
| `Wait_Connection_Timeout` default | 30000 ms |
| `Overlap_Connection` default | false |
| `Wait_Connection_ReadyOk` default | true |
| `Fixed_Sequenced_Time` default | 20000 ms |
| lifetime of a `LF_Generate_AppName` pointer | ~5 seconds |
| lifetime of a `LF_Get_P2P_UID` pointer | ~5 seconds |
| lifetime of a `LF_GetOption` pointer | ~5 seconds |
| grace period after an async op times out | 60 seconds |
| deferred release of async stubs (ArenaReaper) | 30 seconds |
| total number of tests | 145 |

---

# Chapter 2 — Environment setup

## 2.1 Required components

| Component | Minimum version | Recommended version |
|------|:--------:|:--------:|
| **JDK** | **22** | **25 LTS** |
| **Maven** | 3.8 | 3.9 / 3.10 |
| **Operating system** | Windows 10+ / Linux / macOS | any 64-bit |
| **CPU** | x86_64 / aarch64 | — |

**Not needed**: a C/C++ compiler, CMake, Ninja, Python, Node.js, Visual Studio.

## 2.2 Installing JDK 25

### Windows

```powershell
winget install EclipseAdoptium.Temurin.25.JDK
```

Or download the msi from the Adoptium site and tick **Set JAVA_HOME** and **Add to PATH** during
installation.

### Linux (Ubuntu / Debian)

```bash
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | \
    sudo gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg

echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] \
https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/adoptium.list

sudo apt update
sudo apt install temurin-25-jdk
```

### macOS

```bash
brew install --cask temurin@25
```

### Verify

```bash
java -version
```

The expected output is `openjdk version "25.x.x"`. If it shows 8 / 11 / 17 / 21, fix `JAVA_HOME`.

## 2.3 Installing Maven

```powershell
# Windows
winget install Apache.Maven

# Linux
sudo apt install maven

# macOS
brew install maven
```

Verify:

```bash
mvn -version
```

`Java version` must be `22.x` or higher.

## 2.4 Placing the native library

The Java binding **does not include** `LingoFuse64.dll` or other native shared libraries. That
library must be built separately (from the Pascal / C++ sources) and placed where the operating
system loader can find it.

### The expected file names

| Platform | Main library | Dependencies |
|------|------|------|
| Windows 64-bit | `LingoFuse64.dll` | `z_ipc_64.dll`, `mimalloc64.dll` |
| Windows 32-bit | `LingoFuse32.dll` | `z_ipc_32.dll` |
| Linux / BSD | `liblingofuse.so` | `libz_ipc.so` |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` |

### The search order

`LibraryLoader` tries, in order:

1. **the system loader path** (Windows `PATH` / Linux `LD_LIBRARY_PATH` / macOS
   `DYLD_LIBRARY_PATH`)
2. **every directory in `java.library.path`**
3. **the current working directory**

### How to place them

**Recommended (the simplest)**: copy the native libraries into the project root `java/`:

```powershell
Copy-Item "D:\CoreLibrary\LingoFuse\Binary\*.dll" .
```

**Or** add `Binary/` to `PATH`:

```powershell
$env:PATH += ";D:\CoreLibrary\LingoFuse\Binary"
```

**Linux / macOS**:

```bash
sudo cp liblingofuse.so libz_ipc.so /usr/local/lib/
sudo ldconfig
```

---

# Chapter 3 — The first program

## 3.1 A minimal runnable server (Calculator)

```java
import lingofuse.AppHandle;
import lingofuse.Framework;
import lingofuse.LingoFuseStatus;
import lingofuse.NetworkEvents;

public final class CalculatorServer {
    public static void main(String[] args) throws Exception {
        AppHandle app = null;
        boolean started = false;

        try {
            // 1. create the application and register the Call API
            app = new AppHandle("Calculator", "Demo calculator");
            app.registerCall("add", "Add two int32", (input, output) -> {
                int a = input.readInt32();
                int b = input.readInt32();
                output.writeInt32(a + b);
            });

            // 2. network preparation
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
            Framework.setOption("Wait_Connection_Timeout", "10000");
            Framework.resetPrepare();
            Framework.prepareService("ipc:calc", "ipc:calc");
            Framework.prepareClient("ipc:calc", app);

            // 3. start
            if (Framework.prepareDone() != 1
                    && !LingoFuseStatus.checkMainThread()) {
                throw new IllegalStateException("startup failed");
            }
            started = true;

            System.out.println("Ready. Press Enter to stop.");
            System.in.read();

        } finally {
            // 4. clean up (strict order)
            try { NetworkEvents.clear(); } catch (Throwable ignored) {}
            try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
            try { if (app != null) app.close(); } catch (Throwable ignored) {}
            try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
        }
    }
}
```

## 3.2 A minimal runnable client

```java
import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.LingoFuseStatus;

public final class CalculatorClient {
    public static void main(String[] args) {
        boolean started = false;
        try {
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.resetPrepare();
            Framework.prepareClient("ipc:calc", null);

            if (Framework.prepareDone() != 1
                    && !LingoFuseStatus.checkMainThread()) {
                System.err.println("startup failed");
                return;
            }
            started = true;

            try (DataHandle req = new DataHandle("add")) {
                req.writeInt32(5);
                req.writeInt32(7);

                try (DataHandle resp = Framework.call(
                        "Calculator", req, 3000L)) {

                    if (resp.size() == 0) {
                        System.out.println("timeout or target not found");
                        return;
                    }
                    System.out.println("5 + 7 = " + resp.readInt32());
                }
            }
        } finally {
            try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
            try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
        }
    }
}
```

## 3.3 Compiling and running

```powershell
cd D:\CoreLibrary\LingoFuse\java
.\build.ps1
java --enable-native-access=ALL-UNNAMED `
     -cp target\classes CalculatorServer
```

**Note that JDK 24+ requires `--enable-native-access=ALL-UNNAMED`** (`pom.xml` already configures
it for the tests and the exec plugin).

## 3.4 Running the full test suite once

```powershell
.\test.ps1
```

The expected output:

```
[INFO] Tests run: 145, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

---

# Chapter 4 — What LingoFuse is

## 4.1 A one-sentence definition

> **LingoFuse is a cross-language, cross-process, cross-machine RPC framework. Any language that
> binds its 59 C ABI symbols can interoperate with every other language. The Java binding achieves
> this with FFM, without any C glue.**

## 4.2 Why cross-language matters

Modern systems are usually built from components in several languages: Python for AI / data
processing, C++ for high-performance computing, C# for business logic, Java for data pipelines,
Pascal for low-level services, JS for the front end. Communication between them usually goes through
HTTP / gRPC / a message queue.

LingoFuse's goal is to provide a **unified, low-latency, cross-language inter-process
communication layer**:

- **define an RPC once, and every language interoperates**;
- **the wire protocol is byte-for-byte aligned**, so there is no adaptation cost;
- **service discovery, load balancing and async callbacks are all built in**.

## 4.3 How it differs from other RPC frameworks

| Feature | LingoFuse | gRPC | Thrift | HTTP+JSON |
|------|-----------|------|--------|-----------|
| cross-language | 10+ languages | 10+ languages | 10+ languages | everything |
| interface definition | reflective, no IDL | requires `.proto` | requires `.thrift` | none |
| serialization | user-defined (JSON recommended) | Protobuf | Binary | JSON |
| service discovery | built in | needs consul/etcd | needs ZooKeeper | none |
| load balancing | built in | needs a sidecar | needs a sidecar | none |
| async | built in | needs an async stub | needs an async stub | needs an extra library |
| learning curve | low (no IDL) | medium | medium | very low |

## 4.4 A key architectural decision: the wire protocol belongs to the user

LingoFuse **does not negotiate an interface**. It provides only:

- a binary buffer (`DataHandle`);
- a set of addressing keys (App name / UID / P2PName);
- a set of call semantics (Call / Notify / Sequenced_Notify).

**What goes into the payload is up to the user**. The recommended practice is a JSON string
(`LfIo.writeJson` / `readJson`), but LingoFuse **will not force you**. This is the biggest source of
its flexibility, and also where it is easiest to misuse — both ends must agree on the same payload
format.

---

# Chapter 5 — The five abstractions

Understanding LingoFuse's five core abstractions is the prerequisite for understanding every
mechanism that follows.

```
┌──────────────────────────────────────────────────────────┐
│  DataHnd      binary buffer + API name                    │
│  AppHnd       API container (a logical "service")         │
│  Service      listening endpoint (the beacon)             │
│  Client       a node connected to a Service               │
│  Mesh (C4)    service discovery + routing + load balance  │
└──────────────────────────────────────────────────────────┘
```

| Abstraction | Underlying type | Lifetime | Owner |
|------|---------|---------|------|
| **DataHnd** | the `TLF_Data` record | reclaimed after 10 minutes idle (auto-recycled kind only) | the global handle pool |
| **AppHnd** | the `TLF_App` object | until `shutdown()` | the global app pool |
| **Service** | a C4 physical service | until `shutdown()` | internal |
| **Client** | a C4 physical client | until `shutdown()` | internal |
| **MESH** | the C4 service mesh | a process-level singleton | internal |

Users touch `DataHandle` and `AppHandle` directly. Service / Client / MESH are internal; you only
influence them through `prepareService` / `prepareClient` / `prepareDone`.

## 5.1 The roles of Service and Client

- **Service**: the listening endpoint. It maintains the registry (who exposes which APIs) and
  broadcasts it to all clients.
- **Client**: a node connected to a Service. It can expose its own Apps / APIs, or be a pure
  consumer.
- **A process can be both a Service and a Client at once** (self-connected).

| Role | `prepareService` | `prepareClient` | Bind an App |
|------|:---:|:---:|:---:|
| pure beacon | ✅ | ✅ (self-connect) | ❌ |
| compute node | ❌ | ✅ | ✅ |
| pure consumer | ❌ | ✅ | ❌ |
| standalone | ✅ | ✅ | ✅ |

## 5.2 The five capabilities the C4 mesh provides

1. **service discovery**: when a Client connects it pushes its App / API information to the Service.
2. **broadcast**: the Service distributes the registry to all Clients.
3. **routing**: `Framework.call` consults its local cache and picks a target Client.
4. **load balancing**: when several Clients provide an App with the same name, the one least
   recently used is chosen by `Cycle_Time_Anchor`.
5. **local-first**: when the target App lives in this process, the call is served locally and never
   touches the network.

## 5.3 The service discovery sequence

```
Worker                  Service                  Caller
  │                        │                        │
  ├── prepareClient(addr) ─►                       │
  │                        ├── record App/API       │
  │                        ├── broadcast "demo online" ─►│
  │                        │                        │
  │                        │◄── call("demo","add") ─┤
  │                        ├── look up the cache, pick a target │
  │◄── forward the request ┤                        │
  ├── run the callback      │                        │
  ├── return the result ──►├── return the result ───►│
```

**Three core corollaries**:

1. **`checkApi` lags by about 3 seconds** — it reads the locally cached broadcast view.
2. **several workers are load-balanced automatically** — chosen by `Cycle_Time_Anchor`.
3. **`Framework.call` can reach an App in this same process** — local-first.

---

# Chapter 6 — The three addressing modes

LingoFuse's C ABI supports three **completely independent** addressing keys. In Java each has its
own `Target` class, sharing a fully equivalent API.

## 6.1 When to use which

| Addressing mode | Index key | Routing semantics | Local-first? | Load balancing? | Typical use |
|---------|--------|---------|:---------:|:---------:|---------|
| **App name** | a UTF-8 string | locate the "logical App" | ✅ yes | ❌ | fixed services (one App, one responsibility) |
| **UID** | a 32-byte session identifier | locate a "specific client" | ✅ yes | ❌ | targeting a specific client (e.g. calling back after whoami) |
| **P2PName** | a user-defined group name | locate "any member of the group" | ❌ no | ✅ server side | homogeneous service clusters (worker pools) |

## 6.2 App-name addressing

**The most common pattern**. When you have a stable logical service (a "calculator", an
"authentication service", a "log service"), use App-name addressing.

```java
import lingofuse.address.AppTarget;
import lingofuse.DataHandle;

AppTarget target = new AppTarget("Calculator");

try (DataHandle req = new DataHandle("add")) {
    req.writeInt32(5);
    req.writeInt32(7);
    try (DataHandle resp = target.call(req, 3000)) {
        System.out.println("5 + 7 = " + resp.readInt32());
    }
}
```

**Key properties**:

- **local-first**: if the calling process already has an App named `Calculator` with `add`
  registered, the request is served locally and never goes over the network.
- **no load balancing**: if several processes all register `Calculator`, routing is
  **nondeterministic** (it may land on any of them).
- **suited to**: single-instance services, or scenarios where "any instance will do".

## 6.3 UID addressing

When you need to **target one specific client**, use a UID.

```java
import lingofuse.address.UIDTarget;

byte[] uid = acquireClientUid();          // 32 bytes, from side data or whoami
UIDTarget target = new UIDTarget(uid);

try (DataHandle req = new DataHandle("echo")) {
    req.writeString("hello via UID");
    try (DataHandle resp = target.call(req, 3000)) {
        System.out.println(resp.readString());
    }
}
```

**Key properties**:

- **local-first**: the same as App-name addressing.
- **the UID changes on reconnect**: every TunnelLink generates a new UID. Code that caches a UID
  must re-probe after reconnecting.
- **suited to**: stateful operations on a particular client (session management, targeted
  notifications).

**Where does a UID come from?** The server assigns the client its own UID, which can be discovered
through the **whoami pattern**:

```java
// the server registers a whoami API
P2PRegistry.registerCall("whoami", "echo caller identity",
    (in, out) -> {
        byte[] callerUid = in.getP2pUid();       // side data
        String callerName = in.getP2pName();     // side data
        LfIo.writeJson(out, Map.of(
                "uid_hex", toHex(callerUid),
                "p2p_name", callerName));
    });

// the client calls whoami to learn its own UID
try (DataHandle req = new DataHandle("whoami")) {
    try (DataHandle resp = new UIDTarget(broadcastAddr).call(req, 3000)) {
        Map<String, Object> me = LfIo.readJson(resp, Map.class);
        String uidHex = (String) me.get("uid_hex");
        // cache uidHex for later UID-targeted addressing
    }
}
```

## 6.4 P2PName addressing

Use P2PName when you have a group of **homogeneous workers** and want the request distributed to
any one of them (with the server side doing the load balancing).

```java
import lingofuse.address.P2PNameTarget;
import lingofuse.Options;

// 1. the worker declares which group it belongs to (each worker runs this once)
Options.setP2pName("worker_group");

// 2. the caller addresses by group name
P2PNameTarget target = new P2PNameTarget("worker_group");

try (DataHandle req = new DataHandle("process")) {
    LfIo.writeJson(req, Map.of("task", "batch-42"));
    try (DataHandle resp = target.call(req, 5000)) {
        Map<String, Object> result = LfIo.readJson(resp, Map.class);
    }
}
```

**Key properties**:

- **no local-first**: even if the caller is itself in the group, the request is **forwarded to the
  server**, which decides the target client.
- **server-side load balancing**: `Cycle_Anchor` selection by default, with `Fixed_Sequenced_Time`
  controlling the stickiness window.
- **suited to**: horizontal scaling of stateless compute tasks.

## 6.5 The decision tree for choosing a mode

```
What is the target you need to call?
│
├─ a fixed logical service (such as "Calculator")
│   └─ use AppTarget
│
├─ one specific client (identified by a UID)
│   └─ use UIDTarget
│
└─ any one of a group of homogeneous workers
    └─ use P2PNameTarget
```

## 6.6 The common API of the Target family

All three Targets inherit from `lingofuse.address.Target` and share a fully equivalent API:

| Method | Notes |
|------|------|
| `call(param)` / `call(param, timeoutMs)` | synchronous call |
| `callJson(param, Type)` / `callJson(param, Type, timeoutMs)` | synchronous call + JSON deserialization |
| `notify(param)` | one-way notification |
| `sequencedNotify(param)` | FIFO one-way notification |
| `asyncCall(param, handler)` | async callback (raw handle) |
| `asyncCallJson(param, Type, handler)` | async callback (typed) |
| `asyncSequencedCall(...)` / `asyncSequencedCallJson(...)` | FIFO async callback |
| `callFuture(param, Type)` / `callFuture(param, Type, timeoutMs)` | returns a `CallFuture<T>` |
| `sequencedCallFuture(...)` | the FIFO Future variant |
| `describe()` | `"app(X)"` / `"uid(hex)"` / `"p2pname(g)"` |

**Target value semantics**: all three Targets implement `equals` / `hashCode` / `toString`, so they
can be used as Map keys.

---

# Chapter 7 — The wire protocol byte-level contract

> **This chapter is the heart of cross-language interop. Any binding that misreads this chapter will
> fail to interoperate.**

## 7.1 The string frame: UTF-8 + a single NUL

On the wire a LingoFuse string is always:

```
[the UTF-8 encoded byte sequence] [0x00]
```

- **writing**: `LfIo.writeString(hnd, "abc")` produces `61 62 63 00`.
- **reading**: `LfIo.readString(hnd)` scans from the current position, stops at `0x00`, and returns
  the bytes before it (decoded as UTF-8).
- **fault-tolerant reading**: if the scan reaches the end of the buffer without finding `0x00`, it
  returns the whole remainder and moves the cursor to `size + 1` (the library implicitly grows the
  buffer by one byte). **This exists to accommodate non-standard producers such as HTTP bridges**.

## 7.2 Integer encoding: little-endian

| Type | Bytes | Example |
|------|:------:|------|
| `int8` | 1 | `-1` → `FF` |
| `uint8` | 1 | `255` → `FF` |
| `int16` | 2 | `-1` → `FF FF` |
| `uint16` | 2 | `65535` → `FF FF` |
| `int32` | 4 | `0x01020304` → `04 03 02 01` |
| `uint32` | 4 | `0xFFFFFFFF` → `FF FF FF FF` |
| `int64` | 8 | `0x0102030405060708` → `08 07 06 05 04 03 02 01` |
| `uint64` | 8 | the same as above |

## 7.3 Floating-point encoding: IEEE 754 little-endian

| Type | Bytes | Example |
|------|:------:|------|
| `float` | 4 | `3.14f` → `C3 F5 48 40` |
| `double` | 8 | `3.14` → `1F 85 EB 51 B8 1E 09 40` |

## 7.4 The JSON serialization policy

**The only entry point**: `LfIo.dumpsJson(obj)` / `LfIo.writeJson(hnd, obj)`.

**The policy**:

```java
new ObjectMapper().writeValueAsString(obj)
```

Jackson's default behaviour:

- **compact output**: no indentation, no newlines.
- **`ensure_ascii=false`**: non-ASCII characters (Chinese, emoji) are emitted as literal UTF-8 and
  **never produce `\uXXXX` escapes**.
- **strict types**: a non-serializable type raises an exception (**note**: this differs from Python's
  `default=str` — Python degrades an unserializable object to `str(obj)`, Java throws).

## 7.5 The byte-level verification table

| Payload | The bytes every language produces |
|------|-------------------|
| `{"a":1}` | `7B 22 61 22 3A 31 7D 00` |
| `int32 = 0x01020304` | `04 03 02 01` |
| `uint16 = 0xAABB` | `BB AA` |
| `"你好"` | `E4 BD A0 E5 A5 BD 00` |
| `"🌍"` | `F0 9F 8C 8D 00` |

## 7.6 The wire layout of a complete Call request

A single `LF_Call(appName, param, timeoutMs)` sends the following on the wire:

```
[4-byte length LE][appName UTF-8 + NUL]
[the param API name UTF-8 + NUL]
[8-byte param buffer size LE][param buffer bytes]
```

**Note**: `appName` and `timeoutMs` **never go on the wire** (they are used for local routing
decisions); only the `param` API name and the buffer content travel over the network.

The `input` handle the server receives is already at the **correct cursor position** (so `readInt32`
works immediately). On the way back:

```
[4-byte length LE][the output API name UTF-8 + NUL]
[8-byte output buffer size LE][output buffer bytes]
```

The `DataHandle` the caller receives also has its cursor at 0.

## 7.7 The cross-language invariants checklist

**The parts every language binding must agree on byte for byte**:

| Contract | Value / semantics |
|------|------------|
| string frame | UTF-8 bytes + a single `0x00` |
| integer encoding | little-endian |
| floating-point encoding | IEEE 754 little-endian |
| JSON policy | compact, `ensure_ascii=false`, no `\uXXXX` |
| UID parameter representation | a 32-byte array, passed by value in cdecl (which degrades to a pointer) |
| UID return representation | **a pointer** (`PP2P_UID___`), not a value |
| validity of the `LF_Get_P2P_UID` return buffer | ~5 seconds |
| `LF_Call` timeout semantics | returns a **size=0 handle**, not NULL |
| ownership of `LF_Async_Call`'s `Result_` | owned by the framework, released when the callback returns |
| callback threading model | native worker threads |
| `LF_PrepareDone` returning 1 once | the second call returns 0 (not a failure) |

**The Java-private parts** (they do not affect the wire, and other languages need no equivalent):

| Java-private mechanism | Scope |
|--------------|---------|
| `ReentrantReadWriteLock` | inside the Java process |
| `ArenaReaper` | inside the Java process |
| `AsyncBridge` / `AsyncOp` / `CallFuture` | inside the Java process |
| the stderr sink of `reportCallbackError` | inside the Java process |
| the `MAX_C_STRING_LENGTH = 1MB` safety bound | local read defence |
| zeroing the UID arena before close | inside the Java process |
| the JVM shutdown hook | process exit timing |

**The red line**: changes to Java-private mechanisms **must not alter the byte sequence, the
parameter order or the semantics on the wire**. Every change made in the previous round of P0/P1
fixes falls into the Java-private category.

---

# Chapter 8 — The side data injection mechanism

## 8.1 What side data is

**On every remote request the sender's transport layer automatically injects two identity fields at
the head of the payload**:

| Field | Meaning | Length |
|------|------|------|
| `FromUID` | the sender's 32-byte session UID | 32 bytes |
| `FromP2PName` | the P2P group name the sender declared | UTF-8 + NUL |

On the Pascal side the injection is done by `TC40_LF_Client.Send_*` →
`TMemory_Param_Tool.Rebuild_UID_and_P2PName`.

**That means the receiver can read these two fields straight from the callback's INPUT handle, with
no request parameter and no extra agreement.**

## 8.2 Reading them in Java

```java
app.registerCall("whoami", "echo caller identity", (in, out) -> {
    byte[] senderUid = in.getP2pUid();      // 32 bytes, never null
    String senderName = in.getP2pName();    // a UTF-8 string, possibly ""
    LfIo.writeJson(out, Map.of(
            "uid_hex", toHex(senderUid),
            "p2p_name", senderName));
});
```

`DataHandle.getP2pUid()` immediately **copies the 32 bytes into a Java `byte[]`**, so the caller
gets a Java object entirely detached from the C buffer. You can hold it, pass it across threads, and
never release it manually.

## 8.3 It only works on an INPUT handle

This is the most common mistake. Side data is **written by the sender**; it is not an attribute of
the handle.

| Location | `getP2pUid()` / `getP2pName()` |
|------|:------------------------------:|
| the `Input` of `On_Call(Input, Output)` | ✅ valid |
| the `Input` of `On_Notify(Input)` | ✅ valid |
| the `Input` of an `AppHandle.localCall(param)` callback | ✅ valid |
| the `Result_` of `OnResult(Result_)` (async callback) | ❌ all 0 / empty string |
| `new DataHandle("api")` (self-created) | ❌ all 0 / empty string |

**The consequence of violating it**: you silently get an all-zero UID / an empty string. The C side
logs a warning.

## 8.4 How it differs from `Options.getP2pName()`

The two methods share a name and **have nothing to do with each other semantically**:

| Method | What it reads | When it is valid |
|------|-------|---------|
| `Options.getP2pName()` | the group name **this process** declared (local configuration) | at any time |
| `DataHandle.getP2pName()` | the **sender's** group name (side data) | only on a callback's Input |

**A mnemonic**:

- `Options.*` is "me" — this process's configuration.
- `DataHandle.getP2p*` is "them" — the peer's identity.

## 8.5 Typical uses

1. **admission control / authorization**: compare against a UID allow-list.
2. **audit logging**: record the caller UID as hex.
3. **session state**: keep a per-caller state dictionary keyed by UID.
4. **multi-tenancy**: use the P2P group name as the tenant id.
5. **whoami probes**: let a client learn its own UID.

## 8.6 The UID lifetime

**A UID changes on reconnect**. Every `TunnelLink` generates a new UID.

- **code that caches a UID must re-probe after reconnecting**.
- **do not** treat a UID as a permanent credential.
- **recommended**: re-probe with the whoami pattern every time a connection is established.

---

# Chapter 9 — The callback execution model

## 9.1 Callbacks run on native worker threads

**This is the part of the framework that is easiest to get wrong.**

Every callback registered through `registerCall` / `registerNotify` / `asyncCall*` runs on a
**native worker thread** of **LingoFuse's internal thread pool** — **not** the calling thread and
**not** the main thread.

## 9.2 The five iron rules

| # | Rule | Consequence of violating it |
|:-:|------|-----------|
| 1 | **do not block**: no IO, no `Thread.sleep`, no waiting on locks inside a callback | thread-pool starvation |
| 2 | **do not call blocking LingoFuse functions**: `Framework.call` / `notify` / `prepareDone` / `shutdown` | **deadlock** |
| 3 | **do not touch the UI**: when you need to update it, hand off via `CompletableFuture` / `ExecutorService` | random crashes |
| 4 | **do not retain input/output handles**: they are valid only for the duration of this callback | use-after-free |
| 5 | **do not throw**: the binding already try/catches, but catching yourself is better | the exception is swallowed and cannot be investigated |

## 9.3 Why `Framework.call` inside a callback deadlocks

- the callback runs on a C4 worker thread.
- the worker thread holds an internal lock(used for callback dispatch).
- `Framework.call` needs the simulated main thread to dispatch the response.
- the simulated main thread waits on the same internal lock.
- **self-deadlock**.

**The right approach**: when you need to issue a new request, copy the `DataHandle` data out and
submit it to your own thread pool / `CompletableFuture`.

## 9.4 Exception isolation

The Java binding wraps callbacks in `try/catch(Throwable)`. **Any exception that escapes into the C
stack crashes the process**, so this step is required.

A caught exception is reported through `Framework.reportCallbackError`:

```java
Framework.setCallbackErrorHandler((source, exception) -> {
    // your logging pipeline
    logger.error("[LF] callback error in {}: {}",
                 source, exception.getMessage(), exception);
});
```

**Note**: by default it also goes to stderr. To disable stderr:

```java
Framework.setCallbackErrorStderrFallback(false);
```

## 9.5 The construction semantics of the output handle

**Writing to `output` = returning a result**. When the callback calls `writeXxx` on `output`, the
framework marshals the bytes of `output` back to the caller.

**An empty `output`**: the callback writes nothing and the caller receives a **size=0 handle**.

**Note**: `input` is **read-only** and `output` is **write-only**. Writing to `input` or reading
from `output` inside a callback is **undefined behaviour**.

---

# Chapter 10 — The DataHandle lifecycle

## 10.1 The two kinds of handle

| Kind | How it is created | Joins the idle pool | Reclaimed when | How it is released |
|------|---------|:---------:|---------|---------|
| **Auto-recycled** | `new DataHandle("api")` | ✅ | after 10 minutes idle | `close()` only marks it; the next pool scan (≤5s) actually releases it |
| **Permanent** | `DataHandle.createPermanent("api")` | ❌ | never automatically | `close()` releases it immediately and synchronously |

**How to choose**:

- **use auto-recycled by default**: short-lived, single-use.
- **use Permanent for**: handles held across the whole process lifetime (cached templates, global
  registries).

## 10.2 Ownership and borrowing

```java
// owned (you created it, so you must release it)
try (DataHandle h = new DataHandle("api")) {
    // ...
}  // closed automatically

// borrowed (the input/output a callback receives; not yours to manage)
DataHandle inputHandle = DataHandle.fromRaw(raw, false);
// close() is a no-op; the framework releases it when the callback returns
```

**`close()` on a borrowed handle is a safe no-op**: it does not change the wrapper state and you can
keep reading. That tolerates an accidental `close()` inside a callback.

## 10.3 Idle reclamation

- **scan period**: 5 seconds (adjustable through `Options.setDataHandlePoolScanInterval`).
- **reclamation threshold**: 10 minutes (adjustable through `Options.setDataHandleIdleTimeout`).
- **any access** (`getSize` / `getPos` / `read*` / `write*`) refreshes the idle timestamp.
- **while a remote call is in flight**: the input handle's `calling___` counter is > 0, so it is
  exempt from reclamation.

**Do not rely on automatic reclamation**. Under heavy load, auto-recycled handles can accumulate
faster than they are reclaimed. Production code should call `close()` explicitly.

## 10.4 The threading model

The Java binding adds a `ReentrantReadWriteLock` inside `DataHandle`:

- **write operations** (`writeXxx`, `setPosition`, `setSize`, `close`): the write lock.
- **read operations** (`position`, `size`, `getBufferPointer`): the read lock.

This **fixes**:

- a double release caused by two threads calling `close()` at the same time.
- a use-after-free when a reader holds a pointer and a writer triggers a realloc.

This **cannot fix**:

- concurrent writes across processes (already disallowed by the LingoFuse ABI).
- logical semantic races (your application code must handle those).

**Key point**: this lock is **Java-private** and **does not intrude on the wire**. Other language
bindings need no equivalent mechanism and should not have one.

## 10.5 Handle size and position

- **initial size**: 0.
- **after `writeXxx`**: the cursor moves to the end.
- **after `readXxx`**: the cursor advances.
- **`setPosition(N)`**: moves the cursor; beyond the size it **implicitly grows the buffer**.
- **`setSize(N)`**: resizes; the new space is uninitialized.

## 10.6 Correct usage of permanent handles

```java
// create once at process start
DataHandle template = DataHandle.createPermanent("my_api");
LfIo.writeJson(template, Map.of("type", "template"));

// reuse it throughout the process lifetime
// ...

// release it explicitly before exiting
template.close();
```

**Note**:

- `LF_ExitMainThread` **flushes the entire handle pool, including permanent handles**.
- any handle is invalid afterwards.
- so do not use any `DataHandle` after `LF_ExitMainThread`.


# Chapter 11 — The async subsystem

## 11.1 Why an async subsystem is needed

The C ABI's `LF_Async_Call` is a bare function pointer plus `void* user_data`. Using it directly has
three pitfalls:

1. **the callback may still fire after a timeout** — the C side does not cancel the request. If you
   release the stub on timeout, the C-side callback lands in freed memory.
2. **a dispatch failure leaks** — if the C side returns 0 (not queued), the callback never fires and
   the stub leaks forever.
3. **a double-release race** — the caller thread (timeout path) and the C worker thread (callback
   path) may release the same op at the same time.

**The `AsyncBridge` system solves all three.**

## 11.2 The state machine

```
         ┌─────────────┐
         │   PENDING   │  ← created, waiting for the C-side callback
         └──────┬──────┘
                │
    ┌───────────┼───────────┐
    │           │           │
callback fires  timeout    dispatch failure
    │           │           │
    ▼           ▼           ▼
┌────────┐ ┌──────────┐ ┌──────────┐
│ FIRED  │ │ABANDONED │ │NOT_QUEUED│
└────────┘ └────┬─────┘ └──────────┘
                │
         a late callback
                │
                ▼
            ┌────────┐
            │ FIRED  │
            └────────┘
```

- **FIRED**: the C-side callback has finished its Java-side work. The stub is released immediately.
- **ABANDONED**: the timeout fired first. The op stays alive for `graceSeconds` (60s by default) so
  that a late callback can still find a valid Java object. It is released when the grace period
  expires.
- **NOT_QUEUED**: the dispatch failed. Released immediately.

## 11.3 The three usage styles

### 11.3.1 Typed callback (recommended)

```java
try (DataHandle req = new DataHandle("api")) {
    LfIo.writeJson(req, Map.of("query", "..."));

    Framework.asyncCallJson("MyApp", req, Person.class, (person, error) -> {
        if (error != null) {
            log.warn("async call failed", error);
            return;
        }
        System.out.println("got " + person.name);
    });
}
```

**Characteristics**:

- what the user sees is a plain lambda `(T value, Throwable error) -> { ... }`.
- **no stub, no Arena, no handle lifecycle, no user_data**.
- the framework deserializes the result automatically.

### 11.3.2 Raw handle callback

```java
Framework.asyncCall("MyApp", req, (DataHandle result, Throwable error) -> {
    if (error != null) return;
    String value = LfIo.readString(result);  // you must copy inside the callback
});
```

**Characteristics**:

- the user gets a `DataHandle` and **must copy the data out inside the callback**.
- the handle is invalid as soon as the callback returns (the framework owns it).

### 11.3.3 Future style

```java
AppTarget target = new AppTarget("MyApp");
try (DataHandle req = new DataHandle("api")) {
    LfIo.writeJson(req, Map.of("query", "..."));

    CallFuture<Person> future = target.callFuture(req, Person.class, 3000);

    // chain combinators
    future.thenAccept(person -> System.out.println("got " + person.name))
          .exceptionally(err -> { log.warn("failed", err); return null; });

    // or block until it completes
    Person p = future.get(5, TimeUnit.SECONDS);
    System.out.println(p.name);
}
```

**`CallFuture<T>` is a subclass of `CompletableFuture<T>`** and additionally provides:

```java
future.abandoned()   // true means the call was abandoned on timeout; the C-side request may still be in flight
```

## 11.4 Timeout semantics

- **after a timeout the Future completes with `LingoFuseTimeoutException`**.
- `abandoned()` becomes `true`.
- **the C-side request is not cancelled**; if a response arrives later its data is silently dropped.
- **the stub stays alive for 60 seconds** (`graceSeconds`), so a late C callback can find a valid
  object.

## 11.5 Dispatch-failure semantics

When `LF_Async_Call` returns 0:

- **the callback is never triggered** (the C side never received the stub).
- the op status becomes `NOT_QUEUED`.
- **the Future completes immediately with `LingoFuseException`** (the synchronous path).
- **the user callback is invoked synchronously once with `(null, LingoFuseException)`**.

**Note**: on a dispatch failure the callback runs **synchronously on the caller's thread**, not on a
worker thread. **The callback must therefore be safe on any thread.**

## 11.6 The diagnostics interface

```java
AsyncBridge bridge = AsyncBridge.instance();
Map<String, Object> stats = bridge.stats();
// {
//   "total":           N,   // the number of live ops
//   "pending":         N,   // waiting for the callback
//   "fired":           N,   // fired, waiting to be released
//   "abandoned":       N,   // timed out, waiting for the grace period
//   "not_queued":      N,   // dispatch failed
//   "released_total":  N,   // the cumulative number released
//   "grace_seconds":   N    // the current grace period
// }

int liveOps = bridge.liveOpCount();
AsyncBridge.shutdownInstance();    // used for test isolation
```

**A `pending` count that never drops = the C side is not responding**; a rising `not_queued` =
dispatch failures.

## 11.7 Reclaiming stub memory (ArenaReaper)

FFM upcall stubs are allocated in `Arena.ofShared()`. Each op has its own arena.

**When is the arena closed?**

- **op status FIRED or NOT_QUEUED**: closed immediately (the C side will never use this stub again).
- **op status ABANDONED**: **not closed**, because the C side may still be in flight and may fire
  the callback at any moment. The arena is kept until the JVM exits.

**Why not close it on timeout?** Because the C-side request is not cancelled; closing the arena on
timeout would make the C-side callback land in freed memory and crash the process.

**The cost**: the arena of a timed-out op is never released. That is **deliberate** — a 60-second
grace period cannot 100% guarantee that the C side will never fire later. A few KB of native memory
is traded for not crashing.

---

# Chapter 12 — `DataHandle`

The RAII data handle; implements `AutoCloseable`.

## 12.1 Creating

| Method | Notes |
|------|------|
| `new DataHandle(String apiName)` | creates an auto-recycled handle |
| `DataHandle.createPermanent(String apiName)` | creates a permanent handle |
| `DataHandle.fromRaw(MemorySegment raw, boolean owned)` | wraps an existing pointer (internal) |

## 12.2 Lifecycle

| Method | Notes |
|------|------|
| `close()` | releases the handle (a no-op for a borrowed handle) |
| `isValid()` | is the handle valid? |
| `isOwning()` | will `close()` call `LF_FreeData`? |
| `raw()` | returns the native `MemorySegment` |

## 12.3 Position and size

| Method | Notes |
|------|------|
| `position()` | returns the current cursor |
| `setPosition(long)` | moves the cursor; beyond the size it grows implicitly |
| `size()` | returns the total byte count |
| `setSize(long)` | resizes; the new space is uninitialized |
| `getBufferPointer()` | the native pointer of the internal buffer |

## 12.4 Byte I/O

| Method | Notes |
|------|------|
| `writeBytes(byte[])` | write raw bytes |
| `readBytes(int)` | read up to N bytes (a short read does not throw) |
| `readBytesExact(int)` | read exactly N bytes (throws `LingoFuseIoException` if short) |
| `tryReadBytes(int)` | an exact read that does not throw (returns `ReadResult<byte[]>`) |
| `readAllBytes()` | read to the end |

## 12.5 Atomic type I/O (little-endian)

**write**: `writeInt8` / `writeUInt8` / `writeInt16` / `writeUInt16` / `writeInt32` / `writeUInt32` /
`writeInt64` / `writeUInt64` / `writeSingle` / `writeDouble`.

**read**: `readInt8` / `readUInt8` / ... / `readDouble`.

**Reads are exact**: insufficient data throws `LingoFuseIoException`.

## 12.6 String I/O

| Method | Notes |
|------|------|
| `writeString(String)` | write UTF-8 + NUL |
| `readString()` | read up to the NUL (or the end of the buffer) |
| `tryReadString()` | read a string without throwing |

## 12.7 Side data accessors

| Method | Notes |
|------|------|
| `getP2pUid()` | read the sender's 32-byte UID (side data, valid only on a callback Input) |
| `getP2pName()` | read the sender's P2P group name (side data, valid only on a callback Input) |

## 12.8 `ReadResult<T>`

`tryReadBytes` / `tryReadString` return a `ReadResult<T>`:

| Method | Notes |
|------|------|
| `isOk()` | did it succeed? |
| `getValue()` | the value on success; null on failure |

---

# Chapter 13 — `AppHandle`

The RAII application handle; implements `AutoCloseable`.

## 13.1 Creating

| Method | Notes |
|------|------|
| `new AppHandle(String name)` | create with an empty description |
| `new AppHandle(String name, String desc)` | create with a description |

## 13.2 State

| Method | Notes |
|------|------|
| `name()` | returns the App name |
| `isValid()` | is the handle valid? |
| `raw()` | returns the native `MemorySegment` |
| `withHandle(Function<MemorySegment, T>)` | run an operation under the lock (internal) |

## 13.3 API registration

| Method | Notes |
|------|------|
| `registerCall(String api, BiConsumer<DataHandle, DataHandle> handler)` | register a Call API |
| `registerCall(String api, String desc, handler)` | with a description |
| `registerNotify(String api, Consumer<DataHandle> handler)` | register a Notify API |
| `registerNotify(String api, String desc, handler)` | with a description |
| `unregister(String api)` | deregister |

**Return value**: `boolean`. `false` means the name already exists.

**API names are case-insensitive**: `registerCall("add", ...)` and `registerCall("ADD", ...)`
conflict.

## 13.4 Local execution

| Method | Notes |
|------|------|
| `localCall(DataHandle param)` | a local synchronous call, returning the result handle |
| `localNotify(DataHandle param)` | a local notification |

**Local execution never touches the network**. It suits cross-App calls inside one process.

## 13.5 Client binding

| Method | Notes |
|------|------|
| `bind()` | bind to every idle Client, returning the number bound |

**Note**: `bind()` must be called after `Framework.prepareDone()`, and the main thread must be
running. `0` means there were no idle clients or the main thread was not started.

## 13.6 Lifecycle

| Method | Notes |
|------|------|
| `close()` | runs the first phase of two-phase destruction |

**Two-phase destruction**:

1. `close()` → `LF_FreeApp`: detaches from all clients and stops the sequenced threads.
2. `Framework.shutdown()` → `LF_Shutdown`: actually destroys the `TLF_App` object.

**The handle is invalid after `close()`** and cannot be used. The real object stays in the global
pool until `shutdown()`.

---

# Chapter 14 — `Framework`

The process-level facade. Every operation that needs a "global view" lives here.

## 14.1 Callback error handling

| Method | Notes |
|------|------|
| `setCallbackErrorHandler(BiConsumer<String, Throwable>)` | install a callback error handler |
| `setCallbackErrorStderrFallback(boolean)` | enable/disable the default stderr output (enabled by default) |
| `reportCallbackError(String, Throwable)` | internal: report a swallowed exception |

## 14.2 Network preparation

| Method | Notes |
|------|------|
| `resetPrepare()` | clear the preparation queue (does not affect services already started) |
| `prepareService(String listen, String physics)` | prepare a service; returns a tag or -1 |
| `prepareClient(String physics, AppHandle app)` | prepare a client; `app` may be null |
| `prepareDone()` | start the framework; returns 1 or 0 |
| `exitMainThread()` | stop the simulated main thread |

**`prepareDone()` returns 1 only once per process**. A second call returns 0, which is **not a
failure**.

**`exitMainThread()` also flushes the handle pool**, after which every handle is invalid.

## 14.3 Runtime options

| Method | Notes |
|------|------|
| `setOption(String option, String value)` | set an option (generic) |
| `getOption(String option)` | read an option (generic) |

**Prefer the typed `Options.*` methods** (see Chapter 17).

## 14.4 App names

| Method | Notes |
|------|------|
| `generateAppName()` | generate a globally unique App name |
| `getAppName(AppHandle app)` | query the name of an App handle |

**`generateAppName()` must be called after `prepareDone()`**, otherwise the tunnel information is
missing and the name is not unique.

## 14.5 Remote calls — App name

| Method | Notes |
|------|------|
| `call(String app, DataHandle param, long timeoutMs)` | synchronous call |
| `tryCall(String app, DataHandle param, long timeoutMs)` | returns null on timeout |
| `notify(String app, DataHandle param)` | one-way notification |
| `sequencedNotify(String app, DataHandle param)` | FIFO one-way notification |

**`call` returns a size=0 handle on timeout** (not null). To distinguish "timeout" from "empty
response", use `tryCall` or check `size()`.

## 14.6 Remote calls — UID

| Method | Notes |
|------|------|
| `uidCall(byte[] uid, DataHandle param, long timeoutMs)` | synchronous call |
| `tryUidCall(byte[] uid, DataHandle param, long timeoutMs)` | returns null on timeout |
| `uidNotify(byte[] uid, DataHandle param)` | one-way notification |
| `uidSequencedNotify(byte[] uid, DataHandle param)` | FIFO one-way notification |

## 14.7 Remote calls — P2PName

| Method | Notes |
|------|------|
| `p2pCall(String group, DataHandle param, long timeoutMs)` | synchronous call |
| `tryP2pCall(String group, DataHandle param, long timeoutMs)` | returns null on timeout |
| `p2pNotify(String group, DataHandle param)` | one-way notification |
| `p2pSequencedNotify(String group, DataHandle param)` | FIFO one-way notification |

## 14.8 Async calls (12 methods)

**App name**:

- `asyncCall(String app, DataHandle param, AsyncResultHandler handler)`
- `asyncCallJson(String app, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`
- `asyncSequencedCall(String app, DataHandle param, AsyncResultHandler handler)`
- `asyncSequencedCallJson(String app, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`

**UID**:

- `asyncUidCall(byte[] uid, ...)`
- `asyncUidCallJson(byte[] uid, ...)`
- `asyncUidSequencedCall(byte[] uid, ...)`
- `asyncUidSequencedCallJson(byte[] uid, ...)`

**P2PName**:

- `asyncP2pCall(String group, ...)`
- `asyncP2pCallJson(String group, ...)`
- `asyncP2pSequencedCall(String group, ...)`
- `asyncP2pSequencedCallJson(String group, ...)`

**All of them return `boolean`**: `true` means the enqueue succeeded, `false` means the dispatch
failed.

## 14.9 Shutdown

| Method | Notes |
|------|------|
| `shutdown()` | shut the framework down completely |

**Safe to call more than once**.

---

# Chapter 15 — `LfIo`

**Uniform JSON and string I/O**. This is the **only permitted** entry point for touching the
payload. Any code that bypasses `LfIo` and calls `DataHandle.writeBytes` directly to do JSON will
break cross-language compatibility.

## 15.1 JSON serialization

| Method | Notes |
|------|------|
| `dumpsJson(Object)` | serialize to a compact JSON string (no NUL) |
| `loadsJson(String)` | parse into a `JsonNode` |
| `loadsJson(String, Class<T>)` | parse into a POJO |

## 15.2 JSON I/O

| Method | Notes |
|------|------|
| `writeJson(DataHandle, Object)` | write JSON (compact + UTF-8 + NUL) |
| `readJson(DataHandle)` | read JSON as a `JsonNode` |
| `readJson(DataHandle, Class<T>)` | read JSON as a POJO |
| `tryReadJson(DataHandle, Class<T>)` | the non-throwing version |

## 15.3 String I/O

| Method | Notes |
|------|------|
| `writeString(DataHandle, String)` | write UTF-8 + NUL |
| `readString(DataHandle)` | read a string |
| `writeStringBytes(DataHandle, byte[])` | write raw bytes + NUL |
| `readStringBytes(DataHandle)` | read raw bytes (up to the NUL) |
| `readAllBytes(DataHandle)` | read everything |

## 15.4 Deserializing into a POJO

```java
public class Person {
    public String name;
    public int age;
}

try (DataHandle resp = ...) {
    Person p = LfIo.readJson(resp, Person.class);
}
```

Jackson maps by field name. **Fields must be public or have getters/setters**.

## 15.5 The JSON serialization policy (critical)

The equivalent implementation of `dumpsJson(obj)`:

```java
new ObjectMapper().writeValueAsString(obj)
```


**Three guarantees**:

1. **compact output**: no indentation, no newlines.
2. **no `\uXXXX` escapes**: Chinese text and emoji are emitted as literal UTF-8.
3. **strict types**: a non-serializable type throws.

**How it differs from Python**: Python's `default=str` degrades an unserializable object to
`str(obj)`, whereas Java throws. To serialize a custom type, Jackson must support it (add
annotations / implement an interface) or you must convert it to a `JsonNode` first.

---

# Chapter 16 — The `Target` family

A unified wrapper over the three addressing modes.

## 16.1 Construction

```java
// App name: any non-empty string
new AppTarget("MyApp");
new AppTarget("MyApp", 10_000L);        // an explicit default timeout

// UID: must be 32 bytes
new UIDTarget(uidBytes);
new UIDTarget(uidBytes, 10_000L);

// P2PName: any non-empty string
new P2PNameTarget("worker_group");
new P2PNameTarget("worker_group", 10_000L);
```

**Validation at construction**: `UIDTarget` checks `uid.length == 32` and throws
`IllegalArgumentException` otherwise. It also makes a **defensive copy** of the bytes.

## 16.2 Synchronous calls

```java
DataHandle call(DataHandle param)
DataHandle call(DataHandle param, long timeoutMs)
<T> T callJson(DataHandle param, Class<T> type)
<T> T callJson(DataHandle param, Class<T> type, long timeoutMs)
```

**Timeout semantics**: `call` throws `LingoFuseTimeoutException` on timeout or when the target is
unreachable. **This differs from `Framework.call`** — the latter returns a size=0 handle.

## 16.3 One-way notifications

```java
void notify(DataHandle param)
void sequencedNotify(DataHandle param)
```

**`notify` guarantees no ordering**; `sequencedNotify` guarantees FIFO within the same
`(target, api)` pair.

## 16.4 Async callbacks

```java
boolean asyncCall(DataHandle param, AsyncResultHandler handler)
<T> boolean asyncCallJson(DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)
boolean asyncSequencedCall(DataHandle param, AsyncResultHandler handler)
<T> boolean asyncSequencedCallJson(DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)
```

## 16.5 Future style

```java
<T> CallFuture<T> callFuture(DataHandle param, Class<T> type)
<T> CallFuture<T> callFuture(DataHandle param, Class<T> type, long timeoutMs)
<T> CallFuture<T> sequencedCallFuture(DataHandle param, Class<T> type)
<T> CallFuture<T> sequencedCallFuture(DataHandle param, Class<T> type, long timeoutMs)
```

## 16.6 Value semantics

```java
Target a = new AppTarget("X");
Target b = new AppTarget("X");
assert a.equals(b);
assert a.hashCode() == b.hashCode();

Map<Target, Integer> map = new HashMap<>();
map.put(a, 1);
assert map.get(b) == 1;
```

**Different types are never equal**: `AppTarget("X")` and `P2PNameTarget("X")` are not equal.

---

# Chapter 17 — `Options`

16 typed shortcut pairs. **All options are process-level globals and do not persist across
`shutdown()`**.

## 17.1 Authentication

| Setter | Getter |
|--------|--------|
| `setPassword(String)` | `getPassword()` → always returns `'********'` |

**The password is returned through a fixed mask**; the real value is never exposed through the API.

## 17.2 Logging and diagnostics

| Setter | Getter | Type |
|--------|--------|------|
| `setDebug(String)` | `getDebug()` → a placeholder | write-only |
| `setQuiet(boolean)` | `getQuiet()` | boolean |
| `setShowThreadId(boolean)` | `getShowThreadId()` | boolean |
| `setConsoleOutput(boolean)` | `getConsoleOutput()` | boolean |

## 17.3 Connection readiness

| Setter | Getter | Type |
|--------|--------|------|
| `setOverlapConnection(boolean)` | `getOverlapConnection()` | boolean |
| `setWaitConnectionReadyOk(boolean)` | `getWaitConnectionReadyOk()` | boolean |
| `setWaitConnectionTimeout(long)` | `getWaitConnectionTimeout()` | long (ms) |

**`Overlap_Connection` must be set before `prepareClient`**.

## 17.4 IPC

| Setter | Getter |
|--------|--------|
| `setIpcServThreadCount(int)` | `getIpcServThreadCount()` |
| `setIpcServMaxQueueLength(int)` | `getIpcServMaxQueueLength()` |
| `setIpcServMaxMsgSize(int)` | `getIpcServMaxMsgSize()` |

**Must be set before the IPC service starts**.

## 17.5 Sequenced notifications

| Setter | Getter |
|--------|--------|
| `setFixedSequencedTime(long)` | `getFixedSequencedTime()` |

## 17.6 P2P group name

| Setter | Getter |
|--------|--------|
| `setP2pName(String)` | `getP2pName()` |

**`Options.getP2pName()` reads this process's configuration**, unlike `DataHandle.getP2pName()`
(which reads the sender's identity).

## 17.7 The data handle pool

| Setter | Getter |
|--------|--------|
| `setDataHandleIdleTimeout(long)` | `getDataHandleIdleTimeout()` |
| `setDataHandlePoolScanInterval(long)` | `getDataHandlePoolScanInterval()` |

**Setting `0` or a negative value disables the corresponding mechanism**.

## 17.8 Command flush

| Setter | Getter |
|--------|--------|
| `setNoReponseCmdNullFlushThreshold(int)` | `getNoReponseCmdNullFlushThreshold()` |

**Note the historical spelling `Reponse`** (one `s` missing); it is deliberate.

## 17.9 Key semantics

- **booleans travel on the wire as `"True"` / `"False"`** (the Pascal convention). The Java
  signatures are still `boolean`.
- **unknown options are silently ignored** (no exception).
- **options never set return 0 / false / `""`**.
- **they do not persist across `Framework.shutdown()`**.

---

# Chapter 18 — `P2PRegistry`

**Process-level P2P namespace registration**, independent of any App.

## 18.1 How it differs from `AppHandle`

| Dimension | `AppHandle.registerCall` | `P2PRegistry.registerCall` |
|------|-------------------------|---------------------------|
| **ownership** | belongs to the `TLF_App` | belongs to **the process itself** |
| **how it is reached** | App-name addressing + UID addressing | **only** UID addressing + P2PName addressing |
| **lifetime** | ends with `AppHandle.close()` | until the process exits |
| **namespace** | independent of P2P; the same name does not conflict | independent of Apps; the same name does not conflict |

**The two can coexist**: the same name can exist in both namespaces at once.

## 18.2 Registering

```java
P2PRegistry.registerCall("whoami", "echo caller identity",
    (in, out) -> {
        byte[] uid = in.getP2pUid();
        String name = in.getP2pName();
        LfIo.writeJson(out, Map.of(
                "uid_hex", toHex(uid),
                "p2p_name", name));
    });

P2PRegistry.registerNotify("log", "consume and discard", in -> {
    // ...
});
```

**Overloads**: one version with a description and one with an empty description.

## 18.3 Unregistering

```java
boolean ok = P2PRegistry.unregister("whoami");
```

**Returns `boolean`**: `true` means the name existed and was removed.

## 18.4 Behaviour

- **a duplicate registration throws `LingoFuseRegistrationException`**, and `getNamespace()`
  returns `NAMESPACE_P2P`.
- **registration may happen before or after `prepareDone()`**.
- **unregistering only removes the name**: no new calls are accepted, but callbacks already in
  flight are not interrupted.

## 18.5 Typical uses

- **health probes**: `ping` / `whoami`.
- **capability discovery**: `get_capabilities`.
- **global utilities**: `current_time` / `random_uuid`.

**These APIs belong to no App**, and any client can call them by group name or UID.

---

# Chapter 19 — `NetworkEvents`

Process-level global connect / disconnect events.

## 19.1 Semantics

- **Connect**: fires when a Client receives the service API-info broadcast for the first time. It
  is **not the TCP handshake**. It fires once per connection lifetime and again after a reconnect.
- **Disconnect**: fires when the physical link is lost. Automatic reconnection **does not** fire
  Disconnect again.

## 19.2 Installing

```java
NetworkEvents.setNetworkEvent(
    addr -> System.out.println("[+] Connected: " + addr),
    addr -> System.out.println("[-] Disconnected: " + addr)
);
```

Or in an OOP style:

```java
class MyListener extends NetworkEvents.NetworkEventListener {
    @Override
    public void onConnect(String addr) { /* ... */ }
    @Override
    public void onDisconnect(String addr) { /* ... */ }
}

NetworkEvents.setNetworkEventListener(new MyListener());
```

## 19.3 Clearing

```java
NetworkEvents.clear();
```

**Safe to call more than once**.

## 19.4 The threading contract

**Callbacks run on native worker threads**. `addr` is a Python `str` (already decoded from UTF-8)
and may be retained safely.

**Do not block inside the callback**.

## 19.5 Replacement semantics

**`setNetworkEvent` is a REPLACE, not a PATCH**:

```java
setNetworkEvent(cb1, null);         // installs cb1, no disconnect handler
setNetworkEvent(null, cb2);         // cb1 is removed, only cb2 is active
```

To install both, pass them in **one call**:

```java
setNetworkEvent(cb1, cb2);
```

---

# Chapter 20 — `LingoFuseStatus`

The status queue + health checks.

## 20.1 The status queue

| Method | Notes |
|------|------|
| `getStatusCount()` | the number of pending log messages |
| `getStatus()` | pop the next one |
| `drainStatus()` / `drainStatus(int)` | pop in bulk |
| `postStatus(String)` | inject a log message |

**The queue capacity is 1000**; when full the oldest entries are dropped.

**It depends on the simulated main thread**: before `prepareDone` the queue may be empty or stale.

## 20.2 Health checks

| Method | Notes |
|------|------|
| `checkMainThread()` | is the main thread running? |
| `checkApp(String)` | is the App visible? |
| `checkApi(String, String)` | is the API visible? |
| `checkUid(byte[])` | is the UID visible? |
| `checkUidApi(byte[], String)` | is the UID's API visible? |
| `checkP2pName(String)` | is the P2P group visible? |
| `checkP2pNameApi(String, String)` | is the P2P group's API visible? |

**Every check reads the local cache**, which lags the broadcast by about 3 seconds. **Use them for
probing, not for decisions**.

**The recommended retry pattern**:

```java
for (int i = 0; i < 30; i++) {
    if (LingoFuseStatus.checkApi("Target", "api")) break;
    Thread.sleep(200);
}
```

---

# Chapter 21 — The exception hierarchy

## 21.1 The hierarchy

```
RuntimeException
  └── LingoFuseException
        ├── LingoFuseIoException
        ├── LingoFuseObjectDisposedException
        ├── LingoFuseTimeoutException
        └── LingoFuseRegistrationException
```

## 21.2 Each exception

| Type | Trigger | Carried information |
|------|---------|---------|
| `LingoFuseException` | the base class | — |
| `LingoFuseIoException` | a byte-level I/O failure (short read / short write) | `getOperation()` |
| `LingoFuseObjectDisposedException` | an operation on a closed object | `getObjectName()` |
| `LingoFuseTimeoutException` | a synchronous or async call timed out | `getTimeoutMs()` |
| `LingoFuseRegistrationException` | an API registration failed | `getApiName()` / `getNamespace()` |

## 21.3 Catching strategy

**A single entry point**:

```java
try {
    // ...
} catch (LingoFuseException e) {
    if (e instanceof LingoFuseTimeoutException te) {
        log.warn("timed out after {} ms", te.getTimeoutMs());
    } else if (e instanceof LingoFuseRegistrationException re) {
        log.warn("registration conflict: {} in {}",
                 re.getApiName(), re.getNamespace());
    } else {
        log.error("lingofuse error", e);
    }
}
```

## 21.4 Exceptions in async callbacks

**Async callbacks never throw**. Every error is delivered through `AsyncResult.error()` or through
the exception on a `CallFuture`.

```java
Framework.asyncCallJson("App", req, Person.class, (person, error) -> {
    if (error != null) {
        // handle every error here: dispatch failure, timeout, deserialization failure
        log.warn("async failed", error);
        return;
    }
    // the success path
});
```

---

# Chapter 22 — The server pattern

## 22.1 The standard server skeleton

```java
public final class MyService {
    private static final String ENDPOINT = "ipc:my_service";
    private static final String APP_NAME = "MyService";
    private static final AtomicBoolean CLEANED = new AtomicBoolean();
    private static volatile boolean started = false;

    static {
        Runtime.getRuntime().addShutdownHook(
                new Thread(MyService::cleanupOnce, "svc-shutdown"));
    }

    private static void cleanupOnce() {
        if (!CLEANED.compareAndSet(false, true)) return;
        try { NetworkEvents.clear(); } catch (Throwable ignored) {}
        try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
        try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
    }

    public static void main(String[] args) throws Exception {
        AppHandle app = new AppHandle(APP_NAME, "my service");

        app.registerCall("ping", "health check",
                (in, out) -> out.writeString("pong"));

        app.registerCall("add", "add two int32",
                (in, out) -> out.writeInt32(in.readInt32() + in.readInt32()));

        app.registerNotify("log", "one-way log",
                in -> System.out.println("log: " + in.readString()));

        Framework.setOption("Wait_Connection_ReadyOk", "True");
        Framework.setOption("Overlap_Connection", "True");
        Framework.resetPrepare();
        Framework.prepareService(ENDPOINT, ENDPOINT);
        Framework.prepareClient(ENDPOINT, app);

        if (Framework.prepareDone() != 1
                && !LingoFuseStatus.checkMainThread()) {
            throw new IllegalStateException("startup failed");
        }
        started = true;

        System.out.println("Ready. Press Enter to stop.");
        System.in.read();

        app.close();
        cleanupOnce();
    }
}
```

## 22.2 Key points

1. **the App name must be unique**: it must be unique across the whole mesh.


2. **register the APIs first, then `prepareClient`**: otherwise the `Init_App_Info` broadcast
   carries an empty API list.
3. **the shutdown hook guarantees cleanup**: it runs even on `System.exit()`.
4. **exception isolation**: an exception thrown in a callback is swallowed, but you should still
   try/catch and log it.

## 22.3 Listening on several addresses

```java
Framework.resetPrepare();
Framework.prepareService("0.0.0.0:9898", "192.168.1.5:9898");
Framework.prepareService("ipc:local_svc", "ipc:local_svc");
Framework.prepareClient("0.0.0.0:9898", app);
Framework.prepareClient("ipc:local_svc", app);
Framework.prepareDone();
```

**Note**: with `Overlap_Connection=True` every `prepareClient` creates an independent tunnel. With
the default `False`, a single address may host only one client.

---

# Chapter 23 — The client pattern

## 23.1 The standard client skeleton

```java
public final class MyClient {
    private static final String ENDPOINT = "ipc:my_service";
    private static final AtomicBoolean CLEANED = new AtomicBoolean();
    private static volatile boolean started = false;

    static {
        Runtime.getRuntime().addShutdownHook(
                new Thread(MyClient::cleanupOnce, "cli-shutdown"));
    }

    private static void cleanupOnce() {
        if (!CLEANED.compareAndSet(false, true)) return;
        try { NetworkEvents.clear(); } catch (Throwable ignored) {}
        try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
        try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
    }

    public static void main(String[] args) {
        try {
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.resetPrepare();
            Framework.prepareClient(ENDPOINT, null);

            if (Framework.prepareDone() != 1
                    && !LingoFuseStatus.checkMainThread()) {
                throw new IllegalStateException("startup failed");
            }
            started = true;

            // wait for the target App to become visible
            waitFor("MyService", "ping", 10_000);

            // a synchronous call
            try (DataHandle req = new DataHandle("add")) {
                req.writeInt32(5);
                req.writeInt32(7);
                try (DataHandle resp = Framework.call(
                        "MyService", req, 3000)) {
                    if (resp.size() == 0) {
                        System.err.println("call failed");
                    } else {
                        System.out.println("5 + 7 = " + resp.readInt32());
                    }
                }
            }

            // an async call
            try (DataHandle req = new DataHandle("ping")) {
                req.writeString("");
                Framework.asyncCall("MyService", req,
                        (result, error) -> {
                            if (error != null) {
                                System.err.println("async failed: " + error);
                            } else {
                                System.out.println("async got: "
                                        + result.readString());
                            }
                        });
            }

            Thread.sleep(2000);

        } catch (Throwable t) {
            t.printStackTrace(System.err);
        } finally {
            cleanupOnce();
        }
    }

    private static void waitFor(String app, String api, long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (LingoFuseStatus.checkApi(app, api)) return;
            try { Thread.sleep(200); } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }
}
```

## 23.2 The client retry pattern

```java
public static Optional<DataHandle> callWithRetry(
        String app, DataHandle param, int maxRetries) {
    for (int i = 0; i < maxRetries; i++) {
        try {
            DataHandle resp = Framework.call(app, param, 3000);
            if (resp.size() > 0) return Optional.of(resp);
            resp.close();
        } catch (LingoFuseException e) {
            // log it
        }
        try {
            Thread.sleep(200L * (i + 1));  // exponential backoff
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            return Optional.empty();
        }
    }
    return Optional.empty();
}
```

**Note**: if the server is **not idempotent**, retrying duplicates the side effects. You must use an
**idempotency key** (see Chapter 25).

---

# Chapter 24 — The worker pool pattern

**The scenario**: a group of homogeneous workers processing stateless compute tasks. Use P2PName
addressing so the server side does the load balancing.

## 24.1 The worker side

```java
public final class ComputeWorker {
    private static final String ENDPOINT = "ipc:compute_grid";
    private static final String APP_NAME = "compute_worker";

    public static void main(String[] args) throws Exception {
        // 1. declare the group (every worker runs this)
        Options.setP2pName("compute_workers");

        AppHandle app = new AppHandle(APP_NAME, "compute worker");

        app.registerCall("exp", "compute base^exponent",
                (in, out) -> {
                    var req = LfIo.readJson(in, Map.class);
                    double base = ((Number) req.get("base")).doubleValue();
                    double exponent = ((Number) req.get("exponent")).doubleValue();
                    LfIo.writeJson(out, Map.of("result", Math.pow(base, exponent)));
                });

        Framework.setOption("Wait_Connection_ReadyOk", "True");
        Framework.resetPrepare();
        Framework.prepareClient(ENDPOINT, app);
        Framework.prepareDone();

        System.out.println("Worker ready.");
        System.in.read();
    }
}
```

**Deployment**: run N worker instances, all connected to the same ENDPOINT, all calling
`setP2pName("compute_workers")`.

## 24.2 The caller side

```java
P2PNameTarget target = new P2PNameTarget("compute_workers");

for (int i = 0; i < 100; i++) {
    try (DataHandle req = new DataHandle("exp")) {
        LfIo.writeJson(req, Map.of("base", 2.0, "exponent", (double) i));
        try (DataHandle resp = target.call(req, 5000)) {
            var result = LfIo.readJson(resp, Map.class);
            System.out.println("2^" + i + " = " + result.get("result"));
        }
    }
}
```

**What to observe**: the N workers split these 100 requests evenly.

## 24.3 The load-balancing policies

The server-side dispatcher has two policies:

1. **round-robin (Cycle_Anchor)**: pick the target with the smallest anchor, then advance that
   target's anchor.
2. **sticky (FixedSequenced)**: keep the same target for a while (20 seconds by default), controlled
   by `Fixed_Sequenced_Time`.

```java
Options.setFixedSequencedTime(5000);  // shorten the stickiness window to 5 seconds
```

---

# Chapter 25 — Identity awareness and authorization

## 25.1 The whoami pattern

**Register a whoami API so any caller can learn its own UID**:

```java
app.registerCall("whoami", "echo caller identity", (in, out) -> {
    byte[] uid = in.getP2pUid();
    String name = in.getP2pName();
    LfIo.writeJson(out, Map.of(
            "uid_hex", toHex(uid),
            "p2p_name", name));
});

private static String toHex(byte[] bytes) {
    StringBuilder sb = new StringBuilder(bytes.length * 2);
    for (byte b : bytes) {
        sb.append(String.format("%02x", b));
    }
    return sb.toString();
}
```

## 25.2 The client's UID probe

```java
public class UIDProbe {
    private volatile byte[] myUid;
    private volatile String myP2pName;

    public void refresh(UIDTarget target) {
        try (DataHandle req = new DataHandle("whoami")) {
            try (DataHandle resp = target.call(req, 3000)) {
                var me = LfIo.readJson(resp, Map.class);
                this.myUid = hexToBytes((String) me.get("uid_hex"));
                this.myP2pName = (String) me.get("p2p_name");
            }
        }
    }

    public byte[] uid() { return myUid; }
    public String p2pName() { return myP2pName; }
}
```

**Key point**: the UID changes on reconnect, so it must be re-probed after reconnecting.

## 25.3 The authorization pattern

**Control access on the server side with a UID allow-list**:

```java
private static final Set<String> ALLOWED_UIDS = Set.of(
        "aabbccdd...", "11223344..."
);

app.registerCall("admin_op", "privileged operation", (in, out) -> {
    String callerUidHex = toHex(in.getP2pUid());
    if (!ALLOWED_UIDS.contains(callerUidHex)) {
        LfIo.writeJson(out, Map.of("error", "unauthorized"));
        return;
    }
    // perform the privileged operation
    LfIo.writeJson(out, Map.of("result", "ok"));
});
```

## 25.4 The idempotency pattern

**The server records request_id and returns the same response for repeated requests**:

```java
private static final Map<String, String> IDEMPOTENCY_CACHE = new ConcurrentHashMap<>();

app.registerCall("payment", "process payment", (in, out) -> {
    var req = LfIo.readJson(in, Map.class);
    String requestId = (String) req.get("request_id");

    String cached = IDEMPOTENCY_CACHE.get(requestId);
    if (cached != null) {
        out.writeString(cached);
        return;
    }

    String result = doPayment(req);
    IDEMPOTENCY_CACHE.put(requestId, result);
    out.writeString(result);
});
```

**The client generates a fresh request_id each time**:

```java
String requestId = UUID.randomUUID().toString();
try (DataHandle req = new DataHandle("payment")) {
    LfIo.writeJson(req, Map.of(
            "request_id", requestId,
            "amount", 100,
            "from", "A",
            "to", "B"));
    try (DataHandle resp = Framework.call("Payment", req, 10000)) {
        // ...
    }
}
```

**Note**: `IDEMPOTENCY_CACHE` needs periodic cleanup, or an LRU.

---

# Chapter 26 — Cross-language integration

## 26.1 The CrossDemo trio

LingoFuse verifies cross-language integration with the `CrossService` / `CrossNode` / `CrossCall`
trio:

- **`CrossService`**: the beacon (coordinator). Starts the IPC service endpoint `ipc:cross`.
- **`CrossNode`**: the worker. Registers the `add` / `inv_seri` APIs.
- **`CrossCall`**: the load-test client. 32 threads × 10 seconds, calling `add` / `inv_seri` at
  random.

**Running it** (three terminals):

```bash
# terminal 1
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossService

# terminal 2 (after terminal 1 prints "IPC service 'ipc:cross' is running")
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossNode

# terminal 3 (after terminal 2 prints "[Node] Online")
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossCall
```

**Expected**: terminal 3 prints statistics after 10 seconds, with a 100% success rate.

## 26.2 Cross-language interop verification (Java ↔ C#)

**A Java client → a C# server**:

```bash
# terminal A (the C# side)
cd path\to\LingoFuse\csharp
dotnet run --project crossService
dotnet run --project CrossNode

# terminal B (the Java side)
cd path\to\LingoFuse\java
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossCall
```

**Expected**: the Java client calls `add` / `inv_seri` on the C# server, and **the bytes match
exactly**.

**The reverse also holds**: the Java `CrossNode` can be called by the `CrossCall` of C# / Python /
C++ / JS.

## 26.3 The key point: wire contract consistency

Cross-language interop requires that **both ends understand the wire protocol identically**.
Chapter 7 lists every **cross-language invariant**. Any binding that obeys those invariants can
interoperate with the others.

**Every mechanism in the Java binding that "looks like an optimization"** (`ReentrantReadWriteLock`,
`ArenaReaper`, `AsyncBridge`, the JVM shutdown hook and so on) **is Java-private and does not
intrude on the wire**. That is explicitly marked in every Javadoc of the Java binding.

## 26.4 The data type mapping table

| Type | Java | C# | Python | C++ | Pascal | JS |
|------|------|-----|--------|-----|--------|-----|
| int8 | `byte` | `sbyte` | `int` | `int8_t` | `ShortInt` | `number` |
| uint8 | `int` (0..255) | `byte` | `int` | `uint8_t` | `Byte` | `number` |
| int16 | `short` | `short` | `int` | `int16_t` | `SmallInt` | `number` |
| uint16 | `int` | `ushort` | `int` | `uint16_t` | `Word` | `number` |
| int32 | `int` | `int` | `int` | `int32_t` | `Integer` | `number` |
| uint32 | `long` | `uint` | `int` | `uint32_t` | `Cardinal` | `number` |
| int64 | `long` | `long` | `int` | `int64_t` | `Int64` | `bigint` |
| uint64 | `long` | `ulong` | `int` | `uint64_t` | `QWord` | `bigint` |
| float | `float` | `float` | `float` | `float` | `Single` | `number` |
| double | `double` | `double` | `float` | `double` | `Double` | `number` |
| string | `String` | `string` | `str` | `std::string` | `string` | `string` |
| JSON | `JsonNode` / POJO | `JsonNode` | `dict` / `list` | `nlohmann::json` | `TDFE` | `object` |
| UID | `byte[32]` | `byte[32]` | `bytes` | `std::array<uint8_t,32>` | `TUID` | `Buffer(32)` |

---

# Chapter 27 — Lifecycle and graceful shutdown

## 27.1 The cleanup order (strict)

```
1. NetworkEvents.clear()            clear the global network event callbacks
2. Framework.exitMainThread()       stop the simulated main thread (also flushes the handle pool)
3. AppHandle.close()                release the application (phase one of two-phase destruction)
4. Framework.shutdown()             unload the library (phase two of two-phase destruction)
```

**Skipping any step leaves a dangling pointer**.

## 27.2 Guaranteeing cleanup with a shutdown hook

```java
public final class MyApp {
    private static final AtomicBoolean CLEANED = new AtomicBoolean();
    private static volatile boolean started = false;
    private static volatile AppHandle app = null;

    static {
        Runtime.getRuntime().addShutdownHook(
                new Thread(MyApp::cleanupOnce, "lf-shutdown"));
    }

    private static void cleanupOnce() {
        if (!CLEANED.compareAndSet(false, true)) {
            return;
        }
        try { NetworkEvents.clear(); } catch (Throwable ignored) {}
        try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
        try { if (app != null) app.close(); } catch (Throwable ignored) {}
        try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
    }

    public static void main(String[] args) {
        try {
            app = new AppHandle("MyApp", "demo");
            // ... register and start ...
            started = true;

            // the main logic
        } catch (Throwable t) {
            t.printStackTrace(System.err);
        } finally {
            cleanupOnce();
        }
    }
}
```

**Key points**:

- **`AtomicBoolean CLEANED`** guarantees the cleanup runs **exactly once**.
- **the shutdown hook** makes `System.exit()` trigger cleanup too.
- **`try/finally`** makes the exception path trigger cleanup too.

## 27.3 Common mistakes

| Mistake | Symptom |
|------|------|


| forgetting `exitMainThread` | the process hangs; the simulated main thread never exits |
| forgetting `shutdown` | library resources leak; the process may crash on exit |
| calling `shutdown` before `app.close` | `app.close` operates on an already released handle and crashes |
| using a handle after cleanup | `LingoFuseObjectDisposedException` or a native crash |

## 27.4 Restarting the framework

**You can reinitialize after `Framework.shutdown()`**:

```java
// the first run
Framework.prepareClient("ipc:a", app1);
Framework.prepareDone();
// ... use it ...

// shut down
NetworkEvents.clear();
Framework.exitMainThread();
app1.close();
Framework.shutdown();

// the second run (with a different address)
Framework.setOption(...);   // options do not persist across shutdown, so set them again
Framework.resetPrepare();
Framework.prepareClient("ipc:b", app2);   // the address must differ from the previous one
Framework.prepareDone();
```

**Note**: the `prepareClient` address must not equal one used before (unless the process is
restarted).

---

# Chapter 28 — Troubleshooting

## 28.1 Environment issues

| Error | Cause | Fix |
|------|------|------|
| `Cannot find module 'mvn'` | Maven is not installed or not on PATH | see §2.3 |
| `release version 22 not supported` | JDK < 22 | see §2.2 |
| `UnsatisfiedLinkError: Failed to load LingoFuse64.dll` | the native library is not on the search path | see §2.4 |
| `UnsatisfiedLinkError: symbol not found: LF_XXX` | the library version does not match the Java binding | check the DLL version |
| `The restricted method ... has been called` | native access is not enabled on JDK 24+ | add `--enable-native-access=ALL-UNNAMED` |

## 28.2 Network issues

| Error | Cause | Fix |
|------|------|------|
| `prepareDone() returns 0` | it was already initialized (normal behaviour) | check `checkMainThread()` to see whether it really failed |
| a call times out immediately | the API was registered after `prepareClient` | register first, then `prepareClient` |
| `checkApi` returns false | the 3-second broadcast delay | retry 30 times × 200ms |
| `no connection` | the client is not connected | check the `prepareClient` return value |

## 28.3 Async issues

| Error | Cause | Fix |
|------|------|------|
| the async callback never fires | dispatch returned false / the target does not exist / the bridge is already shut down | check the return value; check `AsyncBridge.stats()` |
| `LingoFuseTimeoutException` with 0 timeoutMs | it came from the async path (a known implementation detail) | use the synchronous path when you need a timeout value |
| `abandoned()` returns true | the call was abandoned on timeout; the C side may still be in flight | normal; the data is silently dropped when the response arrives |

## 28.4 Option issues

| Error | Cause | Fix |
|------|------|------|
| `Options` settings have no effect | a misspelled option name / wrong timing / not re-set after shutdown | use the typed methods; check the timing |
| `Overlap_Connection` has no effect | it was set after `prepareClient` | it must be set before |

## 28.5 Encoding issues

| Error | Cause | Fix |
|------|------|------|
| Chinese text / emoji turn into `\uXXXX` | the code bypassed `LfIo` and called an API that escapes | send every JSON payload through `LfIo.writeJson` / `readJson` |

## 28.6 Callback logging issues

| Error | Cause | Fix |
|------|------|------|
| callback logs are jammed onto one line (Windows) | an interaction between JVM native threads and the Windows console | use a single-consumer queue plus a dedicated output thread |

**Reference implementation** (the pattern used in `CrossNode` / `CrossCall`):

```java
private static final BlockingQueue<String> LOG_QUEUE =
        new LinkedBlockingQueue<>();

static {
    Thread t = new Thread(() -> {
        try {
            while (true) {
                String line = LOG_QUEUE.take();
                System.out.println(line);
                System.out.flush();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }, "log-writer");
    t.setDaemon(true);
    t.start();
}

private static void log(String line) {
    LOG_QUEUE.offer(line);  // callback threads only enqueue, they never write directly
}
```

## 28.7 The complete diagnostic tool

```java
import lingofuse.ffi.LibraryLoader;

public class CheckEnv {
    public static void main(String[] args) {
        System.out.println("Library file name: "
                + LibraryLoader.selectPlatformFileName());
        System.out.println("Search paths:");
        for (var p : LibraryLoader.buildSearchPaths()) {
            System.out.println("  " + p);
        }

        try (var h = new lingofuse.DataHandle("probe")) {
            h.writeInt32(42);
            h.setPosition(0);
            System.out.println("Native call OK: read " + h.readInt32());
        } catch (Throwable t) {
            System.err.println("Native call failed: " + t);
        }
    }
}
```

---

# Chapter 29 — Performance characteristics

## 29.1 Current performance

- **single-machine IPC**: ~250 calls/s (32 threads concurrent).
- **the C# / C++ bindings**: ~1500 calls/s.
- **the Python binding**: ~200 calls/s.

**The Java binding currently performs below C# / C++**. The reasons:

1. FFM's `MethodHandle.invokeWithArguments` performs type adaptation on every call.
2. Every call creates an `Arena.ofConfined()`, which is a significant allocation cost.
3. Jackson's JSON serialization is comparatively heavy.

## 29.2 Performance optimization directions (planned)

| Optimization | Expected gain |
|------|---------|
| `invokeExact` instead of `invokeWithArguments` | 2-3x |
| `Arena` reuse | 1.5-2x |
| JSON serialization caching | 1.2-1.5x |
| **total** | **target 1500+ calls/s** |

## 29.3 Performance monitoring

```java
AsyncBridge bridge = AsyncBridge.instance();
Map<String, Object> stats = bridge.stats();
System.out.println("live ops: " + stats.get("total"));
System.out.println("pending: " + stats.get("pending"));
System.out.println("released_total: " + stats.get("released_total"));
```

**The key metrics**:

- a `pending` count that never drops = some op is stuck.
- `not_queued` rising steadily = a systemic dispatch failure.
- the growth rate of `released_total` = the op processing throughput.

## 29.4 Advice for improving throughput

1. **use permanent handles as request templates**: `DataHandle.createPermanent` once, then reuse.
2. **use the async API rather than the synchronous one**: `callFuture` does not block the calling
   thread.
3. **batch notifications**: one `notify` sends one message; consider merging high-frequency ones.
4. **sensible timeouts**: the 3-second default is too long on a LAN; you can drop to 1 second.
5. **choose the addressing mode**:
   - App name (local-first): the fastest.
   - P2PName: one extra server-side forward.
   - UID: the same as the App name.

---

# Chapter 30 — Known limitations

| Limitation | Notes | Workaround |
|------|------|---------|
| **JDK 22+ required** | 8 / 11 / 17 / 21 are unsupported | upgrade the JDK |
| **64-bit only** | 32-bit platforms are unsupported | use a 64-bit JVM |
| **performance not optimized** | ~250 calls/s | see Chapter 29 |
| **no Java modularization** | no `module-info.java` is provided | use `--enable-native-access=ALL-UNNAMED` |
| **no high-level interface** | only low-level APIs today; no `LingoFuseApp` / `LingoFuseClient` | combine `AppHandle` + `Framework` |
| **no SLF4J integration** | callback errors go to stderr by default | install `setCallbackErrorHandler` |
| **async has no cancellation on timeout** | the C-side request is not cancelled | use a higher-level abandon / retry strategy |
| **no back-pressure** | async calls have no flow control | control concurrency yourself in the application layer |
| **P2PName routing has no local-first** | it forwards even when the caller is in the group | accept this design |

---

# Appendix A — Complete API index

## A.1 The C ABI exports (59)

**Data handle (12)**: `LF_CreateData`、`LF_CreateData_Permanent`、`LF_FreeData`、`LF_GetBuffer`、`LF_WriteBuffer`、`LF_ReadBuffer`、`LF_GetPos`、`LF_SetPos`、`LF_GetSize`、`LF_SetSize`、`LF_Get_P2P_UID`、`LF_Get_P2P_Name`

**App handle (5)**: `LF_CreateApp`、`LF_FreeApp`、`LF_Generate_AppName`、`LF_Get_AppName`、`LF_BindApp`

**Registration, app-bound (3)**: `LF_RegisterCall`、`LF_RegisterNotify`、`LF_Unregister`

**Registration, process-wide P2P (3)**: `LF_Register_P2P_Call`、`LF_Register_P2P_Notify`、`LF_Unregister_P2P`

**Local execution (2)**: `LF_LocalCall`、`LF_LocalNotify`

**Network preparation (5)**: `LF_PrepareService`、`LF_PrepareClient`、`LF_ResetPrepare`、`LF_PrepareDone`、`LF_ExitMainThread`

**Remote invocation, app-name (5)**: `LF_Call`、`LF_Async_Call`、`LF_Async_Sequenced_Call`、`LF_Notify`、`LF_Sequenced_Notify`

**Remote invocation, UID (5)**: `LF_UID_Call`、`LF_UID_Async_Call`、`LF_UID_Async_Sequenced_Call`、`LF_UID_Notify`、`LF_UID_Sequenced_Notify`

**Remote invocation, P2PName (5)**: `LF_P2PNAME_Call`、`LF_P2PNAME_Async_Call`、`LF_P2PNAME_Async_Sequenced_Call`、`LF_P2PNAME_Notify`、`LF_P2PNAME_Sequenced_Notify`

**Queries (7)**: `LF_CheckMainThread`、`LF_CheckApp`、`LF_CheckApi`、`LF_Check_UID`、`LF_Check_UID_Api`、`LF_Check_P2PNAME`、`LF_Check_P2PNAME_Api`

**Options (2)**: `LF_SetOption`、`LF_GetOption`

**Status (3)**: `LF_GetStatusCount`、`LF_GetStatus`、`LF_PostStatus`

**Network events (1)**: `LF_Set_Network_Event`

**Shutdown (1)**: `LF_Shutdown`

## A.2 The Java-side type quick reference

| Type | Purpose |
|------|------|
| `DataHandle` | the RAII data handle |
| `AppHandle` | the RAII application handle |
| `Framework` | the process-level facade |
| `LfIo` | uniform JSON / string I/O |
| `Options` | 16 typed option pairs |
| `P2PRegistry` | process-level P2P registration |
| `NetworkEvents` | global network events |
| `LingoFuseStatus` | the status queue + health checks |
| `address.Target` / `AppTarget` / `UIDTarget` / `P2PNameTarget` | the three addressing modes |
| `async.AsyncBridge` / `AsyncOp` / `AsyncSupport` / `CallFuture` | the async subsystem |
| `errors.LingoFuseException` and friends | the 5 exception types |

---

# Appendix B — Wire protocol byte-level examples

## B.1 The complete bytes of a Call request

**The Java side**:

```java
try (DataHandle req = new DataHandle("add")) {
    req.writeInt32(5);
    req.writeInt32(7);
    Framework.call("Calculator", req, 3000);
}
```

**What goes on the wire**:

```
[4-byte length LE = 0x0A = 10]
[the API name "add" UTF-8 + NUL: 61 64 64 00]
[8-byte buffer size LE = 8]
[buffer content: 05 00 00 00 07 00 00 00]
```

**The `input` handle the server receives**:

- the API name: `"add"`
- the buffer: 8 bytes
- the cursor at 0
- `readInt32()` → 5, the cursor moves to 4
- `readInt32()` → 7, the cursor moves to 8

## B.2 The complete bytes of a Call response

**The server**:

```java
output.writeInt32(12);
```

**What is returned on the wire**:

```
[4-byte length LE]
[the API name UTF-8 + NUL]
[8-byte buffer size LE = 4]
[buffer content: 0C 00 00 00]
```

**The client**:

- `response.size()` → 4
- `response.readInt32()` → 12

## B.3 A JSON payload example

**The Java side**:

```java
LfIo.writeJson(hnd, Map.of("name", "张三", "age", 30));
```

**The wire bytes**:

```
7B 22 6E 61 6D 65 22 3A 22 E5 BC A0 E4 B8 89 22 2C
22 61 67 65 22 3A 33 30 7D 00
```

**Decomposed**:

- `7B` → `{`
- `22 6E 61 6D 65 22` → `"name"`
- `3A` → `:`
- `22` → `"`
- `E5 BC A0 E4 B8 89` → 张三 (the UTF-8 literal, **not** `\u5F20\u4E09`)
- `22 2C` → `",`
- `22 61 67 65 22` → `"age"`
- `3A 33 30` → `:30`
- `7D` → `}`
- `00` → NUL

## B.4 The UID wire representation

**A 32-byte UID `0102030405060708090A0B0C0D0E0F10...2021`** is, on the wire, exactly:

```
01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10
11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20
21
```

**No length prefix, no NUL**. A UID is a fixed 32 bytes.

---

# Appendix C — Cross-language comparison

## C.1 Core type mapping

| Function | Java | Python | C++ | C# | Pascal | JS |
|------|------|--------|-----|----|--------|-----|
| DataHandle | `DataHandle` | `DataHandle` | `lingofuse::DataHandle` | `DataHandle` | `LF_CreateData*` | `DataHandle` |
| AppHandle | `AppHandle` | `App` | `lingofuse::App` | `AppHandle` | `LF_CreateApp` | `AppHandle` |
| JSON I/O | `LfIo` | `lf_io` | `lf_io.hpp` | `LfIo` | `LF_WriteString` | `lf.io` |
| remote call (App) | `AppTarget.call` | `client.call` | `lingofuse::call` | `Framework.Call` | `LF_Call` | `framework.call` |
| remote call (UID) | `UIDTarget.call` | `client.uid().call` | — | — | `LF_UID_Call` | — |
| remote call (P2PName) | `P2PNameTarget.call` | `client.p2pname().call` | — | — | `LF_P2PNAME_Call` | — |
| async call | `callAsync` / `callFuture` | `call_future` | — | — | `LF_Async_Call` | — |
| process-level P2P | `P2PRegistry` | `register_p2p_call` | — | — | `LF_Register_P2P_Call` | — |
| typed options | `Options` | `set_opt_*` / `get_opt_*` | — | — | `LF_Set_Opt_*` | — |
| permanent handle | `createPermanent` | `create_permanent` | `createPermanent` | `CreatePermanent` | `LF_CreateData_Permanent` | `createPermanent` |
| Side data | `getP2pUid` / `getP2pName` | `get_p2p_uid` / `get_p2p_name` | — | — | `LF_Get_P2P_UID` | — |

## C.2 The three-layer wire contract

**Layer 1 — byte order and string frames**:

- integers: **little-endian** (every language)
- strings: **UTF-8 + NUL**
- fixed-length fields (UID): **a raw 32-byte array with no length prefix**

**Layer 2 — JSON serialization**:

- **compact**: no indentation, no newlines
- **literal UTF-8**: no `\uXXXX` escapes
- **uniform policy**: every language uses the same JSON library configuration

**Layer 3 — call semantics**:

- **Call**: request-response, synchronous and blocking
- **Notify**: one-way notification, no ordering guarantee
- **Sequenced_Notify**: one-way notification, FIFO within the same `(target, api)` pair
- **Call timeout**: returns a **size=0 handle**, not NULL
- **async callback**: runs on a native worker thread

## C.3 The cross-language interop checklist

When two bindings in different languages need to interoperate, verify item by item:

- [ ] identical integer encoding (little-endian)
- [ ] identical string frames (UTF-8 + NUL)
- [ ] identical UID format (a raw 32-byte array)
- [ ] identical JSON serialization (compact, no `\uXXXX`)
- [ ] identical Call timeout semantics (size=0 rather than NULL)
- [ ] identical async callback ownership rules (the framework owns `Result_`)
- [ ] identical side data injection point (the head of the payload)
- [ ] identical callback threading model (worker threads)

**The Java binding has verified all of these** (see `TestLfIoRepairPaths` in `test_lingofuse.py` and
`jsonWireBytesMatchContract` in `test_lingofuse.cpp`).

## C.4 The Java-private mechanism list (no wire intrusion)

The following Java mechanisms **are all Java-private** and change no byte on the wire:

| Mechanism | Scope | Intrudes on the wire |
|------|--------|:------------:|
| `ReentrantReadWriteLock` | serializing reads and writes on a single handle | ❌ |
| `ArenaReaper` | deferred release of stub native memory | ❌ |
| `AsyncBridge` / `AsyncOp` | the async state machine | ❌ |
| `CallFuture` / `abandoned()` | Future semantics | ❌ |
| the stderr sink of `reportCallbackError` | local logging | ❌ |
| `MAX_C_STRING_LENGTH = 1MB` | the local read bound | ❌ |
| zeroing the UID buffer before close | local memory hygiene | ❌ |
| the JVM shutdown hook | process exit timing | ❌ |
| the `withHandle` lock | Java-side synchronization | ❌ |

**The red line**: any future change to a Java-private mechanism **must not alter the byte sequence,
the parameter order or the semantics on the wire**. That is the absolute bottom line for
cross-language interop.

---

*Document version: the LingoFuse Java binding knowledge base*
*Coverage: 59 C ABI symbols, 145 tests, 4 demos, 10+ cross-language bindings*
*This document is the authoritative reference for every Java / JVM developer using LingoFuse.*

