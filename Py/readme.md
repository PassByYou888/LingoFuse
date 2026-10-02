# LingoFuse Python 绑定

> **跨语言通讯地基的 Python 官方绑定、完整测试、HTTP 网关、JSON 修复与网络事件支持。**
>
> 本目录是 Python 开发者使用 LingoFuse 的唯一起点。读完本 README 即可知道：
> - Python 绑定到底覆盖了什么；
> - 每个模块是干什么的；
> - 测试覆盖了哪些场景；
> - 常见坑在哪里。

---

## 1. 结论先说：Python 支持完善程度

LingoFuse 的 Python 绑定已经形成完整闭环，**不是“能跑示例”的水平，而是生产可用级绑定**。

| 维度 | 状态 | 说明 |
|------|:----:|------|
| C ABI 底层绑定 | ✅ 完整 | `_lf_native.py` 导入全部核心导出函数，含完整注释 |
| RAII 封装 | ✅ 完整 | `DataHandle` / `App`，支持自动回收和永久句柄 |
| 服务端封装 | ✅ 完整 | `Server` + `@expose` 装饰器，一键暴露 Python 函数 |
| 客户端封装 | ✅ 完整 | `C4` 动态属性调用，`client.add(10, 20)` 即远程调用 |
| 本地 Call / Notify | ✅ 完整 | `App.local_call` / `App.local_notify` |
| 远程 Call / Notify | ✅ 完整 | `LF_Call` / `LF_Notify` / `LF_Sequenced_Notify` |
| 多线程并发 | ✅ 已测试 | `test_lingofuse.py` 含 10 线程 × 100 次并发测试 |
| 数据句柄两种类型 | ✅ 完整 | 自动回收（`DataHandle`）和永久句柄（`create_permanent`） |
| 网络事件 | ✅ 完整 | `set_network_event` / `NetworkEventListener` / `NetworkEventQueue` |
| JSON 统一 I/O | ✅ 完整 | `lf_io.py` 是工具链唯一 JSON 序列化/反序列化入口 |
| JSON 修复预处理 | ✅ 完整 | `json_repair_preprocess.py` 三路策略，可禁用 |
| HTTP Bridge | ✅ 完整 | `bridge.py` 三方向网关：入站、出站、JSON 修复 |
| Bridge  forward-only 模式 | ✅ 完整 | 可禁用 HTTP 监听器，仅提供 Call API |
| 测试覆盖 | ✅ 完整 | `test_lingofuse.py` 覆盖核心功能、网络、JSON 修复、网络事件 |
| Bridge 测试 | ✅ 有 | `test_bridge.py` 发送 HTTP 请求验证 Bridge 存活 |
| 文档 | ✅ 完整 | `Bridge_User_Guide.md` 详细描述 Bridge 所有契约 |
| CI | ⚠️ 仅 C++ 有 GitHub CI | Python 测试以本地运行为准 |

**总体判断：Python 绑定覆盖了从底层 ABI 到高级服务端/客户端、HTTP 网关、JSON 修复、网络事件的完整链路，并附带可运行的单元测试。**

---

## 2. 目录结构

```text
Py/
├── lingofuse/                    # 核心包
│   ├── __init__.py               # 包入口，导出公开 API
│   ├── _lf_native.py             # ctypes 底层绑定（不直接使用）
│   ├── core.py                   # DataHandle + App
│   ├── server.py                 # Server + @expose
│   ├── client.py                 # C4 动态客户端
│   ├── bridge.py                 # HTTP Bridge（独立运行）
│   ├── lf_io.py                  # 统一 JSON/字符串 I/O
│   ├── serializers.py            # 默认 JSON 序列化器
│   ├── network_events.py         # 网络事件 API
│   ├── json_repair_preprocess.py # JSON 修复预处理
│   ├── json_repair/              # vendored JSON 修复引擎
│   ├── errors.py                 # 异常层次
│   ├── test_lingofuse.py         # 核心单元测试
│   ├── test_bridge.py            # Bridge 冒烟测试
│   ├── Bridge_User_Guide.md      # Bridge 知识库
│   └── clear_.bat                # 清理 __pycache__
├── cross/                        # 跨语言负载均衡演示
├── llm-service/                  # LLM 流式服务示例
├── setup.py                      # pip install 入口
├── requirements.txt              # 依赖
└── readme.md                     # 本文件
```

