# -*- coding: utf-8 -*-
"""
Default serializers: JSON only.

These functions are used by DataHandle and the high-level wrappers to
convert Python objects to bytes and back. They are not part of the
core LingoFuse ABI, but provide a convenient way to exchange structured
data.

The library itself only deals with raw binary payloads; the
serialization format is entirely application-defined.

{!!!!!  JSON POLICY DELEGATION  !!!!!}
As of this revision, the JSON serialization policy used by
default_serializer is delegated to lingofuse.lf_io.dumps_json, which
is the single source of truth for the toolchain:

    json.dumps(obj, ensure_ascii=False, default=str)

The delegation keeps this module's PUBLIC SIGNATURE unchanged:

    * default_serializer returns bytes,
    * default_deserializer accepts bytes and tolerates a trailing NUL.

What DID change is the V1 serialization policy: objects that the
standard JSON encoder cannot serialize (a datetime, a custom class)
now degrade to their str() representation instead of raising
TypeError. This matches the behaviour of every other LF JSON producer
in the toolchain.

{!!!!!  FRAME FORMAT IS DIFFERENT FROM lf_io  !!!!!}
This module produces a bytes payload WITHOUT a trailing NUL. That is
deliberately different from lingofuse.lf_io.write_json, which appends
a NUL terminator. The two are used by different protocol layers:

    * DataHandle.write / read (this module)
        -> no NUL. Used by Server.json_call, C4.json_call, and the
           App.local_call / App.expose adapters.

    * DataHandle.write_json / read_json (lf_io)
        -> NUL-terminated. Used by every LF service that speaks to
           the Pascal side (llm_service, llm_proxy, llm_proxy_tool,
           mcp_api_tool, language_middleware, bridge).

Both formats are kept for backward compatibility. Do NOT mix them on
the same handle unless you know what you are doing.

This module is a consumer of lingofuse.lf_io (same package). See the
"Callers inside the toolchain include" list in lingofuse.lf_io for
the complete list of consumers.
"""
import json
from typing import Any

from .lf_io import dumps_json


def default_serializer(obj: Any) -> bytes:
    """
    Serialize a Python object to UTF-8 JSON bytes.

    Delegates to lingofuse.lf_io.dumps_json for the serialization
    policy, then encodes the resulting string to UTF-8 bytes.

    The result does NOT include a trailing NUL byte. This matches the
    historical behaviour of this function and the DataHandle.write /
    read protocol layer. Callers that need the NUL-terminated framing
    should use lingofuse.lf_io.write_json instead.

    Arguments:
        obj: Any JSON-serializable Python object. Non-serializable
             values degrade to their str() representation rather than
             raising TypeError (see lf_io.dumps_json).

    Returns:
        UTF-8 encoded bytes, ready to be written to a DataHandle.
    """
    return dumps_json(obj).encode("utf-8")


def default_deserializer(data: bytes) -> Any:
    """
    Deserialize UTF-8 JSON bytes back to a Python object.

    A trailing NUL byte, if present, is stripped before decoding.
    This tolerates payloads that were produced by a NUL-terminating
    producer (for example, a Pascal client calling LF_WriteString)
    even though the serializer side of this module never appends one.

    The inner json.loads call is intentionally kept here rather than
    delegated to lingofuse.lf_io. The deserialization direction does
    not need the ensure_ascii / default=str policy: it operates on
    whatever bytes arrived on the wire, and any valid JSON document
    is acceptable.

    Arguments:
        data: The raw bytes read from a DataHandle.

    Returns:
        The parsed Python object.

    Raises:
        UnicodeDecodeError: if the bytes are not valid UTF-8.
        json.JSONDecodeError: if the text is not valid JSON.
    """
    if data and data[-1] == 0:
        data = data[:-1]
    return json.loads(data.decode("utf-8"))