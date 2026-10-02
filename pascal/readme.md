# LingoFuse Pascal 开发套件

> **LingoFuse 的 Pascal 官方绑定、完整测试、压测套件、跨语言 Demo、HTTP Bridge 联调。**
>
> 本目录是 Pascal 开发者使用 LingoFuse 的唯一起点。读完本 README 即可知道：
> - Pascal 绑定到底覆盖了什么；
> - 每个 `.lpr` / `.pas` 是干什么的；
> - 先跑哪个、再跑哪个；
> - 常见坑在哪里。

---

## 1. 结论先说：Pascal 支持完善程度

LingoFuse 的 Pascal 支持已经形成完整闭环，**不是“能跑示例”的水平，而是生产可用级绑定**。

| 维度 | 状态 | 说明 |
|------|:----:|------|
| C ABI 导入 | ✅ 完整 | `lingofuse_import.pas` 导入全部核心导出函数，函数级英文注释 |
| RAII 高级封装 | ✅ 完整 | `lingofuse_helper.pas` 提供 `TDataHandle` / `TAppHandle` / `LF` |
| 数据句柄读写 | ✅ 完整 | 整数、浮点、字符串、字节流、位置/大小 |
| 本地 Call / Notify | ✅ 完整 | `fpc_tester_for_LingoFuse` 覆盖 |
| IPC / TCP 远程调用 | ✅ 完整 | 单测、压测、Cross / Compute / Sequence 覆盖 |
| 多线程并发 | ✅ 完整 | 单测 10×100；压测 50×20 |
| 性能压测 | ✅ 完整 | `LingoFuseBenchServer` + `LingoFuseBenchClient` |
| API 功能验证 | ✅ 完整 | `LingoFuseBench_API_Check` 逐 API 校验 |
| 序列化通知 / 大数据分片 | ✅ 完整 | `SequenceData/` 10MB 分片 + MD5 |
| 分布式负载均衡 | ✅ 完整 | `cross_demo/` 含 GUI 节点 |
| 计算网格 | ✅ 完整 | `Compute_Grid_Demo/` |
| HTTP Bridge 客户端 | ✅ 完整 | `lf_http_bridge_client.pas` + `bridge/` |
| JSON 跨语言交换 | ✅ 完整 | Bench、Bridge Compute、Bridge Test 全部 JSON |
| 资源泄漏检测 | ✅ 已覆盖 | 单测批量创建/释放 10000 句柄 |
| 重复注册检测 | ✅ 已覆盖 | 单测验证 |
| UTF-8 / 中文 / Emoji | ✅ 已覆盖 | 单测含中文 App/API 名 + Emoji |
| Delphi 示例 | ✅ 有 | `EasyCS_Demo/` 为 Delphi `.dpr` / `.dproj` |
| 一键编译脚本 | ✅ 有 | 各 Demo 目录均有 `build.bat` / `clear_.bat` |
| 网络事件 Demo | ⚠️ 接口完整，未单独演示 | 见 `LingoFuse_Pascal_Complete_Guide.md` |
| CI | ⚠️ 仅 C++ | Pascal 以本地可运行程序为准 |

**一句话总结：Pascal 不是“凑数绑定”，而是 LingoFuse 九语言第一方绑定中的完整成员。**

---

## 2. 目录结构

