// Process-wide facade over the LingoFuse runtime.
//
// TWO ROUTING PATHS
// -----------------
// The original sync methods (call / notify / prepareDone / ...) use the
// legacy direct-FFI path. They work without the C bridge and preserve
// the exact v1.x semantics, so existing applications can continue to
// use them unchanged.
//
// The UID and P2PName addressing families, the asynchronous call
// family, and the typed option accessors were added in v2. They route
// through BridgeHost because:
//
//   * Dart's FFI layer cannot reliably pass the ARGUMENT-role TP2P_UID
//     struct by value. The bridge repacks a 32-byte pointer into the
//     exact struct layout the Pascal side expects.
//
//   * Dart's NativeCallable is asynchronous for cross-thread invocations,
//     but LingoFuse expects synchronous callbacks. The bridge resolves
//     this by blocking the native worker until Dart replies.
//
//   * The asynchronous call family and network events use a
//     fire-and-forget channel that the bridge posts to the Dart
//     isolate. There is no way to express this through raw FFI.
//
// All diagnostics are in English.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'app_handle.dart';
import 'bridge/bridge_error.dart';
import 'bridge/bridge_ffi.dart';
import 'bridge/bridge_host.dart';
import 'data_handle.dart';
import 'errors.dart';
import 'runtime.dart';

/// Process-wide facade over the LingoFuse runtime.
///
/// All members are static. The class is not instantiable.
class Framework {
  Framework._();

  // =================================================================
  // Network preparation
  // =================================================================

  /// Clears any previously prepared services and clients.
  ///
  /// Running services and clients are unaffected; only the preparation
  /// queue is reset. Call this before preparing a new set to avoid
  /// "repeat listen/connection" errors.
  static void resetPrepare() {
    getBindings().LF_ResetPrepare();
  }

  /// Prepares a C4 service.
  ///
  /// [listeningAddr] is the local binding address
  /// (e.g. "0.0.0.0:9898" or "ipc:my_service").
  /// [physicsAddr] is the address advertised to clients.
  ///
  /// Returns a tag ID (>= 1) on success. Throws [LingoFuseError] if the
  /// address is a duplicate.
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
  /// Pass [app] to expose an application on the mesh, or omit it for a
  /// pure consumer.
  ///
  /// Returns a tag ID (>= 1) on success. Throws [LingoFuseError] if the
  /// address is a duplicate and Overlap_Connection is disabled.
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

  /// Starts the framework with all prepared services and clients.
  ///
  /// Returns true on the FIRST successful call. A second call in the
  /// same process (without an intervening shutdown) returns false; this
  /// is NOT a failure.
  static bool prepareDone() {
    return getBindings().LF_PrepareDone() == 1;
  }

  /// Requests the simulated main thread to exit gracefully.
  ///
  /// WARNING: this also flushes the data handle pool, releasing every
  /// outstanding handle - including permanent ones. Do not use any data
  /// handle after this call.
  static void exitMainThread() {
    getBindings().LF_ExitMainThread();
  }

  /// Full LingoFuse shutdown.
  ///
  /// Distinct from BridgeHost.stop(), which only tears down the bridge.
  /// This releases the framework itself. Safe to call multiple times.
  static void shutdown() {
    getBindings().LF_Shutdown();
  }

  // =================================================================
  // Options: string-typed legacy interface
  // =================================================================

  /// Adjusts a global runtime option.
  ///
  /// Option names are case-insensitive. Unknown option names are
  /// silently ignored by the native layer. Changes are not persisted
  /// across [shutdown].
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

