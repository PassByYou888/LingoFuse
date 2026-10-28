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

  print('=== Phase 6 async API probe ===\n');

  print('[Setup] Starting BridgeHost...');
  try {
    await BridgeHost.start();
    check('BridgeHost.start()', true);
  } catch (e) {
    check('BridgeHost.start()', false, '$e');
    exit(1);
  }

  const appName = 'DartP6';
  const groupName = 'dart_p6_group';

  print('\n[Setup] Declaring P2P group "$groupName"...');
  Framework.setOptP2PName(groupName);

  print('\n[Setup] Creating AppHandle and registering APIs...');
  final app = AppHandle(appName, 'Phase 6 async API test');
  app.registerCall('echo', 'Echo bytes', (CallContext ctx) => ctx.payload);
  check('registerCall("echo")', true);

  print('\n[Setup] Starting framework...');
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService('ipc:dart_p6', 'ipc:dart_p6');
  Framework.prepareClient('ipc:dart_p6', app: app);
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

  final target = P2PNameTarget(groupName);

  print('\n[1] Promise style: await target.call(...)');

  try {
    final promise = target.call(
      'echo',
      payload: {'msg': 'hello'},
      timeoutMs: 5000,
    );
    check('promise is not yet settled', !promise.settled);

    final bytes = await promise.future;
    final text = utf8.decode(bytes);

    check('promise resolved', true);
    check('response non-empty', bytes.isNotEmpty, 'size=${bytes.length}');
    check('response echoes payload', text.contains('hello'), 'got "$text"');
    check('promise.settled is true', promise.settled);
    check('promise.abandoned is false', !promise.abandoned);
  } catch (e, st) {
    check('Promise style', false, '$e');
    print(st);
  }

  print('\n[2] JSON style: await target.callJson<T>(...)');

  try {
    final json = await target
        .callJson<Map<String, dynamic>>(
          'echo',
          payload: {'name': 'Alice', 'age': 30},
          timeoutMs: 5000,
        )
        .future;

    check('callJson resolved', true);
    check('name field preserved',
        json['name'] == 'Alice', 'got ${json['name']}');
    check('age field preserved', json['age'] == 30, 'got ${json['age']}');
    check('payload contains exactly 2 fields',
        json.length == 2, 'got ${json.length} fields');
  } catch (e, st) {
    check('JSON style', false, '$e');
    print(st);
  }

  print('\n[3] Callback style: target.callAsync(...)');

  {
    final completer = Completer<Uint8List?>();
    String? observedError;

    target.callAsync('echo', {'k': 'v'}, (result, error) {
      observedError = error;
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    });

    try {
      final result = await completer.future.timeout(
        const Duration(seconds: 8),
      );
      check('callback fired', true);
      check('no error reported', observedError == null,
          'error=$observedError');
      check('result non-null', result != null);
      check('result non-empty', result != null && result.isNotEmpty);
      if (result != null) {
        final text = utf8.decode(result);
        check('callback payload correct', text.contains('"k":"v"'),
            'got "$text"');
      }
    } on TimeoutException {
      check('callback fired', false, 'timeout waiting for callback');
    }
  }

  print('\n[4] Short timeout (1ms)');
  print('         (the promise must settle, one way or the other)');

  {
    final promise = target.call('echo', payload: {'x': 1}, timeoutMs: 1);
    bool abandonedByException = false;
    try {
      await promise.future;
    } on TimeoutException {
      abandonedByException = true;
    } catch (_) {
    }

    check('promise settled', promise.settled);
    check('abandoned flag is consistent',
        !promise.abandoned || promise.settled);
    print(
        '         abandoned: $abandonedByException '
        '(promise.abandoned=${promise.abandoned})');
  }

  print('\n[5] Missing API returns empty bytes or times out');

  try {
    final bytes = await target
        .call('__does_not_exist__', payload: {'x': 1}, timeoutMs: 1500)
        .future;
    check('missing API call settled', true);
    check('missing API returned empty bytes', bytes.isEmpty,
        'got ${bytes.length} bytes');
  } on TimeoutException {
    check('missing API timed out (acceptable)', true);
  } catch (e) {
    check('missing API failed cleanly', true, '$e');
  }

  print('\n[6] Sequenced async (P2PName): FIFO ordering');

  {
    const int kCount = 3;
    final results = <Uint8List?>[];
    final completer = Completer<void>();
    int remaining = kCount;

    for (int i = 0; i < kCount; i++) {
      final param = DataHandle('echo');
      LfIo.writeJson(param, {'seq': i});
      param.position = 0;
      Framework.p2pnameCallAsyncSequenced(groupName, param, (result, error) {
        if (error != null) {
          if (!completer.isCompleted) {
            completer.completeError('seq $i failed: $error');
          }
          return;
        }
        results.add(result);
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete();
        }
      });
      param.dispose();
    }

    try {
      await completer.future.timeout(const Duration(seconds: 8));
      check('sequenced async resolved all $kCount', results.length == kCount);

      bool orderOk = true;
      for (int i = 0; i < results.length; i++) {
        final text = utf8.decode(results[i] ?? Uint8List(0));
        if (!text.contains('"seq":$i')) {
          orderOk = false;
          print('         out of order: index $i got "$text"');
          break;
        }
      }
      check('sequenced async preserves FIFO order', orderOk);
    } on TimeoutException {
      check('sequenced async resolved all $kCount', false,
          'timeout after 8s (received ${results.length}/$kCount)');
    } catch (e) {
      check('sequenced async resolved all $kCount', false, '$e');
    }
  }

  print('\n[7] BridgeHost UID length validation (must throw RangeError)');

  {
    final shortUid = Uint8List(31);
    final longUid = Uint8List(33);
    final param = DataHandle('echo');

    try {
      bool threwRange = false;
      try {
        BridgeHost.instance.uidCallAsync(
          shortUid,
          param.raw,
          (_, __) {},
        );
      } on RangeError {
        threwRange = true;
      } catch (e) {
        print('         got ${e.runtimeType}: $e');
      }
      check('BridgeHost.uidCallAsync(31) throws RangeError', threwRange);

      threwRange = false;
      try {
        BridgeHost.instance.uidCallAsync(
          longUid,
          param.raw,
          (_, __) {},
        );
      } on RangeError {
        threwRange = true;
      } catch (e) {
        print('         got ${e.runtimeType}: $e');
      }
      check('BridgeHost.uidCallAsync(33) throws RangeError', threwRange);

      threwRange = false;
      try {
        BridgeHost.instance.uidCallAsyncSequenced(
          shortUid,
          param.raw,
          (_, __) {},
        );
      } on RangeError {
        threwRange = true;
      } catch (e) {
        print('         got ${e.runtimeType}: $e');
      }
      check('BridgeHost.uidCallAsyncSequenced(31) throws RangeError',
          threwRange);
    } finally {
      param.dispose();
    }
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