# -*- coding: utf-8 -*-
"""
lingofuse.lf_io - Unified JSON and string I/O for LingoFuse handles.

This module is the SINGLE place in the toolchain where Python objects
are converted to, and from, the bytes carried by a LingoFuse
DataHandle. Every service that touches a DataHandle -- inside or
outside the lingofuse package -- MUST use the helpers defined here
instead of calling json.dumps / json.loads / DataHandle.write_json /
DataHandle.read_json directly.

Wire format
-----------
A JSON payload on a DataHandle is:

    <UTF-8 encoded JSON text> <NUL>

A plain-text payload uses the same framing: <UTF-8 text> <NUL>.

{!!!!!  CRITICAL IMPLEMENTATION NOTE: LF_GetBuffer IS NOT USED  !!!!!}
An earlier revision of _read_until_nul obtained the internal buffer
pointer via LF_GetBuffer and then walked it with ctypes pointer
arithmetic to locate the NUL byte. That pattern produced a hard
access violation on Windows when the same DataHandle had just been
read via LF_ReadBuffer several times. The root cause is that the
raw pointer returned by LF_GetBuffer is a low-level implementation
detail of the underlying TMem64; the only contractually safe way to
consume a DataHandle's bytes is LF_ReadBuffer. This module therefore
reads through LF_ReadBuffer exclusively and never dereferences a
pointer obtained from LF_GetBuffer.

JSON serialization policy
-------------------------
dumps_json() is the single source of truth for the toolchain-wide
JSON encoding policy:

    json.dumps(obj, ensure_ascii=False, default=str)

JSON deserialization policy
---------------------------
Every JSON read path routes the decoded text through
lingofuse.json_repair_preprocess.repair_json_text before json.loads:
valid -> unchanged, repairable -> repaired + one WARNING,
unrepairable -> unchanged + one ERROR (or suppressed for lenient
readers).

Threading
---------
All helpers are stateless. Concurrent access to the SAME DataHandle
must still be serialized by the caller.

Dependencies
------------
Standard library: ctypes, json.
Same package: lingofuse._lf_native, lingofuse.json_repair_preprocess.

All comments, docstrings, and log messages are in English.
"""

from __future__ import annotations

import ctypes
import json
from typing import Any

from ._lf_native import (
    DataHnd,
    LF_GetPos,
    LF_GetSize,
    LF_ReadBuffer,
    LF_SetPos,
    LF_WriteBuffer,
)
from .json_repair_preprocess import repair_json_text


NUL: bytes = b"\x00"
ENCODING: str = "utf-8"


def dumps_json(obj: Any) -> str:
    """
    Serialize obj to a JSON string using the toolchain-wide policy:
    ensure_ascii=False and default=str.
    """
    return json.dumps(obj, ensure_ascii=False, default=str)


def _write_bytes(hnd: DataHnd, data: bytes) -> None:
    """
    Append data to the DataHandle at its current position.

    Raises RuntimeError on a short write. A short write means the
    handle is corrupt or the process is out of memory; silently
    continuing would produce a truncated payload on the wire.
    """
    if not data:
        return
    written = LF_WriteBuffer(hnd, data, len(data))
    if written != len(data):
        raise RuntimeError(
            f"LF_WriteBuffer wrote {written} of {len(data)} bytes"
        )


def _read_until_nul(hnd: DataHnd) -> bytes:
    """
    Read bytes from the current position up to (and excluding) the
    first NUL, then advance the handle position to just past that
    NUL. If no NUL is found, read all remaining bytes and leave the
    position at the end.

    Implementation contract
    -----------------------
    This function ONLY uses LF_ReadBuffer / LF_GetPos / LF_GetSize /
    LF_SetPos. It deliberately does NOT use LF_GetBuffer. See the
    module docstring section "LF_GetBuffer IS NOT USED" for why: the
    raw pointer returned by LF_GetBuffer is a low-level detail and
    dereferencing it with ctypes pointer arithmetic has been observed
    to produce hard access violations on Windows. LF_ReadBuffer is
    the only contractually safe way to consume the bytes.

    Cursor semantics
    ----------------
    The handle position after this call is:
      * (position of first NUL) + 1, if a NUL was found;
      * size, if no NUL was found.

    This matches the wire protocol convention used by the rest of
    the toolchain.
    """
    pos = LF_GetPos(hnd)
    size = LF_GetSize(hnd)
    if pos >= size:
        return b""

    remaining = size - pos
    buf = (ctypes.c_byte * remaining)()
    read = LF_ReadBuffer(hnd, buf, remaining)
    if read != remaining:
        raise RuntimeError(
            f"LF_ReadBuffer read {read} of {remaining} bytes"
        )

    raw = bytes(buf)
    nul_idx = raw.find(b"\x00")
    if nul_idx < 0:
        return raw

    LF_SetPos(hnd, pos + nul_idx + 1)
    return raw[:nul_idx]


