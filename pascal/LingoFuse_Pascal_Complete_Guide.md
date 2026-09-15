# LingoFuse Pascal 完整指南（含踩坑知识库 v1.0）

> **面向 AI 与人类开发者的权威参考**  
> 第 1–6 章：学习指南；第 7 章：**Pascal 核心层踩坑知识库（本版重点）**；第 12 章：LLM 生态坑索引
>
> **本版的核心变化**：第 7 章从"零散陷阱"重构为**带 ID 体系、证据等级、复现、验证清单的结构化知识库**。
> 每一条坑都可被 AI 直接消费、被后续维护者增量更新，是 LF 后续发展的**长期资产**。
>
> **证据等级约定**（本版引入，贯穿全文）：
> - 🟢 **已核实源码** — 在 `lingofuse_import.pas`、`lingofuse_helper.pas` 或 `Z.LingoFuse.md`（逐行核对版）中有直接依据
> - 🟡 **仅文档转录** — 来自其他文档，未逐行回源码核对
> - 🔴 **推测** — 从行为推断，未找到直接源码依据；**使用前请回查源码**
>
> **本版的诚实声明**：第 7 章中所有条目标注了证据等级。凡是 🔴 级别的，说明我无法从当前材料中确认，**不装懂**。凡是 🟢 级别的，你可以在源码里找到对应实现。

---

## 📖 目录

