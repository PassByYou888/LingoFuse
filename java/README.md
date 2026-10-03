# LingoFuse Java 绑定

> **跨语言通讯地基的 Java 官方绑定。基于 JDK 22+ 的 FFM API，纯 Java 实现，无需编写任何 C 胶水代码。**

本目录是 Java / JVM 开发者使用 LingoFuse 的唯一起点。读完本 README 即可知道：

- 需要什么环境，如何一步步搭建；
- 如何运行测试、如何跑 CI；
- 如何与 Pascal / Python / C++ / C# / JavaScript 互操作；
- 日常 Java 代码中如何使用 LingoFuse 的 API。

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

---

## 1. 结论先说：Java 支持覆盖了什么

| 维度 | 状态 | 说明 |
|------|:----:|------|
| **底层 FFI 绑定** | ✅ 完整 | 37 个 C ABI 导出函数全部封装，覆盖数据句柄 / 应用句柄 / 网络准备 / 远程调用 / 诊断 / 网络事件 / 关闭 |
| **RAII 封装** | ✅ 完整 | `DataHandle` / `AppHandle` 实现 `AutoCloseable`，支持 try-with-resources |
| **统一 JSON I/O** | ✅ 完整 | `LfIo` 是唯一序列化入口，跨语言字节一致 |
| **进程级门面** | ✅ 完整 | `Framework` 提供网络准备、远程调用、选项、应用名生成、关闭 |
| **网络事件** | ✅ 完整 | `NetworkEvents` 全局 connect / disconnect 回调 |
| **状态与健康检查** | ✅ 完整 | `LingoFuseStatus` 状态队列 + 探活 |
| **异常层次** | ✅ 完整 | 3 个异常类型（基类 / I/O / 已关闭） |
| **永久句柄** | ✅ 完整 | `DataHandle.createPermanent(...)` |
| **跨语言 ABI** | ✅ 已测试 | 逐字节小端序验证，与 C++ / Pascal / Python / C# / JS 字节一致 |
| **跨语言 JSON** | ✅ 已测试 | emoji / 中文无 `\uXXXX` 转义 |
| **多进程 Demo** | ✅ 已测试 | `CrossService` / `CrossNode` / `CrossCall` 三件套 |
| **多线程并发** | ✅ 已测试 | 32 线程 × 10 秒负载测试，100% 成功 |
| **单元测试** | ✅ 完整 | 36 项，覆盖数据句柄、应用句柄、JSON I/O |
| **高级接口层** | ⏳ 计划中 | `LingoFuseApp` / `LingoFuseClient` / 注解驱动 / SLF4J 集成 |
| **性能优化** | ⏳ 计划中 | 当前 ~250 calls/s，目标 1500+ calls/s |
| **CI** | ⚠️ 无 | 目前以本地运行为准 |

