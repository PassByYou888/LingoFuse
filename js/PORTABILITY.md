# Portability Guide — Node.js, Deno, Bun

This document explains how to use the LingoFuse JavaScript binding
from the three supported runtimes. The binding is a single CommonJS
core (`index.js` and its dependencies) with a thin ESM wrapper
(`index.mjs`). Every runtime can consume it, but the exact invocation
differs.

---

## 1. Support matrix

| Feature                                | Node.js 18+ | Deno 2.x       | Bun 1.x+      |
|----------------------------------------|:-----------:|:--------------:|:-------------:|
| CommonJS `require("lingofuse-js")`     | ✅          | ⚠️ see §4      | ✅            |
| ESM `import lf from "lingofuse-js"`    | ✅          | ✅ see §4      | ✅            |
| Named ESM imports                      | ✅          | ✅             | ✅            |
| Network / RPC / callbacks              | ✅          | ✅             | ✅            |
| `node:test` test suite                 | ✅          | ❌ see §4.4    | ⚠️ see §5.4   |
| FFI permission required                | no          | **yes**        | no            |

Legend: ✅ fully supported · ⚠️ partial / with caveats · ❌ not supported

---

## 2. Native library placement

Every runtime needs to find the platform-specific shared library:

| Platform        | File name           |
|-----------------|---------------------|
| Windows 64-bit  | `LingoFuse64.dll`   |
| Windows 32-bit  | `LingoFuse32.dll`   |
| Linux / BSD     | `liblingofuse.so`   |
| macOS           | `liblingofuse.dylib`|

The binding searches, in order:

1. The directory containing the current executable.
2. The current working directory.
3. A `native/` directory next to the binding package.
4. The **system loader search path**:
   - Windows: `PATH`
   - Linux: `LD_LIBRARY_PATH` and `/etc/ld.so.conf`
   - macOS: `DYLD_LIBRARY_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`, and the
     standard framework paths

Any of these locations works. If the library is on the system loader
path, no manual copying is required. If it is not, place it next to the
executable or in the current working directory. `check-env.js` prints
the exact search order and then attempts an authoritative load.

---

## 3. Node.js

### 3.1 Installation

```bash
npm install lingofuse-js