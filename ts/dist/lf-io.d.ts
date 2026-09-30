import { DataHandle } from "./data-handle";
/** Serialize a value to a compact UTF-8 JSON string. */
export declare function dumps(value: unknown): string;
/** Parse a UTF-8 JSON string. Throws LingoFuseIoError on failure. */
export declare function loads<T = unknown>(text: string): T;
/** Write a UTF-8 string followed by a NUL terminator. */
export declare function writeString(handle: DataHandle, value: string): void;
/** Read a UTF-8 string, stopping at the first NUL. */
export declare function readString(handle: DataHandle): string;
/** Write raw bytes followed by a NUL terminator. Embedded NULs preserved. */
export declare function writeStringBytes(handle: DataHandle, data: Uint8Array): void;
/** Read raw bytes up to the first NUL. */
export declare function readStringBytes(handle: DataHandle): Uint8Array;
/** Read all remaining bytes without NUL handling. */
export declare function readAllBytes(handle: DataHandle): Uint8Array;
/** Serialize a value as UTF-8 JSON and write it with a NUL terminator. */
export declare function writeJson(handle: DataHandle, value: unknown): void;
/**
 * Read a NUL-framed JSON payload and deserialize it.
 *
 * Returns `null` when the payload is empty. A JSON literal `null`
 * (the four bytes "null") also decodes to `null`; use readStringBytes
 * if the two must be distinguished.
 */
export declare function readJson<T = unknown>(handle: DataHandle): T | null;
/** Non-throwing counterpart of readJson. */
export declare function tryReadJson<T = unknown>(handle: DataHandle): {
    ok: true;
    value: T | null;
} | {
    ok: false;
};
//# sourceMappingURL=lf-io.d.ts.map