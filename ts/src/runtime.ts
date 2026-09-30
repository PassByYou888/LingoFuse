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

/** Detected runtime family. */
export type RuntimeFamily = "node" | "deno" | "bun" | "unknown";

/** Snapshot of the current runtime environment. */
export interface RuntimeInfo {
    readonly family: RuntimeFamily;
    readonly platform: string;
    readonly arch: string;
    readonly version: string;
}

/** Detect the current runtime family. */
export function detectRuntime(): RuntimeFamily {
    if (typeof (globalThis as { Deno?: unknown }).Deno !== "undefined") {
        return "deno";
    }
    if (typeof (globalThis as { Bun?: unknown }).Bun !== "undefined") {
        return "bun";
    }
    const proc = (globalThis as {
        process?: { versions?: { node?: string } };
    }).process;
    if (proc?.versions?.node !== undefined) {
        return "node";
    }
    return "unknown";
}

/** Snapshot the current runtime environment. */
export function getRuntimeInfo(): RuntimeInfo {
    const family = detectRuntime();
    const proc = (globalThis as {
        process?: {
            platform?: string;
            arch?: string;
            versions?: { node?: string };
        };
    }).process;

    let version = "";
    switch (family) {
        case "deno": {
            const deno = (globalThis as {
                Deno?: { version?: { deno?: string } };
            }).Deno;
            version = deno?.version?.deno ?? "";
            break;
        }
        case "bun": {
            const bun = (globalThis as { Bun?: { version?: string } }).Bun;
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