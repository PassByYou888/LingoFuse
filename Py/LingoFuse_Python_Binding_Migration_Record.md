# LingoFuse Python Binding Changelog

**版本：** v2.1  
**更新日期：** 2026-08-31  

---

## 版本概览

本文档记录 LingoFuse Python 绑定从 `zAPI`（`api_hub`）迁移以来的所有重要变更、新增功能、缺陷修复和已知问题。采用滚动式更新日志风格，便于追踪演进历程。

---

## v2.1 (2026-08-31)

### 🚀 新增特性

- **HTTP 网关 `bridge.py` 改为纯二进制转发模式**  
  不再解析请求体 JSON，只从 URL 路径提取 `app` 和 `api`（格式 `/<app>/<api>` 或 `/<api>` 使用默认应用）。请求体原样转发给后端 LingoFuse 服务，响应原样返回给客户端，极大提升了通用性和性能。

- **新增 `check_api` 预检机制**  
  在转发请求前调用 `LF_CheckApi` 验证目标 API 是否存在，若不可用则提前返回错误码 `-3`，避免无效的网络调用。

- **容错字符串读取**  
  `DataHandle.read_string_null_terminated()` 现在支持无 `\0` 结尾的数据：若扫描到缓冲区末尾仍未见 `\0`，则将整个剩余内容作为字符串返回，并移动位置到末尾。这保证了对纯 JSON 等不带终止符的数据的兼容性。

- **统一写入规范**  
  所有 `write_string_null_terminated()` 调用均保证在末尾追加 `\0`，确保与 Pascal 端 `LF_ReadString` 的约定一致。同时 `bridge.py` 在返回 HTTP 响应前自动剥离尾部的 `\0`，避免 HTTP 客户端解析 JSON 时出错。

- **新增调试日志**  
  `bridge.py` 增加 `--debug` 开关，打印请求/响应的尺寸、内容摘要（含十六进制），便于排查问题。

### 🐛 缺陷修复

- **响应数据读取错误**  
  旧版 `bridge.py` 使用 `LF_GetBuffer` 返回的指针直接切片，因 `ctypes.c_void_p` 不支持切片而报错 `'int' object is not subscriptable`。现改用 `LF_ReadBuffer` 配合 `ctypes` 数组可靠读取。

- **Pascal 服务端收到空请求体**  
  原 `bridge.py` 未追加 `\0`，导致 `LF_ReadString` 返回空字符串。现请求体后追加 `\0`，确保 Pascal 端正确识别 JSON 字符串。

- **浏览器 JSON 解析失败（多余 `\0`）**  
  后端返回的 JSON 字符串带 `\0` 时，浏览器解析报错 `Unexpected non-whitespace character after JSON`。现 `bridge.py` 在返回前自动去除末尾的 `\0`。

- **`cross_bridge.py` 返回格式不统一**  
  `add` 返回纯数字，`inv_seri` 返回字符串，导致客户端 `data.result` 为 `undefined`。现统一返回 `{"code":0, "result": ...}`，错误时返回 `{"code":-1, "error": "..."}`。

- **多语言客户端路径错误**  
  更新 Node.js、PHP、浏览器客户端，改用完整路径 `/cross_bridge/add` 和 `/cross_bridge/inv_seri`，并发送纯参数体（如 `[10,20]` 或 `{}`），不再使用旧式 `{"api":"add","args":[...]}` 包装。

### 📖 文档更新

- 新增 `Bridge_User_Guide.md`（英文）详细说明 `bridge.py` 的用法、参数、调试和示例。
- 更新 `Cross_Demo_Guide_zh.md`，移除已废弃的 `--mode` 和 `--routes` 参数，改为纯路径模式。
- 修改 `Pascal_Service_Guide_for_bridge.md`，面向 Pascal 开发者说明如何配合新桥接器。
- 在 `lingofuse_import.pas` 头部添加“JSON 交换常见陷阱”章节，涵盖 null 终止符、读写策略、错误处理等，供其他语言开发者参考。

### ⚠️ 已知问题

- 无。

---

## v2.0 (2026-08-31) – 初始迁移版本

### 初始功能

- 完成从旧版 `zAPI` 到 LingoFuse 的全面迁移，提供完整的 Python 绑定（`DataHandle`, `App`, `Server`, `C4`）。
- 支持本地/远程调用、通知、顺序通知。
- 提供 HTTP 网关 `bridge.py`（当时支持 `json` 和 `path` 双模式）。
- 包含 Cross 示例（信标、工作节点、适配器、多语言客户端）。

### 已知问题（v2.0）

- `bridge.py` 依赖 JSON 解析，限制了通用性。
- 字符串读取无容错，若缺少 `\0` 则返回空。
- 响应可能残留 `\0`，导致 HTTP 客户端解析失败。
- 缺少 API 预检，无效请求仍会尝试网络调用。

---

## 未来计划

- 集成 OpenTelemetry 链路追踪。
- 支持 gRPC 协议。
- 提供更丰富的序列化插件（如 MessagePack）。

---

## 版本历史

- **v2.1** – 2026-08-31：纯二进制转发、容错读取、统一 `\0` 处理、文档大更新。
- **v2.0** – 2026-08-31：初始迁移版本。