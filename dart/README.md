# LingoFuse Dart Binding

> Dart 语言对 [LingoFuse](https://github.com/PassByYou888/LingoFuse) 的官方绑定。
> 基于 Dart FFI + 一个极小的 C 桥接 DLL，提供**完整的 caller 端 + server 端能力**，覆盖 LingoFuse v5.x C ABI 全部 59 个导出函数、三套寻址模式、现代 async API、类型化运行时选项。
>
> **本绑定位于 LingoFuse 主仓库的 `dart/` 目录下**，与 Pascal、Python、C++、C#、TypeScript、JavaScript、Rust、Go 等第一方绑定并列。

---

## 目录

- [这是什么](#这是什么)
- [能力范围](#能力范围)
- [三套寻址模式](#三套寻址模式)
- [目录结构](#目录结构)
- [环境准备](#环境准备)
- [环境验证](#环境验证)
- [项目初始化](#项目初始化)
- [编译 C 桥接 DLL](#编译-c-桥接-dll)
- [多平台编译](#多平台编译)
- [运行测试](#运行测试)
- [测试与 POC 验证](#测试与-poc-验证)
- [快速开始：最小示例](#快速开始最小示例)
- [快速开始：现代 async API](#快速开始现代-async-api)
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

这个 Dart 绑定通过**三层架构**实现：

```
Dart 应用代码
    │
    ├── 用户 API 层
    │     DataHandle / AppHandle / Framework / LingoFuseStatus / LfIo
    │     Target / AppTarget / UIDTarget / P2PNameTarget
    │     CallPromise / AsyncBridge
    │
    ├── 桥接宿主（BridgeHost）
    │     Protocol A：同步握手（Call / Notify）
    │     Protocol B：fire-and-forget（async / network events）
    │
    └── FFI 层（双路径并存）
          Legacy 路径：bindings_generated.dart ──→ LingoFuse64.dll
          Bridge 路径：bridge_ffi.dart ──→ lf_dart_bridge.dll ──→ LingoFuse64.dll
```

**两条路径独立运行，互不干扰**：

- **Legacy 路径**直接调用 `LingoFuse64.dll` 导出的 C ABI，是 v1.x 的原始通道；所有 v1.x API 语义保持不变。
- **Bridge 路径**经过一个极小的 C 桥接 DLL，解决三个 Dart FFI 无法处理的问题：UID 结构体传值、从原生 worker 线程同步回调、临时指针生命周期。
- **v2.0 新 API**（三套寻址、现代 async、类型化 option）走 Bridge 路径；**老 API**（`Framework.call` / `DataHandle` 标量 I/O 等）走 Legacy 路径。两者共享同一个 `LingoFuse64.dll` 实例和进程级网络状态。

C 桥接层是必需的，原因在[编译 C 桥接 DLL](#编译-c-桥接-dll)一节详细说明。

---

## 能力范围

| 能力 | 状态 | 说明 |
|---|:---:|---|
| 加载 LingoFuse DLL | ✅ | 自动平台探测（Windows / Linux / macOS） |
| 创建/读写 DataHandle | ✅ | 完整支持 auto-recycled 与 permanent 两种句柄 |
| JSON / 字符串 / 字节 I/O | ✅ | 与其他绑定字节级兼容 |
| 作为 **caller** 调用远程 API | ✅ | App 名 / UID / P2PName 三套寻址全支持 |
| 作为 **server** 注册 Call API | ✅ | 通过 C 桥接实现同步语义 |
| 作为 **server** 注册 Notify API | ✅ | 同上 |
| **进程级 P2P 注册** | ✅ | `registerP2PCall` / `registerP2PNotify` |
| **异步调用（Promise 风格）** | ✅ | `target.call(...)` → `CallPromise<Uint8List>` |
| **异步调用（Callback 风格）** | ✅ | `target.callAsync(api, payload, (result, error) { ... })` |
| **异步调用（JSON 自动解码）** | ✅ | `target.callJson<T>(...)` |
| **类型化运行时选项** | ✅ | 32 个 `setOpt*` / `getOpt*` 强类型访问器 |
| **UID / P2PName 健康检查** | ✅ | `LingoFuseStatus.checkUid` / `checkP2PName` |
| **P2P 身份读取** | ✅ | `DataHandle.getP2PUid` / `getP2PName`（仅 input 句柄） |
| **NetworkEvents（网络事件回调）** | ✅ | `BridgeHost.setNetworkEvent` 已实现 |
| 状态队列 | ✅ | `LingoFuseStatus` |

**不支持**：
- Flutter Web（Dart FFI 不可用）
- 32 位 Windows（理论可行，未测试）

---

## 三套寻址模式

LingoFuse 支持**三套正交寻址**，Dart 绑定通过 `Target` 抽象统一暴露：

| 寻址模式 | Dart 类型 | 索引键 | 本地优先 | 服务端负载均衡 |
|---|---|:---:|:---:|
| **App 名** | `AppTarget` | UTF-8 字符串 | ✅ | ❌ |
| **UID** | `UIDTarget` | 32 字节二进制 | ✅ | ❌ |
| **P2PName** | `P2PNameTarget` | UTF-8 字符串 | ❌ | ✅ |

**语义差别**：

- **App 名寻址**：面向固定服务。若本进程也注册了同名 App，调用在本地执行，不走网络。
- **UID 寻址**：面向特定会话。UID 在 `TunnelLink` 成功时生成，重连后会变化；调用方需重新探测。
- **P2PName 寻址**：面向同质服务集群。**不做本地查找**，总是走服务端负载均衡。

**三套寻址共享同一组调用形状**：

```dart
// 1. Promise 风格（返回字节）
final bytes = await target.call('api', payload: {...}).future;

// 2. Promise 风格（自动 JSON 解码）
final json = await target.callJson<Map<String, dynamic>>('api').future;

// 3. Callback 风格（业务代码写在回调里）
target.callAsync('api', {...}, (result, error) {
  if (error != null) { handleError(error); return; }
  handleResult(result!);
});

// 4. 阻塞风格（需在子 isolate 中调用）
final handle = target.callSync('api', payload: {...});

// 5. 单向通知
target.notify('api', payload: {...});           // 不保证顺序
target.sequencedNotify('api', payload: {...});  // 保证 (app, api) 内 FIFO
```

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
│   ├── lf_dart_bridge.h          完整声明（~103 个导出函数）
│   ├── lf_dart_bridge.c          完整实现
│   ├── build.ps1                 Windows 编译脚本（MSVC + dumpbin 自检）
│   ├── build.sh                  Linux / macOS 编译脚本（nm 自检）
│   ├── dart_api_dl.h             ← 从 Dart SDK 拷贝
│   ├── dart_api_dl.c             ← 从 Dart SDK GitHub 下载
│   ├── dart_api.h                ← 从 Dart SDK 拷贝
│   ├── dart_native_api.h         ← 从 Dart SDK 拷贝
│   ├── dart_tools_api.h          ← 从 Dart SDK 拷贝
│   ├── dart_version.h            ← 从 Dart SDK 拷贝
│   └── internal/
│       └── dart_api_dl_impl.h    ← 从 Dart SDK 拷贝
│
├── headers/
│   └── LingoFuse.h               ← 从 LingoFuse 仓库拷贝（59 个 C ABI 导出）
│
├── lib/
│   ├── lingofuse.dart            公开入口
│   └── src/
│       ├── bindings_generated.dart   ffigen 生成（Legacy FFI）
│       ├── runtime.dart              DLL 加载（双路径：getBindings / getBridge）
│       ├── errors.dart               8 类异常层次
│       ├── data_handle.dart          RAII 数据句柄（+ 4 个 P2P/UID 桥接方法）
│       ├── io.dart                   LfIo：JSON / 字符串 I/O 单一权威
│       ├── framework.dart            进程级门面（+ 32 类型化 option + 3 套寻址快捷方法）
│       ├── app_handle.dart           RAII 应用句柄（+ 3 个 P2P 注册方法）
│       ├── status.dart               状态队列（+ 4 个 UID/P2P 检查）
│       ├── async_support.dart        CallPromise / AsyncBridge
│       ├── address.dart              Target / AppTarget / UIDTarget / P2PNameTarget
│       └── bridge/
│           ├── bridge_error.dart     BridgeErrorCode / BridgeException
│           ├── bridge_ffi.dart       C 桥接的 FFI 声明（100+ 条）
│           └── bridge_host.dart      Dart 侧双协议宿主
│
├── bin/
│   ├── lf_probe.dart             最小加载测试
│   ├── phase1_test.dart          DataHandle 层测试
│   ├── phase2_test.dart          caller 侧测试
│   ├── phase3_test.dart          server 端到端测试
│   ├── phase4_bridge_probe.dart  桥接层探针（21 项）
│   ├── phase5_framework_test.dart Framework 探针（28 项）
│   ├── phase6_async_probe.dart   async API 探针（24 项）
│   ├── phase7_addressing_probe.dart  三套寻址探针（25 项）
│   └── hello_async.dart          async API 教学 demo
│
├── test/
│   ├── data_handle_test.dart     DataHandle 层单元测试
│   ├── io_test.dart              LfIo 层单元测试
│   ├── status_test.dart          状态队列单元测试
│   └── server_test.dart          端到端集成测试
│
├── example/                      完整示例（待补充）
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

**C 桥接还解决了另外两个 Dart FFI 无法处理的问题**：

1. **UID 结构体传值**：LingoFuse 的 `TP2P_UID` 是 32 字节 Pascal 数组，Dart FFI 无法可靠地按值传递。桥接接收 `const uint8_t*` 并在 C 侧重新打包。
2. **临时指针生命周期**：`LF_Get_P2P_UID` 返回框架拥有的指针（~5 秒后自动释放）。桥接立即拷贝 32 字节到调用者缓冲区，从不暴露裸指针。

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

**build.ps1 内部做了什么**（六步）：

1. **验证必需源文件** — 全部存在才继续
2. **定位 `vcvars64.bat`** — 通过 `vswhere` 或已知路径搜索
3. **可选清理** — `-Clean` 时删除 `obj/` 和输出 DLL
4. **调用 `cl.exe`** — 编译 `lf_dart_bridge.c` 和 `dart_api_dl.c`
5. **dumpbin 自检** — 断言导出符号数量 ≥ 80 且关键符号齐全
6. **复制到 `dart/` 根目录** — 便于 Dart 运行时从 CWD 加载

**`cl.exe` 的完整参数**：

```
/nologo                     抑制版权信息
/O2                         优化级别 2（速度）
/LD                         生成 DLL
/MD                         使用多线程 DLL 运行时
/W3                         警告级别 3
/wd4100                     禁用"未使用参数"警告
/I.                         头文件搜索路径：当前目录
/I..\headers                头文件搜索路径：上级 headers 目录（LingoFuse.h）
lf_dart_bridge.c            源文件
dart_api_dl.c               源文件
/Fe:lf_dart_bridge.dll      输出文件名
/Fo:obj/                    对象文件输出目录
```

**预期输出**：

```
==================================================================
  LingoFuse Dart Bridge Build (Windows / MSVC)
==================================================================

  Step 1: verifying required files
  [OK]   all 10 required files present

  Step 2: locating vcvars64.bat
  [OK]   found: C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat

  Step 3: cleaning previous build
         clean skipped (pass -Clean to force a full rebuild)

  Step 4: compiling lf_dart_bridge.dll
  [OK]   built: D:\CoreLibrary\LingoFuse\dart\bridge\lf_dart_bridge.dll (~19000 bytes)

  Step 5: verifying exported symbols (dumpbin)
  [OK]   exported 103 lf_bridge_* symbols (minimum: 80)
  [OK]   all 21 critical exports present

  Step 6: copying to dart/ parent directory
  [OK]   copied to: D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll

==================================================================
  Build complete
==================================================================

  [OK]   DLL  : D:\CoreLibrary\LingoFuse\dart\bridge\lf_dart_bridge.dll
  [OK]   copy : D:\CoreLibrary\LingoFuse\dart\lf_dart_bridge.dll
```

**常见编译错误**：

| 错误 | 原因 | 修复 |
|---|---|---|
| `fatal error C1083: 无法打开包括文件: "dart_api.h"` | `dart_api.h` 未拷贝到 `bridge\` | 重新执行步骤 1 |
| `fatal error C1083: 无法打开包括文件: "internal/dart_api_dl_impl.h"` | `internal\` 子目录未拷贝 | 检查 `bridge\internal\dart_api_dl_impl.h` 存在 |
| `error LNK2019: 无法解析的外部符号 Dart_InitializeApiDL` | `dart_api_dl.c` 未加入编译 | 确认 `bridge\dart_api_dl.c` 存在 |
| `[FAIL] vcvars64.bat not found` | VS2022 未安装 C++ 工作负载 | 打开 VS Installer 添加工作负载 |
| `[FAIL] only N lf_bridge_* symbols exported` | 头文件声明了但 `.c` 未实现 | 检查 `lf_dart_bridge.c` 是否完整 |

### 步骤 4：复制 DLL 到项目根

`build.ps1` 会自动完成这一步。如果手动编译，需复制：

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
| 原子自增 | `InterlockedIncrement` | `__sync_add_and_fetch` |
| TLS | `__declspec(thread)` | `__thread` |
| LingoFuse 库名 | `LingoFuse64.dll` | `liblingofuse.so` / `liblingofuse.dylib` |

### 各平台操作清单

#### Windows（已验证）

| 步骤 | 命令 |
|---|---|
| 1 | 从 `D:\dart-sdk\include\` 拷贝所有 `.h` 到 `bridge\`，包括 `internal\` 子目录 |
| 2 | 从 Dart SDK GitHub 下载 `dart_api_dl.c` 到 `bridge\` |
| 3 | `cd bridge; .\build.ps1` |
| 4 | `build.ps1` 自动复制到 `dart\` |

#### Linux

| 步骤 | 命令 |
|---|---|
| 1 | 安装编译工具链：`sudo apt install build-essential`（Debian/Ubuntu）或 `sudo dnf groupinstall "Development Tools"`（Fedora） |
| 2 | 从 Dart SDK 的 `include/` 目录拷贝所有头文件到 `bridge/`（包括 `internal/` 子目录） |
| 3 | 从 [Dart SDK GitHub](https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/include/dart_api_dl.c) 下载 `dart_api_dl.c` 到 `bridge/` |
| 4 | `cd bridge; chmod +x build.sh; ./build.sh` |
| 5 | `build.sh` 自动复制到 `dart/` |

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
| 5 | `build.sh` 自动复制到 `dart/` |

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

### 跨平台 Dart 侧调整

`lib/src/bridge/bridge_ffi.dart` 中的 `load()` 方法按平台选择正确的文件名：

```dart
static String _selectFileName() {
  if (Platform.isWindows) return 'lf_dart_bridge.dll';
  if (Platform.isMacOS) return 'lf_dart_bridge.dylib';
  return 'lf_dart_bridge.so';
}
```

`BridgeFfi.load()` 的搜索顺序为：

1. 环境变量 `LINGOFUSE_BRIDGE_DLL`（如已设置且非空）
2. `bridge/<bridgeName>`（相对 CWD）
3. `<bridgeName>`（裸文件名，由 OS loader 处理）

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
00:08 +75: All tests passed!
```

### 运行探针

除单元测试外，`bin/` 下还有五个独立探针，每个都是自包含的端到端验证：

```powershell
# 桥接层探针（无框架启动，纯 C 桥接 ABI 验证）
dart run bin\phase4_bridge_probe.dart
# → 21 passed, 0 failed

# Framework 层探针（类型化 option、参数校验、错误路径）
dart run bin\phase5_framework_test.dart
# → 28 passed, 0 failed

# Async API 探针（Promise / Callback / JSON / 超时 / 错误）
dart run bin\phase6_async_probe.dart
# → 24 passed, 0 failed

# 三套寻址探针（AppTarget / UIDTarget / P2PNameTarget）
dart run bin\phase7_addressing_probe.dart
# → 25 passed, 0 failed

# 教学 demo（运行完整的 5 段 async 场景）
dart run bin\hello_async.dart
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

Dart 绑定提供**四个层次**的验证：

**单元测试**（`test/data_handle_test.dart`、`io_test.dart`、`status_test.dart`）：
- 不依赖 LingoFuse 框架启动
- 验证 `DataHandle` 的字节、标量、字符串 I/O
- 验证 `LfIo` 的 JSON 序列化与跨语言字节级一致性
- 验证 `LingoFuseStatus` 的队列操作

**端到端集成测试**（`test/server_test.dart`）：
- 启动完整的 LingoFuse 框架（service + client + C 桥接）
- 注册 Call/Notify API
- 通过子 isolate 发起远程调用
- 验证完整的「准备 → 连接 → App 注册 → 广播 → 路由 → 回调 → 返回」链路

**桥接探针**（`bin/phase4_bridge_probe.dart`）：
- 不启动框架，纯验证 C 桥接的 ABI 正确性
- 验证 `create_data` / `write_buffer` / `read_buffer` / `get_p2p_uid` / `write_uid` / `read_uid` 等
- 验证 P2P 身份在自建句柄上返回零值

**Addressing / Async 探针**（`bin/phase6` / `phase7`）：
- 端到端验证三套寻址 + 现代 async API
- 覆盖 Promise / Callback / JSON / 超时 / 错误路径
- **必须走 `P2PNameTarget`**（原因见[故障排查](#故障排查)中的死锁陷阱）

**注意**：所有端到端测试中的服务端和调用端在**同一进程内**运行，因此 `LF_Call` 走的是 mesh 的本地优先路由路径。它流经完整的原生调用链，但没有跨越 TCP 或跨进程 IPC 跳。

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
| P2PName 负载均衡 | 多个同 P2PName 客户端的分发行为 |
| async 高并发 | `CallPromise` 并发调用下的内存和延迟 |

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
  // Required before any AppHandle.registerCall / registerNotify.
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

### 客户端（Legacy 风格）

创建 `bin/my_client.dart`：

```dart
// Minimal LingoFuse client in Dart (legacy synchronous style).

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

## 快速开始：现代 async API

现代 async API 是 v2.0 的核心新增能力，让业务代码可以**直接写在回调里**，无需 await/async 断裂。完整示例见 `bin/hello_async.dart`。

### 三套寻址 + 四种调用形状

```dart
import 'dart:async';
import 'dart:typed_data';
import 'package:lingofuse/lingofuse.dart';

Future<void> main() async {
  // 1. 启动桥接宿主
  await BridgeHost.start();

  // 2. 声明本进程的 P2P 组名
  //    之后 P2PNameTarget('worker_group') 可以路由到本进程
  Framework.setOptP2PName('worker_group');

  // 3. 创建 App 并注册 API
  final app = AppHandle('MyService', 'async demo');
  app.registerCall('add', 'Add two integers', (Uint8List input) {
    final json = decodeJsonPayload(input) as Map<String, dynamic>;
    final a = (json['a'] as num).toInt();
    final b = (json['b'] as num).toInt();
    return encodeJsonPayload({'sum': a + b});
  });

  // 4. 启动框架
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService('ipc:my_service', 'ipc:my_service');
  Framework.prepareClient('ipc:my_service', app: app);
  Framework.prepareDone();

  // 等待 P2P 名传播到服务端（client -> server -> broadcast，约 2 秒）
  await Future.delayed(const Duration(milliseconds: 2000));

  // ★ 关键：从 Dart 主 isolate 发起 async 调用，必须使用 P2PNameTarget
  //   App 名 / UID 路由是 local-first，会触发同步回调导致死锁。
  //   详见下方"故障排查"章节。
  final target = P2PNameTarget('worker_group');

  // ---- 形状 1：Promise 风格（返回原始字节） ----
  final bytes = await target.call(
    'add',
    payload: {'a': 1, 'b': 2},
    timeoutMs: 5000,
  ).future;
  print('bytes: $bytes');

  // ---- 形状 2：Promise 风格（自动 JSON 解码） ----
  final json = await target.callJson<Map<String, dynamic>>(
    'add',
    payload: {'a': 10, 'b': 20},
    timeoutMs: 5000,
  ).future;
  print('sum: ${json['sum']}');  // → 30

  // ---- 形状 3：Callback 风格（Erlang 风格，业务代码在回调里） ----
  target.callAsync('add', {'a': 3, 'b': 4}, (result, error) {
    if (error != null) {
      print('error: $error');
      return;
    }
    final reply = decodeJsonPayload(result!) as Map<String, dynamic>;
    print('callback sum: ${reply['sum']}');  // → 7
  });

  // ---- 形状 4：阻塞风格（需在子 isolate 中调用） ----
  // 从主 isolate 调用会阻塞 Dart 事件循环，导致桥接回调无法送达。
  // 见 bin/server_test.dart 的 Isolate.run 用法。

  // 清理
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
}

// JSON helper：剥离 LingoFuse 的尾部 NUL 后解码
Object? decodeJsonPayload(Uint8List bytes) {
  final nulIndex = bytes.indexOf(0);
  final payload = nulIndex >= 0 ? bytes.sublist(0, nulIndex) : bytes;
  if (payload.isEmpty) return null;
  return jsonDecode(utf8.decode(payload));
}

// JSON helper：编码为 UTF-8 字节
Uint8List encodeJsonPayload(Object? value) {
  return Uint8List.fromList(utf8.encode(jsonEncode(value)));
}
```

### async 的五种典型场景

`bin/hello_async.dart` 演示了完整五种场景，可直接参考：

| 场景 | 演示内容 |
|---|---|
| **[1] Erlang 风格** | 业务代码直接写在 `callAsync` 回调里，无 await 断裂 |
| **[2] Promise 风格** | `await target.callJson<T>(...).future`，链式清晰 |
| **[3] 嵌套调用** | 第一个回调里发起第二个调用，形成业务逻辑链 |
| **[4] 超时放弃** | 1.5s 超时 vs 3s handler，promise.abandoned=true |
| **[5] 服务端错误** | handler 返回 `{"error": "..."}` 被正确识别 |

### 三套寻址的选择建议

| 场景 | 推荐寻址 |
|---|---|
| 调用固定的业务服务 | `AppTarget` |
| 定向推送到已知 UID 的客户端 | `UIDTarget` |
| 从主 isolate 发起 async 调用 | **`P2PNameTarget`**（避免死锁） |
| 同质 worker 集群负载均衡 | `P2PNameTarget` |
| 需要 FIFO 顺序 | 使用 `sequencedCall` / `sequencedNotify` 变体 |

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

**P2PName 跨语言负载均衡**：

Dart 侧声明组名：
```dart
Framework.setOptP2PName('compute_workers');
```

Python 侧调用组内任一 worker：
```python
from lingofuse import C4
client = C4("", "ipc:compute_grid")
result = client.p2pname("compute_workers").call("compute", {"expr": "..."})
```

---

## API 参考

### `DataHandle`

```dart
// ---- 构造 ----
DataHandle(String apiName)                              // auto-recycled
DataHandle.createPermanent(String apiName)              // permanent
DataHandle.fromRaw(Pointer<Void> raw, {bool owned = false})

// ---- 属性 ----
int get position / set position(int)
int get size / set size(int)
bool get isValid
bool get isOwning
Pointer<Void> get raw

// ---- 字节 I/O ----
int writeBytes(List<int>)
Uint8List readBytes(int)
Uint8List readBytesExact(int)             // throws on short read
Uint8List readAllBytes()
Uint8List readBytesUntilNul()

// ---- 标量 I/O（小端序） ----
void writeInt8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Single/Double(...)
int/double readInt8/UInt8/Int16/UInt16/Int32/UInt32/Int64/UInt64/Single/Double()

// ---- 字符串 I/O（UTF-8，尾部 NUL） ----
void writeString(String)
String readString()

// ---- P2P 身份（仅 input 句柄，需 BridgeHost） ----
Uint8List getP2PUid()                     // 32 字节，自建/输出句柄返回全零
String getP2PName()                       // 自建/输出句柄返回空串

// ---- UID 二进制 I/O（需 BridgeHost） ----
void writeUid(Uint8List uid)              // 必须 32 字节
Uint8List readUid()                       // 读取 32 字节

// ---- 生命周期 ----
void dispose()
```

### `LfIo`

```dart
// ---- JSON 字符串 helper（无句柄） ----
static String dumpsJson(Object? value)    // 紧凑 + 字面 UTF-8
static T loadsJson<T>(String text)

// ---- 字符串 I/O ----
static void writeString(DataHandle, String)
static String readString(DataHandle)

// ---- 字节 I/O ----
static void writeStringBytes(DataHandle, Uint8List)
static Uint8List readStringBytes(DataHandle)
static Uint8List readAllBytes(DataHandle)

// ---- JSON I/O ----
static void writeJson(DataHandle, Object?)
static T readJson<T>(DataHandle)          // 空或无效时抛 LingoFuseIoError
static T? tryReadJson<T>(DataHandle)      // 空或无效时返回 null
```

### `Framework` — 网络准备

```dart
static void resetPrepare()
static int prepareService(String listeningAddr, String physicsAddr)
static int prepareClient(String physicsAddr, {AppHandle? app})
static bool prepareDone()
static void exitMainThread()
static void shutdown()
```

### `Framework` — 类型化运行时选项（v2.0）

所有 `setOpt*` 走 Legacy 路径（可以在框架启动前设置）；所有 `getOpt*` 走 Bridge 路径（需要 `BridgeHost.start()` 已完成）。

```dart
// ---- 认证 ----
static void setOptPassword(String value)
static String getOptPassword()            // 返回掩码 "********"

// ---- 日志与调试 ----
static void setOptDebug(String value)     // 写 C4 控制台命令
static String getOptDebug()
static void setOptQuiet(bool value)
static bool getOptQuiet()
static void setOptShowThreadID(bool value)
static bool getOptShowThreadID()
static void setOptConsoleOutput(bool value)
static bool getOptConsoleOutput()

// ---- 连接就绪 ----
static void setOptOverlapConnection(bool value)
static bool getOptOverlapConnection()
static void setOptWaitConnectionReadyOk(bool value)
static bool getOptWaitConnectionReadyOk()
static void setOptWaitConnectionTimeout(int ms)
static int getOptWaitConnectionTimeout()

// ---- IPC ----
static void setOptIpcServThreadCount(int value)
static int getOptIpcServThreadCount()
static void setOptIpcServMaxQueueLength(int value)
static int getOptIpcServMaxQueueLength()
static void setOptIpcServMaxMsgSize(int value)
static int getOptIpcServMaxMsgSize()

// ---- 序列化通知 ----
static void setOptFixedSequencedTime(int ms)
static int getOptFixedSequencedTime()

// ---- P2P 组名 ----
static void setOptP2PName(String value)
static String getOptP2PName()

// ---- 数据句柄池 ----
static void setOptDataHandleIdleTimeout(int ms)
static int getOptDataHandleIdleTimeout()
static void setOptDataHandlePoolScanInterval(int ms)
static int getOptDataHandlePoolScanInterval()

// ---- 命令刷新 ----
static void setOptNoReponseCmdNullFlushThreshold(int value)
static int getOptNoReponseCmdNullFlushThreshold()
```

**通用逃生通道**：

```dart
static void setOption(String option, String value)   // 走 Legacy
static String getOption(String option)               // 走 Bridge（需启动）
```

### `Framework` — 健康检查与调用

```dart
static bool checkMainThread()
static bool checkApp(String appName)
static bool checkApi(String appName, String apiName)
static String generateAppName()

// ---- App 名寻址（Legacy） ----
static DataHandle call(String appName, DataHandle param, {int timeoutMs = 5000})
static DataHandle? tryCall(String appName, DataHandle param, {int timeoutMs = 5000})
static void notify(String appName, DataHandle param)
static void sequencedNotify(String appName, DataHandle param)

// ---- UID 寻址（Bridge，需 BridgeHost） ----
static DataHandle uidCall(Uint8List uid, DataHandle param, {int timeoutMs = 5000})
static DataHandle? tryUidCall(Uint8List uid, DataHandle param, {int timeoutMs = 5000})
static void uidNotify(Uint8List uid, DataHandle param)
static void uidSequencedNotify(Uint8List uid, DataHandle param)

// ---- P2PName 寻址（Bridge，需 BridgeHost） ----
static DataHandle p2pnameCall(String p2pName, DataHandle param, {int timeoutMs = 5000})
static DataHandle? tryP2pnameCall(String p2pName, DataHandle param, {int timeoutMs = 5000})
static void p2pnameNotify(String p2pName, DataHandle param)
static void p2pnameSequencedNotify(String p2pName, DataHandle param)

// ---- 异步调用（Bridge，需 BridgeHost） ----
static void callAsync(String appName, DataHandle param, AsyncResultHandler onResult)
static void callAsyncSequenced(String appName, DataHandle param, AsyncResultHandler onResult)
static void uidCallAsync(Uint8List uid, DataHandle param, AsyncResultHandler onResult)
static void uidCallAsyncSequenced(Uint8List uid, DataHandle param, AsyncResultHandler onResult)
static void p2pnameCallAsync(String p2pName, DataHandle param, AsyncResultHandler onResult)
static void p2pnameCallAsyncSequenced(String p2pName, DataHandle param, AsyncResultHandler onResult)
```

### `AppHandle`

```dart
AppHandle(String name, String description)

// ---- 应用级注册（App 名寻址可命中） ----
void registerCall(String apiName, String description, CallHandler handler)
void registerNotify(String apiName, String description, NotifyHandler handler)
bool unregister(String apiName)

// ---- 进程级 P2P 注册（仅 UID / P2PName 寻址可命中） ----
void registerP2PCall(String apiName, String description, CallHandler handler)
void registerP2PNotify(String apiName, String description, NotifyHandler handler)
bool unregisterP2P(String apiName)

// ---- 本地执行 ----
DataHandle localCall(DataHandle param)
void localNotify(DataHandle param)

// ---- 客户端绑定 ----
int bind()

// ---- 属性 ----
String get name
bool get isValid
Pointer<Void> get raw

// ---- 生命周期 ----
void dispose()
```

### `BridgeHost`

```dart
// ---- 生命周期 ----
static Future<BridgeHost> start()         // 必须早于任何 registerCall
static BridgeHost get instance            // 未启动时抛 StateError
static BridgeHost? get instanceOrNull     // 用于能力探测
void stop()                               // 幂等

// ---- 属性 ----
bool get isStopped
String get version
String get lastError
String get statsJson

// ---- 网络事件（全局，替换式安装） ----
void setNetworkEvent({NetworkEventHandler? onConnect, NetworkEventHandler? onDisconnect})
void clearNetworkEvent()
bool get isNetworkEventInstalled
```

### `Target` / `AppTarget` / `UIDTarget` / `P2PNameTarget`

```dart
// ---- 三套寻址，共享的调用形状 ----
abstract class Target {
  String get hashKey;                     // 'app:x' / 'uid:hex' / 'p2p:name'
  String describe();                      // 人类可读描述

  // Promise 风格：返回 CallPromise<Uint8List>
  CallPromise<Uint8List> call(String apiName, {Object? payload, int? timeoutMs});

  // Promise 风格（自动 JSON 解码）：返回 CallPromise<T>
  CallPromise<T> callJson<T>(String apiName, {Object? payload, int? timeoutMs});

  // Callback 风格：onResult(result, error) 保证调用一次
  void callAsync(String apiName, Object? payload, void Function(Uint8List?, String?) onResult);

  // 阻塞风格：返回 DataHandle，caller 负责 dispose
  DataHandle callSync(String apiName, {Object? payload, int timeoutMs = 5000});
  DataHandle? tryCallSync(String apiName, {Object? payload, int timeoutMs = 5000});

  // 单向
  void notify(String apiName, {Object? payload});
  void sequencedNotify(String apiName, {Object? payload});
}

// ---- 具体构造 ----
AppTarget(String appName)
UIDTarget(Uint8List uid)                  // 必须 32 字节，否则抛 RangeError
UIDTarget.hex(String hex)                 // 必须 64 字符 hex，否则抛 RangeError
P2PNameTarget(String groupName)
```

### `CallPromise<T>` / `AsyncBridge`

```dart
// ---- CallPromise<T> ----
Future<T> get future                       // 底层 Future
bool get abandoned                         // 是否超时放弃
bool get settled                           // 是否已 resolve/reject

// thenable：可直接 await
Future<R> then<R>(FutureOr<R> Function(T), {Function? onError});
Future<T> catchError(Function, {bool Function(Object)? test});
Future<T> whenComplete(FutureOr<void> Function());

// ---- AsyncBridge（进程级单例） ----
static AsyncBridge instance()
static void shutdownInstance()
Map<String, int> stats()                   // {pending, total_settled, total_abandoned, shutdown}
bool get isShutdown
void shutdown()
```

### `LingoFuseStatus`

```dart
// ---- 状态队列（Legacy） ----
static int getStatusCount()
static String getStatus()
static List<String> drainStatus([int maxMessages = 64])
static void postStatus(String message)

// ---- UID / P2PName 健康检查（Bridge，需 BridgeHost） ----
static bool checkUid(Uint8List uid)              // 必须 32 字节
static bool checkUidApi(Uint8List uid, String apiName)
static bool checkP2PName(String p2pName)
static bool checkP2PNameApi(String p2pName, String apiName)
```

### `BridgeFfi` / `BridgeException` / `BridgeErrorCode`

```dart
// ---- BridgeFfi：C 桥接的 FFI 绑定 ----
static BridgeFfi load()                    // 加载 lf_dart_bridge.dll
static BridgeFfi get instance              // 未加载时抛 StateError
static void resetForTest()                 // 测试用

// ---- BridgeException ----
class BridgeException implements Exception {
  final int code;                          // LFB_ErrorCode 常量
  final String message;
  final String? operation;
}

// ---- BridgeErrorCode 常量 ----
BridgeErrorCode.ok                = 0
BridgeErrorCode.notInitialized    = 1
BridgeErrorCode.libraryNotLoaded  = 2
BridgeErrorCode.nullHandle        = 3
BridgeErrorCode.bufferTooSmall    = 4
BridgeErrorCode.invalidArgument   = 5
BridgeErrorCode.lingofuseFailed   = 6
BridgeErrorCode.bridgeInternal    = 7
BridgeErrorCode.dartPostFailed    = 8
BridgeErrorCode.timeout           = 9  // 保留，当前未使用
```

### 异常层次

所有异常继承自 `LingoFuseError`：

```dart
class LingoFuseError implements Exception
class LingoFuseLibraryLoadError extends LingoFuseError   // DLL 加载失败
class LingoFuseCallError extends LingoFuseError          // 远程调用失败
class LingoFuseTimeoutError extends LingoFuseError       // 超时（保留，async 目前抛 TimeoutException）
class LingoFuseIoError extends LingoFuseError            // 句柄 I/O 失败
class LingoFuseObjectDisposedError extends LingoFuseError // 已 dispose 对象
class LingoFuseCallbackError extends LingoFuseError      // 回调内部异常
class LingoFuseRegistrationError extends LingoFuseError  // P2P 注册失败
```

**注意**：`Target.call(...)` 的超时**当前抛出 Dart 内置的 `TimeoutException`**（来自 `dart:async`），而非 `LingoFuseTimeoutError`。捕获时需注意：

```dart
try {
  await target.call('api', payload: {...}).future;
} on TimeoutException catch (e) {
  // 超时
} catch (e) {
  // 其他错误
}
```

---

## 运行时选项

通过 `Framework.setOption(name, value)` 设置（Legacy 字符串接口），或通过 `Framework.setOpt*`（v2.0 类型化接口）。

| 选项 | 类型 | 默认 | 生效时机 | 说明 |
|---|---|---|---|---|
| `password` / `passwd` | string | `DTC40@ZSERVER` | 立即 | C4 网络认证密码 |
| `Quiet` | bool | `False` | 立即 | 抑制内部日志 |
| `ShowThreadID` | bool | `True` | 立即 | 日志显示线程 ID |
| `ConsoleOutput` | bool | auto | 立即 | 控制台输出开关 |
| `debug` | string | — | 立即 | 执行 C4 控制台命令（写侧） |
| `Overlap_Connection` | bool | `False` | `prepareClient` 前 | 允许同地址多个客户端 |
| `Wait_Connection_ReadyOk` | bool | `True` | `prepareDone` 前 | 是否等待所有客户端就绪 |
| `Wait_Connection_Timeout` | int ms | `30000` | `prepareDone` 前 | 等待超时 |
| `IPC_Serv_ThreadCount` | int | 平台相关 | IPC 服务端启动前 | IPC 服务端线程数 |
| `IPC_Serv_MaxQueueLength` | int | 平台相关 | IPC 服务端启动前 | IPC 消息队列长度 |
| `IPC_Serv_MaxMsgSize` | int | 平台相关 | IPC 服务端启动前 | 单条 IPC 消息最大字节数 |
| `Fixed_Sequenced_Time` | int ms | `20000` | 立即 | 序列化通知的粘性窗口 |
| `LF_P2P_name` | string | `''` | 下次请求 | 本进程声明的 P2P 组名 |
| `DataHandle_Idle_Timeout` | int ms | `600000` | `prepareDone` 后 | 数据句柄空闲回收阈值 |
| `DataHandle_Pool_Scan_Interval` | int ms | `5000` | `prepareDone` 后 | 句柄池扫描间隔 |
| `No_Reponse_Cmd_NULL_Flush_Threshold` | int | `5000` | 立即 | 单向命令的 NULL 刷新阈值 |

**布尔值格式**：`"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` / `"No"`（大小写不敏感）。

**未知选项名会被静默忽略**——拼错不会有任何反馈，请仔细核对。

**选项不跨 `LF_Shutdown` 持久化**——重启框架时需重新设置。

---

## 清理顺序

**必须**按以下顺序清理，否则可能导致崩溃或资源泄漏：

```dart
// 1. 释放 App（解绑 + 停止顺序通知线程）
app.dispose();

// 2. 停止模拟主线程（清空数据句柄池，包括 permanent）
Framework.exitMainThread();

// 3. 释放原生资源（清空应用池、卸载 IPC 库）
Framework.shutdown();

// 4. 关闭 Dart 侧 port 监听
BridgeHost.instance.stop();
```

用 `try/finally` 保证所有退出路径都执行：

```dart
try {
  // ... 业务代码 ...
} finally {
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
}
```

**`BridgeHost.stop()` 与 `Framework.shutdown()` 的关系**：

- `Framework.shutdown()` 释放的是 **LingoFuse 框架**（进程级网络状态、App 池、句柄池）
- `BridgeHost.stop()` 释放的是 **C 桥接层**（`ReceivePort`、pending op 表、native 互斥锁）
- 两者**独立**，都需调用；调用顺序通常桥接最后

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

`AppHandle.registerCall` 之前必须调用 `await BridgeHost.start()`。所有 `LingoFuseStatus.checkUid` / `Framework.uidCall` / `Target.call` 等桥接方法也要求桥接已启动。

### `BridgeHost has been stopped`

`BridgeHost.instance` 在 `stop()` 后不可用。如需重新使用，需再次 `await BridgeHost.start()`。

### 远程调用返回空

- `checkApp` 确认目标应用可见（mesh 广播有约 3 秒延迟）
- 确认 API 名拼写正确（大小写不敏感，但必须完全匹配）
- 增加 `timeoutMs`

### `execute call-mode api "xxx" (stdcall) execpet!`

回调内部异常。常见原因：
- `Dart_InitializeApiDL(NULL)` 被跳过（C 桥接必须从 Dart 传入正确的 `NativeApi.initializeApiDLData`）
- 重新编译 `lf_dart_bridge.dll` 后未重启 Dart 进程

### ⚠️ 从 Dart 主 isolate 调用 `AppTarget` / `UIDTarget` 的 async 方法会死锁

**这是最重要的坑**。

`LF_Async_Call` 在 **local-first 路由** 下，若本进程有同名 App / 相同 UID，会**在调用者线程上同步执行 handler**。Dart 主 isolate 发起 FFI 调用 → Pascal 命中本地 → 同步触发 bridge Protocol A 回调 → native 阻塞等 Dart → 但 Dart 主 isolate 卡在 FFI 调用里无法处理消息 → **双向死锁**。

**修复**：从 Dart 主 isolate 发起 async 调用时，**必须使用 `P2PNameTarget`**：

```dart
// ❌ 会死锁
final target = AppTarget('MyApp');
await target.call('api', payload: {...}).future;

// ✅ 安全（P2PName 不做本地查找，总是走服务端独立线程）
final target = P2PNameTarget('my_group');
await target.call('api', payload: {...}).future;
```

**为什么 P2PName 安全**：P2PName 路由**不查本地**，总是转发到服务端 dispatcher。服务端在**独立原生线程**上执行 handler，不占用 Dart 主 isolate 的 OS 线程。

**替代方案**：在子 isolate 中调用（见 `test/server_test.dart` 的 `Isolate.run` 用法）。

### 测试时卡住不动

- 远程调用（`Framework.call` / `callSync`）**必须在子 isolate 中执行**，否则主 isolate 事件循环会被阻塞，Dart 侧回调无法响应
- 从主 isolate 发起 async 调用时使用 `P2PNameTarget`
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

C 桥接的 `g_state.pending_head` 链表和 `pending_lock` 保证了线程安全，但所有 Call / Notify 回调最终串行执行在 Dart 主 isolate 的事件循环上。Dart server 无法并行处理多个 Call 请求。

**如果需要在 Dart 端做高并发 server**，建议：
- 用多个 Dart 进程
- 或用 `Isolate` 池分摊负载
- 或换用 Rust / C++ / Go 绑定

### 3. Async 调用的 isolate 亲和性

从 Dart 主 isolate 发起 async 调用时，**只能使用 `P2PNameTarget`**。`AppTarget` / `UIDTarget` 的 async 方法在主 isolate 上会死锁（原因见上方）。这是一个**架构级限制**，不是 bug。若必须在主 isolate 用 App 名 / UID 寻址，只能改为同步 `call` 或用子 isolate。

### 4. `LingoFuseTimeoutError` 未使用

`errors.dart` 定义了 `LingoFuseTimeoutError`，但 async API 实际抛出的是 Dart 内置的 `TimeoutException`。捕获时需要区分：

```dart
try { ... } on TimeoutException catch (e) { ... }  // async 超时
try { ... } on LingoFuseError catch (e) { ... }    // 其他 LF 错误
```

未来版本可能统一，当前请注意这一点。

### 5. NetworkEvents 未做 Dart 侧封装

`BridgeHost.setNetworkEvent` 已经实现（底层通道就绪），但没有类似 `NetworkEventListener` 的抽象类封装。用户需直接使用 `BridgeHost.instance.setNetworkEvent(...)`，回调签名是 `void Function(String addr)`。

### 6. Flutter Web 不支持

Dart FFI 在 Flutter Web 上不可用（Web 是 JS 运行时）。

### 7. 32 位 Windows 未测试

理论上 `LingoFuse32.dll` + `dart.exe` (32-bit) 应该能工作，但未验证。

### 8. 大端平台未测试

协议约定小端序，但大端平台（如某些 MIPS / PowerPC 服务器）未做端序适配。

---

## 相关项目

- [LingoFuse 主仓库](https://github.com/PassByYou888/LingoFuse)
- [LingoFuse-Tools（代码生成器）](https://github.com/PassByYou888/LingoFuse-Tools)
- [zIPC（同机 IPC 引擎）](https://github.com/PassByYou888/zIPC)

---

## License

MIT。

---

*Binding version: 0.2.0 (v2.0 特性升级)*
*Target LingoFuse version: v5.x 或更高（含 v3.2 ABI 修订 + LF-ASYNC 家族）*
*Last updated: 2026-10-15*