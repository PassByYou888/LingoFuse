# Switching Lazarus 4.8 to FPC 3.3.1 on Windows — complete tutorial

> Chinese version: [Lazarus_Change_FPC.md](Lazarus_Change_FPC.md)

> **When this applies**: Lazarus 4.8 ships with FPC 3.2.2, and you need to switch to FPC 3.3.1 to build LingoFuse and similar projects.
> **Core trick**: **first look at where the existing `fpc.cfg` lives, then imitate the same rule to generate the config file for the new FPC.**
> **Golden rule**: **every machine involved in the build (Windows dev box + Linux deployment box) must use FPC 3.3.1 prebuilt packages from the same build batch!**

---

## 🎯 Key trick: look at the old one before configuring the new one (works for any FPC version switch)

Before configuring any new FPC version, **find where the `fpc.cfg` you are currently using lives**. That file defines how FPC locates unit files (`.ppu`), libraries and so on.

**How**: run the following on the command line and the system tells you the exact location of the current `fpc.cfg`:

```cmd
fpc -vt 2>&1 | find "fpc.cfg"
```

Or, if you already know where Lazarus's bundled FPC lives, just look:

```cmd
dir /s /b C:\lazarus\fpc\*.cfg
```

With your actual environment as the example, the result is:

```
C:\lazarus>dir /s /b fpc.cfg
C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.cfg   ← config file of the old FPC
C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg   ← config file of the new FPC (to be generated)
```

**Key finding**: in Lazarus's FPC directory layout, `fpc.cfg` **sits directly under `bin\x86_64-win64\`**, next to `fpc.exe`.
**Conclusion**: the `fpc.cfg` you generate for the new FPC 3.3.1 belongs in exactly the same place — `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg`.

---

## ⚠️ Most important: the dev and deployment environments must use identical FPC versions!

> **FPC 3.3.1 is a development branch (main/trunk) and is updated almost daily as a Daily Snapshot.**
> Builds of 3.3.1 from different dates can have different internal RTL (runtime library) layouts.
> **If you compile on Windows with 3.3.1 from August 1 and link on Linux (LoongArch64) with 3.3.1 from August 17, you will see:**
> - `PPU version mismatch`
> - `Invalid PPU file format`
>
> **✅ The right approach:**
> **Every platform must use FPC 3.3.1 prebuilt packages from the same day (the same commit).**
> All packages in the **FPC 3.3.1 prebuilt package list** in the appendix below come from **the same build batch**, so they can be safely mixed across platforms.

---

## 📦 Your actual directory layout

```
C:\lazarus\                       ← Lazarus 4.8 installation root
├── fpc\
│   ├── 3.2.2\                    ← old FPC bundled with Lazarus (leave it alone)
│   │   └── bin\x86_64-win64\
│   │       ├── fpc.exe
│   │       └── fpc.cfg           ← old config file (reference template)
│   └── 3.3.1\                    ← the new FPC you installed manually
│       └── bin\x86_64-win64\
│           ├── fpc.exe
│           ├── fpcmkcfg.exe
│           └── fpc.cfg           ← ⭐ the config file to generate (put it here! next to fpc.exe)
├── components\
└── ...
```

---

## 🔧 Step one: confirm FPC 3.3.1 is installed correctly

Open a command prompt and run:
```cmd
C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.exe -iV
```
It should print `3.3.1`. If it says the file cannot be found, check whether the `x86_64-win64` part of the path matches your real directory (for 32-bit it is `i386-win32`).

---

## ⚙️ Step two: imitate the old rule and generate the new `fpc.cfg`

### 📌 Key: how the `basepath` rule works

