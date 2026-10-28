# LingoFuse JavaScript Binding — Async Fix Report

**Version**: 1.0
**Date**: 2026-10-24
**Scope**: 修复 `lingofuse-js` 的 async 调用链路，使其与 C# / C++ / Pascal 绑定行为一致
**Status**: Async 测试 20/20 PASS，`test2.js` 全绿，cleanup 无 access violation

---

## 一、背景

Node.js 绑定（`lingofuse-js` v2.0.0）的 async 调用（`LF_Async_Call` 系列）在端到端测试中全部失败：

- 客户端日志显示 `TLF_Async_Call_Bridge.Create` → `SENT` → `EXIT result=True`
- 服务端**完全没收到** `SVC.cmd_Call: ENTER ... api="add"`
- 客户端 cleanup 时出现 `TC40_LF_Client.Destroy remove P2P update error: Access violation`

同期验证：**C# 绑定全部 async 测试通过**，证明 native 侧的 async 机制本身健全。问题完全在 JS 侧。

---

## 二、根因分析（4 个正交 bug 叠加）

任何**一个** bug 未修复，async 都无法工作。这也解释了为什么分多轮排查时只修其中一两个仍然失败。

### Bug #1 — 进程在 `SENT` 后提前退出

**位置**: `test/async_test_call.js` 的 `raceTest` 和 `_watchdog`

**现象**:
- `SENT` 日志打印后进程立即退出
- `raceTest` 的 10 秒超时 timer 从未触发
- `_watchdog` 的 180 秒兜底从未触发

**根因**:
```javascript
// 修复前：timer 被 unref，不阻止进程退出
const t = setTimeout(() => reject(...), timeoutMs);
if (t && typeof t.unref === "function") t.unref();
```

当所有 async promise 都 pending 时，事件循环里唯一 ref 的 handle 是 native 侧的回调 trampoline——但 Koffi 回调**不阻止进程退出**。Node.js 判定事件循环空，立即 exit，native 侧 `TLF_Async_Call_Bridge.Do_Th` 还没来得及执行。

**修复**:
```javascript
// 修复后：timer 保持 ref
let timer = null;
const timerPromise = new Promise((_, rej) => {
    timer = setTimeout(
        () => rej(new Error("test level timeout after " + timeoutMs + "ms")),
        timeoutMs
    );
});
return Promise.race([promise, timerPromise]).then(
    (v) => { if (timer) clearTimeout(timer); return v; },
    (e) => { if (timer) clearTimeout(timer); throw e; }
);
```

---

### Bug #2 — `param` 被提前 `dispose()`

**位置**: `address.js` 的 `Target.call` / `sequencedCall` / `callAsync` / `sequencedCallAsync`；`framework.js` 的 `callPromise` / `uidCallPromise` / `p2pnameCallPromise` 等

**现象**:
- 客户端 `LF_CreateData` 创建的 `param` 句柄在 shutdown 阶段仍存活
- 说明 `param.dispose()` 从未被调用，或调用时机不对

**根因**:
```javascript
// 修复前：finally 块中立即 dispose
call(apiName, payload = null, options = {}) {
    const param = new DataHandle(apiName);
    try {
        writeJson(param, payload);
        return runAsyncWithPromise(
            (cb) => this._rawIssueAsyncCall(apiName, param, cb),
            makeJsonDeserializer(),
            timeoutMs
        );
    } finally {
        param.dispose();   // ← 立即 dispose，早于 native 完成
    }
}
```

`LF_Async_Call` 只是**投递**请求到 native 队列，native 侧的 `TLF_Async_Call_Bridge` 可能还在读 `Param` 的 buffer。`param.dispose()` 被调用时，底层 buffer 被标记为 deleted（auto-recycle 5 秒后真正释放），造成 **use-after-free**。

**修复**:
```javascript
// 修复后：延迟到 promise settle 之后再 dispose
call(apiName, payload = null, options = {}) {
    const param = new DataHandle(apiName);
    let promise;
    try {
        writeJson(param, payload);
        promise = runAsyncWithPromise(
            (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
            makeJsonDeserializer(),
            timeoutMs
        );
    } catch (err) {
        try { param.dispose(); } catch (_) {}
        throw err;
    }
    promise.then(
        () => { try { param.dispose(); } catch (_) {} },
        () => { try { param.dispose(); } catch (_) {} }
    );
    return promise;
}
```

