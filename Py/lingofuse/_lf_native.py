# -*- coding: utf-8 -*-
"""
Low-level ctypes bindings for the LingoFuse dynamic library.

All exported functions are loaded from the platform-specific shared library
(LingoFuse64.dll / LingoFuse32.dll / liblingofuse.so / liblingofuse.dylib)
at module import.

The binding set is a 1:1 mirror of the C ABI symbols listed in
``LingoFuse.lpr`` (the exports clause of the shared library). Every symbol
exported by the shared library MUST have a corresponding binding here,
otherwise Python callers cannot reach it. Conversely, every binding here
MUST have a corresponding exported symbol, otherwise module import fails
with a clear AttributeError when the symbol lookup is attempted.

=========================== THREAD SAFETY ===========================
All functions are FULLY thread-safe and can be called concurrently
from any number of threads. This matches the library's documented
guarantee.

==================== CALLBACK EXECUTION CONTEXT ====================
Callbacks (LFCallFunc, LFNotifyFunc, LFAsyncCallOnResult,
LFNetworkEventFunc) are executed in background threads from the
library's internal thread pool. Therefore:
    * Do NOT perform long-blocking operations inside callbacks.
    * Do NOT call LF_Call() or LF_Notify() from within a callback
      - this may cause deadlocks.
    * Do NOT access UI components or thread-local storage without
      proper synchronisation.
    * Offload heavy processing to separate worker threads.

These restrictions are part of the LingoFuse callback contract and
are critical for correct operation across all supported languages.

==================== DATA HANDLE KINDS ==============================
The library provides two kinds of data handles:

  1. AUTO-RECYCLED (LF_CreateData):
       - The handle is added to the library's idle pool.
       - The pool scans every 5 seconds and frees any handle that has
         been idle (no accessor call) for more than 10 MINUTES.
       - Any accessor (LF_GetSize, LF_GetPos, LF_ReadBuffer,
         LF_WriteBuffer, ...) refreshes the idle timestamp.
       - LF_FreeData only marks the handle as deleted; the actual
         release happens on the next pool scan (at most 5 seconds later).
       - Recommended for the vast majority of use cases.

  2. PERMANENT (LF_CreateData_Permanent):
       - The handle is NOT added to the idle pool.
       - The automatic idle-timeout reclaimer will NEVER free it,
         no matter how long it has been idle.
       - LF_FreeData releases it IMMEDIATELY (synchronously).
       - Recommended for handles that must survive for the entire
         process lifetime (cached request templates, long-lived
         scratch buffers, global registries, etc.).

==================== SECONDARY MEMORY POOL ==========================
Freed TLF_Data records are not immediately Disposed; they are pushed
back into a secondary pool (TLF_DataMemory) that reuses them on the
next LF_CreateData call. This reduces New/Dispose churn. The pool is
released in full when LF_Shutdown is called.

==================== CALLING COUNTER ================================
While a remote call is in flight, the input handle's internal
calling___ counter is > 0. The pool scanner treats this the same as
a fresh accessor call, so the handle cannot be reclaimed even if it
would otherwise be past the 10-minute idle threshold. User code does
NOT call the counter directly; the LF_Call / LF_LocalCall / LF_Notify /
LF_Sequenced_Notify implementations maintain it.

==================== AUTO SENDER IDENTITY (SIDE DATA) =================
Every inbound request payload carries two identity fields that the
framework injects automatically on the SENDER side (Pascal:
TC40_LF_Client.Send_* -> TMemory_Param_Tool.Rebuild_UID_and_P2PName):

    * FromUID      - the sender's 32-byte session UID
    * FromP2PName  - the sender's user-supplied P2P group name

These two fields are "side data": they are NOT properties of the
handle itself. They are metadata that the sender's transport layer
writes into the payload header before transmission. The receiver
side therefore sees them in the Data_Param of the INPUT handle it
receives from the framework.

Because of this design, the reader functions:

    LF_Get_P2P_UID(Input)
    LF_Get_P2P_Name(Input)

work ONLY for INPUT handles. They do NOT work on OUTPUT handles.
They do NOT work on a handle the caller created itself with
LF_CreateData / LF_CreateData_Permanent (such a handle has no
"sender", so its FromUID is Null_UID() and its FromP2PName is
empty).

On the C side, calling either function on a non-input handle logs
a warning and returns a null UID / empty string. It does NOT raise.

{!!!!!  LF_Get_P2P_UID RETURNS A POINTER, NOT A VALUE  !!!!!}
As of the current C ABI revision, LF_Get_P2P_UID returns a POINTER
to the 32-byte UID. Pascal signature:

    function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;

i.e. ``^TUID___`` (a pointer to a 32-byte UID), not ``TUID___`` (the
value itself). The pointer is allocated by the C side via New and is
scheduled for automatic release about 5 seconds after the call
(DelayFreeMem). Callers MUST:

    1. Copy the 32 bytes immediately if they want to retain them.
    2. NOT call any deallocation function on the pointer.
    3. NOT retain the pointer beyond the ~5-second window.

LF_Get_P2P_Name returns a c_char_p (a pointer to a NUL-terminated
UTF-8 string), also released by the C side after ~5 seconds. ctypes
converts a c_char_p RETURN VALUE into a fresh Python bytes object on
the call boundary, so the value is already detached from the C
buffer. Callers who call the low-level binding directly still get a
safe value, but must copy the UID pointer themselves (or use the
high-level wrapper lingofuse.core.DataHandle.get_p2p_uid).

=========================== UID TYPE ================================
The C ABI's TP2P_UID___ is ``array[0..31] of Byte``. That single
Pascal type plays TWO different roles on the ctypes side, and each
role requires a DIFFERENT ctypes representation:

  * As an ARGUMENT (e.g. the first parameter of LF_UID_Call):
        ``TP2P_UID`` -- a ctypes array (``c_ubyte * 32``).
        Passing an array by value in a cdecl call is correctly
        handled by ctypes: the array is placed in memory and its
        address is passed, matching the Pascal-side cdecl convention
        for arrays larger than 16 bytes.

  * As a RETURN VALUE (LF_Get_P2P_UID only):
        The C ABI returns a POINTER to the 32-byte UID
        (``PP2P_UID___`` = ``^TUID___``), NOT the value itself.
        The ctypes representation is therefore a plain pointer
        (``ctypes.c_void_p``). The high-level wrapper
        (lingofuse.core.DataHandle.get_p2p_uid) copies the 32 bytes
        immediately into a Python ``bytes`` object, so the caller
        does not retain the transient C buffer.

{!!!!!  THE TWO ROLES USE DIFFERENT ctypes TYPES  !!!!!}
The argument-role type (``TP2P_UID``, a ctypes array) and the
return-role type (``ctypes.c_void_p``, a pointer) are different
ctypes types, because the C ABI uses them in different positions.
Do NOT unify them "for consistency". The historical bug this
documentation guards against was precisely a mix-up between these
two roles.

=========================== ASYNC CALLBACKS =========================
``LF_Async_Call`` and ``LF_Async_Sequenced_Call`` (and their UID_* and
P2PName_* variants) take an ``LFAsyncCallOnResult`` callback:

    void (*)(void* Data, TDataHnd___ Result_)

* ``Data`` is the opaque ``Data`` argument the caller passed at the
  call site; the library does NOT own it and does NOT free it.
* ``Result_`` is a freshly-created DataHandle owned by the framework.
  It is released IMMEDIATELY after the OnResult callback returns
  (Pascal: TLF_Async_Call_Bridge.Do_Th calls TLF_Data.Free_Data on
  the result handle right after invoking OnResult). The callback
  MUST NOT call LF_FreeData on it, and MUST NOT retain the pointer
  beyond the callback body.

The callback runs on a TCompute worker thread (NOT the calling thread,
NOT the simulated main thread). It MUST NOT block, and MUST NOT call
any synchronous LingoFuse function.

==================== IMPORTANT NOTES (from the wire protocol) =======
- Data handles must be freed explicitly with LF_FreeData, although an
  automatic idle-timeout reclaimer (10 minutes, scanned every 5 s)
  runs on the main thread. Relying on it can cause leaks under heavy
  load.
- Do not free a handle while it is being used in a callback or while
  a remote call is pending.
- API names are case-insensitive when matching, but stored exactly as
  provided. Use consistent naming.
- LF_Call() with timeout 0 means infinite wait. On timeout, an empty
  handle (size 0) is returned - always check LF_GetSize().
- Sequenced notifications (LF_Sequenced_Notify) guarantee FIFO order
  per (app, api) pair; they are slightly slower than plain
  notifications.
- The status queue (LF_GetStatus) holds up to 1000 messages; old ones
  are discarded when full.
- LF_GetStatus and LF_PostStatus rely on the simulated main thread.
  They only work reliably after LF_PrepareDone() has been called.
- LF_PrepareService and LF_PrepareClient can be called even after the
  main thread has started - they take effect immediately (dynamic
  addition).
- LF_PrepareDone, LF_ExitMainThread, and LF_Shutdown are not one-shot.
  You can restart the framework after shutdown.
- In a library (DLL), LF_Shutdown is NOT automatic; you must call it
  explicitly before unloading to avoid resource leaks.

==================== LF_PrepareDone RETURNS 1 ONLY ONCE  ============
Calling LF_PrepareDone() a second time in the same process (without
an intervening LF_Shutdown()) returns 0. Tests that call
LF_PrepareDone() must also call LF_Shutdown() in a finally block, or
they will fail the next LF_PrepareDone() call.

==================== NETWORK ADDRESS UNIQUENESS ====================
- LF_PrepareClient() CANNOT be called twice with the same physical
  address (e.g., same IPC name or TCP host:port). Each address can
  have only one client connection. This is a limitation of the
  underlying C4 service mesh. To create multiple clients, use distinct
  addresses (e.g., different IPC names or different ports).
- This restriction applies regardless of whether an app is attached
  or not. To force overlap on the same address, set the runtime option
  "Overlap_Connection" to "True" BEFORE calling LF_PrepareClient.

==================== NETWORK EVENT API =============================
LF_Set_Network_Event installs a pair of process-global callbacks that
fire when a LingoFuse client transitions between online and offline.

Callback prototype (cdecl):
    void (*)(const char* addr)

CRITICAL CONTRACT:
  * The callbacks run on a BACKGROUND C WORKER THREAD - not on the
    calling thread and not on the simulated main thread. Never touch
    UI or other thread-affine resources directly inside them.
  * The addr buffer is valid ONLY during the callback invocation.
    ctypes automatically decodes c_char_p callback arguments into
    fresh Python bytes objects, so it is safe to keep the resulting
    bytes (or a decoded str) for as long as needed.
  * Exceptions raised inside the callback are swallowed by the
    library. The high-level wrapper (lingofuse.network_events)
    logs them via the standard ``logging`` module instead.
  * Passing None for either argument installs a NULL function
    pointer, which disables that particular callback.

{!!!!!  c_void_p ARGTYPES ARE INTENTIONAL  !!!!!}
The two callback arguments are declared with ``ctypes.c_void_p``
instead of ``LFNetworkEventFunc``. This is because ctypes enforces
strict type checking when an ``argtypes`` entry is a ``CFUNCTYPE``
instance: passing ``None`` in that case raises a TypeError, even
though ``None`` is the standard way to represent a NULL pointer.

Using ``c_void_p`` accepts both ``None`` (NULL) and a
``LFNetworkEventFunc`` instance (implicitly converted to its
function pointer address) without any additional casts.

The high-level Python API on top of this primitive lives in
``lingofuse.network_events`` and should be preferred for all
application code.

==================== THREE ADDRESSING MODES =========================
Remote invocation comes in three flavours, each addressing a different
routing key:

    App Name   - a human-readable string identifying a logical app.
                 Local-first routing: if the caller process itself
                 hosts an App with the matching name, the call is
                 serviced locally without touching the network.

    UID        - a 32-byte session identifier. Routes to the exact
                 client whose TunnelLink produced that UID. UID is
                 regenerated on every reconnect; callers must re-probe
                 after a link loss.

    P2PName    - a user-supplied group name. Routes to any client in
                 the group, chosen by server-side load balancing
                 (Cycle_Anchor) or sticky affinity (FixedSequenced).
                 Never services locally: even if the caller itself
                 is in the group, the call is forwarded to the server.

Each addressing mode has the same five call shapes:
    Call, Async_Call, Async_Sequenced_Call, Notify, Sequenced_Notify.

==================== WINDOWS DLL DIRECTORY HANDLING ================
On Windows, we add every directory in PATH to the DLL search path via
``os.add_dll_directory`` so that the LingoFuse shared library and its
z_ipc_*.dll dependency can be located. The objects returned by
``os.add_dll_directory`` are kept alive for the lifetime of the process
in ``_dll_directory_handles``; otherwise the garbage collector would
silently remove them from the search path and later dynamic loads
(e.g. of a delayed-loaded dependency) would fail.

==================== LANGUAGE-SPECIFIC PITFALLS ====================
- ctypes.c_char_p pointers are automatically converted to bytes when
  passed to functions, but the returned string from LF_Generate_AppName
  must be decoded immediately to avoid accessing freed memory.
- When writing strings to a DataHandle, always append a null terminator
  (matching the standard wire protocol convention) - use the high-level
  wrapper's write_string() method which does this automatically.
- When reading strings from a DataHandle, the incoming data may or may
  not include a null terminator. The high-level read_string() handles
  both cases (fault-tolerant).
- LF_Get_P2P_UID returns a POINTER to a 32-byte UID. Copy the bytes
  immediately with ctypes.string_at(ptr, 32); do not retain the
  pointer, and do not free it.
- Do not use the low-level functions directly unless you understand
  all the above restrictions; use the RAII wrappers (DataHandle, App)
  whenever possible.
"""

