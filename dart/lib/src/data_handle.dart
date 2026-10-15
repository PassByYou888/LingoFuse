// RAII wrapper around a native LingoFuse data handle (TDataHnd).
//
// TWO I/O PATHS
// -------------
// The existing byte / scalar / string I/O methods use the legacy
// direct-FFI path (getBindings()). They work whether or not the C
// bridge has been started.
//
// The four methods added in v2 -- getP2PUid, getP2PName, writeUid,
// readUid -- are bridge-only because they need the C bridge's
// marshalling:
//
//   * getP2PUid / getP2PName dereference a transient library-owned
//     pointer that must be copied immediately. The bridge does the
//     copy; the legacy path would require Dart to reason about a
//     ~5-second pointer validity window.
//
//   * writeUid / readUid hide the ARGUMENT-role TP2P_UID struct,
//     which Dart FFI cannot pass by value.
//
// Calling these four methods without an active BridgeHost throws
// StateError. This is by design: the bridge is the single supported
// path for identity and UID I/O, and making its availability explicit
// avoids a silent fallback to a fragile code path.
//
// All diagnostics are in English.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bridge/bridge_error.dart';
import 'bridge/bridge_ffi.dart';
import 'bridge/bridge_host.dart';
import 'errors.dart';
import 'runtime.dart';

/// RAII wrapper around a native LingoFuse data handle.
///
/// A handle is either OWNING or BORROWING. Owning handles are created
/// by the public constructor or by [DataHandle.createPermanent] and are
/// released by [dispose]. Borrowing handles are created by
/// [DataHandle.fromRaw] with `owned: false`, typically inside a
/// callback, and are released by the framework.
class DataHandle {
  final Pointer<Void> _raw;
  final bool _owned;
  bool _disposed = false;

  DataHandle._(this._raw, this._owned);

  /// Creates a new auto-recycled data handle bound to the given API name.
  ///
  /// The handle is added to the library's idle pool. It is released by
  /// [dispose] (which marks it for release) or by the idle reclaimer
  /// after 10 minutes of inactivity.
  ///
  /// Uses the legacy direct-FFI path: no BridgeHost required.
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

  /// Creates a new PERMANENT data handle bound to the given API name.
  ///
  /// The handle is NOT added to the idle pool. It is released only by
  /// an explicit [dispose], which acts synchronously.
  ///
  /// Uses the legacy direct-FFI path: no BridgeHost required.
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

  /// Wraps an existing raw handle.
  ///
  /// Pass `owned: false` inside a callback: the framework owns the
  /// handle and will release it when the callback returns.
  ///
  /// Also used by [BridgeHost] when a Protocol-A callback delivers a
  /// borrowed input or output handle.
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

  // =================================================================
  // Position and size
  // =================================================================

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

  // =================================================================
  // Byte I/O
  // =================================================================

  /// Appends raw bytes at the current cursor. Cursor advances by the
  /// number of bytes written; the buffer grows as needed.
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

  /// Reads up to [count] bytes. Returns fewer bytes at end-of-buffer.
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

  /// Reads exactly [count] bytes. Throws on short read and restores
  /// the cursor to its original position.
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

  /// Reads all remaining bytes. Cursor advances to the end.
  Uint8List readAllBytes() {
    _ensureNotDisposed();
    final pos = position;
    final total = size;
    if (pos >= total) return Uint8List(0);
    return readBytes(total - pos);
  }

  /// Reads raw bytes up to the first NUL, or the end of the buffer.
  ///
  /// Advances the cursor past the NUL, or to `size + 1` when no NUL is
  /// found. This matches the fault-tolerant read semantics shared by
  /// every LingoFuse binding.
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

  // =================================================================
  // Scalar I/O (little-endian)
  // =================================================================

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

  // =================================================================
  // NUL-framed string I/O
  // =================================================================

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

  // =================================================================
  // P2P identity (bridge-only)
  // =================================================================

