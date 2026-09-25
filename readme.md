# LingoFuse

> **智能体时代的跨语言通讯底座 —— 让所有编程语言平等对话。**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**LingoFuse** 是一个跨语言、跨进程、跨机器的 RPC 框架。  
不写 IDL，不生成桩代码，不搭 HTTP 服务——任何语言写的函数，任何其他语言都能直接调。

---

## ⭐ 核心亮点：AI 知识库体系已完善，AI 接管成功率接近绝对

> 不是宣传口号，工程现实

---

## 🚀 相比其它 RPC / IPC 方案的优势

| 特性 | LingoFuse | gRPC | REST | HTTP POST 体系¹ | SendMessage 体系² |
|------|-----------|------|------|----------------|------------------|
| 同机延迟 | **< 1 ms** | ~5-8 ms | ~10-20 ms | ~1-5 ms | ~0.05 ms（同进程） |
| 跨机支持 | ✅ 原生 | ✅ 需网关 | ✅ 需网关 | ✅ 原生 | ❌ 仅同进程 |
| 跨语言 | **30+ 种** | 需生成代码 | 需手动封装 | ✅ 天然 | ❌ 系统绑定 |
| 请求-响应 | ✅ Call | ✅ | ✅ | ✅ | ✅ 阻塞 |
| 流式 / 异步 | ✅ Notify | ⚠️ 需 stream | ❌ | ❌（除非 SSE） | ❌ |
| 类型安全 | ✅ 强类型 | ✅ 需 IDL | ❌ | ❌ | ✅ 同进程强类型 |
| 服务发现 | ✅ 内置 | ❌ 需 etcd | ❌ 需 Nginx | ❌ | ❌ |
| 负载均衡 | ✅ 内置 | ❌ 需 LB | ❌ 需 Nginx | ❌ | ❌ |
| 顺序保证 | ✅ FIFO | ❌ | ❌ | ❌ | ⚠️ 队列语义 |
| 断线重连 | ✅ 自动 | ❌ 需重试 | ❌ 需重试 | ❌ 需重试 | ❌ |
| 零拷贝 | ✅ | ❌ | ❌ | ❌ | ✅（同进程） |
| IDL 依赖 | **无** | 必需 | 无（但需文档） | 无 | 无 |
| 桩代码生成 | **可选（自动）** | 必需 | 无 | 无 | 无 |

> ¹ **HTTP POST 体系**：以 HTTP POST 为载体的 RPC 方案——JSON-RPC over HTTP、REST POST、SOAP 等。特点是天然跨机、跨语言，但延迟高、无流式、无服务发现、无负载均衡。  
> ² **SendMessage 体系**：Win32 `SendMessage`、同进程直接调用、LPC 等"同步阻塞"模型。特点是延迟极低、类型安全，但仅限同进程、不跨机、不跨语言。  
> 传统方案各有所长但互不覆盖；**LingoFuse 把两者的长处合并，并且跨机、跨语言、带发现。**

**一句话**：具备 HTTP POST 的跨机跨语言能力，具备 SendMessage 的极低延迟和强类型，同时还有流式、服务发现、负载均衡和顺序保证——一个方案全包。

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
- **知识库体系**：一份文档 → AI 全接管接口

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
| **核心通讯层** | ✅ 稳定 | C4 引擎、二进制帧、句柄、软同步、线程池全部就绪 |
| **Pascal 绑定** | ✅ 生产就绪 | 完整 FFI + 助手层 + 示例 |
| **Python 绑定** | ✅ 生产就绪 | `pip install -e .` 即用 |
| **C++ 绑定** | ✅ 生产就绪 | 原生 C ABI + CMake 工程 |
| **HTTP 桥接** | ✅ 生产就绪 | `bridge.py` 网关，覆盖 Node.js / PHP / 浏览器 |
| **代码生成器体系** | ✅ **已完结** | [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) |
| **AI 知识库体系** | ✅ **已完善** | 覆盖所有接口，AI 接管成功率接近绝对 |
| **C++ 智能体** | 🚀 **即将首推** | [cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent) |
| **C# 智能体** | 🚀 **即将首推** | [csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent) |
| **更多语言绑定** | ⏳ 建设中 | Rust / Go / Java / … |

### 里程碑

- ✅ **通讯底座竣工** —— C4、软同步、线程池、信标
- ✅ **三语言绑定竣工** —— Pascal / Python / C++
- ✅ **代码生成器体系竣工** —— LingoFuse-Tools
- ✅ **AI 知识库体系完善** —— AI 接管成功率接近绝对
- 🚀 **多语言智能体集群首推** —— C++ Agent、C# Agent
- ⏳ **全面竣工** —— 预计很快到来

**项目还在建设中，但已经在加速完结阶段。** 通讯底座已稳，绑定齐全，生成器体系闭环，知识库体系完善，剩下的只是把生态铺满。

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
再把知识库喂给 AI，让 AI 自己把接口全部接管——**这才是智能体时代该有的样子。**  
欢迎来撩、来喷、来 PR——**Star 是最好的催更。**

---

*项目始于 2026 年，持续进化中。有问题提 Issue，急事加 Q。*  
*"让所有编程语言平等对话" —— 不是口号，是正在发生的事。*  
*"让 AI 接管所有语言的接口" —— 不是未来，是已经开始的现在。*  
*"使用 AI 构建 LF 通讯体系的成功率接近绝对" —— 不是承诺，是知识库体系已经证明的事实。*