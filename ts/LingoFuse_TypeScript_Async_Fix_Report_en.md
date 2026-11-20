# LingoFuse TypeScript Binding — Async Fix Report

> Chinese version: [LingoFuse_TypeScript_Async_Fix_Report.md](LingoFuse_TypeScript_Async_Fix_Report.md)

**Version**: 1.0
**Date**: 2026-10-24
**Scope**: fix the async call path and Koffi callback resource management in `lingofuse-ts` so it behaves consistently with the C++ / C# / Pascal / JavaScript bindings
**Status**: v1 baseline 127/127 PASS, v2 tests 99/99 PASS, cross service+node+call end-to-end PASS

---

## 1. Background

The Node.js binding (`lingofuse-js` v2.0.0) failed every async call in the end-to-end tests. The fix report (`LingoFuse_JS_Async_Fix_Report.md`) already located four orthogonal bugs and fixed them on the JS side.

The TypeScript binding (`lingofuse-ts` v2.0.0) had its structure, type system, three addressing abstractions, exception hierarchy, UID dual roles and P2P side-data semantics all correct, but **layers L3–L5 replicated all four async bugs described in the JS fix report in full**, and **three additional Koffi callback resource-ordering problems** were not implemented in the corrected order either.

Consequences:

- every TS async integration test failed (`TimeoutError` or a 15-second hang)
- all `Target.call(...)` / `target.callAsync(...)` calls would fail in production code too
- long runs produced `TC40_LF_Client.Destroy remove P2P update error: Access violation`

The goal of this fix: **port the entire body of experience from the JS fix report to TS**, and complete the Koffi callback resource ordering.

---

## 2. The core issue list

### 2.1 The four async bugs ported from the JS fix report

| Bug | Name | JS fix reference | Where TS replicated it |
|-----|------|-------------|------------|
| **A** | the test race timer's `unref()` | `LingoFuse_JS_Async_Fix_Report.md` §Bug #1 | `test-v2.ts` runner |
| **B** | `param` disposed too early | §Bug #2 | `address.ts` `Target.call` / `sequencedCall` / `callAsync` / `sequencedCallAsync` |
| **C** | the `data` pointer passed as `null` | §Bug #3 | `async-support.ts` + `framework.ts` + `address.ts` |
| **D** | the JSON wire protocol is incompatible | §Bug #4 | `lf-io.ts` + `address.ts` + `framework.ts` |

### 2.2 The three additional Koffi callback resource-ordering problems

| Problem | Location | Consequence |
|------|------|------|
| **K1** | `network-events.ts` `setNetworkEvent` unregisters the old one before installing the new one | during the window, native calls an already-freed trampoline → segfault |
| **K2** | `app-handle.ts` `dispose` unregisters before `LF_FreeApp` | during the `LF_FreeApp` window, callbacks fire → segfault |
| **K3** | the `register*` functions in `app-handle.ts` / `p2p-registration.ts` do not wrap the native calls in try/catch | when native throws, the Koffi bridge leaks (a libuv handle that keeps the process alive) |

### 2.3 Test assertion adaptation

| Problem | Location | Reason |
|------|------|------|
| **T1** | `test/test.ts` `"a throwing callback does not crash the process"` | the assertion `result.size === 0` reflects the old behaviour; after the fix the error envelope is written correctly, so size > 0 |

---

## 3. The fix list (file by file)

### 3.1 `src/lf-io.ts`

**New**: `readJsonTolerant<T>(handle)` — compatible with three wire protocols

```typescript
export function readJsonTolerant<T = unknown>(
    handle: DataHandle,
): T | null {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.readJsonTolerant: handle must be a DataHandle.");
    }
    if (handle.size === 0) return null;
    handle.position = 0;
    const first = handle.readUInt8();
    if (first === 0x00) {
        return readJson<T>(handle);      // status byte success: read JSON from pos=1
    }
    if (first === 0xFF) {
        let msg = "";
        try { msg = handle.readString(); } catch { /* ignore */ }
        throw new LingoFuseError(`remote error: ${msg || "<empty>"}`);
    }
    handle.position = 0;
    return readJson<T>(handle);          // raw JSON
}
```

