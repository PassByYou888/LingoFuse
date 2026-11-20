# LingoFuse Pascal Development Kit

> Chinese version: [readme.md](readme.md)

> **The official Pascal binding of LingoFuse, plus the full test suite, stress suite, cross-language demos and HTTP Bridge integration testing.**
>
> This directory is the single starting point for Pascal developers using LingoFuse. After reading this README you will know:
> - what the Pascal binding actually covers;
> - what each `.lpr` / `.pas` file is for;
> - which to run first and which next;
> - where the common pitfalls are.

---

## 1. Bottom line: how complete the Pascal support is

LingoFuse's Pascal support is a complete closed loop — **not merely "the samples run", but a production-grade binding**.

| Dimension | Status | Notes |
|------|:----:|------|
| C ABI import | ✅ Complete | `lingofuse_import.pas` imports every core export, with function-level English comments |
| RAII high-level wrapper | ✅ Complete | `lingofuse_helper.pas` provides `TDataHandle` / `TAppHandle` / `LF` |
| Data handle read/write | ✅ Complete | integers, floats, strings, byte streams, position/size |
| Local Call / Notify | ✅ Complete | covered by `fpc_tester_for_LingoFuse` |
| IPC / TCP remote calls | ✅ Complete | covered by unit tests, stress tests, Cross / Compute / Sequence |
| Multithreaded concurrency | ✅ Complete | unit test 10×100; stress test 50×20 |
| Performance stress test | ✅ Complete | `LingoFuseBenchServer` + `LingoFuseBenchClient` |
| API functional verification | ✅ Complete | `LingoFuseBench_API_Check` validates API by API |
| Sequenced notify / large-data sharding | ✅ Complete | `SequenceData/` with 10 MB shards + MD5 |
| Distributed load balancing | ✅ Complete | `cross_demo/`, including a GUI node |
| Compute grid | ✅ Complete | `Compute_Grid_Demo/` |
| HTTP Bridge client | ✅ Complete | `lf_http_bridge_client.pas` + `bridge/` |
| JSON cross-language exchange | ✅ Complete | Bench, Bridge Compute and Bridge Test are all JSON |
| Resource-leak detection | ✅ Covered | the unit test creates/frees 10000 handles in bulk |
| Duplicate registration detection | ✅ Covered | verified by the unit test |
| UTF-8 / Chinese / Emoji | ✅ Covered | the unit test includes Chinese App/API names plus Emoji |
| Delphi samples | ✅ Present | `EasyCS_Demo/` holds Delphi `.dpr` / `.dproj` files |
| One-command build scripts | ✅ Present | every demo directory has `build.bat` / `clear_.bat` |
| Network-event demo | ⚠️ API complete, no dedicated demo | see `LingoFuse_Pascal_Complete_Guide.md` |
| CI | ⚠️ C++ only | Pascal relies on locally runnable programs |

**In one sentence: Pascal is not a token binding but a full member of LingoFuse's nine first-party language bindings.**

---

## 2. Directory layout