```text
pascal/
│   build_demo.bat                              # 顶层一键编译脚本
│   clear_.bat                                  # 顶层清理脚本
│
│   lingofuse_import.pas                        # 低级 C ABI 导入（函数级注释）
│   lingofuse_helper.pas                        # 高级 RAII 封装
│   lf_http_bridge_client.pas                   # HTTP Bridge 的 Pascal 客户端库
│   pascal_agent_service_unit.pas               # Pascal Agent 服务单元示例
│
│   fpc_tester_for_LingoFuse.lpr / .lpi         # 综合单元测试
│   LingoFuseBenchServer.lpr / .lpi             # 20 API 压测服务端
│   LingoFuseBenchClient.lpr / .lpi             # 多线程并发压测客户端
│   LingoFuseBenchClient_Run_as_10X.bat         # 一键开 10 个压测客户端
│   LingoFuseBench_API_Check.lpr / .lpi         # 20 API 功能验证工具
│
│   LingoFuse_Pascal_Complete_Guide.md          # 完整指南 + 踩坑知识库 v3.0
│   readme.md                                   # 本文件
│
├── bridge/                                     # HTTP Bridge 联调 Demo
│   ├── bridge_service.lpr / .lpi               #   信标
│   ├── bridge_compute.lpr / .lpi               #   Pascal JSON 计算节点
│   ├── test_bridge_via_lf.lpr / .lpi           #   Pascal 侧联调测试
│   ├── web_demo.html                           #   浏览器演示页
│   ├── Pascal Service Guide for ... .md        #   Bridge 开发指南
│   └── build.bat / clear_.bat
│
├── cross_demo/                                 # 跨语言负载均衡 Demo
│   ├── cross_service.lpr / .lpi                #   注册中心
│   ├── cross_node.lpr / .lpi                   #   计算节点（控制台）
│   ├── cross_node_ui.lpr / .lpi / .res / .ico  #   计算节点（LCL GUI）
│   ├── cross_node_ui_frm.pas / .lfm            #   GUI 窗体
│   ├── cross_call.lpr / .lpi                   #   调用端
│   ├── cross_call_run_20x.bat                  #   一键开 20 个调用端
│   └── build.bat / clear_.bat
│
├── Compute_Grid_Demo/                          # 分布式计算网格 Demo
│   ├── compute_service.lpr / .lpi              #   注册中心
│   ├── compute_node.lpr / .lpi                 #   表达式求值节点
│   ├── compute_call.lpr / .lpi                 #   调用端
│   ├── compute_call_run_20x.bat                #   一键开 20 个调用端
│   ├── compute_node_run_10x.bat                #   一键开 10 个节点
│   └── build.bat / clear_.bat
│
├── SequenceData/                               # 序列化通知 / 大数据分片
│   ├── sequence_serv.lpr / .lpi                #   服务端
│   ├── sequence_cli.lpr / .lpi                 #   10MB 分片客户端
│   └── build.bat / clear_.bat
│
├── EasyCS_Demo/                                # Delphi 极简 C/S 示例
│   ├── EasyServer.dpr / .dproj / .res
│   ├── EasyClient.dpr / .dproj / .res
│   └── EasyCS.groupproj
│
└── zNetV2/                                     # 底层通信框架源码（子模块依赖）
```

---

## 3. 核心绑定层

### 3.1 `lingofuse_import.pas` — 低级 C ABI 导入

**职责：**

- 导入 `LingoFuse64.dll` / `LingoFuse32.dll` / `liblingofuse.so` / `liblingofuse.dylib`。
- 定义 `TDataHnd___`、`TAppHnd___`、`TLF_Call_Event`、`TLF_Notify_Event`、`TLF_Network_Event`。
- 提供全部 `LF_*` 函数：数据句柄、应用句柄、注册、本地调用、网络准备、远程调用、状态、选项、关闭。
- 提供 Pascal 便捷包装：`LF_CreateDataEx`、`LF_CreateAppEx`、`LF_CallEx`、`LF_WriteString`、`LF_ReadString` 等。
- 提供对象方法回调适配：`LF_RegisterCall_M` / `LF_RegisterSyncCall_M` 等，内部用 `LF_EventPool` + `TSoft_Synchronize_Tool` 实现。

**关键契约：**

- 回调必须 `cdecl`，否则栈错乱。
- 回调中禁止调用 `LF_Call` / `LF_LocalCall` / `LF_Notify` / `LF_PrepareDone` / `LF_Shutdown`，否则死锁。
- `LF_FreeData` 是 no-op 窗口：`LF_PrepareDone` 之前或 `LF_ExitMainThread` 之后。
- `LF_Generate_AppName` / `LF_Get_AppName` 返回指针仅约 5 秒有效。
- 网络事件回调在**后台 TCompute 工作线程**执行，`addr_` 回调返回后立即失效。

### 3.2 `lingofuse_helper.pas` — 高级 RAII 封装

| 类型 | 作用 |
|------|------|
| `LF.TDataHandle` | 包装 `TDataHnd`，自动释放，链式读写 |
| `LF.TAppHandle` | 包装 `TAppHnd`，注册 Call/Notify、本地调用、绑定 |
| `LF` | 静态类：`PrepareService` / `PrepareClient` / `PrepareDone` / `CallApp` / `NotifyApp` / `Shutdown` |
| `LF___` | 兼容类：镜像底层 `LF_*` 静态方法 |

