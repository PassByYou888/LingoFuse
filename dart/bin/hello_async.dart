// bin/hello_async.dart
//
// A tutorial demo of the modern async API of the LingoFuse Dart
// binding. The goal is to show, at a glance, what "callback-first"
// business code looks like when you write it against LingoFuse.
//
// The demo runs both the service and the client in a single Dart
// process, so it can be executed with a single command:
//
//     dart run bin/hello_async.dart
//
// ---------------------------------------------------------------------------
// WHY P2PNAME ADDRESSING
// ---------------------------------------------------------------------------
// App-name and UID routing are local-first. When the caller process
// itself hosts a matching App or client, an async call is dispatched
// synchronously on the caller's own OS thread. From the Dart main
// isolate this deadlocks: the dispatch thread blocks waiting for the
// Dart event loop, which is itself blocked in the dispatch call.
//
// P2PName routing is NOT local-first. Every P2PName call is forwarded
// to the server dispatcher, which runs on an independent native
// thread. That thread can safely block on the Protocol A handshake
// while the Dart main isolate remains free to process callbacks.
//
// This is why the demo uses P2PNameTarget exclusively.
//
// ---------------------------------------------------------------------------
// THE ERLANG FEEL
// ---------------------------------------------------------------------------
// In Erlang, a request looks like:
//
//     Pid ! {call, add, {1, 2}},
//     receive
//         {result, Value} -> io:format("sum = ~p~n", [Value]);
//         {error, Reason} -> io:format("error: ~p~n", [Reason])
//     end.
//
// In Dart with this binding, the same intent looks like:
//
//     client.callAsync('add', {'a': 1, 'b': 2}, (result, error) {
//         if (error != null) {
//             print('error: $error');
//             return;
//         }
//         print('sum = ${decodeJson(result)['sum']}');
//     });
//
// No await/async seam. No Future chaining. The business logic lives
// directly in the callback body. That is the entire point of the
// async API design.
//
// All output is in English.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

// ===========================================================================
// Configuration
// ===========================================================================

const String kAppName = 'HelloAsync';
const String kGroupName = 'hello_async_group';
const String kEndpoint = 'ipc:hello_async';

/// Waiting time, in milliseconds, for the P2PName to propagate from
/// the client's Update_UID report to the server's broadcast.
///
/// The propagation is two hops (client -> server -> broadcast), each
/// driven by the C4 network layer. On a warm local mesh it completes
/// in well under a second; on a cold machine 2000ms is a safe margin.
const int kP2PNamePropagationMs = 2000;

// ===========================================================================
// Server-side business logic
// ===========================================================================

/// `add(a, b)` -> `{ "sum": a + b }`
Uint8List serverAdd(Uint8List input) {
  final req = decodeJsonPayload(input) as Map<String, dynamic>;
  final a = (req['a'] as num).toInt();
  final b = (req['b'] as num).toInt();
  return encodeJsonPayload({'sum': a + b});
}

/// `greet(name)` -> `{ "greeting": "Hello, <name>!" }`
Uint8List serverGreet(Uint8List input) {
  final req = decodeJsonPayload(input) as Map<String, dynamic>;
  final name = req['name'] as String;
  return encodeJsonPayload({'greeting': 'Hello, $name!'});
}

/// `getUser(id)` -> `{ "id": id, "name": "...", "email": "..." }`
///
/// A small mock user directory used by the nested-call demo.
Uint8List serverGetUser(Uint8List input) {
  final req = decodeJsonPayload(input) as Map<String, dynamic>;
  final id = (req['id'] as num).toInt();

  const users = <int, Map<String, String>>{
    1: {'name': 'Alice', 'email': 'alice@example.com'},
    2: {'name': 'Bob', 'email': 'bob@example.com'},
    3: {'name': 'Carol', 'email': 'carol@example.com'},
  };

  final user = users[id];
  if (user == null) {
    return encodeJsonPayload({'error': 'user $id not found'});
  }
  return encodeJsonPayload({
    'id': id,
    'name': user['name']!,
    'email': user['email']!,
  });
}

/// `slow(ms)` -> sleeps for `ms` then returns `{ "slept": ms }`.
///
/// Used by the timeout demo. The handler sleeps on the native worker
/// thread, which is legal: LingoFuse handlers are allowed to run for
/// as long as they like, though it is worth remembering that they
/// occupy a worker thread while they do so.
Uint8List serverSlow(Uint8List input) {
  final req = decodeJsonPayload(input) as Map<String, dynamic>;
  final ms = (req['ms'] as num).toInt();

  // Synchronous sleep on the worker thread.
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    // Busy-wait. A production handler would use a proper blocking
    // primitive; the point here is to guarantee a delay without
    // yielding to the Dart event loop, so that the client really does
    // observe a timeout.
  }

  return encodeJsonPayload({'slept': ms});
}

// ===========================================================================
// JSON payload helpers
// ===========================================================================
//
// LingoFuse frames every string with a trailing NUL byte. When a
// server-side handler echoes the raw bytes it received, the response
// carries that NUL. These helpers hide the framing so that the demo
// reads as plain business code.

/// Decodes a JSON payload from raw bytes, stripping the trailing NUL
/// that LingoFuse appends.
Object? decodeJsonPayload(Uint8List bytes) {
  final nulIndex = bytes.indexOf(0);
  final payload = nulIndex >= 0
      ? Uint8List.sublistView(bytes, 0, nulIndex)
      : bytes;
  if (payload.isEmpty) return null;
  return jsonDecode(utf8.decode(payload));
}

/// Encodes a value as UTF-8 JSON bytes. The framing NUL is appended by
/// the framework's write path; this helper only produces the JSON
/// bytes.
Uint8List encodeJsonPayload(Object? value) {
  return Uint8List.fromList(utf8.encode(jsonEncode(value)));
}

