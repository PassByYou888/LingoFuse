# LingoFuse Pascal 完整指南

> **面向 AI 与人类开发者的全面参考手册**  
> 涵盖所有 API、陷阱、示例范式和最佳实践

---

## 📖 目录

1. [引言](#1-引言)
2. [核心概念速览](#2-核心概念速览)
3. [快速入门（5 分钟）](#3-快速入门5-分钟)
4. [API 完全参考](#4-api-完全参考)
   - 4.1 数据句柄操作
   - 4.2 应用句柄操作
   - 4.3 API 注册（Call / Notify）
   - 4.4 本地调用
   - 4.5 网络准备与启动
   - 4.6 远程调用与通知
   - 4.7 运行时选项与状态
   - 4.8 同步辅助
   - 4.9 查询与健康检查
   - 4.10 关闭与清理
5. [完整示例深度解析](#5-完整示例深度解析)
   - 5.1 cross_demo – 跨语言负载均衡
   - 5.2 compute_grid – 分布式计算网格
   - 5.3 sequence – 大数据顺序组装（Sequenced Notify）
   - 5.4 bridge – HTTP + JSON 标准化桥接
   - 5.5 压测套件 – BenchServer / BenchClient
   - 5.6 fpc_tester – 综合单元测试
6. [高级范式与最佳实践](#6-高级范式与最佳实践)
   - 6.1 动态生成应用名 (LF_Generate_AppName)
   - 6.2 动态绑定应用 (LF_BindApp) 与 Overlap_Connection
   - 6.3 部署模式 (Wait_Connection_ReadyOk)
   - 6.4 序列化通知线程池
   - 6.5 数据句柄自动回收机制
   - 6.6 应用生命周期与 LF_FreeApp / LF_Shutdown
   - 6.7 回调线程安全与死锁预防
7. 🚨 已知陷阱与避坑指南
   - 7.1 生成 AppName 的时机
   - 7.2 BindApp 失败的处理
   - 7.3 CheckApp / CheckApi 缓存延迟
   - 7.4 回调中禁止调用远程 API
   - 7.5 数据句柄必须显式释放
   - 7.6 JSON 空终止符 (#0) 问题
   - 7.7 客户端地址唯一性限制
   - 7.8 等待就绪超时
   - 7.9 同步回调必须调用 LF_Sync
   - 7.10 资源清理顺序
   - 7.11 Overlap_Connection 与多应用共存
   - 7.12 LF_FreeApp 不立即销毁对象
8. [与 Python 绑定的范式对比](#8-与-python-绑定的范式对比)
9. [附录 A – 函数速查表](#9-附录-a--函数速查表)
10. [附录 B – 环境变量与编译选项](#10-附录-b--环境变量与编译选项)
11. [附录 C – 常用宏与常量](#11-附录-c--常用宏与常量)

---

## 1. 引言

**LingoFuse** 是一个面向智能体（Agent）和全栈系统的分布式 RPC 框架，基于 C4 服务网格，提供跨语言、跨进程、跨机器的函数调用能力。本指南聚焦于 **Pascal 语言绑定**，该绑定通过 `lingofuse_import.pas` 单元导出所有 C ABI 函数，并提供 `lingofuse_helper.pas` 作为 RAII 高级封装。

本指南旨在成为 **AI 和人类开发者** 的共同参考，详细解释每个 API、其参数、返回值、内部机制、常见陷阱和最佳实践。所有内容均基于 **LingoFuse v3.0** 及 Pascal 绑定单元 `Z.LingoFuse_Export.pas` 实现。

---

## 2. 核心概念速览

- **数据句柄 (TDataHnd)**：不透明指针，指向一个二进制缓冲区，包含 API 名称和载荷。读写操作基于当前位置，支持原子类型读写和字符串（UTF-8 + 空终止符）。
- **应用句柄 (TAppHnd)**：逻辑应用容器，可注册多个 API。应用名在网络中唯一（匹配时不区分大小写）。
- **API 模式**：
  - **Call**：请求-响应，同步等待结果。
  - **Notify**：单向通知，不等待响应。
- **序列化通知 (Sequenced Notify)**：保证同一 (App, API) 对的 FIFO 有序交付，通过专用线程池实现。
- **本地执行**：`LF_LocalCall` / `LF_LocalNotify` 在同一进程内执行，不经过网络。
- **远程执行**：`LF_Call` / `LF_Notify` / `LF_Sequenced_Notify` 通过网络路由，优先查找本地实例。
- **模拟主线程**：C4 事件循环运行在模拟主线程中，由 `LF_PrepareDone` 启动，`LF_ExitMainThread` 停止。
- **线程安全**：所有导出函数（除状态日志辅助外）完全线程安全；回调在后台线程池执行，不得阻塞或调用远程 API。
- **自动内存回收**：数据句柄闲置 5 分钟自动释放（由 `TLF_DataPool` 管理）。
- **部署模式**：通过 `Wait_Connection_ReadyOk=False` 允许节点无序启动。

---

## 3. 快速入门（5 分钟）

以下是最简服务端 + 客户端示例（使用 `lingofuse_helper` 高级封装）。

**服务端 (`server.lpr`)：**
```pascal
program server;
uses lingofuse_helper;

procedure AddCallback(Trigger: Pointer; Input, Output: TDataHnd); cdecl;
var a,b,c: integer;
begin
  a := Input.ReadInt32;
  b := Input.ReadInt32;
  c := a + b;
  Output.WriteInt32(c);
end;

var App: LF.TAppHandle;
begin
  App := LF.TAppHandle.Create('Calc', 'Calculator');
  App.RegisterCall('add', 'Add two ints', nil, @AddCallback);
  LF.ResetPrepare;
  LF.PrepareService('ipc:calc', 'ipc:calc');
  LF.PrepareClient('ipc:calc', App);
  if LF.PrepareDone then
    WriteLn('Service ready, press Enter to stop...');
  ReadLn;
  App.Free;
  LF.Shutdown;
end.
```

**客户端 (`client.lpr`)：**
```pascal
program client;
uses lingofuse_helper;

function Add(a,b: integer): integer;
var Data, Res: TDataHnd;
begin
  Data := TDataHnd.Create('add');
  Data.WriteInt32(a).WriteInt32(b);
  Res := LF.CallApp('Calc', Data, 3000);
  if Res.Size > 0 then Result := Res.ReadInt32 else Result := 0;
  Data.Free; Res.Free;
end;

begin
  LF.ResetPrepare;
  LF.PrepareClient('ipc:calc', nil);
  if LF.PrepareDone then
    WriteLn('10 + 20 = ', Add(10,20));
  LF.Shutdown;
end.
```

**编译运行：**
```bash
lazbuild -B server.lpi
lazbuild -B client.lpi
# 启动服务端，再启动客户端
```

---

## 4. API 完全参考

> **说明**：以下所有函数均来自 `lingofuse_import.pas`，除特别标注外均为 `cdecl; external` 导入。辅助函数（带 `Ex` 后缀）是 Pascal 封装，自动处理 UTF-8 编码。

### 4.1 数据句柄操作

#### `LF_CreateData(MethodName: PAnsiChar): TDataHnd`
- **功能**：创建一个新的数据句柄，并设置其关联的 API 名称。初始载荷为空（大小 0）。
- **参数**：`MethodName` – 目标 API 名称（UTF-8，以空字符结尾）。
- **返回**：非 nil 句柄，必须通过 `LF_FreeData` 释放。
- **辅助**：`LF_CreateDataEx(MethodName: string): TDataHnd`（自动 UTF-8 转换）。
- **示例**：`h := LF_CreateDataEx('echo');`
- **陷阱**：句柄创建后 API 名称不可更改；载荷的读写不影响 API 名称。

#### `LF_FreeData(Hnd: TDataHnd)`
- **功能**：销毁数据句柄，释放内存。如果句柄已在全局池中，会从池中移除。
- **参数**：`Hnd` – 要释放的句柄，可为 nil。
- **注意**：即使句柄被自动回收器回收，显式调用此函数仍是必须的（推荐）。
- **陷阱**：不要在回调中或远程调用未完成时释放句柄。

#### `LF_GetBuffer(Hnd: TDataHnd): Pointer`
- **功能**：返回内部缓冲区的起始指针（只读或读写）。
- **返回**：指针，若句柄为空或大小为 0 则返回 nil。
- **注意**：指针仅在句柄未被释放或调整大小时有效，不得手动释放。
- **辅助**：`LF_GetBufferOffset(Hnd; Offset: NativeInt): Pointer` 返回偏移后的指针。

#### `LF_WriteBuffer(Hnd: TDataHnd; Buff: Pointer; Size: Int64): Int64`
- **功能**：从当前位置写入 `Size` 字节，缓冲区自动扩容，位置向后移动。
- **返回**：实际写入的字节数（通常等于 Size）。
- **注意**：写入操作会更新句柄的最后活跃时间，影响自动回收计时。

#### `LF_ReadBuffer(Hnd: TDataHnd; Buff: Pointer; Size: Int64): Int64`
- **功能**：从当前位置读取最多 `Size` 字节到 `Buff`，位置向后移动。
- **返回**：实际读取的字节数（可能小于 Size）。
- **注意**：若当前位置已到末尾，则返回 0。

#### 位置与大小操作
- `LF_GetPos(Hnd): Int64` – 获取当前读写位置（0-based）。
- `LF_SetPos(Hnd; Pos_: Int64)` – 设置读写位置，若超出当前大小则扩展缓冲区（填充 0）。
- `LF_GetSize(Hnd): Int64` – 获取缓冲区总大小（字节）。
- `LF_SetSize(Hnd; Size_: Int64)` – 调整缓冲区大小，截断或扩展（扩展部分未初始化）。

#### 原子类型读写辅助（Pascal 封装，非 external）

| 写入函数                           | 读取函数（out 参数）                        | 读取函数（返回值）                    |
| ---------------------------------- | ------------------------------------------ | ------------------------------------ |
| `LF_WriteInt8(Hnd; Value: Int8): Boolean` | `LF_ReadInt8(Hnd; out Value: Int8): Boolean` | `LF_ReadInt8(Hnd): Int8`           |
| `LF_WriteUInt8` …                  | `LF_ReadUInt8` …                           | `LF_ReadUInt8`                     |
| `LF_WriteInt16` …                  | `LF_ReadInt16` …                           | `LF_ReadInt16`                     |
| `LF_WriteUInt16` …                 | `LF_ReadUInt16` …                          | `LF_ReadUInt16`                    |
| `LF_WriteInt32` …                  | `LF_ReadInt32` …                           | `LF_ReadInt32`                     |
| `LF_WriteUInt32` …                 | `LF_ReadUInt32` …                          | `LF_ReadUInt32`                    |
| `LF_WriteInt64` …                  | `LF_ReadInt64` …                           | `LF_ReadInt64`                     |
| `LF_WriteUInt64` …                 | `LF_ReadUInt64` …                          | `LF_ReadUInt64`                    |
| `LF_WriteSingle` …                 | `LF_ReadSingle` …                          | `LF_ReadSingle`                    |
| `LF_WriteDouble` …                 | `LF_ReadDouble` …                          | `LF_ReadDouble`                    |
| `LF_WriteString(Hnd; const Value: string): Boolean` | `LF_ReadString(Hnd; out Value: string): Boolean` | `LF_ReadString(Hnd): string` |
| `LF_WriteStringBytes(Hnd; const Value: TBytes): Boolean` | `LF_ReadStringBytes(Hnd; out Buff: TBytes): Boolean` | `LF_ReadStringBytes(Hnd): TBytes` |

- **注意**：
  - 所有写入函数以小端字节序编码。
  - `LF_WriteString` 会追加一个空终止符 (#0)，并写入 UTF-8 编码的字符串。
  - `LF_ReadString` 从当前位置扫描直到遇到 #0，若未找到则读取至缓冲区末尾（容错模式），并将位置移到终止符后或末尾。
  - 使用这些辅助函数会同时更新句柄的最后活跃时间。

---

### 4.2 应用句柄操作

#### `LF_CreateApp(appName, Desc: PAnsiChar): TAppHnd`
- **功能**：创建一个逻辑应用，用于注册 API。应用名在网络中必须唯一（匹配时不区分大小写）。
- **返回**：非 nil 句柄，必须通过 `LF_FreeApp` 释放（但释放后对象仍可能保留在全局池中，见后文）。
- **辅助**：`LF_CreateAppEx(appName, Desc: string): TAppHnd`。

#### `LF_FreeApp(appHnd: TAppHnd)`
- **功能**：将应用从所有客户端分离，停止其序列化通知线程，但 **不立即销毁** 底层对象。对象保留在全局池 `LF_App_Pool` 中，直到 `LF_Shutdown` 被调用。
- **注意**：调用后句柄立即失效，不能再用于注册或调用。但网络广播可能仍会短暂引用该应用数据（安全）。
- **陷阱**：若要强制回收内存，必须调用 `LF_Shutdown`（会清空整个池）。

#### `LF_Generate_AppName(): PAnsiChar`
- **功能**：生成一个全局唯一的应用名字符串，基于当前所有活动的 C4 隧道地址、远程 ID、进程名（含 PID）和高精度时间戳。
- **⚠️ 关键时机**：**必须在 `LF_PrepareDone` 成功返回后调用**，因为该函数依赖已建立的网络隧道信息。若在准备完成前调用，生成的名称可能缺少隧道标识，导致路由失败。
- **返回**：指向内部静态缓冲区的指针，该缓冲区在 **5 秒后被库自动释放**。调用者必须 **立即复制** 内容（例如赋值给 Pascal 字符串）。
- **辅助**：`LF_Generate_AppNameEx(): string`（自动复制）。
- **陷阱**：若返回的指针在 5 秒后仍被使用，将访问已释放内存。

#### `LF_Get_AppName(appHnd: TAppHnd): PAnsiChar`
- **功能**：获取指定应用句柄的名称，返回的指针同样只有 5 秒有效期，需立即复制。
- **辅助**：`LF_Get_AppNameEx(appHnd): string`。

#### `LF_BindApp(appHnd: TAppHnd): Integer`
- **功能**：将应用绑定到所有当前 **未绑定** 的客户端（即 `Cli.app = nil` 的客户端）。这通常在 `LF_PrepareDone` 之后调用。
- **返回**：成功绑定的客户端数量，若为 0 表示没有空闲客户端或主线程未激活。
- **注意**：每个客户端只能托管一个应用。若要绑定多个应用，需要：
  - 准备多个客户端（不同地址），或
  - 设置 `Overlap_Connection=True` 后再调用 `LF_PrepareClient`（见后文）。
- **陷阱**：如果所有客户端都已占用，`BindApp` 返回 0。此时若仍要使用该应用，可设置 `Overlap_Connection=True` 并再次 `PrepareClient` 创建新隧道。

---

### 4.3 API 注册（Call / Notify）

#### 原生回调注册（cdecl 函数指针）
- `LF_RegisterCall(appHnd; MethodName, Desc: PAnsiChar; Trigger: Pointer; OnCall: TLF_Call_Event): Integer`
- `LF_RegisterNotify(appHnd; MethodName, Desc: PAnsiChar; Trigger: Pointer; OnNotify: TLF_Notify_Event): Integer`
- **返回**：1 成功，0 失败（API 名称已存在）。
- **辅助**：`LF_RegisterCallEx` / `LF_RegisterNotifyEx`（字符串参数自动 UTF-8）。

#### 对象方法注册（Pascal 封装）
- `LF_RegisterCall_M(appHnd; MethodName, Desc: string; OnCall: TLF_Call_M): Integer`  
  注册对象方法（非同步），回调在后台线程执行。
- `LF_RegisterSyncCall_M(...)` – 回调通过 `TSoft_Synchronize_Tool` 同步到主线程，需定期调用 `LF_Sync` 驱动。
- `LF_RegisterNotify_M` / `LF_RegisterSyncNotify_M` 同理。

#### `LF_Unregister(appHnd; MethodName: PAnsiChar): Integer`
- **功能**：从本地注册表中移除 API，并触发网络广播（约 3 秒传播）。移除后本地立即可见，但远程节点可能仍有短暂缓存。
- **返回**：1 成功，0 未找到。

#### 回调约束（重要）
- **禁止**在回调中调用 `LF_Call`、`LF_Notify`、`LF_LocalCall` 等阻塞函数（会死锁）。
- **禁止**长时间阻塞（如 Sleep、等待事件）。
- 若需执行耗时操作，应异步提交到工作线程。

---

### 4.4 本地调用

- `LF_LocalCall(appHnd; Param: TDataHnd): TDataHnd`  
  同步执行 Call，返回结果句柄（调用者负责释放）。若 API 不存在或出错，结果句柄大小可能为 0。
- `LF_LocalNotify(appHnd; Param: TDataHnd)`  
  发送本地通知，无返回值。

---

### 4.5 网络准备与启动

#### `LF_ResetPrepare()`
- 清空所有已准备的服务和客户端队列。在重新配置网络前调用。

#### `LF_PrepareService(ListeningAddr_, PhysicsAddr_: PAnsiChar): Integer`
- **功能**：准备一个服务监听器。可多次调用以同时监听多个地址。
- **参数**：
  - `ListeningAddr_`：本地绑定地址，如 `0.0.0.0:9898`、`ipc:my_service`（IPC）。
  - `PhysicsAddr_`：对外公布的地址（客户端连接时使用），格式同 ListeningAddr_。
- **返回**：内部标签（正整数），-1 表示重复地址或无效格式。
- **注意**：若主线程已运行，服务会立即创建；否则队列等待。

#### `LF_PrepareClient(PhysicsAddr_: PAnsiChar; appHnd: TAppHnd): Integer`
- **功能**：准备一个客户端连接。若 `appHnd` 非 nil，则暴露该应用；若为 nil 则纯消费。
- **⚠️ 地址唯一性**：**每个物理地址只能有一个客户端**。重复调用同一地址将返回 -1（除非 `Overlap_Connection=True`）。
- **返回**：内部标签，-1 表示重复地址或无效。
- **辅助**：`LF_PrepareClientEx(addr: string; app: TAppHnd)` 和 `LF_PrepareClientEx(addr: string)`（纯消费）。

#### `LF_PrepareDone(): Integer`
- **功能**：启动 C4 框架，阻塞直到所有准备好的服务和客户端初始化完成（或超时）。
- **返回**：1 成功，0 失败。
- **控制行为**：通过 `LF_SetOption('Wait_Connection_ReadyOk', ...)` 和 `Wait_Connection_Timeout` 调整等待行为。
- **注意**：可在 `LF_Shutdown` 后再次调用，实现重启。

#### `LF_ExitMainThread()`
- 通知模拟主线程退出，停止网络事件循环。通常后接 `LF_Shutdown`。

---

### 4.6 远程调用与通知

#### `LF_Call(appName: PAnsiChar; Param: TDataHnd; Timeout_: UInt64): TDataHnd`
- **功能**：同步远程调用，等待响应。优先查找本地同名应用，若无则通过网络路由。
- **参数**：`appName` – 目标应用名；`Param` – 输入句柄；`Timeout_` – 毫秒，0 表示无限。
- **返回**：新句柄（永远非 nil），大小为 0 表示超时或失败。调用者必须释放。
- **辅助**：`LF_CallEx(appName: string; Param; Timeout): TDataHnd`。

#### `LF_Notify(appName: PAnsiChar; Param: TDataHnd)`
- **功能**：单向通知，不等待响应，尽力送达。

#### `LF_Sequenced_Notify(appName: PAnsiChar; Param: TDataHnd)`
- **功能**：序列化通知，保证同一 (app, api) 的 FIFO 顺序。内部使用专用线程池，空闲 5 分钟后线程自动回收。
- **注意**：适用于大文件分块、日志流等对顺序敏感的场景。

---

### 4.7 运行时选项与状态

#### `LF_SetOption(Option, Value: PAnsiChar)`
- **功能**：动态调整全局配置。所有更改立即生效。
- **常用选项**（区分大小写，支持别名）：
  - `password` / `passwd`：C4 认证令牌。
  - `Quiet`：静默模式（True/False）。
  - `ConsoleOutput` / `Console_Output`：是否输出控制台日志。
  - `ShowThreadID` / `ShowThread` / `Show_Thread`：日志中显示线程 ID。
  - `Overlap_Connection` / `Overlap_Client` / …：允许同一地址多个客户端（见陷阱）。
  - `Wait_Connection_ReadyOk` / `Wait_API_Prepare_Done` / `Wait_Ready`：是否等待客户端就绪（部署模式）。
  - `Wait_Connection_Timeout` / `Wait_TimeOut` / `WaitTimeOut`：等待超时（毫秒）。
  - `IPC_Serv_ThreadCount` / `IPC_ThreadCount`：IPC 线程池大小。
  - `IPC_Serv_MaxQueueLength`：IPC 消息队列长度。
  - `IPC_Serv_MaxMsgSize`：IPC 单条消息最大字节。
  - `Fixed_Sequenced_Time` / `Fixed_Sequenced_Life`：序列化通知的 fallback 阈值（毫秒）。
- **辅助**：`LF_SetOptionEx(Option, Value: string)`。

#### 状态日志
- `LF_GetStatusCount(): Integer` – 返回队列中待读日志条数（最多 1000 条）。
- `LF_GetStatus(): PAnsiChar` – 取出并返回下一条日志（UTF-8），若队列为空返回空字符串。指针有效期至下次调用，需立即复制。
- `LF_PostStatus(status: PAnsiChar)` – 向日志队列注入自定义消息。

---

### 4.8 同步辅助

- `LF_Sync(): Integer` – 处理主线程软同步队列中所有挂起任务（由 `RegisterSyncCall_M` 等注册），返回处理数量。应在主循环或定时器中定期调用。

---

### 4.9 查询与健康检查

- `LF_CheckMainThread(): Integer` – 返回 1 如果模拟主线程正在运行，否则 0。
- `LF_CheckApp(appName: PAnsiChar): Integer` – 返回 1 如果指定应用在线（基于本地缓存，可能有短暂滞后）。
- `LF_CheckApi(appName, apiName: PAnsiChar): Integer` – 返回 1 如果指定 API 可在网络中调用。
- **陷阱**：这些检查基于缓存，广播传播延迟约 3 秒，因此可能产生假阴性/假阳性。不应作为唯一决策依据。

---

### 4.10 关闭与清理

- `LF_Shutdown()` – 完全关闭框架：
  1. 停止所有序列化通知线程。
  2. 释放所有剩余数据句柄。
  3. 退出模拟主线程。
  4. 清空全局应用池（销毁所有未显式释放的 TLF_App）。
  5. 卸载 IPC 库，关闭核心调度线程。
- **说明**：可多次调用，支持重新初始化。

---

## 5. 完整示例深度解析

### 5.1 cross_demo – 跨语言负载均衡

**文件位置**：`pascal/cross_demo/`

**组件**：
- `cross_service`：注册中心（IPC 信标），仅监听 `ipc:cross`，无业务 API。
- `cross_node`：工作节点，注册 `add` 和 `inv_seri` 两个 Call API。
  - `add`：接收两个 Int32，返回和（模拟 32 位溢出）。
  - `inv_seri`：接收 6 种类型（byte, word, cardinal, uint64, string, single），按相反顺序回复（演示跨语言二进制兼容性）。
- `cross_call`：客户端，随机调用上述 API，持续 10 秒后退出，可多开以模拟负载。

**关键技术点**：
- **部署模式**：`LF_SetOptionEx('Wait_Ready', 'False')` 允许任意顺序启动。
- **负载均衡**：多个 `cross_node` 注册相同应用名 `demo`，C4 网格自动将请求分发到负载最低的节点（基于 `Cycle_Time_Anchor`）。
- **二进制序列化**：`inv_seri` 证明所有语言遵循相同的小端字节序和字符串 #0 终止约定。
- **Overlap_Connection**：若需在同一地址支持多个节点，可打开 `Overlap_Connection=True`。

**运行命令**：
```bash
lazbuild -B cross_service.lpi
lazbuild -B cross_node.lpi
lazbuild -B cross_call.lpi
# 任意顺序启动（部署模式）
./cross_service
./cross_node   # 可开多个
./cross_call   # 可开多个
```

---

### 5.2 compute_grid – 分布式计算网格

**文件位置**：`pascal/Compute_Grid_Demo/`

- `compute_service`：注册中心 `ipc:compute_grid`。
- `compute_node`：注册 `exp` API，使用 `Z.Expression` 引擎求值字符串表达式（如 `"1+2*3"`），返回计算结果。
- `compute_call`：每秒随机生成表达式并提交，持续 60 秒。

**技术演示**：
- 分布式 CPU 密集型任务调度。
- 服务发现与自动负载均衡。
- 可配合 Python `bridge.py` 实现 HTTP 入口。

---

### 5.3 sequence – 大数据顺序组装（Sequenced Notify）

**文件位置**：`pascal/SequenceData/`

- `sequence_serv`：服务端提供三个 API：
  - `BeginData`（Call）：返回一个会话 ID（内部 `TSequPool` 对象指针）。
  - `Data`（Notify）：接收数据块，包含 `(SessionID, Index, Payload)`。
  - `EndData`（Notify）：结束会话，后台线程等待所有块收齐，按 Index 排序，计算整体 MD5。
- `sequence_cli`：生成 10MB 随机数据，分块（1536 字节/块）通过 `Sequenced_Notify` 发送，最后发送 `EndData`。

**关键技术**：
- **序列化通知**：保证分块按发送顺序到达（FIFO）。
- **会话管理**：服务端使用 `Safe_Pointer` 哈希表将 SessionID 映射到数据池，防止野指针。
- **乱序重排**：`TSequPool` 在后台按 Index 排序。
- **超时回收**：服务端定时扫描，若某会话超过 5 秒未更新，则判定为“事故”并强制回收资源。
- **野指针防护**：客户端传递的指针值需在 `Safe_Pointer` 中注册，否则拒绝。

---

### 5.4 bridge – HTTP + JSON 标准化桥接

**文件位置**：`pascal/bridge/`

- `bridge_service`：注册中心 `ipc:compute_grid`。
- `bridge_compute`：注册 `exp` API，接收 **JSON 字符串**（`{"args":["1+2*3"]}`），解析后求值，返回 JSON 结果（`{"code":0,"result":"7"}`）。使用 `LF_ReadString` 读取 JSON（容错模式），使用 `LF_WriteString` 写入 JSON（自动追加 #0）。
- `bridge.py`（Python）：独立 HTTP 网关，将 POST 请求转发给 LingoFuse 服务，支持路径格式 `/<app>/<api>`。
- `web_demo.html`：浏览器前端，通过 `fetch` 调用。

**关键技术**：
- **空终止符处理**：`bridge.py` 自动在请求体后追加 #0，并在响应前剥离 #0，使 HTTP 客户端获得纯净 JSON。
- **预检**：`bridge.py` 调用 `LF_CheckApi` 避免无效调用（含重试）。
- **标准化接口**：所有请求统一为 POST + JSON，符合 RESTful 风格。

---

### 5.5 压测套件 – BenchServer / BenchClient

**文件位置**：`pascal/LingoFuseBenchServer.lpr` / `LingoFuseBenchClient.lpr`

- **BenchServer**：注册 20 个 API，覆盖算术、哈希、加密、编码、字符串、随机、时间、sleep、echo，均以 JSON 交互。
- **BenchClient**：启动 50 个线程，每线程调用 20 次（轮询 API），统计成功率、延迟、QPS。

**用途**：性能调优和容量规划。

---

### 5.6 fpc_tester – 综合单元测试

**文件位置**：`pascal/fpc_tester_for_LingoFuse.lpr`

覆盖全部功能：
- 数据句柄所有原子类型读写（含链式操作）。
- 本地调用/通知。
- IPC 远程调用。
- 多线程并发（10×100 次）。
- 性能基准（1000 次顺序调用）。
- 资源泄漏检测（批量分配/释放）。
- 重复注册检测。
- UTF-8 国际化（中文 API 名）。

运行后自动输出测试结果，是环境验证的首选工具。

---

## 6. 高级范式与最佳实践

### 6.1 动态生成应用名 (LF_Generate_AppName)

**正确时序**：
```
1. LF_ResetPrepare
2. LF_PrepareClient(endpoint, nil)   // 先建立连接
3. LF_PrepareDone                     // 等待网络就绪
4. AppName := LF_Generate_AppNameEx   // 此时隧道信息已存在
5. App := LF_CreateAppEx(AppName)
6. 注册 Notify 回调
7. LF_BindApp(App)                    // 绑定到已有的客户端
```

**错误时序**：在 `LF_PrepareDone` 前调用 `LF_Generate_AppName`，生成的名称可能不含隧道地址和远程 ID，导致路由失败。

### 6.2 动态绑定应用 (LF_BindApp) 与 Overlap_Connection

**场景**：你已有一个客户端连接，现在想动态附加一个新生成的 App。

- **如果客户端空闲**（未绑定任何 App）：直接 `LF_BindApp(App)` 即可。
- **如果客户端已占用**：`BindApp` 返回 0。此时你有两个选择：
  1. **设置 `Overlap_Connection=True` 并再次 PrepareClient**：  
     ```pascal
     LF_SetOptionEx('Overlap_Connection', 'True');
     LF_PrepareClientEx(endpoint, App);  // 创建新隧道并立即绑定 App
     ```
  2. **准备不同的物理地址**（如不同 IPC 名称或端口）再调用 `LF_PrepareClient`。

### 6.3 部署模式 (Wait_Connection_ReadyOk)

- `Wait_Connection_ReadyOk = True`（默认）：`LF_PrepareDone` 阻塞直到所有客户端就绪，适用于严格顺序启动。
- `Wait_Connection_ReadyOk = False`：`LF_PrepareDone` 立即返回，允许节点无序启动。此时需要实现重试逻辑，因为目标服务可能尚未注册。

### 6.4 序列化通知线程池

- 每个 `(App, API)` 对拥有一个专用线程，保证 FIFO。
- 线程空闲 5 分钟后自动终止，后续需要时重新创建。
- 可通过 `LF_SetOption('Fixed_Sequenced_Time', ...)` 调整 fallback 阈值（默认 20 秒）。

### 6.5 数据句柄自动回收机制

- `TLF_DataPool` 每隔 5 秒扫描一次，释放闲置超过 5 分钟的句柄。
- 该机制作为安全网，**不应依赖**。生产环境中应显式调用 `LF_FreeData`。

### 6.6 应用生命周期与 LF_FreeApp / LF_Shutdown

- `LF_FreeApp`：分离应用，停止其序列化线程，但对象仍在全局池中。
- 若想立即释放应用内存，必须调用 `LF_Shutdown`（会清空整个池）。
- 对于长期运行且频繁创建/销毁应用的服务，需谨慎设计，避免池无限增长。

### 6.7 回调线程安全与死锁预防

- 所有回调在 C4 线程池中执行，**禁止**在其中调用任何阻塞的 LingoFuse 函数（`LF_Call`, `LF_Notify`, `LF_PrepareDone` 等）。
- 若需远程调用，异步提交给工作线程。
- 同步回调（`RegisterSync*`）虽在主线程执行，但仍需定期调用 `LF_Sync` 驱动，否则会阻塞后台线程。

---

## 7. 🚨 已知陷阱与避坑指南

### 7.1 生成 AppName 的时机
**问题**：在 `LF_PrepareDone` 前调用 `LF_Generate_AppName`，得到的名称缺少隧道信息，导致路由失败。  
**解决**：务必在网络就绪后调用。

### 7.2 BindApp 失败的处理
**问题**：`LF_BindApp` 返回 0，但应用仍需使用。  
**解决**：使用 `Overlap_Connection=True` + `LF_PrepareClient` 创建新隧道，或将 `App` 作为参数直接传递给 `LF_PrepareClient`（在 Prepare 阶段绑定）。

### 7.3 CheckApp / CheckApi 缓存延迟
**问题**：刚注册的应用/API，`CheckApp` 仍返回 0，因为广播未到达。  
**解决**：不要将检查结果作为绝对信任；直接调用 `LF_Call` 并处理超时/空结果。或实现重试循环（如轮询 3 次，间隔 200ms）。

### 7.4 回调中禁止调用远程 API
**问题**：在回调中调用 `LF_Call` 导致死锁。  
**解决**：使用 `TThread.CreateAnonymousThread` 异步执行远程调用，回调仅负责入队。

### 7.5 数据句柄必须显式释放
**问题**：依赖自动回收导致内存积压。  
**解决**：在任何分支路径（包括异常）中都确保调用 `LF_FreeData`，可使用 `try..finally`。

### 7.6 JSON 空终止符 (#0) 问题
**问题**：Pascal 端 `LF_WriteString` 追加 #0，但 HTTP 客户端不需要；`LF_ReadString` 若遇到无 #0 的数据会读至末尾（容错）。  
**解决**：HTTP 桥接器（如 Python `bridge.py`）会在请求后追加 #0，并在响应前剥离 #0，确保兼容。自定义客户端需遵循同样规则。

### 7.7 客户端地址唯一性限制
**问题**：`LF_PrepareClient` 不能对同一物理地址调用两次（除非 `Overlap_Connection=True`）。  
**解决**：使用不同地址（如不同 IPC 名称或端口），或设置 Overlap_Connection 为 True。

### 7.8 等待就绪超时
**问题**：`Wait_Connection_Timeout` 过期后 `PrepareDone` 仍返回 1，但部分客户端可能离线。  
**解决**：检查 `LF_CheckApp` 或实现应用层握手。

### 7.9 同步回调必须调用 LF_Sync
**问题**：注册了 `RegisterSyncCall_M` 但主循环未调用 `LF_Sync`，回调永不执行，导致后台线程阻塞。  
**解决**：在主循环或定时器中定期调用 `LF_Sync`。

### 7.10 资源清理顺序
**正确顺序**：
```
LF_ExitMainThread;
LF_FreeApp(App);
LF_Shutdown;
```
**错误**：先调用 `LF_Shutdown` 再释放 App（Shutdown 会清空池，但若 App 仍被引用可能造成访问违规）。

### 7.11 Overlap_Connection 与多应用共存
**问题**：`Overlap_Connection=False`（默认）时，同一地址的后续 `PrepareClient` 会忽略新 App，导致应用未绑定。  
**解决**：如需多应用，提前设置 `Overlap_Connection=True`。

### 7.12 LF_FreeApp 不立即销毁对象
**问题**：调用 `LF_FreeApp` 后应用仍占用内存（直到 `LF_Shutdown`）。  
**解决**：对于短期应用，若需立即释放，考虑重新设计或调用 `LF_Shutdown` 后重启框架。

---

## 8. 与 Python 绑定的范式对比

| 功能 | Pascal | Python | 说明 |
|------|--------|--------|------|
| 创建数据句柄 | `LF_CreateDataEx('api')` | `DataHandle('api')` | Python 构造器自动管理释放 |
| 注册 Call | `LF_RegisterCall_M(app, 'add', ..., OnCall)` | `@app.expose('add')` | Python 装饰器自动适配 |
| 注册 Notify | `LF_RegisterNotify_M(...)` | `@app.expose('add', notify=True)` | 同上 |
| 生成唯一名称 | `LF_Generate_AppNameEx` | `generate_app_name()` | 均需在 PrepareDone 后调用 |
| 绑定应用 | `LF_BindApp(app)` | `app.bind()` | 等价 |
| Overlap_Connection | `LF_SetOptionEx('Overlap_Connection', 'True')` | `set_option('Overlap_Connection', 'True')` | 等价 |
| 等待就绪 | `Wait_Connection_ReadyOk` 选项 | `set_option('Wait_Connection_ReadyOk', 'True')` | 等价 |
| 序列化通知 | `LF_Sequenced_NotifyEx` | `LF_Sequenced_Notify`（底层）或 `client.sequenced_notify` | 等价 |
| 错误处理 | 检查返回值 | 异常（`RegistrationError`, `ConnectionError`） | Python 更激进 |
| 资源清理 | 显式 `LF_FreeData`, `LF_FreeApp`, `LF_Shutdown` | 使用 `with` 语句或显式 `free()` | Pascal 需手动，Python 有 RAII 但同样推荐显式 |

**核心相似性**：底层 C ABI 一致，因此跨语言调用完全透明。不同之处仅在于语言习惯的封装层。

---

## 9. 附录 A – 函数速查表

| 分类 | 函数名 | 简要说明 |
|------|--------|----------|
| **数据句柄** | `LF_CreateData` | 创建句柄 |
| | `LF_FreeData` | 销毁句柄 |
| | `LF_GetBuffer` | 获取缓冲区指针 |
| | `LF_WriteBuffer` / `LF_ReadBuffer` | 原始读写 |
| | `LF_GetPos` / `LF_SetPos` | 位置操作 |
| | `LF_GetSize` / `LF_SetSize` | 大小操作 |
| | `LF_WriteInt32` 等 | 原子类型写入 |
| | `LF_ReadInt32` 等 | 原子类型读取 |
| | `LF_WriteString` / `LF_ReadString` | 字符串读写（带 #0） |
| **应用** | `LF_CreateApp` | 创建应用 |
| | `LF_FreeApp` | 分离应用（延迟销毁） |
| | `LF_Generate_AppName` | 生成唯一名称 |
| | `LF_Get_AppName` | 获取应用名 |
| | `LF_BindApp` | 绑定应用至空闲客户端 |
| **注册** | `LF_RegisterCall` | 注册 Call（cdecl 函数） |
| | `LF_RegisterNotify` | 注册 Notify（cdecl 函数） |
| | `LF_RegisterCall_M` | 注册 Call（对象方法，非同步） |
| | `LF_RegisterSyncCall_M` | 注册 Call（对象方法，同步到主线程） |
| | `LF_Unregister` | 注销 API |
| **本地调用** | `LF_LocalCall` | 本地执行 Call |
| | `LF_LocalNotify` | 本地执行 Notify |
| **网络准备** | `LF_ResetPrepare` | 清空准备队列 |
| | `LF_PrepareService` | 准备服务端 |
| | `LF_PrepareClient` | 准备客户端 |
| | `LF_PrepareDone` | 启动框架 |
| | `LF_ExitMainThread` | 停止事件循环 |
| **远程调用** | `LF_Call` | 同步 Call |
| | `LF_Notify` | 普通 Notify |
| | `LF_Sequenced_Notify` | 序列化 Notify |
| **选项与状态** | `LF_SetOption` | 设置运行时选项 |
| | `LF_GetStatusCount` | 状态队列长度 |
| | `LF_GetStatus` | 取出下一条状态 |
| | `LF_PostStatus` | 注入自定义状态 |
| **查询** | `LF_CheckMainThread` | 主线程状态 |
| | `LF_CheckApp` | 应用在线？ |
| | `LF_CheckApi` | API 可用？ |
| **清理** | `LF_Shutdown` | 完全关闭 |
| **同步** | `LF_Sync` | 处理主线程同步队列 |

---

## 10. 附录 B – 环境变量与编译选项

- **动态库搜索路径**：系统 PATH（Windows）或 LD_LIBRARY_PATH（Linux）。库名：`LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib`。
- **Lazarus 编译**：使用 `lazbuild -B project.lpi`。确保 `ZNetV2/source` 在单元搜索路径中。
- **配置文件**：首次运行生成 `<exe>.api-tool.ini`，可调整日志级别、超时等。

---

## 11. 附录 C – 常用宏与常量

- `C_Generate_Prefix = '@__generate__@'` – 自动生成名称的前缀。
- 默认端口：9898（TCP），IPC 使用命名管道。
- 日志队列大小：1000 条。
- 数据句柄闲置超时：5 分钟。
- 序列化通知线程空闲超时：5 分钟。
- 广播传播延迟：约 3 秒。

---

**本指南持续更新，欢迎通过 Issue 或 PR 补充遗漏。**