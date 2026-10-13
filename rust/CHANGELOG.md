# 交付：`CHANGELOG.md`

```markdown
# Changelog

本文件记录 `lingofuse` Rust 绑定的所有重要变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [0.3.0] - 2026-10-13

### 摘要

本次升级将 Rust 绑定对 native C ABI 的覆盖率从 **37 / 59** 提升至 **59 / 59**，并引入三个全新模块（`uid` / `options` / `p2p`）和一个现代化异步调用模块（`async_call`）。所有既有 API 保持向后兼容；本次为纯增量版本。

新增 22 个 C ABI 导出的安全封装、38 个类型化选项 getter/setter、以及一套基于闭包的异步 API，让 Rust 调用方无需接触 `unsafe` 即可使用 LingoFuse 的全部机制。

---

### 新增

#### 新模块

| 模块 | 用途 |
|------|------|
| `lingofuse::uid` | 32 字节 P2P 会话标识的安全 newtype，带 hex 转换与 `Debug` / `Display` |
| `lingofuse::options` | 类型化选项 getter/setter，镜像 native 层 `LF_Set_Opt_*` / `LF_Get_Opt_*` 家族 |
| `lingofuse::p2p` | 进程级 P2P API 注册（独立于任何 App） |
| `lingofuse::async_call` | 现代化异步调用：闭包式 + 阻塞式两种风格 |

#### 新增 C ABI 封装（22 个）

**数据句柄身份访问器（2）**
- `LF_Get_P2P_UID`
- `LF_Get_P2P_Name`

**进程级 P2P 注册（3）**
- `LF_Register_P2P_Call`
- `LF_Register_P2P_Notify`
- `LF_Unregister_P2P`

**App 名寻址异步（2）**
- `LF_Async_Call`
- `LF_Async_Sequenced_Call`

**UID 寻址（5）**
- `LF_UID_Call`
- `LF_UID_Async_Call`
- `LF_UID_Async_Sequenced_Call`
- `LF_UID_Notify`
- `LF_UID_Sequenced_Notify`

**P2PName 寻址（5）**
- `LF_P2PNAME_Call`
- `LF_P2PNAME_Async_Call`
- `LF_P2PNAME_Async_Sequenced_Call`
- `LF_P2PNAME_Notify`
- `LF_P2PNAME_Sequenced_Notify`

**额外查询（4）**
- `LF_Check_UID`
- `LF_Check_UID_Api`
- `LF_Check_P2PNAME`
- `LF_Check_P2PNAME_Api`

**选项读取（1）**
- `LF_GetOption`

#### 新增公共 API

**`uid` 模块**
- `Uid` 类型：`Copy` / `Eq` / `Hash` / `Default`，含 `from_bytes` / `from_slice` / `from_hex` / `as_bytes` / `to_bytes` / `to_hex` / `is_null`
- `Uid::NULL` 常量
- 常量 `UID_LEN` (32) / `UID_HEX_LEN` (64)

**`options` 模块**
- 底层 primitive：`set_bool` / `get_bool` / `set_u64` / `get_u64` / `set_i64` / `get_i64` / `set_string` / `get_string`
- 类型化家族（每组含 getter/setter）：
  - `debug`（只写）
  - `password`（读返回掩码）
  - `quiet` / `show_thread_id` / `console_output`
  - `overlap_connection` / `wait_connection_ready_ok` / `wait_connection_timeout`
  - `ipc_serv_thread_count` / `ipc_serv_max_queue_length` / `ipc_serv_max_msg_size`
  - `fixed_sequenced_time`
  - `p2p_name`
  - `data_handle_idle_timeout` / `data_handle_pool_scan_interval`
  - `no_reponse_cmd_null_flush_threshold`

**`p2p` 模块**
- `register_p2p_call<F>` / `register_p2p_notify<F>` / `unregister_p2p`

**`async_call` 模块**
- 回调式：`call_async` / `call_async_sequenced` / `call_async_by_uid` / `call_async_by_p2p_name`
- 阻塞式：`call_async_wait` / `call_async_wait_by_uid` / `call_async_wait_by_p2p_name`
- 类型别名 `AsyncCallback`

**`framework` 模块新增**
- `get_option(option: &str) -> Result<String, Error>`
- `call_by_uid` / `try_call_by_uid` / `notify_by_uid` / `sequenced_notify_by_uid`
- `call_by_p2p_name` / `try_call_by_p2p_name` / `notify_by_p2p_name` / `sequenced_notify_by_p2p_name`
- `check_uid` / `check_uid_api` / `check_p2p_name` / `check_p2p_name_api`

**`data_handle` 模块新增**
- `DataHandle::p2p_uid(&self) -> Result<Uid, Error>`
- `DataHandle::p2p_name(&self) -> Result<String, Error>`

#### 新增 `sys` 层类型

- `LfP2PUid`：`#[repr(C)]` 的 32 字节结构体，用于 argument-role UID 传值
- `LfAsyncCallOnResult`：异步回调原型