---

## 3. 核心模块详解

### 3.1 `_lf_native.py` — 底层 C ABI 绑定

**职责：**

- 加载平台动态库（`LingoFuse64.dll` / `liblingofuse.so` / `liblingofuse.dylib`）。
- 定义 `DataHnd`、`AppHnd`、回调类型。
- 绑定全部 `LF_*` 函数。
- 处理 Windows DLL 搜索路径。

**关键点：**

- 所有函数线程安全。
- 回调在后台 C 工作线程执行，禁止阻塞和调用 `LF_Call`。
- 数据句柄两种类型：`LF_CreateData`（自动回收）和 `LF_CreateData_Permanent`（永久）。
- `LF_PrepareDone` 每进程只成功一次。

### 3.2 `core.py` — DataHandle 与 App

#### `DataHandle`

RAII 封装，支持上下文管理器。

- 自动回收句柄：`DataHandle(api_name)`，10 分钟空闲后自动回收。
- 永久句柄：`DataHandle.create_permanent(api_name)`，不自动回收，手动释放。
- 读写方法：
  - 原子类型：`write_int32` / `read_int32` 等（小端）。
  - 字符串：`write_string`（追加 NUL）、`read_string`（容错，无 NUL 读到末尾）。
  - JSON：`write_json` / `read_json`（委托 `lf_io`）。
  - 原始字节：`read_bytes`。
- 位置/大小：`get_pos` / `set_pos` / `get_size` / `set_size`。

#### `App`

应用容器，注册 Call/Notify API。

- `register_call` / `register_notify`：注册回调，异常被隔离并记录日志。
- `local_call` / `local_notify`：本地执行。
- `bind()`：绑定到空闲客户端。
- `sequenced_notify()`：发送顺序通知。

### 3.3 `server.py` — Server 与 @expose

**用途：** 快速将 Python 函数暴露为远程 API。

```python
from lingofuse import Server

app = Server("Calc", "Calculator")

@app.expose("add")
def add(a, b):
    return a + b

app.start_multi(["ipc:calc", "0.0.0.0:9898"])
```

- `@expose(api_name, notify=False)`：注册 Call 或 Notify。
- `start(addr)` / `start_multi(addresses)`：启动服务。
- `stop(full_cleanup=False)`：停止服务，可完整清理。
- `json_call` / `json_notify` / `json_sequenced_notify`：显式 JSON 调用。
- 内部使用 `lf_io.cstr` 处理字符串参数。

### 3.4 `client.py` — C4 动态客户端

**用途：** 连接远程服务，像调用本地方法一样调用远程 API。

```python
from lingofuse import C4

c = C4("Calc", "ipc:calc")
print(c.add(10, 20))   # 30
```

- 通过 `__getattr__` 动态拦截，返回可调用对象。
- 下划线开头的属性不拦截，避免干扰 Python 内省。
- 全局单例连接，每进程只准备一次。
- 必须显式调用 `C4.shutdown()` 或 `C4.full_cleanup()`。

### 3.5 `bridge.py` — HTTP Bridge

**三方向网关：**

| 方向 | 调用方 | 通道 | 用途 |
|------|--------|------|------|
| A 入站 | HTTP 客户端 | HTTP POST → `LF_Call` | 将 HTTP 请求送入 LingoFuse |
| B 出站 | LingoFuse 调用方 | `LF_Call` → HTTP POST | 将 LingoFuse 请求转发到外部 HTTP |
| C 修复 | LingoFuse 调用方 | `LF_Call` → 修复引擎 | 委托修复畸形 JSON |

**启动示例：**

```bash
python bridge.py --endpoint ipc:compute_grid --app pas --port 8081
```

**关键配置：**
- `--forward-only`：禁用 HTTP 监听，仅提供 Call API。
- `--bridge-app` / `--bridge-api` / `--bridge-repair-api`：自定义 API 名称。
- 环境变量：`LINGOFUSE_*`。

**详细契约见 `Bridge_User_Guide.md`。**

### 3.6 `lf_io.py` — 统一 JSON/字符串 I/O

**这是工具链唯一序列化入口。**

