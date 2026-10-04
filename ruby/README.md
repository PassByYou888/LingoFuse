# LingoFuse Ruby 绑定 — 完整手册

**版本**：1.0.0
**目标平台**：Windows 10 / 11 / Server 2019+（x64）
**Ruby 版本**：4.0+（x64-mingw-ucrt）

---

## 目录

1. [这是什么](#一这是什么)
2. [体系结构](#二体系结构)
3. [环境要求](#三环境要求)
4. [依赖安装](#四依赖安装)
5. [环境诊断](#五环境诊断)
6. [编译 C 扩展](#六编译-c-扩展)
7. [测试](#七测试)
8. [API 说明](#八api-说明)
9. [使用示例](#九使用示例)
10. [故障排查速查](#十故障排查速查)

---

## 一、这是什么

LingoFuse Ruby 绑定让 Ruby 程序能够：

- **调用**由 Pascal / C++ / C# / Python / JavaScript / Rust / Go / Dart / Java / Swift / Zig / Erlang 写的函数
- **被**上述任何语言调用
- 在**同一进程内**、**同机跨进程**、或**跨机器**范围内工作
- 使用**字节级统一**的线格式，无需 IDL、无需桩代码、无需 HTTP 服务

一句话总结：

> **任何语言写的函数，任何其他语言都能直接调；Ruby 是 14 种一等公民语言之一。**

---

## 二、体系结构

### 2.1 五层架构

```mermaid
flowchart TD
    subgraph L0["应用层 — 你的业务代码"]
        U1["LLM 服务 / 计算网格 / 数据处理"]
    end

    subgraph L1["Ruby 门面层 — lib/lingofuse/"]
        F1["DataHandle"]
        F2["AppHandle"]
        F3["LfIo"]
        F4["Framework"]
        F5["Status"]
        F6["NetworkEvents"]
    end

    subgraph L2["Fiddle 绑定层 — binding.rb"]
        B1["Fiddle::Function × 37"]
        B2["平台探测 + 路径搜索"]
    end

    subgraph L3["C 扩展层 — lingofuse_ext.so"]
        E1["原生队列"]
        E2["4 个 trampoline"]
        E3["Ruby 调度线程"]
    end

    subgraph L4["原生库"]
        N1["LingoFuse64.dll"]
        N2["z_ipc_64.dll"]
        N3["mimalloc64.dll"]
    end

    L0 --> L1
    L1 --> L2
    L1 --> L3
    L2 --> L4
    L3 --> L4

    classDef appLayer fill:#E3F2FD,stroke:#1565C0,stroke-width:2px,color:#0D47A1
    classDef rubyLayer fill:#F3E5F5,stroke:#6A1B9A,stroke-width:2px,color:#4A148C
    classDef fiddleLayer fill:#FFF3E0,stroke:#E65100,stroke-width:2px,color:#BF360C
    classDef cextLayer fill:#E8F5E9,stroke:#2E7D32,stroke-width:2px,color:#1B5E20
    classDef nativeLayer fill:#FCE4EC,stroke:#AD1457,stroke-width:2px,color:#880E4F

    class U1 appLayer
    class F1,F2,F3,F4,F5,F6 rubyLayer
    class B1,B2 fiddleLayer
    class E1,E2,E3 cextLayer
    class N1,N2,N3 nativeLayer
```

### 2.2 C 扩展存在的必要性（关键）

**这是整个绑定最重要的设计决策。**

Ruby 的 Fiddle **无法**从 LingoFuse 的原生工作线程回调 Ruby 代码。原因：

- LingoFuse 收到远端 Call / Notify / Network 事件时，会在它自己的 `TCompute` 工作线程上执行回调
- Ruby 的 `Fiddle::Closure` 试图从该线程重新进入解释器时，MRI 抛出 `[BUG] rb_thread_call_with_gvl() is called by non-ruby thread`
- 进程**永久死锁**

```mermaid
flowchart TD
    Start["远端调用到达 LingoFuse 工作线程"] --> Q{"是否持有 GVL？"}

    Q -- "否<br/>（远端调用路径）" --> NoGVL["Fiddle 无法安全进入 Ruby<br/>→ 进程死锁"]
    Q -- "是<br/>（LocalCall 路径）" --> YesGVL["Fiddle 直接执行 Proc<br/>→ 正常工作"]

    NoGVL --> Solution["解决方案：lingofuse_ext C 扩展"]
    Solution --> C1["原生队列作中转"]
    C1 --> C2["Ruby 调度线程消费队列"]
    C2 --> C3["Proc 在 Ruby 线程执行"]
    C3 --> OK["安全，无死锁"]

    classDef problem fill:#FFEBEE,stroke:#C62828,stroke-width:3px,color:#B71C1C
    classDef safe fill:#E8F5E9,stroke:#2E7D32,stroke-width:3px,color:#1B5E20
    classDef sol fill:#FFF3E0,stroke:#E65100,stroke-width:3px,color:#BF360C

    class NoGVL problem
    class YesGVL,OK safe
    class Solution,C1,C2,C3 sol
```

**结论**：
- 只做**本地调用**（`AppHandle#local_call` / `local_notify`）→ 不需要 C 扩展
- 需要**接收远端调用**（作为服务端）→ **C 扩展是必需的**

### 2.3 回调跨线程的完整时序

```mermaid
sequenceDiagram
    autonumber
    participant Remote as 远端调用者
    participant LF as LingoFuse 工作线程
    participant Ext as C 扩展队列
    participant Disp as Ruby 调度线程
    participant User as 用户 Proc

    Remote->>LF: Call(api="add", input)
    Note over LF: 不持有 GVL
    LF->>Ext: trampoline_call(trigger, input, output)
    Ext->>Ext: 入队 CallbackItem
    Ext->>Ext: signal(g_work_cond)
    Note over Ext: 阻塞在 wait_for_item
    Ext-->>LF: 等待中...

    Disp->>Ext: wait_for_work(100ms) [释放 GVL]
    Ext-->>Disp: has_work = true
    Disp->>Ext: process_all() [获取 GVL]
    Ext->>Ext: dequeue 全部 item
    Ext->>User: rb_funcall(proc, "call", input, output)
    User->>User: 业务处理
    User-->>Ext: 返回值
    Ext->>Ext: mark_done(item)
    Ext-->>LF: 唤醒 wait_for_item
    Note over LF: 释放 item, 返回

    LF-->>Remote: Call 返回
```

### 2.4 GVL 分流决策

C 扩展里每个 trampoline 都做一次关键判断：

```mermaid
flowchart TD
    Enter["trampoline 被调用"] --> Check{"ruby_thread_has_gvl_p()?"}

    Check -- "TRUE<br/>（LocalCall / LocalNotify）" --> InPlace["当前线程就是 Ruby 线程<br/>直接调用 Proc"]
    InPlace --> P1["rb_protect(dispatch_protected, args)"]
    P1 --> Done1["返回<br/>无队列、无阻塞"]

    Check -- "FALSE<br/>（远端调用）" --> Enqueue["分配 CallbackItem"]
    Enqueue --> Q1["入队 + signal"]
    Q1 --> Wait["阻塞等待 done 标志"]
    Wait --> Disp["调度线程取出 item"]
    Disp --> P2["rb_protect(dispatch_protected, args)"]
    P2 --> Mark["mark_done(item)"]
    Mark --> Wake["唤醒原生线程"]
    Wake --> Done2["返回"]

    classDef gvlHeld fill:#E8F5E9,stroke:#2E7D32,stroke-width:2px,color:#1B5E20
    classDef gvlFree fill:#E3F2FD,stroke:#1565C0,stroke-width:2px,color:#0D47A1

    class InPlace,P1,Done1 gvlHeld
    class Enqueue,Q1,Wait,Disp,P2,Mark,Wake,Done2 gvlFree
```

### 2.5 DataHandle 生命周期状态机

```mermaid
stateDiagram-v2
    [*] --> Created: DataHandle.new(api_name)
    [*] --> Permanent: create_permanent(api_name)
    [*] --> Borrowed: from_raw(raw, false)

    Created --> InUse: write_* / read_* / 访问器
    Permanent --> InUse: 同上
    Borrowed --> InUse: 同上

    InUse --> InUse: 每次访问刷新时间戳

    InUse --> MarkedDeleted: dispose() [自动回收]
    InUse --> Freed: dispose() [永久 / 借用]

    MarkedDeleted --> Freed: 池扫描检测到 deleted 标志

    InUse --> TimeoutFreed: 空闲 10 分钟
    TimeoutFreed --> Freed: 池扫描释放

    Freed --> [*]: 推回二级内存池

    note right of Borrowed
        回调输入/输出句柄
        dispose 是 no-op
        原生层负责释放
    end note

    note right of MarkedDeleted
        dispose 仅标记
        实际释放在下一次池扫描
        （≤ 5 秒）
    end note
```

### 2.6 依赖关系图

```mermaid
flowchart LR
    subgraph Top["项目根"]
        APP["你的应用"]
    end

    subgraph Lib["lib/"]
        I["lingofuse.rb"]
        subgraph Sub["lib/lingofuse/"]
            E["errors.rb"]
            CB["callback_error_reporter.rb"]
            B["binding.rb"]
            DH["data_handle.rb"]
            AH["app_handle.rb"]
            IO["lf_io.rb"]
            FW["framework.rb"]
            ST["status.rb"]
            NE["network_events.rb"]
            NB["native_bridge.rb"]
        end
        SO["lingofuse_ext.so"]
    end

    subgraph Ext["ext/lingofuse_ext/"]
        EXC["extconf.rb"]
        EXS["lingofuse_ext.c"]
    end

    subgraph Native["Binary/"]
        DLL["LingoFuse64.dll"]
        IPC["z_ipc_64.dll"]
        MI["mimalloc64.dll"]
    end

    APP --> I
    I --> E
    I --> B
    I --> DH
    I --> AH
    I --> IO
    I --> FW
    I --> ST
    I --> NE

    DH --> B
    AH --> B
    AH --> NB
    IO --> DH
    FW --> AH
    NE --> NB
    NB --> CB
    NB --> SO

    B --> DLL
    DLL --> IPC
    DLL --> MI

    EXC -.构建.-> SO
    EXS -.编译.-> SO

    classDef so fill:#E8F5E9,stroke:#2E7D32,stroke-width:3px,color:#1B5E20
    classDef dll fill:#FCE4EC,stroke:#AD1457,stroke-width:3px,color:#880E4F
    classDef src fill:#E3F2FD,stroke:#1565C0,stroke-width:2px,color:#0D47A1

    class SO so
    class DLL,IPC,MI dll
    class EXC,EXS src
```

### 2.7 文件布局

```
ruby/
├── README.md                      本文件
├── BUILD_EXTENSION.md             C 扩展编译指南
├── INSTALL_DEPENDENCIES.md        依赖安装指南
├── Gemfile                        Bundler 声明
├── lingofuse.gemspec              gem 元数据
├── Rakefile                        rake 任务
│
├── setup_build_env.ps1            C 扩展一键编译
├── clean.ps1                      清理编译产物
├── check_env.ps1                  编译环境诊断
├── check_env.rb                   运行时诊断
├── run_tests.ps1                  开发测试（Windows）
├── run_test_ci.ps1                CI 测试（Windows）
├── run_test_ci.sh                 CI 测试（Linux / macOS）
│
├── .vscode/
│   └── launch.json                VS Code 调试配置
│
├── lib/
│   ├── lingofuse.rb               公共入口
│   ├── lingofuse_ext.so           C 扩展（编译产物）
│   └── lingofuse/
│       ├── errors.rb              异常层级
│       ├── callback_error_reporter.rb
│       ├── binding.rb             Fiddle 声明 + 路径搜索
│       ├── data_handle.rb
│       ├── app_handle.rb
│       ├── lf_io.rb
│       ├── framework.rb
│       ├── status.rb
│       ├── network_events.rb
│       └── native_bridge.rb
│
├── ext/lingofuse_ext/
│   ├── extconf.rb                 mkmf 配置
│   └── lingofuse_ext.c            C 源文件
│
├── cross/
│   ├── cross_service.rb           信标
│   ├── cross_node.rb              工作节点
│   └── cross_call.rb              压测客户端
│
└── test/                          14 个测试文件
    ├── test_errors.rb
    ├── test_callback_error_reporter.rb
    ├── test_module_helpers.rb
    ├── test_lf_io.rb
    ├── test_lf_io_extra.rb
    ├── test_data_handle.rb
    ├── test_data_handle_extra.rb
    ├── test_app_handle.rb
    ├── test_app_handle_extra.rb
    ├── test_status.rb
    ├── test_network_events.rb
    ├── test_framework.rb
    ├── test_network.rb
    └── test_native_bridge_self_test.rb
```

---

## 三、环境要求

### 3.1 硬件与操作系统

| 项 | 要求 |
|---|---|
| 操作系统 | Windows 10（1809+）/ Windows 11 / Windows Server 2019+ |
| 架构 | x64（ARM64 未测试） |
| 磁盘空间 | ≥ 1 GB（含 Ruby + DevKit） |
| 内存 | ≥ 4 GB |

### 3.2 软件清单

```mermaid
flowchart LR
    A["Ruby 4.0+<br/>x64-mingw-ucrt"] --> D["核心运行时"]
    B["DevKit<br/>（msys64）"] --> D
    C["gem: minitest"] --> T["测试"]
    C2["gem: rake"] --> T
    C3["gem: debug（可选）"] --> T
    D --> LF["LingoFuse Ruby 绑定"]
    T --> LF
    N1["LingoFuse64.dll"] --> LF
    N2["z_ipc_64.dll"] --> LF
    N3["mimalloc64.dll"] --> LF

    classDef req fill:#E8F5E9,stroke:#2E7D32,stroke-width:2px,color:#1B5E20
    classDef opt fill:#FFF3E0,stroke:#E65100,stroke-width:2px,color:#BF360C
    classDef core fill:#E3F2FD,stroke:#1565C0,stroke-width:3px,color:#0D47A1

    class A,B,C,C2 req
    class C3 opt
    class D,LF,T,N1,N2,N3 core
```

### 3.3 版本选择对照表

| 组件 | 最低版本 | **推荐版本** | 禁止版本 | 说明 |
|------|:--------:|:------------:|:--------:|------|
| Ruby | 2.7.0 | **4.0.x** | x86-mingw32 | 必须 `x64-mingw-ucrt` |
| 平台 | Windows 10 1809 | **Windows 11** | — | 需要 PowerShell 5+ |
| PowerShell | 5.0 | **7.x** | 2.0-4.0 | 5.0 已够用 |
| gem: minitest | 5.0 | **5.x 最新** | — | 通常随 Ruby 一起装 |
| gem: rake | 13.0 | **13.x 最新** | — | |
| gem: debug | — | **1.11+** | — | 可选，用于 VS Code 调试 |
| LingoFuse DLL | 3.0 | **3.10+** | — | 与 `LingoFuse-v3.10` 匹配 |

**关键警告**：

- ⚠️ **一定要装 x64-mingw-ucrt 版本的 Ruby**。x64-mswin64 版本会失败
- ⚠️ **一定要装带 DevKit 的 RubyInstaller**。不带 DevKit 无法编译 C 扩展
- ⚠️ **一定不要用 Embarcadero / Borland / CodeGear 的 make.exe**。与 GNU Make 语法不兼容

---

## 四、依赖安装

### 4.1 Step 1 — 安装 Ruby + DevKit

**下载地址**：https://rubyinstaller.org/downloads/

选择：**Ruby+Devkit 4.0.x (x64)**（不是不带 Devkit 的版本）

```mermaid
flowchart TD
    S1["下载 RubyInstaller 4.0.x<br/>with Devkit"] --> S2["双击安装"]
    S2 --> S3["勾选以下选项："]
    S3 --> O1["☑ Add Ruby executables to your PATH"]
    S3 --> O2["☑ Associate .rb and .rbw files"]
    S3 --> O3["☑ Install MSYS2 development toolchain"]
    O3 --> S4["安装完成后 REOPEN PowerShell"]
    S4 --> V["验证：ruby -v"]

    classDef action fill:#E3F2FD,stroke:#1565C0,stroke-width:2px,color:#0D47A1
    classDef warn fill:#FFF3E0,stroke:#E65100,stroke-width:3px,color:#BF360C

    class S1,S2,S3,S4,V action
    class O1,O2,O3 warn
```

**安装完必做**：**关闭所有 PowerShell 窗口，重新打开**。否则 PATH 变更不生效。

**验证**：

```powershell
ruby -v
```

**期望**：

```
ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [x64-mingw-ucrt]
```

**关键**：`x64-mingw-ucrt` 是正确平台。若显示 `x64-mswin64` 或 `x86-mingw32`，重装。

### 4.2 Step 2 — 验证 DevKit

```powershell
make --version
gcc --version
```

**期望**：

| 命令 | 期望输出 |
|---|---|
| `make --version` | `GNU Make 4.4.1` |
| `gcc --version` | `gcc.exe (Rev... x86_64-w64-mingw32) 13.x.x` |

**如果 `make --version` 显示 Embarcadero / Borland**：

```powershell
# 方案 1 — 临时前置 PATH（当前会话生效）
$env:PATH = "C:\Ruby40-x64\msys64\usr\bin;" + $env:PATH

# 方案 2 — 永久修改（系统设置 → 环境变量）
# 把 C:\Ruby40-x64\msys64\usr\bin 移到 Embarcadero 之前
```

### 4.3 Step 3 — 安装 gem 依赖

```powershell
gem install minitest
gem install rake
gem install debug        # 可选，仅调试需要
```

**验证**：

```powershell
ruby -e "require 'minitest/autorun'; puts 'minitest OK'"
ruby -e "require 'debug'; puts 'debug OK'"
```

### 4.4 Step 4 — 放置 LingoFuse 原生库

**需要的文件**：

| 文件 | 用途 |
|---|---|
| `LingoFuse64.dll` | 核心 RPC 库 |
| `z_ipc_64.dll` | IPC 底层 |
| `mimalloc64.dll` | 内存分配器 |
| `mimalloc-redirect.dll` | mimalloc 重定向 |

**推荐位置**：

```
D:\CoreLibrary\LingoFuse\Binary\        ← 项目根 Binary 目录
```

`lib/lingofuse/binding.rb` 会**自动搜索**以下位置（按顺序）：

```mermaid
flowchart TD
    S1["1. $env:LINGOFUSE_LIB_PATH"] --> F{"文件存在？"}
    S2["2. 当前工作目录"] --> F
    S3["3. lib/lingofuse/"] --> F
    S4["4. lib/Binary/"] --> F
    S5["5. ruby/Binary/"] --> F
    S6["6. 项目根/Binary/"] --> F
    S7["7. 裸文件名（OS loader / PATH）"] --> F

    F -- "是" --> Load["Fiddle.dlopen(绝对路径)"]
    F -- "否" --> Next["尝试下一个"]
    Next --> F
    Load --> OK["加载成功"]

    classDef ok fill:#E8F5E9,stroke:#2E7D32,stroke-width:3px,color:#1B5E20
    class OK,Load ok
```

**第 6 条**命中标准仓库布局，所以**通常不需要设环境变量**。

**只在 DLL 放在别处时**才需要：

```powershell
$env:LINGOFUSE_LIB_PATH = "D:\OtherLocation\LingoFuse\Binary"
```

---

## 五、环境诊断

### 5.1 两个诊断脚本的分工

```mermaid
flowchart LR
    A["首次搭建环境"] --> B["check_env.ps1"]
    B --> C{"Failed = 0?"}
    C -- "是" --> D["编译环境就绪"]
    C -- "否" --> E["按提示修复"]
    E --> B

    D --> F["setup_build_env.ps1"]
    F --> G["编译 C 扩展"]

    G --> H["check_env.rb"]
    H --> I{"Failed = 0?"}
    I -- "是" --> J["运行时就绪"]
    I -- "否" --> K["按提示修复"]
    K --> H

    J --> L["run_test_ci.ps1"]

    classDef build fill:#FFF3E0,stroke:#E65100,stroke-width:2px,color:#BF360C
    classDef run fill:#E3F2FD,stroke:#1565C0,stroke-width:2px,color:#0D47A1
    classDef ok fill:#E8F5E9,stroke:#2E7D32,stroke-width:3px,color:#1B5E20

    class B,E build
    class H,K run
    class D,J,L ok
```

### 5.2 `check_env.ps1` — 编译环境诊断

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
powershell -ExecutionPolicy Bypass -File check_env.ps1
```

**检查内容**（8 个 Section）：

| Section | 检查项 |
|:-------:|--------|
| 1 | PowerShell 版本 + 操作系统 |
| 2 | Ruby 版本 / 平台 / `RbConfig` |
| 3 | **GNU Make（区分 Embarcadero）+ gcc** |
| 4 | `mkmf` 可用性 + 实际编译一个 C 程序 |
| 5 | `pthread.h` 编译链接 + `ruby/thread.h` 存在 |
| 6 | `LINGOFUSE_LIB_PATH`（**可选**，缺失不阻塞） |
| 7 | 扩展源码树完整性 |
| 8 | 汇总报告 |

**期望尾部**：

```
  Passed : 26
  Warned : 0
  Failed : 0

  All required checks passed.
```

### 5.3 `check_env.rb` — 运行时诊断

```powershell
ruby check_env.rb
```

**检查内容**（5 个 Section）：

| Section | 检查项 |
|:-------:|--------|
| 1 | Ruby 版本 |
| 2 | 包布局（11 个 lib 文件 + 3 个 test 文件） |
| 3 | 原生库加载 + C ABI 往返（create / write / read / free） |
| 4 | 全栈冒烟测试 + **C 扩展加载状态** |
| 5 | 汇总 |

**期望尾部**：

```
  Passed : 26
  Failed : 0
```

**关键检查**：

```
  [OK]   lingofuse_ext is loaded (NativeBridge available).
```

如果显示 `[FAIL] lingofuse_ext is NOT available`，说明 C 扩展未正确安装，需要回到第 6 节重新编译。

---

## 六、编译 C 扩展

### 6.1 一键编译（推荐）

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
powershell -ExecutionPolicy Bypass -File setup_build_env.ps1
```

### 6.2 `setup_build_env.ps1` 内部流程

```mermaid
flowchart TD
    S0["Section 0<br/>前置检查"] --> S0a{"平台 = Win32NT?"}
    S0a -- "否" --> Fail0["直接退出 1"]
    S0a -- "是" --> S0b{"PowerShell ≥ 5?"}
    S0b -- "否" --> Fail0
    S0b -- "是" --> S0c{"$PSScriptRoot 非空?"}
    S0c -- "否" --> Fail0
    S0c -- "是" --> S0d{"ext/ 源码树完整?"}
    S0d -- "否" --> Fail0
    S0d -- "是" --> S0e{"ruby 在 PATH?"}
    S0e -- "否" --> Fail0
    S0e -- "是" --> S0f{"ruby 能运行?"}
    S0f -- "否" --> Fail0
    S0f -- "是" --> S0g{"gcc 在 PATH?"}
    S0g -- "否" --> Fail0
    S0g -- "是" --> S0h{"mkmf 可用?"}
    S0h -- "否" --> Fail0
    S0h -- "是" --> S1["Section 1<br/>定位 GNU Make"]
    S1 --> S2["Section 2<br/>重排 PATH"]
    S2 --> S3["Section 3<br/>LINGOFUSE_LIB_PATH 信息"]
    S3 --> S4["Section 4<br/>ruby extconf.rb"]
    S4 --> S5["Section 5<br/>make"]
    S5 --> S6["Section 6<br/>严格安装产物"]
    S6 --> S7["Section 7<br/>加载测试"]
    S7 --> Done["退出 0"]

    classDef fail fill:#FFEBEE,stroke:#C62828,stroke-width:3px,color:#B71C1C
    classDef ok fill:#E8F5E9,stroke:#2E7D32,stroke-width:3px,color:#1B5E20
    classDef step fill:#E3F2FD,stroke:#1565C0,stroke-width:2px,color:#0D47A1

    class Fail0 fail
    class Done ok
    class S0,S1,S2,S3,S4,S5,S6,S7 step
```

**关键行为**：

- **Section 0 失败立即退出**，不再产生误导性错误
- **Section 6 严格安装**：复制前删除旧文件 → 复制时 `-ErrorAction Stop` → 字节数校验。任一步失败 → `exit 1`
- 如果 `lib/lingofuse_ext.so` 被占用，**明确报错**，不再"假装成功"

**期望关键输出**：

```
========================================================================
6. Artifact
========================================================================
  [OK]   Built: lingofuse_ext.so (45056 bytes)
  [OK]   Installed: D:\...\lib\lingofuse_ext.so (45056 bytes)

========================================================================
7. Load test
========================================================================
         LOADED: true true true
  [OK]   lingofuse_ext loads and exposes the full expected surface.
```

### 6.3 手动编译（备选）

```powershell
cd D:\CoreLibrary\LingoFuse\ruby\ext\lingofuse_ext

# 删除旧 Makefile
Remove-Item Makefile -ErrorAction SilentlyContinue

# 生成 Makefile
ruby extconf.rb

# 编译（必须用 GNU Make）
C:\Ruby40-x64\msys64\usr\bin\make.exe

# 复制产物
Copy-Item lingofuse_ext.so ..\..\lib\ -Force
```

### 6.4 编译产物

| 文件 | 位置 | 说明 |
|------|------|------|
| `lingofuse_ext.o` | `ext/lingofuse_ext/` | 中间对象文件 |
| `lingofuse_ext.so` | `ext/lingofuse_ext/` | 编译出的动态库 |
| `lingofuse_ext.so` | `lib/` | 安装副本（**运行时加载的**） |
| `Makefile` | `ext/lingofuse_ext/` | mkmf 生成 |
| `mkmf.log` | `ext/lingofuse_ext/` | mkmf 日志 |
| `*.def` | `ext/lingofuse_ext/` | 导出符号定义 |

### 6.5 清理

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
powershell -ExecutionPolicy Bypass -File clean.ps1
```

**三种模式**：

| 命令 | 行为 |
|------|------|
| `.\clean.ps1` | 清 ext 中间产物 + `lib/lingofuse_ext.so` |
| `.\clean.ps1 -DryRun` | 只列不删 |
| `.\clean.ps1 -KeepInstalled` | 只清 ext 中间产物，保留安装副本 |

**如果提示"文件被占用"**：脚本会**自动列出**运行中的 Ruby 进程（Id / Memory / Path），用户用 `Stop-Process -Id <Id> -Force` 停止即可。

---

## 七、测试

### 7.1 测试体系总览

```mermaid
flowchart TD
    R["测试套件 14 个文件<br/>331 项测试"] --> G1["无需原生库"]
    R --> G2["部分需要原生库"]
    R --> G3["完整需要原生库"]

    G1 --> T1["test_errors.rb<br/>23 项"]
    G1 --> T2["test_callback_error_reporter.rb<br/>10 项"]
    G1 --> T3["test_module_helpers.rb<br/>20 项"]

    G2 --> T4["test_lf_io.rb<br/>32 项"]
    G2 --> T5["test_lf_io_extra.rb<br/>33 项"]

    G3 --> T6["test_data_handle.rb<br/>44 项"]
    G3 --> T7["test_data_handle_extra.rb<br/>20 项"]
    G3 --> T8["test_app_handle.rb<br/>33 项"]
    G3 --> T9["test_app_handle_extra.rb<br/>15 项"]
    G3 --> T10["test_status.rb<br/>17 项"]
    G3 --> T11["test_network_events.rb<br/>27 项"]
    G3 --> T12["test_framework.rb<br/>30 项"]
    G3 --> T13["test_network.rb<br/>9 项"]

    R --> G4["C 扩展专用"]
    G4 --> T14["test_native_bridge_self_test.rb<br/>18 项"]

    classDef pure fill:#E8F5E9,stroke:#2E7D32,stroke-width:2px,color:#1B5E20
    classDef partial fill:#FFF3E0,stroke:#E65100,stroke-width:2px,color:#BF360C
    classDef native fill:#E3F2FD,stroke:#1565C0,stroke-width:2px,color:#0D47A1
    classDef cext fill:#F3E5F5,stroke:#6A1B9A,stroke-width:3px,color:#4A148C

    class T1,T2,T3 pure
    class T4,T5 partial
    class T6,T7,T8,T9,T10,T11,T12,T13 native
    class T14 cext
```

### 7.2 三种运行方式

| 方式 | 命令 | 用途 |
|------|------|------|
| 开发（Windows） | `.\run_tests.ps1` | 交互式跑全部 14 个文件 |
| CI（Windows） | `.\run_test_ci.ps1` | 与开发版功能相同，独立文件 |
| CI（Linux / macOS） | `bash run_test_ci.sh` | 在 POSIX 环境跑 |

```mermaid
flowchart LR
    Start["run_test_ci.ps1"] --> Step1["Step 1<br/>ruby check_env.rb"]
    Step1 --> Check1{"Passed<br/>= 26?"}
    Check1 -- "否" --> Exit1["退出 1"]
    Check1 -- "是" --> Step2["Step 2<br/>依次跑 14 个测试文件"]
    Step2 --> Check2{"全部<br/>0 failures?"}
    Check2 -- "否" --> Exit1
    Check2 -- "是" --> Done["All 14 test files passed.<br/>退出 0"]

    classDef ok fill:#E8F5E9,stroke:#2E7D32,stroke-width:3px,color:#1B5E20
    classDef fail fill:#FFEBEE,stroke:#C62828,stroke-width:3px,color:#B71C1C
    class Done ok
    class Exit1 fail
```

### 7.3 14 个测试文件详细说明

#### 组 1 — 纯 Ruby（无需原生库）

| 文件 | 测试数 | 覆盖内容 |
|------|:------:|----------|
| `test_errors.rb` | 23 | 异常层级：基类、子类、字段、`rescue` 多态 |
| `test_callback_error_reporter.rb` | 10 | 处理器安装、`report` 分发、异常吞噬、并发安全 |
| `test_module_helpers.rb` | 20 | `VERSION` / `load_library` / `library_name` / `platform` / `cstr_ptr` / `read_cstr` |

#### 组 2 — JSON 策略（部分需要原生库）

| 文件 | 测试数 | 覆盖内容 |
|------|:------:|----------|
| `test_lf_io.rb` | 32 | 紧凑输出、非 ASCII 字面量、往返、strict 解析、`IoError` 包装 |
| `test_lf_io_extra.rb` | 33 | 边界：`NUL_BYTE` / `ENCODING` / `cstr` / `peek` 游标 / `read_all_bytes` / `try_read_json` |

#### 组 3 — 数据句柄

| 文件 | 测试数 | 覆盖内容 |
|------|:------:|----------|
| `test_data_handle.rb` | 44 | 构造、位置、大小、字节 I/O、10 种标量类型、NUL 帧字符串、所有权、生命周期、块形式 |
| `test_data_handle_extra.rb` | 20 | 边界：写入返回值、多字节 UTF-8、无效 UTF-8 替换、大载荷、`create_permanent` |

#### 组 4 — 应用句柄

| 文件 | 测试数 | 覆盖内容 |
|------|:------:|----------|
| `test_app_handle.rb` | 33 | 构造、注册 Call/Notify、本地调用、重复注册、注销、大小写不敏感、回调异常隔离、回调生命周期 |
| `test_app_handle_extra.rb` | 15 | 边界：无客户端时 `bind`、未注册 API、注册表键小写、非标准异常、`local_call` 参数校验 |

#### 组 5 — 门面层

| 文件 | 测试数 | 覆盖内容 |
|------|:------:|----------|
| `test_status.rb` | 17 | 状态队列（count / get / drain / post）、`check_main_thread` / `check_app` / `check_api` |
| `test_network_events.rb` | 27 | `set` / `clear` / `installed?` / `set_listener`、`NetworkEventListener`、`NetworkEventQueue` |
| `test_framework.rb` | 30 | `reset_prepare` / `prepare_service` / `prepare_client` / `prepare_done` / `set_option` / `generate_app_name` / `get_app_name` / `call` / `try_call` |
| `test_network.rb` | 9 | `Overlap_Connection` 两种模式、`prepare_done` 只返回一次 `true`、状态队列往返 |

#### 组 6 — C 扩展自测

| 文件 | 测试数 | 覆盖内容 |
|------|:------:|----------|
| `test_native_bridge_self_test.rb` | 18 | 扩展 API 表面、trampoline 地址、`create_ref` / `free_ref`、队列空时 `wait_for_work`、Call/Notify/Network 三种 trampoline、GVL 分流、异常隔离、FIFO、并发 |

### 7.4 测试环境与条件

| 条件 | 必要性 | 说明 |
|------|:------:|------|
| Ruby 4.0+ | **必需** | 无 Ruby 无法运行 |
| LingoFuse64.dll 等 4 个 DLL | **必需** | 组 3/4/5 需要 |
| C 扩展 (`lingofuse_ext.so`) | **组 6 必需** | 其他组会警告但可运行 |
| `minitest` gem | **必需** | 测试框架 |
| 至少 4 个空闲 IPC 端点 | 条件 | 组 5 会创建大量 `ipc:ruby_*` 端点 |
| 无其他 LingoFuse 进程占用相同端点 | 条件 | 测试使用随机端点名，冲突概率极低 |

### 7.5 预期输出

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
.\run_test_ci.ps1
```

**末尾**：

```
========================================================================
All 14 test files passed.
========================================================================
```

**各项统计**：

| 文件 | Runs | Assertions | Failures | Errors |
|------|:----:|:----------:|:--------:|:------:|
| test_errors.rb | 23 | 39 | 0 | 0 |
| test_callback_error_reporter.rb | 10 | 17 | 0 | 0 |
| test_module_helpers.rb | 20 | 41 | 0 | 0 |
| test_lf_io.rb | 32 | 58 | 0 | 0 |
| test_lf_io_extra.rb | 33 | 40 | 0 | 0 |
| test_data_handle.rb | 44 | 85 | 0 | 0 |
| test_data_handle_extra.rb | 20 | 40 | 0 | 0 |
| test_app_handle.rb | 33 | 57 | 0 | 0 |
| test_app_handle_extra.rb | 15 | 28 | 0 | 0 |
| test_status.rb | 17 | 24-40 * | 0 | 0 |
| test_network_events.rb | 27 | 37 | 0 | 0 |
| test_framework.rb | 30 | 41 | 0 | 0 |
| test_network.rb | 9 | 29 | 0 | 0 |
| test_native_bridge_self_test.rb | 18 | 55 | 0 | 0 |
| **合计** | **331** | — | **0** | **0** |

> \* `test_status.rb` 的断言数取决于状态队列长度，非确定性，属正常现象。

### 7.6 日志中"看起来像错误但实际是预期"的条目

| 日志 | 来源 | 说明 |
|------|------|------|
| `[LingoFuse::NativeBridge] callback raised: intentional ...` | 自测 11 / 14 | 故意触发异常，验证 C 端 fallback 日志 |
| `[LingoFuse] Callback error in ...boom...` | test_app_handle | 故意抛异常，验证异常隔离 |
| `no found api "does_not_exist"` | 多个文件 | 故意调用不存在的 API |
| `prepare error: repeat listen/connection addr` | test_framework / test_network | 故意重复地址 |
| `LF_BindApp: Main thread is not active` | test_app_handle_extra | 故意在无主线程时 bind |
| `hint: Data handle pool "N" handles automatically freed.` | 所有含 DataHandle 的测试 | 10 分钟空闲回收，正常行为 |

---

## 八、API 说明

### 8.1 顶层模块函数

```ruby
require 'lingofuse'
```

| 函数 | 说明 |
|------|------|
| `LingoFuse::VERSION` | 绑定版本字符串（`"1.0.0"`） |
| `LingoFuse.load_library` | 幂等，总是返回 `true`（加载在 `require` 时已完成） |
| `LingoFuse.loaded?` | 原生库是否已加载 |
| `LingoFuse.library_name` | 平台相关的库文件名 |
| `LingoFuse.platform` | `{ ruby:, platform:, library: }` |
| `LingoFuse.cstr_ptr(str)` | 转 `Fiddle::Pointer`（NUL 结尾 UTF-8） |
| `LingoFuse.read_cstr(ptr)` | 从指针读 UTF-8 字符串 |

### 8.2 `LingoFuse::DataHandle`

RAII 包装：`TDataHnd`。

**构造**：

```ruby
h = LingoFuse::DataHandle.new('api_name')             # 自动回收
h = LingoFuse::DataHandle.create_permanent('api_name') # 永久
h = LingoFuse::DataHandle.borrow(raw_pointer)          # 借用（回调内用）
LingoFuse::DataHandle.open('api_name') { |h| ... }     # 块形式
```

**方法分类**：

```mermaid
flowchart LR
    DH["DataHandle"] --> L["生命周期"]
    DH --> P["位置 / 大小"]
    DH --> B["字节 I/O"]
    DH --> S["标量 I/O"]
    DH --> T["字符串 I/O"]

    L --> L1["dispose / close"]
    L --> L2["valid? / owning? / raw"]

    P --> P1["position / position="]
    P --> P2["size / size="]
    P --> P3["get_buffer_pointer"]

    B --> B1["write_bytes / read_bytes"]
    B --> B2["read_bytes_exact / try_read_bytes"]
    B --> B3["read_all_bytes"]

    S --> S1["write_int8..write_double"]
    S --> S2["read_int8..read_double"]

    T --> T1["write_string / read_string"]
    T --> T2["read_string_bytes"]
    T --> T3["try_read_string"]
```

### 8.3 `LingoFuse::AppHandle`

RAII 包装：`TAppHnd`。

**构造**：

```ruby
app = LingoFuse::AppHandle.new('AppName', 'description')
```

**方法**：

| 方法 | 说明 |
|------|------|
| `app.register_call(name, desc, &block)` | 注册 Call API |
| `app.register_notify(name, desc, &block)` | 注册 Notify API |
| `app.unregister(name)` | 注销，返回 `true` / `false` |
| `app.local_call(param)` | 本地同步调用，返回新 `DataHandle` |
| `app.local_notify(param)` | 本地异步通知 |
| `app.bind` | 绑定到空闲客户端，返回数量 |
| `app.dispose` | 释放（**两阶段析构第一步**） |
| `app.valid?` / `app.raw` / `app.name` | 状态访问 |

**回调签名**：

```ruby
app.register_call('add', 'Add two ints') do |input, output|
  a = input.read_int32
  b = input.read_int32
  output.write_int32(a + b)
end

app.register_notify('log', 'One-way log') do |input|
  msg = input.read_string
  puts msg
end
```

**回调整约**：

- 回调运行在 **Ruby 调度线程**（C 扩展路径）
- 回调内的 `input` / `output` 是**借用句柄**，不要 `dispose`
- 回调内**不要调用** `local_call` / `local_notify` / `call` / `notify`（死锁）
- 回调内**不要操作 UI**（用 `Thread::Queue` 或 `NetworkEventQueue` 转发）

### 8.4 `LingoFuse::LfIo`

统一 JSON / 字符串 / 字节 I/O。

| 函数 | 说明 |
|------|------|
| `LfIo.dumps_json(obj)` | 序列化：紧凑、非 ASCII 字面量 |
| `LfIo.loads_json(text)` | strict 解析 |
| `LfIo.write_string(handle, str)` | 写 UTF-8 + NUL |
| `LfIo.read_string(handle)` | 读到 NUL |
| `LfIo.write_string_bytes(handle, bytes)` | 写原始字节 + NUL |
| `LfIo.read_string_bytes(handle)` | 读到 NUL（不解码） |
| `LfIo.peek_string_bytes(handle)` | 读到 NUL，**不移动游标** |
| `LfIo.read_all_bytes(handle)` | 读剩余全部 |
| `LfIo.write_json(handle, obj)` | 序列化 + 写 + NUL |
| `LfIo.read_json(handle)` | 读 + 解析（抛 `JSON::ParserError`） |
| `LfIo.try_read_json(handle)` | 非抛异常版本（返回 `nil`） |
| `LfIo.cstr(value)` | 规范化为字符串 |

**线格式**：

```
[UTF-8 encoded JSON text][NUL byte]
```

**跨语言字节级兼容**：`{"a":1}` 在所有绑定上的字节序列都是：

```
7B 22 61 22 3A 31 7D 00
```

### 8.5 `LingoFuse::Framework`

进程级门面。

| 方法 | 说明 |
|------|------|
| `Framework.reset_prepare` | 清空准备队列 |
| `Framework.prepare_service(listen, physics)` | 准备服务端点 |
| `Framework.prepare_client(physics, app)` | 准备客户端连接 |
| `Framework.prepare_done` | 启动框架（**只返回一次 `true`**） |
| `Framework.exit_main_thread` | 请求主线程退出 |
| `Framework.set_option(name, value)` | 调整运行时选项 |
| `Framework.generate_app_name` | 生成唯一 App 名 |
| `Framework.get_app_name(app)` | 查询 App 权威名 |
| `Framework.call(app, param, timeout_ms)` | 同步远程调用 |
| `Framework.try_call(app, param, timeout_ms)` | 空响应返回 `nil` |
| `Framework.notify(app, param)` | 单向通知 |
| `Framework.sequenced_notify(app, param)` | FIFO 通知 |
| `Framework.shutdown` | 完全关闭（幂等） |

**运行时选项**：

| 选项 | 默认 | 说明 |
|------|:----:|------|
| `Wait_Ready` / `Wait_Connection_ReadyOk` | `True` | `prepare_done` 是否等待所有客户端就绪 |
| `Wait_Connection_Timeout` | 30000 | 等待超时（毫秒） |
| `Overlap_Connection` | `False` | 是否允许同地址多客户端 |
| `Fixed_Sequenced_Time` | 20000 | 顺序通知回退阈值 |
| `Quiet` | `False` | 安静模式 |
| `ShowThreadID` | — | 日志显示线程 ID |
| `ConsoleOutput` | — | 控制台输出 |

### 8.6 `LingoFuse::Status`

| 方法 | 说明 |
|------|------|
| `Status.get_status_count` | 队列中待处理消息数 |
| `Status.get_status` | 弹出下一条 |
| `Status.drain_status(max)` | 弹出最多 `max` 条 |
| `Status.post_status(msg)` | 推入一条 |
| `Status.check_main_thread` | 主线程是否运行 |
| `Status.check_app(name)` | App 是否可见 |
| `Status.check_api(app, api)` | API 是否可见 |

### 8.7 `LingoFuse::NetworkEvents`

进程全局连接 / 断开处理器。

```ruby
LingoFuse::NetworkEvents.set(
  on_connect:    ->(addr) { puts "+ #{addr}" },
  on_disconnect: ->(addr) { puts "- #{addr}" }
)
LingoFuse::NetworkEvents.clear
LingoFuse::NetworkEvents.installed?
LingoFuse::NetworkEvents.set_listener(listener)
```

**语义**：

- **Connect** — 客户端首次收到服务 API 广播时触发，**不是** TCP 建链
- **Disconnect** — 物理链路丢失时触发
- **回调线程** — 原生工作线程

### 8.8 `LingoFuse::NetworkEventListener`

面向对象风格：

```ruby
class MyListener < LingoFuse::NetworkEventListener
  def on_connect(addr); end
  def on_disconnect(addr); end
end

LingoFuse::NetworkEvents.set_listener(MyListener.new)
```

### 8.9 `LingoFuse::NetworkEventQueue`

队列式消费：

```ruby
q = LingoFuse::NetworkEventQueue.global_instance
q.install
begin
  loop do
    type, addr = q.get(timeout: 1.0)
    # type 是 :connect 或 :disconnect
  end
ensure
  q.uninstall
end
```

### 8.10 `LingoFuse::NativeBridge`

C 扩展的 Ruby 包装。**通常不直接使用**。

| 方法 | 说明 |
|------|------|
| `NativeBridge.available?` | 扩展是否加载 |
| `NativeBridge.start` | 启动调度线程（幂等） |
| `NativeBridge.register_call(app, name, desc, &block)` | 注册 Call，返回 `ref_addr` |
| `NativeBridge.register_notify(app, name, desc, &block)` | 注册 Notify |
| `NativeBridge.unregister(ref_addr)` | 释放 ref |

C 扩展直接暴露的方法（通过 `lingofuse_ext.so`）：

| 方法 | 说明 |
|------|------|
| `create_ref(proc, kind)` | 保存 Proc，返回地址 |
| `free_ref(addr)` | 释放 |
| `call_trampoline_addr` | Call trampoline 地址 |
| `notify_trampoline_addr` | Notify trampoline 地址 |
| `network_connect_trampoline_addr` | 连接 trampoline |
| `network_disconnect_trampoline_addr` | 断开 trampoline |
| `set_network_refs(conn, disc)` | 设置全局网络 ref |
| `process_all` | 处理队列全部项 |
| `wait_for_work(timeout_ms)` | 等待工作，返回 Boolean |
| `test_invoke_from_native_thread(...)` | 测试用 |
| `test_invoke_network_event(...)` | 测试用 |
| `test_invoke_network_event_inplace(...)` | 测试用 |

**kind 常量**：

| 值 | 含义 |
|:-:|------|
| `0` | Call |
| `1` | Notify |
| `2` | Network connect |
| `3` | Network disconnect |

### 8.11 `LingoFuse::CallbackErrorReporter`

```ruby
LingoFuse::CallbackErrorReporter.handler = ->(source, error) do
  puts "[#{source}] #{error.class}: #{error.message}"
end

LingoFuse::CallbackErrorReporter.report('src', err)
```

- 未装 handler 时写到 `$stderr`
- handler 内部异常被吞噬
- 线程安全

### 8.12 异常层级

```mermaid
classDiagram
    StandardError <|-- Error
    Error <|-- LibraryLoadError
    Error <|-- CallError
    Error <|-- IoError
    Error <|-- ObjectDisposedError
    Error <|-- RegistrationError
    Error <|-- CallbackError

    class Error {
        +message
    }
    class LibraryLoadError {
        +library_name
    }
    class CallError {
        +target_app
        +target_api
    }
    class IoError {
        +operation
    }
    class ObjectDisposedError {
        +object_name
    }
    class RegistrationError {
        +api_name
    }
    class CallbackError {
        +source
        +original_cause
    }
```

**捕获策略**：

```ruby
begin
  # LingoFuse 操作
rescue LingoFuse::CallError => e
  puts "调用失败: #{e.target_app}.#{e.target_api}"
rescue LingoFuse::Error => e
  puts "LingoFuse 错误: #{e.message}"
end
```

---

## 九、使用示例

### 9.1 纯本地调用

```ruby
require 'lingofuse'

app = LingoFuse::AppHandle.new('Calculator', 'Demo')

app.register_call('add', 'Add two ints') do |input, output|
  a = input.read_int32
  b = input.read_int32
  output.write_int32(a + b)
end

param = LingoFuse::DataHandle.new('add')
param.write_int32(5)
param.write_int32(7)

result = app.local_call(param)
puts result.read_int32   # 12

param.dispose
result.dispose
app.dispose
```

### 9.2 服务端

```ruby
require 'lingofuse'

app = LingoFuse::AppHandle.new('Calculator', 'Server')

app.register_call('add', 'Add') do |input, output|
  req = LingoFuse::LfIo.read_json(input)
  result = (req['a'] || 0) + (req['b'] || 0)
  LingoFuse::LfIo.write_json(output, { result: result })
end

LingoFuse::Framework.set_option('Wait_Ready', 'False')
LingoFuse::Framework.reset_prepare
LingoFuse::Framework.prepare_service('ipc:calc', 'ipc:calc')
LingoFuse::Framework.prepare_client('ipc:calc', app)

if LingoFuse::Framework.prepare_done
  puts 'Server ready. Press Enter to exit...'
  $stdin.gets
end

LingoFuse::Framework.exit_main_thread
app.dispose
LingoFuse::Framework.shutdown
```

### 9.3 客户端

```ruby
require 'lingofuse'

LingoFuse::Framework.set_option('Wait_Ready', 'False')
LingoFuse::Framework.reset_prepare
LingoFuse::Framework.prepare_client('ipc:calc', nil)
LingoFuse::Framework.prepare_done

# 等待 App 可见
30.times do
  break if LingoFuse::Status.check_app('Calculator')
  sleep 0.2
end

param = LingoFuse::DataHandle.new('add')
LingoFuse::LfIo.write_json(param, { a: 40, b: 2 })

result = LingoFuse::Framework.call('Calculator', param, 3000)
puts LingoFuse::LfIo.read_json(result)['result']   # 42

param.dispose
result.dispose
LingoFuse::Framework.exit_main_thread
LingoFuse::Framework.shutdown
```

### 9.4 Cross Demo

三个进程，验证跨进程 / 跨语言：

```powershell
# 终端 1
ruby cross/cross_service.rb

# 终端 2
ruby cross/cross_node.rb

# 终端 3
ruby cross/cross_call.rb
```

```mermaid
flowchart LR
    S["cross_service.rb<br/>信标"]
    N["cross_node.rb<br/>工作节点"]
    C["cross_call.rb<br/>压测客户端"]

    C -->|"① 发现信标"| S
    S -.->|"② 广播路由"| N
    C ==>|"③ Call add / inv_seri"| N
    N -->|"④ 字节响应"| C

    classDef beacon fill:#FFF3E0,stroke:#E65100,stroke-width:3px,color:#BF360C
    classDef worker fill:#E8F5E9,stroke:#2E7D32,stroke-width:3px,color:#1B5E20
    classDef client fill:#E3F2FD,stroke:#1565C0,stroke-width:3px,color:#0D47A1

    class S beacon
    class N worker
    class C client
```

---

## 十、故障排查速查

| 症状 | 原因 | 修复 |
|------|------|------|
| `ruby: command not found` | PATH 未生效 | 重启 PowerShell |
| `cannot load such file -- lingofuse` | LOAD_PATH 未设置 | `ruby -I lib ...` 或 `require_relative` |
| `Failed to load the LingoFuse native library` | DLL 找不到 | 检查 `Binary/` 或设 `LINGOFUSE_LIB_PATH` |
| `[BUG] rb_thread_call_with_gvl()` | C 扩展未编译 | 跑 `setup_build_env.ps1` |
| `[LingoFuse::NativeBridge] lingofuse_ext not available` | C 扩展不在 LOAD_PATH | 用 `-I lib`，或安装到 `lib/` |
| `No GNU Make found` | DevKit 未安装 / PATH 顺序 | 见 §3.2 |
| `Fatal makefile ... No terminator` | 用了 Embarcadero Make | 前置 msys64 到 PATH |
| `gettimeofday: conflicting types` | 头文件冲突 | 更新 `lingofuse_ext.c`（去 `<sys/time.h>`） |
| `undefined reference to 'clock_gettime'` | MinGW 缺 pthread | 重装 DevKit |
| `Cannot replace lib\lingofuse_ext.so` | 文件被占用 | `Get-Process ruby \| Stop-Process -Force` |
| `prepare error: repeat listen` | 地址重复 | `Framework.reset_prepare` 后重试 |
| `prepare error: repeat connection` | 地址重复 | 设 `Overlap_Connection=True` |
| `no connection` | 目标 App 不可见 | 等 broadcast 广播，用 `check_app` 轮询 |
| `hint: Data handle pool ... automatically freed.` | 10 分钟空闲回收 | 正常行为 |
| `callback raised: ...`（前缀 `NativeBridge`） | 回调抛异常 | 修回调；已通过 `CallbackErrorReporter` 报告 |
| 调试器无法启动 | `debug` gem 未装 | `gem install debug` |

**通用排查顺序**：

```mermaid
flowchart TD
    Issue["遇到问题"] --> Q1{"check_env.ps1 通过？"}
    Q1 -- "否" --> Fix1["修复编译环境"]
    Q1 -- "是" --> Q2{"setup_build_env.ps1 通过？"}
    Q2 -- "否" --> Fix2["按 Section 0 的报错修复"]
    Q2 -- "是" --> Q3{"check_env.rb 通过？"}
    Q3 -- "否" --> Fix3["修复运行时环境"]
    Q3 -- "是" --> Q4{"run_test_ci.ps1 通过？"}
    Q4 -- "否" --> Fix4["看具体失败的测试文件"]
    Q4 -- "是" --> OK["环境完全就绪"]

    classDef ok fill:#E8F5E9,stroke:#2E7D32,stroke-width:3px,color:#1B5E20
    classDef fail fill:#FFEBEE,stroke:#C62828,stroke-width:2px,color:#B71C1C

    class OK ok
    class Fix1,Fix2,Fix3,Fix4 fail
```

---

## 附录 A — 与其他语言的互通性

同一个 JSON 载荷在**所有** LingoFuse 绑定上产生**相同的字节序列**：

| 语言 | 文件 | 绑定类型 |
|------|------|----------|
| Pascal | `lingofuse_import.pas` | 原生 |
| C | `LingoFuse.h` / `LingoFuse.c` | 原生 |
| C++ | `LingoFuse.hpp` / `lf_io.hpp` | 原生 |
| C# | `LingoFuse.cs` / `LfIo.cs` | P/Invoke |
| Python | `lingofuse.lf_io` | ctypes |
| JavaScript | `index.js` / `lf-io.js` | Koffi |
| **Ruby** | **本绑定** | **Fiddle + C 扩展** |
| Rust | `io.rs` | FFI |
| Go | `lingofuse.go` | purego |
| Dart | `lf_io.dart` | FFI |
| Java | `LingoFuse.java` | FFM API |
| Swift | `LfIo.swift` | C++ 桥 |
| Zig | `lf_io.zig` | C ABI |
| Erlang | `lingofuse.erl` | NIF |

**示例**：`{"a":1}` 在所有绑定上的线字节：

```
7B 22 61 22 3A 31 7D 00
```

跨语言 RPC **无需任何转码层**。

---

## 附录 B — 快速命令卡

```powershell
# ============ 环境诊断 ============
cd D:\CoreLibrary\LingoFuse\ruby

.\check_env.ps1                        # 编译环境
ruby check_env.rb                      # 运行时环境

# ============ 编译 C 扩展 ============
.\setup_build_env.ps1                  # 一键编译 + 安装 + 加载测试
.\clean.ps1                            # 清理全部编译产物
.\clean.ps1 -DryRun                    # 预览清理
.\clean.ps1 -KeepInstalled             # 只清 ext/，保留 lib/

# ============ 测试 ============
.\run_tests.ps1                        # 开发测试
.\run_test_ci.ps1                      # CI 测试

# 单个测试
ruby test\test_errors.rb
ruby test\test_data_handle.rb
ruby test\test_native_bridge_self_test.rb

# ============ Cross Demo（三个终端）============
ruby cross\cross_service.rb
ruby cross\cross_node.rb
ruby cross\cross_call.rb
```

---

## 附录 C — 许可

MIT。

---

*文档版本 1.0 · 与 LingoFuse Ruby 绑定 1.0.0 匹配 · 最后更新 2026-10-04*