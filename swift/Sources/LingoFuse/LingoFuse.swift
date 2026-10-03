//
//  LingoFuse.swift
//  LingoFuse
//
//  Swift module entry point for the LingoFuse binding.
//
//  This module re-exports the CLingoFuse C target so that callers only
//  need a single `import LingoFuse` statement. All 37 C ABI symbols
//  (LF_LoadLibrary, LF_CreateData, LF_Call, ...) are visible through
//  this module because the Clang importer hoists every public
//  declaration from the C target into the Swift target's namespace.
//
//  Step 1 (this file): the C ABI is exposed directly. Callers who want
//  raw access can use LF_* functions exactly as they would in C.
//
//  Step 2 (future): RAII wrappers (DataHandle, AppHandle), JSON I/O
//  helpers (LfIo), and the process-wide facade (Framework) will be
//  added to this module.
//

@_exported import CLingoFuse