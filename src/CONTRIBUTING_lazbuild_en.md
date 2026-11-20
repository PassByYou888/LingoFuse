# Three steps to build lazbuild (manual walkthrough · tuned for loongarch64 + lazarus_4_8)

> Chinese version: [CONTRIBUTING_lazbuild.md](CONTRIBUTING_lazbuild.md)

### Compiling the Lazarus command-line tools offline on LoongArch64 Linux

---

> **📌 This guide is tailored to your files**
>
> - FPC archive: `fpc-3.3.1.loongarch64-linux.tar.gz` (native Loongson build)
> - Lazarus source package: `lazarus_4_8.zip` (packaged from the Git tag `lazarus_4_8`)
> - Operating system: Loongnix / any RHEL-family Linux / Debian-Ubuntu
> - **Every step is performed manually**, each with a detailed explanation, so you fully understand what is happening.
> - **Portability**: change only the architecture name and the archive names and the same flow works on other Linux architectures (x86_64, ARM, RISC-V and so on).
> - **About paths**: the examples below assume your archives are in `~/downloads/`. Replace that with your real path (for example `/home/yourname/downloads/` or `/root/downloads/`).
> - A full-system FPC 3.3.1 package plus the lazarus 4.8 branch source is roughly 10 GB; Baidu Netdisk: [https://pan.baidu.com/s/1wnlNAjCv3-KaURp3kOaZzw](https://pan.baidu.com/s/1wnlNAjCv3-KaURp3kOaZzw), extraction code: vl5t
>
> **Author: Lao Zhang, qq600585**

---


## 📦 Preparation

### 1. Confirm where the files are

Put the following two files in one directory, e.g. `~/downloads/` (adjust to your setup):

- `fpc-3.3.1.loongarch64-linux.tar.gz`
- `lazarus_4_8.zip`

> For the complete list of platforms covered by the prebuilt FPC 3.3.1 package, see [`FPC_3.3.1_Package_Info.md`](./FPC_3.3.1_Package_Info.md) in the same directory.

### 2. Extract the Lazarus source package (`.zip`)

On Linux `.zip` files are extracted with the `unzip` command, which nearly every distribution ships by default. If it is missing, install it with your package manager:

```bash
# RHEL / CentOS / Loongnix
yum install -y unzip

# Debian / Ubuntu
apt install -y unzip
```

**Extraction command**:

```bash
cd ~/downloads
unzip lazarus_4_8.zip
```

Extraction yields a directory (usually named `lazarus` or `lazarus-4.8`). Enter it and confirm it contains subdirectories such as `lcl` and `components` — that is the Lazarus source root.

> **About the FPC archive**: `fpc-3.3.1.loongarch64-linux.tar.gz` is a standard `.tar.gz`, so the `tar` command built into Linux extracts it without extra tools. The command is in step two.

---

### 3. Determine the architecture

This machine is `loongarch64`; confirmed.

---


## 🔧 Step one: install the system build dependencies

**Purpose**: install the basic development tools and graphics libraries Lazarus needs to compile.

Run as root:

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

> **Why are these needed?**
>
> - `make`, `gcc`, `binutils`: essential for compiling.
> - `gtk2-devel`, `cairo-devel`: dependencies of the LCL graphics library. Even when you only build `lazbuild` (no GUI), some Makefiles still reference them, and missing packages cause link errors.
> - `cmake`: some build helper tools need it.

**Verify**:

```bash
make --version
gcc --version
cmake --version
```

All three should print normally.

---


## 📂 Step two: deploy FPC and configure the search paths

**Purpose**: install the FPC compiler itself, configure the unit search paths, and make sure later builds can find every `.ppu`.

> Official resources: [Free Pascal website](https://www.freepascal.org/) | [FPC documentation](https://www.freepascal.org/docs.html) | [FPC forum](https://forum.lazarus.freepascal.org/)

### Steps

#### ① Extract the FPC package

```bash
cd ~/downloads
FPC_TARBALL="fpc-3.3.1.loongarch64-linux.tar.gz"
mkdir -p /tmp/fpc_deploy
tar -xzf "$FPC_TARBALL" -C /tmp/fpc_deploy
```

After extraction, `/tmp/fpc_deploy` contains the three directories `bin/`, `lib/` and `share/`.

#### ② Copy the files into the system directories

```bash
\cp -rf /tmp/fpc_deploy/bin/* /usr/bin/
\cp -rf /tmp/fpc_deploy/lib/* /usr/lib/
\cp -rf /tmp/fpc_deploy/share/* /usr/share/
```

> The leading `\` on `cp` suppresses interactive overwrite prompts.

#### ③ Create a symlink for the backend compiler

The backend compiler on LoongArch is named `ppcloongarch64`:

```bash
ln -sf /usr/lib/fpc/3.3.1/ppcloongarch64 /usr/bin/ppcloongarch64
```

> This is what lets the `fpc` command reach the actual compiler.

#### ④ Generate a base `fpc.cfg`

```bash
/usr/bin/fpcmkcfg -d basepath=/usr -o /etc/fpc.cfg
```

If it reports that `fpcmkcfg` does not exist, check that step ② copied everything.

#### ⑤ Add every unit subdirectory to the configuration (key step)

> **Note**: do not copy absolute paths blindly — enter the directory first and look at the actual architecture name.

```bash
# Enter the FPC unit root
cd /usr/lib/fpc/3.3.1/units

# List the architecture directories and find your target (e.g. loongarch64-linux)
ls

# Enter the matching architecture directory (replace loongarch64-linux with the name you actually see)
cd loongarch64-linux   # replace with the real directory name

# Now add every subdirectory of the current directory to fpc.cfg
find . -type d -print | sed 's|^\.||' | while read dir; do
    [ -n "$dir" ] && echo "-Fu$(pwd)${dir}"
done >> /etc/fpc.cfg
```

> **Why do it this way?**
> Directory names differ per architecture (x86_64-linux, aarch64-linux and so on), so listing them with `ls` first avoids errors from hard-coded paths. `$(pwd)` resolves the current absolute path dynamically, guaranteeing the paths added are correct.

#### ⑥ Clean up the temporary files (optional)

```bash
rm -rf /tmp/fpc_deploy
```

### Verify FPC

```bash
fpc -iV          # should print 3.3.1
ppcloongarch64 -iV  # should print the same version
```

---


## 🛠️ Step three: build `lazbuild`

**Purpose**: build the `lazbuild` command-line tool from the Lazarus source, for automated builds later on.

> Official resources: [Lazarus IDE website](https://www.lazarus-ide.org/) | [Lazarus documentation](https://wiki.lazarus.freepascal.org/) | [Lazarus forum](https://forum.lazarus.freepascal.org/)

### Steps

#### ① Enter the Lazarus source directory

Use the directory name you actually got in step 2 and enter the Lazarus source root:

```bash
cd /path/to/lazarus   # replace with the real Lazarus source path
```

> For example, if extraction in `~/downloads/` produced `lazarus-4.8`, run `cd ~/downloads/lazarus-4.8`.

#### ② Build `lazbuild`

```bash
make clean
make lazbuild
```

> This takes about 3–5 minutes. On a machine with little memory, cap the parallelism: `make lazbuild -j1`.

#### ③ Copy `lazbuild` into the system path

```bash
cp lazbuild /usr/local/bin/
```

#### ④ Configure the Lazarus directory for `lazbuild` (key step)

`lazbuild` must know where the Lazarus source lives (the root holding `lcl`, `components` and so on); otherwise later runs may fail with `Invalid Lazarus directory ""`.

**Recommended approach**:

- **Move the Lazarus source to a fixed location** (for example `/usr/local/share/lazarus`):
  ```bash
  # First confirm the current directory is the Lazarus source root (contains lcl, components, ...)
  # Assume you are in /path/to/lazarus
  mkdir -p /usr/local/share
  rm -rf /usr/local/share/lazarus          # delete any existing copy first
  mv . /usr/local/share/lazarus            # move the whole current directory
  # Note: after the move the current directory is gone, so switch to the new location
  cd /usr/local/share/lazarus
  ```

- **Set the `LAZARUS_DIR` environment variable** (persistently):
  ```bash
  echo 'export LAZARUS_DIR=/usr/local/share/lazarus' >> ~/.bashrc
  source ~/.bashrc
  ```
  From then on `lazbuild` finds the directory automatically.

- **Or pass `--lazarusdir` on each call** (temporary workaround):
  ```bash
  lazbuild --lazarusdir=/usr/local/share/lazarus your-project.lpi
  ```

> **Why is this necessary?**
> `lazbuild` records the temporary path present at build time, and that path may be deleted or moved after extraction. Pinning the Lazarus source to a standard directory and setting the environment variable guarantees the LCL units can always be found, avoiding build failures.

#### ⑤ Verify

```bash
lazbuild --version
```

It should report Lazarus 4.8. Also confirm `lazbuild` can find the Lazarus directory (run `lazbuild` with no arguments — it should print help without errors).

---


## 🧪 Final verification

```bash
fpc -iV
lazbuild --version
```

If both are fine, the environment is ready.

---


## 📌 Common problems and fixes

| Problem | Cause | Fix |
| ---- | ---- | -------- |
| `fpc -iV` reports `ppcloongarch64 can't be executed` | Symlink missing | Do step two ③ |
| `make lazbuild` reports `gtk/gtk.h: No such file` | Graphics libraries missing | Rerun step one and install `gtk2-devel` |
| Units such as `DB` or `Variants` cannot be found | `fpc.cfg` lacks subdirectories | Rerun step two ⑤ and make sure every subdirectory was added |
| `unzip: command not found` | `unzip` not installed | Install it (`yum`/`apt install unzip`) |
| The extracted directory name does not match | The archive's top-level directory has a different name | Use `ls` to see the real name, then `cd` into it |
| `lazbuild` reports `Invalid Lazarus directory ""` | Lazarus path not configured | Do step three ④ and set `LAZARUS_DIR` |

> For more, see the [FPC/Lazarus community forum](https://forum.lazarus.freepascal.org/).

---


## 💡 Portability notes

- **Other architectures**: just replace `ARCH` with the right name (`x86_64`, `arm`, `aarch64`, `riscv64`) and download the matching FPC package. The Lazarus source is the same everywhere.
- **Other distributions**: adjust the package-manager commands (`yum`/`apt`/`pacman`); the rest of the steps are identical.
- **Offline builds**: every resource comes from the local archives, so no network access is needed.

**Master this flow and you can build `lazbuild` quickly on any Linux platform, giving Lazarus projects a command-line, automated build.**

---


## 🚀 Building projects with `lazbuild`

Once the build succeeds you can:

```bash
lazbuild /path/to/your_project.lpi
```

Or process a batch:

```bash
for lpi in *.lpi; do lazbuild --build-mode=Release "$lpi"; done
```

See the "batching" chapter of the documentation for more usage.


## 🔗 Related resources

### About this project

| Document | Description |
|------|------|
| [`CONTRIBUTING.md`](./CONTRIBUTING_en.md) | LingoFuse dynamic-library build guide (overview) |
| [`FPC_3.3.1_Package_Info.md`](./FPC_3.3.1_Package_Info.md) | Platform index for the prebuilt FPC packages |
| [Project root README](../readme_en.md) | LingoFuse project overview and language-binding index |
| [LingoFuse repository](https://github.com/PassByYou888/LingoFuse) | GitHub main repository |
| [zIPC submodule repository](https://github.com/PassByYou888/zIPC) | Process-communication component |

### Official resources

| Resource | Link |
|------|------|
| **Free Pascal website** | https://www.freepascal.org/ |
| **Free Pascal documentation** | https://www.freepascal.org/docs.html |
| **Lazarus IDE website** | https://www.lazarus-ide.org/ |
| **Lazarus Wiki** | https://wiki.lazarus.freepascal.org/ |
| **FPC/Lazarus community forum** | https://forum.lazarus.freepascal.org/ |
| **Lazarus source repository** | https://gitlab.com/freepascal.org/lazarus/lazarus |

### Other references

| Resource | Link |
|------|------|
| **mimalloc** (memory allocator) | https://github.com/microsoft/mimalloc |
| **LingoFuse documentation index** | see `readme.md` in the root |

---

> **Document author: Lao Zhang, qq600585**
> This guide was verified on a Loongson platform; feedback welcome.
