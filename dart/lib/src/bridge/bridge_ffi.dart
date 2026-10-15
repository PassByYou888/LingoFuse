// FFI declarations for lf_dart_bridge.dll / .so / .dylib.
//
// This file is a manual, complete mapping of the C API declared in
// bridge/lf_dart_bridge.h. Unlike the previous bindings_generated.dart
// which was produced by ffigen from a partial header, this file covers
// EVERY function the bridge exports: UID addressing, P2PName
// addressing, asynchronous invocation, P2P identity accessors, and the
// typed option helpers are all present.
//
// STRUCTURE
// ---------
// For each C function `lf_bridge_xxx`, there are three declarations:
//
//     typedef LfBridgeXxxNative = <C signature>;
//     typedef LfBridgeXxxDart   = <Dart signature>;
//     late final LfBridgeXxxDart lfBridgeXxx =
//         _lib.lookupFunction<LfBridgeXxxNative, LfBridgeXxxDart>(
//             'lf_bridge_xxx');
//
// The native typedef describes the ABI signature; the Dart typedef
// describes the same call after Dart's FFI layer has translated the
// argument and return types. Both are needed.
//
// TYPE MAPPING
// ------------
//     C int             -> ffi.Int32               -> int
//     C int64_t         -> ffi.Int64               -> int
//     C uint64_t        -> ffi.Uint64              -> int
//     C void*           -> ffi.Pointer<ffi.Void>   -> Pointer<ffi.Void>
//     C const char*     -> ffi.Pointer<ffi.Char>   -> Pointer<ffi.Char>
//     C char*           -> ffi.Pointer<ffi.Char>   -> Pointer<ffi.Char>
//     C const uint8_t*  -> ffi.Pointer<ffi.Uint8>  -> Pointer<ffi.Uint8>
//     C uint8_t*        -> ffi.Pointer<ffi.Uint8>  -> Pointer<ffi.Uint8>
//     C void            -> ffi.Void                -> void
//
// Dart's `int` is a 64-bit signed integer on the native VM. A C
// uint64_t value above 2^63 - 1 cannot be represented exactly, but the
// only uint64 parameters here are timeouts and byte counts, both of
// which are bounded well below that limit in practice.
//
// LOADING
// -------
// BridgeFfi.load() locates the shared library using this search order:
//
//     1. $LINGOFUSE_BRIDGE_DLL, if set and non-empty.
//     2. bridge/ subdirectory next to the calling script.
//     3. Current working directory.
//     4. The bare file name, letting the OS loader resolve it via
//        PATH / LD_LIBRARY_PATH / DYLD_LIBRARY_PATH.
//
// All diagnostics are in English.

import 'dart:ffi';
import 'dart:io';

// ---------------------------------------------------------------------------
// Convenience type aliases
// ---------------------------------------------------------------------------

typedef _VoidPtr = Pointer<Void>;
typedef _CharPtr = Pointer<Char>;
typedef _U8Ptr = Pointer<Uint8>;

// ===========================================================================
// Section 0 -- Lifecycle
// ===========================================================================

typedef LfBridgeInitNative = Int32 Function(Int64, _VoidPtr);
typedef LfBridgeInitDart = int Function(int, _VoidPtr);

typedef LfBridgeShutdownNative = Void Function();
typedef LfBridgeShutdownDart = void Function();

typedef LfBridgeIsInitializedNative = Int32 Function();
typedef LfBridgeIsInitializedDart = int Function();

// ===========================================================================
// Section 1 -- Data handle
// ===========================================================================

typedef LfBridgeCreateDataNative = _VoidPtr Function(_CharPtr);
typedef LfBridgeCreateDataDart = _VoidPtr Function(_CharPtr);

typedef LfBridgeCreateDataPermanentNative = _VoidPtr Function(_CharPtr);
typedef LfBridgeCreateDataPermanentDart = _VoidPtr Function(_CharPtr);

typedef LfBridgeFreeDataNative = Void Function(_VoidPtr);
typedef LfBridgeFreeDataDart = void Function(_VoidPtr);

typedef LfBridgeWriteBufferNative =
    Int64 Function(_VoidPtr, _VoidPtr, Int64);
typedef LfBridgeWriteBufferDart = int Function(_VoidPtr, _VoidPtr, int);

typedef LfBridgeReadBufferNative =
    Int64 Function(_VoidPtr, _VoidPtr, Int64);
typedef LfBridgeReadBufferDart = int Function(_VoidPtr, _VoidPtr, int);

typedef LfBridgeGetPosNative = Int64 Function(_VoidPtr);
typedef LfBridgeGetPosDart = int Function(_VoidPtr);

typedef LfBridgeSetPosNative = Void Function(_VoidPtr, Int64);
typedef LfBridgeSetPosDart = void Function(_VoidPtr, int);

typedef LfBridgeGetSizeNative = Int64 Function(_VoidPtr);
typedef LfBridgeGetSizeDart = int Function(_VoidPtr);

typedef LfBridgeSetSizeNative = Void Function(_VoidPtr, Int64);
typedef LfBridgeSetSizeDart = void Function(_VoidPtr, int);

typedef LfBridgeGetP2PUidNative = Int32 Function(_VoidPtr, _U8Ptr);
typedef LfBridgeGetP2PUidDart = int Function(_VoidPtr, _U8Ptr);

typedef LfBridgeGetP2PNameNative = Int32 Function(_VoidPtr, _CharPtr, Int32);
typedef LfBridgeGetP2PNameDart = int Function(_VoidPtr, _CharPtr, int);

