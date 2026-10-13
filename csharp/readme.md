# LingoFuse C# 绑定

> **跨语言通讯地基的 C# 官方绑定、完整测试、三方向 HTTP Bridge、跨语言 ABI 互操作、UID / P2PName 寻址、Task 化异步调用、回调风格异步、可插拔回调线程调度。**
>
> 本目录是 .NET 开发者使用 LingoFuse 的唯一起点。读完本 README 即可知道：
> - C# 绑定到底覆盖了什么；
> - 每个模块是干什么的；
> - 测试覆盖了哪些场景；
> - 常见坑在哪里。

---

## 1. 结论先说：C# 支持完善程度

LingoFuse 的 C# 绑定已经形成完整闭环，**不是"能跑示例"的水平，而是生产可用级绑定**。

| 维度 | 状态 | 说明 |
|------|:----:|------|
| P/Invoke 底层绑定 | ✅ 完整 | `NativeMethods.cs` 导入全部 **59 个** C ABI 导出函数，含完整 XML 注释 |
| RAII 封装 | ✅ 完整 | `DataHandle` / `AppHandle`，支持 `using` 和 `IDisposable` |
| UID 值类型 | ✅ 完整 | `P2PUid` — 32 字节 blittable struct，无需 unsafe |
| 统一 JSON I/O | ✅ 完整 | `LfIo` 是唯一序列化入口，保证跨语言字节一致 |
| 强类型运行时选项 | ✅ 完整 | `RuntimeOptions` — 覆盖全部 16 个 `set_opt_xxx` / `get_opt_xxx` |
| 回调线程调度 | ✅ 完整 | `CallbackDispatcher` — Inline / MainThread / 单线程队列 / 自定义 |
| 进程级门面 | ✅ 完整 | `Framework` 提供网络准备、远程调用、选项、关闭 |
| App 名寻址 | ✅ 完整 | `Call` / `Notify` / `SequencedNotify` + 异步变体 |
| UID 寻址 | ✅ 完整 | `CallByUid` / `NotifyByUid` / `SequencedNotifyByUid` + 异步变体 |
| P2PName 寻址 | ✅ 完整 | `CallByP2PName` / `NotifyByP2PName` / `SequencedNotifyByP2PName` + 异步变体 |
| 异步调用 | ✅ 完整 | `Task<DataHandle>` — 兼容 C# `await` 与 `SynchronizationContext` |
| 回调风格异步 ★ | ✅ 完整 | `Async.Call(..., r => {...})` — 调用与回调同一表达式，对齐 C++ / Pascal |
| 发送方身份 | ✅ 完整 | `DataHandle.GetSenderUid` / `GetSenderP2PName` |
| 全局 P2P 注册 | ✅ 完整 | `Framework.RegisterP2PCall` / `RegisterP2PNotify` / `UnregisterP2P` |
| 网络事件 | ✅ 完整 | `NetworkEvents` 全局 connect / disconnect 回调 |
| 状态与健康检查 | ✅ 完整 | `LingoFuseStatus` 状态队列 + 探活 + UID / P2PName 探活 |
| 异常层次 | ✅ 完整 | 5 个异常类型，覆盖加载 / 调用 / I/O / 已释放 |
| 永久句柄 | ✅ 完整 | `DataHandle.CreatePermanent` |
| 多线程并发 | ✅ 已测试 | 10 线程 × 100 本地调用；8 线程 × 500 独立句柄 |
| 跨语言 ABI | ✅ 已测试 | 逐字节小端序验证，与 C++ / Pascal / Python 字节一致 |
| 跨语言 JSON | ✅ 已测试 | Emoji / 中文无 `\uXXXX` 转义 |
| 性能压测 | ✅ 有 | `CrossCall` 32 线程负载测试 |
| 测试覆盖 | ✅ 完整 | v4.0 test 套件 **58 项** + v5.0 test2 套件 **58 项** = **116 项** |
| 跨平台 | ✅ 完整 | Windows / Linux / macOS，自动解析动态库 |
| 文档 | ✅ 完整 | `LingoFuse_CSharp_Complete_Guide.md` v5.1，含 17 章 + 4 附录 |
| CI | ⚠️ 仅 C++ 有 GitHub CI | C# 测试以本地运行为准 |

**总体判断**：C# 绑定覆盖了从底层 P/Invoke 到高级 RAII 封装、统一 JSON I/O、跨语言 ABI 互操作、UID / P2PName 寻址、Task 化异步调用、回调风格异步、可插拔回调线程调度、网络事件、状态检查的完整链路，并附带 **116 项可运行测试**。

---

## 2. 目录结构

```text
csharp/
├── src/
│   └── LingoFuse_cs/                  # 主绑定库
│       ├── LingoFuse_cs.csproj        # 库工程
│       ├── Async.cs                   # ★ v5.1  回调风格异步门面
│       ├── AsyncResult.cs             # ★ v5.1  回调结果只读值类型
│       ├── P2PUid.cs                  # ★ v5.0  32 字节 UID 值类型
│       ├── CallbackDispatcher.cs      # ★ v5.0  回调线程调度抽象
│       ├── RuntimeOptions.cs          # ★ v5.0  强类型运行时选项
│       ├── DataHandle.cs              # RAII 数据句柄（含 v5.0 GetSenderUid / GetSenderP2PName）
│       ├── AppHandle.cs               # RAII 应用句柄（含 v5.0 dispatcher 重载）
│       ├── Framework.cs               # 进程级门面（含 v5.0 UID / P2PName / Async / P2P 注册）
│       ├── LfIo.cs                    # 统一 JSON / 字符串 I/O
│       ├── NetworkEvents.cs           # 全局网络事件
│       ├── LingoFuseStatus.cs         # 状态队列 + 健康检查
│       ├── LingoFuseException.cs      # 异常层次
│       └── Native/
│           ├── NativeMethods.cs       # P/Invoke 声明（唯一 native 调用点）
│           ├── NativeTypes.cs         # 不透明句柄 + TUIDNative + 回调原型
│           ├── Utf8Marshal.cs         # UTF-8 NUL 终止字符串编组
│           └── AsyncCallbackBridge.cs # ★ v5.0  Task ↔ C ABI holder/trampoline
│
├── test/                              # v4.0 测试套件（58 项）
│   ├── Program.cs                     # 完整回归测试
│   └── test.csproj
│
├── test2/                             # ★ v5.0 / v5.1 测试套件（58 项）
│   ├── Program.cs                     # 专注覆盖 v5.0 / v5.1 新增 API 面
│   └── test2.csproj
│
├── CrossCall/                         # 负载测试客户端
│   ├── CrossCall.cs                   # 32 线程 × 10 秒
│   └── CrossCall.csproj
│
├── CrossNode/                         # 工作节点
│   ├── CrossNode.cs                   # 注册 add / inv_seri API
│   └── CrossNode.csproj
│
├── CrossService/                      # 协调者 / 信标
│   ├── CrossService.cs
│   └── crossService.csproj
│
├── build.ps1                          # 一键编译（支持 -Target Test / Pack）
├── clean.ps1                          # 一键清理（含 publish/ 与 artifacts/）
├── publish.ps1                        # 一键发布（支持 -SkipTests）
├── lf_csharp.sln                      # Visual Studio 解决方案
├── LingoFuse_CSharp_Complete_Guide.md # 完整指南（v5.1，17 章 + 4 附录）
└── readme.md                          # 本文件
```

---

## 3. 核心模块详解

### 3.1 `NativeMethods.cs` — P/Invoke 声明

**职责：**

