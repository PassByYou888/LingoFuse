# -*- coding: utf-8 -*-
"""
Core RAII wrappers: DataHandle and App.

This module provides safe, high-level access to the LingoFuse C ABI.
All string parameters are UTF-8 encoded/decoded automatically.

=========================== DATA HANDLE ============================
DataHandle wraps a binary buffer that can be read/written sequentially.
It is an RAII object: freeing the Python object calls LF_FreeData.

Important notes from the wire protocol contract:
- Always free DataHandle objects explicitly (or use `with` / context manager)
  to release resources promptly. The library has an automatic idle-timeout
  reclaimer (5 minutes), but it is not immediate.
- Do not free a handle while it is being used in a callback or while
  a remote call is pending.
- Concurrent writes to the same handle must be serialised externally;
  reads are safe.

String handling rules (critical for cross-language compatibility):
- write_string() always appends a null terminator (\\0) to match
  the standard wire protocol for string framing. This is required
  for the other side to correctly read the string with the
  corresponding read primitive.
- read_string() is fault-tolerant: it scans for a \\0 and returns
  the content before it. If no \\0 is found, it returns the entire
  remaining buffer as a string (consuming all data). This handles
  both null-terminated and raw data (e.g., plain JSON without \\0).

Atomic read/write methods (write_int32, read_int32, etc.) use little-endian
byte order, which matches the cross-language convention.

=========================== JSON I/O DELEGATION ============================
As of this revision, the JSON and string payload I/O of DataHandle is
delegated to `lingofuse.lf_io`, which is the single source of truth
for:
    * the serialization policy (ensure_ascii=False, default=str),
    * the NUL framing on the wire,
    * the NUL-tolerant read behaviour.

The four public methods that delegate are:
    write_string  -> lf_io.write_string
    read_string   -> lf_io.read_string
    write_json    -> lf_io.write_json
    read_json     -> lf_io.read_json (with a position reset first)

The public signatures of these four methods are PRESERVED exactly:
    write_string : returns bool
    read_string  : raises LingoFuseError on invalid UTF-8
    write_json   : returns the number of bytes written
    read_json    : resets the read position to 0, then silently
                   returns None on any parse failure

These signatures are kept for backward compatibility. The delegation
is an internal implementation change: callers see the same observable
behaviour as before, but the serialization and framing policies now
live in exactly one place (lingofuse.lf_io).

The `write` / `read` methods are NOT affected by this change: they
use the serializers module (which produces a bytes payload WITHOUT a
trailing NUL) and belong to a different protocol layer.

=========================== APPLICATION ============================
App represents a logical service that can host multiple APIs.
APIs can be registered as Call (request-response) or Notify (one-way).

Registration rules:
- API names are case-insensitive when matching, but stored as provided.
  Use consistent naming to avoid confusion.
- Registering a duplicate API name fails (returns False in Python).
- The Trigger pointer is unused in these Python bindings; you can ignore it.

Local execution:
- local_call() executes a Call API synchronously within the same process.
- local_notify() sends a notification locally.

NEW functions (since v1.1):
- bind() - binds this application to all currently unbound LingoFuse
  clients. Returns the number of clients bound. A return value of 0
  means no free clients or the main thread is not active. Note that
  clients must have been prepared with distinct physical addresses
  (LF_PrepareClient cannot reuse the same address). Therefore, to bind
  to multiple clients, you must prepare them with different addresses
  (e.g., different IPC names or different ports).

- App also provides a convenient `sequenced_notify()` method.

Thread-safety:
- All methods are thread-safe, but callback registration should be done
  before starting the network.
- Callbacks registered via register_call/register_notify run in
  background threads. They must not block or call any blocking
  LingoFuse function (e.g., LF_Call) to avoid deadlocks.

{!!!!!  CALLBACK EXCEPTION ISOLATION  !!!!!}
Callbacks are wrapped so that any exception raised inside them is caught
and logged, and never allowed to propagate back into the C stack. This
matches the behaviour of the reference C core (Engine.Execute_Call /
Execute_Notify) which wraps user callbacks in try/except. Without this
isolation, ctypes would print a traceback to stderr for every failing
callback, and the caller would receive an empty response without any
indication of the failure.

{!!!!!  ROBUST CLEANUP  !!!!!}
free() and __del__ are written defensively: they use getattr with safe
defaults so that they behave correctly even when the instance was
created via __new__(cls) without ever running __init__. This is
important for tests that exercise construction-failure paths, and for
subclasses that may run custom __init__ logic.

{!!!!!  APP LIFETIME  !!!!!}
- `App.free()` detaches the application but does NOT destroy it
  immediately. The underlying object remains in the global pool until
  `LF_Shutdown()` is called.
- For proper resource cleanup, always call `LF_Shutdown()` or use the
  `full_cleanup()` methods provided by `Server` and `C4` when you are
  done.
"""

