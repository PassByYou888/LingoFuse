# LingoFuse TypeScript 绑定 — Async 修复报告

**版本**: 1.0
**日期**: 2026-10-24
**范围**: 修复 `lingofuse-ts` 的 async 调用链路与 Koffi 回调资源管理，使其与 C++ / C# / Pascal / JavaScript 绑定行为一致
**状态**: v1 基线 127/127 PASS，v2 测试 99/99 PASS，cross service+node+call 端到端 PASS

---

## 一、背景

Node.js 绑定（`lingofuse-js` v2.0.0）的 async 调用在端到端测试中全部失败，修复报告（`LingoFuse_JS_Async_Fix_Report.md`）已经定位了 4 个正交 bug，并在 JS 侧修复完毕。

TypeScript 绑定（`lingofuse-ts` v2.0.0）结构、类型系统、三寻址抽象、异常层次、UID 双角色、P2P side-data 语义全部正确，但 **L3–L5 层完整复刻了 JS 修复报告中描述的 4 个 async bug**，且**额外的 3 个 Koffi 回调资源顺序问题**也没有按修复后的正确顺序实现。

后果：

- TS 的 async 集成测试全部失败（`TimeoutError` 或 15 秒挂起）
- 生产代码里所有 `Target.call(...)` / `target.callAsync(...)` 也会失败
- 长时间运行会出现 `TC40_LF_Client.Destroy remove P2P update error: Access violation`

本次修复的目标：**把 JS 修复报告的全部经验完整移植到 TS**，并补齐 Koffi 回调资源顺序。

---

## 二、核心问题清单

### 2.1 从 JS 修复报告移植的 4 个 async bug

| Bug | 名称 | JS 修复依据 | TS 复刻位置 |
|-----|------|-------------|------------|
| **A** | test 的 race timer `unref()` | `LingoFuse_JS_Async_Fix_Report.md` §Bug #1 | `test-v2.ts` runner |
| **B** | `param` 提前 `dispose()` | §Bug #2 | `address.ts` `Target.call` / `sequencedCall` / `callAsync` / `sequencedCallAsync` |
| **C** | `data` 指针传 `null` | §Bug #3 | `async-support.ts` + `framework.ts` + `address.ts` |
| **D** | JSON wire protocol 不兼容 | §Bug #4 | `lf-io.ts` + `address.ts` + `framework.ts` |

### 2.2 额外的 3 个 Koffi 回调资源顺序问题

| 问题 | 位置 | 后果 |
|------|------|------|
| **K1** | `network-events.ts` `setNetworkEvent` 先 unregister 旧的再 install 新的 | 窗口期内 native 调用已释放的 trampoline → segfault |
| **K2** | `app-handle.ts` `dispose` 先 unregister 再 `LF_FreeApp` | `LF_FreeApp` 窗口期内回调触发 → segfault |
| **K3** | `app-handle.ts` / `p2p-registration.ts` 的 `register*` 未用 try/catch 包裹 native 调用 | native 抛异常时 Koffi bridge 泄漏（libuv 句柄，阻止进程退出） |

### 2.3 测试断言适配

| 问题 | 位置 | 原因 |
|------|------|------|
| **T1** | `test/test.ts` `"a throwing callback does not crash the process"` | 断言 `result.size === 0` 反映旧行为；修复后错误信封正确写入，size > 0 |

---

## 三、修复清单（逐文件）

### 3.1 `src/lf-io.ts`

**新增**：`readJsonTolerant<T>(handle)` —— 兼容三种 wire protocol

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
        return readJson<T>(handle);      // 状态字节成功：从 pos=1 读 JSON
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

**依据**：JS `address.js` 的 `readJsonTolerant`。解决 Bug D。

### 3.2 `src/async-support.ts`

**变更 1**：`AsyncOp` 新增 `dataPtr` 字段与 `freeDataPtr()` 方法

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

**变更 2**：`createAsyncOp` 分配 `koffi.alloc("uint8", 1)`

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

**变更 3**：`runAsyncWithPromise` / `runLegacyOp` 的 `issueFn` 签名扩展

