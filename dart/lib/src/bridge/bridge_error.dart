// Bridge error codes and their descriptions.
//
// The bridge returns LFB_ErrorCode values from every int-returning
// function. A return value of zero means success. The constants below
// mirror the enum in bridge/lf_dart_bridge.h and must be kept in sync
// with it manually.
//
// All diagnostics are in English.

/// Error codes returned by the C bridge.
///
/// These mirror the `LFB_ErrorCode` enum in `bridge/lf_dart_bridge.h`.
class BridgeErrorCode {
  BridgeErrorCode._();

  /// Success.
  static const int ok = 0;

  /// The bridge has not been initialized. Call `BridgeHost.start()`
  /// before any other bridge function.
  static const int notInitialized = 1;

  /// The LingoFuse runtime library could not be located or loaded.
  /// Check that LingoFuse64.dll (or the platform equivalent) is next
  /// to the executable, or on the OS loader search path.
  static const int libraryNotLoaded = 2;

  /// A NULL handle was passed where a valid handle was expected.
  static const int nullHandle = 3;

  /// A caller-supplied output buffer was too small. The data has been
  /// truncated to fit; retrieve the full value with a larger buffer.
  static const int bufferTooSmall = 4;

  /// An argument was invalid (NULL where non-NULL was required, a
  /// negative size, etc.).
  static const int invalidArgument = 5;

  /// The underlying LingoFuse call failed. For example, a duplicate
  /// API name, a rejected prepare address, or a short read/write.
  static const int lingofuseFailed = 6;

  /// An internal bridge invariant was violated. This indicates a bug
  /// in the bridge itself and should be reported.
  static const int bridgeInternal = 7;

  /// `Dart_PostCObject_DL` returned failure when the bridge tried to
  /// deliver a callback to the Dart isolate. This usually means the
  /// isolate's port has been closed.
  static const int dartPostFailed = 8;

  /// A bridge-level timeout. Currently unused; reserved for a future
  /// version that imposes deadlines on Protocol A handshakes.
  static const int timeout = 9;

  /// Human-readable description of an error code.
  static String describe(int code) {
    switch (code) {
      case ok:
        return 'OK';
      case notInitialized:
        return 'bridge not initialized; call BridgeHost.start() first';
      case libraryNotLoaded:
        return 'LingoFuse runtime library not loaded; '
            'check that it is on the OS loader search path';
      case nullHandle:
        return 'a NULL handle was passed';
      case bufferTooSmall:
        return 'output buffer too small; the result was truncated';
      case invalidArgument:
        return 'invalid argument';
      case lingofuseFailed:
        return 'the underlying LingoFuse call failed';
      case bridgeInternal:
        return 'internal bridge invariant violated';
      case dartPostFailed:
        return 'failed to deliver a callback to the Dart isolate';
      case timeout:
        return 'bridge-level timeout';
      default:
        return 'unknown bridge error code: $code';
    }
  }
}

/// Exception thrown when a bridge function returns a non-zero code.
///
/// Carries both the numeric code and the human-readable message that
/// the bridge stored for the current thread. The message may be empty
/// if the bridge could not describe the specific failure.
class BridgeException implements Exception {
  /// Numeric error code, matching one of the [BridgeErrorCode] constants.
  final int code;

  /// Human-readable description. Possibly empty.
  final String message;

  /// Optional context about the operation that failed.
  final String? operation;

  BridgeException(this.code, this.message, {this.operation});

  @override
  String toString() {
    final buf = StringBuffer('BridgeException');
    if (operation != null) {
      buf.write(' in $operation');
    }
    buf.write(' (code $code)');
    final detail = message.isNotEmpty
        ? message
        : BridgeErrorCode.describe(code);
    buf.write(': $detail');
    return buf.toString();
  }
}