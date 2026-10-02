// Runtime loading of the LingoFuse native library.

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bindings_generated.dart';
import 'errors.dart';

/// Selects the platform-specific shared library file name.
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

/// Returns the process-wide LingoFuse bindings singleton, loading the
/// native library on first call.
LingoFuseBindings getBindings() {
  return _bindings ??= LingoFuseBindings(_loadLibrary());
}