// Modern async programming support for the LingoFuse Dart binding.
//
// This module bridges the bridge's fire-and-forget async call family
// (LF_Async_Call and its UID / P2PName variants) to Dart's Future
// idiom. It provides:
//
//   CallPromise<T>   a Promise wrapper around a Completer<T>, with an
//                    `abandoned` flag and a `settled` flag
//
//   AsyncBridge      a process-wide manager for pending async
//                    operations and their Dart-side timeouts
//
// The idioms the module enables:
//
//     // Future style
//     final bytes = await target.call('add', payload: {'a': 1});
//     final json  = await target.callJson<Map<String, dynamic>>('add');
//
//     // Callback style (no await, direct business code)
//     target.callAsync('add', {'a': 1}, (result, error) {
//         if (error != null) { handleError(error); return; }
//         handleResult(result!);
//     });
//
// Both styles flow through the same underlying bridge mechanism. The
// only difference is whether the result is delivered through a
// Completer<T> or through a user-supplied callback.
//
// ---------------------------------------------------------------------------
// WHY THIS IS SIMPLER THAN THE JS VERSION
// ---------------------------------------------------------------------------
// The JavaScript binding (async-support.js) implements a 4-state machine
// (PENDING / FIRED / ABANDONED / NOT_QUEUED) because Koffi callbacks
// must be explicitly released, and the release must be coordinated
// between the JS thread and native worker threads.
//
// Dart does not have this problem:
//
//   * NativeCallable objects are managed by the Dart VM's garbage
//     collector. There is no explicit unregister step.
//
//   * BridgeHost._asyncHandlers is a Dart-side Map. Removing an entry
//     is a single-threaded operation on the Dart event loop.
//
// The only thing that DOES need careful management is the Dart-side
// timeout timer, and that is handled here by AsyncBridge.
//
// All diagnostics are in English.

import 'dart:async';
import 'dart:typed_data';

import 'errors.dart';

// ===========================================================================
// CallPromise<T>
// ===========================================================================

/// A Promise wrapper around a Dart [Completer], with an `abandoned`
/// flag and a `settled` flag.
///
/// A CallPromise is a thenable: `await promise` works directly. It also
/// exposes [then] / [catchError] / [whenComplete] so that callers can
/// chain promises without going through the .future accessor.
class CallPromise<T> {
  final Completer<T> _completer = Completer<T>();
  bool _abandoned = false;
  bool _settled = false;

  /// The underlying Future.
  Future<T> get future => _completer.future;

  /// True when the promise was abandoned because a Dart-side timeout
  /// expired before the native callback fired.
  ///
  /// The native request is NOT cancelled. It may still deliver a result
  /// later; the result is silently discarded.
  bool get abandoned => _abandoned;

  /// True once the promise has been resolved or rejected.
  bool get settled => _settled;

  // -- Thenable interface (enables `await callPromise`) --

  Future<R> then<R>(
    FutureOr<R> Function(T value) onValue, {
    Function? onError,
  }) {
    return _completer.future.then(onValue, onError: onError);
  }

  Future<T> catchError(
    Function onError, {
    bool Function(Object error)? test,
  }) {
    return _completer.future.catchError(onError, test: test);
  }

  Future<T> whenComplete(FutureOr<void> Function() action) {
    return _completer.future.whenComplete(action);
  }

  // -- Internal transitions (documented "internal") --
  //
  // These are called by AsyncBridge and by callers that wrap the
  // promise into a derived promise. They are not underscore-prefixed
  // because Dart has no cross-library private access.

  void settleWithValue(T value) {
    if (_settled) return;
    _settled = true;
    _completer.complete(value);
  }

  void settleWithError(Object error) {
    if (_settled) return;
    _settled = true;
    _completer.completeError(error);
  }

  void markAbandoned() {
    _abandoned = true;
  }
}

// ===========================================================================
// AsyncBridge
// ===========================================================================

/// Process-wide manager for pending asynchronous operations.
///
/// Each pending op is identified by an internal local ID (unrelated to
/// the bridge's own op_id space, which is owned by BridgeHost). The
/// AsyncBridge's responsibilities are:
///
///   1. Track pending ops so that [shutdown] can clean up their timers
///      and reject their Completers.
///   2. Provide a [stats] snapshot for diagnostics.
///
/// The singleton is created lazily on first use. It is safe to create
/// one before or after BridgeHost.start; they are independent.
class AsyncBridge {
  // -----------------------------------------------------------------
  // Singleton
  // -----------------------------------------------------------------

  static AsyncBridge? _instance;

  /// The process-wide singleton, created on first access.
  static AsyncBridge instance() {
    return _instance ??= AsyncBridge._();
  }

  /// Tears down the singleton. All pending ops are rejected with
  /// [StateError]. Safe to call multiple times.
  static void shutdownInstance() {
    final i = _instance;
    if (i != null) {
      i.shutdown();
      _instance = null;
    }
  }

  // -----------------------------------------------------------------
  // Instance state
  // -----------------------------------------------------------------

  final Map<int, _PendingOp> _pending = {};
  int _nextLocalId = 1;
  int _totalSettled = 0;
  int _totalAbandoned = 0;
  bool _shutdown = false;

  AsyncBridge._();

  // -----------------------------------------------------------------
  // Public API
  // -----------------------------------------------------------------

