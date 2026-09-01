# -*- coding: utf-8 -*-
"""
Low‑level ctypes bindings for the LingoFuse dynamic library.

All exported functions are loaded from the platform‑specific shared library
(LingoFuse64.dll / liblingofuse.so / liblingofuse.dylib) at module import.

=========================== THREAD SAFETY ===========================
All functions are FULLY thread‑safe and can be called concurrently
from any number of threads.

==================== CALLBACK EXECUTION CONTEXT ====================
Callbacks (LFCallFunc, LFNotifyFunc) are executed in background
threads from the library's internal thread pool. Therefore:
    * Do NOT perform long‑blocking operations inside callbacks.
    * Do NOT call LF_Call() or LF_Notify() from within a callback
      – this may cause deadlocks.
    * Do NOT access UI components or thread‑local storage without
      proper synchronisation.
    * Offload heavy processing to separate worker threads.

These restrictions exactly mirror those documented in the Pascal unit
Z.LingoFuse_Export.

==================== DYNAMIC UNREGISTRATION =======================
LF_Unregister removes an API from the local registry immediately and
triggers an asynchronous network broadcast. Remote peers will stop
seeing this API within ~3 seconds (depending on network latency and
C4 update interval).

==================== RUNTIME OPTIONS =============================
LF_SetOption dynamically adjusts global runtime options such as
authentication password, wait‑connection behavior, IPC parameters, etc.
All changes take effect immediately (except where noted).
Unknown options are silently ignored.
"""
import ctypes
import sys
import os

class LingoFuseError(Exception):
    """Raised when the library cannot be loaded or a call fails."""
    pass

def _find_library():
    """Return the correct shared library name for the current platform."""
    if sys.platform == "win32":
        return "LingoFuse64.dll" if ctypes.sizeof(ctypes.c_void_p) == 8 else "LingoFuse32.dll"
    elif sys.platform == "darwin":
        return "liblingofuse.dylib"
    else:
        return "liblingofuse.so"  # Linux, BSD, and other ELF systems

def _load_library():
    """
    Locate and load the shared library, primarily using the system PATH.
    Fallback to the current working directory if PATH lookup fails.
    """
    lib_name = _find_library()
    is_64bit = ctypes.sizeof(ctypes.c_void_p) == 8

    # ----- Windows specific: add system PATH directories to DLL search path -----
    if sys.platform == "win32":
        for p in os.environ.get("PATH", "").split(os.pathsep):
            if p and os.path.isdir(p):
                try:
                    os.add_dll_directory(p)
                except Exception:
                    pass
        # Pre-load the IPC dependency library from PATH (only the correct bitness)
        dep_name = "z_ipc_64.dll" if is_64bit else "z_ipc_32.dll"
        # Note: LingoFuse may rely on IPC helper libraries; we attempt to preload them
        for p in os.environ.get("PATH", "").split(os.pathsep):
            if not p:
                continue
            dep_path = os.path.join(p, dep_name)
            if os.path.exists(dep_path):
                try:
                    ctypes.WinDLL(dep_path)
                    break
                except Exception:
                    pass

    # ----- Attempt to load the main library -----
    try:
        if sys.platform == "win32":
            lib = ctypes.WinDLL(lib_name, winmode=0)
        else:
            lib = ctypes.CDLL(lib_name)
        print(f"[INFO] Successfully loaded from system PATH: {lib_name}")
        return lib
    except OSError:
        pass

    # Fallback: try loading from the current working directory
    cwd_path = os.path.join(os.getcwd(), lib_name)
    if os.path.exists(cwd_path):
        try:
            if sys.platform == "win32":
                lib = ctypes.WinDLL(cwd_path, winmode=0)
            else:
                lib = ctypes.CDLL(cwd_path)
            print(f"[INFO] Successfully loaded from current directory: {cwd_path}")
            return lib
        except OSError:
            pass

    raise LingoFuseError(f"Cannot load library: {lib_name}. Ensure it is in the system PATH or current directory.")

_lib = _load_library()

def _set_func(name, argtypes, restype):
    func = getattr(_lib, name)
    func.argtypes = argtypes
    func.restype = restype
    return func

# Opaque handle types
DataHnd = ctypes.c_void_p
AppHnd = ctypes.c_void_p

