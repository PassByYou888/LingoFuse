# LingoFuse Core Dynamic Library Build Guide

> Chinese version: [CONTRIBUTING.md](CONTRIBUTING.md)

> This document explains how to build the LingoFuse core dynamic library (`LingoFuse64.dll` / `LingoFuse32.dll` / `liblingofuse.so` / `liblingofuse.dylib`) from source.
>
> **Build status**: the Windows build path is verified; the Linux / macOS build paths are **not systematically verified** — the include directives in `src/*.pas` and the `OtherUnitFiles` entries in the `.lpi` use Windows-style backslashes, which FPC does not resolve on Linux / macOS, so you must modify them yourself to build there. See §5.
>
> **Scope of this document**: only the build of the `src/` directory (the core dynamic library). Building the individual language bindings (Python / C# / Rust / Go / Java / …) is covered by each language's own README.

---

## Contents

1. [Dependencies and submodules](#1-dependencies-and-submodules)
2. [Build environment](#2-build-environment)
3. [Windows build (verified)](#3-windows-build-verified)
4. [Build outputs](#4-build-outputs)
5. [Linux / macOS build (unverified)](#5-linux--macos-build-unverified)
6. [Build files](#6-build-files)
7. [Version pinning and PPU consistency](#7-version-pinning-and-ppu-consistency)
8. [Troubleshooting](#8-troubleshooting)
9. [Related documents](#9-related-documents)

---

## 1. Dependencies and submodules

### 1.1 The only submodule: `pascal/zNetV2`

Building the LingoFuse core dynamic library **depends on exactly one git submodule**:

```
pascal/zNetV2
```

`.gitmodules` registers nothing else. `git clone --recursive` pulls it in, so nothing is missing.

**What zNetV2 provides** (these are source files inside zNetV2, not separate submodules):

- the C4 service mesh (`Z.Net.C4.pas`)
- dual tunnels (`Z.Net.DoubleTunnelIO*.pas`)
- StableIO (`Z.Net.imp_StableIO.inc`)
- the HPC thread pool (`Z.Net.imp_HPC_*.inc`)
- the command bridge (`Z.Net.imp_CommandInstance.inc`)
- the handle pool / soft sync / zero-copy / serialization family (`Z.Core.*.inc`, `Z.MemoryStream.pas`, `Z.DFE.pas` and so on)
- the IPC engine (`Z.IPC.API.pas` / `Z.IPC.Helper.pas`; binaries in `pascal/zNetV2/binary/`)
- memory-allocator bindings (`mimalloc4p.pas` / `jemalloc4p.pas` / `tcmalloc4p.pas`; binaries in `pascal/zNetV2/binary/`)

**Historical note**: older documents may describe zIPC or mimalloc4p as "standalone submodules" — **that wording is out of date**. Their capabilities now live inside `pascal/zNetV2` and no longer need separate submodule registration. If you follow the old documents and look for commands like `git submodule update --init zIPC`, you will not find them — those entries do not exist in `.gitmodules`.

### 1.2 What you do not need

Building the core dynamic library **does not require**:

- a C/C++ compiler (the Pascal compiler has built-in C interop)
- CMake / Ninja / Meson
- Python / Node.js / .NET / JDK
- Docker

All you need is the **FPC + Lazarus toolchain** (see §2).

---

## 2. Build environment

### 2.1 Required components

| Component | Version | Notes |
|------|:----:|------|
| **FPC (Free Pascal Compiler)** | **3.3.1** | Pinned, see §7 |
| **Lazarus** | a version matching FPC 3.3.1 | Provides the `lazbuild` CLI and the IDE |
| **Operating system** | Windows 10+ x64 | Linux / macOS, see §5 |

**Not needed**: Visual Studio, MinGW, CMake, Python.

### 2.2 Obtaining FPC 3.3.1 + Lazarus

FPC 3.3.1 is a **development build** (a stable snapshot of the trunk branch), not an official release. Ways to get it:

**Option A: use the environment package provided by the repository (recommended)**

See [`FPC_3.3.1_Package_Info.md`](FPC_3.3.1_Package_Info_en.md) — it records the exact source, version information and download guidance for the FPC 3.3.1 environment package.

**Option B: get it from the official Lazarus installer**

Some Lazarus distributions bundle FPC 3.3.1. After installing, confirm:

```bash
fpc -iV
# expected output: 3.3.1
```

**Option C: build it from FPC source**

If neither of the above works, you can build 3.3.1 from FPC's trunk branch. That path is expensive and not recommended — unless you have a clear reason to build it yourself.

### 2.3 Verifying the environment

```bash
# FPC version
fpc -iV
# expected: 3.3.1

# lazbuild version
lazbuild --version
# expected: prints the Lazarus version

# whether the submodule has been pulled
ls pascal/zNetV2/source/Z.Net.C4.pas
# expected: the file exists
```

### 2.4 Switching the FPC version inside the Lazarus IDE

If Lazarus is already installed but its FPC version is not 3.3.1, see [`Lazarus_Change_FPC.md`](Lazarus_Change_FPC_en.md) — it explains how to switch FPC versions in Lazarus.

---

## 3. Windows build (verified)

### 3.1 One-command build (recommended)

```powershell
cd src
.\build.bat
```

`build.bat` will:

1. check that FPC / lazbuild are available;
2. call `lazbuild LingoFuse.lpi`;
3. write the output to `../Binary/` (or whatever output directory the `.lpi` configures).

**Expected output**: `Build succeeded` or a similar success message, with `LingoFuse64.dll` appearing in the `Binary/` directory.

### 3.2 Manual build (lazbuild CLI)

```powershell
cd src
lazbuild LingoFuse.lpi
```

`lazbuild` reads the compile configuration in `LingoFuse.lpi` (unit search paths, compile options, output directory) and builds automatically.

**Details** are in [`CONTRIBUTING_lazbuild.md`](CONTRIBUTING_lazbuild_en.md) — it covers the full lazbuild argument set, the manual LoongArch64 build steps, and troubleshooting for common lazbuild errors.

### 3.3 Building with the Lazarus IDE

1. Open `src/LingoFuse.lpi` in Lazarus;
2. use the `Run` → `Build` menu (or press `Shift+F9`);
3. the output goes to the directory configured in the `.lpi`.

**Note**: the FPC version used by the Lazarus IDE must match the command line (both 3.3.1), otherwise you get `PPU version mismatch` (see §7).

### 3.4 Verifying the build output

```powershell
# confirm the DLL exists
Test-Path ..\Binary\LingoFuse64.dll

# check the exported symbols with dumpbin (bundled with VS) or objdump
dumpbin /exports ..\Binary\LingoFuse64.dll | Select-String "LF_"
# expected: at least 59 LF_* exports
```

### 3.5 Self-test after building

To check whether the DLL actually works, use the C++ test program in `cpp/test/`:

```powershell
cd ..\cpp\test
cmake . && make
.\test_lingofuse.exe
```

Expected: all 82 functional tests PASS.

**If the tests fail**, check first:

1. whether `Binary/` contains the complete dependencies (`z_ipc_64.dll` / `mimalloc64.dll`);
2. whether the DLL is loaded from the right path (see each language README for `LF_LoadLibrary`'s search order);
3. whether an older DLL is being loaded first (check `PATH` for another `LingoFuse64.dll`).

---

## 4. Build outputs

### 4.1 Windows

| File | Description |
|------|------|
| `Binary/LingoFuse64.dll` | 64-bit core dynamic library |
| `Binary/LingoFuse32.dll` | 32-bit core dynamic library (if a 32-bit target was built) |

**Dependencies** (must sit next to the DLL, or be on `PATH`):

- `z_ipc_64.dll` / `z_ipc_32.dll` (IPC engine, from `pascal/zNetV2/binary/`)
- `mimalloc64.dll` / `mimalloc32.dll` (memory allocator, optional but recommended)
- `mimalloc-redirect.dll` / `mimalloc-redirect32.dll` (redirect library, optional)

Prebuilt copies of these dependencies already exist in the repository's `Binary/` directory; you do not need to rebuild them when building the core DLL.

### 4.2 Linux / macOS

| File | Description |
|------|------|
| `liblingofuse.so` | Linux / BSD core dynamic library |
| `liblingofuse.dylib` | macOS core dynamic library |

**Current status**: the Linux / macOS build paths are **not systematically verified** — see §5.

### 4.3 Auxiliary outputs

The build generates the following under `src/`:

- `*.o` (object files)
- `*.ppu` (compiled units)
- `*.compiled` (Lazarus compile state)

These are intermediate files and can safely be deleted (`lazbuild` regenerates them).

---

## 5. Linux / macOS build (unverified)

### 5.1 Current status

The **Linux / macOS build paths are not systematically verified**. The reason is not "theoretically impossible", but:

1. **The include directives in `src/*.pas` use Windows-style backslashes**:
   ```pascal
   {$I ..\pascal\zNetV2\source\Z.Define.inc}
   ```
   FPC on Linux / macOS does not resolve backslash paths and reports "file not found".

2. **`OtherUnitFiles` in `LingoFuse.lpi` also uses backslashes**:
   ```
   ..\pascal\zNetV2\source
   ```
   likewise not resolved by FPC on Linux / macOS.

3. **Windows API dependencies in `cross_call.zig` / `async_call.zig`** (this belongs to the Zig binding rather than the core DLL, but it affects cross-platform verification): `Sleep` / `GetTickCount64` need to be replaced with POSIX `nanosleep` / `clock_gettime`.

4. **The prebuilt artifacts in the repository are Windows-only**: `Binary/` contains only `LingoFuse64.dll` / `LingoFuse32.dll`, with no `.so` / `.dylib`. The Release `pre_build` tag likewise carries only Windows artifacts.

5. **The build scripts are mainly PowerShell / .bat**: `build.bat` is a Windows batch file, and Linux / macOS need a matching `.sh` (there is none at present).

**Conclusion**: to build the core dynamic library on Linux / macOS you must **modify the source and the build configuration yourself**. Guidance follows.

### 5.2 Modification guide

**Step 1: change the include paths to forward slashes**

Change every `{$I ..\...}` under `src/` to `{$I ../...}`. Which files and lines are involved is for you to grep:

```bash
grep -rn '{\$I \.\.\\' src/
```

**Step 2: change `OtherUnitFiles` in the `.lpi` to forward slashes**

Edit `src/LingoFuse.lpi` and change every `..\` to `../`.

**Step 3: switch to an FPC command-line build**

`lazbuild` works on Linux, but the paths in the `.lpi` must be fixed first. Alternatively use the `fpc` command line directly:

```bash
cd src
fpc -Fu../pascal/zNetV2/source -Fu../pascal/zNetV2/source/sec \
    -FE../Binary -o../Binary/liblingofuse.so \
    -Mdelphi -Sh -O3 \
    LingoFuse.lpr
```

**Note**: the command above is **illustrative**; the real compile options are whatever `LingoFuse.lpi` configures. You must convert each of `CustomOptions` / `OtherUnitFiles` / `IncludeFiles` in the `.lpi` into the corresponding `fpc` command-line argument.

**Step 4: handle platform conditional compilation**

Go through the platform conditionals in `src/` (`{$IFDEF MSWINDOWS}` / `{$IFDEF LINUX}` and so on) one by one. If a platform branch lacks an implementation, fill it in.

**Step 5: self-test**

Once `liblingofuse.so` / `liblingofuse.dylib` is built, verify it with the C++ test program in `cpp/test/` (that program also needs to be compiled for the matching platform).

**Step 6: report back**

If you succeed in building and passing the tests on Linux / macOS, a PR or Issue with your changes is welcome — it helps move that platform from "unverified" to "verified".

### 5.3 Why this is not done yet

**It is not impossible — it simply is not a high priority right now.** LingoFuse's main development and verification environment is Windows; Linux / macOS support is in a "theoretically feasible, user must verify" state. If you really need to run on Linux / macOS, follow the guidance in §5.2 — the work is modest (mostly path replacement).

---

## 6. Build files

Build-related files in the `src/` directory:

| File | Purpose |
|------|------|
| `build.bat` | Windows one-command build script (calls `lazbuild`) |
| `LingoFuse.lpi` | Lazarus project file (compile configuration, unit search paths, output directory) |
| `LingoFuse.lpr` | Project main program file (the `library` block defining exported symbols) |
| `Z.LingoFuse_Core.pas` | Core engine implementation (App / Engine / Data / handle pool / sequenced thread pool) |
| `Z.LingoFuse_Export.pas` | The C ABI export layer (implementations of the 59 `LF_*` functions) |
| `Z.Net.C4.LingoFuse.pas` | The C4 distributed layer (service / client management, three addressing schemes, load balancing) |
| `Z.LingoFuse_System_ProcessID.inc` | Process-ID helper (referenced by `Z.LingoFuse_Export.pas`) |

**Dependency graph**:

```
LingoFuse.lpr
  └── Z.LingoFuse_Export.pas
        ├── Z.LingoFuse_Core.pas
        │     └── Z.Net.C4.LingoFuse.pas
        │           └── pascal/zNetV2/source/Z.Net.C4.pas and so on
        └── Z.LingoFuse_System_ProcessID.inc
```

**Things to watch when modifying the code**:

- **Do not change the signatures of the 59 exported functions in `Z.LingoFuse_Export.pas`** — that is the cross-language ABI contract, and changing it breaks every language binding.
- **Do not change the wire format** (UTF-8 + NUL, little-endian, compact JSON with no `\uXXXX`) — that is the basis of byte-level interoperability across languages.
- **Do not change the handle ownership rules** (synchronous family owned by the caller, asynchronous family owned by the framework) — that is the shared contract of every language binding.
- After any change you must run the C++ tests in `cpp/test/` to confirm the contract is not broken.

---

## 7. Version pinning and PPU consistency

### 7.1 Why FPC 3.3.1 is pinned

FPC `.ppu` (compiled unit) files are **tightly bound to the compiler version**. If build machine A compiles `Z.Net.C4.pas` with FPC 3.3.1 and build machine B compiles `LingoFuse.lpr` with FPC 3.3.0, linking fails with:

```
PPU version mismatch
```

That is not a "warning" — it is a **hard error**: linking fails.

### 7.2 Pinning rules

- **Every build machine must use the same FPC 3.3.1 build source.** Not "the same version number" but "the same build source" — a 3.3.1 compiled from one trunk commit and a 3.3.1 compiled from another may have incompatible PPUs.
- If you get the environment package from [`FPC_3.3.1_Package_Info.md`](FPC_3.3.1_Package_Info_en.md), use the FPC inside that package; it guarantees consistency.
- If you build FPC 3.3.1 from source yourself, record the trunk commit you used and make sure every build machine uses that same commit.

### 7.3 What to do about a PPU mismatch

1. Confirm `fpc -iV` prints `3.3.1` on every build machine.
2. Confirm every build machine uses the **same** FPC 3.3.1 build source (not merely "all 3.3.1").
3. Clean every `.ppu` / `.o` / `.compiled` and rebuild:
   ```powershell
   cd src
   del *.ppu, *.o, *.compiled
   lazbuild LingoFuse.lpi
   ```
4. If it still fails, check for leftover `.ppu` files under `pascal/zNetV2/source/` — those were compiled with a different FPC version earlier and must be cleaned too.

### 7.4 Switching FPC versions

If you need to switch FPC versions on the same machine (say from 3.3.1 to 3.3.0 for compatibility testing), see [`Lazarus_Change_FPC.md`](Lazarus_Change_FPC_en.md).

**Note**: after a version switch you must **clean everything** before building, otherwise leftover `.ppu` files from the old version cause a PPU mismatch.

---

## 8. Troubleshooting

### 8.1 `Can't find unit Z.Core`

**Cause**: `OtherUnitFiles` in `LingoFuse.lpi` does not include `pascal/zNetV2/source`, or the submodule was not pulled.

**Fix**:

```bash
# confirm the submodule is pulled
git submodule update --init --recursive pascal/zNetV2

# confirm the source file exists
ls pascal/zNetV2/source/Z.Core.pas
```

If the file exists but `lazbuild` still cannot find it, check whether `OtherUnitFiles` in `LingoFuse.lpi` contains `..\pascal\zNetV2\source`.

### 8.2 `PPU version mismatch`

See §7.3.

### 8.3 `Cannot find LingoFuse64.dll` (during build)

**Cause**: the build itself does not need `LingoFuse64.dll` (it is the output). This error usually appears in the **post-build test phase** — the C++ test program cannot find the DLL that was just built.

**Fix**: copy `Binary/LingoFuse64.dll` next to the test program, or add `Binary/` to `PATH`.

### 8.4 `build.bat` reports "lazbuild not found"

**Cause**: `lazbuild` is not on `PATH`.

**Fix**: add the Lazarus installation directory (the one containing `lazbuild.exe`) to `PATH`. Usually:

```
C:\Lazarus\
C:\lazarus\
```

The exact path depends on where you installed Lazarus.

### 8.5 The build succeeds but the C++ tests fail

**Check in this order**:

1. **Is the right DLL loaded**: check whether another `LingoFuse64.dll` on `PATH` is being loaded first.
2. **Are all dependency DLLs present**: are `z_ipc_64.dll` / `mimalloc64.dll` in the same directory as `LingoFuse64.dll`.
3. **Are the exports complete**: use `dumpbin /exports` to check for the 59 `LF_*` symbols.
4. **Is it an old DLL**: if you built before, `Binary/` may still hold an old DLL that was not overwritten — delete it and rebuild.

### 8.6 `build.bat` does not work on Linux

**Cause**: `build.bat` is a Windows batch script.

**Fix**: see §5.2 — on Linux / macOS you must fix the paths yourself and switch to the `fpc` or `lazbuild` command line.

### 8.7 Submodule pull fails

**Cause**: network problems (`pascal/zNetV2` is a separate repository).

**Fix**:

```bash
# pull manually
git submodule update --init --recursive pascal/zNetV2

# if it still fails, check whether the URL in .gitmodules is reachable
cat .gitmodules
```

---

## 9. Related documents

| Document | Content |
|------|------|
| [`CONTRIBUTING_lazbuild.md`](CONTRIBUTING_lazbuild_en.md) | Full lazbuild CLI arguments, manual LoongArch64 build steps, lazbuild error troubleshooting |
| [`FPC_3.3.1_Package_Info.md`](FPC_3.3.1_Package_Info_en.md) | Exact source, version information and download guidance for the FPC 3.3.1 environment package |
| [`Lazarus_Change_FPC.md`](Lazarus_Change_FPC_en.md) | Steps for switching FPC versions in Lazarus |
| [`../README.md`](../readme_en.md) | Repository overview: positioning, language support, quick start, test system |
| [`../Z.LingoFuse.md`](../Z.LingoFuse_en.md) | Internal-mechanism knowledge base (thread model, callback context, handle ownership, P2P identity) |
| [`../cpp/LingoFuse_Cpp_Knowledge_Base.md`](../cpp/LingoFuse_Cpp_Knowledge_Base_en.md) | C++ binding knowledge base (used to verify build outputs) |
| [`../test/LingoFuse_Functional_Test_Guide.md`](../test/LingoFuse_Functional_Test_Guide_en.md) | Functional test guide (82 items) |
| [`../test/LingoFuse_Stress_Test_Guide.md`](../test/LingoFuse_Stress_Test_Guide_en.md) | Stress test guide |

---

## 10. Build status and CI

### 10.1 Current build status

| Platform | Status | Notes |
|------|:----:|------|
| **Windows x64** | ✅ Verified | One-command build via `build.bat` / `lazbuild`; the `LingoFuse64.dll` output can be verified with the C++ tests |
| Windows x86 | ⏳ Unverified | Theoretically feasible; needs a 32-bit FPC toolchain |
| **Linux x64** | ⏳ Unverified | Requires fixing the include paths and the `.lpi` (see §5.2) |
| **macOS x64 / arm64** | ⏳ Unverified | Same as Linux |

### 10.2 CI status

**There is currently no GitHub Actions workflow in the repository root.** The only workflow in the tree is `erlang/.github/workflows/ci.yml` (covering the Erlang binding only).

**Build verification is done by running locally**: build locally following §3, and verify the output following the self-test steps in §3.5. If you want builds in CI, you must add a workflow yourself — but note that obtaining the pinned FPC 3.3.1 (§7) in a CI environment needs to be solved separately.

---

## License

Same as the main repository; see `LICENSE` in the repository root.