/// Convenience: decodes a `callAsync` result that is expected to be a
/// JSON object.
Map<String, dynamic> decodeJsonResult(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    throw StateError('empty response');
  }
  final decoded = decodeJsonPayload(bytes);
  if (decoded is! Map<String, dynamic>) {
    throw StateError(
        'expected a JSON object, got ${decoded.runtimeType}: $decoded');
  }
  return decoded;
}

// ===========================================================================
// Main
// ===========================================================================

Future<void> main() async {
  print('=== Hello, Async ===\n');

  // -----------------------------------------------------------------
  // Boot
  // -----------------------------------------------------------------
  print('[boot] starting BridgeHost...');
  await BridgeHost.start();

  print('[boot] declaring P2P group "$kGroupName"...');
  Framework.setOptP2PName(kGroupName);

  print('[boot] creating AppHandle and registering APIs...');
  final app = AppHandle(kAppName, 'Hello Async demo');
  app.registerCall('add', 'Add two integers', serverAdd);
  app.registerCall('greet', 'Greet a name', serverGreet);
  app.registerCall('getUser', 'Look up a user by id', serverGetUser);
  app.registerCall('slow', 'Sleep for a given number of milliseconds', serverSlow);

  print('[boot] starting framework on "$kEndpoint"...');
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Overlap_Connection', 'True');
  Framework.resetPrepare();
  Framework.prepareService(kEndpoint, kEndpoint);
  Framework.prepareClient(kEndpoint, app: app);
  Framework.prepareDone();

  print('[boot] waiting for the mesh to converge...');
  for (int i = 0; i < 30; i++) {
    if (Framework.checkApp(kAppName)) break;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  await Future.delayed(const Duration(milliseconds: kP2PNamePropagationMs));

  final client = P2PNameTarget(kGroupName);
  print('[boot] ready; client = ${client.describe()}\n');

  // =================================================================
  // 1. Erlang feel: a bare callback with business code inside it
  // =================================================================
  print('[1] Erlang feel: client.callAsync(api, payload, (result, error) { ... })');
  print('    The business code lives directly in the callback body.');
  print('');

  // Wait for the first callback to fire so that the demo prints in
  // order.
  final firstDone = Completer<void>();
  client.callAsync(
    'greet',
    {'name': 'World'},
    (result, error) {
      if (error != null) {
        print('    [error] $error');
        if (!firstDone.isCompleted) firstDone.complete();
        return;
      }
      final reply = decodeJsonResult(result);
      print('    [reply] greeting = ${reply['greeting']}');
      if (!firstDone.isCompleted) firstDone.complete();
    },
  );
  await firstDone.future;
  print('');

  // =================================================================
  // 2. Promise style: await the future
  // =================================================================
  print('[2] Promise style: await client.callJson<Map>(...).future');
  print('');

  {
    final reply = await client
        .callJson<Map<String, dynamic>>(
          'add',
          payload: {'a': 17, 'b': 25},
          timeoutMs: 5000,
        )
        .future;
    print('    [reply] ${reply['sum']}');
  }
  print('');

  // =================================================================
  // 3. Nested call: a callback fires another call
  // =================================================================
  print('[3] Nested call: inside the getUser callback, call greet(user.name)');
  print('');

  final nestedDone = Completer<void>();
  client.callAsync(
    'getUser',
    {'id': 2},
    (result, error) {
      if (error != null) {
        print('    [error] getUser: $error');
        if (!nestedDone.isCompleted) nestedDone.complete();
        return;
      }
      final user = decodeJsonResult(result);
      print('    [getUser] id=${user['id']} name=${user['name']}');

      // Fire the second call from inside the first callback. This is
      // the pattern that makes async code feel natural: the business
      // logic for step 2 lives right next to the code for step 1.
      client.callAsync(
        'greet',
        {'name': user['name']},
        (result2, error2) {
          if (error2 != null) {
            print('    [error] greet: $error2');
            if (!nestedDone.isCompleted) nestedDone.complete();
            return;
          }
          final greeting = decodeJsonResult(result2);
          print('    [greet]    ${greeting['greeting']}');
          if (!nestedDone.isCompleted) nestedDone.complete();
        },
      );
    },
  );
  await nestedDone.future;
  print('');

  // =================================================================
  // 4. Timeout: the abandoned path
  // =================================================================
  print('[4] Timeout: a 1.5s budget against a 3s handler');
  print('');

  try {
    await client
        .callJson<Map<String, dynamic>>(
          'slow',
          payload: {'ms': 3000},
          timeoutMs: 1500,
        )
        .future;
    print('    [unexpected] the call resolved; a longer timeout would be needed');
  } on TimeoutException catch (e) {
    final msg = e.message;
    final short = (msg == null || msg.isEmpty)
        ? 'the call was abandoned after timeout'
        : msg.split('.').first;
    print('    [timeout] $short.');
  } catch (e) {
    print('    [error] $e');
  }
  print('');

  // =================================================================
  // 5. Error path: a handler-level error
  // =================================================================
  print('[5] Error path: getUser(999) returns a JSON error');
  print('');

  {
    final reply = await client
        .callJson<Map<String, dynamic>>(
          'getUser',
          payload: {'id': 999},
          timeoutMs: 5000,
        )
        .future;
    if (reply.containsKey('error')) {
      print('    [server-error] ${reply['error']}');
    } else {
      print('    [reply] $reply');
    }
  }
  print('');

  // =================================================================
  // Cleanup
  // =================================================================
  print('[cleanup] stopping the framework...');
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();

  print('\n=== done ===');
}