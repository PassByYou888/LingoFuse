# CONTRIBUTING.md — LingoFuse 动态库构建指南

> 本文档详细说明如何从源码构建 LingoFuse 核心动态库（`LingoFuse64.dll` / `liblingofuse.so`），涵盖 Windows、Linux（含无 Lazarus 包的特殊架构）两大平台，并整合了 FPC 3.3.1 工具链部署、`lazbuild` 编译等全部必要步骤。

---

## 📌 前置要求

- **Git**（必须支持 `--recursive` 克隆子模块）
- **Lazarus** 或 **Free Pascal Compiler (FPC) ≥ 3.2.2**（推荐 3.3.1）
- **CMake**（Linux 下编译 mimalloc 时需要）
- **Visual Studio / GCC / Clang**（取决于平台）

---

## 🚀 快速开始（一句话构建）

如果你已经安装了 Lazarus 且 FPC ≥ 3.2.2，执行以下命令即可：

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
cd LingoFuse/src
lazbuild LingoFuse.lpi
```

**⚠️ 重要**：克隆时**必须使用 `--recursive`**，否则子模块（`zIPC`、`mimalloc4p` 等）不会被拉取，编译将失败。

---

## 🧩 子模块说明

LingoFuse 依赖以下子模块（均在 `src/` 同级目录的 `Binary/` 和 `src/` 中有引用）：

| 子模块 | 说明 | 仓库 |
|--------|------|------|
| `zIPC` | 进程通信引擎（共享内存 + 消息队列） | https://github.com/PassByYou888/zIPC |
| `mimalloc4p` | Pascal 绑定和预编译库 | https://github.com/PassByYou888/mimalloc4p |

如果克隆时忘记加 `--recursive`，可以执行以下命令补全：

```bash
git submodule update --init --recursive
```

---

## 🪟 Windows 构建指南

### 1. 安装 Lazarus

- 下载 Lazarus 安装包：https://www.lazarus-ide.org
- 推荐版本：**Lazarus 4.8** 或更高，自带 FPC 3.2.2+
- 安装时建议将 Lazarus 安装到 `C:\lazarus`

### 2. 配置环境变量

将 Lazarus 的 FPC 目录添加到系统 `PATH`，例如：

```cmd
set PATH=C:\lazarus\fpc\3.2.2\bin\x86_64-win64;%PATH%
```

或将 Lazarus 安装目录（`C:\lazarus`）加入 `PATH`，以便直接调用 `lazbuild`。

### 3. 切换 FPC 版本（可选，推荐 3.3.1）

Lazarus 4.8 默认自带 FPC 3.2.2，但 LingoFuse 可能依赖更新的语言特性。**强烈建议使用 FPC 3.3.1**（同批次预编译包，确保 PPU 兼容）。

请参考项目根目录下的 **[Lazarus_Change_FPC.md](../Lazarus_Change_FPC.md)**，该文档详细说明了：

- 如何查看当前 `fpc.cfg` 位置
- 如何生成新版 FPC 的配置文件
- 如何配置 Lazarus 使用新的 FPC
- 如何 Rebuild Lazarus
- **关键提醒**：所有平台必须使用**同一构建批次**的 FPC 3.3.1，否则会出现 `PPU version mismatch`。

### 4. 构建 LingoFuse

```cmd
cd LingoFuse\src
lazbuild LingoFuse.lpi
```

成功后将生成 `LingoFuse64.dll`（或 `LingoFuse32.dll`）于 `Binary/` 目录。

---

## 🐧 Linux 构建指南

### 情况一：通过包管理器安装 Lazarus（适用于主流发行版）

```bash
# Debian / Ubuntu
sudo apt install lazarus

# Fedora / RHEL / CentOS（启用 EPEL）
sudo dnf install lazarus
```

安装后验证：

```bash
lazbuild --version
fpc -iV
```

若 FPC 版本 ≥ 3.2.2，直接执行：

```bash
cd LingoFuse/src
lazbuild LingoFuse.lpi
```

### 情况二：无 Lazarus 包或 FPC 版本过低（如 LoongArch64、RISC‑V 等）

对于龙芯、RISC‑V 等非主流架构，官方仓库可能没有现成的 Lazarus 包。此时需要**手动编译 `lazbuild`**。

完整步骤请参考项目根目录下的 **[CONTRIBUTING_lazbuild.md](../CONTRIBUTING_lazbuild.md)**，该文档以 LoongArch64 为例，详细说明了：

1. **安装系统编译依赖**（`gcc`、`make`、`gtk2-devel`、`cairo-devel` 等）
2. **部署 FPC 3.3.1**（从预编译包清单中选择对应的原生包）
3. **编译 `lazbuild`**（从 Lazarus 源码）
4. **配置环境变量 `LAZARUS_DIR`**

简要流程如下（以 LoongArch64 为例，其他架构替换包名和架构名）：

```bash
# 1. 安装依赖（RHEL系）
yum install -y make gcc gcc-c++ binutils subversion zip unzip \
    libX11-devel gtk2-devel gdk-pixbuf2-devel cairo-devel pango-devel \
    gdb rsync cmake gtk3-devel glibc-devel

