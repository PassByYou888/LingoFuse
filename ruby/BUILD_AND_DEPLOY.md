# LingoFuse Ruby 绑定 — 构建与部署指南（第一步）

> **定位**：本文档描述 **用自写 C 扩展替代 Fiddle** 的构建、部署与验证流程。
> 完成后，Ruby 侧**完全不再使用 Fiddle**加载 LingoFuse DLL；所有对
> `LingoFuse64.dll` 的访问都通过自写的 `lingofuse_ext.so` 完成。
>
> **适用范围**：Windows 10 / 11 / Server 2019+（x64）
> **Ruby 版本**：4.0+（x64-mingw-ucrt）
> **文档版本**：v1.0
> **对应绑定版本**：1.0.0（第一步完成态）

---

## 目录

1. [目标与范围](#一目标与范围)
2. [环境要求](#二环境要求)
3. [目录结构](#三目录结构)
4. [编译 C 扩展](#四编译-c-扩展)
5. [部署原生 DLL](#五部署原生-dll)
6. [部署 C 扩展](#六部署-c-扩展)
7. [加载验证](#七加载验证)
8. [Ruby 层切换](#八ruby-层切换)
9. [常见问题排查](#九常见问题排查)
10. [验收清单](#十验收清单)

---

## 一、目标与范围

### 1.1 背景

原始 Ruby 绑定使用 Ruby 标准库 `Fiddle` 从 `LingoFuse64.dll` 直接加载 37 个
`LF_*` 函数。这种双机制方案（Fiddle + 自写 C 扩展）存在以下问题：

| 问题 | 影响 |
|------|------|
| 加载路径无法控制 | `Fiddle.dlopen` 只搜索系统 PATH，无法显式注册 DLL 目录 |
| 类型安全在运行期 | 参数类型错误在调用时才暴露，无法编译期检查 |
| 错误信息粗糙 | 加载失败时只报 `No such file or directory`，不指明缺失符号 |
| 双份 ABI 声明 | `binding.rb` 与 C 扩展各自维护符号清单，容易漂移 |
| 回调路径分离 | 回调走 C 扩展，同步调用走 Fiddle，两套线程模型并存 |

### 1.2 第一步目标

**用自写的 `lingofuse_ext.so` 完全替代 Fiddle 层**：

- C 扩展内部嵌入 `LingoFuse.c`（上游 C 加载器 + 59 个函数 forwarder）
- C 扩展暴露 59 个 `rb_lf_*` Ruby 方法 + 加载器（`load_library` / `free_library` / `loaded?`）
- 现有回调编组机制**完整保留**（原生队列 + Ruby 调度线程）
- Ruby 侧完全删除 Fiddle 路径

### 1.3 完成后的架构

```
L0  应用代码
     │
L1  lib/lingofuse.rb                    入口
     │
L2  Framework / Status / NetworkEvents   门面
     │
L3  DataHandle / AppHandle / LfIo        RAII + I/O
     │
L4  NativeBridge (回调编组)               C 扩展的回调注册路径
     │
L5  lingofuse_ext.so                     自写 C 扩展
     ├── LingoFuse.c                     加载器 + 59 forwarders
     └── lingofuse_ext.c                 Ruby C API (rb_lf_*)
     │
L6  LingoFuse64.dll                      原生库
     + z_ipc_64.dll
     + mimalloc64.dll
     + mimalloc-redirect.dll
```

**关键变化**：`L5` 现在是**唯一**的原生入口。`L2` 到 `L4` 都不再接触 Fiddle。

---

## 二、环境要求

### 2.1 软件清单

| 组件 | 最低版本 | 推荐版本 | 备注 |
|------|:--------:|:--------:|------|
| Windows | 10 (1809+) | Server 2022 / 11 | — |
| Ruby | 4.0.0 | **4.0.7** | 必须 **x64-mingw-ucrt** |
| DevKit | 随 RubyInstaller | — | 必须安装 |
| GNU Make | 4.4+ | 4.4.1 | **非 Embarcadero** |
| GCC | MinGW-w64 | 16.x | 见 §2.4 说明 |
| PowerShell | 5.0 | 7.x | — |

### 2.2 已确认的参考环境

本文档基于以下**已实测**环境：

```
PowerShell : 7.6.6
OS         : Windows Server 2022 Datacenter
Arch       : AMD64
Ruby       : ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [x64-mingw-ucrt]
Ruby bindir: C:/Ruby40-x64/bin
Make       : C:\Ruby40-x64\msys64\usr\bin\make.exe (GNU Make 4.4.1)
GCC        : D:\mingw64\bin\gcc.exe (16.1.0, MinGW-Builds 项目)
```

### 2.3 验证环境

运行 `check_env.ps1`：

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
.\check_env.ps1
```

**期望**：

```
  Passed : 14
  Warned : 0~2
  Failed : 0
```

**关键检查项**：

| Section | 检查 | 必须通过 |
|:-------:|------|:--------:|
| 2 | Ruby 版本含 `x64-mingw-ucrt` | ✅ |
| 3 | GNU Make 已检测 | ✅ |
| 3 | gcc 已检测 | ✅ |
| 4 | mkmf 可用 + gcc 能编译 C 程序 | ✅ |
| 5 | `pthread.h` + `ruby/thread.h` 存在 | ✅ |
| 7 | `ext/lingofuse_ext/extconf.rb` 存在 | ✅ |

### 2.4 关于 gcc 的说明

**首选**：Ruby DevKit 自带的 gcc

```
C:\Ruby40-x64\msys64\mingw64\bin\gcc.exe
```

**当前环境实际使用**：外部 MinGW-Builds 的 gcc

```
D:\mingw64\bin\gcc.exe
```

两者都是 x86_64、seh 异常模型。**编译 `lingofuse_ext.so` 均可成功**，但有细微差别：

| 差异 | DevKit gcc | 外部 MinGW-Builds gcc |
|------|:----------:|:---------------------:|
| CRT | UCRT（与 Ruby 一致） | msvcrt |
| `have_library` 探测 | 通过 | **可能失败**（见 §2.5） |
| 头文件搜索路径 | 与 Ruby 一致 | 独立 |

### 2.5 关于 `have_library` 的陷阱

如果 `extconf.rb` 里的 `have_library('pthread')` 失败，报：

```
The compiler failed to generate an executable file. (RuntimeError)
You have to install development tools first.
```

这是 **CRT 不匹配** 导致的：mkmf 用 Ruby 的 UCRT CFLAGS 编译探测程序，但外部 gcc 链接 msvcrt 库，链接失败。

**修复**：`extconf.rb` 的当前版本**已经跳过 `have_library` 探测**，改为：

- 仅检查头文件（`have_header`，不涉及链接）
- 显式追加 `$libs << ' -lpthread'` 和 `$libs << ' -lkernel32'`

这样即使 gcc 是外部版本也能编译成功。

---

## 三、目录结构

### 3.1 编译前

```
D:\CoreLibrary\LingoFuse\ruby\
├── BUILD_AND_DEPLOY.md                本文档
├── BUILD_EXTENSION.md                 旧版编译指南（Fiddle 时代）
├── INSTALL_DEPENDENCIES.md            依赖安装指南
├── README.md                          主手册
├── check_env.ps1                      编译环境诊断
├── check_env.rb                       运行时诊断
├── setup_build_env.ps1                一键编译脚本
├── clean.ps1                          清理脚本
├── run_tests.ps1 / run_test_ci.ps1    测试脚本
│
├── ext/
│   └── lingofuse_ext/
│       ├── extconf.rb                 mkmf 配置
│       ├── LingoFuse.c                上游 C 加载器（人类提供）
│       ├── LingoFuse.h                上游 C ABI 头（人类提供）
│       └── lingofuse_ext.c            Ruby C API 表面
│
├── lib/
│   ├── lingofuse.rb
│   └── lingofuse/
│       ├── binding.rb                 LF_* 常量包装
│       ├── native_bridge.rb           回调注册路径
│       ├── data_handle.rb             RAII 数据句柄
│       ├── app_handle.rb              RAII 应用句柄
│       ├── framework.rb               进程级门面
│       ├── status.rb                  状态队列
│       ├── network_events.rb          网络事件
│       ├── lf_io.rb                   统一 I/O
│       ├── errors.rb                  异常层级
│       └── callback_error_reporter.rb 回调异常上报
│
└── test/                              14 个测试文件
```

### 3.2 编译后新增

```
ruby/
├── lib/
│   ├── lingofuse_ext.so               ★ 编译产物（拷贝过来的）
│   └── ...
│
└── ext/lingofuse_ext/
    ├── LingoFuse.o                    ★ 中间产物
    ├── lingofuse_ext.o                ★ 中间产物
    ├── lingofuse_ext.so               ★ 编译产物
    ├── lingofuse_ext-x64-mingw-ucrt.def ★ mkmf 生成
    ├── Makefile                       ★ mkmf 生成
    └── mkmf.log                       ★ mkmf 日志
```

### 3.3 运行时依赖（不在项目内）

```
C:\Ruby40-x64\bin\                     ★ exe 所在目录（LF_LoadLibrary 第一搜索点）
├── ruby.exe
├── LingoFuse64.dll                    ★ 核心 RPC 库
├── z_ipc_64.dll                       ★ IPC 底层
├── mimalloc64.dll                     ★ 内存分配器
└── mimalloc-redirect.dll              ★ mimalloc 重定向
```

**这四个 DLL 必须放在 `ruby.exe` 同目录**。原因见 §5.1。

---

## 四、编译 C 扩展

### 4.1 一键编译（推荐）

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
powershell -ExecutionPolicy Bypass -File setup_build_env.ps1
```

### 4.2 手动编译

```powershell
cd D:\CoreLibrary\LingoFuse\ruby\ext\lingofuse_ext

# 1. 清理旧产物
Remove-Item Makefile,*.o,*.so,*.def,mkmf.log -ErrorAction SilentlyContinue

# 2. 生成 Makefile
ruby extconf.rb

# 3. 编译
make
```

### 4.3 期望输出

```
[extconf] Ruby arch : x64-mingw-ucrt
[extconf] RbConfig CC: gcc
checking for pthread.h... yes
checking for ruby/thread.h... yes
creating Makefile
generating lingofuse_ext-x64-mingw-ucrt.def
compiling LingoFuse.c
compiling lingofuse_ext.c
linking shared-object lingofuse_ext.so
```

**期望**：

- 三行关键信息：`compiling LingoFuse.c` / `compiling lingofuse_ext.c` / `linking shared-object lingofuse_ext.so`
- **没有 error**
- **没有 warning**（`-Wno-cast-function-type` 抑制了 `GetProcAddress` 的伪告警）

### 4.4 编译产物

```powershell
Get-ChildItem D:\CoreLibrary\LingoFuse\ruby\ext\lingofuse_ext\*.so | Format-Table Name, Length
```

**期望**：

```
Name                Length
----                ------
lingofuse_ext.so    98304     （大小可能略有差异）
```

### 4.5 编译失败排查

| 症状 | 原因 | 修复 |
|------|------|------|
| `checking for -lpthread...` 失败 | CRT 不匹配 | 用当前 `extconf.rb`（已跳过 `have_library`） |
| `Fatal makefile ... No terminator` | 用了 Embarcadero Make | 把 msys64 的 bin 前置到 PATH（见下） |
| `permission denied: conftest.exe` | 残留进程锁定文件 | `Stop-Process ruby,conftest -Force` |
| `Pascal-style error` 或找不到符号 | 加载了错误的 DLL | 确认 `LingoFuse64.dll` 版本正确 |

**Embarcadero Make 遮蔽问题**（曾遇到）：

```powershell
# 检查当前 make
make --version
# 如果是 "MAKE Version 5.43 ... Embarcadero"，需要前置修复

# 临时修复（仅当前会话）
$env:PATH = "C:\Ruby40-x64\msys64\usr\bin;" + $env:PATH
make --version
# 应输出 "GNU Make 4.4.1"
```

---

## 五、部署原生 DLL

### 5.1 为什么必须放在 `ruby.exe` 同目录

`LF_LoadLibrary` 的搜索逻辑（见 `LingoFuse.c`）：

```c
// 第一步：从 exe 所在目录加载
GetModuleFileNameA(NULL, full_path, ...)   // → "C:\Ruby40-x64\bin\ruby.exe"
                                            // → exe_dir = "C:\Ruby40-x64\bin\"
LoadLibraryA(exe_dir + "\\LingoFuse64.dll")

// 第二步：如果第一步失败，用 bare name
LoadLibraryA("LingoFuse64.dll")            // 依赖 PATH 搜索
```

**第一步几乎总能成功**，因为：

1. **exe 目录始终被 Windows 加载器搜索**，不受 `SetDefaultDllDirectories` 影响
2. **依赖 DLL（`z_ipc_64.dll` 等）也在同目录**，Windows 加载器默认搜索已加载 DLL 的所在目录（当路径以显式路径给出时）

**第二步会失败**，因为 Ruby 启动时调用了 `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)`，导致本进程内 `LoadLibrary` 不再搜索 PATH。

### 5.2 拷贝命令

```powershell
# 从权威目录拷贝到 ruby.exe 所在目录
Copy-Item D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll       C:\Ruby40-x64\bin\ -Force
Copy-Item D:\CoreLibrary\LingoFuse\Binary\z_ipc_64.dll          C:\Ruby40-x64\bin\ -Force
Copy-Item D:\CoreLibrary\LingoFuse\Binary\mimalloc64.dll        C:\Ruby40-x64\bin\ -Force
Copy-Item D:\CoreLibrary\LingoFuse\Binary\mimalloc-redirect.dll C:\Ruby40-x64\bin\ -Force
```

### 5.3 验证

```powershell
Get-ChildItem C:\Ruby40-x64\bin\LingoFuse64.dll, `
              C:\Ruby40-x64\bin\z_ipc_64.dll, `
              C:\Ruby40-x64\bin\mimalloc64.dll, `
              C:\Ruby40-x64\bin\mimalloc-redirect.dll |
    Format-Table Name, Length
```

**期望**：4 个文件都存在，`LingoFuse64.dll` 约 2.9 MB。

### 5.4 常见错误

| 错误 | 原因 | 修复 |
|------|------|------|
| `Failed to load LingoFuse64.dll` | DLL 不在 exe 目录 | 按 §5.2 拷贝 |
| `The specified module could not be found` | 三个兄弟 DLL 缺失 | 4 个必须同目录 |
| `[WinError 126]` | mimalloc 相关 DLL 缺失 | 确认 `mimalloc-redirect.dll` 存在 |

**注意**：不要把 DLL 拷到项目根目录（`D:\CoreLibrary\LingoFuse\ruby\`）——虽然在某些场景（依赖 CWD）下碰巧可用，但**不可靠**。始终放在 `C:\Ruby40-x64\bin\`。

---

## 六、部署 C 扩展

### 6.1 拷贝 `.so` 到 `lib/`

`native_bridge.rb` 和 `binding.rb` 通过 `require_relative '../lingofuse_ext'` 加载扩展，**固定位置为 `lib/lingofuse_ext.so`**。

```powershell
Copy-Item D:\CoreLibrary\LingoFuse\ruby\ext\lingofuse_ext\lingofuse_ext.so `
          D:\CoreLibrary\LingoFuse\ruby\lib\lingofuse_ext.so `
          -Force
```

### 6.2 验证位置

```powershell
Test-Path D:\CoreLibrary\LingoFuse\ruby\lib\lingofuse_ext.so
# 期望：True
```

### 6.3 为什么这个位置是固定的

```ruby
# lib/lingofuse/native_bridge.rb
require_relative '../lingofuse_ext'
#              ^^^ 相对 native_bridge.rb 自身
#              → lib/lingofuse/../lingofuse_ext
#              → lib/lingofuse_ext.so
```

**不受 `$LOAD_PATH`、PATH、CWD 影响**。移动整个 `ruby/` 目录时，只要 `lib/` 与 `lingofuse/` 相对结构不变，`.so` 就能被找到。

---

## 七、加载验证

### 7.1 冒烟测试

```powershell
cd D:\CoreLibrary\LingoFuse\ruby\ext\lingofuse_ext

@'
require "lingofuse_ext"
puts "Native.load_library -> #{LingoFuse::Native.load_library}"
puts "Native.loaded?      -> #{LingoFuse::Native.loaded?}"
hnd = LingoFuse::Native.lf_create_data("smoke_test")
puts "lf_create_data      -> #{hnd.inspect}"
puts "lf_get_size         -> #{LingoFuse::Native.lf_get_size(hnd)}"
LingoFuse::Native.lf_free_data(hnd)
puts "lf_free_data        -> ok"
LingoFuse::Native.lf_set_option("Quiet", "False")
puts "lf_get_option(Quiet)-> #{LingoFuse::Native.lf_get_option('Quiet').inspect}"
'@ | Set-Content -Path .\_smoke.rb -Encoding UTF8
ruby -I . _smoke.rb
Remove-Item .\_smoke.rb -ErrorAction SilentlyContinue
```

**期望输出**（关键行）：

```
Native.load_library -> 1
Native.loaded?      -> true
lf_create_data      -> 2514705581520       （非零 Integer）
lf_get_size         -> 0
lf_free_data        -> ok
lf_get_option(Quiet)-> "False"
```

**伴随的 `[LF-DEBUG]` 日志**（如 `TLF_App.Create` / `Init_P2P_APP done`）是 LingoFuse 内部初始化输出，**属于正常**。

### 7.2 完整冒烟测试

```powershell
cd D:\CoreLibrary\LingoFuse\ruby

@'
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "lingofuse"

puts "loaded?             -> #{LingoFuse.loaded?}"
puts "library_name        -> #{LingoFuse.library_name}"

h = LingoFuse::DataHandle.new("smoke")
h.write_string("hello, 世界")
h.position = 0
puts "read_string         -> #{h.read_string.inspect}"
h.dispose

app = LingoFuse::AppHandle.new("SmokeApp", "smoke")
app.register_call("echo", "echo") { |i, o| o.write_string(i.read_string) }
req = LingoFuse::DataHandle.new("echo")
req.write_string("round-trip")
res = app.local_call(req)
puts "local_call result   -> #{res.read_string.inspect}"
req.dispose; res.dispose; app.dispose
'@ | Set-Content -Path .\_verify.rb -Encoding UTF8
ruby _verify.rb
Remove-Item .\_verify.rb -ErrorAction SilentlyContinue
```

**期望输出**：

```
loaded?             -> true
library_name        -> LingoFuse64.dll
read_string         -> "hello, 世界"
local_call result   -> "round-trip"
```

---

## 八、Ruby 层切换

### 8.1 已切换的文件

| 文件 | 变更 |
|------|------|
| `lib/lingofuse/binding.rb` | **重写**：删除 Fiddle 声明，改为 `require_relative '../lingofuse_ext'` + `LF_*` 常量包装 |
| `lib/lingofuse/native_bridge.rb` | **重写**：删除 Fiddle fallback，只走 C 扩展 |
| `lib/lingofuse/data_handle.rb` | **重写**：`@handle` 从 `Fiddle::Pointer` 改为 `Integer` |
| `lib/lingofuse/app_handle.rb` | **重写**：同上；`register_*` 直接调 `NativeBridge` |
| `lib/lingofuse/framework.rb` | **重写**：所有调用走 `LF_*` 常量 |
| `lib/lingofuse/status.rb` | **重写**：同上 |
| `lib/lingofuse/network_events.rb` | **重写**：删除 Fiddle fallback |

### 8.2 未改动的文件

| 文件 | 原因 |
|------|------|
| `lib/lingofuse/lf_io.rb` | 只依赖 `DataHandle` 的高层方法，不感知底层 |
| `lib/lingofuse/errors.rb` | 纯 Ruby 异常层级 |
| `lib/lingofuse/callback_error_reporter.rb` | 纯 Ruby 回调上报 |
| `lib/lingofuse.rb` | 入口文件，require 顺序不变 |

### 8.3 关键 API 兼容性

现有代码中以下调用**保持不变**：

```ruby
# 数据句柄
h = LingoFuse::DataHandle.new("api")
h.write_string("hello")
h.read_int32

# 应用句柄
app = LingoFuse::AppHandle.new("App", "desc")
app.register_call("api", "desc") { |i, o| ... }
app.local_call(req)

# 进程级
LingoFuse::Framework.call("App", req, 3000)
LingoFuse::Framework.set_option("Quiet", "False")
LingoFuse::Status.check_app("App")
```

**唯一的行为变化**：`DataHandle#raw` / `AppHandle#raw` 的返回类型从 `Fiddle::Pointer` 改为 `Integer`（地址值）。**普通用户代码不应直接使用 `.raw`**；如果必须用，直接把这个 `Integer` 传给 `Native.lf_*` 即可。

---

## 九、常见问题排查

### 9.1 编译阶段

| 症状 | 诊断 | 修复 |
|------|------|------|
| `checking for -lpthread...` 失败 | CRT 不匹配 | 用当前版 `extconf.rb`（跳过 `have_library`） |
| `No GNU Make found` | Embarcadero 遮蔽 | 前置 `C:\Ruby40-x64\msys64\usr\bin` 到 PATH |
| `conftest.exe: Permission denied` | 残留进程锁定 | `Get-Process ruby,conftest \| Stop-Process -Force` |
| `Fatal makefile ... No terminator` | 用错 Make | 同上 |
| `LingoFuse.c: cast between incompatible function types` | 无害警告 | 忽略，或用 `-Wno-cast-function-type` |

### 9.2 部署阶段

| 症状 | 诊断 | 修复 |
|------|------|------|
| `Failed to load LingoFuse64.dll` | DLL 不在 exe 目录 | §5.2 拷贝 |
| `[WinError 126]` | 兄弟 DLL 缺失 | 4 个必须同目录 |
| `cannot load such file -- lingofuse_ext` | `.so` 不在 `lib/` | §6.1 拷贝 |
| `[BUG] rb_thread_call_with_gvl()` | 走了旧的 Fiddle 路径 | 确认 Ruby 层已切换到 `Native` |

### 9.3 运行时阶段

| 症状 | 诊断 | 修复 |
|------|------|------|
| `CreateData called before LF_LoadLibrary` | 加载失败 | 先 `Native.load_library` |
| `no found api "xxx"` | API 未注册 | 检查 `AppHandle#register_call` |
| `prepare error: repeat listen` | 地址重复 | `Framework.reset_prepare` |
| 回调永不触发 | 调度线程未启动 | 确认 `NativeBridge.start` 已被调用 |

### 9.4 通用排查顺序

```
1. check_env.ps1                  编译环境
     ↓
2. ruby extconf.rb && make        C 扩展编译
     ↓
3. §7.1 冒烟测试                  C 扩展独立加载
     ↓
4. §7.2 完整冒烟测试              Ruby 层集成
     ↓
5. ruby test/test_errors.rb       纯 Ruby 测试
     ↓
6. ruby test/test_data_handle.rb  数据句柄测试
     ↓
7. run_test_ci.ps1                完整测试套件
```

---

## 十、验收清单

完成第一步后，以下命令应全部通过：

### 10.1 编译验证

- [ ] `ruby extconf.rb` 无 error
- [ ] `make` 无 error、无 warning
- [ ] `ext/lingofuse_ext/lingofuse_ext.so` 存在

### 10.2 部署验证

- [ ] `C:\Ruby40-x64\bin\LingoFuse64.dll` 存在
- [ ] `C:\Ruby40-x64\bin\z_ipc_64.dll` 存在
- [ ] `C:\Ruby40-x64\bin\mimalloc64.dll` 存在
- [ ] `C:\Ruby40-x64\bin\mimalloc-redirect.dll` 存在
- [ ] `lib/lingofuse_ext.so` 存在

### 10.3 加载验证

- [ ] `LingoFuse::Native.load_library` 返回 `1`
- [ ] `LingoFuse::Native.loaded?` 返回 `true`
- [ ] `LingoFuse::Native.lf_create_data("x")` 返回非零 Integer

### 10.4 Ruby 层验证

- [ ] `LingoFuse.loaded?` 返回 `true`
- [ ] `LingoFuse.library_name` 返回 `"LingoFuse64.dll"`
- [ ] `DataHandle.new("x").write_string("hello")` 无异常
- [ ] `AppHandle.new("X", "d").local_call(req)` 返回正确结果
- [ ] `Framework.set_option` / `get_option` 往返一致

### 10.5 测试套件验证

- [ ] `ruby test/test_errors.rb` 通过
- [ ] `ruby test/test_data_handle.rb` 通过
- [ ] `ruby test/test_app_handle.rb` 通过
- [ ] `ruby test/test_native_bridge_self_test.rb` 通过
- [ ] `.\run_test_ci.ps1` 输出 `All 14 test files passed.`

---

## 附录 A — 关键文件说明

### A.1 `ext/lingofuse_ext/` 内的源文件

| 文件 | 来源 | 作用 |
|------|------|------|
| `extconf.rb` | 项目 | mkmf 配置 |
| `LingoFuse.c` | 上游提供 | DLL 加载器 + 59 forwarders + helpers |
| `LingoFuse.h` | 上游提供 | C ABI 声明 |
| `lingofuse_ext.c` | 项目 | Ruby C API 表面 + 回调编组 |

### A.2 编译时的宏

| 宏 | 作用 |
|----|------|
| `_WIN32` | 启用 Windows 特定代码（`LoadLibraryA` 等） |
| `WIN32_LEAN_AND_MEAN` | 减少 `<windows.h>` 暴露的符号 |

### A.3 链接时的库

| 库 | 平台 | 作用 |
|----|------|------|
| `pthread` | MinGW | winpthreads（回调队列的原生原语） |
| `kernel32` | Windows | `LoadLibrary` / `GetModuleFileName` / `FreeLibrary` |
| `x64-ucrt-ruby400` | Windows | Ruby 4.0 运行时（mkmf 自动链接） |

---

## 附录 B — 从 Fiddle 到自写库的对照表

| 场景 | 旧（Fiddle） | 新（自写库） |
|------|-------------|-------------|
| 加载 DLL | `Fiddle.dlopen` + 手动 PATH 枚举 | `LF_LoadLibrary`（`LoadLibraryA`） |
| 声明函数 | `Fiddle::Function.new` | C 扩展的 `rb_lf_*` 方法 |
| 传递句柄 | `Fiddle::Pointer` | `Integer`（地址值） |
| 传递字符串 | 手动 `cstr_ptr` | Ruby `String`（自动转换） |
| 回调注册 | `Fiddle::Closure` + `LF_RegisterCall` | C 扩展 `NativeBridge.register_call` |
| 回调线程 | Fiddle 无法跨线程 → 死锁 | C 队列 + Ruby 调度线程 → 安全 |
| 错误信息 | `No such file or directory` | `Failed to resolve symbol LF_XXX` |

---

## 附录 C — 版本记录

| 版本 | 日期 | 变更 |
|:----:|:----:|------|
| v1.0 | 2026-10-14 | 第一步完成：Fiddle → 自写 C 扩展 |

---

*文档版本 v1.0 · 对应 LingoFuse Ruby 绑定 1.0.0 · 最后更新 2026-10-14*