import ctypes
import logging
import struct
import json
from typing import Any, Optional, Callable

from ._lf_native import (
    DataHnd, AppHnd,
    LF_CreateData, LF_FreeData,
    LF_WriteBuffer, LF_ReadBuffer,
    LF_GetSize, LF_SetPos,
    LF_GetBuffer, LF_GetPos,
    LF_SetSize,
    LF_CreateApp, LF_FreeApp,
    LF_RegisterCall, LF_RegisterNotify,
    LF_Unregister,
    LF_LocalCall, LF_LocalNotify,
    LF_Sequenced_Notify,
    LF_BindApp,
    LF_Generate_AppName,
    LF_Get_AppName,
    LFCallFunc, LFNotifyFunc,
)
from .errors import LingoFuseError, RegistrationError
from .serializers import default_serializer, default_deserializer

# ----------------------------------------------------------------------
# Unified LingoFuse payload I/O
# ----------------------------------------------------------------------
#
# The four DataHandle payload methods (write_string / read_string /
# write_json / read_json) delegate to this module. It is the single
# source of truth for the JSON serialization policy, the NUL framing,
# and the NUL-tolerant read behaviour.
#
# The aliases use a leading underscore so that they cannot be confused
# with the DataHandle methods of the same name inside this file. The
# public method implementations below are thin wrappers that preserve
# the historical signatures and error behaviour of DataHandle.
from .lf_io import (
    cstr,
    read_json as _lf_read_json,
    read_string as _lf_read_string,
    write_json as _lf_write_json,
    write_string as _lf_write_string,
)


# Module-level logger for callback failures. All messages are in English
# so that they can be collected by a standard logging pipeline.
_log = logging.getLogger("lingofuse.core")


# ======================================================================
# Module-level convenience functions
# ======================================================================

def generate_app_name() -> str:
    """
    Generate a globally unique application name string.

    The name is built from active C4 addresses, process name (with PID),
    and a high-resolution timestamp. The returned string is guaranteed to
    be unique for each call.

    This function immediately copies the C string into a Python str object,
    so the caller does not need to worry about the 5-second auto-free
    window of the underlying library.

    Returns:
        A UTF-8 string containing the generated name.
    """
    ptr = LF_Generate_AppName()
    if not ptr:
        return ""
    return ptr.decode("utf-8")


def get_app_name(app_handle: AppHnd) -> str:
    """
    Retrieve the application name associated with a raw application handle.

    This is useful when you have a handle obtained from other sources, but
    normally you would use the `App.name` property.

    The function immediately copies the name into a Python str, so the
    5-second lifetime of the underlying C pointer does not affect the caller.

    Args:
        app_handle: The raw application handle (AppHnd).

    Returns:
        The application name as a string, or an empty string on error.
    """
    ptr = LF_Get_AppName(app_handle)
    if not ptr:
        return ""
    return ptr.decode("utf-8")


# ======================================================================
# DataHandle
# ======================================================================