typedef LfBridgeWriteUidNative = Int32 Function(_VoidPtr, _U8Ptr);
typedef LfBridgeWriteUidDart = int Function(_VoidPtr, _U8Ptr);

typedef LfBridgeReadUidNative = Int32 Function(_VoidPtr, _U8Ptr);
typedef LfBridgeReadUidDart = int Function(_VoidPtr, _U8Ptr);

// ===========================================================================
// Section 2 -- Application handle
// ===========================================================================

typedef LfBridgeCreateAppNative = _VoidPtr Function(_CharPtr, _CharPtr);
typedef LfBridgeCreateAppDart = _VoidPtr Function(_CharPtr, _CharPtr);

typedef LfBridgeFreeAppNative = Void Function(_VoidPtr);
typedef LfBridgeFreeAppDart = void Function(_VoidPtr);

typedef LfBridgeGetAppNameNative = Int32 Function(_VoidPtr, _CharPtr, Int32);
typedef LfBridgeGetAppNameDart = int Function(_VoidPtr, _CharPtr, int);

typedef LfBridgeGenerateAppNameNative = Int32 Function(_CharPtr, Int32);
typedef LfBridgeGenerateAppNameDart = int Function(_CharPtr, int);

typedef LfBridgeBindAppNative = Int32 Function(_VoidPtr);
typedef LfBridgeBindAppDart = int Function(_VoidPtr);

// ===========================================================================
// Section 3 -- Registration (app-bound)
// ===========================================================================

typedef LfBridgeRegisterCallNative =
    Int32 Function(_VoidPtr, _CharPtr, _CharPtr, Int64);
typedef LfBridgeRegisterCallDart =
    int Function(_VoidPtr, _CharPtr, _CharPtr, int);

typedef LfBridgeRegisterNotifyNative =
    Int32 Function(_VoidPtr, _CharPtr, _CharPtr, Int64);
typedef LfBridgeRegisterNotifyDart =
    int Function(_VoidPtr, _CharPtr, _CharPtr, int);

typedef LfBridgeUnregisterNative = Int32 Function(_VoidPtr, _CharPtr);
typedef LfBridgeUnregisterDart = int Function(_VoidPtr, _CharPtr);

typedef LfBridgeCompleteNative = Int32 Function(Int64, _U8Ptr, Int64);
typedef LfBridgeCompleteDart = int Function(int, _U8Ptr, int);

// ===========================================================================
// Section 4 -- Registration (process-wide P2P)
// ===========================================================================

typedef LfBridgeRegisterP2PCallNative =
    Int32 Function(_CharPtr, _CharPtr, Int64);
typedef LfBridgeRegisterP2PCallDart =
    int Function(_CharPtr, _CharPtr, int);

typedef LfBridgeRegisterP2PNotifyNative =
    Int32 Function(_CharPtr, _CharPtr, Int64);
typedef LfBridgeRegisterP2PNotifyDart =
    int Function(_CharPtr, _CharPtr, int);

typedef LfBridgeUnregisterP2PNative = Int32 Function(_CharPtr);
typedef LfBridgeUnregisterP2PDart = int Function(_CharPtr);

// ===========================================================================
// Section 5 -- Local execution
// ===========================================================================

typedef LfBridgeLocalCallNative = _VoidPtr Function(_VoidPtr, _VoidPtr);
typedef LfBridgeLocalCallDart = _VoidPtr Function(_VoidPtr, _VoidPtr);

typedef LfBridgeLocalNotifyNative = Void Function(_VoidPtr, _VoidPtr);
typedef LfBridgeLocalNotifyDart = void Function(_VoidPtr, _VoidPtr);

// ===========================================================================
// Section 6 -- Network preparation
// ===========================================================================

typedef LfBridgeResetPrepareNative = Void Function();
typedef LfBridgeResetPrepareDart = void Function();

typedef LfBridgePrepareServiceNative = Int32 Function(_CharPtr, _CharPtr);
typedef LfBridgePrepareServiceDart = int Function(_CharPtr, _CharPtr);

typedef LfBridgePrepareClientNative = Int32 Function(_CharPtr, _VoidPtr);
typedef LfBridgePrepareClientDart = int Function(_CharPtr, _VoidPtr);

typedef LfBridgePrepareDoneNative = Int32 Function();
typedef LfBridgePrepareDoneDart = int Function();

typedef LfBridgeExitMainThreadNative = Void Function();
typedef LfBridgeExitMainThreadDart = void Function();

typedef LfBridgeLfShutdownNative = Void Function();
typedef LfBridgeLfShutdownDart = void Function();

// ===========================================================================
// Section 7 -- Remote invocation, App-name addressing
// ===========================================================================

typedef LfBridgeCallNative = _VoidPtr Function(_CharPtr, _VoidPtr, Uint64);
typedef LfBridgeCallDart = _VoidPtr Function(_CharPtr, _VoidPtr, int);

typedef LfBridgeNotifyNative = Void Function(_CharPtr, _VoidPtr);
typedef LfBridgeNotifyDart = void Function(_CharPtr, _VoidPtr);

typedef LfBridgeSequencedNotifyNative = Void Function(_CharPtr, _VoidPtr);
typedef LfBridgeSequencedNotifyDart = void Function(_CharPtr, _VoidPtr);

typedef LfBridgeCallAsyncNative = Int32 Function(_CharPtr, _VoidPtr, Int64);
typedef LfBridgeCallAsyncDart = int Function(_CharPtr, _VoidPtr, int);

