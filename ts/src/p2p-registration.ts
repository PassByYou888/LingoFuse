// =============================================================================
//  p2p-registration.ts
// -----------------------------------------------------------------------------
//  Process-wide P2P API registration.
//
//  This module wraps LF_Register_P2P_Call / LF_Register_P2P_Notify /
//  LF_Unregister_P2P, which register APIs into the process-wide P2P
//  namespace.
//
//  NAMESPACE ISOLATION
//  -------------------
//  The process-wide P2P namespace is INDEPENDENT of any App:
//
//    - APIs registered here are reachable via UID addressing and
//      P2PName addressing ONLY.
//    - They are NOT reachable via App-name addressing, even if the
//      registered API name happens to match an App name.
//    - They live on the process-wide LF_P2P_APP and survive until the
//      framework is shut down.
//
//  Typical use: register a small set of globally-discoverable utility
//  APIs (health probes, capability discovery, identity echo, etc.) that
//  any client in the mesh can call by group name or by UID.
//
//  HANDLER SHAPE
//  -------------
//  The user handler receives managed DataHandle instances and writes
//  business logic directly:
//
//      registerP2PCall("add", (input, output) => {
//          const { a, b } = readJson(input);
//          writeJson(output, { result: a + b });
//      });
//
//  There is no raw pointer, no ABI-level callback signature, and no
//  manual disposal. The two DataHandle instances are BORROWED from the
//  native layer (owned = false): the handler MUST NOT dispose them, and
//  the native layer releases them as soon as the handler returns.
//
//  CALLBACK EXECUTION CONTEXT
//  --------------------------
//  Handlers run on a native worker thread, serialised onto the
//  TypeScript event loop by the Koffi bridge. They MUST NOT:
//
//    - block for any meaningful duration,
//    - call any synchronous LingoFuse function (LF_Call, LF_Notify,
//      LF_LocalCall, LF_PrepareDone, LF_Shutdown) -- this would
//      deadlock,
//    - throw an exception that escapes -- the module catches every
//      throw and reports it through the shared callback error
//      reporter.
//
//  KEEPALIVE AND LIFETIME
//  ----------------------
//  The native library holds a RAW FUNCTION POINTER to each installed
//  callback. If the corresponding Koffi callback object is garbage
//  collected while the pointer is still live, the next invocation
//  crashes the process. This module keeps a strong reference to every
//  SUCCESSFULLY REGISTERED callback in a module-level array, mirroring
//  the contract of AppHandle.#registrations for app-bound registration.
//
//  The keepalive list is intentionally never pruned:
//
//    - On a REJECTED registration (the native call returned a value
//      other than 1), the Koffi bridge was never handed to the native
//      library, so it is safe to release immediately. This module does
//      exactly that and does NOT add the bridge to the keepalive list.
//
//    - On a successful registration followed by LF_Unregister_P2P, the
//      native library may still be holding a pointer to the bridge
//      while an in-flight request completes. The library does not
//      expose a way to release the callback object itself; keeping the
//      reference is harmless (a few dozen bytes) and removing it would
//      risk a use-after-free on the native side.
//
//  Callers who repeatedly register and unregister the same name should
//  be aware that each successful register/keep cycle leaves one bridge
//  in the keepalive list for the lifetime of the process. This is the
//  safest behaviour the native ABI permits; the alternative is a
//  potential crash on a late callback.
//
//  All code and documentation are in English.
// =============================================================================

import { getBinding, koffi, LfCallFuncPtr, LfNotifyFuncPtr } from "./binding";
import type { NativeFunctions } from "./binding";
import { DataHandle } from "./data-handle";
import { LingoFuseRegistrationError } from "./errors";

// -----------------------------------------------------------------------------
//  Module-level state
// -----------------------------------------------------------------------------

let _funcs: NativeFunctions | null = null;
function funcs(): NativeFunctions {
    if (_funcs === null) _funcs = getBinding().funcs;
    return _funcs;
}

/**
 * Strong references to every Koffi callback successfully registered
 * through the process-wide P2P API.
 *
 * Only bridges accepted by the native layer are appended. A bridge
 * whose registration was rejected is released immediately and never
 * enters this list.
 *
 * The list is intentionally never cleared at runtime. See the file
 * header for the full rationale.
 */
const _p2pCallbacks: unknown[] = [];

// -----------------------------------------------------------------------------
//  Callback error reporting (best-effort, no dependency on framework.ts
//  to avoid a circular require)
// -----------------------------------------------------------------------------

function reportCallbackError(source: string, err: unknown): void {
    try {
        const detail =
            err instanceof Error
                ? err.stack ?? err.message
                : String(err);
        // stderr is available in Node, Deno, and Bun.
        process.stderr.write(
            `[LingoFuse] Callback error in ${source}: ${detail}\n`,
        );
    } catch {
        // Even stderr may be unavailable in some embeddings. Ignore.
    }
}