```text
pascal/
│   build_demo.bat                              # top-level one-command build script
│   clear_.bat                                  # top-level cleanup script
│
│   lingofuse_import.pas                        # low-level C ABI import (function-level comments)
│   lingofuse_helper.pas                        # high-level RAII wrapper
│   lf_http_bridge_client.pas                   # Pascal client library for the HTTP Bridge
│   pascal_agent_service_unit.pas               # sample Pascal Agent service unit
│
│   fpc_tester_for_LingoFuse.lpr / .lpi         # comprehensive unit test
│   LingoFuseBenchServer.lpr / .lpi             # 20-API stress test server
│   LingoFuseBenchClient.lpr / .lpi             # multithreaded concurrency stress client
│   LingoFuseBenchClient_Run_as_10X.bat         # launch 10 stress clients in one click
│   LingoFuseBench_API_Check.lpr / .lpi         # 20-API functional verification tool
│
│   LingoFuse_Pascal_Complete_Guide.md          # complete guide + pitfall knowledge base v3.0
│   readme.md                                   # this file
│
├── bridge/                                     # HTTP Bridge integration demo
│   ├── bridge_service.lpr / .lpi               #   beacon
│   ├── bridge_compute.lpr / .lpi               #   Pascal JSON compute node
│   ├── test_bridge_via_lf.lpr / .lpi           #   Pascal-side integration test
│   ├── web_demo.html                           #   browser demo page
│   ├── Pascal Service Guide for ... .md        #   Bridge development guide
│   └── build.bat / clear_.bat
│
├── cross_demo/                                 # cross-language load-balancing demo
│   ├── cross_service.lpr / .lpi                #   registry
│   ├── cross_node.lpr / .lpi                   #   compute node (console)
│   ├── cross_node_ui.lpr / .lpi / .res / .ico  #   compute node (LCL GUI)
│   ├── cross_node_ui_frm.pas / .lfm            #   GUI form
│   ├── cross_call.lpr / .lpi                   #   caller
│   ├── cross_call_run_20x.bat                  #   launch 20 callers in one click
│   └── build.bat / clear_.bat
│
├── Compute_Grid_Demo/                          # distributed compute-grid demo
│   ├── compute_service.lpr / .lpi              #   registry
│   ├── compute_node.lpr / .lpi                 #   expression-evaluation node
│   ├── compute_call.lpr / .lpi                 #   caller
│   ├── compute_call_run_20x.bat                #   launch 20 callers in one click
│   ├── compute_node_run_10x.bat                #   launch 10 nodes in one click
│   └── build.bat / clear_.bat
│
├── SequenceData/                               # sequenced notify / large-data sharding
│   ├── sequence_serv.lpr / .lpi                #   server
│   ├── sequence_cli.lpr / .lpi                 #   10 MB sharded client
│   └── build.bat / clear_.bat
│
├── EasyCS_Demo/                                # minimal Delphi C/S sample
│   ├── EasyServer.dpr / .dproj / .res
│   ├── EasyClient.dpr / .dproj / .res
│   └── EasyCS.groupproj
│
└── zNetV2/                                     # underlying communication framework source (submodule dependency)
```

---

## 3. The core binding layer

### 3.1 `lingofuse_import.pas` — low-level C ABI import

**Responsibilities:**

- imports `LingoFuse64.dll` / `LingoFuse32.dll` / `liblingofuse.so` / `liblingofuse.dylib`.
- defines `TDataHnd___`, `TAppHnd___`, `TLF_Call_Event`, `TLF_Notify_Event`, `TLF_Network_Event`.
- provides every `LF_*` function: data handles, app handles, registration, local calls, network preparation, remote calls, status, options, shutdown.
- provides Pascal convenience wrappers: `LF_CreateDataEx`, `LF_CreateAppEx`, `LF_CallEx`, `LF_WriteString`, `LF_ReadString` and so on.
- provides object-method callback adapters: `LF_RegisterCall_M` / `LF_RegisterSyncCall_M` and so on, implemented internally with `LF_EventPool` + `TSoft_Synchronize_Tool`.

**Key contracts:**

- callbacks must be `cdecl`, otherwise the stack gets corrupted.
- callbacks must not call `LF_Call` / `LF_LocalCall` / `LF_Notify` / `LF_PrepareDone` / `LF_Shutdown`, otherwise they deadlock.
- `LF_FreeData` has a no-op window: before `LF_PrepareDone` or after `LF_ExitMainThread`.
- pointers returned by `LF_Generate_AppName` / `LF_Get_AppName` are valid for only about 5 seconds.
- network-event callbacks run on a **background TCompute worker thread**, and `addr_` becomes invalid as soon as the callback returns.

### 3.2 `lingofuse_helper.pas` — high-level RAII wrapper

| Type | Purpose |
|------|------|
| `LF.TDataHandle` | wraps a `TDataHnd`, auto-frees, supports chained reads/writes |
| `LF.TAppHandle` | wraps a `TAppHnd`, registers Call/Notify, local calls, binding |
| `LF` | static class: `PrepareService` / `PrepareClient` / `PrepareDone` / `CallApp` / `NotifyApp` / `Shutdown` |
| `LF___` | compatibility class mirroring the low-level `LF_*` static methods |

