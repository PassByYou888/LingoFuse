// Exception hierarchy for the LingoFuse Dart binding.
//
// All exceptions raised by this binding derive from [LingoFuseError],
// so application code can use a single catch-all handler if desired.
//
// The hierarchy mirrors the layer at which the failure occurred:
//
//     LingoFuseError                  base class
//     LingoFuseLibraryLoadError       shared library not found / not loadable
//     LingoFuseCallError              remote call failed (null handle, etc.)
//     LingoFuseTimeoutError           async call abandoned after timeout
//     LingoFuseIoError                low-level buffer I/O failure
//     LingoFuseObjectDisposedError    operation on a disposed object
//     LingoFuseCallbackError          a user callback raised an exception
//     LingoFuseRegistrationError      process-wide P2P registration rejected
//
// This set matches the JavaScript binding (errors.js) one-to-one, so a
// developer familiar with one binding can transfer their knowledge to
// the other without surprises.
//
// All comments and diagnostic strings are in English.

import 'dart:async';

/// Base class for every LingoFuse exception.
class LingoFuseError implements Exception {
  /// Human-readable description of the failure.
  final String message;

  /// Optional underlying cause (typically the exception that triggered
  /// this one). Preserved for diagnostics; not part of the control flow.
  final Object? cause;

  LingoFuseError(this.message, {this.cause});

  @override
  String toString() {
    final buf = StringBuffer('LingoFuseError: $message');
    if (cause != null) {
      buf.write(' (cause: $cause)');
    }
    return buf.toString();
  }
}

/// The native library could not be located or loaded.
class LingoFuseLibraryLoadError extends LingoFuseError {
  /// Name of the library that failed to load.
  final String libraryName;

  LingoFuseLibraryLoadError(
    this.libraryName, {
    String? message,
    Object? cause,
  }) : super(
          message ?? "Failed to load LingoFuse library '$libraryName'",
          cause: cause,
        );
}

/// A remote call failed: null handle from the native layer, an
/// unreachable target application, or an underlying transport error.
///
/// The C ABI reports a failed Call as an empty handle (size 0), never
/// as a NULL pointer. This exception is the Dart representation of
/// that failure.
class LingoFuseCallError extends LingoFuseError {
  /// Target application name, when known.
  final String? targetApp;

  /// Target API name, when known.
  final String? targetApi;

  LingoFuseCallError(
    String message, {
    this.targetApp,
    this.targetApi,
    Object? cause,
  }) : super(message, cause: cause);
}

/// An asynchronous call was abandoned because the Dart-side timeout
/// expired before the native callback fired.
///
/// The native request is NOT cancelled. The framework keeps the
/// callback alive for a grace period, and any late result is silently
/// discarded.
///
/// {!!!!!  TIMEOUTEXCEPTION-COMPATIBLE  !!!!!}
/// This class implements Dart's built-in [TimeoutException] so that
/// callers who catch `TimeoutException` keep working unchanged. It is
/// ALSO a [LingoFuseError], so a single `on LingoFuseError catch`
/// handler catches every LingoFuse exception including timeouts.
///
/// Both catch styles are valid:
///
///     // Traditional style, still works:
///     try {
///       await target.call('api').future;
///     } on TimeoutException catch (e) {
///       // ...
///     }
///
///     // Unified LingoFuse style:
///     try {
///       await target.call('api').future;
///     } on LingoFuseError catch (e) {
///       // catches both timeouts and other LingoFuse failures
///     }
class LingoFuseTimeoutError extends LingoFuseError
    implements TimeoutException {
  /// Target application name, when known.
  final String? targetApp;

  /// Target API name, when known.
  final String? targetApi;

  /// The timeout, in milliseconds, that elapsed.
  final int? timeoutMs;

  /// The timeout, as a [Duration]. Mirrors the field of the same name
  /// on [TimeoutException].
  @override
  final Duration? duration;

  LingoFuseTimeoutError(
    String message, {
    this.targetApp,
    this.targetApi,
    this.timeoutMs,
    this.duration,
    Object? cause,
  }) : super(message, cause: cause);

  @override
  String toString() {
    final buf = StringBuffer('LingoFuseTimeoutError: $message');
    if (timeoutMs != null) {
      buf.write(' (after ${timeoutMs}ms)');
    }
    return buf.toString();
  }
}

/// A low-level I/O failure on a data handle: short read, short write,
/// or an argument that did not fit the documented contract.
class LingoFuseIoError extends LingoFuseError {
  /// Name of the operation that failed (for diagnostics).
  final String? operation;

  LingoFuseIoError(
    String message, {
    this.operation,
    Object? cause,
  }) : super(message, cause: cause);
}

/// An operation was attempted on an object that has already been
/// disposed.
class LingoFuseObjectDisposedError extends LingoFuseError {
  /// Name of the object (DataHandle, AppHandle, ...).
  final String objectName;

  LingoFuseObjectDisposedError(this.objectName, {Object? cause})
      : super('$objectName has been disposed', cause: cause);
}

/// A user callback raised an unhandled exception.
///
/// This exception is never thrown into user code directly. It is
/// delivered to the process-level callback error handler, so that the
/// native worker thread is never disturbed by a Dart exception.
class LingoFuseCallbackError extends LingoFuseError {
  /// Short identifier of the callback that raised (for diagnostics).
  final String source;

  /// The original value that the callback threw.
  final Object? originalCause;

  LingoFuseCallbackError(this.source, this.originalCause)
      : super('Callback "$source" raised: $originalCause');
}

/// A process-wide P2P registration was rejected by the native layer.
///
/// Typical causes: duplicate API name, or the P2P namespace has not yet
/// been initialized.
class LingoFuseRegistrationError extends LingoFuseError {
  /// The API name whose registration was rejected.
  final String apiName;

  LingoFuseRegistrationError(
    this.apiName, {
    String? message,
    Object? cause,
  }) : super(
          message ??
              "Failed to register API '$apiName' "
                  'in the process-wide P2P namespace.',
          cause: cause,
        );
}