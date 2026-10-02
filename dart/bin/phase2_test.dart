// Phase 2 smoke test: caller-side framework plumbing.

import 'dart:io';

import 'package:lingofuse/lingofuse.dart';

void main() {
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

  print('=== Phase 2 smoke test (caller) ===\n');

  // ---- Options ----
  print('[Options]');
  Framework.setOption('Quiet', 'True');
  Framework.setOption('Wait_Connection_ReadyOk', 'False');
  Framework.setOption('Wait_Connection_Timeout', '5000');
  check('setOption does not throw', true);

  // ---- Preparation ----
  print('\n[Preparation]');
  Framework.resetPrepare();
  check('resetPrepare does not throw', true);

  final tag1 = Framework.prepareService('ipc:dart_p2', 'ipc:dart_p2');
  check('prepareService returned tag > 0', tag1 > 0, 'tag=$tag1');

  final tag2 = Framework.prepareClient('ipc:dart_p2');
  check('prepareClient returned tag > 0', tag2 > 0, 'tag=$tag2');

  final started = Framework.prepareDone();
  check('prepareDone returned true', started);

  // Second call should return false (already started)
  final started2 = Framework.prepareDone();
  check('second prepareDone returns false', !started2);

  // ---- Health checks ----
  print('\n[Health checks]');
  check('checkMainThread returns true', Framework.checkMainThread());
  check('checkApp("__absent__") returns false',
      !Framework.checkApp('__absent__'));
  check('checkApi("__absent__", "__also__") returns false',
      !Framework.checkApi('__absent__', '__also__'));

  // ---- Application name ----
  print('\n[App name]');
  final name = Framework.generateAppName();
  check('generateAppName returns non-empty', name.isNotEmpty);
  print('         name = $name');

  // ---- Call to absent target ----
  print('\n[Call to absent target]');
  {
    final param = DataHandle('nonexistent');
    LfIo.writeJson(param, {'a': 1});
    param.position = 0;

    // tryCall should return null (empty response)
    final resp = Framework.tryCall('__definitely_absent__', param,
        timeoutMs: 500);
    check('tryCall returns null for absent target', resp == null);
    param.dispose();
  }

  // ---- Call (low-level, empty handle on timeout) ----
  print('\n[Call (low-level)]');
  {
    final param = DataHandle('nonexistent');
    LfIo.writeJson(param, {'a': 1});
    param.position = 0;

    final resp =
        Framework.call('__definitely_absent__', param, timeoutMs: 500);
    check('call returns size-0 handle on timeout', resp.size == 0);
    resp.dispose();
    param.dispose();
  }

  // ---- Notify (fire and forget) ----
  print('\n[Notify]');
  {
    final param = DataHandle('log');
    LfIo.writeJson(param, {'msg': 'hello'});
    param.position = 0;
    Framework.notify('__definitely_absent__', param);
    check('notify does not throw on absent target', true);
    param.dispose();
  }

  // ---- Sequenced notify ----
  print('\n[Sequenced notify]');
  {
    final param = DataHandle('log');
    LfIo.writeJson(param, {'msg': 'hello'});
    param.position = 0;
    Framework.sequencedNotify('__definitely_absent__', param);
    check('sequencedNotify does not throw on absent target', true);
    param.dispose();
  }

  // ---- Shutdown ----
  print('\n[Shutdown]');
  Framework.exitMainThread();
  check('exitMainThread does not throw', true);
  Framework.shutdown();
  check('shutdown does not throw', true);
  Framework.shutdown();
  check('second shutdown is idempotent', true);

  // ---- Summary ----
  print('\n=== Summary ===');
  print('  passed: $passed');
  print('  failed: $failed');

  exit(failed == 0 ? 0 : 1);
}