import type { TDataHnd } from "./types";
export declare class DataHandle {
    #private;
    /**
     * Create a new data handle bound to the given API name. The
     * underlying buffer starts empty.
     *
     * @throws {LingoFuseError} When the native library fails to
     *         allocate the handle.
     */
    constructor(apiName: string, internal?: {
        handle: TDataHnd;
        owned: boolean;
    });
    /** Wrap an existing raw handle. For internal use. */
    static fromRaw(raw: TDataHnd, owned: boolean): DataHandle;
    /** Raw native pointer. Null after an owning handle has been disposed. */
    get raw(): TDataHnd | null;
    /** True while the handle is valid and usable. */
    get isValid(): boolean;
    /** True when this instance owns the native handle. */
    get isOwning(): boolean;
    /**
     * Release the native handle when ownership applies.
     *
     * Owning handles: calls LF_FreeData, sets the disposed flag
     * (subsequent operations throw), and is idempotent. Borrowing
     * handles: no-op.
     */
    dispose(): void;
    get position(): number;
    set position(value: number | bigint);
    get size(): number;
    set size(value: number | bigint);
    /** Native pointer to the internal buffer. Do not free. */
    getBufferPointer(): unknown;
    /**
     * Append bytes at the current cursor. Throws on a short write,
     * symmetrically with readBytesExact.
     */
    writeBytes(data: Uint8Array): number;
    /** Read up to count bytes. Returns fewer bytes at end-of-buffer. */
    readBytes(count: number): Uint8Array;
    /** Read exactly count bytes. Throws on a short read. */
    readBytesExact(count: number): Uint8Array;
    /** Non-throwing counterpart of readBytesExact. */
    tryReadBytes(count: number): {
        ok: true;
        value: Uint8Array;
    } | {
        ok: false;
    };
    /** Read every remaining byte. Cursor advances to the end. */
    readAllBytes(): Uint8Array;
    writeInt8(value: number): void;
    writeUInt8(value: number): void;
    writeInt16(value: number): void;
    writeUInt16(value: number): void;
    writeInt32(value: number): void;
    writeUInt32(value: number): void;
    writeInt64(value: number | bigint): void;
    writeUInt64(value: number | bigint): void;
    writeSingle(value: number): void;
    writeDouble(value: number): void;
    readInt8(): number;
    readUInt8(): number;
    readInt16(): number;
    readUInt16(): number;
    readInt32(): number;
    readUInt32(): number;
    readInt64(): bigint;
    readUInt64(): bigint;
    readSingle(): number;
    readDouble(): number;
    /**
     * Write a string as UTF-8, followed by a single NUL byte. An empty
     * string writes exactly one byte (the NUL).
     */
    writeString(value: string): void;
    /**
     * Read a UTF-8 string, stopping at the first NUL. If no NUL is
     * found, all remaining bytes are consumed and returned. Invalid
     * UTF-8 sequences are decoded with U+FFFD.
     */
    readString(): string;
    /** Non-throwing counterpart of readString. */
    tryReadString(): {
        ok: true;
        value: string;
    } | {
        ok: false;
    };
}
//# sourceMappingURL=data-handle.d.ts.map