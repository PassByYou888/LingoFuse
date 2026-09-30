# LingoFuse TypeScript 绑定

LingoFuse 分布式 RPC 框架的 TypeScript 绑定。通过 [Koffi](https://koffi.dev/)
调用 LingoFuse 原生库的 C ABI，支持 **Node.js 18+**、**Deno 2.x**、
**Bun 1.x+** 三种运行时。

本绑定与 C++、C#、Pascal、JavaScript 各版本**字节级互通**：

- 相同的 36 个导出 C 函数。
- 相同的 NUL 结尾 UTF-8 线格式。
- 相同的 JSON 序列化策略（紧凑、字面 UTF-8、无 `\uXXXX` 转义）。
- 相同的字符串三态容错读取。
- 相同的清理顺序（LF-CLEAN-001）。

在一个绑定上能工作的逻辑，在其他绑定上也一样。

---

## 目录

1. [项目结构](#1-项目结构)
2. [环境要求](#2-环境要求)
3. [依赖包](#3-依赖包)
4. [安装与构建](#4-安装与构建)
5. [原生动态库放置](#5-原生动态库放置)
6. [运行方式](#6-运行方式)
7. [测试方法](#7-测试方法)
8. [故障排查](#8-故障排查)
9. [API 速查](#9-api-速查)

---

## 1. 项目结构

```
ts/
├── package.json              项目清单
├── tsconfig.json             TypeScript 编译配置
├── README.md                 本文档
├── src/                      源代码（编译输入）
│   ├── index.ts              公开入口，re-exports
│   ├── errors.ts             异常层级 + ErrorCode
│   ├── types.ts              纯类型声明（无运行时代码）
│   ├── runtime.ts            Node / Deno / Bun 运行时探测
│   ├── options.ts            运行时选项常量 + bool() 助手
│   ├── binding.ts            Koffi 声明 + 库加载 + 36 个函数
│   ├── library-loader.ts     RAII 加载器
│   ├── data-handle.ts        TDataHnd 的 RAII 封装
│   ├── app-handle.ts         TAppHnd 的 RAII 封装
│   ├── lf-io.ts              JSON / 字符串 / 字节 I/O
│   ├── framework.ts          进程级 ABI 门面
│   ├── network-events.ts     连接 / 断开事件
│   └── status.ts             状态队列与健康检查
├── examples/
│   └── hello-world.ts        端到端演示（不参与编译）
└── dist/                     编译输出（构建后生成）
```

`src/` 下的每个模块都是独立可导入的。`index.ts` 是公开入口，
其余模块通过命名空间或具名导出暴露。

---

## 2. 环境要求

### 2.1 版本矩阵

| 组件 | 最低版本 | 推荐 | 备注 |
|------|:--------:|:----:|------|
| **Node.js** | 18 | 20 LTS 或 22 | 运行时之一 |
| **Deno** | 2.0 | 2.x 最新 | 运行时之一（可选） |
| **Bun** | 1.0 | 1.x 最新 | 运行时之一（可选） |
| **TypeScript** | 5.0 | 5.4.x | 仅编译期需要 |
| **Koffi** | 3.3.2 | 3.3.2+ | FFI 依赖，自动安装 |
| **@types/node** | 20 | 20.x | 仅类型声明，devDependency |
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
| `typescript` | `^5.4.0` | 编译 `.ts` → `.js` |
| `@types/node` | `^20.11.0` | Node.js 全局类型（`process` / `TextEncoder` / `__dirname`） |
| `tsx`（可选） | `^4.7.0` | 直接运行 `.ts` 文件（不经过编译） |

`@types/node` 是**必需**的，因为 `binding.ts` 里用到了 `node:path` /
`node:fs`，`app-handle.ts` 里用到了 `process.stderr`。

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
2. 从 npm registry 下载 `koffi`、`typescript`、`@types/node`。
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

**开发模式**（文件变更自动重编译）：

```bash
npm run build:watch
```

**仅类型检查**（不产生输出）：

```bash
npm run typecheck
```

### 4.3 编译目标

`tsconfig.json` 的关键设置：

| 选项 | 值 | 含义 |
|------|-----|------|
| `target` | `ES2022` | 输出语法版本（Node 18+ / Bun / Deno 都支持） |
| `module` | `CommonJS` | 输出 `require()` / `module.exports` |
| `moduleResolution` | `Node` | 传统的 node_modules 解析 |
| `strict` | `true` | 全套严格检查 |
| `declaration` | `true` | 生成 `.d.ts` |

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

**注意**：`examples/` 目录**不参与编译**（`tsconfig.json` 的
`include` 只有 `src/**/*.ts`）。示例脚本由 `tsx` / `bun` / `deno`
直接运行。

---

## 7. 测试方法

### 7.1 类型检查

```bash
npm run typecheck
```

执行 `tsc --noEmit`，只做类型检查，不产生输出。**这是提交代码前的
最低要求**。

**预期**：无任何输出（成功时 tsc 静默）。

### 7.2 编译验证

```bash
npm run build
```

**预期**：无任何输出，`dist/` 目录生成。

如果只想检查而不产生文件，用 `npm run typecheck`。

### 7.3 端到端测试（示例脚本）

`examples/hello-world.ts` 是一个**自包含**的端到端测试，无需外部进程：

```bash
npx tsx examples/hello-world.ts
```

**它做了什么**：

1. 加载原生库
2. 创建应用 `TsDemo`，注册三个 API：`add`（Call）、`echo`（Call）、`log`（Notify）
3. 启动自连通的服务+客户端
4. 等待应用在 mesh 上可见
5. 通过三条路径调用每个 API：
   - `app.localCall`（进程内，无网络跳转）
   - `app.localNotify`（进程内，单向）
   - `framework.call`（网络路由，通过 local-first 优化落到本地实例）
6. 输出结果
7. 按 LF-CLEAN-001 顺序清理

**预期输出**：

```
=== LingoFuse TypeScript demo ===

[Phase 1] runtime: node / win32 / x64

[Phase 2] registered: add, echo (Call), log (Notify)

[Phase 3] service tag=1, client tag=2

[Phase 3b] application is visible on the mesh

[Phase 4a] localCall('add', {a:5, b:7}) -> {"result":12}
[App] notify payload: {"level":"info","message":"hello"}
[Phase 4b] localCall('echo', ...) -> {"echo":{"greeting":"你好","list":[1,2,3]},"server":"ts-demo"}
[Phase 4d] framework.call('TsDemo', 'add', ...) -> {"result":300}

[Phase 6] shutting down
          done

=== demo completed successfully ===
```

**日志顺序**：由于 `localNotify` 的回调在原生工作线程上运行，`[App] notify payload`
可能与 `[Phase 4b]` 交错。这是正常的。

### 7.4 跨语言测试

本绑定与 C++ / C# / Pascal / JavaScript 各版本互通。跨语言测试方法：

1. 用 C++ 或 Pascal 版本启动**服务端**：

   ```powershell
   # C++ 版本
   CrossService.exe

   # 或 Pascal 版本
   cross_service.exe
   ```

2. 用 TypeScript 版本的脚本连接：

   ```typescript
   import * as lf from "lingofuse-ts";

   lf.loadLibrary();
   lf.framework.resetPrepare();
   lf.framework.prepareClient("ipc:cross", null);
   lf.framework.prepareDone();

   // 等待对端可见
   while (!lf.status.checkApp("demo")) {
       await new Promise(r => setTimeout(r, 100));
   }

   // 调用对端的 add API
   const param = new lf.DataHandle("add");
   param.writeInt32(5);
   param.writeInt32(7);

   const result = lf.framework.call("demo", param, 3000);
   const sum = result.readInt32();
   console.log(`5 + 7 = ${sum}`);   // 12

   param.dispose();
   result.dispose();
   lf.framework.exitMainThread();
   lf.framework.shutdown();
   ```

### 7.5 跨运行时测试

同一份 `examples/hello-world.ts` 用三种运行时分别运行：

```bash
# Node.js + tsx
npx tsx examples/hello-world.ts

# Bun
bun run examples/hello-world.ts

# Deno
deno run --allow-ffi --allow-read --allow-env --allow-net --allow-sys examples/hello-world.ts
```

三次运行的输出应该**完全一致**（除了 `[Phase 1]` 的 runtime 字段，
分别显示 `node` / `bun` / `deno`）。

### 7.6 生产部署前的检查清单

- [ ] `npm run typecheck` 无错误
- [ ] `npm run build` 无错误
- [ ] `npx tsx examples/hello-world.ts` 完整跑通
- [ ] 在目标运行时的实际环境中运行一次（不只是开发机）
- [ ] 动态库放置位置正确（见 §5）
- [ ] 如果使用 Deno，权限标志齐全
- [ ] 如果使用 Bun，确认版本 ≥ 1.0
- [ ] 清理顺序正确：`clearNetworkEvent → exitMainThread → app.dispose → shutdown`

---

## 8. 故障排查

### 8.1 `Cannot find module 'koffi'`

`node_modules/` 缺失或被删除。在 `ts/` 目录下运行 `npm install`。

如果你把 TS 文件移到了其他目录，`node_modules/` 必须随之移动（Node
从引用文件所在位置向上查找包）。

### 8.2 `Failed to load the LingoFuse native library`

动态库不在任何搜索路径上。见 [§5](#5-原生动态库放置)。

查看实际使用的搜索路径：

```bash
node -e "console.log(require('./dist/binding.js').buildSearchPaths().join('\n'))"
```

### 8.3 `Unexpected void * type, expected <callback> * type`

Koffi 拒绝了回调注册。这在本绑定的 v1.0.0+ 中**不应该再出现**。
如果出现，说明你的 `node_modules/koffi` 版本过旧（< 3.3.2）。

```bash
npm install koffi@latest
```

### 8.4 `Cannot find name 'process'` / `Cannot find name '__dirname'`

`@types/node` 未安装或 `tsconfig.json` 缺少 `"types": ["node"]`。

```bash
npm install -D @types/node
```

确认 `tsconfig.json` 里有：

```json
"types": ["node"]
```

### 8.5 `TS5103: Invalid value for '--ignoreDeprecations'`

你使用的 TypeScript 版本不接受 `tsconfig.json` 里配置的
`ignoreDeprecations` 值。

**修复**：把 `tsconfig.json` 里的值改为 `"5.0"`：

```json
"ignoreDeprecations": "5.0"
```

**说明**：TypeScript 5.9.3 存在一个已知不一致——提示信息要求填
`"6.0"`，但类型定义只接受 `"5.0"`。使用 `"5.0"` 在所有 5.5 ~
5.9 版本下都有效。

### 8.6 `Cannot use import statement outside a module`

你用 `node file.ts` 直接运行 TypeScript，但 Node.js 原生不支持
完整的 TypeScript（只做类型剥离，不做模块决策）。

**修复**：使用 `tsx`：

```bash
npx tsx file.ts
```

或使用 Bun / Deno。

### 8.7 VS Code 显示红色错误但 `npm run build` 通过

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

### 8.8 `prepareDone()` 返回 0

`prepareDone` 每个进程只返回一次 1。第二次调用如果没有中间的
`shutdown()`，会返回 0。**这不是失败**。

完整契约见 `framework.ts` 的 `prepareDone()` 声明。

### 8.9 在 `prepareDone()` 之后立即调用超时

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

### 8.10 回调抛出异常，进程静默退出

回调运行在原生工作线程上。未捕获的异常会跨入 C 栈。本绑定包装了
每一个回调以吞掉异常，并把它们路由到 `callbackErrorHandler`：

```typescript
lf.framework.setCallbackErrorHandler((source, err) => {
    console.error(`[LingoFuse] callback error in ${source}:`, err);
});
```

在注册任何 API 之前安装一次即可。

### 8.11 Deno 报告 `PermissionDenied`

Deno 需要显式权限。加上五个 `--allow-*` 标志：

```bash
deno run \
    --allow-ffi \
    --allow-read \
    --allow-env \
    --allow-net \
    --allow-sys \
    your-script.ts
```

每个标志的理由见 [§6.3](#63-方式三deno-直接运行-ts)。

---

## 9. API 速查

本绑定暴露四个命名空间、两种 RAII 句柄类型，以及一套异常层级。

### 9.1 顶层符号

| 符号 | 说明 |
|------|------|
| `VERSION` | 绑定版本字符串（`"1.0.0"`） |
| `loadLibrary()` | 主动加载原生库（幂等） |
| `isNativeLoaded()` | 原生库加载后返回 `true` |
| `libraryName()` | 平台相关的库文件名 |
| `platform()` | `{ platform, arch, runtime }` 摘要 |
| `detectRuntime()` | 探测运行时族：`"node"` / `"deno"` / `"bun"` / `"unknown"` |
| `getRuntimeInfo()` | 完整的运行时快照 |
| `LibraryLoader` | RAII 加载器（`dispose()` 是 no-op） |
| `DataHandle` | 数据缓冲的 RAII 封装 |
| `AppHandle` | 应用的 RAII 封装 |
| `ErrorCode` | 与 C++ 一致的数值错误码枚举 |
| `Option` | 运行时选项名称常量 |
| `bool(value)` | 把布尔值转为 `"True"` / `"False"` |
| `io` | JSON / 字符串 / 字节 I/O 命名空间 |
| `framework` | 进程级 ABI 门面 |
| `network` | 网络事件处理器 |
| `status` | 状态队列与健康检查 |

### 9.2 `io` 命名空间

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

### 9.3 `framework` 命名空间

| 函数 | 说明 |
|------|------|
| `setCallbackErrorHandler(fn)` | 安装全局错误报告器 |
| `getCallbackErrorHandler()` | 读取当前报告器 |
| `resetPrepare()` | 清空准备队列 |
| `prepareService(listen, physics)` | 准备一个服务端点 |
| `prepareClient(physics, app)` | 准备一个客户端连接 |
| `prepareDone()` | 启动框架 |
| `exitMainThread()` | 请求优雅退出 |
| `setOption(name, value)` | 调整运行时选项 |
| `generateAppName()` | 生成唯一名称（须在 `prepareDone` 之后） |
| `call(appName, param, timeoutMs?)` | 同步远程调用 |
| `notify(appName, param)` | 单向通知 |
| `sequencedNotify(appName, param)` | FIFO 单向通知 |
| `shutdown()` | 完全关闭 |

### 9.4 `network` 命名空间

| 函数 | 说明 |
|------|------|
| `setNetworkEvent(onConnect, onDisconnect)` | 安装连接 / 断开处理器 |
| `clearNetworkEvent()` | 移除两个处理器 |
| `isNetworkEventInstalled()` | 至少安装了一个时返回 `true` |
| `NetworkEventListener` | 面向对象监听器的基类 |
| `setNetworkEventListener(listener)` | 安装一个监听器实例 |

### 9.5 `status` 命名空间

| 函数 | 说明 |
|------|------|
| `getStatusCount()` | 队列中待处理的消息数 |
| `getStatus()` | 弹出下一条消息 |
| `drainStatus(maxMessages?)` | 最多弹出 N 条 |
| `postStatus(message)` | 推入一条消息 |
| `checkMainThread()` | 框架是否运行中 |
| `checkApp(appName)` | 应用是否可见 |
| `checkApi(appName, apiName)` | API 是否可见 |

### 9.6 `DataHandle` 类

通过 `new lf.DataHandle("api_name")` 创建。使用完毕后必须调用
`dispose()`，或者在回调内部使用（此时绑定自动管理其生命周期）。

| 成员 | 说明 |
|------|------|
| `writeBytes(bytes)` / `readBytes(n)` | 原始字节 I/O |
| `readBytesExact(n)` / `tryReadBytes(n)` | 定长字节 I/O |
| `readAllBytes()` | 读到缓冲区末尾 |
| `writeInt8` … `writeDouble` | 小端原子写 |
| `readInt8` … `readDouble` | 小端原子读 |
| `writeString(s)` / `readString()` | NUL 帧的 UTF-8 |
| `position` / `size` | 游标和缓冲区大小（读写） |
| `dispose()` | 释放原生句柄（借用句柄上是 no-op） |
| `isValid` / `isOwning` / `raw` | 状态访问器 |

### 9.7 `AppHandle` 类

通过 `new lf.AppHandle("name", "description")` 创建。使用完毕后必须
调用 `dispose()`。

| 成员 | 说明 |
|------|------|
| `registerCall(name, desc, handler)` | 注册一个 Call API |
| `registerNotify(name, desc, handler)` | 注册一个 Notify API |
| `unregister(name)` | 移除已注册的 API |
| `localCall(param)` / `localNotify(param)` | 进程内调用 |
| `bind()` | 绑定到空闲客户端 |
| `dispose()` | 解除关联并停止线程 |
| `name` / `isValid` / `raw` | 状态访问器 |

### 9.8 清理顺序

必须按以下顺序释放资源（LF-CLEAN-001）：

```typescript
lf.network.clearNetworkEvent();
lf.framework.exitMainThread();
app.dispose();
lf.framework.shutdown();
```

四个操作都是幂等的，可以在 `finally` 块中无条件调用。

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

## 附录 B：许可证

MIT。见 `package.json` 的 `license` 字段。