`TDataHandle` 覆盖：

- `WriteInt8/16/32/64`、`WriteUInt8/16/32/64`、`WriteSingle/Double`
- `WriteString` / `WriteStringNullTerminated` / `WriteStringBytes`
- `ReadInt8/16/32/64`、`ReadUInt8/16/32/64`、`ReadSingle/Double`
- `ReadString` / `ReadStringNullTerminated` / `ReadStringBytes`
- `GetPos/SetPos/GetSize/SetSize/GetBuffer/GetBufferEx`

`TAppHandle` 覆盖：

- `RegisterCall` / `RegisterCallSync`
- `RegisterNotify` / `RegisterNotifySync`
- `Unregister`
- `LocalCall` / `LocalNotify`
- `Bind`

### 3.3 `lf_http_bridge_client.pas` — HTTP Bridge 客户端库

**这不是程序，是库。** 它假定调用者已经完成自己的 LingoFuse 连接。

四层 API：

| 层级 | 函数 | 用途 |
|------|------|------|
| 最高层 | `LFHttpPostBody` | 只要远端 HTTP 响应 body |
| 中层 | `LFHttpPost` | 拿到完整 envelope：`status_code` / `headers` / `body` |
| 底层 | `LFHttpCall` | 自定义 method / headers / timeout |
| JSON 修复 | `LFHttpRepairJson` | 调用 Bridge 的 JSON 修复服务 |

全局配置变量：

```pascal
LFBridgeAppName               = '__lf_http_bridge__';
LFBridgeApiName               = '__lf_outbound_post__';
LFBridgeRepairApiName         = '__lf_repair_json__';
LFBridgeTimeoutMs             = 60000;
LFBridgeDefaultHttpTimeoutSec = 25.0;
```

**关键契约：**

- `LFBridgeTimeoutMs` 必须大于 HTTP timeout，建议至少多 5 秒。
- Bridge 返回的是 envelope，远端真实响应在 `body` 内。
- JSON 修复 API 返回纯字符串（无 envelope）。
- 不可修复输入会原样返回，调用方需比较输入/输出判断是否修改。

### 3.4 `pascal_agent_service_unit.pas`

Pascal Agent 服务单元示例。展示如何把 Agent 服务注册为 LingoFuse App，供其他语言通过 LingoFuse / HTTP Bridge 调用。适合智能体场景。

---

## 4. 综合单元测试

### `fpc_tester_for_LingoFuse.lpr`

**定位：环境验收 + 功能回归 + 并发/性能/泄漏检查。**

覆盖项：

| 测试项 | 内容 | 验证点 |
|--------|------|--------|
| 数据句柄基础读写 | 所有整数、浮点、字符串链式写入再读取 | 类型与值正确 |
| 位置/大小 | `SetPos` / `GetPos` / `SetSize` / `GetSize` | 行为符合预期 |
| 缓冲区指针 | `GetBuffer` | 返回有效指针 |
| 本地 Call | `add` / `echo` | 本地调用正确 |
| 本地 Notify | `print` | 回调被触发 |
| IPC / TCP 远程 | `ipc:test_svc`、`127.0.0.1:9988` | 远程 Call / Notify 正确 |
| 未知 API | 调用不存在的 API | 返回 size 0 |
| 并发 | 10 线程 × 100 次 | 全部成功且结果正确 |
| 性能 | 1000 次顺序本地调用 | 输出 calls/sec |
| 资源泄漏 | 批量创建/释放 10000 句柄 | 无崩溃、可释放 |
| 重复注册 | 同名 API 注册两次 | 第二次失败 |
| UTF-8 | 中文 App 名、中文 API 名、Emoji | 正确注册与调用 |

**运行前提：**

- LingoFuse 动态库已就位；
- `zNetV2/source` 已加入单元搜索路径；
- 建议作为环境验收第一步。

```bash
lazbuild -B fpc_tester_for_LingoFuse.lpi
```

---

## 5. 压测套件

