// =============================================================================
//  errors.ts
// -----------------------------------------------------------------------------
//  Exception hierarchy for the LingoFuse TypeScript binding.
//
//  Mirrors the C++ ErrorCode / Error hierarchy in LingoFuse.hpp. Every
//  failure raised by this binding is a subclass of LingoFuseError, so
//  application code can catch the base type for a single handler.
//
//  THE EIGHT CLASSES
//  -----------------
//      LingoFuseError                  base
//      LingoFuseLibraryLoadError       native library load failure
//      LingoFuseCallError              remote call failed / null handle
//      LingoFuseTimeoutError           remote call timeout (JS-side)
//      LingoFuseIoError                byte-level I/O on a data handle
//      LingoFuseObjectDisposedError    use after dispose
//      LingoFuseCallbackError          user callback raised
//      LingoFuseRegistrationError      API registration rejected
//
//  Only these eight classes exist. Adding a new one requires a matching
//  ErrorCode enumerator so that a numeric category is always available.
//
//  DISTINCTION: LingoFuseCallError vs LingoFuseTimeoutError
//  --------------------------------------------------------
//  The two are deliberately distinct because they represent different
//  causes and require different recovery paths:
//
//      LingoFuseCallError    -- the native layer returned a null handle
//                               or a non-null handle whose size is 0.
//                               The cause is a transport or routing
//                               failure, or an empty response.
//
//      LingoFuseTimeoutError -- the JS-side deadline expired while the
//                               native request was still in flight. The
//                               native request is NOT cancelled; the
//                               framework keeps its callback alive for
//                               a grace period, and any late result is
//                               silently discarded.
//
//  All code and documentation are in English.
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

/**
 * Raised when an asynchronous Call times out on the JS-side deadline,
 * before the native callback could deliver a result.
 *
 * See the file header for the distinction between this class and
 * LingoFuseCallError.
 */
export class LingoFuseTimeoutError extends LingoFuseError {
    public readonly targetApp: string | undefined;
    public readonly targetApi: string | undefined;
    public readonly timeoutMs: number | undefined;

    public constructor(
        message: string = "LingoFuse asynchronous call timed out.",
        options?: {
            targetApp?: string;
            targetApi?: string;
            timeoutMs?: number;
            cause?: unknown;
        },
    ) {
        super(message, ErrorCode.Timeout, options?.cause !== undefined
            ? { cause: options.cause }
            : undefined);
        this.name = "LingoFuseTimeoutError";
        this.targetApp = options?.targetApp;
        this.targetApi = options?.targetApi;
        this.timeoutMs = options?.timeoutMs;
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

/**
 * Raised when an API registration call is rejected by the native layer.
 *
 * App-bound registration (AppHandle.registerCall / registerNotify) uses
 * a boolean return convention instead of throwing: it returns false for
 * a duplicate name and does not raise.
 *
 * The process-wide P2P registration helpers (registerP2PCall /
 * registerP2PNotify) prefer throwing, because the three possible
 * rejection reasons -- duplicate name, invalid handle, native OOM --
 * cannot be distinguished from a boolean alone, and silently returning
 * false would hide a real failure in a one-shot registration call.
 */
export class LingoFuseRegistrationError extends LingoFuseError {
    public readonly apiName: string;

    public constructor(
        apiName: string,
        message?: string,
        options?: { cause?: unknown },
    ) {
        super(
            message ??
                `Failed to register API '${apiName}' in the process-wide ` +
                `P2P namespace.`,
            ErrorCode.RegistrationFailed,
            options,
        );
        this.name = "LingoFuseRegistrationError";
        this.apiName = apiName;
    }
}