`TDataHandle` covers:

- `WriteInt8/16/32/64`, `WriteUInt8/16/32/64`, `WriteSingle/Double`
- `WriteString` / `WriteStringNullTerminated` / `WriteStringBytes`
- `ReadInt8/16/32/64`, `ReadUInt8/16/32/64`, `ReadSingle/Double`
- `ReadString` / `ReadStringNullTerminated` / `ReadStringBytes`
- `GetPos/SetPos/GetSize/SetSize/GetBuffer/GetBufferEx`

`TAppHandle` covers:

- `RegisterCall` / `RegisterCallSync`
- `RegisterNotify` / `RegisterNotifySync`
- `Unregister`
- `LocalCall` / `LocalNotify`
- `Bind`

### 3.3 `lf_http_bridge_client.pas` — HTTP Bridge client library

**This is not a program, it is a library.** It assumes the caller has already established its own LingoFuse connection.

Four API layers:

| Layer | Function | Purpose |
|------|------|------|
| Top | `LFHttpPostBody` | only the remote HTTP response body |
| Middle | `LFHttpPost` | the full envelope: `status_code` / `headers` / `body` |
| Bottom | `LFHttpCall` | custom method / headers / timeout |
| JSON repair | `LFHttpRepairJson` | calls the Bridge's JSON repair service |

Global configuration variables:

```pascal
LFBridgeAppName               = '__lf_http_bridge__';
LFBridgeApiName               = '__lf_outbound_post__';
LFBridgeRepairApiName         = '__lf_repair_json__';
LFBridgeTimeoutMs             = 60000;
LFBridgeDefaultHttpTimeoutSec = 25.0;
```

**Key contracts:**

- `LFBridgeTimeoutMs` must exceed the HTTP timeout; at least 5 seconds more is recommended.
- the Bridge returns an envelope; the real remote response is inside `body`.
- the JSON repair API returns a plain string (no envelope).
- unrepairable input comes back unchanged, so callers must compare input and output to tell whether it was modified.

### 3.4 `pascal_agent_service_unit.pas`

A sample Pascal Agent service unit. It shows how to register an Agent service as a LingoFuse App so other languages can call it through LingoFuse / the HTTP Bridge. Well suited to agent scenarios.

---

## 4. Comprehensive unit test

### `fpc_tester_for_LingoFuse.lpr`

**Role: environment acceptance + functional regression + concurrency/performance/leak checks.**

Coverage:

| Test item | Content | What is verified |
|--------|------|--------|
| Data handle basic read/write | every integer, float and string written chained then read back | types and values are correct |
| Position/size | `SetPos` / `GetPos` / `SetSize` / `GetSize` | behaviour matches expectations |
| Buffer pointer | `GetBuffer` | returns a valid pointer |
| Local Call | `add` / `echo` | local calls are correct |
| Local Notify | `print` | the callback fires |
| IPC / TCP remote | `ipc:test_svc`, `127.0.0.1:9988` | remote Call / Notify are correct |
| Unknown API | call a nonexistent API | returns size 0 |
| Concurrency | 10 threads × 100 iterations | all succeed with correct results |
| Performance | 1000 sequential local calls | prints calls/sec |
| Resource leaks | create/free 10000 handles in bulk | no crash, all freed |
| Duplicate registration | register the same API name twice | the second attempt fails |
| UTF-8 | Chinese App name, Chinese API name, Emoji | registration and calls are correct |

**Prerequisites:**

- the LingoFuse dynamic library is in place;
- `zNetV2/source` is on the unit search path;
- recommended as the first step of environment acceptance.

```bash
lazbuild -B fpc_tester_for_LingoFuse.lpi
```

---

## 5. Stress test suite

### 5.1 `LingoFuseBenchServer.lpr` — 20-API stress test server

