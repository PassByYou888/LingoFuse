# Go Cross Demo — Cross-Language Interop with LingoFuse

Three Go programs that interoperate with the C++ / C# / Pascal / JS
counterparts over the same `ipc:cross` endpoint. Any language can play
any role.

## Programs

| Program | Role |
|---------|------|
| `cross-service` | Coordinator: creates the `ipc:cross` endpoint, holds the mesh together. |
| `cross-node`    | Worker: registers the `add` and `inv_seri` Call APIs under application `demo`. |
| `cross-call`    | Load tester: 32 goroutines repeatedly invoke `add` / `inv_seri`. |

## Wire format (byte-for-byte identical to every other binding)

### `add`

```
input  : int32 LE + int32 LE
output : int32 LE
```

### `inv_seri`

```
input  : uint8 + uint16 LE + uint32 LE + uint64 LE + string(NUL) + float32 LE
output : float32 LE + string(NUL) + uint64 LE + uint32 LE + uint16 LE + uint8
```

The string is UTF-8, NUL-terminated. All integers and floats are
little-endian. This matches the C++, C#, Pascal, Python, and JavaScript
bindings exactly.

## Build

From the `go/` module root:

```powershell
cd D:\CoreLibrary\LingoFuse\go
go build -o cross-service.exe ./cross/cross-service
go build -o cross-node.exe    ./cross/cross-node
go build -o cross-call.exe    ./cross/cross-call
```

Or run directly without producing binaries:

```powershell
go run ./cross/cross-service
go run ./cross/cross-node
go run ./cross/cross-call
```

## Run (single language: all Go)

Open three terminals in `D:\CoreLibrary\LingoFuse\go`:

**Terminal 1 — Service**

```powershell
go run ./cross/cross-service
```

Wait for `[Service] IPC service 'ipc:cross' is running.`

**Terminal 2 — Node**

```powershell
go run ./cross/cross-node
```

Wait for `[Node] Online.`

**Terminal 3 — Call**

```powershell
go run ./cross/cross-call
```

The load test runs for 10 seconds and prints a summary.

## Run (cross-language: Go node + C++ caller)

**Terminal 1 — C++ CrossService**

```
Binary\CrossService.exe
```

**Terminal 2 — Go CrossNode**

```powershell
cd D:\CoreLibrary\LingoFuse\go
go run ./cross/cross-node
```

**Terminal 3 — C++ CrossCall**

```
Binary\CrossCall.exe
```

Both `add` and `inv_seri` will succeed: the wire format produced by
`CrossCall.cpp` is exactly the format the Go `cross-node` reads, and
the reply format the Go node writes is exactly what `CrossCall.cpp`
parses.

## Run (cross-language: C# caller + Go node + JS service)

Any combination works. The required order is:

1. Start one coordinator (any language).
2. Start one or more nodes (any language).
3. Start one or more callers (any language).

The coordinator may be started before or after the nodes if all
participants set `Wait_Ready=False` on the node side, as the Go node
does. The Go caller uses `Wait_Connection_ReadyOk=True`, so it will
block until the endpoint is reachable.

## Cleanup order (LF-CLEAN-001)

Every Go program runs the required sequence on every exit path:

```
ExitMainThread  ->  app.Close  ->  Shutdown
```

Both `ExitMainThread` and `Shutdown` are idempotent. The node's
`app.Close` is a no-op after the first call.
```

---

## 编译与运行验证

在 `go/` 目录下执行：

```powershell
cd D:\CoreLibrary\LingoFuse\go

# 1. 编译三个程序，检查是否有类型/导入错误
go build ./cross/...
go vet ./cross/...

# 2. 全量编译（包括之前的 sys / lingofuse / test）
go build ./...
go vet ./...
```

预期 `go build ./...` 和 `go vet ./...` 均无输出。

---

## 跨语言互通测试（推荐步骤）

在三个终端里依次启动：

**终端 1：Go 协调器**

```powershell
cd D:\CoreLibrary\LingoFuse\go
go run ./cross/cross-service
```

等 `[Service] IPC service 'ipc:cross' is running.` 出现。

**终端 2：C++ 工作节点（或 Go、C#、Pascal、JS 任选）**

```
D:\CoreLibrary\LingoFuse\Binary\CrossNode.exe
```

**终端 3：Go 压测客户端**

```powershell
cd D:\CoreLibrary\LingoFuse\go
go run ./cross/cross-call
```

预期 10 秒后打印 `success: N (100.00 %)`，节点终端也会打印 `add(...) = ...` 和 `inv_seri received/replied` 日志。

任何一端换成其他语言实现都能正常工作——这正是 cross demo 的验证目标。
