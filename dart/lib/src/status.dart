// Status queue helpers for the LingoFuse runtime.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'runtime.dart';

/// Process-wide status queue and health-check helpers.
class LingoFuseStatus {
  LingoFuseStatus._();

  static int getStatusCount() {
    return getBindings().LF_GetStatusCount();
  }

  static String getStatus() {
    final ptr = getBindings().LF_GetStatus();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  static List<String> drainStatus([int maxMessages = 64]) {
    if (maxMessages <= 0) return const [];
    final pending = getStatusCount();
    if (pending <= 0) return const [];
    final count = pending < maxMessages ? pending : maxMessages;
    final out = <String>[];
    for (int i = 0; i < count; i++) {
      final msg = getStatus();
      if (msg.isEmpty) break;
      out.add(msg);
    }
    return out;
  }

  static void postStatus(String message) {
    final c = message.toNativeUtf8().cast<Char>();
    try {
      getBindings().LF_PostStatus(c);
    } finally {
      calloc.free(c);
    }
  }
}