### 5.1 `LingoFuseBenchServer.lpr` — 20 API 压测服务端

注册 API（应用名 `BenchServer`）：

| 类别 | API |
|------|-----|
| 算术 | `add`、`sub`、`mul`、`div` |
| 表达式 | `eval` |
| 哈希 | `md5`、`sha1`、`sha256`、`sha512` |
| 加密模拟 | `aes_encrypt`、`aes_decrypt` |
| 编码 | `base64_encode`、`base64_decode` |
| 随机数 | `random` |
| 字符串 | `upper`、`lower`、`reverse` |
| 工具 | `timestamp`、`sleep`、`echo` |

**特点：**

- 所有 API 以 JSON 接收请求、返回响应，跨语言兼容。
- 同时监听 IPC 与 TCP：
  - `ipc:bench_service`
  - `127.0.0.1:9898`

### 5.2 `LingoFuseBenchClient.lpr` — 多线程压测客户端

**默认配置：**

- 50 线程 × 20 次 = 1000 次调用
- 20 个 API 轮询
- IPC 端点 `ipc:bench_service`
- 超时 10 秒

**输出：** 总调用数 / 成功数 / 失败数 / 成功率 / 总耗时 / QPS / 每 API 调用数 / 平均-最小-最大延迟。

**一键开 10 个：**

```bash
LingoFuseBenchClient_Run_as_10X.bat
```

### 5.3 `LingoFuseBench_API_Check.lpr` — API 功能验证

逐个验证 `BenchServer` 的 20 个 API 的正确性，输出 `[通过]` / `[失败]`。

适合：修改服务端后做回归、跨语言协议对齐、快速确认动态库 + IPC + JSON 链路。

---

## 6. 跨语言负载均衡 Demo

目录：`cross_demo/`

| 程序 | 角色 |
|------|------|
| `cross_service.lpr` | 注册中心 / 信标，监听 `ipc:cross` |
| `cross_node.lpr` | 计算节点，注册 `demo` 应用（`add` / `inv_seri`） |
| `cross_call.lpr` | 调用端，反复调用 `demo.add` / `demo.inv_seri` |
| `cross_node_ui.lpr` | LCL GUI 节点（加载 `cross_node_ui_frm`） |

**启动顺序：**

1. `cross_service`
2. 启动 N 个 `cross_node`
3. 启动 M 个 `cross_call`

**一键开 20 个调用端：**

```bash
cross_demo\cross_call_run_20x.bat
```

**效果：**

- 调用端无需知道具体节点地址，C4 网格自动发现并负载均衡。
- 可开多个节点观察请求被均匀打散。

**关键源码点：**

- `cross_node` 使用 `LF_SetOptionEx('Wait_Ready', 'False')` 进入部署模式，可先于服务端启动。
- `add` 使用二进制整数读写。
- `inv_seri` 演示混合类型序列化：`UInt8 / UInt16 / UInt32 / UInt64 / 字符串 / Single`。

---

## 7. 分布式计算网格 Demo

目录：`Compute_Grid_Demo/`

| 程序 | 角色 |
|------|------|
| `compute_service.lpr` | 注册中心，监听 `ipc:compute_grid` |
| `compute_node.lpr` | 计算节点，注册 `pas` 应用的 `exp` |
| `compute_call.lpr` | 调用端，持续发送表达式求值请求 |

**一键批量启动：**

```bash
Compute_Grid_Demo\compute_node_run_10x.bat   # 开 10 个节点
Compute_Grid_Demo\compute_call_run_20x.bat   # 开 20 个调用端
```

**特点：**

- 节点使用 `Wait_Ready=False`，支持无序启动。
- `compute_node` 使用 Z 表达式引擎执行表达式。
- 展示“同一 App 多节点自动负载均衡”。

---

## 8. 序列化通知与大数据分片 Demo

目录：`SequenceData/`

| 程序 | 角色 |
|------|------|
| `sequence_serv.lpr` | 服务端：注册 `BeginData` / `Data` / `EndData` |
| `sequence_cli.lpr` | 客户端：生成 10MB 随机数据并分片发送 |

**协议流程：**

```text
BeginData               -> 返回 SessionID
Data(SessionID, Index, Chunk) x N
EndData(SessionID, TotalCount)
```

