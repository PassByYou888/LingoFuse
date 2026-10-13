# LingoFuse Rust 接口 — 完整使用说明

**文档版本**: v2.0
**覆盖绑定**: `lingofuse` crate (Stage 1 + Stage 2 + Stage 3 完成)
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
- 用三套寻址（App 名 / UID / P2PName）定位目标
- 用闭包式异步 API 编写非阻塞代码
- 用类型化选项 API 配置运行时参数
- 与 Pascal / Python / C++ / C# / JavaScript 端互操作
- 运行和理解绑定的测试体系
- 判断 Rust 绑定替代了哪些原本需要 POC 验证的工作

### 1.2 阅读路径

| 你的目标 | 阅读路径 |
|---------|----------|
| 第一次用，只想跑通 | 第 2 章 → 第 3.1 节 |
| 深入理解 API | 第 3 章全部 |
| 只想用三套寻址 | 第 3.2.3 节 → 第 3.3.4 节 |
| 只想用异步调用 | 第 3.2.4 节 → 第 3.3.10 节 |
| 理解测试体系 | 第 4 章 → 第 5 章 |
| 评估生产可用性 | 第 5 章 → 第 6 章 → 第 7 章 |
| 排查问题 | 第 3.5 节 → 第 7 章 → 附录 B |

### 1.3 术语约定

| 术语 | 含义 |
|------|------|
| **native 库** | LingoFuse 的 C ABI 动态库（`LingoFuse64.dll` 等） |
| **C ABI** | native 库导出的 59 个 C 函数 |
| **数据句柄** | `DataHandle`，带 API 名称的字节缓冲区 |
| **应用句柄** | `AppHandle`，一组相关 API 的命名容器 |
| **UID** | 32 字节会话标识，由客户端在 `TunnelLink` 成功后生成，重连时会变化 |
| **P2PName** | 用户自定义的组名，服务端按组做负载均衡 |
| **mesh** | C4 服务网格，提供发现、路由、负载均衡 |
| **侧数据** | 发送方在请求载荷头部自动注入的元数据（`FromUID` / `FromP2PName`），仅在接收侧回调的 `input` 句柄上可读 |
| **异步调用** | 基于回调的调用族；与同步调用在**句柄所有权**上相反 |

---

## 第 2 章 库引用

### 2.1 依赖清单

`lingofuse` crate 依赖三个第三方库：

| 依赖 | 版本 | 用途 |
|------|------|------|
| `libloading` | 0.8 | 运行时动态加载 native 共享库 |
| `serde` | 1.x | JSON 序列化 / 反序列化（启用 `derive`） |
| `serde_json` | 1.x | JSON 编解码 |

本绑定**不依赖任何异步运行时**（无 tokio / async-std / futures）。异步调用模块基于 `std::sync::mpsc` 与闭包实现。

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

#### 3.1.2 调用端（同步）

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

#### 3.1.3 调用端（异步）

同样的调用，改用闭包式异步 API：

```rust
use lingofuse::{async_call, framework, io};
use lingofuse::data_handle::DataHandle;
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Serialize)]
struct AddArgs { a: i32, b: i32 }

#[derive(Deserialize, Debug)]
struct AddResult { sum: i32 }

fn main() -> Result<(), lingofuse::error::Error> {
    framework::set_option("Wait_Connection_ReadyOk", "False")?;
    framework::reset_prepare();
    framework::prepare_client("ipc:calc", None)?;
    framework::prepare_done()?;

    let mut req = DataHandle::new("add")?;
    io::write_json(&mut req, &AddArgs { a: 5, b: 7 })?;
    req.set_position(0)?;

    // 提交异步请求。闭包在原生 worker 线程上执行。
    async_call::call_async("Calculator", &req, move |result| {
        match result {
            Ok(mut resp) => {
                if let Ok(out) = io::read_json::<AddResult>(&mut resp) {
                    println!("5 + 7 = {}", out.sum);
                }
            }
            Err(e) => eprintln!("异步调用失败：{}", e),
        }
    })?;

    // 保持进程存活，等回调触发。
    std::thread::sleep(Duration::from_secs(1));
    framework::exit_main_thread();
    framework::shutdown();
    Ok(())
}
```

#### 3.1.4 运行

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

#### 3.2.3 三套寻址

LingoFuse 支持三种路由键。三者**并列**，不是互斥；同一服务端同时支持三种键：

| 寻址 | 键 | 路由方式 | 本地优先？ | 负载均衡？ | 典型用途 |
|------|-----|---------|:----------:|:----------:|---------|
| **App 名** | UTF-8 字符串 | 精确匹配 App 名 | ✅ | ❌ | 固定服务 |
| **UID** | 32 字节二进制 | 按会话标识定位单一客户端 | ✅ | ❌ | 定向到具体客户端 |
| **P2PName** | UTF-8 字符串 | 按组名负载均衡 | ❌ | ✅ | 同质服务集群 |

**关键差异**：

- **UID** 是**会话级**标识：由客户端在 `TunnelLink` 成功后生成，**重连时会变化**。知道某客户端的 UID，就能调用其注册的**任何 API**（包括 App 名注册的和 P2P 注册的），不需要知道 App 名。
- **P2PName** 路由**不做本地查找**：总是经服务端 dispatcher 分发，服务端拥有负载均衡状态。
- **App 名** 路由**本地优先**：本进程有同名 App 且有目标 API 时，直接本地执行，不走网络。

Rust API 的命名约定：App 名寻址用**裸名**（如 `call`），UID 寻址用 `*_by_uid` 后缀，P2PName 寻址用 `*_by_p2p_name` 后缀。三套寻址在 `framework` 模块中**对称呈现**。

#### 3.2.4 调用模式

| 模式 | Rust API | 语义 | 顺序保证 | 返回值 |
|------|----------|------|:--------:|:------:|
| **Call** | `framework::call` / `try_call` | 请求-响应 | — | ✅ |
| **Notify** | `framework::notify` | 单向通知 | ❌ | ❌ |
| **Sequenced Notify** | `framework::sequenced_notify` | 单向通知 | ✅（同一 `(app, api)` 对内 FIFO） | ❌ |
| **Async Call** | `async_call::call_async` 等 | 请求-响应（回调式） | — | 通过闭包 |
| **Async Sequenced Call** | `async_call::call_async_sequenced` | 请求-响应（FIFO） | ✅（同一 `(app, api)` 对内 FIFO） | 通过闭包 |

**选择建议**：

- 需要响应，且当前线程可以阻塞 → **Call**
- 需要响应，但**不想阻塞** → **Async Call**
- 不需要响应，且容忍乱序 → **Notify**（性能最好）
- 不需要响应，但要求顺序 → **Sequenced Notify**