#### 新增单元测试

累计新增 **76 个单元测试**，覆盖：

- `uid`：hex 往返、`from_slice` 长度校验、`Copy` 语义、`Debug` / `Display` 格式、`Hash` / `Eq`（17 个）
- `options`：布尔 / 整数 / 字符串往返、未知选项 fallback、interior-NUL 校验（17 个）
- `p2p`：注册 / 注销往返、重名拒绝、interior-NUL 校验（7 个）
- `data_handle`：P2P 身份访问器在 owning / borrowed / disposed 句柄上的行为（5 个）
- `framework`：`get_option`、UID / P2PName 查询、`uid_to_lf` 桥接、disposed-param 短路（15 个）
- `async_call`：trampoline、dispatch 失败路径、`recv_with_timeout` 各分支（15 个）

#### 新增集成测试

| 文件 | 测试数 | 覆盖内容 |
|------|:------:|---------|
| `tests/options_e2e.rs` | 6 | 类型化选项的完整往返 + 与 raw `get_option` 一致性 |
| `tests/identity_e2e.rs` | 1 | P2P 身份侧数据（回调内读 UID / P2PName；输出句柄为 NULL / 空） |
| `tests/addressing_e2e.rs` | 5 | 三套寻址的同步调用 + 进程级 P2P 注册 + 4 个额外查询 |
| `tests/async_e2e.rs` | 10 | 异步全家族（回调式 + 阻塞式 + dispatch 失败 + 链式 + 扇出 + panic 隔离） |

#### 新增构建 / 测试脚本层

`test.ps1` 从 4 层扩展到 8 层：
- 保留：`unit` / `ignored` / `abi` / `e2e`
- 新增：`e2e_opts` / `e2e_ident` / `e2e_addr` / `e2e_async`

支持按层精确运行，例如 `.\test.ps1 -Layer e2e_addr,e2e_async`。

---

### 变更

#### `sys::bindings`

- 新增 `LfP2PUid` 结构体，含 `NULL` 常量、`from_bytes`、`is_null`、`Default`
- 新增 `LfAsyncCallOnResult` 回调 typedef
- 新增 22 个函数指针 typedef
- 既有 37 个 typedef 逐字不变

#### `sys::loader`

- `NativeLibrary` 字段数：**37 → 59**
- `load_native()` 中 `resolve!` 条目数：**37 → 59**
- 字段与 `resolve!` 的顺序**严格镜像** `LingoFuse.c` 的 `RESOLVE` 序列，共 14 个分组，便于对照审计
- `Debug` 实现的导出计数从 `37` 更新为 `59`
- 加载失败仍被缓存（不重试）；单例语义不变

#### `sys::mod`

- re-export 加入 `LfP2PUid` 与 `LfAsyncCallOnResult`
- 模块文档新增"导出清单"一节，列明 14 个分组的计数

#### `framework`