import ctypes
import sys
import os


# ======================================================================
# Library loading
# ======================================================================

class LingoFuseError(Exception):
    """Raised when the library cannot be loaded or a call fails."""
    pass


# Keep-alive list for os.add_dll_directory() handles on Windows.
# Each object returned by that function automatically removes its
# directory from the DLL search path when garbage-collected. We keep
# them alive for the whole process lifetime so that delayed loads of
# dependencies (e.g. z_ipc_*.dll) continue to work.
_dll_directory_handles = []


def _find_library():
    """Return the correct shared library name for the current platform."""
    if sys.platform == "win32":
        return (
            "LingoFuse64.dll"
            if ctypes.sizeof(ctypes.c_void_p) == 8
            else "LingoFuse32.dll"
        )
    elif sys.platform == "darwin":
        return "liblingofuse.dylib"
    else:
        return "liblingofuse.so"  # Linux, BSD, and other ELF systems


def _register_windows_dll_directories():
    """
    On Windows, add every existing directory in PATH to the DLL search
    path and pre-load the IPC dependency library from the same directory
    as LingoFuse when possible.

    The handles returned by os.add_dll_directory are stored in the
    module-level ``_dll_directory_handles`` list to prevent the garbage
    collector from silently removing the directories.
    """
    for p in os.environ.get("PATH", "").split(os.pathsep):
        if p and os.path.isdir(p):
            try:
                handle = os.add_dll_directory(p)
                # Keep the handle alive for the process lifetime.
                _dll_directory_handles.append(handle)
            except Exception:
                # Some directories may be inaccessible or already added;
                # silently skip them.
                pass

    # Pre-load z_ipc_*.dll so that it is ready before LingoFuse tries
    # to bind to it. This is a best-effort step; failure here does not
    # necessarily mean the main library cannot be loaded.
    is_64bit = ctypes.sizeof(ctypes.c_void_p) == 8
    dep_name = "z_ipc_64.dll" if is_64bit else "z_ipc_32.dll"
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


