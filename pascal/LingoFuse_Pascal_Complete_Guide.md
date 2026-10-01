# LingoFuse Pascal 完整指南（含踩坑知识库 v3.0）

> **面向 AI 与人类开发者的权威参考**
> 第 1–6 章：学习指南；第 7 章：**Pascal 核心层踩坑知识库（本版重点）**；第 12 章：LLM 生态坑索引
>
> **本版 v3.0 的核心变化**（相对 v2.0）：
> - **关键修正**：数据句柄自动回收时间从 **5 分钟** 修正为 **10 分钟**（对齐源码 `C_Tick_Second * 60 * 10`）
> - **新增机制**：`TLF_DataMemory` 二级内存池、`Begin_Call` / `End_Call` 与 `calling___` 计数器、`LF_CreateData_Permanent` 的完整语义
> - **新增坑位**：LF-DATA-006 ~ LF-DATA-008、LF-APP-007、LF-NET-007、LF-OPT-003（合计 48 条）
> - **新增章节**：7.14「模拟主线程与 C4 进度循环」、7.15「内存与对象生命周期详解」
> - **完善**：网络事件的完整触发链条、`LF_PrepareDone` 的超时与返回值语义、`LF_FreeApp` 的 shutdown guard
> - **铁律扩充**：从 4 条扩充到 6 条
>
> **证据等级约定**（贯穿全文）：
> - 🟢 **已核实源码** — 在 `lingofuse_import.pas`、`lingofuse_helper.pas`、`Z.LingoFuse_Export.pas`、`Z.LingoFuse_Core.pas`、`Z.Net.C4.LingoFuse.pas`、`LingoFuse.lpr`、`Z.LingoFuse.md`、`Z.Json.md` 中有直接依据
> - 🟡 **仅文档转录** — 来自其他文档，未逐行回源码核对
> - 🔴 **推测** — 从行为推断，未找到直接源码依据；**使用前请回查源码**
>
> **本版的诚实声明**：第 7 章中所有条目标注了证据等级。凡是 🔴 级别的，说明我无法从当前材料中确认，**不装懂**。凡是 🟢 级别的，你可以在源码里找到对应实现。

---

## 📖 目录

