# LingoFuse 核心动态库构建指南

> 本文档说明如何从源码构建 LingoFuse 核心动态库（`LingoFuse64.dll` / `LingoFuse32.dll` / `liblingofuse.so` / `liblingofuse.dylib`）。
>
> **构建状态**：Windows 构建路径已验证；Linux / macOS 构建路径**未系统验证**——`src/*.pas` 的 include 指令和 `.lpi` 的 `OtherUnitFiles` 使用 Windows 风格反斜杠，FPC 在 Linux / macOS 下不解析这些路径，想在这些平台构建需自行修改。详见 §5。
>
> **本文档范围**：只覆盖 `src/` 目录（核心动态库）的构建。各语言绑定的构建（Python / C# / Rust / Go / Java / …）各自有独立的 README，见各语言目录。

---

## 目录

1. [依赖与子模块](#1-依赖与子模块)
2. [构建环境](#2-构建环境)
3. [Windows 构建（已验证）](#3-windows-构建已验证)
4. [构建产物](#4-构建产物)
5. [Linux / macOS 构建（未验证）](#5-linux--macos-构建未验证)
6. [构建文件说明](#6-构建文件说明)
7. [版本锁定与 PPU 一致性](#7-版本锁定与-ppu-一致性)
8. [常见问题](#8-常见问题)
9. [相关文档](#9-相关文档)

---

## 1. 依赖与子模块

### 1.1 唯一的子模块：`pascal/zNetV2`

LingoFuse 的核心动态库构建**只依赖一个 git 子模块**：

```
pascal/zNetV2
```

`.gitmodules` 里只登记了这一条。`git clone --recursive` 会把它拉下来，不会缺件。

**zNetV2 提供的能力**（这些不是独立子模块，是 zNetV2 内部的源文件）：

- C4 服务网格（`Z.Net.C4.pas`）
- 双隧道（`Z.Net.DoubleTunnelIO*.pas`）
- StableIO（`Z.Net.imp_StableIO.inc`）
- HPC 线程池（`Z.Net.imp_HPC_*.inc`）
- 命令桥（`Z.Net.imp_CommandInstance.inc`）
- 句柄池 / 软同步 / 零拷贝 / 序列化族（`Z.Core.*.inc`、`Z.MemoryStream.pas`、`Z.DFE.pas` 等）
- IPC 引擎（`Z.IPC.API.pas` / `Z.IPC.Helper.pas`；二进制在 `pascal/zNetV2/binary/`）
- 内存分配器绑定（`mimalloc4p.pas` / `jemalloc4p.pas` / `tcmalloc4p.pas`；二进制在 `pascal/zNetV2/binary/`）

**历史说明**：早期文档可能提到 zIPC、mimalloc4p 作为"独立子模块"——**这是过时表述**。它们的能力已包含在 `pascal/zNetV2` 内部，不再需要单独的子模块登记。如果你按旧文档去找 `git submodule update --init zIPC` 之类的命令，会找不到——因为 `.gitmodules` 里没有这些条目。

### 1.2 不需要的东西

构建核心动态库**不需要**：

- C/C++ 编译器（Pascal 编译器自带 C 互操作能力）
- CMake / Ninja / Meson
- Python / Node.js / .NET / JDK
- Docker

只需要 **FPC + Lazarus 工具链**（见 §2）。

---

## 2. 构建环境

### 2.1 必需组件

| 组件 | 版本 | 说明 |
|------|:----:|------|
| **FPC（Free Pascal Compiler）** | **3.3.1** | 版本锁定，见 §7 |
| **Lazarus** | 与 FPC 3.3.1 配套的版本 | 提供 `lazbuild` CLI 和 IDE |
| **操作系统** | Windows 10+ x64 | Linux / macOS 见 §5 |

**不需要**：Visual Studio、MinGW、CMake、Python。

### 2.2 获取 FPC 3.3.1 + Lazarus

FPC 3.3.1 是**开发版**（trunk 分支的稳定快照），不是正式 release。获取方式：

**方式 A：使用仓库提供的环境包（推荐）**

见 [`FPC_3.3.1_Package_Info.md`](FPC_3.3.1_Package_Info.md)——里面记录了 FPC 3.3.1 环境包的具体来源、版本信息和下载指引。

**方式 B：从 Lazarus 官方安装包获取**

Lazarus 的某些发行版自带 FPC 3.3.1。安装后确认：

```bash
fpc -iV
# 期望输出：3.3.1
```

**方式 C：从 FPC 源码构建**

如果以上方式都不可用，可以从 FPC 的 trunk 分支构建 3.3.1。这条路成本较高，不推荐——除非你有明确的理由需要自己构建。

### 2.3 验证环境

```bash
# FPC 版本
fpc -iV
# 期望：3.3.1

# lazbuild 版本
lazbuild --version
# 期望：输出 Lazarus 版本号

# 子模块是否已拉取
ls pascal/zNetV2/source/Z.Net.C4.pas
# 期望：文件存在
```

### 2.4 在 Lazarus IDE 中切换 FPC 版本

如果你已经安装了 Lazarus，但它的 FPC 版本不是 3.3.1，见 [`Lazarus_Change_FPC.md`](Lazarus_Change_FPC.md)——里面说明了如何在 Lazarus 中切换 FPC 版本。

---

## 3. Windows 构建（已验证）

### 3.1 一键构建（推荐）

```powershell
cd src
.\build.bat
```

`build.bat` 会：

1. 检查 FPC / lazbuild 是否可用；
2. 调用 `lazbuild LingoFuse.lpi`；
3. 把产物输出到 `../Binary/`（或按 `.lpi` 配置的输出目录）。

**预期输出**：`Build succeeded` 或类似成功提示，`Binary/` 目录下出现 `LingoFuse64.dll`。

### 3.2 手动构建（lazbuild CLI）

```powershell
cd src
lazbuild LingoFuse.lpi
```

`lazbuild` 读取 `LingoFuse.lpi` 里的编译配置（单元搜索路径、编译选项、输出目录），自动完成构建。

**详细说明**见 [`CONTRIBUTING_lazbuild.md`](CONTRIBUTING_lazbuild.md)——包含 lazbuild 的完整参数、LoongArch64 的手动构建步骤、以及常见 lazbuild 报错的排查。

### 3.3 用 Lazarus IDE 构建

1. 用 Lazarus 打开 `src/LingoFuse.lpi`；
2. 菜单 `Run` → `Build`（或按 `Shift+F9`）；
3. 产物输出到 `.lpi` 配置的目录。

**注意**：Lazarus IDE 使用的 FPC 版本必须与命令行一致（都是 3.3.1），否则会出现 `PPU version mismatch`（见 §7）。

### 3.4 验证构建产物

```powershell
# 确认 DLL 存在
Test-Path ..\Binary\LingoFuse64.dll

# 用 dumpbin（VS 自带）或 objdump 检查导出符号
dumpbin /exports ..\Binary\LingoFuse64.dll | Select-String "LF_"
# 期望：至少 59 个 LF_* 导出符号
```

### 3.5 构建后自测

构建出的 DLL 是否可用，用 `cpp/test/` 里的 C++ 测试程序验证：

```powershell
cd ..\cpp\test
cmake . && make
.\test_lingofuse.exe
```

预期：82 项功能测试全部 PASS。

**如果测试失败**，优先检查：

1. `Binary/` 目录是否包含完整的依赖（`z_ipc_64.dll` / `mimalloc64.dll`）；
2. DLL 是否被正确的路径加载（`LF_LoadLibrary` 的搜索顺序见各语言 README）；
3. 是否是旧版本 DLL 被优先加载（检查 `PATH` 里是否有其他 `LingoFuse64.dll`）。

---

## 4. 构建产物

### 4.1 Windows

| 文件 | 说明 |
|------|------|
| `Binary/LingoFuse64.dll` | 64 位核心动态库 |
| `Binary/LingoFuse32.dll` | 32 位核心动态库（如果构建了 32 位目标） |

**依赖**（必须与 DLL 同目录，或在 `PATH` 上）：

- `z_ipc_64.dll` / `z_ipc_32.dll`（IPC 引擎，来自 `pascal/zNetV2/binary/`）
- `mimalloc64.dll` / `mimalloc32.dll`（内存分配器，可选但推荐）
- `mimalloc-redirect.dll` / `mimalloc-redirect32.dll`（重定向库，可选）

这些依赖在仓库的 `Binary/` 目录里已有预编译副本；构建核心 DLL 时不需要重新编译它们。

### 4.2 Linux / macOS

| 文件 | 说明 |
|------|------|
| `liblingofuse.so` | Linux / BSD 核心动态库 |
| `liblingofuse.dylib` | macOS 核心动态库 |

**当前状态**：Linux / macOS 构建路径**未系统验证**——见 §5。

### 4.3 辅助产物

构建过程中会在 `src/` 下生成：

- `*.o`（目标文件）
- `*.ppu`（编译单元）
- `*.compiled`（Lazarus 编译状态）

这些是中间产物，可以安全删除（`lazbuild` 会重新生成）。

---

## 5. Linux / macOS 构建（未验证）

### 5.1 当前状态

**Linux / macOS 构建路径未系统验证**。原因不是"理论上不可行"，而是：

1. **`src/*.pas` 的 include 指令使用 Windows 风格反斜杠**：
   ```pascal
   {$I ..\pascal\zNetV2\source\Z.Define.inc}
   ```
   FPC 在 Linux / macOS 下不解析反斜杠路径，会报"file not found"。

2. **`LingoFuse.lpi` 的 `OtherUnitFiles` 也使用反斜杠**：
   ```
   ..\pascal\zNetV2\source
   ```
   同样不被 Linux / macOS 的 FPC 解析。

3. **`cross_call.zig` / `async_call.zig` 的 Windows API 依赖**（这条属于 Zig 绑定，不属于核心 DLL，但影响跨平台验证）：`Sleep` / `GetTickCount64` 需要替换为 POSIX 的 `nanosleep` / `clock_gettime`。

4. **仓库里的预编译产物只有 Windows 版本**：`Binary/` 目录只有 `LingoFuse64.dll` / `LingoFuse32.dll`，没有 `.so` / `.dylib`。Release 的 `pre_build` 标签也只有 Windows 产物。

5. **构建脚本以 PowerShell / .bat 为主**：`build.bat` 是 Windows 批处理，Linux / macOS 需要对应的 `.sh`（目前没有）。

**结论**：如果你需要在 Linux / macOS 上构建核心动态库，需要**自行修改源码和构建配置**。下面给出修改指引。

### 5.2 修改指引

**第 1 步：把 include 路径改为正斜杠**

`src/` 下所有 `{$I ..\...}` 改为 `{$I ../...}`。具体涉及哪些文件、哪些行，需要你自己 grep：

```bash
grep -rn '{\$I \.\.\\' src/
```

**第 2 步：把 `.lpi` 的 `OtherUnitFiles` 改为正斜杠**

编辑 `src/LingoFuse.lpi`，把所有 `..\` 改为 `../`。

**第 3 步：改用 FPC 命令行构建**

`lazbuild` 在 Linux 下可用，但 `.lpi` 里的路径需要先修好。或者直接用 `fpc` 命令行：

```bash
cd src
fpc -Fu../pascal/zNetV2/source -Fu../pascal/zNetV2/source/sec \
    -FE../Binary -o../Binary/liblingofuse.so \
    -Mdelphi -Sh -O3 \
    LingoFuse.lpr
```

**注意**：上面这条命令是**示意**，具体的编译选项以 `LingoFuse.lpi` 里配置的为准。你需要对照 `.lpi` 里的 `CustomOptions` / `OtherUnitFiles` / `IncludeFiles` 逐项转换为 `fpc` 命令行参数。

**第 4 步：处理平台条件编译**

`src/` 里的平台条件编译（`{$IFDEF MSWINDOWS}` / `{$IFDEF LINUX}` 等）需要逐一检查。如果某个平台分支缺少实现，需要补齐。

**第 5 步：自测**

构建出 `liblingofuse.so` / `liblingofuse.dylib` 后，用 `cpp/test/` 的 C++ 测试程序验证（需要把 C++ 测试程序也编译成对应平台的版本）。

**第 6 步：反馈**

如果你成功在 Linux / macOS 上构建并跑通了测试，欢迎把修改提 PR 或 Issue——这能帮助后续把这个平台从"未验证"升级为"已验证"。

### 5.3 为什么不做这件事

**不是不能做，是当前优先级不高**。LingoFuse 的主要开发和验证环境是 Windows；Linux / macOS 支持是"理论可行 + 需要用户自行验证"的状态。如果你确实需要在 Linux / macOS 上跑，按 §5.2 的指引改，工作量不大（主要是路径替换）。

---

## 6. 构建文件说明

`src/` 目录下的构建相关文件：

| 文件 | 用途 |
|------|------|
| `build.bat` | Windows 一键构建脚本（调用 `lazbuild`） |
| `LingoFuse.lpi` | Lazarus 项目文件（编译配置、单元搜索路径、输出目录） |
| `LingoFuse.lpr` | 项目主程序文件（`library` 块，定义导出符号） |
| `Z.LingoFuse_Core.pas` | 核心引擎实现（App / Engine / Data / 句柄池 / 顺序线程池） |
| `Z.LingoFuse_Export.pas` | C ABI 导出层（59 个 `LF_*` 函数的实现） |
| `Z.Net.C4.LingoFuse.pas` | C4 分布式层（服务 / 客户端管理、三套寻址、负载均衡） |
| `Z.LingoFuse_System_ProcessID.inc` | 进程 ID 辅助（被 `Z.LingoFuse_Export.pas` 引用） |

**依赖关系**：

```
LingoFuse.lpr
  └── Z.LingoFuse_Export.pas
        ├── Z.LingoFuse_Core.pas
        │     └── Z.Net.C4.LingoFuse.pas
        │           └── pascal/zNetV2/source/Z.Net.C4.pas 等
        └── Z.LingoFuse_System_ProcessID.inc
```

**修改代码时的注意事项**：

- **不要修改 `Z.LingoFuse_Export.pas` 里 59 个导出函数的签名**——这是跨语言 ABI 契约，改了会破坏所有语言绑定。
- **不要修改线格式**（UTF-8 + NUL、小端序、紧凑 JSON 无 `\uXXXX`）——这是跨语言字节级互通的基础。
- **不要修改 Handle 所有权规则**（同步族归调用者、异步族归框架）——这是各语言绑定的共同契约。
- 修改后必须跑 `cpp/test/` 的 C++ 测试验证没有破坏契约。

---

## 7. 版本锁定与 PPU 一致性

### 7.1 为什么锁定 FPC 3.3.1

FPC 的 `.ppu`（编译单元）文件**与编译器版本强绑定**。如果构建机 A 用 FPC 3.3.1 编译了 `Z.Net.C4.pas`，构建机 B 用 FPC 3.3.0 编译 `LingoFuse.lpr`，链接时会报：

```
PPU version mismatch
```

这不是"警告"，是**硬错误**——链接会失败。

### 7.2 锁定规则

- **所有构建机必须使用同一份 FPC 3.3.1 构建源**。不是"版本号相同"，是"构建源相同"——同一个 trunk commit 编译出的 3.3.1，和另一个 trunk commit 编译出的 3.3.1，PPU 可能不兼容。
- 如果你从 [`FPC_3.3.1_Package_Info.md`](FPC_3.3.1_Package_Info.md) 获取环境包，用那个包里的 FPC 即可，它保证了一致性。
- 如果你自己从源码构建 FPC 3.3.1，需要记录你用的 trunk commit，并确保所有构建机用同一个 commit。

### 7.3 遇到 PPU mismatch 怎么办

1. 确认所有构建机的 `fpc -iV` 都输出 `3.3.1`。
2. 确认所有构建机用的是**同一份** FPC 3.3.1 构建源（不是"都是 3.3.1"）。
3. 清理所有 `.ppu` / `.o` / `.compiled`，重新构建：
   ```powershell
   cd src
   del *.ppu, *.o, *.compiled
   lazbuild LingoFuse.lpi
   ```
4. 如果还是失败，检查 `pascal/zNetV2/source/` 下是否有残留的 `.ppu`——这些是之前用不同 FPC 版本编译的，需要一并清理。

### 7.4 切换 FPC 版本

如果你需要在同一台机器上切换 FPC 版本（例如从 3.3.1 切到 3.3.0 做兼容性测试），见 [`Lazarus_Change_FPC.md`](Lazarus_Change_FPC.md)。

**注意**：切换版本后必须**全量清理**再构建，否则会残留旧版本的 `.ppu`，导致 PPU mismatch。

---

## 8. 常见问题

### 8.1 `Can't find unit Z.Core`

**原因**：`LingoFuse.lpi` 的 `OtherUnitFiles` 没包含 `pascal/zNetV2/source`，或者子模块没拉取。

**修复**：

```bash
# 确认子模块已拉取
git submodule update --init --recursive pascal/zNetV2

# 确认源文件存在
ls pascal/zNetV2/source/Z.Core.pas
```

如果文件存在但 `lazbuild` 还是找不到，检查 `LingoFuse.lpi` 里的 `OtherUnitFiles` 是否包含 `..\pascal\zNetV2\source`。

### 8.2 `PPU version mismatch`

见 §7.3。

### 8.3 `Cannot find LingoFuse64.dll`（构建时）

**原因**：构建过程本身不需要 `LingoFuse64.dll`（它是构建产物）。这个错误通常出现在**构建后的测试阶段**——C++ 测试程序找不到刚构建的 DLL。

**修复**：把 `Binary/LingoFuse64.dll` 复制到测试程序同目录，或把 `Binary/` 加入 `PATH`。

### 8.4 `build.bat` 报 "lazbuild not found"

**原因**：`lazbuild` 不在 `PATH` 上。

**修复**：把 Lazarus 的安装目录（包含 `lazbuild.exe` 的目录）加入 `PATH`。通常是：

```
C:\Lazarus\
C:\lazarus\
```

具体路径取决于你的 Lazarus 安装位置。

### 8.5 构建成功但 C++ 测试失败

**排查顺序**：

1. **DLL 是否被正确加载**：检查 `PATH` 里是否有其他 `LingoFuse64.dll` 被优先加载。
2. **依赖 DLL 是否齐全**：`z_ipc_64.dll` / `mimalloc64.dll` 是否与 `LingoFuse64.dll` 同目录。
3. **DLL 的导出符号是否完整**：用 `dumpbin /exports` 检查是否有 59 个 `LF_*`。
4. **是否是旧版本 DLL**：如果你之前构建过，`Binary/` 里可能有旧的 DLL 没被覆盖——删掉重建。

### 8.6 Linux 下 `build.bat` 不能用

**原因**：`build.bat` 是 Windows 批处理脚本。

**修复**：见 §5.2——Linux / macOS 需要自行修改路径并改用 `fpc` 或 `lazbuild` 命令行。

### 8.7 子模块拉取失败

**原因**：网络问题（`pascal/zNetV2` 是独立仓库）。

**修复**：

```bash
# 手动拉取
git submodule update --init --recursive pascal/zNetV2

# 如果还是失败，检查 .gitmodules 里的 URL 是否可访问
cat .gitmodules
```

---

## 9. 相关文档

| 文档 | 内容 |
|------|------|
| [`CONTRIBUTING_lazbuild.md`](CONTRIBUTING_lazbuild.md) | lazbuild CLI 完整参数、LoongArch64 手动构建步骤、lazbuild 报错排查 |
| [`FPC_3.3.1_Package_Info.md`](FPC_3.3.1_Package_Info.md) | FPC 3.3.1 环境包的具体来源、版本信息、下载指引 |
| [`Lazarus_Change_FPC.md`](Lazarus_Change_FPC.md) | 在 Lazarus 中切换 FPC 版本的步骤 |
| [`../README.md`](../readme.md) | 仓库总览：定位、语言支持、快速开始、测试体系 |
| [`../Z.LingoFuse.md`](../Z.LingoFuse.md) | 内部机制知识库（线程模型、回调上下文、Handle 所有权、P2P 身份） |
| [`../cpp/LingoFuse_Cpp_Knowledge_Base.md`](../cpp/LingoFuse_Cpp_Knowledge_Base.md) | C++ 绑定知识库（用于验证构建产物） |
| [`../test/LingoFuse_Functional_Test_Guide.md`](../test/LingoFuse_Functional_Test_Guide.md) | 功能测试指南（82 项） |
| [`../test/LingoFuse_Stress_Test_Guide.md`](../test/LingoFuse_Stress_Test_Guide.md) | 压力测试指南 |

---

## 10. 构建状态与 CI

### 10.1 当前构建状态

| 平台 | 状态 | 说明 |
|------|:----:|------|
| **Windows x64** | ✅ 已验证 | `build.bat` / `lazbuild` 一键构建；产物 `LingoFuse64.dll` 可用 C++ 测试验证 |
| Windows x86 | ⏳ 未验证 | 理论上可行；需要 32 位 FPC 工具链 |
| **Linux x64** | ⏳ 未验证 | 需修改 include 路径和 `.lpi`（见 §5.2） |
| **macOS x64 / arm64** | ⏳ 未验证 | 同 Linux |

### 10.2 CI 状态

**当前仓库根目录没有 GitHub Actions 工作流**。树里唯一的 workflow 是 `erlang/.github/workflows/ci.yml`（只覆盖 Erlang 绑定）。

**构建验证以本地运行为准**：按 §3 的步骤在本地构建，按 §3.5 的自测步骤验证产物。如果你希望构建进入 CI，需要自行添加 workflow——但要注意 FPC 3.3.1 的版本锁定（§7）在 CI 环境里的获取方式需要单独解决。

---

## 许可

与主仓库一致，详见仓库根目录 `LICENSE`。