- 声明全部 **59 个** C ABI 导出（v5.0 从 37 个扩展到 59 个）。
- 使用 `NativeLibrary.SetDllImportResolver` 自动选择平台库：
  - Windows 64 → `LingoFuse64.dll`
  - Windows 32 → `LingoFuse32.dll`
  - Linux / BSD → `liblingofuse.so`
  - macOS → `liblingofuse.dylib`
- 所有函数使用 `CallingConvention.Cdecl`。
- 字符串参数声明为 `IntPtr`，由 `Utf8Marshal` 处理编组。
- UID 参数使用 `TUIDNative`（32 字节 blittable struct），与 Pascal `array[0..31] of Byte` 二进制兼容。

**注意：** 这是 internal 层，用户代码永远不直接调用。

### 3.2 `NativeTypes.cs` — 不透明句柄 + UID + 回调原型

| 类型 | 说明 |
|------|------|
| `DataHnd` | 数据句柄（`IntPtr` 包装，含 `IsValid` / `Null`） |
| `AppHnd` | 应用句柄（同上） |
| `TUIDNative` | ★ 32 字节 blittable UID（4 × `ulong`），P/Invoke 传值 |
| `LfCallFunc` | Call 回调原型 `(trigger, input, output) → void`，`cdecl` |
| `LfNotifyFunc` | Notify 回调原型 `(trigger, input) → void`，`cdecl` |
| `LfNetworkEventFunc` | 网络事件回调原型 `(addr) → void`，`cdecl` |
| `LfAsyncCallOnResult` | ★ 异步完成回调原型 `(data, result) → void`，`cdecl` |

**关键：** 所有回调使用 `[UnmanagedFunctionPointer(CallingConvention.Cdecl)]`。

### 3.3 `Utf8Marshal.cs` — UTF-8 编组

**职责：**

- `Alloc(string) → IntPtr`：分配 NUL 终止 UTF-8 非托管内存。
- `Free(IntPtr)`：释放。
- `PtrToString(IntPtr) → string`：从非托管内存拷贝并解码。

**契约：**

- `Alloc` 返回的内存必须由调用者用 `Free` 释放。
- `PtrToString` 立即拷贝，返回后源指针可被释放。
- `Free(IntPtr.Zero)` 是 no-op。

### 3.4 `P2PUid.cs` — 32 字节 UID 值类型（★ v5.0）

**`readonly struct`，值语义，零 GC 压力。**

**为什么需要专门类型：**

- UID 是 LingoFuse 路由模型的一等公民：UID 寻址的主键；回调内 `GetSenderUid()` 的返回类型；32 字节二进制 blob，必须逐字节跨语言往返。
- 用 `byte[]` 会引入可变性、引用相等性、无 32 字节约束。
- 用 `unsafe fixed byte[32]` 需要 `AllowUnsafeBlocks`（本绑定避免）。
- 用 4 × `ulong`：blittable、无 unsafe、无分配、值相等。

**API：**

| 成员 | 签名 |
|------|------|
| `Empty` | `static readonly P2PUid`（全零） |
| `IsEmpty` | `bool` |
| `FromBytes(ReadOnlySpan<byte>)` | `static P2PUid`（要求 32 字节） |
| `TryParse(string?, out P2PUid)` | `static bool`（64 hex 字符） |
| `Parse(string)` | `static P2PUid` |
| `ToByteArray()` | `byte[]` |
| `CopyTo(Span<byte>)` | `void` |
| `ToHexString()` | `string`（64 小写 hex） |
| `ToString()` / `Equals` / `GetHashCode` / `==` / `!=` | 结构化相等 |

**字节序**：4 个 `ulong` 字段按小端序布局（`_lo` 覆盖字节 0..7，`_hi` 覆盖 8..15，`_top` 覆盖 16..23，`_last` 覆盖 24..31），与 Pascal `array[0..31] of Byte` 逐字节兼容。

**用法**：

```csharp
var uid = input.GetSenderUid();
if (!uid.IsEmpty) sessions[uid] = new Session();

using var param = new DataHandle("api");
using var resp = Framework.CallByUid(uid, param, 5000);
```

**⚠️ 关键陷阱**：UID **在每次重连时重新生成**。缓存跨 link-loss 会导致 `CallByUid` 返回 size-0 句柄。重连后需重新发现（见 §6.4）。

### 3.5 `CallbackDispatcher.cs` — 回调线程调度（★ v5.0）

**抽象**：

```csharp
public interface ILingoCallbackDispatcher
{
    void Dispatch(Action callback);
}
```

**同步契约（核心）**：

> **`Dispatch` 必须在 callback 执行完成后才返回。**

原因：C ABI 的 `input` / `output` 句柄**只在回调体内有效**。native 层在回调函数返回的瞬间释放它们。如果 `Dispatch` 是 post-and-forget，worker 线程提前返回 → 框架释放句柄 → UI 线程访问已释放内存 → **use-after-free**。

因此 `Dispatch` 是同步语义。worker 线程会阻塞，直到 callback 在目标线程上执行完毕。

**内置 dispatcher**：

| 名称 | 行为 |
|------|------|
| `CallbackDispatcher.Inline` | 默认。直接在 worker 线程执行，零开销 |
| `CallbackDispatcher.MainThread` | post 到捕获的 `SynchronizationContext`，阻塞 worker 至完成 |
| `CallbackDispatcher.CreateSingleThreadedQueue(name?)` | 专用后台线程 + FIFO 队列 |
| `CallbackDispatcher.CreateCustom(Action<Action>)` | 用户自定义调度委托 |

**主线程捕获**：

```csharp
// 在 UI 线程启动时（WPF App.OnStartup / WinForms Main / MAUI MauiProgram / Avalonia OnFrameworkInit）
CallbackDispatcher.CaptureMainThread();
```

**⚠️ 死锁风险**：如果 UI 线程同步阻塞在 `Framework.Call` 上，同时 worker 尝试 dispatch 回 UI 线程 → 死锁。用 `CallAsync` + `await` 避免。

**异常策略**：dispatcher **不捕获** callback 异常——由 bridge 捕获并走 `Framework.ReportCallbackError`。dispatcher 必须把异常**原样**传播回 worker 线程。

### 3.6 `RuntimeOptions.cs` — 强类型运行时选项（★ v5.0）

**覆盖全部 16 个 `set_opt_xxx` / `get_opt_xxx` 选项，编译期校验拼写。**

**为什么需要：**

- C ABI 的 `LF_SetOption(name, value)` 是 stringly-typed：未知选项**静默忽略**，拼错、空格、大小写都会导致设置无效而无任何提示。
- 值必须手工解析。
- 无 discoverable list。

**完整属性列表**：

| 分类 | 属性 | 类型 |
|------|------|------|
| 认证 | `Password` | `string`（getter 返回掩码） |
| 日志 | `Quiet` / `ShowThreadId` / `ConsoleOutput` | `bool` |
| 日志 | `SetDebugCommand(string)` | write-only |
| 连接 | `OverlapConnection` | `bool` |
| 连接 | `WaitConnectionReadyOk` | `bool` |
| 连接 | `WaitConnectionTimeoutMs` | `ulong` |
| IPC | `IpcServerThreadCount` / `IpcServerMaxQueueLength` / `IpcServerMaxMsgSize` | `int` |
| 顺序 | `FixedSequencedTimeMs` | `ulong` |
| P2P | `P2PName` | `string` |
| 句柄池 | `DataHandleIdleTimeoutMs` / `DataHandlePoolScanIntervalMs` | `ulong` |
| 刷新 | `NoReponseCmdNullFlushThreshold` | `int` |

**逃生舱**：`GetRaw(string)` / `SetRaw(string, string)`。

**值格式**：bool 写 `"True"` / `"False"`（canonical）；读兼容 `"1"` / `"0"` / `"Yes"` / `"No"`。int / ulong 用 `InvariantCulture`。**未知选项返回类型安全默认值，不抛异常**。

