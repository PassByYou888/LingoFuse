// Three-addressing abstraction for LingoFuse remote calls.
//
// This module exposes the three orthogonal addressing modes that the
// LingoFuse C ABI supports and gives each of them a uniform set of
// call shapes:
//
//   AppTarget        address a logical App by its name
//   UIDTarget        address a specific session by its 32-byte UID
//   P2PNameTarget    address a group of clients by a user-supplied name
//
// ---------------------------------------------------------------------------
// CALL SHAPES
// ---------------------------------------------------------------------------
// Every Target exposes the same four request shapes and two one-way
// shapes:
//
//   call(apiName, {payload, timeoutMs})      CallPromise<Uint8List>
//       Fires the request and returns immediately. The Future resolves
//       with the raw response bytes or rejects with an error.
//
//   callJson<T>(apiName, {payload, timeoutMs})   CallPromise<T>
//       Same as call, but parses the response bytes as UTF-8 JSON into
//       the requested type T. The trailing NUL that LingoFuse appends
//       to every string write is stripped before parsing.
//
//   callAsync(apiName, payload, onResult)
//       Callback style. onResult is invoked exactly once, on the Dart
//       event loop or synchronously on a dispatch failure.
//
//   callSync(apiName, {payload, timeoutMs})    DataHandle
//   tryCallSync(apiName, {payload, timeoutMs}) DataHandle?
//       Blocking variants. callSync returns a size-0 handle on failure;
//       tryCallSync returns null. Both block the calling isolate, so
//       they are only safe from a worker isolate.
//
//   notify(apiName, {payload})
//   sequencedNotify(apiName, {payload})
//       One-way messages. No response.
//
// ---------------------------------------------------------------------------
// ADDRESSING SEMANTICS
// ---------------------------------------------------------------------------
//   Target            Routing key       Local-first?   Load-balanced?
//   ----------------  ----------------  -------------  ---------------
//   AppTarget         App name          YES            N/A
//   UIDTarget         UID (32 bytes)    YES            N/A
//   P2PNameTarget     Group name        NO             YES (server)
//
// "Local-first" means: if the caller process itself hosts a matching
// App / client, the call is serviced without touching the network.
// P2PName deliberately opts out: the server-side dispatcher owns the
// load-balancing state, and short-cutting locally would defeat it.
//
// All diagnostics are in English.

import 'dart:convert';
import 'dart:typed_data';

import 'async_support.dart';
import 'data_handle.dart';
import 'errors.dart';
import 'framework.dart';
import 'io.dart';

// ===========================================================================
// Target base class
// ===========================================================================

/// Abstract base for the three addressing modes.
///
/// Concrete subclasses implement five private hooks, one per underlying
/// call family. The public API is defined once here.
abstract class Target {
  const Target();

  /// A stable, value-based string key for this target.
  ///
  /// Two Target objects that describe the same logical target return
  /// the same hashKey, regardless of the concrete subclass. The format
  /// is `<mode>:<payload>`:
  ///
  ///   app:<appName>
  ///   uid:<64-char-hex>
  ///   p2p:<groupName>
  ///
  /// Use hashKey as a Map / Set key when you need value-based lookup.
  /// Dart's Map and Set compare keys by reference, so two distinct
  /// Target instances that describe the same target would NOT be equal
  /// without this key.
  String get hashKey;

  /// A human-readable description for diagnostics.
  String describe();

  // -----------------------------------------------------------------
  // Subclass hooks
  // -----------------------------------------------------------------

  /// Issues a synchronous Call.
  DataHandle rawSyncCall(String apiName, DataHandle param, int timeoutMs);

  /// Issues an asynchronous Call.
  void rawAsyncCall(
      String apiName, DataHandle param, void Function(Uint8List?, String?) cb);

  /// Issues an asynchronous sequenced Call.
  void rawAsyncSequencedCall(
      String apiName, DataHandle param, void Function(Uint8List?, String?) cb);

  /// Issues a one-way Notify.
  void rawNotify(String apiName, DataHandle param);

  /// Issues a FIFO-ordered one-way Notify.
  void rawSequencedNotify(String apiName, DataHandle param);

