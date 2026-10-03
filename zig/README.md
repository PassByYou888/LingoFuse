# LingoFuse Zig 绑定

> **Zig 语言官方绑定，与 Pascal / C++ / C# / Rust / Go / Python / JavaScript 实现逐字节兼容的线格式。**
>
> 版本：v1.0（阶段 1–7 完成）
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
9. [故障排查](#9-故障排查)
10. [已知限制](#10-已知限制)

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
│   ├── lf_json.h                # nlohmann/json 的 C ABI 头文件
│   ├── lf_json.cpp              # nlohmann/json 的 C ABI 实现
│   └── json.hpp                 # nlohmann/json 单文件版（外部依赖）
│
├── src/                         # 绑定源码
│   ├── lingofuse.zig            # 模块根：顶层 re-export
│   ├── sys.zig                  # 37 个 C ABI 函数的手写 extern 声明
│   ├── error.zig                # 错误集
│   ├── data_handle.zig          # RAII 数据句柄
│   ├── app_handle.zig           # RAII 应用句柄 + 回调 trampoline
│   ├── framework.zig            # 进程级 facade
│   ├── io.zig                   # 统一 JSON / 字符串 / 字节 I/O
│   ├── json_c.zig               # lf_json C ABI 的 extern 声明
│   ├── network_events.zig       # 进程级网络事件
│   └── status.zig               # 状态队列
│
├── examples/                    # 可执行示例 / 测试
│   ├── abi_smoke.zig            # ABI 冒烟测试（35 步）
│   ├── io_smoke.zig             # 统一 I/O 冒烟测试（18 步）
│   ├── json_smoke.zig           # lf_json C ABI 冒烟测试（43 步）
│   ├── network_events_smoke.zig # 网络事件冒烟测试（6 步）
│   ├── status_smoke.zig         # 状态队列冒烟测试（5 步）
│   ├── cross_service.zig        # Cross Demo 协调器
│   ├── cross_node.zig           # Cross Demo 工作节点
│   └── cross_call.zig           # Cross Demo 负载客户端
│
└── tests/
    └── test_abi.zig             # Zig 原生单元测试（33 个）
```

**分层原则**：

```
应用层      用户代码
            ↓ import "lingofuse"
高层封装    io / network_events / status / framework / app_handle / data_handle
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

# Windows（永久生效）
[Environment]::SetEnvironmentVariable(
    "PATH",
    "D:\CoreLibrary\LingoFuse\Binary;" + [Environment]::GetEnvironmentVariable("PATH", "User"),
    "User"
)
```

### 2.4 安装 Zig

见下一节。

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

| 变更 | 影响 |
|------|------|
| 移除 `@cImport` | 必须手写 `extern fn`（`src/sys.zig` 的 37 个声明） |
| 移除 `std.meta.fields` | 反射 struct 字段必须探测 `@typeInfo(T).@"struct"` 的实际布局 |
| 移除 `std.mem.Allocator.dupeZ` | 改用本地 `dupeZ` helper |
| 移除 `std.time.Timer` / `nanoTimestamp` | 改用 C 标准库的 `clock()` |
| 移除 `std.Thread.sleep` | 改用 Windows `Sleep(ms)` |
| `std.json.parseFromSlice` 默认别名输入 | 必须显式传 `.allocate = .alloc_always` |
| `std.ArrayListUnmanaged` 新增字段 | 无法用 `.{ }` 初始化 |

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

**唯一例外**：如果在非 Windows 平台上构建，需确认 `link_libcpp` 对应的运行库名与平台匹配（Zig 会自动处理）。

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
| `zig build test` | 33 | ✅ |
| `zig build smoke` | 35 | ✅ |
| `zig build io-smoke` | 18 | ✅ |
| `zig build json-smoke` | 43 | ✅ |
| `zig build network-events-smoke` | 6 | ✅ |
| `zig build status-smoke` | 5 | ✅ |
| **合计** | **140** | ✅ |

### 4.3 未验证环境（诚实声明）

| 环境 | 状态 | 说明 |
|------|:----:|------|
| Windows 32 位 | ⏳ 未验证 | 需要 32 位 Native 库 |
| Linux x64 | ⏳ 未验证 | `cross_call.zig` 用了 `Sleep`（Windows 专有），需替换为 `nanosleep` |
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
| 导出函数 | 37 个 `LF_*` |
| 是否修改 | ❌ 未修改，逐字节保持原样 |
| 验证方式 | `src/sys.zig` 的 37 个 `extern fn` 声明与 `LingoFuse.h` 一一对应 |

**确认方式**：

```powershell
# 打开 c/LingoFuse.h，搜索 "LF_" 前缀的函数声明
# 数量应为 37，加上两个 loader 函数（LF_LoadLibrary / LF_FreeLibrary）合计 39
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

**确认方式**：

```powershell
# 检查 lf_json.h 的公开函数
Select-String -Path c\lf_json.h -Pattern "^[A-Za-z].*lf_json_"

# 检查 lf_json.cpp 的对应实现
Select-String -Path c\lf_json.cpp -Pattern "^[A-Za-z].*lf_json_"
```

两个列表应一一对应，合计 37 个函数。

### 5.3 `c/json.hpp`

**来源**：从 nlohmann/json 官方 releases 下载的单文件版。

| 项 | 值 |
|----|-----|
| 版本 | 3.12.0 |
| 大小 | 约 920 KB |
| 是否修改 | ❌ 未修改 |
| 验证方式 | 打开文件头部，应有 `NLOHMANN_JSON_VERSION_MAJOR 3` 等宏定义 |

**版本确认**：

```powershell
Select-String -Path c\json.hpp -Pattern "NLOHMANN_JSON_VERSION" | Select-Object -First 3
```

---

## 6. 编译器确认

### 6.1 Zig 编译器

```powershell
zig version
# 必须输出 0.17.0 或更高（本项目只在 0.17.0 上验证）
```

`build.zig` 使用 Zig 0.17.0 的 `std.Build` API，包括：
- `b.createModule(.{ .root_source_file = b.path(...), .target, .optimize })`
- `b.addExecutable(.{ .name, .root_module })`
- `b.addTest(.{ .root_module })`
- `b.addRunArtifact(exe)`
- `b.default_step.dependOn(&exe.step)`

### 6.2 C 编译器（Zig 内置）

Zig 自带 C 编译器，`build.zig` 通过 `addCSourceFile` 编译 `c/LingoFuse.c`。

**验证方式**：

```powershell
# 编译后，检查 zig-out\bin\ 下是否存在 abi_smoke.exe
# 若无编译错误，说明 C 编译器正常工作
.\build.ps1
```

### 6.3 C++ 编译器（Zig 内置）

`build.zig` 通过 `addCSourceFile(.{ .file = b.path("c/lf_json.cpp"), .flags = &.{"-std=c++17"} })` 编译 `lf_json.cpp`，并通过 `m.link_libcpp = true` 链接 C++ 运行库。

**验证方式**：

```powershell
# 编译后，运行 json_smoke.exe；若 nlohmann/json 相关的 43 个测试全过，
# 说明 C++ 编译器与运行库都正常
.\test.ps1
```

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
zig build test                     # Zig 原生单元测试
zig build smoke                    # ABI 冒烟测试
zig build io-smoke                 # 统一 I/O 冒烟测试
zig build json-smoke               # lf_json C ABI 冒烟测试
zig build network-events-smoke     # 网络事件冒烟测试
zig build status-smoke             # 状态队列冒烟测试
```

### 7.2 为什么用冒烟程序而非 Zig test

**根因**：Zig test runner 在 Windows 上有两个已知问题：

1. **stdout 传输争用**：native LingoFuse 库写诊断到控制台时，可能与 test runner 的 stdout 传输争用，导致**卡死**（无输出、不返回）。
2. **log 级别误判**：test runner 默认 `std.testing.log_level = .warn`，任何 ≥ warn 的日志（包括回调 trampoline 里的 `std.log.err`）都会被判定为测试失败。**不存在比 `.err` 更高的级别可以抑制**。

**规避方案**：把大部分测试改写为**普通程序**：
- 每步前后写日志文件（C stdio + `fflush`），卡死时日志文件保留现场
- 不用 Zig test runner，因此不受 log 级别规则约束
- 退出码约定：0 = 全过，1 = 有失败，2 = 无法打开日志文件

**唯二例外**：
- `tests/test_abi.zig`（33 个单元测试）用 Zig test runner，因为它不触发 native 输出
- 该套件的两个契约（handler error 被吞、unregistered API 返回 size 0）**已从测试中删除**，由 `abi_smoke.zig` 覆盖

### 7.3 测试项总览

| 套件 | 步数 | 层 | 应用领域 |
|------|:----:|-----|---------|
| `test_abi` | 33 | 单元测试 | 句柄生命周期、字节 I/O、本地调用 |
| `smoke` | 35 | ABI 集成 | 完整 C ABI 契约、回调、绑定 |
| `io-smoke` | 18 | I/O 层 | 字符串帧、JSON 线格式、容错读取 |
| `json-smoke` | 43 | JSON 引擎 | nlohmann 完整 API 面、字节级兼容 |
| `network-events-smoke` | 6 | 网络事件 | 安装 / 查询 / 清除生命周期 |
| `status-smoke` | 5 | 状态队列 | 计数、投递、读取、批量拉取 |
| **合计** | **140** | — | — |

### 7.4 详细测试项

#### 7.4.1 `zig build test` — 33 个单元测试

| 分组 | 数量 | 覆盖内容 | 应用领域 |
|------|:----:|---------|---------|
| DataHandle 生命周期 | 4 | 创建 / 永久 / 幂等 deinit / deinit 后报错 | 资源管理 |
| DataHandle 字节 I/O | 7 | 往返 / 空写 / 尾部读 / 短读 / 嵌入 NUL / readAll / 空 readAll | 二进制协议 |
| DataHandle 游标与大小 | 4 | setSize / setPosition / 负值拒绝 | 缓冲区控制 |
| DataHandle 字符串助手 | 3 | NUL 帧 / 空串 / UTF-8 | 跨语言字符串 |
| DataHandle 借用句柄 | 1 | `fromRaw(_, false)` 的 deinit 是 no-op | 回调内资源 |
| AppHandle 生命周期 | 3 | 创建 / 释放后报错 / 幂等 | 应用容器 |
| AppHandle 注册 | 4 | registerCall / registerNotify / 重复 / 注销 | API 暴露 |
| AppHandle 本地调用 | 3 | 往返 / 输入不被消费 / Notify 送达 | 同进程 RPC |
| AppHandle 大载荷 | 1 | 200 字节 echo | 数据完整性 |
| Framework | 4 | statusCount / unknown option / checkMainThread / checkApp | 健康检查 |
| **合计** | **33** | | |

#### 7.4.2 `zig build smoke` — 35 步 ABI 集成

| 分组 | 步数 | 覆盖内容 | 应用领域 |
|------|:----:|---------|---------|
| DataHandle 创建与生命周期 | 4 | 创建 / 永久 / 幂等 / deinit 后报错 | 资源管理 |
| DataHandle 字节 I/O | 7 | 往返 / 空写 / 尾部读 / 短读 / 嵌入 NUL / readAll / 空 readAll | 二进制协议 |
| DataHandle 游标与大小 | 4 | setSize / setPosition / 负值拒绝 | 缓冲区控制 |
| DataHandle 字符串 | 3 | NUL 帧 / 空串 / UTF-8 | 跨语言字符串 |
| DataHandle 借用句柄 | 1 | borrowed deinit no-op | 回调内资源 |
| AppHandle 生命周期 | 3 | 创建 / 释放后报错 / 幂等 | 应用容器 |
| AppHandle 注册 | 4 | registerCall / registerNotify / 重复 / 注销 / 重注册 | API 暴露 |
| AppHandle 本地调用 | 3 | 往返 / 输入不被消费 / Notify | 同进程 RPC |
| **Handler 错误吞噬** | 1 | 回调抛错 → 输出为空、进程不死 | **回调健壮性** |
| AppHandle 大载荷 | 1 | 200 字节 echo | 数据完整性 |
| Framework | 4 | statusCount / unknown option / checkMainThread / checkApp | 健康检查 |
| **合计** | **35** | | |

**特别注意**：第 30 步「handler error swallowed」是唯一一个验证**回调错误隔离**的测试。它依赖 native 层的 `try/finally` 结构，确保 handler 抛错不会破坏 native 状态机。

#### 7.4.3 `zig build io-smoke` — 18 步统一 I/O 层

| 分组 | 步数 | 覆盖内容 | 应用领域 |
|------|:----:|---------|---------|
| 字符串 I/O | 8 | 往返 / 空串 / 嵌入 NUL / readStringBytes 停在 NUL / peek 不推进游标 / readAllBytes / 无 NUL 容错 / 游标 size+1 边界 | **跨语言线格式** |
| JSON 序列化（无句柄） | 4 | dumpsJson 紧凑 / 非 ASCII 字面 / 控制字符转义 / loadsJson 严格 | JSON 引擎 |
| JSON I/O（经句柄） | 3 | writeJson/readJson 往返 / 字节级 `{"a":1}\0` / 中文 emoji 往返 | **字节级兼容** |
| JSON 错误路径 | 3 | 空 payload 拒绝 / 垃圾输入返回 null / 类型不匹配返回 null | 错误处理 |
| **合计** | **18** | | |

**关键验证**：`writeJson(&h, Payload{ .a = 1 })` 必须产生**精确的 8 字节**：

```
7B 22 61 22 3A 31 7D 00
│  │  │  │  │  │  │  └── NUL 帧
│  └──┴──┴──┴──┴──┘
└─ {"a":1}
```

这是与 C++ / C# / Rust / Go / Python / JavaScript 六个 binding 互通的**基础契约**。

#### 7.4.4 `zig build json-smoke` — 43 步 lf_json C ABI

| 分组 | 步数 | 覆盖内容 | 应用领域 |
|------|:----:|---------|---------|
| A. 解析 | 7 | 标量 / 字符串 / 转义 / 容器 / 错误 / 显式长度 / free(NULL) | 输入处理 |
| B. 类型标签 | 1 | 7 种 tag + NULL → -1 | 类型分派 |
| C. 序列化 | 4 | 标量 / 字符串 / 容器 / 边界（小 buffer / NULL buffer） | 输出处理 |
| D. 值读取 | 5 | bool / int64 / uint64 / double / string | 类型化访问 |
| E. 对象访问 | 3 | size / key 迭代（顺序 + 越界） / get | 结构化数据 |
| F. 数组访问 | 2 | size / get（元素 + 越界 + 负索引） | 结构化数据 |
| G. DOM 构建 | 6 | new_* / object_set / array_push / 嵌套 / DOM vs parse 字节一致 | 动态构造 |
| H. 流式 writer | 5 | 全 typed writer / raw 拼装 / size / into / NULL 安全 | **序列化引擎** |
| I. 线格式 | 5 | `{"a":1}` 字节序列 / UTF-8 字面 / 控制字符转义 / 浮点格式 / 深拷贝语义 | **字节级兼容** |
| J. 边界情况 | 5 | 64 层嵌套 / 8 KB 字符串 / 空对象 key / UTF-8 key 排序 / i64/u64 极值 | 鲁棒性 |
| **合计** | **43** | | |

**关键验证**：

- **I01** 验证 canonical byte sequence（与 C++ binding 逐字节一致）
- **I02** 验证 UTF-8 字面输出（无 `\uXXXX`，与 C#/Python 一致）
- **I03** 验证控制字符转义策略（`\b` / `\f` 短转义，其余 `\u00XX`）
- **I04** 验证 nlohmann 的 Grisu2 浮点格式（`NaN` / `Inf` → `null`）
- **J04** 验证对象 key 按 **UTF-8 字节序**排序（与 `std::map<std::string>` 一致）

#### 7.4.5 `zig build network-events-smoke` — 6 步

| 步 | 覆盖内容 | 应用领域 |
|:--:|---------|---------|
| 1 | 初始状态未安装 | 状态查询 |
| 2 | 安装 connect + disconnect | 事件订阅 |
| 3 | 替换为仅 connect | 替换语义 |
| 4 | 替换为仅 disconnect | 替换语义 |
| 5 | 清除 | 事件取消 |
| 6 | 幂等清除 | 生命周期 |

**未覆盖**：真实的事件触发（需要第二个进程加入 mesh）。这是 Cross Demo 的职责。

#### 7.4.6 `zig build status-smoke` — 5 步

| 步 | 覆盖内容 | 应用领域 |
|:--:|---------|---------|
| 1 | getStatusCount ≥ 0 | 队列监控 |
| 2 | postStatus 接受消息 | 日志注入 |
| 3 | getStatus 返回 NUL 结尾 slice | 日志读取 |
| 4 | drainStatus(0) 空操作 | 边界条件 |
| 5 | drainStatus(16) 返回合法 slice | 批量读取 |

**未覆盖**：队列真实内容（需要在主线程运行状态下才有意义）。

### 7.5 测试项与应用领域对照

| 应用领域 | 主要覆盖 | 测试套件 |
|---------|---------|---------|
| **资源管理** | 句柄创建 / 释放 / 幂等 / UAF 防护 | test_abi + smoke |
| **二进制协议** | 字节往返、嵌入 NUL、短读、游标控制 | test_abi + smoke + io-smoke |
| **跨语言线格式** | NUL 帧、UTF-8 字面、控制字符转义、`{"a":1}` 字节级验证 | io-smoke + json-smoke |
| **同进程 RPC** | localCall / localNotify / 输入不被消费 | test_abi + smoke |
| **API 暴露** | registerCall / registerNotify / 重复拒绝 / 注销 | test_abi + smoke |
| **回调健壮性** | handler 抛错被吞、进程不崩溃 | smoke（第 30 步） |
| **JSON 引擎** | nlohmann 完整 API 面（43 个） | json-smoke |
| **网络事件** | 安装 / 替换 / 清除生命周期 | network-events-smoke |
| **状态队列** | 计数 / 投递 / 读取 / 批量拉取 | status-smoke |
| **健康检查** | checkMainThread / checkApp / checkApi | test_abi + smoke |
| **跨进程 RPC** | 完整 mesh 发现 + 路由 + 调用 | Cross Demo（§8） |

### 7.6 判断测试是否真实运行

**陷阱**：当 native 库缺失时，部分测试会打印 `[SKIP]` 并返回成功。**测试显示 `ok` 不代表真实运行过**。

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
Get-Content io_smoke.log | Select-Object -First 20
```

日志的第一行应是 `LingoFuse Zig ... smoke test`，随后每一步前后都有 `[step]` / `[ok]` 记录。

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

**期望的终端 3 输出**：

```
=== Cross Call (Client) ===
[Call] Prepared client tunnel to ipc:cross (tag=...).
[Call] Connected to ipc:cross. Starting 10-second load test with 32 threads...
[Call 5] add(412, 789) = 1201
[Call 12] reply: [200, 16, 47, 63, "hello world", 3.14]  original: [...]

[Call] Load test summary
         duration          : 10.023 s
         total calls       : ...
         success           : ... (100.00 %)
         failed            : 0
         add calls         : ...
         inv_seri calls    : ...
         throughput        : ... calls/s
         success throughput: ... calls/s
[Call] Press Enter to exit...
```

**首次调用可能超时**：mesh 广播到达本地缓存需要 1–3 秒。前几次失败是正常的。若失败率超过 10%，需排查。

**第三步：关闭顺序**（与启动相反）

1. 关 **客户端**（cross_call）— 按 Enter
2. 关 **节点**（cross_node）— 按 Enter
3. 关 **协调器**（cross_service）— 按 Enter

每个程序退出时会自动按 `ExitMainThread → app.deinit → shutdown → deinit` 顺序清理（LF-CLEAN-001）。

### 8.5 跨语言运行

把三个终端中的任意一个替换成其它语言的实现即可。例如：

**混合 A**：Zig 协调器 + C++ 节点 + Zig 客户端

```powershell
# 终端 1
.\cross_service.exe              # Zig 协调器

# 终端 2（C++ 目录）
..\..\..\cpp\Binary\CrossNode.exe   # C++ 节点

# 终端 3
.\cross_call.exe                 # Zig 客户端
```

**混合 B**：Zig 协调器 + Zig 节点 + Go 客户端

```powershell
# 终端 1
.\cross_service.exe              # Zig

# 终端 2
.\cross_node.exe                 # Zig

# 终端 3（Go 目录）
..\..\..\go\bin\cross-call.exe   # Go 客户端
```

**任何组合都应该成功**，因为线格式逐字节一致。

### 8.6 跨语言互通验证清单

| 组件 | Zig | C++ | C# | Rust | Go | JS | Pascal | Python |
|------|:---:|:---:|:--:|:----:|:--:|:--:|:------:|:------:|
| 协调器 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 节点 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 客户端 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

**建议的互通测试组合**：

1. Zig ↔ Zig（单语言基线）
2. Zig 节点 ↔ C++ 客户端（验证二进制兼容）
3. Zig 客户端 ↔ Go 节点（验证另一方向的兼容）
4. Zig 节点 ↔ Python 客户端（验证 UTF-8 字符串帧）

---

## 9. 故障排查

### 9.1 编译错误

| 症状 | 原因 | 修法 |
|------|------|------|
| `LibraryNotFound` | native 库不在搜索路径 | 把 `LingoFuse64.dll` + `z_ipc_64.dll` 放入 exe 目录或 PATH |
| `SymbolMissing { symbol: "LF_xxx" }` | native 库版本过旧 | 从主仓库 `Binary/` 取最新版 |
| `expected expression, found 'const'` | Zig 语法错误（0.17 变严） | 检查是否在值比较里用了 `const` 关键字 |
| `local variable is never mutated` | Zig 0.17 把 warning 升为 error | 未修改的 `var` 改成 `const` |
| `std.mem.Allocator has no member named 'dupeZ'` | Zig 0.17 移除 | 用本地 `dupeZ` helper |
| `std.Thread has no member named 'sleep'` | Zig 0.17 移除 | 用 Windows `Sleep(ms)` |
| `std.time has no member named 'Timer'` | Zig 0.17 移除 | 用 C 标准库 `clock()` |

### 9.2 运行时问题

| 症状 | 原因 | 修法 |
|------|------|------|
| 测试卡死（无输出） | test runner 与 native stdout 争用 | 用 smoke 程序替代（见 §7.2） |
| `test ... failed: error.SkipZigTest` | native 库未加载 | 检查 PATH |
| 冒烟测试某步 `[FAIL]` | 具体见日志文件 | 打开 `.log` 查看失败点 |
| Cross Demo 首次调用超时 | mesh 广播延迟 | 正常；重试 1–3 秒后成功 |
| `IPC queue is already occupied` | 上次未正常退出 | 关掉所有残留进程，或换端点名 |

### 9.3 日志文件

每次运行 smoke 测试会生成对应日志：

| 日志 | 生成者 |
|------|--------|
| `abi_smoke.log` | `zig build smoke` |
| `io_smoke.log` | `zig build io-smoke` |
| `json_smoke.log` | `zig build json-smoke` |
| `network_events_smoke.log` | `zig build network-events-smoke` |
| `status_smoke.log` | `zig build status-smoke` |

**卡死时**：日志文件的**最后一行**就是卡住的操作。

**清理**：

```powershell
.\clean.ps1                  # 删除所有 .log
.\clean.ps1 -KeepLogs        # 保留日志，只删 .zig-cache 和 zig-out
```

---

## 10. 已知限制

### 10.1 平台

| 限制 | 影响 | 状态 |
|------|------|:----:|
| 仅在 Windows x64 验证 | Linux / macOS 未测 | ⏳ |
| `cross_call.zig` 用 Windows `Sleep` | 移植到 POSIX 需替换为 `nanosleep` | ⏳ |
| 大端架构未测 | 需显式字节序转换 | ⏳ |

### 10.2 Zig 版本

| 限制 | 影响 |
|------|------|
| 锁定 0.17.0 | 0.18+ 需重跑破坏性变更清单 |
| `std.json` 行为可能变化 | `readJson` / `loadsJson` / `tryReadJson` 需要重点回归 |

### 10.3 架构

| 限制 | 说明 |
|------|------|
| `network_events.zig` 的全局槽位非原子 | 文档要求单线程调用；违反会有 handler/ctx 不匹配 |
| `app_handle.zig` 成功注册会泄漏 context | 有意为之，代价有界（API 数量） |
| `status.drainStatus` 两次分配 | 短队列无影响；高频场景可优化 |

### 10.4 未实现的 API

以下 native 能力当前 Zig 绑定**未暴露**：

| API | 状态 | 说明 |
|-----|:----:|------|
| JSON Pointer | ❌ | 需要扩展 `lf_json.h` |
| JSON Patch | ❌ | 同上 |
| JSON Merge Patch | ❌ | 同上 |
| JSON SAX 流式解析 | ❌ | 同上 |
| JSON 二进制格式（CBOR 等） | ❌ | 同上 |

如需以上能力，需要扩展 `c/lf_json.h` / `c/lf_json.cpp`。

### 10.5 未完成的阶段

| 阶段 | 状态 | 说明 |
|:----:|:----:|------|
| 8. 多语言对接测试 | ⏳ | 建议逐个验证 §8.6 的组合 |
| 9. CI 集成 | ⏳ | GitHub Actions / GitLab CI 配置 |
| — | — | 完整指南 / 踩坑知识库 |

---

## 参考

- **LingoFuse 主仓库**：https://github.com/PassByYou888/LingoFuse
- **nlohmann/json**：https://github.com/nlohmann/json
- **Zig 官方文档**：https://ziglang.org/documentation/0.17.0/

## 许可

与主仓库一致，详见仓库根目录 `LICENSE`。