def _load_library():
    """
    Locate and load the shared library, primarily using the system PATH.
    Fall back to the current working directory if PATH lookup fails.

    On Windows, we also add each PATH directory to the DLL search path
    to help locate dependencies (e.g., z_ipc_64.dll).
    """
    lib_name = _find_library()

    # ----- Windows specific: configure DLL search directories -----
    if sys.platform == "win32":
        _register_windows_dll_directories()

    # ----- Attempt to load the main library from the system PATH -----
    try:
        if sys.platform == "win32":
            lib = ctypes.WinDLL(lib_name, winmode=0)
        else:
            lib = ctypes.CDLL(lib_name)
        print(f"[INFO] Successfully loaded from system PATH: {lib_name}")
        return lib
    except OSError:
        pass

    # ----- Fallback: try loading from the current working directory -----
    cwd_path = os.path.join(os.getcwd(), lib_name)
    if os.path.exists(cwd_path):
        try:
            if sys.platform == "win32":
                lib = ctypes.WinDLL(cwd_path, winmode=0)
            else:
                lib = ctypes.CDLL(cwd_path)
            print(
                f"[INFO] Successfully loaded from current directory: "
                f"{cwd_path}"
            )
            return lib
        except OSError:
            pass

    # ----- Both attempts failed -----
    raise LingoFuseError(
        f"Cannot load library: {lib_name}. "
        f"Ensure it is in the system PATH or in the current working "
        f"directory. Also verify that the matching z_ipc_*.dll is "
        f"available (required as a runtime dependency)."
    )