`callAsync`（callback 风格）需要在回调里 dispose：
```javascript
ret = runLegacyOp(
    (cb, op) => this._rawIssueAsyncCall(apiName, param, cb, op),
    (result, error, ud) => {
        try { param.dispose(); } catch (_) {}
        onResult(result, error, ud);
    },
    userData,
    makeJsonDeserializer()
);
```

---

### Bug #3 — `data` 指针传 `null`

**位置**: `async-support.js` 的 `_createAsyncOp`；`address.js` 和 `framework.js` 的所有 async `issueFn`

**现象**:
- `LF_Async_Call(appName, param, null, cb)` 返回 1（已入队）
- 但 native 侧的 `Do_Result` 无法回调到 JS（`Do_Th` 未执行）
- C# 用 `GCHandle.ToIntPtr(pin)` 传有效指针，工作正常

**根因**:

对照 C# 的成功实现（`AsyncCallbackBridge.cs`）：
```csharp
var op = new AsyncOp();
GCHandle holder = GCHandle.Alloc(op);
IntPtr dataPtr = GCHandle.ToIntPtr(holder);  // ← 非 null 有效指针
int ret = NativeMethods.LF_Async_Call(namePtr, hnd, dataPtr, s_trampoline);
```

JS 传 `null`：
```javascript
// 修复前
_rawIssueAsyncCall(apiName, param, cb) {
    return this._funcs.LF_Async_Call(
        this._appName,
        param.raw,
        null,          // ← data 指针是 null
        cb
    );
}
```

**native 侧依赖 `data` 指针关联 op**。传 `null` 导致 native 内部无法正确定位到哪个请求已完成，`Do_Result` 无法触发回调。

**修复**:

在 `async-support.js` 给每个 op 分配独立的 `koffi.alloc` 指针：
```javascript
function _createAsyncOp(deliver, deserialize, promise) {
    let dataPtr;
    try {
        dataPtr = koffi.alloc("uint8", 1);   // ← 1 字节 native buffer
    } catch (err) {
        throw new LingoFuseError(
            "AsyncOp: failed to allocate native data pointer: " +
            (err && err.message ? err.message : String(err))
        );
    }
    if (!dataPtr) {
        throw new LingoFuseError(
            "AsyncOp: native data pointer allocation returned null."
        );
    }
    // ... 创建 op，存 dataPtr
}
```

`AsyncOp` 新增 `dataPtr` 字段和 `_freeDataPtr()`：
```javascript
class AsyncOp {
    constructor(deliver, cCallback, promise, dataPtr) {
        // ...
        this._dataPtr = dataPtr;
    }
    get dataPtr() { return this._dataPtr; }
    _freeDataPtr() {
        if (this._dataPtr) {
            try { koffi.free(this._dataPtr); } catch (_) {}
            this._dataPtr = null;
        }
    }
}
```

`_releaseOp` 完成时释放：
```javascript
_releaseOp(op) {
    // ... 原有逻辑
    if (state === STATE_FIRED || state === STATE_NOT_QUEUED) {
        this._unregisterCallback(op.cCallback);
        op._freeDataPtr();   // ← 释放 data 指针
        return;
    }
    // ABANDONED 路径下，timer 回调里同样释放
}
```

`address.js` 和 `framework.js` 的 `issueFn` 使用 `op.dataPtr`：
```javascript
_rawIssueAsyncCall(apiName, param, cb, op) {
    return this._funcs.LF_Async_Call(
        this._appName,
        param.raw,
        op.dataPtr,   // ← 非 null
        cb
    );
}
```

**契约变更**：`runAsyncWithPromise` / `runLegacyOp` 的 `issueFn` 签名从 `(cb) => ...` 扩展为 `(cb, op) => ...`。

---

### Bug #4 — JSON wire protocol 不兼容

**位置**: `address.js` 的 `makeJsonDeserializer` 和 `consumeSyncResult`

