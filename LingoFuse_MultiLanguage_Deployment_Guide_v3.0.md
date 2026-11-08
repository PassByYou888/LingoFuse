# LingoFuse 多语言部署指南（v3.0）

> **口径**：18 种一方绑定 = 17 种原生 FFI + 1 种经 bridge 的 PHP。浏览器 JavaScript、Delphi 走 HTTP/JSON + bridge。  

---

## 目录（点击跳转）

| # | 语言 | 方案一 | 方案二 | 硬性版本 | 跳转 |
|:---:|:---|:---|:---|:---|:---:|
| 1 | [Pascal](#1-pascal) | [Lazarus](https://www.lazarus-ide.org/) + [FPC](https://www.freepascal.org/download.var) | [Delphi / RAD Studio](https://www.embarcadero.com/products/delphi) | FPC 3.2.2+ / Delphi 10.4+ | [⬇️](#1-pascal) |
| 2 | [Python](#2-python) | [VS Code](https://code.visualstudio.com/) + [Pylance](https://marketplace.visualstudio.com/items?itemName=ms-python.vscode-pylance) | [PyCharm](https://www.jetbrains.com/pycharm/) | Python 3.8+ | [⬇️](#2-python) |
| 3 | [C++](#3-c) | [VS Code](https://code.visualstudio.com/) + [MinGW/MSYS2](https://www.msys2.org/) + [CMake](https://cmake.org/download/) | [Visual Studio 2022](https://visualstudio.microsoft.com/vs/community/) / [CLion](https://www.jetbrains.com/clion/) | C++17 | [⬇️](#3-c) |
| 4 | [C#](#4-c-1) | [VS Code](https://code.visualstudio.com/) + [C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit) | [Visual Studio 2022](https://visualstudio.microsoft.com/vs/community/) / [Rider](https://www.jetbrains.com/rider/) | .NET 6+ | [⬇️](#4-c-1) |
| 5 | [Rust](#5-rust) | [VS Code](https://code.visualstudio.com/) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer) | [CLion](https://www.jetbrains.com/clion/) / [RustRover](https://www.jetbrains.com/rust/) | edition 2021 | [⬇️](#5-rust) |
| 6 | [Go](#6-go) | [VS Code](https://code.visualstudio.com/) + [Go 插件](https://marketplace.visualstudio.com/items?itemName=golang.Go) | [GoLand](https://www.jetbrains.com/go/) | Go 1.21+ | [⬇️](#6-go) |
| 7 | [Java](#7-java) | [VS Code](https://code.visualstudio.com/) + [Java Pack](https://marketplace.visualstudio.com/items?itemName=vscjava.vscode-java-pack) | [IntelliJ IDEA](https://www.jetbrains.com/idea/) / [Eclipse](https://www.eclipse.org/downloads/) | **JDK 22+ / Maven 3.9+** | [⬇️](#7-java) |
| 8 | [Node.js](#8-nodejs) | [VS Code](https://code.visualstudio.com/) | [WebStorm](https://www.jetbrains.com/webstorm/) | Node 18+ | [⬇️](#8-nodejs) |
| 9 | [TypeScript](#9-typescript) | [VS Code](https://code.visualstudio.com/)（内置 TS） | [WebStorm](https://www.jetbrains.com/webstorm/) | TS 5.6+ / Node 18+ | [⬇️](#9-typescript) |
| 10 | [Erlang](#10-erlang) | [VS Code](https://code.visualstudio.com/) + [Erlang 插件](https://marketplace.visualstudio.com/items?itemName=pguyot.erlang) | [IntelliJ IDEA](https://www.jetbrains.com/idea/) + Erlang 插件 | OTP 27+ | [⬇️](#10-erlang) |
| 11 | [Julia](#11-julia) | [VS Code](https://code.visualstudio.com/) + [Julia 插件](https://marketplace.visualstudio.com/items?itemName=julialang.language-julia) | [Jupyter](https://jupyter.org/install) + IJulia | Julia 1.9+ | [⬇️](#11-julia) |
| 12 | [Zig](#12-zig) | [VS Code](https://code.visualstudio.com/) + [Zig Lang Support](https://marketplace.visualstudio.com/items?itemName=mitchellh.vscode-zig) | [Neovim](https://neovim.io/) + [ZLS](https://github.com/zigtools/zls) | **Zig 0.17.0（严格）** | [⬇️](#12-zig) |
| 13 | [Swift](#13-swift) | [VS Code](https://code.visualstudio.com/) + [Swift 插件](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode) | [Xcode](https://developer.apple.com/xcode/)（仅 macOS） | Swift 5.9+ | [⬇️](#13-swift) |
| 14 | [Ruby](#14-ruby) | [VS Code](https://code.visualstudio.com/) + [Ruby LSP](https://marketplace.visualstudio.com/items?itemName=Shopify.ruby-lsp) | [RubyMine](https://www.jetbrains.com/ruby/) | Ruby 4.0+ | [⬇️](#14-ruby) |
| 15 | [Fortran](#15-fortran) | [VS Code](https://code.visualstudio.com/) + [Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran) + [fortls](https://pypi.org/project/fortls/) | [Code::Blocks](https://www.codeblocks.org/) / [Simply Fortran](https://simplyfortran.com/) | Fortran 2008 + C++17 | [⬇️](#15-fortran) |
| 16 | [Dart](#16-dart) | [VS Code](https://code.visualstudio.com/) + [Dart 插件](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code) | [IntelliJ IDEA](https://www.jetbrains.com/idea/) / [Android Studio](https://developer.android.com/studio) | Dart 3.0+ | [⬇️](#16-dart) |
| 17 | [R](#17-r) | [RStudio](https://posit.co/download/rstudio-desktop/) | [VS Code](https://code.visualstudio.com/) + [R 扩展](https://marketplace.visualstudio.com/items?itemName=REditorSupport.r) | R 4.0+ / Rtools45 | [⬇️](#17-r) |
| 18 | [PHP](#18-php) | `bridge.py` HTTP 网关 | `bridge.exe` HTTP 网关 | PHP + curl | [⬇️](#18-php) |
| 19 | [浏览器 JavaScript](#19-browser-javascript) | `bridge.py` + Fetch | `code_decl_to_json_abi` 生成 JS | 现代浏览器 | [⬇️](#19-browser-javascript) |
| 20 | [Delphi](#20-delphi) | RAD Studio 原生 Pascal | `code_decl_to_json_abi` Delphi Call | Delphi 10.4+ | [⬇️](#20-delphi) |

---

## 当前检查机环境基线

| 语言 | 工具 | 检查结果 | 跳转 |
|---|---|---|---|
| Pascal | fpc | 3.2.2 OK | [Pascal](#1-pascal) |
| Python | python | 3.14.7 OK | [Python](#2-python) |
| C++ | gcc / g++ / cmake | 16.1.0 / 16.1.0 / 3.31.2 OK | [C++](#3-c) |
| C# | dotnet | 9.0.316 OK | [C#](#4-c-1) |
| Rust | cargo / rustc | 1.97.1 / 1.97.1 OK | [Rust](#5-rust) |
| Go | go | 1.25.0 windows/amd64 OK | [Go](#6-go) |
| Java | java / mvn | OK（含 Windows 多处理器组警告） | [Java](#7-java) |
| Node.js | node / npm | v24.21.0 / 11.19.0 OK | [Node.js](#8-nodejs) |
| TypeScript/http_ts | node / npm | v24.21.0 / 11.19.0 OK | [TypeScript](#9-typescript) |
| Erlang | erl / erlc / escript | erl 29 OK；erlc 无版本输出；escript Missing filename 属正常 | [Erlang](#10-erlang) |
| Julia | julia | 1.13.1 OK | [Julia](#11-julia) |
| Zig | zig | 0.17.0 OK | [Zig](#12-zig) |
| Swift | swift | 6.4 OK | [Swift](#13-swift) |
| Ruby | ruby | 4.0.7 x64-mingw-ucrt OK | [Ruby](#14-ruby) |
| Fortran | gfortran | 16.1.0 OK | [Fortran](#15-fortran) |
| Dart | dart | 3.6.2 OK | [Dart](#16-dart) |
| R | Rscript | 4.6.1 OK | [R](#17-r) |

> PHP、浏览器 JavaScript、Delphi JSON Call、`bridge.py` 运行状态不在该脚本检查范围内，需单独验证。

---

## 1. Pascal

- **方案一**：[Lazarus](https://www.lazarus-ide.org/) + [Free Pascal](https://www.freepascal.org/download.var)。
- **方案二**：[Delphi / RAD Studio](https://www.embarcadero.com/products/delphi)。
- **硬性版本**：FPC 3.2.2+ 或 Delphi 10.4+。当前 `fpc 3.2.2` 通过。
- **附加说明**：
  - **额外库**：无第三方库；依赖 RTL `SysUtils`、`Classes`、`SyncObjs`。
  - **注意事项**：回调必须 `cdecl`；跨编译器保留 `{$IFDEF FPC}`；Delphi 保存 `.pas` 建议 UTF-8 with BOM；`LF_LocalCall` / `LF_LocalNotify` 不注入发送方身份，需要身份用 `LF_Call` 命中本地短路。
- **验证**：`fpc -iV`。
- **下载/文档**：[Free Pascal](https://www.freepascal.org/download.var)、[Lazarus](https://www.lazarus-ide.org/)、[Delphi](https://www.embarcadero.com/products/delphi)。

___

## 2. Python

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Pylance](https://marketplace.visualstudio.com/items?itemName=ms-python.vscode-pylance)。
- **方案二**：[PyCharm](https://www.jetbrains.com/pycharm/)。
- **硬性版本**：Python 3.8+。当前 `Python 3.14.7` 通过。
- **附加说明**：
  - **额外库**：仓库 `py/` 下 `pip install -e .`；`bridge.py` 依赖见 `py/requirements.txt`。PyPI 名称在不同文档中有 `py-lingofuse` / `lingofuse` 两种说法，部署建议优先用本地 editable 避免歧义。
  - **注意事项**：同步族 handle 归调用者；异步族归框架，回调返回后立即释放；异步回调内完成所有操作，禁止跨线程保留裸 handle；`_Aio` 在 `asyncio.run()` 内 await；`_Async` 返回 `CallFuture`；回调需 `@server.expose` 或显式 `CFUNCTYPE`。
- **验证**：`python --version`；`python -c "import lingofuse"`。
- **下载/文档**：[Python Windows](https://www.python.org/downloads/windows/)、[VS Code](https://code.visualstudio.com/)、[PyCharm](https://www.jetbrains.com/pycharm/)。

___

## 3. C++

- **方案一**：[VS Code](https://code.visualstudio.com/) + [MSYS2/MinGW-w64](https://www.msys2.org/) + [CMake](https://cmake.org/download/)。
- **方案二**：[Visual Studio 2022 Community](https://visualstudio.microsoft.com/vs/community/) / [CLion](https://www.jetbrains.com/clion/)。
- **硬性版本**：C++17。当前 `gcc/g++ 16.1.0`、`cmake 3.31.2` 通过。
- **附加说明**：
  - **额外库**：标准库 + `LingoFuse.hpp` / `lf_io.hpp` / `LingoFuse.c`；无第三方。
  - **注意事项**：必须先调用 `LF_LoadLibrary()` 并检查返回 1；MSVC 必须 `/utf-8`；CMake 必须 `project(name C CXX)`，否则 `Cannot determine link language`；异步回调内拷贝数据，不要 `dispose` 异步 `Result_`；运行时 DLL 手动放 exe 旁或 `PATH`。
- **验证**：`g++ --version`、`cmake --version`。
- **下载/文档**：[MSYS2](https://www.msys2.org/)、[CMake](https://cmake.org/download/)、[VS 2022](https://visualstudio.microsoft.com/vs/community/)、[CLion](https://www.jetbrains.com/clion/)。

___

## 4. C#

- **方案一**：[VS Code](https://code.visualstudio.com/) + [C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit)。
- **方案二**：[Visual Studio 2022 Community](https://visualstudio.microsoft.com/vs/community/) / [Rider](https://www.jetbrains.com/rider/)。
- **硬性版本**：.NET 6+。当前 `dotnet 9.0.316` 通过。
- **附加说明**：
  - **额外库**：`LingoFuse` C# 项目引用或 NuGet；无第三方。
  - **注意事项**：**生成的库必须没有 `Main`**，否则 `CS0017`；异步回调用 `TaskCompletionSource` + `RunContinuationsAsynchronously`；`DllImportResolver` 自动选平台库，DLL 复制到 bin；`using` 块外不要保留 `DataHandle` 引用。
- **验证**：`dotnet --version`。
- **下载/文档**：[.NET SDK](https://dotnet.microsoft.com/download)、[C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit)、[Rider](https://www.jetbrains.com/rider/)。

___

## 5. Rust

- **方案一**：[VS Code](https://code.visualstudio.com/) + [rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)。
- **方案二**：[CLion](https://www.jetbrains.com/clion/) / [RustRover](https://www.jetbrains.com/rust/)。
- **硬性版本**：Rust edition 2021。当前 `cargo/rustc 1.97.1` 通过。
- **附加说明**：
  - **额外库**：`lingofuse` crate，通过 `Cargo.toml` 的 `path` 或 `git` 依赖。
  - **注意事项**：panic 必须 `catch_unwind`，用户回调也不建议 panic；异步签名 `FnOnce(Result<T, Error>) + Send + 'static`；`ABI_TARGET_APP` / `ABI_TIMEOUT` 是原子量；运行时 DLL 放 exe 旁或 `PATH`。
- **验证**：`cargo --version`、`rustc --version`。
- **下载/文档**：[rustup](https://rustup.rs/)、[rust-analyzer](https://marketplace.visualstudio.com/items?itemName=rust-lang.rust-analyzer)、[RustRover](https://www.jetbrains.com/rust/)。

___

## 6. Go

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Go 插件](https://marketplace.visualstudio.com/items?itemName=golang.Go)。
- **方案二**：[GoLand](https://www.jetbrains.com/go/)。
- **硬性版本**：Go 1.21+。当前 `go 1.25.0 windows/amd64` 通过。
- **附加说明**：
  - **额外库**：`github.com/PassByYou888/LingoFuse/go/lingofuse`；`go.mod` 用 `replace` 指向本地模块。
  - **注意事项**：Call 侧 `purego` 无 cgo；**Service 侧必须 `CGO_ENABLED=1`**；`sys.LoadLibrary()` 必须先调用；`param.Close()` 用 `defer`，确保异步回调结束后再释放；首次打开 Go 文件按提示 Install All 安装 `gopls` / `dlv` / `gofmt`。
- **验证**：`go version`。
- **下载/文档**：[Go SDK](https://go.dev/dl/)、[Go 插件](https://marketplace.visualstudio.com/items?itemName=golang.Go)、[GoLand](https://www.jetbrains.com/go/)。

___

## 7. Java

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Extension Pack for Java](https://marketplace.visualstudio.com/items?itemName=vscjava.vscode-java-pack)。
- **方案二**：[IntelliJ IDEA](https://www.jetbrains.com/idea/) / [Eclipse](https://www.eclipse.org/downloads/)。
- **硬性版本**：**JDK 22+，Maven 3.9+**。当前 `java` / `mvn` 通过，但带 Windows 多处理器组警告，可忽略。
- **附加说明**：
  - **额外库**：`jackson-databind 2.17.0`；LingoFuse Java jar 可通过 `<systemPath>` 引用。
  - **注意事项**：JDK 21 及以下不可用；`LibraryLoader.selectPlatformFileName()` 必须先调用；`-Djava.library.path` 指向原生库；`AsyncBridge.shutdownInstance()` 退出前必须调用；system scope jar 打包需 shade/assembly 手动包含；低于 22 报 `release version 22 not supported`。
- **验证**：
  ```powershell
  (& java -XshowSettings:properties -version 2>&1 | Out-String) -split "`n" | Select-String 'java\.version'
  (& mvn -v 2>&1 | Out-String) -split "`n" | Select-String 'Apache Maven'
  ```
- **下载/文档**：[JDK 22 Oracle](https://download.oracle.com/java/22/latest/jdk-22_windows-x64_bin.msi)、[Adoptium](https://adoptium.net/)、[Maven](https://maven.apache.org/download.cgi)、[Java Pack](https://marketplace.visualstudio.com/items?itemName=vscjava.vscode-java-pack)。

___

## 8. Node.js

- **方案一**：[VS Code](https://code.visualstudio.com/)。
- **方案二**：[WebStorm](https://www.jetbrains.com/webstorm/)。
- **硬性版本**：Node.js 18+。当前 `node v24.21.0`、`npm 11.19.0` 通过。
- **附加说明**：
  - **额外库**：`lingofuse-js`、`koffi`。
  - **注意事项**：`LF_Async_Call` 的 `data` 指针必须非 null（`op.dataPtr`）；`AsyncBridge` 的 timer **不能 `unref`**；`param` 必须在 promise settle 之后 dispose；`AsyncBridge.shutdownInstance()` 退出前必须调用；运行时 DLL 放项目根或 `PATH`。
- **验证**：`node -v`、`npm -v`。
- **下载/文档**：[Node.js](https://nodejs.org/)、[WebStorm](https://www.jetbrains.com/webstorm/)。

___

## 9. TypeScript

- **方案一**：[VS Code](https://code.visualstudio.com/)（内置 TS）。
- **方案二**：[WebStorm](https://www.jetbrains.com/webstorm/)。
- **硬性版本**：TypeScript 5.6+ / Node 18+。当前 `node v24.21.0`、`npm 11.19.0`，`http_ts` 检查通过。
- **附加说明**：
  - **额外库**：`lingofuse-ts`、`koffi`。
  - **注意事项**：`lingofuse-ts/package.json` 的 `exports` 必须加 `./dist/` 前缀；`tsconfig.json` 建议 `"module":"commonjs"`、`"esModuleInterop":true`；`CallPromise<T>` 只实现 `PromiseLike<T>`，`_race` 用 `PromiseLike<T>` 兜底；`tsc --noEmit` 零错误是硬要求。
- **验证**：`npx tsc --noEmit`。
- **下载/文档**：[Node.js](https://nodejs.org/)、[TypeScript](https://www.typescriptlang.org/download)、[WebStorm](https://www.jetbrains.com/webstorm/)。

___

## 10. Erlang

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Erlang 插件](https://marketplace.visualstudio.com/items?itemName=pguyot.erlang)。
- **方案二**：[IntelliJ IDEA Ultimate](https://www.jetbrains.com/idea/) + Erlang 插件。
- **硬性版本**：OTP 27+。当前 `erl 29` 通过；`erlc` 无版本输出、`escript: Missing filename` 属检查脚本正常现象。
- **附加说明**：
  - **额外库**：`lingofuse.beam`、`priv/lingofuse_nif.dll`、[rebar3](https://www.rebar3.org/)。
  - **注意事项**：ABI 层必须二进制 wire，禁止 JSON；NIF 层不 strip `#0`；Service main loop 必须处理 16 种消息形态：`lf_call` / `lf_p2p_call` / `lf_notify` / `lf_p2p_notify` × 有/无 `Identity` × 具体/通用；`lingofuse:reply/2` 只能调用一次，用 `_ =`；`Wait_Connection_ReadyOk=False` 时 SelfClient Link/上报异步，测试需 `sleep(15000)` 量级；NIF 崩溃会拖垮 BEAM。
- **验证**：
  ```powershell
  erl -eval "io:format(\"~s~n\",[erlang:system_info(otp_release)]),halt()." -noshell
  ```
- **下载/文档**：[Erlang/OTP](https://www.erlang.org/downloads)、[rebar3](https://www.rebar3.org/)、[Erlang 插件](https://marketplace.visualstudio.com/items?itemName=pguyot.erlang)。

___

## 11. Julia

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Julia 插件](https://marketplace.visualstudio.com/items?itemName=julialang.language-julia)。
- **方案二**：[Jupyter](https://jupyter.org/install) + IJulia。
- **硬性版本**：Julia 1.9+，**必须 `--threads=2`**。当前 `julia 1.13.1` 通过。
- **附加说明**：
  - **额外库**：`LingoFuse.jl`，`Pkg.develop(path="…")`。
  - **注意事项**：单线程会死锁；回调 consumer 不能落 main 线程；`@threadcall` 并发受 libuv 线程池约束，默认 4，可用 `UV_THREADPOOL_SIZE` 提升；`Project.toml` 不要手动改 UUID；Linux/macOS/Apple Silicon 尚未验证。
- **验证**：`julia --version`；运行时 `julia --threads=2`。
- **下载/文档**：[Julia](https://julialang.org/downloads/)、[Julia 插件](https://marketplace.visualstudio.com/items?itemName=julialang.language-julia)、[Jupyter](https://jupyter.org/install)。

___

## 12. Zig

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Zig Language Support](https://marketplace.visualstudio.com/items?itemName=mitchellh.vscode-zig) + [ZLS](https://github.com/zigtools/zls)。
- **方案二**：[Neovim](https://neovim.io/) + [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) 指向 `zls.exe`。
- **硬性版本**：**Zig 0.17.0（严格锁定）**。当前 `zig 0.17.0` 通过。
- **附加说明**：
  - **额外库**：`lingofuse` 模块、`c/lf_json.cpp`；无第三方。
  - **注意事项**：`build.zig.zon` 的 `minimum_zig_version = "0.17.0"`，0.16 / 0.18 不可编译；fingerprint 错误时 setup 脚本解析 `use this value: 0x…` 回填，最多重试 3 次；`[]const u8` 与 `[]u8` 语义不同，字符串参数用 `[]const u8`；Linux/macOS/32 位待测。
- **验证**：`zig version`。
- **下载/文档**：[Zig](https://ziglang.org/download/)、[ZLS](https://github.com/zigtools/zls)、[Zig VS Code 插件](https://marketplace.visualstudio.com/items?itemName=mitchellh.vscode-zig)。

___

## 13. Swift

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Swift 插件](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode)。
- **方案二**：[Xcode](https://developer.apple.com/xcode/)（仅 macOS）。
- **硬性版本**：Swift 5.9+，推荐 6.4。当前 `Swift 6.4` 通过。
- **附加说明**：
  - **额外库**：`LingoFuse` Swift Package、`CLingoFuse`。
  - **注意事项**：Windows 必须先装 [Visual Studio 2022](https://visualstudio.microsoft.com/vs/community/) “使用 C++ 的桌面开发”工作负载；SPM `.package(path:)` 的 identity 是路径最后一段小写，不是 `Package.swift` 的 `name`；Swift 6.4 `#NoUsage` 诊断可能误报 unused；macOS/Linux 部署路径尚未实测。
- **验证**：`swift --version`。
- **下载/文档**：[Swift Windows](https://www.swift.org/install/windows/)、[Swift 插件](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode)、[Xcode](https://developer.apple.com/xcode/)。

___

## 14. Ruby

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Ruby LSP](https://marketplace.visualstudio.com/items?itemName=Shopify.ruby-lsp)。
- **方案二**：[RubyMine](https://www.jetbrains.com/ruby/)。
- **硬性版本**：Ruby 4.0+（x64-mingw-ucrt）。当前 `ruby 4.0.7 x64-mingw-ucrt` 通过。
- **附加说明**：
  - **额外库**：`lingofuse` gem、`lingofuse_ext.so`；[RubyInstaller](https://rubyinstaller.org/) + DevKit/MSYS2 base；`gem install ruby-lsp`。
  - **注意事项**：`setup_ruby_tests.ps1 -RubyLibDir` 指向 `lib/` 目录；`at_exit` 顺序：`NativeBridge.stop` → `exit_main_thread` → `shutdown` → `Native.free_library`；`HTTP_CALL_BASE_URL` 只读，用 `Module.base_url = ...`；进程不退出用 `exit!`；异常退出可能导致 DLL 卸载后 dispatcher 线程访问冲突。
- **验证**：`ruby -v`。
- **下载/文档**：[RubyInstaller](https://rubyinstaller.org/)、[Ruby LSP](https://marketplace.visualstudio.com/items?itemName=Shopify.ruby-lsp)、[RubyMine](https://www.jetbrains.com/ruby/)。

___

## 15. Fortran

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran) + [fortls](https://pypi.org/project/fortls/)。
- **方案二**：[Code::Blocks](https://www.codeblocks.org/) / [Simply Fortran](https://simplyfortran.com/)。
- **硬性版本**：Fortran 2008 + C++17；C++ 与 Fortran 编译器必须同源。当前 `gfortran 16.1.0` 通过。
- **附加说明**：
  - **额外库**：`iso_c_binding`、`lf_fortran_mod`、`lf_fortran.cpp`、`LingoFuse.c/.h/.hpp`；通过 [MSYS2](https://www.msys2.org/) 安装 `mingw-w64-x86_64-gcc-fortran`。
  - **注意事项**：编译顺序 `LingoFuse.c`（gcc）→ `lf_fortran.cpp`（g++）→ `lf_fortran_mod.f90`（gfortran）；无 async 支持；`internal_call_<api>` 是 stub 返回零值；回调命名 `<api>_callback`，不是 `callback_<api>`；Linux/macOS 理论可行未实测。
- **验证**：`gfortran --version`。
- **下载/文档**：[MSYS2](https://www.msys2.org/)、[Modern Fortran](https://marketplace.visualstudio.com/items?itemName=fortran-lang.linter-gfortran)、[fortls](https://pypi.org/project/fortls/)、[Code::Blocks](https://www.codeblocks.org/)。

___

## 16. Dart

- **方案一**：[VS Code](https://code.visualstudio.com/) + [Dart 插件](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code)。
- **方案二**：[IntelliJ IDEA](https://www.jetbrains.com/idea/) / [Android Studio](https://developer.android.com/studio) + Dart 插件。
- **硬性版本**：Dart 3.0+。当前 `Dart 3.6.2` 通过。
- **附加说明**：
  - **额外库**：`lingofuse` Dart 包、`lf_dart_bridge.dll`；先 `dart pub get`。
  - **注意事项**：`BridgeHost.start()` 必须是 `main()` 第一行；`ABI_TARGET_APP` 必须 `const`，否则 `Isolate.run` 重新执行顶层代码时值不一致；Flutter Web 不可用；移动端建议 Call 经 bridge，Service 部署服务器；`dart analyze` 可能报 `non_constant_identifier_names`，生成文件头已加 `// ignore_for_file:`。
- **验证**：`dart --version`。
- **下载/文档**：[Dart SDK](https://dart.dev/get-dart/archive)、[Dart 插件](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code)、[Android Studio](https://developer.android.com/studio)。

___

## 17. R

- **方案一**：[RStudio](https://posit.co/download/rstudio-desktop/)。
- **方案二**：[VS Code](https://code.visualstudio.com/) + [R 扩展](https://marketplace.visualstudio.com/items?itemName=REditorSupport.r)。
- **硬性版本**：R 4.0+ / Rtools45。当前 `Rscript 4.6.1` 通过。
- **附加说明**：
  - **额外库**：`lingofuse` R 包；`bit64` 可选（int64/uint64 必需）；Rtools 可选（编译含 C/C++ 的 R 包时）。
  - **注意事项**：`LF_Call` 不可重入，单进程自测用 `lf_local_call`；`*_async` 必须 `future::plan("sequential")`，`multisession` / `multicore` 会 fork 导致运行时未初始化；停止服务推荐写 `service.exit` 哨兵文件，不用 Ctrl+C；受外部二进制依赖限制，无法提交 CRAN；设置 `LINGOFUSE_RUNTIME`。
- **验证**：`Rscript --version` 或 `R --version`。
- **下载/文档**：[R Windows](https://cran.r-project.org/bin/windows/base/)、[RStudio](https://posit.co/download/rstudio-desktop/)、[R 扩展](https://marketplace.visualstudio.com/items?itemName=REditorSupport.r)。

___

## 18. PHP

- **方案一**：`bridge.py` HTTP 网关。
- **方案二**：`bridge.exe` HTTP 网关。
- **硬性版本**：PHP + `curl` 扩展或 `allow_url_fopen=On`；`bridge.py` / `bridge.exe` 必须运行。
- **附加说明**：
  - **额外库**：仓库 `php/` 的 `lingofuse.php` HTTP 客户端封装；无原生 LingoFuse 库。
  - **注意事项**：PHP **只能作为 Call**，无 Service 侧能力；不能加载 `LingoFuse64.dll`；endpoint 必须与 bridge/服务一致；bridge 未运行则所有 Call 报网络错误。
- **示例**：
  ```php
  require_once 'lingofuse.php';
  $api = new LingoFuseApi('http://127.0.0.1:8081/<Unit>');
  $result = $api->call('Add', [1, 2]);
  ```
- **验证**：`php -v`；启动 bridge 后执行 PHP 调用；`curl` 直连 bridge API。
- **下载/文档**：[PHP](https://www.php.net/downloads)、[Bridge_User_Guide.md](py/lingofuse/Bridge_User_Guide.md)。

___

## 19. 浏览器 JavaScript

- **方案一**：`bridge.py` + [Fetch API](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API)。
- **方案二**：`code_decl_to_json_abi` 生成浏览器 JS Call 产物。
- **硬性版本**：现代浏览器；bridge 运行；CORS 配置。
- **附加说明**：
  - **额外库**：无原生库；需要 `bridge.py` / `bridge.exe`。
  - **注意事项**：浏览器不能原生 FFI；`file://` 下 fetch 受限，用 `python3 -m http.server` 提供页面；CORS 需 bridge 加 `--cors '*'`；`int64` 在 JS `Number` 丢精度，服务侧返回字符串；bridge 预检查缓存问题可 `--no-precheck`；`code=-3` / `-4` 查 bridge 版本/协议；浏览器端无 Service。
- **验证**：浏览器 Console fetch bridge URL；检查响应 `{"code":0,...}`。
- **下载/文档**：[Fetch API](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API)、[Bridge_User_Guide.md](py/lingofuse/Bridge_User_Guide.md)。

___

## 20. Delphi

- **方案一**：[RAD Studio](https://www.embarcadero.com/products/delphi) 原生 Pascal 绑定。
- **方案二**：`code_decl_to_json_abi` 生成 Delphi Call，经 `bridge.py` / `bridge.exe`。
- **硬性版本**：Delphi 10.4+。
- **附加说明**：
  - **额外库**：原生方案同 Pascal；JSON 方案需 `bridge.py` / `bridge.exe` 与生成 Delphi Call 单元。
  - **注意事项**：原生 Pascal 方案按 [Pascal](#1-pascal) 部署；`code_decl_to_json_abi` 的 Delphi 产物是 **Call**，不是 Service；不要把“Delphi 专用 JSON 产物”误当 Service；endpoint 必须与 bridge 一致。
- **验证**：RAD Studio 编译运行；JSON 方案先启动 bridge 再运行 Delphi Call。
- **下载/文档**：[Delphi / RAD Studio](https://www.embarcadero.com/products/delphi)、[Bridge_User_Guide.md](py/lingofuse/Bridge_User_Guide.md)。

___

## 附：通用部署检查清单

- [ ] `LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib` 在搜索路径。
- [ ] `z_ipc_64.dll`、`mimalloc64.dll`、`mimalloc-redirect.dll` 同目录或 `PATH`。
- [ ] Java：`java.library.path`、`lingofuse.jar`、Jackson。
- [ ] C#：库无 `Main`，DLL 复制到 bin。
- [ ] C++：`LF_LoadLibrary()` 已调用；MSVC `/utf-8`。
- [ ] Go Service：`CGO_ENABLED=1`；Call：purego。
- [ ] Erlang：`priv/lingofuse_nif.dll` 已复制。
- [ ] Ruby：`lingofuse_ext.so` 在 `lib/`；`at_exit` 顺序正确。
- [ ] Dart：`BridgeHost.start()` 第一行；`ABI_TARGET_APP` 为 `const`。
- [ ] Node/TS：`AsyncBridge` timer 未 `unref`；`shutdownInstance` 已调用。
- [ ] Julia：`--threads=2`。
- [ ] R：`future::plan("sequential")`；`LINGOFUSE_RUNTIME`。
- [ ] PHP/浏览器/Delphi JSON：`bridge.py` / `bridge.exe` 正在运行；endpoint 一致；CORS。
- [ ] 端口 9898 或 IPC 地址无冲突；`Overlap_Connection` 按需设置。
- [ ] 清理顺序：`ExitMainThread → FreeApp → Shutdown`；有 dispatcher 先停。

---

**文档结束**