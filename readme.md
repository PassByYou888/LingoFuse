# LingoFuse

> **跨语言通讯地基。不写 IDL，不生成桩代码，不搭 HTTP 服务。**
>
> 任何语言写的函数，任何其他语言都能直接调。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Languages](https://img.shields.io/badge/languages-6%20first--party%20%2B%2030%20via%20tools-blue)]()
[![Latency](https://img.shields.io/badge/same--machine%20IPC-%3C1ms-brightgreen)]()

---

## 这是什么

LingoFuse 是一个跨语言、跨进程、跨机器的 RPC 框架。它的核心承诺只有一句：

**任何语言写的函数，任何其他语言都能直接调。**

不需要写 IDL，不需要生成桩代码，不需要搭 HTTP 服务。同机 IPC 延迟 < 1 ms，跨机原生支持，内置服务发现、负载均衡、FIFO 顺序保证和断线重连。

---

## 为什么需要它

跨语言调用目前的现实是这样的：

- 用 gRPC —— 要写 IDL，要生成桩代码，要搭网关，要维护 etcd
- 用 REST —— 延迟高，无流式，无服务发现，无类型安全
- 用 HTTP POST —— 天然跨机跨语言，但延迟高，无顺序保证，无服务发现
- 用同进程直接调用 —— 延迟极低，类型安全，但仅限同进程，不跨语言

**每一种方案都只覆盖了一部分场景。** LingoFuse 的目标是把这些长处合并，并且把每个短板补上。

| 特性 | LingoFuse | gRPC | REST | HTTP POST 体系¹ | SendMessage 体系² |
|------|-----------|------|------|----------------|------------------|
| 跨机支持 | ✅ 原生 | ✅ 需网关 | ✅ 需网关 | ✅ 原生 | ❌ 仅同进程 |
| 跨语言 | **6 种一方 + 30+ 种经工具链** | 需生成代码 | 需手动封装 | ✅ 天然 | ❌ 系统绑定 |
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
> ² **SendMessage 体系**：Win32 `SendMessage`、同进程直接调用、LPC 等“同步阻塞”模型。特点是延迟极低、类型安全，但仅限同进程、不跨机、不跨语言。

**一句话**：具备 HTTP POST 的跨机跨语言能力，具备 SendMessage 的极低延迟和强类型，同时还有流式、服务发现、负载均衡和顺序保证——一个方案全包。

> ⚠️ **关于并发性能的立场**
>
> LingoFuse 把应用的**稳定性**放在第一位，并发性能往后挪移。这不是某一版本的临时取舍，而是项目在未来所有版本中都会坚持的趋势：**稳定第一，并发次要。**
>
> 理由很直接：LingoFuse 是跨语言通讯地基。地基本身不出问题，上面的建筑才不会塌。一个在高并发下会偶发崩溃、丢消息或死锁的通讯层，延迟再低也没有意义。稳定性是前提，并发吞吐是在稳定前提下的优化项。
>
> 因此，本项目不在主 readme 中做并发性能的横向对比。如果你关心并发与压力下的实际表现，请直接看 `test/` 目录——那里有可运行的测试程序和实测指南，事实以实测为准。

---

## 语言支持

### 第一方绑定（仓库内，生产就绪）

| 语言 | 状态 | 说明 |
|------|------|------|
| **Pascal** | 🟢 生产就绪 | 原生 FFI，完整绑定，核心引擎来源 |
| **Python** | 🟢 生产就绪 | `pip install -e .` 即用 |
| **C++** | 🟢 生产就绪 | 原生 C ABI，零开销，含并发压力测试 |
| **C# / .NET** | 🟢 生产就绪 | 完整 .NET 绑定，服务端/调用端全支持 |
| **TypeScript** | 🟢 生产就绪 | 完整类型定义 + 源码 + 编译产物 + 示例 + 测试 |
| **JavaScript** | 🟢 生产就绪 | CommonJS + ESM 双入口 |

### 经代码生成器 / 桥接支持

| 语言 / 平台 | 方式 |
|-------------|------|
| **Node.js / PHP / 浏览器** | `bridge.py` HTTP 网关 |
| **Rust / Go / Java / Kotlin / Swift / Ruby / Lua / Dart / Elixir / Julia / Zig / Nim / Crystal** | 经 LingoFuse-Tools 代码生成器接入 |
| **aarch64 / loongarch64 / RISC-V** | 边缘设备移植计划，持续推进中 |

### 代码生成器体系

跨语言 RPC 最大的痛点是“为每种语言手写绑定”。LingoFuse 通过 **[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools)** 解决了这个问题。

**给 LingoFuse-Tools 一份 Pascal 单元或 C 头文件，它自动产出多语言的服务端、调用端、以及配套 README 文档。**

| 工具 | 生成目标 | 协议 | 目标语言 |
|------|----------|------|----------|
| **code_decl_to_abi** | ABI 服务端 / 调用端 | LingoFuse 二进制 ABI | Pascal / Python / C++ / C# |
| **code_decl_to_json_abi** | HTTP/JSON 服务端 / 调用端 | HTTP + JSON（经 bridge） | Pascal / Python / C++ / C# / JavaScript |
| **code_decl_to_mcp** | MCP 工具提供者 | Model Context Protocol | Pascal / Python / C++ / C# |

每个工具都是**三入口**（GUI / CLI / MCP API），各自附带一份**自包含的知识库**（Markdown），涵盖 API 契约、线协议、类型映射、已知陷阱、调试树、扩展指南。

**把知识库喂给 AI，AI 即可全接管接口**——无需阅读源码，无需手写 MCP 封装。知识库和 MCP API 从同一份源生成，永远不会偏离。

> 📖 详见 [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools)

---

## 快速开始

**本仓库有子模块，必须加 `--recursive`：**

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
```

忘了加？补救：

```bash
git submodule update --init --recursive
```

不加会编译失败（`Can't find unit Z.Core` 等）。

### 最小示例：Pascal 服务端 + TypeScript 客户端

**Pascal 服务端：**

```pascal
App := LF.CreateApp('Calc', 'Calculator');
App.RegisterCall('add', 'Add two ints', nil, @AddCallback);
LF.PrepareService('0.0.0.0', '127.0.0.1:9898');
LF.PrepareDone;
```

**TypeScript 客户端：**

```typescript
import { Framework } from 'lingofuse-ts';

const lf = new Framework();
lf.prepareClient('127.0.0.1:9898');
const result = lf.call('Calc', 'add', Buffer.from([5, 0, 0, 0, 7, 0, 0, 0]), 5000);
console.log('5 + 7 =', result.readInt32LE(0));
```

**Python 服务端（7 行）：**

```python
from lingofuse import Server
app = Server("Calc")

@app.expose("add")
def add(a, b):
    return a + b

app.start_multi(["ipc:calc", "0.0.0.0:9898"])
input("Press Enter to exit...\n")
```

---

## 测试与验证：以 `test/` 为准

如果你对 readme 中的任何描述拿不准——延迟、顺序、稳定性、并发下的行为——**不要去猜，去 `test/` 目录找实物印证。**

`test/` 目录是 LingoFuse 的 CI 测试接口所在地。这里没有空话，只有可运行的测试程序、可复现的测试指南，以及实测数据的记录。**readme 说的一切，`test/` 里都有对应的东西可以验证。**

### 为什么 test 目录是一堆文档和可执行文件，而不是 GitHub Actions

GitHub 的自动化 CI 有很多限制。LingoFuse 本身又是**多语言、多平台**支持——Pascal、Python、C++、C#、TypeScript、JavaScript，加上 Windows / Linux / macOS，还要覆盖 IPC / TCP / 跨机等不同部署形态。把所有组合都塞进 GitHub 的托管 Runner 里，既不方便，也不现实。

所以 LingoFuse 的做法是：**把测试能力直接交到使用者手里。**

- `test/` 目录提供完整的测试指南（Markdown）和预编译的可执行文件（`test.zip`）。
- 你在自己的机器上解压、运行、观察，得到的是**你自己硬件上的真实数据**，而不是云端 Runner 的参考数字。
- 每一份指南都包含环境要求、运行命令、预期输出、判定标准和故障排查，照做即可。

**所有 CI 测试都是 C++ 代码。** 在 `cpp/` 目录下可以找到全部源码——功能测试、压力测试、并发 Notify 测试，对应的 `.cpp` / `.hpp` 和 `CMakeLists.txt` 都在那里。你可以：

- 直接使用 `test/test.zip` 里的预编译可执行文件快速验证；
- 或者进入 `cpp/` 目录，自己编译，自己复现，自己改。

源码和可执行文件是对应的，测试逻辑完全透明。

### 测试文档与可执行文件

| 文档 | 内容 | 可执行文件 |
|------|------|------------|
| [`LingoFuse_Functional_Test_Guide.md`](test/LingoFuse_Functional_Test_Guide.md) | **功能测试指南**：82 项测试，覆盖 C++ RAII 层与序列化层，验证每一个公开 API 的契约。CI 模式下 100% 通过。 | `test/test.zip` 内 `test_lingofuse` / `test_lingofuse_json` |
| [`LingoFuse_Stress_Test_Guide.md`](test/LingoFuse_Stress_Test_Guide.md) | **压力测试指南**：提供 Call / Notify / 混合模式的一键自测工具，让你在自己的机器上跑出吞吐、延迟、稳定性数据。 | `test/test.zip` 内 `StressService` / `StressClient` / `StressMonitor` |
| [`LingoFuse_Concurrent_Notify_Demo.md`](test/LingoFuse_Concurrent_Notify_Demo.md) | **并发 Notify 演示与 CI 套件**：验证高并发下 Notify 不丢失，演示“完成屏障”模式，20 批 × 10000 条实测零丢失。 | `test/test.zip` 内 `ConcService` / `ConcClient` |

**使用方式**：解压 `test/test.zip`，按对应 `.md` 文档中的步骤运行可执行文件。每份指南包含环境要求、运行命令、预期输出、判定标准和故障排查。

**源码位置**：上述测试的 C++ 源码均在 `cpp/` 目录下：

- `cpp/test/` —— 功能测试（`test_lingofuse.cpp` / `test_lingofuse_json.cpp`）
- `cpp/Stress/` —— 压力测试（`StressService.cpp` / `StressClient.cpp` / `StressMonitor.cpp`）
- `cpp/Conc/` —— 并发 Notify 测试（`ConcService.cpp` / `ConcClient.cpp`）

每个子目录都有对应的 `CMakeLists.txt` 和一键 CI 脚本（`run_*_ci.ps1` / `run_*_ci.sh`），编译和运行方式在指南中有详细说明。

### 为什么把测试单独拿出来说

LingoFuse 把稳定性放在第一位。测试不是附属品，而是这个立场的**证据来源**。

你要做竞态稳定性验证、并发压力测试、或者只是想确认某个 API 在高负载下是否可靠——不需要相信 readme 里的任何一句话。跑 `test/` 里的东西，或者自己编译 `cpp/` 里的源码，看结果说话。

**实测数据是基线，不是承诺。** 你的硬件不同，数字会不同，但相对关系和稳定性结论应当一致。所有测试都支持 CI 模式，返回标准退出码，可直接接入你自己的流水线。

---

## 仓库结构

```
LingoFuse/
├── Binary/              # 预编译动态库（Win32 / Win64）
├── cpp/                 # C++ 绑定、并发压力测试、跨语言 Demo
│   ├── test/            # 功能测试源码（test_lingofuse.cpp / test_lingofuse_json.cpp）
│   ├── Stress/          # 压力测试源码（StressService / StressClient / StressMonitor）
│   └── Conc/            # 并发 Notify 测试源码（ConcService / ConcClient）
├── csharp/              # C# / .NET 绑定、示例、测试程序
├── ts/                  # TypeScript 绑定（源码 + 类型定义 + 示例 + 测试）
├── js/                  # JavaScript 绑定（CommonJS + ESM 双入口）
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
├── test/                # CI 测试接口：功能 / 压力 / 并发测试指南与可执行文件
│   ├── LingoFuse_Functional_Test_Guide.md
│   ├── LingoFuse_Stress_Test_Guide.md
│   ├── LingoFuse_Concurrent_Notify_Demo.md
│   └── test.zip         # 对应测试可执行文件（源码在 cpp/ 下）
└── src/                 # Pascal 主库源码
```

---

## 依赖库

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

## 基于 LingoFuse 构建的生态

LingoFuse 的定位是**通讯地基**。地基本身不做应用，但地基之上的建筑可以有很多种。

以下是社区基于 LingoFuse 构建的项目：

### 智能体运行时

| 项目 | 语言 | 状态 | 说明 |
|------|------|------|------|
| [pasAgent v2](https://github.com/PassByYou888/LingoFuse-pasAgent) | Pascal | 🟢 已发布 | 纯文本智能体，129+ LLM 后端兼容 |
| [pasAgent v3](https://github.com/PassByYou888/LingoFuse-pasAgent-v3) | Pascal | 🟢 已发布 | 多模态智能体，250+ 后端，双语言代码生成 |
| [cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent) | C++ | 🟢 已发布 | C++ 生态智能体接入 |
| [csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent) | C# / .NET | 🟢 已发布 | .NET 智能体运行时 + LLM 客户端 SDK |

这些分支展示了一件事：**LingoFuse 的通讯底座足够通用，可以支撑任何语言生态构建自己的智能体层。** 而底座保证这些分支之间可以互相说话。

### 相关项目

- **[zIPC](https://github.com/PassByYou888/zIPC)** —— LingoFuse 底层的同机 IPC 引擎。如果你只需要同机 IPC，不需要完整的 RPC 网格，可以直接使用 zIPC。

---

## 项目状态

| 板块 | 状态 | 说明 |
|------|------|------|
| **核心通讯层** | ✅ 稳定 | C4 引擎、二进制帧、句柄、软同步、线程池全部就绪 |
| **Pascal 绑定** | ✅ 生产就绪 | 完整 FFI + 助手层 + 示例 |
| **Python 绑定** | ✅ 生产就绪 | `pip install -e .` 即用 |
| **C++ 绑定** | ✅ 生产就绪 | 原生 C ABI + CMake 工程 + 并发压力测试 |
| **C# / .NET 绑定** | ✅ 生产就绪 | 完整绑定 + 测试程序 + README |
| **TypeScript 绑定** | ✅ 生产就绪 | 完整类型定义 + 源码 + 示例 + 测试 |
| **JavaScript 绑定** | ✅ 生产就绪 | CommonJS + ESM 双入口 |
| **HTTP 桥接** | ✅ 生产就绪 | `bridge.py` 网关，覆盖 Node.js / PHP / 浏览器 |
| **代码生成器体系** | ✅ 已完结 | [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) |
| **AI 知识库体系** | ✅ 已完善 | 覆盖所有接口，AI 接管成功率接近绝对 |
| **CI 测试体系** | ✅ 已就绪 | `test/` 提供指南与可执行文件，源码在 `cpp/` 下，可自行编译复现 |
| **Rust / Go / Java 绑定** | ⏳ 接入中 | 欢迎贡献 |

**项目还在建设中，但已经在加速完结阶段。** 通讯底座已稳，六语言第一方绑定齐全，生成器体系闭环，知识库体系完善，CI 测试实物可跑、源码可查——剩下的只是把生态铺满。

---

## 许可证

**MIT** —— 拿去用，拿去改，拿去卖，都不用来谢我。

---

## 关于作者

**老张（QQ: 600585）**

看不惯跨语言调用得写一箩筐胶水代码，干脆撸了 LingoFuse。
现在又看不惯每种语言都得手写绑定，干脆把代码生成器也撸完了。
再把知识库喂给 AI，让 AI 自己把接口全部接管。

**让所有编程语言平等对话** —— 不是口号，是正在发生的事。

欢迎来撩、来喷、来 PR——**Star 是最好的催更。**

---

*项目始于 2026 年，持续进化中。有问题提 Issue，急事加 Q。*