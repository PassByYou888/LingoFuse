# LingoFuse Dart Binding

> Dart 语言对 [LingoFuse](https://github.com/PassByYou888/LingoFuse) 的官方绑定。
> 基于 Dart FFI + 一个极小的 C 桥接 DLL，支持完整的 caller 端和 server 端能力。
>
> **本绑定位于 LingoFuse 主仓库的 `dart/` 目录下**，与 Pascal、Python、C++、C#、TypeScript、JavaScript、Rust、Go 等第一方绑定并列。

---

## 目录

- [这是什么](#这是什么)
- [能力范围](#能力范围)
- [目录结构](#目录结构)
- [环境准备](#环境准备)
- [环境验证](#环境验证)
- [项目初始化](#项目初始化)
- [编译 C 桥接 DLL](#编译-c-桥接-dll)
- [多平台编译](#多平台编译)
- [运行测试](#运行测试)
- [测试与 POC 验证](#测试与-poc-验证)
- [快速开始：最小示例](#快速开始最小示例)
- [跨语言互操作](#跨语言互操作)
- [API 参考](#api-参考)
- [运行时选项](#运行时选项)
- [清理顺序](#清理顺序)
- [故障排查](#故障排查)
- [已知限制](#已知限制)
- [相关项目](#相关项目)
- [License](#license)

---

## 这是什么

LingoFuse 是一个跨语言 RPC 框架，核心承诺：**任何语言写的函数，任何其他语言都能直接调**。

这个 Dart 绑定通过以下三层实现：

```
Dart 应用代码
    ↓ (package:lingofuse)
Dart FFI 层  →  LingoFuse64.dll  (C ABI, 37 个导出函数)
    ↓ (bridge/lf_dart_bridge.dll)
C 桥接层  ←→  Dart 主 isolate（通过原生 port）
```

C 桥接层是必需的，原因在[编译 C 桥接 DLL](#编译-c-桥接-dll)一节详细说明。

---

## 能力范围

| 能力 | 状态 | 说明 |
|---|:---:|---|
| 加载 LingoFuse DLL | ✅ | 自动平台探测 |
| 创建/读写 DataHandle | ✅ | 完整支持 |
| JSON / 字符串 / 字节 I/O | ✅ | 与其他绑定字节级兼容 |
| 作为 **caller** 调用远程 API | ✅ | `Framework.call` / `notify` / `sequencedNotify` |
| 作为 **server** 注册 Call API | ✅ | 通过 C 桥接实现同步语义 |
| 作为 **server** 注册 Notify API | ✅ | 同上 |
| NetworkEvents（网络事件回调） | ⚠️ | 未实现（需要额外的桥接通道） |
| 状态队列 | ✅ | `LingoFuseStatus` |

**不支持**：
- Flutter Web（Dart FFI 不可用）
- 32 位 Windows（未测试）

---

## 目录结构

```
dart/
├── pubspec.yaml                  包定义 + ffigen 配置
├── dart_test.yaml                强制测试串行执行
├── check-env.ps1                 环境诊断脚本（Windows）
├── lf_dart_bridge.dll            编译产物（复制到此处）
│
├── bridge/                       ★ C 桥接源码
│   ├── lf_dart_bridge.h
│   ├── lf_dart_bridge.c
│   ├── build.ps1                 Windows 编译脚本
│   ├── build.sh                  Linux / macOS 编译脚本
│   ├── dart_api_dl.h             ← 从 Dart SDK 拷贝
│   ├── dart_api_dl.c             ← 从 Dart SDK 拷贝
│   ├── dart_api.h                ← 从 Dart SDK 拷贝
│   ├── dart_native_api.h         ← 从 Dart SDK 拷贝
│   ├── dart_tools_api.h          ← 从 Dart SDK 拷贝
│   ├── dart_version.h            ← 从 Dart SDK 拷贝
│   └── internal/
│       └── dart_api_dl_impl.h    ← 从 Dart SDK 拷贝
│
├── headers/
│   └── LingoFuse.h               ← 从 LingoFuse 仓库拷贝
│
├── lib/
│   ├── lingofuse.dart            公开入口
│   └── src/
│       ├── bindings_generated.dart   ffigen 生成
│       ├── runtime.dart              DLL 加载
│       ├── errors.dart               异常层次
│       ├── data_handle.dart          RAII 数据句柄
│       ├── io.dart                   JSON / 字符串 I/O
│       ├── framework.dart            进程级门面
│       ├── app_handle.dart           RAII 应用句柄
│       ├── status.dart               状态队列
│       └── bridge/
│           ├── bridge_ffi.dart       C 桥接的 FFI 声明
│           └── bridge_host.dart      Dart 侧 port 监听
│
├── bin/
│   ├── lf_probe.dart             最小加载测试
│   ├── phase1_test.dart          DataHandle 层测试
│   ├── phase2_test.dart          caller 侧测试
│   └── phase3_test.dart          server 端到端测试
│
├── test/
│   ├── data_handle_test.dart     DataHandle 层测试
│   ├── io_test.dart              LfIo 层测试
│   ├── status_test.dart          状态队列测试
│   └── server_test.dart          端到端集成测试
│
├── example/                      完整示例
├── native/                       备用原生库目录
└── tool/                         辅助工具目录
```

---

## 环境准备

### 1. Dart SDK

**下载地址**（zip 解压版，无需安装器）：

官方：
```
https://storage.googleapis.com/dart-archive/channels/stable/release/3.6.2/sdk/dartsdk-windows-x64-release.zip
```

国内镜像（推荐）：
```
https://storage.flutter-io.cn/dart-archive/channels/stable/release/3.6.2/sdk/dartsdk-windows-x64-release.zip
```

**安装步骤**：

1. 解压到 `D:\dart-sdk`（路径不要有中文和空格）
2. 将 `D:\dart-sdk\bin` 加入系统 PATH：
   ```powershell
   # 管理员 PowerShell
   $p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
   if ($p -notlike '*D:\dart-sdk\bin*') {
       [Environment]::SetEnvironmentVariable('Path', "$p;D:\dart-sdk\bin", 'Machine')
   }
   ```
3. **关闭并重开 PowerShell**，运行：
   ```powershell
   dart --version
   ```
   应输出 `Dart SDK version: 3.6.2` 或更高。

### 2. VSCode + Dart 插件

1. 从 https://code.visualstudio.com/ 下载并安装 VSCode
2. 打开 VSCode，按 `Ctrl+Shift+X` 打开扩展市场
3. 搜索 **Dart**，安装由 **Dart Code** 发布的官方插件
4. 打开本项目目录，VSCode 会自动识别 `pubspec.yaml`

### 3. Visual Studio 2022

**必须安装 C++ 工作负载**，否则无法编译桥接 DLL。

1. 打开 **Visual Studio Installer**
2. 找到 VS2022，点击 **修改**
3. 勾选 **使用 C++ 的桌面开发**（Desktop development with C++）
4. 在右侧确认勾选了：
   - MSVC v143 - VS 2022 C++ x64/x86 生成工具
   - Windows 11 SDK（或 Windows 10 SDK）
   - C++ CMake 工具 for Windows
5. 点击 **修改** 完成安装

### 4. LLVM

`ffigen` 依赖 LLVM 的 `libclang`。

**下载地址**：
```
https://github.com/llvm/llvm-project/releases
```

在最新 release 的 Assets 中找 `LLVM-*-win64.exe`（如 `LLVM-19.1.7-win64.exe`）。

**安装步骤**：

1. 运行安装程序
2. **务必勾选** `Add LLVM to the system PATH for all users`
3. 建议安装到 `C:\LLVM`
4. 重开 PowerShell，运行：
   ```powershell
   clang --version
   ```
   应输出版本号。

### 5. CMake

如果 VS2022 勾选了 **C++ CMake 工具**，CMake 已经随 VS 安装，跳过此步。

如需要独立安装：
```
https://cmake.org/download/
```
下载 `cmake-*-windows-x64.msi`，安装时勾选 **Add CMake to the system PATH for all users**。

---

## 环境验证

`check-env.ps1` 会逐项检查所有依赖，并尝试一次真实的 DLL 调用。

**运行**：

```powershell
cd D:\CoreLibrary\LingoFuse\dart
powershell -ExecutionPolicy Bypass -File .\check-env.ps1
```

**预期输出**（全部 [OK]）：

```
==================================================================
  0. System Information
==================================================================
         OS:         Microsoft Windows Server 2022 Datacenter
         ...
==================================================================
  1. Dart SDK
==================================================================
  [OK]   dart command available: D:\dart-sdk\bin\dart.exe
         Dart SDK version: 3.6.2 (stable) ...
==================================================================
  2. VSCode
==================================================================
  [OK]   code command available: ...
  [OK]   Dart extension installed: dart-code.dart-code-3.144.0
==================================================================
  3. Visual Studio 2022
==================================================================
  [OK]   C++ desktop workload installed (MSVC v143)
  [OK]   VS built-in CMake component installed
  [OK]   found vcvars64.bat: ...
==================================================================
  4. LLVM / clang
==================================================================
  [OK]   clang command available: C:\LLVM\bin\clang.exe
  [OK]   found libclang.dll: C:\LLVM\bin\libclang.dll
==================================================================
  5. CMake
==================================================================
  [OK]   cmake command available: ...
==================================================================
  6. Git
==================================================================
  [OK]   git command available: ...
==================================================================
  7. LingoFuse native library (.dll)
==================================================================
  [OK]   found LingoFuse64.dll : D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll
  [OK]   found dependency z_ipc_64.dll : ...
  [OK]   found dependency mimalloc64.dll : ...
==================================================================
  8. PATH key entries
==================================================================
  [OK]   dart -> D:\dart-sdk\bin
  [OK]   llvm -> C:\LLVM\bin
  [OK]   cmake -> C:\Program Files\CMake\bin
  [OK]   LingoFuse -> D:\CoreLibrary\LingoFuse\Binary
==================================================================
Summary
==================================================================
  [OK]   All required components are ready. You can start Dart FFI development.
```

**如果有任何 [FAIL]**：

- **Dart SDK 缺失** → 按上文步骤 1 安装
- **VSCode / Dart 插件缺失** → 按上文步骤 2 安装
- **VS2022 C++ 工作负载缺失** → 按上文步骤 3 通过 Installer 添加
- **LLVM/libclang 缺失** → 按上文步骤 4 安装
- **CMake 缺失** → 按上文步骤 5 安装
- **LingoFuse64.dll 未找到** → 确认 `D:\CoreLibrary\LingoFuse\Binary\` 存在且包含三个 DLL

**同时确认 `D:\CoreLibrary\LingoFuse\Binary` 已在 PATH 中**：

```powershell
$env:PATH -split ';' | Select-String 'LingoFuse'
```

应输出 `D:\CoreLibrary\LingoFuse\Binary`。如果没输出，以管理员身份运行：

```powershell
$p = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$p;D:\CoreLibrary\LingoFuse\Binary", 'Machine')
```

然后**关闭并重开 PowerShell**。

---

## 项目初始化

### 1. 拉取依赖

```powershell
cd D:\CoreLibrary\LingoFuse\dart
dart pub get
```

会下载 `ffi`、`path`、`ffigen`、`test` 及其传递依赖。

### 2. 生成 FFI 绑定

`ffigen` 解析 `headers/LingoFuse.h`，自动生成 `lib/src/bindings_generated.dart`。

```powershell
dart run ffigen
```

**预期输出**：

```
[INFO]   : Running in Directory: 'D:\CoreLibrary\LingoFuse\dart'
[INFO]   : Input Headers: [file:///D:/CoreLibrary/LingoFuse/dart/headers/LingoFuse.h]
[INFO]   : Finished, Bindings generated in D:\CoreLibrary\LingoFuse\dart\lib\src\bindings_generated.dart
```

**如果报错 `Couldn't find dynamic library in default locations`**：

说明 `ffigen` 找不到 `libclang.dll`。确认 `pubspec.yaml` 的 `ffigen` 段包含：

```yaml
ffigen:
  # ...
  llvm-path:
    - 'C:\LLVM'
    - 'C:\LLVM\bin'
```

---

## 编译 C 桥接 DLL

### 为什么要 C 桥接

Dart FFI 的回调机制只有两种：

| 模式 | 能否从任意原生线程调用 | 同步/异步 |
|---|:---:|:---:|
| `NativeCallable.isolateLocal` | ❌ 只能从创建它的 isolate 线程 | 同步 |
| `NativeCallable.listener` | ✅ 可以从任意线程调用 | **异步** |

LingoFuse 的 Call 回调运行在原生 worker 线程上，因此**只能**用 `listener`。但 `listener` 是**异步**的——原生线程发起回调后**立即返回**，不等 Dart 处理完。而 LingoFuse 在回调返回后**立即释放** input / output 缓冲区。等 Dart 回调真正跑起来时，原生 buffer 可能已被回收。

**C 桥接层的解决方案**：

```
LingoFuse 原生线程                    Dart 主 isolate
     │                                    │
     │  1. 快照 input 字节到堆              │
     │  2. 通过 Dart_PostCObject_DL 投递 ──→  3. 收到消息，调用用户 handler
     │                                    │  4. 通过 lf_bridge_complete 回传
     │  5. 阻塞等待（信号量）       ←──────│
     │  6. 把 output 写入 LingoFuse handle  │
     │  7. 返回，LingoFuse 释放 buffer      │
```

**关键**：原生线程在第 5 步**阻塞等待**，直到 Dart 处理完才返回。这样就把异步回调转成了同步语义，与 LingoFuse 的假设一致。

### 步骤 1：拷贝 Dart SDK 头文件

**这是编译前最关键的一步。**

Dart SDK 的头文件位于 `D:\dart-sdk\include\`，包括：

```
D:\dart-sdk\include\
├── dart_api.h
├── dart_api_dl.h
├── dart_native_api.h
├── dart_tools_api.h
├── dart_version.h
└── internal\
    └── dart_api_dl_impl.h
```

**其中 `dart_api_dl.c` 不在 SDK include 目录里**，需要从 Dart SDK 的 GitHub 源码仓库下载：

```
https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c
```

**完整的拷贝操作**：

```powershell
# 1. 创建 bridge 目录（如果还没有）
New-Item -ItemType Directory -Force -Path D:\CoreLibrary\LingoFuse\dart\bridge | Out-Null
New-Item -ItemType Directory -Force -Path D:\CoreLibrary\LingoFuse\dart\bridge\internal | Out-Null

# 2. 拷贝全部头文件（包括子目录 internal/）
Copy-Item D:\dart-sdk\include\*.h    D:\CoreLibrary\LingoFuse\dart\bridge\ -Force
Copy-Item D:\dart-sdk\include\internal\*.h D:\CoreLibrary\LingoFuse\dart\bridge\internal\ -Force

# 3. 下载 dart_api_dl.c 到 bridge\ 目录
#    （用浏览器打开下面的链接，右键"另存为"到 bridge\ 目录）
#    https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c

# 4. 验证文件齐全
Get-ChildItem D:\CoreLibrary\LingoFuse\dart\bridge\ -Recurse -File | Format-Table Name, Length
```

**`bridge\` 目录最终应包含**（与 `lf_dart_bridge.*` 和 `build.ps1` 同级）：

| 文件 | 来源 |
|---|---|
| `lf_dart_bridge.h` | 本仓库 |
| `lf_dart_bridge.c` | 本仓库 |
| `build.ps1` | 本仓库 |
| `dart_api.h` | 从 `D:\dart-sdk\include\` 拷贝 |
| `dart_api_dl.h` | 从 `D:\dart-sdk\include\` 拷贝 |
| `dart_native_api.h` | 从 `D:\dart-sdk\include\` 拷贝 |
| `dart_tools_api.h` | 从 `D:\dart-sdk\include\` 拷贝 |
| `dart_version.h` | 从 `D:\dart-sdk\include\` 拷贝 |
| `internal\dart_api_dl_impl.h` | 从 `D:\dart-sdk\include\internal\` 拷贝 |
| `dart_api_dl.c` | 从 Dart SDK GitHub 下载 |

**为什么要全部拷贝**：

- `dart_api_dl.h` 内部 `#include "dart_api.h"`
- `dart_api.h` 内部又 `#include "dart_native_api.h"`、`"dart_version.h"`
- `dart_api_dl.c` 内部 `#include "internal/dart_api_dl_impl.h"`

把整个 `include/` 目录的树复制到 `bridge/` 后，编译器就能在**当前目录**找到所有依赖，不需要额外的 `-I` 参数指向 SDK 路径。这样桥接目录是**自包含**的，编译不依赖 Dart SDK 的位置。

### 步骤 2：确认源文件齐全

在运行编译脚本之前，先确认必需的源文件都在：

```powershell
cd D:\CoreLibrary\LingoFuse\dart\bridge

foreach ($f in @(
    'lf_dart_bridge.h',
    'lf_dart_bridge.c',
    'build.ps1',
    'dart_api.h',
    'dart_api_dl.h',
    'dart_api_dl.c',
    'dart_native_api.h',
    'dart_tools_api.h',
    'dart_version.h',
    'internal\dart_api_dl_impl.h'
)) {
    if (Test-Path $f) {
        Write-Host "[OK]   $f"
    } else {
        Write-Host "[FAIL] $f MISSING" -ForegroundColor Red
    }
}
```

全部 [OK] 后再进行下一步。

### 步骤 3：运行 build.ps1

**这是编译的核心命令**：

```powershell
cd D:\CoreLibrary\LingoFuse\dart\bridge
.\build.ps1
```

**如果提示执行策略限制**：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

**build.ps1 内部做了什么**（三步）：

1. **定位 `vcvars64.bat`** — 搜索 `C:\Program Files\Microsoft Visual Studio\2022\*\VC\Auxiliary\Build\vcvars64.bat`
2. **调用 `vcvars64.bat`** — 在一个 `cmd.exe` 子进程里设置 MSVC 编译环境（PATH、INCLUDE、LIB 等）
3. **调用 `cl.exe`** — 编译 `lf_dart_bridge.c` 和 `dart_api_dl.c`，链接成 `lf_dart_bridge.dll`

**`cl.exe` 的完整参数**：

```
/nologo                     抑制版权信息
/O2                         优化级别 2（速度）
/LD                         生成 DLL
/MD                         使用多线程 DLL 运行时
/W3                         警告级别 3
/I.                         头文件搜索路径：当前目录
/I..\headers                头文件搜索路径：上级 headers 目录（LingoFuse.h）
lf_dart_bridge.c            源文件
dart_api_dl.c               源文件
/Fe:lf_dart_bridge.dll      输出文件名
```

**预期输出**：

```
============================================================
  LingoFuse Dart Bridge Build (v3)
============================================================

[OK]   Found dart_api.h at: D:\CoreLibrary\LingoFuse\dart\bridge\dart_api.h
[OK]   All source files present
[OK]   Found vcvars64.bat: C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat

[INFO] Compiling lf_dart_bridge.dll ...
[INFO] Include paths: . ; ..\headers ; <dart SDK include>

lf_dart_bridge.c
dart_api_dl.c
正在生成代码...
  正在创建库 lf_dart_bridge.lib 和对象 lf_dart_bridge.exp

[OK]   Built: D:\CoreLibrary\LingoFuse\dart\bridge\lf_dart_bridge.dll
[INFO] Size:  ~19000 bytes
```

**常见编译错误**：

| 错误 | 原因 | 修复 |
|---|---|---|
| `fatal error C1083: 无法打开包括文件: "dart_api.h"` | `dart_api.h` 未拷贝到 `bridge\` | 重新执行步骤 1 |
| `fatal error C1083: 无法打开包括文件: "internal/dart_api_dl_impl.h"` | `internal\` 子目录未拷贝 | 检查 `bridge\internal\dart_api_dl_impl.h` 存在 |
| `error LNK2019: 无法解析的外部符号 Dart_InitializeApiDL` | `dart_api_dl.c` 未加入编译 | 确认 `bridge\dart_api_dl.c` 存在 |
| `[FAIL] vcvars64.bat not found` | VS2022 未安装 C++ 工作负载 | 打开 VS Installer 添加工作负载 |

### 步骤 4：复制 DLL 到项目根

Dart 运行时从 CWD 或 `bridge/` 子目录加载 `lf_dart_bridge.dll`。把它复制到项目根，便于所有脚本访问：

```powershell
Copy-Item D:\CoreLibrary\LingoFuse\dart\bridge\lf_dart_bridge.dll `
          D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll -Force
```

**验证 DLL 存在**：

```powershell
Get-ChildItem D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll |
    Format-Table Name, Length, LastWriteTime
```

---

## 多平台编译

`lf_dart_bridge.c` 使用**条件编译**同时支持 Windows、Linux 和 macOS。上层逻辑不感知平台差异。

### 平台抽象层

桥接代码内部定义了一组 `lf_*` 前缀的抽象函数，每个平台提供自己的实现：

| 功能 | Windows | Linux / macOS |
|---|---|---|
| 动态库句柄 | `HMODULE` | `void*` |
| 加载动态库 | `LoadLibraryA` | `dlopen` |
| 解析符号 | `GetProcAddress` | `dlsym` |
| 卸载动态库 | `FreeLibrary` | `dlclose` |
| 互斥锁 | `CRITICAL_SECTION` | `pthread_mutex_t` |
| 信号量 | `CreateSemaphoreA` / `WaitForSingleObject` | `sem_init` / `sem_wait` / `sem_post` |
| 原子自增 | `InterlockedIncrement` | `atomic_fetch_add` |
| LingoFuse 库名 | `LingoFuse64.dll` | `liblingofuse.so` / `liblingofuse.dylib` |

### 各平台操作清单

#### Windows（已验证）

| 步骤 | 命令 |
|---|---|
| 1 | 从 `D:\dart-sdk\include\` 拷贝所有 `.h` 到 `bridge\`，包括 `internal\` 子目录 |
| 2 | 从 Dart SDK GitHub 下载 `dart_api_dl.c` 到 `bridge\` |
| 3 | `cd bridge; .\build.ps1` |
| 4 | `copy bridge\lf_dart_bridge.dll dart\` |

#### Linux

| 步骤 | 命令 |
|---|---|
| 1 | 安装编译工具链：`sudo apt install build-essential`（Debian/Ubuntu）或 `sudo dnf groupinstall "Development Tools"`（Fedora） |
| 2 | 从 Dart SDK 的 `include/` 目录拷贝所有头文件到 `bridge/`（包括 `internal/` 子目录） |
| 3 | 从 [Dart SDK GitHub](https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c) 下载 `dart_api_dl.c` 到 `bridge/` |
| 4 | `cd bridge; chmod +x build.sh; ./build.sh` |
| 5 | `cp bridge/lf_dart_bridge.so dart/` |

**Linux 额外依赖**：
- LingoFuse 的 Linux 版本 `liblingofuse.so` 必须能从 PATH / `LD_LIBRARY_PATH` 找到
- 如果 LingoFuse 官方提供了 Linux 预编译库，直接使用即可

#### macOS

| 步骤 | 命令 |
|---|---|
| 1 | 安装 Xcode Command Line Tools：`xcode-select --install` |
| 2 | 从 Dart SDK 的 `include/` 目录拷贝所有头文件到 `bridge/` |
| 3 | 从 [Dart SDK GitHub](https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c) 下载 `dart_api_dl.c` 到 `bridge/` |
| 4 | `cd bridge; chmod +x build.sh; ./build.sh` |
| 5 | `cp bridge/lf_dart_bridge.dylib dart/` |

**macOS 额外注意事项**：
- Apple Silicon（arm64）与 Intel（x86_64）是不同架构，bridge 需要按本机架构编译
- 如果 LingoFuse 官方提供了 macOS 预编译库，直接使用即可

### 关于 LingoFuse 核心库

**LingoFuse 核心库由官方提供预编译的多平台版本。** Dart 绑定开发者不需要自行编译 LingoFuse 核心库。

官方仓库的 `Binary/` 目录包含：

| 平台 | 核心库 | IPC 依赖 | 内存分配器 |
|---|---|---|---|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` | `libmimalloc.so`（可选） |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` | `libmimalloc.dylib`（可选） |

**部署方式**：将 `Binary/` 目录加入系统 PATH，或把动态库复制到可执行文件同目录。

Windows 下需安装 **VC++ 2015-2022 可再发行程序包**：
- [最新受支持的 Visual C++ 可再发行程序包](https://learn.microsoft.com/zh-cn/cpp/windows/latest-supported-vc-redist?view=msvc-170)

### build.sh（Linux / macOS）

新建 `bridge/build.sh`：

```bash
#!/usr/bin/env bash
# LingoFuse Dart Bridge Build (Unix)

set -e

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BRIDGE_DIR"

echo "============================================================"
echo "  LingoFuse Dart Bridge Build (Unix)"
echo "============================================================"
echo

# ---- 1. Check required source files --------------------------------
REQUIRED=(
    "lf_dart_bridge.h"
    "lf_dart_bridge.c"
    "dart_api.h"
    "dart_api_dl.h"
    "dart_api_dl.c"
    "dart_native_api.h"
    "dart_tools_api.h"
    "dart_version.h"
    "internal/dart_api_dl_impl.h"
    "../headers/LingoFuse.h"
)

MISSING=0
for f in "${REQUIRED[@]}"; do
    if [ ! -f "$f" ]; then
        echo "[FAIL] Missing: $f"
        MISSING=1
    fi
done
if [ "$MISSING" -ne 0 ]; then
    echo
    echo "See README.md, section 'Compiling the C bridge', for the"
    echo "list of files that must be copied from D:\\dart-sdk\\include."
    exit 1
fi

echo "[OK]   All source files present"

# ---- 2. Compile -----------------------------------------------------
OS_NAME="$(uname -s)"
case "$OS_NAME" in
    Linux*)  OUT="lf_dart_bridge.so" ;;
    Darwin*) OUT="lf_dart_bridge.dylib" ;;
    *)
        echo "[FAIL] Unsupported OS: $OS_NAME"
        exit 1
        ;;
esac

CC="${CC:-cc}"

echo
echo "[INFO] Compiling $OUT with $CC ..."
echo

# Linux needs -lpthread and -ldl; macOS has them built in.
if [ "$OS_NAME" = "Linux" ]; then
    EXTRA_LIBS="-lpthread -ldl"
else
    EXTRA_LIBS=""
fi

$CC -O2 -fPIC -shared -Wall \
    -I. \
    -I../headers \
    lf_dart_bridge.c \
    dart_api_dl.c \
    $EXTRA_LIBS \
    -o "$OUT"

if [ $? -ne 0 ]; then
    echo "[FAIL] Compilation failed"
    exit 1
fi

# ---- 3. Verify output ----------------------------------------------
if [ ! -f "$OUT" ]; then
    echo "[FAIL] Compilation reported success but $OUT was not created"
    exit 1
fi

SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")
echo
echo "[OK]   Built: $BRIDGE_DIR/$OUT"
echo "[INFO] Size:  $SIZE bytes"
```

**使用**：

```bash
cd bridge
chmod +x build.sh
./build.sh
```

### 跨平台 Dart 侧调整

`lib/src/bridge/bridge_ffi.dart` 中的 `load()` 方法需要按平台选择正确的文件名：

```dart
static BridgeFfi load() {
  final env = Platform.environment['LINGOFUSE_BRIDGE_DLL'];
  if (env != null && env.isNotEmpty) {
    return BridgeFfi(DynamicLibrary.open(env));
  }

  final bridgeName = Platform.isWindows
      ? 'lf_dart_bridge.dll'
      : Platform.isMacOS
          ? 'lf_dart_bridge.dylib'
          : 'lf_dart_bridge.so';

  final candidates = [
    'bridge/$bridgeName',
    bridgeName,
  ];
  Object? lastError;
  for (final c in candidates) {
    try {
      return BridgeFfi(DynamicLibrary.open(c));
    } catch (e) {
      lastError = e;
    }
  }
  throw StateError(
      'Could not load $bridgeName. Set LINGOFUSE_BRIDGE_DLL '
      'or place the library next to the executable. Last error: $lastError');
}
```

---

## 运行测试

### 测试结构

| 文件 | 依赖框架 | 说明 |
|---|:---:|---|
| `test/data_handle_test.dart` | ❌ | DataHandle 层：构造、字节、标量、字符串、位置、生命周期 |
| `test/io_test.dart` | ❌ | LfIo 层：JSON 序列化、字符串/字节 I/O |
| `test/status_test.dart` | ❌ | 状态队列 |
| `test/server_test.dart` | ✅ | 端到端：Framework + AppHandle + C 桥接 + 远程调用 |

`dart_test.yaml` 强制 `concurrency: 1`，因为框架状态是进程级共享的。

### 运行全部测试

```powershell
cd D:\CoreLibrary\LingoFuse\dart
dart test
```

**预期输出**：

```
00:00 +0: loading test\data_handle_test.dart
00:00 +38: test\data_handle_test.dart: All tests passed!
00:00 +58: test\io_test.dart: All tests passed!
00:00 +63: test\status_test.dart: All tests passed!
00:01 +63: test\server_test.dart: (setUpAll)
... (LingoFuse native startup logs) ...
00:05 +76: All tests passed!
```

### 运行单个测试文件

```powershell
dart test test\data_handle_test.dart
dart test test\server_test.dart
```

### 详细输出模式

```powershell
dart test --reporter expanded
```

### 只运行匹配名字的测试

```powershell
dart test --name "echo"
dart test --name "uint64"
```

### 测试失败时的诊断

```powershell
dart test --chain-stack-traces
```

---

## 测试与 POC 验证

### 什么是测试，什么是 POC

在 LingoFuse 生态中，**测试（Test）** 和 **POC（Proof of Concept）** 是两个不同的概念：

| 维度 | 测试（Test） | POC（Proof of Concept） |
|---|---|---|
| **目的** | 验证绑定层本身的正确性 | 验证 LingoFuse 在**你自己的业务场景**下的表现 |
| **范围** | API 契约、序列化、生命周期、回调 | 你的 App 层逻辑、你的并发模式、你的数据量 |
| **提供者** | LingoFuse 仓库提供 | **用户自己构建** |
| **例子** | `DataHandle` 能否正确读写 int32 | 你的订单系统能否在高并发下稳定调用 Dart 服务 |

### Dart 绑定的测试体系

Dart 绑定提供**单元测试**和**端到端集成测试**两个层次：

**单元测试**（`data_handle_test.dart`、`io_test.dart`、`status_test.dart`）：
- 不依赖 LingoFuse 框架启动
- 验证 `DataHandle` 的字节、标量、字符串 I/O
- 验证 `LfIo` 的 JSON 序列化与跨语言字节级一致性
- 验证 `LingoFuseStatus` 的队列操作

**端到端集成测试**（`server_test.dart`）：
- 启动完整的 LingoFuse 框架（service + client + C 桥接）
- 注册 Call/Notify API
- 通过子 isolate 发起远程调用
- 验证完整的「准备 → 连接 → App 注册 → 广播 → 路由 → 回调 → 返回」链路

**注意**：`server_test.dart` 中的服务端和调用端在**同一进程内**运行，因此 `LF_Call` 走的是 mesh 的本地优先路由路径。它流经完整的原生调用链，但没有跨越 TCP 或跨进程 IPC 跳。

### POC：用户自己构建

LingoFuse 官方明确说明：**Dart 绑定提供的测试是机制层测试，不是你的 App 层测试。**

在你的业务中使用 Dart 绑定之前，需要：

1. **用你自己的业务场景构建 PoC**：模拟你的 App 层逻辑，验证 LingoFuse 在你的数据量、并发模式和错误处理下的表现
2. **跨进程验证**：启动两个独立 Dart 进程（或 Dart + 另一种语言的进程），验证跨进程 IPC/TCP 调用
3. **长时间运行稳定性**：让 Dart server 运行 24 小时以上，观察内存和线程稳定性

### POC 建议场景

| 场景 | 验证内容 |
|---|---|
| Dart server + Pascal client | 跨语言互操作性（Dart 作为服务端） |
| Dart client + Python server | 跨语言互操作性（Dart 作为调用端） |
| 高并发 Call 请求 | C 桥接的串行化对性能的影响 |
| 大数据传输（>100 MB） | 内存占用和传输稳定性 |
| 断线重连 | 网络中断后的自动恢复 |

---

## 快速开始：最小示例

### 服务端

创建 `bin/my_server.dart`：

```dart
// Minimal LingoFuse server in Dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

Future<void> main() async {
  // Step 1: start the C bridge host.
  await BridgeHost.start();

  // Step 2: create an application and register a Call API.
  final app = AppHandle('MyDartServer', 'Minimal example');

  app.registerCall('echo', 'Echo the input string', (Uint8List input) {
    final text = String.fromCharCodes(input);
    return Uint8List.fromList('Echo: $text'.codeUnits);
  });

  app.registerCall('add', 'Add two int32 (little-endian)', (Uint8List input) {
    final bd = ByteData.sublistView(input);
    final a = bd.getInt32(0, Endian.little);
    final b = bd.getInt32(4, Endian.little);
    return (ByteData(4)..setInt32(0, a + b, Endian.little))
        .buffer
        .asUint8List();
  });

  // Step 3: configure and start the framework.
  Framework.setOption('Quiet', 'False');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService('ipc:my_dart_server', 'ipc:my_dart_server');
  Framework.prepareClient('ipc:my_dart_server', app: app);

  if (!Framework.prepareDone()) {
    stderr.writeln('Framework failed to start');
    exit(1);
  }

  print('Server ready on "ipc:my_dart_server".');
  print('Press Enter to stop.');
  stdin.readLineSync();

  // Step 4: cleanup in the required order.
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
}
```

**运行**：

```powershell
dart run bin/my_server.dart
```

### 客户端

创建 `bin/my_client.dart`：

```dart
// Minimal LingoFuse client in Dart.

import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

void main() {
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.resetPrepare();
  Framework.prepareClient('ipc:my_dart_server');
  Framework.prepareDone();

  // Wait for the server to become visible.
  for (int i = 0; i < 30; i++) {
    if (Framework.checkApp('MyDartServer')) break;
    sleep(Duration(milliseconds: 100));
  }

  // Call "echo".
  final echoParam = DataHandle('echo');
  echoParam.writeBytes('hello from Dart client'.codeUnits);
  echoParam.position = 0;
  final echoResp = Framework.call('MyDartServer', echoParam, timeoutMs: 5000);
  print('echo: ${String.fromCharCodes(echoResp.readBytes(echoResp.size))}');
  echoResp.dispose();
  echoParam.dispose();

  // Call "add".
  final addParam = DataHandle('add');
  addParam.writeInt32(15);
  addParam.writeInt32(27);
  addParam.position = 0;
  final addResp = Framework.call('MyDartServer', addParam, timeoutMs: 5000);
  print('add: ${addResp.readInt32()}');
  addResp.dispose();
  addParam.dispose();

  Framework.exitMainThread();
  Framework.shutdown();
}

void sleep(Duration d) {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {}
}
```

**运行**：

```powershell
dart run bin/my_client.dart
```

**预期输出**：

```
echo: Echo: hello from Dart client
add: 42
```

---

## 跨语言互操作

Dart server 可以被**任何其他语言的 LingoFuse 客户端**调用，因为底层走的是同一套 C4 服务网格。同样，Dart 客户端可以调用任何语言实现的服务。

### 线协议

| 元素 | 编码 |
|---|---|
| 字符串 | UTF-8 字节 + `0x00` |
| 整数 | 小端序 |
| 浮点 | IEEE 754，小端序 |
| JSON | 紧凑、字面 UTF-8、无 `\uXXXX` 转义 |
| 原始字节 | 任意字节 + `0x00` |

这些规则与 Pascal / Python / C++ / C# / Rust / Go / JavaScript 的绑定完全一致。

### 跨语言调用示例

**Dart server 被 Python client 调用**：

Dart 端注册：
```dart
app.registerCall('echo', 'Echo', (Uint8List input) => input);
```

Python 端调用：
```python
from lingofuse import C4
client = C4("MyDartServer", "ipc:my_dart_server")
result = client.echo(b"hello from Python")
```

**Python server 被 Dart client 调用**：

```dart
final param = DataHandle('compute');
LfIo.writeJson(param, {'expression': '1+2*3'});
param.position = 0;
final resp = Framework.call('PythonApp', param, timeoutMs: 5000);
```

---

## API 参考

### `DataHandle`

```dart
// Construction
DataHandle(String apiName)                              // auto-recycled
DataHandle.createPermanent(String apiName)              // permanent
DataHandle.fromRaw(Pointer<Void> raw, {bool owned = false})

// Properties
int get position / set position(int)
int get size / set size(int)
bool get isValid
bool get isOwning

// Byte I/O
int writeBytes(List<int>)
Uint8List readBytes(int)
Uint8List readBytesExact(int)             // throws on short read
Uint8List readAllBytes()
Uint8List readBytesUntilNul()

// Scalar I/O (little-endian)
void writeInt8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Single/Double(...)
int/double readInt8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Single/Double()

// String I/O (UTF-8, NUL-framed)
void writeString(String)
String readString()

// Lifetime
void dispose()
```

### `LfIo`

```dart
// JSON string helpers (no handle)
static String dumpsJson(Object? value)
static T loadsJson<T>(String text)

// String I/O on handle
static void writeString(DataHandle, String)
static String readString(DataHandle)

// Byte I/O on handle
static void writeStringBytes(DataHandle, Uint8List)
static Uint8List readStringBytes(DataHandle)
static Uint8List readAllBytes(DataHandle)

// JSON I/O on handle
static void writeJson(DataHandle, Object?)
static T readJson<T>(DataHandle)
static T? tryReadJson<T>(DataHandle)
```

### `Framework`

```dart
// Network preparation
static void resetPrepare()
static int prepareService(String listeningAddr, String physicsAddr)
static int prepareClient(String physicsAddr, {AppHandle? app})
static bool prepareDone()
static void exitMainThread()
static void shutdown()

// Runtime options
static void setOption(String option, String value)

// Name generation
static String generateAppName()

// Health checks
static bool checkMainThread()
static bool checkApp(String appName)
static bool checkApi(String appName, String apiName)

// Remote invocation
static DataHandle call(String appName, DataHandle param, {int timeoutMs = 5000})
static DataHandle? tryCall(String appName, DataHandle param, {int timeoutMs = 5000})
static void notify(String appName, DataHandle param)
static void sequencedNotify(String appName, DataHandle param)
```

### `AppHandle`

```dart
AppHandle(String name, String description)

// Registration
void registerCall(String apiName, String description, CallHandler handler)
void registerNotify(String apiName, String description, NotifyHandler handler)
bool unregister(String apiName)

// Properties
String get name
bool get isValid
Pointer<Void> get raw

// Lifetime
void dispose()
```

### `BridgeHost`

```dart
static Future<BridgeHost> start()        // 必须在 AppHandle.registerCall 之前
static BridgeHost get instance
void stop()
```

### `LingoFuseStatus`

```dart
static int getStatusCount()
static String getStatus()
static List<String> drainStatus([int maxMessages = 64])
static void postStatus(String message)
```

---

## 运行时选项

通过 `Framework.setOption(name, value)` 设置：

| 选项 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `Quiet` | bool | `False` | 抑制内部日志 |
| `Overlap_Connection` | bool | `False` | 允许同地址多个客户端 |
| `Wait_Connection_ReadyOk` | bool | `True` | `prepareDone` 是否等待就绪 |
| `Wait_Connection_Timeout` | int ms | `30000` | 等待超时 |
| `ShowThreadID` | bool | `False` | 日志显示线程 ID |
| `ConsoleOutput` | bool | auto | 控制台输出 |
| `Fixed_Sequenced_Time` | int ms | `20000` | 顺序通知回退阈值 |

**布尔值格式**：`"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` / `"No"`（大小写不敏感）。

**未知选项名会被静默忽略**——拼错不会有任何反馈，请仔细核对。

---

## 清理顺序

**必须**按以下顺序清理，否则可能导致崩溃或资源泄漏：

```dart
app.dispose();                // 1. 解绑应用、停止顺序通知线程
Framework.exitMainThread();   // 2. 停止模拟主线程，清空数据句柄池
Framework.shutdown();         // 3. 释放原生资源、清空应用池
BridgeHost.instance.stop();   // 4. 关闭 Dart 侧 port 监听
```

用 `try/finally` 保证所有退出路径都执行。

---

## 故障排查

### `[FAIL] Couldn't find libclang.dll`

`ffigen` 找不到 LLVM。确认 `pubspec.yaml` 有 `llvm-path` 配置：

```yaml
ffigen:
  llvm-path:
    - 'C:\LLVM'
    - 'C:\LLVM\bin'
```

### `LF_CreateData returned null`

DLL 加载成功但分配失败。可能原因：
- DLL 版本与头文件不匹配
- 内存不足

用 [Dependencies](https://github.com/lucasg/Dependencies) 检查 `LingoFuse64.dll` 是否所有依赖都能解析。

### `Could not load lf_dart_bridge.dll`

- 确认 `dart\lf_dart_bridge.dll` 存在
- 或设置环境变量 `LINGOFUSE_BRIDGE_DLL` 指向完整路径
- 或用 `dart\bridge\lf_dart_bridge.dll`（`BridgeFfi.load()` 会自动搜索）

### `BridgeHost is not started`

`AppHandle.registerCall` 之前必须调用 `await BridgeHost.start()`。

### 远程调用返回空

- `checkApp` 确认目标应用可见（mesh 广播有约 3 秒延迟）
- 确认 API 名拼写正确（大小写不敏感，但必须完全匹配）
- 增加 `timeoutMs`

### `execute call-mode api "xxx" (stdcall) execpet!`

回调内部异常。常见原因：
- `Dart_InitializeApiDL(NULL)` 被跳过（C 桥接必须从 Dart 传入正确的 `NativeApi.initializeApiDLData`）
- 重新编译 `lf_dart_bridge.dll` 后未重启 Dart 进程

### 测试时卡住不动

- 远程调用**必须**在子 isolate 中执行（`Isolate.run`），否则主 isolate 事件循环会被阻塞，Dart 侧回调无法响应
- 确认 `dart_test.yaml` 中的 `concurrency: 1` 生效

### `dart test` 显示 `+N -M` 但看不到失败详情

```powershell
dart test --reporter expanded --chain-stack-traces
```

---

## 已知限制

### 1. `NativeCallable` 是异步的

这是 Dart FFI 的根本设计，C 桥接层通过阻塞等待解决，但引入了**每回调一次线程切换**的开销。高频场景下性能不如 Rust / C++ 原生绑定。

### 2. 单线程串行化

C 桥接的 `g_requests` 链表和 `g_lock` 保证了线程安全，但所有回调最终串行执行在 Dart 主 isolate 的事件循环上。Dart server 无法并行处理多个 Call 请求。

**如果需要在 Dart 端做高并发 server**，建议：
- 用多个 Dart 进程
- 或用 `Isolate` 池分摊负载
- 或换用 Rust / C++ / Go 绑定

### 3. NetworkEvents 未实现

`LF_Set_Network_Event` 的回调同样运行在原生 worker 线程，需要额外的桥接通道。当前未实现。

### 4. Flutter Web 不支持

Dart FFI 在 Flutter Web 上不可用（Web 是 JS 运行时）。

### 5. 32 位 Windows 未测试

理论上 `LingoFuse32.dll` + `dart.exe` (32-bit) 应该能工作，但未验证。

---

## 相关项目

- [LingoFuse 主仓库](https://github.com/PassByYou888/LingoFuse)
- [LingoFuse-Tools（代码生成器）](https://github.com/PassByYou888/LingoFuse-Tools)
- [zIPC（同机 IPC 引擎）](https://github.com/PassByYou888/zIPC)

---

## License

MIT。

---

*Binding version: 0.1.0*
*Target LingoFuse version: v3.10+*
*Last updated: 2026-10-02*