- 保留全部 16 个既有函数（签名、文档、错误语义完全不变）
- 新增 13 个公共函数（见上文"新增"部分）
- 内部新增 helper `uid_to_lf(Uid) -> LfP2PUid`，把 `Uid` 桥接到 ABI 结构体

#### `data_handle`

- 模块文档新增 "P2P identity side data" 一节，说明侧数据注入机制、有效句柄表格、5 秒指针失效规则
- 内部 `p2p_uid` 从 `*const LfP2PUid` 拷贝 32 字节后立即丢弃指针，不暴露给调用方
- 内部 `p2p_name` 通过 `CStr::from_ptr` 立即拷贝为 `String`
- `Send` / `Sync` 实现保留

#### `lib.rs`

- 新增 4 个 `pub mod`：`options` / `p2p` / `async_call` / `uid`
- crate 文档新增两节："Address schemes"（三套寻址）、"Async result ownership"（框架拥有的句柄不能跨回调边界）
- 状态表更新到 Stage 3

#### `test.ps1`

- `$layers` 从 4 个扩展到 8 个
- `$validLayers` 数组相应扩展（多行排列）
- `all` 展开包含 8 个层
- 其他逻辑（native 检测、循环、报告）逐字不变
- 完全向后兼容旧的调用形式

---

### 修复

#### 产品代码

**`async_call::extract_payload` 读取结果时包含尾部 `\0`**

`call_async_wait` / `call_async_wait_by_uid` / `call_async_wait_by_p2p_name` 在提取响应字节时使用了 `read_all_bytes`，导致 JSON 文本末尾的 NUL 终止符被一并拷出。下游解析器报错 `io::loads_json: trailing characters`。

**修复**：改用 `read_string`。该函数在遇到第一个 NUL 时停止，返回纯 JSON 文本；对无 NUL 的原始负载则保留 fault-tolerant 语义（读全部剩余）。

#### 交付期编译错误

以下三处在交付阶段发现并修正，均已合并入 v0.3.0：

- `src/async_call.rs` 的 `Error::null_handle(&format!(...))` 缺少取引用
- `src/p2p.rs` 的顶层 `use crate::error::{Error, ErrorCode}` 中的 `ErrorCode` 未使用
- `src/p2p.rs` 的测试模块缺少 `use crate::error::ErrorCode`

---

### 已知限制 / 设计决策

本节记录本次升级中明确做出、且未来可能被重新评估的决策。

#### `call_async_wait` 返回 `Vec<u8>` 而非 `DataHandle`

异步族交付的回调句柄归框架所有，回调返回即释放。若把它包装成 owning `DataHandle` 送出回调边界，会导致 use-after-free。安全的选择只有两种：

1. 在回调内拷贝字节（本实现）
2. 让调用方提供反序列化目标

本版本选择方案 1；返回裸字节是 **有意的契约**，不是缺陷。调用方可用 `io::loads_json` 解码为具体类型。

#### `LF_Shutdown` 不重置选项

native 层的 `LF_Shutdown` 清理网络状态、App 池、句柄池，但**不重置选项存储**。选项值跨 shutdown 保留。C 头文件的"not persisted"指的是"应用层必须重新 apply"，不是"native 层会归零"。

因此本版本的测试不包含"选项在 shutdown 后恢复默认"的断言。

#### 空 UID 的调用行为

C ABI 文档说明 null UID 是"合法参数，只是匹配不到任何客户端"。但实际 wire 行为不在稳定契约内：dispatcher 可能返回空响应、lookup 错误或 size=0 句柄，取决于路由表状态。

Rust 绑定**不**对空 UID 的调用结果做任何断言。查询 API（`check_uid(Uid::NULL)` 返回 `false`）的契约清晰，因此仍被测试。

#### `debug` 选项需 framework 运行

`debug` 是"写入时执行命令"的选项，而非普通字符串存储。某些命令（`RegInfo`、`service`、`tunnel`）依赖模拟主线程正在运行。在 framework 启动前调用会阻塞。

