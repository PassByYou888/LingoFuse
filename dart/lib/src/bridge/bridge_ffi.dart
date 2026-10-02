// FFI declarations for lf_dart_bridge.dll.

import 'dart:ffi';
import 'dart:io';

typedef LfBridgeInitNative = Int32 Function(Int64, Pointer<Void>);
typedef LfBridgeInitDart = int Function(int, Pointer<Void>);

typedef LfBridgeRegisterCallNative = Int32 Function(
    Pointer<Void>, Pointer<Char>, Pointer<Char>, Int64);
typedef LfBridgeRegisterCallDart = int Function(
    Pointer<Void>, Pointer<Char>, Pointer<Char>, int);

typedef LfBridgeRegisterNotifyNative = Int32 Function(
    Pointer<Void>, Pointer<Char>, Pointer<Char>, Int64);
typedef LfBridgeRegisterNotifyDart = int Function(
    Pointer<Void>, Pointer<Char>, Pointer<Char>, int);

typedef LfBridgeCompleteNative = Void Function(Int64, Pointer<Uint8>, Int64);
typedef LfBridgeCompleteDart = void Function(int, Pointer<Uint8>, int);

typedef LfBridgeShutdownNative = Void Function();
typedef LfBridgeShutdownDart = void Function();

class BridgeFfi {
  final DynamicLibrary _lib;
  BridgeFfi(this._lib);

  late final LfBridgeInitDart lfBridgeInit =
      _lib.lookupFunction<LfBridgeInitNative, LfBridgeInitDart>(
          'lf_bridge_init');

  late final LfBridgeRegisterCallDart lfBridgeRegisterCall =
      _lib.lookupFunction<LfBridgeRegisterCallNative,
          LfBridgeRegisterCallDart>('lf_bridge_register_call');

  late final LfBridgeRegisterNotifyDart lfBridgeRegisterNotify =
      _lib.lookupFunction<LfBridgeRegisterNotifyNative,
          LfBridgeRegisterNotifyDart>('lf_bridge_register_notify');

  late final LfBridgeCompleteDart lfBridgeComplete =
      _lib.lookupFunction<LfBridgeCompleteNative, LfBridgeCompleteDart>(
          'lf_bridge_complete');

  late final LfBridgeShutdownDart lfBridgeShutdown =
      _lib.lookupFunction<LfBridgeShutdownNative, LfBridgeShutdownDart>(
          'lf_bridge_shutdown');

  static BridgeFfi load() {
    final env = Platform.environment['LINGOFUSE_BRIDGE_DLL'];
    if (env != null && env.isNotEmpty) {
      return BridgeFfi(DynamicLibrary.open(env));
    }
    const candidates = [
      r'bridge\lf_dart_bridge.dll',
      'lf_dart_bridge.dll',
    ];
    Object? lastError;
    for (final c in candidates) {
      try {
        return BridgeFfi(DynamicLibrary.open(c));
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
        'Could not load lf_dart_bridge.dll. Set LINGOFUSE_BRIDGE_DLL '
        'or place the DLL next to the executable. Last error: $lastError');
  }
}