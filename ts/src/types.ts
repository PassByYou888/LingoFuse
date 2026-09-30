// =============================================================================
//  types.ts
// -----------------------------------------------------------------------------
//  Public type declarations shared across the LingoFuse TypeScript binding.
//
//  This module contains no runtime code. It exists so that callers can
//  import type declarations without pulling in the whole binding surface.
//
//  The opaque handle types mirror TDataHnd / TAppHnd in LingoFuse.h.
//  They are `unknown` at the type level because user code must never
//  dereference them; all access goes through the exported LF_* functions.
// =============================================================================

/** Opaque handle to a LingoFuse data buffer. */
export type TDataHnd = unknown;

/** Opaque handle to a LingoFuse application. */
export type TAppHnd = unknown;

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
 *              invocation; the binding copies it to a JavaScript string
 *              before invoking the user handler.
 */
export type LfNetworkEventFunc = (addr: string) => void;