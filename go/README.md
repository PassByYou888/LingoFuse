# LingoFuse Go 绑定

[LingoFuse](https://github.com/PassByYou888/LingoFuse) 是一个跨语言、跨进程、跨机器的分布式 RPC 框架，
底层基于 C4 服务网格。本目录是 LingoFuse 的 **Go 语言官方绑定**，提供与 C++ / C# / Pascal / Python / JavaScript
实现**逐字节兼容**的线格式，可与这些语言的进程在同一个网格中自由混搭。

- **纯 Go FFI**：基于 [purego](https://github.com/ebitengine/purego)，无需 cgo，无需 C 编译器
- **交叉编译友好**：`GOOS=windows go build` 即可，不需要工具链切换
- **RAII 风格 API**：`DataHandle` / `AppHandle` 显式 `Close()`，不依赖 `runtime.SetFinalizer`
- **类型安全**：`sys` 层是唯一涉及原生调用的地方，上层全部走 `lingofuse` 包
- **完整测试**：18 个测试覆盖 ABI smoke、标量/字符串/JSON I/O、错误层级、同进程 E2E 全流程

---

## 目录

- [一、环境要求](#一环境要求)
- [二、目录结构](#二目录结构)
- [三、安装与部署](#三安装与部署)
- [四、编译](#四编译)
- [五、测试](#五测试)
- [六、快速开始](#六快速开始)
- [七、跨语言 Cross Demo](#七跨语言-cross-demo)
- [八、API 速查](#八api-速查)
- [九、核心概念](#九核心概念)
- [十、六条铁律](#十六条铁律)
- [十一、故障排查](#十一故障排查)
- [十二、与其它语言绑定的差异](#十二与其它语言绑定的差异)

---

## 一、环境要求

### 1.1 Go 版本

| 组件 | 最低版本 | 说明 |
|------|:--------:|------|
| Go 语言 | **1.21** | `any` / `unsafe.Add` / `sync/atomic` 的 `Int64`/`Bool`/`Uintptr` 类型在此版本起可用 |

推荐使用 Go 1.22 或更高版本。

### 1.2 操作系统与架构

| 平台 | 架构 | 状态 |
|------|:----:|:----:|
| Windows | amd64 / arm64 | ✅ 完整支持 |
| Linux | amd64 / arm64 | ✅ 完整支持 |
| macOS | amd64 / arm64 | ✅ 完整支持 |
| 其它 | 任意 | ⚠️ 依赖 `purego` 的支持范围 |

### 1.3 原生库

Go 绑定在运行时通过 `purego` 加载原生动态库，**不参与编译链接**。所需文件：

| 平台 | 文件名 |
|------|--------|
| Windows 64 位 | `LingoFuse64.dll` |
| Windows 32 位 | `LingoFuse32.dll` |
| Linux / BSD | `liblingofuse.so` |
| macOS | `liblingofuse.dylib` |

主仓库的 `Binary/` 目录已附带 Windows 版本的原生库。Linux / macOS 版本需要从源码自行构建（见主仓库 README）。

### 1.4 不需要的

- ❌ 不需要 C 编译器（gcc / clang / MSVC）
- ❌ 不需要设置 `CGO_ENABLED=1`
- ❌ 不需要 Python / Node.js / .NET 运行时

---

## 二、目录结构

```
go/
├── go.mod                      # 模块定义
├── go.sum                      # 依赖校验
├── README.md                   # 本文件
├── LingoFuse64.dll             # 原生库（手动放置，见 §3）
│
├── sys/                        # ① 低层 FFI 层
│   ├── bindings.go             #   37 个 C 导出函数指针
│   ├── loader.go               #   purego 动态加载 + 符号解析
│   ├── loader_windows.go       #   Windows 平台绑定
│   ├── loader_unix.go          #   Unix 平台绑定
│   ├── callbacks.go            #   回调桥接（trigger ID ↔ Go 函数）
│   └── strings.go              #   C 字符串辅助
│
├── lingofuse/                  # ② 高层 RAII 层
│   ├── errors.go               #   Error / ErrorCode 层级
│   ├── data_handle.go          #   RAII DataHandle
│   ├── app_handle.go           #   RAII AppHandle
│   ├── io.go                   #   JSON / 字符串 / 字节统一 I/O
│   ├── framework.go            #   进程级 Facade
│   ├── network_events.go       #   进程级网络事件回调
│   └── status.go               #   状态队列 + 健康检查
│
├── cross/                      # ③ 跨语言演示
│   ├── cross-service/main.go   #   协调器
│   ├── cross-node/main.go      #   工作节点（注册 add / inv_seri）
│   ├── cross-call/main.go      #   并发压测客户端
│   └── README.md
│
├── test/                       # ④ 测试
│   ├── abi_smoke_test.go
│   ├── data_handle_test.go
│   ├── errors_test.go
│   └── e2e_test.go
│
├── build.ps1                   # 编译脚本
├── test.ps1                    # 测试脚本
└── clean.ps1                   # 清理脚本
```

**分层原则**：`sys` 是唯一直接调用原生代码的层。`lingofuse` 只依赖 `sys`，不直接碰 `purego`。

---

## 三、安装与部署

### 3.1 获取源码

```bash
git clone https://github.com/PassByYou888/LingoFuse.git
cd LingoFuse/go
```

### 3.2 配置 Go 模块代理（中国大陆必需）

`proxy.golang.org` 在中国大陆不可达，需要切换到国内镜像：

```powershell
go env -w GOPROXY=https://goproxy.cn,https://goproxy.io,direct
go env -w GOSUMDB=off
```

或使用阿里云 / 腾讯云镜像：

```powershell
go env -w GOPROXY=https://mirrors.aliyun.com/goproxy/,direct
# 或
go env -w GOPROXY=https://mirrors.tencent.com/go/,direct
```

### 3.3 下载依赖

```powershell
cd D:\CoreLibrary\LingoFuse\go
go mod tidy
```

会拉取 `github.com/ebitengine/purego v0.8.1`。

### 3.4 放置原生库

Go 绑定在运行时按以下顺序查找原生库：

1. **可执行文件所在目录**
2. **可执行文件目录下的 `native/` 子目录**
3. **当前工作目录**
4. **系统加载器搜索路径**（`PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH`）

最简单的做法是把它放在模块根目录：

```powershell
Copy-Item ..\Binary\LingoFuse64.dll .
```

如果要在别的工程里引用本绑定，把 DLL 放在**该工程的可执行文件目录**即可。

### 3.5 在其它工程里引用

```bash
# 在你的工程目录里
go get github.com/PassByYou888/LingoFuse/go
```

然后在 `main.go` 里：

```go
import (
    "github.com/PassByYou888/LingoFuse/go/lingofuse"
)
```

此时需要自行保证 `LingoFuse64.dll` 与你的可执行文件在同一个目录（或系统 `PATH` 中）。

---

## 四、编译

### 4.1 一键脚本

在 `go/` 目录下：

```powershell
# 编译所有包 + vet + 三个 cross 可执行文件（输出到 go\bin\）
.\build.ps1

# 跳过 vet（更快）
.\build.ps1 -SkipVet
```

`build.ps1` 会：

1. 执行 `go build ./...` 编译全部包
2. 执行 `go vet ./...` 静态检查
3. 编译三个 cross 可执行文件到 `go\bin\`
4. 从 `..\Binary\LingoFuse64.dll` 拷贝原生库到 `go\bin\`

### 4.2 手动编译

```powershell
cd D:\CoreLibrary\LingoFuse\go

# 只做编译检查（不产生产物）
go build ./...

# 静态检查
go vet ./...

# 编译 cross 可执行文件
go build -o .\bin\cross-service.exe .\cross\cross-service
go build -o .\bin\cross-node.exe    .\cross\cross-node
go build -o .\bin\cross-call.exe    .\cross\cross-call
```

### 4.3 交叉编译

因为不使用 cgo，交叉编译只需切换 `GOOS` / `GOARCH`：

```powershell
$env:GOOS = "linux"; $env:GOARCH = "amd64"
go build ./...

$env:GOOS = "darwin"; $env:GOARCH = "arm64"
go build ./...

# 恢复
Remove-Item Env:\GOOS, Env:\GOARCH
```

**注意**：交叉编译只编译 Go 代码；运行时仍需目标平台的原生库（`liblingofuse.so` / `liblingofuse.dylib`）。

### 4.4 清理

```powershell
.\clean.ps1
```

删除 `go\bin\` 目录、Go 构建缓存、Go 测试缓存。**不删除** `LingoFuse64.dll` 和任何源码。

---

## 五、测试

### 5.1 一键脚本

```powershell
# 全量测试（单元 + E2E 集成）
.\test.ps1

# 只跑单元测试，跳过 E2E（约 1 秒）
.\test.ps1 -Short

# 启用 race detector（需要 gcc 在 PATH 中）
.\test.ps1 -Race

# 每个包一行输出（不打印 -v 的详细日志）
.\test.ps1 -Quiet
```

### 5.2 手动测试

```powershell
cd D:\CoreLibrary\LingoFuse\go

# 全部测试
go test ./... -v

# 只跑 ABI smoke
go test ./test/ -run 'TestLibrary|TestDataHandle|TestPermanent' -v

# 只跑 E2E（约 25 秒）
go test ./test/ -run 'TestE2E_' -v

# 只跑错误层级测试
go test ./test/ -run 'TestError|TestNullHandle|TestInvalid' -v
```

### 5.3 测试矩阵

| 测试文件 | 覆盖范围 | 耗时 |
|---------|---------|:----:|
| `abi_smoke_test.go` | 库加载、句柄创建/读写/释放 | < 1 s |
| `data_handle_test.go` | 标量 I/O、NUL 三态、exact-read、JSON、JsonOrBytes | < 1 s |
| `errors_test.go` | ErrorCode 分类、errors.Is/As/Unwrap、null-handle 检测 | < 1 s |
| `e2e_test.go` | 同进程 service+client、LocalCall、Notify、回调 panic 隔离、TryCall 空响应、Shutdown 幂等 | ~25 s |

**跳过逻辑**：若原生库不可用，所有测试会打印 `[SKIP]` 并**视为通过**，不报错。这样在没有原生库的 CI 环境里也能保持绿色。

### 5.4 E2E 测试的进程级副作用

`TestE2E_*` 会启动进程级的模拟主线程（`LF_PrepareDone`），因此：

- 每个 E2E 测试独立 setup/teardown，`Shutdown` 之后下一个测试可以再次 `PrepareDone`。
- **不要**在同一个测试进程里并发运行多个 E2E 测试（Go 的 `go test` 默认串行执行同一包内的测试，因此无需额外配置）。
- E2E 测试会在 stdout 打印原生层的日志（`Main Thread Begin, LingoFuse-v3.10 ...`），这是**正常输出**，不是测试失败。

---

## 六、快速开始

### 6.1 最小可运行示例

保存为 `main.go`：

```go
package main

import (
    "fmt"
    "log"

    "github.com/PassByYou888/LingoFuse/go/lingofuse"
)

type AddArgs struct {
    A int `json:"a"`
    B int `json:"b"`
}

type AddResult struct {
    Sum int `json:"sum"`
}

func main() {
    // 1. 创建应用并注册一个 Call API
    app, err := lingofuse.NewAppHandle("Calc", "Go calculator")
    if err != nil {
        log.Fatal(err)
    }
    defer app.Close()

    err = app.RegisterCall("add", "add two ints",
        func(input, output *lingofuse.DataHandle) {
            var args AddArgs
            if err := lingofuse.ReadJSON(input, &args); err != nil {
                return
            }
            _ = lingofuse.WriteJSON(output, AddResult{Sum: args.A + args.B})
        })
    if err != nil {
        log.Fatal(err)
    }

    // 2. 准备网络（自连接：同时做 service 和 client）
    _ = lingofuse.SetOption("Overlap_Connection", "True")
    _ = lingofuse.SetOption("Wait_Connection_ReadyOk", "False")
    _ = lingofuse.ResetPrepare()

    endpoint := "ipc:go_calc"
    if _, err := lingofuse.PrepareService(endpoint, endpoint); err != nil {
        log.Fatal(err)
    }
    if _, err := lingofuse.PrepareClient(endpoint, app); err != nil {
        log.Fatal(err)
    }
    started, err := lingofuse.PrepareDone()
    if err != nil || !started {
        log.Fatalf("PrepareDone: %v, %v", started, err)
    }

    // 3. 本地调用
    req, _ := lingofuse.NewDataHandle("add")
    defer req.Close()
    _ = lingofuse.WriteJSON(req, AddArgs{A: 5, B: 7})
    _ = req.SetPosition(0)

    res, err := app.LocalCall(req)
    if err != nil {
        log.Fatal(err)
    }
    defer res.Close()

    var out AddResult
    _ = lingofuse.ReadJSON(res, &out)
    fmt.Printf("5 + 7 = %d\n", out.Sum)

    // 4. 清理（严格按 LF-CLEAN-001 顺序）
    _ = lingofuse.ExitMainThread()
    app.Close()
    _ = lingofuse.Shutdown()
}
```

运行：

```powershell
go run main.go
```

输出：

```
5 + 7 = 12
```

### 6.2 远程调用

把服务端和客户端拆成两个进程：

**服务端**：把上面的 `app.LocalCall` 部分去掉，保留 `PrepareService` / `PrepareClient` / `PrepareDone`，然后阻塞等待 Enter。

**客户端**：不创建 `AppHandle`，`PrepareClient(endpoint, nil)` 传 nil，然后：

```go
req, _ := lingofuse.NewDataHandle("add")
defer req.Close()
_ = lingofuse.WriteJSON(req, AddArgs{A: 5, B: 7})
_ = req.SetPosition(0)

res, ok, err := lingofuse.TryCall("Calc", req, 3000)
if err != nil {
    log.Fatal(err)
}
if !ok {
    log.Fatal("timeout or app not found")
}
defer res.Close()

var out AddResult
_ = lingofuse.ReadJSON(res, &out)
fmt.Printf("5 + 7 = %d\n", out.Sum)
```

`TryCall` 返回 `(*DataHandle, bool, error)`：

- `(handle, true, nil)` — 成功
- `(nil, false, nil)` — 超时或目标不可达
- `(nil, false, err)` — 空句柄或加载失败

---

## 七、跨语言 Cross Demo

`cross/` 下的三个程序可以与 C++ / C# / Pascal / Python / JavaScript 的同名程序**混搭运行**。线格式逐字节一致：

### 7.1 API 线格式

**`add`**

```
input  : int32 LE + int32 LE
output : int32 LE
```

**`inv_seri`**

```
input  : uint8 + uint16 LE + uint32 LE + uint64 LE + string(NUL) + float32 LE
output : float32 LE + string(NUL) + uint64 LE + uint32 LE + uint16 LE + uint8
```

字符串是 UTF-8 编码、以 `0x00` 结尾。所有整数和浮点数都是小端序。

### 7.2 单语言运行（全部 Go）

先 `.\build.ps1`，然后开三个终端：

**终端 1 — 协调器**

```powershell
cd D:\CoreLibrary\LingoFuse\go\bin
.\cross-service.exe
```

等 `[Service] IPC service 'ipc:cross' is running.` 出现。

**终端 2 — 工作节点**

```powershell
cd D:\CoreLibrary\LingoFuse\go\bin
.\cross-node.exe
```

等 `[Node] Online.` 出现。

**终端 3 — 压测客户端**

```powershell
cd D:\CoreLibrary\LingoFuse\go\bin
.\cross-call.exe
```

10 秒后打印汇总。

### 7.3 跨语言运行

把上面三个终端里的任意一个替换成其它语言的实现即可，例如：

- **终端 2** 换成 `Binary\CrossNode.exe`（C++ 节点）
- **终端 3** 换成 `node ..\js\cross\cross-call.js`（JS 客户端）

无论怎么组合，`add` 和 `inv_seri` 都会成功往返。

### 7.4 关闭顺序

严格与启动相反：

1. 关 **客户端**（cross-call）
2. 关 **节点**（cross-node）
3. 关 **协调器**（cross-service）

每个程序退出时会自动按 `ExitMainThread → app.Close → Shutdown` 顺序清理。

---

## 八、API 速查

### 8.1 `lingofuse` 包

#### 构造 / 生命周期

| 函数 | 说明 |
|------|------|
| `NewDataHandle(apiName) (*DataHandle, error)` | 创建自动回收的句柄（10 分钟空闲回收） |
| `CreatePermanent(apiName) (*DataHandle, error)` | 创建永久句柄，不自动回收 |
| `(*DataHandle).Close()` | 释放句柄，幂等 |
| `NewAppHandle(name, desc) (*AppHandle, error)` | 创建应用 |
| `(*AppHandle).Close()` | 分离应用，幂等 |

#### `DataHandle` I/O

| 方法 | 说明 |
|------|------|
| `WriteBytes([]byte) / ReadBytes(n)` | 原始字节 |
| `ReadBytesExact(n) / TryReadBytes(n)` | 精确读取，失败返回错误 / false |
| `ReadAllBytes()` | 读到缓冲区末尾 |
| `WriteString(s) / ReadString()` | NUL-framed UTF-8 |
| `ReadStringBytes()` | NUL-framed 原始字节 |
| `WriteInt8/16/32/64 / WriteUint8/16/32/64` | 小端标量 |
| `WriteSingle/WriteDouble` | 小端浮点 |
| `Position() / SetPosition(pos)` | 读写游标 |
| `Size() / SetSize(n)` | 缓冲区大小 |

#### JSON I/O

| 函数 | 说明 |
|------|------|
| `WriteJSON(h, v) error` | 序列化 + 写入 + NUL 结尾 |
| `ReadJSON(h, &v) error` | 读到 NUL + 反序列化 |
| `TryReadJSON(h, &v) (bool, error)` | 非抛出版本 |
| `ReadJSONOrBytes(h) (JsonOrBytes, error)` | 宽容读取（Empty / JSON / Bytes 三态） |

#### `AppHandle`

| 方法 | 说明 |
|------|------|
| `RegisterCall(name, desc, handler) error` | 注册 Call API |
| `RegisterNotify(name, desc, handler) error` | 注册 Notify API |
| `Unregister(name) (bool, error)` | 注销 API |
| `LocalCall(param) (*DataHandle, error)` | 进程内调用 |
| `LocalNotify(param) error` | 进程内通知 |
| `Bind() (int, error)` | 绑定到空闲客户端 |
| `Name() / Raw() / IsValid()` | 状态查询 |

#### 进程级 Facade

| 函数 | 说明 |
|------|------|
| `ResetPrepare() error` | 清空准备队列 |
| `PrepareService(listen, physics) (int, error)` | 准备服务端点 |
| `PrepareClient(addr, app) (int, error)` | 准备客户端；`app` 可为 nil |
| `PrepareDone() (bool, error)` | 启动框架；每个进程只返回 true 一次 |
| `ExitMainThread() error` | 停止主线程；会清空句柄池 |
| `Call(appName, param, timeoutMs) (*DataHandle, error)` | 远程同步调用 |
| `TryCall(appName, param, timeoutMs) (*DataHandle, bool, error)` | 远程调用，超时返回 `(nil, false, nil)` |
| `Notify(appName, param) error` | 单向通知 |
| `SequencedNotify(appName, param) error` | FIFO 单向通知 |
| `SetOption(name, value) error` | 设置运行时选项 |
| `GenerateAppName() (string, error)` | 生成全局唯一应用名 |
| `GetAppName(app) (string, error)` | 查询应用名 |
| `Shutdown() error` | 完全关闭，幂等 |

#### 状态与健康检查

| 函数 | 说明 |
|------|------|
| `GetStatusCount() (int, error)` | 待处理日志条数 |
| `GetStatus() (string, error)` | 取一条日志 |
| `DrainStatus(n) ([]string, error)` | 批量取日志 |
| `PostStatus(msg) error` | 注入日志 |
| `CheckMainThread() (bool, error)` | 主线程是否运行 |
| `CheckApp(name) (bool, error)` | 应用是否可见（有 ~3 秒缓存延迟） |
| `CheckApi(app, api) (bool, error)` | API 是否可见（同上） |

#### 网络事件

| 函数 | 说明 |
|------|------|
| `SetNetworkEvent(onConnect, onDisconnect) error` | 安装全局回调；传 nil 表示禁用 |
| `ClearNetworkEvent() error` | 移除两个回调 |
| `IsNetworkEventInstalled() bool` | 是否有回调 |

#### 错误

```go
type Error struct {
    Code    ErrorCode
    Message string
    Cause   error
}
```

`ErrorCode` 常量：`ErrGeneric` / `ErrLibraryLoadFailed` / `ErrNullHandle` / `ErrInvalidArgument`
/ `ErrWriteFailed` / `ErrReadFailed` / `ErrCallFailed` / `ErrRegistrationFailed`
/ `ErrNotConnected` / `ErrTimeout`

用 `errors.Is(err, &lingofuse.Error{Code: lingofuse.ErrTimeout})` 按类别判断，或
`errors.As(err, &le)` 取回 `*lingofuse.Error` 结构体。

### 8.2 `sys` 包

`sys` 是低层 FFI 层，普通用户**不应**直接使用。它暴露：

- `sys.LoadLibrary() error` — 显式加载原生库
- 37 个函数变量（`LF_CreateData` / `LF_Call` / ...），全部是 C ABI 的镜像
- `sys.CStringScope` / `sys.GoString` — C 字符串辅助
- `sys.RegisterCallCallback` / `sys.RegisterNotifyCallback` — 回调注册

---

## 九、核心概念

### 9.1 三种调用模式

| 模式 | 语义 | 顺序保证 | 返回值 |
|------|------|:--------:|:------:|
| **Call** | 请求-响应，同步 | — | ✅ |
| **Notify** | 单向通知 | ❌ | ❌ |
| **Sequenced Notify** | 单向通知 | ✅（同一 `(app, api)` 对内 FIFO） | ❌ |

### 9.2 数据句柄的生命周期

```
NewDataHandle(api)        →  自动回收池，10 分钟空闲后回收（扫描间隔 5 秒）
CreatePermanent(api)      →  不进池，永不自动回收
Close()                   →  自动回收：只标记 deleted；永久：同步释放
```

**不要依赖自动回收**。自动回收是安全网，不是替代方案。生产中必须显式 `Close()`。

### 9.3 回调契约

回调在原生库的后台工作线程上执行。回调内**禁止**：

- ❌ 阻塞（`time.Sleep`、等待 channel、长时间 IO）
- ❌ 调用任何阻塞型 LingoFuse 函数（`Call` / `LocalCall` / `PrepareDone` / `Shutdown`）——会死锁
- ❌ 访问 UI（若绑定到 GUI）
- ❌ `Close()` 借用的句柄（input / output 由原生层管理）

回调内**可以**：

- ✅ 读 `input`、写 `output`
- ✅ 访问 `sync.Mutex` 保护的共享状态
- ✅ panic —— Go 包装会在 trampoline 中 recover，原生层看到的是"回调正常返回"，输出为空

### 9.4 清理顺序（LF-CLEAN-001）

```
ExitMainThread  →  app.Close  →  Shutdown
```

| 步骤 | 作用 |
|------|------|
| `ExitMainThread` | 停止模拟主线程；**会清空所有 DataHandle**（包括永久句柄） |
| `app.Close` | 解绑应用、停止顺序通知线程、释放回调槽位 |
| `Shutdown` | 释放原生全局池、卸载 IPC 库 |

三步都是幂等的。推荐用 `defer` 保证任何退出路径都执行。

### 9.5 NUL-framed 字符串三态

`ReadString()` / `ReadStringBytes()` / `ReadJSON()` 遵循同一套三态规则：

| 情况 | 行为 |
|------|------|
| 找到 NUL | 返回 NUL 之前的字节，游标推进到 NUL 之后 |
| 未找到 NUL | 返回剩余全部字节，游标推进到"缓冲区末尾 + 1" |
| 游标已在末尾 | 返回空字符串，游标不变 |

这与其他五种语言的绑定**完全一致**，因此 HTTP bridge、浏览器、手写客户端都能正确互通。

### 9.6 `PrepareDone` 的单次语义

`PrepareDone` 在同一个进程里**只返回 `true` 一次**。第二次调用会返回 `(false, nil)`——**这不是失败**，而是框架已经在运行。

如果需要重新初始化（例如测试）：

```go
_ = lingofuse.Shutdown()
_ = lingofuse.ResetPrepare()
// 重新 PrepareService / PrepareClient
started, _ := lingofuse.PrepareDone()  // 又会返回 true
```

---

## 十、六条铁律

违反任何一条都会导致崩溃、死锁或数据损坏。

1. **回调必须用原生签名**：`sys` 层的 `LfCallFunc` / `LfNotifyFunc` 是 `cdecl` 调用约定，Go 包装已经在 `purego.NewCallback` 中处理。用户只需使用 `lingofuse.CallHandler` / `NotifyHandler` 的 Go 签名。

2. **回调中禁止调用阻塞型 LingoFuse 函数**：`Call` / `LocalCall` / `PrepareDone` / `Shutdown` 都会导致自锁死锁。

3. **数据句柄必须显式 `Close()`**：自动回收是 10 分钟空闲 + 5 秒扫描延迟，不是替代方案。

4. **清理顺序固定**：`ExitMainThread → app.Close → Shutdown`。

5. **`PrepareDone` 每进程只成功一次**：第二次返回 `false` 不代表失败。要重启必须先 `Shutdown`。

6. **`LingoFuse64.dll` 必须在运行时可发现**：可执行文件目录 / `native/` 子目录 / 当前工作目录 / 系统加载器路径，四选一。

---

## 十一、故障排查

### 11.1 加载失败

```
lingofuse: failed to load the native library; tried:
  - D:\myproj\myapp.exe (as dir) \ LingoFuse64.dll
  ...
```

**原因**：DLL 不在任何搜索路径中。

**处理**：把 `LingoFuse64.dll` 拷贝到可执行文件所在目录。

### 11.2 符号缺失

```
lingofuse: native library is missing a required symbol: LF_CreateData_Permanent
```

**原因**：本地的 `LingoFuse64.dll` 版本过旧（低于 3.09）。`LF_CreateData_Permanent` 是 3.09 引入的。

**处理**：从主仓库 `Binary/` 目录取最新版本，或从源码重新编译。

### 11.3 调用超时

```
res, ok, err := lingofuse.TryCall("MyApp", req, 3000)
// ok == false, err == nil  →  超时或目标不可达
```

**原因**：

1. 目标 app 未注册：`CheckApp("MyApp")` 返回 false
2. 网络不通
3. 目标服务启动太慢

**处理**：

```go
for i := 0; i < 15; i++ {
    if ok, _ := lingofuse.CheckApp("MyApp"); ok {
        break
    }
    time.Sleep(200 * time.Millisecond)
}
```

或把 `Wait_Connection_ReadyOk` 设为 `"True"` 让 `PrepareDone` 阻塞等待。

### 11.4 回调没有输出

**原因**：可能回调未注册、注册失败、或回调 panic 被静默吞掉。

**处理**：

- `RegisterCall` 返回 error 时立即检查（通常是 API 名重复）
- 回调内**不要用裸 `panic`**，用 `fmt.Fprintf(os.Stderr, ...)` 打印诊断信息

### 11.5 IPC 队列已被占用

```
[IPC] Queue "ipc:cross0" is already occupied...
```

**原因**：上一次程序没有正常退出，IPC 队列残留。

**处理**：

- 关闭所有残留的进程
- 或换一个 endpoint 名（例如 `ipc:cross_v2`）

### 11.6 `go mod tidy` 超时

**原因**：`proxy.golang.org` 被墙。

**处理**：见 §3.2，配置 `GOPROXY` 到国内镜像。

---

## 十二、与其它语言绑定的差异

| 维度 | Pascal | C++ | C# | Rust | **Go** |
|------|:------:|:---:|:--:|:----:|:------:|
| FFI 方式 | 静态链接 | 动态加载（手写） | P/Invoke | libloading | **purego** |
| 需要 C 编译器 | ❌ | ✅ | ❌ | ❌ | ❌ |
| 错误处理 | 异常 / 返回值 | `std::exception` | `Exception` | `Result<T, E>` | **`(T, error)`** |
| 资源释放 | `Free_Data` | RAII | `IDisposable` | `Drop` | **显式 `Close()` + `defer`** |
| 回调机制 | 函数指针 | `std::function` | `Delegate` | `Box<dyn Fn>` | **`sync.Map` + trigger ID** |
| 回调 panic 隔离 | 库内 `try/except` | 用户 `try/catch` | 自动隔离 | 用户 `catch_unwind` | **包装自动 recover** |
| 数据句柄类型 | `PLF_Data` record | `lingofuse::DataHandle` 类 | `DataHandle` 类 | `DataHandle` 结构体 | **`*DataHandle` 指针** |
| 标量 I/O | `LF_WriteInt32` 等 | `write<int32_t>` | `WriteInt32` | `write(42i32)` | **`WriteInt32(42)`** |

**Go 独有的设计**：

- **错误返回而非异常**：Go 没有异常机制，全部通过 `(value, error)` 返回。`TryCall` / `TryReadBytes` / `TryReadString` 提供"无错误"版本，返回 `(value, bool, error)` 三态。
- **回调通过 `trigger` ID 映射**：`LF_RegisterCall` 接收的 `trigger` 指针被复用为一个自增 ID，回调触发时通过 `sys` 包的 `sync.Map` 找回 Go 函数。这避免了把 Go 闭包指针暴露给 C 层的复杂性和安全风险。
- **借用句柄 `Close()` 是 no-op**：`app.LocalCall` / 回调内的 `input`/`output` 是借用句柄，`Close()` 会检测到 `owned == false` 并直接返回，防止二次释放。
- **无 `runtime.SetFinalizer` 依赖**：所有资源必须显式释放。这是 Go 社区的标准做法，避免 Finalizer 执行时机不确定的问题。

---

## 参考

- **主仓库**：https://github.com/PassByYou888/LingoFuse
- **C++ 知识库**：`cpp/LingoFuse_Cpp_Knowledge_Base.md`
- **Rust 用户指南**：`rust/RUST_USER_GUIDE.md`
- **Pascal 完整指南**：`pascal/LingoFuse_Pascal_Complete_Guide.md`
- **C# 完整指南**：`csharp/LingoFuse_CSharp_Complete_Guide.md`
- **跨语言 Demo 说明**：`go/cross/README.md`

---

## 许可

与主仓库一致，详见 `LICENSE`。
