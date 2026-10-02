// RAII wrapper around a native LingoFuse data handle.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'errors.dart';
import 'runtime.dart';

/// RAII wrapper around a native LingoFuse data handle (TDataHnd).
class DataHandle {
  final Pointer<Void> _raw;
  final bool _owned;
  bool _disposed = false;

  DataHandle._(this._raw, this._owned);

  /// Creates a new auto-recycled data handle.
  factory DataHandle(String apiName) {
    final lf = getBindings();
    final cname = apiName.toNativeUtf8().cast<Char>();
    try {
      final hnd = lf.LF_CreateData(cname);
      if (hnd == nullptr) {
        throw LingoFuseError("LF_CreateData returned null for '$apiName'");
      }
      return DataHandle._(hnd, true);
    } finally {
      calloc.free(cname);
    }
  }

  /// Creates a new permanent data handle (never auto-recycled).
  factory DataHandle.createPermanent(String apiName) {
    final lf = getBindings();
    final cname = apiName.toNativeUtf8().cast<Char>();
    try {
      final hnd = lf.LF_CreateData_Permanent(cname);
      if (hnd == nullptr) {
        throw LingoFuseError(
            "LF_CreateData_Permanent returned null for '$apiName'");
      }
      return DataHandle._(hnd, true);
    } finally {
      calloc.free(cname);
    }
  }

  /// Wraps an existing raw handle. Use `owned: false` inside callbacks.
  factory DataHandle.fromRaw(Pointer<Void> raw, {bool owned = false}) {
    return DataHandle._(raw, owned);
  }

  Pointer<Void> get raw {
    _ensureNotDisposed();
    return _raw;
  }

  bool get isValid => !_disposed && _raw != nullptr;
  bool get isOwning => _owned;

  void _ensureNotDisposed() {
    if (_disposed || _raw == nullptr) {
      throw LingoFuseObjectDisposedError('DataHandle');
    }
  }

  // -----------------------------------------------------------------
  // Position and size
  // -----------------------------------------------------------------

  int get position {
    _ensureNotDisposed();
    return getBindings().LF_GetPos(_raw);
  }

  set position(int value) {
    _ensureNotDisposed();
    if (value < 0) {
      throw RangeError('position must be non-negative');
    }
    getBindings().LF_SetPos(_raw, value);
  }

  int get size {
    _ensureNotDisposed();
    return getBindings().LF_GetSize(_raw);
  }

  set size(int value) {
    _ensureNotDisposed();
    if (value < 0) {
      throw RangeError('size must be non-negative');
    }
    getBindings().LF_SetSize(_raw, value);
  }

  // -----------------------------------------------------------------
  // Byte I/O
  // -----------------------------------------------------------------