- `dumps_json(obj)`：`json.dumps(obj, ensure_ascii=False, default=str)`，保证无 `\uXXXX` 转义。
- `write_string` / `read_string`：UTF-8 + NUL 终止。
- `write_json` / `read_json`：JSON 读写，读取时经过修复预处理。
- `read_json_or_bytes`：宽松读取，非 JSON 返回原始字节。
- `cstr(value)`：生成 NUL 终止 UTF-8 字节，用于 `c_char_p`。

### 3.7 `serializers.py` — 默认 JSON 序列化器

- `default_serializer`：对象 → UTF-8 JSON 字节（无 NUL）。
- `default_deserializer`：字节 → 对象，容忍尾部 NUL，经过修复预处理。

**注意：** 该模块的帧格式与 `lf_io` 不同（无 NUL），用于 `DataHandle.write` / `read` 路径。

### 3.8 `network_events.py` — 网络事件

**安装全局回调：**

```python
from lingofuse import set_network_event, clear_network_event

def on_connect(addr):
    print("Connected:", addr)

def on_disconnect(addr):
    print("Disconnected:", addr)

set_network_event(on_connect, on_disconnect)
```

**关键契约：**
- 回调在后台 C 工作线程执行，不要操作 UI。
- `addr` 是 Python `str`，可安全长期持有。
- **替换语义**：再次调用会替换所有回调，不是补丁。
- 推荐使用 `NetworkEventQueue` 进行队列消费。

### 3.9 `json_repair_preprocess.py` — JSON 修复预处理

**三路策略：**
- 有效 JSON → 原样返回，无日志。
- 可修复 → 返回修复后文本，一条 WARNING。
- 不可修复 → 原样返回，一条 ERROR（严格读路径）。

**环境变量：** `LINGOFUSE_JSON_REPAIR=0` 可禁用修复。

### 3.10 `errors.py` — 异常层次

```python
LingoFuseError
├── ConnectionError
├── TimeoutError
├── RegistrationError
└── SerializationError
```

---

## 4. 测试与验证

### 4.1 `test_lingofuse.py` — 核心单元测试

**覆盖范围：**

| 测试类 | 内容 |
|--------|------|
| `TestDataHandle` | 原子类型读写、Unicode 往返、序列化、位置/大小、上下文管理器、无效 UTF-8 处理、失败初始化安全 |
| `TestApp` | 注册与本地调用、重复注册、回调异常隔离、失败初始化安全 |
| `TestJsonRepairPreprocess` | 三路策略、禁用路径、宽松路径静默、source 标签传播 |
| `TestSerializersRepairPaths` | `default_deserializer` 修复集成、无效 UTF-8 区分、不可修复 JSON 报错 |
| `TestLfIoRepairPaths` | `lf_io.read_json` 和 `read_json_or_bytes` 的修复集成 |
| `TestModuleHelpers` | `generate_app_name`、唯一性、`get_app_name` |
| `TestBindApp` | `App.bind()` 绑定两个客户端，并完成远程调用 |
| `TestOverlapAndFree` | `Overlap_Connection` 行为、`LF_FreeApp` 生命周期 |
| `TestServer` | 单地址、多地址、重复启动报错 |
| `TestNetworkEvents` | 安装/清除、仅 connect、仅 disconnect、队列覆盖警告、监听器基类、队列基本操作 |

**运行方式：**

```bash
python -m unittest lingofuse.test_lingofuse
```

**要求：** Python 3.10+，动态库可用。

### 4.2 `test_bridge.py` — Bridge 冒烟测试

向运行中的 Bridge 发送 HTTP POST，验证响应。

```bash
python -m lingofuse.test_bridge
```

---

## 5. 快速开始

### 5.1 安装

```bash
pip install -e .
```

确保动态库在 `PATH` 或当前目录。

### 5.2 服务端

```python
from lingofuse import Server

app = Server("Calc", "Calculator")

@app.expose("add")
def add(a, b):
    return a + b

app.start_multi(["ipc:calc", "0.0.0.0:9898"])
input("按回车退出...\n")
app.stop()
```

### 5.3 客户端

```python
from lingofuse import C4

c = C4("Calc", "ipc:calc")
print(c.add(10, 20))   # 30
```

### 5.4 HTTP 桥接

```bash
python lingofuse/bridge.py --endpoint ipc:calc --app Calc --port 8081
```

然后浏览器或 curl：

```bash
curl -X POST http://127.0.0.1:8081/Calc/add \
     -H "Content-Type: application/json" \
     -d '[10,20]'
# 返回 30
```

