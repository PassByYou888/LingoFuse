# Ruby 依赖安装指南

本指南描述 LingoFuse Ruby 绑定所需的运行环境和依赖库，以及在 Windows 上的具体安装步骤。

---

## 一、总览

| 依赖 | 用途 | 安装方式 |
|---|---|---|
| Ruby 4.0+ (x64-mingw-ucrt) | 运行环境 | RubyInstaller 安装包 |
| DevKit（随 RubyInstaller） | 编译 C 扩展 | RubyInstaller 安装包 + `msys64` |
| `minitest`（gem） | 测试框架 | `gem install minitest` |
| `rake`（gem） | 任务运行器 | `gem install rake` |
| `debug`（gem） | 调试器后端 | `gem install debug` |
| 系统 `pthread` | C 扩展线程原语 | DevKit 自带 |
| `LingoFuse64.dll` | 原生 RPC 库 | 从 `Binary/` 目录获取 |

**Fiddle 是 Ruby 标准库的一部分**，不需要单独安装。FFI gem **不是**本绑定的依赖。

---

## 二、Ruby 运行环境

### 2.1 安装 RubyInstaller

从 [RubyInstaller for Windows](https://rubyinstaller.org/downloads/) 下载：

- **Ruby+Devkit 4.0.x (x64)**（不是不带 Devkit 的版本）

安装时勾选：

- ☑ Add Ruby executables to your PATH
- ☑ Associate `.rb` and `.rbw` files with this Ruby installation
- ☑ Install MSYS2 development toolchain

**安装完成后必须重启 PowerShell**，否则 PATH 变更不生效。

### 2.2 验证

打开**新的** PowerShell：

```powershell
ruby -v
```

**期望**：

```
ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [x64-mingw-ucrt]
```

**关键**：`x64-mingw-ucrt` 是正确平台。如果显示 `x64-mswin64` 或 `x86-mingw32`，说明装错了版本。

```powershell
gem -v
```

**期望**：`4.x.x` 或更高。

### 2.3 检查安装路径

```powershell
ruby -e "require 'rbconfig'; puts RbConfig::CONFIG['bindir']"
```

**期望**（大致）：

```
C:/Ruby40-x64/bin
```

记下这个路径，后面配置 VS Code 或调试器时会用到。

---

## 三、DevKit（编译 C 扩展必需）

### 3.1 确认 DevKit 已安装

```powershell
Get-Command make
Get-Command gcc
```

**期望**：

| 命令 | 期望输出 |
|---|---|
| `make` | `C:\Ruby40-x64\msys64\usr\bin\make.exe` |
| `gcc` | `...\mingw64\bin\gcc.exe` 或 `D:\mingw64\bin\gcc.exe` |

### 3.2 检查 make 不是 Embarcadero 版本

```powershell
make --version
```

**期望**：

```
GNU Make 4.4.1
```

**如果显示 Embarcadero / Borland / CodeGear**：

Embarcadero 的 `make.exe` 与 GNU Make 不兼容，会导致 mkmf 生成的 Makefile 编译失败。

**修复方法 1**：把 msys64 的 bin 目录前置到 PATH。

```powershell
$env:PATH = "C:\Ruby40-x64\msys64\usr\bin;" + $env:PATH
```

**修复方法 2**：永久修改 PATH。在 Windows 系统设置里，把 `C:\Ruby40-x64\msys64\usr\bin` 移到 `C:\Program Files (x86)\Embarcadero\Studio\21.0\bin` 的前面。

**修复方法 3**：使用项目自带的 `setup_build_env.ps1` 脚本，它会自动找到正确的 make。

### 3.3 检查 MSYS2 环境

DevKit 通过 MSYS2 提供。检查目录：

```powershell
Test-Path C:\Ruby40-x64\msys64\usr\bin\make.exe
Test-Path C:\Ruby40-x64\msys64\mingw64\bin\gcc.exe
```

两条都应该是 `True`。

如果 `msys64` 不存在，说明安装 RubyInstaller 时没有勾选 DevKit。**重新运行 RubyInstaller 安装包**，选择 "Add or remove components"，勾选 "MSYS2 development toolchain"。

### 3.4 检查头文件

编译 C 扩展需要 Ruby 头文件：

```powershell
ruby -e "require 'rbconfig'; puts RbConfig::CONFIG['rubyhdrdir']"
ruby -e "require 'rbconfig'; puts RbConfig::CONFIG['rubyarchhdrdir']"
```

**期望**：

```
C:/Ruby40-x64/include/ruby-4.0.0
C:/Ruby40-x64/include/ruby-4.0.0/x64-mingw-ucrt
```

确认关键头文件存在：

```powershell
Test-Path C:\Ruby40-x64\include\ruby-4.0.0\ruby\thread.h
```

**期望**：`True`

---

## 四、gem 依赖

### 4.1 minitest

测试框架（Ruby 内置版本通常已足够，但显式安装保证一致性）：

```powershell
gem install minitest
```

**期望**：

```
Successfully installed minitest-5.x.x
1 gem installed
```

**验证**：

```powershell
ruby -e "require 'minitest/autorun'; puts 'minitest OK'"
```

**期望**：`minitest OK`

### 4.2 rake

任务运行器，用来执行 `Rakefile`：

```powershell
gem install rake
```

**验证**：

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
rake -T
```

**期望**：列出所有 `rake test:*` 任务（约 15-20 条）。

### 4.3 debug

Ruby 调试器的后端。用 VS Code 的 rdbg 扩展调试时需要：

```powershell
gem install debug
```

**期望**：

```
Building native extensions. This could take a while...
Successfully installed debug-1.11.1
1 gem installed
```

**注意**：`debug` 需要编译原生扩展，所以**必须先装好 DevKit**。如果这步报错，回到第三节检查 DevKit。

**验证**：

```powershell
ruby -e "require 'debug'; puts 'debug OK'"
```

**期望**：`debug OK`

### 4.4 不需要的 gem

以下 gem **不是**本绑定的依赖，不用装：

| gem | 为什么不需要 |
|---|---|
| `ffi` | 本绑定用标准库 Fiddle，不用 FFI |
| `ffi-compiler` | 同上 |
| `sqlite3` | 无关 |
| `json` | 已内置 Ruby 标准库 |
| `rubocop` | 代码风格工具，可选 |

---

## 五、原生库（LingoFuse64.dll）

### 5.1 需要的文件

放到 `D:\CoreLibrary\LingoFuse\Binary\`：

| 文件 | 用途 |
|---|---|
| `LingoFuse64.dll` | 核心 RPC 库 |
| `z_ipc_64.dll` | IPC 底层 |
| `mimalloc64.dll` | 内存分配器 |
| `mimalloc-redirect.dll` | mimalloc 重定向 |

`LingoFuse64.dll` 加载时**会尝试加载另外三个 DLL**。如果它们不在同一个目录、也不在 PATH 上，加载会失败并报 `The specified module could not be found`。

### 5.2 验证文件存在

```powershell
Get-ChildItem D:\CoreLibrary\LingoFuse\Binary\*.dll | Select-Object Name, Length
```

**期望**：至少列出上述 4 个。

### 5.3 无需设置环境变量（推荐）

`lib/lingofuse/binding.rb` 会自动搜索以下位置（按顺序）：

1. `$LINGOFUSE_LIB_PATH`（环境变量，可选覆盖）
2. 当前工作目录
3. `lib/lingofuse/`（binding.rb 所在目录）
4. `lib/Binary/`
5. `ruby/Binary/`
6. **`<项目根>/Binary/`**（标准仓库布局）

第 6 条命中你的项目布局。所以**正常情况下不需要设任何环境变量**。

若以上所有路径都不命中，最后会以裸文件名交给操作系统加载器，
此时 `PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` 仍可生效。

### 5.4 验证自动发现

**新开一个 PowerShell**（不设任何环境变量）：

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
ruby -I lib -e "require 'lingofuse'; puts LingoFuse.loaded?; puts LingoFuse.library_name"
```

**期望**：

```
true
LingoFuse64.dll
```

### 5.5 显式覆盖（可选）

如果 DLL 放在其他位置，可以设环境变量：

```powershell
$env:LINGOFUSE_LIB_PATH = "D:\OtherLocation\LingoFuse\Binary"
```

**该变量是会话级的**，新开 PowerShell 需要重设。如果长期使用，可以在 Windows 系统设置里加到用户环境变量。

---

## 六、一键环境诊断

项目自带 `check_env.ps1`，检查编译环境：

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
powershell -ExecutionPolicy Bypass -File check_env.ps1
```

会依次检查 8 项：

1. PowerShell 版本与操作系统
2. Ruby 版本、平台、`RbConfig`
3. **GNU Make 与 gcc**（判断是不是 Embarcadero Make）
4. `mkmf` 可用性 + 实际编译一个 C 程序
5. `pthread` 编译链接 + `ruby/thread.h` 存在
6. `LINGOFUSE_LIB_PATH` 与 DLL 文件（**可选**，缺失不阻塞构建）
7. 扩展源码树完整性
8. **汇总报告**（`Passed` / `Warned` / `Failed`）

**期望**：`Failed : 0`。

`check_env.rb` 是另一个独立的诊断脚本，检查**运行时**环境：

```powershell
ruby check_env.rb
```

**期望尾部**：

```
  Passed : 23
  Failed : 0

  All checks passed. The environment is ready.
```

两个脚本用途不同：

| 脚本 | 检查对象 | 何时运行 |
|---|---|---|
| `check_env.ps1` | 编译 C 扩展的工具链 | 首次搭建环境、编译失败时 |
| `check_env.rb` | Ruby 绑定运行时 | 首次使用、加载失败时 |

---

## 七、完整验证清单

按顺序执行以下命令，每步都通过再进行下一步：

### 第 1 步：Ruby 环境

```powershell
ruby -v
gem -v
```

### 第 2 步：DevKit 工具链

```powershell
make --version
gcc --version
```

**关键**：`make --version` 必须显示 `GNU Make`。

### 第 3 步：gem 依赖

```powershell
gem list minitest rake debug
```

**期望**：列出这三个 gem 及版本号。

### 第 4 步：原生库

```powershell
Get-ChildItem D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll
```

**期望**：返回文件信息。

### 第 5 步：绑定加载

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
ruby -I lib -e "require 'lingofuse'; puts LingoFuse.loaded?"
```

**期望**：`true`

### 第 6 步：C 扩展加载

```powershell
ruby -I lib -e "require 'lingofuse_ext'; puts LingoFuse::NativeBridge.respond_to?(:create_ref)"
```

**期望**：`true`

### 第 7 步：跑一个测试

```powershell
ruby test/test_errors.rb
```

**期望**：

```
23 runs, 39 assertions, 0 failures, 0 errors, 0 skips
```

### 第 8 步：跑全部测试

```powershell
powershell -ExecutionPolicy Bypass -File run_test_ci.ps1
```

**期望尾部**：

```
========================================================================
All 13 test files passed.
========================================================================
```

---

## 八、VS Code 配置（可选）

如果要在 VS Code 里调试 Ruby：

### 8.1 安装扩展

Extensions 面板搜索并安装：

| 扩展 | 作者 | 用途 |
|---|---|---|
| **VSCode rdbg Ruby Debugger** | Koichi Sasada | 断点调试（必需） |
| Ruby LSP | Shopify | 语法提示（可选） |

**不要装**：`Ruby`（旧版，已弃用）、`ruby-debug-ide`（过时）。

### 8.2 用户设置

按 `Ctrl + Shift + P` → `Preferences: Open User Settings (JSON)`，加入：

```json
{
  "rdbg.ruby": "C:\\Ruby40-x64\\bin\\ruby.exe",
  "rdbg.useBundler": false
}
```

路径要根据 `RbConfig::CONFIG['bindir']` 的实际输出调整。

### 8.3 项目设置

创建 `D:\CoreLibrary\LingoFuse\ruby\.vscode\launch.json`：

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "rdbg",
      "name": "Debug current file",
      "request": "launch",
      "script": "${file}",
      "args": [],
      "useBundler": false
    },
    {
      "type": "rdbg",
      "name": "Debug cross_service.rb",
      "request": "launch",
      "script": "${workspaceFolder}/cross/cross_service.rb",
      "args": [],
      "useBundler": false
    },
    {
      "type": "rdbg",
      "name": "Debug cross_node.rb",
      "request": "launch",
      "script": "${workspaceFolder}/cross/cross_node.rb",
      "args": [],
      "useBundler": false
    },
    {
      "type": "rdbg",
      "name": "Debug cross_call.rb",
      "request": "launch",
      "script": "${workspaceFolder}/cross/cross_call.rb",
      "args": [],
      "useBundler": false
    }
  ]
}
```

### 8.4 断点调试

1. 打开目标 `.rb` 文件
2. 点击行号左侧空白处，出现红点（断点）
3. 按 `F5`，从下拉选择调试配置
4. 程序停到断点处，左侧 "Variables" 面板显示当前作用域

**多进程注意**：`Cross Demo` 是三个独立进程，VSCode 一次只能调试一个。典型做法是：

- VSCode 调试 `cross_service.rb`
- PowerShell 独立窗口跑 `ruby cross/cross_node.rb` 和 `ruby cross/cross_call.rb`

---

## 九、故障排查速查表

| 症状 | 原因 | 修复 |
|---|---|---|
| `ruby: command not found` | PATH 未生效 | 重启 PowerShell 或重装 RubyInstaller |
| `cannot load such file -- lingofuse` | load path 不对 | 用 `require_relative` 或 `-I lib` |
| `Failed to load the LingoFuse native library` | DLL 找不到或依赖缺失 | 检查 `Binary/` 目录，或设 `LINGOFUSE_LIB_PATH` |
| `[BUG] rb_thread_call_with_gvl()` | C 扩展未编译 | 运行 `setup_build_env.ps1` |
| `Fatal makefile ... No terminator` | 用了 Embarcadero Make | 用 msys64 的 GNU Make |
| `gettimeofday: conflicting types` | 头文件冲突 | 更新 `lingofuse_ext.c`（去掉 `<sys/time.h>`） |
| `undefined reference to 'clock_gettime'` | MinGW 缺少 pthread | 重装 DevKit |
| `gem install debug` 失败 | DevKit 未装 | 先装 DevKit 再装 debug |
| `cannot load such file -- debug` | gem 未安装 | `gem install debug` |
| `Workspace not activated` (VS Code) | 工作区 URI 异常 | 用 `code .` 而不是 `code <path>` 打开 |
| `Cannot find any Ruby installations` (Ruby LSP) | 扩展检测失败 | 卸载 Ruby LSP，或用 rdbg 替代 |

---

## 十、文件清单

完成后，项目应该包含以下与依赖相关的文件：

```
ruby/
├── Gemfile                          声明开发依赖
├── lingofuse.gemspec                gem 元数据（不含 runtime 依赖）
├── Rakefile                         rake 任务
├── check_env.ps1                    编译环境诊断（PowerShell）
├── check_env.rb                     运行时环境诊断（Ruby）
├── setup_build_env.ps1              一键编译 C 扩展
├── run_test_ci.ps1                  Windows CI 测试运行器
├── run_test_ci.sh                   Linux/macOS CI 测试运行器
├── BUILD_EXTENSION.md               本目录下的编译指南
├── INSTALL_DEPENDENCIES.md          本文件
├── lib/
│   ├── lingofuse_ext.so             C 扩展（编译产物）
│   └── lingofuse/                   绑定源码
├── ext/lingofuse_ext/               C 扩展源码
└── test/                            测试套件（13 个文件）
```
