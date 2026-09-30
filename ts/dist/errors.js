"use strict";
// =============================================================================
//  errors.ts
// -----------------------------------------------------------------------------
//  Exception hierarchy for the LingoFuse TypeScript binding.
//
//  Mirrors the C++ ErrorCode / Error hierarchy in LingoFuse.hpp. Every
//  failure raised by this binding is a subclass of LingoFuseError, so
//  application code can catch the base type for a single handler.
// =============================================================================
Object.defineProperty(exports, "__esModule", { value: true });
exports.LingoFuseCallbackError = exports.LingoFuseObjectDisposedError = exports.LingoFuseIoError = exports.LingoFuseCallError = exports.LingoFuseLibraryLoadError = exports.LingoFuseError = exports.ErrorCode = void 0;
/** Numeric error category, mirroring the C++ ErrorCode enum. */
var ErrorCode;
(function (ErrorCode) {
    ErrorCode[ErrorCode["Generic"] = 0] = "Generic";
    ErrorCode[ErrorCode["LibraryLoadFailed"] = 1] = "LibraryLoadFailed";
    ErrorCode[ErrorCode["NullHandle"] = 2] = "NullHandle";
    ErrorCode[ErrorCode["InvalidArgument"] = 3] = "InvalidArgument";
    ErrorCode[ErrorCode["WriteFailed"] = 4] = "WriteFailed";
    ErrorCode[ErrorCode["ReadFailed"] = 5] = "ReadFailed";
    ErrorCode[ErrorCode["CallFailed"] = 6] = "CallFailed";
    ErrorCode[ErrorCode["RegistrationFailed"] = 7] = "RegistrationFailed";
    ErrorCode[ErrorCode["NotConnected"] = 8] = "NotConnected";
    ErrorCode[ErrorCode["Timeout"] = 9] = "Timeout";
})(ErrorCode || (exports.ErrorCode = ErrorCode = {}));
/** Base class for all LingoFuse exceptions. */
class LingoFuseError extends Error {
    code;
    constructor(message = "A LingoFuse operation failed.", code = ErrorCode.Generic, options) {
        super(message, options);
        this.name = "LingoFuseError";
        this.code = code;
    }
}
exports.LingoFuseError = LingoFuseError;
/** Raised when the native library cannot be located or loaded. */
class LingoFuseLibraryLoadError extends LingoFuseError {
    libraryName;
    constructor(libraryName, message, options) {
        super(message ?? `Failed to load the LingoFuse native library '${libraryName}'.`, ErrorCode.LibraryLoadFailed, options);
        this.name = "LingoFuseLibraryLoadError";
        this.libraryName = libraryName;
    }
}
exports.LingoFuseLibraryLoadError = LingoFuseLibraryLoadError;
/** Raised when a remote Call fails, times out, or the target is missing. */
class LingoFuseCallError extends LingoFuseError {
    targetApp;
    targetApi;
    constructor(message = "LingoFuse call failed.", options) {
        super(message, ErrorCode.CallFailed, options?.cause !== undefined
            ? { cause: options.cause }
            : undefined);
        this.name = "LingoFuseCallError";
        this.targetApp = options?.targetApp;
        this.targetApi = options?.targetApi;
    }
}
exports.LingoFuseCallError = LingoFuseCallError;
/** Raised when a byte-level I/O operation on a data handle fails. */
class LingoFuseIoError extends LingoFuseError {
    operation;
    constructor(message = "LingoFuse I/O operation failed.", options) {
        super(message, ErrorCode.ReadFailed, options?.cause !== undefined
            ? { cause: options.cause }
            : undefined);
        this.name = "LingoFuseIoError";
        this.operation = options?.operation;
    }
}
exports.LingoFuseIoError = LingoFuseIoError;
/** Raised when an operation is attempted on a disposed object. */
class LingoFuseObjectDisposedError extends LingoFuseError {
    objectName;
    constructor(objectName) {
        super(`The ${objectName} has already been disposed.`);
        this.name = "LingoFuseObjectDisposedError";
        this.objectName = objectName;
    }
}
exports.LingoFuseObjectDisposedError = LingoFuseObjectDisposedError;
/** Raised to describe a user callback that threw an unhandled exception. */
class LingoFuseCallbackError extends LingoFuseError {
    source;
    originalCause;
    constructor(source, cause) {
        const detail = cause instanceof Error ? cause.message : String(cause);
        super(`Callback '${source}' raised: ${detail}`, ErrorCode.Generic, { cause });
        this.name = "LingoFuseCallbackError";
        this.source = source;
        this.originalCause = cause;
    }
}
exports.LingoFuseCallbackError = LingoFuseCallbackError;
//# sourceMappingURL=errors.js.map