# LingoFuse C/C++ 接口 README

> 跨语言通讯地基的 C/C++ 官方绑定。基于 C ABI 和 C++17 RAII 封装，提供类型安全、资源自动管理、跨平台的高性能 RPC 调用能力。

---

## 目录

1. [环境准备](#1-环境准备)
2. [编译](#2-编译)
3. [测试](#3-测试)
4. [使用 C++ 接口](#4-使用-c-接口)
5. [测试报告](#5-测试报告)
6. [故障排查](#6-故障排查)
7. [许可](#7-许可)

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
├── LingoFuse.hpp               # C++17 RAII 封装
├── lf_io.hpp                   # 统一 JSON / 字符串 I/O
├── lf_http_bridge_client.hpp   # HTTP 桥接客户端
├── json.hpp                    # nlohmann/json 单文件
├── CMakeLists.txt              # 顶层构建脚本
├── CrossDemo/                  # 跨进程 Demo
├── Conc/                       # 并发 Notify 演示与 CI
├── Stress/                     # 压力测试套件
└── test/                       # 功能测试套件
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
| `test_lingofuse` | EXECUTABLE | 功能测试（42 项） |
| `test_lingofuse_json` | EXECUTABLE | JSON / 线格式测试（40 项） |
| `ConcService` / `ConcClient` | EXECUTABLE | 并发 Notify 演示 |
| `StressService` / `StressClient` / `StressMonitor` | EXECUTABLE | 压力测试三件套 |
| `CrossService` / `CrossNode` / `CrossCall` | EXECUTABLE | 跨进程 Demo |

### 2.3 编译选项

CMake 自动为 MSVC 添加 `/W4 /permissive-`，为 GCC/Clang 添加 `-Wall -Wextra`。如需自定义，可在 `CMakeLists.txt` 中修改。

---

## 3. 测试

### 3.1 功能测试

运行全部功能测试：

```bash
cd LingoFuse/Binary
./test_lingofuse          # 交互模式
./test_lingofuse --ci     # CI 模式（JSON Lines 输出，退出码 0/1）
./test_lingofuse_json --ci
```

或使用一键 CI 脚本：

```powershell
# Windows
.\run_test_ci.ps1

# Linux / macOS
./run_test_ci.sh
```

**测试内容**：
- `test_lingofuse`：42 项，覆盖 DataHandle、App、网络基础、网络选项、远程调用、网络事件、状态队列、并发、压力。
- `test_lingofuse_json`：40 项，覆盖 JSON 序列化策略、NUL 帧字符串、字节流、三态读取、线格式不变量。

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
#include "LingoFuse.hpp"          // RAII 封装：DataHandle / App / LibraryLoader
#include "lf_io.hpp"              // 统一 JSON / 字符串 I/O（可选，LingoFuse.hpp 已包含）
#include "lf_http_bridge_client.hpp" // HTTP 桥接客户端（可选）
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

### 4.6 远程调用

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
lingofuse::setOption("Overlap_Connection", "True");      // 允许多客户端同地址
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

## 5. 测试报告

### 5.1 功能测试报告

**交互模式**：人类可读的详细报告，包含每个测试的 PASS/FAIL、耗时、失败原因。

**CI 模式**（`--ci`）：每行一个 JSON 对象。

单测试事件：
```json
{"event":"test","suite":"test_lingofuse","index":1,"total":42,"category":"DataHandle","name":"DataHandle :: basic types","status":"PASS","elapsed_ms":12}
```

套件汇总：
```json
{"event":"summary","suite":"test_lingofuse","total":42,"passed":42,"failed":0,"elapsed_sec":45.234,"status":"PASS"}
```

一键脚本 `run_test_ci.ps1` 输出对比表：
```
======================================================================
  LingoFuse Functional Test -- CI Summary
======================================================================

  Suite                           Total   Passed   Failed    Time(s)   Status
  ---------------------------- -------- -------- -------- ---------- --------
  test_lingofuse                     42       42        0      45.23     PASS
  test_lingofuse_json                40       40        0       0.85     PASS
  ---------------------------- -------- -------- -------- ---------- --------
  TOTAL                              82       82        0      46.08     PASS

======================================================================
  RESULT: ALL TESTS PASSED
======================================================================
```

### 5.2 并发 Notify 测试报告

`run_conc_ci.ps1` 生成 `conc_ci_report.jsonl`，包含 Service 和 Client 的所有事件。

**实测基线**（Windows x64，LingoFuse v3.10）：
- 8 线程 × 10000 条/批 × 20 批 → **4,454 notify/s**
- 单条 notify 延迟：P50 = 666 μs，P95 = 858 μs
- 累计 200,000 条 notify，**零丢失**
- 完成屏障每次 700–1100 ms

### 5.3 压力测试报告

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

### 5.4 CI 集成示例

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

## 6. 故障排查

### 6.1 加载失败

**现象**：`LingoFuse: Failed to load LingoFuse64.dll`
**解决**：将运行时库复制到可执行文件同目录，或加入 `PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`。

### 6.2 回调崩溃

**原因**：回调未使用 `LF_CDECL` 调用约定，导致栈错乱。
**解决**：所有回调必须声明为 `LF_CDECL`（即 `__cdecl`）。

### 6.3 死锁

**原因**：在回调中调用了阻塞型 LingoFuse 函数（如 `LF_Call`）。
**解决**：将耗时或远程调用操作放到独立线程中执行，回调内只做快速处理。

### 6.4 清理顺序错误

**现象**：关闭时崩溃或重启后地址占用。
**解决**：严格遵守 `clearNetworkEvent → exitMainThread → ~App → shutdown → ~LibraryLoader` 顺序。

### 6.5 Overlap_Connection 陷阱

**现象**：多个 App 绑定到同一地址时，第二个 App 被静默忽略。
**解决**：在 `prepareClient` 之前设置 `setOption("Overlap_Connection", "True")`。

### 6.6 远程调用超时

**现象**：`tryCall` 返回 `nullopt`。
**排查**：
- 使用 `checkApi` 确认目标已上线（注意 3 秒广播延迟）。
- 检查 `Wait_Connection_Timeout` 是否过短。
- 确认目标 App 名和 API 名正确。

### 6.7 JSON 中文乱码

**原因**：绕过了 `lf_io` 直接调用底层 API。
**解决**：始终通过 `lingofuse::io::write_json` / `read_json` 处理 JSON，保证 UTF-8 字面输出且无 `\uXXXX` 转义。

---

## 7. 许可

MIT License。详见仓库根目录 `LICENSE` 文件。

---

*本文档基于 LingoFuse v3.10 C/C++ 绑定整理。更详细的接口参考、内部机制、跨语言对比请参阅 `LingoFuse_Cpp_Knowledge_Base.md` 及相关测试指南。*