typedef LfBridgeCallAsyncSequencedNative =
    Int32 Function(_CharPtr, _VoidPtr, Int64);
typedef LfBridgeCallAsyncSequencedDart =
    int Function(_CharPtr, _VoidPtr, int);

// ===========================================================================
// Section 8 -- Remote invocation, UID addressing
// ===========================================================================

typedef LfBridgeUidCallNative = _VoidPtr Function(_U8Ptr, _VoidPtr, Uint64);
typedef LfBridgeUidCallDart = _VoidPtr Function(_U8Ptr, _VoidPtr, int);

typedef LfBridgeUidNotifyNative = Void Function(_U8Ptr, _VoidPtr);
typedef LfBridgeUidNotifyDart = void Function(_U8Ptr, _VoidPtr);

typedef LfBridgeUidSequencedNotifyNative = Void Function(_U8Ptr, _VoidPtr);
typedef LfBridgeUidSequencedNotifyDart = void Function(_U8Ptr, _VoidPtr);

typedef LfBridgeUidCallAsyncNative = Int32 Function(_U8Ptr, _VoidPtr, Int64);
typedef LfBridgeUidCallAsyncDart = int Function(_U8Ptr, _VoidPtr, int);

typedef LfBridgeUidCallAsyncSequencedNative =
    Int32 Function(_U8Ptr, _VoidPtr, Int64);
typedef LfBridgeUidCallAsyncSequencedDart =
    int Function(_U8Ptr, _VoidPtr, int);

// ===========================================================================
// Section 9 -- Remote invocation, P2PName addressing
// ===========================================================================

typedef LfBridgeP2PNameCallNative =
    _VoidPtr Function(_CharPtr, _VoidPtr, Uint64);
typedef LfBridgeP2PNameCallDart =
    _VoidPtr Function(_CharPtr, _VoidPtr, int);

typedef LfBridgeP2PNameNotifyNative = Void Function(_CharPtr, _VoidPtr);
typedef LfBridgeP2PNameNotifyDart = void Function(_CharPtr, _VoidPtr);

typedef LfBridgeP2PNameSequencedNotifyNative =
    Void Function(_CharPtr, _VoidPtr);
typedef LfBridgeP2PNameSequencedNotifyDart =
    void Function(_CharPtr, _VoidPtr);

typedef LfBridgeP2PNameCallAsyncNative =
    Int32 Function(_CharPtr, _VoidPtr, Int64);
typedef LfBridgeP2PNameCallAsyncDart =
    int Function(_CharPtr, _VoidPtr, int);

typedef LfBridgeP2PNameCallAsyncSequencedNative =
    Int32 Function(_CharPtr, _VoidPtr, Int64);
typedef LfBridgeP2PNameCallAsyncSequencedDart =
    int Function(_CharPtr, _VoidPtr, int);

// ===========================================================================
// Section 10 -- Queries
// ===========================================================================

typedef LfBridgeCheckMainThreadNative = Int32 Function();
typedef LfBridgeCheckMainThreadDart = int Function();

typedef LfBridgeCheckAppNative = Int32 Function(_CharPtr);
typedef LfBridgeCheckAppDart = int Function(_CharPtr);

typedef LfBridgeCheckApiNative = Int32 Function(_CharPtr, _CharPtr);
typedef LfBridgeCheckApiDart = int Function(_CharPtr, _CharPtr);

typedef LfBridgeCheckUidNative = Int32 Function(_U8Ptr);
typedef LfBridgeCheckUidDart = int Function(_U8Ptr);

typedef LfBridgeCheckUidApiNative = Int32 Function(_U8Ptr, _CharPtr);
typedef LfBridgeCheckUidApiDart = int Function(_U8Ptr, _CharPtr);

typedef LfBridgeCheckP2PNameNative = Int32 Function(_CharPtr);
typedef LfBridgeCheckP2PNameDart = int Function(_CharPtr);

typedef LfBridgeCheckP2PNameApiNative = Int32 Function(_CharPtr, _CharPtr);
typedef LfBridgeCheckP2PNameApiDart = int Function(_CharPtr, _CharPtr);

// ===========================================================================
// Section 11 -- Options
// ===========================================================================

// -- string setter / string getter --
typedef LfBridgeSetOptStrNative = Int32 Function(_CharPtr);
typedef LfBridgeSetOptStrDart = int Function(_CharPtr);

typedef LfBridgeGetOptStrNative = Int32 Function(_CharPtr, Int32);
typedef LfBridgeGetOptStrDart = int Function(_CharPtr, int);

// -- int setter / int getter --
typedef LfBridgeSetOptIntNative = Int32 Function(Int32);
typedef LfBridgeSetOptIntDart = int Function(int);

typedef LfBridgeGetOptIntNative = Int32 Function();
typedef LfBridgeGetOptIntDart = int Function();

// -- uint64 setter / int getter --
typedef LfBridgeSetOptU64Native = Int32 Function(Uint64);
typedef LfBridgeSetOptU64Dart = int Function(int);

typedef LfBridgeGetOptU64Native = Int32 Function();
typedef LfBridgeGetOptU64Dart = int Function();

// -- generic --
typedef LfBridgeSetOptionNative = Int32 Function(_CharPtr, _CharPtr);
typedef LfBridgeSetOptionDart = int Function(_CharPtr, _CharPtr);

typedef LfBridgeGetOptionNative = Int32 Function(_CharPtr, _CharPtr, Int32);
typedef LfBridgeGetOptionDart = int Function(_CharPtr, _CharPtr, int);