---

## 6. 高级用法

### 6.1 数据句柄两种类型

| 类型 | 创建方式 | 自动回收 | 释放时机 |
|------|----------|:--------:|----------|
| 自动回收 | `DataHandle(api_name)` | 10 分钟空闲 | `LF_FreeData` 标记，下次扫描释放 |
| 永久 | `DataHandle.create_permanent(api_name)` | 永不 | `LF_FreeData` 同步释放 |

### 6.2 网络事件队列

```python
from lingofuse import NetworkEventQueue

q = NetworkEventQueue.global_instance()
q.install()
try:
    while True:
        evt_type, addr = q.get(timeout=1.0)
        print(evt_type, addr)
finally:
    q.uninstall()
```

### 6.3 JSON 修复

```python
from lingofuse import repair_json_text

fixed = repair_json_text("{'a': 1,}", source="my_app")
# 返回 '{"a": 1}'
```

### 6.4 Bridge 出站 HTTP

通过 LingoFuse 调用 Bridge 的 `__lf_outbound_post__`：

```python
from lingofuse import C4

c = C4("__lf_http_bridge__", "ipc:lingofuse_bridge")
resp = c.__lf_outbound_post__({
    "url": "https://api.example.com/echo",
    "method": "POST",
    "body": {"msg": "hello"}
})
```

---

## 7. 配置选项

`lingofuse.set_option(option, value)` 支持：

| 选项 | 默认 | 说明 |
|------|------|------|
| `password` / `passwd` | — | C4 P2PVM 认证 |
| `Quiet` | False | 安静模式 |
| `Overlap_Connection` | False | 允许多客户端同地址 |
| `Wait_Connection_ReadyOk` | True | 是否等待客户端就绪 |
| `Wait_Connection_Timeout` | 30000 | 等待超时毫秒 |
| `DataHandle_Idle_Timeout` | 600000 | 数据句柄空闲回收毫秒 |
| `DataHandle_Pool_Scan_Interval` | 5000 | 扫描间隔毫秒 |
| `Fixed_Sequenced_Time` | 20000 | 顺序通知回退阈值 |

环境变量：`LINGOFUSE_JSON_REPAIR=0` 禁用 JSON 修复。

---

## 8. 常见坑与 FAQ

**Q：`generate_app_name()` 什么时候调？**
A：必须在 `LF_PrepareDone` 返回 1 之后调用。

**Q：`check_app()` 返回 False，但服务已注册？**
A：广播缓存延迟约 3 秒，重试或直接调用。

**Q：回调里能调 `LF_Call` 吗？**
A：绝对不行，会死锁。请另开线程。

**Q：多个 App 想连同一个地址？**
A：设 `Overlap_Connection=True`，或先建立空隧道再 `BindApp`。

**Q：HTTP Bridge 返回的 JSON 带 `\0`？**
A：新版 `bridge.py` 会自动剥离尾部 `\0`。

**Q：动态库找不到？**
A：将 `LingoFuse64.dll` / `liblingofuse.so` 放到当前目录或 PATH。

**Q：`LF_PrepareDone` 第二次返回 0？**
A：每进程只成功一次。要重启，先 `LF_Shutdown` + `LF_ResetPrepare`。

**Q：`LF_FreeApp` 后内存没降？**
A：两阶段析构，对象在 `LF_Shutdown` 时才真正销毁。

---

## 9. 与 Pascal 绑定的对比

| 功能 | Python | Pascal |
|------|--------|--------|
| 底层绑定 | `_lf_native.py` | `lingofuse_import.pas` |
| RAII 封装 | `DataHandle` / `App` | `TDataHandle` / `TAppHandle` |
| 服务端 | `Server` + `@expose` | `LF.TAppHandle` + `RegisterCall` |
| 客户端 | `C4` 动态属性 | `LF.CallApp` |
| HTTP Bridge | `bridge.py` | `lf_http_bridge_client.pas` |
| JSON 修复 | `repair_json_text` | 通过 Bridge 调用 |
| 网络事件 | `set_network_event` | `LF_Set_Network_Event` |

---

## 10. 许可证

MIT。随便用，随便改，拿去卖钱也行。

---

*本文档随 LingoFuse Python 绑定 v3.0 整理，覆盖 `test_lingofuse.py` 全部测试场景。*
*最后更新：2026-10-02*