# LingoFuse

> **智能体时代的跨语言通讯底座 —— 让所有编程语言平等对话。**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**LingoFuse** 是一个跨语言、跨进程、跨机器的 RPC 框架。  
不写 IDL，不生成桩代码，不搭 HTTP 服务——任何语言写的函数，任何其他语言都能直接调。

---

## 🚀 相比其它 RPC 库的优势

| 特性 | LingoFuse | gRPC | REST | 传统消息队列 |
|------|-----------|------|------|--------------|
| 同机延迟 | **< 1 ms** | ~5-8 ms | ~10-20 ms | ~2-5 ms |
| 吞吐量 | **12k+/s** | ~3k/s | ~1k/s | ~5k/s |
| 服务发现 | ✅ 内置 | ❌ 需 etcd | ❌ 需 Nginx | ❌ 需 ZooKeeper |
| 负载均衡 | ✅ 内置 | ❌ 需 LB | ❌ 需 Nginx | ❌ 需客户端实现 |
| 顺序保证 | ✅ FIFO | ❌ | ❌ | ⚠️ 需单分区 |
| 断线重连 | ✅ 自动 | ❌ 需重试 | ❌ 需重试 | ⚠️ 需客户端实现 |
| 零拷贝 | ✅ | ❌ | ❌ | ❌ |
| 跨语言 | **30+ 种** | 需生成代码 | 需手动封装 | 需协议定义 |
| IDL 依赖 | **无** | 必需 | 无（但需文档） | 必需 |
| 桩代码生成 | **可选（自动）** | 必需 | 无 | 无 |

**一句话**：比 gRPC 快 5-8 倍，比 REST 快 10-20 倍，自带全套中间件，且不需要 IDL。

---

## 🔬 架构技术特点

LingoFuse 之所以能同时做到"低延迟、高吞吐、跨语言、零 IDL"，源于以下几个核心设计：

### 1. 二进制帧协议（Binary Framing）

- **定长头 + 变长体**：8 字节头部承载类型、长度、序号，避免文本协议的逐字符解析。
- **小端序统一**：跨平台（x86 / ARM / AArch64 / LoongArch）字节序一致，无需运行时转换。
- **分块传输**：超过 64 KB 的 payload 自动分块，单次调用不受帧大小限制。

### 2. 零拷贝数据通路

- **DataHandle 缓冲复用**：调用方和被调用方共享同一块缓冲区视图，避免中间拷贝。
- **UTF-8 + NUL 字符串**：字符串直接以字节流形态传输，不做转义、不做重编码。
- **指针级 I/O**：`LF_WriteBuffer` / `LF_ReadBuffer` 直接操作内部缓冲，绕过流抽象层。

### 3. 内置软同步（User-Space Synchronization）

- **`TSoft_Synchronize_Tool`**：用用户态 FIFO 队列替代内核事件，跨线程同步的开销降低一个数量级。
- **无需 `TThread.Synchronize`**：避免 DLL 场景下的死锁陷阱，同时兼容 RTL 主线程模型。
- **主线程可模拟**：`Begin_Simulator_Main_Thread` 允许把任意 TCompute 线程提升为"模拟主线程"，适配无 GUI 的服务端场景。

### 4. 自缩放线程池（TCompute）

- **按需生长 / 空闲回收**：空闲线程在 1 秒后自动退出，避免长期占用资源。
- **FIFO 派发**：调度线程与工作线程分离，任务顺序与提交顺序一致。
- **并行原语**：`ParallelFor` / `TThreadPost` / `TCompute.RunC` 全家桶，覆盖从单任务投递到块级并行的所有场景。

### 5. 顺序通知（Sequenced Notify）

- **每 (App, API) 一个专用线程**：保证同源消息严格 FIFO，跨 API 之间不互相阻塞。
- **自动线程回收**：5 分钟无流量自动终止，不产生空闲线程堆积。
- **多模态分块友好**：大 payload 通过分块协议流式传输，天然适配 LLM 流式输出。

### 6. 内存管理策略

