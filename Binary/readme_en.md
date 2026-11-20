# 📦 Binary — LingoFuse's ammunition depot

> Chinese version: [readme.md](readme.md)

Based on your requirements, here is a `README.md` written specifically for the `Binary` directory of the LingoFuse project. It removes every reference to zAPI and repositions the document as a description of LingoFuse's runtime dependencies, keeping the tone light and humorous while remaining professional and clear.

---

> This is where all the **dynamic libraries (DLL / SO / DYLIB)** that LingoFuse needs to run live.
> **Download, extract, drop into PATH, done.**
> No compiling, no configuring — **easier than installing a chat app**.

---

## 📌 In one line

This directory holds every binary that LingoFuse's core runtime, IPC engine and memory allocator need.
**Whether you are on Windows, Linux or macOS, the right library is here.**

---

## 📦 File list

### 🔥 The LingoFuse core library — the main engine of the neural-communication foundation

| File name | Platform | Description |
|--------|------|------|
| `LingoFuse64.dll` | Windows 64-bit | LingoFuse core library (Release) |
| `LingoFuse32.dll` | Windows 32-bit | LingoFuse core library (Release) |
| `liblingofuse.so` | Linux / BSD | LingoFuse core library (dynamic link) |
| `liblingofuse.dylib` | macOS | LingoFuse core library (dynamic link) |

> This library handles all cross-language RPC scheduling, service discovery, load balancing and the "brain work" of agent communication.
> **Without it, LingoFuse is just a pile of paper.**

---

### ⚡ The zIPC process-communication engine — same-machine transfer at light speed

| File name | Platform | Description |
|--------|------|------|
| `z_ipc_64.dll` | Windows 64-bit | zIPC Release build (for production) |
| `z_ipc_32.dll` | Windows 32-bit | zIPC Release build (for production) |
| `z_ipc_64d.dll` | Windows 64-bit | zIPC Debug build (for development and debugging) |
| `z_ipc_32d.dll` | Windows 32-bit | zIPC Debug build (for development and debugging) |
| `libz_ipc.so` | Linux / BSD | zIPC dynamic library |
| `libz_ipc.dylib` | macOS | zIPC dynamic library |

zIPC is LingoFuse's **same-machine IPC engine**, built on shared memory plus message queues, with **latency < 1 ms and throughput of 10,000+ requests/second**.
**LingoFuse's large-scale production traffic is carried by it.**

> ⚠️ The Debug builds (with a `d` suffix) are for development and debugging only — **use the Release builds in production**, otherwise performance suffers.

---

### 🧠 The mimalloc memory allocator — memory management as fast as lightning

| File name | Platform | Description |
|--------|------|------|
| `mimalloc64.dll` | Windows 64-bit | mimalloc core library |
| `mimalloc32.dll` | Windows 32-bit | mimalloc core library |
| `mimalloc-redirect.dll` | Windows 64-bit | Redirect library (switches `malloc` to mimalloc) |
| `mimalloc-redirect32.dll` | Windows 32-bit | Redirect library (32-bit) |
| `libmimalloc.so` | Linux | Build it yourself (or use a system package) |
| `libmimalloc.dylib` | macOS | Build it yourself (or use a system package) |

mimalloc is Microsoft's open-source high-performance allocator — **low fragmentation, high concurrency** — and LingoFuse relies on it for maximum memory-management efficiency.
> The redirect library is **optional**; you only need it if you want third-party libraries' `malloc`/`new` routed through mimalloc too.

---

### 🛠️ Visual C++ Redistributable (required on Windows)

| File name | Description |
|--------|------|
| `vc_redist.x64.exe` | Visual C++ 2022 Redistributable (64-bit) |
| `vc_redist.x86.exe` | Visual C++ 2022 Redistributable (32-bit) |

> **⚠️ Important**: every Windows dynamic library here depends on the VC++ runtime.
> If it is not installed, double-click the matching `vc_redist.x*.exe`, **otherwise you get "module not found"**.
> Download and install the version for your architecture from Microsoft:

- [VC++ Redistributable for Visual Studio 2022 (x86/x64)](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170)

---

### 📄 Documentation files

| File name | Description |
|--------|------|
| `mimalloc4p.md` | Guide to the mimalloc4p Pascal binding |
| `Z.IPC.API.md` | Reference for the low-level zIPC C API |
| `Z.IPC.Helper.md` | Guide to the object-oriented zIPC Pascal wrapper |

---

## 🚀 How to use it

### Option one: configure the system PATH (recommended — do it once, forget it)

Add the **full path** of this directory to the system `PATH` environment variable:

1. Open **System Properties** → **Advanced** → **Environment Variables**
2. Find `Path` under **System variables** or **User variables** and click **Edit**
3. Click **New** and paste the full path of this directory (for example `D:\LingoFuse\Binary`)
4. Click **OK** to save, then **restart the command-line window** for it to take effect

Once configured, any LingoFuse program finds these DLLs automatically — **no need to copy them into every project directory**.

### Option two: copy them into the project directory

Simply copy the DLLs you need into the same directory as the executable.
Mind the bitness: **64-bit applications use `*64.dll`, 32-bit applications use `*32.dll`**.

---

## ❓ Frequently asked questions

**Q: At runtime the program says "the specified module could not be found"?**

A: 99% of the time it is one of these:
1. The VC++ Redistributable is not installed (double-click `vc_redist.x64.exe` to install it)
2. The DLL is neither on `PATH` nor in the program directory
3. Bitness mismatch (a 64-bit program loading a 32-bit DLL)

**Q: What is the difference between `z_ipc_64d.dll` and `z_ipc_64.dll`?**

A: The one with `d` is the Debug build, with debug symbols and extra checks — **for development and debugging only**. Use the Release build (no `d`) in production.

**Q: Is mimalloc-redirect.dll required?**

A: **No.** LingoFuse and zIPC call mimalloc directly and need no redirection. The redirect library matters only when you want third-party libraries (OpenCV, for example) to benefit from mimalloc as well.

**Q: There is no prebuilt mimalloc for Linux?**

A: Correct. On Linux, install mimalloc through your package manager (for example `apt install libmimalloc-dev`) or build it from source. LingoFuse can also use the default `malloc` on Linux and still performs excellently.

---

## 🔗 Related links

| Project | Repository |
|------|----------|
| **LingoFuse** | https://github.com/PassByYou888/LingoFuse |
| **zIPC** | https://github.com/PassByYou888/zIPC |
| **mimalloc4p** | https://github.com/PassByYou888/mimalloc4p |
| **mimalloc (upstream)** | https://github.com/microsoft/mimalloc |

---

**Now put the libraries in place and go write your agent application.** 🚀
