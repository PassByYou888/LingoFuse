// RAII wrapper around a native LingoFuse application handle (TAppHnd).
//
// RESPONSIBILITY
// --------------
// Owns a native application handle and exposes:
//
//   - creation / disposal of the handle;
//   - registration of Call and Notify APIs on the handle;
//   - registration of process-wide P2P Call and Notify APIs;
//   - local (in-process) invocation of those APIs;
//   - binding the application to currently unbound clients.
//
// ---------------------------------------------------------------------------
// REGISTRATION CHANNELS
// ---------------------------------------------------------------------------
//
// All registrations flow through BridgeHost. This matches the v1.x
// behaviour: the AppHandle constructors and the registerCall /
// registerNotify / unregister methods have ALWAYS required
// BridgeHost.start() to have been called first, because they route the
// user's Dart closure through the bridge's Protocol A synchronous
// handshake.
//
// There is deliberately NO legacy direct-FFI fallback. Adding one
// would require constructing a NativeCallable per registration, which
// cannot capture the user's Dart closure safely, and would introduce a
// second callback-synchronisation path that is easy to get wrong. The
// bridge is the single supported registration path.
//
// Callers who only need a bare TAppHnd without any registration can
// still construct an AppHandle; the constructor does not require the
// bridge.
//
// ---------------------------------------------------------------------------
// TWO API NAMESPACES
// ---------------------------------------------------------------------------
//
//   registerCall / registerNotify  register APIs on THIS application.
//                                  Reachable via App-name addressing.
//
//   registerP2PCall / registerP2PNotify
//                                  register APIs on the process-wide
//                                  LF_P2P_APP. Reachable via UID
//                                  addressing and P2PName addressing
//                                  ONLY. NOT reachable via App-name
//                                  addressing, even if the API name
//                                  matches an App name.
//
// The two namespaces are independent. Registering the same name in
// both is legal and produces two distinct APIs, reachable through two
// distinct addressing modes.
//
// All diagnostics are in English.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bridge/bridge_host.dart';
import 'data_handle.dart';
import 'errors.dart';
import 'runtime.dart';

/// RAII wrapper around a native LingoFuse application handle.
///
/// Registering Call and Notify APIs requires [BridgeHost.start] to have
/// been called first. The constructor itself does not require the
/// bridge.
class AppHandle {
  // -----------------------------------------------------------------
  // Private state
  // -----------------------------------------------------------------

  final Pointer<Void> _raw;
  final String _name;
  bool _disposed = false;

  AppHandle._(this._raw, this._name);

  // -----------------------------------------------------------------
  // Construction
  // -----------------------------------------------------------------

  /// Creates a new application with the given name and description.
  ///
  /// The [name] must be unique on the wire; matching is
  /// case-insensitive. The [description] is purely informational and
  /// may be empty.
  ///
  /// Does NOT require BridgeHost: the handle is created through the
  /// native LF_CreateApp entry point directly.
  ///
  /// Throws [LingoFuseError] if the native call fails.
  factory AppHandle(String name, String description) {
    final lf = getBindings();
    final cName = name.toNativeUtf8().cast<Char>();
    final cDesc = description.toNativeUtf8().cast<Char>();
    try {
      final hnd = lf.LF_CreateApp(cName, cDesc);
      if (hnd == nullptr) {
        throw LingoFuseError('LF_CreateApp returned null for "$name"');
      }
      return AppHandle._(hnd, name);
    } finally {
      calloc.free(cName);
      calloc.free(cDesc);
    }
  }

  // -----------------------------------------------------------------
  // Identity and state
  // -----------------------------------------------------------------

  /// The raw native handle.
  ///
  /// Throws [LingoFuseObjectDisposedError] if [dispose] has been called.
  Pointer<Void> get raw {
    _ensureNotDisposed();
    return _raw;
  }

  /// The application name passed to the constructor.
  String get name => _name;

  /// True while the handle is valid and [dispose] has not been called.
  bool get isValid => !_disposed && _raw != nullptr;

  void _ensureNotDisposed() {
    if (_disposed || _raw == nullptr) {
      throw LingoFuseObjectDisposedError('AppHandle');
    }
  }

  // =================================================================
  // Registration: app-bound namespace
  // =================================================================

  /// Registers a Call API on THIS application.
  ///
  /// The [handler] runs on the Dart event loop. The native worker that
  /// raised the callback is BLOCKED until the handler returns, so it
  /// MUST NOT block for long and MUST NOT call any synchronous
  /// LingoFuse entry point (LF_Call and friends), which would deadlock.
  ///
  /// The API becomes reachable via App-name addressing (LF_Call etc.)
  /// after the framework broadcasts it, typically within a few seconds.
  ///
  /// Throws [StateError] if [BridgeHost.start] has not been called.
  /// Throws [BridgeException] if the underlying registration is
  /// rejected (for example, a duplicate API name).
  void registerCall(
    String apiName,
    String description,
    CallHandler handler,
  ) {
    _ensureNotDisposed();
    BridgeHost.instance.registerCall(_raw, apiName, description, handler);
  }

  /// Registers a Notify API on THIS application.
  ///
  /// Same threading contract as [registerCall], except that the native
  /// worker does NOT wait for the handler to return.
  ///
  /// Throws [StateError] if [BridgeHost.start] has not been called.
  void registerNotify(
    String apiName,
    String description,
    NotifyHandler handler,
  ) {
    _ensureNotDisposed();
    BridgeHost.instance.registerNotify(_raw, apiName, description, handler);
  }