**同步族与异步族在句柄所有权上相反**：

| 家族 | 函数 | 返回句柄的所有者 | 释放方式 |
|------|------|:----------------:|----------|
| 同步族 | `call` / `call_by_uid` / `call_by_p2p_name` | **调用者** | 调用者显式 `Drop` |
| 异步族 | `call_async` / ... | **框架** | 回调返回后**立即**由框架释放 |

**异步族句柄只能在闭包体内使用**。闭包返回后再使用它是 use-after-free。Rust 的安全包装已通过 `borrowed` 语义与 `Vec<u8>` 返回值在类型系统层面阻止了这一误用。

#### 3.2.5 回调契约

注册的回调在**原生 worker 线程**上执行。四条硬性规则：

1. **不要阻塞**。一个长时间运行的回调占用原生线程池中的一个线程。回调应该只做「读入 + 入队 + 返回」。
2. **不要调用任何阻塞型 LingoFuse 函数**（`framework::call`、`AppHandle::local_call`、`framework::prepare_done`、`framework::shutdown`）。这会死锁原生调度器。需要发起远程调用时，把请求投递到独立线程，或使用**异步调用**（异步族允许在回调内发起）。
3. **不要 panic**。Rust 绑定在 FFI 边界用 `catch_unwind` 隔离了 panic，但被捕获的 panic 仍然会中断当前回调，caller 收到空响应。优先返回错误载荷。
4. **不要触碰 UI**。回调不在主线程上执行。需要更新 UI 时，把结果投递到应用自己的线程安全队列。

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

// 读取发送方身份（"侧数据"，仅对回调的 input 句柄有效）
let uid  = h.p2p_uid()?;     // Uid 类型；非 input 句柄返回 Uid::NULL
let name = h.p2p_name()?;    // String；非 input 句柄返回空串

// 显式释放（通常不需要：Drop 会自动调用）
h.dispose();
```

**`p2p_uid()` / `p2p_name()` 的契约**：

- 这两个方法读取的是**发送方在发送请求时自动写入的侧数据**，不是句柄本身的属性
- **只在回调的 `input` 句柄上有效**；对 `output` 句柄或自建句柄调用会返回 `Uid::NULL` / 空串（DLL 打警告，不报错）
- 原生指针有效期约 5 秒；包装层**立即拷贝**，返回的值可以任意保留

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
    // 不要 dispose，不要阻塞，不要发起同步远程调用
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
use lingofuse::uid::Uid;

// --- 网络准备 ---
framework::reset_prepare();
framework::prepare_service("ipc:my_node", "ipc:my_node")?;
framework::prepare_client("ipc:my_node", Some(&app))?;
framework::prepare_done()?;

// --- App 名寻址 ---
let resp = framework::call("RemoteApp", &param, 3000)?;          // 永不返回 null
let opt = framework::try_call("RemoteApp", &param, 3000)?;       // 空响应返回 None
framework::notify("RemoteApp", &param)?;
framework::sequenced_notify("RemoteApp", &param)?;

// --- UID 寻址 ---
let uid: Uid = /* 从某处获取 */;
let resp = framework::call_by_uid(uid, &param, 3000)?;
let opt = framework::try_call_by_uid(uid, &param, 3000)?;
framework::notify_by_uid(uid, &param)?;
framework::sequenced_notify_by_uid(uid, &param)?;

// --- P2PName 寻址 ---
let resp = framework::call_by_p2p_name("worker_group", &param, 3000)?;
let opt = framework::try_call_by_p2p_name("worker_group", &param, 3000)?;
framework::notify_by_p2p_name("worker_group", &param)?;
framework::sequenced_notify_by_p2p_name("worker_group", &param)?;

// --- 运行时选项 ---
framework::set_option("Overlap_Connection", "True")?;
let quiet = framework::get_option("Quiet")?;               // String
// 或使用类型化接口（见 3.3.8 节）

// --- 应用名 ---
let unique = framework::generate_app_name()?;   // 需在 prepare_done 之后
let name = framework::get_app_name(&app)?;

// --- 健康检查（有约 3 秒缓存延迟）---
framework::check_main_thread()?;
framework::check_app("RemoteApp")?;
framework::check_api("RemoteApp", "add")?;
framework::check_uid(uid)?;
framework::check_uid_api(uid, "add")?;
framework::check_p2p_name("worker_group")?;
framework::check_p2p_name_api("worker_group", "add")?;

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

#### 3.3.7 `uid` 模块

`Uid` 是 32 字节 P2P 会话标识的安全 newtype。

```rust
use lingofuse::uid::Uid;

// 从 hex 构造（接受大小写，可选 0x 前缀）
let uid = Uid::from_hex("0123456789abcdef0123456789abcdef\
                         0123456789abcdef0123456789abcdef")?;

// 从字节数组 / 切片构造
let uid = Uid::from_bytes([0u8; 32]);
let uid = Uid::from_slice(&bytes)?;   // 长度必须恰好 32

// 检查
assert!(Uid::NULL.is_null());
assert_eq!(uid.to_bytes().len(), 32);

// 显示
println!("{}", uid.to_hex());         // 64 字符小写 hex
println!("{:?}", uid);                // 短形式：Uid(01234567..89abcdef)
```

**特性**：`Copy` / `Eq` / `Hash` / `Default`；可用于 `HashMap` 键。

#### 3.3.8 `options` 模块

`options` 提供类型化的选项 getter/setter，避免字符串拼写错误。

```rust
use lingofuse::options;

// 布尔选项
options::set_quiet(true)?;
assert!(options::get_quiet()?);

options::set_overlap_connection(true)?;
options::set_wait_connection_ready_ok(false)?;
options::set_show_thread_id(false)?;
options::set_console_output(true)?;

// 整数选项
options::set_wait_connection_timeout(10_000)?;
options::set_fixed_sequenced_time(20_000)?;
options::set_data_handle_idle_timeout(600_000)?;
options::set_data_handle_pool_scan_interval(5_000)?;
options::set_ipc_serv_thread_count(4)?;
options::set_ipc_serv_max_queue_length(2048)?;
options::set_ipc_serv_max_msg_size(1_048_576)?;
options::set_no_reponse_cmd_null_flush_threshold(5_000)?;

// 字符串选项
options::set_p2p_name("worker_group")?;
assert_eq!(options::get_p2p_name()?, "worker_group");

