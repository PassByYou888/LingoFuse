# LingoFuse C/C++ 接口 README

> 跨语言通讯地基的 C/C++ 官方绑定。基于 C ABI 和 C++17 RAII 封装，提供类型安全、资源自动管理、跨平台的高性能 RPC 调用能力，并内置现代化的异步调用模型。

---

## 目录

1. [环境准备](#1-环境准备)
2. [编译](#2-编译)
3. [测试](#3-测试)
4. [使用 C++ 接口](#4-使用-c-接口)
5. [使用异步调用模型](#5-使用异步调用模型)
6. [读取发送方身份（侧数据）](#6-读取发送方身份侧数据)
7. [测试报告](#7-测试报告)
8. [故障排查](#8-故障排查)
9. [许可](#9-许可)

---

## 1. 环境准备

### 1.1 编译器与工具链

| 项目 | 要求 |
|------|------|
| C++ 标准 | **C++17** 或更高 |
| 编译器 | MSVC 2019+ / GCC 9+ / Clang 10+ / MinGW |
| CMake | 3.15 或更高 |
| 线程库 | `Threads::Threads`（CMake 自动查找） |
| 平台 | Windows 64/32 位、Linux、macOS、BSD |

### 1.2 运行时库

C/C++ 绑定**不包含** LingoFuse 原生共享库，需要单独获取并放置到系统能搜索到的位置。

| 平台 | 核心库 | IPC 依赖 | 内存分配器 |
|------|--------|----------|------------|
| Windows 64 位 | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32 位 | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` | `libmimalloc.so`（可选） |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` | `libmimalloc.dylib`（可选） |

**搜索顺序**（由 `LF_LoadLibrary` 决定）：
1. 当前可执行文件所在目录
2. 系统加载路径（`PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`）

**没有环境变量覆盖机制**。建议将运行时库复制到可执行文件同目录，或将其目录加入系统 `PATH`。

### 1.3 获取源代码

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
cd LingoFuse/cpp
```

目录结构：

```
cpp/
├── LingoFuse.h                 # C ABI 声明
├── LingoFuse.c                 # C ABI 动态加载与转发
├── LingoFuse.hpp               # C++17 RAII 封装 + 异步调用模型
├── lf_io.hpp                   # 统一 JSON / 字符串 I/O
├── lf_http_bridge_client.hpp   # HTTP 桥接客户端
├── json.hpp                    # nlohmann/json 单文件
├── CMakeLists.txt              # 顶层构建脚本
├── LingoFuse_Cpp_Knowledge_Base.md   # C++ 知识库
├── json.hpp.md                 # nlohmann/json 参考
├── CrossDemo/                  # 跨进程 Demo
├── Conc/                       # 并发 Notify 演示与 CI
├── Stress/                     # 压力测试套件
└── test/                       # 功能测试套件
    ├── test_lingofuse.cpp           # C++ RAII / 网络 / 异步测试（50 项）
    ├── test_lingofuse_json.cpp      # JSON / 线格式测试（40 项）
    ├── test_lingofuse_capi.c        # 纯 C ABI 离线测试
    ├── test_lingofuse_uid.c         # UID 身份注入端到端测试
    ├── test_uid_probe.c             # UID 调用约定探针（仅 Windows）
    ├── run_test_ci.ps1
    └── LingoFuse_Functional_Test_Guide.md
```

---

## 2. 编译

### 2.1 构建步骤

```bash
cd LingoFuse/cpp
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . --config Release
```

构建产物默认输出到 `LingoFuse/Binary/` 目录（与运行时库同目录）。

### 2.2 主要目标

| 目标 | 类型 | 说明 |
|------|------|------|
| `lingofuse_headers` | INTERFACE | 公共头文件 |
| `lingofuse_c_wrapper` | STATIC | C ABI 转发层 + 动态加载器 |
| `test_lingofuse` | EXECUTABLE | C++ RAII / 网络 / 异步测试（50 项） |
| `test_lingofuse_json` | EXECUTABLE | JSON / 线格式测试（40 项） |
| `test_lingofuse_capi` | EXECUTABLE | 纯 C ABI 离线测试 |
| `test_lingofuse_uid` | EXECUTABLE | UID 身份注入端到端测试 |
| `test_uid_probe` | EXECUTABLE（仅 Windows） | `LF_Get_P2P_UID` 调用约定探针 |
| `ConcService` / `ConcClient` | EXECUTABLE | 并发 Notify 演示 |
| `StressService` / `StressClient` / `StressMonitor` | EXECUTABLE | 压力测试三件套 |
| `CrossService` / `CrossNode` / `CrossCall` | EXECUTABLE | 跨进程 Demo |

### 2.3 编译选项

CMake 自动为 MSVC 添加 `/W4 /permissive-`，为 GCC/Clang 添加 `-Wall -Wextra`。如需自定义，可在 `CMakeLists.txt` 中修改。

---

## 3. 测试

### 3.1 功能测试

```bash
cd LingoFuse/Binary

# C++ RAII / 网络 / 异步测试（50 项）
./test_lingofuse
./test_lingofuse --ci

# JSON / 线格式测试（40 项）
./test_lingofuse_json --ci

# 纯 C ABI 离线测试
./test_lingofuse_capi

# UID 身份注入端到端测试
./test_lingofuse_uid

# UID 调用约定探针（仅 Windows）
./test_uid_probe
```

一键 CI（跨平台）：

```powershell
# Windows
..\Test\run_test_ci.ps1

# Linux / macOS
../Test/run_test_ci.sh
```

**测试内容**：

| 套件 | 项数 | 覆盖内容 |
|------|:----:|----------|
| `test_lingofuse` | 50 | DataHandle、App、网络基础、网络选项、远程调用、网络事件、状态队列、并发、压力、**异步调用（8 项）** |
| `test_lingofuse_json` | 40 | JSON 序列化策略、NUL 帧字符串、字节流、三态读取、线格式不变量 |
| `test_lingofuse_capi` | ~30 | C ABI 加载、句柄、字符串、UID 双角色 ABI、本地调用 |
| `test_lingofuse_uid` | 7 | 发送方 UID 注入的端到端验证、指针-return ABI |
| `test_uid_probe` | 诊断 | 机器码前导码分析 + 安全调用验证 |

### 3.2 并发 Notify 测试

```bash
# 终端 1：启动服务端
./ConcService

# 终端 2：启动客户端（默认 8 线程 × 10000 条/批 × 20 批）
./ConcClient --threads 8 --size 10000 --batches 20
```

一键 CI：

```powershell
.\run_conc_ci.ps1
```

### 3.3 压力测试

```bash
# 终端 1：启动服务端
./StressService

# 终端 2：启动监控端（可选）
./StressMonitor

# 终端 3：启动客户端
./StressClient --threads 64
```

一键 CI（自动运行 5 个对照场景并生成对比报告）：

```powershell
.\run_stress_ci.ps1
```

### 3.4 跨进程 Demo

```bash
# 终端 1：信标
./CrossService

# 终端 2：工作节点
./CrossNode

# 终端 3：负载客户端
./CrossCall
```

### 3.5 CI 模式与退出码

所有测试程序均支持 `--ci` 参数，输出 JSON Lines 格式，退出码约定：

| 退出码 | 含义 |
|:------:|------|
| `0` | 全部 PASS |
| `1` | 存在 FAIL |
| `2` | 命令行参数错误或启动失败 |

---

## 4. 使用 C++ 接口

### 4.1 引入头文件

```cpp
#include "LingoFuse.hpp"              // RAII 封装 + 异步调用模型
#include "lf_io.hpp"                  // 统一 JSON / 字符串 I/O（可选，已被 LingoFuse.hpp 包含）
#include "lf_http_bridge_client.hpp"  // HTTP 桥接客户端（可选）
```

### 4.2 加载运行时库（必须第一步）

```cpp
int main() {
    lingofuse::LibraryLoader loader;   // 构造函数调用 LF_LoadLibrary
    // ... 所有其他操作 ...
    return 0;                          // 析构函数调用 LF_FreeLibrary
}
```

`LibraryLoader` 是引用计数的 RAII 包装，可安全地在多个模块中使用。**任何 `LF_*` 调用之前必须确保已成功加载库**。

### 4.3 DataHandle — 数据句柄

```cpp
// 创建自动回收句柄（默认，10 分钟空闲后由库自动释放）
lingofuse::DataHandle dh("my_api");

// 创建永久句柄（不会自动回收，需手动释放）
auto perm = lingofuse::DataHandle::createPermanent("my_api");

// 写入标量（小端序）
dh.write(int32_t{42});
dh.write(std::string("Hello 世界"));

// 写入 JSON
dh.writeJson({{"name", "Alice"}, {"age", 30}});

// 读取
dh.seek(0);
int32_t n;
dh.read(n);
std::string s = dh.readString();
auto j = dh.readJson();
```

### 4.4 App — 应用容器

```cpp
lingofuse::App app("MyApp", "My service");

// 注册 Call API（请求-响应）
app.registerCall("add", "Add two ints", nullptr,
    [](void*, void* in, void* out) {
        lingofuse::DataHandle in_h(static_cast<TDataHnd>(in), false);
        lingofuse::DataHandle out_h(static_cast<TDataHnd>(out), false);
        int32_t a, b;
        in_h.read(a); in_h.read(b);
        out_h.write(a + b);
    });

// 注册 Notify API（单向）
app.registerNotify("log", "Log message", nullptr,
    [](void*, void* in) {
        lingofuse::DataHandle in_h(static_cast<TDataHnd>(in), false);
        // 处理消息
    });

// 本地调用
lingofuse::DataHandle param("add");
param.write(int32_t{5});
param.write(int32_t{7});
auto result = app.localCall(param);

// 注销
app.unregister("add");
```

### 4.5 网络准备与启动

```cpp
lingofuse::setOption("Wait_Ready", "False");   // 部署模式，不阻塞等待
lingofuse::resetPrepare();

// 创建服务端（信标）
lingofuse::prepareService("ipc:my_service", "ipc:my_service");

// 创建客户端并绑定 App
lingofuse::prepareClient("ipc:my_service", app.get());

// 启动框架
if (lingofuse::prepareDone() != 1) {
    // 启动失败
}

// 等待目标 App 上线（可选）
for (int i = 0; i < 50; ++i) {
    if (lingofuse::checkApi("TargetApp", "target_api")) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
}
```

### 4.6 同步远程调用

```cpp
// 同步调用
auto resp = lingofuse::tryCall("TargetApp", param, 3000);
if (resp) {
    int32_t result;
    resp->read(result);
}

// 单向通知（不保证顺序）
lingofuse::notify("TargetApp", param);

// 有序通知（同一 (app, api) 对 FIFO）
lingofuse::sequencedNotify("TargetApp", param);
```

### 4.7 网络事件监听

```cpp
lingofuse::setNetworkEvent(
    [](const std::string& addr) {
        std::cout << "Connected: " << addr << "\n";
    },
    [](const std::string& addr) {
        std::cout << "Disconnected: " << addr << "\n";
    });

// 清除
lingofuse::clearNetworkEvent();
```

### 4.8 运行时选项

```cpp
lingofuse::setOption("Overlap_Connection", "True");       // 允许多客户端同地址
lingofuse::setOption("Wait_Connection_Timeout", "60000"); // 等待超时 60 秒
lingofuse::setOption("Quiet", "True");                    // 安静模式
```

### 4.9 状态队列

```cpp
lingofuse::postStatus("自定义日志消息");

while (lingofuse::statusCount() > 0) {
    std::string msg = lingofuse::popStatus();
    std::cout << "[LF] " << msg << "\n";
}
```

### 4.10 HTTP 桥接客户端

```cpp
#include "lf_http_bridge_client.hpp"

// 等待桥接上线
if (lingofuse::bridge::waitForBridge(nullptr, 5000)) {
    // 发送 HTTP POST
    auto envelope = lingofuse::bridge::httpPost(
        "https://api.example.com/v1/echo",
        {{"message", "Hello"}}
    );
    auto body = lingofuse::bridge::httpPostBody(
        "https://api.example.com/v1/echo",
        {{"message", "Hello"}}
    );

    // JSON 修复
    std::string repaired = lingofuse::bridge::repairJson(
        "{'name': 'Alice', 'age': 30,}"
    );
}
```

### 4.11 清理顺序

**严格遵守以下顺序**（Pascal LF-CLEAN-001）：

```cpp
lingofuse::clearNetworkEvent();   // 1. 清除网络事件
lingofuse::exitMainThread();      // 2. 停止主线程
app.close();                      // 3. 释放 App（~App 自动调用）
lingofuse::shutdown();            // 4. 关闭框架
// LibraryLoader 析构时自动调用 LF_FreeLibrary
```

在 C++ 中，利用 RAII 可自动保证顺序：

```cpp
{
    lingofuse::LibraryLoader loader;   // 最先构造，最后析构
    ShutdownGuard shutdown_guard;      // 次构造，次析构 -> LF_Shutdown
    lingofuse::App app("MyApp");       // 最后构造，最先析构 -> LF_FreeApp
    // ...
}   // 析构顺序：~App -> ~ShutdownGuard -> ~LibraryLoader
```

---

## 5. 使用异步调用模型

> **这是本次更新的核心特性**。它把 C ABI 的 `void* data` + 函数指针机制隐藏在 lambda 友好的 API 背后，让"发出调用 → 写回调体"变成一段行云流水的代码。

### 5.1 最简形式

```cpp
#include "LingoFuse.hpp"

lingofuse::callAsync("CalcSvc", "add",
    {{"a", 5}, {"b", 7}},                    // JSON payload
    [](lingofuse::AsyncResult r) {           // 回调
        if (!r.ok()) {
            std::cerr << "调用失败: " << r.error() << "\n";
            return;
        }
        auto j = r.handle().readJson();      // 拷贝数据出来
        std::cout << j.dump() << "\n";
    });
```

**三个特点**：

1. **调用和回调在同一个表达式里**——没有 `std::function`、没有手工 trampoline。
2. **只有一条错误处理路径**——`if (!r.ok())`。分派失败和远端失败都走这里。
3. **结果从"借用句柄"读出**——`.readJson()` / `.readString()` / `.readBytes()` 返回全新对象，用户从不接触裸指针。

### 5.2 四个入口点

| 函数 | 对应 C ABI | 寻址方式 |
|------|-----------|----------|
| `lingofuse::callAsync` | `LF_Async_Call` | App 名 |
| `lingofuse::callAsyncSequenced` | `LF_Async_Sequenced_Call` | App 名，FIFO 顺序 |
| `lingofuse::callAsyncByUid` | `LF_UID_Async_Call` | UID |
| `lingofuse::callAsyncByP2PName` | `LF_P2PNAME_Async_Call` | P2PName |

每个都有两个重载：**DataHandle 形式**和**便捷 JSON 形式**。

### 5.3 使用已经构造好的 DataHandle

```cpp
lingofuse::DataHandle param("add");
param.write(std::int32_t{5});
param.write(std::int32_t{7});

lingofuse::callAsync("CalcSvc", param,
    [](lingofuse::AsyncResult r) {
        if (!r.ok()) return;
        std::int32_t sum = 0;
        r.handle().read(sum);
        std::cout << "sum = " << sum << "\n";
    });

// C ABI 在调用时同步拷贝 payload，所以 param 可以立即析构。
```

### 5.4 扇出多个异步调用

```cpp
struct Aggregator {
    std::mutex m;
    std::vector<nlohmann::json> results;
    std::atomic<int> pending{0};
    std::condition_variable cv;

    void submit(int n) { pending.store(n); }

    void on_result(nlohmann::json j) {
        { std::lock_guard<std::mutex> lk(m); results.push_back(std::move(j)); }
        if (--pending == 0) cv.notify_all();
    }

    bool wait(int timeout_ms) {
        std::unique_lock<std::mutex> lk(m);
        return cv.wait_for(lk, std::chrono::milliseconds(timeout_ms),
                           [this] { return pending.load() == 0; });
    }
};

Aggregator agg;
agg.submit(16);

for (int i = 0; i < 16; ++i) {
    lingofuse::callAsync("compute_node", "exp",
        {{"base", 2.0}, {"exponent", static_cast<double>(i)}},
        [&agg](lingofuse::AsyncResult r) {
            if (r.ok()) {
                agg.on_result(r.handle().readJson());
            } else {
                agg.on_result(nlohmann::json{{"error", r.error()}});
            }
        });
}

agg.wait(10000);
```

**关键**：
- 聚合器**按引用捕获**，其生命周期必须长于所有回调——用栈对象 + 阻塞等待的模式是安全的。
- 每个回调**在回调体内**把 JSON 拷贝出来，绝不跨越回调边界保留句柄。

### 5.5 链式调用（Fire-and-Forget）

```cpp
lingofuse::callAsync("AuthSvc", "login", {{"user", "alice"}},
    [](lingofuse::AsyncResult r) {
        if (!r.ok()) return;

        // 拷贝 token 出来——我们在回调返回后还要用它。
        std::string token = r.handle().readJson()
                              .at("token").get<std::string>();

        // 在回调里发起下一个异步调用（fire-and-forget）。
        lingofuse::callAsync("DataSvc", "fetch", {{"token", token}},
            [](lingofuse::AsyncResult r2) {
                if (!r2.ok()) return;
                auto j = r2.handle().readJson();
                my_main_thread_queue.post([j]() {
                    ui_label.setText(j.dump());
                });
            });
    });
```

每一步都在返回前把需要的数据拷贝出来（`token`、`j`），没有任何东西跨越回调边界存活。

### 5.6 回调契约（必读）

`on_complete` 回调运行在 **TCompute 工作线程**上，不是调用线程，也不是模拟主线程。回调内：

| 允许 | 禁止 |
|------|------|
| 读/拷贝结果（`readJson` / `readString` / `readBytes` / `read<T>`） | 阻塞（sleep、网络 I/O、等锁） |
| 投递到你自己的线程安全队列 | 调 `LF_Call` / `LF_Notify` / `LF_LocalCall` / `LF_PrepareDone` / `LF_Shutdown` |
| 再发起一个 `callAsync*`（fire-and-forget 链） | 触碰 UI 组件 |
| 日志 / 原子操作 | 把 `r.handle()` 保留到回调体之后 |
|  | 对 `r.handle()` 调 `LF_FreeData` |

### 5.7 分派失败也走回调

如果 `LF_Async_Call` 在分派之前就拒绝请求（返回 0），C++ wrapper 会**同步在调用者线程上**触发回调，并传入一个错误 `AsyncResult`。

**这意味着**：

- 调用方无需检查 `callAsync` 的返回值——"调用失败"信号与远端失败走同一条 `if (!r.ok())` 路径。
- 回调体必须**在任意线程上都安全**（包括调用者自己的线程）。这实际上是"不阻塞 / 不调 LF_* / 不碰 UI"规则的超集，任何遵守该规则的回调都自动满足。

### 5.8 没有超时 / 取消

C ABI 的异步家族没有超时参数，也没有取消句柄。如果请求分派了但响应永远不来，holder 对象会泄漏，回调永不触发。实践中 LingoFuse 的传输层保证每个已分派的异步请求最终都会产生回调（携带结果或空 payload 的"超时"结果），所以这是理论而非实际的顾虑。需要硬超时的应用应该在上层自行实现（例如跟踪未完成请求并在配置的时间后放弃）。

### 5.9 与传统同步风格共存

新异步 API **不替代**现有的同步 API：

```cpp
// 同步（阻塞，返回结果）
auto result = lingofuse::tryCall("App", param, 3000);

// 异步（非阻塞，回调）
lingofuse::callAsync("App", param, [](lingofuse::AsyncResult r) { ... });
```

**选择原则**：

- 需要结果立刻用于下一步 → 用同步
- 需要并发多个调用 → 用异步
- 从工作线程发起调用 → **只能用异步**（工作线程里调同步 `LF_Call` 会死锁）

---

## 6. 读取发送方身份（侧数据）

> **这是本次更新的另一个核心特性**。LingoFuse 框架会在**发送方**把两个身份字段写入每个请求的载荷头部，接收方可以从回调的 `input` 参数中读取。

### 6.1 两个身份字段

| 字段 | 内容 |
|------|------|
| `FromUID` | 发送方的 32 字节会话 UID |
| `FromP2PName` | 发送方的用户定义的 P2P 组名（UTF-8） |

这两个字段是**"侧数据"**——它们**不是句柄本身的属性**，而是发送方写入载荷的元数据。

### 6.2 只在回调的 `input` 参数上有效

| 位置 | 是否有效 |
|------|:--------:|
| 回调的 `input` 参数（Call / Notify） | ✅ |
| 本地调用的 `input` | ✅ |
| 回调的 `output` 参数 | ❌（零填充 / 空字符串） |
| 你 `LF_CreateData` 出来的自建句柄 | ❌（同上） |

对无效位置调用时，库**不抛异常**，而是记录警告并返回零填充的 UID / 空字符串。

### 6.3 C++ 侧的读取方式

RAII 封装把临时的库指针隐藏起来，只返回立即拷贝：

```cpp
static void LF_CDECL whoami_cb(void*, void* in, void* out) {
    lingofuse::DataHandle inp(static_cast<TDataHnd>(in), false);
    lingofuse::DataHandle out_h(static_cast<TDataHnd>(out), false);

    // 从输入句柄读取发送方身份。只在回调体内有效。
    std::array<std::uint8_t, 32> uid = inp.getP2PUid();  // 立即拷贝
    std::string p2p_name = inp.getP2PName();             // 立即拷贝

    // uid 和 p2p_name 都是全新的对象，可以安全保留。
    std::string hex;
    hex.reserve(64);
    static const char* digits = "0123456789abcdef";
    for (auto b : uid) {
        hex.push_back(digits[(b >> 4) & 0x0F]);
        hex.push_back(digits[b & 0x0F]);
    }

    out_h.writeJson({
        {"uid_hex", hex},
        {"p2p_name", p2p_name}
    });
}
```

### 6.4 两个访问器的契约

| 访问器 | 返回 | 有效位置 |
|--------|------|----------|
| `DataHandle::getP2PUid()` | `std::array<std::uint8_t, 32>` | 仅 `input` 句柄 |
| `DataHandle::getP2PName()` | `std::string` | 仅 `input` 句柄 |

两者**都不抛异常**，**都不暴露裸指针**，**都可从任意线程调用**。

### 6.5 典型用途

| 场景 | 用法 |
|------|------|
| 调用鉴权 | 比较 `getP2PName()` 与白名单 |
| 审计日志 | 记录 `getP2PUid()`（十六进制）和 `getP2PName()` |
| 会话管理 | 以 UID 为 key 维护 Session |
| 按组路由 | 按 P2PName 分流到不同 worker |
| 多租户 | P2PName 作为租户标识 |
| whoami 探测 | 服务端返回调用方身份，客户端自我发现 |

### 6.6 C ABI 层面的细节（高级用户）

C ABI 里：

```c
const TP2P_UID* LF_Get_P2P_UID(TDataHnd hnd);  // 返回指针
const char*     LF_Get_P2P_Name(TDataHnd hnd); // 返回指针
```

- `LF_Get_P2P_UID` 返回 `const TP2P_UID*`——指向库拥有的 32 字节 UID，**调用后约 5 秒由库自动释放**。调用者必须**立即解引用并拷贝**，不得保留指针，不得释放它。
- `LF_Get_P2P_Name` 返回的指针同样约 5 秒后失效，必须立即 `strncpy` 拷贝。
- `LF_Get_P2P_UID` **不是**返回 `TP2P_UID` 值（那是旧 ABI），是返回**指针**（新 ABI，v3.2 起）。

**重要**：`TP2P_UID` 类型在 C ABI 里扮演两个不同的角色：

| 角色 | 类型 | 出现位置 |
|------|------|----------|
| **参数角色** | `TP2P_UID`（结构体，按值） | `LF_UID_Call` / `LF_Check_UID` / `LF_WriteUid` / `LF_ReadUid` |
| **返回值角色** | `const TP2P_UID*`（指针） | 仅 `LF_Get_P2P_UID` |

**不要统一这两个角色**——它们是 ABI 中不同的位置。

---

## 7. 测试报告

### 7.1 功能测试报告

**交互模式**：人类可读的详细报告，包含每个测试的 PASS/FAIL、耗时、失败原因。

**CI 模式**（`--ci`）：每行一个 JSON 对象。

单测试事件：
```json
{"event":"test","suite":"test_lingofuse","index":1,"total":50,"category":"DataHandle","name":"DataHandle :: basic types","status":"PASS","elapsed_ms":12}
```

套件汇总：
```json
{"event":"summary","suite":"test_lingofuse","total":50,"passed":50,"failed":0,"elapsed_sec":52.234,"status":"PASS"}
```

一键脚本 `run_test_ci.ps1` 输出对比表：
```
======================================================================
  LingoFuse Functional Test -- CI Summary
======================================================================

  Suite                           Total   Passed   Failed    Time(s)   Status
  ---------------------------- -------- -------- -------- ---------- --------
  test_lingofuse                     50       50        0      52.23     PASS
  test_lingofuse_json                40       40        0       0.85     PASS
  ---------------------------- -------- -------- -------- ---------- --------
  TOTAL                              90       90        0      53.08     PASS

======================================================================
  RESULT: ALL TESTS PASSED
======================================================================
```

### 7.2 并发 Notify 测试报告

`run_conc_ci.ps1` 生成 `conc_ci_report.jsonl`，包含 Service 和 Client 的所有事件。

**实测基线**（Windows x64，LingoFuse v3.10）：
- 8 线程 × 10000 条/批 × 20 批 → **4,454 notify/s**
- 单条 notify 延迟：P50 = 666 μs，P95 = 858 μs
- 累计 200,000 条 notify，**零丢失**
- 完成屏障每次 700–1100 ms

### 7.3 压力测试报告

`run_stress_ci.ps1` 生成 `stress_ci_summary.txt`，包含对比表与自动观察结论。

**实测基线**（Windows x64，LingoFuse v3.10）：

| 场景 | 线程 | 时长 | Notify/s | Call/s | 成功率 | Status |
|------|:----:|:----:|:--------:|:------:|:------:|:------:|
| Pure Notify | 32 | 15s | 5,446 | — | — | PASS |
| Pure Call @32 | 32 | 15s | — | 236 | 100% | PASS |
| Pure Call @128 | 128 | 15s | — | 817 | 100% | PASS |
| Pure Call @512 | 512 | 15s | — | 1,166 | 100% | PASS |
| Mixed 20:1 | 64 | 30s | 4,153 | 207 | 100% | PASS |

**关键结论**：
- 单进程单端点 **Notify 上限约 5,500/s**
- 单进程单端点 **Call 上限约 1,200/s**
- Notify/Call 吞吐比约 **5×**
- Call 在 128 线程附近开始饱和

### 7.4 CI 集成示例

```yaml
- name: LingoFuse functional tests
  working-directory: LingoFuse/Binary
  shell: pwsh
  run: |
    ..\Test\run_test_ci.ps1 -Quiet

- name: LingoFuse concurrent notify test
  working-directory: LingoFuse/Binary
  shell: pwsh
  run: |
    .\run_conc_ci.ps1 -Batches 20 -Size 10000 -Threads 8 -Quiet

- name: LingoFuse stress self-evaluation
  working-directory: LingoFuse/Binary
  shell: pwsh
  run: |
    .\run_stress_ci.ps1 -Quiet
```

---

## 8. 故障排查

### 8.1 加载失败

**现象**：`LingoFuse: Failed to load LingoFuse64.dll`
**解决**：将运行时库复制到可执行文件同目录，或加入 `PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`。

### 8.2 回调崩溃

**原因**：回调未使用 `LF_CDECL` 调用约定，导致栈错乱。
**解决**：所有同步回调必须声明为 `LF_CDECL`（即 `__cdecl`）。异步回调由 wrapper 自动处理。

### 8.3 死锁

**原因**：在回调中调用了阻塞型 LingoFuse 函数（如 `LF_Call`）。
**解决**：
- 同步场景：把耗时操作放到独立线程。
- 异步场景：用 `lingofuse::callAsync` 发起链式调用（fire-and-forget），不要用同步 `LF_Call`。

### 8.4 清理顺序错误

**现象**：关闭时崩溃或重启后地址占用。
**解决**：严格遵守 `clearNetworkEvent → exitMainThread → ~App → shutdown → ~LibraryLoader` 顺序。

### 8.5 Overlap_Connection 陷阱

**现象**：多个 App 绑定到同一地址时，第二个 App 被静默忽略。
**解决**：在 `prepareClient` 之前设置 `setOption("Overlap_Connection", "True")`。

### 8.6 远程调用超时

**现象**：`tryCall` 返回 `nullopt`。
**排查**：
- 使用 `checkApi` 确认目标已上线（注意 3 秒广播延迟）。
- 检查 `Wait_Connection_Timeout` 是否过短。
- 确认目标 App 名和 API 名正确。

### 8.7 JSON 中文乱码

**原因**：绕过了 `lf_io` 直接调用底层 API。
**解决**：始终通过 `lingofuse::io::write_json` / `read_json` 处理 JSON，保证 UTF-8 字面输出且无 `\uXXXX` 转义。

### 8.8 异步回调从没被调用

**排查顺序**：

1. **检查 `callAsync*` 是否被实际执行**——在里面打日志。
2. **启用 `ShowThreadID=True` + `Quiet=False`**——看 worker 线程上有没有回调日志。
3. **确认不是在回调里调用了阻塞函数**——会占用整个 worker 线程池。
4. **如果请求分派成功但从没回调**——那是传输层问题；查看状态队列里的 `[LF-DEBUG]` 追踪。
5. **对照 `test_async_call_dispatch_failure`**：那个测试用"无 client 环境"验证分派失败路径确实会同步触发回调。

### 8.9 P2P 身份为空

**现象**：`getP2PUid()` 返回全零，`getP2PName()` 返回空字符串。
**排查**：
1. **确认在 `input` 句柄上调用**——不要在 `output` 句柄或自建句柄上调用。
2. **确认发送方设置了 `LF_P2P_name`**——`setOption("LF_P2P_name", "my_group")`。
3. **确认 UID 已生成**——`Wait_Connection_ReadyOk` 保持默认值（`True`），让 `prepareDone` 阻塞直到客户端上线。
4. **查看状态队列**——C 侧会打印 `[warning] Get_P2P_UID(): P2P Info only backcall "input" parameter.`。

### 8.10 异步回调外泄 `AsyncResult::handle()`

**现象**：把 `r.handle()` 的引用或裸指针传出去，稍后使用出现 use-after-free。
**根因**：`AsyncResult::handle()` 是**借用**，回调返回后框架立即释放底层缓冲区。
**解决**：在回调体内把数据**拷贝出来**：

```cpp
// ❌ 错误：保留句柄引用
lingofuse::DataHandle* saved = nullptr;
lingofuse::callAsync("App", param,
    [&saved](lingofuse::AsyncResult r) {
        saved = &r.handle();      // ❌ 回调返回后失效
    });

// ✅ 正确：立即拷贝
nlohmann::json saved;
lingofuse::callAsync("App", param,
    [&saved](lingofuse::AsyncResult r) {
        saved = r.handle().readJson();  // ✅ 全新对象
    });
```

---

## 9. 许可

MIT License。详见仓库根目录 `LICENSE` 文件。

---

## 延伸阅读

| 文档 | 内容 |
|------|------|
| `LingoFuse_Cpp_Knowledge_Base.md` | C++ 接口完整参考（v8.0，50 项测试详解） |
| `LingoFuse_Pascal_Complete_Guide.md` | Pascal 接口与内部机制 |
| `test/LingoFuse_Functional_Test_Guide.md` | 功能测试详解与 CI 基线 |
| `Conc/LingoFuse_Concurrent_Notify_Demo.md` | 并发 Notify 模式与完成屏障 |
| `Stress/LingoFuse_Stress_Test_Guide.md` | Stress 测试套件与实测基线 |
| `json.hpp.md` | nlohmann/json 参考 |

---

*本文档基于 LingoFuse v3.10 C/C++ 绑定整理。所有代码示例使用英文注释，符合源码契约。*