```typescript
export function runAsyncWithPromise<T>(
    issueFn: (cb: unknown, op: AsyncOp<T>) => number,   // ★ 新增 op
    deserialize: (rawResult: unknown) => T,
    timeoutMs?: number,
): CallPromise<T> {
    const { op, promise } = makeFutureOp<T>(deserialize);
    const ret = issueFn(op.cCallback, op);              // ★ 传 op
    // ...
}

export function runLegacyOp<T>(
    issueFn: (cb: unknown, op: AsyncOp<T>) => number,   // ★ 新增 op
    // ...
): number { /* 同样传入 op */ }
```

**变更 4**：`_pendingUnregisters` 改存 `AsyncOp`，统一释放 `dataPtr`

```typescript
private readonly _pendingUnregisters:
    Map<TimerHandle, AsyncOp<unknown>> = new Map();
```

**变更 5**：`releaseOp` / `shutdown` 都调用 `op.freeDataPtr()`

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

**依据**：JS `async-support.js` 的 `_createAsyncOp` 与 `_releaseOp`。解决 Bug C。

### 3.3 `src/network-events.ts`

**变更**：`setNetworkEvent` 换序为 **build → install → publish → unregister old**

```typescript
export function setNetworkEvent(
    onConnect: ConnectHandler | null,
    onDisconnect: DisconnectHandler | null,
): void {
    const oldConnect = _connectTrampoline;
    const oldDisconnect = _disconnectTrampoline;

    // ① build 新 trampoline（不动 native 槽）
    const newConnect = onConnect === null
        ? null
        : buildTrampoline("NetworkEvents.connect", onConnect);
    const newDisconnect = onDisconnect === null
        ? null
        : buildTrampoline("NetworkEvents.disconnect", onDisconnect);

    // ② 装新的
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

    // ④ 解旧的
    unregisterCallback(oldConnect);
    unregisterCallback(oldDisconnect);
}
```

**依据**：JS `network-events.js` 文件头 "DELEGATE LIFETIME AND REPLACEMENT ORDER"。解决 K1。

### 3.4 `src/app-handle.ts`

**变更 1**：`registerCall` 新增 try/catch，且回调异常写 `[0xFF][msg][NUL]` 错误信封

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
    unregisterCallback(bridge);               // ★ 回收，避免泄漏
    throw err;
}

