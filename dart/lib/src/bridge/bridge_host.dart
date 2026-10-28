import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bridge_error.dart';
import 'bridge_ffi.dart';

class CallContext {
  final Uint8List payload;
  final Uint8List senderUid;
  final String senderP2PName;

  CallContext({
    required this.payload,
    required this.senderUid,
    required this.senderP2PName,
  });

  bool get hasSenderIdentity {
    if (senderUid.length != 32) return false;
    for (var i = 0; i < 32; i++) {
      if (senderUid[i] != 0) return true;
    }
    return false;
  }
}

typedef CallHandler = Uint8List Function(CallContext ctx);
typedef NotifyHandler = void Function(CallContext ctx);
typedef AsyncResultHandler = void Function(Uint8List? result, String? error);
typedef NetworkEventHandler = void Function(String addr);

class BridgeHost {
  final BridgeFfi _ffi;
  final ReceivePort _port;
  StreamSubscription<dynamic>? _subscription;

  final Map<int, _ApiRegistration> _apiRegistrations = {};
  final Map<int, AsyncResultHandler> _asyncHandlers = {};

  NetworkEventHandler? _connectHandler;
  NetworkEventHandler? _disconnectHandler;

  int _nextCallbackId = 1;
  int _nextOpId = 1;

  bool _stopped = false;

  static const int _kConnectEventId = -2;
  static const int _kDisconnectEventId = -3;

  BridgeHost._(this._ffi, this._port);

  static BridgeHost? _instance;

  static BridgeHost get instance {
    final i = _instance;
    if (i == null) {
      throw StateError(
          'BridgeHost is not running. Call "await BridgeHost.start()" first.');
    }
    return i;
  }

  static BridgeHost? get instanceOrNull => _instance;

  static Future<BridgeHost> start() async {
    if (_instance != null) return _instance!;

    final ffi = BridgeFfi.load();
    final port = ReceivePort();
    final host = BridgeHost._(ffi, port);

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

  void stop() {
    if (_stopped) return;
    _stopped = true;

    _apiRegistrations.clear();

    final pendingHandlers = Map<int, AsyncResultHandler>.from(_asyncHandlers);
    _asyncHandlers.clear();
    for (final h in pendingHandlers.values) {
      try {
        h(null, 'BridgeHost was stopped with an async call pending.');
      } catch (_) {
      }
    }

    _connectHandler = null;
    _disconnectHandler = null;

    try {
      _ffi.lfBridgeShutdown();
    } catch (_) {
    }

    try {
      _subscription?.cancel();
    } catch (_) {
    }
    _subscription = null;

    _port.close();
    _instance = null;
  }

  bool get isStopped => _stopped;

  String get version {
    final ptr = _ffi.lfBridgeVersion();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  String get lastError => _readLastError();

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

  bool unregister(Pointer<Void> appHnd, String apiName) {
    _ensureRunning();

    final cApi = apiName.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeUnregister(appHnd, cApi);
      if (rc != BridgeErrorCode.ok) return false;
    } finally {
      calloc.free(cApi);
    }

    _apiRegistrations.removeWhere((_, reg) => reg.apiName == apiName);
    return true;
  }

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

  void clearNetworkEvent() {
    _ensureRunning();
    _connectHandler = null;
    _disconnectHandler = null;
    _ffi.lfBridgeClearNetworkEvent();
  }

  bool get isNetworkEventInstalled =>
      _connectHandler != null || _disconnectHandler != null;

  void _onMessage(dynamic msg) {
    if (_stopped) return;
    if (msg is! List) return;

    if (msg.length == 5) {
      final uidRaw = msg[3];
      final p2pRaw = msg[4];
      final uid = uidRaw is Uint8List ? uidRaw : Uint8List(0);
      final p2p = (p2pRaw is Uint8List && p2pRaw.isNotEmpty)
          ? utf8.decode(p2pRaw, allowMalformed: true)
          : '';
      _handleProtocolA(msg[0] as int, msg[1] as int, msg[2] as Uint8List, uid, p2p);
      return;
    }

    if (msg.length == 3) {
      _handleProtocolA(msg[0] as int, msg[1] as int, msg[2] as Uint8List);
      return;
    }

    if (msg.length == 2) {
      _handleProtocolB(msg[0] as int, msg[1] as Uint8List);
      return;
    }
  }

  void _handleProtocolA(
    int requestId,
    int callbackId,
    Uint8List input, [
    Uint8List? senderUid,
    String? senderP2PName,
  ]) {
    final reg = _apiRegistrations[callbackId];

    if (reg == null) {
      if (requestId != 0) {
        _completeRequest(requestId, Uint8List(0));
      }
      return;
    }

    final ctx = CallContext(
      payload: input,
      senderUid: senderUid ?? Uint8List(0),
      senderP2PName: senderP2PName ?? '',
    );

    if (reg.isCall) {
      Uint8List output;
      try {
        output = (reg.handler as CallHandler)(ctx);
      } catch (e, st) {
        _reportCallbackError('call[${reg.apiName}]', e, st);
        output = Uint8List(0);
      }
      _completeRequest(requestId, output);
    } else {
      try {
        (reg.handler as NotifyHandler)(ctx);
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
  }

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
    }
  }
}

class _ApiRegistration {
  final int callbackId;
  final String apiName;
  final bool isCall;
  final Object handler;

  _ApiRegistration({
    required this.callbackId,
    required this.apiName,
    required this.isCall,
    required this.handler,
  });
}