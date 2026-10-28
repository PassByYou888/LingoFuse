import 'dart:async';

import 'package:lingofuse/lingofuse.dart';
import 'package:test/test.dart';

const String kTestVersion = 'call_context_test-v3';
const String kAppName = 'DartCtxTestServer';
const String kEndpoint = 'ipc:dart_ctx_test_server';
const String kP2PName = 'dart_ctx_test_p2p';

late AppHandle _app;
final List<CallContext> _receivedContexts = [];

void main() {
  setUpAll(() async {
    // ignore: avoid_print
    print('[call_context_test] version = $kTestVersion');

    await BridgeHost.start();

    Framework.setOption('Quiet', 'True');
    Framework.setOption('Wait_Connection_ReadyOk', 'False');
    Framework.setOption('Overlap_Connection', 'True');
    Framework.setOption('Wait_Connection_Timeout', '5000');
    Framework.setOptP2PName(kP2PName);
    Framework.resetPrepare();

    _app = AppHandle(kAppName, 'CallContext test app');

    _app.registerNotify('ctx_probe', 'Record caller context',
        (CallContext ctx) {
      _receivedContexts.add(ctx);
    });

    _app.registerCall('ctx_call_echo', 'Record + echo', (CallContext ctx) {
      _receivedContexts.add(ctx);
      return ctx.payload;
    });

    Framework.prepareService(kEndpoint, kEndpoint);
    Framework.prepareClient(kEndpoint, app: _app);
    if (!Framework.prepareDone()) {
      throw StateError('Framework failed to start');
    }

    bool visible = false;
    for (int i = 0; i < 30; i++) {
      if (Framework.checkApp(kAppName)) {
        visible = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (!visible) {
      throw StateError('App "$kAppName" did not become visible');
    }

    await Future.delayed(const Duration(milliseconds: 2000));
  });

  tearDownAll(() {
    _app.dispose();
    Framework.exitMainThread();
    Framework.shutdown();
    BridgeHost.instance.stop();
  });

  group('CallContext delivery [$kTestVersion]', () {
    test('async call delivers a CallContext with payload', () async {
      _receivedContexts.clear();
      final param = DataHandle('ctx_call_echo');
      LfIo.writeJson(param, {'k': 'v'});
      param.position = 0;

      final completer = Completer<void>();
      Framework.p2pnameCallAsync(kP2PName, param, (result, error) {
        if (completer.isCompleted) return;
        if (error != null) {
          completer.completeError(StateError('async call failed: $error'));
        } else {
          completer.complete();
        }
      });
      param.dispose();

      await completer.future.timeout(const Duration(seconds: 10));

      expect(_receivedContexts.isNotEmpty, isTrue,
          reason: 'CallContext was not delivered to the server callback');

      final ctx = _receivedContexts.last;
      expect(ctx.payload.length, greaterThan(0),
          reason: 'CallContext.payload must be the raw request bytes');
    });

    test('async notify delivers a CallContext with payload', () async {
      _receivedContexts.clear();
      final param = DataHandle('ctx_probe');
      LfIo.writeJson(param, {'k': 'v'});
      param.position = 0;
      Framework.p2pnameNotify(kP2PName, param);
      param.dispose();

      for (int i = 0; i < 60; i++) {
        if (_receivedContexts.isNotEmpty) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }

      expect(_receivedContexts.isNotEmpty, isTrue,
          reason: 'CallContext was not delivered to the notify callback');

      final ctx = _receivedContexts.last;
      expect(ctx.payload.length, greaterThan(0));
    });

    test('v2 senderUid: 32-byte payload (or skipped on v1 bridge)', () async {
      await _ensureOneContext();

      if (_receivedContexts.isEmpty) {
        return;
      }
      final ctx = _receivedContexts.last;

      if (ctx.senderUid.isEmpty) {
        return;
      }

      expect(ctx.senderUid.length, equals(32),
          reason: 'bridge v2 must deliver exactly 32 bytes of senderUid');
    });

    test('v2 senderP2PName: equals caller LF_P2P_name', () async {
      await _ensureOneContext();

      if (_receivedContexts.isEmpty) {
        return;
      }
      final ctx = _receivedContexts.last;

      if (ctx.senderUid.isEmpty) {
        return;
      }

      expect(ctx.senderP2PName, equals(kP2PName),
          reason: 'senderP2PName must match the caller P2P group');
    });
  });
}

Future<void> _ensureOneContext() async {
  if (_receivedContexts.isNotEmpty) return;

  final param = DataHandle('ctx_probe');
  LfIo.writeJson(param, {'warm': true});
  param.position = 0;
  Framework.p2pnameNotify(kP2PName, param);
  param.dispose();

  for (int i = 0; i < 60; i++) {
    if (_receivedContexts.isNotEmpty) break;
    await Future.delayed(const Duration(milliseconds: 50));
  }
}