The old FPC 3.2.2 `fpc.cfg` lives in `C:\lazarus\fpc\3.2.2\bin\x86_64-win64\`, and its `basepath` (the FPC root) is `C:\lazarus\fpc\3.2.2`.

The new FPC 3.3.1 `fpc.cfg` belongs in `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\`, and its `basepath` must be `C:\lazarus\fpc\3.3.1`.

**`fpcmkcfg` command format**:
```cmd
<fpc root>\bin\x86_64-win64\fpcmkcfg -d basepath=<fpc root> -o <output path>\fpc.cfg
```

**For your directories, run**:
```cmd
C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpcmkcfg -d basepath=C:\lazarus\fpc\3.3.1 -o C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg
```

### ✅ Verify the generated result

Open `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg` in Notepad and search for `-Fu`; you should see something like:
```
-FuC:\lazarus\fpc\3.3.1\lib\fpc\3.3.1\units\x86_64-win64\*
```
If the path contains `lib\fpc\3.3.1\units\x86_64-win64\`, the config was generated correctly.
**If the path is wrong (for example it points at the old 3.2.2 directory), check whether `basepath` is misspelled.**

---

## ⚙️ Step three: point Lazarus at the new FPC 3.3.1

1. **Close and restart Lazarus**.
2. Open the `Tools` → `Options` menu.
3. Expand `Environment` on the left and click **`Files`**.
4. On the right, set:

   | Option | Path |
   | :--- | :--- |
   | **`Compiler path`** | `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.exe` |
   | **`Compiler config file`** | `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.cfg` |

5. Click **`OK`** to save.

---

## ✅ Step four: verify the switch worked

1. Create a new project (`Project` → `New Project` → `Simple Program`).
2. Press `Ctrl+F9` to build, then look at the `Messages` window; it should show:
   ```
   Free Pascal Compiler version 3.3.1 ...
   ```
3. If it still shows 3.2.2, recheck the paths from step three.

---

## 🔁 Step five: rebuild Lazarus (recompile the IDE)

1. Open the `Tools` → `Configure “Build Lazarus”` menu.
2. Click **`Clean`** first to clear the old cache, then click **`Build`**.
3. Wait for the build to finish (3–10 minutes).

### 🛠 Build errors? Fix them as they come — don't panic!

**A few small errors during a Lazarus rebuild are completely normal**, especially when a daily-updated FPC 3.3.1 compiles an IDE source written against the stable FPC 3.2.2.
**Almost all of them fall into the categories below; patch them as you go, nothing to be alarmed about:**

| Error type | Typical message | Quick fix |
| :--- | :--- | :--- |
| **Unit not found** | `Fatal: Can't find unit xxx` | Add the missing path under `Project Options` → `Compiler Options` → `Other unit files` in the failing project, or build the dependency package first |
| **Unknown identifier** | `Error: Identifier not found "TMethod"` | Add the missing unit (such as `TypInfo`, `SysUtils`) to the `uses` clause |
| **Outdated compile option** | `Warning: Compiler option "..." is deprecated` | Remove or replace the option in `Project Options` → `Custom Options` |
| **Incompatible assembler syntax** | `Assembler syntax error` | Isolate old and new code with `{$IF FPC_FULLVERSION >= 30301}` |

**If there are too many errors to fix in one go**: uninstall some third-party packages first, complete the rebuild, then reinstall them (they will be recompiled with the new FPC).
**Remember**: these errors are not your fault — they are the normal friction between Lazarus source and FPC daily builds. Patch a couple of lines, keep building, and you will get through it.

---

## ✅ Step six: final verification

1. After a successful rebuild Lazarus restarts automatically.
2. `Help` → `About Lazarus`; confirm `FPC Version` shows `3.3.1`.
3. Create a new GUI application, drop a button on it and write:
   ```pascal
   ShowMessage('FPC: ' + {$I %FPC_VERSION%});
   ```
   Running it should pop up `FPC: 3.3.1`.

---

## 🚀 Step seven: keep versions in sync with the Linux target (LoongArch64)

| Environment | Check command | Expected output |
| :--- | :--- | :--- |
| **Windows** | `C:\lazarus\fpc\3.3.1\bin\x86_64-win64\fpc.exe -iW` | version date matches Linux |
| **Linux** | `fpc -iW` | version date matches Windows |

**Make sure the dates and commit IDs printed on both sides match exactly!** If they differ, re-download a matching package from the list below.

---

## 📚 Appendix: FPC 3.3.1 prebuilt package list (one version across platforms)

