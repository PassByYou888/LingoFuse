# -*- coding: utf-8 -*-
"""
Core RAII wrappers: DataHandle and App.

This module provides safe, high-level access to the LingoFuse C ABI.
All string parameters are UTF-8 encoded/decoded automatically.

=========================== DATA HANDLE ============================
DataHandle wraps a binary buffer that can be read/written sequentially.
It is an RAII object: freeing the Python object calls LF_FreeData.

Important notes from Pascal import (lingofuse_import.pas):
- Always free DataHandle objects explicitly (or use `with` / context manager)
  to release resources promptly. The library has an automatic idle-timeout
  reclaimer (5 minutes), but it is not immediate.
- Do not free a handle while it is being used in a callback or while
  a remote call is pending.
- Concurrent writes to the same handle must be serialised externally;
  reads are safe.

String handling rules (critical for cross-language compatibility):
- write_string() always appends a null terminator (\\0) to match
  Pascal's LF_WriteString. This is required for the other side to
  correctly read the string with LF_ReadString.
- read_string() is fault-tolerant: it scans for a \\0 and returns
  the content before it. If no \\0 is found, it returns the entire
  remaining buffer as a string (consuming all data). This handles
  both null-terminated and raw data (e.g., plain JSON without \\0).

Atomic read/write methods (write_int32, read_int32, etc.) use little-endian
byte order, which matches the Pascal convention.

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
- bind() – binds this application to all currently unbound LingoFuse clients.
  Returns the number of clients bound. A return value of 0 means no free
  clients or the main thread is not active. Note that clients must have
  been prepared with distinct physical addresses (LF_PrepareClient cannot
  reuse the same address). Therefore, to bind to multiple clients, you
  must prepare them with different addresses (e.g., different IPC names
  or different ports).

- App also provides a convenient `sequenced_notify()` method.

Thread-safety:
- All methods are thread-safe, but callback registration should be done
  before starting the network.
- Callbacks registered via register_call/register_notify run in background
  threads. They must not block or call any blocking LingoFuse function
  (e.g., LF_Call) to avoid deadlocks.

{!!!!!  APP LIFETIME  !!!!!}
- `App.free()` detaches the application but does NOT destroy it immediately.
  The underlying object remains in the global pool until `LF_Shutdown()` is called.
- For proper resource cleanup, always call `LF_Shutdown()` or use the
  `full_cleanup()` methods provided by `Server` and `C4` when you are done.
"""
import ctypes
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


# ---- New module-level convenience functions ----

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