**作用域**：进程级；`Framework.Shutdown` 后丢失。

### 3.7 `DataHandle.cs` — 数据句柄

**RAII 封装，支持 `using`。**

两种类型：

| 类型 | 创建方式 | 自动回收 | 释放时机 |
|------|----------|:--------:|----------|
| 自动回收 | `new DataHandle(api)` | 10 分钟空闲 | `Dispose` 标记，下次扫描释放 |
| 永久 | `DataHandle.CreatePermanent(api)` | 永不 | `Dispose` 同步释放 |
| 借用 | `DataHandle.FromRaw(raw, owned: false)` | 由 native 层管理 | `Dispose` 是 no-op |

**I/O 家族：**

| 家族 | 方法 | 行为 |
|------|------|------|
| 部分读取 | `ReadBytes(n)` | 返回至多 n 字节，不抛异常 |
| 精确读取 | `ReadBytesExact(n)` | 少于 n 抛 `LingoFuseIoException` |
| Try 家族 | `TryReadBytes` / `TryReadInt32` 等 | 返回 bool，不抛异常 |
| 全读 | `ReadAllBytes()` | 读完剩余字节 |

**原子类型（小端序）：** 10 种 Write + 10 种精确 Read + 10 种 TryRead。

**字符串契约：**

- `WriteString(s)`：UTF-8 + NUL。空字符串写 1 字节（NUL）。
- `ReadString()`：读到第一个 NUL，或无 NUL 读到末尾。无效 UTF-8 逐字节替换为 U+FFFD。

**发送方身份（★ v5.0）：**

```csharp
public P2PUid GetSenderUid()
public string GetSenderP2PName()
```

**只在回调的 `input` 参数上有效**。其他句柄返回 `P2PUid.Empty` / `""`，**不抛异常**。返回值是**拷贝**，可以安全存储和跨线程传递。

### 3.8 `LfIo.cs` — 统一 JSON / 字符串 I/O

**这是工具链唯一序列化入口。**

**JSON 序列化策略（私有，不可配置）：**

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

**关键保证：**

- **无 `\uXXXX` 转义**：BMP 字符和补充平面字符（emoji）都以字面 UTF-8 输出。
- **`UnescapeSurrogatePairs`**：将 `\uD8xx\uDCxx` 代理对还原为原始字符，确保 emoji 字节与 Pascal / Python / C++ 一致。

**API：**

| 方法 | 用途 |
|------|------|
| `WriteString` / `ReadString` | NUL 终止字符串 |
| `WriteStringBytes` / `ReadStringBytes` / `ReadAllBytes` | 字节流 |
| `WriteJson` / `ReadJson<T>` | JSON 读写 |
| `TryReadJson<T>` | 非抛出 JSON 读 |

**为什么没有公开 `JsonSerializerOptions`：** 暴露它们会诱使调用者构造第二条序列化路径，破坏线协议契约。要改变 JSON 形状，请用 `[JsonPropertyName]` / `[JsonIgnore]` / `[JsonConverter]` 注解你的类型。

### 3.9 `AppHandle.cs` — 应用句柄

**RAII 封装，`IDisposable`。**

| 方法 | 用途 |
|------|------|
| `RegisterCall(api, desc, Action<DataHandle, DataHandle>)` | 注册 Call API（inline 线程） |
| `RegisterCall(api, desc, handler, ILingoCallbackDispatcher)` | ★ v5.0 注册 Call API（自选线程） |
| `RegisterNotify(api, desc, Action<DataHandle>)` | 注册 Notify API（inline 线程） |
| `RegisterNotify(api, desc, handler, ILingoCallbackDispatcher)` | ★ v5.0 注册 Notify API（自选线程） |
| `Unregister(api)` | 注销 API |
| `LocalCall(param)` | 本地 Call（在调用者线程上执行 handler） |
| `LocalNotify(param)` | 本地 Notify |
| `Bind()` | 绑定到空闲客户端 |

**回调模型：**

- 用户回调接收 **borrowed** `DataHandle`（owned = false）。
- **回调中不得 `Dispose` 输入/输出句柄**（no-op 但无意义）。
- **回调异常被捕获**，通过 `Framework.ReportCallbackError` 上报。

**线程安全：**

- 所有公开方法在 `_registrationsLock` 下串行化，防止注册与 Dispose 竞争。
- `_handle` 声明为 `volatile`。

**两阶段析构：**

1. `Dispose` → `LF_FreeApp`：解绑客户端 + 停止顺序通知线程，对象仍在全局池。
2. `Framework.Shutdown` → 清空池，真正销毁所有对象。

### 3.10 `Framework.cs` — 进程级门面

**职责：**

| 分类 | 方法 |
|------|------|
| 网络准备 | `ResetPrepare` / `PrepareService` / `PrepareClient` / `PrepareDone` / `ExitMainThread` |
| App 名同步 | `Call` / `TryCall` / `Notify` / `SequencedNotify` |
| App 名异步 ★ | `CallAsync` / `CallSequencedAsync` |
| UID 同步 ★ | `CallByUid` / `NotifyByUid` / `SequencedNotifyByUid` |
| UID 异步 ★ | `CallByUidAsync` / `CallByUidSequencedAsync` |
| P2PName 同步 ★ | `CallByP2PName` / `NotifyByP2PName` / `SequencedNotifyByP2PName` |
| P2PName 异步 ★ | `CallByP2PNameAsync` / `CallByP2PNameSequencedAsync` |
| 探活 ★ | `CheckUid` / `CheckUidApi` / `CheckP2PName` / `CheckP2PNameApi` |
| P2P 注册 ★ | `RegisterP2PCall` (×2) / `RegisterP2PNotify` (×2) / `UnregisterP2P` |
| 选项 | `SetOption`（原始字符串接口） |
| 应用名 | `GenerateAppName` / `GetAppName` |
| 关闭 | `Shutdown` |
| 回调错误 | `CallbackErrorHandler` 属性 |

**关键契约：**

- `PrepareDone` **每进程只返回 1 一次**，第二次返回 0（非失败）。
- `Call` 超时返回 **size = 0 的句柄**，不是 null。
- `TryCall` 返回 `null`（已 Dispose 空句柄），或返回非空 `DataHandle`。
- `Shutdown` 幂等。
- **P2P 注册的 bridge 由内部静态字典持有**，`Shutdown` 时清空。

### 3.11 `AsyncCallbackBridge.cs` — Task 桥接（★ v5.0，internal）

**职责：**

- 把 C ABI 的 6 个异步调用原语包装为 `Task<DataHandle>`。
- **单 trampoline**：所有入口共享一个 `LfAsyncCallOnResult` 函数指针常量。
- **GCHandle 生命周期**：成功分派 → 回调释放；失败分派 → 调用者释放；P/Invoke 抛异常 → `catch` 释放。
- **结果物化**：在 callback 体内**立即拷贝**框架持有句柄的 payload（1 MiB 分块）到新建自有句柄——**绝不暴露框架持有的裸指针**。
- **分派失败 → `Task` Faulted**：抛出 `LingoFuseCallException`，与同步路径统一。

**关键设计：无 `RunContinuationsAsynchronously`**

`TaskCompletionSource` **不设置** `RunContinuationsAsynchronously`。原因：

- 保持与 BCL 内建 async API（`HttpClient.GetAsync` / `Stream.ReadAsync` / …）**一致的语义**。
- `await` 在有 `SynchronizationContext` 时**回到该 context**（UI 场景）。
- 无 SyncContext 时（控制台 / 后台服务）continuation 内联在完成线程上。
- 用户显式 `ConfigureAwait(false)` 可强制内联。