  // =================================================================
  // Public API
  // =================================================================

  /// Fires an asynchronous call and returns a [CallPromise] that will
  /// resolve with the raw response bytes.
  ///
  /// If [timeoutMs] is provided and expires before the native callback
  /// fires, the promise is rejected with a [TimeoutException] and
  /// marked abandoned. The native request is NOT cancelled; a late
  /// result is silently discarded.
  ///
  /// [payload] is serialized as UTF-8 JSON. Pass null for an empty
  /// payload.
  CallPromise<Uint8List> call(
    String apiName, {
    Object? payload,
    int? timeoutMs,
  }) {
    final param = DataHandle(apiName);
    LfIo.writeJson(param, payload);

    try {
      final bridge = AsyncBridge.instance();
      return bridge.wrapCall(
        issue: (cb) => rawAsyncCall(apiName, param, cb),
        timeoutMs: timeoutMs,
        targetDescription: describe(),
      );
    } finally {
      // The bridge copies the payload synchronously inside the issue
      // call, so the handle may be disposed the moment the request is
      // queued. Do that here.
      param.dispose();
    }
  }

  /// Same as [call] but parses the response as UTF-8 JSON.
  ///
  /// [T] is the decoded type.
  ///
  /// The response bytes are processed exactly like the bytes returned
  /// by [LfIo.readStringBytes]: a trailing NUL is treated as the end of
  /// the payload. This is required because LingoFuse frames every
  /// string write with a single trailing 0x00, and a handler that
  /// echoes a request written by [LfIo.writeJson] returns that trailing
  /// NUL unchanged.
  ///
  /// An empty response (or one that contains only a NUL) is reported
  /// as a [LingoFuseIoError]; a response that is not valid JSON is
  /// reported as a [LingoFuseIoError] from [LfIo.loadsJson].
  CallPromise<T> callJson<T>(
    String apiName, {
    Object? payload,
    int? timeoutMs,
  }) {
    final param = DataHandle(apiName);
    LfIo.writeJson(param, payload);

    final bridge = AsyncBridge.instance();
    final bytePromise = bridge.wrapCall(
      issue: (cb) => rawAsyncCall(apiName, param, cb),
      timeoutMs: timeoutMs,
      targetDescription: describe(),
    );

    param.dispose();

    final jsonPromise = CallPromise<T>();

    bytePromise.future.then<void>(
      (Uint8List bytes) {
        if (jsonPromise.settled) return;
        try {
          // Strip the trailing NUL. LingoFuse frames every string write
          // with a single trailing 0x00; the server-side echo handler
          // returns that byte unchanged, so the response ends with it.
          final nulIndex = bytes.indexOf(0);
          final Uint8List payloadBytes = nulIndex >= 0
              ? Uint8List.sublistView(bytes, 0, nulIndex)
              : bytes;

          if (payloadBytes.isEmpty) {
            jsonPromise.settleWithError(
              LingoFuseIoError(
                'empty JSON payload',
                operation: 'Target.callJson',
              ),
            );
            return;
          }

          final text = const Utf8Decoder().convert(payloadBytes);
          final decoded = LfIo.loadsJson<T>(text);
          jsonPromise.settleWithValue(decoded);
        } catch (e) {
          jsonPromise.settleWithError(e);
        }
      },
      onError: (Object e) {
        if (jsonPromise.settled) return;
        jsonPromise.settleWithError(e);
      },
    );

    if (bytePromise.abandoned) {
      jsonPromise.markAbandoned();
    }
    return jsonPromise;
  }

  /// Callback style. The [onResult] callback is invoked exactly once,
  /// with either (result, null) on success or (null, error) on failure.
  ///
  /// On a dispatch failure the callback is invoked synchronously, on
  /// the caller's stack, before this method returns.
  ///
  /// NOTE: when the payload is written with [LfIo.writeJson], the
  /// resulting [Uint8List] delivered to the callback ends with a
  /// trailing NUL byte, matching the raw bytes on the wire. Callers
  /// that need a clean string should strip it themselves, or use
  /// [call] / [callJson] which handle the framing automatically.
  void callAsync(
    String apiName,
    Object? payload,
    void Function(Uint8List? result, String? error) onResult,
  ) {
    final param = DataHandle(apiName);
    LfIo.writeJson(param, payload);
    try {
      rawAsyncCall(apiName, param, onResult);
    } finally {
      param.dispose();
    }
  }

