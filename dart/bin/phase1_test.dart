// Phase 1 smoke test for the LingoFuse Dart binding.

import 'dart:convert';

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

  print('=== Phase 1 smoke test ===\n');

  // ---- DataHandle basic I/O ----
  print('[DataHandle]');
  {
    final dh = DataHandle('test_phase1');
    dh.writeInt32(42);
    dh.writeString('hello');
    dh.writeDouble(3.14);
    dh.position = 0;
    check('int32 round-trip', dh.readInt32() == 42);
    check('string round-trip', dh.readString() == 'hello');
    check('double round-trip', dh.readDouble() == 3.14);
    check('size = 4 + 6 + 8 = 18', dh.size == 18);
    dh.dispose();
    dh.dispose();
    check('dispose is idempotent', true);
  }

  // ---- JSON via LfIo ----
  print('\n[LfIo]');
  {
    final dh = DataHandle('test_json');
    LfIo.writeJson(dh, {'a': 1, 'msg': '世界 🌍'});
    dh.position = 0;
    final back = LfIo.readJson<Map<String, dynamic>>(dh);
    check('JSON round-trip', back['a'] == 1 && back['msg'] == '世界 🌍');

    // Verify literal UTF-8, no \uXXXX escapes
    dh.position = 0;
    final raw = LfIo.readStringBytes(dh);
    final text = utf8.decode(raw);
    check('CJK literal in wire bytes', text.contains('世界'));
    check('emoji literal in wire bytes', text.contains('🌍'));
    check('no \\uXXXX escapes', !text.contains('\\u'));

    dh.dispose();
  }

  // ---- NUL-framed read tolerance ----
  print('\n[NUL tolerance]');
  {
    final dh = DataHandle('test_nul');
    // {"a":1} with no trailing NUL
    dh.writeBytes([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D]);
    dh.position = 0;
    final s = dh.readString();
    check('reads raw JSON with no NUL', s == '{"a":1}');
    dh.dispose();
  }

  // ---- Status ----
  print('\n[LingoFuseStatus]');
  {
    final n = LingoFuseStatus.getStatusCount();
    check('getStatusCount returns non-negative', n >= 0);
  }

  // ---- Summary ----
  print('\n=== Summary ===');
  print('  passed: $passed');
  print('  failed: $failed');
}