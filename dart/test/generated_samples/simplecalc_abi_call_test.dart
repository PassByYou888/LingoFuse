import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';
import 'simplecalc_abi_call.dart' as abi;

const String kServerAddr = '127.0.0.1:9898';
const String kClientApp = 'simplecalc_client_test';
const String kServiceP2PName = 'simplecalc_service_test_p2p';

int gPass = 0;
int gFail = 0;
int gSkip = 0;
bool gServiceCalledMe = false;
Uint8List gServiceUid = Uint8List(32);
String gServiceP2P = '';
Uint8List gClientUid = Uint8List(32);
String gClientP2P = '';

void reportPass(String label, [String? detail]) {
  stdout.writeln('[PASS] ' + label + (detail != null ? ' = ' + detail : ''));
  gPass++;
}

void reportFail(String label, String reason) {
  stdout.writeln('[FAIL] ' + label + ' -- ' + reason);
  gFail++;
}

void reportSkip(String label, String reason) {
  stdout.writeln('[SKIP] ' + label + ' -- ' + reason);
  gSkip++;
}

String uidPrefixHex(Uint8List uid) {
  if (uid.isEmpty) return '';
  final n = uid.length < 8 ? uid.length : 8;
  final sb = StringBuffer();
  for (int i = 0; i < n; i++) {
    sb.write(uid[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

bool uidIsNonZero(Uint8List uid) {
  for (final b in uid) {
    if (b != 0) return true;
  }
  return false;
}

Uint8List cbReportIdentity(CallContext ctx) {
  gServiceCalledMe = true;
  gServiceUid = Uint8List.fromList(ctx.senderUid);
  gServiceP2P = ctx.senderP2PName;
  final w = AbiWriter();
  w.writeUInt8(0x00);
  w.writeString('identity received');
  return w.takeBytes();
}

Future<void> main() async {
  await BridgeHost.start();
  Framework.setOptQuiet(true);
  Framework.setOptOverlapConnection(true);
  Framework.setOptWaitConnectionReadyOk(true);
  Framework.setOptWaitConnectionTimeout(15000);
  Framework.resetPrepare();

  final clientApp = AppHandle(kClientApp, 'client test app');
  clientApp.registerCall('LF_TEST_REPORT_SERVICE_IDENTITY',
      'report service identity', cbReportIdentity);

  final tag = Framework.prepareClient(kServerAddr, app: clientApp);
  if (tag < 0) {
    stderr.writeln('[FATAL] prepareClient returned ' + tag.toString());
    exit(1);
  }
  if (!Framework.prepareDone()) {
    stderr.writeln('[FATAL] prepareDone failed');
    exit(1);
  }
  stdout.writeln('[READY] client online');

  bool serviceVisible = false;
  for (int i = 0; i < 30; i++) {
    if (Framework.checkApi('SimpleCalc_abi', 'LF_TEST_WHOAMI')) {
      serviceVisible = true;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 200));
  }
  if (!serviceVisible) {
    stderr.writeln('[FATAL] service not visible after 6s');
    await shutdownAndExit(clientApp, 2);
    return;
  }
  stdout.writeln('[OK] service visible');

  await runAllTests();

  stdout.writeln('');
  stdout.writeln('=== Summary ===');
  stdout.writeln('Pass: ' + gPass.toString());
  stdout.writeln('Fail: ' + gFail.toString());
  stdout.writeln('Skip: ' + gSkip.toString());

  await shutdownAndExit(clientApp, gFail == 0 ? 0 : 2);
}

Future<void> shutdownAndExit(AppHandle clientApp, int code) async {
  try { Framework.exitMainThread(); } catch (_) {}
  try { clientApp.dispose(); } catch (_) {}
  try { Framework.shutdown(); } catch (_) {}
  try { BridgeHost.instance.stop(); } catch (_) {}
  exit(code);
}

Future<void> runAllTests() async {
  await testWhoAmI();
  await testAskCallMe();
  await testAdd();
  await testSub();
  await testMul();
  await testEcho();
  await testGetTs();
  await testP2PNameNotify();
}

Future<void> testWhoAmI() async {
  try {
    final result = await Isolate.run(() {
      final req = DataHandle('LF_TEST_WHOAMI');
      try {
        final w = AbiWriter();
        w.writeString('');
        req.writeBytes(w.takeBytes());
        req.position = 0;
        final resp = Framework.call('SimpleCalc_abi', req, timeoutMs: 10000);
        try {
          return resp.readAllBytes().toList();
        } finally {
          resp.dispose();
        }
      } finally {
        req.dispose();
      }
    });
    if (result.isEmpty) {
      reportFail('whoami', 'empty response');
      return;
    }
    final r = AbiReader(Uint8List.fromList(result));
    if (r.readUInt8() != 0x00) {
      reportFail('whoami', 'status != OK');
      return;
    }
    gClientUid = Uint8List.fromList(r.readBytes(32));
    gClientP2P = r.readString();
    if (uidIsNonZero(gClientUid)) {
      final p2pText = gClientP2P.isEmpty ? '(empty)' : gClientP2P;
      reportPass('whoami',
          'client uid=' + uidPrefixHex(gClientUid) + '... p2p=' + p2pText);
    } else {
      reportFail('whoami', 'client UID is all-zero');
    }
  } catch (e) {
    reportFail('whoami', e.toString());
  }
}

Future<void> testAskCallMe() async {
  if (!uidIsNonZero(gClientUid)) {
    reportSkip('ask_call_me', 'no client UID');
    return;
  }
  gServiceCalledMe = false;
  gServiceUid = Uint8List(32);
  gServiceP2P = '';

  final req = DataHandle('LF_TEST_ASK_SERVICE_CALL_ME');
  try {
    final w = AbiWriter();
    w.writeString('go');
    req.writeBytes(w.takeBytes());
    req.position = 0;
    Framework.notify('SimpleCalc_abi', req);
  } finally {
    req.dispose();
  }

  for (int i = 0; i < 200; i++) {
    if (gServiceCalledMe) break;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  if (!gServiceCalledMe) {
    reportFail('ask_call_me', 'service did not call back within 10s');
    return;
  }
  if (uidIsNonZero(gServiceUid)) {
    final p2pText = gServiceP2P.isEmpty ? '(empty)' : gServiceP2P;
    reportPass('ask_call_me',
        'service uid=' + uidPrefixHex(gServiceUid) + '... p2p=' + p2pText);
  } else {
    reportFail('ask_call_me', 'service UID is all-zero');
  }
}

Future<void> testAdd() async {
  try {
    final v = await abi.add(7, 35);
    if (v == 42) {
      reportPass('add(7,35)', v.toString());
    } else {
      reportFail('add(7,35)', 'expected 42 got ' + v.toString());
    }
  } catch (e) {
    reportFail('add(7,35)', e.toString());
  }

  if (uidIsNonZero(gServiceUid)) {
    try {
      final v = await abi.addByUid(gServiceUid, 7, 35);
      if (v == 42) {
        reportPass('addByUid(7,35)', v.toString());
      } else {
        reportFail('addByUid(7,35)', 'expected 42 got ' + v.toString());
      }
    } catch (e) {
      reportFail('addByUid(7,35)', e.toString());
    }
  } else {
    reportSkip('addByUid', 'no service UID');
  }

  try {
    final v = await abi.addByP2PName(kServiceP2PName, 7, 35);
    if (v == 42) {
      reportPass('addByP2PName(7,35)', v.toString());
    } else {
      reportFail('addByP2PName(7,35)', 'expected 42 got ' + v.toString());
    }
  } catch (e) {
    reportFail('addByP2PName(7,35)', e.toString());
  }
}

Future<void> testSub() async {
  try {
    final v = await abi.sub(100, 23);
    if (v == 77) {
      reportPass('sub(100,23)', v.toString());
    } else {
      reportFail('sub(100,23)', 'expected 77 got ' + v.toString());
    }
  } catch (e) {
    reportFail('sub(100,23)', e.toString());
  }

  if (uidIsNonZero(gServiceUid)) {
    try {
      final v = await abi.subByUid(gServiceUid, 100, 23);
      if (v == 77) {
        reportPass('subByUid(100,23)', v.toString());
      } else {
        reportFail('subByUid(100,23)', 'expected 77 got ' + v.toString());
      }
    } catch (e) {
      reportFail('subByUid(100,23)', e.toString());
    }
  } else {
    reportSkip('subByUid', 'no service UID');
  }

  try {
    final v = await abi.subByP2PName(kServiceP2PName, 100, 23);
    if (v == 77) {
      reportPass('subByP2PName(100,23)', v.toString());
    } else {
      reportFail('subByP2PName(100,23)', 'expected 77 got ' + v.toString());
    }
  } catch (e) {
    reportFail('subByP2PName(100,23)', e.toString());
  }
}

Future<void> testMul() async {
  try {
    final v = await abi.mul(12, 12);
    if (v == 144) {
      reportPass('mul(12,12)', v.toString());
    } else {
      reportFail('mul(12,12)', 'expected 144 got ' + v.toString());
    }
  } catch (e) {
    reportFail('mul(12,12)', e.toString());
  }

  if (uidIsNonZero(gServiceUid)) {
    try {
      final v = await abi.mulByUid(gServiceUid, 12, 12);
      if (v == 144) {
        reportPass('mulByUid(12,12)', v.toString());
      } else {
        reportFail('mulByUid(12,12)', 'expected 144 got ' + v.toString());
      }
    } catch (e) {
      reportFail('mulByUid(12,12)', e.toString());
    }
  } else {
    reportSkip('mulByUid', 'no service UID');
  }

  try {
    final v = await abi.mulByP2PName(kServiceP2PName, 12, 12);
    if (v == 144) {
      reportPass('mulByP2PName(12,12)', v.toString());
    } else {
      reportFail('mulByP2PName(12,12)', 'expected 144 got ' + v.toString());
    }
  } catch (e) {
    reportFail('mulByP2PName(12,12)', e.toString());
  }
}

Future<void> testEcho() async {
  try {
    final v = await abi.echo('hello');
    if (v == 'hello') {
      reportPass('echo', v);
    } else {
      reportFail('echo', 'expected hello got ' + v);
    }
  } catch (e) {
    reportFail('echo', e.toString());
  }

  if (uidIsNonZero(gServiceUid)) {
    try {
      final v = await abi.echoByUid(gServiceUid, 'world');
      if (v == 'world') {
        reportPass('echoByUid', v);
      } else {
        reportFail('echoByUid', 'expected world got ' + v);
      }
    } catch (e) {
      reportFail('echoByUid', e.toString());
    }
  } else {
    reportSkip('echoByUid', 'no service UID');
  }

  try {
    final v = await abi.echoByP2PName(kServiceP2PName, 'utf8:你好');
    if (v == 'utf8:你好') {
      reportPass('echoByP2PName', v);
    } else {
      reportFail('echoByP2PName', 'got ' + v);
    }
  } catch (e) {
    reportFail('echoByP2PName', e.toString());
  }
}

Future<void> testGetTs() async {
  try {
    final v = await abi.get_ts();
    if (v > 1600000000) {
      reportPass('get_ts', v.toString());
    } else {
      reportFail('get_ts', 'implausible ts: ' + v.toString());
    }
  } catch (e) {
    reportFail('get_ts', e.toString());
  }

  if (uidIsNonZero(gServiceUid)) {
    try {
      final v = await abi.get_tsByUid(gServiceUid);
      if (v > 1600000000) {
        reportPass('get_tsByUid', v.toString());
      } else {
        reportFail('get_tsByUid', 'implausible ts: ' + v.toString());
      }
    } catch (e) {
      reportFail('get_tsByUid', e.toString());
    }
  } else {
    reportSkip('get_tsByUid', 'no service UID');
  }

  try {
    final v = await abi.get_tsByP2PName(kServiceP2PName);
    if (v > 1600000000) {
      reportPass('get_tsByP2PName', v.toString());
    } else {
      reportFail('get_tsByP2PName', 'implausible ts: ' + v.toString());
    }
  } catch (e) {
    reportFail('get_tsByP2PName', e.toString());
  }
}

Future<void> testP2PNameNotify() async {
  abi.logNotifyByP2PName(kServiceP2PName, 'notify-by-p2pname');
  await Future.delayed(const Duration(milliseconds: 300));
  reportPass('logNotifyByP2PName', 'dispatched');
}