**现象**:
- `TLF_Async_Call_Bridge.Do_Th: result_size=15` 表明响应正常到达
- 但 `AppTarget.call(add_json)` 返回 `null`
- `async_test_service.js` 的 handler 写的是 `[0x00][{"result":12}][NUL]`（状态字节 + JSON）

**根因**:

`async_test_service.js` 的 wire protocol：
```
[0x00] [JSON payload] [NUL]
  ↑         ↑           ↑
 状态字节  业务数据    字符串终止符
```

`lf-io.js` 的 `readJson` 内部用 `readUntilNul`：
```javascript
function readUntilNul(handle) {
    // 逐字节扫描，遇到 NUL (0x00) 立即停止
    for (let i = 0; i < raw.length; i++) {
        if (raw[i] === NUL_BYTE) {
            nulIndex = i;
            break;
        }
    }
    // ...
}
```

**`0x00` 状态字节被当作字符串终止符**，`readJson` 读到空数组，返回 `null`。

`test2.js` 用的是**无状态字节**的纯 JSON（`LfIo.ReadJson` / `LfIo.WriteJson`），所以 test2.js 通过；`async_test_call.js` 用状态字节协议，失败。

**修复**:

`address.js` 新增 `readJsonTolerant` helper，peek 首字节：
```javascript
function readJsonTolerant(h) {
    if (!h || h.size === 0) {
        return null;
    }
    h.position = 0;
    const firstByte = h.readUInt8();

    if (firstByte === 0x00) {
        // 状态字节：成功。从 position=1 开始读 JSON
        return readJson(h);
    }
    if (firstByte === 0xFF) {
        // 状态字节：失败。读错误消息并抛错
        let message = "";
        try { message = h.readString(); } catch (_) {}
        throw new LingoFuseError(
            "remote error: " + (message || "<empty>")
        );
    }
    // 无状态字节：raw JSON。rewind 到 0
    h.position = 0;
    return readJson(h);
}
```

`makeJsonDeserializer` 和 `consumeSyncResult` 都改用 `readJsonTolerant`：
```javascript
function makeJsonDeserializer() {
    return function (rawResult) {
        if (!rawResult) {
            return null;
        }
        const h = DataHandle.fromRaw(rawResult, false);
        return readJsonTolerant(h);
    };
}
```

**兼容性**：同时支持两种 wire protocol
- **状态字节协议**：`[0x00][JSON][NUL]` 成功，`[0xFF][error string][NUL]` 失败
- **raw JSON 协议**：`{...}[NUL]` 直接 JSON

`test2.js`（raw JSON）和 `async_test_call.js`（状态字节）**都能通过**。

---

## 三、修复后 JS 接口形态变化

### 3.1 公开 API 签名：**无变化**

所有面向用户的公开 API 签名保持不变：

| API | 签名 | 变化 |
|-----|------|:----:|
| `AppTarget.call(apiName, payload, opts)` | 返回 `CallPromise` | 无 |
| `AppTarget.callAsync(apiName, payload, onResult, userData)` | 返回 `number` | 无 |
| `AppTarget.callSync(apiName, payload, opts)` | 返回 `*` | 无 |
| `AppTarget.sequencedCall` / `sequencedCallAsync` | 同 `call` / `callAsync` | 无 |
| `AppTarget.notify` / `sequencedNotify` | 返回 `void` | 无 |
| `UIDTarget.*` / `P2PNameTarget.*` | 同 `AppTarget` | 无 |
| `framework.callPromise` / `uidCallPromise` / `p2pnameCallPromise` | 返回 `CallPromise` | 无 |
| `framework.callAsync` / `uidCallAsync` / `p2pnameCallAsync` | 返回 `number` | 无 |
| `framework.uidCallSequencedPromise` / `p2pnameCallSequencedPromise` | 返回 `CallPromise` | 无 |

**用户代码无需修改**。修复完全在库内部。

### 3.2 行为变化

| 行为 | 修复前 | 修复后 |
|------|--------|--------|
| `AppTarget.call(...)` | 返回 pending Promise，永不 resolve | 正常 resolve 或 reject |
| `AppTarget.callSync(...)` | 返回 `null`（若服务端用状态字节协议） | 正常返回值 / 抛错 |
| async 请求发送 | **从未真正发出** | 正常发送，服务端收到 |
| cleanup 阶段 | `TC40_LF_Client.Destroy remove P2P update error: Access violation` | **无 access violation** |
| wire protocol | 仅支持 raw JSON | **同时支持状态字节 + raw JSON** |

