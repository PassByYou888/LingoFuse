// Process-wide facade over the LingoFuse C ABI (caller side).

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'app_handle.dart';
import 'data_handle.dart';
import 'errors.dart';
import 'runtime.dart';

/// Process-wide facade over the LingoFuse runtime.
class Framework {
  Framework._();

  // -----------------------------------------------------------------
  // Network preparation
  // -----------------------------------------------------------------

  static void resetPrepare() {
    getBindings().LF_ResetPrepare();
  }

  static int prepareService(String listeningAddr, String physicsAddr) {
    final lf = getBindings();
    final listen = listeningAddr.toNativeUtf8().cast<Char>();
    final physics = physicsAddr.toNativeUtf8().cast<Char>();
    try {
      final tag = lf.LF_PrepareService(listen, physics);
      if (tag < 0) {
        throw LingoFuseError(
            'LF_PrepareService rejected "$listeningAddr" (duplicate?)');
      }
      return tag;
    } finally {
      calloc.free(listen);
      calloc.free(physics);
    }
  }

  /// Prepares a C4 client connecting to [physicsAddr].
  ///
  /// Pass [app] to expose an application on the mesh; omit it for a pure
  /// consumer.
  static int prepareClient(String physicsAddr, {AppHandle? app}) {
    final lf = getBindings();
    final addr = physicsAddr.toNativeUtf8().cast<Char>();
    final Pointer<Void> appHnd = (app == null) ? nullptr : app.raw;
    try {
      final tag = lf.LF_PrepareClient(addr, appHnd);
      if (tag < 0) {
        throw LingoFuseError(
            'LF_PrepareClient rejected "$physicsAddr" (duplicate?)');
      }
      return tag;
    } finally {
      calloc.free(addr);
    }
  }

  static bool prepareDone() {
    return getBindings().LF_PrepareDone() == 1;
  }

  static void exitMainThread() {
    getBindings().LF_ExitMainThread();
  }

  static void shutdown() {
    getBindings().LF_Shutdown();
  }

  // -----------------------------------------------------------------
  // Runtime options
  // -----------------------------------------------------------------

  static void setOption(String option, String value) {
    final lf = getBindings();
    final cOpt = option.toNativeUtf8().cast<Char>();
    final cVal = value.toNativeUtf8().cast<Char>();
    try {
      lf.LF_SetOption(cOpt, cVal);
    } finally {
      calloc.free(cOpt);
      calloc.free(cVal);
    }
  }

  static String generateAppName() {
    final ptr = getBindings().LF_Generate_AppName();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  // -----------------------------------------------------------------
  // Health checks
  // -----------------------------------------------------------------

  static bool checkMainThread() {
    return getBindings().LF_CheckMainThread() != 0;
  }

  static bool checkApp(String appName) {
    final c = appName.toNativeUtf8().cast<Char>();
    try {
      return getBindings().LF_CheckApp(c) != 0;
    } finally {
      calloc.free(c);
    }
  }

  static bool checkApi(String appName, String apiName) {
    final c1 = appName.toNativeUtf8().cast<Char>();
    final c2 = apiName.toNativeUtf8().cast<Char>();
    try {
      return getBindings().LF_CheckApi(c1, c2) != 0;
    } finally {
      calloc.free(c1);
      calloc.free(c2);
    }
  }

  // -----------------------------------------------------------------
  // Remote invocation
  // -----------------------------------------------------------------

  static DataHandle call(
    String appName,
    DataHandle param, {
    int timeoutMs = 5000,
  }) {
    final lf = getBindings();
    final cName = appName.toNativeUtf8().cast<Char>();
    try {
      final res = lf.LF_Call(cName, param.raw, timeoutMs);
      if (res == nullptr) {
        throw LingoFuseCallError(
          'LF_Call returned a null handle',
          targetApp: appName,
        );
      }
      return DataHandle.fromRaw(res, owned: true);
    } finally {
      calloc.free(cName);
    }
  }

  static DataHandle? tryCall(
    String appName,
    DataHandle param, {
    int timeoutMs = 5000,
  }) {
    final resp = call(appName, param, timeoutMs: timeoutMs);
    if (resp.size == 0) {
      resp.dispose();
      return null;
    }
    return resp;
  }

  static void notify(String appName, DataHandle param) {
    final lf = getBindings();
    final cName = appName.toNativeUtf8().cast<Char>();
    try {
      lf.LF_Notify(cName, param.raw);
    } finally {
      calloc.free(cName);
    }
  }

  static void sequencedNotify(String appName, DataHandle param) {
    final lf = getBindings();
    final cName = appName.toNativeUtf8().cast<Char>();
    try {
      lf.LF_Sequenced_Notify(cName, param.raw);
    } finally {
      calloc.free(cName);
    }
  }
}