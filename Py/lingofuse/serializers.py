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

{!!!!!  UNIFIED JSON REPAIR PREPROCESSING  !!!!!}
As of this revision, default_deserializer routes the decoded text
through lingofuse.json_repair_preprocess.repair_json_text before it
hands the text to json.loads. The policy is the same three-way policy
used by lf_io.read_json:

    * Already valid JSON          -> no log message, text unchanged.
    * Malformed but repairable    -> one WARNING, repaired text is
                                     what gets parsed.
    * Malformed and unrepairable  -> one ERROR; the original text is
                                     then passed to json.loads, which
                                     raises json.JSONDecodeError as it
                                     always did.

Why this module MUST be part of the repair path
-----------------------------------------------
The C4 client (lingofuse.client) reads JSON responses through
DataHandle.read(), which calls this module's default_deserializer. It
does NOT go through DataHandle.read_json() / lf_io.read_json(). If
this module did not call the repair preprocessor, then:

    server side -> covered by lf_io.read_json
    client side -> NOT covered, would raise on malformed JSON

Adding the call here is what makes the repair coverage symmetric
between the two endpoints.

The serialization direction (default_serializer) is intentionally NOT
affected: json.dumps always produces valid JSON, so running a repair
pass on its output would be wasted work.

The repair engine can be disabled with the environment variable
LINGOFUSE_JSON_REPAIR=0. In that case, default_deserializer only
validates and never rewrites, and the historical behaviour of raising
json.JSONDecodeError on malformed input is preserved.

{!!!!!  FRAME FORMAT IS DIFFERENT FROM lf_io  !!!!!}
This module produces a bytes payload WITHOUT a trailing NUL. That is
deliberately different from lingofuse.lf_io.write_json, which appends
a NUL terminator. The two are used by different protocol layers:

    * DataHandle.write / read (this module)
        -> no NUL. Used by Server.json_call, C4.json_call, and the
           App.local_call / App.expose adapters.

    * DataHandle.write_json / read_json (lf_io)
        -> NUL-terminated. Used by every LF service that speaks the
           NUL-framed wire protocol (llm_service, llm_proxy,
           llm_proxy_tool, mcp_api_tool, language_middleware, bridge).

Both formats are kept for backward compatibility. Do NOT mix them on
the same handle unless you know what you are doing.

This module is a consumer of lingofuse.lf_io (same package). See the
"Callers inside the toolchain include" list in lingofuse.lf_io for
the complete list of consumers.

All comments and log messages are in English.
"""
import json
from typing import Any

from .json_repair_preprocess import repair_json_text
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

    This function is intentionally NOT affected by the unified JSON
    repair preprocessing: json.dumps always produces valid JSON, so a
    repair pass on its output would be wasted work.

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
    producer (for example, a client using the standard string-writing
    primitive with an explicit null terminator) even though the
    serializer side of this module never appends one.

    {!!!!!  UNIFIED JSON REPAIR PREPROCESSING  !!!!!}
    The decoded text is passed through
    lingofuse.json_repair_preprocess.repair_json_text before it
    reaches json.loads. The policy is:

        * Already valid JSON         -> no log message, text unchanged.
        * Malformed but repairable   -> one WARNING, the repaired text
                                        is what gets parsed.
        * Malformed and unrepairable -> one ERROR; the original text
                                        is then passed to json.loads,
                                        which raises the same
                                        json.JSONDecodeError that
                                        this function has always
                                        raised.

    This call is what makes the repair coverage symmetric between the
    server side (which uses DataHandle.read_json -> lf_io.read_json)
    and the client side (which uses DataHandle.read ->
    default_deserializer, i.e. this function).

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
        json.JSONDecodeError: if the text is not valid JSON, either
            before the repair attempt or after a failed repair.
    """
    if data and data[-1] == 0:
        data = data[:-1]
    text = data.decode("utf-8")

    # Unified JSON repair preprocessing. This is a no-op (and emits no
    # log message) when the payload is already valid JSON. See the
    # docstring of repair_json_text for the full three-way policy.
    #
    # report_failure=True is the default and is what we want here:
    # this read path is strict, so an unrepairable payload must be
    # surfaced at ERROR level before the subsequent json.loads raises.
    text = repair_json_text(
        text,
        source="serializers.default_deserializer",
    )

    return json.loads(text)