  /// Wraps a fire-and-forget async issue call in a [CallPromise].
  ///
  /// [issue] is a function that takes a callback compatible with
  /// [AsyncResultHandler] and dispatches the native request. It is
  /// expected to invoke the callback exactly once, either with a
  /// result or with an error. If [issue] throws, the promise is
  /// rejected with the thrown error.
  ///
  /// [timeoutMs] is an optional Dart-side deadline. When it expires,
  /// the promise is rejected with [LingoFuseTimeoutError] and marked
  /// abandoned. The native request is NOT cancelled.
  CallPromise<Uint8List> wrapCall({
    required void Function(void Function(Uint8List? result, String? error) cb)
        issue,
    int? timeoutMs,
    String? targetDescription,
  }) {
    if (_shutdown) {
      throw StateError('AsyncBridge has been shut down.');
    }

    final localId = _nextLocalId++;
    final promise = CallPromise<Uint8List>();

    Timer? timer;
    if (timeoutMs != null && timeoutMs > 0) {
      timer = Timer(Duration(milliseconds: timeoutMs), () {
        _onTimeout(localId, targetDescription);
      });
    }

    final op = _PendingOp(
      localId: localId,
      timer: timer,
      promise: promise,
      timeoutMs: timeoutMs,
    );
    _pending[localId] = op;

    void cb(Uint8List? result, String? error) {
      _onResult(localId, result, error, targetDescription);
    }

    try {
      issue(cb);
    } catch (e) {
      _onResult(localId, null, 'issue() threw: $e', targetDescription);
    }

    return promise;
  }

  /// A snapshot of the bridge's counters.
  ///
  /// Keys:
  ///   pending           number of currently tracked ops
  ///   total_settled     lifetime count of ops that resolved or rejected
  ///   total_abandoned   lifetime count of ops that timed out
  ///   shutdown          true when shutdown() has been called
  Map<String, int> stats() {
    return {
      'pending': _pending.length,
      'total_settled': _totalSettled,
      'total_abandoned': _totalAbandoned,
      'shutdown': _shutdown ? 1 : 0,
    };
  }

  /// True when shutdown() has been called.
  bool get isShutdown => _shutdown;

  /// Tears down the bridge. Pending ops are rejected with StateError.
  ///
  /// Safe to call multiple times.
  void shutdown() {
    if (_shutdown) return;
    _shutdown = true;

    for (final op in _pending.values.toList()) {
      op.timer?.cancel();
      if (!op.promise.settled) {
        op.promise.settleWithError(
          StateError('AsyncBridge was shut down with an op pending.'),
        );
      }
    }
    _pending.clear();
  }

  // -----------------------------------------------------------------
  // Internal
  // -----------------------------------------------------------------

  void _onResult(
    int localId,
    Uint8List? result,
    String? error,
    String? target,
  ) {
    final op = _pending.remove(localId);
    if (op == null) return; // already timed out and cleaned up

    op.timer?.cancel();

    if (op.promise.settled) {
      // The promise was already abandoned via timeout. Discard the
      // late result, matching the "native request is not cancelled"
      // contract.
      return;
    }

    _totalSettled++;

    if (error != null) {
      op.promise.settleWithError(_buildError(error, target));
      return;
    }

    // A successful dispatch can still carry a null result when the
    // remote reply was empty. Represent that as an empty Uint8List so
    // that callers always receive a non-null buffer.
    op.promise.settleWithValue(result ?? Uint8List(0));
  }

  void _onTimeout(int localId, String? target) {
    final op = _pending.remove(localId);
    if (op == null) return;

    op.promise.markAbandoned();
    _totalAbandoned++;

    if (op.promise.settled) return;

    final msg = target != null
        ? 'Async call to $target was abandoned after timeout; '
            'the native request may still be in flight, but its '
            'result will be discarded.'
        : 'Async call was abandoned after timeout; the native '
            'request may still be in flight, but its result will be '
            'discarded.';

    final duration = op.timeoutMs != null
        ? Duration(milliseconds: op.timeoutMs!)
        : null;

    op.promise.settleWithError(LingoFuseTimeoutError(
      msg,
      timeoutMs: op.timeoutMs,
      duration: duration,
    ));
  }

  Object _buildError(String message, String? target) {
    // The bridge reports errors as plain strings. Wrap them in a
    // descriptive error so that callers that only catch a generic
    // type still get useful context.
    return _AsyncBridgeError(message, target: target);
  }
}

// ===========================================================================
// Internal types
// ===========================================================================

class _PendingOp {
  final int localId;
  final Timer? timer;
  final CallPromise<Uint8List> promise;
  final int? timeoutMs;

  _PendingOp({
    required this.localId,
    required this.timer,
    required this.promise,
    required this.timeoutMs,
  });
}

/// Error type for async bridge failures. Distinct from
/// [LingoFuseTimeoutError] (which is thrown on timeout) so that callers
/// can distinguish the two.
class _AsyncBridgeError implements Exception {
  final String message;
  final String? target;

  _AsyncBridgeError(this.message, {this.target});

  @override
  String toString() {
    final buf = StringBuffer('AsyncBridgeError');
    if (target != null) {
      buf.write(' in $target');
    }
    buf.write(': $message');
    return buf.toString();
  }
}