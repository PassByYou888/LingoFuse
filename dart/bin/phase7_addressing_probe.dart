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
  app.registerCall('echo', 'Echo bytes', (CallContext ctx) => ctx.payload);
  check('registerCall("echo")', true);

  print('\n[Setup] Starting framework...');
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService('ipc:dart_p7', 'ipc:dart_p7');
  Framework.prepareClient('ipc:dart_p7', app: app);
  check('prepareDone', Framework.prepareDone());

  bool visible = false;
  for (int i = 0; i < 30; i++) {
    if (Framework.checkApp(appName)) {
      visible = true;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
  check('app "$appName" visible on mesh', visible);

  print('\n[Setup] Waiting for P2PName to propagate...');
  await Future.delayed(const Duration(milliseconds: 2000));

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

  print('\n[3] UIDTarget: dead-route with a fake UID');
  print('         (no client owns this UID; call must settle)');

  {
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