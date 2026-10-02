// Phase 3: end-to-end server test.
// Registers an "echo" Call API on the Dart side, then calls it from a
// child isolate (to avoid blocking the main isolate's event loop).

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:lingofuse/lingofuse.dart';

Future<void> main() async {
  int passed = 0;
  int failed = 0;
  void check(String name, bool ok, [String? detail]) {
    if (ok) {
      print('  [OK]   $name');
      passed++;
    } else {
      print('  [FAIL] $name${detail != null ? ' - $detail' : ''}');
      failed++;
    }
  }

  print('=== Phase 3 smoke test (server via C bridge) ===\n');

  // ---- 1. Start bridge host ----
  print('[1] Starting bridge host...');
  await BridgeHost.start();
  check('BridgeHost started', true);

  // ---- 2. Create app and register echo ----
  print('\n[2] Registering "echo" API...');
  final app = AppHandle('DartP3', 'Phase 3 test');
  app.registerCall('echo', 'Echo bytes', (Uint8List input) {
    // ignore: avoid_print
    print('    [callback] echo received ${input.length} bytes');
    return input;
  });
  check('echo API registered', true);

  // ---- 3. Prepare network ----
  print('\n[3] Preparing network...');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Quiet', 'True');
  Framework.resetPrepare();
  Framework.prepareService('ipc:dart_p3', 'ipc:dart_p3');
  Framework.prepareClient('ipc:dart_p3', app: app);   // <-- bind app
  final started = Framework.prepareDone();
  check('prepareDone', started);

  // ---- 4. Wait for app to be visible ----
  print('\n[4] Waiting for app visibility...');
  bool visible = false;
  for (int i = 0; i < 30; i++) {
    if (Framework.checkApp('DartP3')) {
      visible = true;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
  check('app "DartP3" is visible', visible);

  // ---- 5. Remote call from child isolate ----
  print('\n[5] Remote echo from child isolate...');
  final result = await Isolate.run(_remoteEcho);
  const expected = 'hello from child isolate';
  check('response is non-empty', result.isNotEmpty);
  check('response matches expected',
      String.fromCharCodes(result) == expected,
      'got: ${String.fromCharCodes(result)}');

  // ---- 6. Cleanup ----
  print('\n[6] Cleaning up...');
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
  check('shutdown clean', true);

  // ---- Summary ----
  print('\n=== Summary ===');
  print('  passed: $passed');
  print('  failed: $failed');
  exit(failed == 0 ? 0 : 1);
}

// Child isolate entry: loads the DLL directly and does a synchronous
// LF_Call.
Uint8List _remoteEcho() {
  const dllPath = r'D:\CoreLibrary\LingoFuse\Binary\LingoFuse64.dll';
  final dll = DynamicLibrary.open(dllPath);

  final LF_CreateData = dll.lookupFunction<
      Pointer<Void> Function(Pointer<Char>),
      Pointer<Void> Function(Pointer<Char>)>('LF_CreateData');
  final LF_WriteBuffer = dll.lookupFunction<
      Int64 Function(Pointer<Void>, Pointer<Void>, Int64),
      int Function(Pointer<Void>, Pointer<Void>, int)>('LF_WriteBuffer');
  final LF_Call = dll.lookupFunction<
      Pointer<Void> Function(Pointer<Char>, Pointer<Void>, Uint64),
      Pointer<Void> Function(Pointer<Char>, Pointer<Void>, int)>('LF_Call');
  final LF_GetSize = dll.lookupFunction<Int64 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('LF_GetSize');
  final LF_SetPos = dll.lookupFunction<Void Function(Pointer<Void>, Int64),
      void Function(Pointer<Void>, int)>('LF_SetPos');
  final LF_ReadBuffer = dll.lookupFunction<
      Int64 Function(Pointer<Void>, Pointer<Void>, Int64),
      int Function(Pointer<Void>, Pointer<Void>, int)>('LF_ReadBuffer');
  final LF_FreeData = dll.lookupFunction<Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('LF_FreeData');

  final cApi = 'echo'.toNativeUtf8().cast<Char>();
  final hnd = LF_CreateData(cApi);
  calloc.free(cApi);

  const payload = 'hello from child isolate';
  final bytes = payload.codeUnits;
  final ptr = calloc<Uint8>(bytes.length);
  ptr.asTypedList(bytes.length).setAll(0, bytes);
  LF_WriteBuffer(hnd, ptr.cast<Void>(), bytes.length);
  calloc.free(ptr);

  final cApp = 'DartP3'.toNativeUtf8().cast<Char>();
  final resp = LF_Call(cApp, hnd, 5000);
  calloc.free(cApp);

  final size = LF_GetSize(resp);
  LF_SetPos(resp, 0);
  final outPtr = calloc<Uint8>(size);
  LF_ReadBuffer(resp, outPtr.cast<Void>(), size);
  final result = Uint8List.fromList(outPtr.asTypedList(size));
  calloc.free(outPtr);

  LF_FreeData(hnd);
  LF_FreeData(resp);

  return result;
}