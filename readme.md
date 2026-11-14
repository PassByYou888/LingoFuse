# LingoFuse

> **分布式系统地基。跨语言、跨进程、跨机器；同时支撑后台与前台。**
>
> 不写 IDL，不生成桩代码，不搭 HTTP 服务。任何语言写的函数，任何其他语言都能直接调。
>
> **定位**：LingoFuse 不只是"跨语言 RPC"——它是**前沿型程序的多应用组合体系**与**多物理硬件组合体系**的通讯底座，也是**多语言团队生态互补的协作底座**。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Languages](https://img.shields.io/badge/languages-18%20first--party%20%2B%2030%20via%20tools-blue)]()
[![Latency](https://img.shields.io/badge/same--machine%20IPC-%3C1ms-brightgreen)]()

> **作者的话**：LingoFuse 是我自己用的框架，顺手 MIT 开源。它没有融资目标、没有商业化路线、没有社区运营计划——开源的目的就是**帮助所有人**，没有别的。它的底层内核是从**单日 PB 级真实流量**中洗礼出来的，不是实验室里拼出来的。它在地球上没有竞品、没有前例，所以它能做出别人做不出的架构——甚至 AI + 人类组合也无法低成本复制的架构。分支项目（pasAgent-v3、cppAgent 等）会过时，但 LF 作为地基不会。星标少、人气低，但请不要被现象蒙蔽——它是真正的成长型项目，只要世界科技圈有个浪头，它就能起飞。详见下方[项目性质](#项目性质自用开源无目的分享本身)。

---

## 你现在在哪

如果你是第一次打开这个仓库，建议按下面的顺序往下读——每一步只花几分钟，读完就能判断自己该继续深入，还是直接换个方案。

1. **[这是什么](#这是什么)** — 三分钟讲清 LingoFuse 到底解决什么问题
2. **[使用门槛](#使用门槛这是黑科技不是开箱即用)** — 说实话：它不适合所有人，你得先确认自己是不是目标用户
3. **[为什么需要它](#为什么需要它)** — 和 gRPC / REST / 消息队列比，它到底不同在哪
4. **[快速开始](#快速开始)** — Windows 上最短的上手路径，不需要编译任何东西
5. **[语言支持](#语言支持)** — 挑一种你最熟悉的语言，进入对应目录继续

如果你已经决定要用了，可以直接跳到[语言支持](#语言支持)或[快速开始](#快速开始)。如果你想理解内部机制，从[技术短文 · 内核与应用](#技术短文--内核与应用)那 17 篇短文里挑一篇看——它们每一篇都独立可读；更完整的机制知识库在 [Z.LingoFuse.md](Z.LingoFuse.md)。如果你是团队负责人，先看[多语言团队协作策略](#多语言团队协作策略)和[项目性质](#项目性质自用开源无目的分享本身)。

---

## 这是什么

LingoFuse 是一个**分布式系统地基**。

大多数人第一次听到"跨语言 RPC"，想到的是 gRPC、REST、HTTP POST——这些方案解决的是"**A 进程调 B 进程的一个函数**"，这是**点对点**问题。LingoFuse 解决的不是这个，它解决的是"**多个进程、多台机器、多种硬件、多种语言、多种应用，如何组合成一个可运行的系统**"。

换句话说，它同时为两面提供地基：

- **分布式后台地基**：服务器、后台服务、AI Agent 后端、计算节点、存储节点之间如何互相发现、路由、负载均衡、断线重连、稳定会话。后台之间可以是同语言，也可以是异语言；可以同机，也可以跨机、跨 IDC。
- **分布式前台地基**：客户端、Agent 前端、设备端、浏览器、移动端、嵌入式如何接入这个系统——通过原生 FFI（桌面/移动/嵌入式）或 HTTP 桥接（浏览器/受限设备）。前台可以是一台机器，也可以是几万台设备。

跨语言、跨进程、跨机器，是它的**技术手段**，不是定位本身。真正的定位是：**让"分布式组合"成为默认能力，而不是需要额外搭建的基础设施。**

为什么叫"地基"而不是"框架"？因为框架规定你盖什么楼，地基不规定——但它保证你盖什么楼都不会塌。而且地基是从真实生产流量中长出来的（见下方[项目性质](#项目性质自用开源无目的分享本身)），不是设计出来的。

### 它想解决的两类 AI 时代组合问题

LingoFuse 真正要解决的问题，是 AI 时代正在成形的两类组合问题：

**多应用组合**——一个系统不再是一个巨型应用，而是**多个 Agent / 多个应用 / 多个服务**的组合。写代码的 Agent、查数据的 Agent、做计算的 Agent、调硬件接口的 Agent，用不同语言写成，跑在不同机器上，需要互相调用、互相协作、有状态隔离、有故障隔离。LingoFuse 让它们之间的通讯像同进程函数调用一样简单——不需要为每一种组合写网关、写 IDL、写桩代码。

**多物理硬件组合**——一个系统不再是一台机器，而是**多台机器、多种硬件、多种算力**的组合。GPU 节点做推理，CPU 集群做数据处理，嵌入式设备做采集，工作站做可视化。它们需要被组合成一个统一的计算池，按任务分发、按负载路由、按数据形态传输（二进制帧、视频帧、矩阵、张量）。LingoFuse 的 C4 网格、P2P 负载、序列化族、二进制句柄就是为这个场景设计的。

如果你对 P2P 分布式负载的具体机制感兴趣（三套路由、UID 万能路由、本地短路、服务器本地处理、序列化族与高流量计算），可以读一下 [LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept.md)——它把概念讲清楚了，但不是 API 手册。

### 核心承诺一句话

**任何语言写的函数，任何其他语言都能直接调；任何机器上的应用，任何其他机器上的应用都能直接组合。**

- 不需要写 IDL
- 不需要生成桩代码
- 不需要搭 HTTP 服务
- 同机 IPC 延迟声称 < 1 ms
- 跨机原生支持，内置服务发现、负载均衡、FIFO 顺序保证和断线重连
- 18 种语言的一方绑定，20+ 种语言通过代码生成器覆盖

**传输安全性**：同机 IPC 模式（共享内存）**不加密**——它只在本机进程间工作，数据不离开本机，所以不设加密层，追求的是极限延迟；TCP 通讯模式**全部加密**，跨机的每一字节都经过加密保护，企业数据在跨机传输中是加密的，这是 LingoFuse 对企业场景的基本承诺。换句话说，**IPC 管本机、TCP 管跨机，跨机的每一字节都加密**。

**它不是万能胶。** 采用之前，请务必读完[使用门槛](#使用门槛这是黑科技不是开箱即用)、[测试与验证](#测试与验证)和[项目状态与边界](#项目状态与边界)。

---

## 为什么叫 RPC：LF 的定义来源

LingoFuse 的定位不是凭空来的，它是从 ZNetV2 演进出来的——理解这段演进，才能理解"为什么叫 LingoFuse"。

### ZNetV2：单日 PB 级洗礼的工业级通讯引擎

[ZNetV2](https://github.com/PassByYou888/ZNetV2) 是 PassByYou888 技术栈中面向大规模服务器端数据吞吐的通讯框架。它有**单日 PB 级的真实生产流量洗礼**——C4 服务网格、双隧道、StableIO、HPC 线程池、命令桥、交换空间、句柄池、软同步、零拷贝映射，这些内核机制全部是从 ZNetV2 的真实生产流量中锤炼出来的。

但 ZNetV2 在多语言协作环节**很弱**。它不是为"多语言组合"设计的——它是为"大规模服务器端数据吞吐"设计的。它的接口是 Pascal 原生的，其他语言要接入，得自己写胶水层。

### AI 时代：单一语言已经无法适应

AI 时代改变了一件事：**单一语言已经无法适应时代**。

写代码的 Agent 可能是 TypeScript 写的，查数据的 Agent 可能是 Python 写的，做高性能计算的 Agent 可能是 C++ 写的，做硬件接口的 Agent 可能是 C# 写的，做数据分析的 Agent 可能是 R 或 Julia 写的，做前端展示的 Agent 可能是 Dart 或 Swift 写的。**没有一个单一语言能覆盖全部场景**——每个语言都有自己的生态长板，也都有自己的生态短板。

这时候，需要一个**跨语言协作的地基**——它不能只服务某一种语言，它必须对每一种语言都一视同仁；它不能只服务某一个场景，它必须同时覆盖多应用组合和多物理硬件组合。

### LF 破土而出：用 RPC 统一形容

LingoFuse 就是这个跨语言协作的地基。它的诞生背景是 ZNetV2 那个"工业级通讯引擎"的内核，但它的**结构形式很贴近 RPC**——请求-响应、单向通知、序列化调用、异步回调，这些都是 RPC 的标准抽象。同时，**它又能支持 IPC**——同机共享内存，延迟 < 1ms，这是纯网络 RPC 框架做不到的。

所以，我们用 **RPC 来统一地形容 LingoFuse**：

- 它有 RPC 的调用抽象（Call / Notify / Sequenced / Async）；
- 它有 RPC 的服务发现与负载均衡；
- 它**又能吃下 IPC**——同机走共享内存，跨机走 TCP，同一个 API 面，两种传输形态；
- 它**又能吃下多语言**——18 种语言绑定共享同一套线格式、同一套 Handle 所有权、同一套侧数据语义。

**这就是给 LingoFuse 定义的原因**：它不是纯 RPC 框架，也不是纯 IPC 库，它是"用 RPC 的统一形容，把 IPC 和多语言协作吃进去"的分布式系统地基。ZNetV2 是它的技术根系，RPC 是它的公共抽象，多语言是它的用户面——三者合一，就是 LingoFuse。

---

## 项目性质：自用、开源、无目的、分享本身

> 这一节回答"LingoFuse 是什么"，比"这是什么"更靠前。不读这一节，后面的一切都容易被误读。

### 它是作者自用的框架

LingoFuse 不是为创业公司写的产品，不是为融资写的故事，不是为社区写的教程。它是**老张自己用的框架**——他需要一个能让自己不同语言、不同机器、不同硬件的程序互相说话的底座，市面上没有，就自己写了一个。

"自用"决定了它的很多属性：单人维护、不做业务封装、不做跨平台工具链适配、不做"装好就能跑"、不做社区运营。这些不是缺陷，是"自用框架顺手开源"的自然结果。**它不欠任何人一个产品级的交付。**

### 开源用 MIT，目的就是帮助所有人

MIT 协议的含义是：拿去用，拿去改，拿去卖，都不用谢我。没有附加条款、没有商业授权、没有"开源版 vs 企业版"的双轨制。

为什么用 MIT？因为**开源的目的就是分享本身**。老张不缺这个项目带来的钱，也不指望它带来名声。他把它开源，是因为他知道世界上还有别人需要这个东西——那些被 gRPC 的 IDL 折磨的人，那些被 REST 的延迟折磨的人，那些想把 GPU 节点、CPU 集群、嵌入式设备、工作站组合成一个系统的人，那些在 AI 时代需要多 Agent 协作但不想为每种组合写网关的人。

### Vibe 辅助编程 + 文档，但不是放手 Vibe

LingoFuse 的开发过程中大量使用了 AI 辅助——读源码、梳理文档、生成测试用例、整理代码结构、补样板代码。老张把这套 AI 辅助体系叫"贾维斯"。

**但贾维斯不是司机，是施工队。** 接口设计（C ABI 的 59 个导出符号、18 种语言绑定的 API 形状、Handle 所有权模型、P2P 身份侧数据语义）、架构决策（C4 mesh 的调度逻辑、双隧道体系、StableIO 的重连语义、HPC 线程池的边界、命令桥的搭配矩阵）、文档思路（[Z.LingoFuse.md](Z.LingoFuse.md) 为什么按"线程 → 回调 → Handle → P2P 身份"这个顺序展开、[llms.txt](llms.txt) 为什么保留 Julia 的 shim 机制这些细节）——全部是人类提出的。

**为什么大型架构不能放手给 AI？因为大型架构需要可控。** 可控意味着：每一个边界、每一个接口、每一个失败模式，都必须有人能说得清、测得准、兜得住。AI 生成的东西没有人为它站过夜班、没有人为它背过生产事故。当系统规模超过一个阈值，"看起来对"和"在生产中真的对"之间隔着一整条隐性契约的鸿沟。

**AI 在 LF 生态里的角色是加速器，不是架构师。** 人类能当架构师的前提，是 LF 提供了**可被人类审计的接口规则**。这一点在[使用门槛](#使用门槛这是黑科技不是开箱即用)里的"AI 能做和不能做的事"有更详细的展开。

### LF 是全语言平等的：没有 Pascal 加成

**先说清楚一件事：LingoFuse 没有 Pascal 加成。**

Pascal 是核心引擎的**实现语言**——C4 网格、双隧道、StableIO、HPC 线程池、命令桥，这些内核组件是用 Pascal 写的。但**实现语言不等于特权语言**。LingoFuse 对外暴露的是 **59 个 C ABI 导出符号**，这 59 个符号对 18 种语言绑定是**完全平等**的：

- **C ABI 面平等**：Pascal / C++ / Rust / Go / Java / Python / C# / TypeScript / JavaScript / Swift / Zig / Erlang / Ruby / Fortran / Julia / R / Dart / PHP，18 种绑定访问的是**同一套 C ABI**。没有任何一种语言有"原生特权通道"。
- **线格式平等**：所有绑定共享同一套线格式——UTF-8 + NUL、小端序、紧凑 JSON 无 `\uXXXX` 转义。跨语言互通是**字节级**的，不是"某种语言优先"。
- **Handle 所有权平等**：同步族归调用者、异步族归框架——这条规则对 18 种语言**完全一致**。不会因为"某种语言是底层实现"而改变。
- **侧数据语义平等**：UID / P2PName 是发送方写入的侧数据，接收方从回调的 `input` 上读——这条规则对 18 种语言**完全一致**。
- **测试体系平等**：每种语言都有自己的独立测试套件，都能做标准测试。C++ 不因为是"原生 C ABI"而有特殊测试通道，Python 不因为是"脚本语言"而降级，Pascal 也不因为是"实现语言"而有特权。
- **代码生成器平等**：`code_decl_to_abi` 覆盖 17 种原生 FFI 语言，`code_decl_to_json_abi` 覆盖 20+ 种——生成器不偏袒任何语言，它生成的 Service / Call / Test 代码对每种目标语言都是对等的。

**为什么必须说清楚这一点**：因为在很多"以某种语言实现内核"的项目里，实现语言会自然形成"主场加成"——内核语言优先、其他语言是二等公民。**LingoFuse 不是这样**。Pascal 只是一种可以被任何其他语言替代的实现语言；它写的内核，通过 C ABI 暴露出来，然后被 18 种语言平等地使用。

**团队策略里的"Pascal 后台形态"不是语言地位**：`LingoFuse_Team_Enslavement_Strategy.md` 里提到的"Pascal 后台形态作 API 节点"、"Pascal 退居工具环节"，说的是**团队分工策略**——让 Pascal 团队去做工具链和后台节点，让 Java/C# 团队做综合工程主体。这是**团队角色**，不是**语言地位**。LingoFuse 本身对 Pascal 和 Python 一视同仁：Python 能做的事 Pascal 也能做，Pascal 能做的事 Python 也能做。

**一句话总结**：**LF 是全语言平等的，没有 Pascal 加成。** Pascal 是实现语言，不是特权语言；18 种绑定都是第一方绑定，没有主次；C ABI 是唯一入口，对每种语言都是同一套规则。

### 地球没有竞品，也没有前例

LingoFuse 的体系组合在开源世界里**没有等价物**：零 IDL + 18 语言原生 FFI + 二进制线格式 + Handle 所有权 + P2P 侧数据 + 双隧道 + StableIO + HPC + 命令桥 + C4 mesh + 序列化族——这个组合没有任何一个开源项目同时具备。

gRPC 有 IDL、有桩代码、有多语言，但没有 Handle 所有权模型、没有 P2P 侧数据、没有 C4 mesh、没有双隧道。REST / HTTP POST 有跨机能力，但没有 FIFO、没有服务发现、没有零拷贝。消息队列（Kafka / RabbitMQ / NATS）有分布式能力，但没有原生 FFI、没有零 IDL、没有 Handle 所有权。同进程方案（如 PyO3 / napi-rs）有低延迟，但不跨语言、不跨机器。

**没有前例，意味着两件事**：它能做出别人做不出的架构——没有"标准 RPC 架构"的束缚，老张可以按真实需求设计；同时，**AI + 人类组合也无法低成本复制它**。关于第二点，[LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md) 有完整论证——核心是**隐性契约密度**：专家在内核里埋入防御性设计但不写进文档，AI 基于表面接口生成周边时无意中依赖了这些隐藏行为。当隐性契约密度超过阈值，完整描述系统的成本 ≥ 重新设计一个等价系统的成本。**复刻者能拿到代码，拿不到专家写内核时的"我知道下游会这样用"。**

### 为什么复刻不易：体系庞大 + 专属机制埋点

**LingoFuse 的体系本身庞大、内容繁多，复刻不易**——不是"读一遍源码"就能复制的东西：

- **18 种语言绑定**：每种语言都有自己的 FFI 边界处理、回调线程模型、Handle 所有权实现、清理顺序、平台陷阱。18 种就是 18 套隐性契约，一套一套读，读完已经穷年累月。
- **C4 服务网格**：多节点发现、跨节点路由、双隧道体系、StableIO 重连语义、HPC 线程池调度、命令桥搭配矩阵。
- **内核机制群**：句柄池、软同步、零拷贝映射、序列化族、交换空间、锁内换容器锁外干活、TBigList 迭代器语义、TCritical 回收池、线程池 Pick 策略。
- **知识库体系**：194 条踩坑 ID、17 篇技术短文、18 种语言的部署指南、Z.LingoFuse.md v4.0 源码重建版。

这些内容**不是 AI 靠训练数据就能重构的**——因为训练数据里没有 LingoFuse 这种架构。AI 读完源码，能复刻表面接口；复刻不了"为什么 Julia 强制 `--threads=2`"、"为什么 R 的 `LF_Call` 不可重入"、"为什么异步族 handle 回调返回立即释放"这些隐性契约。

**更重要的是**：**如果采用者在自己私有化的分支里稍微埋下一点专属机制设计**——比如自己业务场景特有的防御性检查、特定的路由粘性策略、自定义的清理顺序、内部约定的状态码语义、埋点追踪用的隐藏字段——**AI 就会无法复刻处理**。因为 AI 只能基于表面接口和公开文档推断，它**看不到你私下埋入的那些"我知道我的下游会这样用"的设计**。

这不是理论推演，是私有化实践里反复验证的事实：**复刻的难度，不取决于代码行数，取决于有多少隐性契约是 AI 看不到的。** 你在自己分支里埋一个"当 P2PName 包含特定前缀时走特殊路由"的机制，AI 读完全部公开源码，也看不出这个机制的意图——它只会把它当成一个"奇怪的条件分支"忽略掉。而你的下游代码，正是依赖这个条件分支才能正确工作。

**私有化的真正价值，不是把 LingoFuse 的代码复制一份**，而是**在 LingoFuse 的隐性契约体系之上，叠加组织自己的隐性契约**——叠加得越多，越不可复刻；叠加得越自然，越能抵御 AI 的"看起来对"的推断。这就是为什么 `LingoFuse_Private_Fork_Playbook.md` 里强调"私有化的目标不是'拿走代码'，而是'建立组织自己的隐性契约体系'"。

### 底层内核：从单日 PB 级流量中洗礼出来

LingoFuse 的核心不是"写了一个 RPC 框架"。它的内核——C4 引擎、句柄池、软同步、线程池、零拷贝、序列化族、双隧道、StableIO、HPC、命令桥、交换空间——是**从单日 PB 级真实流量中锤炼出来的**。

这不是实验室里的玩具。这是在真实生产环境里，被高并发、大流量、长时间运行、各种边界情况反复打磨后长出来的分布式内核。它的设计取舍（稳定性优先于并发性能、池化回收、锁内换容器锁外干活、零拷贝映射、软同步替代内核同步）都是**被真实流量逼出来的**，不是从教科书上抄来的。

### 分支项目会过时，LF 不会

LingoFuse 之上有很多分支项目——pasAgent、pasAgent-v3、cppAgent、csharpAgent，以及即将发布的 tsAgent。这些都是**用 LF 搭的建筑**，是作者追赶前沿技术时用 LF 做的实验和演示。

**建筑会过时，地基不会。** pasAgent-v3 的多模态能力、cppAgent 的 C++ 生态接入、csharpAgent 的 .NET 运行时——这些具体的 Agent 实现会随着 AI 技术演进被更新、被替代、被淘汰。但它们脚下踩的 LF，是作者**多年追赶前沿技术、量身定做的框架体系**——它不追某一个具体的浪头，它追的是"多应用组合 + 多硬件组合"这个长期趋势。

### 星标少、人气低，但它是真正的成长型项目

GitHub 星标数不是衡量一个基础设施项目的正确指标。LingoFuse 的星标不多，人气不高——这符合它的性质：它不追热点、不迎合大众、不做营销。它的读者是架构师和集成工程师，不是"想五分钟跑通一个 demo"的人。

**但请不要被现象蒙蔽。** LingoFuse 是真正的**成长型项目**：它的定位是"分布式系统地基"，这个定位的价值会随着 AI 时代的多应用组合、多物理硬件组合需求爆发而上升。它的内核是从 PB 级流量中洗礼出来的，这个工程根基不会因为星标少而贬值。它的 18 种语言绑定、20+ 种生成器覆盖、完整的测试体系、完整的知识库——这些是**已经建成的能力**，不是 PPT。

**只要世界科技圈有个浪头**——AI Agent 爆发、多语言组合需求爆发、多硬件组合需求爆发、边缘计算爆发——**它就能起飞**。它不需要"现在就很火"，它需要的是"在浪头来的时候，已经准备好了"。

---

## 使用门槛：这是黑科技，不是开箱即用

先说清楚性质：**LingoFuse 是黑科技基础设施，不是业务框架。** 它解决的是大多数团队根本不会去碰的底层问题——跨语言字节级互通、C4 mesh 调度、18 种语言的 FFI 绑定、多线程回调安全、Handle 所有权模型。**这些东西让它能做别人做不到的事，也让它对使用者的要求远高于普通库。**

### 它把最难的问题解决了

- **线格式语言无关**：任何语言的 CrossNode 写出的字节流，任何语言的 CrossCall 都能原样读出来。
- **零 IDL 的强类型调用**：C++ 声明 `int Add(int a, int b)`，C# / Rust / Swift / Java 都能直接 `Add(1, 2)`，不需要 `.proto`、不需要生成桩。
- **真·服务发现 + 负载均衡 + FIFO + 断线重连**：不用 etcd、不用 Nginx、不用自己写重试。
- **18 种语言的绑定**：从 ASM 级 C ABI 到 Dart / Julia / R，每种都跑通了自己的测试体系。
- **多应用 / 多硬件的分布式组合**：后台服务、AI Agent、计算节点、客户端、设备端，都可以在同一套地基上组合、路由、隔离。
- **多语言生态互补**：不是每种语言都做全栈，而是按团队策略协作——详见 [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) 与 [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md)。

### 它把最复杂的负担留给了你

LingoFuse **不做**下面这些事：

- **不做业务层封装**。它给你的是 `LF_Call` / `LF_Notify` / `LF_RegisterCall`，怎么组织你的 App 层、怎么切分服务、怎么做权限，都是你的工程决策。
- **不做线程抽象**。回调在 TCompute 工作线程跑，不在主线程；回调里不能调阻塞 LF 函数，否则自锁死；同步回调要靠主线程 `LF_Sync` 驱动。这些不是"读一遍文档就懂"的事，是必须在你自己的代码里反复调试才能养成肌肉记忆的事。
- **不做跨平台工具链适配**。每种语言的绑定都有各自的编译期陷阱：Java 需要 JDK 22+、Fortran 需要 C++ 与 Fortran 编译器来自同一发行版、Ruby 需要 DevKit、Julia 强制 `--threads=2`、Swift 的 macOS / Linux 路径还在验证中。这些坑你必须自己能处理。
- **不做"装好就能跑"**。核心动态库和生成器工具都有**预构建产物**（见[快速开始](#快速开始)），但如果你需要的平台没有预构建版本，你仍然需要自己编译。[Binary/](Binary/) 只提供 Windows 32/64 位预编译库；Linux / macOS 需要按 [src/CONTRIBUTING.md](src/CONTRIBUTING.md) 自己构建。
- **不做社区支持**。单人维护，Issue 会回，但不保证 SLA，没有 Stack Overflow 问答，没有第三方教程。

### 采用前请自测四个问题

1. **你能否自行编译 LingoFuse 核心动态库？** 预构建产物可以帮你跳过这一步——但仅当你的平台和目标语言组合被预构建覆盖时。如果不在覆盖范围内，你仍然需要自己能编译。
2. **你能否读懂回调线程模型，并在自己的代码中系统性避免死锁？** LingoFuse 把回调放在工作线程执行——这是一切正确性的基础，也是最容易出错的地方。如果团队里没人能讲清楚"为什么回调里不能调 `LF_Call`"，先别用。
3. **你能否在出现问题时会读源码，而不是读注释？** 文档里有 [LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide.md) 的 194 条踩坑 ID、20+ 种语言的生成器报告、[Z.LingoFuse.md](Z.LingoFuse.md) v4.0——但**注释是二手信息**。真正诡异的行为，只有源码能说清楚。
4. **你是否愿意做 App 层 PoC，而不是相信 README 里的任何数字？** [test/](test/) 提供的是机理层竞态稳定性测试，不是你的业务层测试。README 里的延迟、并发、成功率，都基于作者的硬件和场景，不是你的。

**如果上面任何一条的答案是"不能"或"不愿意"，请直接选 gRPC / REST / 同进程方案。** LingoFuse 不会替你解决这些问题——它只提供地基，建筑需要你来设计。

**反过来**：如果上面四条你都能答"能"，而且你确实需要跨语言、跨进程、零 IDL、低延迟的原生 RPC，或者需要把多个应用/多个硬件组合成一个分布式系统，那 LingoFuse 是你能找到的最认真的实现之一。

### AI 能做和不能做的事：慎用 "AI 驱动 LingoFuse"

**先说结论：不要让 AI 从零开始"驱动" LingoFuse 构建你的项目。这条路的工期会比你想象的翻好几倍。**

AI 在 LingoFuse 的生态里能做很多事——读生成器源码、读踩坑记录、通过 MCP 驱动 Tools 生成器、按契约写生成代码的 App 层、写测试断言。这些是 LingoFuse 明确设计给 AI 用的能力。但 AI 做不了一件事：**设计你的架构**。

LingoFuse 本身没有规定你的 App 层怎么切分——服务怎么划分、mesh 拓扑怎么布局、Handle 生命周期由谁负责、回调线程池和你的业务线程池怎么隔离、P2P 组和 UID 路由什么时候用哪个、跨机器部署的防火墙 / 端口 / 证书怎么配。这些是 LingoFuse 有意留给你的工程决策，不是它做不了，是它只能由你的业务上下文决定。

AI 遇到这些问题时，它会——诚实地，按照训练数据里的"标准 RPC 架构"——给你一个看似合理但漏掉关键约束的方案。你可能在 48 小时后才发现它选错了拓扑（选了 P2P 组路由，但你的场景需要 UID 定向），或者漏掉了某条"回调里不能调阻塞 LF"的铁律，导致压测时死锁。**这就是 LingoFuse 的"黑科技"属性带来的独特困境：** 它解决的问题越底层，AI 的"常识"就越容易误导你——因为大多数训练数据里没有 LingoFuse 这种架构。

**正确的做法是**：你先跑通 LingoFuse（参[测试与验证](#测试与验证)里的 PoC 路径）→ 你先设计出第一版架构（哪怕只是个草稿，要能讲清楚"哪个进程是 service、哪个是 call、谁负责什么、路由用哪种寻址"）→ 你先用自己最熟悉的语言手写一个最小可用的跨语言调用，确认线格式、回调线程、Handle 所有权都在你的预期内 → **然后**再让 AI 进来，用 AI 加速 Tools 生成器的使用、用 AI 读踩坑记录、用 AI 补测试、用 AI 生成样板代码。

**这样 AI 是"加速器"，不是"司机"。** 架构对不对由你负责，代码快不快由 AI 负责。这也是 LF 自己的开发方式——老张用"贾维斯"辅助写代码、梳理文档、生成测试，但接口设计、架构决策、文档思路全部是人类提出的。**人类定架构和思路，AI 帮执行和梳理。**

关于"为什么即使 AI 读完源码和文档，复刻一个等价的 LF 仍然工程上不可达"，见 [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md)。

---

## 为什么需要它

跨语言、跨进程调用目前的现实是：

- **gRPC**：要写 IDL、要生成桩代码、要搭网关；跨语言，但对"多应用组合 / 多硬件组合"没有直接支持。
- **REST**：延迟高、无流式、无服务发现。
- **HTTP POST**：天然跨机但无顺序保证、无服务发现。
- **同进程调用**：延迟极低但不跨语言、不跨机器。

### 两类组合问题，现有方案都不直接解决

**多应用组合**——一个 AI 系统里，写代码的 Agent、查数据的 Agent、做计算的 Agent 用不同语言写成，跑在不同机器上。你需要它们互相发现、互相路由、互相隔离。现有方案要么把每个 Agent 都套成一个 HTTP 服务（运维成本高，且无原生 FIFO、无原生背压），要么写一套中心化的消息总线（单点、单语言）。

**多物理硬件组合**——GPU 节点、CPU 集群、嵌入式设备、工作站，需要被组合成一个统一的计算池。现有方案要么靠 K8s + 消息队列（对数据形态不友好：视频帧、矩阵、张量需要二进制通道），要么靠手写 socket（工程成本极高）。

LingoFuse 的设计就是同时面向这两类问题：**C4 网格**解决多节点发现与路由，**P2P 负载 + 序列化族**解决多 worker 组合，**二进制句柄 + 零拷贝**解决大流量数据形态，**18 种语言绑定**解决多语言组合，**HTTP 桥接**解决受限平台（浏览器 / 移动 / 嵌入式）接入。

### 稳定性优先于并发性能

LingoFuse 把应用的稳定性放在第一位，并发性能往后挪移。这不是临时取舍，而是项目未来所有版本都会坚持的趋势。一个在高并发下会偶发崩溃、丢消息或死锁的通讯层，延迟再低也没有意义。因此本项目**不在主 README 中做并发性能的横向对比**，实测数据以 [test/](test/) 目录为准。

---

## 快速开始

### 路径 A：直接使用预构建产物（Windows，推荐先试）

如果你在 Windows 上，只是想先跑通、再决定是否深入，**不需要从源码编译任何东西**。到 [release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build) 下载：

- **生成器工具**（Windows 平台预构建）：`code_decl_to_abi` / `code_decl_to_json_abi` / `code_decl_to_mcp` 的可执行文件；
- **动态库**（Windows 平台预构建）：`LingoFuse64.dll` / `LingoFuse32.dll` / `z_ipc_*.dll` / `mimalloc*.dll`。

把动态库放到 `PATH` 或可执行文件同目录，生成器工具直接运行即可。**这是最短的上手路径。** 预构建产物覆盖不到的平台 / 语言组合（Linux / macOS 动态库、部分语言的生成器工具），仍然需要按路径 B 从源码构建。

[Binary/readme.md](Binary/readme.md) 里有所有 DLL 的作用清单和 PATH 配置说明；如果你在 Windows 上遇到"找不到模块"的错误，先看那份文档里的 VC++ 可再分发包一节。

### 路径 B：从源码构建 + 验证

**第一步：克隆仓库**

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
# 然后将 LingoFuse/Binary 目录加入系统 PATH
```

**第二步：阅读测试指南，运行预编译可执行文件**

进入 [test/](test/) 目录，里面有三份指南——[LingoFuse_Functional_Test_Guide.md](test/LingoFuse_Functional_Test_Guide.md) 讲功能测试、[LingoFuse_Stress_Test_Guide.md](test/LingoFuse_Stress_Test_Guide.md) 讲压力测试、[LingoFuse_Concurrent_Notify_Demo.md](test/LingoFuse_Concurrent_Notify_Demo.md) 讲并发通知。解压 [test.zip](test/test.zip)，运行预编译可执行文件。**得到的是你自己硬件上的真实数据。**

**第三步：进入你要用的语言目录，按该语言 README 自行运行测试**

LingoFuse 的 18 种语言绑定**每种都有独立的测试体系**，都能做标准测试：

- C++ 在 [cpp/test/](cpp/test/)（功能）+ [cpp/Stress/](cpp/Stress/)（压力）+ [cpp/Conc/](cpp/Conc/)（并发）
- Python 在 [Py/lingofuse/](Py/lingofuse/)（pytest）
- C# 在 [csharp/test/](csharp/test/)（xUnit）
- Rust 在 [rust/tests/](rust/tests/)（cargo test）
- Go 在 [go/test/](go/test/)（go test）
- Java 在 [java/src/test/](java/src/test/)（JUnit 5）
- TypeScript / JavaScript 在 [ts/test/](ts/test/) 和 [js/test/](js/test/)（Node 测试）
- Swift 在 [swift/Tests/](swift/Tests/)（XCTest）
- Zig 在 [zig/tests/](zig/tests/) 和 [zig/examples/](zig/examples/)（zig build test + 冒烟程序）
- Erlang 在 [erlang/test/](erlang/test/)（EUnit）
- Ruby 在 [ruby/test/](ruby/test/)（minitest）
- Fortran 在 [fortran/c_ext/](fortran/c_ext/)（自研断言）
- Julia 在 [julia/test/](julia/test/)（自研断言）
- R 在 [r/c_ext/tests/](r/c_ext/tests/)（自研断言 + 五步链）
- Dart 在 [dart/test/](dart/test/)（Dart test）
- Pascal 在 [pascal/](pascal/)（自研测试套件）

选择你使用的语言，进入对应目录，按该语言 README 的说明运行测试即可。**没有"某一种语言的测试优先"的概念——所有语言都可以做标准测试。**

**第四步：用你自己的业务场景构建 PoC**

LingoFuse 提供的是竞态稳定性测试（机理层），不是你的 App 层测试。你需要自己模拟自己的 App 层，验证 LF 在自身业务场景下的表现。

---

## 语言支持

### 第一方绑定（仓库内）

每个语言目录都有独立的 README、独立的测试体系、独立的示例。选你最熟悉的一种语言，点进去继续：

| 语言 | 目录 | 状态 | 一句话说明 |
|------|-----|------|-------------|
| C# / .NET | [csharp/](csharp/) | 🟢 生产就绪 | v5.1，116 项测试，P/Invoke + RAII + 统一 JSON I/O + `CallbackDispatcher` + 回调风格异步 |
| C++ | [cpp/](cpp/) | 🟢 生产就绪 | 原生 C ABI 零开销，异步模型 + 侧数据读取 |
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

**跨语言的全局视角**：如果你想知道"为什么某种语言要这么做"——比如为什么 Julia 强制 `--threads=2`、为什么 Ruby 需要自写 C 扩展、为什么 R 不能用 CRAN 发布——[LingoFuse_MultiLanguage_Complete_Guide.md](LingoFuse_MultiLanguage_Complete_Guide.md) 有 194 条踩坑 ID 和 18 种绑定逐一展开；[LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md](LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md) 有每语言工具链、版本硬要求、部署检查清单。

> **再次强调**：上表 18 种语言都是**第一方绑定**，地位对等，没有"主场语言"或"二等语言"。Pascal 是内核实现语言，但它在绑定层和其他语言完全一样——`LF_CreateData` / `LF_Call` / `LF_Get_P2P_UID`，走的是同一套 C ABI。详见[项目性质](#项目性质自用开源无目的分享本身)里的"LF 是全语言平等的：没有 Pascal 加成"。

> 这 18 种语言不是孤立罗列的清单，而是按生态互补原则协作的体系。完整的团队协作策略见下方[多语言团队协作策略](#多语言团队协作策略)。

---

## 多语言团队协作策略

LingoFuse 的 18 种语言绑定不是"每种语言都做全栈"的清单，而是**按生态互补原则协作的体系**。不同语言团队接入时，支持策略和"奴役"策略是两套互补的文档。

### [LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) —— 团队接入支持策略

- **分群**：强实现语言（C++ / Rust / Zig）、后台强项语言（Go / Erlang）、综合工程化语言（Java / C#）、专业 API 节点（Julia / R / Fortran / Python / Ruby）、前端 UI 供给方（Dart / Delphi / Pascal UI / TS/JS / Swift）、工具链与服务方（Pascal 后台形态 / LingoFuse-Tools）。
- **补齐短板**：强实现语言缺高级 UI → LF 提供 UI 宿主；后台语言缺前端 → LF 提供 Web/CS 前端；封闭生态缺前沿 API → LF 提供现代 API 封装；工程化语言做主体 → 工具链提供支撑。
- **交付物清单**：限制清单、服务/调用模板、UI 或 API 宿主模板、共性契约培训、机理 PoC 路径、二进制/JSON 双通道示例、工具链使用指南。
- **落地路线**：先分群再派活，A 类给高级 UI 激励，B 类给前端支持，C 类给主体工程地位，D 类明确为 API 供给方，E 类在 UI 层面尊重其能力，F 类提供工具链与机理 PoC 路径。

### [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md) —— 生态互补与价值最大化策略

- **内部"奴役"不是贬义**，而是让每种语言团队在其最擅长的领域心甘情愿地贡献，同时用统一架构补齐其短板，实现整体系统价值最大化。
- **核心操作原则**：解决目标语言的短板，用统一化全栈语言高度进行全面高端开发。
- **分类"奴役"策略**：A 类强实现语言做局部核心 + 高级 UI 激励；B 类后台语言做后台核心 + 前端支持；C 类工程化语言做主体工程 + 工具链支撑；D 类专业 API 节点做统计/数值/算法服务；E 类前端 UI 语言做 UI 供给方；F 类脚本/胶水语言做 API 节点。
- **逐语言对照表**：每种语言的"让他们做什么 / 我们补什么 / UI 形态"一目了然。

**注意**：团队策略里的"Pascal 后台形态作 API 节点"、"Pascal 退居工具环节"，是**团队角色分工**，不是**语言地位**。LingoFuse 本身对 18 种语言完全平等，详见[项目性质](#项目性质自用开源无目的分享本身)里的"LF 是全语言平等的：没有 Pascal 加成"。

---

## 代码生成器体系 · LingoFuse-Tools

LingoFuse 的第一方绑定是**手写**的。当你要把同一组 API 铺到十几种语言时，手写绑定会变成重复劳动——而且每种语言的线格式只要差一个字节，跨语言互调就会静默失败。

[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) 解决的就是这个问题：**从一份 API 声明（Pascal 单元或 C 头文件）出发，自动产出多语言的 service / call 代码、测试程序和构建脚本**。

Tools 不是单一生成器，而是**三条并行的工具线**，共享同一套解析器、同一套 LV1 模型和同一套类型系统：

- **`code_decl_to_abi`** —— LingoFuse 二进制 ABI。适用于两端都是 LingoFuse 原生、高并发、数值 / 二进制重载荷的场景。
- **`code_decl_to_json_abi`** —— HTTP + JSON（经 `bridge.py`）。适用于一端是浏览器、外部 HTTP 客户端，或没有 LingoFuse 绑定的语言。
- **`code_decl_to_mcp`** —— MCP。把函数暴露为 AI Agent 可调用的工具。

> 同一份声明，三条路径。改一次声明，ABI / JSON / MCP 三套产物一起刷新。不会出现"ABI 改了这个函数但 MCP 还停在旧签名"的情况。

### 生成器覆盖的目标语言

Tools 当前覆盖 **20+ 种目标语言**，每种都含 service 侧、call 侧、测试程序和一套 `setup_*_tests.ps1` 环境脚本。生成器的后端为**无限扩展**设计——加一种语言是机械的 8 步流程，不是架构变更。主要目标语言的 Service / Call 支持情况如下（完整矩阵和平台支持见 [LingoFuse-Tools 仓库](https://github.com/PassByYou888/LingoFuse-Tools)）：

- **Service + Call 都支持**：C#、C++、Dart、Erlang、Fortran、Go、Java、Julia、Node.js、Pascal、Python、R、Ruby、Rust、Swift、TypeScript、Zig
- **仅 Call 支持**（不能做 Service，因为无法加载 LingoFuse 原生库）：JavaScript（浏览器）、PHP、Delphi

**关键边界**：Service 侧必须运行在桌面 / 服务器（Windows / Linux / macOS）。**iOS / Android / WASM / 嵌入式无法运行 Service**——LingoFuse 原生库不支持这些平台。需要移动端提供接口时，把 Service 部署到服务器，移动端作为 Call 通过桥接访问。

**生成器对目标语言平等**：`code_decl_to_abi` 覆盖的 17 种原生 FFI 语言，生成产物的地位完全对等——C++ 的 Service 和 Python 的 Service 走同一套线协议，Rust 的 Call 和 Swift 的 Call 读同一套字节。生成器不偏袒任何语言，也不因为"某种语言是内核实现语言"而有特殊生成路径。

### 代码生成器不是"黑盒"

Tools 仓库同时承载了三类可读资产：生成器源码（每种语言的 service / call / test / setup 生成器都是独立的实现单元）、输入契约（哪些声明会被提取、哪些会被静默丢弃，写得比大多数 IDL 文档都细）、各语言踩坑记录（记录了"我以为"被实测推翻的地方——线格式不对齐、回调线程挂死、`int64` 在 JS 丢精度、`bridge.py` 预检缓存延迟导致 `-3` 错误等）。

AI 可以直接读这些生成器源码和踩坑记录来接管工具链的"使用"——但接管不了你的"架构"。详见[使用门槛](#使用门槛这是黑科技不是开箱即用)里的"AI 能做和不能做的事"。

### 与第一方绑定的关系

第一方绑定是手写的，18 种，每种都有独立测试体系；Tools 生成的绑定是从 Pascal / C 声明生成的，20+ 种，每种都有测试程序和 setup 脚本。**两者不冲突**——Tools 生成的绑定与第一方绑定共享同一套线格式契约；生成器的一个核心设计约束就是"与 C++ 逐字节对齐"。如果你的项目只需要一种语言，直接用第一方绑定；如果你要把同一组 API 铺到多种语言，用 Tools。

👉 **[进入 LingoFuse-Tools 仓库，查看生成器源码、输入契约和踩坑记录](https://github.com/PassByYou888/LingoFuse-Tools)**

---

## 技术短文 · 内核与应用

十七篇短文，每篇讲一个机制或一个应用决策。不重复完整文档里的细节——只讲清楚"为什么这样设计"和"踩坑在哪"。每篇都有一张精炼流程图和一张契约表。

**LF 内核：机制是怎么实现的**

- [LF_Handle_Ownership.md](doc/LF_Handle_Ownership.md) — 同步族句柄归你，异步族句柄归框架，混用必炸
- [LF_Simulated_Main_Thread.md](doc/LF_Simulated_Main_Thread.md) — LF 造了一个后台线程驱动 C4，但它**故意不**驱动 `LF_Sync`
- [LF_WaitOnResult.md](doc/LF_WaitOnResult.md) — 一个 IO 同时只能有一个 Call 在飞，Notify 不受影响
- [LF_Sequenced_FIFO.md](doc/LF_Sequenced_FIFO.md) — FIFO 靠"每个 `(App, API)` 一个线程"实现，粒度很细，混着调会乱
- [LF_ZeroCopy_Decode.md](doc/LF_ZeroCopy_Decode.md) — 解码一次 memcpy 都不做，靠 `Mapping` 零拷贝
- [LF_SwapUnderLock.md](doc/LF_SwapUnderLock.md) — LF 从不在锁里遍历，总是锁内换容器、锁外干活
- [LF_TBigList_Iterator.md](doc/LF_TBigList_Iterator.md) — `Next` 是先移动再判断，`while Next` 会漏首节点
- [LF_ThreadPool_Pick.md](doc/LF_ThreadPool_Pick.md) — 任务来了先让空闲 worker 消化，实在不够才扩容
- [LF_TCritical_Reuse.md](doc/LF_TCritical_Reuse.md) — 创建十万个临界区，句柄数几乎不涨，因为有回收池
- [LF_P2P_Identity.md](doc/LF_P2P_Identity.md) — UID 和 P2PName 是**发送方送来的侧数据**，不是查出来的

**LF 应用：用这些机制做决策**

- [LF_Cmd_Model_Choice.md](doc/LF_Cmd_Model_Choice.md) — 先问"要不要响应"，再问"吞吐够不够"，模型就定了
- [LF_Route_Choice.md](doc/LF_Route_Choice.md) — App 名找服务、UID 找客户端、P2PName 找一组，选错不报错会跑偏
- [LF_Startup_Order.md](doc/LF_Startup_Order.md) — 启动顺序不能乱，乱了是静默失败（连接建了但调不通）
- [LF_Error_In_Callback.md](doc/LF_Error_In_Callback.md) — 回调抛异常等于没抛，错误要在协议层传
- [LF_Reconnect_Strategy.md](doc/LF_Reconnect_Strategy.md) — LF 只给断线信号，重连行为是应用自己的事
- [LF_Concurrent_Send.md](doc/LF_Concurrent_Send.md) — `Send*` 是线程安全的，句柄不是——谁创建谁使用谁释放
- [LF_Debug_Mode.md](doc/LF_Debug_Mode.md) — 三个调试开关（Quiet / ConsoleOutput / debug）各管一摊，得分别设置

**怎么读**：如果只是"想用起来"，先读**应用**那七篇——它们直接对应架构决策；如果想"想知道底下发生了什么"，读**内核**那十篇——它们解释了应用层那些"看起来反直觉的约束"从哪来。

**更完整的机制知识库**：[Z.LingoFuse.md](Z.LingoFuse.md) 是 v4.0 源码重建版，覆盖线程全景、回调执行上下文、Handle 所有权模型、P2P 身份侧数据语义、难缠语言集成指南（Julia / Erlang / R）、反例集、诚实的不确定清单——面向深度集成者和架构师。如果你要搞懂"为什么异步族的 handle 在回调返回后立即释放"、"为什么 Julia 强制 `--threads=2`"、"为什么 R 的 `LF_Call` 不可重入"这些看起来反直觉的约束，这份文档是答案。

---

## 智能体运行时

LingoFuse 是**通讯地基**。地基本身不做应用，但地基之上的建筑可以有很多种。

基于 LingoFuse 构建的智能体运行时：

- [LingoFuse-pasAgent](https://github.com/PassByYou888/LingoFuse-pasAgent)（Pascal）——纯文本智能体，129+ LLM 后端兼容
- [LingoFuse-pasAgent-v3](https://github.com/PassByYou888/LingoFuse-pasAgent-v3)（Pascal）——多模态智能体，250+ 后端，双语言代码生成
- [LingoFuse-cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent)（C++）——C++ 生态智能体接入
- [LingoFuse-csharpAgent](https://github.com/PassByYou888/LingoFuse-csharpAgent)（C# / .NET）——.NET 智能体运行时 + LLM 客户端 SDK
- LingoFuse-tsAgent（TypeScript）——**即将发布**，当前 TS/JS 绑定是纯通讯层，不含 Agent 运行时。如果需要在 TS/JS 中构建 Agent，请使用 Mastra、Vercel AI SDK 等成熟框架，再通过 LingoFuse 的 TS 绑定调用其他语言的函数。

关于分支项目会过时：上面的 Agent 运行时是**用 LF 搭的建筑**，是作者追赶前沿技术时用 LF 做的实验和演示。它们会随着 AI 技术演进被更新、被替代、被淘汰——这很正常。**建筑会过时，地基不会。** LF 本身不追某一个具体的浪头，它追的是"多应用组合 + 多硬件组合"这个长期趋势。详见[项目性质](#项目性质自用开源无目的分享本身)里的"分支项目会过时，LF 不会"。

---

## 相关项目

- [zIPC](https://github.com/PassByYou888/zIPC) —— LingoFuse 底层的同机 IPC 引擎。只需要同机 IPC 不需要完整 RPC 网格时，可直接使用。
- [ZNetV2](https://github.com/PassByYou888/ZNetV2) —— LingoFuse 的**技术根系**。它有单日 PB 级真实流量的洗礼，是多语言协作能力之前的工业级通讯引擎；LingoFuse 从它演化而来，用 RPC 的统一抽象把 IPC 和多语言协作吃进去（详见[为什么叫 RPC](#为什么叫-rpclf-的定义来源)）。
- [LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) —— 代码生成器体系，从 API 声明自动产出多语言绑定。包含三条工具线：`code_decl_to_abi`（二进制 ABI）、`code_decl_to_json_abi`（HTTP/JSON）、`code_decl_to_mcp`（MCP 工具提供者）。

---

## 测试与验证

**以 [test/](test/) 为准。**

对 README 中的任何描述拿不准——延迟、顺序、稳定性、并发下的行为——不要去猜，去 [test/](test/) 目录找实物印证。

test/ 提供了 PoC（Proof of Concept）概念验证的一部分工作。在产品中使用 LingoFuse 体系，请注意：作者提供了竞态稳定性测试（最重要的机理层测试），但不是用户的 App 层测试；用户需要掌握构建编译 LF 的技能（LingoFuse 由老张开发，如果长期不维护，用户需要自己动手编译，跟上最新的代际更新）。

**每个语言都有各自的测试体系，用户可自行运行。所有语言都可以做标准测试。** 18 种语言绑定各自带独立的测试套件——C++ 的功能 / 压力 / 并发测试、Python 的 pytest、C# 的 xUnit、Rust 的 cargo test、Go 的 go test、Java 的 JUnit、TypeScript / JavaScript 的 Node 测试、Swift 的 XCTest、Zig 的 zig build test、Erlang 的 EUnit、Ruby 的 minitest、Fortran 的自研断言、Julia 的自研断言、R 的自研断言 + 双进程 demo、Dart 的 Dart test、Pascal 的自研测试套件。**没有"某一种语言的测试优先"的概念**——选择你使用的语言，进入对应目录，按该语言 README 的说明运行测试即可。

### 把测试能力交到使用者手里

LingoFuse 是 18 种语言 × Windows / Linux / macOS × IPC / TCP / 跨机部署形态的组合。与其把这些组合塞进某个托管环境，不如**把测试能力直接交到使用者手里**：test/ 提供完整的测试指南（Markdown）和预编译的可执行文件（[test.zip](test/test.zip)）。你在自己的机器上解压、运行、观察，得到的是**你自己硬件上的真实数据**。

### 测试指南与可执行文件

- [LingoFuse_Functional_Test_Guide.md](test/LingoFuse_Functional_Test_Guide.md) —— 功能测试：82 项，覆盖 C++ RAII 层与序列化层。可执行文件：`test_lingofuse` / `test_lingofuse_json`。
- [LingoFuse_Stress_Test_Guide.md](test/LingoFuse_Stress_Test_Guide.md) —— 压力测试：Call / Notify / 混合模式，输出吞吐、延迟、稳定性。可执行文件：`StressService` / `StressClient` / `StressMonitor`。
- [LingoFuse_Concurrent_Notify_Demo.md](test/LingoFuse_Concurrent_Notify_Demo.md) —— 并发 Notify：20 批 × 10000 条消息，零丢失，含完成屏障模式。可执行文件：`ConcService` / `ConcClient`。

### 各语言测试规模速查

| 语言 | 测试框架 | 测试数 | 平台验证 |
|------|----------|:------:|----------|
| Ruby | minitest | 331 | Windows x64；Linux / macOS 待测 |
| Fortran | 自研断言 | 474 | Windows x64；Linux / macOS 待测 |
| Julia | 自研断言 | 431 + 4 场景 | Windows x64；Linux / macOS 待测 |
| Swift | XCTest | 261 | Windows；macOS / Linux 待测 |
| TypeScript | Node 测试 | 223 | Windows / Linux / macOS |
| JavaScript | Node 测试 | 223 | Windows / Linux / macOS |
| R | 自研断言 + 双进程 demo | 211 + 五步链 | Windows x64（R 4.6.1 + Rtools45） |
| Rust | cargo test | 174 | Windows / Linux / macOS |
| Python | pytest | 155 | Windows / Linux / macOS |
| Java | JUnit 5 | 145 | Windows / Linux |
| Zig | Zig test + 冒烟程序 | 140+ | Windows x64；Linux / macOS / 32 位待测 |
| C# | xUnit | 116 | Windows |
| C++ | 自研测试 | 82 + 压测 + 并发 | Windows / Linux |
| Erlang | EUnit | 四个套件 | Windows；Linux / macOS 待测 |
| Go | go test | 18 | Windows / Linux / macOS |
| Dart | Dart test | 完整套件 | Windows / Linux / macOS |
| Pascal | 自研 | 完整开发套件 | Windows / Linux |

口径说明：上表的"测试数"为各语言测试项 / 套件数；各语言 README 中的"断言数"（如 Fortran 的 474 断言）可能高于此表的测试项数。详细数字见各语言目录。

---

## 跨语言互调（Cross Demo）

LingoFuse 的核心理念是**"任何语言写的函数，任何其他语言都能直接调"**。为了验证这个承诺，**每种语言的绑定都自带一套名为 "Cross" 的三个程序**：`CrossService`（协调器 / 信标）创建 IPC 端点 `ipc:cross`；`CrossNode`（工作节点）注册 `demo` 应用的 `add` / `inv_seri` 两个 API；`CrossCall`（负载测试客户端）以 32 线程 × 10 秒压测 `demo` 应用。

共享线格式契约：`add (int32 a, int32 b) -> int32`；`inv_seri (uint8, uint16, uint32, uint64, string(NUL), float) -> reversed types`。String = UTF-8 + NUL；整数 = 小端序；浮点 = IEEE 754 小端序。**任何语言的 `CrossCall` 能正确读取另一语言 `CrossNode` 写出的字节，就证明这两个语言 100% 互通。**

Cross Demo 位置：Pascal 在 [pascal/cross_demo/](pascal/cross_demo/)、C++ 在 [cpp/CrossDemo/](cpp/CrossDemo/)、C# 在 [csharp/CrossService/](csharp/CrossService/) / [csharp/CrossNode/](csharp/CrossNode/) / [csharp/CrossCall/](csharp/CrossCall/)、Swift 在 [swift/Sources/CrossService/](swift/Sources/CrossService/) / [swift/Sources/CrossNode/](swift/Sources/CrossNode/) / [swift/Sources/CrossCall/](swift/Sources/CrossCall/)、Zig 在 [zig/examples/](zig/examples/)（[cross_service.zig](zig/examples/cross_service.zig) / [cross_node.zig](zig/examples/cross_node.zig) / [cross_call.zig](zig/examples/cross_call.zig)）、Erlang 在 [erlang/cross/](erlang/cross/)、Ruby 在 [ruby/cross/](ruby/cross/)、Fortran 在 [fortran/cross_demo/](fortran/cross_demo/)、Julia 在 [julia/example/](julia/example/)（[CrossService.jl](julia/example/CrossService.jl) / [CrossNode.jl](julia/example/CrossNode.jl) / [CrossCall.jl](julia/example/CrossCall.jl)）、R 在 [r/c_ext/tests/cross_node.R](r/c_ext/tests/cross_node.R)（配 [r/c_ext/tests/cross_client.cpp](r/c_ext/tests/cross_client.cpp)）、Rust 在 [rust/examples/](rust/examples/)、Go 在 [go/cross/](go/cross/)（[README](go/cross/README.md)）、TypeScript 在 [ts/cross/](ts/cross/)、JavaScript 在 [js/cross/](js/cross/)、Python 在 [Py/cross/](Py/cross/)（[Cross_Demo_Guide_zh.md](Py/cross/Cross_Demo_Guide_zh.md)）、Java 在 [java/src/main/java/lingofuse/demo/cross/](java/src/main/java/lingofuse/demo/cross/)、Dart 在 [dart/bin/](dart/bin/)（探针含 Cross 场景）。

已验证的互调方向：Swift ↔ C++、Zig ↔ C++ / C# / Rust / Go / Python / JavaScript、Erlang ↔ C++ / C# / Python / JavaScript、Ruby ↔ C++ / C# / Python / JavaScript、Fortran ↔ C++、Julia ↔ C++ / C# / Pascal / Python / JavaScript、R ↔ C++、Pascal ↔ C++、C# ↔ C++、Rust ↔ C++——全部字节级兼容或已验证。

---

## 依赖库

### 预构建动态库（Windows，推荐）

到 [release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build) 下载 Windows 平台预构建动态库：Windows 64 位需要 `LingoFuse64.dll` + `z_ipc_64.dll` + `mimalloc64.dll`；Windows 32 位需要 `LingoFuse32.dll` + `z_ipc_32.dll` + `mimalloc32.dll`。

**Linux / macOS 动态库**需要按 [src/CONTRIBUTING.md](src/CONTRIBUTING.md) 自己编译。[Binary/](Binary/) 目录中的预编译库与 `release pre_build` 的 Windows 产物一致；如果你已经从 `pre_build` 下载，不需要再从 [Binary/](Binary/) 复制。

### 仓库内 Binary/ 目录

[Binary/](Binary/) 目录提供 Windows 32/64 位预编译库（与 pre_build 同源），Linux 平台是 `liblingofuse.so` + `libz_ipc.so` + `libmimalloc.so`（可选），macOS 平台是 `liblingofuse.dylib` + `libz_ipc.dylib` + `libmimalloc.dylib`（可选）。

**部署方式**：将 [Binary/](Binary/) 目录加入系统 `PATH`，或把动态库复制到可执行文件同目录。

Windows 下需安装 **VC++ 2015-2022 可再发行程序包**（[最新受支持的 Visual C++ 可再发行程序包](https://learn.microsoft.com/zh-cn/cpp/windows/latest-supported-vc-redist?view=msvc-170)、[vc_redist.x64.exe](https://aka.ms/vs/17/release/vc_redist.x64.exe)、[vc_redist.x86.exe](https://aka.ms/vs/17/release/vc_redist.x86.exe)）。详细的运行时依赖说明见 [Binary/readme.md](Binary/readme.md)。

---

## 构建核心动态库

如果你需要的平台 / 架构没有被 `release pre_build` 或 [Binary/](Binary/) 覆盖（例如 Linux / macOS 动态库、特定架构的生成器工具），你需要从源码构建。

[src/](src/) 是 LingoFuse 核心动态库（`LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib`）的唯一构建入口。需要准备 FPC / Lazarus 工具链，然后一键构建。

构建文档入口：[src/CONTRIBUTING.md](src/CONTRIBUTING.md)（构建环境搭建与工作流总览——第一次编译的入口）、[src/CONTRIBUTING_lazbuild.md](src/CONTRIBUTING_lazbuild.md)（lazbuild CLI 一键构建；含 LoongArch64 手动构建步骤）、[src/FPC_3.3.1_Package_Info.md](src/FPC_3.3.1_Package_Info.md)（FPC 3.3.1 环境包信息）、[src/Lazarus_Change_FPC.md](src/Lazarus_Change_FPC.md)（在 Lazarus 中切换 FPC 版本）。

一键构建：

```bash
cd src
lazbuild LingoFuse.lpi
```

**注意**：FPC 工具链有版本锁定——所有构建机必须使用同一份 FPC 3.3.1 构建源，否则会出现 `PPU version mismatch`。详见 [src/CONTRIBUTING.md](src/CONTRIBUTING.md)。

---

## 项目状态与边界

这个表格列的是**已经建成的能力**，不是"计划中的能力"。LF 的星标不多，但它的 18 种语言绑定、20+ 种生成器覆盖、完整的测试体系、完整的知识库——都是**已经跑通的实物**。不要用星标数衡量一个基础设施项目，详见[项目性质](#项目性质自用开源无目的分享本身)里的"星标少、人气低，但它是真正的成长型项目"。

- **核心通讯层**：✅ 稳定（C4 引擎、二进制帧、句柄、软同步、线程池全部就绪）
- **十八语言第一方绑定**：✅ 生产就绪（C# / C++ / Dart / Erlang / Fortran / Go / Java / JavaScript / Julia / Pascal / Python / R / Ruby / Rust / Swift / TypeScript / Zig / PHP，PHP 为调用者）
- **多语言团队协作策略**：✅ 已完善（[LingoFuse_Team_Support_Strategy.md](LingoFuse_Team_Support_Strategy.md) + [LingoFuse_Team_Enslavement_Strategy.md](LingoFuse_Team_Enslavement_Strategy.md)）
- **HTTP 桥接**：✅ 可用（`bridge.py` 网关，覆盖 Node.js / PHP / 浏览器）
- **代码生成器体系**：✅ 已完结（[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools)：三条工具线 ABI / JSON / MCP，20+ 种目标语言）
- **AI 知识库体系**：✅ 已完善（覆盖所有接口，可辅助 AI 接管接口层和样板层——接管不了架构层，详见[使用门槛](#使用门槛这是黑科技不是开箱即用)）
- **内部机制知识库**：✅ 已完善（[Z.LingoFuse.md](Z.LingoFuse.md) v4.0，面向难缠语言，含 Handle 所有权 + P2P 身份侧数据）
- **P2P 分布式概念**：✅ 已完善（[LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept.md)）
- **架构不可复刻性**：✅ 已完善（[LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md) —— 隐性契约密度、AI 接管边界、专属机制埋点）
- **LLM 入口**：✅ 已完善（[llms.txt](llms.txt)）
- **技术短文（内核 + 应用）**：✅ 已完善（17 篇短文）
- **测试体系**：✅ 18 种语言各有独立测试套件，用户可自行运行；**所有语言都能做标准测试**
- **跨平台支持**：✅ **多平台已全部测试通过**（Windows / Linux / macOS 核心能力已验证）；⚠️ **跨平台的多语言编程支持暂缺**——部分语言绑定在非 Windows 平台的完善度不足，跨平台的多语言混编场景需要用户自行验证
- **传输安全**：✅ IPC 模式（共享内存）不加密（只在本机进程间工作）；TCP 模式全部加密（跨机每一字节都加密）
- **预构建产物**：✅ Windows 可用（[release pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build)：生成器工具 + 动态库；Linux / macOS 需自行编译）
- **tsAgent**：🚧 即将发布（TypeScript / JavaScript 智能体运行时）

---

## 许可证

**MIT** —— 拿去用，拿去改，拿去卖，都不用来谢我。

**这不是一句客套话。** LingoFuse 从诞生就不是为了赚钱，而是为了分享本身。MIT 是这个态度的法律表达——没有附加条款、没有商业授权、没有"开源版 vs 企业版"的双轨制。详见[项目性质](#项目性质自用开源无目的分享本身)。

---

## 关于作者

**老张（QQ: 600585）**

看不惯跨语言调用得写一箩筐胶水代码，干脆撸了 LingoFuse。现在又看不惯每种语言都得手写绑定，干脆把代码生成器也撸完了。再把知识库喂给 AI，让 AI 自己把接口全部接管。

**让所有编程语言平等对话** —— 不是口号，是正在发生的事。

### 我是人类，这些是我亲手敲出来的

LingoFuse 是一个**真实人类作者**手工构建的项目。AI 在这个过程中承担的是**辅助角色**——帮助梳理文档、生成测试用例、整理代码结构。但项目的**灵魂**——架构决策、跨语言字节级互通的设计、C4 mesh 的调度逻辑、十几种语言绑定的接入方式——全部来自一个真实人类在深夜的反复调试和思考。

**接口和架构是老张提的，文档思路也是老张提的。** "贾维斯"（老张的 AI 辅助体系）负责执行、梳理、补测试、生成样板——但贾维斯不是司机，是施工队。LF 的知识库之所以能写得这么细，是因为老张知道集成者会在哪里卡住——这是他从十几种语言绑定的真实踩坑中总结出来的，不是 AI 从训练数据里推断出来的。

你可以查看 **[《LingoFuse · 十四语言实测手记》](https://zpascal.net/imhuman.html)**，那里记录了完整的操作过程：

> 屏幕那些暗色的窗口，是我连续两个晚上熬出来的。没有剪辑，没有脚本合成，没有摆拍。有些命令我敲错三遍才跑通，有些环境装到凌晨才发现是版本问题。报错就是报错，警告就是警告，通过就是通过。

手记中记录的都是真实细节：在 VS 2022 中逐行翻阅 71 KB 的 `NativeMethods.cs`、C++ 绑定构建后 14 个项目 0 警告的输出、压测面板上累计 46,515 次调用和 100.00% 成功率、Dart 环境装了快两个小时但测试 8 秒跑完、有些环境装到凌晨才发现是版本问题。

**AI 是工具，不是作者。** 这个项目从第一行核心代码到第十八个语言绑定，背后是一个真实人类的判断、试错和坚持。

### 为什么开源

因为**分享本身**。老张不缺这个项目带来的钱，也不指望它带来名声。他把它开源，是因为他知道世界上还有别人需要这个东西——那些被 gRPC 的 IDL 折磨的人，那些被 REST 的延迟折磨的人，那些想把 GPU 节点、CPU 集群、嵌入式设备、工作站组合成一个系统的人，那些在 AI 时代需要多 Agent 协作但不想为每种组合写网关的人。

**LingoFuse 从开发出来就不是定位来赚钱的，而是为了分享本身。** 所以它用 MIT，所以它不做社区运营，所以它不追热点——它只是把地基放在那里，谁需要谁拿去用。

### 星标少，但它是成长型项目

GitHub 星标数不是衡量一个基础设施项目的正确指标。LF 的星标不多，但它：追的是"多应用组合 + 多硬件组合"这个长期趋势，不是某一个具体的浪头；内核是从单日 PB 级真实流量中洗礼出来的，不是实验室里拼出来的；18 种语言绑定、20+ 种生成器覆盖、完整测试体系、完整知识库——都是**已经跑通的实物**。

**只要世界科技圈有个浪头，它就能起飞。** 它不需要"现在就很火"，它需要的是"在浪头来的时候，已经准备好了"。

欢迎来撩、来喷、来 PR——**Star 是最好的催更。**

---

*项目始于 2026 年，持续进化中。有问题提 Issue，急事加 Q（600585）。*

**采用前请务必：跑 [test/](test/)，做 PoC，验证你自己的场景。**