# -*- coding: utf-8 -*-
"""
lingofuse.lf_io - Unified JSON and string I/O for LingoFuse handles.

This module is the SINGLE place in the toolchain where Python objects
are converted to, and from, the bytes carried by a LingoFuse
DataHandle. Every service that touches a DataHandle -- inside or
outside the lingofuse package -- MUST use the helpers defined here
instead of calling json.dumps / json.loads / DataHandle.write_json /
DataHandle.read_json directly.

Callers inside the toolchain include:

  lingofuse package (this module lives here):
    - lingofuse.core        DataHandle.write_string / read_string /
                            write_json / read_json delegate here;
                            DataHandle.__init__ and the App class
                            route every c_char_p argument through
                            cstr.
    - lingofuse.server      Server.start / start_multi / json_notify /
                            json_sequenced_notify / json_call route
                            c_char_p arguments through cstr.
    - lingofuse.client      C4._connect / __getattr__._call /
                            json_notify / json_sequenced_notify /
                            json_call route c_char_p arguments
                            through cstr.
    - lingofuse.serializers default_serializer delegates to
                            dumps_json.
    - lingofuse.bridge      HTTP passthrough gateway. JSON error
                            responses via dumps_json; DataHandle
                            payload I/O via write_string_bytes /
                            read_string_bytes; LF_* arguments via
                            cstr.
    - lingofuse.__init__    set_option / post_status / check_app /
                            check_api route c_char_p arguments
                            through cstr.

  llm_common package:
    - llm_common.headers    jdump (the HTTP path for OpenAI request
                            bodies).
    - llm_common.sse_client consumes headers.jdump indirectly for the
                            outbound direction.

  top-level LLM services:
    - llm_service.py
    - llm_proxy.py
    - llm_proxy_tool.py
    - mcp_api_tool.py
    - language_middleware.py
    - llm_test.py

Centralizing this logic guarantees four invariants that would
otherwise drift across files:

  1. Every JSON payload is serialized with ensure_ascii=False, so
     Chinese, emoji, and other non-ASCII content reaches the other
     side as literal UTF-8 bytes. No \\uXXXX escape ever appears on
     the wire.

  2. Every string written to a DataHandle is NUL-terminated, matching
     the wire protocol convention where the receiving side stops at
     the first #0 byte.

  3. Every string read from a DataHandle tolerates a missing NUL
     terminator. This is required for inputs that arrive from an HTTP
     bridge (bridge.py) or any non-standard producer that sends raw
     JSON without a trailing NUL.

  4. LF_* C-ABI string parameters (app name, API name, endpoint,
     option name, option value) are always passed as NUL-terminated
     UTF-8 bytes via cstr(), instead of relying on CPython's hidden
     NUL inside bytes objects.

{!!!!!  UNIFIED JSON REPAIR PREPROCESSING  !!!!!}
As of this revision, both JSON read paths in this module route the
decoded text through lingofuse.json_repair_preprocess.repair_json_text
before handing it to json.loads. The policy is:

    * Valid JSON       -> returned unchanged, no log message.
    * Repairable JSON  -> repaired, one WARNING naming the source.
    * Unrepairable     -> returned unchanged, one ERROR naming the
                          source (read_json only; read_json_or_bytes
                          suppresses the error because a non-JSON
                          payload is a legitimate outcome there).

The repair engine itself lives in lingofuse.json_repair. If that
subpackage is unavailable, the preprocessor degrades to validation
only, and emits a single load-time WARNING. See
lingofuse/json_repair_preprocess.py for the full contract.

This preprocessing is READ-ONLY in the sense that it never mutates a
DataHandle: it operates on the decoded text. The write path
(dumps_json / write_json / write_string) is intentionally NOT
affected, because json.dumps always produces valid JSON.

Wire format
-----------
A JSON payload on a DataHandle is:

    <UTF-8 encoded JSON text> <NUL>

The receiving side:
    1. Reads bytes from the current position up to (but not including)
       the first NUL, or to the end of the buffer if no NUL is present.
    2. Decodes the bytes as UTF-8.
    3. (NEW) Runs the unified JSON repair preprocessing.
    4. Parses the result as JSON.

A plain-text payload uses the same framing: <UTF-8 text> <NUL>.

Compatibility with the wire protocol
------------------------------------
The framing follows the standard convention used by the LingoFuse
ecosystem:

    Reference implementation writes: 7B 22 61 22 3A 31 7D 00
    lf_io.write_json(hnd, {"a": 1})
        -> bytes  7B 22 61 22 3A 31 7D 00

    The receiving side stops at the NUL. lf_io.read_json on the
    receiving side stops at the NUL too, and falls back to reading
    the entire buffer if no NUL is present.

JSON serialization policy
-------------------------
Every JSON string produced by the toolchain goes through dumps_json().
That function is the single source of truth for the serialization
policy:

    json.dumps(obj, ensure_ascii=False, default=str)

Callers that want only the string use dumps_json() directly; callers
that want to write the string to a DataHandle with the required NUL
terminator use write_json(). The HTTP path in llm_common.headers.jdump()
also uses dumps_json(), so the LF path and the HTTP path share one
policy.

JSON deserialization policy
---------------------------
Every JSON text read by the toolchain goes through the unified repair
preprocessor BEFORE it reaches json.loads(). The two read entry points
in this module apply different failure-reporting policies:

    read_json           strict reader, reports unrepairable payloads
                        as ERROR, raises RuntimeError on final failure.
    read_json_or_bytes  lenient reader, suppresses repair errors
                        because a non-JSON payload is a legitimate
                        outcome (returns the raw bytes in that case).

Threading
---------
All helpers are stateless. Concurrent access to the SAME DataHandle
must still be serialized by the caller, matching the contract of
lingofuse.core.DataHandle and lingofuse._lf_native.

Dependencies
------------
Standard library: ctypes, json.
Same package: lingofuse._lf_native (low-level C ABI only).
Same package: lingofuse.json_repair_preprocess (unified repair).
This module does NOT depend on lingofuse.core, so it is usable from
contexts where the RAII wrapper is not available (for example, inside
language_middleware.py, which works with raw handles).

Dependency direction (toolchain-wide):

    lingofuse.core, lingofuse.server, lingofuse.client,
    lingofuse.serializers, lingofuse.bridge, lingofuse.__init__
        -> lingofuse._lf_native
        -> lingofuse.lf_io    (this module)
        -> lingofuse.json_repair_preprocess
        -> lingofuse.json_repair

    llm_common.headers
        -> lingofuse.lf_io    (this module)

    llm_common.sse_client
        -> llm_common.headers
        -> lingofuse.lf_io    (this module, indirect)

    lingofuse.*  ->  llm_common.*   : FORBIDDEN

All comments, docstrings, and log messages are in English.
"""

