// =============================================================================
//  types.ts
// -----------------------------------------------------------------------------
//  Public type declarations shared across the LingoFuse TypeScript
//  binding.
//
//  This module contains no runtime code. It exists so that callers can
//  import type declarations without pulling in the whole binding
//  surface.
//
//  OPAQUE HANDLES
//  --------------
//  TDataHnd and TAppHnd mirror the corresponding types in LingoFuse.h.
//  They are `unknown` at the type level because user code must never
//  dereference them; all access goes through the exported functions on
//  DataHandle / AppHandle, or through the low-level binding module.
//
//  UID SHAPE
//  ---------
//  TP2P_UID describes the argument-role shape that the Koffi layer
//  expects at the ABI boundary. It is a struct wrapping a single
//  32-byte array. Callers rarely need to construct this directly:
//  UIDTarget (address.ts) and the uid* functions in framework.ts
//  accept `Uint8Array(32)` or a 64-character hex string and perform
//  the wrapping internally. The interface is exposed for advanced
//  users who write their own Koffi declarations.
//
//  CALLBACK PROTOTYPES
//  -------------------
//  The four callback types below mirror the four Koffi proto()
//  declarations in binding.ts. They exist so that a caller writing a
//  custom wrapper can name the callback shape without importing the
//  full binding module.
// =============================================================================

// -----------------------------------------------------------------------------
//  Opaque handles
// -----------------------------------------------------------------------------

/** Opaque handle to a LingoFuse data buffer. */
export type TDataHnd = unknown;

/** Opaque handle to a LingoFuse application. */
export type TAppHnd = unknown;

// -----------------------------------------------------------------------------
//  UID shape
// -----------------------------------------------------------------------------

/**
 * The argument-role shape of a 32-byte UID at the Koffi call boundary.
 *
 * Koffi declares TP2P_UID as a struct with a single `bytes` member of
 * type `uint8[32]`. Every LF_UID_* and LF_Check_UID* call must pass an
 * object of this shape.
 *
 * The `bytes` field must be exactly 32 bytes long. The two friendly
 * entry points (UIDTarget and framework.uidCall / uidNotify / ...)
 * enforce this and accept `Uint8Array(32)` or a 64-character hex
 * string as a shortcut.
 */
export interface TP2P_UID {
    readonly bytes: Uint8Array;
}

// -----------------------------------------------------------------------------
//  Callback prototypes
// -----------------------------------------------------------------------------

/**
 * Callback prototype for Call-mode (request-response) APIs.
 *
 * @param trigger  User-supplied value passed at registration time.
 * @param input    Read-only input data handle.
 * @param output   Writable output data handle.
 */
export type LfCallFunc = (
    trigger: unknown,
    input: TDataHnd,
    output: TDataHnd,
) => void;

/**
 * Callback prototype for Notify-mode (one-way) APIs.
 *
 * @param trigger  User-supplied value passed at registration time.
 * @param input    Read-only input data handle.
 */
export type LfNotifyFunc = (trigger: unknown, input: TDataHnd) => void;

/**
 * Callback prototype for network connect / disconnect events.
 *
 * @param addr  UTF-8 endpoint string. Valid only during the callback
 *              invocation; the binding copies it to a JavaScript
 *              string before invoking the user handler.
 */
export type LfNetworkEventFunc = (addr: string) => void;

/**
 * Callback prototype for the asynchronous remote invocation family.
 *
 * LIFETIME
 * --------
 * The `result` handle is OWNED BY THE FRAMEWORK. It is released
 * IMMEDIATELY after this callback returns. Do NOT call LF_FreeData on
 * it, and do NOT retain the pointer past its own return. Any data
 * that must outlive the callback has to be copied out first.
 *
 * @param data    The opaque pointer the caller passed at the call site
 *                (the `Data` argument of LF_Async_Call etc.).
 * @param result  A borrowed data handle carrying the response payload.
 */
export type LfAsyncCallOnResult = (
    data: unknown,
    result: TDataHnd,
) => void;