class DataHandle:
    """
    RAII wrapper for a LingoFuse data handle (TDataHnd).

    Context manager support: use `with DataHandle(...) as dh:` to auto-free.
    Ownership: by default, the object owns the handle and frees it on
    destruction. You can also wrap a raw handle with
    `_from_raw(hnd, owned=True)`.

    All read/write methods update an internal timestamp used by the
    library's idle-timeout reclaimer. However, you should still free
    handles explicitly when they are no longer needed.

    {!!!!!  INITIALIZATION ORDER  !!!!!}
    All instance attributes are initialized to safe defaults BEFORE any
    native call that might fail. This ensures __del__ / free() can run
    safely even if __init__ raises an exception partway through.

    Additionally, free() and __del__ use getattr-based defaults so that
    they also work when the instance was created via __new__(cls)
    without ever running __init__ (a pattern used by tests that
    exercise construction-failure paths, and by subclasses).
    """

    def __init__(self, api_name: str, data: Any = None,
                 serializer: Optional[Callable] = None,
                 deserializer: Optional[Callable] = None):
        """
        Create a new data handle for the given API name.

        The API name is stored internally and will be used as the
        MethodName in the wire protocol. The buffer is initially empty.

        If `data` is provided, it is serialized using the default
        serializer (JSON) and written to the buffer immediately.

        Args:
            api_name: Name of the target API (UTF-8).
            data: Optional object to serialize and write.
            serializer: Callable that converts object to bytes
                (default JSON).
            deserializer: Callable that converts bytes to object
                (default JSON).
        """
        # Initialize all instance attributes to safe defaults FIRST.
        # If LF_CreateData fails and we raise before assigning these,
        # __del__ will still be able to run without AttributeError.
        self._hnd = None
        self._owned = False
        self._serializer = serializer or default_serializer
        self._deserializer = deserializer or default_deserializer

        # Now create the native handle. cstr() supplies NUL-terminated
        # UTF-8 bytes for the c_char_p parameter.
        self._hnd = LF_CreateData(cstr(api_name))
        if not self._hnd:
            raise LingoFuseError(
                f"Failed to create DataHandle for API '{api_name}'"
            )
        self._owned = True

        if data is not None:
            self.write(data)

    @classmethod
    def _from_raw(cls, hnd: DataHnd, owned: bool = True,
                  serializer: Optional[Callable] = None,
                  deserializer: Optional[Callable] = None):
        """
        Wrap an existing raw data handle.

        Args:
            hnd: The raw handle (DataHnd) to wrap.
            owned: If True, LF_FreeData will be called when this object
                is destroyed.
            serializer: Optional serializer to use for write().
            deserializer: Optional deserializer to use for read().

        Returns:
            A new DataHandle instance.
        """
        obj = cls.__new__(cls)
        obj._hnd = hnd
        obj._owned = owned
        obj._serializer = serializer or default_serializer
        obj._deserializer = deserializer or default_deserializer
        return obj

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.free()

    def __del__(self):
        # __del__ must be bullet-proof: swallow any exception so that
        # garbage collection never writes noise to stderr.
        try:
            self.free()
        except Exception:
            pass

    def free(self):
        """
        Free the underlying handle if owned.

        Safe to call multiple times. Safe to call on instances whose
        __init__ never ran or failed partway through: all attribute
        accesses use getattr-based defaults.
        """
        owned = getattr(self, "_owned", False)
        hnd = getattr(self, "_hnd", None)
        if owned and hnd:
            LF_FreeData(hnd)
            self._hnd = None

    @property
    def raw(self) -> DataHnd:
        """Return the raw ctypes handle for low-level operations."""
        return getattr(self, "_hnd", None)

    def write(self, obj: Any) -> int:
        """
        Write a Python object using the configured serializer.

        This method uses the `serializers` module and produces a bytes
        payload WITHOUT a trailing NUL. That is a different protocol
        layer from `write_json`, which produces UTF-8 JSON text with a
        NUL terminator. Both are kept for backward compatibility; do
        not mix them on the same handle unless you know what you are
        doing.
        """
        data = self._serializer(obj)
        return LF_WriteBuffer(self._hnd, data, len(data))

    def read(self, deserializer: Optional[Callable] = None) -> Any:
        """
        Read and deserialize data using the configured or provided
        deserializer.

        Uses the `serializers` module (no NUL framing). See the note
        on `write` above.
        """
        size = LF_GetSize(self._hnd)
        if size == 0:
            return None
        buf = (ctypes.c_byte * size)()
        LF_SetPos(self._hnd, 0)
        LF_ReadBuffer(self._hnd, buf, size)
        raw = bytes(buf)
        des = deserializer or self._deserializer
        return des(raw)

    # ---- Position and size operations ----

    def get_pos(self) -> int:
        """Return the current read/write position."""
        return LF_GetPos(self._hnd)

    def set_pos(self, pos: int) -> None:
        """Set the current read/write position."""
        LF_SetPos(self._hnd, pos)

    def get_size(self) -> int:
        """Return the total buffer size in bytes."""
        return LF_GetSize(self._hnd)

    def set_size(self, size: int) -> None:
        """Resize the buffer. Newly added space is uninitialized."""
        LF_SetSize(self._hnd, size)

    @property
    def size(self) -> int:
        """Return the total buffer size in bytes."""
        return self.get_size()

    # ---------- Atomic types (little-endian) ----------
    #
    # Atomic type I/O is NOT part of the unified JSON/string payload
    # path. It writes raw little-endian integers and floats directly
    # into the buffer and does not use NUL framing or JSON encoding.
    # These methods therefore keep their local `_write_pack` /
    # `_read_unpack` helpers.

    def write_int8(self, value: int) -> bool:
        return self._write_pack('<b', value) == 1

    def write_uint8(self, value: int) -> bool:
        return self._write_pack('<B', value) == 1

    def write_int16(self, value: int) -> bool:
        return self._write_pack('<h', value) == 2

    def write_uint16(self, value: int) -> bool:
        return self._write_pack('<H', value) == 2

    def write_int32(self, value: int) -> bool:
        return self._write_pack('<i', value) == 4

    def write_uint32(self, value: int) -> bool:
        return self._write_pack('<I', value) == 4

    def write_int64(self, value: int) -> bool:
        return self._write_pack('<q', value) == 8

    def write_uint64(self, value: int) -> bool:
        return self._write_pack('<Q', value) == 8

    def write_single(self, value: float) -> bool:
        return self._write_pack('<f', value) == 4

    def write_double(self, value: float) -> bool:
        return self._write_pack('<d', value) == 8

    # ---- Read helpers (atomic types) ----

    def read_int8(self) -> int:
        return self._read_unpack('<b')

    def read_uint8(self) -> int:
        return self._read_unpack('<B')

    def read_int16(self) -> int:
        return self._read_unpack('<h')

    def read_uint16(self) -> int:
        return self._read_unpack('<H')

    def read_int32(self) -> int:
        return self._read_unpack('<i')

    def read_uint32(self) -> int:
        return self._read_unpack('<I')

    def read_int64(self) -> int:
        return self._read_unpack('<q')

    def read_uint64(self) -> int:
        return self._read_unpack('<Q')

    def read_single(self) -> float:
        return self._read_unpack('<f')

    def read_double(self) -> float:
        return self._read_unpack('<d')

    # ---- String helpers (delegated to lingofuse.lf_io) ----

    def write_string(self, value: str) -> bool:
        """
        Write a UTF-8 string followed by a null terminator (\\0).

        Delegates to `lingofuse.lf_io.write_string`, which is the
        single source of truth for the NUL framing and the UTF-8
        encoding used on the wire.

        The return type is preserved from the previous implementation:
        True on success, False on a write failure. lf_io raises on a
        short write, so the wrapper converts that into a `False` return
        to keep the public signature unchanged.
        """
        try:
            _lf_write_string(self._hnd, value)
            return True
        except Exception:
            return False

    # Alias for backward compatibility.
    write_string_null_terminated = write_string

    def read_string(self) -> str:
        """
        Read a null-terminated UTF-8 string from the current position.

        Delegates to `lingofuse.lf_io.read_string`, which is the single
        source of truth for the NUL-tolerant read behaviour:
          * If a NUL is found, return everything before it and advance
            the handle position past the NUL.
          * If no NUL is found, return the entire remaining buffer and
            advance the position to the end.

        The exception type is preserved from the previous
        implementation: an invalid UTF-8 payload raises
        `LingoFuseError` (not the `RuntimeError` that lf_io raises
        internally). The wrapper converts the exception type so that
        existing callers keep working unchanged.
        """
        try:
            return _lf_read_string(self._hnd)
        except RuntimeError as e:
            raise LingoFuseError(str(e)) from e

    # Alias for backward compatibility.
    read_string_null_terminated = read_string

    def read_bytes(self) -> bytes:
        """
        Read all remaining bytes from the current position to the end
        of the buffer. Does not assume UTF-8. Moves position to end.
        """
        pos = self.get_pos()
        size = self.get_size()
        if pos >= size:
            return b""
        ptr = LF_GetBuffer(self._hnd)
        if not ptr:
            raise LingoFuseError("DataHandle buffer is invalid")
        raw = ctypes.string_at(ptr + pos, size - pos)
        self.set_pos(size)
        return raw

    # ---- JSON helpers (delegated to lingofuse.lf_io) ----

    def write_json(self, obj: Any) -> int:
        """
        Serialize a Python object to JSON and write as NUL-terminated
        UTF-8.

        Delegates to `lingofuse.lf_io.write_json`, which guarantees
        the toolchain-wide serialization policy:

            json.dumps(obj, ensure_ascii=False, default=str)

        and appends the NUL terminator required by the wire protocol
        for string framing.

        The return type is preserved from the previous implementation:
        the number of bytes written (including the NUL terminator).
        lf_io.write_json returns None, so the wrapper measures the
        buffer size before and after the call to compute the delta.
        """
        before = LF_GetSize(self._hnd)
        _lf_write_json(self._hnd, obj)
        return LF_GetSize(self._hnd) - before

    def read_json(self) -> Any:
        """
        Read NUL-terminated UTF-8 JSON data and deserialize it.

        Delegates to `lingofuse.lf_io.read_json`, but preserves two
        historical behaviours of this specific method:

          1. The read always starts from position 0, regardless of the
             handle's current position. This is what the previous
             inline implementation did, and some callers rely on it.
          2. Any failure (invalid UTF-8, invalid JSON, empty payload)
             results in a silent `None` return rather than a raised
             exception. This is also what the previous inline
             implementation did, and it is kept for backward
             compatibility even though lf_io itself is strict.

        Callers that want the strict lf_io behaviour should call
        `lingofuse.lf_io.read_json` directly on the raw handle.
        """
        size = LF_GetSize(self._hnd)
        if size == 0:
            return None
        LF_SetPos(self._hnd, 0)
        try:
            return _lf_read_json(self._hnd)
        except Exception:
            return None

    # ---------- Low-level helpers ----------
    #
    # These helpers are used exclusively by the atomic-type methods
    # above. They are NOT part of the unified JSON/string payload
    # path and do not touch NUL framing or JSON encoding.

    def _write_pack(self, fmt: str, value) -> int:
        data = struct.pack(fmt, value)
        return self._write_bytes(data)

    def _write_bytes(self, data: bytes) -> int:
        if not data:
            return 0
        return LF_WriteBuffer(self._hnd, data, len(data))

    def _read_unpack(self, fmt: str):
        size = struct.calcsize(fmt)
        data = self._read_bytes(size)
        if len(data) != size:
            raise LingoFuseError(
                f"Not enough data to read {fmt} "
                f"(expected {size} bytes, got {len(data)})"
            )
        return struct.unpack(fmt, data)[0]

    def _read_bytes(self, n: int) -> bytes:
        if n <= 0:
            return b''
        buf = (ctypes.c_byte * n)()
        read = LF_ReadBuffer(self._hnd, buf, n)
        if read != n:
            raise LingoFuseError(
                f"Read only {read} bytes, expected {n}"
            )
        return bytes(buf)