  /// Blocking call. Returns a handle owning the raw response bytes.
  ///
  /// The caller is responsible for disposing the returned handle. On
  /// timeout or unreachable target, the returned handle has size 0.
  ///
  /// Blocks the calling isolate: use only from a worker isolate, or
  /// when the surrounding code does not need the Dart event loop to
  /// run during the call.
  DataHandle callSync(
    String apiName, {
    Object? payload,
    int timeoutMs = 5000,
  }) {
    final param = DataHandle(apiName);
    LfIo.writeJson(param, payload);
    try {
      return rawSyncCall(apiName, param, timeoutMs);
    } finally {
      param.dispose();
    }
  }

  /// Non-throwing counterpart of [callSync].
  ///
  /// Returns null when the response is empty (timeout, unreachable
  /// target). The caller owns the returned handle on success.
  DataHandle? tryCallSync(
    String apiName, {
    Object? payload,
    int timeoutMs = 5000,
  }) {
    final resp = callSync(apiName, payload: payload, timeoutMs: timeoutMs);
    if (resp.size == 0) {
      resp.dispose();
      return null;
    }
    return resp;
  }

  /// Sends a one-way notification.
  void notify(String apiName, {Object? payload}) {
    final param = DataHandle(apiName);
    LfIo.writeJson(param, payload);
    try {
      rawNotify(apiName, param);
    } finally {
      param.dispose();
    }
  }

  /// Sends a FIFO-ordered one-way notification.
  void sequencedNotify(String apiName, {Object? payload}) {
    final param = DataHandle(apiName);
    LfIo.writeJson(param, payload);
    try {
      rawSequencedNotify(apiName, param);
    } finally {
      param.dispose();
    }
  }
}

// ===========================================================================
// AppTarget
// ===========================================================================

/// Addresses a logical App by its name.
///
/// Routing is local-first: if the caller process itself hosts a
/// matching App, the call is serviced without touching the network.
class AppTarget extends Target {
  final String appName;

  const AppTarget(this.appName);

  @override
  String get hashKey => 'app:$appName';

  @override
  String describe() => 'app("$appName")';

  @override
  DataHandle rawSyncCall(String apiName, DataHandle param, int timeoutMs) {
    return Framework.call(appName, param, timeoutMs: timeoutMs);
  }

  @override
  void rawAsyncCall(
    String apiName,
    DataHandle param,
    void Function(Uint8List?, String?) cb,
  ) {
    Framework.callAsync(appName, param, cb);
  }

  @override
  void rawAsyncSequencedCall(
    String apiName,
    DataHandle param,
    void Function(Uint8List?, String?) cb,
  ) {
    Framework.callAsyncSequenced(appName, param, cb);
  }

  @override
  void rawNotify(String apiName, DataHandle param) {
    Framework.notify(appName, param);
  }

  @override
  void rawSequencedNotify(String apiName, DataHandle param) {
    Framework.sequencedNotify(appName, param);
  }
}

// ===========================================================================
// UIDTarget
// ===========================================================================

/// Addresses a specific session by its 32-byte UID.
///
/// Routing is local-first: if the caller process itself hosts a client
/// with the matching UID, the call is serviced without touching the
/// network.
///
/// A UID addresses ANY API the target registered, whether app-bound or
/// process-wide, without requiring the caller to know the target App
/// name. See the Pascal guide, chapter 9, for the full mechanism.
class UIDTarget extends Target {
  final Uint8List uidBytes;

  /// Constructs a target from a [Uint8List] that must be exactly 32
  /// bytes. A wrong-length input throws a [RangeError]; no silent
  /// truncation or zero-padding is performed.
  UIDTarget(Uint8List uid) : uidBytes = _normalizeUid(uid);

