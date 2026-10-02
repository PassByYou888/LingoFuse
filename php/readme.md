# PHP 支持说明

## 状态

PHP FFI 绑定（全部示例与测试）**已从仓库删除**。

## 未来路线

PHP 与 LingoFuse 的交互统一走 **HTTP POST + JSON**：

- PHP 作为 **API 调用者（caller）**，不做服务端
- 通过 `bridge.py`（独立进程）转发请求到 LingoFuse 网格
- PHP 侧只用原生 `json_encode` / `json_decode` 与 HTTP 客户端

### LingoFuse-Tools 将生成 PHP 统一调用接口

[LingoFuse-Tools](https://github.com/PassByYou888/LingoFuse-Tools) 体系未来会
支持从 API 声明自动生成 PHP 侧的统一调用接口，与已有的 Pascal / C++ / C# /
Python / JS / TS 生成目标并列。

生成物只覆盖 **调用者一侧**：每个 API 生成一个 PHP 函数/方法，内部通过
HTTP POST + JSON 调用 bridge。PHP 不参与服务端生成。

### PHP 的定位

LingoFuse 给 PHP 的定位是 **调用者（caller）**，不是服务端：

- PHP 调用网格上其它语言写的 API
- 其它语言不通过 PHP 暴露 API
- 需要服务端能力时，用 Pascal / C++ / C# / Python / JS / TS

## 为什么删除

PHP 的 FFI 扩展无法从外部 OS 线程进入 PHP 回调，因此无法注册 Call / Notify
服务端 API。php-src 已明确此限制且上游核心团队拒绝修复：

- **Issue #9214**（2022-08）：cmb69 —— *"I don't think that FFI callbacks are thread-safe... especially if calls can come from arbitrary threads in the target process."*
- **PR #12823**（2023-11，Draft）：dstogov —— *"Transferring execution of all callbacks to main thread can't be safe... It's better to just disable calls to FFI callbacks in context of non-main thread."*