_lib = _load_library()


def _set_func(name, argtypes, restype):
    """
    Bind a symbol from the loaded library with the given signature.
    """
    func = getattr(_lib, name)
    func.argtypes = argtypes
    func.restype = restype
    return func


# ======================================================================
# Opaque handle types and value types
# ======================================================================

DataHnd = ctypes.c_void_p
AppHnd = ctypes.c_void_p


# ----------------------------------------------------------------------
# UID type: the C ABI's TP2P_UID___ is ``array[0..31] of Byte``.
#
# That single Pascal type plays TWO different roles on the ctypes side,
# and each role requires a DIFFERENT ctypes representation:
#
#   1. As an ARGUMENT (argtypes entry):
#        ``TP2P_UID`` -- a ctypes array (``c_ubyte * 32``).
#        Passing an array by value in a cdecl call is correctly
#        handled by ctypes: the array is placed in memory and its
#        address is passed, matching the Pascal-side cdecl convention
#        for arrays larger than 16 bytes.
#
#        Used by: LF_UID_Call, LF_UID_Async_Call,
#                 LF_UID_Async_Sequenced_Call,
#                 LF_UID_Notify, LF_UID_Sequenced_Notify,
#                 LF_Check_UID, LF_Check_UID_Api.
#
#   2. As a RETURN VALUE (restype):
#        LF_Get_P2P_UID is the ONLY C ABI function that returns a
#        32-byte UID, and it does so as a POINTER, not by value.
#        Pascal signature:
#
#            function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
#
#        i.e. ``^TUID___``. The ctypes representation is therefore a
#        plain pointer (``ctypes.c_void_p``). The high-level wrapper
#        (lingofuse.core.DataHandle.get_p2p_uid) copies the 32 bytes
#        immediately into a fresh Python ``bytes`` object.
#
# {!!!!!  DO NOT UNIFY THESE TWO ROLES  !!!!!}
# It is tempting to use one ctypes type for both the argument and
# the return position "for consistency". That would reintroduce the
# historical bug this documentation guards against: the argument
# role requires an array (passed by value), while the return role
# requires a pointer. They are different positions in the ABI and
# must be represented differently.
# ----------------------------------------------------------------------

#: Argument-role type: a 32-byte array, passed by value in cdecl.
#: Used as an ARGTYPES entry ONLY.
TP2P_UID = ctypes.c_ubyte * 32


# ======================================================================
# Callback function prototypes
# ----------------------------------------------------------------------
# All callbacks use the C calling convention (cdecl). The Python
# objects returned by CFUNCTYPE(...) MUST be kept alive for as long as
# the C library holds their function pointers - see
# ``lingofuse.network_events._keepalive`` for one example pattern.
# ======================================================================

LFCallFunc = ctypes.CFUNCTYPE(
    None,
    ctypes.c_void_p,   # Trigger
    ctypes.c_void_p,   # Input
    ctypes.c_void_p,   # Output
)

LFNotifyFunc = ctypes.CFUNCTYPE(
    None,
    ctypes.c_void_p,   # Trigger
    ctypes.c_void_p,   # Input
)

#: Callback for the asynchronous remote invocation functions
#: (LF_Async_Call, LF_Async_Sequenced_Call, LF_UID_Async_Call,
#: LF_UID_Async_Sequenced_Call, LF_P2PNAME_Async_Call,
#: LF_P2PNAME_Async_Sequenced_Call).
#:
#: Parameters:
#:     Data    - the opaque pointer the caller passed at the call site.
#:               The library neither owns nor frees it.
#:     Result_ - a DataHandle owned by the framework. It is released
#:               IMMEDIATELY after this callback returns (Pascal:
#:               TLF_Async_Call_Bridge.Do_Th calls TLF_Data.Free_Data
#:               on the result handle right after invoking OnResult).
#:               The callback MUST NOT call LF_FreeData on it, and
#:               MUST NOT retain the pointer past its own return.
#:
#: Execution context: TCompute worker thread (NOT the calling thread
#: and NOT the simulated main thread). The callback MUST NOT block,
#: and MUST NOT call any synchronous LingoFuse function.
LFAsyncCallOnResult = ctypes.CFUNCTYPE(
    None,
    ctypes.c_void_p,   # Data (user data)
    ctypes.c_void_p,   # Result_ (DataHnd)
)

LFNetworkEventFunc = ctypes.CFUNCTYPE(
    None,
    ctypes.c_char_p,   # addr (UTF-8, null-terminated)
)


# ======================================================================
# Data Handle Operations
# ======================================================================

# ----------------------------------------------------------------------
# LF_CreateData: creates an AUTO-RECYCLED data handle.
#
# The returned handle is added to the library's idle pool. The pool
# scans every 5 seconds and frees any handle that has been idle for
# more than 10 minutes. The high-level wrapper DataHandle(...) uses
# this function.
#
# Callers that need to be sure that the handle is not reclaimed
# automatically must use LF_CreateData_Permanent instead.
# ----------------------------------------------------------------------
LF_CreateData = _set_func(
    "LF_CreateData",
    [ctypes.c_char_p],
    DataHnd,
)

# ----------------------------------------------------------------------
# LF_CreateData_Permanent: creates a PERMANENT data handle.
#
# The returned handle is NOT added to the library's idle pool. The
# automatic idle-timeout reclaimer will NEVER free it, no matter how
# long it has been idle. LF_FreeData releases it IMMEDIATELY
# (synchronously), rather than marking it as deleted for a later pool
# scan.
#
# Use this for handles that must survive for the entire lifetime of
# the process, or for an unbounded period (cached request templates,
# long-lived scratch buffers, global registries, etc.).
#
# The high-level wrapper exposes this as
# ``DataHandle.create_permanent(api_name)``.
# ----------------------------------------------------------------------
LF_CreateData_Permanent = _set_func(
    "LF_CreateData_Permanent",
    [ctypes.c_char_p],
    DataHnd,
)

