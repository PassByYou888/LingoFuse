# Windows 下 Lazarus 4.8 切换 FPC 3.3.1 完整教程

> **适用场景**：Lazarus 4.8 自带 FPC 3.2.2，你需要切换到 FPC 3.3.1 来编译 LingoFuse 等项目。  
> **核心技巧**：**先观察原有 `fpc.cfg` 放在哪里，然后模仿同样的规则，为新版 FPC 生成配置文件。**  
> **终极原则**：**所有参与编译的机器（Windows 开发机 + Linux 部署机）必须使用来自同一个构建源的 FPC 3.3.1 预编译包！**

---

## 🎯 关键技巧：先看老的，再配新的（适用于任何 FPC 版本切换）

在配置任何新版本的 FPC 之前，**先找到当前正在使用的 `fpc.cfg` 在哪里**。这个文件定义了 FPC 如何查找单元文件（`.ppu`）、库文件等。

**操作方法**：在命令行执行以下命令，系统会告诉你当前 `fpc.cfg` 的准确位置：

```cmd
fpc -vt 2>&1 | find "fpc.cfg"
```

或者，如果你已经知道 Lazarus 自带的 FPC 位置，直接查看：

```cmd
dir /s /b C:\lazarus\fpc\*.cfg
```

以你的实际环境为例，执行结果如下：

```
C:\lazarus>dir /s /b fpc.cfg
C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.cfg   ← 旧版 FPC 的配置文件
C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg   ← 新版 FPC 的配置文件（将生成）
```

**关键发现**：在 Lazarus 的 FPC 目录结构中，`fpc.cfg` **直接放在 `bin\x86_64-win64\` 目录下**，与 `fpc.exe` 同级。  
**结论**：你为新版 FPC 3.3.1 生成的 `fpc.cfg`，也应该放在同样的位置 —— `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg`。

---

## ⚠️ 重中之重：开发环境与部署环境的 FPC 版本必须完全一致！

> **FPC 3.3.1 是开发分支（main/trunk），几乎每天都有代码更新（Daily Snapshot）。**  
> 不同日期构建的 3.3.1，其 RTL（运行时库）内部结构可能不同。  
> **如果你在 Windows 上用 8月1日的 3.3.1 编译，在 Linux（LoongArch64）上用 8月17日的 3.3.1 链接，会报错：**  
> - `PPU version mismatch`  
> - `Invalid PPU file format`  
>
> **✅ 正确做法：**  
> **所有平台必须使用同一天（同一 Commit）的 FPC 3.3.1 预编译包。**  
> 本文附录的 **FPC 3.3.1 预编译包清单** 中的所有包均来自**同一个构建批次**，可放心在多平台间混用。

---

## 📦 你的实际目录结构

```
C:\lazarus\                       ← Lazarus 4.8 安装根目录
├── fpc\
│   ├── 3.2.2\                    ← Lazarus 自带的旧版 FPC（保留不动）
│   │   └── bin\x86_64-win64\
│   │       ├── fpc.exe
│   │       └── fpc.cfg           ← 旧版配置文件（参考模板）
│   └── 3.3.1\                    ← 你手动安装的新版 FPC
│       └── bin\x86_64-win64\
│           ├── fpc.exe
│           ├── fpcmkcfg.exe
│           └── fpc.cfg           ← ⭐ 需要生成的配置文件（放这里！与 fpc.exe 同级）
├── components\
└── ...
```

---

## 🔧 第一步：确认 FPC 3.3.1 已正确安装

打开命令提示符，执行：
```cmd
C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.exe -iV
```
应输出 `3.3.1`。如果提示找不到文件，检查路径中 `x86_64-win64` 是否与你实际目录匹配（32位为 `i386-win32`）。

---

## ⚙️ 第二步：模仿旧版规则，生成新版 `fpc.cfg`

### 📌 关键：`basepath` 规则说明

旧版 FPC 3.2.2 的 `fpc.cfg` 位于 `C:\lazarus\fpc\3.2.2\bin\x86_64-win64\`，其 `basepath`（FPC 根目录）是 `C:\lazarus\fpc\3.2.2`。

新版 FPC 3.3.1 的 `fpc.cfg` 应位于 `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\`，其 `basepath` 应为 `C:\lazarus\fpc\3.3.1`。

**`fpcmkcfg` 命令格式**：
```cmd
<fpc根目录>\bin\x86_64-win64\fpcmkcfg -d basepath=<fpc根目录> -o <输出路径>\fpc.cfg
```

**针对你的目录，执行**：
```cmd
C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpcmkcfg -d basepath=C:\lazarus\fpc\3.3.1 -o C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg
```

### ✅ 验证生成结果

用记事本打开 `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg`，搜索 `-Fu`，应该看到类似：
```
-FuC:\lazarus\fpc\3.3.1\lib\fpc\3.3.1\units\x86_64-win64\*
```
如果路径中出现了 `lib\fpc\3.3.1\units\x86_64-win64\`，说明配置生成正确。  
**如果路径错误（例如指向了旧版 3.2.2 的目录），请检查 `basepath` 是否写错。**

---

## ⚙️ 第三步：配置 Lazarus 使用新的 FPC 3.3.1

1. **关闭并重启 Lazarus**。
2. 点击菜单 `Tools` → `Options`。
3. 左侧展开 `Environment`，点击 **`Files`**。
4. 在右侧设置：

   | 选项 | 路径 |
   | :--- | :--- |
   | **`Compiler path`** | `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.exe` |
   | **`Compiler config file`** | `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg` |

5. 点击 **`OK`** 保存。

---

## ✅ 第四步：验证编译器切换是否成功

1. 新建项目（`Project` → `New Project` → `Simple Program`）。
2. 按 `Ctrl+F9` 编译，查看 `Messages` 窗口，应显示：
   ```
   Free Pascal Compiler version 3.3.1 ...
   ```
3. 如果仍然显示 3.2.2，请重新检查第三步的路径是否正确。

---

## 🔁 第五步：Rebuild Lazarus（重新编译 IDE）

1. 点击菜单 `Tools` → `Configure “Build Lazarus”`。
2. 先点击 **`Clean`** 清除旧缓存，然后点击 **`Build`**。
3. 等待编译完成（3~10 分钟）。

### 🛠 编译报错？随手修，别慌！

**Rebuild Lazarus 时出点小错是家常便饭**，尤其是用每日更新的 FPC 3.3.1 去编译一个基于稳定版 FPC 3.2.2 开发的 IDE 源码。  
**绝大多数都是以下这几类小问题，按表随手修一下就能过，不必大惊小怪：**

| 错误类型 | 典型信息 | 随手修复 |
| :--- | :--- | :--- |
| **单元未找到** | `Fatal: Can't find unit xxx` | 在报错项目的 `Project Options` → `Compiler Options` → `Other unit files` 中添加缺失路径，或先编译依赖包 |
| **标识符不认识** | `Error: Identifier not found "TMethod"` | 在 `uses` 子句中添加缺失单元（如 `TypInfo`、`SysUtils`） |
| **编译选项过时** | `Warning: Compiler option "..." is deprecated` | 在 `Project Options` → `Custom Options` 中移除或替换该选项 |
| **汇编语法不兼容** | `Assembler syntax error` | 用 `{$IF FPC_FULLVERSION >= 30301}` 条件编译隔离新旧代码 |

