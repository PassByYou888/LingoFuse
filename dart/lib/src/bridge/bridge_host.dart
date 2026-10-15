// BridgeHost -- Dart-side host for the lf_dart_bridge shared library.
//
// This class is the single point of contact between Dart and the
// C bridge. It owns the ReceivePort that receives every callback
// message the bridge posts, and it dispatches those messages to the
// right user handler.
//
// ---------------------------------------------------------------------------
// TWO CALLBACK PROTOCOLS
// ---------------------------------------------------------------------------
//
// The C bridge posts two distinct message shapes; this class dispatches
// on the number of elements.
//
//   PROTOCOL A -- 3-element message
//       [ request_id : int64, callback_id : int64, input : Uint8List ]
//     Used by registered Call and Notify handlers. The native worker
//     that raised the callback is BLOCKED until Dart replies (Call
//     only). For Notify, request_id is 0 and no reply is expected.
//
//   PROTOCOL B -- 2-element message
//       [ op_id : int64, payload : Uint8List ]
//     Used by the async call family and by network events. The native
//     worker returns IMMEDIATELY. op_id routes the payload:
//         op_id >= 0    async call result
//         op_id == -2   network connect event
//         op_id == -3   network disconnect event
//
// ---------------------------------------------------------------------------
// THREADING
// ---------------------------------------------------------------------------
//
// All callbacks run on the Dart event loop. A Call handler MUST NOT
// block for long and MUST NOT call any synchronous LingoFuse entry
// point: the native worker is waiting on it.
//
// All diagnostics are in English.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bridge_error.dart';
import 'bridge_ffi.dart';

// ===========================================================================
// Public callback typedefs
// ===========================================================================

/// A Call-mode handler.
///
/// Receives the request payload as raw bytes and returns the response
/// payload as raw bytes. Returning an empty [Uint8List] produces a
/// size-0 reply.
///
/// Runs on the Dart event loop. The native worker that raised the
/// callback is BLOCKED until this handler returns. Must not block for
/// long, and must not call any synchronous LingoFuse entry point.
typedef CallHandler = Uint8List Function(Uint8List input);

/// A Notify-mode handler.
///
/// Receives the notification payload as raw bytes. Has no return value.
typedef NotifyHandler = void Function(Uint8List input);

/// The completion callback for an asynchronous call.
///
/// Exactly one of [result] and [error] is non-null.
///
/// On a successful dispatch, the callback fires asynchronously on the
/// Dart event loop. On a dispatch failure (the bridge could not send
/// the request), the callback is invoked SYNCHRONOUSLY from the
/// caller's stack, before the dispatching method returns. In both
/// cases the callback is invoked exactly once.
typedef AsyncResultHandler = void Function(Uint8List? result, String? error);

/// A network event handler.
///
/// Receives the endpoint address as a UTF-8 string.
typedef NetworkEventHandler = void Function(String addr);

// ===========================================================================
// BridgeHost
// ===========================================================================

/// The Dart-side host for the bridge shared library.
///
/// There is at most one instance per process. Call [start] once at
/// program startup, before any other LingoFuse bridge API. Call [stop]
/// before process exit to release the bridge's native resources and
/// close the ReceivePort that keeps the event loop alive.
class BridgeHost {
  // -----------------------------------------------------------------
  // Private state
  // -----------------------------------------------------------------

  final BridgeFfi _ffi;
  final ReceivePort _port;
  StreamSubscription<dynamic>? _subscription;

  /// Registered Call and Notify handlers, keyed by callback_id.
  final Map<int, _ApiRegistration> _apiRegistrations = {};

  /// Pending async call completions, keyed by op_id.
  final Map<int, AsyncResultHandler> _asyncHandlers = {};

  /// Currently installed network event handlers.
  NetworkEventHandler? _connectHandler;
  NetworkEventHandler? _disconnectHandler;

  /// Monotonic counter for callback_ids (API registrations).
  int _nextCallbackId = 1;

  /// Monotonic counter for op_ids (async calls).
  int _nextOpId = 1;

  bool _stopped = false;

