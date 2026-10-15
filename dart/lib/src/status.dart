// Status queue and health-check helpers for the LingoFuse runtime.
//
// TWO ROUTING PATHS
// -----------------
// The status queue methods (getStatusCount / getStatus / drainStatus /
// postStatus) use the legacy direct-FFI path. They are available
// without the C bridge.
//
// The UID and P2PName health checks route through the C bridge because
// the legacy ffigen bindings do not expose LF_Check_UID,
// LF_Check_UID_Api, LF_Check_P2PNAME, or LF_Check_P2PNAME_Api. Each
// requires BridgeHost.start() to have been called first.
//
// All diagnostics are in English.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bridge/bridge_ffi.dart';
import 'bridge/bridge_host.dart';
import 'runtime.dart';

/// Process-wide status queue and health-check helpers.
class LingoFuseStatus {
  LingoFuseStatus._();

  // =================================================================
  // Status queue (legacy FFI)
  // =================================================================

  /// Number of pending log messages in the status queue.
  ///
  /// The queue holds up to 1000 messages; older messages are discarded
  /// on overflow. Relies on the simulated main thread, so it is only
  /// meaningful after the framework has started.
  static int getStatusCount() {
    return getBindings().LF_GetStatusCount();
  }

  /// Retrieves the next log message from the status queue (FIFO), or an
  /// empty string when the queue is empty.
  ///
  /// The library returns a pointer into a static 64KB buffer that is
  /// invalidated by the next call. This method copies the string into a
  /// fresh Dart String immediately, so the caller never sees the
  /// transient pointer.
  static String getStatus() {
    final ptr = getBindings().LF_GetStatus();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  /// Drains up to [maxMessages] pending status messages into a list, in
  /// FIFO order.
  static List<String> drainStatus([int maxMessages = 64]) {
    if (maxMessages <= 0) return const [];
    final pending = getStatusCount();
    if (pending <= 0) return const [];
    final count = pending < maxMessages ? pending : maxMessages;
    final out = <String>[];
    for (int i = 0; i < count; i++) {
      final msg = getStatus();
      if (msg.isEmpty) break;
      out.add(msg);
    }
    return out;
  }

  /// Injects a custom status message into the queue.
  static void postStatus(String message) {
    final c = message.toNativeUtf8().cast<Char>();
    try {
      getBindings().LF_PostStatus(c);
    } finally {
      calloc.free(c);
    }
  }

  // =================================================================
  // UID / P2PName health checks (bridge)
  // =================================================================
  //
  // These consult the same locally cached broadcast view as the App-name
  // checks, with the same ~3-second propagation delay. They are probing
  // tools, not authoritative existence tests.
  //
  // Each method requires BridgeHost.start() to have been called first.

  /// True when a client with the given UID is known to the mesh.
  ///
  /// [uid] must be exactly 32 bytes.
  ///
  /// Throws [RangeError] on a wrong-length UID.
  /// Throws [StateError] if the bridge layer is not active.
  static bool checkUid(Uint8List uid) {
    _checkUidLength(uid);
    _ensureBridge('checkUid');

    final ffi = BridgeFfi.instance;
    final uidPtr = calloc<Uint8>(32);
    try {
      uidPtr.asTypedList(32).setAll(0, uid);
      return ffi.lfBridgeCheckUid(uidPtr) == 1;
    } finally {
      calloc.free(uidPtr);
    }
  }

  /// True when a client with the given UID exposes the named API.
  ///
  /// [uid] must be exactly 32 bytes.
  ///
  /// Throws [RangeError] on a wrong-length UID.
  /// Throws [StateError] if the bridge layer is not active.
  static bool checkUidApi(Uint8List uid, String apiName) {
    _checkUidLength(uid);
    _ensureBridge('checkUidApi');

    final ffi = BridgeFfi.instance;
    final uidPtr = calloc<Uint8>(32);
    final cApi = apiName.toNativeUtf8().cast<Char>();
    try {
      uidPtr.asTypedList(32).setAll(0, uid);
      return ffi.lfBridgeCheckUidApi(uidPtr, cApi) == 1;
    } finally {
      calloc.free(uidPtr);
      calloc.free(cApi);
    }
  }

  /// True when at least one client has the given P2P group name.
  ///
  /// Throws [StateError] if the bridge layer is not active.
  static bool checkP2PName(String p2pName) {
    _ensureBridge('checkP2PName');

    final ffi = BridgeFfi.instance;
    final cP2P = p2pName.toNativeUtf8().cast<Char>();
    try {
      return ffi.lfBridgeCheckP2PName(cP2P) == 1;
    } finally {
      calloc.free(cP2P);
    }
  }

  /// True when at least one client in the given P2P group exposes the
  /// named API.
  ///
  /// Throws [StateError] if the bridge layer is not active.
  static bool checkP2PNameApi(String p2pName, String apiName) {
    _ensureBridge('checkP2PNameApi');

    final ffi = BridgeFfi.instance;
    final cP2P = p2pName.toNativeUtf8().cast<Char>();
    final cApi = apiName.toNativeUtf8().cast<Char>();
    try {
      return ffi.lfBridgeCheckP2PNameApi(cP2P, cApi) == 1;
    } finally {
      calloc.free(cP2P);
      calloc.free(cApi);
    }
  }

  // =================================================================
  // Internal helpers
  // =================================================================

  static void _ensureBridge(String operation) {
    if (BridgeHost.instanceOrNull == null) {
      throw StateError(
        '$operation requires the bridge layer. '
        'Call "await BridgeHost.start()" before using it.',
      );
    }
  }

  static void _checkUidLength(Uint8List uid) {
    if (uid.length != 32) {
      throw RangeError('UID must be exactly 32 bytes, got ${uid.length}.');
    }
  }
}