// 底层 primitive（任意 key）
options::set_bool("Quiet", true)?;
options::set_u64("Wait_Connection_Timeout", 30_000)?;
options::set_string("password", "my_secret")?;
let raw = options::get_string("SomeOption")?;
```

**未知选项的 fallback**：`get_bool` 返回 `false`；`get_u64` / `get_i64` 返回 `0`；`get_string` 返回空串。

**写独占选项**：`debug` 只写；`get_debug()` 返回占位字符串。

#### 3.3.9 `p2p` 模块

进程级 P2P 注册，独立于任何 App。这些 API 只能通过 UID / P2PName 寻址到达，**不能**通过 App 名寻址。

```rust
use lingofuse::{io, p2p};
use lingofuse::data_handle::DataHandle;

// 注册一个进程级 Call API
p2p::register_p2p_call(
    "whoami",
    "echo caller identity",
    |input: &mut DataHandle, output: &mut DataHandle| {
        // 读取发送方身份（"侧数据"，仅 input 句柄有效）
        let uid  = input.p2p_uid().unwrap_or_default();
        let name = input.p2p_name().unwrap_or_default();

        let payload = serde_json::json!({
            "uid_hex":  uid.to_hex(),
            "p2p_name": name,
        });
        let _ = io::write_json(output, &payload);
    },
)?;

// 注册一个进程级 Notify API
p2p::register_p2p_notify("p2p_log", "p2p log", |input| {
    let _ = io::read_string(input);
})?;

// 取消注册
let removed = p2p::unregister_p2p("whoami")?;   // bool
```

**P2P 命名空间与 App 命名空间是独立的**：同名 API 分别存在于两个命名空间，互不影响。

**上下文泄漏**：每次注册泄漏一个小的上下文对象（几十字节），与 `app_handle` 同构。理由见第 7.1 节。

#### 3.3.10 `async_call` 模块

现代化异步调用 API。每个寻址方式都有**回调式**和**阻塞式**两个入口。

**回调式**：

```rust
use lingofuse::async_call;
use lingofuse::data_handle::DataHandle;

let mut req = DataHandle::new("add")?;
// ... 填充 req ...

// App 名寻址
async_call::call_async("Calculator", &req, move |result| {
    match result {
        Ok(mut resp) => { /* 使用 resp，只在闭包内有效 */ }
        Err(e)        => eprintln!("异步调用失败：{}", e),
    }
})?;

// 顺序异步（FIFO 保证）
async_call::call_async_sequenced("Calculator", &req, move |result| { /* ... */ })?;

// UID 寻址
async_call::call_async_by_uid(uid, &req, move |result| { /* ... */ })?;

// P2PName 寻址
async_call::call_async_by_p2p_name("worker_group", &req, move |result| { /* ... */ })?;
```

**回调签名**：`FnOnce(Result<DataHandle, Error>) + Send + 'static`——与 `std::thread::spawn` 的闭包同构。

**闭包内的 `DataHandle` 是借用的**：只在闭包体内有效。需要保留数据时，在闭包内**读取并拷贝出来**：

```rust
async_call::call_async("Calculator", &req, move |result| {
    if let Ok(mut resp) = result {
        let value: MyResult = io::read_json(&mut resp)?;   // 拷贝到闭包外可见的类型
        my_channel.send(value);
    }
})?;
```

**阻塞式**：

```rust
use std::time::Duration;

let bytes = async_call::call_async_wait(
    "Calculator",
    &req,
    Some(Duration::from_secs(5)),   // None = 无限等待
)?;

// bytes 是 Vec<u8>，直接包含响应负载（无尾部 NUL）
let text = String::from_utf8_lossy(&bytes);
let value: MyResult = io::loads_json(&text)?;
```

**`call_async_wait` 返回 `Vec<u8>` 而不是 `DataHandle`**——这是**有意的契约**。异步族交付的句柄归框架所有，回调返回即释放；把它包装成 owning `DataHandle` 送出回调边界会导致 use-after-free。安全的选择只有"在回调内拷贝字节"或"让调用方提供反序列化目标"；本绑定选择前者。

**错误路径**：dispatch 失败时（如 framework 未启动），回调会在**调用者线程**上**同步**触发 `Err`，同时入口本身返回 `Err`。这给了调用方一个统一的错误处理路径——`?` 处理同步错误，闭包内 `match` 处理异步错误。

**超时**：阻塞式的 `timeout` 是**纯 Rust 侧**实现（`mpsc::recv_timeout`），超时后返回 `Err(ErrorCode::Timeout)`。原生请求**不会**被取消。

### 3.4 运行时选项速查

| 选项名 | 类型 | 默认 | 说明 | Rust 类型化 API |
|--------|------|------|------|-----------------|
| `password` | string | 内置 | C4 P2PVM 认证密码 | `options::set_password` |
| `Quiet` | bool | `False` | 抑制内部日志 | `options::set_quiet` |
| `ShowThreadID` | bool | `False` | 日志显示线程 ID | `options::set_show_thread_id` |
| `ConsoleOutput` | bool | auto | 控制台输出开关 | `options::set_console_output` |
| `Overlap_Connection` | bool | `False` | 允许同一地址多个客户端 | `options::set_overlap_connection` |
| `Wait_Connection_ReadyOk` | bool | `True` | `prepare_done` 是否等待客户端就绪 | `options::set_wait_connection_ready_ok` |
| `Wait_Connection_Timeout` | int (ms) | `30000` | 上述等待的超时 | `options::set_wait_connection_timeout` |
| `IPC_Serv_ThreadCount` | int | 平台相关 | IPC 服务端线程数 | `options::set_ipc_serv_thread_count` |
| `IPC_Serv_MaxQueueLength` | int | 平台相关 | IPC 入站队列长度 | `options::set_ipc_serv_max_queue_length` |
| `IPC_Serv_MaxMsgSize` | int (bytes) | 平台相关 | 单条 IPC 消息最大字节数 | `options::set_ipc_serv_max_msg_size` |
| `Fixed_Sequenced_Time` | int (ms) | `20000` | 顺序通知回退阈值 | `options::set_fixed_sequenced_time` |
| `DataHandle_Idle_Timeout` | int (ms) | `600000` | 自动回收句柄空闲阈值 | `options::set_data_handle_idle_timeout` |
| `DataHandle_Pool_Scan_Interval` | int (ms) | `5000` | 回收扫描间隔 | `options::set_data_handle_pool_scan_interval` |
| `LF_P2P_name` | string | `""` | 本进程 P2P 组名 | `options::set_p2p_name` |
| `No_Reponse_Cmd_NULL_Flush_Threshold` | int | `5000` | 单向通知 null-flush 阈值 | `options::set_no_reponse_cmd_null_flush_threshold` |
| `debug` | string | — | 执行 C4 控制台调试命令（只写） | `options::set_debug` |

**布尔值格式**：`"True"` / `"False"` / `"1"` / `"0"` / `"Yes"` / `"No"`（大小写不敏感）。类型化 API 一律使用规范的 `"True"` / `"False"`。