  /// Reads a global runtime option.
  ///
  /// Returns an empty string when:
  ///   - the option name is unknown, or
  ///   - the bridge layer has not been started.
  ///
  /// The `get` path routes through the bridge because the legacy
  /// direct-FFI bindings (bindings_generated.dart) do not expose
  /// `LF_GetOption`. The `set` path ([setOption]) remains on the legacy
  /// path so that options can be configured BEFORE the framework starts,
  /// which is the normal order of operations.
  ///
  /// If you need to read options before starting the framework, call
  /// `await BridgeHost.start()` first; the bridge loads LingoFuse
  /// itself, and no other framework state is required to read an
  /// option.
  static String getOption(String option) {
    final bridge = BridgeHost.instanceOrNull;
    if (bridge == null) {
      // The bridge layer is not active. Return an empty string rather
      // than throwing: option reads are commonly treated as probes, and
      // an unavailable value is best reported as "empty" instead of as
      // an exception. Callers that need to distinguish "unknown option"
      // from "bridge not started" should check BridgeHost.instanceOrNull
      // themselves.
      return '';
    }

    final ffi = BridgeFfi.instance;
    const int kBufSize = 4096;
    final cOpt = option.toNativeUtf8().cast<Char>();
    final buf = calloc<Char>(kBufSize);
    try {
      final rc = ffi.lfBridgeGetOption(cOpt, buf, kBufSize);
      if (rc != BridgeErrorCode.ok &&
          rc != BridgeErrorCode.bufferTooSmall) {
        return '';
      }
      return buf.cast<Utf8>().toDartString();
    } finally {
      calloc.free(cOpt);
      calloc.free(buf);
    }
  }

  // -----------------------------------------------------------------
  // Internal: typed option helpers
  // -----------------------------------------------------------------

  static bool _getBoolOption(String key) {
    final v = getOption(key);
    if (v.isEmpty) return false;
    final lower = v.toLowerCase();
    return lower == 'true' || lower == '1' || lower == 'yes';
  }

  static void _setBoolOption(String key, bool value) {
    setOption(key, value ? 'True' : 'False');
  }

  static int _getIntOption(String key) {
    final v = getOption(key);
    if (v.isEmpty) return 0;
    return int.tryParse(v) ?? 0;
  }

  static void _setIntOption(String key, int value) {
    setOption(key, value.toString());
  }

  // -----------------------------------------------------------------
  // Typed option shortcuts
  // -----------------------------------------------------------------

  // -- Authentication --

  /// Set the P2PVM / C4 network authentication password.
  static void setOptPassword(String value) => setOption('password', value);

  /// Read the configured password. The native side returns a fixed mask
  /// ("********"), never the real value.
  static String getOptPassword() => getOption('password');

  // -- Logging and diagnostics --

  /// Execute a C4 console debug command. Write-only; each call
  /// constructs a transient helper object on the Pascal side.
  static void setOptDebug(String value) => setOption('debug', value);

  /// Read the debug option. Returns a fixed placeholder because the
  /// option is write-only.
  static String getOptDebug() => getOption('debug');

  /// Enable or disable quiet mode.
  static void setOptQuiet(bool value) => _setBoolOption('Quiet', value);

  /// True when quiet mode is enabled.
  static bool getOptQuiet() => _getBoolOption('Quiet');

  /// Enable or disable thread-ID prefixes in status output.
  static void setOptShowThreadID(bool value) =>
      _setBoolOption('ShowThreadID', value);

  /// True when thread-ID prefixes are enabled.
  static bool getOptShowThreadID() => _getBoolOption('ShowThreadID');

  /// Enable or disable console output for status messages.
  static void setOptConsoleOutput(bool value) =>
      _setBoolOption('ConsoleOutput', value);

  /// True when console output is enabled.
  static bool getOptConsoleOutput() => _getBoolOption('ConsoleOutput');

  // -- Connection readiness --

  /// Allow or forbid multiple client tunnels to the same address.
  static void setOptOverlapConnection(bool value) =>
      _setBoolOption('Overlap_Connection', value);

  /// True when overlapping connections are allowed.
  static bool getOptOverlapConnection() =>
      _getBoolOption('Overlap_Connection');