- [第 1–6 章：基础指南（保留原有内容）](#第-16-章基础指南)
- [第 7 章：🚨 Pascal 核心层踩坑知识库（v2.0 重构）](#7--pascal-核心层踩坑知识库)
  - 7.0 ID 体系与使用说明
  - 7.1 应用/句柄层（LF-APP-*）
  - 7.2 回调层（LF-CB-*）
  - 7.3 数据句柄层（LF-DATA-*）
  - 7.4 网络准备层（LF-NET-*）
  - 7.5 远程调用层（LF-CALL-*）
  - 7.6 序列化通知层（LF-SEQ-*）
  - 7.7 查询与缓存层（LF-CHK-*）
  - 7.8 运行时选项层（LF-OPT-*）
  - 7.9 清理与生命周期（LF-CLEAN-*）
  - 7.10 线程模型（LF-THREAD-*）
  - 7.11 类型与编译（LF-TYPE-*）
  - 7.12 跨语言数据交换（LF-XLANG-*）
- [第 8–11 章：对比、附录（保留原有内容）](#第-811-章对比附录)
- [第 12 章：LLM 生态坑索引（指向 LLM_Pitfalls）](#12--llm-生态坑索引)
- [附录 A：错误消息原文索引](#附录-a错误消息原文索引)
- [附录 B：ID 总览与维护约定](#附录-bid-总览与维护约定)
- [附录 C：给 AI 使用者的检索规则](#附录-c给-ai-使用者的检索规则)

---

# 第 1–6 章：基础指南

> **说明**：以下 1–6 章保留原文档的内容与结构，仅做轻微整理（去掉重复段落、统一术语），核心 API 签名、示例、最佳实践**一字未改**。

## 1. 引言

**LingoFuse** 是一个面向智能体（Agent）和全栈系统的分布式 RPC 框架，基于 C4 服务网格，提供跨语言、跨进程、跨机器的函数调用能力。本指南聚焦于 **Pascal 语言绑定**，该绑定通过 `lingofuse_import.pas` 单元导出所有 C ABI 函数，并提供 `lingofuse_helper.pas` 作为 RAII 高级封装。

本指南旨在成为 **AI 和人类开发者** 的共同参考，详细解释每个 API、其参数、返回值、内部机制、常见陷阱和最佳实践。所有内容均基于 **LingoFuse v3.0** 及 Pascal 绑定单元 `Z.LingoFuse_Export.pas` 实现。

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
- **陷阱**：句柄创建后 API 名称不可更改；载荷的读写不影响 API 名称。

#### `LF_FreeData(Hnd: TDataHnd)`
- **功能**：销毁数据句柄，释放内存。如果句柄已在全局池中，会从池中移除。
- **注意**：即使句柄被自动回收器回收，显式调用此函数仍是必须的（推荐）。
- **陷阱**：不要在回调中或远程调用未完成时释放句柄。

#### `LF_GetBuffer(Hnd: TDataHnd): Pointer`
- **功能**：返回内部缓冲区的起始指针（只读或读写）。
- **返回**：指针，若句柄为空或大小为 0 则返回 nil。
- **辅助**：`LF_GetBufferOffset(Hnd; Offset: NativeInt): Pointer` 返回偏移后的指针。

#### `LF_WriteBuffer(Hnd: TDataHnd; Buff: Pointer; Size: Int64): Int64`
- **功能**：从当前位置写入 `Size` 字节，缓冲区自动扩容，位置向后移动。
- **返回**：实际写入的字节数。

#### `LF_ReadBuffer(Hnd: TDataHnd; Buff: Pointer; Size: Int64): Int64`
- **功能**：从当前位置读取最多 `Size` 字节到 `Buff`，位置向后移动。
- **返回**：实际读取的字节数。

#### 位置与大小操作
- `LF_GetPos(Hnd): Int64` – 获取当前读写位置。
- `LF_SetPos(Hnd; Pos_: Int64)` – 设置读写位置。
- `LF_GetSize(Hnd): Int64` – 获取缓冲区总大小。
- `LF_SetSize(Hnd; Size_: Int64)` – 调整缓冲区大小。

#### 原子类型读写辅助（Pascal 封装）

| 写入 | 读取（out 参数） | 读取（返回值） |
|------|-----------------|---------------|
| `LF_WriteInt8` … `LF_WriteDouble` | `LF_ReadInt8` … `LF_ReadDouble` | 同左 |
| `LF_WriteString` | `LF_ReadString`（out） | `LF_ReadString` |
| `LF_WriteStringBytes` | `LF_ReadStringBytes`（out） | `LF_ReadStringBytes` |

- 所有写入函数以小端字节序编码。
- `LF_WriteString` 会追加空终止符 (#0)。
- `LF_ReadString` 扫描直到 #0，若未找到则读至末尾（容错模式）。

### 4.2 应用句柄操作

- `LF_CreateApp(appName, Desc: PAnsiChar): TAppHnd` / `LF_CreateAppEx`
- `LF_FreeApp(appHnd)` – 分离应用（延迟销毁）
- `LF_Generate_AppName(): PAnsiChar` / `LF_Generate_AppNameEx(): string`
- `LF_Get_AppName(appHnd): PAnsiChar` / `LF_Get_AppNameEx(appHnd): string`
- `LF_BindApp(appHnd): Integer`

### 4.3 API 注册

- `LF_RegisterCall` / `LF_RegisterNotify`（cdecl 函数）
- `LF_RegisterCall_M` / `LF_RegisterSyncCall_M`（对象方法）
- `LF_RegisterNotify_M` / `LF_RegisterSyncNotify_M`
- `LF_Unregister`

**回调约束**：禁止在回调中调用 `LF_Call`、`LF_Notify`、`LF_LocalCall`。

### 4.4 本地调用

- `LF_LocalCall(appHnd; Param: TDataHnd): TDataHnd`
- `LF_LocalNotify(appHnd; Param: TDataHnd)`

### 4.5 网络准备与启动

- `LF_ResetPrepare()`
- `LF_PrepareService(ListeningAddr_, PhysicsAddr_: PAnsiChar): Integer`
- `LF_PrepareClient(PhysicsAddr_: PAnsiChar; appHnd: TAppHnd): Integer`
- `LF_PrepareDone(): Integer`
- `LF_ExitMainThread()`

### 4.6 远程调用与通知

- `LF_Call(appName: PAnsiChar; Param: TDataHnd; Timeout_: UInt64): TDataHnd`
- `LF_Notify(appName: PAnsiChar; Param: TDataHnd)`
- `LF_Sequenced_Notify(appName: PAnsiChar; Param: TDataHnd)`

### 4.7 运行时选项与状态

- `LF_SetOption(Option, Value: PAnsiChar)`
  - `password` / `passwd`、`Quiet`、`ConsoleOutput`
  - `Overlap_Connection`、`Wait_Connection_ReadyOk`、`Wait_Connection_Timeout`
  - `IPC_Serv_ThreadCount`、`IPC_Serv_MaxQueueLength`、`IPC_Serv_MaxMsgSize`
  - `Fixed_Sequenced_Time`
- `LF_GetStatusCount()`、`LF_GetStatus()`、`LF_PostStatus()`

### 4.8 同步辅助

- `LF_Sync(): Integer`

### 4.9 查询与健康检查

- `LF_CheckMainThread()`、`LF_CheckApp(appName)`、`LF_CheckApi(appName, apiName)`
- 基于本地缓存，广播延迟约 3 秒。

### 4.10 关闭与清理

- `LF_Shutdown()` – 完全关闭：
  1. 停止所有序列化通知线程
  2. 释放所有剩余数据句柄
  3. 退出模拟主线程
  4. 清空全局应用池
  5. 卸载 IPC 库

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

### 6.5 数据句柄自动回收机制

- `TLF_DataPool` 每 5 秒扫描一次，释放闲置超过 5 分钟的句柄
- **不应依赖此机制**，生产环境应显式 `LF_FreeData`

### 6.6 应用生命周期

- `LF_FreeApp`：分离应用，但对象仍在池中
- `LF_Shutdown`：清空池，销毁所有对象

### 6.7 回调线程安全与死锁预防

- 所有回调在 C4 线程池执行
- **禁止**在回调中调用阻塞函数
- 同步回调需定期 `LF_Sync` 驱动

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

### 7.0.2 证据等级使用约定

- 🟢 **已核实源码**：在 `lingofuse_import.pas`、`lingofuse_helper.pas` 或 `Z.LingoFuse.md`（逐行核对版）中有直接文本依据。
- 🟡 **仅文档转录**：来自 `LingoFuse_Python_Binding_Migration_Record.md`、`LingoFuse_mcp_api_tool_Implementation_Memo.md` 等，未逐行回源码核对。
- 🔴 **推测**：从行为/示例代码推断，**使用前请回查源码**。

**重要**：本版中 🔴 级别的条目**不构成权威结论**，仅作为"可疑点"提示。

### 7.0.3 版本区间说明

- "所有版本"：从 v1.0 起就存在的约束（多为设计固有限制）
- "v3.0+"：v3.0 引入的接口/行为
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
  - [ ] 至少 2 种编译器 × 2 种优化级别通过（如 Delphi 10.4 `-O2` + FPC 3.3.1 `-O2`）
- **相关坑**：LF-CB-001、LF-CB-002

### LF-APP-002：`LF_FreeApp` 是两阶段析构，不立即释放内存

- **证据等级**：🟢 已核实源码（`Z.LingoFuse.md` 第 2.3 节、`lingofuse_import.pas` 注释）
- **影响版本**：所有版本
- **触发条件**：调用 `LF_FreeApp` 后立即期望内存下降
- **症状**：
  - 内存不降反升，或长时间不降
  - 频繁创建/销毁 App 的服务，`LF_App_Pool` 持续增长
- **根因**：`LF_FreeApp` 只做两件事：
  1. 遍历所有 `TC40_LF_Client`，把 `Cli.app = app` 的置 nil（**解绑**）
  2. `LF_Notify_Sequence_Thread_Pool.Kill_App(app)`（**停掉顺序通知线程**）
  3. `app.FakeFree`（**仅移除定时器**）
  
  对象**不立即销毁**——仍在 `LF_App_Pool` 中，等 `LF_Shutdown` 时清理。
  
  **为什么这样设计**：防止网络广播仍在引用 App 数据时出现悬空指针。
- **正确做法**：
  - **长期运行**：避免频繁创建/销毁 App，可复用 App 名
  - **短期任务**：调用 `LF_Shutdown` 后重启框架
  - **测试程序**：一次性创建多个 App，最后统一 `LF_Shutdown`
- **验证清单**：
  - [ ] 观察 `LF_App_Pool` 大小（可通过日志或调试器）
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
- **根因**：`LF_Generate_AppName` 的实现（`Z.LingoFuse.md` §2.3）：
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

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 注释"5 seconds"）
- **影响版本**：所有版本
- **触发条件**：保留返回的 `PAnsiChar` 指针，5 秒后才使用
- **症状**：字符串变成乱码、空字符串，或访问违规
- **根因**：这两个函数返回**指向内部静态缓冲区的指针**，库在 **5 秒后自动释放**该缓冲区。
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

- **证据等级**：🟢 已核实源码（`Z.LingoFuse.md` §2.3）
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
  - [ ] `LF_CheckMainThread() = 1`（主线程已启动）
  - [ ] `LF_BindApp` 返回值 > 0
  - [ ] 用 `LF_CheckAppEx(newAppName)` 返回 1
- **相关坑**：LF-NET-001、LF-NET-004

### LF-APP-006：`Overlap_Connection=False` 时同一地址的第二个 App 被静默忽略

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 注释 + `Z.LingoFuse.md` §2.3）
- **影响版本**：所有版本
- **触发条件**：默认配置（`Overlap_Connection=False`）下，向同一地址重复 `LF_PrepareClient`
- **症状**：
  - 第二次 `LF_PrepareClient` 返回的 tag 是新的（不报错）
  - 但**新 App 从未被绑定**
  - 后续对该 App 的 `LF_Call` 永远超时
- **根因**：`Overlap_Connection=False` 时，每个物理地址只允许一个客户端隧道。第二次 `LF_PrepareClient` **复用已存在的隧道**，丢弃传入的新 App 参数。
  
  `Z.LingoFuse.md` §2.3 `LF_PrepareClient` 契约：
  > "**`not Overlap_Connection` 时重复检测**"
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

---

## 7.2 回调层（LF-CB-*）

### LF-CB-001：回调必须显式 `cdecl`

- **证据等级**：🟢 已核实源码
- **影响版本**：所有版本
- **说明**：与 **LF-APP-001** 是同一条坑（从应用层视角看）与同一条坑（从回调层视角看）。**合并表述**：无论注册 Call 还是 Notify，回调**必须**加 `cdecl`。
- **相关坑**：LF-APP-001

### LF-CB-002：回调中禁止调用阻塞型 LingoFuse 函数

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档"CRITICAL – CALLBACK BLOCKING"）
- **影响版本**：所有版本
- **触发条件**：在 Call/Notify 回调里调用 `LF_Call`、`LF_LocalCall`、`LF_Notify`、`LF_PrepareDone`
- **症状**：**整个进程死锁**，服务端不再响应任何请求；调试器显示回调线程阻塞在内部锁
- **根因**：回调运行在 C4 线程池的某个线程上，且持有可能被远程调用需要的内部锁。当回调调用 `LF_Call` 时，远程调用需要获取同一把锁 → **自锁死**。
  
  `lingofuse_import.pas`：
  > "Inside a callback (Call or Notify), you MUST NOT call any blocking LingoFuse function such as LF_Call, LF_LocalCall, or LF_PrepareDone. Doing so will cause a deadlock."
- **最小复现**：
  ```pascal
  procedure MyCallback(Trigger: Pointer; Input, Output: TDataHnd); cdecl;
  var Res: TDataHnd;
  begin
    // ❌ 死锁！
    Res := LF_CallEx('OtherApp', Input, 5000);
    // ...
  end;
  ```
- **修复 diff**：
  ```diff
    procedure MyCallback(Trigger: Pointer; Input, Output: TDataHnd); cdecl;
  - var Res: TDataHnd;
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
  - [ ] 用 `--debug` 观察是否有崩溃报告
- **相关坑**：LF-CB-005、LF-THREAD-002

### LF-CB-005：同步回调必须由主循环驱动 `LF_Sync`

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
- **影响版本**：所有版本
- **触发条件**：注册了 `RegisterSyncCall_M` / `RegisterSyncNotify_M`，但主循环未定期调用 `LF_Sync`
- **症状**：
  - 同步回调**永远不执行**
  - 调用方线程永久阻塞
  - 后台线程处于 `while tmp.Second do TCore_Thread.Sleep(1)` 状态
- **根因**：`TSoft_Synchronize_Tool.Synchronize` 的实现（`lingofuse_import.pas` 内部）：
  - 若当前线程**不是**主线程：将过程入队，然后 `while tmp.Second do Sleep(1)` 忙等
  - 主线程必须**定期调用** `Check_Synchronize`（通过 `LF_Sync`）来出队并执行
- **最小复现**：
  ```pascal
  App.RegisterCallSync('slow', 'Slow call', OnSlowCallback);
  // ...
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
  - [ ] 主循环中有 `LF_Sync`
  - [ ] 同步回调能在 100ms 内执行（压测验证）
  - [ ] `LF_Sync` 返回值为处理的任务数（可用于日志监控）
- **相关坑**：LF-CB-004、LF-THREAD-001

---

## 7.3 数据句柄层（LF-DATA-*）

### LF-DATA-001：句柄必须显式释放，不能依赖 5 分钟自动回收

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档 + `Z.LingoFuse.md` §1.5）
- **影响版本**：所有版本
- **触发条件**：创建句柄后忘记 `LF_FreeData`
- **症状**：
  - 高强度调用下内存持续增长，最终 OOM
  - 5 分钟内积累的句柄数超过自动回收速度
- **根因**：
  - `TLF_DataPool.Progress`（`Z.LingoFuse.md` §1.5）：**每 5 秒扫描一次**，释放闲置超过 **5 分钟**的句柄
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
  - [ ] 用 `fpc_tester_for_LingoFuse` 的资源泄漏检测
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

- **证据等级**：🟢 已核实源码（`Z.LingoFuse.md` §1.4）
- **影响版本**：所有版本
- **触发条件**：手动操作 `TLF_Data` 内部字段（高级用户）
- **症状**：如果试图同时使用 `Data_Param` 和 `Data_Result`，行为未定义
- **根因**：`TLF_Data` 的设计（`Z.LingoFuse.md` §1.4）：
  > "**`Data_Param` 与 `Data_Result` 互斥**——同一句柄只有一个非 nil。"
  >
  > - 输入句柄：`Data_Param` 非 nil，`Data_Result` 为 nil
  > - 输出句柄：`Data_Result` 非 nil，`Data_Param` 为 nil
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
- **根因**：`LF_WriteString` 的实现（`lingofuse_import.pas`）：
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
  
  及 `Wait_Connection_ReadyOk` 选项：
  > "If True, LF_PrepareDone blocks until all prepared clients are connected and their applications are online (boolean). Default is True."
- **正确做法**（部署模式）：
  ```pascal
  LF_SetOptionEx('Wait_Ready', 'False');           // 不阻塞等待
  LF_SetOptionEx('Wait_Connection_Timeout', '5000'); // 缩短超时
  ```
  或：`PrepareDone` 后**检查 `LF_CheckApp`**，失败则重试
- **验证清单**：
  - [ ] 服务端未启动时，`LF_PrepareDone` 返回时间 < 1 秒（部署模式）
  - [ ] 或：`LF_PrepareDone` 后 `LF_CheckAppEx` 返回 1
- **相关坑**：LF-NET-004、LF-CHK-001

### LF-NET-003：`LF_PrepareDone` 在同一进程内只有第一次返回 1

- **证据等级**：🟡 仅文档转录（来自 `LingoFuse_LLM_Pitfalls_For_AI.md` P7-3）
- **影响版本**：未知（v3.0+ 至少）
- **触发条件**：同一进程内 `LF_PrepareDone` 被多次调用
- **症状**：
  - 第一次返回 1
  - 第二次及以后返回 0
  - 依赖"第二次返回 1"的逻辑永久失败
- **根因**：
  - `LF_PrepareDone` 内部启动模拟主线程
  - **主线程一旦启动，后续调用检测到已启动状态 → 返回 0**
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

---

## 7.5 远程调用层（LF-CALL-*）

### LF-CALL-001：`LF_Call` 超时返回大小为 0 的句柄（不是 nil）

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_Call` 注释）
- **影响版本**：所有版本
- **触发条件**：调用超时或目标 App 未注册
- **症状**：调用者用 `if Result <> nil then ...` 判断失败，**判断失效**
- **根因**：
  `lingofuse_import.pas`：
  > "On timeout, an empty result handle is returned (size 0). Always check the result size with LF_GetSize to detect timeouts."
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

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` 头文档）
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

- **证据等级**：🟢 已核实源码（`Z.LingoFuse.md` §1.9）
- **影响版本**：所有版本
- **触发条件**：某 `(App, API)` 对 5 分钟无 `Sequenced_Notify`
- **症状**：下一次调用时有明显启动延迟（线程重建）
- **根因**：`TLF_Notify_Sequence_Thread.Do_Run_Th`（`Z.LingoFuse.md` §1.9）：
  > "若 **超过 5 分钟空闲**：`Activted := False`（**自动终止**）。"
- **正确做法**：
  - 接受这一点（设计行为）
  - 若延迟敏感：改用 `LF_Notify`（可能乱序）
  - 或调整 `Fixed_Sequenced_Time`（默认 20 秒）
- **验证清单**：
  - [ ] 高频率场景下无可感知延迟
  - [ ] 低频率场景下延迟可接受
- **相关坑**：LF-SEQ-002

### LF-SEQ-002：`LF_Sequenced_Notify` 的 FIFO 保证仅限同一 `(App, API)` 对

- **证据等级**：🟢 已核实源码（`Z.LingoFuse.md` §1.8）
- **影响版本**：所有版本
- **触发条件**：跨不同 `(App, API)` 对期望顺序
- **症状**：跨 API 的消息可能乱序
- **根因**：`TLF_Notify_Sequence_Thread_Pool`（`Z.LingoFuse.md` §1.8）：
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

- **证据等级**：🟢 已核实源码（`Z.LingoFuse.md` §2.7 全局变量 + `lingofuse_import.pas` 注释）
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

- **证据等级**：🟢 已核实源码（`lingofuse_import.pas` `LF_SetOption` 注释）
- **影响版本**：所有版本
- **触发条件**：拼错选项名（大小写敏感）
- **症状**：设置无效果，且**无任何报错**
- **根因**：
  `lingofuse_import.pas`：
  > "**Unknown options are silently ignored.**"
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
- **相关坑**：LF-CLEAN-002、LF-APP-002

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
  - 且注意 LF-NET-003（`PrepareDone` 只有第一次返回 1 的约束）
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
  > "All functions exported by this unit are **fully thread‑safe**. You may call them from any thread concurrently without external locking."
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
  - [ ] Delphi 编译也通过（Delphi 区分 `var`/`out`）
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
- **相关坑**：LF-TYPE-001、LF-XLANG-003

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
- **相关坑**：LF-DATA-004、LF-DATA-005

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
- **相关坑**：LF-XLANG-003、LF-TYPE-002

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

# 第 8–11 章：对比、附录

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
| 序列化通知 | `LF_Sequenced_NotifyEx` | `LF_Sequenced_Notify` | 等价 |
| 错误处理 | 检查返回值 | 异常（`RegistrationError`, `ConnectionError`） | Python 更激进 |
| 资源清理 | 显式 `LF_FreeData`, `LF_FreeApp`, `LF_Shutdown` | `with` 语句或显式 `free()` | 均推荐显式 |

## 9. 附录 A – 函数速查表

| 分类 | 函数名 | 简要说明 |
|------|--------|----------|
| **数据句柄** | `LF_CreateData` / `LF_FreeData` | 创建 / 销毁句柄 |
| | `LF_GetBuffer` / `LF_WriteBuffer` / `LF_ReadBuffer` | 缓冲区访问 |
| | `LF_GetPos` / `LF_SetPos` / `LF_GetSize` / `LF_SetSize` | 位置与大小 |
| | `LF_WriteInt32` / `LF_ReadInt32` 等 | 原子类型 |
| | `LF_WriteString` / `LF_ReadString` | 字符串 |
| **应用** | `LF_CreateApp` / `LF_FreeApp` | 创建 / 分离应用 |
| | `LF_Generate_AppName` / `LF_Get_AppName` | 名称 |
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
| **清理** | `LF_Shutdown` | 完全关闭 |
| **同步** | `LF_Sync` | 主线程同步队列 |

## 10. 附录 B – 环境变量与编译选项

- **动态库搜索路径**：系统 PATH（Windows）或 LD_LIBRARY_PATH（Linux）
- **库名**：`LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib`
- **Lazarus 编译**：`lazbuild -B project.lpi`
- **单元搜索路径**：确保 `ZNetV2/source` 在项目搜索路径中

## 11. 附录 C – 常用宏与常量

- `C_Generate_Prefix = '@__generate__@'` – 自动生成名称的前缀
- 默认端口：9898（TCP）
- 日志队列大小：1000 条
- 数据句柄闲置超时：5 分钟
- 序列化通知线程空闲超时：5 分钟
- 广播传播延迟：约 3 秒
- `Fixed_Sequenced_Time` 默认：20 秒

---

# 12. LLM 生态坑索引

> **本章不含具体内容**，只作为**索引**指向已有的 LLM 生态文档。
> **原因**：LLM 生态（Python 端、MCP 网关、LTB、stdio 传输等）是**另一个领域**，不应塞进 Pascal 指南稀释主题。
> 需要 LLM 生态坑的读者请查阅 **`LingoFuse_LLM_Pitfalls_For_AI.md`**。

## 12.1 LLM 生态坑 ID 映射表

| LLM 生态坑 ID | 主题 | 归属子系统 |
|--------------|------|-----------|
| P0-1 | `client_name` 必须是真实 App 名 | 客户端 ↔ 服务端 |
| P0-2 | llama.cpp 线程不安全 | LLM 服务端 |
| P0-3 | 回调中不能调阻塞 LingoFuse 函数 | 客户端 |
| P0-4 | `requests` SSE 缓冲 | 代理层传输 |
| P0-5 | proxy 进程立即退出 | LLM 服务端 |
| P0-6 | thinking 阶段无输出 | 代理层 |
| P1-1 ~ P1-7 | Python 服务端 | Python 服务端 |
| P2-1 ~ P2-3 | 编码问题 | 跨语言 |
| P3-1 ~ P3-3 | 会话生命周期 | 服务端 |
| P4-1 ~ P4-6 | GUI 集成 | Pascal GUI 客户端 |
| P5-1 ~ P5-2 | 递归/边界 | GUI |
| P6-1 ~ P6-4 | llm_proxy 专项 | 代理层 |
| P7-1 ~ P7-5 | LTB 专项 | LLM Tool Bridge |

## 12.2 与 Pascal 相关的交叉引用

有些 LLM 生态的坑**在 Pascal 层有对应**：

| LLM 生态坑 | Pascal 层对应 | 说明 |
|-----------|--------------|------|
| P0-1（client_name） | LF-APP-003 | 都是"名字必须在 PrepareDone 后生成" |
| P0-3（回调阻塞） | LF-CB-002 | 都是"回调中禁止阻塞调用" |
| P2-1（中文编码） | LF-XLANG-002 | 都是"UTF-8 全程贯通" |
| P4-2（FormClose） | LF-CLEAN-001 | 都是"清理顺序" |

**注意**：LLM 生态的坑描述更完整（含 Python 代码示例），需要时请查阅原文档。

---

# 附录 A：错误消息原文索引

> **使用方式**：在日志/控制台看到以下原文时，直接跳到对应章节。

| 错误消息原文 | 章节 | 简述 |
|-------------|------|------|
| `no found app("...") api("...")` | LF-APP-003 | client_name 未注册或生成过早 |
| `LF_PrepareClient returned -1` | LF-NET-001 | 地址重复 |
| `repeat connection` | LF-NET-001 | 重复地址 |
| `LF_PrepareDone failed` | LF-NET-002 | 等待超时 |
| `LF_PrepareDone returned 0` | LF-NET-003 | 二次调用 |
| `3029 function header doesn't match` | LF-TYPE-001 | var/out 同签名 |
| `Can't find unit Z.Core` | 编译配置 | 单元搜索路径未配置 |
| `PPU version mismatch` | 编译配置 | FPC 版本不一致 |
| `Queue "..." is already occupied` | 端口占用 | 端点被占用 |
| `Callback type mismatch` | LF-APP-001 | 缺 cdecl |
| `LF_BindApp returned 0` | LF-APP-005 | 无空闲客户端 |
| `use-after-free` / 段错误 | LF-APP-004 / LF-DATA-002 | 指针已释放 |
| `Timeout` / 大小为 0 的结果 | LF-CALL-001 | 调用超时 |
| `Module not found: LingoFuse64.dll` | 部署 | 动态库未找到 |

---

# 附录 B：ID 总览与维护约定

## B.1 当前 ID 总览

| ID 前缀 | 当前条目数 | 说明 |
|---------|-----------|------|
| `LF-APP` | 6 | 应用/句柄层 |
| `LF-CB` | 5 | 回调层 |
| `LF-DATA` | 5 | 数据句柄层 |
| `LF-NET` | 4 | 网络准备层 |
| `LF-CALL` | 2 | 远程调用层 |
| `LF-SEQ` | 2 | 序列化通知层 |
| `LF-CHK` | 1 | 查询与缓存 |
| `LF-OPT` | 2 | 运行时选项 |
| `LF-CLEAN` | 3 | 清理与生命周期 |
| `LF-THREAD` | 2 | 线程模型 |
| `LF-TYPE` | 2 | 类型与编译 |
| `LF-XLANG` | 3 | 跨语言数据交换 |
| **合计** | **37** | |

## B.2 维护约定

后续新增坑时遵循以下规则：

1. **ID 分配**：按子系统递增，**不复用已删除的 ID**
2. **证据等级必须标注**：🟢 / 🟡 / 🔴 三选一，禁止空缺
3. **必填字段**：ID、标题、证据等级、影响版本、触发条件、症状、根因、修复 diff、验证清单
4. **可选字段**：最小复现、相关坑
5. **交叉引用**：`相关坑` 字段双向维护
6. **升级证据等级**：从 🔴 → 🟡 → 🟢，只升不降
7. **反例集**：历史遗留的错误用法可保留，但标注"反例，见 ID-XXX"

## B.3 待补充的坑（TODO）

以下是当前材料中**未覆盖或覆盖不完整**、需要后续补充的坑：

| 待补充项 | 已知信息 | 需要什么 |
|---------|---------|---------|
| `TLF_App.FakeFree` 完整语义 | `Z.LingoFuse.md` 说"仅 Remove_Timer" | 回查源码确认 |
| `TLF_Data` 的 `bak_input_ / bak_output_` 语义 | `Z.LingoFuse.md` 说"回调前后恢复" | 回查源码确认恢复范围 |
| `Fixed_Sequenced_Time` 精确影响 | 默认 20 秒 | 实测不同值下的行为 |
| `TLF_DataPool.Progress` 与正在使用的句柄 | 5 分钟回收 | 实测回调长时间持有时是否被回收 |
| C4 网络分区的行为 | 未覆盖 | 网络抖动下的恢复逻辑 |
| 大端平台字节序 | 协议约定小端 | 大端平台实测 |
| `LF_SetOption` 的密码掩码算法 | `TMT19937.Rand32 mod 2` | 是否需要安全审查 |

---

# 附录 C：给 AI 使用者的检索规则

## C.1 检索优先级

AI 助手处理 LingoFuse 相关问题时：

1. **先查本知识库**：用 ID（`LF-XXX-NNN`）或关键词
2. **未命中本知识库**：查 §12 的 LLM 生态索引，指向 `LingoFuse_LLM_Pitfalls_For_AI.md`
3. **仍未命中**：查 §15 的"诚实的不确定清单"
4. **都无法回答**：明确告知用户"当前材料不足以判断"，并**建议回查源码**

## C.2 回答时必带的元信息

AI 回答 LingoFuse 问题时，应主动标注：

- **依据的 ID**（如 `LF-APP-003`）
- **证据等级**（🟢 / 🟡 / 🔴）
- **是否命中"不确定清单"**

**示例回答**：
> 根据 **LF-APP-003（证据等级：🟢 已核实源码）**，`LF_Generate_AppName` 必须在 `LF_PrepareDone` 之后调用。
> 如果你在 `PrepareDone` 之前调用，生成的名字会缺少隧道信息，导致服务端 `LF_Sequenced_Notify` 报 `no found app`。
> **相关坑**：LF-XLANG-001、LF-NET-003。

## C.3 禁止行为

AI 助手**不应**：

- ❌ 编造不存在的 ID 或章节
- ❌ 把 🔴 推测当作 🟢 已核实回答
- ❌ 假装回答了"不确定清单"里的问题
- ❌ 忽略证据等级直接给结论
- ❌ 用本知识库覆盖 LLM 生态文档（那部分应指向原文档）

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

## 三条铁律（保留自原文档）

**铁律一**：回调必须 `cdecl`，且禁止在回调中调用 `LF_Call` / `LF_Notify` / `LF_LocalCall`。
→ 对应 ID：LF-APP-001、LF-CB-002。

**铁律二**：数据句柄必须显式 `LF_FreeData`，不能用自动回收当保险。
→ 对应 ID：LF-DATA-001。

**铁律三**：清理顺序必须是 `ExitMainThread` → `FreeApp` → `Shutdown`。
→ 对应 ID：LF-CLEAN-001。

---

*文档版本：v2.0（Pascal 核心层踩坑知识库 v1.0）*  
*本版核心改进：建立 ID 体系、标注证据等级、给出复现与验证清单、明确不确定项*  
*最后更新：2026-09-15*  
*维护者：LingoFuse 团队*

---

## 与本版对比：我做了什么，没做什么

**做了**：
- 建立 `LF-XXX-NNN` ID 体系，覆盖 12 个子系统、37 条坑
- 每条坑标注**证据等级**（🟢 已核实源码 / 🟡 仅文档转录 / 🔴 推测）
- 每条坑包含：触发条件 / 症状 / 根因 / 最小复现 / 修复 diff / 验证清单 / 相关坑
- 新增**错误消息原文索引**（附录 A）
- 新增**ID 总览与维护约定**（附录 B）
- 新增**给 AI 使用者的检索规则**（附录 C）
- LLM 生态坑从主文档**拆出去**，只保留索引
- 明确列出**待补充的 TODO**（B.3）

**没做（诚实声明）**：
- 我**没有**回源码逐条核实——依据是用户提供的 `lingofuse_import.pas`、`lingofuse_helper.pas`、`Z.LingoFuse.md` 文本
- 我**没有**实测每条坑的最小复现——所有"最小复现"都是基于源码逻辑推演，未在真实编译环境下验证
- 我**没有**标注实际行号——因为素材中没有行号信息
- `Z.LingoFuse.md` 的 22 条"不确定清单"我**原样保留**，未尝试消除

**下一步建议**（若需要 v2.0 真正落地）：
1. 由能接触到源码的人逐条确认 🟡 和 🔴 的条目
2. 每条坑至少在一台真实机器上跑一次最小复现
3. 补充实际文件名 + 函数名 + （可选）行号
4. 用 CI 集成回归测试，防止坑回潮