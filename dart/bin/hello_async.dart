import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

const String kAppName = 'HelloAsync';
const String kGroupName = 'hello_async_group';
const String kEndpoint = 'ipc:hello_async';

const int kP2PNamePropagationMs = 2000;

Uint8List serverAdd(CallContext ctx) {
  final req = decodeJsonPayload(ctx.payload) as Map<String, dynamic>;
  final a = (req['a'] as num).toInt();
  final b = (req['b'] as num).toInt();
  return encodeJsonPayload({'sum': a + b});
}

Uint8List serverGreet(CallContext ctx) {
  final req = decodeJsonPayload(ctx.payload) as Map<String, dynamic>;
  final name = req['name'] as String;
  return encodeJsonPayload({'greeting': 'Hello, $name!'});
}

Uint8List serverGetUser(CallContext ctx) {
  final req = decodeJsonPayload(ctx.payload) as Map<String, dynamic>;
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

Uint8List serverSlow(CallContext ctx) {
  final req = decodeJsonPayload(ctx.payload) as Map<String, dynamic>;
  final ms = (req['ms'] as num).toInt();

  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
  }

  return encodeJsonPayload({'slept': ms});
}

Object? decodeJsonPayload(Uint8List bytes) {
  final nulIndex = bytes.indexOf(0);
  final payload = nulIndex >= 0
      ? Uint8List.sublistView(bytes, 0, nulIndex)
      : bytes;
  if (payload.isEmpty) return null;
  return jsonDecode(utf8.decode(payload));
}

Uint8List encodeJsonPayload(Object? value) {
  return Uint8List.fromList(utf8.encode(jsonEncode(value)));
}

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

Future<void> main() async {
  print('=== Hello, Async ===\n');

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

  print('[1] Erlang feel: client.callAsync(api, payload, (result, error) { ... })');
  print('    The business code lives directly in the callback body.');
  print('');

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

  print('[cleanup] stopping the framework...');
  app.dispose();
  Framework.exitMainThread();
  Framework.shutdown();
  BridgeHost.instance.stop();

  print('\n=== done ===');
}