**如果错误太多一时修不完**：可以先卸载部分第三方包，成功 Rebuild 后再重新安装这些包（届时会用新 FPC 重新编译）。  
**记住**：这些错误不是你的问题，是 Lazarus 源码和 FPC 每日构建版本之间的正常磨合。随手改两行，继续 Build，基本都能过去。

---

## ✅ 第六步：最终验证

1. Rebuild 成功后，Lazarus 自动重启。
2. `Help` → `About Lazarus`，确认 `FPC Version` 显示 `3.3.1`。
3. 新建 GUI 应用，放按钮，写入：
   ```pascal
   ShowMessage('FPC: ' + {$I %FPC_VERSION%});
   ```
   运行应弹出 `FPC: 3.3.1`。

---

## 🚀 第七步：与 Linux 目标环境（LoongArch64）保持版本同步

| 环境 | 检查命令 | 期望输出 |
| :--- | :--- | :--- |
| **Windows** | `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.exe -iW` | 版本日期与 Linux 一致 |
| **Linux** | `fpc -iW` | 版本日期与 Windows 一致 |

**确保两端输出的日期和 Commit ID 完全一致！** 如果不一致，请从下方清单中重新下载匹配的包。

---

## 📚 附录：FPC 3.3.1 预编译包清单（多平台统一版本）

> **下载地址**：https://pan.baidu.com/s/1wnlNAjCv3-KaURp3kOaZzw  
> **提取码**：`vl5t`  
> **总大小**：约 10 GB  
> **说明**：以下所有包均来自**同一个构建批次**，版本日期一致，可放心跨平台混用。

### 桌面/服务器通用平台

| 文件名 | 大小 | 说明 |
|--------|------|------|
| `fpc-3.3.1.x86_64-linux.tar.gz` | 102 MB | **x86_64 Linux 原生编译器** |
| `fpc-3.3.1.x86_64-win64.built.on.x86_64-linux.tar.gz` | 211 MB | **x86_64 Win64 交叉编译器**（Linux 上构建） |
| `fpc-3.3.1.i386-win32.zip` | 91 MB | **i386 Win32 原生编译器**（Windows 安装包） |
| `fpc-3.3.1.aarch64-darwin.tar.gz` | 139 MB | **AArch64 macOS 交叉编译器** |

### 🐧 Linux 发行版（重点：LoongArch64）