class DataHandle:
    """
    RAII wrapper for a LingoFuse data handle (TDataHnd).

    Context manager support: use `with DataHandle(...) as dh:` to auto-free.
    Ownership: by default, the object owns the handle and frees it on destruction.
    You can also wrap a raw handle with `_from_raw(hnd, owned=True)`.

    All read/write methods update an internal timestamp used by the library's
    idle-timeout reclaimer. However, you should still free handles explicitly
    when they are no longer needed.
    """

    def __init__(self, api_name: str, data: Any = None, serializer=None):
        """
        Create a new data handle for the given API name.

        The API name is stored internally and will be used as the MethodName
        in the wire protocol. The buffer is initially empty.

        If `data` is provided, it is serialized using the default serializer
        (JSON) and written to the buffer immediately.

        Args:
            api_name: Name of the target API (UTF-8).
            data: Optional object to serialize and write.
            serializer: Callable that converts object to bytes (default JSON).
        """
        self._hnd = LF_CreateData(api_name.encode("utf-8"))
        if not self._hnd:
            raise LingoFuseError("Failed to create DataHandle")
        self._owned = True
        self._serializer = serializer or default_serializer
        self._deserializer = default_deserializer  # 显式初始化
        if data is not None:
            self.write(data)

    @classmethod
    def _from_raw(cls, hnd: DataHnd, owned: bool = True):
        """
        Wrap an existing raw data handle.

        Args:
            hnd: The raw handle (DataHnd) to wrap.
            owned: If True, LF_FreeData will be called when this object is destroyed.

        Returns:
            A new DataHandle instance.
        """
        obj = cls.__new__(cls)
        obj._hnd = hnd
        obj._owned = owned
        obj._serializer = default_serializer
        obj._deserializer = default_deserializer
        return obj

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.free()

    def __del__(self):
        self.free()

    def free(self):
        """Free the underlying handle if owned."""
        if self._owned and self._hnd:
            LF_FreeData(self._hnd)
            self._hnd = None

    @property
    def raw(self) -> DataHnd:
        """Return the raw ctypes handle for low-level operations."""
        return self._hnd

    def write(self, obj: Any) -> int:
        """Write a Python object using the default serializer (JSON)."""
        data = self._serializer(obj)
        return LF_WriteBuffer(self._hnd, data, len(data))

    def read(self, deserializer=None) -> Any:
        """Read and deserialize data using the default or custom deserializer."""
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
        return LF_GetPos(self._hnd)

    def set_pos(self, pos: int) -> None:
        LF_SetPos(self._hnd, pos)

    def get_size(self) -> int:
        return LF_GetSize(self._hnd)

    def set_size(self, size: int) -> None:
        LF_SetSize(self._hnd, size)

    @property
    def size(self) -> int:
        return self.get_size()

    # ---------- Atomic types (little-endian) ----------
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

    # ---- String and JSON helpers ----
    def write_string(self, value: str) -> bool:
        """
        Write a UTF-8 string followed by a null terminator (\\0).

        This is the preferred method for writing plain text strings.
        It automatically encodes to UTF-8 and appends a zero byte, which is
        required for compatibility with Pascal's LF_ReadString.

        Returns True if the full string (including terminator) was written.
        """
        utf8 = value.encode('utf-8')
        written = self._write_bytes(utf8)
        if written != len(utf8):
            return False
        return self._write_pack('<B', 0) == 1

    # Alias for backward compatibility
    write_string_null_terminated = write_string

    def read_string(self) -> str:
        """
        Read a null-terminated UTF-8 string from the current position.

        Fault-tolerant:
        - Scans for a '\\0' byte; if found, returns content before it and advances past it.
        - If no '\\0' is found, returns the entire remaining buffer as a string and moves to end.
        This handles both null-terminated and raw data (e.g., plain JSON from HTTP bridges).

        Returns an empty string if at end of buffer.
        """
        pos = self.get_pos()
        size = self.get_size()
        if pos >= size:
            return ""

        ptr = LF_GetBuffer(self._hnd)
        if not ptr:
            raise BufferError("DataHandle buffer is invalid")

        end = pos
        while end < size:
            if ctypes.string_at(ptr + end, 1) == b'\x00':
                break
            end += 1

        if end < size:
            raw = ctypes.string_at(ptr + pos, end - pos)
            self.set_pos(end + 1)
            return raw.decode('utf-8')

        # No null: consume all remaining data
        raw = ctypes.string_at(ptr + pos, size - pos)
        self.set_pos(size)
        return raw.decode('utf-8')

    # Alias for backward compatibility
    read_string_null_terminated = read_string

    def write_json(self, obj: Any) -> int:
        """
        Serialize a Python object to JSON and write as null-terminated UTF-8.

        Uses ensure_ascii=False for compact Unicode output. The JSON string
        is encoded as UTF-8 and a terminating null byte is appended.

        Returns the number of bytes written.
        """
        data = json.dumps(obj, ensure_ascii=False).encode('utf-8') + b'\x00'
        return LF_WriteBuffer(self._hnd, data, len(data))

    def read_json(self) -> Any:
        """
        Read null-terminated UTF-8 JSON data and deserialize to a Python object.

        Removes the trailing null byte (if present) before decoding and parsing.
        Returns None if the buffer is empty or parsing fails.
        """
        size = self.get_size()
        if size == 0:
            return None
        buf = (ctypes.c_byte * size)()
        LF_SetPos(self._hnd, 0)
        LF_ReadBuffer(self._hnd, buf, size)
        raw = bytes(buf)
        if raw and raw[-1] == 0:
            raw = raw[:-1]
        try:
            return json.loads(raw.decode('utf-8'))
        except Exception:
            return None

    # ---------- Low-level helpers ----------
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
            raise BufferError(f"Not enough data to read {fmt}")
        return struct.unpack(fmt, data)[0]

    def _read_bytes(self, n: int) -> bytes:
        if n <= 0:
            return b''
        buf = (ctypes.c_byte * n)()
        read = LF_ReadBuffer(self._hnd, buf, n)
        if read != n:
            raise BufferError(f"Read only {read} bytes, expected {n}")
        return bytes(buf)


