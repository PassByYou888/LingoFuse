// Exception hierarchy for the LingoFuse Dart binding.

/// Base class for all LingoFuse exceptions.
class LingoFuseError implements Exception {
  final String message;
  final Object? cause;

  LingoFuseError(this.message, {this.cause});

  @override
  String toString() {
    final buf = StringBuffer('LingoFuseError: $message');
    if (cause != null) buf.write(' (cause: $cause)');
    return buf.toString();
  }
}

/// Native library could not be loaded.
class LingoFuseLibraryLoadError extends LingoFuseError {
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

/// Remote call failed (timeout, unreachable target, null handle).
class LingoFuseCallError extends LingoFuseError {
  final String? targetApp;
  final String? targetApi;

  LingoFuseCallError(
    String message, {
    this.targetApp,
    this.targetApi,
    Object? cause,
  }) : super(message, cause: cause);
}

/// Low-level I/O failure on a data handle.
class LingoFuseIoError extends LingoFuseError {
  final String? operation;

  LingoFuseIoError(
    String message, {
    this.operation,
    Object? cause,
  }) : super(message, cause: cause);
}

/// Operation attempted on a disposed object.
class LingoFuseObjectDisposedError extends LingoFuseError {
  final String objectName;

  LingoFuseObjectDisposedError(this.objectName, {Object? cause})
      : super('$objectName has been disposed', cause: cause);
}

/// A user callback raised an unhandled exception.
class LingoFuseCallbackError extends LingoFuseError {
  final String source;
  final Object? originalCause;

  LingoFuseCallbackError(this.source, this.originalCause)
      : super('Callback "$source" raised: $originalCause');
}