Registered APIs (application name `BenchServer`):

| Category | API |
|------|-----|
| Arithmetic | `add`, `sub`, `mul`, `div` |
| Expression | `eval` |
| Hashing | `md5`, `sha1`, `sha256`, `sha512` |
| Encryption simulation | `aes_encrypt`, `aes_decrypt` |
| Encoding | `base64_encode`, `base64_decode` |
| Random | `random` |
| Strings | `upper`, `lower`, `reverse` |
| Utilities | `timestamp`, `sleep`, `echo` |

**Characteristics:**

- every API takes JSON requests and returns JSON responses, so it is cross-language compatible.
- it listens on both IPC and TCP:
  - `ipc:bench_service`
  - `127.0.0.1:9898`

### 5.2 `LingoFuseBenchClient.lpr` — multithreaded stress client

**Default configuration:**

- 50 threads × 20 iterations = 1000 calls
- round-robin over 20 APIs
- IPC endpoint `ipc:bench_service`
- 10-second timeout

**Output:** total calls / successes / failures / success rate / total elapsed / QPS / calls per API / average-min-max latency.

**Launch 10 at once:**

```bash
LingoFuseBenchClient_Run_as_10X.bat
```

### 5.3 `LingoFuseBench_API_Check.lpr` — API functional verification

Verifies the correctness of the 20 `BenchServer` APIs one by one, printing `[passed]` / `[failed]`.

Good for: regression after changing the server, cross-language protocol alignment, and a quick confirmation of the dynamic library + IPC + JSON chain.

---

## 6. Cross-language load-balancing demo

Directory: `cross_demo/`

| Program | Role |
|------|------|
| `cross_service.lpr` | registry / beacon, listening on `ipc:cross` |
| `cross_node.lpr` | compute node registering the `demo` application (`add` / `inv_seri`) |
| `cross_call.lpr` | caller, repeatedly invoking `demo.add` / `demo.inv_seri` |
| `cross_node_ui.lpr` | LCL GUI node (loads `cross_node_ui_frm`) |

**Startup order:**

1. `cross_service`
2. start N `cross_node` instances
3. start M `cross_call` instances

**Launch 20 callers at once:**

```bash
cross_demo\cross_call_run_20x.bat
```

**Effect:**

- callers never need to know a specific node address; the C4 mesh discovers nodes and balances load automatically.
- start several nodes and watch requests spread evenly.

**Key source points:**

- `cross_node` uses `LF_SetOptionEx('Wait_Ready', 'False')` to enter deployment mode, so it can start before the server.
- `add` uses binary integer read/write.
- `inv_seri` demonstrates mixed-type serialization: `UInt8 / UInt16 / UInt32 / UInt64 / string / Single`.

---

## 7. Distributed compute-grid demo

Directory: `Compute_Grid_Demo/`

| Program | Role |
|------|------|
| `compute_service.lpr` | registry, listening on `ipc:compute_grid` |
| `compute_node.lpr` | compute node registering `exp` of the `pas` application |
| `compute_call.lpr` | caller, continuously sending expression-evaluation requests |

**Batch launch:**

```bash
Compute_Grid_Demo\compute_node_run_10x.bat   # start 10 nodes
Compute_Grid_Demo\compute_call_run_20x.bat   # start 20 callers
```

**Characteristics:**

- nodes use `Wait_Ready=False`, so they can start in any order.
- `compute_node` evaluates expressions with the Z expression engine.
- demonstrates "automatic load balancing across several nodes of the same App".

---

## 8. Sequenced notify and large-data sharding demo

Directory: `SequenceData/`

| Program | Role |
|------|------|
| `sequence_serv.lpr` | server: registers `BeginData` / `Data` / `EndData` |
| `sequence_cli.lpr` | client: generates 10 MB of random data and sends it in shards |

**Protocol flow:**

```text
BeginData               -> returns a SessionID
Data(SessionID, Index, Chunk) x N
EndData(SessionID, TotalCount)
```

**Server mechanism:**

