# LingoFuse Java 绑定 — 知识库 + README

> **LingoFuse 是跨语言通讯地基。本文件是 Java 绑定的完整知识库：既是上手 README，也是日常查阅的权威参考。读完本文件，你将能够：**
>
> - 在 15 分钟内把 Java 绑定接入任何 JDK 22+ 项目；
> - 在三种寻址模式（App 名 / UID / P2PName）之间做正确的工程选择；
> - 理解 wire 协议的字节级契约，确保与 Pascal / Python / C++ / C# / JavaScript 逐字节互通；
> - 掌握异步子系统的生命周期模型，写出无泄漏、无死锁的生产代码；
> - 掌握回调、side-data、错峰重试、幂等性等真实应用模式。

---

## 目录

**第一部分 — 快速入门**
- [第 1 章 — 30 秒概述](#第-1-章--30-秒概述)
- [第 2 章 — 环境搭建](#第-2-章--环境搭建)
- [第 3 章 — 第一个程序](#第-3-章--第一个程序)

**第二部分 — 核心概念**
- [第 4 章 — LingoFuse 是什么](#第-4-章--lingofuse-是什么)
- [第 5 章 — 五种抽象](#第-5-章--五种抽象)
- [第 6 章 — 三寻址模式](#第-6-章--三寻址模式)

**第三部分 — 核心机制**
- [第 7 章 — Wire 协议字节级契约](#第-7-章--wire-协议字节级契约)
- [第 8 章 — Side Data 注入机制](#第-8-章--side-data-注入机制)
- [第 9 章 — 回调执行模型](#第-9-章--回调执行模型)
- [第 10 章 — DataHandle 生命周期](#第-10-章--datahandle-生命周期)
- [第 11 章 — 异步子系统](#第-11-章--异步子系统)

**第四部分 — API 参考**
- [第 12 章 — `DataHandle`](#第-12-章--datahandle)
- [第 13 章 — `AppHandle`](#第-13-章--apphandle)
- [第 14 章 — `Framework`](#第-14-章--framework)
- [第 15 章 — `LfIo`](#第-15-章--lfio)
- [第 16 章 — `Target` 家族](#第-16-章--target-家族)
- [第 17 章 — `Options`](#第-17-章--options)
- [第 18 章 — `P2PRegistry`](#第-18-章--p2pregistry)
- [第 19 章 — `NetworkEvents`](#第-19-章--networkevents)
- [第 20 章 — `LingoFuseStatus`](#第-20-章--lingofusestatus)
- [第 21 章 — 异常体系](#第-21-章--异常体系)

**第五部分 — 真实应用模式**
- [第 22 章 — 服务端模式](#第-22-章--服务端模式)
- [第 23 章 — 客户端模式](#第-23-章--客户端模式)
- [第 24 章 — Worker 池模式](#第-24-章--worker-池模式)
- [第 25 章 — 身份感知与授权](#第-25-章--身份感知与授权)
- [第 26 章 — 跨语言集成](#第-26-章--跨语言集成)
- [第 27 章 — 生命周期与优雅关闭](#第-27-章--生命周期与优雅关闭)

**第六部分 — 运维**
- [第 28 章 — 故障排查](#第-28-章--故障排查)
- [第 29 章 — 性能特征](#第-29-章--性能特征)
- [第 30 章 — 已知限制](#第-30-章--已知限制)

**附录**
- [附录 A — 完整 API 索引](#附录-a--完整-api-索引)
- [附录 B — Wire 协议字节级示例](#附录-b--wire-协议字节级示例)
- [附录 C — 跨语言对照](#附录-c--跨语言对照)

---

# 第 1 章 — 30 秒概述

**LingoFuse Java 绑定**是基于 **JDK 22+ 的 FFM API（Project Panama）**实现的跨语言 RPC 客户端与服务端库。它**不依赖 JNI、JNA、JNR**，**不编写任何 C 胶水代码**，纯 Java 加载 `LingoFuse64.dll`（Windows）/ `liblingofuse.so`（Linux）/ `liblingofuse.dylib`（macOS），暴露出与 Pascal / Python / C++ / C# / JavaScript 完全一致的 59 个 C ABI 符号。

## 1.1 文件布局

```
java/
├── pom.xml                          Maven 项目配置
├── build.ps1 / clean.ps1 / test.ps1  Windows 辅助脚本
├── run_test_ci.ps1 / .sh            CI 报告脚本
├── README.md                        本文件
└── src/
    ├── main/java/lingofuse/         生产代码
    │   ├── DataHandle.java          RAII 数据句柄
    │   ├── AppHandle.java           RAII 应用句柄
    │   ├── Framework.java           进程级门面
    │   ├── LfIo.java                统一 JSON / 字符串 I/O
    │   ├── Options.java             16 对类型化选项
    │   ├── P2PRegistry.java         进程级 P2P 命名空间注册
    │   ├── NetworkEvents.java       全局网络事件
    │   ├── LingoFuseStatus.java     状态队列 + 健康检查
    │   ├── address/                 三寻址模式（Target 家族）
    │   ├── async/                   异步子系统
    │   ├── errors/                  5 个异常类型
    │   ├── ffi/                     FFM 层（用户不应直接调用）
    │   └── demo/                    单进程 / 多进程 demo
    └── test/java/lingofuse/         145 项单元测试
```

## 1.2 依赖方向（严格单向）

```
LingoFuse.h（C ABI 声明，59 个符号）
    │
    ├──> ffi/           FFM MethodHandle 绑定
    │       │
    │       ├──> DataHandle / AppHandle / Framework  （RAII 层）
    │       │       │
    │       │       ├──> address/     （三寻址模式）
    │       │       ├──> async/       （异步子系统）
    │       │       ├──> Options / P2PRegistry / NetworkEvents
    │       │       └──> LingoFuseStatus
    │       │
    │       └──> demo/    （应用层）
    │
    └──> LingoFuse64.dll / liblingofuse.so / liblingofuse.dylib
```

**唯一向下的调用链**。用户代码只应触碰 `DataHandle`、`AppHandle`、`Framework`、`LfIo`、`Options`、`P2PRegistry`、`NetworkEvents`、`LingoFuseStatus`、`address/`、`async/` 这些层。`ffi/` 是内部实现，不要直接调用。

## 1.3 七条铁律

| # | 规则 | 违反的后果 |
|:-:|------|-----------|
| 1 | 回调必须是 `cdecl` 风格（FFM 由 `Linker.nativeLinker()` 自动保证） | ABI 不匹配 |
| 2 | **绝不在回调内调用 `Framework.call` / `notify` / `prepareDone` / `shutdown`** | 死锁 |
| 3 | **所有 JSON / 字符串 I/O 必须经过 `LfIo`** | 帧错位、跨语言失败 |
| 4 | 清理顺序：`NetworkEvents.clear` → `exitMainThread` → `app.close` → `shutdown` | 悬空指针、崩溃 |
| 5 | 同一物理地址只能有一个 client，除非开启 `Overlap_Connection` | 静默丢连接 |
| 6 | **`LF_LoadLibrary` 之前不要调用任何 LF_* 函数**（Java 由 `LibraryLoader` 保证） | 空指针解引用 |
| 7 | **`getP2pUid` / `getP2pName` 只在 callback 的 `input` handle 上有效** | 读到 0 / 空串 |

## 1.4 关键默认值

| 项目 | 值 |
|------|---:|
| C ABI 导出符号数 | 59 |
| 默认 TCP 端口 | 9898 |
| DataHandle 空闲回收阈值 | 10 分钟 |
| 回收扫描间隔 | 5 秒 |
| `prepareDone` 初始化超时 | 30 秒 |
| `Wait_Connection_Timeout` 默认 | 30000 ms |
| `Overlap_Connection` 默认 | false |
| `Wait_Connection_ReadyOk` 默认 | true |
| `Fixed_Sequenced_Time` 默认 | 20000 ms |
| `LF_Generate_AppName` 指针有效期 | ~5 秒 |
| `LF_Get_P2P_UID` 指针有效期 | ~5 秒 |
| `LF_GetOption` 指针有效期 | ~5 秒 |
| 异步 op 超时后的 grace 期 | 60 秒 |
| 异步 stub 延迟释放（ArenaReaper） | 30 秒 |
| 测试总数 | 145 |

---

# 第 2 章 — 环境搭建

## 2.1 必需组件

| 组件 | 最低版本 | 推荐版本 |
|------|:--------:|:--------:|
| **JDK** | **22** | **25 LTS** |
| **Maven** | 3.8 | 3.9 / 3.10 |
| **操作系统** | Windows 10+ / Linux / macOS | 任意 64 位 |
| **CPU** | x86_64 / aarch64 | — |

**不需要**：C/C++ 编译器、CMake、Ninja、Python、Node.js、Visual Studio。

## 2.2 安装 JDK 25

### Windows

```powershell
winget install EclipseAdoptium.Temurin.25.JDK
```

或者从 Adoptium 官网下载 msi，安装时勾选 **Set JAVA_HOME** 和 **Add to PATH**。

### Linux（Ubuntu / Debian）

```bash
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | \
    sudo gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg

echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] \
https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/adoptium.list

sudo apt update
sudo apt install temurin-25-jdk
```

### macOS

```bash
brew install --cask temurin@25
```

### 验证

```bash
java -version
```

预期输出 `openjdk version "25.x.x"`。若显示 8 / 11 / 17 / 21，需要修正 `JAVA_HOME`。

## 2.3 安装 Maven

```powershell
# Windows
winget install Apache.Maven

# Linux
sudo apt install maven

# macOS
brew install maven
```

验证：

```bash
mvn -version
```

`Java version` 必须是 `22.x` 或更高。

## 2.4 原生库放置

Java 绑定**不包含** `LingoFuse64.dll` 等原生共享库。该库需单独构建（从 Pascal / C++ 源码），并放到操作系统加载器能找到的位置。

### 期望的文件名

| 平台 | 主库 | 依赖 |
|------|------|------|
| Windows 64 位 | `LingoFuse64.dll` | `z_ipc_64.dll`、`mimalloc64.dll` |
| Windows 32 位 | `LingoFuse32.dll` | `z_ipc_32.dll` |
| Linux / BSD | `liblingofuse.so` | `libz_ipc.so` |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` |

### 搜索顺序

`LibraryLoader` 依次尝试：

1. **系统加载器路径**（Windows `PATH` / Linux `LD_LIBRARY_PATH` / macOS `DYLD_LIBRARY_PATH`）
2. **`java.library.path`** 中的每个目录
3. **当前工作目录**

### 放置方式

**推荐（最简单）**：把原生库复制到项目根目录 `java/`：

```powershell
Copy-Item "D:\CoreLibrary\LingoFuse\Binary\*.dll" .
```

**或者**把 `Binary/` 加入 `PATH`：

```powershell
$env:PATH += ";D:\CoreLibrary\LingoFuse\Binary"
```

**Linux / macOS**：

```bash
sudo cp liblingofuse.so libz_ipc.so /usr/local/lib/
sudo ldconfig
```

---

# 第 3 章 — 第一个程序

## 3.1 最小可运行的服务端（Calculator）

```java
import lingofuse.AppHandle;
import lingofuse.Framework;
import lingofuse.LingoFuseStatus;
import lingofuse.NetworkEvents;

public final class CalculatorServer {
    public static void main(String[] args) throws Exception {
        AppHandle app = null;
        boolean started = false;

        try {
            // 1. 创建应用，注册 Call API
            app = new AppHandle("Calculator", "Demo calculator");
            app.registerCall("add", "Add two int32", (input, output) -> {
                int a = input.readInt32();
                int b = input.readInt32();
                output.writeInt32(a + b);
            });

            // 2. 网络准备
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
            Framework.setOption("Wait_Connection_Timeout", "10000");
            Framework.resetPrepare();
            Framework.prepareService("ipc:calc", "ipc:calc");
            Framework.prepareClient("ipc:calc", app);

            // 3. 启动
            if (Framework.prepareDone() != 1
                    && !LingoFuseStatus.checkMainThread()) {
                throw new IllegalStateException("startup failed");
            }
            started = true;

            System.out.println("Ready. Press Enter to stop.");
            System.in.read();

        } finally {
            // 4. 清理（严格顺序）
            try { NetworkEvents.clear(); } catch (Throwable ignored) {}
            try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
            try { if (app != null) app.close(); } catch (Throwable ignored) {}
            try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
        }
    }
}
```

## 3.2 最小可运行的客户端

```java
import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.LingoFuseStatus;

public final class CalculatorClient {
    public static void main(String[] args) {
        boolean started = false;
        try {
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.resetPrepare();
            Framework.prepareClient("ipc:calc", null);

            if (Framework.prepareDone() != 1
                    && !LingoFuseStatus.checkMainThread()) {
                System.err.println("startup failed");
                return;
            }
            started = true;

            try (DataHandle req = new DataHandle("add")) {
                req.writeInt32(5);
                req.writeInt32(7);

                try (DataHandle resp = Framework.call(
                        "Calculator", req, 3000L)) {

                    if (resp.size() == 0) {
                        System.out.println("timeout or target not found");
                        return;
                    }
                    System.out.println("5 + 7 = " + resp.readInt32());
                }
            }
        } finally {
            try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
            try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
        }
    }
}
```

## 3.3 编译与运行

```powershell
cd D:\CoreLibrary\LingoFuse\java
.\build.ps1
java --enable-native-access=ALL-UNNAMED `
     -cp target\classes CalculatorServer
```

**注意 JDK 24+ 必须加 `--enable-native-access=ALL-UNNAMED`**（`pom.xml` 已经为测试和 exec plugin 配置过）。

## 3.4 跑一次全量测试

```powershell
.\test.ps1
```

预期输出：

```
[INFO] Tests run: 145, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

---

# 第 4 章 — LingoFuse 是什么

## 4.1 一句话定义

> **LingoFuse 是跨语言、跨进程、跨机器的 RPC 框架。任何语言只要绑定它的 59 个 C ABI 符号，就能与其他语言互通。Java 绑定用 FFM 实现这一目标，不依赖任何 C 胶水。**

## 4.2 为什么要跨语言

现代系统往往由多个语言组件构成：Python 做 AI / 数据处理、C++ 做高性能计算、C# 做业务逻辑、Java 做数据管道、Pascal 做底层服务、JS 做前端。它们之间的通讯通常要走 HTTP / gRPC / Message Queue。

LingoFuse 的目标是提供**统一、低延迟、跨语言的进程间通讯层**：

- **一次 RPC 定义，所有语言互通**；
- **Wire 协议完全字节级对齐**，无适配成本；
- **服务发现、负载均衡、异步回调都内建**。

## 4.3 与其他 RPC 框架的差别

| 特性 | LingoFuse | gRPC | Thrift | HTTP+JSON |
|------|-----------|------|--------|-----------|
| 跨语言 | 10+ 语言 | 10+ 语言 | 10+ 语言 | 全部 |
| 接口定义 | 反射式，无需 IDL | 需 `.proto` | 需 `.thrift` | 无 |
| 序列化 | 用户自定义（JSON 推荐） | Protobuf | Binary | JSON |
| 服务发现 | 内建 | 需 consul/etcd | 需 ZooKeeper | 无 |
| 负载均衡 | 内建 | 需 sidecar | 需 sidecar | 无 |
| 异步 | 内建 | 需 async stub | 需 async stub | 需额外库 |
| 学习曲线 | 低（无 IDL） | 中 | 中 | 极低 |

## 4.4 一个关键的架构决策：Wire 协议由用户掌控

LingoFuse **不做接口约定**。它只提供：

- 一个二进制缓冲区（`DataHandle`）；
- 一套寻址键（App 名 / UID / P2PName）；
- 一套调用语义（Call / Notify / Sequenced_Notify）。

**载荷里放什么由用户决定**。工具的推荐做法是用 JSON 字符串（`LfIo.writeJson` / `readJson`），但 LingoFuse **不会强制你**。这是它灵活的最大来源，也是它容易被误用的地方 —— 你的两端必须约定同一套载荷格式。

---

# 第 5 章 — 五种抽象

理解 LingoFuse 的五个核心抽象，是理解后续一切机制的前提。

```
┌──────────────────────────────────────────────────────────┐
│  DataHnd      二进制缓冲区 + API 名                       │
│  AppHnd       API 容器（逻辑上的"服务"）                 │
│  Service      监听端点（信标）                            │
│  Client       连接到 Service 的节点                       │
│  Mesh（C4）   服务发现 + 路由 + 负载均衡                  │
└──────────────────────────────────────────────────────────┘
```

| 抽象 | 底层类型 | 生命周期 | 归属 |
|------|---------|---------|------|
| **DataHnd** | `TLF_Data` record | 空闲 10 分钟回收（仅 auto-recycled 类型） | 全局 handle pool |
| **AppHnd** | `TLF_App` object | 直到 `shutdown()` | 全局 app pool |
| **Service** | C4 physical service | 直到 `shutdown()` | 内部 |
| **Client** | C4 physical client | 直到 `shutdown()` | 内部 |
| **MESH** | C4 service mesh | 进程级单例 | 内部 |

用户只会直接接触 `DataHandle` 和 `AppHandle`。Service / Client / MESH 是内部的，你只通过 `prepareService` / `prepareClient` / `prepareDone` 影响它们。

## 5.1 Service 与 Client 的角色

- **Service**：监听端点。维护注册表（谁暴露了哪些 API），并广播给所有 client。
- **Client**：连接到 Service 的节点。可以暴露自己的 App / API，也可以是纯消费者。
- **一个进程可以同时是 Service 和 Client**（自连通）。

| 角色 | `prepareService` | `prepareClient` | 绑定 App |
|------|:---:|:---:|:---:|
| 纯信标 | ✅ | ✅（自连） | ❌ |
| 计算节点 | ❌ | ✅ | ✅ |
| 纯消费者 | ❌ | ✅ | ❌ |
| 独立运行 | ✅ | ✅ | ✅ |

## 5.2 C4 Mesh 提供的五项能力

1. **服务发现**：Client 连接时把 App / API 信息推给 Service。
2. **广播**：Service 把注册表分发给所有 Client。
3. **路由**：`Framework.call` 查本地缓存，选目标 Client。
4. **负载均衡**：多个 Client 提供同名 App 时，按 `Cycle_Time_Anchor` 选择最久未用的。
5. **本地优先**：目标 App 在本进程内，直接本地调用，不走网络。

## 5.3 Service Discovery 时序

```
Worker                  Service                  Caller
  │                        │                        │
  ├── prepareClient(addr) ─►                       │
  │                        ├── 记录 App/API        │
  │                        ├── 广播 "demo online" ─►│
  │                        │                        │
  │                        │◄── call("demo","add") ─┤
  │                        ├── 查缓存、选目标        │
  │◄── 转发请求 ────────────┤                        │
  ├── 执行回调              │                        │
  ├── 返回结果 ────────────►├── 返回结果 ───────────►│
```

**三个核心推论**：

1. **`checkApi` 有约 3 秒延迟** —— 它读的是本地缓存的广播视图。
2. **多个 Worker 会被自动负载均衡** —— 按 `Cycle_Time_Anchor` 选择。
3. **`Framework.call` 可以打到本进程的 App** —— 本地优先。

---

# 第 6 章 — 三寻址模式

LingoFuse 的 C ABI 支持三套**完全独立**的寻址键。在 Java 里各有对应的 `Target` 类，共享完全对等的 API。

## 6.1 何时用哪个

| 寻址模式 | 索引键 | 路由语义 | 本地优先？ | 负载均衡？ | 典型用途 |
|---------|--------|---------|:---------:|:---------:|---------|
| **App 名** | UTF-8 字符串 | 定位到"逻辑 App" | ✅ 是 | ❌ | 固定服务（一个 App 一个职责） |
| **UID** | 32 字节会话标识 | 定位到"具体客户端" | ✅ 是 | ❌ | 定向到具体客户端（如 whoami 后回访） |
| **P2PName** | 用户自定义组名 | 定位到"组内任意成员" | ❌ 否 | ✅ 服务端 | 同质服务集群（worker pool） |

## 6.2 App 名寻址

**最常见的模式**。当你有一个稳定的逻辑服务（比如"计算器"、"认证服务"、"日志服务"），用 App 名寻址。

```java
import lingofuse.address.AppTarget;
import lingofuse.DataHandle;

AppTarget target = new AppTarget("Calculator");

try (DataHandle req = new DataHandle("add")) {
    req.writeInt32(5);
    req.writeInt32(7);
    try (DataHandle resp = target.call(req, 3000)) {
        System.out.println("5 + 7 = " + resp.readInt32());
    }
}
```

**关键属性**：

- **本地优先**：如果调用方进程内已有名为 `Calculator` 的 App 且注册了 `add`，请求会被本地服务，不走网络。
- **无负载均衡**：如果有多个进程都注册了 `Calculator`，路由**不确定**（可能落到任意一个）。
- **适合**：单实例服务，或"无论哪个实例处理都行"的场景。

## 6.3 UID 寻址

当你需要**定向到某一个具体客户端**时用 UID。

```java
import lingofuse.address.UIDTarget;

byte[] uid = acquireClientUid();          // 32 字节，来自 side-data 或 whoami
UIDTarget target = new UIDTarget(uid);

try (DataHandle req = new DataHandle("echo")) {
    req.writeString("hello via UID");
    try (DataHandle resp = target.call(req, 3000)) {
        System.out.println(resp.readString());
    }
}
```

**关键属性**：

- **本地优先**：与 App 名一致。
- **UID 会随重连变化**：每次 TunnelLink 都会生成新的 UID。缓存 UID 的代码必须在重连后重新探测。
- **适合**：需要在特定客户端上执行有状态操作（如会话管理、定向通知）。

**UID 从哪里来？** 客户端自己的 UID 由服务端分配，可通过 **whoami 模式**探测：

```java
// 服务端注册一个 whoami API
P2PRegistry.registerCall("whoami", "echo caller identity",
    (in, out) -> {
        byte[] callerUid = in.getP2pUid();       // side data
        String callerName = in.getP2pName();     // side data
        LfIo.writeJson(out, Map.of(
                "uid_hex", toHex(callerUid),
                "p2p_name", callerName));
    });

// 客户端调用 whoami 拿到自己的 UID
try (DataHandle req = new DataHandle("whoami")) {
    try (DataHandle resp = new UIDTarget(broadcastAddr).call(req, 3000)) {
        Map<String, Object> me = LfIo.readJson(resp, Map.class);
        String uidHex = (String) me.get("uid_hex");
        // 缓存 uidHex，后续用于定向寻址
    }
}
```

## 6.4 P2PName 寻址

当你有一组**同质 Worker**，希望把请求分发到其中任意一个（并让服务端做负载均衡）时用 P2PName。

```java
import lingofuse.address.P2PNameTarget;
import lingofuse.Options;

// 1. Worker 侧声明自己所属的组（每个 Worker 都要执行一次）
Options.setP2pName("worker_group");

// 2. 调用方按组名寻址
P2PNameTarget target = new P2PNameTarget("worker_group");

try (DataHandle req = new DataHandle("process")) {
    LfIo.writeJson(req, Map.of("task", "batch-42"));
    try (DataHandle resp = target.call(req, 5000)) {
        Map<String, Object> result = LfIo.readJson(resp, Map.class);
    }
}
```

**关键属性**：

- **不做本地优先**：即使调用方本身就在组内，也会**转发到服务端**，由服务端决定目标客户端。
- **服务端负载均衡**：默认按 `Cycle_Anchor` 选择，`Fixed_Sequenced_Time` 控制粘滞窗口。
- **适合**：无状态计算任务的横向扩展。

## 6.5 三种模式的选择决策树

```
你需要调用的目标是什么？
│
├─ 一个固定的逻辑服务（如 "Calculator"）
│   └─ 用 AppTarget
│
├─ 具体某一个客户端（从 UID 来）
│   └─ 用 UIDTarget
│
└─ 一组同质 Worker 中的任意一个
    └─ 用 P2PNameTarget
```

## 6.6 Target 家族的公共 API

三个 Target 都继承自 `lingofuse.address.Target`，共享完全对等的 API：

| 方法 | 说明 |
|------|------|
| `call(param)` / `call(param, timeoutMs)` | 同步调用 |
| `callJson(param, Type)` / `callJson(param, Type, timeoutMs)` | 同步调用 + JSON 反序列化 |
| `notify(param)` | 单向通知 |
| `sequencedNotify(param)` | FIFO 单向通知 |
| `asyncCall(param, handler)` | 异步回调（raw handle） |
| `asyncCallJson(param, Type, handler)` | 异步回调（类型化） |
| `asyncSequencedCall(...)` / `asyncSequencedCallJson(...)` | FIFO 异步回调 |
| `callFuture(param, Type)` / `callFuture(param, Type, timeoutMs)` | 返回 `CallFuture<T>` |
| `sequencedCallFuture(...)` | FIFO 版 Future |
| `describe()` | `"app(X)"` / `"uid(hex)"` / `"p2pname(g)"` |

**Target 的值语义**：三个 Target 都实现了 `equals` / `hashCode` / `toString`。可以作为 Map 的 key。

---

# 第 7 章 — Wire 协议字节级契约

> **本章是跨语言互通的核心。任何语言绑定对本章内容的理解偏差，都会导致互通失败。**

## 7.1 字符串帧：UTF-8 + 单个 NUL

LingoFuse 的字符串在 wire 上永远是：

```
[UTF-8 编码的字节序列] [0x00]
```

- **写入**：`LfIo.writeString(hnd, "abc")` 产生 `61 62 63 00`。
- **读取**：`LfIo.readString(hnd)` 从当前位置开始扫描，遇到 `0x00` 停止，返回其之前的字节（UTF-8 解码）。
- **容错读**：如果扫描到缓冲区末尾都没遇到 `0x00`，返回整个剩余部分，光标移到 `size + 1`（库隐含增长缓冲区 1 字节）。**这是为兼容 HTTP 桥接等非标准生产者而设计的**。

## 7.2 整数编码：小端序（Little-Endian）

| 类型 | 字节数 | 示例 |
|------|:------:|------|
| `int8` | 1 | `-1` → `FF` |
| `uint8` | 1 | `255` → `FF` |
| `int16` | 2 | `-1` → `FF FF` |
| `uint16` | 2 | `65535` → `FF FF` |
| `int32` | 4 | `0x01020304` → `04 03 02 01` |
| `uint32` | 4 | `0xFFFFFFFF` → `FF FF FF FF` |
| `int64` | 8 | `0x0102030405060708` → `08 07 06 05 04 03 02 01` |
| `uint64` | 8 | 同上 |

## 7.3 浮点编码：IEEE 754 小端序

| 类型 | 字节数 | 示例 |
|------|:------:|------|
| `float` | 4 | `3.14f` → `C3 F5 48 40` |
| `double` | 8 | `3.14` → `1F 85 EB 51 B8 1E 09 40` |

## 7.4 JSON 序列化策略

**唯一入口**：`LfIo.dumpsJson(obj)` / `LfIo.writeJson(hnd, obj)`。

**策略**：

```java
new ObjectMapper().writeValueAsString(obj)
```

Jackson 的默认行为：

- **紧凑输出**：无缩进、无换行。
- **`ensure_ascii=false`**：非 ASCII 字符（中文、emoji）以字面 UTF-8 输出，**绝不产生 `\uXXXX` 转义**。
- **类型严格**：不可序列化的类型抛异常（**注意**：这与 Python 的 `default=str` 不同 —— Python 会把不可序列化对象降级为 `str(obj)`，Java 抛异常）。

## 7.5 字节级验证表

| 载荷 | 所有语言产生的字节 |
|------|-------------------|
| `{"a":1}` | `7B 22 61 22 3A 31 7D 00` |
| `int32 = 0x01020304` | `04 03 02 01` |
| `uint16 = 0xAABB` | `BB AA` |
| `"你好"` | `E4 BD A0 E5 A5 BD 00` |
| `"🌍"` | `F0 9F 8C 8D 00` |

## 7.6 完整 Call 请求的 wire 布局

一次 `LF_Call(appName, param, timeoutMs)` 在 wire 上发送：

```
[4 字节长度 LE][appName UTF-8 + NUL]
[param 的 API 名 UTF-8 + NUL]
[8 字节 param 缓冲区大小 LE][param 缓冲区字节]
```

**注意**：`appName` 和 `timeoutMs` **不进 wire**（它们用于本地路由决策）；只有 `param` 的 API 名和缓冲区内容才过网。

服务端收到的 `input` handle 已经在**正确的光标位置**（可以立即 `readInt32`）。返回时：

```
[4 字节长度 LE][输出 API 名 UTF-8 + NUL]
[8 字节输出缓冲区大小 LE][输出缓冲区字节]
```

调用方拿到的 `DataHandle` 光标同样在 0。

## 7.7 跨语言不变量清单

**所有语言绑定必须字节一致的部分**：

| 契约 | 数值 / 语义 |
|------|------------|
| 字符串帧 | UTF-8 字节 + 单个 `0x00` |
| 整数编码 | 小端序 |
| 浮点编码 | IEEE 754 小端序 |
| JSON 策略 | 紧凑、`ensure_ascii=false`、无 `\uXXXX` |
| UID 参数表示 | 32 字节数组，cdecl 按值（实际退化为指针） |
| UID 返回值表示 | **指针**（`PP2P_UID___`），非值 |
| `LF_Get_P2P_UID` 返回缓冲有效期 | ~5 秒 |
| `LF_Call` 超时语义 | 返回 **size=0 的 handle**，非 NULL |
| `LF_Async_Call` 的 `Result_` 所有权 | framework 拥有，回调返回即释放 |
| 回调线程模型 | native worker 线程 |
| `LF_PrepareDone` 单次返回 1 | 第二次返回 0（非失败） |

**Java 私有的部分**（不影响 wire，其他语言无需对等）：

| Java 私有机制 | 作用范围 |
|--------------|---------|
| `ReentrantReadWriteLock` | Java 进程内 |
| `ArenaReaper` | Java 进程内 |
| `AsyncBridge` / `AsyncOp` / `CallFuture` | Java 进程内 |
| `reportCallbackError` 的 stderr sink | Java 进程内 |
| `MAX_C_STRING_LENGTH = 1MB` 安全上界 | 本地读取防御 |
| UID arena close 前清零 | Java 进程内 |
| JVM shutdown hook | 进程退出时机 |

**红线**：Java 私有机制的修改，**不得改变 wire 上的字节序列、参数顺序、语义**。上一轮 P0/P1 修复的所有改动均落在 Java 私有类别中。

---

# 第 8 章 — Side Data 注入机制

## 8.1 什么是 side data

**每次远程请求，发送方的 transport 层会在载荷头部自动注入两个身份字段**：

| 字段 | 含义 | 长度 |
|------|------|------|
| `FromUID` | 发送方的 32 字节会话 UID | 32 字节 |
| `FromP2PName` | 发送方声明的 P2P 组名 | UTF-8 + NUL |

在 Pascal 侧，由 `TC40_LF_Client.Send_*` → `TMemory_Param_Tool.Rebuild_UID_and_P2PName` 完成注入。

**这意味着接收方在 callback 的 INPUT handle 里能直接读到这两个字段，无需任何请求参数或额外约定。**

## 8.2 在 Java 里读取

```java
app.registerCall("whoami", "echo caller identity", (in, out) -> {
    byte[] senderUid = in.getP2pUid();      // 32 字节，永远非 null
    String senderName = in.getP2pName();    // UTF-8 字符串，可能为 ""
    LfIo.writeJson(out, Map.of(
            "uid_hex", toHex(senderUid),
            "p2p_name", senderName));
});
```

`DataHandle.getP2pUid()` 立即把 32 字节**拷贝到 Java `byte[]`**，调用者拿到的是完全脱离 C buffer 的 Java 对象。可以直接持有、跨线程传递、不需要手动释放。

## 8.3 只在 INPUT handle 上有效

这是最容易犯的错误。side data 是**发送方写入的**，不是 handle 的属性。

| 位置 | `getP2pUid()` / `getP2pName()` |
|------|:------------------------------:|
| `On_Call(Input, Output)` 的 `Input` | ✅ 有效 |
| `On_Notify(Input)` 的 `Input` | ✅ 有效 |
| `AppHandle.localCall(param)` 回调的 `Input` | ✅ 有效 |
| `OnResult(Result_)` 的 `Result_`（异步回调） | ❌ 返回全 0 / 空串 |
| `new DataHandle("api")`（自己创建的） | ❌ 返回全 0 / 空串 |

**违反的后果**：静默拿到全 0 UID / 空串。C 侧会打一条 warning 到日志。

## 8.4 与 `Options.getP2pName()` 的区别

这两个方法名字相同，**语义完全无关**：

| 方法 | 读什么 | 何时有效 |
|------|-------|---------|
| `Options.getP2pName()` | **本进程**声明的组名（本地配置） | 任何时刻 |
| `DataHandle.getP2pName()` | **发送方**的组名（side data） | 只在 callback 的 Input 上 |

**记忆法**：

- `Options.*` 是"我"——本进程的配置。
- `DataHandle.getP2p*` 是"他"——对端的身份。

## 8.5 典型用途

1. **调用准入 / 授权**：比对 UID 白名单。
2. **审计日志**：把 caller UID 记录成 hex。
3. **会话状态**：以 UID 为 key 维护每个 callers 的状态字典。
4. **多租户**：用 P2P 组名当 tenant id。
5. **whoami 探针**：让客户端学会自己的 UID。

## 8.6 UID 的生命周期

**UID 会随重连变化**。每次 `TunnelLink` 都会生成新的 UID。

- **缓存 UID 的代码必须在重连后重新探测**。
- **不要**把 UID 当作永久身份证明。
- **推荐**：用 whoami 模式在每次连接建立后重新探测一次。

---

# 第 9 章 — 回调执行模型

## 9.1 回调在 native worker 线程上执行

**这是本框架最容易踩坑的部分。**

所有通过 `registerCall` / `registerNotify` / `asyncCall*` 注册的回调，都在 **LingoFuse 内部线程池**的 **native worker 线程**上执行 —— **不是**调用线程，**不是**主线程。

## 9.2 五条铁律

| # | 铁律 | 违反的后果 |
|:-:|------|-----------|
| 1 | **不阻塞**：不要在回调里做 IO、`Thread.sleep`、等锁 | 线程池饿死 |
| 2 | **不调阻塞型 LingoFuse 函数**：`Framework.call` / `notify` / `prepareDone` / `shutdown` | **死锁** |
| 3 | **不碰 UI**：需要更新 UI 时用 `CompletableFuture` / `ExecutorService` 转发 | 随机崩溃 |
| 4 | **不持有 input/output handle**：它们只在本回调期间有效 | use-after-free |
| 5 | **不抛异常**：绑定已经 try/catch，但自己 catch 更好 | 异常被吞，无法排查 |

## 9.3 为什么回调内 `Framework.call` 会死锁

- Callback 运行在 C4 worker 线程上。
- worker 线程持有内部锁（用于 callback dispatch）。
- `Framework.call` 需要模拟主线程派发响应。
- 模拟主线程在等同一个内部锁。
- **自死锁**。

**正确做法**：需要发起新请求时，把 `DataHandle` 数据拷贝出来，投递到自己的线程池 / `CompletableFuture`。

## 9.4 异常隔离

Java 绑定在回调 wrapper 里做了 `try/catch(Throwable)`。**任何逃逸到 C 栈的异常都会崩溃进程**，所以这一步是必需的。

Catch 到的异常会通过 `Framework.reportCallbackError` 上报：

```java
Framework.setCallbackErrorHandler((source, exception) -> {
    // 你的日志管线
    logger.error("[LF] callback error in {}: {}",
                 source, exception.getMessage(), exception);
});
```

**注意**：默认情况下也会打到 stderr。要禁用 stderr：

```java
Framework.setCallbackErrorStderrFallback(false);
```

## 9.5 output handle 的构造语义

**写 `output` = 返回结果**。当回调对 `output` 调用了 `writeXxx`，框架会把 `output` 的字节 marshalling 回调用方。

**空的 `output`**：回调不写任何东西，调用方收到 **size=0 的 handle**。

**注意**：`input` 是**只读**的，`output` 是**只写**的。在回调里对 `input` 写、对 `output` 读都是**未定义行为**。

---

# 第 10 章 — DataHandle 生命周期

## 10.1 两种 handle

| 类型 | 创建方式 | 加入空闲池 | 回收时机 | 释放方式 |
|------|---------|:---------:|---------|---------|
| **Auto-recycled** | `new DataHandle("api")` | ✅ | 空闲 10 分钟后 | `close()` 只标记，下次池扫描（≤5s）真正释放 |
| **Permanent** | `DataHandle.createPermanent("api")` | ❌ | 永不自动回收 | `close()` 立即同步释放 |

**选择标准**：

- **默认用 auto-recycled**：短生命周期、一次性使用。
- **Permanent 用于**：跨整个进程生命周期持有的 handle（缓存模板、全局 registry）。

## 10.2 引用计数与借用

```java
// 拥有（自己创建，需要自己释放）
try (DataHandle h = new DataHandle("api")) {
    // ...
}  // 自动 close

// 借用（callback 收到的 input/output，不归你管）
DataHandle inputHandle = DataHandle.fromRaw(raw, false);
// close() 是 no-op；框架在回调返回时释放
```

**借用的 handle 上的 `close()` 是安全 no-op**：不改变 wrapper 状态，仍然可以继续读。这是为了容忍回调里误调 `close()` 的情况。

## 10.3 空闲回收

- **扫描周期**：5 秒（可通过 `Options.setDataHandlePoolScanInterval` 调整）。
- **回收阈值**：10 分钟（可通过 `Options.setDataHandleIdleTimeout` 调整）。
- **任何访问**（`getSize` / `getPos` / `read*` / `write*`）都会刷新 idle 时间戳。
- **远程调用进行中**：input handle 的 `calling___` 计数器 > 0，免于回收。

**不要依赖自动回收**。高负载下 auto-recycled handle 的增长可能超过回收速度。生产代码应该显式 `close()`。

## 10.4 线程安全模型

Java 绑定在 `DataHandle` 内部加了 `ReentrantReadWriteLock`：

- **写操作**（`writeXxx`、`setPosition`、`setSize`、`close`）：写锁。
- **读操作**（`position`、`size`、`getBufferPointer`）：读锁。

这**解决了**：

- 两个线程同时 `close()` 造成的双重释放。
- 读端持有指针，写端触发 realloc 造成的 use-after-free。

这**不能解决**：

- 跨进程的并发写（这本来就不允许，由 LingoFuse ABI 约束）。
- 逻辑上的语义竞态（你的应用代码需要自己解决）。

**关键**：这个锁是 **Java 私有的**，**不侵入 wire**。其他语言绑定不需要也不应有对等机制。

## 10.5 Handle 大小与位置

- **初始大小**：0。
- **`writeXxx` 后**：光标移到末尾。
- **`readXxx` 后**：光标前进。
- **`setPosition(N)`**：光标移动；超过 size 会**隐式增长缓冲区**。
- **`setSize(N)`**：调整大小；新空间未初始化。

## 10.6 永久 handle 的正确用法

```java
// 进程启动时创建一次
DataHandle template = DataHandle.createPermanent("my_api");
LfIo.writeJson(template, Map.of("type", "template"));

// 整个进程生命周期内反复使用
// ...

// 退出前显式释放
template.close();
```

**注意**：

- `LF_ExitMainThread` 会**刷新整个 handle pool，包括 permanent handle**。
- 之后任何 handle 都失效。
- 所以 `LF_ExitMainThread` 之后不要使用任何 `DataHandle`。

---

# 第 11 章 — 异步子系统

## 11.1 为什么需要异步子系统

C ABI 层的 `LF_Async_Call` 是裸函数指针 + `void* user_data` 的组合。直接使用有三个陷阱：

1. **超时后回调可能仍会触发** —— C 侧不会取消请求。如果超时后就释放 stub，C 侧回调会打到已释放的内存。
2. **dispatch 失败会泄漏** —— 如果 C 侧返回 0（未入队），回调永不触发，stub 会永久泄漏。
3. **双重释放竞态** —— 调用方线程（超时路径）和 C worker 线程（回调路径）可能同时释放同一个 op。

**`AsyncBridge` 系统解决所有三个问题**。

## 11.2 状态机

```
         ┌─────────────┐
         │   PENDING   │  ← 已创建，等待 C 侧回调
         └──────┬──────┘
                │
    ┌───────────┼───────────┐
    │           │           │
  回调触发    超时触发    dispatch 失败
    │           │           │
    ▼           ▼           ▼
┌────────┐ ┌──────────┐ ┌──────────┐
│ FIRED  │ │ABANDONED │ │NOT_QUEUED│
└────────┘ └────┬─────┘ └──────────┘
                │
            迟到回调
                │
                ▼
            ┌────────┐
            │ FIRED  │
            └────────┘
```

- **FIRED**：C 侧回调已完成 Java 侧工作。立即调度释放 stub。
- **ABANDONED**：超时先触发。op 保持存活 `graceSeconds`（默认 60s），让迟到的回调能找到有效 Java 对象。grace 期满后释放。
- **NOT_QUEUED**：dispatch 失败。立即释放。

## 11.3 三种使用风格

### 11.3.1 类型化回调（推荐）

```java
try (DataHandle req = new DataHandle("api")) {
    LfIo.writeJson(req, Map.of("query", "..."));

    Framework.asyncCallJson("MyApp", req, Person.class, (person, error) -> {
        if (error != null) {
            log.warn("async call failed", error);
            return;
        }
        System.out.println("got " + person.name);
    });
}
```

**特点**：

- 用户看到的是普通 lambda `(T value, Throwable error) -> { ... }`。
- **没有 stub、没有 Arena、没有 handle 生命周期、没有 user_data**。
- 框架自动反序列化结果。

### 11.3.2 原始 handle 回调

```java
Framework.asyncCall("MyApp", req, (DataHandle result, Throwable error) -> {
    if (error != null) return;
    String value = LfIo.readString(result);  // 必须在回调内 copy
});
```

**特点**：

- 用户看到 `DataHandle`，**必须在回调内 copy 出数据**。
- 回调返回后 handle 立即失效（框架拥有）。

### 11.3.3 Future 风格

```java
AppTarget target = new AppTarget("MyApp");
try (DataHandle req = new DataHandle("api")) {
    LfIo.writeJson(req, Map.of("query", "..."));

    CallFuture<Person> future = target.callFuture(req, Person.class, 3000);

    // 链式组合
    future.thenAccept(person -> System.out.println("got " + person.name))
          .exceptionally(err -> { log.warn("failed", err); return null; });

    // 或阻塞等待
    Person p = future.get(5, TimeUnit.SECONDS);
    System.out.println(p.name);
}
```

**`CallFuture<T>` 是 `CompletableFuture<T>` 的子类**，额外提供：

```java
future.abandoned()   // true 表示超时放弃；C 侧请求可能仍在飞行
```

## 11.4 超时语义

- **超时后 Future 以 `LingoFuseTimeoutException` 完成**。
- `abandoned()` 变为 `true`。
- **C 侧请求不会被取消**；如果稍后响应到达，其数据被静默丢弃。
- **stub 保持存活 60 秒**（`graceSeconds`），让迟到的 C 回调能找到有效对象。

## 11.5 dispatch 失败语义

当 `LF_Async_Call` 返回 0 时：

- **回调不会被触发**（C 侧从未收到 stub）。
- op 状态变 `NOT_QUEUED`。
- **Future 被立即以 `LingoFuseException` 完成**（同步路径）。
- **用户回调被同步调用一次，参数为 `(null, LingoFuseException)`**。

**注意**：dispatch 失败时回调在**调用者线程上同步执行**，不是 worker 线程。**回调必须对任何线程安全**。

## 11.6 诊断接口

```java
AsyncBridge bridge = AsyncBridge.instance();
Map<String, Object> stats = bridge.stats();
// {
//   "total":           N,   // 活跃 op 数
//   "pending":         N,   // 等待回调
//   "fired":           N,   // 已触发，等待释放
//   "abandoned":       N,   // 超时，等待 grace
//   "not_queued":      N,   // dispatch 失败
//   "released_total":  N,   // 累计释放数
//   "grace_seconds":   N    // 当前 grace 期
// }

int liveOps = bridge.liveOpCount();
AsyncBridge.shutdownInstance();    // 测试隔离用
```

**`pending` 长期不降 = C 侧未响应**；`not_queued` 上升 = dispatch 失败。

## 11.7 stub 内存的回收（ArenaReaper）

FFM 的 upcall stub 分配在 `Arena.ofShared()` 里。每个 op 有独立的 arena。

**arena 什么时候关闭？**

- **op 状态 FIRED 或 NOT_QUEUED**：立即关闭（C 侧不会再用这个 stub）。
- **op 状态 ABANDONED**：**不关闭**，因为 C 侧可能仍在飞行，随时可能触发回调。arena 保留到 JVM 退出。

**为什么不在超时时直接关？** 因为 C 侧请求未取消，如果在超时时关闭 arena，C 侧回调会打到已释放的内存，进程崩溃。

**代价**：超时 op 的 arena 永不释放。这是**刻意的** —— 60 秒 grace 期无法 100% 保证 C 侧不会更晚触发。用几 KB 的 native 内存换取不会崩溃。

---

# 第 12 章 — `DataHandle`

RAII 数据句柄，实现 `AutoCloseable`。

## 12.1 创建

| 方法 | 说明 |
|------|------|
| `new DataHandle(String apiName)` | 创建 auto-recycled 句柄 |
| `DataHandle.createPermanent(String apiName)` | 创建 permanent 句柄 |
| `DataHandle.fromRaw(MemorySegment raw, boolean owned)` | 包装已有指针（内部用） |

## 12.2 生命周期

| 方法 | 说明 |
|------|------|
| `close()` | 释放句柄（借用的句柄是 no-op） |
| `isValid()` | handle 是否有效 |
| `isOwning()` | close() 是否会调用 `LF_FreeData` |
| `raw()` | 返回原生 `MemorySegment` |

## 12.3 位置与大小

| 方法 | 说明 |
|------|------|
| `position()` | 返回当前游标 |
| `setPosition(long)` | 移动游标；超过 size 会隐式增长 |
| `size()` | 返回总字节数 |
| `setSize(long)` | 调整大小；新空间未初始化 |
| `getBufferPointer()` | 内部缓冲区的原生指针 |

## 12.4 字节 I/O

| 方法 | 说明 |
|------|------|
| `writeBytes(byte[])` | 写原始字节 |
| `readBytes(int)` | 读至多 N 字节（短读不抛） |
| `readBytesExact(int)` | 精确读 N 字节（不足时抛 `LingoFuseIoException`） |
| `tryReadBytes(int)` | 不抛异常的精确读（返回 `ReadResult<byte[]>`） |
| `readAllBytes()` | 读至末尾 |

## 12.5 原子类型 I/O（小端序）

**写**：`writeInt8` / `writeUInt8` / `writeInt16` / `writeUInt16` / `writeInt32` / `writeUInt32` / `writeInt64` / `writeUInt64` / `writeSingle` / `writeDouble`。

**读**：`readInt8` / `readUInt8` / ... / `readDouble`。

**读是精确的**：数据不足会抛 `LingoFuseIoException`。

## 12.6 字符串 I/O

| 方法 | 说明 |
|------|------|
| `writeString(String)` | 写 UTF-8 + NUL |
| `readString()` | 读至 NUL（或缓冲区末尾） |
| `tryReadString()` | 不抛异常的读字符串 |

## 12.7 Side data 访问器

| 方法 | 说明 |
|------|------|
| `getP2pUid()` | 读发送方 32 字节 UID（side data，只在回调 Input 上有效） |
| `getP2pName()` | 读发送方 P2P 组名（side data，只在回调 Input 上有效） |

## 12.8 `ReadResult<T>`

`tryReadBytes` / `tryReadString` 返回 `ReadResult<T>`：

| 方法 | 说明 |
|------|------|
| `isOk()` | 是否成功 |
| `getValue()` | 成功时返回值；失败时返回 null |

---

# 第 13 章 — `AppHandle`

RAII 应用句柄，实现 `AutoCloseable`。

## 13.1 创建

| 方法 | 说明 |
|------|------|
| `new AppHandle(String name)` | 用空描述创建 |
| `new AppHandle(String name, String desc)` | 带描述创建 |

## 13.2 状态

| 方法 | 说明 |
|------|------|
| `name()` | 返回 App 名 |
| `isValid()` | handle 是否有效 |
| `raw()` | 返回原生 `MemorySegment` |
| `withHandle(Function<MemorySegment, T>)` | 在锁内执行操作（内部用） |

## 13.3 API 注册

| 方法 | 说明 |
|------|------|
| `registerCall(String api, BiConsumer<DataHandle, DataHandle> handler)` | 注册 Call API |
| `registerCall(String api, String desc, handler)` | 带描述 |
| `registerNotify(String api, Consumer<DataHandle> handler)` | 注册 Notify API |
| `registerNotify(String api, String desc, handler)` | 带描述 |
| `unregister(String api)` | 反注册 |

**返回值**：`boolean`。`false` 表示名字已存在。

**API 名大小写不敏感**：`registerCall("add", ...)` 和 `registerCall("ADD", ...)` 冲突。

## 13.4 本地执行

| 方法 | 说明 |
|------|------|
| `localCall(DataHandle param)` | 本地同步调用，返回结果 handle |
| `localNotify(DataHandle param)` | 本地通知 |

**本地执行不走网络**。适合单进程内跨 App 调用。

## 13.5 客户端绑定

| 方法 | 说明 |
|------|------|
| `bind()` | 绑定到所有空闲 Client，返回绑定数量 |

**注意**：`bind()` 必须在 `Framework.prepareDone()` 之后调用，且主线程必须运行中。`0` 表示没有空闲 client 或主线程未启动。

## 13.6 生命周期

| 方法 | 说明 |
|------|------|
| `close()` | 执行两阶段销毁的第一阶段 |

**两阶段销毁**：

1. `close()` → `LF_FreeApp`：从所有 client 分离、停止 sequenced 线程。
2. `Framework.shutdown()` → `LF_Shutdown`：真正销毁 `TLF_App` 对象。

**`close()` 之后 handle 失效**，不能再用。真正的对象留在全局池，直到 `shutdown()`。

---

# 第 14 章 — `Framework`

进程级门面。所有需要"全局视角"的操作都在这里。

## 14.1 回调错误处理

| 方法 | 说明 |
|------|------|
| `setCallbackErrorHandler(BiConsumer<String, Throwable>)` | 安装回调错误处理器 |
| `setCallbackErrorStderrFallback(boolean)` | 启用/禁用默认 stderr 输出（默认启用） |
| `reportCallbackError(String, Throwable)` | 内部用：上报 swallowed 异常 |

## 14.2 网络准备

| 方法 | 说明 |
|------|------|
| `resetPrepare()` | 清空准备队列（不影响已启动的服务） |
| `prepareService(String listen, String physics)` | 准备服务；返回 tag 或 -1 |
| `prepareClient(String physics, AppHandle app)` | 准备客户端；`app` 可为 null |
| `prepareDone()` | 启动框架；返回 1 或 0 |
| `exitMainThread()` | 停止模拟主线程 |

**`prepareDone()` 每进程只返回 1 一次**。第二次调用返回 0，**不是失败**。

**`exitMainThread()` 也会刷新 handle pool**，之后所有 handle 失效。

## 14.3 运行时选项

| 方法 | 说明 |
|------|------|
| `setOption(String option, String value)` | 设置选项（通用） |
| `getOption(String option)` | 读取选项（通用） |

**推荐用 `Options.*` 类型化方法**（见第 17 章）。

## 14.4 App 名

| 方法 | 说明 |
|------|------|
| `generateAppName()` | 生成全局唯一 App 名 |
| `getAppName(AppHandle app)` | 查询 App handle 的名字 |

**`generateAppName()` 必须在 `prepareDone()` 之后调用**，否则缺少 tunnel 信息，名字不唯一。

## 14.5 远程调用 — App 名

| 方法 | 说明 |
|------|------|
| `call(String app, DataHandle param, long timeoutMs)` | 同步调用 |
| `tryCall(String app, DataHandle param, long timeoutMs)` | 超时返回 null |
| `notify(String app, DataHandle param)` | 单向通知 |
| `sequencedNotify(String app, DataHandle param)` | FIFO 单向通知 |

**`call` 超时时返回 size=0 的 handle**（不是 null）。要区分"超时"与"空响应"，用 `tryCall` 或检查 `size()`。

## 14.6 远程调用 — UID

| 方法 | 说明 |
|------|------|
| `uidCall(byte[] uid, DataHandle param, long timeoutMs)` | 同步调用 |
| `tryUidCall(byte[] uid, DataHandle param, long timeoutMs)` | 超时返回 null |
| `uidNotify(byte[] uid, DataHandle param)` | 单向通知 |
| `uidSequencedNotify(byte[] uid, DataHandle param)` | FIFO 单向通知 |

## 14.7 远程调用 — P2PName

| 方法 | 说明 |
|------|------|
| `p2pCall(String group, DataHandle param, long timeoutMs)` | 同步调用 |
| `tryP2pCall(String group, DataHandle param, long timeoutMs)` | 超时返回 null |
| `p2pNotify(String group, DataHandle param)` | 单向通知 |
| `p2pSequencedNotify(String group, DataHandle param)` | FIFO 单向通知 |

## 14.8 异步调用（12 个方法）

**App 名**：

- `asyncCall(String app, DataHandle param, AsyncResultHandler handler)`
- `asyncCallJson(String app, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`
- `asyncSequencedCall(String app, DataHandle param, AsyncResultHandler handler)`
- `asyncSequencedCallJson(String app, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`

**UID**：

- `asyncUidCall(byte[] uid, ...)`
- `asyncUidCallJson(byte[] uid, ...)`
- `asyncUidSequencedCall(byte[] uid, ...)`
- `asyncUidSequencedCallJson(byte[] uid, ...)`

**P2PName**：

- `asyncP2pCall(String group, ...)`
- `asyncP2pCallJson(String group, ...)`
- `asyncP2pSequencedCall(String group, ...)`
- `asyncP2pSequencedCallJson(String group, ...)`

**全部返回 `boolean`**：`true` 表示入队成功，`false` 表示 dispatch 失败。

## 14.9 关闭

| 方法 | 说明 |
|------|------|
| `shutdown()` | 完全关闭框架 |

**安全可多次调用**。

---

# 第 15 章 — `LfIo`

**统一 JSON 与字符串 I/O**。这是**唯一被允许**触碰载荷的入口。任何绕过 `LfIo` 直接调 `DataHandle.writeBytes` 做 JSON 的做法都会破坏跨语言兼容。

## 15.1 JSON 序列化

| 方法 | 说明 |
|------|------|
| `dumpsJson(Object)` | 序列化为紧凑 JSON 字符串（无 NUL） |
| `loadsJson(String)` | 解析为 `JsonNode` |
| `loadsJson(String, Class<T>)` | 解析为 POJO |

## 15.2 JSON I/O

| 方法 | 说明 |
|------|------|
| `writeJson(DataHandle, Object)` | 写 JSON（紧凑 + UTF-8 + NUL） |
| `readJson(DataHandle)` | 读 JSON 为 `JsonNode` |
| `readJson(DataHandle, Class<T>)` | 读 JSON 为 POJO |
| `tryReadJson(DataHandle, Class<T>)` | 不抛异常版本 |

## 15.3 字符串 I/O

| 方法 | 说明 |
|------|------|
| `writeString(DataHandle, String)` | 写 UTF-8 + NUL |
| `readString(DataHandle)` | 读字符串 |
| `writeStringBytes(DataHandle, byte[])` | 写原始字节 + NUL |
| `readStringBytes(DataHandle)` | 读原始字节（至 NUL） |
| `readAllBytes(DataHandle)` | 读全部 |

## 15.4 反序列化到 POJO

```java
public class Person {
    public String name;
    public int age;
}

try (DataHandle resp = ...) {
    Person p = LfIo.readJson(resp, Person.class);
}
```

Jackson 会按字段名映射。**字段必须是 public 或者有 getter/setter**。

## 15.5 JSON 序列化策略（关键）

`dumpsJson(obj)` 的等价实现：

```java
new ObjectMapper().writeValueAsString(obj)
```

**三大保证**：

1. **紧凑输出**：无缩进、无换行。
2. **无 `\uXXXX` 转义**：中文、emoji 以字面 UTF-8 输出。
3. **类型严格**：不可序列化的类型抛异常。

**与 Python 的差异**：Python 的 `default=str` 会把不可序列化对象降级为 `str(obj)`，Java 抛异常。要序列化自定义类型，需要 Jackson 支持它（加注解 / 实现接口）或先转成 `JsonNode`。

---

# 第 16 章 — `Target` 家族

三个寻址模式的统一封装。

## 16.1 构造

```java
// App 名：任何非空字符串
new AppTarget("MyApp");
new AppTarget("MyApp", 10_000L);        // 显式默认超时

// UID：必须是 32 字节
new UIDTarget(uidBytes);
new UIDTarget(uidBytes, 10_000L);

// P2PName：任何非空字符串
new P2PNameTarget("worker_group");
new P2PNameTarget("worker_group", 10_000L);
```

**构造时校验**：`UIDTarget` 会校验 `uid.length == 32`，不满足抛 `IllegalArgumentException`。构造时做**防御性拷贝**。

## 16.2 同步调用

```java
DataHandle call(DataHandle param)
DataHandle call(DataHandle param, long timeoutMs)
<T> T callJson(DataHandle param, Class<T> type)
<T> T callJson(DataHandle param, Class<T> type, long timeoutMs)
```

**超时语义**：`call` 在超时/目标不可达时抛 `LingoFuseTimeoutException`。**这与 `Framework.call` 不同** —— 后者返回 size=0 的 handle。

## 16.3 单向通知

```java
void notify(DataHandle param)
void sequencedNotify(DataHandle param)
```

**`notify` 不保证顺序**，`sequencedNotify` 保证同一 `(target, api)` 对内的 FIFO。

## 16.4 异步回调

```java
boolean asyncCall(DataHandle param, AsyncResultHandler handler)
<T> boolean asyncCallJson(DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)
boolean asyncSequencedCall(DataHandle param, AsyncResultHandler handler)
<T> boolean asyncSequencedCallJson(DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)
```

## 16.5 Future 风格

```java
<T> CallFuture<T> callFuture(DataHandle param, Class<T> type)
<T> CallFuture<T> callFuture(DataHandle param, Class<T> type, long timeoutMs)
<T> CallFuture<T> sequencedCallFuture(DataHandle param, Class<T> type)
<T> CallFuture<T> sequencedCallFuture(DataHandle param, Class<T> type, long timeoutMs)
```

## 16.6 值语义

```java
Target a = new AppTarget("X");
Target b = new AppTarget("X");
assert a.equals(b);
assert a.hashCode() == b.hashCode();

Map<Target, Integer> map = new HashMap<>();
map.put(a, 1);
assert map.get(b) == 1;
```

**不同类型不相等**：`AppTarget("X")` 与 `P2PNameTarget("X")` 不相等。

---

# 第 17 章 — `Options`

16 对类型化快捷方法。**所有选项都是进程级全局的，不跨 `shutdown()` 持久化**。

## 17.1 认证

| Setter | Getter |
|--------|--------|
| `setPassword(String)` | `getPassword()` → 永远返回 `'********'` |

**密码用固定掩码返回**，真实值不通过 API 暴露。

## 17.2 日志与诊断

| Setter | Getter | 类型 |
|--------|--------|------|
| `setDebug(String)` | `getDebug()` → 占位符 | 只写 |
| `setQuiet(boolean)` | `getQuiet()` | boolean |
| `setShowThreadId(boolean)` | `getShowThreadId()` | boolean |
| `setConsoleOutput(boolean)` | `getConsoleOutput()` | boolean |

## 17.3 连接就绪

| Setter | Getter | 类型 |
|--------|--------|------|
| `setOverlapConnection(boolean)` | `getOverlapConnection()` | boolean |
| `setWaitConnectionReadyOk(boolean)` | `getWaitConnectionReadyOk()` | boolean |
| `setWaitConnectionTimeout(long)` | `getWaitConnectionTimeout()` | long (ms) |

**`Overlap_Connection` 必须在 `prepareClient` 之前设置**。

## 17.4 IPC

| Setter | Getter |
|--------|--------|
| `setIpcServThreadCount(int)` | `getIpcServThreadCount()` |
| `setIpcServMaxQueueLength(int)` | `getIpcServMaxQueueLength()` |
| `setIpcServMaxMsgSize(int)` | `getIpcServMaxMsgSize()` |

**必须在 IPC 服务启动之前设置**。

## 17.5 序列化通知

| Setter | Getter |
|--------|--------|
| `setFixedSequencedTime(long)` | `getFixedSequencedTime()` |

## 17.6 P2P 组名

| Setter | Getter |
|--------|--------|
| `setP2pName(String)` | `getP2pName()` |

**`Options.getP2pName()` 读本进程的配置**，与 `DataHandle.getP2pName()`（读发送方身份）不同。

## 17.7 数据句柄池

| Setter | Getter |
|--------|--------|
| `setDataHandleIdleTimeout(long)` | `getDataHandleIdleTimeout()` |
| `setDataHandlePoolScanInterval(long)` | `getDataHandlePoolScanInterval()` |

**设 `0` 或负数可以禁用对应机制**。

## 17.8 命令刷新

| Setter | Getter |
|--------|--------|
| `setNoReponseCmdNullFlushThreshold(int)` | `getNoReponseCmdNullFlushThreshold()` |

**注意历史拼写 `Reponse`**（少了一个 s），是刻意的。

## 17.9 关键语义

- **布尔值在 wire 上用 `"True"` / `"False"`**（Pascal 约定）。Java 侧签名仍然是 `boolean`。
- **未知选项静默忽略**（无异常）。
- **未设置过的选项返回 0 / false / `""`**。
- **不跨 `Framework.shutdown()` 持久化**。

---

# 第 18 章 — `P2PRegistry`

**进程级 P2P 命名空间注册**，独立于任何 App。

## 18.1 与 `AppHandle` 的区别

| 维度 | `AppHandle.registerCall` | `P2PRegistry.registerCall` |
|------|-------------------------|---------------------------|
| **所有权** | 属于 `TLF_App` | 属于**进程本身** |
| **可达方式** | App 名寻址 + UID 寻址 | **仅** UID 寻址 + P2PName 寻址 |
| **生命周期** | 随 `AppHandle.close()` 结束 | 直到进程退出 |
| **命名空间** | 与 P2P 独立，同名不冲突 | 与 App 独立，同名不冲突 |

**两者可以共存**：同一个名字可以同时存在于两个命名空间。

## 18.2 注册

```java
P2PRegistry.registerCall("whoami", "echo caller identity",
    (in, out) -> {
        byte[] uid = in.getP2pUid();
        String name = in.getP2pName();
        LfIo.writeJson(out, Map.of(
                "uid_hex", toHex(uid),
                "p2p_name", name));
    });

P2PRegistry.registerNotify("log", "consume and discard", in -> {
    // ...
});
```

**重载**：带 description 和带空 description 两个版本。

## 18.3 注销

```java
boolean ok = P2PRegistry.unregister("whoami");
```

**返回 `boolean`**：`true` 表示名字存在且已移除。

## 18.4 行为

- **重复注册抛 `LingoFuseRegistrationException`**，`getNamespace()` 返回 `NAMESPACE_P2P`。
- **注册可以发生在 `prepareDone()` 之前或之后**。
- **注销只移除名字**：不再接受新调用，但已在飞行中的回调不会被打断。

## 18.5 典型用途

- **健康探针**：`ping` / `whoami`。
- **能力发现**：`get_capabilities`。
- **全局工具**：`current_time` / `random_uuid`。

**这些 API 不属于任何 App**，任何 client 都可以按组名或 UID 调用。

---

# 第 19 章 — `NetworkEvents`

进程级全局 connect / disconnect 事件。

## 19.1 语义

- **Connect**：Client 第一次收到服务 API-info 广播时触发。**不是 TCP 握手**。每次连接生命周期触发一次，重连后再次触发。
- **Disconnect**：物理链路丢失时触发。自动重连**不会**再触发 Disconnect。

## 19.2 安装

```java
NetworkEvents.setNetworkEvent(
    addr -> System.out.println("[+] Connected: " + addr),
    addr -> System.out.println("[-] Disconnected: " + addr)
);
```

或者 OOP 风格：

```java
class MyListener extends NetworkEvents.NetworkEventListener {
    @Override
    public void onConnect(String addr) { /* ... */ }
    @Override
    public void onDisconnect(String addr) { /* ... */ }
}

NetworkEvents.setNetworkEventListener(new MyListener());
```

## 19.3 清除

```java
NetworkEvents.clear();
```

**安全可多次调用**。

## 19.4 线程契约

**回调在 native worker 线程上执行**。`addr` 是 Python `str`（已从 UTF-8 解码），可以安全保留。

**不要在回调内阻塞**。

## 19.5 替换语义

**`setNetworkEvent` 是 REPLACE，不是 PATCH**：

```java
setNetworkEvent(cb1, null);         // 安装 cb1，无 disconnect
setNetworkEvent(null, cb2);         // cb1 被移除，仅 cb2 生效
```

要同时安装两个，**一次调用**传入：

```java
setNetworkEvent(cb1, cb2);
```

---

# 第 20 章 — `LingoFuseStatus`

状态队列 + 健康检查。

## 20.1 状态队列

| 方法 | 说明 |
|------|------|
| `getStatusCount()` | 待处理日志数 |
| `getStatus()` | 弹出下一条 |
| `drainStatus()` / `drainStatus(int)` | 批量弹出 |
| `postStatus(String)` | 注入日志 |

**队列容量 1000**；满了丢弃最旧的。

**依赖模拟主线程**：`prepareDone` 之前队列可能为空或陈旧。

## 20.2 健康检查

| 方法 | 说明 |
|------|------|
| `checkMainThread()` | 主线程是否运行 |
| `checkApp(String)` | App 是否可见 |
| `checkApi(String, String)` | API 是否可见 |
| `checkUid(byte[])` | UID 是否可见 |
| `checkUidApi(byte[], String)` | UID 的 API 是否可见 |
| `checkP2pName(String)` | P2P 组是否可见 |
| `checkP2pNameApi(String, String)` | P2P 组的 API 是否可见 |

**所有 check 基于本地缓存**，广播延迟约 3 秒。**用于探测，不用于决策**。

**推荐的重试模式**：

```java
for (int i = 0; i < 30; i++) {
    if (LingoFuseStatus.checkApi("Target", "api")) break;
    Thread.sleep(200);
}
```

---

# 第 21 章 — 异常体系

## 21.1 层次

```
RuntimeException
  └── LingoFuseException
        ├── LingoFuseIoException
        ├── LingoFuseObjectDisposedException
        ├── LingoFuseTimeoutException
        └── LingoFuseRegistrationException
```

## 21.2 每个异常

| 类型 | 触发场景 | 携带信息 |
|------|---------|---------|
| `LingoFuseException` | 基类 | — |
| `LingoFuseIoException` | 字节级 I/O 失败（短读/短写） | `getOperation()` |
| `LingoFuseObjectDisposedException` | 已关闭对象上的操作 | `getObjectName()` |
| `LingoFuseTimeoutException` | 同步或异步调用超时 | `getTimeoutMs()` |
| `LingoFuseRegistrationException` | API 注册失败 | `getApiName()` / `getNamespace()` |

## 21.3 捕获策略

**统一入口**：

```java
try {
    // ...
} catch (LingoFuseException e) {
    if (e instanceof LingoFuseTimeoutException te) {
        log.warn("timed out after {} ms", te.getTimeoutMs());
    } else if (e instanceof LingoFuseRegistrationException re) {
        log.warn("registration conflict: {} in {}",
                 re.getApiName(), re.getNamespace());
    } else {
        log.error("lingofuse error", e);
    }
}
```

## 21.4 异步回调的异常

**异步回调不抛异常**。所有错误通过 `AsyncResult.error()` 或 `CallFuture` 的异常传递。

```java
Framework.asyncCallJson("App", req, Person.class, (person, error) -> {
    if (error != null) {
        // 这里处理所有错误：dispatch 失败、超时、反序列化失败
        log.warn("async failed", error);
        return;
    }
    // 成功路径
});
```

---

# 第 22 章 — 服务端模式

## 22.1 标准服务端骨架

```java
public final class MyService {
    private static final String ENDPOINT = "ipc:my_service";
    private static final String APP_NAME = "MyService";
    private static final AtomicBoolean CLEANED = new AtomicBoolean();
    private static volatile boolean started = false;

    static {
        Runtime.getRuntime().addShutdownHook(
                new Thread(MyService::cleanupOnce, "svc-shutdown"));
    }

    private static void cleanupOnce() {
        if (!CLEANED.compareAndSet(false, true)) return;
        try { NetworkEvents.clear(); } catch (Throwable ignored) {}
        try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
        try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
    }

    public static void main(String[] args) throws Exception {
        AppHandle app = new AppHandle(APP_NAME, "my service");

        app.registerCall("ping", "health check",
                (in, out) -> out.writeString("pong"));

        app.registerCall("add", "add two int32",
                (in, out) -> out.writeInt32(in.readInt32() + in.readInt32()));

        app.registerNotify("log", "one-way log",
                in -> System.out.println("log: " + in.readString()));

        Framework.setOption("Wait_Connection_ReadyOk", "True");
        Framework.setOption("Overlap_Connection", "True");
        Framework.resetPrepare();
        Framework.prepareService(ENDPOINT, ENDPOINT);
        Framework.prepareClient(ENDPOINT, app);

        if (Framework.prepareDone() != 1
                && !LingoFuseStatus.checkMainThread()) {
            throw new IllegalStateException("startup failed");
        }
        started = true;

        System.out.println("Ready. Press Enter to stop.");
        System.in.read();

        app.close();
        cleanupOnce();
    }
}
```

## 22.2 关键点

1. **App 名唯一**：在整个 mesh 中必须唯一。
2. **先注册 API，再 `prepareClient`**：否则 `Init_App_Info` 广播携带空 API 列表。
3. **shutdown hook 保证清理**：即使 `System.exit()` 也能清理。
4. **异常隔离**：回调里抛异常会被吞掉，但要 try/catch 加日志。

## 22.3 多地址监听

```java
Framework.resetPrepare();
Framework.prepareService("0.0.0.0:9898", "192.168.1.5:9898");
Framework.prepareService("ipc:local_svc", "ipc:local_svc");
Framework.prepareClient("0.0.0.0:9898", app);
Framework.prepareClient("ipc:local_svc", app);
Framework.prepareDone();
```

**注意**：`Overlap_Connection=True` 时每个 `prepareClient` 创建独立 tunnel。默认 `False` 时，同一地址只能有一个 client。

---

# 第 23 章 — 客户端模式

## 23.1 标准客户端骨架

```java
public final class MyClient {
    private static final String ENDPOINT = "ipc:my_service";
    private static final AtomicBoolean CLEANED = new AtomicBoolean();
    private static volatile boolean started = false;

    static {
        Runtime.getRuntime().addShutdownHook(
                new Thread(MyClient::cleanupOnce, "cli-shutdown"));
    }

    private static void cleanupOnce() {
        if (!CLEANED.compareAndSet(false, true)) return;
        try { NetworkEvents.clear(); } catch (Throwable ignored) {}
        try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
        try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
    }

    public static void main(String[] args) {
        try {
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.resetPrepare();
            Framework.prepareClient(ENDPOINT, null);

            if (Framework.prepareDone() != 1
                    && !LingoFuseStatus.checkMainThread()) {
                throw new IllegalStateException("startup failed");
            }
            started = true;

            // 等待目标 App 可见
            waitFor("MyService", "ping", 10_000);

            // 同步调用
            try (DataHandle req = new DataHandle("add")) {
                req.writeInt32(5);
                req.writeInt32(7);
                try (DataHandle resp = Framework.call(
                        "MyService", req, 3000)) {
                    if (resp.size() == 0) {
                        System.err.println("call failed");
                    } else {
                        System.out.println("5 + 7 = " + resp.readInt32());
                    }
                }
            }

            // 异步调用
            try (DataHandle req = new DataHandle("ping")) {
                req.writeString("");
                Framework.asyncCall("MyService", req,
                        (result, error) -> {
                            if (error != null) {
                                System.err.println("async failed: " + error);
                            } else {
                                System.out.println("async got: "
                                        + result.readString());
                            }
                        });
            }

            Thread.sleep(2000);

        } catch (Throwable t) {
            t.printStackTrace(System.err);
        } finally {
            cleanupOnce();
        }
    }

    private static void waitFor(String app, String api, long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (LingoFuseStatus.checkApi(app, api)) return;
            try { Thread.sleep(200); } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }
}
```

## 23.2 客户端重试模式

```java
public static Optional<DataHandle> callWithRetry(
        String app, DataHandle param, int maxRetries) {
    for (int i = 0; i < maxRetries; i++) {
        try {
            DataHandle resp = Framework.call(app, param, 3000);
            if (resp.size() > 0) return Optional.of(resp);
            resp.close();
        } catch (LingoFuseException e) {
            // 记录日志
        }
        try {
            Thread.sleep(200L * (i + 1));  // 指数退避
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            return Optional.empty();
        }
    }
    return Optional.empty();
}
```

**注意**：如果服务端**非幂等**，重试会导致副作用翻倍。必须用**幂等键**（见第 25 章）。

---

# 第 24 章 — Worker 池模式

**场景**：一组同质 Worker，处理无状态的计算任务。用 P2PName 寻址让服务端做负载均衡。

## 24.1 Worker 侧

```java
public final class ComputeWorker {
    private static final String ENDPOINT = "ipc:compute_grid";
    private static final String APP_NAME = "compute_worker";

    public static void main(String[] args) throws Exception {
        // 1. 声明所属组（每个 Worker 都执行）
        Options.setP2pName("compute_workers");

        AppHandle app = new AppHandle(APP_NAME, "compute worker");

        app.registerCall("exp", "compute base^exponent",
                (in, out) -> {
                    var req = LfIo.readJson(in, Map.class);
                    double base = ((Number) req.get("base")).doubleValue();
                    double exponent = ((Number) req.get("exponent")).doubleValue();
                    LfIo.writeJson(out, Map.of("result", Math.pow(base, exponent)));
                });

        Framework.setOption("Wait_Connection_ReadyOk", "True");
        Framework.resetPrepare();
        Framework.prepareClient(ENDPOINT, app);
        Framework.prepareDone();

        System.out.println("Worker ready.");
        System.in.read();
    }
}
```

**部署**：跑 N 个 Worker 实例，都连同一个 ENDPOINT，都 `setP2pName("compute_workers")`。

## 24.2 Caller 侧

```java
P2PNameTarget target = new P2PNameTarget("compute_workers");

for (int i = 0; i < 100; i++) {
    try (DataHandle req = new DataHandle("exp")) {
        LfIo.writeJson(req, Map.of("base", 2.0, "exponent", (double) i));
        try (DataHandle resp = target.call(req, 5000)) {
            var result = LfIo.readJson(resp, Map.class);
            System.out.println("2^" + i + " = " + result.get("result"));
        }
    }
}
```

**观察**：N 个 Worker 会均分这 100 个请求。

## 24.3 负载均衡策略

服务端 dispatcher 有两种策略：

1. **轮询（Cycle_Anchor）**：选择 anchor 最小的目标，然后推进该目标的 anchor。
2. **粘滞（FixedSequenced）**：同一目标保持一段时间（默认 20 秒），由 `Fixed_Sequenced_Time` 控制。

```java
Options.setFixedSequencedTime(5000);  // 缩短粘滞窗口到 5 秒
```

---

# 第 25 章 — 身份感知与授权

## 25.1 whoami 模式

**注册一个 whoami API，让任何 caller 学习自己的 UID**：

```java
app.registerCall("whoami", "echo caller identity", (in, out) -> {
    byte[] uid = in.getP2pUid();
    String name = in.getP2pName();
    LfIo.writeJson(out, Map.of(
            "uid_hex", toHex(uid),
            "p2p_name", name));
});

private static String toHex(byte[] bytes) {
    StringBuilder sb = new StringBuilder(bytes.length * 2);
    for (byte b : bytes) {
        sb.append(String.format("%02x", b));
    }
    return sb.toString();
}
```

## 25.2 客户端的 UID 探测

```java
public class UIDProbe {
    private volatile byte[] myUid;
    private volatile String myP2pName;

    public void refresh(UIDTarget target) {
        try (DataHandle req = new DataHandle("whoami")) {
            try (DataHandle resp = target.call(req, 3000)) {
                var me = LfIo.readJson(resp, Map.class);
                this.myUid = hexToBytes((String) me.get("uid_hex"));
                this.myP2pName = (String) me.get("p2p_name");
            }
        }
    }

    public byte[] uid() { return myUid; }
    public String p2pName() { return myP2pName; }
}
```

**关键**：UID 会随重连变化，重连后必须重新探测。

## 25.3 授权模式

**服务端基于 UID 白名单控制访问**：

```java
private static final Set<String> ALLOWED_UIDS = Set.of(
        "aabbccdd...", "11223344..."
);

app.registerCall("admin_op", "privileged operation", (in, out) -> {
    String callerUidHex = toHex(in.getP2pUid());
    if (!ALLOWED_UIDS.contains(callerUidHex)) {
        LfIo.writeJson(out, Map.of("error", "unauthorized"));
        return;
    }
    // 执行特权操作
    LfIo.writeJson(out, Map.of("result", "ok"));
});
```

## 25.4 幂等性模式

**服务端记录 request_id，重复请求返回相同响应**：

```java
private static final Map<String, String> IDEMPOTENCY_CACHE = new ConcurrentHashMap<>();

app.registerCall("payment", "process payment", (in, out) -> {
    var req = LfIo.readJson(in, Map.class);
    String requestId = (String) req.get("request_id");

    String cached = IDEMPOTENCY_CACHE.get(requestId);
    if (cached != null) {
        out.writeString(cached);
        return;
    }

    String result = doPayment(req);
    IDEMPOTENCY_CACHE.put(requestId, result);
    out.writeString(result);
});
```

**客户端每次生成新的 request_id**：

```java
String requestId = UUID.randomUUID().toString();
try (DataHandle req = new DataHandle("payment")) {
    LfIo.writeJson(req, Map.of(
            "request_id", requestId,
            "amount", 100,
            "from", "A",
            "to", "B"));
    try (DataHandle resp = Framework.call("Payment", req, 10000)) {
        // ...
    }
}
```

**注意**：`IDEMPOTENCY_CACHE` 需要定期清理，或用 LRU。

---

# 第 26 章 — 跨语言集成

## 26.1 CrossDemo 三件套

LingoFuse 的跨语言集成用 `CrossService` / `CrossNode` / `CrossCall` 三件套验证：

- **`CrossService`**：信标（协调器）。启动 IPC 服务端点 `ipc:cross`。
- **`CrossNode`**：Worker。注册 `add` / `inv_seri` API。
- **`CrossCall`**：负载测试客户端。32 线程 × 10 秒，随机调用 `add` / `inv_seri`。

**跑起来**（三个终端）：

```bash
# 终端 1
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossService

# 终端 2（等终端 1 打印 "IPC service 'ipc:cross' is running"）
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossNode

# 终端 3（等终端 2 打印 "[Node] Online"）
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossCall
```

**预期**：终端 3 在 10 秒后打印统计，成功率 100%。

## 26.2 跨语言互通验证（Java ↔ C#）

**Java 客户端 → C# 服务端**：

```bash
# 终端 A（C# 侧）
cd path\to\LingoFuse\csharp
dotnet run --project crossService
dotnet run --project CrossNode

# 终端 B（Java 侧）
cd path\to\LingoFuse\java
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossCall
```

**预期**：Java 客户端调用 C# 服务端的 `add` / `inv_seri`，**字节完全匹配**。

**反向也成立**：Java `CrossNode` 可以被 C# / Python / C++ / JS 的 `CrossCall` 调用。

## 26.3 关键：wire 契约一致性

跨语言互通的前提是**两端对 wire 协议的理解完全一致**。第 7 章列出了所有**跨语言不变量**。任何语言绑定只要遵守这些不变量，就能与其他语言互通。

**Java 绑定中所有"看起来像优化"的机制**（`ReentrantReadWriteLock`、`ArenaReaper`、`AsyncBridge`、JVM shutdown hook 等）**全部是 Java 私有的**，不侵入 wire。这已经在 Java 绑定的所有 Javadoc 中显式标注。

## 26.4 数据类型对应表

| 类型 | Java | C# | Python | C++ | Pascal | JS |
|------|------|-----|--------|-----|--------|-----|
| int8 | `byte` | `sbyte` | `int` | `int8_t` | `ShortInt` | `number` |
| uint8 | `int` (0..255) | `byte` | `int` | `uint8_t` | `Byte` | `number` |
| int16 | `short` | `short` | `int` | `int16_t` | `SmallInt` | `number` |
| uint16 | `int` | `ushort` | `int` | `uint16_t` | `Word` | `number` |
| int32 | `int` | `int` | `int` | `int32_t` | `Integer` | `number` |
| uint32 | `long` | `uint` | `int` | `uint32_t` | `Cardinal` | `number` |
| int64 | `long` | `long` | `int` | `int64_t` | `Int64` | `bigint` |
| uint64 | `long` | `ulong` | `int` | `uint64_t` | `QWord` | `bigint` |
| float | `float` | `float` | `float` | `float` | `Single` | `number` |
| double | `double` | `double` | `float` | `double` | `Double` | `number` |
| string | `String` | `string` | `str` | `std::string` | `string` | `string` |
| JSON | `JsonNode` / POJO | `JsonNode` | `dict` / `list` | `nlohmann::json` | `TDFE` | `object` |
| UID | `byte[32]` | `byte[32]` | `bytes` | `std::array<uint8_t,32>` | `TUID` | `Buffer(32)` |

---

# 第 27 章 — 生命周期与优雅关闭

## 27.1 清理顺序（严格）

```
1. NetworkEvents.clear()            清空全局网络事件回调
2. Framework.exitMainThread()       停止模拟主线程（同时刷新 handle pool）
3. AppHandle.close()                释放应用（两阶段销毁的第一阶段）
4. Framework.shutdown()             卸载库（两阶段销毁的第二阶段）
```

**任何一步跳过都会留下悬空指针**。

## 27.2 用 shutdown hook 保证清理

```java
public final class MyApp {
    private static final AtomicBoolean CLEANED = new AtomicBoolean();
    private static volatile boolean started = false;
    private static volatile AppHandle app = null;

    static {
        Runtime.getRuntime().addShutdownHook(
                new Thread(MyApp::cleanupOnce, "lf-shutdown"));
    }

    private static void cleanupOnce() {
        if (!CLEANED.compareAndSet(false, true)) {
            return;
        }
        try { NetworkEvents.clear(); } catch (Throwable ignored) {}
        try { if (started) Framework.exitMainThread(); } catch (Throwable ignored) {}
        try { if (app != null) app.close(); } catch (Throwable ignored) {}
        try { if (started) Framework.shutdown(); } catch (Throwable ignored) {}
    }

    public static void main(String[] args) {
        try {
            app = new AppHandle("MyApp", "demo");
            // ... 注册和启动 ...
            started = true;

            // 主逻辑
        } catch (Throwable t) {
            t.printStackTrace(System.err);
        } finally {
            cleanupOnce();
        }
    }
}
```

**关键**：

- **`AtomicBoolean CLEANED`** 保证清理**恰好执行一次**。
- **shutdown hook** 保证 `System.exit()` 也能触发清理。
- **`try/finally`** 保证异常路径也能触发清理。

## 27.3 常见错误

| 错误 | 症状 |
|------|------|
| 忘记 `exitMainThread` | 进程挂起，模拟主线程不退出 |
| 忘记 `shutdown` | 库资源泄漏；进程退出时可能崩溃 |
| 先 `shutdown` 后 `app.close` | `app.close` 操作已释放的 handle，崩溃 |
| 清理后继续使用 handle | `LingoFuseObjectDisposedException` 或原生崩溃 |

## 27.4 重启框架

**`Framework.shutdown()` 之后可以重新初始化**：

```java
// 第一次运行
Framework.prepareClient("ipc:a", app1);
Framework.prepareDone();
// ... 使用 ...

// 关闭
NetworkEvents.clear();
Framework.exitMainThread();
app1.close();
Framework.shutdown();

// 第二次运行（用不同的地址）
Framework.setOption(...);   // 选项不跨 shutdown 持久化，必须重新设置
Framework.resetPrepare();
Framework.prepareClient("ipc:b", app2);   // 地址必须不同于之前
Framework.prepareDone();
```

**注意**：`prepareClient` 的地址不能与之前使用过的地址相同（除非重启进程）。

---

# 第 28 章 — 故障排查

## 28.1 环境类

| 错误 | 原因 | 修复 |
|------|------|------|
| `Cannot find module 'mvn'` | Maven 未安装或未加 PATH | 见 §2.3 |
| `release version 22 not supported` | JDK < 22 | 见 §2.2 |
| `UnsatisfiedLinkError: Failed to load LingoFuse64.dll` | 原生库不在搜索路径 | 见 §2.4 |
| `UnsatisfiedLinkError: symbol not found: LF_XXX` | 库版本与 Java 绑定不匹配 | 检查 DLL 版本 |
| `The restricted method ... has been called` | JDK 24+ 未开启 native access | 加 `--enable-native-access=ALL-UNNAMED` |

## 28.2 网络类

| 错误 | 原因 | 修复 |
|------|------|------|
| `prepareDone() 返回 0` | 已初始化过（正常行为） | 检查 `checkMainThread()` 判断是否真失败 |
| 调用立即超时 | API 注册在 `prepareClient` 之后 | 先注册，再 `prepareClient` |
| `checkApi` 返回 false | 3 秒广播延迟 | 重试 30 次 × 200ms |
| `no connection` | 客户端未连接 | 检查 `prepareClient` 返回值 |

## 28.3 异步类

| 错误 | 原因 | 修复 |
|------|------|------|
| 异步回调不触发 | dispatch 返回 false / 目标不存在 / bridge 已 shutdown | 检查返回值；检查 `AsyncBridge.stats()` |
| `LingoFuseTimeoutException` 带 0 timeoutMs | 来自异步路径（已知实现细节） | 需要 timeout 值用同步路径 |
| `abandoned()` 返回 true | 超时放弃；C 侧可能仍在飞行 | 正常；响应到达时数据会被静默丢弃 |

## 28.4 选项类

| 错误 | 原因 | 修复 |
|------|------|------|
| `Options` 设置不生效 | 拼错选项名 / 时机不对 / shutdown 后未重新设置 | 用 typed 方法；检查时机 |
| `Overlap_Connection` 不生效 | 在 `prepareClient` 之后设置 | 必须在之前设置 |

## 28.5 编码类

| 错误 | 原因 | 修复 |
|------|------|------|
| 中文 / emoji 变 `\uXXXX` | 代码绕过 `LfIo` 直接调用会 escape 的 API | 所有 JSON 载荷通过 `LfIo.writeJson` / `readJson` |

## 28.6 回调日志类

| 错误 | 原因 | 修复 |
|------|------|------|
| 回调日志挤在一行（Windows） | JVM native 线程与 Windows 控制台的交互问题 | 用单消费者队列 + 专用线程输出 |

**参考实现**（`CrossNode` / `CrossCall` 里的模式）：

```java
private static final BlockingQueue<String> LOG_QUEUE =
        new LinkedBlockingQueue<>();

static {
    Thread t = new Thread(() -> {
        try {
            while (true) {
                String line = LOG_QUEUE.take();
                System.out.println(line);
                System.out.flush();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }, "log-writer");
    t.setDaemon(true);
    t.start();
}

private static void log(String line) {
    LOG_QUEUE.offer(line);  // 回调线程只入队，不直接输出
}
```

## 28.7 完整诊断工具

```java
import lingofuse.ffi.LibraryLoader;

public class CheckEnv {
    public static void main(String[] args) {
        System.out.println("Library file name: "
                + LibraryLoader.selectPlatformFileName());
        System.out.println("Search paths:");
        for (var p : LibraryLoader.buildSearchPaths()) {
            System.out.println("  " + p);
        }

        try (var h = new lingofuse.DataHandle("probe")) {
            h.writeInt32(42);
            h.setPosition(0);
            System.out.println("Native call OK: read " + h.readInt32());
        } catch (Throwable t) {
            System.err.println("Native call failed: " + t);
        }
    }
}
```

---

# 第 29 章 — 性能特征

## 29.1 当前性能

- **单机 IPC**：~250 calls/s（32 线程并发）。
- **C# / C++ 绑定**：~1500 calls/s。
- **Python 绑定**：~200 calls/s。

**Java 绑定当前性能低于 C# / C++**。原因：

1. FFM 的 `MethodHandle.invokeWithArguments` 每次调用都要做类型适配。
2. 每次调用都创建 `Arena.ofConfined()`，分配开销显著。
3. Jackson 的 JSON 序列化相对较重。

## 29.2 性能优化方向（计划中）

| 优化 | 预期收益 |
|------|---------|
| `invokeExact` 替代 `invokeWithArguments` | 2-3x |
| `Arena` 复用 | 1.5-2x |
| JSON 序列化缓存 | 1.2-1.5x |
| **总计** | **目标 1500+ calls/s** |

## 29.3 性能监控

```java
AsyncBridge bridge = AsyncBridge.instance();
Map<String, Object> stats = bridge.stats();
System.out.println("live ops: " + stats.get("total"));
System.out.println("pending: " + stats.get("pending"));
System.out.println("released_total: " + stats.get("released_total"));
```

**关键指标**：

- `pending` 长期不降 = 有 op 卡住。
- `not_queued` 持续上升 = dispatch 系统性失败。
- `released_total` 增长速率 = op 处理吞吐。

## 29.4 提高吞吐的建议

1. **用永久 handle 做请求模板**：`DataHandle.createPermanent` 一次创建，多次使用。
2. **用异步 API 而非同步**：`callFuture` 不阻塞调用线程。
3. **批量 Notify**：一次 `notify` 发送一条；高频通知考虑合并。
4. **合理的超时**：默认 3 秒对局域网太长，可以降到 1 秒。
5. **选择寻址模式**：
   - App 名（本地优先）：最快。
   - P2PName：多一次服务端转发。
   - UID：与 App 名一致。

---

# 第 30 章 — 已知限制

| 限制 | 说明 | 解决方案 |
|------|------|---------|
| **JDK 22+ 必需** | 不支持 8 / 11 / 17 / 21 | 升级 JDK |
| **仅 64 位** | 不支持 32 位平台 | 用 64 位 JVM |
| **性能未优化** | ~250 calls/s | 见第 29 章 |
| **无 Java 模块化** | 未提供 `module-info.java` | 用 `--enable-native-access=ALL-UNNAMED` |
| **无高级接口** | 目前只有底层 API，无 `LingoFuseApp` / `LingoFuseClient` | 用 `AppHandle` + `Framework` 组合 |
| **无 SLF4J 集成** | 回调错误默认写 stderr | 安装 `setCallbackErrorHandler` |
| **异步无超时取消** | C 侧请求不会被取消 | 用高层的放弃 / 重试策略 |
| **无 back-pressure** | 异步调用无流控 | 应用层自己控制并发 |
| **P2PName 路由不做本地优先** | 即使调用方在组内也会转发 | 接受这一设计 |

---

# 附录 A — 完整 API 索引

## A.1 C ABI 导出（59 个）

**Data handle (12)**：`LF_CreateData`、`LF_CreateData_Permanent`、`LF_FreeData`、`LF_GetBuffer`、`LF_WriteBuffer`、`LF_ReadBuffer`、`LF_GetPos`、`LF_SetPos`、`LF_GetSize`、`LF_SetSize`、`LF_Get_P2P_UID`、`LF_Get_P2P_Name`

**App handle (5)**：`LF_CreateApp`、`LF_FreeApp`、`LF_Generate_AppName`、`LF_Get_AppName`、`LF_BindApp`

**Registration, app-bound (3)**：`LF_RegisterCall`、`LF_RegisterNotify`、`LF_Unregister`

**Registration, process-wide P2P (3)**：`LF_Register_P2P_Call`、`LF_Register_P2P_Notify`、`LF_Unregister_P2P`

**Local execution (2)**：`LF_LocalCall`、`LF_LocalNotify`

**Network preparation (5)**：`LF_PrepareService`、`LF_PrepareClient`、`LF_ResetPrepare`、`LF_PrepareDone`、`LF_ExitMainThread`

**Remote invocation, app-name (5)**：`LF_Call`、`LF_Async_Call`、`LF_Async_Sequenced_Call`、`LF_Notify`、`LF_Sequenced_Notify`

**Remote invocation, UID (5)**：`LF_UID_Call`、`LF_UID_Async_Call`、`LF_UID_Async_Sequenced_Call`、`LF_UID_Notify`、`LF_UID_Sequenced_Notify`

**Remote invocation, P2PName (5)**：`LF_P2PNAME_Call`、`LF_P2PNAME_Async_Call`、`LF_P2PNAME_Async_Sequenced_Call`、`LF_P2PNAME_Notify`、`LF_P2PNAME_Sequenced_Notify`

**Queries (7)**：`LF_CheckMainThread`、`LF_CheckApp`、`LF_CheckApi`、`LF_Check_UID`、`LF_Check_UID_Api`、`LF_Check_P2PNAME`、`LF_Check_P2PNAME_Api`

**Options (2)**：`LF_SetOption`、`LF_GetOption`

**Status (3)**：`LF_GetStatusCount`、`LF_GetStatus`、`LF_PostStatus`

**Network events (1)**：`LF_Set_Network_Event`

**Shutdown (1)**：`LF_Shutdown`

## A.2 Java 侧类型速查

| 类型 | 用途 |
|------|------|
| `DataHandle` | RAII 数据句柄 |
| `AppHandle` | RAII 应用句柄 |
| `Framework` | 进程级门面 |
| `LfIo` | 统一 JSON / 字符串 I/O |
| `Options` | 16 对类型化选项 |
| `P2PRegistry` | 进程级 P2P 注册 |
| `NetworkEvents` | 全局网络事件 |
| `LingoFuseStatus` | 状态队列 + 健康检查 |
| `address.Target` / `AppTarget` / `UIDTarget` / `P2PNameTarget` | 三寻址模式 |
| `async.AsyncBridge` / `AsyncOp` / `AsyncSupport` / `CallFuture` | 异步子系统 |
| `errors.LingoFuseException` 等 | 5 个异常类型 |

---

# 附录 B — Wire 协议字节级示例

## B.1 Call 请求完整字节

**Java 侧**：

```java
try (DataHandle req = new DataHandle("add")) {
    req.writeInt32(5);
    req.writeInt32(7);
    Framework.call("Calculator", req, 3000);
}
```

**Wire 上发送**：

```
[4 字节长度 LE = 0x0A = 10]
[API 名 "add" UTF-8 + NUL: 61 64 64 00]
[8 字节缓冲区大小 LE = 8]
[缓冲区内容: 05 00 00 00 07 00 00 00]
```

**服务端收到的 `input` handle**：

- API 名：`"add"`
- 缓冲区：8 字节
- 光标在 0
- `readInt32()` → 5，光标移到 4
- `readInt32()` → 7，光标移到 8

## B.2 Call 响应完整字节

**服务端**：

```java
output.writeInt32(12);
```

**Wire 上返回**：

```
[4 字节长度 LE]
[API 名 UTF-8 + NUL]
[8 字节缓冲区大小 LE = 4]
[缓冲区内容: 0C 00 00 00]
```

**客户端**：

- `response.size()` → 4
- `response.readInt32()` → 12

## B.3 JSON payload 示例

**Java 侧**：

```java
LfIo.writeJson(hnd, Map.of("name", "张三", "age", 30));
```

**Wire 字节**：

```
7B 22 6E 61 6D 65 22 3A 22 E5 BC A0 E4 B8 89 22 2C
22 61 67 65 22 3A 33 30 7D 00
```

**分解**：

- `7B` → `{`
- `22 6E 61 6D 65 22` → `"name"`
- `3A` → `:`
- `22` → `"`
- `E5 BC A0 E4 B8 89` → `张三`（UTF-8 字面量，**不是** `\u5F20\u4E09`）
- `22 2C` → `",`
- `22 61 67 65 22` → `"age"`
- `3A 33 30` → `:30`
- `7D` → `}`
- `00` → NUL

## B.4 UID wire 表示

**32 字节 UID `0102030405060708090A0B0C0D0E0F10...2021`** 在 wire 上就是：

```
01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10
11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20
21
```

**无长度前缀，无 NUL**。UID 是定长 32 字节。

---

# 附录 C — 跨语言对照

## C.1 核心类型对应

| 功能 | Java | Python | C++ | C# | Pascal | JS |
|------|------|--------|-----|----|--------|-----|
| DataHandle | `DataHandle` | `DataHandle` | `lingofuse::DataHandle` | `DataHandle` | `LF_CreateData*` | `DataHandle` |
| AppHandle | `AppHandle` | `App` | `lingofuse::App` | `AppHandle` | `LF_CreateApp` | `AppHandle` |
| JSON I/O | `LfIo` | `lf_io` | `lf_io.hpp` | `LfIo` | `LF_WriteString` | `lf.io` |
| 远程调用 (App) | `AppTarget.call` | `client.call` | `lingofuse::call` | `Framework.Call` | `LF_Call` | `framework.call` |
| 远程调用 (UID) | `UIDTarget.call` | `client.uid().call` | — | — | `LF_UID_Call` | — |
| 远程调用 (P2PName) | `P2PNameTarget.call` | `client.p2pname().call` | — | — | `LF_P2PNAME_Call` | — |
| 异步调用 | `callAsync` / `callFuture` | `call_future` | — | — | `LF_Async_Call` | — |
| 进程级 P2P | `P2PRegistry` | `register_p2p_call` | — | — | `LF_Register_P2P_Call` | — |
| 类型化选项 | `Options` | `set_opt_*` / `get_opt_*` | — | — | `LF_Set_Opt_*` | — |
| 永久句柄 | `createPermanent` | `create_permanent` | `createPermanent` | `CreatePermanent` | `LF_CreateData_Permanent` | `createPermanent` |
| Side data | `getP2pUid` / `getP2pName` | `get_p2p_uid` / `get_p2p_name` | — | — | `LF_Get_P2P_UID` | — |

## C.2 Wire 协议三层契约

**Layer 1 — 字节序与字符串帧**：

- 整数：**小端序**（所有语言）
- 字符串：**UTF-8 + NUL**
- 定长字段（UID）：**32 字节裸数组，无长度前缀**

**Layer 2 — JSON 序列化**：

- **紧凑**：无缩进、无换行
- **字面 UTF-8**：无 `\uXXXX` 转义
- **策略统一**：所有语言用同一套 JSON 库配置

**Layer 3 — 调用语义**：

- **Call**：请求-响应，同步阻塞
- **Notify**：单向通知，不保证顺序
- **Sequenced_Notify**：单向通知，同一 `(target, api)` 对 FIFO
- **Call 超时**：返回 **size=0 的 handle**，非 NULL
- **异步回调**：在 native worker 线程上执行

## C.3 跨语言互通检查清单

当两个不同语言的绑定需要互通时，逐项验证：

- [ ] 整数编码一致（小端序）
- [ ] 字符串帧一致（UTF-8 + NUL）
- [ ] UID 格式一致（32 字节裸数组）
- [ ] JSON 序列化一致（紧凑、无 `\uXXXX`）
- [ ] Call 超时语义一致（size=0 而非 NULL）
- [ ] 异步回调的所有权规则一致（framework 拥有 Result_）
- [ ] Side data 的注入位置一致（载荷头部）
- [ ] 回调线程模型一致（worker 线程）

**Java 绑定已验证所有这些点**（见 `test_lingofuse.py` 的 `TestLfIoRepairPaths` 和 `test_lingofuse.cpp` 的 `jsonWireBytesMatchContract`）。

## C.4 Java 私有机制清单（不侵入 wire）

以下 Java 机制**全部是 Java 私有的**，不改变 wire 上的任何字节：

| 机制 | 作用域 | 是否侵入 wire |
|------|--------|:------------:|
| `ReentrantReadWriteLock` | 单 handle 读写串行化 | ❌ |
| `ArenaReaper` | stub native 内存延迟释放 | ❌ |
| `AsyncBridge` / `AsyncOp` | 异步状态机 | ❌ |
| `CallFuture` / `abandoned()` | Future 语义 | ❌ |
| `reportCallbackError` 的 stderr sink | 本地日志 | ❌ |
| `MAX_C_STRING_LENGTH = 1MB` | 本地读取上界 | ❌ |
| UID 缓冲区 close 前清零 | 本地内存卫生 | ❌ |
| JVM shutdown hook | 进程退出时机 | ❌ |
| `withHandle` 锁 | Java 侧同步 | ❌ |

**红线**：未来的任何 Java 私有机制修改，**不得改变 wire 上的字节序列、参数顺序、语义**。这是跨语言互通的绝对底线。

---

*文档版本：LingoFuse Java 绑定知识库*
*覆盖：59 个 C ABI 符号、145 项测试、4 个 Demo、10+ 跨语言绑定*
*本文档是所有 Java / JVM 开发者使用 LingoFuse 的权威参考。*