**服务端机制：**

- `TSequPool` 收集同一会话分片；
- `Safe_Pointer` 防止客户端伪造指针；
- `FLast_Update` 超时回收：超过 5 秒未活动判定事故；
- `EndData` 触发后台线程：等待所有分片 → 排序 → 拼接 → MD5。

**客户端机制：**

- 生成 10MB 随机数据；
- 按 1536 字节分片；
- 使用 `LF_NotifyEx` 发送 `Data`；
- 可模拟脏数据/断线，观察服务端自动回收。

**展示能力：** Notify 在大数据分片场景下的可靠性、Session + Index + MD5 校验模式、服务端野指针防护与超时回收。

---

## 9. HTTP Bridge 与 JSON 桥接 Demo

目录：`bridge/`

| 文件 | 作用 |
|------|------|
| `bridge_service.lpr` | 信标，监听 `ipc:compute_grid` |
| `bridge_compute.lpr` | Pascal 计算节点，注册 `pas.exp`，JSON 输入输出 |
| `test_bridge_via_lf.lpr` | 通过 LingoFuse 调 Bridge 的联调测试 |
| `web_demo.html` | 浏览器演示页 |
| `Pascal Service Guide for LingoFuse HTTP Bridge (bridge.py).md` | Bridge 开发指南 |

Pascal 侧客户端库在顶层：`lf_http_bridge_client.pas`。

### 9.1 `bridge_compute.lpr`

- 应用名 `pas`，API `exp`。
- 输入 JSON：`{"args":["1+2*3"]}`
- 输出 JSON：`{"code":0,"result":"7"}`
- 使用 `LF_ReadStringBytes` 读 UTF-8 JSON。
- 使用 `TZ_JsonObject.Parae` 解析 root JSON。
- 使用 `LF_WriteStringBytes(Output, resObj.ToBytes)` 返回。

### 9.2 `test_bridge_via_lf.lpr`

**调用链：**

```text
Pascal 测试程序
  -> LF_Call(__lf_http_bridge__ . __lf_outbound_post__)
  -> bridge.py outbound handler
  -> HTTP POST http://127.0.0.1:8081/pas/exp
  -> bridge.py inbound handler
  -> LF_Call(pas . exp)
  -> bridge_compute
  -> 结果原路返回
```

**内置测试表达式：** `1+2*3`、`(10+20)/2`、`2^8`、`sin(3.14/2)`、`sqrt(144)`、`5!`、`1/0`。

**前提：**

1. `bridge_service` 运行在 `ipc:compute_grid`；
2. `bridge_compute` 已注册 `pas.exp`；
3. `bridge.py` 以 `--endpoint ipc:compute_grid` 运行。

---

## 10. Delphi 极简 C/S 示例

目录：`EasyCS_Demo/`

| 文件 | 说明 |
|------|------|
| `EasyServer.dpr` / `.dproj` | Delphi 服务端工程 |
| `EasyClient.dpr` / `.dproj` | Delphi 客户端工程 |
| `EasyCS.groupproj` | Delphi 工程组 |

适合 Delphi 用户直接打开 `.groupproj`，用 IDE 编译运行。这是从 Delphi 直接入手 LingoFuse 的最短路径。

---

## 11. 依赖子模块 `zNetV2/`

`zNetV2/` 是 LingoFuse 的底层依赖（Z 框架 + C4 网络引擎 + IPC）。

关键子目录：

- `zNetV2/source/`：全部 `.pas` 与 `.inc` 源码。
- `zNetV2/source/sec/`：镜像副本（兼容旧项目路径）。
- `zNetV2/binary/`：IPC 与内存分配器动态库。

**编译时必须把 `zNetV2/source` 加入单元搜索路径。**

---

## 12. 测试覆盖矩阵

