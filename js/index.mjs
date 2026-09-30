/**
 * @file index.mjs
 * @brief ESM entry point for the LingoFuse JavaScript binding.
 *
 * This file is a thin ESM wrapper around the CommonJS implementation
 * in `index.js`. Its only job is to make the binding importable via
 * the standard ESM `import` syntax on every supported runtime:
 *
 *     import lf from "lingofuse-js";
 *     import { DataHandle, io, framework } from "lingofuse-js";
 *
 * ============================================================================
 * WHY A WRAPPER INSTEAD OF A NATIVE ESM IMPLEMENTATION
 * ============================================================================
 * The core of the binding is written in CommonJS for two reasons:
 *
 *   1. Koffi is published as a CommonJS package. Loading it from ESM
 *      requires `createRequire` or a similar interop layer, which adds
 *      complexity to every file that touches it.
 *
 *   2. The existing test suite (test.js) uses the Node.js built-in
 *      test runner, which loads the binding through `require`. Keeping
 *      the core in CommonJS avoids a second test-harness rewrite.
 *
 * The cost of this choice is one extra file. The benefit is that the
 * binding works unchanged on Node.js, Deno (2.x, via the npm: specifier),
 * and Bun, whichever module system the caller prefers.
 *
 * ============================================================================
 * DENO NOTES
 * ============================================================================
 * Deno does not accept a bare file path in `import` for a CommonJS
 * package. To use this binding from Deno, load the package through the
 * npm: specifier:
 *
 *     import lf from "npm:lingofuse-js";
 *
 * Deno's npm compatibility layer will run this file (because the
 * `exports.import` field in package.json points here), and the
 * `createRequire` call below will resolve `koffi` through Deno's npm
 * cache. Deno requires `--allow-ffi`, `--allow-read`, and `--allow-env`
 * permissions.
 *
 * ============================================================================
 * BUN NOTES
 * ============================================================================
 * Bun accepts both `import lf from "lingofuse-js"` and
 * `const lf = require("lingofuse-js")`. Bun selects this file for the
 * ESM case and index.js for the CommonJS case, exactly as
 * package.json's `exports` field declares.
 *
 * ============================================================================
 */

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);

// Load the CommonJS core. This is a real module load, not a reparse:
// the singleton inside index.js is shared with any other CommonJS
// consumer in the same process.
const lf = require("./index.js");

// Named exports. Every field of the CommonJS module object is
// re-exported by name, so callers can use either style:
//
//     import lf from "lingofuse-js";
//     lf.DataHandle;
//
// or
//
//     import { DataHandle, io } from "lingofuse-js";
//
export const VERSION = lf.VERSION;

// Lifecycle helpers
export const loadLibrary = lf.loadLibrary;
export const isLoaded = lf.isLoaded;
export const libraryName = lf.libraryName;
export const platform = lf.platform;

// RAII handle types
export const DataHandle = lf.DataHandle;
export const AppHandle = lf.AppHandle;

// Grouped namespaces
export const io = lf.io;
export const framework = lf.framework;
export const network = lf.network;
export const status = lf.status;

// Exceptions
export const LingoFuseError = lf.LingoFuseError;
export const LingoFuseLibraryLoadError = lf.LingoFuseLibraryLoadError;
export const LingoFuseCallError = lf.LingoFuseCallError;
export const LingoFuseIoError = lf.LingoFuseIoError;
export const LingoFuseObjectDisposedError = lf.LingoFuseObjectDisposedError;
export const LingoFuseCallbackError = lf.LingoFuseCallbackError;

// Advanced escape hatch
export const _binding = lf._binding;

// Default export: the same object that CommonJS `require("lingofuse-js")`
// returns. This makes `import lf from "lingofuse-js"` behave identically
// to `const lf = require("lingofuse-js")`.
export default lf;