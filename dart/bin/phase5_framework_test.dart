// Phase 5 probe: exercises the new Framework / Status / io APIs added
// in v2 WITHOUT starting a full LingoFuse framework.
//
// The probe deliberately does not call Framework.prepareDone() or
// BridgeHost.start(). It verifies three things that must hold in every
// environment:
//
//   1. TYPED OPTION SHORTCUTS. The `set` family works through the
//      legacy FFI path and is a silent no-op for unknown names. The
//      `get` family returns a safe fallback (false / 0 / "") when the
//      bridge is not started.
//
//   2. ARGUMENT VALIDATION IS BRIDGE-INDEPENDENT. A wrong-length UID
//      is rejected with RangeError BEFORE the bridge-precondition
//      check runs. This ordering matters: it lets callers detect
//      programming errors without having started the framework.
//
//   3. BRIDGE-ONLY METHODS FAIL CLEANLY. Every bridge-routed method
//      throws StateError with a message that tells the caller exactly
//      what to do ("Call \"await BridgeHost.start()\" first").
//
// Run:
//     dart run bin/phase5_framework_test.dart
//
// Requires LingoFuse64.dll to be loadable (for the legacy path) but
// does NOT require the framework to be running.
//
// All output is in English.

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

  bool throwsAs<T>(void Function() fn, String label) {
    try {
      fn();
    } catch (e) {
      if (e is T) return true;
      print('         $label threw ${e.runtimeType}: $e');
      return false;
    }
    print('         $label did not throw');
    return false;
  }

  print('=== Phase 5 framework probe ===\n');

  // -----------------------------------------------------------------
  // [1] Typed option shortcuts: set path
  // -----------------------------------------------------------------
  print('[1] Typed option setters (legacy FFI, must not throw)...');

  // The set family routes through the legacy FFI. LingoFuse64.dll is
  // loaded implicitly by getBindings() on first use. All setters are
  // silent no-ops for unknown names, but the canonical names here are
  // real ones.
  try {
    Framework.setOptQuiet(true);
    Framework.setOptShowThreadID(true);
    Framework.setOptConsoleOutput(true);
    Framework.setOptOverlapConnection(true);
    Framework.setOptWaitConnectionReadyOk(false);
    Framework.setOptWaitConnectionTimeout(5000);
    Framework.setOptIpcServThreadCount(8);
    Framework.setOptIpcServMaxQueueLength(1024);
    Framework.setOptIpcServMaxMsgSize(1048576);
    Framework.setOptFixedSequencedTime(30000);
    Framework.setOptP2PName('phase5_group');
    Framework.setOptDataHandleIdleTimeout(600000);
    Framework.setOptDataHandlePoolScanInterval(5000);
    Framework.setOptNoReponseCmdNullFlushThreshold(5000);
    Framework.setOptPassword('phase5_password');
    Framework.setOptDebug('noop');
    check('all 16 typed setters completed', true);
  } catch (e) {
    check('all 16 typed setters completed', false, '$e');
  }

  // -----------------------------------------------------------------
  // [2] Typed option getters: safe fallback when bridge is down
  // -----------------------------------------------------------------
  print('\n[2] Typed option getters (bridge not started)...');
  print('         (must return safe fallbacks, not throw)');

  // For each family, the goal is to verify that the getter returns
  // without throwing. The static return type is guaranteed by Dart's
  // type checker, so a runtime `is` check would be redundant. Values
  // are not asserted because they depend on process-global state.

  bool boolOk = true;
  try {
    Framework.getOptQuiet();
    Framework.getOptShowThreadID();
    Framework.getOptConsoleOutput();
    Framework.getOptOverlapConnection();
    Framework.getOptWaitConnectionReadyOk();
  } catch (e) {
    boolOk = false;
    print('         bool getter threw: $e');
  }
  check('bool getters returned without throwing', boolOk);

  bool intOk = true;
  try {
    Framework.getOptWaitConnectionTimeout();
    Framework.getOptIpcServThreadCount();
    Framework.getOptFixedSequencedTime();
    Framework.getOptDataHandleIdleTimeout();
    Framework.getOptNoReponseCmdNullFlushThreshold();
  } catch (e) {
    intOk = false;
    print('         int getter threw: $e');
  }
  check('int getters returned without throwing', intOk);

  bool strOk = true;
  try {
    Framework.getOptPassword();
    Framework.getOptP2PName();
    Framework.getOptDebug();
  } catch (e) {
    strOk = false;
    print('         string getter threw: $e');
  }
  check('string getters returned without throwing', strOk);

  // Generic getOption with bridge down must return "" rather than throw.
  try {
    final v = Framework.getOption('Quiet');
    check('Framework.getOption returns "" when bridge is down', v.isEmpty,
        'got "$v"');
  } catch (e) {
    check('Framework.getOption returns "" when bridge is down', false, '$e');
  }

  // -----------------------------------------------------------------
  // [3] UID argument validation (bridge-independent)
  // -----------------------------------------------------------------
  print('\n[3] UID argument validation is bridge-independent...');

  final shortUid = Uint8List(31);
  final longUid = Uint8List(33);
  final goodUid = Uint8List(32);

  // We need a DataHandle for the Framework.uidCall / uidNotify
  // signatures. Creating one does not require the bridge.
  final param = DataHandle('phase5_probe');
  try {
    check('uidCall rejects 31-byte UID with RangeError',
        throwsAs<RangeError>(
            () => Framework.uidCall(shortUid, param), 'uidCall(31)'));
    check('uidCall rejects 33-byte UID with RangeError',
        throwsAs<RangeError>(
            () => Framework.uidCall(longUid, param), 'uidCall(33)'));
    check('uidNotify rejects 31-byte UID with RangeError',
        throwsAs<RangeError>(
            () => Framework.uidNotify(shortUid, param), 'uidNotify(31)'));
    check('uidCallAsync rejects 31-byte UID with RangeError',
        throwsAs<RangeError>(
            () => Framework.uidCallAsync(shortUid, param, (_, __) {}),
            'uidCallAsync(31)'));
  } finally {
    param.dispose();
  }

  // -----------------------------------------------------------------
  // [4] Bridge-only methods fail cleanly when bridge is down
  // -----------------------------------------------------------------
  print('\n[4] Bridge-only methods fail with StateError when bridge is down...');

  if (BridgeHost.instanceOrNull != null) {
    print('         (SKIP: a BridgeHost is already running in this process)');
  } else {
    final param2 = DataHandle('phase5_probe_2');
    try {
      check(
          'uidCall(32) throws StateError',
          throwsAs<StateError>(
              () => Framework.uidCall(goodUid, param2), 'uidCall(32)'));
      check(
          'uidNotify(32) throws StateError',
          throwsAs<StateError>(
              () => Framework.uidNotify(goodUid, param2), 'uidNotify(32)'));
      check(
          'p2pnameCall throws StateError',
          throwsAs<StateError>(
              () => Framework.p2pnameCall('g', param2), 'p2pnameCall'));
      check(
          'p2pnameNotify throws StateError',
          throwsAs<StateError>(
              () => Framework.p2pnameNotify('g', param2), 'p2pnameNotify'));
      check(
          'callAsync throws StateError',
          throwsAs<StateError>(
              () => Framework.callAsync('App', param2, (_, __) {}),
              'callAsync'));
      check(
          'callAsyncSequenced throws StateError',
          throwsAs<StateError>(
              () => Framework.callAsyncSequenced('App', param2, (_, __) {}),
              'callAsyncSequenced'));
      check(
          'uidCallAsync(32) throws StateError',
          throwsAs<StateError>(
              () => Framework.uidCallAsync(goodUid, param2, (_, __) {}),
              'uidCallAsync(32)'));
      check(
          'p2pnameCallAsync throws StateError',
          throwsAs<StateError>(
              () => Framework.p2pnameCallAsync('g', param2, (_, __) {}),
              'p2pnameCallAsync'));

      // Status checks.
      check(
          'LingoFuseStatus.checkUid(32) throws StateError',
          throwsAs<StateError>(
              () => LingoFuseStatus.checkUid(goodUid), 'checkUid(32)'));
      check(
          'LingoFuseStatus.checkUidApi(32) throws StateError',
          throwsAs<StateError>(
              () => LingoFuseStatus.checkUidApi(goodUid, 'x'),
              'checkUidApi(32)'));
      check(
          'LingoFuseStatus.checkP2PName throws StateError',
          throwsAs<StateError>(
              () => LingoFuseStatus.checkP2PName('g'), 'checkP2PName'));
      check(
          'LingoFuseStatus.checkP2PNameApi throws StateError',
          throwsAs<StateError>(
              () => LingoFuseStatus.checkP2PNameApi('g', 'x'),
              'checkP2PNameApi'));
    } finally {
      param2.dispose();
    }
  }

  // -----------------------------------------------------------------
  // [5] Status checkUid length validation is bridge-independent
  // -----------------------------------------------------------------
  print('\n[5] LingoFuseStatus UID length validation is bridge-independent...');

  check('checkUid(31) rejects with RangeError',
      throwsAs<RangeError>(
          () => LingoFuseStatus.checkUid(shortUid), 'checkUid(31)'));
  check('checkUidApi(31) rejects with RangeError',
      throwsAs<RangeError>(
          () => LingoFuseStatus.checkUidApi(shortUid, 'x'),
          'checkUidApi(31)'));

  // -----------------------------------------------------------------
  // [6] io.tryReadJson: non-throwing JSON decode
  // -----------------------------------------------------------------
  print('\n[6] io.tryReadJson...');

  {
    final h = DataHandle('phase5_json');
    try {
      LfIo.writeJson(h, {'a': 1, 'b': 'hello'});
      h.position = 0;
      final v = LfIo.tryReadJson<Map<String, dynamic>>(h);
      check('tryReadJson returns a Map for valid JSON',
          v != null && v['a'] == 1 && v['b'] == 'hello',
          'got $v');
    } finally {
      h.dispose();
    }
  }

  {
    final h = DataHandle('phase5_json_bad');
    try {
      h.writeString('not valid json');
      h.position = 0;
      final v = LfIo.tryReadJson<Map<String, dynamic>>(h);
      check('tryReadJson returns null for invalid JSON', v == null,
          'got $v');
    } finally {
      h.dispose();
    }
  }

  {
    final h = DataHandle('phase5_json_empty');
    try {
      h.writeString('');
      h.position = 0;
      final v = LfIo.tryReadJson<Map<String, dynamic>>(h);
      check('tryReadJson returns null for empty payload', v == null,
          'got $v');
    } finally {
      h.dispose();
    }
  }

  // -----------------------------------------------------------------
  // [7] Legacy sync path: call to absent target
  // -----------------------------------------------------------------
  print('\n[7] Legacy sync call to an absent target...');

  {
    final param = DataHandle('phase5_absent');
    LfIo.writeJson(param, {'a': 1});
    param.position = 0;

    try {
      final resp = Framework.call('__phase5_absent__', param, timeoutMs: 500);
      check('Framework.call returns size-0 handle', resp.size == 0,
          'size=${resp.size}');
      resp.dispose();
    } catch (e) {
      check('Framework.call returns size-0 handle', false, '$e');
    }

    param.position = 0;
    try {
      final resp = Framework.tryCall('__phase5_absent__', param,
          timeoutMs: 500);
      check('Framework.tryCall returns null', resp == null);
      resp?.dispose();
    } catch (e) {
      check('Framework.tryCall returns null', false, '$e');
    }

    param.dispose();
  }

  // -----------------------------------------------------------------
  // Summary
  // -----------------------------------------------------------------
  print('\n=== Summary ===');
  print('  passed: $passed');
  print('  failed: $failed');
  exit(failed == 0 ? 0 : 1);
}