**Basis**: `readJsonTolerant` in JS `address.js`. Fixes Bug D.

### 3.2 `src/async-support.ts`

**Change 1**: `AsyncOp` gains a `dataPtr` field and a `freeDataPtr()` method

```typescript
export class AsyncOp<T> {
    private _dataPtr: unknown;
    // ...
    public get dataPtr(): unknown { return this._dataPtr; }
    public freeDataPtr(): void {
        if (this._dataPtr) {
            try {
                (koffi.free as (p: unknown) => void)(this._dataPtr);
            } catch { /* ignore */ }
            this._dataPtr = null;
        }
    }
}
```

**Change 2**: `createAsyncOp` allocates `koffi.alloc("uint8", 1)`

```typescript
function createAsyncOp<T>(...): AsyncOp<T> {
    let dataPtr: unknown;
    try {
        dataPtr = (koffi.alloc as (t: string, n: number) => unknown)(
            "uint8", 1);
    } catch (err) {
        throw new LingoFuseError(
            "AsyncOp: failed to allocate native data pointer: " + detail);
    }
    if (!dataPtr) {
        throw new LingoFuseError(
            "AsyncOp: native data pointer allocation returned null.");
    }
    // ... koffi.register(callback)
    // ... new AsyncOp(deliver, cCallback, promise, dataPtr)
}
```

**Change 3**: the `issueFn` signature of `runAsyncWithPromise` / `runLegacyOp` is extended

```typescript
export function runAsyncWithPromise<T>(
    issueFn: (cb: unknown, op: AsyncOp<T>) => number,   // ★ new op
    deserialize: (rawResult: unknown) => T,
    timeoutMs?: number,
): CallPromise<T> {
    const { op, promise } = makeFutureOp<T>(deserialize);
    const ret = issueFn(op.cCallback, op);              // ★ pass op
    // ...
}

export function runLegacyOp<T>(
    issueFn: (cb: unknown, op: AsyncOp<T>) => number,   // ★ new op
    // ...
): number { /* pass op likewise */ }
```

**Change 4**: `_pendingUnregisters` now stores `AsyncOp` and frees the `dataPtr` uniformly

```typescript
private readonly _pendingUnregisters:
    Map<TimerHandle, AsyncOp<unknown>> = new Map();
```

**Change 5**: both `releaseOp` and `shutdown` call `op.freeDataPtr()`

```typescript
private releaseOp(op: AsyncOp<unknown>): void {
    // ...
    if (wasAbandoned) {
        let timer: TimerHandle;
        timer = setTimeout(() => {
            this._pendingUnregisters.delete(timer);
            this.unregisterCallback(op.cCallback);
            op.freeDataPtr();                            // ★
        }, ABANDONED_RELEASE_DELAY_MS);
        // ...
    } else {
        this.unregisterCallback(op.cCallback);
        op.freeDataPtr();                                // ★
    }
}

public shutdown(): void {
    // ...
    for (const [timer, op] of pending) {
        try { clearTimeout(timer); } catch { }
        this.unregisterCallback(op.cCallback);
        op.freeDataPtr();                                // ★
    }
    for (const op of this._handles.values()) {
        this.unregisterCallback(op.cCallback);
        op.freeDataPtr();                                // ★
    }
}
```

**Basis**: `_createAsyncOp` and `_releaseOp` in JS `async-support.js`. Fixes Bug C.

### 3.3 `src/network-events.ts`

**Change**: `setNetworkEvent` is reordered to **build → install → publish → unregister old**

```typescript
export function setNetworkEvent(
    onConnect: ConnectHandler | null,
    onDisconnect: DisconnectHandler | null,
): void {
    const oldConnect = _connectTrampoline;
    const oldDisconnect = _disconnectTrampoline;

    // ① build the new trampolines (leaving the native slot untouched)
    const newConnect = onConnect === null
        ? null
        : buildTrampoline("NetworkEvents.connect", onConnect);
    const newDisconnect = onDisconnect === null
        ? null
        : buildTrampoline("NetworkEvents.disconnect", onDisconnect);

    // ② install the new ones
    try {
        funcs().LF_Set_Network_Event(newConnect, newDisconnect);
    } catch (err) {
        unregisterCallback(newConnect);
        unregisterCallback(newDisconnect);
        throw err;
    }

    // ③ publish
    _connectTrampoline = newConnect;
    _disconnectTrampoline = newDisconnect;

    // ④ release the old ones
    unregisterCallback(oldConnect);
    unregisterCallback(oldDisconnect);
}
```