**⚠️ 本地 App 名异步调用同步完成（重要语义）**：

当目标 App 是**本进程**时，C ABI 的 `LF_Async_Call` 会在**返回前同步**触发完成回调。后果：

- `Task<DataHandle>` 在 `CallAsync` 返回时**已完成**。
- 后续 `await` **不挂起**——continuation 直接内联在当前线程上执行，**不 post 到任何 SyncContext**。

在 UI 线程上 `await CallAsync("LocalApp", ...)`，continuation **仍在 UI 线程**——行为正确（UI 线程从未 yield），但与远程场景的 `SyncContext.Post` 不同。

**不要依赖 `await` yield**。如果代码必须运行在特定线程，显式 marshal。

### 3.12 `NetworkEvents.cs` — 全局网络事件

| 方法 | 用途 |
|------|------|
| `Set(onConnect, onDisconnect)` | 安装回调（**REPLACE 语义**） |
| `Clear()` | 移除全部回调 |
| `IsInstalled` | 是否已安装 |

**语义：**

- **Connect**：首次收到服务端 API 广播。**不是 TCP 建链。**
- **Disconnect**：物理链路丢失一次。自动重连不触发 Disconnect。

**线程契约：**

- 回调在 native worker 线程执行。
- 不要操作 UI。
- 不要调用阻塞 LF 函数。
- 端点字符串由 wrapper 立即拷贝为托管 string。

**GC 保活：** wrapper 用静态字段保持 `LfNetworkEventFunc` 委托存活。

### 3.13 `LingoFuseStatus.cs` — 状态与健康检查

| 方法 | 用途 |
|------|------|
| `GetStatusCount()` | 待处理消息数（上限 1000） |
| `GetStatus()` | 取出一条消息（静态缓冲，立即拷贝） |
| `DrainStatus(max)` | 批量取出 |
| `PostStatus(msg)` | 注入消息 |
| `CheckMainThread()` | 主线程是否运行 |
| `CheckApp(name)` | 探活 App（**缓存约 3 秒延迟**） |
| `CheckApi(app, api)` | 探活 API（同上） |

**注**：UID / P2PName 探活是 `Framework.CheckUid` / `CheckP2PName`，见 §3.10。

### 3.14 `LingoFuseException.cs` — 异常层次

```text
LingoFuseException
├── LingoFuseLibraryLoadException    (加载失败——目前不抛)
├── LingoFuseCallException           (远程调用失败——TargetApp/TargetApi)
├── LingoFuseIoException             (短读 / 短写——Operation)
└── LingoFuseObjectDisposedException (已释放后使用——ObjectName)
```

### 3.15 `Async.cs` / `AsyncResult.cs` — 回调风格异步（★ v5.1）

**回调风格异步门面，把"调用 + 回调"合并为单一表达式。**

**为什么需要：**

- C++ 绑定用 `lingofuse::callAsync("App", req, [](AsyncResult r){...})`；Pascal 绑定用 `LF.AsyncCallApp_P('App', Data, procedure(Result_) ...)`。
- await 风格（`Framework.CallAsync`）把结果**拷贝**到新句柄后交给 `Task`。适合 UI 应用。
- 回调风格（`Async`）把结果**借用**给回调体，回调返回即释放。适合服务端逻辑、嵌入式、与 C++/Pascal 一致的集成。

**API：**

| 方法 | 用途 |
|------|------|
| `Async.Call(appName, request, onResult)` | App 名寻址 |
| `Async.Call<T>(appName, apiName, payload, onResult)` | App 名 + JSON 便利重载 |
| `Async.CallSequenced(...)` | App 名，FIFO |
| `Async.CallByUid(uid, request, onResult)` | UID 寻址 |
| `Async.CallByUidSequenced(...)` | UID，FIFO |
| `Async.CallByP2PName(group, request, onResult)` | P2PName 寻址 |
| `Async.CallByP2PNameSequenced(...)` | P2PName，FIFO |

所有方法返回 `void`；完成信号通过 `Action<AsyncResult>` 传出。

**AsyncResult 契约：**

| 成员 | 说明 |
|------|------|
| `Ok` | `true` = 拿到结果句柄；`false` = 派发失败 |
| `Error` | `Ok == false` 时的原因 |
| `Size` | 载荷字节数 |
| `Handle` | 借用 `DataHandle`，仅回调体内有效 |
| `ReadString()` / `ReadAllBytes()` / `ReadJson<T>()` | 拷贝数据的便捷方法 |

**生命周期**：`AsyncResult` 仅在回调 lambda 执行期间有效。lambda 返回后框架立即释放底层句柄。这与 C++ `AsyncResult` 和 Pascal `Result_` 参数完全一致。

**派发失败**：`LF_Async_*` 返回 0 时，`Async` 会**在调用方线程同步**调用回调，`Ok == false`。单一错误路径。

**共用一个 trampoline**（`s_trampoline`），静态字段保强引用。回调异常被捕获后通过 `Framework.ReportCallbackError` 上报。

**最简示例：**

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

## 4. 测试与验证

### 4.1 两个测试套件

| 套件 | 项数 | 覆盖 |
|------|:----:|------|
| `test`（v4.0） | 58 | DataHandle、AppHandle、LfIo、Framework、网络集成、跨语言 ABI、并发、压力 |
| `test2`（v5.0 / v5.1） | 58 | P2PUid、RuntimeOptions、侧数据、CallbackDispatcher、UID 寻址、P2PName 寻址、异步（App / UID / P2PName）、P2P 注册、dispatcher 集成、回调风格异步（10 项） |

**总计 116 项测试。**

### 4.2 `test/Program.cs` — v4.0 回归测试（58 项）

**测试分类：**

| 分类 | 数量 | 覆盖内容 |
|------|:----:|----------|
| `DataHandle` | 19 | 基础类型、Unicode、容错读、位置大小、Dispose 安全、NUL 终止、空串、大缓冲、嵌入 NUL、混合字段、零长度、精确读、Try 家族、全读、永久句柄创建 / 存活 / 同步释放 |
| `AppHandle` | 10 | 注册 / 本地调用、重复注册、重新注册、大小写不敏感、无输出回调、异常隔离、LocalNotify、LocalCallBinary、LocalNotifyBinary、Dispose 安全 |
| `LfIo` | 7 | JSON POCO 往返、null 值、Unicode（无 `\uXXXX`）、数组、数字、TryReadJson、ReadJson 抛异常 |
| `Framework` | 5 | SetOption 不抛、ResetPrepare 不抛、GenerateAppName、PrepareDone 只一次、Shutdown 幂等 |
| 网络集成 | 8 | 单地址 JSON 调用、缺失目标返回空句柄、长字符串往返、Notify、SequencedNotify FIFO、CheckApp / CheckApi、NetworkEvents、状态队列 |
| 跨语言 ABI | 5 | CallBinary int32、多类型往返、逐字节小端序验证、NotifyBinary、SequencedNotifyBinary |
| 并发 | 2 | 10 线程 × 100 本地调用、8 线程 × 500 独立句柄 |
| 压力 | 2 | 1000 顺序本地调用、100 次 App 创建/销毁 |

### 4.3 `test2/Program.cs` — v5.0 / v5.1 新增 API 测试（58 项）

**测试分类：**