**未知选项静默忽略**，不会报错。拼写错误没有反馈，请仔细核对。

**选项不跨 `LF_Shutdown` 持久化**：`shutdown` 后 native 层不会重置选项值，但重启 framework 时应重新 apply 应用层配置。

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

**异步调用的错误处理**：

```rust
// 同步的 dispatch 失败通过 ? 传播
async_call::call_async("App", &req, move |result| {
    // 异步的传输失败通过 match 处理
    match result {
        Ok(mut resp) => { /* ... */ }
        Err(e)        => eprintln!("异步调用失败：{}", e),
    }
})?;
```

---

## 第 4 章 测试与验证

### 4.1 测试分层

Rust 绑定的测试分**八层**：

| 层级 | 命令 | 依赖 native | 期望结果 |
|------|------|:-----------:|----------|
| **单元测试** | `cargo test --lib` | 部分 | 122 通过，23 忽略 |
| **忽略的单元测试** | `cargo test --lib -- --ignored --test-threads=1` | ✅ | 23 通过 |
| **ABI 冒烟测试** | `cargo test --test abi_smoke` | ✅ | 5 通过，1 忽略 |
| **框架端到端** | `cargo test --test framework_e2e -- --ignored --test-threads=1` | ✅ | 2 通过 |
| **选项端到端** | `cargo test --test options_e2e -- --ignored --test-threads=1` | ✅ | 6 通过 |
| **身份侧数据端到端** | `cargo test --test identity_e2e -- --ignored --test-threads=1` | ✅ | 1 通过 |
| **三套寻址端到端** | `cargo test --test addressing_e2e -- --ignored --test-threads=1` | ✅ | 5 通过 |
| **异步调用端到端** | `cargo test --test async_e2e -- --ignored --test-threads=1` | ✅ | 10 通过 |

### 4.2 运行全部测试

**推荐方式**：使用 crate 根目录下的 `test.ps1`。

```powershell
.\test.ps1                     # 全部 8 层
.\test.ps1 -Layer unit         # 只跑单元测试
.\test.ps1 -Layer e2e_addr     # 只跑三套寻址端到端
.\test.ps1 -Layer unit,abi     # 跑多个层
.\test.ps1 -RequireNative      # native 缺失时立即失败
.\test.ps1 -NoCapture          # 显示 [SKIP] 行
```

**等价的手动命令**（适用于任何平台）：

```bash
# 1. 快速单元测试（并行安全）
cargo test --lib

# 2. 触及进程级 native 状态的单元测试（必须串行）
cargo test --lib -- --ignored --test-threads=1

# 3. Stage 1 原始 ABI 层测试
cargo test --test abi_smoke

# 4. 框架端到端（必须串行）
cargo test --test framework_e2e -- --ignored --test-threads=1

# 5. 类型化选项端到端（必须串行）
cargo test --test options_e2e -- --ignored --test-threads=1

# 6. P2P 身份侧数据端到端（必须串行）
cargo test --test identity_e2e -- --ignored --test-threads=1

# 7. 三套寻址端到端（必须串行）
cargo test --test addressing_e2e -- --ignored --test-threads=1

# 8. 异步调用端到端（必须串行）
cargo test --test async_e2e -- --ignored --test-threads=1
```

### 4.3 为什么部分测试是 `#[ignore]`

**根本原因**：进程级 native 状态（框架准备 / 关闭、网络事件、状态投递、选项存储、P2P 注册表）只能**串行访问**。Rust test harness 默认并发运行测试，与之冲突。

**危险组合示例**：

- 线程 A 调用 `LF_Shutdown`（清空回调 + 停止工作线程）
- 线程 B 调用 `LF_Set_Network_Event`（重新设置回调指针）

两者竞争导致 native 层持有的回调指针与工作线程状态不一致 → 后续调用崩溃（`STATUS_ACCESS_VIOLATION`）。

`#[ignore]` 是标准隔离机制——不改变生产代码，只改变测试运行策略。所有涉及进程级 native 状态的测试都加了 `--test-threads=1` 强制串行。

### 4.4 判断测试是否真正运行

**集成测试的陷阱**：native 库缺失时，测试会打印 `[SKIP]` 并返回 `ok`。**测试显示 `ok` 不代表真实运行过。**

**判断方法**：

```bash
# 加 --nocapture 让 [SKIP] 输出到终端
cargo test --test addressing_e2e -- --nocapture 2>&1 | grep SKIP

# 无输出 → native 库已加载，测试真实运行 ✅
# 输出 [SKIP] → native 库未找到，测试被跳过 ⚠️
```

或使用 `test.ps1 -NoCapture` 让脚本自动处理。

### 4.5 期望的测试结果

在 LingoFuse v3.10 native 库存在的前提下，`.\test.ps1` 的期望输出：

```
Layer 'unit'        122 passed, 0 failed, 23 ignored
Layer 'ignored'      23 passed, 0 failed
Layer 'abi'           5 passed, 0 failed,  1 ignored
Layer 'e2e'           2 passed, 0 failed
Layer 'e2e_opts'      6 passed, 0 failed
Layer 'e2e_ident'     1 passed, 0 failed
Layer 'e2e_addr'      5 passed, 0 failed
Layer 'e2e_async'    10 passed, 0 failed
```

**合计 174 个测试**（含 24 个 `#[ignore]`）。

### 4.6 与其他绑定共享的验证原则

Rust 绑定的测试分层原则与 C++ / Python / Pascal 绑定一致：

1. **单元测试并行安全**——纯逻辑与无状态操作
2. **`#[ignore]` 隔离进程级状态**——涉及框架生命周期、全局选项、全局注册表
3. **端到端集成**——完整调用链，按关注点分文件
4. **native 缺失时 `[SKIP]`**——保证 CI 在没有 native 库的环境中仍可通过

跨语言回归时，C++ 的 `test_lingofuse` 与 Rust 的 `cargo test` 应观察到相同的 wire 字节序列。附录 C.2 给出具体的字节级对照。

### 4.7 测试失败排查

| 症状 | 原因 | 修法 |
|------|------|------|
| `cargo check --lib` 有 warning | 代码未过 lint | 按提示补 `#[allow]` 或修正 |
| `LibraryNotFound` | native 库不在搜索路径 | 把库放到可执行文件旁或加入 PATH |
| `SymbolMissing { symbol: "LF_xxx" }` | native 库版本不匹配 | 核对 59 个符号是否齐全 |
| 崩溃在 `LF_Set_Network_Event` | 测试并发访问 native 全局状态 | 加 `--test-threads=1` |
| 端到端测试卡在 retry 循环 | mesh 广播未到达 | 加大 retry 次数或改用 `Wait_Connection_ReadyOk=True` |
| `STATUS_ACCESS_VIOLATION`（`0xc0000005`） | 测试 panic 后 Drop 顺序不当，句柄在 `exit_main_thread` 之前被释放 | 修复 panic 本身的根因；不要屏蔽断言 |
| 异步测试报 `trailing characters` | 结果句柄的尾部 `\0` 未被剥离 | 应使用 `read_string` 而非 `read_all_bytes`（v0.3.0 已修复） |
| `local_call_roundtrip` 失败 | 回调类型不匹配 | 检查闭包签名 |