**Basis**: the "DELEGATE LIFETIME AND REPLACEMENT ORDER" note at the top of JS `network-events.js`. Fixes K1.

### 3.4 `src/app-handle.ts`

**Change 1**: `registerCall` gains try/catch, and a callback exception writes a `[0xFF][msg][NUL]` error envelope

```typescript
const bridge = koffi.register(
    (trigger, input, output): void => {
        const inH = DataHandle.fromRaw(input, false);
        const outH = DataHandle.fromRaw(output, false);
        try {
            handler(inH, outH);
        } catch (err) {
            reportCallbackError(
                `AppHandle.registerCall[${apiName}]`, err);
            writeErrorEnvelope(outH, err);    // [0xFF][msg][NUL]
        }
    },
    LfCallFuncPtr,
);

let result: number;
try {
    result = this.#binding.funcs.LF_RegisterCall(
        this.#handle, apiName, desc, null, bridge);
} catch (err) {
    unregisterCallback(bridge);               // ★ reclaim it to avoid a leak
    throw err;
}

if (result === 1) {
    this.#registrations.set(key, bridge);
    return true;
}
unregisterCallback(bridge);
return false;
```

**Change 2**: `registerNotify` gains try/catch (same logic, no output handle)

**Change 3**: the `dispose` order is reversed

```typescript
public dispose(): void {
    if (this.#disposed) return;
    this.#disposed = true;

    const handle = this.#handle;
    this.#handle = null;

    const bridges = Array.from(this.#registrations.values());
    this.#registrations.clear();

    // ① first let native drop all the pointers
    if (handle !== null && handle !== undefined) {
        try {
            this.#binding.funcs.LF_FreeApp(handle);
        } catch { /* ensure trampolines are still released below */ }
    }

    // ② then release the Koffi trampolines
    for (const bridge of bridges) {
        unregisterCallback(bridge);
    }
}
```

**Basis**: the "REPLACEMENT / RELEASE ORDER" note at the top of JS `app-handle.js` and the error envelope in §Bug #4. Fixes K2 and K3.

### 3.5 `src/p2p-registration.ts`

**Change**: `registerP2PCall` / `registerP2PNotify` gain try/catch

```typescript
let ret: number;
try {
    ret = funcs().LF_Register_P2P_Call(
        apiName, desc, null, bridge);
} catch (err) {
    unregisterCallback(bridge);
    throw err;
}

if (ret !== 1) {
    unregisterCallback(bridge);
    throw new LingoFuseRegistrationError(apiName);
}
_p2pCallbacks.push(bridge);
```

**Basis**: the note at the top of JS `p2p-registration.js`. Fixes K3.

### 3.6 `src/framework.ts`

**Change 1**: `makeJsonDeserializer` switches to `readJsonTolerant`

```typescript
function makeJsonDeserializer<T>(): (rawResult: unknown) => T {
    return function (rawResult: unknown): T {
        if (!rawResult) return null as unknown as T;
        const h = DataHandle.fromRaw(rawResult, false);
        return readJsonTolerant<T>(h) as T;   // ★
    };
}
```

**Change 2**: the `issueFn`s of the 6 async functions gain an `op` parameter and pass `op.dataPtr`

```typescript
export function callAsync<TRes = unknown>(...): number {
    return runLegacyOp<TRes>(
        (cb, op) => funcs().LF_Async_Call(
            appName, param.raw, op.dataPtr, cb),    // ★ op.dataPtr
        onResult, userData, makeJsonDeserializer<TRes>());
}

export function callPromise<TRes = unknown>(...): CallPromise<TRes> {
    return runAsyncWithPromise<TRes>(
        (cb, op) => funcs().LF_Async_Call(
            appName, param.raw, op.dataPtr, cb),    // ★ op.dataPtr
        makeJsonDeserializer<TRes>(), timeout);
}

// uidCallAsync / uidCallPromise / p2pnameCallAsync / p2pnameCallPromise
// are all changed the same way
```

