// Unified JSON / string / byte I/O for LingoFuse data handles.
//
// This module is the single sanctioned path for structured I/O on a
// DataHandle. It mirrors lf_io.hpp (C++), LfIo.cs (C#), and lf-io.js
// (JavaScript) one-to-one:
//
//   * Strings are UTF-8 and framed with a trailing NUL byte.
//   * JSON is compact, literal UTF-8, no \uXXXX escapes.
//   * Reads are fault-tolerant: a payload without a trailing NUL is
//     consumed to the end of the buffer, matching the semantics of
//     every other LingoFuse binding.
//
// All diagnostics are in English.

import 'dart:convert';
import 'dart:typed_data';

import 'data_handle.dart';
import 'errors.dart';

/// The single sanctioned path for structured I/O on a [DataHandle].
class LfIo {
  LfIo._();

  // =================================================================
  // JSON string helpers (no handle required)
  // =================================================================

  /// Serializes a value to compact UTF-8 JSON.
  ///
  /// Dart's jsonEncode already emits compact output and leaves
  /// non-ASCII characters as literal UTF-8 code points; the subsequent
  /// UTF-8 encoding happens at the [writeJson] boundary. This matches
  /// the Python (ensure_ascii=False) and C# (UnsafeRelaxedJsonEscaping)
  /// producers byte-for-byte for the same logical value.
  static String dumpsJson(Object? value) {
    try {
      return jsonEncode(value);
    } catch (e) {
      throw LingoFuseIoError('jsonEncode failed: $e', operation: 'dumpsJson');
    }
  }

  /// Parses a UTF-8 JSON string into a value.
  ///
  /// Throws [LingoFuseIoError] on invalid JSON.
  static T loadsJson<T>(String text) {
    try {
      return jsonDecode(text) as T;
    } catch (e) {
      throw LingoFuseIoError('jsonDecode failed: $e', operation: 'loadsJson');
    }
  }

  // =================================================================
  // String I/O (NUL-framed UTF-8)
  // =================================================================

  /// Writes a UTF-8 string followed by a single NUL byte.
  static void writeString(DataHandle h, String value) => h.writeString(value);

  /// Reads a UTF-8 string, stopping at the first NUL or the end of the
  /// buffer.
  static String readString(DataHandle h) => h.readString();

  // =================================================================
  // Byte I/O (NUL-framed raw bytes)
  // =================================================================

  /// Writes a raw byte sequence followed by a single NUL byte.
  ///
  /// Embedded NUL bytes in [data] are preserved; the appended NUL is
  /// an additional framing byte.
  static void writeStringBytes(DataHandle h, Uint8List data) {
    h.writeBytes(data);
    h.writeUInt8(0);
  }

  /// Reads raw bytes up to the first NUL, or the end of the buffer.
  static Uint8List readStringBytes(DataHandle h) => h.readBytesUntilNul();

  /// Reads all remaining bytes without NUL handling.
  static Uint8List readAllBytes(DataHandle h) => h.readAllBytes();

  // =================================================================
  // JSON I/O (NUL-framed JSON)
  // =================================================================

  /// Serializes [value] to JSON and writes it with a NUL terminator.
  static void writeJson(DataHandle h, Object? value) {
    h.writeString(dumpsJson(value));
  }

  /// Reads a NUL-framed JSON payload and decodes it.
  ///
  /// Throws [LingoFuseIoError] when the payload is empty or not valid
  /// JSON.
  static T readJson<T>(DataHandle h) {
    final text = h.readString();
    if (text.isEmpty) {
      throw LingoFuseIoError('empty JSON payload', operation: 'readJson');
    }
    return loadsJson<T>(text);
  }

  /// Non-throwing counterpart of [readJson].
  ///
  /// Returns null when the payload is empty, not valid JSON, or not
  /// decodable. The cursor is advanced regardless of whether the parse
  /// succeeded; this matches the historical behaviour of the C++ and
  /// JavaScript wrappers.
  ///
  /// Use this for probing or for optional JSON fields where absence is
  /// a legitimate outcome.
  static T? tryReadJson<T>(DataHandle h) {
    try {
      return readJson<T>(h);
    } catch (_) {
      return null;
    }
  }
}