class App:
    """
    RAII wrapper for a LingoFuse application handle (TAppHnd).

    An application is a container for related APIs. Each App has a unique
    name used for discovery and routing across the network.

    Important notes (from Pascal import):
    - API names are case-insensitive when matching, but stored as given.
    - If you register the same API name twice, the second registration fails.
    - The Trigger pointer passed to register_call/register_notify is unused
      in these Python bindings; you can safely pass None (the callbacks
      are object methods that don't need extra context).
    - Use the Sync variants if your callback accesses UI components or
      non-thread-safe objects; otherwise, use non-sync for better performance.
    - Do not call any blocking LingoFuse function (e.g., LF_Call) from inside
      a callback to avoid deadlocks.

    {!!!!!  LIFETIME  !!!!!}
    - `free()` detaches the app but does NOT destroy it immediately.
      The object remains in the global pool until `LF_Shutdown()` is called.
    - To fully release resources, use `Server.full_cleanup()`, `C4.full_cleanup()`,
      or call `LF.Shutdown()` directly.

    New in v1.1:
    - bind() method to dynamically attach this App to free clients.
      Note: The number of clients you can bind to is limited by how many
      distinct addresses you prepared with LF_PrepareClient. You cannot
      create multiple clients on the same address.
    - sequenced_notify() convenience method.
    """

    def __init__(self, name: str, description: str = ""):
        """
        Create a new application with the given name and description.

        The name must be unique within the network and is used for routing.
        """
        self._name = name
        self._hnd = LF_CreateApp(name.encode("utf-8"), description.encode("utf-8"))
        if not self._hnd:
            raise LingoFuseError(f"Failed to create App '{name}'")
        self._callbacks = []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.free()

    def __del__(self):
        self.free()

    def free(self):
        """
        Detach the application from all clients and stop its sequenced threads.

        {!!!!!  IMPORTANT  !!!!!}
        This method calls `LF_FreeApp`, which **does not immediately destroy**
        the underlying `TLF_App` object. The object remains alive in the global
        pool until `LF_Shutdown()` is called. This prevents dangling pointers
        while allowing network broadcasts to continue referencing the app data.

        To completely destroy the application and release its memory, you must
        call `LF_Shutdown()` (or use `Server.full_cleanup()` / `C4.full_cleanup()`
        if using those high-level wrappers).
        """
        if self._hnd:
            LF_FreeApp(self._hnd)
            self._hnd = None
            self._callbacks.clear()

    @property
    def raw(self) -> AppHnd:
        """Return the raw ctypes handle for low-level operations."""
        return self._hnd

    @property
    def name(self) -> str:
        """Return the application name."""
        return self._name

    # ---- NEW: Bind this application to unbound clients ----
    def bind(self) -> int:
        """
        Bind this application to all currently unbound LingoFuse clients.

        This method must be called after the C4 main thread is active (i.e.,
        after LF_PrepareDone). It registers the application with all clients
        that do not already have an app attached.

        Returns:
            The number of clients to which the application was successfully bound.
            A return value of 0 means no clients were available (all already occupied)
            or the main thread is not active.

        Important: The number of bound clients depends on how many distinct
        addresses were used when preparing clients. Clients prepared with the
        same address are not allowed – the underlying LF_PrepareClient will
        reject duplicate addresses. To bind to multiple clients, prepare each
        with a unique address (e.g., different IPC names or different ports).
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")
        return LF_BindApp(self._hnd)

    # ---- API registration ----
    def register_call(self, api_name: str, func: Callable, description: str = ""):
        """
        Register a Call API (request-response).

        The callback `func` will be invoked with `(trigger, inp, out)` where
        inp and out are DataHandle objects. The trigger is unused.

        Note: If the API name already exists, RegistrationError is raised.
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")
        def _c_call(trig, inp, out):
            h_in = DataHandle._from_raw(inp, owned=False)
            h_out = DataHandle._from_raw(out, owned=False)
            func(trig, h_in, h_out)
        c_func = LFCallFunc(_c_call)
        self._callbacks.append(c_func)
        ret = LF_RegisterCall(self._hnd,
                              api_name.encode("utf-8"),
                              description.encode("utf-8"),
                              ctypes.c_void_p(0),
                              c_func)
        if ret != 1:
            raise RegistrationError(f"Failed to register Call API '{api_name}'")

    def register_notify(self, api_name: str, func: Callable, description: str = ""):
        """
        Register a Notify API (one-way).

        The callback `func` will be invoked with `(trigger, inp)` where
        inp is a DataHandle. No output is expected.

        Note: If the API name already exists, RegistrationError is raised.
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")
        def _c_notify(trig, inp):
            h_in = DataHandle._from_raw(inp, owned=False)
            func(trig, h_in)
        c_func = LFNotifyFunc(_c_notify)
        self._callbacks.append(c_func)
        ret = LF_RegisterNotify(self._hnd,
                                api_name.encode("utf-8"),
                                description.encode("utf-8"),
                                ctypes.c_void_p(0),
                                c_func)
        if ret != 1:
            raise RegistrationError(f"Failed to register Notify API '{api_name}'")

    def unregister(self, api_name: str) -> bool:
        """
        Unregister a previously registered API by name.

        The removal is immediate locally. Remote peers may still see the API
        for up to ~3 seconds until the network broadcast propagates.
        """
        if not self._hnd:
            return False
        return LF_Unregister(self._hnd, api_name.encode("utf-8")) == 1

    # ---- Local execution ----
    def local_call(self, param: DataHandle) -> DataHandle:
        """
        Execute a Call API locally within the same process.

        The call is synchronous and returns a new DataHandle containing the result.
        The input handle is not freed by this method; the caller must free it.
        """
        if not self._hnd:
            raise LingoFuseError("App already freed")
        h_res = LF_LocalCall(self._hnd, param.raw)
        if not h_res:
            raise LingoFuseError("Local call failed")
        return DataHandle._from_raw(h_res, owned=True)

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
        LF_Sequenced_Notify(self._name.encode("utf-8"), param.raw)