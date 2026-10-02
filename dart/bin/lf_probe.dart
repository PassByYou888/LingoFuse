// =============================================================
//  LingoFuse Dart FFI Probe
//  Loads LingoFuse64.dll and exercises the minimal ABI path:
//      LF_CreateData -> LF_WriteBuffer -> LF_GetSize -> LF_FreeData
//  Run with: dart run bin/lf_probe.dart
// =============================================================

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:lingofuse/src/bindings_generated.dart';

void main() {
  print('=== LingoFuse Dart FFI Probe ===\n');

  // -----------------------------------------------------------
  // [1] Locate the DLL
  // -----------------------------------------------------------
  const dllPath = r'D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll';
  print('[1] DLL path: $dllPath');
  if (!File(dllPath).existsSync()) {
    print('    [FAIL] File does not exist');
    exit(1);
  }
  print('    [OK] File exists');

  // -----------------------------------------------------------
  // [2] Load the DLL
  // -----------------------------------------------------------
  print('\n[2] Loading DLL...');
  late final DynamicLibrary lib;
  try {
    lib = DynamicLibrary.open(dllPath);
    print('    [OK] DLL loaded');
  } catch (e) {
    print('    [FAIL] $e');
    print('    Hint: z_ipc_64.dll and mimalloc64.dll must be findable.');
    print('          Add D:\\CoreLibrary\\LingoFuse\\Binary to PATH.');
    exit(1);
  }

  // -----------------------------------------------------------
  // [3] Instantiate the ffigen-generated bindings
  // -----------------------------------------------------------
  print('\n[3] Instantiating LingoFuseBindings...');
  final lf = LingoFuseBindings(lib);
  print('    [OK] Bindings ready');

  // -----------------------------------------------------------
  // [4] LF_CreateData
  // -----------------------------------------------------------
  print('\n[4] LF_CreateData("dart_probe")...');
  final apiName = 'dart_probe'.toNativeUtf8();
  final hnd = lf.LF_CreateData(apiName.cast<Char>());
  calloc.free(apiName);

  if (hnd == nullptr) {
    print('    [FAIL] Returned null handle');
    exit(1);
  }
  print('    [OK] Handle: $hnd');

  // -----------------------------------------------------------
  // [5] LF_WriteBuffer: write 4 bytes
  // -----------------------------------------------------------
  print('\n[5] LF_WriteBuffer(4 bytes)...');
  final payload = calloc<Uint8>(4);
  payload[0] = 0x01;
  payload[1] = 0x02;
  payload[2] = 0x03;
  payload[3] = 0x04;
  final written = lf.LF_WriteBuffer(hnd, payload.cast<Void>(), 4);
  calloc.free(payload);
  print('    bytes written: $written (expected 4)');
  if (written != 4) {
    print('    [FAIL] Short write');
    lf.LF_FreeData(hnd);
    exit(1);
  }
  print('    [OK]');

  // -----------------------------------------------------------
  // [6] LF_GetSize
  // -----------------------------------------------------------
  print('\n[6] LF_GetSize...');
  final size = lf.LF_GetSize(hnd);
  print('    buffer size: $size (expected 4)');
  if (size != 4) {
    print('    [FAIL] Unexpected size');
    lf.LF_FreeData(hnd);
    exit(1);
  }
  print('    [OK]');

  // -----------------------------------------------------------
  // [7] LF_ReadBuffer: read them back
  // -----------------------------------------------------------
  print('\n[7] LF_ReadBuffer...');
  lf.LF_SetPos(hnd, 0);
  final readBack = calloc<Uint8>(4);
  final got = lf.LF_ReadBuffer(hnd, readBack.cast<Void>(), 4);
  final bytes = <int>[
    readBack[0],
    readBack[1],
    readBack[2],
    readBack[3],
  ];
  calloc.free(readBack);
  print('    bytes read: $got');
  print('    payload:    $bytes');
  final match = got == 4 &&
      bytes[0] == 0x01 &&
      bytes[1] == 0x02 &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;
  if (!match) {
    print('    [FAIL] Payload mismatch');
    lf.LF_FreeData(hnd);
    exit(1);
  }
  print('    [OK] Round-trip successful');

  // -----------------------------------------------------------
  // [8] LF_FreeData
  // -----------------------------------------------------------
  print('\n[8] LF_FreeData...');
  lf.LF_FreeData(hnd);
  print('    [OK] Handle released');

  // -----------------------------------------------------------
  // Done
  // -----------------------------------------------------------
  print('\n=== All checks passed ===');
  print('Dart FFI can call LingoFuse64.dll correctly.');
}