# ----------------------------------------------------------------------
# LF_FreeData: release a data handle.
#
# Behaviour depends on which creation function was used:
#   * Auto-recycled handle: only marks the handle as deleted. The
#     actual release happens on the next pool scan (at most 5 seconds
#     later).
#   * Permanent handle: releases the record immediately.
#
# LF_FreeData is a no-op while the simulated main thread is not
# active (i.e. before LF_PrepareDone or after LF_ExitMainThread).
# ----------------------------------------------------------------------
LF_FreeData = _set_func(
    "LF_FreeData",
    [DataHnd],
    None,
)

LF_GetBuffer = _set_func(
    "LF_GetBuffer",
    [DataHnd],
    ctypes.c_void_p,
)

LF_WriteBuffer = _set_func(
    "LF_WriteBuffer",
    [DataHnd, ctypes.c_void_p, ctypes.c_int64],
    ctypes.c_int64,
)

LF_ReadBuffer = _set_func(
    "LF_ReadBuffer",
    [DataHnd, ctypes.c_void_p, ctypes.c_int64],
    ctypes.c_int64,
)

LF_GetPos = _set_func(
    "LF_GetPos",
    [DataHnd],
    ctypes.c_int64,
)

LF_SetPos = _set_func(
    "LF_SetPos",
    [DataHnd, ctypes.c_int64],
    None,
)

LF_GetSize = _set_func(
    "LF_GetSize",
    [DataHnd],
    ctypes.c_int64,
)

LF_SetSize = _set_func(
    "LF_SetSize",
    [DataHnd, ctypes.c_int64],
    None,
)

# ----------------------------------------------------------------------
# LF_Get_P2P_UID / LF_Get_P2P_Name: read the auto-injected sender
# identity (SIDE DATA) from an INPUT data handle.
#
# SIDE DATA SEMANTICS
# -------------------
# These functions do NOT read a property of the handle itself.
# Instead, they read the two identity fields that the SENDER'S
# transport layer writes into every request payload before
# transmission (Pascal: TC40_LF_Client.Send_* ->
# TMemory_Param_Tool.Rebuild_UID_and_P2PName):
#
#     * FromUID      - the sender's 32-byte session UID
#     * FromP2PName  - the sender's user-supplied P2P group name
#
# The receiver side therefore sees these two fields in the
# Data_Param of the INPUT handle it receives from the framework.
#
# Because of this design:
#
#   * These functions work ONLY on INPUT handles.
#   * They do NOT work on OUTPUT handles.
#   * They do NOT work on a handle the caller created itself with
#     LF_CreateData / LF_CreateData_Permanent, because such a handle
#     has no "sender" and therefore no FromUID / FromP2PName.
#
# On the C side, calling either function on a non-input handle logs
# a warning and returns a null UID / empty string. It does NOT raise.
#
# {!!!!!  LF_Get_P2P_UID RETURNS A POINTER, NOT A VALUE  !!!!!}
# The Pascal signature is:
#
#     function LF_Get_P2P_UID(Hnd: TDataHnd___): PP2P_UID___;
#
# i.e. ``^TUID___`` (a pointer to a 32-byte UID), NOT ``TUID___``
# (the value itself). The pointer is allocated by the C side via New
# and is scheduled for automatic release about 5 seconds after the
# call (DelayFreeMem). Callers MUST:
#
#     1. Copy the 32 bytes immediately if they want to retain them.
#     2. NOT call any deallocation function on the pointer.
#     3. NOT retain the pointer beyond the ~5-second window.
#
# The high-level wrapper lingofuse.core.DataHandle.get_p2p_uid does
# exactly this: it copies the 32 bytes with ctypes.string_at(ptr, 32)
# and returns a fresh Python bytes object. Callers should prefer the
# wrapper.
#
# LF_Get_P2P_Name returns a c_char_p (a pointer to a NUL-terminated
# UTF-8 string), also released by the C side after ~5 seconds. ctypes
# converts a c_char_p RETURN VALUE into a fresh Python bytes object
# on the call boundary, so the result is already detached. Direct
# callers of the low-level binding still get a safe value, but they
# must copy the UID pointer themselves.
#
# Both functions are populated on ALL command paths: Call, Notify,
# Sequenced_Call, Sequenced_Notify, and the UID_* / P2PName_*
# variants. Local calls (LF_LocalCall / LF_LocalNotify) also inject
# identity.
# ----------------------------------------------------------------------
LF_Get_P2P_UID = _set_func(
    "LF_Get_P2P_UID",
    [DataHnd],
    # POINTER to a 32-byte UID (Pascal: PP2P_UID___ = ^TUID___).
    # NOT the value itself; NOT a ctypes array; NOT a Structure.
    ctypes.c_void_p,
)

LF_Get_P2P_Name = _set_func(
    "LF_Get_P2P_Name",
    [DataHnd],
    ctypes.c_char_p,
)


# ======================================================================
# Application Handle Operations
# ======================================================================

LF_CreateApp = _set_func(
    "LF_CreateApp",
    [ctypes.c_char_p, ctypes.c_char_p],
    AppHnd,
)

LF_FreeApp = _set_func(
    "LF_FreeApp",
    [AppHnd],
    None,
)

LF_RegisterCall = _set_func(
    "LF_RegisterCall",
    [AppHnd, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, LFCallFunc],
    ctypes.c_int,
)

LF_RegisterNotify = _set_func(
    "LF_RegisterNotify",
    [AppHnd, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, LFNotifyFunc],
    ctypes.c_int,
)

