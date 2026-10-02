// Integration tests: Framework + AppHandle + C bridge + E2E.
//
// This file manages the complete LingoFuse lifecycle. It MUST be the
// only test file that starts the framework; run with concurrency=1
// (enforced by dart_test.yaml).

import 'dart:isolate';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Shared state for the whole file
// ---------------------------------------------------------------------------

const String kAppName = 'DartTestServer';
const String kEndpoint = 'ipc:dart_test_server';

late AppHandle _app;
int _logCallCount = 0;

void main() {
  // -----------------------------------------------------------------------
  // Setup / teardown for the entire test file
  // -----------------------------------------------------------------------
  setUpAll(() async {
    // 1. Start the C bridge host.
    await BridgeHost.start();

    // 2. Configure the framework for fast startup.
    Framework.setOption('Quiet', 'True');
    Framework.setOption('Wait_Connection_ReadyOk', 'False');
    Framework.setOption('Overlap_Connection', 'True');
    Framework.setOption('Wait_Connection_Timeout', '5000');
    Framework.resetPrepare();

    // 3. Create the app and register the test APIs.
    _app = AppHandle(kAppName, 'Dart server test suite');

    _app.registerCall('echo', 'Echo the payload', (Uint8List input) {
      return input;
    });

    _app.registerCall('add', 'Add two int32 values (little-endian)', (
      Uint8List input,
    ) {
      final bd = ByteData.sublistView(input);
      final a = bd.getInt32(0, Endian.little);
      final b = bd.getInt32(4, Endian.little);
      final out = ByteData(4)..setInt32(0, a + b, Endian.little);
      return out.buffer.asUint8List();
    });

    _app.registerNotify('log', 'Increment a server-side counter', (
      Uint8List input,
    ) {
      _logCallCount++;
    });

    // 4. Prepare the service and the client that exposes the app.
    Framework.prepareService(kEndpoint, kEndpoint);
    Framework.prepareClient(kEndpoint, app: _app);
    final started = Framework.prepareDone();
    if (!started) {
      throw StateError('Framework failed to start');
    }

    // 5. Wait until the app becomes visible on the mesh.
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

  // -----------------------------------------------------------------------
  // Group 1: framework health
  // -----------------------------------------------------------------------
  group('framework health', () {
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

  // -----------------------------------------------------------------------
  // Group 2: remote calls from a child isolate
  //
  // Remote calls block the calling isolate. To avoid deadlocking the
  // main isolate (which also runs the bridge callback loop), every
  // remote call is issued from a short-lived child isolate.
  // -----------------------------------------------------------------------
  group('remote calls', () {
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

  // -----------------------------------------------------------------------
  // Group 3: notify
  // -----------------------------------------------------------------------
  group('remote notify', () {
    test('notify to a registered API reaches the callback', () async {
      final before = _logCallCount;
      final param = DataHandle('log');
      LfIo.writeJson(param, {'msg': 'hello'});
      param.position = 0;
      Framework.notify(kAppName, param);
      param.dispose();

      // Give the callback a moment to run on the bridge loop.
      for (int i = 0; i < 20; i++) {
        if (_logCallCount > before) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
      expect(_logCallCount, greaterThan(before));
    });
  });
}

// ---------------------------------------------------------------------------
// Child isolate entry points
//
// Each function loads the LingoFuse package in a fresh isolate, performs
// a synchronous LF_Call, and returns a serialisable result.
// ---------------------------------------------------------------------------

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
  final result = ByteData.sublistView(resp.readBytes(4)).getInt32(0, Endian.little);
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