  /// Appends raw bytes at the current cursor.
  int writeBytes(List<int> bytes) {
    _ensureNotDisposed();
    if (bytes.isEmpty) return 0;
    final lf = getBindings();
    final ptr = calloc<Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      final written = lf.LF_WriteBuffer(_raw, ptr.cast<Void>(), bytes.length);
      if (written != bytes.length) {
        throw LingoFuseIoError(
          'short write: $written of ${bytes.length}',
          operation: 'writeBytes',
        );
      }
      return written;
    } finally {
      calloc.free(ptr);
    }
  }

  /// Reads up to [count] bytes.
  Uint8List readBytes(int count) {
    _ensureNotDisposed();
    if (count <= 0) return Uint8List(0);
    final lf = getBindings();
    final ptr = calloc<Uint8>(count);
    try {
      final got = lf.LF_ReadBuffer(_raw, ptr.cast<Void>(), count);
      if (got <= 0) return Uint8List(0);
      return Uint8List.fromList(ptr.asTypedList(got));
    } finally {
      calloc.free(ptr);
    }
  }

  /// Reads exactly [count] bytes; throws on short read.
  Uint8List readBytesExact(int count) {
    _ensureNotDisposed();
    if (count <= 0) return Uint8List(0);
    final saved = position;
    final bytes = readBytes(count);
    if (bytes.length != count) {
      position = saved;
      throw LingoFuseIoError(
        'requested $count bytes, got ${bytes.length}',
        operation: 'readBytesExact',
      );
    }
    return bytes;
  }

  /// Reads all remaining bytes.
  Uint8List readAllBytes() {
    _ensureNotDisposed();
    final pos = position;
    final total = size;
    if (pos >= total) return Uint8List(0);
    return readBytes(total - pos);
  }

  // -----------------------------------------------------------------
  // Byte reads up to NUL (fault-tolerant)
  // -----------------------------------------------------------------

  /// Reads raw bytes up to the first NUL, or the end of the buffer.
  /// Advances the cursor past the NUL, or to `size + 1` if none found.
  Uint8List readBytesUntilNul() {
    _ensureNotDisposed();
    final lf = getBindings();
    final start = lf.LF_GetPos(_raw);
    final total = lf.LF_GetSize(_raw);
    if (start >= total) return Uint8List(0);

    final remaining = total - start;
    final ptr = calloc<Uint8>(remaining);
    try {
      final got = lf.LF_ReadBuffer(_raw, ptr.cast<Void>(), remaining);
      if (got <= 0) return Uint8List(0);

      final view = ptr.asTypedList(got);
      int nulIndex = -1;
      for (int i = 0; i < got; i++) {
        if (view[i] == 0) {
          nulIndex = i;
          break;
        }
      }

      if (nulIndex >= 0) {
        lf.LF_SetPos(_raw, start + nulIndex + 1);
        return Uint8List.fromList(view.sublist(0, nulIndex));
      } else {
        lf.LF_SetPos(_raw, start + got + 1);
        return Uint8List.fromList(view);
      }
    } finally {
      calloc.free(ptr);
    }
  }

  // -----------------------------------------------------------------
  // Scalar I/O (little-endian)
  // -----------------------------------------------------------------

  void writeInt8(int v) => writeBytes([v & 0xFF]);
  void writeUInt8(int v) => writeBytes([v & 0xFF]);
  void writeInt16(int v) => writeBytes(
      (ByteData(2)..setInt16(0, v, Endian.little)).buffer.asUint8List());
  void writeUInt16(int v) => writeBytes(
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  void writeInt32(int v) => writeBytes(
      (ByteData(4)..setInt32(0, v, Endian.little)).buffer.asUint8List());
  void writeUInt32(int v) => writeBytes(
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void writeInt64(int v) => writeBytes(
      (ByteData(8)..setInt64(0, v, Endian.little)).buffer.asUint8List());
  void writeUInt64(int v) => writeBytes(
      (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void writeSingle(double v) => writeBytes(
      (ByteData(4)..setFloat32(0, v, Endian.little)).buffer.asUint8List());
  void writeDouble(double v) => writeBytes(
      (ByteData(8)..setFloat64(0, v, Endian.little)).buffer.asUint8List());

  int readInt8() => readBytesExact(1)[0].toSigned(8);
  int readUInt8() => readBytesExact(1)[0];
  int readInt16() =>
      ByteData.sublistView(readBytesExact(2)).getInt16(0, Endian.little);
  int readUInt16() =>
      ByteData.sublistView(readBytesExact(2)).getUint16(0, Endian.little);
  int readInt32() =>
      ByteData.sublistView(readBytesExact(4)).getInt32(0, Endian.little);
  int readUInt32() =>
      ByteData.sublistView(readBytesExact(4)).getUint32(0, Endian.little);
  int readInt64() =>
      ByteData.sublistView(readBytesExact(8)).getInt64(0, Endian.little);
  int readUInt64() =>
      ByteData.sublistView(readBytesExact(8)).getUint64(0, Endian.little);
  double readSingle() =>
      ByteData.sublistView(readBytesExact(4)).getFloat32(0, Endian.little);
  double readDouble() =>
      ByteData.sublistView(readBytesExact(8)).getFloat64(0, Endian.little);

  // -----------------------------------------------------------------
  // NUL-framed string I/O
  // -----------------------------------------------------------------

  /// Writes a UTF-8 string followed by a single NUL byte.
  void writeString(String value) {
    final bytes = utf8.encode(value);
    final total = bytes.length + 1;
    final ptr = calloc<Uint8>(total);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      ptr[bytes.length] = 0;
      _ensureNotDisposed();
      final written = getBindings().LF_WriteBuffer(_raw, ptr.cast<Void>(), total);
      if (written != total) {
        throw LingoFuseIoError(
          'short write: $written of $total',
          operation: 'writeString',
        );
      }
    } finally {
      calloc.free(ptr);
    }
  }

  /// Reads a UTF-8 string, stopping at the first NUL.
  String readString() {
    final bytes = readBytesUntilNul();
    if (bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }

  // -----------------------------------------------------------------
  // Lifetime
  // -----------------------------------------------------------------

  /// Releases the native handle if owned. Idempotent.
  void dispose() {
    if (_disposed) return;
    if (!_owned) return;
    _disposed = true;
    if (_raw != nullptr) {
      getBindings().LF_FreeData(_raw);
    }
  }
}