  /// Returns the sender's 32-byte session UID.
  ///
  /// {!!!!!  SIDE DATA, NOT A HANDLE PROPERTY  !!!!!}
  /// This reads the FromUID field that the SENDER'S transport layer
  /// injects automatically before transmission. It is valid ONLY on an
  /// INPUT handle (the argument of a registered Call / Notify
  /// callback). On an output handle or on a caller-created handle it
  /// returns 32 zero bytes.
  ///
  /// Requires an active BridgeHost. Throws [StateError] otherwise.
  ///
  /// The returned [Uint8List] is a fresh copy; it is safe to retain
  /// indefinitely.
  Uint8List getP2PUid() {
    _ensureNotDisposed();
    _ensureBridgeAvailable('getP2PUid');

    final ffi = BridgeFfi.instance;
    final buf = calloc<Uint8>(32);
    try {
      final rc = ffi.lfBridgeGetP2PUid(_raw, buf);
      if (rc != BridgeErrorCode.ok) {
        throw BridgeException(
          rc,
          _readBridgeError(ffi),
          operation: 'getP2PUid',
        );
      }
      return Uint8List.fromList(buf.asTypedList(32));
    } finally {
      calloc.free(buf);
    }
  }

  /// Returns the sender's P2P group name as a Dart string.
  ///
  /// Same side-data semantics as [getP2PUid]: valid ONLY on an input
  /// handle. Returns an empty string when the sender did not declare a
  /// P2P name (a legitimate configuration).
  ///
  /// Requires an active BridgeHost. Throws [StateError] otherwise.
  String getP2PName() {
    _ensureNotDisposed();
    _ensureBridgeAvailable('getP2PName');

    final ffi = BridgeFfi.instance;
    // Use a large enough buffer to hold any realistic P2P name. The
    // bridge copies into the caller's buffer, and P2P names are
    // user-defined short identifiers, not arbitrary payloads.
    const int kBufSize = 4096;
    final buf = calloc<Char>(kBufSize);
    try {
      final rc = ffi.lfBridgeGetP2PName(_raw, buf, kBufSize);
      if (rc != BridgeErrorCode.ok &&
          rc != BridgeErrorCode.bufferTooSmall) {
        throw BridgeException(
          rc,
          _readBridgeError(ffi),
          operation: 'getP2PName',
        );
      }
      return buf.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buf);
    }
  }

  // =================================================================
  // UID binary I/O (bridge-only)
  // =================================================================

  /// Appends the 32-byte UID at the current cursor. No terminator.
  ///
  /// Requires an active BridgeHost. Throws [StateError] otherwise.
  void writeUid(Uint8List uid) {
    _ensureNotDisposed();
    if (uid.length != 32) {
      throw RangeError(
          'UID must be exactly 32 bytes, got ${uid.length}.');
    }
    _ensureBridgeAvailable('writeUid');

    final ffi = BridgeFfi.instance;
    final buf = calloc<Uint8>(32);
    try {
      buf.asTypedList(32).setAll(0, uid);
      final rc = ffi.lfBridgeWriteUid(_raw, buf);
      if (rc != BridgeErrorCode.ok) {
        throw BridgeException(
          rc,
          _readBridgeError(ffi),
          operation: 'writeUid',
        );
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// Reads exactly 32 bytes from the current cursor as a UID. No
  /// terminator is consumed. Throws [LingoFuseIoError] on a short read.
  ///
  /// Requires an active BridgeHost. Throws [StateError] otherwise.
  Uint8List readUid() {
    _ensureNotDisposed();
    _ensureBridgeAvailable('readUid');

    final ffi = BridgeFfi.instance;
    final buf = calloc<Uint8>(32);
    try {
      final rc = ffi.lfBridgeReadUid(_raw, buf);
      if (rc != BridgeErrorCode.ok) {
        throw LingoFuseIoError(
          'readUid failed with bridge code $rc',
          operation: 'readUid',
        );
      }
      return Uint8List.fromList(buf.asTypedList(32));
    } finally {
      calloc.free(buf);
    }
  }

  // =================================================================
  // Internal helpers
  // =================================================================

  void _ensureBridgeAvailable(String operation) {
    if (BridgeHost.instanceOrNull == null) {
      throw StateError(
        '$operation requires the bridge layer. '
        'Call "await BridgeHost.start()" before using it.',
      );
    }
  }

  String _readBridgeError(BridgeFfi ffi) {
    final ptr = ffi.lfBridgeLastError();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  // =================================================================
  // Lifetime
  // =================================================================

  /// Releases the native handle if owned. Idempotent.
  ///
  /// For an owning auto-recycled handle, this only marks the handle as
  /// deleted; the actual release happens on the next pool scan (at
  /// most 5 seconds later). For a permanent handle, the release is
  /// synchronous. For a borrowing handle, this is a no-op.
  void dispose() {
    if (_disposed) return;
    if (!_owned) return;
    _disposed = true;
    if (_raw != nullptr) {
      getBindings().LF_FreeData(_raw);
    }
  }
}