LF_Unregister = _set_func(
    "LF_Unregister",
    [AppHnd, ctypes.c_char_p],
    ctypes.c_int,
)

LF_LocalCall = _set_func(
    "LF_LocalCall",
    [AppHnd, DataHnd],
    DataHnd,
)

LF_LocalNotify = _set_func(
    "LF_LocalNotify",
    [AppHnd, DataHnd],
    None,
)


# ======================================================================
# Application utility functions
# ----------------------------------------------------------------------
# LF_BindApp:
#     Binds an application to all currently unbound clients. Returns the
#     number of clients bound. A return value of 0 means no free clients
#     are available or the simulated main thread is not active.
#
# LF_Generate_AppName:
#     Returns a globally unique application name. The returned pointer
#     is valid for only 5 seconds - the caller MUST copy it immediately.
#     The high-level wrapper ``generate_app_name()`` does this for you.
#
# LF_Get_AppName:
#     Retrieves the name of an existing application handle. Same 5-second
#     lifetime rule applies; use ``get_app_name()`` from the high-level
#     layer instead of calling this directly.
# ======================================================================

LF_BindApp = _set_func(
    "LF_BindApp",
    [AppHnd],
    ctypes.c_int,
)

LF_Generate_AppName = _set_func(
    "LF_Generate_AppName",
    [],
    ctypes.c_char_p,
)

LF_Get_AppName = _set_func(
    "LF_Get_AppName",
    [AppHnd],
    ctypes.c_char_p,
)


# ======================================================================
# Process-wide P2P API registration
# ----------------------------------------------------------------------
# The process-wide P2P API is a second registration namespace,
# independent of the app-bound namespace (LF_RegisterCall /
# LF_RegisterNotify). APIs registered here live on the process-wide
# LF_P2P_APP and are reachable via P2PName and UID addressing without
# requiring the caller to know the target App name.
#
# Typical use: register a small set of globally-discoverable utility
# APIs (health probes, capability discovery, identity echo, etc.) that
# any client in the mesh can call by group name or by UID.
#
# Contract:
#   * LF_Register_P2P_Call and LF_Register_P2P_Notify return 1 on
#     success, 0 on failure (e.g. duplicate name in the P2P namespace).
#   * LF_Unregister_P2P removes the named API from the process-wide
#     namespace. It does NOT affect app-bound APIs of the same name.
#   * These APIs are reachable ONLY via P2PName_* or UID_* calls. A
#     plain app-name call (LF_Call with an app name) will NOT hit
#     them, even if the app name happens to match a registered P2P
#     API name.
# ======================================================================

LF_Register_P2P_Call = _set_func(
    "LF_Register_P2P_Call",
    [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, LFCallFunc],
    ctypes.c_int,
)

LF_Register_P2P_Notify = _set_func(
    "LF_Register_P2P_Notify",
    [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, LFNotifyFunc],
    ctypes.c_int,
)

LF_Unregister_P2P = _set_func(
    "LF_Unregister_P2P",
    [ctypes.c_char_p],
    ctypes.c_int,
)


# ======================================================================
# Network Preparation
# ======================================================================

# ----------------------------------------------------------------------
# LF_PrepareClient: Prepares a client connection to the given physical
# address. IMPORTANT: the same address cannot be used for more than one
# client unless the runtime option "Overlap_Connection" is set to
# "True" before this call. Use distinct addresses (different IPC names
# or different TCP ports) if you need multiple clients without overlap.
# Attempting to call this twice with the same address while overlap is
# disabled returns -1 and logs a "repeat connection" error.
# ----------------------------------------------------------------------

LF_PrepareService = _set_func(
    "LF_PrepareService",
    [ctypes.c_char_p, ctypes.c_char_p],
    ctypes.c_int,
)

LF_PrepareClient = _set_func(
    "LF_PrepareClient",
    [ctypes.c_char_p, AppHnd],
    ctypes.c_int,
)

LF_ResetPrepare = _set_func(
    "LF_ResetPrepare",
    [],
    None,
)

LF_PrepareDone = _set_func(
    "LF_PrepareDone",
    [],
    ctypes.c_int,
)

LF_ExitMainThread = _set_func(
    "LF_ExitMainThread",
    [],
    None,
)


# ======================================================================
# Remote invocation by App name
# ----------------------------------------------------------------------
# The most common addressing mode: the caller names a logical App and
# the framework routes the call. Routing is LOCAL-FIRST: if the caller
# process itself hosts an App with the matching name and API, the call
# is serviced locally without touching the network.
# ======================================================================

LF_Call = _set_func(
    "LF_Call",
    [ctypes.c_char_p, DataHnd, ctypes.c_uint64],
    DataHnd,
)

# ----------------------------------------------------------------------
# LF_Async_Call: non-blocking variant of LF_Call.
#
# Returns 1 immediately after the request is queued. The OnResult
# callback fires later on a TCompute worker thread once the response
# arrives (or the call times out). Return value 0 means the request
# could not be queued.
#
# The OnResult callback is documented on the LFAsyncCallOnResult
# prototype above. Its Result_ argument is owned by the framework and
# is released IMMEDIATELY after the callback returns; the callback
# MUST NOT call LF_FreeData on it.
# ----------------------------------------------------------------------
LF_Async_Call = _set_func(
    "LF_Async_Call",
    [ctypes.c_char_p, DataHnd, ctypes.c_void_p, LFAsyncCallOnResult],
    ctypes.c_int,
)

