import { DataHandle } from "./data-handle";
import { LingoFuseError, LingoFuseIoError } from "./errors";

const NUL_BYTE = 0x00;
const UTF8_ENCODER = new TextEncoder();
const UTF8_DECODER = new TextDecoder("utf-8", { fatal: false });

function bigIntReplacer(_key: string, value: unknown): unknown {
    if (typeof value === "bigint") {
        const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);
        const MIN_SAFE = -MAX_SAFE;
        if (value <= MAX_SAFE && value >= MIN_SAFE) {
            return Number(value);
        }
        return value.toString();
    }
    return value;
}

export function dumps(value: unknown): string {
    try {
        if (value === undefined) return "null";
        const text = JSON.stringify(value, bigIntReplacer);
        if (typeof text !== "string") {
            throw new LingoFuseIoError(
                "lf-io.dumps: value is not JSON-serializable.");
        }
        return text;
    } catch (err) {
        if (err instanceof LingoFuseIoError) throw err;
        const detail = err instanceof Error ? err.message : String(err);
        throw new LingoFuseIoError(
            `lf-io.dumps: JSON serialization failed: ${detail}`,
            { cause: err });
    }
}

export function loads<T = unknown>(text: string): T {
    if (typeof text !== "string") {
        throw new TypeError("lf-io.loads: text must be a string.");
    }
    try {
        return JSON.parse(text) as T;
    } catch (err) {
        const detail = err instanceof Error ? err.message : String(err);
        throw new LingoFuseIoError(
            `lf-io.loads: invalid JSON: ${detail}`,
            { cause: err });
    }
}

export function writeString(handle: DataHandle, value: string): void {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.writeString: handle must be a DataHandle.");
    }
    if (typeof value !== "string") {
        throw new TypeError(
            "lf-io.writeString: value must be a string.");
    }
    if (value.length > 0) {
        handle.writeBytes(UTF8_ENCODER.encode(value));
    }
    handle.writeBytes(Uint8Array.of(NUL_BYTE));
}

export function readString(handle: DataHandle): string {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.readString: handle must be a DataHandle.");
    }
    return handle.readString();
}

export function writeStringBytes(
    handle: DataHandle,
    data: Uint8Array,
): void {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.writeStringBytes: handle must be a DataHandle.");
    }
    if (!(data instanceof Uint8Array)) {
        throw new TypeError(
            "lf-io.writeStringBytes: data must be a Uint8Array.");
    }
    if (data.length > 0) handle.writeBytes(data);
    handle.writeBytes(Uint8Array.of(NUL_BYTE));
}

export function readStringBytes(handle: DataHandle): Uint8Array {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.readStringBytes: handle must be a DataHandle.");
    }
    return readUntilNul(handle);
}

export function readAllBytes(handle: DataHandle): Uint8Array {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.readAllBytes: handle must be a DataHandle.");
    }
    return handle.readAllBytes();
}

export function writeJson(handle: DataHandle, value: unknown): void {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.writeJson: handle must be a DataHandle.");
    }
    const text = dumps(value);
    writeString(handle, text);
}

export function readJson<T = unknown>(handle: DataHandle): T | null {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.readJson: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0) return null;
    const text = UTF8_DECODER.decode(bytes);
    return loads<T>(text);
}

export function tryReadJson<T = unknown>(
    handle: DataHandle,
): { ok: true; value: T | null } | { ok: false } {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.tryReadJson: handle must be a DataHandle.");
    }
    const bytes = readUntilNul(handle);
    if (bytes.length === 0) return { ok: false };
    const text = UTF8_DECODER.decode(bytes);
    try {
        return { ok: true, value: JSON.parse(text) as T };
    } catch {
        return { ok: false };
    }
}

export function readJsonTolerant<T = unknown>(
    handle: DataHandle,
): T | null {
    if (!(handle instanceof DataHandle)) {
        throw new TypeError(
            "lf-io.readJsonTolerant: handle must be a DataHandle.");
    }
    if (handle.size === 0) return null;
    handle.position = 0;
    const first = handle.readUInt8();
    if (first === 0x00) {
        return readJson<T>(handle);
    }
    if (first === 0xFF) {
        let msg = "";
        try { msg = handle.readString(); } catch { /* ignore */ }
        throw new LingoFuseError(`remote error: ${msg || "<empty>"}`);
    }
    handle.position = 0;
    return readJson<T>(handle);
}

function readUntilNul(handle: DataHandle): Uint8Array {
    const start = handle.position;
    const total = handle.size;
    if (start >= total) return new Uint8Array(0);

    const remaining = total - start;
    const raw = handle.readBytes(remaining);
    if (raw.length === 0) return new Uint8Array(0);

    let nulIndex = -1;
    for (let i = 0; i < raw.length; i++) {
        if (raw[i] === NUL_BYTE) { nulIndex = i; break; }
    }

    if (nulIndex >= 0) {
        const payload = raw.slice(0, nulIndex);
        handle.position = start + nulIndex + 1;
        return payload;
    }

    handle.position = start + raw.length + 1;
    return raw;
}