from __future__ import annotations

import ctypes
import json
from typing import Any

from ._lf_native import (
    DataHnd,
    LF_GetBuffer,
    LF_GetPos,
    LF_GetSize,
    LF_ReadBuffer,
    LF_SetPos,
    LF_WriteBuffer,
)
from .json_repair_preprocess import repair_json_text


# ----------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------

#: The NUL byte used as the string terminator on the wire.
NUL: bytes = b"\x00"

#: The only text encoding used on the wire. Matches the UTF-8
#: convention used across the LingoFuse ecosystem.
ENCODING: str = "utf-8"


# ----------------------------------------------------------------------
# JSON serialization policy (public)
# ----------------------------------------------------------------------
#
# dumps_json() is the single source of truth for how a Python object
# becomes a JSON string in this toolchain. Both the LF DataHandle path
# (write_json) and the HTTP path (llm_common.headers.jdump) route
# through it.
#
# Guarantees:
#   * ensure_ascii=False. Non-ASCII characters (Chinese, emoji,
#     accented Latin letters) are emitted as literal characters in the
#     returned string. The string NEVER contains a \uXXXX escape.
#   * default=str. Any object the encoder cannot serialize (a
#     datetime, a custom class, a tool result with an unexpected type)
#     degrades to its str() representation instead of raising
#     TypeError. This keeps a long-running service alive when a tool
#     returns something unexpected.
#
# The returned value is a Python str. Callers that need bytes must
# encode it themselves with ENCODING; write_json() does exactly that.

