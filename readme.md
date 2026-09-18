# LingoFuse

> **智能体时代的神经网络通讯地基 —— 让所有编程语言平等对话。**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**LingoFuse** 是一个跨语言、跨进程、跨机器的 RPC 框架。  
不写 IDL，不生成桩代码，不搭 HTTP 服务——任何语言写的函数，任何其他语言都能直接调。

---

## 🚀 相比其它 RPC 库的优势

| 特性 | LingoFuse | gRPC | REST |
|------|-----------|------|------|
| 同机延迟 | **< 1 ms** | ~5-8 ms | ~10-20 ms |
| 吞吐量 | **12k+/s** | ~3k/s | ~1k/s |
| 服务发现 | ✅ 内置 | ❌ 需 etcd | ❌ 需 Nginx |
| 负载均衡 | ✅ 内置 | ❌ 需 LB | ❌ 需 Nginx |
| 顺序保证 | ✅ FIFO | ❌ | ❌ |
| 断线重连 | ✅ 自动 | ❌ 需重试 | ❌ 需重试 |
| 零拷贝 | ✅ | ❌ | ❌ |
| 跨语言 | **30+ 种** | 需生成代码 | 需手动封装 |

**一句话**：比 gRPC 快 5-8 倍，比 REST 快 10-20 倍，自带全套中间件。

---

## 🌍 多语言支持（平等列举）

| 语言 | 状态 | 说明 |
|------|------|------|
| **Pascal** | 🟢 生产就绪 | 原生 FFI，完整绑定 |
| **Python** | 🟢 生产就绪 | `pip install -e .` 即用 |
| **C++** | 🟢 生产就绪 | 原生 C ABI，零开销 |
| **Node.js / PHP / 浏览器** | 🌉 HTTP 桥接 | `bridge.py` 网关 |
| **Rust / Go / Java / C# 等** | ⏳ 计划中 | 欢迎贡献绑定 |
| **aarch64 / loongarch64 / RISC-V** | 📱 边缘设备计划 | 持续移植中 |

> 🎯 **目标：让地球上 30+ 种编程语言，用同一个函数调用约定互相说话。**

---

## 🤖 智能体神经网络通讯地基

LingoFuse 不只是 RPC，它是 **AI Agent 调用任意语言函数的底座**。

- **信标**：工具注册中心，AI 自动发现可用工具
- **Call + Notify**：请求-响应 + 流式推送
- **跨语言 FFI**：无论工具用什么语言，AI 无需感知
- **确定性序列化**：工具参数可复现、可审计

基于 LingoFuse，社区构建了多个智能体分支：

- [pasAgent v2](https://github.com/PassByYou888/LingoFuse-pasAgent)（Pascal 纯文本智能体）
- [pasAgent v3](https://github.com/PassByYou888/LingoFuse-pasAgent-v3)（Pascal 多模态智能体）
- [cppAgent](https://github.com/PassByYou888/LingoFuse-cppAgent)（C++ 智能体，即将上传）

未来会有更多语言的智能体分支——**主仓库专注通讯底座，分支专注各自生态。**

---

## 📦 克隆必读

**本仓库有子模块，必须加 `--recursive`：**

```bash
git clone --recursive https://github.com/PassByYou888/LingoFuse.git
```

忘了加？补救：

```bash
git submodule update --init --recursive
```

不加会编译失败（`Can't find unit Z.Core` 等）。

---

## 📚 依赖库

核心动态库位于 `Binary/` 目录：

| 平台 | 核心库 | IPC 依赖 | 内存分配器 |
|------|--------|----------|------------|
| Windows 64 | `LingoFuse64.dll` | `z_ipc_64.dll` | `mimalloc64.dll` |
| Windows 32 | `LingoFuse32.dll` | `z_ipc_32.dll` | `mimalloc32.dll` |
| Linux | `liblingofuse.so` | `libz_ipc.so` | `libmimalloc.so`（可选） |
| macOS | `liblingofuse.dylib` | `libz_ipc.dylib` | `libmimalloc.dylib`（可选） |

**部署方式**：将 `Binary/` 目录加入系统 `PATH`，或把动态库复制到可执行文件同目录。

Windows 下还需安装 **VC++ Redistributable**（`vc_redist.x64.exe` / `vc_redist.x86.exe`）。

---

## 📄 许可证

**MIT** —— 拿去用，拿去改，拿去卖，都不用来谢我。

---

## 🧓 关于作者

**老张（QQ: 600585）**

看不惯跨语言调用得写一箩筐胶水代码，干脆撸了 LingoFuse。  
欢迎来撩、来喷、来 PR——**Star 是最好的催更。**

---

*项目始于 2026 年，持续进化中。有问题提 Issue，急事加 Q。*  
*“让所有编程语言平等对话” —— 不是口号，是正在发生的事。*