if (result === 1) {
    this.#registrations.set(key, bridge);
    return true;
}
unregisterCallback(bridge);
return false;
```

**变更 2**：`registerNotify` 加 try/catch（逻辑同上，无输出 handle）

**变更 3**：`dispose` 顺序反转

```typescript
public dispose(): void {
    if (this.#disposed) return;
    this.#disposed = true;

    const handle = this.#handle;
    this.#handle = null;

    const bridges = Array.from(this.#registrations.values());
    this.#registrations.clear();

    // ① 先让 native 丢掉全部指针
    if (handle !== null && handle !== undefined) {
        try {
            this.#binding.funcs.LF_FreeApp(handle);
        } catch { /* ensure trampolines still released below */ }
    }

    // ② 再释放 Koffi trampoline
    for (const bridge of bridges) {
        unregisterCallback(bridge);
    }
}
```

**依据**：JS `app-handle.js` 文件头 "REPLACEMENT / RELEASE ORDER" 与 §Bug #4 错误信封。解决 K2、K3。

### 3.5 `src/p2p-registration.ts`

**变更**：`registerP2PCall` / `registerP2PNotify` 加 try/catch

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

**依据**：JS `p2p-registration.js` 文件头。解决 K3。

### 3.6 `src/framework.ts`

**变更 1**：`makeJsonDeserializer` 改用 `readJsonTolerant`

```typescript
function makeJsonDeserializer<T>(): (rawResult: unknown) => T {
    return function (rawResult: unknown): T {
        if (!rawResult) return null as unknown as T;
        const h = DataHandle.fromRaw(rawResult, false);
        return readJsonTolerant<T>(h) as T;   // ★
    };
}
```

**变更 2**：6 个 async 函数的 `issueFn` 加 `op` 参数并传 `op.dataPtr`

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
// 全部同样修改
```

**依据**：JS `framework.js` 的修复后版本。解决 Bug C、Bug D。

**注意**：`framework.ts` 的 async 函数**不负责** `param` 生命周期（调用者传入并管理），与 JS 契约一致。

### 3.7 `src/address.ts`

**变更 1**：新增 `AsyncOpView` 接口

```typescript
interface AsyncOpView {
    readonly dataPtr: unknown;
}
```

**理由**：`_rawIssueAsync*` 只需要读 `op.dataPtr`。用结构类型避免 `AsyncOp<TRes>` 到 `AsyncOp<unknown>` 的协变问题，子类实现完全不需要关心 `AsyncOp` 内部状态。

**变更 2**：`Target.call` / `sequencedCall` 的 `param` 延迟到 promise settle 后 dispose

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

**变更 3**：`Target.callAsync` / `sequencedCallAsync` 的 `param` 在 onResult wrapper 里 dispose

```typescript
public callAsync<TReq, TRes>(...): number {
    const param = new DataHandle(apiName);
    let ret: number;
    try {
        writeJson(param, payload);
        ret = runLegacyOp<TRes>(
            (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
            (result, error, ud) => {
                try { param.dispose(); } catch { }   // ★ 先 dispose
                onResult(result, error, ud);        // ★ 再调用户回调
            },
            userData, makeJsonDeserializer<TRes>());
    } catch (err) {
        try { param.dispose(); } catch { }
        throw err;
    }
    return ret;
}
```

**变更 4**：`makeJsonDeserializer` / `consumeSyncResult` 改用 `readJsonTolerant`

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
    // ... size === 0 提前检查
    return readJsonTolerant<T>(h) as T;
}
```

**变更 5**：6 个 `_rawIssueAsync*` 签名加 `op` 参数，具体实现传 `op.dataPtr`

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

**依据**：JS `address.js` 的修复后版本。解决 Bug B、Bug C、Bug D。

**关键顺序**：`callAsync` 里**先 dispose param 再调用户回调**。这样用户回调里即使访问 `param` 也已经是 `disposed` 状态，得到明确错误而不是 UB。`runLegacyOp` 在 dispatch 失败时同步调用 `onResult(null, error, userData)`，wrapper 会先 dispose 再调——顺序正确。

### 3.8 `test/test.ts`

**变更**：`"a throwing callback does not crash the process"` 测试断言

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

**依据**：`app-handle.ts` 现在总是写 `[0xFF][msg][NUL]` 错误信封（跨语言统一契约）。测试断言从"空结果"改为"错误信封"。解决 T1。

### 3.9 `test/test-v2.ts`

**变更**：race timer 去 `unref()` + 新增 `withTimeout` 辅助

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
        // ★ 不 unref，让 timer 保持进程存活
    });
    try {
        return await Promise.race([promise, timeoutPromise]);
    } finally {
        if (timer !== undefined) clearTimeout(timer);
    }
}
```

**变更**：`after()` 新增 `network.clearNetworkEvent()`，遵守 LF-CLEAN-001

```typescript
after(async () => {
    // ...
    // step 1: sleep(500)
    // step 2: network.clearNetworkEvent()       ★ 新增
    // step 3: AsyncBridge.shutdownInstance()
    // step 4: framework.exitMainThread()
    // step 5: app.dispose()
    // step 6: framework.shutdown()
});
```

**依据**：JS `LingoFuse_JS_Async_Fix_Report.md` §Bug A + README §12.8。解决 Bug A。

### 3.10 `tsconfig.json`

**变更**：`ignoreDeprecations` 从 `"5.0"` 改为 `"6.0"`

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

**依据**：TypeScript 6.0 将 `moduleResolution: "node10"` 标记为弃用。`ignoreDeprecations` 的值必须是**当前 TypeScript 版本对应的弃用版本号**。TypeScript 7.0 会彻底移除 `node10`，届时可迁移到 `"bundler"`（`tsx` 本质是打包器）。

---

## 四、PowerShell 脚本

### 4.1 `clean.ps1`

清空 `dist/` + `tsconfig.*.tsbuildinfo`。可选参数：

| 参数 | 行为 |
|------|------|
| `-IncludeNodeModules` | 同时删除 `node_modules/` + `package-lock.json` |
| `-IncludeCache` | 同时删除 `.cache/` |

### 4.2 `check_env.ps1`

**8 个检查段**：

1. PowerShell 版本（≥ 5.1）
2. Node.js（≥ 18）
3. npm
4. 项目结构（24 个必需文件）
5. `node_modules`（koffi / typescript / tsx / @types/node）
6. koffi native addon（实际加载 platform 库探测）
7. LingoFuse native 库（通过 `dist/binding.js` 走真实加载路径）
8. Report（failure / warning 计数）

**Exit code**：`0` = 无 failure，`1` = 有 failure。

### 4.3 `build.ps1`

**执行序列**：

1. 检查 `npm` / `node` 存在
2. `node_modules` 缺失则自动 `npm install`
3. `-Clean` 时 `npm run clean`
4. 除非 `-SkipCheck`，跑 `npm run check`（`tsc --noEmit`）
5. `npm run build`（`tsc -p tsconfig.build.json`）
6. 检查 `dist/index.js` 和 `dist/index.d.ts` 存在
7. 统计 `dist/*.js` / `dist/*.d.ts` 数量

**参数**：`-Clean`、`-SkipCheck`。

### 4.4 `test.ps1`

**参数**：

| 参数 | 值 | 默认 |
|------|----|------|
| `-Suite` | `all` / `v1` / `v2` / `cross` | `all` |
| `-Runtime` | `auto` / `node` / `bun` / `deno` | `auto`（优先 bun → deno → node） |
| `-SkipUnit` | flag | — |
| `-SkipCross` | flag | — |

**关键实现**：

#### Unit test 执行

直接启动 `node.exe` + `tsx cli.mjs`，**绕过 cmd / tsx.cmd**：

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
$proc.WaitForExit(300000)   # 5 分钟超时
```

**避免 pipe 死锁**：`ReadToEndAsync` 在另一个线程持续消费 pipe，父线程等待进程退出不会死锁。

#### Cross test 三进程协同

**固定 sleep + stdin 优雅退出**，放弃实时 pattern 匹配：

| 阶段 | 值 | 依据 |
|------|----|------|
| service 启动 | 10s | IPC 队列创建 + C4 mesh 初始化 < 3 秒，10 秒留余量 |
| node 连接 | 8s | `LF_PrepareClient` + 广播收敛 < 3 秒，8 秒留余量 |
| call 压测 | 18s | `TEST_SECONDS = 10` + `sleep(1ms)` 间隔 + 网络抖动，18 秒足够 |
| call 退出 grace | 15s | stdin 回车后，正常情况下 < 1 秒退出 |

**关键修复**：`Start-CrossProcess` **立即 `ReadToEndAsync()`**，任务持有在 handle 里：

```powershell
function Start-CrossProcess {
    param([string]$Name, [string]$ScriptRelPath)
    # ... 启动进程
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

**优雅退出**：

```powershell
function Request-CrossProcessExit {
    param($Handle, [int]$GraceMs = 15000)
    # ...
    $p.StandardInput.WriteLine("")       # 触发 waitForEnter()
    $p.StandardInput.Flush()
    return $p.WaitForExit($GraceMs)      # 15s grace
}

function Stop-CrossProcess {
    param($Handle)
    # 先 stdin 回车 + Wait 3s
    # 超时 taskkill /T /F /PID
    # 最后 Kill() 兜底
}
```

**数据流时序**：

```
T=0     service 启动        → ReadToEndAsync 在后台消费 pipe
T=10    service alive
T=10    node 启动           → ReadToEndAsync 在后台消费 pipe
T=18    node alive
T=18    call 启动           → ReadToEndAsync 在后台消费 pipe
T=36    call 内 10s 压测结束 → 打印 "[Call] Load test summary" + 统计
T=36    call 阻塞在 waitForEnter
T=36    PowerShell 发 stdin 回车 → waitForEnter 返回 → process 优雅退出
T=37    call Process 退出 → pipe EOF → ReadToEndAsync 任务完成
T=37    从 StdoutTask.GetResult() 拿完整输出
T=37    正则提取 total / failed / success
T=37    判定 pass
T=37    finally 里 Stop 3 个进程（此时都已退出或被杀）
```

**统计解析**：

```powershell
$totalMatch = [regex]::Match($combined, 'total calls\s*:\s*(\d+)')
$failedMatch = [regex]::Match($combined, 'failed\s*:\s*(\d+)')
$successMatch = [regex]::Match($combined, 'success\s*:\s*(\d+)')
```

**判定**：`total > 0` 且 `failed === 0` → pass。

---

## 五、验证结果

### 5.1 v1 基线测试

```
Summary
  runtime : Node.js 24.21.0
  passed  : 127
  failed  : 0
  total   : 127
```

### 5.2 v2.0 测试

```
Summary
  runtime : Node.js 24.21.0
  passed  : 99
  failed  : 0
  total   : 99
```

**覆盖范围**：

- App 名 async：`add`、`whoami`、`probe_output`、`log`（notify）
- UID async：`UIDTarget.callSync`、`UIDTarget.call`
- 三种调用风格：`callSync` / `call`（Promise）/ `callAsync`（inline callback）
- 并发：三个 `add` 调用通过 `await`
- side data：`getP2PUid` / `getP2PName` 在 INPUT handle 上有效，OUTPUT handle 上返回默认值
- `AsyncBridge` 生命周期：`stats`、`shutdown` 幂等

### 5.3 Cross test

```
Cross test: service + node + call
[ OK ]   service process is alive.
[ OK ]   node process is alive.
[ OK ]   call exited gracefully.
[INFO]   total=N  success=N  failed=0
[ OK ]   Cross test passed.
```

### 5.4 Cleanup 无 Access Violation

```
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 begin
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 done timeout=no
```

修复前：

```
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 begin
TC40_LF_Client.Destroy remove P2P update error: Access violation
TC40_LF_Client.Destroy remove app update error: Access violation
```

### 5.5 服务端收到请求

服务端日志：

```
[LF-DEBUG] SVC.cmd_Call: ENTER app="JsTest2" api="add"
[LF-DEBUG] SVC.cmd_Call: LOCAL path, HPC dispatch
```

**这是 async 请求真的到达服务端的铁证**。

---

## 六、关键设计决策

### 6.1 `AsyncOpView` 接口而非直接导入 `AsyncOp`

```typescript
interface AsyncOpView {
    readonly dataPtr: unknown;
}
```

**理由**：

- `Target._rawIssueAsyncCall` 只需要读 `op.dataPtr` 一个字段
- 用结构类型而非具体泛型类，避免 `AsyncOp<TRes>` 到 `AsyncOp<unknown>` 的协变问题
- 子类实现完全不需要关心 `AsyncOp` 类型

### 6.2 `Target.call` 的 `.then` 丢弃返回值

```typescript
promise.then(
    () => { try { param.dispose(); } catch { } },
    () => { try { param.dispose(); } catch { } },
);
return promise;   // 返回原始的 promise
```

`.then` 返回一个新的 `Promise<void>`，被丢弃。但因为两个回调都返回 `void`（不 throw），它是 **resolved** 状态 → 不会造成 unhandledRejection。**同时**，这个 `.then` 在 `_promise` 上注册了 reject handler，避免了 `_promise` 上的 unhandledRejection。

### 6.3 `Target.callAsync` 里先 dispose 后调用户回调

```typescript
(result, error, ud) => {
    try { param.dispose(); } catch { }   // ★ 先 dispose
    onResult(result, error, ud);        // ★ 再调用户
}
```

**顺序理由**：用户回调里即使访问 `param` 也已经 `disposed`，会得到明确的 `LingoFuseObjectDisposedError` 而不是 UB。`runLegacyOp` 在 dispatch 失败时会**同步调用** `onResult(null, error, userData)`，wrapper 会先 dispose 再调用户回调——顺序正确。

### 6.4 `callSync` 保持 `finally { param.dispose(); }`

`callSync` 是同步调用，native 在返回前已经读完了 payload。`finally { param.dispose(); }` 是**对的**，不是 Bug B。JS 修复报告也只在 `call` / `callAsync` / `sequencedCall` / `sequencedCallAsync` 上修 Bug B，`callSync` 不动。

### 6.5 `void apiName;` 抑制 unused 参数警告

子类 `_rawIssue*` 实现的 `apiName` 参数在 ABC 里定义，但子类实现不用（native 侧不需要）。`void apiName;` 明确告知 TS "我故意不用"。

### 6.6 PowerShell 放弃 pattern 匹配

**为什么放弃**：

- `.bat` 在 PowerShell 5.1 + 非 ASCII `$env:TEMP` 下不可靠
- cmd 的引号规则在 `""` 嵌套 + `> 2>` 重定向下极易出错
- 固定 sleep 最坏多花 15-20 秒，但**绝对可靠**

### 6.7 `GetNewClosure()` 不可用于 `DataReceived` 事件

早期版本尝试用 `.GetNewClosure()` 捕获 `$outQueue`，在 Windows PowerShell 5.1 中：

- `[DataReceivedEventHandler]({...}.GetNewClosure())` 强转 `[Delegate]` 时 closure 变量绑定丢失
- 典型报错：`Exception calling "add_OutputDataReceived"...`

**当前方案**：彻底放弃 `DataReceived`，改用 `ReadToEndAsync()` 返回 `Task<string>`，任务持有在 handle 里。

---

## 七、已知问题与后续事项

### 7.1 TypeScript 7.0 迁移

`moduleResolution: "node10"` 将在 TypeScript 7.0 中彻底移除。届时可迁移到 `"bundler"`（`tsx` 本质是打包器）。当前 `ignoreDeprecations: "6.0"` 是临时手段。

### 7.2 跨语言互通验证

当前 JS ↔ JS（service + call）已全绿。下一步验证 TS ↔ C++ / Pascal / C# 互通：

| 场景 | Service | Call | 数据协议 | 预期 |
|------|---------|------|---------|:----:|
| A | Pascal `LF_Test_ServFrm.pas` | TS `cross-call.ts` | raw binary | 待验证 |
| B | TS `cross-service.ts` | Pascal `LF_Test_CliFrm.pas` | raw binary | 待验证 |
| C | C++ `CrossService.cpp` | TS `cross-call.ts` | raw binary | 待验证 |
| D | TS `cross-service.ts` | C++ `CrossCall.cpp` | raw binary | 待验证 |

**注意**：TS ↔ 其他语言互通时，**wire protocol 必须一致**。`cross-call.ts` 用纯二进制（`writeInt32` / `writeUInt8` 等），其他语言的 `CrossCall.cpp` 等也用纯二进制，可以直接互通。

### 7.3 `test.ps1` 输出捕获的时序依赖

当前依赖"18 秒后 stdin 回车"触发 `waitForEnter()` 让 call 优雅退出。如果未来 `cross-call.ts` 的压测时长变长（比如改为 30 秒），需要同步调整 `Start-Sleep -Seconds` 值。

### 7.4 `AsyncBridge` 让 Node 事件循环无法退出

如果忘记调用 `AsyncBridge.shutdownInstance()`，Koffi 回调的 libuv 句柄会一直 ref'ed，Node 事件循环无法退出。**生产代码必须在进程退出前显式调用**：

```typescript
lf.AsyncBridge.shutdownInstance();
lf.framework.shutdown();
```

`test-v2.ts` 的 `after()` 已经遵守这个契约。

---

## 八、变更日志

| 日期 | 事件 |
|------|------|
| 2026-10-24 | 定位 4 个 async bug + 3 个 Koffi 回调资源顺序问题 |
| 2026-10-24 | 修复 `lf-io.ts`（新增 `readJsonTolerant`） |
| 2026-10-24 | 修复 `async-support.ts`（`dataPtr` 分配与释放） |
| 2026-10-24 | 修复 `network-events.ts`（换序） |
| 2026-10-24 | 修复 `p2p-registration.ts`（try/catch） |
| 2026-10-24 | 修复 `app-handle.ts`（dispose 顺序 + 错误信封 + try/catch） |
| 2026-10-24 | 修复 `framework.ts`（`dataPtr` 传参 + `readJsonTolerant`） |
| 2026-10-24 | 修复 `address.ts`（param 生命周期 + `dataPtr` 传参 + `readJsonTolerant`） |
| 2026-10-24 | 修复 `test/test.ts`（错误信封断言） |
| 2026-10-24 | 修复 `test/test-v2.ts`（race timer 去 unref） |
| 2026-10-24 | 修复 `tsconfig.json`（`ignoreDeprecations: "6.0"`） |
| 2026-10-24 | 交付 `clean.ps1` / `check_env.ps1` / `build.ps1` / `test.ps1` |
| 2026-10-24 | **验证：v1 127/127 PASS，v2 99/99 PASS，cross PASS，无 access violation** |

---

## 九、参考

- **JS 修复报告**：`LingoFuse_JS_Async_Fix_Report.md`
- **Pascal 权威文档**：`LingoFuse_Pascal_Complete_Guide.md`（§4.7 Handle 所有权、§10 身份注入、§14 线程模型）
- **JS 权威源码**：`lingofuse-js` v2.0.0（`async-support.js` / `address.js` / `framework.js` / `app-handle.js` / `network-events.js` / `p2p-registration.js` / `lf-io.js`）
- **C ABI 头文件**：`LingoFuse.h`
- **测试套件**：`test/test.ts`（127 项）、`test/test-v2.ts`（99 项）、`cross/cross-service.ts` + `cross/cross-node.ts` + `cross/cross-call.ts`

---

**文档结束**
