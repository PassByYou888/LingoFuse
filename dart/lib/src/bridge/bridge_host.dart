// Dart-side host for the C bridge.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../errors.dart';
import 'bridge_ffi.dart';

/// User-provided Call handler. Receives input bytes, returns output bytes.
typedef CallHandler = Uint8List Function(Uint8List input);

/// User-provided Notify handler.
typedef NotifyHandler = void Function(Uint8List input);

/// Singleton host that connects the C bridge to Dart callbacks.
class BridgeHost {
  final BridgeFfi _ffi;
  final ReceivePort _port;
  final Map<int, CallHandler> _callHandlers = {};
  final Map<int, NotifyHandler> _notifyHandlers = {};
  int _nextId = 1;
  bool _stopped = false;

  BridgeHost._(this._ffi, this._port);

  static BridgeHost? _instance;

  static BridgeHost get instance {
    final i = _instance;
    if (i == null) {
      throw StateError(
          'BridgeHost is not started. Call "await BridgeHost.start()" first.');
    }
    return i;
  }

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
    if (rc != 0) {
      port.close();
      throw LingoFuseError('lf_bridge_init failed with code $rc');
    }

    port.listen(host._onMessage);
    _instance = host;
    return host;
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _ffi.lfBridgeShutdown();
    _port.close();
    _instance = null;
  }

  // -----------------------------------------------------------------
  // Registration
  // -----------------------------------------------------------------

  int registerCall(
      Pointer<Void> appHnd, String apiName, String desc, CallHandler handler) {
    final id = _nextId++;
    _callHandlers[id] = handler;

    final cApi = apiName.toNativeUtf8().cast<Char>();
    final cDesc = desc.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeRegisterCall(appHnd, cApi, cDesc, id);
      if (rc != 1) {
        _callHandlers.remove(id);
        throw LingoFuseError(
            'registerCall failed for "$apiName" (duplicate name?)');
      }
      return id;
    } finally {
      calloc.free(cApi);
      calloc.free(cDesc);
    }
  }

  int registerNotify(Pointer<Void> appHnd, String apiName, String desc,
      NotifyHandler handler) {
    final id = _nextId++;
    _notifyHandlers[id] = handler;

    final cApi = apiName.toNativeUtf8().cast<Char>();
    final cDesc = desc.toNativeUtf8().cast<Char>();
    try {
      final rc = _ffi.lfBridgeRegisterNotify(appHnd, cApi, cDesc, id);
      if (rc != 1) {
        _notifyHandlers.remove(id);
        throw LingoFuseError(
            'registerNotify failed for "$apiName" (duplicate name?)');
      }
      return id;
    } finally {
      calloc.free(cApi);
      calloc.free(cDesc);
    }
  }

  // -----------------------------------------------------------------
  // Message dispatch
  // -----------------------------------------------------------------

  void _onMessage(dynamic msg) {
    if (msg is! List || msg.length != 3) return;

    final requestId = msg[0] as int;
    final callbackId = msg[1] as int;
    final input = msg[2] as Uint8List;

    if (requestId == 0) {
      final handler = _notifyHandlers[callbackId];
      if (handler == null) return;
      try {
        handler(input);
      } catch (e, st) {
        _reportError('notify callback', e, st);
      }
      return;
    }

    final handler = _callHandlers[callbackId];
    if (handler == null) {
      _postComplete(requestId, Uint8List(0));
      return;
    }

    Uint8List output;
    try {
      output = handler(input);
    } catch (e, st) {
      _reportError('call callback', e, st);
      output = Uint8List(0);
    }
    _postComplete(requestId, output);
  }

  void _postComplete(int requestId, Uint8List output) {
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

  void _reportError(String where, Object e, StackTrace st) {
    // ignore: avoid_print
    print('[LingoFuse bridge] error in $where: $e\n$st');
  }
}