# LingoFuse Python 流式 LLM 服务开发要点（AI 速查）

> 本文档专为 AI 模型设计，旨在 5 分钟内掌握 LingoFuse 实现流式 LLM 服务的关键技术细节、常见陷阱与正确实践。  
> 代码参考：`llm_service.py`（服务端）、`llm_test.py`（客户端）。

---

## 1. 核心角色与概念

- **服务端**：注册 `generate` 和 `set_system_message` 两个 **Call API**。  
  - `generate`：接收 `{content, prompt, client_name}`，立即返回 `{session_id}`，并启动后台线程流式生成。  
  - 后台线程通过 **Sequenced Notify** 将 token 块推送给 `client_name` 指定的客户端应用。
- **客户端**：动态生成唯一应用名（`generate_app_name`），注册 Notify 回调，接收流式输出。
- **Sequenced Notify**：保证同一 `(app, api)` 对的消息 **FIFO 有序**，是实现流式推送的关键。

---

## 2. 关键 API 映射（Python 绑定）

| 功能 | 应使用的模块/函数 | 错误做法（避免） |
|------|-------------------|------------------|
| 创建应用、注册 Notify | `lingofuse.App` + `register_notify` | 从 `_lf_native` 导入不存在的高层函数 |
| 数据读写 | `DataHandle.read_json()` / `write_json()` | 直接操作 `LF_ReadString`（Python 中无此函数） |
| 发送通知 | `_lf_native.LF_Sequenced_Notify` | 目标必须是客户端应用名，而非服务端名 |
| 网络准备 | `LF_ResetPrepare`, `LF_PrepareClient`, `LF_PrepareDone` | 混用 `C4` 类会导致重复连接错误 |
| 进程退出 | `LF_ExitMainThread()` + `LF_Shutdown()` | 缺少任一都会导致进程挂起 |

---

## 3. 服务端实现模板

```python
from lingofuse import Server
from lingofuse._lf_native import LF_Sequenced_Notify

class LLMService:
    def __init__(self, config):
        self.server = Server(config.app_name)
        self._register_apis()

    def _register_apis(self):
        @self.server.expose("generate")
        def generate(data: dict) -> dict:
            client_name = data["client_name"]
            session_id = str(uuid.uuid4())
            # 启动后台线程
            threading.Thread(target=self._stream, args=(session_id, client_name, ...)).start()
            return {"session_id": session_id}

    def _send_chunk(self, session_id, client_name, text):
        hnd = DataHandle(self.config.notify_api)
        hnd.write_json({"session_id": session_id, "chunk": text})
        LF_Sequenced_Notify(client_name.encode("utf-8"), hnd.raw)  # 目标=client_name
        hnd.free()

    def cleanup(self):
        self.server.stop()  # 调用 LF_ExitMainThread + LF_Shutdown（通过 stop(full_cleanup=True)）
```

---

## 4. 客户端实现模板

```python
from lingofuse import App, generate_app_name
from lingofuse._lf_native import *

# 1. 准备网络（不绑定 App）
LF_ResetPrepare()
LF_PrepareClient(b"ipc:llm_service", None)   # 只连接，不暴露 App
if LF_PrepareDone() != 1: 处理错误

# 2. 生成唯一名称（必须在 PrepareDone 之后）
client_name = generate_app_name()

# 3. 创建 App 并注册 Notify
app = App(client_name)
app.register_notify("llm_stream", on_stream_callback)

# 4. 绑定 App 到现有客户端（或直接用 PrepareClient 绑定）
bound = LF_BindApp(app.raw)   # 若返回 0，可改用 Overlap_Connection=True + PrepareClient

# 5. 发起生成请求
hnd = DataHandle("generate")
hnd.write_json({"content": "...", "prompt": "...", "client_name": client_name})
res_hnd = LF_Call(b"LLM_Service", hnd.raw, timeout_ms)
response = DataHandle._from_raw(res_hnd).read_json()
session_id = response["session_id"]

# 6. 等待 Notify 回调中的 "__FINISH__"
finish_event.wait()

# 7. 清理
app.free()
LF_ExitMainThread()
LF_Shutdown()
```

---

## 5. 必踩的坑（已填平）

| 坑 | 现象 | 正确做法 |
|----|------|----------|
| `generate_app_name` 在 `PrepareDone` 前调用 | 生成的名称缺少 C4 隧道信息，路由失败 | **必须在 `PrepareDone` 成功后调用** |
| Notify 目标误写为服务端名 | 日志：`no found app("LLM_Service") api("llm_stream")` | Notify 目标必须是**客户端应用名** |
| 混用 `C4` 与手动 `PrepareClient` | `ConnectionError: repeat connection` | 二选一，不要混用 |
| 进程退出卡住 | 未调用 `LF_ExitMainThread` 和 `LF_Shutdown` | `finally` 块中确保调用两者 |
| 服务端 `cleanup` 未释放资源 | 应用池、线程未释放 | 调用 `self.server.stop(full_cleanup=True)` |
| 缩进错误导致方法未定义 | `AttributeError: 'LLMService' object has no attribute 'cleanup'` | 确保类内方法缩进正确（4 空格） |

---

## 6. 调试与日志控制

- **服务端**：支持 `--quiet`（抑制 chunk 日志）、`--debug`（详细日志）、`--log-level 0/1/2`。
- **客户端**：`--debug` 打印配置和调用详情。
- **可观测性**：使用 `check_app(client_name)` 在发送前探测目标是否在线（缓存延迟约 3 秒）。

---

## 7. 顺序保证与流式传输

- `Sequenced_Notify` 保证同一 `(client_app, notify_api)` 的消息顺序，使 token 按生成顺序到达。
- 服务端发送 `"__FINISH__"` 作为结束标记，客户端据此停止等待。
- 大模型流式生成采用 `llama_cpp.create_chat_completion(stream=True)`，每个 chunk 含有 `delta.content`。

---

## 8. 环境与依赖

- 确保 `llama-cpp-python`（或 `transformers + torch`）已安装。
- LingoFuse 动态库（`LingoFuse64.dll` 等）在 `PATH` 中。
- 运行命令示例：
  ```bash
  # 服务端
  python llm_service.py --model-path ./qwen.gguf --endpoint ipc:llm_service --quiet
  # 客户端
  python llm_test.py --content "print('Hello')" --prompt "Explain in Chinese"
  ```

---

## 9. 总结

- 服务端负责 **生成 + 推送**，客户端负责 **接收 + 展示**。
- 严格遵循 API 分层：高层封装（`Server`, `App`）与底层原生函数（`LF_*`）不要混用。
- 资源清理顺序：先 `app.free()`，再 `LF_ExitMainThread()`，最后 `LF_Shutdown()`。
- 名称生成、通知目标、连接准备三大易错点，务必按模板顺序执行。

此文档可作为 AI 理解 LingoFuse 流式 LLM 场景的快速参考，覆盖 90% 的常见问题。