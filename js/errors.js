/**
 * @file errors.js
 * @brief Exception hierarchy for the LingoFuse JavaScript binding.
 *
 * Every failure raised by this binding is an instance of LingoFuseError
 * or of one of its subclasses. Application code can catch the base type
 * for a single, catch-all handler.
 *
 * The hierarchy mirrors the layer at which the failure occurred:
 *
 *     base class            LingoFuseError
 *     library load          LingoFuseLibraryLoadError
 *     remote call           LingoFuseCallError
 *     I/O on a handle       LingoFuseIoError
 *     use after dispose     LingoFuseObjectDisposedError
 *     callback body failure LingoFuseCallbackError
 *
 * Only these six types exist. Custom exception types for registration
 * errors, state errors, or any other condition that cannot actually be
 * raised by the current implementation are deliberately absent. If a
 * new failure mode is introduced, its exception type is added here,
 * not invented at the call site.
 *
 * ============================================================================
 * DESIGN NOTES
 * ============================================================================
 * Unlike C#, JavaScript has no checked exceptions, but it does have a
 * usable `Error` base class with prototype-based subclassing. Each
 * subclass here:
 *
 *   - sets `name` to the class name (for diagnostics and `util.inspect`),
 *   - preserves the stack trace via `Error.captureStackTrace` when
 *     available (V8 / Node.js / Deno / Bun),
 *   - carries a small set of structured fields that callers can use for
 *     programmatic dispatch.
 *
 * The classes work identically on Node.js, Deno, and Bun. They only
 * depend on `Error`, which is part of the ECMAScript standard.
 *
 * ============================================================================
 * USAGE
 * ============================================================================
 * @code
 * const { LingoFuseError, LingoFuseCallError } = require("./errors");
 *
 * try {
 *     // ... LingoFuse operation ...
 * } catch (err) {
 *     if (err instanceof LingoFuseCallError) {
 *         console.error("Call failed:", err.targetApp, err.message);
 *     } else if (err instanceof LingoFuseError) {
 *         console.error("LingoFuse failure:", err.message);
 *     } else {
 *         throw err;  // Not ours; re-throw.
 *     }
 * }
 * @endcode
 */

"use strict";

// ============================================================================
// Base class
// ============================================================================

/**
 * Base class for all LingoFuse exceptions.
 *
 * @extends Error
 */
class LingoFuseError extends Error {
  /**
   * @param {string} [message="A LingoFuse operation failed."]
   *   Human-readable description of the failure.
   * @param {object} [options]
   * @param {Error} [options.cause]
   *   Underlying error that triggered this one, if any. Preserved so
   *   that callers can walk the cause chain.
   */
  constructor(message = "A LingoFuse operation failed.", options = undefined) {
    super(message, options);
    this.name = "LingoFuseError";

    // Preserve a clean stack trace that starts at the throw site
    // rather than at this constructor. V8 / Node / Deno / Bun all
    // support this; on engines that do not, the call is a no-op.
    if (typeof Error.captureStackTrace === "function") {
      Error.captureStackTrace(this, this.constructor);
    }
  }
}

// ============================================================================
// Library load failure
// ============================================================================

/**
 * Raised when the native LingoFuse library cannot be located or loaded
 * by the platform resolver.
 *
 * Typical causes:
 *   - the DLL / .so / .dylib is not next to the executable and is not
 *     on the loader search path;
 *   - it has an architecture mismatch (a 64-bit host trying to load a
 *     32-bit library, or vice versa);
 *   - a dependent native library is missing.
 *
 * @extends LingoFuseError
 */
class LingoFuseLibraryLoadError extends LingoFuseError {
  /**
   * @param {string} libraryName
   *   The logical or platform-specific library name that failed to load.
   * @param {string} [message]
   *   Optional custom message. When omitted, a default is constructed
   *   from the library name.
   * @param {object} [options]
   * @param {Error} [options.cause]
   */
  constructor(libraryName, message = undefined, options = undefined) {
    super(
      message ??
        `Failed to load the LingoFuse native library '${libraryName}'.`,
      options
    );
    this.name = "LingoFuseLibraryLoadError";

    /**
     * The library name that could not be loaded.
     * @type {string}
     */
    this.libraryName = libraryName;
  }
}

// ============================================================================
// Remote call failure
// ============================================================================

