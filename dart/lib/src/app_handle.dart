// RAII wrapper around a native LingoFuse application handle.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bridge/bridge_host.dart';
import 'errors.dart';
import 'runtime.dart';

/// RAII wrapper around a native LingoFuse application handle.
///
/// Registering Call and Notify APIs requires [BridgeHost.start] to have
/// been called first.
class AppHandle {
  final Pointer<Void> _raw;
  final String _name;
  bool _disposed = false;

  AppHandle._(this._raw, this._name);

  /// Creates a new application.
  factory AppHandle(String name, String description) {
    final lf = getBindings();
    final cName = name.toNativeUtf8().cast<Char>();
    final cDesc = description.toNativeUtf8().cast<Char>();
    try {
      final hnd = lf.LF_CreateApp(cName, cDesc);
      if (hnd == nullptr) {
        throw LingoFuseError('LF_CreateApp returned null for "$name"');
      }
      return AppHandle._(hnd, name);
    } finally {
      calloc.free(cName);
      calloc.free(cDesc);
    }
  }

  Pointer<Void> get raw {
    _ensureNotDisposed();
    return _raw;
  }

  String get name => _name;
  bool get isValid => !_disposed && _raw != nullptr;

  void _ensureNotDisposed() {
    if (_disposed || _raw == nullptr) {
      throw LingoFuseObjectDisposedError('AppHandle');
    }
  }

  /// Registers a Call API.
  ///
  /// [handler] receives the input bytes and returns the output bytes.
  void registerCall(String apiName, String description, CallHandler handler) {
    _ensureNotDisposed();
    BridgeHost.instance.registerCall(_raw, apiName, description, handler);
  }

  /// Registers a Notify API.
  void registerNotify(
      String apiName, String description, NotifyHandler handler) {
    _ensureNotDisposed();
    BridgeHost.instance.registerNotify(_raw, apiName, description, handler);
  }

  /// Unregisters a previously registered API.
  bool unregister(String apiName) {
    _ensureNotDisposed();
    final lf = getBindings();
    final cName = apiName.toNativeUtf8().cast<Char>();
    try {
      return lf.LF_Unregister(_raw, cName) == 1;
    } finally {
      calloc.free(cName);
    }
  }

  /// Releases the app handle. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_raw != nullptr) {
      getBindings().LF_FreeApp(_raw);
    }
  }
}