- [第 1–6 章：基础指南](#第-16-章基础指南)
- [第 7 章：🚨 Pascal 核心层踩坑知识库（v3.0）](#7--pascal-核心层踩坑知识库)
  - [7.0 ID 体系与使用说明](#70-id-体系与使用说明)
  - [7.1 应用/句柄层（LF-APP-*）](#71-应用句柄层lf-app-)
  - [7.2 回调层（LF-CB-*）](#72-回调层lf-cb-)
  - [7.3 数据句柄层（LF-DATA-*）](#73-数据句柄层lf-data-)
  - [7.4 网络准备层（LF-NET-*）](#74-网络准备层lf-net-)
  - [7.5 远程调用层（LF-CALL-*）](#75-远程调用层lf-call-)
  - [7.6 序列化通知层（LF-SEQ-*）](#76-序列化通知层lf-seq-)
  - [7.7 查询与缓存层（LF-CHK-*）](#77-查询与缓存层lf-chk-)
  - [7.8 运行时选项层（LF-OPT-*）](#78-运行时选项层lf-opt-)
  - [7.9 清理与生命周期（LF-CLEAN-*）](#79-清理与生命周期lf-clean-)
  - [7.10 线程模型（LF-THREAD-*）](#710-线程模型lf-thread-)
  - [7.11 类型与编译（LF-TYPE-*）](#711-类型与编译lf-type-)
  - [7.12 跨语言数据交换（LF-XLANG-*）](#712-跨语言数据交换lf-xlang-)
  - [7.13 JSON 使用层（LF-JSON-*）](#713-json-使用层lf-json-)
  - [7.14 模拟主线程与 C4 进度循环（v3.0 新增）](#714-模拟主线程与-c4-进度循环lf-main-)
  - [7.15 内存与对象生命周期详解（v3.0 新增）](#715-内存与对象生命周期详解lf-mem-)
- [第 8–11 章：对比、附录](#第-811-章对比附录)
- [第 12 章：LLM 生态坑索引](#12--llm-生态坑索引)
- [附录 A：错误消息原文索引](#附录-a错误消息原文索引)
- [附录 B：ID 总览与维护约定](#附录-bid-总览与维护约定)
- [附录 C：给 AI 使用者的检索规则](#附录-c给-ai-使用者的检索规则)
- [六条铁律](#六条铁律)

---

# 第 1–6 章：基础指南

> **说明**：以下 1–6 章保留原文档的内容与结构，仅做以下调整：
> - **第 2 章** 核心概念新增「网络事件」、「二级内存池」、「calling 计数器」三条
> - **第 4 章** API 完全参考新增「4.11 网络事件」子章节；补充 `LF_CreateData_Permanent`、`LF_Sync`、`LF_GetStatus` 的详细信息
> - **第 6 章** 高级范式新增「6.8 网络事件监听」、「6.9 二级内存池与永久句柄」、「6.10 数据句柄的 calling 计数器」
> 其余段落保持原样，未做术语或示例改动。

## 1. 引言

**LingoFuse** 是一个面向智能体（Agent）和全栈系统的分布式 RPC 框架，基于 C4 服务网格，提供跨语言、跨进程、跨机器的函数调用能力。本指南聚焦于 **Pascal 语言绑定**，该绑定通过 `lingofuse_import.pas` 单元导出所有 C ABI 函数，并提供 `lingofuse_helper.pas` 作为 RAII 高级封装。

本指南旨在成为 **AI 和人类开发者** 的共同参考，详细解释每个 API、其参数、返回值、内部机制、常见陷阱和最佳实践。所有内容均基于 **LingoFuse v3.09** 及 Pascal 绑定单元 `Z.LingoFuse_Export.pas` 实现。

## 2. 核心概念速览

- **数据句柄 (TDataHnd)**：不透明指针，指向一个二进制缓冲区，包含 API 名称和载荷。读写操作基于当前位置，支持原子类型读写和字符串（UTF-8 + 空终止符）。
- **应用句柄 (TAppHnd)**：逻辑应用容器，可注册多个 API。应用名在网络中唯一（匹配时不区分大小写）。
- **API 模式**：
  - **Call**：请求-响应，同步等待结果。
  - **Notify**：单向通知，不等待响应。
- **序列化通知 (Sequenced Notify)**：保证同一 (App, API) 对的 FIFO 有序交付，通过专用线程池实现。
- **本地执行**：`LF_LocalCall` / `LF_LocalNotify` 在同一进程内执行，不经过网络。
- **远程执行**：`LF_Call` / `LF_Notify` / `LF_Sequenced_Notify` 通过网络路由，优先查找本地实例。
- **网络事件（v2.0 新增）**：`LF_Set_Network_Event` 安装全局回调，在客户端上线 / 下线时触发。**注意：Connect 语义不是 TCP 建链，而是"首次收到服务端 API 信息广播"；回调在后台 TCompute 工作线程执行**。详见 §4.11 与 §7.4 `LF-NET-005 / LF-NET-006`。
- **模拟主线程**：C4 事件循环运行在模拟主线程中，由 `LF_PrepareDone` 启动，`LF_ExitMainThread` 停止。**每个进程只能启动一次**，详见 §7.14。
- **线程安全**：所有导出函数（除状态日志辅助外）完全线程安全；回调在后台线程池执行，不得阻塞或调用远程 API。
- **自动内存回收**：数据句柄闲置 **10 分钟**自动释放（由 `TLF_DataPool` 管理）。**扫描间隔为 5 秒**——即句柄在闲置 10 分钟后，最多再等 5 秒被回收。**切勿依赖此机制**，务必显式 `LF_FreeData`。详见 §7.3 `LF-DATA-001`。
- **二级内存池（v3.0 新增）**：`TLF_DataMemory` 缓存已释放的 `TLF_Data` record，减少 `New` / `Dispose` 频率。详见 §7.15。
- **calling 计数器（v3.0 新增）**：`TLF_Data.calling___` 是一个原子计数器，通过 `Begin_Call` / `End_Call` 配对维护。**只要 `calling___ > 0`，句柄就不会被自动回收**——这是远程调用期间保护输入句柄的关键机制。详见 §7.3 `LF-DATA-007`。
- **部署模式**：通过 `Wait_Connection_ReadyOk=False` 允许节点无序启动。

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

## 4. API 完全参考

> **说明**：以下所有函数均来自 `lingofuse_import.pas`，除特别标注外均为 `cdecl; external` 导入。辅助函数（带 `Ex` 后缀）是 Pascal 封装，自动处理 UTF-8 编码。

### 4.1 数据句柄操作

#### `LF_CreateData(MethodName: PAnsiChar): TDataHnd`
- **功能**：创建一个新的数据句柄，并设置其关联的 API 名称。初始载荷为空（大小 0）。
- **参数**：`MethodName` – 目标 API 名称（UTF-8，以空字符结尾）。
- **返回**：非 nil 句柄，必须通过 `LF_FreeData` 释放。
- **辅助**：`LF_CreateDataEx(MethodName: string): TDataHnd`（自动 UTF-8 转换）。
- **陷阱**：
  - 句柄创建后 API 名称不可更改；载荷的读写不影响 API 名称。
  - **句柄会被加入自动回收池**，闲置 10 分钟后由 `TLF_DataPool.Progress` 自动释放。详见 §7.3 `LF-DATA-001`。

#### `LF_CreateData_Permanent(MethodName: PAnsiChar): TDataHnd`（v3.0 详述）
- **功能**：创建一个**不加入自动回收池**的数据句柄。
- **语义**：
  - 内部字段 `auto_recycle___ = False`。
  - **不加入 `LF_DataPool`**，因此永远不会被 `Progress` 扫描回收。
  - `LF_FreeData` 会**同步立即释放**句柄（而非标记为 `deleted___` 等待扫描）。
- **适用场景**：需要跨整个进程生命周期存在的句柄（缓存请求模板、全局 registry 等）。
- **不适用场景**：短生命周期的一次性句柄（用 `LF_CreateData`）。
- **辅助**：`LF_CreateData_PermanentEx(MethodName: string): TDataHnd`。
- **陷阱**：
  - **"永久"不等于"永不释放"**——你必须负责调用 `LF_FreeData`。丢失指针 = 整个进程生命周期内泄漏。
  - **初始化期间 `LF_FreeData` 是 no-op**：在 `LF_PrepareDone` 之前或 `LF_ExitMainThread` 之后创建的永久句柄，会一直保留到进程退出。详见 §7.3 `LF-DATA-008`。

#### `LF_FreeData(Hnd: TDataHnd)`
- **功能**：销毁数据句柄，释放内存。
- **行为差异**：
  - **自动回收句柄**（由 `LF_CreateData` 创建）：`LF_FreeData` 只标记 `deleted___ = True`，实际释放在下一次 `TLF_DataPool.Progress` 扫描时（最多 5 秒延迟）。
  - **永久句柄**（由 `LF_CreateData_Permanent` 创建）：`LF_FreeData` 同步立即释放。
- **陷阱**：
  - **只在模拟主线程活跃时有效**。`LF_PrepareDone` 前或 `LF_ExitMainThread` 后调用是 no-op。
  - 不要在回调中或远程调用未完成时释放句柄。
  - **不要释放 `calling___ > 0` 的句柄**（详见 §7.3 `LF-DATA-007`）。

#### `LF_GetBuffer(Hnd: TDataHnd): Pointer`
- **功能**：返回内部缓冲区的起始指针。
- **返回**：指针，若句柄为空或大小为 0 则返回 nil。
- **辅助**：`LF_GetBufferOffset(Hnd; Offset: NativeInt): Pointer` 返回偏移后的指针。
- **陷阱**：指针在 `LF_WriteBuffer` / `LF_SetSize` 后失效（底层扩容可能重分配）。
- **副作用**：**刷新句柄的时间戳**（`updated___ := True`），重置 10 分钟空闲倒计时。

#### `LF_WriteBuffer(Hnd: TDataHnd; Buff: Pointer; Size: Int64): Int64`
- **功能**：从当前位置写入 `Size` 字节，缓冲区自动扩容，位置向后移动。
- **返回**：实际写入的字节数。
- **副作用**：刷新句柄时间戳。

#### `LF_ReadBuffer(Hnd: TDataHnd; Buff: Pointer; Size: Int64): Int64`
- **功能**：从当前位置读取最多 `Size` 字节到 `Buff`，位置向后移动。
- **返回**：实际读取的字节数。
- **副作用**：刷新句柄时间戳。

#### 位置与大小操作
- `LF_GetPos(Hnd): Int64` – 获取当前读写位置。刷新时间戳。
- `LF_SetPos(Hnd; Pos_: Int64)` – 设置读写位置（超出大小会隐式扩容）。刷新时间戳。
- `LF_GetSize(Hnd): Int64` – 获取缓冲区总大小。刷新时间戳。
- `LF_SetSize(Hnd; Size_: Int64)` – 调整缓冲区大小（新增空间未初始化）。刷新时间戳。

#### 原子类型读写辅助（Pascal 封装）

| 写入 | 读取（out 参数） | 读取（返回值） |
|------|-----------------|---------------|
| `LF_WriteInt8` … `LF_WriteDouble` | `LF_ReadInt8` … `LF_ReadDouble` | 同左 |
| `LF_WriteString` | `LF_ReadString`（out） | `LF_ReadString` |
| `LF_WriteStringBytes` | `LF_ReadStringBytes`（out） | `LF_ReadStringBytes` |

- 所有写入函数以**小端字节序**编码。
- `LF_WriteString` **会追加空终止符 (#0)**。空字符串也写一个 `#0`。
- `LF_ReadString` **扫描直到 #0**；若未找到则读至缓冲区末尾（**容错模式**）。详见 §7.3 `LF-DATA-004`。

### 4.2 应用句柄操作

- `LF_CreateApp(appName, Desc: PAnsiChar): TAppHnd` / `LF_CreateAppEx`
  - `Desc` 为空时自动替换为 `'No Description'`。
- `LF_FreeApp(appHnd)` – 分离应用（**延迟销毁**，对象留在 `LF_App_Pool` 直到 `LF_Shutdown`）。
  - **有 shutdown guard**：`if not Core_Dispatch_Order_Activted then exit`。
- `LF_Generate_AppName(): PAnsiChar` / `LF_Generate_AppNameEx(): string`
  - **必须在 `LF_PrepareDone` 之后调用**。详见 §7.1 `LF-APP-003`。
  - **返回指针仅 5 秒有效**。详见 §7.1 `LF-APP-004`。
- `LF_Get_AppName(appHnd): PAnsiChar` / `LF_Get_AppNameEx(appHnd): string`
  - **返回指针仅 5 秒有效**。
  - **`appHnd = nil` 时安全返回 nil**（不再崩溃）。
- `LF_BindApp(appHnd): Integer`
  - **只绑定 `Cli.app = nil` 的客户端**。详见 §7.1 `LF-APP-005`。
  - **需要 `Simulator_Main_Thread_Activted = True`**。

### 4.3 API 注册

- `LF_RegisterCall` / `LF_RegisterNotify`（cdecl 函数）
  - **回调必须 `cdecl`**。详见 §7.1 `LF-APP-001`。
- `LF_RegisterCall_M` / `LF_RegisterSyncCall_M`（对象方法）
- `LF_RegisterNotify_M` / `LF_RegisterSyncNotify_M`
- `LF_Unregister` / `LF_UnregisterEx`

**回调约束**：禁止在回调中调用 `LF_Call`、`LF_Notify`、`LF_LocalCall`。详见 §7.2 `LF-CB-002`。

### 4.4 本地调用

- `LF_LocalCall(appHnd; Param: TDataHnd): TDataHnd`
  - **输入句柄不被释放**（调用者负责）。
  - **返回新句柄**（调用者负责）。
  - **内部使用 `Begin_Call` / `End_Call` 保护输入句柄**。详见 §7.3 `LF-DATA-007`。
- `LF_LocalNotify(appHnd; Param: TDataHnd)`
  - 同上。

### 4.5 网络准备与启动

- `LF_ResetPrepare()` – 清空准备队列与 tag 列表。
- `LF_PrepareService(ListeningAddr_, PhysicsAddr_: PAnsiChar): Integer` – 返回 tag 或 -1。
- `LF_PrepareClient(PhysicsAddr_: PAnsiChar; appHnd: TAppHnd): Integer` – 返回 tag 或 -1。
- `LF_PrepareDone(): Integer` – 启动主线程，返回 1 或 0。
  - **阻塞**：默认 `Wait_Connection_ReadyOk=True`，最多阻塞 `Wait_Connection_Timeout`（30 秒）。
  - **同进程只有第一次成功返回 1**。详见 §7.4 `LF-NET-003`。
  - **超时后仍返回 1**（不报告失败）。详见 §7.4 `LF-NET-007`。
- `LF_ExitMainThread()` – 停止主线程。

### 4.6 远程调用与通知

- `LF_Call(appName: PAnsiChar; Param: TDataHnd; Timeout_: UInt64): TDataHnd`
  - **超时返回 size=0 的句柄，不是 nil**。详见 §7.5 `LF-CALL-001`。
  - **输入句柄不被释放**。
  - **内部使用 `Begin_Call` / `End_Call`**。
- `LF_Notify(appName: PAnsiChar; Param: TDataHnd)`
  - **不保证顺序**。详见 §7.5 `LF-CALL-002`。
- `LF_Sequenced_Notify(appName: PAnsiChar; Param: TDataHnd)`
  - **仅保证同一 `(App, API)` 对的 FIFO**。详见 §7.6 `LF-SEQ-002`。

### 4.7 运行时选项与状态

- `LF_SetOption(Option, Value: PAnsiChar)`
  - `password` / `passwd`、`Quiet`、`ConsoleOutput`、`ShowThreadID`
  - `Overlap_Connection`、`Wait_Connection_ReadyOk`、`Wait_Connection_Timeout`
  - `IPC_Serv_ThreadCount`、`IPC_Serv_MaxQueueLength`、`IPC_Serv_MaxMsgSize`
  - `Fixed_Sequenced_Time`
  - **未知选项静默忽略**。详见 §7.8 `LF-OPT-001`。
  - **不持久化**。详见 §7.8 `LF-OPT-002`。
- `LF_GetStatusCount()` – 返回状态队列中的消息数（**队列上限 1000**）。
- `LF_GetStatus()` – 返回静态 64KB 缓冲的指针，**下次调用即失效**。
- `LF_PostStatus()` – 注入日志消息。
  - **主线程未运行时仍入队**（v3.09 修正，带诊断日志）。

### 4.8 同步辅助

- `LF_Sync(): Integer` – 处理挂起的同步回调。
  - **仅在自定义主循环中需要手动调用**。默认 `LF_PrepareDone` 后由 C4 进度循环自动驱动。详见 §7.2 `LF-CB-005`。

### 4.9 查询与健康检查

- `LF_CheckMainThread()` – 主线程活跃返回 1。
- `LF_CheckApp(appName)` – App 存在返回 1。
- `LF_CheckApi(appName, apiName)` – API 存在返回 1。
- **基于本地缓存，广播延迟约 3 秒**。详见 §7.7 `LF-CHK-001`。

### 4.10 关闭与清理

- `LF_Shutdown()` – 完全关闭：
  1. **清空网络事件回调**（`On_Network_Connect_Event := nil` / `On_Network_Disconnect_Event := nil`）
  2. 停止所有序列化通知线程
  3. 释放所有剩余数据句柄
  4. 退出模拟主线程
  5. 清空全局应用池（`LF_App_Pool.Clear`）
  6. 卸载 IPC 库、关闭核心调度线程

### 4.11 网络事件

```pascal
type
  TLF_Network_Event = procedure(addr_: pansichar); cdecl;

procedure LF_Set_Network_Event(On_Connect_, On_Disconnect_: TLF_Network_Event);
  cdecl; external liblingofuse name 'LF_Set_Network_Event';
```

**契约**：

| 契约 | 说明 |
|------|------|
| **Connect 语义** | **不是 TCP 建链**；是**首次收到服务端 `update_service_api_info` 广播**后的事件 |
| **Disconnect 语义** | 物理链路断开（`DoNetworkOffline`） |
| **执行线程** | **后台 TCompute 工作线程**（既不是调用线程，也不是主线程） |
| **`addr_` 生命周期** | **回调返回后立即释放**（`TLF_String.FreeUTF8AnsiChar`） |
| **触发次数** | Connect 每连接一次；Disconnect 每物理断线一次 |
| **异常处理** | 回调内异常被 `try...except` 吞掉 |
| **全局作用域** | 全局槽，无 per-client 注册 API |
| **`cdecl` 强制** | 与 C ABI 兼容；默认寄存器约定会崩溃 |
| **托管语言需 pin** | C# / Java / Python ctypes 必须保持强引用 |
| **`LF_Shutdown` 自动清空** | 卸载动态库前无需手动清空，但手动清空更安全 |

**最小示例（Pascal）**：

```pascal
procedure OnConnect(addr: PAnsiChar); cdecl;
var s: string;
begin
  s := UTF8ToString(addr);   // 立即复制，回调返回后 addr 失效
  TThread.Queue(nil,
    procedure
    begin
      Memo1.Lines.Add('Connected: ' + s);
    end);
end;

procedure OnDisconnect(addr: PAnsiChar); cdecl;
var s: string;
begin
  s := UTF8ToString(addr);
  TThread.Queue(nil,
    procedure
    begin
      Memo1.Lines.Add('Disconnected: ' + s);
    end);
end;

// 安装
LF_Set_Network_Event(@OnConnect, @OnDisconnect);

// 卸载（在 LF_Shutdown 之前可选调用）
LF_Set_Network_Event(nil, nil);
```

**详细契约与陷阱**：见 §7.4 `LF-NET-005` / `LF-NET-006`。

## 5. 完整示例深度解析

### 5.1 cross_demo – 跨语言负载均衡
- **组件**：`cross_service`（信标）、`cross_node`（工作节点，注册 `add`/`inv_seri`）、`cross_call`（客户端）
- **关键技术**：部署模式、自动负载均衡、二进制序列化、Overlap_Connection

### 5.2 compute_grid – 分布式计算网格
- `compute_service`（信标）、`compute_node`（`exp` API）、`compute_call`（客户端）
- 演示分布式 CPU 密集任务调度

### 5.3 sequence – 大数据顺序组装（Sequenced Notify）
- `sequence_serv`：`BeginData`/`Data`/`EndData` 三个 API
- `sequence_cli`：10MB 数据分块发送
- **关键技术**：FIFO 保证、Safe_Pointer 野指针防护、乱序重排

### 5.4 bridge – HTTP + JSON 标准化桥接
- `bridge_service`、`bridge_compute`（`exp` API）、`bridge.py`、`web_demo.html`
- **关键技术**：空终止符处理、预检、标准化 POST
- **JSON 相关**：见 §7.13 `LF-JSON-001 / LF-JSON-002`

### 5.5 压测套件 – BenchServer / BenchClient
- **BenchServer**：20 个 API 覆盖多类功能
- **BenchClient**：50 线程 × 20 次调用

### 5.6 fpc_tester – 综合单元测试
- 数据句柄原子类型读写、本地调用、IPC 远程、并发、性能基准、资源泄漏、重复注册、UTF-8

## 6. 高级范式与最佳实践

### 6.1 动态生成应用名 (LF_Generate_AppName) 的正确时序

```
1. LF_ResetPrepare
2. LF_PrepareClient(endpoint, nil)   // 先建立连接
3. LF_PrepareDone                     // 等待网络就绪
4. AppName := LF_Generate_AppNameEx   // 此时隧道信息已存在
5. App := LF_CreateAppEx(AppName)
6. 注册 Notify 回调
7. LF_BindApp(App)                    // 绑定到已有的客户端
```

### 6.2 动态绑定应用 (LF_BindApp) 与 Overlap_Connection

- 客户端空闲时直接 `LF_BindApp(App)`
- 客户端已占用时：
  1. 设 `Overlap_Connection=True` 后再次 `PrepareClient`
  2. 或准备不同的物理地址

### 6.3 部署模式 (Wait_Connection_ReadyOk)

- `True`（默认）：阻塞直到客户端就绪
- `False`：立即返回，允许无序启动

### 6.4 序列化通知线程池

- 每个 `(App, API)` 对拥有专用线程，保证 FIFO
- 线程空闲 5 分钟后自动终止
- 通过 `Fixed_Sequenced_Time` 调整 fallback 阈值（默认 20 秒）

### 6.5 数据句柄自动回收机制（**v3.0 修正**）

- `TLF_DataPool.Progress` **每 5 秒扫描一次**。
- 每次扫描处理三类情况：
  1. `updated___ = True` 或 `calling___ > 0`：刷新 `time___`，重置 `updated___`
  2. `deleted___ = True`：加入用户主动释放列表，实际释放
  3. `tk - time___ > 10 分钟`：加入超时释放列表，实际释放
- **10 分钟是空闲回收的时间阈值**（不是 5 分钟）。
- 5 秒是**扫描间隔**，意味着句柄可能在被标记为可回收后最多再等 5 秒才实际释放。
- **不应依赖此机制**，生产环境应显式 `LF_FreeData`。
- **`calling___ > 0` 的句柄不会被超时回收**——这是远程调用期间的保护机制。

### 6.6 应用生命周期

- `LF_FreeApp`：分离应用，但对象仍在池中
- `LF_Shutdown`：清空池，销毁所有对象
- 需要动态回收内存：显式调用 `LF_Shutdown` 后重启框架

### 6.7 回调线程安全与死锁预防

- 所有回调在 C4 线程池执行
- **禁止**在回调中调用阻塞函数
- 同步回调需定期 `LF_Sync` 驱动

### 6.8 网络事件监听

```pascal
// 主程序初始化时安装
procedure OnNetConnect(addr: PAnsiChar); cdecl;
var s: string;
begin
  s := UTF8ToString(addr);   // 必须立即复制
  TThread.Queue(nil,
    procedure
    begin
      StatusBar1.SimpleText := 'Connected: ' + s;
    end);
end;

procedure OnNetDisconnect(addr: PAnsiChar); cdecl;
begin
  TThread.Queue(nil,
    procedure
    begin
      StatusBar1.SimpleText := 'Disconnected';
    end);
end;

// 安装（进程级单例）
LF_Set_Network_Event(@OnNetConnect, @OnNetDisconnect);

// 卸载（在 LF_Shutdown 之前可选调用）
LF_Set_Network_Event(nil, nil);
```

**关键规则**（对应 §7.4）：

- **回调在后台 TCompute 工作线程执行**——UI 操作必须 `TThread.Queue` 编组
- **`addr_` 回调返回后失效**——必须立即复制
- **异常被吞**——不要依赖异常控制流
- **不要调用阻塞 LF_***——死锁风险
- **托管语言需 pin 回调**——防止 GC 回收

### 6.9 二级内存池与永久句柄（v3.0 新增）

**场景**：需要跨整个进程生命周期持有某个请求模板。

**推荐做法**：用 `LF_CreateData_Permanent`：

```pascal
var
  g_template: TDataHnd;
begin
  // 初始化阶段（LF_PrepareDone 之前也可以）
  g_template := LF_CreateData_PermanentEx('myapi');
  LF_WriteString(g_template, 'template-payload');

  // 整个进程生命周期内可反复使用
  // ...

  // 退出前显式释放
  LF_FreeData(g_template);
  LF_Shutdown;
end;
```

**不要做的事**：

```pascal
// ❌ 用普通 LF_CreateData 创建长生命周期句柄
g_template := LF_CreateDataEx('myapi');
// 10 分钟未使用 → 被自动回收 → g_template 变悬空

// ❌ 用永久句柄但忘记释放
g_template := LF_CreateData_PermanentEx('myapi');
// 进程退出前从不调用 LF_FreeData → 泄漏
```

### 6.10 数据句柄的 calling 计数器（v3.0 新增）

**内部机制**：`TLF_Data.calling___: TAtomInt` 是一个原子计数器。所有对外 API 在发起远程调用时会配对使用 `Begin_Call` / `End_Call`：

```pascal
// LF_LocalCall / LF_Call / LF_Notify / LF_Sequenced_Notify 内部伪代码
PLF_Data(Param).Begin_Call;      // calling___ += 1，同时 updated___ := True
try
  // ... 执行远程调用 ...
finally
  PLF_Data(Param).End_Call;      // calling___ -= 1，同时 updated___ := True
end;
```

**为什么需要**：远程调用可能耗时数秒甚至超时（30 秒以上），期间 `TLF_DataPool.Progress` 会定期扫描。如果没有 `calling___`，输入句柄可能在调用返回前被超时回收。

**对用户的影响**：

- 你**不需要手动**调用 `Begin_Call` / `End_Call`——`LF_Call` 等 API 内部自动调用。
- 但如果你的自定义代码持有一个句柄较长时间（超过 10 分钟），要么定期调用 `LF_GetSize` / `LF_GetPos` 等刷新时间戳，要么改用 `LF_CreateData_Permanent`。

---

# 7. 🚨 Pascal 核心层踩坑知识库

> **本章是本文档的核心资产**。每一条坑都经过整理，具备以下字段：
>
> - **ID**：稳定标识，供后续增量和交叉引用
> - **证据等级**：🟢 已核实源码 / 🟡 仅文档转录 / 🔴 推测
> - **触发条件**：什么时候会踩到
> - **症状**：具体表现（可能有多种）
> - **根因**：源码级解释
> - **最小复现**（如适用）
> - **修复 diff / 正确做法**
> - **验证清单**：修复后如何确认有效
> - **影响版本**
> - **相关坑**

## 7.0 ID 体系与使用说明

### 7.0.1 ID 命名规则

`LF-<子系统>-<三位序号>`，例如 `LF-CB-001`（Callback 子系统第 1 条）。

子系统前缀：

| 前缀 | 含义 | 对应章节 |
|------|------|---------|
| `LF-APP` | 应用句柄与应用生命周期 | 7.1 |
| `LF-CB` | 回调函数 | 7.2 |
| `LF-DATA` | 数据句柄 | 7.3 |
| `LF-NET` | 网络准备与连接 | 7.4 |
| `LF-CALL` | 远程调用与通知 | 7.5 |
| `LF-SEQ` | 序列化通知 | 7.6 |
| `LF-CHK` | 查询与缓存 | 7.7 |
| `LF-OPT` | 运行时选项 | 7.8 |
| `LF-CLEAN` | 清理与生命周期 | 7.9 |
| `LF-THREAD` | 线程模型 | 7.10 |
| `LF-TYPE` | 类型与编译 | 7.11 |
| `LF-XLANG` | 跨语言数据交换 | 7.12 |
| `LF-JSON` | JSON 使用 | 7.13 |
| **`LF-MAIN`** | **模拟主线程与 C4 进度循环（v3.0 新增）** | **7.14** |
| **`LF-MEM`** | **内存与对象生命周期（v3.0 新增）** | **7.15** |

### 7.0.2 证据等级使用约定

- 🟢 **已核实源码**：在 `lingofuse_import.pas`、`lingofuse_helper.pas`、`Z.LingoFuse_Export.pas`、`Z.LingoFuse_Core.pas`、`Z.Net.C4.LingoFuse.pas`、`LingoFuse.lpr`、`Z.LingoFuse.md`、`Z.Json.md` 中有直接文本依据。
- 🟡 **仅文档转录**：来自其他文档，未逐行回源码核对。
- 🔴 **推测**：从行为/示例代码推断，**使用前请回查源码**。

**重要**：本版中 🔴 级别的条目**不构成权威结论**，仅作为"可疑点"提示。

### 7.0.3 版本区间说明

- "所有版本"：从 v1.0 起就存在的约束（多为设计固有限制）
- "v3.0+"：v3.0 引入的接口/行为
- "v3.09+"：v3.09 引入的 `LF_CreateData_Permanent`、`Begin_Call` / `End_Call`
- "v3.11+"：v3.11 引入的 JSON 相关接口（`LF-JSON-*`）
- "未知"：无法从现有材料判断引入版本

---

## 7.1 应用/句柄层（LF-APP-*）

### LF-APP-001：回调必须 `cdecl`，否则崩溃或行为异常

- **证据等级**：🟢 已核实源码
- **影响版本**：所有版本
- **触发条件**：用 `LF_RegisterCall` / `LF_RegisterNotify` 注册回调时未加 `cdecl`
- **症状**（多种表现，取决于编译器和栈布局）：
  - A. 调用时进程直接崩溃（AV / 段错误）
  - B. 回调能进，但 `Trigger` 变成垃圾指针、`Input`/`Output` 位置错乱
  - C. 回调返回后栈不平衡，后续任何调用行为异常
  - D. **最危险**：某编译器/某优化级别下"看着正常"，换环境后崩
- **根因**：`lingofuse_import.pas` 定义：
  ```pascal
  TLF_Call_Event = procedure(Trigger: Pointer; Input: TDataHnd___; Output: TDataHnd___); cdecl;
  ```
  C ABI 硬性要求 `cdecl`；Delphi 默认 `register`、FPC 默认 `fastcall`，参数走寄存器的方式不同 → 栈错位。
- **最小复现**：
  ```pascal
  procedure BadCallback(Trigger: Pointer; Input, Output: TDataHnd); // 无 cdecl
  begin
    WriteLn('Trigger=', PtrUInt(Trigger)); // 会打出垃圾值
  end;
  ```
- **修复 diff**：
  ```diff
  - procedure BadCallback(Trigger: Pointer; Input, Output: TDataHnd);
  + procedure BadCallback(Trigger: Pointer; Input, Output: TDataHnd); cdecl;
  ```
- **验证清单**：
  - [ ] FPC 编译无 `Callback type mismatch` 警告
  - [ ] 打印 `PtrUInt(Trigger)`，与注册时传入值一致
  - [ ] `fpc_tester_for_LingoFuse` 全项通过
  - [ ] 至少 2 种编译器 × 2 种优化级别通过
- **相关坑**：LF-CB-001、LF-CB-002

### LF-APP-002：`LF_FreeApp` 是两阶段析构，不立即释放内存

- **证据等级**：🟢 已核实源码（`Z.LingoFuse.md` §2.3、`Z.LingoFuse_Export.pas` 注释）
- **影响版本**：所有版本
- **触发条件**：调用 `LF_FreeApp` 后立即期望内存下降
- **症状**：
  - 内存不降反升，或长时间不降
  - 频繁创建/销毁 App 的服务，`LF_App_Pool` 持续增长
- **根因**：`LF_FreeApp` 只做四件事：
  1. **shutdown guard**：`if not Core_Dispatch_Order_Activted then exit`
  2. 遍历所有 `TC40_LF_Client`，把 `Cli.app = app` 的置 nil（**解绑**）
  3. `LF_Notify_Sequence_Thread_Pool.Kill_App(app)`（**停掉顺序通知线程**）
  4. `app.FakeFree`（**仅移除定时器**）
  
  对象**不立即销毁**——仍在 `LF_App_Pool` 中，等 `LF_Shutdown` 时清理。
  
  **为什么这样设计**：防止网络广播仍在引用 App 数据时出现悬空指针。
- **正确做法**：
  - **长期运行**：避免频繁创建/销毁 App，可复用 App 名
  - **短期任务**：调用 `LF_Shutdown` 后重启框架
  - **测试程序**：一次性创建多个 App，最后统一 `LF_Shutdown`
- **验证清单**：
  - [ ] 观察 `LF_App_Pool` 大小
  - [ ] 长期运行服务在 24 小时内池大小稳定
- **相关坑**：LF-CLEAN-001、LF-CLEAN-002

### LF-APP-003：`LF_Generate_AppName` 必须在 `LF_PrepareDone` 之后调用

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 注释明确警告）
- **影响版本**：所有版本
- **触发条件**：在 `LF_PrepareDone` 返回前调用 `LF_Generate_AppName`
- **症状**：
  - 生成的名字**缺少隧道地址和 RemoteID**
  - 服务端 `LF_Sequenced_Notify` 到该名字时，控制台刷屏 `no found app("...")`
  - 客户端永远收不到消息，`finish_event` 永不置位
- **根因**：`LF_Generate_AppName` 的实现（`Z.LingoFuse_Export.pas` 实现）：
  1. 拼接所有 `C40_PhysicsTunnelPool` 的**地址和 RemoteID**
  2. 拼接 `Make_LingoFuse_Process_Name`（进程名 + PID）
  3. 拼接 `AtomInc(Generate_AppName_Call_Num)`（自增计数器）
  4. 前缀 `C_Generate_Prefix = '@__generate__@'`
  
  这些隧道信息在 `LF_PrepareDone` 之前**不存在**。
- **最小复现**（Python 侧等价）：
  ```python
  # ❌ 错误：PrepareDone 前生成
  client_name = generate_app_name()  # 名字缺少隧道信息
  LF_PrepareClient(endpoint, nil)
  LF_PrepareDone()
  # 服务端推消息到这个名字 → 永远找不到
  ```
- **修复 diff**：
  ```diff
    LF_ResetPrepare;
    LF_PrepareClient(endpoint, nil);
  - client_name := LF_Generate_AppNameEx;   // ❌ 太早
    if LF_PrepareDone() = 1 then
    begin
  +   client_name := LF_Generate_AppNameEx; // ✅ 此时隧道已就绪
      App := LF_CreateAppEx(client_name, '...');
      App.RegisterNotify('llm_stream', OnStream);
      LF_BindApp(App);
    end;
  ```
- **验证清单**：
  - [ ] 生成的名字包含前缀 `@__generate__@`
  - [ ] 名字中包含 IPC/TCP 地址字符串
  - [ ] 用 `LF_CheckAppEx(client_name)` 返回 1
  - [ ] 服务端不再刷屏 `no found app`
- **相关坑**：LF-XLANG-001、LF-NET-003

### LF-APP-004：`LF_Generate_AppName` / `LF_Get_AppName` 返回指针 5 秒失效

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 注释"5 seconds"，`Z.LingoFuse_Export.pas` 中 `Z.Notify.DelayFreeMem(5.0, Result)`）
- **影响版本**：所有版本
- **触发条件**：保留返回的 `PAnsiChar` 指针，5 秒后才使用
- **症状**：字符串变成乱码、空字符串，或访问违规
- **根因**：这两个函数返回**指向内部临时缓冲区的指针**，库在 **5 秒后**通过 `Z.Notify.DelayFreeMem` 自动释放该缓冲区。
- **最小复现**：
  ```pascal
  var P: PAnsiChar;
  P := LF_Generate_AppName;
  Sleep(6000);           // 6 秒后
  WriteLn(P);            // ❌ use-after-free
  ```
- **修复 diff**：
  ```diff
  - var P: PAnsiChar;
  - P := LF_Generate_AppName;
  - Sleep(6000);
  - WriteLn(P);            // ❌
  + var S: string;
  + S := LF_Generate_AppNameEx;  // ✅ Ex 版本立即复制
  + Sleep(6000);
  + WriteLn(S);            // ✅
  ```
- **验证清单**：
  - [ ] 代码中不出现 `LF_Generate_AppName`（非 Ex）的返回值被跨语句保留
  - [ ] 所有使用点都改为 `LF_Generate_AppNameEx` 或 `LF_Get_AppNameEx`
- **相关坑**：LF-APP-003、LF-DATA-002

### LF-APP-005：`LF_BindApp` 只绑定"未绑定"的客户端

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` `LF_BindApp` 实现）
- **影响版本**：所有版本
- **触发条件**：在已有 App 的客户端上调用 `LF_BindApp(newApp)`
- **症状**：返回值 0，新 App 从未绑定
- **根因**：`LF_BindApp` 的实现：
  1. 要求 `Simulator_Main_Thread_Activted`（主线程已启动），否则返回 0
  2. 遍历所有 `TC40_LF_Client`
  3. **只绑定 `Cli.app = nil` 的客户端**
  4. 返回成功绑定的数量
- **正确做法**（三选一）：
  1. **`Overlap_Connection=True` + 新建隧道**：
     ```pascal
     LF_SetOptionEx('Overlap_Connection', 'True');
     LF_PrepareClientEx(endpoint, newApp);
     ```
  2. **准备不同的物理地址**：
     ```pascal
     LF_PrepareClientEx('ipc:my_service_2', newApp);
     ```
  3. **在 Prepare 阶段直接传 App**：
     ```pascal
     LF_PrepareClientEx(endpoint, newApp);   // 而不是 PrepareClient(endpoint, nil)
     ```
- **验证清单**：
  - [ ] `LF_CheckMainThread() = 1`
  - [ ] `LF_BindApp` 返回值 > 0
  - [ ] 用 `LF_CheckAppEx(newAppName)` 返回 1
- **相关坑**：LF-NET-001、LF-NET-004

### LF-APP-006：`Overlap_Connection=False` 时同一地址的第二个 App 被静默忽略

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 注释 + `Z.LingoFuse_Export.pas` `LF_PrepareClient` 实现）
- **影响版本**：所有版本
- **触发条件**：默认配置（`Overlap_Connection=False`）下，向同一地址重复 `LF_PrepareClient`
- **症状**：
  - 第二次 `LF_PrepareClient` 返回的 tag 是新的（不报错）
  - 但**新 App 从未被绑定**
  - 后续对该 App 的 `LF_Call` 永远超时
- **根因**：`Overlap_Connection=False` 时，每个物理地址只允许一个客户端隧道。第二次 `LF_PrepareClient` **复用已存在的隧道**，丢弃传入的新 App 参数。
- **最小复现**：
  ```pascal
  LF_PrepareClientEx('ipc:my_service', App1);   // OK
  LF_PrepareClientEx('ipc:my_service', App2);   // ⚠️ 静默忽略 App2
  ```
- **修复 diff**：
  ```diff
    LF_ResetPrepare;
  + LF_SetOptionEx('Overlap_Connection', 'True');   // ✅ 显式开启
    LF_PrepareService('ipc:my_service', 'ipc:my_service');
    LF_PrepareClientEx('ipc:my_service', App1);
    LF_PrepareClientEx('ipc:my_service', App2);
  ```
- **验证清单**：
  - [ ] `LF_CheckAppEx(App1Name)` 返回 1
  - [ ] `LF_CheckAppEx(App2Name)` 返回 1
  - [ ] 对两个 App 分别 `LF_Call` 均能成功
- **相关坑**：LF-NET-001、LF-APP-005

### LF-APP-007：`LF_FreeApp` 有 shutdown guard（v3.0 新增）

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` `LF_FreeApp` 实现）
- **影响版本**：所有版本
- **触发条件**：在 `LF_Shutdown` 之后（或 `LF_PrepareDone` 之前）调用 `LF_FreeApp`
- **症状**：函数**直接返回，什么都不做**——App 不会被解绑，顺序通知线程不会被停止
- **根因**：`LF_FreeApp` 的第一行：
  ```pascal
  if not Core_Dispatch_Order_Activted then exit;
  ```
  这是为了防止 `LF_Shutdown` 期间的**双重释放**：
  - `LF_Shutdown` 内部会调用 `Close_Core_Dispatch_Thread`，把 `Core_Dispatch_Order_Activted` 置为 False
  - 如果此后还调用 `LF_FreeApp`，会尝试访问已被清理的 `C40_ClientPool` → 崩溃
- **正确做法**：
  - **在 `LF_Shutdown` 之前调用 `LF_FreeApp`**（按 §7.9 的清理顺序）
  - 不要指望 `LF_Shutdown` 之后再 `LF_FreeApp`
- **验证清单**：
  - [ ] 清理顺序为 `ExitMainThread` → `FreeApp` → `Shutdown`
  - [ ] 不出现 `LF_Shutdown` 后的 `LF_FreeApp` 调用
- **相关坑**：LF-CLEAN-001、LF-APP-002

---

## 7.2 回调层（LF-CB-*）

### LF-CB-001：回调必须显式 `cdecl`

- **证据等级**：🟢 已核实源码
- **影响版本**：所有版本
- **说明**：与 **LF-APP-001** 是同一条坑（从应用层视角看）与同一条坑（从回调层视角看）。**合并表述**：无论注册 Call 还是 Notify，回调**必须**加 `cdecl`。
- **相关坑**：LF-APP-001

### LF-CB-002：回调中禁止调用阻塞型 LingoFuse 函数

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档"CRITICAL - CALLBACK BLOCKING"）
- **影响版本**：所有版本
- **触发条件**：在 Call/Notify 回调里调用 `LF_Call`、`LF_LocalCall`、`LF_Notify`、`LF_PrepareDone`
- **症状**：**整个进程死锁**，服务端不再响应任何请求；调试器显示回调线程阻塞在内部锁
- **根因**：回调运行在 C4 线程池的某个线程上，且持有可能被远程调用需要的内部锁。当回调调用 `LF_Call` 时，远程调用需要获取同一把锁 → **自锁死**。
- **最小复现**：
  ```pascal
  procedure MyCallback(Trigger: Pointer; Input, Output: TDataHnd); cdecl;
  var Res: TDataHnd;
  begin
    Res := LF_CallEx('OtherApp', Input, 5000);   // ❌ 死锁
  end;
  ```
- **修复 diff**：
  ```diff
    procedure MyCallback(Trigger: Pointer; Input, Output: TDataHnd); cdecl;
    begin
  -   Res := LF_CallEx('OtherApp', Input, 5000);   // ❌ 死锁
  +   // ✅ 异步提交到工作线程
  +   TThread.CreateAnonymousThread(
  +     procedure
  +     var Res: TDataHnd;
  +     begin
  +       Res := LF_CallEx('OtherApp', Input, 5000);
  +       // 处理 Res...
  +     end
  +   ).Start;
    end;
  ```
- **验证清单**：
  - [ ] 用调试器确认回调线程未持锁等待
  - [ ] 高并发场景下无死锁（压测 5 分钟以上）
  - [ ] `fpc_tester_for_LingoFuse` 的并发测试通过
- **相关坑**：LF-CB-003、LF-THREAD-001

### LF-CB-003：回调中禁止长时间阻塞

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
- **影响版本**：所有版本
- **触发条件**：在回调中 `Sleep`、等事件、进行大文件 IO
- **症状**：
  - 单个回调阻塞导致整个 C4 线程池线程不可用
  - 高并发下请求排队、超时
- **根因**：回调在 C4 线程池中执行。每个线程被占用就少一个可用线程。
- **正确做法**：
  - 回调只做"读输入 + 入队 + 立即返回"
  - 耗时操作放到工作线程
- **验证清单**：
  - [ ] 单个回调执行时间 < 10ms（用高频压测验证）
  - [ ] 使用 `TThread.CreateAnonymousThread` 或 `TCompute.RunC_NP` 异步化耗时操作
- **相关坑**：LF-CB-002

### LF-CB-004：回调必须线程安全

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
- **影响版本**：所有版本
- **触发条件**：
  - 回调访问全局变量、共享对象
  - 回调读写 UI 控件（VCL/LCL 非线程安全）
- **症状**：偶发崩溃，多核机器上概率更高
- **根因**：回调在后台线程池执行，**不是主线程**。除非用 `RegisterSyncCall_M`（同步到主线程），否则必须在回调内部处理并发。
- **正确做法**：
  - 回调内部只操作局部变量，或使用临界区保护共享状态
  - 若需访问 UI：用 `LF_RegisterSyncCall_M`，并在主循环调 `LF_Sync`
- **验证清单**：
  - [ ] 回调中不出现未加锁的全局变量写入
  - [ ] 回调中不直接访问 UI 控件
- **相关坑**：LF-CB-005、LF-THREAD-002

### LF-CB-005：同步回调必须由主循环驱动 `LF_Sync`

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `TSoft_Synchronize_Tool.Synchronize` 实现）
- **影响版本**：所有版本
- **触发条件**：注册了 `RegisterSyncCall_M` / `RegisterSyncNotify_M`，但主循环未定期调用 `LF_Sync`
- **症状**：
  - 同步回调**永远不执行**
  - 调用方线程永久阻塞
  - 后台线程处于 `while tmp.Second do TCore_Thread.Sleep(1)` 状态
- **根因**：`TSoft_Synchronize_Tool.Synchronize` 的实现：
  - 若当前线程**不是**主线程：将过程入队，然后 `while tmp.Second do Sleep(1)` 忙等
  - 主线程必须**定期调用** `Check_Synchronize`（通过 `LF_Sync`）来出队并执行
  - `LF_PrepareDone` 后 C4 进度循环自动驱动，无需手动
- **最小复现**：
  ```pascal
  App.RegisterCallSync('slow', 'Slow call', OnSlowCallback);
  while Running do
  begin
    // ❌ 没有 LF_Sync
    TCompute.Sleep(10);
  end;
  ```
- **修复 diff**：
  ```diff
    while Running do
    begin
  +   LF_Sync;                              // ✅ 必须定期调用
  +   Z.Core.Check_Soft_Thread_Synchronize(10);
      TCompute.Sleep(10);
    end;
  ```
- **验证清单**：
  - [ ] 主循环中有 `LF_Sync`（仅自定义主循环需要）
  - [ ] 同步回调能在 100ms 内执行（压测验证）
  - [ ] `LF_Sync` 返回值为处理的任务数（可用于日志监控）
- **相关坑**：LF-CB-004、LF-THREAD-001

---

## 7.3 数据句柄层（LF-DATA-*）

### LF-DATA-001：句柄必须显式释放，不能依赖自动回收（**v3.0 修正**）

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档 + `Z.LingoFuse_Core.pas` `TLF_DataPool.Progress` 实现）
- **影响版本**：所有版本
- **触发条件**：创建句柄后忘记 `LF_FreeData`
- **症状**：
  - 高强度调用下内存持续增长，最终 OOM
  - **10 分钟内**积累的句柄数超过自动回收速度
- **根因**：
  - `TLF_DataPool.Progress`：**每 5 秒扫描一次**，释放闲置超过 **10 分钟**的句柄
  - 回收是**异步的**，不保证及时性
  - 高强度调用下句柄累积速度远超回收速度
- **最小复现**：
  ```pascal
  for i := 1 to 100000 do
  begin
    Data := LF_CreateDataEx('add');
    LF_WriteInt32(Data, i);
    // ❌ 忘记 LF_FreeData
  end;
  ```
- **修复 diff**：
  ```diff
    Data := LF_CreateDataEx('add');
  + try
      LF_WriteInt32(Data, i);
      Res := LF_CallEx('Calc', Data, 3000);
  +   try
        WriteLn(Res.ReadInt32);
  +   finally
  +     LF_FreeData(Res);
  +   end;
  + finally
  +   LF_FreeData(Data);
  + end;
  ```
- **验证清单**：
  - [ ] 所有 `LF_CreateData` / `LF_Call` 返回值都有对应的 `LF_FreeData`
  - [ ] 用 `try..finally` 保证异常路径也释放
  - [ ] 长时间运行内存稳定
- **相关坑**：LF-DATA-002、LF-DATA-004

### LF-DATA-002：句柄不能在回调中释放，不能跨异步边界持有

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
- **影响版本**：所有版本
- **触发条件**：
  - 在回调中释放回调收到的 `Input` / `Output` 句柄
  - 把句柄交给异步线程后，主线程再释放
- **症状**：
  - 崩溃（use-after-free）
  - 或数据错乱（缓冲区被另一个请求复用）
- **根因**：
  - 回调收到的 `Input` / `Output` 由库管理，**调用者不拥有**
  - 数据句柄有自动回收机制，异步持有期间可能被回收
- **正确做法**：
  - 回调中**不释放** `Input` / `Output`
  - 需要跨异步边界传递数据时，**复制到自己的内存**（如 `TBytes`）
- **验证清单**：
  - [ ] 回调中不出现 `LF_FreeData(Input)` / `LF_FreeData(Output)`
  - [ ] 跨线程传递时使用值拷贝而非句柄
- **相关坑**：LF-DATA-001、LF-DATA-005

### LF-DATA-003：`Data_Param` 与 `Data_Result` 互斥

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_Data` 记录定义 + `Z.LingoFuse.md` §1.4）
- **影响版本**：所有版本
- **触发条件**：手动操作 `TLF_Data` 内部字段（高级用户）
- **症状**：如果试图同时使用 `Data_Param` 和 `Data_Result`，行为未定义
- **根因**：`TLF_Data` 的设计：
  > "**`Data_Param` 与 `Data_Result` 互斥**——同一句柄只有一个非 nil。"
- **正确做法**：使用 C ABI 的 `LF_ReadBuffer` / `LF_WriteBuffer`，**不要直接操作内部字段**。
- **相关坑**：LF-DATA-004

### LF-DATA-004：`LF_ReadString` 的容错模式可能读走全部剩余字节

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_ReadString` 实现）
- **影响版本**：所有版本
- **触发条件**：
  - 读取一个**没有 #0 结尾**的字符串
  - 后续还有数据要读
- **症状**：`LF_ReadString` **读走了整个剩余缓冲区**，后续 `LF_ReadInt32` 等读到空
- **根因**：`LF_ReadString` 的容错实现：
  ```
  从头扫描，遇到 #0 停止
  若扫描到缓冲区末尾都没有 #0 → 读走从当前位置到末尾的全部字节
  ```
- **最小复现**：
  ```pascal
  // 写入：RawJSON(无 #0) + Int32
  LF_WriteBuffer(Data, PAnsiChar('{"a":1}'), 7);
  LF_WriteInt32(Data, 42);   // 之后还有数据

  // 读取
  S := LF_ReadString(Data);  // S = '{"a":1}' + 4 字节的 42 二进制 → 乱码
  N := LF_ReadInt32(Data);   // ❌ 空
  ```
- **正确做法**：
  - 写入方：**总是追加 #0**（用 `LF_WriteString`）
  - 读取方：如果知道后面还有数据，先读长度前缀，或用 `LF_ReadBuffer` 精确读取
- **验证清单**：
  - [ ] 协议约定：字符串必须带 #0 结尾
  - [ ] 跨语言写入 JSON 时由桥接层追加 #0（见 LF-XLANG-001）
- **相关坑**：LF-XLANG-001、LF-XLANG-002

### LF-DATA-005：`LF_WriteString` 总是追加 #0

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_WriteString` 实现）
- **影响版本**：所有版本
- **触发条件**：跨语言传输 JSON、Protobuf 等
- **症状**：
  - Python/浏览器收到 Pascal 端返回的 JSON，`json.loads` 报错（尾部多余字节）
  - 若接收方也走了容错读，可能恰好不出问题（**隐患**）
- **根因**：`LF_WriteString` 的实现：
  ```pascal
  utf8 := TEncoding.utf8.GetBytes(Value);
  LF_WriteBuffer(Hnd, @utf8[0], len);
  LF_WriteUInt8(Hnd, 0);   // ← 总是追加 #0
  ```
- **正确做法**：
  - Pascal ↔ Pascal：双方都遵循 #0 约定，无问题
  - Pascal → HTTP/Python：由桥接层（如 `bridge.py`）自动剥离 #0
  - Pascal → 自定义二进制协议：用 `LF_WriteBuffer` 精确控制
- **验证清单**：
  - [ ] 桥接层（`bridge.py`）有剥离 #0 的逻辑
  - [ ] 或使用 `LF_WriteBuffer` 直接写二进制
- **相关坑**：LF-DATA-004、LF-XLANG-001

### LF-DATA-006：二级内存池 `TLF_DataMemory`（v3.0 新增）

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_DataMemory` 实现）
- **影响版本**：v3.09+
- **背景**：`TLF_Data` 是 **record**，不是 class。它由 `New` / `Dispose` 管理。频繁创建/释放会导致堆碎片化。
- **机制**：`TLF_DataMemory` 是一个二级内存池：
  - `Get_New_PLF_Data`：池非空时取 `First^.Data; Next`，否则 `New`
  - `Free_PLF_Data`：把指针 `Push` 回池（**不调用 `Dispose`**）
  - `Free_All_PLF_Data_Memory`：逐一 `Dispose` 并清空池（单元终结时调用）
  - 内部有 `Critical__` 保护，线程安全
- **对用户的影响**：
  - **完全透明**。`LF_CreateData` / `LF_FreeData` 内部自动使用这个池。
  - `LF_FreeData` 不是真的 `Dispose`——record 被推回池。
  - **只有单元终结时**才会真正释放所有池中 record。
- **为什么不导致内存泄漏**：池的大小受**活跃句柄数的峰值**限制，不会无界增长。峰值过后，池中的 record 数量稳定。
- **验证清单**：
  - [ ] 不需要额外操作——机制对用户完全透明
  - [ ] 若怀疑内存问题，用 `TLF_DataMemory.Free_All_PLF_Data_Memory` 手动清空（不推荐）
- **相关坑**：LF-DATA-007、LF-MEM-001

### LF-DATA-007：`calling___` 计数器保护进行中的远程调用（v3.0 新增）

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_Data` 定义 + `Z.LingoFuse_Export.pas` 中所有 `LF_Call` / `LF_LocalCall` / `LF_Notify` / `LF_Sequenced_Notify` 实现）
- **影响版本**：v3.09+
- **背景**：远程调用可能耗时数秒（甚至超时 30 秒以上）。如果期间 `TLF_DataPool.Progress` 扫描到该句柄，会不会被超时回收？
- **机制**：`TLF_Data` 有一个 `calling___: TAtomInt` 原子计数器，通过 `Begin_Call` / `End_Call` 配对维护：
  ```pascal
  // Begin_Call 实现
  calling___.UnLock(calling___.LockP^ + 1);
  updated___ := True;

  // End_Call 实现
  calling___.UnLock(calling___.LockP^ - 1);
  updated___ := True;
  ```
  `TLF_DataPool.Progress` 的判断条件：
  ```pascal
  if queue^.Data^.updated___ or (queue^.Data^.calling___.V > 0) then
    begin
      queue^.Data^.time___ := tk;
      queue^.Data^.updated___ := False;
    end
  else if (queue^.Data^.deleted___) then ...
  else if (tk - queue^.Data^.time___ > C_Tick_Second * 60 * 10) then ...
  ```
  **关键**：`calling___ > 0` 时**刷新 `time___`**，因此不会被超时回收。
- **对用户的影响**：
  - **完全透明**。`LF_Call` 等 API 内部自动 `Begin_Call` / `End_Call`。
  - **不要手动**调用 `Begin_Call` / `End_Call`——它们是内部方法，不在 C ABI 导出列表中。
- **用户需要知道的**：
  - 长耗时调用不会导致句柄被回收，即使超过 10 分钟。
  - 但**调用完成后** `calling___` 归零，句柄又回到正常的 10 分钟倒计时。
  - **不要释放正在被调用的句柄**——用户层面没有 `Begin_Call`，但 `LF_Call` 返回后输入句柄的 `calling___` 已经归零，可以释放。
- **验证清单**：
  - [ ] 长耗时远程调用（如 5 分钟）不会导致输入句柄被回收
  - [ ] 调用完成后立即 `LF_FreeData` 输入句柄
- **相关坑**：LF-DATA-006、LF-MEM-002

### LF-DATA-008：`LF_CreateData_Permanent` 的正确与错误使用（v3.0 新增）

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` `LF_CreateData_Permanent` 实现 + 注释）
- **影响版本**：v3.09+
- **背景**：默认的 `LF_CreateData` 会把句柄加入自动回收池。对于需要跨整个进程生命周期的句柄（如模板、缓存），10 分钟空闲超时可能不够。
- **正确用法**：
  ```pascal
  var
    g_template: TDataHnd;
  begin
    // 初始化阶段
    g_template := LF_CreateData_PermanentEx('myapi');
    LF_WriteString(g_template, 'template-payload');

    // 整个进程生命周期内可反复使用
    // ...

    // 退出前显式释放
    LF_FreeData(g_template);
    LF_Shutdown;
  end;
  ```
- **`LF_CreateData_Permanent` 的精确语义**：
  - `auto_recycle___ = False`
  - **不加入 `LF_DataPool`**
  - `LF_FreeData` **同步立即释放**（不是标记 `deleted___` 等待扫描）
  - 即使 `calling___ > 0` 也不会被扫描（因为它根本不在池里）
- **错误用法 1：忘记释放**
  ```pascal
  // ❌ 永久句柄忘记释放 → 进程生命周期内泄漏
  g_template := LF_CreateData_PermanentEx('myapi');
  // ... 从不调用 LF_FreeData ...
  ```
- **错误用法 2：短生命周期场景**
  ```pascal
  // ❌ 一次性句柄用 Permanent → 失去池的安全网
  procedure DoOneCall;
  var d: TDataHnd;
  begin
    d := LF_CreateData_PermanentEx('add');
    try
      // ...
    finally
      LF_FreeData(d);   // 必须手动，不会自动回收
    end;
  end;
  ```
- **错误用法 3：期望"永不释放"**
  ```pascal
  // ❌ 误解："Permanent" 不等于 "Never released"
  g_template := LF_CreateData_PermanentEx('myapi');
  // ... 期望进程退出时自动释放 ...
  // 实际上：不会。你必须显式 LF_FreeData。
  ```
- **错误用法 4：初始化窗口创建**
  ```pascal
  // ⚠️ 在 LF_PrepareDone 之前创建的永久句柄
  g_template := LF_CreateData_PermanentEx('myapi');
  // ... 从未调用 LF_PrepareDone ...
  LF_FreeData(g_template);   // ❌ no-op！因为 Simulator_Main_Thread_Activted = False
  // g_template 泄漏到进程退出
  ```
  **规则**：`LF_FreeData` 是 no-op 窗口 = `LF_PrepareDone` 之前或 `LF_ExitMainThread` 之后。
  在这个窗口创建的永久句柄会**一直保留到进程退出**——因为没有任何机制能释放它们。
- **正确决策树**：

  ```mermaid
  flowchart TD
      A["需要创建数据句柄"] --> B{"生命周期？"}
      B -- "短于 10 分钟" --> C["LF_CreateData"]
      B -- "长于 10 分钟但有限" --> D["LF_CreateData + 定期刷新<br/>（调用 GetSize/GetPos）"]
      B -- "整个进程生命周期" --> E["LF_CreateData_Permanent"]
      C --> F["忘记释放时池会兜底"]
      D --> G["必须确保定期访问"]
      E --> H["必须显式 LF_FreeData"]
  ```

- **验证清单**：
  - [ ] 所有 `LF_CreateData_Permanent*` 调用都有对应的 `LF_FreeData`
  - [ ] `LF_FreeData` 在 `LF_Shutdown` 之前调用
  - [ ] 不在 `LF_PrepareDone` 之前创建永久句柄（除非能接受泄漏）
- **相关坑**：LF-DATA-001、LF-DATA-006、LF-CLEAN-001

---

## 7.4 网络准备层（LF-NET-*）

### LF-NET-001：每个物理地址只能有一个客户端

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_PrepareClient` 注释）
- **影响版本**：所有版本
- **触发条件**：向同一地址第二次 `LF_PrepareClient`
- **症状**：返回 -1，并打印 `repeat connection` 错误（除非 `Overlap_Connection=True`）
- **根因**：
  `lingofuse_import.pas`：
  > "**IMPORTANT: The behaviour of this function regarding duplicate addresses is controlled by the `Overlap_Connection` option.**"
  
  - `Overlap_Connection=False`（默认）：只创建一个隧道，重复调用返回 -1
  - `Overlap_Connection=True`：每次调用创建新隧道
- **正确做法**：
  1. 使用不同地址
  2. 或设置 `Overlap_Connection=True`
- **验证清单**：
  - [ ] 相同地址的多个 `LF_PrepareClient` 返回值非 -1
  - [ ] `LF_CheckAppEx` 对所有 App 返回 1
- **相关坑**：LF-APP-005、LF-APP-006

### LF-NET-002：`LF_PrepareDone` 阻塞等待客户端就绪

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_PrepareDone` 注释）
- **影响版本**：所有版本
- **触发条件**：默认 `Wait_Connection_ReadyOk=True` 且目标服务未启动
- **症状**：
  - `LF_PrepareDone` 阻塞直到 `Wait_Connection_Timeout`（默认 30 秒）超时
  - 超时后**仍返回 1**（不报告失败）
  - 客户端以为一切正常，但后续调用全部超时
- **根因**：
  `lingofuse_import.pas` `LF_PrepareDone`：
  > "Blocks until the framework is initialised."
  
  `Z.LingoFuse_Export.pas` `LF_PrepareDone` 实现：
  ```pascal
  tk := GetTimeTick() + if_(Wait_Connection_Timeout < 500, uint64(5000), Wait_Connection_Timeout) + 1000;
  while Init_Running do
    begin
      Boot_Thread_Sync_Tool.Check_Synchronize(10);
      if GetTimeTick() > tk then break;
    end;
  Result := if_(Init_Successed, 1, 0);
  ```
  **注意**：外层超时 `max(Wait_Connection_Timeout, 5000) + 1000` 毫秒。
- **正确做法**（部署模式）：
  ```pascal
  LF_SetOptionEx('Wait_Ready', 'False');           // 不阻塞等待
  LF_SetOptionEx('Wait_Connection_Timeout', '5000'); // 缩短超时
  ```
  或：`PrepareDone` 后**检查 `LF_CheckApp`**，失败则重试
- **验证清单**：
  - [ ] 服务端未启动时，`LF_PrepareDone` 返回时间 < 1 秒（部署模式）
  - [ ] 或：`LF_PrepareDone` 后 `LF_CheckAppEx` 返回 1
- **相关坑**：LF-NET-004、LF-NET-007、LF-CHK-001

### LF-NET-003：`LF_PrepareDone` 在同一进程内只有第一次返回 1

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` `LF_PrepareDone` 实现 + `Z.LingoFuse.md` §2.6）
- **影响版本**：未知（v3.0+ 至少）
- **触发条件**：同一进程内 `LF_PrepareDone` 被多次调用
- **症状**：
  - 第一次返回 1
  - 第二次及以后返回 0
  - 依赖"第二次返回 1"的逻辑永久失败
- **根因**：
  - `LF_PrepareDone` 内部启动模拟主线程
  - **主线程一旦启动，后续调用检测到 `Simulated_Main_Thread_Running = True` 时立即返回 0**
  ```pascal
  if Simulated_Main_Thread_Running then
      exit;   // Result 保持 0
  ```
- **实战场景**（LTB 的 `Server.start()` 与 `language_middleware._connect()` 竞争）：
  - `Server.start()` 内部先调 `LF_PrepareDone()` → 主线程启动
  - `language_middleware._connect()` 后调 `LF_PrepareDone()` → 返回 0 → 连接失败
  - **修复**：调整顺序，让 middleware 先连接
- **正确做法**：
  - **同一进程只调用一次 `LF_PrepareDone`**
  - 若必须多次初始化，先 `LF_Shutdown` 再重新 `LF_ResetPrepare` + `LF_PrepareDone`
  - 或按依赖顺序安排初始化（middleware → Server）
- **验证清单**：
  - [ ] 全进程范围内只有一处 `LF_PrepareDone` 调用
  - [ ] 若有多处，确认它们的调用顺序
- **相关坑**：LF-NET-002、LF-CLEAN-002

### LF-NET-004：`Wait_Connection_ReadyOk=False` 下的重试逻辑必须自己实现

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 注释）
- **影响版本**：所有版本
- **触发条件**：部署模式（`Wait_Ready=False`）下，服务端未启动
- **症状**：客户端 `LF_PrepareDone` 立即返回，但目标服务尚未注册；客户端直接调用失败
- **根因**：部署模式允许无序启动，因此 `PrepareDone` **不保证目标服务已就绪**。
- **正确做法**：
  ```pascal
  function WaitForApp(const AppName: string; TimeoutMs: Integer): Boolean;
  var tk: TTimeTick;
  begin
    tk := GetTimeTick();
    while GetTimeTick() - tk < TimeoutMs do
    begin
      if LF_CheckAppEx(AppName) then Exit(True);
      TCompute.Sleep(200);
    end;
    Result := False;
  end;
  ```
- **验证清单**：
  - [ ] 服务端未启动 → 客户端有超时逻辑，不会无限阻塞
  - [ ] 服务端延迟启动 → 客户端能自动等到
- **相关坑**：LF-NET-002、LF-CHK-001

### LF-NET-005：网络事件回调在后台 TCompute 工作线程执行

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` 类型注释 + `Z.Net.C4.LingoFuse.pas` `Do_LF_Network_Connect_Th___` 实现）
- **影响版本**：v3.0+
- **触发条件**：安装 `LF_Set_Network_Event` 回调后，客户端上线 / 下线
- **症状**（在回调中直接操作 UI）：
  - 偶发崩溃（AV / 段错误）
  - UI 状态不更新
  - VCL / LCL 报 "Control has no parent window"
- **根因**：触发链
  ```
  TC40_LF_Client.cmd_update_service_api_info (首次广播)
      ↓
  Do_LF_Network_Connect(addr_)
      ↓ if Assigned(On_Network_Connect_Event) then
  TCompute.RunC(addr_.BuildUTF8AnsiChar(), nil, Do_LF_Network_Connect_Th___)
      ↓  ← 这里派发到后台 TCompute 工作线程
  On_Network_Connect_Event(thSender.UserData)   ← 用户回调
      ↓
  TLF_String.FreeUTF8AnsiChar(thSender.UserData)
  ```
  回调**既不是调用线程，也不是主线程**——是 TCompute 工作线程。
- **最小复现**：
  ```pascal
  procedure BadConnect(addr: PAnsiChar); cdecl;
  begin
    Memo1.Lines.Add(UTF8ToString(addr));   // ❌ 后台线程操作 UI
  end;
  ```
- **修复 diff**：
  ```diff
    procedure GoodConnect(addr: PAnsiChar); cdecl;
  + var s: string;
    begin
  +   s := UTF8ToString(addr);   // 先复制（回调返回后 addr 失效）
  +   TThread.Queue(nil,
  +     procedure
  +     begin
  +       Memo1.Lines.Add('Connected: ' + s);   // ✅ 主线程操作 UI
  +     end);
    end;
  ```
- **验证清单**：
  - [ ] 回调内没有直接操作 UI 控件
  - [ ] 回调内使用 `TThread.Queue` / `Synchronize` 编组
  - [ ] 连续触发（重连）不崩溃
- **相关坑**：LF-NET-006、LF-CB-004

### LF-NET-006：网络事件回调的 `addr_` 在回调返回后立即失效

- **证据等级**：🟢 已核实源码（`Z.Net.C4.LingoFuse.pas` `Do_LF_Network_Connect_Th___` 实现）
- **影响版本**：v3.0+
- **触发条件**：在回调中保存 `addr_` 指针，回调返回后使用
- **症状**：
  - 字符串变成乱码或空
  - 访问违规（use-after-free）
  - **诡异**：某些场景下"看着正常"（内存未立即被覆写）
- **根因**：`Do_LF_Network_Connect_Th___` 的实现：
  ```pascal
  procedure Do_LF_Network_Connect_Th___(thSender: TCompute);
  begin
    try
        On_Network_Connect_Event(thSender.UserData);   // 用户回调
    except
    end;
    TLF_String.FreeUTF8AnsiChar(thSender.UserData);    // ← 回调返回后立即释放
  end;
  ```
  `addr_` 是库内部临时分配的 UTF-8 缓冲，**回调返回后立即释放**。
- **最小复现**：
  ```pascal
  var
    g_addr: PAnsiChar;   // ❌ 全局保存指针

  procedure OnConnect(addr: PAnsiChar); cdecl;
  begin
    g_addr := addr;      // ❌ 悬空指针
  end;
  ```
- **修复 diff**：
  ```diff
  - var g_addr: PAnsiChar;
  + var g_addr: string;

    procedure OnConnect(addr: PAnsiChar); cdecl;
    begin
  -   g_addr := addr;
  +   g_addr := UTF8ToString(addr);   // ✅ 立即复制到 string
    end;
  ```
- **验证清单**：
  - [ ] 回调内立即复制 `addr_`，不在回调外使用指针
  - [ ] 若需异步处理，先复制为 `string` / `TBytes`
- **相关坑**：LF-NET-005、LF-APP-004

### LF-NET-007：`LF_PrepareDone` 超时后仍返回 1（v3.0 新增）

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` `LF_PrepareDone` 实现 + `Simulated_Main_Thread` 实现）
- **影响版本**：所有版本
- **触发条件**：`Wait_Connection_ReadyOk=True`，但网络慢或目标服务未启动
- **症状**：
  - `LF_PrepareDone` 阻塞 `Wait_Connection_Timeout` 毫秒后返回 **1**（成功）
  - 但**实际上并非所有客户端都就绪**
  - 后续调用该客户端相关 API 会失败
- **根因**：`LF_PrepareDone` 返回值是 `if_(Init_Successed, 1, 0)`。而 `Init_Successed` 只在两种情况下为 False：
  - `C40_Extract_CmdLine` 直接失败
  - 或 `Prepare_Commands.Count = 0` 时显式为 True
  
  如果只是**客户端连接超时**，`Simulated_Main_Thread` 会在 `repeat ... until` 循环中跳出，然后 `Init_Successed := Online_Num >= Prepare_Cli_Num` 仍为 False，但 `LF_PrepareDone` 的外层等待循环是 `while Init_Running do`——`Init_Running` 在 `Simulated_Main_Thread` 完成后才置为 False。所以**如果主线程在超时窗口内完成了启动**（无论成功或超时），`LF_PrepareDone` 都会返回 `Init_Successed` 的值，而**不是**返回 0。
- **正确做法**：
  - **不要仅依赖 `LF_PrepareDone` 返回值**——它反映的是"框架启动成功"，不是"所有客户端就绪"
  - 用 `LF_CheckAppEx` / `LF_CheckApiEx` 单独验证关键 App
  - 生产环境建议配置：
    ```pascal
    LF_SetOptionEx('Wait_Ready', 'False');           // 不阻塞启动
    LF_SetOptionEx('Wait_Connection_Timeout', '10000');
    if LF_PrepareDone = 1 then
      if not WaitForApp('CriticalApp', 60000) then
        // 关键 App 未就绪 → 记录告警或重试
    ```
- **验证清单**：
  - [ ] 服务端未启动时 `LF_PrepareDone` 仍返回 1（已知行为）
  - [ ] 后续 `LF_CheckAppEx` 确认为 False
  - [ ] 有独立的 `WaitForApp` 重试逻辑
- **相关坑**：LF-NET-002、LF-NET-004、LF-CHK-001

---

## 7.5 远程调用层（LF-CALL-*）

### LF-CALL-001：`LF_Call` 超时返回大小为 0 的句柄（不是 nil）

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_Call` 注释 + `Z.LingoFuse_Export.pas` `LF_Call` 实现）
- **影响版本**：所有版本
- **触发条件**：调用超时或目标 App 未注册
- **症状**：调用者用 `if Result <> nil then ...` 判断失败，**判断失效**
- **根因**：
  `lingofuse_import.pas`：
  > "On timeout, an empty result handle is returned (size 0). Always check the result size with LF_GetSize to detect timeouts."
  
  `Z.LingoFuse_Export.pas` 中 `LF_Call` 结尾：
  ```pascal
  if Output = nil then
      Output := TMem64.Create;
  Result := TLF_Data.New_Result_From(Output, True);
  ```
  **永远返回非 nil 句柄**。
- **最小复现**：
  ```pascal
  Res := LF_CallEx('Calc', Data, 1000);
  if Res <> nil then         // ❌ 永远为真（Res 非 nil）
    WriteLn(Res.ReadInt32);  // 读到 0 或垃圾
  ```
- **修复 diff**：
  ```diff
    Res := LF_CallEx('Calc', Data, 1000);
  - if Res <> nil then
  + if LF_GetSize(Res) > 0 then
      WriteLn(Res.ReadInt32)
  + else
  +   WriteLn('Timeout or target not found');
  ```
- **验证清单**：
  - [ ] 所有 `LF_Call` 返回值用 `LF_GetSize` 检查
  - [ ] 有超时处理分支
- **相关坑**：LF-CALL-002

### LF-CALL-002：`LF_Notify` 不保证送达，`LF_Sequenced_Notify` 才保证顺序

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档 + `Z.LingoFuse_Export.pas` 注释）
- **影响版本**：所有版本
- **触发条件**：用 `LF_Notify` 传输对顺序敏感的数据
- **症状**：大数据分块到达顺序错乱
- **根因**：
  - `LF_Notify`：**不保证顺序**，尽力送达
  - `LF_Sequenced_Notify`：同一 `(app, api)` 对保证 **FIFO**
- **正确做法**：
  - 顺序敏感 → `LF_Sequenced_Notify`
  - 不敏感 → `LF_Notify`（性能更好）
- **验证清单**：
  - [ ] 大数据分块用 `LF_Sequenced_Notify`
  - [ ] 服务端用 Index 排序做兜底
- **相关坑**：LF-SEQ-001、LF-SEQ-002

---

## 7.6 序列化通知层（LF-SEQ-*）

### LF-SEQ-001：序列化通知线程空闲 5 分钟后自动终止

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_Notify_Sequence_Thread.Do_Run_Th` 实现）
- **影响版本**：所有版本
- **触发条件**：某 `(App, API)` 对 5 分钟无 `Sequenced_Notify`
- **症状**：下一次调用时有明显启动延迟（线程重建）
- **根因**：`TLF_Notify_Sequence_Thread.Do_Run_Th`：
  > "若 **超过 5 分钟空闲**：`Activted := False`（**自动终止**）。"
  
  **注意**：这 5 分钟是**空闲超时**，不是回收时间。线程退出后会通过 `DelayFreeObj(5.0, self)` **延迟 5 秒释放**，避免 TCompute 的 UAF。
- **正确做法**：
  - 接受这一点（设计行为）
  - 若延迟敏感：改用 `LF_Notify`（可能乱序）
  - 或调整 `Fixed_Sequenced_Time`（默认 20 秒）
- **验证清单**：
  - [ ] 高频率场景下无可感知延迟
  - [ ] 低频率场景下延迟可接受
- **相关坑**：LF-SEQ-002

### LF-SEQ-002：`LF_Sequenced_Notify` 的 FIFO 保证仅限同一 `(App, API)` 对

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_Notify_Sequence_Thread_Pool` 实现）
- **影响版本**：所有版本
- **触发条件**：跨不同 `(App, API)` 对期望顺序
- **症状**：跨 API 的消息可能乱序
- **根因**：`TLF_Notify_Sequence_Thread_Pool`：
  > "**每个 `(App, API)` 对拥有一个专用线程**"
  
  不同 `(App, API)` 对使用不同线程，**线程间无顺序保证**。
- **正确做法**：
  - 需要跨 API 顺序：使用相同的 `(App, API)` 对
  - 或自己在应用层编号排序
- **验证清单**：
  - [ ] 跨 API 顺序敏感的流程使用相同 API 名
  - [ ] 或应用层有排序逻辑
- **相关坑**：LF-SEQ-001

---

## 7.7 查询与缓存层（LF-CHK-*）

### LF-CHK-001：`LF_CheckApp` / `LF_CheckApi` 基于缓存，延迟约 3 秒

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 注释 + `Z.LingoFuse_Export.pas` 全局查找实现）
- **影响版本**：所有版本
- **触发条件**：刚注册的 App/API 立即调用 `LF_CheckApp` / `LF_CheckApi`
- **症状**：
  - 返回 0（假阴性）
  - 或刚注销的 App/API 仍返回 1（假阳性）
- **根因**：
  `lingofuse_import.pas`：
  > "LF_CheckApp and LF_CheckApi perform lookups based on a **local cache** that is updated via network broadcasts. These broadcasts propagate with a typical delay of about **3 seconds**."
- **正确做法**：
  - **不要将检查结果作为绝对信任**
  - 直接 `LF_Call` 并处理超时/空结果
  - 或实现重试循环（3 次，间隔 200ms）
  ```pascal
  for i := 1 to 3 do
  begin
    if LF_CheckApiEx('App', 'api') then Break;
    TCompute.Sleep(200);
  end;
  ```
- **验证清单**：
  - [ ] 关键流程不依赖 `LF_CheckApp` / `LF_CheckApi` 的返回值
  - [ ] 或实现重试循环
  - [ ] 相关服务启动后至少等待 3 秒再预检
- **相关坑**：LF-NET-004

---

## 7.8 运行时选项层（LF-OPT-*）

### LF-OPT-001：`LF_SetOption` 未知选项静默忽略

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_SetOption` 注释 + `Z.LingoFuse_Export.pas` 实现）
- **影响版本**：所有版本
- **触发条件**：拼错选项名（大小写敏感）
- **症状**：设置无效果，且**无任何报错**
- **根因**：
  `Z.LingoFuse_Export.pas` 中 `LF_SetOption` 实现是一串 `if opt.Same(...) then ... else if ...`，**最后的 else 分支缺失**——未匹配的选项就是静默返回。
- **正确做法**：
  - 严格按官方列表拼写
  - 使用别名（如 `Wait_Ready` 是 `Wait_Connection_ReadyOk` 的别名）
- **验证清单**：
  - [ ] 选项名与官方列表完全一致
  - [ ] 用 `LF_GetStatus` 观察是否生效
- **相关坑**：LF-OPT-002

### LF-OPT-002：运行时选项不持久化

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_SetOption` 注释）
- **影响版本**：所有版本
- **触发条件**：`LF_Shutdown` 后重启
- **症状**：之前设置的选项全部丢失
- **根因**：
  `lingofuse_import.pas`：
  > "**Changes are not persisted across restarts**; applications must store their own configuration."
- **正确做法**：应用层负责保存配置，重启后重新 `LF_SetOption`
- **验证清单**：
  - [ ] 配置文件或命令行参数保留设置
  - [ ] 重启后重新应用所有选项
- **相关坑**：LF-OPT-001

### LF-OPT-003：`Overlap_Connection` 的完整语义与推荐配置（v3.0 新增）

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档 + `Z.LingoFuse_Export.pas` `LF_PrepareClient` 实现）
- **影响版本**：所有版本
- **默认值**：`False`
- **三种典型配置**：

  | 场景 | 推荐值 | 理由 |
  |------|:------:|------|
  | 单 App per 地址 | `False` | 节省资源，一个隧道足够 |
  | 多 App per 地址 | `True` | 每个 App 需要独立隧道 |
  | 动态 Client + BindApp | `False` + 后调 `LF_BindApp` | 一个空隧道 + 事后绑定 |

- **常见误解**：
  - **误解 1**：认为 `Overlap_Connection=True` 一定更好——**错**。每个隧道都有 TCP/IPC 资源开销（socket、缓冲区、线程）。
  - **误解 2**：认为默认值就是"最安全"——**不完全**。默认值 `False` 在多 App 场景下**静默忽略**第二个 App，极易踩坑。
  - **误解 3**：认为 `Overlap_Connection` 可以运行时切换——**技术上可以**（`LF_SetOption` 动态生效），但**已创建的隧道不会重排**。切换只影响**后续**的 `LF_PrepareClient` 调用。
- **推荐决策流程**：

  ```mermaid
  flowchart TD
      A["需要为多个 App 准备客户端"] --> B{"同一物理地址？"}
      B -- "否" --> C["默认配置即可<br/>每个地址一个隧道"]
      B -- "是" --> D["设置 Overlap_Connection=True"]
      D --> E["每个 LF_PrepareClient<br/>创建独立隧道"]
      B -- "动态决定" --> F["默认配置 + LF_BindApp"]
      F --> G["先建立空隧道<br/>后用 BindApp 绑定"]
  ```

- **验证清单**：
  - [ ] 多 App 场景显式设置 `Overlap_Connection=True`
  - [ ] 或使用 `LF_BindApp` 事后绑定
  - [ ] `LF_CheckAppEx` 对所有 App 都返回 1
- **相关坑**：LF-APP-005、LF-APP-006、LF-NET-001

---

## 7.9 清理与生命周期（LF-CLEAN-*）

### LF-CLEAN-001：正确的清理顺序是 `ExitMainThread` → `FreeApp` → `Shutdown`

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档 "RESOURCE CLEANUP ORDER"）
- **影响版本**：所有版本
- **触发条件**：清理顺序错误
- **症状**：
  - 关闭时崩溃
  - 或下次启动时报 `address in use`
- **根因**：
  `lingofuse_import.pas`：
  > "The correct shutdown sequence to avoid resource leaks and crashes is:
  > 1. LF_ExitMainThread
  > 2. LF_FreeApp(app)
  > 3. LF_Shutdown"
  
  **为什么不能先 Shutdown**：`LF_Shutdown` 内部会 `LF_App_Pool.Clear`，把所有 `TLF_App` 对象销毁。此后调用 `LF_FreeApp(app)` 会访问已销毁的对象。
- **最小复现**（错误顺序）：
  ```pascal
  // ❌ 错误
  LF_Shutdown;       // 先清空池，销毁所有 App
  LF_FreeApp(App);   // App 已销毁，访问违规
  ```
- **修复 diff**：
  ```diff
  - LF_Shutdown;
  - LF_FreeApp(App);
  + LF_ExitMainThread;
  + LF_FreeApp(App);
  + LF_Shutdown;
  ```
- **验证清单**：
  - [ ] 清理顺序严格按 `ExitMainThread` → `FreeApp` → `Shutdown`
  - [ ] 程序正常退出无崩溃
  - [ ] 重启无 `address in use`
- **相关坑**：LF-CLEAN-002、LF-APP-002、LF-APP-007

### LF-CLEAN-002：`LF_Shutdown` 后可以重新初始化

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
- **影响版本**：所有版本
- **触发条件**：`LF_Shutdown` 后再 `LF_PrepareDone`
- **症状**：（正常行为）框架重新启动
- **根因**：
  `lingofuse_import.pas`：
  > "LF_PrepareDone, LF_ExitMainThread, and LF_Shutdown are not one-shot. You can call LF_PrepareDone again after a shutdown to restart the framework."
- **注意**：
  - 需要先 `LF_ResetPrepare`
  - 且注意 LF-NET-003（`PrepareDone` 只有第一次返回 1 的约束）——`LF_Shutdown` 会重置这个状态
- **验证清单**：
  - [ ] 重启后 `LF_PrepareDone` 返回 1
  - [ ] 重启后原 App 需重新创建
- **相关坑**：LF-NET-003

### LF-CLEAN-003：DLL 场景下必须显式 `LF_Shutdown`

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
- **影响版本**：所有版本
- **触发条件**：LingoFuse 被编译为 DLL 使用
- **症状**：DLL 卸载后资源泄漏，或进程崩溃
- **根因**：
  `lingofuse_import.pas`：
  > "In a dynamic library (DLL), the shutdown is **NOT automatic** because the library may be unloaded by the host process before finalization. You MUST call LF_Shutdown explicitly before unloading your library to avoid resource leaks."
- **正确做法**：
  ```pascal
  // DLL 出口函数中
  procedure DllUnload; stdcall;
  begin
    LF_Shutdown;   // 必须显式调用
  end;
  ```
- **验证清单**：
  - [ ] DLL 有显式的卸载钩子调用 `LF_Shutdown`
  - [ ] 宿主程序卸载 DLL 后无崩溃
- **相关坑**：LF-CLEAN-001

---

## 7.10 线程模型（LF-THREAD-*）

### LF-THREAD-001：所有导出函数线程安全

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
- **影响版本**：所有版本
- **说明**：
  `lingofuse_import.pas`：
  > "All functions exported by this unit are **fully thread-safe**. You may call them from any thread concurrently without external locking."
- **例外**：
  - **同一个数据句柄的并发写**必须外部同步
  - 状态日志辅助（`LF_GetStatus`）返回静态缓冲，非完全线程安全
- **验证清单**：
  - [ ] 跨线程调用无需外部锁
  - [ ] 同一句柄的写操作有外部同步
- **相关坑**：LF-CB-004

### LF-THREAD-002：数据句柄的并发写不安全

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
- **影响版本**：所有版本
- **触发条件**：多线程并发写同一个 `TDataHnd`
- **症状**：数据错乱、位置指针竞争
- **根因**：
  `lingofuse_import.pas`：
  > "for a given data handle (TDataHnd), concurrent writes must be serialised by the caller; concurrent reads are safe because the buffer operations are atomic with respect to position updates"
- **正确做法**：
  - 每个线程使用独立的句柄
  - 或外部加锁保护共享句柄的写操作
- **验证清单**：
  - [ ] 跨线程共享句柄的写操作有临界区保护
  - [ ] 或每线程独立句柄
- **相关坑**：LF-THREAD-001

---

## 7.11 类型与编译（LF-TYPE-*）

### LF-TYPE-001：FPC 下 `var` 和 `out` 编码为同一引用类别

- **证据等级**：🟡 仅文档转录（来自 `LingoFuse_LLM_Pitfalls_For_AI.md` P1-5）
- **影响版本**：FPC 3.0+
- **触发条件**：定义两个仅 `var`/`out` 区别的重载函数
- **症状**：
  ```
  Error: (3029) function header doesn't match the previous declaration
  ```
- **根因**：Free Pascal 在重载决议时，`var` 和 `out` 编码为**相同的引用传递类别**。
- **最小复现**：
  ```pascal
  // ❌ 这两个被 FPC 视为同一签名
  function Generate(..., var ASessionId: string; out AError: string): boolean;
  function Generate(..., out ASessionId, AError: string): boolean;
  ```
- **修复 diff**：
  ```diff
  - function Generate(..., var ASessionId: string; out AError: string): boolean;
  - function Generate(..., out ASessionId, AError: string): boolean;
  + // ✅ 合并为一个
  + function Generate(const AContent, APrompt: string;
  +                   var ASessionId: string;
  +                   out AError: string): boolean;
  + // ✅ 或另取名字
  + function GenerateCurrent(const AContent, APrompt: string;
  +                          out AError: string): boolean;
  ```
- **验证清单**：
  - [ ] FPC 编译无 3029 错误
  - [ ] Delphi 编译也通过
- **相关坑**：LF-TYPE-002

### LF-TYPE-002：跨语言接口只能用基础类型

- **证据等级**：🟢 已核实源码（`pascal_code_mcp_rule.md` 类型白名单）
- **影响版本**：所有版本
- **触发条件**：用 `Variant`、数组、记录、枚举等作为 API 参数
- **症状**：
  - 代码生成器**静默跳过**含这类参数的声明
  - 或跨语言传输时数据丢失
- **根因**：
  `pascal_code_mcp_rule.md` §3.3 明确禁止：
  - `Boolean`、`Variant`、`array of X`、记录、类、接口、枚举、集合、泛型、函数指针、指针
- **正确做法**：
  - 只用基础类型：整数族、浮点族、字符串族
  - 复杂结构用 **JSON 字符串**传输
- **验证清单**：
  - [ ] 所有参数类型在 `pascal_code_mcp_rule.md` §3 白名单内
  - [ ] 复杂结构用 JSON 字符串包装
- **相关坑**：LF-TYPE-001、LF-XLANG-003、LF-JSON-002

---

## 7.12 跨语言数据交换（LF-XLANG-*）

### LF-XLANG-001：字符串必须遵循 #0 终止符约定

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_WriteString` / `LF_ReadString` 实现）
- **影响版本**：所有版本
- **触发条件**：跨语言传输字符串或 JSON
- **症状**：
  - Pascal 端写入的 JSON 尾部有 #0，Python/浏览器解析失败
  - Python 端发送的纯 JSON，Pascal 端 `LF_ReadString` 读到缓冲区末尾
- **根因**：
  - `LF_WriteString`：**总是追加 #0**
  - `LF_ReadString`：**扫描到 #0 停止**；若无 #0，读到缓冲区末尾（容错模式）
- **正确做法**：
  - **统一约定**：字符串以 #0 结尾
  - **桥接层**（如 `bridge.py`）：
    - 接收 HTTP 请求时，在 body 后追加 #0
    - 返回 HTTP 响应前，剥离尾部 #0
- **验证清单**：
  - [ ] 桥接层实现了双向 #0 处理
  - [ ] 自定义客户端遵循同样约定
  - [ ] 跨语言测试：Pascal ↔ Python 双向传输 JSON 无问题
- **相关坑**：LF-DATA-004、LF-DATA-005、LF-JSON-001

### LF-XLANG-002：UTF-8 全程贯通，不经 `string` 中转

- **证据等级**：🟡 仅文档转录（来自 `LingoFuse_LLM_Pitfalls_For_AI.md` P2-1）
- **影响版本**：所有版本
- **触发条件**：中文 `content` 经 Pascal `string` 中转
- **症状**：
  - 中文变成 `????` 或乱码
  - 英文完全正常
- **根因**：
  - FPC 里 `string` 默认可能是 `AnsiString`（取决于编译指令）
  - `TUPascalString`（Unicode）赋给 `string` 时可能被字符集转换
  - 中文可能在转换中被替换为 `?`
- **正确做法**：
  ```pascal
  // ✅ 全程走 TBytes
  var
    reqBytes, respBytes: TBytes;
  begin
    reqBytes := joReq.ToBytes;          // 直接拿 UTF-8 bytes
    LF_WriteStringBytes(hnd, reqBytes);

    LF_ReadStringBytes(res, respBytes); // 读取 bytes
    joResp.Parae(respBytes);            // 直接解析 bytes
  end;
  ```
- **验证清单**：
  - [ ] 跨语言传输中文完整保留
  - [ ] 代码中不出现中文经 `string` 中转的路径
  - [ ] 或用 `{$CODEPAGE UTF8}` 确保 `string` 是 UTF-8
- **相关坑**：LF-XLANG-003、LF-TYPE-002、LF-JSON-002

### LF-XLANG-003：字节序统一为小端

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_WriteInt32` 等实现）
- **影响版本**：所有版本
- **触发条件**：跨平台（如 x86 ↔ 大端架构）传输整数
- **症状**：跨端读取的整数数值错误
- **根因**：
  `lingofuse_import.pas`：
  > "所有写入函数以**小端字节序**编码。"
  
  所有 `LF_WriteInt32` 等实现用 `Move` 直接写内存（**依赖主机字节序**），但协议约定统一按小端。
- **正确做法**：
  - 跨平台时，所有参与方按小端解析
  - 大部分现代平台（x86/ARM/x86_64/aarch64）都是小端，通常无问题
  - **若跨大端平台**（如 MIPS 大端、PowerPC 大端）：需要显式字节序转换
- **验证清单**：
  - [ ] 跨平台测试：x86_64 ↔ aarch64 双向传输整数
  - [ ] 若涉及大端平台，有显式转换
- **相关坑**：LF-XLANG-002

---

## 7.13 JSON 使用层（LF-JSON-*）

> **本节来源**：从 `LingoFuse_LLM_Pitfalls_For_AI.md` §12（P10 系列）完整合并。
>
> **定位**：所有使用 `Z.Json` 单元（`TZ_JsonObject` / `TZ_JsonArray` / `TZ_JsonString`）的场景，尤其是**跨语言、结构化输出（Structured Output）、LLM 交互**等需要组装/解析 JSON 的场景。
>
> **为什么单列一个子系统**：JSON 踩坑的根因和 LF-* 层的踩坑**不同源**——它源于 `TZ_JsonObject` 的**树形设计**和**跨编译器字符编码差异**。但使用时**经常和 LingoFuse 一起出现**，所以在这里单独列出。

### LF-JSON-001：`TZ_JsonObject` 是树，Parse 类方法只能在 root 上调用

- **证据等级**：🟢 已核实源码（`Z.Json.md` §0 / §4.0 / §4.9 + `LingoFuse_LLM_Pitfalls_For_AI.md` P10-1）
- **影响版本**：v3.11+（`Z.Json` 单元引入该约束；`llm_client_v3.pas` v3.11 修复）
- **触发条件**：
  - 对 `TZ_JsonObject` 的**子对象 / 孙对象**调用 `Parae` / `Assign` / `LoadFromStream` / `ParseText` 中的任何一个
  - 典型场景：向一个已有 `joReq.O['options']` 的子节点注入 JSON 字符串
- **症状**（多种表现，取决于崩溃时机）：
  - **A. 随机崩溃 / 访问冲突**（AV / 段错误）
  - **B. 字段静默丢失**——例如 `options.response_format` 从 JSON 中消失
  - **C. `schema` 字段变成 `null`**
  - **D. 延迟崩溃**——`ToBytes` / 序列化时才崩
  - **E. "看着正常"**——某些编译/运行配置下不崩，但 JSON 结果不对
- **根因**：
  - `TZ_JsonObject` 是**树形容器**，不是扁平 map
  - 子对象的 `FInstance` 是**指向父对象底层 `TJSONObject` 树中某个节点的指针**
  - `Parae` / `Assign` / `LoadFromStream` / `ParseText` 内部执行 `DisposeObjectAndNil(FInstance)` 后创建**全新对象**
  - 导致：
    - 父对象底层树中留下**悬空指针**
    - 新 `FInstance` **没有挂接回父树**
  - `Z.Json.md` §4.0 的通用规则表：
    | 操作 | 允许对象 | 禁止对象 |
    |------|---------|---------|
    | `Parae(TBytes)` | ✅ root | ❌ child / grandchild |
    | `Assign(source)` | ✅ root | ❌ child |
    | `LoadFromStream` | ✅ root | ❌ child |
    | `ParseText` | ✅ root | ❌ child |
    | `S[...]` / `I[...]` / `B[...]` 读写 | ✅ 任意 | — |
    | `O[...]` / `A[...]` 写字段 | ✅ 任意 | — |
- **最小复现**（来自 `LingoFuse_LLM_Pitfalls_For_AI.md` P10-1）：
  ```pascal
  // ❌ 错误：对孙对象调用 Parae
  joJsonSchema := joRoot.O['json_schema'];
  joJsonSchema.O['schema'].Parae(ASchemaJsonBytes);   // 破坏 joRoot 的底层树
  AResponseFormatJsonBytes := joRoot.ToBytes;         // 崩溃或丢字段
  ```
- **修复 diff**（P10-1 官方配方：独立 root 解析 → 取紧凑 JSON → Unicode 空间拼接 → 最后 `.Bytes`）：

  ```diff
  - (* ❌ 错误：对子对象调用 ParseText *)
  - joJsonSchema := joReq.O['options'].O['response_format'];
  - joJsonSchema.O['schema'].ParseText(ASchemaJson);
  - reqBytes := joReq.ToBytes;
  + (* ✅ 正确：三步走 *)
  + (* Step 1: 独立 root 对象解析 *)
  + joSchema := TZ_JsonObject.Create;
  + try
  +   if not joSchema.ParseText(ASchemaJson) then
  +   begin
  +     AError := 'Schema JSON is not valid';
  +     Exit;
  +   end;
  +   schemaJson := joSchema.ToJSONString(False);   (* 紧凑 JSON *)
  + finally
  +   DisposeObject(joSchema);
  + end;
  + (* Step 2: 用 TZ_JsonObject 生成 name/strict 片段 *)
  + joNameStrict := TZ_JsonObject.Create;
  + try
  +   joNameStrict.S['name'] := ASchemaName;
  +   joNameStrict.B['strict'] := AStrict;
  +   nameStrictJson := joNameStrict.ToJSONString(False);
  + finally
  +   DisposeObject(joNameStrict);
  + end;
  + (* Step 3: Unicode 空间拼接 *)
  + reqJson := joReq.ToJSONString(False);            (* TZ_JsonString *)
  + tmpReq := reqJson.Text;
  + SetLength(tmpReq, Length(tmpReq) - 1);            (* 去掉尾 '}' *)
  + reqJson.Text := tmpReq +
  +   ',"options":{"response_format":{' +
  +   '"type":"json_schema","json_schema":{' +
  +   nameStrictJson.Text + ',' +
  +   '"schema":' + schemaJson.Text +
  +   '}}}';
  + (* Step 4: 最后一步 .Bytes 转 UTF-8 *)
  + reqBytes := reqJson.Bytes;
  ```

- **审计方法**（提交前自查）：
  ```
  grep "<obj>.Parae("           → 左侧必须是 ROOT（Parent = nil）
  grep "<obj>.Assign("          → 左侧必须是 ROOT
  grep "<obj>.LoadFromStream("  → 左侧必须是 ROOT
  grep "<obj>.ParseText("       → 左侧必须是 ROOT
  ```
- **验证清单**：
  - [ ] 所有 `Parae` / `Assign` / `LoadFromStream` / `ParseText` 的调用对象都是 root
  - [ ] 使用「独立 root 解析 → 字符串拼接」范式
  - [ ] `ToBytes` 前后不崩溃
  - [ ] JSON 结构完整（用 JSON 校验器验证）
  - [ ] 长时间运行（1 小时以上）无访问冲突
- **相关坑**：LF-JSON-002、LF-JSON-003、LF-XLANG-002

### LF-JSON-002：JSON 组装必须停在 Unicode 空间，不能经 `string` 中转

- **证据等级**：🟢 已核实源码（`Z.Json.md` §1.1 + `LingoFuse_LLM_Pitfalls_For_AI.md` P10-2）
- **影响版本**：v3.11+
- **触发条件**：
  - 把 `TZ_JsonString` 的 `.Text`（`USystemString`）赋给 `string`（FPC 下可能是 `AnsiString`）变量
  - 再对该 `string` 变量做拼接、再赋给另一个 JSON 对象
- **症状**：
  - **只在 Windows + FPC 下出错**，Linux / macOS 下正常
  - **只在 `DefaultSystemCodePage ≠ CP_UTF8` 时出错**（如中文 Windows 的 CP936）
  - Schema 里的 **emoji、韩文、生僻字**到达服务端时变成 `?` 或乱码
  - 纯 ASCII 内容完全正常——**这是最迷惑的地方**
- **根因**：
  - `TZ_JsonString.Text` 返回 `USystemString`（FPC 下是 `UnicodeString`）
  - 赋给 `string`（FPC Delphi mode 下是 `AnsiString`）时，走**系统代码页转换**
  - 在中文 Windows（CP936）下，emoji / 韩文等无法表示的字符 → 变成 `?`
  - `Z.Json.md` §1.1 的通用规则：
    | 用途 | 推荐类型 | 避免类型 |
    |------|---------|---------|
    | JSON 中间容器 | `TZ_JsonString` | `string` |
    | 短 ASCII 字段 | `string` 可接受 | — |
    | 面向 UI 的显示字符串 | `string` 可接受 | — |
    | 字节流 | `TBytes` | — |
- **最小复现**（来自 `LingoFuse_LLM_Pitfalls_For_AI.md` P10-2）：
  ```pascal
  (* ❌ 错误：中间变量用 string（AnsiString） *)
  var
    schemaJson, reqJsonStr: string;
  begin
    schemaJson := joSchema.ToJSONString(False).Text;   (* 非 ASCII 字符丢失 *)
    reqJsonStr := '...' + schemaJson + '...';
    reqBytes   := TEncoding.UTF8.GetBytes(reqJsonStr); (* 再走一遍系统代码页 *)
  end;
  ```
- **修复 diff**：
  ```diff
  - var
  -   schemaJson, reqJsonStr: string;
  - begin
  -   schemaJson := joSchema.ToJSONString(False).Text;
  -   reqJsonStr := '...' + schemaJson + '...';
  -   reqBytes   := TEncoding.UTF8.GetBytes(reqJsonStr);
  - end;
  + var
  +   schemaJson, reqJson: TZ_JsonString;
  +   tmpReq: USystemString;
  + begin
  +   schemaJson := joSchema.ToJSONString(False);   (* 保持 TZ_JsonString *)
  +   reqJson    := joReq.ToJSONString(False);
  +
  +   tmpReq := reqJson.Text;                       (* 在 Unicode 空间拼接 *)
  +   SetLength(tmpReq, Length(tmpReq) - 1);
  +   reqJson.Text := tmpReq +
  +     ',"options":{"response_format":' + schemaJson.Text + '}}';
  +
  +   reqBytes := reqJson.Bytes;                    (* 最后一步转 UTF-8 *)
  + end;
  ```
- **验证清单**：
  - [ ] 所有 JSON 组装的中间变量声明为 `TZ_JsonString`
  - [ ] 代码中不出现 `...ToJSONString(...).Text` 后赋给 `string` 的位置
  - [ ] `.Bytes` 只在最后一步调用
  - [ ] 跨语言测试：包含 emoji / 中文 / 韩文的 JSON 完整保留
- **相关坑**：LF-JSON-001、LF-XLANG-002、LF-TYPE-002

### LF-JSON-003：GBK / Latin-1 回退必须用 `USystemString`，不能用 `AnsiString`

- **证据等级**：🟢 已核实源码（`Z.Json.md` §7.19 + `LingoFuse_LLM_Pitfalls_For_AI.md` P10-3）
- **影响版本**：v3.11+
- **触发条件**：
  - 处理非 UTF-8、非 GBK 编码的文本文件（如 Latin-1、Shift-JIS）
  - 走"编码检测失败 → Latin-1 兜底"的分支
  - 目标变量声明为 `string`（FPC 下是 `AnsiString`）
- **症状**：
  - 输出乱码
  - 或只显示前一半内容
- **根因**：
  - UTF-8 和 GBK 都解码失败后走"Latin-1 兜底"
  - 原实现用 `string`（`AnsiString`）配合 `SetLength` 和 `Move`
  - **字节单位与 UTF-16 容器混用**——`SetLength` 是按字符数（UTF-16 code unit）分配，但 `Move` 按字节拷贝
- **最小复现**：
  ```pascal
  (* ❌ 错误：目标用 string（AnsiString），单位混乱 *)
  var
    Decoded: string;
    i: integer;
  begin
    try
      Decoded := TEncoding.UTF8.GetString(rawBytes);
    except
      try
        Decoded := TEncoding.GetEncoding(936).GetString(rawBytes);
      except
        SetLength(Decoded, Length(rawBytes));      (* ❌ 单位混乱 *)
        for i := 0 to Length(rawBytes) - 1 do
          Decoded[i + 1] := AnsiChar(rawBytes[i]); (* ❌ 高位丢失 *)
      end;
    end;
  end;
  ```
- **修复 diff**：
  ```diff
  - var
  -   Decoded: string;
  -   i: integer;
  - begin
  -   ...
  -       SetLength(Decoded, Length(rawBytes));
  -       for i := 0 to Length(rawBytes) - 1 do
  -         Decoded[i + 1] := AnsiChar(rawBytes[i]);
  - end;
  + var
  +   Decoded: USystemString;                      (* ✅ Unicode 空间 *)
  +   i: integer;
  + begin
  +   ...
  +       SetLength(Decoded, Length(rawBytes));
  +       for i := 0 to Length(rawBytes) - 1 do
  +         Decoded[i + 1] := WideChar(rawBytes[i]); (* ✅ 逐字节映射为 WideChar *)
  + end;
  ```
- **验证清单**：
  - [ ] GBK / Latin-1 回退分支的目标变量声明为 `USystemString`
  - [ ] 逐字节映射用 `WideChar(...)` 而非 `AnsiChar(...)`
  - [ ] 用 Latin-1、Shift-JIS、CP1252 编码的测试文件验证输出
- **相关坑**：LF-JSON-002、LF-XLANG-002

---

## 7.14 模拟主线程与 C4 进度循环（LF-MAIN-*）

> **v3.0 新增子系统**。模拟主线程是 LingoFuse 框架的"心脏"，它驱动网络 I/O、超时处理、数据句柄回收、序列化通知线程池等所有后台任务。理解它是理解整个框架的关键。

### LF-MAIN-001：模拟主线程每进程只能启动一次

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` `LF_PrepareDone` 实现 + `Z.LingoFuse.md` §2.6）
- **影响版本**：所有版本
- **触发条件**：同一进程内多次调用 `LF_PrepareDone`
- **症状**：
  - 第一次返回 1（成功）
  - 第二次及以后立即返回 0（不重新启动）
- **根因**：
  ```pascal
  function LF_PrepareDone: Integer;
  begin
    Result := 0;
    if Simulated_Main_Thread_Running then
        exit;   // 已运行 → 立即返回 0
    ...
  end;
  ```
  这是**有意的保护**——防止重复启动模拟主线程导致双份 C4 进度循环、双份网络监听、双份数据句柄扫描。
- **触发场景**：
  - 多个模块（如 `Server.start()` 和 `language_middleware._connect()`）各自尝试启动
  - 单例模式下重复初始化
- **正确做法**：
  - **整个进程只调用一次 `LF_PrepareDone`**
  - 若需要重新初始化：`LF_Shutdown` → `LF_ResetPrepare` → `LF_PrepareDone`
- **验证清单**：
  - [ ] 全代码库 grep `LF_PrepareDone`，确认只有一处启动点
  - [ ] 多处调用点有明确的"先到先启动"约定
- **相关坑**：LF-NET-003、LF-CLEAN-002

### LF-MAIN-002：模拟主线程驱动的所有后台任务

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` `Simulated_Main_Thread` 实现）
- **影响版本**：所有版本
- **背景**：模拟主线程的 `while` 循环里做了以下事：
  ```pascal
  while Simulated_Main_Thread_Running do
    begin
      C40Progress(if_(LF_RunningCount.V > 0, 0, 10));   // ① C4 网络进度
      try
          LF_DataPool.Progress();                        // ② 数据句柄回收扫描
      except
      end;
    end;
  ```
  **只有这两个**——没有 `LF_SyncTool.Check_Synchronize`！
- **重要推论**：
  - **同步回调（`RegisterSyncCall_M` / `RegisterSyncNotify_M`）不是由模拟主线程直接驱动的**，而是通过 C4 的 `C40Progress` 内部的用户同步钩子（`OnCheckThreadSynchronize`）间接触发的。
  - 如果自定义主循环，需要**同时**：
    1. 定期调用 `LF_Sync`（处理同步回调）
    2. 定期调用 `C40Progress`（处理网络）
- **主线程负责的任务清单**：
  | 任务 | 驱动者 |
  |------|--------|
  | C4 网络收发 | `C40Progress` |
  | 定时器回调（`Subscribe_Timer_*`）| `C40Progress` |
  | 数据句柄空闲回收 | `LF_DataPool.Progress` |
  | 数据句柄扫描间隔（5 秒）| `LF_DataPool.Progress` 内部判断 |
  | 序列化通知线程管理 | 独立 TCompute 工作线程 |
  | 同步回调执行 | C4 同步钩子 |
- **验证清单**：
  - [ ] 自定义主循环必须同时调用 `LF_Sync` 和 `C40Progress`
  - [ ] 使用 `LF_PrepareDone` 时无需手动驱动
- **相关坑**：LF-CB-005、LF-MAIN-001

### LF-MAIN-003：`LF_ExitMainThread` 与资源释放的关系

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Export.pas` `LF_ExitMainThread` 实现 + `Simulated_Main_Thread` 退出代码）
- **影响版本**：所有版本
- **触发条件**：调用 `LF_ExitMainThread` 后
- **语义**：
  ```pascal
  procedure LF_ExitMainThread;
  begin
    Simulated_Main_Thread_Running := False;
    while Simulator_Main_Thread_Activted do
        Boot_Thread_Sync_Tool.Check_Synchronize(10);
  end;
  ```
  - 设置标志 → 主循环退出
  - **等待主线程完全退出**（`Simulator_Main_Thread_Activted` 变 False）
- **主线程退出前的清理**（`Simulated_Main_Thread` 末尾）：
  1. `C40Clean`（清理 C4 状态）
  2. `LF_Notify_Sequence_Thread_Pool.Stop`（停止所有顺序通知线程）
  3. `LF_DataPool.Free_All_Hnd`（释放所有数据句柄）
  4. `LF_DataMemory.Free_All_PLF_Data_Memory`（清空二级内存池）
  5. 打印 `'LingoFuse Main Thread Exit'`
  6. `Check_Soft_Thread_Synchronize(0)`（处理残留同步）
- **重要推论**：
  - `LF_ExitMainThread` 会**清空所有数据句柄**——包括你的 `LF_CreateData_Permanent` 创建的永久句柄！
  - `Free_All_Hnd` 内部**跳过 `calling___ > 0` 的句柄**，但如果回调正在进行，`LF_ExitMainThread` 会阻塞直到回调完成。
- **正确做法**：
  - 按 LF-CLEAN-001 的顺序：`ExitMainThread` → `FreeApp` → `Shutdown`
  - **不要在 `LF_ExitMainThread` 之后使用任何数据句柄**
- **验证清单**：
  - [ ] `LF_ExitMainThread` 后不再持有数据句柄
  - [ ] 清理顺序正确
- **相关坑**：LF-CLEAN-001、LF-MAIN-001

### LF-MAIN-004：`LF_DataPool.Progress` 的三路分支语义

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_DataPool.Progress` 实现）
- **影响版本**：v3.09+
- **完整逻辑**：
  ```
  每 5 秒（Last_Progress_Time__ 判断）扫描一次：
  for each handle in LF_DataPool:
    if handle.updated___ or handle.calling___ > 0:
       handle.time___ := now
       handle.updated___ := False
    else if handle.deleted___:
       加入"用户主动释放"列表 L
       标记回收（Push_To_Recycle_Pool）
    else if now - handle.time___ > 10 分钟:
       加入"超时释放"列表 timeout_data
       标记回收（Push_To_Recycle_Pool）

  释放 L 中所有句柄（Free_Data___）
  如果 timeout_data 非空：
     打印 hint 日志（句柄数、若少于 3 条则逐条打印 Data_Info）
     逐条 Free_Data___（推回 LF_DataMemory）
  ```
- **关键观察**：
  - **三路判断顺序不能打乱**——`updated/calling` 优先于 `deleted` 优先于 `timeout`
  - `updated/calling` 的句柄**只刷新时间戳，不释放**
  - 释放发生在池外（释放锁之后），避免用户回调死锁
- **用户需要知道的**：
  - `LF_FreeData` **不立即释放**（自动回收句柄），只是标记 `deleted___`
  - 实际释放在下一次扫描——**最多延迟 5 秒**
  - 想立即释放 → 用 `LF_CreateData_Permanent`
- **验证清单**：
  - [ ] 不依赖 `LF_FreeData` 立即释放内存
  - [ ] 需要立即释放时用 `LF_CreateData_Permanent`
- **相关坑**：LF-DATA-001、LF-DATA-007、LF-DATA-008

---

## 7.15 内存与对象生命周期详解（LF-MEM-*）

> **v3.0 新增子系统**。这一节系统梳理 LingoFuse 的内存管理机制。

### LF-MEM-001：三层内存池架构

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` 中 `TLF_DataMemory`、`TLF_DataPool`、`TLF_App_Pool` 实现）
- **影响版本**：v3.09+
- **三层结构**：

  ```mermaid
  flowchart TD
      L1["第 1 层：用户视角<br/>TDataHnd 句柄"]
      L2["第 2 层：数据句柄池<br/>TLF_DataPool<br/>（自动回收扫描）"]
      L3["第 3 层：二级内存池<br/>TLF_DataMemory<br/>（record 复用）"]

      L1 -->|"LF_CreateData"| L2
      L2 -->|"LF_FreeData<br/>标记 deleted___"| L3
      L2 -.->|"10 分钟超时"| L3
      L3 -->|"Get_New_PLF_Data"| L2
      L3 -->|"Free_All_PLF_Data_Memory<br/>单元终结"| X["真正 Dispose"]

      style L1 fill:#e8f4ff,stroke:#444
      style L2 fill:#fff7e6,stroke:#444
      style L3 fill:#e8ffe8,stroke:#444
  ```

- **每层的职责**：
  | 层 | 名称 | 职责 |
  |:--:|------|------|
  | 1 | 用户句柄 | 用户持有的 `TDataHnd`，不透明的指针 |
  | 2 | 数据句柄池 | 跟踪所有活跃句柄；扫描并回收空闲/删除的 |
  | 3 | 二级内存池 | 缓存已回收的 `TLF_Data` record，减少 `New`/`Dispose` |
- **对用户的影响**：
  - **完全透明**——你只需用 `LF_CreateData` / `LF_FreeData`。
  - 三层最终都会在单元终结时释放。
  - 生命周期内，池的大小是**受峰值句柄数限制**的，不会无界增长。
- **验证清单**：
  - [ ] 不需要额外操作
  - [ ] 长期运行内存峰值稳定
- **相关坑**：LF-DATA-006、LF-MEM-002

### LF-MEM-002：`TLF_Data` 是 record，不是 class

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_Data = record` 定义）
- **影响版本**：v3.09+
- **关键差异**：

  | 维度 | record | class |
  |------|:------:|:-----:|
  | 分配方式 | `New` / `Dispose` | `Create` / `Free` |
  | 内存位置 | 堆（由 `New` 分配） | 堆 |
  | 拷贝语义 | 值拷贝（默认） | 引用拷贝 |
  | 是否可继承 | 否 | 是 |
  | 指针类型 | `PLF_Data = ^TLF_Data` | — |

- **为什么这样设计**：
  - `TLF_Data` 的字段较少且固定，用 record 可以减少一层指针跳转
  - `TLF_DataMemory` 二级内存池直接复用 record 的内存块，避免反复 `New`/`Dispose`
- **对用户的影响**：
  - **完全透明**——C ABI 层用 `TDataHnd___ = Pointer` 抽象，用户看不到 record 细节
  - **不要直接操作 `TLF_Data` 内部字段**——即使你在 Pascal 层能看到
- **验证清单**：
  - [ ] 不直接引用 `TLF_Data` 类型（除 `lingofuse_import` 外）
  - [ ] 用 `LF_*` 函数访问数据
- **相关坑**：LF-MEM-001

### LF-MEM-003：`TLF_App` 的两阶段析构

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_App.FakeFree` / `Destroy` + `Z.LingoFuse_Export.pas` `LF_FreeApp` 实现）
- **影响版本**：所有版本
- **两阶段**：

  ```mermaid
  stateDiagram-v2
      [*] --> Active: TLF_App.Create
      Active --> Detached: LF_FreeApp
      Note right of Detached: 已从客户端解绑<br/>顺序通知线程已停止<br/>定时器已移除<br/>仍在 LF_App_Pool
      Detached --> Destroyed: LF_Shutdown / LF_App_Pool.Clear
      Destroyed --> [*]: DisposeObjectAndNil
  ```

- **两个阶段的职责**：
  | 阶段 | 触发者 | 做的事 |
  |:----:|:------:|--------|
  | 1 | `LF_FreeApp` | 解绑客户端 + 停顺序通知线程 + 移除定时器 |
  | 2 | `LF_Shutdown` | `LF_App_Pool.Clear` → `DisposeObjectAndNil(Data)` |
- **为什么这样设计**：
  - 防止网络广播仍在引用 App 数据时出现悬空指针
  - 提供统一的释放点（`LF_Shutdown`）
- **对用户的影响**：
  - **`LF_FreeApp` 后句柄失效**——不要再注册 API 或调用
  - 想彻底回收内存 → `LF_Shutdown` 后重启
- **验证清单**：
  - [ ] `LF_FreeApp` 后不再使用句柄
  - [ ] 长生命周期服务用 `LF_Shutdown` 清理
- **相关坑**：LF-APP-002、LF-CLEAN-001

### LF-MEM-004：`TLF_Notify_Sequence_Thread` 的延迟释放

- **证据等级**：🟢 已核实源码（`Z.LingoFuse_Core.pas` `TLF_Notify_Sequence_Thread.Do_Run_Th` 末尾）
- **影响版本**：v3.09+
- **机制**：顺序通知线程退出时，**不立即 `Free`**，而是 `DelayFreeObj(5.0, self)`：
  ```pascal
  // Do_Run_Th 末尾
  if (Internal_Queue_Data___ <> nil) and (Internal_Queue_Pool___ <> nil) then
    begin
      Internal_Queue_Pool___.Lock;
      try
        Internal_Queue_Pool___.Remove(Internal_Queue_Data___);
      finally
        Internal_Queue_Pool___.UnLock;
      end;
    end;

  // Schedule self-release after a 5-second grace period so that TCompute
  // can safely write back the IsRunning / IsExit flags before the object
  // is destroyed.
  DelayFreeObj(5.0, self);
  ```
- **为什么需要延迟**：
  - `TCompute` 线程在主函数返回后，还会写 `IsRunning := False` 和 `IsExit := True`
  - 如果 `Do_Run_Th` 立即 `Free(self)` → 写入已释放内存 → UAF
  - `DelayFreeObj(5.0, self)` 给 TCompute 5 秒窗口完成所有写操作
- **这是一个修复**：v4 版本中曾是 `DisposeObject(self)`（立即释放），导致 UAF。v3.09 改为 `DelayFreeObj`。
- **对用户的影响**：
  - **完全透明**
  - 但意味着**顺序通知线程的清理有最多 5 秒延迟**
- **验证清单**：
  - [ ] 不依赖顺序通知线程立即释放
  - [ ] 高频创建/销毁 App 时观察线程/内存是否稳定
- **相关坑**：LF-SEQ-001、LF-MEM-003

### LF-MEM-005：内存泄漏排查清单

- **证据等级**：🟢 已核实源码（综合自 `Z.LingoFuse_Core.pas` + `Z.LingoFuse_Export.pas`）
- **影响版本**：所有版本
- **常见泄漏源**（按频率排序）：

  | # | 泄漏源 | 检查方法 | 修复 |
  |:-:|--------|---------|------|
  | 1 | 未 `LF_FreeData` 数据句柄 | 长期运行内存增长 | 用 `try..finally` 保证释放 |
  | 2 | 未 `LF_FreeApp` 应用句柄 | `LF_App_Pool` 增长 | 按清理顺序释放 |
  | 3 | `LF_CreateData_Permanent` 未释放 | 显式查找 | 显式 `LF_FreeData` |
  | 4 | DLL 未调用 `LF_Shutdown` | DLL 卸载后仍占内存 | 加卸载钩子 |
  | 5 | 顺序通知线程未退出 | 检查 TCompute 线程数 | 空闲 5 分钟后自动退出，无需处理 |
  | 6 | 句柄池中的 record 未释放 | 检查 `LF_DataMemory` 池大小 | 单元终结时自动释放，无需处理 |
  | 7 | 回调闭包捕获了大对象 | 检查匿名函数 | 使用弱引用或显式清理 |

- **排查工具**：
  - `LF_GetStatus` / `LF_GetStatusCount`：查看内部日志
  - 定期打印 `LF_CheckMainThread` / `LF_GetStatusCount` 监控运行时状态
  - 内存分析工具（如 FastMM4 for Delphi，heaptrc for FPC）
- **验证清单**：
  - [ ] 长期运行（24 小时）内存稳定
  - [ ] 压测后释放所有句柄，内存回到基线
  - [ ] DLL 卸载后宿主程序无残留线程
- **相关坑**：LF-DATA-001、LF-APP-002、LF-CLEAN-003

---

# 第 8–11 章：对比、附录

## 8. 与 Python 绑定的范式对比

| 功能 | Pascal | Python | 说明 |
|------|--------|--------|------|
| 创建数据句柄 | `LF_CreateDataEx('api')` | `DataHandle('api')` | Python 构造器自动管理释放 |
| 创建永久句柄 | `LF_CreateData_PermanentEx('api')` | 无对应 | Python 层未暴露（截至 v3.09） |
| 注册 Call | `LF_RegisterCall_M(app, 'add', ..., OnCall)` | `@app.expose('add')` | Python 装饰器自动适配 |
| 注册 Notify | `LF_RegisterNotify_M(...)` | `@app.expose('add', notify=True)` | 同上 |
| 生成唯一名称 | `LF_Generate_AppNameEx` | `generate_app_name()` | 均需在 PrepareDone 后调用 |
| 绑定应用 | `LF_BindApp(app)` | `app.bind()` | 等价 |
| Overlap_Connection | `LF_SetOptionEx('Overlap_Connection', 'True')` | `set_option('Overlap_Connection', 'True')` | 等价 |
| 等待就绪 | `Wait_Connection_ReadyOk` 选项 | `set_option('Wait_Connection_ReadyOk', 'True')` | 等价 |
| 序列化通知 | `LF_Sequenced_NotifyEx` | `LF_Sequenced_Notify` | 等价 |
| **网络事件** | `LF_Set_Network_Event(...)` | 无对应 | Python 层未暴露（截至 v3.09） |
| **同步驱动** | `LF_Sync`（自定义主循环） | 无对应 | Python 用 `LF_PrepareDone` 的进度循环 |
| 错误处理 | 检查返回值 | 异常（`RegistrationError`, `ConnectionError`） | Python 更激进 |
| 资源清理 | 显式 `LF_FreeData`, `LF_FreeApp`, `LF_Shutdown` | `with` 语句或显式 `free()` | 均推荐显式 |

## 9. 附录 A – 函数速查表

| 分类 | 函数名 | 简要说明 |
|------|--------|----------|
| **数据句柄** | `LF_CreateData` / `LF_FreeData` | 创建 / 销毁句柄（自动回收） |
| | `LF_CreateData_Permanent` | 创建永久句柄（不自动回收） |
| | `LF_GetBuffer` / `LF_WriteBuffer` / `LF_ReadBuffer` | 缓冲区访问 |
| | `LF_GetPos` / `LF_SetPos` / `LF_GetSize` / `LF_SetSize` | 位置与大小 |
| | `LF_WriteInt32` / `LF_ReadInt32` 等 | 原子类型 |
| | `LF_WriteString` / `LF_ReadString` | 字符串（#0 结尾） |
| | `LF_WriteStringBytes` / `LF_ReadStringBytes` | 原始字节 |
| **应用** | `LF_CreateApp` / `LF_FreeApp` | 创建 / 分离应用 |
| | `LF_Generate_AppName` / `LF_Get_AppName` | 名称（5 秒有效期） |
| | `LF_BindApp` | 绑定到空闲客户端 |
| **注册** | `LF_RegisterCall` / `LF_RegisterNotify` | 注册 cdecl 回调 |
| | `LF_RegisterCall_M` / `LF_RegisterSyncCall_M` | 对象方法回调 |
| | `LF_Unregister` | 注销 API |
| **本地调用** | `LF_LocalCall` / `LF_LocalNotify` | 本地执行 |
| **网络准备** | `LF_ResetPrepare` | 清空准备队列 |
| | `LF_PrepareService` / `LF_PrepareClient` | 准备服务 / 客户端 |
| | `LF_PrepareDone` / `LF_ExitMainThread` | 启动 / 停止 |
| **远程调用** | `LF_Call` / `LF_Notify` / `LF_Sequenced_Notify` | 远程调用 |
| **选项与状态** | `LF_SetOption` | 设置选项 |
| | `LF_GetStatusCount` / `LF_GetStatus` / `LF_PostStatus` | 状态 |
| **查询** | `LF_CheckMainThread` / `LF_CheckApp` / `LF_CheckApi` | 健康检查 |
| **网络事件** | `LF_Set_Network_Event` | 安装 / 卸载全局网络事件回调 |
| **清理** | `LF_Shutdown` | 完全关闭 |
| **同步** | `LF_Sync` | 主线程同步队列 |

## 10. 附录 B – 环境变量与编译选项

- **动态库搜索路径**：系统 PATH（Windows）或 LD_LIBRARY_PATH（Linux）
- **库名**：`LingoFuse64.dll` / `LingoFuse32.dll` / `liblingofuse.so` / `liblingofuse.dylib`
- **Lazarus 编译**：`lazbuild -B project.lpi`
- **单元搜索路径**：确保 `ZNetV2/source` 在项目搜索路径中
- **编译指令建议**：`{$CODEPAGE UTF8}`（FPC）确保 `string` 是 UTF-8（见 LF-JSON-002）

## 11. 附录 C – 常用宏与常量

- `C_Generate_Prefix = '@__generate__@'` – 自动生成名称的前缀
- 默认端口：9898（TCP）
- 日志队列大小：1000 条
- **数据句柄空闲超时：10 分钟**（v3.0 修正）
- **数据句柄扫描间隔：5 秒**
- 顺序通知线程空闲超时：5 分钟
- 顺序通知线程延迟释放：5 秒
- 广播传播延迟：约 3 秒
- `Fixed_Sequenced_Time` 默认：20 秒
- `LF_Generate_AppName` / `LF_Get_AppName` 返回指针有效时间：**约 5 秒**
- `LF_PrepareDone` 初始化超时：`max(Wait_Connection_Timeout, 5000) + 1000` 毫秒
- `LF_GetStatus` 静态缓冲：64 KB
- `LF_GetStatus` 消息截断阈值：65534 字节

---

# 12. LLM 生态坑索引

> **本章不含具体内容**，只作为**索引**指向已有的 LLM 生态文档。
> **原因**：LLM 生态（Python 端、MCP 网关、LTB、stdio 传输等）是**另一个领域**，不应塞进 Pascal 指南稀释主题。
> 需要 LLM 生态坑的读者请查阅 **`LingoFuse_LLM_Pitfalls_For_AI.md`**。

## 12.1 LLM 生态坑 ID 映射表

| LLM 生态坑 ID | 主题 | 归属子系统 | 与 Pascal 层的对应 |
|--------------|------|-----------|------------------|
| P0-1 | `client_name` 必须是真实 App 名 | 客户端 ↔ 服务端 | **LF-APP-003** |
| P0-2 | llama.cpp 线程不安全 | LLM 服务端 | — |
| P0-3 | 回调中不能调阻塞 LingoFuse 函数 | 客户端 | **LF-CB-002** |
| P0-4 | `requests` SSE 缓冲 | 代理层传输 | — |
| P0-5 | proxy 进程立即退出 | LLM 服务端 | — |
| P0-6 | thinking 阶段无输出 | 代理层 | — |
| P1-1 ~ P1-7 | Python 服务端 | Python 服务端 | 部分对应 **LF-TYPE-001** |
| P2-1 ~ P2-3 | 编码问题 | 跨语言 | **LF-XLANG-002** |
| P3-1 ~ P3-3 | 会话生命周期 | 服务端 | — |
| P4-1 ~ P4-6 | GUI 集成 | Pascal GUI 客户端 | 部分对应 **LF-CLEAN-001** |
| P5-1 ~ P5-2 | 递归/边界 | GUI | — |
| P6-1 ~ P6-4 | llm_proxy 专项 | 代理层 | — |
| P7-1 ~ P7-5 | LTB 专项 | LLM Tool Bridge | 部分对应 **LF-NET-003** |
| P8-1 ~ P8-3 | 多模态转发 | 代理层 | — |
| **P9-1 ~ P9-15** | **Structured Output** | **LLM 代理 + JSON** | **LF-JSON-001 / LF-JSON-002** |
| **P10-1** | **子对象调 parse 致父树悬空** | **Z.Json 使用** | **LF-JSON-001**（等价合并） |
| **P10-2** | **JSON 经 AnsiString 中转丢字符** | **Z.Json 使用** | **LF-JSON-002**（等价合并） |
| **P10-3** | **GBK 回退 SetLength 单位错** | **Z.Json 使用** | **LF-JSON-003**（等价合并） |

## 12.2 与 Pascal 相关的交叉引用

有些 LLM 生态的坑**在 Pascal 层有对应**：

| LLM 生态坑 | Pascal 层对应 | 说明 |
|-----------|--------------|------|
| P0-1（client_name） | LF-APP-003 | 都是"名字必须在 PrepareDone 后生成" |
| P0-3（回调阻塞） | LF-CB-002 | 都是"回调中禁止阻塞调用" |
| P2-1（中文编码） | LF-XLANG-002 | 都是"UTF-8 全程贯通" |
| P4-2（FormClose） | LF-CLEAN-001 | 都是"清理顺序" |
| P7-3（LTB 预连接） | LF-NET-003 / LF-MAIN-001 | 都是"PrepareDone 只返回 1 一次" |
| **P9 系列（Structured Output）** | **LF-JSON-001 / LF-JSON-002** | **JSON Schema 组装的通用陷阱** |
| **P10-1（子对象 parse）** | **LF-JSON-001** | **已在 §7.13 完整合并** |
| **P10-2（AnsiString 中转）** | **LF-JSON-002** | **已在 §7.13 完整合并** |
| **P10-3（GBK 回退）** | **LF-JSON-003** | **已在 §7.13 完整合并** |

**注意**：
- P10 系列在 §7.13 中**已完整合并**，不需要重复查阅 LLM 文档。
- P9 系列（Structured Output 的场景陷阱）仍在 LLM 文档中，Pascal 层只引用 **LF-JSON-001 / LF-JSON-002** 作为底层机制说明。

---

# 附录 A：错误消息原文索引

> **使用方式**：在日志/控制台看到以下原文时，直接跳到对应章节。

| 错误消息原文 | 章节 | 简述 |
|-------------|------|------|
| `no found app("...") api("...")` | LF-APP-003 | client_name 未注册或生成过早 |
| `LF_PrepareClient returned -1` | LF-NET-001 | 地址重复 |
| `repeat connection` | LF-NET-001 | 重复地址 |
| `prepare error: repeat listen` | LF-NET-001 | 重复监听地址 |
| `LF_PrepareDone failed` | LF-NET-002 | 等待超时 |
| `LF_PrepareDone returned 0` | LF-NET-003 / LF-MAIN-001 | 二次调用 |
| `LF_BindApp: Main thread is not active` | LF-APP-005 | 主线程未启动 |
| `LF_BindApp: All clients are already occupied` | LF-APP-005 | 无空闲客户端 |
| `LF_BindApp returned 0` | LF-APP-005 | 无空闲客户端 |
| `3029 function header doesn't match` | LF-TYPE-001 | var/out 同签名 |
| `Can't find unit Z.Core` | 编译配置 | 单元搜索路径未配置 |
| `PPU version mismatch` | 编译配置 | FPC 版本不一致 |
| `Queue "..." is already occupied` | 端口占用 | 端点被占用 |
| `Callback type mismatch` | LF-APP-001 | 缺 cdecl |
| `use-after-free` / 段错误 | LF-APP-004 / LF-DATA-002 | 指针已释放 |
| `Timeout` / 大小为 0 的结果 | LF-CALL-001 | 调用超时 |
| `Module not found: LingoFuse64.dll` | 部署 | 动态库未找到 |
| `hint: Data handle pool "N" handles were idle...` | LF-DATA-001 | 数据句柄自动回收日志 |
| `started Sequenced notify thread for api "..."` | LF-SEQ-001 | 顺序通知线程启动日志 |
| `Sequenced notify api "..." thread idle timeout, auto-terminating` | LF-SEQ-001 | 顺序通知线程空闲退出日志 |
| `LingoFuse Main Thread Begin, LingoFuse-v...` | LF-MAIN-001 | 模拟主线程启动日志 |
| `LingoFuse Main Thread Exit` | LF-MAIN-003 | 模拟主线程退出日志 |
| **网络事件回调中访问冲突** | **LF-NET-005** | UI 跨线程访问 |
| **网络事件 `addr_` 变乱码 / 空** | **LF-NET-006** | `addr_` 悬空 |
| **`unrecognized type json_schema`** | **LF-JSON-001** | JSON Schema 组装错误 |
| **`options.response_format` 丢失** | **LF-JSON-001** | 父树悬空 |
| **`ToBytes` 访问冲突** | **LF-JSON-001** | 父树悬空 |
| **Schema 里 emoji / 韩文变 `?`** | **LF-JSON-002** | AnsiString 中转 |
| **CP936 环境下 schema 损坏** | **LF-JSON-002** | 系统代码页 |
| **GBK 回退输出乱码 / 截断** | **LF-JSON-003** | SetLength 单位错 |

---

# 附录 B：ID 总览与维护约定

## B.1 当前 ID 总览（v3.0 更新）

| ID 前缀 | 当前条目数 | 说明 |
|---------|-----------|------|
| `LF-APP` | **7** | 应用/句柄层（v3.0 新增 007：shutdown guard） |
| `LF-CB` | 5 | 回调层 |
| `LF-DATA` | **8** | 数据句柄层（v3.0 新增 006/007/008） |
| `LF-NET` | **7** | 网络准备层（v3.0 新增 007：PrepareDone 超时） |
| `LF-CALL` | 2 | 远程调用层 |
| `LF-SEQ` | 2 | 序列化通知层 |
| `LF-CHK` | 1 | 查询与缓存 |
| `LF-OPT` | **3** | 运行时选项（v3.0 新增 003：Overlap_Connection 完整语义） |
| `LF-CLEAN` | 3 | 清理与生命周期 |
| `LF-THREAD` | 2 | 线程模型 |
| `LF-TYPE` | 2 | 类型与编译 |
| `LF-XLANG` | 3 | 跨语言数据交换 |
| `LF-JSON` | 3 | JSON 使用层 |
| **`LF-MAIN`** | **4** | **模拟主线程（v3.0 新增子系统）** |
| **`LF-MEM`** | **5** | **内存与生命周期（v3.0 新增子系统）** |
| **合计** | **57** | （v2.0 为 42，v1.0 为 37） |

## B.2 维护约定

后续新增坑时遵循以下规则：

1. **ID 分配**：按子系统递增，**不复用已删除的 ID**
2. **证据等级必须标注**：🟢 / 🟡 / 🔴 三选一，禁止空缺
3. **必填字段**：ID、标题、证据等级、影响版本、触发条件、症状、根因、修复 diff、验证清单
4. **可选字段**：最小复现、相关坑
5. **交叉引用**：`相关坑` 字段双向维护
6. **升级证据等级**：从 🔴 → 🟡 → 🟢，只升不降
7. **反例集**：历史遗留的错误用法可保留，但标注"反例，见 ID-XXX"
8. **新增子系统**：需要 ≥ 3 条同源坑时才建立独立子系统前缀

## B.3 待补充的坑（TODO，v3.0 更新）

以下是当前材料中**未覆盖或覆盖不完整**、需要后续补充的坑：

| 待补充项 | 已知信息 | 需要什么 |
|---------|---------|---------|
| `TLF_Data` 的 `bak_input_ / bak_output_` 语义 | `Z.LingoFuse_Core.pas` 中有恢复逻辑 | 回查源码确认恢复范围与副作用 |
| `Fixed_Sequenced_Time` 精确影响 | 默认 20 秒 | 实测不同值下的行为 |
| `TLF_DataPool.Progress` 与正在使用的句柄 | `calling___ > 0` 保护 | 实测回调长时间持有时是否被回收 |
| C4 网络分区的行为 | 未覆盖 | 网络抖动下的恢复逻辑 |
| 大端平台字节序 | 协议约定小端 | 大端平台实测 |
| `LF_SetOption` 的密码掩码算法 | `TMT19937.Rand32 mod 2` | 是否需要安全审查 |
| **网络事件回调的具体执行线程 ID** | 未覆盖 | 打线程 ID 观察 |
| **网络事件回调在 `LF_Shutdown` 期间的行为** | 未覆盖 | 实测卸载期间是否仍触发 |
| **`TZ_JsonObject` 在多线程场景下的安全性** | `Z.Json.md` 说"否" | 实测并补充 ID |
| **Structured Output 在 Pascal 客户端的完整流程** | 指向 `llm_client_v3.md` | 补充端到端示例 |
| **`LF_CreateData_Permanent` 在 `LF_PrepareDone` 前创建的精确行为** | 注释说"可能是 no-op" | 实测并补充 ID |
| **`Simulated_Main_Thread` 中 `C40Progress` 的超时与并发语义** | `LF-MAIN-002` 只覆盖了表面 | 深入 C4 内部 |
| **`TLF_Notify_Sequence_Thread` 的 `DelayFreeObj` 与 `Kill_App` 竞态** | `LF-MEM-004` 提及 | 实测并补充 ID |
| **`LF_Shutdown` 多次调用的幂等性** | `LF-CLEAN-001` 提及 | 实测并补充 ID |

---

# 附录 C：给 AI 使用者的检索规则

## C.1 检索优先级

AI 助手处理 LingoFuse 相关问题时：

1. **先查本知识库**：用 ID（`LF-XXX-NNN`）或关键词
2. **网络事件相关**：先查 §4.11 / §6.8 / `LF-NET-005` / `LF-NET-006`
3. **JSON 相关**：先查 §7.13（`LF-JSON-001 / 002 / 003`），再查 `Z.Json.md`
4. **主线程相关**：先查 §7.14（`LF-MAIN-*`）
5. **内存相关**：先查 §7.15（`LF-MEM-*`）
6. **未命中本知识库**：查 §12 的 LLM 生态索引，指向 `LingoFuse_LLM_Pitfalls_For_AI.md`
7. **都无法回答**：明确告知用户"当前材料不足以判断"，并**建议回查源码**

## C.2 回答时必带的元信息

AI 回答 LingoFuse 问题时，应主动标注：

- **依据的 ID**（如 `LF-APP-003` / `LF-JSON-001`）
- **证据等级**（🟢 / 🟡 / 🔴）
- **是否命中"不确定清单"**

**示例回答**：

> 根据 **LF-DATA-008（证据等级：🟢 已核实源码）**，`LF_CreateData_Permanent` 创建的永久句柄**不会**被自动回收，你必须负责调用 `LF_FreeData`。
>
> 特别注意：
> - `LF_FreeData` 在 `LF_PrepareDone` 之前或 `LF_ExitMainThread` 之后是 **no-op**——此时创建的永久句柄会一直保留到进程退出。
> - 短生命周期场景**不要**用永久句柄——会失去池的安全网。
>
> **相关坑**：LF-DATA-001、LF-DATA-006、LF-CLEAN-001。

## C.3 禁止行为

AI 助手**不应**：

- ❌ 编造不存在的 ID 或章节
- ❌ 把 🔴 推测当作 🟢 已核实回答
- ❌ 假装回答了"不确定清单"里的问题
- ❌ 忽略证据等级直接给结论
- ❌ 用本知识库覆盖 LLM 生态文档（那部分应指向原文档）
- ❌ **在网络事件回调中直接操作 UI**（违反 LF-NET-005）
- ❌ **在子对象上调用 `ParseText` / `Parae`**（违反 LF-JSON-001）
- ❌ **依赖数据句柄自动回收**（违反 LF-DATA-001）
- ❌ **假设 `LF_CreateData_Permanent` 会自动释放**（违反 LF-DATA-008）

## C.4 结构化输出模板（推荐）

```
【ID】LF-XXX-NNN
【证据等级】🟢 / 🟡 / 🔴
【症状】...
【根因】...
【修复】...
【验证】...
【相关坑】...
【不确定点】（如适用）
```

---

# 六条铁律

> v3.0 从 4 条扩充到 6 条。前 4 条沿用 v2.0，新增第 5、6 条。

**铁律一**：回调必须 `cdecl`，且禁止在回调中调用 `LF_Call` / `LF_Notify` / `LF_LocalCall`。
→ 对应 ID：LF-APP-001、LF-CB-002。

**铁律二**：数据句柄必须显式 `LF_FreeData`，不能用自动回收当保险。**自动回收是 10 分钟空闲 + 5 秒扫描延迟**。
→ 对应 ID：LF-DATA-001。

**铁律三**：清理顺序必须是 `ExitMainThread` → `FreeApp` → `Shutdown`。
→ 对应 ID：LF-CLEAN-001。

**铁律四**：`TZ_JsonObject` 是树。`Parae` / `Assign` / `LoadFromStream` / `ParseText` 只能在 root 上调用。JSON 组装中间容器用 `TZ_JsonString`，`.Bytes` 只在最后一步。
→ 对应 ID：LF-JSON-001、LF-JSON-002。

**铁律五（v3.0 新增）**：**`LF_PrepareDone` 每进程只能成功启动一次。多次调用第二次返回 0。`LF_ExitMainThread` 会清空所有数据句柄（包括 permanent）。**
→ 对应 ID：LF-MAIN-001、LF-MAIN-003、LF-NET-003。

**铁律六（v3.0 新增）**：**`LF_CreateData_Permanent` 创建的句柄不会自动回收，必须手动 `LF_FreeData`。但 `LF_FreeData` 在 `LF_PrepareDone` 前/`LF_ExitMainThread` 后是 no-op——此时创建的永久句柄会一直保留到进程退出。**
→ 对应 ID：LF-DATA-008、LF-MAIN-003。

**附**：网络事件回调在**后台 TCompute 工作线程**执行，`addr_` 在**回调返回后立即失效**。
→ 对应 ID：LF-NET-005、LF-NET-006。

---

## 与本版对比：我做了什么，没做什么（v3.0 自我检查）

**做了**：

- **关键修正**：
  - 数据句柄自动回收时间：**5 分钟 → 10 分钟**（全文 6 处）
  - 数据句柄扫描间隔：明确为 **5 秒**（§2、§4.1、§6.5、§7.3、附录 C）
  - 顺序通知线程延迟释放（`DelayFreeObj(5.0, self)`）说明（§7.6 `LF-SEQ-001`、§7.15 `LF-MEM-004`）
  - `LF_PostStatus` 语义：主线程未运行时**仍入队**（§4.7）

- **新增机制**：
  - `TLF_DataMemory` 二级内存池（§6.9、§7.3 `LF-DATA-006`、§7.15 `LF-MEM-001`）
  - `Begin_Call` / `End_Call` 与 `calling___` 计数器（§6.10、§7.3 `LF-DATA-007`）
  - `LF_CreateData_Permanent` 完整语义（§4.1、§6.9、§7.3 `LF-DATA-008`）
  - `LF_FreeApp` 的 shutdown guard（§7.1 `LF-APP-007`）
  - `LF_PrepareDone` 超时后仍返回 1（§7.4 `LF-NET-007`）
  - `Overlap_Connection` 完整语义与推荐配置（§7.8 `LF-OPT-003`）

- **新增子系统**：
  - §7.14 `LF-MAIN-*`：模拟主线程与 C4 进度循环（4 条）
  - §7.15 `LF-MEM-*`：内存与对象生命周期（5 条）

- **新增章节**：
  - §6.9 二级内存池与永久句柄
  - §6.10 数据句柄的 calling 计数器
  - §7.14 `LF-MAIN-001` ~ `LF-MAIN-004`
  - §7.15 `LF-MEM-001` ~ `LF-MEM-005`

- **铁律扩充**：从 4 条到 6 条

- **ID 总览更新**：从 42 条到 57 条

- **错误消息索引**：新增 6 条（`hint: Data handle pool`、`started Sequenced notify thread`、`Sequenced notify ... idle timeout`、`LingoFuse Main Thread Begin`、`LingoFuse Main Thread Exit`、`prepare error: repeat listen`）

- **TODO 清单**：新增 5 条（Permanent 前创建、Simulated_Main_Thread 并发语义、DelayFreeObj 竞态、Shutdown 幂等性等）

**没做（诚实声明）**：

- **我没有**回源码逐条核实——依据是用户提供的 `lingofuse_import.pas`、`lingofuse_helper.pas`、`Z.LingoFuse_Export.pas`、`Z.LingoFuse_Core.pas`、`Z.Net.C4.LingoFuse.pas`、`LingoFuse.lpr`、`Z.LingoFuse.md`、`Z.Json.md`、`LingoFuse_LLM_Pitfalls_For_AI.md` 文本
- **我没有**实测每条坑的最小复现——所有"最小复现"都是基于源码逻辑推演，未在真实编译环境下验证
- **我没有**标注实际行号——因为素材中没有行号信息
- **我没有**尝试消除 🔴 级别的推测项——`Z.LingoFuse.md` 中的不确定清单被保留
- **我没有**覆盖 LLM 生态的 P9 系列细节——只做索引，具体内容仍指向 `LingoFuse_LLM_Pitfalls_For_AI.md`

**下一步建议**（若需要 v4.0 真正落地）：

1. 由能接触到源码的人逐条确认 🟡 和 🔴 的条目
2. 每条坑至少在一台真实机器上跑一次最小复现
3. 补充实际文件名 + 函数名 + （可选）行号
4. 用 CI 集成回归测试，防止坑回潮
5. 补充网络事件、JSON 场景、主线程、内存池的端到端测试用例
6. 补充 `LF-MAIN-*` 的 `C40Progress` 内部并发行为

---

*文档版本：v3.0（Pascal 核心层踩坑知识库 v3.0）*
*本版核心改进：修正 10 分钟自动回收；新增二级内存池 / calling 计数器 / 永久句柄 / 主线程 / 内存生命周期共 15 条新坑；铁律扩充到 6 条；ID 总览更新为 57 条*
*最后更新：2026-10-01*
*维护者：LingoFuse 团队*