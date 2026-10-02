# LingoFuse C# 绑定

> **跨语言通讯地基的 C# 官方绑定、完整测试、三方向 HTTP Bridge、跨语言 ABI 互操作。**
>
> 本目录是 .NET 开发者使用 LingoFuse 的唯一起点。读完本 README 即可知道：
> - C# 绑定到底覆盖了什么；
> - 每个模块是干什么的；
> - 测试覆盖了哪些场景；
> - 常见坑在哪里。

---

## 1. 结论先说：C# 支持完善程度

LingoFuse 的 C# 绑定已经形成完整闭环，**不是“能跑示例”的水平，而是生产可用级绑定**。

| 维度 | 状态 | 说明 |
|------|:----:|------|
| P/Invoke 底层绑定 | ✅ 完整 | `NativeMethods.cs` 导入全部 37 个核心导出函数，含完整 XML 注释 |
| RAII 封装 | ✅ 完整 | `DataHandle` / `AppHandle`，支持 `using` 和 `IDisposable` |
| 统一 JSON I/O | ✅ 完整 | `LfIo` 是唯一序列化入口，保证跨语言字节一致 |
| 进程级门面 | ✅ 完整 | `Framework` 提供网络准备、远程调用、选项、关闭 |
| 网络事件 | ✅ 完整 | `NetworkEvents` 全局 connect / disconnect 回调 |
| 状态与健康检查 | ✅ 完整 | `LingoFuseStatus` 状态队列 + 探活 |
| 异常层次 | ✅ 完整 | 5 个异常类型，覆盖加载 / 调用 / I/O / 已释放 |
| 永久句柄 | ✅ 完整 | `DataHandle.CreatePermanent` |
| 多线程并发 | ✅ 已测试 | 10 线程 × 100 本地调用；8 线程 × 500 独立句柄 |
| 跨语言 ABI | ✅ 已测试 | 逐字节小端序验证，与 C++ / Pascal / Python 字节一致 |
| 跨语言 JSON | ✅ 已测试 | Emoji / 中文无 `\uXXXX` 转义 |
| 性能压测 | ✅ 有 | `CrossCall` 32 线程负载测试 |
| 测试覆盖 | ✅ 完整 | 58 项测试，8 个分类 |
| 跨平台 | ✅ 完整 | Windows / Linux / macOS，自动解析动态库 |
| 文档 | ✅ 完整 | `LingoFuse_CSharp_Complete_Guide.md` 含 13 章 + 4 附录 |
| CI | ⚠️ 仅 C++ 有 GitHub CI | C# 测试以本地运行为准 |

**总体判断：C# 绑定覆盖了从底层 P/Invoke 到高级 RAII 封装、统一 JSON I/O、跨语言 ABI 互操作、网络事件、状态检查的完整链路，并附带 58 项可运行测试。**

---

## 2. 目录结构

```text
csharp/
├── src/
│   ├── LingoFuse/                    # 主绑定库（推荐使用）
│   │   ├── LingoFuse.csproj          # 主库工程
│   │   ├── DataHandle.cs             # RAII 数据句柄
│   │   ├── AppHandle.cs              # RAII 应用句柄
│   │   ├── Framework.cs              # 进程级门面
│   │   ├── LfIo.cs                   # 统一 JSON / 字符串 I/O
│   │   ├── NetworkEvents.cs          # 全局网络事件
│   │   ├── LingoFuseStatus.cs        # 状态队列 + 健康检查
│   │   ├── LingoFuseException.cs     # 异常层次
│   │   └── Native/
│   │       ├── NativeMethods.cs      # P/Invoke 声明（唯一 native 调用点）
│   │       ├── NativeTypes.cs        # 不透明句柄 + 回调原型
│   │       └── Utf8Marshal.cs        # UTF-8 NUL 终止字符串编组
│   └── LingoFuse_cs/                 # 兼容旧版命名空间（LingoFuse_cs）
│       └── ...                       # 与 LingoFuse 相同结构
│
├── test/                             # 58 项测试套件
│   ├── Program.cs                    # 测试主程序
│   └── test.csproj
│
├── CrossCall/                        # 负载测试客户端
│   ├── CrossCall.cs                  # 32 线程 × 10 秒
│   └── CrossCall.csproj
│
├── CrossNode/                        # 工作节点
│   ├── CrossNode.cs                  # 注册 add / inv_seri API
│   └── CrossNode.csproj
│
├── crossService/                     # 协调者 / 信标
│   ├── CrossService.cs
│   └── crossService.csproj
│
├── build.ps1                         # 一键编译
├── clean.ps1                         # 一键清理
├── publish.ps1                       # 一键发布
├── lf_csharp.sln                     # Visual Studio 解决方案
├── LingoFuse_CSharp_Complete_Guide.md # 完整指南（13 章 + 4 附录）
└── readme.md                         # 本文件
```