| 分类 | 数量 | 覆盖内容 |
|------|:----:|----------|
| `P2PUid` | 6 | `Empty` / `FromBytes` / 长度校验 / `TryParse` / `ToHexString` / `CopyTo` / 相等性 / 字典键 |
| `RuntimeOptions` | 8 | bool / logging / ulong / int / string 往返；密码掩码；`GetRaw`/`SetRaw`；未设置选项默认值 |
| `DataHandle` 侧数据 | 4 | 输入句柄有身份 / 输出句柄空 / 自建句柄空 / 已释放抛异常 |
| `CallbackDispatcher` | 6 | Inline 同线程 / SingleThreadedQueue 异线程 / 阻塞调用者 / Custom 包装 / null 拒绝 / 未捕获时 fallback |
| UID 寻址 | 5 | 自我发现 / `CallByUid` / `NotifyByUid` / `SequencedNotifyByUid` FIFO / `CheckUid` + `CheckUidApi` |
| P2PName 寻址 | 5 | `CallByP2PName` / `NotifyByP2PName` / `SequencedNotifyByP2PName` FIFO / `CheckP2PName` + `CheckP2PNameApi` / 未知组空结果 |
| Async App 名 | 4 | `CallAsync` / `CallSequencedAsync` FIFO / **await 回 SyncContext** / 并发 8 路 |
| Async UID/P2PName | 4 | `CallByUidAsync` / `CallByUidSequencedAsync` / `CallByP2PNameAsync` / `CallByP2PNameSequencedAsync` |
| P2P 注册 | 3 | `RegisterP2PCall` / `RegisterP2PNotify` / `UnregisterP2P`（含重复 / 缺失 / null 边界） |
| Dispatcher 集成 | 1 | 注册带 dispatcher 的 API，验证 handler 跑在 dispatcher 线程而非调用者线程 |
| **Async 回调风格** ★ | **10** | Call JSON / Call DataHandle / 派发失败同步 / CallSequenced FIFO / CallByUid / CallByUidSequenced FIFO / CallByP2PName / CallByP2PNameSequenced FIFO / 回调异常隔离 / 链式调用 |

**运行方式：**

```bash
cd test2
dotnet run
```

**输出：** 每个分类的通过数 / 失败数 / 耗时，以及失败详情。**预期 58 / 58 PASS**。

### 4.4 Cross Demo — 三端联调

| 程序 | 角色 |
|------|------|
| `CrossService` | 协调者 / 信标，监听 `ipc:cross` |
| `CrossNode` | 工作节点，注册 `demo` 应用的 `add` / `inv_seri` |
| `CrossCall` | 负载测试客户端，32 线程 × 10 秒 |

**三终端运行：**

```bash
# 终端 1
dotnet run --project CrossService

# 终端 2（等终端 1 打印 running）
dotnet run --project CrossNode

# 终端 3（等终端 2 打印 Online）
dotnet run --project CrossCall
```

**跨语言验证：** C# 的 `CrossCall` 可以调用 C++ / Pascal / Python 的 `CrossNode`，反之亦然——线协议逐字节一致。

### 4.5 一键构建 / 测试

```powershell
# 清理
.\clean.ps1 -IncludePackages

# 编译 + 跑全部测试（test 与 test2 都是 console harness，会用 dotnet run 执行）
.\build.ps1 -Configuration Release -Target Test

# 只跑 v5.0 / v5.1 测试
.\build.ps1 -Project .\test2\test2.csproj -Configuration Release -Target Test

# 打包（只打包 LingoFuse_cs.csproj）
.\build.ps1 -Configuration Release -Target Pack

# 发布（跳过测试项目）
.\publish.ps1 -SkipTests
```

---

## 5. 快速开始

### 5.1 添加引用

```xml
<ItemGroup>
  <ProjectReference Include="..\src\LingoFuse\LingoFuse.csproj" />
</ItemGroup>
```

### 5.2 最小服务端

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

### 5.3 最小客户端（同步）

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

### 5.4 最小客户端（异步，★ v5.0）

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

    // await continuation 遵循原生 C# await 语义：
    //   - 有 SyncContext → post 回它
    //   - 无 SyncContext → 在完成线程上内联
    using var response = await Framework.CallAsync("Calculator", request);

    var result = LfIo.ReadJson<JsonElement>(response);
    Console.WriteLine($"5 + 7 = {result.GetProperty("result").GetInt32()}");

    NetworkEvents.Clear();
    Framework.ExitMainThread();
    Framework.Shutdown();
}
```

### 5.5 最小客户端（回调风格，★ v5.1）

与 §5.4 的 await 风格相比，本版本把"调用 + 回调"合并为单一表达式，与 C++ 的 `lingofuse::callAsync` 和 Pascal 的 `LF.AsyncCallApp_P` 完全同构。

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

**注意**：本示例没有 `await`，所以宿主方法不需要是 `async`。callback 风格对调用栈的传染为零。

---

## 6. 高级用法

### 6.1 ABI 跨语言通道

不使用 JSON，直接读写二进制标量，与 C++ / Pascal / Python 逐字节一致。

```csharp
// 服务端
app.RegisterCall("add", "Add two ints", (input, output) =>
{
    int a = input.ReadInt32();
    int b = input.ReadInt32();
    output.WriteInt32(a + b);
});

// 客户端
using var request = new DataHandle("add");
request.WriteInt32(15);
request.WriteInt32(27);
using var response = Framework.Call("demo", request, 3000);
int sum = response.ReadInt32();   // 42
```

**线格式：**

```text
请求：[a: int32 小端][b: int32 小端]
响应：[sum: int32 小端]
```

### 6.2 永久句柄

```csharp
using var template = DataHandle.CreatePermanent("my_api");
template.WriteString("template-payload");
// 跨整个进程生命周期反复使用
// 退出前 Dispose（同步释放）
```

### 6.3 UID 寻址（★ v5.0）

```csharp
// 同步调用
using var param = new DataHandle("compute");
using var resp = Framework.CallByUid(targetUid, param, 5000);

// 异步调用
using var resp2 = await Framework.CallByUidAsync(targetUid, param);

// 探活
if (Framework.CheckUid(targetUid))
{
    // 目标在线
}
```

**与 App 名寻址的对比：**

- **App 名**：知道 App 名 → 路由到任意托管该 App 的客户端（本地优先）。
- **UID**：知道具体会话 UID → 路由到该客户端注册的任意 API（**不需要知道 App 名**，本地优先）。

### 6.4 发送方身份（whoami 模式，★ v5.0）

**服务端注册一个 whoami API**：

```csharp
app.RegisterCall("whoami", "Return caller identity", (input, output) =>
{
    var uid = input.GetSenderUid();
    var p2p = input.GetSenderP2PName();
    output.WriteString(uid.ToHexString());
    output.WriteString(p2p);
});
```

**客户端调用自己**：

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
var selfUid = uidHolder.Value;   // 本进程的 UID
```

**⚠️ UID 在重连时会变化**。每次 Connect 事件后需要重新 whoami。

### 6.5 P2PName 寻址（★ v5.0）

**服务端（worker 节点，启动 N 份）**：

```csharp
RuntimeOptions.P2PName = "compute_group";       // 加入组
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

**客户端（任意进程）**：

```csharp
using var param = new DataHandle("compute");
using var resp = Framework.CallByP2PName("compute_group", param, 5000);
// 服务端按 Cycle_Anchor 负载均衡到组内某个 worker
```

**⚠️ P2PName 路由不做本地优先**——即使本进程也有组成员，调用仍走网络。

### 6.6 异步调用（★ v5.0）

**并发扇出**：

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

**链式调用**：

```csharp
using var login = new DataHandle("login");
LfIo.WriteJson(login, new { user = "alice" });
using var loginResp = await Framework.CallAsync("AuthSvc", login);
var token = LfIo.ReadJson<JsonElement>(loginResp)
    .GetProperty("token").GetString()!;