// ===========================================================================
// Section 12 -- Status
// ===========================================================================

typedef LfBridgeGetStatusCountNative = Int32 Function();
typedef LfBridgeGetStatusCountDart = int Function();

typedef LfBridgeGetStatusNative = Int32 Function(_CharPtr, Int32);
typedef LfBridgeGetStatusDart = int Function(_CharPtr, int);

typedef LfBridgePostStatusNative = Int32 Function(_CharPtr);
typedef LfBridgePostStatusDart = int Function(_CharPtr);

// ===========================================================================
// Section 13 -- Network events
// ===========================================================================

typedef LfBridgeSetNetworkEventNative = Int32 Function(Int64, Int64);
typedef LfBridgeSetNetworkEventDart = int Function(int, int);

typedef LfBridgeClearNetworkEventNative = Int32 Function();
typedef LfBridgeClearNetworkEventDart = int Function();

// ===========================================================================
// Section 15 -- Diagnostics
// ===========================================================================

typedef LfBridgeLastErrorNative = _CharPtr Function();
typedef LfBridgeLastErrorDart = _CharPtr Function();

typedef LfBridgeVersionNative = _CharPtr Function();
typedef LfBridgeVersionDart = _CharPtr Function();

typedef LfBridgeStatsJsonNative = Int32 Function(_CharPtr, Int32);
typedef LfBridgeStatsJsonDart = int Function(_CharPtr, int);

// ===========================================================================
// BridgeFfi -- the loaded library handle and all resolved functions
// ===========================================================================

/// Loaded lf_dart_bridge shared library plus the resolved symbols.
///
/// Construct via [BridgeFfi.load] or [BridgeFfi.instance]. This class is
/// thread-safe (Dart's FFI layer serialises lookups) and idempotent: a
/// second call to [load] returns the same instance.
class BridgeFfi {
  final DynamicLibrary _lib;

  BridgeFfi._(this._lib);

  static BridgeFfi? _instance;

  /// Returns the process-wide singleton, loading it on first access.
  static BridgeFfi get instance {
    final i = _instance;
    if (i == null) {
      throw StateError(
          'BridgeFfi is not loaded. Call BridgeFfi.load() first.');
    }
    return i;
  }

  /// Loads the bridge shared library and resolves every symbol.
  ///
  /// Throws [StateError] if the library cannot be located.
  static BridgeFfi load() {
    if (_instance != null) return _instance!;

    final fileName = _selectFileName();
    final candidates = _buildSearchPaths(fileName);
    final tried = <String>[];

    // 1. Explicit override via environment variable.
    final envOverride = Platform.environment['LINGOFUSE_BRIDGE_DLL'];
    if (envOverride != null && envOverride.isNotEmpty) {
      try {
        _instance = BridgeFfi._(DynamicLibrary.open(envOverride));
        return _instance!;
      } catch (e) {
        tried.add('$envOverride ($e)');
      }
    }

    // 2. File-system search paths.
    for (final path in candidates) {
      try {
        if (File(path).existsSync()) {
          _instance = BridgeFfi._(DynamicLibrary.open(path));
          return _instance!;
        }
        tried.add('$path (not found)');
      } catch (e) {
        tried.add('$path ($e)');
      }
    }

    // 3. Bare name via OS loader.
    try {
      _instance = BridgeFfi._(DynamicLibrary.open(fileName));
      return _instance!;
    } catch (e) {
      tried.add('$fileName on system loader path ($e)');
    }

    throw StateError(
        'Could not load $fileName.\n'
        'Tried:\n  ${tried.join('\n  ')}\n'
        'Set LINGOFUSE_BRIDGE_DLL, or place the library next to the '
        'executable, or in bridge/ or in the current directory.');
  }

  /// Resets the singleton. For tests only.
  static void resetForTest() {
    _instance = null;
  }

  static String _selectFileName() {
    if (Platform.isWindows) return 'lf_dart_bridge.dll';
    if (Platform.isMacOS) return 'lf_dart_bridge.dylib';
    return 'lf_dart_bridge.so';
  }

  static List<String> _buildSearchPaths(String fileName) {
    final paths = <String>[];
    // bridge/ next to the package root
    paths.add('bridge/$fileName');
    // current working directory
    paths.add(fileName);
    return paths;
  }

  // -- Section 0 ---------------------------------------------------------

  late final LfBridgeInitDart lfBridgeInit = _lib.lookupFunction<
      LfBridgeInitNative, LfBridgeInitDart>('lf_bridge_init');

  late final LfBridgeShutdownDart lfBridgeShutdown = _lib.lookupFunction<
      LfBridgeShutdownNative, LfBridgeShutdownDart>('lf_bridge_shutdown');

  late final LfBridgeIsInitializedDart lfBridgeIsInitialized =
      _lib.lookupFunction<LfBridgeIsInitializedNative,
          LfBridgeIsInitializedDart>('lf_bridge_is_initialized');

  // -- Section 1 ---------------------------------------------------------

  late final LfBridgeCreateDataDart lfBridgeCreateData = _lib.lookupFunction<
      LfBridgeCreateDataNative, LfBridgeCreateDataDart>('lf_bridge_create_data');

  late final LfBridgeCreateDataPermanentDart lfBridgeCreateDataPermanent =
      _lib.lookupFunction<LfBridgeCreateDataPermanentNative,
          LfBridgeCreateDataPermanentDart>('lf_bridge_create_data_permanent');