---

## 3. 核心模块详解

### 3.1 `NativeMethods.cs` — P/Invoke 声明

**职责：**

- 声明全部 37 个 C ABI 导出。
- 使用 `NativeLibrary.SetDllImportResolver` 自动选择平台库：
  - Windows 64 → `LingoFuse64.dll`
  - Windows 32 → `LingoFuse32.dll`
  - Linux / BSD → `liblingofuse.so`
  - macOS → `liblingofuse.dylib`
- 所有函数使用 `CallingConvention.Cdecl`。
- 字符串参数声明为 `IntPtr`，由 `Utf8Marshal` 处理编组。

**注意：** 这是 internal 层，用户代码永远不直接调用。

### 3.2 `NativeTypes.cs` — 不透明句柄 + 回调原型

| 类型 | 说明 |
|------|------|
| `DataHnd` | 数据句柄（`IntPtr` 包装，含 `IsValid` / `Null`） |
| `AppHnd` | 应用句柄（同上） |
| `LfCallFunc` | Call 回调原型 `(trigger, input, output) → void`，`cdecl` |
| `LfNotifyFunc` | Notify 回调原型 `(trigger, input) → void`，`cdecl` |
| `LfNetworkEventFunc` | 网络事件回调原型 `(addr) → void`，`cdecl` |

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

### 3.4 `DataHandle.cs` — 数据句柄

**RAII 封装，支持 `using`。**

两种类型：

| 类型 | 创建方式 | 自动回收 | 释放时机 |
|------|----------|:--------:|----------|
| 自动回收 | `new DataHandle(api)` | 10 分钟空闲 | `Dispose` 标记，下次扫描释放 |
| 永久 | `DataHandle.CreatePermanent(api)` | 永不 | `Dispose` 同步释放 |

**I/O 家族：**

| 家族 | 方法 | 行为 |
|------|------|------|
| 部分读取 | `ReadBytes(n)` | 返回至多 n 字节，不抛异常 |
| 精确读取 | `ReadBytesExact(n)` | 少于 n 抛 `LingoFuseIoException` |
| Try 家族 | `TryReadBytes` / `TryReadInt32` 等 | 返回 bool，不抛异常 |
| 全读 | `ReadAllBytes()` | 读完剩余字节 |

**原子类型（小端序）：**

- `WriteInt8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Single/Double`
- `ReadInt8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Single/Double`
- 每个精确读取都有 `TryRead*` 对应版本

**字符串契约：**

- `WriteString(s)`：UTF-8 + NUL。空字符串写 1 字节（NUL）。
- `ReadString()`：读到第一个 NUL，或无 NUL 读到末尾。无效 UTF-8 逐字节替换为 U+FFFD。

**所有权：**

- Owning：`new DataHandle(...)` 或 `CreatePermanent`。`Dispose` 调用 `LF_FreeData`。
- Borrowing：`DataHandle.FromRaw(raw, owned: false)`。**`Dispose` 是 no-op**——用于回调中的输入/输出句柄。

### 3.5 `LfIo.cs` — 统一 JSON / 字符串 I/O

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

### 3.6 `AppHandle.cs` — 应用句柄

**RAII 封装，`IDisposable`。**

| 方法 | 用途 |
|------|------|
| `RegisterCall(api, desc, Action<DataHandle, DataHandle>)` | 注册 Call API |
| `RegisterNotify(api, desc, Action<DataHandle>)` | 注册 Notify API |
| `Unregister(api)` | 注销 API |
| `LocalCall(param)` | 本地 Call |
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