  /// Special op_ids used to distinguish the two network events from
  /// async call results. Negative so they never collide with a real
  /// op_id.
  static const int _kConnectEventId = -2;
  static const int _kDisconnectEventId = -3;

  BridgeHost._(this._ffi, this._port);

  // -----------------------------------------------------------------
  // Singleton
  // -----------------------------------------------------------------

  static BridgeHost? _instance;

  /// The process-wide singleton.
  ///
  /// Throws [StateError] if [start] has not been called.
  static BridgeHost get instance {
    final i = _instance;
    if (i == null) {
      throw StateError(
          'BridgeHost is not running. Call "await BridgeHost.start()" first.');
    }
    return i;
  }

  /// The process-wide singleton, or null when the bridge has not been
  /// started. Does NOT throw. Use this for capability probing.
  static BridgeHost? get instanceOrNull => _instance;

  /// Starts the bridge host.
  ///
  /// Loads the bridge shared library, initializes the C bridge with the
  /// Dart isolate's native port, and begins listening for callbacks.
  ///
  /// Idempotent: a second call returns the existing instance.
  ///
  /// Throws [BridgeException] if initialization fails. The most common
  /// cause is a missing LingoFuse runtime library or a missing Dart SDK
  /// API DL table.
  static Future<BridgeHost> start() async {
    if (_instance != null) return _instance!;

    final ffi = BridgeFfi.load();
    final port = ReceivePort();
    final host = BridgeHost._(ffi, port);

    // NativeApi.initializeApiDLData is the void* that Dart exposes for
    // Dart_InitializeApiDL. Passing anything else (including NULL) to
    // the C side crashes inside the Dart runtime.
    final Pointer<Void> apiDlData = NativeApi.initializeApiDLData;

    final rc = ffi.lfBridgeInit(port.sendPort.nativePort, apiDlData);
    if (rc != BridgeErrorCode.ok) {
      port.close();
      throw BridgeException(
        rc,
        _readLastErrorFrom(ffi),
        operation: 'BridgeHost.start',
      );
    }

    host._subscription = port.listen(host._onMessage);
    _instance = host;
    return host;
  }

  /// Stops the bridge host.
  ///
  /// Releases the bridge's native resources and closes the ReceivePort.
  /// Does NOT call LF_Shutdown: that belongs to the LingoFuse lifecycle
  /// (see Framework.shutdown), not to the bridge lifecycle.
  ///
  /// Safe to call multiple times.
  void stop() {
    if (_stopped) return;
    _stopped = true;

    // Clear API registrations. These are inbound handlers; once the
    // bridge is stopped, no new inbound callbacks will arrive.
    _apiRegistrations.clear();

    // Reject all pending async handlers before clearing the map.
    //
    // Rationale: the native side will never deliver a result once the
    // bridge is stopped, so any Completer that is still awaiting a
    // result would hang forever. Invoking each handler with an explicit
    // error gives the awaiting code a chance to react (typically by
    // rejecting a Future or by logging).
    final pendingHandlers = Map<int, AsyncResultHandler>.from(_asyncHandlers);
    _asyncHandlers.clear();
    for (final h in pendingHandlers.values) {
      try {
        h(null, 'BridgeHost was stopped with an async call pending.');
      } catch (_) {
        // Best-effort notification; a throwing handler must not
        // prevent the remaining handlers from being notified.
      }
    }

    _connectHandler = null;
    _disconnectHandler = null;

    try {
      _ffi.lfBridgeShutdown();
    } catch (_) {
      // Best-effort cleanup; do not let a shutdown failure mask a
      // successful stop().
    }

    try {
      _subscription?.cancel();
    } catch (_) {
      // Best-effort.
    }
    _subscription = null;

    _port.close();
    _instance = null;
  }

  /// Whether [stop] has been called.
  bool get isStopped => _stopped;

  // -----------------------------------------------------------------
  // Diagnostics
  // -----------------------------------------------------------------

