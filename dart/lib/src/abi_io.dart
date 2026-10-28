// ABI binary I/O helpers for LingoFuse Dart binding.
//
// AbiReader and AbiWriter implement the exact wire format used by
// the C++ lf_io.hpp, the Pascal LF_WriteInt32 / LF_ReadString family,
// and the Rust / C# / Python bindings:
//
//   - little-endian for all integer and floating-point types
//   - strings are UTF-8 encoded and terminated by a single NUL byte
//   - readString is fault-tolerant: if no NUL is found, it reads to
//     the end of the buffer (matching the Pascal LF_ReadString behavior)
//   - UID is a fixed 32-byte payload with no terminator
//
// These classes operate on Uint8List directly and do NOT involve FFI,
// so they can be used inside a CallContext callback without any native
// call overhead.

import 'dart:convert';
import 'dart:typed_data';

/// Reads little-endian scalars and NUL-terminated strings from a
/// Uint8List buffer.
class AbiReader {
  final Uint8List _data;
  int _position;

  /// Creates a reader over [data], starting at [offset].
  AbiReader(this._data, {int offset = 0}) : _position = offset {
    if (offset < 0 || offset > _data.length) {
      throw RangeError.range(offset, 0, _data.length, 'offset');
    }
  }

  /// Current read position.
  int get position => _position;

  /// Number of bytes remaining.
  int get remaining => _data.length - _position;

  /// True when the position is at or past the end of the buffer.
  bool get atEnd => _position >= _data.length;

  // -----------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------

  void _require(int n) {
    if (_position + n > _data.length) {
      throw RangeError('AbiReader: need $n bytes at offset $_position, '
          'but only $remaining remain');
    }
  }

  ByteData _view() => ByteData.sublistView(_data);

  // -----------------------------------------------------------------
  // Scalar reads (little-endian)
  // -----------------------------------------------------------------

  int readInt8() {
    _require(1);
    final v = _data[_position];
    _position += 1;
    return v.toSigned(8);
  }

  int readUInt8() {
    _require(1);
    final v = _data[_position];
    _position += 1;
    return v;
  }

  int readInt16() {
    _require(2);
    final v = _view().getInt16(_position, Endian.little);
    _position += 2;
    return v;
  }

  int readUInt16() {
    _require(2);
    final v = _view().getUint16(_position, Endian.little);
    _position += 2;
    return v;
  }

  int readInt32() {
    _require(4);
    final v = _view().getInt32(_position, Endian.little);
    _position += 4;
    return v;
  }

  int readUInt32() {
    _require(4);
    final v = _view().getUint32(_position, Endian.little);
    _position += 4;
    return v;
  }

  int readInt64() {
    _require(8);
    final v = _view().getInt64(_position, Endian.little);
    _position += 8;
    return v;
  }

  int readUInt64() {
    _require(8);
    final v = _view().getUint64(_position, Endian.little);
    _position += 8;
    return v;
  }

  double readSingle() {
    _require(4);
    final v = _view().getFloat32(_position, Endian.little);
    _position += 4;
    return v;
  }

  double readDouble() {
    _require(8);
    final v = _view().getFloat64(_position, Endian.little);
    _position += 8;
    return v;
  }

  // -----------------------------------------------------------------
  // String and byte reads
  // -----------------------------------------------------------------

  /// Reads a NUL-terminated UTF-8 string.
  ///
  /// If a NUL is found, returns the bytes before it and advances past
  /// the NUL. If no NUL is found, returns all remaining bytes and
  /// advances to the end of the buffer (fault-tolerant mode, matching
  /// the Pascal LF_ReadString behavior).
  String readString() {
    final start = _position;
    while (_position < _data.length && _data[_position] != 0) {
      _position++;
    }
    final bytes = _data.sublist(start, _position);
    if (_position < _data.length) {
      _position++; // skip the NUL
    }
    if (bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Reads exactly [n] bytes.
  Uint8List readBytes(int n) {
    _require(n);
    final out = Uint8List.fromList(_data.sublist(_position, _position + n));
    _position += n;
    return out;
  }

  /// Reads a 32-byte UID with no terminator.
  Uint8List readUid() {
    if (_data.length - _position < 32) {
      throw RangeError('AbiReader: need 32 bytes for UID at offset '
          '$_position, but only $remaining remain');
    }
    final out = Uint8List.fromList(_data.sublist(_position, _position + 32));
    _position += 32;
    return out;
  }
}

/// Writes little-endian scalars and NUL-terminated strings into a
/// growing Uint8List buffer.
class AbiWriter {
  final BytesBuilder _builder;

  /// Creates a writer.
  ///
  /// Note: dart:typed_data's BytesBuilder does not support an initial
  /// capacity hint, so there is no `initialCapacity` parameter.
  AbiWriter() : _builder = BytesBuilder(copy: false);

  /// Current number of bytes written.
  int get length => _builder.length;

  // -----------------------------------------------------------------
  // Scalar writes (little-endian)
  // -----------------------------------------------------------------

  void writeInt8(int v) {
    _builder.addByte(v & 0xFF);
  }

  void writeUInt8(int v) {
    _builder.addByte(v & 0xFF);
  }

  void writeInt16(int v) {
    final bd = ByteData(2)..setInt16(0, v, Endian.little);
    _builder.add(bd.buffer.asUint8List());
  }

  void writeUInt16(int v) {
    final bd = ByteData(2)..setUint16(0, v, Endian.little);
    _builder.add(bd.buffer.asUint8List());
  }

  void writeInt32(int v) {
    final bd = ByteData(4)..setInt32(0, v, Endian.little);
    _builder.add(bd.buffer.asUint8List());
  }

  void writeUInt32(int v) {
    final bd = ByteData(4)..setUint32(0, v, Endian.little);
    _builder.add(bd.buffer.asUint8List());
  }

  void writeInt64(int v) {
    final bd = ByteData(8)..setInt64(0, v, Endian.little);
    _builder.add(bd.buffer.asUint8List());
  }

  void writeUInt64(int v) {
    final bd = ByteData(8)..setUint64(0, v, Endian.little);
    _builder.add(bd.buffer.asUint8List());
  }

  void writeSingle(double v) {
    final bd = ByteData(4)..setFloat32(0, v, Endian.little);
    _builder.add(bd.buffer.asUint8List());
  }

  void writeDouble(double v) {
    final bd = ByteData(8)..setFloat64(0, v, Endian.little);
    _builder.add(bd.buffer.asUint8List());
  }

  // -----------------------------------------------------------------
  // String and byte writes
  // -----------------------------------------------------------------

  /// Writes a UTF-8 string followed by a single NUL byte.
  void writeString(String v) {
    if (v.isNotEmpty) {
      _builder.add(utf8.encode(v));
    }
    _builder.addByte(0);
  }

  /// Writes raw bytes without any terminator.
  void writeBytes(Uint8List v) {
    _builder.add(v);
  }

  /// Writes a 32-byte UID with no terminator.
  void writeUid(Uint8List uid) {
    if (uid.length != 32) {
      throw RangeError('UID must be exactly 32 bytes, got ${uid.length}');
    }
    _builder.add(uid);
  }

  // -----------------------------------------------------------------
  // Finalization
  // -----------------------------------------------------------------

  /// Takes the written bytes and resets the writer for reuse.
  Uint8List takeBytes() {
    return _builder.takeBytes();
  }
}