- `TSequPool` collects the shards of one session;
- `Safe_Pointer` prevents clients from forging pointers;
- `FLast_Update` reclaims on timeout: 5 seconds of inactivity counts as a failure;
- `EndData` triggers a background thread: wait for all shards → sort → concatenate → MD5.

**Client mechanism:**

- generate 10 MB of random data;
- shard in 1536-byte pieces;
- send `Data` with `LF_NotifyEx`;
- can simulate dirty data / disconnection to watch the server reclaim automatically.

**What it demonstrates:** Notify reliability in large-data sharding scenarios, the Session + Index + MD5 verification pattern, and the server's wild-pointer protection plus timeout reclamation.

---

## 9. HTTP Bridge and JSON bridging demo

Directory: `bridge/`

| File | Purpose |
|------|------|
| `bridge_service.lpr` | beacon, listening on `ipc:compute_grid` |
| `bridge_compute.lpr` | Pascal compute node registering `pas.exp`, JSON in and out |
| `test_bridge_via_lf.lpr` | integration test calling the Bridge through LingoFuse |
| `web_demo.html` | browser demo page |
| `Pascal Service Guide for LingoFuse HTTP Bridge (bridge.py).md` | Bridge development guide |

The Pascal-side client library is at the top level: `lf_http_bridge_client.pas`.

### 9.1 `bridge_compute.lpr`

- application name `pas`, API `exp`.
- input JSON: `{"args":["1+2*3"]}`
- output JSON: `{"code":0,"result":"7"}`
- reads UTF-8 JSON with `LF_ReadStringBytes`.
- parses the root JSON with `TZ_JsonObject.Parae`.
- returns with `LF_WriteStringBytes(Output, resObj.ToBytes)`.

### 9.2 `test_bridge_via_lf.lpr`

**Call chain:**

```text
Pascal test program
  -> LF_Call(__lf_http_bridge__ . __lf_outbound_post__)
  -> bridge.py outbound handler
  -> HTTP POST http://127.0.0.1:8081/pas/exp
  -> bridge.py inbound handler
  -> LF_Call(pas . exp)
  -> bridge_compute
  -> the result returns along the same path
```

**Built-in test expressions:** `1+2*3`, `(10+20)/2`, `2^8`, `sin(3.14/2)`, `sqrt(144)`, `5!`, `1/0`.

**Prerequisites:**

1. `bridge_service` running on `ipc:compute_grid`;
2. `bridge_compute` has registered `pas.exp`;
3. `bridge.py` running with `--endpoint ipc:compute_grid`.

---

## 10. Minimal Delphi C/S sample

Directory: `EasyCS_Demo/`

| File | Description |
|------|------|
| `EasyServer.dpr` / `.dproj` | Delphi server project |
| `EasyClient.dpr` / `.dproj` | Delphi client project |
| `EasyCS.groupproj` | Delphi project group |

Delphi users can simply open the `.groupproj` and build/run it in the IDE. This is the shortest path to LingoFuse from Delphi.

---

## 11. The dependency submodule `zNetV2/`

`zNetV2/` is LingoFuse's underlying dependency (the Z framework + C4 network engine + IPC).

Key subdirectories:

- `zNetV2/source/`: all `.pas` and `.inc` sources.
- `zNetV2/source/sec/`: a mirror copy (for old project paths).
- `zNetV2/binary/`: IPC and memory-allocator dynamic libraries.

**You must put `zNetV2/source` on the unit search path when building.**

---

## 12. Test coverage matrix