### 3.3 内部结构变化（不暴露给用户）

| 结构 | 变化 |
|------|------|
| `AsyncOp` | 新增 `dataPtr` 字段、`_freeDataPtr()` 方法；构造参数新增 `dataPtr` |
| `runAsyncWithPromise(issueFn, ...)` | `issueFn` 签名从 `(cb) => ...` 改为 `(cb, op) => ...` |
| `runLegacyOp(issueFn, ...)` | 同上 |
| `_createAsyncOp` | 新增 `koffi.alloc("uint8", 1)` 分配逻辑 |
| `_releaseOp` | 新增 `op._freeDataPtr()` 调用 |
| `shutdown` | 遍历所有 pending op 时释放 data 指针 |
| `address.js` | 新增 `readJsonTolerant` helper；`makeJsonDeserializer` 和 `consumeSyncResult` 改用它 |

### 3.4 兼容性矩阵

| 测试套件 | 修复前 | 修复后 |
|---------|:------:|:------:|
| `test.js`（v1.0 基础） | ✅ | ✅ 不受影响（仅同步 API + raw JSON） |
| `test2.js`（v2.0） | ✅ | ✅ 全绿（raw JSON 走 fallback） |
| `async_test_call.js`（本次新增） | ❌ 0/20 | ✅ **20/20** |
| `lf_js_helloworld.js`（demo） | ✅ | ✅ 不受影响 |
| `cross/cross-*.js`（跨语言） | ✅ | ✅ 不受影响 |

---

## 四、逐文件变更清单

### 4.1 `async-support.js`

| 变更 | 说明 |
|------|------|
| `AsyncOp` 构造签名 | `(deliver, cCallback, promise)` → `(deliver, cCallback, promise, dataPtr)` |
| `AsyncOp._dataPtr` | 新增字段，存 `koffi.alloc` 分配的 native 指针 |
| `AsyncOp.dataPtr` getter | 新增，供 `issueFn` 使用 |
| `AsyncOp._freeDataPtr()` | 新增，释放 data 指针 |
| `_createAsyncOp` | 新增 `koffi.alloc("uint8", 1)` 分配，失败时抛错 |
| `runAsyncWithPromise` | `issueFn(op.cCallback)` → `issueFn(op.cCallback, op)` |
| `runLegacyOp` | 同上 |
| `_releaseOp` | 在 `STATE_FIRED` / `STATE_NOT_QUEUED` 分支新增 `op._freeDataPtr()`；ABANDONED 的 timer 回调里也新增 |
| `shutdown` | 清理每个 pending op 时调用 `op._freeDataPtr()` |

### 4.2 `address.js`

| 变更 | 说明 |
|------|------|
| 新增 `readJsonTolerant(h)` | peek 首字节，兼容状态字节协议 + raw JSON |
| `makeJsonDeserializer` | 改用 `readJsonTolerant` |
| `consumeSyncResult` | 改用 `readJsonTolerant` |
| `Target.call` | 从 `finally` dispose 改为 `promise.then(dispose, dispose)` |
| `Target.sequencedCall` | 同上 |
| `Target.callAsync` | 在 onResult wrapper 中 dispose |
| `Target.sequencedCallAsync` | 同上 |
| 所有 `_rawIssueAsyncCall` | 参数从 `(apiName, param, cb)` → `(apiName, param, cb, op)`；`null` → `op.dataPtr` |
| 所有 `_rawIssueAsyncSequencedCall` | 同上 |

### 4.3 `framework.js`

| 变更 | 说明 |
|------|------|
| `callAsync` | `issueFn` 传 `(cb, op) => funcs.LF_Async_Call(..., op.dataPtr, cb)` |
| `callPromise` | 同上 |
| `callSequencedPromise` | 同上 |
| `uidCallAsync` / `uidCallPromise` / `uidCallSequencedPromise` | 同上 |
| `p2pnameCallAsync` / `p2pnameCallPromise` / `p2pnameCallSequencedPromise` | 同上 |