  /// Control whether [prepareDone] blocks until every prepared client is
  /// online.
  static void setOptWaitConnectionReadyOk(bool value) =>
      _setBoolOption('Wait_Connection_ReadyOk', value);

  /// True when [prepareDone] waits for all clients.
  static bool getOptWaitConnectionReadyOk() =>
      _getBoolOption('Wait_Connection_ReadyOk');

  /// Set the [prepareDone] wait timeout, in milliseconds.
  static void setOptWaitConnectionTimeout(int valueMs) =>
      _setIntOption('Wait_Connection_Timeout', valueMs);

  /// The current [prepareDone] wait timeout, in milliseconds.
  static int getOptWaitConnectionTimeout() =>
      _getIntOption('Wait_Connection_Timeout');

  // -- IPC --

  /// Set the IPC server thread-pool size.
  static void setOptIpcServThreadCount(int value) =>
      _setIntOption('IPC_Serv_ThreadCount', value);

  /// The configured IPC server thread count.
  static int getOptIpcServThreadCount() =>
      _getIntOption('IPC_Serv_ThreadCount');

  /// Set the IPC inbound queue length.
  static void setOptIpcServMaxQueueLength(int value) =>
      _setIntOption('IPC_Serv_MaxQueueLength', value);

  /// The configured IPC max queue length.
  static int getOptIpcServMaxQueueLength() =>
      _getIntOption('IPC_Serv_MaxQueueLength');

  /// Set the maximum IPC message size, in bytes.
  static void setOptIpcServMaxMsgSize(int value) =>
      _setIntOption('IPC_Serv_MaxMsgSize', value);

  /// The configured IPC max message size.
  static int getOptIpcServMaxMsgSize() =>
      _getIntOption('IPC_Serv_MaxMsgSize');

  // -- Sequenced notifications --

  /// Set the sticky-affinity window for P2PName load balancing, in ms.
  static void setOptFixedSequencedTime(int valueMs) =>
      _setIntOption('Fixed_Sequenced_Time', valueMs);

  /// The current sticky-affinity window, in milliseconds.
  static int getOptFixedSequencedTime() =>
      _getIntOption('Fixed_Sequenced_Time');

  // -- P2P group name --

  /// Set this process's P2P group name.
  ///
  /// Not to be confused with DataHandle.getP2PName, which reads the
  /// SENDER's name from an input handle. This function declares the
  /// LOCAL identity.
  static void setOptP2PName(String value) => setOption('LF_P2P_name', value);

  /// This process's configured P2P group name.
  static String getOptP2PName() => getOption('LF_P2P_name');

  // -- Data handle pool --

  /// Set the idle-reclaim threshold for auto-recycled handles, in ms.
  static void setOptDataHandleIdleTimeout(int valueMs) =>
      _setIntOption('DataHandle_Idle_Timeout', valueMs);

  /// The current data-handle idle-reclaim threshold, in milliseconds.
  static int getOptDataHandleIdleTimeout() =>
      _getIntOption('DataHandle_Idle_Timeout');

  /// Set the minimum interval between two consecutive pool scans, in ms.
  static void setOptDataHandlePoolScanInterval(int valueMs) =>
      _setIntOption('DataHandle_Pool_Scan_Interval', valueMs);

  /// The current data-handle pool scan interval, in milliseconds.
  static int getOptDataHandlePoolScanInterval() =>
      _getIntOption('DataHandle_Pool_Scan_Interval');

  // -- Command flushing --

  /// Set the null-flush threshold for no-response commands.
  ///
  /// Note the historical spelling "Reponse" (no second 's'); the option
  /// key and the native symbol use it intentionally.
  static void setOptNoReponseCmdNullFlushThreshold(int value) =>
      _setIntOption('No_Reponse_Cmd_NULL_Flush_Threshold', value);

  /// The current null-flush threshold.
  static int getOptNoReponseCmdNullFlushThreshold() =>
      _getIntOption('No_Reponse_Cmd_NULL_Flush_Threshold');

