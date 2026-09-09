# cross_bridge_architecture_zh.md

## 1. 概述

`cross_bridge.py` 是 LingoFuse 的 **JSON ↔ 二进制协议适配器**，使 JavaScript、PHP 等动态语言能通过 HTTP/JSON 调用底层二进制 RPC 节点（`cross_node.py`）。适用于演示、调试和快速原型，生产环境建议直接使用 `bridge.py` 或原生客户端。

---

## 2. 系统架构

```mermaid
graph TB
    subgraph Clients
        JS[浏览器 / JS]
        PHP[PHP / curl]
        PY[Python 脚本]
    end

    subgraph Gateway
        BRIDGE[bridge.py<br>通用 HTTP 网关]
    end

    subgraph Adapter
        CB[cross_bridge.py<br>协议适配器<br>app: cross_bridge]
    end

    subgraph Backend
        NODE[cross_node.py<br>业务节点<br>app: demo]
        SVC[cross_service.py<br>服务注册中心<br>ipc:cross]
    end

    JS -->|HTTP JSON| BRIDGE
    PHP -->|HTTP JSON| BRIDGE
    PY -->|HTTP JSON| BRIDGE

    BRIDGE -->|LingoFuse 二进制| CB
    CB -->|LingoFuse 二进制| NODE
    NODE -.->|注册/发现| SVC
    CB -.->|注册/发现| SVC
    BRIDGE -.->|连接| SVC
```

> 实线 = 数据流，虚线 = 服务注册与发现。

---

## 3. 数据流：从 JSON 到二进制再返回

```mermaid
sequenceDiagram
    participant Client
    participant Bridge
    participant Adapter
    participant Node

    Client->>Bridge: POST /add JSON: [10,20]
    Bridge->>Adapter: 二进制转发（原样）
    Adapter->>Adapter: 解析 JSON → a=10, b=20
    Adapter->>Adapter: DataHandle.write_int32(a), write_int32(b)
    Adapter->>Node: LF_Call("add", 二进制)
    Node->>Node: 计算 a+b
    Node->>Adapter: 返回 int32 结果 (30)
    Adapter->>Adapter: read_int32() → 30
    Adapter->>Adapter: 构造 JSON {"code":0,"result":30}
    Adapter->>Bridge: 二进制响应（含 JSON 字符串）
    Bridge->>Client: JSON 响应
```

---

## 4. 使用场景

```mermaid
graph LR
    subgraph 推荐
        A[浏览器调试] --> CB[cross_bridge]
        B[快速原型开发] --> CB
        C[教学/演示] --> CB
    end

    subgraph 不推荐
        D[高吞吐生产] --> NAT[原生客户端 / bridge.py]
        E[二进制文件传输] --> NAT
        F[微服务间调用] --> NAT
    end
```

---

## 5. 启动流程

```mermaid
flowchart TD
    A[启动 cross_service.py] --> B[服务注册中心就绪]
    B --> C[启动 cross_node.py]
    C --> D[业务节点就绪]
    D --> E[启动 cross_bridge.py]
    E --> F{检查依赖}
    F -->|正常| G[适配器注册成功]
    G --> H[自动启动 bridge.py 子进程]
    H --> I[HTTP 网关监听端口]
    I --> J[系统就绪，等待请求]
    F -->|失败| K[输出错误日志，退出]
```

> `cross_bridge.py` 默认会自动启动 `bridge.py` 子进程，也可以手动单独启动 `bridge.py`。

---

## 6. 协议转换细节

```mermaid
graph LR
    subgraph 入站处理
        A[JSON 请求] --> B[解析为 Python 对象]
        B --> C[提取参数]
        C --> D[写入 DataHandle 二进制]
        D --> E[LF_Call 发送]
    end

    subgraph 出站处理
        F[二进制响应] --> G[读取 int/string]
        G --> H[构造 JSON 对象]
        H --> I[返回 HTTP 响应]
    end
```

**支持的 API**：

| API | 输入格式 | 输出格式 |
|-----|---------|---------|
| `add` | `[a,b]` 或 `{"a":a,"b":b}` | `{"code":0,"result":a+b}` |
| `inv_seri` | 含 `b,w,c,u64,s,f` 的对象或数组（缺失用默认值） | `{"code":0,"result":"格式化字符串"}` |

---

## 7. bridge.py 与 cross_bridge.py 的关系

```mermaid
graph TB
    subgraph bridge.py
        B1[通用 HTTP 网关]
        B2[纯二进制转发<br>不解析内容]
        B3[适合任意载荷]
    end

    subgraph cross_bridge.py
        C1[特定应用适配器]
        C2[JSON ↔ 二进制转换]
        C3[仅适用于 demo 节点]
    end

    B1 -.- C1
    B2 -.- C2
    B3 -.- C3
```

**协作方式**：
- `bridge.py` 可独立部署，直接连接任意 LingoFuse 服务。
- `cross_bridge.py` 内部自动启动 `bridge.py`，使 HTTP 客户端能访问 JSON 适配接口。
- 生产环境若仅需通用 HTTP 接入，直接部署 `bridge.py` 即可。

---

## 8. 常见问题排查

```mermaid
graph TD
    Q[请求返回错误] --> C1{检查 cross_node 是否运行}
    C1 -->|否| S1[启动 cross_node]
    C1 -->|是| C2{检查 cross_service 是否运行}
    C2 -->|否| S2[启动 cross_service]
    C2 -->|是| C3{检查 JSON 格式}
    C3 -->|错误| S3[修正为数组或对象格式]
    C3 -->|正确| S4[查看适配器终端日志]
```

**其他常见问题**：
- **跨域**：`bridge.py` 已配置 CORS 头，允许所有来源。
- **性能**：JSON 转换会引入额外延迟，高并发场景请使用原生客户端或纯二进制网关。
- **端口占用**：通过 `--http-port` 参数修改 HTTP 端口。

---

## 9. 总结

`cross_bridge.py` 是一个轻量级适配器，专为二进制 LingoFuse 节点（如 `cross_node.py`）提供 JSON 接口，降低动态语言接入门槛。适合演示和开发环境，生产环境建议直接使用 `bridge.py` 或原生 LingoFuse 客户端以获得最佳性能和通用性。