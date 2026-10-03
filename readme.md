# LingoFuse

> **跨语言通讯地基。不写 IDL，不生成桩代码，不搭 HTTP 服务。**
>
> 任何语言写的函数，任何其他语言都能直接调。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Languages](https://img.shields.io/badge/languages-11%20first--party%20%2B%2030%20via%20tools-blue)]()
[![Latency](https://img.shields.io/badge/same--machine%20IPC-%3C1ms-brightgreen)]()
[![CI](https://img.shields.io/badge/CI-C%2B%2B%20only-orange)]()

---

## 📖 按需阅读指南

不同的人来这个仓库，想看的东西不一样。请按你的身份选择入口：

| 你的身份 | 建议阅读顺序 |
|---|---|
| **第一次听说 LingoFuse** | [这是什么](#这是什么) → [为什么需要它](#为什么需要它) → [快速开始](#快速开始) |
| **想评估是否采用** | [语言支持](#语言支持) → [测试与验证](#测试与验证) → [项目状态与边界](#项目状态与边界) |
| **已经是用户，想看生态** | [智能体运行时](#智能体运行时) → [代码生成器体系](#代码生成器体系) → [相关项目](#相关项目) |
| **想贡献 / 想 PR** | [项目状态与边界](#项目状态与边界) → [关于作者](#关于作者) → 直接提 Issue |
| **只是想 Star 催更** | 右上角点 Star，然后看 [关于作者](#关于作者) |

---

## 这是什么

LingoFuse 是一个**跨语言、跨进程、跨机器**的 RPC 框架。

核心承诺一句话：**任何语言写的函数，任何其他语言都能直接调。**

- 不需要写 IDL
- 不需要生成桩代码
- 不需要搭 HTTP 服务
- 同机 IPC 延迟声称 < 1 ms
- 跨机原生支持，内置服务发现、负载均衡、FIFO 顺序保证和断线重连

**它不是万能胶。** 采用之前，请务必读完 [测试与验证](#测试与验证) 和 [项目状态与边界](#项目状态与边界)。

---

## 为什么需要它

跨语言调用目前的现实：

- **gRPC**：要写 IDL、要生成桩代码、要搭网关
- **REST**：延迟高、无流式、无服务发现
- **HTTP POST**：天然跨机但无顺序保证、无服务发现
- **同进程调用**：延迟极低但不跨语言

每一种方案都只覆盖了一部分场景。LingoFuse 试图把长处合并，把短板补上。

| 特性 | LingoFuse | gRPC | REST | HTTP POST |
|------|-----------|------|------|-----------|
| 跨机支持 | ✅ 原生 | ✅ 需网关 | ✅ 需网关 | ✅ 原生 |
| 跨语言 | **11 种一方 + 30+ 经工具链** | 需生成代码 | 需手动封装 | ✅ 天然 |
| 请求-响应 | ✅ Call | ✅ | ✅ | ✅ |
| 流式 / 异步 | ✅ Notify | ⚠️ 需 stream | ❌ | ❌ |
| 类型安全 | ✅ 强类型 | ✅ 需 IDL | ❌ | ❌ |
| 服务发现 | ✅ 内置 | ❌ 需 etcd | ❌ 需 Nginx | ❌ |
| 负载均衡 | ✅ 内置 | ❌ 需 LB | ❌ 需 Nginx | ❌ |
| 顺序保证 | ✅ FIFO | ❌ | ❌ | ❌ |
| 断线重连 | ✅ 自动 | ❌ 需重试 | ❌ 需重试 | ❌ 需重试 |
| 零拷贝 | ✅ | ❌ | ❌ | ❌ |
| IDL 依赖 | **无** | 必需 | 无（需文档） | 无 |
| 桩代码生成 | **可选（自动）** | 必需 | 无 | 无 |

> ⚠️ **稳定第一，并发次要。**
>
> LingoFuse 把应用的稳定性放在第一位，并发性能往后挪移。这不是临时取舍，而是项目未来所有版本都会坚持的趋势。一个在高并发下会偶发崩溃、丢消息或死锁的通讯层，延迟再低也没有意义。
>
> 因此本项目**不在主 README 中做并发性能的横向对比**，实测数据以 [`test/`](test/) 目录为准。

---

## 快速开始

在投入任何生产开发之前，建议按以下顺序验证：

**第一步：克隆仓库**

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
# 然后将 LingoFuse/Binary 目录加入系统 PATH
```

**第二步：阅读测试指南，运行预编译可执行文件**

进入 [`test/`](test/) 目录，里面有三份指南：

- [`LingoFuse_Functional_Test_Guide.md`](test/LingoFuse_Functional_Test_Guide.md) —— 功能测试
- [`LingoFuse_Stress_Test_Guide.md`](test/LingoFuse_Stress_Test_Guide.md) —— 压力测试
- [`LingoFuse_Concurrent_Notify_Demo.md`](test/LingoFuse_Concurrent_Notify_Demo.md) —— 并发通知

解压 `test.zip`，运行预编译可执行文件。**得到的是你自己硬件上的真实数据。**

**第三步：如需深入，进入 `cpp/` 目录自行编译 CI 测试**

```bash
cd cpp/test   && cmake . && make && ./test_lingofuse
cd cpp/Stress && cmake . && make && ./StressService & ./StressClient
cd cpp/Conc   && cmake . && make && ./ConcService  & ./ConcClient
```

**第四步：用你自己的业务场景构建 PoC**

LingoFuse 提供的是**竞态稳定性测试（机理层）**，不是你的 App 层测试。你需要自己模拟自己的 App 层，验证 LF 在自身业务场景下的表现。

---

## 语言支持

### 第一方绑定（仓库内）

每个语言目录都有独立的 README、独立的测试体系、独立的示例。点击语言名进入对应目录。

| 语言 | 目录 | 状态 | 测试规模 / 说明 |
|------|------|------|------------------|
| **Pascal** | [`pascal/`](pascal/) | 🟢 生产就绪 | 原生 FFI，核心引擎来源。单测 / 压测 / 计算网格 / HTTP Bridge 全覆盖 |
| **Python** | [`Py/`](Py/) | 🟢 生产就绪 | `pip install -e .` 即用。含服务端 `@expose` 装饰器、HTTP 网关、JSON 修复预处理 |
| **C++** | [`cpp/`](cpp/) | 🟢 生产就绪 | **唯一有 GitHub CI**。原生 C ABI，零开销。功能 / 压力 / 并发三套 CI 测试 |
| **C# / .NET** | [`csharp/`](csharp/) | 🟢 生产就绪 | **58 项测试，8 分类**。完整 .NET 绑定，服务端 / 调用端全支持。P/Invoke + RAII + JSON I/O |
| **TypeScript** | [`ts/`](ts/) | 🟢 生产就绪 | **127 项测试**。完整类型定义 + 源码 + 编译产物 + 示例。支持 Node / Deno / Bun |
| **JavaScript** | [`js/`](js/) | 🟢 生产就绪 | **127 项测试**。CommonJS + ESM 双入口，与 TS 字节级互通 |
| **Rust** | [`rust/`](rust/) | 🟢 生产就绪 | **67 项测试**。安全 RAII 封装 + 完整 C ABI 层。FFI 边界 `catch_unwind` 隔离 |
| **Go** | [`go/`](go/) | 🟢 生产就绪 | **18 项测试**。purego 无 cgo，交叉编译友好。含 e2e / ABI 冒烟 / 数据句柄测试 |
| **Dart** | [`dart/`](dart/) | 🟢 生产就绪 | 完整测试套件。Dart FFI + C 桥接 DLL。**完整 caller + server 能力**。支持 Flutter 移动端 |
| **Java** | [`java/`](java/) | 🟢 生产就绪 | 基于 FFM API（JDK 22+），纯 Java 无 JNI。含 `DataHandle` / `AppHandle`、自动化测试、三进程 Demo。性能优化进行中 |
| **PHP** | [`php/`](php/) | 🟡 调用者接入 | 无 FFI 测试。经 `bridge.py` HTTP 网关，**PHP 只能作为调用者** |

> **关于 PHP 的明确说明**：PHP 官方 FFI 机制无法从外部 OS 线程进入 PHP 回调，无法注册 Call/Notify 服务端 API。因此 PHP 只能作为调用者接入。**需要 PHP 作为服务端时，LingoFuse 当前不满足。**
>
> **关于 Java 的明确说明**：Java 绑定使用 FFM API，需要 **JDK 22+**（推荐 JDK 25 LTS）。当前功能完整，含跨进程 RPC、跨语言 ABI 验证与三进程 Demo；性能优化仍在推进。GitHub 托管 CI 目前只覆盖 C++，Java 侧以 `java/run_test_ci.ps1` / `run_test_ci.sh` 本地运行为准。

### 经代码生成器 / 桥接支持

| 语言 / 平台 | 方式 | 成熟度 |
|-------------|------|--------|
| **Node.js / 浏览器** | `bridge.py` HTTP 网关 | 可用，非原生 |
| **Kotlin / Swift / Ruby / Lua / Elixir / Julia / Zig / Nim / Crystal** | 经 [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) 代码生成器接入 | 生成代码可用，需自行验证 |
| **aarch64 / loongarch64 / RISC-V** | 边缘设备移植计划 | 持续推进中，未生产就绪 |

👉 **[进入 LingoFuse-Tools 仓库](https://github.com/PassByYou888/LingoFuse-Tools)**

---

## 智能体运行时

LingoFuse 是**通讯地基**。地基本身不做应用，但地基之上的建筑可以有很多种。

这些是基于 LingoFuse 构建的**智能体运行时**，每种宿主语言一个：

| 项目 | 语言 | 状态 | 说明 |
|------|------|------|------|
| [**LingoFuse-pasAgent**](https://github.com/PassByYou888/LingoFuse-pasAgent) | Pascal | 🟢 已发布 | 纯文本智能体，129+ LLM 后端兼容 |
| [**LingoFuse-pasAgent-v3**](https://github.com/PassByYou888/LingoFuse-pasAgent-v3) | Pascal | 🟢 已发布 | 多模态智能体，250+ 后端，双语言代码生成 |
| [**LingoFuse-cppAgent**](https://github.com/PassByYou888/LingoFuse-cppAgent) | C++ | 🟢 已发布 | C++ 生态智能体接入 |
| [**LingoFuse-csharpAgent**](https://github.com/PassByYou888/LingoFuse-csharpAgent) | C# / .NET | 🟢 已发布 | .NET 智能体运行时 + LLM 客户端 SDK |
| **LingoFuse-tsAgent** | TypeScript | 🚧 即将发布 | TypeScript / JavaScript 生态智能体接入 |

> **tsAgent 尚未发布。** 当前 TS/JS 绑定是纯通讯层，不含 Agent 运行时。如果需要在 TS/JS 中构建 Agent，请使用 Mastra、Vercel AI SDK 等成熟框架，再通过 LingoFuse 的 TS 绑定调用其他语言的函数。

---

## 相关项目

- **[zIPC](https://github.com/PassByYou888/zIPC)** —— LingoFuse 底层的同机 IPC 引擎。只需要同机 IPC 不需要完整 RPC 网格时，可直接使用。
- **[ZNetV2](https://github.com/PassByYou888/ZNetV2)** —— PassByYou888 技术栈中面向大规模服务器端数据吞吐的通讯框架。

---

## 测试与验证

**以 `test/` 为准。**

对 README 中的任何描述拿不准——延迟、顺序、稳定性、并发下的行为——**不要去猜，去 [`test/`](test/) 目录找实物印证。**

`test/` 提供了 **PoC（Proof of Concept）概念验证**的一部分工作。在产品中使用 LingoFuse 体系，请注意：

1. **作者提供了竞态稳定性测试（最重要的机理层测试），但不是用户的 App 层测试。** 用户需要自己模拟自己的 App 层跑 PoC。
2. **用户需要掌握构建编译 LF 的技能。** LingoFuse 由老张开发，如果长期不维护，用户需要自己动手编译，跟上最新的代际更新。
3. **各个语言原则上都会有自己的 test、CI 体系。** 目前 Pascal、C#、C++、JS、TS、Python、Rust、Go、Dart、Java 都有各自能跑的 test，但 **GitHub 托管 CI 只有 C++ 的**。其他语言提供本地测试脚本或工程，例如：
   - C++：`cpp/test/`、`cpp/Stress/`、`cpp/Conc/`
   - Java：`java/run_test_ci.ps1`、`java/run_test_ci.sh`
   - Go：`go/test.ps1`、`go/dev_test.ps1`
   - Rust：`rust/test.ps1`
   - C#：`csharp/build.ps1`、`csharp/test/`
   - TypeScript：`ts/package.json`、`ts/test/`
   - Python：`Py/lingofuse/test_lingofuse.py`、`Py/lingofuse/test_bridge.py`
   - JavaScript：`js/test/test.js`
   - Dart：`dart/test/`
   - Pascal：`pascal/` 下各 Demo 与测试工程

### 为什么 `test/` 是一堆文档和可执行文件

GitHub 的自动化 CI 有很多限制，LingoFuse 又是**多语言、多平台**支持——Pascal、Python、C++、C#、TypeScript、JavaScript、Rust、Go、Dart、Java、PHP，加上 Windows / Linux / macOS，还要覆盖 IPC / TCP / 跨机等不同部署形态。把所有组合都塞进 GitHub 的托管 Runner 里，既不方便，也不现实。

所以 LingoFuse 的做法是：**把测试能力直接交到使用者手里。**

`test/` 提供完整的测试指南（Markdown）和预编译的可执行文件（`test.zip`）。你在自己的机器上解压、运行、观察，得到的是**你自己硬件上的真实数据**。

### CI 测试源码

**GitHub 托管 CI 测试目前都是 C++ 代码**，源码在 [`cpp/`](cpp/) 目录下：

- [`cpp/test/`](cpp/test/) —— 功能测试（`test_lingofuse.cpp` / `test_lingofuse_json.cpp`）
- [`cpp/Stress/`](cpp/Stress/) —— 压力测试（`StressService.cpp` / `StressClient.cpp` / `StressMonitor.cpp`）
- [`cpp/Conc/`](cpp/Conc/) —— 并发 Notify 测试（`ConcService.cpp` / `ConcClient.cpp`）

每个子目录都有 `CMakeLists.txt` 和一键 CI 脚本。

---

## 依赖库

核心动态库位于 [`Binary/`](Binary/) 目录：

| 平台 | 核心库 | IPC 依赖 | 内存分配器 |
|------|--------|----------|------------|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` | `libmimalloc.so`（可选） |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` | `libmimalloc.dylib`（可选） |

> 仓库当前 `Binary/` 目录主要提供 Windows 32/64 位预编译库；Linux / macOS 库需按 [`src/`](src/) 下构建文档自行编译。

**部署方式**：将 `Binary/` 目录加入系统 `PATH`，或把动态库复制到可执行文件同目录。

Windows 下需安装 **VC++ 2015-2022 可再发行程序包**：

- [最新受支持的 Visual C++ 可再发行程序包](https://learn.microsoft.com/zh-cn/cpp/windows/latest-supported-vc-redist?view=msvc-170)
- x64 直链：[vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe)
- x86 直链：[vc_redist.x86.exe](https://aka.ms/vs/17/release/vc_redist.x86.exe)

---

## 项目状态与边界

| 板块 | 状态 | 说明 |
|------|------|------|
| **核心通讯层** | ✅ 稳定 | C4 引擎、二进制帧、句柄、软同步、线程池全部就绪 |
| **十一语言第一方绑定** | ✅ 生产就绪 | Pascal / Python / C++ / C# / TypeScript / JavaScript / Rust / Go / Dart / Java / PHP（PHP 为调用者） |
| **HTTP 桥接** | ✅ 可用 | `bridge.py` 网关，覆盖 Node.js / PHP / 浏览器 |
| **代码生成器体系** | ✅ 已完结 | [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) |
| **AI 知识库体系** | ✅ 已完善 | 覆盖所有接口，可辅助 AI 接管——生成代码需人工验证 |
| **CI 测试体系** | ⚠️ 仅 C++ 有 GitHub CI | `test/` 提供指南与可执行文件，源码在 `cpp/` 下；其他语言提供本地脚本 |
| **tsAgent** | 🚧 即将发布 | TypeScript / JavaScript 智能体运行时 |
| **Java 绑定** | 🟢 生产就绪 | 功能完整，含 FFM 绑定、自动化测试、三进程 Demo；性能优化进行中 |

### 明确不推荐的使用场景

- 需要成熟社区支持、大量第三方教程、Stack Overflow 问答的项目
- 无法接受单人维护风险，且没有自行编译、自行维护能力的团队
- 纯 TS/JS 项目，所有逻辑都可以用 TS/JS 重写，引入 LF 只会增加复杂度和故障点
- 需要 PHP 作为服务端的场景（PHP 只能作为调用者）
- 对并发性能有硬性要求，且不愿自行做 App 层 PoC 验证的团队
- **Flutter Web 项目**（Dart FFI 不可用）
- **32 位 Windows 项目**（Dart 绑定未测试）
- **Java 绑定需要 JDK 22+**，无法在 JDK 8 / 11 / 17 / 21 上直接运行

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

## 继续探索

| 你想做什么 | 去哪里 |
|---|---|
| 用代码生成器自动产出多语言绑定 | [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) |
| 构建 Pascal 智能体 | [pasAgent](https://github.com/PassByYou888/LingoFuse-pasAgent) / [pasAgent-v3](https://github.com/PassByYou888/LingoFuse-pasAgent-v3) |
| 构建 C++ 智能体 | [cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent) |
| 构建 .NET 智能体 | [csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent) |
| 只用同机 IPC，不需要完整 RPC | [zIPC](https://github.com/PassByYou888/zIPC) |
| 面向大规模服务器端数据吞吐 | [ZNetV2](https://github.com/PassByYou888/ZNetV2) |

---

*项目始于 2026 年，持续进化中。有问题提 Issue，急事加 Q（600585）。*

**采用前请务必：跑 `test/`，做 PoC，验证你自己的场景。**