  // =================================================================
  // Application name generation
  // =================================================================

  /// Generates a globally unique application name.
  ///
  /// Must be called after [prepareDone] has returned true. The generated
  /// name includes C4 tunnel addresses, process name with PID, and a
  /// high-resolution timestamp.
  ///
  /// Returns an empty string on failure.
  static String generateAppName() {
    final ptr = getBindings().LF_Generate_AppName();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  // =================================================================
  // Health checks
  // =================================================================

  /// True when the simulated main thread is currently running.
  static bool checkMainThread() {
    return getBindings().LF_CheckMainThread() != 0;
  }

  /// Probes whether an application with the given name is available.
  ///
  /// The lookup is cached and typically ~3 seconds stale. Use it as a
  /// probing tool, not an authoritative existence test.
  static bool checkApp(String appName) {
    final c = appName.toNativeUtf8().cast<Char>();
    try {
      return getBindings().LF_CheckApp(c) != 0;
    } finally {
      calloc.free(c);
    }
  }

  /// Probes whether the named API is available for the given app.
  ///
  /// Same cache caveat as [checkApp].
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

  // =================================================================
  // Synchronous invocation by App name (legacy FFI)
  // =================================================================

  /// Calls a remote API synchronously and waits for the response.
  ///
  /// On timeout or failure, an EMPTY data handle (size 0) is returned,
  /// NOT a NULL pointer. Always check `result.size > 0` to detect
  /// failures. Callers who want a null contract should use [tryCall].
  ///
  /// Note: this blocks the calling thread. Do NOT call it from the Dart
  /// main isolate if the timeout is long; the event loop will stall and
  /// bridge callbacks cannot be delivered. Use [callAsync] instead, or
  /// run this from a worker isolate.
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

  /// Calls a remote API synchronously, returning null on timeout or
  /// unreachable target.
  ///
  /// This is the recommended convenience wrapper. When the call
  /// succeeds, the caller is responsible for disposing the result.
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

  /// Sends a one-way notification.
  ///
  /// Order of delivery is NOT guaranteed. Use [sequencedNotify] for FIFO
  /// ordering per (app, api) pair.
  static void notify(String appName, DataHandle param) {
    final lf = getBindings();
    final cName = appName.toNativeUtf8().cast<Char>();
    try {
      lf.LF_Notify(cName, param.raw);
    } finally {
      calloc.free(cName);
    }
  }

  /// Sends a one-way notification with FIFO ordering per (app, api)
  /// pair.
  static void sequencedNotify(String appName, DataHandle param) {
    final lf = getBindings();
    final cName = appName.toNativeUtf8().cast<Char>();
    try {
      lf.LF_Sequenced_Notify(cName, param.raw);
    } finally {
      calloc.free(cName);
    }
  }

  // =================================================================
  // Synchronous invocation by UID (bridge)
  // =================================================================

  /// Calls a remote API synchronously by UID.
  ///
  /// [uid] must be exactly 32 bytes. The call routes to the exact client
  /// whose TunnelLink produced the given UID, and can invoke any API
  /// the target registered, without requiring the caller to know the
  /// target App name.
  ///
  /// Requires an active BridgeHost. Throws [StateError] otherwise.
  ///
  /// On timeout or unreachable target, an EMPTY handle (size 0) is
  /// returned. Use [tryUidCall] for a null contract.
  static DataHandle uidCall(
    Uint8List uid,
    DataHandle param, {
    int timeoutMs = 5000,
  }) {
    _checkUidLength(uid);
    _ensureBridge('uidCall');

    final ffi = BridgeFfi.instance;
    final uidPtr = calloc<Uint8>(32);
    try {
      uidPtr.asTypedList(32).setAll(0, uid);
      final res = ffi.lfBridgeUidCall(uidPtr, param.raw, timeoutMs);
      if (res == nullptr) {
        throw LingoFuseCallError(
          'LF_UID_Call returned a null handle',
          targetApp: null,
        );
      }
      return DataHandle.fromRaw(res, owned: true);
    } finally {
      calloc.free(uidPtr);
    }
  }

  /// Calls a remote API synchronously by UID, returning null on timeout
  /// or unreachable target.
  static DataHandle? tryUidCall(
    Uint8List uid,
    DataHandle param, {
    int timeoutMs = 5000,
  }) {
    final resp = uidCall(uid, param, timeoutMs: timeoutMs);
    if (resp.size == 0) {
      resp.dispose();
      return null;
    }
    return resp;
  }

  /// Sends a one-way notification by UID.
  ///
  /// [uid] must be exactly 32 bytes. Requires an active BridgeHost.
  static void uidNotify(Uint8List uid, DataHandle param) {
    _checkUidLength(uid);
    _ensureBridge('uidNotify');

    final ffi = BridgeFfi.instance;
    final uidPtr = calloc<Uint8>(32);
    try {
      uidPtr.asTypedList(32).setAll(0, uid);
      ffi.lfBridgeUidNotify(uidPtr, param.raw);
    } finally {
      calloc.free(uidPtr);
    }
  }

  /// Sends a FIFO-ordered one-way notification by UID.
  static void uidSequencedNotify(Uint8List uid, DataHandle param) {
    _checkUidLength(uid);
    _ensureBridge('uidSequencedNotify');

    final ffi = BridgeFfi.instance;
    final uidPtr = calloc<Uint8>(32);
    try {
      uidPtr.asTypedList(32).setAll(0, uid);
      ffi.lfBridgeUidSequencedNotify(uidPtr, param.raw);
    } finally {
      calloc.free(uidPtr);
    }
  }

  // =================================================================
  // Synchronous invocation by P2PName (bridge)
  // =================================================================

  /// Calls a remote API synchronously by P2P group name.
  ///
  /// Routing is NOT local-first: the call is always forwarded to the
  /// server for dispatch. The server-side dispatcher picks a target
  /// using the mesh's load-balancing state.
  ///
  /// Requires an active BridgeHost.
  static DataHandle p2pnameCall(
    String p2pName,
    DataHandle param, {
    int timeoutMs = 5000,
  }) {
    _ensureBridge('p2pnameCall');

    final ffi = BridgeFfi.instance;
    final cP2P = p2pName.toNativeUtf8().cast<Char>();
    try {
      final res = ffi.lfBridgeP2PNameCall(cP2P, param.raw, timeoutMs);
      if (res == nullptr) {
        throw LingoFuseCallError(
          'LF_P2PNAME_Call returned a null handle',
          targetApp: p2pName,
        );
      }
      return DataHandle.fromRaw(res, owned: true);
    } finally {
      calloc.free(cP2P);
    }
  }

  /// Calls a remote API synchronously by P2PName, returning null on
  /// timeout or unreachable group.
  static DataHandle? tryP2pnameCall(
    String p2pName,
    DataHandle param, {
    int timeoutMs = 5000,
  }) {
    final resp = p2pnameCall(p2pName, param, timeoutMs: timeoutMs);
    if (resp.size == 0) {
      resp.dispose();
      return null;
    }
    return resp;
  }

  /// Sends a one-way notification by P2P group name.
  static void p2pnameNotify(String p2pName, DataHandle param) {
    _ensureBridge('p2pnameNotify');

    final ffi = BridgeFfi.instance;
    final cP2P = p2pName.toNativeUtf8().cast<Char>();
    try {
      ffi.lfBridgeP2PNameNotify(cP2P, param.raw);
    } finally {
      calloc.free(cP2P);
    }
  }

  /// Sends a FIFO-ordered one-way notification by P2P group name.
  static void p2pnameSequencedNotify(String p2pName, DataHandle param) {
    _ensureBridge('p2pnameSequencedNotify');

    final ffi = BridgeFfi.instance;
    final cP2P = p2pName.toNativeUtf8().cast<Char>();
    try {
      ffi.lfBridgeP2PNameSequencedNotify(cP2P, param.raw);
    } finally {
      calloc.free(cP2P);
    }
  }

  // =================================================================
  // Asynchronous invocation (bridge)
  // =================================================================
  //
  // Each method below issues the request and returns immediately. The
  // [onResult] callback is invoked exactly once:
  //
  //   * asynchronously on the Dart event loop when the reply arrives;
  //   * synchronously on the caller's stack if the request could not
  //     be dispatched.
  //
  // In both cases, exactly one of the callback's arguments is non-null.
  // This single error path makes the following idiom work without any
  // await/async seam:
  //
  //     Framework.callAsync('Server', param, (result, error) {
  //         if (error != null) { handleError(error); return; }
  //         handleResult(result!);
  //     });
  //
  // The bridge copies the request payload synchronously inside the
  // dispatch call, so [param] may be disposed immediately after this
  // method returns.

  /// Issues an asynchronous call by App name.
  static void callAsync(
    String appName,
    DataHandle param,
    AsyncResultHandler onResult,
  ) {
    _ensureBridge('callAsync');
    BridgeHost.instance.callAsync(appName, param.raw, onResult);
  }

  /// Issues an asynchronous call by App name with FIFO ordering per
  /// (app, api) pair.
  static void callAsyncSequenced(
    String appName,
    DataHandle param,
    AsyncResultHandler onResult,
  ) {
    _ensureBridge('callAsyncSequenced');
    BridgeHost.instance.callAsyncSequenced(appName, param.raw, onResult);
  }

  /// Issues an asynchronous call by UID.
  ///
  /// [uid] must be exactly 32 bytes.
  static void uidCallAsync(
    Uint8List uid,
    DataHandle param,
    AsyncResultHandler onResult,
  ) {
    _checkUidLength(uid);
    _ensureBridge('uidCallAsync');
    BridgeHost.instance.uidCallAsync(uid, param.raw, onResult);
  }

  /// Issues an asynchronous call by UID with FIFO ordering per
  /// (uid, api) pair.
  ///
  /// [uid] must be exactly 32 bytes.
  static void uidCallAsyncSequenced(
    Uint8List uid,
    DataHandle param,
    AsyncResultHandler onResult,
  ) {
    _checkUidLength(uid);
    _ensureBridge('uidCallAsyncSequenced');
    BridgeHost.instance.uidCallAsyncSequenced(uid, param.raw, onResult);
  }

  /// Issues an asynchronous call by P2PName.
  static void p2pnameCallAsync(
    String p2pName,
    DataHandle param,
    AsyncResultHandler onResult,
  ) {
    _ensureBridge('p2pnameCallAsync');
    BridgeHost.instance.p2pnameCallAsync(p2pName, param.raw, onResult);
  }

  /// Issues an asynchronous call by P2PName with FIFO ordering per
  /// (group, api) pair.
  static void p2pnameCallAsyncSequenced(
    String p2pName,
    DataHandle param,
    AsyncResultHandler onResult,
  ) {
    _ensureBridge('p2pnameCallAsyncSequenced');
    BridgeHost.instance.p2pnameCallAsyncSequenced(p2pName, param.raw, onResult);
  }

  // =================================================================
  // Internal helpers
  // =================================================================

  static void _ensureBridge(String operation) {
    if (BridgeHost.instanceOrNull == null) {
      throw StateError(
        '$operation requires the bridge layer. '
        'Call "await BridgeHost.start()" before using it.',
      );
    }
  }

  static void _checkUidLength(Uint8List uid) {
    if (uid.length != 32) {
      throw RangeError(
          'UID must be exactly 32 bytes, got ${uid.length}.');
    }
  }
}