- **`mimalloc` 内置**：默认内存分配器针对多线程、小对象高频分配做了优化。
- **`TAtomVar` / `AtomInc` 硬件原子**：跨线程共享计数无锁化，避免 `TCritical` 争抢。
- **对象池复用**：`TCritical` 底层实例、MT19937 随机数实例均按线程复用，构造开销趋近于零。

### 7. 信标与自动发现（Beacon）

- **应用级注册中心**：每个 App 的每个 API 自动广播到网络，客户端无需手动配置路由。
- **广播延迟 ~3 秒**：最终一致，抗网络抖动。
- **工具元数据**：参数名、类型、描述随广播一起传播，AI Agent 可直接消费。

---

## 🌍 多语言支持（平等列举）

| 语言 | 状态 | 说明 |
|------|------|------|
| **Pascal** | 🟢 生产就绪 | 原生 FFI，完整绑定 |
| **Python** | 🟢 生产就绪 | `pip install -e .` 即用 |
| **C++** | 🟢 生产就绪 | 原生 C ABI，零开销 |
| **Node.js / PHP / 浏览器** | 🌉 HTTP 桥接 | `bridge.py` 网关 |
| **C# / .NET** | 🚀 即将首推 | 见 [LingoFuse-csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent) |
| **Rust / Go / Java 等** | ⏳ 计划中 | 欢迎贡献绑定 |
| **aarch64 / loongarch64 / RISC-V** | 📱 边缘设备计划 | 持续移植中 |

> 🎯 **目标：让地球上 30+ 种编程语言，用同一个函数调用约定互相说话。**

---

## 🛠️ 代码生成器体系（已完结）

跨语言 RPC 最大的痛点是"为每种语言手写绑定"。LingoFuse 通过 **[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools)** 彻底解决了这个问题。

**给 LingoFuse-Tools 一份 Pascal 单元或 C 头文件，它自动产出多语言的服务端、调用端、以及配套 README 文档。**

### 三大生成器

| 工具 | 生成目标 | 协议 | 目标语言 |
|------|----------|------|----------|
| **code_decl_to_abi** | ABI 服务端 / 调用端 | LingoFuse 二进制 ABI | Pascal / Python / C++ |
| **code_decl_to_json_abi** | HTTP/JSON 服务端 / 调用端 | HTTP + JSON（经 bridge） | Pascal / Python / C++ / JavaScript |
| **code_decl_to_mcp** | MCP 工具提供者 | Model Context Protocol | Pascal / Python / C++ |

### 每个工具都是三入口

- **GUI**：桌面交互，可视化中间步骤
- **CLI**：脚本、CI、批处理
- **MCP API**：AI Agent 通过信标直接调用生成能力

### 每个工具都自带知识库

三个工具各自附带一份**自包含的知识库**（Markdown），涵盖 API 契约、线协议、类型映射、已知陷阱、调试树、扩展指南。

**把知识库喂给 AI，AI 即可全接管接口**——无需阅读源码，无需手写 MCP 封装。知识库和 MCP API 从同一份源生成，**永远不会偏离**。

> 📖 详见 [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools)

---

## 🤖 智能体神经网络通讯地基

LingoFuse 不只是 RPC，它是 **AI Agent 调用任意语言函数的底座**。

- **信标**：工具注册中心，AI 自动发现可用工具
- **Call + Notify**：请求-响应 + 流式推送
- **跨语言 FFI**：无论工具用什么语言，AI 无需感知
- **确定性序列化**：工具参数可复现、可审计
- **代码生成器体系**：一份声明 → 多语言 Agent 接入

基于 LingoFuse，社区正在构建多个语言的智能体分支：

