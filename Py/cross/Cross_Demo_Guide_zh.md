# Cross Demo 使用指南

本文档介绍 LingoFuse Python 绑定中的 **Cross 示例**，涵盖服务注册中心、工作节点、适配器及 HTTP 网关的配置与启动方法，帮助您快速体验 LingoFuse 的分布式 RPC 能力。

---

## 1. 目录结构

```
Py/
├── init_demo_env.ps1                      # Windows 环境初始化脚本
├── cross/                                 # Cross 示例根目录
│   ├── cross_service.py                   # 服务注册中心（信标）
│   ├── cross_node.py                      # 工作节点（demo 应用）
│   ├── cross_call.py                      # 并发测试客户端（直接调用 demo 节点）
│   ├── cross_bridge.py                    # LingoFuse 适配器（JSON ↔ 二进制转换）
│   ├── nodejs/                            # Node.js 客户端
│   │   └── node_cross_client.js
│   ├── php/                               # PHP 客户端
│   │   └── php_cross_client.php
│   └── webjs/                             # 浏览器客户端
│       └── web_cross_client.html
└── lingofuse/                             # 核心绑定包
    ├── bridge.py                          # 通用 HTTP 网关（纯二进制转发）
    └── ... （其他核心文件）
```

---

## 2. 架构概览

Cross 示例演示了三种常见的 LingoFuse 部署模式：

### 2.1 直接模式（最简）
- `cross_service.py`（服务注册中心）
- `cross_node.py`（工作节点）
- `bridge.py` 直接连接节点，不解析 HTTP 请求体，仅转发原始二进制数据。

```mermaid
graph LR
    A[HTTP 客户端] --> B[bridge.py]
    B -->|LingoFuse| C[cross_node.py]
    C -->|注册| D[cross_service.py]
```

### 2.2 适配器模式（分层）
- `cross_service.py`（服务注册中心）
- `cross_node.py`（工作节点）
- `cross_bridge.py`（适配器，接受 JSON 请求，转换为二进制调用节点）
- `bridge.py` 连接适配器，同样只转发原始数据。

```mermaid
graph LR
    A[HTTP 客户端] --> B[bridge.py]
    B -->|LingoFuse| C[cross_bridge.py]
    C -->|原始二进制| D[cross_node.py]
    D -->|注册| E[cross_service.py]
```

适配器模式解耦了协议转换与业务逻辑，便于扩展。

---

## 3. 环境准备

### 3.1 依赖
- Python 3.6+
- Flask（仅 `bridge.py` 需要）
- LingoFuse 动态库（`LingoFuse64.dll` / `liblingofuse.so`）

### 3.2 环境变量
在 PowerShell（Windows）中执行：
```powershell
.\init_demo_env.ps1
```
或在 Linux/macOS 中手动添加：
```bash
export PYTHONPATH="/path/to/Py:$PYTHONPATH"
export PATH="/path/to/Binary:$PATH"
```

### 3.3 安装 Flask
```bash
pip install flask
```

---

## 4. 启动步骤

### 4.1 基础模式（直接调用 demo 节点）

**终端 1 – 服务注册中心**
```bash
python cross/cross_service.py
```
输出示例：
```
[OK] Service registry ready on ipc:cross
[INFO] Press Enter to stop the service...
```

**终端 2 – 工作节点**
```bash
python cross/cross_node.py
```
输出示例：
```
[OK] Node ready on ipc:cross, waiting for requests...
```

**终端 3 – HTTP 网关（直接连接节点）**
```bash
python lingofuse/bridge.py --endpoint ipc:cross --app demo --debug --port 8081
```
输出示例：
```
=== LingoFuse HTTP Bridge (Raw Passthrough) ===
Endpoint: ipc:cross
Default app: demo
Timeout: 5000ms
Threaded: True
Debug: True
Path format: /<app>/<api>  or  /<api> (uses default app)
[Bridge] Connected to LingoFuse service: ipc:cross
Starting HTTP service: http://0.0.0.0:8081
```

**注意**：`bridge.py` 现在采用**纯二进制转发**模式，不解析 JSON 请求体。路径格式为 `/<app>/<api>` 或 `/<api>`（使用默认应用）。

### 4.2 适配器模式（推荐）

**终端 1 – 服务注册中心**
```bash
python cross/cross_service.py
```

**终端 2 – 工作节点**
```bash
python cross/cross_node.py
```

**终端 3 – 适配器**
```bash
python cross/cross_bridge.py
```
默认服务端点 `ipc:cross_bridge_service`，连接节点 `ipc:cross`。

**终端 4 – HTTP 网关连接适配器**
```bash
python lingofuse/bridge.py --endpoint ipc:cross_bridge_service --port 8081 --debug
```
此处不需要 `--app`，因为客户端将在路径中显式指定应用名（如 `/cross_bridge/add`）。

---

## 5. 测试调用