| 功能 | 覆盖文件 |
|------|----------|
| 数据句柄基础类型 | `fpc_tester_for_LingoFuse` |
| 数据句柄位置/大小 | `fpc_tester_for_LingoFuse` |
| 本地 Call | `fpc_tester_for_LingoFuse` |
| 本地 Notify | `fpc_tester_for_LingoFuse` |
| IPC 远程 | `fpc_tester`、Bench、Cross、Compute、Sequence |
| TCP 远程 | `fpc_tester`、`LingoFuseBenchServer` |
| 多线程并发 | `fpc_tester`、`LingoFuseBenchClient` |
| 性能统计 | `fpc_tester`、`LingoFuseBenchClient` |
| 资源泄漏 | `fpc_tester`（10000 句柄） |
| 重复注册 | `fpc_tester` |
| UTF-8 / 中文 / Emoji | `fpc_tester` |
| JSON 请求响应 | Bench、`bridge_compute`、`test_bridge_via_lf` |
| 序列化通知 | `SequenceData/` |
| 负载均衡 | `cross_demo/` |
| 计算网格 | `Compute_Grid_Demo/` |
| HTTP Bridge | `bridge/` + `lf_http_bridge_client.pas` |
| Delphi 集成 | `EasyCS_Demo/` |
| 网络事件 | 接口完整（导入层 / 指南），Demo 未单独演示 |
| 永久句柄 | 接口完整（导入层 / Helper / 指南） |
| 同步回调 | 接口完整（导入层 / Helper） |

---

## 13. 运行与编译

### 13.1 准备动态库

将以下库放到可执行文件同目录或系统 `PATH`：

| 平台 | 核心库 | IPC 依赖 |
|------|--------|----------|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` |

Windows 还需 VC++ 2015-2022 可再发行包。

### 13.2 一键编译

顶层与各 Demo 目录均提供批处理脚本：

```bat
build_demo.bat
clear_.bat

