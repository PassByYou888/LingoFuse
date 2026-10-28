// AbiReader / AbiWriter tests. No native library or framework required.

import 'dart:typed_data';

import 'package:lingofuse/lingofuse.dart';
import 'package:test/test.dart';

void main() {
  group('AbiWriter and AbiReader round-trip', () {
    test('int8 edge values', () {
      final w = AbiWriter();
      for (final v in [-128, -1, 0, 1, 127]) {
        w.writeInt8(v);
      }
      final r = AbiReader(w.takeBytes());
      for (final v in [-128, -1, 0, 1, 127]) {
        expect(r.readInt8(), equals(v));
      }
    });

    test('uint8 edge values', () {
      final w = AbiWriter();
      for (final v in [0, 1, 127, 255]) {
        w.writeUInt8(v);
      }
      final r = AbiReader(w.takeBytes());
      for (final v in [0, 1, 127, 255]) {
        expect(r.readUInt8(), equals(v));
      }
    });

    test('int16 edge values', () {
      final w = AbiWriter();
      for (final v in [-32768, -1, 0, 1, 32767]) {
        w.writeInt16(v);
      }
      final r = AbiReader(w.takeBytes());
      for (final v in [-32768, -1, 0, 1, 32767]) {
        expect(r.readInt16(), equals(v));
      }
    });

    test('uint16 edge values', () {
      final w = AbiWriter();
      for (final v in [0, 1, 32767, 65535]) {
        w.writeUInt16(v);
      }
      final r = AbiReader(w.takeBytes());
      for (final v in [0, 1, 32767, 65535]) {
        expect(r.readUInt16(), equals(v));
      }
    });

    test('int32 edge values', () {
      final w = AbiWriter();
      final values = [-2147483648, -1, 0, 1, 2147483647];
      for (final v in values) {
        w.writeInt32(v);
      }
      final r = AbiReader(w.takeBytes());
      for (final v in values) {
        expect(r.readInt32(), equals(v));
      }
    });

    test('uint32 edge values', () {
      final w = AbiWriter();
      final values = [0, 1, 2147483647, 4294967295];
      for (final v in values) {
        w.writeUInt32(v);
      }
      final r = AbiReader(w.takeBytes());
      for (final v in values) {
        expect(r.readUInt32(), equals(v));
      }
    });

    test('int64 edge values', () {
      final w = AbiWriter();
      final values = [
        -9223372036854775808,
        -1,
        0,
        1,
        9223372036854775807,
      ];
      for (final v in values) {
        w.writeInt64(v);
      }
      final r = AbiReader(w.takeBytes());
      for (final v in values) {
        expect(r.readInt64(), equals(v));
      }
    });

    test('uint64 values within signed range', () {
      final w = AbiWriter();
      final values = [0, 1, 4294967296, 9223372036854775807];
      for (final v in values) {
        w.writeUInt64(v);
      }
      final r = AbiReader(w.takeBytes());
      for (final v in values) {
        expect(r.readUInt64(), equals(v));
      }
    });

    test('single round-trip', () {
      final w = AbiWriter();
      w.writeSingle(3.14);
      final r = AbiReader(w.takeBytes());
      expect(r.readSingle(), closeTo(3.14, 1e-5));
    });

    test('double round-trip', () {
      final w = AbiWriter();
      w.writeDouble(3.141592653589793);
      final r = AbiReader(w.takeBytes());
      expect(r.readDouble(), equals(3.141592653589793));
    });

    test('little-endian byte order is used', () {
      final w = AbiWriter();
      w.writeUInt32(0x01020304);
      final bytes = w.takeBytes();
      expect(bytes, equals([0x04, 0x03, 0x02, 0x01]));
    });
  });

  group('String I/O', () {
    test('ASCII string is NUL-terminated', () {
      final w = AbiWriter();
      w.writeString('hello');
      final bytes = w.takeBytes();
      expect(bytes.length, equals(6));
      expect(bytes[5], equals(0));
      final r = AbiReader(bytes);
      expect(r.readString(), equals('hello'));
    });

    test('empty string occupies exactly one byte', () {
      final w = AbiWriter();
      w.writeString('');
      final bytes = w.takeBytes();
      expect(bytes.length, equals(1));
      expect(bytes[0], equals(0));
      final r = AbiReader(bytes);
      expect(r.readString(), equals(''));
    });

    test('CJK and emoji round-trip', () {
      final w = AbiWriter();
      w.writeString('你好 🌍');
      final r = AbiReader(w.takeBytes());
      expect(r.readString(), equals('你好 🌍'));
    });

    test('readString is fault-tolerant without NUL', () {
      final r = AbiReader(Uint8List.fromList([0x68, 0x65, 0x6C, 0x6C, 0x6F]));
      expect(r.readString(), equals('hello'));
      expect(r.position, equals(5));
    });

    test('readString stops at first NUL', () {
      final r = AbiReader(
          Uint8List.fromList([0x61, 0x62, 0x00, 0x63, 0x64]));
      expect(r.readString(), equals('ab'));
      expect(r.position, equals(3));
    });

    test('multiple strings in sequence', () {
      final w = AbiWriter();
      w.writeString('one');
      w.writeString('two');
      w.writeString('');
      w.writeString('four');
      final r = AbiReader(w.takeBytes());
      expect(r.readString(), equals('one'));
      expect(r.readString(), equals('two'));
      expect(r.readString(), equals(''));
      expect(r.readString(), equals('four'));
    });
  });

  group('Bytes and UID', () {
    test('writeBytes / readBytes round-trip', () {
      final w = AbiWriter();
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      w.writeBytes(data);
      final r = AbiReader(w.takeBytes());
      expect(r.readBytes(5), equals([1, 2, 3, 4, 5]));
    });

    test('UID round-trip without terminator', () {
      final w = AbiWriter();
      final uid = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        uid[i] = (i * 7) & 0xFF;
      }
      w.writeUid(uid);
      final bytes = w.takeBytes();
      expect(bytes.length, equals(32));
      final r = AbiReader(bytes);
      final out = r.readUid();
      expect(out, equals(uid));
    });

    test('writeUid rejects wrong-length input', () {
      final w = AbiWriter();
      expect(() => w.writeUid(Uint8List(31)), throwsA(isA<RangeError>()));
      expect(() => w.writeUid(Uint8List(33)), throwsA(isA<RangeError>()));
    });

    test('readUid throws on short buffer', () {
      final r = AbiReader(Uint8List(20));
      expect(() => r.readUid(), throwsA(isA<RangeError>()));
    });
  });

  group('Position tracking and errors', () {
    test('position and remaining are tracked', () {
      final r = AbiReader(Uint8List.fromList([1, 2, 3, 4, 5]));
      expect(r.position, equals(0));
      expect(r.remaining, equals(5));
      r.readUInt8();
      expect(r.position, equals(1));
      expect(r.remaining, equals(4));
      r.readBytes(3);
      expect(r.position, equals(4));
      expect(r.remaining, equals(1));
      expect(r.atEnd, isFalse);
      r.readUInt8();
      expect(r.atEnd, isTrue);
    });

    test('readInt32 beyond the end throws RangeError', () {
      final r = AbiReader(Uint8List(3));
      expect(() => r.readInt32(), throwsA(isA<RangeError>()));
    });

    test('constructor rejects out-of-range offset', () {
      expect(() => AbiReader(Uint8List(5), offset: -1),
          throwsA(isA<RangeError>()));
      expect(() => AbiReader(Uint8List(5), offset: 6),
          throwsA(isA<RangeError>()));
    });
  });

  group('Cross-language byte alignment', () {
    test('string wire format matches Pascal LF_WriteString', () {
      final w = AbiWriter();
      w.writeString('{"a":1}');
      final bytes = w.takeBytes();
      expect(bytes, equals([0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D, 0x00]));
    });

    test('int32 wire format is little-endian', () {
      final w = AbiWriter();
      w.writeInt32(0x01020304);
      expect(w.takeBytes(), equals([0x04, 0x03, 0x02, 0x01]));
    });

    test('int64 wire format is little-endian', () {
      final w = AbiWriter();
      w.writeInt64(0x0102030405060708);
      expect(w.takeBytes(),
          equals([0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]));
    });
  });
}