### 5.1 浏览器测试
打开 `cross/webjs/web_cross_client.html`，点击按钮：
- **调用 add(10,20)**：预期显示 `✅ 10 + 20 = 30`
- **调用 inv_seri**：预期显示类似 `✅ inv_seri 结果: 接收数据序 [...] = 发送数据序 [...]`

浏览器客户端已修改为直接发送请求体（如 `[10,20]` 或 `{}`），并访问路径 `/cross_bridge/add`。

### 5.2 curl 命令行测试（适配器模式）

```bash
# add API – 发送 [10,20]，路径显式指定 app 和 api
curl -X POST http://127.0.0.1:8081/cross_bridge/add \
     -H "Content-Type: application/json" \
     -d '[10,20]'
# 返回 {"code":0,"result":30}

# inv_seri API – 发送 {} 使用默认参数
curl -X POST http://127.0.0.1:8081/cross_bridge/inv_seri \
     -H "Content-Type: application/json" \
     -d '{}'
# 返回 {"code":0,"result":"接收数据序 [...] = 发送数据序 [...]"}
```

### 5.3 Node.js 客户端
```bash
cd cross/nodejs
node node_cross_client.js
```
输出：
```
10 + 20 = 30
inv_seri 结果: 接收数据序 ...
```

### 5.4 PHP 客户端
```bash
cd cross/php
php php_cross_client.php
```
输出类似。

---

## 6. 配置选项

### 6.1 `cross_bridge.py` 参数
| 参数 | 环境变量 | 默认值 | 说明 |
|------|---------|--------|------|
| `--endpoint` | `CROSS_BRIDGE_ENDPOINT` | `ipc:cross_bridge_service` | 适配器自身服务端点 |
| `--node-endpoint` | `CROSS_BRIDGE_NODE` | `ipc:cross` | demo 节点端点 |
| `--app-name` | `CROSS_BRIDGE_APP` | `cross_bridge` | 适配器应用名称 |
| `--timeout` | `CROSS_BRIDGE_TIMEOUT` | `5000` | 调用超时（ms） |

### 6.2 `bridge.py` 参数
| 参数 | 环境变量 | 默认值 | 说明 |
|------|---------|--------|------|
| `--host` | `LINGOFUSE_HOST` | `0.0.0.0` | HTTP 监听地址 |
| `--port` | `LINGOFUSE_PORT` | `8081` | HTTP 监听端口 |
| `--endpoint` | `LINGOFUSE_ENDPOINT` | `ipc:lingofuse_bridge` | LingoFuse 服务端点 |
| `--timeout` | `LINGOFUSE_TIMEOUT` | `5000` | 默认超时（ms） |
| `--app` | `LINGOFUSE_APP` | `None` | 默认目标应用（仅当路径只有 API 名时使用） |
| `--threaded` / `--no-threaded` | - | `True` | 是否启用多线程 |
| `--debug` | - | `False` | 启用调试日志（打印请求/响应内容） |

> **注意**：`--routes` 和 `--mode` 参数已被移除，因为现在只有一种路由模式（路径驱动）。

---

## 7. 常见问题

### 7.1 动态库加载失败
- 确保 `LingoFuse64.dll`（或同名）位于系统 `PATH` 或当前目录。
- Windows 下可运行 `init_demo_env.ps1` 自动添加 `Binary` 目录到 `PATH`。

### 7.2 连接超时
- 检查 `cross_service.py` 是否运行。
- 检查 `cross_node.py` 是否运行。
- 检查 `cross_bridge.py`（若使用）是否运行。

### 7.3 端口占用
- 修改 `--port` 参数。
- 若 IPC 端点冲突（如 `ipc:cross_bridge_service` 已被占用），可使用其他名称（如 `ipc:my_adapter`）。

### 7.4 浏览器解析 JSON 报错
- 确保 `bridge.py` 已更新至最新版本（自动去除尾部 `\0` 字节）。
- 确保 `cross_bridge.py` 返回标准格式 `{"code":0, "result":...}`。

---

## 8. 扩展开发

### 8.1 添加新 API
1. 在 `cross_node.py` 中新增回调函数，并注册到 `app`。
2. 在 `cross_bridge.py`（若使用）中新增对应的 JSON 回调，转发至节点。
3. 客户端请求时以 `/<app>/<api>` 路径访问，请求体为所需参数。

### 8.2 自定义序列化
`bridge.py` 不进行任何序列化，直接转发原始数据。若需要 JSON 解析，应在 `cross_bridge.py` 或后端节点中处理。

---

## 9. 总结

Cross 示例完整展示了 LingoFuse 的部署方式，包括服务注册、节点注册、适配器转换和 HTTP 网关。新版 `bridge.py` 作为纯二进制转发网关，简化了架构，提高了灵活性。您可以根据实际需求选择直接模式或适配器模式，并借助 `bridge.py` 快速为任意 LingoFuse 应用提供 HTTP 接口。