---

## 第 5 章 测试程序覆盖领域

Rust 绑定的测试体系覆盖以下 **12 个领域**。每个领域都对应生产代码的一个关键能力。

### 5.1 领域一：动态库加载与符号解析

**覆盖的测试**：

- `sys::loader::tests::platform_file_name_is_non_empty_on_supported_targets`
- `sys::loader::tests::is_loaded_reflects_singleton_state`
- `abi_smoke::native_library_loads_and_symbols_resolve`

**验证能力**：

- 平台探测返回正确的库文件名
- 搜索路径拼接正确（exe 目录 / CWD）
- 59 个导出符号全部解析成功
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

- `app_handle::tests::*`（10 个）
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

- `framework::tests::*`（20 个，含新增的 UID / P2PName / `get_option`）

**验证能力**：

- 运行时选项设置与读取（含 interior NUL 拒绝）
- 健康检查（主线程、App、API、UID、P2PName）
- 无框架状态下 `reset_prepare` / `exit_main_thread` / `shutdown` 的安全性
- 已释放句柄的优雅报错
- 幂等性

### 5.6 领域六：网络事件

**覆盖的测试**：

- `network_events::tests::*`（6 个）

**验证能力**：

- 单独安装 connect / disconnect 处理器
- 替换语义（第二次 `set_network_event` 丢弃所有旧处理器）
- 幂等清除
- 安装状态查询

### 5.7 领域七：状态队列

**覆盖的测试**：

- `status::tests::*`（6 个）

**验证能力**：

- 状态队列计数 / 读取 / 投递 / 批量拉取
- interior NUL 拒绝
- 边界条件（`max_messages == 0`）

### 5.8 领域八：P2P 身份侧数据

**覆盖的测试**：

- `data_handle::tests::p2p_uid_on_owning_handle_returns_null_uid`
- `data_handle::tests::p2p_name_on_owning_handle_returns_empty_string`
- `data_handle::tests::p2p_uid_on_disposed_handle_fails_cleanly`
- `data_handle::tests::p2p_name_on_disposed_handle_fails_cleanly`
- `data_handle::tests::p2p_accessors_are_callable_on_borrowed_handle`
- `identity_e2e::identity_roundtrip`

**验证能力**：

- 对回调 `input` 句柄调用 `p2p_uid()` / `p2p_name()` 返回**有效身份**
- 对 `output` 句柄调用返回 `Uid::NULL` / 空串
- 对自建句柄调用返回 `Uid::NULL` / 空串
- 对已 dispose 的句柄调用返回 `Err(NullHandle)`
- 侧数据指针的 5 秒失效规则被正确封装（包装层立即拷贝）

### 5.9 领域九：三套寻址

**覆盖的测试**：

- `addressing_e2e::app_name_addressing_e2e`
- `addressing_e2e::uid_addressing_e2e`
- `addressing_e2e::p2pname_addressing_e2e`
- `addressing_e2e::p2p_registration_e2e`
- `addressing_e2e::query_api_for_uid_and_p2pname_e2e`

**验证能力**：

- **App 名寻址**：`call` / `try_call` / `notify` / `sequenced_notify` 的完整往返
- **UID 寻址**：通过 `whoami` 获取自身 UID；`call_by_uid` / `try_call_by_uid` / `notify_by_uid` / `sequenced_notify_by_uid` 的完整往返；UID 在会话内**稳定**，在 mesh 广播后**可路由**
- **P2PName 寻址**：`call_by_p2p_name` / `try_call_by_p2p_name` / `notify_by_p2p_name` / `sequenced_notify_by_p2p_name` 的完整往返
- **进程级 P2P 注册**：`register_p2p_call` / `register_p2p_notify` / `unregister_p2p`；P2P API 通过 UID 可达；重名拒绝；注销后重注册成功
- **查询 API**：`check_app` / `check_api` / `check_uid` / `check_uid_api` / `check_p2p_name` / `check_p2p_name_api`，含负路径（null UID / 缺席 App / 缺席 group）

### 5.10 领域十：类型化选项

**覆盖的测试**：

- `options::tests::*`（17 个）
- `options_e2e::*`（6 个）

**验证能力**：

- 布尔 / 整数 / 字符串选项的 set / get 往返
- 未知选项 fallback（`false` / `0` / `""`）
- interior NUL 拒绝
- 类型化 getter 与 raw `framework::get_option` 的一致性
- `password` getter 返回掩码而非明文

### 5.11 领域十一：异步调用家族

**覆盖的测试**：

- `async_call::tests::*`（15 个）
- `async_e2e::*`（10 个）

**验证能力**：

- **回调式**：`call_async` / `call_async_sequenced` / `call_async_by_uid` / `call_async_by_p2p_name` 的完整往返
- **阻塞式**：`call_async_wait` / `call_async_wait_by_uid` / `call_async_wait_by_p2p_name`，返回 `Vec<u8>`
- **单一错误路径**：dispatch 失败时，回调在调用者线程上**同步**触发 `Err`，入口也返回 `Err`
- **链式**：回调内再发起异步调用
- **扇出**：N 个并发异步调用 + 结果聚合
- **panic 隔离**：闭包 panic 被 `catch_unwind` 隔离，进程存活并保持可用
- **`recv_with_timeout` 三种分支**：正常值、超时、channel 断开

### 5.12 领域十二：基础端到端集成

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

### 5.13 领域覆盖矩阵

| 领域 | 测试数 | 依赖 native | 是否真实调用 |
|------|:------:|:-----------:|:------------:|
| 动态库加载与符号解析 | 3 | ✅ | ✅ |
| 数据句柄生命周期 | 10 | ✅ | ✅ |
| 统一 I/O 层 | 20 | 部分 | 部分 |
| 应用句柄与回调桥接 | 10 | ✅ | ✅ |
| 进程级框架 | 20 | ✅ | 部分 |
| 网络事件 | 6 | ✅ | ✅ |
| 状态队列 | 6 | ✅ | 部分 |
| P2P 身份侧数据 | 6 | ✅ | ✅ |
| 三套寻址 | 5 | ✅ | ✅ |
| 类型化选项 | 23 | ✅ | ✅ |
| 异步调用家族 | 25 | ✅ | ✅ |
| 基础端到端集成 | 2 | ✅ | ✅ |
| **合计** | **136** | — | — |