  late final LfBridgeFreeDataDart lfBridgeFreeData = _lib.lookupFunction<
      LfBridgeFreeDataNative, LfBridgeFreeDataDart>('lf_bridge_free_data');

  late final LfBridgeWriteBufferDart lfBridgeWriteBuffer =
      _lib.lookupFunction<LfBridgeWriteBufferNative, LfBridgeWriteBufferDart>(
          'lf_bridge_write_buffer');

  late final LfBridgeReadBufferDart lfBridgeReadBuffer =
      _lib.lookupFunction<LfBridgeReadBufferNative, LfBridgeReadBufferDart>(
          'lf_bridge_read_buffer');

  late final LfBridgeGetPosDart lfBridgeGetPos = _lib.lookupFunction<
      LfBridgeGetPosNative, LfBridgeGetPosDart>('lf_bridge_get_pos');

  late final LfBridgeSetPosDart lfBridgeSetPos = _lib.lookupFunction<
      LfBridgeSetPosNative, LfBridgeSetPosDart>('lf_bridge_set_pos');

  late final LfBridgeGetSizeDart lfBridgeGetSize = _lib.lookupFunction<
      LfBridgeGetSizeNative, LfBridgeGetSizeDart>('lf_bridge_get_size');

  late final LfBridgeSetSizeDart lfBridgeSetSize = _lib.lookupFunction<
      LfBridgeSetSizeNative, LfBridgeSetSizeDart>('lf_bridge_set_size');

  late final LfBridgeGetP2PUidDart lfBridgeGetP2PUid = _lib.lookupFunction<
      LfBridgeGetP2PUidNative,
      LfBridgeGetP2PUidDart>('lf_bridge_get_p2p_uid');

  late final LfBridgeGetP2PNameDart lfBridgeGetP2PName = _lib.lookupFunction<
      LfBridgeGetP2PNameNative,
      LfBridgeGetP2PNameDart>('lf_bridge_get_p2p_name');

  late final LfBridgeWriteUidDart lfBridgeWriteUid = _lib.lookupFunction<
      LfBridgeWriteUidNative, LfBridgeWriteUidDart>('lf_bridge_write_uid');

  late final LfBridgeReadUidDart lfBridgeReadUid = _lib.lookupFunction<
      LfBridgeReadUidNative, LfBridgeReadUidDart>('lf_bridge_read_uid');

  // -- Section 2 ---------------------------------------------------------

  late final LfBridgeCreateAppDart lfBridgeCreateApp = _lib.lookupFunction<
      LfBridgeCreateAppNative, LfBridgeCreateAppDart>('lf_bridge_create_app');

  late final LfBridgeFreeAppDart lfBridgeFreeApp = _lib.lookupFunction<
      LfBridgeFreeAppNative, LfBridgeFreeAppDart>('lf_bridge_free_app');

  late final LfBridgeGetAppNameDart lfBridgeGetAppName = _lib.lookupFunction<
      LfBridgeGetAppNameNative,
      LfBridgeGetAppNameDart>('lf_bridge_get_app_name');

  late final LfBridgeGenerateAppNameDart lfBridgeGenerateAppName =
      _lib.lookupFunction<LfBridgeGenerateAppNameNative,
          LfBridgeGenerateAppNameDart>('lf_bridge_generate_app_name');

  late final LfBridgeBindAppDart lfBridgeBindApp = _lib.lookupFunction<
      LfBridgeBindAppNative, LfBridgeBindAppDart>('lf_bridge_bind_app');

  // -- Section 3 ---------------------------------------------------------

  late final LfBridgeRegisterCallDart lfBridgeRegisterCall =
      _lib.lookupFunction<LfBridgeRegisterCallNative, LfBridgeRegisterCallDart>(
          'lf_bridge_register_call');

  late final LfBridgeRegisterNotifyDart lfBridgeRegisterNotify =
      _lib.lookupFunction<LfBridgeRegisterNotifyNative,
          LfBridgeRegisterNotifyDart>('lf_bridge_register_notify');

  late final LfBridgeUnregisterDart lfBridgeUnregister = _lib.lookupFunction<
      LfBridgeUnregisterNative,
      LfBridgeUnregisterDart>('lf_bridge_unregister');

  late final LfBridgeCompleteDart lfBridgeComplete = _lib.lookupFunction<
      LfBridgeCompleteNative, LfBridgeCompleteDart>('lf_bridge_complete');

  // -- Section 4 ---------------------------------------------------------

  late final LfBridgeRegisterP2PCallDart lfBridgeRegisterP2PCall =
      _lib.lookupFunction<LfBridgeRegisterP2PCallNative,
          LfBridgeRegisterP2PCallDart>('lf_bridge_register_p2p_call');

  late final LfBridgeRegisterP2PNotifyDart lfBridgeRegisterP2PNotify =
      _lib.lookupFunction<LfBridgeRegisterP2PNotifyNative,
          LfBridgeRegisterP2PNotifyDart>('lf_bridge_register_p2p_notify');

  late final LfBridgeUnregisterP2PDart lfBridgeUnregisterP2P =
      _lib.lookupFunction<LfBridgeUnregisterP2PNative, LfBridgeUnregisterP2PDart>(
          'lf_bridge_unregister_p2p');

  // -- Section 5 ---------------------------------------------------------

  late final LfBridgeLocalCallDart lfBridgeLocalCall = _lib.lookupFunction<
      LfBridgeLocalCallNative, LfBridgeLocalCallDart>('lf_bridge_local_call');