def dumps_json(obj: Any) -> str:
    """
    Serialize `obj` to a JSON string using the toolchain-wide policy.

    See the section comment above for the exact guarantees. This
    function is pure: it does not touch any DataHandle and does not
    perform I/O.
    """
    return json.dumps(obj, ensure_ascii=False, default=str)


# ----------------------------------------------------------------------
# Low-level byte helpers (private)
# ----------------------------------------------------------------------
#
# These three helpers are the ONLY places in the toolchain that touch
# LF_WriteBuffer, LF_ReadBuffer, LF_GetBuffer, LF_GetPos, LF_GetSize,
# and LF_SetPos for payload I/O. Everything else must go through the
# public API below.

def _write_bytes(hnd: DataHnd, data: bytes) -> None:
    """
    Append `data` to the DataHandle at its current position.

    Raises RuntimeError on a short write. A short write means the
    handle is corrupt or the process is out of memory; there is no
    useful recovery path, and silently continuing would produce a
    truncated payload on the wire.
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
    Return bytes from the current position up to the first NUL, and
    advance the handle position accordingly.

    Behaviour matches the standard wire protocol:
      * If a NUL is found, return everything before it and advance the
        handle position past the NUL.
      * If no NUL is found, return the entire remaining buffer and
        advance the position to the end.

    This makes the reader tolerant of inputs written without a NUL
    terminator, which is the case for every payload that arrives from
    a non-standard producer (bridge.py, a browser, a Node.js client).
    """
    pos = LF_GetPos(hnd)
    size = LF_GetSize(hnd)
    if pos >= size:
        return b""

    ptr = LF_GetBuffer(hnd)
    if not ptr:
        return b""

    cptr = ctypes.cast(ptr, ctypes.POINTER(ctypes.c_byte))
    end = pos
    while end < size and cptr[end] != 0:
        end += 1

    length = end - pos

    if length == 0:
        # The very first byte is NUL. This is a valid empty payload;
        # advance past the NUL and return empty bytes.
        LF_SetPos(hnd, end + 1)
        return b""

    buf = (ctypes.c_byte * length)()
    read = LF_ReadBuffer(hnd, buf, length)
    if read != length:
        raise RuntimeError(
            f"LF_ReadBuffer read {read} of {length} bytes"
        )

    if end < size:
        # A NUL was found at position `end`. Advance past it.
        LF_SetPos(hnd, end + 1)
    # else: no NUL was found. LF_ReadBuffer already moved the
    # position to the end of the buffer, so nothing more to do.

    return bytes(buf)


