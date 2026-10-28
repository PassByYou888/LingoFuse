import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

const String DEFAULT_APP_NAME = 'SimpleCalc_abi';
const String DEFAULT_APP_DESC = 'ABI service for SimpleCalc';

const int STATUS_OK = 0x00;
const int STATUS_ERROR = 0xFF;

Uint8List callback_add(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final a = r.readInt64();
  final b = r.readInt64();
  final w = AbiWriter();
  try {
    final ret = internal_call_add(a, b);
    w.writeUInt8(STATUS_OK);
    w.writeInt64(ret);
  } catch (e) {
    w.writeUInt8(STATUS_ERROR);
    w.writeString(e.toString());
  }
  return w.takeBytes();
}

Uint8List callback_sub(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final a = r.readInt64();
  final b = r.readInt64();
  final w = AbiWriter();
  try {
    final ret = internal_call_sub(a, b);
    w.writeUInt8(STATUS_OK);
    w.writeInt64(ret);
  } catch (e) {
    w.writeUInt8(STATUS_ERROR);
    w.writeString(e.toString());
  }
  return w.takeBytes();
}

Uint8List callback_mul(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final a = r.readInt64();
  final b = r.readInt64();
  final w = AbiWriter();
  try {
    final ret = internal_call_mul(a, b);
    w.writeUInt8(STATUS_OK);
    w.writeInt64(ret);
  } catch (e) {
    w.writeUInt8(STATUS_ERROR);
    w.writeString(e.toString());
  }
  return w.takeBytes();
}

Uint8List callback_echo(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final s = r.readString();
  final w = AbiWriter();
  try {
    final ret = internal_call_echo(s);
    w.writeUInt8(STATUS_OK);
    w.writeString(ret);
  } catch (e) {
    w.writeUInt8(STATUS_ERROR);
    w.writeString(e.toString());
  }
  return w.takeBytes();
}

Uint8List callback_get_ts(CallContext ctx) {
  final w = AbiWriter();
  try {
    final ret = internal_call_get_ts();
    w.writeUInt8(STATUS_OK);
    w.writeInt64(ret);
  } catch (e) {
    w.writeUInt8(STATUS_ERROR);
    w.writeString(e.toString());
  }
  return w.takeBytes();
}

void callback_log(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final s = r.readString();
  internal_call_log(s);
}

int internal_call_add(int a, int b) {
  throw UnimplementedError('internal_call_add');
}

int internal_call_sub(int a, int b) {
  throw UnimplementedError('internal_call_sub');
}

int internal_call_mul(int a, int b) {
  throw UnimplementedError('internal_call_mul');
}

String internal_call_echo(String s) {
  throw UnimplementedError('internal_call_echo');
}

int internal_call_get_ts() {
  throw UnimplementedError('internal_call_get_ts');
}

void internal_call_log(String s) {
  if (s.isEmpty) {
    return;
  }
}

void register_all_abi_apis(AppHandle app) {
  app.registerCall('add', 'add two int64', callback_add);
  app.registerCall('sub', 'sub two int64', callback_sub);
  app.registerCall('mul', 'mul two int64', callback_mul);
  app.registerCall('echo', 'echo a string', callback_echo);
  app.registerCall('get_ts', 'get unix timestamp', callback_get_ts);
  app.registerNotify('log', 'log a string', callback_log);
}

void register_all_p2p_abi_apis() {
  BridgeHost.instance.registerP2PCall('add', 'add two int64', callback_add);
  BridgeHost.instance.registerP2PCall('sub', 'sub two int64', callback_sub);
  BridgeHost.instance.registerP2PCall('mul', 'mul two int64', callback_mul);
  BridgeHost.instance.registerP2PCall('echo', 'echo a string', callback_echo);
  BridgeHost.instance.registerP2PCall(
      'get_ts', 'get unix timestamp', callback_get_ts);
  BridgeHost.instance.registerP2PNotify('log', 'log a string', callback_log);
}

AppHandle create_and_register_abi_app() {
  final app = AppHandle(DEFAULT_APP_NAME, DEFAULT_APP_DESC);
  register_all_abi_apis(app);
  return app;
}