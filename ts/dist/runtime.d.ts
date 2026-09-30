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
export declare function detectRuntime(): RuntimeFamily;
/** Snapshot the current runtime environment. */
export declare function getRuntimeInfo(): RuntimeInfo;
//# sourceMappingURL=runtime.d.ts.map