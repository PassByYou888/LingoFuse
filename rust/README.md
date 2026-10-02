# LingoFuse Rust 接口 — 最终 README

> **跨语言通讯地基。不写 IDL，不生成桩代码，不搭 HTTP 服务。**
> 任何语言写的函数，任何其他语言都能直接调。

---

## 目录

- [这是什么](#这是什么)
- [为什么需要它](#为什么需要它)
- [Rust 绑定的定位](#rust-绑定的定位)
- [快速上手](#快速上手)
- [平台支持](#平台支持)
- [仓库结构](#仓库结构)
- [核心概念](#核心概念)
- [API 总览](#api-总览)
- [跨语言互操作](#跨语言互操作)
- [线协议契约](#线协议契约)
- [测试](#测试)
- [已知限制](#已知限制)
- [扩展路线](#扩展路线)
- [许可证](#许可证)

---

## 这是什么

LingoFuse 是一个**跨语言、跨进程、跨机器**的 RPC 框架。核心承诺一句话：

> **任何语言写的函数，任何其他语言都能直接调。**

不需要写 IDL，不需要生成桩代码，不需要搭 HTTP 服务。同机 IPC 延迟 < 1 ms，跨机原生支持，内置服务发现、负载均衡、FIFO 顺序保证和断线重连。

---

## 为什么需要它

跨语言调用目前的现实是：gRPC 要写 IDL、要生成桩代码、要搭网关；REST 延迟高、无流式、无服务发现；HTTP POST 天然跨机但无顺序保证、无服务发现；同进程调用延迟极低但不跨语言。

**每一种方案都只覆盖了一部分场景。** LingoFuse 把长处合并，把短板补上。

| 特性 | LingoFuse | gRPC | REST | HTTP POST |
|------|:---------:|:----:|:----:|:---------:|
| 跨机支持 | ✅ 原生 | ✅ 需网关 | ✅ 需网关 | ✅ 原生 |
| 跨语言 | **6 种一方 + 30+ 种经工具链** | 需生成代码 | 需手动封装 | ✅ 天然 |
| 请求-响应 | ✅ Call | ✅ | ✅ | ✅ |
| 流式 / 异步 | ✅ Notify | ⚠️ 需 stream | ❌ | ❌ |
| 类型安全 | ✅ 强类型 | ✅ 需 IDL | ❌ | ❌ |
| 服务发现 | ✅ 内置 | ❌ 需 etcd | ❌ 需 Nginx | ❌ |
| 负载均衡 | ✅ 内置 | ❌ 需 LB | ❌ 需 Nginx | ❌ |
| 顺序保证 | ✅ FIFO | ❌ | ❌ | ❌ |
| 断线重连 | ✅ 自动 | ❌ 需重试 | ❌ 需重试 | ❌ 需重试 |
| 零拷贝 | ✅ | ❌ | ❌ | ❌ |
| IDL 依赖 | **无** | 必需 | 无（需文档） | 无 |
| 桩代码生成 | **可选（自动）** | 必需 | 无 | 无 |

> ⚠️ **稳定第一，并发次要。** LingoFuse 把应用的稳定性放在第一位，并发性能往后挪移。一个在高并发下会偶发崩溃、丢消息或死锁的通讯层，延迟再低也没有意义。

---

## Rust 绑定的定位

Rust 在 LingoFuse 的官方定位中属于 **「经代码生成器 / 桥接支持」** 类别，接入路径为：

> **Rust / Go / Java / Kotlin / Swift / Ruby / Lua / Dart / Elixir / Julia / Zig / Nim / Crystal** → 经 LingoFuse-Tools 代码生成器接入

### 当前的 Rust 绑定实现

本目录（`rust/`）提供的 Rust 绑定走的是 **C ABI 直接绑定** 路线，与 C++ 绑定的架构一致：

| 层 | 模块 | 职责 |
|:--:|------|------|
| 原始 FFI | `sys` | 动态加载 C ABI，37 个导出函数，零生命周期管理 |
| 异常 | `error` | `Error` / `ErrorCode` 结构化错误 |
| 数据句柄 | `data_handle` | RAII `DataHandle`，支持字节、标量、NUL 结尾字符串 I/O |
| 统一 I/O | `io` | JSON / 字符串 / 字节的线协议契约 |
| 应用句柄 | `app_handle` | RAII `AppHandle`，带 panic 隔离的回调桥接 |
| 框架门面 | `framework` | 进程级操作：准备、调用、通知、关闭 |
| 网络事件 | `network_events` | 全局连接 / 断开事件处理 |
| 诊断 | `status` | 有界状态队列 |

**与 C++ 绑定的关系**：Rust 绑定在架构上 1:1 对齐 C++ 绑定（`LingoFuse.h` / `lf_io.hpp` / `LingoFuse.hpp`），只是把 RAII 换成了 Rust 的 `Drop`，把异常换成了 `Result`，把回调桥接换成了 `extern "C"` + `Box::into_raw` + `catch_unwind`。

### 与代码生成器的关系

LingoFuse-Tools 的 `code_decl_to_abi` 工具可以从 Pascal 单元或 C 头文件自动生成 ABI 服务端 / 调用端绑定，目标语言包括 Pascal / Python / C++ / C#。

Rust 绑定的角色是：**为代码生成器提供一个稳定的目标语言后端**。当 `code_decl_to_abi` 增加 Rust 目标时，生成的 Rust 代码将直接依赖本目录提供的 `lingofuse` crate。

---

## 快速上手

### 1. 准备动态库

从 LingoFuse 仓库的 `Binary/` 目录获取平台对应的核心库：

| 平台 | 核心库 | IPC 依赖 |
|------|--------|----------|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` |

**部署方式**：将 `Binary/` 目录加入系统 `PATH`，或把动态库复制到可执行文件同目录。

> Windows 下需安装 **VC++ 2015-2022 可再发行程序包**。

### 2. 添加依赖

```toml
[dependencies]
lingofuse = { path = "../rust" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

### 3. 服务端

```rust
use lingofuse::app_handle::AppHandle;
use lingofuse::{data_handle::DataHandle, framework, io};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct AddArgs { a: i32, b: i32 }

#[derive(Serialize)]
struct AddResult { sum: i32 }

fn main() -> Result<(), lingofuse::error::Error> {
    // 部署模式：不阻塞等待 mesh 就绪，便于弹性集群无序启动
    framework::set_option("Wait_Connection_ReadyOk", "False")?;
    framework::set_option("Quiet", "True")?;

    // 创建应用并注册 API
    let app = AppHandle::new("Calculator", "简单计算器")?;
    app.register_call("add", "两数相加", |input, output| {
        if let Ok(args) = io::read_json::<AddArgs>(input) {
            let _ = io::write_json(output, &AddResult { sum: args.a + args.b });
        }
    })?;

    // 准备并启动
    framework::reset_prepare();
    framework::prepare_service("ipc:calc", "ipc:calc")?;
    framework::prepare_client("ipc:calc", Some(&app))?;
    framework::prepare_done()?;

    println!("就绪，按回车退出。");
    std::io::stdin().read_line(&mut String::new()).ok();

    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
    Ok(())
}
```

### 4. 调用端

```rust
use lingofuse::{data_handle::DataHandle, framework, io};
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Serialize)]
struct AddArgs { a: i32, b: i32 }

#[derive(Deserialize)]
struct AddResult { sum: i32 }

fn main() -> Result<(), lingofuse::error::Error> {
    framework::set_option("Wait_Connection_ReadyOk", "False")?;
    framework::reset_prepare();
    framework::prepare_client("ipc:calc", None)?;
    framework::prepare_done()?;

    let mut req = DataHandle::new("add")?;
    io::write_json(&mut req, &AddArgs { a: 5, b: 7 })?;
    req.set_position(0)?;

    // 重试循环：mesh 广播到达本地缓存最多需要约 3 秒
    let mut response = None;
    for _ in 0..30 {
        match framework::try_call("Calculator", &req, 3000)? {
            Some(r) => { response = Some(r); break; }
            None => {
                req.set_position(0)?;
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    }

    let mut resp = response.expect("调用未在 6 秒内成功");
    resp.set_position(0)?;
    let out: AddResult = io::read_json(&mut resp)?;
    println!("5 + 7 = {}", out.sum);

    drop(resp);
    drop(req);
    framework::exit_main_thread();
    framework::shutdown();
    Ok(())
}
```

### 5. 编译运行

```bash
# 确保动态库在 PATH 中
export LD_LIBRARY_PATH=/path/to/LingoFuse/Binary:$LD_LIBRARY_PATH   # Linux
# set PATH=C:\path\to\LingoFuse\Binary;%PATH%                         # Windows

cargo run --bin server
cargo run --bin client
```

---

## 平台支持

| 平台 | 核心库文件 | Rust 目标三元组 |
|------|-----------|----------------|
| Windows 64 位 | `LingoFuse64.dll` | `x86_64-pc-windows-msvc` |
| Windows 32 位 | `LingoFuse32.dll` | `i686-pc-windows-msvc` |
| Linux | `liblingofuse.so` | `x86_64-unknown-linux-gnu` |
| macOS | `liblingofuse.dylib` | `x86_64-apple-darwin` / `aarch64-apple-darwin` |
| BSD | `liblingofuse.so` | 视发行版而定 |

Rust 绑定使用 `libloading` 在**运行时**动态加载共享库，不依赖构建期链接。搜索顺序：

1. 当前可执行文件所在目录
2. 当前工作目录
3. 系统加载器搜索路径（`PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`）

---

## 仓库结构

Rust 绑定在 LingoFuse 主仓库中的位置：

```
LingoFuse/
├── Binary/              # 预编译动态库（Win32 / Win64 / Linux / macOS）
├── cpp/                 # C++ 绑定
├── csharp/              # C# / .NET 绑定
├── ts/                  # TypeScript 绑定
├── js/                  # JavaScript 绑定（CommonJS + ESM）
├── pascal/              # Pascal 绑定
├── Py/                  # Python 绑定
├── rust/                # ★ Rust 绑定（本目录）
│   ├── Cargo.toml
│   ├── README.md        # ← 本文件
│   ├── src/
│   │   ├── lib.rs               # crate 根
│   │   ├── error.rs             # Error / ErrorCode
│   │   ├── data_handle.rs       # RAII DataHandle + Scalar trait
│   │   ├── io.rs                # 统一 JSON / 字符串 / 字节 I/O
│   │   ├── app_handle.rs        # RAII AppHandle + 回调桥接
│   │   ├── framework.rs         # 进程级门面
│   │   ├── network_events.rs    # 全局 connect/disconnect 事件
│   │   ├── status.rs            # 状态队列
│   │   └── sys/
│   │       ├── mod.rs
│   │       ├── bindings.rs      # 37 个 C ABI typedef
│   │       └── loader.rs        # 动态库加载 + 符号解析
│   └── tests/
│       ├── abi_smoke.rs         # 原始 ABI 冒烟测试
│       └── framework_e2e.rs     # 端到端集成测试
├── test/                # CI 测试接口
└── src/                 # Pascal 主库源码
```

---

## 核心概念

### 数据句柄（DataHandle）

数据句柄是 LingoFuse 的**基本原语**：一个带 API 名称的字节缓冲区，带读 / 写游标。

两种句柄：

| 类型 | 构造方式 | 空闲回收 | 释放时机 |
|------|---------|:--------:|----------|
| **自动回收** | `DataHandle::new` | 10 分钟空闲后由池扫描回收（每 5 秒扫描一次） | `Drop` 标记删除，下次扫描实际释放 |
| **永久** | `DataHandle::create_permanent` | 永不自动回收 | `Drop` 同步释放 |

> ⚠️ **「永久」不等于「永不释放」**。永久句柄只是不参与自动回收，你仍然必须显式 `Drop`。

### 应用句柄（AppHandle）

应用句柄是一个**命名容器**，包含一组相关 API。它是网络路由的基本单位：调用方指定 `(应用名, API名)`，mesh 将调用分发到托管该应用的一个客户端。

### 调用模式

| 模式 | 语义 | 顺序保证 | 返回 |
|------|------|:--------:|------|
| **Call** | 请求-响应，同步 | — | ✅ |
| **Notify** | 单向通知 | ❌ | ❌ |
| **Sequenced Notify** | 单向通知 | ✅（同一 `(app, api)` 对内 FIFO） | ❌ |

### 回调契约

注册的回调在**原生 worker 线程**上执行。三条规则：

1. **不要阻塞**。一个长时间运行的回调会占用原生线程池中的一个线程。
2. **不要调用任何阻塞型 LingoFuse 函数**（`LF_Call`、`LF_LocalCall`、`LF_PrepareDone`、`LF_Shutdown`）。这会死锁原生调度器。
3. **不要 panic**。Rust 绑定在 FFI 边界用 `catch_unwind` 隔离了 panic，但被捕获的 panic 仍然会中断当前回调。优先返回错误载荷，而非展开栈。

---

## API 总览

### `sys` — 原始 FFI 层

完整映射 `LingoFuse.h` 的 37 个导出函数，无生命周期管理。

```rust
use lingofuse::sys;

let lib = sys::load_library()?;
let hnd = unsafe { (lib.lf_create_data)(c_name.as_ptr()) };
```

### `error` — 结构化异常

```rust
use lingofuse::error::ErrorCode;

match framework::try_call("App", &param, 3000) {
    Ok(Some(resp)) => { /* 成功 */ }
    Ok(None) => { /* 超时或目标不可达 */ }
    Err(e) if e.code() == ErrorCode::Timeout => { /* 重试 */ }
    Err(e) => eprintln!("致命错误：{}", e),
}
```

### `data_handle` — RAII 数据句柄

```rust
use lingofuse::data_handle::DataHandle;

let mut h = DataHandle::new("my_api")?;
h.write(42i32)?;          // 标量写入（小端）
h.write_string("你好")?;   // NUL 结尾 UTF-8
h.set_position(0)?;
let n: i32 = h.read()?;
let s = h.read_string()?;
```

### `io` — 统一 JSON / 字节 I/O

```rust
use lingofuse::io;

io::write_json(&mut h, &request)?;
h.set_position(0)?;
let response: MyResponse = io::read_json(&mut h)?;

// 非 JSON 载荷（原始字节、无效 UTF-8）
match io::read_json_or_bytes(&mut h)? {
    io::JsonOrBytes::Json(v) => { /* 有效 JSON */ }
    io::JsonOrBytes::Bytes(b) => { /* 原始字节 */ }
    io::JsonOrBytes::Empty => { /* 空 */ }
}
```

### `app_handle` — 应用句柄与回调

```rust
use lingofuse::app_handle::AppHandle;

let app = AppHandle::new("MyApp", "描述")?;

app.register_call("add", "加法", |input, output| {
    // input / output 是借用的 DataHandle，不要 dispose
    // 不要阻塞，不要调用阻塞型 LF 函数
})?;

app.register_notify("log", "日志", |input| {
    // 单向，无输出
})?;

let resp = app.local_call(&param)?;  // 进程内调用，不走网络
app.bind()?;                         // 绑定到空闲客户端
```

### `framework` — 进程级门面

```rust
use lingofuse::framework;

// 网络准备
framework::reset_prepare();
framework::prepare_service("ipc:my_node", "ipc:my_node")?;
framework::prepare_client("ipc:my_node", Some(&app))?;
framework::prepare_done()?;

// 远程调用
let resp = framework::try_call("RemoteApp", &param, 3000)?;
framework::notify("RemoteApp", &param)?;
framework::sequenced_notify("RemoteApp", &param)?;

// 运行时选项
framework::set_option("Overlap_Connection", "True")?;
framework::set_option("Wait_Connection_Timeout", "60000")?;

// 健康检查（有约 3 秒缓存延迟）
framework::check_app("RemoteApp")?;
framework::check_api("RemoteApp", "add")?;

// 关闭
framework::exit_main_thread();
framework::shutdown();
```

### `network_events` — 全局事件

```rust
use lingofuse::network_events::{set_network_event, clear_network_event};

set_network_event(
    Some(Box::new(|addr| println!("[+] 已连接：{}", addr))),
    Some(Box::new(|addr| println!("[-] 已断开：{}", addr))),
)?;

// ... 运行框架 ...

clear_network_event()?;
```

### `status` — 状态队列

```rust
use lingofuse::status;

status::post_status("自定义日志")?;
for msg in status::drain_status(64)? {
    println!("[LF] {}", msg);
}
```

---

## 跨语言互操作

LingoFuse 的核心价值是**跨语言**。Rust 绑定与 Pascal / Python / C++ / C# / TypeScript / JavaScript 共享**完全相同的线协议**。

### 跨语言能力对照

| 语言 | 定位 | 状态 | 接入方式 |
|------|------|:----:|----------|
| **Pascal** | 核心引擎来源 | 生产就绪 | 原生 FFI |
| **Python** | 第一方绑定 | 生产就绪 | `pip install -e .` |
| **C++** | 第一方绑定 | 生产就绪 | 原生 C ABI，零开销 |
| **C# / .NET** | 第一方绑定 | 生产就绪 | 完整 .NET 绑定 |
| **TypeScript** | 第一方绑定 | 生产就绪 | 完整类型定义 |
| **JavaScript** | 第一方绑定 | 生产就绪 | CommonJS + ESM |
| **Rust** | 代码生成器目标 | ⏳ 接入中 | 本目录 C ABI 绑定 |
| **Node.js / PHP / 浏览器** | HTTP 桥接 | ✅ 可用 | `bridge.py` 网关 |
| **Go / Java / Kotlin / Swift / Ruby / Lua / Dart / Elixir / Julia / Zig / Nim / Crystal** | 代码生成器 | ⏳ 接入中 | LingoFuse-Tools |
| **aarch64 / loongarch64 / RISC-V** | 边缘设备移植 | ⏳ 推进中 | — |

### 跨语言调用示例

**Rust 服务端 + Python 调用端**

Rust 端注册 API：

```rust
app.register_call("echo", "回显", |input, output| {
    if let Ok(s) = io::read_json::<String>(input) {
        let _ = io::write_json(output, &s);
    }
})?;
```

Python 端调用：

```python
from lingofuse import C4
client = C4("RustApp", "ipc:my_node")
result = client.echo("hello from Python")
```

**Python 服务端 + Rust 调用端**

```rust
let mut req = DataHandle::new("compute")?;
io::write_json(&mut req, &serde_json::json!({"expression": "1+2*3"}))?;
req.set_position(0)?;
let resp = framework::try_call("PythonApp", &req, 5000)?;
```

---

## 线协议契约

**所有语言绑定共享完全相同的字节级契约。** 这是 Rust 绑定能与其它 6 种语言互操作的基础。

### 核心规则

| 规则 | 说明 |
|------|------|
| **UTF-8** | 所有文本均为 UTF-8 编码 |
| **字面非 ASCII** | 绝不用 `\uXXXX` 转义。`你好` 在线路上是 `E4 BD A0 E5 A5 BD`，不是 `\u4f60\u597d` |
| **NUL 结尾** | 字符串格式为 `[UTF-8 字节][0x00]` |
| **小端序** | 所有整数均为小端序 |
| **容错读取** | 若缓冲区中无 NUL，读取方消费所有剩余字节 |

### 三态读取规则

| 情况 | 条件 | 结果 | 新游标 |
|:----:|------|------|--------|
| 1 | 在偏移 `n` 处找到 NUL | 字节 `[start, start+n)` | `start + n + 1` |
| 2 | 无 NUL | 字节 `[start, size)` | `size + 1` |
| 3 | `start >= size` | 空 | 不变 |

情况 2 将游标移到缓冲区末尾之后一个字节。原生库会自动将缓冲区增长一个字节来容纳新位置——这与 Pascal 的 `LF_SetPos(Hnd, e + 1)` 完全一致。

### JSON 序列化策略

Rust 绑定的 `io` 模块是**唯一**被认可的结构化 I/O 路径：

- **紧凑输出**：无缩进、无尾随换行
- **字面 UTF-8**：非 ASCII 字符以字面 UTF-8 输出，与 Python 的 `ensure_ascii=False`、C++ 的 `error_handler_t::replace`、C# 的 `UnsafeRelaxedJsonEscaping` 策略一致
- **无 panic**：序列化失败返回 `ErrorCode::WriteFailed`，解析失败返回 `ErrorCode::ReadFailed`

---

## 测试

### 测试分层

| 层级 | 命令 | 依赖原生库 | 说明 |
|------|------|:----------:|------|
| 单元测试 | `cargo test --lib` | 部分 | 54 通过，11 忽略（不触及 native 全局状态） |
| 忽略的单元测试 | `cargo test --lib -- --ignored --test-threads=1` | ✅ | 11 通过（修改进程级 native 状态，需串行） |
| ABI 冒烟测试 | `cargo test --test abi_smoke` | ✅ | 5 通过（原始 C ABI 层） |
| 端到端集成测试 | `cargo test --test framework_e2e -- --ignored --test-threads=1` | ✅ | 2 通过（完整调用 + 通知流程） |

### 为什么部分测试是 `#[ignore]`

进程级 native 状态（框架准备 / 关闭、网络事件、状态投递）**只能串行访问**。Rust test harness 默认并发运行测试，与之冲突。`#[ignore]` 是标准的隔离机制——不改变生产代码，只改变测试运行策略。

### 原生库缺失时的行为

所有集成测试在原生库缺失时打印 `[SKIP]` 并提前返回，测试仍然显示 `ok`。要确认测试是否真正运行，加 `--nocapture` 查看是否有 `[SKIP]` 行：

```bash
cargo test --test abi_smoke -- --nocapture 2>&1 | grep SKIP
# 无输出 → 原生库已加载，测试真实运行
# 输出 [SKIP] → 原生库未找到，测试被跳过
```

### 测试数据（真实运行结果）

以下是在 LingoFuse v3.10 native 库下的实测结果：

```
cargo test --lib                                          → 54 passed, 0 failed, 11 ignored
cargo test --lib -- --ignored --test-threads=1            → 11 passed, 0 failed
cargo test --test abi_smoke                               → 5 passed, 1 ignored
cargo test --test framework_e2e -- --ignored --test-threads=1 → 2 passed, 0 failed
```

端到端测试日志中的 `add call timeout` 是**预期的**——第一次调用时 mesh 广播尚未到达本地缓存，重试循环在 200ms 后成功。这验证了完整的「准备 → 连接 → App 注册 → 广播 → 路由 → 回调 → 返回」链路。

---

## 已知限制

### 1. 单进程端到端测试

`tests/framework_e2e.rs` 中服务端和调用端在同一进程内运行，因此 `LF_Call` 走的是 mesh 的**本地优先路由**路径。它确实流经完整的原生调用链（打包、分发、解包、调用回调、打包结果、返回），但没有跨越 TCP 或跨进程 IPC 跳。跨进程验证需要两个独立 OS 进程。

### 2. 回调上下文泄漏

每个注册的 API 会泄漏一个小的上下文对象（几十字节），直到进程退出。这是刻意的设计权衡：

- 原生库可能在注册后的任意时间（包括与取消注册并发时）调用回调。回收会造成 use-after-free 窗口。
- 代价有界：一个上下文只有几十字节，每个应用注册的 API 数量通常很小。

如果应用需要在一个紧密循环中注册和取消注册 API，请联系维护者——需要一套引用计数方案（及其相关重入分析）。

### 3. `AppHandle` 不实现 `Send` / `Sync`

绑定刻意将句柄所有权限制在单线程。回调仍然在原生 worker 线程上运行，因此闭包必须满足 `Fn + Send + Sync`。

### 4. 状态队列的 ABI 限制

原生 ABI 无法区分「空队列」和「空消息」：两者都产生空字符串。需要区分的调用方必须先调用 `get_status_count()`。

### 5. `generate_app_name` 指针有效期

`LF_Generate_AppName` 返回的指针仅有约 5 秒有效期。Rust 绑定立即将其复制到 `String`，因此调用方安全。但如果你绕过 Rust 绑定直接使用 `sys` 层，必须自行处理。

### 6. CI 覆盖

LingoFuse 的自动化 CI 目前**只有 C++ 的**。Rust 绑定的测试需要在本地运行（`test/` 提供指南和预编译可执行文件）。这与仓库「把测试能力直接交到使用者手里」的做法一致。

---

## 扩展路线

### 短期

| 方向 | 说明 |
|------|------|
| **HTTP 桥接客户端** | 对应 `lf_http_bridge_client.hpp`，通过 LingoFuse mesh 调用 `bridge.py`，实现「Rust ↔ HTTP」和「Rust → JSON repair」 |
| **serde 便利层** | 例如 `AppHandle::register_call_json<T, R>`，把类型转换封装在框架内 |
| **跨进程端到端测试** | 两个独立 Rust 进程 + 一个 Pascal beacon，验证完整的跨语言 mesh 交互 |

### 中期

| 方向 | 说明 |
|------|------|
| **LingoFuse-Tools Rust 后端** | 让 `code_decl_to_abi` 支持 Rust 目标语言，自动生成类型安全的调用桩 |
| **异步 API** | 基于 `tokio` 的异步调用封装 |
| **过程宏** | `#[lingofuse_api]` 宏，自动注册 API 并生成类型安全的调用端 |

### 长期

| 方向 | 说明 |
|------|------|
| **MCP 工具提供者** | 通过 `code_decl_to_mcp` 生成 Rust 端的 MCP 工具 |
| **no_std 支持** | 面向边缘设备的精简绑定 |

---

## 许可证

**MIT** —— 拿去用，拿去改，拿去卖，都不用来谢我。

---

## 关于作者

**老张（QQ: 600585）** 看不惯跨语言调用得写一箩筐胶水代码，干脆撸了 LingoFuse。现在又看不惯每种语言都得手写绑定，干脆把代码生成器也撸完了。再把知识库喂给 AI，让 AI 自己把接口全部接管。

**让所有编程语言平等对话** —— 不是口号，是正在发生的事。

---

*Rust 绑定版本：Stage 1 + Stage 2 完成（C ABI 层 + 安全封装层）*
*对应 LingoFuse 版本：v3.10 / C4 v4.01*
*本文档最后更新：2026-10-02*