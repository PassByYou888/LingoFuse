# cross_bridge_architecture_en.md

> Chinese version: [cross_bridge_architecture_zh.md](cross_bridge_architecture_zh.md)

## 1. Overview

`cross_bridge.py` is LingoFuse's **JSON ↔ binary protocol adapter**, letting dynamic languages such as JavaScript and PHP call a binary RPC node (`cross_node.py`) over HTTP/JSON. It suits demos, debugging and quick prototyping; for production, use `bridge.py` or a native client directly.

---

## 2. System architecture

```mermaid
graph TB
    subgraph Clients
        JS[Browser / JS]
        PHP[PHP / curl]
        PY[Python script]
    end

    subgraph Gateway
        BRIDGE[bridge.py<br>generic HTTP gateway]
    end

    subgraph Adapter
        CB[cross_bridge.py<br>protocol adapter<br>app: cross_bridge]
    end

    subgraph Backend
        NODE[cross_node.py<br>business node<br>app: demo]
        SVC[cross_service.py<br>service registry<br>ipc:cross]
    end

    JS -->|HTTP JSON| BRIDGE
    PHP -->|HTTP JSON| BRIDGE
    PY -->|HTTP JSON| BRIDGE

    BRIDGE -->|LingoFuse binary| CB
    CB -->|LingoFuse binary| NODE
    NODE -.->|register/discover| SVC
    CB -.->|register/discover| SVC
    BRIDGE -.->|connect| SVC
```

> Solid lines = data flow, dashed lines = service registration and discovery.

---

## 3. Data flow: from JSON to binary and back

```mermaid
sequenceDiagram
    participant Client
    participant Bridge
    participant Adapter
    participant Node

    Client->>Bridge: POST /add JSON: [10,20]
    Bridge->>Adapter: binary forwarding (unchanged)
    Adapter->>Adapter: parse JSON → a=10, b=20
    Adapter->>Adapter: DataHandle.write_int32(a), write_int32(b)
    Adapter->>Node: LF_Call("add", binary)
    Node->>Node: compute a+b
    Node->>Adapter: return int32 result (30)
    Adapter->>Adapter: read_int32() → 30
    Adapter->>Adapter: build JSON {"code":0,"result":30}
    Adapter->>Bridge: binary response (containing a JSON string)
    Bridge->>Client: JSON response
```

---

## 4. Use cases

```mermaid
graph LR
    subgraph Recommended
        A[Browser debugging] --> CB[cross_bridge]
        B[Rapid prototyping] --> CB
        C[Teaching / demos] --> CB
    end

    subgraph Not recommended
        D[High-throughput production] --> NAT[Native client / bridge.py]
        E[Binary file transfer] --> NAT
        F[Service-to-service calls] --> NAT
    end
```

---

## 5. Startup sequence

```mermaid
flowchart TD
    A[Start cross_service.py] --> B[Service registry ready]
    B --> C[Start cross_node.py]
    C --> D[Business node ready]
    D --> E[Start cross_bridge.py]
    E --> F{Check dependencies}
    F -->|OK| G[Adapter registered]
    G --> H[Auto-start bridge.py child process]
    H --> I[HTTP gateway listening on a port]
    I --> J[System ready, waiting for requests]
    F -->|Failure| K[Log the error and exit]
```

> `cross_bridge.py` starts a `bridge.py` child process automatically by default, but you can also start `bridge.py` separately by hand.

---

## 6. Protocol conversion details

```mermaid
graph LR
    subgraph Inbound
        A[JSON request] --> B[Parse into Python objects]
        B --> C[Extract parameters]
        C --> D[Write into the DataHandle binary]
        D --> E[Send via LF_Call]
    end

    subgraph Outbound
        F[Binary response] --> G[Read int/string]
        G --> H[Build a JSON object]
        H --> I[Return the HTTP response]
    end
```

**Supported APIs**:

| API | Input format | Output format |
|-----|---------|---------|
| `add` | `[a,b]` or `{"a":a,"b":b}` | `{"code":0,"result":a+b}` |
| `inv_seri` | an object or array containing `b,w,c,u64,s,f` (missing fields use defaults) | `{"code":0,"result":"formatted string"}` |

---

## 7. How bridge.py relates to cross_bridge.py

```mermaid
graph TB
    subgraph bridge.py
        B1[Generic HTTP gateway]
        B2[Pure binary forwarding<br>does not parse content]
        B3[Works with any payload]
    end

    subgraph cross_bridge.py
        C1[Application-specific adapter]
        C2[JSON ↔ binary conversion]
        C3[Only for the demo node]
    end

    B1 -.- C1
    B2 -.- C2
    B3 -.- C3
```

**How they work together**:
- `bridge.py` can be deployed standalone and connects directly to any LingoFuse service.
- `cross_bridge.py` starts `bridge.py` internally, so HTTP clients can reach the JSON adapter interface.
- In production, if you only need generic HTTP access, deploying `bridge.py` on its own is enough.

---

## 8. Troubleshooting

```mermaid
graph TD
    Q[Request returns an error] --> C1{Is cross_node running?}
    C1 -->|No| S1[Start cross_node]
    C1 -->|Yes| C2{Is cross_service running?}
    C2 -->|No| S2[Start cross_service]
    C2 -->|Yes| C3{Check the JSON format}
    C3 -->|Wrong| S3[Fix it to array or object form]
    C3 -->|Right| S4[Check the adapter terminal log]
```

**Other common issues**:
- **Cross-origin**: `bridge.py` already sets CORS headers and allows all origins.
- **Performance**: JSON conversion adds latency; under high concurrency use a native client or the pure binary gateway.
- **Port in use**: change the HTTP port with the `--http-port` argument.

---

## 9. Summary

`cross_bridge.py` is a lightweight adapter that gives binary LingoFuse nodes (such as `cross_node.py`) a JSON interface, lowering the barrier for dynamic languages. It suits demos and development environments; for production, use `bridge.py` or a native LingoFuse client directly for the best performance and versatility.