**Basis**: the fixed version of JS `framework.js`. Fixes Bug C and Bug D.

**Note**: the async functions in `framework.ts` are **not** responsible for the `param` lifetime (the caller passes it in and manages it), consistent with the JS contract.

### 3.7 `src/address.ts`

**Change 1**: new `AsyncOpView` interface

```typescript
interface AsyncOpView {
    readonly dataPtr: unknown;
}
```

**Rationale**: `_rawIssueAsync*` only needs to read `op.dataPtr`. Using a structural type avoids the covariance problem of going from `AsyncOp<TRes>` to `AsyncOp<unknown>`, and subclass implementations need not care about `AsyncOp`'s internal state at all.

**Change 2**: in `Target.call` / `sequencedCall` the `param` is disposed only after the promise settles

```typescript
public call<TReq, TRes>(...): CallPromise<TRes> {
    const param = new DataHandle(apiName);
    let promise: CallPromise<TRes>;
    try {
        writeJson(param, payload);
        promise = runAsyncWithPromise<TRes>(
            (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
            makeJsonDeserializer<TRes>(), timeoutMs);
    } catch (err) {
        try { param.dispose(); } catch { }
        throw err;
    }
    promise.then(
        () => { try { param.dispose(); } catch { } },
        () => { try { param.dispose(); } catch { } },
    );
    return promise;
}
```

**Change 3**: in `Target.callAsync` / `sequencedCallAsync` the `param` is disposed inside the onResult wrapper

```typescript
public callAsync<TReq, TRes>(...): number {
    const param = new DataHandle(apiName);
    let ret: number;
    try {
        writeJson(param, payload);
        ret = runLegacyOp<TRes>(
            (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
            (result, error, ud) => {
                try { param.dispose(); } catch { }   // ★ dispose first
                onResult(result, error, ud);        // ★ then call the user callback
            },
            userData, makeJsonDeserializer<TRes>());
    } catch (err) {
        try { param.dispose(); } catch { }
        throw err;
    }
    return ret;
}
```

**Change 4**: `makeJsonDeserializer` / `consumeSyncResult` switch to `readJsonTolerant`

```typescript
function makeJsonDeserializer<T>(): (rawResult: unknown) => T {
    return function (rawResult: unknown): T {
        if (!rawResult) return null as unknown as T;
        const h = DataHandle.fromRaw(rawResult, false);
        return readJsonTolerant<T>(h) as T;
    };
}

function consumeSyncResult<T>(
    rawResult: unknown, apiName: string,
    targetDesc: string, timeoutMs: number,
): T {
    // ... size === 0 early check
    return readJsonTolerant<T>(h) as T;
}
```

**Change 5**: the 6 `_rawIssueAsync*` signatures gain an `op` parameter and pass `op.dataPtr`

```typescript
protected _rawIssueAsyncCall(
    apiName: string,
    param: DataHandle,
    cb: unknown,
    op: AsyncOpView,                             // ★
): number {
    void apiName;
    return this._funcs.LF_Async_Call(
        this._appName, param.raw, op.dataPtr, cb);   // ★
}
```

**Basis**: the fixed version of JS `address.js`. Fixes Bug B, Bug C and Bug D.

**The critical ordering**: inside `callAsync`, **dispose the param first, then call the user callback**. That way, even if the user callback touches `param` it is already `disposed` and gets a clear error instead of UB. When dispatch fails, `runLegacyOp` calls `onResult(null, error, userData)` synchronously and the wrapper disposes first and then calls through — the order is correct.

### 3.8 `test/test.ts`

**Change**: the assertion of `"a throwing callback does not crash the process"`

