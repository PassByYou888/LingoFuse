# LingoFuse

> **分布式系统地基。跨语言、跨进程、跨机器；同时支撑后台与前台。**
>
> 不写 IDL，不生成桩代码，不搭 HTTP 服务。任何语言写的函数，任何其他语言都能直接调。
>
> **定位**：LingoFuse 不只是"跨语言 RPC"——它是 **前沿型程序的多应用组合体系**与 **多物理硬件组合体系**的通讯底座，也是 **多语言团队生态互补的协作底座**。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Languages](https://img.shields.io/badge/languages-18%20first--party%20%2B%2030%20via%20tools-blue)]()
[![Latency](https://img.shields.io/badge/same--machine%20IPC-%3C1ms-brightgreen)]()
[![CI](https://img.shields.io/badge/CI-C%2B%2B%20only-orange)]()

> **作者的话**：LingoFuse 是我自己用的框架，顺手 MIT 开源。它没有融资目标、没有商业化路线、没有社区运营计划——开源的目的就是**帮助所有人**，没有别的。它的底层内核是从**单日 PB 级真实流量**中洗礼出来的，不是实验室里拼出来的。它在地球上没有竞品、没有前例，所以它能做出别人做不出的架构——甚至 AI + 人类组合也无法低成本复制的架构。分支项目（pasAgent-v3、cppAgent 等）会过时，但 LF 作为地基不会。星标少、人气低，但请不要被现象蒙蔽——它是真正的成长型项目，只要世界科技圈有个浪头，它就能起飞。详见下方 [项目性质](#项目性质自用开源无目的分享本身)。

---

## 目录

- [📚 文档知识库全景](#-文档知识库全景)
- [🧭 按身份的阅读路径](#-按身份的阅读路径)
- [项目性质：自用、开源、无目的、分享本身](#项目性质自用开源无目的分享本身)
- [这是什么](#这是什么)
- [⚠️ 使用门槛：这是黑科技，不是开箱即用](#️-使用门槛这是黑科技不是开箱即用)
- [为什么需要它](#为什么需要它)
- [快速开始](#快速开始)
- [语言支持](#语言支持)
- [多语言团队协作策略](#多语言团队协作策略)
- [代码生成器体系 · LingoFuse-Tools](#代码生成器体系--lingofuse-tools)
- [技术短文 · 内核与应用](#技术短文--内核与应用)
- [智能体运行时](#智能体运行时)
- [相关项目](#相关项目)
- [测试与验证](#测试与验证)
- [跨语言互调（Cross Demo）](#跨语言互调cross-demo)
- [依赖库](#依赖库)
- [构建核心动态库](#构建核心动态库)
- [项目状态与边界](#项目状态与边界)
- [许可证](#许可证)
- [关于作者](#关于作者)

---

## 📚 文档知识库全景

本仓库有 **11 份根目录核心文档 + 17 篇机制短文 + 3 份测试指南 + 18 种语言绑定文档**。不要试图一次读完——按你的身份和场景选择入口。下面是全景索引。

### 一、根目录核心文档

| 文档 | 一句话定位 | 适合谁读 |
|---|---|---|
| [readme.md](readme.md) | **本文件**——仓库入口、项目定位、阅读指引 | 所有人 |
| [llms.txt](llms.txt) | LLM 优化入口，所有关键事实 + 各语言测试规模 + 文档地图 | AI / 工具化检索 |
| [Z.LingoFuse.md](Z.LingoFuse.md) | **内部机制知识库 v4.0**——线程全景、回调上下文、Handle 所有权、P2P 身份侧数据、难缠语言集成 | 深度集成者、架构师、Julia/Erlang/R 开发者 |
| [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide.md) | **多语言完整指南 v2.0**——18 种绑定逐一展开、194 条踩坑 ID、工具链参考 | 所有集成者、AI 辅助开发 |
| [LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md](LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md) | **多语言部署指南 v3.0**——每语言工具链、版本要求、硬性坑、检查清单 | 部署工程师、DevOps |
| [LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept.md) | **P2P 分布式负载概念**——三套路由、UID 万能路由、本地短路、服务器本地处理、序列化族 | 架构师、后端工程师 |
| [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md) | **架构不可复刻性论证**——隐性契约密度、AI 接管边界 | 决策者、架构师、AI 研究者 |
| [LingoFuse_Private_Fork_Playbook.md](LingoFuse_Private_Fork_Playbook.md) | **私有化指南**——L0/L1/L2/L3 分级、隐性契约捕获、组织治理 | 组织决策者、技术管理者 |
| [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) | **团队接入支持策略**——分群、补齐短板、交付物清单 | 技术管理者、架构师 |
| [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md) | **生态互补与价值最大化策略**——A/B/C/D/E 分类、逐语言对照表 | 技术管理者 |
| [optimal_and_correct_technology_stack_selection.md](optimal_and_correct_technology_stack_selection.md) | **技术栈选型的哲学文章**——结构匹配优先于单项最优 | 技术决策者 |

### 二、内部机制短文（`doc/` 目录，17 篇）

**内核 10 篇**（机制是怎么实现的）：

| 短文 | 主题 |
|---|---|
| [LF_Handle_Ownership.md](doc/LF_Handle_Ownership.md) | 同步族句柄归你，异步族句柄归框架，混用必炸 |
| [LF_Simulated_Main_Thread.md](doc/LF_Simulated_Main_Thread.md) | LF 造了一个后台线程驱动 C4，但它**故意不**驱动 `LF_Sync` |
| [LF_WaitOnResult.md](doc/LF_WaitOnResult.md) | 一个 IO 同时只能有一个 Call 在飞，Notify 不受影响 |
| [LF_Sequenced_FIFO.md](doc/LF_Sequenced_FIFO.md) | FIFO 靠"每个 `(App, API)` 一个线程"实现，粒度很细 |
| [LF_ZeroCopy_Decode.md](doc/LF_ZeroCopy_Decode.md) | 解码一次 memcpy 都不做，靠 `Mapping` 零拷贝 |
| [LF_SwapUnderLock.md](doc/LF_SwapUnderLock.md) | LF 从不在锁里遍历，总是锁内换容器、锁外干活 |
| [LF_TBigList_Iterator.md](doc/LF_TBigList_Iterator.md) | `Next` 是先移动再判断，`while Next` 会漏首节点 |
| [LF_ThreadPool_Pick.md](doc/LF_ThreadPool_Pick.md) | 任务来了先让空闲 worker 消化，实在不够才扩容 |
| [LF_TCritical_Reuse.md](doc/LF_TCritical_Reuse.md) | 创建十万个临界区，句柄数几乎不涨，因为有回收池 |
| [LF_P2P_Identity.md](doc/LF_P2P_Identity.md) | UID 和 P2PName 是**发送方送来的侧数据**，不是查出来的 |

**应用 7 篇**（用这些机制做决策）：

| 短文 | 主题 |
|---|---|
| [LF_Cmd_Model_Choice.md](doc/LF_Cmd_Model_Choice.md) | 先问"要不要响应"，再问"吞吐够不够"，模型就定了 |
| [LF_Route_Choice.md](doc/LF_Route_Choice.md) | App 名找服务、UID 找客户端、P2PName 找一组，选错不报错会跑偏 |
| [LF_Startup_Order.md](doc/LF_Startup_Order.md) | 启动顺序不能乱，乱了是静默失败 |
| [LF_Error_In_Callback.md](doc/LF_Error_In_Callback.md) | 回调抛异常等于没抛，错误要在协议层传 |
| [LF_Reconnect_Strategy.md](doc/LF_Reconnect_Strategy.md) | LF 只给断线信号，重连行为是应用自己的事 |
| [LF_Concurrent_Send.md](doc/LF_Concurrent_Send.md) | `Send*` 是线程安全的，句柄不是——谁创建谁使用谁释放 |
| [LF_Debug_Mode.md](doc/LF_Debug_Mode.md) | 三个调试开关（Quiet / ConsoleOutput / debug）各管一摊 |

> **怎么读**：如果只是"想用起来"，先读**应用**那 7 篇——它们直接对应架构决策；如果想"知道底下发生了什么"，读**内核**那 10 篇——它们解释了应用层那些"看起来反直觉的约束"从哪来。

### 三、测试指南（`test/` 目录）

| 文档 | 内容 |
|---|---|
| [LingoFuse_Functional_Test_Guide.md](test/LingoFuse_Functional_Test_Guide.md) | 功能测试：82 项，覆盖 C++ RAII 层与序列化层 |
| [LingoFuse_Stress_Test_Guide.md](test/LingoFuse_Stress_Test_Guide.md) | 压力测试：Call / Notify / 混合模式的自评估 |
| [LingoFuse_Concurrent_Notify_Demo.md](test/LingoFuse_Concurrent_Notify_Demo.md) | 并发 Notify：高并发下 Notify 无损，完成屏障模式 |
| [test.zip](test/test.zip) | 预编译可执行文件（`test_lingofuse` / `StressService` / `ConcClient` 等） |

### 四、各语言绑定文档

| 语言 | 入口文档 | 深度指南 / 补充文档 |
|---|---|---|
| **Pascal** | [pascal/readme.md](pascal/readme.md) | [LingoFuse_Pascal_Complete_Guide.md](pascal/LingoFuse_Pascal_Complete_Guide.md) |
| **Python** | [Py/readme.md](Py/readme.md) | [Bridge_User_Guide.md](Py/lingofuse/Bridge_User_Guide.md) · [Cross_Demo_Guide_zh.md](Py/cross/Cross_Demo_Guide_zh.md) · [cross_bridge_architecture_zh.md](Py/cross/cross_bridge_architecture_zh.md) |
| **C / C++** | [cpp/README.md](cpp/README.md) | [LingoFuse_Cpp_Knowledge_Base.md](cpp/LingoFuse_Cpp_Knowledge_Base.md) · [json.hpp.md](cpp/json.hpp.md) |
| **C# / .NET** | [csharp/readme.md](csharp/readme.md) | [LingoFuse_CSharp_Complete_Guide.md](csharp/LingoFuse_CSharp_Complete_Guide.md) |
| **TypeScript** | [ts/README.md](ts/README.md) | [LingoFuse_TypeScript_Async_Fix_Report.md](ts/LingoFuse_TypeScript_Async_Fix_Report.md) |
| **JavaScript (Node.js)** | [js/readme.md](js/readme.md) | [PORTABILITY.md](js/PORTABILITY.md) · [LingoFuse_JS_Async_Fix_Report.md](js/LingoFuse_JS_Async_Fix_Report.md) · [LingoFuse_JS_Async_Ref_Fix_Report.md](js/LingoFuse_JS_Async_Ref_Fix_Report.md) |
| **Rust** | [rust/README.md](rust/README.md) | [CHANGELOG.md](rust/CHANGELOG.md) |
| **Go** | [go/README.md](go/README.md) | [go/cross/README.md](go/cross/README.md) |
| **Dart** | [dart/README.md](dart/README.md) | [dart/example/README.md](dart/example/README.md) |
| **Java** | [java/README.md](java/README.md) | — |
| **Swift** | [swift/README.md](swift/README.md) | — |
| **Zig** | [zig/README.md](zig/README.md) | — |
| **Erlang** | [erlang/README.md](erlang/README.md) | [Erlang_Binding_Pitfalls_Guide.md](erlang/Erlang_Binding_Pitfalls_Guide.md) · [LingoFuse_Erlang_Binding_Fix_Log.md](erlang/LingoFuse_Erlang_Binding_Fix_Log.md) |
| **Ruby** | [ruby/README.md](ruby/README.md) | [BUILD_AND_DEPLOY.md](ruby/BUILD_AND_DEPLOY.md) · [INSTALL_DEPENDENCIES.md](ruby/INSTALL_DEPENDENCIES.md) |
| **Fortran** | [fortran/README.md](fortran/README.md) | — |
| **Julia** | [julia/README.md](julia/README.md) | [Julia_ABI_Binding_Work_Report.md](julia/Julia_ABI_Binding_Work_Report.md) · [SHIM_MECHANISM_GUIDE.md](julia/c_ext/SHIM_MECHANISM_GUIDE.md) · [example/README.md](julia/example/README.md) |
| **R** | [r/README.md](r/README.md) | — |
| **PHP** | [php/readme.md](php/readme.md) | （仅 caller，需配合 `Py/lingofuse/bridge.py`） |

### 五、原生依赖说明

| 文档 | 内容 |
|---|---|
| [Binary/readme.md](Binary/readme.md) | `Binary/` 目录的运行时依赖清单、DLL 作用、PATH 配置、VC++ 可再分发包 |

### 六、工具链

| 工具链 | 位置 |
|---|---|
| **LingoFuse-Tools** | https://github.com/PassByYou888/LingoFuse-Tools |

---

## 🧭 按身份的阅读路径

| 你的身份 | 建议阅读顺序 |
|---|---|
| **第一次听说 LingoFuse** | 本文件 [项目性质](#项目性质自用开源无目的分享本身) → [这是什么](#这是什么) → [使用门槛](#️-使用门槛这是黑科技不是开箱即用) → [快速开始](#快速开始) |
| **想评估是否采用** | 本文件 [使用门槛](#️-使用门槛这是黑科技不是开箱即用) → [语言支持](#语言支持) → [测试与验证](#测试与验证) → [项目状态与边界](#项目状态与边界) → [LingoFuse_Functional_Test_Guide.md](test/LingoFuse_Functional_Test_Guide.md) |
| **已经是用户，想看生态** | 本文件 [智能体运行时](#智能体运行时) → [相关项目](#相关项目) → [llms.txt](llms.txt) |
| **想理解核心机制** | [Z.LingoFuse.md](Z.LingoFuse.md) → [doc/](doc/) 17 篇短文 → [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide.md) → [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md) |
| **想给某种语言写代码** | 该语言目录下的 README → [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide.md) 对应章节 → [LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md](LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md) 对应章节 |
| **想搞部署 / 运维** | [LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md](LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md) → [Binary/readme.md](Binary/readme.md) → [test/](test/) 三份指南 |
| **想做 P2P 分布式** | [LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept.md) → [LF_Route_Choice.md](doc/LF_Route_Choice.md) → [LF_Sequenced_FIFO.md](doc/LF_Sequenced_FIFO.md) |
| **要组织多语言团队** | [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) → [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md) → 本文件 [多语言团队协作策略](#多语言团队协作策略) |
| **要做私有化 / fork** | [LingoFuse_Private_Fork_Playbook.md](LingoFuse_Private_Fork_Playbook.md) → [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md) |
| **想让 AI 接管开发** | 本文件 [使用门槛 · AI 能做和不能做的事](#ai-能做和不能做的事慎用-ai-驱动-lingofuse) → [llms.txt](llms.txt) → [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide.md) |
| **想读简短机制短文** | [技术短文 · 内核与应用](#技术短文--内核与应用) → 按兴趣挑 17 篇之一 |
| **想学应用最佳实践** | [LF_Cmd_Model_Choice.md](doc/LF_Cmd_Model_Choice.md) / [LF_Route_Choice.md](doc/LF_Route_Choice.md) / [LF_Startup_Order.md](doc/LF_Startup_Order.md) / [LF_Error_In_Callback.md](doc/LF_Error_In_Callback.md) 等"应用"7 篇 |
| **想自己编译核心库** | 本文件 [构建核心动态库](#构建核心动态库) → [src/CONTRIBUTING.md](src/CONTRIBUTING.md) |
| **想用代码生成器铺多语言** | 本文件 [代码生成器体系](#代码生成器体系--lingofuse-tools) → [LingoFuse-Tools 仓库](https://github.com/PassByYou888/LingoFuse-Tools) |
| **想知道作者怎么做的** | 本文件 [关于作者](#关于作者) → [十四语言实测手记](https://zpascal.net/imhuman.html) |
| **想学技术栈选型哲学** | [optimal_and_correct_technology_stack_selection.md](optimal_and_correct_technology_stack_selection.md) |
| **只是想 Star 催更** | 右上角点 Star，然后看 [关于作者](#关于作者) |

---

## 项目性质：自用、开源、无目的、分享本身

> **这一节回答"LingoFuse 是什么"，比"这是什么"更靠前。** 不读这一节，后面的一切都容易被误读。

### 它是作者自用的框架

LingoFuse 不是为创业公司写的产品，不是为融资写的故事，不是为社区写的教程。它是**老张自己用的框架**——他需要一个能让自己不同语言、不同机器、不同硬件的程序互相说话的底座，市面上没有，就自己写了一个。

"自用"决定了它的很多属性：**单人维护**、**不做业务封装**、**不做跨平台工具链适配**、**不做"装好就能跑"**、**不做社区运营**。这些不是缺陷，是"自用框架顺手开源"的自然结果。**它不欠任何人一个产品级的交付。**

### 开源用 MIT，目的就是帮助所有人

MIT 协议的含义是：拿去用，拿去改，拿去卖，都不用谢我。**没有附加条款、没有商业授权、没有"开源版 vs 企业版"的双轨制。**

**LingoFuse 从诞生就不是为了赚钱，而是为了分享。**

### Vibe 辅助编程 + 文档，但不是放手 Vibe

LingoFuse 的开发过程中大量使用了 AI 辅助——读源码、梳理文档、生成测试用例、整理代码结构、补样板代码。老张把这套 AI 辅助体系叫"贾维斯"。

**但贾维斯不是司机，是施工队。** 接口设计、架构决策、文档思路——全部是人类提出的。**为什么大型架构不能放手给 AI？因为大型架构需要可控。** 可控意味着：每一个边界、每一个接口、每一个失败模式，都必须有人能说得清、测得准、兜得住。

**AI 在 LF 生态里的角色是加速器，不是架构师。** 而人类能当架构师的前提，是 LF 提供了**可被人类审计的接口规则**。这一点在 [使用门槛](#️-使用门槛这是黑科技不是开箱即用) 里有更详细的展开。

### 地球没有竞品，也没有前例

LingoFuse 的体系组合在开源世界里**没有等价物**：**零 IDL + 18 语言原生 FFI + 二进制线格式 + Handle 所有权 + P2P 侧数据 + 双隧道 + StableIO + HPC + 命令桥 + C4 mesh + 序列化族**——这个组合没有任何一个开源项目同时具备。

**没有前例，意味着两件事**：它能做出别人做不出的架构；AI + 人类组合也无法低成本复制它。关于第二点，[LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md) 有完整论证——核心是**隐性契约密度**：专家在内核里埋入防御性设计但不写进文档，AI 基于表面接口生成周边时无意中依赖了这些隐藏行为。当隐性契约密度超过阈值，完整描述系统的成本 ≥ 重新设计一个等价系统的成本。

### 底层内核：从单日 PB 级流量中洗礼出来

LingoFuse 的核心不是"写了一个 RPC 框架"。它的内核——C4 引擎、句柄池、软同步、线程池、零拷贝、序列化族、双隧道、StableIO、HPC、命令桥、交换空间——是**从单日 PB 级真实流量中锤炼出来的**。它的设计取舍（稳定性优先于并发性能、池化回收、锁内换容器锁外干活、零拷贝映射、软同步替代内核同步）都是**被真实流量逼出来的**，不是从教科书上抄来的。

### 分支项目会过时，LF 不会

LingoFuse 之上有很多分支项目——pasAgent、pasAgent-v3、cppAgent、csharpAgent，以及即将发布的 tsAgent。这些都是**用 LF 搭的建筑**，是作者追赶前沿技术时用 LF 做的实验和演示。**建筑会过时，地基不会。**

### 星标少、人气低，但它是真正的成长型项目

GitHub 星标数不是衡量一个基础设施项目的正确指标。LingoFuse 的星标不多，人气不高——这符合它的性质：它不追热点，不迎合大众，不做营销。**但请不要被现象蒙蔽。** LingoFuse 是真正的**成长型项目**：它的定位是"分布式系统地基"，这个定位的价值会随着 AI 时代的多应用组合、多物理硬件组合需求爆发而上升。**只要世界科技圈有个浪头**——AI Agent 爆发、多语言组合需求爆发、多硬件组合需求爆发、边缘计算爆发——**它就能起飞**。

---

## 这是什么

LingoFuse 是**分布式系统地基**。

### 地基层面：不止是 RPC

大多数"跨语言调用"的方案（gRPC / REST / HTTP POST），解决的是"**A 进程调 B 进程的一个函数**"。这是**点对点**问题。LingoFuse 解决的不是这个——它解决的是"**多个进程、多台机器、多种硬件、多种语言、多种应用，如何组合成一个可运行的系统**"。

它同时为**两面**提供地基：

- **分布式后台地基**：服务器、后台服务、AI Agent 后端、计算节点、存储节点之间如何互相发现、路由、负载均衡、断线重连、稳定会话。后台之间可以是同语言，也可以是异语言；可以同机，也可以跨机、跨 IDC。
- **分布式前台地基**：客户端、Agent 前端、设备端、浏览器、移动端、嵌入式如何接入这个系统——通过原生 FFI（桌面/移动/嵌入式）或 HTTP 桥接（浏览器/受限设备）。前台可以是一台机器，也可以是几万台设备。

**跨语言、跨进程、跨机器**，是它的**技术手段**，不是定位本身。真正的定位是：**让"分布式组合"成为默认能力，而不是需要额外搭建的基础设施。**

> **为什么是"地基"而不是"框架"**：因为地基是从真实生产流量中长出来的（见 [项目性质](#项目性质自用开源无目的分享本身)），不是设计出来的。它不规定你上面盖什么楼，但它保证你盖什么楼都不会塌。

### 多语言生态互补：不是每种语言都单打独斗

LingoFuse 的 18 种语言绑定不是孤立罗列的清单，而是**按生态互补原则协作的体系**。不同语言团队接入时，不是"每种语言都做全栈"，而是**让每种语言做它最擅长的事，用其他语言的长板补齐它的短板**：

- **强实现语言**（C++ / Rust / Zig）：做局部高性能实现，LF 提供高级 UI 宿主作为激励；
- **后台强项语言**（Go / Erlang）：做高并发、OTP 容错服务，LF 提供 Web / CS 前端支持；
- **综合工程化语言**（Java / C#）：做大型企业级主体工程，Pascal 退居工具环节提供代码生成器、调试工具、脚手架；
- **专业 API 节点**（Julia / R / Fortran / Python / Ruby）：做统计、数值、算法、脚本服务，是"服务器 + 前端"架构里 API 的最佳供给方，UI 不强制；
- **前端 UI 供给方**（Dart / Delphi / Pascal UI / TS/JS / Swift）：在 UI 层面尊重其能力，为强实现语言和后台语言提供高级 UI 宿主。

这套协作策略的完整设计见：

- [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) —— 各语言团队接入支持策略
- [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md) —— 生态互补与价值最大化策略

### AI 时代的两类组合体系

- **多应用组合体系**：一个系统不再是一个巨型应用，而是**多个 Agent / 多个应用 / 多个服务**的组合。LingoFuse 让它们之间的通讯像同进程函数调用一样简单。
- **多物理硬件组合体系**：一个系统不再是一台机器，而是**多台机器、多种硬件、多种算力**的组合。LingoFuse 的 C4 网格、P2P 负载、序列化族、二进制句柄就是为这个场景设计的。

### 为人类可控的多语言协作而生

LF 的接口规则（C ABI 59 个导出符号、三套寻址、Handle 所有权、P2P 侧数据）不是为了"让机器更好用"，是为了"**让人能控制机器**"。**LingoFuse 把"明确接口"做成了地基。** 它不是"让 AI 自己搭系统"的工具，它是"让人类在 AI 辅助下，仍然能对系统保持控制"的工具。

### 核心承诺一句话

**任何语言写的函数，任何其他语言都能直接调；任何机器上的应用，任何其他机器上的应用都能直接组合。**

- 不需要写 IDL
- 不需要生成桩代码
- 不需要搭 HTTP 服务
- 同机 IPC 延迟声称 < 1 ms
- 跨机原生支持，内置服务发现、负载均衡、FIFO 顺序保证和断线重连
- 18 种语言的一方绑定，20+ 种语言通过代码生成器覆盖

**它不是万能胶。** 采用之前，请务必读完 [使用门槛](#️-使用门槛这是黑科技不是开箱即用)、[测试与验证](#测试与验证) 和 [项目状态与边界](#项目状态与边界)。

---

## ⚠️ 使用门槛：这是黑科技，不是开箱即用

先说清楚性质：**LingoFuse 是黑科技基础设施，不是业务框架。** 它解决的是大多数团队根本不会去碰的底层问题——跨语言字节级互通、C4 mesh 调度、18 种语言的 FFI 绑定、多线程回调安全、Handle 所有权模型。**这些东西让它能做别人做不到的事，也让它对使用者的要求远高于普通库。**

### 它把最难的问题解决了

- **线格式语言无关**：任何语言的 CrossNode 写出的字节流，任何语言的 CrossCall 都能原样读出来。
- **零 IDL 的强类型调用**：C++ 声明 `int Add(int a, int b)`，C# / Rust / Swift / Java 都能直接 `Add(1, 2)`。
- **真·服务发现 + 负载均衡 + FIFO + 断线重连**：不用 etcd、不用 Nginx、不用自己写重试。
- **18 种语言的绑定**：从 ASM 级 C ABI 到 Dart / Julia / R，每种都跑通了自己的测试体系。
- **多应用 / 多硬件的分布式组合**：后台服务、AI Agent、计算节点、客户端、设备端，都可以在同一套地基上组合、路由、隔离。
- **多语言生态互补**：详见 [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) 与 [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md)。

### 它把最复杂的负担留给了你

LingoFuse **不做**下面这些事：

- **不做业务层封装**。它给你的是 `LF_Call` / `LF_Notify` / `LF_RegisterCall`，怎么组织你的 App 层、怎么切分服务、怎么做权限，都是你的工程决策。
- **不做线程抽象**。回调在 TCompute 工作线程跑，不在主线程；回调里不能调阻塞 LF 函数，否则自锁死；同步回调要靠主线程 `LF_Sync` 驱动。这些不是"读一遍文档就懂"的事，是必须在你自己的代码里反复调试才能养成肌肉记忆的事。
- **不做跨平台工具链适配**。每种语言的绑定都有各自的编译期陷阱：Java 需要 JDK 22+、Fortran 需要 C++ 与 Fortran 编译器来自同一发行版、Ruby 需要 DevKit、Julia 强制 `--threads=2`、Swift 的 macOS / Linux 路径还在验证中。这些坑你必须自己能处理。
- **不做"装好就能跑"**。核心动态库和生成器工具都有**预构建产物**，但**如果你需要的平台没有预构建版本**，或者预构建版本与你的运行时环境不匹配，你仍然需要自己编译。
- **不做社区支持**。单人维护，Issue 会回，但不保证 SLA，没有 Stack Overflow 问答，没有第三方教程。

### 采用前请自测四个问题

1. **你能否自行编译 LingoFuse 核心动态库？**
   预构建产物可以帮你跳过这一步——**但仅当你的平台和目标语言组合被预构建覆盖时**。
2. **你能否读懂回调线程模型，并在自己的代码中系统性避免死锁？**
   如果团队里没人能讲清楚"为什么回调里不能调 `LF_Call`"，先别用。
3. **你能否在出现问题时会读源码，而不是读注释？**
   文档里有 194 条踩坑 ID、20+ 种语言的生成器报告、[Z.LingoFuse.md](Z.LingoFuse.md) v4.0——但**注释是二手信息**。
4. **你是否愿意做 App 层 PoC，而不是相信 README 里的任何数字？**
   `test/` 提供的是**机理层竞态稳定性测试**，不是你的业务层测试。

**如果上面任何一条的答案是"不能"或"不愿意"，请直接选 gRPC / REST / 同进程方案。**

### AI 能做和不能做的事：慎用 "AI 驱动 LingoFuse"

**先说结论：不要让 AI 从零开始"驱动" LingoFuse 构建你的项目。这条路的工期会比你想象的翻好几倍。**

AI 在 LingoFuse 的生态里能做很多事——读生成器源码、读踩坑记录、通过 MCP 驱动 Tools 生成器、按契约写生成代码的 App 层、写测试断言。这些是 LingoFuse 明确设计给 AI 用的能力。

**但 AI 做不了一件事：设计你的架构。**

**正确的做法是：**

1. **你**先把 LingoFuse 跑通
2. **你**先设计出第一版架构
3. **你**先用自己最熟悉的语言手写一个最小可用的跨语言调用
4. **然后**再让 AI 进来——用 AI 加速 Tools 生成器的使用、用 AI 读踩坑记录、用 AI 补测试、用 AI 生成样板代码

**LingoFuse 的定位正是这个：多语言共同协作运行，接口规则明确、可被人类审计。** 关于"为什么即使 AI 读完源码和文档，复刻一个等价的 LF 仍然工程上不可达"，见 [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md)。

---

## 为什么需要它

跨语言、跨进程调用目前的现实：

- **gRPC**：要写 IDL、要生成桩代码、要搭网关；跨语言，但对"多应用组合 / 多硬件组合"没有直接支持。
- **REST**：延迟高、无流式、无服务发现。
- **HTTP POST**：天然跨机但无顺序保证、无服务发现。
- **同进程调用**：延迟极低但不跨语言、不跨机器。

### 两类组合问题，现有方案都不直接解决

- **多应用组合**：现有方案要么把每个 Agent 都套成一个 HTTP 服务，要么写一套中心化的消息总线。
- **多物理硬件组合**：现有方案要么靠 K8s + 消息队列（对数据形态不友好），要么靠手写 socket（工程成本极高）。

LingoFuse 的设计就是同时面向这两类问题：**C4 网格**解决多节点发现与路由，**P2P 负载 + 序列化族**解决多 worker 组合，**二进制句柄 + 零拷贝**解决大流量数据形态，**18 种语言绑定**解决多语言组合，**HTTP 桥接**解决受限平台接入。

### 稳定性优先于并发性能

> LingoFuse 把应用的稳定性放在第一位，并发性能往后挪移。这不是临时取舍，而是项目未来所有版本都会坚持的趋势。一个在高并发下会偶发崩溃、丢消息或死锁的通讯层，延迟再低也没有意义。
>
> 因此本项目**不在主 README 中做并发性能的横向对比**，实测数据以 [test/](test/) 目录为准。

---

## 快速开始

### 路径 A：直接使用预构建产物（Windows，推荐先试）

如果你在 Windows 上，只是想先跑通、再决定是否深入，**不需要从源码编译任何东西**。到 [release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build) 下载：

- **生成器工具**（Windows 平台预构建）：`code_decl_to_abi` / `code_decl_to_json_abi` / `code_decl_to_mcp` 的可执行文件；
- **动态库**（Windows 平台预构建）：`LingoFuse64.dll` / `LingoFuse32.dll` / `z_ipc_*.dll` / `mimalloc*.dll`。

把动态库放到 `PATH` 或可执行文件同目录，生成器工具直接运行即可。**这是最短的上手路径。**

> **预构建产物覆盖不到的平台 / 语言组合**（Linux / macOS 动态库、部分语言的生成器工具），仍然需要按路径 B 从源码构建。

### 路径 B：从源码构建 + 验证

**第一步：克隆仓库**

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
# 然后将 LingoFuse/Binary 目录加入系统 PATH
```

**第二步：阅读测试指南，运行预编译可执行文件**

进入 [test/](test/) 目录，里面有三份指南：

- [LingoFuse_Functional_Test_Guide.md](test/LingoFuse_Functional_Test_Guide.md) —— 功能测试
- [LingoFuse_Stress_Test_Guide.md](test/LingoFuse_Stress_Test_Guide.md) —— 压力测试
- [LingoFuse_Concurrent_Notify_Demo.md](test/LingoFuse_Concurrent_Notify_Demo.md) —— 并发通知

解压 [test.zip](test/test.zip)，运行预编译可执行文件。**得到的是你自己硬件上的真实数据。**

**第三步：如需深入，进入 [cpp/](cpp/) 目录自行编译 CI 测试**

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
|------|-----|------|-------------|
| C# / .NET | [csharp/](csharp/) | 🟢 生产就绪 | v5.1，116 项测试，P/Invoke + RAII + 统一 JSON I/O + `CallbackDispatcher` + 回调风格异步 |
| C++ | [cpp/](cpp/) | 🟢 生产就绪 | 唯一有 GitHub CI，原生 C ABI 零开销，异步模型 + 侧数据读取 |
| Dart | [dart/](dart/) | 🟢 生产就绪 | 完整 caller + server 能力，Flutter 移动端可用；C 桥接解决跨线程同步回调 |
| Erlang | [erlang/](erlang/) | 🟢 生产就绪 | OTP 27+，NIF 跨平台构建，37 个 C ABI 完整封装，零运行时依赖 |
| Fortran | [fortran/](fortran/) | 🟢 生产就绪 | 474 项断言，`iso_c_binding` + C++ 桥接层，Fortran 2008 |
| Go | [go/](go/) | 🟢 生产就绪 | purego 无 cgo，交叉编译友好；死锁看门狗补偿 runtime 误判 |
| Java | [java/](java/) | 🟢 生产就绪 | JDK 22+ FFM API，纯 Java 无 JNI；145 项测试，`ArenaReaper` 处理超时 stub |
| JavaScript | [js/](js/) | 🟢 生产就绪 | v2.0，223 项测试，CommonJS + ESM 双入口，与 TS 字节级互通 |
| Julia | [julia/](julia/) | 🟢 生产就绪 | C shim + `@threadcall` 跨线程回调隔离，**强制 `--threads=2`** |
| Pascal | [pascal/](pascal/) | 🟢 生产就绪 | 原生 FFI，完整指南见 [LingoFuse_Pascal_Complete_Guide.md](pascal/LingoFuse_Pascal_Complete_Guide.md) |
| Python | [Py/](Py/) | 🟢 生产就绪 | `pip install -e .` 即用，含 `@expose` 装饰器与 HTTP 网关；知识库含 Handle 所有权 + 侧数据勘误 |
| R | [r/](r/) | 🟢 生产就绪 | 四层架构 + Job 队列跨线程回调；RAII 句柄；字符串 / 二进制双模式；R 4.6.1 + Rtools45 |
| Ruby | [ruby/](ruby/) | 🟢 生产就绪 | v2.0，331 项测试，Fiddle + C 扩展，完整 caller / server 双向能力 |
| Rust | [rust/](rust/) | 🟢 生产就绪 | v2.0，174 项测试，闭包式异步，`call_async_wait` 返回 `Vec<u8>` |
| Swift | [swift/](swift/) | 🟢 生产就绪 | v1.1，261 项 XCTest，`@convention(c)` 回调，C++ ↔ Swift 双向字节级互调已验证 |
| TypeScript | [ts/](ts/) | 🟢 生产就绪 | v2.0，223 项测试，支持 Node / Deno / Bun，三风格 × 三寻址 |
| Zig | [zig/](zig/) | 🟢 生产就绪 | 锁定 Zig 0.17.0，`c/lf_json.cpp` 保 JSON 字节一致，140+ 项测试 |
| PHP | [php/](php/) | 🟡 调用者接入 | 经 [Py/lingofuse/bridge.py](Py/lingofuse/bridge.py) HTTP 网关，只能作为调用者 |

**每种语言的深度文档**：每个语言目录下都有独立的 README，涵盖该语言的初始化、回调、寻址、清理顺序、常见坑。跨语言比对 + 194 条踩坑 ID 见 [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide.md)；每语言工具链、版本硬要求、部署检查清单见 [LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md](LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md)。

---

## 多语言团队协作策略

LingoFuse 的 18 种语言绑定不是"每种语言都做全栈"的清单，而是**按生态互补原则协作的体系**。不同语言团队接入时，支持策略和"奴役"策略是两套互补的文档：

### [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) —— 团队接入支持策略

- **分群**：强实现语言（C++ / Rust / Zig）、后台强项语言（Go / Erlang）、综合工程化语言（Java / C#）、专业 API 节点（Julia / R / Fortran / Python / Ruby）、前端 UI 供给方（Dart / Delphi / Pascal UI / TS/JS / Swift）、工具链与服务方（Pascal 后台形态 / LingoFuse-Tools）。
- **补齐短板**：强实现语言缺高级 UI → LF 提供 UI 宿主；后台语言缺前端 → LF 提供 Web/CS 前端；封闭生态缺前沿 API → LF 提供现代 API 封装；工程化语言做主体 → Pascal 退居工具环节。
- **交付物清单**：限制清单、服务/调用模板、UI 或 API 宿主模板、共性契约培训、机理 PoC 路径、二进制/JSON 双通道示例、工具链使用指南。
- **落地路线**：先分群再派活，A 类给高级 UI 激励，B 类给前端支持，C 类给主体工程地位，D 类明确为 API 供给方，E 类在 UI 层面尊重其能力，F 类提供工具链与机理 PoC 路径。

### [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md) —— 生态互补与价值最大化策略

- **内部"奴役"不是贬义**，而是让每种语言团队在其最擅长的领域心甘情愿地贡献，同时用统一架构补齐其短板，实现整体系统价值最大化。
- **核心操作原则**：解决目标语言的短板，用统一化全栈语言高度进行全面高端开发。
- **分类"奴役"策略**：A 类强实现语言做局部核心 + 高级 UI 激励；B 类后台语言做后台核心 + 前端支持；C 类工程化语言做主体工程 + Pascal 工具链；D 类专业 API 节点做统计/数值/算法服务；E 类前端 UI 语言做 UI 供给方 + AI API 消费方；F 类脚本/胶水语言做 API 节点。
- **逐语言对照表**：每种语言的"让他们做什么 / 我们补什么 / UI 形态"一目了然。

**核心操作原则**：

> **解决目标语言的短板，用统一化全栈语言高度进行全面高端开发。** 让每种团队做其最擅长的事，同时用其他语言的"长板"补齐其"短板"，实现整体系统价值最大化。
>
> **互补是双向的**：E 类（前端 UI 供给方）不只是"给 A 类供 UI"，他们**同样需要 LF 补齐自己的短板**——前沿 AI 能力（人脸识别、目标检测、OCR、语音识别、智能体编排）。E 类既是供给方，也是消费方。

---

## 代码生成器体系 · LingoFuse-Tools

LingoFuse 的第一方绑定是**手写**的。当你要把同一组 API 铺到十几种语言时，手写绑定会变成重复劳动——而且每种语言的线格式只要差一个字节，跨语言互调就会静默失败。

[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) 解决的就是这个问题：**从一份 API 声明（Pascal 单元或 C 头文件）出发，自动产出多语言的 service / call 代码、测试程序和构建脚本**。

### 三条工具线，三种协议

| 工具 | 产出协议 | 适用场景 |
|------|----------|----------|
| **`code_decl_to_abi`** | LingoFuse 二进制 ABI | 两端都是 LingoFuse 原生、高并发、数值 / 二进制重载荷 |
| **`code_decl_to_json_abi`** | HTTP + JSON（经 `bridge.py`） | 一端是浏览器、外部 HTTP 客户端，或没有 LingoFuse 绑定的语言 |
| **`code_decl_to_mcp`** | MCP | 把函数暴露为 AI Agent 可调用的工具 |

> **同一份声明，三条路径。** 改一次声明，ABI / JSON / MCP 三套产物一起刷新。

### 生成器覆盖的目标语言

Tools 当前覆盖 **20+ 种目标语言**，每种都含 service 侧、call 侧、测试程序和一套 `setup_*_tests.ps1` 环境脚本。生成器的后端为**无限扩展**设计——加一种语言是机械的 8 步流程，不是架构变更。

| 目标语言 | Service | Call | 编译器 / 运行时 |
|----------|:-------:|:----:|----------------|
| C# | ✅ | ✅ | .NET 8.0+ |
| C++ | ✅ | ✅ | C++17 编译器 |
| Dart | ✅ | ✅ | Dart 3.0+ |
| Erlang | ✅ | ✅ | Erlang/OTP 25+ |
| Fortran | ✅ | ✅ | gfortran 9+ / ifort / flang |
| Go | ✅ | ✅ | Go 1.21+（Service 需 cgo） |
| Java | ✅ | ✅ | JDK 11+（FFM 需 22+） |
| JavaScript | ❌ | ✅ | 现代浏览器 |
| Julia | ✅ | ✅ | Julia 1.9+（**必须 `--threads=2`**） |
| Node.js | ✅ | ✅ | Node.js 18+ |
| Pascal | ✅ | ✅ | FPC 3.2+ / Delphi 10.4+ |
| PHP | ❌ | ✅ | PHP 7.4+ |
| Python | ✅ | ✅ | CPython 3.7+ |
| R | ✅ | ✅ | R 4.0+ |
| Ruby | ✅ | ✅ | Ruby 2.7+ / 3.0+ |
| Rust | ✅ | ✅ | Rust 1.70+（2021 edition） |
| Swift | ✅ | ✅ | Swift 5.9+（推荐 6.4） |
| TypeScript | ✅ | ✅ | TypeScript 5.0+、Node 18+、`tsx` |
| Zig | ✅ | ✅ | Zig 0.13+ |
| Delphi | ❌ | ✅ | Delphi 10.3+ |

**关键边界**：**Service 侧必须运行在桌面 / 服务器**（Windows / Linux / macOS）。**iOS / Android / WASM / 嵌入式无法运行 Service**——LingoFuse 原生库不支持这些平台。需要移动端提供接口时，把 Service 部署到服务器，移动端作为 Call 通过桥接访问。

### 代码生成器不是"黑盒"

Tools 仓库同时承载了三类可读资产：

- **生成器源码**：每种语言的 service / call / test / setup 生成器都是独立的实现单元。
- **输入契约**：**哪些声明会被提取、哪些会被静默丢弃**，写得比大多数 IDL 文档都细。
- **各语言踩坑记录**：记录了"我以为"被实测推翻的地方——线格式不对齐、回调线程挂死、`int64` 在 JS 丢精度、`bridge.py` 预检缓存延迟导致 `-3` 错误等。

> **AI 可以直接读这些生成器源码和踩坑记录来接管工具链的"使用"——但接管不了你的"架构"。** 详见 [使用门槛](#️-使用门槛这是黑科技不是开箱即用) 里的"AI 能做和不能做的事"。

👉 **[进入 LingoFuse-Tools 仓库，查看生成器源码、输入契约和踩坑记录](https://github.com/PassByYou888/LingoFuse-Tools)**

---

## 技术短文 · 内核与应用

十七篇短文，每篇讲一个机制或一个应用决策。不重复完整文档里的细节——只讲清楚"为什么这样设计"和"踩坑在哪"。每篇都有一张精炼流程图和一张契约表。

**LF 内核：机制是怎么实现的**

- [LF_Handle_Ownership.md](doc/LF_Handle_Ownership.md) — 同步族句柄归你，异步族句柄归框架，混用必炸
- [LF_Simulated_Main_Thread.md](doc/LF_Simulated_Main_Thread.md) — LF 造了一个后台线程驱动 C4，但它**故意不**驱动 `LF_Sync`
- [LF_WaitOnResult.md](doc/LF_WaitOnResult.md) — 一个 IO 同时只能有一个 Call 在飞，Notify 不受影响
- [LF_Sequenced_FIFO.md](doc/LF_Sequenced_FIFO.md) — FIFO 靠"每个 `(App, API)` 一个线程"实现，粒度很细
- [LF_ZeroCopy_Decode.md](doc/LF_ZeroCopy_Decode.md) — 解码一次 memcpy 都不做，靠 `Mapping` 零拷贝
- [LF_SwapUnderLock.md](doc/LF_SwapUnderLock.md) — LF 从不在锁里遍历，总是锁内换容器、锁外干活
- [LF_TBigList_Iterator.md](doc/LF_TBigList_Iterator.md) — `Next` 是先移动再判断，`while Next` 会漏首节点
- [LF_ThreadPool_Pick.md](doc/LF_ThreadPool_Pick.md) — 任务来了先让空闲 worker 消化，实在不够才扩容
- [LF_TCritical_Reuse.md](doc/LF_TCritical_Reuse.md) — 创建十万个临界区，句柄数几乎不涨，因为有回收池
- [LF_P2P_Identity.md](doc/LF_P2P_Identity.md) — UID 和 P2PName 是**发送方送来的侧数据**，不是查出来的

**LF 应用：用这些机制做决策**

- [LF_Cmd_Model_Choice.md](doc/LF_Cmd_Model_Choice.md) — 先问"要不要响应"，再问"吞吐够不够"，模型就定了
- [LF_Route_Choice.md](doc/LF_Route_Choice.md) — App 名找服务、UID 找客户端、P2PName 找一组，选错不报错会跑偏
- [LF_Startup_Order.md](doc/LF_Startup_Order.md) — 启动顺序不能乱，乱了是静默失败
- [LF_Error_In_Callback.md](doc/LF_Error_In_Callback.md) — 回调抛异常等于没抛，错误要在协议层传
- [LF_Reconnect_Strategy.md](doc/LF_Reconnect_Strategy.md) — LF 只给断线信号，重连行为是应用自己的事
- [LF_Concurrent_Send.md](doc/LF_Concurrent_Send.md) — `Send*` 是线程安全的，句柄不是——谁创建谁使用谁释放
- [LF_Debug_Mode.md](doc/LF_Debug_Mode.md) — 三个调试开关（Quiet / ConsoleOutput / debug）各管一摊

> **怎么读**：如果只是"想用起来"，先读**应用**那七篇——它们直接对应架构决策；如果想"知道底下发生了什么"，读**内核**那十篇——它们解释了应用层那些"看起来反直觉的约束"从哪来。

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

> **关于分支项目会过时**：上面的 Agent 运行时是**用 LF 搭的建筑**，是作者追赶前沿技术时用 LF 做的实验和演示。它们会随着 AI 技术演进被更新、被替代、被淘汰——这很正常。**建筑会过时，地基不会。**

---

## 相关项目

- [zIPC](https://github.com/PassByYou888/zIPC) —— LingoFuse 底层的同机 IPC 引擎。只需要同机 IPC 不需要完整 RPC 网格时，可直接使用。
- [ZNetV2](https://github.com/PassByYou888/ZNetV2) —— PassByYou888 技术栈中面向大规模服务器端数据吞吐的通讯框架。
- [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) —— 代码生成器体系，从 API 声明自动产出多语言绑定。包含三条工具线：`code_decl_to_abi`（二进制 ABI）、`code_decl_to_json_abi`（HTTP/JSON）、`code_decl_to_mcp`（MCP 工具提供者）。

---

## 测试与验证

**以 [test/](test/) 为准。**

对 README 中的任何描述拿不准——延迟、顺序、稳定性、并发下的行为——**不要去猜，去 [test/](test/) 目录找实物印证。**

`test/` 提供了 **PoC（Proof of Concept）概念验证**的一部分工作。在产品中使用 LingoFuse 体系，请注意：

1. **作者提供了竞态稳定性测试（最重要的机理层测试），但不是用户的 App 层测试。** 用户需要自己模拟自己的 App 层跑 PoC。
2. **用户需要掌握构建编译 LF 的技能。** LingoFuse 由老张开发，如果长期不维护，用户需要自己动手编译，跟上最新的代际更新。
3. **各个语言原则上都会有自己的 test、CI 体系。** 目前 18 种语言都有各自能跑的 test，但 **GitHub 托管 CI 只有 C++ 的**。

### 测试指南（三份）

| 文档 | 内容 | 可执行文件 |
|---|---|---|
| [LingoFuse_Functional_Test_Guide.md](test/LingoFuse_Functional_Test_Guide.md) | 功能测试：82 项，覆盖 C++ RAII 层与序列化层 | `test_lingofuse` / `test_lingofuse_json` |
| [LingoFuse_Stress_Test_Guide.md](test/LingoFuse_Stress_Test_Guide.md) | 压力测试：Call / Notify / 混合模式，输出吞吐、延迟、稳定性 | `StressService` / `StressClient` / `StressMonitor` |
| [LingoFuse_Concurrent_Notify_Demo.md](test/LingoFuse_Concurrent_Notify_Demo.md) | 并发 Notify：20 批 × 10000 条消息，零丢失，含完成屏障模式 | `ConcService` / `ConcClient` |

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

> **口径说明**：上表的"测试数"为各语言测试项 / 套件数；各语言 README 中的"断言数"可能高于此表。详细数字见各语言目录。

---

## 跨语言互调（Cross Demo）

LingoFuse 的核心理念是 **"任何语言写的函数，任何其他语言都能直接调"**。为了验证这个承诺，**每种语言的绑定都自带一套名为 "Cross" 的三个程序**。

### 三个进程的角色

| 程序 | 角色 | 说明 |
|---|---|---|
| `CrossService` | 协调器（信标） | 创建 IPC 端点 `ipc:cross`，不注册任何 API |
| `CrossNode` | 工作节点 | 注册 `demo` 应用的 `add` / `inv_seri` 两个 API |
| `CrossCall` | 负载测试客户端 | 32 线程 × 10 秒压测 `demo` 应用 |

### 共享线格式契约

```
add       (int32 a, int32 b)                       -> int32
inv_seri  (uint8, uint16, uint32, uint64,
           string(NUL), float)                     -> reversed types
```

String = UTF-8 + NUL；整数 = 小端序；浮点 = IEEE 754 小端序。**任何语言的 `CrossCall` 能正确读取另一语言 `CrossNode` 写出的字节，就证明这两个语言 100% 互通。**

### Cross Demo 位置

| 语言 | 位置 |
|---|---|
| Pascal | `pascal/cross_demo/` |
| C++ | `cpp/CrossDemo/` |
| C# | `csharp/CrossService/` / `csharp/CrossNode/` / `csharp/CrossCall/` |
| Swift | `swift/Sources/CrossService/` / `CrossNode/` / `CrossCall/` |
| Zig | `zig/examples/`（`cross_service.zig` / `cross_node.zig` / `cross_call.zig`） |
| Erlang | `erlang/cross/`（`cross_service.escript` / `cross_node.escript` / `cross_call.escript`） |
| Ruby | `ruby/cross/`（`cross_service.rb` / `cross_node.rb` / `cross_call.rb`） |
| Fortran | `fortran/cross_demo/` |
| Julia | `julia/example/`（[CrossService.jl](julia/example/CrossService.jl) / [CrossNode.jl](julia/example/CrossNode.jl) / [CrossCall.jl](julia/example/CrossCall.jl)） |
| R | `r/c_ext/tests/cross_node.R`（配 `cross_client.cpp`） |
| Rust | `rust/examples/` |
| Go | `go/cross/`（[README](go/cross/README.md)） |
| TypeScript | `ts/cross/` |
| JavaScript | `js/cross/` |
| Python | `Py/cross/`（[Cross_Demo_Guide_zh.md](Py/cross/Cross_Demo_Guide_zh.md)） |
| Java | `java/src/main/java/lingofuse/demo/cross/` |
| Dart | `dart/bin/`（探针含 Cross 场景） |

### 已验证的互调方向

| 方向 | 结果 |
|---|---|
| Swift ↔ C++ | ✅ 已验证 |
| Zig ↔ C++ / C# / Rust / Go / Python / JavaScript | ✅ 字节级兼容 |
| Erlang ↔ C++ / C# / Python / JavaScript | ✅ 字节级互通 |
| Ruby ↔ C++ / C# / Python / JavaScript | ✅ 字节级兼容 |
| Fortran ↔ C++ | ✅ 已验证 |
| Julia ↔ C++ / C# / Pascal / Python / JavaScript | ✅ 字节级兼容 |
| R ↔ C++ | ✅ 已验证 |
| Pascal ↔ C++ | ✅ 已验证 |
| C# ↔ C++ | ✅ 已验证 |
| Rust ↔ C++ | ✅ 已验证 |

---

## 依赖库

### 预构建动态库（Windows，推荐）

到 [release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build) 下载 Windows 平台预构建动态库：

| 平台 | 核心库 | IPC 依赖 | 内存分配器 |
|------|--------|----------|------------|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |

> **Linux / macOS 动态库**需要按 [src/CONTRIBUTING.md](src/CONTRIBUTING.md) 自己编译。

### 仓库内 `Binary/` 目录

[Binary/](Binary/) 目录提供 Windows 32/64 位预编译库（与 `pre_build` 同源）：

| 平台 | 核心库 | IPC 依赖 | 内存分配器 |
|------|--------|----------|------------|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` | `libmimalloc.so`（可选） |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` | `libmimalloc.dylib`（可选） |

**部署方式**：将 `Binary/` 目录加入系统 `PATH`，或把动态库复制到可执行文件同目录。

**详细的运行时依赖说明见 [Binary/readme.md](Binary/readme.md)。**

Windows 下需安装 **VC++ 2015-2022 可再发行程序包**：
- x64 直链：[vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe)
- x86 直链：[vc_redist.x86.exe](https://aka.ms/vs/17/release/vc_redist.x86.exe)

---

## 构建核心动态库

如果你需要的平台 / 架构 **没有被 `release pre_build` 或 `Binary/` 覆盖**（例如 Linux / macOS 动态库、特定架构的生成器工具），你需要从源码构建。

`src/` 是 LingoFuse 核心动态库（`LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib`）的唯一构建入口。需要准备 FPC / Lazarus 工具链，然后一键构建。

### 构建文档

| 文档 | 内容 |
|------|------|
| [src/CONTRIBUTING.md](src/CONTRIBUTING.md) | 构建环境搭建与工作流总览——第一次编译的入口 |
| [src/CONTRIBUTING_lazbuild.md](src/CONTRIBUTING_lazbuild.md) | lazbuild CLI 一键构建；含 LoongArch64 手动构建步骤 |
| [src/FPC_3.3.1_Package_Info.md](src/FPC_3.3.1_Package_Info.md) | FPC 3.3.1 环境包信息 |
| [src/Lazarus_Change_FPC.md](src/Lazarus_Change_FPC.md) | 在 Lazarus 中切换 FPC 版本 |

### 核心构建文件

| 文件 | 用途 |
|---|---|
| `src/build.bat` | Windows 一键构建脚本 |
| `src/LingoFuse.lpi` | Lazarus 项目文件 |
| `src/LingoFuse.lpr` | 项目主程序文件 |
| `src/Z.LingoFuse_Core.pas` | 核心引擎实现 |
| `src/Z.LingoFuse_Export.pas` | C ABI 导出层 |

一键构建：

```bash
cd src
lazbuild LingoFuse.lpi
```

> **注意**：FPC 工具链有版本锁定——所有构建机必须使用同一份 FPC 3.3.1 构建源，否则会出现 `PPU version mismatch`。详见 [src/CONTRIBUTING.md](src/CONTRIBUTING.md)。

---

## 项目状态与边界

| 板块 | 状态 | 说明 |
|------|------|------|
| **核心通讯层** | ✅ 稳定 | C4 引擎、二进制帧、句柄、软同步、线程池全部就绪 |
| **十八语言第一方绑定** | ✅ 生产就绪 | C# / C++ / Dart / Erlang / Fortran / Go / Java / JavaScript / Julia / Pascal / Python / R / Ruby / Rust / Swift / TypeScript / Zig / PHP（PHP 为调用者） |
| **多语言团队协作策略** | ✅ 已完善 | [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) + [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md) |
| **HTTP 桥接** | ✅ 可用 | `bridge.py` 网关，覆盖 Node.js / PHP / 浏览器 |
| **代码生成器体系** | ✅ 已完结 | [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools)：三条工具线，20+ 种目标语言 |
| **AI 知识库体系** | ✅ 已完善 | 覆盖所有接口，可辅助 AI 接管**接口层和样板层**——**接管不了架构层** |
| **内部机制知识库** | ✅ 已完善 | [Z.LingoFuse.md](Z.LingoFuse.md) v4.0，面向难缠语言（含 Handle 所有权 + P2P 身份侧数据） |
| **P2P 分布式概念** | ✅ 已完善 | [LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept.md) |
| **架构不可复刻性** | ✅ 已完善 | [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md) |
| **私有化指南** | ✅ 已完善 | [LingoFuse_Private_Fork_Playbook.md](LingoFuse_Private_Fork_Playbook.md) |
| **LLM 入口** | ✅ 已完善 | [llms.txt](llms.txt) |
| **技术短文（内核 + 应用）** | ✅ 已完善 | 17 篇短文，见 [技术短文 · 内核与应用](#技术短文--内核与应用) |
| **CI 测试体系** | ⚠️ 仅 C++ 有 GitHub CI | [test/](test/) 提供指南与可执行文件；其他语言提供本地脚本 |
| **预构建产物** | ✅ Windows 可用 | [release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build)；Linux / macOS 需自行编译 |
| **tsAgent** | 🚧 即将发布 | TypeScript / JavaScript 智能体运行时 |

---

## 许可证

**MIT** —— 拿去用，拿去改，拿去卖，都不用来谢我。

**这不是一句客套话。** LingoFuse 从诞生就不是为了赚钱，而是为了分享本身。MIT 是这个态度的法律表达——没有附加条款、没有商业授权、没有"开源版 vs 企业版"的双轨制。详见 [项目性质](#项目性质自用开源无目的分享本身)。

---

## 关于作者

**老张（QQ: 600585）**

看不惯跨语言调用得写一箩筐胶水代码，干脆撸了 LingoFuse。
现在又看不惯每种语言都得手写绑定，干脆把代码生成器也撸完了。
再把知识库喂给 AI，让 AI 自己把接口全部接管。

**让所有编程语言平等对话** —— 不是口号，是正在发生的事。

### 我是人类，这些是我亲手敲出来的

LingoFuse 是一个**真实人类作者**手工构建的项目。AI 在这个过程中承担的是**辅助角色**——帮助梳理文档、生成测试用例、整理代码结构。但项目的**灵魂**——架构决策、跨语言字节级互通的设计、C4 mesh 的调度逻辑、十几种语言绑定的接入方式——全部来自一个真实人类在深夜的反复调试和思考。

你可以查看 **[《LingoFuse · 十四语言实测手记》](https://zpascal.net/imhuman.html)**，那里记录了完整的操作过程。

**AI 是工具，不是作者。**

### 为什么开源

因为**分享本身**。老张不缺这个项目带来的钱，也不指望它带来名声。他把它开源，是因为他知道世界上还有别人需要这个东西——那些被 gRPC 的 IDL 折磨的人，那些被 REST 的延迟折磨的人，那些想把 GPU 节点、CPU 集群、嵌入式设备、工作站组合成一个系统的人，那些在 AI 时代需要多 Agent 协作但不想为每种组合写网关的人。

### 星标少，但它是成长型项目

GitHub 星标数不是衡量一个基础设施项目的正确指标。LF 的星标不多，但它：

- 追的是"多应用组合 + 多硬件组合"这个长期趋势，不是某一个具体的浪头；
- 内核是从单日 PB 级真实流量中洗礼出来的，不是实验室里拼出来的；
- 18 种语言绑定、20+ 种生成器覆盖、完整测试体系、完整知识库——都是**已经跑通的实物**。

**只要世界科技圈有个浪头，它就能起飞。** 它不需要"现在就很火"，它需要的是"在浪头来的时候，已经准备好了"。

欢迎来撩、来喷、来 PR——**Star 是最好的催更。**

---

*项目始于 2026 年，持续进化中。有问题提 Issue，急事加 Q（600585）。*

**采用前请务必：跑 [test/](test/)，做 PoC，验证你自己的场景。**