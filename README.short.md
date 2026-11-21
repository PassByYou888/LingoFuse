# LingoFuse

**跨语言 RPC 地基 —— 不写 IDL、不生成桩代码、不搭 HTTP 服务。**
任意语言写的函数，任意其他语言直接调；同机可调，跨机也可调。MIT。

```cpp
// C++
int Add(int a, int b);
```

```python
# Python —— 调同一个函数，没有 .proto，没有生成的桩代码
print(LF_Call("math", "Add", 1, 2))   # => 3
```

## 你得到什么

- **18 种语言一等公民绑定**——Pascal、C++、Rust、Go、Java、Python、C#、TypeScript、JavaScript、Swift、Zig、Erlang、Ruby、Fortran、Julia、R、Dart、PHP，共用一套 C ABI、一种线格式、一套句柄所有权模型。
- **两种传输，一套 API**——同机共享内存 IPC；跨机 TCP 网格，内置服务发现、负载均衡、FIFO 与断线重连。
- **零 IDL**——按普通函数声明，其他语言按名字直接调。没有 `.proto`，没有桩代码，不用为每对语言写网关。
- **生成器**——覆盖 17 种原生 FFI 语言、20+ 种 JSON-ABI 语言，以及声明转 MCP。

## 60 秒跑起来（Windows，无需编译）

1. 从 [Releases · pre_build](https://github.com/PassByYou888/LingoFuse/releases/tag/pre_build) 下载 `LingoFuse64.dll` 与生成器工具
2. 加入 `PATH`
3. 跑 [test/](test/) 里的预编译测试，拿到你自己硬件的真实数据

Linux / macOS：从源码构建 —— [src/CONTRIBUTING.md](src/CONTRIBUTING.md)。**尚未验证**，CI 在计划中。

## 采用前必读

这是前沿基础设施，不是开箱即用。它解决最难的部分，把复杂的部分留给你：

- 回调跑在工作线程上 —— 绝不要在回调里调用阻塞的 LF 函数
- 不做业务层封装、不做跨平台工具链适配、没有支持 SLA（单人维护）
- 预编译目前只有 Windows

## 往下读

| | |
|---|---|
| 完整 README | [readme.md](readme.md) |
| 机制知识库（v4.0） | [Z.LingoFuse.md](Z.LingoFuse.md) |
| 内核与应用短文（17 篇） | [doc/](doc/) |
| P2P 分布式负载概念 | [LingoFuse_P2P_Distributed_Load_Concept.md](LingoFuse_P2P_Distributed_Load_Concept.md) |
| 测试与验证 | [test/](test/) |
| LLM 入口 | [llms.txt](llms.txt) |
| 为什么不易被复刻 | [LF-Architecture-Unreplicable-Backend-Systems.md](LF-Architecture-Unreplicable-Backend-Systems.md) |
