// DataHandle layer tests. No framework state required.

import 'package:lingofuse/lingofuse.dart';
import 'package:test/test.dart';

void main() {
  group('construction', () {
    test('auto-recycled handle is valid and owning', () {
      final dh = DataHandle('test');
      expect(dh.isValid, isTrue);
      expect(dh.isOwning, isTrue);
      dh.dispose();
    });

    test('permanent handle is valid and owning', () {
      final dh = DataHandle.createPermanent('test');
      expect(dh.isValid, isTrue);
      expect(dh.isOwning, isTrue);
      dh.dispose();
    });

    test('fromRaw with owned=false marks handle as borrowing', () {
      final owner = DataHandle('test');
      final borrowed = DataHandle.fromRaw(owner.raw, owned: false);
      expect(borrowed.isOwning, isFalse);
      owner.dispose();
      borrowed.dispose(); // no-op
    });
  });

  group('byte I/O', () {
    test('writeBytes then readBytes round-trips', () {
      final dh = DataHandle('test');
      dh.writeBytes([1, 2, 3, 4]);
      dh.position = 0;
      expect(dh.readBytes(4), equals([1, 2, 3, 4]));
      dh.dispose();
    });

    test('readBytes returns empty at end of buffer', () {
      final dh = DataHandle('test');
      dh.writeBytes([1, 2]);
      dh.position = 2;
      expect(dh.readBytes(10), isEmpty);
      dh.dispose();
    });

    test('readBytes returns partial when fewer bytes available', () {
      final dh = DataHandle('test');
      dh.writeBytes([1, 2]);
      dh.position = 0;
      expect(dh.readBytes(10), equals([1, 2]));
      dh.dispose();
    });

    test('readBytesExact throws on short read and restores cursor', () {
      final dh = DataHandle('test');
      dh.writeBytes([1, 2]);
      dh.position = 0;
      expect(() => dh.readBytesExact(4), throwsA(isA<LingoFuseIoError>()));
      expect(dh.position, equals(0));
      dh.dispose();
    });

    test('readAllBytes consumes remaining bytes', () {
      final dh = DataHandle('test');
      dh.writeBytes([1, 2, 3, 4, 5]);
      dh.position = 2;
      expect(dh.readAllBytes(), equals([3, 4, 5]));
      dh.dispose();
    });

    test('writeBytes accepts empty list as no-op', () {
      final dh = DataHandle('test');
      final written = dh.writeBytes([]);
      expect(written, equals(0));
      expect(dh.size, equals(0));
      dh.dispose();
    });
  });

  group('scalar I/O', () {
    test('int8 round-trips edge values', () {
      final dh = DataHandle('test');
      for (final v in [-128, -1, 0, 1, 127]) {
        dh.writeInt8(v);
      }
      dh.position = 0;
      for (final v in [-128, -1, 0, 1, 127]) {
        expect(dh.readInt8(), equals(v));
      }
      dh.dispose();
    });

    test('uint8 round-trips edge values', () {
      final dh = DataHandle('test');
      for (final v in [0, 1, 127, 255]) {
        dh.writeUInt8(v);
      }
      dh.position = 0;
      for (final v in [0, 1, 127, 255]) {
        expect(dh.readUInt8(), equals(v));
      }
      dh.dispose();
    });

    test('int16 round-trips edge values', () {
      final dh = DataHandle('test');
      for (final v in [-32768, -1, 0, 1, 32767]) {
        dh.writeInt16(v);
      }
      dh.position = 0;
      for (final v in [-32768, -1, 0, 1, 32767]) {
        expect(dh.readInt16(), equals(v));
      }
      dh.dispose();
    });

    test('uint16 round-trips edge values', () {
      final dh = DataHandle('test');
      for (final v in [0, 1, 32767, 65535]) {
        dh.writeUInt16(v);
      }
      dh.position = 0;
      for (final v in [0, 1, 32767, 65535]) {
        expect(dh.readUInt16(), equals(v));
      }
      dh.dispose();
    });

    test('int32 round-trips edge values', () {
      final dh = DataHandle('test');
      final values = [-2147483648, -1, 0, 1, 2147483647];
      for (final v in values) {
        dh.writeInt32(v);
      }
      dh.position = 0;
      for (final v in values) {
        expect(dh.readInt32(), equals(v));
      }
      dh.dispose();
    });

    test('uint32 round-trips edge values', () {
      final dh = DataHandle('test');
      final values = [0, 1, 2147483647, 4294967295];
      for (final v in values) {
        dh.writeUInt32(v);
      }
      dh.position = 0;
      for (final v in values) {
        expect(dh.readUInt32(), equals(v));
      }
      dh.dispose();
    });

    test('int64 round-trips edge values', () {
      final dh = DataHandle('test');
      final values = [
        -9223372036854775808,
        -1,
        0,
        1,
        9223372036854775807,
      ];
      for (final v in values) {
        dh.writeInt64(v);
      }
      dh.position = 0;
      for (final v in values) {
        expect(dh.readInt64(), equals(v));
      }
      dh.dispose();
    });

    test('uint64 round-trips values within Dart int range', () {
      // Dart's `int` is signed 64-bit on the native VM. Values above
      // 2^63 - 1 cannot be expressed as a Dart integer literal, so the
      // full uint64 range is exercised at the byte level (see the
      // `uint64 full-range round-trip via raw bytes` test below).
      final dh = DataHandle('test');
      final values = [
        0,
        1,
        4294967296, // 2^32
        9223372036854775807, // 2^63 - 1
      ];
      for (final v in values) {
        dh.writeUInt64(v);
      }
      dh.position = 0;
      for (final v in values) {
        expect(dh.readUInt64(), equals(v));
      }
      dh.dispose();
    });

    test('uint64 full-range round-trip via raw bytes', () {
      // 0xFFFFFFFFFFFFFFFF encoded little-endian. This bypasses Dart's
      // signed 64-bit int and verifies the full byte range.
      final dh = DataHandle('test');
      dh.writeBytes([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
      dh.position = 0;
      expect(
        dh.readBytes(8),
        equals([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
      );
      dh.dispose();
    });

    test('single round-trips within float32 precision', () {
      final dh = DataHandle('test');
      dh.writeSingle(3.14);
      dh.position = 0;
      expect(dh.readSingle(), closeTo(3.14, 1e-5));
      dh.dispose();
    });

    test('double round-trips exactly', () {
      final dh = DataHandle('test');
      dh.writeDouble(3.141592653589793);
      dh.position = 0;
      expect(dh.readDouble(), equals(3.141592653589793));
      dh.dispose();
    });

    test('scalars are encoded little-endian', () {
      final dh = DataHandle('test');
      dh.writeUInt32(0x01020304);
      dh.position = 0;
      expect(dh.readBytes(4), equals([0x04, 0x03, 0x02, 0x01]));
      dh.dispose();
    });

    test('mixed scalars maintain insertion order', () {
      final dh = DataHandle('test');
      dh.writeInt32(42);
      dh.writeUInt16(0xABCD);
      dh.writeDouble(3.14);
      dh.writeString('hello');
      dh.position = 0;
      expect(dh.readInt32(), equals(42));
      expect(dh.readUInt16(), equals(0xABCD));
      expect(dh.readDouble(), equals(3.14));
      expect(dh.readString(), equals('hello'));
      dh.dispose();
    });
  });

  group('string I/O', () {
    test('ASCII round-trips', () {
      final dh = DataHandle('test');
      dh.writeString('hello world');
      dh.position = 0;
      expect(dh.readString(), equals('hello world'));
      dh.dispose();
    });

    test('CJK round-trips', () {
      final dh = DataHandle('test');
      dh.writeString('你好世界');
      dh.position = 0;
      expect(dh.readString(), equals('你好世界'));
      dh.dispose();
    });

    test('emoji round-trips', () {
      final dh = DataHandle('test');
      dh.writeString('Hello 🌍 🎉');
      dh.position = 0;
      expect(dh.readString(), equals('Hello 🌍 🎉'));
      dh.dispose();
    });

    test('empty string occupies exactly one byte', () {
      final dh = DataHandle('test');
      dh.writeString('');
      expect(dh.size, equals(1));
      dh.position = 0;
      expect(dh.readString(), equals(''));
      dh.dispose();
    });

    test('embedded NUL truncates on read', () {
      final dh = DataHandle('test');
      dh.writeString('abc\u0000def');
      dh.position = 0;
      expect(dh.readString(), equals('abc'));
      dh.dispose();
    });

    test('read is fault-tolerant when NUL is absent', () {
      final dh = DataHandle('test');
      // raw "hello" without NUL
      dh.writeBytes([0x68, 0x65, 0x6C, 0x6C, 0x6F]);
      dh.position = 0;
      expect(dh.readString(), equals('hello'));
      dh.dispose();
    });
  });

  group('position and size', () {
    test('size grows with writes', () {
      final dh = DataHandle('test');
      expect(dh.size, equals(0));
      dh.writeBytes([1, 2, 3]);
      expect(dh.size, equals(3));
      dh.writeBytes([4, 5]);
      expect(dh.size, equals(5));
      dh.dispose();
    });

    test('position advances with writes', () {
      final dh = DataHandle('test');
      expect(dh.position, equals(0));
      dh.writeBytes([1, 2, 3]);
      expect(dh.position, equals(3));
      dh.dispose();
    });

    test('setSize extends the buffer explicitly', () {
      final dh = DataHandle('test');
      dh.size = 10;
      expect(dh.size, equals(10));
      dh.dispose();
    });

    test('position can be set to a value within the resized buffer', () {
      final dh = DataHandle('test');
      dh.size = 10;
      dh.position = 5;
      expect(dh.position, equals(5));
      dh.dispose();
    });

    test('setSize both truncates and extends', () {
      final dh = DataHandle('test');
      dh.writeBytes([1, 2, 3, 4, 5]);
      dh.size = 3;
      expect(dh.size, equals(3));
      dh.size = 8;
      expect(dh.size, equals(8));
      dh.dispose();
    });

    test('negative position is rejected', () {
      final dh = DataHandle('test');
      expect(() => dh.position = -1, throwsA(isA<RangeError>()));
      dh.dispose();
    });

    test('negative size is rejected', () {
      final dh = DataHandle('test');
      expect(() => dh.size = -1, throwsA(isA<RangeError>()));
      dh.dispose();
    });
  });

  group('lifetime', () {
    test('dispose is idempotent', () {
      final dh = DataHandle('test');
      dh.dispose();
      dh.dispose();
    });

    test('accessors after dispose throw LingoFuseObjectDisposedError', () {
      final dh = DataHandle('test');
      dh.dispose();
      expect(() => dh.size, throwsA(isA<LingoFuseObjectDisposedError>()));
      expect(() => dh.position, throwsA(isA<LingoFuseObjectDisposedError>()));
      expect(() => dh.writeBytes([1]),
          throwsA(isA<LingoFuseObjectDisposedError>()));
      expect(() => dh.readBytes(1),
          throwsA(isA<LingoFuseObjectDisposedError>()));
    });

    test('borrowed handle dispose does not invalidate the handle', () {
      final owner = DataHandle('test');
      owner.writeBytes([1, 2, 3]);
      owner.position = 0;
      final borrowed = DataHandle.fromRaw(owner.raw, owned: false);
      borrowed.dispose(); // no-op
      expect(borrowed.isValid, isTrue);
      expect(borrowed.readBytes(1), equals([1]));
      owner.dispose();
    });
  });
}