  /// Constructs a target from a 64-character hexadecimal string (case
  /// insensitive). A wrong-length or non-hex input throws a
  /// [RangeError].
  UIDTarget.hex(String hex) : uidBytes = _normalizeUidHex(hex);

  /// A 64-character lowercase hexadecimal representation of the UID.
  String get uidHex {
    final buf = StringBuffer();
    for (final b in uidBytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  @override
  String get hashKey => 'uid:$uidHex';

  @override
  String describe() => 'uid($uidHex)';

  @override
  DataHandle rawSyncCall(String apiName, DataHandle param, int timeoutMs) {
    return Framework.uidCall(uidBytes, param, timeoutMs: timeoutMs);
  }

  @override
  void rawAsyncCall(
    String apiName,
    DataHandle param,
    void Function(Uint8List?, String?) cb,
  ) {
    Framework.uidCallAsync(uidBytes, param, cb);
  }

  @override
  void rawAsyncSequencedCall(
    String apiName,
    DataHandle param,
    void Function(Uint8List?, String?) cb,
  ) {
    Framework.uidCallAsyncSequenced(uidBytes, param, cb);
  }

  @override
  void rawNotify(String apiName, DataHandle param) {
    Framework.uidNotify(uidBytes, param);
  }

  @override
  void rawSequencedNotify(String apiName, DataHandle param) {
    Framework.uidSequencedNotify(uidBytes, param);
  }
}

// ===========================================================================
// P2PNameTarget
// ===========================================================================

/// Addresses a group of clients by a user-supplied name.
///
/// Routing is NOT local-first: the call is always forwarded to the
/// server for dispatch. The server-side dispatcher picks a target
/// using the mesh's load-balancing state.
class P2PNameTarget extends Target {
  final String groupName;

  const P2PNameTarget(this.groupName);

  @override
  String get hashKey => 'p2p:$groupName';

  @override
  String describe() => 'p2pname("$groupName")';

  @override
  DataHandle rawSyncCall(String apiName, DataHandle param, int timeoutMs) {
    return Framework.p2pnameCall(groupName, param, timeoutMs: timeoutMs);
  }

  @override
  void rawAsyncCall(
    String apiName,
    DataHandle param,
    void Function(Uint8List?, String?) cb,
  ) {
    Framework.p2pnameCallAsync(groupName, param, cb);
  }

  @override
  void rawAsyncSequencedCall(
    String apiName,
    DataHandle param,
    void Function(Uint8List?, String?) cb,
  ) {
    Framework.p2pnameCallAsyncSequenced(groupName, param, cb);
  }

  @override
  void rawNotify(String apiName, DataHandle param) {
    Framework.p2pnameNotify(groupName, param);
  }

  @override
  void rawSequencedNotify(String apiName, DataHandle param) {
    Framework.p2pnameSequencedNotify(groupName, param);
  }
}

// ===========================================================================
// UID normalization helpers
// ===========================================================================

/// Validates a UID that is expected to be exactly 32 bytes and returns
/// a defensive copy. A wrong-length input throws a [RangeError]; no
/// silent truncation or zero-padding is performed.
Uint8List _normalizeUid(Uint8List input) {
  if (input.length != 32) {
    throw RangeError(
        'UID must be exactly 32 bytes, got ${input.length}.');
  }
  return Uint8List.fromList(input);
}

/// Parses a 64-character hexadecimal string into a 32-byte UID. A
/// wrong-length or non-hex input throws a [RangeError].
Uint8List _normalizeUidHex(String hex) {
  final trimmed = hex.trim();
  if (trimmed.length != 64) {
    throw RangeError(
        'UID hex must be exactly 64 characters, got ${trimmed.length}.');
  }
  final out = Uint8List(32);
  for (int i = 0; i < 32; i++) {
    final pair = trimmed.substring(i * 2, i * 2 + 2);
    final v = int.tryParse(pair, radix: 16);
    if (v == null) {
      throw RangeError(
          'UID hex contains a non-hex character at position ${i * 2}.');
    }
    out[i] = v;
  }
  return out;
}