// Phase 7 probe: end-to-end verification of the three-addressing
// abstraction.
//
// The three addressing modes are:
//
//   AppTarget        address a logical App by its name.
//   UIDTarget        address a specific session by its 32-byte UID.
//   P2PNameTarget    address a group of clients by a user-supplied name.
//
// ROUTING AND THE ASYNC HAZARD
// ----------------------------
// App-name and UID routing are LOCAL-FIRST. When the caller process
// itself hosts a matching App or client, the request is dispatched to
// the local instance on the CALLING thread. For the async family, a
// local dispatch on the Dart main isolate deadlocks (the reason is
// documented at length in phase6_async_probe.dart).
//
// P2PName routing is NOT local-first. It always goes through the server
// dispatcher, which runs on an independent native thread. That makes
// P2PName the only safe addressing mode for async calls issued from
// the Dart main isolate.
//
// This probe therefore exercises:
//
//   [1] AppTarget        static properties only (hashKey, describe);
//                        no live call is attempted, because a live
//                        AppTarget.call from the main isolate would
//                        deadlock.
//
//   [2] UIDTarget        argument validation (pure Dart).
//
//   [3] UIDTarget        a live call to a fake UID. Because no client
//                        owns the UID, the call cannot route to a local
//                        target and therefore cannot deadlock. It is
//                        expected to settle within the timeout.
//
//   [4] P2PNameTarget    a live end-to-end call. This is the primary
//                        verification that the addressing abstraction
//                        works end to end.
//
//   [5] Cross-type hashKey prefixes must not collide.
//
// A true end-to-end UID test -- where a client learns its own UID and
// calls itself by UID -- requires the C bridge to expose the caller's
// identity from the input handle of a Protocol A callback. That
// capability is planned for a future revision of the bridge.
//
// Run:
//     dart run bin/phase7_addressing_probe.dart
//
// All output is in English.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  print('=== Phase 7 addressing probe ===\n');

  // -----------------------------------------------------------------
  // Setup
  // -----------------------------------------------------------------
  print('[Setup] Starting BridgeHost...');
  try {
    await BridgeHost.start();
    check('BridgeHost.start()', true);
  } catch (e) {
    check('BridgeHost.start()', false, '$e');
    exit(1);
  }

  const appName = 'DartP7';
  const groupName = 'dart_p7_group';

  print('\n[Setup] Declaring P2P group "$groupName"...');
  Framework.setOptP2PName(groupName);

  print('\n[Setup] Creating AppHandle and registering APIs...');
  final app = AppHandle(appName, 'Phase 7 addressing test');
  app.registerCall('echo', 'Echo bytes', (Uint8List input) => input);
  check('registerCall("echo")', true);

  print('\n[Setup] Starting framework...');
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService('ipc:dart_p7', 'ipc:dart_p7');
  Framework.prepareClient('ipc:dart_p7', app: app);
  check('prepareDone', Framework.prepareDone());

  // Wait for the app to become visible.
  bool visible = false;
  for (int i = 0; i < 30; i++) {
    if (Framework.checkApp(appName)) {
      visible = true;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
  check('app "$appName" visible on mesh', visible);

  // Wait for the P2P name to propagate.
  print('\n[Setup] Waiting for P2PName to propagate...');
  await Future.delayed(const Duration(milliseconds: 2000));

  // -----------------------------------------------------------------
  // [1] AppTarget: static properties only
  // -----------------------------------------------------------------
  print('\n[1] AppTarget: static properties (no live call)');

  {
    final target = AppTarget(appName);
    check('appName preserved', target.appName == appName);
    check('hashKey has "app:" prefix',
        target.hashKey == 'app:$appName', 'got "${target.hashKey}"');
    check('describe includes name',
        target.describe().contains(appName),
        'got "${target.describe()}"');
  }

  // -----------------------------------------------------------------
  // [2] UIDTarget: argument validation
  // -----------------------------------------------------------------
  print('\n[2] UIDTarget: parameter validation');

  check(
    'UIDTarget rejects 31-byte UID with RangeError',
    _throwsRangeError(() => UIDTarget(Uint8List(31))),
  );
  check(
    'UIDTarget rejects 33-byte UID with RangeError',
    _throwsRangeError(() => UIDTarget(Uint8List(33))),
  );
  check(
    'UIDTarget.hex rejects wrong-length hex with RangeError',
    _throwsRangeError(() => UIDTarget.hex('abc')),
  );
  check(
    'UIDTarget.hex rejects non-hex characters with RangeError',
    _throwsRangeError(() => UIDTarget.hex('zz' * 32)),
  );
  check(
    'UIDTarget accepts a 32-byte Uint8List',
    !_throwsRangeError(() => UIDTarget(Uint8List(32))),
  );
  check(
    'UIDTarget.hex accepts a 64-char hex string',
    !_throwsRangeError(() => UIDTarget.hex('11' * 32)),
  );

  // -----------------------------------------------------------------
  // [3] UIDTarget: dead-route behavior
  // -----------------------------------------------------------------
  print('\n[3] UIDTarget: dead-route with a fake UID');
  print('         (no client owns this UID; call must settle)');

  {
    // Build a syntactically valid but semantically unknown UID.
    // Use 0xFF to minimise the chance of an accidental collision.
    final fakeUid = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      fakeUid[i] = 0xFF;
    }

    final target = UIDTarget(fakeUid);
    check('UIDTarget constructed', true);
    check(
      'hashKey uses lowercase hex',
      target.hashKey == 'uid:${'ff' * 32}',
      'got "${target.hashKey}"',
    );

    try {
      final bytes = await target
          .call('echo', payload: {'via': 'uid'}, timeoutMs: 1500)
          .future;
      check('dead-route settled (empty response)', bytes.isEmpty,
          'got ${bytes.length} bytes');
    } on TimeoutException {
      check('dead-route settled (timeout)', true);
    } catch (e) {
      check('dead-route settled (other error)', true, '$e');
    }
  }

  // -----------------------------------------------------------------
  // [4] P2PNameTarget: live end-to-end call
  // -----------------------------------------------------------------
  print('\n[4] P2PNameTarget: live call via the server dispatcher');

  {
    final target = P2PNameTarget(groupName);
    check('hashKey has "p2p:" prefix',
        target.hashKey == 'p2p:$groupName',
        'got "${target.hashKey}"');
    check('describe includes group name',
        target.describe().contains(groupName));

    try {
      final bytes = await target
          .call('echo', payload: {'via': 'p2pname'}, timeoutMs: 5000)
          .future;
      final text = utf8.decode(bytes);

      check('P2PNameTarget.call resolved', true);
      check('response echoes payload', text.contains('p2pname'),
          'got "$text"');
    } on TimeoutException {
      check('P2PNameTarget.call', false,
          'timeout: P2PName never propagated to the server');
    } catch (e, st) {
      check('P2PNameTarget.call', false, '$e');
      print(st);
    }
  }

  // -----------------------------------------------------------------
  // [5] Cross-type hashKeys must not collide
  // -----------------------------------------------------------------
  print('\n[5] Cross-type hashKeys do not collide');

  {
    final a = AppTarget('X');
    final p = P2PNameTarget('X');
    final u = UIDTarget(Uint8List(32));

    check('app vs p2p hashKeys differ', a.hashKey != p.hashKey);
    check('app hashKey prefix is "app:"', a.hashKey.startsWith('app:'));
    check('p2p hashKey prefix is "p2p:"', p.hashKey.startsWith('p2p:'));
    check('uid hashKey prefix is "uid:"', u.hashKey.startsWith('uid:'));
  }

  // -----------------------------------------------------------------
  // Cleanup
  // -----------------------------------------------------------------
  print('\n[Cleanup]');
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();
  check('cleanup complete', true);

  print('\n=== Summary ===');
  print('  passed: $passed');
  print('  failed: $failed');
  exit(failed == 0 ? 0 : 1);
}

/// Helper: returns true if [fn] throws a [RangeError].
bool _throwsRangeError(void Function() fn) {
  try {
    fn();
    return false;
  } on RangeError {
    return true;
  } catch (_) {
    return false;
  }
}