| Feature | Covering files |
|------|----------|
| Data handle basic types | `fpc_tester_for_LingoFuse` |
| Data handle position/size | `fpc_tester_for_LingoFuse` |
| Local Call | `fpc_tester_for_LingoFuse` |
| Local Notify | `fpc_tester_for_LingoFuse` |
| IPC remote | `fpc_tester`, Bench, Cross, Compute, Sequence |
| TCP remote | `fpc_tester`, `LingoFuseBenchServer` |
| Multithreaded concurrency | `fpc_tester`, `LingoFuseBenchClient` |
| Performance statistics | `fpc_tester`, `LingoFuseBenchClient` |
| Resource leaks | `fpc_tester` (10000 handles) |
| Duplicate registration | `fpc_tester` |
| UTF-8 / Chinese / Emoji | `fpc_tester` |
| JSON request/response | Bench, `bridge_compute`, `test_bridge_via_lf` |
| Sequenced notify | `SequenceData/` |
| Load balancing | `cross_demo/` |
| Compute grid | `Compute_Grid_Demo/` |
| HTTP Bridge | `bridge/` + `lf_http_bridge_client.pas` |
| Delphi integration | `EasyCS_Demo/` |
| Network events | API complete (import layer / guide), no dedicated demo |
| Permanent handles | API complete (import layer / Helper / guide) |
| Synchronous callbacks | API complete (import layer / Helper) |

---

## 13. Running and building

### 13.1 Prepare the dynamic libraries

Put the following libraries next to the executable or on the system `PATH`:

| Platform | Core library | IPC dependency |
|------|--------|----------|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` |

Windows also needs the VC++ 2015-2022 redistributable.

### 13.2 One-command build

Batch scripts are provided at the top level and in every demo directory:

```bat
build_demo.bat
clear_.bat