```typescript
it("a throwing callback does not crash the process", () => {
    const tmpApp = new lf.AppHandle("JsTestThrow", "throwing callback");
    tmpApp.registerCall("boom", "always throws", () => {
        throw new Error("intentional test failure");
    });

    const param = new DataHandle("boom");
    try {
        const result = tmpApp.localCall(param);
        assert.ok(
            result.size > 0,
            "expected non-empty error envelope (0xFF + message + NUL)");
        result.position = 0;
        assert.equal(
            result.readUInt8(), 0xFF,
            "expected error envelope status byte 0xFF");
        result.dispose();
    }
    finally {
        param.dispose();
        tmpApp.dispose();
    }

    assert.equal(lf.status.checkMainThread(), true);
});
```

**Basis**: `app-handle.ts` now always writes the `[0xFF][msg][NUL]` error envelope (a cross-language unified contract). The assertion changes from "empty result" to "error envelope". Fixes T1.

### 3.9 `test/test-v2.ts`

**Change**: drop `unref()` from the race timer + add a `withTimeout` helper

```typescript
async function withTimeout<T>(
    promise: Promise<T>,
    timeoutMs: number,
): Promise<T> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeoutPromise = new Promise<never>((_, reject) => {
        timer = setTimeout(
            () => reject(new Error(
                `test timed out after ${timeoutMs} ms`)),
            timeoutMs,
        );
        // ★ no unref; the timer keeps the process alive
    });
    try {
        return await Promise.race([promise, timeoutPromise]);
    } finally {
        if (timer !== undefined) clearTimeout(timer);
    }
}
```

**Change**: `after()` gains `network.clearNetworkEvent()`, honouring LF-CLEAN-001

```typescript
after(async () => {
    // ...
    // step 1: sleep(500)
    // step 2: network.clearNetworkEvent()       ★ new
    // step 3: AsyncBridge.shutdownInstance()
    // step 4: framework.exitMainThread()
    // step 5: app.dispose()
    // step 6: framework.shutdown()
});
```

**Basis**: `LingoFuse_JS_Async_Fix_Report.md` §Bug A + README §12.8. Fixes Bug A.

### 3.10 `tsconfig.json`

