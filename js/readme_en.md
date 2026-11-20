# The LingoFuse JavaScript interface library

> Chinese version: [readme.md](readme.md)

The cross-platform JavaScript binding for the **LingoFuse** distributed RPC framework. It supports
**Node.js**, **Deno** (2.x) and **Bun**, and calls the LingoFuse native library's C ABI through
[Koffi](https://koffi.dev/).

The binding consists of a CommonJS core plus a light ESM wrapper, and corresponds one-to-one with
the C++, C#, Pascal and Python versions:

- the same **59** exported C functions.
- the same NUL-terminated UTF-8 wire format.
- the same JSON serialization policy (compact, literal UTF-8, no `\uXXXX` escapes).
- the same three-state tolerant string reading.
- the same `tryCall` / `getAppName` / `createPermanent` convenience APIs.
- the same three addressing modes (App name / UID / P2PName).
- the same handle-ownership model (synchronous family / asynchronous family).
- the same P2P identity side-data semantics.

Logic that works on one binding works on the others too.

---

## What changed from v1.0 to v2.0

v1.0 was a straight C ABI translation layer: it covered only 37 of the 59 exported functions and
offered only App-name addressing and callback-style async.

v2.0 fills in the complete capability and builds a **business-facing abstraction layer** on top:

| Dimension | v1.0 | v2.0 |
|------|:----:|:----:|
| C ABI coverage | 37 / 59 | **59 / 59** |
| Call styles | inline callback + synchronous | inline callback + async/await + synchronous |
| Addressing modes | App name | App name / UID / P2PName |
| Runtime options | the generic `setOption` | generic + **16 typed pairs** |
| P2P identity reading | none | `DataHandle.getP2PUid` / `getP2PName` |
| Global P2P registration | none | `registerP2PCall` / `registerP2PNotify` |
| Exception hierarchy | 6 classes | **8 classes** |
| Test suites | 127 items | 127 + **96 items** |

**No breaking changes.** All v1.0 code runs unchanged on v2.0.

---

## Contents

1. [Environment requirements](#1-environment-requirements)
2. [Project layout](#2-project-layout)
3. [Environment setup](#3-environment-setup)
   - [3.1 Node.js on Windows](#31-nodejs-on-windows)
   - [3.2 Node.js on Linux / macOS / BSD](#32-nodejs-on-linux--macos--bsd)
   - [3.3 Deno](#33-deno)
   - [3.4 Bun](#34-bun)
4. [Placing the native library](#4-placing-the-native-library)
5. [Verification](#5-verification)
   - [5.1 Environment check](#51-environment-check)
   - [5.2 Running the demo](#52-running-the-demo)
   - [5.3 Running the test suites](#53-running-the-test-suites)
6. [Using this library in another application](#6-using-this-library-in-another-application)
   - [6.0 Comparison of the four reference options](#60-comparison-of-the-four-reference-options)
   - [6.1 Option A — absolute-path require](#61-option-a--absolute-path-require)
   - [6.2 Option B — npm install from a local path](#62-option-b--npm-install-from-a-local-path)
   - [6.3 Option C — npm link](#63-option-c--npm-link)
   - [6.4 Option D — a Windows directory junction](#64-option-d--a-windows-directory-junction)
   - [6.5 A complete minimal example](#65-a-complete-minimal-example)
   - [6.6 A require path cannot point at a directory](#66-a-require-path-cannot-point-at-a-directory)
   - [6.7 CommonJS usage](#67-commonjs-usage)
   - [6.8 ESM usage](#68-esm-usage)
   - [6.9 The simplest Call API example](#69-the-simplest-call-api-example)
   - [6.10 The simplest Notify API example](#610-the-simplest-notify-api-example)
   - [6.11 A pure client example](#611-a-pure-client-example)
   - [6.12 Choosing between tryCall and call](#612-choosing-between-trycall-and-call)
   - [6.13 Permanent and short-lived handles](#613-permanent-and-short-lived-handles)
   - [6.14 The JSON payload convention](#614-the-json-payload-convention)
   - [**6.15 The three call styles (new in v2.0)**](#615-the-three-call-styles-new-in-v20)
   - [**6.16 The three addressing modes (new in v2.0)**](#616-the-three-addressing-modes-new-in-v20)
   - [**6.17 Typed options (new in v2.0)**](#617-typed-options-new-in-v20)
   - [**6.18 Reading P2P identity (new in v2.0)**](#618-reading-p2p-identity-new-in-v20)
7. [Troubleshooting](#7-troubleshooting)
8. [API quick reference](#8-api-quick-reference)

---

## 1. Environment requirements

| Component | Minimum version | Notes |
|-----------------|:--------:|--------------------------------------------|
| Node.js | 18 | 20 LTS or newer recommended. |
| npm | 9 | installed together with Node.js. |
| Deno (optional) | 2.0 | not needed if you only use Node.js. |
| Bun (optional) | 1.0 | not needed if you only use Node.js. |
| Koffi | 3.3.2 | installed automatically by `npm install`. |

The binding is written in pure ECMAScript 2022 and needs no compiler itself. The Koffi dependency
ships prebuilt native binaries for every supported platform, so installing Koffi needs no C++
toolchain.

---

## 2. Project layout

The library is delivered as a flat directory:

```
js/
├── check-env.js               environment diagnostic script
├── index.js                   CommonJS entry point
├── index.mjs                  ESM entry point
├── errors.js                  exception hierarchy (v2.0: 8 classes)
├── binding.js                 Koffi declarations and library loading (59 symbols)
├── data-handle.js             the RAII wrapper for TDataHnd (with the P2P identity accessors)
├── app-handle.js              the RAII wrapper for TAppHnd
├── lf-io.js                   JSON / string / byte I/O
├── framework.js               the process-level ABI facade
├── network-events.js          connect / disconnect event handlers
├── status.js                  the status queue and health checks (including UID / P2PName checks)
├── options.js                 typed runtime options (new in v2.0)
├── address.js                 the three addressing abstractions (new in v2.0)
├── async-support.js           the async subsystem (new in v2.0)
├── p2p-registration.js        process-level P2P registration (new in v2.0)
├── package.json
├── PORTABILITY.md             runtime-specific notes
├── readme.md                  this file
├── test/
│   ├── test.js                the v1.0 test suite (127 items)
│   ├── test2.js               the v2.0 test suite (96 items)
│   └── lf_js_helloworld.js    end-to-end demo
├── cross/
│   ├── cross-service.js        the beacon (coordinator)
│   ├── cross-node.js           a worker node (exposes the "demo" application)
│   └── cross-call.js           the load-test client
└── node_modules/               installed dependencies (koffi)
```

All source files sit in the same directory; there is no `src/` subdirectory.

---

## 3. Environment setup

### 3.1 Node.js on Windows

**Prerequisites**

1. Download and install Node.js 18 or newer from <https://nodejs.org/en/download/>. The MSI
   installer adds `node` and `npm` to `PATH` automatically.
2. Verify the installation in a **fresh** PowerShell window:

   ```powershell
   node --version
   npm --version
   ```

   Expected: `v18.x.x` or newer, and `9.x.x` or newer.

**Installing the dependencies**

In the `js/` directory:

```powershell
cd D:\CoreLibrary\LingoFuse\js
npm install
```

`npm install` reads `package.json`, downloads `koffi@3.3.2` from the npm registry, and unpacks the
prebuilt Windows x64 binary into `node_modules/@koromix/koffi-win32-x64/`. No build tools are
needed.

**If `npm install` fails**

- clear the cache and retry:

  ```powershell
  npm cache clean --force
  Remove-Item -Recurse -Force node_modules
  Remove-Item package-lock.json
  npm install
  ```

- if you are behind a proxy, configure npm:

  ```powershell
  npm config set proxy http://your-proxy:port
  npm config set https-proxy http://your-proxy:port
  npm install
  ```

### 3.2 Node.js on Linux / macOS / BSD

**Prerequisites**

Install Node.js 18 or newer. Recommended approaches (in priority order):

- **nvm** (all Linux distributions, macOS):

  ```bash
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  source ~/.bashrc      # or ~/.zshrc
  nvm install 20
  nvm use 20
  ```

- **distribution packages** (Debian, Ubuntu):

  ```bash
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
  ```

- **Homebrew** (macOS):

  ```bash
  brew install node@20
  ```

Verify:

```bash
node --version
npm --version
```

**Installing the dependencies**

In the `js/` directory:

```bash
cd /path/to/LingoFuse/js
npm install
```

The right native binary is selected automatically:

| Platform | Package installed |
|-------------------|-----------------------------------------|
| Linux x64 | `@koromix/koffi-linux-x64` |
| Linux arm64 | `@koromix/koffi-linux-arm64` |
| macOS x64 | `@koromix/koffi-darwin-x64` |
| macOS arm64 | `@koromix/koffi-darwin-arm64` |
| FreeBSD / OpenBSD | the corresponding `koffi-*` package |

**If `npm install` fails**

- confirm you can write to the `js/` directory:

  ```bash
  ls -ld /path/to/LingoFuse/js
  ```

  If the directory belongs to another user, either `chown` it first or install with
  `sudo npm install --unsafe-perm`. `--unsafe-perm` is required because koffi's postinstall script
  must write into the project directory.

- if the install hangs inside a corporate network, retry with another registry:

  ```bash
  npm install --registry=https://registry.npmmirror.com
  ```

### 3.3 Deno

Deno is optional. Install it from <https://deno.land/#installation>:

```bash
# Linux / macOS
curl -fsSL https://deno.land/install.sh | sh

# Windows PowerShell
irm https://deno.land/install.ps1 | iex
```

Deno consumes this library through the `npm:` specifier. Deno's npm compatibility layer provides a
CommonJS `require` internally, which is exactly what this library needs.

The full Deno contract is in [PORTABILITY.md](PORTABILITY.md) §4. Deno needs
`--allow-ffi`, `--allow-read` and `--allow-env` permissions.

### 3.4 Bun

Bun is optional. Install it from <https://bun.sh/>:

```bash
# Linux / macOS
curl -fsSL https://bun.sh/install | bash

# Windows PowerShell
powershell -c "irm bun.sh/install.ps1 | iex"
```

Bun accepts both `require("lingofuse-js")` and `import lf from "lingofuse-js"` with no extra
configuration.

The full Bun contract is in [PORTABILITY.md](PORTABILITY.md) §5.

---

## 4. Placing the native library

This library **does not include** the LingoFuse native shared library. That library must be built
separately (from the Pascal / C++ sources) and placed where the OS loader can find it.

**The expected file names**

| Platform | File name |
|-------------------|-----------------------|
| Windows 64-bit | `LingoFuse64.dll` |
| Windows 32-bit | `LingoFuse32.dll` |
| Linux / BSD | `liblingofuse.so` |
| macOS | `liblingofuse.dylib` |

**The search order the library uses**

The library tries, in turn:

1. the directory holding the current executable (`process.execPath`).
2. the current working directory (`process.cwd()`).
3. the `native/` subdirectory beside the library package.
4. **the operating system's loader search path**:
   - Windows: the `PATH` environment variable.
   - Linux: `LD_LIBRARY_PATH`, then `/etc/ld.so.conf` and `/etc/ld.so.conf.d/*.conf`.
   - macOS: `DYLD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, and the standard framework paths.

Any one of those is fine. If the library is already on the system loader path, no copying is needed.

**Example placements**

Windows: copy `LingoFuse64.dll` next to the executable, or add its directory to `PATH`:

```powershell
$env:PATH += ";D:\CoreLibrary\LingoFuse\Binary"
```

Linux: copy `liblingofuse.so` into `/usr/local/lib` and run `sudo ldconfig`, or add its directory to
`LD_LIBRARY_PATH`:

```bash
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/opt/lingofuse/lib"
```

macOS: copy `liblingofuse.dylib` into `/usr/local/lib`, or add its directory to
`DYLD_LIBRARY_PATH`:

```bash
export DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH:/opt/lingofuse/lib"
```

`check-env.js` (see [§5.1](#51-environment-check)) prints the exact search order and then attempts
one authoritative load. Run it once the library is in place.

---

## 5. Verification

### 5.1 Environment check

In the `js/` directory:

```bash
node check-env.js
```

Expected output (Windows shown; Linux and macOS are identical apart from the file names):

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
  ... (13 lines)

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

If any section reports `[FAIL]`, see [Troubleshooting](#7-troubleshooting).

### 5.2 Running the demo

```bash
node test/lf_js_helloworld.js
```

The demo creates a self-connected endpoint, registers three APIs (`add`, `echo`, `log`), waits for
the network to be ready, and then calls each API through its own path. The expected last line:

```
=== demo completed successfully ===
```

### 5.3 Running the test suites

The v1.0 baseline suite (127 items):

```bash
node test/test.js
```

Expected output (the trailing summary):

```
Summary
  runtime : Node.js 24.21.0
  passed  : 127
  failed  : 0
  total   : 127
```

The v2.0 addition suite (96 items):

```bash
node test/test2.js
```

Expected output (the trailing summary):

```
Summary
  runtime : Node.js 24.21.0
  passed  : 96
  failed  : 0
  total   : 96
```

The two suites together cover **223 assertions**.

### 5.4 npm scripts

If you prefer, the same four commands are available through npm:

```bash
npm run check       # node check-env.js
npm run demo        # node test/lf_js_helloworld.js
npm test            # node test/test.js        (v1.0, 127 items)
npm run test:v2     # node test/test2.js       (v2.0, 96 items)
npm run test:all    # run both suites in sequence
```

---

## 6. Using this library in another application

Suppose the library lives in `D:\CoreLibrary\LingoFuse\js\` and your application is at
`C:\temp\test_lf.js`. This section covers four ways to reference it. **No file copying is needed**:
copying means moving `node_modules/` too (including koffi's native binary, about 8 MB), re-copying
on every library update, and a good chance of version drift. Any of the options below avoids those
problems.

### 6.0 Comparison of the four reference options

| Option | Command complexity | After a package update | Needs administrator rights | Suitable for |
|------|:---------:|:--------:|:-------------:|----------|
| A  absolute-path require | zero | takes effect immediately | no | quick validation, one-off scripts |
| B  npm install from a local path | one command | requires re-installing | no | standalone, long-term projects |
| C  npm link | two commands | takes effect immediately | **usually yes** | developing/debugging the library itself |
| D  Windows directory junction | two commands | takes effect immediately | no | developing on Windows |

**Recommendations**:
- just validating something → A.
- `C:\temp\` is a long-term project and you will not change the library often → B.
- you are debugging the library itself and want changes live immediately → C (macOS/Linux), D (Windows).

---

### 6.1 Option A — absolute-path require

Write the full path directly in your script:

```javascript
"use strict";

const lf = require("D:/CoreLibrary/LingoFuse/js/index.js");

lf.loadLibrary();
console.log("library :", lf.libraryName());
console.log("runtime :", lf.platform().runtime);
```

On Windows both forward slashes `/` and backslashes `\\` are accepted; forward slashes are
recommended (no escaping). Node resolves all of the library's internal `require` calls relative to
the directory holding `D:/CoreLibrary/LingoFuse/js/index.js`, including its lookup of
`node_modules/koffi`, so everything works.

**Pros**: zero configuration; the hard-coded path is immediately obvious.
**Cons**: the path is hard-coded in the source. Moving to another machine or path requires a code change.

---

### 6.2 Option B — npm install from a local path

```powershell
cd C:\temp
npm init -y                                    # if there is no package.json yet
npm install D:\CoreLibrary\LingoFuse\js
```

npm copies the whole `js\` directory into `C:\temp\node_modules\lingofuse-js\`. Then `test_lf.js` uses:

```javascript
"use strict";

const lf = require("lingofuse-js");

lf.loadLibrary();
console.log("library :", lf.libraryName());
```

**Pros**: follows the Node standard, so referencing by package name matches the way a registry
install is used; `package.json` records the dependency version (shown as a `"file:../path"` entry).
**Cons**: after a library update you must run `npm install D:\CoreLibrary\LingoFuse\js` again.

---

### 6.3 Option C — npm link

Two setup steps.

**Step 1** — register a global link in the package directory:

```powershell
cd D:\CoreLibrary\LingoFuse\js
npm link
```

**Step 2** — link to it from your project:

```powershell
cd C:\temp
npm init -y
npm link lingofuse-js
```

`npm link` creates a symbolic link at `C:\temp\node_modules\lingofuse-js` pointing at
`D:\CoreLibrary\LingoFuse\js\`. Then `test_lf.js` likewise uses:

```javascript
const lf = require("lingofuse-js");
```

**Pros**: changes to the library source take effect immediately, with no re-install.
**Cons**: creating a symbolic link on Windows usually needs **administrator rights** or **Developer
Mode enabled**. If it fails, use option D.

---

### 6.4 Option D — a Windows directory junction

A Windows **junction** needs no administrator rights and is the more practical replacement for
`npm link` on Windows.

**Step 1** — create the `node_modules` directory (if it does not exist) and the junction:

```powershell
cd C:\temp
mkdir node_modules -Force
cmd /c mklink /J node_modules\lingofuse-js D:\CoreLibrary\LingoFuse\js
```

**Step 2** — reference it as usual:

```javascript
"use strict";

const lf = require("lingofuse-js");

lf.loadLibrary();
console.log("library :", lf.libraryName());
```

`node_modules/lingofuse-js` is essentially a transparent directory pointing at
`D:\CoreLibrary\LingoFuse\js\`; reading its contents is the same as reading the original directory,
and so is writing.

**Inspecting / deleting the junction**:

```powershell
# inspect
dir C:\temp\node_modules

# remove (deletes only the link itself, leaving the original directory alone)
cmd /c rmdir C:\temp\node_modules\lingofuse-js
```

**Pros**: no administrator rights needed; library changes take effect immediately; removing the
junction deletes only the link, which is safe.
**Cons**: Windows-specific. On Linux/macOS use `ln -s` or option B/C.

---

### 6.5 A complete minimal example

Using option A as the example, `C:\temp\test_lf.js`:

```javascript
"use strict";

const lf = require("D:/CoreLibrary/LingoFuse/js/index.js");

// 1. load the runtime.
lf.loadLibrary();
console.log("library :", lf.libraryName());
console.log("runtime :", lf.platform().runtime);

// 2. create an application and register one API.
const app = new lf.AppHandle("QuickTest", "absolute-path require test");

app.registerCall("ping", "Return pong", (input, output) => {
    lf.io.writeJson(output, { pong: true });
});

// 3. start a self-connected endpoint.
lf.framework.setOption("Wait_Ready", "False");
lf.framework.resetPrepare();
lf.framework.prepareService("ipc:quicktest", "ipc:quicktest");
lf.framework.prepareClient("ipc:quicktest", app);

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

// 4. wait for the application to become visible on the mesh.
(async () => {
    for (let i = 0; i < 100; i++) {
        if (lf.status.checkApi("QuickTest", "ping")) break;
        await new Promise((r) => setTimeout(r, 100));
    }

    // 5. call it.
    const param = new lf.DataHandle("ping");
    lf.io.writeJson(param, {});

    const result = app.localCall(param);
    console.log("response:", lf.io.readJson(result));

    // 6. clean up.
    param.dispose();
    result.dispose();
    app.dispose();
    lf.framework.exitMainThread();
    lf.framework.shutdown();
})();
```

Run it:

```powershell
cd C:\temp
node test_lf.js
```

Expected output:

```
library : LingoFuse64.dll
runtime : node
response: { pong: true }
```

If you switch to option B/C/D, you only need to change the require on the first line to:

```javascript
const lf = require("lingofuse-js");
```

The rest of the code is unchanged.

---

### 6.6 A require path cannot point at a directory

**This is the most common pitfall.**

The following **always fails**:

```javascript
const lf = require("D:/CoreLibrary/LingoFuse/js");   // ❌ error
```

Node only performs the "automatically look for index.js or package.json" directory resolution
inside `node_modules/`. When an absolute or relative path points directly at a directory, Node does
not append `index.js` automatically.

**The two correct approaches**:

- in option A, write the full path: `require("D:/CoreLibrary/LingoFuse/js/index.js")`.
- in options B/C/D, use the package name: `require("lingofuse-js")` (that name is resolved through
  the `node_modules` directory).

---

### 6.7 CommonJS usage

```javascript
"use strict";

const lf = require("lingofuse-js");

// load the runtime (idempotent; may be omitted).
lf.loadLibrary();

// access the seven namespaces.
lf.io;         // JSON / string / byte I/O
lf.framework;  // the process-level ABI facade
lf.network;    // connect / disconnect events
lf.status;     // the status queue and health checks
lf.options;    // typed runtime options             [new in v2.0]
lf.address;    // the three addressing modes         [new in v2.0]
lf.async;      // the async subsystem                [new in v2.0]

// top-level types.
const dh = new lf.DataHandle("my_api");
const app = new lf.AppHandle("MyApp", "description");

// top-level addressing shortcuts (equivalent to lf.address.AppTarget and company).
const t = new lf.AppTarget("MyApp");
```

### 6.8 ESM usage

```javascript
import lf from "lingofuse-js";
import { DataHandle, AppHandle, io, framework } from "lingofuse-js";

lf.loadLibrary();
const dh = new DataHandle("my_api");
io.writeJson(dh, { hello: "world" });
```

Both styles access the same singleton. Mixing them in one process is safe.

### 6.9 The simplest Call API example

A server that fully exposes an "add" API:

```javascript
"use strict";

const lf = require("lingofuse-js");

function main() {
    // 1. load the runtime.
    lf.loadLibrary();

    // 2. install the callback error reporter (optional but recommended).
    lf.framework.setCallbackErrorHandler((source, err) => {
        console.error(`[lf] callback failed in ${source}:`, err);
    });

    // 3. create the application.
    const app = new lf.AppHandle("Calculator", "Add two integers");

    // 4. register a Call API.
    app.registerCall("add", "Add two integers", (input, output) => {
        const req = lf.io.readJson(input);
        const a = Number(req.a) || 0;
        const b = Number(req.b) || 0;
        lf.io.writeJson(output, { result: a + b });
    });

    // 5. prepare the framework. This example is self-connected: one endpoint is both server and client.
    lf.framework.setOption("Wait_Ready", "False");
    lf.framework.resetPrepare();
    lf.framework.prepareService("ipc:calc", "ipc:calc");
    lf.framework.prepareClient("ipc:calc", app);

    if (lf.framework.prepareDone() !== 1) {
        throw new Error("framework startup failed");
    }

    // 6. wait for the application to become visible on the network.
    //    Why this is necessary: see §6.9.1.
    waitForApp("Calculator", "add", 10000).then((visible) => {
        if (!visible) {
            throw new Error("app did not become visible in time");
        }
        console.log("ready");

        // 7. call the API.
        const param = new lf.DataHandle("add");
        lf.io.writeJson(param, { a: 40, b: 2 });

        const result = app.localCall(param);
        const response = lf.io.readJson(result);
        console.log("result:", response.result);   // 42

        // 8. clean up.
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

#### 6.9.1 The `waitForApp` pattern

If you disabled `Wait_Ready` (as the example above does), `prepareDone()` returns as soon as the
framework event loop starts. The client-to-server connection, and the server API information
broadcast that follows, are both asynchronous. In that window the client's local cache does not know
the application exists, and any call issued too early times out.

The `waitForApp` helper polls `checkApp` and `checkApi` until the target is visible. That is the
pattern **every** production program must use when `Wait_Ready` is disabled.

The alternative is to leave `Wait_Ready` at its default (`"True"`) and let `prepareDone()` block
until all prepared clients are ready. That is simpler but adds startup latency. The full trade-off
discussion is in the LingoFuse C++ knowledge base.

### 6.10 The simplest Notify API example

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
    // wait for visibility (same reason as §6.9.1).
    for (let i = 0; i < 100; i++) {
        if (lf.status.checkApi("Logger", "log")) break;
        await new Promise((r) => setTimeout(r, 100));
    }

    // send a notification.
    const param = new lf.DataHandle("log");
    lf.io.writeJson(param, { level: "info", message: "hello" });

    app.localNotify(param);
    param.dispose();

    // give the callback time to run before tearing things down.
    await new Promise((r) => setTimeout(r, 200));

    lf.framework.exitMainThread();
    app.dispose();
    lf.framework.shutdown();
})();
```

### 6.11 A pure client example

A process that only consumes another process's APIs:

```javascript
"use strict";

const lf = require("lingofuse-js");

lf.loadLibrary();

// prepare a client with no application. This is a pure consumer.
lf.framework.setOption("Wait_Ready", "False");
lf.framework.resetPrepare();
lf.framework.prepareClient("ipc:calc", null);

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

(async () => {
    // wait for the target application to become visible.
    for (let i = 0; i < 100; i++) {
        if (lf.status.checkApp("Calculator")) break;
        await new Promise((r) => setTimeout(r, 100));
    }

    // call the remote API. In this cross-process scenario LF_Call routes the
    // request over IPC.
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

Note: the client creates no `AppHandle`. A pure consumer never needs one.

### 6.12 Choosing between tryCall and call

The framework offers two synchronous remote-call entry points; they differ in **what they return on
failure**:

| Scenario | `framework.call(app, param, timeout)` | `framework.tryCall(app, param, timeout)` |
|---|---|---|
| normal return | `DataHandle` (`size > 0`) | `DataHandle` (`size > 0`) |
| timeout | `DataHandle` (`size == 0`) | `null` |
| target unreachable | `DataHandle` (`size == 0`) | `null` |

**Recommended usage**:

```javascript
// when you only care about "success/failure" and do not distinguish a timeout from an empty response:
const response = lf.framework.tryCall("Calc", param, 3000);
if (response === null) {
    console.log("call failed");
} else {
    console.log(lf.io.readJson(response));
    response.dispose();
}

// when you need to distinguish "timed out" from "the service returned an empty response":
const response2 = lf.framework.call("Calc", param, 3000);
if (response2.size === 0) {
    // either is possible
} else {
    // the service returned a non-empty response
}
response2.dispose();
```

**Ownership**: when `tryCall` returns `null` the internal handle has already been released
automatically; when it returns a `DataHandle`, the caller is responsible for `dispose`. This
contract is exactly the same as C#'s `Framework.TryCall`.

### 6.13 Permanent and short-lived handles

The framework offers two kinds of data handle with different lifetimes:

| Kind | Construction | Idle reclaim | `dispose()` semantics |
|---|---|---|---|
| **auto-recycled** | `new DataHandle(apiName)` | reclaimed by the pool after 10 minutes without access | marks deletion only; the actual release happens on the next pool scan (≤ 5 seconds) |
| **permanent** | `DataHandle.createPermanent(apiName)` | **never auto-reclaimed** | releases **synchronously** and immediately |

**Use auto-recycled handles by default.** The pool is a safety net when you forget to `dispose`.

**Use a permanent handle only in these cases**:

- you need to hold it across the whole process lifecycle (cached request templates, global
  registries).
- you need to avoid the dangling risk caused by 10-minute idle reclaim.
- a long-running operation where you cannot guarantee refreshing the last-access timestamp every 10
  minutes.

**The two pitfalls of permanent handles**:

1. **"permanent" does not mean "never released"**. You must `dispose` it explicitly, otherwise it
   leaks for the whole process lifecycle.
2. **the no-op window**: a permanent handle created and `dispose`d before `prepareDone()` or after
   `exitMainThread()` gets a no-op `LF_FreeData`, because the main thread is not active. A handle
   created then is kept until the process exits (or until `shutdown()` releases it).

**Example**:

```javascript
// short-lived: use the default constructor
{
    const param = new lf.DataHandle("myapi");
    lf.io.writeJson(param, payload);
    const result = lf.framework.call("Target", param, 3000);
    result.dispose();
    param.dispose();
}

// process lifetime: use createPermanent
const cachedTemplate = lf.DataHandle.createPermanent("myapi");
lf.io.writeJson(cachedTemplate, { template: true });

// ... reusable across the whole process lifetime, with no 10-minute timeout to worry about ...

// release it explicitly before exiting
cachedTemplate.dispose();
lf.framework.shutdown();
```

### 6.14 The JSON payload convention

This library enforces one serialization policy across all languages:

- **compact** JSON. No indentation, no trailing newline.
- **literal UTF-8** for non-ASCII characters. Non-ASCII text is written as its UTF-8 bytes rather
  than `\uXXXX` escapes.
- **a single NUL byte** appended after every string and JSON payload.
- **tolerant reading**: a payload without the trailing NUL is still fully consumed.

That makes the byte sequence JavaScript emits identical to what Pascal, Python, C++ and C# emit for
the same logical value:

```
{"a":1}
→ 7B 22 61 22 3A 31 7D 00
```

Do not bypass the `lf.io` helpers. Calling `LF_WriteBuffer` / `LF_ReadBuffer` directly is possible,
but it breaks the cross-language contract.

The full wire-format contract is in the `lf-io.js` file header.

---

### 6.15 The three call styles (new in v2.0)

The LingoFuse JS binding offers **three parallel call styles**. All three share the same
`AsyncBridge` subsystem and may be mixed freely, but each suits a different business scenario.

| Style | Entry point | Blocking? | Suits |
|------|------|:------:|------|
| **A. inline callback** | `target.callAsync(api, payload, (r, e) => {...})` | no | event-driven code, simple business logic, when you do not want `async` |
| **B. async/await** | `await target.call(api, payload)` | no (suspends) | modern async business code needing sequential logic |
| **C. synchronous** | `target.callSync(api, payload)` | yes | scripts, tests, CLI tools |

#### 6.15.1 Style A — inline callback

**Best when the business code goes straight into the callback body**, with no `await` and no
`Promise` wrapper.

```javascript
const target = new lf.AppTarget("Calculator");

target.callAsync("add", { a: 5, b: 7 }, (result, error, userData) => {
    // the business code goes right here
    if (error) {
        console.error("call failed:", error);
        return;
    }
    console.log("result:", result);   // { result: 12 }
});
```

The callback signature is `(result, error, userData) => void`.

| Parameter | Meaning |
|------|------|
| `result` | the deserialized JSON value; `null` on failure |
| `error` | a `LingoFuseError` / `LingoFuseTimeoutError` instance; `null` on success |
| `userData` | the optional 4th argument passed at call time |

**Key points**:

- the callback **runs on the JS event loop** (serialized over from the native worker thread by the
  Koffi bridge). **Do not block it.**
- **do not** call any synchronous LingoFuse function (such as `target.callSync`) inside a callback
  — that deadlocks.
- an exception thrown by the callback body is swallowed and written to stderr; it does not propagate
  back onto the native stack.

#### 6.15.2 Style B — async/await

`target.call(api, payload, { timeoutMs })` returns a `CallPromise` (a thenable). Use `await` to get
the result:

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

**Cancellation semantics**: `CallPromise` is **not** a standard `Promise`; it carries an extra
`abandoned` flag. When the JS-side timeout fires before the native callback arrives:

- `CallPromise` rejects with `LingoFuseTimeoutError`
- `abandoned` becomes `true`
- **the native request is not cancelled**: `AsyncBridge` keeps the callback alive for a grace
  period, and any late result is discarded

The rationale for this design (and why it cannot simply be cancelled) is in the `async-support.js`
file header.

#### 6.15.3 Style C — synchronous

```javascript
const target = new lf.AppTarget("Calculator");

const result = target.callSync("add", { a: 5, b: 7 }, { timeoutMs: 3000 });
console.log("result:", result);   // { result: 12 }
```

- on **success** it returns the deserialized value.
- on a **timeout** it throws `LingoFuseTimeoutError`.
- when **unreachable** it throws `LingoFuseCallError`.

There is also a non-throwing variant:

```javascript
const result = target.tryCallSync("add", { a: 5, b: 7 }, { timeoutMs: 3000 });
if (result === null) {
    console.log("call failed");
} else {
    console.log("result:", result);
}
```

**Warning**: `callSync` **blocks the JS event loop** until the native call returns. Use it only in
scripts, tests and CLI tools. Do not use it on a server's hot path.

#### 6.15.4 All three share the same AsyncBridge

All three styles go through the same process-level `AsyncBridge`:

```javascript
const stats = lf.AsyncBridge.instance().stats();
console.log(stats);
// {
//   total: <int>,          // the number of currently active ops
//   pending: <int>,        // waiting for a callback
//   fired: <int>,          // callback fired, waiting for release
//   abandoned: <int>,      // already timed out, waiting for the grace period to expire
//   not_queued: <int>,     // dispatch failed
//   released_total: <int>, // cumulative releases
//   grace_seconds: <float>,
//   period_seconds: <float>,
// }
```

`AsyncBridge` is **a singleton**. Users of all three styles **share the same counters**.

---

### 6.16 The three addressing modes (new in v2.0)

LingoFuse supports three **orthogonal** addressing modes. They share one call interface
(`call` / `callAsync` / `callSync` / `tryCallSync` /
`sequencedCall` / `sequencedCallAsync` / `notify` /
`sequencedNotify`) and differ only in **routing semantics**.

| Target type | Routing key | Local first? | Load balanced? | After it dies |
|-------------|--------|:---------:|:---------:|--------|
| `AppTarget` | App name (string) | ✅ yes | ❌ N/A | must re-register |
| `UIDTarget` | UID (32 bytes) | ✅ yes | ❌ N/A | **the UID is now invalid** |
| `P2PNameTarget` | group name (string) | ❌ no | ✅ yes | forwarded to another member of the group |

#### 6.16.1 `AppTarget` — address by application name

The most common approach. Routes to **any** client with a matching name.

```javascript
const target = new lf.AppTarget("Calculator");

const result = await target.call("add", { a: 1, b: 2 });
```

**Local first**: if the caller's own process registered an App of the same name and exposes the
target API, the call completes **locally**, without going over the network.

```javascript
// with several clients, the C4 mesh load-balances across the same App name automatically,
// using a "Least Recently Used" policy.
```

#### 6.16.2 `UIDTarget` — address by session UID

Routes to a **specific** 32-byte session. Suited to "I want to message that particular client I
talked to a moment ago".

```javascript
// the UID may be a Uint8Array(32) or a 64-character hexadecimal string.
const uidHex = "4fa01fc4a85b6099a037c5a3f01f49a89564268a2d7fd48009d636246cfc2633";
const target = new lf.UIDTarget(uidHex);

const result = await target.call("add", { a: 1, b: 2 });
```

**A UID can reach any API on the target**, whether it was registered by an App
(`app.registerCall`) or as a process-level P2P API (`registerP2PCall`) — no need to know the
target's App name.

**UID lifetime**: the UID is **regenerated** on every `TunnelLink`. A caller that cached a UID
**must rediscover it after the link drops**.

#### 6.16.3 `P2PNameTarget` — address by group name

Routes to any client in a user-defined group. **Load-balanced by the server.**

```javascript
const target = new lf.P2PNameTarget("workers");

// the server picks one of all clients whose P2PName is "workers"
const result = await target.call("process", { task: "..." });
```

**Not local first**: even if the caller's own process is in the target group, the call is
**forwarded to the server** for dispatch. That is deliberate: the server owns the load-balancing
state.

**Setting your own group name**:

```javascript
lf.options.setOptP2PName("workers");
```

It must be set before `prepareDone()`, or reported through the `Update_UID` command (checked
automatically every second).

#### 6.16.4 `hashKey()` — a stable key for Map / Set

JS `Map` / `Set` compare keys **by reference**. If you want to use a Target as a dictionary key,
use `hashKey()`:

```javascript
const m = new Map();
m.set(new lf.AppTarget("X").hashKey(), 1);
m.get(new lf.AppTarget("X").hashKey());   // => 1
```

Each addressing mode returns a prefixed key: `app:X`, `uid:<hex64>`, `p2p:G`. The three modes
**cannot** collide (even when the string parts match).

---

### 6.17 Typed options (new in v2.0)

The `lf.options` namespace provides **16 typed setter/getter pairs**, corresponding one-to-one with
the `LF_Set_Opt_*` / `LF_Get_Opt_*` families of the Pascal / C# bindings.

#### 6.17.1 The complete option table

| Option | Setter / Getter | Type | Default |
|--------|-----------------|------|------|
| `password` | `setOptPassword` / `getOptPassword` | string | empty (returns a fixed mask) |
| `debug` | `setOptDebug` / `getOptDebug` | string (write-only) | — |
| `Quiet` | `setOptQuiet` / `getOptQuiet` | bool | `false` |
| `ShowThreadID` | `setOptShowThreadID` / `getOptShowThreadID` | bool | `true` |
| `ConsoleOutput` | `setOptConsoleOutput` / `getOptConsoleOutput` | bool | platform dependent |
| `Overlap_Connection` | `setOptOverlapConnection` / `getOptOverlapConnection` | bool | `false` |
| `Wait_Connection_ReadyOk` | `setOptWaitConnectionReadyOk` / `getOptWaitConnectionReadyOk` | bool | `true` |
| `Wait_Connection_Timeout` | `setOptWaitConnectionTimeout` / `getOptWaitConnectionTimeout` | int (ms) | `30000` |
| `IPC_Serv_ThreadCount` | `setOptIpcServThreadCount` / `getOptIpcServThreadCount` | int | platform dependent |
| `IPC_Serv_MaxQueueLength` | `setOptIpcServMaxQueueLength` / `getOptIpcServMaxQueueLength` | int | platform dependent |
| `IPC_Serv_MaxMsgSize` | `setOptIpcServMaxMsgSize` / `getOptIpcServMaxMsgSize` | int (bytes) | platform dependent |
| `Fixed_Sequenced_Time` | `setOptFixedSequencedTime` / `getOptFixedSequencedTime` | int (ms) | `20000` |
| `LF_P2P_name` | `setOptP2PName` / `getOptP2PName` | string | empty |
| `DataHandle_Idle_Timeout` | `setOptDataHandleIdleTimeout` / `getOptDataHandleIdleTimeout` | int (ms) | `600000` (10 minutes) |
| `DataHandle_Pool_Scan_Interval` | `setOptDataHandlePoolScanInterval` / `getOptDataHandlePoolScanInterval` | int (ms) | `5000` (5 seconds) |
| `No_Reponse_Cmd_NULL_Flush_Threshold` | `setOptNoReponseCmdNullFlushThreshold` / `getOptNoReponseCmdNullFlushThreshold` | int | `5000` |

#### 6.17.2 Usage example

```javascript
const lf = require("lingofuse-js");

// load the library and set options.
lf.loadLibrary();

lf.options.setOptOverlapConnection(true);
lf.options.setOptWaitConnectionReadyOk(false);
lf.options.setOptP2PName("my_group");

// read options back.
console.log(lf.options.getOptP2PName());        // "my_group"
console.log(lf.options.getOptWaitConnectionReadyOk());  // false
```

#### 6.17.3 ⚠️ `LF_SetOption` delivers asynchronously

Once LingoFuse's simulated main thread has started (i.e. `prepareDone()` has returned 1), `LF_SetOption` **posts to the main thread** via `MainThreadPost.PostM_NP(DoRun)` and applies on the next tick. **A getter called immediately after the setter returns sees the old value.**

```javascript
// ❌ wrong: you may read the old value
lf.options.setOptQuiet(true);
console.log(lf.options.getOptQuiet());   // may still be false

// ✅ right: wait for the main thread to apply it
lf.options.setOptQuiet(true);
await new Promise((r) => setTimeout(r, 150));
console.log(lf.options.getOptQuiet());   // true
```

150 milliseconds is far above the main thread's 1-10 millisecond tick granularity.

**Setting options before `prepareDone()`** is not subject to this restriction — the main thread has
not started yet, so `LF_SetOption` applies **synchronously**.

#### 6.17.4 Unknown option names are silently ignored

`LF_SetOption` has no return value and **raises no error** on an unrecognised option name. The typed
convenience functions eliminate this failure mode by hard-coding the names, but
`lf.framework.setOption("Typo", "x")` still fails silently.

#### 6.17.5 The generic `setOption` is still available

The typed convenience functions are **layered on top of** the generic API, not a replacement:

```javascript
// a dynamic option name (read from a configuration file)
const optionName = process.env.LF_OPTION_NAME || "Quiet";
lf.framework.setOption(optionName, "True");

// or read the raw string value
const raw = lf.framework.getOption("Quiet");   // "True" / "False" / ""
```

Both paths share the same underlying native call; mixing them is safe.

---

### 6.18 Reading P2P identity (new in v2.0)

Every **inbound request payload** in LingoFuse carries two identity fields of the sender, injected
automatically by **the sender's transport layer** before sending:

```
[apiName: string]
[FromUID: 32 bytes]         ← the sender's session UID
[FromP2PName: string]       ← the sender's P2P group name
[Param.Size: Int32]
[Param: bytes]
```

These two fields are **"side data"**. They are **not** properties of the handle itself but metadata
the sender writes into the payload header. **The receiver can read them only on the callback's
`Input` parameter of the fired event**.

#### 6.18.1 The two accessors

`DataHandle` has two accessors:

```javascript
const uid  = input.getP2PUid();    // Uint8Array(32)
const name = input.getP2PName();   // string ("" when unset)
```

#### 6.18.2 Callable only on an INPUT handle

| Location | Valid? |
|------|:--------:|
| the callback's `input` parameter | ✅ |
| the `input` of a local call | ✅ |
| the callback's `output` parameter | ❌ (returns 32 zeros / an empty string) |
| a handle you created with `new DataHandle(...)` | ❌ (same as above) |

On an invalid location the library **does not throw**; it returns the default value (32 zeros /
an empty string) and records a warning on the native side.

#### 6.18.3 The whoami pattern

**The classic use case**: a client wants to know **its own** UID (the "sender UID" the server sees).

**The server**:

```javascript
const app = new lf.AppHandle("IdentitySvc", "identity echo");

app.registerCall("whoami", "Echo caller identity", (input, output) => {
    // input is the INPUT handle carrying the sender's side data
    const callerUid = input.getP2PUid();
    const callerName = input.getP2PName();

    // hex-encode the UID for readability
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

**The client**:

```javascript
const target = new lf.AppTarget("IdentitySvc");
const result = await target.call("whoami", {});

console.log("my UID:", result.uid_hex);   // 64 hexadecimal characters
console.log("my P2P:", result.p2p_name);  // e.g. "jstest2_group"

// keep the UID; UIDTarget can later reach this session
const myUidTarget = new lf.UIDTarget(result.uid_hex);
```

#### 6.18.4 Implementation detail (a v2.0 correction)

**`LF_Get_P2P_UID` returns a pointer, not a value.** The native side returns a `const TP2P_UID*`
(pointing at a 32-byte buffer the library owns) which is **released automatically about 5 seconds
after the call**. `DataHandle.getP2PUid()` wraps all of that:

1. copies the 32 bytes out immediately with `koffi.decode`
2. does **not** release the pointer
3. does **not** keep the pointer across this method call

The caller never sees the temporary pointer.

**`LF_Get_P2P_Name`** returns a `const char*` that likewise becomes invalid after about 5 seconds.
Koffi's `str` return type copies it into a JS string right at the call boundary, so the value
`getP2PName()` returns is already detached from the native buffer.

#### 6.18.5 Typical uses

| Scenario | How |
|------|------|
| call authorisation | compare `getP2PName()` against a whitelist |
| audit logging | record `getP2PUid()` (hex) and `getP2PName()` |
| session management | keep sessions keyed by UID |
| multi-tenancy | use P2PName as the tenant identifier |
| routing by group | split traffic by P2PName across workers |
| whoami probing | the server echoes the caller's identity for client self-discovery |

#### 6.18.6 `getP2PUid` vs `options.getOptP2PName`

These two are easy to confuse:

| Function | What it reads | Where from |
|------|--------|--------|
| `lf.options.getOptP2PName()` | the group name **I** declared | local configuration |
| `input.getP2PName()` | the group name **the sender** declared | side data (the payload header) |

In other words:

- `getOptP2PName()` answers "what group name did **I** set for myself?"
- `DataHandle.getP2PName()` answers "what group name does **the party messaging me** belong to?"

Both are UTF-8 strings, but their origins are entirely different.

#### 6.18.7 Process-level P2P registration (a separate concept)

Besides `App.registerCall` (App-bound registration), v2.0 also offers **process-level P2P
registration**: the APIs are reachable only by UID or P2PName addressing, **not** by App name:

```javascript
lf.registerP2PCall("whoami", (input, output) => {
    // the callback of a process-level P2P API
    // there is no App binding here
    lf.io.writeJson(output, { ok: true });
}, "Echo");

lf.registerP2PNotify("log", (input) => {
    // ...
}, "One-way log");

// remove
lf.unregisterP2P("whoami");
```

**Typical use**: register a small set of globally discoverable functions (health checks, capability
discovery, identity echo) that any client on the mesh can call by group name or UID, without
knowing the other side's App name.

---

## 7. Troubleshooting

### 7.1 `Cannot find module 'koffi'`

`node_modules/` is missing or was deleted. Run `npm install` in the `js/` directory.

If you moved the JS files to another directory, `node_modules/` must move with them (Node searches
upward from the location of the referencing file).

### 7.2 `Cannot find module './index.js'`

You are running a script from a directory that does **not** contain `index.js`. Every script
(`check-env.js`, `test/test.js`, `test/test2.js`, `test/lf_js_helloworld.js`) must run from the
`js/` directory, alongside the binding files. Do not move the scripts into a subdirectory.

### 7.3 `Failed to load the LingoFuse native library`

The native shared library is not on any search path. See
[§4 Placing the native library](#4-placing-the-native-library).

To see the exact search paths the library uses:

```bash
node -e "console.log(require('./binding.js').buildSearchPaths().join('\n'))"
```

### 7.4 `LF_CreateData` returns `null`

The native library loaded, but the symbol resolved to a wrong or truncated version. Make sure the
DLL / `.so` / `.dylib` matches the header version the library was written against (LingoFuse 5.0+).

### 7.5 `prepareDone()` returns `0`

`prepareDone` returns 1 only once per process. A second call without an intervening `shutdown()`
returns 0. That is not a failure. The full contract is in the `framework.js` file header.

### 7.6 Calls time out immediately after `prepareDone()`

See [§6.9.1](#691-the-waitforapp-pattern). The framework is not necessarily usable the moment
`prepareDone()` returns. Wait for `checkApp` to become true before issuing any call.

### 7.7 A callback throws and the process exits silently

Callbacks run on native worker threads. An uncaught exception would cross into the C stack. This
library wraps every callback to swallow exceptions and route them to `callbackErrorHandler`:

```javascript
lf.framework.setCallbackErrorHandler((source, err) => {
    console.error(`[lf] ${source}:`, err);
});
```

Install it once before registering any API.

### 7.8 Deno reports `PermissionDenied`

Deno needs explicit permissions:

```bash
deno run \
    --allow-ffi \
    --allow-read \
    --allow-env \
    --allow-net \
    your-script.ts
```

The reason for each flag is in [PORTABILITY.md](PORTABILITY.md) §4.2.

### 7.9 `require("D:\\...\\js")` reports `Cannot find module`

See [§6.6](#66-a-require-path-cannot-point-at-a-directory). An absolute path must point at the
`index.js` file, not at the `js` directory.

### 7.10 `getAppName` throws `LingoFuseObjectDisposedError` for a destroyed handle

This is **expected behaviour**. `AppHandle.raw` returns `null` after disposal without throwing, but
`framework.getAppName` explicitly checks `isValid` and rejects a destroyed handle. Catch the
exception, or check `app.isValid` before using it.

### 7.11 The test hangs during teardown (new in v2.0)

**Symptom**: all tests PASS, but the `Summary` is never printed and the process does not exit.

**Cause**: some native call triggers a Pascal-side live query, leaving a pending async task behind.
When `C40Clean()` inside `LF_ExitMainThread` waits for that task, the whole native main thread
blocks, which in turn blocks the JS event loop that called `LF_ExitMainThread`.

The most common trigger is `setOptDebug("<command>")`, where `<command>` is
`service` / `tunnel` / `ZNet_Info` / `HPC_Thread_Info` /
`Instance_Info` and the like. Those commands create a short-lived `TC40_Console_Help` object and
run a live query.

**Diagnosis**:

1. **enable verbose native logging**: call this before `prepareDone`
   ```javascript
   lf.options.setOptQuiet(false);
   lf.options.setOptShowThreadID(true);
   lf.options.setOptConsoleOutput(true);
   ```
   That prints every step of the native main thread.

2. **log around each teardown step**:
   ```javascript
   console.error("[after] step 3 begin: LF_ExitMainThread()");
   lf.framework.exitMainThread();
   console.error("[after] step 3 done");
   ```
   That pinpoints the step that hangs.

3. **disable the watchdog to observe**:
   ```bash
   LINGOFUSE_TEST_NO_WATCHDOG=1 node test/test2.js
   ```

**Fix**: do not run side-effecting debug commands in tests. Use a side-effect-free placeholder
(such as `noop-for-test`) to validate the `setOptDebug` API contract.

**The permanent safety net**: v2.0's `test2.js` has a built-in **standalone child-process watchdog**
(SIGKILL on this process after 90 seconds). That is the only mechanism that can bypass a blocked
JS event loop: any in-process timer fails while the event loop is frozen, whereas a child process
has its own event loop.

### 7.12 The `LF_Get_P2P_UID` pointer becomes invalid after 5 seconds

Do not keep the pointer the native side returns. Use `DataHandle.getP2PUid()`, which copies 32
bytes immediately with `koffi.decode`:

```javascript
// ✅ right
const uid = input.getP2PUid();   // copied immediately

// ❌ wrong: never take the native pointer directly
const rawPtr = lf._binding.funcs.LF_Get_P2P_UID(input.raw);
// 5 seconds later the memory rawPtr points at is released by the native side
```

---

## 8. API quick reference

This library exposes **seven namespaces**, **two RAII handle types**, **three addressing target
classes**, and **an eight-class exception hierarchy**.

### 8.1 Top level

| Symbol | Notes |
|-------------------------------|--------------------------------------------|
| `VERSION` | the binding version string (`"2.0.0"`). |
| `loadLibrary()` | load the native library explicitly (idempotent). |
| `isLoaded()` | returns `true` once the native library is loaded. |
| `libraryName()` | the platform-specific library file name. |
| `platform()` | a `{ platform, arch, runtime }` summary. |
| `DataHandle` | the RAII wrapper for a data buffer. |
| `AppHandle` | the RAII wrapper for an application. |
| `AppTarget` | an App-name-addressed target (a shortcut to `lf.address.AppTarget`). |
| `UIDTarget` | a UID-addressed target. |
| `P2PNameTarget` | a group-name-addressed target. |
| `CallPromise` | the async/await-style Promise wrapper. |
| `AsyncBridge` | the async subsystem singleton. |
| `registerP2PCall()` | process-level P2P Call registration. |
| `registerP2PNotify()` | process-level P2P Notify registration. |
| `unregisterP2P()` | remove a process-level P2P API. |
| `io` | the JSON / string / byte I/O namespace. |
| `framework` | the process-level ABI facade. |
| `network` | the network event handlers. |
| `status` | the status queue and health checks. |
| `options` | typed runtime options. |
| `address` | the three addressing modes. |
| `async` | the async subsystem (`AsyncBridge` / `AsyncOp` / `CallPromise` etc.). |

### 8.2 `lf.io`

| Function | Notes |
|------------------------------------|-------------------------------------------|
| `dumps(value)` | serialize to compact JSON. |
| `loads(text)` | parse JSON; throws on failure. |
| `writeString(handle, str)` | write UTF-8 + NUL. |
| `readString(handle)` | read UTF-8, stopping at a NUL. |
| `writeStringBytes(handle, bytes)` | write raw bytes + NUL. |
| `readStringBytes(handle)` | read raw bytes, stopping at a NUL. |
| `readAllBytes(handle)` | read all the rest. |
| `writeJson(handle, value)` | serialize value, write UTF-8 + NUL. |
| `readJson(handle)` | read NUL-framed JSON. |
| `tryReadJson(handle)` | a non-throwing `readJson`. |

### 8.3 `lf.framework`

| Function | Notes |
|-----------------------------------------|-----------------------------------|
| `setCallbackErrorHandler(fn)` | install the global error reporter. |
| `resetPrepare()` | clear the preparation queue. |
| `prepareService(listen, physics)` | prepare a service endpoint. |
| `prepareClient(physics, app)` | prepare a client connection. |
| `prepareDone()` | start the framework. |
| `exitMainThread()` | request a graceful exit. |
| `setOption(name, value)` | adjust a runtime option (generic). |
| `getOption(name)` | read a runtime option (generic). |
| `generateAppName()` | generate a unique name. |
| `getAppName(app)` | query an App's authoritative name. |
| `call(appName, param, timeoutMs)` | a synchronous remote call. |
| `tryCall(appName, param, timeoutMs)` | a `call` that returns `null` on timeout/unreachable. |
| `notify(appName, param)` | a one-way notification. |
| `sequencedNotify(appName, param)` | a FIFO one-way notification. |
| `callAsync(appName, param, cb, data)` | an inline-callback async call. |
| `callPromise(appName, param, timeoutMs)` | a Promise-style async call. |
| `uidCall(uid, param, timeoutMs)` | a synchronous UID call. |
| `uidCallAsync(uid, param, cb, data)` | an inline-callback UID call. |
| `uidCallPromise(uid, param, timeoutMs)` | a Promise-style UID call. |
| `uidNotify(uid, param)` | a one-way UID notification. |
| `uidSequencedNotify(uid, param)` | a FIFO one-way UID notification. |
| `p2pnameCall(name, param, timeoutMs)` | a synchronous P2PName call. |
| `p2pnameCallAsync(name, param, cb, data)` | an inline-callback P2PName call. |
| `p2pnameCallPromise(name, param, timeoutMs)` | a Promise-style P2PName call. |
| `p2pnameNotify(name, param)` | a one-way P2PName notification. |
| `p2pnameSequencedNotify(name, param)` | a FIFO one-way P2PName notification. |
| `shutdown()` | a full shutdown. |

### 8.4 `lf.network`

| Function | Notes |
|--------------------------------------------|---------------------------------|
| `setNetworkEvent(onConnect, onDisconnect)` | install the connect / disconnect handlers. |
| `clearNetworkEvent()` | remove both handlers. |
| `isNetworkEventInstalled()` | true when at least one is installed. |
| `NetworkEventListener` | the base class for object-oriented listeners. |
| `setNetworkEventListener(listener)` | install a listener instance. |

### 8.5 `lf.status`

| Function | Notes |
|---------------------------------|--------------------------------------|
| `getStatusCount()` | the number of pending messages in the queue. |
| `getStatus()` | pop the next message. |
| `drainStatus(maxMessages)` | pop up to N messages. |
| `postStatus(message)` | push a message (queued even when the main thread is not running). |
| `checkMainThread()` | is the framework running? |
| `checkApp(appName)` | is the application visible? |
| `checkApi(appName, apiName)` | is the API visible? |
| `checkUid(uid)` | is the UID visible? |
| `checkUidApi(uid, apiName)` | is the API on that UID visible? |
| `checkP2PName(p2pName)` | is the group name visible? |
| `checkP2PNameApi(p2pName, apiName)` | is the API on that group visible? |

### 8.6 `lf.options`

Each option has a setter / getter pair. The complete list is in
[§6.17.1](#6171-the-complete-option-table).

### 8.7 `lf.address`

| Class | Notes |
|-----------------|--------------------------------------------|
| `Target` | the abstract base class (not used directly). |
| `AppTarget` | address by App name. |
| `UIDTarget` | address by UID. |
| `P2PNameTarget` | address by group name. |

**Every Target class exposes the following methods**:

| Method | Notes |
|------|------|
| `call(api, payload, {timeoutMs})` | returns a `CallPromise` to consume with `await` |
| `callAsync(api, payload, onResult, userData)` | inline callback |
| `callSync(api, payload, {timeoutMs})` | synchronous (blocking) |
| `tryCallSync(api, payload, {timeoutMs})` | synchronous, returns `null` on failure |
| `sequencedCall(api, payload, {timeoutMs})` | returns a `CallPromise`, FIFO |
| `sequencedCallAsync(api, payload, onResult, userData)` | inline callback, FIFO |
| `notify(api, payload)` | one-way, no ordering guarantee |
| `sequencedNotify(api, payload)` | one-way, FIFO |
| `hashKey()` | a stable, value-based string key |

### 8.8 `lf.async`

| Symbol | Notes |
|------|------|
| `AsyncBridge` | the process-level singleton. `instance()` / `shutdownInstance()` / `stats()` |
| `AsyncOp` | the state holder for a single async operation. |
| `CallPromise` | the Promise wrapper, carrying an `abandoned` flag. |
| `makeLegacyOp` | the low-level factory: builds a legacy callback-style op. |
| `makeFutureOp` | the low-level factory: builds an op + CallPromise pair. |
| `runAsyncWithPromise` | one-stop: build + dispatch + set the timeout. |
| `runLegacyOp` | one-stop: legacy callback style. |

### 8.9 `DataHandle`

Create an auto-recycled handle with `new lf.DataHandle("api_name")`;
create a permanent handle with `lf.DataHandle.createPermanent("api_name")`.
Always call `dispose()` when you are done, or use it inside a callback (where the library manages
its lifetime automatically).

| Method / property | Notes |
|--------------------------------------------|----------------------------|
| `DataHandle.createPermanent(apiName)` | static factory: create a permanent handle. |
| `DataHandle.fromRaw(raw, owned)` | wrap an existing pointer (internal use). |
| `writeBytes(bytes)` / `readBytes(n)` | raw byte I/O. |
| `readBytesExact(n)` / `tryReadBytes(n)` | fixed-length byte I/O. |
| `readAllBytes()` | read to the end of the buffer. |
| `writeInt8` … `writeDouble` | little-endian atomic writes. |
| `readInt8` … `readDouble` | little-endian atomic reads. |
| `tryReadInt8` … `tryReadDouble` | non-throwing atomic reads. |
| `writeString(s)` / `readString()` | NUL-framed UTF-8. |
| `tryReadString()` | a non-throwing `readString`. |
| `writeUid(uid)` / `readUid()` | 32-byte UID read/write (no NUL). |
| `getP2PUid()` | read the sender's UID (INPUT only). |
| `getP2PName()` | read the sender's group name (INPUT only). |
| `position` / `size` | the cursor and the buffer size. |
| `getBufferPointer()` | the native pointer of the internal buffer. |
| `dispose()` | release the native handle. |
| `isValid` / `isOwning` / `raw` | state accessors. |

### 8.10 `AppHandle`

Created with `new lf.AppHandle("name", "description")`. Always call `dispose()` when you are done.

| Method | Notes |
|-----------------------------------------------|-----------------------|
| `registerCall(name, desc, handler)` | register a Call API. |
| `registerNotify(name, desc, handler)` | register a Notify API. |
| `unregister(name)` | remove a registered API. |
| `localCall(param)` / `localNotify(param)` | in-process calls. |
| `bind()` | bind to an idle client. |
| `dispose()` | unbind and stop the threads. |
| `name` / `isValid` / `raw` | state accessors. |

### 8.11 The exception hierarchy

| Type | Base class | Extra fields |
|---------------------------------|-----------------------------|-------------------------|
| `LingoFuseError` | `Error` | `cause` |
| `LingoFuseLibraryLoadError` | `LingoFuseError` | `libraryName` |
| `LingoFuseCallError` | `LingoFuseError` | `targetApp`, `targetApi` |
| `LingoFuseTimeoutError` | `LingoFuseError` | `targetApp`, `targetApi`, `timeoutMs` |
| `LingoFuseIoError` | `LingoFuseError` | `operation` |
| `LingoFuseObjectDisposedError` | `LingoFuseError` | `objectName` |
| `LingoFuseCallbackError` | `LingoFuseError` | `source`, `originalCause` |
| `LingoFuseRegistrationError` | `LingoFuseError` | `apiName` |

**Catching strategy**: catching `LingoFuseError` covers every exception this library throws; use
`instanceof` on the subclasses when you need finer handling.

```javascript
try {
    // ... LingoFuse operations ...
} catch (err) {
    if (err instanceof lf.LingoFuseTimeoutError) {
        console.error("timed out:", err.targetApp, err.timeoutMs);
    } else if (err instanceof lf.LingoFuseCallError) {
        console.error("call failed:", err.targetApp, err.message);
    } else if (err instanceof lf.LingoFuseError) {
        console.error("LingoFuse error:", err.message);
    } else {
        throw err;      // not thrown by this library, rethrow it
    }
}
```

---

## Appendix A — cross-language compatibility

This library is **byte-compatible** with the following languages:

| Language | Files |
|---------|-------------------------------|
| C | `LingoFuse.h` / `LingoFuse.c` |
| C++ | `LingoFuse.hpp` / `lf_io.hpp` |
| C# | `LingoFuse.cs` / `LfIo.cs` |
| Pascal | `lingofuse_import.pas` |
| Python | `lingofuse.lf_io` |
| JS | this package |

The same JSON payload produces the same wire bytes on every binding, and the read semantics are
identical. Cross-language RPC needs no transcoding layer.

## Appendix B — API correspondence with C++ / C#

| Function | C++ | C# | JS |
|---------------------|------------------------------------|-----------------------------------|----------------------------------------|
| load the runtime | `LF_LoadLibrary()` | automatic (lazy CLR loading) | `lf.loadLibrary()` (idempotent; may be omitted) |
| create a data handle | `DataHandle dh("api")` | `new DataHandle("api")` | `new lf.DataHandle("api")` |
| create a permanent handle | `DataHandle::createPermanent(...)` | `DataHandle.CreatePermanent(...)` | `lf.DataHandle.createPermanent(...)` |
| write JSON | `dh.writeJson(obj)` | `LfIo.WriteJson(dh, obj)` | `lf.io.writeJson(dh, obj)` |
| read JSON | `dh.readJson()` | `LfIo.ReadJson<T>(dh)` | `lf.io.readJson(dh)` |
| remote call (explicit) | `lingofuse::call(...)` | `Framework.Call(...)` | `lf.framework.call(...)` |
| remote call (try) | `lingofuse::tryCall(...)` | `Framework.TryCall(...)` | `lf.framework.tryCall(...)` |
| **three call styles** | `call` / `callAsync` / `tryCall` | `Call` / `CallAsync` / `TryCall` | `call` / `callAsync` / `callSync` |
| **App addressing** | `lingofuse::AppTarget` | `Framework.AppTarget` | `new lf.AppTarget(...)` |
| **UID addressing** | `lingofuse::UIDTarget` | `Framework.UIDTarget` | `new lf.UIDTarget(...)` |
| **P2PName addressing** | `lingofuse::P2PNameTarget` | `Framework.P2PNameTarget` | `new lf.P2PNameTarget(...)` |
| **typed options** | `LF_Set_Opt_*` / `LF_Get_Opt_*` | `Lf.SetOpt*` / `Lf.GetOpt*` | `lf.options.setOpt* / getOpt*` |
| **P2P identity read** | `dh.getP2PUid()` / `getP2PName()` | `dh.GetP2PUid()` / `GetP2PName()` | `dh.getP2PUid()` / `dh.getP2PName()` |
| generate a unique name | `generateAppName()` | `Framework.GenerateAppName()` | `lf.framework.generateAppName()` |
| query an App's authoritative name | `getAppName(app)` | `Framework.GetAppName(app)` | `lf.framework.getAppName(app)` |
| callback error reporting | none (exceptions are swallowed) | `Framework.CallbackErrorHandler` | `lf.framework.setCallbackErrorHandler` |
| shutdown | `shutdown()` | `Framework.Shutdown()` | `lf.framework.shutdown()` |

## Appendix C — further reading

- [PORTABILITY.md](PORTABILITY.md) — detailed notes for each runtime.
- the `lf-io.js` file header — the full wire format and serialization policy.
- the `data-handle.js` file header — ownership, I/O failure semantics, the two handle kinds.
- the `app-handle.js` file header — callback lifecycle and thread model.
- the `framework.js` file header — the process-level contract and numeric parameters.
- the `binding.js` file header — Koffi declarations and platform detection.
- the `address.js` file header — the semantics of the three addressing modes.
- the `async-support.js` file header — the async subsystem's design rationale and state machine.
- the `options.js` file header — what typed options are for, and their pitfalls.
- the `p2p-registration.js` file header — the isolation of the process-level P2P namespace.

## Appendix D — licence

MIT. See the `license` field of `package.json`.