# ======================================================================
# App
# ======================================================================

class App:
    """
    RAII wrapper for a LingoFuse application handle (TAppHnd).

    An application is a container for related APIs. Each App has a unique
    name used for discovery and routing across the network.

    Important notes (from the wire protocol contract):
    - API names are case-insensitive when matching, but stored as given.
    - If you register the same API name twice, the second registration
      fails.
    - The Trigger pointer passed to register_call/register_notify is
      unused in these Python bindings; you can safely pass None (the
      callbacks are object methods that don't need extra context).
    - Use the Sync variants if your callback accesses UI components or
      non-thread-safe objects; otherwise, use non-sync for better
      performance.
    - Do not call any blocking LingoFuse function (e.g., LF_Call) from
      inside a callback to avoid deadlocks.

    {!!!!!  CALLBACK EXCEPTION ISOLATION  !!!!!}
    User callbacks registered via register_call / register_notify are
    wrapped so that any exception they raise is caught and logged to
    the "lingofuse.core" logger. The exception is never allowed to
    propagate back into the C stack. This matches the behaviour of the
    reference C core (Engine.Execute_Call / Engine.Execute_Notify).

    {!!!!!  LIFETIME  !!!!!}
    - `free()` detaches the app but does NOT destroy it immediately.
      The object remains in the global pool until `LF_Shutdown()` is
      called.
    - To fully release resources, use `Server.full_cleanup()`,
      `C4.full_cleanup()`, or call `LF.Shutdown()` directly.

    {!!!!!  ROBUST CLEANUP  !!!!!}
    free() and __del__ use getattr-based defaults so that they also
    work when the instance was created via __new__(cls) without ever
    running __init__.

    New in v1.1:
    - bind() method to dynamically attach this App to free clients.
    - sequenced_notify() convenience method.

    {!!!!!  STRING PARAMETERS  !!!!!}
    Every string argument passed to an LF_* function (app name,
    description, API name) is routed through `lingofuse.lf_io.cstr`,
    which supplies NUL-terminated UTF-8 bytes for the c_char_p
    parameter. This removes the previous reliance on the hidden NUL
    byte inside CPython bytes objects and makes the wire contract
    explicit.
    """

    def __init__(self, name: str, description: str = ""):
        """
        Create a new application with the given name and description.

        The name must be unique within the network and is used for
        routing.
        """
        # Initialize all instance attributes to safe defaults FIRST.
        self._name = name
        self._hnd = None
        self._callbacks = []

        # Now create the native handle. cstr() supplies NUL-terminated
        # UTF-8 bytes for both c_char_p parameters.
        self._hnd = LF_CreateApp(
            cstr(name),
            cstr(description),
        )
        if not self._hnd:
            raise LingoFuseError(f"Failed to create App '{name}'")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.free()

    def __del__(self):
        # __del__ must be bullet-proof.
        try:
            self.free()
        except Exception:
            pass

    def free(self):
        """
        Detach the application from all clients and stop its sequenced
        threads.

        {!!!!!  IMPORTANT  !!!!!}
        This method calls `LF_FreeApp`, which does NOT immediately
        destroy the underlying `TLF_App` object. The object remains
        alive in the global pool until `LF_Shutdown()` is called. This
        prevents dangling pointers while allowing network broadcasts
        to continue referencing the app data.

        To completely destroy the application and release its memory,
        you must call `LF_Shutdown()` (or use `Server.full_cleanup()` /
        `C4.full_cleanup()` if using those high-level wrappers).

        Safe to call multiple times. Safe to call on instances whose
        __init__ never ran or failed partway through: all attribute
        accesses use getattr-based defaults.
        """
        hnd = getattr(self, "_hnd", None)
        if hnd:
            LF_FreeApp(hnd)
            self._hnd = None
            # Release strong references to ctypes callbacks so they
            # can be garbage collected.
            callbacks = getattr(self, "_callbacks", None)
            if callbacks is not None:
                try:
                    callbacks.clear()
                except Exception:
                    pass

    @property
    def raw(self) -> AppHnd:
        """Return the raw ctypes handle for low-level operations."""
        return getattr(self, "_hnd", None)

    @property
    def name(self) -> str:
        """Return the application name."""
        return getattr(self, "_name", "")

    # ---- Bind this application to unbound clients ----

    def bind(self) -> int:
        """
        Bind this application to all currently unbound LingoFuse clients.

        This method must be called after the C4 main thread is active
        (i.e., after LF_PrepareDone). It registers the application with
        all clients that do not already have an app attached.

        Returns:
            The number of clients to which the application was
            successfully bound. A return value of 0 means no clients
            were available (all already occupied) or the main thread
            is not active.

        Important: The number of bound clients depends on how many
        distinct addresses were used when preparing clients. Clients
        prepared with the same address are not allowed - the underlying
        LF_PrepareClient will reject duplicate addresses. To bind to
        multiple clients, prepare each with a unique address (e.g.,
        different IPC names or different ports).
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")
        return LF_BindApp(self._hnd)

    # ---- API registration ----

    def register_call(self, api_name: str, func: Callable,
                      description: str = ""):
        """
        Register a Call API (request-response).

        The callback `func` will be invoked with `(trigger, inp, out)`
        where inp and out are DataHandle objects. The trigger is unused.

        {!!!!!  EXCEPTION ISOLATION  !!!!!}
        Any exception raised inside `func` is caught and logged. The
        exception never escapes into the C stack.

        Note: If the API name already exists, RegistrationError is raised.
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")

        def _c_call(trig, inp, out):
            h_in = DataHandle._from_raw(inp, owned=False)
            h_out = DataHandle._from_raw(out, owned=False)
            try:
                func(trig, h_in, h_out)
            except Exception:
                # Match the reference C core semantics: callbacks must
                # never let exceptions escape into the C stack. Log
                # and continue.
                _log.exception(
                    "Call callback for API '%s' raised an exception; "
                    "the exception has been suppressed",
                    api_name,
                )

        c_func = LFCallFunc(_c_call)
        self._callbacks.append(c_func)
        ret = LF_RegisterCall(
            self._hnd,
            cstr(api_name),
            cstr(description),
            ctypes.c_void_p(0),
            c_func,
        )
        if ret != 1:
            raise RegistrationError(
                f"Failed to register Call API '{api_name}'"
            )

    def register_notify(self, api_name: str, func: Callable,
                        description: str = ""):
        """
        Register a Notify API (one-way).

        The callback `func` will be invoked with `(trigger, inp)` where
        inp is a DataHandle. No output is expected.

        {!!!!!  EXCEPTION ISOLATION  !!!!!}
        Any exception raised inside `func` is caught and logged. The
        exception never escapes into the C stack.

        Note: If the API name already exists, RegistrationError is raised.
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")

        def _c_notify(trig, inp):
            h_in = DataHandle._from_raw(inp, owned=False)
            try:
                func(trig, h_in)
            except Exception:
                _log.exception(
                    "Notify callback for API '%s' raised an exception; "
                    "the exception has been suppressed",
                    api_name,
                )

        c_func = LFNotifyFunc(_c_notify)
        self._callbacks.append(c_func)
        ret = LF_RegisterNotify(
            self._hnd,
            cstr(api_name),
            cstr(description),
            ctypes.c_void_p(0),
            c_func,
        )
        if ret != 1:
            raise RegistrationError(
                f"Failed to register Notify API '{api_name}'"
            )

    def unregister(self, api_name: str) -> bool:
        """
        Unregister a previously registered API by name.

        The removal is immediate locally. Remote peers may still see the
        API for up to ~3 seconds until the network broadcast propagates.
        """
        if not self._hnd:
            return False
        return LF_Unregister(self._hnd, cstr(api_name)) == 1

    # ---- Local execution ----

    def local_call(self, param: DataHandle) -> DataHandle:
        """
        Execute a Call API locally within the same process.

        The call is synchronous and returns a new DataHandle containing
        the result. The input handle is not freed by this method; the
        caller must free it.

        The returned DataHandle inherits this App's serializer settings
        (the module-level defaults, since App itself does not customize
        serialization).
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")
        h_res = LF_LocalCall(self._hnd, param.raw)
        if not h_res:
            raise LingoFuseError("Local call returned a null handle")
        return DataHandle._from_raw(
            h_res,
            owned=True,
            serializer=param._serializer,
            deserializer=param._deserializer,
        )

    def local_notify(self, param: DataHandle):
        """
        Send a notification locally within the same process.

        This is synchronous but does not wait for a response.
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")
        LF_LocalNotify(self._hnd, param.raw)

    # ---- Sequenced notification ----

    def sequenced_notify(self, param: DataHandle):
        """
        Send a sequenced notification to this application.

        The notification will be delivered in FIFO order for the same
        (app, api) pair. The underlying thread pool handles ordering.
        The call returns immediately after queuing the notification.
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")
        LF_Sequenced_Notify(cstr(self._name), param.raw)