using var fetch = new DataHandle("fetch");
LfIo.WriteJson(fetch, new { token });
using var fetchResp = await Framework.CallAsync("DataSvc", fetch);
// 处理 fetchResp
```

**软超时组合**：

```csharp
var pending = Framework.CallAsync("App", param);
var delay = Task.Delay(TimeSpan.FromSeconds(5));
var completed = await Task.WhenAny(pending, delay);

if (completed == delay)
{
    // 软超时：底层 holder 仍占用，直到框架最终派发完成回调
}
else
{
    using var response = await pending;
    // ...
}
```

### 6.7 回调风格异步（★ v5.1）

**最简形式**：

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

**DataHandle 形式**：

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

**回调内再发起异步调用（链式）**：

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

**派发失败**：`LF_Async_*` 返回 0 时，回调在**调用方线程同步**触发，`Ok == false`。单一错误路径。

**与 await 风格的选择**：

| 场景 | 推荐 |
|------|------|
| UI 应用（WPF / WinForms / MAUI / Avalonia） | `await Framework.CallAsync(...)` |
| 需要 `SynchronizationContext` 自动 marshal | `await Framework.CallAsync(...)` |
| 需要 `Task.WhenAll` / `Task.WhenAny` 组合 | `await Framework.CallAsync(...)` |
| 服务端回调逻辑、嵌入式、脚本化 | `Async.Call(..., r => { ... })` |
| 与 C++ / Pascal 集成保持一致的团队 | `Async.Call(..., r => { ... })` |
| 想避免 `async`/`await` 传染整个调用栈 | `Async.Call(..., r => { ... })` |

两者可自由混用，共享底层 C ABI。

### 6.8 全局 P2P 注册（★ v5.0）

```csharp
// 注册进程级 Call API
Framework.RegisterP2PCall("capabilities",
    "Return capabilities",
    (input, output) =>
    {
        LfIo.WriteJson(output, new { version = "5.1" });
    });

// 注册进程级 Notify API
Framework.RegisterP2PNotify("health_ping",
    "Ping handler",
    input => Console.WriteLine($"[ping] {input.ReadString()}"));

// 对端可用 UID 或 P2PName 寻址调用：
//     Framework.CallByUid(someUid, new DataHandle("capabilities"));
//     Framework.CallByP2PName("some_group", new DataHandle("capabilities"));

// 注销
Framework.UnregisterP2P("capabilities");
```

**P2P API 只能通过 UID / P2PName 寻址到达，不能用 App 名寻址**。

### 6.9 回调线程调度（★ v5.0）

**UI 线程 handler**：

```csharp
// 在 UI 启动时
CallbackDispatcher.CaptureMainThread();

using var app = new AppHandle("UIApp", "UI service");

app.RegisterCall("update_label", "Update label",
    (input, output) =>
    {
        // 运行在 UI 线程
        MyLabel.Text = input.ReadString();
        output.WriteString("ok");
    },
    CallbackDispatcher.MainThread);
```

**单线程队列 handler**：

```csharp
using var dispatcher =
    CallbackDispatcher.CreateSingleThreadedQueue("db-writer");

app.RegisterCall("write_db", "Write to DB",
    (input, output) =>
    {
        // 运行在专用线程，FIFO 顺序
        // ...
    },
    dispatcher);
```

**自定义 dispatcher**：

```csharp
var dispatcher = CallbackDispatcher.CreateCustom(callback =>
{
    // 用户自选调度逻辑
    // 必须同步语义：返回前 callback 已执行完成
    myCustomScheduler.Post(callback);
    myCustomScheduler.WaitUntilDone();
});
```

### 6.10 网络事件

```csharp
NetworkEvents.Set(
    onConnect: addr => Console.WriteLine($"[+] {addr}"),
    onDisconnect: addr => Console.WriteLine($"[-] {addr}"));

// ... 运行 ...

NetworkEvents.Clear();
```

### 6.11 回调错误处理

```csharp
Framework.CallbackErrorHandler = (source, ex) =>
{
    logger.Error($"[LingoFuse] {source}: {ex}");
};
```

### 6.12 JSON 属性命名

```csharp
public sealed class Request
{
    [System.Text.Json.Serialization.JsonPropertyName("user_name")]
    public string UserName { get; set; } = "";

    [System.Text.Json.Serialization.JsonPropertyName("request_id")]
    public int RequestId { get; set; }
}
```

序列化为 `{"user_name":"...","request_id":...}`。

### 6.13 强类型运行时选项（★ v5.0）

```csharp
RuntimeOptions.OverlapConnection = true;
RuntimeOptions.WaitConnectionReadyOk = true;
RuntimeOptions.WaitConnectionTimeoutMs = 10000;
RuntimeOptions.P2PName = "worker_group";
RuntimeOptions.Quiet = false;
RuntimeOptions.ShowThreadId = true;
RuntimeOptions.ConsoleOutput = true;

// 读取（未设置返回类型安全默认值，不抛异常）
bool quiet = RuntimeOptions.Quiet;
string p2p = RuntimeOptions.P2PName;

// 逃生舱：未知 / 未来选项
RuntimeOptions.SetRaw("Some_Future_Option", "value");
string raw = RuntimeOptions.GetRaw("Some_Future_Option");
```

---

## 7. 配置选项

`RuntimeOptions` 强类型属性 vs `Framework.SetOption` 原始字符串接口：

| 选项 | RuntimeOptions 属性 | 别名 | 默认 | 说明 |
|------|---------------------|------|------|------|
| 认证 | `Password` | `passwd` | — | C4 P2PVM 认证（getter 返回掩码） |
| 日志 | `Quiet` | — | False | 安静模式 |
| 日志 | `ShowThreadId` | `ShowThread` | True | 日志显示线程 ID |
| 日志 | `ConsoleOutput` | `Console_Output` | auto | 控制台日志 |
| 日志 | `SetDebugCommand(string)` | `debug_cmd` 等 | — | 执行 C4 调试命令（write-only） |
| 连接 | `OverlapConnection` | `Overlap_Client` 等 | False | 允许多客户端同地址 |
| 连接 | `WaitConnectionReadyOk` | `Wait_Ready` 等 | True | 是否等待客户端就绪 |
| 连接 | `WaitConnectionTimeoutMs` | `Wait_TimeOut` 等 | 30000 | 等待超时毫秒 |
| IPC | `IpcServerThreadCount` | `IPC_ThreadCount` 等 | 平台相关 | IPC 服务端线程数 |
| IPC | `IpcServerMaxQueueLength` | `IPC_MaxQueueLength` 等 | 平台相关 | IPC 队列长度 |
| IPC | `IpcServerMaxMsgSize` | `IPC_MaxMsgSize` 等 | 平台相关 | IPC 消息最大尺寸 |
| 顺序 | `FixedSequencedTimeMs` | `Fixed_Sequenced_Life` | 20000 | 顺序通知回退阈值 |
| P2P | `P2PName` | `P2P_name` 等 | 空 | 本进程 P2P 组名 |
| 句柄池 | `DataHandleIdleTimeoutMs` | `Data_Idle_Timeout` 等 | 600000 | 空闲回收阈值 |
| 句柄池 | `DataHandlePoolScanIntervalMs` | `Data_Scan_Interval` 等 | 5000 | 池扫描间隔 |
| 刷新 | `NoReponseCmdNullFlushThreshold` | — | 5000 | Notify NULL 刷新阈值 |

**布尔值格式：** `"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` / `"No"`（大小写不敏感）。

**作用域**：进程级；`Framework.Shutdown` 后丢失。

**使用建议**：新代码优先用 `RuntimeOptions` 属性——编译期校验、类型安全、读取无异常。原始 `Framework.SetOption` 保留用于未来扩展选项。

---

## 8. 清理顺序

严格按此顺序：

