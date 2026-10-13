# LingoFuse Java 绑定

> **跨语言通讯地基的 Java 官方绑定。基于 JDK 22+ 的 FFM API，纯 Java 实现，无需编写任何 C 胶水代码。**

本目录是 Java / JVM 开发者使用 LingoFuse 的唯一起点。读完本 README 即可知道：

- 需要什么环境，如何一步步搭建；
- 如何运行测试、如何跑 CI；
- 如何与 Pascal / Python / C++ / C# / JavaScript 互操作；
- 日常 Java 代码中如何使用 LingoFuse 的三寻址模式、同步与异步 API；
- 每个类、每个方法的精确契约。

**文档版本：v2.0**（相对 v1.0 的增量更新，见 §16 附录）。

---

## 目录

1. [结论先说：Java 支持覆盖了什么](#1-结论先说java-支持覆盖了什么)
2. [技术选型](#2-技术选型)
3. [环境需求](#3-环境需求)
4. [环境搭建](#4-环境搭建)
5. [原生库放置](#5-原生库放置)
6. [项目结构](#6-项目结构)
7. [运行测试](#7-运行测试)
8. [运行 Demo](#8-运行-demo)
9. [CI 测试](#9-ci-测试)
10. [跨语言互操作](#10-跨语言互操作)
11. [日常用法](#11-日常用法)
12. [API 参考](#12-api-参考)
13. [故障排查](#13-故障排查)
14. [当前状态与路线图](#14-当前状态与路线图)
15. [许可证](#15-许可证)
16. [附录：v1.0 → v2.0 迁移](#16-附录v10--v20-迁移)

---

## 1. 结论先说：Java 支持覆盖了什么

| 维度 | 状态 | 说明 |
|------|:----:|------|
| **底层 FFI 绑定** | ✅ 完整 | **59 个 C ABI 导出函数**全部封装，覆盖数据句柄 / 应用句柄 / 网络准备 / 远程调用 / 诊断 / 网络事件 / 关闭 |
| **RAII 封装** | ✅ 完整 | `DataHandle` / `AppHandle` 实现 `AutoCloseable`，支持 try-with-resources |
| **统一 JSON I/O** | ✅ 完整 | `LfIo` 是唯一序列化入口，跨语言字节一致 |
| **三寻址模式** | ✅ 完整 | `AppTarget` / `UIDTarget` / `P2PNameTarget` 三个寻址目标，共享同一套 API |
| **异步子系统** | ✅ 完整 | 回调风格 + Future 风格双轨，底层由 `AsyncBridge` 统一管理生命周期 |
| **类型化选项** | ✅ 完整 | `Options` 提供 **16 对** 类型化 getter / setter，覆盖所有运行时选项 |
| **进程级 P2P 注册** | ✅ 完整 | `P2PRegistry` 注册独立于任何 App 的进程级 API |
| **side-data 访问器** | ✅ 完整 | `DataHandle.getP2pUid()` / `getP2pName()` 读取发送方身份 |
| **进程级门面** | ✅ 完整 | `Framework` 提供网络准备、远程调用、选项、应用名生成、关闭 |
| **网络事件** | ✅ 完整 | `NetworkEvents` 全局 connect / disconnect 回调 |
| **状态与健康检查** | ✅ 完整 | `LingoFuseStatus` 状态队列 + App / API / UID / P2PName 四类探活 |
| **异常层次** | ✅ 完整 | 5 个异常类型（基类 / I/O / 已关闭 / 超时 / 注册） |
| **永久句柄** | ✅ 完整 | `DataHandle.createPermanent(...)` |
| **跨语言 ABI** | ✅ 已测试 | 逐字节小端序验证，与 C++ / Pascal / Python / C# / JS 字节一致 |
| **跨语言 JSON** | ✅ 已测试 | emoji / 中文无 `\uXXXX` 转义 |
| **多进程 Demo** | ✅ 已测试 | `CrossService` / `CrossNode` / `CrossCall` 三件套 |
| **多线程并发** | ✅ 已测试 | 32 线程 × 10 秒负载测试，100% 成功 |
| **单元测试** | ✅ 完整 | **145 项**，覆盖数据句柄、应用句柄、选项、P2P 注册、三寻址、异步子系统 |
| **高级接口层** | ⏳ 计划中 | `LingoFuseApp` / `LingoFuseClient` / 注解驱动 / SLF4J 集成 |
| **性能优化** | ⏳ 计划中 | 当前 ~250 calls/s，目标 1500+ calls/s |
| **CI** | ⚠️ 无 | 目前以本地运行为准 |

**总体判断：Java 绑定已经能完成生产级的跨进程 RPC 调用，覆盖从 FFI 绑定到跨语言互操作的完整链路，并附带 145 项自动化测试和三进程 Demo。**

---

## 2. 技术选型

Java 绑定**没有**使用 JNI / JNA / JNR，而是选择了 **Project Panama 的 FFM API（Foreign Function & Memory API）**，原因如下：

| 方案 | 结论 | 理由 |
|------|:----:|------|
| **JNI** | ❌ | 需要编写 C 胶水代码，跨平台编译复杂，内存管理容易出错 |
| **JNA** | ❌ | 基于反射，性能差，不适合高频 RPC 调用 |
| **JNR** | ❌ | 社区小，维护不活跃 |
| **FFM API** | ✅ **选用** | JDK 内置、类型安全、JIT 可优化、纯 Java、JDK 22+ 正式标准 |

FFM API 在 **JDK 22 正式发布**（JEP 454）。早期版本（JDK 17–21）的 FFM 只有 preview，API 完全不同，**无法编译本项目**。

---

## 3. 环境需求

### 3.1 必需组件

| 组件 | 最低版本 | 推荐版本 | 说明 |
|------|:--------:|:--------:|------|
| **JDK** | **22** | **25 LTS** | FFM 正式标准从 22 开始；25 是当前 LTS |
| **Maven** | 3.8 | 3.9 / 3.10 | 构建与依赖管理 |
| **操作系统** | Windows 10+ / Linux / macOS | 任意 | 64 位系统 |
| **CPU 架构** | x86_64 / aarch64 | — | 32 位平台不支持 |

### 3.2 不需要的组件

- ❌ 不需要 C/C++ 编译器
- ❌ 不需要 CMake / Ninja
- ❌ 不需要 Python 或 Node.js
- ❌ 不需要 Visual Studio

Java 绑定是纯 Java 实现，只依赖 JDK 和 Maven。

### 3.3 网络需求

首次运行 `mvn test` 需要访问 Maven Central（`repo.maven.apache.org`），下载 Jackson 和 JUnit 依赖（约 15 MB）。之后走本地缓存。

---

## 4. 环境搭建

### 4.1 安装 JDK 25（推荐）

#### Windows

推荐用 `winget`，一条命令：

```powershell
winget install EclipseAdoptium.Temurin.25.JDK
```

如果 `winget` 不可用，从官网下载 msi：

👉 **https://adoptium.net/temurin/releases/?version=25&os=windows&arch=x64&package=jdk**

安装时勾选：

- ✅ **Set JAVA_HOME variable**
- ✅ **Add to PATH**

#### Linux（Ubuntu / Debian）

```bash
# 添加 Adoptium 源
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | \
    sudo gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg

echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] \
https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/adoptium.list

sudo apt update
sudo apt install temurin-25-jdk
```

#### macOS

```bash
brew install --cask temurin@25
```

#### 验证 JDK

```bash
java -version
```

预期输出：

```
openjdk version "25.x.x" 2025-...
OpenJDK Runtime Environment Temurin-25.x.x+...
OpenJDK 64-Bit Server VM Temurin-25.x.x+...
```

**如果显示的是 JDK 8 / 11 / 17 / 21，需要修正 `JAVA_HOME` 指向 JDK 22+。**

### 4.2 安装 Maven

#### Windows

```powershell
winget install Apache.Maven
```

或者从官网下载 zip：

👉 **https://maven.apache.org/download.cgi**

下载 `apache-maven-3.9.x-bin.zip`，解压到 `D:\apache-maven-3.9.x`，然后把 `D:\apache-maven-3.9.x\bin` 加入系统 `PATH`。

#### Linux / macOS

```bash
# Ubuntu / Debian
sudo apt install maven

# macOS
brew install maven

# 或者用 SDKMAN
curl -s "https://get.sdkman.io" | bash
sdk install maven
```

#### 验证 Maven

```bash
mvn -version
```

预期输出：

```
Apache Maven 3.9.x (...)
Maven home: ...
Java version: 25.x.x, vendor: Eclipse Adoptium, runtime: ...
```

**关键**：`Java version` 必须是 `22.x` 或更高。如果显示 `17.x` / `8.x`，说明 `JAVA_HOME` 未生效。

#### 修正 `JAVA_HOME`

Windows PowerShell：

```powershell
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-25.0.4.101-hotspot"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
mvn -version
```

Linux / macOS：

```bash
export JAVA_HOME=/usr/lib/jvm/temurin-25-jdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
mvn -version
```

---

## 5. 原生库放置

Java 绑定**不包含** LingoFuse 原生共享库。该库需要单独构建（从 Pascal / C++ 源码），放到操作系统加载器能找到的位置。

### 5.1 期望的文件名

| 平台 | 文件名 |
|------|--------|
| Windows 64 位 | `LingoFuse64.dll` |
| Windows 32 位 | `LingoFuse32.dll` |
| Linux / BSD | `liblingofuse.so` |
| macOS | `liblingofuse.dylib` |

### 5.2 依赖库

除了主库，还需要以下依赖同目录：

| 平台 | IPC 依赖 | 内存分配器 |
|------|----------|------------|
| Windows | `z_ipc_64.dll` | `mimalloc64.dll` |
| Linux | `libz_ipc.so` | `libmimalloc.so`（可选） |
| macOS | `libz_ipc.dylib` | `libmimalloc.dylib`（可选） |

### 5.3 搜索顺序

`LibraryLoader` 依次尝试：

1. **系统加载器路径**（Windows：`PATH`；Linux：`LD_LIBRARY_PATH`；macOS：`DYLD_LIBRARY_PATH`）
2. **`java.library.path`** 里的每个目录
3. **当前工作目录**

以上任一位置都行。

### 5.4 放置示例

#### Windows

把 `LingoFuse64.dll`、`z_ipc_64.dll`、`mimalloc64.dll` 复制到项目根目录 `D:\CoreLibrary\LingoFuse\java\`：

```powershell
Copy-Item "D:\CoreLibrary\LingoFuse\Binary\*.dll" .
```

或者把 `Binary\` 目录加入 `PATH`：

```powershell
$env:PATH += ";D:\CoreLibrary\LingoFuse\Binary"
```

#### Linux

```bash
sudo cp liblingofuse.so libz_ipc.so /usr/local/lib/
sudo ldconfig
```

或：

```bash
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/opt/lingofuse/lib"
```

#### macOS

```bash
sudo cp liblingofuse.dylib libz_ipc.dylib /usr/local/lib/
```

或：

```bash
export DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH:/opt/lingofuse/lib"
```

---

## 6. 项目结构

```
java/
├── pom.xml                                    Maven 项目配置
├── README.md                                  本文件
├── src/
│   ├── main/java/lingofuse/
│   │   ├── DataHandle.java                    RAII 数据句柄（含 side-data 访问器）
│   │   ├── AppHandle.java                     RAII 应用句柄
│   │   ├── Framework.java                     进程级门面（含 12 个异步方法）
│   │   ├── LfIo.java                          统一 JSON / 字符串 I/O
│   │   ├── Options.java                       16 对类型化选项快捷方法
│   │   ├── P2PRegistry.java                   进程级 P2P 命名空间注册
│   │   ├── NetworkEvents.java                 全局网络事件
│   │   ├── LingoFuseStatus.java               状态队列 + 健康检查（App / UID / P2PName）
│   │   ├── address/                            三寻址模式
│   │   │   ├── Target.java                    寻址抽象基类
│   │   │   ├── AppTarget.java                 App 名寻址
│   │   │   ├── UIDTarget.java                 UID 寻址
│   │   │   └── P2PNameTarget.java             P2PName 寻址
│   │   ├── async/                              异步子系统
│   │   │   ├── AsyncBridge.java               进程级单例 + 超时 / 回收调度
│   │   │   ├── AsyncOp.java                   单次异步操作状态机
│   │   │   ├── AsyncSupport.java              工厂 + one-stop helper
│   │   │   ├── CallFuture.java                CompletableFuture 子类（含 abandoned 标志）
│   │   │   ├── AsyncResultHandler.java        原始 handle 风格回调接口
│   │   │   └── TypedAsyncResultHandler.java   类型化对象风格回调接口
│   │   ├── errors/
│   │   │   ├── LingoFuseException.java        异常基类
│   │   │   ├── LingoFuseIoException.java      字节级 I/O 异常
│   │   │   ├── LingoFuseObjectDisposedException.java
│   │   │   ├── LingoFuseTimeoutException.java 超时异常
│   │   │   └── LingoFuseRegistrationException.java 注册失败异常
│   │   ├── ffi/                                FFM 层（用户不应直接调用）
│   │   │   ├── LibraryLoader.java             动态库加载
│   │   │   ├── NativeMethods.java             59 个 C ABI 函数的 MethodHandle
│   │   │   ├── NativeTypes.java               值布局 + 回调 FunctionDescriptor
│   │   │   └── NativeCall.java                MethodHandle 调用包装
│   │   └── demo/
│   │       ├── EchoDemo.java                  单进程端到端 demo
│   │       ├── LogProbe.java                  日志探针（无 LingoFuse 依赖）
│   │       └── cross/
│   │           ├── CrossService.java          信标（协调器）
│   │           ├── CrossNode.java             工作节点（暴露 ABI API）
│   │           └── CrossCall.java             32 线程负载测试客户端
│   └── test/java/lingofuse/
│       ├── DataHandleSmokeTest.java           23 项测试
│       ├── AppHandleSmokeTest.java            13 项测试
│       ├── OptionsTest.java                   22 项测试
│       ├── P2PRegistryTest.java               15 项测试
│       ├── FrameworkAsyncTest.java            12 项测试
│       ├── address/
│       │   └── TargetTest.java                28 项测试
│       ├── async/
│       │   └── AsyncSupportTest.java          32 项测试
│       └── ci/
│           └── CiTestListener.java            JUnit 5 监听器（CI 模式）
└── target/                                    编译产物（git 忽略）
```

---

## 7. 运行测试

### 7.1 一次性全量测试

```bash
cd java
mvn clean test
```

预期输出末尾：

```
[INFO] Tests run: 145, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

**145 项测试全部通过**，即环境搭建成功。

### 7.2 测试覆盖

| 测试类 | 数量 | 覆盖内容 |
|--------|:----:|----------|
| `DataHandleSmokeTest` | 23 | 库加载、句柄生命周期、原子类型往返、位置/大小、字节 I/O、字符串 NUL 帧、Unicode、小端序、JSON wire bytes |
| `AppHandleSmokeTest` | 13 | 应用生命周期、Call / Notify 注册 / 反注册、本地调用、回调异常隔离、借用句柄、回调长期存活 |
| `OptionsTest` | 22 | 16 对选项往返、掩码密码、只写 debug、未知名静默、与通用 API 互通 |
| `P2PRegistryTest` | 15 | 进程级注册 / 重复注册拒绝 / 注销 / 命名空间隔离 |
| `FrameworkAsyncTest` | 12 | `Framework` 的 4 个 App-name 异步方法端到端 + 20 并发调用 + bridge 回收 |
| `address.TargetTest` | 28 | 三寻址构造与值语义 + `AppTarget` 的 sync / async / future 全风格 |
| `async.AsyncSupportTest` | 32 | 状态机、超时、延迟回调丢弃、dispatch 失败不泄漏、工厂、诊断 |

### 7.3 运行单个测试

```bash
mvn test -Dtest=DataHandleSmokeTest
mvn test -Dtest=DataHandleSmokeTest#writeStringAppendsNul
mvn test -Dtest=lingofuse.address.TargetTest
```

### 7.4 测试工具脚本

Windows（PowerShell）：

```powershell
.\test.ps1                          # 全量测试
.\test.ps1 -Class lingofuse.OptionsTest
.\test.ps1 -Class lingofuse.DataHandleSmokeTest -Method writeStringAppendsNul
.\test.ps1 -NoClean                 # 跳过 mvn clean
```

---

## 8. 运行 Demo

### 8.1 单进程 Demo：EchoDemo

自连通的服务 + 客户端，演示完整的生命周期。

```bash
mvn -q compile
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.EchoDemo
```

预期输出：

```
=== LingoFuse Java binding - Echo demo ===

[Setup] Registered APIs 'echo' and 'add'.
[Setup] Service and client prepared on ipc:lingofuse_java_demo.
[Setup] Framework started.
[Setup] App 'EchoApp' is visible on the mesh.

--- Remote call via Framework.call() ---
  echo -> Hello, 世界!
  add(5, 7) -> 12

--- Local call via AppHandle.localCall() ---
  echo -> Local call, 你好!
  add(40, 2) -> 42

[Demo] All demonstrations completed.
[Demo] Press Enter to shut down...
```

### 8.2 多进程 Demo：cross 三件套

这是与 C++ / Pascal / Python / C# / JavaScript 的 `Cross` 系列**直接互通**的 demo。

#### 步骤

**终端 1 —— 信标**：

```bash
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossService
```

**终端 2 —— 工作节点**（等终端 1 打印 `IPC service 'ipc:cross' is running`）：

```bash
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossNode
```

**终端 3 —— 负载测试**（等终端 2 打印 `[Node] Online`）：

```bash
java --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossCall
```

#### 预期输出

终端 1：等待 Enter 键。

终端 2：每次调用打印一行：

```
[Node] add #1(348, 639) = 987
[Node] add #2(794, 65) = 859
[Node] inv_seri #1 received: [200, 16, 47, 63, "hello world", 3.14]
[Node] inv_seri #1 replied: [3.14, "hello world", 63, 47, 16, 200]
...
```

终端 3：10 秒后打印统计：

```
[Call] Load test summary
         duration          : 10.134 s
         total calls       : 2514
         success           : 2514 (100.00 %)
         failed            : 0
         add calls         : 1234
         inv_seri calls    : 1280
         throughput        : 248.09 calls/s
         success throughput: 248.09 calls/s
```

#### 运行参数

`CrossCall` 的每次调用间隔（毫秒）通过系统属性控制，默认 0：

```bash
java -Dlingofuse.crosscall.pause=1 \
     --enable-native-access=ALL-UNNAMED \
     -cp target\classes lingofuse.demo.cross.CrossCall
```

---

## 9. CI 测试

### 9.1 当前状态

Java 绑定目前**没有配置 GitHub CI**。测试以本地运行为准。这与 LingoFuse 的整体策略一致——目前只有 C++ 绑定的测试在 GitHub Actions 上跑，其他语言以本地验证为主。

### 9.2 本地 CI 脚本

在 `java/` 目录下执行：

```bash
mvn clean test
```

或者用附带的脚本，它们额外生成机器可读的报告：

```powershell
# Windows
.\run_test_ci.ps1
.\run_test_ci.ps1 -Quiet
```

```bash
# Linux / macOS
./run_test_ci.sh
```

**产物**：

| 文件 | 内容 |
|------|------|
| `test_ci_report.jsonl` | 每个测试一行 JSON |
| `test_ci_summary.txt` | 人类可读的摘要 |
| `test_ci_raw.log` | 完整 Maven 输出 |

**退出码**：

- `0`：全部通过
- 非 `0`：有失败或错误

### 9.3 未来 CI 计划

如果添加 GitHub Actions，配置会如下（伪代码）：

```yaml
name: Java Binding CI

on: [push, pull_request]

jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
        java: [22, 25]
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: ${{ matrix.java }}
      - name: Place native library
        run: |
          # 从 Binary/ 目录复制对应平台的原生库
      - name: Run tests
        run: cd java && mvn -B clean test
```

**为什么现在没有**：GitHub 的自动化 CI 有很多限制，LingoFuse 是**多语言、多平台**支持（10+ 语言 × Windows / Linux / macOS × IPC / TCP / 跨机），把所有组合塞进托管 Runner 不现实。项目策略是把测试能力交到使用者手里，本地运行得到的是**你自己硬件上的真实数据**。

---

## 10. 跨语言互操作

### 10.1 线协议契约

LingoFuse 的所有绑定共享同一套线协议：

| 元素 | 编码 |
|------|------|
| 字符串帧 | UTF-8 字节 + 单个 NUL（`0x00`） |
| 整数 | 小端序 |
| 浮点 | IEEE 754，小端序 |
| JSON 文本 | 紧凑，字面 UTF-8，无 `\uXXXX` 转义 |
| 原始字节 | 任意字节 + NUL（若用 `writeStringBytes`） |

### 10.2 与其他绑定的对应关系

| 功能 | Java | C++ | C# | Python | Pascal | JavaScript |
|------|------|-----|----|--------|--------|------------|
| 数据句柄 | `DataHandle` | `DataHandle` | `DataHandle` | `DataHandle` | `LF_CreateData*` | `DataHandle` |
| 应用句柄 | `AppHandle` | `App` | `AppHandle` | `App` | `LF_CreateApp` | `AppHandle` |
| JSON I/O | `LfIo` | `lf_io.hpp` | `LfIo` | `lf_io` | `LF_WriteString` | `lf.io` |
| 远程调用（App） | `AppTarget.call` | `lingofuse::call` | `Framework.Call` | `C4.call` | `LF_Call` | `framework.call` |
| 远程调用（UID） | `UIDTarget.call` | — | — | — | `LF_UID_Call` | — |
| 远程调用（P2PName） | `P2PNameTarget.call` | — | — | — | `LF_P2PNAME_Call` | — |
| 异步调用 | `Target.callFuture` | — | — | `call_future` | `LF_Async_Call` | — |
| 进程级 P2P 注册 | `P2PRegistry` | — | — | `register_p2p_call` | `LF_Register_P2P_Call` | — |
| 类型化选项 | `Options` | — | — | `set_opt_*` / `get_opt_*` | `LF_Set_Opt_*` | — |
| 永久句柄 | `DataHandle.createPermanent` | `DataHandle::createPermanent` | `DataHandle.CreatePermanent` | `DataHandle.create_permanent` | `LF_CreateData_Permanent` | `DataHandle.createPermanent` |
| side-data | `DataHandle.getP2pUid` / `getP2pName` | — | — | `DataHandle.get_p2p_uid` / `get_p2p_name` | `LF_Get_P2P_UID` / `LF_Get_P2P_Name` | — |

### 10.3 跨语言互操作验证

**Java 客户端 → C# 服务端**：

1. **终端 A** —— 用 C# 的 `crossService` + `CrossNode`：

   ```powershell
   cd path\to\LingoFuse\csharp
   dotnet run --project crossService
   dotnet run --project CrossNode
   ```

2. **终端 B** —— 用 Java 的 `CrossCall`：

   ```powershell
   cd path\to\LingoFuse\java
   java --enable-native-access=ALL-UNNAMED \
        -cp target\classes lingofuse.demo.cross.CrossCall
   ```

3. **预期**：Java 客户端成功调用 C# 服务端的 `add` / `inv_seri`，字节完全匹配。

**反向也成立**：Java `CrossNode` 可以被 C# / Python / C++ / JS 的 `CrossCall` 调用。

### 10.4 字节级验证

Java 绑定已经通过如下测试验证字节一致性：

| 载荷 | Java 产生的字节 | 与其它绑定一致 |
|------|-----------------|:--------------:|
| `{"a":1}` | `7B 22 61 22 3A 31 7D 00` | ✅ |
| `int32 = 0x01020304` | `04 03 02 01` | ✅ |
| `uint16 = 0xAABB` | `BB AA` | ✅ |
| `"你好"` | `E4 BD A0 E5 A5 BD 00` | ✅ |
| `"🌍"` | `F0 9F 8C 8D 00` | ✅ |

---

## 11. 日常用法

### 11.1 最小服务端

```java
import lingofuse.AppHandle;
import lingofuse.Framework;
import lingofuse.LingoFuseStatus;
import lingofuse.LfIo;
import lingofuse.Options;

public class MyServer {
    public static void main(String[] args) throws Exception {
        // 1. 创建应用，注册 API
        try (AppHandle app = new AppHandle("Calculator", "Demo calculator")) {

            app.registerCall("add", "Add two integers", (input, output) -> {
                int a = input.readInt32();
                int b = input.readInt32();
                output.writeInt32(a + b);
            });

            // 2. 准备网络
            Options.setWaitConnectionReadyOk(true);
            Options.setOverlapConnection(true);
            Framework.resetPrepare();

            Framework.prepareService("ipc:calc", "ipc:calc");
            Framework.prepareClient("ipc:calc", app);

            // 3. 启动
            if (Framework.prepareDone() != 1
                    && !LingoFuseStatus.checkMainThread()) {
                throw new IllegalStateException("Startup failed");
            }

            System.out.println("Ready. Press Enter to stop.");
            System.in.read();

            // 4. 清理（try-with-resources 会自动 close app）
            Framework.exitMainThread();
            Framework.shutdown();
        }
    }
}
```

### 11.2 最小客户端

```java
import lingofuse.DataHandle;
import lingofuse.Framework;
import lingofuse.LingoFuseStatus;
import lingofuse.Options;

public class MyClient {
    public static void main(String[] args) {
        Options.setWaitConnectionReadyOk(true);
        Framework.resetPrepare();
        Framework.prepareClient("ipc:calc", null);

        if (Framework.prepareDone() != 1) {
            System.err.println("Startup failed");
            return;
        }

        try (DataHandle request = new DataHandle("add")) {
            request.writeInt32(5);
            request.writeInt32(7);

            try (DataHandle response = Framework.call(
                    "Calculator", request, 3000L)) {

                if (response.size() == 0) {
                    System.out.println("Timeout or target not found");
                    return;
                }
                System.out.println("5 + 7 = " + response.readInt32());
            }
        }

        Framework.exitMainThread();
        Framework.shutdown();
    }
}
```

### 11.3 JSON 载荷

```java
import lingofuse.DataHandle;
import lingofuse.LfIo;

// 写 JSON
try (DataHandle request = new DataHandle("my_api")) {
    LfIo.writeJson(request, Map.of("name", "Alice", "age", 30));
    // ...
}

// 读 JSON 到 Map
try (DataHandle response = ...) {
    Map<String, Object> result = LfIo.readJson(response, Map.class);
}

// 读 JSON 到 POJO
public class Person {
    public String name;
    public int age;
}
Person p = LfIo.readJson(response, Person.class);
```

### 11.4 Notify 和 SequencedNotify

```java
// 单向通知（不保证顺序）
try (DataHandle param = new DataHandle("log")) {
    LfIo.writeJson(param, "hello");
    Framework.notify("Logger", param);
}

// 单向通知，同一 (app, api) 对内 FIFO
try (DataHandle param = new DataHandle("event")) {
    LfIo.writeJson(param, Map.of("index", 1));
    Framework.sequencedNotify("Logger", param);
}
```

### 11.5 永久句柄

用于跨整个进程生命周期持有的句柄（缓存模板、全局 registry）：

```java
// 创建
DataHandle template = DataHandle.createPermanent("my_api");
LfIo.writeJson(template, Map.of("type", "template"));

// 整个进程生命周期内反复使用
// ...

// 退出前显式释放（同步）
template.close();
```

### 11.6 网络事件监听

```java
import lingofuse.NetworkEvents;

NetworkEvents.setNetworkEvent(
    addr -> System.out.println("[+] Connected: " + addr),
    addr -> System.out.println("[-] Disconnected: " + addr)
);

// ... 运行 ...

NetworkEvents.clear();
```

或使用面向对象的监听器：

```java
class MyListener extends NetworkEvents.NetworkEventListener {
    @Override
    public void onConnect(String addr) {
        System.out.println("Connected: " + addr);
    }

    @Override
    public void onDisconnect(String addr) {
        System.out.println("Disconnected: " + addr);
    }
}

NetworkEvents.setNetworkEventListener(new MyListener());
```

### 11.7 回调错误处理

```java
import lingofuse.Framework;

Framework.setCallbackErrorHandler((source, exception) -> {
    // 你的日志管线（SLF4J / Log4j / 等）
    logger.error("[LingoFuse] {}: {}", source, exception.getMessage(), exception);
});
```

**注意**：默认情况下，回调异常会打到 stderr。安装 handler 后可以路由到你的日志框架。

### 11.8 清理顺序

**严格遵守以下顺序**：

```java
NetworkEvents.clear();          // 1. 清空网络事件
Framework.exitMainThread();     // 2. 停止主线程
app.close();                    // 3. 释放应用
Framework.shutdown();           // 4. 卸载框架
```

**用 `try/finally` 保证所有退出路径都执行**：

```java
AppHandle app = null;
boolean started = false;

try {
    app = new AppHandle("MyApp");
    // ... 准备和运行 ...
    started = true;
} finally {
    if (started) {
        try { NetworkEvents.clear(); } catch (Throwable ignored) {}
        try { Framework.exitMainThread(); } catch (Throwable ignored) {}
        try { if (app != null) app.close(); } catch (Throwable ignored) {}
        try { Framework.shutdown(); } catch (Throwable ignored) {}
    }
}
```

### 11.9 三寻址模式

LingoFuse 的 C ABI 支持三套独立的寻址键。三者在 Java 里各有对应的 Target 类，共享完全对等的 API。

#### 11.9.1 何时用哪个

| 寻址模式 | 索引键 | 路由语义 | 本地优先？ | 负载均衡？ | 典型用途 |
|---------|--------|---------|:---------:|:---------:|---------|
| **App 名** | UTF-8 字符串 | 定位到"逻辑 App" | ✅ 是 | ❌ | 固定服务 |
| **UID** | 32 字节会话标识 | 定位到"具体客户端" | ✅ 是 | ❌ | 定向到具体客户端 |
| **P2PName** | 用户自定义组名 | 定位到"组内任意成员" | ❌ 否 | ✅ 服务端 | 同质服务集群 |

#### 11.9.2 App 名寻址（最常见）

```java
import lingofuse.address.AppTarget;
import lingofuse.DataHandle;
import lingofuse.LfIo;

AppTarget target = new AppTarget("Calculator");

try (DataHandle req = new DataHandle("add")) {
    req.writeInt32(5);
    req.writeInt32(7);

    try (DataHandle resp = target.call(req, 3000)) {
        System.out.println("5 + 7 = " + resp.readInt32());
    }
}
```

#### 11.9.3 UID 寻址

```java
import lingofuse.address.UIDTarget;

// uid 是 32 字节的会话标识；构造时校验长度，做防御性拷贝
byte[] uid = acquireClientUid();
UIDTarget target = new UIDTarget(uid);

try (DataHandle req = new DataHandle("echo")) {
    LfIo.writeString(req, "hello via UID");
    try (DataHandle resp = target.call(req, 3000)) {
        System.out.println(LfIo.readString(resp));
    }
}
```

**UID 从哪里来？** 客户端每次 TunnelLink 后由服务端分配，可通过 **whoami 模式**探知：

```java
// 服务端：注册一个 whoami API
P2PRegistry.registerCall("whoami", "echo caller identity",
    (in, out) -> {
        byte[] callerUid = in.getP2pUid();     // side data
        String callerName = in.getP2pName();   // side data
        LfIo.writeJson(out, Map.of(
                "uid_hex", toHex(callerUid),
                "p2p_name", callerName));
    });

// 客户端：调用 whoami 拿到自己的 UID，缓存
Map<String, Object> me = new AppTarget("Bridge")
        .callJson(new DataHandle("whoami") {{
            // ...
        }}, Map.class);
String uidHex = (String) me.get("uid_hex");
```

**重要**：UID 会随重连变化。缓存 UID 的代码必须在重连后重新探知。

#### 11.9.4 P2PName 寻址

```java
import lingofuse.address.P2PNameTarget;
import lingofuse.Options;

// 客户端自己通过 Options 声明所属组
Options.setP2pName("worker_group");

// 调用方按组名寻址；服务端在组内做负载均衡
P2PNameTarget target = new P2PNameTarget("worker_group");

try (DataHandle req = new DataHandle("process")) {
    LfIo.writeJson(req, Map.of("task", "batch-42"));
    try (DataHandle resp = target.call(req, 5000)) {
        Map<String, Object> result = LfIo.readJson(resp, Map.class);
        System.out.println("result: " + result);
    }
}
```

**注意**：P2PName 路由**不做本地优先**。即使调用方本身就在组内，也会转发到服务端，由服务端决定目标客户端。

### 11.10 异步回调（"直接写业务"）

v2.0 最核心的设计目标：**让异步调用看起来像普通业务代码**。

```java
import lingofuse.Framework;
import lingofuse.DataHandle;
import lingofuse.LfIo;

// 一行调用 + 一块内联代码
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

**用户侧看到的东西**：

- 一个方法调用
- 一个 lambda 参数：`(T value, Throwable error) -> { ... }`
- **没有 stub、没有 Arena、没有 handle 生命周期、没有 user_data**

**框架侧自动完成的事**：创建 stub、绑定 op、注册到 `AsyncBridge`、调用 C 侧 `LF_Async_Call`、反序列化结果、释放 handle、调 lambda、注销 op。

**两种回调风格**（同一个 Target / `Framework` 都支持）：

```java
// 原始 handle 风格：用户看到 DataHandle，需要自己 copy
Framework.asyncCall("MyApp", req, (DataHandle result, Throwable error) -> {
    if (error != null) return;
    String value = LfIo.readString(result);   // 必须在回调内 copy
});

// 类型化风格（推荐）：框架反序列化后再调 lambda
Framework.asyncCallJson("MyApp", req, String.class, (String value, Throwable error) -> {
    // value 已经是 Java 对象
});
```

**回调契约**：

1. 在原生 worker 线程上执行（不是调用线程，不是主线程）
2. 不阻塞：不要在回调里做 IO、`Thread.sleep`、等锁
3. 不调阻塞型 LingoFuse 函数（`LF_Call` / `LF_LocalCall` 等，会死锁）
4. 不碰 UI：需要更新 UI 时用 `CompletableFuture` / `ExecutorService` 转发
5. 异常被吞掉：通过 `Framework.setCallbackErrorHandler` 报告

### 11.11 异步 Future（链式组合）

```java
import lingofuse.address.AppTarget;
import lingofuse.async.CallFuture;

AppTarget target = new AppTarget("MyApp");

try (DataHandle req = new DataHandle("api")) {
    LfIo.writeJson(req, Map.of("query", "..."));

    CallFuture<Person> future = target.callFuture(req, Person.class, 3000);

    // 链式组合
    future.thenAccept(person -> System.out.println("got " + person.name))
          .exceptionally(err -> {
              log.warn("failed", err);
              return null;
          });

    // 也可以阻塞等待
    Person p = future.get(5, TimeUnit.SECONDS);
}
```

**`CallFuture<T>` 是 `CompletableFuture<T>` 的子类**，额外提供：

```java
future.abandoned()   // true 表示超时放弃；C 侧请求可能仍在飞行
```

**超时语义**：

- 超时后 Future 以 `LingoFuseTimeoutException` 完成
- `abandoned()` 变为 `true`
- **C 侧请求不会被取消**；如果稍后响应到达，其数据会被静默丢弃

### 11.12 类型化选项（`Options`）

v1.0 只有 `Framework.setOption(name, value)` / `getOption(name)` 两个通用方法。v2.0 新增 `Options` 类，提供 **16 对**类型化快捷方法：

```java
import lingofuse.Options;

// 网络准备
Options.setWaitConnectionReadyOk(true);
Options.setWaitConnectionTimeout(10_000L);
Options.setOverlapConnection(true);

// 日志
Options.setQuiet(false);
Options.setShowThreadId(true);

// P2P 分组
Options.setP2pName("worker_group");
String myGroup = Options.getP2pName();

// 数据句柄池
Options.setDataHandleIdleTimeout(600_000L);
Options.setDataHandlePoolScanInterval(5_000L);

// 序列化通知
Options.setFixedSequencedTime(20_000L);
```

**完整方法列表**：

| Setter | Getter | 类型 |
|--------|--------|------|
| `setPassword(String)` | `getPassword()` → `'********'` | 掩码 |
| `setDebug(String)` | `getDebug()` → 占位符 | 只写 |
| `setQuiet(boolean)` | `getQuiet()` | boolean |
| `setShowThreadId(boolean)` | `getShowThreadId()` | boolean |
| `setConsoleOutput(boolean)` | `getConsoleOutput()` | boolean |
| `setOverlapConnection(boolean)` | `getOverlapConnection()` | boolean |
| `setWaitConnectionReadyOk(boolean)` | `getWaitConnectionReadyOk()` | boolean |
| `setWaitConnectionTimeout(long)` | `getWaitConnectionTimeout()` | long |
| `setIpcServThreadCount(int)` | `getIpcServThreadCount()` | int |
| `setIpcServMaxQueueLength(int)` | `getIpcServMaxQueueLength()` | int |
| `setIpcServMaxMsgSize(int)` | `getIpcServMaxMsgSize()` | int |
| `setFixedSequencedTime(long)` | `getFixedSequencedTime()` | long |
| `setP2pName(String)` | `getP2pName()` | String |
| `setDataHandleIdleTimeout(long)` | `getDataHandleIdleTimeout()` | long |
| `setDataHandlePoolScanInterval(long)` | `getDataHandlePoolScanInterval()` | long |
| `setNoReponseCmdNullFlushThreshold(int)` | `getNoReponseCmdNullFlushThreshold()` | int |

**关键语义**：

- **布尔值在 wire 上用 `"True"` / `"False"`**（Pascal 约定）；Java 侧签名仍然是 `boolean`
- **`getPassword()` 永远返回掩码 `'********'`**；真实值不暴露
- **`getDebug()` 返回占位符**；该选项是只写的
- **`Options.getP2pName()` 读本进程声明的组名**；与 `DataHandle.getP2pName()`（读发送方身份）不同
- **未设置过的选项返回 0 / false / `""`**；不抛异常
- **不跨 `Framework.shutdown()` 持久化**；重启后必须重新设置

### 11.13 进程级 P2P 注册（`P2PRegistry`）

v1.0 的 API 注册都绑定到某个具体的 `AppHandle`。v2.0 新增**进程级 P2P 命名空间**，独立于任何 App。

**两者的区别**：

| 维度 | `AppHandle.registerCall` | `P2PRegistry.registerCall` |
|------|-------------------------|---------------------------|
| **所有权** | 属于 `TLF_App` | 属于**进程本身** |
| **可达方式** | App 名寻址 + UID 寻址 | UID 寻址 + P2PName 寻址 |
| **生命周期** | 随 `AppHandle.close()` 结束 | 直到进程退出 |
| **命名空间** | 与 P2P 独立，同名不冲突 | 与 App 独立，同名不冲突 |

**示例**：

```java
import lingofuse.P2PRegistry;
import lingofuse.LfIo;

// whoami 探针：任何客户端都可以调用它学习自己的身份
P2PRegistry.registerCall("whoami", "echo caller identity",
    (in, out) -> {
        byte[] uid = in.getP2pUid();
        String name = in.getP2pName();
        LfIo.writeJson(out, Map.of(
                "uid_hex", toHex(uid),
                "p2p_name", name));
    });

// 注销
P2PRegistry.unregister("whoami");
```

**行为**：

- **重复注册**抛 `LingoFuseRegistrationException`，`getNamespace()` 返回 `NAMESPACE_P2P`
- **注销**返回 `boolean`（`true` = 该名字存在并被移除）
- **注册可以发生在 `Framework.prepareDone()` 之前或之后**
- **`unregister` 只移除名字**：不再接受新调用，但已经在飞行中的回调不会被打断

### 11.14 side-data 访问器

每次远程请求，**发送方**在发送前会自动把两个身份字段注入到载荷头部：

- **`FromUID`**：发送方的 32 字节会话 UID
- **`FromP2PName`**：发送方声明的 P2P 组名

在回调内部，通过 `DataHandle` 访问：

```java
app.registerCall("whoami", (in, out) -> {
    byte[] senderUid = in.getP2pUid();      // 32 字节，永远非 null
    String senderName = in.getP2pName();    // UTF-8 字符串，可能为 ""
    LfIo.writeJson(out, Map.of(
            "uid_hex", toHex(senderUid),
            "p2p_name", senderName));
});
```

**三个重要的使用约束**：

**约束 1：只在 INPUT handle 上有效**

| 位置 | `getP2pUid()` / `getP2pName()` |
|------|:------------------------------:|
| `On_Call(Input, Output)` 的 `Input` | ✅ 有效 |
| `On_Notify(Input)` 的 `Input` | ✅ 有效 |
| `AppHandle.localCall(param)` 回调的 `Input` | ✅ 有效 |
| `OnResult(Result_)` 的 `Result_`（异步回调） | ❌ 返回全 0 / 空串 |
| `new DataHandle("api")`（自己创建的） | ❌ 返回全 0 / 空串 |

**约束 2：`getP2pUid()` 返回的是拷贝**

Java 包装层立即把 32 字节拷贝到 `byte[]`，调用者拿到的是完全脱离 C buffer 的 Java 对象。可以直接持有、可以跨线程传递、不需要手动释放。

**约束 3：与 `Options.getP2pName()` 完全不同**

| 方法 | 读什么 | 何时有效 |
|------|-------|---------|
| `Options.getP2pName()` | **本进程**声明的组名（本地配置） | 任何时刻 |
| `DataHandle.getP2pName()` | **发送方**的组名（side data） | 只在回调 Input 上 |

---

## 12. API 参考

### 12.1 `DataHandle`

RAII 封装，实现 `AutoCloseable`。

| 方法 | 说明 |
|------|------|
| `new DataHandle(String apiName)` | 创建自动回收句柄 |
| `DataHandle.createPermanent(String apiName)` | 创建永久句柄 |
| `DataHandle.fromRaw(MemorySegment raw, boolean owned)` | 包装已有指针（内部用） |
| `close()` | 释放句柄（借用的句柄是 no-op） |
| `isValid()` / `isOwning()` / `raw()` | 状态访问器 |
| `position()` / `setPosition(long)` | 游标 |
| `size()` / `setSize(long)` | 大小 |
| `getBufferPointer()` | 内部缓冲区的原生指针 |
| `writeBytes(byte[])` | 写原始字节 |
| `readBytes(int)` | 读至多 N 字节 |
| `readBytesExact(int)` | 精确读 N 字节（不足时抛异常） |
| `tryReadBytes(int)` | 不抛异常的精确读 |
| `readAllBytes()` | 读至末尾 |
| `writeInt8` ~ `writeDouble` | 小端序原子写 |
| `readInt8` ~ `readDouble` | 小端序原子读 |
| `writeString(String)` | 写 UTF-8 + NUL |
| `readString()` | 读至 NUL（或缓冲区末尾） |
| `tryReadString()` | 不抛异常的读字符串 |
| **`getP2pUid()`** | **读发送方 32 字节 UID（side data，只在回调 Input 上有效）** |
| **`getP2pName()`** | **读发送方 P2P 组名（side data，只在回调 Input 上有效）** |

### 12.2 `AppHandle`

| 方法 | 说明 |
|------|------|
| `new AppHandle(String name)` | 用空描述创建 |
| `new AppHandle(String name, String desc)` | 带描述创建 |
| `name()` / `isValid()` / `raw()` | 状态访问器 |
| `registerCall(String api, BiConsumer<DataHandle, DataHandle> handler)` | 注册 Call API |
| `registerCall(String api, String desc, handler)` | 带描述 |
| `registerNotify(String api, Consumer<DataHandle> handler)` | 注册 Notify API |
| `registerNotify(String api, String desc, handler)` | 带描述 |
| `unregister(String api)` | 反注册 |
| `localCall(DataHandle param)` | 本地同步调用 |
| `localNotify(DataHandle param)` | 本地通知 |
| `bind()` | 绑定到空闲客户端 |
| `close()` | 释放 |

### 12.3 `Framework`

| 方法 | 说明 |
|------|------|
| `setCallbackErrorHandler(BiConsumer<String, Throwable>)` | 安装回调错误处理器 |
| `resetPrepare()` | 清空准备队列 |
| `prepareService(String listen, String physics)` | 准备服务 |
| `prepareClient(String physics, AppHandle app)` | 准备客户端 |
| `prepareDone()` | 启动框架 |
| `exitMainThread()` | 停止主线程 |
| `setOption(String option, String value)` | 设置运行时选项（通用） |
| `getOption(String option)` | 读取运行时选项（通用） |
| `generateAppName()` | 生成唯一 App 名 |
| `getAppName(AppHandle app)` | 查询 App 名 |
| `call(String app, DataHandle param, long timeoutMs)` | 同步远程调用（App 名） |
| `tryCall(String app, DataHandle param, long timeoutMs)` | 超时返回 `null` 的调用 |
| `notify(String app, DataHandle param)` | 单向通知（App 名） |
| `sequencedNotify(String app, DataHandle param)` | FIFO 单向通知（App 名） |
| **`uidCall(byte[] uid, DataHandle param, long timeoutMs)`** | **同步远程调用（UID）** |
| **`tryUidCall(byte[] uid, DataHandle param, long timeoutMs)`** | **UID 变体的 tryCall** |
| **`uidNotify(byte[] uid, DataHandle param)`** | **单向通知（UID）** |
| **`uidSequencedNotify(byte[] uid, DataHandle param)`** | **FIFO 单向通知（UID）** |
| **`p2pCall(String group, DataHandle param, long timeoutMs)`** | **同步远程调用（P2PName）** |
| **`tryP2pCall(String group, DataHandle param, long timeoutMs)`** | **P2PName 变体的 tryCall** |
| **`p2pNotify(String group, DataHandle param)`** | **单向通知（P2PName）** |
| **`p2pSequencedNotify(String group, DataHandle param)`** | **FIFO 单向通知（P2PName）** |
| **`asyncCall(String app, DataHandle param, AsyncResultHandler handler)`** | **异步调用（App 名，raw handle）** |
| **`asyncCallJson(String app, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`** | **异步调用（App 名，类型化）** |
| **`asyncSequencedCall(String app, DataHandle param, AsyncResultHandler handler)`** | **FIFO 异步调用（App 名，raw handle）** |
| **`asyncSequencedCallJson(String app, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`** | **FIFO 异步调用（App 名，类型化）** |
| **`asyncUidCall(byte[] uid, DataHandle param, AsyncResultHandler handler)`** | **异步调用（UID，raw handle）** |
| **`asyncUidCallJson(byte[] uid, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`** | **异步调用（UID，类型化）** |
| **`asyncUidSequencedCall(byte[] uid, DataHandle param, AsyncResultHandler handler)`** | **FIFO 异步调用（UID，raw handle）** |
| **`asyncUidSequencedCallJson(byte[] uid, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`** | **FIFO 异步调用（UID，类型化）** |
| **`asyncP2pCall(String group, DataHandle param, AsyncResultHandler handler)`** | **异步调用（P2PName，raw handle）** |
| **`asyncP2pCallJson(String group, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`** | **异步调用（P2PName，类型化）** |
| **`asyncP2pSequencedCall(String group, DataHandle param, AsyncResultHandler handler)`** | **FIFO 异步调用（P2PName，raw handle）** |
| **`asyncP2pSequencedCallJson(String group, DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)`** | **FIFO 异步调用（P2PName，类型化）** |
| `shutdown()` | 完全关闭 |

### 12.4 `LfIo`

| 方法 | 说明 |
|------|------|
| `dumpsJson(Object)` | 序列化为紧凑 JSON 字符串 |
| `loadsJson(String)` | 解析为 `JsonNode` |
| `loadsJson(String, Class<T>)` | 解析为 POJO |
| `writeString(DataHandle, String)` | 写 UTF-8 + NUL |
| `readString(DataHandle)` | 读字符串 |
| `writeStringBytes(DataHandle, byte[])` | 写原始字节 + NUL |
| `readStringBytes(DataHandle)` | 读原始字节（至 NUL） |
| `readAllBytes(DataHandle)` | 读全部 |
| `writeJson(DataHandle, Object)` | 写 JSON |
| `readJson(DataHandle)` | 读 JSON 为 `JsonNode` |
| `readJson(DataHandle, Class<T>)` | 读 JSON 为 POJO |
| `tryReadJson(DataHandle, Class<T>)` | 不抛异常的 JSON 读 |

### 12.5 `NetworkEvents`

| 方法 | 说明 |
|------|------|
| `setNetworkEvent(Consumer<String>, Consumer<String>)` | 安装 connect / disconnect |
| `clear()` | 移除 |
| `isInstalled()` | 是否已安装 |
| `setNetworkEventListener(NetworkEventListener)` | 安装 OOP 监听器 |

### 12.6 `LingoFuseStatus`

| 方法 | 说明 |
|------|------|
| `getStatusCount()` | 待处理日志数 |
| `getStatus()` | 弹出下一条 |
| `drainStatus()` / `drainStatus(int)` | 批量弹出 |
| `postStatus(String)` | 注入日志 |
| `checkMainThread()` | 主线程是否运行 |
| `checkApp(String)` | App 是否可见 |
| `checkApi(String, String)` | API 是否可见 |
| **`checkUid(byte[])`** | **UID 是否可见** |
| **`checkUidApi(byte[], String)`** | **UID 的 API 是否可见** |
| **`checkP2pName(String)`** | **P2P 组是否可见** |
| **`checkP2pNameApi(String, String)`** | **P2P 组的 API 是否可见** |

**注意**：所有 `check*` 方法基于本地缓存，广播延迟约 3 秒。用于**探测**，不用于**决策**。

### 12.7 `Options`

16 对类型化 getter / setter。完整列表见 §11.12。

### 12.8 `P2PRegistry`

| 方法 | 说明 |
|------|------|
| `registerCall(String apiName, String description, BiConsumer<DataHandle, DataHandle> handler)` | 注册进程级 Call API |
| `registerCall(String apiName, BiConsumer<DataHandle, DataHandle> handler)` | 无描述版本 |
| `registerNotify(String apiName, String description, Consumer<DataHandle> handler)` | 注册进程级 Notify API |
| `registerNotify(String apiName, Consumer<DataHandle> handler)` | 无描述版本 |
| `unregister(String apiName)` | 注销，返回 `boolean` |

### 12.9 `Target` / `AppTarget` / `UIDTarget` / `P2PNameTarget`

三个 Target 都继承自 `lingofuse.address.Target`，共享完全对等的 API。

| 方法 | 说明 |
|------|------|
| `call(DataHandle param)` | 同步调用，默认超时 |
| `call(DataHandle param, long timeoutMs)` | 同步调用，显式超时 |
| `callJson(DataHandle param, Class<T> type)` | 同步调用 + JSON 反序列化 |
| `callJson(DataHandle param, Class<T> type, long timeoutMs)` | 同上，显式超时 |
| `notify(DataHandle param)` | 单向通知 |
| `sequencedNotify(DataHandle param)` | 单向通知，按 `(target, api)` FIFO |
| `asyncCall(DataHandle param, AsyncResultHandler handler)` | 异步回调，raw handle |
| `asyncCallJson(DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)` | 异步回调，类型化 |
| `asyncSequencedCall(DataHandle param, AsyncResultHandler handler)` | 异步回调，FIFO |
| `asyncSequencedCallJson(DataHandle param, Class<T> type, TypedAsyncResultHandler<T> handler)` | 异步回调，FIFO + 类型化 |
| `callFuture(DataHandle param, Class<T> type)` | 异步 Future，默认超时 |
| `callFuture(DataHandle param, Class<T> type, long timeoutMs)` | 异步 Future，显式超时 |
| `sequencedCallFuture(DataHandle param, Class<T> type)` | 异步 Future，FIFO，默认超时 |
| `sequencedCallFuture(DataHandle param, Class<T> type, long timeoutMs)` | 异步 Future，FIFO，显式超时 |
| `describe()` | 返回 `"app(X)"` / `"uid(hex)"` / `"p2pname(g)"` |

**Target 的构造**：

```java
// App 名：任何非空字符串
new AppTarget("MyApp");
new AppTarget("MyApp", 10_000L);   // 显式默认超时

// UID：必须是 32 字节
new UIDTarget(uidBytes);
new UIDTarget(uidBytes, 10_000L);

// P2PName：任何非空字符串
new P2PNameTarget("worker_group");
new P2PNameTarget("worker_group", 10_000L);
```

**值语义**：三个 Target 都实现了 `equals` / `hashCode` / `toString`。

### 12.10 异步子系统（`lingofuse.async`）

| 类 | 用途 |
|----|------|
| `AsyncSupport` | 工厂：`makeLegacyOp` / `makeTypedLegacyOp` / `makeFutureOp` / `runAsyncWithFuture` + 4 个预置 deserializer |
| `AsyncOp` | 单次异步操作的状态机 |
| `AsyncBridge` | 进程级单例，管理 op 生命周期与超时 |
| `CallFuture<T>` | `CompletableFuture<T>` 子类，含 `abandoned()` 标志 |
| `AsyncResultHandler` | 原始 handle 风格回调接口 |
| `TypedAsyncResultHandler<T>` | 类型化对象风格回调接口 |

**普通用户通常不需要直接使用这些类** —— `Target` 和 `Framework` 的异步方法已经把它们全部封装。仅在需要自定义 deserializer、诊断、或测试隔离时才直接接触。

**诊断接口**：

```java
AsyncBridge bridge = AsyncBridge.instance();
Map<String, Object> stats = bridge.stats();
// { "total": N, "pending": N, "fired": N, "abandoned": N,
//   "not_queued": N, "released_total": N, "grace_seconds": N }

int liveOps = bridge.liveOpCount();
AsyncBridge.shutdownInstance();     // 测试隔离用
```

### 12.11 异常

| 类型 | 触发场景 |
|------|----------|
| `LingoFuseException` | 基类 |
| `LingoFuseIoException` | 字节级 I/O 失败（短读 / 短写），携带 `getOperation()` |
| `LingoFuseObjectDisposedException` | 已关闭对象上的操作，携带 `getObjectName()` |
| `LingoFuseTimeoutException` | 同步或异步调用超时，携带 `getTimeoutMs()` |
| `LingoFuseRegistrationException` | API 注册失败，携带 `getApiName()` 和 `getNamespace()` |

**捕获策略**：捕获 `LingoFuseException` 即可覆盖所有绑定抛出的异常；需要细化时按子类判断。

---

## 13. 故障排查

### 13.1 `Cannot find module 'mvn'`

Maven 未安装或未加入 `PATH`。见 §4.2。

### 13.2 `release version 22 not supported`

JDK 版本低于 22。见 §4.1。

### 13.3 `UnsatisfiedLinkError: Failed to load LingoFuse64.dll`

原生库不在搜索路径上。见 §5。

**打印搜索路径**：

```java
import lingofuse.ffi.LibraryLoader;
System.out.println(LibraryLoader.buildSearchPaths());
```

### 13.4 `UnsatisfiedLinkError: LingoFuse symbol not found: LF_XXX`

**版本不匹配**：Java 绑定期望的某个 C ABI 符号在加载的 DLL / .so 中不存在。原因通常是：
- DLL 是旧版（v1.0 的 37 个符号），Java 是 v2.0（期望 59 个符号）
- DLL 是 v2.0 但 Java 是旧版

**修复**：确保 Java 绑定和原生库是同一版本。检查 `target/classes/lingofuse/ffi/NativeMethods.class` 里的符号列表与 `Binary/` 目录下的 DLL 是否匹配。

### 13.5 `The restricted method ... has been called`

JDK 24+ 需要显式开启 native access。用命令行参数：

```bash
java --enable-native-access=ALL-UNNAMED -cp target\classes ...
```

或者在 `pom.xml` 的 surefire 配置里已经设好了（见项目自带 `pom.xml`）。

### 13.6 `prepareDone() 返回 0`

**正常行为，不是失败**。每进程只返回 1 一次。如果已经初始化过，第二次返回 0。检查：

```java
if (Framework.prepareDone() != 1
        && !LingoFuseStatus.checkMainThread()) {
    // 真正失败
}
```

### 13.7 调用立即超时

常见原因是 **API 注册在 `prepareClient` 之后**。必须**先注册 API，再 `prepareClient`**，否则 `Init_App_Info` 广播携带空 API 列表。

```java
AppHandle app = new AppHandle("MyApp");
app.registerCall("ping", ...);   // ← 先注册
Framework.prepareClient(endpoint, app);   // ← 后绑定
```

### 13.8 `CheckApp` / `CheckApi` 返回 false

**3 秒广播延迟**。刚启动的 App 需要等待广播传播。重试循环：

```java
for (int i = 0; i < 30; i++) {
    if (LingoFuseStatus.checkApi("Target", "api")) break;
    Thread.sleep(200);
}
```

### 13.9 异步回调不触发

**可能原因**：
1. dispatch 返回 `false`（C 库拒绝入队）——检查返回值
2. 目标 App / API 不存在——异步调用不会立即失败，会等超时
3. `AsyncBridge` 已 shutdown——检查是否在测试外调用了 `shutdownInstance()`

**诊断**：

```java
Map<String, Object> stats = AsyncBridge.instance().stats();
System.out.println(stats);
// {"total": N, "pending": N, ...}
```

`pending` 长期不降 = C 侧未响应；`not_queued` 上升 = dispatch 失败。

### 13.10 `LingoFuseTimeoutException` 带 0 timeoutMs

**来自异步路径**：`CallFuture` 完成异常时，`LingoFuseTimeoutException` 不携带具体的 timeout 值（`getTimeoutMs()` 返回 0）。这是已知实现细节；如果需要 timeout 值，用同步路径的 `Target.call`。

### 13.11 `callFuture()` 的 `abandoned()` 返回 true

**C 侧请求可能仍在飞行**。超时只表示 Python/Java 侧放弃等待，不表示 C 侧取消。如果响应稍后到达，其数据会被静默丢弃。

### 13.12 `P2PRegistry.registerCall` 抛 `LingoFuseRegistrationException`

**名字冲突**。`getNamespace()` 返回 `NAMESPACE_P2P` 表示冲突发生在进程级 P2P 命名空间。可能原因：
- 同进程里同一个名字注册了两次
- 名字已被别的模块注册

**注意**：**App 命名空间和 P2P 命名空间是独立的**。同一个名字可以同时存在于两者，互不冲突。

### 13.13 回调日志挤在一行

**Windows 控制台 + JVM native 线程**的已知交互问题。修法是所有日志经**单消费者队列 + 专用线程**输出。`CrossNode` / `CrossCall` 已经用这个方案。用户自己的服务端如果也有高频回调日志，参考它们的实现。

### 13.14 `Options` 设置不生效

**可能原因**：
1. 选项名拼错——用 typed 方法避免
2. 该选项需要在特定时机前设置——例如 `Overlap_Connection` 必须在 `prepareClient` 之前
3. `Framework.shutdown()` 后未重新设置——选项不跨 shutdown 持久化

### 13.15 中文 / emoji 变 `\uXXXX`

**不可能发生**。Jackson 的默认行为就是字面 UTF-8 输出。如果看到了，说明代码绕过了 `LfIo`，直接调用了某个会 escape 的 API。

**正确做法**：所有 JSON 载荷都通过 `LfIo.writeJson` / `LfIo.readJson`。

### 13.16 完整诊断工具

参考 `check-env.js`（JavaScript 绑定）的思路，可以手写：

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
        // 尝试一次真实的 native 调用
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

## 14. 当前状态与路线图

### 14.1 已交付（阶段 1–4）

| 阶段 | 内容 | 状态 |
|:----:|------|:----:|
| **1** | C ABI 绑定层 + RAII 封装 + 单元测试 | ✅ |
| **2** | `EchoDemo` 单进程 demo | ✅ |
| **3** | `CrossService` / `CrossNode` / `CrossCall` 三进程 demo | ✅ |
| **4** | **三寻址模式 + 异步子系统 + Options + P2PRegistry** | ✅ |

### 14.2 计划中

| 阶段 | 内容 | 优先级 |
|:----:|------|:------:|
| **4.5** | 性能优化：`invokeExact` + Arena 复用，目标 1500+ calls/s | 高 |
| **5** | 高级接口：`LingoFuseApp` / `LingoFuseClient` / 注解驱动 / SLF4J | 中 |
| **6** | CI 集成：GitHub Actions | 中 |
| **7** | 跨语言互操作 e2e 测试：与 C# / Python / C++ 的交叉验证 | 中 |

### 14.3 已知限制

| 限制 | 说明 |
|------|------|
| **JDK 22+ 必需** | 不支持 JDK 8 / 11 / 17 / 21 |
| **仅 64 位** | 不支持 32 位平台 |
| **性能未优化** | 当前 ~250 calls/s，低于 C# / C++ 绑定 |
| **无 Java 模块化** | 未提供 `module-info.java`（用 `--enable-native-access=ALL-UNNAMED` 解决） |
| **无高级接口** | 目前只有底层 API，没有 `LingoFuseApp` / `LingoFuseClient` |
| **无 SLF4J 集成** | 回调错误默认写 stderr |

### 14.4 与其他绑定的对比

| 功能 | Java | C# | Python | C++ | Pascal | JS |
|------|:----:|:--:|:------:|:---:|:------:|:--:|
| 底层绑定 | ✅ FFM | ✅ P/Invoke | ✅ ctypes | ✅ 手动 | ✅ 静态 | ✅ Koffi |
| RAII 封装 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| JSON I/O | ✅ | ✅ | ✅ | ✅ | ⚠️ | ✅ |
| 网络事件 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 永久句柄 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 三寻址模式 | ✅ | ⚠️ | ✅ | ❌ | ✅ | ❌ |
| 异步子系统 | ✅ | ⚠️ | ✅ | ❌ | ✅ | ❌ |
| 类型化选项 | ✅ | ✅ | ✅ | ⚠️ | ✅ | ❌ |
| 进程级 P2P 注册 | ✅ | ⚠️ | ✅ | ❌ | ✅ | ❌ |
| 高级接口 | ⏳ | ✅ | ✅ | ⚠️ | ✅ | ❌ |
| CI | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |

---

## 15. 许可证

MIT。

---

## 16. 附录：v1.0 → v2.0 迁移

> **v2.0 是纯增量升级**。v1.0 的所有类、方法、签名**保持不变**；新增的类、方法、枚举**全部可选使用**。任何用 v1.0 API 写成的代码，在 v2.0 下**编译、运行、语义全部不变**。
>
> **升级成本**：零。仅需替换 `target/` 下的 `.jar` 或重新 `mvn install`，无需修改任何业务代码。

### 16.1 v2.0 新增能力一览

| 能力 | 类 / 方法 | 章节 |
|------|-----------|------|
| **三寻址模式** | `lingofuse.address.AppTarget` / `UIDTarget` / `P2PNameTarget` | §11.9 |
| **异步回调（"直接写业务"）** | `Target.asyncCall` / `Target.asyncCallJson` | §11.10 |
| **异步 Future（链式组合）** | `Target.callFuture` / `Target.sequencedCallFuture` | §11.11 |
| **`Framework` 异步方法（12 个）** | `Framework.asyncCall*` / `asyncUidCall*` / `asyncP2pCall*` | §12.3 |
| **类型化选项快捷方法（16 对）** | `lingofuse.Options` | §11.12 |
| **进程级 P2P 命名空间注册** | `lingofuse.P2PRegistry` | §11.13 |
| **UID / P2PName 健康检查** | `LingoFuseStatus.checkUid` / `checkP2pName` 等 4 个方法 | §12.6 |
| **异步诊断** | `lingofuse.async.AsyncBridge` | §12.10 |
| **side-data 访问器** | `DataHandle.getP2pUid()` / `getP2pName()` | §11.14 |
| **新异常** | `LingoFuseTimeoutException` / `LingoFuseRegistrationException` | §12.11 |

### 16.2 迁移对照表

| v1.0 写法 | v2.0 等价写法 | 说明 |
|-----------|--------------|------|
| `Framework.setOption("Wait_Connection_Timeout", "10000")` | `Options.setWaitConnectionTimeout(10_000L)` | 类型化，拼写不再出错 |
| `Framework.getOption("LF_P2P_name")` | `Options.getP2pName()` | 同上 |
| `Framework.call("MyApp", req, 3000)` | `new AppTarget("MyApp").call(req, 3000)` | Target 层超时抛异常；`Framework.call` 保持返回 size=0 |
| `AppHandle.registerCall(api, handler)` | 保持不变（App-bound 语义未变） | — |
| 无 | `P2PRegistry.registerCall(api, handler)` | 全新的进程级 P2P 注册 |
| 无 | `new UIDTarget(uid).call(req, 3000)` | 全新的 UID 寻址 |
| 无 | `new P2PNameTarget("group").call(req, 3000)` | 全新的 P2PName 寻址 |
| 无 | `Framework.asyncCallJson(app, req, Person.class, (p, e) -> { ... })` | 全新的异步回调 |
| 无 | `target.callFuture(req, Person.class, 3000)` | 全新的异步 Future |
| 无 | `DataHandle.getP2pUid()` / `getP2pName()` | 全新的 side-data 访问器 |
| `catch (LingoFuseException e)` | 保持有效；可细化为 `catch (LingoFuseTimeoutException e)` | 新异常继承自 `LingoFuseException` |

### 16.3 何时应该迁移

| 场景 | 建议 |
|------|------|
| 现有代码工作正常 | **不必迁移**。v2.0 完全兼容 v1.0 |
| 需要三寻址模式 | 使用 `Target` 层（`AppTarget` / `UIDTarget` / `P2PNameTarget`） |
| 需要异步不阻塞调用 | 使用 `Target.asyncCallJson` / `callFuture` |
| 需要进程级工具 API | 使用 `P2PRegistry` |
| 想要拼错选项立刻发现 | 使用 `Options.*` |
| 依赖 v1.0 的"超时返回 size=0" | **继续用 `Framework.call`**（Target 层会抛异常） |

### 16.4 命名冲突提示

- **`Options.getP2pName()`** 读**本进程声明的组名**（本地配置）
- **`DataHandle.getP2pName()`** 读**发送方的组名**（side data，只在回调 Input 上有意义）

两者名字相同，语义完全无关。见 §11.14。

### 16.5 版本历史

| 版本 | 变更 |
|------|------|
| **v1.0.0** | C ABI 绑定层 / RAII 封装 / `EchoDemo` / `CrossService` 三件套 / 36 项测试 |
| **v2.0.0** | **纯增量升级**：<br>• 三寻址模式（`Target` / `AppTarget` / `UIDTarget` / `P2PNameTarget`）<br>• 异步回调 + Future 双风格（`AsyncBridge` / `AsyncOp` / `AsyncSupport` / `CallFuture`）<br>• 16 对类型化选项快捷方法（`Options`）<br>• 进程级 P2P 命名空间注册（`P2PRegistry`）<br>• UID / P2PName 健康检查（`LingoFuseStatus` 扩展）<br>• side-data 访问器（`DataHandle.getP2pUid` / `getP2pName`）<br>• 新异常（`LingoFuseTimeoutException` / `LingoFuseRegistrationException`）<br>• C ABI 覆盖从 37 → **59** 个符号<br>• 测试从 36 → **145** 项 |

### 16.6 兼容性声明

- ✅ **API 兼容**：所有 v1.0 的类、方法、签名保持不变
- ✅ **ABI 兼容**：`LingoFuse64.dll` 版本无需变更
- ✅ **行为兼容**：v1.0 的调用语义完全一致
- ⚠️ **唯一的语义差异**：`Target.call` 在超时时**抛异常**而非返回 size=0 的 handle。这是 Target 层**新增**的行为；`Framework.call` 的 v1.0 行为保持不变

### 16.7 升级步骤

1. 备份 `target/` 目录下的旧 jar
2. 从新版源码重新 `mvn -B clean install`
3. 无需修改任何业务代码
4. 运行测试确认：`.\test.ps1`（Windows）/ `mvn -B clean test`（Linux / macOS）

---

*本文档随 LingoFuse Java 绑定 v2.0.0 整理，覆盖 59 个 C ABI 符号、145 项测试、4 个 Demo。*
*最后更新：2026-10-13*
