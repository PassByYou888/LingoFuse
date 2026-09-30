"use strict";
// =============================================================================
//  runtime.ts
// -----------------------------------------------------------------------------
//  Runtime detection helpers.
//
//  The binding supports Node.js, Deno (2.x), and Bun. Deno and Bun both
//  expose a Node-compatible `process` shim, so `process` alone cannot
//  distinguish them; the detection order below checks the Deno and Bun
//  globals first.
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.getRuntimeInfo = exports.detectRuntime = void 0;
/** Detect the current runtime family. */
function detectRuntime() {
    if (typeof globalThis.Deno !== "undefined") {
        return "deno";
    }
    if (typeof globalThis.Bun !== "undefined") {
        return "bun";
    }
    const proc = globalThis.process;
    if (proc?.versions?.node !== undefined) {
        return "node";
    }
    return "unknown";
}
exports.detectRuntime = detectRuntime;
/** Snapshot the current runtime environment. */
function getRuntimeInfo() {
    const family = detectRuntime();
    const proc = globalThis.process;
    let version = "";
    switch (family) {
        case "deno": {
            const deno = globalThis.Deno;
            version = deno?.version?.deno ?? "";
            break;
        }
        case "bun": {
            const bun = globalThis.Bun;
            version = bun?.version ?? "";
            break;
        }
        case "node":
            version = proc?.versions?.node ?? "";
            break;
        default:
            version = "";
    }
    return Object.freeze({
        family,
        platform: proc?.platform ?? "unknown",
        arch: proc?.arch ?? "unknown",
        version,
    });
}
exports.getRuntimeInfo = getRuntimeInfo;
//# sourceMappingURL=runtime.js.map