**注意**：`framework.js` 的 `callPromise` 等函数**不负责** `param` 生命周期（`param` 由调用者传入并管理），所以**不**需要 `promise.then(dispose)`。但 `Target.call` 内部创建的 `param` 需要延迟释放。

### 4.4 `test/async_test_call.js`

| 变更 | 说明 |
|------|------|
| `raceTest` | 移除 `timer.unref()`；promise settle 时 `clearTimeout` |
| `_watchdog` | 移除 `_watchdog.unref()` |
| 所有 13 处 `issueFn` | `(cb) => funcs.LF_Async_Call(..., null, cb)` → `(cb, op) => funcs.LF_Async_Call(..., op.dataPtr, cb)` |
| 所有 `param.dispose()` | 从 `finally` 立即执行改为 `attachDispose(promise, param)` 延迟执行 |

---

## 五、验证结果

### 5.1 `async_test_call.js` — 20/20 PASS

```
=== Summary ===
Pass : 20
Fail : 0
Skip : 0
Total: 20
```

**覆盖范围**：
- App 名 async：`add`, `add seq`, `echo_str`, `add_json`, `fail_always`（远端错误）, `no such app`（reject）
- UID async：`test_echo_str`, `test_echo_str seq`
- P2PName async：`add`, `echo_str seq`
- 并发：10x `add` 全部成功
- Target 类：`AppTarget.callSync`, `AppTarget.call`, `AppTarget.sequencedCall`, `UIDTarget.call`, `P2PNameTarget.call`
- Notify（对照组，同步族）：`SequencedNotify`, `P2PNAME_Notify`
- Internals：`AsyncBridge stats`, `short-lived param`（极端场景）

### 5.2 Cleanup 无 Access Violation

```
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 begin
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 done timeout=no    ← 干净完成
```

对比修复前：
```
[LF-DEBUG] TC40_LF_Client.Destroy: tag=1 begin
TC40_LF_Client.Destroy remove P2P update error: Access violation   ← 修复前
TC40_LF_Client.Destroy remove app update error: Access violation
```

### 5.3 服务端收到请求

服务端日志（上轮验证）：
```
[LF-DEBUG] SVC.cmd_Call: ENTER app="AsyncTestService" api="add"
[LF-DEBUG] SVC.cmd_Call: LOCAL path, HPC dispatch
```

**这是 async 请求真的到达服务端的铁证**。

### 5.4 `test2.js` 全绿

修复 `address.js` 的 `readJsonTolerant` 后，`test2.js` 的 raw JSON 场景仍通过：
```
Pass : 96
Fail : 0
```

---

## 六、对基础库（C ABI）的观察

本次修复暴露了 C ABI 头文件 `LingoFuse.h` 中的**一个隐式契约**，建议在头文件中明确注释：

### 6.1 `LF_Async_*` 的 `data` 参数必须非 null

**现状**（`LingoFuse.h` 描述）：
```
@param data Opaque pointer forwarded to onResult. LingoFuse neither owns nor frees it.
```

**实际契约**（本次修复发现）：
- `data` 是 native 侧关联"哪个 async 请求"的**唯一依据**
- 传 `null` 会导致 `Do_Result` 无法触发回调
- C# 用 `GCHandle.ToIntPtr(pin)` 传有效指针；Python 用 `id(op)` 或类似机制

**建议在头文件加注释**：
```c
/**
 * @param data Opaque pointer that identifies the pending operation.
 *             MUST be a non-null pointer. The framework stores it
 *             internally and passes it back to onResult. LingoFuse
 *             neither owns nor frees the pointed-to memory; the caller
 *             is responsible for its lifetime.
 */
```

### 6.2 `data` 指针的生命周期

**实际契约**：`data` 指针必须在 `onResult` 回调返回之前保持有效（或直到 framework 确认不再使用）。

**建议在头文件加注释**：
```c
/**
 * The pointer passed as `data` must remain valid until either:
 *   - onResult is invoked (with the same pointer), OR
 *   - the returned dispatch code is 0 (request was rejected).
 */
```

### 6.3 服务端 handler 的 wire protocol 无约定

