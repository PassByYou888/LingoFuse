# -*- coding: utf-8 -*-
"""
Core RAII wrappers: DataHandle and App.
"""
import ctypes
import struct
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
    LFCallFunc, LFNotifyFunc,
)
from .errors import LingoFuseError, RegistrationError
from .serializers import default_serializer, default_deserializer


class DataHandle:
    """
    RAII wrapper for a LingoFuse data handle (TDataHnd).
    """

    def __init__(self, api_name: str, data: Any = None, serializer=None):
        self._hnd = LF_CreateData(api_name.encode("utf-8"))
        if not self._hnd:
            raise LingoFuseError("Failed to create DataHandle")
        self._owned = True
        self._serializer = serializer or default_serializer
        self._deserializer = None
        if data is not None:
            self.write(data)

    @classmethod
    def _from_raw(cls, hnd: DataHnd, owned: bool = True):
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
        if self._owned and self._hnd:
            LF_FreeData(self._hnd)
            self._hnd = None

    @property
    def raw(self) -> DataHnd:
        return self._hnd

    def write(self, obj: Any) -> int:
        data = self._serializer(obj)
        return LF_WriteBuffer(self._hnd, data, len(data))

    def read(self, deserializer=None) -> Any:
        size = LF_GetSize(self._hnd)
        if size == 0:
            return None
        buf = (ctypes.c_byte * size)()
        LF_SetPos(self._hnd, 0)
        LF_ReadBuffer(self._hnd, buf, size)
        raw = bytes(buf)
        des = deserializer or self._deserializer or default_deserializer
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

    # ---------- Atomic types (little‑endian) ----------
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

    def write_string_null_terminated(self, value: str) -> bool:
        """
        Write a UTF-8 string followed by a null terminator (\\0).

        This function always appends a '\\0' byte at the end, ensuring
        compatibility with LF_ReadString conventions.
        """
        utf8 = value.encode('utf-8')
        written = self._write_bytes(utf8)
        if written != len(utf8):
            return False
        return self._write_pack('<B', 0) == 1

    def _write_pack(self, fmt: str, value) -> int:
        data = struct.pack(fmt, value)
        return self._write_bytes(data)

    def _write_bytes(self, data: bytes) -> int:
        if not data:
            return 0
        return LF_WriteBuffer(self._hnd, data, len(data))

    # ---------- Read helpers ----------
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

    def read_string_null_terminated(self) -> str:
        """
        Read a null-terminated UTF-8 string from the current position.

        **Fault-tolerant behavior**:
        - First, scans for a '\\0' byte. If found, returns the content before it
          and advances past the '\\0'.
        - If no '\\0' is found before the end of the buffer, returns the entire
          remaining buffer content as a string and moves the position to the end.
        - This handles both standard null-terminated strings (Pascal-style) and
          raw data without a terminator (e.g., plain JSON).
        """
        pos = self.get_pos()
        size = self.get_size()
        if pos >= size:
            return ""

        ptr = LF_GetBuffer(self._hnd)
        if not ptr:
            raise BufferError("DataHandle buffer is invalid")

        # Scan from pos to size for a null byte
        end = pos
        while end < size:
            if ctypes.string_at(ptr + end, 1) == b'\x00':
                break
            end += 1

        # If null found, read from pos to end and skip the null
        if end < size:
            raw = ctypes.string_at(ptr + pos, end - pos)
            self.set_pos(end + 1)
            return raw.decode('utf-8')

        # No null: consume all remaining data as one string
        raw = ctypes.string_at(ptr + pos, size - pos)
        self.set_pos(size)
        return raw.decode('utf-8')

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
    """

    def __init__(self, name: str, description: str = ""):
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
        if self._hnd:
            LF_FreeApp(self._hnd)
            self._hnd = None
            self._callbacks.clear()

    @property
    def raw(self) -> AppHnd:
        return self._hnd

    @property
    def name(self) -> str:
        return self._name

    def register_call(self, api_name: str, func: Callable, description: str = ""):
        if not self._hnd:
            raise LingoFuseError("App already freed")
        def _c_call(trig, inp, out):
            h_in = DataHandle._from_raw(inp, owned=False)
            h_out = DataHandle._from_raw(out, owned=False)
            func(trig, h_in, h_out)
        c_func = LFCallFunc(_c_call)
        self._callbacks.append(c_func)
        ret = LF_RegisterCall(self._hnd, api_name.encode("utf-8"), description.encode("utf-8"),
                              ctypes.c_void_p(0), c_func)
        if ret != 1:
            raise RegistrationError(f"Failed to register Call API '{api_name}'")

    def register_notify(self, api_name: str, func: Callable, description: str = ""):
        if not self._hnd:
            raise LingoFuseError("App already freed")
        def _c_notify(trig, inp):
            h_in = DataHandle._from_raw(inp, owned=False)
            func(trig, h_in)
        c_func = LFNotifyFunc(_c_notify)
        self._callbacks.append(c_func)
        ret = LF_RegisterNotify(self._hnd, api_name.encode("utf-8"), description.encode("utf-8"),
                                ctypes.c_void_p(0), c_func)
        if ret != 1:
            raise RegistrationError(f"Failed to register Notify API '{api_name}'")

    def unregister(self, api_name: str) -> bool:
        if not self._hnd:
            return False
        return LF_Unregister(self._hnd, api_name.encode("utf-8")) == 1

    def local_call(self, param: DataHandle) -> DataHandle:
        if not self._hnd:
            raise LingoFuseError("App already freed")
        h_res = LF_LocalCall(self._hnd, param.raw)
        if not h_res:
            raise LingoFuseError("Local call failed")
        return DataHandle._from_raw(h_res, owned=True)

    def local_notify(self, param: DataHandle):
        if not self._hnd:
            raise LingoFuseError("App already freed")
        LF_LocalNotify(self._hnd, param.raw)

    def sequenced_notify(self, param: DataHandle):
        if not self._hnd:
            raise LingoFuseError("App already freed")
        LF_Sequenced_Notify(self._name.encode("utf-8"), param.raw)