  late final LfBridgeLocalNotifyDart lfBridgeLocalNotify = _lib.lookupFunction<
      LfBridgeLocalNotifyNative,
      LfBridgeLocalNotifyDart>('lf_bridge_local_notify');

  // -- Section 6 ---------------------------------------------------------

  late final LfBridgeResetPrepareDart lfBridgeResetPrepare =
      _lib.lookupFunction<LfBridgeResetPrepareNative, LfBridgeResetPrepareDart>(
          'lf_bridge_reset_prepare');

  late final LfBridgePrepareServiceDart lfBridgePrepareService =
      _lib.lookupFunction<LfBridgePrepareServiceNative,
          LfBridgePrepareServiceDart>('lf_bridge_prepare_service');

  late final LfBridgePrepareClientDart lfBridgePrepareClient =
      _lib.lookupFunction<LfBridgePrepareClientNative, LfBridgePrepareClientDart>(
          'lf_bridge_prepare_client');

  late final LfBridgePrepareDoneDart lfBridgePrepareDone = _lib.lookupFunction<
      LfBridgePrepareDoneNative,
      LfBridgePrepareDoneDart>('lf_bridge_prepare_done');

  late final LfBridgeExitMainThreadDart lfBridgeExitMainThread =
      _lib.lookupFunction<LfBridgeExitMainThreadNative,
          LfBridgeExitMainThreadDart>('lf_bridge_exit_main_thread');

  late final LfBridgeLfShutdownDart lfBridgeLfShutdown = _lib.lookupFunction<
      LfBridgeLfShutdownNative,
      LfBridgeLfShutdownDart>('lf_bridge_lf_shutdown');

  // -- Section 7 ---------------------------------------------------------

  late final LfBridgeCallDart lfBridgeCall = _lib.lookupFunction<
      LfBridgeCallNative, LfBridgeCallDart>('lf_bridge_call');

  late final LfBridgeNotifyDart lfBridgeNotify = _lib.lookupFunction<
      LfBridgeNotifyNative, LfBridgeNotifyDart>('lf_bridge_notify');

  late final LfBridgeSequencedNotifyDart lfBridgeSequencedNotify =
      _lib.lookupFunction<LfBridgeSequencedNotifyNative,
          LfBridgeSequencedNotifyDart>('lf_bridge_sequenced_notify');

  late final LfBridgeCallAsyncDart lfBridgeCallAsync = _lib.lookupFunction<
      LfBridgeCallAsyncNative, LfBridgeCallAsyncDart>('lf_bridge_call_async');

  late final LfBridgeCallAsyncSequencedDart lfBridgeCallAsyncSequenced =
      _lib.lookupFunction<LfBridgeCallAsyncSequencedNative,
          LfBridgeCallAsyncSequencedDart>('lf_bridge_call_async_sequenced');

  // -- Section 8 ---------------------------------------------------------

  late final LfBridgeUidCallDart lfBridgeUidCall = _lib.lookupFunction<
      LfBridgeUidCallNative, LfBridgeUidCallDart>('lf_bridge_uid_call');

  late final LfBridgeUidNotifyDart lfBridgeUidNotify = _lib.lookupFunction<
      LfBridgeUidNotifyNative, LfBridgeUidNotifyDart>('lf_bridge_uid_notify');

  late final LfBridgeUidSequencedNotifyDart lfBridgeUidSequencedNotify =
      _lib.lookupFunction<LfBridgeUidSequencedNotifyNative,
          LfBridgeUidSequencedNotifyDart>('lf_bridge_uid_sequenced_notify');

  late final LfBridgeUidCallAsyncDart lfBridgeUidCallAsync =
      _lib.lookupFunction<LfBridgeUidCallAsyncNative, LfBridgeUidCallAsyncDart>(
          'lf_bridge_uid_call_async');

  late final LfBridgeUidCallAsyncSequencedDart lfBridgeUidCallAsyncSequenced =
      _lib.lookupFunction<LfBridgeUidCallAsyncSequencedNative,
          LfBridgeUidCallAsyncSequencedDart>(
          'lf_bridge_uid_call_async_sequenced');

  // -- Section 9 ---------------------------------------------------------

  late final LfBridgeP2PNameCallDart lfBridgeP2PNameCall =
      _lib.lookupFunction<LfBridgeP2PNameCallNative, LfBridgeP2PNameCallDart>(
          'lf_bridge_p2pname_call');

  late final LfBridgeP2PNameNotifyDart lfBridgeP2PNameNotify =
      _lib.lookupFunction<LfBridgeP2PNameNotifyNative,
          LfBridgeP2PNameNotifyDart>('lf_bridge_p2pname_notify');

  late final LfBridgeP2PNameSequencedNotifyDart lfBridgeP2PNameSequencedNotify =
      _lib.lookupFunction<LfBridgeP2PNameSequencedNotifyNative,
          LfBridgeP2PNameSequencedNotifyDart>(
          'lf_bridge_p2pname_sequenced_notify');

  late final LfBridgeP2PNameCallAsyncDart lfBridgeP2PNameCallAsync =
      _lib.lookupFunction<LfBridgeP2PNameCallAsyncNative,
          LfBridgeP2PNameCallAsyncDart>('lf_bridge_p2pname_call_async');

  late final LfBridgeP2PNameCallAsyncSequencedDart
      lfBridgeP2PNameCallAsyncSequenced = _lib.lookupFunction<
          LfBridgeP2PNameCallAsyncSequencedNative,
          LfBridgeP2PNameCallAsyncSequencedDart>(
          'lf_bridge_p2pname_call_async_sequenced');

