// Runtime loading of the LingoFuse native libraries.
//
// TWO LOADING PATHS
// -----------------
// This package currently supports two ways of talking to LingoFuse:
//
//   1. LEGACY  getBindings()
//        Loads LingoFuse64.dll directly and returns the ffigen-generated
//        bindings. Used by the v1.x DataHandle / AppHandle / Framework
//        code paths. Kept for backward compatibility.
//
//   2. BRIDGE  getBridge()
//        Loads lf_dart_bridge.dll and returns the C bridge wrapper.
//        Every LF_* call goes through the bridge, which handles UID
//        marshalling, callback synchronisation, and typed options.
//        This is the future path: v2.0 will migrate every caller to it.
//
// The two paths may coexist in the same process. LingoFuse64.dll is
// loaded once by each; the OS shares the module, so there is no state
// duplication inside LingoFuse itself.
//
// All diagnostics are in English.

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bindings_generated.dart';
import 'bridge/bridge_ffi.dart';
import 'errors.dart';

// ===========================================================================
// Legacy path: direct load of LingoFuse64.dll
// ===========================================================================

/// Selects the platform-specific shared library file name for
/// LingoFuse itself.
String selectPlatformFileName() {
  if (Platform.isWindows) {
    return (sizeOf<Pointer>() == 8) ? 'LingoFuse64.dll' : 'LingoFuse32.dll';
  } else if (Platform.isMacOS) {
    return 'liblingofuse.dylib';
  } else if (Platform.isLinux) {
    return 'liblingofuse.so';
  }
  throw LingoFuseLibraryLoadError(
    'unknown',
    message: 'Unsupported platform: ${Platform.operatingSystem}',
  );
}

/// Builds the list of candidate paths to try before falling back to
/// the system loader search path.
List<String> buildSearchPaths() {
  final fileName = selectPlatformFileName();
  final candidates = <String>[];

  // 1. Explicit override via environment variable.
  final envOverride = Platform.environment['LINGOFUSE_DLL'];
  if (envOverride != null && envOverride.isNotEmpty) {
    candidates.add(envOverride);
  }

  // 2. Current working directory.
  candidates.add(p.join(Directory.current.path, fileName));

  // 3. Package-local native/ folder.
  candidates.add(p.join(Directory.current.path, 'native', fileName));

  return candidates;
}

DynamicLibrary _loadLibrary() {
  final fileName = selectPlatformFileName();
  final tried = <String>[];

  for (final path in buildSearchPaths()) {
    try {
      if (File(path).existsSync()) {
        return DynamicLibrary.open(path);
      }
      tried.add('$path (not found)');
    } catch (e) {
      tried.add('$path ($e)');
    }
  }

  // Last resort: let the OS loader resolve the bare name via PATH.
  try {
    return DynamicLibrary.open(fileName);
  } catch (e) {
    throw LingoFuseLibraryLoadError(
      fileName,
      message: 'Failed to load $fileName.\n'
          'Tried:\n  ${tried.join('\n  ')}\n'
          'Also tried bare name "$fileName" on the system loader path: $e',
      cause: e,
    );
  }
}

LingoFuseBindings? _bindings;

/// Returns the process-wide direct LingoFuse bindings singleton,
/// loading LingoFuse64.dll on first call.
///
/// This is the legacy path. New code should prefer [getBridge].
LingoFuseBindings getBindings() {
  return _bindings ??= LingoFuseBindings(_loadLibrary());
}

// ===========================================================================
// Bridge path: load lf_dart_bridge.dll
// ===========================================================================

/// Returns the process-wide bridge singleton, loading
/// lf_dart_bridge.dll on first call.
///
/// This is the recommended path for all new code. The bridge wraps
/// every LF_* function and resolves Dart's FFI limitations (struct
/// marshalling, callback threading, transient pointers) on the C side.
///
/// May be called before or after [getBindings]; the two paths are
/// independent and can coexist.
BridgeFfi getBridge() {
  return BridgeFfi.load();
}