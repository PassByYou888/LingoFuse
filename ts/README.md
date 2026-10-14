# LingoFuse TypeScript 绑定

LingoFuse 分布式 RPC 框架的 TypeScript 绑定。通过 [Koffi](https://koffi.dev/)
调用 LingoFuse 原生库的 C ABI，支持 **Node.js 18+**、**Deno 2.x**、
**Bun 1.x+** 三种运行时。

本绑定与 C++、C#、Pascal、JavaScript、Python 各版本**字节级互通**：

- 相同的 **59 个**导出 C 函数。
- 相同的 NUL 结尾 UTF-8 线格式。
- 相同的 JSON 序列化策略（紧凑、字面 UTF-8、无 `\uXXXX` 转义）。
- 相同的字符串三态容错读取。
- 相同的 **三种寻址模式**（App 名 / UID / P2PName）。
- 相同的 **三种调用风格**（Promise / 回调 / 同步）。
- 相同的 **Handle 所有权模型**（同步族 / 异步族）。
- 相同的 **P2P 身份侧数据语义**（`getP2PUid` / `getP2PName`）。
- 相同的清理顺序（LF-CLEAN-001）。

在一个绑定上能工作的逻辑，在其他绑定上也一样。

---

## v2.0 相比 v1.0 的变化

v1.0 是一个 C ABI 直译层：59 个导出函数中只覆盖了 36 个，只提供
App 名寻址和同步调用。

v2.0 补齐了完整能力，并在其上构建了**面向业务的抽象层**：

| 维度 | v1.0 | v2.0 |
|------|:----:|:----:|
| C ABI 覆盖 | 36 / 59 | **59 / 59** |
| 调用风格 | 同步 | 同步 + 回调 + **Promise（async/await）** |
| 寻址模式 | App 名 | App 名 / **UID** / **P2PName** |
| 运行时选项 | 通用 `setOption` | 通用 + **16 对 typed 快捷** |
| P2P 身份读取 | 无 | `DataHandle.getP2PUid` / `getP2PName` |
| P2P 全局注册 | 无 | `registerP2PCall` / `registerP2PNotify` |
| 异步子系统 | 无 | `AsyncBridge` / `CallPromise` / `AsyncOp` |
| 异常层级 | 6 类 | **8 类** |
| 测试套件 | 127 项 | 127 + **99 项** |

**没有破坏性变更**。v1.0 的所有代码在 v2.0 上原样运行。

---

## 目录

1. [项目结构](#1-项目结构)
2. [环境要求](#2-环境要求)
3. [依赖包](#3-依赖包)
4. [安装与构建](#4-安装与构建)
5. [原生动态库放置](#5-原生动态库放置)
6. [运行方式](#6-运行方式)
7. [快速上手](#7-快速上手)
   - [7.1 最小服务端](#71-最小服务端)
   - [7.2 最小客户端](#72-最小客户端)
   - [7.3 三种调用风格](#73-三种调用风格)
   - [7.4 三种寻址模式](#74-三种寻址模式)
8. [运行时选项](#8-运行时选项)
9. [P2P 身份读取](#9-p2p-身份读取)
10. [进程级 P2P 注册](#10-进程级-p2p-注册)
11. [异步子系统](#11-异步子系统)
12. [测试方法](#12-测试方法)
13. [故障排查](#13-故障排查)
14. [API 速查](#14-api-速查)

---

## 1. 项目结构

```
ts/
├── package.json              项目清单
├── tsconfig.json             开发配置（类型检查）
├── tsconfig.build.json       构建配置（生成 dist/）
├── README.md                 本文档
├── .vscode/
│   ├── launch.json           调试配置
│   └── settings.json         VS Code 工作区设置
├── src/                      源代码（编译输入）
│   ├── index.ts              公开入口，re-exports
│   ├── errors.ts             异常层级 + ErrorCode（8 类）
│   ├── types.ts              纯类型声明（无运行时代码）
│   ├── runtime.ts            Node / Deno / Bun 运行时探测
│   ├── options.ts            运行时选项常量 + 16 对 typed 快捷
│   ├── binding.ts            Koffi 声明 + 库加载 + 59 个函数
│   ├── library-loader.ts     RAII 加载器
│   ├── data-handle.ts        TDataHnd 的 RAII 封装（含 P2P 身份读取）
│   ├── app-handle.ts         TAppHnd 的 RAII 封装
│   ├── lf-io.ts              JSON / 字符串 / 字节 I/O
│   ├── framework.ts          进程级 ABI 门面（低层）
│   ├── network-events.ts     连接 / 断开事件
│   ├── status.ts             状态队列与健康检查（含 UID / P2PName 检查）
│   ├── address.ts            三寻址 Target 抽象（v2.0 新增）
│   ├── async-support.ts      异步子系统（v2.0 新增）
│   └── p2p-registration.ts   进程级 P2P 注册（v2.0 新增）
├── examples/
│   └── hello-world.ts        端到端演示（不参与编译）
├── cross/
│   ├── cross-service.ts      跨语言协调器
│   ├── cross-node.ts         跨语言工作节点
│   └── cross-call.ts         跨语言负载测试
├── test/
│   ├── test.ts               v1.0 基线测试套件（127 项）
│   └── test-v2.ts            v2.0 测试套件（99 项）
└── dist/                     编译输出（构建后生成）
```

`src/` 下的每个模块都是独立可导入的。`index.ts` 是公开入口，
其余模块通过命名空间或具名导出暴露。

**分层架构**（自上而下）：

```
L6  入口聚合层     index.ts
L5  业务抽象层     address.ts / async-support.ts / options.ts / p2p-registration.ts
L4  进程级门面层   framework.ts / status.ts / network-events.ts
L3  RAII 句柄层    data-handle.ts / app-handle.ts / lf-io.ts
L2  类型 & 异常层  types.ts / errors.ts / runtime.ts
L1  原生声明层     binding.ts  (59 / 59)
```

依赖方向严格单向向下，任何上层不得被下层 import。

---

## 2. 环境要求

### 2.1 版本矩阵

| 组件 | 最低版本 | 推荐 | 备注 |
|------|:--------:|:----:|------|
| **Node.js** | 18 | 20 LTS 或 22 | 运行时之一 |
| **Deno** | 2.0 | 2.x 最新 | 运行时之一（可选） |
| **Bun** | 1.0 | 1.x 最新 | 运行时之一（可选） |
| **TypeScript** | 5.0 | 5.6.x | 仅编译期需要 |
| **Koffi** | 3.3.2 | 3.3.2+ | FFI 依赖，自动安装 |
| **@types/node** | 20 | 22.x | 仅类型声明，devDependency |
| **tsx**（可选） | 4.0 | 4.x 最新 | 直接运行 .ts 文件 |

**三选一即可**：装 Node.js、Deno、Bun 中的任意一个都能运行本绑定。
若需要跨运行时验证，可以全部安装。

### 2.2 操作系统

| 平台 | 支持的架构 | 备注 |
|------|-----------|------|
| Windows | x64 / x86 | 需要 `LingoFuse64.dll` 或 `LingoFuse32.dll` |
| Linux | x64 / arm64 | 需要 `liblingofuse.so` |
| macOS | x64 / arm64 | 需要 `liblingofuse.dylib` |
| FreeBSD / OpenBSD | x64 | 需要 `liblingofuse.so`（Koffi 官方预编译） |

Koffi 为上述所有平台提供**预编译的原生二进制**，安装时**不需要 C++
工具链**。

### 2.3 Windows 环境准备

**安装 Node.js**

1. 从 <https://nodejs.org/en/download/> 下载 Node.js 18 或更新版本的
   MSI 安装包。
2. 运行 MSI，全程默认选项即可。
3. 在**新的** PowerShell 窗口中验证：

   ```powershell
   node --version
   npm --version
   ```

   预期输出 `v20.x.x` 或更高，以及 `10.x.x` 或更高。

**（可选）安装 Deno**

```powershell
irm https://deno.land/install.ps1 | iex
```

**（可选）安装 Bun**

```powershell
powershell -c "irm bun.sh/install.ps1 | iex"
```

### 2.4 Linux 环境准备

**安装 Node.js**

推荐使用 nvm（与发行版无关）：

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc      # 或 ~/.zshrc
nvm install 20
nvm use 20
```

或使用发行版包管理器（Debian / Ubuntu）：

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

验证：

```bash
node --version
npm --version
```

**（可选）安装 Deno**

```bash
curl -fsSL https://deno.land/install.sh | sh
```

**（可选）安装 Bun**

```bash
curl -fsSL https://bun.sh/install | bash
```

### 2.5 macOS 环境准备

**安装 Node.js**

```bash
brew install node@20
```

或使用 nvm（与 Linux 相同）。

**（可选）安装 Deno / Bun**

```bash
brew install deno
brew install oven-sh/bun/bun
```

---

## 3. 依赖包

### 3.1 运行时依赖

| 包 | 版本 | 用途 |
|----|------|------|
| `koffi` | `^3.3.2` | FFI 层：加载动态库、声明 C 函数、桥接回调 |

Koffi 是**唯一**的运行时依赖。它包含所有支持平台的预编译二进制，
通过 `optionalDependencies` 机制自动选择当前平台对应的包：

| 平台 | 自动安装的包 |
|------|-------------|
| Windows x64 | `@koromix/koffi-win32-x64` |
| Windows x86 | `@koromix/koffi-win32-ia32` |
| Linux x64 | `@koromix/koffi-linux-x64` |
| Linux arm64 | `@koromix/koffi-linux-arm64` |
| macOS x64 | `@koromix/koffi-darwin-x64` |
| macOS arm64 | `@koromix/koffi-darwin-arm64` |

### 3.2 开发依赖

| 包 | 版本 | 用途 |
|----|------|------|
| `typescript` | `^5.6.0` | 编译 `.ts` → `.js` |
| `@types/node` | `^22.0.0` | Node.js 全局类型（`process` / `TextEncoder` / `__dirname`） |
| `tsx`（可选） | `^4.0.0` | 直接运行 `.ts` 文件（不经过编译） |

`@types/node` 是**必需**的，因为 `binding.ts` 里用到了 `node:path` /
`node:fs`，`app-handle.ts` 里用到了 `process.stderr`，`test-v2.ts`
里用到了 `node:child_process`。

---

## 4. 安装与构建

### 4.1 安装依赖

在 `ts/` 目录下：

```bash
cd ts
npm install
```

`npm install` 会：

1. 读取 `package.json`。
2. 从 npm registry 下载 `koffi`、`typescript`、`@types/node`、`tsx`。
3. 把当前平台对应的 Koffi 原生二进制解包到 `node_modules/@koromix/`。
4. 无需任何构建工具。

**如果安装失败**：

```bash
# 清空缓存后重试
npm cache clean --force
rm -rf node_modules package-lock.json   # Windows: Remove-Item -Recurse -Force
npm install

# 或在企业代理下
npm install --registry=https://registry.npmmirror.com
```

### 4.2 编译

```bash
npm run build
```

**输出**：`dist/` 目录，包含：

- 每个 `src/*.ts` 对应的 `.js` 文件
- 每个 `.js` 对应的 `.d.ts`（类型声明）
- 每个 `.js` 对应的 `.js.map`（source map）
- 每个 `.d.ts` 对应的 `.d.ts.map`（声明跳转）

**仅类型检查**（不产生输出）：

```bash
npm run check
```

### 4.3 编译配置

本项目使用**双 tsconfig** 结构：

| 文件 | 用途 | `include` | `noEmit` |
|------|------|-----------|:--------:|
| `tsconfig.json` | 开发 / 类型检查 | `src` / `test` / `examples` / `cross` | `true` |
| `tsconfig.build.json` | 生产构建 | 仅 `src` | `false` |

`tsconfig.build.json` 通过 `extends` 继承 `tsconfig.json` 的编译器选项，
仅覆写 `noEmit` / `declaration` / `outDir` 等构建相关字段。

**关键设置**：

| 选项 | 值 | 含义 |
|------|-----|------|
| `target` | `ES2022` | 输出语法版本（Node 18+ / Bun / Deno 都支持） |
| `module` | `commonjs` | 输出 `require()` / `module.exports` |
| `moduleResolution` | `node10` | 传统的 node_modules 解析 |
| `ignoreDeprecations` | `"6.0"` | 屏蔽 TS 6.0 的 `node10` 弃用警告 |
| `strict` | `true` | 全套严格检查 |
| `declaration` | `true` | 生成 `.d.ts` |

**关于 `ignoreDeprecations: "6.0"`**：

TypeScript 6.0 起将 `moduleResolution: "node10"` 标记为弃用。该项目
显式声明 `"ignoreDeprecations": "6.0"` 以屏蔽警告，同时保持输出为
CommonJS。选择保留 `node10` 而非迁移到 `bundler` / `nodenext` 的
理由是：**已发布的 `dist/` 输出是 CommonJS**，改变模块系统会破坏
现有消费者。TS 7.0 正式移除 `node10` 支持时，本项目再统一迁移。

**为什么输出 CommonJS**：CJS 格式对 Node.js、Bun、Deno 兼容性最广。
`package.json` 里 `"type": "commonjs"` 与之对应。

---

## 5. 原生动态库放置

**本绑定不包含** LingoFuse 原生共享库。该库需要单独从 Pascal / C++
源码构建。

### 5.1 期望的文件名

| 平台 | 文件名 |
|------|--------|
| Windows 64 位 | `LingoFuse64.dll` |
| Windows 32 位 | `LingoFuse32.dll` |
| Linux / BSD | `liblingofuse.so` |
| macOS | `liblingofuse.dylib` |

### 5.2 搜索顺序

`binding.ts` 的 `buildSearchPaths()` 按以下顺序尝试：

1. **当前可执行文件所在目录**（`process.execPath` 的父目录）
2. **当前工作目录**（`process.cwd()`）
3. **包同级的 `native/` 子目录**（`__dirname/../native/`）
4. **操作系统加载器搜索路径**（作为最后的兜底）：
   - Windows：`PATH` 环境变量
   - Linux：`LD_LIBRARY_PATH` 和 `/etc/ld.so.conf`
   - macOS：`DYLD_LIBRARY_PATH` 和 `/usr/local/lib`

以上任一位置都有效。**最简单的做法**是把动态库复制到与你的脚本相同的
目录，或加入系统加载器路径。

### 5.3 放置示例

**Windows**：

```powershell
# 方案 A：放到运行脚本的目录
Copy-Item D:\LingoFuse\Binary\LingoFuse64.dll C:\MyApp\

# 方案 B：加入 PATH（仅在当前 PowerShell 会话有效）
$env:PATH += ";D:\LingoFuse\Binary"

# 方案 C：永久加入 PATH
[Environment]::SetEnvironmentVariable(
    "PATH",
    $env:PATH + ";D:\LingoFuse\Binary",
    "User")
```

**Linux**：

```bash
# 方案 A：放到运行脚本的目录
cp /opt/lingofuse/lib/liblingofuse.so /home/user/myapp/

# 方案 B：加入 LD_LIBRARY_PATH
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/opt/lingofuse/lib"

# 方案 C：安装到系统目录（需要 root）
sudo cp /opt/lingofuse/lib/liblingofuse.so /usr/local/lib/
sudo ldconfig
```

**macOS**：

```bash
# 方案 A：放到运行脚本的目录
cp /opt/lingofuse/lib/liblingofuse.dylib ~/myapp/

# 方案 B：加入 DYLD_LIBRARY_PATH
export DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH:/opt/lingofuse/lib"

# 方案 C：安装到系统目录
sudo cp /opt/lingofuse/lib/liblingofuse.dylib /usr/local/lib/
```

---

## 6. 运行方式

TypeScript 有四种执行路径，按使用场景选择。

### 6.1 方式一：`tsx` 直接运行 `.ts`（推荐用于开发）

`tsx` 是一个零配置的 TypeScript 执行器，即时编译并运行。**不需要预先
编译到 `dist/`**。

**安装**：

```bash
npm install -D tsx
```

**运行示例**：

```bash
npx tsx examples/hello-world.ts
```

或在 `package.json` 里加一条脚本：

```json
"scripts": {
  "demo": "tsx examples/hello-world.ts"
}
```

然后：

```bash
npm run demo
```

**优点**：

- 支持 `.ts` 路径导入（`import * as lf from "../src/index"` 直接解析到 `.ts` 源文件）
- 同时支持 ESM 和 CJS 语法
- 行业标准（Vite / Vitest / Next.js 内部都在用）

### 6.2 方式二：Bun 直接运行 `.ts`

Bun 内置 TypeScript 支持，**不需要任何预处理**。

```bash
bun run examples/hello-world.ts
```

运行你的服务脚本：

```bash
bun run my-service.ts
```

**优点**：

- 零配置，零依赖
- 启动速度最快（比 Node.js 快 3-5 倍）

### 6.3 方式三：Deno 直接运行 `.ts`

Deno 内置 TypeScript 支持，**但需要显式权限标志**。

```bash
deno run \
    --allow-ffi \
    --allow-read \
    --allow-env \
    --allow-net \
    --allow-sys \
    examples/hello-world.ts
```

**每个权限标志的理由**：

| 标志 | 必要性 | 用途 |
|------|:------:|------|
| `--allow-ffi` | **必需** | 加载 Koffi 原生库 |
| `--allow-read` | **必需** | Koffi 读取环境与库文件路径 |
| `--allow-env` | **必需** | Koffi 读取环境变量 |
| `--allow-net` | **必需** | LingoFuse 的网络 I/O |
| `--allow-sys` | 推荐 | 进程与系统信息探测 |
| `--allow-run` | 测试套件需要 | v2.0 测试套件启动 watchdog 子进程 |

**给脚本加 shebang**（可选）：

```typescript
#!/usr/bin/env -S deno run --allow-ffi --allow-read --allow-env --allow-net --allow-sys
```

然后：

```bash
deno run my-service.ts
```

### 6.4 方式四：编译后运行（用于生产部署）

先编译到 `dist/`，再运行输出的 JavaScript：

```bash
npm run build
node dist/index.js          # 或 dist/你写的入口文件.js
```

或从你自己的项目引用编译后的包：

```typescript
import * as lf from "lingofuse-ts";
```

**优点**：

- 启动时不需要 TypeScript 编译器（更少的运行时开销）
- 可以打包到 Docker 镜像里
- 与其他 JavaScript 项目使用方式一致

**注意**：`examples/` 目录**不参与编译**（`tsconfig.build.json` 的
`include` 只有 `src/**/*.ts`）。示例脚本由 `tsx` / `bun` / `deno`
直接运行。

---

## 7. 快速上手

本节演示 v2.0 的**三种调用风格**与**三种寻址模式**。所有示例假设
你已经完成 [§4](#4-安装与构建) 的安装步骤，并且按 [§5](#5-原生动态库放置)
放好了原生动态库。

### 7.1 最小服务端

```typescript
import * as lf from "lingofuse-ts";

lf.loadLibrary();

// 1. 创建应用
const app = new lf.AppHandle("Calculator", "Add two integers");

// 2. 注册 Call API（回调直接写业务代码）
app.registerCall<{ a: number; b: number }, { result: number }>(
    "add",
    "Add two integers",
    (input, output) => {
        const req = lf.io.readJson<{ a: number; b: number }>(input) ?? { a: 0, b: 0 };
        lf.io.writeJson(output, { result: req.a + req.b });
    });

// 3. 准备网络
lf.options.setOptWaitConnectionReadyOk(false);
lf.framework.resetPrepare();
lf.framework.prepareService("ipc:calc", "ipc:calc");
lf.framework.prepareClient("ipc:calc", app);

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

// 4. 等待应用在 mesh 上可见（Wait_Ready=False 时必需）
while (!lf.status.checkApp("Calculator")) {
    await new Promise((r) => setTimeout(r, 100));
}

console.log("Server ready");

// 5. 清理（进程退出时）
lf.framework.exitMainThread();
app.dispose();
lf.framework.shutdown();
```

### 7.2 最小客户端

```typescript
import * as lf from "lingofuse-ts";

lf.loadLibrary();

lf.options.setOptWaitConnectionReadyOk(false);
lf.framework.resetPrepare();
lf.framework.prepareClient("ipc:calc", null);   // 纯消费者，无 App

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

while (!lf.status.checkApp("Calculator")) {
    await new Promise((r) => setTimeout(r, 100));
}

// ---- 现代调用（v2.0 推荐）----
const target = new lf.AppTarget("Calculator");
const result = await target.call<{ a: number; b: number }, { result: number }>(
    "add", { a: 5, b: 7 });
console.log("5 + 7 =", result.result);   // 12

// ---- 清理 ----
lf.framework.exitMainThread();
lf.framework.shutdown();
```

### 7.3 三种调用风格

三种风格共享同一底层 `AsyncBridge` 子系统，可以自由混用。

| 风格 | 入口 | 阻塞？ | 适合 |
|------|------|:------:|------|
| **A. Promise** | `await target.call("api", payload)` | 否（挂起） | 现代 async 业务代码 |
| **B. 内联回调** | `target.callAsync("api", payload, cb)` | 否 | 事件驱动、业务代码写在回调里 |
| **C. 同步** | `target.callSync("api", payload)` | 是 | 脚本、测试、CLI 工具 |

#### 风格 A —— Promise（推荐用于现代业务代码）

```typescript
const target = new lf.AppTarget("Calculator");

try {
    const result = await target.call<{ a: number; b: number }, { result: number }>(
        "add", { a: 5, b: 7 }, { timeoutMs: 3000 });
    console.log("result:", result.result);   // 12
} catch (err) {
    if (err instanceof lf.LingoFuseTimeoutError) {
        console.error("timed out after", err.timeoutMs, "ms");
    } else if (err instanceof lf.LingoFuseCallError) {
        console.error("call failed:", err.targetApp, err.message);
    } else {
        throw err;
    }
}
```

**取消语义**：`CallPromise` **不是**标准 `Promise`，它带有一个额外的
`abandoned` 标记。当 JS 侧的超时先于 native 回调到达时：

- `CallPromise` 以 `LingoFuseTimeoutError` reject
- `abandoned` 变为 `true`
- **native 请求不会被取消**：`AsyncBridge` 会保留回调一个 grace
  周期（默认 60 秒），任何迟到的结果都被丢弃

#### 风格 B —— 内联回调（业务代码直接写在回调里）

```typescript
const target = new lf.AppTarget("Calculator");

target.callAsync<{ a: number; b: number }, { result: number }>(
    "add",
    { a: 5, b: 7 },
    (res, err, userData) => {
        // 业务代码直接写在这里，无 await、无 Promise 包装
        if (err) {
            console.error("call failed:", err.message);
            return;
        }
        console.log("5 + 7 =", res!.result);   // 12
    });
```

回调签名：`(result, error, userData) => void`。

| 参数 | 含义 |
|------|------|
| `result` | 反序列化后的 JSON 值；失败时为 `null` |
| `error` | `LingoFuseError` / `LingoFuseTimeoutError` 实例；成功时为 `null` |
| `userData` | 调用时传入的第 4 个参数（可选） |

**要点**：

- 回调**运行在 JS 事件循环**上（由 Koffi 桥接从 native 工作线程
  序列化过来）。**不要阻塞它**。
- 回调内**不要**调用任何同步的 LingoFuse 函数（如 `callSync`）—— 会死锁。
- 回调体抛出的异常会被吞掉并写入 stderr；不会传回 native 栈。

#### 风格 C —— 同步

```typescript
const target = new lf.AppTarget("Calculator");

const result = target.callSync<{ a: number; b: number }, { result: number }>(
    "add", { a: 5, b: 7 }, { timeoutMs: 3000 });
console.log("result:", result.result);   // 12
```

还有非抛异常版本：

```typescript
const result = target.tryCallSync<{ a: number; b: number }, { result: number }>(
    "add", { a: 5, b: 7 }, { timeoutMs: 3000 });
if (result === null) {
    console.log("call failed");
} else {
    console.log("result:", result.result);
}
```

**警告**：`callSync` 会**阻塞 JS 事件循环**直到 native 调用返回。
仅用于脚本、测试、CLI 工具。不要在服务器热路径里使用。

### 7.4 三种寻址模式

三种寻址模式共享同一个调用接口（`call` / `callAsync` / `callSync` /
`tryCallSync` / `sequencedCall` / `sequencedCallAsync` / `notify` /
`sequencedNotify`），只在**路由语义**上不同。

| Target 类型 | 路由键 | 本地优先？ | 负载均衡？ | 典型用途 |
|-------------|--------|:---------:|:---------:|---------|
| `AppTarget` | App 名（string） | ✅ | ❌ | 固定服务 |
| `UIDTarget` | UID（32 字节） | ✅ | ❌ | **定向到具体客户端** |
| `P2PNameTarget` | 组名（string） | ❌ | ✅ | 同质服务集群 |

#### 7.4.1 `AppTarget` —— 按应用名寻址

最常用的方式。路由到**任意**具有匹配名字的客户端。

```typescript
const target = new lf.AppTarget("Calculator");
const result = await target.call("add", { a: 1, b: 2 });
```

**本地优先**：如果调用者进程本身注册了同名 App 且暴露了目标 API，
调用会在**本地**完成，不经过网络。

#### 7.4.2 `UIDTarget` —— 按会话 UID 寻址

路由到**具体**的 32 字节会话。适合"我想给刚才那个客户端发消息"这类场景。

```typescript
// UID 可以是 Uint8Array(32) 或 64 字符十六进制字符串。
const uidHex = "4fa01fc4a85b6099a037c5a3f01f49a89564268a2d7fd48009d636246cfc2633";
const target = new lf.UIDTarget(uidHex);

const result = await target.call("add", { a: 1, b: 2 });
```

**UID 可以打到目标上的任意 API**，不管它是 App 注册的
（`app.registerCall`）还是进程级 P2P 注册的（`registerP2PCall`）——
不需要知道目标 App 名。

**UID 生命周期**：UID 在每次 `TunnelLink` 时**重新生成**。调用方
如果缓存了 UID，**链路断开后必须重新探测**。

#### 7.4.3 `P2PNameTarget` —— 按组名寻址

路由到**任意**用户自定义组中的客户端。服务端**负载均衡**。

```typescript
const target = new lf.P2PNameTarget("workers");

// 服务端会在所有 P2PName = "workers" 的客户端中选一个
const result = await target.call("process", { task: "..." });
```

**不是本地优先**：即使调用者进程本身在目标组里，调用也会**转发
到服务端**做派发。这是刻意的：服务端拥有负载均衡状态。

**设置自己的组名**：

```typescript
lf.options.setOptP2PName("workers");
```

必须在 `prepareDone()` 之前设置，或者通过 `Update_UID` 命令
上报（每秒自动检查）。

#### 7.4.4 `hashKey()` —— 用于 Map / Set 的稳定键

JS 的 `Map` / `Set` 用**引用**比较键。如果你要把 Target 用作
字典键，用 `hashKey()`：

```typescript
const m = new Map<string, number>();
m.set(new lf.AppTarget("X").hashKey(), 1);
m.get(new lf.AppTarget("X").hashKey());   // => 1
```

每种寻址模式返回带前缀的键：`app:X`、`uid:<hex64>`、`p2p:G`。
三种模式**不会**碰撞（即使字符串部分相同）。

---

## 8. 运行时选项

`lf.options` 命名空间提供 **16 对 typed setter/getter**，一一对应
Pascal / C# / JavaScript 绑定的 `LF_Set_Opt_*` / `LF_Get_Opt_*` 系列。

### 8.1 完整的选项对照表

| Option | Setter / Getter | 类型 | 默认 |
|--------|-----------------|------|------|
| `password` | `setOptPassword` / `getOptPassword` | string | 空（返回固定掩码 `"********"`） |
| `debug` | `setOptDebug` / `getOptDebug` | string（只写） | — |
| `Quiet` | `setOptQuiet` / `getOptQuiet` | bool | `false` |
| `ShowThreadID` | `setOptShowThreadID` / `getOptShowThreadID` | bool | `true` |
| `ConsoleOutput` | `setOptConsoleOutput` / `getOptConsoleOutput` | bool | 平台相关 |
| `Overlap_Connection` | `setOptOverlapConnection` / `getOptOverlapConnection` | bool | `false` |
| `Wait_Connection_ReadyOk` | `setOptWaitConnectionReadyOk` / `getOptWaitConnectionReadyOk` | bool | `true` |
| `Wait_Connection_Timeout` | `setOptWaitConnectionTimeout` / `getOptWaitConnectionTimeout` | int（毫秒） | `30000` |
| `IPC_Serv_ThreadCount` | `setOptIpcServThreadCount` / `getOptIpcServThreadCount` | int | 平台相关 |
| `IPC_Serv_MaxQueueLength` | `setOptIpcServMaxQueueLength` / `getOptIpcServMaxQueueLength` | int | 平台相关 |
| `IPC_Serv_MaxMsgSize` | `setOptIpcServMaxMsgSize` / `getOptIpcServMaxMsgSize` | int（字节） | 平台相关 |
| `Fixed_Sequenced_Time` | `setOptFixedSequencedTime` / `getOptFixedSequencedTime` | int（毫秒） | `20000` |
| `LF_P2P_name` | `setOptP2PName` / `getOptP2PName` | string | 空 |
| `DataHandle_Idle_Timeout` | `setOptDataHandleIdleTimeout` / `getOptDataHandleIdleTimeout` | int（毫秒） | `600000`（10 分钟） |
| `DataHandle_Pool_Scan_Interval` | `setOptDataHandlePoolScanInterval` / `getOptDataHandlePoolScanInterval` | int（毫秒） | `5000`（5 秒） |
| `No_Reponse_Cmd_NULL_Flush_Threshold` | `setOptNoReponseCmdNullFlushThreshold` / `getOptNoReponseCmdNullFlushThreshold` | int | `5000` |

> **拼写注意**：`No_Reponse` 少一个 `s`，这是 Pascal 侧的历史拼写。
> typed 函数名与选项键都保持这个拼写。

### 8.2 使用示例

```typescript
const lf = require("lingofuse-ts");

lf.loadLibrary();

lf.options.setOptOverlapConnection(true);
lf.options.setOptWaitConnectionReadyOk(false);
lf.options.setOptP2PName("my_group");

console.log(lf.options.getOptP2PName());              // "my_group"
console.log(lf.options.getOptWaitConnectionReadyOk()); // false
```

### 8.3 ⚠️ `LF_SetOption` 是异步投递的

一旦 LingoFuse 模拟主线程启动（即 `prepareDone()` 返回 1），
`LF_SetOption` 会通过 `MainThreadPost.PostM_NP(DoRun)` **投递到
主线程**并在下一个 tick 应用。**setter 返回后立即 getter 读到的是
旧值**。

```typescript
// ❌ 错误：读到的可能是旧值
lf.options.setOptQuiet(true);
console.log(lf.options.getOptQuiet());   // 可能仍是 false

// ✅ 正确：等待主线程应用
lf.options.setOptQuiet(true);
await new Promise((r) => setTimeout(r, 150));
console.log(lf.options.getOptQuiet());   // true
```

150 毫秒远大于主线程的 1-10 毫秒 tick 粒度。

**在 `prepareDone()` 之前**设置选项不受这个限制 —— 此时主线程还
没启动，`LF_SetOption` 是**同步**应用的。

### 8.4 未知选项名被静默忽略

`LF_SetOption` 没有返回值，收到不认识的选项名时**不会报错**。
typed 快捷函数通过硬编码选项名消除了这个失败模式，但
`lf.framework.setOption("Typo", "x")` 仍然会静默忽略。

### 8.5 通用 `setOption` / `getOption` 仍然可用

typed 快捷函数是**叠加**在通用 API 之上的，不是替代：

```typescript
// 动态选项名（从配置文件读取）
const optionName = process.env.LF_OPTION_NAME || "Quiet";
lf.framework.setOption(optionName, "True");

// 或者读取原始字符串值
const raw = lf.framework.getOption("Quiet");   // "True" / "False" / ""
```

两条路径共享同一个底层 native 调用，混用是安全的。

---

## 9. P2P 身份读取

LingoFuse 的每个**入站请求载荷**都携带发送方的两个身份字段，
由**发送方传输层**在发送前自动注入：

```
[apiName: string]
[FromUID: 32 bytes]         ← 发送方会话 UID
[FromP2PName: string]       ← 发送方 P2P 组名
[Param.Size: Int32]
[Param: bytes]
```

这两个字段是**"侧数据"（side data）**。它们**不是句柄本身的
属性**，而是发送方写入载荷头部的元数据。**接收方只能在触发事件
的回调 `Input` 参数上读取它们**。

### 9.1 两个访问器

`DataHandle` 上有两个访问器：

```typescript
const uid  = input.getP2PUid();    // Uint8Array(32)
const name = input.getP2PName();   // string（未设置时返回 ""）
```

### 9.2 只能在 INPUT 句柄上调用

| 位置 | 是否有效 |
|------|:--------:|
| 回调的 `input` 参数 | ✅ |
| 本地调用的 `input` | ✅ |
| 回调的 `output` 参数 | ❌（返回 32 个 0 / 空串） |
| 你 `new DataHandle(...)` 出来的自建句柄 | ❌（同上） |

对无效位置调用时，库**不抛异常**，而是返回默认值（32 个 0 /
空字符串），并在 native 侧记录一条警告。

### 9.3 whoami 模式

**经典应用场景**：客户端想知道**自己的** UID（服务端看到的
"发送方 UID"）。

**服务端**：

```typescript
const app = new lf.AppHandle("IdentitySvc", "identity echo");

app.registerCall("whoami", "Echo caller identity", (input, output) => {
    // input 是携带发送方侧数据的 INPUT 句柄
    const callerUid = input.getP2PUid();
    const callerName = input.getP2PName();

    // 把 UID 十六进制化方便查看
    let hex = "";
    for (const b of callerUid) {
        hex += b.toString(16).padStart(2, "0");
    }

    lf.io.writeJson(output, {
        uid_hex: hex,
        p2p_name: callerName,
    });
});
```

**客户端**：

```typescript
const target = new lf.AppTarget("IdentitySvc");
const result = await target.call("whoami", {});

console.log("my UID:", result.uid_hex);   // 64 字符十六进制
console.log("my P2P:", result.p2p_name);  // 例如 "jstest2_group"

// 把 UID 存起来，之后可以用 UIDTarget 打到这个会话
const myUidTarget = new lf.UIDTarget(result.uid_hex);
```

### 9.4 实现细节（勘误）

**`LF_Get_P2P_UID` 返回指针，不是值**。native 侧返回
`const TP2P_UID*`（指向库拥有的 32 字节缓冲），并在调用后
**约 5 秒自动释放**。`DataHandle.getP2PUid()` 封装了这一切：

1. 立即用 `koffi.decode` 把 32 字节拷贝出来
2. **不**释放指针
3. **不**跨越本次方法调用保留指针

调用者看不到临时指针。

**`LF_Get_P2P_Name`** 返回 `const char*`，同样约 5 秒后失效。
Koffi 的 `str` 返回类型会在调用边界立刻拷贝成 JS 字符串，所以
`getP2PName()` 的返回值已经和 native 缓冲脱离。

### 9.5 `getP2PUid` 与 `options.getOptP2PName` 的区别

这两个概念容易混淆：

| 函数 | 读什么 | 从哪读 |
|------|--------|--------|
| `lf.options.getOptP2PName()` | **我**声明的组名 | 本地配置 |
| `input.getP2PName()` | **发送方**声明的组名 | 侧数据（载荷头部） |

换句话说：

- `getOptP2PName()` 回答"我给**自己**设了什么组名？"
- `DataHandle.getP2PName()` 回答"**发消息给我的人**是什么组名？"

两者都是 UTF-8 字符串，但来源完全不同。

---

## 10. 进程级 P2P 注册

除了 `App.registerCall`（App 绑定注册），v2.0 还提供**进程级
P2P 注册**，API 只通过 UID 或 P2PName 寻址可达，**不通过 App
名可达**。

```typescript
lf.registerP2PCall("whoami", (input, output) => {
    // 进程级 P2P API 的回调
    // 这里没有 App 绑定
    lf.io.writeJson(output, { ok: true });
}, "Echo");

lf.registerP2PNotify("log", (input) => {
    // ...
}, "One-way log");

// 移除
lf.unregisterP2P("whoami");
```

**典型用途**：注册一小部分全局可发现的功能（健康检查、能力发现、
身份回显），任何 mesh 上的客户端都可以按组名或 UID 调用，无需
知道对方的 App 名。

**命名空间隔离**：进程级 P2P 命名空间与任何 App **独立**。
在这里注册的 API **不通过 App 名可达**——即使 API 名恰好与 App 名
相同。

**失败语义**：注册失败时抛出 `LingoFuseRegistrationError`，而非
返回 false。原因见 `errors.ts` 的文档注释。

---

## 11. 异步子系统

`lf.async` 命名空间暴露 `AsyncBridge` / `AsyncOp` / `CallPromise`，
是 v2.0 三种调用风格的**共同底层**。

### 11.1 三种风格共享同一个 AsyncBridge

```typescript
const stats = lf.AsyncBridge.instance().stats();
console.log(stats);
// {
//   total: <int>,          // 当前活跃的 op 数
//   pending: <int>,        // 等待回调
//   fired: <int>,          // 回调已触发，等待释放
//   abandoned: <int>,      // 已超时，等待 grace 过期
//   not_queued: <int>,     // 派发失败
//   released_total: <int>, // 累计释放数
//   grace_seconds: <float>,
//   period_seconds: <float>,
// }
```

`AsyncBridge` 是**进程级单例**。三种风格的用户**共享同一份计数**。

### 11.2 Koffi 回调的生命周期

`AsyncBridge` 的存在是为了解决三个并发风险：

1. **超时后过早释放**：native 请求不会因为 JS 侧超时而取消。
   如果我们在超时时立即释放 Koffi 回调，native 侧会在后续回调时
   撞上悬空指针。
2. **派发失败时泄漏**：如果 native 在派发前就拒绝了请求（返回值
   不等于 1），回调永远不会触发。天真的"等回调释放"策略会永久
   泄漏 Koffi 回调。
3. **双重释放竞态**：JS 线程（超时）和 native 工作线程（回调）
   可能竞态释放同一个对象。

`AsyncBridge` 通过显式的状态机（`PENDING → FIRED | ABANDONED |
NOT_QUEUED`）解决三个风险。

### 11.3 环境变量配置

两个环境变量在模块加载时**读取一次**：

| 变量 | 默认值 | 含义 |
|------|:------:|------|
| `LINGOFUSE_ASYNC_RECLAIM_GRACE` | `60` | abandoned op 的 grace 周期（秒） |
| `LINGOFUSE_ASYNC_RECLAIM_PERIOD` | `1.0` | 回收扫描间隔（秒） |

### 11.4 关闭

在 `after()` / 进程退出前调用：

```typescript
lf.AsyncBridge.shutdownInstance();
```

它会：

1. 停止回收循环
2. 立即 flush 所有 pending 的 grace timer
3. 释放所有 outstanding op 的 Koffi 回调
4. 清空内部状态

不清空会导致 Koffi 句柄泄漏 + Node 事件循环无法退出。

---

## 12. 测试方法

### 12.1 类型检查

```bash
npm run check
```

执行 `tsc -p tsconfig.json --noEmit`，只做类型检查，不产生输出。
**这是提交代码前的最低要求**。

**预期**：无任何输出（成功时 tsc 静默）。

### 12.2 编译验证

```bash
npm run build
```

**预期**：无任何输出，`dist/` 目录生成。

如果只想检查而不产生文件，用 `npm run check`。

### 12.3 v1.0 基线测试套件（127 项）

```bash
npm test
```

或直接：

```bash
npx tsx test/test.ts
```

覆盖 9 个测试组：`errors` / `binding` / `DataHandle` / `lf-io` /
`AppHandle` / `framework` / `status` / `callbacks` / `network events`。

**预期输出末尾**：

```
Summary
  runtime : Node.js 20.x.x
  passed  : 127
  failed  : 0
  total   : 127
```

### 12.4 v2.0 测试套件（99 项）

```bash
npm run test:v2
```

或直接：

```bash
npx tsx test/test-v2.ts
```

覆盖 12 个测试组：

| # | 测试组 | 覆盖点 |
|:-:|--------|--------|
| 1 | `errors-v2` | 8 类异常、`LingoFuseTimeoutError` 字段、`ErrorCode.Timeout` |
| 2 | `CallPromise` | thenable / `abandoned` / `settled` / 幂等 / `await` |
| 3 | `AsyncBridge` | 单例 / stats / shutdown 幂等 / grace/period 默认值 |
| 4 | `Targets` | 三 Target 构造 / `hashKey` / UID 归一化 / 8 个方法 |
| 5 | `options` | 16 对 typed setter/getter round-trip + 参数校验 |
| 6 | `framework.getOption` | 与 typed 一致 / 未知返回空串 / 参数类型 |
| 7 | `DataHandle UID methods` | `writeUid` / `readUid` / `getP2PUid` / `getP2PName` |
| 8 | `p2p-registration` | 注册 / 注销 / 重复抛异常 / 参数校验 |
| 9 | `status UID checks` | 4 个 check 函数 / hex 字符串 / 参数校验 |
| 10 | `Integration: call shapes` | 三种风格 + `userData` + `notify` |
| 11 | `Integration: UIDTarget` | UID 端到端；接受 `Uint8Array(32)` 与 hex |
| 12 | `Integration: side data` | `whoami` 读 P2P 身份 / `output` 侧默认值 |

**预期输出末尾**：

```
Summary
  runtime : Node.js 20.x.x
  passed  : 99
  failed  : 0
  total   : 99
```

### 12.5 三个硬约束

v2.0 测试套件强制遵守三个硬约束（详见 `test/test-v2.ts` 文件头）：

| ID | 约束 | 原因 |
|:--:|------|------|
| **C1** | 不允许在测试运行时动态注册 API | `registerCall` 触发 1 秒延迟的 `Init_App_Info` 广播；广播 in-flight 时 `LF_ExitMainThread` 会阻塞 |
| **C2** | 不允许执行有副作用的 `debug` 命令 | `setOptDebug("service")` 等会触发 live query，可能留下 pending native task |
| **C3** | 启动 detached watchdog 子进程 | 如果 native shutdown 阻塞 JS 事件循环，任何 in-process timer 都失效；只有子进程能救场 |

**禁用 watchdog**（调试 native shutdown 时）：

```bash
LINGOFUSE_TEST_NO_WATCHDOG=1 npx tsx test/test-v2.ts
```

### 12.6 跨运行时测试

同一份测试用三种运行时分别执行：

```bash
# Node.js + tsx
npm run test:v2

# Bun
npm run test:v2:bun

# Deno（注意 test-v2 需要 --allow-run，因为启动了 watchdog）
npm run test:v2:deno
```

三次运行的结果应该**完全一致**（除了 `Summary` 里的 `runtime` 字段）。

### 12.7 跨语言测试

本绑定与 C++ / C# / Pascal / JavaScript / Python 各版本互通。跨语言
测试方法：

1. 用 C++ 或 Pascal 版本启动**服务端**：

   ```powershell
   # C++ 版本
   CrossService.exe

   # 或 Pascal 版本
   cross_service.exe
   ```

2. 用 TypeScript 版本的脚本连接（`cross/cross-call.ts` 已内置）：

   ```bash
   npx tsx cross/cross-call.ts
   ```

   `cross/cross-call.ts` 会对 `demo` 应用随机调用 `add` 和
   `inv_seri` 两个 API，做 10 秒的负载测试，输出吞吐量和成功率。

3. 或者用 TypeScript 版本的节点作为**工作节点**：

   ```bash
   npx tsx cross/cross-node.ts
   ```

   它会注册 `add` 和 `inv_seri` 两个 API，等待对端调用。

**目录说明**：

| 文件 | 角色 |
|------|------|
| `cross/cross-service.ts` | 协调器（信标 + 服务） |
| `cross/cross-node.ts` | 工作节点（暴露 `demo` 应用） |
| `cross/cross-call.ts` | 负载测试客户端 |

三种角色可以任意混用不同语言实现。所有绑定字节级互通。

### 12.8 生产部署前的检查清单

- [ ] `npm run check` 无错误
- [ ] `npm run build` 无错误
- [ ] `npm test` 通过（127 项）
- [ ] `npm run test:v2` 通过（99 项）
- [ ] 在目标运行时的实际环境中运行一次（不只是开发机）
- [ ] 动态库放置位置正确（见 §5）
- [ ] 如果使用 Deno，权限标志齐全（含 `--allow-run` 若启动 watchdog）
- [ ] 如果使用 Bun，确认版本 ≥ 1.0
- [ ] 清理顺序正确：`clearNetworkEvent → exitMainThread → app.dispose → shutdown`
- [ ] 在关闭前调用 `lf.AsyncBridge.shutdownInstance()`

---

## 13. 故障排查

### 13.1 `Cannot find module 'koffi'`

`node_modules/` 缺失或被删除。在 `ts/` 目录下运行 `npm install`。

如果你把 TS 文件移到了其他目录，`node_modules/` 必须随之移动（Node
从引用文件所在位置向上查找包）。

### 13.2 `Failed to load the LingoFuse native library`

动态库不在任何搜索路径上。见 [§5](#5-原生动态库放置)。

查看实际使用的搜索路径：

```bash
node -e "console.log(require('./dist/binding.js').buildSearchPaths().join('\n'))"
```

### 13.3 `Unexpected void * type, expected <callback> * type`

Koffi 拒绝了回调注册。这在本绑定的 v2.0.0+ 中**不应该再出现**。
如果出现，说明你的 `node_modules/koffi` 版本过旧（< 3.3.2）。

```bash
npm install koffi@latest
```

### 13.4 `Cannot find name 'process'` / `Cannot find name '__dirname'`

`@types/node` 未安装或 `tsconfig.json` 缺少 `"types": ["node"]`。

```bash
npm install -D @types/node
```

确认 `tsconfig.json` 里有：

```json
"types": ["node"]
```

### 13.5 `TS5103: Invalid value for '--ignoreDeprecations'`

你使用的 TypeScript 版本不接受 `tsconfig.json` 里配置的
`ignoreDeprecations` 值。

**修复**：把 `tsconfig.json` 里的值改为 `"5.0"`：

```json
"ignoreDeprecations": "5.0"
```

**说明**：TypeScript 5.9.3 存在一个已知不一致——提示信息要求填
`"6.0"`，但类型定义只接受 `"5.0"`。使用 `"5.0"` 在所有 5.5 ~
5.9 版本下都有效。

### 13.6 `Cannot use import statement outside a module`

你用 `node file.ts` 直接运行 TypeScript，但 Node.js 原生不支持
完整的 TypeScript（只做类型剥离，不做模块决策）。

**修复**：使用 `tsx`：

```bash
npx tsx file.ts
```

或使用 Bun / Deno。

### 13.7 VS Code 显示红色错误但 `npm run check` 通过

VS Code 使用的是**内置的 TypeScript 版本**，可能与项目本地版本
不一致。

**修复**（推荐）：让 VS Code 使用工作区版本。

1. 按 `Ctrl + Shift + P` 打开命令面板。
2. 输入 `TypeScript: Select TypeScript Version`。
3. 选择 `Use Workspace Version`。

或在 `.vscode/settings.json` 中配置：

```json
{
  "typescript.tsdk": "node_modules/typescript/lib",
  "typescript.enablePromptUseWorkspaceTsdk": true
}
```

### 13.8 `prepareDone()` 返回 0

`prepareDone` 每个进程只返回一次 1。第二次调用如果没有中间的
`shutdown()`，会返回 0。**这不是失败**。

完整契约见 `framework.ts` 的 `prepareDone()` 声明。

### 13.9 在 `prepareDone()` 之后立即调用超时

`prepareDone()` 返回的那一刻，mesh 不一定已经可用。如果设置了
`Wait_Connection_ReadyOk=False`（部署模式），必须显式轮询
`checkApp` / `checkApi`：

```typescript
async function waitForApp(
    appName: string,
    timeoutMs: number,
): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (lf.status.checkApp(appName)) return true;
        await new Promise(r => setTimeout(r, 100));
    }
    return false;
}

await waitForApp("MyApp", 10000);
```

`examples/hello-world.ts` 里的 `waitForApp` 就是这个模式。

### 13.10 回调抛出异常，进程静默退出

回调运行在原生工作线程上。未捕获的异常会跨入 C 栈。本绑定包装了
每一个回调以吞掉异常，并把它们路由到 `callbackErrorHandler`：

```typescript
lf.framework.setCallbackErrorHandler((source, err) => {
    console.error(`[LingoFuse] callback error in ${source}:`, err);
});
```

在注册任何 API 之前安装一次即可。

### 13.11 Deno 报告 `PermissionDenied`

Deno 需要显式权限。测试套件需要六个 `--allow-*` 标志：

```bash
deno run \
    --allow-ffi \
    --allow-read \
    --allow-env \
    --allow-net \
    --allow-sys \
    --allow-run \
    test/test-v2.ts
```

每个标志的理由见 [§6.3](#63-方式三deno-直接运行-ts)。

### 13.12 `LF_Get_P2P_UID` 的指针在 5 秒后失效

不要保存 native 侧返回的指针。用 `DataHandle.getP2PUid()`，它会
立即 `koffi.decode` 拷贝 32 字节：

```typescript
// ✅ 正确
const uid = input.getP2PUid();   // 立即拷贝

// ❌ 错误：不能直接拿 native 指针
const rawPtr = lf._binding.getBinding().funcs.LF_Get_P2P_UID(input.raw);
// 5 秒后 rawPtr 指向的内存会被 native 侧释放
```

### 13.13 `AsyncBridge` 让 Node 事件循环无法退出

如果忘记调用 `lf.AsyncBridge.shutdownInstance()`，Koffi 回调的
libuv 句柄会一直 ref'ed，Node 事件循环无法退出。

**修复**：在进程退出前显式调用：

```typescript
lf.AsyncBridge.shutdownInstance();
lf.framework.shutdown();
```

`AsyncBridge.shutdown()` 会释放所有 outstanding op 的回调，同时
flush 所有 pending 的 grace timer。

### 13.14 异步回调外使用 handle

**不要**把异步回调接收的 `Result_` handle 传出去，跨线程使用。

```typescript
// ❌ 错误：把异步 handle 传出去
let savedPtr: unknown = null;

target.callAsync("api", {}, (res, err) => {
    savedPtr = res;   // ❌ 回调返回后失效
});

// ... 稍后
// read from savedPtr   ❌ use-after-free
```

**正确**：回调内读取并拷贝数据，或直接用 Target 的 Promise 风格
（它已经在回调内完成了拷贝）。

### 13.15 用 `require("D:\\...\\ts")` 报 `Cannot find module`

绝对路径或相对路径直接指向一个目录时，Node 不会自动补 `index.js`。
要么写全路径（`require("D:/.../ts/dist/index.js")`），要么用包名
（`require("lingofuse-ts")`）。

---

## 14. API 速查

本绑定暴露**七个命名空间**、**两种 RAII 句柄类型**、**三种寻址
目标类**，以及**一套八类的异常层级**。

### 14.1 顶层符号

| 符号 | 说明 |
|------|------|
| `VERSION` | 绑定版本字符串（`"2.0.0"`） |
| `loadLibrary()` | 主动加载原生库（幂等） |
| `isLoaded()` | 原生库加载后返回 `true` |
| `libraryName()` | 平台相关的库文件名 |
| `platform()` | `{ platform, arch, runtime }` 摘要 |
| `detectRuntime()` | 探测运行时族：`"node"` / `"deno"` / `"bun"` / `"unknown"` |
| `getRuntimeInfo()` | 完整的运行时快照 |
| `LibraryLoader` | RAII 加载器（`dispose()` 是 no-op） |
| `DataHandle` | 数据缓冲的 RAII 封装 |
| `AppHandle` | 应用的 RAII 封装 |
| `AppTarget` | 按 App 名寻址的目标 |
| `UIDTarget` | 按 UID 寻址的目标 |
| `P2PNameTarget` | 按组名寻址的目标 |
| `CallPromise` | async/await 风格的 Promise 包装 |
| `AsyncBridge` | 异步子系统单例 |
| `registerP2PCall()` | 进程级 P2P Call 注册 |
| `registerP2PNotify()` | 进程级 P2P Notify 注册 |
| `unregisterP2P()` | 移除进程级 P2P API |
| `ErrorCode` | 与 C++ 一致的数值错误码枚举 |
| `Option` | 运行时选项名称常量 |
| `bool(value)` | 把布尔值转为 `"True"` / `"False"` |
| `io` | JSON / 字符串 / 字节 I/O 命名空间 |
| `framework` | 进程级 ABI 门面（低层） |
| `network` | 网络事件处理器 |
| `status` | 状态队列与健康检查 |
| `options` | typed 运行时选项（v2.0 新增） |
| `address` | 三种寻址模式（v2.0 新增） |
| `async` | 异步子系统（v2.0 新增） |
| `_binding` | 底层 `binding.ts` 模块对象（escape hatch） |

**异常类**（8 类）：

| 类 | 基类 | 附加字段 |
|----|------|---------|
| `LingoFuseError` | `Error` | `code` |
| `LingoFuseLibraryLoadError` | `LingoFuseError` | `libraryName` |
| `LingoFuseCallError` | `LingoFuseError` | `targetApp`, `targetApi` |
| `LingoFuseTimeoutError` | `LingoFuseError` | `targetApp`, `targetApi`, `timeoutMs` |
| `LingoFuseIoError` | `LingoFuseError` | `operation` |
| `LingoFuseObjectDisposedError` | `LingoFuseError` | `objectName` |
| `LingoFuseCallbackError` | `LingoFuseError` | `source`, `originalCause` |
| `LingoFuseRegistrationError` | `LingoFuseError` | `apiName` |

### 14.2 `io` 命名空间

| 函数 | 说明 |
|------|------|
| `dumps(value)` | 序列化为紧凑 JSON（字面 UTF-8，无 `\uXXXX`） |
| `loads<T>(text)` | 解析 JSON；失败时抛 `LingoFuseIoError` |
| `writeString(handle, str)` | 写 UTF-8 + NUL |
| `readString(handle)` | 读 UTF-8，遇 NUL 停止（容错） |
| `writeStringBytes(handle, bytes)` | 写原始字节 + NUL |
| `readStringBytes(handle)` | 读原始字节，遇 NUL 停止 |
| `readAllBytes(handle)` | 读取剩余全部字节 |
| `writeJson(handle, value)` | 序列化 value，写 UTF-8 + NUL |
| `readJson<T>(handle)` | 读 NUL 帧的 JSON，返回 `T \| null` |
| `tryReadJson<T>(handle)` | 不抛异常的 `readJson` |

### 14.3 `framework` 命名空间

| 函数 | 说明 |
|------|------|
| `setCallbackErrorHandler(fn)` | 安装全局错误报告器 |
| `getCallbackErrorHandler()` | 读取当前报告器 |
| `resetPrepare()` | 清空准备队列 |
| `prepareService(listen, physics)` | 准备一个服务端点 |
| `prepareClient(physics, app)` | 准备一个客户端连接 |
| `prepareDone()` | 启动框架 |
| `exitMainThread()` | 请求优雅退出 |
| `setOption(name, value)` | 调整运行时选项（通用） |
| `getOption(name)` | 读取运行时选项（通用） |
| `generateAppName()` | 生成唯一名称（须在 `prepareDone` 之后） |
| `getAppName(app)` | 查询 App 的权威名称 |
| `call(appName, param, timeoutMs?)` | 同步远程调用（低层） |
| `tryCall(appName, param, timeoutMs?)` | 超时/不可达时返回 `null` 的 `call` |
| `callAsync(appName, param, cb, data?)` | 内联回调式异步调用 |
| `callPromise(appName, param, timeoutMs?)` | Promise 式异步调用 |
| `notify(appName, param)` | 单向通知 |
| `sequencedNotify(appName, param)` | FIFO 单向通知 |
| `uidCall(uid, param, timeoutMs?)` | 同步 UID 调用 |
| `uidCallAsync(uid, param, cb, data?)` | 内联回调式 UID 调用 |
| `uidCallPromise(uid, param, timeoutMs?)` | Promise 式 UID 调用 |
| `uidNotify(uid, param)` | 单向 UID 通知 |
| `uidSequencedNotify(uid, param)` | FIFO 单向 UID 通知 |
| `p2pnameCall(name, param, timeoutMs?)` | 同步 P2PName 调用 |
| `p2pnameCallAsync(name, param, cb, data?)` | 内联回调式 P2PName 调用 |
| `p2pnameCallPromise(name, param, timeoutMs?)` | Promise 式 P2PName 调用 |
| `p2pnameNotify(name, param)` | 单向 P2PName 通知 |
| `p2pnameSequencedNotify(name, param)` | FIFO 单向 P2PName 通知 |
| `shutdown()` | 完全关闭 |

**`framework` 与 `address` 的分工**：

- `framework.*` 是**低层门面**，接受并返回 `DataHandle`；适合需要
  直接访问句柄的场景。
- `address.*` 是**高层抽象**，业务代码只接触 JavaScript 值；推荐
  用于绝大多数应用代码。

### 14.4 `network` 命名空间

| 函数 | 说明 |
|------|------|
| `setNetworkEvent(onConnect, onDisconnect)` | 安装连接 / 断开处理器 |
| `clearNetworkEvent()` | 移除两个处理器 |
| `isNetworkEventInstalled()` | 至少安装了一个时返回 `true` |
| `NetworkEventListener` | 面向对象监听器的基类 |
| `setNetworkEventListener(listener)` | 安装一个监听器实例 |

### 14.5 `status` 命名空间

| 函数 | 说明 |
|------|------|
| `getStatusCount()` | 队列中待处理的消息数 |
| `getStatus()` | 弹出下一条消息 |
| `drainStatus(maxMessages?)` | 最多弹出 N 条 |
| `postStatus(message)` | 推入一条消息 |
| `checkMainThread()` | 框架是否运行中 |
| `checkApp(appName)` | 应用是否可见 |
| `checkApi(appName, apiName)` | API 是否可见 |
| `checkUid(uid)` | UID 是否可见（v2.0 新增） |
| `checkUidApi(uid, apiName)` | UID 上的 API 是否可见（v2.0 新增） |
| `checkP2PName(p2pName)` | 组名是否可见（v2.0 新增） |
| `checkP2PNameApi(p2pName, apiName)` | 组上的 API 是否可见（v2.0 新增） |

### 14.6 `options` 命名空间

| 函数 | 说明 |
|------|------|
| 16 对 setter / getter | 见 §8.1 的完整对照表 |

### 14.7 `address` 命名空间

| 类 | 说明 |
|----|------|
| `Target` | 抽象基类（不直接使用） |
| `AppTarget` | 按 App 名寻址 |
| `UIDTarget` | 按 UID 寻址 |
| `P2PNameTarget` | 按组名寻址 |

**每个 Target 类都暴露以下方法**：

| 方法 | 说明 |
|------|------|
| `call(api, payload, {timeoutMs})` | 返回 `CallPromise`，用 `await` 消费 |
| `callAsync(api, payload, onResult, userData)` | 内联回调 |
| `callSync(api, payload, {timeoutMs})` | 同步（阻塞） |
| `tryCallSync(api, payload, {timeoutMs})` | 同步，失败返回 `null` |
| `sequencedCall(api, payload, {timeoutMs})` | 返回 `CallPromise`，FIFO |
| `sequencedCallAsync(api, payload, onResult, userData)` | 内联回调，FIFO |
| `notify(api, payload)` | 单向，无顺序保证 |
| `sequencedNotify(api, payload)` | 单向，FIFO |
| `hashKey()` | 稳定的、基于值的字符串键 |

### 14.8 `async` 命名空间

| 符号 | 说明 |
|------|------|
| `AsyncBridge` | 进程级单例。`instance()` / `shutdownInstance()` / `stats()` |
| `AsyncOp` | 单次异步操作的状态持有者 |
| `CallPromise` | Promise 包装，带 `abandoned` 标记 |
| `makeLegacyOp` | 底层工厂：构建 legacy 回调风格的 op |
| `makeFutureOp` | 底层工厂：构建 op + CallPromise 对 |
| `runAsyncWithPromise` | 一站式：构建 + 派发 + 设超时 |
| `runLegacyOp` | 一站式：legacy 回调风格 |

### 14.9 `DataHandle` 类

通过 `new lf.DataHandle("api_name")` 创建自动回收句柄；
通过 `lf.DataHandle.createPermanent("api_name")` 创建永久句柄。
使用完毕后一定要调用 `dispose()`，或者在回调内部使用（此时接口库
自动管理其生命周期）。

| 方法 / 属性 | 说明 |
|------------|------|
| `DataHandle.createPermanent(apiName)` | 静态工厂：创建永久句柄 |
| `DataHandle.fromRaw(raw, owned)` | 包装已有指针（内部使用） |
| `writeBytes(bytes)` / `readBytes(n)` | 原始字节 I/O |
| `readBytesExact(n)` / `tryReadBytes(n)` | 定长字节 I/O |
| `readAllBytes()` | 读到缓冲区末尾 |
| `writeInt8` … `writeDouble` | 小端原子写 |
| `readInt8` … `readDouble` | 小端原子读 |
| `writeString(s)` / `readString()` | NUL 帧的 UTF-8 |
| `tryReadString()` | 不抛异常的 `readString` |
| `writeUid(uid)` / `readUid()` | 32 字节 UID 读写（无 NUL 帧；v2.0 新增） |
| `getP2PUid()` | 读发送方 UID（仅 INPUT；v2.0 新增） |
| `getP2PName()` | 读发送方组名（仅 INPUT；v2.0 新增） |
| `position` / `size` | 游标和缓冲区大小（读写） |
| `getBufferPointer()` | 内部缓冲区的原生指针 |
| `dispose()` | 释放原生句柄（借用句柄上是 no-op） |
| `isValid` / `isOwning` / `raw` | 状态访问器 |

### 14.10 `AppHandle` 类

通过 `new lf.AppHandle("name", "description")` 创建。使用完毕后
一定要调用 `dispose()`。

| 方法 | 说明 |
|------|------|
| `registerCall(name, desc, handler)` | 注册一个 Call API |
| `registerNotify(name, desc, handler)` | 注册一个 Notify API |
| `unregister(name)` | 移除已注册的 API |
| `localCall(param)` / `localNotify(param)` | 进程内调用 |
| `bind()` | 绑定到空闲客户端 |
| `dispose()` | 解除关联并停止线程 |
| `name` / `isValid` / `raw` | 状态访问器 |

### 14.11 清理顺序

必须按以下顺序释放资源（LF-CLEAN-001）：

```typescript
lf.network.clearNetworkEvent();
lf.AsyncBridge.shutdownInstance();
lf.framework.exitMainThread();
app.dispose();
lf.framework.shutdown();
```

五个操作都是幂等的，可以在 `finally` 块中无条件调用。

---

## 附录 A：跨语言兼容性

本绑定与以下语言**字节兼容**：

| 语言 | 对应文件 |
|------|---------|
| C | `LingoFuse.h` / `LingoFuse.c` |
| C++ | `LingoFuse.hpp` / `lf_io.hpp` |
| C# | `LingoFuse.cs` / `LfIo.cs` |
| Pascal | `lingofuse_import.pas` |
| Python | `lingofuse.lf_io` |
| JavaScript | `lingofuse-js` |
| **TypeScript** | 本包 |

同一个 JSON 载荷在每个绑定上产生相同的线字节，读取语义也一致。
跨语言 RPC 无需任何转码层。

## 附录 B：与 JavaScript 绑定的对应

本绑定与 `lingofuse-js`（JavaScript 绑定）在**公共 API 面**上完全
对应，方便跨项目迁移：

| 功能 | JavaScript | TypeScript |
|------|------------|------------|
| 加载运行时 | `lf.loadLibrary()` | `lf.loadLibrary()` |
| 创建数据句柄 | `new lf.DataHandle("api")` | `new lf.DataHandle("api")` |
| 读 JSON | `lf.io.readJson(h)` | `lf.io.readJson<T>(h)` |
| 三种风格 | `call` / `callAsync` / `callSync` | 同左 |
| App 寻址 | `new lf.AppTarget(...)` | 同左 |
| UID 寻址 | `new lf.UIDTarget(...)` | 同左 |
| P2PName 寻址 | `new lf.P2PNameTarget(...)` | 同左 |
| typed options | `lf.options.setOptQuiet(...)` | 同左 |
| P2P 身份读 | `dh.getP2PUid()` | 同左 |
| 异步子系统 | `lf.async.AsyncBridge` | 同左 |
| 异常层级 | 8 类 | 8 类 |

## 附录 C：延伸阅读

- `src/index.ts` 文件头 — 公共入口的完整命名空间布局
- `src/address.ts` 文件头 — 三种寻址模式的语义与设计动机
- `src/async-support.ts` 文件头 — 异步子系统的设计动机和状态机
- `src/options.ts` 文件头 — typed 选项的用途和三条硬规则
- `src/p2p-registration.ts` 文件头 — 进程级 P2P 命名空间的隔离
- `src/data-handle.ts` 文件头 — 两种句柄的生命周期与 P2P 身份语义
- `src/framework.ts` 文件头 — 低层门面与高层抽象的边界
- `test/test-v2.ts` 文件头 — v2.0 测试套件的三个硬约束

## 附录 D：许可证

MIT。见 `package.json` 的 `license` 字段。
