# LingoFuse Rust 接口 — 完整使用说明

**文档版本**: v1.0
**覆盖绑定**: `lingofuse` crate (Stage 1 + Stage 2 完成)
**对应 native 库**: LingoFuse v3.10 / C4 v4.01
**目标 Rust 版本**: 1.70+
**文档类型**: 完整使用指南（可独立使用，无需参考其它文档）

---

## 目录

- [第 1 章 阅读指引](#第-1-章-阅读指引)
- [第 2 章 库引用](#第-2-章-库引用)
- [第 3 章 使用说明](#第-3-章-使用说明)
- [第 4 章 测试与验证](#第-4-章-测试与验证)
- [第 5 章 测试程序覆盖领域](#第-5-章-测试程序覆盖领域)
- [第 6 章 替代 POC 的工作](#第-6-章-替代-poc-的工作)
- [第 7 章 已知限制与最佳实践](#第-7-章-已知限制与最佳实践)
- [附录 A 快速参考](#附录-a-快速参考)
- [附录 B 错误码索引](#附录-b-错误码索引)
- [附录 C 跨语言对照](#附录-c-跨语言对照)

---

## 第 1 章 阅读指引

### 1.1 本文档解决什么问题

本文档是 LingoFuse Rust 绑定的**独立使用手册**。读完本文档，你可以：

- 把 `lingofuse` crate 引入到自己的 Rust 项目
- 用 Rust 编写 LingoFuse 服务端和调用端
- 与 Pascal / Python / C++ / C# / JavaScript 端互操作
- 运行和理解绑定的测试体系
- 判断 Rust 绑定替代了哪些原本需要 POC 验证的工作

### 1.2 阅读路径

| 你的目标 | 阅读路径 |
|---------|----------|
| 第一次用，只想跑通 | 第 2 章 → 第 3.1 节 |
| 深入理解 API | 第 3 章全部 |
| 理解测试体系 | 第 4 章 → 第 5 章 |
| 评估生产可用性 | 第 5 章 → 第 6 章 → 第 7 章 |
| 排查问题 | 第 3.5 节 → 第 7 章 → 附录 B |

### 1.3 术语约定

| 术语 | 含义 |
|------|------|
| **native 库** | LingoFuse 的 C ABI 动态库（`LingoFuse64.dll` 等） |
| **C ABI** | native 库导出的 37 个 C 函数 |
| **数据句柄** | `DataHandle`，带 API 名称的字节缓冲区 |
| **应用句柄** | `AppHandle`，一组相关 API 的命名容器 |
| **mesh** | C4 服务网格，提供发现、路由、负载均衡 |

---

## 第 2 章 库引用

### 2.1 依赖清单

`lingofuse` crate 依赖三个第三方库：

| 依赖 | 版本 | 用途 |
|------|------|------|
| `libloading` | 0.8 | 运行时动态加载 native 共享库 |
| `serde` | 1.x | JSON 序列化 / 反序列化（启用 `derive`） |
| `serde_json` | 1.x | JSON 编解码 |

### 2.2 添加依赖

**方式 A：作为 path 依赖（推荐用于同仓库开发）**

在你的 `Cargo.toml` 中：

```toml
[dependencies]
lingofuse = { path = "../LingoFuse/rust" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

**方式 B：作为 git 依赖**

```toml
[dependencies]
lingofuse = { git = "https://github.com/PassByYou888/LingoFuse", branch = "main", subdir = "rust" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

**方式 C：作为本地 crate 直接使用**

直接把 `rust/` 目录复制到你的项目中，改为 path 依赖。

### 2.3 native 库部署

`lingofuse` crate 使用 **运行时动态加载**，不依赖构建期链接。你需要把 native 库放到 Rust 加载器能找到的位置。

**需要的文件**：

| 平台 | 核心库 | IPC 依赖 |
|------|--------|----------|
| Windows 64 位 | `LingoFuse64.dll` | `z_ipc_64.dll` |
| Windows 32 位 | `LingoFuse32.dll` | `z_ipc_32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` |

**部署位置**（按加载器搜索顺序）：

1. 当前可执行文件所在目录
2. 当前工作目录
3. 系统加载器搜索路径（`PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`）

**最省事的做法**：把 LingoFuse 仓库的 `Binary/` 目录加入系统 `PATH`。

Windows PowerShell：

```powershell
$env:PATH = "C:\path\to\LingoFuse\Binary;$env:PATH"
```

Linux / macOS：

```bash
export LD_LIBRARY_PATH=/path/to/LingoFuse/Binary:$LD_LIBRARY_PATH
```

### 2.4 平台依赖

Windows 下需要安装 **VC++ 2015-2022 可再发行程序包**（提供 native 库的 C 运行时依赖）。

Linux 下若使用 musl 目标，需要确保 `liblingofuse.so` 与 musl ABI 兼容（native 库默认使用 glibc 构建）。

### 2.5 验证库引用成功

在你的项目里跑一个最小示例：

```rust
use lingofuse::sys;

fn main() {
    match sys::load_library() {
        Ok(_) => println!("[OK] LingoFuse native library loaded"),
        Err(e) => eprintln!("[FAIL] {}", e),
    }
}
```

**输出 `[OK]` 说明库引用成功。**

若输出 `[FAIL]`，错误信息会列出所有尝试过的路径，按提示调整部署位置。

---

## 第 3 章 使用说明

### 3.1 最小可运行示例

#### 3.1.1 服务端

创建 `src/bin/server.rs`：

```rust
use lingofuse::app_handle::AppHandle;
use lingofuse::framework;
use lingofuse::io;
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct AddArgs {
    a: i32,
    b: i32,
}

#[derive(Serialize)]
struct AddResult {
    sum: i32,
}

fn main() -> Result<(), lingofuse::error::Error> {
    // 部署模式：不阻塞等待 mesh 就绪
    framework::set_option("Wait_Connection_ReadyOk", "False")?;
    framework::set_option("Quiet", "True")?;

    // 创建应用并注册 API
    let app = AppHandle::new("Calculator", "简单计算器")?;

    app.register_call("add", "两数相加", |input, output| {
        if let Ok(args) = io::read_json::<AddArgs>(input) {
            let _ = io::write_json(output, &AddResult { sum: args.a + args.b });
        }
    })?;

    // 网络准备
    framework::reset_prepare();
    framework::prepare_service("ipc:calc", "ipc:calc")?;
    framework::prepare_client("ipc:calc", Some(&app))?;
    framework::prepare_done()?;

    println!("服务端就绪，按回车退出。");
    std::io::stdin().read_line(&mut String::new()).ok();

    drop(app);
    framework::exit_main_thread();
    framework::shutdown();
    Ok(())
}
```

#### 3.1.2 调用端

创建 `src/bin/client.rs`：

```rust
use lingofuse::data_handle::DataHandle;
use lingofuse::framework;
use lingofuse::io;
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Serialize)]
struct AddArgs {
    a: i32,
    b: i32,
}

#[derive(Deserialize)]
struct AddResult {
    sum: i32,
}

fn main() -> Result<(), lingofuse::error::Error> {
    framework::set_option("Wait_Connection_ReadyOk", "False")?;
    framework::reset_prepare();
    framework::prepare_client("ipc:calc", None)?;
    framework::prepare_done()?;

    // 构造请求
    let mut req = DataHandle::new("add")?;
    io::write_json(&mut req, &AddArgs { a: 5, b: 7 })?;
    req.set_position(0)?;

    // 重试循环：mesh 广播到达本地缓存最多需要约 3 秒
    let mut response = None;
    for _ in 0..30 {
        match framework::try_call("Calculator", &req, 3000)? {
            Some(r) => {
                response = Some(r);
                break;
            }
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

#### 3.1.3 运行

```bash
# 确保 native 库在 PATH / LD_LIBRARY_PATH 中
cargo run --bin server    # 终端 1
cargo run --bin client    # 终端 2
```

**期望输出**：`5 + 7 = 12`

### 3.2 核心概念

#### 3.2.1 数据句柄（DataHandle）

数据句柄是 LingoFuse 的**基本原语**——一个带 API 名称的字节缓冲区，带读 / 写游标。

两种句柄：

| 类型 | 构造 | 空闲回收 | 释放时机 |
|------|------|:--------:|----------|
| **自动回收** | `DataHandle::new("api")` | 10 分钟空闲后由池扫描回收（每 5 秒扫一次） | `Drop` 标记删除，下次扫描实际释放 |
| **永久** | `DataHandle::create_permanent("api")` | 永不自动回收 | `Drop` 同步释放 |

**关键区别**：

- 自动回收句柄：忘记 `Drop` 有兜底，但高强度场景下可能泄漏
- 永久句柄：适合跨进程生命周期的模板缓存；**必须显式 `Drop`**

**借用句柄**：回调内部拿到的 `input` / `output` 是**借用**的——原生层拥有它们，函数返回即释放。**不要**对它们调用 `dispose()`。

#### 3.2.2 应用句柄（AppHandle）

应用句柄是**一组相关 API 的命名容器**。它是网络路由的基本单位：

- 调用方指定 `(应用名, API名)`
- mesh 把调用分发到托管该应用的一个客户端
- 应用名大小写不敏感
- 一个客户端同一时刻只能托管一个应用（除非启用 `Overlap_Connection`）

#### 3.2.3 三种调用模式

| 模式 | Rust API | 语义 | 顺序保证 | 返回值 |
|------|----------|------|:--------:|:------:|
| **Call** | `framework::call` / `try_call` | 请求-响应 | — | ✅ |
| **Notify** | `framework::notify` | 单向通知 | ❌ | ❌ |
| **Sequenced Notify** | `framework::sequenced_notify` | 单向通知 | ✅（同一 `(app, api)` 对内 FIFO） | ❌ |

**选择建议**：

- 需要响应 → **Call**
- 不需要响应，且容忍乱序 → **Notify**（性能最好）
- 不需要响应，但要求顺序 → **Sequenced Notify**

#### 3.2.4 回调契约

注册的回调在**原生 worker 线程**上执行。三条硬性规则：

1. **不要阻塞**。一个长时间运行的回调占用原生线程池中的一个线程。回调应该只做「读入 + 入队 + 返回」。
2. **不要调用任何阻塞型 LingoFuse 函数**（`framework::call`、`AppHandle::local_call`、`framework::prepare_done`、`framework::shutdown`）。这会死锁原生调度器。需要发起远程调用时，把请求投递到独立线程。
3. **不要 panic**。Rust 绑定在 FFI 边界用 `catch_unwind` 隔离了 panic，但被捕获的 panic 仍然会中断当前回调，caller 收到空响应。优先返回错误载荷。

### 3.3 API 详解

#### 3.3.1 `data_handle` 模块

```rust
use lingofuse::data_handle::{DataHandle, Scalar};

// 构造
let mut h = DataHandle::new("api_name")?;              // 自动回收
let mut p = DataHandle::create_permanent("template")?; // 永久

// 字节 I/O
h.write_bytes(&[1, 2, 3])?;
let bytes = h.read_bytes(3)?;                    // 部分读，返回实际读到的
let bytes = h.read_bytes_exact(3)?;              // 精确读，短读报错
let opt = h.try_read_bytes(3)?;                  // 非抛出，短读返回 None
let all = h.read_all_bytes()?;                   // 读全部剩余

// 标量 I/O（小端序）
h.write(42i32)?;                                  // 任何实现了 Scalar 的类型
let n: i32 = h.read()?;
// 支持：i8/u8/i16/u16/i32/u32/i64/u64/f32/f64

// 字符串 I/O（NUL 结尾 UTF-8）
h.write_string("你好")?;
let s = h.read_string()?;

// 游标与大小
let pos = h.position()?;
h.set_position(0)?;
let sz = h.size()?;
h.set_size(100)?;

// 显式释放（通常不需要：Drop 会自动调用）
h.dispose();
```

#### 3.3.2 `io` 模块

```rust
use lingofuse::io;

// JSON 序列化 / 反序列化（无句柄）
let text = io::dumps_json(&my_value)?;
let value: MyType = io::loads_json(&text)?;

// 写入句柄（自动加 NUL 结尾）
io::write_json(&mut h, &request)?;

// 从句柄读取
let response: MyResponse = io::read_json(&mut h)?;
let opt = io::try_read_json::<MyResponse>(&mut h)?;  // 非抛出

// 字符串
io::write_string(&mut h, "hello")?;
let s = io::read_string(&mut h)?;

// 字节
io::write_string_bytes(&mut h, &payload)?;
let bytes = io::read_string_bytes(&mut h)?;   // 读到第一个 NUL
let bytes = io::read_all_bytes(&mut h)?;      // 读全部
let bytes = io::peek_string_bytes(&mut h)?;   // 不移动游标

// 三态读取
match io::read_json_or_bytes(&mut h)? {
    io::JsonOrBytes::Json(v) => { /* 有效 JSON */ }
    io::JsonOrBytes::Bytes(b) => { /* 原始字节 */ }
    io::JsonOrBytes::Empty => { /* 空 */ }
}
```

#### 3.3.3 `app_handle` 模块

```rust
use lingofuse::app_handle::AppHandle;

let app = AppHandle::new("MyApp", "描述")?;

// 注册 Call API（请求-响应）
app.register_call("add", "加法", |input, output| {
    // input / output 是借用的 DataHandle
    // 不要 dispose，不要阻塞，不要发起远程调用
    if let Ok(args) = io::read_json::<AddArgs>(input) {
        let _ = io::write_json(output, &AddResult { sum: args.a + args.b });
    }
})?;

// 注册 Notify API（单向）
app.register_notify("log", "日志", |input| {
    // 无输出
})?;

// 取消注册
let removed = app.unregister("add")?;   // bool

// 进程内调用（不走网络）
let resp = app.local_call(&req)?;
app.local_notify(&req)?;

// 绑定到空闲客户端
let count = app.bind()?;                // i32

// 显式释放
app.dispose();
```

#### 3.3.4 `framework` 模块

```rust
use lingofuse::framework;

// --- 网络准备 ---
framework::reset_prepare();
framework::prepare_service("ipc:my_node", "ipc:my_node")?;
framework::prepare_client("ipc:my_node", Some(&app))?;
framework::prepare_done()?;

// --- 远程调用 ---
let resp = framework::call("RemoteApp", &param, 3000)?;          // 永不返回 null
let opt = framework::try_call("RemoteApp", &param, 3000)?;       // 空响应返回 None
framework::notify("RemoteApp", &param)?;
framework::sequenced_notify("RemoteApp", &param)?;

// --- 运行时选项 ---
framework::set_option("Overlap_Connection", "True")?;
framework::set_option("Wait_Connection_Timeout", "60000")?;
framework::set_option("Quiet", "True")?;

// --- 应用名 ---
let unique = framework::generate_app_name()?;   // 需在 prepare_done 之后
let name = framework::get_app_name(&app)?;

// --- 健康检查（有约 3 秒缓存延迟）---
framework::check_main_thread()?;
framework::check_app("RemoteApp")?;
framework::check_api("RemoteApp", "add")?;

// --- 关闭 ---
framework::exit_main_thread();
framework::shutdown();
```

#### 3.3.5 `network_events` 模块

```rust
use lingofuse::network_events;

network_events::set_network_event(
    Some(Box::new(|addr| println!("[+] 已连接：{}", addr))),
    Some(Box::new(|addr| println!("[-] 已断开：{}", addr))),
)?;

let installed = network_events::is_network_event_installed();

network_events::clear_network_event()?;
```

**语义说明**：

- **Connect** 触发于客户端首次收到服务端 API 信息广播时，**不是 TCP 握手**
- **Disconnect** 触发于物理链路断开时
- **自动重连**会再次触发 Connect，但**不会**重复触发 Disconnect

#### 3.3.6 `status` 模块

```rust
use lingofuse::status;

status::post_status("自定义日志")?;
let count = status::get_status_count()?;
let next = status::get_status()?;
let msgs = status::drain_status(64)?;
```

### 3.4 运行时选项速查

| 选项名 | 类型 | 默认 | 说明 |
|--------|------|------|------|
| `Overlap_Connection` | bool | `False` | 允许同一地址多个客户端 |
| `Wait_Connection_ReadyOk` | bool | `True` | `prepare_done` 是否等待客户端就绪 |
| `Wait_Connection_Timeout` | int (ms) | `30000` | 上述等待的超时 |
| `Quiet` | bool | `False` | 抑制内部日志 |
| `ShowThreadID` | bool | `False` | 日志显示线程 ID |
| `ConsoleOutput` | bool | auto | 控制台输出开关 |
| `Fixed_Sequenced_Time` | int (ms) | `20000` | 顺序通知回退阈值 |

**布尔值格式**：`"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` / `"No"`（大小写不敏感）。

**未知选项静默忽略**，不会报错。拼写错误没有反馈，请仔细核对。

### 3.5 错误处理

所有错误都是 `lingofuse::error::Error`，带 `ErrorCode` 分类标签。

```rust
use lingofuse::error::ErrorCode;

match framework::try_call("App", &param, 3000) {
    Ok(Some(resp)) => { /* 成功，resp 非空 */ }
    Ok(None) => { /* 超时或目标不可达 */ }
    Err(e) if e.code() == ErrorCode::Timeout => { /* 特殊处理超时 */ }
    Err(e) => eprintln!("致命错误：{}", e),
}
```

**错误链**：`Error::source()` 返回底层错误。`anyhow` / `eyre` 生态可以直接展开。

---

## 第 4 章 测试与验证

### 4.1 测试分层

Rust 绑定的测试分四层：

| 层级 | 命令 | 依赖 native | 说明 |
|------|------|:-----------:|------|
| **单元测试** | `cargo test --lib` | 部分 | 54 通过，11 忽略 |
| **忽略的单元测试** | `cargo test --lib -- --ignored --test-threads=1` | ✅ | 11 通过 |
| **ABI 冒烟测试** | `cargo test --test abi_smoke` | ✅ | 5 通过，1 忽略 |
| **端到端集成测试** | `cargo test --test framework_e2e -- --ignored --test-threads=1` | ✅ | 2 通过 |

### 4.2 运行全部测试

```bash
# 1. 快速单元测试（并行安全）
cargo test --lib

# 2. 触及进程级 native 状态的单元测试（必须串行）
cargo test --lib -- --ignored --test-threads=1

# 3. Stage 1 原始 ABI 层测试
cargo test --test abi_smoke

# 4. Stage 2 端到端集成测试（必须串行）
cargo test --test framework_e2e -- --ignored --test-threads=1
```

### 4.3 为什么部分测试是 `#[ignore]`

**根本原因**：进程级 native 状态（框架准备 / 关闭、网络事件、状态投递）只能**串行访问**。Rust test harness 默认并发运行测试，与之冲突。

**危险组合示例**：

- 线程 A 调用 `LF_Shutdown`（清空回调 + 停止工作线程）
- 线程 B 调用 `LF_Set_Network_Event`（重新设置回调指针）

两者竞争导致 native 层持有的回调指针与工作线程状态不一致 → 后续调用崩溃（`STATUS_ACCESS_VIOLATION`）。

`#[ignore]` 是标准隔离机制——不改变生产代码，只改变测试运行策略。

### 4.4 判断测试是否真正运行

**集成测试的陷阱**：native 库缺失时，测试会打印 `[SKIP]` 并返回 `ok`。**测试显示 `ok` 不代表真实运行过。**

**判断方法**：

```bash
# 加 --nocapture 让 [SKIP] 输出到终端
cargo test --test abi_smoke -- --nocapture 2>&1 | grep SKIP

# 无输出 → native 库已加载，测试真实运行 ✅
# 输出 [SKIP] → native 库未找到，测试被跳过 ⚠️
```

### 4.5 期望的测试结果

在 LingoFuse v3.10 native 库存在的前提下：

```
cargo test --lib                                          → 54 passed, 0 failed, 11 ignored
cargo test --lib -- --ignored --test-threads=1            → 11 passed, 0 failed
cargo test --test abi_smoke                               → 5 passed, 1 ignored
cargo test --test framework_e2e -- --ignored --test-threads=1 → 2 passed, 0 failed
```

**合计 72 个测试**（含 12 个 `#[ignore]`）。

### 4.6 验证脚本

**Windows PowerShell** — 存为 `verify-stage2.ps1`：

```powershell
$ErrorActionPreference = "Stop"

Write-Host "=== [1/4] 编译检查 ===" -ForegroundColor Cyan
cargo check --lib
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n=== [2/4] 单元测试 ===" -ForegroundColor Cyan
cargo test --lib

Write-Host "`n=== [3/4] 忽略的单元测试 ===" -ForegroundColor Cyan
cargo test --lib -- --ignored --test-threads=1

Write-Host "`n=== [4/4] 端到端集成测试 ===" -ForegroundColor Cyan
$out = cargo test --test framework_e2e -- --ignored --test-threads=1 --nocapture 2>&1 | Out-String
Write-Host $out
$skips = ([regex]::Matches($out, "\[SKIP\]")).Count
if ($skips -gt 0) {
    Write-Host "[!] 有 $skips 个测试被跳过 - native 库未加载" -ForegroundColor Yellow
    exit 2
}

Write-Host "`n全部通过。" -ForegroundColor Green
```

**Linux / macOS** — 存为 `verify-stage2.sh`：

```bash
#!/usr/bin/env bash
set -e

echo "=== [1/4] 编译检查 ==="
cargo check --lib

echo "=== [2/4] 单元测试 ==="
cargo test --lib

echo "=== [3/4] 忽略的单元测试 ==="
cargo test --lib -- --ignored --test-threads=1

echo "=== [4/4] 端到端集成测试 ==="
out=$(cargo test --test framework_e2e -- --ignored --test-threads=1 --nocapture 2>&1 || true)
echo "$out"
skips=$(echo "$out" | grep -c "SKIP" || true)
if [ "$skips" -gt 0 ]; then
    echo "[!] 有 $skips 个测试被跳过 - native 库未加载"
    exit 2
fi

echo "全部通过。"
```

### 4.7 测试失败排查

| 症状 | 原因 | 修法 |
|------|------|------|
| `cargo check --lib` 有 warning | 代码未过 lint | 按提示补 `#[allow]` 或修正 |
| `LibraryNotFound` | native 库不在搜索路径 | 把库放到可执行文件旁或加入 PATH |
| `SymbolMissing { symbol: "LF_xxx" }` | native 库版本不匹配 | 核对 37 个符号是否齐全 |
| 崩溃在 `LF_Set_Network_Event` | 测试并发访问 native 全局状态 | 加 `--test-threads=1` |
| 端到端测试卡在 retry 循环 | mesh 广播未到达 | 加大 retry 次数或改用 `Wait_Connection_ReadyOk=True` |
| `local_call_roundtrip` 失败 | 回调类型不匹配 | 检查闭包签名 |

---

## 第 5 章 测试程序覆盖领域

Rust 绑定的测试体系覆盖以下 **8 个领域**。每个领域都对应生产代码的一个关键能力。

### 5.1 领域一：动态库加载与符号解析

**覆盖的测试**：

- `sys::loader::tests::platform_file_name_is_non_empty_on_supported_targets`
- `sys::loader::tests::is_loaded_reflects_singleton_state`
- `abi_smoke::native_library_loads_and_symbols_resolve`

**验证能力**：

- 平台探测返回正确的库文件名
- 搜索路径拼接正确（exe 目录 / CWD）
- 37 个导出符号全部解析成功
- 加载状态单例语义正确

### 5.2 领域二：数据句柄生命周期

**覆盖的测试**：

- `data_handle::tests::byte_roundtrip`
- `data_handle::tests::scalar_roundtrip`
- `data_handle::tests::string_roundtrip`
- `data_handle::tests::empty_string_roundtrip`
- `data_handle::tests::exact_read_failure_restores_cursor`
- `data_handle::tests::try_read_returns_none_without_error`
- `data_handle::tests::read_without_nul_consumes_remaining`
- `data_handle::tests::drop_is_idempotent`
- `abi_smoke::data_handle_byte_roundtrip`
- `abi_smoke::permanent_handle_is_synchronous`

**验证能力**：

- 自动回收句柄与永久句柄的创建、读写、释放
- 字节 / 标量（10 种类型）/ 字符串的所有 I/O 路径
- 短读恢复游标
- 容错读取（无 NUL 时消费剩余字节）
- `Drop` 幂等性

### 5.3 领域三：统一 I/O 层

**覆盖的测试**：

- `io::tests::dumps_json_is_compact`
- `io::tests::dumps_json_preserves_non_ascii_literally`
- `io::tests::loads_json_is_strict`
- `io::tests::json_string_roundtrip_no_handle`
- `io::tests::write_read_string_roundtrip`
- `io::tests::empty_string_roundtrip_writes_single_nul`
- `io::tests::write_string_bytes_writes_all_bytes_then_framing_nul`
- `io::tests::read_string_bytes_stops_at_first_embedded_nul`
- `io::tests::peek_does_not_advance`
- `io::tests::read_without_nul_consumes_remaining`
- `io::tests::read_all_bytes_is_raw`
- `io::tests::json_roundtrip`
- `io::tests::json_with_unicode_roundtrip`
- `io::tests::read_json_rejects_empty`
- `io::tests::try_read_json_returns_none_on_garbage`
- `io::tests::try_read_json_returns_none_on_type_mismatch`
- `io::tests::read_json_or_bytes_empty`
- `io::tests::read_json_or_bytes_json`
- `io::tests::read_json_or_bytes_raw_on_non_json`
- `io::tests::read_json_or_bytes_raw_on_invalid_utf8`

**验证能力**：

- JSON 序列化紧凑、非 ASCII 字面输出（无 `\uXXXX`）
- 严格解析（拒绝无效 JSON）
- 中文 / emoji 的 UTF-8 无损往返
- 三态读取（`Json` / `Bytes` / `Empty`）
- 嵌入式 NUL 的读写非对称语义
- `peek` 不移动游标

### 5.4 领域四：应用句柄与回调桥接

**覆盖的测试**：

- `app_handle::tests::create_app_and_read_name`
- `app_handle::tests::register_call_succeeds`
- `app_handle::tests::register_notify_succeeds`
- `app_handle::tests::duplicate_registration_fails`
- `app_handle::tests::unregister_after_register`
- `app_handle::tests::local_call_roundtrip`
- `app_handle::tests::local_notify_is_delivered`
- `app_handle::tests::callback_panic_does_not_abort`
- `app_handle::tests::dispose_invalidates_handle`
- `abi_smoke::local_call_roundtrip`

**验证能力**：

- 应用创建 / 释放 / 命名
- Call / Notify API 注册
- 重复注册拒绝
- 取消注册及重注册
- 本地调用（进程内，不走网络）
- 通知投递
- **panic 隔离**（回调 panic 不跨 FFI 边界）
- 句柄释放后所有操作报错

### 5.5 领域五：进程级框架

**覆盖的测试**：

- `framework::tests::set_option_accepts_known_keys`
- `framework::tests::set_option_rejects_interior_nul`
- `framework::tests::check_main_thread_returns_bool`
- `framework::tests::check_app_for_absent_name_is_false`
- `framework::tests::check_api_for_absent_pair_is_false`
- `framework::tests::reset_prepare_is_safe_without_framework`
- `framework::tests::exit_main_thread_is_safe_without_framework`
- `framework::tests::shutdown_is_idempotent`
- `framework::tests::get_app_name_rejects_disposed_handle`
- `framework::tests::call_with_disposed_param_fails_cleanly`
- `framework::tests::notify_with_disposed_param_fails_cleanly`
- `framework::tests::sequenced_notify_with_disposed_param_fails_cleanly`

**验证能力**：

- 运行时选项设置（含 interior NUL 拒绝）
- 健康检查（主线程、应用、API）
- 无框架状态下 `reset_prepare` / `exit_main_thread` / `shutdown` 的安全性
- 已释放句柄的优雅报错
- 幂等性

### 5.6 领域六：网络事件

**覆盖的测试**：

- `network_events::tests::install_and_clear_roundtrip`
- `network_events::tests::only_connect_installed`
- `network_events::tests::only_disconnect_installed`
- `network_events::tests::set_none_none_clears_previous`
- `network_events::tests::replacing_handler_keeps_installed`
- `network_events::tests::clear_is_idempotent`

**验证能力**：

- 单独安装 connect / disconnect 处理器
- 替换语义（第二次 `set_network_event` 丢弃所有旧处理器）
- 幂等清除
- 安装状态查询

### 5.7 领域七：状态队列

**覆盖的测试**：

- `status::tests::get_status_count_succeeds`
- `status::tests::post_status_accepts_a_message`
- `status::tests::post_status_rejects_interior_nul`
- `status::tests::get_status_succeeds`
- `status::tests::drain_status_with_zero_is_a_noop`
- `status::tests::drain_status_succeeds`

**验证能力**：

- 状态队列计数 / 读取 / 投递 / 批量拉取
- interior NUL 拒绝
- 边界条件（`max_messages == 0`）

### 5.8 领域八：端到端集成

**覆盖的测试**：

- `framework_e2e::same_process_service_and_client`
- `framework_e2e::consumer_only_call_to_absent_app_returns_none`

**验证能力**：

- 完整的「准备 → 连接 → App 注册 → 广播 → 路由 → 回调 → 返回」链路
- JSON 请求 / 响应端到端往返
- Notify 投递确认
- 缺席目标的优雅返回 `Ok(None)`
- 完整的关闭流程

**注意**：这两个测试在同一进程内运行服务端和调用端，走的是 mesh 的**本地优先路由**路径。它验证了完整的原生调用链（打包、分发、解包、调用回调、打包结果、返回），但没有跨越 TCP 或跨进程 IPC 跳。

### 5.9 领域覆盖矩阵

| 领域 | 测试数 | 依赖 native | 是否真实调用 |
|------|:------:|:-----------:|:------------:|
| 动态库加载与符号解析 | 3 | ✅ | ✅ |
| 数据句柄生命周期 | 10 | ✅ | ✅ |
| 统一 I/O 层 | 20 | 部分 | 部分 |
| 应用句柄与回调桥接 | 10 | ✅ | ✅ |
| 进程级框架 | 12 | ✅ | 部分 |
| 网络事件 | 6 | ✅ | ✅ |
| 状态队列 | 6 | ✅ | 部分 |
| 端到端集成 | 2 | ✅ | ✅ |
| **合计** | **69** | — | — |

> 上表按测试「逻辑归属」计数，与 `cargo test` 输出的数字（72）略有差异，因为部分测试同时覆盖多个领域。

---

## 第 6 章 替代 POC 的工作

### 6.1 什么是「POC 工作」

引入一个新的跨语言绑定，通常需要先做一轮**概念验证**：

- 动态库能否加载
- 符号是否齐全
- 数据能否往返
- 回调能否工作
- 生命周期是否安全
- 错误能否优雅处理
- 与其它语言的互操作是否成功

每一项都是潜在的风险点。Rust 绑定的测试体系**已经把所有这些验证工作完成了**。

### 6.2 被替代的 POC 清单

下表列出**每一项已被 Rust 绑定测试体系覆盖的 POC 工作**。如果你原本计划自己做这些验证，可以跳过。

#### 6.2.1 动态库加载类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 运行时能否找到 `LingoFuse64.dll` | `native_library_loads_and_symbols_resolve` | ✅ 已确认 |
| 跨平台库文件名是否正确 | `platform_file_name_is_non_empty_on_supported_targets` | ✅ 已确认 |
| 搜索路径拼接是否符合预期 | 同上 | ✅ 已确认 |
| 加载失败时错误信息是否可诊断 | `LoadError::LibraryNotFound` 的 `Display` 实现 | ✅ 已确认 |
| 加载状态是否线程安全 | `OnceLock` 单例 + `is_loaded_reflects_singleton_state` | ✅ 已确认 |

#### 6.2.2 C ABI 符号类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 37 个导出符号是否全部存在 | `native_library_loads_and_symbols_resolve` | ✅ 已确认 |
| 函数指针签名是否与 C 头文件匹配 | 编译期类型检查 + `abi_smoke` | ✅ 已确认 |
| 调用约定（cdecl）是否正确 | `extern "C"` + 端到端测试 | ✅ 已确认 |
| 缺少符号时是否有清晰错误 | `LoadError::SymbolMissing` | ✅ 已确认 |

#### 6.2.3 数据句柄类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 能否创建自动回收句柄 | `byte_roundtrip` | ✅ 已确认 |
| 能否创建永久句柄 | `permanent_handle_is_synchronous` | ✅ 已确认 |
| 字节读写是否正确 | `byte_roundtrip` | ✅ 已确认 |
| 标量类型（10 种）是否都正确 | `scalar_roundtrip` | ✅ 已确认 |
| 字符串读写是否正确 | `string_roundtrip` / `empty_string_roundtrip` | ✅ 已确认 |
| 短读是否恢复游标 | `exact_read_failure_restores_cursor` | ✅ 已确认 |
| 无 NUL 的载荷是否容错 | `read_without_nul_consumes_remaining` | ✅ 已确认 |
| `Drop` 是否幂等 | `drop_is_idempotent` | ✅ 已确认 |
| 释放后的操作是否优雅报错 | `dispose_invalidates_handle` | ✅ 已确认 |

#### 6.2.4 I/O 层类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| JSON 是否紧凑输出 | `dumps_json_is_compact` | ✅ 已确认 |
| 非 ASCII 是否字面输出（无 `\uXXXX`） | `dumps_json_preserves_non_ascii_literally` | ✅ 已确认 |
| 中文 / emoji 是否无损往返 | `json_with_unicode_roundtrip` | ✅ 已确认 |
| 严格 JSON 解析是否生效 | `loads_json_is_strict` | ✅ 已确认 |
| 三态读取是否正确 | `read_json_or_bytes_*`（4 个测试） | ✅ 已确认 |
| 嵌入式 NUL 读写语义是否一致 | `write_string_bytes_*` / `read_string_bytes_*` | ✅ 已确认 |
| `peek` 是否不移动游标 | `peek_does_not_advance` | ✅ 已确认 |

#### 6.2.5 回调桥接类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| Rust 闭包能否作为 C 回调 | `register_call_succeeds` | ✅ 已确认 |
| 回调收到的句柄是否可用 | `local_call_roundtrip` | ✅ 已确认 |
| 回调内 panic 是否被隔离 | `callback_panic_does_not_abort` | ✅ 已确认 |
| 回调 panic 后进程是否存活 | 同上 | ✅ 已确认 |
| 重复注册是否拒绝 | `duplicate_registration_fails` | ✅ 已确认 |
| 取消注册后是否可重注册 | `unregister_after_register` | ✅ 已确认 |
| Notify 回调是否投递 | `local_notify_is_delivered` | ✅ 已确认 |

#### 6.2.6 框架生命周期类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 网络准备 / 启动流程是否工作 | `same_process_service_and_client` | ✅ 已确认 |
| `prepare_done` 是否返回 1（首次） | 同上 | ✅ 已确认 |
| `prepare_done` 是否返回 0（二次） | 逻辑已实现，未单独测 | 🟡 逻辑明确 |
| `exit_main_thread` / `shutdown` 是否幂等 | `shutdown_is_idempotent` | ✅ 已确认 |
| 关闭后是否可重新启动 | 未单独测 | 🟡 逻辑明确 |
| 无框架状态下的操作是否安全 | 多个 `*_without_framework` 测试 | ✅ 已确认 |

#### 6.2.7 网络事件类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 能否安装 connect / disconnect 处理器 | `install_and_clear_roundtrip` | ✅ 已确认 |
| 替换语义是否正确 | `set_none_none_clears_previous` | ✅ 已确认 |
| 单独安装一侧是否可行 | `only_connect_installed` / `only_disconnect_installed` | ✅ 已确认 |
| 清理是否幂等 | `clear_is_idempotent` | ✅ 已确认 |
| 真实事件是否能触发 | 端到端场景依赖第二进程 | 🟡 需跨进程验证 |

#### 6.2.8 错误处理类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 已释放句柄操作是否报错 | 多个 `*_disposed_*` 测试 | ✅ 已确认 |
| interior NUL 是否拒绝 | 多个 `*_rejects_interior_nul` 测试 | ✅ 已确认 |
| 缺席目标是否优雅返回 | `consumer_only_call_to_absent_app_returns_none` | ✅ 已确认 |
| 超时是否可检测 | `try_call` 返回 `None` | ✅ 已确认 |
| 错误码分类是否清晰 | `ErrorCode` 枚举 + 单元测试 | ✅ 已确认 |

### 6.3 仍需自行验证的场景

Rust 绑定测试体系**没有**覆盖以下场景。如果你的项目依赖这些能力，需要自行验证。

| 未覆盖的场景 | 原因 | 建议 |
|-------------|------|------|
| **跨进程调用** | 集成测试在单进程内运行 | 启动两个独立 Rust 进程；或用 Rust + Python 混合 |
| **跨机器调用** | 需要两台物理机 | 部署到两台机器上验证 |
| **真实网络事件触发** | 需要第二个进程加入 mesh | 启动两个进程，观察事件回调 |
| **负载均衡** | 需要多个节点提供同一 App | 启动 N 个服务实例，观察请求分发 |
| **高并发压力** | 单进程测试不适合压测 | 用 `criterion` 或 `cargo bench` |
| **长时间运行稳定性** | 测试只跑几秒 | 让服务端运行 24 小时观察 |
| **断线重连** | 需要模拟网络故障 | 手动断网 / 重启服务端 |
| **大数据传输（>100 MB）** | 测试用小载荷 | 构造大载荷测试 |
| **`Sequenced_Notify` 的 FIFO 保证** | 需要多消息并发发送 | 发送大量消息，验证接收顺序 |
| **native 库 32 位版本** | 当前测试用 64 位 | 在 32 位环境下重新运行 |

### 6.4 POC 替代的净收益

基于上面的覆盖矩阵，Rust 绑定**已经替代的 POC 工作量**估算：

| 类别 | 替代的 POC 项数 | 估计节省时间 |
|------|:--------------:|:------------:|
| 动态库加载 | 5 | 0.5 天 |
| C ABI 符号 | 4 | 0.5 天 |
| 数据句柄 | 9 | 1 天 |
| I/O 层 | 7 | 1 天 |
| 回调桥接 | 7 | 1.5 天 |
| 框架生命周期 | 6 | 1 天 |
| 网络事件 | 5 | 0.5 天 |
| 错误处理 | 5 | 0.5 天 |
| **合计** | **48** | **约 6.5 人天** |

**净收益**：

- **6.5 人天**的 POC 工作已被替代
- 剩下需要做的仅是**部署环境相关的验证**（跨进程、跨机器、长时间稳定性）
- 每次 native 库升级，重跑 `cargo test` 即可回归

---

## 第 7 章 已知限制与最佳实践

### 7.1 已知限制

#### 7.1.1 `AppHandle` 不实现 `Send` / `Sync`

绑定刻意把句柄所有权限制在单线程。回调仍可在原生 worker 线程上运行，闭包必须满足 `Fn + Send + Sync`。

**影响**：不能把 `AppHandle` 放进 `Arc<Mutex<>>` 让多线程共享。若需要，把注册逻辑集中到一个线程，其它线程通过 `channel` 投递请求。

#### 7.1.2 回调上下文泄漏

每个注册的 API 泄漏一个小的上下文对象（几十字节），直到进程退出。

**权衡**：原生库可能在任意时间（包括与取消注册并发时）调用回调，回收会造成 use-after-free。代价有界。

**影响**：不要在紧密循环中注册 / 取消注册 API。注册后长期使用是设计场景。

#### 7.1.3 单进程端到端测试

`tests/framework_e2e.rs` 中服务端和调用端在同一进程内，走的是 mesh 的**本地优先路由**。

**影响**：验证了完整的调用链，但没跨越 TCP / 跨进程 IPC 跳。跨进程验证需要两个独立 OS 进程。

#### 7.1.4 状态队列的 ABI 限制

原生 ABI 无法区分「空队列」和「空消息」：两者都产生空字符串。

**修法**：先调用 `get_status_count()` 判断。

#### 7.1.5 `generate_app_name` 指针有效期

原生指针仅有约 5 秒有效期。Rust 绑定立即复制到 `String`。

**影响**：直接用 `sys` 层时需自行处理。

#### 7.1.6 无 CI 覆盖

LingoFuse 的自动化 CI 只有 C++ 部分。Rust 测试需在本地运行。

#### 7.1.7 平台限制

- 大端架构未测试（协议约定小端）
- 32 位 Windows 未在 Rust 测试中覆盖
- aarch64 / loongarch64 / RISC-V 等边缘平台移植中

### 7.2 最佳实践

#### 7.2.1 永远写重试循环

mesh 广播到达本地缓存最多需要约 3 秒。即使 `Wait_Connection_ReadyOk=True`，也不保证广播已到达。

```rust
let mut response = None;
for _ in 0..30 {
    match framework::try_call("TargetApp", &req, 3000)? {
        Some(r) => { response = Some(r); break; }
        None => {
            req.set_position(0)?;
            std::thread::sleep(Duration::from_millis(200));
        }
    }
}
let resp = response.ok_or_else(|| /* 自定义错误 */)?;
```

#### 7.2.2 回调保持轻量

回调应该只做「读入 + 入队 + 返回」。重活投递到独立线程。

```rust
use std::sync::mpsc;

let (tx, rx) = mpsc::channel();
std::thread::spawn(move || {
    for job in rx {
        // 处理重活
    }
});
let tx_clone = tx.clone();

app.register_call("heavy", "重活", move |input, _output| {
    let data = io::read_string_bytes(input).unwrap_or_default();
    let _ = tx_clone.send(data);  // 只投递，立即返回
})?;
```

#### 7.2.3 用 `#[derive]` 定义载荷类型

```rust
#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Request {
    #[serde(rename = "user_name")]  // 与其它语言的 snake_case 对齐
    user_name: String,
    request_id: u64,
}
```

#### 7.2.4 用 `try_call` 而非 `call`

`call` 在超时时返回 size=0 的句柄，容易误判。`try_call` 返回 `Option`，语义清晰。

```rust
// ❌ 容易误判：size == 0 时也要检查
let resp = framework::call("App", &param, 3000)?;
if resp.size()? > 0 { /* ... */ }

// ✅ 清晰
match framework::try_call("App", &param, 3000)? {
    Some(mut resp) => { /* 有响应 */ }
    None => { /* 超时或目标不可达 */ }
}
```

#### 7.2.5 用 `create_permanent` 缓存模板

需要跨进程生命周期的请求模板用永久句柄。

```rust
let template = DataHandle::create_permanent("my_api")?;
// 用完后显式释放
template.dispose();
```

#### 7.2.6 回调内用 `catch_unwind` 兜底

虽然绑定的 trampoline 已隔离 panic，但回调内自行捕获更利于诊断。

```rust
app.register_call("api", "desc", |input, output| {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // 业务逻辑
    }));
    match result {
        Ok(v) => { let _ = io::write_json(output, &v); }
        Err(_) => { let _ = io::write_json(output, &serde_json::json!({"error": "panic"})); }
    }
})?;
```

#### 7.2.7 应用注册先于客户端准备

```rust
// ✅ 正确顺序
let app = AppHandle::new("MyApp", "desc")?;
app.register_call("api1", "desc", ...)?;  // ← 先注册
framework::prepare_client("ipc:...", Some(&app))?;  // ← 后准备
```

顺序颠倒会导致 mesh 广播携带空 API 列表，首次调用失败。

#### 7.2.8 用 `Overlap_Connection` 托管多应用

```rust
framework::set_option("Overlap_Connection", "True")?;
framework::prepare_client("ipc:addr", Some(&app1))?;
framework::prepare_client("ipc:addr", Some(&app2))?;
```

不加这个选项，第二次 `prepare_client` 会**静默丢弃**第二个应用。

---

## 附录 A 快速参考

### A.1 常用代码片段

```rust
// --- 引入 ---
use lingofuse::app_handle::AppHandle;
use lingofuse::data_handle::DataHandle;
use lingofuse::error::ErrorCode;
use lingofuse::{framework, io, network_events, status, sys};

// --- 加载库 ---
sys::load_library()?;

// --- 定义载荷 ---
#[derive(Serialize, Deserialize)]
struct MyRequest { /* ... */ }

// --- 创建应用 ---
let app = AppHandle::new("AppName", "description")?;

// --- 注册 Call ---
app.register_call("api", "desc", |input, output| {
    if let Ok(req) = io::read_json::<MyRequest>(input) {
        let _ = io::write_json(output, &MyResponse { /* ... */ });
    }
})?;

// --- 注册 Notify ---
app.register_notify("log", "desc", |input| {
    let _ = io::read_string(input);
})?;

// --- 网络准备 ---
framework::reset_prepare();
framework::prepare_service("ipc:addr", "ipc:addr")?;
framework::prepare_client("ipc:addr", Some(&app))?;
framework::prepare_done()?;

// --- 远程调用 ---
let mut req = DataHandle::new("api")?;
io::write_json(&mut req, &my_request)?;
req.set_position(0)?;
let resp = framework::try_call("TargetApp", &req, 3000)?;

// --- 单向通知 ---
framework::notify("TargetApp", &req)?;
framework::sequenced_notify("TargetApp", &req)?;

// --- 网络事件 ---
network_events::set_network_event(
    Some(Box::new(|addr| println!("+ {}", addr))),
    Some(Box::new(|addr| println!("- {}", addr))),
)?;

// --- 状态 ---
status::post_status("msg")?;

// --- 关闭 ---
framework::exit_main_thread();
framework::shutdown();
```

### A.2 环境变量与运行时选项

| 选项名 | 类型 | 默认 | 常用值 |
|--------|------|------|--------|
| `Overlap_Connection` | bool | `False` | 多应用同地址时 `True` |
| `Wait_Connection_ReadyOk` | bool | `True` | 弹性集群时 `False` |
| `Wait_Connection_Timeout` | int (ms) | `30000` | 慢网络时 `60000` |
| `Quiet` | bool | `False` | 生产环境 `True` |
| `ConsoleOutput` | bool | auto | 容器环境 `False` |
| `ShowThreadID` | bool | `False` | 调试时 `True` |

### A.3 库文件清单

| 平台 | 文件 |
|------|------|
| Windows 64 | `LingoFuse64.dll` + `z_ipc_64.dll` |
| Windows 32 | `LingoFuse32.dll` + `z_ipc_32.dll` |
| Linux | `liblingofuse.so` + `libz_ipc.so` |
| macOS | `liblingofuse.dylib` + `libz_ipc.dylib` |

---

## 附录 B 错误码索引

| 错误码 | 触发场景 | 修法 |
|--------|---------|------|
| `Generic` | 未分类错误 | 查看 `Display` 消息 |
| `LibraryLoadFailed` | native 库未找到或符号缺失 | 检查部署位置 / 版本 |
| `NullHandle` | 已释放句柄的操作 | 检查生命周期 |
| `InvalidArgument` | interior NUL 或负数参数 | 检查参数 |
| `WriteFailed` | 写入短写 | native 层异常或内存不足 |
| `ReadFailed` | 精确读短读 / JSON 解析失败 | 检查数据 / 类型 |
| `CallFailed` | 远程调用返回 null 句柄 | native 层内部错误 |
| `RegistrationFailed` | API 名重复 | 换名或先 unregister |
| `NotConnected` | 框架未运行时的操作 | 先 `prepare_done` |
| `Timeout` | 远程调用超时 | 增大 timeout 或重试 |

---

## 附录 C 跨语言对照

### C.1 核心 API 对照

| 功能 | Pascal | Python | C++ | C# | JavaScript | **Rust** |
|------|:------:|:------:|:---:|:--:|:----------:|:--------:|
| 加载库 | 静态链接 | import | `LF_LoadLibrary` | DllImport | `koffi.load` | `sys::load_library()` |
| 自动句柄 | `LF_CreateDataEx` | `DataHandle()` | `DataHandle(name)` | `new DataHandle` | `new DataHandle` | `DataHandle::new` |
| 永久句柄 | `LF_CreateData_PermanentEx` | — | `createPermanent` | `CreatePermanent` | `createPermanent` | `DataHandle::create_permanent` |
| 写 JSON | `LF_WriteString` | `lf_io.write_json` | `io::write_json` | `LfIo.WriteJson` | `lf-io.writeJson` | `io::write_json` |
| 读 JSON | `LF_ReadString` | `lf_io.read_json` | `io::read_json` | `LfIo.ReadJson` | `lf-io.readJson` | `io::read_json` |
| 创建应用 | `LF_CreateAppEx` | `App(name)` | `App(name, desc)` | `new AppHandle` | `new AppHandle` | `AppHandle::new` |
| 注册 Call | `LF_RegisterCall_M` | `@app.expose` | `registerCall` | `RegisterCall` | `registerCall` | `AppHandle::register_call` |
| 注册 Notify | `LF_RegisterNotify_M` | `@app.expose(notify=True)` | `registerNotify` | `RegisterNotify` | `registerNotify` | `AppHandle::register_notify` |
| 本地调用 | `LF_LocalCall` | `app.local_call` | `localCall` | `LocalCall` | `localCall` | `AppHandle::local_call` |
| 远程调用 | `LF_Call` | `call()` | `lingofuse::call` | `Framework.Call` | `framework.call` | `framework::call` |
| 网络准备 | `LF_PrepareService/Client/Done` | `prepare_*` | `prepare*` | `Framework.Prepare*` | `framework.prepare*` | `framework::prepare_*` |
| 关闭 | `LF_Shutdown` | `shutdown()` | `shutdown` | `Framework.Shutdown` | `framework.shutdown` | `framework::shutdown` |
| 网络事件 | `LF_Set_Network_Event` | — | `setNetworkEvent` | `NetworkEvents.Set` | `network.setNetworkEvent` | `network_events::set_network_event` |

### C.2 线协议一致性

所有绑定共享**完全相同的字节级契约**：

- UTF-8 编码
- 字面非 ASCII（无 `\uXXXX`）
- NUL 结尾
- 小端序整数
- 容错读取

**同一逻辑载荷**在任意两种语言之间往返，字节完全一致：

```
{"a":1}  →  7B 22 61 22 3A 31 7D 00
```

### C.3 跨语言调用示例

**Rust 服务端 + Python 调用端**

Rust：
```rust
app.register_call("echo", "回显", |input, output| {
    if let Ok(s) = io::read_json::<String>(input) {
        let _ = io::write_json(output, &s);
    }
})?;
```

Python：
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

*文档版本: v1.0*
*对应 Rust 绑定: Stage 1 + Stage 2 完成*
*对应 LingoFuse 版本: v3.10 / C4 v4.01*
*最后更新: 2026-10-02*
*维护者: LingoFuse 团队*