本版本的 `options` 模块只提供 setter / getter 接口，不在其中添加额外保护；调用方需自行确保调用时机。

#### P2P 注册的上下文 Box 泄漏

`p2p::register_p2p_call` / `register_p2p_notify` 每次注册会泄漏一个小的 `Box<Context>`。这是与 `app_handle` 层一致的**有意取舍**：native 层可能在任意时刻（包括并发于 unregister）调用回调，回收会造成 use-after-free 窗口。代价有界（每个注册几十字节），正常使用场景不会构成问题。

#### 异步调用无超时 / 无取消

C ABI 的异步族没有超时参数与取消句柄。回调式入口因此也没有超时；阻塞式入口的 `timeout` 是**纯 Rust 侧**实现（`mpsc::recv_timeout`），超时后返回 `Err(Timeout)` 并放弃回调，但 native 请求**不会**被取消。

调用方如需硬性超时，应在上层跟踪未完成请求并在配置的时间后放弃。

#### 单进程端到端测试

所有新增的集成测试都在**同一进程内**运行服务端与客户端。App 名与 UID 寻址因此走 mesh 的 local-first 路径；P2PName 寻址则仍经服务端 dispatcher（走 IPC loopback）。完整跨进程验证需要两个 OS 进程，不在本次范围内。

---

### 未变更

以下部分本次**未**改动，未来如有需求可单独评估：

- `error` 模块（`Error` / `ErrorCode` / source 链）完全不变
- `io` 模块完全不变
- `app_handle` 模块完全不变（`AppHandle` 仍不实现 `Send` / `Sync`）
- `network_events` / `status` 模块完全不变
- `Cargo.toml` 无新依赖（仅使用 `std` + 已有的 `libloading` / `serde` / `serde_json`）
- `rust-version = "1.70"` / `edition = "2021"` 不变
- `examples/` 下的三个示例程序未改动

---

### 测试矩阵（v0.3.0 完成状态）

| Layer | 文件 | 测试数 | 说明 |
|-------|------|:------:|------|
| `unit` | `cargo test --lib` | 122 passed / 23 ignored | 覆盖全部模块的平行安全单元测试 |
| `ignored` | `--ignored --test-threads=1` | 23 passed | 涉及进程级 native 状态的测试 |
| `abi` | `tests/abi_smoke.rs` | 5 passed / 1 ignored | Stage 1 C ABI 层 |
| `e2e` | `tests/framework_e2e.rs` | 2 passed | Stage 2 端到端 |
| `e2e_opts` | `tests/options_e2e.rs` | 6 passed | 新增：类型化选项 |
| `e2e_ident` | `tests/identity_e2e.rs` | 1 passed | 新增：P2P 身份侧数据 |
| `e2e_addr` | `tests/addressing_e2e.rs` | 5 passed | 新增：三套寻址 + P2P 注册 |
| `e2e_async` | `tests/async_e2e.rs` | 10 passed | 新增：异步调用家族 |
| **合计** | | **174** | |

全部层通过 `.\test.ps1` 一次运行。

---

### C ABI 覆盖对照

| 分组 | C ABI 导出数 | Rust 封装数 | 覆盖率 |
|------|:------------:|:-----------:|:------:|
| Data handle | 12 | 12 | 100% |
| Application handle | 5 | 5 | 100% |
| API registration (app-bound) | 3 | 3 | 100% |
| API registration (process-wide P2P) | 3 | 3 | 100% |
| Local execution | 2 | 2 | 100% |
| Network preparation | 5 | 5 | 100% |
| Remote invocation (app-name) | 5 | 5 | 100% |
| Remote invocation (UID) | 5 | 5 | 100% |
| Remote invocation (P2PName) | 5 | 5 | 100% |
| Queries | 7 | 7 | 100% |
| Options | 2 | 2 | 100% |
| Status | 3 | 3 | 100% |
| Network events | 1 | 1 | 100% |
| Shutdown | 1 | 1 | 100% |
| **合计** | **59** | **59** | **100%** |

---

### 迁移指南