  /// The bridge's own version string.
  String get version {
    final ptr = _ffi.lfBridgeVersion();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  /// The most recent error message from the current thread.
  String get lastError => _readLastError();

  /// A snapshot of the bridge's internal counters, as a JSON string.
  String get statsJson {
    final buf = calloc<Char>(1024);
    try {
      final rc = _ffi.lfBridgeStatsJson(buf, 1024);
      if (rc != BridgeErrorCode.ok) {
        return '{}';
      }
      return buf.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  // -----------------------------------------------------------------
  // API registration (app-bound)
  // -----------------------------------------------------------------

  /// Registers a Call API on the given application handle.
  ///
  /// Returns the callback_id assigned to this registration.
  ///
  /// Throws [BridgeException] if the bridge rejects the registration
  /// (for example, a duplicate API name).
  int registerCall(
    Pointer<Void> appHnd,
    String apiName,
    String desc,
    CallHandler handler,
  ) {
    _ensureRunning();
    final callbackId = _nextCallbackId++;

    final cApi = apiName.toNativeUtf8().cast<Char>();
    final cDesc = desc.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeRegisterCall(appHnd, cApi, cDesc, callbackId);
      if (rc != BridgeErrorCode.ok) {
        throw BridgeException(
          rc,
          _readLastError(),
          operation: 'registerCall[$apiName]',
        );
      }
    } finally {
      calloc.free(cApi);
      calloc.free(cDesc);
    }

    _apiRegistrations[callbackId] = _ApiRegistration(
      callbackId: callbackId,
      apiName: apiName,
      isCall: true,
      handler: handler,
    );
    return callbackId;
  }

  /// Registers a Notify API on the given application handle.
  ///
  /// Returns the callback_id assigned to this registration.
  int registerNotify(
    Pointer<Void> appHnd,
    String apiName,
    String desc,
    NotifyHandler handler,
  ) {
    _ensureRunning();
    final callbackId = _nextCallbackId++;

    final cApi = apiName.toNativeUtf8().cast<Char>();
    final cDesc = desc.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeRegisterNotify(appHnd, cApi, cDesc, callbackId);
      if (rc != BridgeErrorCode.ok) {
        throw BridgeException(
          rc,
          _readLastError(),
          operation: 'registerNotify[$apiName]',
        );
      }
    } finally {
      calloc.free(cApi);
      calloc.free(cDesc);
    }

    _apiRegistrations[callbackId] = _ApiRegistration(
      callbackId: callbackId,
      apiName: apiName,
      isCall: false,
      handler: handler,
    );
    return callbackId;
  }

  /// Unregisters a previously registered API by name.
  ///
  /// Returns true if the API was found and removed.
  bool unregister(Pointer<Void> appHnd, String apiName) {
    _ensureRunning();

    final cApi = apiName.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeUnregister(appHnd, cApi);
      if (rc != BridgeErrorCode.ok) return false;
    } finally {
      calloc.free(cApi);
    }

    // Remove any local registrations that reference this API name.
    _apiRegistrations.removeWhere((_, reg) => reg.apiName == apiName);
    return true;
  }

  // -----------------------------------------------------------------
  // API registration (process-wide P2P)
  // -----------------------------------------------------------------

  /// Registers a process-wide P2P Call API.
  ///
  /// P2P APIs are reachable via UID addressing and P2PName addressing
  /// ONLY. They are NOT reachable via App-name addressing.
  int registerP2PCall(
    String apiName,
    String desc,
    CallHandler handler,
  ) {
    _ensureRunning();
    final callbackId = _nextCallbackId++;

    final cApi = apiName.toNativeUtf8().cast<Char>();
    final cDesc = desc.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeRegisterP2PCall(cApi, cDesc, callbackId);
      if (rc != BridgeErrorCode.ok) {
        throw BridgeException(
          rc,
          _readLastError(),
          operation: 'registerP2PCall[$apiName]',
        );
      }
    } finally {
      calloc.free(cApi);
      calloc.free(cDesc);
    }

