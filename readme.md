# LingoFuse

> **跨语言通讯地基。不写 IDL，不生成桩代码，不搭 HTTP 服务。**
>
> 任何语言写的函数，任何其他语言都能直接调。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Languages](https://img.shields.io/badge/languages-18%20first--party%20%2B%2030%20via%20tools-blue)]()
[![Latency](https://img.shields.io/badge/same--machine%20IPC-%3C1ms-brightgreen)]()
[![CI](https://img.shields.io/badge/CI-C%2B%2B%20only-orange)]()

---

## 📖 按需阅读指南

不同的人来这个仓库，想看的东西不一样。请按你的身份选择入口：

| 你的身份 | 建议阅读顺序 |
|---|---|
| **第一次听说 LingoFuse** | [这是什么](#这是什么) → [使用门槛](#️-使用门槛这是黑科技不是开箱即用) → [为什么需要它](#为什么需要它) → [快速开始](#快速开始) |
| **想评估是否采用** | [使用门槛](#️-使用门槛这是黑科技不是开箱即用) → [语言支持](#语言支持) → [测试与验证](#测试与验证) → [项目状态与边界](#项目状态与边界) |
| **已经是用户，想看生态** | [智能体运行时](#智能体运行时) → [相关项目](#相关项目) |
| **想理解核心机制** | [核心概念](#核心概念) → [内部机制知识库](Z.LingoFuse.md) → [Pascal 完整指南](LingoFuse_Pascal_Complete_Guide.md) |
| **想自己编译核心库** | [构建核心动态库](#构建核心动态库) |
| **想用代码生成器铺开多语言绑定** | [代码生成器体系 · LingoFuse-Tools](#代码生成器体系--lingofuse-tools) |
| **想了解作者怎么做的** | [关于作者](#关于作者) → [十四语言实测手记](https://zpascal.net/imhuman.html) |
| **想贡献 / 想 PR** | [使用门槛](#️-使用门槛这是黑科技不是开箱即用) → [项目状态与边界](#项目状态与边界) → [关于作者](#关于作者) → 直接提 Issue |
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

**它不是万能胶。** 采用之前，请务必读完 [使用门槛](#️-使用门槛这是黑科技不是开箱即用)、[测试与验证](#测试与验证) 和 [项目状态与边界](#项目状态与边界)。

---

## ⚠️ 使用门槛：这是黑科技，不是开箱即用

先说清楚性质：**LingoFuse 是黑科技基础设施，不是业务框架。** 它解决的是大多数团队根本不会去碰的底层问题——跨语言字节级互通、C4 mesh 调度、18 种语言的 FFI 绑定、多线程回调安全、Handle 所有权模型。**这些东西让它能做别人做不到的事，也让它对使用者的要求远高于普通库。**

### 它把最难的问题解决了

- **线格式语言无关**：任何语言的 CrossNode 写出的字节流，任何语言的 CrossCall 都能原样读出来。
- **零 IDL 的强类型调用**：Pascal 声明 `function Add(a, b: Integer): Integer;`，C++ / Rust / Swift / Java 都能直接 `Add(1, 2)`，不需要 `.proto`、不需要生成桩。
- **真·服务发现 + 负载均衡 + FIFO + 断线重连**：不用 etcd、不用 Nginx、不用自己写重试。
- **18 种语言的绑定**：从 ASM 级 C ABI 到 Dart / Julia / R，每种都跑通了自己的测试体系。

### 它把最复杂的负担留给了你

LingoFuse **不做**下面这些事：

- **不做业务层封装**。它给你的是 `LF_Call` / `LF_Notify` / `LF_RegisterCall`，怎么组织你的 App 层、怎么切分服务、怎么做权限，都是你的工程决策。
- **不做线程抽象**。回调在 TCompute 工作线程跑，不在主线程；回调里不能调阻塞 LF 函数，否则自锁死；同步回调要靠主线程 `LF_Sync` 驱动。这些不是"读一遍文档就懂"的事，是必须在你自己的代码里反复调试才能养成肌肉记忆的事。
- **不做跨平台工具链适配**。每种语言的绑定都有各自的编译期陷阱：Java 需要 JDK 22+、Fortran 需要 C++ 与 Fortran 编译器来自同一发行版、Ruby 需要 DevKit、Julia 强制 `--threads=2`、Swift 的 macOS / Linux 路径还在验证中。这些坑你必须自己能处理。
- **不做"装好就能跑"**。核心动态库需要你自己（或环境）编译；`Binary/` 只提供 Windows 32/64 位预编译版；Linux / macOS 需要按 `src/CONTRIBUTING.md` 自己构建。
- **不做社区支持**。单人维护，Issue 会回，但不保证 SLA，没有 Stack Overflow 问答，没有第三方教程。

### 采用前请自测四个问题

1. **你能否自行编译 LingoFuse 核心动态库（FPC / Lazarus）？**
   如果答案是否，你的团队将完全依赖预编译二进制，遇到任何平台适配问题都会卡死。
2. **你能否读懂回调线程模型，并在自己的代码中系统性避免死锁？**
   LingoFuse 把回调放在工作线程执行——这是一切正确性的基础，也是最容易出错的地方。如果团队里没人能讲清楚"为什么回调里不能调 `LF_Call`"，先别用。
3. **你能否在出现问题时会读源码，而不是读注释？**
   文档里有 95 条踩坑 ID、17 种语言的生成器报告、`Z.LingoFuse.md` v3.2——但**注释是二手信息**。真正诡异的行为，只有源码能说清楚。
4. **你是否愿意做 App 层 PoC，而不是相信 README 里的任何数字？**
   `test/` 提供的是**机理层竞态稳定性测试**，不是你的业务层测试。README 里的延迟、并发、成功率，都基于作者的硬件和场景，不是你的。

**如果上面任何一条的答案是"不能"或"不愿意"，请直接选 gRPC / REST / 同进程方案。** LingoFuse 不会替你解决这些问题——它只提供地基，建筑需要你来设计。

**反过来**：如果上面四条你都能答"能"，而且你确实需要跨语言、跨进程、零 IDL、低延迟的原生 RPC，那 LingoFuse 是你能找到的最认真的实现之一。

---

## 为什么需要它

跨语言调用目前的现实：

- **gRPC**：要写 IDL、要生成桩代码、要搭网关
- **REST**：延迟高、无流式、无服务发现
- **HTTP POST**：天然跨机但无顺序保证、无服务发现
- **同进程调用**：延迟极低但不跨语言

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

| 语言 | 目录 | 状态 | 一句话说明 |
|------|-----|-------|-------------|
| Pascal | [`pascal/`](pascal/) | 🟢 生产就绪 | 原生 FFI，核心引擎来源；完整指南见 [`LingoFuse_Pascal_Complete_Guide.md`](LingoFuse_Pascal_Complete_Guide.md)（v7.0，95 条踩坑 ID） |
| Python | [`Py/`](Py/) | 🟢 生产就绪 | `pip install -e .` 即用，含 `@expose` 装饰器与 HTTP 网关；知识库含 Handle 所有权 + 侧数据勘误 |
| C++ | [`cpp/`](cpp/) | 🟢 生产就绪 | 唯一有 GitHub CI，原生 C ABI 零开销，异步模型 + 侧数据读取 |
| C# / .NET | [`csharp/`](csharp/) | 🟢 生产就绪 | v5.1，116 项测试，P/Invoke + RAII + 统一 JSON I/O + `CallbackDispatcher` + 回调风格异步 |
| TypeScript | [`ts/`](ts/) | 🟢 生产就绪 | v2.0，223 项测试，支持 Node / Deno / Bun，三风格 × 三寻址 |
| JavaScript | [`js/`](js/) | 🟢 生产就绪 | v2.0，223 项测试，CommonJS + ESM 双入口，与 TS 字节级互通 |
| Rust | [`rust/`](rust/) | 🟢 生产就绪 | v2.0，174 项测试，闭包式异步，`call_async_wait` 返回 `Vec<u8>` |
| Go | [`go/`](go/) | 🟢 生产就绪 | purego 无 cgo，交叉编译友好；死锁看门狗补偿 runtime 误判 |
| Dart | [`dart/`](dart/) | 🟢 生产就绪 | 完整 caller + server 能力，Flutter 移动端可用；C 桥接解决跨线程同步回调 |
| Java | [`java/`](java/) | 🟢 生产就绪 | JDK 22+ FFM API，纯 Java 无 JNI；145 项测试，`ArenaReaper` 处理超时 stub |
| Swift | [`swift/`](swift/) | 🟢 生产就绪 | v1.1，261 项 XCTest，`@convention(c)` 回调，C++ ↔ Swift 双向字节级互调已验证 |
| Zig | [`zig/`](zig/) | 🟢 生产就绪 | 锁定 Zig 0.17.0，`c/lf_json.cpp` 保 JSON 字节一致，140+ 项测试 |
| Erlang | [`erlang/`](erlang/) | 🟢 生产就绪 | OTP 27+，NIF 跨平台构建，37 个 C ABI 完整封装，零运行时依赖 |
| Ruby | [`ruby/`](ruby/) | 🟢 生产就绪 | v2.0，331 项测试，Fiddle + C 扩展，完整 caller / server 双向能力 |
| Fortran | [`fortran/`](fortran/) | 🟢 生产就绪 | 474 项断言，`iso_c_binding` + C++ 桥接层，Fortran 2008 |
| Julia | [`julia/`](julia/) | 🟢 生产就绪 | C shim + `@threadcall` 跨线程回调隔离，**强制 `--threads=2`** |
| R | [`r/`](r/) | 🟢 生产就绪 | 四层架构 + Job 队列跨线程回调；RAII 句柄；字符串 / 二进制双模式；R 4.6.1 + Rtools45 |
| PHP | [`php/`](php/) | 🟡 调用者接入 | 经 `bridge.py` HTTP 网关，只能作为调用者 |


👉 **[进入 LingoFuse-Tools 仓库](https://github.com/PassByYou888/LingoFuse-Tools)**

---

## 代码生成器体系 · LingoFuse-Tools

LingoFuse 的第一方绑定是**手写**的。当你要把同一组 API 铺到十几种语言时，手写绑定会变成重复劳动——而且每种语言的线格式只要差一个字节，跨语言互调就会静默失败。

[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) 解决的就是这个问题：**从一份 Pascal 单元或 C 头文件出发，自动产出多语言的 service / call 代码、测试程序和构建脚本**。

### 三条工具线，三种协议

Tools 不是单一生成器，而是**三条并行的工具线**，共享同一套解析器、同一套 LV1 模型和同一套类型系统：

| 工具 | 产出协议 | 适用场景 |
|------|----------|----------|
| **`code_decl_to_abi`** | LingoFuse 二进制 ABI | 两端都是 LingoFuse 原生、高并发、数值 / 二进制重载荷 |
| **`code_decl_to_json_abi`** | HTTP + JSON（经 `bridge.py`） | 一端是浏览器、外部 HTTP 客户端，或没有 LingoFuse 绑定的语言 |
| **`code_decl_to_mcp`** | MCP | 把函数暴露为 AI Agent 可调用的工具，在中国 MCP 已经烂大街停更中 |

> **同一份声明，三条路径。** 改一次声明，ABI / JSON / MCP 三套产物一起刷新。不会出现"ABI 改了这个函数但 MCP 还停在旧签名"的情况。

### 生成器覆盖的目标语言

Tools 当前覆盖 **20+ 种目标语言**，每种都含 service 侧、call 侧、测试程序和一套 `setup_*_tests.ps1` 环境脚本。生成器的后端为**无限扩展**设计——加一种语言是机械的 8 步流程，不是架构变更。

#### 平台与运行时矩阵

下表列出每种目标语言**能运行生成代码**的平台与运行时要求。表格同时给出该语言是否支持 **service 侧**（被动响应方）与 **call 侧**（主动发起方）——某些语言只能做 call（无 service 生成），平台覆盖也各有边界。

| 目标语言 | Service | Call | 编译器 / 运行时 | Windows | Linux | macOS | 其他平台 | 备注 |
|----------|:-------:|:----:|----------------|:-------:|:-----:|:-----:|---------|------|
| Pascal | ✅ | ✅ | FPC 3.2+ / Delphi 10.4+ | ✅ | ✅ | ✅ | — | 需 `lingofuse_import.pas` + `Z.Core` |
| Python | ✅ | ✅ | CPython 3.7+ | ✅ | ✅ | ✅ | FreeBSD 等 | 需 `py-lingofuse` |
| C++ | ✅ | ✅ | C++17 编译器 | ✅ | ✅ | ✅ | — | 需 `LingoFuse.hpp` + `LingoFuse.c` |
| C# | ✅ | ✅ | .NET 8.0+ | ✅ | ✅ | ✅ | — | 需 `lingofuse` 命名空间 |
| Rust | ✅ | ✅ | Rust 1.70+（2021 edition） | ✅ | ✅ | ✅ | FreeBSD、WASM、嵌入式（仅 Call） | 需 `lingofuse` crate |
| Go | ✅ | ✅ | Go 1.21+（Service 需 `CGO_ENABLED=1`） | ✅ | ✅ | ✅ | FreeBSD、OpenBSD、NetBSD、Plan 9、Android、iOS、WASM（仅 Call） | 需 `lingofuse/go` module；Service 侧依赖 cgo |
| Java | ✅ | ✅ | JDK 11+（推荐 17+）；FFM API 需 JDK 22+ | ✅ | ✅ | ✅ | Solaris、AIX（仅 Call） | 需 `lingofuse.jar` + Jackson |
| Node.js | ✅ | ✅ | Node.js 18+ | ✅ | ✅ | ✅ | FreeBSD、OpenBSD（仅 Call） | 需 `lingofuse-js` + `koffi` |
| TypeScript | ✅ | ✅ | TypeScript 5.0+、Node 18+、`tsx` | ✅ | ✅ | ✅ | — | 需 `lingofuse-ts` |
| Erlang | ✅ | ✅ | Erlang/OTP 25+ | ✅ | ✅ | ✅ | FreeBSD 等 | 需 `lingofuse` Erlang binding |
| Julia | ✅ | ✅ | Julia 1.9+（**必须 `--threads=2`**） | ✅ | ✅ | ✅ | FreeBSD | 异步依赖多线程；单线程死锁 |
| Zig | ✅ | ✅ | Zig 0.13+ | ✅ | ✅ | ✅ | — | 需 `lingofuse` Zig 绑定 |
| Swift | ✅ | ✅ | Swift 5.9+（推荐 6.4） | ⚠️ 5.9+ 有工具链 | ⚠️ 社区验证 | ✅ 主要支持 | iOS（仅 Call，异步需 macOS 12+ / iOS 15+） | Windows 路径未实测 |
| Ruby | ✅ | ✅ | Ruby 2.7+ / 3.0+ | ✅ | ✅ | ✅ | FreeBSD 等 | 需 `lingofuse` gem + C 扩展工具链 |
| Fortran | ✅ | ✅ | gfortran 9+ / ifort / flang | ✅ | ✅ | ✅ | — | 需 `lf_fortran_mod` + C++17 工具链；C++ 与 Fortran 编译器须同发行版 |
| Dart | ✅ | ✅ | Dart 3.0+ | ✅ | ✅ | ✅ | iOS、Android、Web（仅 Call） | 需 `lingofuse` Dart 包 + `lf_dart_bridge.dll` |
| R | ✅ | ✅ | R 4.0+ | ✅ | ✅ | ✅ | FreeBSD | 需 `lingofuse` R 包；`int64` / `uint64` 需 `bit64` |
| JavaScript | ❌ | ✅ | 现代浏览器（Chrome / Edge / Firefox / Safari） | ✅ | ✅ | ✅ | iOS、Android、ChromeOS | 浏览器仅能做 call；浏览器内 `fetch` |
| PHP | ❌ | ✅ | PHP 7.4+ | ✅ | ✅ | ✅ | FreeBSD 等 | 经 `bridge.py` HTTP 网关，只能做 call |
| Delphi | ❌ | ✅ | Delphi 10.3+ | ✅ | ✅ | ✅ | iOS、Android | 受 Delphi 版本限制，只能做 call |

**图例**：
- ✅ — 该平台生产就绪
- ⚠️ — 有工具链但未充分验证，生产使用需谨慎
- ❌ — 该侧无生成能力（语言本身可能仍有该平台，但无 LingoFuse 绑定）
- — — 不适用

**关键边界**：
- **Service 侧**必须运行在桌面 / 服务器（Windows / Linux / macOS）。**iOS / Android / WASM / 嵌入式无法运行 Service**——LingoFuse 原生库不支持这些平台。需要移动端提供接口时，把 Service 部署到服务器，移动端作为 Call 通过桥接访问。
- **Call 侧平台范围更广**：因为 Call 的模式 A（直接 HTTP）不需要 LingoFuse 原生库，移动端 / WASM / 浏览器都能做 Call。
- **MCP 生成**目前只有 Pascal / Python / C++ / C# 四种语言，平台范围受各自运行时限制。

### 代码生成器不是"黑盒"

Tools 仓库同时承载了三类可读资产：

- **生成器源码**（`*_abi_*_generator_tool.pas`）：每种语言的 service / call / test / setup 生成器都是独立的 Pascal 单元。
- **输入契约**（`pascal_code_abi_rule.md` / `C_code_abi_rule.md` / `pascal_code_mcp_rule.md` / `C_code_mcp_rule.md`）：**哪些声明会被提取、哪些会被静默丢弃**，写得比大多数 IDL 文档都细。
- **各语言踩坑记录**（`R_ABI_Generator_Knowledge_Base.md` / `Dart_ABI_Generators_Fix_Report.md` / `Fortran_ABI_Generator_Work_Report.md` / `LingoFuse_Ruby_ABI_Integration_Report.md` / `swift_abi_generator_development_log.md` / `TypeScript_ABI_Generator_Development_Report.md` / `LingoFuse_JS_Async_Generator_Fix_Knowledge_Base.md`）：记录了"我以为"被实测推翻的地方——线格式不对齐、回调线程挂死、`int64` 在 JS 丢精度、`bridge.py` 预检缓存延迟导致 `-3` 错误等。

> **AI 可以直接读这些生成器源码和踩坑记录来接管工具链。** Tools 的设计目标之一就是让 Agent 不需要"猜"生成器的行为——文档和源码写在一起。

### 与第一方绑定的关系

| 维度 | 第一方绑定 | Tools 生成绑定 |
|------|-----------|----------------|
| 来源 | 手写 | 从 Pascal / C 声明生成 |
| 覆盖面 | 18 种，每种都有独立测试体系 | 20+ 种，每种都有测试程序和 setup 脚本 |
| CI | C++ 有 GitHub 托管 CI，其余本地脚本 | 生成器本身不跑 CI，产物需自行验证 |
| 适用阶段 | 生产部署 | 原型 / 多语言铺开 / 持续同步 |

**两者不冲突。** Tools 生成的绑定与第一方绑定共享同一套线格式契约；生成器的一个核心设计约束就是"与 C++ / Pascal 逐字节对齐"。如果你的项目只需要一种语言，直接用第一方绑定；如果你要把同一组 API 铺到多种语言，用 Tools。

👉 **[进入 LingoFuse-Tools 仓库，查看生成器源码、输入契约和踩坑记录](https://github.com/PassByYou888/LingoFuse-Tools)**

---

## 智能体运行时

LingoFuse 是**通讯地基**。地基本身不做应用，但地基之上的建筑可以有很多种。

这些是基于 LingoFuse 构建的**智能体运行时**，每种宿主语言一个：

| 项目 | 语言 | 状态 | 说明 |
|------|------|------|------|
| [LingoFuse-pasAgent](https://github.com/PassByYou888/LingoFuse-pasAgent) | Pascal | 🟢 已发布 | 纯文本智能体，129+ LLM 后端兼容 |
| [LingoFuse-pasAgent-v3](https://github.com/PassByYou888/LingoFuse-pasAgent-v3) | Pascal | 🟢 已发布 | 多模态智能体，250+ 后端，双语言代码生成 |
| [LingoFuse-cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent) | C++ | 🟢 已发布 | C++ 生态智能体接入 |
| [LingoFuse-csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent) | C# / .NET | 🟢 已发布 | .NET 智能体运行时 + LLM 客户端 SDK |
| LingoFuse-tsAgent | TypeScript | 🚧 即将发布 | TypeScript / JavaScript 生态智能体接入 |

> **tsAgent 尚未发布。** 当前 TS/JS 绑定是纯通讯层，不含 Agent 运行时。如果需要在 TS/JS 中构建 Agent，请使用 Mastra、Vercel AI SDK 等成熟框架，再通过 LingoFuse 的 TS 绑定调用其他语言的函数。

---

## 相关项目

- **[zIPC](https://github.com/PassByYou888/zIPC)** —— LingoFuse 底层的同机 IPC 引擎。只需要同机 IPC 不需要完整 RPC 网格时，可直接使用。
- **[ZNetV2](https://github.com/PassByYou888/ZNetV2)** —— PassByYou888 技术栈中面向大规模服务器端数据吞吐的通讯框架。
- **[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools)** —— 代码生成器体系，从 API 声明自动产出多语言绑定。包含三条工具线：`code_decl_to_abi`（二进制 ABI）、`code_decl_to_json_abi`（HTTP/JSON）、`code_decl_to_mcp`（MCP 工具提供者）。

---

## 测试与验证

**以 `test/` 为准。**

对 README 中的任何描述拿不准——延迟、顺序、稳定性、并发下的行为——**不要去猜，去 [`test/`](test/) 目录找实物印证。**

`test/` 提供了 **PoC（Proof of Concept）概念验证**的一部分工作。在产品中使用 LingoFuse 体系，请注意：

1. **作者提供了竞态稳定性测试（最重要的机理层测试），但不是用户的 App 层测试。** 用户需要自己模拟自己的 App 层跑 PoC。
2. **用户需要掌握构建编译 LF 的技能。** LingoFuse 由老张开发，如果长期不维护，用户需要自己动手编译，跟上最新的代际更新。
3. **各个语言原则上都会有自己的 test、CI 体系。** 目前 18 种语言都有各自能跑的 test，但 **GitHub 托管 CI 只有 C++ 的**。其他语言提供本地测试脚本或工程，例如：

### 为什么 `test/` 是一堆文档和可执行文件

GitHub 的自动化 CI 有很多限制，LingoFuse 又是**多语言、多平台**支持——18 种语言，加上 Windows / Linux / macOS，还要覆盖 IPC / TCP / 跨机等不同部署形态。把所有组合都塞进 GitHub 的托管 Runner 里，既不方便，也不现实。

所以 LingoFuse 的做法是：**把测试能力直接交到使用者手里。**

`test/` 提供完整的测试指南（Markdown）和预编译的可执行文件（`test.zip`）。你在自己的机器上解压、运行、观察，得到的是**你自己硬件上的真实数据**。

### CI 测试源码

**GitHub 托管 CI 测试目前都是 C++ 代码**，源码在 [`cpp/`](cpp/) 目录下：

- [`cpp/test/`](cpp/test/) —— 功能测试（`test_lingofuse.cpp` / `test_lingofuse_json.cpp`）
- [`cpp/Stress/`](cpp/Stress/) —— 压力测试（`StressService.cpp` / `StressClient.cpp` / `StressMonitor.cpp`）
- [`cpp/Conc/`](cpp/Conc/) —— 并发 Notify 测试（`ConcService.cpp` / `ConcClient.cpp`）

每个子目录都有 `CMakeLists.txt` 和一键 CI 脚本。

### 各语言测试规模速查

| 语言 | 测试框架 | 测试数 | 平台验证 | CI |
|------|----------|:------:|----------|:--:|
| Ruby | minitest | 331 | Windows x64；Linux / macOS 待测 | 本地 |
| Fortran | 自研断言 | 474 | Windows x64；Linux / macOS 待测 | 本地 |
| Julia | 自研断言 | 431 + 4 场景 | Windows x64；Linux / macOS 待测 | 本地 |
| Swift | XCTest | 261 | Windows；macOS / Linux 待测 | 本地 |
| TypeScript | Node 测试 | 223 | Windows / Linux / macOS | 本地 |
| JavaScript | Node 测试 | 223 | Windows / Linux / macOS | 本地 |
| R | 自研断言 + 双进程 demo | 211 + 五步链 | Windows x64（R 4.6.1 + Rtools45） | 本地 |
| Rust | cargo test | 174 | Windows / Linux / macOS | 本地 |
| Python | pytest | 155 | Windows / Linux / macOS | 本地 |
| Java | JUnit 5 | 145 | Windows / Linux | 本地 |
| Zig | Zig test + 冒烟程序 | 140+ | Windows x64；Linux / macOS / 32 位待测 | 本地 |
| C# | xUnit | 116 | Windows | 本地 |
| C++ | 自研 CI | 82 + 压测 + 并发 | Windows / Linux | ✅ GitHub |
| Erlang | EUnit | 四个套件 | Windows；Linux / macOS 待测 | 本地 |
| Go | go test | 18 | Windows / Linux / macOS | 本地 |
| Dart | Dart test | 完整套件 | Windows / Linux / macOS | 本地 |
| Pascal | 自研 | 完整开发套件 | Windows / Linux | 本地 |

> **口径说明**：上表的"测试数"为各语言测试项 / 套件数；各语言 README 中的"断言数"（如 Fortran 的 474 断言）可能高于此表的测试项数。详细数字见各语言目录。

---

## 跨语言互调（Cross Demo）

LingoFuse 的核心理念是 **"任何语言写的函数，任何其他语言都能直接调"**。为了验证这个承诺，**每种语言的绑定都自带一套名为 "Cross" 的三个程序**。

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

## 构建核心动态库

`src/` 是 LingoFuse 核心动态库（`LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib`）的唯一构建入口。需要准备 Pascal 编译环境（FPC / Lazarus），然后一键构建。

### 构建文档

| 文档 | 内容 |
|------|------|
| [**`src/CONTRIBUTING.md`**](src/CONTRIBUTING.md) | 构建环境搭建与工作流总览——第一次编译的入口 |

---

## 项目状态与边界

| 板块 | 状态 | 说明 |
|------|------|------|
| **核心通讯层** | ✅ 稳定 | C4 引擎、二进制帧、句柄、软同步、线程池全部就绪 |
| **十八语言第一方绑定** | ✅ 生产就绪 | Pascal / Python / C++ / C# / TypeScript / JavaScript / Rust / Go / Dart / Java / Swift / Zig / Erlang / Ruby / Fortran / Julia / R / PHP（PHP 为调用者） |
| **HTTP 桥接** | ✅ 可用 | `bridge.py` 网关，覆盖 Node.js / PHP / 浏览器 |
| **代码生成器体系** | ✅ 已完结 | [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools)：三条工具线（ABI / JSON / MCP），20+ 种目标语言 |
| **AI 知识库体系** | ✅ 已完善 | 覆盖所有接口，可辅助 AI 接管——生成代码需人工验证 |
| **内部机制知识库** | ✅ 已完善 | [`Z.LingoFuse.md`](Z.LingoFuse.md) v3.2，面向难缠语言 |
| **P2P 分布式概念** | ✅ 已完善 | [`LingoFuse_P2P_Distributed_Load_Concept.md`](LingoFuse_P2P_Distributed_Load_Concept.md) |
| **Pascal 完整指南** | ✅ 已完善 | [`LingoFuse_Pascal_Complete_Guide.md`](LingoFuse_Pascal_Complete_Guide.md) v7.0，95 条踩坑 ID |
| **CI 测试体系** | ⚠️ 仅 C++ 有 GitHub CI | `test/` 提供指南与可执行文件，源码在 `cpp/` 下；其他语言提供本地脚本 |
| **tsAgent** | 🚧 即将发布 | TypeScript / JavaScript 智能体运行时 |

### 明确不推荐的使用场景

- 需要成熟社区支持、大量第三方教程、Stack Overflow 问答的项目
- 无法接受单人维护风险，且没有自行编译、自行维护能力的团队
- 纯 TS/JS 项目，所有逻辑都可以用 TS/JS 重写，引入 LF 只会增加复杂度和故障点
- 需要 PHP 作为服务端的场景（PHP 只能作为调用者）
- 对并发性能有硬性要求，且不愿自行做 App 层 PoC 验证的团队
- **Flutter Web 项目**（Dart FFI 不可用）
- **32 位 Windows 项目**（Dart 绑定未测试）
- **Java 绑定需要 JDK 22+**，无法在 JDK 8 / 11 / 17 / 21 上直接运行
- **Swift 绑定需要 Swift 5.9+**（推荐 6.4），macOS / Linux 部署路径尚未实测
- **Zig 绑定锁定 Zig 0.17.0**，升级到 0.18+ 前需重新评估破坏性 API 变更；Linux / macOS / 32 位平台尚未验证
- **Erlang 绑定需要 Erlang/OTP 27+**，NIF 崩溃会拖垮 BEAM 节点；回调中不得调用阻塞型 LingoFuse 函数
- **Ruby 绑定需要 Ruby 4.0+（x64-mingw-ucrt）与 DevKit**，用于编译 C 扩展；Linux / macOS 路径待验证
- **Fortran 绑定需要 Fortran 2008 + C++17 工具链，且 C++ 与 Fortran 编译器必须来自同一套发行版**（否则 `__gfortran_*` 符号缺失）；Linux / macOS 理论可行但未实测
- **Julia 绑定强制 `--threads=2`**（回调 consumer 不能落在 main 线程，否则死锁）；`@threadcall` 并发上限受 libuv 线程池约束（默认 4，可用 `UV_THREADPOOL_SIZE` 提升）；Linux / macOS / Apple Silicon 尚未验证
- **R 绑定需要 R 4.0+ 与 Rtools45（Windows）** 才能编译桥接层；`LF_Call` 不可重入，单进程自测需改用 `lf_local_call`；受外部二进制依赖限制，无法提交 CRAN
- **Python 绑定**：同步族 handle 归调用者，异步族归框架（回调返回后立即释放）——混用会导致偶发 use-after-free
- **代码生成器产物**（LingoFuse-Tools）需要人工验证：生成器覆盖 Pascal / Python / C++ / C# / Rust / Go / Java / Node.js / TypeScript / Erlang / Julia / Zig / Swift / Ruby / Fortran / Dart / R 等语言，但生成代码的 App 层行为需要你自己的测试兜底

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

### 我是人类，这些是我亲手敲出来的

LingoFuse 是一个**真实人类作者**手工构建的项目。AI 在这个过程中承担的是**辅助角色**——帮助梳理文档、生成测试用例、整理代码结构。但项目的**灵魂**——架构决策、跨语言字节级互通的设计、C4 mesh 的调度逻辑、十几种语言绑定的接入方式——全部来自一个真实人类在深夜的反复调试和思考。

你可以查看 **[《LingoFuse · 十四语言实测手记》](https://zpascal.net/imhuman.html)**，那里记录了完整的操作过程：

> 屏幕那些暗色的窗口，是我连续两个晚上熬出来的。没有剪辑，没有脚本合成，没有摆拍。有些命令我敲错三遍才跑通，有些环境装到凌晨才发现是版本问题。报错就是报错，警告就是警告，通过就是通过。

手记中记录的都是真实细节：在 VS 2022 中逐行翻阅 71 KB 的 `NativeMethods.cs`、C++ 绑定构建后 14 个项目 0 警告的输出、压测面板上累计 46,515 次调用和 100.00% 成功率、Dart 环境装了快两个小时但测试 8 秒跑完、有些环境装到凌晨才发现是版本问题。

**AI 是工具，不是作者。** 这个项目从第一行 Pascal 核心代码到第十八个语言绑定，背后是一个真实人类的判断、试错和坚持。

欢迎来撩、来喷、来 PR——**Star 是最好的催更。**

---

*项目始于 2026 年，持续进化中。有问题提 Issue，急事加 Q（600585）。*

**采用前请务必：跑 `test/`，做 PoC，验证你自己的场景。**