# The LingoFuse TypeScript binding

> Chinese version: [README.md](README.md)

The TypeScript binding for the LingoFuse distributed RPC framework. It calls the LingoFuse native library's C ABI through [Koffi](https://koffi.dev/) and supports **Node.js 18+**, **Deno 2.x** and **Bun 1.x+**.

This binding is **byte-level interoperable** with the C++, C#, Pascal, JavaScript and Python versions:

- the same **59** exported C functions.
- the same NUL-terminated UTF-8 wire format.
- the same JSON serialization policy (compact, literal UTF-8, no `\uXXXX` escapes).
- the same three-state tolerant string reads.
- the same **three addressing modes** (App name / UID / P2PName).
- the same **three call styles** (Promise / callback / synchronous).
- the same **handle ownership model** (synchronous family / asynchronous family).
- the same **P2P identity side-data semantics** (`getP2PUid` / `getP2PName`).
- the same cleanup order (LF-CLEAN-001).

Logic that works on one binding works the same on the others.

---

## What changed from v1.0 to v2.0

v1.0 was a straight C ABI translation layer: it covered only 36 of the 59 exported functions and offered only App-name addressing and synchronous calls.

v2.0 completes the full capability set and builds a **business-oriented abstraction layer** on top of it:

| Dimension | v1.0 | v2.0 |
|------|:----:|:----:|
| C ABI coverage | 36 / 59 | **59 / 59** |
| call styles | synchronous | synchronous + callback + **Promise (async/await)** |
| addressing modes | App name | App name / **UID** / **P2PName** |
| runtime options | the generic `setOption` | generic + **16 typed shortcut pairs** |
| P2P identity reads | none | `DataHandle.getP2PUid` / `getP2PName` |
| P2P global registration | none | `registerP2PCall` / `registerP2PNotify` |
| async subsystem | none | `AsyncBridge` / `CallPromise` / `AsyncOp` |
| exception hierarchy | 6 classes | **8 classes** |
| test suite | 127 cases | 127 + **99 cases** |

**No breaking changes**. All v1.0 code runs unchanged on v2.0.

---

## Contents