  // -- Section 10 --------------------------------------------------------

  late final LfBridgeCheckMainThreadDart lfBridgeCheckMainThread =
      _lib.lookupFunction<LfBridgeCheckMainThreadNative,
          LfBridgeCheckMainThreadDart>('lf_bridge_check_main_thread');

  late final LfBridgeCheckAppDart lfBridgeCheckApp = _lib.lookupFunction<
      LfBridgeCheckAppNative, LfBridgeCheckAppDart>('lf_bridge_check_app');

  late final LfBridgeCheckApiDart lfBridgeCheckApi = _lib.lookupFunction<
      LfBridgeCheckApiNative, LfBridgeCheckApiDart>('lf_bridge_check_api');

  late final LfBridgeCheckUidDart lfBridgeCheckUid = _lib.lookupFunction<
      LfBridgeCheckUidNative, LfBridgeCheckUidDart>('lf_bridge_check_uid');

  late final LfBridgeCheckUidApiDart lfBridgeCheckUidApi = _lib.lookupFunction<
      LfBridgeCheckUidApiNative,
      LfBridgeCheckUidApiDart>('lf_bridge_check_uid_api');

  late final LfBridgeCheckP2PNameDart lfBridgeCheckP2PName =
      _lib.lookupFunction<LfBridgeCheckP2PNameNative, LfBridgeCheckP2PNameDart>(
          'lf_bridge_check_p2pname');

  late final LfBridgeCheckP2PNameApiDart lfBridgeCheckP2PNameApi =
      _lib.lookupFunction<LfBridgeCheckP2PNameApiNative,
          LfBridgeCheckP2PNameApiDart>('lf_bridge_check_p2pname_api');

  // -- Section 11: Options ----------------------------------------------

  // Authentication
  late final LfBridgeSetOptStrDart lfBridgeSetOptPassword =
      _lib.lookupFunction<LfBridgeSetOptStrNative, LfBridgeSetOptStrDart>(
          'lf_bridge_set_opt_password');
  late final LfBridgeGetOptStrDart lfBridgeGetOptPassword =
      _lib.lookupFunction<LfBridgeGetOptStrNative, LfBridgeGetOptStrDart>(
          'lf_bridge_get_opt_password');

  // Debug
  late final LfBridgeSetOptStrDart lfBridgeSetOptDebug =
      _lib.lookupFunction<LfBridgeSetOptStrNative, LfBridgeSetOptStrDart>(
          'lf_bridge_set_opt_debug');
  late final LfBridgeGetOptStrDart lfBridgeGetOptDebug =
      _lib.lookupFunction<LfBridgeGetOptStrNative, LfBridgeGetOptStrDart>(
          'lf_bridge_get_opt_debug');

  // Quiet
  late final LfBridgeSetOptIntDart lfBridgeSetOptQuiet =
      _lib.lookupFunction<LfBridgeSetOptIntNative, LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_quiet');
  late final LfBridgeGetOptIntDart lfBridgeGetOptQuiet =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_quiet');

  // ShowThreadID
  late final LfBridgeSetOptIntDart lfBridgeSetOptShowThreadId =
      _lib.lookupFunction<LfBridgeSetOptIntNative, LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_show_thread_id');
  late final LfBridgeGetOptIntDart lfBridgeGetOptShowThreadId =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_show_thread_id');

  // ConsoleOutput
  late final LfBridgeSetOptIntDart lfBridgeSetOptConsoleOutput =
      _lib.lookupFunction<LfBridgeSetOptIntNative, LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_console_output');
  late final LfBridgeGetOptIntDart lfBridgeGetOptConsoleOutput =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_console_output');

  // OverlapConnection
  late final LfBridgeSetOptIntDart lfBridgeSetOptOverlapConnection =
      _lib.lookupFunction<LfBridgeSetOptIntNative, LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_overlap_connection');
  late final LfBridgeGetOptIntDart lfBridgeGetOptOverlapConnection =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_overlap_connection');

  // WaitConnectionReadyOk
  late final LfBridgeSetOptIntDart lfBridgeSetOptWaitConnectionReadyOk =
      _lib.lookupFunction<LfBridgeSetOptIntNative, LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_wait_connection_ready_ok');
  late final LfBridgeGetOptIntDart lfBridgeGetOptWaitConnectionReadyOk =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_wait_connection_ready_ok');

  // WaitConnectionTimeout
  late final LfBridgeSetOptU64Dart lfBridgeSetOptWaitConnectionTimeout =
      _lib.lookupFunction<LfBridgeSetOptU64Native, LfBridgeSetOptU64Dart>(
          'lf_bridge_set_opt_wait_connection_timeout');
  late final LfBridgeGetOptIntDart lfBridgeGetOptWaitConnectionTimeout =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_wait_connection_timeout');

  // IpcServThreadCount
  late final LfBridgeSetOptIntDart lfBridgeSetOptIpcServThreadCount =
      _lib.lookupFunction<LfBridgeSetOptIntNative, LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_ipc_serv_thread_count');
  late final LfBridgeGetOptIntDart lfBridgeGetOptIpcServThreadCount =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_ipc_serv_thread_count');

  // IpcServMaxQueueLength
  late final LfBridgeSetOptIntDart lfBridgeSetOptIpcServMaxQueueLength =
      _lib.lookupFunction<LfBridgeSetOptIntNative, LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_ipc_serv_max_queue_length');
  late final LfBridgeGetOptIntDart lfBridgeGetOptIpcServMaxQueueLength =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_ipc_serv_max_queue_length');