> 上表按测试「逻辑归属」计数，与 `cargo test` 输出的数字（174）略有差异，因为部分测试同时覆盖多个领域，且 `cargo test` 的数字包含未单独归类的辅助测试。

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
| 59 个导出符号是否全部存在 | `native_library_loads_and_symbols_resolve` | ✅ 已确认 |
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
| 发送方身份读取是否正确 | `identity_roundtrip` | ✅ 已确认 |

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

#### 6.2.8 三套寻址类（v0.3.0 新增）

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| App 名寻址完整往返 | `app_name_addressing_e2e` | ✅ 已确认 |
| UID 寻址完整往返 | `uid_addressing_e2e` | ✅ 已确认 |
| UID 在会话内是否稳定 | `uid_addressing_e2e` 的 double-probe | ✅ 已确认 |
| UID 广播后可路由 | `wait_until(check_uid)` | ✅ 已确认 |
| P2PName 寻址完整往返 | `p2pname_addressing_e2e` | ✅ 已确认 |
| 进程级 P2P 注册 / 注销 | `p2p_registration_e2e` | ✅ 已确认 |
| P2P API 通过 UID 可达 | `p2p_registration_e2e` | ✅ 已确认 |
| 4 个额外查询 API | `query_api_for_uid_and_p2pname_e2e` | ✅ 已确认 |

#### 6.2.9 类型化选项类（v0.3.0 新增）

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 布尔 / 整数 / 字符串选项的 set/get 往返 | `bool_options_roundtrip` 等 | ✅ 已确认 |
| 类型化 getter 与 raw 读取一致 | `typed_getter_matches_raw_get_option` | ✅ 已确认 |
| 未知选项 fallback | `unknown_option_returns_empty` | ✅ 已确认 |
| `password` 返回掩码 | `string_options_roundtrip` | ✅ 已确认 |

#### 6.2.10 异步调用家族类（v0.3.0 新增）

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 回调式异步完整往返 | `callback_style_app_name_async_e2e` | ✅ 已确认 |
| 阻塞式异步完整往返 | `blocking_style_app_name_async_e2e` | ✅ 已确认 |
| dispatch 失败的单一错误路径 | `dispatch_failure_returns_err_and_fires_callback` | ✅ 已确认 |
| 回调内链式异步调用 | `chained_async_roundtrip` | ✅ 已确认 |
| N 个并发异步调用 | `fan_out_async_roundtrip` | ✅ 已确认 |
| 回调 panic 隔离 | `callback_panic_is_isolated` | ✅ 已确认 |
| 结果字节无尾部 NUL | `blocking_style_*_async_e2e` 的 JSON 解析 | ✅ 已确认 |

#### 6.2.11 错误处理类

| POC 项目 | 被哪个测试覆盖 | 结论 |
|---------|---------------|------|
| 已释放句柄操作是否报错 | 多个 `*_disposed_*` 测试 | ✅ 已确认 |
| interior NUL 是否拒绝 | 多个 `*_rejects_interior_nul` 测试 | ✅ 已确认 |
| 缺席目标是否优雅返回 | `consumer_only_call_to_absent_app_returns_none` | ✅ 已确认 |
| 超时是否可检测 | `try_call` 返回 `None`；`call_async_wait` 返回 `Err(Timeout)` | ✅ 已确认 |
| 错误码分类是否清晰 | `ErrorCode` 枚举 + 单元测试 | ✅ 已确认 |

### 6.3 仍需自行验证的场景

Rust 绑定测试体系**没有**覆盖以下场景。如果你的项目依赖这些能力，需要自行验证。

| 未覆盖的场景 | 原因 | 建议 |
|-------------|------|------|
| **跨进程调用** | 集成测试在单进程内运行 | 启动两个独立 Rust 进程；或用 Rust + Python 混合 |
| **跨机器调用** | 需要两台物理机 | 部署到两台机器上验证 |
| **真实网络事件触发** | 需要第二个进程加入 mesh | 启动两个进程，观察事件回调 |
| **P2PName 真实负载均衡** | 需要多个提供同一组名的客户端 | 启动 N 个服务实例，观察请求分发 |
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
| 数据句柄 | 10 | 1 天 |
| I/O 层 | 7 | 1 天 |
| 回调桥接 | 7 | 1.5 天 |
| 框架生命周期 | 6 | 1 天 |
| 网络事件 | 5 | 0.5 天 |
| 三套寻址 | 8 | 1 天 |
| 类型化选项 | 4 | 0.5 天 |
| 异步调用家族 | 7 | 1.5 天 |
| 错误处理 | 5 | 0.5 天 |
| **合计** | **68** | **约 9.5 人天** |

**净收益**：

- **约 9.5 人天**的 POC 工作已被替代
- 剩下需要做的仅是**部署环境相关的验证**（跨进程、跨机器、长时间稳定性、负载均衡）
- 每次 native 库升级，重跑 `.\test.ps1` 即可回归

（上表为**量级估算**，不同项目的实际收益会因代码熟悉度、业务复杂度而异。）

---

## 第 7 章 已知限制与最佳实践

### 7.1 已知限制

#### 7.1.1 `AppHandle` 不实现 `Send` / `Sync`

绑定刻意把句柄所有权限制在单线程。回调仍可在原生 worker 线程上运行，闭包必须满足 `Fn + Send + Sync`。

**影响**：不能把 `AppHandle` 放进 `Arc<Mutex<>>` 让多线程共享。若需要，把注册逻辑集中到一个线程，其它线程通过 `channel` 投递请求。

#### 7.1.2 回调上下文泄漏

**每个注册的 API**（无论 App 级还是 P2P 级）泄漏一个小的上下文对象（几十字节），直到进程退出。

**权衡**：原生库可能在任意时间（包括与取消注册并发时）调用回调，回收会造成 use-after-free。代价有界。

**影响**：不要在紧密循环中注册 / 取消注册 API。注册后长期使用是设计场景。

#### 7.1.3 单进程端到端测试

`tests/framework_e2e.rs` / `tests/identity_e2e.rs` / `tests/addressing_e2e.rs` / `tests/async_e2e.rs` 中服务端和调用端在同一进程内，走的是 mesh 的**本地优先路由**（P2PName 除外）。

**影响**：验证了完整的调用链，但没跨越 TCP / 跨进程 IPC 跳。跨进程验证需要两个独立 OS 进程。

#### 7.1.4 状态队列的 ABI 限制

原生 ABI 无法区分「空队列」和「空消息」：两者都产生空字符串。

**修法**：先调用 `get_status_count()` 判断。