# ----------------------------------------------------------------------
# LF_Async_Sequenced_Call: like LF_Async_Call, but requests are
# delivered to the target in FIFO order per (app, api) pair. The
# framework maintains a dedicated dispatch thread per (app, api) key
# on the target side, so concurrency is preserved across keys while
# ordering is preserved within each key.
# ----------------------------------------------------------------------
LF_Async_Sequenced_Call = _set_func(
    "LF_Async_Sequenced_Call",
    [ctypes.c_char_p, DataHnd, ctypes.c_void_p, LFAsyncCallOnResult],
    ctypes.c_int,
)

LF_Notify = _set_func(
    "LF_Notify",
    [ctypes.c_char_p, DataHnd],
    None,
)

LF_Sequenced_Notify = _set_func(
    "LF_Sequenced_Notify",
    [ctypes.c_char_p, DataHnd],
    None,
)


# ======================================================================
# Remote invocation by UID
# ----------------------------------------------------------------------
# UID addressing routes to the exact client whose TunnelLink produced
# the given 32-byte UID. Unlike app-name routing, a UID is unique to a
# single connected session and is regenerated on every reconnect: a
# caller must re-probe the target's UID after a link loss.
#
# UID routing is also LOCAL-FIRST, matching app-name routing: if the
# caller process itself hosts a client with the matching UID, the call
# is serviced locally.
#
# The UID can address ANY API registered on the target (whether
# app-bound or process-wide P2P), without requiring the caller to know
# the target App name.
#
# {!!!!!  TP2P_UID AS ARGUMENT  !!!!!}
# The first argtypes entry is ``TP2P_UID``, the argument-role array
# type. ctypes passes arrays by value correctly for cdecl functions.
# Do NOT confuse this with the RETURN-role representation of the same
# Pascal type (which is a pointer, used only by LF_Get_P2P_UID).
# ======================================================================

LF_UID_Call = _set_func(
    "LF_UID_Call",
    [TP2P_UID, DataHnd, ctypes.c_uint64],
    DataHnd,
)

LF_UID_Async_Call = _set_func(
    "LF_UID_Async_Call",
    [TP2P_UID, DataHnd, ctypes.c_void_p, LFAsyncCallOnResult],
    ctypes.c_int,
)

LF_UID_Async_Sequenced_Call = _set_func(
    "LF_UID_Async_Sequenced_Call",
    [TP2P_UID, DataHnd, ctypes.c_void_p, LFAsyncCallOnResult],
    ctypes.c_int,
)

LF_UID_Notify = _set_func(
    "LF_UID_Notify",
    [TP2P_UID, DataHnd],
    None,
)

LF_UID_Sequenced_Notify = _set_func(
    "LF_UID_Sequenced_Notify",
    [TP2P_UID, DataHnd],
    None,
)


# ======================================================================
# Remote invocation by P2P name
# ----------------------------------------------------------------------
# P2PName addressing routes to any client in a user-defined group. The
# server-side dispatcher picks a target using one of two strategies:
#
#   * Load balancing (Cycle_Anchor): the target with the smallest
#     anchor value is chosen, and its anchor is then advanced to a new
#     global counter value so that the next call lands elsewhere.
#
#   * Sticky affinity (FixedSequenced, governed by the runtime option
#     "Fixed_Sequenced_Time", default 20 seconds): the same target is
#     kept for a bounded period before the dispatcher switches.
#
# IMPORTANT: P2PName routing is NOT local-first. Even when the caller
# process itself hosts a client in the target group, the call is
# forwarded to the server for dispatch. This is a deliberate design
# choice: the server owns the load-balancing state, and short-cutting
# locally would defeat it.
# ======================================================================

LF_P2PNAME_Call = _set_func(
    "LF_P2PNAME_Call",
    [ctypes.c_char_p, DataHnd, ctypes.c_uint64],
    DataHnd,
)

LF_P2PNAME_Async_Call = _set_func(
    "LF_P2PNAME_Async_Call",
    [ctypes.c_char_p, DataHnd, ctypes.c_void_p, LFAsyncCallOnResult],
    ctypes.c_int,
)

LF_P2PNAME_Async_Sequenced_Call = _set_func(
    "LF_P2PNAME_Async_Sequenced_Call",
    [ctypes.c_char_p, DataHnd, ctypes.c_void_p, LFAsyncCallOnResult],
    ctypes.c_int,
)

LF_P2PNAME_Notify = _set_func(
    "LF_P2PNAME_Notify",
    [ctypes.c_char_p, DataHnd],
    None,
)

LF_P2PNAME_Sequenced_Notify = _set_func(
    "LF_P2PNAME_Sequenced_Notify",
    [ctypes.c_char_p, DataHnd],
    None,
)


# ======================================================================
# Status and Check functions
# ======================================================================

LF_GetStatusCount = _set_func(
    "LF_GetStatusCount",
    [],
    ctypes.c_int,
)

LF_GetStatus = _set_func(
    "LF_GetStatus",
    [],
    ctypes.c_char_p,
)

LF_PostStatus = _set_func(
    "LF_PostStatus",
    [ctypes.c_char_p],
    None,
)

LF_CheckMainThread = _set_func(
    "LF_CheckMainThread",
    [],
    ctypes.c_int,
)

LF_CheckApp = _set_func(
    "LF_CheckApp",
    [ctypes.c_char_p],
    ctypes.c_int,
)

LF_CheckApi = _set_func(
    "LF_CheckApi",
    [ctypes.c_char_p, ctypes.c_char_p],
    ctypes.c_int,
)

# ----------------------------------------------------------------------
# LF_Check_UID / LF_Check_UID_Api: query whether a client with the
# given UID is currently registered on the mesh, optionally whether
# that client exposes a named API.
#
# Both functions consult a locally cached view of the mesh (updated
# by periodic broadcasts). Registration and unregistration propagate
# to this cache with a typical delay of about 3 seconds. A fresh
# registration may therefore return 0 (false negative) for a short
# window, and a fresh unregistration may return 1 (false positive).
# Callers that need a definitive answer should retry, or fall back to
# the actual call and handle the empty-result case.
#
# These functions take a UID as an ARGUMENT. The argument-role type
# is ``TP2P_UID`` (a c_ubyte * 32 array). This is a DIFFERENT role
# from the LF_Get_P2P_UID return value (which is a pointer).
# ----------------------------------------------------------------------
LF_Check_UID = _set_func(
    "LF_Check_UID",
    [TP2P_UID],
    ctypes.c_int,
)

