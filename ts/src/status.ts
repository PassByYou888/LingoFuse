// =============================================================================
//  status.ts
// -----------------------------------------------------------------------------
//  Status queue and health checks for the LingoFuse runtime.
//
//  STATUS QUEUE
//  ------------
//  The native library maintains a bounded FIFO of log messages (up to
//  1000 entries). Older entries are dropped when the buffer is full.
//
//  The status queue is processed by the native simulated main thread.
//  Before prepareDone() has been called, the queue may be empty or
//  contain stale data.
//
//  HEALTH CHECKS
//  -------------
//  All check* functions are PROBES, not authoritative availability
//  decisions. The native implementation reads a local cache that is
//  updated by network broadcasts; the cache has an approximate 3-second
//  propagation delay. Consequences:
//
//    - A false negative immediately after registration is normal.
//    - A false positive shortly after unregistration is normal.
//    - Callers that need a hard availability decision must use a real
//      call with a bounded timeout, or poll with a retry budget.
//
//  UID ARGUMENTS
//  -------------
//  checkUid() and checkUidApi() accept a UID in any of the following
//  forms:
//
//    - Uint8Array of length 32
//    - 64-character hexadecimal string (case-insensitive)
//
//  The value is normalised to a 32-byte Uint8Array locally, then
//  wrapped in the Koffi struct shape { bytes: Uint8Array(32) } that
//  the LF_Check_UID* functions expect at the ABI boundary.
//
//  The same normalisation is used by address.UIDTarget. The two
//  modules keep separate copies of the tiny helper so that status.ts
//  does not depend on address.ts (which would otherwise introduce a
//  cycle the day address.ts needs to consult status). The two copies
//  are equivalent and will be unified if and when that cycle becomes
//  real.
// =============================================================================

import { getBinding } from "./binding";
import type { NativeFunctions } from "./binding";

let _funcs: NativeFunctions | null = null;
function funcs(): NativeFunctions {
    if (_funcs === null) _funcs = getBinding().funcs;
    return _funcs;
}

// -----------------------------------------------------------------------------
//  UID normalisation (module-private)
// -----------------------------------------------------------------------------

/**
 * Normalise a UID value into a 32-byte Uint8Array.
 *
 * Accepts:
 *   - Uint8Array of length 32
 *   - 64-character hexadecimal string (case-insensitive)
 *
 * @throws {TypeError}  When uid is neither a Uint8Array nor a string.
 * @throws {RangeError} When the length is not 32 (bytes) or 64 (hex).
 * @throws {RangeError} When the hex string contains non-hex characters.
 */
function normalizeUid(uid: Uint8Array | string): Uint8Array {
    if (uid instanceof Uint8Array) {
        if (uid.length !== 32) {
            throw new RangeError(
                `UID must be exactly 32 bytes, got ${uid.length}.`);
        }
        // Defensive copy: callers may reuse or mutate their buffer.
        return new Uint8Array(uid);
    }
    if (typeof uid === "string") {
        const hex = uid.trim();
        if (hex.length !== 64) {
            throw new RangeError(
                `UID hex string must be exactly 64 characters, ` +
                `got ${hex.length}.`);
        }
        if (!/^[0-9a-fA-F]+$/.test(hex)) {
            throw new RangeError(
                "UID hex string contains non-hex characters.");
        }
        const out = new Uint8Array(32);
        for (let i = 0; i < 32; i++) {
            out[i] = parseInt(hex.substr(i * 2, 2), 16);
        }
        return out;
    }
    throw new TypeError(
        "UID must be a Uint8Array(32) or a 64-character hex string, " +
        `got ${uid === null ? "null" : typeof uid}.`);
}

/**
 * Wrap a normalised 32-byte Uint8Array in the Koffi struct shape that
 * the LF_Check_UID* functions expect at the ABI boundary.
 *
 * Koffi declares TP2P_UID as a struct with a single `bytes` member of
 * type `uint8[32]`. At the call site, Koffi matches the value against
 * that struct by member name, so a plain object with a `bytes` field
 * is sufficient.
 *
 * A fresh Uint8Array is allocated so that Koffi cannot hold a reference
 * to the caller's buffer across the native call.
 */
function toTp2pUid(bytes: Uint8Array): { bytes: Uint8Array } {
    const arr = new Uint8Array(32);
    arr.set(bytes);
    return { bytes: arr };
}

// -----------------------------------------------------------------------------
//  Status queue
// -----------------------------------------------------------------------------

/** Number of pending log messages in the status queue. */
export function getStatusCount(): number {
    return funcs().LF_GetStatusCount();
}