#### 7.1.5 `generate_app_name` / `get_option` / 身份访问器指针有效期

原生指针仅有约 5 秒有效期。Rust 绑定**立即拷贝**到 `String` / `Uid`，返回的值可以任意保留。

**影响**：直接用 `sys` 层时需自行处理。

#### 7.1.6 无 CI 覆盖

LingoFuse 的自动化 CI 只有 C++ 部分。Rust 测试需在本地运行。

#### 7.1.7 平台限制

- 大端架构未测试（协议约定小端）
- 32 位 Windows 未在 Rust 测试中覆盖
- aarch64 / loongarch64 / RISC-V 等边缘平台移植中

#### 7.1.8 `call_async_wait` 返回 `Vec<u8>` 而非 `DataHandle`

**这是有意的契约**，不是缺陷。

异步族交付的结果句柄归**框架所有**，回调返回瞬间即释放。把它包装成 owning `DataHandle` 送出回调边界会导致 use-after-free（read-after-free）。安全的选择只有：

1. 在回调内拷贝字节（本实现）
2. 让调用方提供反序列化目标

本绑定选择方案 1。调用方拿到 `Vec<u8>` 后可用 `io::loads_json` 解码为具体类型。

#### 7.1.9 空 UID 的调用行为未定义

C ABI 文档称 null UID 是"合法参数，只是匹配不到任何客户端"。但实际 wire 行为不在稳定契约内：dispatcher 可能返回空响应、lookup 错误或 size=0 句柄，取决于路由表状态。

Rust 绑定**不**对空 UID 的调用结果做任何断言。**查询 API**（`check_uid(Uid::NULL)` 返回 `false`）的契约清晰，因此仍被保证。

#### 7.1.10 `debug` 选项需 framework 运行

`debug` 是"写入时执行命令"的选项，而非普通字符串存储。某些命令（`RegInfo`、`service`、`tunnel`）依赖模拟主线程正在运行。**在 framework 启动前调用会阻塞**。

Rust 绑定的 `options` 模块只提供 setter / getter 接口，不在其中添加额外保护；调用方需自行确保调用时机。

#### 7.1.11 选项不跨 `LF_Shutdown` 重置

`LF_Shutdown` 清理网络状态、App 池、句柄池，但**不重置选项存储**。选项值跨 shutdown 保留。

**含义**：应用重启 framework 时应重新 apply 配置，而**不是**依赖"shutdown 会恢复默认"。

#### 7.1.12 异步调用无超时 / 无取消

C ABI 的异步族没有超时参数与取消句柄。回调式入口因此也没有超时；阻塞式入口的 `timeout` 是**纯 Rust 侧**实现（`mpsc::recv_timeout`），超时后返回 `Err(Timeout)` 并放弃回调，但 native 请求**不会**被取消。

调用方如需硬性超时，应在上层跟踪未完成请求并在配置的时间后放弃。

### 7.2 最佳实践

#### 7.2.1 永远写重试循环

mesh 广播到达本地缓存最多需要约 3 秒。即使 `Wait_Connection_ReadyOk=True`，也不保证广播已到达。

```rust
use std::time::Duration;

fn call_with_retry(
    app: &str,
    req: &mut DataHandle,
) -> Result<DataHandle, lingofuse::error::Error> {
    for _ in 0..30 {
        match framework::try_call(app, req, 3000)? {
            Some(resp) => return Ok(resp),
            None => {
                req.set_position(0)?;
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    }
    Err(lingofuse::error::Error::new(
        lingofuse::error::ErrorCode::Timeout,
        "target did not become reachable within 6 seconds",
    ))
}
```

同样适用于 `try_call_by_uid` / `try_call_by_p2p_name`。

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

#### 7.2.9 用类型化选项 API 而非字符串

字符串选项拼写错误是静默失败（native 层不报错）。类型化 API 在编译期捕获拼写错误。

```rust
// ❌ 拼写错误静默失败
framework::set_option("Waitt_Connection_ReadyOk", "False")?;   // 忽略，无反馈

// ✅ 编译期检查
options::set_wait_connection_ready_ok(false)?;
```

#### 7.2.10 异步调用优先用阻塞式获得 `Result`

如果不需要真正的"非阻塞"，用 `call_async_wait` 会得到清晰的 `Err(Timeout)` 语义，而不是 `try_call` 的 `Ok(None)` 二义性。

```rust
// 相对模糊：超时和空响应用同一个 None
let opt = framework::try_call("App", &req, 3000)?;

// 相对清晰：超时是明确的 Err(Timeout)
let bytes = async_call::call_async_wait(
    "App", &req, Some(Duration::from_secs(3)),
)?;
```

`call_async_wait` 唯一的代价是返回 `Vec<u8>`（见 7.1.8），需要调用方自行解码。

#### 7.2.11 用 `Uid` 而非裸字节数组

```rust
// ❌ 手工维护 32 字节，容易出错
let mut uid_bytes = [0u8; 32];
// ...

// ✅ 类型安全，Debug / Display 友好
let uid = Uid::from_hex("...")?;
println!("calling {}", uid);
framework::call_by_uid(uid, &req, 3000)?;
```

#### 7.2.12 P2P 身份只能在回调的 `input` 句柄上读取

```rust
app.register_call("whoami", "desc", |input, output| {
    // ✅ 从 input 读取发送方身份
    let uid = input.p2p_uid().unwrap_or_default();
    let name = input.p2p_name().unwrap_or_default();

    // ❌ 不要从 output 读（返回 NULL / 空串）
    // ❌ 不要从自建句柄读（返回 NULL / 空串）
})?;
```

---

## 附录 A 快速参考

### A.1 常用代码片段