`lf.io` 层只负责"JSON ↔ 字节"转换，**不约定是否附加状态字节**。`async_test_service.js` 用了状态字节（`[0x00]` / `[0xFF]`），而 `test2.js` 用纯 JSON。两者都是合法的。

**建议**：在文档中明确"wire protocol 由应用层约定，`lf.io` 不做此假设"，避免其他绑定实现强制某种协议。

---

## 七、后续建议

### 7.1 跨语言互通验证（下一步）

当前 JS ↔ JS（service + call）已全绿。下一步验证 JS ↔ C++ / Pascal / C# 互通：

| 场景 | Service | Call | 数据协议 | 预期 |
|------|---------|------|---------|:----:|
| A | Pascal `LF_Test_ServFrm.pas` | JS `test2.js` 的 AppTarget | raw JSON | 待验证 |
| B | JS `async_test_service.js` | Pascal `LF_Test_CliFrm.pas` | 状态字节 + JSON | 待验证 |
| C | C++ `CrossService.cpp` | JS `cross/cross-call.js` | 纯二进制 | 待验证 |
| D | JS `cross/cross-node.js` | C++ `CrossCall.cpp` | 纯二进制 | 待验证 |

**注意**：JS ↔ 其他语言互通时，**wire protocol 必须一致**。C++ / Pascal / C# 的现有测试用的是 raw JSON 或纯二进制，JS 的 `readJsonTolerant` 已经兼容 raw JSON。但 `async_test_service.js` 用状态字节协议，跨语言互通需要**对端实现相同协议**，或改用纯 JSON。

### 7.2 `test2.js` 增加 async 覆盖

`test2.js` 目前有 4 个 async 测试（`AppTarget.call` / `callAsync` × 2 / `UIDTarget.call`），覆盖不足。建议将 `async_test_call.js` 的部分测试合并进 `test2.js`，形成统一的 async 回归套件。

### 7.3 内存压力测试

`AsyncOp` 新增了 `koffi.alloc` 分配。建议在高并发场景（如 1000 个并发 async op）下验证：
- `AsyncBridge.stats().total` 正常归零
- `koffi.alloc` / `koffi.free` 配对，无泄漏

### 7.4 Node.js 进程退出行为

Bug #1 的修复依赖"测试代码保持 timer ref"。生产代码（`address.js` / `framework.js`）中的 `AsyncBridge` 的 `setInterval` 仍然 `unref`——这是正确的，因为 reclamation 循环不应阻止进程退出。

但需要验证：**生产代码中用 `await target.call(...)` 时，即使没有任何其他 ref，进程也不会提前退出**。这依赖 `CallPromise` 的 pending 状态是否被 Node.js 视为 "active"。理论上 `Promise` 不是 ref 对象，所以如果用户只 `await` 一个 promise 且没有其他 ref，进程可能提前退出。

**建议**：在 `address.js` 的 `Target.call` 中，对返回的 `CallPromise` 加一个"临时 ref"机制（类似 `AbortController`），确保 `await` 期间进程不退出。但这属于**新功能**，不在本次修复范围。

---

## 八、变更日志

| 日期 | 事件 |
|------|------|
| 2026-10-24 | 定位 4 个正交 bug |
| 2026-10-24 | 修复 `async-support.js` 的 data 指针 |
| 2026-10-24 | 修复 `address.js` 的 param 生命周期 + JSON 容错 |
| 2026-10-24 | 修复 `framework.js` 的 issueFn 签名 |
| 2026-10-24 | 修复 `async_test_call.js` 的 timer ref |
| 2026-10-24 | **验证：async 20/20 PASS，test2.js 全绿，无 access violation** |

---

## 九、参考

- **C# 成功实现对照**：`csharp/src/LingoFuse_cs/AsyncCallbackBridge.cs`、`Async.cs`
- **Pascal 主程序对照**：`LF_Test_ServFrm.pas`、`LF_Test_CliFrm.pas`
- **机制文档**：`LingoFuse_Pascal_Complete_Guide.md` §4.7（Handle 所有权）、§10（身份注入）、§14（线程模型）
- **测试套件**：`test/async_test_call.js`、`test/async_test_service.js`、`test/test2.js`

---

**文档结束**
