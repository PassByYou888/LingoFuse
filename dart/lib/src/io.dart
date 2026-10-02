// Unified JSON / string / byte I/O for LingoFuse data handles.

import 'dart:convert';
import 'dart:typed_data';

import 'data_handle.dart';
import 'errors.dart';

/// The single sanctioned path for structured I/O on a [DataHandle].
class LfIo {
  LfIo._();

  // JSON string helpers (no handle required)

  /// Serializes a value to compact UTF-8 JSON.
  static String dumpsJson(Object? value) {
    try {
      return jsonEncode(value);
    } catch (e) {
      throw LingoFuseIoError('jsonEncode failed: $e', operation: 'dumpsJson');
    }
  }

  /// Parses a UTF-8 JSON string into a value.
  static T loadsJson<T>(String text) {
    try {
      return jsonDecode(text) as T;
    } catch (e) {
      throw LingoFuseIoError('jsonDecode failed: $e', operation: 'loadsJson');
    }
  }

  // String I/O

  static void writeString(DataHandle h, String value) => h.writeString(value);
  static String readString(DataHandle h) => h.readString();

  // Byte I/O

  static void writeStringBytes(DataHandle h, Uint8List data) {
    h.writeBytes(data);
    h.writeUInt8(0);
  }

  static Uint8List readStringBytes(DataHandle h) => h.readBytesUntilNul();
  static Uint8List readAllBytes(DataHandle h) => h.readAllBytes();

  // JSON I/O

  /// Serializes [value] to JSON and writes it with a NUL terminator.
  static void writeJson(DataHandle h, Object? value) {
    h.writeString(dumpsJson(value));
  }

  /// Reads a NUL-framed JSON payload and decodes it.
  static T readJson<T>(DataHandle h) {
    final text = h.readString();
    if (text.isEmpty) {
      throw LingoFuseIoError('empty JSON payload', operation: 'readJson');
    }
    return loadsJson<T>(text);
  }

  /// Non-throwing counterpart of [readJson].
  static T? tryReadJson<T>(DataHandle h) {
    try {
      return readJson<T>(h);
    } catch (_) {
      return null;
    }
  }
}