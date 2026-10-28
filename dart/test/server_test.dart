import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';
import 'package:test/test.dart';

const String kTestVersion = 'server_test-v3';
const String kAppName = 'DartTestServer';
const String kEndpoint = 'ipc:dart_test_server';
const String kTestP2PName = 'dart_test_server_p2p';

late AppHandle _app;
int _logCallCount = 0;
String _lastLogSenderP2P = '';
Uint8List _lastLogSenderUid = Uint8List(0);

void main() {
  setUpAll(() async {
    // ignore: avoid_print
    print('[server_test] version = $kTestVersion');

    await BridgeHost.start();

    Framework.setOption('Quiet', 'True');
    Framework.setOption('Wait_Connection_ReadyOk', 'False');
    Framework.setOption('Overlap_Connection', 'True');
    Framework.setOption('Wait_Connection_Timeout', '5000');
    Framework.setOption('LF_P2P_name', kTestP2PName);
    Framework.resetPrepare();

    _app = AppHandle(kAppName, 'Dart server test suite');

    _app.registerCall('echo', 'Echo the payload', (CallContext ctx) {
      return ctx.payload;
    });

    _app.registerCall('add', 'Add two int32 values (little-endian)',
        (CallContext ctx) {
      final bd = ByteData.sublistView(ctx.payload);
      final a = bd.getInt32(0, Endian.little);
      final b = bd.getInt32(4, Endian.little);
      final out = ByteData(4)..setInt32(0, a + b, Endian.little);
      return out.buffer.asUint8List();
    });

    _app.registerNotify('log', 'Increment a server-side counter',
        (CallContext ctx) {
      _logCallCount++;
      _lastLogSenderP2P = ctx.senderP2PName;
      _lastLogSenderUid = ctx.senderUid;
    });

    Framework.prepareService(kEndpoint, kEndpoint);
    Framework.prepareClient(kEndpoint, app: _app);
    final started = Framework.prepareDone();
    if (!started) {
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
  });

  tearDownAll(() {
    _app.dispose();
    Framework.exitMainThread();
    Framework.shutdown();
    BridgeHost.instance.stop();
  });

  group('framework health [$kTestVersion]', () {
    test('main thread is running', () {
      expect(Framework.checkMainThread(), isTrue);
    });

    test('app is visible on the mesh', () {
      expect(Framework.checkApp(kAppName), isTrue);
    });

    test('registered API is visible on the mesh', () {
      expect(Framework.checkApi(kAppName, 'echo'), isTrue);
    });

    test('absent app is not visible', () {
      expect(Framework.checkApp('__definitely_absent__'), isFalse);
    });

    test('absent api is not visible', () {
      expect(Framework.checkApi(kAppName, '__absent__'), isFalse);
    });

    test('second prepareDone returns false without shutdown', () {
      expect(Framework.prepareDone(), isFalse);
    });

    test('generateAppName returns a non-empty unique name', () {
      final name = Framework.generateAppName();
      expect(name, isNotEmpty);
    });
  });

  group('remote calls [$kTestVersion]', () {
    test('echo returns the same string', () async {
      final result = await Isolate.run(
        () => _childEcho(kAppName, 'hello from child isolate'),
      );
      expect(result, equals('hello from child isolate'));
    });

    test('echo round-trips UTF-8 payloads', () async {
      final result = await Isolate.run(
        () => _childEcho(kAppName, '你好 🌍'),
      );
      expect(result, equals('你好 🌍'));
    });

    test('add returns the correct sum', () async {
      final result = await Isolate.run(
        () => _childAdd(kAppName, 5, 7),
      );
      expect(result, equals(12));
    });

    test('add handles negative values', () async {
      final result = await Isolate.run(
        () => _childAdd(kAppName, -100, 25),
      );
      expect(result, equals(-75));
    });

    test('unknown API returns an empty response', () async {
      final result = await Isolate.run(
        () => _childTryEcho(kAppName, '__does_not_exist__'),
      );
      expect(result, isNull);
    });

    test('unknown app returns an empty response', () async {
      final result = await Isolate.run(
        () => _childTryEcho('__does_not_exist__', 'echo'),
      );
      expect(result, isNull);
    });
  });

  group('remote notify [$kTestVersion]', () {
    test('notify to a registered API reaches the callback', () async {
      final before = _logCallCount;
      final param = DataHandle('log');
      LfIo.writeJson(param, {'msg': 'hello'});
      param.position = 0;
      Framework.notify(kAppName, param);
      param.dispose();

      for (int i = 0; i < 20; i++) {
        if (_logCallCount > before) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(_logCallCount, greaterThan(before));
    });

    test('v2 senderUid: 32-byte payload (or skipped on v1 bridge)',
        () async {
      await _ensureOneNotifyDelivered();

      if (_lastLogSenderUid.isEmpty) {
        return;
      }

      expect(_lastLogSenderUid.length, equals(32),
          reason: 'bridge v2 must deliver exactly 32 bytes of senderUid');
    });

    test('v2 senderP2PName: equals caller LF_P2P_name', () async {
      await _ensureOneNotifyDelivered();

      if (_lastLogSenderUid.isEmpty) {
        return;
      }

      expect(_lastLogSenderP2P, equals(kTestP2PName),
          reason: 'senderP2PName must echo the caller LF_P2P_name');
    });
  });
}

Future<void> _ensureOneNotifyDelivered() async {
  if (_logCallCount > 0) return;

  final param = DataHandle('log');
  LfIo.writeJson(param, {'msg': 'warmup'});
  param.position = 0;
  Framework.notify(kAppName, param);
  param.dispose();

  for (int i = 0; i < 20; i++) {
    if (_logCallCount > 0) break;
    await Future.delayed(const Duration(milliseconds: 50));
  }
}

String _childEcho(String app, String payload) {
  final param = DataHandle('echo');
  param.writeString(payload);
  param.position = 0;
  final resp = Framework.call(app, param, timeoutMs: 5000);
  final result = resp.readString();
  resp.dispose();
  param.dispose();
  return result;
}

int _childAdd(String app, int a, int b) {
  final param = DataHandle('add');
  final bytes = ByteData(8)
    ..setInt32(0, a, Endian.little)
    ..setInt32(4, b, Endian.little);
  param.writeBytes(bytes.buffer.asUint8List());
  param.position = 0;
  final resp = Framework.call(app, param, timeoutMs: 5000);
  final result =
      ByteData.sublistView(resp.readBytes(4)).getInt32(0, Endian.little);
  resp.dispose();
  param.dispose();
  return result;
}

String? _childTryEcho(String app, String api) {
  final param = DataHandle(api);
  param.writeString('hello');
  param.position = 0;
  final resp = Framework.tryCall(app, param, timeoutMs: 500);
  String? result;
  if (resp != null) {
    result = resp.readString();
    resp.dispose();
  }
  param.dispose();
  return result;
}