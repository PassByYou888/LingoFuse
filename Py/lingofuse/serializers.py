# -*- coding: utf-8 -*-
"""
Default serializers: JSON with pickle fallback.

These functions are used by DataHandle and the high‑level wrappers to
convert Python objects to bytes and back. They are not part of the
core LingoFuse ABI, but provide a convenient way to exchange structured
data.

The library itself only deals with raw binary payloads; the serialization
format is entirely application‑defined.
"""
import json
import pickle
from typing import Any

def default_serializer(obj: Any) -> bytes:
    try:
        return json.dumps(obj, ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError):
        return pickle.dumps(obj)

def default_deserializer(data: bytes) -> Any:
    if data and data[-1] == 0:
        data = data[:-1]
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        try:
            return pickle.loads(data)
        except Exception:
            return data