// -----------------------------------------------------------------------------
//  Public API
// -----------------------------------------------------------------------------

/**
 * Register a process-wide P2P Call API.
 *
 * The API becomes reachable via UID addressing or P2PName addressing
 * from any client in the mesh, without requiring the caller to know the
 * target App name.
 *
 * @param apiName       Unique API name inside the process-wide P2P
 *                      namespace. Case-insensitive at lookup time.
 * @param handler       Business callback. Receives BORROWED DataHandle
 *                      instances for input and output. Must not
 *                      dispose them.
 * @param description   Optional human-readable description.
 *
 * @throws {TypeError}                  On a malformed argument.
 * @throws {LingoFuseRegistrationError} When the native call is rejected
 *                                      (duplicate name, invalid handle,
 *                                      or native OOM).
 */
export function registerP2PCall(
    apiName: string,
    handler: (input: DataHandle, output: DataHandle) => void,
    description: string = "",
): void {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "registerP2PCall: apiName must be a string.");
    }
    if (typeof handler !== "function") {
        throw new TypeError(
            "registerP2PCall: handler must be a function.");
    }
    const desc = description ?? "";

    const bridge = koffi.register(
        function (_trigger: unknown, input: unknown, output: unknown): void {
            const inH = DataHandle.fromRaw(input, false);
            const outH = DataHandle.fromRaw(output, false);
            try {
                handler(inH, outH);
            } catch (err) {
                reportCallbackError(
                    `registerP2PCall[${apiName}]`,
                    err,
                );
            }
        },
        LfCallFuncPtr,
    );

    const ret = funcs().LF_Register_P2P_Call(
        apiName,
        desc,
        null,
        bridge,
    );

    if (ret !== 1) {
        // The native call did NOT accept the callback pointer. The
        // bridge has never been seen by the native library, so it is
        // safe (and required) to release it immediately. Pushing it
        // into the keepalive list before this check would leak one
        // Koffi thread-safe function per rejected registration.
        try {
            koffi.unregister(bridge);
        } catch {
            // Best-effort cleanup.
        }
        throw new LingoFuseRegistrationError(apiName);
    }

    // Registration succeeded: the native library now holds a raw
    // pointer to this bridge. Keep the strong reference for the
    // lifetime of the process.
    _p2pCallbacks.push(bridge);
}

/**
 * Register a process-wide P2P Notify API.
 *
 * @param apiName       Unique API name inside the process-wide P2P
 *                      namespace.
 * @param handler       Business callback. Receives a BORROWED
 *                      DataHandle for the input payload. Must not
 *                      dispose it.
 * @param description   Optional human-readable description.
 *
 * @throws {TypeError}                  On a malformed argument.
 * @throws {LingoFuseRegistrationError} When the native call is rejected.
 */
export function registerP2PNotify(
    apiName: string,
    handler: (input: DataHandle) => void,
    description: string = "",
): void {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "registerP2PNotify: apiName must be a string.");
    }
    if (typeof handler !== "function") {
        throw new TypeError(
            "registerP2PNotify: handler must be a function.");
    }
    const desc = description ?? "";

    const bridge = koffi.register(
        function (_trigger: unknown, input: unknown): void {
            const inH = DataHandle.fromRaw(input, false);
            try {
                handler(inH);
            } catch (err) {
                reportCallbackError(
                    `registerP2PNotify[${apiName}]`,
                    err,
                );
            }
        },
        LfNotifyFuncPtr,
    );

    const ret = funcs().LF_Register_P2P_Notify(
        apiName,
        desc,
        null,
        bridge,
    );

    if (ret !== 1) {
        // Same reasoning as registerP2PCall: the bridge was never
        // handed to the native library and is safe to release.
        try {
            koffi.unregister(bridge);
        } catch {
            // Best-effort cleanup.
        }
        throw new LingoFuseRegistrationError(apiName);
    }

    _p2pCallbacks.push(bridge);
}

/**
 * Remove a previously registered process-wide P2P API.
 *
 * The removal is immediate locally. Remote peers may still see the API
 * for up to ~3 seconds until the network broadcast propagates.
 *
 * The corresponding Koffi callback wrapper stays in the keepalive list
 * even after unregistration. This is deliberate; see the file header
 * for the full rationale.
 *
 * @param apiName  API name previously passed to registerP2PCall or
 *                 registerP2PNotify.
 * @returns        True when the native call reported a removal, false
 *                 when the name was not found.
 *
 * @throws {TypeError} When apiName is not a string.
 */
export function unregisterP2P(apiName: string): boolean {
    if (typeof apiName !== "string") {
        throw new TypeError(
            "unregisterP2P: apiName must be a string.");
    }
    return funcs().LF_Unregister_P2P(apiName) === 1;
}