# 2. 下载并解压 FPC 3.3.1 原生包（从百度网盘获取）
wget <fpc-3.3.1.loongarch64-linux.tar.gz>   # 或从其他途径获取
tar -xzf fpc-3.3.1.loongarch64-linux.tar.gz -C /tmp/fpc_deploy
cp -rf /tmp/fpc_deploy/bin/* /usr/bin/
cp -rf /tmp/fpc_deploy/lib/* /usr/lib/
cp -rf /tmp/fpc_deploy/share/* /usr/share/
ln -sf /usr/lib/fpc/3.3.1/ppcloongarch64 /usr/bin/ppcloongarch64

# 3. 生成 fpc.cfg
/usr/bin/fpcmkcfg -d basepath=/usr -o /etc/fpc.cfg

# 4. 添加所有单元子目录（关键步骤）
cd /usr/lib/fpc/3.3.1/units/loongarch64-linux   # 实际架构名
find . -type d -print | sed 's|^\.||' | while read dir; do
    [ -n "$dir" ] && echo "-Fu$(pwd)${dir}"
done >> /etc/fpc.cfg

# 5. 下载 Lazarus 源码（标签 lazarus_4_8）
wget https://gitlab.com/freepascal.org/lazarus/lazarus/-/archive/lazarus_4_8/lazarus-lazarus_4_8.zip
unzip lazarus-lazarus_4_8.zip
cd lazarus-lazarus_4_8
make clean
make lazbuild
cp lazbuild /usr/local/bin/
export LAZARUS_DIR=$(pwd)   # 或写入 ~/.bashrc

# 6. 构建 LingoFuse
cd /path/to/LingoFuse/src
lazbuild LingoFuse.lpi
```

> **注意**：不同架构的后端编译器名称不同（如 `ppcx64`、`ppca64`、`ppcriscv64` 等），请根据实际情况调整软链接名称。

---

## 🧪 验证构建结果

构建成功后，在 `Binary/` 目录下应该看到：

- Windows: `LingoFuse64.dll` 或 `LingoFuse32.dll`
- Linux: `liblingofuse.so`
- macOS: `liblingofuse.dylib`

同时 `Binary/` 目录下还有 `z_ipc_*.dll` / `libz_ipc.so` 等依赖库，这些来自子模块，已一并编译或提供预编译版本。

---

## 🧩 mimalloc 内存分配器（可选）

LingoFuse Windows 版已包含预编译的 `mimalloc64.dll` / `mimalloc32.dll`，无需额外编译。  
Linux 下如需使用 mimalloc，可自行编译：

```bash
git clone https://github.com/microsoft/mimalloc.git
cd mimalloc
git checkout v2.1.7
mkdir build && cd build
cmake .. -DMI_BUILD_SHARED=ON
make -j$(nproc)
```

将生成的 `libmimalloc.so.2.x` 复制到 `/usr/lib/` 或 LingoFuse 的 `Binary/` 目录。

> 如果没有 mimalloc，LingoFuse 会回退到系统 `malloc`，性能依然优秀。

---

## ❓ 常见问题

| 问题 | 原因 | 解决方法 |
|------|------|----------|
| `lazbuild: command not found` | Lazarus 未安装或 PATH 未设置 | 安装 Lazarus，或将 `lazbuild` 所在目录加入 PATH |
| `Fatal: Can't find unit system` | `fpc.cfg` 路径错误 | 检查 `fpc.cfg` 中的 `-Fu` 是否指向正确的单元目录 |
| `PPU version mismatch` | 不同平台的 FPC 版本不一致 | 确保所有平台使用**同一批次**的 FPC 3.3.1 预编译包 |
| 链接时提示 `undefined reference` | 缺少 `z_ipc` 或 `mimalloc` 库 | 确认子模块已初始化（`git submodule update --init --recursive`） |
| `make lazbuild` 报 GTK 相关错误 | 缺少图形库开发包 | 安装 `gtk2-devel` / `libgtk2.0-dev` 等 |
| Windows 下找不到 `z_ipc_64.dll` | 动态库不在 PATH 中 | 将 `Binary/` 目录加入 `PATH` 或将 DLL 复制到可执行文件同目录 |

---

## 🔗 相关资源

- **LingoFuse 仓库**：https://github.com/PassByYou888/LingoFuse
- **FPC 3.3.1 预编译包清单**（百度网盘）：详见项目根目录 [`FPC_3.3.1_Package_Info.md`](../FPC_3.3.1_Package_Info.md)  
  提取码：`vl5t`，总大小约 10 GB，涵盖 x86_64、ARM、LoongArch、RISC‑V 等全平台。
- **Lazarus 切换 FPC 版本教程**：[`../Lazarus_Change_FPC.md`](../Lazarus_Change_FPC.md)
- **三步构建 lazbuild 教程**：[`../CONTRIBUTING_lazbuild.md`](../CONTRIBUTING_lazbuild.md)
- **zIPC 仓库**：https://github.com/PassByYou888/zIPC
- **mimalloc 官方**：https://github.com/microsoft/mimalloc

---

## 🤝 贡献

我们欢迎任何形式的贡献！如果你在构建中遇到问题，请提交 Issue 或 PR。  
作者 QQ：`600585`（添加请备注“LingoFuse 构建”）

---

**现在，开始构建你的 LingoFuse 吧！** 🚀