LF_Check_UID_Api = _set_func(
    "LF_Check_UID_Api",
    [TP2P_UID, ctypes.c_char_p],
    ctypes.c_int,
)

# ----------------------------------------------------------------------
# LF_Check_P2PNAME / LF_Check_P2PNAME_Api: same as the UID variants,
# but keyed on the user-supplied P2P group name. Both functions are
# backed by the same locally cached broadcast view and are subject to
# the same ~3-second propagation delay.
# ----------------------------------------------------------------------
LF_Check_P2PNAME = _set_func(
    "LF_Check_P2PNAME",
    [ctypes.c_char_p],
    ctypes.c_int,
)

LF_Check_P2PNAME_Api = _set_func(
    "LF_Check_P2PNAME_Api",
    [ctypes.c_char_p, ctypes.c_char_p],
    ctypes.c_int,
)


# ======================================================================
# Runtime options
# ----------------------------------------------------------------------
# LF_SetOption / LF_GetOption read and write process-global runtime
# configuration. All option keys are ASCII strings. The full set of
# supported keys is documented in lingofuse/__init__.py; brief notes
# on the ones that change the library's ABI-level behaviour:
#
#     "Overlap_Connection"    - allow multiple client tunnels to the
#                               same physical address
#     "Wait_Connection_ReadyOk" - whether LF_PrepareDone blocks until
#                               every prepared client is online
#     "Wait_Connection_Timeout" - the preceding wait's timeout, ms
#     "password" / "passwd"   - P2PVM authentication token
#     "LF_P2P_name"           - the sender's P2P group name; injected
#                               into every outbound request
#     "DataHandle_Idle_Timeout" - idle reclamation threshold, ms
#     "DataHandle_Pool_Scan_Interval" - reclamation scan period, ms
#
# Unknown option keys are silently ignored. Changes are NOT persisted
# across LF_Shutdown: an application must reapply its options on
# restart.
# ======================================================================

LF_SetOption = _set_func(
    "LF_SetOption",
    [ctypes.c_char_p, ctypes.c_char_p],
    None,
)

# ----------------------------------------------------------------------
# LF_GetOption: read the current value of a runtime option.
#
# Returns a UTF-8 string. The returned pointer is backed by a transient
# buffer that is released ~5 seconds after the call; ctypes converts
# the c_char_p return value to a Python bytes object on the call
# boundary, so the returned object is already detached from that
# buffer. For unknown option keys, the C side returns an empty string.
# ----------------------------------------------------------------------
LF_GetOption = _set_func(
    "LF_GetOption",
    [ctypes.c_char_p],
    ctypes.c_char_p,
)


# ======================================================================
# Network Event API
# ----------------------------------------------------------------------
# LF_Set_Network_Event installs a pair of process-global callbacks that
# fire when a LingoFuse client transitions between online and offline.
#
# Callback prototype:
#     void (*)(const char* addr)  --  cdecl, single UTF-8 argument.
#
# Contract (see the module docstring for the full version):
#   * Callbacks run on a BACKGROUND C WORKER THREAD - not on the
#     calling thread and not on the simulated main thread.
#   * The addr buffer is valid ONLY during the callback invocation.
#     ctypes automatically decodes c_char_p callback arguments into
#     a fresh Python bytes object, so keeping the bytes is safe.
#   * Exceptions raised inside the callback are swallowed by the
#     library. The high-level wrapper logs them instead.
#   * Passing None for either argument installs a NULL pointer,
#     which disables that particular callback.
#
# {!!!!!  c_void_p ARGTYPES ARE INTENTIONAL  !!!!!}
# We declare the two arguments as c_void_p instead of LFNetworkEventFunc.
# This is because ctypes enforces strict type checking when an argtypes
# entry is a CFUNCTYPE instance: passing None in that case raises a
# TypeError, even though None is the canonical way to pass a NULL
# pointer. Using c_void_p accepts both None (NULL) and a CFUNCTYPE
# instance (implicitly converted to its function pointer address),
# with no additional casts required at the call site.
#
# IMPORTANT: the CFUNCTYPE objects you pass here MUST be kept alive
# as long as the C library holds their function pointers. See
# ``lingofuse.network_events`` for the recommended pattern.
# ======================================================================

LF_Set_Network_Event = _set_func(
    "LF_Set_Network_Event",
    [ctypes.c_void_p, ctypes.c_void_p],
    None,
)


# ======================================================================
# Shutdown
# ----------------------------------------------------------------------
# LF_Shutdown releases every resource the library holds:
#   1. Clears the network event callbacks.
#   2. Stops all sequenced-notification threads.
#   3. Releases every remaining data handle.
#   4. Exits the simulated main thread.
#   5. Clears the global application pool (destroying every TLF_App).
#   6. Unloads the IPC library and closes the core dispatcher thread.
#
# After LF_Shutdown returns, the library can be restarted: call
# LF_ResetPrepare, LF_PrepareService / LF_PrepareClient, then
# LF_PrepareDone again. All runtime options are reset to their
# defaults, so the application must reapply them.
#
# In a dynamic library (DLL) context, LF_Shutdown is NOT automatic;
# the host process MUST call it explicitly before unloading the DLL,
# otherwise resources leak.
# ======================================================================

LF_Shutdown = _set_func(
    "LF_Shutdown",
    [],
    None,
)