```rust
// --- 引入 ---
use lingofuse::app_handle::AppHandle;
use lingofuse::async_call;
use lingofuse::data_handle::DataHandle;
use lingofuse::error::ErrorCode;
use lingofuse::uid::Uid;
use lingofuse::{framework, io, network_events, options, p2p, status, sys};

// --- 加载库 ---
sys::load_library()?;

// --- 定义载荷 ---
#[derive(Serialize, Deserialize)]
struct MyRequest { /* ... */ }

// --- 配置选项（类型化）---
options::set_quiet(true)?;
options::set_wait_connection_ready_ok(false)?;
options::set_p2p_name("worker_group")?;

// --- 创建应用 ---
let app = AppHandle::new("AppName", "description")?;

// --- 注册 App 级 Call ---
app.register_call("api", "desc", |input, output| {
    if let Ok(req) = io::read_json::<MyRequest>(input) {
        let _ = io::write_json(output, &MyResponse { /* ... */ });
    }
})?;

// --- 注册进程级 P2P Call ---
p2p::register_p2p_call("whoami", "desc", |input, output| {
    let uid = input.p2p_uid().unwrap_or_default();
    let name = input.p2p_name().unwrap_or_default();
    let _ = io::write_json(output, &serde_json::json!({
        "uid_hex": uid.to_hex(),
        "p2p_name": name,
    }));
})?;

// --- 网络准备 ---
framework::reset_prepare();
framework::prepare_service("ipc:addr", "ipc:addr")?;
framework::prepare_client("ipc:addr", Some(&app))?;
framework::prepare_done()?;

// --- 同步远程调用（App 名）---
let mut req = DataHandle::new("api")?;
io::write_json(&mut req, &my_request)?;
req.set_position(0)?;
let resp = framework::try_call("TargetApp", &req, 3000)?;

// --- 同步远程调用（UID）---
let resp = framework::try_call_by_uid(uid, &req, 3000)?;

// --- 同步远程调用（P2PName）---
let resp = framework::try_call_by_p2p_name("worker_group", &req, 3000)?;

// --- 单向通知 ---
framework::notify("TargetApp", &req)?;
framework::sequenced_notify("TargetApp", &req)?;

// --- 异步调用（回调式）---
async_call::call_async("TargetApp", &req, move |result| {
    match result {
        Ok(mut resp) => { /* ... */ }
        Err(e)        => eprintln!("异步失败：{}", e),
    }
})?;

// --- 异步调用（阻塞式）---
let bytes = async_call::call_async_wait(
    "TargetApp", &req, Some(Duration::from_secs(5)),
)?;
let text = String::from_utf8_lossy(&bytes);
let value: MyResponse = io::loads_json(&text)?;

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

| 选项名 | 类型 | 默认 | 常用值 | Rust 类型化 API |
|--------|------|------|--------|-----------------|
| `Overlap_Connection` | bool | `False` | 多应用同地址时 `True` | `options::set_overlap_connection` |
| `Wait_Connection_ReadyOk` | bool | `True` | 弹性集群时 `False` | `options::set_wait_connection_ready_ok` |
| `Wait_Connection_Timeout` | int (ms) | `30000` | 慢网络时 `60000` | `options::set_wait_connection_timeout` |
| `Quiet` | bool | `False` | 生产环境 `True` | `options::set_quiet` |
| `ConsoleOutput` | bool | auto | 容器环境 `False` | `options::set_console_output` |
| `ShowThreadID` | bool | `False` | 调试时 `True` | `options::set_show_thread_id` |
| `Fixed_Sequenced_Time` | int (ms) | `20000` | 高频顺序通知时 `5000` | `options::set_fixed_sequenced_time` |
| `LF_P2P_name` | string | `""` | 组名 | `options::set_p2p_name` |
| `DataHandle_Idle_Timeout` | int (ms) | `600000` | 调试时 `0` 禁用 | `options::set_data_handle_idle_timeout` |

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
| `CallFailed` | 远程调用返回 null 句柄 / 异步 dispatch 失败 | 检查 framework 是否启动 / target 是否可达 |
| `RegistrationFailed` | API 名重复 | 换名或先 unregister |
| `NotConnected` | 框架未运行时的操作 | 先 `prepare_done` |
| `Timeout` | 远程调用超时（含 `call_async_wait` 的 Rust 侧超时） | 增大 timeout 或重试 |

---

## 附录 C 跨语言对照

### C.1 核心 API 对照

| 功能 | Pascal | Python | C++ | **Rust** |
|------|:------:|:------:|:---:|:--------:|
| 加载库 | 静态链接 | import | `LF_LoadLibrary` | `sys::load_library()` |
| 自动句柄 | `LF_CreateDataEx` | `DataHandle()` | `DataHandle(name)` | `DataHandle::new` |
| 永久句柄 | `LF_CreateData_PermanentEx` | — | `createPermanent` | `DataHandle::create_permanent` |
| 写 JSON | `LF_WriteString` | `lf_io.write_json` | `io::write_json` | `io::write_json` |
| 读 JSON | `LF_ReadString` | `lf_io.read_json` | `io::read_json` | `io::read_json` |
| 读发送方 UID | `LF_Get_P2P_UID`（指针） | `dh.get_p2p_uid()` | `dh.getP2PUid()` | `DataHandle::p2p_uid` |
| 读发送方 Name | `LF_Get_P2P_Name`（指针） | `dh.get_p2p_name()` | `dh.getP2PName()` | `DataHandle::p2p_name` |
| 创建应用 | `LF_CreateAppEx` | `App(name)` | `App(name, desc)` | `AppHandle::new` |
| 注册 Call | `LF_RegisterCall_M` | `@app.expose` | `registerCall` | `AppHandle::register_call` |
| 注册 Notify | `LF_RegisterNotify_M` | `@app.expose(notify=True)` | `registerNotify` | `AppHandle::register_notify` |
| 注册 P2P Call | `LF_Register_P2P_Call` | — | — | `p2p::register_p2p_call` |
| 本地调用 | `LF_LocalCall` | `app.local_call` | `localCall` | `AppHandle::local_call` |
| App 名同步调用 | `LF_Call` | `call()` | `lingofuse::call` | `framework::call` |
| UID 同步调用 | `LF_UID_Call` | — | — | `framework::call_by_uid` |
| P2PName 同步调用 | `LF_P2PNAME_Call` | — | — | `framework::call_by_p2p_name` |
| App 名异步调用 | `LF_Async_Call` | `Target.call_future` | `lingofuse::callAsync` | `async_call::call_async` |
| App 名异步等待 | — | `await` | — | `async_call::call_async_wait` |
| 选项设置 | `LF_Set_Opt_XXX` | — | `setOption` | `options::set_xxx` |
| 选项读取 | `LF_Get_Opt_XXX` | — | `LF_GetOption` | `options::get_xxx` |
| 网络准备 | `LF_PrepareService/Client/Done` | `prepare_*` | `prepare*` | `framework::prepare_*` |
| 关闭 | `LF_Shutdown` | `shutdown()` | `shutdown` | `framework::shutdown` |
| 网络事件 | `LF_Set_Network_Event` | — | `setNetworkEvent` | `network_events::set_network_event` |

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

**Rust 服务端 + C++ 异步调用端**

Rust 侧使用 `p2p::register_p2p_call` 注册进程级 API；C++ 侧通过 `LF_UID_Async_Call` 调用。两侧共享同一 wire 契约，字节完全一致。

---

*文档版本: v2.0*
*对应 Rust 绑定: Stage 1 + Stage 2 + Stage 3 完成*
*对应 LingoFuse 版本: v3.10 / C4 v4.01*
*最后更新: 2026-10-13*
*维护者: LingoFuse 团队*
