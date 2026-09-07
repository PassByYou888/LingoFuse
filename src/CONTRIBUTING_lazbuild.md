# 三步构建 lazbuild（手动操作版 · 适配 loongarch64 + lazarus_4_8）

### 在 LoongArch64 Linux 上离线编译 Lazarus 命令行工具

---

> **📌 本指南针对您的文件定制**
>
> - FPC 压缩包：`fpc-3.3.1.loongarch64-linux.tar.gz`（原生龙芯包）
> - Lazarus 源码包：`lazarus_4_8.zip`（来自 Git 标签 `lazarus_4_8` 的打包）
> - 操作系统：Loongnix / 任何 RHEL 系 Linux / Debian/Ubuntu
> - **所有步骤均需手动执行**，每步配有详细解释，确保您完全理解操作意图。
> - **流程通用性**：仅需替换架构名和压缩包名，即可迁移到其他 Linux 架构（x86_64、ARM、RISC‑V 等）。
> - **关于路径**：以下示例中，假设您的压缩包放在 `~/downloads/` 目录下。请您根据实际情况替换为您的真实路径（例如 `/home/你的用户名/downloads/` 或 `/root/downloads/`）。
> - fpc3.3.1全系统打包+lazarus4.8分支源码，总共10G左右，百度网盘：[https://pan.baidu.com/s/1wnlNAjCv3-KaURp3kOaZzw](https://pan.baidu.com/s/1wnlNAjCv3-KaURp3kOaZzw) 提取码：vl5t
>
> **作者：老张 qq600585**

---


## 📦 准备工作

### 1. 确认文件位置

将以下两个文件放到同一个目录，例如 `~/downloads/`（请根据实际修改）：

- `fpc-3.3.1.loongarch64-linux.tar.gz`
- `lazarus_4_8.zip`

> 完整的 FPC 3.3.1 预编译包平台清单，请参考同目录下的 [`FPC_3.3.1_Package_Info.md`](./FPC_3.3.1_Package_Info.md)。

### 2. 解压 Lazarus 源码包（.zip 格式）

`.zip` 格式在 Linux 下使用 `unzip` 命令解压，绝大多数 Linux 发行版默认已安装该工具。若未安装，可通过包管理器快速安装：

```bash
# RHEL / CentOS / Loongnix
yum install -y unzip

# Debian / Ubuntu
apt install -y unzip
```

**解压命令**：

```bash
cd ~/downloads
unzip lazarus_4_8.zip
```

解压后会得到一个目录（通常名为 `lazarus` 或 `lazarus-4.8`）。进入该目录，确认其中包含 `lcl`、`components` 等子目录，这就是 Lazarus 源码根目录。

> **关于 FPC 压缩包**：`fpc-3.3.1.loongarch64-linux.tar.gz` 是标准的 `.tar.gz` 格式，Linux 系统自带的 `tar` 命令即可解压，无需额外工具。解压命令见第二步。

---

### 3. 确定架构

本机为 `loongarch64`，已确认。

---


## 🔧 第一步：安装系统编译依赖

**目的**：安装编译 Lazarus 所需的基础开发工具和图形库。

以 root 执行：

```bash
# RHEL / CentOS / Loongnix
yum install -y make gcc gcc-c++ binutils subversion zip unzip \
    libX11-devel gtk2-devel gdk-pixbuf2-devel cairo-devel pango-devel \
    gdb rsync cmake gtk3-devel glibc-devel

# Debian / Ubuntu
apt install -y make gcc g++ binutils subversion zip unzip \
    libx11-dev libgtk2.0-dev libgdk-pixbuf2.0-dev libcairo2-dev libpango1.0-dev \
    gdb rsync cmake libgtk-3-dev
```

> **为什么需要这些？**
>
> - `make`, `gcc`, `binutils`：编译必需品。
> - `gtk2-devel`, `cairo-devel`：LCL 图形库依赖，即使只编译 `lazbuild`（无 GUI），部分 Makefile 仍会引用，缺失会导致链接错误。
> - `cmake`：一些构建辅助工具需要。

**验证**：

```bash
make --version
gcc --version
cmake --version
```

均应正常输出。

---


## 📂 第二步：部署 FPC 并配置搜索路径

**目的**：安装 FPC 编译器本体，配置单元搜索路径，确保后续编译能找到所有 `.ppu`。

> 官方资源：[Free Pascal 官网](https://www.freepascal.org/) | [FPC 文档](https://www.freepascal.org/docs.html) | [FPC 论坛](https://forum.lazarus.freepascal.org/)

### 操作步骤

#### ① 解压 FPC 包

```bash
cd ~/downloads
FPC_TARBALL="fpc-3.3.1.loongarch64-linux.tar.gz"
mkdir -p /tmp/fpc_deploy
tar -xzf "$FPC_TARBALL" -C /tmp/fpc_deploy
```

解压后，`/tmp/fpc_deploy` 下会得到 `bin/`、`lib/`、`share/` 三个目录。

#### ② 复制文件到系统目录

```bash
\cp -rf /tmp/fpc_deploy/bin/* /usr/bin/
\cp -rf /tmp/fpc_deploy/lib/* /usr/lib/
\cp -rf /tmp/fpc_deploy/share/* /usr/share/
```

> 使用 `\cp` 避免交互式覆盖提示。

#### ③ 创建后端编译器软链接

龙芯架构的后端编译器名为 `ppcloongarch64`：

```bash
ln -sf /usr/lib/fpc/3.3.1/ppcloongarch64 /usr/bin/ppcloongarch64
```

> 这样 `fpc` 命令才能调用到实际编译器。

#### ④ 生成基础 `fpc.cfg`

```bash
/usr/bin/fpcmkcfg -d basepath=/usr -o /etc/fpc.cfg
```

若提示 `fpcmkcfg` 不存在，请检查第②步是否完整复制。

#### ⑤ 将所有单元子目录添加到配置（关键步骤）

> **注意**：不要直接复制绝对路径，请先进入目录查看实际架构名称。

```bash
# 进入 FPC 单元根目录
cd /usr/lib/fpc/3.3.1/units

# 列出所有架构目录，找到您的目标（例如 loongarch64-linux）
ls

# 根据列出的名称，进入对应的架构目录（请将 loongarch64-linux 替换为实际看到的名称）
cd loongarch64-linux   # 请替换为实际目录名

# 现在将当前目录下的所有子目录添加到 fpc.cfg
find . -type d -print | sed 's|^\.||' | while read dir; do
    [ -n "$dir" ] && echo "-Fu$(pwd)${dir}"
done >> /etc/fpc.cfg
```

> **为什么这样做？**
> 不同架构的目录名不同（例如 x86_64-linux、aarch64-linux 等），通过 `ls` 查看后再进入，可以避免因硬编码路径导致的错误。`$(pwd)` 会动态获取当前绝对路径，确保添加的路径正确。

#### ⑥ 清理临时文件（可选）

```bash
rm -rf /tmp/fpc_deploy
```

### 验证 FPC

```bash
fpc -iV          # 应输出 3.3.1
ppcloongarch64 -iV  # 同样输出版本号
```

---


## 🛠️ 第三步：编译 `lazbuild`

**目的**：从 Lazarus 源码编译出命令行工具 `lazbuild`，用于后续自动化构建。

> 官方资源：[Lazarus IDE 官网](https://www.lazarus-ide.org/) | [Lazarus 文档](https://wiki.lazarus.freepascal.org/) | [Lazarus 论坛](https://forum.lazarus.freepascal.org/)

### 操作步骤

#### ① 进入 Lazarus 源码目录

根据您在第 2 步中解压得到的实际目录名，进入 Lazarus 源码根目录：

```bash
cd /path/to/lazarus   # 请替换为实际的 Lazarus 源码目录路径
```

> 例如，如果您在 `~/downloads/` 下解压得到 `lazarus-4.8`，则执行 `cd ~/downloads/lazarus-4.8`。

#### ② 编译 `lazbuild`

```bash
make clean
make lazbuild
```

> 此过程约需 3~5 分钟，若内存较小可添加 `-j1` 限制并行数：`make lazbuild -j1`。

#### ③ 复制 `lazbuild` 到系统路径

```bash
cp lazbuild /usr/local/bin/
```

#### ④ 配置 `lazbuild` 的 Lazarus 目录（关键步骤）

`lazbuild` 需要知道 Lazarus 源码的位置（即包含 `lcl`、`components` 等子目录的根目录），否则后续使用时可能报错 `Invalid Lazarus directory ""`。

**推荐做法**：

- **将 Lazarus 源码移动到固定位置**（例如 `/usr/local/share/lazarus`）：
  ```bash
  # 首先确认当前目录是 Lazarus 源码根目录（包含 lcl、components 等）
  # 假设当前在 /path/to/lazarus
  mkdir -p /usr/local/share
  rm -rf /usr/local/share/lazarus          # 如果已存在则先删除
  mv . /usr/local/share/lazarus            # 将当前目录整体移动
  # 注意：移动后当前目录会消失，需要切换到新位置
  cd /usr/local/share/lazarus
  ```

- **设置环境变量 `LAZARUS_DIR`**（永久生效）：
  ```bash
  echo 'export LAZARUS_DIR=/usr/local/share/lazarus' >> ~/.bashrc
  source ~/.bashrc
  ```
  这样以后直接运行 `lazbuild` 就会自动识别该目录。

- **或者在每次调用时使用 `--lazarusdir` 参数**（临时方案）：
  ```bash
  lazbuild --lazarusdir=/usr/local/share/lazarus 项目文件.lpi
  ```

> **为什么要这么做？**
> `lazbuild` 编译时记录的是编译时的临时路径，但该路径在解压后可能被删除或移动。将 Lazarus 源码固定到标准目录并配置环境变量，可以保证任何时候都能找到所需的 LCL 单元，避免编译失败。

#### ⑤ 验证

```bash
lazbuild --version
```

应显示 Lazarus 4.8 版本信息。同时确认 `lazbuild` 能找到 Lazarus 目录（可尝试不带参数运行 `lazbuild`，应显示帮助信息，无报错）。

---


## 🧪 最终验证

```bash
fpc -iV
lazbuild --version
```

一切正常，则环境已就绪。

---


## 📌 常见问题与解决

| 问题 | 原因 | 解决办法 |
| ---- | ---- | -------- |
| `fpc -iV` 报 `ppcloongarch64 can't be executed` | 未创建软链接 | 执行第二步第③条 |
| `make lazbuild` 报 `gtk/gtk.h: No such file` | 图形库未安装 | 重新执行第一步，安装 `gtk2-devel` |
| 找不到 `DB`、`Variants` 等单元 | `fpc.cfg` 缺少子目录 | 重新执行第二步第⑤条，确保所有子目录添加 |
| `unzip: command not found` | 未安装 unzip | 安装 `unzip`（yum/apt install unzip）|
| 解压后目录名不匹配 | 压缩包内顶层目录名不同 | 使用 `ls` 查看实际目录名，再 `cd` 进入 |
| `lazbuild` 报 `Invalid Lazarus directory ""` | 未设置 Lazarus 路径 | 执行第三步第④条，设置 `LAZARUS_DIR` |

> 更多问题可查阅 [FPC/Lazarus 社区论坛](https://forum.lazarus.freepascal.org/)。

---


## 💡 通用性说明

- **不同架构**：只需将 `ARCH` 改为对应名称（如 `x86_64`、`arm`、`aarch64`、`riscv64`），并下载对应的 FPC 包。Lazarus 源码通用。
- **不同发行版**：调整包管理器命令（`yum`/`apt`/`pacman`）即可，后续步骤完全相同。
- **离线编译**：所有资源均来自本地压缩包，无需联网。

**掌握这套流程，您可以在任何 Linux 平台上快速构建 `lazbuild`，实现 Lazarus 项目的命令行自动化编译。**

---


## 🚀 使用 `lazbuild` 编译项目

编译成功后，您可以：

```bash
lazbuild /path/to/your_project.lpi
```

或批量处理：

```bash
for lpi in *.lpi; do lazbuild --build-mode=Release "$lpi"; done
```

更多用法请参考文档中的“批处理化”章节。


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