**从 v0.2 升级到 v0.3 无需修改任何既有代码。** 本次为纯增量版本。

若希望采用新 API，推荐路径：

1. **把散落的字符串选项调用替换为类型化 API**

   ```rust
   // 之前
   framework::set_option("Quiet", "True")?;
   framework::set_option("Wait_Connection_Timeout", "10000")?;

   // 之后
   options::set_quiet(true)?;
   options::set_wait_connection_timeout(10_000)?;
   ```

2. **用 `Uid` 替代裸字节数组**

   ```rust
   // 之前：手工维护 32 字节
   let mut uid_bytes = [0u8; 32];
   // ... 从某处填充 ...

   // 之后
   let uid = Uid::from_hex("...")?;
   framework::call_by_uid(uid, &req, 3000)?;
   ```

3. **用回调式异步替代手写线程池**

   ```rust
   // 之前：手工 spawn 线程 + 阻塞调用
   std::thread::spawn(move || {
       let resp = framework::call("App", &req, 3000)?;
       // ...
   });

   // 之后
   async_call::call_async("App", &req, move |result| {
       match result {
           Ok(mut resp) => { /* ... */ }
           Err(e)        => eprintln!("{}", e),
       }
   })?;
   ```

4. **用 P2P 注册发布进程级工具 API**

   ```rust
   p2p::register_p2p_call("whoami", "identity echo", |input, output| {
       let uid = input.p2p_uid().unwrap_or_default();
       let _ = io::write_json(output, &serde_json::json!({
           "uid": uid.to_hex(),
       }));
   })?;
   ```

---

### 致谢

本次升级在设计上参考了 LingoFuse 的 C++ 绑定（`LingoFuse.hpp`）、Pascal 完整指南（`LingoFuse_Pascal_Complete_Guide.md` v5.0）与内部机制知识库（`Z.LingoFuse.md` v3.2）。异步模型与 `AsyncResult` 的所有权契约直接沿用 C++ 绑定的设计，只是以 Rust 惯用形式呈现。

---

## [0.2.0] - 2026-10-02

初始版本。C ABI 覆盖 37 / 59，包含：

- `sys` 层（bindings / loader）
- `error` / `data_handle` / `io` / `app_handle`
- `framework`（App 名寻址的同步调用）
- `network_events` / `status`

详细的 API 说明见 `README.md`。
```

---

## 交付确认

- **文件**：`CHANGELOG.md`（新增）
- **位置**：crate 根目录（与 `README.md` / `Cargo.toml` 同级）
- **行数**：约 380 行
- **格式**：Keep a Changelog 风格，`[0.3.0]` 为本次升级，`[0.2.0]` 为历史锚点
- **内容语言**：中文
- **代码 / 文件名 / API 名**：保留英文原样

### 文档覆盖的关键信息

| 章节 | 内容 |
|------|------|
| 摘要 | 覆盖率 37 → 59 的核心数字 |
| 新增 | 4 个新模块、22 个 C ABI 封装、13 个 `framework` 函数、2 个 `data_handle` 方法 |
| 变更 | 6 个源文件的具体改动 |
| 修复 | 1 个产品代码 bug + 3 处交付期编译错误 |
| 已知限制 | 6 条明确的设计决策（含 `Vec<u8>` 返回值、shutdown 不重置选项、null UID 行为） |
| 未变更 | 明确边界（`error` / `io` / `app_handle` / `network_events` / `status` 完全不动） |
| 测试矩阵 | 8 层测试，174 个测试的完整清单 |
| C ABI 覆盖对照 | 14 个分组的 100% 覆盖率证明 |
| 迁移指南 | 4 个 before / after 示例 |

### 定位

- 面向**开发者**（升级到 v0.3 的用户）
- 面向**维护者**（未来回顾设计决策）
- 面向**审计者**（C ABI 覆盖率与测试矩阵的对照）

### 下一步

剩余一项：`README.md` 更新。请确认本批无误后，我交付 `README.md`。