| 分支 | 语言 | 状态 |
|------|------|------|
| [pasAgent v2](https://github.com/PassByYou888/LingoFuse-pasAgent) | Pascal | 🟢 已发布（纯文本智能体） |
| [pasAgent v3](https://github.com/PassByYou888/LingoFuse-pasAgent-v3) | Pascal | 🟢 已发布（多模态智能体） |
| [cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent) | C++ | 🚀 **即将首推** |
| [csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent) | C# / .NET | 🚀 **即将首推** |

**主仓库专注通讯底座，分支专注各自生态。** 未来会有更多语言的智能体分支接入。

---

## 📊 项目状态与路线图

### 当前状态：加速完结中

LingoFuse 已经进入 **良性发展阶段**：

| 板块 | 状态 | 说明 |
|------|------|------|
| **核心通讯层** | ✅ 稳定 | C4 引擎、二进制帧、DataHandle、软同步、线程池全部就绪 |
| **Pascal 绑定** | ✅ 生产就绪 | 完整 FFI + 助手层 + 示例 |
| **Python 绑定** | ✅ 生产就绪 | `pip install -e .` 即用 |
| **C++ 绑定** | ✅ 生产就绪 | 原生 C ABI + CMake 工程 |
| **HTTP 桥接** | ✅ 生产就绪 | `bridge.py` 网关，覆盖 Node.js / PHP / 浏览器 |
| **代码生成器体系** | ✅ **已完结** | [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) |
| **C++ 智能体** | 🚀 **即将首推** | [cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent) |
| **C# 智能体** | 🚀 **即将首推** | [csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent) |
| **更多语言绑定** | ⏳ 建设中 | Rust / Go / Java / … |

### 里程碑

- ✅ **通讯底座竣工** —— C4、软同步、线程池、信标
- ✅ **三语言绑定竣工** —— Pascal / Python / C++
- ✅ **代码生成器体系竣工** —— LingoFuse-Tools
- 🚀 **多语言智能体集群首推** —— C++ Agent、C# Agent
- ⏳ **全面竣工** —— 预计很快到来

**项目还在建设中，但已经在加速完结阶段。** 通讯底座已稳，绑定齐全，生成器体系闭环，剩下的只是把生态铺满。

---

## 📦 克隆必读

**本仓库有子模块，必须加 `--recursive`：**

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
```

忘了加？补救：

```bash
git submodule update --init --recursive
```

不加会编译失败（`Can't find unit Z.Core` 等）。

---

## 📚 依赖库

核心动态库位于 `Binary/` 目录：

| 平台 | 核心库 | IPC 依赖 | 内存分配器 |
|------|--------|----------|------------|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` | `libmimalloc.so`（可选） |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` | `libmimalloc.dylib`（可选） |

**部署方式**：将 `Binary/` 目录加入系统 `PATH`，或把动态库复制到可执行文件同目录。

Windows 下还需安装 **VC++ Redistributable**（`vc_redist.x64.exe` / `vc_redist.x86.exe`）。

---

## 📂 仓库结构

```
LingoFuse/
├── Binary/              # 预编译动态库（Win32 / Win64）
├── cpp/                 # C++ 绑定、示例、跨语言 Demo
├── pascal/              # Pascal 绑定、示例、基准测试、桥接
│   ├── bridge/          # HTTP 桥接相关
│   ├── Compute_Grid_Demo/
│   ├── cross_demo/
│   ├── EasyCS_Demo/     # C# 互操作示例
│   ├── SequenceData/    # 顺序通知示例
│   └── zNetV2/          # Z 框架核心（子模块）
├── Py/                  # Python 绑定、桥接、跨语言 Demo
│   ├── lingofuse/       # Python 包
│   └── cross/           # Node.js / PHP / WebJS 客户端
└── src/                 # Pascal 主库源码
```

---

## 📄 许可证

**MIT** —— 拿去用，拿去改，拿去卖，都不用来谢我。

---

## 🧓 关于作者

**老张（QQ: 600585）**

看不惯跨语言调用得写一箩筐胶水代码，干脆撸了 LingoFuse。  
现在又看不惯每种语言都得手写绑定，干脆把代码生成器也撸完了。  
欢迎来撩、来喷、来 PR——**Star 是最好的催更。**

---

*项目始于 2026 年，持续进化中。有问题提 Issue，急事加 Q。*  
*"让所有编程语言平等对话" —— 不是口号，是正在发生的事。*  
*"让 AI 接管所有语言的接口" —— 不是未来，是已经开始的现在。*