  /// Unregisters an API registered through [registerCall] or
  /// [registerNotify].
  ///
  /// The removal takes effect locally immediately. A network broadcast
  /// propagates it to remote peers within approximately 3 seconds.
  ///
  /// Returns true if the API was found and removed.
  ///
  /// Throws [StateError] if [BridgeHost.start] has not been called.
  bool unregister(String apiName) {
    _ensureNotDisposed();
    return BridgeHost.instance.unregister(_raw, apiName);
  }

  // =================================================================
  // Registration: process-wide P2P namespace
  // =================================================================

  /// Registers a process-wide P2P Call API.
  ///
  /// P2P APIs live on the process-wide LF_P2P_APP and are reachable via
  /// UID addressing and P2PName addressing ONLY. They are NOT reachable
  /// via App-name addressing, even if the API name matches an App name.
  ///
  /// Typical use: register a small set of globally-discoverable utility
  /// APIs (health probes, capability discovery, identity echo, ...)
  /// that any client in the mesh can call by group name or by UID
  /// without knowing the target App name.
  ///
  /// The [handler] runs on the Dart event loop with the same threading
  /// contract as [registerCall].
  ///
  /// Throws [StateError] if [BridgeHost.start] has not been called.
  /// Throws [BridgeException] if the registration is rejected.
  void registerP2PCall(
    String apiName,
    String description,
    CallHandler handler,
  ) {
    _ensureNotDisposed();
    BridgeHost.instance.registerP2PCall(apiName, description, handler);
  }

  /// Registers a process-wide P2P Notify API.
  ///
  /// Same namespace rules as [registerP2PCall]. The native worker does
  /// NOT wait for the handler to return.
  ///
  /// Throws [StateError] if [BridgeHost.start] has not been called.
  void registerP2PNotify(
    String apiName,
    String description,
    NotifyHandler handler,
  ) {
    _ensureNotDisposed();
    BridgeHost.instance.registerP2PNotify(apiName, description, handler);
  }

  /// Removes a process-wide P2P API by name.
  ///
  /// The removal is immediate locally. Remote peers may still see the
  /// API for up to ~3 seconds until the broadcast propagates.
  ///
  /// Returns true if the API was found and removed.
  ///
  /// Throws [StateError] if [BridgeHost.start] has not been called.
  bool unregisterP2P(String apiName) {
    _ensureNotDisposed();
    return BridgeHost.instance.unregisterP2P(apiName);
  }

  // =================================================================
  // Local execution
  // =================================================================

  /// Invokes a Call API locally within the same process.
  ///
  /// Local calls run in-process and bypass the network entirely. The
  /// [param] handle is not consumed by this call.
  ///
  /// Returns a new handle owning the result. When the target API is not
  /// registered, the returned handle has size 0 (not NULL). The caller
  /// is responsible for disposing the result.
  ///
  /// Note: local Call runs the handler on the CALLING thread, not on a
  /// native worker thread. BridgeHost is therefore not required for
  /// local execution, and the handler MUST be the legacy direct-FFI
  /// callback (not a Dart closure) if registration was performed
  /// through a native call. In practice, when a handler is registered
  /// through [registerCall] and then invoked through [localCall], the
  /// call path is routed through the bridge synchronisation machinery.
  ///
  /// Throws [LingoFuseCallError] if the native call returns NULL (a
  /// rare transport-level failure).
  DataHandle localCall(DataHandle param) {
    _ensureNotDisposed();
    final lf = getBindings();
    final result = lf.LF_LocalCall(_raw, param.raw);
    if (result == nullptr) {
      throw LingoFuseCallError(
        'LF_LocalCall returned a null handle.',
        targetApp: _name,
      );
    }
    return DataHandle.fromRaw(result, owned: true);
  }

  /// Invokes a Notify API locally within the same process.
  ///
  /// Same execution model as [localCall]: runs in-process, bypasses the
  /// network, no return value.
  void localNotify(DataHandle param) {
    _ensureNotDisposed();
    getBindings().LF_LocalNotify(_raw, param.raw);
  }

  // =================================================================
  // Client binding
  // =================================================================

  /// Binds the application to all currently unbound LingoFuse clients.
  ///
  /// Must be called after the framework has started (i.e. after
  /// Framework.prepareDone() has returned true) and while the simulated
  /// main thread is active.
  ///
  /// A client is eligible for binding only if it has no app attached
  /// yet. Each client hosts at most one application.
  ///
  /// Returns the number of clients successfully bound. A return value
  /// of 0 means either the main thread is not active or all clients are
  /// already occupied.
  int bind() {
    _ensureNotDisposed();
    return getBindings().LF_BindApp(_raw);
  }

  // =================================================================
  // Lifetime
  // =================================================================

  /// Releases the app handle. Idempotent.
  ///
  /// This is the FIRST stage of the two-stage native destruction:
  ///
  ///   1. The application is detached from all clients.
  ///   2. Its sequenced notification threads are stopped.
  ///   3. Its update timer is removed.
  ///
  /// The underlying object remains in the global application pool until
  /// LF_Shutdown is called (through Framework.shutdown or
  /// BridgeHost-related shutdown paths).
  ///
  /// After [dispose], the handle is invalid: any method that accesses
  /// [raw] throws [LingoFuseObjectDisposedError].
  ///
  /// Note: this does NOT unregister APIs at the bridge level. The
  /// bridge keeps its Protocol A registrations until the process exits
  /// or the bridge itself is stopped. If you need to re-register the
  /// same API name in a new AppHandle, either re-use the existing
  /// AppHandle or restart the bridge.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_raw != nullptr) {
      getBindings().LF_FreeApp(_raw);
    }
  }
}