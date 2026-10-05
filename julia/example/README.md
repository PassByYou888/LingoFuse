# LingoFuse Julia Binding — Cross Demo

This directory contains the Julia implementation of the standard
LingoFuse **Cross Demo**: three cooperating processes that exercise
the full RPC mesh end to end, using the raw binary channel (no JSON).

The wire format is byte-for-byte identical to the C++, C#, Pascal,
Python, and JavaScript Cross Demos. A Julia `CrossNode` can be driven
by a `CrossCall` written in any of those languages, and a Julia
`CrossCall` can drive a `CrossNode` written in any of them.

---

## 1. The Three Programs

| Program | Role | Registered APIs |
|---------|------|-----------------|
| `CrossService.jl` | **Beacon** — IPC discovery anchor. Registers no API. | — |
| `CrossNode.jl`    | **Worker** — serves the `demo` application. | `add`, `inv_seri` |
| `CrossCall.jl`    | **Load tester** — 8 concurrent tasks hammering `demo`. | — |

### Wire contracts

Both APIs use raw little-endian binary, not JSON.

**`add(int32 a, int32 b) -> int32`**

```
request  : [int32 a] [int32 b]              (8 bytes)
response : [int32 a + b]                    (4 bytes)
```

**`inv_seri(uint8, uint16, uint32, uint64, string, float32) -> reversed`**

```
request  : [uint8] [uint16] [uint32] [uint64] [UTF-8 string + NUL] [float32]
response : [float32] [UTF-8 string + NUL] [uint64] [uint32] [uint16] [uint8]
```

Every integer is little-endian. The `string` field is NUL-terminated
in the standard LingoFuse wire convention. Both layouts match the
`CrossNode.cpp` handlers exactly.

---

## 2. Prerequisites

- The C shim must be built: run `..\build.ps1` from the `julia/`
  directory. This produces:

  ```
  c_ext\real\lf_shim_real.dll
  ```

- The LingoFuse runtime (`LingoFuse64.dll`, `z_ipc_64.dll`) must be
  discoverable. Either put the runtime directory on `PATH`, or set
  `LINGOFUSE_LIBRARY` to the full DLL path.

- **Every** Julia process that runs a Cross demo must be started with
  `--threads=2` (or more). The callback consumer runs on a dedicated
  Julia thread and the runtime refuses to start otherwise.

---

## 3. Running the Demo

Open **three** terminals in the `julia/` directory. Start the
programs in the order shown below and wait for each to print its
readiness banner before starting the next.

### Terminal 1 — Beacon

```powershell
julia --threads=2 example\CrossService.jl
```

Expected output:

```
=== Cross Service (Coordinator) ===
[Service] Prepared service endpoint ipc:cross (tag=1)
[Service] Prepared self-client (tag=2)
IPC service 'ipc:cross' is running. Press Enter to exit...
```

### Terminal 2 — Worker

```powershell
julia --threads=2 example\CrossNode.jl
```

Expected output:

```
=== Cross Node (Worker) ===
[Node] Registered APIs 'add' and 'inv_seri' under application 'demo'.
[Node] Online. Press Enter to exit...
```

### Terminal 3 — Load tester

```powershell
julia --threads=2 example\CrossCall.jl
```

The call generator runs a 10-second load test, then prints a summary
and waits for Enter:

```
=== Cross Call (Client) ===
[Call] Connected to ipc:cross.
[Call] Starting 10-second load test with 8 tasks...
[Call] Load test summary
         duration          : 10.02 s
         total calls       : ...
         success           : ... (...)
         failed            : ...
         add calls         : ...
         inv_seri calls    : ...
         throughput        : ... calls/s
         success throughput: ... calls/s
```

### Shutting down

Press **Enter** in Terminal 3, then Terminal 2, then Terminal 1.
Each process prints a short shutdown banner and exits with status 0.

---

## 4. Concurrency and `UV_THREADPOOL_SIZE`

`LF_Call` is dispatched through Julia's `@threadcall`, so every
in-flight call consumes one **libuv worker thread** for the duration
of the underlying native call. libuv's default thread pool size is
**4**.

With 8 Julia tasks and the default pool, at most 4 calls can be in
flight at once; the remaining tasks queue inside libuv. This is a
Julia runtime property, not a LingoFuse binding property — the C++
and C# demos use one native thread per call and therefore reach
higher concurrency on the same hardware.

To raise the pool size, set `UV_THREADPOOL_SIZE` **before Julia
starts**:

```powershell
$env:UV_THREADPOOL_SIZE = "32"
julia --threads=2 example\CrossCall.jl
```

The default `WORKER_TASKS = 8` keeps the queue shallow and the
throughput stable. Increase it after raising the pool size.

---

## 5. Cross-Language Interop

Any of the three roles can be replaced by another language's Cross
demo without changing the other two. For example:

```
Terminal 1  : pascal\cross_demo\CrossService      (Pascal beacon)
Terminal 2  : julia\example\CrossNode.jl          (Julia worker)
Terminal 3  : cpp\CrossDemo\CrossCall             (C++ load tester)
```

The three processes agree only on:

- the IPC endpoint name (`ipc:cross`),
- the application name (`demo`),
- the two API names (`add`, `inv_seri`),
- the raw byte layouts documented in §1.

No configuration file, no IDL, no code generation.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `LingoFuseLoadError: ... not found` | `LingoFuse64.dll` not on `PATH` | Add `Binary\` to `PATH` or set `LINGOFUSE_LIBRARY` |
| `LingoFuseLoadError: C callback shim not found` | `lf_shim_real.dll` missing | Run `..\build.ps1` |
| `LingoFuseStateError: ... requires at least 2 Julia threads` | Julia started without `--threads=2` | Restart with `julia --threads=2 ...` |
| Worker prints `[FATAL] prepare_client returned -1` | Endpoint address already in use | Make sure no other process is bound to `ipc:cross`; restart the beacon |
| `[Call] target app 'demo' did not become visible` | Worker did not register in time | Start the worker **before** the caller; wait for `[Node] Online` |
| Call summary shows high `failed` count | `UV_THREADPOOL_SIZE` too small for the task count | Raise the pool size and rerun |

Set `$env:LINGOFUSE_TRACE = "1"` to enable step-by-step tracing on
stderr. Set `$env:LINGOFUSE_TRACE = "0"` (the default) to disable it.

---

## 7. See Also

- `..\c_ext\SHIM_MECHANISM_GUIDE.md` — the C shim mechanism, the
  threading contract, and the design rules that every Julia caller
  must obey.
- `..\test\` — the acceptance test suite (`..\test.ps1`).
- `..\src\` — the binding source.
