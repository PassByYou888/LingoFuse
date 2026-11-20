# LingoFuse multi-language deployment guide (v3.0)

> Chinese version: [LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md](LingoFuse_MultiLanguage_Deployment_Guide_v3.0.md)

> **Scope**: 18 first-party bindings = 17 native FFIs + 1 PHP through the bridge. Browser JavaScript and Delphi go over HTTP/JSON + bridge.

---

## Contents (click to jump)

| # | Language | Option one | Option two | Hard version | Jump |
|:---:|:---|:---|:---|:---|:---:|
| 1 | [Pascal](#1-pascal) | [Lazarus](https://www.lazarus-ide.org/) + [FPC](https://www.freepascal.org/download.var) | [Delphi / RAD Studio](https://www.embarcadero.com/products/delphi) | FPC 3.2.2+ / Delphi 10.4+ | [⬇️](#1-pascal) |
| 2 | [Python](#2-python) | [VS Code](https://code.visualstudio.com/) + [Pylance](https://marketplace.visualstudio.com/items?itemName=ms-python.vscode-pylance) | [PyCharm](https://www.jetbrains.com/pycharm/) | Python 3.8+ | [⬇️](#2-python) |
| 3 | [C++](#3-c) | [VS Code](https://code.visualstudio.com/) + [MinGW/MSYS2](https://www.msys2.org/) + [CMake](https://cmake.org/download/) | [Visual Studio 2022](https://visualstudio.microsoft.com/vs/community/) / [CLion](https://www.jetbrains.com/clion/) | C++17 | [⬇️](#3-c) |
| 4 | [C#](#4-c-1) | [VS Code](https://code.visualstudio.com/) + [C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit) | [Visual Studio 2022](https://visualstudio.microsoft.com/vs/community/) / [Rider](https://www.jetbrains.com/rider/) | .NET 6+ | [⬇️](#4-c-1) |
| 5 | [Rust](#5-rust) | [VS Code](https://code.visualstudio.com/) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer) | [CLion](https://www.jetbrains.com/clion/) / [RustRover](https://www.jetbrains.com/rust/) | edition 2021 | [⬇️](#5-rust) |
| 6 | [Go](#6-go) | [VS Code](https://code.visualstudio.com/) + [Go extension](https://marketplace.visualstudio.com/items?itemName=golang.Go) | [GoLand](https://www.jetbrains.com/go/) | Go 1.21+ | [⬇️](#6-go) |
| 7 | [Java](#7-java) | [VS Code](https://code.visualstudio.com/) + [Java Pack](https://marketplace.visualstudio.com/items?itemName=vscjava.vscode-java-pack) | [IntelliJ IDEA](https://www.jetbrains.com/idea/) / [Eclipse](https://www.eclipse.org/downloads/) | **JDK 22+ / Maven 3.9+** | [⬇️](#7-java) |
| 8 | [Node.js](#8-nodejs) | [VS Code](https://code.visualstudio.com/) | [WebStorm](https://www.jetbrains.com/webstorm/) | Node 18+ | [⬇️](#8-nodejs) |
| 9 | [TypeScript](#9-typescript) | [VS Code](https://code.visualstudio.com/) (built-in TS) | [WebStorm](https://www.jetbrains.com/webstorm/) | TS 5.6+ / Node 18+ | [⬇️](#9-typescript) |
| 10 | [Erlang](#10-erlang) | [VS Code](https://code.visualstudio.com/) + [Erlang extension](https://marketplace.visualstudio.com/items?itemName=pguyot.erlang) | [IntelliJ IDEA](https://www.jetbrains.com/idea/) + Erlang extension | OTP 27+ | [⬇️](#10-erlang) |
| 11 | [Julia](#11-julia) | [VS Code](https://code.visualstudio.com/) + [Julia extension](https://marketplace.visualstudio.com/items?itemName=julialang.language-julia) | [Jupyter](https://jupyter.org/install) + IJulia | Julia 1.9+ | [⬇️](#11-julia) |
| 12 | [Zig](#12-zig) | [VS Code](https://code.visualstudio.com/) + [Zig Lang Support](https://marketplace.visualstudio.com/items?itemName=mitchellh.vscode-zig) | [Neovim](https://neovim.io/) + [ZLS](https://github.com/zigtools/zls) | **Zig 0.17.0 (strict)** | [⬇️](#12-zig) |
| 13 | [Swift](#13-swift) | [VS Code](https://code.visualstudio.com/) + [Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode) | [Xcode](https://developer.apple.com/xcode/) (macOS only) | Swift 5.9+ | [⬇️](#13-swift) |
| 14 | [Ruby](#14-ruby) | [VS Code](https://code.visualstudio.com/) + [Ruby LSP](https://marketplace.visualstudio.com/items?itemName=Shopify.ruby-lsp) | [RubyMine](https://www.jetbrains.com/ruby/) | Ruby 4.0+ | [⬇️](#14-ruby) |
| 15 | [Fortran](#15-fortran) | [VS Code](https://code.visualstudio.com/) + [Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran) + [fortls](https://pypi.org/project/fortls/) | [Code::Blocks](https://www.codeblocks.org/) / [Simply Fortran](https://simplyfortran.com/) | Fortran 2008 + C++17 | [⬇️](#15-fortran) |
| 16 | [Dart](#16-dart) | [VS Code](https://code.visualstudio.com/) + [Dart extension](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code) | [IntelliJ IDEA](https://www.jetbrains.com/idea/) / [Android Studio](https://developer.android.com/studio) | Dart 3.0+ | [⬇️](#16-dart) |
| 17 | [R](#17-r) | [RStudio](https://posit.co/download/rstudio-desktop/) | [VS Code](https://code.visualstudio.com/) + [R extension](https://marketplace.visualstudio.com/items?itemName=REditorSupport.r) | R 4.0+ / Rtools45 | [⬇️](#17-r) |
| 18 | [PHP](#18-php) | `bridge.py` HTTP gateway | `bridge.exe` HTTP gateway | PHP + curl | [⬇️](#18-php) |
| 19 | [Browser JavaScript](#19-browser-javascript) | `bridge.py` + Fetch | `code_decl_to_json_abi` generates JS | Modern browsers | [⬇️](#19-browser-javascript) |
| 20 | [Delphi](#20-delphi) | RAD Studio native Pascal | `code_decl_to_json_abi` Delphi Call | Delphi 10.4+ | [⬇️](#20-delphi) |

---

## Current checker machine environment baseline

| Language | Tool | Check result | Jump |
|---|---|---|---|
| Pascal | fpc | 3.2.2 OK | [Pascal](#1-pascal) |
| Python | python | 3.14.7 OK | [Python](#2-python) |
| C++ | gcc / g++ / cmake | 16.1.0 / 16.1.0 / 3.31.2 OK | [C++](#3-c) |
| C# | dotnet | 9.0.316 OK | [C#](#4-c-1) |
| Rust | cargo / rustc | 1.97.1 / 1.97.1 OK | [Rust](#5-rust) |
| Go | go | 1.25.0 windows/amd64 OK | [Go](#6-go) |
| Java | java / mvn | OK (with a Windows multi-processor-group warning) | [Java](#7-java) |
| Node.js | node / npm | v24.21.0 / 11.19.0 OK | [Node.js](#8-nodejs) |
| TypeScript/http_ts | node / npm | v24.21.0 / 11.19.0 OK | [TypeScript](#9-typescript) |
| Erlang | erl / erlc / escript | erl 29 OK; erlc prints no version; `escript Missing filename` is normal | [Erlang](#10-erlang) |
| Julia | julia | 1.13.1 OK | [Julia](#11-julia) |
| Zig | zig | 0.17.0 OK | [Zig](#12-zig) |
| Swift | swift | 6.4 OK | [Swift](#13-swift) |
| Ruby | ruby | 4.0.7 x64-mingw-ucrt OK | [Ruby](#14-ruby) |
| Fortran | gfortran | 16.1.0 OK | [Fortran](#15-fortran) |
| Dart | dart | 3.6.2 OK | [Dart](#16-dart) |
| R | Rscript | 4.6.1 OK | [R](#17-r) |

> PHP, browser JavaScript, Delphi JSON Call and the `bridge.py` runtime are outside that script's scope and must be verified separately.

---

## 1. Pascal

- **Option one**: [Lazarus](https://www.lazarus-ide.org/) + [Free Pascal](https://www.freepascal.org/download.var).
- **Option two**: [Delphi / RAD Studio](https://www.embarcadero.com/products/delphi).
- **Hard version**: FPC 3.2.2+ or Delphi 10.4+. Current `fpc 3.2.2` passes.
- **Additional notes**:
  - **Extra libraries**: none third-party; depends on the RTL `SysUtils`, `Classes`, `SyncObjs`.
  - **Caveats**: callbacks must be `cdecl`; keep `{$IFDEF FPC}` for cross-compiler support; when saving `.pas` in Delphi prefer UTF-8 with BOM; `LF_LocalCall` / `LF_LocalNotify` do not inject sender identity — when identity is needed use `LF_Call` to hit the local short-circuit.
- **Verify**: `fpc -iV`.
- **Download/docs**: [Free Pascal](https://www.freepascal.org/download.var), [Lazarus](https://www.lazarus-ide.org/), [Delphi](https://www.embarcadero.com/products/delphi).

___

## 2. Python

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Pylance](https://marketplace.visualstudio.com/items?itemName=ms-python.vscode-pylance).
- **Option two**: [PyCharm](https://www.jetbrains.com/pycharm/).
- **Hard version**: Python 3.8+. Current `Python 3.14.7` passes.
- **Additional notes**:
  - **Extra libraries**: `pip install -e .` under the repo's `py/`; see `py/requirements.txt` for `bridge.py` dependencies. The PyPI name appears as both `py-lingofuse` and `lingofuse` in different documents; for deployment prefer a local editable install to avoid ambiguity.
  - **Caveats**: synchronous-family handles belong to the caller; the async family belongs to the framework and is released immediately after the callback returns; do all work inside the async callback and never retain a raw handle across threads; `_Aio` must be awaited inside `asyncio.run()`; `_Async` returns a `CallFuture`; callbacks need `@server.expose` or an explicit `CFUNCTYPE`.
- **Verify**: `python --version`; `python -c "import lingofuse"`.
- **Download/docs**: [Python Windows](https://www.python.org/downloads/windows/), [VS Code](https://code.visualstudio.com/), [PyCharm](https://www.jetbrains.com/pycharm/).

___

## 3. C++

- **Option one**: [VS Code](https://code.visualstudio.com/) + [MSYS2/MinGW-w64](https://www.msys2.org/) + [CMake](https://cmake.org/download/).
- **Option two**: [Visual Studio 2022 Community](https://visualstudio.microsoft.com/vs/community/) / [CLion](https://www.jetbrains.com/clion/).
- **Hard version**: C++17. Current `gcc/g++ 16.1.0` and `cmake 3.31.2` pass.
- **Additional notes**:
  - **Extra libraries**: the standard library + `LingoFuse.hpp` / `lf_io.hpp` / `LingoFuse.c`; no third-party.
  - **Caveats**: `LF_LoadLibrary()` must be called first and its return of 1 checked; MSVC must use `/utf-8`; CMake must use `project(name C CXX)` or it reports `Cannot determine link language`; copy data inside async callbacks and never `dispose` the async `Result_`; place the runtime DLL next to the exe or on `PATH`.
- **Verify**: `g++ --version`, `cmake --version`.
- **Download/docs**: [MSYS2](https://www.msys2.org/), [CMake](https://cmake.org/download/), [VS 2022](https://visualstudio.microsoft.com/vs/community/), [CLion](https://www.jetbrains.com/clion/).

___

## 4. C#

- **Option one**: [VS Code](https://code.visualstudio.com/) + [C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit).
- **Option two**: [Visual Studio 2022 Community](https://visualstudio.microsoft.com/vs/community/) / [Rider](https://www.jetbrains.com/rider/).
- **Hard version**: .NET 6+. Current `dotnet 9.0.316` passes.
- **Additional notes**:
  - **Extra libraries**: reference the `LingoFuse` C# project or the NuGet package; no third-party.
  - **Caveats**: **the generated library must have no `Main`**, otherwise `CS0017`; async callbacks use `TaskCompletionSource` + `RunContinuationsAsynchronously`; `DllImportResolver` selects the platform library automatically and the DLL goes into bin; never keep a `DataHandle` reference beyond its `using` block.
- **Verify**: `dotnet --version`.
- **Download/docs**: [.NET SDK](https://dotnet.microsoft.com/download), [C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit), [Rider](https://www.jetbrains.com/rider/).

___

## 5. Rust

- **Option one**: [VS Code](https://code.visualstudio.com/) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer).
- **Option two**: [CLion](https://www.jetbrains.com/clion/) / [RustRover](https://www.jetbrains.com/rust/).
- **Hard version**: Rust edition 2021. Current `cargo/rustc 1.97.1` passes.
- **Additional notes**:
  - **Extra libraries**: the `lingofuse` crate, referenced by `path` or `git` in `Cargo.toml`.
  - **Caveats**: panics must go through `catch_unwind`, and user callbacks should not panic either; the async signature is `FnOnce(Result<T, Error>) + Send + 'static`; `ABI_TARGET_APP` / `ABI_TIMEOUT` are atomics; place the runtime DLL next to the exe or on `PATH`.
- **Verify**: `cargo --version`, `rustc --version`.
- **Download/docs**: [rustup](https://rustup.rs/), [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer), [RustRover](https://www.jetbrains.com/rust/).

___

## 6. Go

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Go extension](https://marketplace.visualstudio.com/items?itemName=golang.Go).
- **Option two**: [GoLand](https://www.jetbrains.com/go/).
- **Hard version**: Go 1.21+. Current `go 1.25.0 windows/amd64` passes.
- **Additional notes**:
  - **Extra libraries**: `github.com/PassByYou888/LingoFuse/go/lingofuse`; point `go.mod` at the local module with `replace`.
  - **Caveats**: on the Call side `purego` needs no cgo; **the Service side must set `CGO_ENABLED=1`**; `sys.LoadLibrary()` must be called first; use `defer param.Close()` so it is released only after the async callback ends; on first opening a Go file, install `gopls` / `dlv` / `gofmt` via "Install All" as prompted.
- **Verify**: `go version`.
- **Download/docs**: [Go SDK](https://go.dev/dl/), [Go extension](https://marketplace.visualstudio.com/items?itemName=golang.Go), [GoLand](https://www.jetbrains.com/go/).

___

## 7. Java

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Extension Pack for Java](https://marketplace.visualstudio.com/items?itemName=vscjava.vscode-java-pack).
- **Option two**: [IntelliJ IDEA](https://www.jetbrains.com/idea/) / [Eclipse](https://www.eclipse.org/downloads/).
- **Hard version**: **JDK 22+, Maven 3.9+**. Current `java` / `mvn` pass, with a Windows multi-processor-group warning that can be ignored.
- **Additional notes**:
  - **Extra libraries**: `jackson-databind 2.17.0`; the LingoFuse Java jar can be referenced via `<systemPath>`.
  - **Caveats**: JDK 21 and below do not work; `LibraryLoader.selectPlatformFileName()` must be called first; `-Djava.library.path` must point at the native libraries; `AsyncBridge.shutdownInstance()` must be called before exit; system-scope jars need shade/assembly to be included in packages; below 22 you get `release version 22 not supported`.
- **Verify**:
  ```powershell
  (& java -XshowSettings:properties -version 2>&1 | Out-String) -split "`n" | Select-String 'java\.version'
  (& mvn -v 2>&1 | Out-String) -split "`n" | Select-String 'Apache Maven'
  ```
- **Download/docs**: [JDK 22 Oracle](https://download.oracle.com/java/22/latest/jdk-22_windows-x64_bin.msi), [Adoptium](https://adoptium.net/), [Maven](https://maven.apache.org/download.cgi), [Java Pack](https://marketplace.visualstudio.com/items?itemName=vscjava.vscode-java-pack).

___

## 8. Node.js

- **Option one**: [VS Code](https://code.visualstudio.com/).
- **Option two**: [WebStorm](https://www.jetbrains.com/webstorm/).
- **Hard version**: Node.js 18+. Current `node v24.21.0`, `npm 11.19.0` pass.
- **Additional notes**:
  - **Extra libraries**: `lingofuse-js`, `koffi`.
  - **Caveats**: the `data` pointer of `LF_Async_Call` must be non-null (`op.dataPtr`); `AsyncBridge` timers **must not be `unref`ed**; `param` must be disposed only after the promise settles; `AsyncBridge.shutdownInstance()` must be called before exit; place the runtime DLL at the project root or on `PATH`.
- **Verify**: `node -v`, `npm -v`.
- **Download/docs**: [Node.js](https://nodejs.org/), [WebStorm](https://www.jetbrains.com/webstorm/).

___

## 9. TypeScript

- **Option one**: [VS Code](https://code.visualstudio.com/) (built-in TS).
- **Option two**: [WebStorm](https://www.jetbrains.com/webstorm/).
- **Hard version**: TypeScript 5.6+ / Node 18+. Current `node v24.21.0`, `npm 11.19.0`, and the `http_ts` check pass.
- **Additional notes**:
  - **Extra libraries**: `lingofuse-ts`, `koffi`.
  - **Caveats**: the `exports` of `lingofuse-ts/package.json` must carry the `./dist/` prefix; `tsconfig.json` should use `"module":"commonjs"` and `"esModuleInterop":true`; `CallPromise<T>` only implements `PromiseLike<T>`, and `_race` falls back to `PromiseLike<T>`; `tsc --noEmit` reporting zero errors is a hard requirement.
- **Verify**: `npx tsc --noEmit`.
- **Download/docs**: [Node.js](https://nodejs.org/), [TypeScript](https://www.typescriptlang.org/download), [WebStorm](https://www.jetbrains.com/webstorm/).

___

## 10. Erlang

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Erlang extension](https://marketplace.visualstudio.com/items?itemName=pguyot.erlang).
- **Option two**: [IntelliJ IDEA Ultimate](https://www.jetbrains.com/idea/) + Erlang extension.
- **Hard version**: OTP 27+. Current `erl 29` passes; `erlc` printing no version and `escript: Missing filename` are normal artefacts of the check script.
- **Additional notes**:
  - **Extra libraries**: `lingofuse.beam`, `priv/lingofuse_nif.dll`, [rebar3](https://www.rebar3.org/).
  - **Caveats**: the ABI layer must use the binary wire format; JSON is forbidden; the NIF layer must not strip `#0`; the Service main loop must handle 16 message shapes: `lf_call` / `lf_p2p_call` / `lf_notify` / `lf_p2p_notify` × with/without `Identity` × specific/generic; `lingofuse:reply/2` may be called only once — use `_ =`; with `Wait_Connection_ReadyOk=False` the SelfClient Link/reporting is asynchronous, so tests need `sleep(15000)`-scale waits; a NIF crash takes BEAM down.
- **Verify**:
  ```powershell
  erl -eval "io:format(\"~s~n\",[erlang:system_info(otp_release)]),halt()." -noshell
  ```
- **Download/docs**: [Erlang/OTP](https://www.erlang.org/downloads), [rebar3](https://www.rebar3.org/), [Erlang extension](https://marketplace.visualstudio.com/items?itemName=pguyot.erlang).

___

## 11. Julia

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Julia extension](https://marketplace.visualstudio.com/items?itemName=julialang.language-julia).
- **Option two**: [Jupyter](https://jupyter.org/install) + IJulia.
- **Hard version**: Julia 1.9+, **`--threads=2` is mandatory**. Current `julia 1.13.1` passes.
- **Additional notes**:
  - **Extra libraries**: `LingoFuse.jl`, via `Pkg.develop(path="…")`.
  - **Caveats**: single-threaded runs deadlock; the callback consumer must not land on the main thread; `@threadcall` concurrency is constrained by the libuv thread pool (4 by default, raisable via `UV_THREADPOOL_SIZE`); do not edit the UUID in `Project.toml` by hand; Linux/macOS/Apple Silicon are unverified.
- **Verify**: `julia --version`; run with `julia --threads=2`.
- **Download/docs**: [Julia](https://julialang.org/downloads/), [Julia extension](https://marketplace.visualstudio.com/items?itemName=julialang.language-julia), [Jupyter](https://jupyter.org/install).

___

## 12. Zig

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Zig Language Support](https://marketplace.visualstudio.com/items?itemName=mitchellh.vscode-zig) + [ZLS](https://github.com/zigtools/zls).
- **Option two**: [Neovim](https://neovim.io/) + [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) pointed at `zls.exe`.
- **Hard version**: **Zig 0.17.0 (strictly pinned)**. Current `zig 0.17.0` passes.
- **Additional notes**:
  - **Extra libraries**: the `lingofuse` module, `c/lf_json.cpp`; no third-party.
  - **Caveats**: `minimum_zig_version = "0.17.0"` in `build.zig.zon`; 0.16 / 0.18 do not compile; on fingerprint errors the setup script parses `use this value: 0x…` and writes it back, retrying up to 3 times; `[]const u8` and `[]u8` differ in semantics — use `[]const u8` for string parameters; Linux/macOS/32-bit are untested.
- **Verify**: `zig version`.
- **Download/docs**: [Zig](https://ziglang.org/download/), [ZLS](https://github.com/zigtools/zls), [Zig VS Code extension](https://marketplace.visualstudio.com/items?itemName=mitchellh.vscode-zig).

___

## 13. Swift

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode).
- **Option two**: [Xcode](https://developer.apple.com/xcode/) (macOS only).
- **Hard version**: Swift 5.9+, 6.4 recommended. Current `Swift 6.4` passes.
- **Additional notes**:
  - **Extra libraries**: the `LingoFuse` Swift Package, `CLingoFuse`.
  - **Caveats**: on Windows you must first install the [Visual Studio 2022](https://visualstudio.microsoft.com/vs/community/) "Desktop development with C++" workload; the identity of an SPM `.package(path:)` is the lowercased last path segment, not the `name` in `Package.swift`; Swift 6.4's `#NoUsage` diagnostic may falsely report unused; macOS/Linux deployment paths are unmeasured.
- **Verify**: `swift --version`.
- **Download/docs**: [Swift Windows](https://www.swift.org/install/windows/), [Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode), [Xcode](https://developer.apple.com/xcode/).

___

## 14. Ruby

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Ruby LSP](https://marketplace.visualstudio.com/items?itemName=Shopify.ruby-lsp).
- **Option two**: [RubyMine](https://www.jetbrains.com/ruby/).
- **Hard version**: Ruby 4.0+ (x64-mingw-ucrt). Current `ruby 4.0.7 x64-mingw-ucrt` passes.
- **Additional notes**:
  - **Extra libraries**: the `lingofuse` gem, `lingofuse_ext.so`; [RubyInstaller](https://rubyinstaller.org/) + DevKit/MSYS2 base; `gem install ruby-lsp`.
  - **Caveats**: `setup_ruby_tests.ps1 -RubyLibDir` must point at the `lib/` directory; `at_exit` order: `NativeBridge.stop` → `exit_main_thread` → `shutdown` → `Native.free_library`; `HTTP_CALL_BASE_URL` is read-only — use `Module.base_url = ...`; to keep the process alive use `exit!`; an abnormal exit may cause an access violation in the dispatcher thread after the DLL is unloaded.
- **Verify**: `ruby -v`.
- **Download/docs**: [RubyInstaller](https://rubyinstaller.org/), [Ruby LSP](https://marketplace.visualstudio.com/items?itemName=Shopify.ruby-lsp), [RubyMine](https://www.jetbrains.com/ruby/).

___

## 15. Fortran

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran) + [fortls](https://pypi.org/project/fortls/).
- **Option two**: [Code::Blocks](https://www.codeblocks.org/) / [Simply Fortran](https://simplyfortran.com/).
- **Hard version**: Fortran 2008 + C++17; the C++ and Fortran compilers must come from the same toolchain. Current `gfortran 16.1.0` passes.
- **Additional notes**:
  - **Extra libraries**: `iso_c_binding`, `lf_fortran_mod`, `lf_fortran.cpp`, `LingoFuse.c/.h/.hpp`; install `mingw-w64-x86_64-gcc-fortran` via [MSYS2](https://www.msys2.org/).
  - **Caveats**: compile order `LingoFuse.c` (gcc) → `lf_fortran.cpp` (g++) → `lf_fortran_mod.f90` (gfortran); no async support; `internal_call_<api>` is a stub returning zeros; callbacks are named `<api>_callback`, not `callback_<api>`; Linux/macOS are theoretically viable but unmeasured.
- **Verify**: `gfortran --version`.
- **Download/docs**: [MSYS2](https://www.msys2.org/), [Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran), [fortls](https://pypi.org/project/fortls/), [Code::Blocks](https://www.codeblocks.org/).

___

## 16. Dart

- **Option one**: [VS Code](https://code.visualstudio.com/) + [Dart extension](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code).
- **Option two**: [IntelliJ IDEA](https://www.jetbrains.com/idea/) / [Android Studio](https://developer.android.com/studio) + Dart extension.
- **Hard version**: Dart 3.0+. Current `Dart 3.6.2` passes.
- **Additional notes**:
  - **Extra libraries**: the `lingofuse` Dart package, `lf_dart_bridge.dll`; run `dart pub get` first.
  - **Caveats**: `BridgeHost.start()` must be the first line of `main()`; `ABI_TARGET_APP` must be `const`, otherwise `Isolate.run` re-executing top-level code yields inconsistent values; Flutter Web is unusable; on mobile, route Calls through the bridge and deploy the Service on a server; `dart analyze` may report `non_constant_identifier_names`, and generated files already carry `// ignore_for_file:` at the head.
- **Verify**: `dart --version`.
- **Download/docs**: [Dart SDK](https://dart.dev/get-dart/archive), [Dart extension](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code), [Android Studio](https://developer.android.com/studio).

___

## 17. R

- **Option one**: [RStudio](https://posit.co/download/rstudio-desktop/).
- **Option two**: [VS Code](https://code.visualstudio.com/) + [R extension](https://marketplace.visualstudio.com/items?itemName=REditorSupport.r).
- **Hard version**: R 4.0+ / Rtools45. Current `Rscript 4.6.1` passes.
- **Additional notes**:
  - **Extra libraries**: the `lingofuse` R package; `bit64` optional (required for int64/uint64); Rtools optional (needed when compiling R packages containing C/C++).
  - **Caveats**: `LF_Call` is not reentrant — use `lf_local_call` for single-process self-testing; `*_async` requires `future::plan("sequential")`, because `multisession` / `multicore` fork and leave the runtime uninitialized; stopping the service is best done by writing a `service.exit` sentinel file rather than Ctrl+C; external binary dependencies make CRAN submission impossible; set `LINGOFUSE_RUNTIME`.
- **Verify**: `Rscript --version` or `R --version`.
- **Download/docs**: [R Windows](https://cran.r-project.org/bin/windows/base/), [RStudio](https://posit.co/download/rstudio-desktop/), [R extension](https://marketplace.visualstudio.com/items?itemName=REditorSupport.r).

___

## 18. PHP

- **Option one**: `bridge.py` HTTP gateway.
- **Option two**: `bridge.exe` HTTP gateway.
- **Hard version**: PHP with the `curl` extension or `allow_url_fopen=On`; `bridge.py` / `bridge.exe` must be running.
- **Additional notes**:
  - **Extra libraries**: the `lingofuse.php` HTTP client wrapper under the repo's `php/`; no native LingoFuse library.
  - **Caveats**: PHP **can only act as a Caller** with no Service-side capability; it cannot load `LingoFuse64.dll`; the endpoint must match the bridge/service; if the bridge is not running every Call reports a network error.
- **Example**:
  ```php
  require_once 'lingofuse.php';
  $api = new LingoFuseApi('http://127.0.0.1:8081/<Unit>');
  $result = $api->call('Add', [1, 2]);
  ```
- **Verify**: `php -v`; start the bridge then run the PHP call; hit the bridge API directly with `curl`.
- **Download/docs**: [PHP](https://www.php.net/downloads), [Bridge_User_Guide.md](py/lingofuse/Bridge_User_Guide.md).

___

## 19. Browser JavaScript

- **Option one**: `bridge.py` + [Fetch API](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API).
- **Option two**: browser JS Call artefacts generated by `code_decl_to_json_abi`.
- **Hard version**: modern browsers; the bridge running; CORS configured.
- **Additional notes**:
  - **Extra libraries**: no native library; `bridge.py` / `bridge.exe` required.
  - **Caveats**: browsers cannot FFI natively; fetch is restricted under `file://`, so serve the page with `python3 -m http.server`; CORS needs `--cors '*'` on the bridge; `int64` loses precision in JS `Number`, so the service side should return strings; bridge precheck caching issues can be bypassed with `--no-precheck`; `code=-3` / `-4` point at bridge version/protocol problems; there is no Service on the browser side.
- **Verify**: fetch the bridge URL from the browser console and check for `{"code":0,...}` in the response.
- **Download/docs**: [Fetch API](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API), [Bridge_User_Guide.md](py/lingofuse/Bridge_User_Guide.md).

___

## 20. Delphi

- **Option one**: native Pascal bindings in [RAD Studio](https://www.embarcadero.com/products/delphi).
- **Option two**: a Delphi Call generated by `code_decl_to_json_abi`, going through `bridge.py` / `bridge.exe`.
- **Hard version**: Delphi 10.4+.
- **Additional notes**:
  - **Extra libraries**: for the native option, same as Pascal; the JSON option needs `bridge.py` / `bridge.exe` plus the generated Delphi Call unit.
  - **Caveats**: deploy the native Pascal option per [Pascal](#1-pascal); the Delphi artefact from `code_decl_to_json_abi` is a **Call**, not a Service; do not mistake the "Delphi-specific JSON artefact" for a Service; the endpoint must match the bridge.
- **Verify**: compile and run in RAD Studio; for the JSON option start the bridge before running the Delphi Call.
- **Download/docs**: [Delphi / RAD Studio](https://www.embarcadero.com/products/delphi), [Bridge_User_Guide.md](py/lingofuse/Bridge_User_Guide.md).

___

## Appendix: general deployment checklist

- [ ] `LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib` is on the search path.
- [ ] `z_ipc_64.dll`, `mimalloc64.dll`, `mimalloc-redirect.dll` in the same directory or on `PATH`.
- [ ] Java: `java.library.path`, `lingofuse.jar`, Jackson.
- [ ] C#: the library has no `Main`; the DLL is copied into bin.
- [ ] C++: `LF_LoadLibrary()` has been called; MSVC `/utf-8`.
- [ ] Go Service: `CGO_ENABLED=1`; Call: purego.
- [ ] Erlang: `priv/lingofuse_nif.dll` copied.
- [ ] Ruby: `lingofuse_ext.so` in `lib/`; `at_exit` order correct.
- [ ] Dart: `BridgeHost.start()` on the first line; `ABI_TARGET_APP` is `const`.
- [ ] Node/TS: `AsyncBridge` timers not `unref`ed; `shutdownInstance` called.
- [ ] Julia: `--threads=2`.
- [ ] R: `future::plan("sequential")`; `LINGOFUSE_RUNTIME`.
- [ ] PHP/browser/Delphi JSON: `bridge.py` / `bridge.exe` running; endpoint matching; CORS.
- [ ] No conflict on port 9898 or the IPC address; `Overlap_Connection` set as needed.
- [ ] Cleanup order: `ExitMainThread → FreeApp → Shutdown`; stop any dispatcher first.

---

**End of document**