> **Download**: https://pan.baidu.com/s/1wnlNAjCv3-KaURp3kOaZzw
> **Extraction code**: `vl5t`
> **Total size**: about 10 GB
> **Note**: every package below comes from **the same build batch**, with identical version dates, so they can be safely mixed across platforms.

### General desktop/server platforms

| File name | Size | Description |
|--------|------|------|
| `fpc-3.3.1.x86_64-linux.tar.gz` | 102 MB | **x86_64 Linux native compiler** |
| `fpc-3.3.1.x86_64-win64.built.on.x86_64-linux.tar.gz` | 211 MB | **x86_64 Win64 cross compiler** (built on Linux) |
| `fpc-3.3.1.i386-win32.zip` | 91 MB | **i386 Win32 native compiler** (Windows installer package) |
| `fpc-3.3.1.aarch64-darwin.tar.gz` | 139 MB | **AArch64 macOS cross compiler** |

### 🐧 Linux distributions (focus: LoongArch64)

| File name | Size | Description |
|--------|------|------|
| `fpc-3.3.1.loongarch64-linux.tar.gz` | 218 MB | ⭐ **LoongArch64 Linux native compiler** (your deployment target) |
| `fpc-3.3.1.loongarch64-linux.built.on.x86_64-linux.tar.gz` | 123 MB | LoongArch64 Linux cross compiler (built on x86_64) |
| `fpc-3.3.1.aarch64-linux.built.on.x86_64-linux.tar.gz` | 99 MB | AArch64 Linux cross compiler |
| `fpc-3.3.1.riscv64-linux.built.on.x86_64-linux.tar.gz` | 111 MB | RISC-V 64 Linux cross compiler |
| `fpc-3.3.1.arm-linux.built.on.x86_64-linux-eabihf.tar.gz` | 98 MB | ARM Linux (hard float) cross compiler |
| `fpc-3.3.1.powerpc64-linux.built.on.x86_64-linux.tar.gz` | 105 MB | PowerPC64 Linux cross compiler |

### 📱 Embedded and mobile platforms (partial)

| File name | Description |
|--------|------|
| `fpc-3.3.1.aarch64-android.built.on.x86_64-linux.tar.gz` | AArch64 Android cross compiler |
| `fpc-3.3.1.arm-android.built.on.x86_64-linux.tar.gz` | ARM Android cross compiler |
| `fpc-3.3.1.arm-embedded.built.on.x86_64-linux.tar.gz` | ARM embedded cross compiler |

### 💾 Classic platforms

| File name | Description |
|--------|------|
| `fpc-3.3.1-WmCompact.msdos.zip` | MS-DOS (compact memory model) |
| `fpc-3.3.1.i386-freebsd.built.on.x86_64-linux.tar.gz` | i386 FreeBSD cross compiler |
| `fpc-3.3.1.m68k-amiga.built.on.x86_64-linux.tar.gz` | m68k Amiga cross compiler |

### 🧪 WebAssembly and the JVM

| File name | Description |
|--------|------|
| `fpc-3.3.1.wasm32-embedded.built.on.x86_64-linux.tar.gz` | WebAssembly embedded cross compiler |
| `fpc-3.3.1.jvm-java.built.on.x86_64-linux.tar.gz` | JVM (Java) cross compiler |

---

## ❗ Troubleshooting quick reference

| Problem | Cause | Solution |
| :--- | :--- | :--- |
| `fpc -iV` shows the old version | The PATH environment variable points at the old one | Force the full `fpc.exe` path in Lazarus `Tools` → `Options` |
| `Can't find unit system` | Wrong `-Fu` path in `fpc.cfg` | Check that `basepath` points at the root, then regenerate `fpc.cfg` |
| Windows and Linux PPUs are incompatible | FPC version dates differ between the machines | Download packages from the same batch in the list above so `fpc -iW` matches |
| Lazarus fails to start after the rebuild | Stale `.ppu` cache not cleared | Delete the `.ppu` and `.o` files under `C:\Users\yourname\AppData\Local\lazarus\`, then Clean + Build again |


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