def _read_all(hnd: DataHnd) -> bytes:
    """
    Return all remaining bytes from the handle.

    The handle position is advanced to the end of the buffer. No NUL
    handling is performed; this is the raw binary path.
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


# ----------------------------------------------------------------------
# Public API - string I/O
# ----------------------------------------------------------------------

def write_string(hnd: DataHnd, value: str) -> None:
    """
    Write `value` as UTF-8 bytes, followed by a NUL terminator.

    An empty string is written as a single NUL byte, matching the
    wire protocol convention for empty strings.

    `None` is treated as the empty string, so callers do not need a
    separate check for optional values.
    """
    if value is None:
        value = ""
    _write_bytes(hnd, value.encode(ENCODING) + NUL)


def write_string_bytes(hnd: DataHnd, data: bytes) -> None:
    """
    Write raw UTF-8 bytes followed by a NUL terminator.

    Provided for callers that already hold the encoded bytes and do
    not want to round-trip through str. The bytes are NOT validated
    as UTF-8; garbage in, garbage out. Use this only when the bytes
    are known to be UTF-8 (for example, the output of json.dumps with
    ensure_ascii=False).
    """
    if data:
        _write_bytes(hnd, data)
    _write_bytes(hnd, NUL)


def read_string(hnd: DataHnd) -> str:
    """
    Read a UTF-8 string from the handle, stopping at the first NUL.

    If no NUL is present, the entire remaining buffer is consumed and
    decoded. Returns an empty string if the handle is already at its
    end, or if the first byte is a NUL.

    Raises RuntimeError if the bytes are not valid UTF-8. Callers that
    need raw binary access should use `read_string_bytes` or
    `read_all_bytes` instead.
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

    Unlike `read_all_bytes`, which consumes the entire remaining
    buffer, this stops at the NUL that `write_string` / `write_json`
    append. The bytes are returned undecoded, so the caller can
    inspect or forward them without a UTF-8 round-trip.

    This is the accessor to use inside a bridge or proxy that
    forwards a payload unchanged to a downstream consumer. It is
    also the accessor for callers that want to decode the bytes
    themselves with a specific error handler.

    Returns empty bytes if the handle is already at its end, or if
    the first byte is a NUL.
    """
    return _read_until_nul(hnd)


def peek_string_bytes(hnd: DataHnd) -> bytes:
    """
    Read raw bytes up to the first NUL WITHOUT advancing the handle
    position.

    Provided for diagnostic and logging code that needs to inspect
    the current payload without consuming it. The handle position is
    restored to its original value before returning, so a subsequent
    `read_string` / `read_json` sees the same bytes.

    This is the ONLY public helper that reads without advancing. It
    exists because a debug path that calls `read_string_bytes` twice
    in a row would silently consume the payload the second time; the
    peek variant makes the intent explicit.
    """
    saved_pos = LF_GetPos(hnd)
    try:
        return _read_until_nul(hnd)
    finally:
        LF_SetPos(hnd, saved_pos)


def read_all_bytes(hnd: DataHnd) -> bytes:
    """
    Read all remaining bytes from the handle, without NUL handling.

    The handle position is advanced to the end of the buffer. Use
    this for raw binary payloads; use `read_string_bytes` for
    NUL-terminated text/JSON payloads.
    """
    return _read_all(hnd)


# Backwards-compatible alias. `read_bytes` was the name used in the
# first revision of this module; keep it so that any early caller
# does not break, but document the preferred name above.
read_bytes = read_all_bytes


# ----------------------------------------------------------------------
# Public API - JSON I/O
# ----------------------------------------------------------------------

def write_json(hnd: DataHnd, obj: Any) -> None:
    """
    Serialize `obj` as UTF-8 JSON and write it with a NUL terminator.

    The serialization goes through dumps_json(), so ensure_ascii=False
    and default=str are guaranteed. The output NEVER contains a
    \\uXXXX escape, and a trailing NUL byte is always appended.

    The caller owns `hnd`; this function never frees it.
    """
    _write_bytes(hnd, dumps_json(obj).encode(ENCODING) + NUL)


def read_json(hnd: DataHnd) -> Any:
    """
    Read a UTF-8 JSON payload from the handle and return the decoded
    object.

    The payload may or may not be NUL-terminated. If a NUL is present,
    it is treated as the end of the payload; otherwise the entire
    remaining buffer is consumed.

    {!!!!!  UNIFIED JSON REPAIR PREPROCESSING  !!!!!}
    The decoded text is passed through
    lingofuse.json_repair_preprocess.repair_json_text before it is
    handed to json.loads:

        * Already valid JSON          -> no log message.
        * Malformed but repairable    -> one WARNING, repaired text
                                         is what gets parsed.
        * Malformed and unrepairable  -> one ERROR, and this function
                                         raises RuntimeError as
                                         before.

    The repair engine can be disabled with the environment variable
    LINGOFUSE_JSON_REPAIR=0. In that case, malformed payloads are
    reported as an ERROR (or the RuntimeError below, depending on the
    path) but are never rewritten.

    Returns ``None`` if the buffer contains no bytes at all. This
    matches the historical convention of the toolchain: an empty
    payload means "no result". Note that a JSON ``null`` (the four
    bytes ``null``) also decodes to ``None``; callers that need to
    distinguish the two must inspect the raw buffer themselves via
    `read_string_bytes`.

    Raises RuntimeError if the bytes are not valid UTF-8, or if the
    payload is still not valid JSON after the repair preprocessing.
    This is a protocol error: the other side sent something this
    module cannot interpret, and there is no useful recovery path.
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

    # Unified JSON repair preprocessing. This is a no-op (and emits
    # no log message) when the payload is already valid JSON. See the
    # docstring of repair_json_text for the full three-way policy.
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
    Read a UTF-8 payload and return either the decoded JSON object or
    the raw bytes.

    Semantics:
      * Empty payload                -> None
      * Valid JSON                   -> the decoded Python object
      * Valid UTF-8 but invalid JSON -> the raw bytes (NOT decoded)
      * Invalid UTF-8                -> the raw bytes

    {!!!!!  UNIFIED JSON REPAIR PREPROCESSING  !!!!!}
    Before the strict json.loads call, the decoded text is passed
    through lingofuse.json_repair_preprocess.repair_json_text with
    report_failure=False. This path is explicitly lenient: a payload
    that is not JSON is a legitimate outcome (the caller wants the
    raw bytes), so an unrepairable payload must not produce
    error-level noise. A successful repair still emits a WARNING,
    because rewriting data is always noteworthy.

    This is a deliberately lenient reader for callers that historically
    treated a non-JSON response as a payload they should forward or
    log verbatim, rather than as a protocol error. The canonical
    example is mcp_api_tool: a backend API may return plain text or
    binary, and the MCP server must not reject it merely because it
    is not JSON.

    Callers that want strict behaviour (reject anything that is not
    valid JSON) must use `read_json` instead.

    The handle position is advanced past the payload exactly as in
    `read_string_bytes`.
    """
    raw = _read_until_nul(hnd)
    if not raw:
        return None
    try:
        text = raw.decode(ENCODING)
    except UnicodeDecodeError:
        return raw

    # Unified JSON repair preprocessing with lenient reporting. See
    # the docstring of repair_json_text for the three-way policy; the
    # report_failure=False argument suppresses the ERROR branch for
    # this read path only.
    text = repair_json_text(
        text,
        source="lf_io.read_json_or_bytes",
        report_failure=False,
    )

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return raw


# ----------------------------------------------------------------------
# Public API - C-ABI string parameters
# ----------------------------------------------------------------------

def cstr(value: str) -> bytes:
    """
    Return NUL-terminated UTF-8 bytes for a ``ctypes.c_char_p``
    parameter of an LF_* function.

    Every LF_* string parameter (app name, API name, endpoint, option
    name, option value) MUST be passed through this helper. CPython's
    ``bytes`` objects happen to carry a hidden trailing NUL byte, but
    the toolchain does not rely on that implementation detail: the
    wire contract is explicit here.

    ``None`` is treated as the empty string, so callers do not need a
    separate check for optional values. Callers that need to pass a
    genuine NULL pointer (only applicable to pointer parameters, not
    to string parameters) must call the LF_* function directly.
    """
    if value is None:
        value = ""
    return value.encode(ENCODING) + NUL


# ----------------------------------------------------------------------
# Public exports
# ----------------------------------------------------------------------

__all__ = [
    # Constants
    "NUL",
    "ENCODING",
    # JSON serialization policy (public, for the HTTP path)
    "dumps_json",
    # String I/O
    "write_string",
    "write_string_bytes",
    "read_string",
    "read_string_bytes",
    "peek_string_bytes",
    "read_all_bytes",
    "read_bytes",       # backwards-compatible alias
    # JSON I/O
    "write_json",
    "read_json",
    "read_json_or_bytes",
    # C-ABI
    "cstr",
]