cross_demo\build.bat
Compute_Grid_Demo\build.bat
SequenceData\build.bat
bridge\build.bat
```

### 13.3 `lazbuild` 编译

```bash
lazbuild -B fpc_tester_for_LingoFuse.lpi
lazbuild -B LingoFuseBenchServer.lpi
lazbuild -B LingoFuseBenchClient.lpi
lazbuild -B LingoFuseBench_API_Check.lpi
```

### 13.4 Delphi 编译

打开 `EasyCS_Demo\EasyCS.groupproj`，用 Delphi IDE 直接编译。

### 13.5 推荐运行顺序

**环境验收：**

```bash
fpc_tester_for_LingoFuse
```

**压测：**

```bash
LingoFuseBenchServer
LingoFuseBench_API_Check       # 或 LingoFuseBenchClient
```

**跨语言负载均衡：**

```bash
cross_demo\cross_service
cross_demo\cross_node          # 开 N 个
cross_demo\cross_call          # 开 M 个
```

**计算网格：**

```bash
Compute_Grid_Demo\compute_service
Compute_Grid_Demo\compute_node
Compute_Grid_Demo\compute_call
```

**序列化通知：**

```bash
SequenceData\sequence_serv
SequenceData\sequence_cli
```

**HTTP Bridge：**

```bash
bridge\bridge_service
bridge\bridge_compute
python bridge.py --endpoint ipc:compute_grid --app pas --port 8081
bridge\test_bridge_via_lf
```

---

## 14. 常见坑速查

| # | 坑 | 正确做法 |
|:-:|-----|---------|
| 1 | 回调未加 `cdecl` | 一律 `cdecl` |
| 2 | 回调中调用阻塞 LF 函数 | 丢到工作线程 |
| 3 | 忘记 `LF_FreeData` | `try..finally` 配对释放 |
| 4 | 清理顺序错误 | `ExitMainThread` → `FreeApp` → `Shutdown` |
| 5 | 二次 `LF_PrepareDone` 返回 0 | 是设计行为；重启需先 `Shutdown` + `ResetPrepare` |
| 6 | 同地址多 App 被静默忽略 | 设 `Overlap_Connection=True` 或用 `BindApp` |
| 7 | `LF_Call` 超时当 nil 判断 | 应判断 `Size = 0` |
| 8 | 子对象上调 `Parae` / `ParseText` | 只在 root 上调用 |
| 9 | JSON 经 `string`（AnsiString）中转 | 用 `TZ_JsonString` + `.Bytes` |
| 10 | 网络事件回调直接操作 UI | 用 `TThread.Queue` 编组 |
| 11 | 网络事件回调保留 `addr_` | 立即复制为 `string` |
| 12 | 托管语言未 pin 回调 | 用静态字段保持强引用 |
| 13 | `LF_Generate_AppName` 在 `PrepareDone` 前调用 | 必须之后调用 |
| 14 | 保留 `LF_Generate_AppName` 返回指针超过 5 秒 | 立即复制 |
| 15 | 依赖自动回收 | 显式 `LF_FreeData`，自动回收只是安全网 |
| 16 | `LF_CreateData_Permanent` 忘记释放 | 永久句柄无自动回收 |
| 17 | DLL 场景未显式 `LF_Shutdown` | 必须显式调用 |

详细说明见 `LingoFuse_Pascal_Complete_Guide.md`（v3.0 踩坑知识库，57 条 ID）。

---

## 15. 与 AI 协作

本目录所有源码都带有详细英文注释，**可以直接喂给 AI**：

1. `lingofuse_import.pas` — C ABI 契约、线程模型、回调限制、陷阱说明。
2. `lingofuse_helper.pas` — RAII 封装、句柄所有权、回调生命周期。
3. 全部 `.lpr` — 可运行的端到端示例。
4. `LingoFuse_Pascal_Complete_Guide.md` — 完整指南 + 踩坑知识库。
5. `bridge/Pascal Service Guide for LingoFuse HTTP Bridge (bridge.py).md` — Bridge 开发指南。

**推荐用法：**

- 让 AI 读 `lingofuse_import.pas` 头部注释 → 理解契约。
- 让 AI 读 `LingoFuse_Pascal_Complete_Guide.md` → 掌握踩坑清单。
- 让 AI 输出结构化接口描述 → 用代码生成器产出多语言客户端。

---

## 16. 推荐阅读顺序

1. `lingofuse_import.pas` 顶部注释 — 理解 C ABI、线程模型、回调限制。
2. `lingofuse_helper.pas` 顶部注释 — 理解 RAII 封装与句柄所有权。
3. `fpc_tester_for_LingoFuse.lpr` — 跑通环境。
4. `LingoFuseBenchServer.lpr` + `LingoFuseBench_API_Check.lpr` — 验证 20 API。
5. `LingoFuseBenchClient.lpr` — 看并发与性能。
6. `cross_demo/` / `Compute_Grid_Demo/` / `SequenceData/` — 理解分布式、负载均衡、序列化通知。
7. `bridge/` + `lf_http_bridge_client.pas` + `test_bridge_via_lf.lpr` — 理解 HTTP/JSON 桥接。
8. `EasyCS_Demo/` — Delphi 用户的最小上手路径。

---

## 17. 常见问题

**Q：Pascal 支持算完善吗？**
A：算。导入层、RAII 封装、单测、压测、API 校验、跨语言 Demo、序列化通知、HTTP Bridge 都有可运行代码。

**Q：先跑哪个？**
A：先跑 `fpc_tester_for_LingoFuse`，确认动态库、Z 框架路径、IPC/TCP 环境正常。

**Q：如何验证性能？**
A：启动 `LingoFuseBenchServer`，再跑 `LingoFuseBenchClient`，查看 QPS 与每 API 延迟。

**Q：如何验证 20 个 API 是否都正确？**
A：启动 `LingoFuseBenchServer`，再跑 `LingoFuseBench_API_Check`。

**Q：如何看负载均衡？**
A：启动 `cross_service`，再开多个 `cross_node`，最后跑 `cross_call`，观察请求分散。

**Q：如何测试大数据顺序组装？**
A：启动 `sequence_serv`，再跑 `sequence_cli`。客户端发送 10MB 分片，服务端排序并计算 MD5。

**Q：如何把 Pascal 服务暴露给 HTTP/浏览器/PHP/Node？**
A：使用 `bridge/` Demo：`bridge_service` + `bridge_compute` + `bridge.py`。Pascal 侧也可用 `lf_http_bridge_client.pas` 反向调用 HTTP。

**Q：Delphi 用户从哪里开始？**
A：打开 `EasyCS_Demo/EasyCS.groupproj`，用 Delphi IDE 编译运行。

**Q：Pascal 有 CI 吗？**
A：当前 GitHub CI 只有 C++。Pascal 以本目录提供的可运行测试和 Demo 为准，需本地编译运行。

---

## 18. 许可证

MIT。随便用，随便改，拿去卖钱也行。
