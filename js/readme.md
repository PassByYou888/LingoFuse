# LingoFuse JavaScript 接口库

**LingoFuse** 分布式 RPC 框架的跨平台 JavaScript 绑定。支持
**Node.js**、**Deno**（2.x）和 **Bun**。通过 [Koffi](https://koffi.dev/)
调用 LingoFuse 原生库的 C ABI。

本绑定由一个 CommonJS 核心和一个轻量 ESM 包装组成，与 C++、C#、
Pascal、Python 各版本一一对应：

- 相同的 **59 个**导出 C 函数。
- 相同的 NUL 结尾 UTF-8 线格式。
- 相同的 JSON 序列化策略（紧凑、字面 UTF-8、无 `\uXXXX` 转义）。
- 相同的字符串三态容错读取。
- 相同的 `tryCall` / `getAppName` / `createPermanent` 便捷 API。
- 相同的三种寻址模式（App 名 / UID / P2PName）。
- 相同的 Handle 所有权模型（同步族 / 异步族）。
- 相同的 P2P 身份侧数据语义。

在一个绑定上能工作的逻辑，在其他绑定上也一样。

---

## v2.0 相比 v1.0 的变化

v1.0 是一个 C ABI 直译层：59 个导出函数中只覆盖了 37 个，只提供
`App` 名寻址和回调式异步。

v2.0 补齐了完整能力，并在其上构建了**面向业务的抽象层**：

| 维度 | v1.0 | v2.0 |
|------|:----:|:----:|
| C ABI 覆盖 | 37 / 59 | **59 / 59** |
| 调用风格 | 内联回调 + 同步 | 内联回调 + async/await + 同步 |
| 寻址模式 | App 名 | App 名 / UID / P2PName |
| 运行时选项 | 通用 `setOption` | 通用 + **16 对 typed 快捷** |
| P2P 身份读取 | 无 | `DataHandle.getP2PUid` / `getP2PName` |
| P2P 全局注册 | 无 | `registerP2PCall` / `registerP2PNotify` |
| 异常层级 | 6 类 | **8 类** |
| 测试套件 | 127 项 | 127 + **96 项** |

**没有破坏性变更**。v1.0 的所有代码在 v2.0 上原样运行。

---

## 目录

1. [环境要求](#1-环境要求)
2. [项目布局](#2-项目布局)
3. [环境搭建](#3-环境搭建)
   - [3.1 Windows 上的 Node.js](#31-windows-上的-nodejs)
   - [3.2 Linux / macOS / BSD 上的 Node.js](#32-linux--macos--bsd-上的-nodejs)
   - [3.3 Deno](#33-deno)
   - [3.4 Bun](#34-bun)
4. [原生库放置](#4-原生库放置)
5. [验证](#5-验证)
   - [5.1 环境检查](#51-环境检查)
   - [5.2 运行演示](#52-运行演示)
   - [5.3 运行测试套件](#53-运行测试套件)
6. [在其他应用中使用本接口库](#6-在其他应用中使用本接口库)
   - [6.0 四种引用方案对比](#60-四种引用方案对比)
   - [6.1 方案 A —— 绝对路径 require](#61-方案-a--绝对路径-require)
   - [6.2 方案 B —— npm install 本地路径](#62-方案-b--npm-install-本地路径)
   - [6.3 方案 C —— npm link](#63-方案-c--npm-link)
   - [6.4 方案 D —— Windows 目录联接](#64-方案-d--windows-目录联接)
   - [6.5 完整最小示例](#65-完整最小示例)
   - [6.6 `require` 路径不能指到目录](#66-require-路径不能指到目录)
   - [6.7 CommonJS 用法](#67-commonjs-用法)
   - [6.8 ESM 用法](#68-esm-用法)
   - [6.9 最简 Call API 示例](#69-最简-call-api-示例)
   - [6.10 最简 Notify API 示例](#610-最简-notify-api-示例)
   - [6.11 纯客户端示例](#611-纯客户端示例)
   - [6.12 `tryCall` 与 `call` 的选择](#612-trycall-与-call-的选择)
   - [6.13 永久句柄与短生命周期句柄](#613-永久句柄与短生命周期句柄)
   - [6.14 JSON 载荷约定](#614-json-载荷约定)
   - [**6.15 三种调用风格（v2.0 新增）**](#615-三种调用风格v20-新增)
   - [**6.16 三种寻址模式（v2.0 新增）**](#616-三种寻址模式v20-新增)
   - [**6.17 typed options（v2.0 新增）**](#617-typed-optionsv20-新增)
   - [**6.18 P2P 身份读取（v2.0 新增）**](#618-p2p-身份读取v20-新增)
7. [故障排查](#7-故障排查)
8. [API 速查](#8-api-速查)

---

## 1. 环境要求

| 组件            | 最低版本 | 说明                                       |
|-----------------|:--------:|--------------------------------------------|
| Node.js         | 18       | 推荐 20 LTS 或更新。                       |
| npm             | 9        | 随 Node.js 一起安装。                      |
| Deno（可选）    | 2.0      | 如果只用 Node.js，则无需安装。             |
| Bun（可选）     | 1.0      | 如果只用 Node.js，则无需安装。             |
| Koffi           | 3.3.2    | 由 `npm install` 自动安装。                |

本绑定使用纯 ECMAScript 2022 编写，自身不需要编译器。Koffi 依赖
为所有受支持的平台预编译好了原生二进制，因此安装 Koffi 无需 C++
工具链。

---

## 2. 项目布局

本接口库以扁平目录形式交付：

```
js/
├── check-env.js               环境诊断脚本
├── index.js                   CommonJS 入口
├── index.mjs                  ESM 入口
├── errors.js                  异常层级（v2.0：8 类）
├── binding.js                 Koffi 声明与库加载（59 个符号）
├── data-handle.js             TDataHnd 的 RAII 封装（含 P2P 身份访问器）
├── app-handle.js              TAppHnd 的 RAII 封装
├── lf-io.js                   JSON / 字符串 / 字节 I/O
├── framework.js               进程级 ABI 门面
├── network-events.js          连接 / 断开事件处理器
├── status.js                  状态队列与健康检查（含 UID / P2PName 检查）
├── options.js                 typed 运行时选项（v2.0 新增）
├── address.js                 三种寻址抽象（v2.0 新增）
├── async-support.js           异步子系统（v2.0 新增）
├── p2p-registration.js        进程级 P2P 注册（v2.0 新增）
├── package.json
├── PORTABILITY.md             各运行时的专项说明
├── readme.md                  本文件
├── test/
│   ├── test.js                v1.0 测试套件（127 项）
│   ├── test2.js               v2.0 测试套件（96 项）
│   └── lf_js_helloworld.js    端到端演示
├── cross/
│   ├── cross-service.js       信标（协调器）
│   ├── cross-node.js          工作节点（暴露 "demo" 应用）
│   └── cross-call.js          负载测试客户端
└── node_modules/              已安装依赖（koffi）
```

所有源文件都在同一目录下，没有 `src/` 子目录。

---

## 3. 环境搭建

### 3.1 Windows 上的 Node.js

**前置条件**

1. 从 <https://nodejs.org/en/download/> 下载并安装 Node.js 18 或
   更新版本。MSI 安装包会自动把 `node` 和 `npm` 加入 `PATH`。
2. 在一个**全新的** PowerShell 窗口中验证安装：

   ```powershell
   node --version
   npm --version
   ```

   预期输出：`v18.x.x` 或更高，以及 `9.x.x` 或更高。

**安装依赖**

在 `js/` 目录下执行：

```powershell
cd D:\CoreLibrary\LingoFuse\js
npm install
```

`npm install` 读取 `package.json`，从 npm registry 下载
`koffi@3.3.2`，并把 Windows x64 的预编译二进制解包到
`node_modules/@koromix/koffi-win32-x64/`。无需任何构建工具。

**如果 `npm install` 失败**

- 清空缓存后重试：

  ```powershell
  npm cache clean --force
  Remove-Item -Recurse -Force node_modules
  Remove-Item package-lock.json
  npm install
  ```

- 如果处于代理环境中，配置 npm：

  ```powershell
  npm config set proxy http://your-proxy:port
  npm config set https-proxy http://your-proxy:port
  npm install
  ```

### 3.2 Linux / macOS / BSD 上的 Node.js

**前置条件**

安装 Node.js 18 或更新版本。推荐方式（按优先级排序）：

- **nvm**（所有 Linux 发行版、macOS）：

  ```bash
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  source ~/.bashrc      # 或 ~/.zshrc
  nvm install 20
  nvm use 20
  ```

- **发行版软件包**（Debian、Ubuntu）：

  ```bash
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  ```

- **Homebrew**（macOS）：

  ```bash
  brew install node@20
  ```

验证：

```bash
node --version
npm --version
```

**安装依赖**

在 `js/` 目录下执行：

```bash
cd /path/to/LingoFuse/js
npm install
```

系统会自动选择对应的原生二进制：

| 平台              | 安装的软件包                            |
|-------------------|-----------------------------------------|
| Linux x64         | `@koromix/koffi-linux-x64`              |
| Linux arm64       | `@koromix/koffi-linux-arm64`            |
| macOS x64         | `@koromix/koffi-darwin-x64`             |
| macOS arm64       | `@koromix/koffi-darwin-arm64`           |
| FreeBSD / OpenBSD | 对应的 `koffi-*` 软件包                  |

**如果 `npm install` 失败**

- 确认你对 `js/` 目录有写权限：

  ```bash
  ls -ld /path/to/LingoFuse/js
  ```

  如果目录属于其他用户，要么先 `chown`，要么用
  `sudo npm install --unsafe-perm` 安装。`--unsafe-perm` 是必需的，
  因为 koffi 的 postinstall 脚本需要写入项目目录。

- 如果在企业网络中安装挂起，换一个 registry 重试：

  ```bash
  npm install --registry=https://registry.npmmirror.com
  ```

### 3.3 Deno

Deno 是可选的。从 <https://deno.land/#installation> 安装：

```bash
# Linux / macOS
curl -fsSL https://deno.land/install.sh | sh

# Windows PowerShell
irm https://deno.land/install.ps1 | iex
```

Deno 通过 `npm:` 说明符消费本接口库。Deno 的 npm 兼容层内部会提供
一个 CommonJS `require`，这正是本接口库需要的。

完整的 Deno 契约见 [PORTABILITY.md](PORTABILITY.md) §4。Deno 需要
`--allow-ffi`、`--allow-read`、`--allow-env` 权限。

### 3.4 Bun

Bun 是可选的。从 <https://bun.sh/> 安装：

```bash
# Linux / macOS
curl -fsSL https://bun.sh/install | bash

# Windows PowerShell
powershell -c "irm bun.sh/install.ps1 | iex"
```

Bun 同时接受 `require("lingofuse-js")` 和
`import lf from "lingofuse-js"`，无需额外配置。

完整的 Bun 契约见 [PORTABILITY.md](PORTABILITY.md) §5。

---

## 4. 原生库放置

本接口库**不包含** LingoFuse 原生共享库。该库需要单独构建（从
Pascal / C++ 源码），并放到操作系统加载器能够找到的位置。

**期望的文件名**

| 平台              | 文件名                |
|-------------------|-----------------------|
| Windows 64 位     | `LingoFuse64.dll`     |
| Windows 32 位     | `LingoFuse32.dll`     |
| Linux / BSD       | `liblingofuse.so`     |
| macOS             | `liblingofuse.dylib`  |

**接口库使用的搜索顺序**

接口库依次尝试：

1. 当前可执行文件所在目录（`process.execPath`）。
2. 当前工作目录（`process.cwd()`）。
3. 接口库包同级的 `native/` 子目录。
4. **操作系统加载器搜索路径**：
   - Windows：`PATH` 环境变量。
   - Linux：`LD_LIBRARY_PATH`，然后是 `/etc/ld.so.conf` 和
     `/etc/ld.so.conf.d/*.conf`。
   - macOS：`DYLD_LIBRARY_PATH`、`DYLD_FALLBACK_LIBRARY_PATH`，
     以及标准的 framework 路径。

以上任一位置都行。如果库已在系统加载器路径上，就无需复制。

**示例放置**

Windows：把 `LingoFuse64.dll` 复制到与可执行文件相同的目录，
或将其目录加入 `PATH`：

```powershell
$env:PATH += ";D:\CoreLibrary\LingoFuse\Binary"
```

Linux：把 `liblingofuse.so` 复制到 `/usr/local/lib` 并运行
`sudo ldconfig`，或将其目录加入 `LD_LIBRARY_PATH`：

```bash
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/opt/lingofuse/lib"
```

macOS：把 `liblingofuse.dylib` 复制到 `/usr/local/lib`，或将其
目录加入 `DYLD_LIBRARY_PATH`：

```bash
export DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH:/opt/lingofuse/lib"
```

`check-env.js`（见 [§5.1](#51-环境检查)）会打印精确的搜索顺序，
然后尝试一次权威的加载。放置完库之后运行一次。

---

## 5. 验证

### 5.1 环境检查

在 `js/` 目录下执行：

```bash
node check-env.js
```

预期输出（以 Windows 为例；Linux 和 macOS 除了文件名之外完全
相同）：

```
========================================================================
1. Node.js runtime
========================================================================
         Node version    : v20.x.x
         Platform        : win32
         Architecture    : x64
         ...
  [OK]   Running on Node.js.

========================================================================
2. koffi package
========================================================================
  [OK]   koffi can be require()d.
  [OK]   koffi version: 3.3.2

========================================================================
3. koffi native addon
========================================================================
  [OK]   koffi native addon loaded; probed 'kernel32.dll'.

========================================================================
4. Binding modules
========================================================================
  [OK]   require('errors.js') succeeded.
  [OK]   require('binding.js') succeeded.
  ... (13 行)

========================================================================
5. LingoFuse native library
========================================================================
  [OK]   Native library loaded successfully: 'LingoFuse64.dll'.

========================================================================
6. Native call round-trip
========================================================================
  [OK]   LF_CreateData returned a non-null handle.
  [OK]   LF_WriteBuffer wrote 4 bytes.
  [OK]   LF_ReadBuffer returned the exact bytes written.
  [OK]   LF_FreeData released the handle.

========================================================================
Report
========================================================================
  All checks passed. The environment is ready.
```

如果某一节报 `[FAIL]`，见[故障排查](#7-故障排查)。

### 5.2 运行演示

```bash
node test/lf_js_helloworld.js
```

演示会创建一个自连通过程，注册三个 API（`add`、`echo`、`log`），
等待网络就绪，然后通过各自的路径调用每个 API。预期的最后一行：

```
=== demo completed successfully ===
```

### 5.3 运行测试套件

v1.0 基线套件（127 项）：

```bash
node test/test.js
```

预期输出（末尾摘要）：

```
Summary
  runtime : Node.js 24.21.0
  passed  : 127
  failed  : 0
  total   : 127
```

v2.0 新增套件（96 项）：

```bash
node test/test2.js
```

预期输出（末尾摘要）：

```
Summary
  runtime : Node.js 24.21.0
  passed  : 96
  failed  : 0
  total   : 96
```

两个套件合起来覆盖 **223 项**断言。

### 5.4 npm 脚本

如果你愿意，同样三条命令可以通过 npm 执行：

```bash
npm run check       # node check-env.js
npm run demo        # node test/lf_js_helloworld.js
npm test            # node test/test.js        (v1.0，127 项)
npm run test:v2     # node test/test2.js       (v2.0，96 项)
npm run test:all    # 依次运行两个套件
```

---

## 6. 在其他应用中使用本接口库

假设本接口库位于 `D:\CoreLibrary\LingoFuse\js\`，你的应用位于
`C:\temp\test_lf.js`。本节介绍四种引用方式。**不需要复制文件**：
拷贝方式要连 `node_modules/`（含 koffi 的原生二进制，约 8 MB）
一起搬，而且每次接口库更新都要重拷一次，还容易产生版本漂移。
以下任何一种方案都能避免这些问题。

### 6.0 四种引用方案对比

| 方案 | 命令复杂度 | 包更新后 | 需要管理员权限 | 适用场景 |
|------|:---------:|:--------:|:-------------:|----------|
| A  绝对路径 require      | 零           | 立即生效        | 不需要          | 快速验证、一次性脚本 |
| B  npm install 本地路径  | 一条命令     | 需重新 install  | 不需要          | 独立、长期项目 |
| C  npm link              | 两条命令     | 立即生效        | **通常需要**    | 开发调试接口库本身 |
| D  Windows 目录联接      | 两条命令     | 立即生效        | 不需要          | Windows 上开发调试 |

**推荐**：
- 只是验证一下 → A。
- `C:\temp\` 是长期项目，不打算频繁改接口库 → B。
- 正在调试接口库本身，希望改动立即生效 → C（macOS/Linux），D（Windows）。

---

### 6.1 方案 A —— 绝对路径 require

在你的脚本里直接写完整路径：

```javascript
"use strict";

const lf = require("D:/CoreLibrary/LingoFuse/js/index.js");

lf.loadLibrary();
console.log("library :", lf.libraryName());
console.log("runtime :", lf.platform().runtime);
```

Windows 上正斜杠 `/` 和反斜杠 `\\` 都接受，推荐正斜杠（免转义）。
Node 会以 `D:/CoreLibrary/LingoFuse/js/index.js` 所在目录为基准
解析它内部的所有 `require`，包括它自己去找的
`node_modules/koffi`，一切正常。

**优点**：零配置，路径写死但一目了然。
**缺点**：路径硬编码在源码里。若要换机器或换路径，需要改代码。

---

### 6.2 方案 B —— npm install 本地路径

```powershell
cd C:\temp
npm init -y                                    # 如果还没有 package.json
npm install D:\CoreLibrary\LingoFuse\js
```

npm 会把 `js\` 整个复制到 `C:\temp\node_modules\lingofuse-js\`。
之后 `test_lf.js` 写：

```javascript
"use strict";

const lf = require("lingofuse-js");

lf.loadLibrary();
console.log("library :", lf.libraryName());
```

**优点**：符合 Node 标准，包名引用与从 npm registry 安装的用法
一致；`package.json` 里会记录依赖版本（显示为 `"file:../path"`
形式）。
**缺点**：包更新后需要重新 `npm install D:\CoreLibrary\LingoFuse\js`。

---

### 6.3 方案 C —— npm link

两步设置。

**第 1 步** —— 在包目录里注册全局链接：

```powershell
cd D:\CoreLibrary\LingoFuse\js
npm link
```

**第 2 步** —— 在你的项目里链接到它：

```powershell
cd C:\temp
npm init -y
npm link lingofuse-js
```

`npm link` 在 `C:\temp\node_modules\lingofuse-js` 创建一个符号
链接，指向 `D:\CoreLibrary\LingoFuse\js\`。之后 `test_lf.js` 同样
写：

```javascript
const lf = require("lingofuse-js");
```

**优点**：修改接口库源码后立即生效，无需重新安装。
**缺点**：Windows 上创建符号链接通常需要**管理员权限**或**开启
开发者模式**。如果失败了，请用方案 D。

---

### 6.4 方案 D —— Windows 目录联接

Windows 的 **junction** 不需要管理员权限，是 `npm link` 在
Windows 上更实用的替代。

**第 1 步** —— 创建 `node_modules` 目录（如果还不存在）和联接：

```powershell
cd C:\temp
mkdir node_modules -Force
cmd /c mklink /J node_modules\lingofuse-js D:\CoreLibrary\LingoFuse\js
```

**第 2 步** —— 照常引用：

```javascript
"use strict";

const lf = require("lingofuse-js");

lf.loadLibrary();
console.log("library :", lf.libraryName());
```

`node_modules/lingofuse-js` 本质上是一个指向
`D:\CoreLibrary\LingoFuse\js\` 的透明目录，读它的内容和直接读原
目录一样，写也一样。

**查看/删除联接**：

```powershell
# 查看
dir C:\temp\node_modules

# 删除（只删链接本身，不影响原目录）
cmd /c rmdir C:\temp\node_modules\lingofuse-js
```

**优点**：不需要管理员权限；改动接口库后立即生效；删除联接是
纯删除链接，安全。
**缺点**：Windows 特有。Linux/macOS 用 `ln -s` 或方案 B/C。

---

### 6.5 完整最小示例

以方案 A 为例，`C:\temp\test_lf.js`：

```javascript
"use strict";

const lf = require("D:/CoreLibrary/LingoFuse/js/index.js");

// 1. 加载运行时。
lf.loadLibrary();
console.log("library :", lf.libraryName());
console.log("runtime :", lf.platform().runtime);

// 2. 建一个应用，注册一个 API。
const app = new lf.AppHandle("QuickTest", "absolute-path require test");

app.registerCall("ping", "Return pong", (input, output) => {
    lf.io.writeJson(output, { pong: true });
});

// 3. 起一个自连通的端点。
lf.framework.setOption("Wait_Ready", "False");
lf.framework.resetPrepare();
lf.framework.prepareService("ipc:quicktest", "ipc:quicktest");
lf.framework.prepareClient("ipc:quicktest", app);

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

// 4. 等应用在 mesh 上可见。
(async () => {
    for (let i = 0; i < 100; i++) {
        if (lf.status.checkApi("QuickTest", "ping")) break;
        await new Promise((r) => setTimeout(r, 100));
    }

    // 5. 调用。
    const param = new lf.DataHandle("ping");
    lf.io.writeJson(param, {});

    const result = app.localCall(param);
    console.log("response:", lf.io.readJson(result));

    // 6. 清理。
    param.dispose();
    result.dispose();
    app.dispose();
    lf.framework.exitMainThread();
    lf.framework.shutdown();
})();
```

运行：

```powershell
cd C:\temp
node test_lf.js
```

预期输出：

```
library : LingoFuse64.dll
runtime : node
response: { pong: true }
```

如果你改用方案 B/C/D，只需把第一行的 require 换成：

```javascript
const lf = require("lingofuse-js");
```

其余代码不变。

---

### 6.6 `require` 路径不能指到目录

**这是最常见的坑**。

下面这种写法**一定会失败**：

```javascript
const lf = require("D:/CoreLibrary/LingoFuse/js");   // ❌ 报错
```

Node 只在 `node_modules/` 里做 "自动查找 index.js 或
package.json" 的目录解析。绝对路径或相对路径直接指向一个目录时，
Node 不会自动补 `index.js`。

**两种正确做法**：

- 方案 A 里写全路径：`require("D:/CoreLibrary/LingoFuse/js/index.js")`。
- 方案 B/C/D 里用包名：`require("lingofuse-js")`（该名字通过
  `node_modules` 目录被解析）。

---

### 6.7 CommonJS 用法

```javascript
"use strict";

const lf = require("lingofuse-js");

// 加载运行时（幂等；可省略）。
lf.loadLibrary();

// 访问七个命名空间。
lf.io;         // JSON / 字符串 / 字节 I/O
lf.framework;  // 进程级 ABI 门面
lf.network;    // 连接 / 断开事件
lf.status;     // 状态队列与健康检查
lf.options;    // typed 运行时选项             【v2.0 新增】
lf.address;    // 三种寻址模式                 【v2.0 新增】
lf.async;      // 异步子系统                   【v2.0 新增】

// 顶层类型。
const dh = new lf.DataHandle("my_api");
const app = new lf.AppHandle("MyApp", "description");

// 顶层寻址快捷（等价于 lf.address.AppTarget 等）。
const t = new lf.AppTarget("MyApp");
```

### 6.8 ESM 用法

```javascript
import lf from "lingofuse-js";
import { DataHandle, AppHandle, io, framework } from "lingofuse-js";

lf.loadLibrary();
const dh = new DataHandle("my_api");
io.writeJson(dh, { hello: "world" });
```

两种风格访问的是同一个单例。在同一进程中混用是安全的。

### 6.9 最简 Call API 示例

一个完整地暴露 "add" API 的服务端：

```javascript
"use strict";

const lf = require("lingofuse-js");

function main() {
    // 1. 加载运行时。
    lf.loadLibrary();

    // 2. 安装回调错误报告器（可选但推荐）。
    lf.framework.setCallbackErrorHandler((source, err) => {
        console.error(`[lf] callback failed in ${source}:`, err);
    });

    // 3. 创建应用。
    const app = new lf.AppHandle("Calculator", "Add two integers");

    // 4. 注册一个 Call API。
    app.registerCall("add", "Add two integers", (input, output) => {
        const req = lf.io.readJson(input);
        const a = Number(req.a) || 0;
        const b = Number(req.b) || 0;
        lf.io.writeJson(output, { result: a + b });
    });

    // 5. 准备框架。本例是自连通的：一个端点同时充当服务端和客户端。
    lf.framework.setOption("Wait_Ready", "False");
    lf.framework.resetPrepare();
    lf.framework.prepareService("ipc:calc", "ipc:calc");
    lf.framework.prepareClient("ipc:calc", app);

    if (lf.framework.prepareDone() !== 1) {
        throw new Error("framework startup failed");
    }

    // 6. 等待应用在网络中可见。
    //    为什么必须这样做，见 §6.9.1。
    waitForApp("Calculator", "add", 10000).then((visible) => {
        if (!visible) {
            throw new Error("app did not become visible in time");
        }
        console.log("ready");

        // 7. 调用 API。
        const param = new lf.DataHandle("add");
        lf.io.writeJson(param, { a: 40, b: 2 });

        const result = app.localCall(param);
        const response = lf.io.readJson(result);
        console.log("result:", response.result);   // 42

        // 8. 清理。
        param.dispose();
        result.dispose();
        app.dispose();
        lf.framework.exitMainThread();
        lf.framework.shutdown();
    });
}

async function waitForApp(appName, apiName, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (lf.status.checkApp(appName) &&
            (apiName === null || lf.status.checkApi(appName, apiName))) {
            return true;
        }
        await new Promise((r) => setTimeout(r, 100));
    }
    return false;
}

main();
```

#### 6.9.1 `waitForApp` 模式

如果你禁用了 `Wait_Ready`（上面示例就是这样做的），
`prepareDone()` 会在框架事件循环一开始时就返回。客户端到服务端的
连接、以及随后的服务端 API 信息广播，都是异步的。在这个窗口期内，
客户端的本地缓存不知道应用存在，任何过早发出的调用都会超时。

`waitForApp` 辅助函数轮询 `checkApp` 和 `checkApi`，直到目标可见。
这是**每一个**生产程序在禁用 `Wait_Ready` 时都必须使用的模式。

另一种做法是保持 `Wait_Ready` 为默认值（`"True"`），让
`prepareDone()` 阻塞直到所有已准备的客户端就绪。这更简单，但会
增加启动延迟。完整的取舍讨论见 LingoFuse C++ 知识库。

### 6.10 最简 Notify API 示例

```javascript
"use strict";

const lf = require("lingofuse-js");

lf.loadLibrary();

const app = new lf.AppHandle("Logger", "One-way logger");

app.registerNotify("log", "Log a message", (input) => {
    const payload = lf.io.readJson(input);
    console.log("[remote log]", JSON.stringify(payload));
});

lf.framework.setOption("Wait_Ready", "False");
lf.framework.resetPrepare();
lf.framework.prepareService("ipc:logger", "ipc:logger");
lf.framework.prepareClient("ipc:logger", app);

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

(async () => {
    // 等待可见（理由同 §6.9.1）。
    for (let i = 0; i < 100; i++) {
        if (lf.status.checkApi("Logger", "log")) break;
        await new Promise((r) => setTimeout(r, 100));
    }

    // 发送一个通知。
    const param = new lf.DataHandle("log");
    lf.io.writeJson(param, { level: "info", message: "hello" });

    app.localNotify(param);
    param.dispose();

    // 给回调留出运行时间，再开始拆解。
    await new Promise((r) => setTimeout(r, 200));

    lf.framework.exitMainThread();
    app.dispose();
    lf.framework.shutdown();
})();
```

### 6.11 纯客户端示例

一个只消费另一个进程的 API 的进程：

```javascript
"use strict";

const lf = require("lingofuse-js");

lf.loadLibrary();

// 准备一个不带应用的客户端。这是一个纯消费者。
lf.framework.setOption("Wait_Ready", "False");
lf.framework.resetPrepare();
lf.framework.prepareClient("ipc:calc", null);

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

(async () => {
    // 等待目标应用可见。
    for (let i = 0; i < 100; i++) {
        if (lf.status.checkApp("Calculator")) break;
        await new Promise((r) => setTimeout(r, 100));
    }

    // 调用远程 API。在这个跨进程的场景里，LF_Call 会通过 IPC
    // 路由请求。
    const param = new lf.DataHandle("add");
    lf.io.writeJson(param, { a: 5, b: 7 });

    const result = lf.framework.call("Calculator", param, 5000);
    if (result.size === 0) {
        console.error("call failed: timeout or target not found");
    } else {
        const response = lf.io.readJson(result);
        console.log("5 + 7 =", response.result);
    }

    param.dispose();
    result.dispose();

    lf.framework.exitMainThread();
    lf.framework.shutdown();
})();
```

注意：客户端没有创建 `AppHandle`。纯消费者从不需要它。

### 6.12 `tryCall` 与 `call` 的选择

框架提供两个同步远程调用入口，行为差异在**失败时返回什么**：

| 场景 | `framework.call(app, param, timeout)` | `framework.tryCall(app, param, timeout)` |
|---|---|---|
| 正常返回 | `DataHandle`（`size > 0`） | `DataHandle`（`size > 0`） |
| 超时 | `DataHandle`（`size == 0`） | `null` |
| 目标不可达 | `DataHandle`（`size == 0`） | `null` |

**推荐用法**：

```javascript
// 只关心"成功/失败"，不区分超时和空响应：
const response = lf.framework.tryCall("Calc", param, 3000);
if (response === null) {
    console.log("call failed");
} else {
    console.log(lf.io.readJson(response));
    response.dispose();
}

// 需要区分"超时"和"服务返回了空响应"：
const response2 = lf.framework.call("Calc", param, 3000);
if (response2.size === 0) {
    // 两者都有可能
} else {
    // 服务返回了非空响应
}
response2.dispose();
```

**所有权**：`tryCall` 返回 `null` 时已自动释放内部句柄；返回
`DataHandle` 时，调用者负责 `dispose`。这一契约与 C# 的
`Framework.TryCall` 完全一致。

### 6.13 永久句柄与短生命周期句柄

框架提供两种数据句柄，生命周期不同：

| 类型 | 创建方式 | 空闲回收 | `dispose()` 语义 |
|---|---|---|---|
| **自动回收** | `new DataHandle(apiName)` | 10 分钟未访问后由池回收 | 只标记删除；实际释放在下一次池扫描（≤ 5 秒） |
| **永久** | `DataHandle.createPermanent(apiName)` | **永不自动回收** | **同步**立即释放 |

**默认使用自动回收句柄**。池子会在你忘记 `dispose` 时兜底。

**仅在以下场景使用永久句柄**：

- 需要跨整个进程生命周期持有（缓存请求模板、全局注册表）。
- 需要避免 10 分钟空闲回收造成的悬空风险。
- 长耗时操作且无法保证每 10 分钟刷新一次访问时间戳。

**永久句柄的两个陷阱**：

1. **"永久"不等于"永不释放"**。你必须显式 `dispose`，否则整个进程生命周期内泄漏。
2. **no-op 窗口**：在 `prepareDone()` 之前或 `exitMainThread()` 之后创建并 `dispose` 的永久句柄，由于主线程未激活，`LF_FreeData` 是 no-op。此时创建的句柄会一直保留到进程退出（或 `shutdown()` 释放）。

**示例**：

```javascript
// 短生命周期：用默认构造
{
    const param = new lf.DataHandle("myapi");
    lf.io.writeJson(param, payload);
    const result = lf.framework.call("Target", param, 3000);
    result.dispose();
    param.dispose();
}

// 进程生命周期：用 createPermanent
const cachedTemplate = lf.DataHandle.createPermanent("myapi");
lf.io.writeJson(cachedTemplate, { template: true });

// ... 整个进程生命周期内可反复使用，无需担心 10 分钟超时 ...

// 退出前显式释放
cachedTemplate.dispose();
lf.framework.shutdown();
```

### 6.14 JSON 载荷约定

本接口库在所有语言之间强制同一套序列化策略：

- **紧凑** JSON。无缩进，无尾随换行。
- **字面 UTF-8** 表示非 ASCII 字符。`你好` 写成三个 UTF-8
  字节，而不是 `\u4f60\u597d`。
- **单个 NUL 字节**追加到每个字符串和 JSON 载荷之后。
- **容错读取**：缺少尾随 NUL 的载荷也会被完整消费。

这使得 JavaScript 发出的字节序列与 Pascal、Python、C++、C# 为
同一逻辑值发出的字节序列完全相同：

```
{"a":1}
→ 7B 22 61 22 3A 31 7D 00
```

不要绕过 `lf.io` 辅助函数。直接调用 `LF_WriteBuffer` /
`LF_ReadBuffer` 是可能的，但会破坏跨语言契约。

完整的线格式契约见 `lf-io.js` 的文件头。

---

### 6.15 三种调用风格（v2.0 新增）

LingoFuse JS 绑定提供**三种平行的调用风格**。三者共享同一个
`AsyncBridge` 子系统，可以随意混用，但每种风格适合不同的业务
场景。

| 风格 | 入口 | 阻塞？ | 适合 |
|------|------|:------:|------|
| **A. 内联回调** | `target.callAsync(api, payload, (r, e) => {...})` | 否 | 事件驱动代码、简单业务、不想引入 `async` |
| **B. async/await** | `await target.call(api, payload)` | 否（挂起） | 现代 async 业务代码、需要串行逻辑 |
| **C. 同步** | `target.callSync(api, payload)` | 是 | 脚本、测试、CLI 工具 |

#### 6.15.1 风格 A —— 内联回调

**最适合把业务代码直接写在回调体里**，无需 `await`、无需
`Promise` 包装。

```javascript
const target = new lf.AppTarget("Calculator");

target.callAsync("add", { a: 5, b: 7 }, (result, error, userData) => {
    // 业务代码直接写在这里
    if (error) {
        console.error("call failed:", error);
        return;
    }
    console.log("result:", result);   // { result: 12 }
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
- 回调内**不要**调用任何同步的 LingoFuse 函数（如
  `target.callSync`）—— 会死锁。
- 回调体抛出的异常会被吞掉并写入 stderr；不会传回 native 栈。

#### 6.15.2 风格 B —— async/await

`target.call(api, payload, { timeoutMs })` 返回一个 `CallPromise`
（thenable）。用 `await` 拿结果：

```javascript
const target = new lf.AppTarget("Calculator");

try {
    const result = await target.call("add", { a: 5, b: 7 }, { timeoutMs: 3000 });
    console.log("result:", result);   // { result: 12 }
} catch (err) {
    if (err instanceof lf.LingoFuseTimeoutError) {
        console.error("timed out; err.abandoned =", true);
    } else {
        console.error("call failed:", err);
    }
}
```

**取消语义**：`CallPromise` **不是**标准 `Promise`，它带有一个
额外的 `abandoned` 标志。当 JS 侧的超时先于 native 回调到达时：

- `CallPromise` 会以 `LingoFuseTimeoutError` reject
- `abandoned` 变为 `true`
- **native 请求不会被取消**：`AsyncBridge` 会保留回调一个 grace
  周期，任何迟到的结果都被丢弃

这个设计的原因（以及为什么不能简单地取消）见 `async-support.js`
的文件头。

#### 6.15.3 风格 C —— 同步

```javascript
const target = new lf.AppTarget("Calculator");

const result = target.callSync("add", { a: 5, b: 7 }, { timeoutMs: 3000 });
console.log("result:", result);   // { result: 12 }
```

- **成功**返回反序列化后的值。
- **超时**抛 `LingoFuseTimeoutError`。
- **不可达**抛 `LingoFuseCallError`。

还有非抛异常版本：

```javascript
const result = target.tryCallSync("add", { a: 5, b: 7 }, { timeoutMs: 3000 });
if (result === null) {
    console.log("call failed");
} else {
    console.log("result:", result);
}
```

**警告**：`callSync` 会**阻塞 JS 事件循环**直到 native 调用返回。
仅用于脚本、测试、CLI 工具。不要在服务器热路径里使用。

#### 6.15.4 三者共享同一个 AsyncBridge

三种风格都走同一个进程级 `AsyncBridge`：

```javascript
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

`AsyncBridge` 是**单例**。三种风格的用户**共享同一份计数**。

---

### 6.16 三种寻址模式（v2.0 新增）

LingoFuse 支持三种**正交**的寻址模式。三者共享同一个调用接口
（`call` / `callAsync` / `callSync` / `tryCallSync` /
`sequencedCall` / `sequencedCallAsync` / `notify` /
`sequencedNotify`），只在**路由语义**上不同。

| Target 类型 | 路由键 | 本地优先？ | 负载均衡？ | 死掉后 |
|-------------|--------|:---------:|:---------:|--------|
| `AppTarget` | App 名（string） | ✅ 是 | ❌ N/A | 需重新注册 |
| `UIDTarget` | UID（32 字节） | ✅ 是 | ❌ N/A | **UID 已失效** |
| `P2PNameTarget` | 组名（string） | ❌ 否 | ✅ 是 | 转发到组内其他成员 |

#### 6.16.1 `AppTarget` —— 按应用名寻址

最常用的方式。路由到**任意**具有匹配名字的客户端。

```javascript
const target = new lf.AppTarget("Calculator");

const result = await target.call("add", { a: 1, b: 2 });
```

**本地优先**：如果调用者进程本身注册了同名 App 且暴露了目标 API，
调用会在**本地**完成，不经过网络。

```javascript
// 多客户端场景下，同名 App 会被 C4 mesh 自动负载均衡。
// 使用 "Least Recently Used" 策略。
```

#### 6.16.2 `UIDTarget` —— 按会话 UID 寻址

路由到**具体**的 32 字节会话。适合"我想给刚才那个客户端发消息"
这类场景。

```javascript
// UID 可以是 Uint8Array(32) 或 64 字符十六进制字符串。
const uidHex = "4fa01fc4a85b6099a037c5a3f01f49a89564268a2d7fd48009d636246cfc2633";
const target = new lf.UIDTarget(uidHex);

const result = await target.call("add", { a: 1, b: 2 });
```

**UID 可以打到目标上的任意 API**，不管它是 App 注册的（
`app.registerCall`）还是进程级 P2P 注册的
（`registerP2PCall`）—— 不需要知道目标 App 名。

**UID 生命周期**：UID 在每次 `TunnelLink` 时**重新生成**。调用方
如果缓存了 UID，**链路断开后必须重新探测**。

#### 6.16.3 `P2PNameTarget` —— 按组名寻址

路由到**任意**用户自定义组中的客户端。服务端**负载均衡**。

```javascript
const target = new lf.P2PNameTarget("workers");

// 服务端会在所有 P2PName = "workers" 的客户端中选一个
const result = await target.call("process", { task: "..." });
```

**不是本地优先**：即使调用者进程本身在目标组里，调用也会**转发
到服务端**做派发。这是刻意的：服务端拥有负载均衡状态。

**设置自己的组名**：

```javascript
lf.options.setOptP2PName("workers");
```

必须在 `prepareDone()` 之前设置，或者通过 `Update_UID` 命令
上报（每秒自动检查）。

#### 6.16.4 `hashKey()` —— 用于 Map / Set 的稳定键

JS 的 `Map` / `Set` 用**引用**比较键。如果你要把 Target 用作
字典键，用 `hashKey()`：

```javascript
const m = new Map();
m.set(new lf.AppTarget("X").hashKey(), 1);
m.get(new lf.AppTarget("X").hashKey());   // => 1
```

每种寻址模式返回带前缀的键：`app:X`、`uid:<hex64>`、`p2p:G`。
三种模式**不会**碰撞（即使字符串部分相同）。

---

### 6.17 typed options（v2.0 新增）

`lf.options` 命名空间提供 **16 对 typed setter/getter**，一一对应
Pascal / C# 绑定的 `LF_Set_Opt_*` / `LF_Get_Opt_*` 系列。

#### 6.17.1 完整的选项对照表

| Option | Setter / Getter | 类型 | 默认 |
|--------|-----------------|------|------|
| `password` | `setOptPassword` / `getOptPassword` | string | 空（返回固定掩码） |
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

#### 6.17.2 使用示例

```javascript
const lf = require("lingofuse-js");

// 加载库并设置选项。
lf.loadLibrary();

lf.options.setOptOverlapConnection(true);
lf.options.setOptWaitConnectionReadyOk(false);
lf.options.setOptP2PName("my_group");

// 读取选项。
console.log(lf.options.getOptP2PName());        // "my_group"
console.log(lf.options.getOptWaitConnectionReadyOk());  // false
```

#### 6.17.3 ⚠️ `LF_SetOption` 是异步投递的

一旦 LingoFuse 模拟主线程启动（即 `prepareDone()` 返回 1），
`LF_SetOption` 会通过 `MainThreadPost.PostM_NP(DoRun)` **投递到
主线程**并在下一个 tick 应用。**setter 返回后立即 getter 读到的是
旧值**。

```javascript
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

#### 6.17.4 未知选项名被静默忽略

`LF_SetOption` 没有返回值，收到不认识的选项名时**不会报错**。
typed 快捷函数通过硬编码选项名消除了这个失败模式，但
`lf.framework.setOption("Typo", "x")` 仍然会静默忽略。

#### 6.17.5 通用 `setOption` 仍然可用

typed 快捷函数是**叠加**在通用 API 之上的，不是替代：

```javascript
// 动态选项名（从配置文件读取）
const optionName = process.env.LF_OPTION_NAME || "Quiet";
lf.framework.setOption(optionName, "True");

// 或者读取原始字符串值
const raw = lf.framework.getOption("Quiet");   // "True" / "False" / ""
```

两条路径共享同一个底层 native 调用，混用是安全的。

---

### 6.18 P2P 身份读取（v2.0 新增）

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

#### 6.18.1 两个访问器

`DataHandle` 上有两个访问器：

```javascript
const uid  = input.getP2PUid();    // Uint8Array(32)
const name = input.getP2PName();   // string（未设置时返回 ""）
```

#### 6.18.2 只能在 INPUT 句柄上调用

| 位置 | 是否有效 |
|------|:--------:|
| 回调的 `input` 参数 | ✅ |
| 本地调用的 `input` | ✅ |
| 回调的 `output` 参数 | ❌（返回 32 个 0 / 空串） |
| 你 `new DataHandle(...)` 出来的自建句柄 | ❌（同上） |

对无效位置调用时，库**不抛异常**，而是返回默认值（32 个 0 /
空字符串），并在 native 侧记录一条警告。

#### 6.18.3 whoami 模式

**经典应用场景**：客户端想知道**自己的** UID（服务端看到的
"发送方 UID"）。

**服务端**：

```javascript
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

```javascript
const target = new lf.AppTarget("IdentitySvc");
const result = await target.call("whoami", {});

console.log("my UID:", result.uid_hex);   // 64 字符十六进制
console.log("my P2P:", result.p2p_name);  // 例如 "jstest2_group"

// 把 UID 存起来，之后可以用 UIDTarget 打到这个会话
const myUidTarget = new lf.UIDTarget(result.uid_hex);
```

#### 6.18.4 实现细节（v2.0 勘误）

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

#### 6.18.5 典型用途

| 场景 | 用法 |
|------|------|
| 调用鉴权 | 比较 `getP2PName()` 与白名单 |
| 审计日志 | 记录 `getP2PUid()`（十六进制）和 `getP2PName()` |
| 会话管理 | 以 UID 为 key 维护 Session |
| 多租户 | P2PName 作为租户标识 |
| 按组路由 | 按 P2PName 分流到不同 worker |
| whoami 探测 | 服务端返回调用方身份，客户端自我发现 |

#### 6.18.6 `getP2PUid` 与 `options.getOptP2PName` 的区别

这两个概念容易混淆：

| 函数 | 读什么 | 从哪读 |
|------|--------|--------|
| `lf.options.getOptP2PName()` | **我**声明的组名 | 本地配置 |
| `input.getP2PName()` | **发送方**声明的组名 | 侧数据（载荷头部） |

换句话说：

- `getOptP2PName()` 回答"我给**自己**设了什么组名？"
- `DataHandle.getP2PName()` 回答"**发消息给我的人**是什么组名？"

两者都是 UTF-8 字符串，但来源完全不同。

#### 6.18.7 进程级 P2P 注册（独立概念）

除了 `App.registerCall`（App 绑定注册），v2.0 还提供**进程级
P2P 注册**，API 只通过 UID 或 P2PName 寻址可达，**不通过 App
名可达**：

```javascript
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

---

## 7. 故障排查

### 7.1 `Cannot find module 'koffi'`

`node_modules/` 缺失或被删除。在 `js/` 目录下运行 `npm install`。

如果你把 JS 文件移到了其他目录，`node_modules/` 必须随之移动
（Node 从引用文件所在位置向上查找包）。

### 7.2 `Cannot find module './index.js'`

你从**不包含** `index.js` 的目录运行脚本。每个脚本
（`check-env.js`、`test/test.js`、`test/test2.js`、
`test/lf_js_helloworld.js`）都必须从 `js/` 目录、与绑定文件在同
一目录下运行。不要把脚本移入子目录。

### 7.3 `Failed to load the LingoFuse native library`

原生共享库不在任何搜索路径上。见
[§4 原生库放置](#4-原生库放置)。

查看接口库使用的精确搜索路径：

```bash
node -e "console.log(require('./binding.js').buildSearchPaths().join('\n'))"
```

### 7.4 `LF_CreateData` 返回 `null`

原生库加载成功，但符号解析到了错误或截断的版本。确保 DLL /
`.so` / `.dylib` 与接口库编写时对应的头文件版本一致
（LingoFuse 5.0+）。

### 7.5 `prepareDone()` 返回 `0`

`prepareDone` 每个进程只返回一次 1。第二次调用如果没有中间的
`shutdown()`，会返回 0。这不是失败。完整契约见 `framework.js`
文件头。

### 7.6 在 `prepareDone()` 之后调用立即超时

见 [§6.9.1](#691-waitforapp-模式)。`prepareDone()` 返回的那一刻
框架不一定可用。在发出任何调用之前先等 `checkApp` 变为 true。

### 7.7 回调抛出异常，进程静默退出

回调运行在原生工作线程上。未捕获的异常会跨入 C 栈。本接口库包装
了每一个回调以吞掉异常，并把它们路由到 `callbackErrorHandler`：

```javascript
lf.framework.setCallbackErrorHandler((source, err) => {
    console.error(`[lf] ${source}:`, err);
});
```

在注册任何 API 之前安装一次即可。

### 7.8 Deno 报告 `PermissionDenied`

Deno 需要显式权限：

```bash
deno run \
    --allow-ffi \
    --allow-read \
    --allow-env \
    --allow-net \
    your-script.ts
```

每个标志的原因见 [PORTABILITY.md](PORTABILITY.md) §4.2。

### 7.9 用 `require("D:\\...\\js")` 报 `Cannot find module`

见 [§6.6](#66-require-路径不能指到目录)。绝对路径必须指向
`index.js` 文件，不能指向 `js` 目录。

### 7.10 `getAppName` 对已销毁的句柄抛出 `LingoFuseObjectDisposedError`

这是**预期行为**。`AppHandle.raw` 在销毁后返回 `null` 而不抛异常，
但 `framework.getAppName` 会显式检查 `isValid`，并拒绝已销毁的句柄。
捕获异常或在使用前检查 `app.isValid`。

### 7.11 测试在 teardown 阶段卡死（v2.0 新增）

**现象**：所有测试 PASS，但 `Summary` 未打印，进程不退出。

**原因**：某个 native 调用触发了 Pascal 侧的 live query，留下一个
pending 的异步任务。当 `LF_ExitMainThread` 里的 `C40Clean()` 等待
该任务完成时，整个 native 主线程阻塞，进而阻塞调用
`LF_ExitMainThread` 的 JS 事件循环。

最常见的触发源是 `setOptDebug("<command>")`，其中 `<command>` 是
`service` / `tunnel` / `ZNet_Info` / `HPC_Thread_Info` /
`Instance_Info` 等。这些命令会创建一个短暂的 `TC40_Console_Help`
对象并执行 live query。

**诊断**：

1. **启用详细 native 日志**：在 `prepareDone` 之前调用
   ```javascript
   lf.options.setOptQuiet(false);
   lf.options.setOptShowThreadID(true);
   lf.options.setOptConsoleOutput(true);
   ```
   这样会打印 native 主线程每一步。

2. **在 teardown 每一步前后打日志**：
   ```javascript
   console.error("[after] step 3 begin: LF_ExitMainThread()");
   lf.framework.exitMainThread();
   console.error("[after] step 3 done");
   ```
   能定位到具体卡在哪一步。

3. **禁用 watchdog 观察**：
   ```bash
   LINGOFUSE_TEST_NO_WATCHDOG=1 node test/test2.js
   ```

**修复**：不要在测试里执行有副作用的 debug 命令。用无副作用的
占位符（如 `noop-for-test`）来验证 `setOptDebug` 的 API 契约。

**永久兜底**：v2.0 的 `test2.js` 内置一个**独立子进程 watchdog**
（90 秒后 SIGKILL 本进程）。这是唯一能绕过 JS 事件循环阻塞的
机制：任何 in-process timer 在事件循环冻结时都失效，而子进程有
自己的事件循环。

### 7.12 `LF_Get_P2P_UID` 的指针在 5 秒后失效

不要保存 native 侧返回的指针。用 `DataHandle.getP2PUid()`，它会
立即 `koffi.decode` 拷贝 32 字节：

```javascript
// ✅ 正确
const uid = input.getP2PUid();   // 立即拷贝

// ❌ 错误：不能直接拿 native 指针
const rawPtr = lf._binding.funcs.LF_Get_P2P_UID(input.raw);
// 5 秒后 rawPtr 指向的内存会被 native 侧释放
```

---

## 8. API 速查

本接口库暴露**七个命名空间**、**两种 RAII 句柄类型**、**三种
寻址目标类**，以及**一套八类的异常层级**。

### 8.1 顶层

| 符号                          | 说明                                       |
|-------------------------------|--------------------------------------------|
| `VERSION`                     | 绑定版本字符串（`"2.0.0"`）。              |
| `loadLibrary()`               | 主动加载原生库（幂等）。                   |
| `isLoaded()`                  | 原生库加载后返回 `true`。                  |
| `libraryName()`               | 平台相关的库文件名。                       |
| `platform()`                  | `{ platform, arch, runtime }` 摘要。       |
| `DataHandle`                  | 数据缓冲的 RAII 封装。                     |
| `AppHandle`                   | 应用的 RAII 封装。                         |
| `AppTarget`                   | 按 App 名寻址的目标（`lf.address.AppTarget` 的快捷）。 |
| `UIDTarget`                   | 按 UID 寻址的目标。                        |
| `P2PNameTarget`               | 按组名寻址的目标。                         |
| `CallPromise`                 | async/await 风格的 Promise 包装。          |
| `AsyncBridge`                 | 异步子系统单例。                           |
| `registerP2PCall()`           | 进程级 P2P Call 注册。                     |
| `registerP2PNotify()`         | 进程级 P2P Notify 注册。                   |
| `unregisterP2P()`             | 移除进程级 P2P API。                       |
| `io`                          | JSON / 字符串 / 字节 I/O 命名空间。        |
| `framework`                   | 进程级 ABI 门面。                          |
| `network`                     | 网络事件处理器。                           |
| `status`                      | 状态队列与健康检查。                       |
| `options`                     | typed 运行时选项。                         |
| `address`                     | 三种寻址模式。                             |
| `async`                       | 异步子系统（`AsyncBridge` / `AsyncOp` / `CallPromise` 等）。 |

### 8.2 `lf.io`

| 函数                               | 说明                                      |
|------------------------------------|-------------------------------------------|
| `dumps(value)`                     | 序列化为紧凑 JSON。                       |
| `loads(text)`                      | 解析 JSON；失败时抛异常。                 |
| `writeString(handle, str)`         | 写 UTF-8 + NUL。                          |
| `readString(handle)`               | 读 UTF-8，遇 NUL 停止。                   |
| `writeStringBytes(handle, bytes)`  | 写原始字节 + NUL。                        |
| `readStringBytes(handle)`          | 读原始字节，遇 NUL 停止。                 |
| `readAllBytes(handle)`             | 读取剩余全部。                            |
| `writeJson(handle, value)`         | 序列化 value，写 UTF-8 + NUL。            |
| `readJson(handle)`                 | 读 NUL 帧的 JSON。                        |
| `tryReadJson(handle)`              | 不抛异常的 `readJson`。                   |

### 8.3 `lf.framework`

| 函数                                    | 说明                              |
|-----------------------------------------|-----------------------------------|
| `setCallbackErrorHandler(fn)`           | 安装全局错误报告器。              |
| `resetPrepare()`                        | 清空准备队列。                    |
| `prepareService(listen, physics)`       | 准备一个服务端点。                |
| `prepareClient(physics, app)`           | 准备一个客户端连接。              |
| `prepareDone()`                         | 启动框架。                        |
| `exitMainThread()`                      | 请求优雅退出。                    |
| `setOption(name, value)`                | 调整运行时选项（通用）。          |
| `getOption(name)`                       | 读取运行时选项（通用）。          |
| `generateAppName()`                     | 生成唯一名称。                    |
| `getAppName(app)`                       | 查询 App 的权威名称。             |
| `call(appName, param, timeoutMs)`       | 同步远程调用。                    |
| `tryCall(appName, param, timeoutMs)`    | 超时/不可达时返回 `null` 的 `call`。 |
| `notify(appName, param)`                | 单向通知。                        |
| `sequencedNotify(appName, param)`       | FIFO 单向通知。                   |
| `callAsync(appName, param, cb, data)`   | 内联回调式异步调用。              |
| `callPromise(appName, param, timeoutMs)`| Promise 式异步调用。              |
| `uidCall(uid, param, timeoutMs)`        | 同步 UID 调用。                   |
| `uidCallAsync(uid, param, cb, data)`    | 内联回调式 UID 调用。             |
| `uidCallPromise(uid, param, timeoutMs)` | Promise 式 UID 调用。             |
| `uidNotify(uid, param)`                 | 单向 UID 通知。                   |
| `uidSequencedNotify(uid, param)`        | FIFO 单向 UID 通知。              |
| `p2pnameCall(name, param, timeoutMs)`   | 同步 P2PName 调用。               |
| `p2pnameCallAsync(name, param, cb, data)`| 内联回调式 P2PName 调用。         |
| `p2pnameCallPromise(name, param, timeoutMs)`| Promise 式 P2PName 调用。       |
| `p2pnameNotify(name, param)`            | 单向 P2PName 通知。               |
| `p2pnameSequencedNotify(name, param)`   | FIFO 单向 P2PName 通知。          |
| `shutdown()`                            | 完全关闭。                        |

### 8.4 `lf.network`

| 函数                                       | 说明                            |
|--------------------------------------------|---------------------------------|
| `setNetworkEvent(onConnect, onDisconnect)` | 安装连接 / 断开处理器。         |
| `clearNetworkEvent()`                      | 移除两个处理器。                |
| `isNetworkEventInstalled()`                | 至少安装了一个时返回 true。     |
| `NetworkEventListener`                     | 面向对象监听器的基类。          |
| `setNetworkEventListener(listener)`        | 安装一个监听器实例。            |

### 8.5 `lf.status`

| 函数                            | 说明                                 |
|---------------------------------|--------------------------------------|
| `getStatusCount()`              | 队列中待处理的消息数。               |
| `getStatus()`                   | 弹出下一条消息。                     |
| `drainStatus(maxMessages)`      | 最多弹出 N 条。                      |
| `postStatus(message)`           | 推入一条消息（主线程未运行也入队）。 |
| `checkMainThread()`             | 框架是否运行中？                     |
| `checkApp(appName)`             | 应用是否可见？                       |
| `checkApi(appName, apiName)`    | API 是否可见？                       |
| `checkUid(uid)`                 | UID 是否可见？                       |
| `checkUidApi(uid, apiName)`     | UID 上的 API 是否可见？              |
| `checkP2PName(p2pName)`         | 组名是否可见？                       |
| `checkP2PNameApi(p2pName, apiName)`| 组上的 API 是否可见？             |

### 8.6 `lf.options`

每个选项一对 setter / getter。完整列表见
[§6.17.1](#6171-完整的选项对照表)。

### 8.7 `lf.address`

| 类              | 说明                                       |
|-----------------|--------------------------------------------|
| `Target`        | 抽象基类（不直接使用）。                   |
| `AppTarget`     | 按 App 名寻址。                            |
| `UIDTarget`     | 按 UID 寻址。                              |
| `P2PNameTarget` | 按组名寻址。                               |

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

### 8.8 `lf.async`

| 符号 | 说明 |
|------|------|
| `AsyncBridge` | 进程级单例。`instance()` / `shutdownInstance()` / `stats()` |
| `AsyncOp` | 单次异步操作的状态持有者。 |
| `CallPromise` | Promise 包装，带 `abandoned` 标志。 |
| `makeLegacyOp` | 底层工厂：构建 legacy 回调风格的 op。 |
| `makeFutureOp` | 底层工厂：构建 op + CallPromise 对。 |
| `runAsyncWithPromise` | 一站式：构建 + 派发 + 设超时。 |
| `runLegacyOp` | 一站式：legacy 回调风格。 |

### 8.9 `DataHandle`

通过 `new lf.DataHandle("api_name")` 创建自动回收句柄；
通过 `lf.DataHandle.createPermanent("api_name")` 创建永久句柄。
使用完毕后一定要调用 `dispose()`，或者在回调内部使用（此时接口库
自动管理其生命周期）。

| 方法 / 属性                                | 说明                       |
|--------------------------------------------|----------------------------|
| `DataHandle.createPermanent(apiName)`      | 静态工厂：创建永久句柄。   |
| `DataHandle.fromRaw(raw, owned)`           | 包装已有指针（内部使用）。 |
| `writeBytes(bytes)` / `readBytes(n)`       | 原始字节 I/O。             |
| `readBytesExact(n)` / `tryReadBytes(n)`    | 定长字节 I/O。             |
| `readAllBytes()`                           | 读到缓冲区末尾。           |
| `writeInt8` … `writeDouble`                | 小端原子写。               |
| `readInt8` … `readDouble`                  | 小端原子读。               |
| `tryReadInt8` … `tryReadDouble`            | 不抛异常的原子读。         |
| `writeString(s)` / `readString()`          | NUL 帧的 UTF-8。           |
| `tryReadString()`                          | 不抛异常的 `readString`。  |
| `writeUid(uid)` / `readUid()`              | 32 字节 UID 读写（无 NUL）。 |
| `getP2PUid()`                              | 读发送方 UID（仅 INPUT）。 |
| `getP2PName()`                             | 读发送方组名（仅 INPUT）。 |
| `position` / `size`                        | 游标和缓冲区大小。         |
| `getBufferPointer()`                       | 内部缓冲区的原生指针。     |
| `dispose()`                                | 释放原生句柄。             |
| `isValid` / `isOwning` / `raw`             | 状态访问器。               |

### 8.10 `AppHandle`

通过 `new lf.AppHandle("name", "description")` 创建。使用完毕后
一定要调用 `dispose()`。

| 方法                                          | 说明                  |
|-----------------------------------------------|-----------------------|
| `registerCall(name, desc, handler)`           | 注册一个 Call API。   |
| `registerNotify(name, desc, handler)`         | 注册一个 Notify API。 |
| `unregister(name)`                            | 移除已注册的 API。    |
| `localCall(param)` / `localNotify(param)`     | 进程内调用。          |
| `bind()`                                      | 绑定到空闲客户端。    |
| `dispose()`                                   | 解除关联并停止线程。  |
| `name` / `isValid` / `raw`                    | 状态访问器。          |

### 8.11 异常层级

| 类型                            | 基类                        | 附加字段                |
|---------------------------------|-----------------------------|-------------------------|
| `LingoFuseError`                | `Error`                     | `cause`                 |
| `LingoFuseLibraryLoadError`     | `LingoFuseError`            | `libraryName`           |
| `LingoFuseCallError`            | `LingoFuseError`            | `targetApp`, `targetApi`|
| `LingoFuseTimeoutError`         | `LingoFuseError`            | `targetApp`, `targetApi`, `timeoutMs` |
| `LingoFuseIoError`              | `LingoFuseError`            | `operation`             |
| `LingoFuseObjectDisposedError`  | `LingoFuseError`            | `objectName`            |
| `LingoFuseCallbackError`        | `LingoFuseError`            | `source`, `originalCause` |
| `LingoFuseRegistrationError`    | `LingoFuseError`            | `apiName`               |

**捕获策略**：捕获 `LingoFuseError` 即可覆盖所有本接口库抛出的
异常；需要细化处理时按子类 `instanceof` 判断。

```javascript
try {
    // ... LingoFuse 操作 ...
} catch (err) {
    if (err instanceof lf.LingoFuseTimeoutError) {
        console.error("超时:", err.targetApp, err.timeoutMs);
    } else if (err instanceof lf.LingoFuseCallError) {
        console.error("调用失败:", err.targetApp, err.message);
    } else if (err instanceof lf.LingoFuseError) {
        console.error("LingoFuse 错误:", err.message);
    } else {
        throw err;      // 不是本接口库抛的，重新抛出
    }
}
```

---

## 附录 A —— 跨语言兼容性

本接口库与以下语言**字节兼容**：

| 语言    | 文件                          |
|---------|-------------------------------|
| C       | `LingoFuse.h` / `LingoFuse.c` |
| C++     | `LingoFuse.hpp` / `lf_io.hpp` |
| C#      | `LingoFuse.cs` / `LfIo.cs`    |
| Pascal  | `lingofuse_import.pas`        |
| Python  | `lingofuse.lf_io`             |
| JS      | 本包                          |

同一个 JSON 载荷在每个绑定上产生相同的线字节，读取语义也一致。
跨语言 RPC 无需任何转码层。

## 附录 B —— 与 C++ / C# 的 API 对应

| 功能                | C++                                | C#                                | JS                                     |
|---------------------|------------------------------------|-----------------------------------|----------------------------------------|
| 加载运行时          | `LF_LoadLibrary()`                 | 自动（CLR 惰性加载）              | `lf.loadLibrary()`（幂等；也可省略）   |
| 创建数据句柄        | `DataHandle dh("api")`             | `new DataHandle("api")`           | `new lf.DataHandle("api")`             |
| 创建永久句柄        | `DataHandle::createPermanent(...)` | `DataHandle.CreatePermanent(...)` | `lf.DataHandle.createPermanent(...)`   |
| 写 JSON             | `dh.writeJson(obj)`                | `LfIo.WriteJson(dh, obj)`         | `lf.io.writeJson(dh, obj)`             |
| 读 JSON             | `dh.readJson()`                    | `LfIo.ReadJson<T>(dh)`            | `lf.io.readJson(dh)`                   |
| 远程调用（显式）    | `lingofuse::call(...)`             | `Framework.Call(...)`             | `lf.framework.call(...)`               |
| 远程调用（try）     | `lingofuse::tryCall(...)`          | `Framework.TryCall(...)`          | `lf.framework.tryCall(...)`            |
| **三种风格调用**    | `call` / `callAsync` / `tryCall`   | `Call` / `CallAsync` / `TryCall`  | `call` / `callAsync` / `callSync`      |
| **App 寻址**        | `lingofuse::AppTarget`             | `Framework.AppTarget`             | `new lf.AppTarget(...)`                |
| **UID 寻址**        | `lingofuse::UIDTarget`             | `Framework.UIDTarget`             | `new lf.UIDTarget(...)`                |
| **P2PName 寻址**    | `lingofuse::P2PNameTarget`         | `Framework.P2PNameTarget`         | `new lf.P2PNameTarget(...)`            |
| **typed options**   | `LF_Set_Opt_*` / `LF_Get_Opt_*`    | `Lf.SetOpt*` / `Lf.GetOpt*`       | `lf.options.setOpt* / getOpt*`         |
| **P2P 身份读**      | `dh.getP2PUid()` / `getP2PName()`  | `dh.GetP2PUid()` / `GetP2PName()` | `dh.getP2PUid()` / `dh.getP2PName()`   |
| 生成唯一名          | `generateAppName()`                | `Framework.GenerateAppName()`     | `lf.framework.generateAppName()`       |
| 查询 App 权威名     | `getAppName(app)`                  | `Framework.GetAppName(app)`       | `lf.framework.getAppName(app)`         |
| 回调错误报告        | 无（异常被吞）                     | `Framework.CallbackErrorHandler`  | `lf.framework.setCallbackErrorHandler` |
| 关闭                | `shutdown()`                       | `Framework.Shutdown()`            | `lf.framework.shutdown()`              |

## 附录 C —— 延伸阅读

- [PORTABILITY.md](PORTABILITY.md) —— 各运行时的详细说明。
- `lf-io.js` 文件头 —— 完整的线格式和序列化策略。
- `data-handle.js` 文件头 —— 所有权、I/O 失败语义、两种句柄。
- `app-handle.js` 文件头 —— 回调生命周期和线程模型。
- `framework.js` 文件头 —— 进程级契约和数值参数。
- `binding.js` 文件头 —— Koffi 声明和平台探测。
- `address.js` 文件头 —— 三种寻址模式的语义。
- `async-support.js` 文件头 —— 异步子系统的设计动机和状态机。
- `options.js` 文件头 —— typed 选项的用途和陷阱。
- `p2p-registration.js` 文件头 —— 进程级 P2P 命名空间的隔离。

## 附录 D —— 许可证

MIT。见 `package.json` 的 `license` 字段。