```text
1. NetworkEvents.Clear()
2. Framework.ExitMainThread()
3. app.Dispose()
4. Framework.Shutdown()
```

| 步骤 | 原因 |
|------|------|
| 1 | 防止回调在关闭过渡期触发 |
| 2 | 停止主线程，无回调可触发 |
| 3 | 解绑 App，停止顺序通知线程 |
| 4 | 释放全部 native 资源，包括 App 池和 P2P bridge 注册表 |

用 `finally` 保证所有退出路径都执行：

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

## 9. 常见坑与 FAQ

### 9.1 回调中禁止阻塞

**症状：** 整个进程死锁。

**原因：** 回调在 native worker 线程执行，`Framework.Call` 需要主线程派发响应。

**修复：** 回调中不得调用 `Framework.Call` / `Notify` / `SequencedNotify` / `LocalCall` / `LocalNotify` / `PrepareDone` / `Shutdown`。耗时操作丢到 `Task.Run`。

### 9.2 `Call` 超时返回 size=0，不是 null

**修复：** 检查 `response.Size == 0`，不要检查 `null`。

### 9.3 `PrepareDone` 每进程只返回 1 一次

**修复：** 重启框架必须 `Shutdown` → `ResetPrepare` → `PrepareDone`。

### 9.4 API 注册必须在 `PrepareClient` 之前

**症状：** 首次调用超时。

**原因：** `Init_App_Info` 广播在 `PrepareClient` 时发送。之后注册的 API 不在广播中。

**修复：**

```csharp
using var app = new AppHandle("MyApp", "");
app.RegisterCall("api1", "...", ...);   // ← 先注册
app.RegisterCall("api2", "...", ...);
Framework.PrepareClient(endpoint, app); // ← 后绑定
```

### 9.5 同地址多客户端被静默忽略

**修复：** 设置 `RuntimeOptions.OverlapConnection = true`（在 `PrepareClient` 之前）。

### 9.6 `CheckApp` / `CheckApi` / `CheckUid` / `CheckP2PName` 有 3 秒缓存延迟

**修复：** 重试循环，最多 6 秒。

### 9.7 `AppHandle.Dispose` 不立即释放内存

**原因：** 两阶段析构，对象在 `Framework.Shutdown` 才销毁。

**修复：** 长生命周期服务定期 `Shutdown` 后重启，或在进程退出时统一 `Shutdown`。

### 9.8 `NetworkEvents.Set` 是 REPLACE 语义

**修复：** 两个回调一次性传入，或先 `Clear` 再 `Set`。

### 9.9 `LfIo.WriteJson` 与 `DataHandle.WriteBytes` 的区别

| 方法 | NUL 终止 | 用途 |
|------|:--------:|------|
| `LfIo.WriteString` | ✅ | UTF-8 文本 |
| `LfIo.WriteJson` | ✅ | JSON 文本 |
| `LfIo.WriteStringBytes` | ✅ | 预编码字节 |
| `DataHandle.WriteBytes` | ❌ | 原始字节，无终止符 |

### 9.10 `TryReadJson` 返回 `true` 但值为 `null`

**原因：** JSON 负载是字面 `null`，且 `T` 是引用类型。

**修复：** 同时检查 `v is not null`。

### 9.11 `DataHandle.FromRaw` 在回调外使用会泄漏

**修复：** 回调外一律用 `new DataHandle("api")`。

### 9.12 `DataHandle.Raw` 在 resize 后失效

**修复：** 不要缓存 `Raw`。需要长期持有时拷贝字节。

### 9.13 侧数据访问器在错误句柄上返回空

**症状：** `GetSenderUid()` 返回 `P2PUid.Empty`，`GetSenderP2PName()` 返回 `""`。

**原因：** 在 output 句柄或自建句柄上调用。

**修复：** **只在回调的 `input` 参数上调用**。

### 9.14 UID 跨 link-loss 失效

**症状：** `CallByUid` 返回 size-0 句柄。

**原因：** UID 在每次重连时重新生成。

**修复：** 每次 Connect 事件后重新 whoami 发现 UID。

### 9.15 P2PName 路由不走本地

**症状：** 本进程也有组成员，但 `CallByP2PName` 仍走网络。

**原因：** P2PName 路由设计为不做本地查找。

**修复：** 需要本地优先用 `Call`（App 名）或 `CallByUid`。

### 9.16 dispatcher 不遵守同步契约 → use-after-free

**症状：** 偶发崩溃，UI 线程访问已释放句柄。

**原因：** 自定义 dispatcher 是 post-and-forget。

**修复：** `Dispatch` 必须在 callback 执行完成后才返回。

### 9.17 UI handler + 同步 Call 死锁

**症状：** 进程死锁。

**原因：** UI 线程阻塞在 `Framework.Call`，同时 worker 尝试 dispatch 回 UI 线程。

**修复：** 用 `CallAsync` + `await` 而不是 `Call`。或在 UI handler 内不发起同步调用。

### 9.18 `await` 不回 SyncContext

**症状：** `Task.Run` 里设置 SyncContext 后 await，continuation 不在 ctx 线程。

**原因：**
- 本地 App 名调用**同步完成** → Task 已完成 → await 不挂起 → 无 Post。
- 无 SyncContext 的线程池线程 → continuation 内联在完成线程上。

**修复：**
- 在真实 UI 线程上 await（不要 `Task.Run` 包裹）。
- 或把整个 async lambda post 到 ctx。

### 9.19 AsyncResult 逃逸出回调体

**症状：** 回调返回后访问 `AsyncResult.Handle` / `Read*`，偶发读到垃圾数据或崩溃。

**原因：** `AsyncResult` 内部持有**借用** `DataHandle`（`owned: false`）。回调返回瞬间框架释放底层句柄。

**修复：** 在回调体内**立即拷贝**你需要的数据（`ReadJson<T>` / `ReadString` / `ReadAllBytes`），把**拷贝的托管对象**交给世界。绝不把 `AsyncResult` 或 `r.Handle` 存字段 / 入队 / 传别的线程。

### 9.20 回调风格异步被误当同步函数用

**症状：** 以为 `Async.Call(...)` 返回后结果就绪。

**原因：** `Async.Call` 返回 `void`。派发成功时回调在**稍后的 worker 线程**触发，此时 `Async.Call` 早已返回。

**修复：** 用 `ManualResetEventSlim` / `CountdownEvent` / `TaskCompletionSource` 在调用方与回调方之间同步。或者改用 await 风格 `Framework.CallAsync`。

### 9.21 完整 FAQ

**Q：C# 支持算完善吗？**
A：算。P/Invoke 层（59 个导出）、RAII 封装、统一 JSON I/O、UID / P2PName 寻址、Task 化异步、回调风格异步、可插拔回调线程调度、网络事件、异常层次、116 项测试、跨语言 ABI 互操作，全覆盖。

**Q：先跑哪个？**
A：先跑 `test` 和 `test2` 项目，确认动态库和环境正常。

**Q：如何验证跨语言？**
A：启动 C++ 或 Pascal 的 CrossNode，用 C# 的 CrossCall 调用；或反过来。线协议逐字节一致。

**Q：如何压测？**
A：跑 CrossCall，32 线程 × 10 秒，输出吞吐量。

**Q：动态库找不到？**
A：把 `LingoFuse64.dll` / `liblingofuse.so` 放到可执行文件同目录或系统 PATH。

**Q：`PrepareDone` 第二次返回 0？**
A：每进程只成功一次。要重启，先 `Shutdown` + `ResetPrepare`。

**Q：`LingoFuseLibraryLoadException` 会抛吗？**
A：当前实现不抛此异常；加载失败时 `NativeLibrary.Load` 抛 `DllNotFoundException`。建议同时 catch 两种。

