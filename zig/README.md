# LingoFuse Zig 绑定

> **Zig 语言官方绑定，与 Pascal / C++ / C# / Rust / Go / Python / JavaScript 实现逐字节兼容的线格式。**
>
> 版本：v1.1（阶段 1–7 + v0.4 增量升级：UID 类型、P2P 身份、typed options、进程级 P2P 注册、异步调用家族）
> Native 库：LingoFuse v3.10 / C4 v4.01
> 目标 Zig 版本：0.17.0

---

## 目录

1. [项目结构](#1-项目结构)
2. [环境搭建](#2-环境搭建)
3. [编译器版本要求](#3-编译器版本要求)
4. [验证环境](#4-验证环境)
5. [c 目录代码确认](#5-c-目录代码确认)
6. [编译器确认](#6-编译器确认)
7. [测试](#7-测试)
8. [Cross Demo 三件套](#8-cross-demo-三件套)
9. [v0.4 新能力速览](#9-v04-新能力速览)
10. [C# 端使用 typed options](#10-c-端使用-typed-options)
11. [故障排查](#11-故障排查)
12. [已知限制](#12-已知限制)

---

## 1. 项目结构

```
zig/
├── build.zig                    # 构建脚本
├── build.zig.zon                # 包描述
├── build.ps1                    # 一键编译
├── test.ps1                     # 一键测试
├── clean.ps1                    # 一键清理
├── README.md                    # 本文件
│
├── c/                           # C / C++ 依赖
│   ├── LingoFuse.h              # LingoFuse C ABI 头文件
│   ├── LingoFuse.c              # LingoFuse 动态加载器
│   ├── LingoFuse_Opt.h          # (v0.4 新增) typed set_opt_* / get_opt_* 的 C 封装层
│   ├── lf_json.h                # nlohmann/json 的 C ABI 头文件
│   ├── lf_json.cpp              # nlohmann/json 的 C ABI 实现
│   └── json.hpp                 # nlohmann/json 单文件版（外部依赖）
│
├── src/                         # 绑定源码
│   ├── lingofuse.zig            # 模块根：顶层 re-export
│   ├── sys.zig                  # 59 个 C ABI 函数的手写 extern 声明
│   ├── error.zig                # 错误集
│   ├── util.zig                 # (v0.4 新增) 共享 helper（dupeZ / copyCstr）
│   ├── uid.zig                  # (v0.4 新增) 32 字节 UID 值类型
│   ├── data_handle.zig          # RAII 数据句柄（含 P2P 身份访问器）
│   ├── app_handle.zig           # RAII 应用句柄 + 回调 trampoline
│   ├── framework.zig            # 进程级 facade（三套寻址）
│   ├── io.zig                   # 统一 JSON / 字符串 / 字节 I/O
│   ├── json_c.zig               # lf_json C ABI 的 extern 声明
│   ├── network_events.zig       # 进程级网络事件
│   ├── status.zig               # 状态队列
│   ├── options.zig              # (v0.4 新增) 类型化选项
│   ├── p2p.zig                  # (v0.4 新增) 进程级 P2P 注册
│   └── async_call.zig           # (v0.4 新增) 现代化异步调用
│
├── examples/                    # 可执行示例 / 测试
│   ├── abi_smoke.zig            # ABI 冒烟测试（35 步）
│   ├── io_smoke.zig             # 统一 I/O 冒烟测试（18 步）
│   ├── json_smoke.zig           # lf_json C ABI 冒烟测试（43 步）
│   ├── network_events_smoke.zig # 网络事件冒烟测试（6 步）
│   ├── status_smoke.zig         # 状态队列冒烟测试（5 步）
│   ├── uid_smoke.zig            # (v0.4) UID 值类型冒烟测试（10 步）
│   ├── identity_smoke.zig       # (v0.4) P2P 身份侧数据冒烟测试（2 步）
│   ├── options_smoke.zig        # (v0.4) 类型化选项冒烟测试（9 步）
│   ├── async_smoke.zig          # (v0.4) 异步调用家族冒烟测试（6 步）
│   ├── p2p_smoke.zig            # (v0.4) 进程级 P2P 注册冒烟测试（6 步）
│   ├── addressing_smoke.zig     # (v0.4) 三套寻址冒烟测试（7 步）
│   ├── cross_service.zig        # Cross Demo 协调器
│   ├── cross_node.zig           # Cross Demo 工作节点
│   └── cross_call.zig           # Cross Demo 负载客户端
│
└── tests/
    └── test_abi.zig             # Zig 原生单元测试（仅纯逻辑，24 个）
```

**分层原则**：

```
应用层      用户代码
            ↓ import "lingofuse"
高层封装    io / network_events / status / options / p2p / async_call
            framework / app_handle / data_handle
            ↓
类型层      Uid / Error / util
            ↓
FFI 层      sys（唯一直接调用 native 的模块）/ json_c
            ↓
Native 库   LingoFuse64.dll（+ z_ipc_64.dll）/ lf_json（静态链接进 exe）
```

---

## 2. 环境搭建

### 2.1 获取源码

```powershell
git clone https://github.com/PassByYou888/LingoFuse.git
cd LingoFuse\zig
```

### 2.2 获取 `json.hpp`

本项目不自带 nlohmann/json 单文件版，需要手动下载：

1. 打开 https://github.com/nlohmann/json/releases
2. 下载最新 release 里的 `json.hpp`（约 900 KB）
3. 放到 `zig/c/json.hpp`

**版本要求**：3.11 或更高（本项目在 3.12.0 上验证）。

### 2.3 获取 Native 库

需要以下文件（与 LingoFuse 主仓库的 `Binary/` 目录一致）：

| 平台 | 主库 | IPC 依赖 |
|------|------|----------|
| Windows 64 位 | `LingoFuse64.dll` | `z_ipc_64.dll` |
| Windows 32 位 | `LingoFuse32.dll` | `z_ipc_32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` |

**放置位置**（按加载器搜索顺序）：

1. 可执行文件所在目录（`zig-out\bin\`）
2. 系统 `PATH`（Windows）/ `LD_LIBRARY_PATH`（Linux）/ `DYLD_LIBRARY_PATH`（macOS）

**最省事的做法**：把 `LingoFuse\Binary\` 目录加入系统 `PATH`：

```powershell
# Windows PowerShell（仅当前会话有效）
$env:PATH = "D:\CoreLibrary\LingoFuse\Binary;$env:PATH"
```

### 2.4 安装 Zig

见第 3 节。

### 2.5 一键验证

```powershell
cd D:\CoreLibrary\LingoFuse\zig
.\build.ps1        # 编译所有产物
.\test.ps1         # 运行所有测试套件
```

若 `build.ps1` 输出 `Build succeeded.` 且 `test.ps1` 输出 `RESULT: ALL SUITES PASSED`，环境搭建完成。

---

## 3. 编译器版本要求

| 组件 | 最低版本 | 推荐版本 | 备注 |
|------|:--------:|:--------:|------|
| **Zig** | 0.17.0 | 0.17.0 | 见下方说明 |
| C 编译器 | 任意 | MinGW-w64 / MSVC 2019+ | Zig 自带 `zig cc` 可满足 |
| C++ 编译器 | C++17 支持 | 任意 | 同上 |
| nlohmann/json | 3.11.0 | 3.12.0 | 单文件版 |
| PowerShell | 5.1 | 7.x | 仅用于脚本 |
| 操作系统 | Windows 10 x64 | Windows 10/11 x64 | Linux/macOS 待验证 |

### 3.1 为什么锁定 Zig 0.17.0

本项目在开发过程中发现 **Zig 0.17 引入了多项破坏性 API 变更**，与旧版本不兼容：

| 变更 | 影响 | 本绑定应对 |
|------|------|-----------|
| 移除 `@cImport` | 必须手写 `extern fn` | `src/sys.zig` 的 59 个声明 |
| 移除 `std.meta.fields` | 反射 struct 字段必须探测 `@typeInfo(T).@"struct"` 的实际布局 | `src/io.zig` 的 `serializeJson` |
| 移除 `std.mem.Allocator.dupeZ` | 用本地 `dupeZ` helper | `src/util.zig` 的 `dupeZ` |
| 移除 `std.time.Timer` / `milliTimestamp` | 用 C / Windows API | `src/async_call.zig` 用 `GetTickCount64` |
| 移除 `std.Thread.sleep` | 用 Windows `Sleep(ms)` | `src/async_call.zig` + `cross_call.zig` |
| `std.json.parseFromSlice` 默认别名输入 | 必须显式传 `.allocate = .alloc_always` | `src/io.zig` 的 `readJson` / `loadsJson` |
| `std.ArrayListUnmanaged` 新增字段 | 无法用 `.{ }` 初始化 | 项目不使用 ArrayList |
| 自定义 `format` 方法签名变化 | `std.fmt` 不再识别旧签名 | 不实现自定义 `format`；用 `toHexBuf` 等显式 helper |
| **`**` 运算符空格要求** | `**` 两侧空格必须对称；编辑器/文本往返可能破坏 | **全项目禁用 `**`**；用 `@splat` / `@memset` 填充 |

**升级 Zig 版本前**，需要重新评估以上每一项。项目会在 `build.zig` 与 `README` 中同步记录。

### 3.2 Zig 安装

```powershell
# 下载后解压到任意目录，例如 D:\zig-x86_64-windows-0.17.0\
# 然后加入 PATH
[Environment]::SetEnvironmentVariable(
    "PATH",
    "D:\zig-x86_64-windows-0.17.0;" + [Environment]::GetEnvironmentVariable("PATH", "User"),
    "User"
)

# 验证
zig version
# 期望输出：0.17.0
```

### 3.3 C++ 编译器

Zig 内置 `zig cc` / `zig c++`，无需单独安装 C++ 编译器。`build.zig` 通过 `m.link_libcpp = true` 让 Zig 自动使用内置的 C++ 运行库。

---

## 4. 验证环境

### 4.1 开发验证环境

| 项 | 值 |
|----|-----|
| 操作系统 | Windows 10 x64 |
| Zig | 0.17.0（`D:\zig-x86_64-windows-0.17.0\zig.exe`） |
| PowerShell | 5.1 |
| Native 库 | `LingoFuse64.dll`（v3.10）+ `z_ipc_64.dll` |
| nlohmann/json | 3.12.0 |
| 编辑器 | VS Code + `ziglang.vscode-zig` 扩展 |

### 4.2 验证结果

所有测试在此环境下 100% 通过：

| 套件 | 通过数 | 状态 |
|------|:------:|:----:|
| `zig build test` | 24 | ✅ |
| `zig build smoke` | 35 | ✅ |
| `zig build io-smoke` | 18 | ✅ |
| `zig build json-smoke` | 43 | ✅ |
| `zig build network-events-smoke` | 6 | ✅ |
| `zig build status-smoke` | 5 | ✅ |
| `zig build uid-smoke` | 10 | ✅ |
| `zig build identity-smoke` | 2 | ✅ |
| `zig build options-smoke` | 9 | ✅ |
| `zig build async-smoke` | 6 | ✅ |
| `zig build p2p-smoke` | 6 | ✅ |
| `zig build addressing-smoke` | 7 | ✅ |
| **合计** | **171** | ✅ |

### 4.3 未验证环境（诚实声明）

| 环境 | 状态 | 说明 |
|------|:----:|------|
| Windows 32 位 | ⏳ 未验证 | 需要 32 位 Native 库 |
| Linux x64 | ⏳ 未验证 | `cross_call.zig` / `async_call.zig` 用 Windows `Sleep` / `GetTickCount64`，需替换 |
| macOS | ⏳ 未验证 | 同上 |
| Zig 0.18+ | ⏳ 未验证 | 需重跑破坏性变更清单 |
| 大端架构 | ⏳ 未验证 | 协议约定小端，大端平台需显式转换 |

---

## 5. c 目录代码确认

### 5.1 `c/LingoFuse.h` / `c/LingoFuse.c`

**来源**：从 LingoFuse 主仓库的 C/C++ 绑定目录复制，**与本绑定开发无关的原始文件**。

| 项 | 值 |
|----|-----|
| 用途 | LingoFuse C ABI 的动态加载器（`LF_LoadLibrary` 等） |
| 导出函数 | 59 个 `LF_*` |
| 是否修改 | ❌ 未修改，逐字节保持原样 |
| 验证方式 | `src/sys.zig` 的 59 个 `extern fn` 声明与 `LingoFuse.h` 一一对应 |

**确认方式**：

```powershell
# 打开 c/LingoFuse.h，搜索 "LF_" 前缀的函数声明
# 数量应为 59，加上两个 loader 函数（LF_LoadLibrary / LF_FreeLibrary）合计 61
Select-String -Path c\LingoFuse.h -Pattern "^\s*(TDataHnd|TAppHnd|void|int|int64_t|const char\*)\s+LF_" | Measure-Object
```

### 5.2 `c/lf_json.h` / `c/lf_json.cpp`

**来源**：本项目**新增**，为 Zig 提供 nlohmann/json 的 C ABI 封装。

| 项 | 值 |
|----|-----|
| 用途 | 让 Zig 直接调用 C++ 的 nlohmann/json，保证 JSON 序列化与 C++ binding 逐字节一致 |
| 设计 | 用**不透明句柄**（`TJsonHnd` / `TJsonWriter`）替换 C++ 对象 |
| 异常处理 | 所有 C++ 异常在 ABI 边界内被捕获，返回 NULL / -1 / 0 |
| 线程安全 | 不同句柄独立；同一句柄写入需外部同步 |
| 覆盖范围 | 解析、序列化、类型查询、值读取、对象/数组访问、DOM 构建、流式 writer |

### 5.3 `c/LingoFuse_Opt.h`（v0.4 新增）

**来源**：本项目**新增**，为 C / C++ 提供 typed `set_opt_*` / `get_opt_*` 的**头文件封装**。

| 项 | 值 |
|----|-----|
| 用途 | 把 `LF_SetOption("Quiet", "True")` 这样的字符串调用包装为 `LF_Set_Opt_Quiet(1)` |
| 设计 | **header-only**；每个函数 `static inline`，不引入新导出符号 |
| 覆盖范围 | 16 组 typed pair（Quiet / ShowThreadID / Wait_Connection_Timeout / IPC / P2P / DataHandle 等） |
| C# 用户 | **不能直接 P/Invoke inline 函数**；见第 10 节 |

### 5.4 `c/json.hpp`

**来源**：从 nlohmann/json 官方 releases 下载的单文件版。

| 项 | 值 |
|----|-----|
| 版本 | 3.12.0 |
| 大小 | 约 920 KB |
| 是否修改 | ❌ 未修改 |

---

## 6. 编译器确认

### 6.1 Zig 编译器

```powershell
zig version
# 必须输出 0.17.0（本项目只在 0.17.0 上验证）
```

### 6.2 C 编译器（Zig 内置）

Zig 自带 C 编译器，`build.zig` 通过 `addCSourceFile` 编译 `c/LingoFuse.c`。

### 6.3 C++ 编译器（Zig 内置）

`build.zig` 通过 `addCSourceFile(.{ .file = b.path("c/lf_json.cpp"), .flags = &.{"-std=c++17"} })` 编译 `lf_json.cpp`，并通过 `m.link_libcpp = true` 链接 C++ 运行库。

### 6.4 编译器确认清单

| 项 | 命令 | 期望 |
|----|------|------|
| Zig 版本 | `zig version` | `0.17.0` |
| C 编译器 | `.\build.ps1` | `Build succeeded.` |
| C++ 编译器 | `.\test.ps1` | `RESULT: ALL SUITES PASSED` |
| Native 库 | `Test-Path LingoFuse64.dll` 或 `where.exe LingoFuse64.dll` | 输出路径 |
| `z_ipc_64.dll` | `where.exe z_ipc_64.dll` | 输出路径 |
| `json.hpp` | `Test-Path c\json.hpp` | `True` |

---

## 7. 测试

### 7.1 测试运行方式

```powershell
# 一键运行所有套件
.\test.ps1

# 单独运行某个套件
zig build test                     # Zig 原生单元测试（纯逻辑）
zig build smoke                    # ABI 冒烟测试
zig build io-smoke                 # 统一 I/O 冒烟测试
zig build json-smoke               # lf_json C ABI 冒烟测试
zig build network-events-smoke     # 网络事件冒烟测试
zig build status-smoke             # 状态队列冒烟测试
zig build uid-smoke                # UID 值类型冒烟测试
zig build identity-smoke           # P2P 身份侧数据冒烟测试
zig build options-smoke            # 类型化选项冒烟测试
zig build async-smoke              # 异步调用家族冒烟测试
zig build p2p-smoke                # 进程级 P2P 注册冒烟测试
zig build addressing-smoke         # 三套寻址冒烟测试
```

### 7.2 为什么 `test_abi.zig` 只能放纯逻辑测试

**铁律**：`tests/test_abi.zig` 中**不允许**出现任何需要 native 库的测试。

**根因**：Zig test runner 在 Windows 上有两个已知问题：

1. **stdout 传输争用**：native LingoFuse 库写诊断到控制台时，可能与 test runner 的 stdout 传输争用，导致**卡死**（无输出、不返回）。
2. **log 级别误判**：test runner 默认 `std.testing.log_level = .warn`，任何 ≥ warn 的日志（包括回调 trampoline 里的 `std.log.err`）都会被判定为测试失败。**不存在比 `.err` 更高的级别可以抑制**。

**规避方案**：所有需要 native 库的测试必须改写为**普通程序**（`examples/*_smoke.zig`）：

- 每步前后写日志文件（C stdio + `fflush`），卡死时日志文件保留现场
- 不用 Zig test runner，因此不受 log 级别规则约束
- 退出码约定：0 = 全过，1 = 有失败，2 = 无法打开日志文件

**`tests/test_abi.zig` 唯一能放的是**：
- 纯数据结构测试（`Uid` 值类型、`AsyncResult` tagged union）
- re-export 存在性检查（`@hasDecl`）
- 不调用 `lf.framework.init()` 的测试

如果误把集成测试放进去，`zig build test` 会**卡死**在第一步。

### 7.3 测试项总览

| 套件 | 步数 | 层 | 应用领域 |
|------|:----:|-----|---------|
| `test_abi` | 24 | 单元测试（纯逻辑） | Uid 值类型、AsyncResult、re-export 存在性 |
| `smoke` | 35 | ABI 集成 | 完整 C ABI 契约、回调、绑定 |
| `io-smoke` | 18 | I/O 层 | 字符串帧、JSON 线格式、容错读取 |
| `json-smoke` | 43 | JSON 引擎 | nlohmann 完整 API 面、字节级兼容 |
| `network-events-smoke` | 6 | 网络事件 | 安装 / 查询 / 清除生命周期 |
| `status-smoke` | 5 | 状态队列 | 计数、投递、读取、批量拉取 |
| `uid-smoke` | 10 | UID 类型 | 构造 / hex / ABI 桥接 / 比较 |
| `identity-smoke` | 2 | 身份侧数据 | owning 句柄 / callback input+output |
| `options-smoke` | 9 | 类型化选项 | 16 组 typed pair 的代表性覆盖 |
| `async-smoke` | 6 | 异步调用 | 回调式 / 阻塞式 / 单一错误路径 |
| `p2p-smoke` | 6 | 进程级 P2P 注册 | 注册 / 注销 / 重名 / 重注册 / namespace 独立性 |
| `addressing-smoke` | 7 | 三套寻址 | App 名 / UID / P2PName + 查询（含负路径） |
| **合计** | **171** | — | — |

### 7.4 判断测试是否真实运行

**陷阱**：当 native 库缺失时，部分集成测试会打印 `[SKIP]` 并返回成功。**测试显示 `ok` 不代表真实运行过**。

**判断方法**：

```powershell
# 运行并抓取日志
zig build smoke 2>&1 | Select-String "SKIP"

# 无输出 → native 库已加载，测试真实运行 ✅
# 输出 [SKIP] → native 库未找到，测试被跳过 ⚠️
```

**更可靠的方法**：查看测试产出的日志文件：

```powershell
Get-Content abi_smoke.log | Select-Object -First 20
Get-Content uid_smoke.log | Select-Object -First 20
```

日志的第一行应是 `LingoFuse Zig ... smoke test`，随后每一步前后都有 `[step]` / `[ok]` 记录。

### 7.5 串行 vs 并行

- `zig build test`（纯逻辑）可以并行
- 所有 smoke 测试**必须串行运行**（它们都启动 framework 的模拟主线程）

**推荐**：`.\test.ps1` 已经按顺序串行调用所有套件。

---

## 8. Cross Demo 三件套

### 8.1 目的

Cross Demo 是**跨进程、跨语言**的端到端验证。它对齐 C++ / C# / Rust / Go / JavaScript / Pascal / Python 的同名 demo，验证 Zig 绑定与其它语言绑定的**字节级互通**。

### 8.2 三个程序

| 程序 | 角色 | 职责 |
|------|------|------|
| `cross_service` | 协调器 | 创建 IPC 端点 `ipc:cross`，作为发现锚点 |
| `cross_node` | 工作节点 | 注册 `add` / `inv_seri` 两个 API，暴露为应用 `demo` |
| `cross_call` | 负载客户端 | 32 线程并发调用 `demo`，跑 10 秒，输出吞吐 |

### 8.3 注册的 API

#### `add(int32, int32) → int32`

```
请求：int32 LE + int32 LE
响应：int32 LE
```

#### `inv_seri(...) → 反转序列`

```
请求：uint8 + uint16 LE + uint32 LE + uint64 LE + string(NUL) + float32 LE
响应：float32 LE + string(NUL) + uint64 LE + uint32 LE + uint16 LE + uint8
```

**字符串是 UTF-8 编码，以 `0x00` 结尾。所有整数和浮点数都是小端序。**

### 8.4 单语言运行（全部 Zig）

**第一步：编译**

```powershell
cd D:\CoreLibrary\LingoFuse\zig
.\build.ps1
# 或
zig build cross-service cross-node cross-call
```

产物在 `zig-out\bin\`：

```
cross_service.exe
cross_node.exe
cross_call.exe
```

**第二步：三个终端，按顺序**

```powershell
cd D:\CoreLibrary\LingoFuse\zig\zig-out\bin
```

**终端 1 — 协调器**：

```powershell
.\cross_service.exe
# 等 "[Service] IPC service 'ipc:cross' is running. Press Enter to exit..."
```

**终端 2 — 工作节点**：

```powershell
.\cross_node.exe
# 等 "[Node] Online. Press Enter to exit..."
```

**终端 3 — 负载客户端**：

```powershell
.\cross_call.exe
# 10 秒后自动打印 summary
```

**第三步：关闭顺序**（与启动相反）

1. 关 **客户端**（cross_call）— 按 Enter
2. 关 **节点**（cross_node）— 按 Enter
3. 关 **协调器**（cross_service）— 按 Enter

每个程序退出时会自动按 `ExitMainThread → app.deinit → shutdown → deinit` 顺序清理（LF-CLEAN-001）。

### 8.5 跨语言运行

把三个终端中的任意一个替换成其它语言的实现即可。例如：

**混合 A**：Zig 协调器 + C++ 节点 + Zig 客户端

**混合 B**：Zig 协调器 + Zig 节点 + Go 客户端

**任何组合都应该成功**，因为线格式逐字节一致。

### 8.6 跨语言互通验证清单

| 组件 | Zig | C++ | C# | Rust | Go | JS | Pascal | Python |
|------|:---:|:---:|:--:|:----:|:--:|:--:|:------:|:------:|
| 协调器 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 节点 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 客户端 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

---

## 9. v0.4 新能力速览

### 9.1 UID 值类型

```zig
const lf = @import("lingofuse");

// 从 hex 解析
const uid = try lf.Uid.fromHex("0123...cdef");

// 从字节构造
const uid = lf.Uid.fromBytes([_]u8{0x42} ** 32);  // 注意：项目中用 @splat

// 检查 / 比较
if (uid.isNull()) { ... }
if (a.eql(b)) { ... }

// 输出
var buf: [64]u8 = undefined;
uid.toHexBuf(&buf);
std.debug.print("uid = {s}\n", .{&buf});
```

### 9.2 P2P 身份侧数据

```zig
fn whoamiCallback(
    _: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    // 只能从回调的 input 句柄读取发送方身份
    const uid = input.p2pUid() catch lf.Uid.NULL;
    const name = input.p2pName(std.heap.page_allocator) catch return;

    // 打印（uid 用 hex）
    var buf: [64]u8 = undefined;
    uid.toHexBuf(&buf);
    std.debug.print("caller uid = {s}, name = {s}\n", .{ &buf, name });
}
```

### 9.3 类型化选项

```zig
const lf = @import("lingofuse");

// 布尔 / 整数 / 字符串
try lf.options.setQuiet(true);
try lf.options.setWaitConnectionTimeout(10_000);
try lf.options.setP2PName("worker_group");

// getter（字符串类型返回 allocator-owned slice）
const quiet = try lf.options.getQuiet(std.heap.page_allocator);
const timeout = try lf.options.getWaitConnectionTimeout(std.heap.page_allocator);
const name = try lf.options.getP2PName(std.heap.page_allocator);
defer std.heap.page_allocator.free(name);
```

### 9.4 进程级 P2P 注册

```zig
fn whoamiHandler(
    _: ?*anyopaque,
    input: *lf.DataHandle,
    output: *lf.DataHandle,
) lf.Error!void {
    const uid = input.p2pUid() catch lf.Uid.NULL;
    const name = input.p2pName(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(name);

    var buf: [64]u8 = undefined;
    uid.toHexBuf(&buf);

    try lf.io.writeJson(output, .{
        .uid_hex = &buf,
        .p2p_name = name,
    });
}

// 注册（不属于任何 App，通过 UID 或 P2PName 可达）
try lf.p2p.registerP2PCall("whoami", "echo caller identity", null, whoamiHandler);

// 注销
const removed = try lf.p2p.unregisterP2P("whoami");
```

### 9.5 异步调用家族（重点）

**这是你最关心的"`async_call(xxx, 业务代码)`"Zig 形态**。

Zig 没有闭包，所以业务代码写成**匿名 struct 的 fn**，通过 `ctx` 指针携带共享状态。这与 `std.Thread.spawn(.{}, fn, args)` 完全同构：

```zig
const lf = @import("lingofuse");

// --- 共享状态 ------------------------------------------------
const Sync = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sum: i32 = 0,
};

// --- "业务代码"：匿名 struct 的 fn ---------------------------
const Biz = struct {
    fn handle(ctx: ?*anyopaque, result: lf.async_call.AsyncResult) void {
        const s: *Sync = @ptrCast(@alignCast(ctx orelse return));
        switch (result) {
            .ok => |h| {
                var hh = h;
                var buf: [4]u8 = undefined;
                _ = hh.readBytes(&buf) catch { return; };
                s.sum = std.mem.readInt(i32, &buf, .little);
                s.done.store(true, .release);
            },
            .err => |e| {
                std.debug.print("async failed: {}\n", .{e});
                s.done.store(true, .release);
            },
        }
    }
};

// --- 发起调用 ------------------------------------------------
var req = try lf.DataHandle.create("add");
defer req.deinit();
// ... 填充 req ...
var sync = Sync{};
try lf.async_call.callAsync("Calculator", &req, &sync, Biz.handle);

// --- 等待（或直接在 Biz.handle 里处理）-----------------------
while (!sync.done.load(.acquire)) Sleep(1);
```

**阻塞式**（最接近同步调用的手感）：

```zig
const bytes = try lf.async_call.callAsyncWait(
    "Calculator",
    &req,
    @as(?u64, 5_000),  // null = 无限等待
);
defer std.heap.page_allocator.free(bytes);

// bytes 是响应负载的字节，无尾部 NUL
const out = try lf.io.loadsJson(MyResult, bytes);
```

**为什么返回 `[]u8` 而不是 `DataHandle`**：异步回调的 `result` handle 归**框架所有**，回调返回瞬间释放。把它包装成 owning `DataHandle` 送出回调边界会导致 use-after-free。唯一安全的策略是**在回调内拷贝字节**。

---

## 10. C# 端使用 typed options

### 10.1 问题

LingoFuse C ABI 只导出两个 option 函数：

```c
void        LF_SetOption(const char* option, const char* value);
const char* LF_GetOption(const char* option);
```

`c/LingoFuse_Opt.h` 提供了 `LF_Set_Opt_Quiet(1)` 这样的 **`static inline` 封装**，但它**不能被 C# P/Invoke 调用**——P/Invoke 只能调用**已导出**的符号，`static inline` 函数没有导出符号。

### 10.2 解决方案：C# 端写一个小封装

**推荐方式**（无需改 native 库）：

```csharp
using System;
using System.Globalization;
using System.Runtime.InteropServices;

internal static class Lf {
    private const string Lib = "LingoFuse64";  // 或 "LingoFuse32"

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void LF_SetOption(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string option,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string value);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr LF_GetOption(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string option);
}

/// <summary>
/// Typed wrappers around LF_SetOption / LF_GetOption.
/// Mirrors c/LingoFuse_Opt.h.
/// </summary>
public static class LfOptions {
    private static string GetString(string option) {
        var ptr = Lf.LF_GetOption(option);
        return ptr == IntPtr.Zero ? "" : (Marshal.PtrToStringUTF8(ptr) ?? "");
    }

    private static bool GetBool(string option) =>
        GetString(option).Equals("True", StringComparison.OrdinalIgnoreCase);

    private static void SetBool(string option, bool value) =>
        Lf.LF_SetOption(option, value ? "True" : "False");

    private static ulong GetU64(string option) =>
        ulong.TryParse(GetString(option), NumberStyles.Integer,
                       CultureInfo.InvariantCulture, out var v) ? v : 0UL;

    private static int GetI32(string option) =>
        int.TryParse(GetString(option), NumberStyles.Integer,
                     CultureInfo.InvariantCulture, out var v) ? v : 0;

    // --- Quiet ---------------------------------------------------
    public static void SetQuiet(bool v) => SetBool("Quiet", v);
    public static bool GetQuiet() => GetBool("Quiet");

    // --- ShowThreadID --------------------------------------------
    public static void SetShowThreadId(bool v) => SetBool("ShowThreadID", v);
    public static bool GetShowThreadId() => GetBool("ShowThreadID");

    // --- ConsoleOutput -------------------------------------------
    public static void SetConsoleOutput(bool v) => SetBool("ConsoleOutput", v);
    public static bool GetConsoleOutput() => GetBool("ConsoleOutput");

    // --- Overlap_Connection --------------------------------------
    public static void SetOverlapConnection(bool v) => SetBool("Overlap_Connection", v);
    public static bool GetOverlapConnection() => GetBool("Overlap_Connection");

    // --- Wait_Connection_ReadyOk ---------------------------------
    public static void SetWaitConnectionReadyOk(bool v) => SetBool("Wait_Connection_ReadyOk", v);
    public static bool GetWaitConnectionReadyOk() => GetBool("Wait_Connection_ReadyOk");

    // --- Wait_Connection_Timeout ---------------------------------
    public static void SetWaitConnectionTimeout(ulong ms) =>
        Lf.LF_SetOption("Wait_Connection_Timeout",
                        ms.ToString(CultureInfo.InvariantCulture));
    public static ulong GetWaitConnectionTimeout() =>
        GetU64("Wait_Connection_Timeout");

    // --- Fixed_Sequenced_Time ------------------------------------
    public static void SetFixedSequencedTime(ulong ms) =>
        Lf.LF_SetOption("Fixed_Sequenced_Time",
                        ms.ToString(CultureInfo.InvariantCulture));
    public static ulong GetFixedSequencedTime() =>
        GetU64("Fixed_Sequenced_Time");

    // --- IPC_Serv_ThreadCount ------------------------------------
    public static void SetIpcServThreadCount(int v) =>
        Lf.LF_SetOption("IPC_Serv_ThreadCount",
                        v.ToString(CultureInfo.InvariantCulture));
    public static int GetIpcServThreadCount() =>
        GetI32("IPC_Serv_ThreadCount");

    // --- DataHandle_Idle_Timeout ---------------------------------
    public static void SetDataHandleIdleTimeout(ulong ms) =>
        Lf.LF_SetOption("DataHandle_Idle_Timeout",
                        ms.ToString(CultureInfo.InvariantCulture));
    public static ulong GetDataHandleIdleTimeout() =>
        GetU64("DataHandle_Idle_Timeout");

    // --- LF_P2P_name ---------------------------------------------
    public static void SetP2PName(string name) => Lf.LF_SetOption("LF_P2P_name", name);
    public static string GetP2PName() => GetString("LF_P2P_name");
}
```

使用方式与 Pascal / C++ / Zig 的 typed 层完全一致：

```csharp
LfOptions.SetQuiet(true);
LfOptions.SetWaitConnectionTimeout(10_000);
LfOptions.SetP2PName("worker_group");

bool quiet = LfOptions.GetQuiet();
ulong timeout = LfOptions.GetWaitConnectionTimeout();
string group = LfOptions.GetP2PName();
```

### 10.3 关于 `c/LingoFuse_Opt.h`

`c/LingoFuse_Opt.h` 是**给 C / C++ 用户**的便利层。C# 用户直接照抄第 10.2 节的 `LfOptions` 类即可。

**未来的可能性**：如果 LingoFuse 的 Pascal 侧决定导出 typed 函数（`LF_Set_Opt_Quiet` 等），那么 C# 就能直接 P/Invoke 这些符号。**这需要改 Pascal 代码，不在本 Zig 项目范围内**。`c/LingoFuse_Opt.h` 顶部有一段 `LF_OPT_DECLARE_EXPORTED` 宏的说明，描述了这一演进路径。

---

## 11. 故障排查

### 11.1 编译错误

| 症状 | 原因 | 修法 |
|------|------|------|
| `LibraryNotFound` | native 库不在搜索路径 | 把 `LingoFuse64.dll` + `z_ipc_64.dll` 放入 exe 目录或 PATH |
| `SymbolMissing { symbol: "LF_xxx" }` | native 库版本过旧 | 从主仓库 `Binary/` 取最新版 |
| `error: expected expression, found 'const'` | Zig 语法错误（0.17 变严） | 检查语法 |
| `local variable is never mutated` | Zig 0.17 把 warning 升为 error | 未修改的 `var` 改成 `const` |
| `binary operator '*' has whitespace on one side` | `**` 运算符空格不对称 | **改用 `@splat`**（见 11.4） |
| `std.mem.Allocator has no member named 'dupeZ'` | Zig 0.17 移除 | 用 `src/util.zig` 的 `dupeZ` |
| `std.Thread has no member named 'sleep'` | Zig 0.17 移除 | 用 Windows `Sleep(ms)` |
| `std.time has no member named 'milliTimestamp'` | Zig 0.17 移除 | 用 Windows `GetTickCount64()` |
| `dependency on libc must be explicitly specified` | 单文件 `zig test` 不含 libc | 加 `-lc`：`zig test -lc src/async_call.zig` |

### 11.2 运行时问题

| 症状 | 原因 | 修法 |
|------|------|------|
| `zig build test` 卡死 | `test_abi.zig` 里出现了集成测试 | 移除；改到 `examples/*_smoke.zig`（见 7.2） |
| `test ... failed: error.SkipZigTest` | native 库未加载 | 检查 PATH |
| 冒烟测试某步 `[FAIL]` | 具体见日志文件 | 打开 `.log` 查看失败点 |
| Cross Demo 首次调用超时 | mesh 广播延迟 | 正常；重试 1–3 秒后成功 |
| `IPC queue is already occupied` | 上次未正常退出 | 关掉所有残留进程，或换端点名 |
| `LF_BindApp: Main thread is not active` | `prepareDone` 未调用或失败 | 检查 `prepareDone` 返回值 |

### 11.3 日志文件

每次运行 smoke 测试会生成对应日志：

| 日志 | 生成者 |
|------|--------|
| `abi_smoke.log` | `zig build smoke` |
| `io_smoke.log` | `zig build io-smoke` |
| `json_smoke.log` | `zig build json-smoke` |
| `network_events_smoke.log` | `zig build network-events-smoke` |
| `status_smoke.log` | `zig build status-smoke` |
| `uid_smoke.log` | `zig build uid-smoke` |
| `identity_smoke.log` | `zig build identity-smoke` |
| `options_smoke.log` | `zig build options-smoke` |
| `async_smoke.log` | `zig build async-smoke` |
| `p2p_smoke.log` | `zig build p2p-smoke` |
| `addressing_smoke.log` | `zig build addressing-smoke` |

**卡死时**：日志文件的**最后一行**就是卡住的操作。

**清理**：

```powershell
.\clean.ps1                  # 删除所有 .log
.\clean.ps1 -KeepLogs        # 保留日志，只删 .zig-cache 和 zig-out
```

### 11.4 `**` 运算符陷阱（重要）

Zig 的 `**`（数组重复运算符）要求**两侧空格必须对称**：

```zig
const a = [_]u8{0} ** 32;   // ✅ 正确
const a = [_]u8{0} **32;    // ❌ error: whitespace on one side
const a = [_]u8{0}** 32;    // ❌ error: whitespace on one side
```

**任何工具（编辑器、Markdown 往返、复制粘贴）都可能破坏空格对称性**。本项目的**铁律**：

> **项目所有代码（src/ examples/ tests/）一律禁用 `**`。**

**替代写法**：

| 场景 | 禁用写法 | 推荐写法 |
|------|---------|---------|
| 全零数组 | `[_]u8{0} ** N` | `@splat(0)` 或 `std.mem.zeroes([N]u8)` |
| 单值填充 | `[_]u8{v} ** N` | `@splat(v)` |
| 运行时填充 | `arr ** = v` | `@memset(&arr, v)` |
| 字符串重复 | `"abc" ** N` | 显式 `@memset` 或 `while` 循环 |

### 11.5 关于 `-lc` 标志

**含 `extern "c" fn` 声明**的模块（目前只有 `src/async_call.zig`）单文件 `zig test` 需要加 `-lc`：

```powershell
zig test -lc src/async_call.zig
```

**`build.zig` 已设 `link_libc = true`**，所以 `zig build` / `zig build test` / `zig build *-smoke` **不需要**手动处理。

---

## 12. 已知限制

### 12.1 平台

| 限制 | 影响 | 状态 |
|------|------|:----:|
| 仅在 Windows x64 验证 | Linux / macOS 未测 | ⏳ |
| `cross_call.zig` / `async_call.zig` 用 Windows `Sleep` / `GetTickCount64` | 移植到 POSIX 需替换为 `nanosleep` / `clock_gettime` | ⏳ |
| 大端架构未测 | 需显式字节序转换 | ⏳ |

### 12.2 Zig 版本

| 限制 | 影响 |
|------|------|
| 锁定 0.17.0 | 0.18+ 需重跑破坏性变更清单 |
| `std.json` 行为可能变化 | `io.readJson` / `loadsJson` / `tryReadJson` 需要重点回归 |
| 自定义 `format` 方法签名变化 | 不实现自定义 `format`；用 `toHexBuf` 等显式 helper |

### 12.3 架构

| 限制 | 说明 |
|------|------|
| `network_events.zig` 的全局槽位非原子 | 文档要求单线程调用；违反会有 handler/ctx 不匹配 |
| `app_handle.zig` 成功注册会泄漏 context | 有意为之，代价有界（API 数量） |
| `p2p.zig` 成功注册同样泄漏 context | 同上 |
| `async_call.zig` 的阻塞式超时不取消 native 请求 | 超时后回调可能晚到；handler 检测到 abandoned waiter 后丢弃 |
| `tests/test_abi.zig` 不能放集成测试 | Zig test runner 会卡死（见 §7.2） |
| `status.drainStatus` 两次分配 | 短队列无影响；高频场景可优化 |

### 12.4 未实现的 API

以下 native 能力当前 Zig 绑定**未暴露**：

| API | 状态 | 说明 |
|-----|:----:|------|
| JSON Pointer | ❌ | 需要扩展 `lf_json.h` |
| JSON Patch | ❌ | 同上 |
| JSON Merge Patch | ❌ | 同上 |
| JSON SAX 流式解析 | ❌ | 同上 |
| JSON 二进制格式（CBOR 等） | ❌ | 同上 |

如需以上能力，需要扩展 `c/lf_json.h` / `c/lf_json.cpp`。

### 12.5 未完成的阶段

| 阶段 | 状态 | 说明 |
|:----:|:----:|------|
| 8. 多语言对接测试 | ⏳ | 建议逐个验证 §8.6 的组合 |
| 9. CI 集成 | ⏳ | GitHub Actions / GitLab CI 配置 |
| — | ⏳ | 完整指南 / 踩坑知识库 |

---

## 参考

- **LingoFuse 主仓库**：https://github.com/PassByYou888/LingoFuse
- **nlohmann/json**：https://github.com/nlohmann/json
- **Zig 官方文档**：https://ziglang.org/documentation/0.17.0/

## 许可

与主仓库一致，详见仓库根目录 `LICENSE`。