1. [Project structure](#1-project-structure)
2. [Requirements](#2-requirements)
3. [Dependencies](#3-dependencies)
4. [Installation and build](#4-installation-and-build)
5. [Placing the native shared library](#5-placing-the-native-shared-library)
6. [How to run it](#6-how-to-run-it)
7. [Quick start](#7-quick-start)
   - [7.1 A minimal server](#71-a-minimal-server)
   - [7.2 A minimal client](#72-a-minimal-client)
   - [7.3 The three call styles](#73-the-three-call-styles)
   - [7.4 The three addressing modes](#74-the-three-addressing-modes)
8. [Runtime options](#8-runtime-options)
9. [Reading the P2P identity](#9-reading-the-p2p-identity)
10. [Process-level P2P registration](#10-process-level-p2p-registration)
11. [The async subsystem](#11-the-async-subsystem)
12. [How to test](#12-how-to-test)
13. [Troubleshooting](#13-troubleshooting)
14. [API quick reference](#14-api-quick-reference)

---

## 1. Project structure

```
ts/
├── package.json              the project manifest
├── tsconfig.json             the development configuration (type checking)
├── tsconfig.build.json       the build configuration (produces dist/)
├── README.md                 this document
├── .vscode/
│   ├── launch.json           the debug configuration
│   └── settings.json         VS Code workspace settings
├── src/                      the source code (the compiler input)
│   ├── index.ts              the public entry point, re-exports
│   ├── errors.ts             the exception hierarchy + ErrorCode (8 classes)
│   ├── types.ts              pure type declarations (no runtime code)
│   ├── runtime.ts            Node / Deno / Bun runtime detection
│   ├── options.ts            runtime option constants + 16 typed shortcut pairs
│   ├── binding.ts            Koffi declarations + library loading + the 59 functions
│   ├── library-loader.ts     the RAII loader
│   ├── data-handle.ts        the RAII wrapper around TDataHnd (including P2P identity reads)
│   ├── app-handle.ts         the RAII wrapper around TAppHnd
│   ├── lf-io.ts              JSON / string / byte I/O
│   ├── framework.ts          the process-level ABI facade (low level)
│   ├── network-events.ts     connect / disconnect events
│   ├── status.ts             the status queue and health checks (including UID / P2PName checks)
│   ├── address.ts            the three-addressing Target abstraction (new in v2.0)
│   ├── async-support.ts      the async subsystem (new in v2.0)
│   └── p2p-registration.ts   process-level P2P registration (new in v2.0)
├── examples/
│   └── hello-world.ts        an end-to-end demo (not part of the build)
├── cross/
│   ├── cross-service.ts      the cross-language coordinator
│   ├── cross-node.ts         the cross-language worker node
│   └── cross-call.ts         the cross-language load test
├── test/
│   ├── test.ts               the v1.0 baseline suite (127 cases)
│   └── test-v2.ts            the v2.0 suite (99 cases)
└── dist/                     the build output (produced by the build)
```

Every module under `src/` is independently importable. `index.ts` is the public entry point; the other modules are exposed through namespaces or named exports.

**The layered architecture** (top to bottom):

```
L6  entry aggregation layer    index.ts
L5  business abstraction layer address.ts / async-support.ts / options.ts / p2p-registration.ts
L4  process-level facade layer framework.ts / status.ts / network-events.ts
L3  RAII handle layer          data-handle.ts / app-handle.ts / lf-io.ts
L2  types & exceptions layer   types.ts / errors.ts / runtime.ts
L1  native declaration layer   binding.ts  (59 / 59)
```

The dependency direction is strictly one-way downwards; no upper layer may be imported by a lower one.

---

## 2. Requirements

### 2.1 The version matrix

| Component | Minimum | Recommended | Notes |
|------|:--------:|:----:|------|
| **Node.js** | 18 | 20 LTS or 22 | one of the runtimes |
| **Deno** | 2.0 | the newest 2.x | one of the runtimes (optional) |
| **Bun** | 1.0 | the newest 1.x | one of the runtimes (optional) |
| **TypeScript** | 5.0 | 5.6.x | needed at compile time only |
| **Koffi** | 3.3.2 | 3.3.2+ | the FFI dependency, installed automatically |
| **@types/node** | 20 | 22.x | type declarations only, a devDependency |
| **tsx** (optional) | 4.0 | the newest 4.x | run `.ts` files directly |

**Any one of the three suffices**: installing Node.js, Deno or Bun alone lets you run this binding. Install all of them if you want to verify across runtimes.

### 2.2 Operating systems

| Platform | Supported architectures | Notes |
|------|-----------|------|
| Windows | x64 / x86 | needs `LingoFuse64.dll` or `LingoFuse32.dll` |
| Linux | x64 / arm64 | needs `liblingofuse.so` |
| macOS | x64 / arm64 | needs `liblingofuse.dylib` |
| FreeBSD / OpenBSD | x64 | needs `liblingofuse.so` (Koffi ships official prebuilt binaries) |

Koffi provides **prebuilt native binaries** for all the platforms above, so installing it **requires no C++ toolchain**.

### 2.3 Preparing a Windows environment

**Installing Node.js**

1. Download the MSI installer for Node.js 18 or newer from <https://nodejs.org/en/download/>.
2. Run the MSI with the default options throughout.
3. Verify in a **new** PowerShell window:

   ```powershell
   node --version
   npm --version
   ```

   Expect `v20.x.x` or higher, and `10.x.x` or higher.

**Installing Deno (optional)**

```powershell
irm https://deno.land/install.ps1 | iex
```

**Installing Bun (optional)**

```powershell
powershell -c "irm bun.sh/install.ps1 | iex"
```

### 2.4 Preparing a Linux environment

**Installing Node.js**

nvm is recommended (it is distribution-independent):

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
source ~/.bashrc      # or ~/.zshrc
nvm install 20
nvm use 20
```

Or the distribution's package manager (Debian / Ubuntu):

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

Verify:

```bash
node --version
npm --version
```

**Installing Deno (optional)**

```bash
curl -fsSL https://deno.land/install.sh | sh
```

**Installing Bun (optional)**

```bash
curl -fsSL https://bun.sh/install | bash
```

### 2.5 Preparing a macOS environment

**Installing Node.js**

```bash
brew install node@20
```

Or use nvm (the same as on Linux).

**Installing Deno / Bun (optional)**

```bash
brew install deno
brew install oven-sh/bun/bun
```

---

## 3. Dependencies

### 3.1 Runtime dependencies

| Package | Version | Purpose |
|----|------|------|
| `koffi` | `^3.3.2` | the FFI layer: loading dynamic libraries, declaring C functions, bridging callbacks |

Koffi is the **only** runtime dependency. It ships prebuilt binaries for every supported platform and automatically selects the package for the current platform through the `optionalDependencies` mechanism:

| Platform | The package installed automatically |
|------|-------------|
| Windows x64 | `@koromix/koffi-win32-x64` |
| Windows x86 | `@koromix/koffi-win32-ia32` |
| Linux x64 | `@koromix/koffi-linux-x64` |
| Linux arm64 | `@koromix/koffi-linux-arm64` |
| macOS x64 | `@koromix/koffi-darwin-x64` |
| macOS arm64 | `@koromix/koffi-darwin-arm64` |

### 3.2 Development dependencies

| Package | Version | Purpose |
|----|------|------|
| `typescript` | `^5.6.0` | compile `.ts` → `.js` |
| `@types/node` | `^22.0.0` | Node.js global types (`process` / `TextEncoder` / `__dirname`) |
| `tsx` (optional) | `^4.0.0` | run `.ts` files directly (without compiling) |

`@types/node` is **required**, because `binding.ts` uses `node:path` / `node:fs`, `app-handle.ts` uses `process.stderr`, and `test-v2.ts` uses `node:child_process`.

---

## 4. Installation and build

### 4.1 Installing the dependencies

Inside the `ts/` directory:

```bash
cd ts
npm install
```

`npm install` will:

1. read `package.json`.
2. download `koffi`, `typescript`, `@types/node` and `tsx` from the npm registry.
3. unpack the Koffi native binary for the current platform into `node_modules/@koromix/`.
4. require no build tooling at all.

**If the installation fails**:

```bash
# clear the cache and retry
npm cache clean --force
rm -rf node_modules package-lock.json   # Windows: Remove-Item -Recurse -Force
npm install

# or behind a corporate proxy
npm install --registry=https://registry.npmmirror.com
```

### 4.2 Building

```bash
npm run build
```

**Output**: the `dist/` directory, containing:

- one `.js` file per `src/*.ts`
- one `.d.ts` (type declaration) per `.js`
- one `.js.map` (source map) per `.js`
- one `.d.ts.map` (declaration jump) per `.d.ts`

**Type checking only** (no output):

```bash
npm run check
```

### 4.3 The build configuration

This project uses a **dual tsconfig** structure:

| File | Purpose | `include` | `noEmit` |
|------|------|-----------|:--------:|
| `tsconfig.json` | development / type checking | `src` / `test` / `examples` / `cross` | `true` |
| `tsconfig.build.json` | the production build | only `src` | `false` |

`tsconfig.build.json` inherits the compiler options from `tsconfig.json` through `extends` and overrides only the build-related fields such as `noEmit` / `declaration` / `outDir`.

**The key settings**:

| Option | Value | Meaning |
|------|-----|------|
| `target` | `ES2022` | output syntax level (supported by Node 18+ / Bun / Deno) |
| `module` | `commonjs` | emit `require()` / `module.exports` |
| `moduleResolution` | `node10` | traditional node_modules resolution |
| `ignoreDeprecations` | `"6.0"` | silence the TS 6.0 `node10` deprecation warning |
| `strict` | `true` | the full strict check set |
| `declaration` | `true` | generate `.d.ts` |

**On `ignoreDeprecations: "6.0"`**:

TypeScript 6.0 marks `moduleResolution: "node10"` as deprecated. This project explicitly declares `"ignoreDeprecations": "6.0"` to silence the warning while keeping the output as CommonJS. The reason for keeping `node10` rather than migrating to `bundler` / `nodenext` is: **the published `dist/` output is CommonJS**, and changing the module system would break existing consumers. When TS 7.0 formally removes `node10` support, this project will migrate as a whole.

**Why the output is CommonJS**: the CJS format has the widest compatibility across Node.js, Bun and Deno. `"type": "commonjs"` in `package.json` corresponds to it.

---

## 5. Placing the native shared library

**This binding does not include** the LingoFuse native shared library. That library must be built separately from the Pascal / C++ source.

### 5.1 The expected file names

| Platform | File name |
|------|--------|
| Windows 64-bit | `LingoFuse64.dll` |
| Windows 32-bit | `LingoFuse32.dll` |
| Linux / BSD | `liblingofuse.so` |
| macOS | `liblingofuse.dylib` |

### 5.2 The search order

`buildSearchPaths()` in `binding.ts` tries the following in order:

1. **the directory of the current executable** (the parent directory of `process.execPath`)
2. **the current working directory** (`process.cwd()`)
3. **the `native/` subdirectory next to the package** (`__dirname/../native/`)
4. **the operating system loader search path** (as the final fallback):
   - Windows: the `PATH` environment variable
   - Linux: `LD_LIBRARY_PATH` and `/etc/ld.so.conf`
   - macOS: `DYLD_LIBRARY_PATH` and `/usr/local/lib`

Any of these locations works. **The simplest approach** is to copy the shared library into the same directory as your script, or to add it to the system loader path.

### 5.3 Placement examples

**Windows**:

```powershell
# option A: put it in the directory you run your script from
Copy-Item D:\LingoFuse\Binary\LingoFuse64.dll C:\MyApp\

# option B: add to PATH (valid only in the current PowerShell session)
$env:PATH += ";D:\LingoFuse\Binary"

# option C: add to PATH permanently
[Environment]::SetEnvironmentVariable(
    "PATH",
    $env:PATH + ";D:\LingoFuse\Binary",
    "User")
```

**Linux**:

```bash
# option A: put it in the directory you run your script from
cp /opt/lingofuse/lib/liblingofuse.so /home/user/myapp/

# option B: add to LD_LIBRARY_PATH
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:/opt/lingofuse/lib"

# option C: install into a system directory (requires root)
sudo cp /opt/lingofuse/lib/liblingofuse.so /usr/local/lib/
sudo ldconfig
```

**macOS**:

```bash
# option A: put it in the directory you run your script from
cp /opt/lingofuse/lib/liblingofuse.dylib ~/myapp/

# option B: add to DYLD_LIBRARY_PATH
export DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH:/opt/lingofuse/lib"

# option C: install into a system directory
sudo cp /opt/lingofuse/lib/liblingofuse.dylib /usr/local/lib/
```

---

## 6. How to run it

TypeScript has four execution paths; pick one according to the use case.

### 6.1 Option one: `tsx` runs `.ts` directly (recommended for development)

`tsx` is a zero-configuration TypeScript runner that compiles and runs on the fly. **No prior compilation into `dist/` is needed**.

**Installing**:

```bash
npm install -D tsx
```

**Running the example**:

```bash
npx tsx examples/hello-world.ts
```

Or add a script in `package.json`:

```json
"scripts": {
  "demo": "tsx examples/hello-world.ts"
}
```

Then:

```bash
npm run demo
```

**Advantages**:

- supports `.ts` path imports (`import * as lf from "../src/index"` resolves straight to the `.ts` source)
- supports both ESM and CJS syntax
- an industry standard (Vite / Vitest / Next.js all use it internally)

### 6.2 Option two: Bun runs `.ts` directly

Bun has built-in TypeScript support and **needs no preprocessing at all**.

```bash
bun run examples/hello-world.ts
```

Running your own service script:

```bash
bun run my-service.ts
```

**Advantages**:

- zero configuration, zero dependencies
- the fastest startup (3-5× faster than Node.js)

### 6.3 Option three: Deno runs `.ts` directly

Deno has built-in TypeScript support, **but requires explicit permission flags**.

```bash
deno run \
    --allow-ffi \
    --allow-read \
    --allow-env \
    --allow-net \
    --allow-sys \
    examples/hello-world.ts
```

**The reason for each permission flag**:

| Flag | Necessity | Purpose |
|------|:------:|------|
| `--allow-ffi` | **required** | load Koffi's native library |
| `--allow-read` | **required** | Koffi reads the environment and library file paths |
| `--allow-env` | **required** | Koffi reads environment variables |
| `--allow-net` | **required** | LingoFuse's network I/O |
| `--allow-sys` | recommended | process and system information probing |
| `--allow-run` | needed by the test suite | the v2.0 suite starts a watchdog child process |

**Adding a shebang to your script** (optional):

```typescript
#!/usr/bin/env -S deno run --allow-ffi --allow-read --allow-env --allow-net --allow-sys
```

Then:

```bash
deno run my-service.ts
```

### 6.4 Option four: compile, then run (for production deployment)

Compile into `dist/` first, then run the emitted JavaScript:

```bash
npm run build
node dist/index.js          # or dist/<your entry file>.js
```

Or reference the compiled package from your own project:

```typescript
import * as lf from "lingofuse-ts";
```

**Advantages**:

- no TypeScript compiler needed at startup (less runtime overhead)
- can be packaged into a Docker image
- used exactly like any other JavaScript project

**Note**: the `examples/` directory **is not part of the build** (`tsconfig.build.json`'s `include` is only `src/**/*.ts`). The example scripts are run directly by `tsx` / `bun` / `deno`.

---

## 7. Quick start

This section demonstrates v2.0's **three call styles** and **three addressing modes**. All examples assume you have completed the installation steps in [§4](#4-installation-and-build) and placed the native shared library as described in [§5](#5-placing-the-native-shared-library).

### 7.1 A minimal server

```typescript
import * as lf from "lingofuse-ts";

lf.loadLibrary();

// 1. create the app
const app = new lf.AppHandle("Calculator", "Add two integers");

// 2. register a Call API (the callback holds the business code directly)
app.registerCall<{ a: number; b: number }, { result: number }>(
    "add",
    "Add two integers",
    (input, output) => {
        const req = lf.io.readJson<{ a: number; b: number }>(input) ?? { a: 0, b: 0 };
        lf.io.writeJson(output, { result: req.a + req.b });
    });

// 3. prepare the network
lf.options.setOptWaitConnectionReadyOk(false);
lf.framework.resetPrepare();
lf.framework.prepareService("ipc:calc", "ipc:calc");
lf.framework.prepareClient("ipc:calc", app);

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

// 4. wait for the app to become visible on the mesh (required when Wait_Ready=False)
while (!lf.status.checkApp("Calculator")) {
    await new Promise((r) => setTimeout(r, 100));
}

console.log("Server ready");

// 5. clean up (when the process exits)
lf.framework.exitMainThread();
app.dispose();
lf.framework.shutdown();
```

### 7.2 A minimal client

```typescript
import * as lf from "lingofuse-ts";

lf.loadLibrary();

lf.options.setOptWaitConnectionReadyOk(false);
lf.framework.resetPrepare();
lf.framework.prepareClient("ipc:calc", null);   // a pure consumer, no App

if (lf.framework.prepareDone() !== 1) {
    throw new Error("framework startup failed");
}

while (!lf.status.checkApp("Calculator")) {
    await new Promise((r) => setTimeout(r, 100));
}

// ---- the modern call (recommended in v2.0) ----
const target = new lf.AppTarget("Calculator");
const result = await target.call<{ a: number; b: number }, { result: number }>(
    "add", { a: 5, b: 7 });
console.log("5 + 7 =", result.result);   // 12

// ---- cleanup ----
lf.framework.exitMainThread();
lf.framework.shutdown();
```

### 7.3 The three call styles

All three styles share the same underlying `AsyncBridge` subsystem and can be mixed freely.

| Style | Entry point | Blocking? | Suited to |
|------|------|:------:|------|
| **A. Promise** | `await target.call("api", payload)` | no (suspends) | modern async business code |
| **B. Inline callback** | `target.callAsync("api", payload, cb)` | no | event-driven code, business logic written in the callback |
| **C. Synchronous** | `target.callSync("api", payload)` | yes | scripts, tests, CLI tools |

#### Style A — Promise (recommended for modern business code)

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

**Cancellation semantics**: `CallPromise` is **not** a standard `Promise`; it carries an extra `abandoned` flag. When the JS-side timeout arrives before the native callback:

- `CallPromise` rejects with `LingoFuseTimeoutError`
- `abandoned` becomes `true`
- **the native request is not cancelled**: `AsyncBridge` keeps the callback alive for a grace period (60 seconds by default), and any late result is discarded

#### Style B — Inline callback (business code written straight into the callback)

```typescript
const target = new lf.AppTarget("Calculator");

target.callAsync<{ a: number; b: number }, { result: number }>(
    "add",
    { a: 5, b: 7 },
    (res, err, userData) => {
        // the business code goes right here, with no await and no Promise wrapping
        if (err) {
            console.error("call failed:", err.message);
            return;
        }
        console.log("5 + 7 =", res!.result);   // 12
    });
```

The callback signature: `(result, error, userData) => void`.

| Parameter | Meaning |
|------|------|
| `result` | the deserialized JSON value; `null` on failure |
| `error` | a `LingoFuseError` / `LingoFuseTimeoutError` instance; `null` on success |
| `userData` | the optional fourth argument passed to the call |

**Key points**:

- the callback **runs on the JS event loop** (marshalled over by the Koffi bridge from a native worker thread). **Do not block it**.
- **do not** call any synchronous LingoFuse function (such as `callSync`) inside the callback — it deadlocks.
- an exception thrown by the callback body is swallowed and written to stderr; it is never propagated back onto the native stack.

#### Style C — Synchronous

```typescript
const target = new lf.AppTarget("Calculator");

const result = target.callSync<{ a: number; b: number }, { result: number }>(
    "add", { a: 5, b: 7 }, { timeoutMs: 3000 });
console.log("result:", result.result);   // 12
```

There is also a non-raising version:

```typescript
const result = target.tryCallSync<{ a: number; b: number }, { result: number }>(
    "add", { a: 5, b: 7 }, { timeoutMs: 3000 });
if (result === null) {
    console.log("call failed");
} else {
    console.log("result:", result.result);
}
```

**Warning**: `callSync` **blocks the JS event loop** until the native call returns. Use it only in scripts, tests and CLI tools. Do not use it on a server's hot path.

### 7.4 The three addressing modes

All three modes share one call interface (`call` / `callAsync` / `callSync` / `tryCallSync` / `sequencedCall` / `sequencedCallAsync` / `notify` / `sequencedNotify`) and differ only in their **routing semantics**.

| Target type | Routing key | Local first? | Load balanced? | Typical use |
|-------------|--------|:---------:|:---------:|---------|
| `AppTarget` | App name (string) | ✅ | ❌ | fixed services |
| `UIDTarget` | UID (32 bytes) | ✅ | ❌ | **targeting a specific client** |
| `P2PNameTarget` | group name (string) | ❌ | ✅ | homogeneous service clusters |

#### 7.4.1 `AppTarget` — addressing by App name

The most common approach. Routes to **any** client with a matching name.

```typescript
const target = new lf.AppTarget("Calculator");
const result = await target.call("add", { a: 1, b: 2 });
```

**Local first**: if the caller's own process registers an app of the same name and exposes the target API, the call completes **locally** without going over the network.

#### 7.4.2 `UIDTarget` — addressing by session UID

Routes to a **specific** 32-byte session. Suited to cases like "I want to message the client I was just talking to".

```typescript
// the UID may be a Uint8Array(32) or a 64-character hex string.
const uidHex = "4fa01fc4a85b6099a037c5a3f01f49a89564268a2d7fd48009d636246cfc2633";
const target = new lf.UIDTarget(uidHex);

const result = await target.call("add", { a: 1, b: 2 });
```

**A UID can reach any API on the target**, whether it was registered by an App (`app.registerCall`) or at process level by P2P (`registerP2PCall`) — you do not need to know the target's App name.

**UID lifetime**: the UID is **regenerated on every `TunnelLink`**. A caller that cached a UID **must re-probe it after the link drops**.

#### 7.4.3 `P2PNameTarget` — addressing by group name

Routes to a client in any user-defined group. The **server load balances**.

```typescript
const target = new lf.P2PNameTarget("workers");

// the server picks one of all clients whose P2PName is "workers"
const result = await target.call("process", { task: "..." });
```

**Not local first**: even when the caller's own process belongs to the target group, the call is **forwarded to the server** for dispatch. This is deliberate: the server holds the load-balancing state.

**Setting your own group name**:

```typescript
lf.options.setOptP2PName("workers");
```

This must be set before `prepareDone()`, or reported through the `Update_UID` command (checked automatically every second).

#### 7.4.4 `hashKey()` — a stable key for Map / Set

JS `Map` / `Set` compare keys **by reference**. If you want to use a Target as a dictionary key, use `hashKey()`:

```typescript
const m = new Map<string, number>();
m.set(new lf.AppTarget("X").hashKey(), 1);
m.get(new lf.AppTarget("X").hashKey());   // => 1
```

Each addressing mode returns a prefixed key: `app:X`, `uid:<hex64>`, `p2p:G`. The three modes **never collide** (even when the string parts match).

---

## 8. Runtime options

The `lf.options` namespace provides **16 typed setter/getter pairs**, corresponding one for one to the `LF_Set_Opt_*` / `LF_Get_Opt_*` family in the Pascal / C# / JavaScript bindings.

### 8.1 The complete option table

| Option | Setter / Getter | Type | Default |
|--------|-----------------|------|------|
| `password` | `setOptPassword` / `getOptPassword` | string | empty (returns the fixed mask `"********"`) |
| `debug` | `setOptDebug` / `getOptDebug` | string (write-only) | — |
| `Quiet` | `setOptQuiet` / `getOptQuiet` | bool | `false` |
| `ShowThreadID` | `setOptShowThreadID` / `getOptShowThreadID` | bool | `true` |
| `ConsoleOutput` | `setOptConsoleOutput` / `getOptConsoleOutput` | bool | platform-dependent |
| `Overlap_Connection` | `setOptOverlapConnection` / `getOptOverlapConnection` | bool | `false` |
| `Wait_Connection_ReadyOk` | `setOptWaitConnectionReadyOk` / `getOptWaitConnectionReadyOk` | bool | `true` |
| `Wait_Connection_Timeout` | `setOptWaitConnectionTimeout` / `getOptWaitConnectionTimeout` | int (ms) | `30000` |
| `IPC_Serv_ThreadCount` | `setOptIpcServThreadCount` / `getOptIpcServThreadCount` | int | platform-dependent |
| `IPC_Serv_MaxQueueLength` | `setOptIpcServMaxQueueLength` / `getOptIpcServMaxQueueLength` | int | platform-dependent |
| `IPC_Serv_MaxMsgSize` | `setOptIpcServMaxMsgSize` / `getOptIpcServMaxMsgSize` | int (bytes) | platform-dependent |
| `Fixed_Sequenced_Time` | `setOptFixedSequencedTime` / `getOptFixedSequencedTime` | int (ms) | `20000` |
| `LF_P2P_name` | `setOptP2PName` / `getOptP2PName` | string | empty |
| `DataHandle_Idle_Timeout` | `setOptDataHandleIdleTimeout` / `getOptDataHandleIdleTimeout` | int (ms) | `600000` (10 minutes) |
| `DataHandle_Pool_Scan_Interval` | `setOptDataHandlePoolScanInterval` / `getOptDataHandlePoolScanInterval` | int (ms) | `5000` (5 seconds) |
| `No_Reponse_Cmd_NULL_Flush_Threshold` | `setOptNoReponseCmdNullFlushThreshold` / `getOptNoReponseCmdNullFlushThreshold` | int | `5000` |

> **Watch the spelling**: `No_Reponse` is missing an `s` — a historical spelling from the Pascal side. Both the typed function names and the option keys keep that spelling.

### 8.2 A usage example

```typescript
const lf = require("lingofuse-ts");

lf.loadLibrary();

lf.options.setOptOverlapConnection(true);
lf.options.setOptWaitConnectionReadyOk(false);
lf.options.setOptP2PName("my_group");

console.log(lf.options.getOptP2PName());              // "my_group"
console.log(lf.options.getOptWaitConnectionReadyOk()); // false
```

### 8.3 ⚠️ `LF_SetOption` is delivered asynchronously

Once the LingoFuse simulated main thread has started (that is, once `prepareDone()` returns 1), `LF_SetOption` **posts the change to the main thread** via `MainThreadPost.PostM_NP(DoRun)` and it is applied on the next tick. **A getter called immediately after the setter returns reads the old value**.

```typescript
// ❌ wrong: you may read the old value
lf.options.setOptQuiet(true);
console.log(lf.options.getOptQuiet());   // may still be false

// ✅ right: wait for the main thread to apply it
lf.options.setOptQuiet(true);
await new Promise((r) => setTimeout(r, 150));
console.log(lf.options.getOptQuiet());   // true
```

150 milliseconds is far larger than the main thread's 1-10 millisecond tick granularity.

**Setting options before `prepareDone()`** is not subject to this restriction — the main thread has not started yet, and `LF_SetOption` applies **synchronously**.

### 8.4 Unknown option names are silently ignored

`LF_SetOption` has no return value and **does not report an error** when it receives an unrecognised option name. The typed shortcuts eliminate this failure mode by hard-coding the option names, but `lf.framework.setOption("Typo", "x")` will still be silently ignored.

### 8.5 The generic `setOption` / `getOption` remain available

The typed shortcuts **layer on top of** the generic API rather than replacing it:

```typescript
// a dynamic option name (read from a configuration file)
const optionName = process.env.LF_OPTION_NAME || "Quiet";
lf.framework.setOption(optionName, "True");

// or read the raw string value
const raw = lf.framework.getOption("Quiet");   // "True" / "False" / ""
```

Both paths share the same underlying native call, and mixing them is safe.

---

## 9. Reading the P2P identity

Every **inbound request payload** in LingoFuse carries two identity fields for the sender, injected automatically by the **sender's transport layer** before sending:

```
[apiName: string]
[FromUID: 32 bytes]         ← the sender's session UID
[FromP2PName: string]       ← the sender's P2P group name
[Param.Size: Int32]
[Param: bytes]
```

These two fields are **"side data"**. They are **not properties of the handle itself** but metadata the sender writes into the payload header. **The receiver can read them only on the `Input` parameter of the callback that fires the event**.

### 9.1 The two accessors

`DataHandle` has two accessors:

```typescript
const uid  = input.getP2PUid();    // Uint8Array(32)
const name = input.getP2PName();   // string ("" when unset)
```

### 9.2 They can be called only on INPUT handles

| Location | Valid? |
|------|:--------:|
| the callback's `input` parameter | ✅ |
| a local call's `input` | ✅ |
| the callback's `output` parameter | ❌ (returns 32 zero bytes / an empty string) |
| a handle you created with `new DataHandle(...)` | ❌ (same as above) |

Called on an invalid location, the library **does not throw**; it returns the default values (32 zeros / an empty string) and logs a warning on the native side.

### 9.3 The whoami pattern

**The classic application scenario**: a client wants to know **its own** UID (the "sender UID" the server sees).

**The server**:

```typescript
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

```typescript
const target = new lf.AppTarget("IdentitySvc");
const result = await target.call("whoami", {});

console.log("my UID:", result.uid_hex);   // 64 hex characters
console.log("my P2P:", result.p2p_name);  // e.g. "jstest2_group"

// store the UID; you can later reach this session with a UIDTarget
const myUidTarget = new lf.UIDTarget(result.uid_hex);
```

### 9.4 Implementation details (a correction)

**`LF_Get_P2P_UID` returns a pointer, not a value**. The native side returns `const TP2P_UID*` (pointing at a 32-byte buffer owned by the library) and **releases it automatically about 5 seconds later**. `DataHandle.getP2PUid()` wraps all of this:

1. copy the 32 bytes out immediately with `koffi.decode`
2. **not** release the pointer
3. **not** retain the pointer beyond this method call

The caller never sees the temporary pointer.

**`LF_Get_P2P_Name`** returns a `const char*` that likewise becomes invalid after about 5 seconds. Koffi's `str` return type copies it into a JS string at the call boundary immediately, so the value returned by `getP2PName()` is already detached from the native buffer.

### 9.5 The difference between `getP2PUid` and `options.getOptP2PName`

These two concepts are easily confused:

| Function | What it reads | Where from |
|------|--------|--------|
| `lf.options.getOptP2PName()` | the group name **I** declared | local configuration |
| `input.getP2PName()` | the group name the **sender** declared | side data (payload header) |

In other words:

- `getOptP2PName()` answers "what group name did I set for **myself**?"
- `DataHandle.getP2PName()` answers "what group name does **the party messaging me** have?"

Both are UTF-8 strings, but their sources are completely different.

---

## 10. Process-level P2P registration

Besides `App.registerCall` (App-bound registration), v2.0 also offers **process-level P2P registration**: the APIs are reachable only via UID or P2PName addressing, **not via App name**.

```typescript
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

**Typical uses**: registering a small set of globally discoverable functions (health checks, capability discovery, identity echo) that any client on the mesh can call by group name or UID without knowing the other party's App name.

**Namespace isolation**: the process-level P2P namespace is **independent of** any app. APIs registered here **are not reachable via App name** — even when the API name happens to match an App name.

**Failure semantics**: a failed registration throws `LingoFuseRegistrationError` rather than returning false. The reason is documented in the header comment of `errors.ts`.

---

## 11. The async subsystem

The `lf.async` namespace exposes `AsyncBridge` / `AsyncOp` / `CallPromise`, the **shared substrate** of v2.0's three call styles.

### 11.1 All three styles share one AsyncBridge

```typescript
const stats = lf.AsyncBridge.instance().stats();
console.log(stats);
// {
//   total: <int>,          // the number of currently active ops
//   pending: <int>,        // waiting for a callback
//   fired: <int>,          // the callback fired, waiting for release
//   abandoned: <int>,      // timed out, waiting for the grace period to expire
//   not_queued: <int>,     // dispatch failed
//   released_total: <int>, // the cumulative release count
//   grace_seconds: <float>,
//   period_seconds: <float>,
// }
```

`AsyncBridge` is a **process-level singleton**. Users of all three styles **share one set of counters**.

### 11.2 The Koffi callback lifecycle

`AsyncBridge` exists to solve three concurrency risks:

1. **Premature release after a timeout**: the native request is not cancelled because of a JS-side timeout. If we released the Koffi callback immediately on timeout, the native side would hit a dangling pointer on the later callback.
2. **A leak when dispatch fails**: if the native side rejects the request before dispatching it (the return value is not 1), the callback never fires. A naive "wait for the callback to release" policy would leak the Koffi callback permanently.
3. **A double-release race**: the JS thread (timeout) and a native worker thread (callback) may race to release the same object.

`AsyncBridge` solves the three risks with an explicit state machine (`PENDING → FIRED | ABANDONED | NOT_QUEUED`).

### 11.3 Environment variable configuration

Two environment variables are **read once at module load time**:

| Variable | Default | Meaning |
|------|:------:|------|
| `LINGOFUSE_ASYNC_RECLAIM_GRACE` | `60` | the grace period for abandoned ops (seconds) |
| `LINGOFUSE_ASYNC_RECLAIM_PERIOD` | `1.0` | the reclaim scan interval (seconds) |

### 11.4 Shutdown

Call this in `after()` / before the process exits:

```typescript
lf.AsyncBridge.shutdownInstance();
```

It will:

1. stop the reclaim loop
2. flush every pending grace timer immediately
3. release the Koffi callbacks of every outstanding op
4. clear the internal state

Failing to do this leaks Koffi handles and prevents the Node event loop from exiting.

---

## 12. How to test

### 12.1 Type checking

```bash
npm run check
```

Runs `tsc -p tsconfig.json --noEmit`; it type-checks only and produces no output. **This is the minimum requirement before committing code**.

**Expected**: no output at all (tsc is silent on success).

### 12.2 Build verification

```bash
npm run build
```

**Expected**: no output, and the `dist/` directory is produced.

If you only want to check without producing files, use `npm run check`.

### 12.3 The v1.0 baseline suite (127 cases)

```bash
npm test
```

Or directly:

```bash
npx tsx test/test.ts
```

It covers 9 test groups: `errors` / `binding` / `DataHandle` / `lf-io` / `AppHandle` / `framework` / `status` / `callbacks` / `network events`.

**The expected output tail**:

```
Summary
  runtime : Node.js 20.x.x
  passed  : 127
  failed  : 0
  total   : 127
```

### 12.4 The v2.0 suite (99 cases)

```bash
npm run test:v2
```

Or directly:

```bash
npx tsx test/test-v2.ts
```

It covers 12 test groups:

| # | Test group | What it covers |
|:-:|--------|--------|
| 1 | `errors-v2` | the 8 exception classes, `LingoFuseTimeoutError` fields, `ErrorCode.Timeout` |
| 2 | `CallPromise` | thenable / `abandoned` / `settled` / idempotence / `await` |
| 3 | `AsyncBridge` | the singleton / stats / shutdown idempotence / the default grace and period |
| 4 | `Targets` | constructing the three Targets / `hashKey` / UID normalization / the 8 methods |
| 5 | `options` | round trips for the 16 typed setter/getter pairs + argument validation |
| 6 | `framework.getOption` | consistency with the typed versions / unknown names returning an empty string / argument types |
| 7 | `DataHandle UID methods` | `writeUid` / `readUid` / `getP2PUid` / `getP2PName` |
| 8 | `p2p-registration` | registration / unregistration / duplicates throwing / argument validation |
| 9 | `status UID checks` | the 4 check functions / hex strings / argument validation |
| 10 | `Integration: call shapes` | the three styles + `userData` + `notify` |
| 11 | `Integration: UIDTarget` | UID end to end; accepting both `Uint8Array(32)` and hex |
| 12 | `Integration: side data` | `whoami` reading the P2P identity / the defaults on the `output` side |

**The expected output tail**:

```
Summary
  runtime : Node.js 20.x.x
  passed  : 99
  failed  : 0
  total   : 99
```

### 12.5 The three hard constraints

The v2.0 suite enforces three hard constraints (see the file header of `test/test-v2.ts`):

| ID | Constraint | Reason |
|:--:|------|------|
| **C1** | never register APIs dynamically while the tests run | `registerCall` triggers a 1-second-delayed `Init_App_Info` broadcast; `LF_ExitMainThread` blocks while a broadcast is in flight |
| **C2** | never execute `debug` commands with side effects | `setOptDebug("service")` and similar trigger live queries that may leave a pending native task |
| **C3** | start a detached watchdog child process | if the native shutdown blocks the JS event loop, no in-process timer can fire; only a child process can rescue the run |

**Disabling the watchdog** (when debugging the native shutdown):

```bash
LINGOFUSE_TEST_NO_WATCHDOG=1 npx tsx test/test-v2.ts
```

### 12.6 Cross-runtime testing

The same suite is executed with each of the three runtimes:

```bash
# Node.js + tsx
npm run test:v2

# Bun
npm run test:v2:bun

# Deno (note that test-v2 needs --allow-run because it starts a watchdog)
npm run test:v2:deno
```

The three runs should produce **identical results** (apart from the `runtime` field in `Summary`).

### 12.7 Cross-language testing

This binding interoperates with the C++ / C# / Pascal / JavaScript / Python versions. How to test across languages:

1. Start a **server** using the C++ or Pascal version:

   ```powershell
   # the C++ version
   CrossService.exe

   # or the Pascal version
   cross_service.exe
   ```

2. Connect with a TypeScript script (`cross/cross-call.ts` is already provided):

   ```bash
   npx tsx cross/cross-call.ts
   ```

   `cross/cross-call.ts` randomly calls the two APIs `add` and `inv_seri` on the `demo` app, runs a 10-second load test and prints the throughput and success rate.

3. Or use the TypeScript node as a **worker node**:

   ```bash
   npx tsx cross/cross-node.ts
   ```

   It registers the two APIs `add` and `inv_seri` and waits for the peer to call.

**The files**:

| File | Role |
|------|------|
| `cross/cross-service.ts` | the coordinator (beacon + service) |
| `cross/cross-node.ts` | the worker node (exposing the `demo` app) |
| `cross/cross-call.ts` | the load-test client |

The three roles can be implemented in any mix of languages. All bindings are byte-level interoperable.

### 12.8 The pre-deployment checklist

- [ ] `npm run check` passes with no errors
- [ ] `npm run build` passes with no errors
- [ ] `npm test` passes (127 cases)
- [ ] `npm run test:v2` passes (99 cases)
- [ ] run once in the real environment of the target runtime (not just on the development machine)
- [ ] the shared library is placed correctly (see §5)
- [ ] if using Deno, all the permission flags are present (including `--allow-run` if the watchdog is started)
- [ ] if using Bun, confirm the version is ≥ 1.0
- [ ] the cleanup order is correct: `clearNetworkEvent → exitMainThread → app.dispose → shutdown`
- [ ] `lf.AsyncBridge.shutdownInstance()` is called before shutdown

---

## 13. Troubleshooting

### 13.1 `Cannot find module 'koffi'`

`node_modules/` is missing or was deleted. Run `npm install` inside the `ts/` directory.

If you moved the TS files to another directory, `node_modules/` must move with them (Node looks for packages by walking up from the location of the referring file).

### 13.2 `Failed to load the LingoFuse native library`

The shared library is not on any search path. See [§5](#5-placing-the-native-shared-library).

To see the search paths actually used:

```bash
node -e "console.log(require('./dist/binding.js').buildSearchPaths().join('\n'))"
```

### 13.3 `Unexpected void * type, expected <callback> * type`

Koffi rejected the callback registration. This **should no longer occur** in this binding's v2.0.0+. If it does, your `node_modules/koffi` is too old (< 3.3.2).

```bash
npm install koffi@latest
```

### 13.4 `Cannot find name 'process'` / `Cannot find name '__dirname'`

`@types/node` is not installed, or `tsconfig.json` lacks `"types": ["node"]`.

```bash
npm install -D @types/node
```

Confirm that `tsconfig.json` contains:

```json
"types": ["node"]
```

### 13.5 `TS5103: Invalid value for '--ignoreDeprecations'`

The TypeScript version you are using does not accept the `ignoreDeprecations` value configured in `tsconfig.json`.

**Fix**: change the value in `tsconfig.json` to `"5.0"`:

```json
"ignoreDeprecations": "5.0"
```

**Note**: TypeScript 5.9.3 has a known inconsistency — the message asks for `"6.0"` but the type definition only accepts `"5.0"`. Using `"5.0"` works across all versions from 5.5 to 5.9.

### 13.6 `Cannot use import statement outside a module`

You ran TypeScript directly with `node file.ts`, but Node.js does not natively support full TypeScript (it only strips types and makes no module decisions).

**Fix**: use `tsx`:

```bash
npx tsx file.ts
```

Or use Bun / Deno.

### 13.7 VS Code shows red errors but `npm run check` passes

VS Code uses its **built-in TypeScript version**, which may differ from the project's local version.

**Fix** (recommended): make VS Code use the workspace version.

1. Press `Ctrl + Shift + P` to open the command palette.
2. Type `TypeScript: Select TypeScript Version`.
3. Choose `Use Workspace Version`.

Or configure `.vscode/settings.json`:

```json
{
  "typescript.tsdk": "node_modules/typescript/lib",
  "typescript.enablePromptUseWorkspaceTsdk": true
}
```

### 13.8 `prepareDone()` returns 0

`prepareDone` returns 1 only once per process. A second call without an intervening `shutdown()` returns 0. **This is not a failure**.

For the full contract see the `prepareDone()` declaration in `framework.ts`.

### 13.9 A call made right after `prepareDone()` times out

The mesh is not necessarily ready at the moment `prepareDone()` returns. If `Wait_Connection_ReadyOk=False` is set (deployment mode), you must poll `checkApp` / `checkApi` explicitly:

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

`waitForApp` in `examples/hello-world.ts` follows exactly this pattern.

### 13.10 A callback throws and the process exits silently

Callbacks run on a native worker thread. An uncaught exception would cross into the C stack. This binding wraps every callback so that exceptions are swallowed and routed to `callbackErrorHandler`:

```typescript
lf.framework.setCallbackErrorHandler((source, err) => {
    console.error(`[LingoFuse] callback error in ${source}:`, err);
});
```

Install it once before registering any API.

### 13.11 Deno reports `PermissionDenied`

Deno requires explicit permissions. The test suite needs six `--allow-*` flags:

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

The reason for each flag is given in [§6.3](#63-option-three-deno-runs-ts-directly).

### 13.12 The `LF_Get_P2P_UID` pointer becomes invalid after 5 seconds

Do not keep the pointer returned by the native side. Use `DataHandle.getP2PUid()`, which copies the 32 bytes with `koffi.decode` immediately:

```typescript
// ✅ right
const uid = input.getP2PUid();   // copied immediately

// ❌ wrong: you must not hold the native pointer
const rawPtr = lf._binding.getBinding().funcs.LF_Get_P2P_UID(input.raw);
// after 5 seconds the memory rawPtr points at is released by the native side
```

### 13.13 `AsyncBridge` prevents the Node event loop from exiting

If you forget to call `lf.AsyncBridge.shutdownInstance()`, the libuv handles behind the Koffi callbacks stay ref'ed and the Node event loop cannot exit.

**Fix**: call it explicitly before the process exits:

```typescript
lf.AsyncBridge.shutdownInstance();
lf.framework.shutdown();
```

`AsyncBridge.shutdown()` releases the callbacks of every outstanding op and flushes every pending grace timer.

### 13.14 Using a handle outside the async callback

**Do not** pass out the `Result_` handle received by an async callback, or use it across threads.

```typescript
// ❌ wrong: passing the async handle out
let savedPtr: unknown = null;

target.callAsync("api", {}, (res, err) => {
    savedPtr = res;   // ❌ invalid once the callback returns
});

// ... later
// read from savedPtr   ❌ use-after-free
```

**Correct**: read and copy the data inside the callback, or use the Target's Promise style directly (which already copies inside the callback).

### 13.15 `require("D:\\...\\ts")` reports `Cannot find module`

When an absolute or relative path points directly at a directory, Node does not append `index.js` automatically. Either write the full path (`require("D:/.../ts/dist/index.js")`) or use the package name (`require("lingofuse-ts")`).

---

## 14. API quick reference

This binding exposes **seven namespaces**, **two RAII handle types**, **three addressing target classes** and **an eight-class exception hierarchy**.

### 14.1 Top-level symbols

| Symbol | Description |
|------|------|
| `VERSION` | the binding version string (`"2.0.0"`) |
| `loadLibrary()` | load the native library explicitly (idempotent) |
| `isLoaded()` | returns `true` once the native library is loaded |
| `libraryName()` | the platform-specific library file name |
| `platform()` | a `{ platform, arch, runtime }` summary |
| `detectRuntime()` | detect the runtime family: `"node"` / `"deno"` / `"bun"` / `"unknown"` |
| `getRuntimeInfo()` | a full runtime snapshot |
| `LibraryLoader` | the RAII loader (`dispose()` is a no-op) |
| `DataHandle` | the RAII wrapper around a data buffer |
| `AppHandle` | the RAII wrapper around an app |
| `AppTarget` | the target addressed by App name |
| `UIDTarget` | the target addressed by UID |
| `P2PNameTarget` | the target addressed by group name |
| `CallPromise` | the async/await-style Promise wrapper |
| `AsyncBridge` | the async subsystem singleton |
| `registerP2PCall()` | register a process-level P2P Call |
| `registerP2PNotify()` | register a process-level P2P Notify |
| `unregisterP2P()` | remove a process-level P2P API |
| `ErrorCode` | the numeric error-code enum, consistent with C++ |
| `Option` | runtime option name constants |
| `bool(value)` | convert a boolean to `"True"` / `"False"` |
| `io` | the JSON / string / byte I/O namespace |
| `framework` | the process-level ABI facade (low level) |
| `network` | the network event handlers |
| `status` | the status queue and health checks |
| `options` | typed runtime options (new in v2.0) |
| `address` | the three addressing modes (new in v2.0) |
| `async` | the async subsystem (new in v2.0) |
| `_binding` | the underlying `binding.ts` module object (escape hatch) |

**The exception classes** (8):

| Class | Base | Extra fields |
|----|------|---------|
| `LingoFuseError` | `Error` | `code` |
| `LingoFuseLibraryLoadError` | `LingoFuseError` | `libraryName` |
| `LingoFuseCallError` | `LingoFuseError` | `targetApp`, `targetApi` |
| `LingoFuseTimeoutError` | `LingoFuseError` | `targetApp`, `targetApi`, `timeoutMs` |
| `LingoFuseIoError` | `LingoFuseError` | `operation` |
| `LingoFuseObjectDisposedError` | `LingoFuseError` | `objectName` |
| `LingoFuseCallbackError` | `LingoFuseError` | `source`, `originalCause` |
| `LingoFuseRegistrationError` | `LingoFuseError` | `apiName` |

### 14.2 The `io` namespace

| Function | Description |
|------|------|
| `dumps(value)` | serialize to compact JSON (literal UTF-8, no `\uXXXX`) |
| `loads<T>(text)` | parse JSON; throws `LingoFuseIoError` on failure |
| `writeString(handle, str)` | write UTF-8 + NUL |
| `readString(handle)` | read UTF-8 until NUL (tolerant) |
| `writeStringBytes(handle, bytes)` | write raw bytes + NUL |
| `readStringBytes(handle)` | read raw bytes until NUL |
| `readAllBytes(handle)` | read all remaining bytes |
| `writeJson(handle, value)` | serialize value, write UTF-8 + NUL |
| `readJson<T>(handle)` | read a NUL-framed JSON payload, returns `T \| null` |
| `tryReadJson<T>(handle)` | a non-raising `readJson` |

### 14.3 The `framework` namespace

| Function | Description |
|------|------|
| `setCallbackErrorHandler(fn)` | install the global error reporter |
| `getCallbackErrorHandler()` | read the current reporter |
| `resetPrepare()` | clear the preparation queue |
| `prepareService(listen, physics)` | prepare a service endpoint |
| `prepareClient(physics, app)` | prepare a client connection |
| `prepareDone()` | start the framework |
| `exitMainThread()` | request a graceful exit |
| `setOption(name, value)` | adjust a runtime option (generic) |
| `getOption(name)` | read a runtime option (generic) |
| `generateAppName()` | generate a unique name (must be after `prepareDone`) |
| `getAppName(app)` | query an App's authoritative name |
| `call(appName, param, timeoutMs?)` | a synchronous remote call (low level) |
| `tryCall(appName, param, timeoutMs?)` | `call` returning `null` on timeout / unreachability |
| `callAsync(appName, param, cb, data?)` | an inline-callback async call |
| `callPromise(appName, param, timeoutMs?)` | a Promise-style async call |
| `notify(appName, param)` | a one-way notification |
| `sequencedNotify(appName, param)` | a FIFO one-way notification |
| `uidCall(uid, param, timeoutMs?)` | a synchronous UID call |
| `uidCallAsync(uid, param, cb, data?)` | an inline-callback UID call |
| `uidCallPromise(uid, param, timeoutMs?)` | a Promise-style UID call |
| `uidNotify(uid, param)` | a one-way UID notification |
| `uidSequencedNotify(uid, param)` | a FIFO one-way UID notification |
| `p2pnameCall(name, param, timeoutMs?)` | a synchronous P2PName call |
| `p2pnameCallAsync(name, param, cb, data?)` | an inline-callback P2PName call |
| `p2pnameCallPromise(name, param, timeoutMs?)` | a Promise-style P2PName call |
| `p2pnameNotify(name, param)` | a one-way P2PName notification |
| `p2pnameSequencedNotify(name, param)` | a FIFO one-way P2PName notification |
| `shutdown()` | a full shutdown |

**How `framework` and `address` divide the work**:

- `framework.*` is the **low-level facade**, taking and returning `DataHandle`; suited to cases that need direct handle access.
- `address.*` is the **high-level abstraction**, where business code only touches JavaScript values; recommended for the great majority of application code.

### 14.4 The `network` namespace

| Function | Description |
|------|------|
| `setNetworkEvent(onConnect, onDisconnect)` | install the connect / disconnect handlers |
| `clearNetworkEvent()` | remove both handlers |
| `isNetworkEventInstalled()` | returns `true` when at least one is installed |
| `NetworkEventListener` | the base class for object-style listeners |
| `setNetworkEventListener(listener)` | install a listener instance |

### 14.5 The `status` namespace

| Function | Description |
|------|------|
| `getStatusCount()` | the number of messages pending in the queue |
| `getStatus()` | pop the next message |
| `drainStatus(maxMessages?)` | pop up to N messages |
| `postStatus(message)` | push one message |
| `checkMainThread()` | whether the framework is running |
| `checkApp(appName)` | whether an app is visible |
| `checkApi(appName, apiName)` | whether an API is visible |
| `checkUid(uid)` | whether a UID is visible (new in v2.0) |
| `checkUidApi(uid, apiName)` | whether an API on a UID is visible (new in v2.0) |
| `checkP2PName(p2pName)` | whether a group name is visible (new in v2.0) |
| `checkP2PNameApi(p2pName, apiName)` | whether an API on a group is visible (new in v2.0) |

### 14.6 The `options` namespace

| Function | Description |
|------|------|
| 16 setter / getter pairs | see the complete table in §8.1 |

### 14.7 The `address` namespace

| Class | Description |
|----|------|
| `Target` | the abstract base class (not used directly) |
| `AppTarget` | addressing by App name |
| `UIDTarget` | addressing by UID |
| `P2PNameTarget` | addressing by group name |

**Each Target class exposes the following methods**:

| Method | Description |
|------|------|
| `call(api, payload, {timeoutMs})` | returns a `CallPromise`, consumed with `await` |
| `callAsync(api, payload, onResult, userData)` | an inline callback |
| `callSync(api, payload, {timeoutMs})` | synchronous (blocking) |
| `tryCallSync(api, payload, {timeoutMs})` | synchronous, returning `null` on failure |
| `sequencedCall(api, payload, {timeoutMs})` | returns a `CallPromise`, FIFO |
| `sequencedCallAsync(api, payload, onResult, userData)` | an inline callback, FIFO |
| `notify(api, payload)` | one-way, no ordering guarantee |
| `sequencedNotify(api, payload)` | one-way, FIFO |
| `hashKey()` | a stable, value-based string key |

### 14.8 The `async` namespace

| Symbol | Description |
|------|------|
| `AsyncBridge` | the process-level singleton. `instance()` / `shutdownInstance()` / `stats()` |
| `AsyncOp` | the state holder of a single async operation |
| `CallPromise` | the Promise wrapper carrying an `abandoned` flag |
| `makeLegacyOp` | a low-level factory: builds a legacy-callback-style op |
| `makeFutureOp` | a low-level factory: builds an op + CallPromise pair |
| `runAsyncWithPromise` | all in one: build + dispatch + set the timeout |
| `runLegacyOp` | all in one: the legacy callback style |

### 14.9 The `DataHandle` class

Create an auto-reclaim handle with `new lf.DataHandle("api_name")`; create a permanent handle with `lf.DataHandle.createPermanent("api_name")`. Always call `dispose()` when done, or use it inside a callback (where the interface library manages its lifetime automatically).

| Method / property | Description |
|------------|------|
| `DataHandle.createPermanent(apiName)` | static factory: create a permanent handle |
| `DataHandle.fromRaw(raw, owned)` | wrap an existing pointer (internal use) |
| `writeBytes(bytes)` / `readBytes(n)` | raw byte I/O |
| `readBytesExact(n)` / `tryReadBytes(n)` | fixed-length byte I/O |
| `readAllBytes()` | read to the end of the buffer |
| `writeInt8` … `writeDouble` | little-endian atomic writes |
| `readInt8` … `readDouble` | little-endian atomic reads |
| `writeString(s)` / `readString()` | NUL-framed UTF-8 |
| `tryReadString()` | a non-raising `readString` |
| `writeUid(uid)` / `readUid()` | 32-byte UID read/write (no NUL frame; new in v2.0) |
| `getP2PUid()` | read the sender's UID (INPUT only; new in v2.0) |
| `getP2PName()` | read the sender's group name (INPUT only; new in v2.0) |
| `position` / `size` | the cursor and buffer size (read/write) |
| `getBufferPointer()` | the native pointer of the internal buffer |
| `dispose()` | release the native handle (a no-op on borrowed handles) |
| `isValid` / `isOwning` / `raw` | state accessors |

### 14.10 The `AppHandle` class

Created with `new lf.AppHandle("name", "description")`. Always call `dispose()` when done.

| Method | Description |
|------|------|
| `registerCall(name, desc, handler)` | register a Call API |
| `registerNotify(name, desc, handler)` | register a Notify API |
| `unregister(name)` | remove a registered API |
| `localCall(param)` / `localNotify(param)` | in-process calls |
| `bind()` | bind to idle clients |
| `dispose()` | unbind and stop the thread |
| `name` / `isValid` / `raw` | state accessors |

### 14.11 The cleanup order

Resources must be released in the following order (LF-CLEAN-001):

```typescript
lf.network.clearNetworkEvent();
lf.AsyncBridge.shutdownInstance();
lf.framework.exitMainThread();
app.dispose();
lf.framework.shutdown();
```

All five operations are idempotent and may be called unconditionally in a `finally` block.

---

## Appendix A: cross-language compatibility

This binding is **byte-compatible** with the following languages:

| Language | Corresponding file |
|------|---------|
| C | `LingoFuse.h` / `LingoFuse.c` |
| C++ | `LingoFuse.hpp` / `lf_io.hpp` |
| C# | `LingoFuse.cs` / `LfIo.cs` |
| Pascal | `lingofuse_import.pas` |
| Python | `lingofuse.lf_io` |
| JavaScript | `lingofuse-js` |
| **TypeScript** | this package |

The same JSON payload produces the same wire bytes on every binding, with identical read semantics. Cross-language RPC needs no transcoding layer at all.

## Appendix B: correspondence with the JavaScript binding

This binding's **public API surface** corresponds exactly to `lingofuse-js` (the JavaScript binding), which makes cross-project migration easy:

| Feature | JavaScript | TypeScript |
|------|------------|------------|
| load the runtime | `lf.loadLibrary()` | `lf.loadLibrary()` |
| create a data handle | `new lf.DataHandle("api")` | `new lf.DataHandle("api")` |
| read JSON | `lf.io.readJson(h)` | `lf.io.readJson<T>(h)` |
| the three styles | `call` / `callAsync` / `callSync` | same |
| App addressing | `new lf.AppTarget(...)` | same |
| UID addressing | `new lf.UIDTarget(...)` | same |
| P2PName addressing | `new lf.P2PNameTarget(...)` | same |
| typed options | `lf.options.setOptQuiet(...)` | same |
| reading the P2P identity | `dh.getP2PUid()` | same |
| async subsystem | `lf.async.AsyncBridge` | same |
| exception hierarchy | 8 classes | 8 classes |

## Appendix C: further reading

- the header of `src/index.ts` — the full namespace layout of the public entry point
- the header of `src/address.ts` — the semantics and design rationale of the three addressing modes
- the header of `src/async-support.ts` — the design rationale and state machine of the async subsystem
- the header of `src/options.ts` — what the typed options are for and the three hard rules
- the header of `src/p2p-registration.ts` — the isolation of the process-level P2P namespace
- the header of `src/data-handle.ts` — the lifetime of the two handle kinds and the P2P identity semantics
- the header of `src/framework.ts` — the boundary between the low-level facade and the high-level abstraction
- the header of `test/test-v2.ts` — the three hard constraints of the v2.0 suite

## Appendix D: licence

MIT. See the `license` field in `package.json`.