### 3.7 `Framework.cs` — 进程级门面

**职责：**

| 分类 | 方法 |
|------|------|
| 网络准备 | `ResetPrepare` / `PrepareService` / `PrepareClient` / `PrepareDone` / `ExitMainThread` |
| 远程调用 | `Call` / `TryCall` / `Notify` / `SequencedNotify` |
| 运行时选项 | `SetOption` |
| 应用名 | `GenerateAppName` / `GetAppName` |
| 关闭 | `Shutdown` |
| 回调错误 | `CallbackErrorHandler` 属性 |

**关键契约：**

- `PrepareDone` **每进程只返回 1 一次**，第二次返回 0（非失败）。
- `Call` 超时返回 **size = 0 的句柄**，不是 null。
- `TryCall` 返回 `null`（已 Dispose 空句柄），或返回非空 `DataHandle`。
- `Shutdown` 幂等。

### 3.8 `NetworkEvents.cs` — 全局网络事件

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

### 3.9 `LingoFuseStatus.cs` — 状态与健康检查

| 方法 | 用途 |
|------|------|
| `GetStatusCount()` | 待处理消息数（上限 1000） |
| `GetStatus()` | 取出一条消息（静态缓冲，立即拷贝） |
| `DrainStatus(max)` | 批量取出 |
| `PostStatus(msg)` | 注入消息 |
| `CheckMainThread()` | 主线程是否运行 |
| `CheckApp(name)` | 探活 App（**缓存约 3 秒延迟**） |
| `CheckApi(app, api)` | 探活 API（同上） |

### 3.10 `LingoFuseException.cs` — 异常层次

```text
LingoFuseException
├── LingoFuseLibraryLoadException    (加载失败)
├── LingoFuseCallException           (远程调用失败)
├── LingoFuseIoException             (短读 / 短写)
└── LingoFuseObjectDisposedException (已释放后使用)
```

| 类型 | 关键属性 |
|------|----------|
| `LingoFuseCallException` | `TargetApp`, `TargetApi` |
| `LingoFuseIoException` | `Operation`（如 `"ReadBytesExact"`） |
| `LingoFuseObjectDisposedException` | `ObjectName` |
| `LingoFuseLibraryLoadException` | `LibraryName`（保留给未来使用） |

---

## 4. 测试与验证

### 4.1 `test/Program.cs` — 58 项测试套件

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

**运行方式：**

```bash
cd test
dotnet run
```

**输出：** 每个分类的通过数 / 失败数 / 耗时，以及失败详情。

### 4.2 Cross Demo — 三端联调

| 程序 | 角色 |
|------|------|
| `crossService` | 协调者 / 信标，监听 `ipc:cross` |
| `CrossNode` | 工作节点，注册 `demo` 应用的 `add` / `inv_seri` |
| `CrossCall` | 负载测试客户端，32 线程 × 10 秒 |

**三终端运行：**

```bash
# 终端 1
dotnet run --project crossService

# 终端 2（等终端 1 打印 running）
dotnet run --project CrossNode

# 终端 3（等终端 2 打印 Online）
dotnet run --project CrossCall
```

**CrossCall 输出：** 总调用数 / 成功数 / 失败数 / 吞吐量。

**跨语言验证：** C# 的 `CrossCall` 可以调用 C++ / Pascal / Python 的 `CrossNode`，反之亦然——线协议逐字节一致。

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

Framework.SetOption("Overlap_Connection", "True");
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

### 5.3 最小客户端

```csharp
using System;
using System.Text.Json;
using LingoFuse;

Framework.SetOption("Wait_Connection_ReadyOk", "True");
Framework.SetOption("Overlap_Connection", "True");
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

### 6.3 网络事件

```csharp
NetworkEvents.Set(
    onConnect: addr => Console.WriteLine($"[+] {addr}"),
    onDisconnect: addr => Console.WriteLine($"[-] {addr}"));

// ... 运行 ...

