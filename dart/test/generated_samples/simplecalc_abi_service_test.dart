import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';

const String kListenAddr = '0.0.0.0';
const String kAdvertAddr = '127.0.0.1:9898';
const String kClientAddr = '127.0.0.1:9898';
const String kP2PName = 'simplecalc_service_test_p2p';
const String kAppName = 'SimpleCalc_abi';
const String kAppDesc = 'ABI service for SimpleCalc';
const String kLogFileDefault = 'simplecalc_service.log';
const String kSentinelDefault = 'simplecalc_service.exit';

const int STATUS_OK = 0x00;

late File gLogFile;
bool gRunning = true;
AppHandle? gApp;

void logLine(String s) {
  stdout.writeln(s);
  try {
    gLogFile.writeAsStringSync(s + '\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

Uint8List cbWhoAmI(CallContext ctx) {
  final w = AbiWriter();
  w.writeUInt8(STATUS_OK);
  w.writeBytes(ctx.senderUid);
  w.writeString(ctx.senderP2PName);
  return w.takeBytes();
}

void cbAskServiceCallMe(CallContext ctx) {
  if (ctx.senderUid.length != 32) {
    logLine('[SERVICE] ask_call_me: invalid sender UID');
    return;
  }
  final req = DataHandle('LF_TEST_REPORT_SERVICE_IDENTITY');
  try {
    final w = AbiWriter();
    w.writeString('service initiates call');
    req.writeBytes(w.takeBytes());
    req.position = 0;
    final uid = Uint8List.fromList(ctx.senderUid);
    Framework.uidCallAsync(uid, req, (result, error) {
      if (error != null) {
        logLine('[SERVICE] ask_call_me: error = ' + error);
        return;
      }
      logLine('[SERVICE] ask_call_me: client responded');
    });
  } finally {
    req.dispose();
  }
}

Uint8List cbAdd(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final a = r.readInt64();
  final b = r.readInt64();
  final w = AbiWriter();
  w.writeUInt8(STATUS_OK);
  w.writeInt64(a + b);
  return w.takeBytes();
}

Uint8List cbSub(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final a = r.readInt64();
  final b = r.readInt64();
  final w = AbiWriter();
  w.writeUInt8(STATUS_OK);
  w.writeInt64(a - b);
  return w.takeBytes();
}

Uint8List cbMul(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final a = r.readInt64();
  final b = r.readInt64();
  final w = AbiWriter();
  w.writeUInt8(STATUS_OK);
  w.writeInt64(a * b);
  return w.takeBytes();
}

Uint8List cbEcho(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final s = r.readString();
  final w = AbiWriter();
  w.writeUInt8(STATUS_OK);
  w.writeString(s);
  return w.takeBytes();
}

Uint8List cbGetTs(CallContext ctx) {
  final w = AbiWriter();
  w.writeUInt8(STATUS_OK);
  w.writeInt64(DateTime.now().millisecondsSinceEpoch ~/ 1000);
  return w.takeBytes();
}

void cbLog(CallContext ctx) {
  final r = AbiReader(ctx.payload);
  final s = r.readString();
  logLine('[SERVICE-LOG] ' + s);
}

void registerCallApis(AppHandle app) {
  app.registerCall('add', 'add two int64', cbAdd);
  app.registerCall('sub', 'sub two int64', cbSub);
  app.registerCall('mul', 'mul two int64', cbMul);
  app.registerCall('echo', 'echo a string', cbEcho);
  app.registerCall('get_ts', 'get unix timestamp', cbGetTs);
  app.registerCall('LF_TEST_WHOAMI', 'service whoami', cbWhoAmI);
  app.registerNotify('log', 'log a string', cbLog);
  app.registerNotify('LF_TEST_ASK_SERVICE_CALL_ME',
      'service callback client', cbAskServiceCallMe);
}

void registerP2PApis() {
  final h = BridgeHost.instance;
  h.registerP2PCall('add', 'add two int64', cbAdd);
  h.registerP2PCall('sub', 'sub two int64', cbSub);
  h.registerP2PCall('mul', 'mul two int64', cbMul);
  h.registerP2PCall('echo', 'echo a string', cbEcho);
  h.registerP2PCall('get_ts', 'get unix timestamp', cbGetTs);
  h.registerP2PCall('LF_TEST_WHOAMI', 'service whoami', cbWhoAmI);
  h.registerP2PNotify('log', 'log a string', cbLog);
  h.registerP2PNotify('LF_TEST_ASK_SERVICE_CALL_ME',
      'service callback client', cbAskServiceCallMe);
}

Future<void> waitForExit(String sentinelPath) async {
  final f = File(sentinelPath);
  while (gRunning) {
    await Future.delayed(const Duration(milliseconds: 100));
    if (f.existsSync()) {
      logLine('[SENTINEL] exit requested');
      gRunning = false;
    }
  }
}

Future<void> main(List<String> args) async {
  final logPath = args.isNotEmpty ? args[0] : kLogFileDefault;
  final sentinelPath = args.length > 1 ? args[1] : kSentinelDefault;
  gLogFile = File(logPath);
  try {
    gLogFile.writeAsStringSync('', flush: true);
  } catch (_) {}

  ProcessSignal.sigint.watch().listen((_) {
    logLine('[SIGNAL] SIGINT');
    gRunning = false;
  });

  try {
    await BridgeHost.start();
    Framework.setOptQuiet(true);
    Framework.setOptOverlapConnection(true);
    Framework.setOptWaitConnectionReadyOk(true);
    Framework.setOptWaitConnectionTimeout(15000);
    Framework.setOptP2PName(kP2PName);
    Framework.resetPrepare();

    gApp = AppHandle(kAppName, kAppDesc);
    registerCallApis(gApp!);
    registerP2PApis();

    final tag = Framework.prepareService(kListenAddr, kAdvertAddr);
    if (tag < 0) {
      logLine('[FATAL] prepareService returned ' + tag.toString());
      return;
    }
    final ctag = Framework.prepareClient(kClientAddr, app: gApp);
    if (ctag < 0) {
      logLine('[FATAL] prepareClient returned ' + ctag.toString());
      return;
    }
    if (!Framework.prepareDone()) {
      logLine('[FATAL] prepareDone failed');
      return;
    }

    logLine('[READY] service online');
    logLine('[INFO] app   = ' + kAppName);
    logLine('[INFO] addr  = ' + kAdvertAddr);
    logLine('[INFO] p2p   = ' + kP2PName);

    await waitForExit(sentinelPath);
  } catch (e, st) {
    logLine('[FATAL] ' + e.toString());
    logLine(st.toString());
  } finally {
    logLine('[SHUTDOWN]');
    try { Framework.exitMainThread(); } catch (_) {}
    if (gApp != null) {
      try { gApp!.dispose(); } catch (_) {}
      gApp = null;
    }
    try { Framework.shutdown(); } catch (_) {}
    try { BridgeHost.instance.stop(); } catch (_) {}
    exit(0);
  }
}