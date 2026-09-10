基于您的需求，我为您编写了 LingoFuse 项目 `Binary` 目录专用的 `README.md`。该文档完全移除 zAPI 引用，重新定位为 LingoFuse 运行时依赖说明，文风轻松幽默，同时保持专业清晰。

---

# 📦 Binary —— LingoFuse 的“弹药库”

> 这里是 LingoFuse 跑起来需要的所有 **动态库（DLL / SO / DYLIB）**。  
> **下载解压，丢进 PATH，完事。**  
> 不需要编译，不需要配置，**比装个 QQ 还简单**。

---

## 📌 一句话说明

本目录包含 LingoFuse 核心运行时、IPC 引擎和内存分配器的所有二进制文件。  
**无论你是 Windows、Linux 还是 macOS，都能在这里找到对应的库。**

---

## 📦 文件清单

### 🔥 LingoFuse 核心库 —— 神经通讯地基的主引擎

| 文件名 | 平台 | 说明 |
|--------|------|------|
| `LingoFuse64.dll` | Windows 64-bit | LingoFuse 主核心库（Release） |
| `LingoFuse32.dll` | Windows 32-bit | LingoFuse 主核心库（Release） |
| `liblingofuse.so` | Linux / BSD | LingoFuse 主核心库（动态链接） |
| `liblingofuse.dylib` | macOS | LingoFuse 主核心库（动态链接） |

> 这个库负责所有跨语言 RPC 调度、服务发现、负载均衡，以及智能体通讯的“大脑”工作。  
> **没有它，LingoFuse 就是一堆废纸。**

---

### ⚡ zIPC 进程通信引擎 —— 同机光速传输

| 文件名 | 平台 | 说明 |
|--------|------|------|
| `z_ipc_64.dll` | Windows 64-bit | zIPC Release 版（生产环境用） |
| `z_ipc_32.dll` | Windows 32-bit | zIPC Release 版（生产环境用） |
| `z_ipc_64d.dll` | Windows 64-bit | zIPC Debug 版（开发调试用） |
| `z_ipc_32d.dll` | Windows 32-bit | zIPC Debug 版（开发调试用） |
| `libz_ipc.so` | Linux / BSD | zIPC 动态库 |
| `libz_ipc.dylib` | macOS | zIPC 动态库 |

zIPC 是 LingoFuse 的 **同机 IPC 引擎**，基于共享内存 + 消息队列，**延迟 < 1ms，吞吐 10,000+ 请求/秒**。  
**LingoFuse 的大规模生产调用就是靠它撑起来的。**

> ⚠️ Debug 版（带 `d` 后缀）仅供开发调试，**生产环境请用 Release 版**，否则性能会打折扣。

---

### 🧠 mimalloc 内存分配器 —— 让内存管理快如闪电

| 文件名 | 平台 | 说明 |
|--------|------|------|
| `mimalloc64.dll` | Windows 64-bit | mimalloc 核心库 |
| `mimalloc32.dll` | Windows 32-bit | mimalloc 核心库 |
| `mimalloc-redirect.dll` | Windows 64-bit | 重定向库（将 `malloc` 切换到 mimalloc） |
| `mimalloc-redirect32.dll` | Windows 32-bit | 重定向库（32位） |
| `libmimalloc.so` | Linux | 需自行编译（或使用系统包） |
| `libmimalloc.dylib` | macOS | 需自行编译（或使用系统包） |

mimalloc 是微软开源的高性能内存分配器，**低碎片、高并发**，LingoFuse 依赖它获得极致的内存管理效率。  
> 重定向库是**可选**的，仅在需要将第三方库的 `malloc`/`new` 也切换到 mimalloc 时才用。

---

### 🛠️ Visual C++ Redistributable（Windows 必备）

| 文件名 | 说明 |
|--------|------|
| `vc_redist.x64.exe` | Visual C++ 2022 Redistributable（64位） |
| `vc_redist.x86.exe` | Visual C++ 2022 Redistributable（32位） |

> **⚠️ 重要**：所有 Windows 动态库都依赖 VC++ 运行库。  
> 如果系统未安装，请双击对应的 `vc_redist.x*.exe` 安装，**否则会报“找不到模块”**。
> 请从微软官方下载并安装对应架构的版本：

- [VC++ Redistributable for Visual Studio 2022 (x86/x64)](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170)

---

### 📄 文档文件

| 文件名 | 说明 |
|--------|------|
| `mimalloc4p.md` | mimalloc4p Pascal 绑定使用指南 |
| `Z.IPC.API.md` | zIPC 底层 C API 参考文档 |
| `Z.IPC.Helper.md` | zIPC Pascal 面向对象封装使用指南 |

---

## 🚀 怎么用？

### 方式一：配置系统 PATH（推荐，一劳永逸）

将本目录的**完整路径**添加到系统 `PATH` 环境变量中：

1. 打开 **系统属性** → **高级** → **环境变量**
2. 在 **系统变量** 或 **用户变量** 中找到 `Path`，点击 **编辑**
3. 点击 **新建**，粘贴本目录的完整路径（例如 `D:\LingoFuse\Binary`）
4. 点击 **确定** 保存，**重启命令行窗口**生效

配置后，任何 LingoFuse 程序都能自动找到这些 DLL，**不用复制到每个项目目录**。

### 方式二：复制到项目目录

直接把需要的 DLL 复制到可执行文件的同目录下。  
注意位数匹配：**64位应用用 `*64.dll`，32位应用用 `*32.dll`**。

---

## ❓ 常见问题

**Q：运行时提示“找不到指定的模块”？**

A：99% 是以下原因之一：
1. 没装 VC++ Redistributable（双击 `vc_redist.x64.exe` 装上）
2. DLL 不在 `PATH` 中，也没在程序目录里
3. 位数不匹配（64位程序用了32位 DLL）

**Q：`z_ipc_64d.dll` 和 `z_ipc_64.dll` 有什么区别？**

A：带 `d` 的是 Debug 版，包含调试符号和额外检查，**仅供开发调试**。生产环境请用 Release 版（不带 `d`）。

**Q：mimalloc-redirect.dll 是必须的吗？**

A：**不是**。LingoFuse 和 zIPC 直接调用 mimalloc，不需要重定向。重定向库只在你想让第三方库（比如 OpenCV）也享受 mimalloc 加速时才需要。

**Q：Linux 下没有预编译的 mimalloc？**

A：是的。Linux 下建议使用系统包管理器安装 mimalloc（如 `apt install libmimalloc-dev`），或者从源码编译。LingoFuse 在 Linux 下也可以使用默认的 `malloc`，性能依然优秀。

---

## 🔗 相关链接

| 项目 | 仓库地址 |
|------|----------|
| **LingoFuse** | https://github.com/PassByYou888/LingoFuse |
| **zIPC** | https://github.com/PassByYou888/zIPC |
| **mimalloc4p** | https://github.com/PassByYou888/mimalloc4p |
| **mimalloc（上游）** | https://github.com/microsoft/mimalloc |

---

**现在，把库文件放好，去写你的智能体应用吧。** 🚀