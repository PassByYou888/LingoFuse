# LingoFuse JavaScript 接口库

**LingoFuse** 分布式 RPC 框架的跨平台 JavaScript 绑定。支持
**Node.js**、**Deno**（2.x）和 **Bun**。通过 [Koffi](https://koffi.dev/) 调用 LingoFuse 原生库的 C ABI。

本绑定由一个 CommonJS 核心和一个轻量 ESM 包装组成，与 C++、C#、
Pascal 各版本一一对应：

- 相同的 36 个导出 C 函数。
- 相同的 NUL 结尾 UTF-8 线格式。
- 相同的 JSON 序列化策略（紧凑、字面 UTF-8、无 `\uXXXX` 转义）。
- 相同的字符串三态容错读取。

在一个绑定上能工作的逻辑，在其他绑定上也一样。

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
   - [6.12 JSON 载荷约定](#612-json-载荷约定)
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
├── lf_js_helloworld.js        端到端演示
├── test.js                    测试套件（node:test）
├── package.json
├── index.js                   CommonJS 入口
├── index.mjs                  ESM 入口
├── errors.js                  异常层级
├── binding.js                 Koffi 声明与库加载
├── data-handle.js             TDataHnd 的 RAII 封装
├── app-handle.js              TAppHnd 的 RAII 封装
├── lf-io.js                   JSON / 字符串 / 字节 I/O
├── framework.js               进程级 ABI 门面
├── network-events.js          连接 / 断开事件处理器
├── status.js                  状态队列与健康检查
├── PORTABILITY.md             各运行时的专项说明
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
  ...

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
node lf_js_helloworld.js
```

演示会创建一个自连通过程，注册三个 API（`add`、`echo`、`log`），
等待网络就绪，然后通过各自的路径调用每个 API。预期的最后一行：

```
=== demo completed successfully ===
```

### 5.3 运行测试套件

```bash
node --test test.js
```

预期输出：

```
ℹ tests 116
ℹ suites 9
ℹ pass 116
ℹ fail 0
```

### 5.4 npm 脚本

如果你愿意，同样三条命令可以通过 npm 执行：

```bash
npm run check      # node check-env.js
npm run demo       # node lf_js_helloworld.js
npm test           # node --test test.js
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

// 访问四个命名空间。
lf.io;         // JSON / 字符串 / 字节 I/O
lf.framework;  // 进程级 ABI 门面
lf.network;    // 连接 / 断开事件
lf.status;     // 状态队列与健康检查

// 顶层类型。
const dh = new lf.DataHandle("my_api");
const app = new lf.AppHandle("MyApp", "description");
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

### 6.12 JSON 载荷约定

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

## 7. 故障排查

### 7.1 `Cannot find module 'koffi'`

`node_modules/` 缺失或被删除。在 `js/` 目录下运行 `npm install`。

如果你把 JS 文件移到了其他目录，`node_modules/` 必须随之移动
（Node 从引用文件所在位置向上查找包）。

### 7.2 `Cannot find module './index.js'`

你从**不包含** `index.js` 的目录运行脚本。每个脚本
（`check-env.js`、`test.js`、`lf_js_helloworld.js`）都必须从 `js/`
目录、与绑定文件在同一目录下运行。不要把脚本移入子目录。

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
（LingoFuse 3.0+）。

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

---

## 8. API 速查

本接口库暴露四个命名空间、两种 RAII 句柄类型，以及一套异常层级。

### 8.1 顶层

| 符号                          | 说明                                       |
|-------------------------------|--------------------------------------------|
| `VERSION`                     | 绑定版本字符串（`"1.0.0"`）。              |
| `loadLibrary()`               | 主动加载原生库（幂等）。                   |
| `isLoaded()`                  | 原生库加载后返回 `true`。                  |
| `libraryName()`               | 平台相关的库文件名。                       |
| `platform()`                  | `{ platform, arch, runtime }` 摘要。       |
| `DataHandle`                  | 数据缓冲的 RAII 封装。                     |
| `AppHandle`                   | 应用的 RAII 封装。                         |
| `io`                          | JSON / 字符串 / 字节 I/O 命名空间。        |
| `framework`                   | 进程级 ABI 门面。                          |
| `network`                     | 网络事件处理器。                           |
| `status`                      | 状态队列与健康检查。                       |
| `LingoFuseError`              | 基类异常。                                 |
| `LingoFuseLibraryLoadError`   | 库加载失败。                               |
| `LingoFuseCallError`          | 远程调用失败。                             |
| `LingoFuseIoError`            | 字节级 I/O 失败。                          |
| `LingoFuseObjectDisposedError`| dispose 后使用。                           |
| `LingoFuseCallbackError`      | 回调体失败。                               |

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
| `setOption(name, value)`                | 调整运行时选项。                  |
| `generateAppName()`                     | 生成唯一名称。                    |
| `call(appName, param, timeoutMs)`       | 同步远程调用。                    |
| `notify(appName, param)`                | 单向通知。                        |
| `sequencedNotify(appName, param)`       | FIFO 单向通知。                   |
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
| `postStatus(message)`           | 推入一条消息。                       |
| `checkMainThread()`             | 框架是否运行中？                     |
| `checkApp(appName)`             | 应用是否可见？                       |
| `checkApi(appName, apiName)`    | API 是否可见？                       |

### 8.6 `DataHandle`

通过 `new lf.DataHandle("api_name")` 创建。使用完毕后一定要调用
`dispose()`，或者在回调内部使用（此时接口库自动管理其生命周期）。

| 方法                                       | 说明                       |
|--------------------------------------------|----------------------------|
| `writeBytes(bytes)` / `readBytes(n)`       | 原始字节 I/O。             |
| `readBytesExact(n)` / `tryReadBytes(n)`    | 定长字节 I/O。             |
| `readAllBytes()`                           | 读到缓冲区末尾。           |
| `writeInt8` … `writeDouble`                | 小端原子写。               |
| `readInt8` … `readDouble`                  | 小端原子读。               |
| `writeString(s)` / `readString()`          | NUL 帧的 UTF-8。           |
| `position` / `size`                        | 游标和缓冲区大小。         |
| `dispose()`                                | 释放原生句柄。             |
| `isValid` / `isOwning` / `raw`             | 状态访问器。               |

### 8.7 `AppHandle`

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

## 附录 B —— 延伸阅读

- [PORTABILITY.md](PORTABILITY.md) —— 各运行时的详细说明。
- `lf-io.js` 文件头 —— 完整的线格式和序列化策略。
- `data-handle.js` 文件头 —— 所有权和 I/O 失败语义。
- `app-handle.js` 文件头 —— 回调生命周期和线程模型。
- `framework.js` 文件头 —— 进程级契约和数值参数。

## 附录 C —— 许可证

MIT。见 `package.json` 的 `license` 字段。