/**
 * Raised when a remote Call fails: null handle from the native layer,
 * timeout, or an unreachable target application.
 *
 * The C ABI reports a failed Call as an empty handle (size 0), never
 * as a NULL pointer. This exception is the JavaScript representation of
 * that failure, and it is also raised when the native layer itself
 * returns a NULL handle (a more fundamental transport problem).
 *
 * @extends LingoFuseError
 */
class LingoFuseCallError extends LingoFuseError {
  /**
   * @param {string} [message]
   * @param {object} [options]
   * @param {string} [options.targetApp]
   *   Name of the target application, when known.
   * @param {string} [options.targetApi]
   *   Name of the target API, when known.
   * @param {Error} [options.cause]
   */
  constructor(message = "LingoFuse call failed.", options = undefined) {
    super(message, options);
    this.name = "LingoFuseCallError";

    /**
     * Name of the target application, or `undefined` when unknown.
     * @type {string|undefined}
     */
    this.targetApp = options?.targetApp;

    /**
     * Name of the target API, or `undefined` when unknown.
     * @type {string|undefined}
     */
    this.targetApi = options?.targetApi;
  }
}

// ============================================================================
// I/O failure
// ============================================================================

/**
 * Raised when a low-level I/O operation on a data handle fails: a short
 * read when the caller asked for a fixed number of bytes, or a short
 * write when the native layer accepted fewer bytes than requested.
 *
 * This exception is reserved for the byte-level contract of a data
 * handle. Argument validation errors use the standard `TypeError` /
 * `RangeError` classes.
 *
 * The `operation` property names the failing operation (for example
 * "ReadBytesExact") so a diagnostic handler can produce a precise
 * message without parsing the exception text.
 *
 * @extends LingoFuseError
 */
class LingoFuseIoError extends LingoFuseError {
  /**
   * @param {string} [message]
   * @param {object} [options]
   * @param {string} [options.operation]
   *   Name of the failing I/O operation, when known.
   * @param {Error} [options.cause]
   */
  constructor(message = "LingoFuse I/O operation failed.", options = undefined) {
    super(message, options);
    this.name = "LingoFuseIoError";

    /**
     * Name of the failing I/O operation, or `undefined` when unknown.
     * @type {string|undefined}
     */
    this.operation = options?.operation;
  }
}

// ============================================================================
// Use-after-dispose failure
// ============================================================================

/**
 * Raised when an operation is attempted on an object that has already
 * been disposed.
 *
 * @extends LingoFuseError
 */
class LingoFuseObjectDisposedError extends LingoFuseError {
  /**
   * @param {string} objectName
   *   Name of the disposed object, for diagnostics.
   * @param {object} [options]
   * @param {Error} [options.cause]
   */
  constructor(objectName, options = undefined) {
    super(`The ${objectName} has already been disposed.`, options);
    this.name = "LingoFuseObjectDisposedError";

    /**
     * Name of the disposed object.
     * @type {string}
     */
    this.objectName = objectName;
  }
}

// ============================================================================
// Callback body failure
// ============================================================================

/**
 * Raised to describe a user callback that threw an unhandled exception
 * while running on a native worker thread.
 *
 * This error is never thrown into user code directly; it is passed to
 * the process-level callback error reporter (see framework.js). It
 * exists so that the reporter receives a structured object with a
 * stable type, rather than a raw value the callback happened to throw.
 *
 * The `source` property names the callback site (for example
 * "AppHandle.registerCall[add]"). The `cause` property holds the
 * original value thrown by the callback body, which may be an `Error`
 * or any other JavaScript value.
 *
 * @extends LingoFuseError
 */
class LingoFuseCallbackError extends LingoFuseError {
  /**
   * @param {string} source
   *   Identifier of the callback site that raised.
   * @param {*} cause
   *   The value the user callback threw. Not necessarily an `Error`.
   */
  constructor(source, cause) {
    // The message includes the cause's `toString()` form when possible.
    // A callback that throws a non-Error value (a string, a number, a
    // plain object) still gets a useful diagnostic.
    const detail = cause instanceof Error ? cause.message : String(cause);
    super(`Callback '${source}' raised: ${detail}`);
    this.name = "LingoFuseCallbackError";

    /**
     * Identifier of the callback site that raised.
     * @type {string}
     */
    this.source = source;

    /**
     * The original value thrown by the callback body.
     * @type {*}
     */
    this.originalCause = cause;
  }
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
  LingoFuseError,
  LingoFuseLibraryLoadError,
  LingoFuseCallError,
  LingoFuseIoError,
  LingoFuseObjectDisposedError,
  LingoFuseCallbackError,
};