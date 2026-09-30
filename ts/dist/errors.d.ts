/** Numeric error category, mirroring the C++ ErrorCode enum. */
export declare enum ErrorCode {
    Generic = 0,
    LibraryLoadFailed = 1,
    NullHandle = 2,
    InvalidArgument = 3,
    WriteFailed = 4,
    ReadFailed = 5,
    CallFailed = 6,
    RegistrationFailed = 7,
    NotConnected = 8,
    Timeout = 9
}
/** Base class for all LingoFuse exceptions. */
export declare class LingoFuseError extends Error {
    readonly code: ErrorCode;
    constructor(message?: string, code?: ErrorCode, options?: {
        cause?: unknown;
    });
}
/** Raised when the native library cannot be located or loaded. */
export declare class LingoFuseLibraryLoadError extends LingoFuseError {
    readonly libraryName: string;
    constructor(libraryName: string, message?: string, options?: {
        cause?: unknown;
    });
}
/** Raised when a remote Call fails, times out, or the target is missing. */
export declare class LingoFuseCallError extends LingoFuseError {
    readonly targetApp: string | undefined;
    readonly targetApi: string | undefined;
    constructor(message?: string, options?: {
        targetApp?: string;
        targetApi?: string;
        cause?: unknown;
    });
}
/** Raised when a byte-level I/O operation on a data handle fails. */
export declare class LingoFuseIoError extends LingoFuseError {
    readonly operation: string | undefined;
    constructor(message?: string, options?: {
        operation?: string;
        cause?: unknown;
    });
}
/** Raised when an operation is attempted on a disposed object. */
export declare class LingoFuseObjectDisposedError extends LingoFuseError {
    readonly objectName: string;
    constructor(objectName: string);
}
/** Raised to describe a user callback that threw an unhandled exception. */
export declare class LingoFuseCallbackError extends LingoFuseError {
    readonly source: string;
    readonly originalCause: unknown;
    constructor(source: string, cause: unknown);
}
//# sourceMappingURL=errors.d.ts.map