NetworkEvents.Clear();
```

### 6.4 回调错误处理

```csharp
Framework.CallbackErrorHandler = (source, ex) =>
{
    logger.Error($"[LingoFuse] {source}: {ex}");
};
```

### 6.5 JSON 属性命名

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

---

## 7. 配置选项

`Framework.SetOption(option, value)` 支持：

| 选项 | 别名 | 默认 | 说明 |
|------|------|------|------|
| `password` | `passwd` | — | C4 P2PVM 认证 |
| `Quiet` | — | False | 安静模式 |
| `ShowThreadID` | `ShowThread` | False | 日志显示线程 ID |
| `ConsoleOutput` | `Console_Output` | auto | 控制台日志 |
| `Overlap_Connection` | `Overlap_Client` 等 | False | 允许多客户端同地址 |
| `Wait_Connection_ReadyOk` | `Wait_Ready` 等 | True | 是否等待客户端就绪 |
| `Wait_Connection_Timeout` | `Wait_TimeOut` 等 | 30000 | 等待超时毫秒 |
| `Fixed_Sequenced_Time` | `Fixed_Sequenced_Life` | 20000 | 顺序通知回退阈值 |

**布尔值格式：** `"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` / `"No"`（大小写不敏感）。

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
| 4 | 释放全部 native 资源，包括 App 池 |

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

**修复：** 设置 `Framework.SetOption("Overlap_Connection", "True")`。

### 9.6 `CheckApp` / `CheckApi` 有 3 秒缓存延迟

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

### 9.13 完整 FAQ

**Q：C# 支持算完善吗？**
A：算。P/Invoke 层、RAII 封装、统一 JSON I/O、网络事件、异常层次、58 项测试、跨语言 ABI 互操作，全覆盖。

**Q：先跑哪个？**
A：先跑 `test` 项目，确认动态库和环境正常。

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
A：不会。`LfIo` 内部 `UnescapeSurrogatePairs` 保证 emoji 以字面 UTF-8 输出，与 Pascal / Python / C++ 一致。

---

## 10. 跨语言互操作

### 10.1 线协议契约

| 元素 | 编码 |
|------|------|
| 字符串帧 | UTF-8 字节 + NUL (`0x00`) |
| 整数 | 小端序 |
| 浮点 | IEEE 754，小端序 |
| JSON 文本 | 紧凑，字面 UTF-8，无 `\uXXXX` 转义 |
| 原始字节 | 任意字节 + NUL（若用 `WriteStringBytes`） |

### 10.2 互操作矩阵

| 服务端 | 客户端 | 传输 | 信封 | 支持 |
|--------|--------|------|------|:----:|
| C# | C# | IPC / TCP | JSON / ABI | ✅ |
| C# | Pascal | IPC | JSON / ABI | ✅ |
| C# | Python | IPC | JSON / ABI | ✅ |
| C# | C++ | IPC | JSON / ABI | ✅ |
| C# | Rust / Go / Node / Java | IPC | JSON / ABI | ✅ |
| C# | HTTP | HTTP→bridge→LF | JSON | ✅ |

**所有组合使用同一线协议。** 唯一区别是应用层选择 JSON 信封还是原始标量。

### 10.3 跨语言示例

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
| 统一 JSON I/O | `LfIo` | `lf_io`（通过 Bridge） | `lf_io` | `lf_io.hpp` |
| HTTP Bridge 客户端 | ✅ | ✅ | ✅ | ✅ |
| 网络事件 | `NetworkEvents` | `LF_Set_Network_Event` | `network_events` | `NetworkEvents` |
| 状态检查 | `LingoFuseStatus` | 直接调用 | `lingofuse.check_*` | `LingoFuseStatus` |
| 永久句柄 | `CreatePermanent` | `LF_CreateData_Permanent` | `create_permanent` | ✅ |
| 测试数量 | 58 | 综合单测 | 综合单测 | 功能 + 压力 + 并发 |
| CI | ❌ | ❌ | ❌ | ✅ 唯一 |

---

## 12. 许可证

MIT。随便用，随便改，拿去卖钱也行。

---

*本文档随 LingoFuse C# 绑定 v3.2（永久句柄支持）整理，覆盖 58 项测试全部分类。*
*完整 API 参考见 `LingoFuse_CSharp_Complete_Guide.md`。*
*最后更新：2026-10-02*