/** Retrieve the next log message. Returns "" when the queue is empty. */
export function getStatus(): string {
    const msg = funcs().LF_GetStatus();
    return typeof msg === "string" ? msg : "";
}

/**
 * Drain up to maxMessages pending status messages in FIFO order.
 * Stops early when the queue reports an empty message.
 */
export function drainStatus(maxMessages: number = 64): string[] {
    if (typeof maxMessages !== "number") {
        throw new TypeError("drainStatus: maxMessages must be a number.");
    }
    if (!Number.isInteger(maxMessages) || maxMessages < 0) {
        throw new RangeError(
            "drainStatus: maxMessages must be a non-negative integer.");
    }
    if (maxMessages === 0) return [];

    const pending = getStatusCount();
    if (pending <= 0) return [];

    const count = Math.min(pending, maxMessages);
    const messages: string[] = [];
    for (let i = 0; i < count; i++) {
        const msg = getStatus();
        if (msg.length === 0) break;
        messages.push(msg);
    }
    return messages;
}

/** Inject a custom log message into the status queue. */
export function postStatus(message: string): void {
    if (typeof message !== "string") {
        throw new TypeError("postStatus: message must be a string.");
    }
    funcs().LF_PostStatus(message);
}

// -----------------------------------------------------------------------------
//  Core health checks
// -----------------------------------------------------------------------------

/** True when the simulated main thread is currently running. */
export function checkMainThread(): boolean {
    return funcs().LF_CheckMainThread() !== 0;
}

/**
 * Probe whether an application with the given name is available.
 *
 * Uses a local cache updated by network broadcasts (~3 s delay).
 * False negatives immediately after registration and false positives
 * shortly after unregistration are both normal.
 */
export function checkApp(appName: string): boolean {
    if (typeof appName !== "string") {
        throw new TypeError("checkApp: appName must be a string.");
    }
    return funcs().LF_CheckApp(appName) !== 0;
}

/** Probe whether the named API is available for the given application. */
export function checkApi(appName: string, apiName: string): boolean {
    if (typeof appName !== "string") {
        throw new TypeError("checkApi: appName must be a string.");
    }
    if (typeof apiName !== "string") {
        throw new TypeError("checkApi: apiName must be a string.");
    }
    return funcs().LF_CheckApi(appName, apiName) !== 0;
}

// -----------------------------------------------------------------------------
//  UID / P2PName health checks
// -----------------------------------------------------------------------------

/**
 * Check whether a client with the given UID is currently known to the
 * mesh (locally or via the cached remote view).
 *
 * The UID may be provided as a Uint8Array(32) or a 64-character hex
 * string. See the file header for the cache-delay caveat that applies
 * to every check* function.
 *
 * @throws {TypeError}  When uid is neither a Uint8Array nor a string.
 * @throws {RangeError} When the UID length is invalid.
 */
export function checkUid(uid: Uint8Array | string): boolean {
    const bytes = normalizeUid(uid);
    return funcs().LF_Check_UID(toTp2pUid(bytes)) !== 0;
}

/**
 * Check whether a client with the given UID exposes the named API.
 *
 * The UID may be provided as a Uint8Array(32) or a 64-character hex
 * string.
 *
 * @throws {TypeError}  When uid is neither a Uint8Array nor a string,
 *                      or when apiName is not a string.
 * @throws {RangeError} When the UID length is invalid.
 */
export function checkUidApi(
    uid: Uint8Array | string,
    apiName: string,
): boolean {
    if (typeof apiName !== "string") {
        throw new TypeError("checkUidApi: apiName must be a string.");
    }
    const bytes = normalizeUid(uid);
    return funcs().LF_Check_UID_Api(toTp2pUid(bytes), apiName) !== 0;
}

/**
 * Check whether at least one client has the given P2P group name.
 *
 * @throws {TypeError} When p2pName is not a string.
 */
export function checkP2PName(p2pName: string): boolean {
    if (typeof p2pName !== "string") {
        throw new TypeError("checkP2PName: p2pName must be a string.");
    }
    return funcs().LF_Check_P2PNAME(p2pName) !== 0;
}

/**
 * Check whether at least one client in the given P2P group exposes the
 * named API.
 *
 * @throws {TypeError} When either argument is not a string.
 */
export function checkP2PNameApi(
    p2pName: string,
    apiName: string,
): boolean {
    if (typeof p2pName !== "string") {
        throw new TypeError("checkP2PNameApi: p2pName must be a string.");
    }
    if (typeof apiName !== "string") {
        throw new TypeError("checkP2PNameApi: apiName must be a string.");
    }
    return funcs().LF_Check_P2PNAME_Api(p2pName, apiName) !== 0;
}