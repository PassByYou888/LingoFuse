// bin/phase4_bridge_probe.dart
//
// End-to-end probe for the bridge shared library.
//
// Exercises, in order:
//   1. BridgeHost.start()                  -- init the C bridge
//   2. lfBridgeVersion / lfBridgeIsInitialized
//   3. lfBridgeCreateData / WriteBuffer / ReadBuffer / GetSize / FreeData
//   4. lfBridgeGetP2PUid / GetP2PName on a self-created handle
//      (should return 32 zero bytes and an empty string)
//   5. lfBridgeWriteUid / ReadUid
//   6. lfBridgeStatsJson
//   7. BridgeHost.stop()
//
// Run:
//     dart run bin/phase4_bridge_probe.dart
//
// Requires lf_dart_bridge.dll and LingoFuse64.dll on the loader path
// (see README.md).
//
// All output is in English.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:lingofuse/src/bridge/bridge_error.dart';
import 'package:lingofuse/src/bridge/bridge_ffi.dart';
import 'package:lingofuse/src/bridge/bridge_host.dart';

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

  print('=== Phase 4 bridge probe ===\n');

  // -----------------------------------------------------------------
  // 1. Start the bridge host
  // -----------------------------------------------------------------
  print('[1] Starting BridgeHost...');
  try {
    await BridgeHost.start();
    check('BridgeHost.start()', true);
  } catch (e, st) {
    check('BridgeHost.start()', false, '$e');
    print(st);
    exit(1);
  }

  final bridge = BridgeHost.instance;
  final ffi = BridgeFfi.instance;

  // -----------------------------------------------------------------
  // 2. Version and init status
  // -----------------------------------------------------------------
  print('\n[2] Version and init status...');
  final version = bridge.version;
  print('         version : $version');
  check('version is non-empty', version.isNotEmpty);
  check('is_initialized == 1', ffi.lfBridgeIsInitialized() == 1);

  // -----------------------------------------------------------------
  // 3. DataHandle round-trip
  // -----------------------------------------------------------------
  print('\n[3] DataHandle round-trip...');

  final cApi = 'bridge_probe'.toNativeUtf8().cast<Char>();
  final hnd = ffi.lfBridgeCreateData(cApi);
  calloc.free(cApi);
  check('create_data returns non-null', hnd != nullptr);

  // Write 4 bytes.
  final writeBuf = calloc<Uint8>(4);
  writeBuf[0] = 0x01;
  writeBuf[1] = 0x02;
  writeBuf[2] = 0x03;
  writeBuf[3] = 0x04;
  final written = ffi.lfBridgeWriteBuffer(hnd, writeBuf.cast<Void>(), 4);
  calloc.free(writeBuf);
  check('write_buffer wrote 4 bytes', written == 4, 'got $written');
  check('get_size == 4', ffi.lfBridgeGetSize(hnd) == 4,
      'got ${ffi.lfBridgeGetSize(hnd)}');

  // Rewind and read.
  ffi.lfBridgeSetPos(hnd, 0);
  check('get_pos == 0 after set_pos', ffi.lfBridgeGetPos(hnd) == 0);

  final readBuf = calloc<Uint8>(4);
  final got = ffi.lfBridgeReadBuffer(hnd, readBuf.cast<Void>(), 4);
  final bytes = <int>[readBuf[0], readBuf[1], readBuf[2], readBuf[3]];
  calloc.free(readBuf);
  check('read_buffer read 4 bytes', got == 4, 'got $got');
  check(
      'payload matches 01 02 03 04',
      bytes[0] == 1 && bytes[1] == 2 && bytes[2] == 3 && bytes[3] == 4,
      'got $bytes');

  // -----------------------------------------------------------------
  // 4. P2P identity on a self-created handle
  // -----------------------------------------------------------------
  print('\n[4] P2P identity on a self-created handle...');
  print('         (should return 32 zero bytes and an empty string)');

  final uidBuf = calloc<Uint8>(32);
  final rcUid = ffi.lfBridgeGetP2PUid(hnd, uidBuf);
  final uidBytes = uidBuf.asTypedList(32);
  final allZero = uidBytes.every((b) => b == 0);
  check('get_p2p_uid returns OK', rcUid == BridgeErrorCode.ok,
      'rc=$rcUid');
  check('self-created handle yields 32 zero bytes', allZero,
      'got ${uidBytes.toList()}');
  calloc.free(uidBuf);

  final nameBuf = calloc<Char>(256);
  final rcName = ffi.lfBridgeGetP2PName(hnd, nameBuf, 256);
  final name = nameBuf.cast<Utf8>().toDartString();
  check('get_p2p_name returns OK', rcName == BridgeErrorCode.ok,
      'rc=$rcName');
  check('self-created handle yields empty name', name.isEmpty,
      'got "$name"');
  calloc.free(nameBuf);

  // -----------------------------------------------------------------
  // 5. UID binary I/O
  // -----------------------------------------------------------------
  print('\n[5] UID binary I/O on a fresh handle...');

  final cApi2 = 'bridge_probe_uid'.toNativeUtf8().cast<Char>();
  final hnd2 = ffi.lfBridgeCreateData(cApi2);
  calloc.free(cApi2);

  final uidIn = calloc<Uint8>(32);
  for (int i = 0; i < 32; i++) {
    uidIn[i] = (i * 7) & 0xFF;
  }
  final rcW = ffi.lfBridgeWriteUid(hnd2, uidIn);
  check('write_uid returns OK', rcW == BridgeErrorCode.ok, 'rc=$rcW');
  check('size grew by exactly 32', ffi.lfBridgeGetSize(hnd2) == 32,
      'got ${ffi.lfBridgeGetSize(hnd2)}');

  ffi.lfBridgeSetPos(hnd2, 0);
  final uidOut = calloc<Uint8>(32);
  final rcR = ffi.lfBridgeReadUid(hnd2, uidOut);
  check('read_uid returns OK', rcR == BridgeErrorCode.ok, 'rc=$rcR');
  bool uidMatch = true;
  for (int i = 0; i < 32; i++) {
    if (uidIn[i] != uidOut[i]) {
      uidMatch = false;
      break;
    }
  }
  check('UID round-trip is byte-exact', uidMatch);
  calloc.free(uidIn);
  calloc.free(uidOut);

  // -----------------------------------------------------------------
  // 6. Free both handles
  // -----------------------------------------------------------------
  print('\n[6] Releasing handles...');
  ffi.lfBridgeFreeData(hnd);
  ffi.lfBridgeFreeData(hnd2);
  check('free_data did not throw', true);

  // -----------------------------------------------------------------
  // 7. Stats
  // -----------------------------------------------------------------
  print('\n[7] Bridge stats...');
  final statsJson = bridge.statsJson;
  print('         stats : $statsJson');
  check('stats JSON is non-empty', statsJson.isNotEmpty);
  check('stats JSON starts with "{"', statsJson.startsWith('{'));

  // -----------------------------------------------------------------
  // 8. Stop
  // -----------------------------------------------------------------
  print('\n[8] Stopping BridgeHost...');
  bridge.stop();
  check('stop() did not throw', true);

  // -----------------------------------------------------------------
  // Summary
  // -----------------------------------------------------------------
  print('\n=== Summary ===');
  print('  passed: $passed');
  print('  failed: $failed');
  exit(failed == 0 ? 0 : 1);
}