cross_demo\build.bat
Compute_Grid_Demo\build.bat
SequenceData\build.bat
bridge\build.bat
```

### 13.3 Building with `lazbuild`

```bash
lazbuild -B fpc_tester_for_LingoFuse.lpi
lazbuild -B LingoFuseBenchServer.lpi
lazbuild -B LingoFuseBenchClient.lpi
lazbuild -B LingoFuseBench_API_Check.lpi
```

### 13.4 Building with Delphi

Open `EasyCS_Demo\EasyCS.groupproj` and build directly in the Delphi IDE.

### 13.5 Recommended run order

**Environment acceptance:**

```bash
fpc_tester_for_LingoFuse
```

**Stress test:**

```bash
LingoFuseBenchServer
LingoFuseBench_API_Check       # or LingoFuseBenchClient
```

**Cross-language load balancing:**

```bash
cross_demo\cross_service
cross_demo\cross_node          # start N
cross_demo\cross_call          # start M
```

**Compute grid:**

```bash
Compute_Grid_Demo\compute_service
Compute_Grid_Demo\compute_node
Compute_Grid_Demo\compute_call
```

**Sequenced notify:**

```bash
SequenceData\sequence_serv
SequenceData\sequence_cli
```

**HTTP Bridge:**

```bash
bridge\bridge_service
bridge\bridge_compute
python bridge.py --endpoint ipc:compute_grid --app pas --port 8081
bridge\test_bridge_via_lf
```

---

## 14. Common pitfall quick reference

| # | Pitfall | Correct approach |
|:-:|-----|---------|
| 1 | callback not declared `cdecl` | always `cdecl` |
| 2 | calling a blocking LF function inside a callback | move it to a worker thread |
| 3 | forgetting `LF_FreeData` | free in a paired `try..finally` |
| 4 | wrong cleanup order | `ExitMainThread` → `FreeApp` → `Shutdown` |
| 5 | a second `LF_PrepareDone` returns 0 | that is by design; to restart, call `Shutdown` + `ResetPrepare` first |
| 6 | multiple Apps on the same address are silently ignored | set `Overlap_Connection=True` or use `BindApp` |
| 7 | treating a `LF_Call` timeout as nil | check `Size = 0` instead |
| 8 | calling `Parae` / `ParseText` on a child object | call them only on the root |
| 9 | routing JSON through `string` (AnsiString) | use `TZ_JsonString` + `.Bytes` |
| 10 | manipulating UI directly from a network-event callback | marshal with `TThread.Queue` |
| 11 | keeping `addr_` alive in a network-event callback | copy it to a `string` immediately |
| 12 | callbacks not pinned in managed languages | keep a strong reference in a static field |
| 13 | calling `LF_Generate_AppName` before `PrepareDone` | it must be called after |
| 14 | keeping the `LF_Generate_AppName` pointer longer than 5 seconds | copy it immediately |
| 15 | relying on automatic reclamation | call `LF_FreeData` explicitly; auto-reclamation is only a safety net |
| 16 | forgetting to free `LF_CreateData_Permanent` | permanent handles have no automatic reclamation |
| 17 | not calling `LF_Shutdown` explicitly in a DLL scenario | it must be called explicitly |

For details see `LingoFuse_Pascal_Complete_Guide.md` (v3.0 pitfall knowledge base, 57 IDs).

---

## 15. Working with AI

Every source file in this directory carries detailed English comments, so it can be **fed straight to an AI**:

1. `lingofuse_import.pas` — the C ABI contract, thread model, callback restrictions and pitfalls.
2. `lingofuse_helper.pas` — the RAII wrapper, handle ownership, callback lifetime.
3. every `.lpr` — runnable end-to-end examples.
4. `LingoFuse_Pascal_Complete_Guide.md` — the complete guide plus pitfall knowledge base.
5. `bridge/Pascal Service Guide for LingoFuse HTTP Bridge (bridge.py).md` — the Bridge development guide.

**Suggested usage:**

- have the AI read the header comments of `lingofuse_import.pas` → understand the contract.
- have the AI read `LingoFuse_Pascal_Complete_Guide.md` → master the pitfall list.
- have the AI produce a structured interface description → generate multi-language clients with a code generator.

---

## 16. Recommended reading order

1. the top comment of `lingofuse_import.pas` — understand the C ABI, thread model and callback restrictions.
2. the top comment of `lingofuse_helper.pas` — understand the RAII wrapper and handle ownership.
3. `fpc_tester_for_LingoFuse.lpr` — get the environment running.
4. `LingoFuseBenchServer.lpr` + `LingoFuseBench_API_Check.lpr` — verify the 20 APIs.
5. `LingoFuseBenchClient.lpr` — see concurrency and performance.
6. `cross_demo/` / `Compute_Grid_Demo/` / `SequenceData/` — understand distribution, load balancing and sequenced notify.
7. `bridge/` + `lf_http_bridge_client.pas` + `test_bridge_via_lf.lpr` — understand HTTP/JSON bridging.
8. `EasyCS_Demo/` — the minimal path in for Delphi users.

---

## 17. Frequently asked questions

**Q: Is the Pascal support reasonably complete?**
A: Yes. The import layer, RAII wrapper, unit tests, stress tests, API validation, cross-language demos, sequenced notify and HTTP Bridge all have runnable code.

**Q: Which one should I run first?**
A: Run `fpc_tester_for_LingoFuse` first to confirm the dynamic library, the Z framework path and the IPC/TCP environment.

**Q: How do I measure performance?**
A: Start `LingoFuseBenchServer`, then run `LingoFuseBenchClient` and look at QPS and per-API latency.

**Q: How do I check that all 20 APIs are correct?**
A: Start `LingoFuseBenchServer`, then run `LingoFuseBench_API_Check`.

**Q: How do I observe load balancing?**
A: Start `cross_service`, then several `cross_node` instances, then run `cross_call` and watch requests spread out.

**Q: How do I test ordered reassembly of large data?**
A: Start `sequence_serv`, then run `sequence_cli`. The client sends 10 MB in shards; the server sorts them and computes the MD5.

**Q: How do I expose a Pascal service to HTTP / browsers / PHP / Node?**
A: Use the `bridge/` demo: `bridge_service` + `bridge_compute` + `bridge.py`. On the Pascal side you can also call HTTP outbound with `lf_http_bridge_client.pas`.

**Q: Where does a Delphi user start?**
A: Open `EasyCS_Demo/EasyCS.groupproj` and build/run it in the Delphi IDE.

**Q: Does Pascal have CI?**
A: The GitHub CI currently covers C++ only. For Pascal, the runnable tests and demos in this directory are the standard; they must be built and run locally.

---

## 18. License

MIT. Use it freely, change it freely, even sell it.