def _read_all(hnd: DataHnd) -> bytes:
    """
    Read all remaining bytes from the handle. Position advances to
    the end. No NUL handling.
    """
    pos = LF_GetPos(hnd)
    size = LF_GetSize(hnd)
    if pos >= size:
        return b""
    length = size - pos
    buf = (ctypes.c_byte * length)()
    read = LF_ReadBuffer(hnd, buf, length)
    if read != length:
        raise RuntimeError(
            f"LF_ReadBuffer read {read} of {length} bytes"
        )
    return bytes(buf)


def write_string(hnd: DataHnd, value: str) -> None:
    """
    Write value as UTF-8 bytes followed by a NUL terminator.

    An empty string is written as a single NUL byte.
    None is treated as the empty string.
    """
    if value is None:
        value = ""
    _write_bytes(hnd, value.encode(ENCODING) + NUL)


def write_string_bytes(hnd: DataHnd, data: bytes) -> None:
    """
    Write raw bytes followed by a NUL terminator.

    Bytes are NOT validated as UTF-8. Use only for already-encoded
    UTF-8 payloads (e.g. the output of json.dumps with
    ensure_ascii=False).
    """
    if data:
        _write_bytes(hnd, data)
    _write_bytes(hnd, NUL)


def read_string(hnd: DataHnd) -> str:
    """
    Read a UTF-8 string from the handle, stopping at the first NUL.

    If no NUL is present, the entire remaining buffer is consumed
    and decoded. Returns an empty string if the handle is already
    at its end, or if the first byte is a NUL.

    Raises RuntimeError if the bytes are not valid UTF-8.
    """
    raw = _read_until_nul(hnd)
    if not raw:
        return ""
    try:
        return raw.decode(ENCODING)
    except UnicodeDecodeError as e:
        raise RuntimeError(
            f"lf_io.read_string: buffer contains invalid UTF-8: {e}"
        ) from e


def read_string_bytes(hnd: DataHnd) -> bytes:
    """
    Read raw bytes from the handle, stopping at the first NUL.
    The bytes are returned undecoded.
    """
    return _read_until_nul(hnd)


def peek_string_bytes(hnd: DataHnd) -> bytes:
    """
    Read raw bytes up to the first NUL without advancing the
    handle position. The saved position is restored before return.
    """
    saved_pos = LF_GetPos(hnd)
    try:
        return _read_until_nul(hnd)
    finally:
        LF_SetPos(hnd, saved_pos)


def read_all_bytes(hnd: DataHnd) -> bytes:
    """
    Read all remaining bytes from the handle, without NUL handling.
    """
    return _read_all(hnd)


read_bytes = read_all_bytes


def write_json(hnd: DataHnd, obj: Any) -> None:
    """
    Serialize obj as UTF-8 JSON and write it with a NUL terminator.
    ensure_ascii=False is guaranteed by dumps_json.
    """
    _write_bytes(hnd, dumps_json(obj).encode(ENCODING) + NUL)


def read_json(hnd: DataHnd) -> Any:
    """
    Read a UTF-8 JSON payload from the handle and return the decoded
    object.

    Empty buffer -> None.
    Invalid UTF-8 -> RuntimeError.
    Invalid JSON (after repair) -> RuntimeError.
    """
    raw = _read_until_nul(hnd)
    if not raw:
        return None
    try:
        text = raw.decode(ENCODING)
    except UnicodeDecodeError as e:
        raise RuntimeError(
            f"lf_io.read_json: buffer contains invalid UTF-8: {e}"
        ) from e

    text = repair_json_text(text, source="lf_io.read_json")

    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        preview = raw[:200]
        raise RuntimeError(
            f"lf_io.read_json: buffer contains invalid JSON: {e}; "
            f"first {len(preview)} bytes: {preview!r}"
        ) from e


def read_json_or_bytes(hnd: DataHnd) -> Any:
    """
    Read a UTF-8 payload and return either the decoded JSON object
    or the raw bytes.

    Empty -> None.
    Valid JSON -> decoded object.
    Valid UTF-8 but not JSON -> raw bytes.
    Invalid UTF-8 -> raw bytes.
    """
    raw = _read_until_nul(hnd)
    if not raw:
        return None
    try:
        text = raw.decode(ENCODING)
    except UnicodeDecodeError:
        return raw

    text = repair_json_text(
        text,
        source="lf_io.read_json_or_bytes",
        report_failure=False,
    )

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return raw


def cstr(value: str) -> bytes:
    """
    Return NUL-terminated UTF-8 bytes for a ctypes.c_char_p parameter
    of an LF_* function.

    None is treated as the empty string.
    """
    if value is None:
        value = ""
    return value.encode(ENCODING) + NUL


__all__ = [
    "NUL",
    "ENCODING",
    "dumps_json",
    "write_string",
    "write_string_bytes",
    "read_string",
    "read_string_bytes",
    "peek_string_bytes",
    "read_all_bytes",
    "read_bytes",
    "write_json",
    "read_json",
    "read_json_or_bytes",
    "cstr",
]