**总体判断：Java 绑定已经能完成生产级的跨进程 RPC 调用，覆盖从 FFI 绑定到跨语言互操作的完整链路，并附带 36 项自动化测试和三进程 Demo。**

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
│   │   ├── DataHandle.java                    RAII 数据句柄
│   │   ├── AppHandle.java                     RAII 应用句柄
│   │   ├── Framework.java                     进程级门面
│   │   ├── LfIo.java                          统一 JSON / 字符串 I/O
│   │   ├── NetworkEvents.java                 全局网络事件
│   │   ├── LingoFuseStatus.java               状态队列 + 健康检查
│   │   ├── errors/
│   │   │   ├── LingoFuseException.java        异常基类
│   │   │   ├── LingoFuseIoException.java      字节级 I/O 异常
│   │   │   └── LingoFuseObjectDisposedException.java
│   │   ├── ffi/                                FFM 层（用户不应直接调用）
│   │   │   ├── LibraryLoader.java             动态库加载
│   │   │   ├── NativeMethods.java             37 个 C ABI 函数的 MethodHandle
│   │   │   ├── NativeTypes.java               值布局 + 回调 FunctionDescriptor
│   │   │   └── NativeCall.java                MethodHandle 调用包装
│   │   └── demo/
│   │       ├── EchoDemo.java                  单进程端到端 demo
│   │       └── cross/
│   │           ├── CrossService.java          信标（协调器）
│   │           ├── CrossNode.java             工作节点（暴露 ABI API）
│   │           └── CrossCall.java             32 线程负载测试客户端
│   └── test/java/lingofuse/
│       ├── DataHandleSmokeTest.java           23 项测试
│       └── AppHandleSmokeTest.java            13 项测试
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
[INFO] Running lingofuse.AppHandleSmokeTest
[INFO] Tests run: 13, Failures: 0, Errors: 0, Skipped: 0
[INFO] Running lingofuse.DataHandleSmokeTest
[INFO] Tests run: 23, Failures: 0, Errors: 0, Skipped: 0
[INFO] BUILD SUCCESS
```

**36 项测试全部通过**，即环境搭建成功。

### 7.2 测试覆盖

`DataHandleSmokeTest`（23 项）：

- 库加载、平台库名
- 数据句柄生命周期（创建 / 关闭 / 幂等）
- 永久句柄创建与同步释放
- 全部原子类型往返（`int8` ~ `double`）
- 位置 / 大小访问器
- 部分读取 vs 精确读取
- `tryRead*` 系列
- 字符串 NUL 帧协议
- 空字符串 / Unicode / 容错读取
- 小端序验证
- JSON wire bytes 逐字节验证
- 无 `\uXXXX` 转义验证
- 参数校验

`AppHandleSmokeTest`（13 项）：

- 应用生命周期
- Call / Notify API 注册 / 反注册
- 大小写不敏感匹配
- 本地调用（命中 / 未命中）
- 回调异常隔离
- 借用句柄 no-op
- 回调长期存活（100 次调用）
- 参数校验

### 7.3 运行单个测试

```bash
mvn test -Dtest=DataHandleSmokeTest
mvn test -Dtest=DataHandleSmokeTest#writeStringAppendsNul
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

在 `java/` 目录下执行即可：

```bash
mvn clean test
```

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
| 远程调用 | `Framework.call` | `lingofuse::call` | `Framework.Call` | `C4.call` | `LF_Call` | `framework.call` |
| 永久句柄 | `DataHandle.createPermanent` | `DataHandle::createPermanent` | `DataHandle.CreatePermanent` | `DataHandle.create_permanent` | `LF_CreateData_Permanent` | `DataHandle.createPermanent` |

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
            Framework.setOption("Wait_Connection_ReadyOk", "True");
            Framework.setOption("Overlap_Connection", "True");
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

