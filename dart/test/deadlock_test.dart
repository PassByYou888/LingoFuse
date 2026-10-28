// Deadlock safety tests.
//
// These tests verify that the Dart binding never blocks the main isolate
// event loop for any public API call, and that a synchronous call from a
// child isolate does not block the main isolate.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';
import 'package:test/test.dart';

void main() {
  late AppHandle app;

  setUpAll(() async {
    await BridgeHost.start();

    Framework.setOption('Quiet', 'True');
    Framework.setOption('Wait_Connection_ReadyOk', 'False');
    Framework.setOption('Overlap_Connection', 'True');
    Framework.setOption('Wait_Connection_Timeout', '5000');
    Framework.setOptP2PName('deadlock_test_p2p');
    Framework.resetPrepare();

    app = AppHandle('DeadlockTest', 'Deadlock safety tests');
    app.registerCall('echo', 'Echo payload', (CallContext ctx) => ctx.payload);

    Framework.prepareService('ipc:deadlock_test', 'ipc:deadlock_test');
    Framework.prepareClient('ipc:deadlock_test', app: app);
    if (!Framework.prepareDone()) {
      throw StateError('Framework failed to start');
    }

    for (int i = 0; i < 30; i++) {
      if (Framework.checkApp('DeadlockTest')) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await Future.delayed(const Duration(milliseconds: 2000));
  });

  tearDownAll(() {
    app.dispose();
    Framework.exitMainThread();
    Framework.shutdown();
    BridgeHost.instance.stop();
  });

  test('main isolate: p2pnameCallAsync does not block the event loop',
      () async {
    final p2p = P2PNameTarget('deadlock_test_p2p');
    final param = DataHandle('echo');
    LfIo.writeJson(param, {'x': 1});
    param.position = 0;

    int ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      ticks++;
    });

    final completer = Completer<void>();
    p2p.callAsync('echo', {'x': 1}, (result, error) {
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future.timeout(const Duration(seconds: 5));
    timer.cancel();
    param.dispose();

    expect(ticks, greaterThan(0),
        reason: 'event loop must have run while the async call was in flight');
  });

  test('main isolate: uidCallAsync does not block the event loop', () async {
    // We need a valid UID; get one via whoami-like callback. For simplicity
    // here, use the fact that the client's own UID is generated on
    // TunnelLink. Use a zero UID which will simply not resolve, but the
    // dispatch itself must not block.
    final uid = Uint8List(32);
    final param = DataHandle('echo');
    LfIo.writeJson(param, {'x': 1});
    param.position = 0;

    int ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      ticks++;
    });

    final completer = Completer<void>();
    Framework.uidCallAsync(uid, param, (result, error) {
      // It may timeout or return empty; either way it must not block.
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future.timeout(const Duration(seconds: 5));
    timer.cancel();
    param.dispose();

    expect(ticks, greaterThan(0),
        reason: 'event loop must have run while the async call was in flight');
  });

  test('child isolate: sync call does not block main isolate event loop',
      () async {
    int ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
      ticks++;
    });

    final result = await Isolate.run(() {
      final param = DataHandle('echo');
      LfIo.writeJson(param, {'from': 'child'});
      param.position = 0;
      final resp = Framework.call('DeadlockTest', param, timeoutMs: 5000);
      final ok = resp.size > 0;
      resp.dispose();
      param.dispose();
      return ok;
    });

    timer.cancel();
    expect(result, isTrue,
        reason: 'child isolate sync call should have succeeded');
    expect(ticks, greaterThan(0),
        reason: 'main isolate event loop must have run during child execution');
  });
}