  // IpcServMaxMsgSize
  late final LfBridgeSetOptIntDart lfBridgeSetOptIpcServMaxMsgSize =
      _lib.lookupFunction<LfBridgeSetOptIntNative, LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_ipc_serv_max_msg_size');
  late final LfBridgeGetOptIntDart lfBridgeGetOptIpcServMaxMsgSize =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_ipc_serv_max_msg_size');

  // FixedSequencedTime
  late final LfBridgeSetOptU64Dart lfBridgeSetOptFixedSequencedTime =
      _lib.lookupFunction<LfBridgeSetOptU64Native, LfBridgeSetOptU64Dart>(
          'lf_bridge_set_opt_fixed_sequenced_time');
  late final LfBridgeGetOptIntDart lfBridgeGetOptFixedSequencedTime =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_fixed_sequenced_time');

  // P2PName
  late final LfBridgeSetOptStrDart lfBridgeSetOptP2PName =
      _lib.lookupFunction<LfBridgeSetOptStrNative, LfBridgeSetOptStrDart>(
          'lf_bridge_set_opt_p2p_name');
  late final LfBridgeGetOptStrDart lfBridgeGetOptP2PName =
      _lib.lookupFunction<LfBridgeGetOptStrNative, LfBridgeGetOptStrDart>(
          'lf_bridge_get_opt_p2p_name');

  // DataHandleIdleTimeout
  late final LfBridgeSetOptU64Dart lfBridgeSetOptDataHandleIdleTimeout =
      _lib.lookupFunction<LfBridgeSetOptU64Native, LfBridgeSetOptU64Dart>(
          'lf_bridge_set_opt_data_handle_idle_timeout');
  late final LfBridgeGetOptIntDart lfBridgeGetOptDataHandleIdleTimeout =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_data_handle_idle_timeout');

  // DataHandlePoolScanInterval
  late final LfBridgeSetOptU64Dart lfBridgeSetOptDataHandlePoolScanInterval =
      _lib.lookupFunction<LfBridgeSetOptU64Native, LfBridgeSetOptU64Dart>(
          'lf_bridge_set_opt_data_handle_pool_scan_interval');
  late final LfBridgeGetOptIntDart lfBridgeGetOptDataHandlePoolScanInterval =
      _lib.lookupFunction<LfBridgeGetOptIntNative, LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_data_handle_pool_scan_interval');

  // NoReponseCmdNullFlushThreshold
  late final LfBridgeSetOptIntDart
      lfBridgeSetOptNoReponseCmdNullFlushThreshold = _lib.lookupFunction<
          LfBridgeSetOptIntNative,
          LfBridgeSetOptIntDart>(
          'lf_bridge_set_opt_no_reponse_cmd_null_flush_threshold');
  late final LfBridgeGetOptIntDart
      lfBridgeGetOptNoReponseCmdNullFlushThreshold = _lib.lookupFunction<
          LfBridgeGetOptIntNative,
          LfBridgeGetOptIntDart>(
          'lf_bridge_get_opt_no_reponse_cmd_null_flush_threshold');

  // Generic escape hatch
  late final LfBridgeSetOptionDart lfBridgeSetOption = _lib.lookupFunction<
      LfBridgeSetOptionNative, LfBridgeSetOptionDart>('lf_bridge_set_option');

  late final LfBridgeGetOptionDart lfBridgeGetOption = _lib.lookupFunction<
      LfBridgeGetOptionNative, LfBridgeGetOptionDart>('lf_bridge_get_option');

  // -- Section 12 --------------------------------------------------------

  late final LfBridgeGetStatusCountDart lfBridgeGetStatusCount =
      _lib.lookupFunction<LfBridgeGetStatusCountNative,
          LfBridgeGetStatusCountDart>('lf_bridge_get_status_count');

  late final LfBridgeGetStatusDart lfBridgeGetStatus = _lib.lookupFunction<
      LfBridgeGetStatusNative, LfBridgeGetStatusDart>('lf_bridge_get_status');

  late final LfBridgePostStatusDart lfBridgePostStatus = _lib.lookupFunction<
      LfBridgePostStatusNative,
      LfBridgePostStatusDart>('lf_bridge_post_status');

  // -- Section 13 --------------------------------------------------------

  late final LfBridgeSetNetworkEventDart lfBridgeSetNetworkEvent =
      _lib.lookupFunction<LfBridgeSetNetworkEventNative,
          LfBridgeSetNetworkEventDart>('lf_bridge_set_network_event');

  late final LfBridgeClearNetworkEventDart lfBridgeClearNetworkEvent =
      _lib.lookupFunction<LfBridgeClearNetworkEventNative,
          LfBridgeClearNetworkEventDart>('lf_bridge_clear_network_event');

  // -- Section 15 --------------------------------------------------------

  late final LfBridgeLastErrorDart lfBridgeLastError = _lib.lookupFunction<
      LfBridgeLastErrorNative, LfBridgeLastErrorDart>('lf_bridge_last_error');

  late final LfBridgeVersionDart lfBridgeVersion = _lib.lookupFunction<
      LfBridgeVersionNative, LfBridgeVersionDart>('lf_bridge_version');

  late final LfBridgeStatsJsonDart lfBridgeStatsJson = _lib.lookupFunction<
      LfBridgeStatsJsonNative,
      LfBridgeStatsJsonDart>('lf_bridge_stats_json');
}