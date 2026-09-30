// =============================================================================
//  errors.ts
// -----------------------------------------------------------------------------
//  Exception hierarchy for the LingoFuse TypeScript binding.
//
//  Mirrors the C++ ErrorCode / Error hierarchy in LingoFuse.hpp. Every
//  failure raised by this binding is a subclass of LingoFuseError, so
//  application code can catch the base type for a single handler.
// =============================================================================

/** Numeric error category, mirroring the C++ ErrorCode enum. */
export enum ErrorCode {
    Generic = 0,
    LibraryLoadFailed,
    NullHandle,
    InvalidArgument,
    WriteFailed,
    ReadFailed,
    CallFailed,
    RegistrationFailed,
    NotConnected,
    Timeout,
}

/** Base class for all LingoFuse exceptions. */
export class LingoFuseError extends Error {
    public readonly code: ErrorCode;

    public constructor(
        message: string = "A LingoFuse operation failed.",
        code: ErrorCode = ErrorCode.Generic,
        options?: { cause?: unknown },
    ) {
        super(message, options);
        this.name = "LingoFuseError";
        this.code = code;
    }
}

/** Raised when the native library cannot be located or loaded. */
export class LingoFuseLibraryLoadError extends LingoFuseError {
    public readonly libraryName: string;

    public constructor(
        libraryName: string,
        message?: string,
        options?: { cause?: unknown },
    ) {
        super(
            message ?? `Failed to load the LingoFuse native library '${libraryName}'.`,
            ErrorCode.LibraryLoadFailed,
            options,
        );
        this.name = "LingoFuseLibraryLoadError";
        this.libraryName = libraryName;
    }
}

/** Raised when a remote Call fails, times out, or the target is missing. */
export class LingoFuseCallError extends LingoFuseError {
    public readonly targetApp: string | undefined;
    public readonly targetApi: string | undefined;

    public constructor(
        message: string = "LingoFuse call failed.",
        options?: { targetApp?: string; targetApi?: string; cause?: unknown },
    ) {
        super(message, ErrorCode.CallFailed, options?.cause !== undefined
            ? { cause: options.cause }
            : undefined);
        this.name = "LingoFuseCallError";
        this.targetApp = options?.targetApp;
        this.targetApi = options?.targetApi;
    }
}

/** Raised when a byte-level I/O operation on a data handle fails. */
export class LingoFuseIoError extends LingoFuseError {
    public readonly operation: string | undefined;

    public constructor(
        message: string = "LingoFuse I/O operation failed.",
        options?: { operation?: string; cause?: unknown },
    ) {
        super(message, ErrorCode.ReadFailed, options?.cause !== undefined
            ? { cause: options.cause }
            : undefined);
        this.name = "LingoFuseIoError";
        this.operation = options?.operation;
    }
}

/** Raised when an operation is attempted on a disposed object. */
export class LingoFuseObjectDisposedError extends LingoFuseError {
    public readonly objectName: string;

    public constructor(objectName: string) {
        super(`The ${objectName} has already been disposed.`);
        this.name = "LingoFuseObjectDisposedError";
        this.objectName = objectName;
    }
}

/** Raised to describe a user callback that threw an unhandled exception. */
export class LingoFuseCallbackError extends LingoFuseError {
    public readonly source: string;
    public readonly originalCause: unknown;

    public constructor(source: string, cause: unknown) {
        const detail = cause instanceof Error ? cause.message : String(cause);
        super(
            `Callback '${source}' raised: ${detail}`,
            ErrorCode.Generic,
            { cause },
        );
        this.name = "LingoFuseCallbackError";
        this.source = source;
        this.originalCause = cause;
    }
}