    _apiRegistrations[callbackId] = _ApiRegistration(
      callbackId: callbackId,
      apiName: apiName,
      isCall: true,
      handler: handler,
    );
    return callbackId;
  }

  /// Registers a process-wide P2P Notify API.
  int registerP2PNotify(
    String apiName,
    String desc,
    NotifyHandler handler,
  ) {
    _ensureRunning();
    final callbackId = _nextCallbackId++;

    final cApi = apiName.toNativeUtf8().cast<Char>();
    final cDesc = desc.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeRegisterP2PNotify(cApi, cDesc, callbackId);
      if (rc != BridgeErrorCode.ok) {
        throw BridgeException(
          rc,
          _readLastError(),
          operation: 'registerP2PNotify[$apiName]',
        );
      }
    } finally {
      calloc.free(cApi);
      calloc.free(cDesc);
    }

    _apiRegistrations[callbackId] = _ApiRegistration(
      callbackId: callbackId,
      apiName: apiName,
      isCall: false,
      handler: handler,
    );
    return callbackId;
  }

  /// Removes a process-wide P2P API by name.
  bool unregisterP2P(String apiName) {
    _ensureRunning();

    final cApi = apiName.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeUnregisterP2P(cApi);
      if (rc != BridgeErrorCode.ok) return false;
    } finally {
      calloc.free(cApi);
    }

    _apiRegistrations.removeWhere((_, reg) => reg.apiName == apiName);
    return true;
  }

  // -----------------------------------------------------------------
  // Asynchronous invocation (App-name addressing)
  // -----------------------------------------------------------------

  /// Issues an asynchronous call by App name.
  ///
  /// The [onResult] callback is invoked exactly once:
  ///   - asynchronously on the Dart event loop when the reply arrives;
  ///   - synchronously on the caller's stack if the request could not
  ///     be dispatched.
  ///
  /// In both cases, exactly one of the callback's arguments is
  /// non-null. This single error path makes the following idiom work
  /// without any await/async seam:
  ///
  ///     bridge.callAsync('Server', param, (result, error) {
  ///         if (error != null) { handleError(error); return; }
  ///         handleResult(result!);
  ///     });
  void callAsync(
    String appName,
    Pointer<Void> param,
    AsyncResultHandler onResult,
  ) {
    _ensureRunning();
    _dispatchAsync(
      onResult,
      (opId) {
        final cName = appName.toNativeUtf8().cast<Char>();
        try {
          return _ffi.lfBridgeCallAsync(cName, param, opId);
        } finally {
          calloc.free(cName);
        }
      },
      'callAsync[$appName]',
    );
  }

  /// Issues an asynchronous call by App name with FIFO ordering per
  /// (app, api) pair.
  void callAsyncSequenced(
    String appName,
    Pointer<Void> param,
    AsyncResultHandler onResult,
  ) {
    _ensureRunning();
    _dispatchAsync(
      onResult,
      (opId) {
        final cName = appName.toNativeUtf8().cast<Char>();
        try {
          return _ffi.lfBridgeCallAsyncSequenced(cName, param, opId);
        } finally {
          calloc.free(cName);
        }
      },
      'callAsyncSequenced[$appName]',
    );
  }

  // -----------------------------------------------------------------
  // Asynchronous invocation (UID addressing)
  // -----------------------------------------------------------------

  /// Issues an asynchronous call by UID.
  ///
  /// [uid] must be exactly 32 bytes.
  void uidCallAsync(
    Uint8List uid,
    Pointer<Void> param,
    AsyncResultHandler onResult,
  ) {
    _ensureRunning();
    _checkUidLength(uid);
    _dispatchAsync(
      onResult,
      (opId) {
        final uidPtr = calloc<Uint8>(32);
        try {
          uidPtr.asTypedList(32).setAll(0, uid);
          return _ffi.lfBridgeUidCallAsync(uidPtr, param, opId);
        } finally {
          calloc.free(uidPtr);
        }
      },
      'uidCallAsync',
    );
  }

  /// Issues an asynchronous call by UID with FIFO ordering per
  /// (uid, api) pair.
  void uidCallAsyncSequenced(
    Uint8List uid,
    Pointer<Void> param,
    AsyncResultHandler onResult,
  ) {
    _ensureRunning();
    _checkUidLength(uid);
    _dispatchAsync(
      onResult,
      (opId) {
        final uidPtr = calloc<Uint8>(32);
        try {
          uidPtr.asTypedList(32).setAll(0, uid);
          return _ffi.lfBridgeUidCallAsyncSequenced(uidPtr, param, opId);
        } finally {
          calloc.free(uidPtr);
        }
      },
      'uidCallAsyncSequenced',
    );
  }

  // -----------------------------------------------------------------
  // Asynchronous invocation (P2PName addressing)
  // -----------------------------------------------------------------

  /// Issues an asynchronous call by P2PName.
  void p2pnameCallAsync(
    String p2pName,
    Pointer<Void> param,
    AsyncResultHandler onResult,
  ) {
    _ensureRunning();
    _dispatchAsync(
      onResult,
      (opId) {
        final cP2P = p2pName.toNativeUtf8().cast<Char>();
        try {
          return _ffi.lfBridgeP2PNameCallAsync(cP2P, param, opId);
        } finally {
          calloc.free(cP2P);
        }
      },
      'p2pnameCallAsync[$p2pName]',
    );
  }

  /// Issues an asynchronous call by P2PName with FIFO ordering per
  /// (group, api) pair.
  void p2pnameCallAsyncSequenced(
    String p2pName,
    Pointer<Void> param,
    AsyncResultHandler onResult,
  ) {
    _ensureRunning();
    _dispatchAsync(
      onResult,
      (opId) {
        final cP2P = p2pName.toNativeUtf8().cast<Char>();
        try {
          return _ffi.lfBridgeP2PNameCallAsyncSequenced(cP2P, param, opId);
        } finally {
          calloc.free(cP2P);
        }
      },
      'p2pnameCallAsyncSequenced[$p2pName]',
    );
  }

  // -----------------------------------------------------------------
  // Network events
  // -----------------------------------------------------------------

  /// Installs the process-global network event handlers.
  ///
  /// Passing null for either argument disables that event. This is a
  /// REPLACE operation: calling it again discards any previously
  /// installed handlers.
  void setNetworkEvent({
    NetworkEventHandler? onConnect,
    NetworkEventHandler? onDisconnect,
  }) {
    _ensureRunning();
    _connectHandler = onConnect;
    _disconnectHandler = onDisconnect;

    final connectId = onConnect != null ? _kConnectEventId : -1;
    final disconnectId = onDisconnect != null ? _kDisconnectEventId : -1;

    final rc = _ffi.lfBridgeSetNetworkEvent(connectId, disconnectId);
    if (rc != BridgeErrorCode.ok) {
      throw BridgeException(
        rc,
        _readLastError(),
        operation: 'setNetworkEvent',
      );
    }
  }

  /// Removes both network event handlers.
  void clearNetworkEvent() {
    _ensureRunning();
    _connectHandler = null;
    _disconnectHandler = null;
    _ffi.lfBridgeClearNetworkEvent();
  }

  /// True when at least one network event handler is installed.
  bool get isNetworkEventInstalled =>
      _connectHandler != null || _disconnectHandler != null;

  // =================================================================
  // Internal: message dispatch
  // =================================================================

  void _onMessage(dynamic msg) {
    if (_stopped) return;
    if (msg is! List) return;

    if (msg.length == 3) {
      _handleProtocolA(msg[0] as int, msg[1] as int, msg[2] as Uint8List);
      return;
    }

    if (msg.length == 2) {
      _handleProtocolB(msg[0] as int, msg[1] as Uint8List);
      return;
    }

    // Unknown message shape. Ignore; the bridge never posts anything
    // else, so reaching here means a version mismatch.
  }

  void _handleProtocolA(int requestId, int callbackId, Uint8List input) {
    final reg = _apiRegistrations[callbackId];

    if (reg == null) {
      // Unknown registration. If this is a Call, we must still complete
      // the request to unblock the native worker; otherwise the worker
      // would block forever.
      if (requestId != 0) {
        _completeRequest(requestId, Uint8List(0));
      }
      return;
    }

    if (reg.isCall) {
      Uint8List output;
      try {
        output = (reg.handler as CallHandler)(input);
      } catch (e, st) {
        _reportCallbackError('call[${reg.apiName}]', e, st);
        output = Uint8List(0);
      }
      _completeRequest(requestId, output);
    } else {
      // Notify: requestId is 0, no reply expected.
      try {
        (reg.handler as NotifyHandler)(input);
      } catch (e, st) {
        _reportCallbackError('notify[${reg.apiName}]', e, st);
      }
    }
  }

  void _handleProtocolB(int opId, Uint8List payload) {
    if (opId == _kConnectEventId) {
      final h = _connectHandler;
      if (h != null) {
        try {
          h(utf8.decode(payload, allowMalformed: true));
        } catch (e, st) {
          _reportCallbackError('networkConnect', e, st);
        }
      }
      return;
    }

    if (opId == _kDisconnectEventId) {
      final h = _disconnectHandler;
      if (h != null) {
        try {
          h(utf8.decode(payload, allowMalformed: true));
        } catch (e, st) {
          _reportCallbackError('networkDisconnect', e, st);
        }
      }
      return;
    }

    if (opId >= 0) {
      final h = _asyncHandlers.remove(opId);
      if (h != null) {
        try {
          h(payload.isEmpty ? null : payload, null);
        } catch (e, st) {
          _reportCallbackError('asyncResult[$opId]', e, st);
        }
      }
      return;
    }

    // Unknown negative op_id. Ignore.
  }

  // =================================================================
  // Internal: helpers
  // =================================================================

  void _completeRequest(int requestId, Uint8List output) {
    if (output.isEmpty) {
      _ffi.lfBridgeComplete(requestId, nullptr.cast<Uint8>(), 0);
      return;
    }
    final ptr = calloc<Uint8>(output.length);
    try {
      ptr.asTypedList(output.length).setAll(0, output);
      _ffi.lfBridgeComplete(requestId, ptr, output.length);
    } finally {
      calloc.free(ptr);
    }
  }

  void _dispatchAsync(
    AsyncResultHandler onResult,
    int Function(int opId) issue,
    String opName,
  ) {
    final opId = _nextOpId++;
    _asyncHandlers[opId] = onResult;

    int rc;
    try {
      rc = issue(opId);
    } catch (e, st) {
      _asyncHandlers.remove(opId);
      _reportCallbackError(opName, e, st);
      _invokeAsyncResult(onResult, null, 'dispatch exception: $e');
      return;
    }

    if (rc != BridgeErrorCode.ok) {
      _asyncHandlers.remove(opId);
      final msg = _readLastError();
      final description =
          msg.isNotEmpty ? msg : BridgeErrorCode.describe(rc);
      _invokeAsyncResult(onResult, null, description);
    }
  }

  void _invokeAsyncResult(
    AsyncResultHandler handler,
    Uint8List? result,
    String? error,
  ) {
    try {
      handler(result, error);
    } catch (e, st) {
      _reportCallbackError('asyncCallback', e, st);
    }
  }

  void _ensureRunning() {
    if (_stopped) {
      throw StateError('BridgeHost has been stopped.');
    }
    if (_ffi.lfBridgeIsInitialized() != 1) {
      throw StateError(
          'BridgeHost is not initialized. Call "await BridgeHost.start()" first.');
    }
  }

  void _checkUidLength(Uint8List uid) {
    if (uid.length != 32) {
      throw RangeError(
          'UID must be exactly 32 bytes, got ${uid.length}.');
    }
  }

  String _readLastError() => _readLastErrorFrom(_ffi);

  static String _readLastErrorFrom(BridgeFfi ffi) {
    final ptr = ffi.lfBridgeLastError();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  void _reportCallbackError(String source, Object error, StackTrace stack) {
    try {
      // ignore: avoid_print
      print('[LingoFuse bridge] error in $source: $error\n$stack');
    } catch (_) {
      // Even print may be unavailable in some embeddings.
    }
  }
}

// ===========================================================================
// Internal: registration record
// ===========================================================================

class _ApiRegistration {
  final int callbackId;
  final String apiName;

  /// True for Call handlers, false for Notify handlers.
  final bool isCall;

  /// The user-supplied handler. Cast to [CallHandler] or
  /// [NotifyHandler] depending on [isCall].
  final Object handler;

  _ApiRegistration({
    required this.callbackId,
    required this.apiName,
    required this.isCall,
    required this.handler,
  });
}