| 文件名 | 大小 | 说明 |
|--------|------|------|
| `fpc-3.3.1.loongarch64-linux.tar.gz` | 218 MB | ⭐ **LoongArch64 Linux 原生编译器**（你的部署目标） |
| `fpc-3.3.1.loongarch64-linux.built.on.x86_64-linux.tar.gz` | 123 MB | LoongArch64 Linux 交叉编译器（x86_64 上构建） |
| `fpc-3.3.1.aarch64-linux.built.on.x86_64-linux.tar.gz` | 99 MB | AArch64 Linux 交叉编译器 |
| `fpc-3.3.1.riscv64-linux.built.on.x86_64-linux.tar.gz` | 111 MB | RISC-V 64 Linux 交叉编译器 |
| `fpc-3.3.1.arm-linux.built.on.x86_64-linux-eabihf.tar.gz` | 98 MB | ARM Linux（硬浮点）交叉编译器 |
| `fpc-3.3.1.powerpc64-linux.built.on.x86_64-linux.tar.gz` | 105 MB | PowerPC64 Linux 交叉编译器 |

### 📱 嵌入式与移动平台（部分）

| 文件名 | 说明 |
|--------|------|
| `fpc-3.3.1.aarch64-android.built.on.x86_64-linux.tar.gz` | AArch64 Android 交叉编译器 |
| `fpc-3.3.1.arm-android.built.on.x86_64-linux.tar.gz` | ARM Android 交叉编译器 |
| `fpc-3.3.1.arm-embedded.built.on.x86_64-linux.tar.gz` | ARM 嵌入式交叉编译器 |

### 💾 经典平台

| 文件名 | 说明 |
|--------|------|
| `fpc-3.3.1-WmCompact.msdos.zip` | MS-DOS（紧凑内存模型） |
| `fpc-3.3.1.i386-freebsd.built.on.x86_64-linux.tar.gz` | i386 FreeBSD 交叉编译器 |
| `fpc-3.3.1.m68k-amiga.built.on.x86_64-linux.tar.gz` | m68k Amiga 交叉编译器 |

### 🧪 WebAssembly 与 JVM

| 文件名 | 说明 |
|--------|------|
| `fpc-3.3.1.wasm32-embedded.built.on.x86_64-linux.tar.gz` | WebAssembly 嵌入式交叉编译器 |
| `fpc-3.3.1.jvm-java.built.on.x86_64-linux.tar.gz` | JVM（Java）交叉编译器 |

---

## ❗ 常见问题速查

| 问题 | 原因 | 解决方案 |
| :--- | :--- | :--- |
| `fpc -iV` 显示旧版本 | PATH 环境变量指向旧版 | 在 Lazarus 的 `Tools` → `Options` 中强制指定 `fpc.exe` 完整路径 |
| `Can't find unit system` | `fpc.cfg` 中 `-Fu` 路径错误 | 检查 `basepath` 是否正确指向根目录，重新生成 `fpc.cfg` |
| Windows 和 Linux 的 PPU 不兼容 | 两端 FPC 版本日期不同 | 从上述清单中下载同一批次的包，确保 `fpc -iW` 输出一致 |
| Rebuild 后 Lazarus 启动报错 | 旧 `.ppu` 缓存未清理 | 删除 `C:\Users\你的用户名\AppData\Local\lazarus\` 下的 `.ppu` 和 `.o` 文件，重新 Clean + Build |


## 🔗 相关资源

### 本项目相关

| 文档 | 说明 |
|------|------|
| [`CONTRIBUTING.md`](./CONTRIBUTING.md) | LingoFuse 动态库构建指南（总览） |
| [`FPC_3.3.1_Package_Info.md`](./FPC_3.3.1_Package_Info.md) | FPC 预编译包平台索引 |
| [项目根目录 README](../readme.md) | LingoFuse 项目总览和语言绑定索引 |
| [LingoFuse 项目仓库](https://github.com/PassByYou888/LingoFuse) | GitHub 主仓库 |
| [zIPC 子模块仓库](https://github.com/PassByYou888/zIPC) | 进程通信组件 |

### 官方资源

| 资源 | 链接 |
|------|------|
| **Free Pascal 官网** | https://www.freepascal.org/ |
| **Free Pascal 文档** | https://www.freepascal.org/docs.html |
| **Lazarus IDE 官网** | https://www.lazarus-ide.org/ |
| **Lazarus Wiki** | https://wiki.lazarus.freepascal.org/ |
| **FPC/Lazarus 社区论坛** | https://forum.lazarus.freepascal.org/ |
| **Lazarus 源码仓库** | https://gitlab.com/freepascal.org/lazarus/lazarus |

### 其他参考

| 资源 | 链接 |
|------|------|
| **mimalloc**（内存分配器） | https://github.com/microsoft/mimalloc |
| **LingoFuse 文档索引** | 详见根目录 `readme.md` |

---

> **文档作者：老张 qq600585**
> 本指南基于龙芯平台实测，欢迎反馈问题。