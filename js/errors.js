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
 *     remote call timeout   LingoFuseTimeoutError
 *     I/O on a handle       LingoFuseIoError
 *     use after dispose     LingoFuseObjectDisposedError
 *     callback body failure LingoFuseCallbackError
 *     API registration      LingoFuseRegistrationError
 *
 * Only these eight types exist. Custom exception types for state
 * errors or any other condition that cannot actually be raised by the
 * current implementation are deliberately absent.
 *
 * All comments and docstrings are in English.
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
   * @param {object} [options]
   * @param {Error} [options.cause]
   */
  constructor(message = "A LingoFuse operation failed.", options = undefined) {
    super(message, options);
    this.name = "LingoFuseError";

    if (typeof Error.captureStackTrace === "function") {
      Error.captureStackTrace(this, this.constructor);
    }
  }
}

// ============================================================================
// Library load failure
// ============================================================================

/**
 * Raised when the native LingoFuse library cannot be located or loaded.
 *
 * @extends LingoFuseError
 */
class LingoFuseLibraryLoadError extends LingoFuseError {
  /**
   * @param {string} libraryName
   * @param {string} [message]
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

    /** @type {string} */
    this.libraryName = libraryName;
  }
}

// ============================================================================
// Remote call failure
// ============================================================================

/**
 * Raised when a remote Call fails: null handle from the native layer,
 * or an unreachable target application.
 *
 * The C ABI reports a failed Call as an empty handle (size 0), never
 * as a NULL pointer. This exception is the JavaScript representation
 * of that failure.
 *
 * @extends LingoFuseError
 */
class LingoFuseCallError extends LingoFuseError {
  /**
   * @param {string} [message]
   * @param {object} [options]
   * @param {string} [options.targetApp]
   * @param {string} [options.targetApi]
   * @param {Error} [options.cause]
   */
  constructor(message = "LingoFuse call failed.", options = undefined) {
    super(message, options);
    this.name = "LingoFuseCallError";

    /** @type {string|undefined} */
    this.targetApp = options?.targetApp;

    /** @type {string|undefined} */
    this.targetApi = options?.targetApi;
  }
}

// ============================================================================
// Remote call timeout
// ============================================================================

/**
 * Raised when an asynchronous Call times out on the JS-side deadline,
 * before the native callback could deliver a result.
 *
 * This is a distinct type from LingoFuseCallError, because the two
 * failures have different causes and different recovery paths:
 *
 *   LingoFuseCallError    -- the native layer returned a null handle
 *                            or an empty (size-0) result.
 *
 *   LingoFuseTimeoutError -- the JS-side timeout expired while the C
 *                            request was still in flight. The C
 *                            request is NOT cancelled; the framework
 *                            keeps the callback alive for a grace
 *                            period, and any late result is discarded.
 *
 * @extends LingoFuseError
 */
class LingoFuseTimeoutError extends LingoFuseError {
  /**
   * @param {string} [message="LingoFuse asynchronous call timed out."]
   * @param {object} [options]
   * @param {string} [options.targetApp]
   * @param {string} [options.targetApi]
   * @param {number} [options.timeoutMs]
   * @param {Error}  [options.cause]
   */
  constructor(
    message = "LingoFuse asynchronous call timed out.",
    options = undefined
  ) {
    super(message, options);
    this.name = "LingoFuseTimeoutError";

    /** @type {string|undefined} */
    this.targetApp = options?.targetApp;

    /** @type {string|undefined} */
    this.targetApi = options?.targetApi;

    /** @type {number|undefined} */
    this.timeoutMs = options?.timeoutMs;
  }
}

// ============================================================================
// I/O failure
// ============================================================================

/**
 * Raised when a low-level I/O operation on a data handle fails: a
 * short read when the caller asked for a fixed number of bytes, or a
 * short write when the native layer accepted fewer bytes than
 * requested.
 *
 * @extends LingoFuseError
 */
class LingoFuseIoError extends LingoFuseError {
  /**
   * @param {string} [message]
   * @param {object} [options]
   * @param {string} [options.operation]
   * @param {Error} [options.cause]
   */
  constructor(message = "LingoFuse I/O operation failed.", options = undefined) {
    super(message, options);
    this.name = "LingoFuseIoError";

    /** @type {string|undefined} */
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
   * @param {object} [options]
   * @param {Error} [options.cause]
   */
  constructor(objectName, options = undefined) {
    super(`The ${objectName} has already been disposed.`, options);
    this.name = "LingoFuseObjectDisposedError";

    /** @type {string} */
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
 * the process-level callback error reporter (see framework.js).
 *
 * @extends LingoFuseError
 */
class LingoFuseCallbackError extends LingoFuseError {
  /**
   * @param {string} source
   * @param {*} cause
   */
  constructor(source, cause) {
    const detail = cause instanceof Error ? cause.message : String(cause);
    super(`Callback '${source}' raised: ${detail}`);
    this.name = "LingoFuseCallbackError";

    /** @type {string} */
    this.source = source;

    /** @type {*} */
    this.originalCause = cause;
  }
}

// ============================================================================
// API registration failure
// ============================================================================

/**
 * Raised when a registration call is rejected by the native layer.
 *
 * App-bound registration (AppHandle.registerCall / registerNotify) uses
 * a boolean return convention instead of throwing: it returns false for
 * a duplicate name and does not raise. This exception is therefore used
 * by the process-wide P2P registration helpers (registerP2PCall /
 * registerP2PNotify).
 *
 * @extends LingoFuseError
 */
class LingoFuseRegistrationError extends LingoFuseError {
  /**
   * @param {string} apiName
   * @param {string} [message]
   * @param {object} [options]
   * @param {Error} [options.cause]
   */
  constructor(apiName, message = undefined, options = undefined) {
    super(
      message ??
        `Failed to register API '${apiName}' in the process-wide P2P ` +
        `namespace.`,
      options
    );
    this.name = "LingoFuseRegistrationError";

    /** @type {string} */
    this.apiName = apiName;
  }
}

// ============================================================================
// Exports
// ============================================================================

module.exports = {
  LingoFuseError,
  LingoFuseLibraryLoadError,
  LingoFuseCallError,
  LingoFuseTimeoutError,
  LingoFuseIoError,
  LingoFuseObjectDisposedError,
  LingoFuseCallbackError,
  LingoFuseRegistrationError,
};