# llm_service_*.exe 命令行使用说明

**适用版本**：LingoFuse LLM Service（Python 版 PyInstaller 打包）  
**适用文件**：`llm_service_cpu.exe` / `llm_service_cu124.exe` / `llm_service_vulkan.exe` 等  
**文档定位**：覆盖模型放置、启动参数、环境变量、典型场景、故障排查与运行时行为的完整命令行手册。

---

## 目录

1. [概述](#1-概述)
2. [运行前提](#2-运行前提)
3. [默认行为](#3-默认行为)
4. [命令行参数详解](#4-命令行参数详解)
5. [环境变量](#5-环境变量)
6. [不同后端版本的区别](#6-不同后端版本的区别)
7. [典型使用场景](#7-典型使用场景)
8. [运行时行为说明](#8-运行时行为说明)
9. [如何被调用（客户端视角）](#9-如何被调用客户端视角)
10. [故障排查](#10-故障排查)
11. [参数速查表](#11-参数速查表)

---

## 1. 概述

`llm_service_*.exe` 是一个 **基于 LingoFuse 服务网格的多会话流式 LLM 服务端**。它：

- 加载本地 GGUF 模型（默认 `qwen2.5-7b-instruct-q4_k_m.gguf`）
- 在 LingoFuse 服务网格上注册为 `LLM_Service` 应用
- 暴露两个 **Call API**：
  - `generate`：接收 `{content, prompt, client_name}`，立即返回 `{session_id}`，启动后台线程流式生成
  - `set_system_message`：运行时修改系统提示词
- 通过 **Sequenced Notify**（默认 API 名 `llm_stream`）向指定客户端推送 token 流
- 每个请求独立会话、独立线程，支持多客户端并发

**运行环境**：Windows / Linux / macOS（不同后缀的 exe 对应不同硬件后端）。  
**依赖**：`LingoFuse64.dll` / `liblingofuse.so`（位于系统 PATH 或 exe 同目录）。

---

## 2. 运行前提

### 2.1 模型文件必须就位

**默认情况下，exe 启动时会自动扫描当前工作目录下的模型文件：**

```
qwen2.5-7b-instruct-q4_k_m.gguf
```

**要求**：

- 文件名**大小写严格匹配**，不要重命名。
- 文件必须**与 exe 位于同一目录**（或通过 `--model-path` 显式指定路径）。
- 文件完整，约 **4.7 GB**。
- 若未找到该文件，服务将报错退出：

```
[ERROR] Model file not found: ./qwen2.5-7b-instruct-q4_k_m.gguf
```

模型下载方式详见 `Qwen2.5-7B-Instruct-Q4_K_M.md`。

### 2.2 动态库必须可加载

exe 启动第一件事就是加载 LingoFuse 动态库。成功时会打印：

```
[INFO] Successfully loaded from system PATH: LingoFuse64.dll
```

若看到 `Failed to load`，请检查：

- `LingoFuse64.dll` / `liblingofuse.so` 是否在系统 `PATH` 中，或在 exe 同目录。
- 动态库位数是否与 exe 一致（64 位 vs 32 位）。
- 依赖的 `z_ipc_64.dll` 等是否也能被找到。

### 2.3 工作目录建议

建议在**放模型和 exe 的目录**里打开命令行，这样默认路径就能生效：

```powershell
cd C:\Temp\temp2
.\llm_service_cpu.exe
```

---

## 3. 默认行为

**不带任何参数直接运行**，服务按以下默认值启动：

| 配置项 | 默认值 |
|---|---|
| 模型路径 | `./qwen2.5-7b-instruct-q4_k_m.gguf` |
| 上下文大小 | `32768` tokens |
| 最大生成 token | `4096` |
| CPU 线程数 | `6` |
| GPU 层数 | `-1`（全部卸载到 GPU；若 GPU 不可用则回退 CPU） |
| 系统提示词 | `Before answering, briefly list your reasoning steps using numbered bullets. Then give the final answer. Do not use Markdown.` |
| LingoFuse 端点 | `ipc:llm_service` |
| 服务应用名 | `LLM_Service` |
| 流式通知 API | `llm_stream` |
| 调用超时 | `5000` ms |
| 会话闲置超时 | `60` 秒（信息性） |
| 日志级别 | `0`（quiet） |

启动后会打印一段**服务状态横幅**，然后进入监听状态，直到 `Ctrl+C` 退出：

```
======================================================================
 LINGOFUSE LLM SERVICE STATUS
======================================================================
  Backend               : llama_cpp
  Model path            : ./qwen2.5-7b-instruct-q4_k_m.gguf
  Context size          : 32768
  ...
[OK] Server 'LLM_Service' started on ipc:llm_service
[Service] LLM Service is running on ipc:llm_service
[Service] Press Ctrl+C to stop...
```

---

## 4. 命令行参数详解

所有参数都可以被**同名环境变量覆盖**（见第 5 节）。

### 4.1 模型与推理参数

#### `--model-path PATH`

- **作用**：指定 GGUF 模型文件路径。
- **默认**：`./qwen2.5-7b-instruct-q4_k_m.gguf`
- **环境变量**：`LLM_MODEL_PATH`
- **示例**：
  ```powershell
  .\llm_service_cpu.exe --model-path D:\models\qwen2.5-7b.gguf
  ```
- **说明**：路径可以是相对路径（相对当前工作目录）或绝对路径。

#### `--context-size N`

- **作用**：上下文窗口大小（token 数）。
- **默认**：`32768`
- **环境变量**：`LLM_CONTEXT_SIZE`
- **示例**：`--context-size 8192`
- **注意**：调大能处理更长输入，但占用更多内存/显存。启动时会打印 `Maximum context size: N tokens`。

#### `--max-tokens N`

- **作用**：单次生成的最大 token 数。
- **默认**：`4096`
- **环境变量**：`LLM_MAX_TOKENS`
- **示例**：`--max-tokens 2048`

#### `--threads N`

- **作用**：CPU 推理线程数（仅 llama.cpp 后端有效）。
- **默认**：`6`
- **环境变量**：`LLM_THREADS`
- **示例**：`--threads 8`
- **建议**：设为**物理核心数的一半**（避免风扇狂转/温度过高）。

#### `--gpu-layers N`

- **作用**：卸载到 GPU 的模型层数。
- **默认**：`-1`（全部卸载到 GPU；若 GPU 不可用则自动回退 CPU）
- **环境变量**：`LLM_GPU_LAYERS`
- **取值**：
  - `-1` = 全部层卸载到 GPU（有独显时性能最佳）
  - `0` = 纯 CPU 模式（无 GPU 或显存不足时使用）
  - `N > 0` = 卸载前 N 层到 GPU（显存不足时逐步下调）
- **示例**：`--gpu-layers 0`（强制 CPU）

#### `--system-message "MESSAGE"`

- **作用**：设定全局系统提示词（所有会话共用，可在运行时通过 `set_system_message` API 修改）。
- **默认**：见第 3 节。
- **环境变量**：`LLM_SYSTEM_MESSAGE`
- **示例**：
  ```powershell
  .\llm_service_cpu.exe --system-message "You are a helpful assistant."
  ```
- **注意**：含空格时需用引号包裹。

### 4.2 LingoFuse 服务参数

#### `--endpoint ADDRESS`

- **作用**：LingoFuse 服务端点（IPC 或 TCP）。
- **默认**：`ipc:llm_service`
- **环境变量**：`LINGOFUSE_ENDPOINT`
- **示例**：
  - `--endpoint ipc:my_llm`（同机 IPC）
  - `--endpoint 0.0.0.0:9898`（跨机 TCP）
- **说明**：IPC 适合同机进程调用（延迟 < 1ms）；TCP 适合跨机调用。

#### `--app-name NAME`

- **作用**：LingoFuse 服务应用名（客户端通过该名字查找服务）。
- **默认**：`LLM_Service`
- **环境变量**：`LINGOFUSE_APP_NAME`
- **示例**：`--app-name MyLLM`

#### `--notify-api NAME`

- **作用**：流式 token 推送使用的 Notify API 名。
- **默认**：`llm_stream`
- **环境变量**：`LINGOFUSE_NOTIFY_API`
- **注意**：客户端必须用**同一个名字**注册 Notify 回调才能收到流。

#### `--timeout MS`

- **作用**：Call API 的超时（毫秒），**不影响流式推送**。
- **默认**：`5000`
- **环境变量**：`LINGOFUSE_TIMEOUT_MS`
- **示例**：`--timeout 10000`

#### `--session-timeout SECONDS`

- **作用**：会话闲置超时（秒），当前为**信息性参数**（未来可能用于自动终止卡死的生成线程）。
- **默认**：`60`
- **环境变量**：`LLM_SESSION_TIMEOUT`

### 4.3 日志与调试参数

#### `--log-level {0,1,2}`

- **作用**：日志详细程度。
  - `0` = quiet：抑制 chunk 日志和警告（**默认**）
  - `1` = normal：显示每个 chunk 的推送日志，抑制警告
  - `2` = debug：显示所有日志，包括"目标客户端不可达"等警告
- **默认**：`0`
- **环境变量**：`LLM_LOG_LEVEL`
- **示例**：`--log-level 1`

#### `--debug`

- **作用**：等价于 `--log-level 2`，打印完整调试信息。
- **环境变量**：`LLM_DEBUG`（`1` / `true` / `yes`）
- **示例**：`.\llm_service_cpu.exe --debug`

#### `--quiet`

- **作用**：等价于 `--log-level 0`，抑制 chunk 日志和警告。
- **环境变量**：`LLM_QUIET`（`1` / `true` / `yes`）
- **示例**：`.\llm_service_cpu.exe --quiet`

> **优先级**：`--debug` > `--quiet` > `--log-level`。

---

## 5. 环境变量

所有命令行参数都可以通过**同名环境变量**设置。适合在启动脚本或系统服务中统一配置。

| 环境变量 | 对应参数 | 示例 |
|---|---|---|
| `LLM_MODEL_PATH` | `--model-path` | `D:\models\qwen.gguf` |
| `LLM_CONTEXT_SIZE` | `--context-size` | `8192` |
| `LLM_MAX_TOKENS` | `--max-tokens` | `2048` |
| `LLM_THREADS` | `--threads` | `8` |
| `LLM_GPU_LAYERS` | `--gpu-layers` | `0` |
| `LLM_SYSTEM_MESSAGE` | `--system-message` | `You are...` |
| `LINGOFUSE_ENDPOINT` | `--endpoint` | `ipc:my_llm` |
| `LINGOFUSE_APP_NAME` | `--app-name` | `MyLLM` |
| `LINGOFUSE_NOTIFY_API` | `--notify-api` | `llm_stream` |
| `LINGOFUSE_TIMEOUT_MS` | `--timeout` | `10000` |
| `LLM_SESSION_TIMEOUT` | `--session-timeout` | `120` |
| `LLM_LOG_LEVEL` | `--log-level` | `1` |
| `LLM_DEBUG` | `--debug` | `1` / `true` / `yes` |
| `LLM_QUIET` | `--quiet` | `1` / `true` / `yes` |

**PowerShell 示例**：

```powershell
$env:LLM_GPU_LAYERS = "0"
$env:LLM_THREADS = "8"
.\llm_service_cpu.exe
```

**CMD 示例**：

```cmd
set LLM_GPU_LAYERS=0
set LLM_THREADS=8
llm_service_cpu.exe
```

**优先级**：命令行参数 > 环境变量 > 内置默认值。

---

## 6. 不同后端版本的区别

同一个 `llm_service.py` 可以编译成多个不同后端的 exe，参数完全一致，**区别只在底层推理引擎**：

| 文件名 | 后端 | 适用场景 | 显存要求 |
|---|---|---|---|
| `llm_service_cpu.exe` | CPU（llama.cpp） | 无独显、笔记本、云主机 | 仅需内存 |
| `llm_service_cu124.exe` | CUDA 12.4 | NVIDIA 显卡 | ≥ 8GB 显存跑 7B Q4_K_M |
| `llm_service_vulkan.exe` | Vulkan | AMD/Intel/NVIDIA 跨平台 GPU | ≥ 8GB 显存 |
| `llm_service_metal.exe` | Metal | Apple Silicon | 统一内存 |
| `llm_service_openblas.exe` | OpenBLAS | CPU BLAS 加速 | 仅需内存 |

**启动时的行为**：

- exe 内部已经内置了对应后端的 llama.cpp 编译产物，无需额外安装。
- 默认 `--gpu-layers -1`：如果 exe 是 CPU 版，会忽略 GPU 参数走 CPU；如果是 GPU 版，会尝试全部卸载。
- 建议：**明确指定** `--gpu-layers`，避免后端不匹配时的行为不确定。

---

## 7. 典型使用场景

### 7.1 CPU 纯离线启动（无独显）

```powershell
.\llm_service_cpu.exe --gpu-layers 0 --threads 8 --quiet
```

- 6~14 tokens/s（取决于 CPU）。
- 适合 7×24 小时运行，风扇噪声可控。

### 7.2 NVIDIA 显卡加速（默认全卸载）

```powershell
.\llm_service_cu124.exe --gpu-layers -1 --threads 4
```

- 20~40 tokens/s（取决于显卡）。
- `--threads 4`：GPU 推理时 CPU 线程数影响不大。

### 7.3 显存不足时的渐进式调整

```powershell
# 先试 20 层
.\llm_service_cu124.exe --gpu-layers 20
# 若仍 OOM，降到 10 层
.\llm_service_cu124.exe --gpu-layers 10
# 最后回退纯 CPU
.\llm_service_cu124.exe --gpu-layers 0
```

### 7.4 自定义端点和应用名（多服务共存）

```powershell
.\llm_service_cpu.exe --endpoint ipc:llm_service_A --app-name LLM_Service_A
```

- 便于在同机上跑多个 LLM 服务实例（加载不同模型）。
- 客户端需要对应调整 `--server-app` 和 `--endpoint`。

### 7.5 跨机部署（TCP 模式）

**服务端（GPU 工作站）**：

```powershell
.\llm_service_cu124.exe --endpoint 0.0.0.0:9898 --app-name LLM_Service
```

**客户端（弱鸡笔记本）**：

```python
from lingofuse import C4
c = C4("LLM_Service", "192.168.1.100:9898")
```

### 7.6 日志调试（开发排查）

```powershell
.\llm_service_cpu.exe --debug
```

- 打印每个 chunk 的 JSON、客户端可达性警告。
- 仅用于排查，生产环境请用 `--quiet`。

### 7.7 自定义系统提示词

```powershell
.\llm_service_cpu.exe --system-message "你是一个代码声明转换助手，只转换声明部分，禁止 markdown 输出。"
```

### 7.8 搭配 MCP 智能体使用

配合 `pascal_decl_to_mcp.exe` 生成的工具提供者，把 LLM 能力注册为 MCP 工具：

1. 启动 `llm_service_cpu.exe`（默认端点 `ipc:llm_service`）
2. 启动 `pascal_agent_service.exe`（信标）
3. 启动 `mcp_server.exe`
4. MCP 客户端（LM Studio / Claude Desktop / 豆包）即可调用 `generate` 工具

---

## 8. 运行时行为说明

### 8.1 启动阶段

1. **加载 LingoFuse 动态库**：打印 `[INFO] Successfully loaded from system PATH: ...`
2. **检测 LLM 后端**：`llama_cpp` 或 `transformers`
3. **加载模型**：打印模型元数据（架构、量化等级、上下文长度等），一般 5~15 秒
4. **注册 Call API**：`generate`、`set_system_message`
5. **启动 LingoFuse 服务**：创建 IPC/TCP 端点、主线程、服务网格注册
6. **进入监听状态**：等待客户端调用

### 8.2 请求处理流程

1. 客户端调用 `generate`，传入 `{content, prompt, client_name}`
2. 服务端**立即返回** `{code: 0, session_id: "..."}`
3. 服务端**启动独立线程**执行流式生成
4. 每个 token 通过 `Sequenced_Notify` 推送到 `client_name` 应用的 `llm_stream` API
5. 生成结束时发送 `{"chunk": "__FINISH__"}`
6. 出错时发送 `{"chunk": "__ERROR__: ..."}`

### 8.3 多会话并发

- 每个 `generate` 请求独立 `session_id`、独立线程。
- 多客户端并发**互不干扰**。
- 每个会话的状态（`client_name`、`start_time`、`status`）由 `active_sessions` 字典跟踪。

### 8.4 退出

- 按 `Ctrl+C`：优雅退出，打印 `[Service] Shutting down...`，清理资源。
- 通过 `atexit` 确保 `cleanup()` 被调用。
- **不建议**直接关窗口或 `kill -9`，可能残留 IPC 队列。

---

## 9. 如何被调用（客户端视角）

服务启动后，客户端可以通过 LingoFuse 调用它。**Python 客户端最小示例**：

```python
from lingofuse import App, generate_app_name
from lingofuse._lf_native import (
    LF_ResetPrepare, LF_PrepareClient, LF_PrepareDone,
    LF_Call, LF_BindApp, LF_ExitMainThread, LF_Shutdown
)
from lingofuse.core import DataHandle
import threading

LF_ResetPrepare()
LF_PrepareClient(b"ipc:llm_service", None)
LF_PrepareDone()

client_name = generate_app_name()
app = App(client_name)
finish_event = threading.Event()

def on_stream(trigger, inp):
    data = inp.read_json()
    if data and data.get("chunk") == "__FINISH__":
        finish_event.set()
    else:
        print(data.get("chunk", ""), end="")

app.register_notify("llm_stream", on_stream)
LF_BindApp(app.raw)

# 发起生成
hnd = DataHandle("generate")
hnd.write_json({"content": "print('Hello')", "prompt": "用中文解释", "client_name": client_name})
resp = LF_Call(b"LLM_Service", hnd.raw, 10000)
print(f"session_id: {DataHandle._from_raw(resp).read_json()['session_id']}")

finish_event.wait()
app.free()
LF_ExitMainThread()
LF_Shutdown()
```

**Pascal 客户端**参考 `tools/llm_client.pas`。

---

## 10. 故障排查

### Q1：启动报 `Model file not found`

- 检查 `qwen2.5-7b-instruct-q4_k_m.gguf` 是否与 exe 同目录。
- 或者用 `--model-path` 指定绝对路径。
- 确认文件名没有多余后缀（如 `.gguf.part`）。

### Q2：启动报 `Failed to load LingoFuse64.dll`

- 将 `LingoFuse64.dll` 放到 exe 同目录，或加入系统 `PATH`。
- 确认动态库位数与 exe 一致。

### Q3：显存不足（`CUDA out of memory`）

- 降低 `--gpu-layers`（如 `20` → `10` → `0`）。
- 降低 `--context-size`。
- 换更小的量化模型。

### Q4：CPU 太慢 / 风扇狂转

- 减少 `--threads`（如从 8 降到 4）。
- 检查 CPU 是否支持 AVX2/AVX512。

### Q5：客户端收不到流

- 检查客户端是否用 `llm_stream` 注册了 Notify 回调。
- 检查 `client_name` 是否**在 `PrepareDone` 之后**生成（`generate_app_name`）。
- 检查服务端 `--notify-api` 是否被改过。

### Q6：`Context length exceeded`

- 输入过长。降低 `--max-tokens` 或缩短 prompt。
- 或者调大 `--context-size`（但要注意内存占用）。

### Q7：端口 / IPC 队列被占用

- 报错类似 `Queue "llm_service0" is already occupied`。
- 说明同机已有服务在监听 `ipc:llm_service`。
- 换个 `--endpoint ipc:llm_service_2` 即可。

### Q8：进程退不干净

- 优先用 `Ctrl+C` 优雅退出。
- 若残留 IPC 队列，可重启系统或在任务管理器中结束所有 LingoFuse 相关进程。

---

## 11. 参数速查表

```
llm_service_*.exe [OPTIONS]

模型与推理
  --model-path PATH           GGUF 模型路径 (默认: ./qwen2.5-7b-instruct-q4_k_m.gguf)
  --context-size N            上下文窗口 token 数 (默认: 32768)
  --max-tokens N              单次最大生成 token 数 (默认: 4096)
  --threads N                 CPU 线程数 (默认: 6)
  --gpu-layers N              GPU 层数, -1=全部, 0=纯CPU (默认: -1)
  --system-message "MSG"      系统提示词

LingoFuse 服务
  --endpoint ADDR             服务端点 (默认: ipc:llm_service)
  --app-name NAME             应用名 (默认: LLM_Service)
  --notify-api NAME           流式通知 API 名 (默认: llm_stream)
  --timeout MS                Call 超时 ms (默认: 5000)
  --session-timeout SEC       会话闲置超时秒 (默认: 60)

日志与调试
  --log-level {0,1,2}         日志级别 (默认: 0)
  --debug                     等价 --log-level 2
  --quiet                     等价 --log-level 0

环境变量与参数一一对应 (前缀 LLM_* 和 LINGOFUSE_*)
```

---

**文档版本**：V1.0  
**维护者**：LingoFuse-pasAgent 团队  
**反馈**：问题提 Issue，急事加 Q（600585）