**Q：`AppHandle` 支持跨线程注册 API 吗？**
A：支持。内部有锁串行化。

**Q：Pascal / Python / C++ 的 peer 能调用 C# 服务吗？**
A：能。所有语言使用同一线协议，只要 App 名和 API 名一致即可。

**Q：JSON key 大小写？**
A：C# 属性名 verbatim。要改成 snake_case，用 `[JsonPropertyName]` 注解。

**Q：Emoji 会被转义吗？**
A：不会。`LfIo` 内部 `UnescapeSurrogatePairs` 保证 emoji 以字面 UTF-8 输出。

**Q：怎么拿到发送方的身份？**
A：在回调里用 `input.GetSenderUid()` 和 `input.GetSenderP2PName()`。**只在 `input` 上有效**。

**Q：怎么把 handler 放到 UI 线程？**
A：`CallbackDispatcher.CaptureMainThread()`（UI 启动时调一次），然后注册时传 `CallbackDispatcher.MainThread`。

**Q：异步调用为什么有时是同步完成？**
A：目标 App 是本地时（本进程），C ABI 会在 `CallAsync` 返回前**同步**触发完成回调，Task 已完成。此时 `await` 不挂起，continuation 内联在当前线程。详见 `LingoFuse_CSharp_Complete_Guide.md` §12.4。

**Q：怎么给异步调用加超时？**
A：`Task.WhenAny(pending, Task.Delay(...))`。C ABI 层无 timeout / cancellation。

**Q：UID 会变吗？**
A：每次重连都会重新生成。跨 link-loss 缓存 UID 会导致 `CallByUid` 失败。

**Q：P2PName 路由是本地优先吗？**
A：不是。P2PName 路由总是走服务端，服务端做负载均衡。

**Q：回调风格异步和 await 风格异步该选哪个？**
A：UI 应用 / 需要 `SynchronizationContext` / 需要 `Task.WhenAll` → await 风格。服务端回调逻辑 / 嵌入式 / 与 C++/Pascal 保持一致 / 不想让 `async` 传染调用栈 → 回调风格。两者可混用。

---

## 10. 跨语言互操作

### 10.1 线协议契约

| 元素 | 编码 |
|------|------|
| 字符串帧 | UTF-8 字节 + NUL (`0x00`) |
| 整数 | 小端序 |
| 浮点 | IEEE 754，小端序 |
| JSON 文本 | 紧凑，字面 UTF-8，无 `\uXXXX` 转义 |
| UID | 32 字节，小端 4 × 64-bit |
| 原始字节 | 任意字节 + NUL（若用 `WriteStringBytes`） |

### 10.2 互操作矩阵

| 服务端 | 客户端 | 传输 | 寻址 / 信封 | 支持 |
|--------|--------|------|-------------|:----:|
| C# | C# | IPC / TCP | JSON / ABI / UID / P2PName | ✅ |
| C# | Pascal | IPC | JSON / ABI / UID / P2PName | ✅ |
| C# | Python | IPC | JSON / ABI / UID / P2PName | ✅ |
| C# | C++ | IPC | JSON / ABI / UID / P2PName | ✅ |
| C# | Rust / Go / Node / Java | IPC | JSON / ABI / UID / P2PName | ✅ |
| C# | HTTP | HTTP→bridge→LF | JSON | ✅ |

**所有组合使用同一线协议。** 唯一区别是应用层选择 JSON 信封还是原始标量、选择 App 名 / UID / P2PName 哪种寻址。

### 10.3 侧数据矩阵

| 命令 | 是否注入发送方身份 |
|------|:------------------:|
| `Framework.Notify` / `SequencedNotify` | ✅ |
| `Framework.Call` / `CallAsync` | ✅ |
| `Framework.CallByUid` / `CallByUidAsync` | ✅ |
| `Framework.CallByP2PName` / `CallByP2PNameAsync` | ✅ |
| `AppHandle.LocalCall` / `LocalNotify` | ✅ |
| 异步回调的 `Result_` handle | ❌（output 句柄） |
| 调用者自建句柄 | ❌（无发送方） |

### 10.4 跨语言示例

**C# 服务端：**

```csharp
app.RegisterCall("add", "Add two ints", (input, output) =>
{
    int a = input.ReadInt32();
    int b = input.ReadInt32();
    output.WriteInt32(a + b);
});
```

**C++ 客户端：**

```cpp
DataHandle param("add");
param.write<int32_t>(a);
param.write<int32_t>(b);
auto response = lingofuse::call("demo", param, 1000);
int32_t sum = response.read<int32_t>();
```

**Pascal 客户端：**

```pascal
send_ := LF_CreateDataEx('add');
LF_WriteInt32(send_, a);
LF_WriteInt32(send_, b);
return_ := LF_CallEx('demo', send_, 1000);
Result := LF_ReadInt32(return_);
```

**Python 客户端：**

```python
c = C4("demo", "ipc:cross")
result = c.add(a, b)
```

**线字节完全一致。**

---

## 11. 与其它语言绑定的对比

| 功能 | C# | Pascal | Python | C++ |
|------|:--:|:------:|:------:|:---:|
| 底层绑定 | `NativeMethods.cs` | `lingofuse_import.pas` | `_lf_native.py` | `LingoFuse.h` |
| RAII 封装 | `DataHandle` / `AppHandle` | `TDataHandle` / `TAppHandle` | `DataHandle` / `App` | `DataHandle` / `AppHandle` |
| UID 值类型 | `P2PUid` | `TP2P_UID___` | `bytes` | `TP2P_UID` |
| 统一 JSON I/O | `LfIo` | `lf_io`（通过 Bridge） | `lf_io` | `lf_io.hpp` |
| 强类型选项 | `RuntimeOptions` | — | — | — |
| 回调线程调度 | `CallbackDispatcher` | `LF_RegisterSyncCall_M` | — | — |
| 异步调用 | `Task<DataHandle>` | 匿名方法 + `LF_Async_Call` | `call_future` + `asyncio` | `callAsync` + `AsyncResult` |
| 回调风格异步 ★ | `Async.Call(..., r => {...})` | `LF.AsyncCallApp_P` | — | `lingofuse::callAsync` |
| HTTP Bridge 客户端 | — | ✅ | ✅ | ✅ |
| 网络事件 | `NetworkEvents` | `LF_Set_Network_Event` | `network_events` | `NetworkEvents` |
| 状态检查 | `LingoFuseStatus` | 直接调用 | `lingofuse.check_*` | `LingoFuseStatus` |
| 永久句柄 | `CreatePermanent` | `LF_CreateData_Permanent` | `create_permanent` | ✅ |
| 测试数量 | **116**（58 + 58） | 综合单测 | 综合单测 | 功能 + 压力 + 并发 |
| CI | ❌ | ❌ | ❌ | ✅ 唯一 |

---

## 12. 许可证

MIT。随便用，随便改，拿去卖钱也行。

---

## 延伸阅读

| 文档 | 内容 |
|------|------|
| `LingoFuse_CSharp_Complete_Guide.md` | C# 接口完整参考（v5.1，17 章 + 4 附录） |
| `../LingoFuse_Pascal_Complete_Guide.md` | Pascal 接口与内部机制 |
| `../Z.LingoFuse.md` | LingoFuse 内部机制知识库 |
| `../cpp/LingoFuse_Cpp_Knowledge_Base.md` | C++ 接口参考（v8.0） |

---

*本文档随 LingoFuse C# 绑定 v5.1 整理，覆盖 116 项测试全部分类。*
*完整 API 参考见 `LingoFuse_CSharp_Complete_Guide.md`。*
*最后更新：2026-10-13*
