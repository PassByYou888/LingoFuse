// LfIo layer tests. No framework state required.

import 'dart:convert';
import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';
import 'package:test/test.dart';

void main() {
  group('JSON string helpers', () {
    test('dumpsJson output is compact', () {
      final s = LfIo.dumpsJson({'a': 1, 'b': 'x'});
      expect(s.contains('\n'), isFalse);
      expect(s.contains('  '), isFalse);
    });

    test('dumpsJson preserves non-ASCII literally', () {
      final s = LfIo.dumpsJson({'msg': '你好 🌍'});
      expect(s.contains('你好'), isTrue);
      expect(s.contains('🌍'), isTrue);
      expect(s.contains(r'\u'), isFalse);
    });

    test('loadsJson parses valid JSON', () {
      final v = LfIo.loadsJson<Map<String, dynamic>>('{"a":1}');
      expect(v['a'], equals(1));
    });

    test('loadsJson rejects invalid JSON', () {
      expect(() => LfIo.loadsJson<dynamic>('not json'),
          throwsA(isA<LingoFuseIoError>()));
    });

    test('round-trip preserves nested structures', () {
      final original = {
        'name': '张三',
        'age': 30,
        'tags': ['a', 'b', 'c'],
        'nested': {
          'x': 1,
          'y': [2, 3],
        },
        'emoji': '🎉',
        'flag': true,
        'nothing': null,
      };
      final text = LfIo.dumpsJson(original);
      final back = LfIo.loadsJson<Map<String, dynamic>>(text);
      expect(back, equals(original));
    });
  });

  group('JSON on DataHandle', () {
    test('writeJson / readJson round-trip', () {
      final dh = DataHandle('test');
      LfIo.writeJson(dh, {'a': 1, 'msg': 'hello'});
      dh.position = 0;
      final back = LfIo.readJson<Map<String, dynamic>>(dh);
      expect(back['a'], equals(1));
      expect(back['msg'], equals('hello'));
      dh.dispose();
    });

    test('JSON wire bytes contain literal UTF-8, no escapes', () {
      final dh = DataHandle('test');
      LfIo.writeJson(dh, {'msg': '世界'});
      dh.position = 0;
      final raw = LfIo.readStringBytes(dh);
      final text = utf8.decode(raw);
      expect(text.contains('世界'), isTrue);
      expect(text.contains(r'\u'), isFalse);
    });

    test('JSON payload is NUL-framed', () {
      final dh = DataHandle('test');
      LfIo.writeJson(dh, {'a': 1});
      // {"a":1} = 7 bytes, plus NUL = 8
      expect(dh.size, equals(8));
      dh.dispose();
    });

    test('readJson throws LingoFuseIoError on empty payload', () {
      final dh = DataHandle('test');
      dh.writeString('');
      dh.position = 0;
      expect(() => LfIo.readJson<Map<String, dynamic>>(dh),
          throwsA(isA<LingoFuseIoError>()));
      dh.dispose();
    });

    test('readJson throws LingoFuseIoError on invalid JSON', () {
      final dh = DataHandle('test');
      dh.writeString('not valid json');
      dh.position = 0;
      expect(() => LfIo.readJson<Map<String, dynamic>>(dh),
          throwsA(isA<LingoFuseIoError>()));
      dh.dispose();
    });

    test('tryReadJson returns null on invalid payload', () {
      final dh = DataHandle('test');
      dh.writeString('not valid json');
      dh.position = 0;
      expect(LfIo.tryReadJson<Map<String, dynamic>>(dh), isNull);
      dh.dispose();
    });

    test('tryReadJson returns null on empty payload', () {
      final dh = DataHandle('test');
      dh.writeString('');
      dh.position = 0;
      expect(LfIo.tryReadJson<Map<String, dynamic>>(dh), isNull);
      dh.dispose();
    });
  });

  group('string and byte helpers', () {
    test('writeString / readString are NUL-framed', () {
      final dh = DataHandle('test');
      LfIo.writeString(dh, 'hello');
      dh.position = 0;
      expect(LfIo.readString(dh), equals('hello'));
      dh.dispose();
    });

    test('writeStringBytes appends a single NUL', () {
      final dh = DataHandle('test');
      LfIo.writeStringBytes(dh, Uint8List.fromList([1, 2, 3]));
      expect(dh.size, equals(4));
      dh.dispose();
    });

    test('writeStringBytes preserves embedded NULs', () {
      final dh = DataHandle('test');
      LfIo.writeStringBytes(dh, Uint8List.fromList([1, 0, 2]));
      expect(dh.size, equals(4)); // 1 + 0 + 2 + framing NUL
      dh.dispose();
    });

    test('readStringBytes stops at first NUL', () {
      final dh = DataHandle('test');
      dh.writeBytes([1, 2, 0, 3, 4]);
      dh.position = 0;
      expect(LfIo.readStringBytes(dh), equals([1, 2]));
      dh.dispose();
    });

    test('readAllBytes ignores NULs', () {
      final dh = DataHandle('test');
      dh.writeBytes([1, 0, 2, 0, 3]);
      dh.position = 0;
      expect(LfIo.readAllBytes(dh), equals([1, 0, 2, 0, 3]));
      dh.dispose();
    });

    test('empty payload readStringBytes returns empty', () {
      final dh = DataHandle('test');
      dh.writeBytes([]);
      dh.position = 0;
      expect(LfIo.readStringBytes(dh), isEmpty);
      dh.dispose();
    });
  });
}