# Callback function prototypes – must match the C calling convention (cdecl)
LFCallFunc = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
LFNotifyFunc = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_void_p)

# ----------------------------------------------------------------------
# Data Handle Operations
# ----------------------------------------------------------------------
LF_CreateData = _set_func("LF_CreateData", [ctypes.c_char_p], DataHnd)
LF_FreeData = _set_func("LF_FreeData", [DataHnd], None)
LF_GetBuffer = _set_func("LF_GetBuffer", [DataHnd], ctypes.c_void_p)
LF_WriteBuffer = _set_func("LF_WriteBuffer", [DataHnd, ctypes.c_void_p, ctypes.c_int64], ctypes.c_int64)
LF_ReadBuffer = _set_func("LF_ReadBuffer", [DataHnd, ctypes.c_void_p, ctypes.c_int64], ctypes.c_int64)
LF_GetPos = _set_func("LF_GetPos", [DataHnd], ctypes.c_int64)
LF_SetPos = _set_func("LF_SetPos", [DataHnd, ctypes.c_int64], None)
LF_GetSize = _set_func("LF_GetSize", [DataHnd], ctypes.c_int64)
LF_SetSize = _set_func("LF_SetSize", [DataHnd, ctypes.c_int64], None)

# ----------------------------------------------------------------------
# Application Handle Operations
# ----------------------------------------------------------------------
LF_CreateApp = _set_func("LF_CreateApp", [ctypes.c_char_p, ctypes.c_char_p], AppHnd)
LF_FreeApp = _set_func("LF_FreeApp", [AppHnd], None)
LF_RegisterCall = _set_func("LF_RegisterCall", [AppHnd, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, LFCallFunc], ctypes.c_int)
LF_RegisterNotify = _set_func("LF_RegisterNotify", [AppHnd, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, LFNotifyFunc], ctypes.c_int)
LF_Unregister = _set_func("LF_Unregister", [AppHnd, ctypes.c_char_p], ctypes.c_int)
LF_LocalCall = _set_func("LF_LocalCall", [AppHnd, DataHnd], DataHnd)
LF_LocalNotify = _set_func("LF_LocalNotify", [AppHnd, DataHnd], None)

# ----------------------------------------------------------------------
# Network Preparation and Communication
# ----------------------------------------------------------------------
LF_PrepareService = _set_func("LF_PrepareService", [ctypes.c_char_p, ctypes.c_char_p], ctypes.c_int)
LF_PrepareClient = _set_func("LF_PrepareClient", [ctypes.c_char_p, AppHnd], ctypes.c_int)
LF_ResetPrepare = _set_func("LF_ResetPrepare", [], None)
LF_PrepareDone = _set_func("LF_PrepareDone", [], ctypes.c_int)
LF_ExitMainThread = _set_func("LF_ExitMainThread", [], None)
LF_Call = _set_func("LF_Call", [ctypes.c_char_p, DataHnd, ctypes.c_uint64], DataHnd)
LF_Notify = _set_func("LF_Notify", [ctypes.c_char_p, DataHnd], None)
LF_SetOption = _set_func("LF_SetOption", [ctypes.c_char_p, ctypes.c_char_p], None)
LF_Shutdown = _set_func("LF_Shutdown", [], None)

# ----------------------------------------------------------------------
# New in LingoFuse: Sequenced Notify, Status, and Check functions
# ----------------------------------------------------------------------
LF_Sequenced_Notify = _set_func("LF_Sequenced_Notify", [ctypes.c_char_p, DataHnd], None)

LF_GetStatusCount = _set_func("LF_GetStatusCount", [], ctypes.c_int)
LF_GetStatus = _set_func("LF_GetStatus", [], ctypes.c_char_p)
LF_PostStatus = _set_func("LF_PostStatus", [ctypes.c_char_p], None)

LF_CheckMainThread = _set_func("LF_CheckMainThread", [], ctypes.c_int)
LF_CheckApp = _set_func("LF_CheckApp", [ctypes.c_char_p], ctypes.c_int)
LF_CheckApi = _set_func("LF_CheckApi", [ctypes.c_char_p, ctypes.c_char_p], ctypes.c_int)
# -----------------------------------------