**Change**: `ignoreDeprecations` from `"5.0"` to `"6.0"`

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "moduleResolution": "node10",
    "ignoreDeprecations": "6.0",
    // ...
  }
}
```

**Basis**: TypeScript 6.0 marks `moduleResolution: "node10"` as deprecated. The value of `ignoreDeprecations` must be **the deprecation version number matching the current TypeScript version**. TypeScript 7.0 will remove `node10` entirely, at which point it can migrate to `"bundler"` (`tsx` is essentially a bundler).

---

## 4. The PowerShell scripts

### 4.1 `clean.ps1`

Clears `dist/` + `tsconfig.*.tsbuildinfo`. Optional parameters:

| Parameter | Behaviour |
|------|------|
| `-IncludeNodeModules` | also deletes `node_modules/` + `package-lock.json` |
| `-IncludeCache` | also deletes `.cache/` |

### 4.2 `check_env.ps1`

**8 check sections**:

1. PowerShell version (≥ 5.1)
2. Node.js (≥ 18)
3. npm
4. project structure (24 required files)
5. `node_modules` (koffi / typescript / tsx / @types/node)
6. the koffi native addon (actually loading the platform library as a probe)
7. the LingoFuse native library (going through the real load path via `dist/binding.js`)
8. Report (failure / warning counts)

**Exit code**: `0` = no failures, `1` = failures present.

### 4.3 `build.ps1`

**Execution sequence**:

1. check that `npm` / `node` exist
2. run `npm install` automatically if `node_modules` is missing
3. with `-Clean`, run `npm run clean`
4. unless `-SkipCheck`, run `npm run check` (`tsc --noEmit`)
5. run `npm run build` (`tsc -p tsconfig.build.json`)
6. check that `dist/index.js` and `dist/index.d.ts` exist
7. count the `dist/*.js` / `dist/*.d.ts` files

**Parameters**: `-Clean`, `-SkipCheck`.

### 4.4 `test.ps1`

**Parameters**:

| Parameter | Values | Default |
|------|----|------|
| `-Suite` | `all` / `v1` / `v2` / `cross` | `all` |
| `-Runtime` | `auto` / `node` / `bun` / `deno` | `auto` (prefers bun → deno → node) |
| `-SkipUnit` | flag | — |
| `-SkipCross` | flag | — |

**Key implementation points**:

#### Running the unit tests

Launch `node.exe` + `tsx cli.mjs` directly, **bypassing cmd / tsx.cmd**:

```powershell
$cmd = @{
    Exe = "D:\...\node.exe"
    ArgList = @("D:\...\node_modules\tsx\dist\cli.mjs", "D:\...\test\test.ts")
}
$psi.FileName = $cmd.Exe
$psi.Arguments = Build-ArgumentsString -ArgList $cmd.ArgList

$proc = [System.Diagnostics.Process]::Start($psi)
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()
$proc.WaitForExit(300000)   # 5-minute timeout
```

**Avoiding pipe deadlock**: `ReadToEndAsync` keeps consuming the pipe on another thread, so the parent thread waiting for the process to exit cannot deadlock.

#### Cross test: three processes cooperating

**Fixed sleeps + graceful exit via stdin**, with real-time pattern matching abandoned:

| Phase | Value | Basis |
|------|----|------|
| service startup | 10 s | IPC queue creation + C4 mesh init < 3 s; 10 s leaves margin |
| node connect | 8 s | `LF_PrepareClient` + broadcast convergence < 3 s; 8 s leaves margin |
| call load test | 18 s | `TEST_SECONDS = 10` + `sleep(1ms)` interval + network jitter; 18 s is enough |
| call exit grace | 15 s | after the stdin Enter, normally < 1 s to exit |

**The critical fix**: `Start-CrossProcess` **calls `ReadToEndAsync()` immediately** and holds the task in the handle:

```powershell
function Start-CrossProcess {
    param([string]$Name, [string]$ScriptRelPath)
    # ... start the process
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    return @{
        Name = $Name; Process = $proc
        StdoutTask = $stdoutTask
        StderrTask = $stderrTask
    }
}
```

**Graceful exit**:

```powershell
function Request-CrossProcessExit {
    param($Handle, [int]$GraceMs = 15000)
    # ...
    $p.StandardInput.WriteLine("")       # triggers waitForEnter()
    $p.StandardInput.Flush()
    return $p.WaitForExit($GraceMs)      # 15s grace
}

function Stop-CrossProcess {
    param($Handle)
    # first stdin Enter + Wait 3s
    # on timeout taskkill /T /F /PID
    # finally Kill() as the backstop
}
```

**The data-flow timeline**:

```
T=0     service starts         → ReadToEndAsync consumes the pipe in the background
T=10    service alive
T=10    node starts            → ReadToEndAsync consumes the pipe in the background
T=18    node alive
T=18    call starts            → ReadToEndAsync consumes the pipe in the background
T=36    the 10s load test inside call ends → prints "[Call] Load test summary" + stats
T=36    call blocks at waitForEnter
T=36    PowerShell sends stdin Enter → waitForEnter returns → the process exits gracefully
T=37    the call Process exits → pipe EOF → the ReadToEndAsync task completes
T=37    take the full output from StdoutTask.GetResult()
T=37    regex-extract total / failed / success
T=37    decide pass
T=37    finally stops the 3 processes (all already exited or killed by now)
```

**Parsing the statistics**:

```powershell
$totalMatch = [regex]::Match($combined, 'total calls\s*:\s*(\d+)')
$failedMatch = [regex]::Match($combined, 'failed\s*:\s*(\d+)')
$successMatch = [regex]::Match($combined, 'success\s*:\s*(\d+)')
```

**Verdict**: `total > 0` and `failed === 0` → pass.

---

## 5. Verification results

### 5.1 The v1 baseline tests

```
Summary
  runtime : Node.js 24.21.0
  passed  : 127
  failed  : 0
  total   : 127
```

### 5.2 The v2.0 tests

```
Summary
  runtime : Node.js 24.21.0
  passed  : 99
  failed  : 0
  total   : 99
```

**Coverage**:

- App-name async: `add`, `whoami`, `probe_output`, `log` (notify)
- UID async: `UIDTarget.callSync`, `UIDTarget.call`
- the three call styles: `callSync` / `call` (Promise) / `callAsync` (inline callback)
- concurrency: three `add` calls through `await`
- side data: `getP2PUid` / `getP2PName` are valid on the INPUT handle and return defaults on the OUTPUT handle
- `AsyncBridge` lifetime: `stats`, idempotent `shutdown`

### 5.3 The cross test

```
Cross test: service + node + call
[ OK ]   service process is alive.
[ OK ]   node process is alive.
[ OK ]   call exited gracefully.
[INFO]   total=N  success=N  failed=0
[ OK ]   Cross test passed.
```

### 5.4 Cleanup shows no access violation

```
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 begin
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 done timeout=no
```

Before the fix:

```
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 begin
TC40_LF_Client.Destroy remove P2P update error: Access violation
TC40_LF_Client.Destroy remove app update error: Access violation
```

### 5.5 The server receives the request

Server log:

```
[LF-DEBUG] SVC.cmd_Call: ENTER app="JsTest2" api="add"
[LF-DEBUG] SVC.cmd_Call: LOCAL path, HPC dispatch
```

**This is hard proof that the async request really reaches the server.**

---

## 6. Key design decisions

### 6.1 Using the `AsyncOpView` interface rather than importing `AsyncOp` directly

```typescript
interface AsyncOpView {
    readonly dataPtr: unknown;
}
```

**Rationale**:

- `Target._rawIssueAsyncCall` only needs to read the single field `op.dataPtr`
- a structural type rather than a concrete generic class avoids the covariance problem going from `AsyncOp<TRes>` to `AsyncOp<unknown>`
- subclass implementations need not care about the `AsyncOp` type at all

### 6.2 `Target.call`'s `.then` discards the return value

```typescript
promise.then(
    () => { try { param.dispose(); } catch { } },
    () => { try { param.dispose(); } catch { } },
);
return promise;   // return the original promise
```

`.then` returns a new `Promise<void>` that is discarded. But since both callbacks return `void` (they do not throw), it is **resolved** → no unhandledRejection. **At the same time**, this `.then` registers a reject handler on `_promise`, which prevents an unhandledRejection on `_promise`.

### 6.3 In `Target.callAsync`, dispose first and then call the user callback

```typescript
(result, error, ud) => {
    try { param.dispose(); } catch { }   // ★ dispose first
    onResult(result, error, ud);        // ★ then call the user
}
```

**Why that order**: even if the user callback touches `param` it is already `disposed`, so it gets a clear `LingoFuseObjectDisposedError` instead of UB. When dispatch fails, `runLegacyOp` calls `onResult(null, error, userData)` **synchronously**; the wrapper disposes first and then calls the user callback — the order is correct.

### 6.4 `callSync` keeps `finally { param.dispose(); }`

`callSync` is a synchronous call and native has already finished reading the payload before returning. `finally { param.dispose(); }` is **correct**, not Bug B. The JS fix report also fixed Bug B only on `call` / `callAsync` / `sequencedCall` / `sequencedCallAsync`, leaving `callSync` alone.

### 6.5 `void apiName;` suppresses the unused-parameter warning

The `apiName` parameter of the subclass `_rawIssue*` implementations is defined in the ABC but not used by the subclass (native does not need it). `void apiName;` tells TS explicitly "I am deliberately not using it".

### 6.6 PowerShell gives up pattern matching

**Why**:

- `.bat` is unreliable under PowerShell 5.1 + a non-ASCII `$env:TEMP`
- cmd's quoting rules are extremely error-prone with nested `""` + `> 2>` redirection
- fixed sleeps cost at most 15–20 extra seconds in the worst case, but are **absolutely reliable**

### 6.7 `GetNewClosure()` cannot be used with the `DataReceived` event

An earlier version tried to capture `$outQueue` with `.GetNewClosure()`; under Windows PowerShell 5.1:

- casting `[DataReceivedEventHandler]({...}.GetNewClosure())` to `[Delegate]` loses the closure variable bindings
- the typical error: `Exception calling "add_OutputDataReceived"...`

**The current approach**: abandon `DataReceived` completely and use `ReadToEndAsync()` returning `Task<string>`, with the task held in the handle.

---

## 7. Known issues and follow-ups

### 7.1 The TypeScript 7.0 migration

`moduleResolution: "node10"` will be removed entirely in TypeScript 7.0. At that point it can migrate to `"bundler"` (`tsx` is essentially a bundler). The current `ignoreDeprecations: "6.0"` is a stopgap.

### 7.2 Cross-language interop verification

JS ↔ JS (service + call) is fully green today. The next step is to verify TS ↔ C++ / Pascal / C# interop:

| Scenario | Service | Call | Data protocol | Expectation |
|------|---------|------|---------|:----:|
| A | Pascal `LF_Test_ServFrm.pas` | TS `cross-call.ts` | raw binary | to be verified |
| B | TS `cross-service.ts` | Pascal `LF_Test_CliFrm.pas` | raw binary | to be verified |
| C | C++ `CrossService.cpp` | TS `cross-call.ts` | raw binary | to be verified |
| D | TS `cross-service.ts` | C++ `CrossCall.cpp` | raw binary | to be verified |

**Note**: when TS talks to another language, **the wire protocol must match**. `cross-call.ts` uses pure binary (`writeInt32` / `writeUInt8` and so on), and `CrossCall.cpp` in the other languages also uses pure binary, so they interoperate directly.

### 7.3 The timing dependency of `test.ps1`'s output capture

It currently relies on "an Enter on stdin after 18 seconds" to trigger `waitForEnter()` and let the call exit gracefully. If `cross-call.ts`'s load-test duration grows later (to 30 seconds, say), the `Start-Sleep -Seconds` values need adjusting in step.

### 7.4 `AsyncBridge` prevents the Node event loop from exiting

If you forget to call `AsyncBridge.shutdownInstance()`, the libuv handles of the Koffi callbacks stay ref'd and the Node event loop cannot exit. **Production code must call it explicitly before the process exits**:

```typescript
lf.AsyncBridge.shutdownInstance();
lf.framework.shutdown();
```

`test-v2.ts`'s `after()` already honours this contract.

---

## 8. Change log

| Date | Event |
|------|------|
| 2026-10-24 | located the 4 async bugs + 3 Koffi callback resource-ordering problems |
| 2026-10-24 | fixed `lf-io.ts` (new `readJsonTolerant`) |
| 2026-10-24 | fixed `async-support.ts` (`dataPtr` allocation and release) |
| 2026-10-24 | fixed `network-events.ts` (reordering) |
| 2026-10-24 | fixed `p2p-registration.ts` (try/catch) |
| 2026-10-24 | fixed `app-handle.ts` (dispose order + error envelope + try/catch) |
| 2026-10-24 | fixed `framework.ts` (`dataPtr` passing + `readJsonTolerant`) |
| 2026-10-24 | fixed `address.ts` (param lifetime + `dataPtr` passing + `readJsonTolerant`) |
| 2026-10-24 | fixed `test/test.ts` (error envelope assertion) |
| 2026-10-24 | fixed `test/test-v2.ts` (remove the unref from the race timer) |
| 2026-10-24 | fixed `tsconfig.json` (`ignoreDeprecations: "6.0"`) |
| 2026-10-24 | delivered `clean.ps1` / `check_env.ps1` / `build.ps1` / `test.ps1` |
| 2026-10-24 | **verified: v1 127/127 PASS, v2 99/99 PASS, cross PASS, no access violation** |

---

## 9. References

- **JS fix report**: `LingoFuse_JS_Async_Fix_Report.md`
- **The authoritative Pascal document**: `LingoFuse_Pascal_Complete_Guide.md` (§4.7 handle ownership, §10 identity injection, §14 threading model)
- **The authoritative JS source**: `lingofuse-js` v2.0.0 (`async-support.js` / `address.js` / `framework.js` / `app-handle.js` / `network-events.js` / `p2p-registration.js` / `lf-io.js`)
- **The C ABI header**: `LingoFuse.h`
- **Test suites**: `test/test.ts` (127 items), `test/test-v2.ts` (99 items), `cross/cross-service.ts` + `cross/cross-node.ts` + `cross/cross-call.ts`

---

**End of document**