public class MyClient {
    public static void main(String[] args) {
        Framework.setOption("Wait_Connection_ReadyOk", "True");
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
| `setOption(String option, String value)` | 设置运行时选项 |
| `generateAppName()` | 生成唯一 App 名 |
| `getAppName(AppHandle app)` | 查询 App 名 |
| `call(String app, DataHandle param, long timeoutMs)` | 同步远程调用 |
| `tryCall(String app, DataHandle param, long timeoutMs)` | 超时返回 `null` 的调用 |
| `notify(String app, DataHandle param)` | 单向通知 |
| `sequencedNotify(String app, DataHandle param)` | FIFO 单向通知 |
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

### 12.7 异常

| 类型 | 触发场景 |
|------|----------|
| `LingoFuseException` | 基类 |
| `LingoFuseIoException` | 字节级 I/O 失败（短读 / 短写），携带 `getOperation()` |
| `LingoFuseObjectDisposedException` | 已关闭对象上的操作，携带 `getObjectName()` |

**捕获策略**：捕获 `LingoFuseException` 即可覆盖所有绑定抛出的异常；需要细化时按子类判断。

---

## 13. 故障排查

### 13.1 `Cannot find module 'mvn'`

Maven 未安装或未加入 `PATH`。见 [§4.2 安装 Maven](#42-安装-maven)。

### 13.2 `release version 22 not supported`

JDK 版本低于 22。见 [§4.1 安装 JDK 25](#41-安装-jdk-25推荐)。

### 13.3 `UnsatisfiedLinkError: Failed to load LingoFuse64.dll`

原生库不在搜索路径上。见 [§5 原生库放置](#5-原生库放置)。

**打印搜索路径**：

```java
import lingofuse.ffi.LibraryLoader;
System.out.println(LibraryLoader.buildSearchPaths());
```

### 13.4 `The restricted method ... has been called`

JDK 24+ 需要显式开启 native access。用命令行参数：

```bash
java --enable-native-access=ALL-UNNAMED -cp target\classes ...
```

或者在 `pom.xml` 的 surefire 配置里已经设好了（见项目自带 `pom.xml`）。

### 13.5 `prepareDone() 返回 0`

**正常行为，不是失败**。每进程只返回 1 一次。如果已经初始化过，第二次返回 0。检查：

```java
if (Framework.prepareDone() != 1
        && !LingoFuseStatus.checkMainThread()) {
    // 真正失败
}
```

### 13.6 调用立即超时

常见原因是 **API 注册在 `prepareClient` 之后**。必须**先注册 API，再 `prepareClient`**，否则 `Init_App_Info` 广播携带空 API 列表。

```java
AppHandle app = new AppHandle("MyApp");
app.registerCall("ping", ...);   // ← 先注册
Framework.prepareClient(endpoint, app);   // ← 后绑定
```

### 13.7 `CheckApp` / `CheckApi` 返回 false

**3 秒广播延迟**。刚启动的 App 需要等待广播传播。重试循环：

```java
for (int i = 0; i < 30; i++) {
    if (LingoFuseStatus.checkApi("Target", "api")) break;
    Thread.sleep(200);
}
```

### 13.8 回调日志挤在一行

**Windows 控制台 + JVM native 线程**的已知交互问题。修法是所有日志经**单消费者队列 + 专用线程**输出。`CrossNode` / `CrossCall` 已经用这个方案。用户自己的服务端如果也有高频回调日志，参考它们的实现。

### 13.9 中文 / emoji 变 `\uXXXX`

**不可能发生**。Jackson 的默认行为就是字面 UTF-8 输出。如果看到了，说明代码绕过了 `LfIo`，直接调用了某个会 escape 的 API。

**正确做法**：所有 JSON 载荷都通过 `LfIo.writeJson` / `LfIo.readJson`。

### 13.10 完整诊断工具

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

### 14.1 已交付（阶段 1–3）

| 阶段 | 内容 | 状态 |
|:----:|------|:----:|
| **1** | C ABI 绑定层 + RAII 封装 + 单元测试 | ✅ |
| **2** | `EchoDemo` 单进程 demo | ✅ |
| **3** | `CrossService` / `CrossNode` / `CrossCall` 三进程 demo | ✅ |

### 14.2 计划中

| 阶段 | 内容 | 优先级 |
|:----:|------|:------:|
| **3.5** | 性能优化：`invokeExact` + Arena 复用，目标 1500+ calls/s | 高 |
| **4** | 高级接口：`LingoFuseApp` / `LingoFuseClient` / 注解驱动 / SLF4J | 中 |
| **5** | CI 集成：GitHub Actions | 中 |
| **6** | 跨语言互操作 e2e 测试：与 C# / Python / C++ 的交叉验证 | 中 |

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
| 高级接口 | ⏳ | ✅ | ✅ | ⚠️ | ✅ | ❌ |
| CI | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |

---

## 15. 许可证

MIT。

---

*本文档随 LingoFuse Java 绑定 v1.0.0（阶段 3 完成）整理，覆盖 36 项测试 + 4 个 Demo。*
*最后更新：2026-10-03*
