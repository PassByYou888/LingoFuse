# LingoFuse Ruby Binding — Build and Deployment Guide (Step One)

> Chinese version: [BUILD_AND_DEPLOY.md](BUILD_AND_DEPLOY.md)

> **What this document is**: it describes the build, deployment and verification flow for **replacing Fiddle with a self-written C extension**.
> Once completed, the Ruby side **no longer uses Fiddle at all** to load the LingoFuse DLL; every access to
> `LingoFuse64.dll` goes through the self-written `lingofuse_ext.so`.
>
> **Scope**: Windows 10 / 11 / Server 2019+ (x64)
> **Ruby version**: 4.0+ (x64-mingw-ucrt)
> **Document version**: v1.0
> **Corresponding binding version**: 1.0.0 (step-one completion state)

---

## Contents

1. [Goals and scope](#1-goals-and-scope)
2. [Environment requirements](#2-environment-requirements)
3. [Directory structure](#3-directory-structure)
4. [Compiling the C extension](#4-compiling-the-c-extension)
5. [Deploying the native DLL](#5-deploying-the-native-dll)
6. [Deploying the C extension](#6-deploying-the-c-extension)
7. [Load verification](#7-load-verification)
8. [Switching the Ruby layer](#8-switching-the-ruby-layer)
9. [Troubleshooting](#9-troubleshooting)
10. [Acceptance checklist](#10-acceptance-checklist)

---

## 1. Goals and scope

### 1.1 Background

The original Ruby binding used the Ruby standard-library `Fiddle` to load 37 `LF_*` functions directly from `LingoFuse64.dll`. That dual-mechanism scheme (Fiddle + self-written C extension) had the following problems:

| Problem | Impact |
|------|------|
| the load path cannot be controlled | `Fiddle.dlopen` searches only the system PATH and cannot explicitly register a DLL directory |
| type safety is runtime-only | wrongly typed arguments surface only at call time; no compile-time check |
| coarse error messages | a failed load reports only `No such file or directory` and does not name the missing symbol |
| two copies of the ABI declarations | `binding.rb` and the C extension each maintain their own symbol list, which easily drifts |
| split callback paths | callbacks go through the C extension, synchronous calls through Fiddle — two threading models coexist |

### 1.2 The step-one goal

**Fully replace the Fiddle layer with the self-written `lingofuse_ext.so`**:

- the C extension embeds `LingoFuse.c` internally (the upstream C loader + 59 function forwarders)
- the C extension exposes 59 `rb_lf_*` Ruby methods plus the loader (`load_library` / `free_library` / `loaded?`)
- the existing callback marshalling mechanism is **fully preserved** (native queue + Ruby dispatch thread)
- the Ruby side deletes the Fiddle path entirely

### 1.3 The architecture once completed

```
L0  application code
     │
L1  lib/lingofuse.rb                     entry point
     │
L2  Framework / Status / NetworkEvents   facades
     │
L3  DataHandle / AppHandle / LfIo        RAII + I/O
     │
L4  NativeBridge (callback marshalling)  the C extension's callback registration path
     │
L5  lingofuse_ext.so                     the self-written C extension
     ├── LingoFuse.c                     loader + 59 forwarders
     └── lingofuse_ext.c                 Ruby C API (rb_lf_*)
     │
L6  LingoFuse64.dll                      the native library
     + z_ipc_64.dll
     + mimalloc64.dll
     + mimalloc-redirect.dll
```

**The key change**: `L5` is now the **only** native entry point. Levels `L2` through `L4` no longer touch Fiddle.

---

## 2. Environment requirements

### 2.1 Software list

| Component | Minimum | Recommended | Notes |
|------|:--------:|:--------:|------|
| Windows | 10 (1809+) | Server 2022 / 11 | — |
| Ruby | 4.0.0 | **4.0.7** | must be **x64-mingw-ucrt** |
| DevKit | bundled with RubyInstaller | — | must be installed |
| GNU Make | 4.4+ | 4.4.1 | **not Embarcadero** |
| GCC | MinGW-w64 | 16.x | see the note in §2.4 |
| PowerShell | 5.0 | 7.x | — |

### 2.2 The confirmed reference environment

This document is based on the following **measured** environment:

```
PowerShell : 7.6.6
OS         : Windows Server 2022 Datacenter
Arch       : AMD64
Ruby       : ruby 4.0.7 (2026-09-15 revision 229531a6cf) +PRISM [x64-mingw-ucrt]
Ruby bindir: C:/Ruby40-x64/bin
Make       : C:\Ruby40-x64\msys64\usr\bin\make.exe (GNU Make 4.4.1)
GCC        : D:\mingw64\bin\gcc.exe (16.1.0, MinGW-Builds project)
```

### 2.3 Verifying the environment

Run `check_env.ps1`:

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
.\check_env.ps1
```

**Expected**:

```
  Passed : 14
  Warned : 0~2
  Failed : 0
```

**The key checks**:

| Section | Check | Must pass |
|:-------:|------|:--------:|
| 2 | Ruby version contains `x64-mingw-ucrt` | ✅ |
| 3 | GNU Make detected | ✅ |
| 3 | gcc detected | ✅ |
| 4 | mkmf available + gcc can compile a C program | ✅ |
| 5 | `pthread.h` + `ruby/thread.h` present | ✅ |
| 7 | `ext/lingofuse_ext/extconf.rb` present | ✅ |

### 2.4 A note on gcc

**First choice**: the gcc bundled with Ruby DevKit

```
C:\Ruby40-x64\msys64\mingw64\bin\gcc.exe
```

**Actually used in the current environment**: gcc from an external MinGW-Builds

```
D:\mingw64\bin\gcc.exe
```

Both are x86_64 with the seh exception model. **Either can compile `lingofuse_ext.so` successfully**, but with subtle differences:

| Difference | DevKit gcc | external MinGW-Builds gcc |
|------|:----------:|:---------------------:|
| CRT | UCRT (matching Ruby) | msvcrt |
| `have_library` probing | passes | **may fail** (see §2.5) |
| header search path | matching Ruby | independent |

### 2.5 The `have_library` trap

If `have_library('pthread')` in `extconf.rb` fails with:

```
The compiler failed to generate an executable file. (RuntimeError)
You have to install development tools first.
```

this is caused by a **CRT mismatch**: mkmf compiles the probe program with Ruby's UCRT CFLAGS, but the external gcc links against msvcrt libraries, so linking fails.

**The fix**: the current version of `extconf.rb` **already skips the `have_library` probe** and instead:

- checks only the headers (`have_header`, which involves no linking)
- explicitly appends `$libs << ' -lpthread'` and `$libs << ' -lkernel32'`

That way compilation succeeds even with an external gcc.

---

## 3. Directory structure

### 3.1 Before compiling

```
D:\CoreLibrary\LingoFuse\ruby\
├── BUILD_AND_DEPLOY.md                this document
├── BUILD_EXTENSION.md                 the older build guide (Fiddle era)
├── INSTALL_DEPENDENCIES.md            dependency installation guide
├── README.md                          main manual
├── check_env.ps1                      build environment diagnostics
├── check_env.rb                       runtime diagnostics
├── setup_build_env.ps1                one-command build script
├── clean.ps1                          cleanup script
├── run_tests.ps1 / run_test_ci.ps1    test scripts
│
├── ext/
│   └── lingofuse_ext/
│       ├── extconf.rb                 mkmf configuration
│       ├── LingoFuse.c                the upstream C loader (provided by a human)
│       ├── LingoFuse.h                the upstream C ABI header (provided by a human)
│       └── lingofuse_ext.c            the Ruby C API surface
│
├── lib/
│   ├── lingofuse.rb
│   └── lingofuse/
│       ├── binding.rb                 LF_* constant wrappers
│       ├── native_bridge.rb           the callback registration path
│       ├── data_handle.rb             RAII data handle
│       ├── app_handle.rb              RAII app handle
│       ├── framework.rb               the process-level facade
│       ├── status.rb                  the status queue
│       ├── network_events.rb          network events
│       ├── lf_io.rb                   unified I/O
│       ├── errors.rb                  the exception hierarchy
│       └── callback_error_reporter.rb callback exception reporting
│
└── test/                              14 test files
```

### 3.2 Added after compiling

```
ruby/
├── lib/
│   ├── lingofuse_ext.so               ★ build artifact (copied here)
│   └── ...
│
└── ext/lingofuse_ext/
    ├── LingoFuse.o                    ★ intermediate artifact
    ├── lingofuse_ext.o                ★ intermediate artifact
    ├── lingofuse_ext.so               ★ build artifact
    ├── lingofuse_ext-x64-mingw-ucrt.def ★ generated by mkmf
    ├── Makefile                       ★ generated by mkmf
    └── mkmf.log                       ★ mkmf log
```

### 3.3 Runtime dependencies (outside the project)

```
C:\Ruby40-x64\bin\                     ★ the exe's directory (first search point of LF_LoadLibrary)
├── ruby.exe
├── LingoFuse64.dll                    ★ the core RPC library
├── z_ipc_64.dll                       ★ the IPC substrate
├── mimalloc64.dll                     ★ the memory allocator
└── mimalloc-redirect.dll              ★ the mimalloc redirect
```

**These four DLLs must sit beside `ruby.exe`**. The reason is in §5.1.

---

## 4. Compiling the C extension

### 4.1 One-command build (recommended)

```powershell
cd D:\CoreLibrary\LingoFuse\ruby
powershell -ExecutionPolicy Bypass -File setup_build_env.ps1
```

### 4.2 Manual build

```powershell
cd D:\CoreLibrary\LingoFuse\ruby\ext\lingofuse_ext

# 1. clean old artifacts
Remove-Item Makefile,*.o,*.so,*.def,mkmf.log -ErrorAction SilentlyContinue

# 2. generate the Makefile
ruby extconf.rb

# 3. compile
make
```

### 4.3 Expected output

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

**Expected**:

- three key lines: `compiling LingoFuse.c` / `compiling lingofuse_ext.c` / `linking shared-object lingofuse_ext.so`
- **no errors**
- **no warnings** (`-Wno-cast-function-type` suppresses the spurious `GetProcAddress` warning)

### 4.4 The build artifacts

```powershell
Get-ChildItem D:\CoreLibrary\LingoFuse\ruby\ext\lingofuse_ext\*.so | Format-Table Name, Length
```

**Expected**:

```
Name                Length
----                ------
lingofuse_ext.so    98304     (the size may differ slightly)
```

### 4.5 Troubleshooting a failed build

| Symptom | Cause | Fix |
|------|------|------|
| `checking for -lpthread...` fails | CRT mismatch | use the current `extconf.rb` (it already skips `have_library`) |
| `Fatal makefile ... No terminator` | Embarcadero Make was used | prepend msys64's bin to PATH (see below) |
| `permission denied: conftest.exe` | a leftover process is holding the file | `Stop-Process ruby,conftest -Force` |
| a "Pascal-style error" or symbols not found | the wrong DLL was loaded | confirm `LingoFuse64.dll` is the right version |

**The Embarcadero Make shadowing problem** (previously encountered):

```powershell
# check the current make
make --version
# if it says "MAKE Version 5.43 ... Embarcadero", fix the ordering first

# temporary fix (current session only)
$env:PATH = "C:\Ruby40-x64\msys64\usr\bin;" + $env:PATH
make --version
# should print "GNU Make 4.4.1"
```

---

## 5. Deploying the native DLL

### 5.1 Why it must sit beside `ruby.exe`

The search logic of `LF_LoadLibrary` (see `LingoFuse.c`):

```c
// step one: load from the exe's directory
GetModuleFileNameA(NULL, full_path, ...)   // → "C:\Ruby40-x64\bin\ruby.exe"
                                            // → exe_dir = "C:\Ruby40-x64\bin\"
LoadLibraryA(exe_dir + "\\LingoFuse64.dll")

// step two: if step one fails, use the bare name
LoadLibraryA("LingoFuse64.dll")            // relies on PATH search
```

**Step one almost always succeeds**, because:

1. **the exe directory is always searched by the Windows loader**, unaffected by `SetDefaultDllDirectories`
2. **the dependent DLLs (`z_ipc_64.dll` and the others) are in the same directory**, and the Windows loader by default searches the directory of the loaded DLL (when the path is given explicitly)

**Step two will fail**, because Ruby calls `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)` at startup, after which `LoadLibrary` in this process no longer searches PATH.

### 5.2 The copy commands

```powershell
# copy from the authoritative directory to ruby.exe's directory
Copy-Item D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll       C:\Ruby40-x64\bin\ -Force
Copy-Item D:\CoreLibrary\LingoFuse\Binary\z_ipc_64.dll          C:\Ruby40-x64\bin\ -Force
Copy-Item D:\CoreLibrary\LingoFuse\Binary\mimalloc64.dll        C:\Ruby40-x64\bin\ -Force
Copy-Item D:\CoreLibrary\LingoFuse\Binary\mimalloc-redirect.dll C:\Ruby40-x64\bin\ -Force
```

### 5.3 Verifying

```powershell
Get-ChildItem C:\Ruby40-x64\bin\LingoFuse64.dll, `
              C:\Ruby40-x64\bin\z_ipc_64.dll, `
              C:\Ruby40-x64\bin\mimalloc64.dll, `
              C:\Ruby40-x64\bin\mimalloc-redirect.dll |
    Format-Table Name, Length
```

**Expected**: all four files exist; `LingoFuse64.dll` is about 2.9 MB.

### 5.4 Common errors

| Error | Cause | Fix |
|------|------|------|
| `Failed to load LingoFuse64.dll` | the DLL is not in the exe directory | copy as in §5.2 |
| `The specified module could not be found` | the three sibling DLLs are missing | all 4 must share one directory |
| `[WinError 126]` | a mimalloc-related DLL is missing | confirm `mimalloc-redirect.dll` exists |

**Note**: do not copy the DLLs to the project root (`D:\CoreLibrary\LingoFuse\ruby\`) — although it happens to work in some scenarios (depending on CWD), it is **unreliable**. Always put them in `C:\Ruby40-x64\bin\`.

---

## 6. Deploying the C extension

### 6.1 Copying the `.so` to `lib/`

`native_bridge.rb` and `binding.rb` load the extension through `require_relative '../lingofuse_ext'`, **with the path fixed at `lib/lingofuse_ext.so`**.

```powershell
Copy-Item D:\CoreLibrary\LingoFuse\ruby\ext\lingofuse_ext\lingofuse_ext.so `
          D:\CoreLibrary\LingoFuse\ruby\lib\lingofuse_ext.so `
          -Force
```

### 6.2 Verifying the location

```powershell
Test-Path D:\CoreLibrary\LingoFuse\ruby\lib\lingofuse_ext.so
# expected: True
```

### 6.3 Why that location is fixed

```ruby
# lib/lingofuse/native_bridge.rb
require_relative '../lingofuse_ext'
#              ^^^ relative to native_bridge.rb itself
#              → lib/lingofuse/../lingofuse_ext
#              → lib/lingofuse_ext.so
```

**It is unaffected by `$LOAD_PATH`, PATH or CWD**. If you move the whole `ruby/` directory, as long as the relative layout of `lib/` and `lingofuse/` is unchanged the `.so` is still found.

---

## 7. Load verification

### 7.1 The smoke test

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

**Expected output** (the key lines):

```
Native.load_library -> 1
Native.loaded?      -> true
lf_create_data      -> 2514705581520       (a non-zero Integer)
lf_get_size         -> 0
lf_free_data        -> ok
lf_get_option(Quiet)-> "False"
```

**The accompanying `[LF-DEBUG]` logs** (such as `TLF_App.Create` / `Init_P2P_APP done`) are LingoFuse's internal initialization output and **are normal**.

### 7.2 The full smoke test

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

**Expected output**:

```
loaded?             -> true
library_name        -> LingoFuse64.dll
read_string         -> "hello, 世界"
local_call result   -> "round-trip"
```

---

## 8. Switching the Ruby layer

### 8.1 Files already switched

| File | Change |
|------|------|
| `lib/lingofuse/binding.rb` | **rewritten**: Fiddle declarations removed, replaced by `require_relative '../lingofuse_ext'` + `LF_*` constant wrappers |
| `lib/lingofuse/native_bridge.rb` | **rewritten**: the Fiddle fallback removed; only the C extension is used |
| `lib/lingofuse/data_handle.rb` | **rewritten**: `@handle` changed from `Fiddle::Pointer` to `Integer` |
| `lib/lingofuse/app_handle.rb` | **rewritten**: as above; `register_*` calls `NativeBridge` directly |
| `lib/lingofuse/framework.rb` | **rewritten**: all calls go through the `LF_*` constants |
| `lib/lingofuse/status.rb` | **rewritten**: as above |
| `lib/lingofuse/network_events.rb` | **rewritten**: the Fiddle fallback removed |

### 8.2 Files left untouched

| File | Reason |
|------|------|
| `lib/lingofuse/lf_io.rb` | depends only on `DataHandle`'s high-level methods; unaware of the substrate |
| `lib/lingofuse/errors.rb` | a pure-Ruby exception hierarchy |
| `lib/lingofuse/callback_error_reporter.rb` | pure-Ruby callback reporting |
| `lib/lingofuse.rb` | the entry file; the require order is unchanged |

### 8.3 Key API compatibility

The following calls in existing code **stay exactly as they are**:

```ruby
# data handle
h = LingoFuse::DataHandle.new("api")
h.write_string("hello")
h.read_int32

# app handle
app = LingoFuse::AppHandle.new("App", "desc")
app.register_call("api", "desc") { |i, o| ... }
app.local_call(req)

# process level
LingoFuse::Framework.call("App", req, 3000)
LingoFuse::Framework.set_option("Quiet", "False")
LingoFuse::Status.check_app("App")
```

**The only behavioural change**: the return type of `DataHandle#raw` / `AppHandle#raw` changes from `Fiddle::Pointer` to `Integer` (an address value). **Ordinary user code should not use `.raw` directly**; if you must, pass that `Integer` straight to `Native.lf_*`.

---

## 9. Troubleshooting

### 9.1 The build stage

| Symptom | Diagnosis | Fix |
|------|------|------|
| `checking for -lpthread...` fails | CRT mismatch | use the current `extconf.rb` (skips `have_library`) |
| `No GNU Make found` | Embarcadero shadowing | prepend `C:\Ruby40-x64\msys64\usr\bin` to PATH |
| `conftest.exe: Permission denied` | a leftover process holds the file | `Get-Process ruby,conftest \| Stop-Process -Force` |
| `Fatal makefile ... No terminator` | wrong Make used | same as above |
| `LingoFuse.c: cast between incompatible function types` | a harmless warning | ignore it, or use `-Wno-cast-function-type` |

### 9.2 The deployment stage

| Symptom | Diagnosis | Fix |
|------|------|------|
| `Failed to load LingoFuse64.dll` | the DLL is not in the exe directory | copy as in §5.2 |
| `[WinError 126]` | a sibling DLL is missing | all 4 must share one directory |
| `cannot load such file -- lingofuse_ext` | the `.so` is not in `lib/` | copy as in §6.1 |
| `[BUG] rb_thread_call_with_gvl()` | the old Fiddle path is still in use | confirm the Ruby layer has switched to `Native` |

### 9.3 The runtime stage

| Symptom | Diagnosis | Fix |
|------|------|------|
| `CreateData called before LF_LoadLibrary` | loading failed | call `Native.load_library` first |
| `no found api "xxx"` | the API is not registered | check `AppHandle#register_call` |
| `prepare error: repeat listen` | duplicate address | `Framework.reset_prepare` |
| callbacks never fire | the dispatch thread was not started | confirm `NativeBridge.start` has been called |

### 9.4 The general troubleshooting order

```
1. check_env.ps1                   build environment
     ↓
2. ruby extconf.rb && make        C extension build
     ↓
3. §7.1 smoke test                standalone C extension load
     ↓
4. §7.2 full smoke test           Ruby layer integration
     ↓
5. ruby test/test_errors.rb       pure-Ruby tests
     ↓
6. ruby test/test_data_handle.rb  data handle tests
     ↓
7. run_test_ci.ps1                the full test suite
```

---

## 10. Acceptance checklist

After finishing step one, all of the following commands should pass.

### 10.1 Build verification

- [ ] `ruby extconf.rb` produces no errors
- [ ] `make` produces no errors and no warnings
- [ ] `ext/lingofuse_ext/lingofuse_ext.so` exists

### 10.2 Deployment verification

- [ ] `C:\Ruby40-x64\bin\LingoFuse64.dll` exists
- [ ] `C:\Ruby40-x64\bin\z_ipc_64.dll` exists
- [ ] `C:\Ruby40-x64\bin\mimalloc64.dll` exists
- [ ] `C:\Ruby40-x64\bin\mimalloc-redirect.dll` exists
- [ ] `lib/lingofuse_ext.so` exists

### 10.3 Load verification

- [ ] `LingoFuse::Native.load_library` returns `1`
- [ ] `LingoFuse::Native.loaded?` returns `true`
- [ ] `LingoFuse::Native.lf_create_data("x")` returns a non-zero Integer

### 10.4 Ruby layer verification

- [ ] `LingoFuse.loaded?` returns `true`
- [ ] `LingoFuse.library_name` returns `"LingoFuse64.dll"`
- [ ] `DataHandle.new("x").write_string("hello")` raises nothing
- [ ] `AppHandle.new("X", "d").local_call(req)` returns the correct result
- [ ] `Framework.set_option` / `get_option` round-trip consistently

### 10.5 Test suite verification

- [ ] `ruby test/test_errors.rb` passes
- [ ] `ruby test/test_data_handle.rb` passes
- [ ] `ruby test/test_app_handle.rb` passes
- [ ] `ruby test/test_native_bridge_self_test.rb` passes
- [ ] `.\run_test_ci.ps1` prints `All 14 test files passed.`

---

## Appendix A — Key file descriptions

### A.1 The source files inside `ext/lingofuse_ext/`

| File | Origin | Purpose |
|------|------|------|
| `extconf.rb` | project | mkmf configuration |
| `LingoFuse.c` | provided upstream | DLL loader + 59 forwarders + helpers |
| `LingoFuse.h` | provided upstream | C ABI declarations |
| `lingofuse_ext.c` | project | the Ruby C API surface + callback marshalling |

### A.2 Macros at compile time

| Macro | Purpose |
|----|------|
| `_WIN32` | enables the Windows-specific code (`LoadLibraryA` and friends) |
| `WIN32_LEAN_AND_MEAN` | reduces the symbols `<windows.h>` exposes |

### A.3 Libraries at link time

| Library | Platform | Purpose |
|----|------|------|
| `pthread` | MinGW | winpthreads (the native primitive behind the callback queue) |
| `kernel32` | Windows | `LoadLibrary` / `GetModuleFileName` / `FreeLibrary` |
| `x64-ucrt-ruby400` | Windows | the Ruby 4.0 runtime (linked automatically by mkmf) |

---

## Appendix B — Fiddle versus the self-written library

| Scenario | Old (Fiddle) | New (self-written library) |
|------|-------------|-------------|
| loading the DLL | `Fiddle.dlopen` + manual PATH enumeration | `LF_LoadLibrary` (`LoadLibraryA`) |
| declaring functions | `Fiddle::Function.new` | the C extension's `rb_lf_*` methods |
| passing handles | `Fiddle::Pointer` | `Integer` (an address value) |
| passing strings | manual `cstr_ptr` | a Ruby `String` (converted automatically) |
| callback registration | `Fiddle::Closure` + `LF_RegisterCall` | the C extension's `NativeBridge.register_call` |
| callback threads | Fiddle cannot cross threads → deadlock | C queue + Ruby dispatch thread → safe |
| error messages | `No such file or directory` | `Failed to resolve symbol LF_XXX` |

---

## Appendix C — Version history

| Version | Date | Change |
|:----:|:----:|------|
| v1.0 | 2026-10-14 | step one complete: Fiddle → self-written C extension |

---

*Document version v1.0 · corresponding to LingoFuse Ruby binding 1.0.0 · last updated 2026-10-14*
